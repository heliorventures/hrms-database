# kabipay-database

Liquibase migration project for the KabiPay HRMS PostgreSQL schema.

## Repository layout

This is the only project README. Import and migration operation notes are collected below.

| Location | Purpose |
| --- | --- |
| `scripts/reusable/provisioning/` | Tenant setup, admin bootstrap and demo seeding |
| `scripts/reusable/migrations/` | Existing-tenant Liquibase updater |
| `scripts/reusable/maintenance/` | Target routing, Indian timezones and subscription preflight |
| `scripts/reusable/rbac/` | Permission defaults, audits and workplace RBAC rollout |
| `scripts/reusable/imports/` | Generic converter entry point, normalization, XLSX reader and private outputs |
| `scripts/tenant_specific/solvian/imports/` | Reviewed SCL/SBL layout and salary/leave/period conversion rules |
| `scripts/tenant_specific/reviewed_repairs/` | Corrections bound to explicitly reviewed tenant schemas |
| `tests/unit/` | Offline assertions, mocked connection helpers and in-memory fixtures |
| `tests/migrations/` | Migration contracts and read-only post-migration SQL verification |
| `tests/integration/` | Disposable PostgreSQL/container fixtures |
| `tests/tenant_specific/solvian/` | Solvian workbook converter fixtures |
| `import-templates/v1/` | Versioned JSON contract and fictional example |
| `changelog/` | Ops/tenant migrations and their existing master files |

Generic SQL/Liquibase runners remain at the repository root. A client adapter is specific to a raw-data layout; the reusable import contract contains no source-column knowledge. Review tenant-specific tools/data as one group before removing them in future.

Documentation consolidation and file relocation do not prove runtime or migration acceptance. Tests/builds remain user-run. The new tenant importer/reset/payroll support is still being implemented; converter output alone is not a completed client import.

## Validation commands

Run from `hrms-database`:

```powershell
rtk npm test
rtk npm run check:permission-defaults
rtk proxy py -3 -m unittest discover -s tests/tenant_specific/solvian/unit -p test_converter.py -v
rtk proxy py -3 -m unittest discover -s tests/unit/migrations -p module_subscription_backfill_test.py -v
rtk proxy powershell -NoProfile -File tests/unit/migrations/test-tenant-migration-connection.ps1
rtk proxy powershell -NoProfile -File tests/unit/maintenance/test-indian-tenant-timezones.ps1
```

The commands above are offline. Migration-contract PowerShell checks in `tests/migrations/` are also offline; the asset SQL verification reads an explicitly selected tenant when the operator runs it. Integration tests create their own disposable database/container fixtures and have separate prerequisites described in the operation notes. None of these commands is an instruction to run a live import/reset.

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

5. **Provision tenants** and **tenant changelogs** with **`scripts/reusable/provisioning/provision-tenant.ps1`** (uses `node run-sql.cjs` + bundled Liquibase; see [Run migrations](#run-migrations)).

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
rtk npm run migrate-ops
```

The underlying command is `node migrate-ops.cjs` → `run-liquibase.cjs` (JDBC URL; add `?sslmode=require` for managed Postgres). A JRE 17 is placed under `vendor/` if `JAVA_HOME` is not set.

Liquibase history tables are stored in `public` (see `liquibaseSchemaName` in `liquibase.properties`) so the first changeset can create `kabipay_ops`.

### 2. Tenant plane (run per tenant on provisioning)

Use **`scripts\reusable\provisioning\provision-tenant.ps1`**; it creates the schema, updates `kabipay_ops.tenant_database`, and runs the tenant Liquibase changelog.

When provisioning for Docker Compose on the VPS, keep a clear split between the
tooling connection and the runtime target. Your laptop or VPS shell may connect
through `localhost` or a forwarded host port, but the deployed services must use
the Compose service name stored in `kabipay_ops.tenant_database`:

```powershell
rtk proxy powershell -NoProfile -File scripts\reusable\provisioning\provision-tenant.ps1 `
  -Name "Helior Prd" `
  -Code helior-prd `
  -RuntimePostgresHost postgres `
  -RuntimeDbName helior
```

For an already-provisioned tenant, repair the stored runtime target without
rerunning tenant migrations:

```powershell
rtk proxy powershell -NoProfile -File scripts\reusable\maintenance\update-tenant-database-target.ps1 `
  -TenantId e6d4fc13-feb8-52a0-93bd-f66c795969b1 `
  -RuntimePostgresHost postgres `
  -RuntimeDbName helior

or to migrate scehma
 rtk proxy powershell -NoProfile -File scripts\reusable\migrations\update-tenant-liquibase.ps1 -Schema tenant_e6d4fc13 
```

Or use **`node run-sql.cjs`** / **`node run-liquibase.cjs`** (after `npm install`) with the same **`.env`** values; see `scripts\reusable\provisioning\provision-tenant.ps1` for the exact pattern.

In production, the `kabipay-tenant` service's provisioning workflow invokes this automatically.

### Tenant data imports

The [versioned import template and conversion instructions](#tenant-import-template-v1)
describe the current two-step import work. The converter reads an explicit client
workbook and writes a private standard package with section-level issues.
Reusable tenant import/reset and payroll integration are still under implementation;
the converter alone does not import or reset a tenant.

The earlier Consultancy employee seed and workbook-reset scripts have been retired.
Use the current template workflow for updated salary-muster data. Tenant provisioning,
management-account setup, migration tools and their verification documentation remain
separate from employee-data import.

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

## Tenant import template v1

`import-templates/v1/tenant-import.schema.json` is the client-independent contract. `import-templates/v1/example.synthetic.json` contains fictional values solely to illustrate salary/leave/settlement separation. It is not a client package or an operator configuration.

Money is a two-decimal string, days/ratios are decimal strings, and dates are ISO strings. Optional unknowns are null; their source states preserve MISSING, BLANK, NA, VALUE or ERROR. They never imply an explicit field deletion. `clear_fields` lists supported nullable deletions during normal update. Conversion never supplies a clear instruction automatically.

The approved September exception is explicit: `--september-blank-formula-inputs-as-zero` treats blank/missing numeric inputs referenced by supported source salary formulas, and the reviewed gross / 31 * source LWP-days rule, as zero. Every substitution is logged and its original source state remains unchanged. NA, errors, unsupported formulas and unknown future contribution eligibility are not converted to zero. Repeated Excel shared formulas are translated with their relative/absolute references; no formula is executed. Empty Dues absent from the source total creates no adjustment and stays visible as an omission. A blank LWP amount is calculated using the reviewed rule and logged separately.

Conversion issues use WARNING, DEFER_SECTION, BLOCK_EMPLOYEE and BLOCK_TENANT. A missing code requires a reviewed mapping; missing optional banking data defers banking alone. `ready` describes that section's calculation data, not a committed import or authorization to finalize payroll. Required core identity and all financial prerequisites are checked again by the reusable importer/pay-run.

Recurring gross/split and annual employer PF are distinct. A source monthly hardcoded contribution/zero does not establish a permanent exemption or future employer cost. Employer PF/CTC remains unknown until its formula/configuration is confirmed. The displayed PF ceiling does not override a source formula that calculates directly from PF wages.

Leave snapshots retain signed source values for review. The Solvian profile applies the confirmed blank/dash-as-zero conventions: Opening is 2025 carry-forward, Allotted is the 2026 grant, signed taken values represent usage and excess usage is historical unpaid leave. All 37 source snapshots reconcile to nonnegative paid balances. Pending/planned remain unknown where not supplied. Historical LWP never supplies September payroll days or dated requests. Other converters must establish their own source conventions.

Optional version-1 sections `company_payroll_policy`, employee `tax_settings` and `tax_history` use reusable native validators and independent section outcomes. Old packages can omit them. Proven Solvian percentage formulas and source contribution rules are converted into configuration effective 1 October 2026. Annual regime, residency, future eligibility and PT are not inferred from blank source amounts. Invalid/incomplete optional tax data defers that section while valid employee/salary/leave data can continue. Tax imports require tax:manage ALL; replacement also requires this permission because it can delete tax state.

Tax history requires an explicit fiscal year, source reference, covered dates, actual component amounts, coverage status and reason. `tds: null` means not supplied; `tds: "0"` is a confirmed zero. Complete coverage requires a known TDS amount. Current-employer history must not overlap imported or finalized payroll. Settings/history corrections are revisioned and preserve finalized statements.

Period data retains the actual gross formula choice, source-only overrides and earned components. Employee deductions are PF, ESI, PT and TDS, plus reviewed additional deductions with a reason. Advance is salary already paid: it never enters recurring components or deduction totals, and appears once in settlement. Missing deduction reasons keep the period draft. Company component visibility controls browser, print and PDF details without changing calculated totals; employer contributions are hidden by default.

### Read-only conversion

From `hrms-database`, after the focused tests pass, run one exact original path at a time. Replace every placeholder with reviewed values; neither effective date nor leave as-of date is inferred from the filename.

```powershell
rtk proxy py -3 scripts/reusable/imports/convert-client-workbook.py `
  --input "D:\work\heliorventures\ClientDocumenation\Salary Muster FY 2026-27 SCL.xlsx" `
  --profile SCL `
  --tenant-code "<reviewed Consultancy tenant code>" `
  --salary-effective-from JOINING_DATE `
  --leave-as-of 2026-08-31 `
  --september-blank-formula-inputs-as-zero `
  --output-dir "<new private directory under an existing parent>"

rtk proxy py -3 scripts/reusable/imports/convert-client-workbook.py `
  --input "D:\work\heliorventures\ClientDocumenation\Salary Muster FY 2026-27 SBL.xlsx" `
  --profile SBL `
  --tenant-code "<reviewed Buildcon tenant code>" `
  --salary-effective-from JOINING_DATE `
  --leave-as-of 2026-08-31 `
  --september-blank-formula-inputs-as-zero `
  --output-dir "<different new private directory under an existing parent>"
```

Both commands read the workbook and write private local JSON; they never access a database or alter the workbook. No filename glob is supported. They do not read similarly named copies unless explicitly supplied as the input. Windows outputs receive an owner-only ACL through `whoami`/`icacls`; POSIX outputs use directory mode 0700/files 0600. Existing output directories are refused, and ACL failure prevents private data writing. Keep output outside tracked repository/documentation paths.

Outputs are `tenant-import.json` (contains personal/financial data) and `conversion-report.json` (fixed safe messages, source references and counts). Standard output contains only counts and source hash. Successful conversion can contain deferred/blocked rows; it does not claim successful import. Inspect the report before the reusable importer's preview. Offline acceptance on 4 October 2026 confirmed 19 SCL and 18 SBL rows, all 37 recurring salary structures, 36 financially reconciled September periods, and 22 reconciled leave openings. Five employee codes, 15 leave openings and one SBL deduction reason remain unresolved. Financial readiness does not bypass a blocked employee identity.

### Reviewed missing-code mapping

The five missing codes remain blocked until supplied. An optional JSON map is bound to the workbook fingerprint, so it cannot accidentally be reused for a different or changed workbook:

```json
{
  "source_hash": "<exact SHA-256 of the reviewed source>",
  "employee_codes": {
    "Sheet1:<reviewed worksheet row>": "<reviewed employee code>"
  }
}
```

Supply it with `--employee-code-map "<private reviewed map.json>"`. The keys address a row within that exact source; the reviewed employee code is the persistent identity. A source/mapping code disagreement or unused mapping blocks affected import identity rather than replacing a source code silently. Codes/usernames/credentials are never generated by the converter.

The user selected a provisional 31 August 2026 leave cutoff, each employee's joining date for salary assignment, and September 2026 payroll. An explicit ISO salary date is also supported. The five missing employee codes remain unresolved; none is invented.

### Native template import and reviewed replacement

The reusable engine is `hrms-svc/crates/kabipay-tenant-import`; it contains no workbook column mappings. `scripts/reusable/imports/import-tenant-template.ps1` runs it. The default action is **Preview**, which only reads the database and writes a private plan. No action migrates, deploys or automatically generates payslips.

Offline **Validate** checks the package contract and shared native salary/leave/period calculations without reading an environment file or connecting to a database. It writes a protected `validation-report.json` when an output path is supplied. Preview includes masked per-source section actions: CREATE/UPDATE/UNCHANGED for core identity, CREATE_AFTER_RESET for ordinary replaced staff, STAGE_FOR_REVIEW/DEFERRED for missing inputs, and RECONCILE for linked domain sections. The committed report gives the final CREATED/UPDATED/UNCHANGED/DEFERRED/FAILED facts after domain validation. Reconciliation actions are deliberately not promises that linked records can be overwritten.

Build from the service checkout:

```powershell
rtk proxy cargo build -p kabipay-tenant-import --offline
```

Create private options using `import-templates/v1/operator-options.schema.json`; the example is fictional. Supply exact tenant UUID/code, mapped schema/host/database, active actor with employee/payroll/leave manage ALL scopes, preserved usernames, reviewed absent usernames and optional login manifest. Usernames are never inferred. Existing passwords/roles are preserved; new random temporary credentials are written only to private staged output. Login failures defer login alone.

When the mapping has a Docker service hostname, `connection_host` must name the reviewed effective resolver host. Backup uses that same connection. `payroll_excluded_employee_ids` explicitly identifies retained management records excluded from payroll.

```powershell
# Offline validation: no environment or database connection.
rtk proxy powershell -NoProfile -File scripts/reusable/imports/import-tenant-template.ps1 -Action Validate -PackagePath "<private tenant-import.json>" -OptionsPath "<private options.json>" -OutputDirectory "<new private output>"

# Read-only default preview: verifies mapping, permissions, storage and target state.
rtk proxy powershell -NoProfile -File scripts/reusable/imports/import-tenant-template.ps1 -PackagePath "<private tenant-import.json>" -OptionsPath "<private options.json>" -EnvironmentFile "<private connection file>" -OutputDirectory "<new private preview output>"

# WRITES DATA: operator execution after reviewing the exact plan and destination.
rtk proxy powershell -NoProfile -File scripts/reusable/imports/import-tenant-template.ps1 -Action Apply -PackagePath "<private tenant-import.json>" -OptionsPath "<private options.json>" -EnvironmentFile "<private connection file>" -PlanPath "<preview output>/plan.json" -ConfirmDigest "<reviewed digest>" -OutputDirectory "<new private apply output>"
```

The connection file supplies `DATABASE_URL` for ops and `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` for the tenant resolver. No repository `.env` is loaded automatically. Keep packages, credentials, options and connection files private and outside tracked directories.

Independent sections use savepoints in one tenant transaction. Missing/invalid optional data produces DEFERRED results while valid sections continue. Reports distinguish CREATED, UPDATED, UNCHANGED, DEFERRED and FAILED, with fixed issue codes and source references. Historical opening LWP creates no dated requests and never supplies a later month's payroll days. Generated periods, altered salary structures or changed leave openings with subsequent activity require reviewed reconciliation.

Identical committed package/options/mode replay returns the persisted report without writes. To retry deferred sections after correcting configuration, set a new meaningful `review_reference` and review a fresh preview. Changed source values produce a new package hash. Domain identities prevent duplicate employees, assignments, balances or monthly records on corrected-file imports.

Replacement uses a separate review. Resolve every required employee identity and classify every target table in `reset_delete_tables`, `reset_truncate_tables` or `reset_retain_tables`. Foundation, permissions, roles, migration history and import audit remain retained. Preview with `-Replace`; review counts, exact preserved accounts and reset operations. Delete follows populated foreign-key dependencies; nullable links are cleared only to resolve supported cycles, and columns governed by check constraints are excluded from automatic clearing. Retained references to deleted rows and unsupported cycles block execution. Populated tables with delete triggers require explicit lifecycle review rather than being silently treated as ordinary deletes.

`reset_truncate_tables` explicitly selects a whole-table reset group, such as all three attendance day metadata tables for a pre-live reload. The group must include every table referencing a selected table, including empty referencing tables, and must exclude preserved identity/foundation tables and inherited/partitioned tables. The engine uses schema-qualified `TRUNCATE ... RESTRICT` in the import transaction, without CASCADE or disabling normal lifecycle guards.

For an approved replacement, pause application writes and add `-Replace -WritesPaused -PostgresBin "<PostgreSQL bin directory>"` to Apply, using the replacement preview/digest. A snapshot-consistent custom backup is taken and checked before deletion. Reset, import and committed audit are atomic. Restoration has been tested into a separate fictional database containing the ops foundation; restoring over a live schema requires its own reviewed procedure.

For an explicitly approved pre-live reset without a backup, set `"replacement_backup": {"mode": "SKIP", "reason": "Operator approved pre-live clean reload"}` in the operator options **before Preview**. The default is `{"mode":"REQUIRED"}`. A SKIP reason must be nonblank, at most 200 characters, and contain no control characters. The reviewed digest binds this choice, and the committed report/audit records it. With SKIP, `PostgresBin` is not required and no new backup is created; all target, preservation, write-lock and transaction checks still apply.

Failures after the private output directory is created write `failure.json` with a safe operation code and available SQLSTATE/constraint/table identifiers, excluding SQL text, bind values and database error details. A failure report does not establish commit status: check staged run state and persisted audit before retrying.

`run-state.staged.json` records the run ID before commit. If commit acknowledgement or final report writing fails, run `-Action Reconcile -RunId "<staged run ID>"` with the original package/options and new output. Distribute staged credentials only after the persisted run is confirmed committed.

Deploy reviewed migrations 0090–0094 and matching employee/payroll/leave/tax services, recompose the gateway and deploy the UI before client acceptance. HR reviews monthly inputs and unresolved costs, calculates/recalculates a draft, then explicitly selects Finalize & Lock. A stale review must be recalculated. Finalization is atomic and immutable; the old direct-run endpoint is retired. Company payslip display applies to all employees. Advances reduce remaining transfer payment while tax and net-earnings reports retain full earned salary. Payment itself remains external.

### Local verification

Focused local suites, from `hrms-database`:

```powershell
rtk proxy py -3 -m unittest discover -s tests/tenant_specific/solvian/unit -p test_converter.py -v
rtk proxy py -3 -m unittest discover -s tests/integration/imports -p test_import_storage.py
# Requires the native importer, payroll_fixture, and analytics payroll_report_fixture test executables.
rtk proxy node tests/integration/imports/native-import.integration.cjs
```

The storage and native acceptance suites start disposable loopback PostgreSQL clusters and never read repository `.env`. They cover full Liquibase migrations, replay, retained admin identity, reset, backup restoration and normal payroll statements. Local evidence does not prove deployment, actual tenant mappings, client import/reset or signed-in browser acceptance. Real client execution remains operator-controlled.

## Fresh-tenant permission catalog prerequisites (0051)

An empty tenant used to fail at `0052-003-assets-self-read-permissions`: it derives the asset module from `assets:manage`, but nothing earlier created that catalog entry. The canonical matrix in `0069` also requires workplace permission entries that were otherwise only supplied by later migrations or external seed data.

This new changeset is deliberately included **before 0052**. It adds the ten missing base catalog prerequisites, using the existing service entitlement ownership and `0070` workplace ownership definitions. It does not create role assignments, scopes, subscriptions, users, or employees. Existing IDs and descriptions remain unchanged. Missing/ambiguous modules, duplicate permission codes, conflicting module ownership and noncanonical existing spellings cause a clear failure instead of silently rewriting rows.

Historical changeset contents/checksums remain unchanged. Liquibase applies the new, previously unrecorded prerequisite on an interrupted tenant before retrying `0052`. An already migrated tenant receives only missing catalog entries; existing authorization is preserved. No `clearCheckSums`, changelog edits in the database, permission deletion, or tenant recreation is required.

The retired Solvian roster workflow and its integration tests are no longer shipped. The prerequisite changeset remains part of the reusable tenant migration chain; use the existing-tenant migration updater for a reviewed target. This cleanup does not establish fresh-schema or interrupted-migration runtime acceptance.

## Missing module subscriptions (0083)

Run once per ops/control-plane database, not once per tenant schema. This covers
every non-deleted tenant and every active module currently in `kabipay_ops.module`,
including Expenses, Tax, Recruitment and their active catalog dependencies.

For each missing `(tenant_id, module_id)`, insert an `ACTIVE` subscription with
`activated_at = NULL` and `expires_at = NULL` (available immediately without expiry).
The unique constraint plus `ON CONFLICT DO NOTHING` makes repeat execution safe.
Existing rows are skipped even when expired, suspended, cancelled, pending or
soft-deleted. Their IDs, dates, seats, usage, approval and audit fields are preserved.

New rows use the schema defaults: `contracted_seats = 0`, `current_seat_usage = 0`,
`overage_policy = BLOCK`. This grants module access; it does not allocate licensed
seats or change pricing. Tenant status, module activation, explicit feature flags
and employee permissions are unchanged. A suspended tenant remains suspended.
The preflight reports these remaining blockers, including dependency problems.

### Run

From `D:\work\heliorventures\hrms-database`, first confirm `.env` points at the
intended ops database. The following preflight is read-only:

```powershell
rtk proxy node run-sql-raw.cjs -f scripts/reusable/maintenance/module-subscription-preflight.sql
```

Review the missing subscription counts and other blockers before applying:

```powershell
rtk npm run migrate-ops
```

This applies **all pending ops migrations**, including 0083. It does not run tenant
schema migrations. Repeat the preflight afterward: missing subscription counts
should be zero for the current active catalog and non-deleted tenants. Reload the
affected pages and verify access with each relevant role. No image rebuild is
needed for this data change; entitlement snapshots are loaded per request.

The backfill does not create missing module catalog entries, override explicit
disables, or restore existing inactive subscriptions. It runs once in Liquibase;
tenants/modules created afterward need normal subscription provisioning. There is
no automatic rollback: removing granted access requires a reviewed forward change.

### Local checks

```powershell
py -3 tests/unit/migrations/module_subscription_backfill_test.py
rtk npm test
```

The Python test executes the INSERT unchanged against in-memory SQLite fixtures
to check selection, preservation and repeat execution. It does not connect to `.env`
or establish PostgreSQL/Liquibase integration or production access.

## Admin and HR permission defaults (0085)

0080 created prejoining permissions without role grants. 0076 already granted
survey access, but missing grants/scopes can remain on an existing tenant. 0069
gave Admin only the permissions present at that point in migration history; its
HR list excluded role administration. The demo seed also rebuilt an older matrix.

0085 adds missing grants and scopes for the 58 current UI permission codes using
explicit Admin/HR decisions. The shared tenant changelog covers existing tenants
and new provisioning. The demo seed consumes the same registered decisions.
Catalog creation and module ownership remain in the preceding feature migrations;
0085 fails rather than silently skipping missing or ambiguous catalog entries.

- Prejoining manage/review, survey manage/results and Settings role management: ALL.
- Survey respond, performance self and other personal actions: SELF.
- HR asset read is NONE because its existing assets:manage covers administration.
- Performance evaluate is NONE for both roles; evaluation is assigned through MANAGER
  with TEAM scope. NONE adds nothing and does not remove an existing assignment.
- HR now receives role:manage=ALL, including the ability to administer tenant roles.
- Existing grants/scopes and custom roles are retained. Existing narrower or otherwise
  different scopes are reported, never widened automatically. A missing grant is
  restored even when its scope row already exists; explicit scope values are retained.
- No user-role assignments, module subscriptions or active sessions are modified.
  Users must sign out and sign in again after deployment to refresh permissions.

### Run for an existing client

Run from hrms-database with its configured database connection. Resolve the actual
schema first; the client code is not the schema name. This is a read-only query:

```powershell
rtk proxy node run-sql-raw.cjs 'SELECT t.name, t.subdomain, td.tenant_id, td.schema_name FROM kabipay_ops.tenant_database td JOIN kabipay_ops.tenant t ON t.id=td.tenant_id ORDER BY t.name'
```

Replace `tenant_ACTUAL_SCHEMA` below with the confirmed schema for the client.

```powershell
# Read-only; exit 2 means missing defaults, scope differences or ambiguity.
rtk proxy node scripts/reusable/rbac/audit-admin-hr-permissions.cjs tenant_ACTUAL_SCHEMA nhr

# Applies ALL pending tenant migrations, including 0085. Review pending releases first.
rtk proxy powershell -NoProfile -File scripts\reusable\migrations\update-tenant-liquibase.ps1 -Schema tenant_ACTUAL_SCHEMA

# Read-only postflight. Review preserved differences; then sign in again.
rtk proxy node scripts/reusable/rbac/audit-admin-hr-permissions.cjs tenant_ACTUAL_SCHEMA nhr
```

`npm run migrate-ops` does not apply this tenant migration. Do not run the demo seed
as a production repair: it intentionally rebuilds demo role assignments and data.

### Adding the next permission

Add catalog creation and explicit role/scope assignments in a NEW tenant migration.
Include it in tenant.changelog-master.xml. Add a SQL `admin_hr_defaults` INSERT
between `-- permission-defaults:start` and `-- permission-defaults:end` markers with
four columns: resource, action, admin_scope, hr_scope. Use NONE for a deliberate
non-grant. These must be executable migration decisions, not comments. Never edit
0085 after deployment to add future permissions; Liquibase tracks its checksum.

The checker reads the registered migrations in order; later decisions supersede
earlier ones for audits and seeding. It detects newly introduced UI permission codes
without an explicit default decision; it does not replace review of backend-only
permissions, SQL behavior or scope suitability.

```powershell
rtk npm test
rtk npm run check:permission-defaults
# Separate UI checkout: node scripts/reusable/rbac/check-permission-defaults.cjs C:/path/to/permissions.ts
rtk npm run test:permission-defaults:integration
```

The integration test creates its own temporary PostgreSQL cluster on 127.0.0.1:55489,
never reads .env, and stops it afterwards. It uses PostgreSQL 17 under Program Files
by default; set PG_TEST_BIN to another local bin directory. Temporary files are
retained at the printed path for diagnostics. It exercises the migration SQL with
a focused RBAC fixture; it does not claim full tenant provisioning or live UI proof.

## Survey response review (0086)

Apply this tenant migration before deploying the matching survey service, gateway,
and UI. The tenant master includes it after 0085. No production database was
changed during implementation.

Existing surveys default to `AGGREGATE_ONLY`, preserving their original reporting
promise. Their individual submissions cannot be retrieved through the new API.
Create a new survey (or copy an existing questionnaire into a new draft) and
explicitly choose `ANONYMOUS_SUBMISSIONS` to collect future responses with the
new disclosure. Changing the mode of an already published survey is prohibited.

For `ANONYMOUS_SUBMISSIONS`, individual review requires both `survey:manage` and
`survey:results` with exact `ALL` scope, and survey status `CLOSED`. Returned
submissions contain questionnaire answers and an arbitrary ordinal, without
respondent IDs, response IDs, timestamps, actors or organizational metadata.
Free text can identify its author; respondents must see that warning before
submitting. Closed surveys cannot reopen and published surveys cannot return to
draft; use a new survey for a new collection round.

This mode withholds aggregate results before closure and excludes TEAM and
DEPARTMENT slices to prevent matching individual content back to an
organizational group. After closure, authorized individual reviewers see complete
organization-wide charts, including small counts. Other ALL-scope results
viewers retain minimum-group suppression. Legacy aggregate-only reporting keeps
its existing scope and suppression rules. Management participation counts expose
only assigned/completed/pending totals, never assignment identities.

Question guidance is optional, up to 2,000 characters. Rating and choice questions
can enable an optional respondent comment up to 4,000 characters, stored alongside
the primary answer. Existing questions default to comments disabled.

From the database repository, after verifying the real target connection and
reviewing all pending tenant migrations:

```powershell
$surveyTenantSchema = Read-Host 'Enter the verified existing tenant schema'
rtk proxy powershell -NoProfile -File scripts\reusable\migrations\update-tenant-liquibase.ps1 -Schema $surveyTenantSchema
```

This command **applies every pending tenant migration**, not only 0086. Earlier
0082/0084 migrations have their own preconditions; review them before running.
`npm run migrate-ops` does not apply this tenant migration. Rollback deliberately
requires a forward corrective migration to preserve disclosed privacy modes.

Local verification:

```powershell
rtk proxy node tests/integration/surveys/survey-response-review.integration.cjs
```

The test starts and stops a disposable loopback-only PostgreSQL 17 cluster, does
not load `.env`, and retains its temporary directory for diagnostics. It executes
the migration's column declarations and SQL against a fixture schema and checks
legacy defaults, immutable published modes, permanent closure and content limits.
This is not proof that Liquibase ran against a deployed tenant.
