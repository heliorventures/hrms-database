-- Read the metadata registration using a separate operator-owned libpq service.
SELECT set_config('kabipay.bootstrap.registry_database',:'registry_database',false),set_config('kabipay.bootstrap.database',:'database',false),set_config('kabipay.bootstrap.scope',:'scope_id',false),set_config('kabipay.bootstrap.schema',:'source_schema',false),set_config('kabipay.bootstrap.host',:'runtime_host',false);
DO $registration$
DECLARE scope uuid:=current_setting('kabipay.bootstrap.scope')::uuid;matches bigint;
BEGIN
 IF current_database()<>current_setting('kabipay.bootstrap.registry_database') THEN RAISE EXCEPTION 'Registry database binding mismatch';END IF;
 SELECT count(*) INTO matches FROM kabipay_ops.tenant_database d JOIN kabipay_ops.tenant t ON t.id=d.tenant_id
 WHERE d.tenant_id=scope AND d.is_active AND d.db_type='POSTGRES' AND NOT t.is_deleted
 AND lower(d.db_host)=lower(current_setting('kabipay.bootstrap.host')) AND d.db_name=current_setting('kabipay.bootstrap.database') AND d.schema_name=current_setting('kabipay.bootstrap.schema');
 IF matches<>1 OR (SELECT count(*) FROM kabipay_ops.tenant_database WHERE tenant_id=scope AND is_active)<>1 THEN RAISE EXCEPTION 'Exact registered company source binding required';END IF;
 IF EXISTS(SELECT 1 FROM kabipay_ops.tenant_database WHERE is_active AND tenant_id<>scope AND lower(db_host)=lower(current_setting('kabipay.bootstrap.host')) AND db_name=current_setting('kabipay.bootstrap.database') AND schema_name=current_setting('kabipay.bootstrap.schema')) THEN RAISE EXCEPTION 'Source registration is shared by another company';END IF;
END $registration$;
