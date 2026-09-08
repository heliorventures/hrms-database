$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog/migrations/0075_performance_appraisal_lifecycle/performance_appraisal_lifecycle.xml'
$masterPath = Join-Path $root 'changelog/tenant.changelog-master.xml'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $migrationPath) '0075 performance appraisal lifecycle migration is missing'
$migration = Get-Content -Raw -LiteralPath $migrationPath
$master = Get-Content -Raw -LiteralPath $masterPath

foreach ($table in @(
    'performance_program',
    'appraisal_template',
    'appraisal_template_section',
    'appraisal_question',
    'appraisal_question_option',
    'performance_participant',
    'appraisal_answer',
    'continuous_feedback',
    'performance_admin_exception'
)) {
    Assert-True ($migration -match ('tableName="' + [regex]::Escape($table) + '"')) "Missing $table"
}

foreach ($column in @('cadence', 'anchor_date', 'period_key', 'current_stage', 'manager_employee_id', 'self_submitted_at', 'manager_submitted_at', 'parent_question_id', 'question_type', 'answerer', 'self_rating_enabled', 'manager_rating_enabled')) {
    Assert-True ($migration -match ('name="' + [regex]::Escape($column) + '"')) "Missing $column"
}

Assert-True ($migration -match 'MONTHLY.+QUARTERLY.+YEARLY.+MANUAL') 'Cadence domain is incomplete'
Assert-True ($migration -match 'performance[\s\S]*?evaluate') 'performance:evaluate permission is missing'
Assert-True ($migration -match 'performance[\s\S]*?self') 'performance:self permission is missing'
Assert-True ($migration -match 'uq_review_cycle_program_period') 'Program period idempotency constraint is missing'
Assert-True ($migration -match 'uq_appraisal_answer_participant_question_revision') 'Answer revision uniqueness is missing'
Assert-True ($migration -match 'forward corrective migration') 'Durable appraisal data must be forward-only'
Assert-True ($master -match '0075_performance_appraisal_lifecycle/performance_appraisal_lifecycle.xml') 'Tenant master does not include 0075'

Write-Host 'Performance appraisal lifecycle migration contract passed.'
