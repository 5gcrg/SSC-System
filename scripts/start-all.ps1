# SSC Event Booking System - start all services (bare-metal Windows).
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1
# Opens one window per service, in dependency order:
#   MySQL (service) -> MinIO -> File Server -> Main API -> Frontend

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

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
    Start-Process powershell -ArgumentList '-NoExit', '-Command', @"
`$host.UI.RawUI.WindowTitle = 'SSC - MinIO'
`$env:MINIO_ROOT_USER = 'sscadmin'
`$env:MINIO_ROOT_PASSWORD = 'sscpassword123'
& '$minioExe' server '$repo\minio\data' --console-address ':9001'
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
    Start-Process powershell -ArgumentList '-NoExit', '-Command', @"
`$host.UI.RawUI.WindowTitle = 'SSC - File Server (8080)'
Set-Location '$repo\ssc-booking-fileserver'
& '$javaExe' -jar '$($fsJar.FullName)'
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
    Start-Process powershell -ArgumentList '-NoExit', '-Command', @"
`$host.UI.RawUI.WindowTitle = 'SSC - Main API (8081)'
Set-Location '$repo\ssc-booking-backend'
& '$javaExe' -jar '$($beJar.FullName)'
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
    Start-Process powershell -ArgumentList '-NoExit', '-Command', @"
`$host.UI.RawUI.WindowTitle = 'SSC - Frontend (3000)'
Set-Location '$repo\ssc-booking-frontend'
npm run start
"@
    if (-not (Wait-Port 3000 'Frontend')) { exit 1 }
}

Write-Host "`n=== All services up ===" -ForegroundColor Green
Write-Host "Frontend:      http://localhost:3000/login"
Write-Host "Main API:      http://localhost:8081/api/v1/ping"
Write-Host "File Server:   http://localhost:8080/actuator/health"
Write-Host "MinIO console: http://localhost:9001  (sscadmin / sscpassword123)"
