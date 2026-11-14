// Explicitly owned disposable loopback cluster. Never loads .env or live DSNs.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
function compile(mode,policy,snapshot){
 const program="import sys,json; sys.path.insert(0,sys.argv[1]); import policy,catalog; data=json.load(sys.stdin); p=data['policy']; mode=sys.argv[2]; result=catalog.snapshot_sql(p) if mode=='snapshot' else catalog.guarded_sql(p,data['snapshot']) if mode=='apply' else policy.owner_authority_digest(data['snapshot'],'definer_owner') if mode=='owner' else policy.check_snapshot(p,data['snapshot'],complete=mode=='verify'); print(result if isinstance(result,str) else json.dumps(result))";
 const python=process.env.RUNTIME_GRANTS_PYTHON||'py';
 const args=process.platform==='win32'&&path.basename(python).toLowerCase().replace(/\.exe$/,'')==='py'?['-3']:[];
 return spawnSync(python,[...args,'-c',program,directory,mode],{input:JSON.stringify({policy,snapshot}),encoding:'utf8',windowsHide:true,timeout:60000});
}
test('exact runtime grants work and excess grants/drift roll back',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const fixtureConnection=pg.connection('postgres');
 pg.query('postgres',`REVOKE ALL ON DATABASE postgres FROM PUBLIC; REVOKE ALL ON DATABASE template1 FROM PUBLIC; CREATE ROLE runtime_employee LOGIN NOINHERIT; CREATE DATABASE company_fixture;`);
 pg.query('company_fixture',`REVOKE ALL ON DATABASE company_fixture FROM PUBLIC; CREATE SCHEMA tenant_fixture; REVOKE ALL ON SCHEMA public FROM PUBLIC; ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC; CREATE TABLE tenant_fixture."user"(id integer,tenant_id integer,is_active boolean,is_deleted boolean,password_hash text); CREATE TABLE tenant_fixture.employee(id integer,name text); INSERT INTO tenant_fixture."user" VALUES(1,2,true,false,'synthetic-secret'); INSERT INTO tenant_fixture.employee VALUES(1,'Example'); CREATE SEQUENCE tenant_fixture.outbox_seq; CREATE TABLE public.other_product(secret text);`);
 const systemId=pg.query('company_fixture','SELECT system_identifier FROM pg_control_system()').trim();
 const policy={version:1,systemId,database:'company_fixture',allowedDatabases:['company_fixture'],schema:'tenant_fixture',creators:['fixture_owner'],roles:{runtime_employee:{tables:{user:{select:['id','tenant_id','is_active','is_deleted']},employee:{select:['id','name'],update:['name']}},sequences:['outbox_seq'],functions:[]}},blockers:[]};
 function held(sql,probe=false){
   // Exercise the actual persistent-session coordinator: only its separate
   // control connection can close admission to the held target database.
   pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');
   const program="import sys,json,subprocess,os; sys.path.insert(0,sys.argv[1]); from maintenance_session import MaintenanceSession,PersistentPsql; d=json.load(sys.stdin); p=d['policy']; factory=lambda db:[d['psql'],'-X','-qAt','-w','-h','127.0.0.1','-p',str(d['port']),'-U','fixture_owner','-d',db,'-v','ON_ERROR_STOP=1'];\ndef control(sql):\n r=subprocess.run(factory('postgres'),input=sql,text=True,capture_output=True,timeout=30); assert r.returncode==0,r.stderr; return r.stdout.strip()\nwith MaintenanceSession(p,control,lambda:None,session_factory=lambda db:PersistentPsql(db,command_factory=factory,timeout=30)) as session:\n if d.get('probe'):\n  for role in ['fixture_owner','runtime_employee']:\n   args=factory(p['database']); args[args.index('-U')+1]=role; attempt=subprocess.run(args,input='SELECT 1',text=True,capture_output=True,timeout=30); assert attempt.returncode!=0 and 'not currently accepting connections' in attempt.stderr,'admission barrier did not reject '+role\n print(session.query(d['sql']))";
   const python=process.env.RUNTIME_GRANTS_PYTHON||'py';
   const args=process.platform==='win32'&&path.basename(python).toLowerCase().replace(/\.exe$/,'')==='py'?['-3']:[];
   const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^PG/i.test(key)));
   try{return spawnSync(python,[...args,'-c',program,directory],{input:JSON.stringify({policy,sql,probe,port:fixtureConnection.port,psql:path.join(process.env.PRIVATE_TEST_PG_BIN,'psql'+(process.platform==='win32'?'.exe':''))}),encoding:'utf8',windowsHide:true,timeout:60000,env});}
   finally{pg.query('postgres','ALTER DATABASE company_fixture ALLOW_CONNECTIONS true');}
 }
 function snapshot(){const query=compile('snapshot',policy);assert.equal(query.status,0,query.stderr);const result=held(query.stdout);assert.equal(result.status,0,result.stderr);return JSON.parse(result.stdout);}
 const before=snapshot();assert.equal(before.systemAccess.length,0,JSON.stringify(before.systemAccess).slice(0,6000));let result=compile('check',policy,before);assert.equal(result.status,0,result.stderr);
 await t.test('unsupported runtime object rights invalidate bounds and a reviewed baseline',()=>{
   pg.query('company_fixture',"BEGIN; SET LOCAL allow_system_table_mods=on; CREATE FOREIGN DATA WRAPPER unsupported_wrapper; CREATE SERVER unsupported_server FOREIGN DATA WRAPPER unsupported_wrapper; CREATE SEQUENCE pg_catalog.unsupported_seq; CREATE TYPE tenant_fixture.unsupported_type AS ENUM('VALUE'); COMMIT;");
   const largeObject=pg.query('company_fixture', "SELECT lo_from_bytea(0,decode('73796e746865746963','hex'))").trim();
   const cases=[
     ['system schema CREATE','GRANT CREATE ON SCHEMA pg_catalog TO runtime_employee','REVOKE CREATE ON SCHEMA pg_catalog FROM runtime_employee'],
     ['large object SELECT',`GRANT SELECT ON LARGE OBJECT ${largeObject} TO runtime_employee`,`REVOKE SELECT ON LARGE OBJECT ${largeObject} FROM runtime_employee`],
     ['system schema grant option','GRANT USAGE ON SCHEMA information_schema TO runtime_employee WITH GRANT OPTION','REVOKE USAGE ON SCHEMA information_schema FROM runtime_employee'],
     ['foreign wrapper USAGE','GRANT USAGE ON FOREIGN DATA WRAPPER unsupported_wrapper TO runtime_employee','REVOKE USAGE ON FOREIGN DATA WRAPPER unsupported_wrapper FROM runtime_employee'],
     ['foreign server USAGE','GRANT USAGE ON FOREIGN SERVER unsupported_server TO runtime_employee','REVOKE USAGE ON FOREIGN SERVER unsupported_server FROM runtime_employee'],
     ['tablespace CREATE','GRANT CREATE ON TABLESPACE pg_default TO runtime_employee','REVOKE CREATE ON TABLESPACE pg_default FROM runtime_employee'],
     ['system sequence USAGE','GRANT USAGE ON SEQUENCE pg_catalog.unsupported_seq TO runtime_employee','REVOKE USAGE ON SEQUENCE pg_catalog.unsupported_seq FROM runtime_employee'],
     ['language grant option','GRANT USAGE ON LANGUAGE plpgsql TO runtime_employee WITH GRANT OPTION','REVOKE USAGE ON LANGUAGE plpgsql FROM runtime_employee'],
     ['type grant option','GRANT USAGE ON TYPE tenant_fixture.unsupported_type TO runtime_employee WITH GRANT OPTION','REVOKE USAGE ON TYPE tenant_fixture.unsupported_type FROM runtime_employee'],
   ];
   const failures=[];
   pg.query('company_fixture','GRANT CONNECT ON DATABASE company_fixture TO runtime_employee');
   try {for(const [label,grant,revoke] of cases){
     const baseline=snapshot();const generated=compile('apply',policy,baseline);assert.equal(generated.status,0,generated.stderr);
     pg.query('company_fixture',grant);
     try {
       if(label==='large object SELECT') {const read=pg.psql('company_fixture',{role:'runtime_employee',sql:`SELECT encode(lo_get(${largeObject}),'hex')`});assert.equal(read.status,0,read.stderr);assert.equal(read.stdout.trim(),'73796e746865746963');}
       assert.notEqual(compile('check',policy,snapshot()).status,0,label+' must fail effective bounds');
       assert.notEqual(held(generated.stdout).status,0,label+' must invalidate earlier baseline');
     } catch(error) {failures.push(error.message);} finally {pg.query('company_fixture',revoke);}
   }} finally {pg.query('company_fixture',`SELECT lo_unlink(${largeObject}); REVOKE CONNECT ON DATABASE company_fixture FROM runtime_employee; DROP SERVER unsupported_server; DROP FOREIGN DATA WRAPPER unsupported_wrapper; DROP SEQUENCE pg_catalog.unsupported_seq; DROP TYPE tenant_fixture.unsupported_type`);}
   assert.deepEqual(failures,[]);
 });
 await t.test('held admission rejects new runtime and superuser clients',()=>{
   const result=held('SELECT current_database()',true);assert.equal(result.status,0,result.stderr);
 });
 await t.test('generated SQL enforces exact baseline and postcondition',()=>{
   const generated=compile('apply',policy,before);assert.equal(generated.status,0,generated.stderr);
   const applied=held(generated.stdout);assert.equal(applied.status,0,applied.stderr);
   result=compile('verify',policy,snapshot());assert.equal(result.status,0,result.stderr);
 });
 await t.test('status read and permitted update work; credentials and other products stay denied',()=>{
   const role='runtime_employee';
   assert.equal(pg.psql('company_fixture',{role,sql:'SELECT is_active,is_deleted FROM tenant_fixture."user" WHERE id=1 AND tenant_id=2; UPDATE tenant_fixture.employee SET name=\'Updated\' WHERE id=1; SELECT nextval(\'tenant_fixture.outbox_seq\');'}).status,0);
   for(const sql of ['SELECT password_hash FROM tenant_fixture."user"','SELECT * FROM tenant_fixture."user"','DELETE FROM tenant_fixture.employee','SELECT * FROM public.other_product','SELECT setval(\'tenant_fixture.outbox_seq\',1)','CREATE TABLE tenant_fixture.unauthorized(id integer)'])assert.notEqual(pg.psql('company_fixture',{role,sql}).status,0,sql);
   assert.notEqual(pg.psql('postgres',{role,sql:'SELECT 1'}).status,0);
 });
 await t.test('idempotent second application preserves the exact contract',()=>{
   const generated=compile('apply',policy,snapshot());assert.equal(generated.status,0,generated.stderr);
   const applied=held(generated.stdout);assert.equal(applied.status,0,applied.stderr);
 });
 await t.test('changed PUBLIC column privilege prevents any new grants',()=>{
   const baseline=snapshot();const generated=compile('apply',policy,baseline);assert.equal(generated.status,0,generated.stderr);
   pg.query('company_fixture','GRANT SELECT(password_hash) ON tenant_fixture."user" TO PUBLIC');
   assert.notEqual(held(generated.stdout).status,0);
   assert.notEqual(compile('check',policy,snapshot()).status,0);
   pg.query('company_fixture','REVOKE SELECT(password_hash) ON tenant_fixture."user" FROM PUBLIC');
 });
 await t.test('broad table SELECT and membership are rejected',()=>{
   pg.query('company_fixture','GRANT SELECT ON tenant_fixture.employee TO runtime_employee');
   assert.notEqual(compile('check',policy,snapshot()).status,0);
   pg.query('company_fixture','REVOKE SELECT ON tenant_fixture.employee FROM runtime_employee; CREATE ROLE unrelated; GRANT unrelated TO runtime_employee');
   assert.notEqual(compile('check',policy,snapshot()).status,0);
   pg.query('company_fixture','REVOKE unrelated FROM runtime_employee');
 });
 await t.test('unreviewed function execution and default grants are rejected',()=>{
   pg.query('company_fixture',"CREATE FUNCTION tenant_fixture.operator_only() RETURNS integer LANGUAGE SQL SECURITY DEFINER AS 'SELECT 1'; GRANT EXECUTE ON FUNCTION tenant_fixture.operator_only() TO PUBLIC;");
   assert.notEqual(compile('check',policy,snapshot()).status,0);
   pg.query('company_fixture','REVOKE ALL ON FUNCTION tenant_fixture.operator_only() FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA tenant_fixture GRANT SELECT ON TABLES TO runtime_employee');
   assert.notEqual(compile('check',policy,snapshot()).status,0);
   pg.query('company_fixture','ALTER DEFAULT PRIVILEGES IN SCHEMA tenant_fixture REVOKE SELECT ON TABLES FROM runtime_employee');
 });
 await t.test('implicit function PUBLIC default is rejected without a catalog override',()=>{
   pg.query('company_fixture','ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC');
   const state=snapshot();assert.equal(state.defaultAccess.length,0,'default returned to implicit ACL');
   assert.notEqual(compile('check',policy,state).status,0,'implicit PUBLIC EXECUTE must not be treated as safe');
   pg.query('company_fixture','ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC');
 });
 await t.test('sensitive system catalog and restricted builtin grants are rejected',()=>{
   pg.query('company_fixture','GRANT SELECT ON pg_catalog.pg_authid TO runtime_employee');
   assert.notEqual(compile('check',policy,snapshot()).status,0,'catalog password verifier access must be rejected');
   pg.query('company_fixture','REVOKE SELECT ON pg_catalog.pg_authid FROM runtime_employee; GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_file(text) TO runtime_employee');
   assert.notEqual(compile('check',policy,snapshot()).status,0,'restricted built-in execute must be rejected');
   pg.query('company_fixture','REVOKE EXECUTE ON FUNCTION pg_catalog.pg_read_file(text) FROM runtime_employee');
 });
 await t.test('reviewed function execution works and ownership or owner-authority drift fails',()=>{
   pg.query('company_fixture',"CREATE ROLE definer_owner NOLOGIN; GRANT USAGE,CREATE ON SCHEMA tenant_fixture TO definer_owner; ALTER DEFAULT PRIVILEGES FOR ROLE definer_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC; CREATE FUNCTION tenant_fixture.reviewed_function() RETURNS integer LANGUAGE SQL SECURITY DEFINER AS 'SELECT 1'; ALTER FUNCTION tenant_fixture.reviewed_function() OWNER TO definer_owner;");
   policy.creators.push('definer_owner');
   const initial=snapshot();const actual=initial.functions.find(f=>f.name==='reviewed_function');
   const authority=compile('owner',policy,initial);assert.equal(authority.status,0,authority.stderr);
   policy.roles.runtime_employee.functions.push({name:actual.name,identityArguments:actual.identityArguments,definitionSha256:actual.definitionSha256,owner:actual.owner,securityDefiner:actual.securityDefiner,ownerAuthoritySha256:authority.stdout.trim()});
   let generated=compile('apply',policy,initial);assert.equal(generated.status,0,generated.stderr);
   let applied=held(generated.stdout);assert.equal(applied.status,0,applied.stderr);
   assert.equal(pg.psql('company_fixture',{role:'runtime_employee',sql:'SELECT tenant_fixture.reviewed_function()'}).status,0);
   const reviewed=snapshot();generated=compile('apply',policy,reviewed);assert.equal(generated.status,0,generated.stderr);
   pg.query('company_fixture','ALTER FUNCTION tenant_fixture.reviewed_function() OWNER TO fixture_owner');
   assert.notEqual(held(generated.stdout).status,0,'function owner drift must reject a reviewed transaction');
   assert.notEqual(compile('check',policy,snapshot()).status,0,'function owner must match explicit contract');
   pg.query('company_fixture','ALTER FUNCTION tenant_fixture.reviewed_function() OWNER TO definer_owner; ALTER ROLE definer_owner CREATEDB');
   assert.notEqual(compile('check',policy,snapshot()).status,0,'owner security attribute escalation must fail');
   pg.query('company_fixture','ALTER ROLE definer_owner NOCREATEDB');
   pg.query('company_fixture','GRANT SELECT ON pg_catalog.pg_authid TO definer_owner');
   assert.notEqual(compile('check',policy,snapshot()).status,0,'nonruntime definer-owner data ACL escalation must fail');
   pg.query('company_fixture','REVOKE SELECT ON pg_catalog.pg_authid FROM definer_owner');
 });
 await t.test('postcondition failure rolls back a newly added approved grant',()=>{
   pg.query('company_fixture','REVOKE UPDATE(name) ON tenant_fixture.employee FROM runtime_employee');
   const state=snapshot();const generated=compile('apply',policy,state);assert.equal(generated.status,0,generated.stderr);
   // Inject a catalog change after GRANTs but before the actual generated
   // postcondition, proving that failure rolls back the preceding GRANT.
   const changed=generated.stdout.replace('GRANT USAGE ON SEQUENCE','ALTER TABLE tenant_fixture.employee ALTER COLUMN name SET DEFAULT \'unexpected\';\nGRANT USAGE ON SEQUENCE');
   assert.notEqual(held(changed).status,0);
   assert.equal(pg.query('company_fixture',"SELECT has_column_privilege('runtime_employee','tenant_fixture.employee','name','UPDATE')").trim(),'f');
   const retry=compile('apply',policy,snapshot());assert.equal(retry.status,0,retry.stderr);assert.equal(held(retry.stdout).status,0);
 });
 await t.test('wrong cluster or database refuses to compile application SQL',()=>{
   const state=snapshot();for(const key of ['systemId','database']){const wrong=structuredClone(policy);wrong[key]=key==='systemId'?'9999':'another_database';if(key==='database')wrong.allowedDatabases.push(wrong.database);assert.notEqual(compile('apply',wrong,state).status,0);}
 });
});
