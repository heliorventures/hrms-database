"""Security catalog snapshot and transactional ACL compare-and-apply."""
import copy
import json
from pathlib import Path

from policy import check_snapshot, digest, grant_sql, literal, validate_policy


def snapshot_sql(policy):
    validate_policy(policy)
    roles = "ARRAY[" + ",".join(literal(role) for role in sorted(policy["roles"])) + "]"
    baseline = json.loads(Path(__file__).with_name("system-baseline.json").read_text(encoding="utf-8"))
    information_schema = "ARRAY[" + ",".join(literal(name) for name in baseline["publicSelectRelations"]) + "]::text[]"
    return Path(__file__).with_name("snapshot.sql").read_text(encoding="utf-8").replace("__ROLES__", roles).replace("__SCHEMA__", literal(policy["schema"])).replace("__INFORMATION_SCHEMA_SELECT__", information_schema).strip().rstrip(";")


def expected_after(policy, baseline):
    state = copy.deepcopy(baseline)
    for row in state["schemas"]:
        if row["name"] == policy["schema"]:
            row["usage"] = True
    for row in state["databases"]:
        if row["name"] == policy["database"]:
            row["connect"] = True
    for role, permissions in policy["roles"].items():
        for table, rights in permissions["tables"].items():
            for operation, columns in rights.items():
                for column in ([None] if operation == "delete" else columns):
                    state["access"].append(dict(role=role, schema=policy["schema"], table=table, column=column, privilege=operation.upper(), grantOption=False))
        for sequence in permissions["sequences"]:
            state["sequenceAccess"].append(dict(role=role, schema=policy["schema"], sequence=sequence, privilege="USAGE", grantOption=False))
        for function in permissions["functions"]:
            state["functionAccess"].append(dict(role=role, schema=policy["schema"], **{key: function[key] for key in ("name", "identityArguments", "definitionSha256")}, grantOption=False))
    for key in ("access", "sequenceAccess", "functionAccess"):
        state[key] = list({json.dumps(row, sort_keys=True): row for row in state[key]}.values())
    check_snapshot(policy, state, complete=True)
    return state


def state_equivalent(actual, expected):
    if set(actual) != set(expected):
        return False
    for key in actual:
        left, right = actual[key], expected[key]
        if isinstance(left, list) and isinstance(right, list):
            if {json.dumps(row, sort_keys=True) for row in left} != {json.dumps(row, sort_keys=True) for row in right}:
                return False
        elif left != right:
            return False
    return True


def state_guard(policy, expected, code):
    query = snapshot_sql(policy)
    # Dollar tag must not occur in serialized defaults, identifiers or messages.
    body = "DECLARE actual jsonb; wanted jsonb := " + literal(json.dumps(expected, separators=(",", ":"))) + "::jsonb; key text; BEGIN actual := (" + query + "); FOR key IN SELECT jsonb_object_keys(wanted) LOOP IF jsonb_typeof(wanted->key)='array' THEN IF EXISTS ((SELECT value FROM jsonb_array_elements(actual->key) EXCEPT SELECT value FROM jsonb_array_elements(wanted->key)) UNION ALL (SELECT value FROM jsonb_array_elements(wanted->key) EXCEPT SELECT value FROM jsonb_array_elements(actual->key))) THEN RAISE EXCEPTION '" + code + "'; END IF; ELSIF (actual->key) IS DISTINCT FROM (wanted->key) THEN RAISE EXCEPTION '" + code + "'; END IF; END LOOP; END"
    tag = "$runtime_guard_" + digest(body) + "$"
    assert tag not in body
    return "DO " + tag + " " + body + " " + tag + ";"


def guarded_sql(policy, baseline):
    check_snapshot(policy, baseline)
    after = expected_after(policy, baseline)
    return "\n".join([
        "BEGIN;", "SET LOCAL search_path=pg_catalog;", "SET LOCAL standard_conforming_strings=on;", "SET LOCAL lock_timeout='5s';", "SET LOCAL statement_timeout='60s';",
        "SELECT pg_advisory_xact_lock(hashtextextended('hrms-runtime-grants:'||current_database(),0));",
        state_guard(policy, baseline, "RUNTIME_GRANT_BASELINE_CHANGED"),
        grant_sql(policy), state_guard(policy, after, "RUNTIME_GRANT_VERIFICATION_FAILED"), "COMMIT;"
    ])
