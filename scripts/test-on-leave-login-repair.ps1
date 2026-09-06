[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$MigrationRelativePath = 'migrations/0072_on_leave_login_repair/on_leave_login_repair.xml'
$MigrationPath = Join-Path (Join-Path $DatabaseDir 'changelog') $MigrationRelativePath
$MasterPath = Join-Path $DatabaseDir 'changelog/tenant.changelog-master.xml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $MigrationPath) '0072 ON_LEAVE login repair migration is missing'

[xml]$master = Get-Content -Raw -LiteralPath $MasterPath
$includes = @($master.databaseChangeLog.include | ForEach-Object { $_.file })
$previousIndex = [array]::IndexOf($includes, 'migrations/0071_leave_supporting_document_file/leave_supporting_document_file.xml')
$migrationIndex = [array]::IndexOf($includes, $MigrationRelativePath)
Assert-True ($migrationIndex -eq ($previousIndex + 1)) '0072 must immediately follow 0071 in the tenant changelog'

$migration = Get-Content -Raw -LiteralPath $MigrationPath
foreach ($requiredPattern in @(
    'employee.status = ''ON_LEAVE''',
    'employee.user_id = login_user.id',
    'employee.tenant_id = login_user.tenant_id',
    'employee.is_deleted = FALSE',
    'login_user.is_deleted = FALSE',
    'login_user.is_active = FALSE',
    'SET is_active = TRUE'
)) {
    Assert-True ($migration -match $requiredPattern) "ON_LEAVE login repair is missing: $requiredPattern"
}

Write-Host 'ON_LEAVE login repair migration contract passed.' -ForegroundColor Green
