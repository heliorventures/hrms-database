const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../..');

test('one registered source builder produces all four explicit canonical bundles', () => {
  const {buildRoleDefaults} = require('../../../scripts/reusable/rbac/canonical-role-defaults.cjs');
  const rows = buildRoleDefaults();
  const counts = Object.fromEntries(['EMPLOYEE','MANAGER','HR','ADMIN'].map(role => [role,rows.filter(row => row.role===role).length]));
  assert.deepEqual(counts,{EMPLOYEE:22,MANAGER:29,HR:56,ADMIN:57});
  assert.equal(new Set(rows.map(row => `${row.role}:${row.resource}:${row.action}`)).size,rows.length);
  assert(!rows.some(row => row.resource==='loan'));
  assert(rows.some(row => row.role==='MANAGER' && row.resource==='performance' && row.action==='evaluate' && row.scope==='TEAM'));
  assert(rows.some(row => row.role==='ADMIN' && row.resource==='survey' && row.action==='respond' && row.scope==='SELF'));
});

test('reusable provisioning never silently resets customized grants or grants the entire catalog', () => {
  for (const file of ['bootstrap-tenant-admins.ps1', 'seed-demo-data.ps1']) {
    const source = fs.readFileSync(path.join(root, 'scripts/reusable/provisioning', file), 'utf8');
    assert.doesNotMatch(source, /AllPermissions\s*=\s*\$true|DELETE FROM[^\n]*(?:role_permission|permission_scope)/i, file);
    assert.match(source, /canonical-role-defaults\.cjs|company-bootstrap\.cjs/, file);
  }
});

test('obsolete colocated setup and provision stop before any database runner', () => {
  for (const file of ['setup-tenant.ps1', 'provision-tenant.ps1']) {
    const source = fs.readFileSync(path.join(root, 'scripts/reusable/provisioning', file), 'utf8');
    assert.match(source, /LEGACY_COLOCATED_PROVISIONING_DISABLED/, file);
    assert.doesNotMatch(source, /Import-DotEnvFile|run-sql|run-liquibase|POSTGRES_PASSWORD/, file);
  }
});
