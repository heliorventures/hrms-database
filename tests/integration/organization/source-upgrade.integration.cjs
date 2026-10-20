// Actual migration prefix in a fresh loopback Docker fixture; no .env or external DSN.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {Client} = require('pg');
const root = path.resolve(__dirname, '../../..');
const owner = randomUUID();
const container = 'source-upgrade-' + owner.replaceAll('-', '');
const tenant = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const survey = '33333333-3333-4333-8333-333333333333';
const empty = '44444444-4444-4444-8444-444444444444';
let created = false, db, blocker, failed = 0, passed = 0;
function docker(args) {
  const r = spawnSync('docker', args, {encoding:'utf8', windowsHide:true, timeout:60000});
  if (r.error || r.status !== 0) throw Error('Owned Docker fixture command failed: ' + (r.error?.message ?? r.stderr));
  return r.stdout.trim();
}
async function check(name, run) {
  try { await run(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
}
async function main() {
  assert(process.argv.includes('--docker-fixture'), 'EXPLICIT_OWNED_DOCKER_FIXTURE_REQUIRED');
  docker(['run','--pull=never','--rm','-d','--name',container,'--label','codex.source-upgrade='+owner,
    '--memory','256m','-p','127.0.0.1::5432','-e','POSTGRES_USER=upgrade_fixture',
    '-e','POSTGRES_PASSWORD=synthetic-only','postgres:16-alpine']);
  created = true;
  const endpoint = docker(['port',container,'5432/tcp']).match(/^127\.0\.0\.1:(\d+)$/);
  assert(endpoint);
  for (let i=0;i<60;i++) {
    try { docker(['exec',container,'pg_isready','-h','127.0.0.1','-U','upgrade_fixture']); break; }
    catch { if (i===59) throw Error('FIXTURE_NOT_READY'); await new Promise(r=>setTimeout(r,250)); }
  }
  const config={host:'127.0.0.1',port:Number(endpoint[1]),user:'upgrade_fixture',password:'synthetic-only',database:'postgres',connectionTimeoutMillis:5000};
  db = new Client(config); blocker = new Client(config);
  await db.connect(); await blocker.connect();
  await db.query('SET statement_timeout=8000');
  await db.query('CREATE SCHEMA source_one;'+
    'CREATE TABLE source_one.company_event_outbox(id uuid PRIMARY KEY,organization_id uuid NOT NULL,source_tenant_id uuid,created_at timestamptz,source_position bigserial,event_envelope jsonb);'+
    'CREATE TABLE source_one.outbox_event(id uuid PRIMARY KEY,tenant_id uuid,event_type text,aggregate_type text,aggregate_id uuid,created_at timestamptz);'+
    'CREATE TABLE source_one.separation(id uuid PRIMARY KEY,tenant_id uuid,offboarding_event_id uuid,CONSTRAINT fk_separation_offboarding_event FOREIGN KEY(offboarding_event_id) REFERENCES source_one.outbox_event(id));'+
    'CREATE TABLE source_one.audit_log(id uuid PRIMARY KEY,tenant_id uuid,entity_type text,entity_id uuid,action text,created_at timestamptz);'+
    'CREATE TABLE source_one.survey(id uuid PRIMARY KEY,tenant_id uuid);'+
    'CREATE TABLE source_one.webhook_subscription(id uuid PRIMARY KEY,updated_at timestamptz);');
  await db.query('INSERT INTO source_one.survey VALUES($1,$2),($3,$2)',[survey,tenant,empty]);
  for (const [id,action,time,company] of [
    ['00000000-0000-4000-8000-000000000001','SURVEY_OPENED','2026-10-01T01:00:00.123456Z',tenant],
    ['00000000-0000-4000-8000-000000000002','SURVEY_MANUALLY_OPENED','2026-10-01T02:00:00.123456Z',tenant],
    ['00000000-0000-4000-8000-000000000003','SURVEY_TRANSITION_FAILED','2026-10-01T03:00:00.123456Z',tenant],
    ['00000000-0000-4000-8000-000000000004','SURVEY_AUTOMATICALLY_CLOSED','2026-10-01T03:00:00.123456Z',tenant],
    ['00000000-0000-4000-8000-000000000005','SURVEY_SAVED','2026-10-01T04:00:00.123456Z',tenant],
    ['00000000-0000-4000-8000-000000000006','SURVEY_TRANSITION_FAILED','2026-10-01T05:00:00.123456Z',other],
  ]) await db.query("INSERT INTO source_one.audit_log VALUES($1,$2,'SURVEY',$3,$4,$5)",[id,company,survey,action,time]);
  await db.query("INSERT INTO source_one.survey SELECT md5('survey-'||n)::uuid,$1 FROM generate_series(1,200) n",[tenant]);
  await db.query("INSERT INTO source_one.audit_log SELECT md5('audit-'||n||'-'||a)::uuid,$1,'SURVEY',md5('survey-'||n)::uuid,CASE a WHEN 1 THEN 'SURVEY_OPENED' WHEN 2 THEN 'SURVEY_MANUALLY_OPENED' WHEN 3 THEN 'SURVEY_TRANSITION_FAILED' ELSE 'SURVEY_SAVED' END,'2026-10-01'::timestamptz+make_interval(secs=>a) FROM generate_series(1,200) n CROSS JOIN generate_series(1,4) a",[tenant]);
  const xml=fs.readFileSync(path.join(root,'changelog/migrations/0125_private_event_source/private_event_source.xml'),'utf8');
  const all=[...xml.matchAll(/<!\[CDATA\[([\s\S]*?)\]\]>/g)].map(m=>m[1]).join('\n').replaceAll('${schema}','source_one');
  const boundary=all.indexOf('CREATE TABLE "source_one".private_capture_source_marker');
  assert(boundary>0);
  const upgrade=all.slice(0,boundary);
  await blocker.query('BEGIN;LOCK TABLE source_one.audit_log IN ROW EXCLUSIVE MODE');
  await check('contended upgrade fails with lock timeout and atomically restores the old schema',async()=>{
    await db.query('BEGIN');
    try { await assert.rejects(db.query(upgrade),e=>e.code==='55P03'); }
    finally { await db.query('ROLLBACK'); }
    assert.equal((await db.query("SELECT count(*)::int n FROM information_schema.columns WHERE table_schema='source_one' AND table_name='company_event_outbox' AND column_name='event_stream'")).rows[0].n,0);
    assert.equal((await db.query("SELECT to_regclass('source_one.private_survey_execution_state') present")).rows[0].present,null);
  });
  await blocker.query('ROLLBACK');
  await db.query('BEGIN');
  await db.query(upgrade);
  await check('migration limits apply only to the upgrade transaction',async()=>{
    assert.equal((await db.query('SHOW lock_timeout')).rows[0].lock_timeout,'5s');
    assert.equal((await db.query('SHOW statement_timeout')).rows[0].statement_timeout,'1min');
  });
  await db.query('COMMIT');
  assert.equal((await db.query('SHOW statement_timeout')).rows[0].statement_timeout,'8s');
  await check('backfill preserves exact opening, transition tie-break, tenant boundary and empty history',async()=>{
    const row=(await db.query('SELECT *,opened_at::text exact_open FROM source_one.private_survey_execution_state WHERE survey_id=$1',[survey])).rows[0];
    assert.match(row.exact_open,/01:00:00\.123456/);
    assert.equal(row.last_transition_action,'SURVEY_AUTOMATICALLY_CLOSED');
    assert.equal(row.last_transition_id,'00000000-0000-4000-8000-000000000004');
    const blank=(await db.query('SELECT * FROM source_one.private_survey_execution_state WHERE survey_id=$1',[empty])).rows[0];
    assert.equal(blank.opened_at,null); assert.equal(blank.last_transition_id,null);
    assert.equal((await db.query('SELECT count(*)::int n FROM source_one.private_survey_execution_state')).rows[0].n,202);
  });
  await check('audit backfill scans history once instead of once per survey',async()=>{
    const start=upgrade.indexOf('INSERT INTO "source_one".private_survey_execution_state');
    assert(start>0);
    const insert=upgrade.slice(start,upgrade.indexOf(';',start)+1);
    await db.query('BEGIN;DELETE FROM source_one.private_survey_execution_state');
    try {
      const plan=(await db.query('EXPLAIN (ANALYZE,FORMAT JSON) '+insert)).rows[0]['QUERY PLAN'][0].Plan;
      const scans=[];
      function visit(node) { if(node['Relation Name']==='audit_log')scans.push(node); for(const child of node.Plans??[])visit(child); }
      visit(plan);
      assert.equal(scans.length,1,'audit history must have one scan');
      assert.equal(scans[0]['Actual Loops'],1,'audit history must not be rescanned per survey');
    } finally { await db.query('ROLLBACK'); }
  });
  await check('operator registry query covers suspended tenants and cannot write source state',async()=>{
    const {registryQuery,checkRegistry}=require('../../../provisioning/organization/check-rollout.cjs');
    await db.query("CREATE SCHEMA kabipay_ops;CREATE TABLE kabipay_ops.tenant(id uuid,status text,is_deleted boolean,subdomain text)");
    await db.query("INSERT INTO kabipay_ops.tenant VALUES($1,'ACTIVE',false,'company-a'),($2,'SUSPENDED',false,'company-b'),($3,'PROVISIONING',false,'not-ready'),($4,'TERMINATED',false,'ended'),($5,'ACTIVE',true,'deleted')",[tenant,other,randomUUID(),randomUUID(),randomUUID()]);
    await db.query('BEGIN');
    try {
      const result=await db.query(registryQuery),rows=result.at(-1).rows[0].inventory;
      assert.deepEqual(rows.map(r=>r.status),['ACTIVE','SUSPENDED']);
      const receipt=checkRegistry({tag:'synthetic-001',digest:'a'.repeat(64),companyBindings:[{id:tenant,slug:'company-a'},{id:other,slug:'company-b'}]},rows);
      assert(receipt.includes('tenant_ids='+tenant+','+other+'\n'));
      await assert.rejects(db.query("INSERT INTO kabipay_ops.tenant VALUES($1,'ACTIVE',false,'forbidden')",[randomUUID()]),e=>e.code==='25006');
    } finally {await db.query('ROLLBACK');}
    // Exercise the operator's actual psql output flags; SET command tags must
    // not pollute the JSON receipt input. Transport here is synthetic/local.
    const output=docker(['exec',container,'psql','--username=upgrade_fixture','--dbname=postgres',
      '--no-psqlrc','--no-password','--quiet','--no-align','--tuples-only','--set=ON_ERROR_STOP=1',
      '--single-transaction','--command',registryQuery]);
    assert.deepEqual(JSON.parse(output).map(r=>r.id),[tenant,other]);
  });
  console.log('Source upgrade: '+passed+' passed, '+failed+' failed');
  if(failed)process.exitCode=1;
}
main().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(async()=>{
  if(blocker)await blocker.end().catch(()=>{});
  if(db)await db.end().catch(()=>{});
  if(created){assert.equal(docker(['inspect','--format','{{index .Config.Labels "codex.source-upgrade"}}',container]),owner);docker(['rm','--force',container]);}
});
