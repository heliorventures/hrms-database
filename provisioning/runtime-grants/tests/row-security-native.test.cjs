// Owned local PostgreSQL16: canonical RLS definitions, exact grants and row isolation.
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
test('reviewed canonical row policies remain enforced after exact runtime grants',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const migration=path.resolve(__dirname,'../../../changelog/migrations/0120_organization_capture_lifecycle/organization_capture_lifecycle.xml');
 const bytes=fs.readFileSync(migration),policies=bytes.toString().match(/CREATE POLICY[\s\S]*?;/g);assert.equal(policies.length,3);
 const names=['organization_projection_worker','organization_history_worker','organization_reporting_worker','organization_projection_reader'];
 pg.query('postgres',names.map(n=>`CREATE ROLE ${n} LOGIN NOINHERIT;`).join('')+'REVOKE ALL ON DATABASE postgres,template1 FROM PUBLIC;');
 pg.query('postgres','CREATE DATABASE metadata_fixture');
 pg.query('postgres','CREATE DATABASE outside_closed ALLOW_CONNECTIONS false');
 pg.query('postgres','REVOKE ALL ON DATABASE outside_closed FROM PUBLIC;GRANT CONNECT ON DATABASE outside_closed TO organization_history_worker;');
 const tables=['organization_consumer_identity','organization_consumer_checkpoint','organization_capture_barrier'];
 pg.query('metadata_fixture','CREATE SCHEMA kabipay_ops;REVOKE USAGE ON SCHEMA public FROM PUBLIC;REVOKE ALL ON DATABASE metadata_fixture FROM PUBLIC;ALTER DEFAULT PRIVILEGES FOR ROLE fixture_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;'+tables.map(n=>`CREATE TABLE kabipay_ops.${n}(consumer_role text,payload text);INSERT INTO kabipay_ops.${n} VALUES('inbox','one'),('history','two'),('reporting','three');ALTER TABLE kabipay_ops.${n} ENABLE ROW LEVEL SECURITY;`).join('')+policies.join(''));
 const program=`import json,sys,subprocess
sys.path.insert(0,sys.argv[1]);import catalog,policy
from maintenance_session import MaintenanceSession,PersistentPsql
d=json.load(sys.stdin)
factory=lambda db:[d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U','fixture_owner','-d',db,'-v','ON_ERROR_STOP=1']
def control(sql):
 r=subprocess.run(factory('postgres'),input=sql,text=True,capture_output=True,timeout=60);assert r.returncode==0,r.stderr;return r.stdout.strip()
p=dict(version=1,systemId=d['systemId'],database='metadata_fixture',allowedDatabases=['metadata_fixture'],schema='kabipay_ops',creators=['fixture_owner'],roles={},blockers=[])
for role in d['roles']:
 tables={name:dict(select=['consumer_role','payload'],**({}if role.endswith('reader')else dict(insert=['consumer_role','payload'])))for name in d['tables']if not(role.endswith('reader')and name=='organization_consumer_identity')}
 p['roles'][role]=dict(tables=tables,sequences=[],functions=[])
with MaintenanceSession(p,control,lambda:None,session_factory=lambda db:PersistentPsql(db,command_factory=factory,timeout=90))as session:
 before=json.loads(session.query(catalog.snapshot_sql(p)))
 p['rowSecurity']={r['name']:dict(force=r['forceRowSecurity'],policies=r['rowSecurityPolicies'])for r in before['relations']if r['schema']=='kabipay_ops'}
 policy.validate_policy(p)
 try:policy.check_snapshot(p,before);raise AssertionError('closed database CONNECT was not inspected')
 except ValueError as e:assert str(e)=='CONNECT_OUTSIDE_APPROVED_DATABASES'
 control('REVOKE CONNECT ON DATABASE outside_closed FROM organization_history_worker;')
 before=json.loads(session.query(catalog.snapshot_sql(p)));policy.check_snapshot(p,before)
 session.query(catalog.guarded_sql(p,before));after=json.loads(session.query(catalog.snapshot_sql(p)));policy.check_snapshot(p,after,complete=True)
 # Altered expressions and FORCE flags fail the same production validation.
 session.query('ALTER POLICY organization_identity_role ON kabipay_ops.organization_consumer_identity USING(true);')
 try:policy.check_snapshot(p,json.loads(session.query(catalog.snapshot_sql(p))));raise AssertionError('changed RLS policy accepted')
 except ValueError as e:assert str(e)=='ROW_SECURITY_POLICY_CHANGED'
 session.query('DROP POLICY organization_identity_role ON kabipay_ops.organization_consumer_identity;'+d['identityPolicy'])
 session.query('ALTER TABLE kabipay_ops.organization_consumer_identity FORCE ROW LEVEL SECURITY;')
 try:policy.check_snapshot(p,json.loads(session.query(catalog.snapshot_sql(p))));raise AssertionError('changed FORCE flag accepted')
 except ValueError as e:assert str(e)=='ROW_SECURITY_POLICY_CHANGED'
 session.query('ALTER TABLE kabipay_ops.organization_consumer_identity NO FORCE ROW LEVEL SECURITY;')
 policy.check_snapshot(p,json.loads(session.query(catalog.snapshot_sql(p))),complete=True)
 print(json.dumps(dict(status='canonical_rls_grants_verified',rowSecurity=p['rowSecurity'],canonicalMigrationSha256=d['migrationSha256'])))`;
 const result=spawnSync('py',['-3.13','-c',program,path.resolve(__dirname,'..')],{input:JSON.stringify({psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql.exe'),port:pg.connection('postgres').port,systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),roles:names,tables,identityPolicy:policies.find(s=>s.startsWith('CREATE POLICY organization_identity_role')),migrationSha256:crypto.createHash('sha256').update(bytes).digest('hex')}),encoding:'utf8',windowsHide:true,timeout:240000});
 assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout);
 pg.query('postgres','ALTER DATABASE metadata_fixture ALLOW_CONNECTIONS true');
 for(const [role,wanted]of [['organization_projection_worker','one'],['organization_history_worker','two'],['organization_reporting_worker','three']]){
  const r=pg.psql('metadata_fixture',{role,sql:'SELECT payload FROM kabipay_ops.organization_consumer_identity'});assert.equal(r.status,0,r.stderr);assert.equal(r.stdout.trim(),wanted);
 }
 assert.equal(pg.psql('metadata_fixture',{role:'organization_projection_reader',sql:'SELECT count(*)FROM kabipay_ops.organization_consumer_checkpoint'}).stdout.trim(),'3');
 const forbidden=pg.psql('metadata_fixture',{role:'organization_history_worker',sql:"INSERT INTO kabipay_ops.organization_consumer_identity VALUES('inbox','denied')"});assert.notEqual(forbidden.status,0);assert.match(forbidden.stderr,/row.level security/);
 const readerWrite=pg.psql('metadata_fixture',{role:'organization_projection_reader',sql:"INSERT INTO kabipay_ops.organization_consumer_checkpoint VALUES('history','denied')"});assert.notEqual(readerWrite.status,0);
 pg.query('postgres','ALTER DATABASE metadata_fixture ALLOW_CONNECTIONS false');
 if(process.env.METADATA_RLS_REFERENCE_OUTPUT){const out=process.env.METADATA_RLS_REFERENCE_OUTPUT;assert(path.isAbsolute(out));fs.writeFileSync(out,JSON.stringify({...receipt,rowIsolationVerified:true,readerWriteDenied:true},null,2)+'\n',{flag:'wx'});}
 console.log('Canonical row policies and restricted grants verified; cross-consumer inserts and reader writes denied.');
});
