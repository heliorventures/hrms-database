"""Fixed period-input lock authority; extends, never replaces, the two helpers.

Pure compilation only. The previously installed company owner already has the
required internal table right. Payroll receives no table-wide write privilege.
"""
import payroll_authority as authority
from policy import identifier, literal

NAME=authority.PERIOD_LOCK_FUNCTION

def body(target):
    authority.validate_target(target)
    return ("BEGIN\nIF pg_catalog.current_database() <> "+literal(target['database'])+
            " OR p_tenant IS DISTINCT FROM "+literal(target['tenantId'])+"::uuid THEN\n"
            " RAISE EXCEPTION 'PAYROLL_AUTHORITY_TENANT_MISMATCH' USING ERRCODE='42501';\nEND IF;\n"
            'LOCK TABLE '+identifier(target['schema'])+'."payroll_period_input" IN ROW EXCLUSIVE MODE;\nEND')

def installation_statements(target,preserved_routines=()):
    authority.validate_target(target)
    schema=identifier(target['schema']);function=schema+'.'+identifier(NAME)
    return [
        "DO $monthly_new$ BEGIN IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname="+literal(target['schema'])+' AND p.proname='+literal(NAME)+") THEN RAISE EXCEPTION 'MONTHLY_INPUT_FUNCTION_EXISTS_REVIEW_REQUIRED'; END IF; END $monthly_new$;",
        authority.verify_sql(target,preserved_routines),
        'CREATE FUNCTION '+function+'(p_tenant uuid) RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER\nSET search_path = pg_catalog, pg_temp\nSET lock_timeout = \'15s\'\nAS $monthly_body$'+body(target)+'$monthly_body$;',
        'ALTER FUNCTION '+function+'(uuid) OWNER TO '+identifier(target['owner'])+';',
        'REVOKE ALL ON FUNCTION '+function+'(uuid) FROM PUBLIC;',
        'GRANT EXECUTE ON FUNCTION '+function+'(uuid) TO "hrms_company_payroll";',
    ]

def verify_sql(target,preserved_routines=()):
    return authority.verify_sql(target,preserved_routines,include_period_lock=True)

def install_sql(target,preserved_routines=()):
    return '\n'.join(["BEGIN; SET LOCAL search_path=pg_catalog; SET LOCAL lock_timeout='3s'; SET LOCAL statement_timeout='30s';",
                      *installation_statements(target,preserved_routines),verify_sql(target,preserved_routines),'COMMIT;'])
