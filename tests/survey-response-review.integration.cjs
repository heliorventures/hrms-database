// Disposable loopback PostgreSQL only. Does not read environment connection secrets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const bin = process.env.PG_TEST_BIN || 'C:/Program Files/PostgreSQL/17/bin';
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hrms-survey-review-'));
const data = path.join(dir, 'data');
const port = 55491;
function pg(command, args) {
  const output = fs.openSync(path.join(dir, `${command}.log`), 'a');
  let result;
  try { result = spawnSync(path.join(bin, command), args, { windowsHide: true, stdio: ['ignore', output, output], timeout: 60000 }); }
  finally { fs.closeSync(output); }
  if (result.error || result.status !== 0) throw new Error(`${command}: ${result.error || result.status}`);
}
async function main() {
  const db = new Client({ host: '127.0.0.1', port, database: 'postgres', user: 'postgres' });
  let started = false;
  try {
    pg('initdb', ['-D', data, '-U', 'postgres', '-A', 'trust', '--no-locale', '--no-sync', '-E', 'UTF8']);
    pg('pg_ctl', ['-D', data, '-l', path.join(dir, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port}`, '-w', 'start']);
    started = true;
    await db.connect();
    await db.query(`CREATE SCHEMA tenant_test;
      CREATE TABLE tenant_test.survey(id INT PRIMARY KEY,status TEXT NOT NULL);
      CREATE TABLE tenant_test.survey_question(id INT PRIMARY KEY,question_type TEXT NOT NULL);
      CREATE TABLE tenant_test.survey_answer(id INT PRIMARY KEY);
      CREATE TABLE tenant_test.survey_response(id UUID PRIMARY KEY,tenant_id UUID,survey_id INT);
      INSERT INTO tenant_test.survey VALUES(1,'PUBLISHED'),(2,'CLOSED'),(3,'DRAFT');
      INSERT INTO tenant_test.survey_question VALUES(1,'RATING'),(2,'LONG_TEXT');
      INSERT INTO tenant_test.survey_answer VALUES(1);`);
    const xml = fs.readFileSync(path.join(__dirname, '../changelog/migrations/0086_survey_response_review/survey_response_review.xml'), 'utf8');
    // Execute the migration's real addColumn declarations and SQL, preserving defaults/constraints.
    for (const [, table, body] of xml.matchAll(/<addColumn schemaName="\$\{schema\}" tableName="(\w+)">([\s\S]*?)<\/addColumn>/g)) {
      for (const [, attributes, constraint] of body.matchAll(/<column\s+([^>]*?)(?:\/>|>([\s\S]*?)<\/column>)/g)) {
        const attrs = Object.fromEntries([...attributes.matchAll(/(\w+)="([^"]*)"/g)].map(m => [m[1], m[2]]));
        const fallback = attrs.defaultValue ? ` DEFAULT '${attrs.defaultValue}'` : attrs.defaultValueBoolean ? ` DEFAULT ${attrs.defaultValueBoolean}` : '';
        await db.query(`ALTER TABLE tenant_test.${table} ADD COLUMN ${attrs.name} ${attrs.type}${fallback}${constraint?.includes('nullable="false"') ? ' NOT NULL' : ''}`);
      }
    }
    const sql = xml.match(/<sql splitStatements="false"><!\[CDATA\[([\s\S]*?)\]\]><\/sql>/)[1].replaceAll('${schema}', 'tenant_test');
    await db.query(sql);
    assert.deepEqual((await db.query('SELECT response_review_mode FROM tenant_test.survey ORDER BY id')).rows.map(r => r.response_review_mode), ['AGGREGATE_ONLY', 'AGGREGATE_ONLY', 'AGGREGATE_ONLY']);
    for (const id of [1, 2]) await assert.rejects(db.query(`UPDATE tenant_test.survey SET response_review_mode='ANONYMOUS_SUBMISSIONS' WHERE id=$1`, [id]), /immutable/);
    await db.query(`UPDATE tenant_test.survey SET response_review_mode='ANONYMOUS_SUBMISSIONS' WHERE id=3;
      UPDATE tenant_test.survey SET status='PUBLISHED' WHERE id=3;`);
    await assert.rejects(db.query(`UPDATE tenant_test.survey SET response_review_mode='AGGREGATE_ONLY' WHERE id=3`), /immutable/);
    await assert.rejects(db.query(`UPDATE tenant_test.survey SET status='DRAFT' WHERE id=3`), /return to draft/);
    await db.query(`UPDATE tenant_test.survey SET status='CLOSED' WHERE id=3`);
    await assert.rejects(db.query(`UPDATE tenant_test.survey SET status='PUBLISHED' WHERE id=3`), /cannot reopen/);
    await assert.rejects(db.query(`UPDATE tenant_test.survey SET response_review_mode='UNKNOWN' WHERE id=3`));
    await db.query(`UPDATE tenant_test.survey_question SET comment_enabled=true,description='Guidance' WHERE id=1`);
    await assert.rejects(db.query(`UPDATE tenant_test.survey_question SET comment_enabled=true WHERE id=2`), /ck_survey_question_comment_type/);
    await assert.rejects(db.query(`UPDATE tenant_test.survey_question SET description=repeat('x',2001) WHERE id=1`), /ck_survey_question_guidance/);
    await db.query(`UPDATE tenant_test.survey_answer SET comment=repeat('x',4000) WHERE id=1`);
    await assert.rejects(db.query(`UPDATE tenant_test.survey_answer SET comment=repeat('x',4001) WHERE id=1`), /ck_survey_answer_comment_length/);
    const columns = (await db.query(`SELECT column_name FROM information_schema.columns WHERE table_schema='tenant_test' AND table_name='survey_answer'`)).rows.map(r => r.column_name);
    assert.deepEqual(columns.sort(), ['comment', 'id']);
    console.log('PASS migration defaults preserve existing surveys; published mode immutable; closure permanent; guidance/comment constraints; no identifying answer columns');
  } finally {
    await db.end().catch(() => {});
    if (started && fs.existsSync(path.join(data, 'postmaster.pid'))) pg('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
    console.log(`Temporary test files: ${dir}`);
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
