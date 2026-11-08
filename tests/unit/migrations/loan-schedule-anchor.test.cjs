const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('contractual first due date is additive and preserves unknown historical anchors', () => {
  const root = path.resolve(__dirname, '../../..');
  const source = fs.readFileSync(path.join(root, 'changelog/migrations/0109_loan_schedule_anchor/loan_schedule_anchor.xml'), 'utf8');
  assert.match(source, /ADD COLUMN first_due_date DATE/);
  assert.doesNotMatch(source, /DISABLE TRIGGER/);
  assert.doesNotMatch(source, /UPDATE\s+"\$\{schema\}"/);
  assert.doesNotMatch(source, /SET first_due_date\s*=\s*(?:effective_from|CURRENT_DATE)/i);
  assert.doesNotMatch(source, /(?:DELETE FROM|UPDATE)\s+(?:"\$\{schema\}"\.)?loan_schedule_item\b/i);
  const master = fs.readFileSync(path.join(root, 'changelog/tenant.changelog-master.xml'), 'utf8');
  assert.match(master, /0109_loan_schedule_anchor/);
});
