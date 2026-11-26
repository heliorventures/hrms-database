// Actual Expense/Travel writers in an owned cluster. Business-table baseline
// privileges here are a synthetic existing-service fixture, not a proposed
// production grant. Exact additive mail privileges have separate native tests.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,tables,services}=require('./email-native-support.cjs');
const privateBusiness=require('./email-private-business-fixture.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Expense and Travel submit/approve/reject commit their mail atomically and reject duplicate replay',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_expense_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','expense','expense_category','expense_policy','workflow','workflow_step','workflow_instance','workflow_action','file_storage','travel_request','notification']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_expense;
 GRANT SELECT ON tenant_fixture.user_role,tenant_fixture.employee,tenant_fixture.expense,tenant_fixture.travel_request,tenant_fixture.expense_category,tenant_fixture.expense_policy,tenant_fixture.file_storage,tenant_fixture.workflow,tenant_fixture.workflow_step,tenant_fixture.workflow_instance,tenant_fixture.workflow_action,tenant_fixture.notification TO hrms_company_expense;
 GRANT INSERT,UPDATE ON tenant_fixture.expense,tenant_fixture.travel_request,tenant_fixture.workflow_instance,tenant_fixture.workflow_action,tenant_fixture.notification TO hrms_company_expense;
 GRANT UPDATE(id) ON tenant_fixture.employee,tenant_fixture.workflow,tenant_fixture.workflow_step TO hrms_company_expense;`;
 let seeds=`SET search_path=tenant_fixture,pg_catalog;
 INSERT INTO expense_category(id,tenant_id,name,code) VALUES('${id(20)}','${id(1)}','Fixture category','FIXTURE');
 INSERT INTO file_storage(id,tenant_id,provider,storage_path,mime_type,file_size_bytes,is_public,uploaded_by) VALUES('${id(21)}','${id(1)}','LOCAL','synthetic-not-opened','application/pdf',100,false,'${id(5)}');
 INSERT INTO workflow(id,tenant_id,name,entity_type,is_active) VALUES('${id(30)}','${id(1)}','Fixture expenses','EXPENSE',true),('${id(40)}','${id(1)}','Fixture trips','TRAVEL_REQUEST',true);`;
 for(const [workflow,permission]of [[30,'expense:approve'],[40,'travel:approve']])for(const step of [1,2])seeds+=`INSERT INTO workflow_step(id,tenant_id,workflow_id,sequence_order,step_name,approver_type,approver_permission) VALUES('${id(workflow+step)}','${id(1)}','${id(workflow)}',${step},'Fixture review ${step}','PERMISSION','${permission}');`;
 for(const [user,employee]of [[5,2],[10,110],[11,111]]){
   seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
   INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false);
   INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);
   INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 for(const [n,resource]of [[100,'expense'],[101,'travel']]){
   seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(n)}','${resource}','approve');`;
   for(const user of [5,10,11])seeds+=`INSERT INTO role_permission(role_id,permission_id) VALUES('${id(user+200)}','${id(n)}');INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(user+200)}','${resource}','approve','ALL');`;
 }
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+
   python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+privateBusiness.baseline(id(1),'hrms_company_expense')+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');
 fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_expense_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;env.KABIPAY_PRIVATE_EVENT_KEYS_FILE=privateBusiness.keys(pg.directory,id(1));
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-expense','--test','email_writers_owned','--','--ignored','--exact','owned_expense_and_travel_commit_rollback_next_step_outcome_and_replay','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
