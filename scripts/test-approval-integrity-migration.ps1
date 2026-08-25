$ErrorActionPreference = 'Stop'

$migrationPath = Join-Path $PSScriptRoot '..\changelog\migrations\0064_approval_integrity\approval_integrity.xml'
$masterPath = Join-Path $PSScriptRoot '..\changelog\tenant.changelog-master.xml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $migrationPath) 'approval integrity migration file is missing'

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$master = Get-Content -Raw -LiteralPath $masterPath
$sql = (@($migration.SelectNodes("//*[local-name()='sql']") | ForEach-Object { $_.InnerText }) -join "`n") -replace '\s+', ' '

Assert-True ($sql -match 'CREATE UNIQUE INDEX\s+uq_workflow_action_terminal_actor') 'terminal workflow action unique index is missing'
Assert-True ($sql -match 'tenant_id\s*,\s*instance_id\s*,\s*workflow_step_id\s*,\s*performed_by\s*,\s*action') 'terminal workflow action index must include tenant, instance, step, actor, and action'
Assert-True ($sql -match "WHERE\s+action\s+IN\s*\(\s*'APPROVE'\s*,\s*'REJECT'\s*\)") 'terminal workflow action index must cover approve and reject actions only'
Assert-True ($migration.OuterXml -match 'name="approver_permission"\s+type="VARCHAR\(150\)"') 'workflow approver_permission column is missing'
Assert-True ($sql -match "WHEN\s+'LEAVE_REQUEST'\s+THEN\s+'leave:approve'") 'leave workflows must migrate to leave:approve'
Assert-True ($sql -match "WHEN\s+'TIMESHEET_WEEK_BATCH'\s+THEN\s+'timesheet:approve'") 'timesheet workflows must migrate to timesheet:approve'
Assert-True ($sql -match "WHEN\s+'ROLE'\s+THEN\s+'PERMISSION'") 'ROLE workflow steps must migrate to PERMISSION'
Assert-True ($sql -match 'ck_workflow_step_permission_authority') 'workflow permission authority check is missing'

$includes = @($master.SelectNodes("//*[local-name()='include']") | ForEach-Object { $_.GetAttribute('file') })
Assert-True ($includes -contains 'migrations/0064_approval_integrity/approval_integrity.xml') 'tenant master changelog must include 0064 approval integrity'

Write-Output 'Approval integrity migration contract passed.'
