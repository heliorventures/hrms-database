"""Source September inputs, with no fabricated leave requests or future eligibility."""
from __future__ import annotations

import ast
from decimal import Decimal
import re
from scripts.reusable.imports.normalize import money, quantity
from scripts.tenant_specific.solvian.imports.solvian_salary_leave import COMPONENTS, PF_COMPONENTS
from scripts.tenant_specific.solvian.imports.solvian_formula_inputs import september_numbers


def _formula_tree(formula):
    if formula is None or len(formula) > 2048:
        return None
    source = formula.replace("$", "").strip().lstrip("=")
    source = re.sub(r"(\d+(?:\.\d+)?)%", r"(\1/100)", source)
    try:
        tree = ast.parse(source, mode="eval")
    except (SyntaxError, RecursionError):
        return None

    class StripPlus(ast.NodeTransformer):
        def visit_UnaryOp(self, node):
            node = self.generic_visit(node)
            return node.operand if isinstance(node.op, ast.UAdd) else node

    return ast.dump(StripPlus().visit(tree), include_attributes=False)


def _matches(formula, expected):
    actual = _formula_tree(formula)
    return actual is not None and actual == _formula_tree(expected)


def gross_rule(row):
    fixed = f"{row.columns['fixed_gross']}{row.row}"
    ot = f"{row.columns['ot']}{row.row}"
    month = f"{row.columns['month_days']}{row.row}"
    paid = f"{row.columns['paid_days']}{row.row}"
    formula = row.formula("earned_gross")
    if _matches(formula, f"{fixed}-AD{row.row}"):
        return "FIXED_MINUS_LWP"
    if _matches(formula, f"{fixed}/{month}*{paid}+{ot}"):
        return "PAID_DAYS_PLUS_OT"
    row.issue("SOURCE_GROSS_OVERRIDE", "WARNING", "period_input", "earned_gross",
              "Earned gross is an explicit September override; the source does not establish a reusable gross formula.")
    return "SOURCE_OVERRIDE"


def contribution_rules(row):
    rules = {}
    pf_wage = f"AJ{row.row}"
    esi_wage = f"AN{row.row}"
    for code, field, wage, rate in (("employee_pf", "employee_pf", pf_wage, "12"),
                                   ("employer_pf", "employer_pf", pf_wage, "13"),
                                   ("employee_esi", "employee_esi", esi_wage, "0.75"),
                                   ("employer_esi", "employer_esi", esi_wage, "3.25")):
        formula = row.formula(field)
        known = _matches(formula, f"{wage}*{rate}%") or _matches(formula, f"{wage}*{rate}/100")
        rules[code] = {"origin": "SOURCE_FORMULA" if known else "PERIOD_OVERRIDE",
                       "rate": quantity(Decimal(rate) / 100) if known else None,
                       "ceiling": None, "future_applicability_confirmed": known,
                       "source_amount": money(row.number(field))}
    esi_formula = row.formula("esi_wage")
    rules["pf_basis_components"] = PF_COMPONENTS
    rules["displayed_pf_ceiling"] = money(row.number("displayed_pf_ceiling"))
    rules["esi_gross_multiplier"] = "0.5" if _matches(esi_formula, f"AE{row.row}/2") else None
    rules["rounding"] = "SOURCE_PERIOD_OVERRIDE"
    return rules


def period_input(row, blank_formula_inputs_as_zero=False):
    monetary_fields = ("fixed_gross", "earned_gross", "lwp_amount", "ot", "employee_pf", "employer_pf",
                       "esi_wage", "employee_esi", "employer_esi", "pt", "dues", "advance", "tds",
                       "other_deduction", "total_deduction", "incentive", "remaining_payable", "pf_wage")
    day_fields = ("month_days", "paid_days", "present_days", "lwd_days", "lwp_days")
    values = september_numbers(row, monetary_fields + day_fields, blank_formula_inputs_as_zero)
    amounts = {field: values[field] for field in monetary_fields}
    days = {field: values[field] for field in day_fields}
    rule = gross_rule(row)
    optional = {"employer_pf", "employer_esi", "esi_wage", "pf_wage"}
    states = row.states()
    # An empty Dues field absent from the source total is not a deduction.
    # Keep its absence visible rather than inventing an imported adjustment.
    if states["dues"] in {"BLANK", "MISSING"} and not re.search(
            rf"\b\$?{row.columns['dues']}\$?{row.row}\b", row.formula("total_deduction") or ""):
        optional.add("dues")
    if (blank_formula_inputs_as_zero and amounts["lwp_amount"] is None and
            states["lwp_amount"] in {"BLANK", "MISSING"} and days["lwd_days"] is not None):
        optional.add("lwp_amount")
    if rule != "PAID_DAYS_PLUS_OT":
        optional.add("ot")
    ready = True
    for field, value in amounts.items():
        if value is None or value < 0:
            row.issue("PERIOD_AMOUNT_UNRESOLVED", "WARNING" if field in optional else "DEFER_SECTION", "period_input", field,
                      "A financial source amount is missing or invalid; preserve it as unknown and review this period.")
            if field not in optional:
                ready = False
    if (days["lwd_days"] is None or days["lwd_days"] < 0 or
            (rule == "PAID_DAYS_PLUS_OT" and (days["month_days"] is None or days["month_days"] <= 0 or
             days["paid_days"] is None or days["paid_days"] < 0))):
        row.issue("PERIOD_DAYS_UNRESOLVED", "DEFER_SECTION", "period_input", "paid_days",
                  "Month, paid and LWP day inputs require nonnegative verified source quantities.")
        ready = False
    if days["lwp_days"] is not None and days["lwd_days"] is not None and days["lwp_days"] != days["lwd_days"]:
        row.issue("LWP_DAY_COLUMNS_CONFLICT", "DEFER_SECTION", "period_input", "lwp_days",
                  "The explicit leave-days column and the days used by the source LWP rule differ; HR reconciliation is required.")
        ready = False
    components = {code: row.number(field) for code, field in COMPONENTS.items()}
    if (any(value is None or value < 0 for value in components.values()) or amounts["earned_gross"] is None or
            abs(sum(value for value in components.values() if value is not None) - amounts["earned_gross"]) > Decimal("0.02")):
        row.issue("EARNED_COMPONENTS_UNRESOLVED", "DEFER_SECTION", "period_input", "earned_gross",
                  "Earned components do not reconcile to September gross; financial finalization requires review.")
        ready = False
    additional = []
    for field, code in (("other_deduction", "OTHER_DEDUCTION"), ("dues", "DUES")):
        amount = amounts[field]
        if amount is not None and amount > 0:
            additional.append({"code": code, "amount": money(amount), "reason": None,
                               "origin": "SOURCE_IMPORT"})
            row.issue("DEDUCTION_REASON_REQUIRED", "DEFER_SECTION", "period_input", field,
                      "The source deduction has no business reason; HR must provide the actual reason before finalization.")
            ready = False
    fixed, earned, lwp, ot = (amounts[field] for field in ("fixed_gross", "earned_gross", "lwp_amount", "ot"))
    if lwp is None and "lwp_amount" in optional and fixed is not None:
        lwp = fixed / 31 * days["lwd_days"]
        row.issue("SOURCE_LWP_RULE_CALCULATED", "WARNING", "period_input", "lwp_amount",
                  "The blank September amount is calculated using the reviewed gross / 31 * source days rule; source absence is retained.")
    computed = None
    if rule == "FIXED_MINUS_LWP" and fixed is not None and lwp is not None:
        computed = fixed - lwp
    elif (rule == "PAID_DAYS_PLUS_OT" and fixed is not None and ot is not None and
          days["month_days"] is not None and days["month_days"] > 0 and days["paid_days"] is not None):
        computed = fixed / days["month_days"] * days["paid_days"] + ot
    if computed is not None and earned is not None and abs(computed - earned) > Decimal("0.02"):
        row.issue("SOURCE_GROSS_RECONCILIATION", "DEFER_SECTION", "period_input", "earned_gross",
                  "The known gross formula differs from its stored result; the workbook needs reviewed recalculation.")
        ready = False
    lwp_computed = None
    if fixed is not None and days["lwd_days"] is not None:
        lwp_computed = fixed / 31 * days["lwd_days"]
    if lwp_computed is not None and lwp is not None and abs(lwp_computed - lwp) > Decimal("0.02"):
        row.issue("SOURCE_LWP_OVERRIDE", "WARNING", "period_input", "lwp_amount",
                  "The September LWP amount is an explicit source override of gross / 31 * source days; do not deduct it twice.")
    statutory_values = [amounts[field] for field in ("employee_pf", "employee_esi", "pt", "tds")]
    statutory = sum(statutory_values) if all(v is not None for v in statutory_values) else None
    extra_values = [amounts["dues"], amounts["other_deduction"]]
    extra = sum(v for v in extra_values if v is not None) if (amounts["other_deduction"] is not None and
            (amounts["dues"] is not None or "dues" in optional)) else None
    incentive, advance = amounts["incentive"], amounts["advance"]
    net = earned + incentive - statutory - extra if all(v is not None for v in (earned, incentive, statutory, extra)) else None
    remaining = net - advance if net is not None and advance is not None else None
    total = statutory + extra + advance if all(v is not None for v in (statutory, extra, advance)) else None
    for field, calculated in (("total_deduction", total), ("remaining_payable", remaining)):
        expected = amounts[field]
        if calculated is not None and expected is not None and abs(calculated - expected) > Decimal("0.02"):
            row.issue("STATEMENT_RECONCILIATION_REQUIRED", "DEFER_SECTION", "period_input", field,
                      "Source statement totals differ from itemized amounts; reconcile before financial finalization.")
            ready = False
    if remaining is not None and remaining < 0:
        row.issue("EXCESS_ADVANCE_REVIEW", "DEFER_SECTION", "period_input", "advance",
                  "Advance exceeds net earned; HR must confirm the outstanding-credit settlement before finalization.")
        ready = False
    total_formula = row.formula("total_deduction") or ""
    if len(re.findall(rf"\b\$?AU\$?{row.row}\b", total_formula)) > 1:
        row.issue("SOURCE_DUPLICATE_DEDUCTION_REFERENCE", "WARNING", "period_input", "total_deduction",
                  "The source total formula includes Other Deduction more than once; the system uses its itemized amount once.")
    expected_statement = {"earned_gross": money(earned), "statutory_total": money(statutory),
                          "additional_total": money(extra), "net_earned": money(net),
                          "source_total_deduction": money(amounts["total_deduction"]),
                          "remaining_payable": money(amounts["remaining_payable"]),
                          "excess_advance_credit": money(max(Decimal(0), -remaining)) if remaining is not None else None}
    return {"year": 2026, "month": 9, "gross_rule": rule, "fixed_gross": money(fixed),
            "earned_gross_override": money(earned) if rule == "SOURCE_OVERRIDE" else None,
            "month_days": quantity(days["month_days"]), "paid_days": quantity(days["paid_days"]),
            "present_days": quantity(days["present_days"]), "lwp_days": quantity(days["lwd_days"]),
            "source_lwp_days": quantity(days["lwp_days"]), "lwp_divisor": "31",
            "lwp_amount_override": money(lwp), "lwp_basis": "GROSS",
            "lwp_handling": "SOURCE_GROSS_INCLUDES_REDUCTION", "variable_allowance_ot": money(ot),
            "incentive": money(incentive), "advance_already_paid": money(advance),
            "additional_deductions": additional, "statutory_overrides": {
                code: money(amounts[field]) for code, field in (("PF", "employee_pf"), ("ESI", "employee_esi"),
                                                              ("PT", "pt"), ("TDS", "tds"))},
            "expected_earned_components": {code: money(value) for code, value in components.items()},
            "expected_wages": {"pf": money(amounts["pf_wage"]), "esi": money(amounts["esi_wage"])},
            "expected_employer_contributions": {"pf": money(amounts["employer_pf"]), "esi": money(amounts["employer_esi"])},
            "expected_statement": expected_statement, "contribution_rules": contribution_rules(row),
            "ready": ready, "status": "DRAFT", "historical_lwp_included": False}
