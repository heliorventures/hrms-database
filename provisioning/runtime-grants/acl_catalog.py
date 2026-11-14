"""Exact ACL origins; catalog metadata only, without credential or function bodies."""
from pathlib import Path

import catalog as runtime_catalog
from policy import identifier, literal, require, validate_policy
from run import validate_inventory_snapshot, validate_inventory_target


def _acl_json(expression):
    return "(SELECT coalesce(jsonb_agg(jsonb_build_object('grantor',pg_get_userbyid(a.grantor),'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,'privilege',a.privilege_type,'grantOption',a.is_grantable) ORDER BY a.grantor,a.grantee,a.privilege_type,a.is_grantable),'[]'::jsonb) FROM aclexplode(NULLIF("+expression+",'{}'::aclitem[]))a)"


def base_target(target):
    require(isinstance(target,dict),'INVALID_INVENTORY_TARGET')
    base={k:v for k,v in target.items()if k!='aclSchemas'}
    validate_inventory_target(base)
    if 'aclSchemas'in target:
        scopes=target['aclSchemas']
        require(isinstance(scopes,list)and 2<=len(scopes)<=16 and all(isinstance(n,str)for n in scopes),'INVALID_ACL_SCHEMA_SCOPE')
        require(len(set(scopes))==len(scopes)and {'public',base['schema']}<=set(scopes),'INVALID_ACL_SCHEMA_SCOPE')
        for name in scopes:
            if name!='public':identifier(name)
    return base


def allowed_schemas(target):
    base=base_target(target)
    return sorted(target.get('aclSchemas',['public',base['schema']]))


def query_policy(target):
    base_target(target)
    return validate_policy({"version":1,"systemId":target["systemId"],"database":target["database"],"schema":target["schema"],"allowedDatabases":target["allowedDatabases"],"creators":["catalog_inventory_placeholder"],"roles":{role:{"tables":{},"sequences":[],"functions":[]} for role in target["roles"]},"blockers":[]})


def snapshot_sql(target):
    policy=query_policy(target)
    text=Path(__file__).with_name("acl_snapshot.sql").read_text(encoding="utf-8")
    replacements={"__BASE_QUERY__":runtime_catalog.snapshot_sql(policy),"__SCHEMA__":literal(target["schema"]),"__ACL_SCHEMAS__":"ARRAY["+",".join(literal(n)for n in allowed_schemas(target))+"]::text[]","__ROLES__":"ARRAY["+",".join(literal(r) for r in sorted(target["roles"]))+"]::text[]",
        "__FUNCTION_ACL__":_acl_json("coalesce(p.proacl,acldefault('f',p.proowner))"),
        "__SCHEMA_ACL__":_acl_json("coalesce(n.nspacl,acldefault('n',n.nspowner))"),
        "__DEFAULT_ACL__":_acl_json("d.defaclacl"),
        "__GLOBAL_ACL__":_acl_json("coalesce(g.defaclacl,acldefault('f',r.oid))"),
        "__LOCAL_ACL__":_acl_json("l.defaclacl")}
    for key,value in replacements.items():text=text.replace(key,value)
    return text.strip().rstrip(';')


def validate_snapshot(target,state):
    base=base_target(target)
    require(isinstance(state,dict) and set(state)=={"purpose","systemId","database","versionMajor","admissionBarrier","connections","runtimeRoles","functions","schemas","defaultPrivileges","creatorDefaults","extensions","authorities","catalogInvariantSha256"},"INCOMPLETE_ACL_SNAPSHOT")
    require(state["purpose"]=="exact_acl_catalog_only_not_correction_plan","INVALID_ACL_CATALOG_PURPOSE")
    validate_inventory_snapshot(base,state)
    if 'aclSchemas'in target:require({s['name']for s in state['schemas']}==set(target['aclSchemas']),'ACL_SCHEMA_SET_CHANGED')
    require(set(state["runtimeRoles"])==set(target["roles"]) and len(state["runtimeRoles"])==len(target["roles"]),"ROLE_BASELINE_CHANGED")
    return state
