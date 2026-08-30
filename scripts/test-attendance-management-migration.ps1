$ErrorActionPreference = 'Stop'

$migrationPath = Join-Path $PSScriptRoot '..\changelog\migrations\0063_attendance_management\attendance_management.xml'
$canonicalMigrationPath = Join-Path $PSScriptRoot '..\changelog\migrations\0067_canonical_rbac_authorization\canonical_rbac_authorization.xml'
$masterPath = Join-Path $PSScriptRoot '..\changelog\tenant.changelog-master.xml'
$seedPath = Join-Path $PSScriptRoot 'seed-demo-data.ps1'
$bootstrapPath = Join-Path $PSScriptRoot 'bootstrap-tenant-admins.ps1'

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

function Assert-HistoricalRegularizeRoles {
    param(
        [string]$GrantSql,
        [string]$GrantName
    )

    $rolePredicate = [regex]::Match(
        $GrantSql,
        "UPPER\(\s*TRIM\(\s*tenant_role\.name\s*\)\s*\)\s*IN\(\s*(?<roles>[^)]*)\)"
    )
    Assert-True $rolePredicate.Success "$GrantName must preserve the historical 0063 compatibility role-name set"
    $actualRoles = @([regex]::Matches($rolePredicate.Groups['roles'].Value, "'(?<role>[A-Z_]+)'") | ForEach-Object {
        $_.Groups['role'].Value
    } | Sort-Object -Unique)
    $expectedRoles = @('HR_ADMIN', 'ORG_ADMIN', 'TENANT_ADMIN')
    Assert-True (
        $actualRoles.Count -eq $expectedRoles.Count -and
        [string]::Join(',', $actualRoles) -eq [string]::Join(',', $expectedRoles)
    ) "$GrantName must preserve exactly the historical HR_ADMIN, TENANT_ADMIN, and ORG_ADMIN compatibility set"
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

function Get-CanonicalRbacConfig {
    param(
        [string]$Path,
        [string]$WriterLabel
    )

    $ast = Get-PowerShellAst -Path $Path
    $assignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'CanonicalRbac'
    }, $true))
    Assert-True ($assignments.Count -eq 1) "$WriterLabel must define exactly one `$CanonicalRbac data structure"
    try {
        return & ([scriptblock]::Create($assignments[0].Right.Extent.Text))
    } catch {
        throw "$WriterLabel `$CanonicalRbac must be a self-contained PowerShell data expression: $($_.Exception.Message)"
    }
}

function Assert-CanonicalAttendanceOutcomes {
    param(
        [object]$Config,
        [string]$WriterLabel
    )

    $grantMap = @{}
    foreach ($grant in $Config.Grants) {
        $grantMap["$($grant.Role):$($grant.Resource):$($grant.Action)".ToUpperInvariant()] = $grant.Scope.ToUpperInvariant()
    }
    foreach ($expectedGrant in @(
        @{ Key = 'EMPLOYEE:ATTENDANCE:READ'; Scope = 'SELF' },
        @{ Key = 'EMPLOYEE:ATTENDANCE:PUNCH_SELF'; Scope = 'SELF' },
        @{ Key = 'MANAGER:ATTENDANCE:READ'; Scope = 'TEAM' },
        @{ Key = 'MANAGER:ATTENDANCE:REGULARIZE'; Scope = 'TEAM' },
        @{ Key = 'HR:ATTENDANCE:READ'; Scope = 'ALL' },
        @{ Key = 'HR:ATTENDANCE:REGULARIZE'; Scope = 'ALL' },
        @{ Key = 'HR:ATTENDANCE:PUNCH_POLICY'; Scope = 'ALL' }
    )) {
        Assert-True $grantMap.ContainsKey($expectedGrant.Key) "$WriterLabel is missing canonical attendance grant $($expectedGrant.Key)"
        Assert-True ($grantMap[$expectedGrant.Key] -eq $expectedGrant.Scope) "$WriterLabel $($expectedGrant.Key) must use $($expectedGrant.Scope) scope"
    }

    $adminSelfScopes = @($Config.AdminSelfScopes | ForEach-Object {
        "$($_.Resource):$($_.Action)".ToUpperInvariant()
    })
    Assert-True ($adminSelfScopes -contains 'ATTENDANCE:PUNCH_SELF') "$WriterLabel ADMIN must keep attendance:punch_self at SELF"
    Assert-True ($adminSelfScopes -notcontains 'ATTENDANCE:READ') "$WriterLabel ADMIN attendance:read must resolve to ALL"
    Assert-True ($adminSelfScopes -notcontains 'ATTENDANCE:REGULARIZE') "$WriterLabel ADMIN attendance:regularize must resolve to ALL"
    Assert-True ($adminSelfScopes -notcontains 'ATTENDANCE:PUNCH_POLICY') "$WriterLabel ADMIN attendance:punch_policy must resolve to ALL"
}

Assert-True (Test-Path -LiteralPath $migrationPath) 'attendance management migration file is missing'
Assert-True (Test-Path -LiteralPath $canonicalMigrationPath) 'canonical RBAC migration 0067 is missing'
Assert-True (Test-Path -LiteralPath $bootstrapPath) 'tenant-admin bootstrap writer is missing'

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$canonicalMigration = Get-Content -Raw -LiteralPath $canonicalMigrationPath
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
Assert-HistoricalRegularizeRoles -GrantSql $rolePermissionGrant[0] -GrantName 'historical 0063 role permission grant'
Assert-True ($rolePermissionGrant[0] -match 'FROM\s+active_admin_roles\s+CROSS\s+JOIN\s+regularize_permission') 'role permission grant must consume only active_admin_roles and the regularize permission'

$scopeGrant = @($sqlStatements | Where-Object { $_ -match 'INSERT INTO\s+"?\$\{schema\}"?\.permission_scope' })
Assert-True ($scopeGrant.Count -eq 1) 'regularize scope grant is missing or ambiguous'
Assert-HistoricalRegularizeRoles -GrantSql $scopeGrant[0] -GrantName 'historical 0063 permission scope grant'
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
$canonicalIndex = [Array]::IndexOf($includeFiles, 'migrations/0067_canonical_rbac_authorization/canonical_rbac_authorization.xml')
Assert-True ($previousIndex -ge 0 -and $currentIndex -eq ($previousIndex + 1)) '0063 must be registered immediately after 0062'
Assert-True ($canonicalIndex -gt $currentIndex) '0067 canonical RBAC must run after historical 0063 compatibility grants'

$canonicalSql = Get-NormalizedSql -Document $canonicalMigration
foreach ($canonicalOutcome in @(
    "\(\s*'attendance'\s*,\s*'read'\s*,\s*'SELF'\s*\)",
    "\(\s*'attendance'\s*,\s*'punch_self'\s*,\s*'SELF'\s*\)",
    "\(\s*'MANAGER'\s*,\s*'attendance'\s*,\s*'read'\s*,\s*'TEAM'\s*\)",
    "\(\s*'MANAGER'\s*,\s*'attendance'\s*,\s*'regularize'\s*,\s*'TEAM'\s*\)",
    "\(\s*'HR'\s*,\s*'attendance'\s*,\s*'read'\s*,\s*'ALL'\s*\)",
    "\(\s*'HR'\s*,\s*'attendance'\s*,\s*'regularize'\s*,\s*'ALL'\s*\)",
    "\(\s*'HR'\s*,\s*'attendance'\s*,\s*'punch_policy'\s*,\s*'ALL'\s*\)"
)) {
    Assert-True ($canonicalSql -match $canonicalOutcome) "0067 must establish canonical attendance outcome: $canonicalOutcome"
}
Assert-True ($canonicalSql -match "SELECT\s*'ADMIN'.*?FROM\s+`"?\$\{schema\}`"?\.permission" ) '0067 ADMIN attendance authorization must derive from permission outcomes, not a role-name allowlist'

$seedConfig = Get-CanonicalRbacConfig -Path $seedPath -WriterLabel 'demo seed'
$bootstrapConfig = Get-CanonicalRbacConfig -Path $bootstrapPath -WriterLabel 'tenant-admin bootstrap'
Assert-CanonicalAttendanceOutcomes -Config $seedConfig -WriterLabel 'demo seed'
Assert-CanonicalAttendanceOutcomes -Config $bootstrapConfig -WriterLabel 'tenant-admin bootstrap'

Write-Host 'Attendance management migration contract passed.'
