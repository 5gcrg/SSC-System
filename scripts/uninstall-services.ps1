# SSC System - remove the Windows Services installed by install-services.ps1.
# Run from an ELEVATED PowerShell, from the repo root:
#   powershell -ExecutionPolicy Bypass -File scripts\uninstall-services.ps1
#
# Stops and removes SSC-Frontend, SSC-Backend, SSC-FileServer, SSC-MinIO
# (reverse dependency order). Does not touch MySQL - it was never
# installed by install-services.ps1, so it is not removed here either.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$nssmExe = Join-Path $repo 'nssm\nssm.exe'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script removes Windows Services and must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run:" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\uninstall-services.ps1" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $nssmExe)) {
    Write-Host "nssm.exe not found at $nssmExe - falling back to sc.exe for removal." -ForegroundColor Yellow
}

Write-Host "=== Removing SSC Windows Services ===" -ForegroundColor Cyan

foreach ($name in @('SSC-Frontend', 'SSC-Backend', 'SSC-FileServer', 'SSC-MinIO')) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "  $name -- not installed, skipping." -ForegroundColor DarkGray
        continue
    }

    Write-Host "  Stopping $name..."
    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue

    if (Test-Path $nssmExe) {
        & $nssmExe remove $name confirm 2>&1 | Out-Null
    } else {
        & sc.exe delete $name | Out-Null
    }
    Write-Host "  $name removed." -ForegroundColor Green
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "MySQL was left untouched (it was never managed by install-services.ps1)."
Write-Host "Check status:   powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1"
