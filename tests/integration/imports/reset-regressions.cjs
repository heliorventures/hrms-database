const assert = require('node:assert/strict');

async function seedClaimedDocument(db, tenant, actor) {
  const file = (await db.query(`INSERT INTO file_storage(id,tenant_id,provider,storage_path,uploaded_by)
    VALUES(gen_random_uuid(),$1,'LOCAL','fixture/claimed.pdf',$2) RETURNING id`, [tenant, actor])).rows[0].id;
  const document = (await db.query(`INSERT INTO company_document(id,tenant_id,category,title,file_storage_id,uploaded_by)
    VALUES(gen_random_uuid(),$1,'COMPANY_POLICY','Fixture policy',$2,$3) RETURNING id`, [tenant, file, actor])).rows[0].id;
  await db.query(`INSERT INTO file_upload_stage(id,tenant_id,file_storage_id,purpose,created_by,expires_at,claimed_at,claimed_resource_id)
    VALUES(gen_random_uuid(),$1,$2,'COMPANY_DOCUMENT',$3,now()+interval '1 day',now(),$4)`, [tenant, file, actor, document]);
}

function assertClaimedDocumentPlan(plan) {
  assert.ok(!plan.reset.clear_nullable_links.some(link => link.child === 'file_upload_stage'),
    'A claimed upload must be deleted before its document, not changed into an invalid half-claimed state');
  assert.ok(plan.reset.delete_order.indexOf('file_upload_stage') < plan.reset.delete_order.indexOf('company_document'));
  assert.ok(plan.reset.delete_order.indexOf('company_document') < plan.reset.delete_order.indexOf('file_storage'));
}

const attendanceTables = ['attendance_day_profile', 'attendance_day_policy_version', 'attendance_day_window'];

async function seedAttendanceHistory(db, tenant) {
  await db.query(`INSERT INTO attendance_day_profile(tenant_id,revision,initialized_at) VALUES($1,1,now())`, [tenant]);
  const version = (await db.query(`INSERT INTO attendance_day_policy_version(id,tenant_id,effective_work_date,boundary_minutes,timezone,created_at)
    VALUES(gen_random_uuid(),$1,'2026-04-01',0,'Asia/Kolkata',now()) RETURNING id`, [tenant])).rows[0].id;
  await db.query(`INSERT INTO attendance_day_window(id,tenant_id,work_date,starts_at,ends_at,timezone,boundary_minutes,policy_version_id,created_at)
    VALUES(gen_random_uuid(),$1,'2026-09-01','2026-09-01 00:00:00+05:30','2026-09-02 00:00:00+05:30','Asia/Kolkata',0,$2,now())`, [tenant, version]);
  await assert.rejects(db.query('DELETE FROM attendance_day_window'), /immutable/);
}

async function assertAttendanceReset(db) {
  for (const table of attendanceTables) assert.equal((await db.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n, 0);
  const guards = await db.query(`SELECT count(*)::int AS n FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() AND NOT t.tgisinternal
    AND c.relname=ANY($1::text[]) AND t.tgenabled<>'D'`, [attendanceTables]);
  assert.equal(guards.rows[0].n, 3, 'Normal attendance lifecycle guards must remain enabled');
}

module.exports = { seedClaimedDocument, assertClaimedDocumentPlan, seedAttendanceHistory, assertAttendanceReset, attendanceTables };
