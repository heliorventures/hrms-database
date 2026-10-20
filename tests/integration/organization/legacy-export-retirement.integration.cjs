// Owns one new loopback-only disposable container. Never reads .env or accepts a source DSN.
const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const {randomUUID}=require('node:crypto');const {spawnSync}=require('node:child_process');const {Client}=require('pg');
const root=path.resolve(__dirname,'../../..'),container='private-legacy-export-'+randomUUID().replaceAll('-','');
const schema='source_one',ids=Object.fromEntries(['tenant','org','member','audit','legacy','pending','canonical','business','private'].map(k=>[k,randomUUID()]));
let created=false,db,checks=0;
function docker(args){const r=spawnSync('docker',args,{encoding:'utf8',windowsHide:true,timeout:60000});if(r.error||r.status!==0)throw Error(r.error?.message??r.stderr);return r.stdout.trim();}
function migration(file){return [...fs.readFileSync(path.join(root,'changelog/migrations',file),'utf8').matchAll(/<!\[CDATA\[([\s\S]*?)\]\]>/g)].map(m=>m[1].replaceAll('${schema}',schema)).join('\n');}
function fn(sql,name){const expression=new RegExp('CREATE(?: OR REPLACE)? FUNCTION "'+schema+'"\\.'+name+'\\([\\s\\S]*?END \\$fn\\$;');const found=sql.match(expression);assert.ok(found,`canonical function missing: ${name}`);return found[0];}
async function check(name,run){await run();checks++;console.log('PASS '+name);}
async function main(){
 if(!process.argv.includes('--docker-fixture'))throw Error('EXPLICIT_OWNED_DOCKER_FIXTURE_REQUIRED');
 docker(['run','--pull=never','--rm','-d','--name',container,'--memory','256m','-p','127.0.0.1::5432','-e','POSTGRES_USER=private_fixture','-e','POSTGRES_PASSWORD=private_fixture','postgres:16-alpine']);created=true;
 const endpoint=docker(['port',container,'5432/tcp']).match(/^127\.0\.0\.1:(\d+)$/);assert.ok(endpoint);
 for(let i=0;i<60;i++){try{docker(['exec',container,'pg_isready','-h','127.0.0.1','-U','private_fixture']);break;}catch{if(i===59)throw Error('FIXTURE_NOT_READY');await new Promise(r=>setTimeout(r,250));}}
 db=new Client({host:'127.0.0.1',port:Number(endpoint[1]),user:'private_fixture',password:'private_fixture',database:'postgres',connectionTimeoutMillis:5000});await db.connect();
 const old=migration('0121_organization_source_history/organization_source_history.xml');
 await db.query(`CREATE SCHEMA ${schema};SET search_path TO ${schema};
 CREATE TABLE organization_membership_installation(tenant_id uuid,organization_id uuid,membership_id uuid,version bigint,status text);
 CREATE TABLE company_event_outbox(id uuid PRIMARY KEY,source_tenant_id uuid,organization_id uuid,event_envelope jsonb,created_at timestamptz DEFAULT now(),source_position bigserial,event_stream text NOT NULL DEFAULT 'company');
 CREATE TABLE audit_log(id uuid PRIMARY KEY,tenant_id uuid,user_id uuid,entity_type text,entity_id uuid,action text,before_state jsonb,after_state jsonb,created_at timestamptz DEFAULT now(),organization_history_position bigserial);
 CREATE TABLE private_source_cutover(tenant_id uuid PRIMARY KEY,state text,writers_fenced boolean);
 CREATE FUNCTION organization_fact_uuid(text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$SELECT md5($1)::uuid$$;`);
 const tables=old.slice(old.indexOf('CREATE TABLE "'+schema+'".organization_history_export ('),old.indexOf('CREATE FUNCTION "'+schema+'".organization_history_export_start('));await db.query(tables);
 for(const name of ['organization_history_export_start','organization_legacy_audit_event','organization_legacy_export_start','organization_history_export_next'])await db.query(fn(old,name));
 await db.query('INSERT INTO organization_membership_installation VALUES($1,$2,$3,1,\'ACTIVE\')',[ids.tenant,ids.org,ids.member]);
 await db.query("INSERT INTO audit_log(id,tenant_id,entity_type,entity_id,action,before_state,after_state) VALUES($1,$2,'LEAVE_REQUEST',$1,'APPROVED','{\"status\":\"PENDING\"}','{\"status\":\"APPROVED\"}')",[ids.audit,ids.tenant]);
 await db.query('SELECT organization_legacy_export_start($1,$2,$3)',[ids.tenant,ids.org,ids.legacy]);
 await db.query('SELECT organization_history_export_next($1,$2,200)',[ids.tenant,ids.legacy]);
 await db.query('SELECT organization_legacy_export_start($1,$2,$3)',[ids.tenant,ids.org,ids.pending]);
 const retained=(await db.query('SELECT manifest::text raw,manifest_sha256 FROM organization_history_export_chunk WHERE export_id=$1',[ids.legacy])).rows[0];
 const forward=migration('0125_private_event_source/private_event_source.xml');
 for(const name of ['organization_legacy_audit_event','organization_legacy_export_start','organization_history_export_next'])if(forward.includes('CREATE OR REPLACE FUNCTION "'+schema+'".'+name+'('))await db.query(fn(forward,name));
 await check('forward preparation rejects a new lossy legacy export before destructive retirement',async()=>{await assert.rejects(db.query('SELECT organization_legacy_export_start($1,$2,$3)',[ids.tenant,ids.org,randomUUID()]),/Legacy audit projection export retired/);});
 await check('forward preparation rejects an existing pending legacy job',async()=>{await assert.rejects(db.query('SELECT organization_history_export_next($1,$2,200)',[ids.tenant,ids.pending]),/Legacy audit projection export retired/);});
 await check('forward preparation rejects an existing complete legacy job',async()=>{await assert.rejects(db.query('SELECT organization_history_export_next($1,$2,200)',[ids.tenant,ids.legacy]),/Legacy audit projection export retired/);});
 await check('legacy projection generator cannot create a new company event',async()=>{await assert.rejects(db.query('SELECT organization_legacy_audit_event(to_jsonb(a),$1) FROM audit_log a',[ids.org]),/Legacy audit projection export retired/);});
 await check('existing archived chunks retain their exact bytes and digest',async()=>{assert.deepEqual((await db.query('SELECT manifest::text raw,manifest_sha256 FROM organization_history_export_chunk WHERE export_id=$1',[ids.legacy])).rows[0],retained);assert.match(retained.raw,/legacy_audit.recorded/);});
 await db.query("INSERT INTO company_event_outbox(id,source_tenant_id,organization_id,event_envelope,event_stream) VALUES($1,$2,$3,'{\"business\":true}','company'),($4,$2,NULL,'{\"private\":true}','audit')",[ids.business,ids.tenant,ids.org,ids.private]);
 await check('canonical OUTBOX export retains only company stream records',async()=>{await db.query('SELECT organization_history_export_start($1,$2,$3)',[ids.tenant,ids.org,ids.canonical]);const page=(await db.query('SELECT organization_history_export_next($1,$2,200) page',[ids.tenant,ids.canonical])).rows[0].page;assert.equal(page.source_kind,'OUTBOX');assert.deepEqual(page.rows.map(r=>r.id),[ids.business]);assert.equal(page.rows[0].raw,'{"business": true}');});
 await check('canonical completed job remains idempotent',async()=>{assert.equal((await db.query('SELECT organization_history_export_next($1,$2,200) page',[ids.tenant,ids.canonical])).rows[0].page,null);});
 await db.query("INSERT INTO private_source_cutover VALUES($1,'FENCED',true)",[ids.tenant]);
 await check('legacy export stays rejected while source writers are fenced',async()=>{await assert.rejects(db.query('SELECT organization_legacy_export_start($1,$2,$3)',[ids.tenant,ids.org,randomUUID()]),/Legacy audit projection export retired/);});
 console.log(`PASS ${checks} actual PostgreSQL legacy export retirement checks`);
}
main().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(async()=>{if(db)await db.end().catch(()=>{});if(created){const exact=docker(['inspect','--format','{{.Name}}',container]);assert.equal(exact,'/'+container);docker(['rm','--force',container]);}});
