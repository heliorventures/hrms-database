"""Imported details and payroll eligibility are service contracts, independent of UI roles."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).parents[1]))
import policy


class CalculationRequirementsTests(unittest.TestCase):
    def test_imported_profile_requires_dates_and_bank_extension_columns(self):
        employee=policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee']
        self.assertTrue({'id','tenant_id','is_deleted','confirmation_date','imported_exit_date','imported_last_working_date'} <= set(employee.get('employee',{}).get('select',[])))
        self.assertEqual(employee.get('employee_bank'),{'select':['tenant_id','employee_id','is_primary','account_holder','branch_name']})

    def test_payroll_requires_employment_eligibility_and_exit_reads_without_writes(self):
        employee=policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll']['employee']
        self.assertTrue({'id','tenant_id','is_deleted','status','payroll_excluded','date_of_joining','imported_exit_date','imported_last_working_date','employee_code','first_name','last_name'} <= set(employee['select']))
        self.assertEqual(set(employee),{'select'})

    def test_requirements_never_expand_the_separately_reviewed_presentation_compiler(self):
        from presentation_columns import PRESENTATION_COMPANY_COLUMNS
        columns=PRESENTATION_COMPANY_COLUMNS['hrms_company_payroll']['employee']['select']
        self.assertNotIn('payroll_excluded',columns)
        self.assertNotIn('imported_exit_date',columns)
        self.assertEqual(len(columns),13)

    def test_old_regime_projection_requires_only_proof_summary_reads(self):
        payroll=policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll']
        self.assertEqual(payroll.get('tax_proof_line'),{'select':['section_code','status','actual_amount','submitted_at','tenant_id','employee_id','fiscal_year','tax_config_version_id']})
        self.assertEqual(payroll.get('tax_configuration_version'),{'select':['tenant_id','id','fiscal_year','regime']})


if __name__=='__main__':unittest.main()
