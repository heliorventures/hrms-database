/**
 * Run SQL from argv or -f file using `load-env.cjs` (pg, no psql).
 *   node run-sql.cjs "SELECT 1"
 *   node run-sql.cjs -f script.sql
 */
require("./load-env.cjs");
const { Client } = require("pg");
const fs = require("fs");

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
    await client.query(sql);
  } finally {
    await client.end();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
