$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$relative = 'migrations/0084_survey_targeting_corrections/survey_targeting_corrections.xml'
[xml]$doc = Get-Content -Raw -LiteralPath (Join-Path $root ('changelog/' + $relative))
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('db', 'http://www.liquibase.org/xml/ns/dbchangelog')
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$change = $doc.SelectSingleNode('//db:changeSet', $ns)
Assert-True ($change.preConditions.onFail -eq 'HALT' -and $change.preConditions.onError -eq 'HALT') 'Unexpected historical responses must halt'
Assert-True ($change.preConditions.sqlCheck.InnerText -match 'survey_assignment' -and $change.preConditions.sqlCheck.InnerText -match 'survey_response') 'Guard must cover assignments and responses'
foreach ($table in @('survey_audience_location', 'survey_audience_employee', 'survey_revision')) {
    Assert-True ($null -ne $change.SelectSingleNode('./db:addPrimaryKey[@tableName="' + $table + '"]', $ns)) "Missing primary key for $table"
    Assert-True ($change.SelectNodes('./db:addForeignKeyConstraint[@baseTableName="' + $table + '" and @referencedColumnNames="tenant_id,id"]', $ns).Count -eq 2) "Tenant-qualified survey and target references required for $table"
}
foreach ($table in @('survey_assignment', 'survey_response')) {
    Assert-True ($null -ne $change.SelectSingleNode('./db:addForeignKeyConstraint[@baseTableName="' + $table + '" and @referencedTableName="location" and @onDelete="SET NULL"]', $ns)) "Nullable location snapshot required for $table"
    Assert-True ($null -ne $change.SelectSingleNode('./db:addForeignKeyConstraint[@baseTableName="' + $table + '" and @referencedColumnNames="tenant_id,id" and @deferrable="true" and @initiallyDeferred="true"]', $ns)) "Snapshot tenant ownership must be enforced for $table"
}
Assert-True ($null -ne $change.SelectSingleNode('./db:addPrimaryKey[@tableName="survey_audience_scope"]', $ns)) 'Audience kind must be durable independently of selected mapping rows'
Assert-True ($null -ne $change.SelectSingleNode('./db:addForeignKeyConstraint[@baseTableName="survey_audience_scope" and @baseColumnNames="tenant_id,survey_id"]', $ns)) 'Audience kind must reference its tenant survey'
Assert-True ($change.SelectNodes('./db:sql | ./db:insert | ./db:update | ./db:delete', $ns).Count -eq 0) 'Migration must not rewrite historical data'
Assert-True ($change.rollback.sql.InnerText -match 'RAISE EXCEPTION') 'Rollback must require a forward correction'
$master = Get-Content -Raw -LiteralPath (Join-Path $root 'changelog/tenant.changelog-master.xml')
Assert-True (([regex]::Matches($master, [regex]::Escape($relative))).Count -eq 1) 'Migration must be included exactly once'
Write-Host 'Survey targeting and correction migration contract passed.'
