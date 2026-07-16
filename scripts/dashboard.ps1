# SSC System — Dashboard Launcher
# Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File scripts\dashboard.ps1
#
# Opens a browser dashboard at http://localhost:9999 that lets you
# start, stop, and monitor all services without juggling separate terminals.

$ErrorActionPreference = 'Stop'
$serverScript = Join-Path $PSScriptRoot 'dashboard-server.js'

# ── Prerequisite check ────────────────────────────────────────────────────────
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  Node.js is required to run the dashboard server.' -ForegroundColor Red
    Write-Host '  Install it from https://nodejs.org/ (v18 LTS or newer), then re-run.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if (-not (Test-Path $serverScript)) {
    Write-Host "dashboard-server.js not found at: $serverScript" -ForegroundColor Red
    exit 1
}

$nodeVersion = node --version 2>$null
Write-Host ''
Write-Host '  SSC System — Service Dashboard' -ForegroundColor Cyan
Write-Host "  Node.js $nodeVersion detected." -ForegroundColor DarkGray
Write-Host '  Server starting on http://localhost:9999 ...' -ForegroundColor Cyan
Write-Host '  Press Ctrl+C to stop the dashboard.' -ForegroundColor DarkGray
Write-Host ''

# ── Open browser after a short delay (fire and forget) ───────────────────────
$null = Start-Job -ScriptBlock {
    Start-Sleep -Milliseconds 900
    Start-Process 'http://localhost:9999'
}

# ── Run the Node.js server (blocking — keeps this terminal alive) ─────────────
node $serverScript
