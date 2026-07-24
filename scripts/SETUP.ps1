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

# --- 0. Require an elevated session -------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script installs software via Chocolatey and must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run this script."
    exit 1
}

# --- 1. Check prerequisites (any install method - not just Chocolatey) ------------
Write-Host "`n[1/6] Checking prerequisites..." -ForegroundColor Cyan

# Command name -> Chocolatey package id, only used for whichever ones are missing.
$tools = [ordered]@{
    'git'   = 'git'
    'java'  = 'temurin21'
    'mvn'   = 'maven'
    'node'  = 'nodejs-lts'
    'mysql' = 'mysql'
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
    Write-Host "  All prerequisites already installed - nothing to download." -ForegroundColor Green
} else {
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
    $rootPwd = Read-Host "Enter your MySQL root password (blank if none)" -AsSecureString
    $MySqlRootPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($rootPwd))
}

$sql = @'
CREATE DATABASE IF NOT EXISTS ssc_booking CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'sscuser'@'localhost' IDENTIFIED BY 'sscpassword';
CREATE USER IF NOT EXISTS 'sscuser'@'%' IDENTIFIED BY 'sscpassword';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'localhost';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'%';
FLUSH PRIVILEGES;
'@
if ([string]::IsNullOrEmpty($MySqlRootPassword)) {
    $sql | mysql -u root --skip-password
} else {
    $sql | mysql -u root --password=$MySqlRootPassword
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "MySQL setup failed - check the root password and that the MySQL service is running on port 3306." -ForegroundColor Red
    exit 1
}
Write-Host "  Database ready. (Tables are created by Flyway on first backend start.)"

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
    Invoke-WebRequest -Uri 'https://dl.min.io/server/minio/release/windows-amd64/minio.exe' -OutFile $minioExe
    Write-Host "  Downloaded."
}

# --- 5. Build backend + fileserver ---------------------------------------------------
Write-Host "`n[5/6] Building Main API and File Server (downloads Maven deps on first run)..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-backend')
mvn -q clean package -DskipTests
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Backend build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  Main API jar built."

Push-Location (Join-Path $repo 'ssc-booking-fileserver')
mvn -q clean package -DskipTests
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "File server build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  File server jar built."

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
Write-Host "  .tools\minio.exe server .tools\minio-data --console-address :9001   (set MINIO_ROOT_USER=sscadmin, MINIO_ROOT_PASSWORD=sscpassword123)"
Write-Host "  cd ssc-booking-fileserver; java -jar target\*.jar"
Write-Host "  cd ssc-booking-backend;    java -jar target\*.jar"
Write-Host "  cd ssc-booking-frontend;   npm start"
Write-Host "Then open: http://localhost:3000/login"
