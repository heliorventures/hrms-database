// Runs real service transactions only in an owned loopback cluster. No SMTP.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {fixture} = require('../../private-events/tests/local-postgres-fixture.cjs');
const root = path.resolve(__dirname, '../../..');

async function runOwnedEmailSettings(t, target, testName) {
  assert(['email_settings_owned','email_key_rotation_owned'].includes(target));
  assert(['owned_settings_transactions','owned_rotation_preview_apply_resume_and_missing_key'].includes(testName));
  const pg = await fixture(); t.after(() => pg.stop());
  const tenant = '00000000-0000-4000-8000-000000000001';
  const actors = [11, 12, 13, 14].map(n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`);
  const roles = ['employee', 'leave', 'attendance', 'payroll', 'expense', 'tax', 'performance', 'notification','maintenance'];
  pg.query('postgres', roles.map(role => `CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('') + 'CREATE DATABASE company_email_fixture;');
  const schema = fs.readFileSync(path.join(root, 'changelog/migrations/0132_tenant_email/schema.sql'), 'utf8')
    .replaceAll('${schema}', 'tenant_fixture').replaceAll('${companyTenantId}', tenant);
  const compiled = spawnSync(process.env.RUNTIME_GRANTS_PYTHON, ['-c',
    "import sys;sys.path.insert(0,sys.argv[1]);import email_columns;print(email_columns.grants_sql('tenant_fixture'))",
    path.join(root, 'provisioning/runtime-grants')], {encoding: 'utf8', windowsHide: true});
  assert.equal(compiled.status, 0, compiled.stderr);
  pg.query('company_email_fixture', 'CREATE SCHEMA tenant_fixture;' + schema + compiled.stdout);
  // Minimum existing common-audit SQL prerequisites, not new email grants.
  // These are a separate production preflight dependency, never inferred from
  // an end-user role. The actual append_audit code runs as Notification below.
  pg.query('company_email_fixture', `
    CREATE TABLE tenant_fixture."user"(id uuid PRIMARY KEY,tenant_id uuid NOT NULL);
    INSERT INTO tenant_fixture."user" VALUES ${actors.map(actor => `('${actor}','${tenant}')`).join(',')};
    CREATE TABLE tenant_fixture.private_source_cutover(tenant_id uuid PRIMARY KEY,producer_generation bigint NOT NULL,updated_at timestamptz NOT NULL DEFAULT now());
    INSERT INTO tenant_fixture.private_source_cutover(tenant_id,producer_generation) VALUES('${tenant}',1);
    CREATE TABLE tenant_fixture.company_event_outbox(id uuid PRIMARY KEY,source_tenant_id uuid NOT NULL,organization_id uuid,
      event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz);
    GRANT SELECT(id,tenant_id),UPDATE(id) ON tenant_fixture."user" TO hrms_company_notification;
    GRANT SELECT(tenant_id,producer_generation),UPDATE(updated_at) ON tenant_fixture.private_source_cutover TO hrms_company_notification;
    GRANT INSERT(id,source_tenant_id,organization_id,event_type,aggregate_type,aggregate_id,aggregate_version,event_envelope,event_stream,created_at)
      ON tenant_fixture.company_event_outbox TO hrms_company_notification;`);
  const privateKeys = path.join(pg.directory, 'synthetic-audit-keys.json');
  fs.writeFileSync(privateKeys, JSON.stringify({schema_version: 1, keys: [{tenant_id: tenant,
    purpose: 'audit', key_id: 'fixture', key_b64: Buffer.alloc(32, 1).toString('base64'), active: true}]}), {flag: 'wx', mode: 0o600});
  const config = path.join(pg.directory, 'owned-email-settings-fixture.json');
  fs.writeFileSync(config, JSON.stringify({port: pg.connection('postgres').port,
    tenant, actors, system_id: pg.query('postgres', 'SELECT system_identifier FROM pg_control_system()').trim(),
    data_directory: path.join(pg.directory, 'data')}), {flag: 'wx', mode: 0o600});
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) =>
    !/^(PG|POSTGRES|DATABASE|KABIPAY)/i.test(name)));
  env.KABIPAY_EMAIL_OWNED_FIXTURE = config;
  env.KABIPAY_PRIVATE_EVENT_KEYS_FILE = privateKeys;
  const result = spawnSync('cargo', ['test', '--offline', '--locked', '-p', 'kabipay-notification',
    '--test', target, '--', '--ignored', '--exact', testName, '--test-threads=1'], {
    cwd: path.resolve(root, '../hrms-svc'), env, encoding: 'utf8', windowsHide: true, timeout: 1200000,
  });
  assert.equal(result.status, 0, (result.stderr || '') + (result.stdout || ''));
  assert.match(result.stdout, /test result: ok\. 1 passed/, 'the owned integration test must actually execute');
}

module.exports={runOwnedEmailSettings};
