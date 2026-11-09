// Central migrations only. Company updates use the registry-aware tenant updater.
const path=require('node:path');const {spawnSync}=require('node:child_process');
const {load,client,childEnv,check,identifier}=require('./provisioning/company-databases/connection.cjs');
function invocation(config,expectedDatabase,command='update'){
 check(identifier(expectedDatabase) && config.database===expectedDatabase && !expectedDatabase.startsWith('company_'),'EXPLICIT_METADATA_TARGET_REQUIRED');
 check(['update','validate','status'].includes(command),'INVALID_MIGRATION_COMMAND');
 const params=new URLSearchParams({sslmode:config.sslmode});if(config.rootcert)params.set('sslrootcert',config.rootcert);
 const host=config.host.includes(':')?'['+config.host+']':config.host;
 const env=childEnv(config,config.database);
 Object.assign(env,{LIQUIBASE_COMMAND_URL:`jdbc:postgresql://${host}:${config.port}/${config.database}?${params}`,LIQUIBASE_COMMAND_USERNAME:config.user,LIQUIBASE_COMMAND_PASSWORD:config.password});
 return {args:['--defaults-file=liquibase.properties',command],env};
}
async function deployOps(config,expectedDatabase,command='update',run=spawnSync){
 const call=invocation(config,expectedDatabase,command);const db=client(config);
 try{
  await db.connect();
  const target=await db.query("SELECT current_database() AS database,to_regclass('kabipay_ops.tenant_database') IS NOT NULL AS registry");
  check(target.rows[0].database===expectedDatabase && target.rows[0].registry,'EXISTING_METADATA_REGISTRY_REQUIRED');
  const result=run(process.execPath,[path.join(__dirname,'run-liquibase.cjs'),...call.args],{cwd:__dirname,env:call.env,encoding:'utf8',shell:false,windowsHide:true,maxBuffer:16*1024*1024});
  check(!result.error && result.status===0,'OPS_LIQUIBASE_FAILED_REVIEW_WITH_DATABASE_OPERATOR');
  return {database:expectedDatabase,scope:'ops',command,completed:true};
 }finally{await db.end();}
}
async function main(args){
 const options={};for(let i=0;i<args.length;i+=2){check(['--expected-database','--command'].includes(args[i]) && args[i+1] && !options[args[i]],'USAGE_MIGRATE_OPS_EXPECTED_DATABASE_REQUIRED');options[args[i]]=args[i+1];}
 check(options['--expected-database'],'EXPECTED_METADATA_DATABASE_REQUIRED');
 console.log(JSON.stringify(await deployOps(load(options['--expected-database']),options['--expected-database'],options['--command']||'update')));
}
module.exports={invocation,deployOps,main};
if(require.main===module)main(process.argv.slice(2)).catch(()=>{console.error('Ops migration failed. Supply --expected-database matching the existing metadata registry; verify TLS and migration prerequisites. Raw database output is suppressed.');process.exitCode=1;});
