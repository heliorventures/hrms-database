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
    [switch]$PostgresSsl,
    # Used by orchestrators that already loaded .env with the canonical Node
    # loader. Keep exactly that connection instead of independently reparsing it.
    [switch]$UseProcessEnvironment
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

if (-not $UseProcessEnvironment) { Import-DotEnvFile -Path $DbEnv }

if ([string]::IsNullOrWhiteSpace($DbName)) { $DbName = $env:POSTGRES_DB }
if ([string]::IsNullOrWhiteSpace($DbUser)) { $DbUser = $env:POSTGRES_USER }
if ([string]::IsNullOrWhiteSpace($DbPassword)) { $DbPassword = $env:POSTGRES_PASSWORD }
if ([string]::IsNullOrWhiteSpace($PostgresHost)) { $PostgresHost = $env:POSTGRES_HOST }
if (-not $PSBoundParameters.ContainsKey('PostgresPort') -and $env:POSTGRES_PORT) { $PostgresPort = [int]$env:POSTGRES_PORT }
if ([string]::IsNullOrWhiteSpace($DbName) -or [string]::IsNullOrWhiteSpace($DbUser) -or [string]::IsNullOrWhiteSpace($DbPassword)) {
    throw "Set DbName, DbUser, DbPassword or configure POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD in kabipay-database/.env"
}
if ([string]::IsNullOrWhiteSpace($PostgresHost)) { $PostgresHost = 'localhost' }
$sslMode = ''
if ($env:POSTGRES_SSLMODE -in @('require', 'verify-full')) { $sslMode = $env:POSTGRES_SSLMODE }
elseif ($PostgresSsl) { $sslMode = 'require' }

$JdbcHost = $PostgresHost
$tenantJdbc = "jdbc:postgresql://${JdbcHost}:${PostgresPort}/${DbName}"
if ($sslMode) { $tenantJdbc += "?sslmode=$sslMode" }

function ConvertTo-JavaPropertyValue {
    param([string]$Value)
    $escaped = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 92) { [void]$escaped.Append('\\') }
        elseif ($code -le 32 -or $code -gt 126) { [void]$escaped.Append(('\u{0:x4}' -f $code)) }
        else { [void]$escaped.Append($character) }
    }
    return $escaped.ToString()
}
$propertyUser = ConvertTo-JavaPropertyValue $DbUser
$propertyPassword = ConvertTo-JavaPropertyValue $DbPassword

$TrackingTable = "${Schema}_databasechangelog"
$TenantPropsPath = Join-Path $DatabaseDir ".generated-tenant-update-$Schema.properties"
$TenantProps = @"
changeLogFile=changelog/tenant.changelog-master.xml
url=$tenantJdbc
username=$propertyUser
password=$propertyPassword
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
