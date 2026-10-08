// Isolated, synthetic loopback cluster. Does not read .env or any client schema.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const root = path.resolve(__dirname, '../../..');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'hrms-tax-storage-'));
const bin = process.env.PG_TEST_BIN || 'C:/Program Files/PostgreSQL/17/bin';
const tenant = '10000000-0000-0000-0000-000000000001';
const actor = '10000000-0000-0000-0000-000000000002';
const employee = '10000000-0000-0000-0000-000000000003';
function pg(name, args) {
  const fd = fs.openSync(path.join(directory, `${name}.log`), 'a');
  try {
    const result = spawnSync(path.join(bin, `${name}.exe`), args, { windowsHide: true, stdio: ['ignore', fd, fd], timeout: 60000 });
    assert.equal(result.status, 0, `${name}: ${directory}`);
  } finally { fs.closeSync(fd); }
}
async function main() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  const data = path.join(directory, 'pgdata');
  const db = new Client({ host: '127.0.0.1', port, user: 'postgres', database: 'postgres' });
  let started = false;
  try {
    pg('initdb', ['-D', data, '-U', 'postgres', '-A', 'trust', '-N', '--no-locale', '-E', 'UTF8']);
    pg('pg_ctl', ['-D', data, '-l', path.join(directory, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port}`, '-w', 'start']);
    started = true; await db.connect();
    await db.query(`CREATE SCHEMA fixture; SET search_path TO fixture,public;
      CREATE TABLE employee(tenant_id uuid,id uuid,PRIMARY KEY(tenant_id,id));
      CREATE TABLE "user"(tenant_id uuid,id uuid,PRIMARY KEY(tenant_id,id));`);
    await db.query('INSERT INTO employee VALUES($1,$2)', [tenant, employee]);
    await db.query('INSERT INTO "user" VALUES($1,$2)', [tenant, actor]);
    const xml = fs.readFileSync(path.join(root, 'changelog/migrations/0093_tax_projection_configuration/tax_projection_configuration.xml'), 'utf8');
    for (const block of xml.matchAll(/<!\[CDATA\[([\s\S]*?)\]\]>/g)) await db.query(block[1].replaceAll('${schema}', 'fixture'));
    const settings = `INSERT INTO employee_tax_settings(id,tenant_id,employee_id,revision,effective_from,payload,actor_id)
      VALUES(gen_random_uuid(),$1,$2,$3,'2026-10-01','{"regime":"NEW"}',$4)`;
    await db.query(settings, [tenant, employee, 1, actor]);
    await assert.rejects(db.query(settings, [tenant, employee, 1, actor]), /revision|unique/i);
    await assert.rejects(db.query(settings, ['20000000-0000-0000-0000-000000000001', employee, 2, actor]), /foreign key/i);
    const history = `INSERT INTO employee_tax_history(id,tenant_id,employee_id,fiscal_year,source_key,revision,
      period_start,period_end,employer,earnings,tds,coverage,payload,actor_id)
      VALUES(gen_random_uuid(),$1,$2,2026,$3,$4,$5,$6,'CURRENT',1000,$7,$8,'{}',$9)`;
    await db.query(history, [tenant, employee, 'opening', 1, '2026-04-01', '2026-08-31', null, 'INCOMPLETE', actor]);
    await assert.rejects(db.query(history, [tenant, employee, 'overlap', 1, '2026-08-01', '2026-09-30', 0, 'COMPLETE', actor]), /overlap/i);
    await assert.rejects(db.query(history, [tenant, employee, 'future', 1, '2027-04-01', '2027-04-30', 0, 'COMPLETE', actor]), /check constraint/i);
    await assert.rejects(db.query(history, [tenant, employee, 'missing', 1, '2026-09-01', '2026-09-30', null, 'COMPLETE', actor]), /check constraint/i);
    await db.query(history, [tenant, employee, 'opening', 2, '2026-04-01', '2026-08-31', 0, 'COMPLETE', actor]);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM employee_tax_history')).rows[0].n, 2);
    await assert.rejects(db.query('UPDATE employee_tax_history SET earnings=2'), /append.only/i);
    console.log('PASS tenant ownership, history bounds, overlap, revisions, unknown TDS and immutable audit');
  } finally {
    await db.end().catch(() => {});
    if (started) pg('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
    console.log(`Synthetic fixture evidence: ${directory}`);
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
