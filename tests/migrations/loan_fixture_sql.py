"""Translate the loan migration's supported Liquibase elements for isolated PG tests.

This does not replace Liquibase validation or authorize live migration.
"""
from pathlib import Path
import xml.etree.ElementTree as ET

NS = '{http://www.liquibase.org/xml/ns/dbchangelog}'
ROOT = Path(__file__).resolve().parents[2]

def migration_sql(file):
    result = []
    for change in ET.parse(ROOT / file).getroot().findall(NS + 'changeSet'):
        for node in change:
            name = node.tag.removeprefix(NS)
            a = node.attrib
            schema = a.get('schemaName', a.get('baseTableSchemaName', '${schema}'))
            if name == 'createTable':
                columns = []
                for column in node:
                    c = column.attrib
                    constraint = column.find(NS + 'constraints')
                    flags = constraint.attrib if constraint is not None else {}
                    declaration = f'"{c["name"]}" {c["type"]}'
                    if flags.get('nullable') == 'false': declaration += ' NOT NULL'
                    if flags.get('primaryKey') == 'true': declaration += ' PRIMARY KEY'
                    if 'defaultValueComputed' in c: declaration += ' DEFAULT ' + c['defaultValueComputed']
                    columns.append(declaration)
                result.append(f'CREATE TABLE "{schema}".{a["tableName"]} (' + ','.join(columns) + ');')
            elif name == 'addUniqueConstraint':
                result.append(f'ALTER TABLE "{schema}".{a["tableName"]} ADD CONSTRAINT {a["constraintName"]} UNIQUE({a["columnNames"]});')
            elif name == 'addForeignKeyConstraint':
                result.append(f'ALTER TABLE "{schema}".{a["baseTableName"]} ADD CONSTRAINT {a["constraintName"]} FOREIGN KEY({a["baseColumnNames"]}) REFERENCES "{a["referencedTableSchemaName"]}".{a["referencedTableName"]}({a["referencedColumnNames"]}) ON DELETE {a.get("onDelete","NO ACTION")} DEFERRABLE INITIALLY DEFERRED;')
            elif name == 'sql': result.append(node.text or '')
            elif name not in ('comment','rollback','preConditions'): raise ValueError(f'unsupported Liquibase test element: {name}')
    return '\n'.join(result).replace('${schema}', 'loan_test')

if __name__ == '__main__':
    print('\\set ON_ERROR_STOP on\nBEGIN;\nCREATE SCHEMA loan_test;\nCREATE TABLE loan_test.employee(id UUID PRIMARY KEY,tenant_id UUID NOT NULL);')
    print(migration_sql('changelog/migrations/0103_employee_loans/employee_loans.xml'))
    print('COMMIT;')
