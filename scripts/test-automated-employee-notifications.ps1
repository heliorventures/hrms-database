[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$RelativeMigration = 'migrations/0074_automated_employee_notifications/automated_employee_notifications.xml'
$MigrationPath = Join-Path (Join-Path $DatabaseDir 'changelog') $RelativeMigration
$MasterPath = Join-Path $DatabaseDir 'changelog/tenant.changelog-master.xml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $MigrationPath) '0074 automated employee notifications migration is missing'

[xml]$master = Get-Content -Raw -LiteralPath $MasterPath
$includes = @($master.databaseChangeLog.include | ForEach-Object { $_.file })
Assert-True ($includes -contains $RelativeMigration) 'Tenant changelog must include migration 0074'

$migration = Get-Content -Raw -LiteralPath $MigrationPath
foreach ($table in @(
    'notification_automation_setting',
    'employee_celebration_preference',
    'automated_notification_occurrence'
)) {
    $tablePattern = 'createTable tableName="' + [regex]::Escape($table) + '"'
    Assert-True ($migration -match $tablePattern) "Migration is missing $table"
}

Assert-True ($migration -match 'share_birthday[\s\S]*?defaultValueBoolean="false"') 'Birthday sharing must default to false'
Assert-True ($migration -match 'share_work_anniversary[\s\S]*?defaultValueBoolean="false"') 'Anniversary sharing must default to false'
Assert-True ($migration -match 'tenant_id,event_type,employee_id,event_date,recipient_user_id') 'Occurrence uniqueness must cover tenant, event, employee, date, and recipient'
Assert-True ($migration -match 'fk_automated_notification_occurrence_notification') 'Occurrence must reference the generated notification'
Assert-True ($migration -match 'requires a forward corrective migration instead of rollback') 'Rollback must be forward-only'
Assert-True ($migration -notmatch '(?i)INSERT\s+INTO[\s\S]*?role_permission') 'Phase 1 must not reassign role permissions'
Assert-True ($migration -notmatch '(?i)DELETE\s+FROM[\s\S]*?permission_scope') 'Phase 1 must not delete permission scopes'

Write-Host 'Automated employee notification migration contract passed.' -ForegroundColor Green
