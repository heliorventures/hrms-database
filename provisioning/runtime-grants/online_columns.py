"""Online additive correction of reviewed service column contracts.

Pure SQL compilation; no credentials, environment, connections or file writes.
It adds explicit columns and reviewed RBAC relationship DELETE privileges.
It cannot add table-wide SELECT/INSERT/UPDATE, schema/database access or roles.
Existing maintenance workflows remain separate and require their barrier.
"""
import json
import re
from policy import REQUIRED_COMPANY_COLUMNS, digest, identifier, literal, require


def validate_target(target):
    require(isinstance(target, dict) and set(target) == {'systemId', 'database', 'schema'},
            'ONLINE_COLUMNS_TARGET_INVALID')
    require(isinstance(target['systemId'], str) and re.fullmatch(r'[0-9]{1,20}', target['systemId']),
            'ONLINE_COLUMNS_CLUSTER_INVALID')
    require(re.fullmatch(r'company_[a-z0-9_]+', target['database']) and
            re.fullmatch(r'tenant_[a-z0-9_]+', target['schema']), 'ONLINE_COLUMNS_SCOPE_INVALID')
    identifier(target['database']); identifier(target['schema'])


def additions(requirements=REQUIRED_COMPANY_COLUMNS):
    return [(role, table, operation.upper(), column)
            for role, tables in sorted(requirements.items())
            for table, rights in sorted(tables.items())
            for operation, columns in sorted(rights.items())
            for column in ([None] if operation == 'delete' else sorted(columns))]


def snapshot_sql(target, requirements=REQUIRED_COMPANY_COLUMNS):
    validate_target(target)
    schema = literal(target['schema'])
    roles = ','.join(literal(role) for role in sorted(requirements))
    rows = ','.join('(' + ','.join('NULL::text' if v is None else literal(v) for v in row) + ')' for row in additions(requirements))
    # Mask only the exact non-grantable column additions, granted by the table
    # owner. Every other ACL, definition, owner, RLS policy and role is hashed.
    return """WITH wanted(role,rel,priv,col) AS (VALUES """ + rows + """),
    columns AS (
      SELECT c.oid,c.relname,a.attnum,a.attname,a.atttypid,a.atttypmod,a.attnotnull,
       a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid) AS expr,
       (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.grantor,x.grantee,x.privilege_type),'[]'::jsonb)
        FROM aclexplode(a.attacl) x WHERE NOT (NOT x.is_grantable AND x.grantor=c.relowner AND EXISTS(
         SELECT 1 FROM wanted w JOIN pg_roles r ON r.rolname=w.role
         WHERE w.rel=c.relname AND w.col=a.attname AND w.priv=x.privilege_type AND r.oid=x.grantee))) AS acl
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
      LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname=""" + schema + """
    ) SELECT jsonb_build_object(
     'database',current_database(),'systemId',(SELECT system_identifier::text FROM pg_control_system()),
     'open',(SELECT datallowconn FROM pg_database WHERE datname=current_database()),
     'restrictedRoles',(SELECT count(*)=""" + str(len(requirements)) + """ AND bool_and(rolcanlogin AND NOT(rolsuper OR rolcreatedb OR
      rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)) FROM pg_roles
      WHERE rolname IN(""" + roles + """)) AND NOT EXISTS(
       SELECT 1 FROM pg_roles r WHERE r.rolname IN(""" + roles + """) AND (
        EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid) OR
        EXISTS(SELECT 1 FROM pg_database d WHERE d.datdba=r.oid) OR
        EXISTS(SELECT 1 FROM pg_namespace n WHERE n.nspowner=r.oid) OR
        EXISTS(SELECT 1 FROM pg_class c WHERE c.relowner=r.oid) OR
        EXISTS(SELECT 1 FROM pg_proc p WHERE p.proowner=r.oid))),
     'required',(SELECT jsonb_agg(CASE WHEN w.col IS NULL THEN
      has_table_privilege(w.role,format('%I.%I',""" + schema + """,w.rel),w.priv)
      AND NOT has_table_privilege(w.role,format('%I.%I',""" + schema + """,w.rel),w.priv||' WITH GRANT OPTION') ELSE
      has_column_privilege(w.role,format('%I.%I',""" + schema + """,w.rel),w.col,w.priv)
      AND NOT has_column_privilege(w.role,format('%I.%I',""" + schema + """,w.rel),w.col,w.priv||' WITH GRANT OPTION') END
      ORDER BY w.role,w.rel,w.priv,w.col) FROM wanted w),
     'invariantsSha256',encode(sha256(convert_to(jsonb_build_object(
      'roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rolname) FROM pg_roles r),
      'memberships',(SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.roleid,m.member),'[]'::jsonb) FROM pg_auth_members m),
      'database',(SELECT to_jsonb(d)-'datfrozenxid'-'datminmxid' FROM pg_database d WHERE d.datname=current_database()),
      'schema',(SELECT to_jsonb(n) FROM pg_namespace n WHERE n.nspname=""" + schema + """),
      'relations',(SELECT jsonb_agg(jsonb_build_object('oid',c.oid,'name',c.relname,'kind',c.relkind,
       'owner',c.relowner,'acl',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.grantor,x.grantee,x.privilege_type),'[]'::jsonb)
        FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) x WHERE NOT(
         NOT x.is_grantable AND x.grantor=c.relowner AND EXISTS(SELECT 1 FROM wanted w
         JOIN pg_roles r ON r.rolname=w.role WHERE w.col IS NULL AND w.rel=c.relname
         AND w.priv=x.privilege_type AND r.oid=x.grantee))),
       'rls',c.relrowsecurity,'forced',c.relforcerowsecurity)
       ORDER BY c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=""" + schema + """),
      'columns',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.oid,c.attnum) FROM columns c),
      'policies',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.oid),'[]'::jsonb) FROM pg_policy p
       JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=""" + schema + """),
      'functions',(SELECT jsonb_agg(jsonb_build_object('oid',p.oid,'definition',pg_get_functiondef(p.oid),
       'owner',p.proowner,'acl',p.proacl) ORDER BY p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname=""" + schema + """ AND p.prokind IN('f','p')),
      'defaults',(SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.oid),'[]'::jsonb) FROM pg_default_acl d)
     )::text,'UTF8')),'hex'))"""


def guarded_sql(target, before, requirements=REQUIRED_COMPANY_COLUMNS):
    validate_target(target)
    require(isinstance(before, dict) and set(before) == {
        'database', 'systemId', 'open', 'restrictedRoles', 'required', 'invariantsSha256'},
        'ONLINE_COLUMNS_BASELINE_INVALID')
    require(before['database'] == target['database'] and before['systemId'] == target['systemId']
            and before['open'] is True and before['restrictedRoles'] is True,
            'ONLINE_COLUMNS_DATABASE_OR_ROLES_CHANGED')
    require(isinstance(before['required'], list) and len(before['required']) == len(additions(requirements))
            and all(type(v) is bool for v in before['required']) and
            re.fullmatch('[a-f0-9]{64}', before['invariantsSha256']), 'ONLINE_COLUMNS_BASELINE_INVALID')
    desired = dict(before, required=[True] * len(additions(requirements)))

    def guard(state, code):
        body = ('BEGIN IF (' + snapshot_sql(target, requirements) + ') IS DISTINCT FROM ' +
                literal(json.dumps(state, separators=(',', ':'))) + "::jsonb THEN RAISE EXCEPTION '" + code + "'; END IF; END")
        tag = '$online_columns_' + digest(body) + '$'
        require(tag not in body, 'ONLINE_COLUMNS_UNSAFE_DELIMITER')
        return 'DO ' + tag + ' ' + body + ' ' + tag + ';'

    schema = identifier(target['schema'])
    tables = sorted({table for _, table, _, _ in additions(requirements)})
    grants = ['GRANT ' + privilege + (' (' + identifier(column) + ')' if column is not None else '') + ' ON TABLE ' + schema + '.' +
              identifier(table) + ' TO ' + identifier(role) + ';'
              for role, table, privilege, column in additions(requirements)]
    return '\n'.join([
        'BEGIN;', 'SET LOCAL search_path=pg_catalog;', 'SET LOCAL standard_conforming_strings=on;',
        "SET LOCAL lock_timeout='3s';", "SET LOCAL statement_timeout='30s';",
        "SELECT pg_advisory_xact_lock(hashtextextended('hrms-runtime-grants:'||current_database(),0));",
        'LOCK TABLE ' + ','.join(schema+'.'+identifier(table) for table in tables) + ' IN ACCESS SHARE MODE;',
        guard(before, 'ONLINE_COLUMNS_BASELINE_CHANGED'), *grants,
        guard(desired, 'ONLINE_COLUMNS_POSTCONDITION_FAILED'), 'COMMIT;'])
