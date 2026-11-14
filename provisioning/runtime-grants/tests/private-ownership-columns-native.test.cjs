// Owned loopback PostgreSQL and synthetic receipts only; no .env or live DSNs.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
function compile(mode,target,before){
 const code="import sys,json;sys.path.insert(0,sys.argv[1]);import online_private_ownership_columns as m;v=json.load(sys.stdin);print(m.snapshot_sql(v['target']) if sys.argv[2]=='snapshot' else m.guarded_sql(v['target'],v['before']))";
 const python=process.env.RUNTIME_GRANTS_PYTHON||'py';
 const args=process.platform==='win32'&&path.basename(python).toLowerCase().replace(/\.exe$/,'')==='py'?['-3']:[];
 return spawnSync(python,[...args,'-c',code,directory,mode],{input:JSON.stringify({target,before}),encoding:'utf8',windowsHide:true,timeout:60000});
}
test('broker ownership exact reads/writes work while receipt identity and existing ownership stay protected',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres','CREATE DATABASE company_fixture; CREATE ROLE hrms_company_employee LOGIN NOINHERIT; CREATE ROLE hrms_company_leave LOGIN NOINHERIT;');
 const migration=fs.readFileSync(path.resolve(directory,'../../changelog/migrations/0125_private_event_source/private_event_source.xml'),'utf8');
 const table=migration.match(/CREATE TABLE "\$\{schema\}"\.private_delivery_receipt[\s\S]*?\n\);/);
 const guard=migration.match(/CREATE FUNCTION "\$\{schema\}"\.private_receipt_guard[\s\S]*?CREATE TRIGGER private_receipt_guard[^;]+;/);
 assert(table&&guard,'retain actual receipt DDL and immutable-ownership trigger');
 const replace=s=>s.replaceAll('${schema}','tenant_fixture');
 pg.query('company_fixture',`CREATE SCHEMA tenant_fixture; GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_employee,hrms_company_leave;
 ${replace(table[0])}
 CREATE TABLE tenant_fixture.private_source_cutover(tenant_id uuid PRIMARY KEY,producer_generation bigint);
 ${replace(guard[0])}
 GRANT SELECT(tenant_id,intent_id,destination_id,intent_hash,destination_version,source_generation) ON tenant_fixture.private_delivery_receipt TO hrms_company_employee;
 GRANT UPDATE(updated_at) ON tenant_fixture.private_delivery_receipt TO hrms_company_employee;
 INSERT INTO tenant_fixture.private_delivery_receipt(tenant_id,intent_id,destination_id,source_kind,resource_id,intent_hash,destination_version,source_generation,status)
 VALUES('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000003','notification','00000000-0000-4000-8000-000000000004',repeat('a',64),1,1,'NO_DESTINATION');`);
 const target={systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture'};
 function snapshot(){const c=compile('snapshot',target);assert.equal(c.status,0,c.stderr);return JSON.parse(pg.query('company_fixture',c.stdout));}
 const read='SELECT intent_hash,destination_version,source_generation,broker_owned_at,broker_owner_id,broker_receipt_sha256 FROM tenant_fixture.private_delivery_receipt FOR UPDATE';
 const write="UPDATE tenant_fixture.private_delivery_receipt SET broker_owned_at=clock_timestamp(),broker_owner_id='00000000-0000-4000-8000-000000000005',broker_receipt_sha256=repeat('b',64),updated_at=clock_timestamp()";
 for(const sql of [read,write])assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_employee',sql}).status,0,'reproduce missing real ownership access');
 const before=snapshot();assert.equal(before.required.length,13);assert.equal(before.required.filter(v=>!v).length,6);
 const compiled=compile('apply',target,before);assert.equal(compiled.status,0,compiled.stderr);
 assert.equal((compiled.stdout.match(/^GRANT /gm)||[]).length,13);
 assert.equal(pg.psql('company_fixture',{sql:compiled.stdout}).status,0);
 const after=snapshot();assert.deepEqual(after,{...before,required:Array(13).fill(true)});
 assert.equal(pg.psql('company_fixture',{role:'hrms_company_employee',sql:`BEGIN; ${read}; ${write}; COMMIT;`}).status,0,'actual authenticated-handler receipt SQL works');
 assert.equal(pg.query('company_fixture',"SELECT status||':'||(broker_owned_at IS NOT NULL)::text FROM tenant_fixture.private_delivery_receipt").trim(),'NO_DESTINATION:true','broker ownership does not change receiver outcome');
 const row=pg.query('company_fixture','TABLE tenant_fixture.private_delivery_receipt');
 assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_employee',sql:"UPDATE tenant_fixture.private_delivery_receipt SET broker_owner_id='00000000-0000-4000-8000-000000000006'"}).status,0,'existing proof remains immutable');
 assert.equal(pg.query('company_fixture','TABLE tenant_fixture.private_delivery_receipt'),row);
 for(const sql of ['DELETE FROM tenant_fixture.private_delivery_receipt','UPDATE tenant_fixture.private_delivery_receipt SET source_generation=2','UPDATE tenant_fixture.private_delivery_receipt SET intent_hash=repeat(\'c\',64)'])
  assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_employee',sql}).status,0,'no deletion or immutable identity authority added');
 assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_leave',sql:'SELECT broker_owner_id FROM tenant_fixture.private_delivery_receipt'}).status,0,'other service receives no ownership read');
 assert.equal(pg.query('company_fixture',"SELECT has_table_privilege('hrms_company_employee','tenant_fixture.private_delivery_receipt','UPDATE')").trim(),'f','no table-wide UPDATE');
 assert.equal(pg.query('company_fixture',"SELECT has_column_privilege('hrms_company_employee','tenant_fixture.private_delivery_receipt','broker_owner_id','UPDATE WITH GRANT OPTION')").trim(),'f','no grant option');
 assert.notEqual(pg.psql('company_fixture',{sql:compiled.stdout}).status,0,'stale before-state refuses replay');
 pg.query('company_fixture','REVOKE UPDATE(broker_owner_id) ON tenant_fixture.private_delivery_receipt FROM hrms_company_employee');
 const fresh=snapshot(),pending=compile('apply',target,fresh);assert.equal(pending.status,0,pending.stderr);
 pg.query('company_fixture','ALTER TABLE tenant_fixture.private_delivery_receipt ADD COLUMN drift text');
 assert.notEqual(pg.psql('company_fixture',{sql:pending.stdout}).status,0,'catalog drift refuses the transaction');
 assert.equal(pg.query('company_fixture',"SELECT has_column_privilege('hrms_company_employee','tenant_fixture.private_delivery_receipt','broker_owner_id','UPDATE')").trim(),'f','failed guard leaves missing right absent');
});
