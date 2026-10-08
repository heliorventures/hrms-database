"""Prove same-row numeric formula references; never execute workbook expressions."""
from __future__ import annotations

import ast
from decimal import Decimal
import re


def _column(number):
    result = ""
    while number:
        number, digit = divmod(number - 1, 26)
        result = chr(65 + digit) + result
    return result


def _column_number(column):
    result = 0
    for char in column:
        result = result * 26 + ord(char) - 64
    return result


def numeric_references(formula, row_number):
    if not formula or len(formula) > 2048:
        return set()
    source = formula.upper().replace("$", "").strip().lstrip("=")
    # Ranges are allowed only inside a plain SUM; expansion is bounded to one row.
    def expand(match):
        start, first, end, last = match.groups()
        a, b = _column_number(start), _column_number(end)
        if int(first) != row_number or int(last) != row_number or not 0 <= b - a <= 64:
            raise ValueError("unsupported range")
        return ",".join(f"{_column(n)}{row_number}" for n in range(a, b + 1))

    try:
        source = re.sub(r"([A-Z]+)(\d+):([A-Z]+)(\d+)", expand, source)
        source = re.sub(r"(\d+(?:\.\d+)?)%", r"(\1/100)", source)
        tree = ast.parse(source, mode="eval")
    except (ValueError, SyntaxError, RecursionError):
        return set()
    references = set()

    def check(node):
        if isinstance(node, ast.Expression):
            return check(node.body)
        if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div)):
            return check(node.left) and check(node.right)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            return check(node.operand)
        if isinstance(node, ast.Constant):
            return type(node.value) in (int, float)
        if isinstance(node, ast.Name) and re.fullmatch(rf"[A-Z]+{row_number}", node.id):
            references.add(node.id)
            return True
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "SUM":
            return not node.keywords and 0 < len(node.args) <= 128 and all(check(arg) for arg in node.args)
        return False

    try:
        return references if check(tree) else set()
    except RecursionError:
        return set()


def september_numbers(row, fields, enabled):
    values = {field: row.number(field) for field in fields}
    if not enabled:
        return values
    references = set()
    # A numeric cached salary result is required. Errors and unsupported functions
    # do not authorize replacing their inputs, even when another field is empty.
    salary_outputs = ("lwp_amount", "earned_gross", "total_deduction", "remaining_payable",
                      "earned_basic", "earned_hra", "earned_conveyance", "earned_other",
                      "pf_wage", "esi_wage", "employee_pf", "employer_pf", "employee_esi", "employer_esi")
    for field in salary_outputs:
        if row.number(field) is not None:
            references.update(numeric_references(row.formula(field), row.row))
    # The reviewed September LWP rule is gross / 31 * source LWD even when
    # the amount cell is empty. This is a period rule, never historical usage.
    references.add(f"{row.columns['lwd_days']}{row.row}")
    states = row.states()
    logged = set()
    for field in fields:
        cell_ref = f"{row.columns[field]}{row.row}"
        if values[field] is None and states[field] in {"BLANK", "MISSING"} and cell_ref in references:
            values[field] = Decimal(0)
            if cell_ref not in logged:
                row.issue("SOURCE_BLANK_FORMULA_INPUT_ZERO", "WARNING", "period_input", field,
                          "Approved September-only rule: this blank numeric formula input is treated as zero; the source state is retained.")
                logged.add(cell_ref)
    return values
