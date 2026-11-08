\set ON_ERROR_STOP on
BEGIN;
INSERT INTO loan_test.loan_request(id,tenant_id,employee_id,requested_amount,currency,purpose,preferences,state,version)
VALUES('40000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',10000,'INR','second fixture','{}','APPROVED',1);
INSERT INTO loan_test.loan_account(id,tenant_id,employee_id,request_id,loan_number,approved_principal,currency,minor_units,state,funding_state,rounding_carry,version)
VALUES('50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','LN-SECOND',10000,'INR',2,'OPEN','UNFUNDED',0,1);
COMMIT;
DO $$ DECLARE pid UUID:=gen_random_uuid(); BEGIN BEGIN
 INSERT INTO loan_test.loan_posting(id,tenant_id,loan_id,kind,source_kind,source_id,source_revision,value_date,amount,principal_delta,interest_delta,terms_version_id,calculation_evidence,actor_id)
 VALUES(pid,'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','DISBURSEMENT','DISBURSEMENT',gen_random_uuid(),1,'2026-10-01',1000,1000,0,'60000000-0000-0000-0000-000000000001','{}',gen_random_uuid());
 INSERT INTO loan_test.loan_ledger_entry(id,tenant_id,loan_id,posting_id,sequence,principal_delta,interest_delta)
 VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002',pid,1,1000,0);
 SET CONSTRAINTS ALL IMMEDIATE;
 RAISE EXCEPTION 'posting borrowed another account terms: test failed';
 EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $$;
SELECT 'cross-account terms test passed' AS result;

