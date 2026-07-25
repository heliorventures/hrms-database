# Run Liquibase tenant changelog **update** against an already-provisioned schema.
# Use this after new changeSets are added so existing tenants get the new tables.
#
# Requires: Node + `npm install` in kabipay-database; `kabipay-database/.env` with POSTGRES_* (and SSL as needed).
#
# Example:
#   Set-Location D:\work\KabiPay\kabipay-database\scripts
#   .\update-tenant-liquibase.ps1 -Schema tenant_342205fc

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^tenant_[a-z0-9_]{1,50}$')]
    [string]$Schema,
    [string]$PostgresHost = '',
    [int]$PostgresPort = 5432,
    [string]$DbName = '',
    [string]$DbUser = '',
    [string]$DbPassword = '',
    [switch]$PostgresSsl
)

$ErrorActionPreference = 'Stop'

$DatabaseDir = Split-Path -Parent $PSScriptRoot
$RunLb = Join-Path $DatabaseDir 'run-liquibase.cjs'
$DbEnv = Join-Path $DatabaseDir '.env'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js is required" }
if (-not (Test-Path $RunLb)) { throw "Missing run-liquibase.cjs - in kabipay-database run npm install" }

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
        Set-Item -Path "Env:$k" -Value $v
    }
}

Import-DotEnvFile -Path $DbEnv

if ([string]::IsNullOrWhiteSpace($DbName)) { $DbName = $env:POSTGRES_DB }
if ([string]::IsNullOrWhiteSpace($DbUser)) { $DbUser = $env:POSTGRES_USER }
if ([string]::IsNullOrWhiteSpace($DbPassword)) { $DbPassword = $env:POSTGRES_PASSWORD }
if ([string]::IsNullOrWhiteSpace($PostgresHost)) { $PostgresHost = $env:POSTGRES_HOST }
if (-not $PSBoundParameters.ContainsKey('PostgresPort') -and $env:POSTGRES_PORT) { $PostgresPort = [int]$env:POSTGRES_PORT }
if ([string]::IsNullOrWhiteSpace($DbName) -or [string]::IsNullOrWhiteSpace($DbUser) -or [string]::IsNullOrWhiteSpace($DbPassword)) {
    throw "Set DbName, DbUser, DbPassword or configure POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD in kabipay-database/.env"
}
if ([string]::IsNullOrWhiteSpace($PostgresHost)) { $PostgresHost = 'localhost' }
$isCloud = ($PostgresHost -ne 'localhost' -and $PostgresHost -ne '127.0.0.1')
$useSsl = [bool]$PostgresSsl
if (-not $useSsl -and $isCloud -and $env:POSTGRES_SSLMODE -eq 'require') { $useSsl = $true }

$JdbcHost = $PostgresHost
$tenantJdbc = "jdbc:postgresql://${JdbcHost}:${PostgresPort}/${DbName}"
if ($useSsl) { $tenantJdbc += "?sslmode=require" }

$TrackingTable = "${Schema}_databasechangelog"
$TenantPropsPath = Join-Path $DatabaseDir ".generated-tenant-update-$Schema.properties"
$TenantProps = @"
changeLogFile=changelog/tenant.changelog-master.xml
url=$tenantJdbc
username=$DbUser
password=$DbPassword
driver=org.postgresql.Driver
logLevel=INFO
defaultSchemaName=$Schema
databaseChangeLogTableName=$TrackingTable
parameter.schema=$Schema
liquibase.hub.mode=off
"@
$TenantProps | Set-Content -Path $TenantPropsPath -Encoding ASCII

try {
    Write-Host "==> Liquibase update for schema $Schema (tracking: $Schema.$TrackingTable)..." -ForegroundColor Cyan
    $TenantPropsRel = [System.IO.Path]::GetFileName($TenantPropsPath)
    Push-Location $DatabaseDir
    try {
        & node $RunLb --defaults-file=$TenantPropsRel update
        if ($LASTEXITCODE -ne 0) { throw "Liquibase update failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
} finally {
    Remove-Item -Path $TenantPropsPath -ErrorAction SilentlyContinue
}
Write-Host "Done. Pending tenant changeSets (if any) are now applied to $Schema." -ForegroundColor Green
