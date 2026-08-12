# SSC Event Booking System - one-time environment setup for Windows.
# Installs prerequisites via Chocolatey, provisions the local MySQL database,
# downloads MinIO, and builds all three app submodules.
#
# Run from the repo root, in an elevated (Administrator) PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1
#
# Non-interactive (CI / automation):
#   powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1 -MySqlRootPassword "yourpwd"
#   (pass an empty string "" if root has no password)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'MySqlRootPassword')]
param(
    [string]$MySqlRootPassword = $null
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

Write-Host "=== SSC System setup ===" -ForegroundColor Cyan
Write-Host "Repo root: $repo"

# --- 0. Require elevated session only if Chocolatey installs are needed -----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 1. Check prerequisites & MySQL status ----------------------------------------
Write-Host "`n[1/6] Checking prerequisites..." -ForegroundColor Cyan

# Probe for mysql.exe in PATH or common XAMPP / MySQL paths and save path.
$mysqlBin = Get-Command mysql -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $mysqlBin) {
    $knownMySqlPaths = @(
        'C:\xampp\mysql\bin\mysql.exe',
        'D:\xampp\mysql\bin\mysql.exe',
        'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
        'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe',
        'C:\Program Files (x86)\MySQL\MySQL Server 8.0\bin\mysql.exe'
    )
    if ($env:XAMPP_HOME) {
        $knownMySqlPaths += (Join-Path $env:XAMPP_HOME 'mysql\bin\mysql.exe')
    }
    foreach ($path in $knownMySqlPaths) {
        if (Test-Path $path) {
            $mysqlBin = $path
            $binDir = Split-Path -Parent $path
            $env:PATH = "$binDir;$env:PATH"
            Write-Host ("  Found MySQL CLI at {0} (added to PATH)" -f $path) -ForegroundColor Green
            break
        }
    }
}

# Verify MySQL is actively running on port 3306 (HARD STOP if not running)
function Test-SscMySqlPort([int]$Port = 3306, [int]$TimeoutMs = 1000) {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected
        $client.Close()
        return [bool]$ok
    } catch { return $false }
}

if (-not (Test-SscMySqlPort)) {
    Write-Host "`n[ERROR] MySQL is NOT running on port 3306!" -ForegroundColor Red
    Write-Host "Please start MySQL in the XAMPP Control Panel (or start your MySQL service) before running setup." -ForegroundColor Yellow
    Write-Host "Setup aborted." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  OK      MySQL service detected on port 3306 (using existing / XAMPP MySQL)" -ForegroundColor Green
}

# Dev tools managed by Chocolatey if missing (MySQL is excluded because existing MySQL/XAMPP is used).
$tools = [ordered]@{
    'git'   = 'git'
    'java'  = 'temurin'
    'mvn'   = 'maven'
    'node'  = 'nodejs-lts'
}

$missing = @()
foreach ($cmd in $tools.Keys) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host ("  OK      {0}" -f $cmd)
    } else {
        Write-Host ("  MISSING {0}" -f $cmd) -ForegroundColor Yellow
        $missing += $cmd
    }
}

if ($missing.Count -eq 0) {
    Write-Host "  All dev prerequisites already installed - nothing to download." -ForegroundColor Green
} else {
    if (-not $isAdmin) {
        Write-Host "`n[ERROR] Missing prerequisites ($($missing -join ', ')) need to be installed via Chocolatey." -ForegroundColor Red
        Write-Host "Please re-run this script in an elevated (Administrator) PowerShell session." -ForegroundColor Yellow
        exit 1
    }

    $packages = $missing | ForEach-Object { $tools[$_] }
    Write-Host ("`n  Missing: {0} -> will install via Chocolatey: {1}" -f ($missing -join ', '), ($packages -join ', ')) -ForegroundColor Yellow

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "  Chocolatey not found - installing..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-Host "Chocolatey install did not put 'choco' on PATH. Open a new PowerShell window and re-run this script." -ForegroundColor Red
            exit 1
        }
    }

    choco install @packages -y
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Chocolatey package install failed - see output above." -ForegroundColor Red
        exit 1
    }

    # Refresh PATH in this process so freshly-installed tools are usable without a new shell.
    $chocoProfile = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    if (Test-Path $chocoProfile) {
        Import-Module $chocoProfile
        refreshenv | Out-Null
    }

    $stillMissing = @()
    foreach ($cmd in $missing) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host ("  OK      {0}" -f $cmd)
        } else {
            Write-Host ("  MISS    {0}" -f $cmd) -ForegroundColor Red
            $stillMissing += $cmd
        }
    }
    if ($stillMissing.Count -gt 0) {
        Write-Host "`nStill missing after install: $($stillMissing -join ', ')" -ForegroundColor Red
        Write-Host "Close this window, open a new (Administrator) PowerShell, and re-run this script -"
        Write-Host "Chocolatey sometimes needs a fresh shell to pick up PATH changes."
        exit 1
    }
}

# --- 2. Submodules ---------------------------------------------------------------
Write-Host "`n[2/6] Checking submodules..." -ForegroundColor Cyan
if (-not (Test-Path (Join-Path $repo 'ssc-booking-backend\pom.xml'))) {
    Write-Host "  Submodules are empty. Running: git submodule update --init" -ForegroundColor Yellow
    Push-Location $repo
    git submodule update --init
    Pop-Location
} else {
    Write-Host "  OK   submodules present"
}

# --- 3. MySQL database + user -----------------------------------------------------
Write-Host "`n[3/6] Creating MySQL database 'ssc_booking' and user 'sscuser'..." -ForegroundColor Cyan
if ($null -eq $MySqlRootPassword) {
    # Default to empty password for standard XAMPP MySQL installations
    $MySqlRootPassword = ""
}

$sql = @'
CREATE DATABASE IF NOT EXISTS ssc_booking CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'sscuser'@'localhost' IDENTIFIED BY 'sscpassword';
CREATE USER IF NOT EXISTS 'sscuser'@'%' IDENTIFIED BY 'sscpassword';
ALTER USER 'sscuser'@'localhost' IDENTIFIED BY 'sscpassword';
ALTER USER 'sscuser'@'%' IDENTIFIED BY 'sscpassword';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'localhost';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'%';
FLUSH PRIVILEGES;
'@

if ($mysqlBin -and (Test-Path $mysqlBin)) {
    if ([string]::IsNullOrEmpty($MySqlRootPassword)) {
        $sql | & $mysqlBin -u root --skip-password
    } else {
        $sql | & $mysqlBin -u root --password=$MySqlRootPassword
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "MySQL setup failed - check the root password and that the MySQL service is running on port 3306." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Database ready. (Tables are created by Flyway on first backend start.)" -ForegroundColor Green
} else {
    Write-Host "  [WARNING] mysql.exe CLI not found. Please ensure 'ssc_booking' database and 'sscuser' account exist." -ForegroundColor Yellow
}


# --- 4. MinIO -----------------------------------------------------------------------
Write-Host "`n[4/6] Setting up MinIO..." -ForegroundColor Cyan
$minioDir = Join-Path $repo '.tools'
$minioExe = Join-Path $minioDir 'minio.exe'
New-Item -ItemType Directory -Force (Join-Path $minioDir 'minio-data') | Out-Null
if (Test-Path $minioExe) {
    Write-Host "  minio.exe already present."
} else {
    Write-Host "  Downloading minio.exe (~110 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L -s -S -o $minioExe 'https://dl.min.io/server/minio/release/windows-amd64/minio.exe'
    } else {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $true
        $client = [System.Net.Http.HttpClient]::new($handler)
        $bytes = $client.GetByteArrayAsync('https://dl.min.io/server/minio/release/windows-amd64/minio.exe').GetAwaiter().GetResult()
        [System.IO.File]::WriteAllBytes($minioExe, $bytes)
        $client.Dispose()
        $handler.Dispose()
    }
    if ((-not (Test-Path $minioExe)) -or ((Get-Item $minioExe).Length -lt 1000000)) {
        Write-Host "MinIO binary download failed or output file is corrupt." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Downloaded."
}

# --- 5. Build backend + fileserver ---------------------------------------------------
Write-Host "`n[5/6] Building Main API and File Server with Maven (packages JARs & runs isolated test suite)..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-backend')
mvn clean package
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Backend build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  Main API jar built successfully (isolated test validation passed)." -ForegroundColor Green

Push-Location (Join-Path $repo 'ssc-booking-fileserver')
mvn clean package
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "File server build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  File server jar built successfully." -ForegroundColor Green

# --- 6. Frontend ----------------------------------------------------------------------
Write-Host "`n[6/6] Installing and building the frontend..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-frontend')
if ((-not (Test-Path '.env.local')) -and (Test-Path '.env.local.example')) {
    Copy-Item '.env.local.example' '.env.local'
    Write-Host "  Created .env.local from .env.local.example (defaults: localhost)."
}
npm install
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "npm install failed." -ForegroundColor Red; exit 1 }
npm run build
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Frontend build failed." -ForegroundColor Red; exit 1 }
Pop-Location

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "Start each service in its own terminal:"
Write-Host "  .tools\minio.exe server .tools\minio-data --address :9006 --console-address :9007   (set MINIO_ROOT_USER=sscadmin, MINIO_ROOT_PASSWORD=sscpassword123)"
Write-Host "  cd ssc-booking-fileserver; java -jar target\*.jar --server.port=9005"
Write-Host "  cd ssc-booking-backend;    java -jar target\*.jar --server.port=9004"
Write-Host "  cd ssc-booking-frontend;   npm start -- -p 9003"
Write-Host "Then open: http://localhost:9003/login"
Write-Host "(Or just run scripts\start-all.ps1, which reads all of these ports from .env.)"
