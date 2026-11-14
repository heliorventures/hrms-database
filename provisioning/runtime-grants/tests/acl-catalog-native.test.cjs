// Catalog metadata only on an owned disposable PostgreSQL16 fixture.
const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
test('ACL inventory captures origins, overloads, defaults and extension dependencies',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres','CREATE ROLE runtime_employee LOGIN NOINHERIT; CREATE ROLE unrelated NOLOGIN; CREATE DATABASE company_fixture');
 pg.query('company_fixture',`CREATE SCHEMA tenant_fixture;
 CREATE EXTENSION pgcrypto WITH SCHEMA tenant_fixture;
 CREATE FUNCTION tenant_fixture.helper(integer) RETURNS integer LANGUAGE SQL AS 'SELECT $1';
 CREATE FUNCTION tenant_fixture.helper(text) RETURNS text LANGUAGE SQL AS 'SELECT $1';
 GRANT EXECUTE ON FUNCTION tenant_fixture.helper(integer) TO runtime_employee WITH GRANT OPTION;
 GRANT EXECUTE ON FUNCTION tenant_fixture.helper(text) TO unrelated;
 CREATE TABLE tenant_fixture.example(id integer DEFAULT tenant_fixture.helper(1));`);
 const target={version:1,systemId:pg.query('company_fixture','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture',allowedDatabases:['company_fixture'],roles:['runtime_employee']};
 const connection=pg.connection('postgres');
 const program=`import sys,json,subprocess;sys.path.insert(0,sys.argv[1]);import acl_catalog;from maintenance_session import MaintenanceSession,PersistentPsql
 d=json.load(sys.stdin)
 `.replace(/\n /g,'\n')+`factory=lambda db:[d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U','fixture_owner','-d',db,'-v','ON_ERROR_STOP=1']
def control(sql):
 r=subprocess.run(factory('postgres'),input=sql,text=True,capture_output=True,timeout=30);assert r.returncode==0,r.stderr;return r.stdout.strip()
with MaintenanceSession(dict(d['target'],roles={r:{} for r in d['target']['roles']}),control,lambda:None,session_factory=lambda db:PersistentPsql(db,command_factory=factory,timeout=60)) as session:
 state=json.loads(session.query(acl_catalog.snapshot_sql(d['target'])+';'));acl_catalog.validate_snapshot(d['target'],state);print(json.dumps(state))`;
 function capture(){
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
 const result=spawnSync('py',['-3','-c',program,directory],{input:JSON.stringify({target,port:connection.port,psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql.exe')}),encoding:'utf8',windowsHide:true,timeout:90000});
 assert.equal(result.status,0,result.stderr);
 return JSON.parse(result.stdout);
 }
 const state=capture();
 assert.equal(state.admissionBarrier.allowConnections,false);
 assert.equal(pg.query('postgres',"SELECT datallowconn FROM pg_database WHERE datname='company_fixture'").trim(),'f');
 const overloads=state.functions.filter(f=>f.name==='helper');assert.equal(overloads.length,2);
 const numeric=overloads.find(f=>f.identityArguments==='integer');assert(numeric.acl.some(a=>a.grantee==='runtime_employee'&&a.privilege==='EXECUTE'&&a.grantOption));
 const string=overloads.find(f=>f.identityArguments==='text');assert(string.acl.some(a=>a.grantee==='unrelated'&&a.grantor==='fixture_owner'));
 assert(numeric.dependents.some(d=>d.description.includes('default value for column id')));
 const crypto=state.functions.filter(f=>f.extension&&f.extension.name==='pgcrypto');assert(crypto.length>0);assert(crypto.every(f=>/^[0-9a-f]{64}$/.test(f.definitionSha256)));
 assert(crypto.some(f=>f.acl.some(a=>a.grantee==='PUBLIC'&&a.privilege==='EXECUTE')));
 const defaults=state.creatorDefaults.find(d=>d.owner==='fixture_owner'&&d.schema==='tenant_fixture');assert.equal(defaults.globalExplicit,false);assert(defaults.globalAcl.some(a=>a.grantee==='PUBLIC'&&a.privilege==='EXECUTE'));
 assert(/^[0-9a-f]{64}$/.test(state.authorities.untouchedAclSha256));assert(/^[0-9a-f]{64}$/.test(state.catalogInvariantSha256));
 assert(!JSON.stringify(state).includes('SELECT $1'),'SQL function bodies are never returned');
 assert.equal(state.connections,0);
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
 pg.query('company_fixture','REVOKE EXECUTE ON FUNCTION tenant_fixture.helper(integer) FROM PUBLIC; ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC');
 const corrected=capture();
 assert.equal(corrected.catalogInvariantSha256,state.catalogInvariantSha256,'selected ACL changes preserve immutable catalog fingerprint');
 assert.equal(corrected.authorities.untouchedAclSha256,state.authorities.untouchedAclSha256,'selected ACL changes preserve all other ACLs');
 assert(!corrected.functions.find(f=>f.name==='helper'&&f.identityArguments==='integer').acl.some(a=>a.grantee==='PUBLIC'));
 const afterDefaults=corrected.creatorDefaults.find(d=>d.owner==='fixture_owner'&&d.schema==='tenant_fixture');assert.equal(afterDefaults.globalExplicit,true);assert(!afterDefaults.globalAcl.some(a=>a.grantee==='PUBLIC'));
 assert(corrected.functions.find(f=>f.name==='helper'&&f.identityArguments==='integer').acl.some(a=>a.grantee==='runtime_employee'&&a.grantOption));
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
 pg.query('company_fixture','GRANT SELECT ON tenant_fixture.example TO unrelated');
 const unrelatedDrift=capture();assert.notEqual(unrelatedDrift.authorities.untouchedAclSha256,corrected.authorities.untouchedAclSha256,'unrelated grantee/table ACL changes must be visible');
 pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
 pg.query('company_fixture',"CREATE OR REPLACE FUNCTION tenant_fixture.helper(integer) RETURNS integer LANGUAGE SQL AS 'SELECT $1+1'");
 const definitionDrift=capture();assert.notEqual(definitionDrift.catalogInvariantSha256,unrelatedDrift.catalogInvariantSha256,'routine definition drift must be visible');
});
