const {test}=require('node:test');
const assert=require('node:assert/strict');
const {resolveCompany,liquibaseInvocation}=require('../deploy-company.cjs');
const id='11111111-1111-4111-8111-111111111111';
const options={tenantId:id,expectedDatabase:'company_alpha',runtimeHost:'postgres'};
const row={tenant_id:id,status:'ACTIVE',is_deleted:false,db_type:'POSTGRES',db_host:'postgres',db_name:'company_alpha',schema_name:'tenant_11111111'};
const client=rows=>({query:async()=>({rows})});
test('company target uses exact registry mapping, including tunnel host distinction',async()=>{
 assert.deepEqual(await resolveCompany(client([row]),options),{database:'company_alpha',schema:'tenant_11111111',tenantId:id});
 for(const rows of [[],[row,row],[{...row,db_name:'helior'}],[{...row,db_host:'other'}],[{...row,status:'TERMINATED'}],[{...row,schema_name:'public'}]]) {
  await assert.rejects(resolveCompany(client(rows),options));
 }
});
test('Liquibase uses child credentials, no password argv or persistent credential properties',()=>{
 const config={host:'127.0.0.1',port:5433,user:'migrator',password:'never-print',sslmode:'verify-full',rootcert:'C:/certs/ca.pem'};
 const result=liquibaseInvocation(config,{database:'company_alpha',schema:'tenant_11111111'},'status');
 assert(!JSON.stringify(result.args).includes(config.password));
 assert.equal(result.env.LIQUIBASE_COMMAND_PASSWORD,config.password);
 assert.match(result.env.LIQUIBASE_COMMAND_URL,/company_alpha\?sslmode=verify-full/);
 assert.match(result.env.LIQUIBASE_COMMAND_URL,/sslrootcert=/);
 assert(result.args.includes('--database-changelog-table-name=tenant_11111111_databasechangelog'));
 assert(result.args.includes('-Dschema=tenant_11111111'));
 assert.throws(()=>liquibaseInvocation(config,{database:'company_alpha',schema:'tenant_11111111'},'drop-all'));
});
