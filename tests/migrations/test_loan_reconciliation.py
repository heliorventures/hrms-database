from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FILE = ROOT/'changelog/migrations/0107_loan_reconciliation/loan_reconciliation.xml'
NS = '{http://www.liquibase.org/xml/ns/dbchangelog}'

class ReconciliationSchemaTests(unittest.TestCase):
    def test_late_payment_extension_preserves_balance_and_allocation_guards(self):
        file=ROOT/'changelog/migrations/0108_loan_late_payments/loan_late_payments.xml'
        root=ET.parse(file).getroot()
        sql='\n'.join(node.text or '' for node in root.iter(NS+'sql'))
        for invariant in ['loan_is_reviewed_late_adjustment', 'loan_late_payment_evidence', 'loan posting ledger does not reconcile', 'loan repayment allocation does not reconcile', 'loan reversal does not reconcile with its source', 'loan balance cannot be negative', "preview'->>'correctedPrincipal", 'reviewFingerprint']:
            self.assertIn(invariant,sql)
        self.assertIsNotNone(root.find('.//'+NS+'rollback'))
        self.assertIn('0108_loan_late_payments/loan_late_payments.xml',(ROOT/'changelog/tenant.changelog-master.xml').read_text(encoding='utf-8'))
    def test_results_are_immutable_and_status_cannot_clear_a_failed_result(self):
        root = ET.parse(FILE).getroot()
        tables = {node.attrib['tableName'] for node in root.iter(NS+'createTable')}
        self.assertEqual(tables, {'loan_reconciliation_run', 'loan_reconciliation_status'})
        sql = '\n'.join(node.text or '' for node in root.iter(NS+'sql'))
        self.assertIn('loan_reconciliation_run_immutable', sql)
        self.assertIn('validate_loan_reconciliation_status', sql)
        self.assertIn('jsonb_array_length', sql)
        self.assertIn('fk_loan_reconciliation_result', sql)
        self.assertIn('0107_loan_reconciliation/loan_reconciliation.xml', (ROOT/'changelog/tenant.changelog-master.xml').read_text(encoding='utf-8'))

if __name__ == '__main__': unittest.main()
