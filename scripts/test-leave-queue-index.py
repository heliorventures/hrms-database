"""Exercise migration 0081 and its rollback against the disposable queue-test container.

Run: py -3 scripts/test-leave-queue-index.py
Requires the local container described in the UI hardening evidence document.
Never connects to the normal tenant database or accepts a production connection string.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET


CONTAINER = "codex-leave-queue-hardening-20260910"
SCHEMA = "queue_index_test_" + uuid.uuid4().hex
ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = {"lb": "http://www.liquibase.org/xml/ns/dbchangelog"}
MIGRATION = ROOT / "changelog/migrations/0081_leave_approval_queue_index/leave_approval_queue_index.xml"


def sql(statement):
    result = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-X", "-qAt",
         "-v", "ON_ERROR_STOP=1", "-U", "queue_test", "-d", "leave_queue_test"],
        input=statement, text=True, capture_output=True, check=True,
    )
    return result.stdout.strip()


def nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from nodes(child)


def run_migration(command):
    with tempfile.TemporaryDirectory(prefix="queue-index-", dir=ROOT.parent / ".codex-tmp") as folder:
        properties = Path(folder) / "liquibase.properties"
        properties.write_text("\n".join([
            "changeLogFile=changelog/migrations/0081_leave_approval_queue_index/leave_approval_queue_index.xml",
            "url=jdbc:postgresql://127.0.0.1:15439/leave_queue_test",
            "username=queue_test", "password=queue_test_local_only",
            "driver=org.postgresql.Driver", f"defaultSchemaName={SCHEMA}",
            f"parameter.schema={SCHEMA}", "liquibase.hub.mode=off",
        ]), encoding="ascii")
        result = subprocess.run(
            ["node", "run-liquibase.cjs", f"--defaults-file={properties}", *command],
            cwd=ROOT, text=True, capture_output=True,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--liquibase", action="store_true", help="Execute update/rollback through the bundled Liquibase runner")
    args = parser.parse_args()
    assert sql("SELECT current_database()") == "leave_queue_test"
    change = ET.parse(MIGRATION).getroot().find("lb:changeSet", NAMESPACE)
    assert change is not None and change.attrib["runInTransaction"] == "false"
    create = change.find("lb:sql", NAMESPACE)
    rollback = change.find("lb:rollback/lb:sql", NAMESPACE)
    assert create is not None and rollback is not None
    assert create.text and rollback.text
    tenant = "00000000-0000-0000-0000-000000000001"
    try:
        sql(f"""
            CREATE SCHEMA {SCHEMA};
            CREATE TABLE {SCHEMA}.leave_request (
                id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
                applied_at timestamptz NOT NULL, is_deleted boolean NOT NULL,
                from_date date NOT NULL, to_date date NOT NULL, reason text
            );
            INSERT INTO {SCHEMA}.leave_request
            SELECT md5(n::text)::uuid, '{tenant}'::uuid,
                '2026-09-10'::timestamptz - n * interval '1 second',
                n % 10 = 0, '2026-09-01'::date, '2026-09-03'::date, repeat('x', 100)
            FROM generate_series(1, 50000) n;
            ANALYZE {SCHEMA}.leave_request;
        """)
        query = f"""
            EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
            SELECT * FROM {SCHEMA}.leave_request
            WHERE tenant_id = '{tenant}' AND is_deleted = FALSE
                AND to_date >= '2026-01-01' AND from_date <= '2026-12-31'
                AND (applied_at, id) < ('2026-09-09 23:00:00+00'::timestamptz,
                    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
            ORDER BY applied_at DESC, id DESC LIMIT 200;
        """
        before = json.loads(sql(query))[0]
        if args.liquibase:
            run_migration(["update"])
        else:
            sql(create.text.replace("${schema}", SCHEMA))
        after = json.loads(sql(query))[0]
        plan_nodes = list(nodes(after["Plan"]))
        assert any(node.get("Index Name") == "idx_leave_request_queue_order" for node in plan_nodes)
        assert any("applied_at" in node.get("Index Cond", "") and "id" in node.get("Index Cond", "")
                   for node in plan_nodes), "Cursor must seek the index, not filter all earlier rows"
        assert not any(node["Node Type"] == "Sort" for node in plan_nodes)
        assert after["Plan"]["Actual Rows"] == 200
        valid = sql(f"""SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='{SCHEMA}' AND c.relname='idx_leave_request_queue_order'""")
        assert valid == "t"
        if args.liquibase:
            run_migration(["rollback-count", "--count=1"])
        else:
            sql(rollback.text.replace("${schema}", SCHEMA))
        assert sql(f"SELECT to_regclass('{SCHEMA}.idx_leave_request_queue_order') IS NULL") == "t"
        print(json.dumps({
            "rows_seeded": 50000, "page_rows": 200,
            "before_execution_ms": before["Execution Time"],
            "after_execution_ms": after["Execution Time"],
            "index_used": True, "sort_removed": True, "rollback_verified": True,
            "liquibase_runner": args.liquibase,
            "before_plan": before, "after_plan": after,
        }, indent=2))
    finally:
        # Only the unique schema created above is removed, never an existing tenant schema.
        sql(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE;")


if __name__ == "__main__":
    main()
