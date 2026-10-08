"""Recurring salary and leave snapshot conversion, independent of payroll usage."""
from decimal import Decimal
from scripts.reusable.imports.normalize import money, quantity


COMPONENTS = {"BASIC": "earned_basic", "HRA": "earned_hra",
              "CONVEYANCE": "earned_conveyance", "OTHER": "earned_other"}
PF_COMPONENTS = ["BASIC", "CONVEYANCE", "OTHER"]
CONFIRMED_SPLIT = {"BASIC": Decimal("0.5"), "HRA": Decimal("0.25"),
                   "CONVEYANCE": Decimal("0.125"), "OTHER": Decimal("0.125")}


def recurring_salary(row):
    fixed, earned = row.number("fixed_gross"), row.number("earned_gross")
    amounts = {code: row.number(field) for code, field in COMPONENTS.items()}
    if (fixed is None or fixed <= 0 or earned is None or earned <= 0 or
            any(value is None or value < 0 for value in amounts.values()) or
            abs(sum(amounts.values()) - earned) > Decimal("0.02")):
        row.issue("SALARY_SPLIT_UNRESOLVED", "DEFER_SECTION", "recurring_salary", "earned_gross",
                  "Fixed gross and earned split must be numeric, positive and reconciled before salary configuration.")
        return None
    ratios = {code: value / earned for code, value in amounts.items()}
    # The approved client profile is the reviewed 50/25/12.5/12.5 split, not a guess for changed files.
    if any(abs(ratios[code] - expected) > Decimal("0.000001") for code, expected in CONFIRMED_SPLIT.items()):
        row.issue("SALARY_PROFILE_CHANGED", "DEFER_SECTION", "recurring_salary", "earned_basic",
                  "Earned component proportions differ from the reviewed client profile; review the source rule.")
        return None
    # The source split has passed the reviewed tolerance above. Preserve the
    # confirmed ratios rather than binary floating-point cache noise.
    ratios = dict(CONFIRMED_SPLIT)
    recurring = {code: Decimal(money(fixed * ratio)) for code, ratio in ratios.items()}
    recurring["OTHER"] += Decimal(money(fixed)) - sum(recurring.values())
    wage_base = sum(recurring[code] for code in PF_COMPONENTS)
    employer_rule = None
    annual_employer_pf = None
    # A source formula establishes this rule. A hardcoded amount/zero does not prove eligibility or a cap.
    formula = row.formula("employer_pf")
    canonical = "" if formula is None else formula.replace(" ", "").replace("$", "").lstrip("=")
    if canonical == f"AJ{row.row}*13%":
        employer_rule = {"basis_components": PF_COMPONENTS, "rate": "0.13", "ceiling": None,
                         "rounding": "HALF_UP_2DP", "origin": "SOURCE_FORMULA"}
        annual_employer_pf = Decimal(money(wage_base * Decimal("0.13"))) * 12
    else:
        row.issue("EMPLOYER_PF_RULE_REVIEW", "DEFER_SECTION", "employer_cost", "employer_pf",
                  "Monthly employer PF is a source override; confirm future applicability, ceiling and rounding before CTC is ready.")
    annual_gross = Decimal(money(fixed)) * 12
    return {"monthly_gross": money(fixed), "annual_gross": money(annual_gross),
            "components": {code: money(value) for code, value in recurring.items()},
            "component_ratios": {code: quantity(value) for code, value in ratios.items()},
            "calculation_basis": "PERCENT_OF_GROSS", "employer_pf_rule": employer_rule,
            "annual_employer_pf": money(annual_employer_pf),
            "annual_ctc": money(annual_gross + annual_employer_pf) if annual_employer_pf is not None else None}


def leave_snapshot(row, options):
    fields = ("carry_forward", "grant", "taken", "balance")
    values = {field: row.number(field) for field in fields}
    raw_values = {field: row.cell(field).raw if row.cell(field) else None for field in fields}
    states = row.states()
    blank = {field for field in fields if states[field] in ("BLANK", "MISSING")
             or (states[field] == "VALUE" and str(raw_values[field]).strip() == "-")}
    zero_fields = blank.intersection(("carry_forward", "grant"))
    # Usage is zero only when the entire section is blank; otherwise an absent
    # Taken field remains unknown instead of inventing historical usage.
    if len(blank) == len(fields):
        zero_fields.add("taken")
    for field in zero_fields:
        values[field] = Decimal(0)
    if zero_fields:
        row.issue("LEAVE_BLANK_AS_ZERO", "WARNING", "leave_opening", "carry_forward",
                  "Confirmed source convention: blank entitlement, or wholly blank leave history, is zero.")
    carry, grant, taken, balance = (values[field] for field in fields)
    if taken is not None and taken < 0:
        taken = abs(taken)
        row.issue("LEAVE_SIGNED_USAGE_NORMALIZED", "WARNING", "leave_opening", "taken",
                  "Confirmed source convention: negative Taken records absolute historical usage; original values are retained.")
    if all(value is not None for value in (carry, grant, taken)):
        expected_balance = carry + grant - taken
        if "balance" in blank or (carry == 0 and grant == 0 and taken > 0 and balance == 0):
            balance = expected_balance
            row.issue("LEAVE_BALANCE_NORMALIZED", "WARNING", "leave_opening", "balance",
                      "Derived accounting balance from entitlement and usage; source zero with no entitlement denotes unpaid usage. Paid availability stays nonnegative.")
    result = {"year": 2026, "as_of": options.leave_as_of, "carry_forward": quantity(carry),
              "grant": quantity(grant), "source_taken": quantity(taken), "source_balance": quantity(balance),
              "raw_source_values": raw_values,
              "paid_used": None, "paid_remaining": None, "pending": None, "planned": None,
              "ready": False}
    historical = None
    complete = all(value is not None for value in (carry, grant, taken, balance))
    if complete and carry >= 0 and grant >= 0 and taken >= 0 and abs(carry + grant - taken - balance) <= Decimal("0.001"):
        entitlement = carry + grant
        result.update({"paid_used": quantity(min(taken, entitlement)),
                       "paid_remaining": quantity(max(Decimal(0), balance)), "ready": True})
        excess = max(Decimal(0), taken - entitlement)
        if excess:
            historical = {"as_of": options.leave_as_of, "days": quantity(excess),
                          "payroll_attribution": "HISTORICAL_ONLY"}
    else:
        row.issue("LEAVE_RECONCILIATION_REQUIRED", "DEFER_SECTION", "leave_opening", "taken",
                  "Leave values remain unknown or inconsistent after confirmed source conventions; review the snapshot.")
    row.issue("LEAVE_REQUEST_STATUS_NOT_SUPPLIED", "WARNING", "leave_opening", "pending",
              "The source supplies no pending/planned request status; these remain unknown and no dated request is created.")
    if row.text("leave_date_text"):
        row.issue("LEAVE_DATES_NOT_IMPORTED", "WARNING", "leave_opening", "leave_date_text",
                  "Source date text has no verified type/status/year; only the aggregate snapshot is retained.")
    return result, historical
