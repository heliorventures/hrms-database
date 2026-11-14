"""Held PostgreSQL admission barrier through one socket operator connection.

No passwords, .env, remote DSNs, HBA changes, session termination or automatic
availability restoration. Command injection exists only as a library test seam.
"""
import json
import queue
import subprocess
import threading
import time
import uuid

from policy import RESERVED_MAINTENANCE_DATABASES, identifier, literal, require



def psql_command(database):
    identifier(database)
    script = ('exec psql -X -qAt --no-password -h /var/run/postgresql '
              '-v ON_ERROR_STOP=1 -P pager=off -U "${POSTGRES_USER:-postgres}" -d ' + database)
    return ['docker', 'exec', '-i', 'postgres', 'sh', '-c', script]


class PersistentPsql:
    """A request is successful only after its unique psql completion marker."""
    MAX_LINE = 32 * 1024 * 1024
    MAX_RESPONSE = 64 * 1024 * 1024

    def __init__(self, database, command_factory=None, timeout=180):
        identifier(database)
        self.timeout = timeout
        self.process = subprocess.Popen((command_factory or psql_command)(database), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                        encoding='utf-8', errors='replace', bufsize=1)
        self.lines = queue.Queue(maxsize=1024)
        self.closed = False
        self.lock = threading.Lock()
        self.stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self.stderr_thread = threading.Thread(target=self._discard_stderr, daemon=True)
        self.stdout_thread.start()
        self.stderr_thread.start()

    def _read_stdout(self):
        try:
            while True:
                line = self.process.stdout.readline(self.MAX_LINE + 1)
                if not line:
                    break
                if len(line) > self.MAX_LINE:
                    self.lines.put(None)
                    return
                self.lines.put(line.rstrip('\r\n'))
        finally:
            self.lines.put(None)

    def _discard_stderr(self):
        # Drain a bounded chunk at a time; never retain or print server errors.
        while self.process.stderr.read(4096):
            pass

    def query(self, sql):
        with self.lock:
            require(not self.closed, 'PSQL_SESSION_CLOSED')
            marker = 'runtime_request_' + uuid.uuid4().hex
            deadline = time.monotonic() + self.timeout
            output, size = [], 0
            try:
                self.process.stdin.write(sql.rstrip() + '\n;\n\\echo ' + marker + '\n')
                self.process.stdin.flush()
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise queue.Empty
                    line = self.lines.get(timeout=remaining)
                    require(line is not None, 'PSQL_REQUEST_FAILED')
                    if line == marker:
                        return '\n'.join(output).strip()
                    size += len(line)
                    require(size <= self.MAX_RESPONSE, 'PSQL_RESPONSE_LIMIT')
                    output.append(line)
            except queue.Empty:
                self.close()
                raise ValueError('PSQL_REQUEST_TIMEOUT') from None
            except (OSError, ValueError):
                self.close()
                raise ValueError('PSQL_REQUEST_FAILED') from None

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            # Only this local client process; never pg_terminate_backend or peers.
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1)
        self.stdout_thread.join(timeout=.2)
        self.stderr_thread.join(timeout=.2)
        self.process.stdout.close()
        self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()


def control_snapshot_sql(policy, backend_pid=None):
    database = literal(policy['database'])
    roles = 'ARRAY[' + ','.join(literal(role) for role in sorted(policy['roles'])) + ']::text[]'
    excluded = '' if backend_pid is None else ' AND pid<>' + str(int(backend_pid))
    return ("SELECT jsonb_build_object('systemId',(SELECT system_identifier::text FROM pg_control_system()),"
            "'controlDatabase',current_database(),'controlDatabaseOid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),"
            "'database',d.datname,'databaseOid',d.oid::bigint,'owner',pg_get_userbyid(d.datdba),"
            "'template',d.datistemplate,'allowConnections',d.datallowconn,'connectionLimit',d.datconnlimit,"
            "'operator',current_user,'operatorSuperuser',(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
            "'roles',coalesce((SELECT jsonb_agg(jsonb_build_object('name',rolname,'canLogin',rolcanlogin,"
            "'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'inherit',rolinherit,"
            "'replication',rolreplication,'bypassRls',rolbypassrls) ORDER BY rolname) FROM pg_roles WHERE rolname=ANY(" + roles + ")), '[]'::jsonb),"
            "'otherConnections',(SELECT count(*) FROM pg_stat_activity WHERE datname=" + database + excluded + ")) FROM pg_database d WHERE d.datname=" + database + ';')


class MaintenanceSession:
    def __init__(self, policy, control_query, stopped_applications, session_factory=PersistentPsql):
        # Never close the fixed control database or a template. This precondition
        # also protects library callers bypassing CLI target/policy validation.
        identifier(policy['database'])
        require(policy['database'] not in RESERVED_MAINTENANCE_DATABASES, 'RESERVED_MAINTENANCE_DATABASE')
        self.policy, self.control = policy, control_query
        self.stopped_applications, self.session_factory = stopped_applications, session_factory
        self.session, self.original, self.touched = None, None, False
        self.backend_pid = None
        self.target = identifier(policy['database'])

    def _state(self):
        state = json.loads(self.control(control_snapshot_sql(self.policy, self.backend_pid)))
        require(isinstance(state, dict), 'WRONG_DATABASE_OR_CLUSTER')
        require(state.get('systemId') == self.policy['systemId'] and state.get('database') == self.policy['database'], 'WRONG_DATABASE_OR_CLUSTER')
        require(state.get('operatorSuperuser') is True and isinstance(state.get('operator'), str), 'SUPERUSER_SOCKET_OPERATOR_REQUIRED')
        require(type(state.get('databaseOid')) is int and state['databaseOid'] > 0 and state.get('template') is False, 'UNREVIEWED_DATABASE_FLAGS')
        require(state.get('controlDatabase') == 'postgres' and type(state.get('controlDatabaseOid')) is int and state['controlDatabaseOid'] > 0 and state['controlDatabaseOid'] != state['databaseOid'], 'UNSAFE_CONTROL_DATABASE_IDENTITY')
        require(type(state.get('connectionLimit')) is int and state['connectionLimit'] >= -1 and type(state.get('allowConnections')) is bool, 'UNREVIEWED_DATABASE_FLAGS')
        roles = {role['name']: role for role in state.get('roles', [])}
        require(set(roles) == set(self.policy['roles']), 'ROLE_BASELINE_CHANGED')
        for role in roles.values():
            require(role.get('canLogin') is True and all(role.get(key) is False for key in ('superuser','createDb','createRole','inherit','replication','bypassRls')), 'UNRESTRICTED_RUNTIME_ROLE')
        if self.original:
            for key in ['systemId','database','databaseOid','controlDatabase','controlDatabaseOid','owner','template','operator','operatorSuperuser','roles']:
                require(state.get(key) == self.original.get(key), 'MAINTENANCE_IDENTITY_CHANGED')
        return state

    def _close_barrier(self):
        # Two independent commands: closing admission must precede limit restore.
        self.control('ALTER DATABASE ' + self.target + ' ALLOW_CONNECTIONS false;')
        self.control('ALTER DATABASE ' + self.target + ' CONNECTION LIMIT ' + str(self.original['connectionLimit']) + ';')
        state = self._state()
        require(state['allowConnections'] is False and state['connectionLimit'] == self.original['connectionLimit'], 'MAINTENANCE_BARRIER_CONFIRMATION_FAILED')
        return state

    def __enter__(self):
        self.stopped_applications()
        self.original = self._state()
        try:
            self.touched = True
            self.control('ALTER DATABASE ' + self.target + ' CONNECTION LIMIT 0;')
            if not self.original['allowConnections']:
                self.control('ALTER DATABASE ' + self.target + ' ALLOW_CONNECTIONS true;')
            self.session = self.session_factory(self.policy['database'])
            identity = json.loads(self.session.query("SET search_path=pg_catalog; SET standard_conforming_strings=on; SELECT jsonb_build_object('systemId',(SELECT system_identifier::text FROM pg_control_system()),'database',current_database(),'operator',current_user,'operatorSuperuser',(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),'backendPid',pg_backend_pid());"))
            # Close immediately after proving the target connection was admitted.
            pid = identity.get('backendPid')
            require(type(pid) is int and pid > 0, 'TARGET_SESSION_IDENTITY_CHANGED')
            self.backend_pid = pid
            state = self._close_barrier()
            require(all(identity.get(key) == self.original[key] for key in ['systemId','database','operator','operatorSuperuser']), 'TARGET_SESSION_IDENTITY_CHANGED')
            require(state['otherConnections'] == 0, 'DATABASE_WRITERS_NOT_FROZEN')
            self.stopped_applications()
            return self.session
        except BaseException:
            self.__exit__(*__import__('sys').exc_info())
            raise

    def __exit__(self, exception_type, exception, traceback):
        barrier_error = None
        if self.touched:
            try:
                self._close_barrier()
            except BaseException:
                barrier_error = ValueError('MAINTENANCE_BARRIER_CONFIRMATION_FAILED')
        if self.session:
            try:
                self.session.close()
            except Exception:
                if exception is None and barrier_error is None:
                    raise ValueError('PSQL_SESSION_CLOSE_FAILED') from None
        if barrier_error:
            raise barrier_error from None
        return False
