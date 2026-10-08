# Offline: the node function intercepts execution, so no Liquibase or DB call occurs.
$ErrorActionPreference = 'Stop'
$global:TenantMigrationTestCaptured = ''
function node {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)
    $props = Join-Path ((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath) '.generated-tenant-update-tenant_connectiontest.properties'
    $global:TenantMigrationTestCaptured = Get-Content -LiteralPath $props -Raw
    $global:LASTEXITCODE = 0
}
$keys = @('POSTGRES_HOST','POSTGRES_PORT','POSTGRES_DB','POSTGRES_USER','POSTGRES_PASSWORD','POSTGRES_SSLMODE')
$saved = @{}
foreach ($key in $keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
try {
    $env:POSTGRES_HOST = '127.0.0.1'
    $env:POSTGRES_PORT = '55432'
    $env:POSTGRES_DB = 'isolated_test'
    $env:POSTGRES_USER = 'test_user'
    $env:POSTGRES_PASSWORD = "a'b\c#literal"
    $env:POSTGRES_SSLMODE = 'verify-full'
    & (Join-Path $PSScriptRoot '../../../scripts/reusable/migrations/update-tenant-liquibase.ps1') -Schema tenant_connectiontest -UseProcessEnvironment
    if ($global:TenantMigrationTestCaptured -notmatch 'sslmode=verify-full') { throw 'TLS hostname/certificate verification was downgraded' }
    if (-not $global:TenantMigrationTestCaptured.Contains('password=a''b\\c#literal')) { throw 'Inherited password was reparsed or not escaped for Java properties' }
    if ($global:TenantMigrationTestCaptured -notmatch '127.0.0.1:55432/isolated_test') { throw 'Inherited connection target was changed' }
    if (Test-Path (Join-Path ((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath) '.generated-tenant-update-tenant_connectiontest.properties')) { throw 'Generated credential file was not removed' }
    Write-Host 'PASS: inherited connection is preserved, verify-full survives loopback, password escapes survive, temporary properties removed; no .env read or DB access.'
} finally {
    foreach ($key in $keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    Remove-Variable TenantMigrationTestCaptured -Scope Global
}
