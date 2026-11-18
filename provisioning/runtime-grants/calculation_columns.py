"""Explicit caller projections for imported banking and payroll eligibility.

These rights belong to the existing service identities. End-user role names are
irrelevant: APIs still enforce their exact permission, scope and target binding.
The whole-row Payroll fingerprint and its table locks use a separate authority;
this module must never grant broad input writes or unrelated fingerprint reads.
"""

CALCULATION_COMPANY_COLUMNS = {
    'hrms_company_employee': {
        'employee': {'select': [
            'id', 'tenant_id', 'is_deleted', 'confirmation_date',
            'imported_exit_date', 'imported_last_working_date']},
        'employee_bank': {'select': [
            'tenant_id', 'employee_id', 'is_primary', 'account_holder', 'branch_name']},
    },
    'hrms_company_payroll': {
        'employee': {'select': [
            'id', 'tenant_id', 'status', 'payroll_excluded', 'date_of_joining',
            'imported_last_working_date', 'imported_exit_date', 'employee_code',
            'first_name', 'last_name', 'is_deleted']},
        # Tax projection conditionally resolves the latest old-regime proof per
        # section. It does not request proof contents, evidence or approval writes.
        'tax_proof_line': {'select': [
            'section_code', 'status', 'actual_amount', 'submitted_at',
            'tenant_id', 'employee_id', 'fiscal_year', 'tax_config_version_id']},
        'tax_configuration_version': {'select': [
            'tenant_id', 'id', 'fiscal_year', 'regime']},
    },
}
