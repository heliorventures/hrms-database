// Owned loopback PostgreSQL only. Executes the actual Rust SQL with the exact
// new read profiles; no application DSN, .env, SMTP or live metadata is used.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {fixture} = require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,rustConstant,tables,services}=require('./email-native-support.cjs');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const tenant = id(1), other = id(2), user = id(3), role = id(4), permission = id(5);
const metadataRole = 'hrms_fixture_metadata_employee';

test('actual mail authority SQL respects custom roles, exact scope and current metadata revocation', async t => {
  const contracts = JSON.parse(python('print(json.dumps({"authority":e.EMAIL_AUTHORITY_COLUMNS,"metadata":e.EMAIL_METADATA_COLUMNS["kabipay-employee"]}))'));
  const pg = await fixture(); t.after(() => pg.stop());
  const roles = Object.keys(contracts.authority);
  pg.query('postgres', roles.map(name => `CREATE ROLE "${name}" LOGIN NOINHERIT;`).join('') + `CREATE ROLE ${metadataRole} LOGIN NOINHERIT;CREATE ROLE hrms_company_notification LOGIN NOINHERIT;CREATE DATABASE company_fixture;`);
  pg.query('company_fixture', tables('tenant_fixture',Object.values(contracts.authority)) + tables('kabipay_ops',[contracts.metadata]) +
    'ALTER TABLE tenant_fixture.role ADD COLUMN name text;ALTER TABLE tenant_fixture."user" ADD COLUMN password_hash text;' +
    python('print(e.authority_grants_sql("tenant_fixture"));print(e.metadata_grants_sql("hrms_fixture_metadata_employee","kabipay-employee"))'));
  const as = (login, sql) => pg.psql('company_fixture',{role:login,sql:'SET search_path=tenant_fixture,pg_catalog;' + sql});
  const auth = rustConstant('crates/kabipay-common/src/important_email/eligibility.rs','CURRENT_EMAIL_PERMISSION_SQL');
  const read = (login, resource='leave', action='approve') => {
    const result = as(login, `PREPARE email_auth(uuid,uuid,text,text) AS ${auth};EXECUTE email_auth('${tenant}','${user}','${resource}','${action}');`);
    assert.equal(result.status, 0, result.stderr); return result.stdout.trim().split(/\r?\n/).filter(Boolean).sort();
  };
  pg.query('company_fixture', `SET search_path=tenant_fixture,pg_catalog;
    INSERT INTO "user"(id,tenant_id,is_active,is_deleted,email,password_hash) VALUES('${user}','${tenant}',true,false,'synthetic@example.invalid','not-readable');
    INSERT INTO role(id,tenant_id,is_deleted,name) VALUES('${role}','${tenant}',false,'ANY_NEW_CUSTOM_ROLE'),('${id(6)}','${other}',false,'ADMIN');
    INSERT INTO user_role(user_id,role_id) VALUES('${user}','${role}'),('${user}','${id(6)}');
    INSERT INTO permission(id,resource,action) VALUES('${permission}','leave','approve'),('${id(7)}','payroll','manage');
    INSERT INTO role_permission(role_id,permission_id) VALUES('${role}','${permission}'),('${id(6)}','${id(7)}');
    INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES
      ('${tenant}','${role}','leave','approve','TEAM'),('${other}','${role}','leave','approve','ALL'),
      ('${tenant}','${role}','payroll','manage','ALL'),('${other}','${id(6)}','payroll','manage','ALL');`);
  for (const login of roles) {
    assert.deepEqual(read(login), ['TEAM']);
    assert.deepEqual(read(login,'payroll','manage'), [], 'a scope without its same-role grant and corrupt foreign role confer nothing');
    assert.notEqual(as(login,'SELECT name FROM role').status,0,'runtime never needs role names');
    assert.notEqual(as(login,'SELECT password_hash FROM "user"').status,0);
    assert.equal(as(login,'SELECT email FROM "user"').status === 0,login === 'hrms_company_employee');
  }
  assert.notEqual(as('hrms_company_notification','SELECT id FROM "user"').status,0,'Notification has no identity-directory read profile');
  for (const domain of ['leave','expense','attendance','payroll','tax','performance']) {
    const login='hrms_company_'+domain;
    const read=as(login,'SELECT manager_employee_id FROM management_assignment');
    assert.equal(read.status,0,read.stderr);
    const locked=as(login,'SELECT manager_employee_id FROM management_assignment FOR SHARE');
    assert.notEqual(locked.status,0,'mail must not gain assignment UPDATE rights for a row lock');
    assert.match(locked.stderr,/permission denied/i);
  }
  pg.query('company_fixture',`SET search_path=tenant_fixture;INSERT INTO role(id,tenant_id,is_deleted,name) VALUES('${id(8)}','${tenant}',false,'ARBITRARY');INSERT INTO user_role(user_id,role_id) VALUES('${user}','${id(8)}');INSERT INTO role_permission(role_id,permission_id) VALUES('${id(8)}','${permission}');INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${tenant}','${id(8)}','leave','approve','ALL');`);
  assert.deepEqual(read('hrms_company_leave'),['ALL','TEAM']);
  pg.query('company_fixture',`DELETE FROM tenant_fixture.role_permission WHERE role_id='${id(8)}'`);
  assert.deepEqual(read('hrms_company_leave'),['TEAM'],'revocation is effective without a new login');
  pg.query('company_fixture',`UPDATE tenant_fixture."user" SET is_active=false WHERE id='${user}'`);
  assert.deepEqual(read('hrms_company_leave'),[]);

  const org=id(20), member=id(21), sourceMember=id(22), principal=id(23), employment=id(24), employee=id(25), sourceUser=id(26), binding=id(27), orgRole=id(28);
  pg.query('company_fixture',`SET search_path=kabipay_ops,pg_catalog;
    INSERT INTO tenant(id,status,is_deleted) VALUES('${tenant}','ACTIVE',false),('${other}','ACTIVE',false);
    INSERT INTO organization(id,status) VALUES('${org}','ACTIVE');INSERT INTO principal(id,status) VALUES('${principal}','ACTIVE');
    INSERT INTO organization_company(id,organization_id,tenant_id,status,version,installed_version,runtime_status,effective_from)
      VALUES('${member}','${org}','${tenant}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day'),('${sourceMember}','${org}','${other}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day');
    INSERT INTO employment_ref(id,organization_id,organization_company_id,principal_id,source_tenant_id,source_employee_id,source_user_id,employment_status)
      VALUES('${employment}','${org}','${sourceMember}','${principal}','${other}','${employee}','${sourceUser}','ACTIVE');
    INSERT INTO principal_login_link(principal_id,source_tenant_id,source_user_id,issuer,status) VALUES('${principal}','${other}','${sourceUser}','kabipay-client','VERIFIED');
    INSERT INTO organization_role(id,organization_id,status) VALUES('${orgRole}','${org}','ACTIVE');
    INSERT INTO principal_role_binding(id,organization_id,principal_id,version,status,role_id,effective_from) VALUES('${binding}','${org}','${principal}',1,'ACTIVE','${orgRole}',clock_timestamp()-interval '1 day');
    INSERT INTO organization_role_capability(role_id,organization_id,capability_code,employee_scope) VALUES('${orgRole}','${org}','leave:approve','ALL');
    INSERT INTO role_binding_company(binding_id,organization_id,organization_company_id,activation_status,expected_grant_version) VALUES('${binding}','${org}','${member}','ACTIVE',1);`);
  const identity = rustConstant('crates/kabipay-common/src/important_email/organization_identity.rs','EMAIL_ORGANIZATION_IDENTITY_SQL');
  const identityRead = () => {
    const result = as(metadataRole,`PREPARE email_identity(uuid,uuid,uuid,uuid,uuid,uuid) AS ${identity};EXECUTE email_identity('${principal}','${other}','${employee}','${org}','${member}','${tenant}');`);
    assert.equal(result.status,0,result.stderr); return result.stdout.trim();
  };
  assert.equal(identityRead(),sourceUser);
  for (const [change, restore] of [
    [`UPDATE principal SET status='REVOKED'`,`UPDATE principal SET status='ACTIVE'`],
    [`UPDATE principal_login_link SET status='REVOKED'`,`UPDATE principal_login_link SET status='VERIFIED'`],
    [`UPDATE employment_ref SET source_user_id='${id(29)}'`,`UPDATE employment_ref SET source_user_id='${sourceUser}'`],
    [`UPDATE organization_company SET installed_version=0 WHERE id='${member}'`,`UPDATE organization_company SET installed_version=version WHERE id='${member}'`],
    [`UPDATE organization_company SET runtime_status='PENDING' WHERE id='${sourceMember}'`,`UPDATE organization_company SET runtime_status='ACTIVE' WHERE id='${sourceMember}'`],
  ]) {
    pg.query('company_fixture','SET search_path=kabipay_ops,pg_catalog;'+change);assert.equal(identityRead(),'');
    pg.query('company_fixture','SET search_path=kabipay_ops,pg_catalog;'+restore);assert.equal(identityRead(),sourceUser);
  }
  const identitySource = fs.readFileSync(path.join(services,'crates/kabipay-organization-tenant/src/email_identity.rs'),'utf8');
  const grant = identitySource.match(/"(SELECT b\.id FROM kabipay_ops\.principal_role_binding[^"\n]+)"/)[1];
  const grantRead = () => {
    const result = as(metadataRole,`PREPARE email_grant(uuid,uuid,uuid,bigint,uuid,text) AS ${grant};EXECUTE email_grant('${binding}','${org}','${principal}',1,'${member}','leave:approve');`);
    assert.equal(result.status,0,result.stderr);return result.stdout.trim();
  };
  assert.equal(grantRead(),binding);
  pg.query('company_fixture',`UPDATE kabipay_ops.principal_role_binding SET version=2`);assert.equal(grantRead(),'');
  pg.query('company_fixture',`UPDATE kabipay_ops.principal_role_binding SET version=1`);assert.equal(grantRead(),binding);
  pg.query('company_fixture',`UPDATE kabipay_ops.organization_role_capability SET employee_scope='TEAM'`);
  assert.equal(grantRead(),'','TEAM applies to reporting relationships, not organization role bindings');
});
