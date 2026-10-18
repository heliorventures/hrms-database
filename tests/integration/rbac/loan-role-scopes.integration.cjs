// Synthetic disposable PostgreSQL only. Never load .env or production connection settings.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const root = path.resolve(__dirname, '../../..');
const baseline = process.argv.includes('--baseline'); // Explicitly reproduce the pre-migration missing-scope failure.
const migration = path.join(root, 'changelog/migrations/0110_loan_role_scopes/loan_role_scopes.xml');
const xml = baseline ? '' : fs.readFileSync(migration, 'utf8');
const sql = baseline ? '' : xml.match(/<sql splitStatements="false"><!\[CDATA\[([\s\S]*?)\]\]><\/sql>/)[1].replaceAll('${schema}', 'loan_scope_fixture');
const fixture = fs.readFileSync(path.join(__dirname, 'loan-role-scopes.fixture.sql'), 'utf8');
const container = 'hrms-loan-scopes-' + randomUUID().replaceAll('-', '');
const tenant = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const actions = ['read','submit','approve','disburse','repay','manage','policy','correct','exit-review','export'];
let db;
let created = false;
let checks = 0;
function docker(args) {
  const result = spawnSync('docker', args, { encoding: 'utf8', windowsHide: true, timeout: 60000 });
  if (result.error || result.status !== 0) throw new Error(`Docker fixture command failed: ${result.error || result.stderr}`);
  return result.stdout.trim();
}
async function grant(name, granted, tenantId = tenant) {
  await db.query(`INSERT INTO loan_scope_fixture.role_permission(role_id,permission_id)
    SELECT r.id,p.id FROM loan_scope_fixture.role r CROSS JOIN loan_scope_fixture.permission p
    WHERE r.name=$1 AND r.tenant_id=$2 AND p.resource='loan' AND p.action=ANY($3::text[])`,[name,tenantId,granted]);
}
async function scope(name, action, type) {
  await db.query(`INSERT INTO loan_scope_fixture.permission_scope(tenant_id,role_id,resource,action,scope_type)
    SELECT tenant_id,id,'loan',$2,$3 FROM loan_scope_fixture.role WHERE name=$1 AND tenant_id=$4`,[name,action,type,tenant]);
}
async function snapshot() {
  return (await db.query(`SELECT jsonb_build_object(
    'roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM loan_scope_fixture.role r),
    'permissions',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM loan_scope_fixture.permission p),
    'grants',(SELECT jsonb_agg(to_jsonb(g) ORDER BY role_id,permission_id) FROM loan_scope_fixture.role_permission g),
    'scopes',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM loan_scope_fixture.permission_scope s),
    'modules',(SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM kabipay_ops.module m),
    'mapping',(SELECT jsonb_agg(to_jsonb(t) ORDER BY schema_name) FROM kabipay_ops.tenant_database t)) AS state`)).rows[0].state;
}
async function migrate() {
  await db.query('BEGIN');
  try {
    if (!baseline) await db.query(sql);
    await db.query('COMMIT');
  } catch (error) { await db.query('ROLLBACK'); throw error; }
}
async function check(name, run) {
  await db.query(fixture);
  await run();
  checks++;
  console.log(`PASS ${name}`);
}
async function main() {
  try {
    docker(['run','--pull=never','--rm','-d','--name',container,'--memory','256m','--cpus','1','-p','127.0.0.1::5432',
      '-e','POSTGRES_USER=scope_fixture','-e','POSTGRES_PASSWORD=scope_fixture','-e','POSTGRES_DB=scope_fixture','postgres:16-alpine']);
    created = true;
    const binding = docker(['port',container,'5432/tcp']);
    const match = binding.match(/^127\.0\.0\.1:(\d+)$/);
    assert.ok(match, 'refusing a non-loopback fixture endpoint');
    let ready = false;
    for (let attempt=0;attempt<60;attempt++) {
      const result=spawnSync('docker',['exec',container,'pg_isready','-h','127.0.0.1','-U','scope_fixture','-d','scope_fixture'],{windowsHide:true,stdio:'ignore',timeout:5000});
      if (result.status===0) { ready=true;break; }
      await new Promise(resolve=>setTimeout(resolve,200));
    }
    assert.ok(ready,'disposable PostgreSQL did not become ready');
    db=new Client({host:'127.0.0.1',port:Number(match[1]),user:'scope_fixture',password:'scope_fixture',database:'scope_fixture',ssl:false,connectionTimeoutMillis:5000});
    await db.connect();
    console.log('POSTGRES_FIXTURE_CONNECTED=true');
    await check('existing HR/Admin grants receive only missing scopes; restrictions and grants preserved',async()=>{
      await grant('HR',actions);await grant('ADMIN',actions);
      await scope('HR','read','TEAM');await scope('ADMIN','policy','SELF');
      const before=await snapshot();await migrate();const after=await snapshot();
      for (const key of ['roles','permissions','grants','modules','mapping']) assert.deepEqual(after[key],before[key],key);
      for (const old of before.scopes) assert.ok(after.scopes.some(row=>JSON.stringify(row)===JSON.stringify(old)),'existing scope must remain byte-equivalent');
      const rows=(await db.query(`SELECT r.name,s.action,s.scope_type FROM loan_scope_fixture.permission_scope s JOIN loan_scope_fixture.role r ON r.id=s.role_id`)).rows;
      for (const role of ['HR','ADMIN']) for (const action of actions) {
        const expected=role==='HR' && action==='read'?'TEAM':role==='ADMIN' && action==='policy'?'SELF':action==='submit'?'SELF':'ALL';
        assert.ok(rows.some(row=>row.name===role && row.action===action && row.scope_type===expected),`missing ${role} loan:${action} scope`);
      }
      assert.equal(rows.length,20);
      const first=await snapshot();await migrate();assert.deepEqual(await snapshot(),first,'repeat must preserve scope IDs, timestamps and restrictions');
    });
    await check('no loan grants means no scopes or automatic permissions',async()=>{
      const before=await snapshot();await migrate();assert.deepEqual(await snapshot(),before);
    });
    await check('custom, manager, employee, deleted and other-tenant roles remain excluded',async()=>{
      await grant('HR',['approve']);
      for (const role of ['CUSTOM','MANAGER','EMPLOYEE','hr']) await grant(role,actions);
      await grant('HR',actions,other);
      await db.query(`INSERT INTO loan_scope_fixture.role_permission SELECT r.id,p.id FROM loan_scope_fixture.role r CROSS JOIN loan_scope_fixture.permission p WHERE r.name='ADMIN' AND p.resource='payroll'`);
      await scope('CUSTOM','read','SELF');
      const before=await snapshot();await migrate();const after=await snapshot();
      assert.deepEqual(after.grants,before.grants);assert.equal(after.scopes.length,2);
      assert.ok(after.scopes.some(row=>row.tenant_id===tenant && row.action==='approve' && row.scope_type==='ALL'));
      assert.ok(after.scopes.some(row=>JSON.stringify(row)===JSON.stringify(before.scopes[0])));
    });
    for (const [name,setup] of [
      ['missing tenant mapping',`DELETE FROM kabipay_ops.tenant_database`],
      ['ambiguous active canonical role',`INSERT INTO loan_scope_fixture.role(tenant_id,name) VALUES('${tenant}',' hr ')`],
      ['missing loan catalog entry',`DELETE FROM loan_scope_fixture.permission WHERE resource='loan' AND action='export'`],
      ['wrong module owner',`UPDATE loan_scope_fixture.permission SET module_id=(SELECT id FROM kabipay_ops.module WHERE code='PAYROLL') WHERE action='export'`],
      ['ambiguous normalized permission',`INSERT INTO loan_scope_fixture.permission(resource,action,module_id) SELECT 'LOAN','READ',module_id FROM loan_scope_fixture.permission WHERE action='read'`],
      ['cross-tenant scope',`UPDATE loan_scope_fixture.permission_scope SET tenant_id='${other}' WHERE action='read'`],
      ['ambiguous normalized scope',`INSERT INTO loan_scope_fixture.permission_scope(tenant_id,role_id,resource,action,scope_type) SELECT tenant_id,role_id,'LOAN','READ','SELF' FROM loan_scope_fixture.permission_scope WHERE action='read'`],
      ['invalid stored scope',`UPDATE loan_scope_fixture.permission_scope SET scope_type='INVALID' WHERE action='read'`],
      ['unmatchable stored scope key',`UPDATE loan_scope_fixture.permission_scope SET resource=' loan ' WHERE action='read'`],
    ]) await check(`${name} fails without partial changes`,async()=>{
      await grant('HR',['read','approve']);await scope('HR','read','TEAM');await db.query(setup);
      const before=await snapshot();await assert.rejects(migrate(),/0110/);assert.deepEqual(await snapshot(),before);
    });
    console.log(`LOAN_SCOPE_CHECKS_PASSED=${checks}`);
  } finally {
    if (db) await db.end();
    if (created) {
      assert.match(container,/^hrms-loan-scopes-[a-f0-9]{32}$/);
      docker(['rm','--force',container]);
      console.log('OWNED_FIXTURE_REMOVED=true');
    }
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
