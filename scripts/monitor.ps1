# Live status dashboard for the SSC System's background services. Auto-refreshes,
# and lets you restart all services, restart one specific service, or stop all -
# without needing separate start-all.ps1/stop-all.ps1 calls.
#   powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1
#
# Can be run standalone at any time to reattach to whatever's already running -
# status is read from .run\*.json + a live process/port check, not tied to how
# the services were originally started.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ServiceLib.psm1') -Force

function Read-KeyWithTimeout([int]$TimeoutSeconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ([Console]::KeyAvailable) {
            return [Console]::ReadKey($true)
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Show-Dashboard {
    Clear-Host
    Write-Host "=== SSC System Monitor ===" -ForegroundColor Cyan
    Write-Host "Updated: $(Get-Date -Format 'HH:mm:ss')`n"

    Get-SscServiceNames | ForEach-Object { Get-SscServiceStatus $_ } |
        Format-Table -Property Name, Status, ProcessId, Port -AutoSize | Out-Host

    Write-Host "[1] Restart ALL   [2] Restart one   [3] Stop ALL   [4] Refresh now   [Q] Quit monitor (services keep running)"
}

while ($true) {
    Show-Dashboard
    $key = Read-KeyWithTimeout -TimeoutSeconds 5
    if ($null -eq $key) { continue }

    switch ($key.KeyChar.ToString().ToUpperInvariant()) {
        '1' {
            Write-Host "`nRestarting all services...`n" -ForegroundColor Yellow
            Restart-AllSscServices
            Start-Sleep -Seconds 2
        }
        '2' {
            $names = Get-SscServiceNames
            Write-Host ("`nWhich service? ({0})" -f ($names -join ', '))
            $choice = Read-Host 'Name'
            if ($names -contains $choice) {
                Write-Host "`nRestarting $choice...`n" -ForegroundColor Yellow
                Restart-SscService $choice
                Start-Sleep -Seconds 2
            } else {
                Write-Host "`nUnknown service '$choice'." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
        '3' {
            Write-Host "`nStopping all services...`n" -ForegroundColor Yellow
            Stop-AllSscServices
            Start-Sleep -Seconds 2
        }
        '4' { }
        'Q' { Write-Host "`nExiting monitor (services keep running in the background)." -ForegroundColor Cyan; return }
        default { }
    }
}
