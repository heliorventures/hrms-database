"""Reviewed business callers; explicit columns, never inferred from ORM/source scans.

Read projections include ORM INSERT/UPDATE RETURNING. PostgreSQL row locks need
UPDATE authority: workflow_step receives only UPDATE(id), preserving its lock
semantics without allowing Payroll to edit workflow configuration. No sequence
rights are needed: source identifiers are UUIDs and timestamps use now().
"""

BUSINESS_COMPANY_COLUMNS = {
    'hrms_company_employee': {
        'onboarding_checklist': {
            'select': ['id', 'tenant_id', 'employee_id', 'task_name', 'task_category', 'assigned_to', 'is_completed', 'due_date', 'completed_at', 'created_at', 'updated_at'],
            'update': ['is_completed', 'completed_at', 'updated_at']},
        'employee_profile_change_request': {
            'select': ['id', 'tenant_id', 'employee_id', 'requested_by', 'request_type', 'requested_payload', 'requested_payload_encrypted', 'payload_encryption_version', 'status', 'supporting_document_id', 'reviewed_by', 'reviewed_at', 'rejection_reason', 'created_at', 'updated_at'],
            'insert': ['id', 'tenant_id', 'employee_id', 'requested_by', 'request_type', 'requested_payload', 'requested_payload_encrypted', 'payload_encryption_version', 'status', 'supporting_document_id', 'reviewed_by', 'reviewed_at', 'rejection_reason', 'created_at', 'updated_at'],
            'update': ['status', 'requested_payload', 'requested_payload_encrypted', 'payload_encryption_version', 'reviewed_by', 'reviewed_at', 'rejection_reason', 'updated_at']},
        'separation': {
            'select': ['id', 'tenant_id', 'employee_id', 'separation_type', 'resignation_date', 'last_working_date', 'reason', 'status', 'approved_by', 'workflow_instance_id', 'offboarded_at', 'offboarding_event_id', 'created_at', 'updated_at'],
            'insert': ['id', 'tenant_id', 'employee_id', 'separation_type', 'resignation_date', 'last_working_date', 'reason', 'status', 'approved_by', 'workflow_instance_id', 'offboarded_at', 'offboarding_event_id', 'created_at', 'updated_at'],
            'update': ['status', 'approved_by', 'approved_by_principal_id', 'offboarded_at', 'offboarding_event_id', 'updated_at']},
        'clearance_checklist': {
            'select': ['id', 'tenant_id', 'separation_id', 'department', 'task_name', 'is_cleared', 'cleared_by', 'cleared_at', 'created_at', 'updated_at'],
            'insert': ['id', 'tenant_id', 'separation_id', 'department', 'task_name', 'is_cleared', 'cleared_by', 'cleared_at', 'created_at', 'updated_at'],
            'update': ['is_cleared', 'cleared_by', 'cleared_by_principal_id', 'cleared_at', 'updated_at']},
        # Profile callers emit an in-transaction notification without requesting
        # an unused ORM readback; Employee does not need notification SELECT.
        'notification': {
            'insert': ['id', 'tenant_id', 'user_id', 'type', 'title', 'message', 'action_url', 'is_read', 'read_at', 'created_at', 'updated_at']},
        # Finance approval registration/terminal transitions are owned by HR.
        # result is not read or written by the current source operations.
        'employee_exit_operation': {
            'select': ['id', 'tenant_id', 'separation_id', 'employee_id', 'actor_id', 'review_id', 'separation_fingerprint', 'payload_hash', 'authorization_id', 'state', 'created_at'],
            'insert': ['id', 'tenant_id', 'separation_id', 'employee_id', 'actor_id', 'review_id', 'separation_fingerprint', 'payload_hash', 'state'],
            'update': ['state', 'authorization_id', 'updated_at']},
    },
    'hrms_company_leave': {
        'workflow_action': {
            'select': ['id', 'tenant_id', 'instance_id', 'workflow_step_id', 'performed_by', 'action', 'remarks', 'acted_at', 'created_at', 'updated_at']},
    },
    'hrms_company_payroll': {
        'user': {'select': ['id', 'tenant_id', 'username', 'is_active', 'is_deleted']},
        'file_storage': {'select': ['id', 'tenant_id', 'mime_type']},
        'loan_request': {
            'select': ['id', 'tenant_id', 'employee_id', 'requested_amount', 'currency', 'purpose', 'employee_notes', 'management_notes', 'preferences', 'state', 'workflow_instance_id', 'version', 'created_at'],
            'insert': ['id', 'tenant_id', 'employee_id', 'requested_amount', 'currency', 'purpose', 'employee_notes', 'preferences', 'state', 'version'],
            'update': ['requested_amount', 'currency', 'purpose', 'employee_notes', 'preferences', 'state', 'workflow_instance_id', 'version', 'management_notes']},
        'workflow': {
            'select': ['id', 'tenant_id', 'name', 'entity_type', 'is_active', 'created_at', 'updated_at']},
        'workflow_step': {
            'select': ['id', 'tenant_id', 'workflow_id', 'sequence_order', 'step_name', 'approver_type', 'approver_role_id', 'approver_permission', 'can_skip', 'sla_hours', 'created_at', 'updated_at'],
            'update': ['id']},
        'workflow_instance': {
            'select': ['id', 'tenant_id', 'workflow_id', 'entity_type', 'entity_id', 'status', 'current_step_id', 'created_at', 'completed_at', 'updated_at'],
            'insert': ['id', 'tenant_id', 'workflow_id', 'entity_type', 'entity_id', 'status', 'current_step_id', 'created_at', 'completed_at', 'updated_at'],
            'update': ['status', 'current_step_id', 'completed_at', 'updated_at']},
        'workflow_action': {
            'insert': ['id', 'tenant_id', 'instance_id', 'workflow_step_id', 'performed_by', 'action', 'remarks', 'acted_at', 'created_at', 'updated_at']},
        'payslip_unpaid_leave': {
            'select': ['id', 'tenant_id', 'payslip_id', 'basic_component_code', 'basic_amount', 'day_divisor', 'unpaid_days', 'amount', 'treatment', 'source_days', 'created_at'],
            'insert': ['id', 'tenant_id', 'payslip_id', 'basic_component_code', 'basic_amount', 'day_divisor', 'unpaid_days', 'amount', 'treatment', 'source_days', 'created_at']},
    },
}
