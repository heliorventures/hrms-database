<#
.SYNOPSIS
    Update the runtime database target stored in kabipay_ops.tenant_database.

.DESCRIPTION
    Use this when the tenant was provisioned through a local/tunnel/tooling
    address but the deployed KabiPay services must connect through a different
    runtime address. For Docker Compose on the VPS, RuntimePostgresHost is
    normally `postgres`.

.EXAMPLE
    .\scripts\update-tenant-database-target.ps1 -TenantId e6d4fc13-feb8-52a0-93bd-f66c795969b1 -RuntimePostgresHost postgres -RuntimeDbName helior
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [string]$RuntimePostgresHost = '',

    [string]$RuntimeDbName = ''
)

$ErrorActionPreference = 'Stop'

$DatabaseDir = Split-Path -Parent $PSScriptRoot
$RunSql = Join-Path $DatabaseDir 'run-sql.cjs'
$DbEnv = Join-Path $DatabaseDir '.env'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js is required. From $DatabaseDir run: npm install"
}
if (-not (Test-Path $RunSql)) {
    throw "Missing run-sql.cjs. In kabipay-database run: npm install"
}

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

function Escape-SqlLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace("'", "''")
}

Import-DotEnvFile -Path $DbEnv

if ([string]::IsNullOrWhiteSpace($RuntimePostgresHost)) { $RuntimePostgresHost = $env:KABIPAY_RUNTIME_POSTGRES_HOST }
if ([string]::IsNullOrWhiteSpace($RuntimeDbName)) { $RuntimeDbName = $env:KABIPAY_RUNTIME_POSTGRES_DB }
if ([string]::IsNullOrWhiteSpace($RuntimeDbName)) { $RuntimeDbName = $env:POSTGRES_DB }

if ([string]::IsNullOrWhiteSpace($env:POSTGRES_HOST) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PORT) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_DB) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_USER) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PASSWORD)) {
    throw "Set POSTGRES_HOST/PORT/DB/USER/PASSWORD in $DbEnv so this script can connect to the ops database."
}
if ([string]::IsNullOrWhiteSpace($RuntimePostgresHost) -or [string]::IsNullOrWhiteSpace($RuntimeDbName)) {
    throw "RuntimePostgresHost and RuntimeDbName must be set, either by parameters or KABIPAY_RUNTIME_POSTGRES_HOST/KABIPAY_RUNTIME_POSTGRES_DB."
}

$HostEscaped = Escape-SqlLiteral $RuntimePostgresHost
$DbNameEscaped = Escape-SqlLiteral $RuntimeDbName

$Sql = @"
WITH updated AS (
    UPDATE kabipay_ops.tenant_database
       SET db_host = '$HostEscaped',
           db_name = '$DbNameEscaped',
           updated_at = NOW()
     WHERE tenant_id = '$TenantId'
       AND is_active = true
     RETURNING id
)
SELECT CASE WHEN EXISTS (SELECT 1 FROM updated) THEN 1 ELSE 1 / 0 END;
"@

$TempSql = [System.IO.Path]::GetTempFileName() + '.sql'
try {
    [System.IO.File]::WriteAllText($TempSql, $Sql, [System.Text.UTF8Encoding]::new($false))
    Push-Location $DatabaseDir
    try {
        & node $RunSql -f $TempSql
        if ($LASTEXITCODE -ne 0) {
            throw "Updating tenant database target failed with exit code $LASTEXITCODE. This script connects using kabipay-database/.env from the current machine. For the VPS Docker database, run project-documentation/scripts/deploy-on-vps.ps1 with -SyncTenantDatabaseTarget or -Deploy."
        }
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $TempSql -ErrorAction SilentlyContinue
}

Write-Host "Updated tenant database target." -ForegroundColor Green
Write-Host "  tenant_id: $TenantId"
Write-Host "  db_host  : $RuntimePostgresHost"
Write-Host "  db_name  : $RuntimeDbName"
