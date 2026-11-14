-- Existing direct psql callers retain the historical runtime grant profile.
\if :{?permission_mode}
\else
\set permission_mode 'runtime'
\endif
SELECT set_config('kabipay.bootstrap.permissions',:'permission_mode',false);
