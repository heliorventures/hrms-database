<#
.SYNOPSIS
Preview or explicitly update Indian tenant timezones to Asia/Kolkata.
.DESCRIPTION
Uses hrms-database/.env and the existing SQL runner. Dry run is read-only.
Changes only kabipay_ops.tenant.timezone and updated_at; historical attendance is untouched.
.EXAMPLE
.\scripts\update-indian-tenant-timezones.ps1 -AllIndianTenants
.EXAMPLE
.\scripts\update-indian-tenant-timezones.ps1 -TenantSlug solvianconsultancy -Execute -ExpectedCount 1
#>
[CmdletBinding(DefaultParameterSetName = 'Tenant')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Tenant')]
    [ValidatePattern('^[a-z0-9][a-z0-9_-]{1,63}$')][string]$TenantSlug,
    [Parameter(Mandatory, ParameterSetName = 'All')][switch]$AllIndianTenants,
    [switch]$Execute,
    [ValidateRange(0, 100000)][int]$ExpectedCount = 0,
    [switch]$GenerateSqlOnly
)
$ErrorActionPreference = 'Stop'
if ($Execute -and -not $PSBoundParameters.ContainsKey('ExpectedCount')) {
    throw 'Run the preview first, then pass -ExpectedCount with the number of tenants that need a change.'
}
if ($PSCmdlet.ParameterSetName -eq 'Tenant') {
    # An explicitly named tenant is safe to target even when older tenant metadata has no country.
    $ScopeClause = "subdomain = '$TenantSlug'"
} else {
    $ScopeClause = "UPPER(TRIM(COALESCE(country, ''))) IN ('IN', 'INDIA')"
}
$Predicate = "is_deleted = FALSE AND status <> 'TERMINATED' AND $ScopeClause"
$Preview = @"
SELECT id, name, subdomain, country, timezone AS previous_timezone,
       'Asia/Kolkata' AS proposed_timezone,
       timezone IS DISTINCT FROM 'Asia/Kolkata' AS needs_change
  FROM kabipay_ops.tenant WHERE $Predicate ORDER BY subdomain;
"@
if ($Execute) {
    $Sql = @"
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
DO `$guard`$
DECLARE target_count integer;
BEGIN
    PERFORM 1 FROM kabipay_ops.tenant WHERE $Predicate ORDER BY id FOR UPDATE;
    SELECT COUNT(*) INTO target_count FROM kabipay_ops.tenant
     WHERE $Predicate AND timezone IS DISTINCT FROM 'Asia/Kolkata';
    IF target_count <> $ExpectedCount THEN
        RAISE EXCEPTION 'Preview is stale: expected % timezone changes, found %', $ExpectedCount, target_count;
    END IF;
END;
`$guard`$;
WITH previous AS MATERIALIZED (
    SELECT id, timezone FROM kabipay_ops.tenant
     WHERE $Predicate AND timezone IS DISTINCT FROM 'Asia/Kolkata'
), changed AS (
    UPDATE kabipay_ops.tenant t SET timezone = 'Asia/Kolkata', updated_at = NOW()
      FROM previous p WHERE t.id = p.id
    RETURNING t.id, t.subdomain, p.timezone AS previous_timezone, t.timezone AS new_timezone
)
SELECT * FROM changed ORDER BY subdomain;
COMMIT;
"@
} else {
    $Sql = "BEGIN READ ONLY;`n$Preview`nCOMMIT;"
}
if ($GenerateSqlOnly) { return $Sql }
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $DatabaseDir 'run-sql-raw.cjs'
$TempSqlPath = Join-Path ([IO.Path]::GetTempPath()) ("tenant-timezones-{0}.sql" -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($TempSqlPath, $Sql, [Text.UTF8Encoding]::new($false))
    Push-Location $DatabaseDir
    try {
        & node $Runner -f $TempSqlPath
        if ($LASTEXITCODE -ne 0) { throw "Timezone operation failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }
} finally { Remove-Item -LiteralPath $TempSqlPath -ErrorAction SilentlyContinue }
if ($Execute) {
    Write-Host 'Timezone update completed. Reload tenant browser sessions. Historical attendance was not rewritten.'
} else {
    Write-Host 'Preview only. Count needs_change=True rows and pass -Execute -ExpectedCount <count> to apply.'
}
