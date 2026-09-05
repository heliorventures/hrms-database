require("../load-env.cjs");

const fs = require("fs");
const { Client } = require("pg");

const overrides = {
  POSTGRES_HOST: "WORKPLACE_RBAC_POSTGRES_HOST",
  POSTGRES_PORT: "WORKPLACE_RBAC_POSTGRES_PORT",
  POSTGRES_DB: "WORKPLACE_RBAC_POSTGRES_DB",
  POSTGRES_USER: "WORKPLACE_RBAC_POSTGRES_USER",
  POSTGRES_PASSWORD: "WORKPLACE_RBAC_POSTGRES_PASSWORD",
  POSTGRES_SSLMODE: "WORKPLACE_RBAC_POSTGRES_SSLMODE",
};
for (const [target, source] of Object.entries(overrides)) {
  if (Object.prototype.hasOwnProperty.call(process.env, source)) {
    process.env[target] = process.env[source];
  }
}

async function main() {
  const sqlPath = process.argv[2];
  if (!sqlPath) throw new Error("Usage: node run-workplace-rbac-audit.cjs <sql-file>");
  const sql = fs.readFileSync(sqlPath, "utf8");
  const host = process.env.POSTGRES_HOST || "localhost";
  const port = Number.parseInt(process.env.POSTGRES_PORT || "5432", 10);
  const database = process.env.POSTGRES_DB;
  const user = process.env.POSTGRES_USER;
  const password = process.env.POSTGRES_PASSWORD;
  if (!database || !user) throw new Error("Configure POSTGRES_DB and POSTGRES_USER in .env or pass connection parameters");
  const sslMode = process.env.POSTGRES_SSLMODE;
  const ssl = sslMode === "require" || sslMode === "verify-full" ? { rejectUnauthorized: false } : undefined;
  const client = new Client({ host, port, database, user, password, ssl });
  await client.connect();
  try {
    const results = await client.query(sql);
    for (const result of Array.isArray(results) ? results : [results]) {
      if (result.rows?.length) console.table(result.rows);
    }
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
