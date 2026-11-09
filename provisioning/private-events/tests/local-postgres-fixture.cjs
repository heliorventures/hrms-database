// Owned loopback cluster only; never reads .env, services, passfiles or live DSNs.
const fs=require('node:fs');
const path=require('node:path');
const net=require('node:net');
const {spawnSync}=require('node:child_process');
const assert=require('node:assert/strict');
async function fixture() {
  const bin=process.env.PRIVATE_TEST_PG_BIN;
  assert(bin && path.isAbsolute(bin),'PRIVATE_TEST_PG_BIN must name the native PostgreSQL bin directory');
  // Keep the running data directory in the workspace: OS temporary-directory
  // cleanup can remove cluster identity files while a native test is running.
  const fixtureRoot=path.resolve(__dirname,'../../../../.codex-tmp');
  fs.mkdirSync(fixtureRoot,{recursive:true});
  const directory=fs.mkdtempSync(path.join(fixtureRoot,'hrms-shared-grants-'));
  const data=path.join(directory,'data');
  const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^PG/i.test(key)));
  function run(name,args,input) {
    const executable=path.join(bin,name+(process.platform==='win32'?'.exe':''));
    const result=spawnSync(executable,args,{input,env,encoding:'utf8',windowsHide:true,timeout:60000,
      ...(name==='pg_ctl'?{stdio:'ignore'}:{})});
    assert(!result.error, String(result.error));return result;
  }
  const listener=net.createServer();await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));
  const port=listener.address().port;await new Promise(resolve=>listener.close(resolve));
  function stop() {
    if(fs.existsSync(path.join(data,'postmaster.pid'))) assert.equal(run('pg_ctl',['-D',data,'-m','fast','-w','stop']).status,0);
  }
  try {
    const init=run('initdb',['-D',data,'-U','fixture_owner','--auth=trust','--encoding=UTF8','--no-locale','--no-sync']);
    assert.equal(init.status,0,init.stderr);
    assert.equal(run('pg_ctl',['-D',data,'-l',path.join(directory,'postgres.log'),'-o',`-h 127.0.0.1 -p ${port}`,'-w','start']).status,0);
  } catch(error) {stop();throw error;}
  function psql(database,{sql,file,variables=[],role='fixture_owner'}={}) {
    const args=['-X','-qAt','-w','-h','127.0.0.1','-p',String(port),'-U',role,'-d',database,'-v','ON_ERROR_STOP=1'];
    for(const value of variables) args.push('-v',value);
    if(file) args.push('--single-transaction','-f',file);
    return run('psql',args,sql);
  }
  function query(database,sql) {const result=psql(database,{sql});assert.equal(result.status,0,result.stderr);return result.stdout;}
  function archive(name,database,args) {
    assert(['pg_dump','pg_restore'].includes(name));
    const result=run(name,['--host=127.0.0.1','--port='+port,'--username=fixture_owner','--dbname='+database,...args]);
    assert.equal(result.status,0,result.stderr);return result;
  }
  const connection=(database,role='fixture_owner')=>({host:'127.0.0.1',port,user:role,
    password:'synthetic-unused-trust',database,ssl:false,connectionTimeoutMillis:5000});
  return {query,psql,archive,connection,stop,directory};
}
module.exports={fixture};
