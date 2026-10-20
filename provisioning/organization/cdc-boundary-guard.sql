-- Shared fail-closed boundary checks. Parent SQL sets reviewed role/table inputs.
DO $guard$
DECLARE
 role_name text := current_setting('hrms.cdc.role');
 role_id oid;
 expected oid[];
BEGIN
 SELECT oid INTO role_id FROM pg_roles WHERE rolname=role_name AND rolcanlogin AND rolreplication
  AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole;
 IF role_id IS NULL THEN RAISE EXCEPTION 'CDC role must preexist with LOGIN REPLICATION NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE'; END IF;
 IF EXISTS(SELECT 1 FROM pg_auth_members WHERE member=role_id OR roleid=role_id) THEN RAISE EXCEPTION 'CDC role must not inherit or assume other roles'; END IF;
 IF EXISTS(SELECT 1 FROM pg_database WHERE datallowconn AND datname<>current_database() AND has_database_privilege(role_id,oid,'CONNECT')) THEN
  RAISE EXCEPTION 'CDC identity can CONNECT to another database; DBA must review PUBLIC/role grants before provisioning';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_database WHERE datdba=role_id) OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=role_id) OR EXISTS(SELECT 1 FROM pg_class WHERE relowner=role_id) THEN
  RAISE EXCEPTION 'CDC identity must not own databases, schemas or relations';
 END IF;
 SELECT array_agg(to_regclass(value)::oid) INTO expected FROM jsonb_array_elements_text(current_setting('hrms.cdc.tables')::jsonb);
 IF expected IS NULL OR array_position(expected,NULL) IS NOT NULL THEN RAISE EXCEPTION 'Expected canonical CDC table is missing'; END IF;
 IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND left(n.nspname,3)<>'pg_'
   AND c.relkind IN ('r','p','v','m','f') AND NOT c.oid=ANY(expected)
   AND (has_table_privilege(role_id,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(role_id,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) THEN
  RAISE EXCEPTION 'CDC identity has unexpected effective user-table privileges';
 END IF;
 IF EXISTS(SELECT 1 FROM unnest(expected) target WHERE has_table_privilege(role_id,target,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(role_id,target,'INSERT,UPDATE,REFERENCES')) THEN
  RAISE EXCEPTION 'CDC identity has unexpected source-table mutation privileges';
 END IF;
 -- PostgreSQL has no publication ACL: a replication identity can request any
 -- publication in its connected DB, regardless of configured connector name.
 IF EXISTS(SELECT 1 FROM pg_publication WHERE puballtables)
 OR EXISTS(SELECT 1 FROM pg_publication_namespace)
 OR EXISTS(SELECT 1 FROM pg_publication_rel WHERE NOT prrelid=ANY(expected)) THEN
  RAISE EXCEPTION 'Another publication exposes tables beyond this CDC identity boundary';
 END IF;
END $guard$;


