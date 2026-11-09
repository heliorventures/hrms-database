-- Read the metadata registration using a separate operator-owned libpq service.
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY;
SELECT set_config('kabipay.bootstrap.operation','company',false);
SELECT set_config('kabipay.bootstrap.registry_database',:'registry_database',false),set_config('kabipay.bootstrap.database',:'database',false),set_config('kabipay.bootstrap.scope',:'scope_id',false),set_config('kabipay.bootstrap.schema',:'source_schema',false),set_config('kabipay.bootstrap.host',:'runtime_host',false);
\ir runtime-databases.template.sql
DO $registration$
DECLARE scope uuid:=current_setting('kabipay.bootstrap.scope')::uuid;matches bigint;database_name text;company_id uuid;
BEGIN
 IF current_database()<>current_setting('kabipay.bootstrap.registry_database') THEN RAISE EXCEPTION 'Registry database binding mismatch';END IF;
 SELECT count(*) INTO matches FROM kabipay_ops.tenant_database d JOIN kabipay_ops.tenant t ON t.id=d.tenant_id
 WHERE d.tenant_id=scope AND d.is_active AND d.db_type='POSTGRES' AND NOT t.is_deleted
 AND lower(d.db_host)=lower(current_setting('kabipay.bootstrap.host')) AND d.db_name=current_setting('kabipay.bootstrap.database') AND d.schema_name=current_setting('kabipay.bootstrap.schema');
 IF matches<>1 OR (SELECT count(*) FROM kabipay_ops.tenant_database WHERE tenant_id=scope AND is_active)<>1 THEN RAISE EXCEPTION 'Exact registered company source binding required';END IF;
 IF EXISTS(SELECT 1 FROM kabipay_ops.tenant_database WHERE is_active AND tenant_id<>scope AND lower(db_host)=lower(current_setting('kabipay.bootstrap.host')) AND db_name=current_setting('kabipay.bootstrap.database') AND schema_name=current_setting('kabipay.bootstrap.schema')) THEN RAISE EXCEPTION 'Source registration is shared by another company';END IF;
 -- The shared login can only be approved for uniquely owned company databases.
 -- Check ownership across the single fleet, including host aliases/wrong types.
 FOR database_name IN SELECT value FROM jsonb_array_elements_text(current_setting('kabipay.bootstrap.runtime_databases')::jsonb) LOOP
  IF database_name=current_database() OR (SELECT count(*) FROM kabipay_ops.tenant_database WHERE is_active AND db_name=database_name)<>1 THEN RAISE EXCEPTION 'Unique registered company database required: %',database_name;END IF;
  SELECT d.tenant_id INTO company_id FROM kabipay_ops.tenant_database d JOIN kabipay_ops.tenant t ON t.id=d.tenant_id
  WHERE d.is_active AND d.db_name=database_name AND d.db_type='POSTGRES'
   AND lower(d.db_host)=lower(current_setting('kabipay.bootstrap.host'))
   AND d.schema_name ~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$'
   AND lower(d.schema_name) NOT IN ('public','kabipay_ops','information_schema') AND left(lower(d.schema_name),3)<>'pg_'
   AND NOT t.is_deleted AND t.status IN ('ACTIVE','SUSPENDED');
  IF company_id IS NULL OR (SELECT count(*) FROM kabipay_ops.tenant_database WHERE is_active AND tenant_id=company_id)<>1 THEN RAISE EXCEPTION 'Exact registered company database required: %',database_name;END IF;
 END LOOP;
END $registration$;
