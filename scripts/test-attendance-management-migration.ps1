$ErrorActionPreference = 'Stop'

$migrationPath = Join-Path $PSScriptRoot '..\changelog\migrations\0063_attendance_management\attendance_management.xml'
$masterPath = Join-Path $PSScriptRoot '..\changelog\tenant.changelog-master.xml'
$seedPath = Join-Path $PSScriptRoot 'seed-demo-data.ps1'

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

    return ((Get-NormalizedSqlStatements -Document $Document) -join "`n")
}

function Get-NormalizedSqlStatements {
    param([xml]$Document)

    return @($Document.SelectNodes("//*[local-name()='sql']") | ForEach-Object {
        $_.InnerText `
        -replace '(?s)/\*.*?\*/', ' ' `
        -replace '\s+', ' ' `
        -replace '\s*([(),;])\s*', '$1 '
    })
}

function Assert-ExactRegularizeRoles {
    param(
        [string]$GrantSql,
        [string]$GrantName
    )

    $rolePredicate = [regex]::Match(
        $GrantSql,
        "UPPER\(\s*TRIM\(\s*tenant_role\.name\s*\)\s*\)\s*IN\(\s*(?<roles>[^)]*)\)"
    )
    Assert-True $rolePredicate.Success "$GrantName must filter active_admin_roles by an explicit role-name set"
    $actualRoles = @([regex]::Matches($rolePredicate.Groups['roles'].Value, "'(?<role>[A-Z_]+)'") | ForEach-Object {
        $_.Groups['role'].Value
    } | Sort-Object -Unique)
    $expectedRoles = @('HR_ADMIN', 'ORG_ADMIN', 'TENANT_ADMIN')
    Assert-True (
        $actualRoles.Count -eq $expectedRoles.Count -and
        [string]::Join(',', $actualRoles) -eq [string]::Join(',', $expectedRoles)
    ) "$GrantName must target exactly HR_ADMIN, TENANT_ADMIN, and ORG_ADMIN"
}

function Get-PowerShellAst {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True ($parseErrors.Count -eq 0) "seed script has PowerShell parse errors: $($parseErrors.Message -join '; ')"
    return $ast
}

Assert-True (Test-Path -LiteralPath $migrationPath) 'attendance management migration file is missing'

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$master = Get-Content -Raw -LiteralPath $masterPath

$auditTable = @($migration.SelectNodes("//*[local-name()='createTable' and @tableName='attendance_adjustment_audit' and @schemaName='`${schema}']"))
Assert-True ($auditTable.Count -eq 1) 'attendance_adjustment_audit must be created once in the tenant schema'

$columns = @{}
foreach ($column in $auditTable[0].SelectNodes("./*[local-name()='column']")) {
    $columns[$column.GetAttribute('name')] = $column
}

$requiredColumns = [ordered]@{
    id = 'UUID'
    tenant_id = 'UUID'
    attendance_id = 'UUID'
    target_employee_id = 'UUID'
    actor_user_id = 'UUID'
    operation = 'VARCHAR(10)'
    reason = 'VARCHAR(500)'
    after_values = 'JSONB'
    created_at = 'TIMESTAMPTZ'
}
foreach ($required in $requiredColumns.GetEnumerator()) {
    Assert-True $columns.ContainsKey($required.Key) "required audit column $($required.Key) is missing"
    Assert-True ($columns[$required.Key].GetAttribute('type') -eq $required.Value) "audit column $($required.Key) must use type $($required.Value)"
    $constraints = $columns[$required.Key].SelectSingleNode("./*[local-name()='constraints']")
    Assert-True ($null -ne $constraints -and $constraints.GetAttribute('nullable') -eq 'false') "audit column $($required.Key) must be non-null"
}
foreach ($nullable in ([ordered]@{ before_values = 'JSONB'; request_id = 'VARCHAR(128)' }).GetEnumerator()) {
    Assert-True $columns.ContainsKey($nullable.Key) "nullable audit column $($nullable.Key) is missing"
    Assert-True ($columns[$nullable.Key].GetAttribute('type') -eq $nullable.Value) "audit column $($nullable.Key) must use type $($nullable.Value)"
    $constraints = $columns[$nullable.Key].SelectSingleNode("./*[local-name()='constraints']")
    Assert-True ($null -eq $constraints -or $constraints.GetAttribute('nullable') -ne 'false') "audit column $($nullable.Key) must remain nullable"
}

$foreignKeys = @($migration.SelectNodes("//*[local-name()='addForeignKeyConstraint' and @baseTableName='attendance_adjustment_audit' and @baseTableSchemaName='`${schema}']"))
foreach ($foreignKey in @(
    @{ Column = 'attendance_id'; Table = 'attendance'; Name = 'fk_attendance_adjustment_audit_attendance' },
    @{ Column = 'target_employee_id'; Table = 'employee'; Name = 'fk_attendance_adjustment_audit_employee' },
    @{ Column = 'actor_user_id'; Table = 'user'; Name = 'fk_attendance_adjustment_audit_actor' }
)) {
    $match = @($foreignKeys | Where-Object {
        $_.GetAttribute('baseColumnNames') -eq $foreignKey.Column -and
        $_.GetAttribute('referencedTableName') -eq $foreignKey.Table -and
        $_.GetAttribute('referencedTableSchemaName') -eq '${schema}' -and
        $_.GetAttribute('constraintName') -eq $foreignKey.Name -and
        $_.GetAttribute('onDelete') -eq 'RESTRICT'
    })
    Assert-True ($match.Count -eq 1) "audit foreign key $($foreignKey.Name) must restrict deletion in the tenant schema"
}

$indexes = @($migration.SelectNodes("//*[local-name()='createIndex' and @tableName='attendance_adjustment_audit' and @schemaName='`${schema}']"))
foreach ($index in @(
    @{ Name = 'idx_attendance_adjustment_audit_attendance'; First = 'attendance_id' },
    @{ Name = 'idx_attendance_adjustment_audit_employee'; First = 'target_employee_id' },
    @{ Name = 'idx_attendance_adjustment_audit_actor'; First = 'actor_user_id' }
)) {
    $match = @($indexes | Where-Object { $_.GetAttribute('indexName') -eq $index.Name })
    Assert-True ($match.Count -eq 1) "audit index $($index.Name) is missing"
    $indexColumns = @($match[0].SelectNodes("./*[local-name()='column']"))
    Assert-True ($indexColumns.Count -eq 2 -and $indexColumns[0].GetAttribute('name') -eq $index.First) "audit index $($index.Name) must start with $($index.First)"
    Assert-True ($indexColumns[1].GetAttribute('name') -eq 'created_at' -and $indexColumns[1].GetAttribute('descending') -eq 'true') "audit index $($index.Name) must order created_at descending"
}

$sqlStatements = Get-NormalizedSqlStatements -Document $migration
$sql = $sqlStatements -join "`n"
foreach ($check in @(
    'ADD CONSTRAINT\s+chk_attendance_adjustment_audit_operation\s+CHECK\(\s*operation\s+IN\(\s*''CREATE''\s*,\s*''UPDATE''\s*\)\s*\)',
    'ADD CONSTRAINT\s+chk_attendance_adjustment_audit_reason\s+CHECK\(\s*char_length\(\s*trim\(\s*reason\s*\)\s*\)\s+BETWEEN\s+5\s+AND\s+500\s*\)',
    'ADD CONSTRAINT\s+chk_attendance_adjustment_audit_before_values\s+CHECK\(\s*\(\s*operation\s*=\s*''CREATE''\s+AND\s+before_values\s+IS\s+NULL\s*\)\s+OR\s*\(\s*operation\s*=\s*''UPDATE''\s+AND\s+before_values\s+IS\s+NOT\s+NULL\s*\)\s*\)'
)) {
    Assert-True ($sql -match $check) "audit check constraint is missing or has the wrong invariant: $check"
}

$immutabilitySql = @($sqlStatements | Where-Object {
    $_ -match 'CREATE OR REPLACE FUNCTION\s+"?\$\{schema\}"?\.prevent_attendance_adjustment_audit_mutation\s*\('
})
Assert-True ($immutabilitySql.Count -eq 1) 'audit immutability function is missing'
Assert-True ($immutabilitySql[0] -match "RETURNS\s+TRIGGER\s+LANGUAGE\s+plpgsql") 'audit immutability function must be a PostgreSQL trigger function'
Assert-True ($immutabilitySql[0] -match "RAISE\s+EXCEPTION\s+'attendance_adjustment_audit is append-only'") 'audit immutability function must reject mutations'
Assert-True ($immutabilitySql[0] -match 'CREATE\s+TRIGGER\s+trg_attendance_adjustment_audit_append_only\s+BEFORE\s+UPDATE\s+OR\s+DELETE\s+ON\s+"?\$\{schema\}"?\.attendance_adjustment_audit\s+FOR\s+EACH\s+ROW\s+EXECUTE\s+FUNCTION\s+"?\$\{schema\}"?\.prevent_attendance_adjustment_audit_mutation\s*\(') 'audit immutability trigger must reject both UPDATE and DELETE'

Assert-True ($sql -match 'INSERT INTO\s+"?\$\{schema\}"?\.permission') 'regularize permission insert is missing'
Assert-True ($sql -match "'attendance'\s*,\s*'regularize'") 'regularize permission must use attendance:regularize'
Assert-True ($sql -match "module\.code\s*=\s*'ATTENDANCE'") 'regularize permission must be constrained to the Attendance module'
Assert-True ($sql -match "subscription\.status\s*=\s*'ACTIVE'") 'regularize permission must be constrained to active subscriptions'
$rolePermissionGrant = @($sqlStatements | Where-Object { $_ -match 'INSERT INTO\s+"?\$\{schema\}"?\.role_permission' })
Assert-True ($rolePermissionGrant.Count -eq 1) 'regularize role permission grant is missing or ambiguous'
Assert-ExactRegularizeRoles -GrantSql $rolePermissionGrant[0] -GrantName 'role permission grant'
Assert-True ($rolePermissionGrant[0] -match 'FROM\s+active_admin_roles\s+CROSS\s+JOIN\s+regularize_permission') 'role permission grant must consume only active_admin_roles and the regularize permission'

$scopeGrant = @($sqlStatements | Where-Object { $_ -match 'INSERT INTO\s+"?\$\{schema\}"?\.permission_scope' })
Assert-True ($scopeGrant.Count -eq 1) 'regularize scope grant is missing or ambiguous'
Assert-ExactRegularizeRoles -GrantSql $scopeGrant[0] -GrantName 'permission scope grant'
Assert-True ($scopeGrant[0] -match "SELECT\s+gen_random_uuid\(\s*\)\s*,\s*active_admin_roles\.tenant_id\s*,\s*active_admin_roles\.id\s*,\s*'attendance'\s*,\s*'regularize'\s*,\s*'ALL'\s+FROM\s+active_admin_roles") 'regularize scope grant must assign ALL to active_admin_roles'
Assert-True ($scopeGrant[0] -match "ON CONFLICT\(\s*role_id, resource, action\)\s*DO UPDATE SET scope_type = EXCLUDED\.scope_type") 'regularize scope must upsert the ALL scope'

$auditRollback = @($migration.SelectNodes("//*[local-name()='rollback']/*[local-name()='dropTable' and @tableName='attendance_adjustment_audit' and @schemaName='`${schema}']"))
Assert-True ($auditRollback.Count -eq 1) 'audit rollback must drop the audit table'
$rollbackSql = (@($migration.SelectNodes("//*[local-name()='rollback']/*[local-name()='sql']")) | ForEach-Object { $_.InnerText }) -join "`n"
Assert-True ($rollbackSql -match 'DROP\s+TRIGGER\s+IF\s+EXISTS\s+trg_attendance_adjustment_audit_append_only\s+ON\s+"?\$\{schema\}"?\.attendance_adjustment_audit') 'audit rollback must drop the immutability trigger'
Assert-True ($rollbackSql -match 'DROP\s+FUNCTION\s+IF\s+EXISTS\s+"?\$\{schema\}"?\.prevent_attendance_adjustment_audit_mutation\s*\(\s*\)') 'audit rollback must drop the immutability function'
Assert-True ($rollbackSql -match 'SELECT\s+1;') 'authorization rollback must be an intentional no-op'

$includeFiles = @($master.SelectNodes("//*[local-name()='include']") | ForEach-Object { $_.GetAttribute('file') })
$previousIndex = [Array]::IndexOf($includeFiles, 'migrations/0062_private_file_cleanup_hardening/private_file_cleanup_hardening.xml')
$currentIndex = [Array]::IndexOf($includeFiles, 'migrations/0063_attendance_management/attendance_management.xml')
Assert-True ($previousIndex -ge 0 -and $currentIndex -eq ($previousIndex + 1)) '0063 must be registered immediately after 0062'

$seedAst = Get-PowerShellAst -Path $seedPath
$assignments = @($seedAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
foreach ($scopeVariable in @('ScopeAttendanceRegularizeAllId', 'ScopeAttendanceRegularizeTeamLmId')) {
    $assignment = @($assignments | Where-Object { $_.Left.VariablePath.UserPath -eq $scopeVariable })
    Assert-True ($assignment.Count -eq 1) "seed must define deterministic `$${scopeVariable}"
    Assert-True ($assignment[0].Right.Extent.Text -match 'New-DeterministicUuid') "`$${scopeVariable} must be deterministic"
}

$seedSqlNodes = @($seedAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))
$scopeInsert = @($seedSqlNodes | Where-Object { $_.Extent.Text -match 'INSERT\s+INTO\s+"\$Schema"\.permission_scope' })
Assert-True ($scopeInsert.Count -ge 1) 'seed must contain a permission_scope insert'
$seedSql = ($scopeInsert | ForEach-Object { $_.Extent.Text }) -join "`n"
$seedHrAdminPattern = (@('$ScopeAttendanceRegularizeAllId', '$TenantId', '$RoleHrAdminId', 'attendance', 'regularize', 'ALL') | ForEach-Object {
    "'$([regex]::Escape($_))'"
}) -join '\s*,\s*'
$seedLineManagerPattern = (@('$ScopeAttendanceRegularizeTeamLmId', '$TenantId', '$RoleLineManagerId', 'attendance', 'regularize', 'TEAM') | ForEach-Object {
    "'$([regex]::Escape($_))'"
}) -join '\s*,\s*'
Assert-True ($seedSql -match $seedHrAdminPattern) 'seed must grant HR_ADMIN ALL attendance regularization'
Assert-True ($seedSql -match $seedLineManagerPattern) 'seed must grant LINE_MANAGER TEAM attendance regularization explicitly'

Write-Host 'Attendance management migration contract passed.'
