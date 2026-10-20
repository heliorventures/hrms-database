// Read-only operator tool for the single shared fleet. Never reads .env.
const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const {spawnSync} = require('node:child_process');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = value => createHash('sha256').update(value).digest('hex');
const requireValue = (condition, code) => { if (!condition) throw Error(code); };
const registryQuery="SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY; SET LOCAL statement_timeout='10s'; "+
  "SELECT COALESCE(json_agg(json_build_object('id',id,'subdomain',subdomain,'status',status,'is_deleted',is_deleted) ORDER BY id),'[]'::json) AS inventory "+
  "FROM kabipay_ops.tenant WHERE NOT is_deleted AND status IN ('ACTIVE','SUSPENDED');";
function readRelease(directory) {
  const base=fs.realpathSync(directory);
  const indexFile=path.join(base,'release.sha256');
  requireValue(fs.realpathSync(indexFile)===indexFile && !fs.lstatSync(indexFile).isSymbolicLink(),'RELEASE_ARTIFACT_ALIAS');
  const index=fs.readFileSync(indexFile);
  requireValue(index.length>0 && index.length<=1024*1024,'INVALID_RELEASE_INDEX');
  requireValue(index.at(-1)===10,'INVALID_RELEASE_INDEX');
  const names=new Set();
  for(const line of index.toString('utf8').slice(0,-1).split('\n')) {
    const match=line.match(/^([a-f0-9]{64})  ([a-zA-Z0-9][a-zA-Z0-9_./-]*)$/);
    requireValue(match && !match[2].split('/').some(p=>!p || p==='.' || p==='..'),'INVALID_RELEASE_INDEX');
    const [,digest,name]=match;
    requireValue(!names.has(name) && name!=='release.sha256','INVALID_RELEASE_INDEX');names.add(name);
    const file=path.join(base,...name.split('/'));
    requireValue(fs.realpathSync(file)===file && !fs.lstatSync(file).isSymbolicLink(),'RELEASE_ARTIFACT_ALIAS');
    requireValue(hash(fs.readFileSync(file))===digest,'RELEASE_ARTIFACT_CHANGED');
  }
  requireValue(names.has('release.json') && names.has('compose.json') && names.has('required-tenants.txt'),'INCOMPLETE_RELEASE_INDEX');
  const release=JSON.parse(fs.readFileSync(path.join(base,'release.json'),'utf8'));
  requireValue(release.version===1 && release.mode==='organization' && /^[a-zA-Z0-9_.-]+$/.test(release.tag??''),'INVALID_RELEASE');
  requireValue(Array.isArray(release.artifacts) && new Set(release.artifacts).size===release.artifacts.length &&
    release.artifacts.length===names.size+1 && release.artifacts.includes('release.sha256') &&
    release.artifacts.every(n=>n==='release.sha256'||names.has(n)),'INCOMPLETE_RELEASE_INDEX');
  const bindings=release.companyBindings;
  requireValue(Array.isArray(bindings) && bindings.length>0 && bindings.length<=100,'INVALID_COMPANY_BINDINGS');
  const ids=new Set(),slugs=new Set();
  for(const c of bindings) {
    requireValue(uuid.test(c.id??'') && !ids.has(c.id) &&
      /^[a-z][a-z0-9-]{0,30}$/.test(c.slug??'') && !slugs.has(c.slug) &&
      typeof release.tenantBaseDomain==='string' && c.publicHost===c.slug+'.'+release.tenantBaseDomain,'INVALID_COMPANY_BINDINGS');
    ids.add(c.id);slugs.add(c.slug);
  }
  requireValue(fs.readFileSync(path.join(base,'required-tenants.txt'),'utf8')===[...ids].sort().join(',')+'\n','INVALID_REQUIRED_TENANTS');
  return {...release,digest:hash(index)};
}
function checkRegistry(release,rows,now=Math.floor(Date.now()/1000)) {
  requireValue(Number.isSafeInteger(now) && now>0 && Array.isArray(rows),'INVALID_REGISTRY_RESULT');
  const desired=new Map(release.companyBindings.map(c=>[c.id,c])),seen=new Set();
  for(const r of rows) {
    requireValue(uuid.test(r.id??'') && !seen.has(r.id) && r.is_deleted===false &&
      ['ACTIVE','SUSPENDED'].includes(r.status),'INVALID_REGISTRY_RESULT');
    seen.add(r.id);
  }
  const missing=[...seen].filter(id=>!desired.has(id)).sort();
  requireValue(!missing.length,'INVENTORY_MISSING_TENANTS:'+missing.join(','));
  const notReady=[...desired.keys()].filter(id=>!seen.has(id)).sort();
  requireValue(!notReady.length,'INVENTORY_COMPANY_NOT_READY:'+notReady.join(','));
  for(const row of rows)requireValue(desired.get(row.id).slug===row.subdomain,'INVENTORY_SUBDOMAIN_MISMATCH:'+row.id);
  return ['version=1','scope=single-shared-fleet','tag='+release.tag,
    'release_sha256='+release.digest,'checked_at='+now,'expires_at='+(now+900),
    'tenant_ids='+[...seen].sort().join(',')].join('\n')+'\n';
}
function main(args) {
  const values={};
  for(let i=0;i<args.length;i+=2) {
    const key=args[i];
    requireValue(['--release-dir','--service','--database','--output'].includes(key) && args[i+1] && !values[key],'USAGE: node check-rollout.cjs --release-dir DIR --service LIBPQ_SERVICE --database OPS_DATABASE --output NEW_FILE');
    values[key]=args[i+1];
  }
  requireValue(Object.keys(values).length===4 && /^[a-z][a-z0-9_.-]*$/.test(values['--service']) &&
    /^[a-z][a-z0-9_]{0,62}$/.test(values['--database']),'INVALID_OPERATOR_ARGUMENTS');
  const release=readRelease(values['--release-dir']);
  const result=spawnSync('psql',[
    'service='+values['--service']+' dbname='+values['--database']+' sslmode=verify-full',
    '--no-psqlrc','--no-password','--quiet','--no-align','--tuples-only','--set=ON_ERROR_STOP=1','--single-transaction','--command',registryQuery,
  ],{encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:1024*1024});
  requireValue(!result.error && result.status===0,'OPS_INVENTORY_QUERY_FAILED');
  let rows;try {rows=JSON.parse(result.stdout);}catch {throw Error('INVALID_REGISTRY_RESULT');}
  const report=checkRegistry(release,rows);
  // Refuse overwrite/symlink replacement and never print DB transport details.
  fs.writeFileSync(values['--output'],report,{encoding:'utf8',mode:0o600,flag:'wx'});
  console.log('Inventory matched '+rows.length+' ACTIVE/SUSPENDED companies; receipt expires in 15 minutes. Freeze tenant provisioning/status/subdomain changes until cutover.');
}
module.exports={readRelease,checkRegistry,registryQuery};
if(require.main===module)try {main(process.argv.slice(2));}catch(e){console.error(e.message);process.exitCode=1;}
