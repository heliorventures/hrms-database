$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog/migrations/0076_anonymous_surveys/anonymous_surveys.xml'
$masterPath = Join-Path $root 'changelog/tenant.changelog-master.xml'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $migrationPath) '0076 anonymous survey migration is missing'
$migration = Get-Content -Raw -LiteralPath $migrationPath
$master = Get-Content -Raw -LiteralPath $masterPath

foreach ($table in @('survey', 'survey_audience_department', 'survey_section', 'survey_question', 'survey_question_option', 'survey_assignment', 'survey_response', 'survey_answer')) {
    Assert-True ($migration -match ('tableName="' + [regex]::Escape($table) + '"')) "Missing $table"
}
foreach ($column in @('minimum_report_group_size', 'dimension', 'manager_employee_id', 'department_id', 'completed_at', 'selected_option_ids', 'numeric_answer', 'text_answer')) {
    Assert-True ($migration -match ('name="' + [regex]::Escape($column) + '"')) "Missing $column"
}
Assert-True ($migration -match 'minimum_report_group_size.+?&gt;= 3') 'Survey threshold must never be below 3'
$responseTable = [regex]::Match($migration, '<createTable tableName="survey_response"[\s\S]*?</createTable>').Value
Assert-True ($responseTable -notmatch '<column name="employee_id"') 'Anonymous survey_response must not store employee_id'
Assert-True ($migration -match "'manage'.+'respond'.+'results'") 'Survey RBAC permissions are incomplete'
Assert-True ($migration -match 'forward corrective migration') 'Durable survey responses must be forward-only'
Assert-True ($master -match '0076_anonymous_surveys/anonymous_surveys.xml') 'Tenant master does not include 0076'

Write-Host 'Anonymous survey migration contract passed.'
