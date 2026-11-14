// Disposable local PostgreSQL only; never reads an environment file or live DSN.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
function compile(mode,target,before){
 const code="import sys,json;sys.path.insert(0,sys.argv[1]);import online_columns as m;v=json.load(sys.stdin);print(m.snapshot_sql(v['target']) if sys.argv[2]=='snapshot' else m.guarded_sql(v['target'],v['before']))";
 const python=process.env.RUNTIME_GRANTS_PYTHON||'py';
 const args=process.platform==='win32'&&path.basename(python).toLowerCase().replace(/\.exe$/,'')==='py'?['-3']:[];
 return spawnSync(python,[...args,'-c',code,directory,mode],{input:JSON.stringify({target,before}),encoding:'utf8',windowsHide:true});
}
test('online column correction covers actual RBAC, guidance upsert and review reads without broader rights',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres','CREATE DATABASE company_fixture; CREATE ROLE hrms_company_employee LOGIN NOINHERIT; CREATE ROLE hrms_company_performance LOGIN NOINHERIT;');
 pg.query('company_fixture',`CREATE SCHEMA tenant_fixture; REVOKE ALL ON SCHEMA public FROM PUBLIC;
 GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_employee,hrms_company_performance;
 CREATE TABLE tenant_fixture.actor_ref(tenant_id uuid,principal_id uuid,display_name text);
 CREATE TABLE tenant_fixture.permission(id uuid,resource text,action text,module_id uuid,description text,created_at timestamptz,updated_at timestamptz);
 CREATE TABLE tenant_fixture.role_permission(role_id uuid,permission_id uuid,created_at timestamptz,PRIMARY KEY(role_id,permission_id));
 CREATE TABLE tenant_fixture.permission_scope(id uuid PRIMARY KEY,tenant_id uuid,role_id uuid,resource text,action text,scope_type text,created_at timestamptz);
 CREATE TABLE tenant_fixture.user_role(user_id uuid,role_id uuid,assigned_at timestamptz,PRIMARY KEY(user_id,role_id));
 CREATE TABLE tenant_fixture.user_guidance_state(id uuid PRIMARY KEY,tenant_id uuid,user_id uuid,overview_dismissed_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),UNIQUE(tenant_id,user_id));
 CREATE TABLE tenant_fixture.review_cycle(current_stage text,operator_only text);
 CREATE TABLE tenant_fixture.private_delivery_receipt(tenant_id uuid,intent_id uuid,destination_id uuid,
 intent_hash text,destination_version bigint,source_generation bigint,broker_owned_at timestamptz,
 broker_owner_id uuid,broker_receipt_sha256 text,updated_at timestamptz);
 CREATE TABLE tenant_fixture.unrelated(secret text);
 GRANT SELECT(id,resource,action) ON tenant_fixture.permission TO hrms_company_employee;`);
 const target={systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture'};
 function snapshot(){const r=compile('snapshot',target);assert.equal(r.status,0,r.stderr);return JSON.parse(pg.query('company_fixture',r.stdout));}
 const before=snapshot();
 for(const [role,sql]of[
  ['hrms_company_employee','SELECT * FROM tenant_fixture.permission LIMIT 0'],
  ['hrms_company_employee','SELECT overview_dismissed_at FROM tenant_fixture.user_guidance_state LIMIT 0'],
  ['hrms_company_performance','SELECT current_stage FROM tenant_fixture.review_cycle LIMIT 0']])
  assert.notEqual(pg.psql('company_fixture',{role,sql}).status,0,'reproduce denied real projection');
 const result=compile('apply',target,before);assert.equal(result.status,0,result.stderr);
 assert.equal(pg.psql('company_fixture',{sql:result.stdout}).status,0);
 const after=snapshot();assert.equal(after.invariantsSha256,before.invariantsSha256);assert(after.required.every(Boolean));
 for(const table of['permission','role_permission','permission_scope'])
  assert.equal(pg.psql('company_fixture',{role:'hrms_company_employee',sql:`SELECT * FROM tenant_fixture.${table} LIMIT 0`}).status,0);
 const row="('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000003')";
 const upsert=`INSERT INTO tenant_fixture.user_guidance_state(id,tenant_id,user_id) VALUES ${row} ON CONFLICT(tenant_id,user_id) DO NOTHING RETURNING id;`;
 for(let i=0;i<2;i++)assert.equal(pg.psql('company_fixture',{role:'hrms_company_employee',sql:upsert}).status,0,'idempotent real guidance SQL');
 assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.user_guidance_state').trim(),'1');
 const id="'00000000-0000-4000-8000-000000000001'";
 const replace=`BEGIN;
 DELETE FROM tenant_fixture.role_permission WHERE role_id=${id};
 INSERT INTO tenant_fixture.role_permission(role_id,permission_id,created_at) VALUES(${id},${id},now()) RETURNING *;
 DELETE FROM tenant_fixture.permission_scope WHERE role_id=${id};
 INSERT INTO tenant_fixture.permission_scope(id,tenant_id,role_id,resource,action,scope_type,created_at) VALUES(${id},${id},${id},'employee','read','ALL',now()) RETURNING *;
 DELETE FROM tenant_fixture.user_role WHERE user_id=${id};
 INSERT INTO tenant_fixture.user_role(user_id,role_id,assigned_at) VALUES(${id},${id},now()) RETURNING *;
 ROLLBACK;`;
 assert.equal(pg.psql('company_fixture',{role:'hrms_company_employee',sql:replace}).status,0,'real relationship replacement writes');
 assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.role_permission').trim(),'0','test transaction rolled back');
 for(const sql of['SELECT created_at FROM tenant_fixture.user_guidance_state','UPDATE tenant_fixture.user_guidance_state SET overview_dismissed_at=now()','DELETE FROM tenant_fixture.user_guidance_state','SELECT * FROM tenant_fixture.unrelated'])
  assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_employee',sql}).status,0,sql);
 assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_performance',sql:'SELECT operator_only FROM tenant_fixture.review_cycle'}).status,0);
 for(const sql of['DELETE FROM tenant_fixture.permission','UPDATE tenant_fixture.role_permission SET created_at=now()'])assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_employee',sql}).status,0,sql);
 const retry=compile('apply',target,after);assert.equal(retry.status,0,retry.stderr);assert.equal(pg.psql('company_fixture',{sql:retry.stdout}).status,0);
 pg.query('company_fixture','REVOKE SELECT(description) ON tenant_fixture.permission FROM hrms_company_employee');
 const baseline=snapshot(),guarded=compile('apply',target,baseline);assert.equal(guarded.status,0,guarded.stderr);
 pg.query('company_fixture','ALTER TABLE tenant_fixture.permission ADD COLUMN changed text');
 assert.notEqual(pg.psql('company_fixture',{sql:guarded.stdout}).status,0,'catalog drift refuses transaction');
 assert.equal(pg.query('company_fixture',"SELECT has_column_privilege('hrms_company_employee','tenant_fixture.permission','description','SELECT')").trim(),'f');
 const bad=compile('apply',{...target,systemId:'999'},snapshot());assert.notEqual(bad.status,0,'wrong cluster refuses SQL');
 pg.query('company_fixture','CREATE ROLE unrelated_member; GRANT hrms_company_employee TO unrelated_member');
 assert.equal(snapshot().restrictedRoles,false,'incoming membership must not share newly granted access');
 assert.notEqual(compile('apply',target,snapshot()).status,0,'incoming membership blocks preparation');
});
