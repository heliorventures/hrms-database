-- Shared by registry/source entrypoints. The default preserves isolated roles.
\if :{?runtime_databases_b64}
\else
\set runtime_databases_b64 'W10='
\endif
SELECT set_config('kabipay.bootstrap.runtime_databases',convert_from(decode(:'runtime_databases_b64','base64'),'UTF8'),false);
DO $runtime_databases$
DECLARE values_json jsonb:=current_setting('kabipay.bootstrap.runtime_databases')::jsonb;names text[];
BEGIN
 IF jsonb_typeof(values_json)<>'array' THEN RAISE EXCEPTION 'Invalid company database list';END IF;
 IF jsonb_array_length(values_json)>100 OR EXISTS(SELECT 1 FROM jsonb_array_elements(values_json) v WHERE jsonb_typeof(v)<>'string') THEN RAISE EXCEPTION 'Invalid company database list';END IF;
 SELECT COALESCE(array_agg(value),ARRAY[]::text[]) INTO names FROM jsonb_array_elements_text(values_json);
 IF cardinality(names)>0 THEN
  IF current_setting('kabipay.bootstrap.operation')<>'company' THEN RAISE EXCEPTION 'Operator sources cannot use a shared company database list';END IF;
  IF NOT current_setting('kabipay.bootstrap.database')=ANY(names)
   OR cardinality(names)<>(SELECT count(DISTINCT n) FROM unnest(names)n)
   OR EXISTS(SELECT 1 FROM unnest(names)n WHERE n !~ '^[A-Za-z_][A-Za-z0-9_-]{0,62}$'
    OR lower(n) IN ('public','postgres','template0','template1','kabipay_ops','information_schema') OR left(lower(n),3)='pg_')
  THEN RAISE EXCEPTION 'Invalid company database allowlist';END IF;
 END IF;
END $runtime_databases$;
