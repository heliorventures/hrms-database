// Only an owned disposable PostgreSQL16 cluster; no live DSNs or .env reads.
const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');

test('exact PUBLIC ACL reductions preserve unrelated rights and extension index operations',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres','CREATE ROLE runtime_employee LOGIN NOINHERIT; CREATE ROLE unrelated NOLOGIN; CREATE DATABASE company_fixture');
 pg.query('company_fixture',`CREATE SCHEMA tenant_fixture; CREATE EXTENSION btree_gist WITH SCHEMA public;
 CREATE FUNCTION tenant_fixture.helper(p integer) RETURNS integer LANGUAGE SQL AS 'SELECT $1';
 CREATE FUNCTION tenant_fixture.helper(p text) RETURNS text LANGUAGE SQL AS 'SELECT $1';
 CREATE FUNCTION tenant_fixture.mark_inserted() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN NEW.stamped := true; RETURN NEW; END';
 GRANT EXECUTE ON FUNCTION tenant_fixture.helper(integer) TO runtime_employee WITH GRANT OPTION;
 GRANT EXECUTE ON FUNCTION tenant_fixture.helper(text) TO unrelated;
 CREATE TABLE tenant_fixture.example(id integer DEFAULT tenant_fixture.helper(1), stamped boolean DEFAULT false, EXCLUDE USING gist(id WITH =));
 CREATE TRIGGER mark_inserted BEFORE INSERT ON tenant_fixture.example FOR EACH ROW EXECUTE FUNCTION tenant_fixture.mark_inserted();
 ALTER DEFAULT PRIVILEGES IN SCHEMA tenant_fixture GRANT EXECUTE ON FUNCTIONS TO PUBLIC,unrelated;
 GRANT USAGE ON SCHEMA tenant_fixture TO runtime_employee;
 GRANT INSERT(id) ON tenant_fixture.example TO runtime_employee;`);
 const target={version:1,systemId:pg.query('company_fixture','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture',allowedDatabases:['company_fixture'],roles:['runtime_employee']};
 const program=`import sys,json,subprocess;sys.path.insert(0,sys.argv[1]);import acl_catalog,acl_corrections as c
from maintenance_session import MaintenanceSession,PersistentPsql
d=json.load(sys.stdin)
factory=lambda db:[d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U','fixture_owner','-d',db,'-v','ON_ERROR_STOP=1']
def control(sql):
 r=subprocess.run(factory('postgres'),input=sql,text=True,capture_output=True,timeout=30);assert r.returncode==0,r.stderr;return r.stdout.strip()
with MaintenanceSession(dict(d['target'],roles={r:{} for r in d['target']['roles']}),control,lambda:None,session_factory=lambda db:PersistentPsql(db,command_factory=factory,timeout=90)) as session:
 before=json.loads(session.query(acl_catalog.snapshot_sql(d['target'])+';'))
 if d['action']=='capture':print(json.dumps(before))
 else:
  plan=d['plan'];sql=c.guarded_sql(plan)
  if d['action']=='post_failure':
   guard=c._guard(d['target'],c.expected_after(plan),'ACL_CORRECTION_POSTCONDITION_FAILED');sql=sql.replace(guard,'GRANT SELECT ON tenant_fixture.example TO unrelated;'+guard)
  if d['action'] in ('refuse','post_failure'):
   try:session.query(sql)
   except ValueError:print(json.dumps({'refused':True}))
   else:raise AssertionError('invalid plan unexpectedly committed')
  else:
   session.query(sql);after=json.loads(session.query(acl_catalog.snapshot_sql(d['target'])+';'));assert c.equivalent(c.expected_after(plan),after);print(json.dumps(after))`;
 function run(action,plan){
  const result=spawnSync('py',['-3','-c',program,directory],{input:JSON.stringify({action,plan,target,port:pg.connection('postgres').port,psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql.exe')}),encoding:'utf8',windowsHide:true,timeout:120000});
  assert.equal(result.status,0,result.stderr);return JSON.parse(result.stdout);
 }
 const before=run('capture');
 const operations=before.functions.filter(f=>f.acl.some(a=>a.grantee==='PUBLIC'&&a.privilege==='EXECUTE')).map(f=>({kind:'function_public_execute',oid:f.oid}));
 operations.push({kind:'schema_public_usage',name:'public'},{kind:'function_public_default',owner:'fixture_owner',schema:null});
 operations.push({kind:'function_public_default',owner:'fixture_owner',schema:'tenant_fixture'});
 const plan={version:1,purpose:'reviewed_public_acl_reductions',target,baseline:before,operations};
 // A stale definition, extension identity or dependency must refuse before DDL.
 for(const mutate of [p=>p.baseline.functions[0].definitionSha256='a'.repeat(64),p=>p.baseline.functions[0].extension.version='999',p=>p.baseline.functions[0].dependents.push({type:'n',description:'changed'})]){
  const wrong=structuredClone(plan);mutate(wrong);
  assert.equal(run('refuse',wrong).refused,true);
 }
 // An unexpected post-DDL ACL change rolls the entire correction back.
 assert.equal(run('post_failure',plan).refused,true);
 const stillBefore=run('capture');assert.deepEqual(stillBefore,before,'all revokes and injected grant rolled back');
 const after=run('apply',plan);
 assert(after.functions.every(f=>!f.acl.some(a=>a.grantee==='PUBLIC')));
 assert.equal(after.functions.filter(f=>f.extension?.name==='btree_gist').length,188);
 const numeric=after.functions.find(f=>f.name==='helper'&&f.identityArguments==='p integer');
 assert(numeric.acl.some(a=>a.grantee==='runtime_employee'&&a.grantOption));
 assert(after.functions.find(f=>f.name==='helper'&&f.identityArguments==='p text').acl.some(a=>a.grantee==='unrelated'));
 assert.equal(after.authorities.untouchedAclSha256,before.authorities.untouchedAclSha256);
 // Controlled fixture admission for behavioral verification only, then reclose.
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
 const insert=pg.psql('company_fixture',{role:'runtime_employee',sql:'INSERT INTO tenant_fixture.example DEFAULT VALUES; INSERT INTO tenant_fixture.example(id) VALUES(2);'});
 assert.equal(insert.status,0,insert.stderr);
 assert.equal(pg.query('company_fixture','SELECT bool_and(stamped) FROM tenant_fixture.example').trim(),'t','trigger entry still fires without runtime EXECUTE; separately granted nested default helper remains callable');
 const conflict=pg.psql('company_fixture',{role:'runtime_employee',sql:'INSERT INTO tenant_fixture.example(id) VALUES(2)'});
 assert.notEqual(conflict.status,0);assert.match(conflict.stderr,/exclusion constraint/);
 assert.equal(pg.psql('company_fixture',{role:'runtime_employee',sql:'SELECT tenant_fixture.helper(3)'}).stdout.trim(),'3');
 pg.query('company_fixture',"CREATE FUNCTION tenant_fixture.future() RETURNS integer LANGUAGE SQL AS 'SELECT 1'");
 assert.equal(pg.query('company_fixture',"SELECT has_function_privilege('runtime_employee','tenant_fixture.future()','EXECUTE')").trim(),'f');
 assert.equal(pg.query('company_fixture',"SELECT has_function_privilege('unrelated','tenant_fixture.future()','EXECUTE')").trim(),'t','unrelated per-schema default grant preserved');
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS false');
 assert.equal(pg.query('postgres',"SELECT datallowconn FROM pg_database WHERE datname='company_fixture'").trim(),'f');
});
