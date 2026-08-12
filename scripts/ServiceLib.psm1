# Shared start/stop/status logic for the SSC System's local services, used by
# start-all.ps1, monitor.ps1, and stop-all.ps1 so process-management logic
# (launching hidden, tracking PIDs, tree-killing wrapped processes like npm)
# lives in exactly one place.

$Script:RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:RunDir   = Join-Path $RepoRoot '.run'
$Script:LogDir   = Join-Path $RepoRoot 'logs'

# --- Root .env is the single source of truth for ports and service config ----------
# Values are pushed into the current process environment so every service we launch
# inherits them: Start-Process hands the parent environment to the child, and both
# Spring Boot and MinIO read their config straight out of it.
#
# .env deliberately wins over a variable already set in the shell - re-importing the
# module after editing .env then always takes effect, instead of silently keeping a
# stale value from an earlier import in the same session.
function Import-SscDotEnv([string]$Path = (Join-Path $Script:RepoRoot '.env')) {
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        $key = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim()
        # Strip one layer of matching surrounding quotes, if present.
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or
                                      ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

Import-SscDotEnv

# Ports fall back to the same values .env ships with, so a missing .env still lands
# every service on the ports the rest of the repo documents.
function Get-SscEnvPort([string]$Name, [int]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name, 'Process')
    $parsed = 0
    if ($raw -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

# First non-empty of $Names, else $Default. Written as a function because a chained
# `if {} / elseif {}` split across lines is a parse error in an assignment context.
function Get-SscEnvOrDefault([string[]]$Names, [string]$Default) {
    foreach ($n in $Names) {
        $v = [Environment]::GetEnvironmentVariable($n, 'Process')
        if ($v) { return $v }
    }
    return $Default
}

# Startup order matters (each depends on the one before); stop order is the reverse.
$Script:ServiceOrder = @('mysql', 'minio', 'fileserver', 'backend', 'frontend')
$Script:ManagedServiceOrder = @('minio', 'fileserver', 'backend', 'frontend')

$Script:ServiceDefs = @{
    'mysql'      = @{ Port = (Get-SscEnvPort 'MYSQL_PORT'      3306) }
    'minio'      = @{ Port = (Get-SscEnvPort 'MINIO_PORT'      9006) }
    'fileserver' = @{ Port = (Get-SscEnvPort 'FILESERVER_PORT' 9005) }
    'backend'    = @{ Port = (Get-SscEnvPort 'BACKEND_PORT'    9004) }
    'frontend'   = @{ Port = (Get-SscEnvPort 'FRONTEND_PORT'   9003) }
}

function Get-SscServiceNames {
    $ServiceOrder
}

function Get-SscServicePort([string]$Name) {
    $ServiceDefs[$Name].Port
}

# --- Launch spec per service: what to run, with what args, from where -------------
function Get-SscLaunchSpec([string]$Name) {
    New-Item -ItemType Directory -Force $RunDir | Out-Null
    New-Item -ItemType Directory -Force $LogDir | Out-Null

    switch ($Name) {
        'mysql' {
            throw "MySQL is managed externally (e.g. via XAMPP Control Panel)."
        }
        'minio' {
            New-Item -ItemType Directory -Force (Join-Path $RepoRoot '.tools\minio-data') | Out-Null
            # Root credentials must match the fileserver's minio.access-key/secret-key
            # (ssc-booking-fileserver\src\main\resources\application.yml); without them
            # MinIO falls back to minioadmin/minioadmin and every upload is rejected.
            $env:MINIO_ROOT_USER = Get-SscEnvOrDefault @('MINIO_ACCESS_KEY', 'MINIO_ROOT_USER') 'sscadmin'
            $env:MINIO_ROOT_PASSWORD = Get-SscEnvOrDefault @('MINIO_SECRET_KEY', 'MINIO_ROOT_PASSWORD') 'sscpassword123'
            # --address is required: without it MinIO binds its API to 9000 no matter
            # what MINIO_PORT says, and every port check here would look at the wrong one.
            $consolePort = Get-SscEnvPort 'MINIO_CONSOLE_PORT' 9007
            return @{
                FilePath         = Join-Path $RepoRoot '.tools\minio.exe'
                ArgumentList     = @('server', (Join-Path $RepoRoot '.tools\minio-data'),
                                     '--address', ":$(Get-SscServicePort 'minio')",
                                     '--console-address', ":$consolePort")
                WorkingDirectory = $RepoRoot
            }
        }
        'fileserver' {
            $dir = Join-Path $RepoRoot 'ssc-booking-fileserver'
            $jar = Get-ChildItem (Join-Path $dir 'target\*.jar') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $jar) { throw "No jar in ssc-booking-fileserver\target - build it first (scripts\SETUP.ps1)." }
            # --server.port is passed explicitly so the process can never end up on a port
            # other than the one Get-SscServiceStatus and monitor.ps1 health-check.
            return @{
                FilePath         = 'java'
                ArgumentList     = @('-jar', $jar.FullName, "--server.port=$(Get-SscServicePort 'fileserver')")
                WorkingDirectory = $dir
            }
        }
        'backend' {
            $dir = Join-Path $RepoRoot 'ssc-booking-backend'
            $jar = Get-ChildItem (Join-Path $dir 'target\*.jar') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $jar) { throw "No jar in ssc-booking-backend\target - build it first (scripts\SETUP.ps1)." }
            return @{
                FilePath         = 'java'
                ArgumentList     = @('-jar', $jar.FullName, "--server.port=$(Get-SscServicePort 'backend')")
                WorkingDirectory = $dir
            }
        }
        'frontend' {
            $dir = Join-Path $RepoRoot 'ssc-booking-frontend'
            # npm is a .cmd shim on Windows; cmd.exe /c is the reliable way to launch it hidden.
            # -p is what actually decides the port - `next start` reads the flag before any
            # .env file, so this beats relying on PORT being picked up.
            return @{
                FilePath         = 'cmd.exe'
                ArgumentList     = @('/c', "npm start -- -p $(Get-SscServicePort 'frontend')")
                WorkingDirectory = $dir
            }
        }
        default { throw "Unknown service '$Name'." }
    }
}

# --- State persistence (one JSON file per service under .run\) --------------------
function Get-SscStatePath([string]$Name) { Join-Path $RunDir "$Name.json" }

function Get-SscServiceState([string]$Name) {
    $path = Get-SscStatePath $Name
    if (-not (Test-Path $path)) { return $null }
    try { Get-Content $path -Raw | ConvertFrom-Json } catch { $null }
}

function Save-SscServiceState([string]$Name, [int]$ProcessId) {
    New-Item -ItemType Directory -Force $RunDir | Out-Null
    [PSCustomObject]@{
        pid       = $ProcessId
        startedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content (Get-SscStatePath $Name)
}

function Remove-SscServiceState([string]$Name) {
    Remove-Item (Get-SscStatePath $Name) -ErrorAction SilentlyContinue
}

# --- Fast, non-blocking TCP port check (avoids Test-NetConnection's ~1s+ overhead) -
function Test-SscPort([int]$Port, [int]$TimeoutMs = 250) {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected
        $client.Close()
        return [bool]$ok
    } catch {
        return $false
    }
}

# Finds whichever PID actually owns the listening socket on a port, regardless of
# whether we're the ones tracking it - used to detect services already running
# outside this tooling (started manually, or by something else) before we try to
# launch a duplicate that would just crash with "port already in use".
function Get-SscPortOwnerPid([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty OwningProcess
    if ($conn) { return $conn }
    return $null
}

function Get-SscServiceStatus([string]$Name) {
    if ($Name -eq 'mysql') {
        $port = Get-SscServicePort 'mysql'
        $pid = Get-SscPortOwnerPid $port
        if (Test-SscPort $port) {
            return [PSCustomObject]@{ Name = 'mysql'; Status = 'RUNNING'; ProcessId = $pid; Port = $port }
        }
        return [PSCustomObject]@{ Name = 'mysql'; Status = 'STOPPED'; ProcessId = $null; Port = $port }
    }
    $state = Get-SscServiceState $Name
    $port = Get-SscServicePort $Name
    if (-not $state) {
        $externalPid = Get-SscPortOwnerPid $port
        if ($externalPid) {
            return [PSCustomObject]@{ Name = $Name; Status = 'EXTERNAL'; ProcessId = $externalPid; Port = $port }
        }
        return [PSCustomObject]@{ Name = $Name; Status = 'STOPPED'; ProcessId = $null; Port = $port }
    }
    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Remove-SscServiceState $Name
        return [PSCustomObject]@{ Name = $Name; Status = 'STOPPED'; ProcessId = $null; Port = $port }
    }
    $status = if (Test-SscPort $port) { 'RUNNING' } else { 'STARTING' }
    return [PSCustomObject]@{ Name = $Name; Status = $status; ProcessId = $state.pid; Port = $port }
}

# --- Start / stop / restart ---------------------------------------------------------
function Start-SscService([string]$Name) {
    if ($Name -eq 'mysql') {
        $port = Get-SscServicePort 'mysql'
        if (Test-SscPort $port) {
            Write-Host ("  mysql: already running on port {0} (XAMPP / local service)." -f $port) -ForegroundColor Green
        } else {
            Write-Host ("  mysql: NOT running on port {0}. Please start MySQL in XAMPP Control Panel!" -f $port) -ForegroundColor Red
        }
        return
    }
    $existing = Get-SscServiceStatus $Name
    if ($existing.Status -eq 'EXTERNAL') {
        Write-Host ("  {0}: port {1} is already in use by PID {2}, which this tool didn't start - leaving it alone. Stop it manually first if you want this tool to manage it." -f $Name, $existing.Port, $existing.ProcessId) -ForegroundColor Yellow
        return
    }
    if ($existing.Status -ne 'STOPPED') {
        Write-Host ("  {0} already running (PID {1})." -f $Name, $existing.ProcessId) -ForegroundColor Yellow
        return
    }
    $spec = Get-SscLaunchSpec $Name
    $outLog = Join-Path $LogDir "$Name.log"
    $errLog = Join-Path $LogDir "$Name.err.log"
    $proc = Start-Process -FilePath $spec.FilePath -ArgumentList $spec.ArgumentList `
        -WorkingDirectory $spec.WorkingDirectory -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
    Save-SscServiceState -Name $Name -ProcessId $proc.Id
    Write-Host ("  {0} started (PID {1}). Logs: logs\{0}.log" -f $Name, $proc.Id) -ForegroundColor Green
}

function Stop-SscService([string]$Name) {
    if ($Name -eq 'mysql') {
        Write-Host "  mysql: managed externally (e.g. XAMPP). Stop it from XAMPP Control Panel if needed." -ForegroundColor Yellow
        return
    }
    $state = Get-SscServiceState $Name
    if ($state -and (Get-Process -Id $state.pid -ErrorAction SilentlyContinue)) {
        # taskkill /T kills the whole process tree - needed because frontend/minio/java
        # are launched through a wrapper (cmd.exe -> npm.cmd -> node.exe) and Stop-Process
        # alone would only kill the wrapper, orphaning the real process underneath.
        & taskkill /PID $state.pid /T /F *> $null
        Write-Host ("  {0} stopped (PID {1})." -f $Name, $state.pid) -ForegroundColor Green
    } else {
        $externalPid = Get-SscPortOwnerPid (Get-SscServicePort $Name)
        if ($externalPid) {
            Write-Host ("  {0}: not managed by this tool (port owned by untracked PID {1}) - not touching it." -f $Name, $externalPid) -ForegroundColor Yellow
            return
        }
        Write-Host ("  {0} was not running." -f $Name)
    }
    Remove-SscServiceState $Name
}

function Restart-SscService([string]$Name) {
    if ($Name -eq 'mysql') {
        Write-Host "  mysql: managed externally. Please restart it via XAMPP Control Panel." -ForegroundColor Yellow
        return
    }
    Stop-SscService $Name
    Start-Sleep -Milliseconds 500
    Start-SscService $Name
}

function Start-AllSscServices {
    $mysqlPort = Get-SscServicePort 'mysql'
    if (-not (Test-SscPort $mysqlPort)) {
        Write-Host "  [WARNING] MySQL is NOT running on port $mysqlPort!" -ForegroundColor Red
        Write-Host "  Please start MySQL in XAMPP Control Panel for backend database connectivity.`n" -ForegroundColor Yellow
    } else {
        Write-Host "  OK      MySQL service detected on port $mysqlPort (XAMPP / local)." -ForegroundColor Green
    }
    foreach ($name in $Script:ManagedServiceOrder) {
        Start-SscService $name
        Start-Sleep -Seconds 2
    }
}

function Stop-AllSscServices {
    for ($i = $Script:ManagedServiceOrder.Count - 1; $i -ge 0; $i--) {
        Stop-SscService $Script:ManagedServiceOrder[$i]
    }
}

function Restart-AllSscServices {
    Stop-AllSscServices
    Start-Sleep -Seconds 1
    Start-AllSscServices
}

Export-ModuleMember -Function `
    Get-SscServiceNames, Get-SscServicePort, Get-SscServiceStatus, `
    Start-SscService, Stop-SscService, Restart-SscService, `
    Start-AllSscServices, Stop-AllSscServices, Restart-AllSscServices, `
    Test-SscPort
