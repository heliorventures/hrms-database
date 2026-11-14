const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {fixture}=require('./local-postgres-fixture.cjs');
const root=path.resolve(__dirname,'../../..');

test('actual Rust installer keeps lifecycle receipts immutable with concurrent commands',{timeout:1900000},async()=>{
  const pg=await fixture();
  try {
    pg.query('postgres','CREATE DATABASE lifecycle_fixture');
    const xml=fs.readFileSync(path.join(root,'changelog/migrations/0117_organization_membership_lifecycle/organization_membership_lifecycle.xml'),'utf8');
    const ddl=xml.split('<![CDATA[')[1].split(']]>')[0].replaceAll('${schema}','source');
    // Start from the pre-0117 shape: the actual migration below adds grant status.
    pg.query('lifecycle_fixture',`REVOKE CONNECT ON DATABASE lifecycle_fixture FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA source;
CREATE TABLE source.organization_grant_installation(tenant_id uuid,organization_id uuid,membership_version bigint);
CREATE TABLE source.organization_fact_bootstrap(tenant_id uuid,organization_id uuid,phase integer NOT NULL DEFAULT 0,after_id uuid,status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','COMPLETE')),updated_at timestamptz DEFAULT now(),PRIMARY KEY(tenant_id,organization_id));
${ddl}
CREATE ROLE lifecycle_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT CONNECT ON DATABASE lifecycle_fixture TO lifecycle_runtime;
GRANT USAGE ON SCHEMA source TO lifecycle_runtime;
GRANT SELECT ON source.organization_membership_installation,source.organization_membership_lifecycle_receipt,source.organization_grant_installation,source.organization_fact_bootstrap TO lifecycle_runtime;
GRANT INSERT(tenant_id,membership_id,organization_id,status,desired_status,version,configuration_hash,retirement_transaction_id),UPDATE(status,desired_status,version,configuration_hash,retirement_transaction_id,installed_at) ON source.organization_membership_installation TO lifecycle_runtime;
GRANT INSERT(tenant_id,command_id,membership_id,organization_id,version,desired_status,status,configuration_hash) ON source.organization_membership_lifecycle_receipt TO lifecycle_runtime;
GRANT UPDATE(status) ON source.organization_grant_installation TO lifecycle_runtime;
GRANT INSERT(tenant_id,organization_id,phase,after_id,status),UPDATE(phase,after_id,status,updated_at) ON source.organization_fact_bootstrap TO lifecycle_runtime;`);
    assert.equal(pg.query('lifecycle_fixture',"SELECT count(*) FROM information_schema.columns WHERE table_schema='source' AND table_name='organization_grant_installation' AND column_name='status'").trim(),'1','actual 0117 migration must add grant status before the runtime grants');
    const connection=pg.connection('lifecycle_fixture','lifecycle_runtime');
    const env={...process.env,LIFECYCLE_PERMISSION_TEST_DATABASE_URL:`postgres://lifecycle_runtime@127.0.0.1:${connection.port}/lifecycle_fixture`};
    const result=spawnSync('cargo',['test','--lib','--offline','--locked','-p','kabipay-organization-tenant',
      'membership_lifecycle::permission_tests::immutable_receipt_serializes_same_command_across_memberships','--','--ignored','--exact','--nocapture'],
    {cwd:path.join(root,'../hrms-svc'),env,encoding:'utf8',windowsHide:true,timeout:1800000});
    assert(!result.error,String(result.error));
    assert.equal(result.status,0,result.stdout+'\n'+result.stderr);
    assert.match(result.stdout,/1 passed; 0 failed/);
    console.log(result.stdout.trim());
  } finally {pg.stop();console.log('Owned lifecycle receipt fixture retained: '+pg.directory);}
});
