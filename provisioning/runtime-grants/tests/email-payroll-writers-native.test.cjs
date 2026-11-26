// Actual draft/finalization under real fixed Payroll authorities; metadata is
// in a separate owned DB, never made visible inside the company schema.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function upstream(file,args=[]){const result=spawnSync(process.env.RUNTIME_GRANTS_PYTHON,[file,...args],{encoding:'utf8',windowsHide:true,timeout:60000});assert.equal(result.status,0,result.stderr);return result.stdout.split(/\r?\n/).filter(line=>!line.startsWith('\\')).join('\n').replaceAll('loan_test','tenant_fixture');}
test('actual Payroll draft is silent and employee-visible finalization email commits atomically once',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];const database='company_email_payroll_fixture';const owner=database+'_owner';
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+`CREATE ROLE ${owner} NOLOGIN NOINHERIT;CREATE DATABASE ${database} OWNER ${owner};CREATE DATABASE email_metadata_fixture;`);
 pg.query(database,upstream(path.join(root,'tests/migrations/loan_fixture_sql.py')));
 pg.query(database,upstream(path.join(services,'scripts/loan_runtime_fixture.py'),['--part','company']));
 pg.query(database,upstream(path.join(services,'scripts/payroll_loan_fixture.py')));
 pg.query('email_metadata_fixture',upstream(path.join(services,'scripts/loan_runtime_fixture.py'),['--part','metadata']));
 pg.query('email_metadata_fixture',`INSERT INTO kabipay_ops.tenant(id,name,status,timezone,currency,is_deleted) VALUES('${id(1)}','Synthetic Payroll tenant','ACTIVE','UTC','INR',false);INSERT INTO kabipay_ops.module(id,code,name,is_active,is_core) VALUES('${id(70)}','PAYROLL','Payroll',true,true);`);
 // Separate existing business fixture rights, granted before any mail table exists.
 pg.query(database,'GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_payroll;GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA tenant_fixture TO hrms_company_payroll;');
 const existing=pg.query(database,"SELECT table_name FROM information_schema.tables WHERE table_schema='tenant_fixture'").trim().split(/\r?\n/);const full=new Set(existing);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const seeds=`SET search_path=tenant_fixture,pg_catalog;
 INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(5)}','${id(1)}','fixture@example.invalid','fixture',true,false);
 INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted,date_of_joining,payroll_excluded) VALUES('${id(2)}','${id(1)}','${id(5)}','FIXTURE-2','ACTIVE',false,'2020-01-01',false);
 INSERT INTO salary_component(id,tenant_id,code,name,type,is_active,is_taxable,is_fixed) VALUES('${id(20)}','${id(1)}','BASIC','Basic','EARNING',true,true,true);`;
 const target={systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),database,schema:'tenant_fixture',tenantId:id(1),owner,sourceOwner:'fixture_owner'};
 const authority=python(`import payroll_authority as a;import monthly_input_authority as m;t=${JSON.stringify(target)};print(a.install_sql(t));print(m.install_sql(t))`);
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+seeds+authority,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:target.systemId,data_directory:path.join(pg.directory,'data'),database,metadata_database:'email_metadata_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX|LOAN_TEST)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-payroll','--test','email_writers_owned','--','--ignored','--exact','owned_draft_is_silent_and_finalization_email_is_atomic_and_once','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
