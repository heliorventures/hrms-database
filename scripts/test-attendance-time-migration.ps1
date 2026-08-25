$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog\migrations\0065_attendance_time_integrity\attendance_time_integrity.xml'
$masterPath = Join-Path $root 'changelog\tenant.changelog-master.xml'
$migration = Get-Content -LiteralPath $migrationPath -Raw
$master = Get-Content -LiteralPath $masterPath -Raw

$required = @(
    'name="check_in_at" type="TIMESTAMPTZ"',
    'name="check_out_at" type="TIMESTAMPTZ"',
    'attendance_instant_backfill_audit',
    'uq_attendance_one_open',
    "status = 'COMPLETE'",
    "status = 'OPEN' AND check_out_time IS NOT NULL",
    'WHERE check_out_at IS NULL',
    "status = 'OPEN'",
    "status IN ('OPEN', 'INCOMPLETE')",
    'ck_attendance_completed_instants',
    'check_out_at > check_in_at'
)

foreach ($fragment in $required) {
    if (-not $migration.Contains($fragment)) {
        throw "Attendance time migration is missing required fragment: $fragment"
    }
}

if (-not $master.Contains('migrations/0065_attendance_time_integrity/attendance_time_integrity.xml')) {
    throw 'Tenant changelog does not include migration 0065.'
}

Write-Host 'Attendance time migration static checks passed.'
