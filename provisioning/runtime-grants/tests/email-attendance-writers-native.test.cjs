// Real authoritative expiry under both owning Attendance and scheduler logins.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,tables,services}=require('./email-native-support.cjs');const privateBusiness=require('./email-private-business-fixture.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Attendance/scheduler expiry preserves atomic intents, DST windows and correction suppression',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_attendance_fixture;');
 const full=new Set(['user','employee','attendance','attendance_day_window']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 const baseline=`SET search_path=tenant_fixture,pg_catalog;
 CREATE UNIQUE INDEX fixture_attendance_window ON attendance_day_window(tenant_id,work_date);
 GRANT SELECT,UPDATE ON attendance TO hrms_company_attendance,hrms_company_maintenance;
 GRANT SELECT ON attendance_day_window TO hrms_company_attendance,hrms_company_maintenance;`;
 let seeds='';
 for(const [user,employee]of [[5,2],[6,3],[7,4]]){
  seeds+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);
  INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false);`;
 }
 const auditBaseline=privateBusiness.baseline(id(1),'hrms_company_attendance')+`
 GRANT SELECT(id,tenant_id),UPDATE(id) ON "user" TO hrms_company_maintenance;
 GRANT SELECT(tenant_id,producer_generation),UPDATE(updated_at) ON private_source_cutover TO hrms_company_maintenance;
 GRANT INSERT,SELECT(id) ON company_event_outbox TO hrms_company_maintenance;`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+baseline+auditBaseline+seeds,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_attendance_fixture'}),{flag:'wx',mode:0o600});
 const keys=privateBusiness.keys(pg.directory,id(1));const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;env.KABIPAY_PRIVATE_EVENT_KEYS_FILE=keys;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-attendance','--test','email_writers_owned','--','--ignored','--exact','owned_missed_punch_atomic_failure_dst_business_date_and_correction','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
