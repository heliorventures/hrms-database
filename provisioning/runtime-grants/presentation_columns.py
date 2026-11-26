"""Reviewed conditional payslip and automated-notification caller requirements.

The payslip renderer always projects its allowlisted employee fields and joins
tenant-scoped department/designation labels, even if a company displays fewer
fields. Imported salary financials and the immutable payslip statement are reads.
The notification marker inserts eight fields. RETURNING needs UUID read access;
the explicit ON CONFLICT arbiter needs its five key columns. The existing unique
delivery key remains responsible for suppressing duplicates.
"""
from copy import deepcopy

PRESENTATION_COMPANY_COLUMNS = {
    'hrms_company_payroll': {
        'employee': {'select': [
            'id', 'tenant_id', 'first_name', 'last_name', 'employee_code',
            'department_id', 'designation_id', 'date_of_joining', 'gender',
            'marital_status', 'uan_number', 'esic_number', 'is_deleted']},
        'department': {'select': ['id', 'tenant_id', 'name', 'is_deleted']},
        'designation': {'select': ['id', 'tenant_id', 'title', 'is_deleted']},
        'employee_salary_structure': {'select': [
            'id', 'tenant_id', 'annual_gross', 'annual_employer_pf']},
        'payslip_statement': {'select': [
            'payslip_id', 'tenant_id', 'statement', 'period_input_id',
            'period_input_revision', 'created_at']},
    },
    'hrms_company_notification': {
        'automated_notification_occurrence': {
            'insert': ['id', 'tenant_id', 'event_type', 'employee_id', 'event_date',
                       'recipient_user_id', 'notification_id', 'created_at'],
            'select': ['id', 'tenant_id', 'event_type', 'employee_id', 'event_date',
                       'recipient_user_id']},
    },
}

# The automated sweep runs in tenant maintenance; the notification service can
# still invoke the same operation. Keep their occurrence contract independent.
PRESENTATION_COMPANY_COLUMNS['hrms_company_maintenance'] = deepcopy(
    PRESENTATION_COMPANY_COLUMNS['hrms_company_notification'])
