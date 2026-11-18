"""The draft UPSERT needs reads of EXCLUDED fields as well as write rights."""
DRAFT_COMPANY_COLUMNS = {
    'hrms_company_payroll': {
        'payroll_draft_calculation': {'select': [
            'tenant_id', 'cycle_id', 'snapshot', 'revision', 'fingerprint',
            'calculated_by', 'calculated_by_principal_id']},
    },
}
