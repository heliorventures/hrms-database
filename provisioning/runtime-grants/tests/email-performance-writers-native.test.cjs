// Actual Performance resolver/scheduler transactions; never an application DSN.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,tables,services}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('actual Performance transitions, scheduler, replay and reopen are transactional',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 const profiles=JSON.parse(python('print(json.dumps(e.EMAIL_AUTHORITY_COLUMNS))'));
 const roles=['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'];
 pg.query('postgres',roles.map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_performance_fixture;');
 const full=new Set(['user','user_role','role','role_permission','permission','permission_scope','employee','review_cycle','goal','kpi','performance_program','appraisal_template','appraisal_template_section','appraisal_question','appraisal_question_option','performance_participant','appraisal_answer','continuous_feedback','performance_admin_exception']);
 const thin=Object.values(profiles).map(profile=>Object.fromEntries(Object.entries(profile).filter(([name])=>!full.has(name))));
 // XML-derived disposable adapter for raw tables/columns absent from ORM entities.
 const extras=python(`import xml.etree.ElementTree as E;from pathlib import Path
r=Path(sys.argv[1]).parents[1];ns={'d':'http://www.liquibase.org/xml/ns/dbchangelog'}
for rel in ['0075_performance_appraisal_lifecycle/performance_appraisal_lifecycle.xml','0088_performance_completion/performance_completion.xml']:
 doc=E.parse(r/'changelog/migrations'/rel)
 for node in doc.findall('.//d:createTable',ns):
  name=node.get('tableName')
  if name not in ['performance_program_policy','performance_program_population','performance_participant_revision','performance_audit_event','performance_calibration_decision']:continue
  columns=[]
  for c in node.findall('d:column',ns):
   constraint=c.find('d:constraints',ns);field='"'+c.get('name')+'" '+c.get('type')
   if constraint is not None and constraint.get('primaryKey')=='true':field+=' PRIMARY KEY'
   if constraint is not None and constraint.get('nullable')=='false':field+=' NOT NULL'
   if c.get('defaultValue') is not None:field+=" DEFAULT '"+c.get('defaultValue')+"'"
   columns.append(field)
  print('CREATE TABLE tenant_fixture."'+name+'"('+','.join(columns)+');')
 for node in doc.findall('.//d:addColumn',ns):
  if node.get('tableName')!='review_cycle':continue
  for c in node.findall('d:column',ns):print('ALTER TABLE tenant_fixture.review_cycle ADD COLUMN "'+c.get('name')+'" '+c.get('type')+';')
`);
 const lifecycle=fs.readFileSync(path.join(root,'changelog/migrations/0117_organization_membership_lifecycle/organization_membership_lifecycle.xml'),'utf8');
 const reporting=lifecycle.match(/CREATE OR REPLACE FUNCTION "\$\{schema\}"\.organization_reporting_owned[\s\S]*?\$owned\$;/)[0].replaceAll('${schema}','tenant_fixture');
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 // Existing business fixture rights precede mail tables; these are not proposed mail grants.
 const baseline=`SET search_path=tenant_fixture,pg_catalog;GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_performance,hrms_company_maintenance;GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA tenant_fixture TO hrms_company_performance,hrms_company_maintenance;
 ALTER TABLE performance_participant_revision ADD UNIQUE(performance_participant_id,revision);
 ALTER TABLE review_cycle ADD CONSTRAINT uq_review_cycle_program_period UNIQUE(performance_program_id,period_key);
 ALTER TABLE performance_admin_exception ADD COLUMN dedup_key text;
 CREATE UNIQUE INDEX fixture_exception ON performance_admin_exception(tenant_id,dedup_key) WHERE resolved_at IS NULL AND dedup_key IS NOT NULL;`;
 let seed='';for(const [user,employee]of [[5,2],[10,null],[11,12]]){
  seed+=`INSERT INTO "user"(id,tenant_id,email,username,is_active,is_deleted) VALUES('${id(user)}','${id(1)}','fixture-${user}@example.invalid','fixture-${user}',true,false);`;
  if(employee)seed+=`INSERT INTO employee(id,tenant_id,user_id,employee_code,status,is_deleted,reporting_manager_id) VALUES('${id(employee)}','${id(1)}','${id(user)}','FIXTURE-${employee}','ACTIVE',false,${user===5?`'${id(12)}'`:'NULL'});`;
 }
 for(const [user,permission,action,scope]of [[10,100,'manage','ALL'],[11,101,'evaluate','TEAM']])seed+=`
 INSERT INTO role(id,tenant_id,name,is_deleted) VALUES('${id(user+200)}','${id(1)}','CUSTOM-${user}',false);
 INSERT INTO user_role(user_id,role_id) VALUES('${id(user)}','${id(user+200)}');
 INSERT INTO permission(id,resource,action) VALUES('${id(permission)}','performance','${action}');
 INSERT INTO role_permission(role_id,permission_id) VALUES('${id(user+200)}','${id(permission)}');
 INSERT INTO permission_scope(tenant_id,role_id,resource,action,scope_type) VALUES('${id(1)}','${id(user+200)}','performance','${action}','${scope}');`;
 seed+=`INSERT INTO performance_program(id,tenant_id,name,cadence,anchor_date,status,include_calibration,include_acknowledgement,goal_weight_required,rating_min,rating_max,created_at,updated_at) VALUES('${id(20)}','${id(1)}','Fixture','MANUAL',CURRENT_DATE,'ACTIVE',false,true,100,1,5,now(),now());
 INSERT INTO appraisal_template(id,tenant_id,performance_program_id,version,name,status) VALUES('${id(21)}','${id(1)}','${id(20)}',1,'Fixture','PUBLISHED');
 INSERT INTO appraisal_template_section(id,tenant_id,appraisal_template_id,title) VALUES('${id(22)}','${id(1)}','${id(21)}','Fixture');
 INSERT INTO appraisal_question(id,tenant_id,section_id,question_type,prompt,is_required,answerer,self_rating_enabled,manager_rating_enabled) VALUES('${id(23)}','${id(1)}','${id(22)}','SHORT_TEXT','Fixture',true,'BOTH',false,false);`;
 // Defaults for raw adapter tables are applied before installing constrained mail DDL.
 const defaults=`DO $$ DECLARE c record;BEGIN FOR c IN SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='tenant_fixture' AND data_type='timestamp with time zone' AND is_nullable='NO' AND column_default IS NULL LOOP EXECUTE format('ALTER TABLE tenant_fixture.%I ALTER COLUMN %I SET DEFAULT now()',c.table_name,c.column_name);END LOOP;END $$;`;
 fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),tables('tenant_fixture',thin).replace('CREATE SCHEMA "tenant_fixture";','')+extras+reporting+baseline+defaults+schema+python('print(e.grants_sql("tenant_fixture"));print(e.authority_grants_sql("tenant_fixture"))')+seed,{flag:'wx',mode:0o600});
 const config=path.join(pg.directory,'owned-email-writers-fixture.json');fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),data_directory:path.join(pg.directory,'data'),database:'company_email_performance_fixture'}),{flag:'wx',mode:0o600});
 const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
 const result=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-performance','--lib','owned_performance_transitions_replay_scheduler_reopen_and_rollback','--','--ignored','--exact','resolvers::concurrency_tests::email_owned_tests::owned_performance_transitions_replay_scheduler_reopen_and_rollback','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});
 assert.equal(result.status,0,(result.stderr||'')+(result.stdout||''));assert.match(result.stdout,/test result: ok\. 1 passed/);
});
