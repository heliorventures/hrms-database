-- Invoked only inside the operator psql transaction. No producer role can run
-- authority initialization or grant itself these permissions.
DO $bootstrap$
DECLARE
 operation text:=current_setting('kabipay.bootstrap.operation');source_schema text:=current_setting('kabipay.bootstrap.schema');
 role_name text:=current_setting('kabipay.bootstrap.role');scope_text text:=current_setting('kabipay.bootstrap.scope');scope uuid;
 generation bigint:=current_setting('kabipay.bootstrap.generation')::bigint;mode text:=current_setting('kabipay.bootstrap.mode');
 role_id oid;authority regclass;entry record;column_entry record;existing record;relation_oid oid;source_outbox text;
 allowed_select boolean;insert_columns text[];update_columns text[];legacy_tables text[];required_tables text[];
 protected_tables text[]:=ARRAY['private_source_cutover','private_delivery_receipt','private_domain_receipt','private_survey_execution_state','private_capture_source_marker','private_capture_evidence','private_legacy_export','private_pending_migration','private_pending_destination_owner','private_outbox_cleanup_receipt','private_capture_pulse','private_capture_compaction'];
 legacy_nonempty boolean:=false;found_rows boolean;sequence_name text;column_sql text;
BEGIN
 PERFORM set_config('lock_timeout','5s',true);PERFORM set_config('statement_timeout','30s',true);
 IF current_database()<>current_setting('kabipay.bootstrap.database') OR operation NOT IN ('company','operator') OR mode NOT IN ('empty','existing') OR generation NOT BETWEEN 1 AND 9007199254740991
 OR scope_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'Private source bootstrap identity invalid';END IF;
 scope:=scope_text::uuid;
 IF source_schema !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$' OR (operation='operator' AND source_schema<>'kabipay_ops')
 OR (operation='company' AND (lower(source_schema) IN ('public','kabipay_ops','information_schema') OR left(lower(source_schema),3)='pg_'))
 OR role_name !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$' OR lower(role_name) IN ('public','postgres','kabipay_ops','information_schema') OR left(lower(role_name),3)='pg_' THEN RAISE EXCEPTION 'Private source schema/runtime role invalid';END IF;
 SELECT oid INTO role_id FROM pg_roles WHERE rolname=role_name AND rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication;
 IF role_id IS NULL OR role_name=current_user THEN RAISE EXCEPTION 'Dedicated unprivileged preexisting runtime LOGIN role required';END IF;
 IF EXISTS(SELECT 1 FROM pg_auth_members WHERE member=role_id OR roleid=role_id) THEN RAISE EXCEPTION 'Private runtime role cannot inherit, assume or be granted to other roles';END IF;
 IF EXISTS(SELECT 1 FROM pg_database WHERE datdba=role_id) OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=role_id) OR EXISTS(SELECT 1 FROM pg_class WHERE relowner=role_id) THEN RAISE EXCEPTION 'Private runtime role cannot own databases, schemas or relations';END IF;
 IF EXISTS(SELECT 1 FROM pg_database WHERE datallowconn AND datname<>current_database() AND has_database_privilege(role_id,oid,'CONNECT')) THEN RAISE EXCEPTION 'Private runtime can CONNECT to another database; review PUBLIC and role grants';END IF;
 IF EXISTS(SELECT 1 FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema') AND left(nspname,3)<>'pg_' AND has_schema_privilege(role_id,oid,'CREATE')) THEN RAISE EXCEPTION 'Private runtime cannot CREATE in user schemas';END IF;
 IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname<>source_schema AND n.nspname NOT IN ('pg_catalog','information_schema') AND left(n.nspname,3)<>'pg_' AND c.relkind IN ('r','p','v','m','f') AND (has_table_privilege(role_id,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(role_id,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) THEN RAISE EXCEPTION 'Private runtime has effective data privileges outside its source schema';END IF;
 source_outbox:=CASE WHEN operation='company' THEN 'company_event_outbox' ELSE 'organization_outbox' END;
 legacy_tables:=CASE WHEN operation='company' THEN ARRAY['audit_log','outbox_event','webhook_delivery_log','employee_finance_outbox'] ELSE ARRAY['operator_audit_log'] END;
 required_tables:=ARRAY['private_source_cutover','private_legacy_export',source_outbox];
 IF operation='company' THEN required_tables:=required_tables||ARRAY['user','employee','private_delivery_receipt','private_domain_receipt','private_survey_execution_state'];END IF;
 FOREACH source_outbox IN ARRAY required_tables LOOP
  IF to_regclass(format('%I.%I',source_schema,source_outbox)) IS NULL THEN RAISE EXCEPTION 'Required migrated source table missing: %',source_outbox;END IF;
 END LOOP;
 source_outbox:=CASE WHEN operation='company' THEN 'company_event_outbox' ELSE 'organization_outbox' END;
 authority:=to_regclass(format('%I.private_source_cutover',source_schema));
 EXECUTE format('LOCK TABLE %s IN SHARE ROW EXCLUSIVE MODE',authority);
 EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s WHERE tenant_id<>$1)',authority) INTO found_rows USING scope;
 IF found_rows THEN RAISE EXCEPTION 'Source authority already belongs to another scope';END IF;
 IF operation='company' THEN
  -- tenant_id owns each local business row. source_tenant_id owns publication
  -- rows only; other tables can legitimately record foreign organization actors
  -- or incoming source references (for example organization_command_receipt).
  FOR entry IN SELECT c.relname,a.attname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid WHERE n.nspname=source_schema AND c.relkind IN ('r','p') AND (a.attname='tenant_id' OR (c.relname=source_outbox AND a.attname='source_tenant_id')) AND a.atttypid='uuid'::regtype AND a.attnum>0 AND NOT a.attisdropped LOOP
   EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE %I IS NOT NULL AND %I<>$1)',source_schema,entry.relname,entry.attname,entry.attname) INTO found_rows USING scope;
   IF found_rows THEN RAISE EXCEPTION 'Company source contains another tenant identity in %',entry.relname;END IF;
  END LOOP;
 END IF;
 -- Compare existing effective permissions, including PUBLIC and column grants,
 -- before adding anything. Broad grants are an operator correction, never an
 -- automatic REVOKE that could silently alter existing business permissions.
 FOR entry IN SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=source_schema AND c.relkind IN ('r','p','v','m','f') AND (c.relname=ANY(protected_tables) OR c.relname=source_outbox OR c.relname=ANY(legacy_tables)) LOOP
  allowed_select:=entry.relname IN ('private_source_cutover','private_legacy_export','private_delivery_receipt','private_domain_receipt','private_survey_execution_state',source_outbox);
  insert_columns:=CASE entry.relname
   WHEN 'company_event_outbox' THEN ARRAY['id','source_tenant_id','organization_id','event_type','aggregate_type','aggregate_id','aggregate_version','event_envelope','event_stream','created_at']
   WHEN 'organization_outbox' THEN ARRAY['id','organization_id','source_tenant_id','actor_principal_id','aggregate_id','aggregate_version','event_type','schema_version','payload','event_stream','created_at']
   WHEN 'private_delivery_receipt' THEN ARRAY['tenant_id','intent_id','destination_id','source_kind','resource_id','intent_hash','destination_version','status','created_at','source_generation']
   WHEN 'private_domain_receipt' THEN ARRAY['id','tenant_id','event_type','aggregate_type','aggregate_id','occurred_at','source_hash']
   WHEN 'private_survey_execution_state' THEN ARRAY['tenant_id','survey_id','opened_at','last_transition_action','last_transition_at','last_transition_id'] ELSE ARRAY[]::text[] END;
  update_columns:=CASE entry.relname
   WHEN 'private_source_cutover' THEN ARRAY['updated_at'] -- SELECT FOR SHARE needs one UPDATE column; no authority/evidence field is writable.
   WHEN 'private_delivery_receipt' THEN ARRAY['status','lease_generation','lease_until','claim_owner','accepted_at','acknowledgement_id','broker_owned_at','broker_owner_id','broker_receipt_sha256','outcome_code','outcome_sha256','updated_at']
   WHEN 'private_survey_execution_state' THEN ARRAY['opened_at','last_transition_action','last_transition_at','last_transition_id'] ELSE ARRAY[]::text[] END;
  IF has_table_privilege(role_id,entry.oid,'DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_table_privilege(role_id,entry.oid,'SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION,UPDATE WITH GRANT OPTION') THEN RAISE EXCEPTION 'Unexpected private runtime table mutation/grant privileges on %',entry.relname;END IF;
  FOR column_entry IN SELECT attname FROM pg_attribute WHERE attrelid=entry.oid AND attnum>0 AND NOT attisdropped LOOP
   IF (NOT allowed_select AND has_column_privilege(role_id,entry.oid,column_entry.attname,'SELECT')) OR (NOT column_entry.attname=ANY(insert_columns) AND has_column_privilege(role_id,entry.oid,column_entry.attname,'INSERT')) OR (NOT column_entry.attname=ANY(update_columns) AND has_column_privilege(role_id,entry.oid,column_entry.attname,'UPDATE')) OR has_column_privilege(role_id,entry.oid,column_entry.attname,'REFERENCES,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION,UPDATE WITH GRANT OPTION') THEN RAISE EXCEPTION 'Unexpected private runtime effective column privileges on %.%',entry.relname,column_entry.attname;END IF;
  END LOOP;
  IF allowed_select THEN EXECUTE format('GRANT SELECT ON %s TO %I',entry.oid::regclass,role_name);END IF;
  IF cardinality(insert_columns)>0 THEN SELECT string_agg(format('%I',x),',') INTO column_sql FROM unnest(insert_columns)x;EXECUTE format('GRANT INSERT(%s) ON %s TO %I',column_sql,entry.oid::regclass,role_name);END IF;
  IF cardinality(update_columns)>0 THEN SELECT string_agg(format('%I',x),',') INTO column_sql FROM unnest(update_columns)x;EXECUTE format('GRANT UPDATE(%s) ON %s TO %I',column_sql,entry.oid::regclass,role_name);END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=source_schema AND (left(p.proname,16)='private_capture_' OR left(p.proname,22)='private_legacy_export_' OR p.proname IN ('private_fence_legacy','private_source_digest','private_dependency_digest','private_assert_pending_migration','private_assert_retirement','private_cleanup_outbox')) AND p.prorettype<>'trigger'::regtype AND has_function_privilege(role_id,p.oid,'EXECUTE')) THEN RAISE EXCEPTION 'Private runtime can execute operator evidence/capture/retirement functions';END IF;
 EXECUTE format('SELECT * FROM %s WHERE tenant_id=$1 FOR UPDATE',authority) INTO existing USING scope;
 IF existing.tenant_id IS NOT NULL THEN
  IF existing.source_database<>current_database() OR existing.source_schema<>source_schema OR existing.producer_generation<>generation OR existing.state<>'PREPARED' OR existing.writers_fenced OR existing.reader_switch_complete OR existing.business_state_complete OR existing.pending_ownership_complete OR existing.source_version<>'private-events-v1' THEN RAISE EXCEPTION 'Existing source authority differs or advanced; bootstrap never resets it';END IF;
 ELSE
  FOREACH source_outbox IN ARRAY legacy_tables LOOP
   relation_oid:=to_regclass(format('%I.%I',source_schema,source_outbox));IF relation_oid IS NULL THEN RAISE EXCEPTION 'New authority requires explicit intact legacy/empty source inventory';END IF;
   EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s)',relation_oid::regclass) INTO found_rows;legacy_nonempty:=legacy_nonempty OR found_rows;
  END LOOP;
  IF (mode='empty' AND legacy_nonempty) OR (mode='existing' AND NOT legacy_nonempty) THEN RAISE EXCEPTION 'Explicit legacy inventory classification does not match source rows';END IF;
  EXECUTE format('INSERT INTO %s(tenant_id,source_database,source_schema,producer_generation) VALUES($1,current_database(),$2,$3)',authority) USING scope,source_schema,generation;
 END IF;
 EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',current_database(),role_name);EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I',source_schema,role_name);
 source_outbox:=CASE WHEN operation='company' THEN 'company_event_outbox' ELSE 'organization_outbox' END;
 sequence_name:=pg_get_serial_sequence(format('%I.%I',source_schema,source_outbox),'source_position');
 IF sequence_name IS NOT NULL THEN
  IF has_sequence_privilege(role_id,sequence_name,'UPDATE') THEN RAISE EXCEPTION 'Private runtime cannot reset source publication sequence';END IF;
  EXECUTE format('GRANT USAGE ON SEQUENCE %s TO %I',sequence_name,role_name);
 END IF;
END $bootstrap$;
