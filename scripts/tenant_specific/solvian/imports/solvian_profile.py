"""Convert a selected reviewed Solvian workbook layout into the version-1 contract."""
from __future__ import annotations

import re
from scripts.reusable.imports.normalize import ConversionOptions, identifier, parse_date
from scripts.tenant_specific.solvian.imports.solvian_layout import COMMON, SBL, SCL, SourceRow
from scripts.tenant_specific.solvian.imports.solvian_period import period_input
from scripts.tenant_specific.solvian.imports.solvian_salary_leave import leave_snapshot, recurring_salary


def _identifier(row, field, section, pattern=None):
    cell = row.cell(field)
    value = identifier(row.raw(field), numeric=cell is not None and cell.kind == "n")
    if value is not None:
        value = value.replace(" ", "").upper() if field in {"pan", "aadhaar", "uan", "ifsc"} else value
    if value is None or (pattern and not re.fullmatch(pattern, value)):
        code = "OPTIONAL_IDENTIFIER_MISSING" if row.text(field) is None else "IDENTIFIER_INVALID"
        row.issue(code, "WARNING" if section != "bank" else "DEFER_SECTION", section, field,
                  "An identifier is absent or cannot be imported accurately; preserve existing data and request client confirmation.")
        return None
    return value


def _date(row, field, *, required=False):
    value = parse_date(row.raw(field), date1904=row.workbook.date1904)
    if value is None and (required or row.text(field) is not None):
        row.issue("REQUIRED_DATE_INVALID" if required else "OPTIONAL_DATE_INVALID",
                  "BLOCK_EMPLOYEE" if required else "WARNING", "employee", field,
                  "A source date is missing or unsupported; confirm the date without substituting another field.")
    return value


def _employee(row, options, used_code_keys):
    code_cell = row.cell("code")
    code = identifier(row.raw("code"), numeric=code_cell is not None and code_cell.kind == "n")
    mapping_key = f"{row.sheet.name}:{row.row}"
    mapped = options.employee_codes.get(mapping_key)
    if mapped is not None:
        used_code_keys.add(mapping_key)
        if code is not None and code != mapped.strip():
            row.issue("CODE_MAPPING_CONFLICT", "BLOCK_EMPLOYEE", "employee", "code",
                      "Reviewed code mapping conflicts with the source code; resolve identity before import.")
        else:
            code = mapped.strip()
    if code is None:
        row.issue("EMPLOYEE_CODE_REQUIRED", "BLOCK_EMPLOYEE", "employee", "code",
                  "Employee code is missing; supply a reviewed source-row mapping. A code will not be fabricated.")
    name = row.text("name")
    if name is None:
        row.issue("EMPLOYEE_NAME_REQUIRED", "BLOCK_EMPLOYEE", "employee", "name",
                  "Employee name is missing; confirm core identity before importing this employee.")
    parts = (name or "").split(maxsplit=1)
    first_name = parts[0] if parts else None
    last_name = parts[1] if len(parts) > 1 else None
    joining = _date(row, "joining_date", required=True)
    birth = _date(row, "birth_date")
    repeated_birth = parse_date(row.raw("repeated_birth_date"), date1904=row.workbook.date1904)
    if birth is not None and repeated_birth is not None and birth != repeated_birth:
        birth = None
        row.issue("DOB_CONFLICT", "WARNING", "employee", "birth_date",
                  "The two source birth dates disagree; omit this optional field until corrected.")
    elif row.text("repeated_birth_date") is not None and repeated_birth is None:
        birth = None
        row.issue("DOB_CONFLICT", "WARNING", "employee", "repeated_birth_date",
                  "The repeated birth date is invalid; confirm source precedence before importing this optional field.")
    elif birth is None and row.text("birth_date") is None:
        birth = repeated_birth
    if birth is None and row.text("birth_date") is None and row.text("repeated_birth_date") is None:
        row.issue("OPTIONAL_DATE_MISSING", "WARNING", "employee", "birth_date",
                  "Birth date is not supplied; preserve any existing value and record this field for client follow-up.")
    if birth is not None and joining is not None and birth >= joining:
        birth = None
        row.issue("DOB_CHRONOLOGY_INVALID", "WARNING", "employee", "birth_date",
                  "Birth date is on or after joining; omit the optional birth date pending correction.")
    confirmation = _date(row, "confirmation_date")
    if confirmation is not None and joining is not None and confirmation < joining:
        confirmation = None
        row.issue("CONFIRMATION_DATE_INVALID", "WARNING", "employee", "confirmation_date",
                  "Confirmation precedes joining; omit this optional date pending correction.")
    repeated_name = row.text("repeated_name")
    if repeated_name is not None and name is not None and " ".join(repeated_name.split()).casefold() != " ".join(name.split()).casefold():
        row.issue("NAME_COLUMNS_CONFLICT", "BLOCK_EMPLOYEE", "employee", "name",
                  "Source name columns disagree; confirm employee identity before import.")
    gender = row.text("gender")
    if gender is not None:
        gender = {"M": "MALE", "MALE": "MALE", "F": "FEMALE", "FEMALE": "FEMALE", "OTHER": "OTHER"}.get(gender.upper())
        if gender is None:
            row.issue("GENDER_VALUE_UNSUPPORTED", "WARNING", "employee", "gender",
                      "Source gender is unsupported; preserve existing data and request clarification.")
    return {"code": code, "mapping_key": mapping_key, "name": name, "first_name": first_name,
            "last_name": last_name, "joining_date": joining, "birth_date": birth,
            "confirmation_date": confirmation, "exit_date": _date(row, "exit_date"),
            "last_working_date": _date(row, "last_working_date"), "gender": gender,
            "designation": row.text("designation"), "department": row.text("department"),
            "uan": _identifier(row, "uan", "employee", r"\d{12}")}


def _identity(row):
    pan = _identifier(row, "pan", "identity", r"[A-Z]{5}\d{4}[A-Z]")
    aadhaar = _identifier(row, "aadhaar", "identity", r"\d{12}")
    return {"pan": pan, "aadhaar_last_four": aadhaar[-4:] if aadhaar else None, "verified": False}


def _bank(row):
    account = _identifier(row, "bank_account", "bank", r"\d+")
    ifsc = _identifier(row, "ifsc", "bank", r"[A-Z]{4}0[A-Z0-9]{6}")
    bank_name = row.text("bank_name")
    if not bank_name:
        row.issue("BANK_NAME_REQUIRED", "DEFER_SECTION", "bank", "bank_name",
                  "Bank name is absent; no incomplete bank record will be created.")
    if not account or not ifsc or not bank_name:
        return None
    return {"account_number": account, "ifsc": ifsc, "bank_name": bank_name,
            "account_holder": row.text("bank_holder"), "branch": row.text("bank_branch"),
            "account_type": row.text("bank_account_type"), "verified": False}


def convert_solvian(rows, profile: str, options: ConversionOptions) -> dict:
    if profile not in {"SCL", "SBL"}:
        raise ValueError("Select the explicit SCL or SBL source profile")
    if "Sheet1" not in rows.sheets:
        raise ValueError("The reviewed source profile requires Sheet1")
    sheet = rows.sheets["Sheet1"]
    header_row = 7 if profile == "SCL" else 6
    header = sheet.rows.get(header_row, {})
    name_header = header.get(f"F{header_row}")
    if name_header is None or "name" not in name_header.raw.lower():
        raise ValueError("The selected profile does not match the source header layout")
    columns = {**COMMON, **(SCL if profile == "SCL" else SBL)}
    issues, employees, used_code_keys = [], [], set()
    for row_number, cells in sorted(sheet.rows.items()):
        if row_number <= header_row:
            continue
        serial = cells.get(f"C{row_number}")
        # Positive employee serials define rows. A missing name is an issue, not a dropped row.
        if serial is None or not re.fullmatch(r"[1-9]\d*(?:\.0+)?", serial.raw.strip()):
            continue
        row = SourceRow(rows, sheet, row_number, columns, issues)
        employee = _employee(row, options, used_code_keys)
        identity, bank = _identity(row), _bank(row)
        salary = recurring_salary(row)
        leave, historical = leave_snapshot(row, options)
        period = period_input(row, options.september_blank_formula_inputs_as_zero)
        from scripts.tenant_specific.solvian.imports.solvian_future_rules import tax_settings
        future_tax = tax_settings(row)
        employees.append({"source_ref": row.source_ref(), "source_states": row.states(),
                          "employee": employee, "identity": identity, "bank": bank,
                          "recurring_salary": salary, "leave_opening": leave,
                          "historical_lwp": historical, "period_input": period, "clear_fields": [],
                          "tax_settings": future_tax, "tax_history": []})
    if not employees:
        raise ValueError("No employee rows matched the selected source profile")
    _duplicates(employees, issues)
    unmatched = set(options.employee_codes) - used_code_keys
    if unmatched:
        issues.append({"code": "UNUSED_CODE_MAPPING", "severity": "BLOCK_TENANT", "section": "employee",
                       "source_ref": None, "field": "code", "message": "A reviewed code mapping does not match an employee source row; review the mapping file."})
    from scripts.tenant_specific.solvian.imports.solvian_future_rules import company_policy
    return {"format": "hrms-tenant-import", "version": 1, "company_payroll_policy": company_policy(),
            "source": {"file_label": rows.file_label, "file_hash": rows.file_hash, "profile": profile,
                       "profile_version": 3, "formula_results": "CACHED_SOURCE_VALUES"},
            "tenant_code": options.tenant_code.strip(),
            "salary_effective_policy": "JOINING_DATE" if options.salary_effective_from == "JOINING_DATE" else "FIXED_DATE",
            "salary_effective_from": None if options.salary_effective_from == "JOINING_DATE" else options.salary_effective_from,
            "leave_as_of": options.leave_as_of, "period": {"year": 2026, "month": 9},
            "employees": employees, "configuration": {
                "leave": {"paid_type_code": "EL", "unpaid_type_code": "LWP", "grant_mode": "SNAPSHOT_ONLY",
                          "unpaid_quota": None, "unpaid_max_consecutive_days": None, "approval": "EXISTING_WORKFLOW"},
                "payroll": {"lwp_basis": "GROSS", "lwp_divisor": "31", "rounding": "HALF_UP_2DP",
                            "unresolved_future_rules": "REQUIRE_HR_CONFIGURATION", "auto_generate_payslips": False}},
            "issues": issues}


def _duplicates(employees, issues):
    for section, field in (("employee", "code"), ("bank", "account_number"), ("identity", "pan"), ("employee", "uan")):
        groups = {}
        for employee in employees:
            value = (employee.get(section) or {}).get(field)
            if value is not None:
                groups.setdefault(value, []).append(employee)
        for group in groups.values():
            if len(group) < 2:
                continue
            for employee in group:
                issues.append({"code": "DUPLICATE_SOURCE_IDENTIFIER", "severity": "WARNING" if section == "bank" else "BLOCK_EMPLOYEE",
                               "section": section, "source_ref": employee["source_ref"], "field": field,
                               "message": "An identifier is shared by multiple source rows; confirm ownership without merging employee identities."})
