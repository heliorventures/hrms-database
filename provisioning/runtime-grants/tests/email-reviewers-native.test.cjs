const {test}=require('node:test');
const assert=require('node:assert/strict');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,rustConstant,tables}=require('./email-native-support.cjs');
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;

test('one restricted batch selects current custom-role reviewers with scope, canonical manager and self denial',async t=>{
  const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
  const pg=await fixture(); t.after(()=>pg.stop());
  pg.query('postgres',Object.keys(profiles).map(role=>`CREATE ROLE ${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_fixture;');
  pg.query('company_fixture',tables('tenant_fixture',Object.values(profiles))+python('print(e.authority_grants_sql("tenant_fixture"))'));
  const tenant=id(1),subject=id(2),department=id(3),permission=id(4),requester=id(5);
  const manager=id(10),director=id(11),peer=id(12),all=id(13),outside=id(14);
  const actorEmployee=user=>id(Number(user.slice(-12))+100);
  pg.query('company_fixture',`SET search_path=tenant_fixture,pg_catalog;
    INSERT INTO "user"(id,tenant_id,is_active,is_deleted) VALUES('${requester}','${tenant}',true,false);
    INSERT INTO employee(id,tenant_id,user_id,department_id,reporting_manager_id,status,is_deleted)
    VALUES('${subject}','${tenant}','${requester}','${department}','${actorEmployee(manager)}','ACTIVE',false);
    INSERT INTO permission(id,resource,action) VALUES('${permission}','leave','approve');`+
    [manager,director,peer,all,outside,requester].map((user,index)=>{
      const role=id(200+index); const employee=actorEmployee(user); const scope=['TEAM','TEAM','DEPARTMENT','ALL','TEAM','ALL'][index];
      return `${user===requester?'':`INSERT INTO "user"(id,tenant_id,is_active,is_deleted) VALUES('${user}','${tenant}',true,false);
      INSERT INTO employee(id,tenant_id,user_id,department_id,reporting_manager_id,status,is_deleted)
      VALUES('${employee}','${tenant}','${user}',${user===peer?`'${department}'`:'NULL'},${user===manager?`'${actorEmployee(director)}'`:'NULL'},'ACTIVE',false);`}
      INSERT INTO role(id,tenant_id,is_deleted) VALUES('${role}','${tenant}',false);
      INSERT INTO user_role(user_id,role_id) VALUES('${user}','${role}');
      INSERT INTO role_permission(role_id,permission_id) VALUES('${role}','${permission}');
      INSERT INTO permission_scope(role_id,tenant_id,resource,action,scope_type) VALUES('${role}','${tenant}','leave','approve','${scope}');`;
    }).join(''));
  const sql=rustConstant('crates/kabipay-common/src/important_email/reviewers.rs','CURRENT_REVIEWER_BATCH_SQL');
  const read=role=>{
    const result=pg.psql('company_fixture',{role,sql:`SET search_path=tenant_fixture,pg_catalog;PREPARE reviewers(uuid,uuid,text,text) AS ${sql};EXECUTE reviewers('${tenant}','${subject}','leave','approve');`});
    assert.equal(result.status,0,result.stderr); return result.stdout.trim().split(/\r?\n/).filter(Boolean).map(row=>row.split('|'));
  };
  for(const role of Object.keys(profiles))assert.deepEqual(read(role).map(row=>row[0]),[manager,director,peer,all]);
  assert.equal(read('hrms_company_leave').find(row=>row[0]===manager)[3],'t');
  pg.query('company_fixture',`DELETE FROM tenant_fixture.role_permission WHERE role_id='${id(200)}';`);
  assert.deepEqual(read('hrms_company_leave').map(row=>row[0]),[director,peer,all],'permission revocation is fresh');
  pg.query('company_fixture',`INSERT INTO tenant_fixture.role_permission(role_id,permission_id) VALUES('${id(200)}','${permission}');
    INSERT INTO tenant_fixture.management_assignment(id,tenant_id,subject_employee_id,manager_employee_id,relationship_type,status,effective_from)
    VALUES('${id(300)}','${tenant}','${subject}',NULL,'PRIMARY','ACTIVE',clock_timestamp()-interval '1 day');`);
  assert.deepEqual(read('hrms_company_leave').map(row=>row[0]),[peer,all],'foreign canonical manager suppresses legacy local TEAM fallback');
  pg.query('company_fixture',`DELETE FROM tenant_fixture.management_assignment;
    INSERT INTO tenant_fixture.employee(id,tenant_id,user_id,status,is_deleted) VALUES('${id(400)}','${tenant}','${all}','ACTIVE',false);
    UPDATE tenant_fixture."user" SET is_active=false WHERE id='${peer}';`);
  assert.deepEqual(read('hrms_company_leave').map(row=>row[0]),[manager,director],'ambiguous employment and disabled accounts are excluded');
  pg.query('company_fixture',`UPDATE tenant_fixture.employee SET user_id='${id(500)}' WHERE id='${actorEmployee(manager)}';`);
  assert.deepEqual(read('hrms_company_leave').map(row=>row[0]),[director],'changed source login cannot reuse old role holder');
});
