# SSC System - install Windows Services via NSSM (auto-start on boot).
# Run from an ELEVATED PowerShell, from the repo root:
#   powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1
#
# Registers MinIO, File Server, Main API, and Frontend as real Windows
# Services (auto-start, restart-on-crash), with dependencies so Windows
# sequences startup correctly on boot. MySQL is not managed here - it is
# already its own native Windows service from the MySQL installer.
#
# Requires scripts\setup.ps1 to have already been run at least once
# (needs the built jars and frontend .next output to exist).
#
# To remove everything this script installs: scripts\uninstall-services.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $repo 'logs'
$nssmDir = Join-Path $repo 'nssm'
$nssmExe = Join-Path $nssmDir 'nssm.exe'

# --- Elevation check -----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script installs Windows Services and must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run:" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force $logsDir | Out-Null

# --- Download NSSM if missing ----------------------------------------------------
if (-not (Test-Path $nssmExe)) {
    Write-Host "Downloading NSSM..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $nssmDir | Out-Null
    $zipPath = Join-Path $nssmDir 'nssm.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $nssmDir -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $extracted = Join-Path $nssmDir "nssm-2.24\$arch\nssm.exe"
    if (-not (Test-Path $extracted)) { Write-Host "NSSM download did not contain the expected exe - check $nssmDir manually." -ForegroundColor Red; exit 1 }
    Copy-Item $extracted $nssmExe -Force
    Remove-Item $zipPath -Force
    Remove-Item (Join-Path $nssmDir 'nssm-2.24') -Recurse -Force
    Write-Host "  NSSM ready." -ForegroundColor Green
} else {
    Write-Host "NSSM already present." -ForegroundColor Green
}

# --- Resolve paths ---------------------------------------------------------------
$javaExe = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { (Get-Command java -ErrorAction SilentlyContinue).Source }
if (-not $javaExe -or -not (Test-Path $javaExe)) { Write-Host "Could not resolve java.exe - set JAVA_HOME and re-run." -ForegroundColor Red; exit 1 }

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = 'C:\Program Files\nodejs\node.exe' }
if (-not (Test-Path $nodeExe)) { Write-Host "Could not resolve node.exe - is Node.js installed?" -ForegroundColor Red; exit 1 }

$fsJar = Get-ChildItem (Join-Path $repo 'ssc-booking-fileserver\target') -Filter '*.jar' -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notlike '*sources*' } | Select-Object -First 1
$beJar = Get-ChildItem (Join-Path $repo 'ssc-booking-backend\target') -Filter '*.jar' -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notlike '*sources*' } | Select-Object -First 1
$nextBin = Join-Path $repo 'ssc-booking-frontend\node_modules\next\dist\bin\next'
$minioExe = Join-Path $repo 'minio\minio.exe'

if (-not $fsJar) { Write-Host "File server jar not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
if (-not $beJar) { Write-Host "Backend jar not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $nextBin)) { Write-Host "Frontend not built - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $minioExe)) { Write-Host "minio.exe not found - run scripts\setup.ps1 first." -ForegroundColor Red; exit 1 }

# --- Port conflict check ---------------------------------------------------------
# None of these 4 services exist as Windows Services yet on a fresh install, so
# anything already listening on their ports right now must be a manually-started
# process (start-all.ps1, the browser dashboard, etc.) that will make the new
# services fail to bind and crash-loop with a confusing "address already in use"
# buried in their logs. Catch it here instead, with a clear fix.
$portConflicts = @()
foreach ($portCheck in @(
    @{ Port = 9000; Service = 'SSC-MinIO' }
    @{ Port = 8080; Service = 'SSC-FileServer' }
    @{ Port = 8081; Service = 'SSC-Backend' }
    @{ Port = 3000; Service = 'SSC-Frontend' }
)) {
    $conn = Get-NetTCPConnection -LocalPort $portCheck.Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { $portConflicts += "$($portCheck.Service) needs port $($portCheck.Port), already in use (PID $($conn.OwningProcess -join ', '))" }
}
if ($portConflicts.Count -gt 0) {
    Write-Host "Port conflict - stop whatever's already running first:" -ForegroundColor Red
    $portConflicts | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "`nRun 'scripts\stop-all.ps1' (stops manually-started processes) and re-run this script." -ForegroundColor Yellow
    exit 1
}

$mysqlSvc = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mysqlSvc) {
    Write-Host "Warning: no MySQL Windows service found - SSC-Backend will install without a MySQL dependency." -ForegroundColor Yellow
    Write-Host "  Make sure MySQL is running some other way before SSC-Backend starts." -ForegroundColor Yellow
}

# --- Helper: install or reconfigure a service -------------------------------------
function Install-NssmService {
    param(
        [string]$Name,
        [string]$Application,
        [string]$Arguments,
        [string]$WorkingDir,
        [string[]]$DependsOn = @(),
        [hashtable]$ExtraEnv = $null
    )

    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  $Name already installed - stopping and removing to reconfigure." -ForegroundColor Yellow
        & $nssmExe stop $Name confirm 2>&1 | Out-Null
        & $nssmExe remove $Name confirm 2>&1 | Out-Null
    }

    & $nssmExe install $Name $Application | Out-Null
    & $nssmExe set $Name AppParameters $Arguments | Out-Null
    & $nssmExe set $Name AppDirectory $WorkingDir | Out-Null
    & $nssmExe set $Name AppStdout (Join-Path $logsDir "$($Name.ToLower()).log") | Out-Null
    & $nssmExe set $Name AppStderr (Join-Path $logsDir "$($Name.ToLower()).err.log") | Out-Null
    & $nssmExe set $Name AppRotateFiles 1 | Out-Null
    & $nssmExe set $Name Start SERVICE_AUTO_START | Out-Null

    if ($ExtraEnv) {
        $envLines = ($ExtraEnv.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n"
        & $nssmExe set $Name AppEnvironmentExtra $envLines | Out-Null
    }

    if ($DependsOn.Count -gt 0) {
        # NSSM's DependOnService takes each dependency as its own argument -
        # NOT a single slash- or comma-joined string (that gets treated as one
        # literal, invalid service name and fails with "dependency service
        # does not exist").
        & $nssmExe set $Name DependOnService @DependsOn | Out-Null
    }

    Write-Host "  $Name configured." -ForegroundColor Green
}

Write-Host "`n=== Installing SSC Windows Services ===" -ForegroundColor Cyan

Install-NssmService -Name 'SSC-MinIO' `
    -Application $minioExe `
    -Arguments "server `"$repo\minio\data`" --console-address :9001" `
    -WorkingDir (Join-Path $repo 'minio') `
    -ExtraEnv @{ MINIO_ROOT_USER = 'sscadmin'; MINIO_ROOT_PASSWORD = 'sscpassword123' }

Install-NssmService -Name 'SSC-FileServer' `
    -Application $javaExe `
    -Arguments "-jar `"$($fsJar.FullName)`"" `
    -WorkingDir (Join-Path $repo 'ssc-booking-fileserver') `
    -DependsOn @('SSC-MinIO')

$backendDeps = @('SSC-FileServer')
if ($mysqlSvc) { $backendDeps = @($mysqlSvc.Name) + $backendDeps }
Install-NssmService -Name 'SSC-Backend' `
    -Application $javaExe `
    -Arguments "-jar `"$($beJar.FullName)`"" `
    -WorkingDir (Join-Path $repo 'ssc-booking-backend') `
    -DependsOn $backendDeps

Install-NssmService -Name 'SSC-Frontend' `
    -Application $nodeExe `
    -Arguments "`"$nextBin`" start" `
    -WorkingDir (Join-Path $repo 'ssc-booking-frontend') `
    -DependsOn @('SSC-Backend')

Write-Host "`nStarting services..." -ForegroundColor Cyan
foreach ($name in @('SSC-MinIO', 'SSC-FileServer', 'SSC-Backend', 'SSC-Frontend')) {
    try {
        Start-Service -Name $name -ErrorAction Stop
        Write-Host "  $name started." -ForegroundColor Green
    } catch {
        Write-Host "  $name failed to start: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Check logs\$($name.ToLower()).err.log" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Check status:   powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1"
Write-Host "View in GUI:    services.msc"
Write-Host "Remove:         powershell -ExecutionPolicy Bypass -File scripts\uninstall-services.ps1"
