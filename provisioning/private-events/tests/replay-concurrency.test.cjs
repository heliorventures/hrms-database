const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {Client}=require('pg');
const {fixture}=require('./local-postgres-fixture.cjs');

const root=path.resolve(__dirname,'../../..');
const migration=fs.readFileSync(path.join(root,'changelog/migrations/0125_private_event_source/private_event_source.xml'),'utf8');
const rust=fs.readFileSync(path.join(root,'../hrms-svc/crates/kabipay-common/src/private_events/delivery_history_client.rs'),'utf8');
const events=fs.readFileSync(path.join(root,'../hrms-svc/crates/kabipay-common/src/private_events/mod.rs'),'utf8');
const tenant='11111111-1111-4111-8111-111111111111';
const intent='22222222-2222-4222-8222-222222222222';
const destination='33333333-3333-4333-8333-333333333333';
const event='44444444-4444-4444-8444-444444444444';
const marker='55555555-5555-4555-8555-555555555555';
const evidence='66666666-6666-4666-8666-666666666666';
const hash='a'.repeat(64);

function sourceSql(source,prefix) {
  const literals=[...source.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map(m=>m[1]);
  const value=literals.find(sql=>sql.startsWith(prefix));
  assert(value,'Production SQL missing: '+prefix);
  return JSON.parse('"'+value+'"');
}
const receiptSql=sourceSql(rust,'SELECT r.*,a.producer_generation FROM private_source_cutover');
const framesSql=sourceSql(rust,'SELECT event_envelope FROM company_event_outbox WHERE source_tenant_id=$1');
const replaySql=sourceSql(rust,"UPDATE private_delivery_receipt SET status='PENDING'");
const insertSql=sourceSql(events,'INSERT INTO company_event_outbox(id,source_tenant_id');
function table(name) {
  const start=migration.indexOf('CREATE TABLE "${schema}".'+name+' (');
  // The cleanup receipt declaration intentionally has no space before '('.
  const actual=start<0?migration.indexOf('CREATE TABLE "${schema}".'+name+'('):start;
  assert(actual>=0,name);const end=migration.indexOf('\n);',actual);assert(end>actual);
  return migration.slice(actual,end+3).replaceAll('${schema}','source');
}
function fn(name) {
  const start=migration.indexOf('CREATE FUNCTION "${schema}".'+name+'(');
  assert(start>=0,name);const end=migration.indexOf('END $fn$;',start);assert(end>start);
  return migration.slice(start,end+10).replaceAll('${schema}','source');
}
const frame={schema_version:1,event_id:event,tenant_id:tenant,purpose:'delivery',source_generation:1,
  record_id:intent,resource_type:'delivery_intent',resource_id:intent,source_kind:'webhook',
  key_id:'synthetic-test-key',nonce:'AAAAAAAAAAAAAAAA',ciphertext:'c3ludGhldGlj',
  source_sha256:hash,source_size:9,frame_index:0,frame_count:1,occurred_at:'2026-01-01T00:00:00Z'};

async function connect(pg,role) {
  const client=new Client(pg.connection('postgres',role));await client.connect();
  await client.query('SET search_path=source,public; SET statement_timeout=15000');
  return client;
}
async function blocked(observer,pid) {
  const deadline=Date.now()+5000;
  while(Date.now()<deadline) {
    const result=await observer.query("SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1",[pid]);
    if(result.rows[0]?.wait_event_type==='Lock')return;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  assert.fail('Expected actual PostgreSQL row-lock wait');
}
async function seed(owner) {
  await owner.query('TRUNCATE source.private_outbox_cleanup_receipt,source.company_event_outbox,source.private_delivery_receipt RESTART IDENTITY');
  await owner.query(`INSERT INTO source.private_delivery_receipt(tenant_id,intent_id,destination_id,source_kind,resource_id,intent_hash,destination_version,status,source_generation) VALUES($1,$2,$3,'webhook',$2,$4,1,'PERMANENT',1)`,[tenant,intent,destination,hash]);
  await owner.query(insertSql,[JSON.stringify([frame])]);
}
async function prepare(pg) {
  pg.query('postgres',`CREATE SCHEMA source;
${['private_source_cutover','private_delivery_receipt','private_capture_source_marker','private_capture_evidence','private_outbox_cleanup_receipt'].map(table).join('\n')}
CREATE TABLE source.company_event_outbox(id uuid PRIMARY KEY,source_tenant_id uuid,organization_id uuid,event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz,source_position bigserial);
${fn('private_outbox_guard')}
${fn('private_receipt_guard')}
${fn('private_cleanup_outbox')}
CREATE TRIGGER private_outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON source.company_event_outbox FOR EACH ROW EXECUTE FUNCTION source.private_outbox_guard();
CREATE TRIGGER private_receipt_guard BEFORE UPDATE OR DELETE ON source.private_delivery_receipt FOR EACH ROW EXECUTE FUNCTION source.private_receipt_guard();
INSERT INTO source.private_source_cutover(tenant_id,source_database,source_schema) VALUES('${tenant}',current_database(),'source');
INSERT INTO source.private_capture_source_marker(id,tenant_id,producer_generation,through_position,source_lsn) VALUES('${marker}','${tenant}',1,100,'0/1');
INSERT INTO source.private_capture_evidence(id,source_marker_id,source_lsn,tenant_id,purpose,producer_generation,through_position,expected_partitions,covered_partitions,archive_sha256,restore_sha256,restore_verified_at,accepted_at,expires_at,accepted_by,acceptance_sha256)
VALUES('${evidence}','${marker}','0/1','${tenant}','delivery',1,100,1,1,'${hash}','${hash}',clock_timestamp()-interval '2 seconds',clock_timestamp()-interval '1 second',clock_timestamp()+interval '30 minutes','synthetic-fixture','${hash}');
CREATE ROLE replay_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT USAGE ON SCHEMA source TO replay_runtime;
GRANT SELECT ON source.private_source_cutover,source.private_delivery_receipt,source.company_event_outbox TO replay_runtime;
GRANT UPDATE(updated_at) ON source.private_source_cutover TO replay_runtime;
GRANT UPDATE(status,lease_until,claim_owner,outcome_code,updated_at) ON source.private_delivery_receipt TO replay_runtime;
GRANT INSERT(id,source_tenant_id,organization_id,event_type,aggregate_type,aggregate_id,aggregate_version,event_envelope,event_stream,created_at) ON source.company_event_outbox TO replay_runtime;
GRANT USAGE ON SEQUENCE source.company_event_outbox_source_position_seq TO replay_runtime;`);
}

test('restricted replay uses receipt fencing for both cleanup orderings without outbox UPDATE',{timeout:120000},async()=>{
  const pg=await fixture();let owner,replay,cleanup;
  try {
    await prepare(pg);owner=await connect(pg);replay=await connect(pg,'replay_runtime');cleanup=await connect(pg);
    const replayPid=(await replay.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    const cleanupPid=(await cleanup.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    assert.equal((await replay.query("SELECT has_any_column_privilege(current_user,'source.company_event_outbox','UPDATE') AS allowed")).rows[0].allowed,false);

    // Replay first: real receipt UPDATE lock must hold canonical cleanup's SHARE lock.
    await seed(owner);await replay.query('BEGIN');
    await replay.query(receiptSql,[tenant,intent,destination]);
    await cleanup.query('BEGIN');
    const pending=cleanup.query('SELECT source.private_cleanup_outbox($1,\'delivery\',$2,100)',[tenant,evidence]).then(value=>({value}),error=>({error}));
    await blocked(owner,cleanupPid);
    const frames=await replay.query(framesSql,[tenant,intent]);
    assert.deepEqual(frames.rows.map(row=>row.event_envelope),[frame]);
    await replay.query(replaySql,[tenant,intent,destination,0]);await replay.query('COMMIT');
    const cleaned=await pending;
    assert.ifError(cleaned.error);
    assert.equal(cleaned.value.rows[0].private_cleanup_outbox,0,'cleanup must recheck the pending receipt after its row-lock wait');
    await cleanup.query('COMMIT');
    assert.equal((await owner.query('SELECT count(*) AS n FROM source.company_event_outbox')).rows[0].n,'1');

    // Cleanup first: replay must wait for receipts, then restore the exact missing frames.
    await seed(owner);await cleanup.query('BEGIN');
    assert.equal((await cleanup.query('SELECT source.private_cleanup_outbox($1,\'delivery\',$2,100) AS n',[tenant,evidence])).rows[0].n,1);
    await replay.query('BEGIN');const waiting=replay.query(receiptSql,[tenant,intent,destination]);
    await blocked(owner,replayPid);await cleanup.query('COMMIT');await waiting;
    const missing=await replay.query(framesSql,[tenant,intent]);assert.equal(missing.rowCount,0);
    await replay.query(insertSql,[JSON.stringify([frame])]);
    await replay.query(replaySql,[tenant,intent,destination,0]);await replay.query('COMMIT');
    assert.deepEqual((await owner.query('SELECT event_envelope FROM source.company_event_outbox')).rows[0].event_envelope,frame);
    assert.equal((await owner.query('SELECT status FROM source.private_delivery_receipt')).rows[0].status,'PENDING');
    // Canonical immutability and source generation gates remain enforced.
    await assert.rejects(owner.query("UPDATE source.company_event_outbox SET event_envelope='{}'"),/Private envelopes are immutable/);
    await assert.rejects(replay.query(insertSql,[JSON.stringify([{...frame,event_id:marker,source_generation:2}])]),/generation mismatch/);
  } finally {
    for(const client of [replay,cleanup,owner])if(client){await client.query('ROLLBACK').catch(()=>{});await client.end();}
    pg.stop();console.log('Owned replay concurrency fixture retained: '+pg.directory);
  }
});
