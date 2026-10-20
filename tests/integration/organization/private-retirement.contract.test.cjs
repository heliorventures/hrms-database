const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const root=path.resolve(__dirname,'../../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
test('normal masters install non destructive preparation only',()=>{
 assert.match(read('changelog/tenant.changelog-master.xml'),/0125_private_event_source/);
 assert.match(read('changelog/db.changelog-master.xml'),/0124_private_event_control/);
 assert.doesNotMatch(read('changelog/tenant.changelog-master.xml'),/0126/);
 assert.doesNotMatch(read('changelog/db.changelog-master.xml'),/0127/);
});
test('private cleanup needs independent evidence and company routing remains checked',()=>{
 const sql=read('changelog/migrations/0125_private_event_source/private_event_source.xml');
 assert.match(sql,/event_stream IN \('company','audit','delivery'\)/);
 assert.match(sql,/private_capture_evidence/);assert.match(sql,/private cleanup evidence required/);
 assert.match(sql,/ORDER BY a.created_at DESC,a.id DESC/);
 assert.match(sql,/REFERENCES "\$\{schema\}"\.private_domain_receipt/);
});
test('retirement is opt in and rejects CASCADE, stale evidence and lossy legacy completeness',()=>{
 for(const [id,name] of [['0126','tenant_legacy_retirement'],['0127','ops_legacy_retirement']]) {
  const sql=read(`changelog/migrations/${id}_${name}/${name}.xml`);
  assert.doesNotMatch(sql,/\bCASCADE\b/);assert.match(sql,/private_assert_retirement/);
 }
 const sql=read('changelog/migrations/0125_private_event_source/private_event_source.xml');
 for(const gate of ['restore_verified_at','producer_generation','source_sha256','pending_ownership_complete','reader_switch_complete','dependency_inventory_sha256','expires_at','revoked_at','business_state_complete']) assert.ok(sql.includes(gate),gate);
 assert.match(sql,/ACCESS EXCLUSIVE/);
});
test('idle capture publishes encrypted pulses and compacts only behind private proof',()=>{
 for(const file of ['0125_private_event_source/private_event_source','0124_private_event_control/private_event_control']){
  const sql=read('changelog/migrations/'+file+'.xml');assert.equal([...sql.matchAll(/<\/databaseChangeLog>/g)].length,1);
  for(const name of ['private_capture_pulse_spec','private_capture_pulse_publish','private_capture_prune','private_capture_compaction'])assert.ok(sql.includes(name));
  assert.match(sql,/'through_position',m.through_position::text/);assert.match(sql,/batch_size NOT BETWEEN 1 AND 200/);
  assert.match(sql,/p.event_id=o.id AND p.published_position=o.source_position AND p.purpose=o.event_stream/);
  assert.match(sql,/old.expires_at<clock_timestamp\(\) AND old.revoked_at IS NULL/);
 }
});
