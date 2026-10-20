-- psql operational entrypoint; run with provision.ps1, never caller input SQL.
SELECT current_database() = :'database' AS database_matches \gset
\if :database_matches
\else
 \echo 'Database binding mismatch'
 SELECT 1/0;
\endif
SELECT set_config('hrms.cdc.company', :'company_id', false),set_config('hrms.cdc.schema', :'source_schema', false),set_config('hrms.cdc.role', :'cdc_role', false),
 set_config('hrms.cdc.tables', jsonb_build_array(format('%I.company_event_outbox', :'source_schema'),format('%I.organization_capture_marker', :'source_schema'))::text,false);
DO $binding$
DECLARE company text:=current_setting('hrms.cdc.company'); source_schema text:=current_setting('hrms.cdc.schema');
BEGIN
 IF company !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
 OR current_setting('hrms.cdc.role')<>'organization_cdc_'||replace(company,'-','')
 OR source_schema !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$'
 OR lower(source_schema) IN ('public','kabipay_ops','information_schema') OR left(lower(source_schema),3)='pg_' THEN
  RAISE EXCEPTION 'Company CDC role/schema binding is invalid';
 END IF;
END $binding$;
\ir cdc-boundary-guard.sql
GRANT CONNECT ON DATABASE :"database" TO :"cdc_role";
GRANT USAGE ON SCHEMA :"source_schema" TO :"cdc_role";
GRANT SELECT ON :"source_schema".company_event_outbox,:"source_schema".organization_capture_marker TO :"cdc_role";
DO $publication$
DECLARE expected oid[]; publication_id oid;
BEGIN
 SELECT array_agg(to_regclass(value)::oid) INTO expected FROM jsonb_array_elements_text(current_setting('hrms.cdc.tables')::jsonb);
 SELECT oid INTO publication_id FROM pg_publication WHERE pubname='organization_company_outbox';
 IF publication_id IS NULL THEN
  EXECUTE format('CREATE PUBLICATION organization_company_outbox FOR TABLE %s',array_to_string(ARRAY(SELECT value FROM jsonb_array_elements_text(current_setting('hrms.cdc.tables')::jsonb)),','));
 ELSIF EXISTS(SELECT 1 FROM pg_publication WHERE oid=publication_id AND (puballtables OR NOT(pubinsert AND pubupdate AND pubdelete AND pubtruncate)))
 OR EXISTS(SELECT 1 FROM pg_publication_namespace WHERE pnpubid=publication_id)
 OR EXISTS(SELECT 1 FROM pg_publication_rel WHERE prpubid=publication_id AND (prqual IS NOT NULL OR prattrs IS NOT NULL))
 OR (SELECT count(*) FROM pg_publication_rel WHERE prpubid=publication_id)<>2
 OR EXISTS(SELECT 1 FROM pg_publication_rel WHERE prpubid=publication_id AND NOT prrelid=ANY(expected)) THEN
  RAISE EXCEPTION 'Existing company publication does not exactly match the reviewed two source tables';
 END IF;
END $publication$;
-- Connector slot is organization_company_<company UUID without hyphens>.
-- Logical slots are cluster-wide; monitor this exact per-company slot, bounded
-- max_slot_wal_keep_size and invalidation. No slot is created/dropped here.


