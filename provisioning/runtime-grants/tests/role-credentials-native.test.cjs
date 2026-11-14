// Owned loopback PostgreSQL16 fixture. No existing credentials or .env reads.
const {test}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
test('restricted role creation is atomic and generated SCRAM passwords authenticate',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const connection=pg.connection('postgres');
 const program=`import sys,json,subprocess,os
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import role_credentials as roles
d=json.load(sys.stdin)
def run(sql,user='fixture_owner',password=None):
 env=os.environ.copy()
 if password is not None:env['PGPASSWORD']=password
 return subprocess.run([d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U',user,'-d','postgres','-v','ON_ERROR_STOP=1'],input=sql,text=True,capture_output=True,timeout=30,env=env)
def query(sql):
 result=run(sql);assert result.returncode==0,'fixture database query failed';return result.stdout.strip()
before=json.loads(query(roles.SNAPSHOT_SQL+';'));bundle=roles.new_bundle(['metadata_first','metadata_second']);sql=roles.create_sql(before,bundle)
failed=run(sql.replace('COMMIT;',"DO $fail$ BEGIN RAISE EXCEPTION 'injected'; END $fail$;COMMIT;"));assert failed.returncode!=0
assert json.loads(query(roles.SNAPSHOT_SQL+';'))==before,'failed creation did not roll back'
query(sql);assert json.loads(query(roles.SNAPSHOT_SQL+';'))==roles.expected_after(before,bundle)
query(roles.credential_guard(bundle))
try:roles.create_sql(json.loads(query(roles.SNAPSHOT_SQL+';')),bundle);raise AssertionError('password reset accepted')
except ValueError as error:assert str(error)=='ROLE_ALREADY_EXISTS_NO_PASSWORD_RESET'
hba=Path(d['directory'])/'data'/'pg_hba.conf';previous=hba.read_text();hba.write_text('host all metadata_first 127.0.0.1/32 scram-sha-256\\n'+previous)
query('SELECT pg_reload_conf();')
good=run('SELECT current_user;',user='metadata_first',password=bundle['metadata_first']['password']);assert good.returncode==0 and good.stdout.strip()=='metadata_first','SCRAM login failed'
bad=run('SELECT current_user;',user='metadata_first',password='deliberately-wrong-synthetic-password');assert bad.returncode!=0,'wrong password authenticated'
assert query("SELECT count(*)FROM pg_shdepend WHERE refclassid='pg_authid'::regclass AND refobjid IN(SELECT oid FROM pg_roles WHERE rolname IN('metadata_first','metadata_second'))AND deptype='o'")=='0'
print(json.dumps(dict(status='restricted_credentials_verified',roles=2,rollback=True,scramAuthentication=True,wrongPasswordRejected=True,passwordResetRefused=True)))`;
 const result=spawnSync('py',['-3','-c',program,path.resolve(__dirname,'..')],{input:JSON.stringify({port:connection.port,psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql.exe'),directory:pg.directory}),encoding:'utf8',windowsHide:true,timeout:90000});
 assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).scramAuthentication,true);
});
