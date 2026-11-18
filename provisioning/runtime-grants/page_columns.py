"""Reviewed page callers omitted from the original company service contract.

Employee's two reads use complete ORM models after resolver authorization.
Payroll's raw catalog, save and additional-deduction insert use the visibility
column absent from its ORM model. Performance reads raw cycle stage dates and
the program filter. No unused model, end-user role or table-wide right is added.
"""

PAGE_COMPANY_COLUMNS = {
    'hrms_company_employee': {
        'company_document': {'select': [
            'id', 'tenant_id', 'category', 'title', 'description', 'file_storage_id',
            'status', 'visible_to_employees', 'uploaded_by', 'is_deleted',
            'deleted_at', 'deleted_by', 'created_at', 'updated_at']},
        'employment_history': {'select': [
            'id', 'tenant_id', 'employee_id', 'department_id', 'designation_id',
            'cost_center_id', 'salary', 'effective_from', 'effective_to',
            'change_reason', 'changed_by', 'is_deleted', 'created_at', 'updated_at']},
    },
    'hrms_company_payroll': {
        'salary_component': {
            'select': ['id', 'tenant_id', 'show_on_payslip'],
            'insert': ['show_on_payslip'],
            'update': ['show_on_payslip', 'updated_at']},
    },
    'hrms_company_performance': {
        'review_cycle': {'select': [
            'id', 'tenant_id', 'performance_program_id', 'current_stage',
            'goal_setting_due_date', 'self_review_due_date', 'manager_review_due_date',
            'calibration_due_date', 'acknowledgement_due_date']},
    },
}
