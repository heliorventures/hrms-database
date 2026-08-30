$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog\migrations\0068_employee_status_integrity\employee_status_integrity.xml'
$masterPath = Join-Path $root 'changelog\tenant.changelog-master.xml'
$migrationInclude = 'migrations/0068_employee_status_integrity/employee_status_integrity.xml'
$previousMigrationInclude = 'migrations/0067_canonical_rbac_authorization/canonical_rbac_authorization.xml'
$canonicalStatuses = @('ACTIVE', 'PROBATION', 'INACTIVE', 'ON_LEAVE', 'SUSPENDED', 'TERMINATED')

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-SqlStatusValues {
    param(
        [string]$Sql,
        [string]$Pattern,
        [string]$Label
    )

    $match = [regex]::Match(
        $Sql,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    Assert-True $match.Success "$Label status set is missing"

    return @([regex]::Matches($match.Groups['statuses'].Value, "'([^']+)'") | ForEach-Object {
        $_.Groups[1].Value
    })
}

function Assert-ExactStatusSet {
    param(
        [string[]]$Actual,
        [string]$Label
    )

    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($canonicalStatuses | Sort-Object)
    Assert-True ($Actual.Count -eq $actualSorted.Count) "$Label must not contain duplicate statuses"
    Assert-True (
        $actualSorted.Count -eq $expectedSorted.Count -and
        [string]::Join(',', $actualSorted) -eq [string]::Join(',', $expectedSorted)
    ) "$Label must contain exactly: $($expectedSorted -join ', ')"
}

Assert-True (Test-Path -LiteralPath $migrationPath) 'employee status integrity migration file is missing'

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$master = Get-Content -Raw -LiteralPath $masterPath

$changeSets = @($migration.SelectNodes("//*[local-name()='changeSet']"))
Assert-True ($changeSets.Count -eq 1) 'employee status integrity migration must contain exactly one changeSet'
Assert-True ($changeSets[0].GetAttribute('id') -eq '0068-001-employee-status-integrity') 'employee status integrity changeSet id is incorrect'

$forwardSqlNodes = @($changeSets[0].SelectNodes("./*[local-name()='sql']"))
Assert-True ($forwardSqlNodes.Count -eq 3) 'employee status integrity migration must have guard, normalization, and constraint SQL steps'

$guardSql = $forwardSqlNodes[0].InnerText -replace '\s+', ' '
$normalizationSql = $forwardSqlNodes[1].InnerText -replace '\s+', ' '
$constraintSql = $forwardSqlNodes[2].InnerText -replace '\s+', ' '

Assert-True ($forwardSqlNodes[0].GetAttribute('splitStatements') -eq 'false') 'unknown-status guard must use splitStatements="false"'
Assert-True ($guardSql -match '\bRAISE\s+EXCEPTION\b') 'unknown-status guard must raise a clear exception'
Assert-True ($guardSql -match 'unknown employee status') 'unknown-status exception must identify the employee status problem'
Assert-True ($guardSql -match 'UPPER\s*\(\s*BTRIM\s*\(\s*status\s*\)\s*\)\s+NOT\s+IN') 'unknown-status guard must compare normalized status values'

$guardStatuses = Get-SqlStatusValues -Sql $guardSql -Pattern 'UPPER\s*\(\s*BTRIM\s*\(\s*status\s*\)\s*\)\s+NOT\s+IN\s*\((?<statuses>[^)]*)\)' -Label 'unknown-status guard'
Assert-ExactStatusSet -Actual $guardStatuses -Label 'unknown-status guard'

Assert-True ($normalizationSql -match 'UPDATE\s+"\$\{schema\}"\.employee\s+SET\s+status\s*=\s*UPPER\s*\(\s*BTRIM\s*\(\s*status\s*\)\s*\)') 'known employee statuses must be normalized with UPPER(BTRIM(status))'
$normalizationStatuses = Get-SqlStatusValues -Sql $normalizationSql -Pattern 'UPPER\s*\(\s*BTRIM\s*\(\s*status\s*\)\s*\)\s+IN\s*\((?<statuses>[^)]*)\)' -Label 'normalization'
Assert-ExactStatusSet -Actual $normalizationStatuses -Label 'normalization'

Assert-True ($constraintSql -match 'ALTER\s+TABLE\s+"\$\{schema\}"\.employee\s+ADD\s+CONSTRAINT\s+ck_employee_status_canonical\s+CHECK') 'canonical employee status CHECK constraint is missing'
$constraintStatuses = Get-SqlStatusValues -Sql $constraintSql -Pattern 'CHECK\s*\(\s*status\s+IN\s*\((?<statuses>[^)]*)\)\s*\)' -Label 'CHECK constraint'
Assert-ExactStatusSet -Actual $constraintStatuses -Label 'CHECK constraint'

$rollbackNodes = @($changeSets[0].SelectNodes("./*[local-name()='rollback']"))
Assert-True ($rollbackNodes.Count -eq 1) 'employee status integrity migration must define one rollback'
$rollbackSql = $rollbackNodes[0].InnerText -replace '\s+', ' '
Assert-True ($rollbackSql -match 'ALTER\s+TABLE\s+"\$\{schema\}"\.employee\s+DROP\s+CONSTRAINT\s+IF\s+EXISTS\s+ck_employee_status_canonical') 'rollback must drop the canonical employee status constraint'
Assert-True ($rollbackSql -notmatch '\bUPDATE\b|\bDELETE\b|\bINSERT\b|\bALTER\s+COLUMN\b') 'rollback must not denormalize or otherwise mutate employee data'

$includes = @($master.SelectNodes("//*[local-name()='include']") | ForEach-Object { $_.GetAttribute('file') })
Assert-True (@($includes | Where-Object { $_ -eq $migrationInclude }).Count -eq 1) 'tenant master changelog must include migration 0068 exactly once'
$previousIndex = [array]::IndexOf($includes, $previousMigrationInclude)
$migrationIndex = [array]::IndexOf($includes, $migrationInclude)
Assert-True ($previousIndex -ge 0) 'tenant master changelog must retain migration 0067'
Assert-True ($migrationIndex -eq ($previousIndex + 1)) 'tenant master changelog must include migration 0068 immediately after 0067'

Write-Output 'Employee status integrity migration contract passed.'
