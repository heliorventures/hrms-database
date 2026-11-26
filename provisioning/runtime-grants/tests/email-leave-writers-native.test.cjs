// Real local Leave writer rehearsal, isolated from application databases and
// providers. Existing webhook/audit prerequisites are a separate fixture
// baseline; none are silently added to the new email permission contract.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');
const privateBusiness=require('./email-private-business-fixture.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Leave submit/approve/reject/withdraw/comp-off cancellation preserves atomic email and existing in-app writes',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_leave_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','leave_request','leave_type','leave_balance','workflow','workflow_step','workflow_instance','workflow_action','notification','holiday','holiday_calendar','working_calendar_profile','leave_working_date_snapshot','comp_off_policy','comp_off_credit','comp_off_allocation']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`SET search_path=tenant_fixture,pg_catalog;
 GRANT SELECT ON employee,leave_request,leave_type,leave_balance,workflow,workflow_step,workflow_instance,workflow_action,notification,holiday,holiday_calendar,working_calendar_profile,leave_working_date_snapshot,comp_off_policy,comp_off_credit,comp_off_allocation TO hrms_company_leave;
 GRANT INSERT,UPDATE ON leave_request,leave_balance,workflow_instance,workflow_action,notification,leave_working_date_snapshot,comp_off_credit,comp_off_allocation TO hrms_company_leave;
 GRANT UPDATE(id) ON employee,workflow,workflow_step,management_assignment,"user" TO hrms_company_leave;`;
 let seeds=`INSERT INTO leave_type(id,tenant_id,name,code,is_paid,half_day_allowed,requires_document,is_deleted,sandwich_rule) VALUES('${id(20)}','${id(1)}','Fixture unpaid','FIXTURE_UNPAID',false,true,false,false,false),('${id(50)}','${id(1)}','Fixture comp off','COMP_OFF',true,true,false,false,false);
 INSERT INTO workflow(id,tenant_id,name,entity_type,is_active) VALUES('${id(30)}','${id(1)}','Fixture leave','LEAVE_REQUEST',true);
 INSERT INTO workflow_step(id,tenant_id,workflow_id,sequence_order,step_name,approver_type,approver_permission) VALUES('${id(31)}','${id(1)}','${id(30)}',1,'Fixture manager or approver','REPORTING_MANAGER_OR_PERMISSION','leave:approve'),('${id(32)}','${id(1)}','${id(30)}',2,'Fixture final review','PERMISSION','leave:approve');`;
 for(const [user,employee]of [[5,2],[10,110],[11,111]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted,reporting_manager_id) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false,${user===5?`'${id(110)}'`:'NULL'});
  INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);
  INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(100)}','leave','approve');`;
 for(const user of [5,10,11])seeds+=`INSERT INTO role_permission(role_id,permission_id) VALUES('${id(user+200)}','${id(100)}');INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(user+200)}','leave','approve','ALL');`;
 seeds+=`INSERT INTO comp_off_policy(id,tenant_id,employee_id,leave_type_id,enabled,allow_approved_leave_cancellation) VALUES('${id(51)}','${id(1)}','${id(2)}','${id(50)}',true,true);
 INSERT INTO leave_request(id,tenant_id,employee_id,leave_type_id,from_date,to_date,days_requested,is_half_day,status,uses_comp_off,is_deleted) VALUES('${id(60)}','${id(1)}','${id(2)}','${id(50)}','2026-12-01','2026-12-01',1,false,'APPROVED',true,false);
 INSERT INTO comp_off_credit(id,tenant_id,employee_id,earned_units,reserved_units,used_units,expires_at) VALUES('${id(61)}','${id(1)}','${id(2)}',1,0,1,'2026-12-31');
 INSERT INTO comp_off_allocation(id,tenant_id,credit_id,leave_request_id,leave_date,units,status) VALUES('${id(62)}','${id(1)}','${id(61)}','${id(60)}','2026-12-01',1,'USED');`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+privateBusiness.baseline(id(1),'hrms_company_leave')+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_leave_fixture'}),{flag:'wx',mode:0o600});
 const keys=privateBusiness.keys(pg.directory,id(1));
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;env.KABIPAY_PRIVATE_EVENT_KEYS_FILE=keys;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-leave','--test','email_writers_owned','--','--ignored','--exact','owned_leave_commit_rollback_next_step_cancellation_and_final_outcome','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
