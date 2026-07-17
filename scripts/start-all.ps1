# SSC Event Booking System - start all services (bare-metal Windows).
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1
# Starts every service hidden in the background (no per-service windows),
# in dependency order: MySQL (service) -> MinIO -> File Server -> Main API
# -> Frontend, then hands off into scripts\monitor.ps1 for a single live
# status dashboard. Each service's output goes to logs\<service>.log.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $repo 'logs'
New-Item -ItemType Directory -Force $logsDir | Out-Null

function Wait-Port([int]$Port, [string]$Name, [int]$TimeoutSec = 90) {
    Write-Host ("  waiting for {0} on port {1}..." -f $Name, $Port) -NoNewline
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            if ($client.Connected) { $client.Close(); Write-Host " up." -ForegroundColor Green; return $true }
        } catch {} finally { $client.Dispose() }
        Start-Sleep -Seconds 2
    }
    Write-Host " TIMED OUT after ${TimeoutSec}s." -ForegroundColor Red
    return $false
}

function Test-PortOpen([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.Connect('127.0.0.1', $Port); return $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

Write-Host "=== Starting SSC System ===" -ForegroundColor Cyan

# --- MySQL (Windows service) ---------------------------------------------------
$mysqlSvc = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mysqlSvc -and $mysqlSvc.Status -ne 'Running') {
    Write-Host "Starting MySQL service ($($mysqlSvc.Name))..."
    try {
        Start-Service $mysqlSvc.Name -ErrorAction Stop
    } catch {
        Write-Host "  Warning: could not start MySQL service — run this script as Administrator" -ForegroundColor Yellow
        Write-Host "  or start MySQL manually, then re-run." -ForegroundColor Yellow
    }
}
if (-not (Wait-Port 3306 'MySQL')) { Write-Host "MySQL is not reachable — start it first (run as Administrator if using a Windows service)."; exit 1 }

# --- MinIO -----------------------------------------------------------------------
if (Test-PortOpen 9000) {
    Write-Host "MinIO already running on 9000 - skipping."
} else {
    $minioExe = Join-Path $repo 'minio\minio.exe'
    if (-not (Test-Path $minioExe)) { Write-Host "minio.exe not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoLogo', '-NoProfile', '-Command', @"
`$env:MINIO_ROOT_USER = 'sscadmin'
`$env:MINIO_ROOT_PASSWORD = 'sscpassword123'
& '$minioExe' server '$repo\minio\data' --console-address ':9001' *>> '$logsDir\minio.log'
"@
    if (-not (Wait-Port 9000 'MinIO')) { exit 1 }
}

# --- File Server (8080) ----------------------------------------------------------
if (Test-PortOpen 8080) {
    Write-Host "File Server already running on 8080 - skipping."
} else {
    $fsJar = Get-ChildItem (Join-Path $repo 'ssc-booking-fileserver\target') -Filter '*.jar' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike '*sources*' } | Select-Object -First 1
    if (-not $fsJar) { Write-Host "File server jar not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
    $javaExe = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoLogo', '-NoProfile', '-Command', @"
Set-Location '$repo\ssc-booking-fileserver'
& '$javaExe' -jar '$($fsJar.FullName)' *>> '$logsDir\fileserver.log'
"@
    if (-not (Wait-Port 8080 'File Server')) { exit 1 }
}

# --- Main API (8081) --------------------------------------------------------------
if (Test-PortOpen 8081) {
    Write-Host "Main API already running on 8081 - skipping."
} else {
    $beJar = Get-ChildItem (Join-Path $repo 'ssc-booking-backend\target') -Filter '*.jar' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike '*sources*' } | Select-Object -First 1
    if (-not $beJar) { Write-Host "Backend jar not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
    $javaExe = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoLogo', '-NoProfile', '-Command', @"
Set-Location '$repo\ssc-booking-backend'
& '$javaExe' -jar '$($beJar.FullName)' *>> '$logsDir\backend.log'
"@
    # First start runs all Flyway migrations, allow extra time
    if (-not (Wait-Port 8081 'Main API' 180)) { exit 1 }
}

# --- Frontend (3000) ----------------------------------------------------------------
if (Test-PortOpen 3000) {
    Write-Host "Frontend already running on 3000 - skipping."
} else {
    if (-not (Test-Path (Join-Path $repo 'ssc-booking-frontend\.next'))) {
        Write-Host "Frontend build not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1
    }
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoLogo', '-NoProfile', '-Command', @"
Set-Location '$repo\ssc-booking-frontend'
npm run start *>> '$logsDir\frontend.log'
"@
    if (-not (Wait-Port 3000 'Frontend')) { exit 1 }
}

Write-Host "`n=== All services up ===" -ForegroundColor Green
Write-Host "Logs: $logsDir\*.log"
Write-Host "Launching status dashboard...`n" -ForegroundColor Cyan
Start-Sleep -Seconds 1
& (Join-Path $PSScriptRoot 'monitor.ps1')
