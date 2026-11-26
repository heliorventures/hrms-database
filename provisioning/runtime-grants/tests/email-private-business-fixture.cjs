// Existing business webhook/audit prerequisites, owned synthetic fixtures only.
const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
function baseline(tenant,role){
 assert(/^[0-9a-f-]{36}$/.test(tenant));assert(['hrms_company_leave','hrms_company_expense','hrms_company_employee','hrms_company_attendance'].includes(role));
 return `SET search_path=tenant_fixture,pg_catalog;
 CREATE TABLE webhook_subscription(id uuid PRIMARY KEY,tenant_id uuid,event_name text,config_version bigint,is_active boolean,created_at timestamptz);
 CREATE TABLE private_source_cutover(tenant_id uuid PRIMARY KEY,producer_generation bigint,updated_at timestamptz DEFAULT now());
 INSERT INTO private_source_cutover(tenant_id,producer_generation) VALUES('${tenant}',1);
 CREATE TABLE company_event_outbox(id uuid PRIMARY KEY,source_tenant_id uuid,organization_id uuid,event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz);
 CREATE TABLE private_delivery_receipt(tenant_id uuid,intent_id uuid,destination_id uuid,source_kind text,resource_id uuid,intent_hash char(64),destination_version bigint,status text,created_at timestamptz,source_generation bigint,outcome_code text,updated_at timestamptz DEFAULT now(),PRIMARY KEY(tenant_id,intent_id,destination_id));
 GRANT SELECT(id,tenant_id),UPDATE(id) ON "user" TO ${role};
 GRANT SELECT,UPDATE(id) ON webhook_subscription TO ${role};
 GRANT SELECT(tenant_id,producer_generation),UPDATE(updated_at) ON private_source_cutover TO ${role};
 GRANT INSERT ON company_event_outbox TO ${role};GRANT SELECT(id) ON company_event_outbox TO ${role};
 GRANT SELECT,INSERT,UPDATE(status,outcome_code,updated_at) ON private_delivery_receipt TO ${role};`;
}
function keys(directory,tenant){
 const file=path.join(directory,'synthetic-private-event-keys.json');
 fs.writeFileSync(file,JSON.stringify({schema_version:1,keys:['audit','delivery'].map((purpose,index)=>({tenant_id:tenant,purpose,key_id:`fixture-${purpose}`,key_b64:Buffer.alloc(32,index+7).toString('base64'),active:true}))}),{flag:'wx',mode:0o600});return file;
}
module.exports={baseline,keys};
