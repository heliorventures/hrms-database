"""Operator-only raw XLSX -> versioned import JSON. Does not access a database."""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

# Direct CLI execution must resolve the owned repository packages from any cwd.
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts.reusable.imports.normalize import ConversionOptions
from scripts.reusable.imports.private_output import create_private_directory, write_private_json
from scripts.tenant_specific.solvian.imports.solvian_profile import convert_solvian
from scripts.reusable.imports.workbook_xml import read_workbook


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--input", required=True, type=Path, help="One exact XLSX path; no glob expansion")
    result.add_argument("--profile", required=True, choices=("SCL", "SBL"))
    result.add_argument("--tenant-code", required=True, help="Reviewed tenant code, not inferred from the source")
    result.add_argument("--salary-effective-from", required=True, help="Explicit YYYY-MM-DD assignment date or JOINING_DATE for each employee's source joining date")
    result.add_argument("--leave-as-of", required=True, help="Explicit YYYY-MM-DD leave snapshot date")
    result.add_argument("--september-blank-formula-inputs-as-zero", action="store_true",
                        help="Reviewed September-only policy: blank numeric salary-formula inputs are zero, with provenance logs")
    result.add_argument("--employee-code-map", type=Path,
                        help="Reviewed JSON {source_hash, employee_codes: {Sheet1:row: code}}")
    result.add_argument("--output-dir", required=True, type=Path,
                        help="New private directory under an existing parent; must not already exist")
    return result


def _code_map(path, workbook):
    if path is None:
        return {}
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Employee code mapping exceeds the supported size")
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("The reviewed mapping contains duplicate JSON keys")
            result[key] = value
        return result

    with path.open(encoding="utf-8-sig") as source:
        mapping = json.load(source, object_pairs_hook=unique_object)
    if not isinstance(mapping, dict) or set(mapping) != {"source_hash", "employee_codes"}:
        raise ValueError("Code mapping must contain source_hash and employee_codes only")
    if mapping["source_hash"] != workbook.file_hash:
        raise ValueError("Code mapping fingerprint does not match the selected workbook")
    return mapping["employee_codes"]


def issue_report(package):
    counts = Counter(issue["severity"] for issue in package["issues"])
    return {"format": "hrms-tenant-import-conversion-report", "version": 1,
            "source": package["source"], "employee_count": len(package["employees"]),
            "issue_counts": dict(sorted(counts.items())),
            "section_counts": {
                "recurring_salary_present": sum(e["recurring_salary"] is not None for e in package["employees"]),
                "bank_present": sum(e["bank"] is not None for e in package["employees"]),
                "leave_opening_ready": sum(e["leave_opening"]["ready"] for e in package["employees"]),
                "period_inputs_ready": sum(e["period_input"]["ready"] for e in package["employees"])},
            "issues": package["issues"], "database_writes": False, "import_performed": False}


def main(argv=None):
    args = parser().parse_args(argv)
    stage = "READ_SOURCE"
    try:
        workbook = read_workbook(args.input)
        stage = "VALIDATE_OPERATOR_INPUTS"
        options = ConversionOptions(args.tenant_code, args.salary_effective_from, args.leave_as_of,
                                    _code_map(args.employee_code_map, workbook),
                                    args.september_blank_formula_inputs_as_zero)
        stage = "CONVERT_SOURCE"
        package = convert_solvian(workbook, args.profile, options)
        report = issue_report(package)
        stage = "PROTECT_OUTPUT_DIRECTORY"
        directory = create_private_directory(args.output_dir)
        stage = "WRITE_PRIVATE_PACKAGE"
        write_private_json(directory, "tenant-import.json", package)
        write_private_json(directory, "conversion-report.json", report)
        print(json.dumps({"employee_count": report["employee_count"], "issue_counts": report["issue_counts"],
                          "source_hash": workbook.file_hash, "files_written": 2, "database_writes": False}))
        # Success means conversion completed; row/section issues stay in the report.
        return 0
    except (ValueError, OSError, subprocess.SubprocessError):
        # Exceptions can include source values, filenames or subprocess output. Keep ordinary logs safe.
        print(json.dumps({"status": "FAILED", "stage": stage, "database_writes": False,
                          "message": "Check the exact workbook/profile, operator dates, reviewed code map, and a new private output directory. No database was accessed."}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
