\set ON_ERROR_STOP on
DO $$ DECLARE policy_id UUID:=gen_random_uuid(); rules JSONB; BEGIN
 SELECT jsonb_object_agg(key,'{}'::jsonb) INTO rules FROM unnest(ARRAY['eligibility','exposure','interest','recovery','shortSalary','allocation','excessCredit','earlySettlement','exitRecovery','taxTreatment','approval']) AS fields(key);
 INSERT INTO loan_test.loan_policy_version(id,tenant_id,policy_key,version,status,currency,minor_units,effective_from,effective_to,rules,calculator_version,approved_by)
 VALUES(policy_id,'10000000-0000-0000-0000-000000000001','schema-policy-overlap',1,'ACTIVE','INR',2,DATE '2026-10-01',DATE '2026-11-01',rules,'fixture',gen_random_uuid());
 BEGIN
  INSERT INTO loan_test.loan_policy_version(id,tenant_id,policy_key,version,status,currency,minor_units,effective_from,rules,calculator_version,approved_by)
  VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','schema-policy-overlap',2,'ACTIVE','INR',2,DATE '2026-10-15',rules,'fixture',gen_random_uuid());
  RAISE EXCEPTION 'overlapping active policy accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
  UPDATE loan_test.loan_policy_version SET status='RETIRED',currency='USD' WHERE id=policy_id;
  RAISE EXCEPTION 'retirement allowed a financial policy edit';
 EXCEPTION WHEN check_violation THEN NULL; END;
 UPDATE loan_test.loan_policy_version SET status='RETIRED' WHERE id=policy_id;
 BEGIN
  UPDATE loan_test.loan_policy_version SET status='ACTIVE' WHERE id=policy_id;
  RAISE EXCEPTION 'retired immutable policy was reactivated';
 EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
DO $$ BEGIN
 BEGIN
  UPDATE loan_test.loan_request SET version=0 WHERE id='40000000-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'zero request version accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
  INSERT INTO loan_test.loan_period_override(id,tenant_id,loan_id,period_start,action,accrual_treatment,reason,actor_id,version)
  VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',DATE '2026-10-02','SKIP','CONTINUE','fixture',gen_random_uuid(),1);
  RAISE EXCEPTION 'non-period-boundary override accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 INSERT INTO loan_test.loan_period_override(id,tenant_id,loan_id,period_start,action,accrual_treatment,reason,actor_id,version)
 VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',DATE '2026-10-01','SKIP','CONTINUE','fixture',gen_random_uuid(),1);
 BEGIN
  INSERT INTO loan_test.loan_period_override(id,tenant_id,loan_id,period_start,action,accrual_treatment,reason,actor_id,version)
  VALUES(gen_random_uuid(),'10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',DATE '2026-10-01','SKIP','CONTINUE','duplicate fixture',gen_random_uuid(),1);
  RAISE EXCEPTION 'duplicate loan period override accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
SELECT 'policy, version and override constraints passed' AS result;
