// Explicit operator tool. Company data is never accessed through retained schemas.
const fs = require('node:fs');
const {randomUUID} = require('node:crypto');
const {load,client,check,quote} = require('./connection.cjs');
const {resolveCompany} = require('./deploy-company.cjs');
const {buildRoleDefaults} = require('../../scripts/reusable/rbac/canonical-role-defaults.cjs');

async function lockedRegistry(config, options, operation) {
  check(/^\d{1,20}$/.test(options.systemIdentifier || ''), 'EXPECTED_CLUSTER_ID_REQUIRED');
  const registry = client(config);
  let registryFailed=false;
  registry.on('error',()=>{registryFailed=true;});
  const assertRegistry=async()=>{check(!registryFailed,'REGISTRY_LOCK_CONNECTION_LOST');await registry.query('SELECT 1');};
  try {
    await registry.connect();
    await registry.query('BEGIN');
    await registry.query("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='2min'");
    const identity = (await registry.query('SELECT system_identifier::text AS id FROM pg_control_system()')).rows[0];
    check(identity.id === options.systemIdentifier, 'CLUSTER_ID_MISMATCH');
    await registry.query('SELECT id FROM kabipay_ops.tenant WHERE id=$1 FOR SHARE', [options.tenantId]);
    await registry.query('SELECT id FROM kabipay_ops.tenant_database WHERE tenant_id=$1 FOR SHARE', [options.tenantId]);
    const target = await resolveCompany(registry, options);
    check(!(await registry.query('SELECT 1 FROM kabipay_ops.tenant_database WHERE is_active AND db_name=$1 AND tenant_id<>$2', [target.database,target.tenantId])).rows.length, 'DATABASE_SHARED_WITH_ANOTHER_COMPANY');
    const result = await operation(registry, target, assertRegistry);
    await assertRegistry();
    await registry.query('COMMIT');
    return result;
  } finally { await registry.end(); }
}

async function assertCompany(db, target, systemIdentifier) {
  const identity = (await db.query('SELECT current_database() AS database,system_identifier::text AS id FROM pg_control_system()')).rows[0];
  check(identity.database === target.database && identity.id === systemIdentifier, 'COMPANY_DATABASE_OR_CLUSTER_MISMATCH');
  check(!(await db.query("SELECT 1 FROM pg_namespace WHERE nspname='kabipay_ops' OR (nspname LIKE 'tenant\\_%' ESCAPE '\\' AND nspname<>$1)", [target.schema])).rows.length, 'ISOLATED_COMPANY_SCHEMA_REQUIRED');
  const history = `${quote(target.schema)}.${quote(target.schema+'_databasechangelog')}`;
  check((await db.query(`SELECT count(*)::int AS n FROM ${history} WHERE id='0129-001-local-company-catalog-reference-and-helper' AND exectype IN ('EXECUTED','RERAN')`)).rows[0].n === 1, 'REAL_COMPANY_BASELINE_REQUIRED');
}

async function applyDefaults(db, target, defaults=buildRoleDefaults()) {
  const s=quote(target.schema), tenant=target.tenantId;
  await db.query(`LOCK TABLE ${s}.role,${s}.permission,${s}.role_permission,${s}.permission_scope IN SHARE ROW EXCLUSIVE MODE`);
  const roles=new Map(),newRoles=new Set();
  for(const role of ['EMPLOYEE','MANAGER','HR','ADMIN']) {
    const rows=(await db.query(`SELECT id,is_deleted FROM ${s}.role WHERE tenant_id=$1 AND UPPER(TRIM(name))=$2`,[tenant,role])).rows;
    check(rows.length<=1 && !rows[0]?.is_deleted,'AMBIGUOUS_OR_DELETED_CANONICAL_ROLE');
    let id=rows[0]?.id;
    if(!id) { id=randomUUID();await db.query(`INSERT INTO ${s}.role(id,tenant_id,name,description) VALUES($1,$2,$3,$4)`,[id,tenant,role,`Canonical ${role} defaults`]);newRoles.add(role); }
    roles.set(role,id);
  }
  let added=0;
  const changedRoles=new Set();
  for(const row of defaults) {
    // An existing role's absent default may be an intentional revocation.
    // Only a genuinely new role receives a default bundle.
    if(!newRoles.has(row.role)) continue;
    const permissions=(await db.query(`SELECT id FROM ${s}.permission WHERE LOWER(TRIM(resource))=$1 AND LOWER(TRIM(action))=$2`,[row.resource,row.action])).rows;
    check(permissions.length===1,'MIGRATED_UNAMBIGUOUS_PERMISSION_CATALOG_REQUIRED');
    const role=roles.get(row.role), permission=permissions[0].id;
    // Preserve all existing decisions, including inactive unscoped grants and
    // scopes whose permission link was deliberately removed. Add a missing pair.
    const existing=(await db.query(`SELECT EXISTS(SELECT 1 FROM ${s}.role_permission WHERE role_id=$1 AND permission_id=$2) AS has_grant,
      EXISTS(SELECT 1 FROM ${s}.permission_scope WHERE role_id=$1 AND LOWER(TRIM(resource))=$3 AND LOWER(TRIM(action))=$4) AS has_scope`,[role,permission,row.resource,row.action])).rows[0];
    if(existing.has_grant || existing.has_scope) continue;
    await db.query(`INSERT INTO ${s}.role_permission(role_id,permission_id) VALUES($1,$2)`,[role,permission]);
    await db.query(`INSERT INTO ${s}.permission_scope(id,tenant_id,role_id,resource,action,scope_type) VALUES($1,$2,$3,$4,$5,$6)`,[randomUUID(),tenant,role,row.resource,row.action,row.scope]);
    added++;changedRoles.add(role);
  }
  if(changedRoles.size) {
    await db.query(`DELETE FROM ${s}.user_session WHERE user_id IN(SELECT user_id FROM ${s}.user_role WHERE role_id=ANY($1::uuid[]))`,[[...changedRoles]]);
  }
  return {added,adminRoleId:roles.get('ADMIN')};
}

function validateAdmins(admins) {
  check(Array.isArray(admins) && admins.length<=20,'EXPLICIT_NEW_ADMIN_INPUT_REQUIRED');
  const seen=new Set();
  for(const a of admins) {
    check(a.intent==='CREATE_NEW_ADMIN' && typeof a.username==='string' && /^[a-z0-9][a-z0-9@._-]{1,254}$/.test(a.username),'NEW_ADMIN_INTENT_AND_USERNAME_REQUIRED');
    check(!seen.has(a.username),'DUPLICATE_NEW_ADMIN_USERNAME');seen.add(a.username);
    check(typeof a.firstName==='string' && a.firstName.trim() && a.firstName.length<=100 && typeof a.lastName==='string' && a.lastName.trim() && a.lastName.length<=100,'ADMIN_NAME_REQUIRED');
    check(/^[A-Za-z0-9][A-Za-z0-9._-]{0,49}$/.test(a.employeeCode||''),'ADMIN_EMPLOYEE_CODE_REQUIRED');
    check(/^\d{4}-\d{2}-\d{2}$/.test(a.dateOfJoining||''),'ADMIN_JOINING_DATE_REQUIRED');
    const hash=a.passwordHash?.match(/^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$[A-Za-z0-9+/]{16,}\$[A-Za-z0-9+/]{32,}$/);
    check(hash && +hash[1]>=19456 && +hash[2]>=2 && +hash[3]>=1,'EXPLICIT_ARGON2ID_PASSWORD_HASH_REQUIRED');
  }
  return admins;
}

async function assertAdminAuthority(db,target,adminRoleId) {
  const s=quote(target.schema);
  const admin=(await db.query(`SELECT 1 FROM ${s}.role_permission rp JOIN ${s}.permission p ON p.id=rp.permission_id
    JOIN ${s}.permission_scope ps ON ps.role_id=rp.role_id AND ps.tenant_id=$2
    AND ps.resource='role' AND ps.action='manage' AND ps.scope_type='ALL'
    WHERE rp.role_id=$1 AND p.resource='role' AND p.action='manage'`,[adminRoleId,target.tenantId])).rows;
  check(admin.length===1,'EXISTING_ADMIN_POLICY_REQUIRES_EXPLICIT_OPERATOR_REVIEW');
}

async function bootstrap(config,options) {
  const admins=validateAdmins(options.admins||[]);
  return lockedRegistry(config,options,async(registry,target,assertRegistry)=>{
    const db=client(config,target.database);
    let companyFailed=false;
    db.on('error',()=>{companyFailed=true;});
    try {
      await db.connect();await db.query('BEGIN');
      await db.query("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='2min'");
      await assertCompany(db,target,options.systemIdentifier);
      if(!options.execute) { await db.query('ROLLBACK');return {...target,operation:'PLAN_COMPANY_BOOTSTRAP',newAdminCount:admins.length,defaults:buildRoleDefaults().length}; }
      const result=await applyDefaults(db,target);
      const s=quote(target.schema), ids=[];
      await db.query(`LOCK TABLE ${s}."user",${s}.employee,${s}.user_role IN SHARE ROW EXCLUSIVE MODE`);
      if(admins.length)await assertAdminAuthority(db,target,result.adminRoleId);
      for(const a of admins) {
        const exists=await db.query(`SELECT 1 FROM ${s}."user" WHERE tenant_id=$1 AND LOWER(username)=LOWER($2)`,[target.tenantId,a.username]);
        check(!exists.rows.length,'EXISTING_USER_NEVER_SILENTLY_ELEVATED_OR_RESET');
        const uid=randomUUID(), eid=randomUUID();
        await db.query(`INSERT INTO ${s}."user"(id,tenant_id,username,password_hash,is_active,must_change_password) VALUES($1,$2,$3,$4,true,true)`,[uid,target.tenantId,a.username,a.passwordHash]);
        await db.query(`INSERT INTO ${s}.employee(id,tenant_id,user_id,employee_code,first_name,last_name,status,date_of_joining) VALUES($1,$2,$3,$4,$5,$6,'ACTIVE',$7)`,[eid,target.tenantId,uid,a.employeeCode,a.firstName.trim(),a.lastName.trim(),a.dateOfJoining]);
        await db.query(`INSERT INTO ${s}.user_role(user_id,role_id) VALUES($1,$2)`,[uid,result.adminRoleId]);ids.push(uid);
      }
      check(!companyFailed,'COMPANY_CONNECTION_LOST');
      await assertRegistry();
      await db.query('COMMIT');
      return {...target,systemIdentifier:options.systemIdentifier,operation:'COMPANY_BOOTSTRAP',addedDefaultPairs:result.added,createdAdminIds:ids};
    } finally { await db.end(); }
  });
}

async function main(args) {
  const v={};
  for(let i=0;i<args.length;i++) {const key=args[i];check(!Object.hasOwn(v,key),'DUPLICATE_ARGUMENT');if(key==='--execute')v[key]=true;else{check(['--tenant-id','--expected-database','--expected-metadata-database','--runtime-host','--expected-system-identifier','--admin-input','--receipt'].includes(key)&&args[i+1],'INVALID_BOOTSTRAP_ARGUMENT');v[key]=args[++i];}}
  check(v['--expected-metadata-database'] && (!v['--execute']||v['--receipt']),'METADATA_TARGET_AND_EXECUTION_RECEIPT_REQUIRED');
  const admins=v['--admin-input']?JSON.parse(fs.readFileSync(v['--admin-input'],'utf8')):[];
  validateAdmins(admins);
  // Reserve the receipt before mutation; never overwrite a prior execution.
  const fd=v['--execute']?fs.openSync(v['--receipt'],'wx',0o600):undefined;
  const append=record=>{if(fd!==undefined){fs.writeFileSync(fd,JSON.stringify(record)+'\n');fs.fsyncSync(fd);}};
  try {
    append({status:'STARTED',tenantId:v['--tenant-id'],database:v['--expected-database'],systemIdentifier:v['--expected-system-identifier'],intents:admins.map(a=>({intent:a.intent,username:a.username,employeeCode:a.employeeCode}))});
    const result=await bootstrap(load(v['--expected-metadata-database']),{tenantId:v['--tenant-id'],expectedDatabase:v['--expected-database'],runtimeHost:v['--runtime-host'],systemIdentifier:v['--expected-system-identifier'],admins,execute:!!v['--execute']});
    append({status:'COMPLETED',...result});
    console.log(JSON.stringify(result));
  } catch(error) {
    append({status:'FAILED_OR_UNKNOWN_REVIEW_REQUIRED'});throw error;
  } finally {if(fd!==undefined)fs.closeSync(fd);}
}
module.exports={lockedRegistry,assertCompany,applyDefaults,validateAdmins,assertAdminAuthority,bootstrap,main};
if(require.main===module)main(process.argv.slice(2)).catch(()=>{console.error('Company bootstrap failed; no credentials or server details are displayed. Review exact target and the execution receipt before retry.');process.exitCode=1;});
