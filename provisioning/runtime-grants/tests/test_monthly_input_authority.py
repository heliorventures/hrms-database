"""Monthly edits retain narrow locking and draft conflict-update capabilities."""
import importlib.util
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).parents[1]))
import policy
import payroll_authority as authority

TARGET=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')

class MonthlyAuthorityTests(unittest.TestCase):
    def module(self):
        self.assertIsNotNone(importlib.util.find_spec('monthly_input_authority'),'fixed monthly-input lock compiler is required')
        import monthly_input_authority
        return monthly_input_authority

    def test_lock_has_one_bound_tenant_argument_and_only_fixed_period_relation(self):
        m=self.module();sql=m.install_sql(TARGET)
        self.assertIn('hrms_lock_payroll_period_input_v1',sql)
        self.assertIn('IN ROW EXCLUSIVE MODE',sql)
        self.assertIn('"tenant_fixture"."payroll_period_input"',sql)
        self.assertIn('p_tenant IS DISTINCT FROM',sql)
        self.assertIn("SET lock_timeout = '15s'",sql)
        self.assertIn('REVOKE ALL ON FUNCTION',sql)
        self.assertNotIn('GRANT UPDATE',sql)
        self.assertNotIn('CREATE OR REPLACE',sql)

    def test_existing_two_helpers_are_preserved_and_optional_helper_is_exactly_verified(self):
        m=self.module();before=authority._bodies(TARGET)
        sql=m.install_sql(TARGET)
        self.assertEqual(authority._bodies(TARGET),before)
        self.assertIn('MONTHLY_INPUT_FUNCTION_EXISTS_REVIEW_REQUIRED',sql)
        verify=authority.verify_sql(TARGET,include_period_lock=True)
        self.assertIn(m.body(TARGET).replace("'","''"),verify)
        self.assertIn('PAYROLL_AUTHORITY_POSTCONDITION_FAILED',verify)

    def test_invalid_target_is_rejected_before_compilation(self):
        m=self.module()
        for key,value in [('tenantId','00000000-0000-0000-0000-000000000000'),('schema','public'),('owner','appuser')]:
            with self.assertRaises(ValueError):m.install_sql(dict(TARGET,**{key:value}))

    def test_draft_upsert_read_contract_contains_only_the_required_columns(self):
        self.assertEqual(policy.REQUIRED_COMPANY_COLUMNS['hrms_company_payroll'].get('payroll_draft_calculation'),
                         {'select':['tenant_id','cycle_id','snapshot','revision','fingerprint','calculated_by','calculated_by_principal_id']})

if __name__=='__main__':unittest.main()
