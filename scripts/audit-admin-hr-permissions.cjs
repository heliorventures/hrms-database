// Read-only preflight/postflight. Does not apply migrations or change role assignments.
const { readDefaults } = require('./check-permission-defaults.cjs');
async function main() {
  const [schema, username] = process.argv.slice(2);
  if (!/^tenant_[a-z0-9_]{1,50}$/.test(schema || '')) throw new Error('Usage: node scripts/audit-admin-hr-permissions.cjs tenant_<schema> [username]');
  require('../load-env.cjs');
  const { Client } = require('pg');
  const db = new Client({ host: process.env.POSTGRES_HOST || 'localhost', port: Number(process.env.POSTGRES_PORT || 5432),
    database: process.env.POSTGRES_DB, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD,
    ssl: ['require','verify-full'].includes(process.env.POSTGRES_SSLMODE) ? { rejectUnauthorized: true } : undefined });
  await db.connect();
  try {
    await db.query('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const mapping = await db.query('SELECT tenant_id FROM kabipay_ops.tenant_database WHERE schema_name=$1',[schema]);
    if (mapping.rowCount !== 1) throw new Error('Expected exactly one tenant mapping');
    const tenant = mapping.rows[0].tenant_id;
    const rows = await db.query(`WITH defaults AS (SELECT * FROM json_to_recordset($1::json)
      AS d(resource TEXT,action TEXT,admin TEXT,hr TEXT)), expected AS (
      SELECT names.name,d.resource,d.action,CASE names.name WHEN 'ADMIN' THEN d.admin ELSE d.hr END AS expected_scope
      FROM defaults d CROSS JOIN (VALUES ('ADMIN'),('HR')) names(name))
      SELECT e.*,r.id AS role_id,r.is_deleted,p.id AS permission_id,s.scope_type AS current_scope,
       CASE WHEN r.id IS NULL THEN 'MISSING_ROLE' WHEN r.is_deleted THEN 'DELETED_ROLE'
       WHEN p.id IS NULL THEN 'MISSING_PERMISSION' WHEN rp.role_id IS NULL THEN 'MISSING_GRANT'
       WHEN s.id IS NULL THEN 'MISSING_SCOPE' WHEN s.tenant_id<>r.tenant_id THEN 'INVALID_SCOPE_TENANT'
       WHEN s.scope_type<>e.expected_scope THEN 'PRESERVED_SCOPE_DIFFERS' ELSE 'OK' END AS status
      FROM expected e LEFT JOIN "${schema}".role r ON UPPER(TRIM(r.name))=e.name AND r.tenant_id=$2
      LEFT JOIN "${schema}".permission p ON LOWER(TRIM(p.resource))=e.resource AND LOWER(TRIM(p.action))=e.action
      LEFT JOIN "${schema}".role_permission rp ON rp.role_id=r.id AND rp.permission_id=p.id
      LEFT JOIN "${schema}".permission_scope s ON s.role_id=r.id AND LOWER(TRIM(s.resource))=e.resource AND LOWER(TRIM(s.action))=e.action
      WHERE e.expected_scope<>'NONE' ORDER BY e.name,e.resource,e.action`,[JSON.stringify([...readDefaults().values()]),tenant]);
    const counts = new Map();
    for (const row of rows.rows) { const key=`${row.name}:${row.resource}:${row.action}`; counts.set(key,(counts.get(key)||0)+1); }
    for (const row of rows.rows) if (counts.get(`${row.name}:${row.resource}:${row.action}`)>1) row.status='AMBIGUOUS';
    const issues = rows.rows.filter(row => row.status!=='OK');
    console.table(issues.map(({name,resource,action,expected_scope,current_scope,status}) => ({role:name,permission:`${resource}:${action}`,expected_scope,current_scope,status})));
    console.log(`${rows.rowCount-issues.length} matching defaults; ${issues.length} items require migration or review.`);
    if (username) console.table((await db.query(`SELECT u.username,r.name AS role,r.is_deleted AS role_deleted
      FROM "${schema}"."user" u LEFT JOIN "${schema}".user_role ur ON ur.user_id=u.id
      LEFT JOIN "${schema}".role r ON r.id=ur.role_id AND r.tenant_id=u.tenant_id
      WHERE u.tenant_id=$1 AND LOWER(u.username)=LOWER($2)`,[tenant,username])).rows);
    await db.query('COMMIT');
    if (issues.length) process.exitCode=2;
  } finally { await db.end(); }
}
main().catch(e => { console.error(e.message); process.exitCode=1; });
