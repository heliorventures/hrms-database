// Ordered, source-bound defaults. Existing tenant customization is not a default.
const fs = require('node:fs');
const path = require('node:path');
const {readDefaults} = require('./check-permission-defaults.cjs');
const root = path.resolve(__dirname, '../../..');

function buildRoleDefaults() {
  const master = fs.readFileSync(path.join(root, 'changelog/tenant.changelog-master.xml'), 'utf8');
  const files = [...master.matchAll(/<include file="([^"]+)"/g)].map(m => m[1]);
  const locate = prefix => {
    const matches = files.filter(file => file.startsWith(`migrations/${prefix}_`));
    if (matches.length !== 1) throw Error(`CANONICAL_DEFAULT_SOURCE_REQUIRED_${prefix}`);
    return {index: files.indexOf(matches[0]), source: fs.readFileSync(path.join(root, 'changelog', matches[0]), 'utf8')};
  };
  const base = locate('0069'), performance = locate('0075'), survey = locate('0076');
  if (!(base.index < performance.index && performance.index < survey.index)) throw Error('CANONICAL_DEFAULT_ORDER_CHANGED');
  const employeeBlock = base.source.match(/WITH employee_grants\(resource, action, scope_type\) AS \(([\s\S]*?)\),\s*employee_derived_roles/);
  const managerBlock = base.source.match(/role_overrides\(role_name, resource, action, scope_type\) AS \(([\s\S]*?)\),\s*grant_candidates/);
  if (!employeeBlock || !managerBlock) throw Error('CANONICAL_BASE_DEFAULT_SOURCE_CHANGED');
  const employee = new Map();
  for (const [,resource,action,scope] of employeeBlock[1].matchAll(/\('([a-z_]+)', '([a-z_-]+)', '(SELF|TEAM|DEPARTMENT|ALL)'\)/g)) employee.set(`${resource}:${action}`, {resource,action,scope});
  if (employee.size !== 20) throw Error('CANONICAL_EMPLOYEE_BASE_REQUIRES_REVIEW');
  const manager = new Map(employee);
  for (const [,resource,action,scope] of managerBlock[1].matchAll(/\('MANAGER', '([a-z_]+)', '([a-z_-]+)', '(SELF|TEAM|DEPARTMENT|ALL)'\)/g)) manager.set(`${resource}:${action}`, {resource,action,scope});
  // These source witnesses deliberately fail on policy drift. Do not silently
  // infer broader grants from a new catalog permission or permission name.
  if (!performance.source.includes("WHEN 'evaluate' THEN 'TEAM' ELSE 'SELF'") ||
      !performance.source.includes("IN ('EMPLOYEE','MANAGER','HR','ADMIN')") ||
      !survey.source.includes("= 'respond' THEN 'SELF'") ||
      !survey.source.includes("= 'MANAGER' THEN 'TEAM' ELSE 'ALL'")) throw Error('REGISTERED_PERSONA_ADDITIONS_REQUIRE_REVIEW');
  employee.set('performance:self', {resource:'performance',action:'self',scope:'SELF'});
  employee.set('survey:respond', {resource:'survey',action:'respond',scope:'SELF'});
  for (const row of employee.values()) if (!manager.has(`${row.resource}:${row.action}`)) manager.set(`${row.resource}:${row.action}`,row);
  manager.set('performance:evaluate', {resource:'performance',action:'evaluate',scope:'TEAM'});
  manager.set('survey:results', {resource:'survey',action:'results',scope:'TEAM'});
  const roles = {EMPLOYEE:employee, MANAGER:manager, HR:new Map(), ADMIN:new Map()};
  for (const row of readDefaults().values()) {
    for (const [role,key] of [['HR','hr'],['ADMIN','admin']]) {
      if (row[key] !== 'NONE') roles[role].set(`${row.resource}:${row.action}`, {resource:row.resource,action:row.action,scope:row[key]});
    }
  }
  return Object.entries(roles).flatMap(([role,permissions]) => [...permissions.values()]
    .sort((a,b) => `${a.resource}:${a.action}`.localeCompare(`${b.resource}:${b.action}`))
    .map(permission => ({role,...permission})));
}

module.exports = {buildRoleDefaults};
if (require.main === module) {
  if (process.argv.length !== 3 || process.argv[2] !== '--json') throw Error('USAGE_CANONICAL_DEFAULTS_JSON');
  process.stdout.write(JSON.stringify(buildRoleDefaults()));
}
