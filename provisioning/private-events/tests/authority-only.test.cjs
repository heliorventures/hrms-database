const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {fixture}=require('./local-postgres-fixture.cjs');
const root=path.resolve(__dirname,'../../..');
const source=fs.readFileSync(path.join(root,'changelog/migrations/0125_private_event_source/private_event_source.xml'),'utf8');
const tenant='11111111-1111-4111-8111-111111111111';
function table(name) {
  const start=source.indexOf('CREATE TABLE "${schema}".'+name+' (');assert(start>=0,name);
  const end=source.indexOf('\n);',start);assert(end>start);
  return source.slice(start,end+3).replaceAll('${schema}','source');
}
test('authority-only initializes without publishing ACLs and retains canonical source guards',{timeout:120000},async()=>{
  const pg=await fixture();
  function company(extra=[],error) {
    const result=pg.psql('postgres',{file:path.join(__dirname,'../company.template.sql'),variables:[
      'database=postgres',`scope_id=${tenant}`,'source_schema=source','runtime_role=runtime_role',
      'bootstrap_mode=empty','producer_generation=1','permission_mode=authority-only',...extra]});
    if(error){assert.notEqual(result.status,0);assert.match(result.stderr,error);}
    else assert.equal(result.status,0,result.stderr);
    return result;
  }
  function acl() {
    return pg.query('postgres',`SELECT jsonb_build_object('connect',has_database_privilege('runtime_role',current_database(),'CONNECT'),'schema',has_schema_privilege('runtime_role','source','USAGE'),'relations',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'acl',c.relacl,'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'acl',a.attacl) ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='source'));`);
  }
  try {
    pg.query('postgres',`REVOKE CONNECT ON DATABASE postgres,template1 FROM PUBLIC;
CREATE ROLE runtime_role LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE SCHEMA source;
CREATE TABLE source."user"(id uuid,tenant_id uuid); CREATE TABLE source.employee(id uuid,tenant_id uuid);
CREATE TABLE source.survey(id uuid,tenant_id uuid,UNIQUE(tenant_id,id));
CREATE TABLE source.company_event_outbox(id uuid,source_tenant_id uuid,organization_id uuid,event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz,source_position bigserial);
CREATE TABLE source.audit_log(id uuid);CREATE TABLE source.outbox_event(id uuid);
CREATE TABLE source.webhook_delivery_log(id uuid);CREATE TABLE source.employee_finance_outbox(id uuid);
CREATE TABLE source.business_preserved(id integer);GRANT SELECT ON source.business_preserved TO runtime_role;
${['private_source_cutover','private_delivery_receipt','private_domain_receipt','private_survey_execution_state','private_legacy_export'].map(table).join('\n')}`);
    const before=acl();
    company(['bootstrap_mode=existing'],/inventory classification/);
    company();
    assert.equal(acl(),before,'authority-only must not publish any table/column/schema/database/sequence ACL');
    assert.equal(pg.query('postgres','SELECT state||\':\'||producer_generation||\':\'||writers_fenced FROM source.private_source_cutover').trim(),'PREPARED:1:false');
    company();assert.equal(acl(),before,'authority-only reapplication must preserve ACLs');
    company(['permission_mode=invalid'],/permission mode/);
    company(['permission_mode='],/permission mode/);
    company(['producer_generation=2'],/differs or advanced/);
    company(['scope_id=22222222-2222-4222-8222-222222222222'],/another scope/);
    pg.query('postgres','UPDATE source.private_source_cutover SET reader_switch_complete=true');
    company([],/differs or advanced/);
    pg.query('postgres','UPDATE source.private_source_cutover SET reader_switch_complete=false;GRANT UPDATE(producer_generation) ON source.private_source_cutover TO runtime_role');
    company([],/Unexpected private runtime effective column privileges/);
    pg.query('postgres','REVOKE UPDATE(producer_generation) ON source.private_source_cutover FROM runtime_role;GRANT UPDATE ON SEQUENCE source.company_event_outbox_source_position_seq TO runtime_role');
    company([],/cannot reset source publication sequence/);
    pg.query('postgres','REVOKE UPDATE ON SEQUENCE source.company_event_outbox_source_position_seq FROM runtime_role');
    // The explicit compatibility profile and omitted default retain historical grants.
    company(['permission_mode=runtime']);
    assert.equal(pg.query('postgres',"SELECT has_database_privilege('runtime_role',current_database(),'CONNECT') AND has_schema_privilege('runtime_role','source','USAGE') AND has_table_privilege('runtime_role','source.private_source_cutover','SELECT') AND has_sequence_privilege('runtime_role','source.company_event_outbox_source_position_seq','USAGE')").trim(),'t');
    const control=fs.readFileSync(path.join(root,'changelog/migrations/0124_private_event_control/private_event_control.xml'),'utf8');
    const controlTables=['private_source_cutover','private_legacy_export'].map(name=>{
      const start=control.indexOf('CREATE TABLE kabipay_ops.'+name+' (');assert(start>=0,name);
      return control.slice(start,control.indexOf('\n);',start)+3);
    }).join('\n');
    pg.query('postgres',`CREATE ROLE operator_runtime LOGIN;CREATE SCHEMA kabipay_ops;
CREATE TABLE kabipay_ops.operator_audit_log(id uuid);
CREATE TABLE kabipay_ops.organization_outbox(id uuid,organization_id uuid,source_tenant_id uuid,actor_principal_id uuid,aggregate_id uuid,aggregate_version bigint,event_type text,schema_version integer,payload jsonb,event_stream text,created_at timestamptz,source_position bigserial);
${controlTables}`);
    const operator=pg.psql('postgres',{file:path.join(__dirname,'../operator.template.sql'),variables:[
      'database=postgres','scope_id=22222222-2222-4222-8222-222222222222','source_schema=kabipay_ops',
      'runtime_role=operator_runtime','bootstrap_mode=empty','producer_generation=1','permission_mode=authority-only']});
    assert.equal(operator.status,0,operator.stderr);
    assert.equal(pg.query('postgres',"SELECT has_database_privilege('operator_runtime',current_database(),'CONNECT') OR has_schema_privilege('operator_runtime','kabipay_ops','USAGE') OR has_table_privilege('operator_runtime','kabipay_ops.private_source_cutover','SELECT') OR has_sequence_privilege('operator_runtime','kabipay_ops.organization_outbox_source_position_seq','USAGE')").trim(),'f');
    assert.equal(pg.query('postgres','SELECT source_schema FROM kabipay_ops.private_source_cutover').trim(),'kabipay_ops');
  } finally {pg.stop();console.log('Owned authority-only fixture retained: '+pg.directory);}
});
