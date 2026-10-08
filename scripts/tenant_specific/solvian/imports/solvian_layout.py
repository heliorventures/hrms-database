"""The two reviewed Solvian layouts and row-level safe provenance."""
from __future__ import annotations

from dataclasses import dataclass
from scripts.reusable.imports.normalize import decimal_value, source_value, text_value


COMMON = {
    "serial": "C", "code": "D", "name": "F", "lwp_amount": "AD", "earned_gross": "AE",
    "earned_basic": "AF", "earned_hra": "AG", "earned_conveyance": "AH", "earned_other": "AI",
    "pf_wage": "AJ", "displayed_pf_ceiling": "AK", "employee_pf": "AL", "employer_pf": "AM",
    "esi_wage": "AN", "employee_esi": "AO", "employer_esi": "AP", "pt": "AQ", "dues": "AR",
    "advance": "AS", "tds": "AT", "other_deduction": "AU", "total_deduction": "AV",
    "incentive": "AW", "remaining_payable": "AX",
}
SCL = {
    "uan": "E", "designation": "G", "department": "H", "birth_date": "I", "joining_date": "J",
    "confirmation_date": "K", "exit_date": "L", "last_working_date": "M", "leave_date_text": "N",
    "carry_forward": "O", "grant": "P", "taken": "Q", "balance": "R", "month_days": "S",
    "present_days": "T", "lwd_days": "U", "early_basic": "V", "early_hra": "W",
    "early_conveyance": "X", "early_other": "Y", "fixed_gross": "Z", "ot": "AA",
    "paid_days": "AB", "lwp_days": "AC", "gender": "BA", "repeated_name": "BD",
    "pan": "BE", "aadhaar": "BF", "repeated_birth_date": "BG", "bank_holder": "BH",
    "bank_account": "BI", "bank_account_type": "BJ", "bank_name": "BK", "bank_branch": "BL",
    "ifsc": "BM",
}
SBL = {
    "uan": "G", "designation": "H", "department": "I", "birth_date": "J", "joining_date": "K",
    "confirmation_date": "L", "exit_date": "M", "last_working_date": "N", "leave_date_text": "O",
    "carry_forward": "P", "grant": "Q", "taken": "R", "balance": "S", "month_days": "T",
    "present_days": "U", "lwd_days": "V", "early_basic": "W", "early_hra": "X",
    "early_conveyance": "Y", "early_other": "Z", "fixed_gross": "AA", "ot": "AB",
    "paid_days": "AC", "lwp_days": "V", "repeated_name": "BA", "pan": "BB", "aadhaar": "BC",
    "repeated_birth_date": "BD", "bank_holder": "BE", "bank_account": "BF",
    "bank_account_type": "BG", "bank_name": "BH", "bank_branch": "BI", "ifsc": "BJ",
}


@dataclass
class SourceRow:
    workbook: object
    sheet: object
    row: int
    columns: dict
    issues: list

    def cell(self, field):
        column = self.columns.get(field)
        return self.sheet.rows[self.row].get(f"{column}{self.row}") if column else None

    def raw(self, field):
        cell = self.cell(field)
        return cell.raw if cell is not None and cell.kind != "e" else None

    def text(self, field):
        return text_value(self.raw(field))

    def number(self, field):
        return decimal_value(self.raw(field))

    def formula(self, field):
        cell = self.cell(field)
        return cell.formula if cell else None

    def source_ref(self):
        return {"file_hash": self.workbook.file_hash, "sheet": self.sheet.name, "row": self.row,
                "cells": {field: f"{column}{self.row}" for field, column in self.columns.items()}}

    def states(self):
        result = {}
        for field in self.columns:
            cell = self.cell(field)
            result[field] = ("ERROR" if cell and cell.kind == "e" else
                             source_value(None if cell is None else cell.raw, present=cell is not None)["state"])
        return result

    def issue(self, code, severity, section, field, message):
        # Messages are fixed application text; source values/identifiers are never interpolated.
        self.issues.append({"code": code, "severity": severity, "section": section,
                            "source_ref": self.source_ref(), "field": field, "message": message})
