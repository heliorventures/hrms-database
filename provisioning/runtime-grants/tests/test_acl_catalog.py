import importlib.util
from pathlib import Path
import sys
import unittest

HERE=Path(__file__).parents[1]
sys.path.insert(0,str(HERE))
import acl_catalog


def target():
    return {"version":1,"systemId":"1234","database":"company_fixture","schema":"tenant_fixture","allowedDatabases":["company_fixture"],"roles":["runtime_employee"]}


class AclCatalogTests(unittest.TestCase):
    def test_explicit_metadata_acl_schemas_do_not_broaden_runtime_query_policy(self):
        request=dict(target(),aclSchemas=['public','tenant_fixture','retained_company'])
        compiled=acl_catalog.snapshot_sql(request)
        self.assertIn("ARRAY['public','retained_company','tenant_fixture']::text[]",compiled)
        self.assertNotIn('__ACL_SCHEMAS__',compiled)
        self.assertNotIn('aclSchemas',acl_catalog.query_policy(request))

    def test_acl_schema_scope_rejects_duplicates_system_schemas_and_omitted_primary(self):
        for scopes in [['public','tenant_fixture','tenant_fixture'],['public','pg_catalog','tenant_fixture'],['public','other'],[],['public','tenant_fixture','bad;schema']]:
            with self.subTest(scopes=scopes),self.assertRaises(ValueError):acl_catalog.snapshot_sql(dict(target(),aclSchemas=scopes))

    def test_query_collects_exact_acl_origins_and_extension_dependencies(self):
        query=getattr(acl_catalog,"snapshot_sql",lambda _: "")(target())
        for required in ("pg_extension","pg_depend","aclexplode","acldefault","pg_default_acl","pg_roles","pg_control_system","pg_get_function_identity_arguments"):
            self.assertIn(required,query)
        self.assertNotIn("rolpassword",query.lower())
        self.assertNotRegex(query.lower(),r"\b(?:from|join)\s+(?:pg_catalog\.)?pg_authid\b")
        self.assertNotIn("prosrc",query.lower())
        self.assertNotIn("password_hash",query.lower())

    def test_invalid_or_control_target_is_refused_before_query_compilation(self):
        compiler=getattr(acl_catalog,"snapshot_sql",lambda _: "")
        for field,value in (("database","postgres"),("schema","tenant; SELECT 1"),("systemId","0")):
            request=target();request[field]=value
            if field=="database":request["allowedDatabases"]=[value]
            with self.assertRaises(ValueError):compiler(request)

    def test_snapshot_requires_exact_identity_and_closed_admission(self):
        validate=getattr(acl_catalog,"validate_snapshot",lambda *_: None)
        state={"purpose":"exact_acl_catalog_only_not_correction_plan","systemId":"1234","database":"company_fixture","versionMajor":"16","admissionBarrier":{"allowConnections":False,"connectionLimit":-1},"connections":0,"runtimeRoles":["runtime_employee"],"functions":[],"schemas":[],"defaultPrivileges":[],"creatorDefaults":[],"extensions":[],"authorities":{"roles":[],"memberships":[],"untouchedAclSha256":"a"*64},"catalogInvariantSha256":"b"*64}
        for field,value in (("systemId","999"),("connections",1),("versionMajor","17")):
            wrong=dict(state);wrong[field]=value
            with self.assertRaises(ValueError):validate(target(),wrong)
        with self.assertRaises(ValueError):validate(target(),dict(state,admissionBarrier={"allowConnections":True,"connectionLimit":-1}))
        self.assertEqual(validate(target(),state),state)


if __name__=="__main__":unittest.main()
