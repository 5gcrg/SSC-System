# SSC System - Terminal Monitor (XAMPP-style status dashboard)
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\monitor.ps1
#
# Standalone, read-only status view - works no matter how the services were
# started (start-all.ps1, the browser dashboard, manually, or later as
# Windows services). Never starts or stops anything on its own; press S if
# you explicitly want to stop everything, or Q / Ctrl+C to just close this
# view and leave services running.

$ErrorActionPreference = 'Stop'
$RefreshSeconds = 2

$SERVICES = @(
    @{ Name = 'MySQL';       Port = 3306; Url = 'localhost:3306';                       IsWindowsService = $true  }
    @{ Name = 'MinIO';       Port = 9000; Url = 'http://localhost:9001 (console)';       IsWindowsService = $false }
    @{ Name = 'File Server'; Port = 8080; Url = 'http://localhost:8080/actuator/health'; IsWindowsService = $false }
    @{ Name = 'Main API';    Port = 8081; Url = 'http://localhost:8081/api/v1/ping';     IsWindowsService = $false }
    @{ Name = 'Frontend';    Port = 3000; Url = 'http://localhost:3000/login';           IsWindowsService = $false }
)

function Test-PortOpen([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.Connect('127.0.0.1', $Port); return $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-PortOwnerPid([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { return $conn.OwningProcess }
    return $null
}

function Stop-AllServices {
    Write-Host "`nStopping app services (MySQL left running)..." -ForegroundColor Yellow
    foreach ($port in @(3000, 8080, 8081, 9000)) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        foreach ($procId in ($conns | Select-Object -ExpandProperty OwningProcess -Unique)) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host ("  Port {0}: stopping {1} (PID {2})" -f $port, $proc.ProcessName, $procId)
                Stop-Process -Id $procId -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host "Done.`n" -ForegroundColor Green
}

function Draw-Dashboard {
    Clear-Host
    Write-Host ''
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host '   SSC System - Service Monitor' -ForegroundColor Cyan
    Write-Host '  ===========================================' -ForegroundColor Cyan
    Write-Host ("   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
    Write-Host ''

    $nameW = 14; $portW = 6; $statusW = 10; $pidW = 8
    Write-Host ('  ' + 'SERVICE'.PadRight($nameW) + 'PORT'.PadRight($portW) + 'STATUS'.PadRight($statusW) + 'PID'.PadRight($pidW) + 'URL') -ForegroundColor White
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray

    foreach ($svc in $SERVICES) {
        $portUp = Test-PortOpen -Port $svc.Port
        $ownerPid = Get-PortOwnerPid -Port $svc.Port

        if ($svc.IsWindowsService) {
            $winSvc = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue | Select-Object -First 1
            $running = ($winSvc -and $winSvc.Status -eq 'Running') -or $portUp
        } else {
            $running = $portUp
        }

        Write-Host ('  ' + $svc.Name.PadRight($nameW)) -NoNewline
        Write-Host ($svc.Port.ToString().PadRight($portW)) -NoNewline
        if ($running) {
            Write-Host 'RUNNING'.PadRight($statusW) -NoNewline -ForegroundColor Green
        } else {
            Write-Host 'STOPPED'.PadRight($statusW) -NoNewline -ForegroundColor Red
        }
        Write-Host ($(if ($ownerPid) { $ownerPid.ToString() } else { '-' }).PadRight($pidW)) -NoNewline
        Write-Host $svc.Url
    }

    Write-Host ''
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
    Write-Host '  [Q] quit monitor (services keep running)   [S] stop all services   [R] refresh now' -ForegroundColor DarkGray
    Write-Host ("  Refreshing every {0}s..." -f $RefreshSeconds) -ForegroundColor DarkGray
}

# --- Main loop -----------------------------------------------------------------
try {
    while ($true) {
        Draw-Dashboard

        $waitedMs = 0
        $refreshMs = $RefreshSeconds * 1000
        $keyPressed = $null
        while ($waitedMs -lt $refreshMs) {
            if ([Console]::KeyAvailable) {
                $keyPressed = [Console]::ReadKey($true)
                break
            }
            Start-Sleep -Milliseconds 200
            $waitedMs += 200
        }

        if ($null -ne $keyPressed) {
            switch ($keyPressed.Key) {
                'Q' { Write-Host "`nExiting monitor. Services are untouched." -ForegroundColor Cyan; exit 0 }
                'S' { Stop-AllServices; exit 0 }
                'R' { continue }
                default { continue }
            }
        }
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
}
