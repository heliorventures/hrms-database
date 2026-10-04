"""Strict scalar normalization shared by client adapters."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import re


CENT = Decimal("0.01")
NA_MARKERS = {"NA", "N/A", "#N/A", "NOT APPLICABLE"}


def source_value(raw, *, present=True):
    """Describe absence without turning it into zero or an explicit clear."""
    if not present:
        return {"state": "MISSING", "value": None}
    text = "" if raw is None else str(raw).strip()
    if not text:
        return {"state": "BLANK", "value": None}
    if text.upper() in NA_MARKERS:
        return {"state": "NA", "value": None}
    return {"state": "VALUE", "value": text}


def decimal_value(raw):
    state = source_value(raw)
    if state["state"] != "VALUE":
        return None
    text = state["value"]
    if len(text) > 64 or not re.fullmatch(r"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", text):
        return None
    try:
        number = Decimal(text)
        # Bound hostile inputs before quantization/arithmetic.
        if not number.is_finite() or abs(number) > Decimal("1e12") or abs(number.as_tuple().exponent) > 32:
            return None
        return number
    except InvalidOperation:
        return None


def money(value):
    return None if value is None else format(value.quantize(CENT, rounding=ROUND_HALF_UP), ".2f")


def quantity(value):
    return None if value is None else format(value.normalize(), "f")


def text_value(raw):
    state = source_value(raw)
    return state["value"] if state["state"] == "VALUE" else None


def identifier(raw, *, numeric=False):
    text = text_value(raw)
    if text is None:
        return None
    if numeric:
        try:
            number = Decimal(text)
            if not number.is_finite() or number != number.to_integral_value() or number < 0:
                return None
            text = format(number, ".0f")
            # Excel numeric cells cannot preserve identifiers beyond 15 digits.
            if len(text) > 15:
                return None
        except InvalidOperation:
            return None
    return text.strip()


def parse_date(raw, *, date1904=False):
    text = text_value(raw)
    if text is None:
        return None
    if re.fullmatch(r"\d+(?:\.0+)?", text):
        number = Decimal(text)
        if number < 0 or number > 1000000:
            return None
        days = int(number)
        # Excel's fictional 29-Feb-1900 must not become a real date.
        if not date1904 and days == 60:
            return None
        epoch = date(1904, 1, 1) if date1904 else date(1899, 12, 31)
        if not date1904 and days > 60:
            days -= 1
        try:
            return (epoch + timedelta(days=days)).isoformat()
        except OverflowError:
            return None
    for pattern in ("%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(text, pattern).date().isoformat()
        except ValueError:
            continue
    return None


@dataclass(frozen=True)
class ConversionOptions:
    tenant_code: str
    salary_effective_from: str
    leave_as_of: str
    employee_codes: dict[str, str] = field(default_factory=dict)
    september_blank_formula_inputs_as_zero: bool = False

    def __post_init__(self):
        if type(self.september_blank_formula_inputs_as_zero) is not bool:
            raise ValueError("September blank-input policy must be explicitly boolean")
        if not isinstance(self.tenant_code, str) or not self.tenant_code.strip():
            raise ValueError("An explicit tenant code is required")
        for value in (self.salary_effective_from, self.leave_as_of):
            if value == self.salary_effective_from and value == "JOINING_DATE":
                continue
            if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                raise ValueError("Operator dates must be explicit ISO dates")
            date.fromisoformat(value)
        if date.fromisoformat(self.leave_as_of).year != 2026:
            raise ValueError("This source profile requires a 2026 leave snapshot")
        if not isinstance(self.employee_codes, dict):
            raise ValueError("Reviewed employee codes must be a source-reference object")
        for key, code in self.employee_codes.items():
            if not isinstance(key, str) or not isinstance(code, str) or not code.strip():
                raise ValueError("Each reviewed employee mapping needs a nonblank string code")
