const {test}=require('node:test');
const assert=require('node:assert/strict');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,rustConstant,tables}=require('./email-native-support.cjs');
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('installed organization reviewers require matching live metadata and verified current source employment in one batch',async t=>{
 const profiles=JSON.parse(python('print(json.dumps({"source":e.EMAIL_AUTHORITY_COLUMNS,"metadata":e.EMAIL_METADATA_COLUMNS["kabipay-leave"]}))'));
 const pg=await fixture();t.after(()=>pg.stop());
 const meta='hrms_fixture_metadata_leave';const login='hrms_company_leave';
 pg.query('postgres',Object.keys(profiles.source).map(role=>`CREATE ROLE ${role} LOGIN NOINHERIT;`).join('')+`CREATE ROLE ${meta} LOGIN NOINHERIT;CREATE DATABASE company_fixture;`);
 pg.query('company_fixture',tables('tenant_fixture',Object.values(profiles.source))+tables('kabipay_ops',[profiles.metadata])+
   python(`print(e.authority_grants_sql('tenant_fixture'));print(e.metadata_grants_sql('${meta}','kabipay-leave'))`));
 const tenant=id(1),source=id(2),org=id(3),member=id(4),sourceMember=id(5),principal=id(6),subjectPrincipal=id(7),subject=id(8),actor=id(9),user=id(10),subjectUser=id(11),grant=id(12),role=id(13),relation=id(14),actorRef=id(15),subjectRef=id(16);
 const cap='leave:approve';
 pg.query('company_fixture',`SET search_path=tenant_fixture,pg_catalog;
 INSERT INTO organization_membership_installation(tenant_id,organization_id,membership_id,version,status) VALUES('${tenant}','${org}','${member}',1,'ACTIVE');
 INSERT INTO organization_grant_installation(tenant_id,binding_id,organization_id,membership_id,principal_id,grant_version,membership_version,status,capabilities)
 VALUES('${tenant}','${grant}','${org}','${member}','${principal}',1,1,'ACTIVE','[{"code":"${cap}","employee_scope":"ALL"}]');
 INSERT INTO management_assignment(id,tenant_id,organization_id,membership_id,subject_employee_id,subject_principal_id,manager_principal_id,version,relationship_type,status,effective_from)
 VALUES('${relation}','${tenant}','${org}','${member}','${subject}','${subjectPrincipal}','${principal}',2,'PRIMARY','ACTIVE',clock_timestamp()-interval '1 day');
 INSERT INTO assignment_capability(tenant_id,assignment_id,capability_code) VALUES('${tenant}','${relation}','${cap}');
 SET search_path=kabipay_ops,pg_catalog;
 INSERT INTO tenant(id,status,is_deleted) VALUES('${tenant}','ACTIVE',false),('${source}','ACTIVE',false);
 INSERT INTO organization(id,status) VALUES('${org}','ACTIVE');
 INSERT INTO principal(id,status) VALUES('${principal}','ACTIVE'),('${subjectPrincipal}','ACTIVE');
 INSERT INTO organization_company(id,organization_id,tenant_id,status,version,installed_version,runtime_status,effective_from)
 VALUES('${member}','${org}','${tenant}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day'),('${sourceMember}','${org}','${source}','ACTIVE',1,1,'ACTIVE',clock_timestamp()-interval '1 day');
 INSERT INTO employment_ref(id,organization_id,organization_company_id,principal_id,source_tenant_id,source_employee_id,source_user_id,employment_status)
 VALUES('${actorRef}','${org}','${sourceMember}','${principal}','${source}','${actor}','${user}','ACTIVE'),('${subjectRef}','${org}','${member}','${subjectPrincipal}','${tenant}','${subject}','${subjectUser}','ACTIVE');
 INSERT INTO principal_login_link(principal_id,source_tenant_id,source_user_id,issuer,status) VALUES('${principal}','${source}','${user}','kabipay-client','VERIFIED');
 INSERT INTO organization_role(id,organization_id,status) VALUES('${role}','${org}','ACTIVE');
 INSERT INTO principal_role_binding(id,organization_id,principal_id,version,status,role_id,effective_from) VALUES('${grant}','${org}','${principal}',1,'ACTIVE','${role}',clock_timestamp()-interval '1 day');
 INSERT INTO organization_role_capability(role_id,organization_id,capability_code,employee_scope) VALUES('${role}','${org}','${cap}','ALL');
 INSERT INTO role_binding_company(binding_id,organization_id,organization_company_id,activation_status,expected_grant_version) VALUES('${grant}','${org}','${member}','ACTIVE',1);
 INSERT INTO organization_relationship(id,organization_id,organization_company_id,manager_employment_ref_id,subject_employment_ref_id,version,installed_version,status,effective_from,capabilities,relationship_type)
 VALUES('${relation}','${org}','${member}','${actorRef}','${subjectRef}',2,2,'ACTIVE',clock_timestamp()-interval '1 day','["${cap}"]','PRIMARY');`);
 const installed=rustConstant('crates/kabipay-organization-tenant/src/email_reviewers.rs','EMAIL_INSTALLED_REVIEWERS_SQL');
 const metadata=rustConstant('crates/kabipay-organization-tenant/src/email_reviewers.rs','EMAIL_METADATA_REVIEWERS_SQL');
 const run=(role,sql)=>{const r=pg.psql('company_fixture',{role,sql:'SET search_path=tenant_fixture,pg_catalog;'+sql});assert.equal(r.status,0,r.stderr);return r.stdout.trim().split(/\r?\n/).filter(Boolean).map(r=>r.split('|'));};
 const read=()=>{
   const rows=run(login,`PREPARE installed(uuid,uuid,text) AS ${installed};EXECUTE installed('${tenant}','${subject}','${cap}');`);
   const keys=['organization_id','membership_id','principal_id','authority_id','authority_version','membership_version','relationship','scope','source_is_reporting_manager'];
   const candidates=rows.map(row=>Object.fromEntries(keys.map((key,i)=>[key,key.endsWith('version')?Number(row[i]):['relationship','source_is_reporting_manager'].includes(key)?row[i]==='t':row[i]])));
   return run(meta,`PREPARE metadata(jsonb,uuid,uuid,text) AS ${metadata};EXECUTE metadata('${JSON.stringify(candidates)}','${tenant}','${subject}','${cap}');`);
 };
 assert.equal(read().length,2);assert(read().every(r=>r[7]===source&&r[8]===actor&&r[9]==='t'));
 for(const [change,restore,count] of [
   [`UPDATE principal_role_binding SET version=2`,`UPDATE principal_role_binding SET version=1`,1],
   [`UPDATE employment_ref SET source_user_id='${id(30)}' WHERE id='${actorRef}'`,`UPDATE employment_ref SET source_user_id='${user}' WHERE id='${actorRef}'`,0],
   [`UPDATE organization_company SET runtime_status='PENDING' WHERE id='${sourceMember}'`,`UPDATE organization_company SET runtime_status='ACTIVE' WHERE id='${sourceMember}'`,0],
   [`UPDATE organization_company SET status='SUSPENDED' WHERE id='${member}'`,`UPDATE organization_company SET status='ACTIVE' WHERE id='${member}'`,0],
   [`UPDATE organization_relationship SET version=3`,`UPDATE organization_relationship SET version=2`,1],
   [`UPDATE employment_ref SET principal_id='${principal}' WHERE id='${subjectRef}'`,`UPDATE employment_ref SET principal_id='${subjectPrincipal}' WHERE id='${subjectRef}'`,0],
 ]){pg.query('company_fixture','SET search_path=kabipay_ops;'+change);assert.equal(read().length,count,change);pg.query('company_fixture','SET search_path=kabipay_ops;'+restore);assert.equal(read().length,2);}
 pg.query('company_fixture',`UPDATE tenant_fixture.management_assignment SET relationship_type='DOTTED';`);
 assert(read().every(r=>r[9]==='f'),'metadata alone cannot invent an installed canonical manager');
});
