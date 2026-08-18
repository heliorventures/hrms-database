-- Read-only post-migration verification for 0057_asset_management_lifecycle,
-- 0058_asset_management_integrity, 0059_file_upload_stage, and
-- 0060_private_file_cleanup. Run against one
-- tenant schema with psql:
--   psql "$DATABASE_URL" -v schema=tenant_example -f tests/asset_management_lifecycle_verification.sql
-- Every violation_count must be zero before this tenant is accepted.

WITH checks AS (
    SELECT
        'blank_category_name' AS check_name,
        COUNT(*)::BIGINT AS violation_count
    FROM :"schema".asset_category
    WHERE name IS NULL OR BTRIM(name) = ''

    UNION ALL

    SELECT
        'invalid_category_code',
        COUNT(*)::BIGINT
    FROM :"schema".asset_category
    WHERE code IS NULL
       OR BTRIM(code) = ''
       OR code <> BTRIM(code)
       OR code <> UPPER(code)

    UNION ALL

    SELECT
        'duplicate_normalized_category_code',
        COUNT(*)::BIGINT
    FROM (
        SELECT tenant_id, UPPER(BTRIM(code))
        FROM :"schema".asset_category
        GROUP BY tenant_id, UPPER(BTRIM(code))
        HAVING COUNT(*) > 1
    ) AS duplicate_codes

    UNION ALL

    SELECT
        'asset_category_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".asset AS asset
    JOIN :"schema".asset_category AS category ON category.id = asset.asset_category_id
    WHERE asset.tenant_id <> category.tenant_id

    UNION ALL

    SELECT
        'asset_location_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".asset AS asset
    JOIN :"schema".location AS location ON location.id = asset.location_id
    WHERE asset.tenant_id <> location.tenant_id

    UNION ALL

    SELECT
        'asset_allocation_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".asset_allocation AS allocation
    JOIN :"schema".asset AS asset ON asset.id = allocation.asset_id
    WHERE allocation.tenant_id <> asset.tenant_id

    UNION ALL

    SELECT
        'asset_allocation_employee_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".asset_allocation AS allocation
    JOIN :"schema".employee AS employee ON employee.id = allocation.employee_id
    WHERE allocation.tenant_id <> employee.tenant_id

    UNION ALL

    SELECT
        'asset_return_log_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".asset_return_log AS return_log
    JOIN :"schema".asset_allocation AS allocation ON allocation.id = return_log.asset_allocation_id
    WHERE return_log.tenant_id <> allocation.tenant_id

    UNION ALL

    SELECT
        'blank_asset_name',
        COUNT(*)::BIGINT
    FROM :"schema".asset
    WHERE name IS NULL OR BTRIM(name) = ''

    UNION ALL

    SELECT
        'negative_purchase_value',
        COUNT(*)::BIGINT
    FROM :"schema".asset
    WHERE purchase_value < 0

    UNION ALL

    SELECT
        'duplicate_normalized_asset_tag',
        COUNT(*)::BIGINT
    FROM (
        SELECT tenant_id, UPPER(BTRIM(asset_tag))
        FROM :"schema".asset
        WHERE NULLIF(BTRIM(asset_tag), '') IS NOT NULL
        GROUP BY tenant_id, UPPER(BTRIM(asset_tag))
        HAVING COUNT(*) > 1
    ) AS duplicate_asset_tags

    UNION ALL

    SELECT
        'duplicate_normalized_serial_number',
        COUNT(*)::BIGINT
    FROM (
        SELECT tenant_id, UPPER(BTRIM(serial_number))
        FROM :"schema".asset
        WHERE NULLIF(BTRIM(serial_number), '') IS NOT NULL
        GROUP BY tenant_id, UPPER(BTRIM(serial_number))
        HAVING COUNT(*) > 1
    ) AS duplicate_serial_numbers

    UNION ALL

    SELECT
        'retired_asset_has_active_allocation',
        COUNT(*)::BIGINT
    FROM :"schema".asset AS asset
    JOIN :"schema".asset_allocation AS allocation ON allocation.asset_id = asset.id
    WHERE asset.status = 'RETIRED'
      AND allocation.status = 'ACTIVE'

    UNION ALL

    SELECT
        'multiple_active_allocations',
        COUNT(*)::BIGINT
    FROM (
        SELECT asset_id
        FROM :"schema".asset_allocation
        WHERE status = 'ACTIVE'
        GROUP BY asset_id
        HAVING COUNT(*) > 1
    ) AS duplicate_active_allocations

    UNION ALL

    SELECT
        'duplicate_return_log',
        COUNT(*)::BIGINT
    FROM (
        SELECT asset_allocation_id
        FROM :"schema".asset_return_log
        GROUP BY asset_allocation_id
        HAVING COUNT(*) > 1
    ) AS duplicate_return_logs

    UNION ALL

    SELECT
        'asset_status_not_reconciled',
        COUNT(*)::BIGINT
    FROM :"schema".asset AS asset
    WHERE asset.status <> CASE
        WHEN asset.status = 'RETIRED' THEN 'RETIRED'
        WHEN EXISTS (
            SELECT 1
            FROM :"schema".asset_allocation AS allocation
            WHERE allocation.asset_id = asset.id
              AND allocation.status = 'ACTIVE'
        ) THEN 'ASSIGNED'
        ELSE 'AVAILABLE'
    END

    UNION ALL

    SELECT
        'company_document_file_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".company_document AS document
    JOIN :"schema".file_storage AS file ON file.id = document.file_storage_id
    WHERE document.tenant_id <> file.tenant_id

    UNION ALL

    SELECT
        'file_upload_stage_file_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage AS stage
    JOIN :"schema".file_storage AS file ON file.id = stage.file_storage_id
    WHERE stage.tenant_id <> file.tenant_id

    UNION ALL

    SELECT
        'file_upload_stage_creator_tenant_mismatch',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage AS stage
    JOIN :"schema"."user" AS creator ON creator.id = stage.created_by
    WHERE stage.tenant_id <> creator.tenant_id

    UNION ALL

    SELECT
        'file_upload_stage_invalid_purpose',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage
    WHERE purpose <> 'COMPANY_DOCUMENT'

    UNION ALL

    SELECT
        'file_upload_stage_invalid_expiry',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage
    WHERE expires_at <= created_at

    UNION ALL

    SELECT
        'file_upload_stage_unpaired_claim',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage
    WHERE (claimed_at IS NULL) <> (claimed_resource_id IS NULL)

    UNION ALL

    SELECT
        'file_upload_stage_invalid_claimed_document',
        COUNT(*)::BIGINT
    FROM :"schema".file_upload_stage AS stage
    LEFT JOIN :"schema".company_document AS document
      ON document.id = stage.claimed_resource_id
    WHERE stage.claimed_resource_id IS NOT NULL
      AND (document.id IS NULL OR stage.tenant_id <> document.tenant_id)

    UNION ALL

    SELECT
        'private_file_cleanup_invalid_status',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE status NOT IN ('PENDING', 'PROCESSING', 'FAILED', 'COMPLETED')

    UNION ALL

    SELECT
        'private_file_cleanup_negative_attempt_count',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE attempt_count < 0

    UNION ALL

    SELECT
        'private_file_cleanup_invalid_error_class',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE last_error_class IS NOT NULL
      AND last_error_class NOT IN (
          'INVALID_STORAGE_METADATA',
          'LOCAL_IO',
          'STORAGE_CONFIGURATION',
          'OBJECT_STORE',
          'UNSUPPORTED_PROVIDER'
      )

    UNION ALL

    SELECT
        'private_file_cleanup_invalid_payload',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE NOT (
        (status = 'COMPLETED'
         AND storage_path IS NULL
         AND bucket IS NULL
         AND local_root IS NULL
         AND completed_at IS NOT NULL)
        OR
        (status <> 'COMPLETED'
         AND storage_path IS NOT NULL
         AND completed_at IS NULL)
    )

    UNION ALL

    SELECT
        'private_file_cleanup_invalid_provider_coordinates',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE status <> 'COMPLETED'
      AND NOT (
          (provider = 'LOCAL' AND bucket IS NULL AND local_root IS NOT NULL)
          OR (provider = 'S3' AND bucket IS NOT NULL AND BTRIM(bucket) <> '' AND local_root IS NULL)
      )

    UNION ALL

    SELECT
        'private_file_cleanup_invalid_deduplication_key',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE deduplication_key !~ '^[0-9a-f]{64}$'

    UNION ALL

    SELECT
        'private_file_cleanup_processing_claim_missing',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE status = 'PROCESSING'
      AND claimed_at IS NULL

    UNION ALL

    SELECT
        'private_file_cleanup_nonprocessing_claim_present',
        COUNT(*)::BIGINT
    FROM :"schema".private_file_cleanup_task
    WHERE status IN ('PENDING', 'FAILED', 'COMPLETED')
      AND claimed_at IS NOT NULL

    UNION ALL

    SELECT
        'private_file_cleanup_duplicate_tenant_coordinates',
        COUNT(*)::BIGINT
    FROM (
        SELECT tenant_id, deduplication_key
        FROM :"schema".private_file_cleanup_task
        GROUP BY tenant_id, deduplication_key
        HAVING COUNT(*) > 1
    ) AS duplicate_cleanup_tasks

    UNION ALL

    SELECT
        'required_constraint_missing:' || expected.constraint_name,
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_constraint AS constraint_definition
            JOIN pg_namespace AS table_schema ON table_schema.oid = constraint_definition.connamespace
            WHERE table_schema.nspname = :'schema'
              AND constraint_definition.conname = expected.constraint_name
              AND constraint_definition.contype = expected.constraint_type
        ) THEN 0 ELSE 1 END::BIGINT
    FROM (
        VALUES
            ('chk_asset_category_code_normalized', 'c'),
            ('uq_asset_category_id_tenant', 'u'),
            ('uq_asset_id_tenant', 'u'),
            ('uq_employee_id_tenant', 'u'),
            ('uq_asset_allocation_id_tenant', 'u'),
            ('uq_location_id_tenant', 'u'),
            ('fk_asset_category_tenant', 'f'),
            ('fk_asset_location_tenant', 'f'),
            ('fk_asset_allocation_asset_tenant', 'f'),
            ('fk_asset_allocation_employee_tenant', 'f'),
            ('fk_asset_return_log_allocation_tenant', 'f'),
            ('uq_company_document_id_tenant', 'u'),
            ('uq_user_id_tenant', 'u'),
            ('uq_file_upload_stage_file', 'u'),
            ('fk_company_document_file_tenant', 'f'),
            ('fk_file_upload_stage_tenant_file', 'f'),
            ('fk_file_upload_stage_created_by_tenant', 'f'),
            ('fk_file_upload_stage_claimed_document_tenant', 'f'),
            ('chk_file_upload_stage_purpose', 'c'),
            ('chk_file_upload_stage_expiry', 'c'),
            ('chk_file_upload_stage_claim', 'c'),
            ('uq_private_file_cleanup_tenant_deduplication', 'u'),
            ('chk_private_file_cleanup_status', 'c'),
            ('chk_private_file_cleanup_attempts', 'c'),
            ('chk_private_file_cleanup_deduplication_key', 'c'),
            ('chk_private_file_cleanup_error_class', 'c'),
            ('chk_private_file_cleanup_payload', 'c'),
            ('chk_private_file_cleanup_provider_payload', 'c'),
            ('chk_private_file_cleanup_claim_lifecycle', 'c')
    ) AS expected(constraint_name, constraint_type)

    UNION ALL

    SELECT
        'required_unique_index_missing_or_wrong:' || expected.index_name,
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_indexes AS index_definition
            JOIN pg_class AS index_relation ON index_relation.relname = index_definition.indexname
            JOIN pg_namespace AS index_schema ON index_schema.oid = index_relation.relnamespace
            JOIN pg_index AS index_metadata ON index_metadata.indexrelid = index_relation.oid
            WHERE index_definition.schemaname = :'schema'
              AND index_definition.indexname = expected.index_name
              AND index_schema.nspname = :'schema'
              AND index_metadata.indisunique
              AND POSITION(
                    expected.index_fragment IN
                    REGEXP_REPLACE(REPLACE(LOWER(index_definition.indexdef), '"', ''), '\s+', ' ', 'g')
                  ) > 0
              AND CASE expected.predicate_kind
                    WHEN 'none' THEN index_metadata.indpred IS NULL
                    WHEN 'active' THEN index_metadata.indpred IS NOT NULL
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%status%'
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%active%'
                    WHEN 'nonblank' THEN index_metadata.indpred IS NOT NULL
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%is not null%'
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%btrim%'
                    ELSE FALSE
                  END
        ) THEN 0 ELSE 1 END::BIGINT
    FROM (
        VALUES
            ('uq_asset_category_tenant_code_normalized_ci', 'tenant_id, upper(code)', 'none'),
            ('uq_asset_tenant_asset_tag_ci', 'tenant_id, upper(asset_tag)', 'nonblank'),
            ('uq_asset_tenant_serial_number_ci', 'tenant_id, upper(serial_number)', 'nonblank'),
            ('uq_asset_allocation_one_active_per_asset', 'asset_id', 'active'),
            ('uq_asset_return_log_allocation', 'asset_allocation_id', 'none')
    ) AS expected(index_name, index_fragment, predicate_kind)

    UNION ALL

    SELECT
        'required_index_missing_or_wrong:' || expected.index_name,
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_indexes AS index_definition
            JOIN pg_class AS index_relation ON index_relation.relname = index_definition.indexname
            JOIN pg_namespace AS index_schema ON index_schema.oid = index_relation.relnamespace
            JOIN pg_index AS index_metadata ON index_metadata.indexrelid = index_relation.oid
            WHERE index_definition.schemaname = :'schema'
              AND index_definition.indexname = expected.index_name
              AND index_schema.nspname = :'schema'
              AND index_metadata.indisunique = expected.is_unique
              AND POSITION(
                    expected.index_fragment IN
                    REGEXP_REPLACE(REPLACE(LOWER(index_definition.indexdef), '"', ''), '\s+', ' ', 'g')
                  ) > 0
              AND LOWER(COALESCE(pg_get_expr(index_metadata.indpred, index_metadata.indrelid), ''))
                    LIKE expected.predicate_fragment
        ) THEN 0 ELSE 1 END::BIGINT
    FROM (
        VALUES
            ('uq_file_storage_tenant_id_id', 'tenant_id, id', TRUE, '%'),
            ('idx_file_upload_stage_unclaimed', 'tenant_id, purpose, created_by, expires_at', FALSE, '%claimed_at is null%')
    ) AS expected(index_name, index_fragment, is_unique, predicate_fragment)

    UNION ALL

    SELECT
        'required_index_missing_or_wrong:' || expected.index_name,
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_indexes AS index_definition
            JOIN pg_class AS index_relation ON index_relation.relname = index_definition.indexname
            JOIN pg_namespace AS index_schema ON index_schema.oid = index_relation.relnamespace
            JOIN pg_index AS index_metadata ON index_metadata.indexrelid = index_relation.oid
            WHERE index_definition.schemaname = :'schema'
              AND index_definition.indexname = expected.index_name
              AND index_schema.nspname = :'schema'
              AND NOT index_metadata.indisunique
              AND POSITION(
                    expected.index_fragment IN
                    REGEXP_REPLACE(REPLACE(LOWER(index_definition.indexdef), '"', ''), '\s+', ' ', 'g')
                  ) > 0
              AND CASE expected.predicate_kind
                    WHEN 'due' THEN index_metadata.indpred IS NOT NULL
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%pending%'
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%failed%'
                    WHEN 'processing' THEN index_metadata.indpred IS NOT NULL
                        AND LOWER(pg_get_expr(index_metadata.indpred, index_metadata.indrelid)) LIKE '%processing%'
                    ELSE FALSE
                  END
        ) THEN 0 ELSE 1 END::BIGINT
    FROM (
        VALUES
            ('idx_private_file_cleanup_due', 'tenant_id, next_attempt_at, created_at', 'due'),
            ('idx_private_file_cleanup_processing', 'tenant_id, claimed_at', 'processing')
    ) AS expected(index_name, index_fragment, predicate_kind)

    UNION ALL

    SELECT
        'required_trigger_missing:trg_file_upload_stage_updated_at',
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_trigger AS trigger_definition
            JOIN pg_class AS table_definition ON table_definition.oid = trigger_definition.tgrelid
            JOIN pg_namespace AS table_schema ON table_schema.oid = table_definition.relnamespace
            WHERE table_schema.nspname = :'schema'
              AND table_definition.relname = 'file_upload_stage'
              AND trigger_definition.tgname = 'trg_file_upload_stage_updated_at'
              AND NOT trigger_definition.tgisinternal
              AND LOWER(pg_get_triggerdef(trigger_definition.oid)) LIKE '%before update%'
              AND LOWER(pg_get_triggerdef(trigger_definition.oid)) LIKE '%execute function kabipay_ops.set_updated_at()%'
        ) THEN 0 ELSE 1 END::BIGINT

    UNION ALL

    SELECT
        'required_trigger_missing:trg_private_file_cleanup_updated_at',
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_trigger AS trigger_definition
            JOIN pg_class AS table_definition ON table_definition.oid = trigger_definition.tgrelid
            JOIN pg_namespace AS table_schema ON table_schema.oid = table_definition.relnamespace
            WHERE table_schema.nspname = :'schema'
              AND table_definition.relname = 'private_file_cleanup_task'
              AND trigger_definition.tgname = 'trg_private_file_cleanup_updated_at'
              AND NOT trigger_definition.tgisinternal
              AND LOWER(pg_get_triggerdef(trigger_definition.oid)) LIKE '%before update%'
              AND LOWER(pg_get_triggerdef(trigger_definition.oid)) LIKE '%execute function kabipay_ops.set_updated_at()%'
        ) THEN 0 ELSE 1 END::BIGINT
)
SELECT
    check_name,
    violation_count,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY check_name;
