/**
 * Runs once, before any test file, in vitest's own process (not shared with
 * the test workers). Resets the schema exactly once.
 *
 * Every individual test file's `beforeAll` used to do this itself
 * (`down(pool, true); up(pool)`), which happened to pass because timing
 * never actually collided in practice -- but vitest runs test files in
 * parallel by default, and two files independently dropping and recreating
 * the same live tables is a real race, not a hypothetical one. This file is
 * the only place that resets the schema; individual test files only read
 * and write it.
 */

import pg from "pg";
import { loadConfig } from "../src/config.js";
import { down, up } from "../src/migrate.js";

export async function setup(): Promise<void> {
  process.env["NODE_ENV"] = "test";
  const config = loadConfig();
  const pool = new pg.Pool({ connectionString: config.databaseUrl });
  try {
    await down(pool, true);
    await up(pool);
  } finally {
    await pool.end();
  }
}
