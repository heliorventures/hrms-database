const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {fixture}=require('./local-postgres-fixture.cjs');
const root=path.resolve(__dirname,'../../..');
const source=fs.readFileSync(path.join(root,'changelog/migrations/0125_private_event_source/private_event_source.xml'),'utf8');
const scopeA='11111111-1111-4111-8111-111111111111',scopeB='22222222-2222-4222-8222-222222222222';
const approved='["company_a","company_b"]';
const encodedList=value=>'runtime_databases_b64='+Buffer.from(value,'utf8').toString('base64');
function ddl(schema,text=source,names=['private_source_cutover','private_delivery_receipt','private_domain_receipt','private_survey_execution_state','private_legacy_export'],prefix='"${schema}"') {
  return names.map(name=>{
    const start=text.indexOf('CREATE TABLE '+prefix+'.'+name+' (');assert(start>=0,name);
    const end=text.indexOf('\n);',start);assert(end>start,name);
    return text.slice(start,end+3).replaceAll('${schema}',schema);
  }).join('\n');
}
test('shared role bootstraps two databases while retaining registry, CONNECT and protected-column boundaries',{timeout:240000},async()=>{
  const pg=await fixture();
  function template(database,name,variables,error) {
    const result=pg.psql(database,{file:path.join(__dirname,'..',name+'.template.sql'),variables});
    if(error) {assert.notEqual(result.status,0);assert.match(result.stderr,error);}
    else assert.equal(result.status,0,result.stderr);
    return result;
  }
  function company(database,scope,schema,list=approved,error) {
    return template(database,'company',[`database=${database}`,`scope_id=${scope}`,`source_schema=${schema}`,
      'runtime_role=shared_runtime','bootstrap_mode=empty','producer_generation=1',encodedList(list)],error);
  }
  function registration(list=approved,error) {
    return template('postgres','registration',['registry_database=postgres','database=company_a',`scope_id=${scopeA}`,
      'source_schema=tenant_a','runtime_host=postgres-company',encodedList(list)],error);
  }
  try {
    pg.query('postgres',`CREATE DATABASE company_a; CREATE DATABASE company_b; CREATE DATABASE unrelated_product;
REVOKE CONNECT ON DATABASE postgres,template1,company_a,company_b,unrelated_product FROM PUBLIC;
CREATE ROLE shared_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE extra_privilege;
GRANT CONNECT ON DATABASE company_a,company_b TO shared_runtime;
CREATE SCHEMA kabipay_ops;
CREATE TABLE kabipay_ops.tenant(id uuid PRIMARY KEY,is_deleted boolean,status text);
CREATE TABLE kabipay_ops.tenant_database(tenant_id uuid,db_type text,db_host text,db_name text,schema_name text,is_active boolean);
INSERT INTO kabipay_ops.tenant VALUES('${scopeA}',false,'ACTIVE'),('${scopeB}',false,'SUSPENDED');
INSERT INTO kabipay_ops.tenant_database VALUES('${scopeA}','POSTGRES','postgres-company','company_a','tenant_a',true),
('${scopeB}','POSTGRES','postgres-company','company_b','tenant_b',true);`);
    for(const [database,schema] of [['company_a','tenant_a'],['company_b','tenant_b']]) {
      pg.query(database,`CREATE SCHEMA ${schema};
CREATE TABLE ${schema}."user"(id uuid,tenant_id uuid); CREATE TABLE ${schema}.employee(id uuid,tenant_id uuid);
CREATE TABLE ${schema}.survey(id uuid,tenant_id uuid,UNIQUE(tenant_id,id));
CREATE TABLE ${schema}.company_event_outbox(id uuid,source_tenant_id uuid,organization_id uuid,event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz,source_position bigserial);
CREATE TABLE ${schema}.audit_log(id uuid); CREATE TABLE ${schema}.outbox_event(id uuid);
CREATE TABLE ${schema}.webhook_delivery_log(id uuid); CREATE TABLE ${schema}.employee_finance_outbox(id uuid);
CREATE TABLE ${schema}.business_preserved(id integer); GRANT SELECT ON ${schema}.business_preserved TO shared_runtime;
${ddl(schema)}`);
    }
    registration();
    company('company_a',scopeA,'tenant_a'); company('company_b',scopeB,'tenant_b');
    company('company_a',scopeA,'tenant_a'); // Idempotent re-application.
    for(const [database,schema,scope] of [['company_a','tenant_a',scopeA],['company_b','tenant_b',scopeB]]) {
      const read=pg.psql(database,{role:'shared_runtime',sql:`SELECT tenant_id FROM ${schema}.private_source_cutover; SELECT * FROM ${schema}.business_preserved;`});
      assert.equal(read.status,0,read.stderr);assert.match(read.stdout,new RegExp(scope));
      const denied=pg.psql(database,{role:'shared_runtime',sql:`UPDATE ${schema}.private_source_cutover SET producer_generation=2;`});
      assert.notEqual(denied.status,0);assert.match(denied.stderr,/permission denied/);
      assert.equal(pg.query(database,`SELECT state||':'||writers_fenced FROM ${schema}.private_source_cutover;`).trim(),'PREPARED:false');
    }
    company('company_a',scopeA,'tenant_a','[]',/CONNECT/); // Default remains isolated.
    pg.query('company_a','GRANT UPDATE(producer_generation) ON tenant_a.private_source_cutover TO shared_runtime;');
    company('company_a',scopeA,'tenant_a',approved,/Unexpected private runtime effective column privileges/);
    pg.query('company_a','REVOKE UPDATE(producer_generation) ON tenant_a.private_source_cutover FROM shared_runtime;');
    pg.query('company_a','UPDATE tenant_a.private_source_cutover SET reader_switch_complete=true;');
    company('company_a',scopeA,'tenant_a',approved,/Existing source authority differs or advanced/);
    pg.query('company_a','UPDATE tenant_a.private_source_cutover SET reader_switch_complete=false;');
    company('company_a',scopeA,'tenant_a','["company_a","missing_company"]',/does not exist|unavailable/);
    for(const list of ['{}','[null]','["company_a","company_a"]','["company_b"]','["company_a","postgres"]']) {
      company('company_a',scopeA,'tenant_a',list,/database list|database allowlist/);
    }
    template('company_a','operator',['database=company_a',`scope_id=${scopeA}`,'source_schema=kabipay_ops',
      'runtime_role=shared_runtime','bootstrap_mode=empty','producer_generation=1',encodedList(approved)],/company|Operator/);
    pg.query('postgres','GRANT CONNECT ON DATABASE unrelated_product TO PUBLIC;');
    company('company_a',scopeA,'tenant_a',approved,/CONNECT/);
    pg.query('postgres','REVOKE CONNECT ON DATABASE unrelated_product FROM PUBLIC; GRANT extra_privilege TO shared_runtime;');
    company('company_a',scopeA,'tenant_a',approved,/cannot inherit/);
    pg.query('postgres','REVOKE extra_privilege FROM shared_runtime;');
    const denied=pg.psql('unrelated_product',{role:'shared_runtime',sql:'SELECT 1;'});
    assert.notEqual(denied.status,0);assert.match(denied.stderr,/permission denied/);
    // Successful legacy isolated-company and operator paths must keep working.
    pg.query('postgres','CREATE ROLE isolated_runtime LOGIN; CREATE ROLE metadata_runtime LOGIN;');
    template('company_a','company',['database=company_a',`scope_id=${scopeA}`,'source_schema=tenant_a',
      'runtime_role=isolated_runtime','bootstrap_mode=empty','producer_generation=1']);
    assert.equal(pg.query('postgres',"SELECT has_database_privilege('isolated_runtime','company_a','CONNECT') AND NOT has_database_privilege('isolated_runtime','company_b','CONNECT');").trim(),'t');
    const control=fs.readFileSync(path.join(root,'changelog/migrations/0124_private_event_control/private_event_control.xml'),'utf8');
    pg.query('postgres',`CREATE TABLE kabipay_ops.organization_outbox(id uuid,organization_id uuid,source_tenant_id uuid,actor_principal_id uuid,aggregate_id uuid,aggregate_version bigint,event_type text,schema_version integer,payload jsonb,event_stream text,created_at timestamptz,source_position bigserial);
CREATE TABLE kabipay_ops.operator_audit_log(id uuid);
${ddl('kabipay_ops',control,['private_source_cutover','private_legacy_export'],'kabipay_ops')}`);
    template('postgres','operator',['database=postgres',`scope_id=${scopeA}`,'source_schema=kabipay_ops',
      'runtime_role=metadata_runtime','bootstrap_mode=empty','producer_generation=1']);
    assert.equal(pg.query('postgres',"SELECT has_database_privilege('metadata_runtime','postgres','CONNECT') AND NOT has_database_privilege('metadata_runtime','company_a','CONNECT');").trim(),'t');
    registration('["company_a","unrelated_product"]',/registered company database/);
    pg.query('postgres',`UPDATE kabipay_ops.tenant_database SET db_host='wrong-host' WHERE db_name='company_b';`);
    registration(approved,/registered company database/);
    pg.query('postgres',`UPDATE kabipay_ops.tenant_database SET db_host='postgres-company' WHERE db_name='company_b'; UPDATE kabipay_ops.tenant SET is_deleted=true WHERE id='${scopeB}';`);
    registration(approved,/registered company database/);
    pg.query('postgres',`UPDATE kabipay_ops.tenant SET is_deleted=false WHERE id='${scopeB}';
INSERT INTO kabipay_ops.tenant_database SELECT * FROM kabipay_ops.tenant_database WHERE db_name='company_b';`);
    registration(approved,/registered company database/);
  } finally {pg.stop();console.log('Owned synthetic fixture retained: '+pg.directory);}
});
