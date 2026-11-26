const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python,services}=require('./email-native-support.cjs');
test('worker current-company metadata query fits its exact independent readonly login',async t=>{
 const pg=await fixture();t.after(()=>pg.stop());pg.query('postgres','CREATE ROLE hrms_fixture_metadata_notification LOGIN NOINHERIT;CREATE DATABASE email_metadata_fixture;');
 const tenant='00000000-0000-4000-8000-000000000001';
 pg.query('email_metadata_fixture',`CREATE SCHEMA kabipay_ops;CREATE TABLE kabipay_ops.tenant(id uuid PRIMARY KEY,name text,status text,is_deleted boolean,timezone text);
 INSERT INTO kabipay_ops.tenant VALUES('${tenant}','Fixture Company','ACTIVE',false,'UTC');`+python('print(e.metadata_grants_sql("hrms_fixture_metadata_notification","kabipay-notification"))'));
 const source=fs.readFileSync(path.join(services,'crates/kabipay-notification/src/email/worker.rs'),'utf8');
 const context=source.slice(source.indexOf('async fn active_tenant('),source.indexOf('async fn current_company('));
 const literal=context.match(/"(SELECT name FROM kabipay_ops\.tenant[^"\r\n]+)"/);assert(literal,'worker must use one fixed company-status projection');
 const query=literal[1].replaceAll('$1',`'${tenant}'`);
 const as=sql=>pg.psql('email_metadata_fixture',{role:'hrms_fixture_metadata_notification',sql});
 const result=as(query);assert.equal(result.status,0,result.stderr);assert.equal(result.stdout.trim(),'Fixture Company');
 for(const sql of ['SELECT * FROM kabipay_ops.tenant','SELECT timezone FROM kabipay_ops.tenant',"UPDATE kabipay_ops.tenant SET status='ACTIVE'",'DELETE FROM kabipay_ops.tenant'])assert.notEqual(as(sql).status,0,'mail metadata adds only the four explicit status/label reads');
 pg.query('email_metadata_fixture',"UPDATE kabipay_ops.tenant SET status='SUSPENDED'");assert.equal(as(query).stdout.trim(),'','known inactive companies are refused');
});
