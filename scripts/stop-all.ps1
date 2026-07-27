# Stops all SSC System background services started by start-all.ps1 / monitor.ps1.
#   powershell -ExecutionPolicy Bypass -File scripts\stop-all.ps1

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ServiceLib.psm1') -Force

Write-Host "=== Stopping SSC System services ===" -ForegroundColor Cyan
Stop-AllSscServices
Write-Host "`nAll services stopped." -ForegroundColor Green
