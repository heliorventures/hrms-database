-- Read-only. Run before and after migration 0083 against the ops/control-plane database.
BEGIN TRANSACTION READ ONLY;

-- Exact insertion count per tenant, including zero. Existing rows always count as existing.
SELECT tenant.id AS tenant_id, tenant.subdomain, tenant.status AS tenant_status,
       count(module.id) FILTER (WHERE subscription.id IS NULL) AS missing_subscriptions,
       count(subscription.id) AS existing_subscriptions
FROM kabipay_ops.tenant AS tenant
LEFT JOIN kabipay_ops.module AS module ON module.is_active = true
LEFT JOIN kabipay_ops.tenant_subscription AS subscription
  ON subscription.tenant_id = tenant.id AND subscription.module_id = module.id
WHERE tenant.is_deleted = false
GROUP BY tenant.id, tenant.subdomain, tenant.status
ORDER BY tenant.subdomain;

-- Missing service catalog entries cannot be repaired by adding subscriptions.
SELECT expected.code AS missing_catalog_module
FROM (VALUES ('EMPLOYEE'), ('ATTENDANCE'), ('LEAVE'), ('PAYROLL'),
             ('TAX'), ('EXPENSE'), ('RECRUITMENT'), ('WORKFLOW')) AS expected(code)
LEFT JOIN kabipay_ops.module AS module ON module.code = expected.code
WHERE module.id IS NULL;

-- Current access blockers, including transitive dependencies and dependency cycles.
-- Missing subscriptions should disappear after 0083. Other blockers are preserved.
WITH RECURSIVE dependency_reach(root_id, dependency_id) AS (
    SELECT module_id, depends_on_module_id FROM kabipay_ops.module_dependency
    UNION
    SELECT reach.root_id, dependency.depends_on_module_id
    FROM dependency_reach AS reach
    JOIN kabipay_ops.module_dependency AS dependency ON dependency.module_id = reach.dependency_id
), coverage(root_id, dependency_id) AS (
    SELECT id, id FROM kabipay_ops.module
    UNION
    SELECT root_id, dependency_id FROM dependency_reach
), module_state AS (
    SELECT tenant.id AS tenant_id, tenant.subdomain, module.id AS module_id, module.code,
        CASE
            WHEN tenant.status <> 'ACTIVE' THEN 'TENANT_' || tenant.status
            WHEN NOT module.is_active THEN 'MODULE_INACTIVE'
            WHEN EXISTS (
                SELECT 1 FROM kabipay_ops.feature_flag AS flag
                WHERE flag.tenant_id = tenant.id AND flag.feature_name = 'module:' || module.code
                  AND NOT flag.is_enabled
            ) THEN 'EXPLICIT_FEATURE_DISABLE'
            WHEN EXISTS (
                SELECT 1 FROM dependency_reach
                WHERE root_id = module.id AND dependency_id = module.id
            ) THEN 'DEPENDENCY_CYCLE'
            WHEN module.is_core THEN NULL
            WHEN subscription.id IS NULL THEN 'MISSING_SUBSCRIPTION'
            WHEN subscription.is_deleted THEN 'SUBSCRIPTION_SOFT_DELETED'
            WHEN subscription.status <> 'ACTIVE' THEN 'SUBSCRIPTION_' || subscription.status
            WHEN subscription.activated_at > (CURRENT_TIMESTAMP AT TIME ZONE COALESCE(tenant.timezone, 'UTC'))::date
                THEN 'SUBSCRIPTION_NOT_STARTED'
            WHEN subscription.expires_at <= (CURRENT_TIMESTAMP AT TIME ZONE COALESCE(tenant.timezone, 'UTC'))::date
                THEN 'SUBSCRIPTION_EXPIRED'
            WHEN subscription.activated_at >= subscription.expires_at THEN 'INVALID_SUBSCRIPTION_DATES'
        END AS blocker
    FROM kabipay_ops.tenant AS tenant
    CROSS JOIN kabipay_ops.module AS module
    LEFT JOIN kabipay_ops.tenant_subscription AS subscription
      ON subscription.tenant_id = tenant.id AND subscription.module_id = module.id
    WHERE NOT tenant.is_deleted
)
SELECT state.tenant_id, state.subdomain, root.code AS requested_module,
       state.code AS blocking_module, state.blocker
FROM coverage
JOIN kabipay_ops.module AS root ON root.id = coverage.root_id
JOIN module_state AS state ON state.module_id = coverage.dependency_id
WHERE state.blocker IS NOT NULL
ORDER BY state.subdomain, root.code, state.code;

COMMIT;
