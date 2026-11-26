// Actual Loan commands, reusing the repository's existing disposable financial
// adapters and real Loan migration. Only an owned loopback database is admitted.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function upstream(file){const result=spawnSync(process.env.RUNTIME_GRANTS_PYTHON,[file],{encoding:'utf8',windowsHide:true,timeout:60000});assert.equal(result.status,0,result.stderr);return result.stdout.split(/\r?\n/).filter(line=>!line.startsWith('\\')).join('\n').replaceAll('loan_test','tenant_fixture');}
test('actual Loan commands atomically preserve current-stage, replay, outcome and financial writes',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_loan_fixture;');
 for(const file of [path.join(root,'tests/migrations/loan_fixture_sql.py'),path.join(services,'scripts/loan_runtime_fixture.py'),path.join(services,'scripts/payroll_loan_fixture.py')])pg.query('company_email_loan_fixture',upstream(file));
 // Existing financial fixture baseline is applied BEFORE mail tables exist.
 // It cannot accidentally grant mail settings or delivery-state privileges.
 pg.query('company_email_loan_fixture','GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_payroll;GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA tenant_fixture TO hrms_company_payroll;');
 const existing=pg.query('company_email_loan_fixture',"SELECT table_name FROM information_schema.tables WHERE table_schema='tenant_fixture'").trim().split(/\r?\n/);
 const full=new Set([...existing,'user_role','role','role_permission','permission','permission_scope']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 let seeds=`SET search_path=tenant_fixture,pg_catalog;
 INSERT INTO kabipay_ops.tenant(id,name,status,timezone,currency,is_deleted) VALUES('${id(1)}','Synthetic Loan tenant','ACTIVE','UTC','INR',false);
 INSERT INTO kabipay_ops.module(id,code,name,is_active,is_core) VALUES('${id(70)}','LOANS','Loans',true,true),('${id(71)}','PAYROLL','Payroll',true,true);
 INSERT INTO workflow(id,tenant_id,name,entity_type,is_active) VALUES('${id(30)}','${id(1)}','Synthetic Loan workflow','LOAN_REQUEST',true);
 INSERT INTO workflow_step(id,tenant_id,workflow_id,sequence_order,step_name,approver_type,approver_permission,can_skip) VALUES('${id(31)}','${id(1)}','${id(30)}',1,'First','PERMISSION','loan:approve',false),('${id(32)}','${id(1)}','${id(30)}',2,'Final','PERMISSION','loan:approve',false);`;
 for(const [user,employee]of [[5,2],[6,3],[10,110],[11,111]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted,employment_type,date_of_joining) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false,'FULL_TIME','2020-01-01');`;
  if(user>=10)seeds+=`INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(100)}','loan','approve');`;
 for(const user of [10,11])seeds+=`INSERT INTO role_permission(role_id,permission_id) VALUES('${id(user+200)}','${id(100)}');INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(user+200)}','loan','approve','ALL');`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e._grants_sql("tenant_fixture", {"hrms_company_payroll": e.EMAIL_AUTHORITY_COLUMNS["hrms_company_payroll"]}))')+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_loan_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX|LOAN_TEST)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-loans','--test','email_writers_owned','--','--ignored','--exact','owned_loan_command_stage_outcome_dedup_and_atomic_failure','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
