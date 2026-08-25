$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog\migrations\0066_lifecycle_validation_integrity\lifecycle_validation_integrity.xml'
$masterPath = Join-Path $root 'changelog\tenant.changelog-master.xml'
$migration = Get-Content -LiteralPath $migrationPath -Raw
$master = Get-Content -LiteralPath $masterPath -Raw

$required = @(
    'name="offboarded_at" type="TIMESTAMPTZ"',
    'name="offboarding_event_id" type="UUID"',
    'uq_separation_offboarding_event',
    'fk_separation_offboarding_event',
    'initiallyDeferred="true"',
    'idx_separation_due_offboarding',
    "status = 'APPROVED'",
    'offboarded_at IS NULL',
    'ck_separation_offboarding_marker',
    'SET hours_worked = ROUND(hours_worked, 2)',
    'ck_timesheet_hours_two_decimals',
    'CHECK (hours_worked = ROUND(hours_worked, 2))'
)

foreach ($fragment in $required) {
    if (-not $migration.Contains($fragment)) {
        throw "Lifecycle validation migration is missing required fragment: $fragment"
    }
}

if (-not $master.Contains('migrations/0066_lifecycle_validation_integrity/lifecycle_validation_integrity.xml')) {
    throw 'Tenant changelog does not include migration 0066.'
}

Write-Host 'Lifecycle validation migration static checks passed.'
