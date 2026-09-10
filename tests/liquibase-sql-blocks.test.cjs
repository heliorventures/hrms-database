const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

function readRepositoryFile(...segments) {
  return fs.readFileSync(path.join(__dirname, "..", ...segments), "utf8");
}

test("0052-003 keeps its PostgreSQL DO block as one Liquibase statement", () => {
  const changelogPath = path.join(
    __dirname,
    "..",
    "changelog",
    "migrations",
    "0052_payroll_assets_hrms_depth",
    "payroll_assets_hrms_depth.xml",
  );
  const changelog = fs.readFileSync(changelogPath, "utf8");
  const changeSet = changelog.match(
    /<changeSet id="0052-003-assets-self-read-permissions"[\s\S]*?<\/changeSet>/,
  );

  assert.ok(changeSet, "0052-003 changeset must exist");
  assert.match(changeSet[0], /<sql splitStatements="false"><!\[CDATA\[\s*DO \$\$/);
});

test("asset identifiers are normalized and constrained by a forward-only migration", () => {
  const master = readRepositoryFile("changelog", "tenant.changelog-master.xml");
  const migration = readRepositoryFile(
    "changelog",
    "migrations",
    "0061_asset_identifier_integrity",
    "asset_identifier_integrity.xml",
  );

  assert.match(master, /migrations\/0061_asset_identifier_integrity\/asset_identifier_integrity\.xml/);
  assert.match(migration, /UPPER\(BTRIM\(asset_tag\)\)/);
  assert.match(migration, /UPPER\(BTRIM\(serial_number\)\)/);
  assert.match(migration, /chk_asset_tag_normalized/);
  assert.match(migration, /chk_asset_serial_number_normalized/);
});

test("private cleanup claims and blocked upload stages have durable database state", () => {
  const master = readRepositoryFile("changelog", "tenant.changelog-master.xml");
  const migration = readRepositoryFile(
    "changelog",
    "migrations",
    "0062_private_file_cleanup_hardening",
    "private_file_cleanup_hardening.xml",
  );

  assert.match(master, /migrations\/0062_private_file_cleanup_hardening\/private_file_cleanup_hardening\.xml/);
  assert.match(migration, /name="claim_token" type="UUID"/);
  assert.match(migration, /name="cleanup_blocked_at" type="TIMESTAMPTZ"/);
  assert.match(migration, /name="cleanup_error_class" type="VARCHAR\(40\)"/);
  assert.match(migration, /chk_private_file_cleanup_claim_lifecycle/);
  assert.match(migration, /chk_file_upload_stage_cleanup_block/);
  assert.match(migration, /cleanup_error_class IS NOT NULL/);
  assert.match(migration, /Private-file cleanup hardening blocked/);
  assert.doesNotMatch(migration, /SET claim_token = gen_random_uuid\(\)/);
});

test("post-migration verification covers normalized identifiers and claim ownership", () => {
  const verification = readRepositoryFile(
    "tests",
    "asset_management_lifecycle_verification.sql",
  );

  assert.match(verification, /asset_tag_not_normalized/);
  assert.match(verification, /serial_number_not_normalized/);
  assert.match(verification, /private_file_cleanup_processing_claim_token_missing/);
  assert.match(verification, /file_upload_stage_invalid_cleanup_block/);
  assert.match(verification, /tenant_id, upper\(btrim\(/i);
  assert.match(verification, /'asset_tag'/);
  assert.match(verification, /'serial_number'/);
});

test("npm test executes the Liquibase regression suite", () => {
  const packageJson = JSON.parse(readRepositoryFile("package.json"));

  assert.ok(packageJson.scripts.test.split(' && ').includes('node tests/liquibase-sql-blocks.test.cjs'));
});
