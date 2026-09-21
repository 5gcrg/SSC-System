# SSC Event Booking System - one-time environment setup for Windows.
#
# Run from the repository root in PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1
#
# Build-only setup (does not require MySQL):
#   powershell -ExecutionPolicy Bypass -File scripts\SETUP.ps1 -SkipDatabase
#
# Command-line database parameters override values loaded from the root .env file.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'MySqlRootPassword')]
param(
    [string]$MySqlRootPassword = $null,
    [string]$MySqlHost = $null,
    [int]$MySqlPort = 0,
    [string]$MySqlDatabase = $null,
    [string]$MySqlUser = $null,
    [string]$MySqlPassword = $null,
    [switch]$SkipDatabase
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Import-SscDotEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
             ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

function Get-SscEnv([string]$Name, [string]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($null -ne $value -and $value -ne '') { return $value }
    return $Default
}

function Get-SscJavaMajor {
    if (-not (Get-Command java -CommandType Application -ErrorAction SilentlyContinue)) { return 0 }
    # java -version writes normal output to stderr. Windows PowerShell 5.1 turns
    # redirected native stderr into an ErrorRecord when ErrorActionPreference=Stop,
    # so capture it through cmd.exe instead.
    $output = (& cmd.exe /d /c 'java -version 2>&1' | Out-String)
    if ($output -match 'version\s+"(?<major>\d+)') { return [int]$Matches.major }
    if ($output -match 'openjdk\s+(?<major>\d+)') { return [int]$Matches.major }
    return 0
}

function Get-SscNodeVersion {
    if (-not (Get-Command node -CommandType Application -ErrorAction SilentlyContinue)) {
        return [Version]'0.0.0'
    }
    $raw = ((& node --version) -replace '^v', '').Trim()
    $version = [Version]'0.0.0'
    if ([Version]::TryParse($raw, [ref]$version)) { return $version }
    return [Version]'0.0.0'
}

function Find-SscMySqlClient {
    $command = Get-Command mysql -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    $candidates = @(
        'C:\xampp\mysql\bin\mysql.exe',
        'D:\xampp\mysql\bin\mysql.exe',
        'C:\Program Files\MariaDB 11.4\bin\mysql.exe',
        'C:\Program Files\MariaDB 10.11\bin\mysql.exe'
    )
    if ($env:XAMPP_HOME) {
        $candidates += (Join-Path $env:XAMPP_HOME 'mysql\bin\mysql.exe')
    }
    $candidates += Get-ChildItem 'C:\Program Files\MySQL\MySQL Server *\bin\mysql.exe' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Test-SscTcpEndpoint([string]$HostName, [int]$Port, [int]$TimeoutMs = 1000) {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connection = $client.BeginConnect($HostName, $Port, $null, $null)
            return $connection.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected
        } finally {
            $client.Close()
        }
    } catch {
        return $false
    }
}

function ConvertTo-SscMySqlLiteral([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace("'", "''")
}

Import-SscDotEnv (Join-Path $repo '.env')

if (-not $PSBoundParameters.ContainsKey('MySqlRootPassword')) {
    $MySqlRootPassword = Get-SscEnv 'MYSQL_ROOT_PASSWORD' ''
}
if (-not $PSBoundParameters.ContainsKey('MySqlHost')) {
    $MySqlHost = Get-SscEnv 'MYSQL_HOST' '127.0.0.1'
}
if (-not $PSBoundParameters.ContainsKey('MySqlPort')) {
    $portText = Get-SscEnv 'MYSQL_PORT' '3306'
    if (-not [int]::TryParse($portText, [ref]$MySqlPort) -or $MySqlPort -lt 1 -or $MySqlPort -gt 65535) {
        throw "MYSQL_PORT must be a number between 1 and 65535 (received '$portText')."
    }
}
if (-not $PSBoundParameters.ContainsKey('MySqlDatabase')) {
    $MySqlDatabase = Get-SscEnv 'MYSQL_DATABASE' 'ssc_booking'
}
if (-not $PSBoundParameters.ContainsKey('MySqlUser')) {
    $MySqlUser = Get-SscEnv 'MYSQL_USER' 'sscuser'
}
if (-not $PSBoundParameters.ContainsKey('MySqlPassword')) {
    $MySqlPassword = Get-SscEnv 'MYSQL_PASSWORD' 'sscpassword'
}
if ([string]::IsNullOrWhiteSpace($MySqlHost)) { throw 'MYSQL_HOST cannot be empty.' }
if ($MySqlPort -lt 1 -or $MySqlPort -gt 65535) { throw 'MYSQL_PORT must be between 1 and 65535.' }

# Fail before setup downloads, installs, or builds anything when the external
# database is unavailable. The mysql client alone does not mean XAMPP/MariaDB is
# running, and a connection failure must never be confused with a setup change.
$mysqlBin = $null
if (-not $SkipDatabase) {
    $mysqlBin = Find-SscMySqlClient
    if (-not $mysqlBin) {
        throw 'MySQL/MariaDB client was not found. Install XAMPP/MySQL, or run setup with -SkipDatabase.'
    }
    if (-not (Test-SscTcpEndpoint -HostName $MySqlHost -Port $MySqlPort)) {
        throw "MySQL/MariaDB is not running at $MySqlHost`:$MySqlPort. Start it in the XAMPP Control Panel, wait until it is green, and run setup again. No database changes were made."
    }
}

Write-Host '=== SSC System setup ===' -ForegroundColor Cyan
Write-Host "Repo root: $repo"

# --- 1. Prerequisites ---------------------------------------------------------------
Write-Host "`n[1/6] Checking prerequisites..." -ForegroundColor Cyan
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$installPackages = @()

if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
    Write-Host "  OK      $(& git --version)"
} else {
    Write-Host '  MISSING Git' -ForegroundColor Yellow
    $installPackages += 'git'
}

$javaMajor = Get-SscJavaMajor
if ($javaMajor -eq 21) {
    Write-Host '  OK      Java 21'
} else {
    $description = if ($javaMajor -eq 0) { 'missing' } else { "version $javaMajor (Java 21 is required)" }
    Write-Host "  INVALID Java: $description" -ForegroundColor Yellow
    $installPackages += 'temurin21'
}

$nodeVersion = Get-SscNodeVersion
$minimumNode = [Version]'18.18.0'
if ($nodeVersion -ge $minimumNode -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "  OK      Node.js $nodeVersion"
} else {
    Write-Host "  INVALID Node.js: found $nodeVersion; version $minimumNode or newer with npm is required" -ForegroundColor Yellow
    $installPackages += 'nodejs-lts'
}

if ($installPackages.Count -gt 0) {
    if (-not $isAdmin) {
        Write-Host "`n[ERROR] Installation requires Administrator PowerShell: $($installPackages -join ', ')" -ForegroundColor Red
        Write-Host 'Re-run this script as Administrator.' -ForegroundColor Yellow
        exit 1
    }
    if (-not (Get-Command choco -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '  Chocolatey not found - installing...'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    if (-not (Get-Command choco -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '[ERROR] Chocolatey was installed but is not available in this PowerShell session.' -ForegroundColor Red
        Write-Host 'Open a new Administrator PowerShell and run setup again.' -ForegroundColor Yellow
        exit 1
    }
    $installPackages = @($installPackages | Select-Object -Unique)
    & choco install $installPackages -y
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[ERROR] Chocolatey package installation failed.' -ForegroundColor Red
        exit 1
    }
    $chocolateyInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Process')
    if (-not $chocolateyInstall) {
        $chocolateyInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    }
    if ($chocolateyInstall) {
        $profile = Join-Path $chocolateyInstall 'helpers\chocolateyProfile.psm1'
        if (Test-Path -LiteralPath $profile) {
            Import-Module $profile
            refreshenv | Out-Null
        }
    }
}

$preflightErrors = @()
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { $preflightErrors += 'Git is unavailable' }
if ((Get-SscJavaMajor) -ne 21) { $preflightErrors += 'Java 21 is not the active java executable' }
if ((Get-SscNodeVersion) -lt $minimumNode) { $preflightErrors += "Node.js $minimumNode or newer is unavailable" }
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { $preflightErrors += 'npm is unavailable' }
if ($preflightErrors.Count -gt 0) {
    Write-Host "`n[ERROR] Prerequisite validation failed:" -ForegroundColor Red
    $preflightErrors | ForEach-Object { Write-Host "  - $_" }
    Write-Host 'Open a new PowerShell after installation. If multiple JDKs are installed, point JAVA_HOME and PATH to JDK 21.' -ForegroundColor Yellow
    exit 1
}
Write-Host '  All prerequisite versions are valid.' -ForegroundColor Green

# --- 2. Submodules ------------------------------------------------------------------
Write-Host "`n[2/6] Initializing and checking submodules..." -ForegroundColor Cyan
Push-Location $repo
try {
    & git submodule sync --recursive
    if ($LASTEXITCODE -ne 0) { throw 'git submodule sync failed.' }
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw 'git submodule update failed. Check network access and repository permissions.' }
} finally {
    Pop-Location
}
$requiredSubmoduleFiles = @(
    'ssc-booking-backend\pom.xml',
    'ssc-booking-backend\src\main\resources\db\migration\V58__normalize_school_ids.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V59__seed_current_masterlists.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V60__sync_active_departments_and_organizations.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V61__store_approval_pins_on_users.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V62__introduce_ssc_endorser_role.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V63__add_staged_document_decisions.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V64__assign_academic_setting_ownership.sql',
    'ssc-booking-backend\src\main\resources\db\migration\V65__add_sdg_objective_selection.sql',
    'ssc-booking-fileserver\pom.xml',
    'ssc-booking-frontend\package.json',
    'ssc-booking-frontend\package-lock.json'
)
$missingSubmoduleFiles = @($requiredSubmoduleFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $repo $_))
})
if ($missingSubmoduleFiles.Count -gt 0) {
    throw "Submodule initialization is incomplete. Missing: $($missingSubmoduleFiles -join ', ')"
}
Write-Host '  All application submodules are present.' -ForegroundColor Green
Write-Host '  Bundled masterlist baseline is present (278 registrar records, 277 student profiles, 2 faculty records).' -ForegroundColor Green
Write-Host '  Active directory baseline is present (6 departments, 5 organizations).' -ForegroundColor Green
Write-Host '  Server-managed approval PIN migration is present.' -ForegroundColor Green
Write-Host '  SSC Endorser and final-approval workflow migrations are present.' -ForegroundColor Green
Write-Host '  Complete 17-goal SDG objective masterlist migration is present.' -ForegroundColor Green

# --- 3. MinIO -----------------------------------------------------------------------
Write-Host "`n[3/6] Setting up MinIO..." -ForegroundColor Cyan
$minioDir = Join-Path $repo '.tools'
$minioExe = Join-Path $minioDir 'minio.exe'
$minioData = Join-Path $minioDir 'minio-data'
New-Item -ItemType Directory -Force $minioData | Out-Null
if (-not (Test-Path -LiteralPath $minioExe)) {
    $downloadPath = "$minioExe.download"
    Write-Host '  Downloading minio.exe...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    try {
        if (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --silent --show-error -o $downloadPath 'https://dl.min.io/server/minio/release/windows-amd64/minio.exe'
            if ($LASTEXITCODE -ne 0) { throw 'curl failed to download MinIO.' }
        } else {
            $client = [System.Net.Http.HttpClient]::new()
            try {
                $bytes = $client.GetByteArrayAsync('https://dl.min.io/server/minio/release/windows-amd64/minio.exe').GetAwaiter().GetResult()
                [System.IO.File]::WriteAllBytes($downloadPath, $bytes)
            } finally {
                $client.Dispose()
            }
        }
        if ((-not (Test-Path -LiteralPath $downloadPath)) -or (Get-Item -LiteralPath $downloadPath).Length -lt 1000000) {
            throw 'Downloaded MinIO binary is missing or unexpectedly small.'
        }
        Move-Item -LiteralPath $downloadPath -Destination $minioExe -Force
    } finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
    }
}
$minioVersion = (& $minioExe --version 2>&1 | Select-Object -First 1)
if ($LASTEXITCODE -ne 0) { throw 'minio.exe exists but could not be executed.' }
Write-Host "  OK      $minioVersion" -ForegroundColor Green

# --- 4. Database --------------------------------------------------------------------
Write-Host "`n[4/6] Database provisioning..." -ForegroundColor Cyan
if ($SkipDatabase) {
    Write-Host '  SKIPPED Database provisioning (-SkipDatabase).' -ForegroundColor Yellow
} else {
    if ($MySqlDatabase -notmatch '^[A-Za-z0-9_]+$') { throw 'MYSQL_DATABASE may contain only letters, numbers, and underscores.' }
    if ($MySqlUser -notmatch '^[A-Za-z0-9_]+$') { throw 'MYSQL_USER may contain only letters, numbers, and underscores.' }
    $escapedUserPassword = ConvertTo-SscMySqlLiteral $MySqlPassword
    $sql = @"
CREATE DATABASE IF NOT EXISTS ``$MySqlDatabase`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MySqlUser'@'localhost' IDENTIFIED BY '$escapedUserPassword';
CREATE USER IF NOT EXISTS '$MySqlUser'@'%' IDENTIFIED BY '$escapedUserPassword';
ALTER USER '$MySqlUser'@'localhost' IDENTIFIED BY '$escapedUserPassword';
ALTER USER '$MySqlUser'@'%' IDENTIFIED BY '$escapedUserPassword';
GRANT ALL PRIVILEGES ON ``$MySqlDatabase``.* TO '$MySqlUser'@'localhost';
GRANT ALL PRIVILEGES ON ``$MySqlDatabase``.* TO '$MySqlUser'@'%';
FLUSH PRIVILEGES;
"@
    $hadMySqlPwd = Test-Path Env:MYSQL_PWD
    $previousMySqlPwd = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $MySqlRootPassword

        # XAMPP's MariaDB privilege tables use the non-transactional Aria
        # engine and can be left damaged by an unclean server shutdown. Check
        # every table this provisioning SQL writes before making any changes.
        # Setup never repairs system tables automatically: a failed Aria
        # repair can rebuild a corrupt table without all of its original rows.
        $serverVersion = (& $mysqlBin --protocol=tcp --host=$MySqlHost --port=$MySqlPort --user=root `
            --batch --skip-column-names --execute='SELECT VERSION();' | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not connect to MySQL at $MySqlHost`:$MySqlPort as root. Check MYSQL_ROOT_PASSWORD and server availability."
        }
        if ($serverVersion -match 'MariaDB') {
            $privilegeCheck = (& $mysqlBin --protocol=tcp --host=$MySqlHost --port=$MySqlPort --user=root `
                --batch --skip-column-names --execute='CHECK TABLE mysql.global_priv, mysql.db;' | Out-String)
            if ($LASTEXITCODE -ne 0) {
                throw 'MariaDB privilege-table integrity check failed.'
            }
            if ($privilegeCheck -match '(?im)\b(corrupt|crashed|error)\b') {
                Write-Host $privilegeCheck.TrimEnd() -ForegroundColor Red
                throw 'MariaDB privilege tables are damaged. Setup stopped before changing accounts or grants. Back up the XAMPP data directory and repair or restore the affected tables before retrying.'
            }
        }

        $sql | & $mysqlBin --protocol=tcp --host=$MySqlHost --port=$MySqlPort --user=root
        if ($LASTEXITCODE -ne 0) {
            throw "MySQL provisioning failed for $MySqlHost`:$MySqlPort. Review the SQL error printed above."
        }
    } finally {
        if ($hadMySqlPwd) { $env:MYSQL_PWD = $previousMySqlPwd } else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
    }
    Write-Host "  Database '$MySqlDatabase' and user '$MySqlUser' are ready." -ForegroundColor Green
}

# --- 5. Maven reactor build --------------------------------------------------------
Write-Host "`n[5/6] Building backend services with the Maven Wrapper..." -ForegroundColor Cyan
$mavenWrapper = Join-Path $repo 'mvnw.cmd'
if (-not (Test-Path -LiteralPath $mavenWrapper)) { throw 'mvnw.cmd is missing from the repository root.' }
Push-Location $repo
$runtimeDatabaseEnvironment = @(
    'SPRING_DATASOURCE_URL',
    'SPRING_DATASOURCE_USERNAME',
    'SPRING_DATASOURCE_PASSWORD',
    'SPRING_DATASOURCE_DRIVER_CLASS_NAME'
)
$savedDatabaseEnvironment = @{}
try {
    # The root .env contains runtime MySQL overrides. Spring gives environment
    # variables precedence over application-test.yml, so allowing those values
    # into Surefire produces an invalid H2-driver/MySQL-URL combination.
    foreach ($name in $runtimeDatabaseEnvironment) {
        $savedDatabaseEnvironment[$name] = @{
            Exists = Test-Path "Env:$name"
            Value = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    & $mavenWrapper clean package
    if ($LASTEXITCODE -ne 0) { throw 'Maven reactor build failed.' }
} finally {
    foreach ($name in $runtimeDatabaseEnvironment) {
        $saved = $savedDatabaseEnvironment[$name]
        if ($saved.Exists) {
            [Environment]::SetEnvironmentVariable($name, $saved.Value, 'Process')
        } else {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Pop-Location
}
Write-Host '  Backend and file server JARs built successfully.' -ForegroundColor Green

# --- 6. Frontend --------------------------------------------------------------------
Write-Host "`n[6/6] Installing and building the frontend..." -ForegroundColor Cyan
$frontendDir = Join-Path $repo 'ssc-booking-frontend'
$serviceModule = Join-Path $PSScriptRoot 'ServiceLib.psm1'
$restartManagedFrontend = $false
if (Test-Path -LiteralPath $serviceModule) {
    Import-Module $serviceModule -Force
    $frontendStatus = Get-SscServiceStatus 'frontend'
    if ($frontendStatus.Status -in @('RUNNING', 'STARTING')) {
        Write-Host '  Stopping the managed frontend to release Windows file locks...' -ForegroundColor Yellow
        Stop-SscService 'frontend'
        $restartManagedFrontend = $true
        Start-Sleep -Milliseconds 500
    } elseif ($frontendStatus.Status -eq 'EXTERNAL') {
        throw "Frontend port $($frontendStatus.Port) is owned by untracked PID $($frontendStatus.ProcessId). Stop that process before running setup so npm can replace the Next.js SWC binary."
    }
}
Push-Location $frontendDir
try {
    if ((-not (Test-Path -LiteralPath '.env.local')) -and (Test-Path -LiteralPath '.env.local.example')) {
        Copy-Item -LiteralPath '.env.local.example' -Destination '.env.local'
        Write-Host '  Created .env.local from .env.local.example.'
    }
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
} finally {
    Pop-Location
    if ($restartManagedFrontend) {
        Write-Host '  Restarting the managed frontend...' -ForegroundColor Yellow
        Start-SscService 'frontend'
    }
}

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
if ($SkipDatabase) {
    Write-Host 'Database provisioning was skipped. Provision MySQL before starting the backend.' -ForegroundColor Yellow
}
Write-Host 'Start all services with:'
Write-Host '  powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1'
Write-Host 'The first backend start applies the ID, masterlist, directory, approval PIN, staged endorsement, and SDG objective migrations automatically.'
Write-Host 'Then open: http://localhost:9003/login'
