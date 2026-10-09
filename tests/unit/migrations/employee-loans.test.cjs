const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const root = path.resolve(__dirname, '../../..');
const read = (file) => fs.existsSync(path.join(root, file)) ? fs.readFileSync(path.join(root, file), 'utf8') : '';
const schema = () => read('changelog/migrations/0103_employee_loans/employee_loans.xml');

test('loan relationships bind tenant and employee without financial cascade deletion', () => {
  assert.match(schema(), /baseColumnNames="tenant_id,employee_id"/);
  assert.match(schema(), /referencedColumnNames="tenant_id,id"/);
  assert.doesNotMatch(schema(), /onDelete="CASCADE"/);
});
test('ledger is immutable and posting groups reconcile principal and interest allocations', () => {
  assert.match(schema(), /loan_reject_financial_mutation/);
  assert.match(schema(), /loan_check_posting_balance/);
  assert.match(schema(), /DEFERRABLE INITIALLY DEFERRED/);
  assert.match(schema(), /uq_loan_posting_source/);
});
test('policy activation, allocation and idempotency have database constraints', () => {
  assert.match(schema(), /ck_loan_policy_activation/);
  assert.match(schema(), /uq_loan_command_receipt/);
  assert.match(schema(), /ck_loan_allocation_nonnegative/);
  assert.match(schema(), /ck_loan_account_principal/);
});
test('loan catalog does not activate tenants or grant financial capabilities', () => {
  const catalog = read('changelog/migrations/0104_loan_module_catalog/loan_module_catalog.xml');
  assert.match(catalog, /LOANS/);
  assert.doesNotMatch(catalog, /INSERT INTO[^;]*(tenant_subscription|role_permission|permission_scope)/i);
  assert.match(read('changelog/tenant.changelog-master.xml'), /0103_employee_loans/);
  assert.match(read('changelog/db.changelog-master.xml'), /0104_loan_module_catalog/);
});
