const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {root,load,client,childEnv,check,identifier,uuid,quote}=require('./connection.cjs');
async function resolveCompany(registry,{tenantId,expectedDatabase,runtimeHost}) {
 check(uuid(tenantId) && identifier(expectedDatabase) && /^company_[a-z0-9_]+$/.test(expectedDatabase),'EXPLICIT_COMPANY_TARGET_REQUIRED');
 check(typeof runtimeHost==='string' && /^[a-zA-Z0-9_.:-]+$/.test(runtimeHost),'RUNTIME_HOST_REQUIRED');
 const result=await registry.query(`SELECT t.id AS tenant_id,t.status,t.is_deleted,d.db_type,d.db_host,d.db_name,d.schema_name
  FROM kabipay_ops.tenant t JOIN kabipay_ops.tenant_database d ON d.tenant_id=t.id AND d.is_active WHERE t.id=$1`,[tenantId]);
 check(result.rows.length===1,'UNIQUE_COMPANY_MAPPING_REQUIRED');
 const row=result.rows[0];
 check(!row.is_deleted && ['ACTIVE','SUSPENDED'].includes(row.status) && row.db_type==='POSTGRES' && row.db_host===runtimeHost && row.db_name===expectedDatabase && /^tenant_[a-z0-9_]{1,50}$/.test(row.schema_name),'COMPANY_REGISTRY_TARGET_MISMATCH');
 return {database:row.db_name,schema:row.schema_name,tenantId};
}
function liquibaseInvocation(config,target,command='update') {
 check(['update','validate','status'].includes(command),'INVALID_MIGRATION_COMMAND');
 check(identifier(target.database) && /^tenant_[a-z0-9_]{1,50}$/.test(target.schema),'INVALID_COMPANY_TARGET');
 const host=config.host.includes(':')?'['+config.host+']':config.host;
 const params=new URLSearchParams({sslmode:config.sslmode});
 if(config.rootcert)params.set('sslrootcert',config.rootcert);
 const env=childEnv(config,target.database);
 Object.assign(env,{LIQUIBASE_COMMAND_URL:`jdbc:postgresql://${host}:${config.port}/${target.database}?${params}`,LIQUIBASE_COMMAND_USERNAME:config.user,LIQUIBASE_COMMAND_PASSWORD:config.password});
 const args=['--defaults-file=provisioning/company-databases/company.properties',
  '--default-schema-name='+target.schema,'--liquibase-schema-name='+target.schema,
  '--database-changelog-table-name='+target.schema+'_databasechangelog',command,'-Dschema='+target.schema];
 return {args,env};
}
async function deploy(config,options,run=spawnSync) {
 const registry=client(config);let company;
 try {
  await registry.connect();await registry.query('BEGIN');
  await registry.query("SET LOCAL lock_timeout='5s'");
  // Hold the exact tenant/mapping stable until Liquibase exits.
  await registry.query('SELECT id FROM kabipay_ops.tenant WHERE id=$1 FOR SHARE',[options.tenantId]);
  await registry.query('SELECT id FROM kabipay_ops.tenant_database WHERE tenant_id=$1 FOR SHARE',[options.tenantId]);
  const target=await resolveCompany(registry,options);
  const duplicate=await registry.query('SELECT tenant_id FROM kabipay_ops.tenant_database WHERE is_active AND db_name=$1 AND tenant_id<>$2',[target.database,target.tenantId]);
  check(!duplicate.rows.length,'DATABASE_SHARED_WITH_ANOTHER_COMPANY');
  company=client(config,target.database);await company.connect();
  const history=quote(target.schema)+'.'+quote(target.schema+'_databasechangelog');
  const baseline=await company.query(`SELECT count(*)::int AS count FROM ${history} WHERE id='0129-001-local-company-catalog-reference-and-helper' AND exectype IN ('EXECUTED','RERAN')`);
  check(baseline.rows[0].count===1,'COMPANY_BASELINE_REQUIRED_MIGRATE_WHILE_COLOCATED_THEN_COPY');
  const foreign=await company.query("SELECT nspname FROM pg_namespace WHERE nspname='kabipay_ops' OR (nspname LIKE 'tenant\\_%' ESCAPE '\\' AND nspname<>$1)",[target.schema]);
  check(!foreign.rows.length,'ISOLATED_COMPANY_SCHEMA_REQUIRED');
  const invocation=liquibaseInvocation(config,target,options.command);
  // Capture tool output: SQL errors may include business values. Never echo it.
  const result=run(process.execPath,[path.join(root,'run-liquibase.cjs'),...invocation.args],{cwd:root,env:invocation.env,encoding:'utf8',shell:false,windowsHide:true,maxBuffer:16*1024*1024});
  check(!result.error && result.status===0,'COMPANY_LIQUIBASE_FAILED_REVIEW_WITH_DATABASE_OPERATOR');
  await registry.query('COMMIT');return {...target,command:options.command||'update',completed:true};
 } finally {if(company)await company.end();await registry.end();}
}
function parse(args) {
 const values={};
 for(let i=0;i<args.length;i+=2){check(['--tenant-id','--expected-database','--expected-metadata-database','--runtime-host','--command'].includes(args[i]) && args[i+1] && !values[args[i]],'INVALID_COMPANY_DEPLOY_ARGUMENTS');values[args[i]]=args[i+1];}
 check(values['--expected-metadata-database'],'EXPECTED_METADATA_DATABASE_REQUIRED');
 return values;
}
module.exports={resolveCompany,liquibaseInvocation,deploy,parse};
if(require.main===module){(async()=>{const v=parse(process.argv.slice(2));const result=await deploy(load(v['--expected-metadata-database']),{tenantId:v['--tenant-id'],expectedDatabase:v['--expected-database'],runtimeHost:v['--runtime-host'],command:v['--command']||'update'});console.log(JSON.stringify(result));})().catch(()=>{console.error('Company migration failed. Verify explicit target, registry, baseline, TLS and migration prerequisites; credentials and database errors are suppressed.');process.exitCode=1;});}
