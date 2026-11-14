// Synthetic SQL behavior only; full Liquibase baseline is a separate rehearsal.
const test=require('node:test');
const assert=require('node:assert/strict');
const {Client}=require('pg');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {applyDefaults,validateAdmins,assertAdminAuthority}=require('../company-bootstrap.cjs');
const {buildRoleDefaults}=require('../../../scripts/reusable/rbac/canonical-role-defaults.cjs');

test('canonical writer converges and preserves custom, inactive and unrelated role decisions',async()=>{
 const f=await fixture();const db=new Client(f.connection('postgres'));
 const tenant='11111111-1111-4111-8111-111111111111';
 try{
  await db.connect();await db.query(`CREATE SCHEMA tenant_fresh;
   CREATE TABLE tenant_fresh.role(id uuid PRIMARY KEY,tenant_id uuid,name text,description text,is_deleted boolean DEFAULT false);
   CREATE TABLE tenant_fresh.permission(id uuid PRIMARY KEY,resource text,action text);
   CREATE TABLE tenant_fresh.role_permission(role_id uuid,permission_id uuid,PRIMARY KEY(role_id,permission_id));
   CREATE TABLE tenant_fresh.permission_scope(id uuid PRIMARY KEY,tenant_id uuid,role_id uuid,resource text,action text,scope_type text);
   CREATE TABLE tenant_fresh.user_role(user_id uuid,role_id uuid);
   CREATE TABLE tenant_fresh.user_session(user_id uuid);`);
  const defaults=buildRoleDefaults();
  await db.query(`INSERT INTO tenant_fresh.permission SELECT gen_random_uuid(),resource,action FROM json_to_recordset($1::json) AS d(resource text,action text) GROUP BY resource,action`,[JSON.stringify(defaults)]);
  const target={schema:'tenant_fresh',tenantId:tenant};
  await db.query('BEGIN');assert.equal((await applyDefaults(db,target)).added,164);await db.query('COMMIT');
  const counts=(await db.query(`SELECT name,count(*)::int AS n FROM tenant_fresh.role r JOIN tenant_fresh.role_permission p ON p.role_id=r.id GROUP BY name ORDER BY name`)).rows;
  assert.deepEqual(Object.fromEntries(counts.map(x=>[x.name,x.n])),{ADMIN:57,EMPLOYEE:22,HR:56,MANAGER:29});
  const admin=(await db.query("SELECT id FROM tenant_fresh.role WHERE name='ADMIN'")).rows[0].id;
  await assertAdminAuthority(db,target,admin);
  await db.query("UPDATE tenant_fresh.permission_scope SET scope_type='TEAM' WHERE role_id=$1 AND resource='role' AND action='manage'",[admin]);
  await assert.rejects(assertAdminAuthority(db,target,admin),/ADMIN_POLICY_REQUIRES_EXPLICIT_OPERATOR_REVIEW/);
  await db.query(`UPDATE tenant_fresh.permission_scope SET scope_type='TEAM' WHERE resource='employee' AND action='read';
   DELETE FROM tenant_fresh.permission_scope WHERE resource='survey' AND action='respond';
   DELETE FROM tenant_fresh.role_permission p USING tenant_fresh.permission q WHERE q.id=p.permission_id AND q.resource='performance' AND q.action='self';
   DELETE FROM tenant_fresh.role_permission p USING tenant_fresh.permission q WHERE q.id=p.permission_id AND q.resource='tax' AND q.action='submit';
   DELETE FROM tenant_fresh.permission_scope WHERE resource='tax' AND action='submit';
   INSERT INTO tenant_fresh.permission VALUES(gen_random_uuid(),'loan','read');
   INSERT INTO tenant_fresh.role_permission SELECT r.id,p.id FROM tenant_fresh.role r CROSS JOIN tenant_fresh.permission p WHERE p.resource='loan';`);
  const snapshot=async()=>JSON.stringify((await db.query(`SELECT 'grant' AS kind,role_id::text AS role,permission_id::text AS value FROM tenant_fresh.role_permission UNION ALL SELECT 'scope',role_id::text,resource||':'||action||':'||scope_type FROM tenant_fresh.permission_scope ORDER BY 1,2,3`)).rows);
  const before=await snapshot();await db.query('BEGIN');assert.equal((await applyDefaults(db,target)).added,0);await db.query('COMMIT');
  assert.equal(await snapshot(),before,'custom and deliberately inactive decisions must remain byte-equivalent');
  assert.equal((await db.query("SELECT count(*)::int AS n FROM tenant_fresh.permission_scope WHERE resource='loan'")).rows[0].n,0);
 }finally{await db.end();f.stop();}
});

test('new admin input requires explicit intent and strong supplied hashes',()=>{
 const valid={intent:'CREATE_NEW_ADMIN',username:'new.admin',firstName:'New',lastName:'Admin',employeeCode:'ADM-001',dateOfJoining:'2026-11-13',passwordHash:'$argon2id$v=19$m=19456,t=2,p=1$abcdefghijklmnop$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG'};
 assert.equal(validateAdmins([valid]).length,1);
 for(const change of [{intent:'ASSIGN_ADMIN'},{passwordHash:'plaintext'},{passwordHash:valid.passwordHash.replace('19456','1024')},{employeeCode:''}])assert.throws(()=>validateAdmins([{...valid,...change}]));
 assert.throws(()=>validateAdmins([valid,valid]));
});
