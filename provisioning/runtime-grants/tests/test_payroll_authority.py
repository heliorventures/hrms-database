"""The bounded Payroll interface is explicit and cannot accept SQL identifiers."""
import importlib.util
from pathlib import Path
import sys
import unittest
import copy

sys.path.insert(0,str(Path(__file__).parents[1]))
try:
    import payroll_authority as authority
except ModuleNotFoundError:
    authority=None

class PayrollAuthorityTests(unittest.TestCase):


    def test_preserved_trigger_requires_explicit_exact_reviewed_definition_pin(self):
        target=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')
        preserved=[dict(name='organization_capture_admin_version',definitionSha256='a'*64)]
        sql=authority.install_sql(target,preserved_routines=preserved)
        self.assertIn('a'*64,sql)
        self.assertIn('PAYROLL_AUTHORITY_PRESERVED_ROUTINE_CHANGED',sql)
        self.assertIn("'trigger'::regtype",sql)
        self.assertNotIn('CREATE OR REPLACE FUNCTION',sql)
        for routine in [dict(name='unreviewed_authority',definitionSha256='a'*64),dict(name='organization_capture_admin_version',definitionSha256='invalid')]:
            with self.assertRaises(ValueError):authority.install_sql(target,preserved_routines=[routine])

    def test_capacity_is_checked_before_materializing_any_table_array(self):
        target=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')
        sql=authority.install_sql(target)
        self.assertIn('PAYROLL_SNAPSHOT_CAPACITY_EXCEEDED',sql)
        self.assertIn('33554432',sql)
        body=authority._bodies(target)[1]
        self.assertLess(body.rindex('v_bytes :='),body.index('jsonb_agg'))
        self.assertIn('totalBytes',authority.capacity_sql(target))

    def test_existing_owner_relations_cannot_inherit_new_authority(self):
        target=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')
        self.assertTrue('PAYROLL_AUTHORITY_OWNER_RELATIONS_CHANGED' in authority.prerequisite_sql(target),
                        'Owner-owned views must be refused before internal grants')

    def test_future_payroll_profile_refuses_missing_authority_without_inference(self):
        import policy
        from test_policy import contract, company_tables
        target=contract()
        tables=company_tables('hrms_company_payroll')
        target['roles']['hrms_company_payroll']={'tables':tables,'sequences':[],'functions':[]}
        before=copy.deepcopy(target)
        with self.assertRaisesRegex(ValueError,'PAYROLL_INPUT_AUTHORITY_MISSING'):policy.validate_policy(target)
        self.assertEqual(target,before)

    def test_authority_uses_exact_interface_and_keeps_runtime_table_writes_absent(self):
        self.assertIsNotNone(authority,'restricted Payroll authority must be implemented')
        target=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')
        sql=authority.install_sql(target)
        self.assertIn('SECURITY DEFINER',sql)
        self.assertIn('SET search_path = pg_catalog, pg_temp',sql)
        self.assertIn('SHARE ROW EXCLUSIVE MODE',sql)
        self.assertIn('p_tenant IS DISTINCT FROM',sql)
        self.assertIn('TO "company_fixture_owner"',sql)
        self.assertNotIn('GRANT UPDATE ON TABLE "tenant_fixture"."employee" TO "hrms_company_payroll"',sql)
        self.assertIn('REVOKE ALL ON FUNCTION',sql)
        self.assertIn('hrms_payroll_input_fingerprint_v1',sql)
        self.assertIn('PAYROLL_AUTHORITY_OWNER_CHANGED',authority.verify_sql(target))
        self.assertIn('PAYROLL_AUTHORITY_OWNER_PRIVILEGES_MISSING',authority.verify_sql(target))

    def test_invalid_targets_are_refused_before_sql_compilation(self):
        self.assertIsNotNone(authority,'restricted Payroll authority must be implemented')
        target=dict(systemId='1234',database='company_fixture',schema='tenant_fixture',tenantId='00000000-0000-4000-8000-000000000001',owner='company_fixture_owner',sourceOwner='fixture_owner')
        for key,value in [('schema','public'),('database','postgres'),('owner','hrms_company_payroll'),('tenantId','00000000-0000-0000-0000-000000000000'),('schema','tenant_x; DROP DATABASE company_fixture')]:
            with self.assertRaises(ValueError):authority.install_sql(dict(target,**{key:value}))

if __name__=='__main__':unittest.main()
