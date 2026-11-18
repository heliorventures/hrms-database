"""Conditional payslip reads and idempotent automated-notification writes."""
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import policy


class PresentationRequirementsTests(unittest.TestCase):
    def test_payroll_has_the_exact_employee_display_projection_without_private_profile_writes(self):
        rights = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll'].get('employee', {})
        self.assertEqual(rights, {'select': [
            'id', 'tenant_id', 'first_name', 'last_name', 'employee_code',
            'department_id', 'designation_id', 'date_of_joining', 'gender',
            'marital_status', 'uan_number', 'esic_number', 'is_deleted', 'status',
            'payroll_excluded', 'imported_last_working_date', 'imported_exit_date']})

    def test_tenant_scoped_display_joins_and_imported_annual_values_have_explicit_reads(self):
        required = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll']
        self.assertEqual(required.get('department'), {'select': ['id', 'tenant_id', 'name', 'is_deleted']})
        self.assertEqual(required.get('designation'), {'select': ['id', 'tenant_id', 'title', 'is_deleted']})
        self.assertEqual(required.get('employee_salary_structure'), {'select': ['id', 'tenant_id', 'annual_gross', 'annual_employer_pf']})

    def test_immutable_statement_read_covers_real_model_but_never_write_authority(self):
        required = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll'].get('payslip_statement', {})
        source = Path(__file__).parents[4] / 'hrms-svc/crates/kabipay-db-entities/src/tenant/d0090_payroll_period_configuration.rs'
        body = re.search(r'pub mod payslip_statement\s*\{[\s\S]*?pub struct Model\s*\{([\s\S]*?)\n    \}', source.read_text())
        self.assertIsNotNone(body)
        columns = set(re.findall(r'^\s*pub ([a-z_][a-z0-9_]*):', body[1], re.M))
        self.assertEqual(set(required.get('select', [])), columns)
        self.assertEqual(set(required), {'select'})

    def test_notification_occurrence_reads_only_returned_identifier_and_conflict_arbiter(self):
        self.assertEqual(policy.REQUIRED_COMPANY_COLUMNS.get('hrms_company_notification', {}).get('automated_notification_occurrence'), {
            'insert': ['id', 'tenant_id', 'event_type', 'employee_id', 'event_date', 'recipient_user_id', 'notification_id', 'created_at'],
            'select': ['id', 'tenant_id', 'event_type', 'employee_id', 'event_date', 'recipient_user_id']})


if __name__ == '__main__':
    unittest.main()
