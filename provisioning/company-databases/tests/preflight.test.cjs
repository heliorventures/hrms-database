// Only creates an owned, disposable local PostgreSQL cluster. No .env or live DSN.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const {spawnSync} = require('node:child_process');
const sql = path.resolve(__dirname, '../preflight.sql');

test('preflight reports metadata without changing the source', {timeout: 180000}, async () => {
  assert(fs.existsSync(sql), 'preflight.sql must exist');
  const bin = process.env.PREFLIGHT_TEST_PG_BIN;
  assert(bin && path.isAbsolute(bin), 'Set PREFLIGHT_TEST_PG_BIN to native PostgreSQL bin directory');
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'hrms-preflight-test-'));
  const data = path.join(folder, 'data');
  const executable = name => path.join(bin, name + (process.platform === 'win32' ? '.exe' : ''));
  function command(name, args, input) {
    // On Windows the server inherits pg_ctl's captured pipes and keeps them open.
    // pg_ctl writes its startup log to a file; do not give it captured handles.
    const result = spawnSync(executable(name), args, {input, encoding:'utf8', windowsHide:true, timeout:60000,
      ...(name === 'pg_ctl' ? {stdio:'ignore'} : {})});
    assert(!result.error, String(result.error) + '\n' + result.stdout + '\n' + result.stderr);
    return result;
  }
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  function psql(args, input) {
    return command('psql', ['-X','-qAt','-w','-h','127.0.0.1','-p',String(port),'-U','preflight_fixture',
      '-d','postgres','-v','ON_ERROR_STOP=1', ...args], input);
  }
  function query(input) {
    const result = psql([], input); assert.equal(result.status, 0, result.stderr); return result.stdout;
  }
  try {
    const init = command('initdb', ['-D', data, '-U','preflight_fixture','--auth=trust','--encoding=UTF8','--no-locale','--no-sync']);
    assert.equal(init.status, 0, init.stderr);
    const start = command('pg_ctl', ['-D',data,'-l',path.join(folder,'postgres.log'),'-o',`-h 127.0.0.1 -p ${port}`,'-w','start']);
    assert.equal(start.status, 0, 'Read owned fixture postgres.log for startup failure');
    query(`
CREATE SCHEMA kabipay_ops; CREATE SCHEMA tenant_one; CREATE SCHEMA tenant_two;
CREATE TABLE kabipay_ops.tenant(id uuid,subdomain text,status text,is_deleted boolean);
CREATE TABLE kabipay_ops.tenant_database(id uuid,tenant_id uuid,db_type text,db_host text,db_name text,schema_name text,is_active boolean);
INSERT INTO kabipay_ops.tenant VALUES
 ('11111111-1111-4111-8111-111111111111','one','ACTIVE',false),
 ('22222222-2222-4222-8222-222222222222','two','SUSPENDED',false),
 ('33333333-3333-4333-8333-333333333333','unmapped','ACTIVE',false),
 ('44444444-4444-4444-8444-444444444444','deleted','ACTIVE',true);
INSERT INTO kabipay_ops.tenant_database VALUES
 (gen_random_uuid(),'11111111-1111-4111-8111-111111111111','POSTGRES','postgres','postgres','tenant_one',true),
 (gen_random_uuid(),'22222222-2222-4222-8222-222222222222','POSTGRES','postgres','postgres','tenant_two',true);
CREATE TABLE kabipay_ops.integration_connector(id uuid PRIMARY KEY);
CREATE FUNCTION kabipay_ops.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS
 'BEGIN NEW.updated_at=now(); RETURN NEW; END';
CREATE TABLE tenant_one.tenant_integration(id uuid,tenant_id uuid,integration_connector_id uuid REFERENCES kabipay_ops.integration_connector(id), updated_at timestamptz);
CREATE TRIGGER stamp BEFORE UPDATE ON tenant_one.tenant_integration FOR EACH ROW EXECUTE FUNCTION kabipay_ops.set_updated_at();
CREATE VIEW kabipay_ops.incoming_view AS SELECT id FROM tenant_one.tenant_integration;
CREATE TABLE tenant_one.tenant_one_databasechangelog(id text,author text,filename text,orderexecuted integer);
INSERT INTO tenant_one.tenant_one_databasechangelog VALUES('0109-done','fixture','migration.xml',259);
CREATE TABLE tenant_one.databasechangeloglock(id integer,locked boolean);
INSERT INTO tenant_one.databasechangeloglock VALUES(1,true);
`);
    const before = query('SELECT md5(string_agg(row_to_json(t)::text,\'\' ORDER BY id)) FROM kabipay_ops.tenant t');
    const result = psql(['-v','expected_database=postgres','-f',sql]);
    assert.equal(result.status, 0, result.stderr);
    const records = result.stdout.trim().split(/\r?\n/).filter(Boolean).map(JSON.parse);
    const report = records.find(x => x.section === 'inventory');
    assert.equal(report.tenants.length, 3);
    assert.equal(report.tenants.find(x => x.subdomain === 'unmapped').mappings.length, 0);
    assert.equal(report.foreign_keys.length, 1);
    assert.equal(report.foreign_keys[0].referenced_schema, 'kabipay_ops');
    assert.equal(report.external_triggers[0].function_schema, 'kabipay_ops');
    assert(report.external_views.some(x=>x.view_schema==='kabipay_ops' && x.referenced_schema==='tenant_one'));
    assert.equal(report.history_tables.find(x=>x.schema==='tenant_two').history_present,false);
    assert.equal(report.relations.some(x => x.schema === 'tenant_one'), true);
    assert.equal(report.transaction_read_only, 'on');
    const history = records.find(x => x.section === 'history' && x.schema === 'tenant_one');
    assert.equal(history.applied_count, 1);
    assert.equal(history.latest[0].id, '0109-done');
    assert(records.some(x => x.section === 'migration_lock' && x.locked === true));
    assert.equal(records.at(-1).section, 'complete');
    assert.equal(query('SELECT md5(string_agg(row_to_json(t)::text,\'\' ORDER BY id)) FROM kabipay_ops.tenant t'), before);
    const wrong = psql(['-v','expected_database=wrong_database','-f',sql]);
    assert.notEqual(wrong.status, 0);
    assert.match(wrong.stderr, /Source database mismatch/);
    assert(!wrong.stdout.includes('"section": "complete"'));
    query(`INSERT INTO kabipay_ops.tenant_database SELECT gen_random_uuid(),tenant_id,db_type,db_host,db_name,schema_name,is_active FROM kabipay_ops.tenant_database WHERE schema_name='tenant_one';`);
    const duplicate = psql(['-v','expected_database=postgres','-f',sql]);
    assert.equal(duplicate.status, 0, duplicate.stderr);
    assert.equal(JSON.parse(duplicate.stdout.trim().split(/\r?\n/)[0]).tenants.find(x=>x.subdomain==='one').mappings.length,2);
    query('DROP TABLE kabipay_ops.tenant_database');
    const absent = psql(['-v','expected_database=postgres','-f',sql]);
    assert.notEqual(absent.status,0);
    assert.match(absent.stderr,/Central tenant registry missing/);
  } finally {
    if (fs.existsSync(path.join(data,'postmaster.pid'))) {
      const stop = command('pg_ctl', ['-D',data,'-m','fast','-w','stop']);
      assert.equal(stop.status, 0, stop.stderr);
    }
    // Keep the owned fixture/log for diagnosis. No arbitrary recursive deletion.
    console.log('Owned fixture retained: ' + folder);
  }
});
