/**
 * DB tooling env: use only this folder's `.env` (see `.env.example`).
 * Standalone `kabipay-database` clone: use only this folder’s `.env` (see `.env.example`).
 */
const fs = require("fs");
const path = require("path");
const dotenv = require("dotenv");
const here = __dirname;
const localEnv = path.join(here, ".env");
if (fs.existsSync(localEnv)) {
  dotenv.config({ path: localEnv, override: true });
}
