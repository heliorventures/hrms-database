-- Tenant-local durable email. No business data, recipients or credentials are backfilled.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
CREATE TABLE "${schema}".tenant_email_settings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL UNIQUE,
 singleton boolean NOT NULL DEFAULT true UNIQUE CHECK(singleton),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 enabled boolean NOT NULL DEFAULT false,
 smtp_host text NOT NULL DEFAULT '',
 smtp_port integer NOT NULL DEFAULT 465 CHECK(smtp_port IN(465,587)),
 tls_mode text NOT NULL DEFAULT 'implicit' CHECK(tls_mode IN('implicit','starttls')),
 sender_name text NOT NULL DEFAULT '', sender_email text NOT NULL DEFAULT '',
 account_email text NOT NULL DEFAULT '',
 categories jsonb NOT NULL DEFAULT '{"leave":false,"approval":false,"payslip":false,"missed_punch_out":false}',
 enabled_after timestamptz, category_cutoffs jsonb NOT NULL DEFAULT '{}',
 credential_cipher bytea, credential_nonce bytea, credential_key_id text,
 updated_by uuid, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((credential_cipher IS NULL AND credential_nonce IS NULL AND credential_key_id IS NULL)
   OR (credential_cipher IS NOT NULL AND octet_length(credential_cipher) BETWEEN 17 AND 1040
    AND credential_nonce IS NOT NULL AND octet_length(credential_nonce)=12
    AND credential_key_id IS NOT NULL AND credential_key_id ~ '^[A-Za-z0-9_.:-]{1,64}$')),
 CHECK(NOT enabled OR (credential_cipher IS NOT NULL AND enabled_after IS NOT NULL)),
 CHECK((smtp_port=465 AND tls_mode='implicit') OR (smtp_port=587 AND tls_mode='starttls')),
 CHECK(jsonb_typeof(categories)='object' AND jsonb_typeof(category_cutoffs)='object')
);

-- Registry-validated isolated upgrades pass companyTenantId explicitly. The
-- colocated fresh-schema path uses exactly one authoritative registry mapping.
DO $binding$
DECLARE tenant uuid; supplied text:='${companyTenantId}'; matches integer;
BEGIN
 IF supplied ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' THEN
  tenant:=supplied::uuid;
 ELSIF to_regclass('kabipay_ops.tenant_database') IS NOT NULL THEN
  SELECT count(*), min(tenant_id::text)::uuid INTO matches,tenant
   FROM kabipay_ops.tenant_database WHERE schema_name='${schema}' AND is_active;
  IF matches<>1 THEN RAISE EXCEPTION 'EMAIL_COMPANY_BINDING_REQUIRED'; END IF;
 ELSE RAISE EXCEPTION 'EMAIL_COMPANY_BINDING_REQUIRED'; END IF;
 IF tenant IS NULL OR tenant='00000000-0000-0000-0000-000000000000'::uuid THEN
  RAISE EXCEPTION 'EMAIL_COMPANY_BINDING_REQUIRED'; END IF;
 INSERT INTO "${schema}".tenant_email_settings(tenant_id) VALUES(tenant);
END $binding$;

CREATE TABLE "${schema}".important_email_intent (
 id uuid PRIMARY KEY, tenant_id uuid NOT NULL REFERENCES "${schema}".tenant_email_settings(tenant_id),
 event_id uuid NOT NULL, recipient_key text NOT NULL CHECK(length(recipient_key) BETWEEN 1 AND 256),
 event_hash char(64) NOT NULL CHECK(event_hash ~ '^[a-f0-9]{64}$'),
 event jsonb NOT NULL, producer text NOT NULL,
 resource_type text NOT NULL CHECK(resource_type IN('leave','expense','travel','tax_proof','timesheet','profile_change','loan_request','performance_review','payslip','attendance','test')),
 resource_id uuid NOT NULL, resource_version text NOT NULL CHECK(length(resource_version) BETWEEN 1 AND 256),
 category text NOT NULL CHECK(category IN('leave','approval','payslip','missed_punch_out','test')),
 kind text NOT NULL CHECK(kind IN('action_required','outcome','payslip_available','missed_punch_out','test')),
 occurred_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK(expires_at>occurred_at),
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','CLAIMED','SUBMITTING','ACCEPTED','SKIPPED','FAILED','UNCERTAIN')),
 next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 5),
 lease_token uuid, lease_until timestamptz, settings_version bigint,
 delivery_source_tenant uuid, delivery_source_user uuid,
 terminal_at timestamptz, last_error_code text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(tenant_id,event_id,recipient_key),
 CHECK((delivery_source_tenant IS NULL)=(delivery_source_user IS NULL)),
 CHECK((state IN('ACCEPTED','SKIPPED','FAILED','UNCERTAIN'))=(terminal_at IS NOT NULL)),
 CHECK(state NOT IN('CLAIMED','SUBMITTING') OR (lease_token IS NOT NULL AND lease_until IS NOT NULL)),
 CHECK((category='leave' AND resource_type='leave' AND kind IN('action_required','outcome'))
  OR (category='approval' AND resource_type IN('expense','travel','tax_proof','timesheet','profile_change','loan_request','performance_review') AND kind IN('action_required','outcome'))
  OR (category='payslip' AND resource_type='payslip' AND kind='payslip_available')
  OR (category='missed_punch_out' AND resource_type='attendance' AND kind='missed_punch_out')
  OR (category='test' AND resource_type='test' AND kind='test'))
);
CREATE UNIQUE INDEX email_resolved_delivery_key ON "${schema}".important_email_intent
 (tenant_id,event_id,delivery_source_tenant,delivery_source_user)
 WHERE delivery_source_tenant IS NOT NULL;
CREATE INDEX email_claim_pending ON "${schema}".important_email_intent(tenant_id,next_attempt_at,id)
 WHERE state IN('PENDING','CLAIMED','SUBMITTING');

CREATE TABLE "${schema}".email_private_request_receipt (
 tenant_id uuid NOT NULL REFERENCES "${schema}".tenant_email_settings(tenant_id),
 audience text NOT NULL, purpose text NOT NULL CHECK(purpose IN('email_eligibility','email_recipient')),
 nonce uuid NOT NULL, request_hash char(64) NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(tenant_id,audience,purpose,nonce),
 CHECK(expires_at>created_at AND expires_at<=created_at+interval '60 seconds')
);
CREATE INDEX email_receipt_expiry ON "${schema}".email_private_request_receipt(tenant_id,expires_at,nonce);

CREATE FUNCTION "${schema}".email_settings_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $guard$
BEGIN
 IF TG_OP<>'UPDATE' OR (NEW.id,NEW.tenant_id,NEW.singleton) IS DISTINCT FROM (OLD.id,OLD.tenant_id,OLD.singleton)
  OR NEW.version<>OLD.version+1 THEN RAISE EXCEPTION 'EMAIL_SETTINGS_IDENTITY_OR_VERSION'; END IF;
 RETURN NEW;
END $guard$;
CREATE TRIGGER email_settings_guard BEFORE INSERT OR UPDATE OR DELETE ON "${schema}".tenant_email_settings
 FOR EACH ROW EXECUTE FUNCTION "${schema}".email_settings_guard();

-- SECURITY DEFINER here performs only immutable duplicate comparison. Producers
-- cannot read message events or delivery state through their acknowledgment ACL.
CREATE FUNCTION "${schema}".email_intent_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $guard$
DECLARE caller text:=session_user; previous record; settings record; moment timestamptz:=clock_timestamp(); active integer;
BEGIN
 IF TG_OP='INSERT' THEN
  IF caller LIKE 'hrms_company_%' AND NOT (
    (caller='hrms_company_leave' AND NEW.producer='leave' AND NEW.resource_type='leave') OR
    (caller='hrms_company_expense' AND NEW.producer='expense' AND NEW.resource_type IN('expense','travel')) OR
    (caller='hrms_company_employee' AND NEW.producer='employee' AND NEW.resource_type='profile_change') OR
    (caller='hrms_company_attendance' AND NEW.producer='attendance' AND NEW.resource_type IN('timesheet','attendance')) OR
    (caller='hrms_company_payroll' AND NEW.producer='payroll' AND NEW.resource_type IN('loan_request','payslip')) OR
    (caller='hrms_company_tax' AND NEW.producer='tax' AND NEW.resource_type='tax_proof') OR
    (caller='hrms_company_performance' AND NEW.producer='performance' AND NEW.resource_type='performance_review') OR
    (caller='hrms_company_maintenance' AND ((NEW.producer='attendance' AND NEW.resource_type='attendance') OR (NEW.producer='performance' AND NEW.resource_type='performance_review'))) OR
    (caller='hrms_company_notification' AND NEW.producer='notification' AND NEW.resource_type='test'))
   THEN RAISE EXCEPTION 'EMAIL_PRODUCER_DOMAIN'; END IF;
  -- Bind the JSON routed by the worker to the columns authorized above. A
  -- restricted producer must not hide a different domain/tenant in that body.
  IF jsonb_typeof(NEW.event)<>'object' OR
   ((NEW.event->>'tenant_id')::uuid,(NEW.event->>'event_id')::uuid,NEW.event->>'resource_type',
    (NEW.event->>'resource_id')::uuid,NEW.event->>'resource_version',NEW.event->>'category',NEW.event->>'kind',
    (NEW.event->>'occurred_at')::timestamptz,(NEW.event->>'expires_at')::timestamptz,
    CASE NEW.event#>>'{recipient,type}'
     WHEN 'local_user' THEN 'local:'||(NEW.event#>>'{recipient,user_id}')
     WHEN 'organization_principal' THEN 'organization:'||(NEW.event#>>'{recipient,principal_id}')||':'||
      (NEW.event#>>'{recipient,source_tenant_id}')||':'||(NEW.event#>>'{recipient,source_employee_id}') ELSE NULL END)
   IS DISTINCT FROM (NEW.tenant_id,NEW.event_id,NEW.resource_type,NEW.resource_id,NEW.resource_version,
    NEW.category,NEW.kind,NEW.occurred_at,NEW.expires_at,NEW.recipient_key)
   THEN RAISE EXCEPTION 'EMAIL_EVENT_COLUMN_BINDING'; END IF;
  -- Serialize immutable duplicate validation with insertion, including concurrent
  -- producers; ON CONFLICT never silently acknowledges a different event body.
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id::text||NEW.event_id::text||NEW.recipient_key,132));
  SELECT event_hash,event,producer,resource_type,resource_id,resource_version,category,kind,occurred_at,expires_at
   INTO previous FROM "${schema}".important_email_intent
   WHERE tenant_id=NEW.tenant_id AND event_id=NEW.event_id AND recipient_key=NEW.recipient_key;
  IF FOUND AND (previous.event_hash,previous.event,previous.producer,previous.resource_type,previous.resource_id,
    previous.resource_version,previous.category,previous.kind,previous.occurred_at,previous.expires_at)
   IS DISTINCT FROM (NEW.event_hash,NEW.event,NEW.producer,NEW.resource_type,NEW.resource_id,
    NEW.resource_version,NEW.category,NEW.kind,NEW.occurred_at,NEW.expires_at)
   THEN RAISE EXCEPTION 'EMAIL_IMMUTABLE_EVENT_CONFLICT'; END IF;
  IF NEW.state<>'PENDING' OR NEW.attempt_count<>0 OR NEW.terminal_at IS NOT NULL
    OR NEW.lease_token IS NOT NULL OR NEW.delivery_source_tenant IS NOT NULL THEN
   RAISE EXCEPTION 'EMAIL_INITIAL_DELIVERY_STATE'; END IF;
  RETURN NEW;
 ELSIF TG_OP='DELETE' THEN
  IF OLD.terminal_at IS NULL OR OLD.terminal_at>clock_timestamp()-interval '30 days' THEN
   RAISE EXCEPTION 'EMAIL_TERMINAL_RETENTION'; END IF;
  RETURN OLD;
 ELSIF (NEW.id,NEW.tenant_id,NEW.event_id,NEW.recipient_key,NEW.event_hash,NEW.event,NEW.producer,
    NEW.resource_type,NEW.resource_id,NEW.resource_version,NEW.category,NEW.kind,NEW.occurred_at,NEW.expires_at,NEW.created_at)
   IS DISTINCT FROM (OLD.id,OLD.tenant_id,OLD.event_id,OLD.recipient_key,OLD.event_hash,OLD.event,OLD.producer,
    OLD.resource_type,OLD.resource_id,OLD.resource_version,OLD.category,OLD.kind,OLD.occurred_at,OLD.expires_at,OLD.created_at)
  THEN RAISE EXCEPTION 'EMAIL_IMMUTABLE_EVENT';
 ELSIF OLD.terminal_at IS NOT NULL THEN RAISE EXCEPTION 'EMAIL_TERMINAL_IMMUTABLE';
 END IF;
 -- Fixed delivery transitions are a database contract, shared by every worker.
 -- attempt_count is the completed safe-retry count (initial attempt plus five retries).
 IF NEW.attempt_count<>OLD.attempt_count AND NOT (
   OLD.state IN('CLAIMED','SUBMITTING') AND NEW.state='PENDING' AND NEW.attempt_count=OLD.attempt_count+1
   AND OLD.attempt_count<5 AND NEW.next_attempt_at>moment
   AND NEW.next_attempt_at<OLD.created_at+interval '24 hours' AND NEW.next_attempt_at<OLD.expires_at
   AND (OLD.state='CLAIMED' OR (OLD.lease_until>moment AND NEW.last_error_code='EMAIL_SMTP_UNAVAILABLE')))
  THEN RAISE EXCEPTION 'EMAIL_RETRY_TRANSITION'; END IF;
 IF OLD.delivery_source_tenant IS NOT NULL AND (NEW.delivery_source_tenant,NEW.delivery_source_user)
   IS DISTINCT FROM (OLD.delivery_source_tenant,OLD.delivery_source_user)
  THEN RAISE EXCEPTION 'EMAIL_RESOLVED_IDENTITY_IMMUTABLE'; END IF;
 IF OLD.delivery_source_tenant IS NULL AND NEW.delivery_source_tenant IS NOT NULL
   AND (OLD.state<>'CLAIMED' OR NEW.state<>'CLAIMED' OR OLD.lease_until<=moment)
  THEN RAISE EXCEPTION 'EMAIL_IDENTITY_REQUIRES_LIVE_CLAIM'; END IF;
 IF NEW.state='CLAIMED' THEN
  IF NEW.lease_token IS NULL OR NEW.lease_until<=moment OR NEW.lease_until>moment+interval '90 seconds'
    OR NEW.attempt_count<>OLD.attempt_count THEN RAISE EXCEPTION 'EMAIL_CLAIM_LEASE'; END IF;
  IF OLD.state='PENDING' THEN
   -- The settings row serializes concurrent processes before counting leases.
   SELECT version INTO settings FROM "${schema}".tenant_email_settings WHERE tenant_id=NEW.tenant_id FOR UPDATE;
   SELECT count(*) INTO active FROM "${schema}".important_email_intent
    WHERE tenant_id=NEW.tenant_id AND id<>NEW.id AND state IN('CLAIMED','SUBMITTING') AND lease_until>clock_timestamp();
   IF active>=2 OR NEW.settings_version IS DISTINCT FROM settings.version THEN RAISE EXCEPTION 'EMAIL_TENANT_LEASE_LIMIT_OR_VERSION'; END IF;
  ELSIF OLD.state<>'CLAIMED' OR OLD.lease_until<=moment OR NEW.lease_token IS DISTINCT FROM OLD.lease_token
    OR NEW.settings_version IS DISTINCT FROM OLD.settings_version OR NEW.lease_until<OLD.lease_until
   THEN RAISE EXCEPTION 'EMAIL_CLAIM_TRANSITION'; END IF;
 ELSIF NEW.state='SUBMITTING' THEN
  IF OLD.state<>'CLAIMED' OR OLD.lease_until<=moment OR NEW.lease_token IS DISTINCT FROM OLD.lease_token
    OR NEW.lease_until IS DISTINCT FROM OLD.lease_until OR NEW.settings_version IS DISTINCT FROM OLD.settings_version
    OR NEW.delivery_source_tenant IS NULL OR OLD.delivery_source_tenant IS NULL OR NEW.attempt_count<>OLD.attempt_count
   THEN RAISE EXCEPTION 'EMAIL_SUBMISSION_FENCE'; END IF;
  SELECT * INTO settings FROM "${schema}".tenant_email_settings WHERE tenant_id=NEW.tenant_id FOR UPDATE;
  IF NEW.settings_version IS DISTINCT FROM settings.version OR (NEW.category='test' AND NEW.resource_version<>settings.version::text)
    OR (NEW.category<>'test' AND (NOT settings.enabled OR NOT COALESCE((settings.categories->>NEW.category)::boolean,false)
     OR settings.enabled_after IS NULL OR settings.category_cutoffs->>NEW.category IS NULL
     OR NEW.occurred_at<settings.enabled_after OR NEW.created_at<settings.enabled_after
     OR NEW.occurred_at<(settings.category_cutoffs->>NEW.category)::timestamptz
     OR NEW.created_at<(settings.category_cutoffs->>NEW.category)::timestamptz))
    OR NEW.expires_at<=moment THEN RAISE EXCEPTION 'EMAIL_SUBMISSION_SETTINGS_CHANGED'; END IF;
 ELSIF NEW.state='PENDING' THEN
  IF OLD.state NOT IN('CLAIMED','SUBMITTING') OR NEW.attempt_count<>OLD.attempt_count+1
    OR NEW.lease_token IS NOT NULL OR NEW.lease_until IS NOT NULL THEN RAISE EXCEPTION 'EMAIL_UNSAFE_RESET'; END IF;
 ELSIF NEW.state='ACCEPTED' THEN
  IF OLD.state<>'SUBMITTING' THEN RAISE EXCEPTION 'EMAIL_ACCEPTANCE_REQUIRES_SUBMISSION'; END IF;
 ELSIF NEW.state='UNCERTAIN' THEN
  IF OLD.state<>'SUBMITTING' THEN RAISE EXCEPTION 'EMAIL_UNCERTAINTY_REQUIRES_SUBMISSION'; END IF;
 ELSIF NEW.state='SKIPPED' THEN
  IF OLD.state NOT IN('PENDING','CLAIMED') THEN RAISE EXCEPTION 'EMAIL_SKIP_AFTER_SUBMISSION'; END IF;
 ELSIF NEW.state='FAILED' THEN
  IF OLD.state NOT IN('PENDING','CLAIMED','SUBMITTING') OR (OLD.state='SUBMITTING' AND OLD.lease_until<=moment)
   THEN RAISE EXCEPTION 'EMAIL_UNCERTAIN_EXPIRED_SUBMISSION'; END IF;
 ELSE RAISE EXCEPTION 'EMAIL_DELIVERY_TRANSITION'; END IF;
 IF NEW.state IN('ACCEPTED','SKIPPED','FAILED','UNCERTAIN') AND NEW.attempt_count<>OLD.attempt_count
  THEN RAISE EXCEPTION 'EMAIL_TERMINAL_RETRY_COUNT'; END IF;
 IF NEW.terminal_at IS NOT NULL THEN NEW.terminal_at:=clock_timestamp(); END IF;
 RETURN NEW;
END $guard$;
CREATE TRIGGER email_intent_guard BEFORE INSERT OR UPDATE OR DELETE ON "${schema}".important_email_intent
 FOR EACH ROW EXECUTE FUNCTION "${schema}".email_intent_guard();

CREATE FUNCTION "${schema}".email_receipt_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $guard$
BEGIN
 IF TG_OP='DELETE' AND OLD.expires_at<clock_timestamp() THEN RETURN OLD; END IF;
 IF TG_OP='INSERT' THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'EMAIL_RECEIPT_IMMUTABLE_OR_UNEXPIRED';
END $guard$;
CREATE TRIGGER email_receipt_guard BEFORE INSERT OR UPDATE OR DELETE ON "${schema}".email_private_request_receipt
 FOR EACH ROW EXECUTE FUNCTION "${schema}".email_receipt_guard();

REVOKE ALL ON "${schema}".tenant_email_settings,"${schema}".important_email_intent,"${schema}".email_private_request_receipt FROM PUBLIC;
REVOKE ALL ON FUNCTION "${schema}".email_settings_guard(),"${schema}".email_intent_guard(),"${schema}".email_receipt_guard() FROM PUBLIC;
