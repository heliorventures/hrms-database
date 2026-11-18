# Explicit runtime database permissions

These operator tools inspect and apply one reviewed database/schema/role contract.
They never derive permission authority from SQL text, service names, or entity
ownership. The source inventory and deployed catalog inventory must be reconciled
before creating an executable policy.

## Operations

- `inventory --target TARGET.json --output NEW.json --maintenance-window` records
  security/catalog metadata under the held admission barrier. This output is
  explicitly an inventory, **not a grant plan**. It contains no business rows,
  password verifiers, passwords, or CA keys.
- `preview --policy POLICY.json` is a read-only observation on an already open
  database. It explicitly does not establish a maintenance barrier or grant plan.
- `prepare --policy POLICY.json --output NEW.json --maintenance-window` validates
  the current upper bound and writes a protected plan with its review hash.
- `apply --plan PLAN.json --expected-sha256 HASH --maintenance-window` requires
  that exact reviewed plan and baseline. It grants only the specified rights,
  checks the exact postcondition before commit, and reads it back afterward.
- `verify --plan PLAN.json --expected-sha256 HASH --maintenance-window` compares
  the current permissions and catalog against the reviewed expected poststate.

Run with `sudo python3 run.py ...` on the reviewed Docker host. The fixed
PostgreSQL container is `postgres`; the operator username is resolved inside that
container. No `.env` or password file is opened. There is no remote DSN override.
The control database `postgres` and both template databases are rejected as
targets and as entries in the database allowlist before maintenance I/O.

## Held maintenance barrier

The operator explicitly approves `--maintenance-window` for every operation that
changes database admission. All legacy and newly deployed HRMS applications must
remain stopped. A separate control connection checks the cluster/database and
restricted role identities before admitting one persistent superuser socket
connection. Normal-role admission is limited to zero while that connection is
established. The control connection then sets `ALLOW_CONNECTIONS false` and
restores the original connection limit while admission remains closed.

All catalog inspection, grant execution and verification use the already admitted
connection. The operation refuses other existing connections; it does not
terminate them. New connections, including superusers, cannot enter the closed
database. Success and failure both leave the database closed. This is not an
application startup or availability-restoration tool. Restoring production
admission is a separate reviewed cutover action.

If closure cannot be confirmed after a command/transport failure, the runner
reports `MAINTENANCE_BARRIER_CONFIRMATION_FAILED` instead of success. Inspect
admission from the control database before retrying. An uncertain grant commit
requires exact verification or a new prepared plan, never a guessed receipt.

## Contract and bounds

Built-in Employee and Performance profiles also validate the explicit page
column requirements in `policy.py`. RBAC entity reads include metadata columns;
guidance needs its filtered timestamp read and idempotent INSERT/RETURNING;
the raw Performance summary reads `review_cycle.current_stage` beyond its ORM
model. Missing requirements reject a policy; validation never adds grants.

`business_columns.py` records the separately reviewed Employee onboarding,
profile, separation and clearance operations, Leave workflow trail, and
conditional Payroll loan/workflow and unpaid-leave snapshot operations. It
includes the profile notification and HR exit-operation dependencies. Built-in
Employee, Leave and Payroll policy validation requires these explicit columns;
it never silently expands an operator plan. Payroll credential reads
(`password_hash`, `mfa_secret`) are rejected even if explicitly requested.

`online_business_columns.py` compiles the corresponding guarded additive SQL
using the same catalog checks as `online_columns.py`. It is pure compilation,
not a production execution command. Review its exact additions and obtain the
current capability/catalog baseline before any rollout. These business
requirements do not grant DELETE. Payroll receives `UPDATE(id)` on
`workflow_step` solely because PostgreSQL requires UPDATE authority for the
existing row lock; workflow configuration columns remain unwritable. Application
tenant, employee, action, scope and module checks remain required.

`online_columns.py` is a pure SQL compiler for these reviewed access additions.
It requires an open, explicitly named company database, restricted service roles
with no memberships in either direction or ownership, an exact catalog baseline
and transaction postcondition. The Access replacement operations also require
INSERT columns and DELETE on `role_permission`, `permission_scope`, and
`user_role`. DELETE is limited to these explicit relationship tables; permission
catalog writes remain excluded. It emits no table-wide SELECT/INSERT/UPDATE,
schema/database grants, role changes, row updates, admission changes or defaults. The caller must bind
the approved fleet/cluster, preserve protected before/after receipts and resolve
an uncertain commit by readback. Do not use the maintenance runner on a live
application. Native regression: `tests/online-columns-native.test.cjs`.

The exact top-level fields are `version`, `systemId`, `database`,
`allowedDatabases`, `schema`, `creators`, `roles`, and an empty `blockers` array.
Each role has `tables`, `sequences`, and `functions`.

- SELECT/INSERT/UPDATE require explicit column lists. DELETE is explicit per
  named table. No wildcard, all-tables, all-sequences, or default grant is emitted.
- Runtime roles must be restricted LOGIN NOINHERIT identities with no role
  memberships, ownership, CREATE, TEMP, replication or bypass privileges.
- Effective PUBLIC/column rights, grant options, foreign database/schema access,
  sequence privileges and callable function identities are checked.
- Functions bind their exact catalog signature, source-definition digest, owner,
  definer setting and owner-authority graph digest. Procedures are unsupported.
- Schema creators must be named explicitly. Their effective global plus
  schema-specific function defaults must not grant PUBLIC/runtime EXECUTE;
  absent default-ACL rows are expanded using PostgreSQL's built-in defaults.
- System access is checked against initial catalog privileges. The explicit
  information-schema SELECT baseline is derived from the pinned official
  [PostgreSQL 16.14 source](https://github.com/postgres/postgres/blob/REL_16_14/src/backend/catalog/information_schema.sql).
  It permits only the enumerated bootstrap objects, never new arbitrary objects
  added to a system schema. No secret catalog values are selected.
- System-schema CREATE and grant options, system sequences, large-object access,
  foreign wrapper/server USAGE and tablespace CREATE are unsupported and block
  preparation. Type/language rights are limited to built-in PUBLIC defaults
  without grant options. Owner-authority hashes do not replace these effective
  runtime checks.

Any excess ACL/default/function capability blocks additive grant preparation.
The `run.py` workflow never revokes rights. The separate ACL correction workflow
below requires its own reviewed plan and authorization. Neither workflow alters
passwords, owner roles, role creation or source authority state.

Policy and plan hashes use canonical JSON, not the bytes/file checksum. Plans and
inventory outputs require a canonical root-owned directory with mode 0700 and a
new root-owned file with mode 0600. The local operator lock serializes admission
changes; it supplements the database admission barrier.

## Source authority is separate

For private events, use the existing provisioner's explicit
`-PermissionMode authority-only` to validate/initialize source authority without
publishing its compatibility grants. Keep all source identity, generation,
legacy coverage and retirement/fencing requirements intact. Assign only the
caller-proven private publication/receipt columns in the reviewed runtime policy.

## Focused local verification

Python unit tests (Linux is required for ownership, fsync and file-lock cases):

```sh
python3 -m unittest discover -s provisioning/runtime-grants/tests -p 'test_*.py' -v
```

Owned native PostgreSQL 16 fixture, with an explicit local tool directory:

```powershell
$env:PRIVATE_TEST_PG_BIN = '<absolute local PostgreSQL 16 bin directory>'
node --experimental-test-isolation=none --test provisioning/runtime-grants/tests/native.test.cjs
```

These are local proofs. They do not establish deployed grants, complete service
acceptance, a live registry switch, or successful Kafka/ClickHouse ingestion.

## Separate PUBLIC ACL corrections

`acl_catalog.py` records original grantors, implicit defaults, overload identities,
extension membership and dependencies without function bodies or business rows.
`acl_corrections.py` accepts only individually named PUBLIC EXECUTE reductions,
PUBLIC USAGE removal from `public`, and explicit function-default reductions for
observed creators. It never infers an operation from a finding, grants replacement
rights, issues wildcard revokes or uses CASCADE. Unrelated ACLs and grant options
are preserved. The complete before/after catalog, role graph, definitions,
dependencies and untouched ACL fingerprint are compared inside one transaction.

An explicit caller permission contract must cover required nested helpers,
defaults, sequences and table columns before application startup. Removing PUBLIC
access does not supply these service permissions or prove runtime readiness.

`acl_operator.py` separates three operator actions. All require a stopped writer
fleet, the reviewed canonical plan hash, `--maintenance-window`, and a new output
file in an existing root-owned directory with mode 0700. Input for `apply`/`verify`
must be a root-owned plan with mode 0600, written by `prepare`.

```sh
python3 acl_operator.py prepare --plan reviewed-proposal.json --expected-sha256 REVIEWED_HASH --output /root/NEW_PRIVATE_DIRECTORY/plan.json --maintenance-window
python3 acl_operator.py apply --plan /root/NEW_PRIVATE_DIRECTORY/plan.json --expected-sha256 REVIEWED_HASH --output /root/NEW_PRIVATE_DIRECTORY/apply-receipt.json --maintenance-window
python3 acl_operator.py verify --plan /root/NEW_PRIVATE_DIRECTORY/plan.json --expected-sha256 REVIEWED_HASH --output /root/NEW_PRIVATE_DIRECTORY/verify-receipt.json --maintenance-window
```

These are templates, not authorization to apply production changes. Preparation
checks the exact current catalog and writes a plan without executing its revokes.
Each action holds the existing maintenance connection and leaves the database
closed. HUP/TERM/INT are deferred over admission and cleanup; hard termination or
host/transport failure still requires inspection from the control database.
Success is published only after barrier cleanup. If a command loses its result,
use `verify` with a new receipt path; never blindly rerun `apply`. A mixed/drifted
state requires investigation and a newly reviewed plan. The additive grant engine
requires a fresh post-correction snapshot and owner-authority hashes.

The focused native regression additionally covers correction rollback, definition,
extension/dependency drift, explicit unrelated grants, future function defaults,
and restricted-role GiST exclusion/index inserts after PUBLIC revocation:

```powershell
node --experimental-test-isolation=none --test provisioning/runtime-grants/tests/acl-corrections-native.test.cjs
```

### Private broker ownership receipt permissions

The Employee service's authenticated private ownership endpoint reads a delivery
receipt and records initial broker ownership after the work record is durable in
Kafka. Its contract is explicit in `private_ownership_columns.py`: nine named
read columns and UPDATE on `broker_owned_at`, `broker_owner_id`,
`broker_receipt_sha256` and `updated_at`. The policy validator rejects incomplete
company contracts; it does not silently add permissions.

`online_private_ownership_columns.py` compiles the existing guarded, column-only
online operation for this contract. It preserves role membership, admission,
owners, row security, definitions and unrelated ACLs. A production operation
requires fresh per-company snapshots and exact reviewed approval. It does not
approve requests, replay deliveries or reset Kafka offsets. A worker already
retrying may resume automatically once its missing service privileges exist.

The focused native regression uses actual receipt DDL and its immutable-proof
trigger with synthetic data. It covers the denied read/write, successful initial
ownership, preserved receiver status, immutable existing proof, forbidden identity
writes/deletion, unrelated-service denial, grant-option denial and drift rollback:

```powershell
node --experimental-test-isolation=none --test provisioning/runtime-grants/tests/private-ownership-columns-native.test.cjs
```

### Calculation and imported details

`calculation_columns.py` covers the actual imported-profile/bank extension,
Payroll employment eligibility and exit dates, and conditional old-regime proof
summary.

`payroll_authority.py` compiles a separate company-bound installation and exact
verification for `hrms_lock_payroll_inputs_v1(uuid)` and
`hrms_payroll_input_fingerprint_v1(uuid)`. The existing NOLOGIN company owner
receives internal USAGE plus SELECT on the fixed 30 input tables and UPDATE on
the 31 lock tables. Payroll receives only EXECUTE. PUBLIC/other callers are
denied; source, signature, owner, search path and tenant/database bindings are
verified. The v2 digest bytes and SHARE ROW EXCLUSIVE locking semantics are
preserved. Functions return no business rows and perform no financial writes.
The fingerprint helper checks exact serialized UTF-8 input size before building
any table array and refuses inputs above 32 MiB. This bounds its input contract;
it is not a measured upper bound on PostgreSQL process memory.

For fresh isolated companies, install and verify this authority after the real
schema baseline and before preparing the runtime grant policy. Supply an
explicit target with `systemId`, `database`, `schema`, `tenantId`, `owner` and
`sourceOwner`; source ownership and membership-free NOLOGIN authority must match.
The pure compiler performs no database I/O. Installation refuses existing helper
names. An optional preserved-routine descriptor permits only the previously
reviewed `organization_capture_admin_version()` trigger, bound to its exact
definition hash, owner and owner-only execution ACL. Other owner routines and
owner-owned relations are refused before internal privileges are granted.
An uncertain/mixed result requires operator readback, not a rerun.
Built-in Payroll policies require both exact reviewed function descriptors,
including current definition and owner-authority digests. Validation refuses
omissions rather than inventing grants. Adding an application role using existing
permissions/scopes does not require a different service/database policy.

### Page read and payslip visibility contracts

`page_columns.py` records explicit caller requirements for Employee company
documents and salary-bearing employment history, Payroll payslip visibility,
and Performance cycle program/deadline reads. The validator rejects incomplete
future policies. These are service database rights: salary-history API access
still requires the resolver's exact payroll scope; no end-user role is changed.
Unused entity models do not receive access automatically.

`presentation_columns.py` additionally covers the populated payslip branch:
tenant-scoped employee/department/designation projections, imported annual salary
fields and immutable statement reads. The Notification marker contract includes
eight INSERT columns, SELECT(id) for RETURNING, and SELECT on the five explicit
ON CONFLICT arbiter columns. These reads are required even for DO NOTHING;
granting only INSERT and RETURNING(id) is insufficient. No notification payload
read, marker UPDATE/DELETE or payroll profile write is added.

### Monthly Payroll writes and draft conflict updates

After the two snapshot helpers are installed, `monthly_input_authority.py`
installs `hrms_lock_payroll_period_input_v1(uuid)`. It preserves the monthly
edit's ROW EXCLUSIVE lock without giving the runtime login table-wide UPDATE.
The existing company NOLOGIN owner's internal rights are reused. Only Payroll
receives EXECUTE; tenant/database binding, fixed relation, safe search path and
timeout are verified. Rust callers require an explicit `DatabaseTransaction`.

`draft_columns.py` declares the seven draft reads required by the existing
UPSERT, including its four EXCLUDED-field reads.

New Payroll
policies require all three helpers. After installation use
`monthly_input_authority.verify_sql`, or explicitly opt into
`payroll_authority.verify_sql(..., include_period_lock=True)`; the original
two-helper verifier deliberately rejects the additional owner routine.
