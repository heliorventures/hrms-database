// Shared synthetic delivery fixtures; never an app DSN, .env or provider account.
const fs=require('node:fs');const path=require('node:path');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');const {python}=require('./email-native-support.cjs');
const root=path.resolve(__dirname,'../../..');
async function prepare(){
 const pg=await fixture();
 try{
  pg.query('postgres',['employee','leave','attendance','payroll','expense','tax','performance','notification','maintenance'].map(role=>`CREATE ROLE hrms_company_${role} LOGIN NOINHERIT;`).join('')+'CREATE DATABASE company_email_delivery_fixture;');
  const schema=fs.readFileSync(path.join(root,'changelog/migrations/0132_tenant_email/schema.sql'),'utf8').replaceAll('${schema}','tenant_fixture').replaceAll('${companyTenantId}','00000000-0000-4000-8000-000000000001');
  fs.writeFileSync(path.join(pg.directory,'owned-email-writers-setup.sql'),schema+python('print(e.grants_sql("tenant_fixture"))')+`SET search_path=tenant_fixture,pg_catalog;UPDATE tenant_email_settings SET enabled=true,enabled_after=clock_timestamp()-interval '1 day',categories='{"leave":true}',category_cutoffs=jsonb_build_object('leave',clock_timestamp()-interval '1 day'),credential_cipher=decode(repeat('aa',17),'hex'),credential_nonce=decode(repeat('bb',12),'hex'),credential_key_id='fixture',version=version+1;`,{flag:'wx',mode:0o600});
  const config=path.join(pg.directory,'owned-email-writers-fixture.json');const system=pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim();
  fs.writeFileSync(config,JSON.stringify({port:pg.connection('postgres').port,system_id:system,data_directory:path.join(pg.directory,'data'),database:'company_email_delivery_fixture'}),{flag:'wx',mode:0o600});
  const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!/^(PG|POSTGRES|DATABASE|KABIPAY|OUTBOX)/i.test(name)));env.KABIPAY_EMAIL_WRITERS_OWNED_FIXTURE=config;
  return {pg,env,system};
 }catch(error){pg.stop();throw error;}
}
module.exports={prepare};
