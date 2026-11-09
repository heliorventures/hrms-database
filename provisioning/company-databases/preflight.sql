-- Metadata only. Invoke psql -X -qAt -v ON_ERROR_STOP=1 -v expected_database=helior.
-- Completion means collection succeeded, NOT that migration is safe to execute.
\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
\pset pager off
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '3s';
SET LOCAL idle_in_transaction_session_timeout = '60s';
SELECT set_config('kabipay.preflight.expected_database', :'expected_database', true) AS expected_database \gset
DO $guard$
BEGIN
 IF current_database() <> current_setting('kabipay.preflight.expected_database') THEN
  RAISE EXCEPTION 'Source database mismatch';
 END IF;
 IF current_setting('transaction_read_only') <> 'on' THEN
  RAISE EXCEPTION 'Read-only transaction required';
 END IF;
 IF to_regclass('kabipay_ops.tenant') IS NULL OR to_regclass('kabipay_ops.tenant_database') IS NULL THEN
  RAISE EXCEPTION 'Central tenant registry missing';
 END IF;
END $guard$;

WITH tenants AS (
 SELECT t.id,t.subdomain,t.status,
  COALESCE((SELECT jsonb_agg(jsonb_build_object('mapping_id',d.id,'db_type',d.db_type,
   'db_host',d.db_host,'db_name',d.db_name,'schema_name',d.schema_name,
   'database_name_matches',d.db_name=current_database(),
   'schema_name_present_in_connected_database',to_regnamespace(d.schema_name) IS NOT NULL)
   ORDER BY d.id) FROM kabipay_ops.tenant_database d WHERE d.tenant_id=t.id AND d.is_active),'[]'::jsonb) AS mappings
 FROM kabipay_ops.tenant t WHERE NOT t.is_deleted AND t.status IN ('ACTIVE','SUSPENDED')
), schemas AS (
 SELECT n.oid,n.nspname FROM pg_namespace n
 WHERE n.nspname LIKE 'tenant\_%' ESCAPE '\' OR EXISTS (
  SELECT 1 FROM kabipay_ops.tenant_database d WHERE d.is_active AND d.db_name=current_database() AND d.schema_name=n.nspname
 )
), fks AS (
 SELECT a.nspname AS source_schema,c.relname AS source_table,k.conname AS constraint_name,
  b.nspname AS referenced_schema,r.relname AS referenced_table,k.convalidated AS validated
 FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace a ON a.oid=c.relnamespace
 JOIN pg_class r ON r.oid=k.confrelid JOIN pg_namespace b ON b.oid=r.relnamespace
 WHERE k.contype='f' AND a.oid<>b.oid AND (a.oid IN(SELECT oid FROM schemas) OR b.oid IN(SELECT oid FROM schemas))
), triggers AS (
 SELECT n.nspname AS source_schema,c.relname AS source_table,pn.nspname AS function_schema,
  p.proname AS function_name,md5(pg_get_functiondef(p.oid)) AS definition_md5,count(*) AS trigger_count
 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN schemas n ON n.oid=c.relnamespace
 JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
 WHERE NOT t.tgisinternal AND pn.oid<>n.oid
 GROUP BY n.nspname,c.relname,pn.nspname,p.proname,p.oid
), dependencies AS (
 SELECT DISTINCT a.type AS object_type,a.schema AS source_schema,a.identity AS object_identity,
  b.type AS referenced_type,b.schema AS referenced_schema,b.identity AS referenced_identity
 FROM pg_depend d
 CROSS JOIN LATERAL pg_identify_object(d.classid,d.objid,d.objsubid) a
 CROSS JOIN LATERAL pg_identify_object(d.refclassid,d.refobjid,d.refobjsubid) b
 WHERE a.schema IS NOT NULL AND b.schema IS NOT NULL AND a.schema<>b.schema
  AND (a.schema IN(SELECT nspname FROM schemas) OR b.schema IN(SELECT nspname FROM schemas))
  AND a.schema NOT IN('pg_catalog','information_schema') AND b.schema NOT IN('pg_catalog','information_schema')
), views AS (
 SELECT DISTINCT vn.nspname AS view_schema,v.relname AS view_name,
  rn.nspname AS referenced_schema,r.relname AS referenced_relation
 FROM pg_rewrite w JOIN pg_class v ON v.oid=w.ev_class JOIN pg_namespace vn ON vn.oid=v.relnamespace
 JOIN pg_depend d ON d.classid='pg_rewrite'::regclass AND d.objid=w.oid AND d.refclassid='pg_class'::regclass
 JOIN pg_class r ON r.oid=d.refobjid JOIN pg_namespace rn ON rn.oid=r.relnamespace
 WHERE v.relkind IN('v','m') AND vn.oid<>rn.oid
  AND (vn.oid IN(SELECT oid FROM schemas) OR rn.oid IN(SELECT oid FROM schemas))
), relations AS (
 SELECT n.nspname AS schema,c.relname AS name,c.relkind AS kind,
  c.reltuples::bigint AS estimated_rows,pg_total_relation_size(c.oid) AS bytes,
  c.relrowsecurity AS rls,c.relforcerowsecurity AS force_rls,
  c.relpersistence AS persistence,pg_get_userbyid(c.relowner) AS owner
 FROM pg_class c JOIN schemas n ON n.oid=c.relnamespace WHERE c.relkind IN('r','p','v','m','f','S')
), history_tables AS (
 SELECT n.nspname AS schema,
  to_regclass(format('%I.%I',n.nspname,n.nspname||'_databasechangelog')) IS NOT NULL AS history_present,
  to_regclass(format('%I.databasechangeloglock',n.nspname)) IS NOT NULL AS lock_table_present
 FROM schemas n
)
SELECT jsonb_build_object(
 'section','inventory','format_version',1,'collected_at',transaction_timestamp(),
 'database',current_database(),'server_version',current_setting('server_version'),
 'server_address',inet_server_addr(),'server_port',inet_server_port(),
 'transaction_read_only',current_setting('transaction_read_only'),
 'tenants',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM tenants t),'[]'::jsonb),
 'settings',(SELECT jsonb_agg(jsonb_build_object('name',name,'setting',setting,'unit',unit,'pending_restart',pending_restart) ORDER BY name)
  FROM pg_settings WHERE name IN('max_connections','superuser_reserved_connections','reserved_connections',
   'wal_level','max_replication_slots','max_wal_senders','max_slot_wal_keep_size','ssl')),
 'connections',(SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM
  (SELECT datname,usename,state,count(*) AS connections FROM pg_stat_activity GROUP BY datname,usename,state ORDER BY datname,usename,state) x),
 'databases',(SELECT jsonb_agg(jsonb_build_object('name',datname,'owner',pg_get_userbyid(datdba),
   'bytes',pg_database_size(oid),'allow_connections',datallowconn) ORDER BY datname) FROM pg_database WHERE NOT datistemplate),
 'slots',(SELECT COALESCE(jsonb_agg(jsonb_build_object('name',slot_name,'type',slot_type,'database',database,
   'active',active,'wal_status',wal_status,'retained_bytes',CASE WHEN restart_lsn IS NOT NULL AND NOT pg_is_in_recovery()
    THEN pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn) END)),'[]'::jsonb) FROM pg_replication_slots),
 'extensions',(SELECT jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname) ORDER BY e.extname)
   FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),
 'large_object_count',(SELECT count(*) FROM pg_largeobject_metadata),
 'foreign_keys',COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY source_schema,source_table,constraint_name) FROM fks f),'[]'::jsonb),
 'external_triggers',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY source_schema,source_table,function_name) FROM triggers t),'[]'::jsonb),
 'external_dependencies',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY source_schema,object_identity,referenced_identity) FROM dependencies d),'[]'::jsonb),
 'external_views',COALESCE((SELECT jsonb_agg(to_jsonb(v) ORDER BY view_schema,view_name,referenced_relation) FROM views v),'[]'::jsonb),
 'relations',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY schema,name) FROM relations r),'[]'::jsonb),
 'history_tables',COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY schema) FROM history_tables h),'[]'::jsonb),
 'limitations',jsonb_build_array('Estimated rows are not reconciliation counts.',
  'Catalog dependencies do not prove absence of dynamic SQL, application references or external file dependencies.',
  'Connection counts are a snapshot, not peak load or a capacity test.',
  'Matching database/schema names do not verify a registry host resolves to this server.',
  'Collection completion is not deployment approval.')
);

-- Object names come only from the catalog and are identifier-quoted by format.
-- Historical entries contain no business rows; only five latest entries are returned.
SELECT format($query$
 SELECT jsonb_build_object('section','history','schema',%L,'table',%L,
  'applied_count',(SELECT count(*) FROM %I.%I),
  'latest',(SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY orderexecuted DESC),'[]'::jsonb)
    FROM (SELECT id,author,filename,orderexecuted FROM %I.%I ORDER BY orderexecuted DESC LIMIT 5) h));
 $query$,n.nspname,c.relname,n.nspname,c.relname,n.nspname,c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND ((n.nspname='public' AND c.relname='databasechangelog') OR
 (c.relname=n.nspname||'_databasechangelog' AND EXISTS(SELECT 1 FROM kabipay_ops.tenant_database d
  WHERE d.is_active AND d.db_name=current_database() AND d.schema_name=n.nspname)))
ORDER BY n.nspname,c.relname
\gexec

SELECT format('SELECT jsonb_build_object(''section'',''migration_lock'',''schema'',%L,''locked'',locked) FROM %I.%I;',n.nspname,n.nspname,c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND c.relname='databasechangeloglock' AND (n.nspname='public' OR
 EXISTS(SELECT 1 FROM kabipay_ops.tenant_database d WHERE d.is_active AND d.db_name=current_database() AND d.schema_name=n.nspname))
ORDER BY n.nspname
\gexec
COMMIT;
SELECT jsonb_build_object('section','complete','format_version',1,'database',current_database(),'readiness','not_assessed');
