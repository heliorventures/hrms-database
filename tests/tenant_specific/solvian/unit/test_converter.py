"""Synthetic converter acceptance cases. No client data or database access."""
from __future__ import annotations

import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from xml.sax.saxutils import escape
from zipfile import ZipFile


sys.path.insert(0, str(Path(__file__).resolve().parents[4]))
_missing_converter = None
try:
    from scripts.reusable.imports.normalize import ConversionOptions, source_value  # noqa: E402
    from scripts.tenant_specific.solvian.imports.solvian_profile import convert_solvian  # noqa: E402
    from scripts.reusable.imports.workbook_xml import read_workbook  # noqa: E402
except ModuleNotFoundError as error:
    if error.name not in {"normalize", "solvian_profile", "workbook_xml"}:
        raise
    _missing_converter = error.name


def write_workbook(path, rows, *, date1904=False):
    """Create a tiny standards-based XLSX fixture with cached formula values."""
    ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    records = []
    for row, cells in sorted(rows.items()):
        items = []
        for column, value in cells.items():
            ref = f"{column}{row}"
            if isinstance(value, tuple):
                formula, cached = value[:2]
                attributes = value[2] if len(value) == 3 else ""
                items.append(f'<c r="{ref}"><f{attributes}>{escape(formula)}</f>'
                             f'<v>{escape(str(cached))}</v></c>')
            elif isinstance(value, (int, float)):
                items.append(f'<c r="{ref}"><v>{value}</v></c>')
            else:
                items.append(f'<c r="{ref}" t="inlineStr"><is>'
                             f'<t>{escape(str(value))}</t></is></c>')
        records.append(f'<row r="{row}">{"".join(items)}</row>')
    with ZipFile(path, "w") as archive:
        archive.writestr("xl/workbook.xml", f'<workbook xmlns="{ns}" '
                         'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                         f'<workbookPr date1904="{int(date1904)}"/>'
                         '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>')
        archive.writestr("xl/_rels/workbook.xml.rels", '<Relationships '
                         'xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                         '<Relationship Id="rId1" Target="worksheets/sheet1.xml" '
                         'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>'
                         '</Relationships>')
        archive.writestr("xl/worksheets/sheet1.xml", f'<worksheet xmlns="{ns}">'
                         f'<sheetData>{"".join(records)}</sheetData></worksheet>')


def employee_cells(profile):
    common = {"C": 1, "D": "TEST-001", "F": "Synthetic Employee",
              "AD": 0, "AE": 27000, "AF": 13500, "AG": 6750,
              "AH": 3375, "AI": 3375, "AJ": 20250, "AK": 15000,
              "AL": 1800, "AM": 1950, "AN": 27000, "AO": 0,
              "AP": 0, "AQ": 200, "AR": 0, "AS": 0, "AT": 0,
              "AU": 0, "AV": 2000, "AW": 0, "AX": 25000}
    if profile == "SCL":
        common.update({"G": "Engineer", "H": "Engineering", "I": "01.01.1990",
                       "J": "01.01.2020", "O": 4, "P": 6, "Q": 8, "R": 2,
                       "S": 30, "T": 27, "U": 0, "V": "NA", "W": "NA",
                       "X": "NA", "Y": "NA", "Z": 30000, "AA": 0,
                       "AB": 27, "AC": 0, "BG": "01.01.1990",
                       "BH": "Synthetic Employee", "BI": "001234567890",
                       "BJ": "SAVINGS", "BK": "Synthetic Bank", "BL": "Test Branch",
                       "BM": "TEST0001234"})
    else:
        common.update({"G": 123456789012, "H": "Engineer", "I": "Engineering",
                       "J": "01.01.1990", "K": "01.01.2020",
                       "P": 4, "Q": 6, "R": 8, "S": 2, "T": 30, "U": 27,
                       "V": 0, "W": "NA", "X": "NA", "Y": "NA", "Z": "NA",
                       "AA": 30000, "AB": 0, "AC": 27,
                       "BD": "01.01.1990", "BE": "Synthetic Employee",
                       "BF": "001234567890", "BG": "SAVINGS", "BH": "Synthetic Bank",
                       "BI": "Test Branch", "BJ": "TEST0001234"})
    return common


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNone(_missing_converter,
                          f"Converter feature is not implemented: {_missing_converter}")
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def convert(self, profile="SCL", changes=None, *, date1904=False, codes=None, formula_zeros=False):
        header = 7 if profile == "SCL" else 6
        cells = employee_cells(profile)
        cells.update(changes or {})
        path = Path(self.directory.name) / f"synthetic-{profile}.xlsx"
        rows = {header: {"C": "Sr.No.", "D": "Employee Code", "F": "Name"},
                header + 1: cells, header + 2: {"F": "Total", "AE": 27000},
                header + 3: {"F": "Prepared by Synthetic Reviewer"}}
        write_workbook(path, rows, date1904=date1904)
        options = ConversionOptions(tenant_code="synthetic-tenant",
                                    salary_effective_from="2026-09-01",
                                    leave_as_of="2026-09-30", employee_codes=codes or {},
                                    september_blank_formula_inputs_as_zero=formula_zeros)
        return convert_solvian(read_workbook(path), profile, options)

    def issue_codes(self, package):
        return {issue["code"] for issue in package["issues"]}

    def test_cached_decimal_noise_does_not_change_confirmed_ratios(self):
        package = self.convert(changes={"AF": "13499.999999999999"})
        self.assertEqual(package["employees"][0]["recurring_salary"]["component_ratios"],
                         {"BASIC": "0.5", "HRA": "0.25", "CONVEYANCE": "0.125", "OTHER": "0.125"})

    def test_september_formula_blank_policy_is_explicit_and_logged(self):
        changes = {"AA": "", "AO": "", "AP": "", "AR": "", "AS": "", "AT": "", "AW": "", "U": "",
                   "AD": ("Z8/31*U8", 0), "AE": 30000, "AF": 15000, "AG": 7500, "AH": 3750, "AI": 3750,
                   "AV": ("SUM(AL8,AO8,AQ8,AR8,AS8,AT8,AU8)", 2000), "AX": ("AE8-AV8+AW8", 28000)}
        package = self.convert(changes=changes, formula_zeros=True)
        period = package["employees"][0]["period_input"]
        self.assertTrue(period["ready"])
        self.assertEqual(period["statutory_overrides"]["TDS"], "0.00")
        self.assertEqual(period["lwp_days"], "0")
        self.assertIn("SOURCE_BLANK_FORMULA_INPUT_ZERO", self.issue_codes(package))
        self.assertEqual(package["employees"][0]["source_states"]["tds"], "BLANK")
        self.assertFalse(self.convert(changes=changes)["employees"][0]["period_input"]["ready"])
        self.assertFalse(self.convert(changes={**changes, "AT": "NA"}, formula_zeros=True)["employees"][0]["period_input"]["ready"])

    def test_explicit_joining_date_salary_policy(self):
        options = ConversionOptions(tenant_code="synthetic-tenant",
                                    salary_effective_from="JOINING_DATE", leave_as_of="2026-08-31")
        path = Path(self.directory.name) / "joining-date.xlsx"
        write_workbook(path, {7: {"F": "Name"}, 8: employee_cells("SCL")})
        package = convert_solvian(read_workbook(path), "SCL", options)
        self.assertEqual(package["salary_effective_policy"], "JOINING_DATE")
        self.assertIsNone(package["salary_effective_from"])
        self.assertEqual(package["employees"][0]["employee"]["joining_date"], "2020-01-01")
        self.assertEqual(package["leave_as_of"], "2026-08-31")

    def test_shared_numeric_formula_retains_relative_and_absolute_references(self):
        path = Path(self.directory.name) / "shared.xlsx"
        write_workbook(path, {8: {"AV": ("SUM(AL8+$AO8+AQ$8+$AS$8)", 2000,
                                        ' t="shared" si="0" ref="AV8:AV9"')},
                              9: {"AV": ("", 2000, ' t="shared" si="0"')}})
        book = read_workbook(path)
        self.assertEqual(book.sheets["Sheet1"].rows[9]["AV9"].formula,
                         "SUM(AL9+$AO9+AQ$8+$AS$8)")

    def test_both_layouts_exclude_totals_and_footer(self):
        for profile in ("SCL", "SBL"):
            with self.subTest(profile=profile):
                package = self.convert(profile)
                self.assertEqual(len(package["employees"]), 1)
                self.assertEqual(package["employees"][0]["employee"]["code"], "TEST-001")
                self.assertEqual(package["period"], {"year": 2026, "month": 9})
                self.assertEqual(package["format"], "hrms-tenant-import")
                self.assertEqual(package["version"], 1)

    def test_recurring_split_uses_fixed_gross_instead_of_reduced_earnings(self):
        for profile in ("SCL", "SBL"):
            with self.subTest(profile=profile):
                employee = self.convert(profile)["employees"][0]
                salary = employee["recurring_salary"]
                self.assertEqual(salary["monthly_gross"], "30000.00")
                self.assertEqual(salary["annual_gross"], "360000.00")
                self.assertEqual(salary["components"], {"BASIC": "15000.00", "HRA": "7500.00",
                                                       "CONVEYANCE": "3750.00", "OTHER": "3750.00"})
                self.assertEqual(employee["period_input"]["expected_earned_components"],
                                 {"BASIC": "13500.00", "HRA": "6750.00",
                                  "CONVEYANCE": "3375.00", "OTHER": "3375.00"})

    def test_source_states_do_not_collapse_blank_na_zero_or_missing(self):
        for raw, present, expected in (("", True, "BLANK"), ("NA", True, "NA"),
                                       ("0", True, "VALUE"), (None, False, "MISSING")):
            with self.subTest(expected=expected):
                self.assertEqual(source_value(raw, present=present)["state"], expected)

    def test_text_and_excel_serial_dates(self):
        employee = self.convert(changes={"J": 43831})["employees"][0]["employee"]
        self.assertEqual(employee["joining_date"], "2020-01-01")
        self.assertEqual(employee["birth_date"], "1990-01-01")

    def test_1904_epoch_is_respected(self):
        employee = self.convert(changes={"J": 42369}, date1904=True)["employees"][0]["employee"]
        self.assertEqual(employee["joining_date"], "2020-01-01")

    def test_numeric_identifiers_and_string_leading_zeroes(self):
        employee = self.convert("SBL")["employees"][0]
        self.assertEqual(employee["employee"]["uan"], "123456789012")
        self.assertEqual(employee["bank"]["account_number"], "001234567890")

    def test_only_aadhaar_last_four_enters_package(self):
        package = self.convert(changes={"BF": "123456789012"})
        self.assertEqual(package["employees"][0]["identity"]["aadhaar_last_four"], "9012")
        self.assertNotIn("123456789012", json.dumps(package))

    def test_missing_bank_defers_bank_without_blocking_employee_or_salary(self):
        package = self.convert(changes={"BI": "", "BM": ""})
        self.assertIsNone(package["employees"][0]["bank"])
        self.assertIsNotNone(package["employees"][0]["recurring_salary"])
        self.assertTrue(any(i["section"] == "bank" and i["severity"] == "DEFER_SECTION"
                            for i in package["issues"]))
        self.assertFalse(any(i["severity"] == "BLOCK_EMPLOYEE" for i in package["issues"]))

    def test_conflicting_optional_birth_dates_are_omitted_and_reported(self):
        package = self.convert(changes={"BG": "02.01.1990"})
        self.assertIsNone(package["employees"][0]["employee"].get("birth_date"))
        self.assertIn("DOB_CONFLICT", self.issue_codes(package))

    def test_missing_code_is_blocking_and_never_fabricated(self):
        package = self.convert(changes={"D": ""})
        self.assertIsNone(package["employees"][0]["employee"].get("code"))
        self.assertTrue(any(i["field"] == "code" and i["severity"] == "BLOCK_EMPLOYEE"
                            for i in package["issues"]))

    def test_reviewed_code_mapping_resolves_missing_code(self):
        package = self.convert(changes={"D": ""}, codes={"Sheet1:8": "REVIEWED-001"})
        self.assertEqual(package["employees"][0]["employee"]["code"], "REVIEWED-001")
        self.assertFalse(any(i["field"] == "code" and i["severity"] == "BLOCK_EMPLOYEE"
                             for i in package["issues"]))

    def test_invalid_joining_date_blocks_core_only(self):
        package = self.convert(changes={"J": "unknown"})
        self.assertTrue(any(i["field"] == "joining_date" and i["severity"] == "BLOCK_EMPLOYEE"
                            for i in package["issues"]))
        self.assertIsNotNone(package["employees"][0]["recurring_salary"])

    def test_leave_snapshot_never_infers_september_payroll_lwp(self):
        employee = self.convert(changes={"Q": 12, "R": -2})["employees"][0]
        self.assertEqual(employee["leave_opening"]["carry_forward"], "4")
        self.assertEqual(employee["leave_opening"]["grant"], "6")
        self.assertEqual(employee["historical_lwp"]["days"], "2")
        self.assertEqual(employee["period_input"]["lwp_days"], "0")

    def test_negative_taken_is_reviewed_without_sign_inversion(self):
        package = self.convert(changes={"Q": -2, "R": -2})
        self.assertIn("LEAVE_RECONCILIATION_REQUIRED", self.issue_codes(package))
        self.assertIsNone(package["employees"][0]["historical_lwp"])

    def test_unknown_leave_grant_is_not_zero_or_negative_balance(self):
        package = self.convert(changes={"P": "NA", "Q": "", "R": ""})
        self.assertIsNone(package["employees"][0]["leave_opening"]["grant"])
        self.assertIn("LEAVE_RECONCILIATION_REQUIRED", self.issue_codes(package))

    def test_sbl_paid_days_are_not_lwp_days(self):
        employee = self.convert("SBL", {"AC": 27, "V": 0})["employees"][0]
        self.assertEqual(employee["period_input"]["paid_days"], "27")
        self.assertEqual(employee["period_input"]["lwp_days"], "0")

    def test_additional_deduction_without_reason_defers_period_only(self):
        package = self.convert("SBL", {"AU": 100, "AV": 2100, "AX": 24900})
        self.assertTrue(any(i["code"] == "DEDUCTION_REASON_REQUIRED" and
                            i["severity"] == "DEFER_SECTION" and i["section"] == "period_input"
                            for i in package["issues"]))
        deduction = package["employees"][0]["period_input"]["additional_deductions"][0]
        self.assertEqual(deduction["amount"], "100.00")
        self.assertIsNone(deduction["reason"])

    def test_advances_and_incentives_are_period_values_only(self):
        employee = self.convert(changes={"AS": 5000, "AW": 500, "AV": 7000,
                                        "AX": 20500})["employees"][0]
        period = employee["period_input"]
        self.assertEqual(period["advance_already_paid"], "5000.00")
        self.assertEqual(period["incentive"], "500.00")
        self.assertEqual(period["expected_statement"]["net_earned"], "25500.00")
        self.assertEqual(period["expected_statement"]["remaining_payable"], "20500.00")
        self.assertEqual(employee["recurring_salary"]["annual_gross"], "360000.00")

    def test_cached_formula_carries_provenance_without_execution(self):
        package = self.convert(changes={"AE": ("Z8/S8*AB8+AA8", 27000)})
        source = package["employees"][0]["source_ref"]
        self.assertEqual(source["cells"]["earned_gross"], "AE8")
        self.assertEqual(len(source["file_hash"]), 64)
        self.assertEqual(package["employees"][0]["period_input"]["gross_rule"], "PAID_DAYS_PLUS_OT")

    def test_unrecognized_formula_is_preserved_as_reviewed_monthly_override(self):
        package = self.convert(changes={"AE": ("HYPERLINK(\"https://invalid.example\")", 27000)})
        self.assertEqual(package["employees"][0]["period_input"]["gross_rule"], "SOURCE_OVERRIDE")
        self.assertIn("SOURCE_GROSS_OVERRIDE", self.issue_codes(package))

    def test_formula_without_cache_defers_salary_not_silent_zero(self):
        package = self.convert(changes={"AE": ("Z8/S8*AB8", "")})
        self.assertIsNone(package["employees"][0]["recurring_salary"])
        self.assertTrue(any(i["severity"] == "DEFER_SECTION" and i["section"] == "recurring_salary"
                            for i in package["issues"]))

    def test_optional_source_blanks_never_request_explicit_clears(self):
        employee = self.convert(changes={"I": "", "BG": ""})["employees"][0]
        self.assertEqual(employee["clear_fields"], [])

    def test_required_operator_dates_have_no_defaults(self):
        with self.assertRaises((TypeError, ValueError)):
            ConversionOptions(tenant_code="synthetic-tenant")

    def test_invalid_profile_is_rejected(self):
        with self.assertRaises(ValueError):
            self.convert("UNKNOWN")


if __name__ == "__main__":
    unittest.main()
