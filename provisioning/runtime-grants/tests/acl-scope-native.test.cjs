// Owned PostgreSQL16 only; no live DSN, .env, application data or credentials.
const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
test('explicit retained-schema ACL corrections preserve owners, rows and unselected schemas',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres','CREATE ROLE runtime_metadata LOGIN NOINHERIT; CREATE ROLE unrelated NOLOGIN; CREATE DATABASE metadata_fixture');
 const schemas=['metadata_scope','retained_a','retained_b','unselected'];
 pg.query('metadata_fixture',schemas.map(s=>`CREATE SCHEMA ${s};CREATE FUNCTION ${s}.helper(i integer) RETURNS integer LANGUAGE SQL AS 'SELECT $1';CREATE TABLE ${s}.example(id integer);INSERT INTO ${s}.example VALUES(1);`).join('\n')+'GRANT EXECUTE ON FUNCTION retained_a.helper(integer) TO unrelated;');
 const target={version:1,systemId:pg.query('metadata_fixture','SELECT system_identifier FROM pg_control_system()').trim(),database:'metadata_fixture',schema:'metadata_scope',allowedDatabases:['metadata_fixture'],roles:['runtime_metadata'],aclSchemas:['public','metadata_scope','retained_a','retained_b']};
 const program=`import sys,json,subprocess;sys.path.insert(0,sys.argv[1]);import acl_catalog,acl_corrections as c
from maintenance_session import MaintenanceSession,PersistentPsql
d=json.load(sys.stdin)
factory=lambda db:[d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U','fixture_owner','-d',db,'-v','ON_ERROR_STOP=1']
def control(sql):
 r=subprocess.run(factory('postgres'),input=sql,text=True,capture_output=True,timeout=30);assert r.returncode==0,r.stderr;return r.stdout.strip()
with MaintenanceSession(acl_catalog.query_policy(d['target']),control,lambda:None,session_factory=lambda db:PersistentPsql(db,command_factory=factory,timeout=90))as session:
 before=json.loads(session.query(acl_catalog.snapshot_sql(d['target'])+';'));acl_catalog.validate_snapshot(d['target'],before)
 assert {f['schema']for f in before['functions']}=={'metadata_scope','retained_a','retained_b'}
 operations=[dict(kind='function_public_execute',oid=f['oid'])for f in before['functions']]
 plan=c.prepare(d['target'],before,operations);session.query(c.guarded_sql(plan))
 after=json.loads(session.query(acl_catalog.snapshot_sql(d['target'])+';'));assert c.equivalent(c.expected_after(plan),after)
 assert after['catalogInvariantSha256']==before['catalogInvariantSha256']
 assert after['authorities']==before['authorities']
 print(json.dumps(dict(status='explicit_schema_scope_verified',functions=len(after['functions']))))`;
 const connection=pg.connection('postgres');
 const result=spawnSync('py',['-3','-c',program,directory],{input:JSON.stringify({target,port:connection.port,psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql.exe')}),encoding:'utf8',windowsHide:true,timeout:120000});
 assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).functions,3);
 assert.equal(pg.query('postgres',"SELECT datallowconn FROM pg_database WHERE datname='metadata_fixture'").trim(),'f');
 pg.query('postgres','ALTER DATABASE metadata_fixture ALLOW_CONNECTIONS true');
 for(const schema of schemas)assert.equal(pg.query('metadata_fixture',`SELECT count(*) FROM ${schema}.example`).trim(),'1');
 assert.equal(pg.query('metadata_fixture',"SELECT has_function_privilege('runtime_metadata','retained_a.helper(integer)','EXECUTE')").trim(),'f');
 assert.equal(pg.query('metadata_fixture',"SELECT has_function_privilege('unrelated','retained_a.helper(integer)','EXECUTE')").trim(),'t');
 assert.equal(pg.query('metadata_fixture',"SELECT has_function_privilege('runtime_metadata','unselected.helper(integer)','EXECUTE')").trim(),'t');
 assert.equal(pg.query('metadata_fixture','SELECT retained_a.helper(7)').trim(),'7');
 pg.query('postgres','ALTER DATABASE metadata_fixture ALLOW_CONNECTIONS false');
});
