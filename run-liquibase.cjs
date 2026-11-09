/**
 * Run bundled Liquibase with local JRE (ensure-java.cjs). Usage: same as liquibase CLI.
 *   node run-liquibase.cjs --defaults-file=liquibase.properties --url=... --username=... --password=... update
 */
const { spawnSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const ensure = spawnSync(process.execPath, [path.join(__dirname, "ensure-java.cjs")], {
  encoding: "utf8",
});
if (ensure.status !== 0) {
  process.stderr.write(ensure.stderr || "");
  process.exit(ensure.status || 1);
}
const javaHome = (ensure.stdout || "").trim();
const env = { ...process.env };
if (javaHome) env.JAVA_HOME = javaHome;

const home = path.join(__dirname, "node_modules", "liquibase", "dist", "liquibase");
const jar = path.join(home, 'internal', 'lib', 'liquibase-core.jar');
if (!fs.existsSync(jar)) {
  console.error("Missing npm package 'liquibase'. Run: npm install");
  process.exit(1);
}

const args = process.argv.slice(2);
env.LIQUIBASE_HOME=home;
const java=javaHome?path.join(javaHome,'bin',process.platform==='win32'?'java.exe':'java'):'java';
const r = spawnSync(java, ['-jar',jar,...args], { env, stdio: "inherit", shell: false, windowsHide: true });
process.exit(r.status ?? 1);
