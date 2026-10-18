const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const root = path.resolve(__dirname, '../../..');
const migrationPath = 'changelog/migrations/0085_admin_hr_permission_defaults/admin_hr_permission_defaults.xml';

test('unregistered hyphenated financial capabilities cannot escape default coverage', () => {
  const { checkCoverage } = require('../../../scripts/reusable/rbac/check-permission-defaults.cjs');
  assert.deepEqual(checkCoverage("financialReview: 'new_feature:exit-review'"), ['new_feature:exit-review']);
});

test('loan capabilities require deliberate grants rather than Admin or HR defaults', () => {
  const { readDefaults } = require('../../../scripts/reusable/rbac/check-permission-defaults.cjs');
  const decisions = readDefaults();
  for (const action of ['read', 'submit', 'approve', 'disburse', 'repay', 'manage', 'policy', 'correct', 'exit-review', 'export']) {
    assert.deepEqual(decisions.get(`loan:${action}`), { resource: 'loan', action, admin: 'NONE', hr: 'NONE' });
  }
});

test('loan scope backfill is forward-only, transactional and cannot grant permissions', () => {
  const relative = 'migrations/0110_loan_role_scopes/loan_role_scopes.xml';
  const xml = fs.readFileSync(path.join(root, 'changelog', relative), 'utf8');
  const master = fs.readFileSync(path.join(root, 'changelog/tenant.changelog-master.xml'), 'utf8');
  assert.ok(master.includes(`<include file="${relative}"`));
  assert.match(xml, /runInTransaction="true"/);
  assert.match(xml, /splitStatements="false"/);
  assert.match(xml, /JOIN "\$\{schema\}"\.role_permission rp ON rp\.role_id=r\.id/);
  assert.match(xml, /\('submit','SELF'\)/);
  assert.doesNotMatch(xml, /(?:INSERT INTO|UPDATE|DELETE FROM)\s+"\$\{schema\}"\.(?:role_permission|permission)\b/i);
  assert.doesNotMatch(xml, /(?:UPDATE|DELETE FROM)\s+"\$\{schema\}"\.permission_scope\b/i);
  assert.match(xml, /forward corrective migration/);
});

test('every UI permission has an explicit Admin/HR default decision in a registered migration', () => {
  const { checkCoverage } = require('../../../scripts/reusable/rbac/check-permission-defaults.cjs');
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
