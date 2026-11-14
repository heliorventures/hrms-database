import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import acl_corrections as corrections


def fixture():
    target = dict(version=1, systemId='1234', database='company_fixture', schema='tenant_fixture', allowedDatabases=['company_fixture'], roles=['runtime_employee'])
    owner = dict(grantor='fixture_owner', grantee='fixture_owner', privilege='EXECUTE', grantOption=False)
    public = dict(owner, grantee='PUBLIC')
    function = dict(oid=123, schema='tenant_fixture', name='helper', kind='f', identityArguments='p integer', owner='fixture_owner', language='sql', securityDefiner=False, definitionSha256='a'*64, aclExplicit=False, acl=[public, owner], extension=None, dependents=[])
    creator = dict(owner='fixture_owner', schema='tenant_fixture', globalExplicit=False, globalAcl=[public, owner], schemaExplicit=False, schemaAcl=[])
    state = dict(purpose='exact_acl_catalog_only_not_correction_plan', systemId='1234', database='company_fixture', versionMajor='16', admissionBarrier=dict(allowConnections=False, connectionLimit=-1), connections=0, runtimeRoles=['runtime_employee'], functions=[function], schemas=[dict(oid=456,name='public',owner='pg_database_owner',aclExplicit=True,acl=[dict(grantor='pg_database_owner',grantee='PUBLIC',privilege='USAGE',grantOption=False)])], defaultPrivileges=[], creatorDefaults=[creator], extensions=[], authorities=dict(roles=[dict(name='runtime_employee',login=True,inherit=False,superuser=False,createDb=False,createRole=False,replication=False,bypassRls=False)], memberships=[],untouchedAclSha256='b'*64), catalogInvariantSha256='c'*64)
    operations=[dict(kind='function_public_execute',oid=123),dict(kind='schema_public_usage',name='public'),dict(kind='function_public_default',owner='fixture_owner',schema=None)]
    return target,state,operations


class CorrectionsTests(unittest.TestCase):
    def test_retained_schema_function_reduction_requires_explicit_scope(self):
        target,state,_=fixture();state['functions'][0]['schema']='retained_company'
        operations=[dict(kind='function_public_execute',oid=123)]
        with self.assertRaisesRegex(ValueError,'FUNCTION_CORRECTION_TARGET_CHANGED'):corrections.prepare(target,state,operations)
        target['aclSchemas']=['public','tenant_fixture','retained_company']
        state['schemas'].extend(dict(oid=oid,name=name,owner='fixture_owner',aclExplicit=True,acl=[])for oid,name in[(457,'tenant_fixture'),(458,'retained_company')])
        plan=corrections.prepare(target,state,operations)
        self.assertEqual([a['grantee']for a in corrections.expected_after(plan)['functions'][0]['acl']],['fixture_owner'])
        self.assertIn('RESTRICT',corrections.guarded_sql(plan))

    def test_expected_removes_only_reviewed_public_rights(self):
        target,state,operations=fixture()
        other=dict(grantor='fixture_owner',grantee='unrelated',privilege='EXECUTE',grantOption=True)
        state['functions'][0]['acl'].append(other)
        plan=corrections.prepare(target,state,operations)
        after=corrections.expected_after(plan)
        self.assertIn(other,after['functions'][0]['acl'])
        self.assertNotIn('PUBLIC',[a['grantee'] for a in after['functions'][0]['acl']])
        self.assertEqual(after['schemas'][0]['acl'],[])
        self.assertEqual(after['authorities'],state['authorities'])
        self.assertEqual(after['catalogInvariantSha256'],state['catalogInvariantSha256'])
        self.assertTrue(after['creatorDefaults'][0]['globalExplicit'])
        self.assertEqual(len(after['defaultPrivileges']),1)
        self.assertEqual(state['functions'][0]['acl'][0]['grantee'],'PUBLIC')

    def test_rejects_unreviewed_targets_duplicates_or_grantor_chains(self):
        target,state,operations=fixture()
        cases=[operations+[operations[0]], [dict(kind='function_public_execute',oid=999)], [dict(kind='schema_public_usage',name='pg_catalog')], [dict(kind='function_public_default',owner='missing',schema=None)], [dict(kind='arbitrary_sql',sql='REVOKE ALL')]]
        for invalid in cases:
            with self.assertRaises(ValueError):corrections.prepare(target,state,invalid)
        state['functions'][0]['acl'][0]['grantor']='other'
        with self.assertRaisesRegex(ValueError,'UNREVIEWED_PUBLIC_GRANT_CHAIN'):corrections.prepare(target,state,operations)

    def test_sql_resolves_oid_without_splicing_argument_text(self):
        target,state,operations=fixture()
        state['functions'][0]['identityArguments']="p text); SELECT 'unsafe'"
        plan=corrections.prepare(target,state,operations)
        sql=corrections.guarded_sql(plan)
        self.assertIn('RESTRICT',sql)
        self.assertIn('pg_advisory_xact_lock',sql)
        self.assertIn('ACL_CORRECTION_BASELINE_CHANGED',sql)
        self.assertIn('ACL_CORRECTION_POSTCONDITION_FAILED',sql)
        self.assertIn('target::regprocedure',sql)
        ddl=corrections.statements(plan)
        self.assertNotIn('ON ALL',ddl)
        self.assertNotIn('CASCADE',ddl)

    def test_exact_state_detects_nested_acl_extension_owner_and_dependency_drift(self):
        target,state,operations=fixture();plan=corrections.prepare(target,state,operations)
        for mutate in [lambda s:s['functions'][0].update(extension={'name':'new'}),lambda s:s['functions'][0].update(owner='other'),lambda s:s['functions'][0]['dependents'].append({'type':'n'}),lambda s:s['authorities'].update(untouchedAclSha256='d'*64)]:
            changed=copy.deepcopy(state);mutate(changed)
            self.assertFalse(corrections.equivalent(plan['baseline'],changed))
        reordered=copy.deepcopy(state);reordered['functions'][0]['acl'].reverse()
        self.assertTrue(corrections.equivalent(state,reordered))

    def test_local_default_removal_preserves_unrelated_default_grants(self):
        target,state,_=fixture();creator=state['creatorDefaults'][0]
        creator['schemaExplicit']=True
        creator['schemaAcl']=[dict(grantor='fixture_owner',grantee='PUBLIC',privilege='EXECUTE',grantOption=False),dict(grantor='fixture_owner',grantee='unrelated',privilege='EXECUTE',grantOption=False)]
        state['defaultPrivileges']=[dict(owner='fixture_owner',schema='tenant_fixture',type='f',acl=copy.deepcopy(creator['schemaAcl']))]
        plan=corrections.prepare(target,state,[dict(kind='function_public_default',owner='fixture_owner',schema='tenant_fixture')])
        after=corrections.expected_after(plan)
        self.assertEqual([a['grantee'] for a in after['defaultPrivileges'][0]['acl']],['unrelated'])
        self.assertTrue(after['creatorDefaults'][0]['schemaExplicit'])

    def test_empty_local_override_is_removed_without_changing_global_defaults(self):
        target,state,_=fixture();creator=state['creatorDefaults'][0]
        creator['schemaExplicit']=True
        creator['schemaAcl']=[dict(grantor='fixture_owner',grantee='PUBLIC',privilege='EXECUTE',grantOption=False)]
        state['defaultPrivileges']=[dict(owner='fixture_owner',schema='tenant_fixture',type='f',acl=copy.deepcopy(creator['schemaAcl']))]
        plan=corrections.prepare(target,state,[dict(kind='function_public_default',owner='fixture_owner',schema='tenant_fixture')])
        after=corrections.expected_after(plan)
        self.assertEqual(after['defaultPrivileges'],[])
        self.assertFalse(after['creatorDefaults'][0]['schemaExplicit'])
        self.assertEqual(after['creatorDefaults'][0]['globalAcl'],creator['globalAcl'])


if __name__=='__main__':unittest.main()
