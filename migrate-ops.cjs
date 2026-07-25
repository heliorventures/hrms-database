/**
 * Cross-platform entry: `load-env.cjs` → run ops Liquibase update (`npm run migrate-ops`).
 *   npm run migrate-ops
 */
const { spawnSync } = require("child_process");
const path = require("path");
require("./load-env.cjs");

const user = process.env.KABIPAY_DB_USER || process.env.POSTGRES_USER;
const pass = process.env.KABIPAY_DB_PASSWORD || process.env.POSTGRES_PASSWORD;
const hostName = process.env.POSTGRES_HOST;
const port = process.env.POSTGRES_PORT;
const db = process.env.POSTGRES_DB;
const ssl = process.env.POSTGRES_SSLMODE;

if (!hostName || !port || !db) {
  console.error("Set POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB in kabipay-database/.env.");
  process.exit(1);
}
if (!user || !pass) {
  console.error("Set KABIPAY_DB_* or POSTGRES_USER/POSTGRES_PASSWORD");
  process.exit(1);
}

let jdbcUrl = `jdbc:postgresql://${hostName}:${port}/${db}`;
if (ssl) jdbcUrl += jdbcUrl.includes("?") ? `&sslmode=${ssl}` : `?sslmode=${ssl}`;

const lb = path.join(__dirname, "run-liquibase.cjs");
const r = spawnSync(
  process.execPath,
  [lb, "--defaults-file=liquibase.properties", `--url=${jdbcUrl}`, `--username=${user}`, `--password=${pass}`, "update"],
  { cwd: __dirname, stdio: "inherit", env: process.env },
);
process.exit(r.status ?? 1);
