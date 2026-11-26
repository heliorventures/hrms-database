// Owned disposable loopback cluster only. No .env, application DSN or SMTP.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {fixture} = require('../../private-events/tests/local-postgres-fixture.cjs');
const root = path.resolve(__dirname, '../../..');
const directory = path.resolve(__dirname, '..');
const tenant = '00000000-0000-4000-8000-000000000001';
const other = '00000000-0000-4000-8000-000000000002';
const event = '00000000-0000-4000-8000-000000000003';
const resource = '00000000-0000-4000-8000-000000000004';

function compile(schema = 'tenant_fixture') {
  const code = "import sys;sys.path.insert(0,sys.argv[1]);import email_columns;print(email_columns.grants_sql(sys.argv[2]))";
  const result = spawnSync(process.env.RUNTIME_GRANTS_PYTHON, ['-c', code, directory, schema], {
    encoding: 'utf8', windowsHide: true, timeout: 60000,
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

test('real email DDL and service grants isolate tenants, producers, immutable events and transactions', async t => {
  const schema = path.join(root, 'changelog/migrations/0132_tenant_email/schema.sql');
  assert(fs.existsSync(schema), 'durable email schema is missing');
  const pg = await fixture(); t.after(() => pg.stop());
  const roles = ['employee', 'leave', 'attendance', 'payroll', 'expense', 'tax', 'performance', 'notification', 'maintenance'];
  pg.query('postgres', roles.map(role => `CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('') +
    'CREATE DATABASE company_fixture;');
  const sql = fs.readFileSync(schema, 'utf8').replaceAll('${schema}', 'tenant_fixture')
    .replaceAll('${companyTenantId}', tenant);
  pg.query('company_fixture', 'CREATE SCHEMA tenant_fixture; ' + sql + compile());
  pg.query('company_fixture', `CREATE TABLE tenant_fixture.permission(id uuid PRIMARY KEY,resource text,action text,module_id uuid,description text);
    INSERT INTO tenant_fixture.permission VALUES(gen_random_uuid(),'notification','read','${resource}','Existing Notification/EMPLOYEE permission');`);
  const migration = fs.readFileSync(path.join(root, 'changelog/migrations/0132_tenant_email/tenant_email.xml'), 'utf8');
  const catalog = migration.match(/<!\[CDATA\[([\s\S]*?)\]\]>/)[1].replaceAll('${schema}', 'tenant_fixture');
  pg.query('company_fixture', catalog);
  assert.equal(pg.query('company_fixture', "SELECT count(*) FROM tenant_fixture.permission WHERE resource='email_settings'").trim(), '3');
  const as = (role, sql) => pg.psql('company_fixture', {role: 'hrms_company_' + role,
    sql: 'SET search_path=tenant_fixture,pg_catalog;' + sql});
  const nonce = '00000000-0000-4000-8000-000000000006';
  const receipt = (scope = tenant, seconds = 59) => `INSERT INTO email_private_request_receipt
    (tenant_id,audience,purpose,nonce,request_hash,expires_at)
    VALUES('${scope}','kabipay-email-recipient','email_recipient','${nonce}',repeat('a',64),clock_timestamp()+interval '${seconds} seconds')
    ON CONFLICT DO NOTHING RETURNING nonce;`;
  const firstReceipt = as('employee', receipt());
  assert.equal(firstReceipt.status, 0, firstReceipt.stderr);
  assert(firstReceipt.stdout.includes(nonce));
  const replay = as('employee', receipt());
  assert.equal(replay.status, 0, replay.stderr);
  assert(!replay.stdout.includes(nonce), 'a replay cannot obtain a second consumed receipt');
  assert.notEqual(as('employee', receipt(other)).status, 0, 'receipt cannot route into another tenant');
  assert.notEqual(as('employee', receipt(tenant, 65).replaceAll(nonce, resource)).status, 0, 'proof expiry is bounded to 60 seconds');
  assert.notEqual(as('employee', 'DELETE FROM email_private_request_receipt').status, 0, 'unexpired receipt cannot be purged to enable replay');
  assert.notEqual(as('employee', "UPDATE email_private_request_receipt SET request_hash=repeat('b',64)").status, 0);
  const oldNonce = '00000000-0000-4000-8000-000000000007';
  pg.query('company_fixture', `INSERT INTO tenant_fixture.email_private_request_receipt
    (tenant_id,audience,purpose,nonce,request_hash,created_at,expires_at)
    VALUES('${tenant}','kabipay-email-recipient','email_recipient','${oldNonce}',repeat('c',64),clock_timestamp()-interval '120 seconds',clock_timestamp()-interval '61 seconds');`);
  assert.equal(as('employee', `DELETE FROM email_private_request_receipt WHERE nonce='${oldNonce}'`).status, 0, 'only expired nonce metadata is eligible for bounded cleanup');
  assert.notEqual(as('notification', "UPDATE tenant_email_settings SET credential_cipher=decode('aa','hex'),version=version+1").status, 0,
    'partial encrypted credential cannot pass a nullable CHECK');
  const rawEvent=scope=>JSON.stringify({tenant_id:scope,event_id:event,resource_type:'leave',resource_id:resource,resource_version:'v1',category:'leave',kind:'outcome',occurred_at:'2026-11-24T00:00:00Z',expires_at:'2026-12-01T00:00:00Z',recipient:{type:'local_user',user_id:resource},actor_ref:null});
  const insert = (scope = tenant, hash = 'a') => `INSERT INTO important_email_intent
    (id,tenant_id,event_id,recipient_key,event_hash,event,producer,resource_type,resource_id,resource_version,category,kind,occurred_at,expires_at)
    VALUES(gen_random_uuid(),'${scope}','${event}','local:${resource}',repeat('${hash}',64),'${rawEvent(scope)}','leave','leave','${resource}','v1','leave','outcome','2026-11-24T00:00:00Z','2026-12-01T00:00:00Z')
    ON CONFLICT(tenant_id,event_id,recipient_key) DO NOTHING RETURNING id,event_hash;`;
  assert.notEqual(as('leave', insert(other)).status, 0, 'cross-tenant insert denied');
  const first = as('leave', insert()); assert.equal(first.status, 0, first.stderr);
  assert(first.stdout.includes('a'.repeat(64)));
  assert.equal(as('leave', insert()).status, 0, 'same immutable event is idempotent');
  assert.notEqual(as('leave', insert().replace('"actor_ref":null', `"actor_ref":{"type":"local_user","user_id":"${nonce}"}`)).status, 0,
    'same hash cannot acknowledge a different immutable body');
  assert.notEqual(as('leave', insert(tenant, 'b')).status, 0, 'different duplicate hash is a conflict');
  for (const operation of [
    'SELECT credential_cipher FROM tenant_email_settings',
    "UPDATE important_email_intent SET state='ACCEPTED'",
    'SELECT state FROM important_email_intent',
    'DELETE FROM important_email_intent',
  ]) assert.notEqual(as('leave', operation).status, 0, 'producer cannot access settings or delivery');
  assert.notEqual(as('employee', insert()).status, 0, 'producer cannot impersonate another domain');
  for (const domain of ['attendance','performance']) {
    const resourceType=domain==='attendance'?'attendance':'performance_review';
    const kind=domain==='attendance'?'missed_punch_out':'outcome';
    const category=domain==='attendance'?'missed_punch_out':'approval';
    const payload=insert().replaceAll(event,'00000000-0000-4000-8000-000000000017')
      .replace("'leave','leave'",`'${domain}','${resourceType}'`).replace("'v1','leave'",`'v1','${category}'`).replace("'outcome'",`'${kind}'`);
    const bound=payload.replace('"resource_type":"leave"',`"resource_type":"${resourceType}"`).replace('"category":"leave"',`"category":"${category}"`).replace('"kind":"outcome"',`"kind":"${kind}"`);
    const result=as('maintenance','BEGIN;'+bound+'ROLLBACK;');
    assert.equal(result.status,0,result.stderr);
  }
  assert.notEqual(as('maintenance',insert()).status,0,'scheduler cannot impersonate Leave');
  for (const query of ['SELECT credential_cipher FROM tenant_email_settings',"UPDATE important_email_intent SET state='ACCEPTED'",'SELECT event FROM important_email_intent']) {
    assert.notEqual(as('maintenance',query).status,0,'scheduler cannot read secrets/events or take over delivery');
  }

  assert.notEqual(as('notification', "UPDATE important_email_intent SET event_hash=repeat('b',64)").status, 0);
  assert.equal(as('notification', "UPDATE important_email_intent SET state='CLAIMED',lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '90 seconds',settings_version=1").status, 0);
  const rollback = insert().replaceAll(event, '00000000-0000-4000-8000-000000000005');
  assert.equal(as('leave', 'BEGIN;' + rollback + 'ROLLBACK;').status, 0);
  assert.equal(pg.query('company_fixture', 'SELECT count(*) FROM tenant_fixture.important_email_intent').trim(), '1');
  assert.notEqual(as('notification', 'DELETE FROM important_email_intent').status, 0, 'nonterminal purge denied');
  const terminal = as('notification', "UPDATE important_email_intent SET state='FAILED',terminal_at=clock_timestamp()-interval '31 days' RETURNING (terminal_at>clock_timestamp()-interval '1 minute')::text;");
  assert.equal(terminal.status, 0, terminal.stderr);
  assert(terminal.stdout.includes('true'), 'terminal timestamp is database-owned, not backdated by the worker');
  assert.notEqual(as('notification', 'DELETE FROM important_email_intent').status, 0, 'cannot bypass retention by backdating terminal state');
  assert.equal(pg.query('company_fixture', "SELECT has_table_privilege('hrms_company_leave','tenant_fixture.important_email_intent','SELECT')").trim(), 'f');
  assert.equal(pg.query('company_fixture', "SELECT has_column_privilege('hrms_company_leave','tenant_fixture.important_email_intent','event_hash','SELECT WITH GRANT OPTION')").trim(), 'f');
  const schemaSql = fs.readFileSync(schema, 'utf8');
  for (const name of ['tenant_fresh', 'tenant_upgrade']) {
    pg.query('company_fixture', 'CREATE SCHEMA ' + name + ';' + schemaSql.replaceAll('${schema}', name)
      .replaceAll('${companyTenantId}', tenant) + compile(name));
  }
  const acl = name => pg.query('company_fixture', `SELECT grantee,table_name,column_name,privilege_type
    FROM information_schema.column_privileges WHERE table_schema='${name}' ORDER BY 1,2,3,4;`);
  assert.equal(acl('tenant_fresh'), acl('tenant_upgrade'), 'same DDL/service contract for fresh and upgrade installations');
});
