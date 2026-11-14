import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]))
import policy

class RowSecurity(unittest.TestCase):
 def setUp(self):
  self.definition=dict(force=False,policies=[dict(name='history_rows',command='*',permissive=True,roles=['PUBLIC'],using="(CURRENT_USER = 'history_worker'::name)",check=None)])
  self.contract=dict(rowSecurity={'checkpoint':self.definition})
  self.relation=dict(rowSecurity=True,forceRowSecurity=False,rowSecurityPolicies=copy.deepcopy(self.definition['policies']))
 def test_exact_reviewed_rls_is_accepted(self):
  policy.check_row_security(self.contract,'checkpoint',self.relation)
 def test_unreviewed_rls_or_missing_policy_is_rejected(self):
  for contract in({},dict(rowSecurity={})):
   with self.assertRaisesRegex(ValueError,'UNREVIEWED_ROW_SECURITY'):policy.check_row_security(contract,'checkpoint',self.relation)
 def test_policy_force_role_and_expression_drift_are_rejected(self):
  changes=[lambda x:x.update(forceRowSecurity=True),lambda x:x['rowSecurityPolicies'].append(copy.deepcopy(x['rowSecurityPolicies'][0])),lambda x:x['rowSecurityPolicies'][0].update(using='true'),lambda x:x['rowSecurityPolicies'][0].update(roles=['other']),lambda x:x.update(rowSecurity=False)]
  for change in changes:
   observed=copy.deepcopy(self.relation);change(observed)
   with self.assertRaisesRegex(ValueError,'ROW_SECURITY_POLICY_CHANGED'):policy.check_row_security(self.contract,'checkpoint',observed)
 def test_contract_requires_named_referenced_tables_and_valid_policy_shapes(self):
  candidate=dict(version=1,systemId='123',database='metadata_fixture',allowedDatabases=['metadata_fixture'],schema='metadata_scope',creators=['fixture_owner'],roles={'history_worker':dict(tables={'checkpoint':dict(select=['consumer_role'])},sequences=[],functions=[])},blockers=[],rowSecurity={'checkpoint':copy.deepcopy(self.definition)})
  policy.validate_policy(candidate)
  mutations=[lambda p:p['rowSecurity'].update(unused=copy.deepcopy(self.definition)),lambda p:p['rowSecurity']['checkpoint'].update(extra=True),lambda p:p['rowSecurity']['checkpoint'].update(policies=[]),lambda p:p['rowSecurity']['checkpoint']['policies'][0].update(command='unknown'),lambda p:p['rowSecurity']['checkpoint']['policies'][0].update(roles=[]),lambda p:p['rowSecurity']['checkpoint']['policies'][0].update(using=123)]
  for change in mutations:
   altered=copy.deepcopy(candidate);change(altered)
   with self.assertRaises(ValueError):policy.validate_policy(altered)
 def test_database_snapshot_checks_closed_non_template_databases(self):
  import catalog
  candidate=dict(version=1,systemId='123',database='metadata_fixture',allowedDatabases=['metadata_fixture'],schema='metadata_scope',creators=['fixture_owner'],roles={'history_worker':dict(tables={},sequences=[],functions=[])},blockers=[])
  sql=catalog.snapshot_sql(candidate)
  self.assertFalse('WHERE d.datallowconn OR d.datname=current_database()'in sql)
  self.assertTrue("WHERE d.datname<>'template0' OR d.datname=current_database()"in sql)

if __name__=='__main__':unittest.main()
