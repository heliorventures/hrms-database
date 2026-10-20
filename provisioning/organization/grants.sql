-- psql-only operational entrypoint: execute using provision.ps1.
SELECT current_database() = :'database' AS database_matches \gset
\if :database_matches
\else
  \echo 'Database binding mismatch'
  SELECT 1/0; -- ON_ERROR_STOP aborts with nonzero exit status.
\endif
DO $guard$
BEGIN
 IF EXISTS (
  SELECT 1 FROM unnest(ARRAY['organization_projection_worker','organization_projection_reader','organization_history_worker','organization_reporting_worker','organization_capture_coordinator','organization_archive_worker']) AS expected(name)
  LEFT JOIN pg_roles r ON r.rolname=expected.name
  WHERE r.oid IS NULL OR NOT r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolreplication
 ) THEN
  RAISE EXCEPTION 'Every worker role must exist with LOGIN NOSUPERUSER NOBYPASSRLS NOREPLICATION';
 END IF;
END $guard$;
-- Run manually as metadata DB administrator after creating a dedicated LOGIN
-- organization_projection_worker with a separately provisioned secret and TLS.
GRANT USAGE ON SCHEMA kabipay_ops TO organization_projection_worker;
-- Narrow definer function locks the live policy rows; no UPDATE or tenant table
-- SELECT (which could expose database configuration) is granted to the worker.
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_capture_member_active(uuid,uuid) TO organization_projection_worker;
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_capture_member_classification(uuid,uuid) TO organization_projection_worker;
GRANT SELECT,INSERT,UPDATE ON kabipay_ops.organization_inbox_projection,
 kabipay_ops.organization_directory_projection,kabipay_ops.organization_projection_fence,
 kabipay_ops.organization_projection_watermark TO organization_projection_worker;
GRANT SELECT,INSERT,UPDATE ON kabipay_ops.organization_consumer_identity,kabipay_ops.organization_consumer_checkpoint,kabipay_ops.organization_capture_barrier TO organization_projection_worker;
GRANT SELECT ON kabipay_ops.organization_capture_marker TO organization_projection_worker;
-- Provision these separate LOGIN identities out of band with distinct secrets.
GRANT USAGE ON SCHEMA kabipay_ops TO organization_history_worker,organization_reporting_worker,organization_capture_coordinator,organization_archive_worker;
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_capture_member_classification(uuid,uuid) TO organization_history_worker,organization_reporting_worker,organization_capture_coordinator,organization_archive_worker;
GRANT SELECT,INSERT,UPDATE ON kabipay_ops.organization_consumer_identity,kabipay_ops.organization_consumer_checkpoint,kabipay_ops.organization_capture_barrier TO organization_history_worker,organization_reporting_worker;
GRANT SELECT ON kabipay_ops.organization_capture_marker TO organization_history_worker,organization_reporting_worker;
GRANT SELECT,INSERT ON kabipay_ops.organization_capture_marker TO organization_capture_coordinator;
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_capture_marker_classification(uuid,uuid,uuid,bigint) TO organization_capture_coordinator,organization_projection_worker,organization_history_worker,organization_reporting_worker;
-- No worker receives reconciliation EXECUTE or receipt table mutation privileges.
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_capture_healthy(uuid,uuid,text[],integer) TO organization_projection_reader,organization_archive_worker;
GRANT SELECT ON kabipay_ops.organization_company_capture,kabipay_ops.organization_archive_manifest,kabipay_ops.organization_capture_marker TO organization_archive_worker;
GRANT EXECUTE ON FUNCTION kabipay_ops.organization_archive_member_recognized(uuid,uuid,uuid) TO organization_archive_worker;
GRANT INSERT ON kabipay_ops.organization_archive_manifest,kabipay_ops.organization_archive_access_audit TO organization_archive_worker;
-- No tenant/schema credentials or business-table grants belong to this role.
-- Separate reader identity; application must still scope each query by live policy.
GRANT USAGE ON SCHEMA kabipay_ops TO organization_projection_reader;
GRANT SELECT ON kabipay_ops.organization_inbox_projection,
 kabipay_ops.organization_directory_projection,kabipay_ops.organization_projection_watermark,kabipay_ops.organization_company_capture,kabipay_ops.organization_consumer_checkpoint,kabipay_ops.organization_capture_marker,kabipay_ops.organization_capture_barrier
 TO organization_projection_reader;


