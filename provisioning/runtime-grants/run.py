#!/usr/bin/env python3
"""Operator-only, explicit-contract runtime grants. No CA keys or passwords read."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

import catalog
from catalog import expected_after, guarded_sql, snapshot_sql
from maintenance_session import MaintenanceSession, RESERVED_MAINTENANCE_DATABASES, psql_command
from maintenance_signals import defer_termination
from policy import check_snapshot, digest, identifier, literal, require, validate_policy


LEGACY = {"kabipay-gateway", "kabipay-ui", "kabipay-subgraphs", "kabipay-auth", "kabipay-outbox-worker"}


def command(arguments, sql=None):
    result = subprocess.run(arguments, input=sql, text=True, capture_output=True, timeout=180)
    require(result.returncode == 0, "OPERATOR_COMMAND_FAILED_RAW_OUTPUT_SUPPRESSED")
    return result.stdout.strip()


def database_sql(database, sql):
    identifier(database)
    # Only a validated identifier is interpolated. Username comes from the
    # existing PostgreSQL container, never a password file or .env.
    return command(psql_command(database), "SET search_path=pg_catalog; SET standard_conforming_strings=on;\n" + sql + "\n")


def snapshot(policy):
    availability = json.loads(database_sql("postgres", "SELECT jsonb_build_object('systemId',(SELECT system_identifier::text FROM pg_control_system()),'available',coalesce((SELECT datallowconn FROM pg_database WHERE datname=" + literal(policy["database"]) + "),false));"))
    require(availability["systemId"] == policy["systemId"], "WRONG_CLUSTER")
    require(availability["available"], "DATABASE_CLOSED_REQUIRES_REVIEWED_CUTOVER_STEP")
    return json.loads(database_sql(policy["database"], "SET default_transaction_read_only=on;\n" + snapshot_sql(policy) + ";"))


def state_equivalent(expected, actual):
    return catalog.state_equivalent(expected, actual)


def verify_expected(policy, baseline, state):
    check_snapshot(policy, state, complete=True)
    require(state_equivalent(expected_after(policy, baseline), state), "RUNTIME_GRANT_VERIFICATION_FAILED")


@contextmanager
def operator_lock():
    # All admission-changing operations, including preparation and verification,
    # serialize on the same operator lock. This is not the writer barrier.
    import fcntl
    descriptor = os.open("/run/lock/hrms-runtime-grants.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        lock_info = os.fstat(descriptor)
        require(lock_info.st_uid == 0 and stat.S_IMODE(lock_info.st_mode) == 0o600 and stat.S_ISREG(lock_info.st_mode), "UNSAFE_OPERATOR_LOCK")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def session_snapshot(policy, session):
    return json.loads(session.query(snapshot_sql(policy) + ";"))


def validate_inventory_target(target):
    require(isinstance(target, dict) and set(target) == {"version", "systemId", "database", "schema", "allowedDatabases", "roles"}, "INVALID_INVENTORY_TARGET")
    require(type(target["version"]) is int and target["version"] == 1, "INVALID_INVENTORY_TARGET")
    system_id = target["systemId"]
    require(isinstance(system_id, str) and re.fullmatch(r"[0-9]{1,20}", system_id) is not None and 0 < int(system_id) < 2 ** 64, "INVALID_SYSTEM_ID")
    identifier(target["database"])
    require(target["database"] not in RESERVED_MAINTENANCE_DATABASES, "RESERVED_MAINTENANCE_DATABASE")
    identifier(target["schema"])
    for field, limit in (("roles", 64), ("allowedDatabases", 1024)):
        names = target[field]
        require(isinstance(names, list) and 0 < len(names) <= limit and all(isinstance(name, str) for name in names), "INVALID_INVENTORY_TARGET")
        require(len(set(names)) == len(names), "DUPLICATE_INVENTORY_TARGET")
        for name in names:
            identifier(name)
            if field == "allowedDatabases":
                require(name not in RESERVED_MAINTENANCE_DATABASES, "RESERVED_MAINTENANCE_DATABASE")
    require(target["database"] in target["allowedDatabases"], "INVALID_DATABASE_ALLOWLIST")
    return target


def inventory_json_object(pairs):
    require(len(dict(pairs)) == len(pairs), "DUPLICATE_INVENTORY_TARGET_FIELD")
    return dict(pairs)


def validate_inventory_snapshot(target, state):
    # Inventory records unsafe catalog findings for review. It deliberately does
    # not apply the permission upper-bound gate used by a reviewed grant policy.
    require(isinstance(state, dict) and state.get("systemId") == target["systemId"] and state.get("database") == target["database"] and state.get("versionMajor") == "16", "WRONG_DATABASE_OR_CLUSTER")
    require(type(state.get("connections")) is int and state["connections"] == 0, "DATABASE_WRITERS_NOT_FROZEN")
    barrier = state.get("admissionBarrier")
    require(isinstance(barrier, dict) and barrier.get("allowConnections") is False and type(barrier.get("connectionLimit")) is int, "MAINTENANCE_BARRIER_CONFIRMATION_FAILED")


def stopped_applications():
    rows = [json.loads(line) for line in command(["docker", "ps", "-a", "--format", "{{json .}}"]).splitlines() if line.strip()]
    names = {row["Names"] for row in rows}
    require(LEGACY <= names, "LEGACY_CONTAINER_INVENTORY_CHANGED")
    for row in rows:
        image = row["Image"].split("@", 1)[0]
        is_hrms = re.search(r"(?:^|/)kabipay-[a-z0-9_-]+(?::|$)", image)
        if row["Names"] in LEGACY or row["Names"].startswith("kabipay-") or is_hrms:
            require(row["State"] in ("exited", "created", "dead"), "HRMS_WRITERS_MUST_REMAIN_STOPPED")


def protected_read(path):
    require(path.is_absolute() and path.resolve() == path, "UNSAFE_PLAN_PATH")
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600, "UNSAFE_PLAN_FILE")
    parent = path.parent
    require(parent.is_dir() and parent.stat().st_uid == 0 and stat.S_IMODE(parent.stat().st_mode) == 0o700, "UNSAFE_PLAN_DIRECTORY")
    return json.loads(path.read_text(encoding="utf-8"))


def protected_write(path, value):
    require(path.is_absolute() and path.parent.resolve() == path.parent and path.parent.is_dir(), "UNSAFE_PLAN_PATH")
    info = path.parent.stat()
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700, "UNSAFE_PLAN_DIRECTORY")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def execute(args):
    require(os.geteuid() == 0, "ROOT_OPERATOR_REQUIRED")
    if args.command != "preview":
        require(getattr(args, "maintenance_window", False), "EXPLICIT_MAINTENANCE_WINDOW_REQUIRED")
    if args.command == "inventory":
        require(getattr(args, "target", None) and args.output and not args.policy and not args.plan and not args.expected_sha256, "INVENTORY_TARGET_AND_NEW_OUTPUT_REQUIRED")
        target = validate_inventory_target(json.loads(Path(args.target).read_text(encoding="utf-8"), object_pairs_hook=inventory_json_object))
        # This query-only compiler input is never published as a grant policy.
        query_policy = validate_policy({"version": 1, "systemId": target["systemId"], "database": target["database"], "schema": target["schema"], "allowedDatabases": target["allowedDatabases"], "creators": ["catalog_inventory_placeholder"], "roles": {role: {"tables": {}, "sequences": [], "functions": []} for role in target["roles"]}, "blockers": []})
        with defer_termination(), operator_lock(), MaintenanceSession(query_policy, lambda sql: database_sql("postgres", sql), stopped_applications) as session:
            state = session_snapshot(query_policy, session)
            validate_inventory_snapshot(target, state)
        protected_write(Path(args.output), {"version": 1, "purpose": "catalog_inventory_only_not_grant_plan", "target": target, "snapshot": state})
        print(json.dumps({"status": "runtime_catalog_inventory_recorded", "database": target["database"], "counts": {"roles": len(target["roles"]), "relations": len(state.get("relations", [])), "functions": len(state.get("functions", [])), "effectiveTablePrivileges": len(state.get("access", []))}, "closed": True, "grantsChanged": False}))
        return
    require(not getattr(args, "target", None), "TARGET_ONLY_ALLOWED_FOR_INVENTORY")
    if args.command in ("preview", "prepare"):
        require(args.policy and not args.plan, "POLICY_REQUIRED")
        policy = validate_policy(json.loads(Path(args.policy).read_text(encoding="utf-8")))
        if args.command == "prepare":
            require(args.output is not None, "NEW_PROTECTED_OUTPUT_REQUIRED")
            with defer_termination(), operator_lock(), MaintenanceSession(policy, lambda sql: database_sql("postgres", sql), stopped_applications) as session:
                state = session_snapshot(policy, session)
                check_snapshot(policy, state)
                plan = {"version": 1, "policy": policy, "baseline": state}
                # Compile/check without applying. Admission remains closed.
                guarded_sql(policy, state)
            protected_write(Path(args.output), plan)
            print(json.dumps({"status": "runtime_grants_prepared", "planSha256": digest(plan), "database": policy["database"], "roles": len(policy["roles"]), "productionGrantsChanged": False}))
        else:
            snapshot(policy)  # Read-only observation, not a freeze or approved plan.
            print(json.dumps({"status": "runtime_grants_preview_not_barrier_ready", "barrierReady": False, "database": policy["database"], "roles": len(policy["roles"]), "productionGrantsChanged": False}))
        return
    require(args.plan and not args.policy, "PREPARED_PLAN_REQUIRED")
    plan = protected_read(Path(args.plan))
    require(set(plan) == {"version", "policy", "baseline"} and plan["version"] == 1, "INVALID_OPERATOR_PLAN")
    require(args.expected_sha256 == digest(plan), "REVIEWED_PLAN_HASH_REQUIRED")
    policy = validate_policy(plan["policy"])
    with defer_termination(), operator_lock(), MaintenanceSession(policy, lambda sql: database_sql("postgres", sql), stopped_applications) as session:
        if args.command == "verify":
            verify_expected(policy, plan["baseline"], session_snapshot(policy, session))
            status = {"status": "runtime_grants_verified", "database": policy["database"], "roles": len(policy["roles"]), "applicationsStarted": False}
        else:
            # A retry uses a new preview/plan, never guesses whether a failed network
            # command committed. Grants are additive only, with no automatic revokes.
            require(state_equivalent(plan["baseline"], session_snapshot(policy, session)), "RUNTIME_GRANT_BASELINE_CHANGED")
            stopped_applications()
            session.query(guarded_sql(policy, plan["baseline"]))
            verify_expected(policy, plan["baseline"], session_snapshot(policy, session))
            status = {"status": "runtime_grants_applied_and_verified", "database": policy["database"], "roles": len(policy["roles"]), "planSha256": digest(plan), "passwordsChanged": False, "registryChanged": False, "applicationsStarted": False}
    # A failed barrier confirmation must never emit success before context exit.
    print(json.dumps(status))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inventory", "preview", "prepare", "apply", "verify"))
    parser.add_argument("--target", help="Strict catalog inventory identity file, never a grant policy")
    parser.add_argument("--policy")
    parser.add_argument("--plan")
    parser.add_argument("--output")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--maintenance-window", action="store_true", help="Explicitly authorize this reviewed admission action; the database remains closed afterward, including on failure")
    try:
        execute(parser.parse_args())
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        # Database and OS output are not evidence suitable for chat. Stable,
        # programmer-defined ValueError codes only; all other details suppressed.
        code = str(error) if type(error) is ValueError and re.fullmatch(r"[A-Z_]+", str(error)) else "OPERATOR_FAILURE_REVIEW_STATE_BEFORE_RETRY"
        print(json.dumps({"completed": False, "code": code}), file=sys.stderr)
        sys.exit(1)
