# Organization PostgreSQL operational provisioning

Canonical production source/metadata grants, CDC boundary checks and publication SQL. Apply Liquibase migrations first. Every provisioning command is separate from Kafka installation, connector creation and application rollout. No RLS policy, password, existing ACL, slot or existing publication is automatically replaced/removed.

## Company binding and role prerequisite

A company runtime requires a fixed non-system schema, matching `BoundTenantDatabase`: ASCII letter/underscore followed by ASCII letters/digits/underscores, at most63 bytes; reject public, kabipay_ops, information_schema (case insensitive) and any pg_ prefix. The operator must preprovision a unique LOGIN REPLICATION NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE identity named `organization_cdc_<canonical company UUID without hyphens>`. Example company11111111-1111-4111-8111-111111111111 uses `organization_cdc_11111111111141118111111111111111`. The wrapper and SQL derive/check this exact binding; callers cannot supply another role. No role/password creation happens here.

Dedicated CDC identities must have no role memberships, database/schema/relation ownership, source writes or unrelated user-table access. **PostgreSQL replication has no publication ACL.** A connected replication identity can request other publications in that database. Provisioning rejects all-table/schema publications and any publication exposing tables beyond that identity's exact allowed outbox/marker boundary. Existing expected publications are accepted only when their exact table count/membership and publish operations match; mismatches fail without alteration.

**Default PUBLIC CONNECT makes an unhardened cluster fail provisioning.** Both company and metadata CDC guards reject effective CONNECT to every other connectable database, including postgres/template1. A DBA must independently review existing PUBLIC/role grants and preserve intended existing access while restricting these identities. This script never revokes PUBLIC or changes another role. A role-specific pg_hba rule alone does not satisfy the SQL effective-CONNECT guard because SQL cannot verify HBA enforcement. Retain both ACL hardening and reviewed HBA restrictions.

Review pg_hba first-match ordering: allow the exact own database + exact CDC identity + fixed private Connect address with verify-full client certificate mapping; reject that identity for all other database/address combinations and physical replication. Ensure earlier broad rules cannot match it. Give each company a distinct certificate/source password, even when databases share one PostgreSQL cluster. Restrict the metadata role independently to its one metadata database. Logical replication roles remain sensitive: validate the complete DBA/network boundary before production use.

## Independent operator command

Configure a local libpq service binding DBA host/user, root CA and client certificate. Passfiles/service files are operator-owned secrets; none are generated/displayed here. Run from workspace root using native PowerShell and psql:

```powershell
./hrms-database/provisioning/organization/provision.ps1 -Operation company -Database company_one -Service company_one_dba -CompanyId 11111111-1111-4111-8111-111111111111 -SourceSchema tenant_company_one
./hrms-database/provisioning/organization/provision.ps1 -Operation control -Database metadata -Service metadata_dba
./hrms-database/provisioning/organization/provision.ps1 -Operation workers -Database metadata -Service metadata_dba
```

CompanyId/SourceSchema are mandatory for company mode and forbidden for other modes. Database/schema/role identifiers are validated and passed as psql quoted identifiers. Startup files are disabled; errors abort the enclosing transaction. SQL independently checks company/schema/role binding. Run SQL through this wrapper so the shared canonical `cdc-boundary-guard.sql` is loaded relative to its owner file.

Company publication `organization_company_outbox` contains exactly `<SourceSchema>.company_event_outbox` and `<SourceSchema>.organization_capture_marker`. Metadata publication `organization_control_outbox` contains only `kabipay_ops.organization_outbox`; metadata identity remains the separately managed `organization_control_cdc`. Ordinary worker grants retain existing RLS and never grant BYPASSRLS.

Logical slots are cluster-wide: each company connector derives `organization_company_<32 UUID hex>`; the central metadata slot is separate. Monitor the exact derived slot, logical WAL settings, bounded max_slot_wal_keep_size and invalidation. Slot deletion/recreation/history skipping require separate operator review. Neither provisioning nor connector restart authorizes data retirement.

## Evidence

### Shared-fleet cutover inventory

Before starting the new organization application topology on the existing single shared VPS, render the exact release with hrms-documentation. Then use a read-only ops libpq service and an operator-owned passfile:

```powershell
node hrms-database/provisioning/organization/check-rollout.cjs --release-dir D:/review/hrms-release --service hrms_ops_readonly --database ops_database --output D:/review/cutover-inventory.txt
```

Replace the example release path, service and database with reviewed values. The tool never loads .env, accepts passwords on the command line, or changes the registry. psql uses verify-full TLS, disables startup files/password prompting and runs a repeatable-read, read-only transaction with a ten-second query limit. Keep PGSERVICEFILE/PGPASSFILE and CA material local to the database operator.

The manifest must include every nondeleted ACTIVE and SUSPENDED tenant in this shared registry, with its exact current subdomain. Suspended tenants retain their deployment so later reactivation cannot expose a missing runtime. PROVISIONING/TERMINATED/deleted tenants are excluded; a manifest containing an unready tenant is rejected. Multiple independent fleets require an explicit fleet ownership model before using this tool.

The operator tool verifies every rendered artifact against release.sha256, then issues a new receipt bound to that checksum index, tag and tenant set. It refuses to overwrite an existing receipt. The application deployment requires this file through -InventoryReport. The receipt expires after fifteen minutes and the remote guard checks it before image loading and immediately before startup.

Freeze tenant provisioning, status/subdomain changes and the reviewed release files from inventory generation through application/Caddy cutover. Re-rendering, changing files, changing the company set or exceeding the window requires a fresh query and receipt. This receipt prevents deployment mistakes under a trusted operator; it is not a signed authorization credential and does not prove source grants, TLS, migration, browser or restore acceptance.

### Existing-company migration 0125

Preparation retains transaction-local five-second lock waits and sixty-second statement limits. Contention or an oversized backfill aborts the changeset atomically. Survey state uses one windowed audit scan, preserving earliest opening and the latest supported transition by timestamp/UUID. Necessary locks on separation/outbox/audit/survey still pause writes during the transaction.

Rehearse on a representative protected copy, measure lock/backfill duration and schedule a bounded maintenance window before applying to a live tenant. If the measured data cannot fit the limit, stop and design a staged preparation; do not remove the bounds or blindly retry against traffic. This changeset has not been released to production in the reviewed feature worktree. Never modify a changeset already applied in production; use a forward migration instead.

The 0115 rollback guard deliberately refuses to discard durable organization evidence. After enabling organization writes, preserve compatible schema and attribution through an accepted forward recovery or tested restore procedure. Do not remove the guard or fabricate local actor IDs. The separate 0126/0127 retirement changelogs remain opt-in behind their existing gates.

`./hrms-database/provisioning/organization/tests/provision.test.ps1` exercises native wrapper argument validation and failure propagation with mocked psql; SQL boundary checks are inspected as static contracts. It contacts no database. Current canonical SQL passed an isolated native PostgreSQL17.6 rehearsal:46 SQL operations/assertions including two-company exact schema/role binding, PUBLIC/cross-database CONNECT rejection, table/column privilege rejection, role membership rejection, exact publication reapply, row filter/column list/table count mismatch rejection, unrelated/all-table/schema publication rejection, reserved-schema/wrong-role rejection and preserved RLS. The owned loopback-only server was stopped. Run `./hrms-database/provisioning/organization/tests/native-cdc.test.ps1` to repeat with the locally installed native binaries. This is PostgreSQL17.6, **not pinned PostgreSQL16**, source TLS/pg_hba rollout, actual logical replication/Connect delivery or production acceptance. Earlier public-schema/shared-role synthetic results describe superseded SQL and do not prove the current contract.


A separate complete Kafka owner rehearsal also passed against Docker PostgreSQL16.15 with two company databases on one source server: current canonical company SQL/default PUBLIC CONNECT rejection/exact reapply, derived separate roles/slots, actual client-certificate CN plus verify-full TLS and SCRAM, cross-database/wrong-CN/wrong-password rejection, and real outbox/marker CDC through two private Connect instances. Evidence: workspace `.codex-tmp/kafka-tls-1792395273962/runtime-transcript.log`; repeat with `hrms-kafka/test/tls-runtime/Run.ps1` after explicit runtime-slot coordination. This bounded pinned16 subset does not replace the broader native17.6 negative matrix above, optional metadata CDC delivery, or production acceptance.
