\set ON_ERROR_STOP on
DO $$ DECLARE pid UUID:=gen_random_uuid(); BEGIN BEGIN
 INSERT INTO loan_test.loan_posting(id,tenant_id,loan_id,kind,source_kind,source_id,source_revision,value_date,amount,principal_delta,interest_delta,terms_version_id,calculation_evidence,actor_id)
 SELECT pid,tenant_id,loan_id,kind,source_kind,source_id,source_revision+1,value_date,1000,1000,0,terms_version_id,'{}',actor_id FROM loan_test.loan_posting WHERE id='70000000-0000-0000-0000-000000000001';
 INSERT INTO loan_test.loan_ledger_entry(id,tenant_id,loan_id,posting_id,sequence,principal_delta,interest_delta)
 VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',pid,2,1000,0);
 SET CONSTRAINTS ALL IMMEDIATE;
 RAISE EXCEPTION 'same source posted under new revision: test failed';
 EXCEPTION WHEN unique_violation THEN NULL; END; END $$;
SELECT 'source revision uniqueness test passed' AS result;

