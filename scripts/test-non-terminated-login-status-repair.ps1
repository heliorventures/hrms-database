[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$MigrationRelativePath = 'migrations/0073_non_terminated_login_status_repair/non_terminated_login_status_repair.xml'
$MigrationPath = Join-Path (Join-Path $DatabaseDir 'changelog') $MigrationRelativePath
$MasterPath = Join-Path $DatabaseDir 'changelog/tenant.changelog-master.xml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $MigrationPath) '0073 non-terminated login-status repair migration is missing'

[xml]$master = Get-Content -Raw -LiteralPath $MasterPath
$includes = @($master.databaseChangeLog.include | ForEach-Object { $_.file })
$previousIndex = [array]::IndexOf($includes, 'migrations/0072_on_leave_login_repair/on_leave_login_repair.xml')
$migrationIndex = [array]::IndexOf($includes, $MigrationRelativePath)
Assert-True ($migrationIndex -eq ($previousIndex + 1)) '0073 must immediately follow 0072 in the tenant changelog'

$migration = Get-Content -Raw -LiteralPath $MigrationPath
foreach ($requiredPattern in @(
    "employee.status\)\) IN \('INACTIVE', 'SUSPENDED'\)",
    'employee.user_id = login_user.id',
    'employee.tenant_id = login_user.tenant_id',
    'employee.is_deleted = FALSE',
    'login_user.is_deleted = FALSE',
    'login_user.is_active = FALSE',
    'SET is_active = TRUE'
)) {
    Assert-True ($migration -match $requiredPattern) "Non-terminated login-status repair is missing: $requiredPattern"
}
Assert-True (-not ($migration -match "employee.status\)\) IN \([^\)]*'TERMINATED'")) '0073 must never reactivate terminated employees'

Write-Host 'Non-terminated login-status repair migration contract passed.' -ForegroundColor Green
