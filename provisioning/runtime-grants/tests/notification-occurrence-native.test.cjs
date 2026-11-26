// Owned loopback database, actual application occurrence SQL, no live DSN.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {Client}=require('pg');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const directory=path.resolve(__dirname,'..');
function compile(mode,target,before){
 const code="import sys,json;sys.path.insert(0,sys.argv[1]);import online_notification_columns as m;d=json.load(sys.stdin);print(m.snapshot_sql(d['target']) if sys.argv[2]=='snapshot' else m.guarded_sql(d['target'],d['before']))";
 const python=process.env.RUNTIME_GRANTS_PYTHON||(process.platform==='win32'?'py':'python3');
 const args=process.platform==='win32'&&path.basename(python).toLowerCase().replace(/\.exe$/,'')==='py'?['-3']:[];
 return spawnSync(python,[...args,'-c',code,directory,mode],{input:JSON.stringify({target,before}),encoding:'utf8',windowsHide:true,timeout:20000});
}
test('maintenance occurrence correction admits real idempotent SQL without broader rights or orphan notifications',async t=>{
 const pg=await fixture();let client;t.after(async()=>{if(client)await client.end();pg.stop();});
 pg.query('postgres','CREATE DATABASE company_fixture; CREATE ROLE hrms_company_maintenance LOGIN NOINHERIT; CREATE ROLE unrelated_reader LOGIN NOINHERIT;');
 pg.query('company_fixture',`CREATE SCHEMA tenant_fixture;
 CREATE TABLE tenant_fixture.notification(id uuid PRIMARY KEY,tenant_id uuid,user_id uuid,type text,title text,message text,action_url text,is_read boolean,read_at timestamptz,created_at timestamptz,updated_at timestamptz);
 CREATE TABLE tenant_fixture.automated_notification_occurrence(id uuid PRIMARY KEY,tenant_id uuid NOT NULL,event_type text NOT NULL,
 employee_id uuid NOT NULL,event_date date NOT NULL,recipient_user_id uuid NOT NULL,notification_id uuid NOT NULL REFERENCES tenant_fixture.notification(id),created_at timestamptz NOT NULL,
 UNIQUE(tenant_id,event_type,employee_id,event_date,recipient_user_id));
 CREATE TABLE tenant_fixture.unrelated(secret text);
 GRANT USAGE ON SCHEMA tenant_fixture TO hrms_company_maintenance,unrelated_reader;
 GRANT SELECT,INSERT ON tenant_fixture.notification TO hrms_company_maintenance;
 GRANT INSERT(id,tenant_id,event_type,employee_id,event_date,recipient_user_id,notification_id,created_at),SELECT(id) ON tenant_fixture.automated_notification_occurrence TO hrms_company_maintenance;`);
 const source=fs.readFileSync(path.resolve(__dirname,'../../../../hrms-svc/crates/kabipay-notification/src/services/automated_events.rs'),'utf8');
 const occurrence=/r#"(INSERT INTO automated_notification_occurrence[\s\S]*?RETURNING id)"#/.exec(source)?.[1];
 assert(occurrence,'actual occurrence SQL missing');
 const target={systemId:pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),database:'company_fixture',schema:'tenant_fixture'};
 const snapshot=()=>{const r=compile('snapshot',target);assert.equal(r.status,0,r.stderr);return JSON.parse(pg.query('company_fixture',r.stdout));};
 client=new Client(pg.connection('company_fixture','hrms_company_maintenance'));await client.connect();
 await client.query('SET search_path=tenant_fixture');
 const id=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
 async function deliver(number){
  await client.query('BEGIN');
  try{
   await client.query('INSERT INTO notification(id,tenant_id) VALUES($1,$2)',[id(number),id(2)]);
   const result=await client.query(occurrence,[id(number+100),id(2),'EMPLOYEE_BIRTHDAY',id(3),'2026-11-27',id(4),id(number),new Date('2026-11-27T00:00:00Z')]);
   await client.query(result.rowCount?'COMMIT':'ROLLBACK');return result.rowCount;
  }catch(error){await client.query('ROLLBACK');throw error;}
 }
 await assert.rejects(deliver(10),error=>error.code==='42501');
 assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.notification').trim(),'0');
 const before=snapshot(),compiled=compile('apply',target,before);assert.equal(compiled.status,0,compiled.stderr);
 assert.equal(pg.psql('company_fixture',{sql:compiled.stdout}).status,0);
 const after=snapshot();assert(after.required.every(Boolean));assert.equal(after.invariantsSha256,before.invariantsSha256);
 assert.equal(await deliver(11),1);assert.equal(await deliver(12),0);
 assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.notification').trim(),'1');
 assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.automated_notification_occurrence').trim(),'1');
 for(const sql of ['SELECT notification_id FROM automated_notification_occurrence','SELECT created_at FROM automated_notification_occurrence',
  'UPDATE automated_notification_occurrence SET event_type=event_type','DELETE FROM automated_notification_occurrence','SELECT * FROM unrelated'])
  await assert.rejects(client.query(sql),error=>error.code==='42501');
 assert.notEqual(pg.psql('company_fixture',{role:'unrelated_reader',sql:'SELECT id FROM tenant_fixture.automated_notification_occurrence'}).status,0);
 const repeat=compile('apply',target,after);assert.equal(repeat.status,0);assert.equal(pg.psql('company_fixture',{sql:repeat.stdout}).status,0);
 const stale=compile('apply',target,snapshot());assert.equal(stale.status,0);
 pg.query('company_fixture','ALTER TABLE tenant_fixture.automated_notification_occurrence ADD COLUMN changed text');
 assert.notEqual(pg.psql('company_fixture',{sql:stale.stdout}).status,0,'catalog drift refuses stale plan');
 assert.notEqual(compile('apply',{...target,systemId:'999'},after).status,0,'wrong cluster refuses plan');
});
