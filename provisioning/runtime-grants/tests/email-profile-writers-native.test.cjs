// Actual profile transactions; existing business rights stay fixture-only.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');const privateBusiness=require('./email-private-business-fixture.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
for(const linkedReviewer of [true,false]) test(`actual Profile transaction with reviewer linked employment=${linkedReviewer}`,async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_profile_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','employee_bank','employee_pan','employee_aadhaar','employee_document','employee_profile_change_request','notification']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`SET search_path=tenant_fixture,pg_catalog;
 GRANT SELECT ON "user",user_role,role,role_permission,permission,employee,employee_bank,employee_pan,employee_aadhaar,employee_document,employee_profile_change_request,notification TO hrms_company_employee;
 GRANT INSERT,UPDATE ON employee,employee_bank,employee_pan,employee_aadhaar,employee_document,employee_profile_change_request,notification TO hrms_company_employee;`;
 let seeds='';
 for(const [user,employee]of [[5,2],[10,110]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  ${user===5||linkedReviewer?`INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false);`:''}
  INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);
  INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(100)}','employee','write');
 INSERT INTO role_permission(role_id,permission_id) VALUES('${id(210)}','${id(100)}');
 INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(210)}','employee','write','ALL');`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+privateBusiness.baseline(id(1),'hrms_company_employee')+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_profile_fixture'}),{flag:'wx',mode:0o600});
 const keys=privateBusiness.keys(pg.directory,id(1));
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;env.KABIPAY_PRIVATE_EVENT_KEYS_FILE=keys;env.KABIPAY_PROFILE_CHANGE_ENCRYPTION_KEY=Buffer.alloc(32,9).toString('base64');
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-employee','--test','email_writers_owned','--','--ignored','--exact','owned_profile_commit_rollback_replay_cancel_and_private_payload','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
