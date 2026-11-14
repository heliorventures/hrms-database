import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1]))
spec = importlib.util.spec_from_file_location("runtime_grants_protected_runner", Path(__file__).parents[1] / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0, "Linux root operator file semantics")
class ProtectedFilesTests(unittest.TestCase):
    def test_durable_private_plan_is_readable_and_never_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            parent.chmod(0o700)
            target = parent / "plan.json"
            runner.protected_write(target, {"approved": True})
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(runner.protected_read(target), {"approved": True})
            with self.assertRaises(FileExistsError):
                runner.protected_write(target, {"approved": False})
            self.assertEqual(runner.protected_read(target), {"approved": True})

    def test_symlink_or_insecure_file_and_parent_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            parent.chmod(0o700)
            target = parent / "plan.json"
            runner.protected_write(target, {})
            link = parent / "linked.json"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                runner.protected_read(link)
            target.chmod(0o644)
            with self.assertRaises(ValueError):
                runner.protected_read(target)
            target.chmod(0o600)
            parent.chmod(0o755)
            with self.assertRaises(ValueError):
                runner.protected_read(target)
            with self.assertRaises(ValueError):
                runner.protected_write(parent / "another.json", {})

    def test_file_lock_rejects_concurrent_operator_then_releases(self):
        with tempfile.TemporaryDirectory() as folder:
            lock = str(Path(folder) / "operator.lock")
            original_open = os.open
            def open_fixture(path, flags, mode=0o777):
                self.assertEqual(path, "/run/lock/hrms-runtime-grants.lock")
                return original_open(lock, flags, mode)
            with mock.patch.object(runner.os, "open", side_effect=open_fixture):
                with runner.operator_lock():
                    with self.assertRaises(BlockingIOError):
                        with runner.operator_lock():
                            self.fail("Second operator acquired an exclusive lock")
                with runner.operator_lock():
                    pass


if __name__ == "__main__":
    unittest.main()
