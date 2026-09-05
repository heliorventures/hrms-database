[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$MigrationRelativePath = 'migrations/0070_workplace_configuration_rbac/workplace_configuration_rbac.xml'
$MigrationPath = Join-Path (Join-Path $DatabaseDir 'changelog') $MigrationRelativePath
$MasterPath = Join-Path $DatabaseDir 'changelog/tenant.changelog-master.xml'
$RolloutPath = Join-Path $PSScriptRoot 'update-workplace-configuration-rbac.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $MigrationPath) '0070 workplace configuration RBAC migration is missing'
Assert-True (Test-Path -LiteralPath $RolloutPath) 'Workplace configuration RBAC rollout script is missing'

[xml]$master = Get-Content -Raw -LiteralPath $MasterPath
$includes = @($master.databaseChangeLog.include | ForEach-Object { $_.file })
Assert-True ($includes -contains $MigrationRelativePath) 'Tenant changelog must include the 0070 workplace configuration RBAC migration'

$migration = Get-Content -Raw -LiteralPath $MigrationPath
$rollout = Get-Content -Raw -LiteralPath $RolloutPath
$targets = @(
    @{ Resource = 'benefits'; Module = 'EMPLOYEE' },
    @{ Resource = 'recruitment'; Module = 'RECRUITMENT' },
    @{ Resource = 'performance'; Module = 'EMPLOYEE' },
    @{ Resource = 'learning'; Module = 'EMPLOYEE' },
    @{ Resource = 'succession'; Module = 'EMPLOYEE' },
    @{ Resource = 'compensation'; Module = 'EMPLOYEE' }
)

foreach ($target in $targets) {
    $resource = [regex]::Escape($target.Resource)
    $module = [regex]::Escape($target.Module)
    Assert-True ($migration -match "\('$resource',\s*'manage',\s*'$module'") "Migration catalog is missing $($target.Resource):manage owned by $($target.Module)"
    foreach ($writerName in @('bootstrap-tenant-admins.ps1', 'seed-demo-data.ps1')) {
        $writer = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $writerName)
        Assert-True ($writer -match "Resource\s*=\s*'$resource';\s*Action\s*=\s*'manage';\s*Module\s*=\s*'$module'") "$writerName is missing $($target.Resource):manage"
    }
}

foreach ($requiredPattern in @(
    'LOCK\s+TABLE[\s\S]*?permission[\s\S]*?MODE\s+NOWAIT',
    'kabipay_ops\.tenant_database',
    'HAVING\s+COUNT\(\*\)\s*>\s*1',
    'DELETE\s+FROM\s+"?\$\{schema\}"?\.role_permission',
    'DELETE\s+FROM\s+"?\$\{schema\}"?\.permission_scope',
    "\('HR',\s*'benefits',\s*'manage',\s*'ALL'\)",
    "\('ADMIN',\s*'benefits',\s*'manage',\s*'ALL'\)",
    'DELETE\s+FROM\s+"?\$\{schema\}"?\.user_session[\s\S]*?workplace_rbac_change',
    'requires a forward corrective migration instead of rollback'
)) {
    Assert-True ($migration -match $requiredPattern) "Migration contract is missing pattern: $requiredPattern"
}

Assert-True ($rollout -match "ValidatePattern\('\^tenant_\[a-z0-9_\]\{1,50\}\$'\)") 'Rollout script must validate every schema identifier'
Assert-True ($rollout -match '\[switch\]\$Execute') 'Rollout script must default to read-only and require -Execute for migration writes'
Assert-True ($rollout -match 'update-tenant-liquibase\.ps1') 'Rollout script must use the supported tenant Liquibase updater'
Assert-True ($rollout -match 'Strict\s*=\s*\$false') 'Rollout script must run a non-mutating preflight before execution'
Assert-True ($rollout -match 'Strict\s*=\s*\$true') 'Rollout script must strictly verify each tenant after execution'

Write-Host 'Workplace configuration RBAC contract passed.' -ForegroundColor Green
