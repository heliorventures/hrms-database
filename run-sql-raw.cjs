/**
 * Run a SQL file as one PostgreSQL request using `load-env.cjs`.
 *
 * Use this for PostgreSQL blocks that must not be split by semicolon, for example
 * `DO $$ ... $$;`.
 *
 * Usage:
 *   node run-sql-raw.cjs -f script.sql
 *   node run-sql-raw.cjs "SELECT 1"
 */
require("./load-env.cjs");

const fs = require("fs");
const { Client } = require("pg");

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
    console.error("No SQL. Usage: node run-sql-raw.cjs -f script.sql");
    process.exit(1);
  }

  const host = process.env.POSTGRES_HOST || "localhost";
  const port = parseInt(process.env.POSTGRES_PORT || "5432", 10);
  const database = process.env.POSTGRES_DB;
  const user = process.env.POSTGRES_USER;
  const password = process.env.POSTGRES_PASSWORD;
  const useSsl =
    process.env.POSTGRES_SSLMODE === "require" || process.env.POSTGRES_SSLMODE === "verify-full";
  const ssl = useSsl ? { rejectUnauthorized: false } : undefined;

  if (!database || !user) {
    console.error("Set POSTGRES_DB and POSTGRES_USER in hrms-database/.env.");
    process.exit(1);
  }

  const client = new Client({ host, port, database, user, password, ssl });
  client.on("notice", (notice) => {
    if (notice && notice.message) {
      console.log(`NOTICE: ${notice.message}`);
    }
  });

  await client.connect();
  try {
    const result = await client.query(sql);
    if (result.rows && result.rows.length > 0) {
      console.table(result.rows);
    }
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
