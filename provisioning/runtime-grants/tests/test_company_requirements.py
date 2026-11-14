"""Built-in company policies must cover the real page projections, explicitly."""
import copy
import re
from pathlib import Path
import sys
import unittest

DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(DIRECTORY))
from test_policy import contract
import policy


class CompanyRequirementsTests(unittest.TestCase):
    def test_private_ownership_acknowledgement_requires_exact_receipt_columns(self):
        receipt = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee'].get(
            'private_delivery_receipt', {})
        self.assertEqual(set(receipt.get('select', [])), {
            'tenant_id', 'intent_id', 'destination_id', 'intent_hash',
            'destination_version', 'source_generation', 'broker_owned_at',
            'broker_owner_id', 'broker_receipt_sha256'})
        self.assertEqual(set(receipt.get('update', [])), {
            'broker_owned_at', 'broker_owner_id', 'broker_receipt_sha256', 'updated_at'})
        self.assertNotIn('insert', receipt)
        self.assertNotIn('delete', receipt)

    def test_incomplete_builtin_projection_is_rejected(self):
        candidate = contract()
        candidate['roles']['hrms_company_performance'] = {
            'tables': {'review_cycle': {'select': ['id']}},
            'sequences': [], 'functions': []}
        with self.assertRaisesRegex(ValueError, 'COMPANY_RUNTIME_COLUMNS_MISSING'):
            policy.validate_policy(candidate)

    def test_explicit_requirements_are_required_one_column_at_a_time(self):
        for role, tables in policy.REQUIRED_COMPANY_COLUMNS.items():
            candidate = contract()
            candidate['roles'][role] = {
                'tables': {**copy.deepcopy(policy.BUSINESS_COMPANY_COLUMNS.get(role, {})),
                           **copy.deepcopy(tables)}, 'sequences': [], 'functions': []}
            policy.validate_policy(candidate)
            for table, rights in tables.items():
                for operation, columns in rights.items():
                    if operation == 'delete':
                        incomplete = copy.deepcopy(candidate)
                        del incomplete['roles'][role]['tables'][table]['delete']
                        with self.assertRaises(ValueError):
                            policy.validate_policy(incomplete)
                        continue
                    for column in columns:
                        incomplete = copy.deepcopy(candidate)
                        values = incomplete['roles'][role]['tables'][table][operation]
                        values.remove(column)
                        if not values:
                            del incomplete['roles'][role]['tables'][table][operation]
                        if not incomplete['roles'][role]['tables'][table]:
                            del incomplete['roles'][role]['tables'][table]
                        with self.assertRaises(ValueError, msg=(role, table, operation, column)):
                            policy.validate_policy(incomplete)

    def test_requirements_do_not_implicitly_add_permissions(self):
        candidate = contract()
        before = copy.deepcopy(candidate)
        policy.validate_policy(candidate)
        self.assertEqual(candidate, before)

    def test_access_replacement_requires_explicit_relationship_writes(self):
        employee = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee']
        for table, columns in {
            'role_permission': {'role_id', 'permission_id', 'created_at'},
            'permission_scope': {'id', 'tenant_id', 'role_id', 'resource', 'action', 'scope_type', 'created_at'},
            'user_role': {'user_id', 'role_id', 'assigned_at'},
        }.items():
            self.assertEqual(set(employee[table].get('insert', [])), columns, table)
            self.assertIs(employee[table].get('delete'), True, table)

    def test_rbac_requirements_cover_current_full_entity_projections(self):
        # This is a drift alarm, never an authority-generating source scanner.
        source = (Path(__file__).parents[4] / 'hrms-svc/crates/kabipay-db-entities/src/tenant/d0005_auth_rbac.rs')
        raw = source.read_text(encoding='utf-8')
        required = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee']
        for table in ('permission', 'permission_scope', 'role_permission'):
            body = re.search(r'pub mod ' + table + r'\s*\{[\s\S]*?pub struct Model\s*\{([\s\S]*?)\n    \}', raw)
            self.assertIsNotNone(body, table)
            fields = set(re.findall(r'^\s*pub (?:r#)?([a-z_][a-z0-9_]*):', body[1], re.M))
            self.assertTrue(fields)
            self.assertLessEqual(fields, set(required[table]['select']), table)


if __name__ == '__main__':
    unittest.main()
