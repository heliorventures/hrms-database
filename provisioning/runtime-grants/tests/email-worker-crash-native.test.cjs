// Real process termination + owned database restart. SMTP is synthetic only.
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const {spawnSync,spawn}=require('node:child_process');
const {prepare}=require('./email-delivery-fixture.cjs');const {services}=require('./email-native-support.cjs');
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
for(const mode of ['predata','submitting'])test(`worker process crash in ${mode} preserves safe recovery through database down/up`,async t=>{
 const {pg,env,system}=await prepare();t.after(()=>pg.stop());env.KABIPAY_EMAIL_CRASH_MODE=mode;
 const build=spawnSync('cargo',['test','--offline','--locked','-p','kabipay-notification','--test','email_delivery_owned','--no-run','--message-format=json'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:900000});assert.equal(build.status,0,build.stderr);
 const outputs=build.stdout.trim().split(/\r?\n/).map(line=>{try{return JSON.parse(line);}catch{return null;}});
 const executable=outputs.find(item=>item?.reason==='compiler-artifact'&&item.target?.name==='email_delivery_owned'&&item.executable)?.executable;
 assert(executable&&fs.realpathSync(executable).startsWith(fs.realpathSync(process.env.CARGO_TARGET_DIR)+path.sep),'test executable must stay in the configured generated target');
 const child=spawn(executable,['--ignored','--exact','owned_email_crash_child','--nocapture','--test-threads=1'],{cwd:services,env,windowsHide:true,stdio:['ignore','pipe','pipe']});let diagnostic='';child.stdout.on('data',chunk=>{diagnostic=(diagnostic+chunk.toString()).slice(-8192);});child.stderr.on('data',chunk=>{diagnostic=(diagnostic+chunk.toString()).slice(-8192);});t.after(()=>{if(child.exitCode===null)child.kill();});
 let lease;for(let poll=0;poll<80;poll++){
  const result=pg.psql('company_email_delivery_fixture',{sql:"SELECT state||'|'||extract(epoch FROM lease_until)::text FROM tenant_fixture.important_email_intent LIMIT 1"});
  if(result.status===0){const [state,until]=result.stdout.trim().split('|');if(state===(mode==='submitting'?'SUBMITTING':'CLAIMED')){lease=Number(until)*1000;break;}}
  assert.equal(child.exitCode,null,diagnostic);await wait(250);
 }
 assert(lease,'child never reached the durable phase: '+diagnostic);
 pg.restart();assert.equal(pg.query('postgres','SELECT system_identifier FROM pg_control_system()').trim(),system,'same owned cluster identity after down/up');
 const exited=new Promise(resolve=>child.once('exit',resolve));assert(child.kill(),'only the spawned owned test child is terminated');await exited;
 const delay=Math.max(0,lease-Date.now()+1500);assert(delay<=95000);await wait(delay);
 const readback=spawnSync(executable,['--ignored','--exact','owned_email_crash_readback','--test-threads=1'],{cwd:services,env,encoding:'utf8',windowsHide:true,timeout:60000});assert.equal(readback.status,0,(readback.stderr||'')+(readback.stdout||''));assert.match(readback.stdout,/test result: ok\. 1 passed/);
});
