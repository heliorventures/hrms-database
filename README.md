# kabipay-database

Liquibase migration project for the KabiPay HRMS PostgreSQL schema.

## Dependencies

| Requirement | Notes |
|-------------|--------|
| **Node.js 18+** and **npm** | Used to install bundled Liquibase (npm) + `pg` for SQL. No system `psql` or `liquibase` on PATH. |
| **JRE 17** | Downloaded into `vendor/` on first `npm run migrate-ops` (via [njre](https://www.npmjs.com/package/njre)), unless `JAVA_HOME` is already set. |
| **PostgreSQL 16** | Cloud (Neon, Aiven, …) or local. SQLite/other engines are not supported. |
| **pgAdmin or another GUI** (optional) | Connect with SSL when the provider requires it. |

**Neon (serverless):** use the **`*-pooler.*.neon.tech`** host for `POSTGRES_HOST` (and JDBC URLs) so database tooling multiplexes through Neon pooler and stays within connection/compute limits. Use **`POSTGRES_SSLMODE=require`**. For heavy one-off admin DDL, your provider may also offer a **direct** (non-pooler) host; use only when their docs say to.

## Quick start (cloud Postgres + migrations)

1. Create a **PostgreSQL 16**–compatible service (e.g. **Neon**, **Aiven**, or self-hosted) and note host, port, database name, user, and password.

2. Put connection settings in **`kabipay-database/.env`** (copy from **`.env.example`**): `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_SSLMODE=require` when TLS is required. For Neon, prefer the **pooler** endpoint for routine migrations and app traffic.

3. In **`kabipay-database/`**, run **`npm install`** (pulls Liquibase, PostgreSQL driver, JRE helper, and `pg` — no global tools).

4. **Apply ops migrations** once: **`npm run migrate-ops`**. The first run may download a JRE 17 into `vendor/` (gitignored — you can delete `vendor/` anytime; it is re-created when needed).

5. **Provision tenants** and **tenant changelogs** with **`scripts/provision-tenant.ps1`** (uses `node run-sql.cjs` + bundled Liquibase; see [Run migrations](#run-migrations)).

## Topology

Two logical masters, two property files, one PostgreSQL database:

| Master changelog | Property file | Target schema | When it runs |
|---|---|---|---|
| `changelog/db.changelog-master.xml` | `liquibase.properties` | `kabipay_ops` (fixed) | Once at environment setup |
| `changelog/tenant.changelog-master.xml` | `liquibase-tenant.properties` | `${schema}` (parameterised) | Once per tenant, at tenant provisioning |

- **Ops schema** (`kabipay_ops`) holds operator plane, control plane, module catalog, and billing tables (domains 0001–0004, plus `0005_integration_connector_catalog`). This is KabiPay's control-plane data.
- **Tenant schemas** (`tenant_<uuid_short>`) each hold the full client plane (domains **0005–0030** in the table below, plus **0031–0033** in `tenant.changelog-master.xml`: tax proof, attendance punch policy, travel request). One isolated schema per customer.

## Prerequisites

- PostgreSQL 16 reachable from your machine (cloud URL + TLS as required).
- **Node.js**; **`npm install`** in this folder; **`.env`** in this folder with `POSTGRES_*` values for database tooling.

## Run migrations

### 1. Ops/control plane (run once)

From the `kabipay-database/` folder, with `kabipay-database/.env` configured:

```bash
npm run migrate-ops
```

The underlying command is `node migrate-ops.cjs` → `run-liquibase.cjs` (JDBC URL; add `?sslmode=require` for managed Postgres). A JRE 17 is placed under `vendor/` if `JAVA_HOME` is not set.

Liquibase history tables are stored in `public` (see `liquibaseSchemaName` in `liquibase.properties`) so the first changeset can create `kabipay_ops`.

### 2. Tenant plane (run per tenant on provisioning)

Use **`scripts\provision-tenant.ps1`**; it creates the schema, updates `kabipay_ops.tenant_database`, and runs the tenant Liquibase changelog.

Or use **`node run-sql.cjs`** / **`node run-liquibase.cjs`** (after `npm install`) with the same **`.env`** values; see `scripts\provision-tenant.ps1` for the exact pattern.

In production, the `kabipay-tenant` service's provisioning workflow invokes this automatically.

## Migration authoring rules

1. **Never edit an existing changeset.** Add a new one instead. Liquibase tracks changesets by `id + author + file path` and will refuse to re-apply edits.
2. **Every changeset must have a `<rollback>` block.** If the forward action is trivially reversible (e.g. `createTable`, `addColumn`), Liquibase can infer rollback — but we write it explicitly anyway for clarity.
3. **Every table must have** `id UUID PK`, `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.
4. **Every major entity table** (not junction/log tables) also has `is_deleted BOOLEAN NOT NULL DEFAULT false`, `deleted_at TIMESTAMPTZ`, `deleted_by UUID`.
5. **Every client-plane table** carries `tenant_id UUID NOT NULL` with an index (even though schema isolation already protects — this is defense in depth).
6. **All money columns:** `NUMERIC(15,4)` — never `FLOAT`, never unqualified `DECIMAL`.
7. **All timestamps:** `TIMESTAMPTZ` — never `TIMESTAMP`.
8. **All FKs are explicit** with an `ON DELETE` clause (default `RESTRICT`, use `CASCADE` / `SET NULL` where intentional).
9. **`updated_at` trigger** is attached via `CREATE TRIGGER ... EXECUTE FUNCTION kabipay_ops.set_updated_at()`. The function lives once in `kabipay_ops` and is called cross-schema from every tenant's triggers.
10. **Enum-like status/type columns:** `VARCHAR(50)` with a `CHECK (... IN ('A','B','C'))` constraint, OR (for tenant-configurable dropdowns) a logical reference to `MASTER_DATA.key`.
11. **JSONB columns** for `before_state`, `after_state`, `config_json`, `payload`.
12. **Changeset ID format:** `{domain}-{seq}-{kebab-description}` e.g. `0007-001-create-employee-table`.

## Domain map

| # | Folder | Plane | Status |
|---|---|---|---|
| 0000 | `0000_foundation` | ops | Done |
| 0001 | `0001_operator_plane` | ops | Done |
| 0002 | `0002_control_plane` | ops | Done |
| 0003 | `0003_module_catalog` | ops | Done |
| 0004 | `0004_billing` | ops | Done |
| 0005 | `0005_auth_rbac` | tenant | Done |
| 0006 | `0006_org_hierarchy` | tenant | Done |
| 0007 | `0007_employee_core` | tenant | Done |
| 0008 | `0008_document_system` | tenant | Done |
| 0009 | `0009_custom_fields` | tenant | Done |
| 0010 | `0010_time_shift_roster` | tenant | Done |
| 0011 | `0011_leave` | tenant | Done |
| 0012 | `0012_payroll` | tenant | Done |
| 0013 | `0013_tax_statutory` | tenant | Done |
| 0014 | `0014_benefits` | tenant | Done |
| 0015 | `0015_expense` | tenant | Done |
| 0016 | `0016_recruitment` | tenant | Done |
| 0017 | `0017_onboarding_offboarding` | tenant | Done |
| 0018 | `0018_performance` | tenant | Done |
| 0019 | `0019_lms` | tenant | Done |
| 0020 | `0020_succession` | tenant | Done |
| 0021 | `0021_compensation` | tenant | Done |
| 0022 | `0022_assets` | tenant | Done |
| 0023 | `0023_grievance` | tenant | Done |
| 0024 | `0024_analytics` | tenant | Done |
| 0025 | `0025_workflow` | tenant | Done |
| 0026 | `0026_integrations` | tenant | Done |
| 0027 | `0027_communication_audit` | tenant | Done |
| 0028 | `0028_master_data` | tenant | Done |
| 0029 | `0029_file_storage` | tenant | Done |
| 0030 | `0030_outbox_events` | tenant | Done |
| 0031 | `0031_tax_proof` | tenant | Done |
| 0032 | `0032_attendance_punch_policy` | tenant | Done |
| 0033 | `0033_travel_request` | tenant | Done |

**Ops:** `changelog/db.changelog-master.xml` includes `0005_integration_connector_catalog` (global `integration_connector` in `kabipay_ops`, referenced by `tenant_integration` in domain 0026). Apply **ops** migrations before **tenant** provisioning.

## Reference

If this repo lives next to other KabiPay docs in a workspace, you may have:

- Canonical ERD: `hrms_erd_complete.md`
- Implementation prompt: `KABIPAY_AI_PROMPT.md`
