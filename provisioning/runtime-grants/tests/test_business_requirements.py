"""Explicit audited service operations, including PostgreSQL lock authority."""
import copy
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import policy
from test_policy import contract, payroll_function_contracts, company_tables


class BusinessRequirementsTests(unittest.TestCase):
    def test_full_model_reads_and_returning_are_explicit_drift_alarms(self):
        source = Path(__file__).parents[4] / 'hrms-svc/crates/kabipay-db-entities/src/tenant'
        relations = {
            'd0017_onboarding_offboarding.rs': ('onboarding_checklist', 'separation', 'clearance_checklist'),
            'd0050_employee_self_service.rs': ('employee_profile_change_request',),
            'd0027_communication_audit.rs': ('notification',),
            'd0025_workflow.rs': ('workflow', 'workflow_step', 'workflow_instance', 'workflow_action'),
            'd0103_employee_loans.rs': ('loan_request',),
            'd0077_unpaid_leave_payroll.rs': ('payslip_unpaid_leave',),
        }
        for filename, tables in relations.items():
            raw = (source / filename).read_text(encoding='utf-8')
            for table in tables:
                body = re.search(r'pub mod ' + table + r'\s*\{[\s\S]*?pub struct Model\s*\{([\s\S]*?)\n    \}', raw)
                self.assertIsNotNone(body, table)
                fields = set(re.findall(r'^\s*pub (?:r#)?([a-z_][a-z0-9_]*):', body[1], re.M))
                self.assertTrue(fields)
                for role, requirements in policy.BUSINESS_COMPANY_COLUMNS.items():
                    if table in requirements:
                        operation = 'select' if 'select' in requirements[table] else 'insert'
                        self.assertEqual(fields, set(requirements[table][operation]), (role, table, operation))

    def test_payroll_credential_reads_are_rejected_even_when_explicit(self):
        for credential in ('password_hash', 'mfa_secret'):
            candidate = contract()
            tables = copy.deepcopy(policy.BUSINESS_COMPANY_COLUMNS['hrms_company_payroll'])
            tables['user']['select'].append(credential)
            candidate['roles']['hrms_company_payroll'] = {
                'tables': tables, 'sequences': [], 'functions': []}
            with self.assertRaisesRegex(ValueError, 'PAYROLL_CREDENTIAL_READ_FORBIDDEN'):
                policy.validate_policy(candidate)

    def test_reviewed_business_relations_are_permanent_requirements(self):
        requirements = getattr(policy, 'BUSINESS_COMPANY_COLUMNS', {})
        expected = {
            'hrms_company_employee': {'onboarding_checklist', 'employee_profile_change_request', 'separation', 'clearance_checklist', 'notification', 'employee_exit_operation'},
            'hrms_company_leave': {'workflow_action'},
            'hrms_company_payroll': {'user', 'file_storage', 'loan_request', 'workflow', 'workflow_step', 'workflow_instance', 'workflow_action', 'payslip_unpaid_leave'},
        }
        for role, tables in expected.items():
            self.assertEqual(set(requirements.get(role, {})), tables, role)

    def test_missing_business_columns_are_rejected_and_never_inferred(self):
        for role, tables in getattr(policy, 'BUSINESS_COMPANY_COLUMNS', {}).items():
            candidate = contract()
            existing = company_tables(role)
            candidate['roles'][role] = {'tables': existing, 'sequences': [], 'functions': payroll_function_contracts() if role=='hrms_company_payroll' else []}
            before = copy.deepcopy(candidate)
            policy.validate_policy(candidate)
            self.assertEqual(candidate, before)
            for table, rights in tables.items():
                for operation, columns in rights.items():
                    for column in columns:
                        incomplete = copy.deepcopy(candidate)
                        selected = incomplete['roles'][role]['tables'][table][operation]
                        selected.remove(column)
                        if not selected:
                            del incomplete['roles'][role]['tables'][table][operation]
                        if not incomplete['roles'][role]['tables'][table]:
                            del incomplete['roles'][role]['tables'][table]
                        with self.assertRaises(ValueError, msg=(role, table, operation, column)):
                            policy.validate_policy(incomplete)


if __name__ == '__main__':
    unittest.main()
