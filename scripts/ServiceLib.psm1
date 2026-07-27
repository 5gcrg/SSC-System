# Shared start/stop/status logic for the SSC System's local services, used by
# start-all.ps1, monitor.ps1, and stop-all.ps1 so process-management logic
# (launching hidden, tracking PIDs, tree-killing wrapped processes like npm)
# lives in exactly one place.

$Script:RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:RunDir   = Join-Path $RepoRoot '.run'
$Script:LogDir   = Join-Path $RepoRoot 'logs'

# Root .env is gitignored and today has zero effect on anything (nothing sourced it).
# Load it into the process environment once, without overriding anything already set
# in the shell, so BACKEND_PORT/FILESERVER_PORT/etc. can be customized per-machine to
# dodge port clashes with other local projects, without touching the checked-in
# defaults that the real Windows Server deployment expects.
function Import-SscDotEnv {
    $envFile = Join-Path $RepoRoot '.env'
    if (-not (Test-Path $envFile)) { return }
    foreach ($line in Get-Content $envFile) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim()
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if (-not (Test-Path "Env:$key")) { Set-Item "Env:$key" $value }
    }
}
Import-SscDotEnv

function Get-SscEnvOrDefault([string]$Name, $Default) {
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ($val) { $val } else { $Default }
}

# Startup order matters (each depends on the one before); stop order is the reverse.
$Script:ServiceOrder = @('minio', 'fileserver', 'backend', 'frontend')

$Script:ServiceDefs = @{
    'minio'      = @{ Port = [int](Get-SscEnvOrDefault 'MINIO_PORT' 9000); ConsolePort = [int](Get-SscEnvOrDefault 'MINIO_CONSOLE_PORT' 9001) }
    'fileserver' = @{ Port = [int](Get-SscEnvOrDefault 'FILESERVER_PORT' 8080) }
    'backend'    = @{ Port = [int](Get-SscEnvOrDefault 'BACKEND_PORT' 8081) }
    'frontend'   = @{ Port = [int](Get-SscEnvOrDefault 'FRONTEND_PORT' 3000) }
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
        'minio' {
            New-Item -ItemType Directory -Force (Join-Path $RepoRoot '.tools\minio-data') | Out-Null
            # Root credentials must match the fileserver's minio.access-key/secret-key
            # (ssc-booking-fileserver\src\main\resources\application.yml); without them
            # MinIO falls back to minioadmin/minioadmin and every upload is rejected.
            $env:MINIO_ROOT_USER = if ($env:MINIO_ACCESS_KEY) { $env:MINIO_ACCESS_KEY } else { 'sscadmin' }
            $env:MINIO_ROOT_PASSWORD = if ($env:MINIO_SECRET_KEY) { $env:MINIO_SECRET_KEY } else { 'sscpassword123' }
            $minioPort = $ServiceDefs['minio'].Port
            $minioConsolePort = $ServiceDefs['minio'].ConsolePort
            return @{
                FilePath         = Join-Path $RepoRoot '.tools\minio.exe'
                ArgumentList     = @('server', (Join-Path $RepoRoot '.tools\minio-data'), '--address', ":$minioPort", '--console-address', ":$minioConsolePort")
                WorkingDirectory = $RepoRoot
            }
        }
        'fileserver' {
            $dir = Join-Path $RepoRoot 'ssc-booking-fileserver'
            $jar = Get-ChildItem (Join-Path $dir 'target\*.jar') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $jar) { throw "No jar in ssc-booking-fileserver\target - build it first (scripts\SETUP.ps1)." }
            return @{ FilePath = 'java'; ArgumentList = @('-jar', $jar.FullName); WorkingDirectory = $dir }
        }
        'backend' {
            $dir = Join-Path $RepoRoot 'ssc-booking-backend'
            $jar = Get-ChildItem (Join-Path $dir 'target\*.jar') -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $jar) { throw "No jar in ssc-booking-backend\target - build it first (scripts\SETUP.ps1)." }
            return @{ FilePath = 'java'; ArgumentList = @('-jar', $jar.FullName); WorkingDirectory = $dir }
        }
        'frontend' {
            $dir = Join-Path $RepoRoot 'ssc-booking-frontend'
            # npm is a .cmd shim on Windows; cmd.exe /c is the reliable way to launch it hidden.
            # Next reads process.env.PORT directly (before .env.local is ever parsed), so the
            # port must be a real process env var here, not a PORT= line in .env.local.
            $env:PORT = "$($ServiceDefs['frontend'].Port)"
            return @{ FilePath = 'cmd.exe'; ArgumentList = @('/c', 'npm start'); WorkingDirectory = $dir }
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
    Stop-SscService $Name
    Start-Sleep -Milliseconds 500
    Start-SscService $Name
}

function Start-AllSscServices {
    foreach ($name in $ServiceOrder) {
        Start-SscService $name
        Start-Sleep -Seconds 2
    }
}

function Stop-AllSscServices {
    for ($i = $ServiceOrder.Count - 1; $i -ge 0; $i--) {
        Stop-SscService $ServiceOrder[$i]
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
