-- Fixed metadata source, independently bound role and database.
SELECT current_database() = :'database' AS database_matches \gset
\if :database_matches
\else
 \echo 'Database binding mismatch'
 SELECT 1/0;
\endif
SELECT set_config('hrms.cdc.role','organization_control_cdc',false),
 set_config('hrms.cdc.tables','["kabipay_ops.organization_outbox"]',false);
\ir cdc-boundary-guard.sql
GRANT CONNECT ON DATABASE :"database" TO organization_control_cdc;
GRANT USAGE ON SCHEMA kabipay_ops TO organization_control_cdc;
GRANT SELECT ON kabipay_ops.organization_outbox TO organization_control_cdc;
DO $publication$
DECLARE publication_id oid;
BEGIN
 SELECT oid INTO publication_id FROM pg_publication WHERE pubname='organization_control_outbox';
 IF publication_id IS NULL THEN
  CREATE PUBLICATION organization_control_outbox FOR TABLE kabipay_ops.organization_outbox;
 ELSIF EXISTS(SELECT 1 FROM pg_publication WHERE oid=publication_id AND (puballtables OR NOT(pubinsert AND pubupdate AND pubdelete AND pubtruncate)))
 OR EXISTS(SELECT 1 FROM pg_publication_namespace WHERE pnpubid=publication_id)
 OR EXISTS(SELECT 1 FROM pg_publication_rel WHERE prpubid=publication_id AND (prqual IS NOT NULL OR prattrs IS NOT NULL))
 OR (SELECT count(*) FROM pg_publication_rel WHERE prpubid=publication_id)<>1
 OR EXISTS(SELECT 1 FROM pg_publication_rel WHERE prpubid=publication_id AND prrelid<>'kabipay_ops.organization_outbox'::regclass) THEN
  RAISE EXCEPTION 'Existing control publication differs from the exact metadata outbox';
 END IF;
END $publication$;

