// Synthetic dependency rehearsal only. No .env, production data or live DSNs.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {Client}=require('pg');
const {fixture}=require('../../private-events/tests/local-postgres-fixture.cjs');
const root=path.resolve(__dirname,'../../..');
const opsFile=path.join(root,'changelog/migrations/0128_integration_catalog_identity/integration_catalog_identity.xml');
const tenantFile=path.join(root,'changelog/migrations/0129_company_database_dependencies/company_database_dependencies.xml');
function forwardSql(file,schema) {
  const xml=fs.readFileSync(file,'utf8');
  // Exclude the intentionally rejecting rollback block.
  const forward=xml.split('<rollback>')[0];
  return [...forward.matchAll(/<!\[CDATA\[([\s\S]*?)\]\]>/g)].map(m=>m[1]).join('\n').replaceAll('${schema}',schema);
}
const connector='11111111-1111-4111-8111-111111111111',missing='22222222-2222-4222-8222-222222222222';
const scope='33333333-3333-4333-8333-333333333333';
const otherScope='44444444-4444-4444-8444-444444444444';
function tenantFixture(schema,tenant=scope) {
  return `CREATE SCHEMA "${schema}";
CREATE TABLE "${schema}".tenant_integration(id uuid PRIMARY KEY,tenant_id uuid NOT NULL,integration_connector_id uuid NOT NULL,
 credentials_encrypted text,config_json jsonb,is_active boolean NOT NULL,connected_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT uq_tenant_integration_tenant_connector UNIQUE(tenant_id,integration_connector_id),
 CONSTRAINT fk_tenant_integration_connector FOREIGN KEY(integration_connector_id) REFERENCES kabipay_ops.integration_connector(id) ON DELETE RESTRICT);
INSERT INTO "${schema}".tenant_integration VALUES('${tenant}','${tenant}','${connector}','synthetic-only','{"preserve":true}',true,'2000-01-01','2000-01-01','2000-01-01');
CREATE TRIGGER stamp BEFORE UPDATE ON "${schema}".tenant_integration FOR EACH ROW WHEN (NEW.is_active AND NEW.credentials_encrypted <> 'EXECUTE FUNCTION kabipay_ops.set_updated_at()') EXECUTE FUNCTION kabipay_ops.set_updated_at();
COMMENT ON TRIGGER stamp ON "${schema}".tenant_integration IS 'Preserve this synthetic comment';
CREATE TRIGGER disabled_stamp BEFORE UPDATE ON "${schema}".tenant_integration FOR EACH ROW EXECUTE FUNCTION kabipay_ops.set_updated_at();
ALTER TABLE "${schema}".tenant_integration DISABLE TRIGGER disabled_stamp;
CREATE TRIGGER replica_stamp BEFORE UPDATE ON "${schema}".tenant_integration FOR EACH ROW EXECUTE FUNCTION kabipay_ops.set_updated_at();
ALTER TABLE "${schema}".tenant_integration ENABLE REPLICA TRIGGER replica_stamp;
CREATE TRIGGER always_stamp BEFORE UPDATE ON "${schema}".tenant_integration FOR EACH ROW EXECUTE FUNCTION kabipay_ops.set_updated_at();
ALTER TABLE "${schema}".tenant_integration ENABLE ALWAYS TRIGGER always_stamp;
CREATE TABLE "${schema}"."${schema}_databasechangelog"(id text,md5sum text);
INSERT INTO "${schema}"."${schema}_databasechangelog" VALUES('synthetic-history-marker','preserve-checksum');
CREATE TABLE "${schema}".period_claim(id bigserial PRIMARY KEY,employee_id uuid,active_range tstzrange,
 EXCLUDE USING gist(employee_id public.gist_uuid_ops WITH =,active_range WITH &&));
INSERT INTO "${schema}".period_claim(employee_id,active_range) VALUES('${tenant}',tstzrange('2000-01-01','2000-01-02','[)'));
SELECT setval(pg_get_serial_sequence('"${schema}".period_claim','id'),7,true);`;
}

async function checkApplicationSql(pg,database,schema,tenant) {
  // Execute the actual Rust SQL constants using a restricted company login.
  const rust=fs.readFileSync(path.join(root,'../hrms-svc/crates/kabipay-analytics/src/services/integration_connections.rs'),'utf8');
  const insert=rust.match(/const REFERENCE_SQL: &str =\s*"([^"]+)";/)?.[1];
  const connect=rust.match(/const CONNECT_SQL: &str = r#"([\s\S]*?)"#;/)?.[1];
  assert(insert && connect,'Actual application SQL constants required');
  pg.query(database,`GRANT USAGE ON SCHEMA "${schema}" TO integration_runtime;
GRANT SELECT,INSERT ON "${schema}".integration_connector_ref TO integration_runtime;
GRANT SELECT,INSERT ON "${schema}".tenant_integration TO integration_runtime;
GRANT UPDATE(is_active,connected_at,updated_at) ON "${schema}".tenant_integration TO integration_runtime;`);
  const clients=[new Client(pg.connection(database,'integration_runtime')),new Client(pg.connection(database,'integration_runtime'))];
  try {
    for(const client of clients) {await client.connect();await client.query(`SET search_path="${schema}",pg_catalog`);}
    const before=(await clients[0].query('SELECT id,credentials_encrypted,config_json,created_at FROM tenant_integration')).rows[0];
    async function write(client,id) {
      await client.query('BEGIN');
      try {
        await client.query(insert,[id]);
        const row=(await client.query(connect,[require('node:crypto').randomUUID(),tenant,id,new Date()])).rows[0];
        await client.query('COMMIT');return row;
      } catch(error) {await client.query('ROLLBACK');throw error;}
    }
    const reconnected=await write(clients[0],connector);
    for(const key of ['id','credentials_encrypted','config_json','created_at']) assert.deepEqual(reconnected[key],before[key]);
    const fresh='55555555-5555-4555-8555-555555555555';
    const rows=await Promise.all(clients.map(client=>write(client,fresh)));
    assert.equal(rows[0].id,rows[1].id,'Concurrent connects must converge on one integration');
    assert.equal((await clients[0].query('SELECT count(*)::int n FROM tenant_integration WHERE integration_connector_id=$1',[fresh])).rows[0].n,1);
    // The local reference is not admission authority; Rust tests exercise the
    // central active-catalog check that must precede this SQL transaction.
    await assert.rejects(clients[0].query('DELETE FROM integration_connector_ref'),/permission denied/);
  } finally {await Promise.all(clients.map(client=>client.end()));}
}

test('forward dependencies migrate and restore two company schemas without ops catalog/helper',{timeout:240000},async()=>{
  assert(fs.existsSync(opsFile),'0128 forward catalog identity migration required');
  assert(fs.existsSync(tenantFile),'0129 forward tenant dependency migration required');
  assert(fs.readFileSync(path.join(root,'changelog/db.changelog-master.xml'),'utf8').includes('0128_integration_catalog_identity'));
  assert(fs.readFileSync(path.join(root,'changelog/tenant.changelog-master.xml'),'utf8').includes('0129_company_database_dependencies'));
  const pg=await fixture();
  function migrate(file,schema,error) {
    const result=pg.psql('postgres',{sql:'BEGIN;'+forwardSql(file,schema)+'COMMIT;'});
    if(error) {assert.notEqual(result.status,0);assert.match(result.stderr,error);}
    else assert.equal(result.status,0,result.stderr);
  }
  function denied(database,sql,pattern) {const result=pg.psql(database,{sql});assert.notEqual(result.status,0);assert.match(result.stderr,pattern);}
  try {
    pg.query('postgres',`CREATE EXTENSION btree_gist WITH SCHEMA public;CREATE SCHEMA kabipay_ops;
CREATE FUNCTION kabipay_ops.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN NEW.updated_at = NOW(); RETURN NEW; END;';
CREATE TABLE kabipay_ops.integration_connector(id uuid PRIMARY KEY,code text UNIQUE,is_active boolean NOT NULL);
INSERT INTO kabipay_ops.integration_connector VALUES('${connector}','HISTORICAL',false);
${tenantFixture('tenant_one')}
${tenantFixture('Tenant_Two',otherScope)}
CREATE ROLE integration_runtime LOGIN;`);
    migrate(tenantFile,'tenant_one',/catalog identity/);
    assert.equal(pg.query('postgres',"SELECT to_regclass('tenant_one.integration_connector_ref') IS NULL;").trim(),'t');
    migrate(opsFile);
    for(const sql of [`DELETE FROM kabipay_ops.integration_connector;`,`TRUNCATE kabipay_ops.integration_connector CASCADE;`,
      `UPDATE kabipay_ops.integration_connector SET id='${missing}';`]) denied('postgres',sql,/immutable|retained|identity/);
    // Historical inactive connectors are deliberately retained by the backfill.
    // Unknown source-helper behavior must reject before changing tenant objects.
    pg.query('postgres',"CREATE OR REPLACE FUNCTION kabipay_ops.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN NEW.updated_at=clock_timestamp(); RETURN NEW; END;';");
    migrate(tenantFile,'tenant_one',/helper/);
    pg.query('postgres',"CREATE OR REPLACE FUNCTION kabipay_ops.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN NEW.updated_at = NOW(); RETURN NEW; END;';");
    // Independent rollback-only probes reproduce all three final-review cases.
    const regression={};
    pg.query('postgres','ALTER FUNCTION kabipay_ops.set_updated_at() SET search_path=public,pg_catalog;');
    let probe=pg.psql('postgres',{sql:'BEGIN;'+forwardSql(tenantFile,'tenant_one')+'ROLLBACK;'});
    regression.unreviewedHelperConfigurationRejected=probe.status!==0 && /helper/.test(probe.stderr);
    pg.query('postgres','ALTER FUNCTION kabipay_ops.set_updated_at() RESET ALL;');
    probe=pg.psql('postgres',{sql:'BEGIN;SET LOCAL search_path=kabipay_ops,public;'+forwardSql(tenantFile,'tenant_one')+'ROLLBACK;'});
    regression.visibleOpsHelperSupported=probe.status===0;
    probe=pg.psql('postgres',{sql:'BEGIN;'+forwardSql(tenantFile,'tenant_one')+"SELECT 'condition-preserved='||(position('EXECUTE FUNCTION kabipay_ops.set_updated_at()' in pg_get_triggerdef(oid))>0)::text FROM pg_trigger WHERE tgrelid='tenant_one.tenant_integration'::regclass AND tgname='stamp';ROLLBACK;"});
    regression.conditionLiteralPreserved=probe.status===0 && probe.stdout.includes('condition-preserved=true');
    assert.deepEqual(regression,{unreviewedHelperConfigurationRejected:true,visibleOpsHelperSupported:true,conditionLiteralPreserved:true});
    pg.query('postgres',tenantFixture('tenant_bad')+'DROP TRIGGER stamp ON tenant_bad.tenant_integration;CREATE TRIGGER stamp AFTER UPDATE ON tenant_bad.tenant_integration FOR EACH ROW EXECUTE FUNCTION kabipay_ops.set_updated_at();');
    migrate(tenantFile,'tenant_bad',/Unsupported timestamp helper trigger/);
    assert.equal(pg.query('postgres',"SELECT to_regclass('tenant_bad.integration_connector_ref') IS NULL;").trim(),'t');
    for(const [schema,database] of [['tenant_one','company_one'],['Tenant_Two','company_two']]) {
      const tenant=schema==='tenant_one'?scope:otherScope;
      const before=pg.query('postgres',`SELECT row_to_json(i)::text FROM "${schema}".tenant_integration i;`);
      migrate(tenantFile,schema);
      assert.equal(pg.query('postgres',`SELECT row_to_json(i)::text FROM "${schema}".tenant_integration i;`),before);
      assert.equal(pg.query('postgres',`SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace WHERE n.nspname='${schema}' AND NOT t.tgisinternal AND pn.nspname<>n.nspname;`).trim(),'0');
      const modes=pg.query('postgres',`SELECT string_agg(tgname||':'||tgenabled::text,',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='"${schema}".tenant_integration'::regclass AND NOT tgisinternal;`);
      assert.equal(modes.trim(),'always_stamp:A,disabled_stamp:D,replica_stamp:R,stamp:O');
      const dump=path.join(pg.directory,database+'.dump');
      pg.archive('pg_dump','postgres',['--format=custom','--no-owner','--no-acl','--schema="'+schema+'"','--file='+dump]);
      pg.query('postgres',`CREATE DATABASE ${database};`);
      assert.throws(()=>pg.archive('pg_restore',database,['--exit-on-error','--single-transaction','--no-owner','--no-acl',dump]),/data type uuid has no default operator class for access method "gist"/);
      assert.equal(pg.query(database,`SELECT to_regnamespace('${schema}') IS NULL;`).trim(),'t','Failed restore must roll back target schema');
      pg.query(database,'CREATE EXTENSION btree_gist WITH SCHEMA public;');
      pg.archive('pg_restore',database,['--exit-on-error','--single-transaction','--no-owner','--no-acl',dump]);
      assert.equal(pg.query(database,"SELECT to_regnamespace('kabipay_ops') IS NULL;").trim(),'t');
      assert.equal(pg.query(database,`SELECT row_to_json(i)::text FROM "${schema}".tenant_integration i;`),before);
      assert.equal(pg.query(database,`SELECT md5sum FROM "${schema}"."${schema}_databasechangelog";`).trim(),'preserve-checksum');
      assert.equal(pg.query(database,`SELECT obj_description(oid,'pg_trigger') FROM pg_trigger WHERE tgrelid='"${schema}".tenant_integration'::regclass AND tgname='stamp';`).trim(),'Preserve this synthetic comment');
      const restoredTrigger=pg.query(database,`SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid='"${schema}".tenant_integration'::regclass AND tgname='stamp';`);
      assert.match(restoredTrigger,/WHEN \(\(new.is_active AND/i);
      assert(restoredTrigger.includes("'EXECUTE FUNCTION kabipay_ops.set_updated_at()'"),'Trigger condition literal must survive migration/restore unchanged');
      assert.equal(pg.query(database,`SELECT nextval(pg_get_serial_sequence('"${schema}".period_claim','id'));`).trim(),'8');
      denied(database,`INSERT INTO "${schema}".tenant_integration(id,tenant_id,integration_connector_id,is_active) VALUES('${missing}','${tenant}','${missing}',true);`,/foreign key/);
      pg.query(database,`UPDATE "${schema}".tenant_integration SET connected_at=now();`);
      assert.equal(pg.query(database,`SELECT updated_at>'2000-01-02'::timestamptz FROM "${schema}".tenant_integration;`).trim(),'t');
      assert.equal(pg.query(database,`SELECT to_regnamespace('${schema==='tenant_one'?'Tenant_Two':'tenant_one'}') IS NULL;`).trim(),'t');
      pg.query('postgres',`UPDATE kabipay_ops.integration_connector SET is_active=true;
INSERT INTO kabipay_ops.integration_connector VALUES('55555555-5555-4555-8555-555555555555','NEW',true) ON CONFLICT DO NOTHING;`);
      await checkApplicationSql(pg,database,schema,tenant);
    }
  } finally {pg.stop();console.log('Synthetic dependency rehearsal retained: '+pg.directory);}
});
