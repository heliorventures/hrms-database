// Operator credentials are read by the child tool only; never log connection objects.
const fs=require('node:fs');
const path=require('node:path');
const {Client}=require('pg');
const root=path.resolve(__dirname,'../..');
const check=(ok,code)=>{if(!ok)throw Error(code);};
const identifier=value=>typeof value==='string' && /^[a-z][a-z0-9_]{0,62}$/.test(value);
const uuid=value=>typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const quote=value=>'"'+value.replaceAll('"','""')+'"';
function load(expectedDatabase,values) {
 if(!values) {try{values=require('dotenv').parse(fs.readFileSync(path.join(root,'.env')));}catch{throw Error('REPOSITORY_ENV_UNREADABLE');}}
 check(identifier(expectedDatabase) && values.POSTGRES_DB===expectedDatabase,'METADATA_DATABASE_MISMATCH');
 check(/^[a-zA-Z0-9_.:-]+$/.test(values.POSTGRES_HOST||''),'INVALID_DATABASE_HOST');
 check(/^\d{1,5}$/.test(String(values.POSTGRES_PORT)) && +values.POSTGRES_PORT>0 && +values.POSTGRES_PORT<=65535,'INVALID_DATABASE_PORT');
 const sslmode=values.POSTGRES_SSLMODE||'verify-full';
 check(sslmode==='verify-full' || (sslmode==='disable' && ['localhost','127.0.0.1','::1'].includes(values.POSTGRES_HOST)),'VERIFY_FULL_OR_EXPLICIT_LOOPBACK_REQUIRED');
 const user=values.KABIPAY_DB_USER||values.POSTGRES_USER,password=values.KABIPAY_DB_PASSWORD||values.POSTGRES_PASSWORD;
 check(user && password && !/[\r\n\0]/.test(user+password),'DATABASE_CREDENTIALS_REQUIRED');
 return {host:values.POSTGRES_HOST,port:+values.POSTGRES_PORT,database:expectedDatabase,user,password,sslmode,rootcert:values.POSTGRES_SSLROOTCERT};
}
function client(config,database=config.database) {
 return new Client({host:config.host,port:config.port,user:config.user,password:config.password,database,
  ssl:config.sslmode==='disable'?false:{rejectUnauthorized:true,...(config.rootcert?{ca:fs.readFileSync(config.rootcert,'utf8')}:{})},
  connectionTimeoutMillis:10000,application_name:'hrms-company-operator'});
}
function childEnv(config,database) {
 const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^PG|^LIQUIBASE_|^POSTGRES_|^KABIPAY_DB_/i.test(key)));
 Object.assign(env,{PGHOST:config.host,PGPORT:String(config.port),PGDATABASE:database,PGUSER:config.user,PGPASSWORD:config.password,PGSSLMODE:config.sslmode,PGCONNECT_TIMEOUT:'10'});
 if(config.rootcert)env.PGSSLROOTCERT=config.rootcert;
 return env;
}
module.exports={root,load,client,childEnv,check,identifier,uuid,quote};
