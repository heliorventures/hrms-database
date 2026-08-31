$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog\migrations\0069_permission_contract_convergence\permission_contract_convergence.xml'
$masterPath = Join-Path $root 'changelog\tenant.changelog-master.xml'
$bootstrapPath = Join-Path $root 'scripts\bootstrap-tenant-admins.ps1'
$seedPath = Join-Path $root 'scripts\seed-demo-data.ps1'
$migrationInclude = 'migrations/0069_permission_contract_convergence/permission_contract_convergence.xml'
$previousMigrationInclude = 'migrations/0068_employee_status_integrity/employee_status_integrity.xml'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-NormalizedSql {
    param([xml]$Document)

    return (@($Document.SelectNodes("//*[local-name()='changeSet']/*[local-name()='sql']") | ForEach-Object {
        $_.InnerText
    }) -join "`n") -replace '\s+', ' '
}

function Assert-ExactSet {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Label
    )

    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    Assert-True ($Actual.Count -eq $actualSorted.Count) "$Label must not contain duplicate values"
    Assert-True (
        $actualSorted.Count -eq $expectedSorted.Count -and
        [string]::Join(',', $actualSorted) -eq [string]::Join(',', $expectedSorted)
    ) "$Label does not match the current permission contract"
}

function Get-WriterContract {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    $text = Get-Content -Raw -LiteralPath $Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True ($parseErrors.Count -eq 0) "$Path has PowerShell parse errors: $($parseErrors.Message -join '; ')"

    $assignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'CanonicalRbac'
    }, $true))
    Assert-True ($assignments.Count -eq 1) "$Path must define exactly one CanonicalRbac data expression"

    try {
        $config = & ([scriptblock]::Create($assignments[0].Right.Extent.Text))
    } catch {
        throw "$Path CanonicalRbac must be a self-contained data expression: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Config = $config
        Text = $text
    }
}

Assert-True (Test-Path -LiteralPath $migrationPath) 'permission contract convergence migration file is missing'

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$master = Get-Content -Raw -LiteralPath $masterPath

$changeSets = @($migration.SelectNodes("//*[local-name()='changeSet']"))
Assert-True ($changeSets.Count -eq 1) 'permission contract convergence migration must contain exactly one changeSet'
Assert-True ($changeSets[0].GetAttribute('id') -eq '0069-001-permission-contract-convergence') 'permission contract convergence changeSet id is incorrect'
Assert-True ($changeSets[0].GetAttribute('runInTransaction') -eq 'true') 'permission contract convergence must run in one transaction'
Assert-True (@($changeSets[0].SelectNodes("./*[local-name()='rollback']")).Count -eq 1) 'permission contract convergence must define rollback behavior'

$sql = Get-NormalizedSql -Document $migration
$includes = @($master.SelectNodes("//*[local-name()='include']") | ForEach-Object { $_.GetAttribute('file') })
$previousIndex = [array]::IndexOf($includes, $previousMigrationInclude)
$migrationIndex = [array]::IndexOf($includes, $migrationInclude)

Assert-True ($previousIndex -ge 0) 'tenant master changelog must retain migration 0068'
Assert-True ($migrationIndex -eq ($previousIndex + 1)) 'tenant master changelog must include migration 0069 immediately after 0068'
Assert-True ($includes[-1] -eq $migrationInclude) '0069 must be the final tenant migration'

Assert-True ($sql -match 'LOCK TABLE .*user_session.*workflow_step.*approval_rule.*expense_policy.*announcement.*NOWAIT') 'migration must lock every rewritten authorization consumer and user_session with NOWAIT'
Assert-True ($sql -match "'employee_directory'\s*,\s*'read'") 'directory permission is missing'
Assert-True ($sql -match "'employee'\s*,\s*'read'\s*,\s*'SELF'") 'employee self profile grant must use employee:read=SELF'
Assert-True ($sql -match "employee_grants.*'payroll'\s*,\s*'read'\s*,\s*'SELF'.*employee_derived_roles.*'MANAGER'") 'manager payroll access must remain SELF through the employee baseline'
Assert-True ($sql -match "'HR'\s*,\s*'payroll'\s*,\s*'read'\s*,\s*'ALL'") 'HR company payroll read authority is missing'
Assert-True ($sql -match "'HR'\s*,\s*'payroll'\s*,\s*'manage'\s*,\s*'ALL'") 'HR company payroll authority is missing'
Assert-True ($sql -match "SELECT\s+'ADMIN'.*ELSE\s+'ALL'.*FROM .*permission") 'Admin must receive every current permission with management actions scoped ALL'
Assert-True ($sql -match "'PAYROLL'\s*,\s*'HR'") 'PAYROLL role assignments must be mapped to HR before deletion'

Assert-True ($sql -match 'UPDATE .*workflow_step .*approver_role_id') 'workflow step role references must be remapped'
Assert-True ($sql -match 'UPDATE .*approval_rule .*approver_role_id') 'approval rule role references must be remapped'
Assert-True ($sql -match 'UPDATE .*expense_policy .*role_id') 'expense policy role references must be remapped'
Assert-True ($sql -match "UPDATE .*announcement .*target_audience\s*=\s*'ROLE:'") 'announcement role audiences must be remapped'
Assert-True ($sql -match 'DELETE FROM .*user_session') 'permission rewrite must revoke sessions'
Assert-True ($sql -match 'RAISE EXCEPTION') 'migration must fail closed on invariant violations'
Assert-True ($sql -match 'FROM canonical_permission_matrix .*LEFT JOIN .*permission .*WHERE permission\.id IS NULL') 'migration must fail when a canonical matrix permission is absent'

Assert-True ($sql -match 'DELETE FROM .*role .*PAYROLL') 'retired PAYROLL role must be deleted after reference remapping'
Assert-True ($sql -match 'DELETE FROM .*permission .*employee.*self') 'retired employee:self permission must be deleted after grant migration'
Assert-True ($sql -match 'canonical_roles.*EMPLOYEE.*MANAGER.*HR.*ADMIN') 'migration must declare the four current canonical role bundles'
Assert-True ($sql -match "IF EXISTS .*role.*PAYROLL.*RAISE EXCEPTION") 'final invariants must reject a remaining canonical PAYROLL role'
Assert-True ($sql -match "IF EXISTS .*permission.*employee.*self.*RAISE EXCEPTION") 'final invariants must reject a remaining employee:self permission'

$expectedRoles = @(
    'EMPLOYEE::FALSE:TRUE',
    'MANAGER:EMPLOYEE:FALSE:TRUE',
    'HR:EMPLOYEE:FALSE:TRUE',
    'ADMIN::TRUE:TRUE'
)
$expectedPermissions = @(
    'EMPLOYEE_DIRECTORY:READ:EMPLOYEE',
    'EMPLOYEE:READ:EMPLOYEE', 'EMPLOYEE:WRITE:EMPLOYEE', 'EMPLOYEE:MANAGE:EMPLOYEE',
    'NOTIFICATION:READ:EMPLOYEE', 'NOTIFICATION:MANAGE:EMPLOYEE', 'ROLE:MANAGE:EMPLOYEE',
    'ATTENDANCE:READ:ATTENDANCE', 'ATTENDANCE:PUNCH_SELF:ATTENDANCE', 'ATTENDANCE:REGULARIZE:ATTENDANCE', 'ATTENDANCE:PUNCH_POLICY:ATTENDANCE',
    'TIMESHEET:READ:ATTENDANCE', 'TIMESHEET:WRITE:ATTENDANCE', 'TIMESHEET:APPROVE:ATTENDANCE', 'TIMESHEET:MANAGE:ATTENDANCE',
    'LEAVE:READ:LEAVE', 'LEAVE:SUBMIT:LEAVE', 'LEAVE:APPROVE:LEAVE', 'LEAVE:MANAGE:LEAVE',
    'EXPENSE:READ:EXPENSE', 'EXPENSE:SUBMIT:EXPENSE', 'EXPENSE:APPROVE:EXPENSE', 'EXPENSE:MANAGE:EXPENSE', 'EXPENSE:PAY:EXPENSE',
    'TRAVEL:READ:EXPENSE', 'TRAVEL:SUBMIT:EXPENSE', 'TRAVEL:APPROVE:EXPENSE', 'TRAVEL:MANAGE:EXPENSE',
    'PAYROLL:READ:PAYROLL', 'PAYROLL:MANAGE:PAYROLL', 'PAYROLL:STATUTORY_EXPORT:PAYROLL',
    'TAX:READ:TAX', 'TAX:SUBMIT:TAX', 'TAX:APPROVE:TAX', 'TAX:MANAGE:TAX',
    'WORKFLOW:MANAGE:WORKFLOW'
)
$expectedGrants = @(
    'EMPLOYEE:EMPLOYEE_DIRECTORY:READ:ALL', 'EMPLOYEE:EMPLOYEE:READ:SELF',
    'EMPLOYEE:ATTENDANCE:READ:SELF', 'EMPLOYEE:ATTENDANCE:PUNCH_SELF:SELF',
    'EMPLOYEE:TIMESHEET:READ:SELF', 'EMPLOYEE:TIMESHEET:WRITE:SELF',
    'EMPLOYEE:LEAVE:READ:SELF', 'EMPLOYEE:LEAVE:SUBMIT:SELF',
    'EMPLOYEE:EXPENSE:READ:SELF', 'EMPLOYEE:EXPENSE:SUBMIT:SELF',
    'EMPLOYEE:TRAVEL:READ:SELF', 'EMPLOYEE:TRAVEL:SUBMIT:SELF',
    'EMPLOYEE:PAYROLL:READ:SELF', 'EMPLOYEE:TAX:READ:SELF', 'EMPLOYEE:TAX:SUBMIT:SELF',
    'EMPLOYEE:NOTIFICATION:READ:SELF',
    'EMPLOYEE:BENEFITS:SELF:SELF', 'EMPLOYEE:ONBOARDING:SELF:SELF', 'EMPLOYEE:GRIEVANCE:SELF:SELF', 'EMPLOYEE:ASSETS:SELF:SELF',
    'MANAGER:EMPLOYEE:READ:TEAM',
    'MANAGER:ATTENDANCE:READ:TEAM', 'MANAGER:ATTENDANCE:REGULARIZE:TEAM',
    'MANAGER:TIMESHEET:READ:TEAM', 'MANAGER:TIMESHEET:APPROVE:TEAM',
    'MANAGER:LEAVE:READ:TEAM', 'MANAGER:LEAVE:APPROVE:TEAM',
    'MANAGER:EXPENSE:READ:TEAM', 'MANAGER:EXPENSE:APPROVE:TEAM',
    'MANAGER:TRAVEL:READ:TEAM', 'MANAGER:TRAVEL:APPROVE:TEAM',
    'HR:EMPLOYEE:READ:ALL', 'HR:EMPLOYEE:WRITE:ALL', 'HR:EMPLOYEE:MANAGE:ALL',
    'HR:ATTENDANCE:READ:ALL', 'HR:ATTENDANCE:REGULARIZE:ALL', 'HR:ATTENDANCE:PUNCH_POLICY:ALL',
    'HR:TIMESHEET:READ:ALL', 'HR:TIMESHEET:APPROVE:ALL', 'HR:TIMESHEET:MANAGE:ALL',
    'HR:LEAVE:READ:ALL', 'HR:LEAVE:APPROVE:ALL', 'HR:LEAVE:MANAGE:ALL',
    'HR:EXPENSE:READ:ALL', 'HR:EXPENSE:APPROVE:ALL', 'HR:EXPENSE:MANAGE:ALL', 'HR:EXPENSE:PAY:ALL',
    'HR:TRAVEL:READ:ALL', 'HR:TRAVEL:APPROVE:ALL', 'HR:TRAVEL:MANAGE:ALL',
    'HR:PAYROLL:READ:ALL', 'HR:PAYROLL:MANAGE:ALL', 'HR:PAYROLL:STATUTORY_EXPORT:ALL',
    'HR:TAX:READ:ALL', 'HR:TAX:APPROVE:ALL', 'HR:TAX:MANAGE:ALL',
    'HR:WORKFLOW:MANAGE:ALL', 'HR:NOTIFICATION:MANAGE:ALL',
    'HR:BENEFITS:MANAGE:ALL', 'HR:RECRUITMENT:MANAGE:ALL', 'HR:ONBOARDING:MANAGE:ALL',
    'HR:PERFORMANCE:MANAGE:ALL', 'HR:LEARNING:MANAGE:ALL', 'HR:ASSETS:MANAGE:ALL',
    'HR:GRIEVANCE:MANAGE:ALL', 'HR:SUCCESSION:MANAGE:ALL', 'HR:COMPENSATION:MANAGE:ALL', 'HR:ANALYTICS:READ:ALL'
)
$expectedAdminSelfScopes = @(
    '*:SELF', 'ATTENDANCE:PUNCH_SELF', 'TIMESHEET:WRITE', 'LEAVE:SUBMIT',
    'EXPENSE:SUBMIT', 'TRAVEL:SUBMIT', 'TAX:SUBMIT', 'NOTIFICATION:READ'
)

$bootstrapContract = Get-WriterContract -Path $bootstrapPath
$seedContract = Get-WriterContract -Path $seedPath
foreach ($writer in @(
    [pscustomobject]@{ Label = 'bootstrap'; Contract = $bootstrapContract },
    [pscustomobject]@{ Label = 'demo seed'; Contract = $seedContract }
)) {
    $config = $writer.Contract.Config
    Assert-ExactSet @($config.Roles | ForEach-Object {
        "$($_.Name):$($_.Inherits):$($_.AllPermissions):$($_.BootstrapManaged)".ToUpperInvariant()
    }) $expectedRoles "$($writer.Label) roles"
    Assert-ExactSet @($config.Permissions | ForEach-Object {
        "$($_.Resource):$($_.Action):$($_.Module)".ToUpperInvariant()
    }) $expectedPermissions "$($writer.Label) permissions"
    Assert-ExactSet @($config.Grants | ForEach-Object {
        "$($_.Role):$($_.Resource):$($_.Action):$($_.Scope)".ToUpperInvariant()
    }) $expectedGrants "$($writer.Label) grants"
    Assert-ExactSet @($config.AdminSelfScopes | ForEach-Object {
        "$($_.Resource):$($_.Action)".ToUpperInvariant()
    }) $expectedAdminSelfScopes "$($writer.Label) admin self scopes"
    Assert-True (-not ($config.Permissions | Where-Object {
        $_.Resource -eq 'employee' -and $_.Action -eq 'self'
    })) "$($writer.Label) must not recreate employee:self"
    Assert-True (-not ($config.Roles | Where-Object { $_.Name -eq 'PAYROLL' })) "$($writer.Label) must not recreate the retired PAYROLL role"
}

$personaRoleMatch = [regex]::Match(
    $seedContract.Text,
    'seeded_persona_roles\s*\(\s*user_id\s*,\s*role_name\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*''\$[A-Za-z][A-Za-z0-9]*''\s*,\s*''[A-Z]+''\s*\)\s*,?\s*)+)\)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $personaRoleMatch.Success 'demo seed must define explicit canonical persona assignments'
$actualPersonaRoles = @([regex]::Matches(
    $personaRoleMatch.Groups['values'].Value,
    '''\$(?<user>[A-Za-z][A-Za-z0-9]*)''\s*,\s*''(?<role>[A-Z]+)'''
) | ForEach-Object {
    "$($_.Groups['user'].Value)->$($_.Groups['role'].Value)".ToUpperInvariant()
})
Assert-ExactSet $actualPersonaRoles @(
    'STAFFUSERID->EMPLOYEE', 'MANAGERUSERID->MANAGER', 'USERID->HR',
    'ACCOUNTINGUSERID->HR', 'TENANTADMINUSERID->ADMIN'
) 'demo persona assignments'

foreach ($workflowStage in @(
    @{ StepVariable = 'WorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE' },
    @{ StepVariable = 'ExpenseWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE' },
    @{ StepVariable = 'ExpenseWorkflowStep2Id'; ApproverType = 'ROLE' },
    @{ StepVariable = 'TravelWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE' },
    @{ StepVariable = 'TravelWorkflowStep2Id'; ApproverType = 'ROLE' },
    @{ StepVariable = 'TimesheetWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE' }
)) {
    $stepLiteral = "'" + '$' + $workflowStage.StepVariable + "'"
    $stepPattern = [regex]::Escape($stepLiteral) +
        ".{0,600}'$([regex]::Escape($workflowStage.ApproverType))'\s*,\s*\(\s*SELECT\s+canonical_role\.id.{0,400}UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*'HR'"
    Assert-True (
        ([regex]::Matches(
            $seedContract.Text,
            $stepPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
        )).Count -eq 1
    ) "demo workflow $($workflowStage.StepVariable) must route through the canonical HR permission bundle"
}

Assert-True (-not ($seedContract.Text -match "canonical_role\.name\)\)\s*=\s*'PAYROLL'")) 'demo workflows must not route to the retired PAYROLL role'

Write-Output 'Permission contract convergence migration passed.'
