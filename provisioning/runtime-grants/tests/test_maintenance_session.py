"""Local protocol/orchestration fixtures; never connect to PostgreSQL or Docker."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).parents[1]
sys.path.insert(0, str(HERE))


def load():
    spec = importlib.util.spec_from_file_location('maintenance_session', HERE / 'maintenance_session.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Fixture:
    def __init__(self, available=False, fail_connect=False, sessions=0):
        self.available, self.limit = available, 12
        self.fail_connect, self.sessions = fail_connect, sessions
        self.calls = []
        self.role = dict(name='runtime_employee', canLogin=True, superuser=False,
                         createDb=False, createRole=False, inherit=False, replication=False, bypassRls=False)

    def control(self, sql):
        self.calls.append(sql)
        if 'ALLOW_CONNECTIONS false' in sql:
            self.available = False
        if 'CONNECTION LIMIT 0' in sql:
            self.limit = 0
        if 'ALLOW_CONNECTIONS true' in sql:
            self.available = True
        if 'CONNECTION LIMIT 12' in sql:
            self.limit = 12
        return json.dumps(dict(systemId='1234', database='company_fixture', databaseOid=77,
                               controlDatabase='postgres', controlDatabaseOid=5,
                               owner='postgres', template=False, allowConnections=self.available,
                               connectionLimit=self.limit, operator='postgres', operatorSuperuser=True,
                               roles=[self.role], otherConnections=self.sessions))

    def connect(self, database):
        self.calls.append('CONNECT:' + database)
        if self.fail_connect:
            raise ValueError('TARGET_CONNECT_FAILED')
        return self

    def query(self, sql):
        self.calls.append('TARGET:' + sql)
        return json.dumps(dict(systemId='1234', database='company_fixture', operator='postgres',
                               operatorSuperuser=True, backendPid=987))

    def close(self):
        self.calls.append('CLOSE_TARGET')


POLICY = dict(systemId='1234', database='company_fixture', roles={'runtime_employee': {}})


class MaintenanceTests(unittest.TestCase):
    def test_actual_control_identity_and_distinct_oid_are_checked_before_alter(self):
        m = load()
        for change in [dict(controlDatabase='company_fixture'), dict(controlDatabaseOid=77),
                       dict(controlDatabaseOid='5')]:
            f = Fixture()
            original = f.control
            def control(sql):
                return json.dumps(dict(json.loads(original(sql)), **change))
            with self.assertRaisesRegex(ValueError, 'UNSAFE_CONTROL_DATABASE_IDENTITY'):
                with m.MaintenanceSession(POLICY, control, lambda: None, f.connect):
                    pass
            self.assertFalse(any(sql.startswith('ALTER ') for sql in f.calls))
            self.assertFalse(any(sql.startswith('CONNECT:') for sql in f.calls))

    def test_control_and_template_targets_refused_before_any_control_or_inventory_io(self):
        m = load()
        for database in ['postgres', 'template0', 'template1']:
            f = Fixture()
            with self.assertRaisesRegex(ValueError, 'RESERVED_MAINTENANCE_DATABASE'):
                m.MaintenanceSession(dict(POLICY, database=database), f.control,
                                     lambda: f.calls.append('STOPPED'), f.connect)
            self.assertEqual(f.calls, [])

    def test_control_snapshot_casts_postgres_oid_to_json_number(self):
        m = load()
        # PostgreSQL jsonb_build_object serializes oid itself as a JSON string;
        # bigint has a JSON-number representation. Keep strict integer decoding.
        self.assertIn("'databaseOid',d.oid::bigint", m.control_snapshot_sql(POLICY))
        f = Fixture()
        original = f.control
        def uncast_oid(sql):
            row = json.loads(original(sql))
            row['databaseOid'] = '77'
            return json.dumps(row)
        with self.assertRaisesRegex(ValueError, 'UNREVIEWED_DATABASE_FLAGS'):
            with m.MaintenanceSession(POLICY, uncast_oid, lambda: None, f.connect):
                self.fail('uncast string must not weaken strict identity validation')

    def test_closed_admission_restores_limit_but_never_reopens(self):
        m = load()
        f = Fixture()
        with m.MaintenanceSession(POLICY, f.control, lambda: f.calls.append('STOPPED'), f.connect) as session:
            self.assertIs(session, f)
            self.assertFalse(f.available)
            self.assertEqual(f.limit, 12)
        self.assertFalse(f.available)
        self.assertEqual(sum('ALLOW_CONNECTIONS true' in sql for sql in f.calls), 1)
        self.assertLess(f.calls.index('STOPPED'), f.calls.index('CONNECT:company_fixture'))

    def test_initially_open_database_stays_closed_after_body_failure(self):
        m, f = load(), Fixture(available=True)
        with self.assertRaisesRegex(ValueError, 'BODY_FAILED'):
            with m.MaintenanceSession(POLICY, f.control, lambda: None, f.connect):
                raise ValueError('BODY_FAILED')
        self.assertFalse(f.available)
        self.assertFalse(any('ALLOW_CONNECTIONS true' in sql for sql in f.calls))

    def test_failed_target_startup_closes_admission_and_restores_limit(self):
        m, f = load(), Fixture(fail_connect=True)
        with self.assertRaisesRegex(ValueError, 'TARGET_CONNECT_FAILED'):
            with m.MaintenanceSession(POLICY, f.control, lambda: None, f.connect):
                self.fail('must not enter body')
        self.assertFalse(f.available)
        self.assertEqual(f.limit, 12)

    def test_other_sessions_refuse_work_without_termination_or_reopening(self):
        m, f = load(), Fixture(sessions=1)
        with self.assertRaisesRegex(ValueError, 'DATABASE_WRITERS_NOT_FROZEN'):
            with m.MaintenanceSession(POLICY, f.control, lambda: None, f.connect):
                self.fail('must not enter body')
        self.assertFalse(f.available)
        self.assertFalse(any('terminate_backend' in sql for sql in f.calls))

    def test_wrong_cluster_or_unsafe_role_never_admits(self):
        m = load()
        for wrong in ['cluster', 'role']:
            f = Fixture()
            policy = dict(POLICY, systemId='9999') if wrong == 'cluster' else POLICY
            if wrong == 'role':
                f.role['superuser'] = True
            with self.assertRaises(ValueError):
                with m.MaintenanceSession(policy, f.control, lambda: None, f.connect):
                    self.fail('must not enter body')
            self.assertFalse(any('ALLOW_CONNECTIONS true' in sql for sql in f.calls))

    def test_stopped_container_recheck_failure_keeps_database_closed(self):
        m, f = load(), Fixture()
        calls = []
        def stopped():
            calls.append(True)
            if len(calls) > 1:
                raise ValueError('HRMS_WRITERS_MUST_REMAIN_STOPPED')
        with self.assertRaisesRegex(ValueError, 'HRMS_WRITERS_MUST_REMAIN_STOPPED'):
            with m.MaintenanceSession(POLICY, f.control, stopped, f.connect):
                self.fail('container restart must refuse work')
        self.assertFalse(f.available)

    def test_failed_barrier_confirmation_supersedes_body_error_without_reopening(self):
        m, f = load(), Fixture()
        original = f.control
        fails = []
        def control(sql):
            if fails and sql.startswith('SELECT'):
                raise ValueError('CONTROL_FAILED')
            return original(sql)
        with self.assertRaisesRegex(ValueError, 'MAINTENANCE_BARRIER_CONFIRMATION_FAILED'):
            with m.MaintenanceSession(POLICY, control, lambda: None, f.connect):
                fails.append(True)
                raise ValueError('BODY_FAILED')
        self.assertFalse(f.available)
        self.assertEqual(sum('ALLOW_CONNECTIONS true' in sql for sql in f.calls), 1)

    def test_client_close_error_preserves_body_failure_when_barrier_confirmed(self):
        m, f = load(), Fixture()
        def close():
            raise OSError('raw client detail')
        f.close = close
        with self.assertRaisesRegex(ValueError, 'BODY_FAILED'):
            with m.MaintenanceSession(POLICY, f.control, lambda: None, f.connect):
                raise ValueError('BODY_FAILED')
        self.assertFalse(f.available)

    def test_persistent_protocol_multiple_requests_and_raw_stderr_suppressed(self):
        m = load()
        fixture = '''import sys
for line in sys.stdin:
 if line.startswith("\\\\echo "):
  print(line.strip()[6:], flush=True)
 elif "fixture_one" in line:
  print("one", flush=True)
 elif "fixture_two" in line:
  print("two", flush=True)
 sys.stderr.write("sensitive server detail\\n"); sys.stderr.flush()
'''
        # Correct psql metacommand spelling inside the fixture source.
        fixture = fixture.replace('\\\\echo', '\\echo')
        with m.PersistentPsql('company_fixture', command_factory=lambda _: [sys.executable, '-u', '-c', fixture], timeout=2) as session:
            self.assertEqual(session.query('SELECT fixture_one;'), 'one')
            self.assertEqual(session.query('SELECT fixture_two;'), 'two')

    def test_protocol_eof_and_timeout_never_return_partial_success(self):
        m = load()
        for code in ['import sys; sys.stderr.write("secret"); sys.exit(2)',
                     'import time; time.sleep(3)']:
            with self.assertRaisesRegex(ValueError, 'PSQL_REQUEST_FAILED|PSQL_REQUEST_TIMEOUT'):
                with m.PersistentPsql('company_fixture', command_factory=lambda _: [sys.executable, '-u', '-c', code], timeout=.2) as session:
                    session.query('SELECT 1;')


if __name__ == '__main__':
    unittest.main()
