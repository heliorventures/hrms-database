$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$testContainer = 'hrms-loans-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$testSql = Join-Path $testRoot ($testContainer + '.sql')
$created = $false
function Check-Exit([string]$action) { if ($LASTEXITCODE -ne 0) { throw "$action failed with exit code $LASTEXITCODE" } }
try {
    rtk proxy py -3 (Join-Path $testRoot 'loan_fixture_sql.py') | Set-Content -Encoding utf8 -LiteralPath $testSql
    Check-Exit 'Generate loan fixture'
    rtk proxy docker run --detach --rm --name $testContainer --network none -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
    Check-Exit 'Start isolated PostgreSQL'; $created = $true
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        rtk proxy docker exec $testContainer pg_isready -U postgres | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Test PostgreSQL did not become ready' }
    rtk proxy docker cp $testSql "${testContainer}:/tmp/schema.sql"; Check-Exit 'Copy schema'
    rtk proxy docker exec $testContainer psql -U postgres -d postgres -q -f /tmp/schema.sql; Check-Exit 'Apply test schema'
    foreach ($fixture in @('loan_financial_invariants.sql','loan_cross_account.sql','loan_source_identity.sql','loan_policy_override_constraints.sql')) {
        rtk proxy docker cp (Join-Path $testRoot $fixture) "${testContainer}:/tmp/test.sql"; Check-Exit 'Copy financial fixture'
        rtk proxy docker exec $testContainer psql -U postgres -d postgres -q -f /tmp/test.sql; Check-Exit $fixture
    }
    Write-Output 'All isolated PostgreSQL loan invariant suites passed.'
} finally {
    if ($created) { rtk proxy docker stop $testContainer | Out-Null }
    if (Test-Path -LiteralPath $testSql) { Remove-Item -LiteralPath $testSql }
}
