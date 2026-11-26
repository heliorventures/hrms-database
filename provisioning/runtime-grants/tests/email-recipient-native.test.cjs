// Executes the real recipient resolver with separate restricted company and
// metadata logins in an owned cluster. No live DSN, .env, email or SMTP socket.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;

test('real source recipient proof, identity, nonce and test revocation use restricted SQL',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const contracts=JSON.parse(python('print(json.dumps({"authority":e.EMAIL_AUTHORITY_COLUMNS,"metadata":e.EMAIL_METADATA_COLUMNS["kabipay-employee"]}))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE ROLE hrms_fixture_metadata_employee LOGIN NOINHERIT;CREATE DATABASE company_email_recipient_fixture;');
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(2));
 pg.query('company_email_recipient_fixture',tables('tenant_fixture',Object.values(contracts.authority))+tables('kabipay_ops',[contracts.metadata])+schema+
  python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"));print(e.metadata_grants_sql("hrms_fixture_metadata_employee","kabipay-employee"))'));
 pg.query('company_email_recipient_fixture',`SET search_path=tenant_fixture,pg_catalog;
 INSERT INTO "user"(id,tenant_id,is_active,is_deleted,email) VALUES('${id(26)}','${id(2)}',true,false,'recipient@example.invalid');
 INSERT INTO employee(id,tenant_id,user_id,status,is_deleted) VALUES('${id(25)}','${id(2)}','${id(26)}','ACTIVE',false);
 INSERT INTO role(id,tenant_id,is_deleted) VALUES('${id(51)}','${id(2)}',false);
 INSERT INTO user_role(user_id,role_id) VALUES('${id(26)}','${id(51)}');
 INSERT INTO permission(id,resource,action) VALUES('${id(52)}','email_settings','read'),('${id(53)}','email_settings','test');
 INSERT INTO role_permission(role_id,permission_id) VALUES('${id(51)}','${id(52)}'),('${id(51)}','${id(53)}');
 INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(2)}','${id(51)}','email_settings','read','ALL'),('${id(2)}','${id(51)}','email_settings','test','ALL');
 SET search_path=kabipay_ops,pg_catalog;
 INSERT INTO tenant(id,status,is_deleted) VALUES('${id(1)}','ACTIVE',false),('${id(2)}','ACTIVE',false);
 INSERT INTO organization(id,status) VALUES('${id(20)}','ACTIVE');
 INSERT INTO principal(id,status) VALUES('${id(23)}','ACTIVE'),('${id(32)}','ACTIVE');
 INSERT INTO organization_company(id,organization_id,tenant_id,status,version,installed_version,runtime_status,effective_from)
 VALUES('${id(21)}','${id(20)}','${id(1)}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day'),('${id(22)}','${id(20)}','${id(2)}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day');
 INSERT INTO employment_ref(id,organization_id,organization_company_id,principal_id,source_tenant_id,source_employee_id,source_user_id,employment_status)
 VALUES('${id(24)}','${id(20)}','${id(22)}','${id(23)}','${id(2)}','${id(25)}','${id(26)}','ACTIVE'),('${id(31)}','${id(20)}','${id(21)}','${id(32)}','${id(1)}','${id(33)}','${id(34)}','ACTIVE');
 INSERT INTO principal_login_link(principal_id,source_tenant_id,source_user_id,issuer,status) VALUES('${id(23)}','${id(2)}','${id(26)}','kabipay-client','VERIFIED');
 INSERT INTO organization_role(id,organization_id,status) VALUES('${id(28)}','${id(20)}','ACTIVE');
 INSERT INTO principal_role_binding(id,organization_id,principal_id,version,status,role_id,effective_from) VALUES('${id(27)}','${id(20)}','${id(23)}',1,'ACTIVE','${id(28)}',clock_timestamp()-interval '1 day');
 INSERT INTO organization_role_capability(role_id,organization_id,capability_code,employee_scope) VALUES('${id(28)}','${id(20)}','leave:approve','ALL');
 INSERT INTO role_binding_company(binding_id,organization_id,organization_company_id,activation_status,expected_grant_version) VALUES('${id(27)}','${id(20)}','${id(21)}','ACTIVE',1);
 INSERT INTO organization_relationship(id,organization_id,organization_company_id,manager_employment_ref_id,subject_employment_ref_id,version,installed_version,status,effective_from,capabilities)
 VALUES('${id(30)}','${id(20)}','${id(21)}','${id(24)}','${id(31)}',1,1,'ACTIVE',clock_timestamp()-interval '1 day','["leave:approve"]');`);
 const config=path.join(pg.directory,'owned-email-recipient-fixture.json');
 fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data')}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY)/i.test(name)));
 env.KABIPAY_EMAIL_RECIPIENT_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-organization-tenant','--test','email_recipient_owned','--','--ignored','--exact','owned_recipient_authority_and_identity','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));
 assert.match(result.stdout,/test result: ok\. 1 passed/,'owned recipient service test must actually execute');
});
