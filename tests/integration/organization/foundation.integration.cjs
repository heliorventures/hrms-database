// Only a newly created, loopback-bound disposable PostgreSQL container is used.
// Never load .env, accept a connection URL, or target an existing tenant database.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');

const root = path.resolve(__dirname, '../../..');
const baseline = process.argv.includes('--baseline');
const container = `hrms-organization-foundation-${randomUUID().replaceAll('-', '')}`;
const ids = Object.fromEntries(['tenantA','tenantB','orgA','orgB','membershipA','membershipB','personA','personB','personC','employeeA','employeeB','roleA','roleB','bindingA','employmentA','employmentB','managerEmploymentA','managerEmploymentB'].map(key=>[key,randomUUID()]));
let db, config, created = false, checks = 0;
function docker(args) {
  const result = spawnSync('docker', args, { encoding:'utf8', windowsHide:true, timeout:60000 });
  if (result.error || result.status !== 0) throw new Error(`disposable Docker command failed: ${result.error || result.stderr}`);
  return result.stdout.trim();
}
function sqlBlocks(relative) {
  const xml = fs.readFileSync(path.join(root,relative),'utf8').replace(/<rollback>[\s\S]*?<\/rollback>/g,'');
  return [...xml.matchAll(/<sql\s+splitStatements="false">\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*<\/sql>/g)].map(m=>m[1]);
}
async function migrate() {
  const files = [
    ['changelog/migrations/0111_organization_foundation/organization_foundation.xml',null],
    ['changelog/migrations/0112_company_management_foundation/company_management_foundation.xml','org_a'],
    ['changelog/migrations/0112_company_management_foundation/company_management_foundation.xml','org_b'],
  ];
  for (const [file,schema] of files) {
    const blocks=sqlBlocks(file);assert.ok(blocks.length>0,`missing executable migration SQL: ${file}`);
    await db.query('BEGIN');
    try { for (const sql of blocks) await db.query(schema?sql.replaceAll('${schema}',schema):sql);await db.query('COMMIT'); }
    catch(error) {await db.query('ROLLBACK');throw error;}
  }
}
async function check(name,run) {await run();checks++;console.log(`PASS ${name}`);}
async function rejected(query,code) {await assert.rejects(query,error=>error.code===code,`expected PostgreSQL ${code}`);}
async function assignment(schema, overrides={}) {
  const a=schema==='org_a';
  const row={id:randomUUID(),tenant:a?ids.tenantA:ids.tenantB,org:ids.orgA,
    employee:a?ids.employeeA:ids.employeeB,subject:a?ids.personA:ids.personC,
    manager:a?ids.personB:ids.personA,subjectEmployment:a?ids.employmentA:ids.employmentB,
    managerEmployment:a?ids.managerEmploymentB:ids.managerEmploymentA,
    managerTenant:a?ids.tenantB:ids.tenantA,type:'PRIMARY',status:'ACTIVE',from:'2026-10-18T08:00:00Z',to:'2026-10-18T12:00:00Z',...overrides};
  assert.ok(['org_a','org_b'].includes(schema));
  const values=[row.id,row.tenant,row.org,row.employee,row.subject,row.manager,row.subjectEmployment,row.managerEmployment,row.managerTenant,row.type,row.status,row.from,row.to];
  return {row,values,sql:`INSERT INTO ${schema}.management_assignment
    (id,tenant_id,organization_id,subject_employee_id,subject_principal_id,manager_principal_id,
     subject_employment_ref_id,manager_employment_ref_id,manager_tenant_id,relationship_type,status,effective_from,effective_to)
    VALUES (${values.map((_,i)=>'$'+(i+1)).join(',')})`};
}
async function insertAssignment(schema,overrides={}) {const q=await assignment(schema,overrides);await db.query(q.sql,q.values);return q.row;}
async function main() {
  try {
    docker(['run','--pull=never','--rm','-d','--name',container,'--memory','256m','--cpus','1','-p','127.0.0.1::5432',
      '-e','POSTGRES_USER=organization_fixture','-e','POSTGRES_PASSWORD=organization_fixture','-e','POSTGRES_DB=organization_fixture','postgres:16-alpine']);
    created=true;
    const match=docker(['port',container,'5432/tcp']).match(/^127\.0\.0\.1:(\d+)$/);
    assert.ok(match,'refusing non-loopback fixture endpoint');
    let ready=false;
    for(let i=0;i<60;i++) {
      const r=spawnSync('docker',['exec',container,'pg_isready','-h','127.0.0.1','-U','organization_fixture','-d','organization_fixture'],{stdio:'ignore',windowsHide:true,timeout:5000});
      if(r.status===0){ready=true;break;}
      await new Promise(resolve=>setTimeout(resolve,200));
    }
    assert.ok(ready,'disposable PostgreSQL did not become ready');
    config={host:'127.0.0.1',port:Number(match[1]),user:'organization_fixture',password:'organization_fixture',database:'organization_fixture',ssl:false,connectionTimeoutMillis:5000};
    db=new Client(config);await db.connect();
    await db.query(`CREATE EXTENSION IF NOT EXISTS pgcrypto;
      CREATE SCHEMA kabipay_ops;CREATE TABLE kabipay_ops.tenant(id UUID PRIMARY KEY);
      CREATE SCHEMA org_a;CREATE SCHEMA org_b;
      CREATE TABLE org_a.employee(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
      CREATE TABLE org_b.employee(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);`);
    await db.query('INSERT INTO kabipay_ops.tenant VALUES($1),($2)',[ids.tenantA,ids.tenantB]);
    await db.query('INSERT INTO org_a.employee VALUES($1,$2)',[ids.employeeA,ids.tenantA]);
    await db.query('INSERT INTO org_b.employee VALUES($1,$2)',[ids.employeeB,ids.tenantB]);
    if(!baseline) await migrate();
    await check('foundation exists without granting any organization authority',async()=>{
      assert.equal((await db.query("SELECT to_regclass('kabipay_ops.organization') IS NOT NULL AS present")).rows[0].present,true);
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM kabipay_ops.principal_role_binding')).rows[0].n,0);
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM org_a.employee')).rows[0].n,1);
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM org_b.employee')).rows[0].n,1);
    });
    await db.query('INSERT INTO kabipay_ops.organization(id,name,status) VALUES($1,$2,$3),($4,$5,$3)',[ids.orgA,'Organization A','ACTIVE',ids.orgB,'Organization B']);
    await db.query('INSERT INTO kabipay_ops.principal(id,display_name) VALUES($1,$2),($3,$4),($5,$6)',[ids.personA,'Person A',ids.personB,'Person B',ids.personC,'Person C']);
    await db.query(`INSERT INTO kabipay_ops.organization_company(id,organization_id,tenant_id,status,effective_from)
      VALUES($1,$2,$3,'ACTIVE',NOW()),($4,$2,$5,'ACTIVE',NOW())`,[ids.membershipA,ids.orgA,ids.tenantA,ids.membershipB,ids.tenantB]);
    await check('one company cannot occupy two organizations simultaneously',async()=>{
      await rejected(()=>db.query(`INSERT INTO kabipay_ops.organization_company(organization_id,tenant_id,status,effective_from) VALUES($1,$2,'ACTIVE',NOW())`,[ids.orgB,ids.tenantA]),'23505');
    });
    await check('verified source login requires verification evidence',async()=>{
      await rejected(()=>db.query(`INSERT INTO kabipay_ops.principal_login_link(principal_id,source_tenant_id,source_user_id,issuer,status) VALUES($1,$2,$3,'fixture','VERIFIED')`,[ids.personA,ids.tenantA,randomUUID()]),'23514');
    });
    await db.query('INSERT INTO kabipay_ops.organization_role(id,organization_id,name) VALUES($1,$2,$3),($4,$5,$6)',[ids.roleA,ids.orgA,'Scoped HR',ids.roleB,ids.orgB,'Other organization role']);
    await check('role bindings cannot cross organization boundaries',async()=>{
      await rejected(()=>db.query('INSERT INTO kabipay_ops.principal_role_binding(organization_id,principal_id,role_id,effective_from) VALUES($1,$2,$3,NOW())',[ids.orgA,ids.personA,ids.roleB]),'23503');
    });
    await check('wildcard and ambiguous capabilities are rejected',async()=>{
      for(const code of ['payroll:*','Payroll:manage','leave:approve ']) await rejected(()=>db.query('INSERT INTO kabipay_ops.organization_role_capability(organization_id,role_id,capability_code,employee_scope) VALUES($1,$2,$3,$4)',[ids.orgA,ids.roleA,code,'ALL']),'23514');
    });
    await db.query('INSERT INTO kabipay_ops.principal_role_binding(id,organization_id,principal_id,role_id,effective_from) VALUES($1,$2,$3,$4,NOW())',[ids.bindingA,ids.orgA,ids.personA,ids.roleA]);
    await check('company scope rejects a different organization and inactive defaults confer no authority',async()=>{
      await rejected(()=>db.query('INSERT INTO kabipay_ops.role_binding_company(organization_id,binding_id,organization_company_id) VALUES($1,$2,$3)',[ids.orgB,ids.bindingA,ids.membershipA]),'23503');
      const binding=(await db.query('SELECT status FROM kabipay_ops.principal_role_binding WHERE id=$1',[ids.bindingA])).rows[0];
      assert.equal(binding.status,'PENDING');
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM kabipay_ops.role_binding_company')).rows[0].n,0);
    });
    for(const [schema,tenant] of [['org_a',ids.tenantA],['org_b',ids.tenantB]]) {
      await db.query(`INSERT INTO ${schema}.actor_ref(tenant_id,principal_id,display_name,identity_version,last_verified_at) VALUES($1,$2,'Person A',1,NOW()),($1,$3,'Person B',1,NOW()),($1,$4,'Person C',1,NOW())`,[tenant,ids.personA,ids.personB,ids.personC]);
    }
    await check('cross-company actor references create no duplicate employment',async()=>{
      await insertAssignment('org_a');await insertAssignment('org_b');
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM org_a.employee')).rows[0].n,1);
      assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM org_b.employee')).rows[0].n,1);
    });
    await check('self reporting and reversed periods fail at the database boundary',async()=>{
      await rejected(()=>insertAssignment('org_a',{manager:ids.personA,type:'FUNCTIONAL'}),'23514');
      await rejected(()=>insertAssignment('org_a',{from:'2026-10-18T12:00:00Z',to:'2026-10-18T08:00:00Z',type:'FUNCTIONAL'}),'23514');
    });
    await check('primary overlap is rejected; adjacent periods and functional reviewers are allowed',async()=>{
      await rejected(()=>insertAssignment('org_a',{from:'2026-10-18T10:00:00Z',to:'2026-10-18T14:00:00Z'}),'23P01');
      await insertAssignment('org_a',{from:'2026-10-18T12:00:00Z',to:'2026-10-18T18:00:00Z'});
      await insertAssignment('org_a',{type:'FUNCTIONAL'});
    });
    await check('a subject employee or actor cannot be borrowed from another tenant',async()=>{
      await rejected(()=>insertAssignment('org_a',{employee:ids.employeeB,type:'FUNCTIONAL'}),'23503');
      await rejected(()=>insertAssignment('org_a',{tenant:ids.tenantB,type:'FUNCTIONAL'}),'23503');
    });
    await check('concurrent primary assignments cannot both commit',async()=>{
      const first=new Client(config),second=new Client(config);await first.connect();await second.connect();
      try {
        await first.query('BEGIN');await second.query('BEGIN');
        await second.query("SET LOCAL lock_timeout='3s'");
        const a=await assignment('org_a',{from:'2026-10-19T08:00:00Z',to:'2026-10-19T12:00:00Z'});
        const b=await assignment('org_a',{from:'2026-10-19T09:00:00Z',to:'2026-10-19T13:00:00Z'});
        await first.query(a.sql,a.values);
        const pending=second.query(b.sql,b.values).then(()=>null,error=>error);
        await new Promise(resolve=>setTimeout(resolve,100));await first.query('COMMIT');
        const error=await pending;assert.equal(error?.code,'23P01');await second.query('ROLLBACK');
      } finally {await first.end();await second.end();}
    });
    console.log(`PASS ${checks} organization foundation database scenarios`);
  } finally {
    if(db) await db.end();
    if(created) docker(['rm','-f',container]);
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
