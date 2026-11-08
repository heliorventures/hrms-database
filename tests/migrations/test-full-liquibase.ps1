<#
.SYNOPSIS
    Rehearse both complete Liquibase masters in disposable PostgreSQL.
.DESCRIPTION
    Requires Node, npm install in hrms-database, Docker with the cached
    postgres:16-alpine image, and Java 17 (JAVA_HOME, PATH, or the vendor JRE).
    The bundled runner locates Java; no machine-specific path is configured.
    Uses random dummy credentials, a unique container and a random loopback
    port. No repository .env or production database configuration is read.
    This proves a fresh full-chain update, repeat no-op updates and acceptance
    of three exact prior loan checksums, not a restored production upgrade.
.PARAMETER SkipPriorChecksumVerification
    Exercise fresh and repeat updates without simulating prior loan history.
#>
[CmdletBinding()]
param([switch]$SkipPriorChecksumVerification)

$ErrorActionPreference = 'Stop'
$databaseRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$runner = Join-Path $databaseRoot 'run-liquibase.cjs'
$testId = [guid]::NewGuid().ToString('N')
$testContainer = 'hrms-full-liquibase-' + $testId.Substring(0, 12)
$testUser = 'loan_' + $testId.Substring(0, 12)
$testPassword = [guid]::NewGuid().ToString('N')
$testDatabase = 'loan_rehearsal'
$testSchema = 'tenant_loanrehearsal'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDirectory = Join-Path $tempBase ('hrms-full-liquibase-' + $testId)
$containerCreated = $false
$tempCreated = $false

function Assert-Native([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit $LASTEXITCODE" }
}

function Invoke-TestSql([string]$Sql) {
    & docker exec $testContainer psql -v ON_ERROR_STOP=1 -U $testUser -d $testDatabase -c $Sql
    Assert-Native 'Disposable database SQL'
}

function Get-HistoryFingerprint([string]$Table) {
    $sql = "SELECT md5(COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.orderexecuted,h.id,h.author,h.filename),'[]'::jsonb)::text) FROM $Table h;"
    $fingerprint = (& docker exec $testContainer psql -v ON_ERROR_STOP=1 -At -U $testUser -d $testDatabase -c $sql).Trim()
    Assert-Native 'Read disposable migration history'
    if ($fingerprint -notmatch '^[a-f0-9]{32}$') { throw 'Unexpected migration history fingerprint' }
    return $fingerprint
}

function Invoke-TestUpdate([string]$Properties, [string]$Changelog) {
    # CLI connection values outrank inherited Liquibase settings. Even an
    # unrelated LIQUIBASE_COMMAND_URL cannot redirect this rehearsal.
    & node $runner "--defaults-file=$Properties" "--url=$testJdbc" "--username=$testUser" "--password=$testPassword" "--changelog-file=$Changelog" update
    Assert-Native 'Disposable Liquibase update'
}

foreach ($command in @('node', 'docker')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required" }
}
if (-not (Test-Path -LiteralPath $runner)) { throw 'Missing bundled Liquibase runner' }
if (-not (Test-Path -LiteralPath (Join-Path $databaseRoot 'node_modules/liquibase'))) {
    throw 'Run npm install in hrms-database before this rehearsal'
}

try {
    if (Test-Path -LiteralPath $tempDirectory) { throw 'Refusing an existing rehearsal temporary directory' }
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    $tempCreated = $true
    & docker run --pull=never --rm -d --name $testContainer -p 127.0.0.1::5432 -e "POSTGRES_USER=$testUser" -e "POSTGRES_PASSWORD=$testPassword" -e "POSTGRES_DB=$testDatabase" postgres:16-alpine
    Assert-Native 'Start disposable PostgreSQL (postgres:16-alpine must be cached)'
    $containerCreated = $true
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        & docker exec $testContainer pg_isready -U $testUser -d $testDatabase | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Disposable PostgreSQL did not become ready' }
    $binding = (& docker port $testContainer 5432/tcp).Trim()
    Assert-Native 'Find disposable loopback port'
    if ($binding -notmatch '^127\.0\.0\.1:(\d+)$') { throw 'Refused a non-loopback database endpoint' }
    $testJdbc = "jdbc:postgresql://127.0.0.1:$($Matches[1])/$testDatabase"
    $commonProperties = @"
url=$testJdbc
username=$testUser
password=$testPassword
driver=org.postgresql.Driver
logLevel=INFO
liquibase.hub.mode=off
"@
    $opsProperties = Join-Path $tempDirectory 'ops.properties'
    $tenantProperties = Join-Path $tempDirectory 'tenant.properties'
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($opsProperties, $commonProperties + "`nchangeLogFile=changelog/db.changelog-master.xml`ndefaultSchemaName=kabipay_ops`nliquibaseSchemaName=public`n", $utf8)
    [IO.File]::WriteAllText($tenantProperties, $commonProperties + "`nchangeLogFile=changelog/tenant.changelog-master.xml`ndefaultSchemaName=$testSchema`nliquibaseSchemaName=$testSchema`ndatabaseChangeLogTableName=${testSchema}_databasechangelog`nparameter.schema=$testSchema`n", $utf8)
    Push-Location $databaseRoot
    try {
        Write-Output 'FULL_LIQUIBASE_STAGE=FRESH_MASTER_UPDATE'
        Invoke-TestUpdate $opsProperties 'changelog/db.changelog-master.xml'
        $tenantId = [guid]::NewGuid().ToString()
        $tenantDatabaseId = [guid]::NewGuid().ToString()
        $bootstrap = @"
INSERT INTO kabipay_ops.module(id,code,name) SELECT gen_random_uuid(),code,code FROM unnest(ARRAY['EMPLOYEE','ATTENDANCE','LEAVE','EXPENSE','PAYROLL','TAX','WORKFLOW','RECRUITMENT']) AS code ON CONFLICT(code) DO NOTHING;
INSERT INTO kabipay_ops.tenant(id,name,status,country,currency,subdomain) VALUES('$tenantId','Disposable Liquibase rehearsal','ACTIVE','IN','INR','loan-rehearsal');
INSERT INTO kabipay_ops.tenant_database(id,tenant_id,db_type,db_host,db_name,schema_name,is_active) VALUES('$tenantDatabaseId','$tenantId','POSTGRES','127.0.0.1','$testDatabase','$testSchema',TRUE);
CREATE SCHEMA $testSchema;
"@
        Invoke-TestSql $bootstrap
        Write-Output 'FULL_LIQUIBASE_STAGE=FRESH_TENANT_UPDATE'
        Invoke-TestUpdate $tenantProperties 'changelog/tenant.changelog-master.xml'
        if (-not $SkipPriorChecksumVerification) {
            # Independently recorded from the original definitions with Liquibase
            # 4.28; do not derive expected history from the current allowlist.
            $priorChecksums = @"
UPDATE $testSchema.${testSchema}_databasechangelog
SET md5sum=CASE id
 WHEN '0103-001-employee-loans' THEN '9:636b7e9268358e8ea225d1b9e7da5c78'
 WHEN '0105-001-payslip-loan-evidence' THEN '9:8d7a799d027b2661b3607fb6e724ac53'
 WHEN '0108-001-reviewed-late-loan-payments' THEN '9:19c6187bb7148d08fcd662e2674dc4ec'
 END
WHERE author='kabipay-dev' AND id IN ('0103-001-employee-loans','0105-001-payslip-loan-evidence','0108-001-reviewed-late-loan-payments');
"@
            Invoke-TestSql $priorChecksums
        }
        $opsBefore = Get-HistoryFingerprint 'public.databasechangelog'
        $tenantBefore = Get-HistoryFingerprint "$testSchema.${testSchema}_databasechangelog"
        Write-Output 'FULL_LIQUIBASE_STAGE=REPEAT_MASTER_UPDATE'
        Invoke-TestUpdate $opsProperties 'changelog/db.changelog-master.xml'
        Write-Output 'FULL_LIQUIBASE_STAGE=REPEAT_TENANT_UPDATE'
        Invoke-TestUpdate $tenantProperties 'changelog/tenant.changelog-master.xml'
        if ((Get-HistoryFingerprint 'public.databasechangelog') -ne $opsBefore -or
            (Get-HistoryFingerprint "$testSchema.${testSchema}_databasechangelog") -ne $tenantBefore) {
            throw 'Repeat update changed recorded migration history'
        }
        if (-not $SkipPriorChecksumVerification) {
            $countSql = "SELECT count(*) FROM $testSchema.${testSchema}_databasechangelog WHERE author='kabipay-dev' AND (id,md5sum) IN (('0103-001-employee-loans','9:636b7e9268358e8ea225d1b9e7da5c78'),('0105-001-payslip-loan-evidence','9:8d7a799d027b2661b3607fb6e724ac53'),('0108-001-reviewed-late-loan-payments','9:19c6187bb7148d08fcd662e2674dc4ec')) AND exectype='EXECUTED';"
            $priorCount = (& docker exec $testContainer psql -v ON_ERROR_STOP=1 -At -U $testUser -d $testDatabase -c $countSql).Trim()
            Assert-Native 'Verify exact prior migration checksums'
            if ($priorCount -ne '3') { throw 'Prior checksum history was rewritten or lost' }
            Write-Output 'PRIOR_CHECKSUM_HISTORY=PASSED'
        }
        Write-Output 'FULL_LIQUIBASE_REHEARSAL=PASSED'
    } finally { Pop-Location }
} finally {
    try {
        if ($containerCreated) {
            & docker stop --time 10 $testContainer | Out-Null
            Assert-Native 'Remove disposable PostgreSQL container'
        }
    } finally {
        if ($tempCreated -and (Test-Path -LiteralPath $tempDirectory)) {
            $absoluteTemp = [IO.Path]::GetFullPath($tempDirectory)
            $allowedPrefix = $tempBase.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
            if (-not $absoluteTemp.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($absoluteTemp) -ne ('hrms-full-liquibase-' + $testId)) {
                throw 'Refused cleanup outside the unique rehearsal temporary directory'
            }
            Remove-Item -LiteralPath $absoluteTemp -Recurse -Force
        }
    }
}
