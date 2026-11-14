"""Operator dispatch fixtures; no Docker, database, secrets or production access."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).parents[1]
sys.path.insert(0, str(HERE))


def load():
    spec = importlib.util.spec_from_file_location('runtime_runner_fixture', HERE / 'run.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def arguments(command, **kwargs):
    return SimpleNamespace(command=command, policy=None, plan='/safe/plan.json', output=None,
                           expected_sha256='reviewed', target=None, maintenance_window=False, **kwargs)


class RunTests(unittest.TestCase):
    def test_all_hrms_service_images_must_be_stopped_not_only_svc_image(self):
        runner = load()
        rows = [dict(Names=name, Image='legacy:fixture', State='exited') for name in runner.LEGACY]
        rows.append(dict(Names='company_tax_fixture', Image='registry.invalid/helior/kabipay-tax:fixture', State='running'))
        with patch.object(runner, 'command', return_value='\n'.join(json.dumps(row) for row in rows)):
            with self.assertRaisesRegex(ValueError, 'HRMS_WRITERS_MUST_REMAIN_STOPPED'):
                runner.stopped_applications()

    def test_mutating_paths_require_explicit_maintenance_flag_before_io(self):
        runner = load()
        for command in ['inventory', 'prepare', 'apply', 'verify']:
            args = arguments(command)
            with patch.object(runner.os, 'geteuid', return_value=0, create=True), \
                 patch.object(runner, 'protected_read', side_effect=AssertionError('no file IO')):
                with self.assertRaisesRegex(ValueError, 'EXPLICIT_MAINTENANCE_WINDOW_REQUIRED'):
                    runner.execute(args)

    def test_inventory_target_is_strict_and_never_becomes_an_apply_policy(self):
        runner = load()
        target = dict(version=1, systemId='1234', database='company_fixture', schema='tenant_fixture',
                      allowedDatabases=['company_fixture'], roles=['runtime_employee'])
        self.assertEqual(runner.validate_inventory_target(target), target)
        invalid = [dict(target, extra=True), dict(target, version=True), dict(target, systemId='0'),
                   dict(target, roles=[]), dict(target, roles=['runtime_employee'] * 2),
                   dict(target, roles=['unsafe;role']), dict(target, allowedDatabases=['other_fixture']),
                   dict(target, allowedDatabases=['company_fixture'] * 2), dict(target, schema='public')]
        invalid += [dict(target, database=name, allowedDatabases=[name]) for name in ['postgres','template0','template1']]
        invalid += [dict(target, allowedDatabases=['company_fixture','postgres'])]
        for candidate in invalid:
            with self.assertRaises(ValueError):
                runner.validate_inventory_target(candidate)

    def test_inventory_control_database_rejected_before_control_or_output_io(self):
        runner = load()
        target = dict(version=1, systemId='1234', database='postgres', schema='tenant_fixture',
                      allowedDatabases=['postgres'], roles=['runtime_employee'])
        args = arguments('inventory')
        args.target, args.plan, args.output, args.expected_sha256 = 'target.json', None, '/safe/new.json', None
        args.maintenance_window = True
        with patch.object(runner.os, 'geteuid', return_value=0, create=True), \
             patch.object(Path, 'read_text', return_value=json.dumps(target)), \
             patch.object(runner, 'operator_lock', side_effect=AssertionError('no lock IO')), \
             patch.object(runner, 'MaintenanceSession', side_effect=AssertionError('no connection or mutation')), \
             patch.object(runner, 'protected_write', side_effect=AssertionError('no output')):
            with self.assertRaisesRegex(ValueError, 'RESERVED_MAINTENANCE_DATABASE'):
                runner.execute(args)

    def test_inventory_dispatch_captures_unsafe_catalog_without_grants_or_full_acl_gate(self):
        runner = load()
        target = dict(version=1, systemId='1234', database='company_fixture', schema='tenant_fixture',
                      allowedDatabases=['company_fixture'], roles=['runtime_employee'])
        state = dict(systemId='1234', database='company_fixture', versionMajor='16', connections=0,
                     admissionBarrier=dict(allowConnections=False, connectionLimit=12),
                     roles=[dict(name='runtime_employee')], access=[dict(unsafe=True)], relations=[dict(name='example')])
        args = arguments('inventory')
        args.target, args.plan, args.output, args.expected_sha256 = 'target.json', None, '/safe/new.json', None
        args.maintenance_window = True
        queries = []
        session = SimpleNamespace(query=lambda sql: queries.append(sql) or json.dumps(state))
        with patch.object(runner.os, 'geteuid', return_value=0, create=True), \
             patch.object(Path, 'read_text', return_value=json.dumps(target)), \
             patch.object(runner, 'snapshot_sql', return_value='SELECT fixture_snapshot') as build, \
             patch.object(runner, 'check_snapshot', side_effect=AssertionError('inventory captures unsafe ACLs')), \
             patch.object(runner, 'guarded_sql', side_effect=AssertionError('inventory grants forbidden')), \
             patch.object(runner, 'operator_lock', return_value=contextlib.nullcontext()), \
             patch.object(runner, 'MaintenanceSession', return_value=contextlib.nullcontext(session)), \
             patch.object(runner, 'protected_write') as publish, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            runner.execute(args)
        artifact = publish.call_args.args[1]
        self.assertEqual(set(artifact), {'version','purpose','target','snapshot'})
        self.assertEqual(artifact['purpose'], 'catalog_inventory_only_not_grant_plan')
        self.assertEqual(artifact['snapshot']['access'], [dict(unsafe=True)])
        self.assertNotIn('policy', artifact)
        internal = build.call_args.args[0]
        self.assertEqual(internal['creators'], ['catalog_inventory_placeholder'])
        self.assertEqual(internal['roles']['runtime_employee'], dict(tables={},sequences=[],functions=[]))
        self.assertEqual(len(queries), 1)
        result = json.loads(output.getvalue())
        self.assertTrue(result['closed'])
        self.assertFalse(result['grantsChanged'])

    def test_inventory_refuses_open_or_wrong_snapshot_without_publishing(self):
        runner = load()
        target = dict(version=1, systemId='1234', database='company_fixture', schema='tenant_fixture',
                      allowedDatabases=['company_fixture'], roles=['runtime_employee'])
        state = dict(systemId='1234', database='company_fixture', versionMajor='16', connections=0,
                     admissionBarrier=dict(allowConnections=False, connectionLimit=12))
        for change in [dict(systemId='9999'),dict(database='wrong_fixture'),dict(versionMajor='15'),
                       dict(connections=1),dict(admissionBarrier=dict(allowConnections=True))]:
            with self.assertRaises(ValueError):
                runner.validate_inventory_snapshot(target, dict(state, **change))

    def test_exact_verify_rejects_changed_trigger_even_when_acl_check_passes(self):
        runner = load()
        expected = {'access': [], 'relations': [{'trigger': 'reviewed'}]}
        actual = {'access': [], 'relations': [{'trigger': 'changed'}]}
        with patch.object(runner, 'check_snapshot'), \
             patch.object(runner, 'expected_after', return_value=expected, create=True) as derive, \
             patch.object(runner, 'state_equivalent', side_effect=lambda wanted, got: wanted == got, create=True):
            with self.assertRaisesRegex(ValueError, 'RUNTIME_GRANT_VERIFICATION_FAILED'):
                runner.verify_expected({'roles': {}}, {'reviewed': 'baseline'}, actual)
            derive.assert_called_once_with({'roles': {}}, {'reviewed': 'baseline'})

    def test_verify_dispatch_uses_one_admitted_session_and_exact_poststate(self):
        runner = load()
        policy = {'database': 'company_fixture', 'roles': {}}
        baseline, expected = {'relations': ['before']}, {'relations': ['after']}
        plan = {'version': 1, 'policy': policy, 'baseline': baseline}
        args = arguments('verify')
        args.maintenance_window = True
        queries = []
        session = SimpleNamespace(query=lambda sql: queries.append(sql) or json.dumps(expected))
        with patch.object(runner.os, 'geteuid', return_value=0, create=True), \
             patch.object(runner, 'protected_read', return_value=plan), \
             patch.object(runner, 'digest', return_value='reviewed'), \
             patch.object(runner, 'validate_policy', side_effect=lambda p: p), \
             patch.object(runner, 'check_snapshot'), \
             patch.object(runner, 'snapshot_sql', return_value='SELECT fixture_snapshot'), \
             patch.object(runner, 'expected_after', return_value=expected, create=True), \
             patch.object(runner, 'state_equivalent', side_effect=lambda wanted, got: wanted == got, create=True), \
             patch.object(runner, 'operator_lock', return_value=contextlib.nullcontext(), create=True), \
             patch.object(runner, 'MaintenanceSession', return_value=contextlib.nullcontext(session), create=True) as admitted, \
             patch.object(runner, 'database_sql', side_effect=AssertionError('no second target connection')), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            runner.execute(args)
        admitted.assert_called_once()
        self.assertEqual(len(queries), 1)
        self.assertEqual(json.loads(output.getvalue())['status'], 'runtime_grants_verified')

    def test_preview_explicitly_reports_no_held_barrier(self):
        runner = load()
        args = arguments('preview')
        args.policy, args.plan = 'policy.json', None
        with patch.object(runner.os, 'geteuid', return_value=0, create=True), \
             patch.object(Path, 'read_text', return_value='{}'), \
             patch.object(runner, 'validate_policy', return_value={'database': 'company_fixture', 'roles': {}}), \
             patch.object(runner, 'snapshot', return_value={'admissionBarrier': {'allowConnections': True}}), \
             patch.object(runner, 'stopped_applications', side_effect=AssertionError('read only')), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            runner.execute(args)
        result = json.loads(output.getvalue())
        self.assertFalse(result['barrierReady'])
        self.assertEqual(result['status'], 'runtime_grants_preview_not_barrier_ready')


if __name__ == '__main__':
    unittest.main()
