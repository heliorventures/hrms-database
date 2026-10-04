// Full migration and native CLI acceptance on a new loopback PostgreSQL cluster.
// Never loads repository .env or uses a client roster.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const { seedClaimedDocument, assertClaimedDocumentPlan, seedAttendanceHistory, assertAttendanceReset, attendanceTables } = require('./reset-regressions.cjs');
const root = path.resolve(__dirname, '../../..');
const service = path.resolve(root, '../hrms-svc');
const binary = path.join(service, 'target/debug/kabipay-tenant-import.exe');
const directory = fs.mkdtempSync(path.join(process.env.HRMS_TEST_OUTPUT_ROOT || os.tmpdir(), 'hrms-native-import-'));
const data = path.join(directory, 'pgdata');
const bin = process.env.PG_TEST_BIN || 'C:/Program Files/PostgreSQL/17/bin';
const schema = 'tenant_import_fixture';
const tenant = '10000000-0000-0000-0000-000000000001';
const actor = '10000000-0000-0000-0000-000000000002';
const adminEmployee = '10000000-0000-0000-0000-000000000003';
function run(executable, args, log, options = {}) {
  const fd = fs.openSync(path.join(directory, log), 'a');
  try {
    const result = spawnSync(executable, args, { windowsHide: true, stdio: ['ignore', fd, fd], timeout: 180000, ...options });
    if (result.error) throw result.error;
    return result.status;
  } finally { fs.closeSync(fd); }
}
function pg(name, args) { assert.equal(run(path.join(bin, `${name}.exe`), args, `${name}.log`), 0, `${name} failed; logs: ${directory}`); }
async function freePort() {
  const server = net.createServer(); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port;
}
async function main() {
  assert.ok(fs.existsSync(binary), 'Build the native importer before running this fixture');
  const port = await freePort(); let started = false; let invocation = 0;
  const db = new Client({ host: '127.0.0.1', port, database: 'postgres', user: 'postgres', connectionTimeoutMillis: 5000 });
  const env = { ...process.env, DATABASE_URL: `postgres://postgres@127.0.0.1:${port}/postgres`, POSTGRES_HOST: '127.0.0.1', POSTGRES_PORT: String(port), POSTGRES_DB: 'postgres', POSTGRES_USER: 'postgres', POSTGRES_PASSWORD: '', POSTGRES_SSLMODE: 'disable' };
  const javaDirectory = path.join(root, 'vendor/jre');
  const java = fs.existsSync(javaDirectory) && fs.readdirSync(javaDirectory).map(name => path.join(javaDirectory, name)).find(candidate => fs.existsSync(path.join(candidate, 'bin/java.exe')));
  const q = sql => db.query(sql);
  try {
    pg('initdb', ['-D', data, '-U', 'postgres', '-A', 'trust', '-N', '--no-locale', '-E', 'UTF8']);
    pg('pg_ctl', ['-D', data, '-l', path.join(directory, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port}`, '-w', 'start']); started = true;
    await db.connect();
    fs.cpSync(path.join(root, 'changelog'), path.join(directory, 'changelog'), { recursive: true });
    const migrate = tenantSchema => {
      const props = path.join(directory, `connection-${++invocation}.properties`);
      fs.writeFileSync(props, [`changeLogFile=changelog/${tenantSchema ? 'tenant' : 'db'}.changelog-master.xml`, `url=jdbc:postgresql://127.0.0.1:${port}/postgres`, 'username=postgres', 'password=', 'driver=org.postgresql.Driver', 'liquibase.hub.mode=off', ...(tenantSchema ? [`defaultSchemaName=${tenantSchema}`, `databaseChangeLogTableName=${tenantSchema}_databasechangelog`, `parameter.schema=${tenantSchema}`] : [])].join('\n'));
      const log = `liquibase-${invocation}.log`;
      assert.equal(run(process.execPath, [path.join(root, 'run-liquibase.cjs'), `--defaults-file=${props}`, 'update'], log, { cwd: directory, env: { ...env, ...(java ? { JAVA_HOME: java } : {}) } }), 0, `Full migration failed; logs: ${directory}/${log}`);
    };
    migrate(null);
    await q(`INSERT INTO kabipay_ops.module(id,code,name) SELECT gen_random_uuid(),code,code FROM unnest(ARRAY['EMPLOYEE','ATTENDANCE','LEAVE','EXPENSE','PAYROLL','TAX','WORKFLOW','RECRUITMENT']) code`);
    await db.query(`INSERT INTO kabipay_ops.tenant(id,name,status,country,currency,timezone,subdomain) VALUES($1,'Fictional import fixture','ACTIVE','IN','INR','Asia/Kolkata','fictional')`, [tenant]);
    await db.query(`INSERT INTO kabipay_ops.tenant_database(id,tenant_id,db_type,db_host,db_name,schema_name,is_active) VALUES(gen_random_uuid(),$1,'POSTGRES','127.0.0.1','postgres',$2,true)`, [tenant, schema]);
    await db.query('INSERT INTO kabipay_ops.tenant_subscription(id,tenant_id,module_id,status) SELECT gen_random_uuid(),$1,id,\'ACTIVE\' FROM kabipay_ops.module', [tenant]);
    await q(`CREATE SCHEMA ${schema}`); migrate(schema); migrate(schema);
    console.log('PASS full ops and tenant migrations, including repeat execution');
    await q(`SET search_path TO ${schema},public`);
    await db.query(`INSERT INTO "user"(id,tenant_id,username,password_hash) VALUES($1,$2,'fixture.admin','unchanged-admin-hash')`, [actor, tenant]);
    await db.query(`INSERT INTO employee(id,tenant_id,user_id,employee_code,first_name,last_name,date_of_joining,status) VALUES($1,$2,$3,'ADMIN','Fixture','Admin','2020-01-01','ACTIVE')`, [adminEmployee, tenant, actor]);
    const role = (await db.query(`INSERT INTO role(id,tenant_id,name,is_system_role) VALUES(gen_random_uuid(),$1,'FIXTURE_ADMIN',false) RETURNING id`, [tenant])).rows[0].id;
    await db.query('INSERT INTO user_role(user_id,role_id) VALUES($1,$2)', [actor, role]);
    await db.query('INSERT INTO role_permission(role_id,permission_id) SELECT $1,id FROM permission', [role]);
    await db.query(`INSERT INTO permission_scope(id,tenant_id,role_id,resource,action,scope_type) SELECT gen_random_uuid(),$1,$2,resource,action,'ALL' FROM permission`, [tenant, role]);
    await db.query(`INSERT INTO role(id,tenant_id,name) SELECT gen_random_uuid(),$1,'EMPLOYEE' WHERE NOT EXISTS(SELECT 1 FROM role WHERE tenant_id=$1 AND name='EMPLOYEE')`, [tenant]);
    const packagePath = path.join(directory, 'fictional.json');
    const optionsPath = path.join(directory, 'options.json');
    const document = JSON.parse(fs.readFileSync(path.join(root, 'import-templates/v1/example.synthetic.json'), 'utf8'));
    document.tenant_code = 'fictional'; document.employees[0].employee.code = 'EXAMPLE-001'; document.employees[0].employee.confirmation_date = '2025-01-01';
    // This fixture exercises missing tax history estimated from a known salary.
    // Historical salary unavailable but covered by opening history is a separate domain regression.
    document.salary_effective_from = document.employees[0].employee.joining_date;
    document.employees[0].bank = { account_number: '1234567890', ifsc: 'ABCD0123456', bank_name: 'Fictional Bank', account_holder: 'Fictional Employee', branch: 'Fictional', account_type: 'SAVINGS', verified: false };
    document.employees[0].identity = { pan: 'ABCDE1234F', aadhaar_last_four: '1234', verified: false };
    fs.writeFileSync(packagePath, JSON.stringify(document));
    let options = { tenant_id: tenant, tenant_code: 'fictional', schema_name: schema, db_host: '127.0.0.1', db_name: 'postgres', actor_id: actor, preserved_usernames: ['fixture.admin'], reviewed_absent_usernames: [], login_by_employee_code: { 'EXAMPLE-001': 'fixture.employee' }, payroll_excluded_employee_ids: [adminEmployee], runtime_contract_version: 1, reset_delete_tables: [], reset_retain_tables: [] };
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    const native = (command, label, flags = [], expected = 0) => {
      const output = path.join(directory, label);
      const args = [command, '--package', packagePath, '--options', optionsPath, '--output', output, ...flags];
      const status = run(binary, args, `${label}.log`, { env, cwd: service });
      assert.equal(status, expected, `Native ${label} status ${status}; logs: ${directory}/${label}.log`);
      return output;
    };
    native('validate', 'validate');
    let planPath = path.join(native('preview', 'preview-import'), 'plan.json');
    let plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
    assert.ok(plan.actions.some(item => item.section === 'employee' && item.action === 'CREATE'));
    assert.ok(plan.actions.some(item => item.section === 'recurring_salary' && item.action === 'RECONCILE'));
    const output = native('apply', 'apply-import', ['--plan', planPath, '--confirm', plan.digest]);
    const report = JSON.parse(fs.readFileSync(path.join(output, 'report.json'), 'utf8'));
    assert.ok(report.committed); assert.equal(report.sections.filter(item => item.outcome === 'FAILED').length, 0);
    for (const section of ['employee', 'profile', 'department', 'designation', 'identity', 'bank', 'recurring_salary', 'leave_opening', 'period_input']) {
      assert.ok(report.sections.some(item => item.section === section && ['CREATED', 'UPDATED', 'UNCHANGED'].includes(item.outcome)), `${section} deferred; private report ${output}`);
    }
    const employee = (await q(`SELECT id,confirmation_date::text FROM employee WHERE employee_code='EXAMPLE-001'`)).rows[0];
    assert.equal(employee.confirmation_date, '2025-01-01');
    assert.equal((await q('SELECT historical_lwp FROM leave_import_history')).rows[0].historical_lwp, '2.00');
    assert.equal(Number((await q("SELECT balance_days FROM leave_balance")).rows[0].balance_days), 0);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM leave_request')).rows[0].n, 0);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM payroll_period_input WHERE ready')).rows[0].n, 1);
    assert.equal((await q("SELECT COUNT(*)::int AS n FROM salary_component WHERE code='ADVANCE'")).rows[0].n, 0);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM payslip')).rows[0].n, 0);
    console.log('PASS native template import: employee, identifiers, banking, salary, leave history, period; no automatic slips');
    const fingerprint = async () => (await q(`SELECT md5(string_agg(to_jsonb(e)::text,'' ORDER BY id)) AS state FROM employee e`)).rows[0].state;
    const before = await fingerprint();
    native('apply', 'replay-import', ['--plan', planPath, '--confirm', plan.digest]);
    assert.equal(await fingerprint(), before);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM tenant_import_run')).rows[0].n, 1);
    console.log('PASS committed replay leaves employee data and audit cardinality unchanged');
    const businessState = async () => {
      const tables = ['employee','employee_bank','employee_pan','employee_aadhaar','employee_salary_structure','employee_payroll_rule','leave_balance','leave_import_history','payroll_period_input','salary_structure_component'];
      return Promise.all(tables.map(async name => (await q(`SELECT md5(COALESCE(string_agg(to_jsonb(t)::text,'' ORDER BY to_jsonb(t)::text),'')) AS state FROM "${name}" t`)).rows[0].state));
    };
    const businessBefore = await businessState();
    options.review_reference = 'Reviewed retry with unchanged source'; fs.writeFileSync(optionsPath, JSON.stringify(options));
    planPath = path.join(native('preview','preview-reviewed-retry'),'plan.json'); plan = JSON.parse(fs.readFileSync(planPath,'utf8'));
    const retry = native('apply','apply-reviewed-retry',['--plan',planPath,'--confirm',plan.digest]);
    assert.deepEqual(await businessState(),businessBefore);
    const retryReport = JSON.parse(fs.readFileSync(path.join(retry,'report.json'),'utf8'));
    for (const section of ['employee','login','profile','department','designation','identity','bank','recurring_salary','leave_opening','period_input']) assert.ok(retryReport.sections.some(item=>item.section===section && item.outcome==='UNCHANGED'),`${section} must be unchanged on a reviewed retry`);
    console.log('PASS corrected/reviewed retry preserves domain rows and reports unchanged sections');
    options.review_reference = 'Partial source and stale target review'; fs.writeFileSync(optionsPath, JSON.stringify(options));
    document.employees[0].bank.ifsc='INVALID'; fs.writeFileSync(packagePath,JSON.stringify(document));
    planPath = path.join(native('preview','preview-partial'),'plan.json'); plan = JSON.parse(fs.readFileSync(planPath,'utf8'));
    const partial = native('apply','apply-partial',['--plan',planPath,'--confirm',plan.digest]);
    const partialReport = JSON.parse(fs.readFileSync(path.join(partial,'report.json'),'utf8'));
    assert.ok(partialReport.committed);assert.ok(partialReport.sections.some(item=>item.section==='bank'&&item.outcome==='DEFERRED'));
    assert.ok(partialReport.sections.some(item=>item.section==='recurring_salary'&&item.outcome==='UNCHANGED'));
    assert.equal((await q('SELECT ifsc_code FROM employee_bank')).rows[0].ifsc_code,'ABCD0123456');
    console.log('PASS invalid optional bank section is logged and does not block salary or clear valid bank data');
    document.employees[0].bank.ifsc='ABCD0123456'; fs.writeFileSync(packagePath,JSON.stringify(document));
    options.review_reference = 'Target state change must invalidate review'; fs.writeFileSync(optionsPath,JSON.stringify(options));
    planPath = path.join(native('preview', 'preview-stale'), 'plan.json'); plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
    await q("UPDATE employee SET first_name='Intervening' WHERE employee_code='EXAMPLE-001'");
    native('apply', 'reject-stale', ['--plan', planPath, '--confirm', plan.digest], 1);
    assert.match(fs.readFileSync(path.join(directory,'reject-stale.log'),'utf8'),/TARGET_CHANGED_REVIEW_A_NEW_PREVIEW/);
    const names = (await q(`SELECT tablename FROM pg_tables WHERE schemaname='${schema}' ORDER BY tablename`)).rows.map(row => row.tablename);
    const deletes = new Set(['user','user_role','user_session','employee','employee_bank','employee_pan','employee_aadhaar','employee_salary_structure','employee_payroll_rule','payroll_period_input','payroll_period_input_audit','payroll_period_adjustment','payslip','payslip_component','payslip_statement','payroll_cycle','leave_balance','leave_import_history','salary_structure_component','salary_structure','department','designation']);
    await seedClaimedDocument(db, tenant, actor);
    for (const name of ['file_upload_stage', 'company_document', 'file_storage']) deletes.add(name);
    options.reset_delete_tables = names.filter(name => deletes.has(name)); options.reset_retain_tables = names.filter(name => !deletes.has(name));
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    const adminBefore = (await q(`SELECT to_jsonb(u) AS state FROM "user" u WHERE id='${actor}'`)).rows[0].state;
    planPath = path.join(native('preview', 'preview-replace', ['--replace']), 'plan.json'); plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
    assertClaimedDocumentPlan(plan);
    await seedAttendanceHistory(db, tenant);
    options.reset_delete_tables.push(...attendanceTables);
    options.reset_retain_tables = options.reset_retain_tables.filter(name => !attendanceTables.includes(name));
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    const rejectedAttendance = native('preview', 'reject-immutable-delete', ['--replace'], 1);
    assert.equal(JSON.parse(fs.readFileSync(path.join(rejectedAttendance, 'failure.json'))).code, 'RESET_DELETE_TRIGGER_REQUIRES_REVIEW');
    options.reset_delete_tables = options.reset_delete_tables.filter(name => !attendanceTables.includes(name));
    options.reset_truncate_tables = attendanceTables.filter(name => name !== 'attendance_day_window');
    options.reset_retain_tables.push('attendance_day_window');
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    native('preview', 'reject-truncate-escape', ['--replace'], 1);
    assert.match(fs.readFileSync(path.join(directory, 'reject-truncate-escape.log'), 'utf8'), /RESET_TRUNCATE_REFERENCE_OUTSIDE_GROUP/);
    options.reset_retain_tables = options.reset_retain_tables.filter(name => name !== 'attendance_day_window');
    options.reset_truncate_tables = attendanceTables;
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    planPath = path.join(native('preview', 'preview-whole-attendance-reset', ['--replace']), 'plan.json');
    plan = JSON.parse(fs.readFileSync(planPath));
    assertClaimedDocumentPlan(plan);
    assert.deepEqual(plan.reset.truncate_tables, attendanceTables);
    assert.deepEqual(plan.reset.backup, { mode: 'REQUIRED' });
    const replacement = native('apply', 'apply-replace', ['--replace','--writes-paused','--pg-bin',bin,'--plan',planPath,'--confirm',plan.digest]);
    assert.deepEqual((await q(`SELECT to_jsonb(u) AS state FROM "user" u WHERE id='${actor}'`)).rows[0].state, adminBefore);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM employee')).rows[0].n, 2);
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM tenant_import_run')).rows[0].n, 4);
    await assertAttendanceReset(db);
    for (const table of ['file_upload_stage', 'company_document', 'file_storage']) assert.equal((await q(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n, 0);
    console.log('PASS reviewed replacement preserves admin credentials, role linkage and import history');
    options.replacement_backup = { mode: 'SKIP', reason: 'Approved fictional pre-live reset' };
    fs.writeFileSync(optionsPath, JSON.stringify(options));
    planPath = path.join(native('preview', 'preview-no-backup', ['--replace']), 'plan.json');
    plan = JSON.parse(fs.readFileSync(planPath));
    assert.deepEqual(plan.reset.backup, options.replacement_backup);
    const noBackup = native('apply', 'apply-no-backup', ['--replace','--writes-paused','--plan',planPath,'--confirm',plan.digest]);
    assert.ok(!fs.existsSync(path.join(noBackup, 'tenant-before-import.dump')));
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(noBackup, 'report.json'))).replacement_backup, options.replacement_backup);
    assert.deepEqual((await q(`SELECT to_jsonb(u) AS state FROM "user" u WHERE id='${actor}'`)).rows[0].state, adminBefore);
    console.log('PASS claimed-document reset, guarded attendance reset and audited no-backup import');
    const testDirectory = path.join(service,'target/debug/deps');
    const payrollTest = fs.readdirSync(testDirectory).filter(name => /^payroll_fixture-.*\.exe$/.test(name)).map(name=>path.join(testDirectory,name)).sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs)[0];
    assert.ok(payrollTest,'Compile the fixture payroll test before running this suite');
    assert.equal(run(payrollTest,['--ignored','--exact','imported_month_uses_the_normal_pay_run_and_immutable_statement'],'normal-payroll.log',{env:{...env,HRMS_IMPORT_TEST_DATABASE_URL:env.DATABASE_URL}}),0,`Normal payroll fixture failed; logs: ${directory}/normal-payroll.log`);
    const reportTest = fs.readdirSync(testDirectory).filter(name => /^payroll_report_fixture-.*\.exe$/.test(name)).map(name=>path.join(testDirectory,name)).sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs)[0];
    assert.ok(reportTest, 'Build the analytics payroll_report_fixture test before running acceptance');
    assert.equal(run(reportTest,['--ignored','--exact','finalized_statements_appear_once_in_unpaid_report'],'payroll-report.log',{env:{...env,HRMS_IMPORT_TEST_DATABASE_URL:env.DATABASE_URL}}),0,`Payroll report fixture failed; logs: ${directory}/payroll-report.log`);
    console.log('PASS normal pay run, immutable statement, advance settlement and company visibility');
    pg('createdb', ['-h','127.0.0.1','-p',String(port),'-U','postgres','fixture_restore']);
    // A tenant backup expects the existing ops foundation, including trigger functions.
    pg('pg_dump', ['-h','127.0.0.1','-p',String(port),'-U','postgres','-d','postgres','--schema=kabipay_ops','--format=custom','--file',path.join(directory,'ops-foundation.dump')]);
    pg('pg_restore', ['-h','127.0.0.1','-p',String(port),'-U','postgres','-d','fixture_restore','--no-owner','--no-acl',path.join(directory,'ops-foundation.dump')]);
    assert.equal(run(path.join(bin, 'pg_restore.exe'), ['-h','127.0.0.1','-p',String(port),'-U','postgres','-d','fixture_restore','--no-owner','--no-acl',path.join(replacement, 'tenant-before-import.dump')], 'restore.log', {env}), 0, `Backup restore failed; logs: ${directory}`);
    const restored = new Client({host:'127.0.0.1',port,database:'fixture_restore',user:'postgres'});
    await restored.connect();
    try {assert.equal((await restored.query(`SELECT first_name FROM ${schema}.employee WHERE employee_code='EXAMPLE-001'`)).rows[0].first_name, 'Intervening');}
    finally {await restored.end();}
    console.log('PASS snapshot backup restores pre-replacement employee data into a separate database');
    console.log(`Disposable fixture evidence: ${directory}`);
  } catch (error) {
    console.error(`Fixture failure: ${error.message}; evidence: ${directory}`);
    throw error;
  } finally {await db.end().catch(() => {}); if(started) {
    try { pg('pg_ctl',['-D',data,'-m','fast','-w','stop']); }
    catch (error) { console.error(`Fixture cleanup failed: ${error.message}`); process.exitCode=1; }
  }}
}
main().catch(error => {console.error(error.message);process.exitCode=1;});
