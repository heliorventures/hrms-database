// Read the repository's .env without loading it into the parent environment.
// This runner is intentionally restricted to an already-open loopback SSH tunnel.
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const dotenv = require('dotenv');
const root = path.resolve(__dirname,'../..');
const requireValue = (condition,code) => { if (!condition) throw Error(code); };

function connection(values, expected) {
  requireValue(/^[a-z][a-z0-9_]{0,62}$/.test(expected ?? ''),'EXPLICIT_EXPECTED_DATABASE_REQUIRED');
  requireValue(values.POSTGRES_DB === expected,'DATABASE_TARGET_MISMATCH');
  requireValue(['localhost','127.0.0.1','::1'].includes(values.POSTGRES_HOST),'LOOPBACK_TUNNEL_REQUIRED');
  requireValue(/^\d{1,5}$/.test(values.POSTGRES_PORT ?? '') && Number(values.POSTGRES_PORT)>0 &&
    Number(values.POSTGRES_PORT)<=65535,'INVALID_TUNNEL_PORT');
  for (const key of ['POSTGRES_USER','POSTGRES_PASSWORD']) {
    requireValue(typeof values[key]==='string' && values[key].length>0 && !values[key].includes('\0'),'DATABASE_CREDENTIALS_REQUIRED');
  }
  const sslmode=values.POSTGRES_SSLMODE ?? 'prefer';
  requireValue(['disable','allow','prefer','require','verify-ca','verify-full'].includes(sslmode),'INVALID_SSL_MODE');
  return {host:values.POSTGRES_HOST,port:values.POSTGRES_PORT,database:expected,
    user:values.POSTGRES_USER,password:values.POSTGRES_PASSWORD,sslmode,rootcert:values.POSTGRES_SSLROOTCERT};
}

function childEnvironment(config, ambient=process.env) {
  // Ignore ambient PG service/host/SSL/option overrides, even mixed-case Windows keys.
  const env=Object.fromEntries(Object.entries(ambient).filter(([key])=>!/^PG/i.test(key)));
  Object.assign(env,{PGHOST:config.host,PGPORT:config.port,PGDATABASE:config.database,
    PGUSER:config.user,PGPASSWORD:config.password,PGSSLMODE:config.sslmode,
    PGCONNECT_TIMEOUT:'10',PGAPPNAME:'hrms-company-database-preflight',
    PGOPTIONS:'-c default_transaction_read_only=on'});
  if (config.rootcert) env.PGSSLROOTCERT=config.rootcert;
  return env;
}

function collect({config,output,psql}, spawn=spawnSync) {
  let fd;
  try { fd=fs.openSync(output,'wx',0o600); }
  catch { throw Error('OUTPUT_EXISTS_OR_UNWRITABLE'); }
  try {
    const result=spawn(psql,['--no-psqlrc','--no-password','--quiet','--no-align','--tuples-only',
      '--set=ON_ERROR_STOP=1','--set=expected_database='+config.database,
      '--file='+path.join(__dirname,'preflight.sql')],
    {env:childEnvironment(config),shell:false,encoding:'utf8',windowsHide:true,timeout:120000,maxBuffer:16*1024*1024});
    // Never echo stderr, the connection configuration or environment on failure.
    requireValue(!result.error && result.status===0,'PREFLIGHT_FAILED_CHECK_TUNNEL_LOGIN_AND_PSQL');
    let records;
    try { records=result.stdout.trim().split(/\r?\n/).map(line=>JSON.parse(line)); }
    catch { throw Error('INVALID_PREFLIGHT_REPORT'); }
    const inventory=records[0],complete=records.at(-1);
    requireValue(inventory?.section==='inventory' && inventory.database===config.database &&
      inventory.transaction_read_only==='on' && Array.isArray(inventory.tenants) &&
      complete?.section==='complete' && complete.database===config.database && complete.format_version===1 &&
      complete.readiness==='not_assessed','INCOMPLETE_OR_WRONG_TARGET_REPORT');
    fs.writeFileSync(fd,result.stdout,{encoding:'utf8'});
    return {tenants:inventory.tenants.length,output:path.resolve(output)};
  } finally { fs.closeSync(fd); }
}

function main(args) {
  const options={};
  for (let i=0;i<args.length;i+=2) {
    requireValue(['--expected-database','--output','--psql'].includes(args[i]) && args[i+1] &&
      !options[args[i]],'USAGE: node run-local.cjs --expected-database helior --output NEW_FILE [--psql ABSOLUTE_PSQL_PATH]');
    options[args[i]]=args[i+1];
  }
  requireValue(options['--output'],'OUTPUT_REQUIRED');
  requireValue(!options['--psql'] || path.isAbsolute(options['--psql']),'ABSOLUTE_PSQL_PATH_REQUIRED');
  let values;
  try { values=dotenv.parse(fs.readFileSync(path.join(root,'.env'))); }
  catch { throw Error('REPOSITORY_ENV_UNREADABLE'); }
  const config=connection(values,options['--expected-database']);
  console.log(`Read-only preflight: ${config.host}:${config.port}/${config.database}`);
  const result=collect({config,output:options['--output'],psql:options['--psql'] ?? 'psql'});
  console.log(`Collected ${result.tenants} ACTIVE/SUSPENDED tenants. Report: ${result.output}`);
  console.log('Collection succeeded; migration readiness has not been assessed.');
}

module.exports={connection,childEnvironment,collect};
if (require.main===module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message);process.exitCode=1; }
}
