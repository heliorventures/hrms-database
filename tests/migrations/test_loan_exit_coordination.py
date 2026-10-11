"""Ownership and durable exit authorization schema acceptance."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FILE = ROOT / 'changelog/migrations/0106_loan_exit_coordination/loan_exit_coordination.xml'
NS = '{http://www.liquibase.org/xml/ns/dbchangelog}'

class ExitCoordinationTests(unittest.TestCase):
    def test_durable_records_and_financial_guards(self):
        root = ET.parse(FILE).getroot()
        tables = {node.attrib['tableName'] for node in root.iter(NS + 'createTable')}
        self.assertTrue({'employee_exit_operation', 'employee_finance_outbox',
                         'loan_exit_review', 'loan_exit_approval_guard', 'loan_exit_arrangement',
                         'fnf_financial_review', 'fnf_payout_source'} <= tables)
        sql = '\n'.join(node.text or '' for node in root.iter(NS + 'sql'))
        self.assertIn('RECONCILIATION_PENDING', sql)
        self.assertIn('REGISTERED', sql)
        self.assertIn('uq_active_exit_guard', sql)
        self.assertIn('guard_issued_fnf', sql)
        self.assertIn('uq_fnf_source_allocation', sql)
        self.assertIn('loan_exit_approval_guard', sql)
    def test_registered_without_financial_policy_defaults(self):
        ET.parse(FILE)
        master = (ROOT/'changelog/tenant.changelog-master.xml').read_text(encoding='utf-8')
        self.assertIn('0106_loan_exit_coordination/loan_exit_coordination.xml', master)
        self.assertNotIn('<insert ', FILE.read_text(encoding='utf-8'))

if __name__ == '__main__': unittest.main()
