-- Exact catalog ACL origins. No business rows, password fields or function bodies.
WITH base AS (SELECT (__BASE_QUERY__) AS body),
selected_ns AS (SELECT * FROM pg_namespace WHERE nspname=ANY(__ACL_SCHEMAS__)),
selected_functions AS (SELECT p.* FROM pg_proc p JOIN selected_ns n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p')),
authority_objects AS (
 SELECT 'relation'::text AS kind,c.oid AS object_oid,0 AS sub_id,c.relowner AS owner,coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner)) AS acl FROM pg_class c WHERE c.relkind IN ('r','p','v','m','f','S')
 UNION ALL SELECT 'column',c.oid,a.attnum,c.relowner,a.attacl FROM pg_class c JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped WHERE c.relkind IN ('r','p','v','m','f')
 UNION ALL SELECT 'function',oid,0,proowner,coalesce(proacl,acldefault('f',proowner)) FROM pg_proc
 UNION ALL SELECT 'schema',oid,0,nspowner,coalesce(nspacl,acldefault('n',nspowner)) FROM pg_namespace
 UNION ALL SELECT 'database',oid,0,datdba,coalesce(datacl,acldefault('d',datdba)) FROM pg_database
 UNION ALL SELECT 'type',oid,0,typowner,coalesce(typacl,acldefault('T',typowner)) FROM pg_type
 UNION ALL SELECT 'language',oid,0,lanowner,coalesce(lanacl,acldefault('l',lanowner)) FROM pg_language
 UNION ALL SELECT 'foreign_wrapper',oid,0,fdwowner,coalesce(fdwacl,acldefault('F',fdwowner)) FROM pg_foreign_data_wrapper
 UNION ALL SELECT 'foreign_server',oid,0,srvowner,coalesce(srvacl,acldefault('S',srvowner)) FROM pg_foreign_server
 UNION ALL SELECT 'large_object',oid,0,lomowner,coalesce(lomacl,acldefault('L',lomowner)) FROM pg_largeobject_metadata
 UNION ALL SELECT 'tablespace',oid,0,spcowner,coalesce(spcacl,acldefault('t',spcowner)) FROM pg_tablespace
 UNION ALL SELECT 'default',oid,0,defaclrole,defaclacl FROM pg_default_acl WHERE defaclobjtype<>'f' OR (defaclnamespace<>0 AND defaclnamespace NOT IN (SELECT oid FROM selected_ns))
),
untouched_acl_rows AS (
 SELECT jsonb_build_object('kind',o.kind,'object',o.object_oid,'subId',o.sub_id,'owner',o.owner,'grantor',a.grantor,'grantee',a.grantee,'privilege',a.privilege_type,'grantOption',a.is_grantable) AS entry
 FROM authority_objects o LEFT JOIN LATERAL aclexplode(NULLIF(o.acl,'{}'::aclitem[]))a ON true
 WHERE NOT(o.kind='function' AND o.object_oid IN (SELECT oid FROM selected_functions)) AND NOT(o.kind='schema' AND o.object_oid IN (SELECT oid FROM selected_ns))
),
invariant AS (
 SELECT body-ARRAY['schemas','creators','functionAccess','defaultAccess','authorities'] || jsonb_build_object(
 'authorityRoles',body->'authorities'->'roles','authorityMemberships',body->'authorities'->'memberships',
 'schemasOutsideTargets',coalesce((SELECT jsonb_agg(value ORDER BY value::text) FROM jsonb_array_elements(body->'schemas') WHERE (value->>'name')<>ALL(__ACL_SCHEMAS__)),'[]'::jsonb),
 'functionsOutsideTargets',coalesce((SELECT jsonb_agg(value ORDER BY value::text) FROM jsonb_array_elements(body->'functionAccess') WHERE (value->>'schema')<>ALL(__ACL_SCHEMAS__)),'[]'::jsonb),
 'creatorNames',coalesce((SELECT jsonb_agg(value->>'name' ORDER BY value->>'name') FROM jsonb_array_elements(body->'creators')),'[]'::jsonb),
 'otherDefaults',coalesce((SELECT jsonb_agg(value ORDER BY value::text) FROM jsonb_array_elements(body->'defaultAccess') WHERE value->>'type'<>'f' OR ((value->>'schemaOid')::oid<>0 AND (value->>'schemaOid')::oid NOT IN (SELECT oid FROM selected_ns))),'[]'::jsonb)) AS body
 FROM base
)
SELECT jsonb_build_object(
 'purpose','exact_acl_catalog_only_not_correction_plan','systemId',(SELECT body->>'systemId' FROM base),'database',current_database(),'versionMajor',split_part(current_setting('server_version'),'.',1),
 'admissionBarrier',(SELECT body->'admissionBarrier' FROM base),'connections',(SELECT body->'connections' FROM base),
 'runtimeRoles',coalesce((SELECT jsonb_agg(rolname ORDER BY rolname) FROM pg_roles WHERE rolname=ANY(__ROLES__)),'[]'::jsonb),
 'schemas',coalesce((SELECT jsonb_agg(jsonb_build_object('oid',n.oid::bigint,'name',n.nspname,'owner',pg_get_userbyid(n.nspowner),'aclExplicit',n.nspacl IS NOT NULL,'acl',__SCHEMA_ACL__) ORDER BY n.nspname) FROM selected_ns n),'[]'::jsonb),
 'functions',coalesce((SELECT jsonb_agg(jsonb_build_object('oid',p.oid::bigint,'schema',n.nspname,'name',p.proname,'kind',p.prokind,'identityArguments',pg_get_function_identity_arguments(p.oid),'owner',pg_get_userbyid(p.proowner),'language',l.lanname,'securityDefiner',p.prosecdef,
 'definitionSha256',encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex'),'aclExplicit',p.proacl IS NOT NULL,'acl',__FUNCTION_ACL__,
 'extension',(SELECT jsonb_build_object('name',e.extname,'version',e.extversion,'schema',en.nspname,'owner',pg_get_userbyid(e.extowner)) FROM pg_depend dep JOIN pg_extension e ON e.oid=dep.refobjid JOIN pg_namespace en ON en.oid=e.extnamespace WHERE dep.classid='pg_proc'::regclass AND dep.objid=p.oid AND dep.refclassid='pg_extension'::regclass AND dep.deptype='e'),
 'dependents',coalesce((SELECT jsonb_agg(jsonb_build_object('classOid',d.classid::bigint,'objectOid',d.objid::bigint,'subId',d.objsubid,'type',d.deptype,'description',pg_describe_object(d.classid,d.objid,d.objsubid)) ORDER BY d.classid,d.objid,d.objsubid,d.deptype) FROM pg_depend d WHERE d.refclassid='pg_proc'::regclass AND d.refobjid=p.oid),'[]'::jsonb)) ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) FROM selected_functions p JOIN selected_ns n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang),'[]'::jsonb),
 'extensions',coalesce((SELECT jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname,'owner',pg_get_userbyid(e.extowner)) ORDER BY e.extname) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),'[]'::jsonb),
 'defaultPrivileges',coalesce((SELECT jsonb_agg(jsonb_build_object('owner',pg_get_userbyid(d.defaclrole),'schema',n.nspname,'type',d.defaclobjtype,'acl',__DEFAULT_ACL__) ORDER BY d.defaclrole,d.defaclnamespace,d.defaclobjtype) FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace),'[]'::jsonb),
 'creatorDefaults',coalesce((SELECT jsonb_agg(jsonb_build_object('owner',r.rolname,'schema',n.nspname,'globalExplicit',g.oid IS NOT NULL,'globalAcl',__GLOBAL_ACL__,'schemaExplicit',l.oid IS NOT NULL,'schemaAcl',__LOCAL_ACL__) ORDER BY r.rolname,n.nspname) FROM pg_roles r CROSS JOIN selected_ns n LEFT JOIN pg_default_acl g ON g.defaclrole=r.oid AND g.defaclnamespace=0 AND g.defaclobjtype='f' LEFT JOIN pg_default_acl l ON l.defaclrole=r.oid AND l.defaclnamespace=n.oid AND l.defaclobjtype='f' WHERE has_schema_privilege(r.oid,n.oid,'CREATE')),'[]'::jsonb),
 'authorities',jsonb_build_object('roles',(SELECT body->'authorities'->'roles' FROM base),'memberships',(SELECT body->'authorities'->'memberships' FROM base),'untouchedAclSha256',encode(sha256(convert_to(coalesce((SELECT jsonb_agg(entry ORDER BY entry::text) FROM untouched_acl_rows),'[]'::jsonb)::text,'UTF8')),'hex')),
 'catalogInvariantSha256',encode(sha256(convert_to((SELECT body::text FROM invariant),'UTF8')),'hex')
);
