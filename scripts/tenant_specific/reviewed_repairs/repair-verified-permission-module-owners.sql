-- Reviewed correction for the two observed 0051-002 prerequisite failures.
-- Execute using: rtk node run-sql-raw.cjs -f scripts/tenant_specific/reviewed_repairs/repair-verified-permission-module-owners.sql
-- Connection comes from hrms-database/.env. This file requires database helior.
-- Changes only permission.module_id; permission IDs, grants, scopes and migration
-- history are retained. Both corrections commit together or neither commits.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
 IF current_database() <> 'helior' THEN
  RAISE EXCEPTION 'Expected reviewed database helior, connected to %', current_database();
 END IF;
END $$;

LOCK TABLE kabipay_ops.module IN SHARE MODE;
LOCK TABLE tenant_a50902ed.permission, tenant_e6d4fc13.permission IN SHARE ROW EXCLUSIVE MODE;

DO $$
DECLARE
 target RECORD;
 ids UUID[];
 expected_id UUID;
 previous_id UUID;
 actual RECORD;
 row_count INTEGER;
BEGIN
 FOR target IN SELECT * FROM (VALUES
  ('tenant_a50902ed', 'recruitment', 'EMPLOYEE', 'RECRUITMENT'),
  ('tenant_e6d4fc13', 'compensation', 'PAYROLL', 'EMPLOYEE')
 ) AS targets(schema_name, resource, previous_module, expected_module)
 LOOP
  IF (SELECT COUNT(*) FROM kabipay_ops.tenant_database td
      JOIN kabipay_ops.tenant t ON t.id=td.tenant_id
      WHERE td.schema_name=target.schema_name AND td.db_name=current_database()
        AND td.is_active AND NOT t.is_deleted) <> 1 THEN
   RAISE EXCEPTION 'Expected one active tenant mapping for %', target.schema_name;
  END IF;

  SELECT array_agg(id) INTO ids FROM kabipay_ops.module
   WHERE UPPER(TRIM(code))=target.expected_module;
  IF COALESCE(array_length(ids,1),0) <> 1 THEN
   RAISE EXCEPTION 'Expected one module named %', target.expected_module;
  END IF;
  expected_id := ids[1];
  SELECT array_agg(id) INTO ids FROM kabipay_ops.module
   WHERE UPPER(TRIM(code))=target.previous_module;
  IF COALESCE(array_length(ids,1),0) <> 1 THEN
   RAISE EXCEPTION 'Expected one module named %', target.previous_module;
  END IF;
  previous_id := ids[1];

  EXECUTE format('SELECT count(*) FROM %I.permission WHERE lower(trim(resource))=$1 AND lower(trim(action))=''manage''',target.schema_name)
   INTO row_count USING target.resource;
  IF row_count <> 1 THEN
   RAISE EXCEPTION 'Expected one %:manage permission in %', target.resource,target.schema_name;
  END IF;
  EXECUTE format('SELECT id,resource,action,module_id FROM %I.permission WHERE lower(trim(resource))=$1 AND lower(trim(action))=''manage''',target.schema_name)
   INTO actual USING target.resource;
  IF actual.resource <> target.resource OR actual.action <> 'manage'
     OR actual.module_id IS NULL OR actual.module_id NOT IN (previous_id,expected_id) THEN
   RAISE EXCEPTION 'Permission differs from reviewed state in %; no correction committed',target.schema_name;
  END IF;
  IF actual.module_id=expected_id THEN
   RAISE NOTICE '% %:manage already belongs to %',target.schema_name,target.resource,target.expected_module;
  ELSE
   EXECUTE format('UPDATE %I.permission SET module_id=$1 WHERE id=$2 AND module_id=$3',target.schema_name)
    USING expected_id,actual.id,previous_id;
   GET DIAGNOSTICS row_count = ROW_COUNT;
   IF row_count <> 1 THEN RAISE EXCEPTION 'Expected one corrected permission'; END IF;
   RAISE NOTICE '% %:manage corrected from % to %; ID and role grants retained',
    target.schema_name,target.resource,target.previous_module,target.expected_module;
  END IF;
 END LOOP;
END $$;

COMMIT;
