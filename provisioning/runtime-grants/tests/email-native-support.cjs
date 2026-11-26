// Shared owned-fixture utilities. Static source contracts only; no live DSN.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const directory=path.resolve(__dirname,'..');
const services=path.resolve(__dirname,'../../../../hrms-svc');
function python(code) {
  const result = spawnSync(process.env.RUNTIME_GRANTS_PYTHON, ['-c', `import sys,json;sys.path.insert(0,sys.argv[1]);import email_columns as e;${code}`, directory],
    {encoding:'utf8',windowsHide:true,timeout:60000});
  assert.equal(result.status, 0, result.stderr); return result.stdout;
}
function rustConstant(file, name) {
  const source = fs.readFileSync(path.join(services, file), 'utf8');
  const match = source.match(new RegExp(`\\b${name}[^=]*=\\s*r#"([\\s\\S]*?)"#;`));
  assert(match, `missing executable SQL contract ${name}`); return match[1];
}
function tables(schema, profiles) {
  const fields = {};
  for (const profile of profiles) for (const [table, rights] of Object.entries(profile)) {
    const columns = Array.isArray(rights) ? rights : rights.select;
    fields[table] ??= new Set(); for (const column of columns) fields[table].add(column);
  }
  const integers = new Set(['version','installed_version','expected_grant_version','grant_version','membership_version','graph_version','assignment_version']);
  const smallIntegers = new Set(['sequence_order','sla_hours','response_revision']);
  const booleans = new Set(['is_active','is_deleted','can_skip','is_excluded']);
  const type = column => column === 'id' || column.endsWith('_id') || column === 'requested_by' ? 'uuid' : integers.has(column) ? 'bigint' : smallIntegers.has(column) ? 'integer' : column === 'weightage' ? 'numeric' :
    booleans.has(column) ? 'boolean' : column.endsWith('_at') || ['effective_from','effective_to'].includes(column) ? 'timestamptz' : column === 'capabilities' ? 'jsonb' : 'text';
  return `CREATE SCHEMA "${schema}";` + Object.entries(fields).map(([table, columns]) =>
    `CREATE TABLE "${schema}"."${table}"(${[...columns].map(column => `"${column}" ${type(column)}`).join(',')});`).join('');
}

module.exports={python,rustConstant,tables,services};
