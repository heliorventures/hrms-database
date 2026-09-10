const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const root = path.resolve(__dirname, '..');
const migrationPath = 'changelog/migrations/0085_admin_hr_permission_defaults/admin_hr_permission_defaults.xml';

test('every UI permission has an explicit Admin/HR default decision in a registered migration', () => {
  const { checkCoverage } = require('../scripts/check-permission-defaults.cjs');
  const source = fs.readFileSync(path.join(root, '../hrms-ui/src/auth/permissions.ts'), 'utf8');
  assert.deepEqual(checkCoverage(source), []);
  assert.deepEqual(checkCoverage(source + "\nnewFeature: 'new_feature:manage'"), ['new_feature:manage']);
});

test('forward migration is transactional, additive and included for existing and new tenants', () => {
  const xml = fs.readFileSync(path.join(root, migrationPath), 'utf8');
  const master = fs.readFileSync(path.join(root, 'changelog/tenant.changelog-master.xml'), 'utf8');
  assert.ok(master.includes(migrationPath.replace('changelog/', '')));
  assert.match(xml, /runInTransaction="true"/);
  assert.match(xml, /splitStatements="false"/);
  assert.doesNotMatch(xml, /(?:UPDATE|DELETE FROM)\s+"\$\{schema\}"\.(?:permission_scope|role_permission)/i);
  assert.match(xml, /forward corrective migration/);
});
