"""Explicit mail-only contracts; independent of end-user roles and scopes."""
import re
from copy import deepcopy

EMAIL_PRODUCERS = tuple('hrms_company_' + name for name in (
    'employee', 'leave', 'attendance', 'payroll', 'expense', 'tax', 'performance', 'maintenance'))
EMAIL_IDENTITY_COLUMNS = [
    'id', 'tenant_id', 'event_id', 'recipient_key', 'event_hash', 'event', 'producer',
    'resource_type', 'resource_id', 'resource_version', 'category', 'kind',
    'occurred_at', 'expires_at', 'created_at']
EMAIL_INSERT_COLUMNS = [column for column in EMAIL_IDENTITY_COLUMNS if column != 'created_at']
EMAIL_ACK_COLUMNS = ['id', 'tenant_id', 'event_id', 'recipient_key', 'event_hash']
EMAIL_DELIVERY_COLUMNS = [
    'state', 'next_attempt_at', 'attempt_count', 'lease_token', 'lease_until',
    'settings_version', 'delivery_source_tenant', 'delivery_source_user',
    'terminal_at', 'last_error_code']
EMAIL_SETTINGS_COLUMNS = [
    'id', 'tenant_id', 'singleton', 'version', 'enabled', 'smtp_host', 'smtp_port',
    'tls_mode', 'sender_name', 'sender_email', 'account_email', 'categories',
    'enabled_after', 'category_cutoffs', 'credential_cipher', 'credential_nonce',
    'credential_key_id', 'updated_by', 'updated_at']
EMAIL_RECEIPT_COLUMNS = [
    'tenant_id', 'audience', 'purpose', 'nonce', 'request_hash', 'expires_at', 'created_at']

EMAIL_COMPANY_COLUMNS = {
    role: {'important_email_intent': {'insert': list(EMAIL_INSERT_COLUMNS),
                                    'select': list(EMAIL_ACK_COLUMNS)}}
    for role in EMAIL_PRODUCERS
}
EMAIL_COMPANY_COLUMNS['hrms_company_notification'] = {
    'tenant_email_settings': {
        'select': list(EMAIL_SETTINGS_COLUMNS),
        'update': [column for column in EMAIL_SETTINGS_COLUMNS if column not in ('id', 'tenant_id', 'singleton')]},
    'important_email_intent': {
        'select': EMAIL_IDENTITY_COLUMNS + EMAIL_DELIVERY_COLUMNS,
        'insert': list(EMAIL_INSERT_COLUMNS), 'update': list(EMAIL_DELIVERY_COLUMNS), 'delete': True},
}
for _role in EMAIL_PRODUCERS:
    if _role == 'hrms_company_maintenance':
        continue  # Scheduler is a producer, never a private HTTP receipt consumer.
    EMAIL_COMPANY_COLUMNS[_role]['email_private_request_receipt'] = {
        'insert': [column for column in EMAIL_RECEIPT_COLUMNS if column != 'created_at'],
        'select': list(EMAIL_RECEIPT_COLUMNS), 'delete': True}

# Existing-table requirements are separate from the additive three-table DDL.
# Runtime policy merges them with earlier reviewed feature requirements. They
# never replace Access writes, imply an end-user role, or give Notification a
# financial/profile/RBAC read path.
_AUTHORITY_READS = {
    'user': ['id', 'tenant_id', 'is_active', 'is_deleted'],
    'user_role': ['user_id', 'role_id'],
    'role': ['id', 'tenant_id', 'is_deleted'],
    'role_permission': ['role_id', 'permission_id'],
    'permission': ['id', 'resource', 'action'],
    'permission_scope': ['role_id', 'tenant_id', 'resource', 'action', 'scope_type'],
    'employee': ['id', 'tenant_id', 'user_id', 'department_id', 'reporting_manager_id', 'status', 'is_deleted'],
}
EMAIL_AUTHORITY_COLUMNS = {
    role: {table: {'select': list(columns)} for table, columns in _AUTHORITY_READS.items()}
    for role in EMAIL_PRODUCERS
}
EMAIL_AUTHORITY_COLUMNS['hrms_company_employee']['user']['select'].append('email')
_WORKFLOW_READS = {
    'workflow': ['id', 'tenant_id', 'entity_type', 'is_active'],
    'workflow_instance': ['id', 'tenant_id', 'workflow_id', 'entity_type', 'entity_id', 'status', 'current_step_id', 'updated_at', 'completed_at'],
    'workflow_action': ['id', 'tenant_id', 'instance_id', 'action', 'acted_at'],
    'workflow_step': ['id', 'tenant_id', 'workflow_id', 'sequence_order', 'step_name', 'approver_type', 'approver_role_id',
                      'approver_permission', 'can_skip', 'sla_hours', 'created_at', 'updated_at'],
}
for _domain in ('leave', 'expense', 'attendance', 'payroll'):
    EMAIL_AUTHORITY_COLUMNS['hrms_company_' + _domain].update({table: {'select': list(columns)} for table, columns in _WORKFLOW_READS.items()})
_INSTALLATION_READS = {
    'organization_membership_installation': ['tenant_id', 'organization_id', 'membership_id', 'version', 'status'],
    'organization_grant_installation': ['tenant_id', 'binding_id', 'organization_id', 'membership_id', 'principal_id', 'grant_version', 'membership_version', 'status', 'capabilities'],
    'management_assignment': ['tenant_id', 'id', 'organization_id', 'membership_id', 'manager_principal_id', 'subject_employee_id',
                              'subject_principal_id', 'version', 'status', 'effective_from', 'effective_to'],
    'assignment_capability': ['tenant_id', 'assignment_id', 'capability_code'],
}
for _domain in ('leave', 'attendance', 'performance'):
    EMAIL_AUTHORITY_COLUMNS['hrms_company_' + _domain].update({table: {'select': list(columns)} for table, columns in _INSTALLATION_READS.items()})
_RESOURCE_READS = {
    'leave': {'leave_request': ['id', 'tenant_id', 'employee_id', 'status', 'updated_at', 'workflow_instance_id', 'is_deleted']},
    'expense': {
        'expense': ['id', 'tenant_id', 'employee_id', 'status', 'updated_at', 'workflow_instance_id', 'is_deleted'],
        'travel_request': ['id', 'tenant_id', 'employee_id', 'status', 'updated_at', 'workflow_instance_id']},
    'tax': {'tax_proof_line': ['id', 'tenant_id', 'employee_id', 'status', 'updated_at']},
    'employee': {'employee_profile_change_request': ['id', 'tenant_id', 'employee_id', 'requested_by', 'status', 'updated_at']},
    'attendance': {
        'timesheet_week_batch': ['id', 'tenant_id', 'employee_id', 'status', 'updated_at', 'workflow_instance_id'],
        'attendance': ['id', 'tenant_id', 'employee_id', 'status', 'regularization_status', 'updated_at', 'check_out_at', 'check_out_time']},
    'payroll': {
        'loan_request': ['id', 'tenant_id', 'employee_id', 'state', 'version', 'workflow_instance_id'],
        'payslip': ['id', 'tenant_id', 'employee_id', 'payroll_cycle_id', 'status', 'updated_at'],
        'payroll_cycle': ['id', 'tenant_id', 'status']},
    'performance': {
        'performance_participant': ['id', 'tenant_id', 'employee_id', 'review_cycle_id', 'manager_employee_id', 'response_revision',
                                    'updated_at', 'self_submitted_at', 'manager_submitted_at', 'is_excluded'],
        'review_cycle': ['id', 'tenant_id', 'current_stage', 'status', 'updated_at'],
        'goal': ['id', 'tenant_id', 'review_cycle_id', 'employee_id', 'status', 'weightage', 'updated_at'],
        'organization_review_manager': ['tenant_id', 'participant_id', 'principal_id', 'assignment_id', 'assignment_version']},
}
for _domain, _tables in _RESOURCE_READS.items():
    EMAIL_AUTHORITY_COLUMNS['hrms_company_' + _domain].update({table: {'select': list(columns)} for table, columns in _tables.items()})
for _domain in ('employee', 'leave', 'expense', 'attendance', 'payroll', 'tax', 'performance'):
    _columns = EMAIL_AUTHORITY_COLUMNS['hrms_company_' + _domain].setdefault('management_assignment', {'select': []})['select']
    for _column in ('id', 'tenant_id', 'subject_employee_id', 'manager_employee_id', 'relationship_type', 'status', 'effective_from', 'effective_to'):
        if _column not in _columns:
            _columns.append(_column)
EMAIL_AUTHORITY_COLUMNS['hrms_company_performance']['management_assignment']['select'].append('graph_version')

# The actual business scheduler runs under its own login. It receives only
# Performance selection/identity reads here; Attendance expiry already owns
# its existing business reads, and uses the shared identity projection.
EMAIL_AUTHORITY_COLUMNS['hrms_company_maintenance'] = deepcopy(EMAIL_AUTHORITY_COLUMNS['hrms_company_performance'])

# Logical metadata consumers. An operator must bind these profiles to the
# reviewed existing metadata login; no account name or production grant is
# guessed here. No address is stored or read from these metadata tables.
EMAIL_METADATA_READS = {
    'employment_ref': ['id', 'organization_id', 'organization_company_id', 'principal_id', 'source_tenant_id', 'source_employee_id', 'source_user_id', 'employment_status'],
    'principal': ['id', 'status'],
    'principal_login_link': ['principal_id', 'source_tenant_id', 'source_user_id', 'issuer', 'status'],
    'organization_company': ['id', 'organization_id', 'tenant_id', 'status', 'installed_version', 'version', 'runtime_status', 'effective_from', 'effective_to'],
    'organization': ['id', 'status'], 'tenant': ['id', 'status', 'is_deleted'],
    'principal_role_binding': ['id', 'organization_id', 'principal_id', 'version', 'status', 'role_id', 'effective_from', 'effective_to'],
    'organization_role': ['id', 'organization_id', 'status'],
    'organization_role_capability': ['role_id', 'organization_id', 'capability_code', 'employee_scope'],
    'role_binding_company': ['binding_id', 'organization_id', 'organization_company_id', 'activation_status', 'expected_grant_version'],
    'organization_relationship': ['id', 'organization_id', 'organization_company_id', 'manager_employment_ref_id', 'subject_employment_ref_id', 'version', 'installed_version', 'status', 'effective_from', 'effective_to', 'capabilities'],
}
EMAIL_METADATA_COLUMNS = {
    'kabipay-employee': deepcopy(EMAIL_METADATA_READS),
    'kabipay-organization': deepcopy(EMAIL_METADATA_READS),
}
EMAIL_METADATA_COLUMNS['kabipay-notification'] = {
    'tenant': ['id', 'name', 'status', 'is_deleted'],
}
EMAIL_METADATA_COLUMNS['kabipay-organization']['employment_ref'].append('department_id')
EMAIL_METADATA_COLUMNS['kabipay-organization']['organization_relationship'].append('relationship_type')
for _service in ('kabipay-leave', 'kabipay-attendance', 'kabipay-performance', 'kabipay-tenant-maintenance'):
    EMAIL_METADATA_COLUMNS[_service] = deepcopy(EMAIL_METADATA_COLUMNS['kabipay-organization'])


def grants_sql(schema):
    """Same explicit projections consumed by reviewed fresh/upgrade policies."""
    return _grants_sql(schema, EMAIL_COMPANY_COLUMNS)


def authority_grants_sql(schema):
    """Explicit existing-table reads for an owned rehearsal/reviewed installer."""
    return _grants_sql(schema, EMAIL_AUTHORITY_COLUMNS)


def metadata_grants_sql(role, service):
    """Render only a reviewed logical profile for an explicitly supplied login.

    Does not discover/create accounts, connect to a database or execute SQL.
    Production tooling must first bind the service profile to its real login.
    """
    if (not isinstance(role, str) or not re.fullmatch(r'[a-z_][a-z0-9_]{0,62}', role)
            or role in ('postgres', 'public', 'current_user', 'session_user')
            or role.startswith('pg_') or service not in EMAIL_METADATA_COLUMNS):
        raise ValueError('EMAIL_METADATA_PROFILE_INVALID')
    lines = [f'GRANT USAGE ON SCHEMA "kabipay_ops" TO "{role}";']
    for table, columns in EMAIL_METADATA_COLUMNS[service].items():
        projection = ','.join('"' + column + '"' for column in columns)
        lines.append(f'GRANT SELECT ({projection}) ON "kabipay_ops"."{table}" TO "{role}";')
    return '\n'.join(lines)


def _grants_sql(schema, contracts):
    if (not re.fullmatch(r'[a-z_][a-z0-9_]{0,62}', schema)
            or schema in ('public', 'kabipay_ops', 'information_schema')
            or schema.startswith('pg_')):
        raise ValueError('EMAIL_SCHEMA_INVALID')
    lines = []
    for role, tables in contracts.items():
        lines.append(f'GRANT USAGE ON SCHEMA "{schema}" TO "{role}";')
        for table, rights in tables.items():
            for operation, columns in rights.items():
                projection = '' if columns is True else ' (' + ','.join('"' + col + '"' for col in columns) + ')'
                lines.append(f'GRANT {operation.upper()}{projection} ON "{schema}"."{table}" TO "{role}";')
    return '\n'.join(lines)
