# Private source authority initialization

Run after forward migration 0125 for a company, or 0124 for metadata, before enabling the private producers. The operator must use a dedicated DBA libpq service and passfile. The wrapper never accepts a password, free-form connection string, SQL, arbitrary schema for metadata, or worker database credential. TLS is always `verify-full`.

```powershell
./provision.ps1 -Operation company -Service company_dba -Database Company_One `
  -ScopeId '<registered company UUID>' -SourceSchema Tenant_One -RuntimeRole company_runtime `
  -RegistryService metadata_dba -RegistryDatabase Metadata -RuntimeHost postgres-company `
  -BootstrapMode empty

./provision.ps1 -Operation operator -Service metadata_dba -Database Metadata `
  -ScopeId '<configured stable metadata audit scope UUID>' -RuntimeRole metadata_runtime `
  -BootstrapMode existing -ProducerGeneration 1
```

`ScopeId` is explicit. A company UUID must match the active `kabipay_ops.tenant_database` registration, database, source schema and reviewed runtime host. The wrapper checks that registration through a separate trusted metadata service before connecting to the source. Metadata operator audit uses the stable scope UUID already configured for its private keys, consumer binding and query proof; it is never derived from an arbitrary tenant or replaced with a hardcoded UUID. Company schema names retain their case. Metadata schema is exactly `kabipay_ops`.

Choose `empty` only when every intact legacy source table is empty. Choose `existing` when at least one contains rows. Both paths insert only an initial PREPARED source authority with the explicitly selected generation (default 1) and all cutover flags false. This classification does not create archive evidence, assert verified-empty acceptance, switch readers, fence old writers, transfer pending ownership, or authorize retirement. Those are separate source-owned export/cutover operations. Missing legacy inventory blocks a new authority. Reapplying the same initial authority is idempotent; a changed generation, database, schema, source version, advanced state or any changed cutover flag is rejected and preserved.

Company initialization checks every local `tenant_id` UUID column and the publication outbox's owning `source_tenant_id` for foreign identities. Other business tables can legitimately retain foreign actor/source references, such as `organization_command_receipt.source_tenant_id`; those references do not determine the local source identity. Registered metadata mapping is a reviewed snapshot; the bound runtime independently rechecks registration at startup. No shared worker or history reader receives any source database grant or source encryption key.

## Runtime permissions

The runtime role must preexist as LOGIN, NOSUPERUSER, NOBYPASSRLS, NOCREATEDB, NOCREATEROLE and NOREPLICATION. It cannot own databases/schemas/relations, have memberships or be granted to other roles, create user-schema objects, or read/mutate another source schema in the current database. By default it cannot connect to another database. Existing business grants in its own schema are retained. Broad inherited or PUBLIC grants cause a failure; the script does not revoke or silently correct them. In particular, stock PUBLIC CONNECT to unapproved databases must be reviewed by the DBA before provisioning.

### Shared company business-service logins

For the approved shared application layout, provide the same reviewed database list to each company's invocation for a service login:

```powershell
$companyDatabases = @('company_one', 'company_two')
./provision.ps1 -Operation company -Service company_dba -Database company_one `
  -ScopeId '<company-one UUID>' -SourceSchema tenant_one -RuntimeRole employee_runtime `
  -RegistryService metadata_dba -RegistryDatabase Metadata -RuntimeHost postgres-company `
  -BootstrapMode existing -CompanyDatabases $companyDatabases
```

Use the actual inventory classification, generation and exact registered identities. The list is case-sensitive, includes the current database, contains at most 100 unique names, and excludes system/metadata databases. Each entry must match one active POSTGRES mapping on the reviewed host, owned by one non-deleted ACTIVE/SUSPENDED company with no second active mapping. Every listed database must exist on the source server and accept connections. Effective CONNECT to any unlisted database, including via PUBLIC, blocks bootstrap.

The list permits existing approved connections; this invocation grants CONNECT and source permissions only in its current database. Repeat provisioning for every company and each business-service role. No per-company password is added to service files. Adding a company requires updating the reviewed provisioning inventory and granting the existing roles access there. Freeze registry mappings/status changes for the full provisioning sequence: metadata validation and each source transaction are separate, and the runtime independently checks its mappings again. A successful invocation does not certify privileges in databases not yet provisioned.

Omit `CompanyDatabases` for isolated company roles. Operator audit rejects it and retains the single-database rule. CDC/private-worker provisioners and their purpose-specific isolation are unchanged. Do not use this option to broaden worker or reader credentials. The wrapper transfers the non-secret list as base64-encoded JSON to preserve quoting through Windows PowerShell native arguments; SQL decodes and validates it before use.

New grants are SELECT on source authority, accepted legacy manifest state and compact source business state; bounded INSERT columns on the existing publication outbox and compact receipts/state; bounded UPDATE columns on delivery outcome/lease/ownership and survey lifecycle state. The publication sequence receives USAGE, never UPDATE/setval. No runtime grant writes legacy tables, capture markers/evidence, migration ownership plans, acceptance, source identity, generation, source version or cutover flags. Operator-only private capture/export/cleanup/retirement functions must not be executable by the runtime, including through PUBLIC.

PostgreSQL requires UPDATE permission on at least one column for `SELECT ... FOR SHARE`. The authority receives only `UPDATE(updated_at)` for that row lock. This timestamp is operational metadata and is not an authorization, generation, archive hash, acceptance or freshness prerequisite. Every authority identity/generation/state/flag column remains unwritable. This avoids a privileged SECURITY DEFINER runtime API. Private legacy manifests need SELECT only; the source history readers do not lock them for update.

The bootstrap grants do not replace existing business grants for users, employees, subscriptions and other domain tables. Source adapter requests remain fixed-purpose authenticated RPC references; granting the source runtime its local privileges never grants a shared broker or query service source access.

## Checks

`tests/provision.test.ps1` mocks native psql to verify argument binding, fixed service/database/TLS connections, canonical scope IDs, case preservation, role/schema negatives, generation bounds, registration-before-source ordering and stop-on-error. This is not database evidence. The native database fixture and its exact result are recorded in the provider report after execution. Live bootstrap/deployment is separate.

`tests/shared-runtime.test.cjs` creates an owned, loopback-only native PostgreSQL cluster from `PRIVATE_TEST_PG_BIN`, without reading `.env`. It checks two real company databases, a shared role, registry negatives, PUBLIC CONNECT leakage, role membership and protected authority columns. Run with `node --experimental-test-isolation=none --test provisioning/private-events/tests/shared-runtime.test.cjs`. Native fixture results do not establish production TLS or PostgreSQL 16 acceptance when run with another server version.
