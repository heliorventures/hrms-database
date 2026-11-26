"""Compile an explicit runtime ACL contract; never infer grants from source text.

No environment, network, credentials or application data is read by this module.
Every identifier/column is supplied by a reviewed contract, never a wildcard.
"""
import hashlib
import json
import re
from copy import deepcopy
from business_columns import BUSINESS_COMPANY_COLUMNS
from private_ownership_columns import PRIVATE_OWNERSHIP_COLUMNS
from page_columns import PAGE_COMPANY_COLUMNS
from presentation_columns import PRESENTATION_COMPANY_COLUMNS
from calculation_columns import CALCULATION_COMPANY_COLUMNS
from draft_columns import DRAFT_COMPANY_COLUMNS
from email_columns import EMAIL_COMPANY_COLUMNS, EMAIL_AUTHORITY_COLUMNS


RESERVED_MAINTENANCE_DATABASES = frozenset({"postgres", "template0", "template1"})

# Reviewed caller requirements, not inferred grants. Guidance uses an INSERT
# with RETURNING id; RBAC loads these entity projections; performance's raw
# review summary also reads current_stage (absent from its ORM entity).
# Private ownership requirements cover the authenticated source handler's
# receipt read and its initial broker-ownership write, without identity writes.
REQUIRED_COMPANY_COLUMNS = {
    'hrms_company_employee': {
        **PAGE_COMPANY_COLUMNS['hrms_company_employee'],
        **PRIVATE_OWNERSHIP_COLUMNS['hrms_company_employee'],
        'actor_ref': {'select': ['tenant_id', 'principal_id', 'display_name']},
        'permission': {'select': ['id', 'resource', 'action', 'module_id',
                                  'description', 'created_at', 'updated_at']},
        'role_permission': {
            'select': ['role_id', 'permission_id', 'created_at'],
            'insert': ['role_id', 'permission_id', 'created_at'], 'delete': True},
        'permission_scope': {'select': ['id', 'tenant_id', 'role_id', 'resource',
                                        'action', 'scope_type', 'created_at'],
                             'insert': ['id', 'tenant_id', 'role_id', 'resource',
                                        'action', 'scope_type', 'created_at'], 'delete': True},
        'user_role': {'select': ['user_id', 'role_id', 'assigned_at'],
                      'insert': ['user_id', 'role_id', 'assigned_at'], 'delete': True},
        'user_guidance_state': {
            'select': ['id', 'tenant_id', 'user_id', 'overview_dismissed_at'],
            'insert': ['id', 'tenant_id', 'user_id']},
    },
    'hrms_company_payroll': {
        **PAGE_COMPANY_COLUMNS['hrms_company_payroll'],
        **PRESENTATION_COMPANY_COLUMNS['hrms_company_payroll'],
    },
    'hrms_company_notification': PRESENTATION_COMPANY_COLUMNS['hrms_company_notification'],
    'hrms_company_performance': PAGE_COMPANY_COLUMNS['hrms_company_performance'],
}

# Combine reviewed projections without mutating a separately approved compiler's
# source contract. Operator policies must explicitly include every requirement;
# validation never adds authority to a submitted policy.
REQUIRED_COMPANY_COLUMNS = deepcopy(REQUIRED_COMPANY_COLUMNS)
for _contract in (EMAIL_COMPANY_COLUMNS, EMAIL_AUTHORITY_COLUMNS):
    for _role, _tables in _contract.items():
        for _table, _rights in _tables.items():
            _target = REQUIRED_COMPANY_COLUMNS.setdefault(_role, {}).setdefault(_table, {})
            for _operation, _columns in _rights.items():
                if _columns is True:
                    _target[_operation] = True
                else:
                    _existing = _target.setdefault(_operation, [])
                    _existing.extend(column for column in _columns if column not in _existing)
for _role, _tables in {**CALCULATION_COMPANY_COLUMNS, 'hrms_company_payroll': {
        **CALCULATION_COMPANY_COLUMNS['hrms_company_payroll'],
        **DRAFT_COMPANY_COLUMNS['hrms_company_payroll']}}.items():
    for _table, _rights in _tables.items():
        _target = REQUIRED_COMPANY_COLUMNS.setdefault(_role, {}).setdefault(_table, {})
        for _operation, _columns in _rights.items():
            _existing = _target.setdefault(_operation, [])
            _existing.extend(column for column in _columns if column not in _existing)


def require(condition, code):
    if not condition:
        raise ValueError(code)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-z_][a-z0-9_]{0,62}", value), "INVALID_IDENTIFIER")
    require(not value.startswith("pg_") and value not in ("public", "information_schema"), "RESERVED_IDENTIFIER")
    return '"' + value + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_policy(policy):
    fields={"version", "systemId", "database", "allowedDatabases", "schema", "creators", "roles", "blockers"}
    require(isinstance(policy, dict) and fields<=set(policy)<=fields|{'rowSecurity'}, "INVALID_POLICY_FIELDS")
    require(type(policy["version"]) is int and policy["version"] == 1, "INVALID_POLICY_VERSION")
    require(isinstance(policy["systemId"], str) and re.fullmatch(r"[0-9]{1,20}", policy["systemId"]), "INVALID_SYSTEM_ID")
    identifier(policy["database"])
    require(policy["database"] not in RESERVED_MAINTENANCE_DATABASES, "RESERVED_MAINTENANCE_DATABASE")
    require(isinstance(policy["allowedDatabases"], list) and policy["database"] in policy["allowedDatabases"] and len(set(policy["allowedDatabases"])) == len(policy["allowedDatabases"]), "INVALID_DATABASE_ALLOWLIST")
    for database in policy["allowedDatabases"]:
        identifier(database)
        require(database not in RESERVED_MAINTENANCE_DATABASES, "RESERVED_MAINTENANCE_DATABASE")
    identifier(policy["schema"])
    require(isinstance(policy["creators"], list) and policy["creators"] and len(set(policy["creators"])) == len(policy["creators"]), "EXPLICIT_SCHEMA_CREATORS_REQUIRED")
    for creator in policy["creators"]:
        identifier(creator)
    require(policy["blockers"] == [], "UNRESOLVED_POLICY_BLOCKERS")
    require(isinstance(policy["roles"], dict) and 0 < len(policy["roles"]) <= 64, "INVALID_ROLE_SET")
    for role, permissions in policy["roles"].items():
        identifier(role)
        require(isinstance(permissions, dict) and set(permissions) == {"tables", "sequences", "functions"}, "INVALID_ROLE_POLICY")
        require(isinstance(permissions["tables"], dict), "INVALID_TABLE_POLICY")
        for table, rights in permissions["tables"].items():
            identifier(table)
            require(isinstance(rights, dict) and rights and set(rights) <= {"select", "insert", "update", "delete"}, "INVALID_TABLE_PRIVILEGES")
            for operation, columns in rights.items():
                if operation == "delete":
                    require(columns is True, "INVALID_DELETE_PRIVILEGE")
                else:
                    require(isinstance(columns, list) and columns and len(set(columns)) == len(columns), "EXPLICIT_COLUMNS_REQUIRED")
                    for column in columns:
                        identifier(column)
        require(isinstance(permissions["sequences"], list) and len(set(permissions["sequences"])) == len(permissions["sequences"]), "INVALID_SEQUENCE_POLICY")
        for sequence in permissions["sequences"]:
            identifier(sequence)
        require(isinstance(permissions["functions"], list), "INVALID_FUNCTION_POLICY")
        seen = set()
        for function in permissions["functions"]:
            require(isinstance(function, dict) and set(function) == {"name", "identityArguments", "definitionSha256", "owner", "securityDefiner", "ownerAuthoritySha256"}, "INVALID_FUNCTION_IDENTITY")
            identifier(function["name"])
            identifier(function["owner"])
            require(type(function["securityDefiner"]) is bool, "INVALID_FUNCTION_AUTHORITY")
            require(re.fullmatch(r"[0-9a-f]{64}", function["ownerAuthoritySha256"]) is not None, "INVALID_FUNCTION_OWNER_DIGEST")
            # Argument spelling must match pg_get_function_identity_arguments().
            # This text is used only in equality checks. DDL resolves an OID first.
            require(isinstance(function["identityArguments"], str) and len(function["identityArguments"]) < 2048 and re.fullmatch(r'[A-Za-z0-9_.,\[\]()" \t]*', function["identityArguments"]) is not None, "INVALID_FUNCTION_ARGUMENTS")
            require(re.fullmatch(r"[0-9a-f]{64}", function["definitionSha256"]) is not None, "INVALID_FUNCTION_DIGEST")
            key = (function["name"], function["identityArguments"])
            require(key not in seen, "DUPLICATE_FUNCTION_IDENTITY")
            seen.add(key)
    # reporting_display::current_managers joins the source actor's public label.
    # Refuse a built-in employee profile that omits this required projection.
    employee = policy["roles"].get("hrms_company_employee")
    if employee is not None:
        required = {"tenant_id", "principal_id", "display_name"}
        require(required <= set(employee["tables"].get("actor_ref", {}).get("select", [])), "EMPLOYEE_REPORTING_ACTOR_READ_MISSING")
    payroll = policy['roles'].get('hrms_company_payroll')
    if payroll is not None:
        user_reads = set(payroll['tables'].get('user', {}).get('select', []))
        require(not user_reads & {'password_hash', 'mfa_secret'},
                'PAYROLL_CREDENTIAL_READ_FORBIDDEN')
    for role, tables in list(REQUIRED_COMPANY_COLUMNS.items()) + list(BUSINESS_COMPANY_COLUMNS.items()):
        if role not in policy['roles']:
            continue
        actual = policy['roles'][role]['tables']
        for table, rights in tables.items():
            for operation, columns in rights.items():
                if operation == 'delete':
                    require(actual.get(table, {}).get(operation) is True,
                            'COMPANY_RUNTIME_RELATIONSHIP_DELETE_MISSING')
                else:
                    require(set(columns) <= set(actual.get(table, {}).get(operation, [])),
                            'COMPANY_RUNTIME_COLUMNS_MISSING')
    if payroll is not None:
        for name in ('hrms_lock_payroll_inputs_v1','hrms_payroll_input_fingerprint_v1','hrms_lock_payroll_period_input_v1'):
            require(any(function['name']==name and function['identityArguments']=='p_tenant uuid'
                        and function['owner']==policy['database']+'_owner'
                        and function['securityDefiner'] is True
                        for function in payroll['functions']),
                    'PAYROLL_INPUT_AUTHORITY_MISSING')
    validate_row_security(policy)
    return policy


def validate_row_security(policy):
    contracts=policy.get('rowSecurity',{})
    require(isinstance(contracts,dict)and len(contracts)<=64,'INVALID_ROW_SECURITY_CONTRACT')
    referenced={name for role in policy['roles'].values()for name in role['tables']}
    for table,definition in contracts.items():
        identifier(table)
        require(table in referenced and isinstance(definition,dict)and set(definition)=={'force','policies'}and type(definition['force'])is bool,'INVALID_ROW_SECURITY_CONTRACT')
        entries=definition['policies']
        require(isinstance(entries,list)and 0<len(entries)<=64,'EXPLICIT_ROW_SECURITY_POLICIES_REQUIRED')
        names=[]
        for entry in entries:
            require(isinstance(entry,dict)and set(entry)=={'name','command','permissive','roles','using','check'},'INVALID_ROW_SECURITY_POLICY')
            identifier(entry['name']);names.append(entry['name'])
            require(entry['command']in('*','r','a','w','d')and type(entry['permissive'])is bool,'INVALID_ROW_SECURITY_POLICY')
            roles=entry['roles']
            require(isinstance(roles,list)and roles and len(set(roles))==len(roles),'INVALID_ROW_SECURITY_ROLES')
            for role in roles:
                if role!='PUBLIC':identifier(role)
            for field in('using','check'):
                require(entry[field]is None or isinstance(entry[field],str)and 0<len(entry[field])<=16384,'INVALID_ROW_SECURITY_EXPRESSION')
        require(names==sorted(set(names)),'INVALID_ROW_SECURITY_POLICY_ORDER')


def check_row_security(policy,table,relation):
    wanted=policy.get('rowSecurity',{}).get(table)
    if wanted is None:
        require(relation.get('rowSecurity')is False,'UNREVIEWED_ROW_SECURITY')
    else:
        require(relation.get('rowSecurity')is True and relation.get('forceRowSecurity')is wanted['force']and relation.get('rowSecurityPolicies')==wanted['policies'],'ROW_SECURITY_POLICY_CHANGED')


def grant_sql(policy):
    validate_policy(policy)
    schema = identifier(policy["schema"])
    lines = []
    for role, permissions in sorted(policy["roles"].items()):
        quoted_role = identifier(role)
        lines.append(f'GRANT CONNECT ON DATABASE {identifier(policy["database"])} TO {quoted_role};')
        lines.append(f'GRANT USAGE ON SCHEMA {schema} TO {quoted_role};')
        for table, rights in sorted(permissions["tables"].items()):
            target = schema + "." + identifier(table)
            for operation, columns in sorted(rights.items()):
                privilege = operation.upper()
                if operation != "delete":
                    privilege += " (" + ", ".join(identifier(column) for column in columns) + ")"
                lines.append(f"GRANT {privilege} ON TABLE {target} TO {quoted_role};")
        for sequence in sorted(permissions["sequences"]):
            lines.append(f'GRANT USAGE ON SEQUENCE {schema}.{identifier(sequence)} TO {quoted_role};')
        for function in permissions["functions"]:
            # Never splice argument text as SQL. Resolve the exact catalog OID.
            lines.append("DO $grant_function$ DECLARE target oid; BEGIN SELECT p.oid INTO STRICT target FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=" + literal(policy["schema"]) + " AND p.proname=" + literal(function["name"]) + " AND pg_get_function_identity_arguments(p.oid)=" + literal(function["identityArguments"]) + " AND encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')=" + literal(function["definitionSha256"]) + "; EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',target::regprocedure," + literal(role) + "); END $grant_function$;")
    return "\n".join(lines)


def excess_privileges(policy, snapshot):
    validate_policy(policy)
    excess = []
    for entry in snapshot["access"]:
        rights = policy["roles"].get(entry["role"], {}).get("tables", {}).get(entry["table"], {})
        privilege = entry["privilege"].lower()
        allowed = entry["schema"] == policy["schema"] and not entry["grantOption"]
        if entry["column"] is None:
            allowed = allowed and privilege == "delete" and rights.get("delete") is True
        else:
            allowed = allowed and entry["column"] in rights.get(privilege, [])
        if not allowed:
            excess.append(entry)
    return excess


def check_snapshot(policy, state, *, complete=False):
    """Upper bound on all effective rights, including PUBLIC and grant options."""
    validate_policy(policy)
    require(set(state) == {"systemId", "database", "versionMajor", "roles", "memberships", "ownedObjects", "schemas", "databases", "relations", "functions", "access", "sequenceAccess", "functionAccess", "defaultAccess", "connections", "systemAccess", "authorities", "creators", "admissionBarrier"}, "INCOMPLETE_SECURITY_SNAPSHOT")
    require(state["systemId"] == policy["systemId"] and state["database"] == policy["database"] and state["versionMajor"] == "16", "WRONG_DATABASE_OR_CLUSTER")
    require(state["connections"] == 0, "DATABASE_OTHER_CONNECTIONS_PRESENT")
    require(state["admissionBarrier"]["allowConnections"] is False, "DATABASE_ADMISSION_BARRIER_REQUIRED")
    roles = {row["name"]: row for row in state["roles"]}
    require(set(roles) == set(policy["roles"]), "ROLE_BASELINE_CHANGED")
    for role in roles.values():
        require(role["canLogin"] is True and not any(role[key] for key in ("superuser", "createDb", "createRole", "inherit", "replication", "bypassRls")), "UNRESTRICTED_RUNTIME_ROLE")
    require(state["memberships"] == [] and state["ownedObjects"] == [], "ROLE_MEMBERSHIP_OR_OWNERSHIP")
    require(state["defaultAccess"] == [], "UNREVIEWED_DEFAULT_PRIVILEGES")
    require(state["systemAccess"] == [], "EXCESS_SYSTEM_OBJECT_PRIVILEGES")
    require({entry["name"] for entry in state["creators"]} == set(policy["creators"]), "SCHEMA_CREATOR_SET_CHANGED")
    require(not any(entry["functionPublicExecute"] or entry["functionRuntimeGrantees"] for entry in state["creators"]), "UNSAFE_EFFECTIVE_FUNCTION_DEFAULTS")
    require(not excess_privileges(policy, state), "EXCESS_EFFECTIVE_TABLE_PRIVILEGES")
    require(any(row["name"] == policy["schema"] for row in state["schemas"]), "MISSING_SCHEMA")
    for row in state["schemas"]:
        require(not row["create"] and not row["grantOption"], "UNEXPECTED_SCHEMA_PRIVILEGES")
        require(row["name"] == policy["schema"] or not row["usage"], "USAGE_OUTSIDE_APPROVED_SCHEMA")
    # A login is shared across the approved fleet. The contract records each
    # allowed CONNECT database explicitly in the external operator plan.
    for row in state["databases"]:
        require(not row["create"] and not row["temporary"] and not row["grantOption"], "UNEXPECTED_DATABASE_PRIVILEGES")
        require(not row["connect"] or row["name"] in policy["allowedDatabases"], "CONNECT_OUTSIDE_APPROVED_DATABASES")
    relations = {(row["schema"], row["name"]): row for row in state["relations"]}
    functions = {(row["schema"], row["name"], row["identityArguments"]): row for row in state["functions"]}
    for role, permissions in policy["roles"].items():
        for name, rights in permissions["tables"].items():
            relation = relations.get((policy["schema"], name))
            require(relation is not None and relation["kind"] in ("r", "p"), "MISSING_OR_UNREVIEWED_RELATION")
            check_row_security(policy,name,relation)
            columns = {column["name"] for column in relation["columns"]}
            for operation, wanted in rights.items():
                if operation != "delete":
                    require(set(wanted) <= columns, "POLICY_COLUMN_MISSING")
        for name in permissions["sequences"]:
            require((policy["schema"], name) in relations and relations[(policy["schema"], name)]["kind"] == "S", "POLICY_SEQUENCE_MISSING")
        for function in permissions["functions"]:
            actual = functions.get((policy["schema"], function["name"], function["identityArguments"]))
            require(actual is not None and actual["kind"] == "f" and all(actual[key] == function[key] for key in ("definitionSha256", "owner", "securityDefiner")), "FUNCTION_DEFINITION_OR_OWNER_CHANGED")
            require(owner_authority_digest(state, function["owner"]) == function["ownerAuthoritySha256"], "FUNCTION_OWNER_AUTHORITY_CHANGED")
    for row in state["sequenceAccess"]:
        require(row["schema"] == policy["schema"] and row["sequence"] in policy["roles"][row["role"]]["sequences"] and row["privilege"] == "USAGE" and not row["grantOption"], "EXCESS_SEQUENCE_PRIVILEGES")
    for row in state["functionAccess"]:
        allowed = policy["roles"][row["role"]]["functions"]
        require(not row["grantOption"] and row["schema"] == policy["schema"] and any(row["name"] == function["name"] and row["identityArguments"] == function["identityArguments"] and row["definitionSha256"] == function["definitionSha256"] for function in allowed), "UNREVIEWED_FUNCTION_EXECUTE")
    if complete:
        expected = set()
        for role, permissions in policy["roles"].items():
            for table, rights in permissions["tables"].items():
                for operation, columns in rights.items():
                    for column in ([None] if operation == "delete" else columns):
                        expected.add((role, policy["schema"], table, column, operation.upper()))
        actual = {(row["role"], row["schema"], row["table"], row["column"], row["privilege"]) for row in state["access"]}
        require(expected == actual, "REQUIRED_PRIVILEGES_MISSING")
        for role, permissions in policy["roles"].items():
            require(any(row["name"] == policy["schema"] and row["role"] == role and row["usage"] for row in state["schemas"]), "SCHEMA_USAGE_MISSING")
            require(any(row["name"] == policy["database"] and row["role"] == role and row["connect"] for row in state["databases"]), "DATABASE_CONNECT_MISSING")
            require({row["sequence"] for row in state["sequenceAccess"] if row["role"] == role} == set(permissions["sequences"]), "SEQUENCE_USAGE_MISSING")
            require({(row["name"], row["identityArguments"]) for row in state["functionAccess"] if row["role"] == role} == {(row["name"], row["identityArguments"]) for row in permissions["functions"]}, "FUNCTION_EXECUTE_MISSING")
    return state


def owner_authority_digest(state, name):
    # Full role graph is included because a function owner can SET ROLE or
    # inherit a chain; its effective authority is not only its own flags.
    owner = [row for row in state["authorities"]["roles"] if row["name"] == name]
    require(len(owner) == 1, "FUNCTION_OWNER_MISSING")
    return digest({"owner": owner[0], "roles": state["authorities"]["roles"], "memberships": state["authorities"]["memberships"], "objectAclSha256": state["authorities"]["objectAclSha256"]})
