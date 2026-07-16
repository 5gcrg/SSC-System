# SSC Event Booking System - one-time setup for bare-metal Windows.
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
# See INSTRUCTIONS.md for the manual equivalent of every step.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

Write-Host "=== SSC System setup ===" -ForegroundColor Cyan
Write-Host "Repo root: $repo"

# --- 1. Verify prerequisites -------------------------------------------------
Write-Host "`n[1/6] Checking prerequisites..." -ForegroundColor Cyan
$missing = @()
foreach ($tool in @('git', 'java', 'mvn', 'node', 'npm', 'mysql')) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) {
        Write-Host ("  OK   {0}" -f $tool)
    } else {
        Write-Host ("  MISS {0}" -f $tool) -ForegroundColor Red
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Write-Host "`nMissing tools: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Install them first (see INSTRUCTIONS.md section 1), then re-run this script."
    exit 1
}

# Submodules present?
if (-not (Test-Path (Join-Path $repo 'ssc-booking-backend\pom.xml'))) {
    Write-Host "Submodules are empty. Running: git submodule update --init" -ForegroundColor Yellow
    Push-Location $repo
    git submodule update --init
    Pop-Location
}

# --- 2. Create database and user ---------------------------------------------
Write-Host "`n[2/6] Creating MySQL database 'ssc_booking' and user 'sscuser'..." -ForegroundColor Cyan
$rootPwd = Read-Host "Enter your MySQL root password" -AsSecureString
$rootPwdPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($rootPwd))

$sql = @'
CREATE DATABASE IF NOT EXISTS ssc_booking CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'sscuser'@'localhost' IDENTIFIED BY 'sscpassword';
CREATE USER IF NOT EXISTS 'sscuser'@'%' IDENTIFIED BY 'sscpassword';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'localhost';
GRANT ALL PRIVILEGES ON ssc_booking.* TO 'sscuser'@'%';
FLUSH PRIVILEGES;
'@
$sql | mysql -u root --password=$rootPwdPlain
if ($LASTEXITCODE -ne 0) {
    Write-Host "MySQL setup failed - check the root password and that the MySQL80 service is running." -ForegroundColor Red
    exit 1
}
Write-Host "  Database ready. (Tables are created by Flyway on first backend start.)"

# --- 3. MinIO ------------------------------------------------------------------
Write-Host "`n[3/6] Setting up MinIO..." -ForegroundColor Cyan
$minioDir = Join-Path $repo 'minio'
$minioExe = Join-Path $minioDir 'minio.exe'
New-Item -ItemType Directory -Force (Join-Path $minioDir 'data') | Out-Null
if (Test-Path $minioExe) {
    Write-Host "  minio.exe already present."
} else {
    Write-Host "  Downloading minio.exe (~110 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dl.min.io/server/minio/release/windows-amd64/minio.exe' -OutFile $minioExe
    Write-Host "  Downloaded."
}

# --- 4. Build backend jars -----------------------------------------------------
Write-Host "`n[4/6] Building Main API (downloads Maven deps on first run)..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-backend')
mvn -q clean package -DskipTests
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Backend build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  Main API jar built."

Write-Host "`n[5/6] Building File Server..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-fileserver')
mvn -q clean package -DskipTests
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "File server build failed." -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host "  File server jar built."

# --- 5. Frontend -----------------------------------------------------------------
Write-Host "`n[6/6] Installing and building the frontend..." -ForegroundColor Cyan
Push-Location (Join-Path $repo 'ssc-booking-frontend')
if (-not (Test-Path '.env.local')) {
    Copy-Item '.env.local.example' '.env.local'
    Write-Host "  Created .env.local from .env.local.example (defaults: localhost)."
}
npm install
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "npm install failed." -ForegroundColor Red; exit 1 }
npm run build
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Frontend build failed." -ForegroundColor Red; exit 1 }
Pop-Location

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "Start everything with:  powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1"
Write-Host "Then open:              http://localhost:3000/login"
