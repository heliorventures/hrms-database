SELECT set_config('kabipay.bootstrap.operation','company',false),set_config('kabipay.bootstrap.database',:'database',false),set_config('kabipay.bootstrap.scope',:'scope_id',false),set_config('kabipay.bootstrap.schema',:'source_schema',false),set_config('kabipay.bootstrap.role',:'runtime_role',false),set_config('kabipay.bootstrap.mode',:'bootstrap_mode',false),set_config('kabipay.bootstrap.generation',:'producer_generation',false);
\ir runtime-databases.template.sql
\ir runtime-bootstrap.sql
