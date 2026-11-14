-- Catalog/security metadata only. No credentials, password verifiers or business rows.
WITH runtime AS (SELECT * FROM pg_roles WHERE rolname=ANY(__ROLES__::text[])),
ns AS (SELECT * FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema') AND nspname NOT LIKE 'pg\_%'),
rels AS (SELECT c.*,n.nspname FROM pg_class c JOIN ns n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p','v','m','f','S')),
funcs AS (SELECT p.*,n.nspname,pg_get_function_identity_arguments(p.oid) AS args,
 encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') AS digest
 FROM pg_proc p JOIN ns n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p')),
creators AS (SELECT r.* FROM pg_roles r WHERE has_schema_privilege(r.oid,__SCHEMA__,'CREATE')),
creator_function_defaults AS (
 SELECT r.rolname,a.grantee,a.privilege_type FROM creators r
 CROSS JOIN LATERAL aclexplode(NULLIF(coalesce((SELECT d.defaclacl FROM pg_default_acl d WHERE d.defaclrole=r.oid AND d.defaclnamespace=0 AND d.defaclobjtype='f'),acldefault('f',r.oid)),'{}'::aclitem[]))a
 UNION ALL
 SELECT r.rolname,a.grantee,a.privilege_type FROM creators r JOIN pg_default_acl d ON d.defaclrole=r.oid AND d.defaclobjtype='f' AND d.defaclnamespace=(SELECT oid FROM pg_namespace WHERE nspname=__SCHEMA__)
 CROSS JOIN LATERAL aclexplode(NULLIF(d.defaclacl,'{}'::aclitem[]))a
),
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
 UNION ALL SELECT 'default',oid,0,defaclrole,defaclacl FROM pg_default_acl
),
authority_acl_rows AS (
 SELECT jsonb_build_object('kind',o.kind,'object',o.object_oid,'subId',o.sub_id,'owner',o.owner,'grantor',a.grantor,'grantee',a.grantee,'privilege',a.privilege_type,'grantOption',a.is_grantable) AS entry
 FROM authority_objects o LEFT JOIN LATERAL (SELECT * FROM aclexplode(NULLIF(o.acl,'{}'::aclitem[])) WHERE grantee<>ALL(ARRAY(SELECT oid FROM runtime)))a ON true
),
system_rels AS (SELECT c.*,n.nspname,coalesce(ip.initprivs,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner)) AS initial_acl,
 (n.nspname='information_schema' AND c.oid<16384 AND c.relkind IN ('r','v') AND c.relname=ANY(__INFORMATION_SCHEMA_SELECT__)) AS bootstrap_public_select
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_init_privs ip ON ip.classoid='pg_class'::regclass AND ip.objoid=c.oid AND ip.objsubid=0 AND ip.privtype='i'
 WHERE (n.nspname IN ('pg_catalog','information_schema') OR n.nspname LIKE 'pg\_%') AND c.relkind IN ('r','p','v','m','f')),
system_excess AS (
 -- Unsupported object classes are checked separately from owner-authority
 -- hashes: approved runtime grants are intentionally excluded from those hashes.
 SELECT jsonb_build_object('role',r.rolname,'schema',n.nspname,'object',n.nspname,'kind','schema','privilege',p.privilege,'grantOption',g.grant_option) AS entry
 FROM runtime r CROSS JOIN pg_namespace n
 LEFT JOIN pg_init_privs ip ON ip.classoid='pg_namespace'::regclass AND ip.objoid=n.oid AND ip.objsubid=0 AND ip.privtype='i'
 CROSS JOIN unnest(ARRAY['USAGE','CREATE'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE (n.nspname IN ('pg_catalog','information_schema') OR n.nspname LIKE 'pg\_%')
 AND has_schema_privilege(r.oid,n.oid,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (p.privilege='CREATE' OR g.grant_option OR NOT (n.nspname IN ('pg_catalog','information_schema') AND p.privilege='USAGE')
 AND NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(ip.initprivs,'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type=p.privilege))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'object',o.oid,'kind','large_object','privilege',a.privilege_type,'grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_largeobject_metadata o
 CROSS JOIN LATERAL aclexplode(NULLIF(coalesce(o.lomacl,acldefault('L',o.lomowner)),'{}'::aclitem[]))a
 CROSS JOIN (VALUES(false),(true))g(grant_option)
 -- PostgreSQL 16 has no has_largeobject_privilege helper. Expand PUBLIC and
 -- effective inheritable role ACLs; role memberships/ownership also fail bounds.
 WHERE (CASE WHEN a.grantee=0 THEN true ELSE pg_has_role(r.oid,a.grantee,'USAGE') END)
 AND (NOT g.grant_option OR a.is_grantable OR pg_has_role(r.oid,o.lomowner,'USAGE'))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'object',f.fdwname,'kind','foreign_wrapper','privilege','USAGE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_foreign_data_wrapper f CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_foreign_data_wrapper_privilege(r.oid,f.oid,'USAGE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'object',s.srvname,'kind','foreign_server','privilege','USAGE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_foreign_server s CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_server_privilege(r.oid,s.oid,'USAGE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'object',s.spcname,'kind','tablespace','privilege','CREATE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_tablespace s CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_tablespace_privilege(r.oid,s.oid,'CREATE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',n.nspname,'object',c.relname,'kind','sequence','privilege',p.privilege,'grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 CROSS JOIN unnest(ARRAY['USAGE','SELECT','UPDATE'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE c.relkind='S' AND (n.nspname IN ('pg_catalog','information_schema') OR n.nspname LIKE 'pg\_%')
 AND has_sequence_privilege(r.oid,c.oid,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'object',l.lanname,'kind','language','privilege','USAGE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_language l CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_language_privilege(r.oid,l.oid,'USAGE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (g.grant_option OR NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(acldefault('l',l.lanowner),'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type='USAGE'))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',n.nspname,'object',t.typname,'kind','type','privilege','USAGE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_type_privilege(r.oid,t.oid,'USAGE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (g.grant_option OR NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(acldefault('T',t.typowner),'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type='USAGE'))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',c.nspname,'object',c.relname,'column',NULL,'kind','relation','privilege',p.privilege,'grantOption',g.grant_option) AS entry
 FROM runtime r CROSS JOIN system_rels c CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_table_privilege(r.oid,c.oid,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (g.grant_option OR NOT (c.bootstrap_public_select AND p.privilege='SELECT') AND NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(c.initial_acl,'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type=p.privilege))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',c.nspname,'object',c.relname,'column',at.attname,'kind','column','privilege',p.privilege,'grantOption',g.grant_option)
 FROM runtime r CROSS JOIN system_rels c JOIN pg_attribute at ON at.attrelid=c.oid AND at.attnum>0 AND NOT at.attisdropped
 LEFT JOIN pg_init_privs ip ON ip.classoid='pg_class'::regclass AND ip.objoid=c.oid AND ip.objsubid=at.attnum AND ip.privtype='i'
 CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE has_column_privilege(r.oid,c.oid,at.attname,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (g.grant_option OR (NOT (c.bootstrap_public_select AND p.privilege='SELECT') AND NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(c.initial_acl,'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type=p.privilege)
 AND NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(ip.initprivs,'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type=p.privilege)))
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',n.nspname,'object',p.proname,'arguments',pg_get_function_identity_arguments(p.oid),'kind','function','privilege','EXECUTE','grantOption',g.grant_option)
 FROM runtime r CROSS JOIN pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 LEFT JOIN pg_init_privs ip ON ip.classoid='pg_proc'::regclass AND ip.objoid=p.oid AND ip.objsubid=0 AND ip.privtype='i'
 CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE (n.nspname IN ('pg_catalog','information_schema') OR n.nspname LIKE 'pg\_%')
 AND has_function_privilege(r.oid,p.oid,'EXECUTE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 AND (g.grant_option OR NOT (p.oid<16384 OR coalesce(ip.privtype='i',false)) OR NOT EXISTS(SELECT 1 FROM aclexplode(NULLIF(coalesce(ip.initprivs,acldefault('f',p.proowner)),'{}'::aclitem[]))a WHERE a.grantee=0 AND a.privilege_type='EXECUTE'))
),
access_rows AS (
 SELECT jsonb_build_object('role',r.rolname,'schema',c.nspname,'table',c.relname,'column',NULL,'privilege',p.privilege,'grantOption',g.grant_option) AS entry
 FROM runtime r CROSS JOIN rels c CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'])p(privilege)
 CROSS JOIN (VALUES(false),(true))g(grant_option) WHERE c.relkind<>'S' AND has_table_privilege(r.oid,c.oid,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
 UNION ALL
 SELECT jsonb_build_object('role',r.rolname,'schema',c.nspname,'table',c.relname,'column',a.attname,'privilege',p.privilege,'grantOption',g.grant_option)
 FROM runtime r CROSS JOIN rels c JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
 CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option)
 WHERE c.relkind<>'S' AND has_column_privilege(r.oid,c.oid,a.attname,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)
)
SELECT jsonb_build_object(
 'systemId',(SELECT system_identifier::text FROM pg_control_system()),'database',current_database(),
 'versionMajor',split_part(current_setting('server_version'),'.',1),
 'connections',(SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()),
 'admissionBarrier',(SELECT jsonb_build_object('allowConnections',datallowconn,'connectionLimit',datconnlimit) FROM pg_database WHERE datname=current_database()),
 'roles',coalesce((SELECT jsonb_agg(jsonb_build_object('name',rolname,'canLogin',rolcanlogin,'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'inherit',rolinherit,'replication',rolreplication,'bypassRls',rolbypassrls) ORDER BY rolname) FROM runtime),'[]'::jsonb),
 'memberships',coalesce((SELECT jsonb_agg(jsonb_build_object('role',pg_get_userbyid(roleid),'member',pg_get_userbyid(member),'admin',admin_option) ORDER BY roleid,member) FROM pg_auth_members WHERE member IN (SELECT oid FROM runtime) OR roleid IN (SELECT oid FROM runtime)),'[]'::jsonb),
 'ownedObjects',coalesce((SELECT jsonb_agg(jsonb_build_object('role',pg_get_userbyid(refobjid),'databaseOid',dbid,'classOid',classid,'objectOid',objid,'subId',objsubid) ORDER BY refobjid,dbid,classid,objid,objsubid) FROM pg_shdepend WHERE refclassid='pg_authid'::regclass AND refobjid IN (SELECT oid FROM runtime) AND deptype='o'),'[]'::jsonb),
 'schemas',coalesce((SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'name',n.nspname,'usage',has_schema_privilege(r.oid,n.oid,'USAGE'),'create',has_schema_privilege(r.oid,n.oid,'CREATE'),'grantOption',has_schema_privilege(r.oid,n.oid,'USAGE WITH GRANT OPTION,CREATE WITH GRANT OPTION')) ORDER BY r.rolname,n.nspname) FROM runtime r CROSS JOIN ns n),'[]'::jsonb),
 -- Closed company databases still carry ACLs. Include them before admission can
 -- be reopened; template0 is PostgreSQL's permanently unconnectable template.
 'databases',coalesce((SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'name',d.datname,'connect',has_database_privilege(r.oid,d.oid,'CONNECT'),'create',has_database_privilege(r.oid,d.oid,'CREATE'),'temporary',has_database_privilege(r.oid,d.oid,'TEMPORARY'),'grantOption',has_database_privilege(r.oid,d.oid,'CONNECT WITH GRANT OPTION,CREATE WITH GRANT OPTION,TEMPORARY WITH GRANT OPTION')) ORDER BY r.rolname,d.datname) FROM runtime r CROSS JOIN pg_database d WHERE d.datname<>'template0' OR d.datname=current_database()),'[]'::jsonb),
 'relations',coalesce((SELECT jsonb_agg(jsonb_build_object('schema',c.nspname,'name',c.relname,'kind',c.relkind,'owner',pg_get_userbyid(c.relowner),'rowSecurity',c.relrowsecurity,'forceRowSecurity',c.relforcerowsecurity,
  'columns',coalesce((SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,'default',pg_get_expr(ad.adbin,ad.adrelid)) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),'[]'::jsonb),
  'triggers',coalesce((SELECT jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled,'definition',pg_get_triggerdef(t.oid),'functionOid',t.tgfoid) ORDER BY t.tgname) FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal),'[]'::jsonb))
  || CASE WHEN c.relrowsecurity THEN jsonb_build_object('rowSecurityPolicies',coalesce((SELECT jsonb_agg(jsonb_build_object('name',p.polname,'command',p.polcmd,'permissive',p.polpermissive,'roles',(SELECT jsonb_agg(CASE WHEN role_oid=0 THEN 'PUBLIC' ELSE pg_get_userbyid(role_oid)END ORDER BY CASE WHEN role_oid=0 THEN 'PUBLIC' ELSE pg_get_userbyid(role_oid)END)FROM unnest(p.polroles)role_oid),'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid))ORDER BY p.polname)FROM pg_policy p WHERE p.polrelid=c.oid),'[]'::jsonb))ELSE '{}'::jsonb END
  ORDER BY c.nspname,c.relname) FROM rels c),'[]'::jsonb),
 'functions',coalesce((SELECT jsonb_agg(jsonb_build_object('schema',nspname,'name',proname,'kind',prokind,'identityArguments',args,'definitionSha256',digest,'owner',pg_get_userbyid(proowner),'securityDefiner',prosecdef) ORDER BY nspname,proname,args) FROM funcs),'[]'::jsonb),
 'access',coalesce((SELECT jsonb_agg(entry ORDER BY entry::text) FROM access_rows),'[]'::jsonb),
 'sequenceAccess',coalesce((SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'schema',c.nspname,'sequence',c.relname,'privilege',p.privilege,'grantOption',g.grant_option) ORDER BY r.rolname,c.nspname,c.relname,p.privilege,g.grant_option) FROM runtime r CROSS JOIN rels c CROSS JOIN unnest(ARRAY['USAGE','SELECT','UPDATE'])p(privilege) CROSS JOIN (VALUES(false),(true))g(grant_option) WHERE c.relkind='S' AND has_sequence_privilege(r.oid,c.oid,p.privilege||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)),'[]'::jsonb),
 'functionAccess',coalesce((SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'schema',p.nspname,'name',p.proname,'identityArguments',p.args,'definitionSha256',p.digest,'grantOption',g.grant_option) ORDER BY r.rolname,p.nspname,p.proname,p.args,g.grant_option) FROM runtime r CROSS JOIN funcs p CROSS JOIN (VALUES(false),(true))g(grant_option) WHERE has_function_privilege(r.oid,p.oid,'EXECUTE'||CASE WHEN g.grant_option THEN ' WITH GRANT OPTION' ELSE '' END)),'[]'::jsonb),
 'defaultAccess',coalesce((SELECT jsonb_agg(jsonb_build_object('owner',pg_get_userbyid(d.defaclrole),'schemaOid',d.defaclnamespace,'type',d.defaclobjtype,'grantee',a.grantee,'privilege',a.privilege_type,'grantOption',a.is_grantable) ORDER BY d.oid,a.grantee,a.privilege_type) FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(NULLIF(d.defaclacl,'{}'::aclitem[]))a WHERE a.grantee=0 OR a.grantee IN (SELECT oid FROM runtime)),'[]'::jsonb),
 'systemAccess',coalesce((SELECT jsonb_agg(entry ORDER BY entry::text) FROM system_excess),'[]'::jsonb),
 'creators',coalesce((SELECT jsonb_agg(jsonb_build_object('name',c.rolname,'functionPublicExecute',EXISTS(SELECT 1 FROM creator_function_defaults d WHERE d.rolname=c.rolname AND d.grantee=0 AND d.privilege_type='EXECUTE'),'functionRuntimeGrantees',coalesce((SELECT jsonb_agg(DISTINCT pg_get_userbyid(d.grantee)) FROM creator_function_defaults d WHERE d.rolname=c.rolname AND d.grantee IN (SELECT oid FROM runtime) AND d.privilege_type='EXECUTE'),'[]'::jsonb)) ORDER BY c.rolname) FROM creators c),'[]'::jsonb),
 'authorities',jsonb_build_object('roles',coalesce((SELECT jsonb_agg(jsonb_build_object('name',rolname,'login',rolcanlogin,'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'inherit',rolinherit,'replication',rolreplication,'bypassRls',rolbypassrls) ORDER BY rolname) FROM pg_roles),'[]'::jsonb),'memberships',coalesce((SELECT jsonb_agg(jsonb_build_object('role',pg_get_userbyid(roleid),'member',pg_get_userbyid(member),'admin',admin_option,'inherit',inherit_option,'set',set_option) ORDER BY roleid,member) FROM pg_auth_members),'[]'::jsonb),'objectAclSha256',encode(sha256(convert_to(coalesce((SELECT jsonb_agg(entry ORDER BY entry::text) FROM authority_acl_rows),'[]'::jsonb)::text,'UTF8')),'hex'))
);
