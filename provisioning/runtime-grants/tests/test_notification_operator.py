"""No production I/O; validate exact plans, hash binding and single-attempt writes."""
import json
from pathlib import Path
import sys
import unittest
import contextlib
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[1]))
import notification_operator as operator
from policy import digest


class NotificationOperatorTests(unittest.TestCase):
    def plan(self):
        target = dict(systemId='123', database='company_fixture', schema='tenant_fixture')
        before = dict(database=target['database'], systemId=target['systemId'], open=True,
                      restrictedRoles=True, required=[True, False, False, False, False, False],
                      invariantsSha256='a'*64)
        return operator.make_plan(target, before)

    def test_wrong_hash_and_modified_contract_refuse_before_write(self):
        plan = self.plan()
        with self.assertRaises(ValueError):
            operator.validate_plan(plan, '0'*64)
        plan['requirementsSha256'] = '0'*64
        with self.assertRaises(ValueError):
            operator.validate_plan(plan, digest(plan))

    def test_guarded_write_is_once_and_postcondition_is_exact(self):
        plan = self.plan()
        sql = operator.validate_plan(plan, digest(plan))
        after = dict(plan['before'], required=[True]*6)
        calls = []
        def query(database, text):
            calls.append((database, text))
            return '' if text == sql else json.dumps(after)
        result = operator.operate('apply', plan, query)
        self.assertEqual(result, after)
        self.assertEqual(sum(text == sql for _, text in calls), 1)
        calls.clear()
        operator.operate('verify', plan, query)
        self.assertEqual(sum(text == sql for _, text in calls), 0)

    def test_ambiguous_write_failure_never_retries(self):
        plan = self.plan()
        calls = []
        def query(*args):
            calls.append(args)
            raise RuntimeError('transport unavailable')
        with self.assertRaises(RuntimeError):
            operator.operate('apply', plan, query)
        self.assertEqual(len(calls), 1)

    def test_changed_postcondition_cannot_be_reported_as_verified(self):
        plan = self.plan()
        after = dict(plan['before'], required=[True]*6, invariantsSha256='b'*64)
        with self.assertRaisesRegex(ValueError, 'NOTIFICATION_POSTCONDITION_FAILED'):
            operator.operate('verify', plan, lambda *_: json.dumps(after))

    def test_apply_requires_window_before_any_file_or_database_io(self):
        args = SimpleNamespace(command='apply', maintenance_window=False)
        with patch.object(operator.os, 'geteuid', return_value=0, create=True), \
                patch.object(operator, 'protected_read') as read, \
                patch.object(operator, 'database_sql') as query:
            with self.assertRaisesRegex(ValueError, 'EXPLICIT_MAINTENANCE_WINDOW_REQUIRED'):
                operator.execute(args)
            read.assert_not_called()
            query.assert_not_called()

    def test_wrong_reviewed_hash_refuses_before_database_io(self):
        args = SimpleNamespace(command='apply', maintenance_window=True, output='/new',
                               plan='/plan', expected_sha256='0'*64, system_id=None,
                               database=None, schema=None)
        with patch.object(operator.os, 'geteuid', return_value=0, create=True), \
                patch.object(operator, 'ensure_new_output'), \
                patch.object(operator, 'protected_read', return_value=self.plan()), \
                patch.object(operator, 'database_sql') as query:
            with self.assertRaisesRegex(ValueError, 'NOTIFICATION_PLAN_HASH_CHANGED'):
                operator.execute(args)
            query.assert_not_called()

    def test_ambiguous_apply_records_intent_and_unconfirmed_result_without_retry(self):
        plan = self.plan()
        args = SimpleNamespace(command='apply', maintenance_window=True, output='/new',
                               plan='/plan', expected_sha256=digest(plan), system_id=None,
                               database=None, schema=None)
        with patch.object(operator.os, 'geteuid', return_value=0, create=True), \
                patch.object(operator, 'ensure_new_output'), \
                patch.object(operator, 'protected_read', return_value=plan), \
                patch.object(operator, 'operator_lock', contextlib.nullcontext), \
                patch.object(operator, 'protected_write') as write, \
                patch.object(operator, 'database_sql', side_effect=RuntimeError('uncertain')) as query:
            with self.assertRaises(RuntimeError):
                operator.execute(args)
            self.assertEqual(query.call_count, 1)
            self.assertEqual([call.args[1]['status'] for call in write.call_args_list],
                             ['operation_requested', 'unconfirmed_reconcile_before_retry'])


if __name__ == '__main__':
    unittest.main()
