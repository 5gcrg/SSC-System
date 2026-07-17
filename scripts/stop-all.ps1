# SSC Event Booking System — stop all app services.
# Stops whatever is listening on the app ports (3000, 8080, 8081, 9000).
# Leaves the MySQL Windows service running (stop it via services.msc if needed).

$ports = @(3000, 8080, 8081, 9000)

foreach ($port in $ports) {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Host ("Port {0}: nothing running." -f $port)
        continue
    }
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($procId in $pids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host ("Port {0}: stopping {1} (PID {2})" -f $port, $proc.ProcessName, $procId)
            Stop-Process -Id $procId -Force -Confirm:$false
        }
    }
}

Write-Host "Done. (MySQL service left running.)"
