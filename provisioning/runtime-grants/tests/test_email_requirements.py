"""Mail privileges belong to service contracts, never to custom end-user roles."""
import importlib
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[3]
sys.path.insert(0, str(Path(__file__).parents[1]))


class EmailRequirements(unittest.TestCase):
    def contract(self):
        self.assertTrue((Path(__file__).parents[1] / 'email_columns.py').is_file(),
                        'email service column contract is missing')
        return importlib.import_module('email_columns')

    def test_producers_have_no_settings_or_delivery_state_access(self):
        contract = self.contract()
        for role in contract.EMAIL_PRODUCERS:
            tables = contract.EMAIL_COMPANY_COLUMNS[role]
            self.assertNotIn('tenant_email_settings', tables)
            self.assertNotIn('update', tables['important_email_intent'])
            self.assertNotIn('state', tables['important_email_intent']['select'])
            self.assertNotIn('delete', tables['important_email_intent'])

    def test_notification_cannot_rewrite_event_identity(self):
        contract = self.contract()
        rights = contract.EMAIL_COMPANY_COLUMNS['hrms_company_notification']['important_email_intent']
        self.assertFalse(set(contract.EMAIL_IDENTITY_COLUMNS) & set(rights['update']))
        self.assertTrue({'lease_token', 'state', 'attempt_count'} <= set(rights['update']))

    def test_current_authority_is_read_only_and_mailboxes_belong_only_to_employee(self):
        contract = self.contract()
        authority = contract.EMAIL_AUTHORITY_COLUMNS
        self.assertNotIn('hrms_company_notification', authority)
        for role in contract.EMAIL_PRODUCERS:
            for table, rights in authority[role].items():
                self.assertEqual(set(rights), {'select'}, (role, table))
                self.assertIsInstance(rights['select'], list)
            self.assertNotIn('name', authority[role]['role']['select'])
            self.assertEqual('email' in authority[role]['user']['select'], role == 'hrms_company_employee')

    def test_current_authority_does_not_replace_existing_access_write_requirements(self):
        contract = self.contract()
        import policy
        for role, tables in contract.EMAIL_AUTHORITY_COLUMNS.items():
            for table, rights in tables.items():
                self.assertTrue(set(rights['select']) <= set(policy.REQUIRED_COMPANY_COLUMNS[role][table]['select']))
        employee = policy.REQUIRED_COMPANY_COLUMNS['hrms_company_employee']
        self.assertTrue(employee['role_permission']['delete'])
        self.assertIn('created_at', employee['role_permission']['select'])
        self.assertIn('created_at', employee['role_permission']['insert'])
        self.assertTrue(employee['user_role']['delete'])

    def test_metadata_profile_requires_an_explicit_non_system_login(self):
        contract = self.contract()
        sql = contract.metadata_grants_sql('hrms_fixture_metadata_employee', 'kabipay-employee')
        self.assertIn('GRANT SELECT', sql)
        self.assertIn('"kabipay_ops"."principal_login_link"', sql)
        self.assertNotIn('GRANT UPDATE', sql)
        self.assertNotIn('WITH GRANT OPTION', sql)
        for role in ('postgres', 'public', 'pg_monitor', 'x;DROP ROLE y'):
            with self.assertRaises(ValueError):
                contract.metadata_grants_sql(role, 'kabipay-employee')
        with self.assertRaises(ValueError):
            contract.metadata_grants_sql('hrms_fixture_metadata_employee', 'unknown-mail-service')

    def test_notification_metadata_is_only_current_company_status_and_label(self):
        contract = self.contract()
        self.assertEqual(contract.EMAIL_METADATA_COLUMNS.get('kabipay-notification'),
                         {'tenant': ['id', 'name', 'status', 'is_deleted']})
        sql = contract.metadata_grants_sql('hrms_fixture_metadata_notification', 'kabipay-notification')
        self.assertNotIn('email', sql)
        self.assertNotIn('GRANT UPDATE', sql)
        self.assertNotIn('employment_ref', sql)

    def test_actual_organization_producers_have_only_explicit_read_profiles(self):
        contract = self.contract()
        for service in ('kabipay-leave', 'kabipay-attendance', 'kabipay-performance'):
            profile = contract.EMAIL_METADATA_COLUMNS.get(service, {})
            self.assertIn('department_id', profile.get('employment_ref', []), service)
            self.assertIn('relationship_type', profile.get('organization_relationship', []), service)
            sql = contract.metadata_grants_sql('hrms_fixture_metadata_producer', service)
            self.assertNotIn('GRANT UPDATE', sql)
            self.assertNotIn('email', ' '.join(column for columns in profile.values() for column in columns))
        for service in ('kabipay-expense', 'kabipay-tax', 'kabipay-payroll'):
            self.assertNotIn(service, contract.EMAIL_METADATA_COLUMNS)

    def test_scheduler_produces_only_attendance_and_performance_without_directory_or_delivery_access(self):
        contract = self.contract()
        role = 'hrms_company_maintenance'
        self.assertIn(role, contract.EMAIL_PRODUCERS)
        self.assertEqual(set(contract.EMAIL_COMPANY_COLUMNS[role]), {'important_email_intent'})
        self.assertEqual(contract.EMAIL_COMPANY_COLUMNS[role]['important_email_intent']['select'], contract.EMAIL_ACK_COLUMNS)
        reads = contract.EMAIL_AUTHORITY_COLUMNS[role]
        self.assertIn('performance_participant', reads)
        self.assertNotIn('email', reads['user']['select'])
        for table in ('tax_proof_line', 'loan_request', 'employee_profile_change_request', 'timesheet_week_batch'):
            self.assertNotIn(table, reads)
        self.assertIn('kabipay-tenant-maintenance', contract.EMAIL_METADATA_COLUMNS)

    def test_grants_reject_reserved_or_injected_schemas(self):
        contract = self.contract()
        for schema in ('public', 'kabipay_ops', 'information_schema', 'pg_catalog', 'x;DROP SCHEMA y'):
            with self.assertRaises(ValueError):
                contract.grants_sql(schema)

    def test_shared_policy_and_upgrade_use_the_same_explicit_contract(self):
        contract = self.contract()
        import policy
        for role, tables in contract.EMAIL_COMPANY_COLUMNS.items():
            for table, rights in tables.items():
                for operation, columns in rights.items():
                    actual = policy.REQUIRED_COMPANY_COLUMNS[role][table][operation]
                    self.assertTrue(actual is True if columns is True else set(columns) <= set(actual))
        master = (ROOT / 'changelog/tenant.changelog-master.xml').read_text()
        self.assertIn('0132_tenant_email/tenant_email.xml', master)


if __name__ == '__main__':
    unittest.main()
