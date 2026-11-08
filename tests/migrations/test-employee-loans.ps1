<#
Requires Docker with postgres:16-alpine and Python. -Jdbc additionally requires
npm install in hrms-database and Java (JAVA_HOME, PATH, or vendor JRE). Both paths
use a unique disposable container; JDBC publishes only a random loopback port.
No repository .env is loaded. Run both modes to cover JDBC and direct psql.
#>
param([switch]$Jdbc)
$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$databaseRoot = (Resolve-Path (Join-Path $testRoot '../..')).ProviderPath
$testContainer = 'hrms-loans-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$testSql = Join-Path $testRoot ($testContainer + '.sql')
$testProperties = Join-Path $testRoot ($testContainer + '.properties')
$testPassword = [guid]::NewGuid().ToString('N')
$created = $false
function Check-Exit([string]$action) { if ($LASTEXITCODE -ne 0) { throw "$action failed with exit code $LASTEXITCODE" } }
try {
    py -3 (Join-Path $testRoot 'loan_fixture_sql.py') | Set-Content -Encoding utf8 -LiteralPath $testSql
    Check-Exit 'Generate loan fixture'
    $network = if ($Jdbc) { @('-p', '127.0.0.1::5432') } else { @('--network', 'none') }
    docker run --detach --rm --name $testContainer @network -e "POSTGRES_PASSWORD=$testPassword" postgres:16-alpine
    Check-Exit 'Start isolated PostgreSQL'; $created = $true
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        docker exec $testContainer pg_isready -U postgres | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Test PostgreSQL did not become ready' }
    if ($Jdbc) {
        # Real Liquibase/JDBC execution catches driver handling that a psql fixture cannot.
        # Requires npm install and Java (JAVA_HOME, PATH, or the repository's vendor JRE).
        $binding = (docker port $testContainer 5432/tcp).Trim(); Check-Exit 'Read JDBC port'
        if ($binding -notmatch '^127\.0\.0\.1:(\d+)$') { throw 'JDBC test refused a non-loopback endpoint' }
        $jdbcPort = $Matches[1]
        docker exec $testContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'CREATE SCHEMA loan_test; CREATE TABLE loan_test.employee(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);'
        Check-Exit 'Create JDBC prerequisite schema'
        @"
url=jdbc:postgresql://127.0.0.1:$jdbcPort/postgres
username=postgres
password=$testPassword
changeLogFile=changelog/migrations/0103_employee_loans/employee_loans.xml
defaultSchemaName=loan_test
liquibaseSchemaName=public
parameter.schema=loan_test
driver=org.postgresql.Driver
logLevel=INFO
"@ | Set-Content -LiteralPath $testProperties -Encoding ASCII
        Push-Location $databaseRoot
        try {
            node (Join-Path $databaseRoot 'run-liquibase.cjs') "--defaults-file=$testProperties" update
            Check-Exit 'Apply actual loan changelog through JDBC'
            # Model a previously applied SQL-equivalent definition without clearing
            # checksums. The repeat update must accept only its explicit old checksum.
            [xml]$migration = Get-Content (Join-Path $databaseRoot 'changelog/migrations/0103_employee_loans/employee_loans.xml')
            $priorChecksum = [string]$migration.databaseChangeLog.changeSet.validCheckSum
            if ($priorChecksum -notmatch '^9:[a-f0-9]{32}$') { throw 'Expected one exact prior checksum' }
            docker exec $testContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "UPDATE public.databasechangelog SET md5sum='$priorChecksum' WHERE id='0103-001-employee-loans' AND author='kabipay-dev';"
            Check-Exit 'Set simulated prior-applied history in disposable database'
            node (Join-Path $databaseRoot 'run-liquibase.cjs') "--defaults-file=$testProperties" update
            Check-Exit 'Repeat JDBC update with prior-applied checksum'
            $historyCount = (docker exec $testContainer psql -At -U postgres -d postgres -c "SELECT count(*) FROM public.databasechangelog WHERE id='0103-001-employee-loans' AND md5sum='$priorChecksum' AND exectype='EXECUTED';").Trim()
            Check-Exit 'Read preserved prior-applied history'
            if ($historyCount -ne '1') { throw 'Repeat update rewrote or duplicated prior-applied history' }
        } finally { Pop-Location }
    } else {
        docker cp $testSql "${testContainer}:/tmp/schema.sql"; Check-Exit 'Copy schema'
        docker exec $testContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -q -f /tmp/schema.sql; Check-Exit 'Apply test schema'
    }
    foreach ($fixture in @('loan_financial_invariants.sql','loan_cross_account.sql','loan_source_identity.sql','loan_policy_override_constraints.sql')) {
        docker cp (Join-Path $testRoot $fixture) "${testContainer}:/tmp/test.sql"; Check-Exit 'Copy financial fixture'
        docker exec $testContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -q -f /tmp/test.sql; Check-Exit $fixture
    }
    Write-Output 'All isolated PostgreSQL loan invariant suites passed.'
} finally {
    if ($created) { docker stop $testContainer | Out-Null }
    if (Test-Path -LiteralPath $testSql) { Remove-Item -LiteralPath $testSql }
    if (Test-Path -LiteralPath $testProperties) { Remove-Item -LiteralPath $testProperties }
}
