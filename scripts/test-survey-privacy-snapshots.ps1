$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog/migrations/0082_survey_privacy_snapshots/survey_privacy_snapshots.xml'
$masterPath = Join-Path $root 'changelog/tenant.changelog-master.xml'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $migrationPath) '0082 survey privacy snapshot migration is missing'
[xml]$document = Get-Content -Raw -LiteralPath $migrationPath
$migration = Get-Content -Raw -LiteralPath $migrationPath
$master = Get-Content -Raw -LiteralPath $masterPath
$namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
$namespace.AddNamespace('db', 'http://www.liquibase.org/xml/ns/dbchangelog')

$structural = $document.SelectSingleNode('//db:changeSet[db:addColumn[@tableName="survey_assignment"]]', $namespace)
Assert-True ($null -ne $structural) 'A structural survey privacy changeset is required'
$preconditions = $structural.SelectSingleNode('./db:preConditions', $namespace)
Assert-True ($null -ne $preconditions) 'The structural changeset must guard empty survey data'
Assert-True ($preconditions.onFail -eq 'HALT') 'Unexpected survey rows must HALT on precondition failure'
Assert-True ($preconditions.onError -eq 'HALT') 'Survey precondition errors must HALT migration execution'
$emptyDataCheck = $preconditions.SelectSingleNode('./db:sqlCheck', $namespace)
Assert-True ($null -ne $emptyDataCheck -and $emptyDataCheck.expectedResult -eq '0') 'The empty-data guard must require a zero count'
$emptyDataSql = $emptyDataCheck.InnerText
Assert-True ($emptyDataSql -match 'COUNT\(\*\).*"\$\{schema\}"\.survey_assignment') 'The guard must count tenant survey assignments'
Assert-True ($emptyDataSql -match 'COUNT\(\*\).*"\$\{schema\}"\.survey_response') 'The guard must count tenant survey responses'

$add = $structural.SelectSingleNode('./db:addColumn[@tableName="survey_assignment" and @schemaName="${schema}"]', $namespace)
Assert-True ($null -ne $add) 'The assignment amendments must be tenant-schema qualified'
foreach ($column in @('completed', 'publication_department_id', 'publication_manager_employee_id')) {
    Assert-True ($null -ne $add.SelectSingleNode('./db:column[@name="' + $column + '"]', $namespace)) "Missing assignment column $column"
}
$completed = $add.SelectSingleNode('./db:column[@name="completed"]', $namespace)
Assert-True ($completed.defaultValueBoolean -eq 'false') 'Assignment completion must default to false'
Assert-True ($completed.SelectSingleNode('./db:constraints[@nullable="false"]', $namespace) -ne $null) 'Assignment completion must be non-null'

$assignmentDrop = $structural.SelectSingleNode('./db:dropColumn[@tableName="survey_assignment" and @schemaName="${schema}" and @columnName="completed_at"]', $namespace)
$responseDrop = $structural.SelectSingleNode('./db:dropColumn[@tableName="survey_response" and @schemaName="${schema}" and @columnName="submitted_at"]', $namespace)
Assert-True ($null -ne $assignmentDrop) 'completed_at must be dropped from tenant survey assignments'
Assert-True ($null -ne $responseDrop) 'submitted_at and its database default must be dropped from tenant survey responses'

$departmentSnapshotForeignKey = $structural.SelectSingleNode('./db:addForeignKeyConstraint[@baseTableSchemaName="${schema}" and @baseTableName="survey_assignment" and @baseColumnNames="publication_department_id" and @referencedTableSchemaName="${schema}" and @referencedTableName="department" and @referencedColumnNames="id" and @onDelete="SET NULL"]', $namespace)
$managerSnapshotForeignKey = $structural.SelectSingleNode('./db:addForeignKeyConstraint[@baseTableSchemaName="${schema}" and @baseTableName="survey_assignment" and @baseColumnNames="publication_manager_employee_id" and @referencedTableSchemaName="${schema}" and @referencedTableName="employee" and @referencedColumnNames="id" and @onDelete="SET NULL"]', $namespace)
Assert-True ($null -ne $departmentSnapshotForeignKey) 'Publication department snapshots must use a tenant-qualified SET NULL foreign key'
Assert-True ($null -ne $managerSnapshotForeignKey) 'Publication manager snapshots must use a tenant-qualified SET NULL foreign key'

$forwardWrites = $structural.SelectNodes('./db:insert | ./db:update | ./db:delete | ./db:sql', $namespace)
Assert-True ($forwardWrites.Count -eq 0) 'The correction must not rewrite survey rows'
Assert-True ($migration -match 'forward corrective migration') 'Rollback must halt instead of restoring identifying timestamps'
$rollback = $document.SelectSingleNode('//db:rollback', $namespace)
Assert-True ($null -ne $rollback) 'A forward-only rollback guard is required'
Assert-True ($rollback.SelectNodes('.//db:addColumn | .//db:dropColumn', $namespace).Count -eq 0) 'Rollback must not reconstruct timing columns'

$include = 'migrations/0082_survey_privacy_snapshots/survey_privacy_snapshots.xml'
Assert-True (([regex]::Matches($master, [regex]::Escape($include))).Count -eq 1) 'Tenant master must include 0082 exactly once'
Assert-True ($master.IndexOf('0081_leave_approval_queue_index/leave_approval_queue_index.xml') -lt $master.IndexOf($include)) '0082 must follow 0081 in the tenant master'

Write-Host 'Survey privacy snapshot migration contract passed.'
