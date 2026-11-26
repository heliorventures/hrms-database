// Existing private Timesheet service writers; no added production test bypass.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Timesheet batch writers preserve next-step, final receipt, rollback, replay and rejection notification',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_timesheet_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','timesheet_entry','timesheet_week_batch','workflow','workflow_step','workflow_instance','workflow_action','notification','master_data']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`SET search_path=tenant_fixture,pg_catalog;
 CREATE UNIQUE INDEX fixture_week ON timesheet_week_batch(tenant_id,employee_id,week_start_date);
 GRANT SELECT ON employee,timesheet_entry,timesheet_week_batch,workflow,workflow_step,workflow_instance,workflow_action,notification,master_data TO hrms_company_attendance;
 GRANT INSERT,UPDATE ON timesheet_entry,timesheet_week_batch,workflow_instance,workflow_action,notification TO hrms_company_attendance;
 GRANT UPDATE(id) ON employee,workflow,workflow_step TO hrms_company_attendance;`;
 let seeds=`INSERT INTO workflow(id,tenant_id,name,entity_type,is_active) VALUES('${id(30)}','${id(1)}','Synthetic Timesheet workflow','TIMESHEET_WEEK_BATCH',true);
 INSERT INTO workflow_step(id,tenant_id,workflow_id,sequence_order,step_name,approver_type,approver_permission,can_skip) VALUES('${id(31)}','${id(1)}','${id(30)}',1,'First','PERMISSION','timesheet:approve',false),('${id(32)}','${id(1)}','${id(30)}',2,'Final','PERMISSION','timesheet:approve',false);`;
 for(const [user,employee]of [[5,2],[6,3],[10,110],[11,111]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false);
  INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');`;
 }
 seeds+=`INSERT INTO permission(id,resource,action) VALUES('${id(100)}','timesheet','approve');`;
 for(const user of [5,10,11])seeds+=`INSERT INTO role_permission(role_id,permission_id) VALUES('${id(user+200)}','${id(100)}');INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(user+200)}','timesheet','approve','ALL');`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_timesheet_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-attendance','--lib','owned_timesheet_submission_decisions_rollback_replay_and_resubmit','--','--ignored','--exact','services::timesheet_batch_service::email_owned_tests::owned_timesheet_submission_decisions_rollback_replay_and_resubmit','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
