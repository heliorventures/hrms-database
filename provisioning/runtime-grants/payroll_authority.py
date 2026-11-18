"""Compile the fixed Payroll locking/hash interface. No I/O or SQL execution.

Internal table privileges belong only to the membership-free NOLOGIN company
owner. The runtime login gets EXECUTE on two tenant-bound functions, never those
table rights. An operator must separately bind the live catalog and review this
owner-authority expansion before installation.
"""
import re
from uuid import UUID
from policy import identifier, literal, require

INPUT_TABLES = (
    'company_payroll_rule', 'employee', 'employee_location_assignment',
    'employee_payroll_rule', 'employee_salary_component_override',
    'employee_salary_structure', 'employee_tax_declaration', 'employee_tax_history',
    'employee_tax_settings', 'holiday', 'holiday_calendar', 'leave_request',
    'leave_working_date_snapshot', 'leave_type', 'payroll_arrear', 'payroll_cycle',
    'payroll_period_input', 'payroll_unpaid_leave_allocation',
    'payroll_unpaid_leave_policy', 'payslip', 'payslip_component',
    'payslip_loan_snapshot', 'payslip_statement', 'salary_component',
    'salary_structure', 'salary_structure_component', 'tax_proof_line',
    'tax_configuration_version', 'weekly_off_policy_version', 'working_calendar_profile',
)
LOCK_TABLES = tuple(sorted((*INPUT_TABLES, 'payroll_draft_calculation')))
FUNCTIONS = ('hrms_lock_payroll_inputs_v1', 'hrms_payroll_input_fingerprint_v1')
PERIOD_LOCK_FUNCTION = 'hrms_lock_payroll_period_input_v1'
RUNTIME = 'hrms_company_payroll'
# Bound retained serialized input, not PostgreSQL's complete backend RSS. Initial
# production admission must measure capacity with substantial growth headroom.
MAX_PAYLOAD_BYTES = 32 * 1024 * 1024
PREFIX = 'payroll-draft-v2-reviewed-remuneration'


def validate_target(target):
    require(isinstance(target,dict) and set(target)=={'systemId','database','schema','tenantId','owner','sourceOwner'},'PAYROLL_AUTHORITY_TARGET_FIELDS')
    require(isinstance(target['systemId'],str) and re.fullmatch(r'[0-9]{1,20}',target['systemId']),'PAYROLL_AUTHORITY_CLUSTER_REQUIRED')
    for field in ('database','schema','owner','sourceOwner'):identifier(target[field])
    require(target['database'].startswith('company_') and target['schema'].startswith('tenant_'),'PAYROLL_AUTHORITY_ISOLATED_TARGET_REQUIRED')
    require(target['owner']==target['database']+'_owner' and target['owner']!=target['sourceOwner'],'PAYROLL_AUTHORITY_OWNER_INVALID')
    try:
        tenant=UUID(target['tenantId'])
    except (TypeError,ValueError,AttributeError):
        raise ValueError('PAYROLL_AUTHORITY_TENANT_INVALID') from None
    require(tenant.int!=0 and str(tenant)==target['tenantId'],'PAYROLL_AUTHORITY_TENANT_INVALID')


def _ownership(schema, table, tenant):
    return ('calendar_id IN (SELECT id FROM '+schema+'."holiday_calendar" WHERE tenant_id='+tenant+')'
            if table=='holiday' else 'tenant_id='+tenant)


def _serialized_bytes():
    # jsonb array text: two brackets plus ", " separators. UTF-8 bytes, not
    # character counts; compute row sizes without aggregating their contents.
    return ("COALESCE(pg_catalog.sum(pg_catalog.octet_length(pg_catalog.convert_to(pg_catalog.to_jsonb(t)::text,'UTF8'))),0)"
            '+CASE WHEN pg_catalog.count(*)=0 THEN 2 ELSE 2*pg_catalog.count(*) END')


def capacity_sql(target):
    """Read-only preinstallation measurement; return byte counts, never rows."""
    validate_target(target)
    schema=identifier(target['schema']);tenant=literal(target['tenantId'])+'::uuid'
    parts=["SELECT "+literal(table)+" AS name,"+_serialized_bytes()+' AS bytes FROM '+schema+'.'+identifier(table)
           +' t WHERE '+_ownership(schema,table,tenant) for table in INPUT_TABLES]
    fixed=len(PREFIX.encode('utf8'))+sum(len(table.encode('utf8'))for table in INPUT_TABLES)
    return ("WITH sizes AS ("+' UNION ALL '.join(parts)+") SELECT pg_catalog.jsonb_build_object('totalBytes',"
            +str(fixed)+"+pg_catalog.sum(bytes),'limitBytes',"+str(MAX_PAYLOAD_BYTES)
            +",'tables',pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('table',name,'bytes',bytes) ORDER BY name)) FROM sizes;")


def _bodies(target):
    validate_target(target)
    schema=identifier(target['schema']);tenant=literal(target['tenantId'])
    binding=("IF pg_catalog.current_database() <> "+literal(target['database'])+
             " OR p_tenant IS DISTINCT FROM "+tenant+"::uuid THEN\n"
             " RAISE EXCEPTION 'PAYROLL_AUTHORITY_TENANT_MISMATCH' USING ERRCODE='42501';\nEND IF;\n")
    lock='BEGIN\n'+binding+'LOCK TABLE '+','.join(schema+'.'+identifier(t)for t in LOCK_TABLES)+' IN SHARE ROW EXCLUSIVE MODE;\nEND'
    sizes=[];reads=[]
    for table in INPUT_TABLES:
        ownership=_ownership(schema,table,'p_tenant')
        sizes.append('SELECT '+_serialized_bytes()+' INTO v_rows_bytes FROM '+schema+'.'+identifier(table)+' t WHERE '+ownership+';\n'
                     'v_bytes := v_bytes + '+str(len(table.encode('utf8')))+' + v_rows_bytes;\n'
                     'IF v_bytes > '+str(MAX_PAYLOAD_BYTES)+" THEN RAISE EXCEPTION 'PAYROLL_SNAPSHOT_CAPACITY_EXCEEDED' USING ERRCODE='54000'; END IF;")
        reads.append("SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(t) ORDER BY pg_catalog.to_jsonb(t)::text),'[]'::jsonb)::text INTO v_rows FROM "+schema+'.'+identifier(table)+' t WHERE '+ownership+';\n'
                     'v_payload := v_payload || '+literal(table)+' || v_rows;')
    # STABLE sees the caller statement snapshot in both passes. Check the full
    # input capacity before materializing any array or cumulative payload.
    fingerprint=("DECLARE v_payload text := "+literal(PREFIX)+"; v_rows text; v_rows_bytes bigint; v_bytes bigint := "+str(len(PREFIX.encode('utf8')))+";\nBEGIN\n"+binding+
                 '\n'.join(sizes)+'\n'+'\n'.join(reads)+
                 "\nIF pg_catalog.octet_length(pg_catalog.convert_to(v_payload,'UTF8')) <> v_bytes THEN RAISE EXCEPTION 'PAYROLL_SNAPSHOT_CAPACITY_CHANGED'; END IF;"
                 "\nRETURN pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_payload,'UTF8')),'hex');\nEND")
    return (lock,fingerprint)


def _preserved_routine_predicate(target, preserved_routines):
    """Only the separately reviewed, trigger-only admin routine may coexist.

    A name alone never authorizes it: require its exact definition, fixed
    signature/settings, the authority owner and no callable external ACL.
    The compiler does not alter the existing routine or its trigger bindings.
    """
    require(isinstance(preserved_routines,(list,tuple)) and len(preserved_routines)<=1,
            'PAYROLL_AUTHORITY_PRESERVED_ROUTINE_SCOPE')
    if not preserved_routines:
        return 'false'
    routine=preserved_routines[0]
    require(isinstance(routine,dict) and set(routine)=={'name','definitionSha256'}
            and routine['name']=='organization_capture_admin_version',
            'PAYROLL_AUTHORITY_PRESERVED_ROUTINE_SCOPE')
    require(isinstance(routine['definitionSha256'],str)
            and re.fullmatch('[a-f0-9]{64}',routine['definitionSha256']),
            'PAYROLL_AUTHORITY_PRESERVED_ROUTINE_PIN')
    return ("(n.nspname="+literal(target['schema'])+" AND p.proname='organization_capture_admin_version'"
            " AND p.prokind='f' AND p.pronargs=0 AND p.prorettype='trigger'::regtype"
            " AND p.prosecdef AND p.proconfig=ARRAY['search_path=pg_catalog']::text[]"
            " AND encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')="+literal(routine['definitionSha256'])+
            " AND NOT EXISTS(SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a"
            " WHERE a.grantee<>p.proowner OR a.is_grantable))")


def prerequisite_sql(target, new_install=True, preserved_routines=(), include_period_lock=False):
    validate_target(target)
    s=literal(target['schema']);owner=literal(target['owner']);source=literal(target['sourceOwner'])
    tables=','.join(literal(t)for t in LOCK_TABLES)
    preserved=_preserved_routine_predicate(target,preserved_routines)
    helper_names=(*FUNCTIONS,PERIOD_LOCK_FUNCTION) if include_period_lock else FUNCTIONS
    helpers=("(n.nspname="+s+" AND p.proname IN ("+','.join(literal(f)for f in helper_names)+") AND p.prokind='f' AND p.pronargs=1 AND p.proargtypes='2950'::oidvector)"if not new_install else 'false')
    return ("""DO $payroll_prerequisites$ BEGIN
 IF current_database() <> """+literal(target['database'])+" OR (SELECT system_identifier::text FROM pg_control_system()) <> "+literal(target['systemId'])+""" THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_DATABASE_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles r JOIN pg_database d ON d.datdba=r.oid WHERE d.datname=current_database() AND r.rolname="""+owner+""" AND NOT(r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls)) OR EXISTS(SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid IN(m.roleid,m.member) WHERE r.rolname="""+owner+""" ) THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_OWNER_CHANGED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname='hrms_company_payroll' AND r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)) OR EXISTS(SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid IN(m.roleid,m.member) WHERE r.rolname='hrms_company_payroll') THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_RUNTIME_CHANGED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_namespace n WHERE n.nspname="""+s+' AND pg_get_userbyid(n.nspowner)='+source+""" ) OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='kabipay_ops' OR (nspname LIKE 'tenant\\_%' ESCAPE '\\' AND nspname<>"""+s+""")) THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_SCHEMA_CHANGED'; END IF;
 IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname="""+s+' AND c.relname IN ('+tables+") AND c.relkind='r' AND NOT(c.relrowsecurity OR c.relforcerowsecurity) AND pg_get_userbyid(c.relowner)="+source+") <> "+str(len(LOCK_TABLES))+""" THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_INPUT_RELATIONS_CHANGED'; END IF;
"""+ (" IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname="+s+" AND p.proname IN ("+','.join(literal(f)for f in FUNCTIONS)+")) THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_FUNCTION_EXISTS_REVIEW_REQUIRED'; END IF;" if new_install else '')+
    "\n IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE pg_get_userbyid(p.proowner)="+owner+
    ' AND NOT('+preserved+' OR '+helpers+')'+
    ") THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_OWNER_ROUTINES_CHANGED'; END IF;\n"
    +( " IF NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE pg_get_userbyid(p.proowner)="+owner+' AND '+preserved+") THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_PRESERVED_ROUTINE_CHANGED'; END IF;\n"if preserved_routines else '')+
    " IF EXISTS(SELECT 1 FROM pg_class c WHERE pg_get_userbyid(c.relowner)="+owner+
    ") THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_OWNER_RELATIONS_CHANGED'; END IF;\nEND $payroll_prerequisites$;")


def verify_sql(target, preserved_routines=(), include_period_lock=False):
    """Assert exact function source/configuration, owner, signature and callers."""
    validate_target(target)
    bodies=_bodies(target)
    owner=literal(target['owner']);schema=literal(target['schema'])
    tables=','.join(literal(t)for t in LOCK_TABLES)
    statements=["IF NOT has_schema_privilege("+owner+','+schema+",'USAGE') OR EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname="+schema+' AND c.relname IN ('+tables+") AND (NOT has_table_privilege("+owner+",c.oid,'UPDATE') OR (c.relname<>'payroll_draft_calculation' AND NOT has_table_privilege("+owner+",c.oid,'SELECT')))) THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_OWNER_PRIVILEGES_MISSING'; END IF;"]
    specifications=[(name,body,name==FUNCTIONS[0]) for name,body in zip(FUNCTIONS,bodies)]
    if include_period_lock:
        from monthly_input_authority import body as period_body
        specifications.append((PERIOD_LOCK_FUNCTION,period_body(target),True))
    for name,body,is_lock in specifications:
        config=['search_path=pg_catalog, pg_temp']+(['lock_timeout=15s']if is_lock else[])
        result='void'if is_lock else'text'
        volatility='v'if is_lock else's'
        statements.append("IF NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname="+literal(target['schema'])+' AND p.proname='+literal(name)+" AND p.prokind='f' AND p.pronargs=1 AND p.proargtypes='2950'::oidvector AND p.prorettype="+literal(result)+"::regtype AND p.prosecdef AND NOT p.proisstrict AND NOT p.proleakproof AND p.provolatile="+literal(volatility)+' AND p.proconfig=ARRAY['+','.join(literal(v)for v in config)+']::text[] AND pg_get_userbyid(p.proowner)='+literal(target['owner'])+' AND p.prosrc='+literal(body)+" AND has_function_privilege('hrms_company_payroll',p.oid,'EXECUTE') AND NOT EXISTS(SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee NOT IN(p.proowner,(SELECT oid FROM pg_roles WHERE rolname='hrms_company_payroll')) OR a.is_grantable)) THEN RAISE EXCEPTION 'PAYROLL_AUTHORITY_POSTCONDITION_FAILED'; END IF;")
    return prerequisite_sql(target,new_install=False,preserved_routines=preserved_routines,include_period_lock=include_period_lock)+'\nDO $payroll_verify$ BEGIN\n'+'\n'.join(statements)+'\nEND $payroll_verify$;'


def installation_statements(target, preserved_routines=()):
    """Fixed DDL/grants, for wrappers that hold their own atomic guards."""
    validate_target(target);schema=identifier(target['schema']);owner=identifier(target['owner'])
    lines=[prerequisite_sql(target,preserved_routines=preserved_routines),
           'GRANT USAGE ON SCHEMA '+schema+' TO '+owner+';']
    for table in INPUT_TABLES:lines.append('GRANT SELECT ON TABLE '+schema+'.'+identifier(table)+' TO '+owner+';')
    for table in LOCK_TABLES:lines.append('GRANT UPDATE ON TABLE '+schema+'.'+identifier(table)+' TO '+owner+';')
    for name,body in zip(FUNCTIONS,_bodies(target)):
        function=schema+'.'+identifier(name)
        result='void'if name==FUNCTIONS[0]else'text'
        volatility='VOLATILE'if name==FUNCTIONS[0]else'STABLE'
        lines.append('CREATE FUNCTION '+function+'(p_tenant uuid) RETURNS '+result+' LANGUAGE plpgsql '+volatility+' SECURITY DEFINER\nSET search_path = pg_catalog, pg_temp'+("\nSET lock_timeout = '15s'"if name==FUNCTIONS[0]else'')+'\nAS $payroll_body$'+body+'$payroll_body$;')
        lines.extend(['ALTER FUNCTION '+function+'(uuid) OWNER TO '+owner+';',
                      'REVOKE ALL ON FUNCTION '+function+'(uuid) FROM PUBLIC;',
                      'GRANT EXECUTE ON FUNCTION '+function+'(uuid) TO "hrms_company_payroll";'])
    return lines


def install_sql(target, preserved_routines=()):
    """New installation only. Existing/mixed state requires explicit readback."""
    return '\n'.join(["BEGIN; SET LOCAL lock_timeout='3s'; SET LOCAL statement_timeout='30s';",
        *installation_statements(target,preserved_routines),verify_sql(target,preserved_routines),'COMMIT;'])
