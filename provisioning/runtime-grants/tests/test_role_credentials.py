"""Pure fixtures; no environment, credentials or database connection."""
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]))
import role_credentials as roles

class RoleCredentialTests(unittest.TestCase):
    def test_restricted_create_sql_never_contains_plaintext_passwords(self):
        bundle=roles.new_bundle(['metadata_reader','metadata_writer'])
        before=dict(systemId='1234',database='postgres',operatorSuperuser=True,roles=[],memberships=[])
        sql=roles.create_sql(before,bundle)
        for entry in bundle.values():
            self.assertNotIn(entry['password'],sql)
            self.assertIn(entry['verifier'],sql)
        self.assertIn('NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',sql)
        self.assertNotIn('GRANT ',sql)
        self.assertEqual(len(roles.expected_after(before,bundle)['roles']),2)

    def test_invalid_role_sets_and_changed_verifiers_are_refused(self):
        for names in([],['pg_bad'],['public'],['metadata_reader','metadata_reader'],['bad;role']):
            with self.subTest(names=names),self.assertRaises(ValueError):roles.new_bundle(names)
        bundle=roles.new_bundle(['metadata_reader']);changed=copy.deepcopy(bundle)
        changed['metadata_reader']['password']='A'*48
        with self.assertRaisesRegex(ValueError,'CREDENTIAL_VERIFIER_MISMATCH'):roles.validate_bundle(changed)

    def test_existing_role_or_wrong_control_context_cannot_create_or_reset(self):
        bundle=roles.new_bundle(['metadata_reader']);before=dict(systemId='1234',database='postgres',operatorSuperuser=True,roles=[],memberships=[])
        for state in[dict(before,database='helior'),dict(before,operatorSuperuser=False),dict(before,roles=[dict(name='metadata_reader')])]:
            with self.assertRaises(ValueError):roles.create_sql(state,bundle)

if __name__=='__main__':unittest.main()
