// Mail state invariants under the exact Notification login; owned loopback only.
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const {python,rustConstant}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('database refuses unsafe delivery resets, identity changes and a third active lease',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());
 pg.query('postgres',['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'].map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_fixture;');
 const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}',id(1));
 pg.query('company_fixture','CREATE SCHEMA tenant_fixture;'+schema+python('print(e.grants_sql("tenant_fixture"))'));
 const as=sql=>pg.psql('company_fixture',{role:'hrms_company_notification',sql:'SET search_path=tenant_fixture,pg_catalog;'+sql});
 assert.equal(as(`UPDATE tenant_email_settings SET enabled=true,enabled_after=clock_timestamp()-interval '1 day',categories='{"leave":true}',category_cutoffs=jsonb_build_object('leave',clock_timestamp()-interval '1 day'),credential_cipher=decode(repeat('aa',17),'hex'),credential_nonce=decode(repeat('bb',12),'hex'),credential_key_id='fixture',version=version+1;`).status,0);
 const moment=new Date().toISOString(),expiry=new Date(Date.now()+86400000).toISOString();
 const body=n=>({tenant_id:id(1),event_id:id(n+100),resource_type:'leave',resource_id:id(10),resource_version:'v1',category:'leave',kind:'outcome',occurred_at:moment,expires_at:expiry,recipient:{type:'local_user',user_id:id(5)}});
 const insertion=(n,payload=body(n),at=moment,end=expiry)=>`INSERT INTO tenant_fixture.important_email_intent(id,tenant_id,event_id,recipient_key,event_hash,event,producer,resource_type,resource_id,resource_version,category,kind,occurred_at,expires_at) VALUES('${id(n)}','${id(1)}','${id(n+100)}','local:${id(5)}',repeat('a',64),'${JSON.stringify(payload)}','leave','leave','${id(10)}','v1','leave','outcome','${at}','${end}');`;
 const forged={...body(19),resource_type:'payslip'};
 assert.notEqual(pg.psql('company_fixture',{role:'hrms_company_leave',sql:'BEGIN;SET search_path=tenant_fixture,pg_catalog;'+insertion(19,forged)+'ROLLBACK;'}).status,0,'a producer cannot route another domain through an embedded event body');
 const insert=n=>pg.query('company_fixture',insertion(n));
 for(const n of [20,21,22])insert(n);
 const claim=n=>`UPDATE important_email_intent SET state='CLAIMED',lease_token='${id(n+200)}',lease_until=clock_timestamp()+interval '90 seconds',settings_version=2 WHERE id='${id(n)}';`;
 assert.equal(as(claim(20)).status,0);assert.equal(as(claim(21)).status,0);
 assert.notEqual(as(claim(22)).status,0,'third live lease must be rejected by the database itself');
 assert.notEqual(as(`UPDATE important_email_intent SET state='SUBMITTING' WHERE id='${id(20)}'`).status,0,'submission requires a resolved source identity');
 assert.equal(as(`UPDATE important_email_intent SET delivery_source_tenant='${id(1)}',delivery_source_user='${id(5)}' WHERE id='${id(20)}'`).status,0);
 assert.equal(as(`UPDATE important_email_intent SET state='SUBMITTING' WHERE id='${id(20)}'`).status,0);
 assert.notEqual(as(`UPDATE important_email_intent SET state='PENDING',lease_token=NULL,lease_until=NULL WHERE id='${id(20)}'`).status,0,'body may have been submitted; no blind reset');
 assert.notEqual(as(`UPDATE important_email_intent SET delivery_source_user='${id(6)}' WHERE id='${id(20)}'`).status,0,'resolved identity is immutable');
 assert.notEqual(as(`UPDATE important_email_intent SET state='PENDING',attempt_count=0,lease_token=NULL,lease_until=NULL WHERE id='${id(21)}'`).status,0,'retry count must advance exactly once');
 assert.notEqual(as(`UPDATE important_email_intent SET lease_until=clock_timestamp()+interval '1 hour' WHERE id='${id(21)}'`).status,0,'lease duration is bounded');
 assert.equal(as(`UPDATE tenant_email_settings SET version=version+1;`).status,0);
 assert.notEqual(as(`UPDATE important_email_intent SET state='SUBMITTING',delivery_source_tenant='${id(1)}',delivery_source_user='${id(6)}' WHERE id='${id(21)}'`).status,0,'changed settings fences unstarted body');
 assert.notEqual(as(`UPDATE important_email_intent SET attempt_count=2 WHERE id='${id(21)}'`).status,0,'attempt count is not an arbitrary writable counter');
 // Seed synthetic aged terminal metadata as the owned fixture owner. The real
 // Notification role cannot backdate it; the earlier guard regression proves so.
 const past=new Date(Date.now()-40*86400000).toISOString(),ended=new Date(Date.now()-39*86400000).toISOString();
 let history='BEGIN;';for(let n=100;n<205;n++)history+=insertion(n,{...body(n),occurred_at:past,expires_at:ended},past,ended);
 history+=`UPDATE tenant_fixture.important_email_intent SET state='SKIPPED',terminal_at=clock_timestamp() WHERE id>='${id(100)}' AND id<'${id(205)}';
 ALTER TABLE tenant_fixture.important_email_intent DISABLE TRIGGER email_intent_guard;
 UPDATE tenant_fixture.important_email_intent SET created_at=clock_timestamp()-interval '40 days',terminal_at=clock_timestamp()-interval '31 days' WHERE id>='${id(100)}' AND id<'${id(205)}';
 ALTER TABLE tenant_fixture.important_email_intent ENABLE TRIGGER email_intent_guard;COMMIT;`;
 pg.query('company_fixture',history);
 const purge=rustConstant('crates/kabipay-notification/src/email/store.rs','PURGE_TERMINAL_SQL').replaceAll('$1',`'${id(1)}'`);
 assert.equal(as(purge).status,0);
 assert.equal(pg.query('company_fixture',"SELECT count(*) FROM tenant_fixture.important_email_intent WHERE terminal_at<clock_timestamp()-interval '30 days'").trim(),'5','one pass deletes at most 100 aged terminal records');
 assert.equal(as(purge).status,0);assert.equal(pg.query('company_fixture','SELECT count(*) FROM tenant_fixture.important_email_intent').trim(),'3','live and new records survive both bounded passes');
});
