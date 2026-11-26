"""Explicit page caller requirements; models are drift alarms, not grant generators."""
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import policy
import online_columns


class PageRequirementsTests(unittest.TestCase):
    def test_employee_document_and_salary_history_reads_cover_real_projections(self):
        required = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee']
        source_root = Path(__file__).parents[4] / 'hrms-svc/crates/kabipay-db-entities/src/tenant'
        for table, file in [('company_document', 'd0056_company_documents.rs'),
                            ('employment_history', 'd0007_employee_core.rs')]:
            raw = (source_root / file).read_text(encoding='utf-8')
            body = re.search(r'pub mod ' + table + r'\s*\{[\s\S]*?pub struct Model\s*\{([\s\S]*?)\n    \}', raw)
            self.assertIsNotNone(body, table)
            columns = set(re.findall(r'^\s*pub (?:r#)?([a-z_][a-z0-9_]*):', body[1], re.M))
            self.assertEqual(set(required.get(table, {}).get('select', [])), columns, table)
            self.assertEqual(set(required.get(table, {})), {'select'}, table)

    def test_payroll_visibility_covers_read_and_authorized_save_paths(self):
        rights = policy.REQUIRED_COMPANY_COLUMNS.get('hrms_company_payroll', {}).get('salary_component', {})
        self.assertEqual(rights, {'select': ['id', 'tenant_id', 'show_on_payslip'],
                                  'insert': ['show_on_payslip'],
                                  'update': ['show_on_payslip', 'updated_at']})

    def test_performance_detail_includes_raw_dates_and_program_filter(self):
        projection = policy.PAGE_COMPANY_COLUMNS['hrms_company_performance']['review_cycle']
        self.assertEqual(set(projection['select']), {
            'id', 'tenant_id', 'performance_program_id', 'current_stage',
            'goal_setting_due_date', 'self_review_due_date', 'manager_review_due_date',
            'calibration_due_date', 'acknowledgement_due_date'})
        combined = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_performance']['review_cycle']
        self.assertLessEqual(set(projection['select']), set(combined['select']))
        self.assertEqual(set(combined), {'select'})

    def test_no_unused_entity_or_broad_authority_is_added(self):
        required = policy.REQUIRED_COMPANY_COLUMNS
        self.assertNotIn('performance_rating', required['hrms_company_performance'])
        self.assertNotIn('document_field_definition', required['hrms_company_employee'])
        self.assertNotIn('employee_document_field', required['hrms_company_employee'])
        self.assertTrue(all(column is not None for *_, column in online_columns.additions({
            role: {table: rights for table, rights in tables.items() if table in (
                'company_document', 'employment_history', 'salary_component', 'review_cycle')}
            for role, tables in required.items()})))


if __name__ == '__main__':
    unittest.main()
