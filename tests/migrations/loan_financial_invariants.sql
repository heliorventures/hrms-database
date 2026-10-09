\set ON_ERROR_STOP on
BEGIN;
INSERT INTO loan_test.employee VALUES('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
INSERT INTO loan_test.loan_policy_version(id,tenant_id,policy_key,version,status,currency,minor_units,effective_from,rules,calculator_version) VALUES('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','fixture',1,'DRAFT','INR',2,DATE '2026-10-01','{}'::jsonb,'fixture');
INSERT INTO loan_test.loan_request(id,tenant_id,employee_id,requested_amount,currency,purpose,preferences,state,version) VALUES('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',10000,'INR','fixture','{}'::jsonb,'APPROVED',1);
INSERT INTO loan_test.loan_account(id,tenant_id,employee_id,request_id,loan_number,approved_principal,currency,minor_units,state,funding_state,rounding_carry,version) VALUES('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','LN-TEST',10000,'INR',2,'OPEN','FUNDED',0,1);
INSERT INTO loan_test.loan_terms_version(id,tenant_id,loan_id,policy_version_id,version,effective_from,terms,approved_by,agreement_evidence) VALUES('60000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',1,DATE '2026-10-01','{}'::jsonb,gen_random_uuid(),'{}'::jsonb);
INSERT INTO loan_test.loan_posting(id,tenant_id,loan_id,kind,source_kind,source_id,source_revision,value_date,amount,principal_delta,interest_delta,terms_version_id,calculation_evidence,actor_id) VALUES('70000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','DISBURSEMENT','DISBURSEMENT',gen_random_uuid(),1,DATE '2026-10-01',10000,10000,0,'60000000-0000-0000-0000-000000000001','{}'::jsonb,gen_random_uuid());
INSERT INTO loan_test.loan_ledger_entry(id,tenant_id,loan_id,posting_id,sequence,principal_delta,interest_delta) VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',1,10000,0);
COMMIT;
DO $$ BEGIN
 BEGIN UPDATE loan_test.loan_ledger_entry SET principal_delta=9999; RAISE EXCEPTION 'immutable ledger test failed'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN DELETE FROM loan_test.loan_posting; RAISE EXCEPTION 'immutable posting test failed'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN INSERT INTO loan_test.loan_command_receipt(id,tenant_id,actor_id,idempotency_key,command,payload_hash,result)
 VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','','test',repeat('a',64),'{}'); RAISE EXCEPTION 'empty idempotency test failed'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
DO $$ DECLARE pid UUID:=gen_random_uuid(); BEGIN
BEGIN
INSERT INTO loan_test.loan_posting(id,tenant_id,loan_id,kind,source_kind,source_id,source_revision,value_date,amount,principal_delta,interest_delta,terms_version_id,calculation_evidence,actor_id) VALUES(pid,'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','DISBURSEMENT','DISBURSEMENT',gen_random_uuid(),1,DATE '2026-10-01',1000,1000,0,'60000000-0000-0000-0000-000000000001','{}'::jsonb,gen_random_uuid());
INSERT INTO loan_test.loan_ledger_entry(id,tenant_id,loan_id,posting_id,sequence,principal_delta,interest_delta) VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',pid,2,999,0);
SET CONSTRAINTS ALL IMMEDIATE;
RAISE EXCEPTION 'unbalanced posting test failed'; EXCEPTION WHEN check_violation THEN NULL; END; END $$;
DO $$ DECLARE pid UUID:=gen_random_uuid(); BEGIN
BEGIN
INSERT INTO loan_test.loan_posting(id,tenant_id,loan_id,kind,source_kind,source_id,source_revision,value_date,amount,principal_delta,interest_delta,terms_version_id,calculation_evidence,actor_id) VALUES(pid,'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','REPAYMENT','RECEIPT',gen_random_uuid(),1,DATE '2026-10-01',11000,-11000,0,'60000000-0000-0000-0000-000000000001','{}'::jsonb,gen_random_uuid());
INSERT INTO loan_test.loan_ledger_entry(id,tenant_id,loan_id,posting_id,sequence,principal_delta,interest_delta) VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',pid,2,-11000,0);
INSERT INTO loan_test.loan_allocation(id,tenant_id,loan_id,posting_id,principal,interest,direction) VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',pid,11000,0,'RECOVER');
SET CONSTRAINTS ALL IMMEDIATE;
RAISE EXCEPTION 'negative loan balance test failed'; EXCEPTION WHEN check_violation THEN NULL; END; END $$;
DO $$ BEGIN BEGIN
INSERT INTO loan_test.loan_account(id,tenant_id,employee_id,request_id,loan_number,approved_principal,currency,minor_units,state,funding_state,rounding_carry,version) VALUES(gen_random_uuid(),gen_random_uuid(),'20000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','BAD-TENANT',10000,'INR',2,'OPEN','UNFUNDED',0,1);
SET CONSTRAINTS ALL IMMEDIATE;
RAISE EXCEPTION 'cross-tenant foreign key test failed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END; END $$;
SELECT 'loan database invariant tests passed' AS result;

