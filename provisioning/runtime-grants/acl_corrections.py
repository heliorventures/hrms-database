"""Explicit PUBLIC-only ACL reductions, bound to an exact reviewed catalog.

This compiler performs no I/O and never grants rights, changes ownership,
replaces functions, or accepts SQL text as an operation.
"""
import copy
import json
import re

import acl_catalog
from policy import digest, literal, require


def _quoted(value):
    require(isinstance(value,str) and re.fullmatch(r'[a-z_][a-z0-9_]{0,62}',value), 'INVALID_CATALOG_IDENTIFIER')
    return '"'+value+'"'


def _without_public(acl,owner,privilege):
    selected=[a for a in acl if a['grantee']=='PUBLIC' and a['privilege']==privilege]
    require(len(selected)==1,'REVIEWED_PUBLIC_PRIVILEGE_NOT_PRESENT')
    require(selected[0]['grantor']==owner and selected[0]['grantOption'] is False,'UNREVIEWED_PUBLIC_GRANT_CHAIN')
    return [a for a in acl if a not in selected]


def _validate(plan):
    require(isinstance(plan,dict) and set(plan)=={'version','purpose','target','baseline','operations'} and type(plan['version']) is int and plan['version']==1,'INVALID_CORRECTION_PLAN')
    require(plan['purpose']=='reviewed_public_acl_reductions','INVALID_CORRECTION_PURPOSE')
    acl_catalog.validate_snapshot(plan['target'],plan['baseline'])
    roles={r['name']:r for r in plan['baseline']['authorities']['roles']}
    for name in plan['target']['roles']:
        role=roles.get(name,{})
        require(role.get('login') is True and all(role.get(k) is False for k in ('inherit','superuser','createDb','createRole','replication','bypassRls')),'UNRESTRICTED_RUNTIME_ROLE')
    for row in plan['baseline']['authorities']['memberships']:
        require(not set(plan['target']['roles']).intersection(str(v) for v in row.values()),'RUNTIME_ROLE_MEMBERSHIP')
    operations=plan['operations']
    require(isinstance(operations,list) and 0<len(operations)<=4096,'EXPLICIT_CORRECTIONS_REQUIRED')
    require(len({digest(o) for o in operations})==len(operations),'DUPLICATE_CORRECTION')
    for operation in operations:
        require(isinstance(operation,dict),'INVALID_CORRECTION_OPERATION')
        kind=operation.get('kind')
        if kind=='function_public_execute':
            require(set(operation)=={'kind','oid'} and type(operation['oid']) is int and 0<operation['oid']<2**32,'INVALID_FUNCTION_CORRECTION')
        elif kind=='schema_public_usage':
            require(set(operation)=={'kind','name'} and operation['name']=='public','INVALID_SCHEMA_CORRECTION')
        elif kind=='function_public_default':
            require(set(operation)=={'kind','owner','schema'} and operation['schema'] in [None,*acl_catalog.allowed_schemas(plan['target'])],'INVALID_DEFAULT_CORRECTION')
            _quoted(operation['owner'])
        else:
            raise ValueError('INVALID_CORRECTION_OPERATION')
    return plan


def prepare(target,baseline,operations):
    plan=copy.deepcopy(dict(version=1,purpose='reviewed_public_acl_reductions',target=target,baseline=baseline,operations=operations))
    expected_after(plan)
    return plan


def expected_after(plan):
    _validate(plan)
    state=copy.deepcopy(plan['baseline'])
    for operation in plan['operations']:
        kind=operation['kind']
        if kind=='function_public_execute':
            rows=[f for f in state['functions'] if f['oid']==operation['oid']]
            require(len(rows)==1,'FUNCTION_CORRECTION_TARGET_CHANGED')
            row=rows[0]
            require(row['schema'] in acl_catalog.allowed_schemas(plan['target']) and row['kind'] in ('f','p'),'FUNCTION_CORRECTION_TARGET_CHANGED')
            row['acl']=_without_public(row['acl'],row['owner'],'EXECUTE')
            row['aclExplicit']=True
        elif kind=='schema_public_usage':
            rows=[s for s in state['schemas'] if s['name']==operation['name']]
            require(len(rows)==1,'SCHEMA_CORRECTION_TARGET_CHANGED')
            rows[0]['acl']=_without_public(rows[0]['acl'],rows[0]['owner'],'USAGE')
            rows[0]['aclExplicit']=True
        else:
            owner,scope=operation['owner'],operation['schema']
            creators=[c for c in state['creatorDefaults'] if c['owner']==owner and (scope is None or c['schema']==scope)]
            require(creators,'DEFAULT_CREATOR_CHANGED')
            prefix='global' if scope is None else 'schema'
            original=creators[0][prefix+'Acl']
            require(all(c[prefix+'Acl']==original for c in creators),'INCONSISTENT_DEFAULT_CATALOG')
            reduced=_without_public(original,owner,'EXECUTE')
            for creator in creators:
                creator[prefix+'Acl']=copy.deepcopy(reduced)
                creator[prefix+'Explicit']=True if scope is None else bool(reduced)
            state['defaultPrivileges']=[d for d in state['defaultPrivileges'] if (d['owner'],d['schema'],d['type'])!=(owner,scope,'f')]
            if scope is None or reduced:
                state['defaultPrivileges'].append(dict(owner=owner,schema=scope,type='f',acl=copy.deepcopy(reduced)))
    return state


def _canonical(value):
    if isinstance(value,dict):return {k:_canonical(v) for k,v in value.items()}
    if isinstance(value,list):return sorted((_canonical(v) for v in value),key=lambda v:json.dumps(v,sort_keys=True))
    return value


def equivalent(expected,actual):
    return _canonical(expected)==_canonical(actual)


def _guard(target,state,code):
    # JSONB mutual containment compares nested arrays without catalog-OID order.
    # Actual snapshot uses fixed keys; test keys separately to reject extra fields.
    body='DECLARE actual jsonb; wanted jsonb := '+literal(json.dumps(state,separators=(',',':')))+'::jsonb; BEGIN actual := ('+acl_catalog.snapshot_sql(target)+"); IF NOT(actual @> wanted AND wanted @> actual) OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(actual)key) IS DISTINCT FROM (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(wanted)key) THEN RAISE EXCEPTION '"+code+"'; END IF; END"
    tag='$acl_guard_'+digest(body)+'$'
    require(tag not in body,'UNSAFE_GUARD_DELIMITER')
    return 'DO '+tag+' '+body+' '+tag+';'


def statements(plan):
    expected_after(plan)
    lines=[]
    for operation in plan['operations']:
        if operation['kind']=='function_public_execute':
            routine=next(f for f in plan['baseline']['functions'] if f['oid']==operation['oid'])
            object_type='PROCEDURE' if routine['kind']=='p' else 'FUNCTION'
            # Resolve the bound OID; never splice identity argument text into DDL.
            lines.append("DO $acl_revoke$ DECLARE target oid := "+str(operation['oid'])+"; BEGIN EXECUTE format('REVOKE EXECUTE ON "+object_type+" %s FROM PUBLIC RESTRICT',target::regprocedure); END $acl_revoke$;")
        elif operation['kind']=='schema_public_usage':
            lines.append('REVOKE USAGE ON SCHEMA "public" FROM PUBLIC RESTRICT;')
        else:
            scope='' if operation['schema'] is None else ' IN SCHEMA '+_quoted(operation['schema'])
            lines.append('ALTER DEFAULT PRIVILEGES FOR ROLE '+_quoted(operation['owner'])+scope+' REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC RESTRICT;')
    return '\n'.join(lines)


def guarded_sql(plan):
    after=expected_after(plan)
    return '\n'.join(['BEGIN;','SET LOCAL search_path=pg_catalog;','SET LOCAL standard_conforming_strings=on;',"SET LOCAL lock_timeout='5s';","SET LOCAL statement_timeout='60s';","SELECT pg_advisory_xact_lock(hashtextextended('hrms-runtime-grants:'||current_database(),0));",_guard(plan['target'],plan['baseline'],'ACL_CORRECTION_BASELINE_CHANGED'),statements(plan),_guard(plan['target'],after,'ACL_CORRECTION_POSTCONDITION_FAILED'),'COMMIT;'])
