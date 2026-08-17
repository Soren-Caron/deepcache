/**
 * Postgres connection pool.
 *
 * One pool per process, created lazily so tests can build an app without a
 * database and only pay for a connection when a route actually needs one.
 */

import pg from "pg";
import type { Config } from "./config.js";

const { Pool } = pg;

let pool: pg.Pool | undefined;

export function getPool(config: Config): pg.Pool {
  if (pool === undefined) {
    pool = new Pool({ connectionString: config.databaseUrl });
  }
  return pool;
}

/** `SELECT 1`, for /readyz. Never throws — returns false on any failure. */
export async function checkConnection(config: Config): Promise<boolean> {
  try {
    await getPool(config).query("SELECT 1");
    return true;
  } catch {
    return false;
  }
}

/** Closes the pool. Tests call this in `afterAll` so vitest can exit cleanly. */
export async function closePool(): Promise<void> {
  if (pool !== undefined) {
    await pool.end();
    pool = undefined;
  }
}
