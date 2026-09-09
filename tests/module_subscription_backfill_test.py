"""Execute the migration INSERT unchanged in SQLite; no configured database access.

This verifies row selection/idempotency, not PostgreSQL or Liquibase integration.
"""
import sqlite3
import unittest
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = "migrations/0083_missing_module_subscriptions/missing_module_subscriptions.xml"
NS = {"lb": "http://www.liquibase.org/xml/ns/dbchangelog"}


class SubscriptionBackfillTests(unittest.TestCase):
    def test_ops_only_and_preserves_existing_rows_on_repeated_runs(self):
        master = ET.parse(ROOT / "changelog/db.changelog-master.xml")
        self.assertIn(MIGRATION, [node.get("file") for node in master.findall("lb:include", NS)])
        tenant = ET.parse(ROOT / "changelog/tenant.changelog-master.xml")
        self.assertNotIn(MIGRATION, [node.get("file") for node in tenant.findall("lb:include", NS)])
        migration = ET.parse(ROOT / "changelog" / MIGRATION)
        sql = migration.find("lb:changeSet/lb:sql", NS).text
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.create_function("gen_random_uuid", 0, lambda: str(uuid.uuid4()))
        db.executescript("""
            ATTACH DATABASE ':memory:' AS kabipay_ops;
            CREATE TABLE kabipay_ops.tenant (id TEXT PRIMARY KEY, is_deleted BOOLEAN, status TEXT);
            CREATE TABLE kabipay_ops.module (id TEXT PRIMARY KEY, is_active BOOLEAN, is_core BOOLEAN);
            CREATE TABLE kabipay_ops.tenant_subscription (
                id TEXT PRIMARY KEY, tenant_id TEXT, module_id TEXT, status TEXT,
                activated_at TEXT, expires_at TEXT, is_deleted BOOLEAN DEFAULT false,
                contracted_seats INTEGER DEFAULT 0, current_seat_usage INTEGER DEFAULT 0,
                overage_policy TEXT DEFAULT 'BLOCK',
                UNIQUE (tenant_id, module_id)
            );
            INSERT INTO kabipay_ops.tenant VALUES
                ('a', false, 'ACTIVE'), ('b', false, 'ACTIVE'),
                ('suspended', false, 'SUSPENDED'), ('deleted', true, 'ACTIVE');
            INSERT INTO kabipay_ops.module VALUES
                ('expense', true, false), ('tax', true, false),
                ('recruitment', true, false), ('core', true, true), ('inactive', false, false);
            INSERT INTO kabipay_ops.tenant_subscription VALUES
                ('existing-active', 'a', 'expense', 'ACTIVE', '2020-01-01', NULL, false, 42, 3, 'NOTIFY'),
                ('existing-expired', 'a', 'tax', 'EXPIRED', '2020-01-01', '2021-01-01', false, 50, 2, 'BLOCK'),
                ('existing-deleted', 'b', 'recruitment', 'CANCELLED', NULL, NULL, true, 10, 0, 'BLOCK'),
                ('existing-future', 'b', 'tax', 'PENDING', '2099-01-01', NULL, false, 20, 0, 'BLOCK'),
                ('existing-suspended', 'b', 'expense', 'SUSPENDED', NULL, NULL, false, 20, 0, 'BLOCK');
        """)
        before = db.execute("SELECT * FROM kabipay_ops.tenant_subscription ORDER BY id").fetchall()
        db.executescript(sql)
        after = db.execute("SELECT * FROM kabipay_ops.tenant_subscription ORDER BY id").fetchall()
        self.assertEqual(len(after), 12)  # Three non-deleted tenants, four active modules.
        self.assertTrue(all(row in after for row in before))
        inserted = [row for row in after if row not in before]
        self.assertTrue(all(row[3:6] == ('ACTIVE', None, None) for row in inserted))
        self.assertTrue(all(row[6:] == (0, 0, 0, 'BLOCK') for row in inserted))
        self.assertFalse(any(row[1] == 'deleted' or row[2] == 'inactive' for row in after))
        self.assertEqual(db.execute("SELECT status FROM kabipay_ops.tenant WHERE id='suspended'").fetchone()[0], 'SUSPENDED')
        db.executescript(sql)
        self.assertEqual(after, db.execute("SELECT * FROM kabipay_ops.tenant_subscription ORDER BY id").fetchall())


if __name__ == "__main__":
    unittest.main()
