import copy
import importlib.util
import json
from pathlib import Path
import unittest
import sys

sys.path.insert(0, str(Path(__file__).parents[1]))

spec = importlib.util.spec_from_file_location("policy", Path(__file__).parents[1] / "policy.py")
policy_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy_module)


def contract():
    return {"version": 1, "systemId": "1234", "database": "company_fixture", "allowedDatabases": ["company_fixture"],
            "schema": "tenant_fixture", "creators": ["fixture_owner"], "roles": {"runtime_employee": {
                "tables": {"user": {"select": ["id", "tenant_id", "is_active", "is_deleted"]},
                           "employee": {"select": ["id", "name"], "update": ["name"]}},
                "sequences": [], "functions": []}}, "blockers": []}


def payroll_function_contracts():
    # Synthetic descriptors only. Live policies bind real source and owner-graph
    # digests from the reviewed installed catalog; never reuse these fixtures.
    return [dict(name=name,identityArguments='p_tenant uuid',definitionSha256='a'*64,
                 owner='company_fixture_owner',securityDefiner=True,ownerAuthoritySha256='b'*64)
            for name in ('hrms_lock_payroll_inputs_v1','hrms_payroll_input_fingerprint_v1','hrms_lock_payroll_period_input_v1')]


def company_tables(role):
    """Complete synthetic fixture union; never infer a submitted policy's rights."""
    tables = {}
    for contract in (policy_module.REQUIRED_COMPANY_COLUMNS, policy_module.BUSINESS_COMPANY_COLUMNS):
        for table, rights in contract.get(role, {}).items():
            target = tables.setdefault(table, {})
            for operation, columns in rights.items():
                if columns is True:
                    target[operation] = True
                else:
                    values = target.setdefault(operation, [])
                    values.extend(column for column in columns if column not in values)
    return tables


class PolicyTests(unittest.TestCase):
    def test_builtin_employee_profile_requires_actual_reporting_label_projection(self):
        candidate = contract()
        candidate["roles"]["hrms_company_employee"] = candidate["roles"].pop("runtime_employee")
        actor = {"select": ["tenant_id", "principal_id", "identity_version"]}
        candidate["roles"]["hrms_company_employee"]["tables"]["actor_ref"] = actor
        with self.assertRaisesRegex(ValueError, "EMPLOYEE_REPORTING_ACTOR_READ_MISSING"):
            policy_module.validate_policy(candidate)
        actor["select"].append("display_name")
        candidate["roles"]["hrms_company_employee"]["tables"].update(company_tables('hrms_company_employee'))
        policy_module.validate_policy(candidate)
    def test_pinned_information_schema_includes_explicit_on_table_grants(self):
        baseline = json.loads((Path(__file__).parents[1] / "system-baseline.json").read_text())
        self.assertIn("foreign_server_options", baseline["publicSelectRelations"])
        self.assertIn("foreign_table_options", baseline["publicSelectRelations"])

    def test_sql_only_grants_exact_columns_to_exact_roles(self):
        sql = policy_module.grant_sql(contract())
        self.assertIn('GRANT SELECT ("id", "tenant_id", "is_active", "is_deleted") ON TABLE "tenant_fixture"."user" TO "runtime_employee";', sql)
        self.assertNotIn("ALL TABLES", sql)
        self.assertNotIn("PASSWORD", sql)

    def test_unresolved_or_broad_privileges_are_rejected(self):
        for mutate in [lambda p: p["roles"]["runtime_employee"]["tables"]["user"].update(select=True),
                       lambda p: p.update(blockers=["missing trigger closure"]),
                       lambda p: p.update(database='company_fixture"; RESET ROLE;'),
                       lambda p: p["roles"]["runtime_employee"].update(unknown="ignored")]:
            policy = contract()
            mutate(policy)
            with self.assertRaises(ValueError):
                policy_module.validate_policy(policy)

    def test_control_and_template_databases_are_rejected_in_policy(self):
        for reserved in ("postgres", "template0", "template1"):
            for allowed_only in (False, True):
                candidate = contract()
                candidate["allowedDatabases"].append(reserved)
                if not allowed_only:
                    candidate["database"] = reserved
                with self.assertRaisesRegex(ValueError, "RESERVED_MAINTENANCE_DATABASE"):
                    policy_module.validate_policy(candidate)

    def test_extra_secret_column_and_table_level_select_are_excess(self):
        for access in [{"role": "runtime_employee", "schema": "tenant_fixture", "table": "user", "column": "password_hash", "privilege": "SELECT", "grantOption": False},
                       {"role": "runtime_employee", "schema": "tenant_fixture", "table": "employee", "column": None, "privilege": "SELECT", "grantOption": False}]:
            self.assertEqual(policy_module.excess_privileges(contract(), {"access": [access]}), [access])

    def test_allowed_column_access_is_preserved_but_grant_option_is_denied(self):
        access = {"role": "runtime_employee", "schema": "tenant_fixture", "table": "employee", "column": "name", "privilege": "UPDATE", "grantOption": False}
        self.assertEqual(policy_module.excess_privileges(contract(), {"access": [access]}), [])
        access["grantOption"] = True
        self.assertEqual(policy_module.excess_privileges(contract(), {"access": [access]}), [access])

    def test_function_identity_cannot_terminate_operator_sql_body(self):
        policy = contract()
        policy["roles"]["runtime_employee"]["functions"] = [{"name": "checked_function", "identityArguments": "$grant_function$; SELECT 1; --", "definitionSha256": "a" * 64, "owner": "fixture_owner", "securityDefiner": False, "ownerAuthoritySha256": "b" * 64}]
        with self.assertRaises(ValueError):
            policy_module.validate_policy(policy)

    def test_function_owner_authority_includes_nonruntime_object_acl_changes(self):
        state = {"authorities": {"roles": [{"name": "definer_owner"}], "memberships": [], "objectAclSha256": "a" * 64}}
        original = policy_module.owner_authority_digest(state, "definer_owner")
        state["authorities"]["objectAclSha256"] = "b" * 64
        self.assertNotEqual(original, policy_module.owner_authority_digest(state, "definer_owner"))


if __name__ == "__main__":
    unittest.main()
