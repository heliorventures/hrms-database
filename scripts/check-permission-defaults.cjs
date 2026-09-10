const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

function readDefaults() {
  const master = fs.readFileSync(path.join(root, 'changelog/tenant.changelog-master.xml'), 'utf8');
  const decisions = new Map();
  for (const [, file] of master.matchAll(/<include file="([^"]+)"/g)) {
    const xml = fs.readFileSync(path.join(root, 'changelog', file), 'utf8');
    const block = xml.match(/-- permission-defaults:start([\s\S]*?)-- permission-defaults:end/);
    if (!block) continue;
    for (const [, resource, action, admin, hr] of block[1].matchAll(/\('([a-z_]+)'\s*,\s*'([a-z_]+)'\s*,\s*'(ALL|SELF|TEAM|NONE)'\s*,\s*'(ALL|SELF|TEAM|NONE)'\)/g)) {
      decisions.set(`${resource}:${action}`, { resource, action, admin, hr });
    }
  }
  return decisions;
}

function checkCoverage(source) {
  const decisions = readDefaults();
  return [...new Set([...source.matchAll(/['"]([a-z_]+:[a-z_]+)['"]/g)].map(m => m[1]))]
    .filter(code => !decisions.has(code)).sort();
}

if (require.main === module) {
  if (process.argv[2] === '--json') {
    process.stdout.write(JSON.stringify([...readDefaults().values()]));
  } else {
    const ui = process.argv[2] || path.join(root, '../hrms-ui/src/auth/permissions.ts');
    const missing = checkCoverage(fs.readFileSync(ui, 'utf8'));
    if (missing.length) {
      console.error('Permissions require a forward migration with explicit Admin/HR defaults:', missing.join(', '));
      process.exitCode = 1;
    } else console.log('All UI permissions have registered Admin/HR migration defaults.');
  }
}
module.exports = { checkCoverage, readDefaults };
