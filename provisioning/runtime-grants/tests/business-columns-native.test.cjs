// Native ACL operations only, using owned loopback PostgreSQL and synthetic rows.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
const E='hrms_company_employee',P='hrms_company_payroll',L='hrms_company_leave';
const id="'00000000-0000-4000-8000-000000000001'";
const other="'00000000-0000-4000-8000-000000000002'";
function compile(mode,target,before){
 const code="import sys,json;sys.path.insert(0,sys.argv[1]);import online_business_columns as m;v=json.load(sys.stdin);print(m.snapshot_sql(v['target']) if sys.argv[2]=='snapshot' else m.guarded_sql(v['target'],v['before']))";
 return spawnSync('py',['-3','-c',code,directory,mode],{input:JSON.stringify({target,before}),encoding:'utf8',windowsHide:true});
}

test('reviewed business ACLs support real writes, returning, defaults and locks without secrets or broad rights',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const generated=spawnSync('py',['-3',path.join(__dirname,'business_fixture.py')],{encoding:'utf8',windowsHide:true});
 assert.equal(generated.status,0,generated.stderr);
 const {sql:ddl,requirements}=JSON.parse(generated.stdout);
 pg.query('postgres',`CREATE DATABASE company_fixture; CREATE ROLE ${E} LOGIN NOINHERIT; CREATE ROLE ${P} LOGIN NOINHERIT; CREATE ROLE ${L} LOGIN NOINHERIT;`);
 pg.query('company_fixture',ddl);
 pg.query('company_fixture',`GRANT USAGE ON SCHEMA tenant_fixture TO ${E},${P},${L};
 GRANT SELECT(id,tenant_id,is_active,is_deleted),UPDATE(id) ON tenant_fixture."user" TO ${P};
 INSERT INTO tenant_fixture."user"(id,tenant_id,username,email,password_hash) VALUES(${id},${id},'follow-up','synthetic@example.invalid','synthetic-never-return');
 INSERT INTO tenant_fixture.file_storage(id,tenant_id,provider,storage_path,mime_type) VALUES(${id},${id},'LOCAL','synthetic-private-location','image/png');
 INSERT INTO tenant_fixture.payslip VALUES(${id},${id});
 INSERT INTO tenant_fixture.onboarding_checklist(id,tenant_id,employee_id,task_name) VALUES(${id},${id},${id},'Welcome');
 INSERT INTO tenant_fixture.workflow(id,tenant_id,name,entity_type) VALUES(${id},${id},'Loan review','LOAN_REQUEST');
 INSERT INTO tenant_fixture.workflow_step(id,tenant_id,workflow_id,sequence_order,step_name,approver_permission) VALUES(${id},${id},${id},1,'Review','loan:approve');`);
 const target={systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture'};
 function snapshot(){const result=compile('snapshot',target);assert.equal(result.status,0,result.stderr);return JSON.parse(pg.query('company_fixture',result.stdout));}
 function allowed(role,sql){const result=pg.psql('company_fixture',{role,sql:'SET search_path=tenant_fixture; '+sql});assert.equal(result.status,0,result.stderr+'\n'+sql);return result.stdout;}
 function denied(role,sql){const result=pg.psql('company_fixture',{role,sql:'SET search_path=tenant_fixture; '+sql});assert.notEqual(result.status,0,sql);assert.match(result.stderr,/permission denied/,result.stderr);}
 const before=snapshot();assert(before.required.some(v=>!v));
 for(const [role,tables]of Object.entries(requirements))for(const table of Object.keys(tables))
  denied(role,`SELECT ${table==='user'?'username':'id'} FROM "${table}" LIMIT 0`);
 denied(E,`UPDATE onboarding_checklist SET is_completed=true WHERE id=${id}`);
 denied(P,`INSERT INTO loan_request(id,tenant_id,employee_id,requested_amount,currency,purpose,preferences,state,version) VALUES(${id},${id},${id},100,'INR','Medical','{}','DRAFT',1)`);
 const correction=compile('apply',target,before);assert.equal(correction.status,0,correction.stderr);
 const applied=pg.psql('company_fixture',{sql:correction.stdout});assert.equal(applied.status,0,applied.stderr);
 const after=snapshot();assert(after.required.every(Boolean));assert.equal(after.invariantsSha256,before.invariantsSha256);

 await t.test('payroll directory and logo predicates work with credential/storage projections denied',()=>{
  assert.equal(allowed(P,`SELECT id FROM "user" WHERE id=${id} AND tenant_id=${id} AND is_active=true AND is_deleted=false`).trim(),id.slice(1,-1));
  assert.match(allowed(P,`SELECT id,username FROM "user" WHERE tenant_id=${id} AND is_active=true AND is_deleted=false ORDER BY id LIMIT 101`),/follow-up/);
  assert.equal(allowed(P,`SELECT mime_type FROM file_storage WHERE id=${id} AND tenant_id=${id}`).trim(),'image/png');
  assert.equal(allowed(P,`SELECT mime_type FROM file_storage WHERE id=${id} AND tenant_id=${other}`).trim(),'');
  for(const sql of['SELECT password_hash FROM "user"','SELECT mfa_secret FROM "user"','SELECT * FROM "user"','SELECT storage_path FROM file_storage','SELECT * FROM file_storage',`UPDATE "user" SET is_active=false WHERE id=${id}`])denied(P,sql);
 });
 await t.test('employee onboarding, separation, clearance and profile transitions return their ORM fields',()=>{
  const profileColumns='id,tenant_id,employee_id,requested_by,request_type,requested_payload,requested_payload_encrypted,payload_encryption_version,status,supporting_document_id,reviewed_by,reviewed_at,rejection_reason,created_at,updated_at';
  const separationColumns='id,tenant_id,employee_id,separation_type,resignation_date,last_working_date,reason,status,approved_by,workflow_instance_id,offboarded_at,offboarding_event_id,created_at,updated_at';
  const clearanceColumns='id,tenant_id,separation_id,department,task_name,is_cleared,cleared_by,cleared_at,created_at,updated_at';
  const notificationColumns='id,tenant_id,user_id,type,title,message,action_url,is_read,read_at,created_at,updated_at';
  allowed(E,`BEGIN;
   SELECT * FROM onboarding_checklist WHERE tenant_id=${id} AND employee_id=${id};
   UPDATE onboarding_checklist SET is_completed=true,completed_at=now(),updated_at=now() WHERE id=${id} RETURNING *;
   INSERT INTO separation(${separationColumns}) VALUES(${id},${id},${id},'RESIGNATION',current_date,current_date,'Synthetic','PENDING',NULL,NULL,NULL,NULL,now(),now()) RETURNING ${separationColumns};
   SELECT ${separationColumns} FROM separation WHERE tenant_id=${id} AND id=${id} FOR UPDATE;
   UPDATE separation SET status='APPROVED',approved_by=${id},updated_at=now() WHERE tenant_id=${id} AND id=${id} RETURNING ${separationColumns};
   INSERT INTO clearance_checklist(${clearanceColumns}) VALUES(${id},${id},${id},'HR','Return ID',false,NULL,NULL,now(),now()) RETURNING ${clearanceColumns};
   UPDATE clearance_checklist SET is_cleared=true,cleared_by=NULL,cleared_by_principal_id=${other},cleared_at=now(),updated_at=now() WHERE tenant_id=${id} AND id=${id};
   SELECT ${clearanceColumns} FROM clearance_checklist WHERE tenant_id=${id} AND separation_id=${id};
   UPDATE separation SET status='REJECTED',approved_by=NULL,approved_by_principal_id=${other},updated_at=now() WHERE tenant_id=${id} AND id=${id};
   UPDATE separation SET offboarded_at=now(),offboarding_event_id=${other},updated_at=now() WHERE tenant_id=${id} AND id=${id} RETURNING employee_id;
   INSERT INTO employee_profile_change_request(${profileColumns}) VALUES(${id},${id},${id},${id},'PAN','{}',decode('01','hex'),1,'PENDING',NULL,NULL,NULL,NULL,now(),now()) RETURNING ${profileColumns};
   SELECT ${profileColumns} FROM employee_profile_change_request WHERE tenant_id=${id} AND id=${id} FOR UPDATE;
   UPDATE employee_profile_change_request SET status='CANCELLED',requested_payload='{}',requested_payload_encrypted=NULL,payload_encryption_version=NULL,updated_at=now() WHERE id=${id} RETURNING ${profileColumns};
   UPDATE employee_profile_change_request SET status='REJECTED',requested_payload='{}',requested_payload_encrypted=NULL,payload_encryption_version=NULL,reviewed_by=${other},reviewed_at=now(),rejection_reason='Synthetic',updated_at=now() WHERE id=${id} RETURNING ${profileColumns};
   INSERT INTO notification(${notificationColumns}) VALUES(${id},${id},${id},'PROFILE','Reviewed','Synthetic','/profile',false,NULL,now(),now());
   COMMIT;`);
  assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.notification').trim(),'1');
  denied(E,'SELECT * FROM notification');
  denied(E,`INSERT INTO notification(${notificationColumns}) VALUES(${other},${id},${id},'PROFILE','Reviewed','Synthetic','/profile',false,NULL,now(),now()) RETURNING ${notificationColumns}`);
  for(const sql of[`INSERT INTO onboarding_checklist(id,tenant_id,employee_id,task_name) VALUES(${other},${id},${id},'Unrequested')`,`UPDATE employee_profile_change_request SET requested_by=${other} WHERE id=${id}`,`UPDATE separation SET reason='Unrequested' WHERE id=${id}`,`UPDATE clearance_checklist SET department='Unrequested' WHERE id=${id}`,'DELETE FROM separation','UPDATE notification SET is_read=true'])denied(E,sql);
 });
 await t.test('HR exit operation defaults and immutable transition trigger survive least privilege',()=>{
  allowed(E,`INSERT INTO employee_exit_operation(id,tenant_id,separation_id,employee_id,actor_id,review_id,separation_fingerprint,payload_hash,state) VALUES(${id},${id},${id},${id},${id},${id},'synthetic','synthetic','REGISTERED');
   BEGIN; SELECT id,separation_id,employee_id,actor_id,review_id,separation_fingerprint,payload_hash,authorization_id,state FROM employee_exit_operation WHERE tenant_id=${id} AND id=${id} FOR UPDATE;
   UPDATE employee_exit_operation SET state='COMMITTED',authorization_id=${other},updated_at=now() WHERE tenant_id=${id} AND id=${id} AND state='REGISTERED'; COMMIT;`);
  const changed=pg.psql('company_fixture',{role:E,sql:`UPDATE tenant_fixture.employee_exit_operation SET state='CANCELLED',updated_at=now() WHERE id=${id}`});
  assert.notEqual(changed.status,0);assert.match(changed.stderr,/terminal HR Finance operations are immutable/);
  denied(E,`UPDATE employee_exit_operation SET result='{}' WHERE id=${id}`);
  denied(E,'SELECT result FROM employee_exit_operation');
 });
 await t.test('conditional loan workflow supports request/default/returning/lock and snapshot operations',()=>{
  allowed(P,`BEGIN;
   INSERT INTO loan_request(id,tenant_id,employee_id,requested_amount,currency,purpose,employee_notes,preferences,state,version) VALUES(${id},${id},${id},100,'INR','Medical',NULL,'{}','DRAFT',1);
   SELECT * FROM loan_request WHERE tenant_id=${id} AND id=${id} FOR UPDATE;
   UPDATE loan_request SET requested_amount=101,currency='INR',purpose='Medical',employee_notes='Synthetic',preferences='{}',state='SUBMITTED',workflow_instance_id=NULL,version=version+1 WHERE tenant_id=${id} AND id=${id};
   SELECT * FROM workflow WHERE tenant_id=${id} AND id=${id};
   SELECT * FROM workflow_step WHERE tenant_id=${id} AND workflow_id=${id} ORDER BY sequence_order;
   SELECT * FROM workflow_step WHERE tenant_id=${id} AND workflow_id=${id} AND id=${id} FOR UPDATE;
   INSERT INTO workflow_instance(id,tenant_id,workflow_id,entity_type,entity_id,status,current_step_id,created_at,completed_at,updated_at) VALUES(${id},${id},${id},'LOAN_REQUEST',${id},'IN_PROGRESS',${id},now(),NULL,now()) RETURNING *;
   UPDATE loan_request SET workflow_instance_id=${id},state='UNDER_REVIEW',management_notes='Review',version=version+1 WHERE tenant_id=${id} AND id=${id};
   SELECT * FROM workflow_instance WHERE tenant_id=${id} AND id=${id} FOR UPDATE;
   INSERT INTO workflow_action(id,tenant_id,instance_id,workflow_step_id,performed_by,action,remarks,acted_at,created_at,updated_at) VALUES(${id},${id},${id},${id},${id},'APPROVE','Synthetic',now(),now(),now());
   UPDATE workflow_instance SET status='COMPLETED',current_step_id=NULL,completed_at=now(),updated_at=now() WHERE id=${id} RETURNING *;
   INSERT INTO payslip_unpaid_leave(id,tenant_id,payslip_id,basic_component_code,basic_amount,day_divisor,unpaid_days,amount,treatment,source_days,created_at) VALUES(${id},${id},${id},'BASIC',3000,30,1,100,'BEFORE_STATUTORY','[]',now()) RETURNING *;
   SELECT * FROM payslip_unpaid_leave WHERE tenant_id=${id} AND payslip_id=${id}; COMMIT;`);
  allowed(L,`SELECT * FROM workflow_action WHERE tenant_id=${id} AND instance_id=${id} ORDER BY acted_at,id`);
  denied(P,'SELECT * FROM workflow_action');
  denied(P,`INSERT INTO workflow_action(id,tenant_id,instance_id,workflow_step_id,performed_by,action,remarks,acted_at,created_at,updated_at) VALUES(${other},${id},${id},${id},${id},'APPROVE','Synthetic',now(),now(),now()) RETURNING *`);
  pg.query('company_fixture',`REVOKE UPDATE(id) ON tenant_fixture.workflow_step FROM ${P}`);
  denied(P,`SELECT * FROM workflow_step WHERE id=${id} FOR UPDATE`);
  pg.query('company_fixture',`GRANT UPDATE(id) ON tenant_fixture.workflow_step TO ${P}`);
  allowed(P,`BEGIN; SELECT * FROM workflow_step WHERE id=${id} FOR UPDATE; ROLLBACK;`);
  for(const sql of['UPDATE workflow_step SET step_name=\'Changed\'','UPDATE workflow SET is_active=false','UPDATE payslip_unpaid_leave SET amount=0','DELETE FROM loan_request','SELECT * FROM notification'])denied(P,sql);
 });
 await t.test('no table privilege or sequence dependency; drift, incoming membership and wrong targets fail closed',()=>{
  for(const [role,tables]of Object.entries(requirements))for(const table of Object.keys(tables))for(const operation of['SELECT','INSERT','UPDATE','DELETE'])
   assert.equal(pg.query('company_fixture',`SELECT has_table_privilege('${role}','tenant_fixture.${table}','${operation}')`).trim(),'f',role+'.'+table+'.'+operation);
  assert.equal(pg.query('company_fixture',"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='tenant_fixture' AND c.relkind='S'").trim(),'0');
  const retry=compile('apply',target,snapshot());assert.equal(retry.status,0,retry.stderr);assert.equal(pg.psql('company_fixture',{sql:retry.stdout}).status,0);
  const stale=compile('apply',target,snapshot());assert.equal(stale.status,0,stale.stderr);
  pg.query('company_fixture','ALTER TABLE tenant_fixture.workflow ADD COLUMN operator_only text');
  const drift=pg.psql('company_fixture',{sql:stale.stdout});assert.notEqual(drift.status,0);assert.match(drift.stderr,/ONLINE_COLUMNS_BASELINE_CHANGED/);
  assert.notEqual(compile('apply',{...target,systemId:'999'},snapshot()).status,0);
  pg.query('company_fixture',`CREATE ROLE unexpected_member; GRANT ${P} TO unexpected_member`);
  assert.equal(snapshot().restrictedRoles,false);assert.notEqual(compile('apply',target,snapshot()).status,0);
 });
});
