# Generates a data-only Flyway snapshot for the registrar and faculty masterlists.
# The source database is never modified: normalization is tested in a temporary clone.

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $OutputPath = Join-Path $repo 'ssc-booking-backend\src\main\resources\db\migration\V59__seed_current_masterlists.sql'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    throw "Output already exists: $OutputPath. Flyway migrations are immutable; choose a new versioned filename."
}

function Import-SscDotEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
             ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

function Find-SscExecutable([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($base in @('C:\xampp\mysql\bin', 'D:\xampp\mysql\bin')) {
        $candidate = Join-Path $base "$Name.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

Import-SscDotEnv (Join-Path $repo '.env')
$mysql = Find-SscExecutable 'mysql'
$mysqldump = Find-SscExecutable 'mysqldump'
if (-not $mysql -or -not $mysqldump) {
    throw 'mysql.exe and mysqldump.exe are required.'
}

$hostName = if ($env:MYSQL_HOST) { $env:MYSQL_HOST } else { '127.0.0.1' }
$port = if ($env:MYSQL_PORT) { $env:MYSQL_PORT } else { '3306' }
$sourceDatabase = if ($env:MYSQL_DATABASE) { $env:MYSQL_DATABASE } else { 'ssc_booking' }
$rootPassword = if ($env:MYSQL_ROOT_PASSWORD) { $env:MYSQL_ROOT_PASSWORD } else { '' }
$temporaryDatabase = "ssc_seed_export_$PID"
if ($temporaryDatabase -notmatch '^ssc_seed_export_[0-9]+$') {
    throw "Refusing unsafe temporary database name: $temporaryDatabase"
}

$fullDump = Join-Path ([System.IO.Path]::GetTempPath()) "$temporaryDatabase-full.sql"
$seedDump = Join-Path ([System.IO.Path]::GetTempPath()) "$temporaryDatabase-seed.sql"
$normalizationMigration = Join-Path $repo 'ssc-booking-backend\src\main\resources\db\migration\V58__normalize_school_ids.sql'
if (-not (Test-Path -LiteralPath $normalizationMigration)) {
    throw "Normalization migration is missing: $normalizationMigration"
}

$hadMySqlPwd = Test-Path Env:MYSQL_PWD
$previousMySqlPwd = $env:MYSQL_PWD
try {
    $env:MYSQL_PWD = $rootPassword
    "CREATE DATABASE ``$temporaryDatabase`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" |
        & $mysql --protocol=tcp --host=$hostName --port=$port --user=root
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary export database.' }

    & $mysqldump --protocol=tcp --host=$hostName --port=$port --user=root `
        --single-transaction --default-character-set=utf8mb4 --result-file=$fullDump $sourceDatabase
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone the source database.' }

    & cmd.exe /d /c ('"{0}" --protocol=tcp --host="{1}" --port={2} --user=root --database="{3}" < "{4}"' -f `
        $mysql, $hostName, $port, $temporaryDatabase, $fullDump)
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore the temporary export database.' }

    & cmd.exe /d /c ('"{0}" --protocol=tcp --host="{1}" --port={2} --user=root --database="{3}" < "{4}"' -f `
        $mysql, $hostName, $port, $temporaryDatabase, $normalizationMigration)
    if ($LASTEXITCODE -ne 0) { throw 'ID normalization failed in the temporary database.' }

    & $mysqldump --protocol=tcp --host=$hostName --port=$port --user=root `
        --single-transaction --no-create-info --skip-triggers --complete-insert `
        --skip-extended-insert --compact --default-character-set=utf8mb4 `
        --result-file=$seedDump $temporaryDatabase masterlist students faculty faculty_organizations
    if ($LASTEXITCODE -ne 0) { throw 'Could not export the normalized masterlist snapshot.' }

    $seedSql = [System.IO.File]::ReadAllText($seedDump, [System.Text.UTF8Encoding]::new($false))
    $seedSql = $seedSql.Replace('INSERT INTO ', 'INSERT IGNORE INTO ')
    $header = @"
-- Baseline snapshot generated from the approved SSC masterlists.
-- Contains personally identifiable information; keep this repository private and access-controlled.
-- Generated after applying V58 normalization in an isolated database clone.
-- INSERT IGNORE makes this safe for the source database and for fresh databases containing earlier seeds.

-- If an earlier migration contains data that conflicts with the approved registrar snapshot,
-- add a narrowly guarded cleanup below before installing this generated migration.

"@
    [System.IO.File]::WriteAllText($OutputPath, $header + $seedSql, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Created $OutputPath" -ForegroundColor Green
} finally {
    $env:MYSQL_PWD = $rootPassword
    "DROP DATABASE IF EXISTS ``$temporaryDatabase``;" |
        & $mysql --protocol=tcp --host=$hostName --port=$port --user=root 2>$null
    foreach ($temporaryFile in @($fullDump, $seedDump)) {
        if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
    }
    if ($hadMySqlPwd) { $env:MYSQL_PWD = $previousMySqlPwd } else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
}
