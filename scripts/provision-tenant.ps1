<#
.SYNOPSIS
    Provision a KabiPay tenant: ops rows + tenant schema + Liquibase tenant migrations.

.DESCRIPTION
    1. Inserts kabipay_ops.tenant (id = deterministic v5 UUID derived from -Code).
    2. Inserts kabipay_ops.tenant_database referencing the target schema.
    3. CREATE SCHEMA IF NOT EXISTS <Schema> in kabipay_dev.
    4. Runs Liquibase tenant.changelog-master.xml against <Schema>, with a
       per-tenant DATABASECHANGELOG tracking table inside that schema.

    Requires:
      - **Node.js** and `npm install` in **kabipay-database** (bundled Liquibase + `run-sql.cjs` via `pg`, no `psql`).
      - Database reachable: pass **-PostgresHost** (and -PostgresPort, -PostgresSsl) for *cloud* hosts,
        or omit **-PostgresHost** to use **localhost** and **-PostgresPort** (default 5432) for a *local* Postgres.

.PARAMETER Name
    Human-readable tenant name, e.g. "Demo Co".

.PARAMETER Code
    Short unique code (a-z0-9, 2-32 chars). Also used to seed the deterministic UUID.

.PARAMETER Schema
    OPTIONAL — PostgreSQL schema name to create for this tenant. When omitted, the schema
    is auto-derived as `tenant_<first 8 hex chars of the tenant UUID>`, matching
    `kabipay_common::db::derive_tenant_schema_name`. Pass an explicit value ONLY if you
    have already wired a `kabipay_ops.tenant_database` lookup on the service side.

.PARAMETER Country
    ISO 3166-1 alpha-2 country code. Defaults to IN.

.PARAMETER Currency
    ISO 4217 currency code. Defaults to INR.

.PARAMETER DbName
    Postgres database. If omitted, uses **kabipay-database/.env** `POSTGRES_DB`. For local (no -PostgresHost), defaults to `kabipay_dev` when not in .env.

.PARAMETER DbUser
    Database user. If omitted, uses **kabipay-database/.env** `POSTGRES_USER` (or `kabipay` for local when not in .env).

.PARAMETER DbPassword
    If omitted, uses **kabipay-database/.env** `POSTGRES_PASSWORD` (required for Aiven; do not paste a placeholder like YOUR_PASSWORD on the command line).

.PARAMETER RuntimePostgresHost
    Database host that KabiPay services should use at runtime. This can differ from
    POSTGRES_HOST when provisioning from a laptop, SSH tunnel, or VPS host shell.
    For Docker Compose on the VPS, use `postgres`.

.PARAMETER RuntimeDbName
    Database name that KabiPay services should use at runtime. Defaults to the
    tooling connection database from POSTGRES_DB.

.PARAMETER PostgresHost
    If set, connect to this host (e.g. Aiven) with `run-sql.cjs` and bundled Liquibase. Use with -PostgresPort,
    -PostgresSsl, -DbName, -DbUser, -DbPassword. If *omitted*, uses `localhost` and -PostgresPort
    (default **5432**) for a local PostgreSQL (no SSL unless you add it).

.PARAMETER PostgresPort
    Port for both cloud (`-PostgresHost` set) and local (localhost) connections. Defaults to 5432.

.PARAMETER PostgresSsl
    When -PostgresHost is set, use TLS (sslmode=require / PGSSLMODE=require). Required for Aiven.

.EXAMPLE
    .\provision-tenant.ps1 -Name "Demo Co" -Code demo -Schema tenant_demo0001

.EXAMPLE
    # Cloud: put host/port/user/db/password in kabipay-database/.env, then
    .\provision-tenant.ps1 -Name "Demo Co" -Code demo -PostgresHost "pg-....aivencloud.com" -PostgresPort 12507 -PostgresSsl

.EXAMPLE
    # Or pass only what you need; use the real Aiven password, not the literal "YOUR_PASSWORD"
    .\provision-tenant.ps1 -Name "Demo Co" -Code demo -PostgresHost "pg-....aivencloud.com" -PostgresPort 12507 -DbName defaultdb -DbUser avnadmin -DbPassword "<paste from Aiven>" -PostgresSsl

.EXAMPLE
    # Provision through localhost/host port, but store the Docker runtime target.
    .\provision-tenant.ps1 -Name "Helior Prd" -Code helior-prd -RuntimePostgresHost postgres -RuntimeDbName client_demo_db
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9_-]{1,31}$')][string]$Code,
    [Parameter(Mandatory = $false)][ValidatePattern('^tenant_[a-z0-9_]{1,50}$')][string]$Schema,
    [string]$Country = 'IN',
    [string]$Currency = 'INR',
    [string]$DbName,
    [string]$DbUser,
    [string]$DbPassword,
    [string]$PostgresHost = '',
    [int]$PostgresPort = 5432,
    [switch]$PostgresSsl,
    [string]$RuntimePostgresHost = '',
    [string]$RuntimeDbName = ''
)

$ErrorActionPreference = 'Stop'

# Database repo root = one level above this script's folder.
$DatabaseDir = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $DatabaseDir)) {
    throw "kabipay-database dir not found at $DatabaseDir"
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js is required. From $DatabaseDir run: npm install"
}
$RunSql = Join-Path $DatabaseDir 'run-sql.cjs'
$RunLb = Join-Path $DatabaseDir 'run-liquibase.cjs'
if (-not (Test-Path $RunSql) -or -not (Test-Path $RunLb)) {
    throw "Missing run-sql.cjs or run-liquibase.cjs. In kabipay-database run: npm install"
}

$DbEnv = Join-Path $DatabaseDir '.env'
function Import-DotEnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { return }
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
        if ($k) { Set-Item -Path "Env:$k" -Value $v }
    }
}
# Base connection: kabipay-database/.env is the single database tooling config.
Import-DotEnvFile -Path $DbEnv
$isRemoteInEnv = $env:POSTGRES_HOST -and $env:POSTGRES_HOST -notin @('localhost', '127.0.0.1', '')
# Remote: explicit -PostgresHost, or Aiven/Cloud host only in .env
if ($PostgresHost -or $isRemoteInEnv) {
    if ($PostgresHost) { $env:POSTGRES_HOST = $PostgresHost }
    if ($PostgresSsl) { $env:POSTGRES_SSLMODE = 'require' }
    # else keep .env value (e.g. require) — do not strip SSL
    if ($PSBoundParameters.ContainsKey('PostgresPort')) { $env:POSTGRES_PORT = "$PostgresPort" }
    if ($PSBoundParameters.ContainsKey('DbName') -and -not [string]::IsNullOrWhiteSpace($DbName)) { $env:POSTGRES_DB = $DbName }
    if ($PSBoundParameters.ContainsKey('DbUser') -and -not [string]::IsNullOrWhiteSpace($DbUser)) { $env:POSTGRES_USER = $DbUser }
    if ($PSBoundParameters.ContainsKey('DbPassword') -and -not [string]::IsNullOrWhiteSpace($DbPassword)) { $env:POSTGRES_PASSWORD = $DbPassword }
} else {
    $env:POSTGRES_HOST = 'localhost'
    if ($PSBoundParameters.ContainsKey('PostgresPort')) { $env:POSTGRES_PORT = "$PostgresPort" }
    elseif (-not $env:POSTGRES_PORT) { $env:POSTGRES_PORT = '5432' }
    if ($PSBoundParameters.ContainsKey('DbName') -and -not [string]::IsNullOrWhiteSpace($DbName)) { $env:POSTGRES_DB = $DbName }
    elseif (-not $env:POSTGRES_DB) { $env:POSTGRES_DB = 'kabipay_dev' }
    if ($PSBoundParameters.ContainsKey('DbUser') -and -not [string]::IsNullOrWhiteSpace($DbUser)) { $env:POSTGRES_USER = $DbUser }
    elseif (-not $env:POSTGRES_USER) { $env:POSTGRES_USER = 'kabipay' }
    if ($PSBoundParameters.ContainsKey('DbPassword') -and -not [string]::IsNullOrWhiteSpace($DbPassword)) { $env:POSTGRES_PASSWORD = $DbPassword }
    elseif (-not $env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD = 'changeme' }
    Remove-Item Env:POSTGRES_SSLMODE -ErrorAction SilentlyContinue
}
if ([string]::IsNullOrWhiteSpace($env:POSTGRES_HOST) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PORT) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_DB) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_USER) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PASSWORD)) {
    throw "After loading .env, POSTGRES_HOST/PORT/DB/USER/PASSWORD must be set. Pass -PostgresHost/-PostgresPort/... and/or set credentials in $DbEnv"
}

if ([string]::IsNullOrWhiteSpace($RuntimePostgresHost)) { $RuntimePostgresHost = $env:KABIPAY_RUNTIME_POSTGRES_HOST }
if ([string]::IsNullOrWhiteSpace($RuntimeDbName)) { $RuntimeDbName = $env:KABIPAY_RUNTIME_POSTGRES_DB }
if ([string]::IsNullOrWhiteSpace($RuntimePostgresHost)) { $RuntimePostgresHost = $env:POSTGRES_HOST }
if ([string]::IsNullOrWhiteSpace($RuntimeDbName)) { $RuntimeDbName = $env:POSTGRES_DB }
if ([string]::IsNullOrWhiteSpace($RuntimePostgresHost) -or [string]::IsNullOrWhiteSpace($RuntimeDbName)) {
    throw "RuntimePostgresHost and RuntimeDbName must be set, either by parameters or KABIPAY_RUNTIME_POSTGRES_HOST/KABIPAY_RUNTIME_POSTGRES_DB."
}

function New-DeterministicUuid {
    param([Parameter(Mandatory=$true)][string]$Seed)
    # SHA1(seed) -> first 16 bytes -> set UUID v5 bits -> format.
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("kabipay-tenant:$Seed"))[0..15]
        $bytes[6] = ($bytes[6] -band 0x0F) -bor 0x50   # version 5
        $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80   # variant RFC 4122
        $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
        return "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
    } finally { $sha1.Dispose() }
}

$TenantId = New-DeterministicUuid -Seed $Code
$TenantDbRowId = New-DeterministicUuid -Seed "$Code-db"
$Subdomain = $Code.ToLowerInvariant()

# Auto-derive schema to match kabipay_common::db::derive_tenant_schema_name unless the caller
# passed one explicitly. The common resolver uses the first 8 hex chars of the tenant UUID.
if ([string]::IsNullOrWhiteSpace($Schema)) {
    $Schema = 'tenant_' + ($TenantId -replace '-','').Substring(0,8)
    Write-Host "Schema (derived): $Schema"
} else {
    Write-Host "Schema (explicit): $Schema (must match tenant_database.schema_name lookup)"
}

Write-Host "Tenant UUID     : $TenantId"
Write-Host "Tenant DB rowId : $TenantDbRowId"
Write-Host "Subdomain       : $Subdomain"
Write-Host "Runtime DB      : $RuntimePostgresHost/$RuntimeDbName"
Write-Host ""

function Invoke-Psql {
    param([Parameter(Mandatory=$true)][string]$Sql)
    $tmp = [System.IO.Path]::GetTempFileName() + '.sql'
    try {
        [System.IO.File]::WriteAllText($tmp, $Sql, [System.Text.UTF8Encoding]::new($false))
        & node $RunSql -f $tmp
        if ($LASTEXITCODE -ne 0) { throw "SQL failed (exit $LASTEXITCODE) running: $Sql" }
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "==> Creating tenant schema $Schema ..." -ForegroundColor Cyan
$ConnUser = $env:POSTGRES_USER
Invoke-Psql "CREATE SCHEMA IF NOT EXISTS $Schema AUTHORIZATION $ConnUser;"

Write-Host "==> Upserting kabipay_ops.tenant ..." -ForegroundColor Cyan
$NameEscaped = $Name.Replace("'", "''")
Invoke-Psql @"
INSERT INTO kabipay_ops.tenant (id, name, status, country, currency, subdomain)
VALUES ('$TenantId', '$NameEscaped', 'ACTIVE', '$Country', '$Currency', '$Subdomain')
ON CONFLICT (id) DO UPDATE SET
    name       = EXCLUDED.name,
    status     = EXCLUDED.status,
    country    = EXCLUDED.country,
    currency   = EXCLUDED.currency,
    subdomain  = EXCLUDED.subdomain,
    updated_at = NOW();
"@

$RowDbHost = $RuntimePostgresHost.Replace("'", "''")
$RowDbName = $RuntimeDbName.Replace("'", "''")
Write-Host "==> Upserting kabipay_ops.tenant_database ..." -ForegroundColor Cyan
Invoke-Psql @"
INSERT INTO kabipay_ops.tenant_database (id, tenant_id, db_type, db_host, db_name, schema_name, is_active)
VALUES ('$TenantDbRowId', '$TenantId', 'POSTGRES', '$RowDbHost', '$RowDbName', '$Schema', true)
ON CONFLICT (id) DO UPDATE SET
    tenant_id   = EXCLUDED.tenant_id,
    db_host     = EXCLUDED.db_host,
    db_name     = EXCLUDED.db_name,
    schema_name = EXCLUDED.schema_name,
    is_active   = true,
    updated_at  = NOW();
"@

Write-Host "==> Running Liquibase tenant changelog against $Schema ..." -ForegroundColor Cyan
$TrackingTable = "${Schema}_databasechangelog"

# Liquibase 4.27 CLI rejects ad-hoc `-D<name>=<value>` arguments. Write a per-tenant
# properties file that substitutes `${schema}` in the changelog via `parameter.schema=...`,
# pins the per-tenant tracking table, and sets the default schema.
$TenantPropsPath = Join-Path $DatabaseDir ".generated-tenant-$Schema.properties"
$JdbcHost = $env:POSTGRES_HOST
$tenantJdbc = "jdbc:postgresql://${JdbcHost}:$($env:POSTGRES_PORT)/$($env:POSTGRES_DB)"
$needJdbcSsl = ($env:POSTGRES_SSLMODE -eq 'require') -or $PostgresSsl
if ($needJdbcSsl -and $tenantJdbc -notmatch 'sslmode=') {
    $tenantJdbc += if ($tenantJdbc.Contains('?')) { '&sslmode=require' } else { '?sslmode=require' }
}
$DbUserForLb = $env:POSTGRES_USER
$DbPassForLb = $env:POSTGRES_PASSWORD
$TenantProps = @"
changeLogFile=changelog/tenant.changelog-master.xml
url=$tenantJdbc
username=$DbUserForLb
password=$DbPassForLb
driver=org.postgresql.Driver
logLevel=INFO
defaultSchemaName=$Schema
databaseChangeLogTableName=$TrackingTable
parameter.schema=$Schema
liquibase.hub.mode=off
"@
$TenantProps | Set-Content -Path $TenantPropsPath -Encoding ASCII

try {
    $TenantPropsRel = [System.IO.Path]::GetFileName($TenantPropsPath)
    Push-Location $DatabaseDir
    try {
        & node $RunLb --defaults-file=$TenantPropsRel update
        if ($LASTEXITCODE -ne 0) { throw "Liquibase tenant migration failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -Path $TenantPropsPath -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Tenant '$Name' provisioned." -ForegroundColor Green
Write-Host "  id          : $TenantId"
Write-Host "  schema      : $Schema"
Write-Host "  tracking tbl: $Schema.$TrackingTable"
Write-Host ""
Write-Host "Next: run scripts\seed-demo-data.ps1 -TenantId $TenantId -Schema $Schema"
