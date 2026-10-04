"""Reviewed source conventions exported as data for the reusable importer."""
from scripts.tenant_specific.solvian.imports.solvian_period import _matches


def tax_settings(row):
    if not _matches(row.formula("tds"), f"AE{row.row}*10%"):
        row.issue("FUTURE_TAX_SETTINGS_REQUIRED", "DEFER_SECTION", "tax_settings", "tds",
                  "September TDS remains the source amount. HR must choose the future regime and withholding method; a constant does not establish a rate.")
        return None
    row.issue("TAX_REGIME_REVIEW_REQUIRED", "DEFER_SECTION", "tax_settings", "tds",
              "The source establishes 10% of earned gross excluding separate incentive. HR must select the annual tax regime and confirm residency before future configuration is ready.")
    return {"regime": None, "method": "PERCENTAGE_OVERRIDE", "percentage": "0.10",
            "basis_components": ["BASIC", "HRA", "CONVEYANCE", "OTHER"],
            "effective_from": "2026-10-01", "effective_until": None, "resident": None,
            "reason": "Imported client source formula: 10% of earned gross after LWP, excluding separately recorded incentive. Annual tax regime requires HR review."}


def company_policy():
    def formula(weights, rate):
        return {"weights": weights, "rate": rate, "ceiling": None, "rounding": "HALF_UP_2DP"}
    pf = {"BASIC": "1", "CONVEYANCE": "1", "OTHER": "1"}
    esi = {code: "0.5" for code in ("BASIC", "HRA", "CONVEYANCE", "OTHER")}
    return {"effective_from": "2026-10-01", "effective_until": None, "lwp_divisor": 31,
            "origin": "IMPORTED_CLIENT_RULE",
            "reason": "Imported Solvian workbook convention: PF on Basic + Conveyance + Other; ESI on half of earned gross. This is a client formula, not a certification of statutory wage classification. HR must confirm individual applicability, ceilings and future professional tax.",
            "pf_employee": formula(pf, "0.12"), "pf_employer": formula(pf, "0.13"),
            "esi_basis": formula(esi, "0.0075"), "esi_employer_rate": "0.0325",
            "company_esi_covered": True, "esi_mode": "CUSTOM_COMPONENTS",
            "classifications": {}, "professional_tax": None}
