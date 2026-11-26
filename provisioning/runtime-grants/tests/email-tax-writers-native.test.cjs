// Actual Tax writers under a restricted login, with an owned ephemeral cluster.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Tax submit/approve/reject atomically preserves intent, deduplication and current eligibility',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_tax_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','tax_proof_line','tax_section_definition','tax_configuration_version','employee_tax_settings','employee_tax_declaration','notification','file_storage']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`SET search_path=tenant_fixture,pg_catalog;
 GRANT SELECT ON employee,tax_proof_line,tax_section_definition,tax_configuration_version,employee_tax_settings,employee_tax_declaration,notification,file_storage TO hrms_company_tax;
 GRANT INSERT,UPDATE ON tax_proof_line,employee_tax_declaration,notification TO hrms_company_tax;`;
 let seeds='';
 for(const [user,employee]of [[5,2],[10,110]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false);
  INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);
  INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(100)}','tax','approve');
 INSERT INTO role_permission(role_id,permission_id) VALUES('${id(210)}','${id(100)}');
 INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(210)}','tax','approve','ALL');
 INSERT INTO tax_configuration_version(id,tenant_id,fiscal_year,regime,country_code,is_active) VALUES('${id(20)}','${id(1)}',2026,'OLD','IN',true);
 INSERT INTO file_storage(id,tenant_id,uploaded_by,mime_type,file_size_bytes) VALUES('${id(21)}','${id(1)}','${id(5)}','application/pdf',100);
 INSERT INTO employee_tax_settings(id,tenant_id,employee_id,revision,effective_from,payload,actor_id) VALUES('${id(22)}','${id(1)}','${id(2)}',1,'2020-04-01','{"regime":"OLD","method":"ANNUAL_PROJECTION","effective_from":"2020-04-01","resident":true}','${id(10)}');`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_tax_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-tax','--test','email_writers_owned','--','--ignored','--exact','owned_tax_submission_decisions_rollback_dedup_and_current_eligibility','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
