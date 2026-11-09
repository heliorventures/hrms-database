const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {connection, childEnvironment, collect} = require('../run-local.cjs');
const fixture = {POSTGRES_HOST:'localhost', POSTGRES_PORT:'5434', POSTGRES_DB:'helior',
  POSTGRES_USER:'synthetic_operator', POSTGRES_PASSWORD:'synthetic-password'};

test('only explicit loopback tunnel and expected database accepted', () => {
  assert.equal(connection(fixture,'helior').port,'5434');
  for (const [key,value] of [['POSTGRES_HOST','public.example'],['POSTGRES_PORT','5434 host=remote'],
    ['POSTGRES_PORT','0'],['POSTGRES_PORT','65536'],['POSTGRES_DB','other'],['POSTGRES_USER',''],['POSTGRES_PASSWORD',''],
    ['POSTGRES_SSLMODE','invalid']]) {
    assert.throws(()=>connection({...fixture,[key]:value},'helior'));
  }
  assert.throws(()=>connection(fixture,''));
});

test('credentials are confined to child environment and ambient libpq routing is removed', () => {
  const ambient={PATH:'fixture-path',PGSERVICE:'wrong',PGHOSTADDR:'remote',PGOPTIONS:'-c default_transaction_read_only=off'};
  const env=childEnvironment(connection(fixture,'helior'),ambient);
  assert.equal(env.PGPASSWORD,fixture.POSTGRES_PASSWORD);
  assert.equal(env.PGHOST,'localhost'); assert.equal(env.PGPORT,'5434');
  assert.equal(env.PGSERVICE,undefined); assert.equal(env.PGHOSTADDR,undefined);
  assert.equal(env.PGOPTIONS,'-c default_transaction_read_only=on');
  assert.equal(ambient.PGSERVICE,'wrong');
});

test('writes only a complete validated report; never overwrites or prints raw server errors', () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'hrms-local-preflight-'));
  const output=path.join(dir,'report.jsonl');
  const config=connection(fixture,'helior');
  const stdout=JSON.stringify({section:'inventory',database:'helior',transaction_read_only:'on',tenants:[]})+'\n'+
    JSON.stringify({section:'complete',database:'helior',format_version:1,readiness:'not_assessed'})+'\n';
  let calls=0;
  const spawn=(exe,args,options)=>{
    calls++; assert.equal(exe,'fixture-psql');
    assert(!args.join(' ').includes(fixture.POSTGRES_PASSWORD));
    assert.equal(options.shell,false);
    assert.equal(options.env.PGPASSWORD,fixture.POSTGRES_PASSWORD);
    return {status:0,stdout,stderr:''};
  };
  collect({config,output,psql:'fixture-psql'},spawn);
  assert.equal(fs.readFileSync(output,'utf8'),stdout);
  assert.throws(()=>collect({config,output,psql:'fixture-psql'},spawn),/OUTPUT_EXISTS_OR_UNWRITABLE/);
  assert.equal(calls,1);
  for (const [index,result] of [
    {status:1,stdout:'',stderr:fixture.POSTGRES_PASSWORD},
    {status:0,stdout:'{}\n',stderr:''},
    {status:0,stdout:stdout.replaceAll('helior','wrong'),stderr:''},
    {status:0,stdout:stdout.replace('"on"','"off"'),stderr:''},
  ].entries()) {
    const failed=path.join(dir,`failed-${index}.jsonl`);
    assert.throws(()=>collect({config,output:failed,psql:'fixture-psql'},()=>result),error=>
      !error.message.includes(fixture.POSTGRES_PASSWORD));
    assert.equal(fs.statSync(failed).size,0);
  }
});
