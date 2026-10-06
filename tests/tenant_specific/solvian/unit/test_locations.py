"""Location mapping uses synthetic rows, never client workbooks or a database."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import json
from types import SimpleNamespace

from test_converter import employee_cells, write_workbook
from scripts.reusable.imports.normalize import ConversionOptions
from scripts.reusable.imports.workbook_xml import read_workbook
from scripts.tenant_specific.solvian.imports.solvian_profile import convert_solvian
from scripts.reusable.imports.location_mapping import load_location_map


class LocationConversionTests(unittest.TestCase):
    def convert(self, profile, mapping):
        with TemporaryDirectory() as directory:
            header = 7 if profile == "SCL" else 6
            path = Path(directory) / "synthetic.xlsx"
            write_workbook(path, {header: {"F": "Name"}, header + 1: employee_cells(profile)})
            options = ConversionOptions("synthetic", "2026-09-01", "2026-09-30", employee_locations=mapping)
            return convert_solvian(read_workbook(path), profile, options)

    def test_reviewed_location_is_carried_to_both_profiles(self):
        for profile, row in [("SCL", 8), ("SBL", 7)]:
            value = {"name": "Pune Office", "effective_from": "2026-10-07"}
            package = self.convert(profile, {f"Sheet1:{row}": value})
            self.assertEqual(package["employees"][0].get("location"), value)

    def test_unmapped_location_is_explicitly_deferred(self):
        package = self.convert("SCL", {})
        self.assertIsNone(package["employees"][0].get("location"))
        self.assertTrue(any(i["code"] == "LOCATION_NOT_SUPPLIED" for i in package["issues"]))

    def test_unused_mapping_blocks_import_instead_of_silently_dropping_location(self):
        package = self.convert("SCL", {"Sheet1:99": {"name": "Pune", "effective_from": "2026-10-07"}})
        self.assertTrue(any(i["code"] == "UNUSED_LOCATION_MAPPING" and i["severity"] == "BLOCK_TENANT"
                            for i in package["issues"]))

    def test_mapping_rejects_wrong_workbook_or_tenant(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "locations.json"
            for source_hash, tenant in [("wrong", "synthetic"), ("hash", "foreign")]:
                path.write_text(json.dumps({"source_hash": source_hash, "tenant_code": tenant,
                                            "locations": {}}), encoding="utf-8")
                with self.assertRaises(ValueError):
                    load_location_map(path, SimpleNamespace(file_hash="hash"), "synthetic")

    def test_mapping_rejects_duplicate_json_keys(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "locations.json"
            path.write_text('{"source_hash":"hash","tenant_code":"synthetic","locations":{},"locations":{}}', encoding="utf-8")
            with self.assertRaises(ValueError):
                load_location_map(path, SimpleNamespace(file_hash="hash"), "synthetic")

    def test_invalid_location_values_are_rejected(self):
        for value in [{"name": "Pune"}, {"name": " ", "effective_from": "2026-10-07"},
                      {"name": "Pune", "effective_from": "2026-02-30"},
                      {"name": "Pune\nOffice", "effective_from": "2026-10-07"}]:
            with self.assertRaises(ValueError):
                ConversionOptions("synthetic", "2026-09-01", "2026-09-30",
                                  employee_locations={"Sheet1:8": value})

    def test_valid_mapping_is_read_and_location_names_are_normalized(self):
        value = {"name": " Pune   Office ", "effective_from": "2026-10-07"}
        with TemporaryDirectory() as directory:
            path = Path(directory) / "locations.json"
            path.write_text(json.dumps({"source_hash": "hash", "tenant_code": "synthetic",
                                        "locations": {"Sheet1:8": value}}), encoding="utf-8")
            mapping = load_location_map(path, SimpleNamespace(file_hash="hash"), "synthetic")
            self.assertEqual(self.convert("SCL", mapping)["employees"][0]["location"]["name"], "Pune Office")
