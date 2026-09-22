# Production-oriented build and launcher for the existing Windows deployment.
# This deliberately never creates databases, changes grants, downloads binaries,
# or stops existing processes. Use a service manager for unattended auto-restart.
# Examples:
#   .\scripts\production.ps1 -Action Build  -ConfigPath C:\ProgramData\SSC-System\production.env
#   .\scripts\production.ps1 -Action Validate -ConfigPath C:\ProgramData\SSC-System\production.env
#   .\scripts\production.ps1 -Action Check  -ConfigPath C:\ProgramData\SSC-System\production.env
#   .\scripts\production.ps1 -Action Start  -ConfigPath C:\ProgramData\SSC-System\production.env
#   .\scripts\production.ps1 -Action Status -ConfigPath C:\ProgramData\SSC-System\production.env

param(
    [ValidateSet('Validate', 'Check', 'Build', 'Start', 'Status')]
    [string]$Action = 'Validate',
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeDir = Join-Path $repoRoot '.run\production'
$logDir = Join-Path $repoRoot 'logs'

function Read-ProductionConfig([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $repoPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Keep the production environment file outside the Git repository (for example, C:\ProgramData\SSC-System\production.env).'
    }
    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $resolved) {
        $item = $line.Trim()
        if (-not $item -or $item.StartsWith('#')) { continue }
        if ($item -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Invalid production environment line. Use KEY=value (without spaces around '=')."
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($settings.ContainsKey($key)) { throw "Duplicate production setting: $key" }
        $settings[$key] = $value
    }
    return $settings
}

function Require-Setting($Settings, [string]$Name) {
    $value = $Settings[$Name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '(?i:CHANGE_ME|REPLACE_ME|YOUR_)') {
        throw "Production setting $Name is missing or still a placeholder."
    }
    return $value
}

function Get-Port($Settings, [string]$Name, [int]$Default) {
    if (-not $Settings.ContainsKey($Name)) { return $Default }
    $port = 0
    if (-not [int]::TryParse($Settings[$Name], [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "$Name must be a TCP port from 1 to 65535."
    }
    return $port
}

function Require-Url([string]$Value, [string]$Name, [string]$Scheme) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne $Scheme) {
        throw "$Name must be an absolute $Scheme URL."
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw "$Name must not contain credentials, a query, or a fragment."
    }
    return $uri
}

function Test-Configuration($Settings) {
    $required = @('DB_URL', 'DB_USERNAME', 'DB_PASSWORD', 'JWT_SECRET',
        'GOOGLE_CLIENT_ID', 'NEXT_PUBLIC_GOOGLE_CLIENT_ID', 'FRONTEND_URL',
        'API_URL', 'FILESERVER_URL', 'MINIO_URL', 'MINIO_PUBLIC_URL',
        'MINIO_ROOT_USER', 'MINIO_ROOT_PASSWORD', 'MINIO_ACCESS_KEY', 'MINIO_SECRET_KEY',
        'MINIO_DATA_DIR')
    foreach ($name in $required) { $null = Require-Setting $Settings $name }

    if ($Settings['JWT_SECRET'].Length -lt 32 -or $Settings['JWT_SECRET'] -like '*dev-secret*') {
        throw 'JWT_SECRET must be a unique random secret of at least 32 characters.'
    }
    foreach ($name in @('DB_PASSWORD', 'MINIO_ROOT_PASSWORD', 'MINIO_SECRET_KEY')) {
        if ($Settings[$name] -in @('root', 'password', 'sscpassword', 'sscpassword123', 'minioadmin')) {
            throw "$name still uses a known development password."
        }
    }
    if ($Settings['GOOGLE_CLIENT_ID'] -ne $Settings['NEXT_PUBLIC_GOOGLE_CLIENT_ID']) {
        throw 'GOOGLE_CLIENT_ID and NEXT_PUBLIC_GOOGLE_CLIENT_ID must match.'
    }
    if (-not [IO.Path]::IsPathRooted($Settings['MINIO_DATA_DIR'])) {
        throw 'MINIO_DATA_DIR must be an absolute path.'
    }
    $storagePath = [IO.Path]::GetFullPath($Settings['MINIO_DATA_DIR'])
    $repoPrefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    if ($storagePath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'MINIO_DATA_DIR must be outside the repository for production use.'
    }
    $frontendUri = Require-Url $Settings['FRONTEND_URL'] 'FRONTEND_URL' 'https'
    $null = Require-Url $Settings['MINIO_PUBLIC_URL'] 'MINIO_PUBLIC_URL' 'https'
    if ($Settings['FRONTEND_URL'] -match '(?i:example\.)' -or
        $Settings['MINIO_PUBLIC_URL'] -match '(?i:example\.)') {
        throw 'Replace the example frontend and MinIO domains with real HTTPS hostnames.'
    }
    if ($frontendUri.Host -in @('localhost', '127.0.0.1') -or
        ([Uri]$Settings['MINIO_PUBLIC_URL']).Host -in @('localhost', '127.0.0.1')) {
        throw 'Public frontend and MinIO URLs must use real HTTPS hostnames, not localhost.'
    }
    if ($frontendUri.AbsolutePath -ne '/') { throw 'FRONTEND_URL must be the origin only, without a path.' }
    if ($Settings['DB_URL'] -notmatch '^jdbc:mysql://([^/:?]+)(?::([0-9]+))?/([^?]+)') {
        throw 'DB_URL must be a jdbc:mysql://host:port/database URL.'
    }
    $dbHost = $Matches[1]
    $dbPort = if ($Matches[2]) { [int]$Matches[2] } else { 3306 }
    $dbName = $Matches[3]
    if ($dbPort -lt 1 -or $dbPort -gt 65535 -or $dbName -notmatch '^[A-Za-z0-9_]+$') {
        throw 'DB_URL has an invalid port or database name.'
    }

    $ports = [ordered]@{
        Minio = Get-Port $Settings 'MINIO_PORT' 9006
        MinioConsole = Get-Port $Settings 'MINIO_CONSOLE_PORT' 9007
        FileServer = Get-Port $Settings 'FILESERVER_PORT' 9005
        Backend = Get-Port $Settings 'BACKEND_PORT' 9004
        Frontend = Get-Port $Settings 'FRONTEND_PORT' 9003
    }
    if (@($ports.Values | Select-Object -Unique).Count -ne $ports.Count) {
        throw 'Production service ports must all be distinct.'
    }
    foreach ($pair in @(
        @('API_URL', $ports.Backend),
        @('FILESERVER_URL', $ports.FileServer),
        @('MINIO_URL', $ports.Minio))) {
        $uri = Require-Url $Settings[$pair[0]] $pair[0] 'http'
        if ($uri.Host -notin @('127.0.0.1', 'localhost') -or $uri.Port -ne $pair[1] -or $uri.AbsolutePath -ne '/') {
            throw "$($pair[0]) must point to the corresponding local service on port $($pair[1])."
        }
    }
    return [PSCustomObject]@{ DbHost = $dbHost; DbPort = $dbPort; DbName = $dbName;
        Ports = $ports; MinioDataDir = $storagePath }
}

function Apply-ProductionEnvironment($Settings) {
    foreach ($entry in $Settings.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    # Do not let inherited development overrides silently defeat application-prod.yml.
    foreach ($name in @('SPRING_DATASOURCE_URL', 'SPRING_DATASOURCE_USERNAME', 'SPRING_DATASOURCE_PASSWORD')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $env:SPRING_PROFILES_ACTIVE = 'prod'
    $env:NODE_ENV = 'production'
    $env:JWT_COOKIE_SECURE = 'true'
    $env:DEV_ENDPOINTS_ENABLED = 'false'
    $env:ALLOWED_ORIGINS = $Settings['FRONTEND_URL']
    $env:NEXT_PUBLIC_FILESERVER_URL = $Settings['FRONTEND_URL']
}

function Test-Tcp([string]$HostName, [int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect($HostName, $Port, $null, $null)
        return $result.AsyncWaitHandle.WaitOne(1000, $false) -and $client.Connected
    } catch { return $false }
    finally { $client.Close() }
}

function Test-Http([string]$Url) {
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Timeout = 1500
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        try { return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 }
        finally { $response.Close() }
    } catch { return $false }
}

function Find-DatabaseClient($Settings) {
    if ($Settings.ContainsKey('MYSQL_CLIENT_PATH')) {
        if (-not (Test-Path -LiteralPath $Settings['MYSQL_CLIENT_PATH'])) { throw 'MYSQL_CLIENT_PATH does not exist.' }
        return (Resolve-Path -LiteralPath $Settings['MYSQL_CLIENT_PATH']).Path
    }
    foreach ($name in @('mariadb.exe', 'mysql.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    foreach ($path in @('C:\xampp\mysql\bin\mysql.exe', 'D:\xampp\mysql\bin\mysql.exe')) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw 'A MariaDB/MySQL client is required for the production database health check. Set MYSQL_CLIENT_PATH.'
}

function Assert-DatabaseReady($Settings, $Config) {
    if (-not (Test-Tcp $Config.DbHost $Config.DbPort)) {
        throw "Database is not accepting connections at $($Config.DbHost):$($Config.DbPort)."
    }
    $client = Find-DatabaseClient $Settings
    $oldPassword = [Environment]::GetEnvironmentVariable('MYSQL_PWD', 'Process')
    try {
        $env:MYSQL_PWD = $Settings['DB_PASSWORD']
        $result = & $client --protocol=tcp --host=$Config.DbHost --port=$Config.DbPort `
            --user=$($Settings['DB_USERNAME']) --batch --skip-column-names `
            --database=$($Config.DbName) --execute='SELECT 1;' 2>$null
        if ($LASTEXITCODE -ne 0 -or @($result)[0] -ne '1') {
            throw 'Database login/query failed with the configured application credentials.'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('MYSQL_PWD', $oldPassword, 'Process')
    }
}

function Assert-ToolsAndArtifacts([bool]$RequireArtifacts) {
    foreach ($name in @('java.exe', 'node.exe', 'npm.cmd')) {
        if (-not (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$name is required on PATH."
        }
    }
    if (-not $RequireArtifacts) { return }
    foreach ($service in @('ssc-booking-fileserver', 'ssc-booking-backend')) {
        $jars = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "$service\target") -Filter '*.jar' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '(sources|javadoc|plain)' })
        if ($jars.Count -ne 1) { throw "$service needs exactly one built application JAR. Run -Action Build first." }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'ssc-booking-frontend\.next\BUILD_ID'))) {
        throw 'The production Next.js build is missing. Run -Action Build first.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.tools\minio.exe'))) {
        throw 'MinIO is missing from .tools. Install and verify the binary before starting production.'
    }
}

function Get-BuildFingerprint($Settings) {
    $names = @('FRONTEND_URL', 'API_URL', 'FILESERVER_URL', 'MINIO_URL',
        'MINIO_PUBLIC_URL', 'NEXT_PUBLIC_GOOGLE_CLIENT_ID')
    $payload = ($names | ForEach-Object { "$_=$($Settings[$_])" }) -join "`n"
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '')
    } finally { $hash.Dispose() }
}

function Assert-ProductionBuild($Settings) {
    $manifestPath = Join-Path $runtimeDir 'build.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw 'No production build manifest found. Run -Action Build with this configuration first.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $buildIdPath = Join-Path $repoRoot 'ssc-booking-frontend\.next\BUILD_ID'
    if ($manifest.fingerprint -ne (Get-BuildFingerprint $Settings) -or
        $manifest.buildId -ne (Get-Content -LiteralPath $buildIdPath -Raw).Trim()) {
        throw 'The built frontend does not match these production URLs/Google settings. Run -Action Build again.'
    }
}

function Assert-StorageReady($Config) {
    if (-not (Test-Path -LiteralPath $Config.MinioDataDir -PathType Container)) {
        throw 'MINIO_DATA_DIR is missing. Copy the existing MinIO data only after stopping MinIO cleanly.'
    }
    $firstItem = Get-ChildItem -LiteralPath $Config.MinioDataDir -Force -ErrorAction Stop | Select-Object -First 1
    if (-not $firstItem) {
        throw 'MINIO_DATA_DIR is empty. Verify the storage migration before starting production.'
    }
}

function Get-HealthUrls($Config) {
    $ports = $Config.Ports
    return [ordered]@{
        Minio = "http://127.0.0.1:$($ports.Minio)/minio/health/live"
        FileServer = "http://127.0.0.1:$($ports.FileServer)/actuator/health"
        Backend = "http://127.0.0.1:$($ports.Backend)/actuator/health"
        Frontend = "http://127.0.0.1:$($ports.Frontend)/"
    }
}

function Wait-Healthy([string]$Name, [string]$Url, $Process, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) { throw "$Name exited before becoming healthy. Check logs\production-$($Name.ToLower()).err.log." }
        if (Test-Http $Url) { return }
        Start-Sleep -Seconds 1
    }
    throw "$Name did not become healthy within $Seconds seconds. Check logs\production-$($Name.ToLower()).err.log."
}

function Start-ProductionProcess([string]$Name, [string]$Exe, [string[]]$Arguments, [string]$WorkingDir, [string]$HealthUrl, [int]$WaitSeconds) {
    $outLog = Join-Path $logDir "production-$($Name.ToLower()).log"
    $errLog = Join-Path $logDir "production-$($Name.ToLower()).err.log"
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $WorkingDir `
        -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
    Wait-Healthy $Name $HealthUrl $process $WaitSeconds
    [PSCustomObject]@{ name = $Name; pid = $process.Id; startedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeDir "$Name.json")
    Write-Host "  $Name healthy (PID $($process.Id))." -ForegroundColor Green
}

$settings = Read-ProductionConfig $ConfigPath
$config = Test-Configuration $settings
Apply-ProductionEnvironment $settings
$health = Get-HealthUrls $config

switch ($Action) {
    'Validate' {
        Assert-ToolsAndArtifacts $false
        Assert-DatabaseReady $settings $config
        Write-Host 'Production settings and database login: OK. No services or database objects were changed.' -ForegroundColor Green
    }
    'Check' {
        Assert-ToolsAndArtifacts $true
        Assert-ProductionBuild $settings
        Assert-StorageReady $config
        Assert-DatabaseReady $settings $config
        Write-Host 'Production configuration, artifacts, storage, and database login: OK. No services or database objects were changed.' -ForegroundColor Green
    }
    'Build' {
        Assert-ToolsAndArtifacts $false
        foreach ($port in $config.Ports.Values) {
            if (Test-Tcp '127.0.0.1' $port) { throw "Port $port is active. Stop running services before building in this checkout." }
        }
        $wrapper = Join-Path $repoRoot 'mvnw.cmd'
        if (-not (Test-Path -LiteralPath $wrapper)) { throw 'mvnw.cmd is missing.' }
        $previousProfile = $env:SPRING_PROFILES_ACTIVE
        try {
            Remove-Item Env:SPRING_PROFILES_ACTIVE -ErrorAction SilentlyContinue
            Push-Location $repoRoot
            try {
                & $wrapper clean package
                if ($LASTEXITCODE -ne 0) { throw 'Maven build/tests failed.' }
            } finally { Pop-Location }
        } finally { $env:SPRING_PROFILES_ACTIVE = $previousProfile }
        Push-Location (Join-Path $repoRoot 'ssc-booking-frontend')
        try {
            & npm ci
            if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
            & npm run build
            if ($LASTEXITCODE -ne 0) { throw 'Frontend production build failed.' }
        } finally { Pop-Location }
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
        [PSCustomObject]@{
            fingerprint = Get-BuildFingerprint $settings
            buildId = (Get-Content -LiteralPath (Join-Path $repoRoot 'ssc-booking-frontend\.next\BUILD_ID') -Raw).Trim()
            builtAt = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeDir 'build.json')
        Write-Host 'Production build complete. Run -Action Check, then -Action Start.' -ForegroundColor Green
    }
    'Status' {
        foreach ($name in $health.Keys) {
            $state = if (Test-Http $health[$name]) { 'HEALTHY' } else { 'DOWN' }
            Write-Host ("  {0,-12} {1}" -f $name, $state)
        }
        if (Test-Tcp $config.DbHost $config.DbPort) { Write-Host '  Database     TCP OPEN' }
        else { Write-Host '  Database     DOWN' -ForegroundColor Red }
    }
    'Start' {
        Assert-ToolsAndArtifacts $true
        Assert-ProductionBuild $settings
        Assert-StorageReady $config
        Assert-DatabaseReady $settings $config
        foreach ($port in $config.Ports.Values) {
            if (Test-Tcp '127.0.0.1' $port) {
                throw "Port $port is already in use. Run -Action Status and resolve the existing process before starting another copy."
            }
        }
        New-Item -ItemType Directory -Force -Path $runtimeDir, $logDir | Out-Null
        $minio = Join-Path $repoRoot '.tools\minio.exe'
        $minioData = $config.MinioDataDir
        $env:MINIO_ROOT_USER = $settings['MINIO_ROOT_USER']
        $env:MINIO_ROOT_PASSWORD = $settings['MINIO_ROOT_PASSWORD']
        Start-ProductionProcess 'Minio' $minio @('server', "`"$minioData`"", '--address', "127.0.0.1:$($config.Ports.Minio)",
            '--console-address', "127.0.0.1:$($config.Ports.MinioConsole)") $repoRoot $health.Minio 60

        $java = (Get-Command java.exe -CommandType Application).Source
        $fileJar = (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'ssc-booking-fileserver\target') -Filter '*.jar' |
            Where-Object { $_.Name -notmatch '(sources|javadoc|plain)' } | Select-Object -First 1).FullName
        Start-ProductionProcess 'FileServer' $java @('-jar', "`"$fileJar`"", '--server.address=127.0.0.1',
            "--server.port=$($config.Ports.FileServer)") (Join-Path $repoRoot 'ssc-booking-fileserver') $health.FileServer 90

        $backendJar = (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'ssc-booking-backend\target') -Filter '*.jar' |
            Where-Object { $_.Name -notmatch '(sources|javadoc|plain)' } | Select-Object -First 1).FullName
        Start-ProductionProcess 'Backend' $java @('-jar', "`"$backendJar`"", '--server.address=127.0.0.1',
            "--server.port=$($config.Ports.Backend)") (Join-Path $repoRoot 'ssc-booking-backend') $health.Backend 120

        $node = (Get-Command node.exe -CommandType Application).Source
        $frontendDir = Join-Path $repoRoot 'ssc-booking-frontend'
        $nextCli = Join-Path $frontendDir 'node_modules\next\dist\bin\next'
        if (-not (Test-Path -LiteralPath $nextCli)) { throw 'Next.js runtime is missing. Run -Action Build first.' }
        Start-ProductionProcess 'Frontend' $node @("`"$nextCli`"", 'start', '-H', '127.0.0.1',
            '-p', [string]$config.Ports.Frontend) $frontendDir $health.Frontend 90
        Write-Host 'All services passed health checks. Configure an OS service manager for automatic restart after reboot/failure.' -ForegroundColor Green
    }
}
