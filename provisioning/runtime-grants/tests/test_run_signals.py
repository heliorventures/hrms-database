"""Cancellation must surround admission/cleanup before any success publication."""
import contextlib
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parent))
from test_run_maintenance import load


class SignalDispatchTests(unittest.TestCase):
    def exercise(self,command,interrupted=False,cleanup_error=False):
        runner=load();events=[]
        target=dict(version=1,systemId='1234',database='company_fixture',schema='tenant_fixture',allowedDatabases=['company_fixture'],roles=['runtime_employee'])
        policy=dict(database='company_fixture',roles={'runtime_employee':{}})
        plan=dict(version=1,policy=policy,baseline={})
        args=SimpleNamespace(command=command,policy=None,plan='plan',output='output',target=None,expected_sha256='reviewed',maintenance_window=True)
        if command=='prepare':args.policy='policy';args.plan=None
        if command=='inventory':args.target='target';args.policy=None;args.plan=None;args.expected_sha256=None
        @contextlib.contextmanager
        def signals():
            events.append('signals_start');yield;events.append('signals_end')
            if interrupted:raise ValueError('MAINTENANCE_INTERRUPTED_AFTER_CLEANUP')
        @contextlib.contextmanager
        def barrier(*args):
            events.append('admitted');yield SimpleNamespace(query=lambda sql:None);events.append('closed')
            if cleanup_error:raise ValueError('MAINTENANCE_BARRIER_CONFIRMATION_FAILED')
        with contextlib.ExitStack()as stack:
            stack.enter_context(patch.object(runner.os,'geteuid',return_value=0,create=True))
            stack.enter_context(patch.object(Path,'read_text',return_value=json.dumps(target)))
            for name,replacement in [('validate_inventory_target',lambda _:target),('validate_policy',lambda _:policy),('validate_inventory_snapshot',lambda *_:None),('protected_read',lambda _:plan),('digest',lambda _:'reviewed'),('operator_lock',contextlib.nullcontext),('MaintenanceSession',barrier),('session_snapshot',lambda *_:{}),('check_snapshot',lambda *_:None),('guarded_sql',lambda *_:'fixture'),('state_equivalent',lambda *_:True),('verify_expected',lambda *_:None),('stopped_applications',lambda:None),('protected_write',lambda *_:events.append('published'))]:
                stack.enter_context(patch.object(runner,name,replacement))
            stack.enter_context(patch.object(runner,'defer_termination',signals,create=True))
            output=stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            expected_error='MAINTENANCE_BARRIER_CONFIRMATION_FAILED'if cleanup_error else'MAINTENANCE_INTERRUPTED_AFTER_CLEANUP'
            if interrupted or cleanup_error:
                with self.assertRaisesRegex(ValueError,expected_error):runner.execute(args)
                self.assertNotIn('published',events)
                self.assertEqual(output.getvalue(),'')
            else:
                runner.execute(args)
                wanted=['signals_start','admitted','closed','signals_end']
                if command in('inventory','prepare'):wanted.append('published')
                self.assertEqual(events,wanted)
                self.assertTrue(output.getvalue())

    def test_all_held_paths_defer_signals_until_after_cleanup(self):
        for command in('inventory','prepare','apply','verify'):
            with self.subTest(command=command):self.exercise(command)

    def test_pending_cancellation_cannot_publish_a_plan_or_success(self):
        for command in('inventory','prepare','apply','verify'):
            with self.subTest(command=command):self.exercise(command,interrupted=True)

    def test_failed_cleanup_cannot_publish_inventory_or_plan(self):
        for command in('inventory','prepare'):
            with self.subTest(command=command):self.exercise(command,cleanup_error=True)

if __name__=='__main__':unittest.main()
