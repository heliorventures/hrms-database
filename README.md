# kabipay-database

Liquibase migration project for the KabiPay HRMS PostgreSQL schema.

## Dependencies

| Requirement | Notes |
|-------------|--------|
| **PostgreSQL 16** | Required. SQLite/other engines are not supported. |
| **Docker** (optional) | Recommended on Windows/macOS/Linux to run Postgres locally via `docker-compose.yml`. |
| **Liquibase 4.27+** *or* **Docker** | To apply changelogs; Docker image `liquibase/liquibase:4.27` is enough. |

## Quick start (run local Postgres + migrations)

1. **Optional:** copy Compose env template and edit credentials/ports:

   ```powershell
   copy .env.example .env
   ```

2. **Start Postgres** (from this directory):

   ```powershell
   docker compose up -d postgres
   ```

   Optional pgAdmin: `docker compose --profile tools up -d pgadmin`

3. **Align JDBC with your port** — if you changed `POSTGRES_PORT` in `.env`, set the same host/port in `liquibase.properties` (or pass `--url` when invoking Liquibase). Inside Docker, the service hostname is **`postgres`** and port **`5432`**.

4. **Apply ops migrations** once (see [Run migrations](#run-migrations) below).

5. **Tenant schemas** are created per customer (e.g. provisioning scripts in **kabipay-svc**); then apply `liquibase-tenant.properties` for each schema.

## Topology

Two logical masters, two property files, one PostgreSQL database:

| Master changelog | Property file | Target schema | When it runs |
|---|---|---|---|
| `changelog/db.changelog-master.xml` | `liquibase.properties` | `kabipay_ops` (fixed) | Once at environment setup |
| `changelog/tenant.changelog-master.xml` | `liquibase-tenant.properties` | `${schema}` (parameterised) | Once per tenant, at tenant provisioning |

- **Ops schema** (`kabipay_ops`) holds operator plane, control plane, module catalog, and billing tables (domains 0001–0004). This is KabiPay's own data.
- **Tenant schemas** (`tenant_<uuid_short>`) each hold the full client plane (domains 0005–0030: auth through outbox). One isolated schema per customer.

## Prerequisites

- PostgreSQL 16 running locally: from **this directory**, `docker compose up -d postgres` (see `docker-compose.yml`; optional vars in `.env` from `.env.example`)
- Liquibase 4.27+ **or** Docker (we'll use Docker — no local Liquibase install needed)
- For JDBC/Liquibase against the Compose service: match host `localhost`, published `POSTGRES_PORT`, and credentials to `liquibase.properties` / your shell

## Run migrations

### 1. Ops/control plane (run once)

From the `kabipay-database/` folder:

```powershell
# Using local liquibase binary (set KABIPAY_DB_USER / KABIPAY_DB_PASSWORD in the shell, or edit liquibase.properties):
liquibase --defaults-file=liquibase.properties update

# Using Docker (recommended — no install needed):
# Prerequisites: `docker compose up -d postgres` from this folder. Replace user/password if your `.env` differs.
# On Docker Desktop for Windows, attach to the Compose network so the hostname `postgres` resolves:
docker run --rm --network kabipay_default `
  -v ${PWD}:/liquibase/changelog `
  liquibase/liquibase:4.27 `
  --searchPath=/liquibase/changelog `
  --defaultsFile=/liquibase/changelog/liquibase.properties `
  --url=jdbc:postgresql://postgres:5432/kabipay_dev `
  --username=kabipay `
  --password=changeme `
  update
```

If your Compose project network is not named `kabipay_default`, run `docker network ls` and use the network that lists `kabipay_postgres`, or use `host.docker.internal` instead of `postgres` in the JDBC URL (and omit `--network`).

Liquibase history tables are stored in `public` (see `liquibaseSchemaName` in `liquibase.properties`) so the first changeset can create `kabipay_ops`.

### 2. Tenant plane (run per tenant on provisioning)

Replace `<tenant_id_short>` with the first 8 chars of the tenant UUID (no hyphens):

```powershell
# First, create the tenant schema:
psql -h localhost -U kabipay -d kabipay_dev -c "CREATE SCHEMA tenant_abc12345;"

# Then apply migrations into that schema:
liquibase --defaults-file=liquibase-tenant.properties `
  -Dschema=tenant_abc12345 `
  --databaseChangelogTableName=tenant_abc12345_databasechangelog `
  update
```

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

**Ops:** `changelog/db.changelog-master.xml` also includes `0005_integration_connector_catalog` (global `integration_connector` table in `kabipay_ops`, referenced by `tenant_integration` in domain 0026). Apply ops migrations before tenant provisioning.

## Reference

If this repo lives next to other KabiPay docs in a workspace, you may have:

- Canonical ERD: `hrms_erd_complete.md`
- Implementation prompt: `KABIPAY_AI_PROMPT.md`
