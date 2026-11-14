#!/usr/bin/env python3
"""Separate reviewed ACL preparation, application and verification.

Preparation admits only the held maintenance connection and leaves the company
database closed. No application startup, metadata routing, credentials or data
migration is included. Application requires its own operator authorization.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

import acl_catalog
import acl_corrections as corrections
from maintenance_session import MaintenanceSession
from maintenance_signals import defer_termination
from policy import digest,require
from run import database_sql,inventory_json_object,operator_lock,protected_read,protected_write,stopped_applications


def load_plan(path,protected=False):
    if protected:
        plan=protected_read(Path(path))
    else:
        source=Path(path)
        require(source.is_file() and not source.is_symlink() and source.stat().st_size<=16*1024*1024,'INVALID_PROPOSAL_FILE')
        plan=json.loads(source.read_text(encoding='utf-8'),object_pairs_hook=inventory_json_object)
    corrections.expected_after(plan)
    return plan


def ensure_new_output(path):
    path=Path(path)
    require(path.is_absolute() and path.parent.resolve()==path.parent and path.parent.is_dir() and not path.exists() and not path.is_symlink(),'NEW_PROTECTED_OUTPUT_REQUIRED')
    info=path.parent.stat()
    require(info.st_uid==0 and stat.S_IMODE(info.st_mode)==0o700,'UNSAFE_PLAN_DIRECTORY')


def capture(target,session):
    state=json.loads(session.query('BEGIN READ ONLY; SET LOCAL search_path=pg_catalog; SET LOCAL standard_conforming_strings=on; '+acl_catalog.snapshot_sql(target)+'; COMMIT;'))
    return acl_catalog.validate_snapshot(target,state)


def execute(args):
    require(getattr(os,'geteuid',lambda:-1)()==0,'ROOT_OPERATOR_REQUIRED')
    require(args.maintenance_window,'EXPLICIT_MAINTENANCE_WINDOW_REQUIRED')
    plan=load_plan(args.plan,protected=args.command!='prepare')
    require(args.expected_sha256==digest(plan),'REVIEWED_PLAN_HASH_REQUIRED')
    ensure_new_output(args.output)
    expected=corrections.expected_after(plan)
    with defer_termination(),operator_lock(),MaintenanceSession(acl_catalog.query_policy(plan['target']),lambda sql:database_sql('postgres',sql),stopped_applications) as session:
        before=capture(plan['target'],session)
        if args.command=='verify':
            require(corrections.equivalent(expected,before),'ACL_CORRECTION_VERIFICATION_FAILED')
            result=dict(status='acl_corrections_verified',planSha256=digest(plan),database=plan['target']['database'],afterSha256=digest(before),applicationsStarted=False)
        else:
            require(corrections.equivalent(plan['baseline'],before),'ACL_CORRECTION_BASELINE_CHANGED')
            if args.command=='prepare':
                corrections.guarded_sql(plan)
                result=plan
            else:
                stopped_applications()
                session.query(corrections.guarded_sql(plan))
                after=capture(plan['target'],session)
                require(corrections.equivalent(expected,after),'ACL_CORRECTION_VERIFICATION_FAILED')
                result=dict(status='acl_corrections_applied_and_verified',planSha256=digest(plan),database=plan['target']['database'],afterSha256=digest(after),operations=len(plan['operations']),registryChanged=False,applicationsStarted=False,passwordsChanged=False)
    # No successful plan/receipt publication until barrier cleanup is confirmed.
    # A committed change with lost transport is verified separately, never retried
    # blindly. Existing output files are never overwritten.
    protected_write(Path(args.output),result)
    print(json.dumps(dict(status='acl_corrections_prepared',planSha256=digest(plan),database=plan['target']['database'],permissionsChanged=False) if args.command=='prepare' else result))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('prepare','apply','verify'))
    parser.add_argument('--plan',required=True)
    parser.add_argument('--expected-sha256',required=True)
    parser.add_argument('--output',required=True,help='New file in an existing root-owned directory with mode 0700')
    parser.add_argument('--maintenance-window',action='store_true')
    try:
        execute(parser.parse_args())
    except (ValueError,OSError,subprocess.SubprocessError,json.JSONDecodeError) as error:
        code=str(error) if type(error) is ValueError and re.fullmatch('[A-Z_]+',str(error)) else 'OPERATOR_FAILURE_REVIEW_STATE_BEFORE_RETRY'
        print(json.dumps(dict(completed=False,code=code)),file=sys.stderr)
        sys.exit(1)
