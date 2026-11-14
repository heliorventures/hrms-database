"""Bounded native fixture from selected migration DDL, not from grant columns.

This is an ACL operation rehearsal, not a complete Liquibase deployment. It
retains selected column defaults, nullability, keys, workflow FKs and triggers.
Cross-domain parent records are synthetic and contain no application data.
"""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(DIRECTORY))
from business_columns import BUSINESS_COMPANY_COLUMNS

MIGRATIONS = DIRECTORY.parents[1] / 'changelog/migrations'
NS = {'l': 'http://www.liquibase.org/xml/ns/dbchangelog'}
SCHEMA = 'tenant_fixture'


def quoted(value):
    return '"' + value + '"'


def tree(name):
    return ET.parse(MIGRATIONS / name).getroot()


def column_sql(column):
    result = quoted(column.attrib['name']) + ' ' + column.attrib['type']
    constraints = column.find('l:constraints', NS)
    if constraints is not None:
        if constraints.get('nullable') == 'false':
            result += ' NOT NULL'
        if constraints.get('primaryKey') == 'true':
            result += ' PRIMARY KEY'
    for attribute in ['defaultValueComputed', 'defaultValueBoolean', 'defaultValueNumeric']:
        if attribute in column.attrib:
            result += ' DEFAULT ' + column.attrib[attribute]
    if 'defaultValue' in column.attrib:
        result += " DEFAULT '" + column.attrib['defaultValue'].replace("'", "''") + "'"
    return result


def fixture_sql():
    columns = {}
    raw = '\n'.join(''.join(n.itertext()) for n in tree('0129_company_database_dependencies/company_database_dependencies.xml').findall('l:changeSet/l:sql', NS))
    timestamp_function = re.search(r'CREATE FUNCTION "\$\{schema\}"\.set_updated_at\(\)[\s\S]*?END \$updated\$;', raw)
    assert timestamp_function
    sql = ['CREATE SCHEMA tenant_fixture;',
           timestamp_function[0].replace('${schema}', SCHEMA),
           'REVOKE ALL ON SCHEMA public FROM PUBLIC;',
           'CREATE TABLE tenant_fixture.payslip(tenant_id uuid,id uuid,PRIMARY KEY(tenant_id,id));']
    files = {
        '0017_onboarding_offboarding/onboarding_offboarding.xml': ['onboarding_checklist', 'separation', 'clearance_checklist'],
        '0050_employee_self_service/employee_self_service.xml': ['employee_profile_change_request'],
        '0027_communication_audit/communication_audit.xml': ['notification'],
        '0106_loan_exit_coordination/loan_exit_coordination.xml': ['employee_exit_operation'],
        '0025_workflow/workflow.xml': ['workflow', 'workflow_step', 'workflow_instance', 'workflow_action'],
        '0029_file_storage/file_storage.xml': ['file_storage'],
        '0005_auth_rbac/auth_rbac.xml': ['user'],
        '0103_employee_loans/employee_loans.xml': ['loan_request'],
    }
    for name, selected in files.items():
        root = tree(name)
        for table in root.findall('l:changeSet/l:createTable', NS):
            table_name = table.get('tableName')
            if table_name in selected:
                columns[table_name] = {c.get('name') for c in table.findall('l:column', NS)}
                sql.append('CREATE TABLE tenant_fixture.' + quoted(table_name) + '(' +
                           ','.join(column_sql(c) for c in table.findall('l:column', NS)) + ');')
        for node in root.findall('l:changeSet/l:sql', NS):
            raw = ''.join(node.itertext()).replace('${schema}', SCHEMA)
            if raw.strip().startswith('CREATE TRIGGER') and any('.' + name + ' ' in raw for name in selected):
                # 0129 retargets the legacy timestamp triggers to this exact
                # tenant-local function before isolated company provisioning.
                sql.append(raw.replace('kabipay_ops.set_updated_at()', 'tenant_fixture.set_updated_at()'))
        for fk in root.findall('l:changeSet/l:addForeignKeyConstraint', NS):
            if fk.get('baseTableName') in selected and fk.get('referencedTableName') in selected:
                sql.append('ALTER TABLE tenant_fixture.' + quoted(fk.get('baseTableName')) +
                           ' ADD FOREIGN KEY(' + fk.get('baseColumnNames') + ') REFERENCES tenant_fixture.' +
                           quoted(fk.get('referencedTableName')) + '(' + fk.get('referencedColumnNames') + ');')
    for name, table in [
        ('0051_employee_self_service_readiness/employee_self_service_readiness.xml', 'employee_profile_change_request'),
        ('0064_approval_integrity/approval_integrity.xml', 'workflow_step'),
        ('0066_lifecycle_validation_integrity/lifecycle_validation_integrity.xml', 'separation'),
    ]:
        for node in tree(name).findall('l:changeSet/l:addColumn', NS):
            if node.get('tableName') == table:
                for column in node.findall('l:column', NS):
                    columns[table].add(column.get('name'))
                    sql.append('ALTER TABLE tenant_fixture.' + table + ' ADD COLUMN ' + column_sql(column) + ';')
    sql += ['ALTER TABLE tenant_fixture.separation ADD COLUMN approved_by_principal_id uuid;',
            'ALTER TABLE tenant_fixture.clearance_checklist ADD COLUMN cleared_by_principal_id uuid;']
    columns['separation'].add('approved_by_principal_id')
    columns['clearance_checklist'].add('cleared_by_principal_id')
    raw = ''.join(tree('0077_unpaid_leave_payroll/unpaid_leave_payroll.xml').find('l:changeSet/l:sql', NS).itertext())
    unpaid = re.search(r'CREATE TABLE "\$\{schema\}"\.payslip_unpaid_leave \([\s\S]*?\n\);', raw)
    assert unpaid
    columns['payslip_unpaid_leave'] = set(re.findall(r'^\s+([a-z_]+) (?:UUID|VARCHAR|NUMERIC|JSONB|TIMESTAMPTZ)', unpaid[0], re.M))
    sql.append(unpaid[0].replace('${schema}', SCHEMA))
    raw = '\n'.join(''.join(n.itertext()) for n in tree('0106_loan_exit_coordination/loan_exit_coordination.xml').findall('l:changeSet/l:sql', NS))
    trigger = re.search(r'CREATE FUNCTION "\$\{schema\}"\.guard_hr_finance_operation\(\)[\s\S]*?CREATE TRIGGER guard_hr_finance_operation[\s\S]*?;', raw)
    assert trigger
    sql.append(trigger[0].replace('${schema}', SCHEMA))
    sql.append('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA tenant_fixture FROM PUBLIC;')
    for role, tables in BUSINESS_COMPANY_COLUMNS.items():
        for table, rights in tables.items():
            for operation, names in rights.items():
                assert set(names) <= columns[table], (role, table, operation, set(names) - columns[table])
    return '\n'.join(sql)


if __name__ == '__main__':
    print(json.dumps({'sql': fixture_sql(), 'requirements': BUSINESS_COMPANY_COLUMNS}))
