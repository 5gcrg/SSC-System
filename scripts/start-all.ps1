# Starts MinIO, the file server, the main API, and the frontend as hidden background
# processes (no per-service terminal windows), then hands off to the live monitor.
#   powershell -ExecutionPolicy Bypass -File scripts\start-all.ps1

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ServiceLib.psm1') -Force

Write-Host "=== Starting SSC System services ===" -ForegroundColor Cyan
Start-AllSscServices

Write-Host "`nAll services started. Opening monitor...`n" -ForegroundColor Green
Start-Sleep -Seconds 1
& (Join-Path $PSScriptRoot 'monitor.ps1')
