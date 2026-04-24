/**
 * Resolves JAVA_HOME: uses env, system java, or downloads JRE 17 via njre to vendor/jre-17.
 */
const fs = require("fs");
const path = require("path");
const { execSync, spawnSync } = require("child_process");

const vendorRoot = path.join(__dirname, "vendor");
fs.mkdirSync(vendorRoot, { recursive: true });

function hasJavaInPath() {
  try {
    execSync("java -version", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function findJavaHomeUnder(root) {
  if (!fs.existsSync(root)) return null;
  const stack = [root];
  while (stack.length) {
    const d = stack.pop();
    const bin = path.join(d, "bin");
    if (fs.existsSync(path.join(bin, "java.exe")) || fs.existsSync(path.join(bin, "java")))
      return d;
    try {
      for (const n of fs.readdirSync(d, { withFileTypes: true })) {
        if (n.isDirectory() && n.name !== "node_modules" && n.name[0] !== ".")
          stack.push(path.join(d, n.name));
      }
    } catch { /* */ }
  }
  return null;
}

async function main() {
  if (process.env.JAVA_HOME) {
    const jh = process.env.JAVA_HOME.replace(/"/g, "");
    if (fs.existsSync(path.join(jh, "bin", "java.exe")) || fs.existsSync(path.join(jh, "bin", "java"))) {
      console.log(jh);
      return;
    }
  }
  if (hasJavaInPath()) {
    console.log("");
    return;
  }
  const existing = findJavaHomeUnder(vendorRoot);
  if (existing) {
    console.log(existing);
    return;
  }
  // eslint-disable-next-line no-console
  console.error("Downloading Java 17 (first run)…");
  const njre = require("njre");
  await njre.install(17, { installPath: path.join(vendorRoot, "njre-install") });
  const h = findJavaHomeUnder(vendorRoot);
  if (!h) {
    throw new Error("JRE 17 was downloaded but java.exe not found under " + vendorRoot);
  }
  console.log(h);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
