const test=require('node:test');const assert=require('node:assert/strict');
test('central deployment requires explicit matching metadata database and hides credentials',()=>{
 const fs=require('node:fs');const file=require.resolve('../../../migrate-ops.cjs');
 assert.match(fs.readFileSync(file,'utf8'),/require\.main\s*===\s*module/,'Operator entry point must be import-safe');
 const {invocation}=require(file);
 const config={database:'helior',host:'127.0.0.1',port:5433,user:'operator',password:'secret & literal',sslmode:'disable'};
 assert.throws(()=>invocation(config,'company_alpha','update'));
 assert.throws(()=>invocation(config,'helior','drop-all'));
 const result=invocation(config,'helior','update');
 assert(!JSON.stringify(result.args).includes(config.password));
 assert.equal(result.env.LIQUIBASE_COMMAND_PASSWORD,config.password);
 assert(result.env.LIQUIBASE_COMMAND_URL.includes('/helior?'));
});
