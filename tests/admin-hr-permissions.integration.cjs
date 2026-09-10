// Creates its own disposable, loopback-only PostgreSQL cluster. Never loads .env.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const { readDefaults } = require('../scripts/check-permission-defaults.cjs');
const bin = process.env.PG_TEST_BIN || 'C:/Program Files/PostgreSQL/17/bin';
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hrms-rbac-test-'));
const data = path.join(dir, 'data');
const port = 55489;
function pg(command, args) {
  // A PostgreSQL child can inherit pipe handles on Windows, keeping spawnSync
  // blocked after pg_ctl exits. File descriptors avoid that pipe lifetime issue.
  const output = fs.openSync(path.join(dir, `${command}.log`), 'a');
  let result;
  try { result = spawnSync(path.join(bin, command), args, { windowsHide: true, stdio: ['ignore',output,output], timeout: 60000 }); }
  finally { fs.closeSync(output); }
  if (result.error || result.status !== 0) throw new Error(`${command}: ${result.error || result.stderr || result.stdout}`);
}
async function main() {
  let started = false;
  const db = new Client({ host: '127.0.0.1', port, database: 'postgres', user: 'postgres' });
  try {
    pg('initdb', ['-D', data, '-U', 'postgres', '-A', 'trust', '--no-locale', '-E', 'UTF8']);
    started = true;
    pg('pg_ctl', ['-D', data, '-l', path.join(dir, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port}`, '-w', 'start']);
    await db.connect();
    const tenant = '00000000-0000-0000-0000-000000000001';
    const other = '00000000-0000-0000-0000-000000000002';
    await db.query(`
      CREATE SCHEMA kabipay_ops; CREATE SCHEMA tenant_test;
      CREATE TABLE kabipay_ops.tenant_database(tenant_id UUID, schema_name TEXT);
      INSERT INTO kabipay_ops.tenant_database VALUES ('${tenant}','tenant_test');
      CREATE TABLE tenant_test.role(id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id UUID NOT NULL, name TEXT NOT NULL, is_deleted BOOLEAN NOT NULL DEFAULT false);
      CREATE TABLE tenant_test.permission(id UUID PRIMARY KEY DEFAULT gen_random_uuid(),resource TEXT NOT NULL,action TEXT NOT NULL);
      CREATE TABLE tenant_test.role_permission(role_id UUID REFERENCES tenant_test.role,permission_id UUID REFERENCES tenant_test.permission,PRIMARY KEY(role_id,permission_id));
      CREATE TABLE tenant_test.permission_scope(id UUID PRIMARY KEY,tenant_id UUID NOT NULL,role_id UUID REFERENCES tenant_test.role,resource TEXT NOT NULL,action TEXT NOT NULL,scope_type TEXT NOT NULL);
      INSERT INTO tenant_test.role(tenant_id,name) VALUES ('${tenant}','ADMIN'),('${tenant}','HR'),('${tenant}','CUSTOM'),('${other}','ADMIN');
    `);
    for (const d of readDefaults().values()) await db.query('INSERT INTO tenant_test.permission(resource,action) VALUES($1,$2)', [d.resource,d.action]);
    const xml = fs.readFileSync(path.join(__dirname, '../changelog/migrations/0085_admin_hr_permission_defaults/admin_hr_permission_defaults.xml'), 'utf8');
    const sql = xml.match(/<sql splitStatements="false"><!\[CDATA\[([\s\S]*?)\]\]><\/sql>/)[1].replaceAll('${schema}', 'tenant_test');
    const migrate = async () => {
      await db.query('BEGIN');
      try { await db.query(sql); await db.query('COMMIT'); }
      catch (e) { await db.query('ROLLBACK'); throw e; }
    };
    const snapshot = async () => (await db.query(`SELECT json_build_object(
      'grants',(SELECT json_agg(x ORDER BY role_id,permission_id) FROM tenant_test.role_permission x),
      'scopes',(SELECT json_agg(x ORDER BY id) FROM tenant_test.permission_scope x)) AS state`)).rows[0].state;
    await migrate();
    const grants = (await db.query(`SELECT r.name,p.resource,p.action,s.scope_type FROM tenant_test.role r
      JOIN tenant_test.role_permission rp ON rp.role_id=r.id JOIN tenant_test.permission p ON p.id=rp.permission_id
      JOIN tenant_test.permission_scope s ON s.role_id=r.id AND s.resource=p.resource AND s.action=p.action`)).rows;
    for (const name of ['ADMIN','HR']) {
      for (const [resource,action,scope] of [['prejoining','manage','ALL'],['prejoining','review','ALL'],['survey','manage','ALL'],['survey','results','ALL'],['survey','respond','SELF'],['role','manage','ALL'],['performance','self','SELF']]) {
        assert.ok(grants.some(g => g.name===name && g.resource===resource && g.action===action && g.scope_type===scope), `${name} ${resource}:${action} ${scope}`);
      }
    }
    assert.equal(grants.filter(g => g.action==='evaluate').length, 0);
    assert.equal((await db.query(`SELECT COUNT(*)::int n FROM tenant_test.role_permission rp JOIN tenant_test.role r ON r.id=rp.role_id WHERE r.tenant_id=$1 OR r.name='CUSTOM'`,[other])).rows[0].n,0);
    const fresh = await snapshot(); await migrate(); assert.deepEqual(await snapshot(),fresh);
    console.log('PASS fresh defaults, exact scopes, role/tenant isolation, repeat execution');

    const auditSource = fs.readFileSync(path.join(__dirname,'../scripts/audit-admin-hr-permissions.cjs'),'utf8');
    const auditSql = auditSource.match(/db\.query\(`(WITH defaults[\s\S]*?)`,/)[1].replaceAll('${schema}','tenant_test');
    const audit = async () => (await db.query(auditSql,[JSON.stringify([...readDefaults().values()]),tenant])).rows;
    assert.ok((await audit()).every(row => row.status==='OK'));
    const seed = fs.readFileSync(path.join(__dirname,'../scripts/seed-demo-data.ps1'),'utf8');
    const seedSql = seed.slice(seed.indexOf('DELETE FROM canonical_permission_matrix AS matrix'),seed.indexOf('DELETE FROM "$Schema".role_permission AS role_permission'))
      .replaceAll('$Schema','tenant_test').replaceAll('$PermissionDefaultsJsonSql',JSON.stringify([...readDefaults().values()]));
    await db.query('CREATE TEMP TABLE canonical_permission_matrix(role_name TEXT,resource TEXT,action TEXT,scope_type TEXT,PRIMARY KEY(role_name,resource,action))');
    await db.query(seedSql);
    const seeded = (await db.query('SELECT * FROM canonical_permission_matrix')).rows;
    assert.equal(seeded.length,grants.length);
    for (const g of grants) assert.ok(seeded.some(s => s.role_name===g.name && s.resource===g.resource && s.action===g.action && s.scope_type===g.scope_type));
    await db.query(seedSql);
    assert.equal((await db.query('SELECT COUNT(*)::int n FROM canonical_permission_matrix')).rows[0].n,seeded.length);
    console.log('PASS audit SQL and seed defaults agree with migrated grants');

    await db.query(`UPDATE tenant_test.permission_scope SET scope_type='TEAM' WHERE resource='survey' AND action='results';
      INSERT INTO tenant_test.permission_scope SELECT gen_random_uuid(),tenant_id,id,'custom','read','SELF' FROM tenant_test.role WHERE name='CUSTOM';
      INSERT INTO tenant_test.role_permission SELECT r.id,p.id FROM tenant_test.role r CROSS JOIN tenant_test.permission p WHERE r.name='CUSTOM' AND p.resource='survey' AND p.action='manage';`);
    const restricted = await snapshot(); await migrate(); assert.deepEqual(await snapshot(),restricted);
    assert.equal((await audit()).filter(row => row.status==='PRESERVED_SCOPE_DIFFERS').length,2);
    console.log('PASS existing restrictions and custom grants preserved');

    await db.query(`DELETE FROM tenant_test.permission_scope WHERE resource='prejoining';
      DELETE FROM tenant_test.role_permission WHERE permission_id IN (SELECT id FROM tenant_test.permission WHERE resource='prejoining');`);
    assert.equal((await audit()).filter(row => row.status==='MISSING_GRANT').length,4);
    await migrate();
    assert.equal((await db.query(`SELECT COUNT(*)::int n FROM tenant_test.permission_scope WHERE resource='prejoining'`)).rows[0].n,4);
    console.log('PASS missing grants and scopes repaired');

    for (const setup of [
      `INSERT INTO tenant_test.role(tenant_id,name) VALUES ('${tenant}',' hr ')`,
      `INSERT INTO tenant_test.permission(resource,action) VALUES ('prejoining','manage')`,
      `INSERT INTO kabipay_ops.tenant_database VALUES ('${other}','tenant_test')`,
      `UPDATE tenant_test.permission_scope SET tenant_id='${other}' WHERE resource='prejoining'`,
      `UPDATE tenant_test.role SET is_deleted=true WHERE name='HR'`,
      `UPDATE tenant_test.permission SET resource='missing_catalog' WHERE resource='prejoining' AND action='manage'`
    ]) {
      await db.query('BEGIN'); await db.query(setup); await db.query('SAVEPOINT invalid_fixture');
      await assert.rejects(db.query(sql), /0085/);
      await db.query('ROLLBACK');
    }
    console.log('PASS ambiguous roles/catalog/tenant mapping, cross-tenant scopes, deleted roles and missing prerequisites fail closed');
  } finally {
    await db.end().catch(() => {});
    if (started && fs.existsSync(path.join(data,'postmaster.pid'))) pg('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
    // Deliberately retain only this generated cluster for diagnostics; print exact path.
    console.log(`Temporary test files: ${dir}`);
  }
}
main().catch(e => { console.error(e); process.exitCode=1; });
