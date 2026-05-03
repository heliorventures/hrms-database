/**
 * Run SQL from argv or -f file using `load-env.cjs` (pg, no psql).
 *   node run-sql.cjs "SELECT 1"
 *   node run-sql.cjs -f script.sql
 */
require("./load-env.cjs");
const { Client } = require("pg");
const fs = require("fs");

/**
 * Split a SQL script into statements at line endings that terminate with `;`.
 * Avoids sending multi-statement strings in one pg round-trip (Neon pooler / some proxies reject it).
 * Scripts must not place meaningful semicolons inside unterminated multi-line chunks except after full statements.
 */
function splitStatements(sql) {
  const lines = sql.split(/\r?\n/);
  const out = [];
  let buf = [];
  for (const line of lines) {
    buf.push(line);
    if (/;\s*$/.test(line)) {
      const stmt = buf.join("\n").trim();
      if (stmt) out.push(stmt);
      buf = [];
    }
  }
  const tail = buf.join("\n").trim();
  if (tail) out.push(tail);
  return out.length ? out : [sql.trim()];
}

async function main() {
  const argv = process.argv.slice(2);
  let sql;
  if (argv[0] === "-f" && argv[1]) {
    sql = fs.readFileSync(argv[1], "utf8");
  } else if (argv.length) {
    sql = argv.join(" ");
  } else {
    sql = fs.readFileSync(0, "utf8");
  }
  if (!sql.trim()) {
    console.error("No SQL. Usage: node run-sql.cjs \"...\"  or  -f file.sql");
    process.exit(1);
  }
  const host = process.env.POSTGRES_HOST || "localhost";
  const port = parseInt(process.env.POSTGRES_PORT || "5432", 10);
  const database = process.env.POSTGRES_DB;
  const user = process.env.POSTGRES_USER;
  const password = process.env.POSTGRES_PASSWORD;
  const useSsl = process.env.POSTGRES_SSLMODE === "require" || process.env.POSTGRES_SSLMODE === "verify-full";
  const ssl = useSsl ? { rejectUnauthorized: false } : undefined;
  if (!database || !user) {
    console.error("Set POSTGRES_DB and POSTGRES_USER in kabipay-database/.env (or kabipay-svc/.env in a monorepo).");
    process.exit(1);
  }
  const client = new Client({ host, port, database, user, password, ssl });
  await client.connect();
  try {
    const stmts = splitStatements(sql);
    for (const stmt of stmts) {
      if (!stmt.trim()) continue;
      await client.query(stmt);
    }
  } finally {
    await client.end();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
