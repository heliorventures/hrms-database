import contextlib
import copy
import io
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parents[1]))
import acl_operator as operator
import acl_corrections
from policy import digest
from test_acl_corrections import fixture


class OperatorTests(unittest.TestCase):
    def test_wrong_reviewed_hash_refuses_before_database_admission(self):
        target,state,operations=fixture();plan=acl_corrections.prepare(target,state,operations)
        with patch.object(operator,'load_plan',return_value=plan),patch.object(operator.os,'geteuid',return_value=0,create=True),patch.object(operator,'MaintenanceSession') as session:
            with self.assertRaisesRegex(ValueError,'REVIEWED_PLAN_HASH_REQUIRED'):
                operator.execute(SimpleNamespace(command='prepare',plan='x',expected_sha256='0'*64,output='new',maintenance_window=True))
            session.assert_not_called()

    def test_success_receipt_is_written_only_after_barrier_exit(self):
        target,state,operations=fixture();plan=acl_corrections.prepare(target,state,operations);events=[]
        @contextlib.contextmanager
        def barrier(*args):
            events.append('enter');yield SimpleNamespace(query=lambda sql:None);events.append('closed')
        @contextlib.contextmanager
        def signal_scope():
            events.append('signals_start');yield;events.append('signals_end')
        args=SimpleNamespace(command='apply',plan='x',expected_sha256=digest(plan),output='new',maintenance_window=True)
        with contextlib.redirect_stdout(io.StringIO()),patch.object(operator,'load_plan',return_value=plan),patch.object(operator.os,'geteuid',return_value=0,create=True),patch.object(operator,'MaintenanceSession',barrier),patch.object(operator,'defer_termination',signal_scope),patch.object(operator,'operator_lock',contextlib.nullcontext),patch.object(operator,'ensure_new_output'),patch.object(operator,'stopped_applications'),patch.object(operator,'capture',side_effect=[state,acl_corrections.expected_after(plan)]),patch.object(operator,'protected_write',side_effect=lambda *_:events.append('receipt')):
            operator.execute(args)
        self.assertEqual(events,['signals_start','enter','closed','signals_end','receipt'])

    def test_failed_barrier_or_postcondition_cannot_publish_success(self):
        target,state,operations=fixture();plan=acl_corrections.prepare(target,state,operations)
        @contextlib.contextmanager
        def bad_barrier(*args):
            yield SimpleNamespace(query=lambda sql:None)
            raise ValueError('MAINTENANCE_BARRIER_CONFIRMATION_FAILED')
        args=SimpleNamespace(command='apply',plan='x',expected_sha256=digest(plan),output='new',maintenance_window=True)
        with patch.object(operator,'load_plan',return_value=plan),patch.object(operator.os,'geteuid',return_value=0,create=True),patch.object(operator,'MaintenanceSession',bad_barrier),patch.object(operator,'operator_lock',contextlib.nullcontext),patch.object(operator,'ensure_new_output'),patch.object(operator,'stopped_applications'),patch.object(operator,'capture',side_effect=[state,acl_corrections.expected_after(plan)]),patch.object(operator,'protected_write') as write:
            with self.assertRaisesRegex(ValueError,'MAINTENANCE_BARRIER_CONFIRMATION_FAILED'):operator.execute(args)
            write.assert_not_called()

    def test_uncertain_retry_requires_verify_or_new_reviewed_plan(self):
        target,state,operations=fixture();plan=acl_corrections.prepare(target,state,operations)
        @contextlib.contextmanager
        def barrier(*args):yield SimpleNamespace(query=lambda sql:self.fail('must not reapply'))
        args=SimpleNamespace(command='apply',plan='x',expected_sha256=digest(plan),output='new',maintenance_window=True)
        with patch.object(operator,'load_plan',return_value=plan),patch.object(operator.os,'geteuid',return_value=0,create=True),patch.object(operator,'MaintenanceSession',barrier),patch.object(operator,'operator_lock',contextlib.nullcontext),patch.object(operator,'ensure_new_output'),patch.object(operator,'capture',return_value=acl_corrections.expected_after(plan)),patch.object(operator,'protected_write') as write:
            with self.assertRaisesRegex(ValueError,'ACL_CORRECTION_BASELINE_CHANGED'):operator.execute(args)
            write.assert_not_called()


if __name__=='__main__':unittest.main()
