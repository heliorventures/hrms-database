"""Storage contracts against a disposable loopback PostgreSQL cluster, never .env."""
from pathlib import Path
import os
import socket
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from uuid import UUID

ROOT = Path(__file__).resolve().parents[3]
MIGRATIONS = (
    "0090_payroll_period_configuration/payroll_period_configuration.xml",
    "0091_leave_import_history/leave_import_history.xml",
    "0092_tenant_import_tracking/tenant_import_tracking.xml",
)
NS = {"db": "http://www.liquibase.org/xml/ns/dbchangelog"}


class ImportStorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for name in MIGRATIONS:
            assert (ROOT / "changelog/migrations" / name).is_file(), "import storage migration is not implemented"
        cls.bin = Path(os.environ.get("PG_TEST_BIN", r"C:\Program Files\PostgreSQL\17\bin"))
        cls.directory = Path(tempfile.mkdtemp(prefix="hrms-import-storage-"))
        cls.data = cls.directory / "pgdata"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]
        cls.run_tool("initdb", ["-D", str(cls.data), "-U", "postgres", "-A", "trust", "-N", "--no-locale", "-E", "UTF8"])
        cls.run_tool("pg_ctl", ["-D", str(cls.data), "-l", str(cls.directory / "postgres.log"), "-o", f"-h 127.0.0.1 -p {cls.port}", "-w", "start"])
        cls.addClassCleanup(cls.run_tool, "pg_ctl", ["-D", str(cls.data), "-m", "fast", "-w", "stop"])
        cls.sql('''CREATE SCHEMA fixture;
            CREATE TABLE fixture."user"(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
            CREATE TABLE fixture.employee(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
            CREATE TABLE fixture.employee_bank(id UUID PRIMARY KEY);
            CREATE TABLE fixture.employee_salary_structure(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
            CREATE TABLE fixture.salary_component(id UUID PRIMARY KEY,tenant_id UUID NOT NULL,type TEXT NOT NULL);
            CREATE TABLE fixture.payslip(id UUID PRIMARY KEY,tenant_id UUID NOT NULL,UNIQUE(tenant_id,id));
            CREATE TABLE fixture.leave_type(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
            CREATE TABLE fixture.leave_balance(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);
            INSERT INTO fixture."user" VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010');
            INSERT INTO fixture.employee VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000010');
            INSERT INTO fixture.leave_type VALUES ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000010');
            INSERT INTO fixture.salary_component VALUES(gen_random_uuid(),'00000000-0000-0000-0000-000000000010','EMPLOYER_CONTRIBUTION');
        ''')
        for name in MIGRATIONS:
            tree = ET.parse(ROOT / "changelog/migrations" / name)
            for element in tree.findall(".//db:sql", NS):
                cls.sql((element.text or "").replace("${schema}", "fixture"))

    @classmethod
    def run_tool(cls, name, args):
        with (cls.directory / f"{name}.log").open("a", encoding="utf-8") as log:
            result = subprocess.run([str(cls.bin / f"{name}.exe"), *args], stdin=subprocess.DEVNULL, stdout=log, stderr=log, timeout=60)
        if result.returncode:
            raise AssertionError(f"disposable {name} failed; logs retained in {cls.directory}")

    @classmethod
    def sql(cls, sql, fails=False, sqlstate=None):
        result = subprocess.run([str(cls.bin / "psql.exe"), "-h", "127.0.0.1", "-p", str(cls.port), "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-At"],
                                input="\\set VERBOSITY verbose\n" + sql, text=True, capture_output=True, timeout=30)
        if fails:
            if not result.returncode:
                raise AssertionError("invalid storage write was accepted")
            if sqlstate and sqlstate not in result.stderr:
                raise AssertionError(f"expected SQLSTATE {sqlstate}; {result.stderr}")
        elif result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def test_default_company_component_visibility_hides_employer_cost(self):
        self.assertEqual(self.sql("SELECT show_on_payslip FROM fixture.salary_component WHERE type='EMPLOYER_CONTRIBUTION'"), "f")
        # Earning catalogs keep a compatible default; employer components explicitly opt out.
        self.assertEqual(self.sql("SELECT column_default FROM information_schema.columns WHERE table_schema='fixture' AND table_name='salary_component' AND column_name='show_on_payslip'"), "true")

    def test_period_identity_is_unique_and_tenant_bound(self):
        values = "'00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000002',2026,9,'{}','00000000-0000-0000-0000-000000000001'"
        self.sql(f"INSERT INTO fixture.payroll_period_input(tenant_id,employee_id,year,month,input,updated_by) VALUES({values})")
        self.sql(f"INSERT INTO fixture.payroll_period_input(tenant_id,employee_id,year,month,input,updated_by) VALUES({values})", fails=True)
        self.sql("INSERT INTO fixture.payroll_period_input(tenant_id,employee_id,year,month,input,updated_by) VALUES('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000002',2026,10,'{}','00000000-0000-0000-0000-000000000001')", fails=True)

    def test_missing_reason_can_be_staged_but_cannot_be_ready(self):
        self.sql("INSERT INTO fixture.payroll_period_adjustment(tenant_id,employee_id,year,month,code,amount,reason,ready,updated_by) VALUES('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000002',2026,9,'OTHER',100,NULL,false,'00000000-0000-0000-0000-000000000001')")
        self.sql("UPDATE fixture.payroll_period_adjustment SET ready=true", fails=True)

    def test_historical_lwp_requires_nonnegative_usage(self):
        tenant, employee, leave_type, actor = (str(UUID(int=value)) for value in (16, 2, 3, 1))
        self.sql(f"INSERT INTO fixture.leave_import_history(tenant_id,employee_id,leave_type_id,year,as_of,opening,historical_lwp,updated_by) VALUES('{tenant}','{employee}','{leave_type}',2026,'2026-09-30','{{}}',-1,'{actor}')", fails=True, sqlstate="23514")

    def test_tracking_survives_employee_deletion(self):
        constraints = self.sql("SELECT COUNT(*) FROM pg_constraint WHERE conrelid='fixture.tenant_import_record'::regclass AND confrelid='fixture.employee'::regclass")
        self.assertEqual(constraints, "0")


if __name__ == "__main__":
    unittest.main()
