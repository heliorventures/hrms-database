/**
 * DB tooling env: optional sibling `../kabipay-svc/.env` (monorepo), then `kabipay-database/.env` (wins for overlapping keys).
 * Standalone `kabipay-database` clone: use only this folder’s `.env` (see `.env.example`).
 */
const fs = require("fs");
const path = require("path");
const dotenv = require("dotenv");
const here = __dirname;
const svcEnv = path.join(here, "..", "kabipay-svc", ".env");
const localEnv = path.join(here, ".env");
if (fs.existsSync(svcEnv)) {
  dotenv.config({ path: svcEnv, override: false });
}
if (fs.existsSync(localEnv)) {
  dotenv.config({ path: localEnv, override: true });
}
