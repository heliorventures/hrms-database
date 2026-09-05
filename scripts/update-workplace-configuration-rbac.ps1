<#
.SYNOPSIS
    Audits or applies the workplace configuration RBAC contract to one or more tenant schemas.

.DESCRIPTION
    The default mode is read-only and reports whether each tenant needs migration 0070.
    Pass -Execute to run the supported tenant Liquibase updater and then enforce a strict
    post-update audit. Schema identifiers are validated before they are interpolated into SQL.

.EXAMPLE
    .\scripts\update-workplace-configuration-rbac.ps1 -Schemas tenant_a50902ed,tenant_e6d4fc13

.EXAMPLE
    .\scripts\update-workplace-configuration-rbac.ps1 -Schemas tenant_a50902ed,tenant_e6d4fc13 -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^tenant_[a-z0-9_]{1,50}$')]
    [string[]]$Schemas,
    [switch]$Execute,
    [string]$PostgresHost = '',
    [int]$PostgresPort = 5432,
    [string]$DbName = '',
    [string]$DbUser = '',
    [string]$DbPassword = '',
    [switch]$PostgresSsl
)

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$AuditRunner = Join-Path $PSScriptRoot 'run-workplace-rbac-audit.cjs'
$UpdateScript = Join-Path $PSScriptRoot 'update-tenant-liquibase.ps1'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required' }
if (-not (Test-Path -LiteralPath $AuditRunner)) { throw "Missing audit runner: $AuditRunner" }
if (-not (Test-Path -LiteralPath $UpdateScript)) { throw "Missing tenant Liquibase updater: $UpdateScript" }

$Schemas = @($Schemas | Select-Object -Unique)
if ($Schemas.Count -eq 0) { throw 'At least one tenant schema is required' }

$savedEnvironment = @{}
function Set-AuditEnvironment {
    param([string]$Name, [string]$Value)
    if (-not $savedEnvironment.ContainsKey($Name)) {
        $savedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

if ($PSBoundParameters.ContainsKey('PostgresHost') -and -not [string]::IsNullOrWhiteSpace($PostgresHost)) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_HOST' $PostgresHost
}
if ($PSBoundParameters.ContainsKey('PostgresPort')) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_PORT' "$PostgresPort"
}
if ($PSBoundParameters.ContainsKey('DbName') -and -not [string]::IsNullOrWhiteSpace($DbName)) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_DB' $DbName
}
if ($PSBoundParameters.ContainsKey('DbUser') -and -not [string]::IsNullOrWhiteSpace($DbUser)) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_USER' $DbUser
}
if ($PSBoundParameters.ContainsKey('DbPassword') -and -not [string]::IsNullOrWhiteSpace($DbPassword)) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_PASSWORD' $DbPassword
}
if ($PostgresSsl) {
    Set-AuditEnvironment 'WORKPLACE_RBAC_POSTGRES_SSLMODE' 'require'
}

function Invoke-TenantAudit {
    param(
        [Parameter(Mandatory = $true)][string]$Schema,
        [Parameter(Mandatory = $true)][bool]$Strict
    )

    if ($Schema -notmatch '^tenant_[a-z0-9_]{1,50}$') { throw "Unsafe tenant schema: $Schema" }
    $strictSql = if ($Strict) { 'true' } else { 'false' }
    $auditPath = Join-Path $DatabaseDir ".generated-workplace-rbac-audit-$Schema-$PID.sql"
    $sql = @"
BEGIN READ ONLY;

DO `$audit`$
DECLARE
    tenant_count INTEGER;
    active_role_count INTEGER;
    ambiguous_roles TEXT;
    ambiguous_permissions TEXT;
    ambiguous_scopes TEXT;
    invalid_modules TEXT;
    is_compliant BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO tenant_count
    FROM kabipay_ops.tenant_database
    WHERE schema_name = '$Schema';
    IF tenant_count <> 1 THEN
        RAISE EXCEPTION 'workplace RBAC audit expected one tenant_database row for schema %, found %', '$Schema', tenant_count;
    END IF;

    SELECT STRING_AGG(role_name, ', ' ORDER BY role_name) INTO ambiguous_roles
    FROM (
        SELECT UPPER(TRIM(name)) AS role_name
        FROM "$Schema".role
        WHERE UPPER(TRIM(name)) IN ('HR', 'ADMIN')
        GROUP BY UPPER(TRIM(name))
        HAVING COUNT(*) > 1
    ) AS duplicates;
    IF ambiguous_roles IS NOT NULL THEN
        RAISE EXCEPTION 'workplace RBAC audit found ambiguous HR or ADMIN roles: %', ambiguous_roles;
    END IF;

    SELECT COUNT(*) INTO active_role_count
    FROM "$Schema".role AS tenant_role
    JOIN kabipay_ops.tenant_database AS tenant_database ON tenant_database.tenant_id = tenant_role.tenant_id
    WHERE tenant_database.schema_name = '$Schema'
      AND UPPER(TRIM(tenant_role.name)) IN ('HR', 'ADMIN')
      AND tenant_role.is_deleted = false;
    IF active_role_count <> 2 THEN
        RAISE EXCEPTION 'workplace RBAC audit requires one active HR role and one active ADMIN role';
    END IF;

    WITH targets(resource, action) AS (
        VALUES ('benefits', 'manage'), ('recruitment', 'manage'), ('performance', 'manage'),
               ('learning', 'manage'), ('succession', 'manage'), ('compensation', 'manage')
    )
    SELECT STRING_AGG(permission_code, ', ' ORDER BY permission_code) INTO ambiguous_permissions
    FROM (
        SELECT LOWER(TRIM(permission.resource)) || ':' || LOWER(TRIM(permission.action)) AS permission_code
        FROM "$Schema".permission AS permission
        JOIN targets ON targets.resource = LOWER(TRIM(permission.resource))
                    AND targets.action = LOWER(TRIM(permission.action))
        GROUP BY LOWER(TRIM(permission.resource)), LOWER(TRIM(permission.action))
        HAVING COUNT(*) > 1
    ) AS duplicates;
    IF ambiguous_permissions IS NOT NULL THEN
        RAISE EXCEPTION 'workplace RBAC audit found ambiguous permissions: %', ambiguous_permissions;
    END IF;

    WITH targets(resource, action) AS (
        VALUES ('benefits', 'manage'), ('recruitment', 'manage'), ('performance', 'manage'),
               ('learning', 'manage'), ('succession', 'manage'), ('compensation', 'manage')
    )
    SELECT STRING_AGG(scope_code, ', ' ORDER BY scope_code) INTO ambiguous_scopes
    FROM (
        SELECT permission_scope.role_id::text || ':' || LOWER(TRIM(permission_scope.resource)) AS scope_code
        FROM "$Schema".permission_scope AS permission_scope
        JOIN targets ON targets.resource = LOWER(TRIM(permission_scope.resource))
                    AND targets.action = LOWER(TRIM(permission_scope.action))
        GROUP BY permission_scope.role_id, LOWER(TRIM(permission_scope.resource)), LOWER(TRIM(permission_scope.action))
        HAVING COUNT(*) > 1
    ) AS duplicates;
    IF ambiguous_scopes IS NOT NULL THEN
        RAISE EXCEPTION 'workplace RBAC audit found ambiguous permission scopes: %', ambiguous_scopes;
    END IF;

    WITH required_modules(module_code) AS (VALUES ('EMPLOYEE'), ('RECRUITMENT'))
    SELECT STRING_AGG(module_code, ', ' ORDER BY module_code) INTO invalid_modules
    FROM required_modules
    WHERE (SELECT COUNT(*) FROM kabipay_ops.module WHERE UPPER(TRIM(code)) = required_modules.module_code) <> 1;
    IF invalid_modules IS NOT NULL THEN
        RAISE EXCEPTION 'workplace RBAC audit requires exactly one module row for: %', invalid_modules;
    END IF;

    WITH targets(resource, action) AS (
        VALUES ('benefits', 'manage'), ('recruitment', 'manage'), ('performance', 'manage'),
               ('learning', 'manage'), ('succession', 'manage'), ('compensation', 'manage')
    ), tenant_context AS (
        SELECT tenant_id FROM kabipay_ops.tenant_database WHERE schema_name = '$Schema'
    )
    SELECT NOT EXISTS (
        SELECT 1
        FROM targets
        WHERE (SELECT COUNT(*) FROM "$Schema".permission AS permission
               WHERE permission.resource = targets.resource AND permission.action = targets.action) <> 1
           OR (SELECT COUNT(*)
               FROM "$Schema".role_permission AS role_permission
               JOIN "$Schema".role AS tenant_role ON tenant_role.id = role_permission.role_id
               JOIN "$Schema".permission AS permission ON permission.id = role_permission.permission_id
               JOIN tenant_context ON tenant_context.tenant_id = tenant_role.tenant_id
               WHERE permission.resource = targets.resource AND permission.action = targets.action
                 AND tenant_role.is_deleted = false
                 AND UPPER(TRIM(tenant_role.name)) IN ('HR', 'ADMIN')) <> 2
           OR EXISTS (
               SELECT 1
               FROM "$Schema".role_permission AS role_permission
               JOIN "$Schema".role AS tenant_role ON tenant_role.id = role_permission.role_id
               JOIN "$Schema".permission AS permission ON permission.id = role_permission.permission_id
               CROSS JOIN tenant_context
               WHERE permission.resource = targets.resource AND permission.action = targets.action
                 AND (tenant_role.tenant_id <> tenant_context.tenant_id OR tenant_role.is_deleted = true
                      OR UPPER(TRIM(tenant_role.name)) NOT IN ('HR', 'ADMIN'))
           )
           OR (SELECT COUNT(*)
               FROM "$Schema".permission_scope AS permission_scope
               JOIN "$Schema".role AS tenant_role ON tenant_role.id = permission_scope.role_id
               JOIN tenant_context ON tenant_context.tenant_id = tenant_role.tenant_id
               WHERE permission_scope.resource = targets.resource AND permission_scope.action = targets.action
                 AND permission_scope.tenant_id = tenant_context.tenant_id
                 AND tenant_role.is_deleted = false
                 AND UPPER(TRIM(tenant_role.name)) IN ('HR', 'ADMIN')
                 AND UPPER(TRIM(permission_scope.scope_type)) = 'ALL') <> 2
           OR EXISTS (
               SELECT 1
               FROM "$Schema".permission_scope AS permission_scope
               JOIN "$Schema".role AS tenant_role ON tenant_role.id = permission_scope.role_id
               CROSS JOIN tenant_context
               WHERE permission_scope.resource = targets.resource AND permission_scope.action = targets.action
                 AND (tenant_role.tenant_id <> tenant_context.tenant_id OR tenant_role.is_deleted = true
                      OR UPPER(TRIM(tenant_role.name)) NOT IN ('HR', 'ADMIN')
                      OR permission_scope.tenant_id <> tenant_context.tenant_id
                      OR UPPER(TRIM(permission_scope.scope_type)) <> 'ALL')
           )
    ) INTO is_compliant;

    IF $strictSql AND NOT is_compliant THEN
        RAISE EXCEPTION 'workplace RBAC strict verification failed for schema %', '$Schema';
    END IF;
END `$audit`$;

WITH targets(resource, action) AS (
    VALUES ('benefits', 'manage'), ('recruitment', 'manage'), ('performance', 'manage'),
           ('learning', 'manage'), ('succession', 'manage'), ('compensation', 'manage')
), tenant_context AS (
    SELECT tenant_id FROM kabipay_ops.tenant_database WHERE schema_name = '$Schema'
)
SELECT
    targets.resource || ':' || targets.action AS permission,
    COUNT(DISTINCT permission.id) AS catalog_rows,
    COALESCE(STRING_AGG(DISTINCT UPPER(TRIM(tenant_role.name)), ', ' ORDER BY UPPER(TRIM(tenant_role.name)))
             FILTER (WHERE role_permission.role_id IS NOT NULL), '') AS granted_roles,
    COALESCE(STRING_AGG(DISTINCT UPPER(TRIM(tenant_role.name)) || '=' || UPPER(TRIM(permission_scope.scope_type)), ', '
             ORDER BY UPPER(TRIM(tenant_role.name)) || '=' || UPPER(TRIM(permission_scope.scope_type)))
             FILTER (WHERE permission_scope.id IS NOT NULL), '') AS scopes,
    CASE
        WHEN COUNT(DISTINCT permission.id) = 1
         AND COUNT(DISTINCT tenant_role.id) FILTER (
             WHERE role_permission.role_id IS NOT NULL AND tenant_role.tenant_id = tenant_context.tenant_id
               AND tenant_role.is_deleted = false AND UPPER(TRIM(tenant_role.name)) IN ('HR', 'ADMIN')) = 2
         AND COUNT(DISTINCT permission_scope.role_id) FILTER (
             WHERE permission_scope.tenant_id = tenant_context.tenant_id
               AND UPPER(TRIM(permission_scope.scope_type)) = 'ALL'
               AND UPPER(TRIM(tenant_role.name)) IN ('HR', 'ADMIN')) = 2
         AND NOT EXISTS (
             SELECT 1
             FROM "$Schema".role_permission AS unexpected_grant
             JOIN "$Schema".role AS unexpected_role ON unexpected_role.id = unexpected_grant.role_id
             JOIN "$Schema".permission AS unexpected_permission ON unexpected_permission.id = unexpected_grant.permission_id
             WHERE LOWER(TRIM(unexpected_permission.resource)) = targets.resource
               AND LOWER(TRIM(unexpected_permission.action)) = targets.action
               AND (unexpected_role.tenant_id <> tenant_context.tenant_id OR unexpected_role.is_deleted = true
                    OR UPPER(TRIM(unexpected_role.name)) NOT IN ('HR', 'ADMIN'))
         )
         AND NOT EXISTS (
             SELECT 1
             FROM "$Schema".permission_scope AS unexpected_scope
             JOIN "$Schema".role AS unexpected_role ON unexpected_role.id = unexpected_scope.role_id
             WHERE LOWER(TRIM(unexpected_scope.resource)) = targets.resource
               AND LOWER(TRIM(unexpected_scope.action)) = targets.action
               AND (unexpected_role.tenant_id <> tenant_context.tenant_id OR unexpected_role.is_deleted = true
                    OR UPPER(TRIM(unexpected_role.name)) NOT IN ('HR', 'ADMIN')
                    OR unexpected_scope.tenant_id <> tenant_context.tenant_id
                    OR UPPER(TRIM(unexpected_scope.scope_type)) <> 'ALL')
         )
        THEN 'COMPLIANT'
        ELSE 'REQUIRES_MIGRATION'
    END AS status
FROM targets
CROSS JOIN tenant_context
LEFT JOIN "$Schema".permission AS permission
  ON LOWER(TRIM(permission.resource)) = targets.resource
 AND LOWER(TRIM(permission.action)) = targets.action
LEFT JOIN "$Schema".role_permission AS role_permission ON role_permission.permission_id = permission.id
LEFT JOIN "$Schema".role AS tenant_role ON tenant_role.id = role_permission.role_id
LEFT JOIN "$Schema".permission_scope AS permission_scope
  ON permission_scope.role_id = tenant_role.id
 AND LOWER(TRIM(permission_scope.resource)) = targets.resource
 AND LOWER(TRIM(permission_scope.action)) = targets.action
GROUP BY targets.resource, targets.action, tenant_context.tenant_id
ORDER BY targets.resource;

COMMIT;
"@

    try {
        [System.IO.File]::WriteAllText(
            $auditPath,
            $sql,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "==> Auditing $Schema (strict=$Strict)..." -ForegroundColor Cyan
        & node $AuditRunner $auditPath
        if ($LASTEXITCODE -ne 0) { throw "Workplace RBAC audit failed for $Schema (exit $LASTEXITCODE)" }
    } finally {
        Remove-Item -LiteralPath $auditPath -ErrorAction SilentlyContinue
    }
}

try {
    foreach ($Schema in $Schemas) {
        $previewParameters = @{ Schema = $Schema; Strict = $false }
        Invoke-TenantAudit @previewParameters
    }

    if (-not $Execute) {
        Write-Host 'Read-only preview complete. Re-run the same command with -Execute to apply migration 0070.' -ForegroundColor Yellow
        return
    }

    foreach ($Schema in $Schemas) {
        $updateParameters = @{ Schema = $Schema }
        if ($PSBoundParameters.ContainsKey('PostgresHost')) { $updateParameters.PostgresHost = $PostgresHost }
        if ($PSBoundParameters.ContainsKey('PostgresPort')) { $updateParameters.PostgresPort = $PostgresPort }
        if ($PSBoundParameters.ContainsKey('DbName')) { $updateParameters.DbName = $DbName }
        if ($PSBoundParameters.ContainsKey('DbUser')) { $updateParameters.DbUser = $DbUser }
        if ($PSBoundParameters.ContainsKey('DbPassword')) { $updateParameters.DbPassword = $DbPassword }
        if ($PostgresSsl) { $updateParameters.PostgresSsl = $true }
        & $UpdateScript @updateParameters

        $verificationParameters = @{ Schema = $Schema; Strict = $true }
        Invoke-TenantAudit @verificationParameters
    }
    Write-Host 'Workplace configuration RBAC migration and strict verification completed for every requested tenant.' -ForegroundColor Green
} finally {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
        }
    }
}
