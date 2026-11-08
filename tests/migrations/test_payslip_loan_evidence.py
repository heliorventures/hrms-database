"""Structural acceptance for the immutable, tenant-bound Payroll evidence migration."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FILE = ROOT / 'changelog/migrations/0105_payslip_loan_evidence/payslip_loan_evidence.xml'
NS = '{http://www.liquibase.org/xml/ns/dbchangelog}'

class EvidenceTests(unittest.TestCase):
    def test_snapshot_is_payroll_owned_and_bound_to_exact_payslip(self):
        root=ET.parse(FILE).getroot()
        table=root.find('.//' + NS + 'createTable')
        self.assertEqual(table.attrib['tableName'], 'payslip_loan_snapshot')
        self.assertIn('snapshot', [column.attrib['name'] for column in table])
        sql='\n'.join(node.text or '' for node in root.iter(NS + 'sql'))
        self.assertIn('tenant_id,payslip_id,employee_id,cycle_id', sql)
        self.assertIn('BEFORE UPDATE OR DELETE', sql)
        self.assertNotIn('REFERENCES "${schema}".loan_', sql)
        self.assertIn('recovery_total >= 0', sql)
    def test_migration_is_registered(self):
        master=(ROOT/'changelog/tenant.changelog-master.xml').read_text(encoding='utf-8')
        self.assertIn('0105_payslip_loan_evidence/payslip_loan_evidence.xml',master)

if __name__ == '__main__': unittest.main()
