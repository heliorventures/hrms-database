"""Compile restricted LOGIN creation from an exact operator role baseline.

No I/O or grants. Callers keep the generated credentials on the database host,
in a protected credential store, and must verify an uncertain commit instead of
resetting passwords. SQL receives SCRAM verifiers rather than plaintext values.
"""
import base64
import copy
import hashlib
import hmac
import re
import secrets

from policy import digest,identifier,literal,require

SNAPSHOT_SQL="""SELECT jsonb_build_object(
 'systemId',(SELECT system_identifier::text FROM pg_control_system()),
 'database',current_database(),
 'operatorSuperuser',(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),
 'roles',coalesce((SELECT jsonb_agg(jsonb_build_object('name',rolname,'login',rolcanlogin,'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'inherit',rolinherit,'replication',rolreplication,'bypassRls',rolbypassrls)ORDER BY rolname)FROM pg_roles),'[]'::jsonb),
 'memberships',coalesce((SELECT jsonb_agg(jsonb_build_object('role',pg_get_userbyid(roleid),'member',pg_get_userbyid(member),'admin',admin_option,'inherit',inherit_option,'set',set_option)ORDER BY roleid,member)FROM pg_auth_members),'[]'::jsonb))"""


def scram(password,salt=None):
    salt=secrets.token_bytes(16)if salt is None else salt
    require(isinstance(salt,bytes)and len(salt)==16,'INVALID_CREDENTIAL_SALT')
    salted=hashlib.pbkdf2_hmac('sha256',password.encode('ascii'),salt,4096)
    client=hmac.new(salted,b'Client Key',hashlib.sha256).digest()
    stored=hashlib.sha256(client).digest()
    server=hmac.new(salted,b'Server Key',hashlib.sha256).digest()
    encode=lambda value:base64.b64encode(value).decode('ascii')
    return 'SCRAM-SHA-256$4096:'+encode(salt)+'$'+encode(stored)+':'+encode(server)


def new_bundle(names):
    require(isinstance(names,list)and 0<len(names)<=64,'EXPLICIT_ROLE_SET_REQUIRED')
    require(all(isinstance(n,str)for n in names)and len(set(names))==len(names),'INVALID_ROLE_SET')
    for name in names:identifier(name)
    result={}
    for name in sorted(names):
        password=secrets.token_urlsafe(36)
        result[name]=dict(role=name,password=password,verifier=scram(password))
    return validate_bundle(result)


def validate_bundle(bundle):
    require(isinstance(bundle,dict)and 0<len(bundle)<=64,'INVALID_CREDENTIAL_BUNDLE')
    passwords=set()
    for name,entry in bundle.items():
        identifier(name)
        require(isinstance(entry,dict)and set(entry)=={'role','password','verifier'}and entry['role']==name,'INVALID_CREDENTIAL_ENTRY')
        password=entry['password']
        require(isinstance(password,str)and re.fullmatch('[A-Za-z0-9_-]{48}',password)is not None and password not in passwords,'INVALID_OR_DUPLICATE_PASSWORD')
        passwords.add(password)
        try:
            mechanism,iteration_salt,keys=entry['verifier'].split('$')
            iterations,salt_text=iteration_salt.split(':')
            salt=base64.b64decode(salt_text,validate=True)
            stored,server=[base64.b64decode(v,validate=True)for v in keys.split(':')]
            require(mechanism=='SCRAM-SHA-256'and iterations=='4096'and len(stored)==32 and len(server)==32,'INVALID_CREDENTIAL_VERIFIER')
            require(hmac.compare_digest(scram(password,salt),entry['verifier']),'CREDENTIAL_VERIFIER_MISMATCH')
        except (TypeError,AttributeError,ValueError)as error:
            if type(error)is ValueError and re.fullmatch('[A-Z_]+',str(error)):raise
            raise ValueError('INVALID_CREDENTIAL_VERIFIER')from None
    return bundle


def expected_after(before,bundle):
    validate_bundle(bundle)
    require(isinstance(before,dict)and set(before)=={'systemId','database','operatorSuperuser','roles','memberships'},'INVALID_ROLE_BASELINE')
    require(isinstance(before['systemId'],str)and re.fullmatch('[1-9][0-9]{0,19}',before['systemId'])is not None and before['database']=='postgres'and before['operatorSuperuser']is True,'SUPERUSER_CONTROL_BASELINE_REQUIRED')
    require(isinstance(before['roles'],list)and isinstance(before['memberships'],list),'INVALID_ROLE_BASELINE')
    require(not set(bundle).intersection(r['name']for r in before['roles']),'ROLE_ALREADY_EXISTS_NO_PASSWORD_RESET')
    result=copy.deepcopy(before)
    result['roles']=sorted(result['roles']+[dict(name=name,login=True,inherit=False,superuser=False,createDb=False,createRole=False,replication=False,bypassRls=False)for name in bundle],key=lambda r:r['name'])
    return result


def state_guard(expected,code):
    require(re.fullmatch('[A-Z_]+',code)is not None,'INVALID_GUARD_CODE')
    import json
    body='BEGIN IF ('+SNAPSHOT_SQL+') IS DISTINCT FROM '+literal(json.dumps(expected,separators=(',',':')))+"::jsonb THEN RAISE EXCEPTION '"+code+"'; END IF; END"
    tag='$role_guard_'+digest(body)+'$';require(tag not in body,'UNSAFE_GUARD_DELIMITER')
    return 'DO '+tag+' '+body+' '+tag+';'


def credential_guard(bundle):
    validate_bundle(bundle)
    choices=['(rolname='+literal(name)+' AND rolpassword='+literal(entry['verifier'])+')'for name,entry in sorted(bundle.items())]
    return "DO $credential_guard$ BEGIN IF (SELECT count(*) FROM pg_authid WHERE "+' OR '.join(choices)+")<>"+str(len(bundle))+" THEN RAISE EXCEPTION 'CREDENTIAL_VERIFICATION_FAILED'; END IF; END $credential_guard$;"


def create_sql(before,bundle):
    after=expected_after(before,bundle)
    lines=['BEGIN;','SET LOCAL search_path=pg_catalog;','SET LOCAL standard_conforming_strings=on;',"SET LOCAL lock_timeout='5s';","SET LOCAL statement_timeout='60s';","SELECT pg_advisory_xact_lock(hashtextextended('hrms-restricted-role-creation',0));",'LOCK TABLE pg_authid,pg_auth_members IN SHARE ROW EXCLUSIVE MODE;',state_guard(before,'ROLE_BASELINE_CHANGED')]
    for name,entry in sorted(bundle.items()):
        lines.append('CREATE ROLE '+identifier(name)+' LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '+literal(entry['verifier'])+';')
    return '\n'.join(lines+[state_guard(after,'ROLE_POSTCONDITION_FAILED'),credential_guard(bundle),'COMMIT;'])
