#!/usr/bin/env python3
"""Online, exact maintenance occurrence SELECT grants; no admission or data changes."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

import online_notification_columns as columns
from maintenance_signals import defer_termination
from policy import digest, require
from run import database_sql, operator_lock, protected_read, protected_write


def make_plan(target, before):
    columns.guarded_sql(target, before)
    return copy.deepcopy(dict(version=1, target=target, before=before,
                              requirementsSha256=digest(columns.REQUIREMENTS)))


def validate_plan(plan, expected_sha256):
    require(isinstance(plan, dict) and set(plan) == {
        'version', 'target', 'before', 'requirementsSha256'}, 'NOTIFICATION_PLAN_INVALID')
    require(type(plan['version']) is int and plan['version'] == 1 and
            plan['requirementsSha256'] == digest(columns.REQUIREMENTS),
            'NOTIFICATION_CONTRACT_CHANGED')
    require(isinstance(expected_sha256, str) and
            re.fullmatch('[a-f0-9]{64}', expected_sha256) and
            digest(plan) == expected_sha256, 'NOTIFICATION_PLAN_HASH_CHANGED')
    return columns.guarded_sql(plan['target'], plan['before'])


def capture(target, query):
    sql = ("BEGIN READ ONLY; SET LOCAL statement_timeout='10s'; " +
           columns.snapshot_sql(target) + '; COMMIT;')
    return json.loads(query(target['database'], sql))


def operate(command, plan, query):
    require(command in ('apply', 'verify'), 'NOTIFICATION_OPERATION_INVALID')
    sql = validate_plan(plan, digest(plan))
    if command == 'apply':
        # Exactly one transaction attempt. A lost reply can mean a commit;
        # reconcile with verify or a new preparation, never retry automatically.
        query(plan['target']['database'], sql)
    after = capture(plan['target'], query)
    expected = dict(plan['before'], required=[True] * len(plan['before']['required']))
    require(after == expected, 'NOTIFICATION_POSTCONDITION_FAILED')
    return after


def ensure_new_output(path):
    require(path.is_absolute() and path.parent.resolve() == path.parent and
            path.parent.is_dir() and not path.exists() and not path.is_symlink(),
            'NEW_PROTECTED_OUTPUT_REQUIRED')
    info = path.parent.stat()
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700,
            'UNSAFE_PLAN_DIRECTORY')


def execute(args):
    require(getattr(os, 'geteuid', lambda: -1)() == 0, 'ROOT_OPERATOR_REQUIRED')
    if args.command == 'apply':
        require(args.maintenance_window, 'EXPLICIT_MAINTENANCE_WINDOW_REQUIRED')
    output = Path(args.output)
    ensure_new_output(output)
    if args.command == 'prepare':
        require(not args.plan and not args.expected_sha256 and
                all((args.system_id, args.database, args.schema)), 'NOTIFICATION_TARGET_REQUIRED')
        target = dict(systemId=args.system_id, database=args.database, schema=args.schema)
        with defer_termination(), operator_lock():
            plan = make_plan(target, capture(target, database_sql))
        protected_write(output, plan)
        print(json.dumps(dict(status='notification_plan_prepared', planSha256=digest(plan),
                              target=target, permissionsChanged=False)))
        return
    require(args.plan and args.expected_sha256 and not any((args.system_id, args.database, args.schema)),
            'NOTIFICATION_PREPARED_PLAN_REQUIRED')
    plan = protected_read(Path(args.plan))
    validate_plan(plan, args.expected_sha256)
    result_path = Path(str(output) + '.result.json')
    ensure_new_output(result_path)
    with defer_termination(), operator_lock():
        protected_write(output, dict(status='operation_requested', command=args.command,
                                      planSha256=digest(plan), target=plan['target']))
        try:
            after = operate(args.command, plan, database_sql)
        except Exception:
            protected_write(result_path, dict(status='unconfirmed_reconcile_before_retry',
                                               command=args.command, planSha256=digest(plan)))
            raise
    result = dict(status='notification_grants_verified', command=args.command,
                  planSha256=digest(plan), afterSha256=digest(after), target=plan['target'],
                  admissionChanged=False, rowsChanged=False, credentialsChanged=False)
    protected_write(result_path, result)
    print(json.dumps(dict(result, receipt=str(result_path))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'apply', 'verify'))
    parser.add_argument('--system-id')
    parser.add_argument('--database')
    parser.add_argument('--schema')
    parser.add_argument('--plan')
    parser.add_argument('--expected-sha256')
    parser.add_argument('--output', required=True, help='New file in a root-owned mode-0700 directory')
    parser.add_argument('--maintenance-window', action='store_true')
    try:
        execute(parser.parse_args())
    except (ValueError, OSError, subprocess.SubprocessError, RuntimeError, TypeError, KeyError) as error:
        code = str(error) if type(error) is ValueError and re.fullmatch('[A-Z_]+', str(error)) else 'OPERATOR_FAILURE_RECONCILE_BEFORE_RETRY'
        print(json.dumps(dict(completed=False, code=code)), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
