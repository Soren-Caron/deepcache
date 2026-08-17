/**
 * Minimal migration runner.
 *
 * One file per migration in `migrations/`, each split into `-- +up` and
 * `-- +down` sections. Applied migrations are tracked in `schema_migrations`
 * so re-running `up` is a no-op and `down` reverses exactly what was applied,
 * in reverse order.
 *
 * Deliberately hand-rolled rather than a framework: the schema here is a
 * handful of tables, and a 60-line runner is easier to audit than a new
 * dependency with its own migration-state format to trust.
 *
 * Usage:
 *   tsx src/migrate.ts up
 *   tsx src/migrate.ts down        # reverts the most recent migration
 *   tsx src/migrate.ts down --all  # reverts everything
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import pg from "pg";
import { loadConfig } from "./config.js";

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "migrations");

interface Migration {
  readonly id: string;
  readonly up: string;
  readonly down: string;
}

function loadMigrations(): Migration[] {
  const files = readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith(".sql"))
    .sort();

  return files.map((name) => {
    const raw = readFileSync(join(MIGRATIONS_DIR, name), "utf8");
    const upMarker = "-- +up";
    const downMarker = "-- +down";
    const upStart = raw.indexOf(upMarker);
    const downStart = raw.indexOf(downMarker);
    if (upStart === -1 || downStart === -1 || downStart < upStart) {
      throw new Error(`migration ${name} is missing a "${upMarker}" or "${downMarker}" section`);
    }
    return {
      id: name,
      up: raw.slice(upStart + upMarker.length, downStart).trim(),
      down: raw.slice(downStart + downMarker.length).trim(),
    };
  });
}

async function ensureMigrationsTable(client: pg.PoolClient): Promise<void> {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )
  `);
}

async function appliedIds(client: pg.PoolClient): Promise<Set<string>> {
  const result = await client.query<{ id: string }>("SELECT id FROM schema_migrations ORDER BY id");
  return new Set(result.rows.map((row) => row.id));
}

async function up(pool: pg.Pool): Promise<string[]> {
  const migrations = loadMigrations();
  const client = await pool.connect();
  const applied: string[] = [];
  try {
    await ensureMigrationsTable(client);
    const already = await appliedIds(client);
    for (const migration of migrations) {
      if (already.has(migration.id)) continue;
      await client.query("BEGIN");
      try {
        await client.query(migration.up);
        await client.query("INSERT INTO schema_migrations (id) VALUES ($1)", [migration.id]);
        await client.query("COMMIT");
        applied.push(migration.id);
      } catch (err) {
        await client.query("ROLLBACK");
        throw new Error(`migration ${migration.id} failed: ${String(err)}`);
      }
    }
  } finally {
    client.release();
  }
  return applied;
}

async function down(pool: pg.Pool, all: boolean): Promise<string[]> {
  const migrations = loadMigrations();
  const byId = new Map(migrations.map((m) => [m.id, m]));
  const client = await pool.connect();
  const reverted: string[] = [];
  try {
    await ensureMigrationsTable(client);
    const already = [...(await appliedIds(client))].sort().reverse();
    const targets = all ? already : already.slice(0, 1);
    for (const id of targets) {
      const migration = byId.get(id);
      if (migration === undefined) {
        throw new Error(`applied migration ${id} has no matching file on disk`);
      }
      await client.query("BEGIN");
      try {
        await client.query(migration.down);
        await client.query("DELETE FROM schema_migrations WHERE id = $1", [id]);
        await client.query("COMMIT");
        reverted.push(id);
      } catch (err) {
        await client.query("ROLLBACK");
        throw new Error(`reverting ${id} failed: ${String(err)}`);
      }
    }
  } finally {
    client.release();
  }
  return reverted;
}

async function main(): Promise<void> {
  const direction = process.argv[2];
  const config = loadConfig();
  const pool = new pg.Pool({ connectionString: config.databaseUrl });

  try {
    if (direction === "up") {
      const applied = await up(pool);
      console.log(applied.length === 0 ? "up to date" : `applied: ${applied.join(", ")}`);
    } else if (direction === "down") {
      const all = process.argv.includes("--all");
      const reverted = await down(pool, all);
      console.log(reverted.length === 0 ? "nothing to revert" : `reverted: ${reverted.join(", ")}`);
    } else {
      console.error(`usage: tsx src/migrate.ts <up|down> [--all]`);
      process.exitCode = 1;
    }
  } finally {
    await pool.end();
  }
}

// Only run when invoked directly (`tsx src/migrate.ts ...`), not when
// imported by the test suite, which drives `up`/`down` against its own pool.
// Built via pathToFileURL rather than a manual `file://` prefix: on Windows,
// import.meta.url is `file:///C:/...` (three slashes, forward slashes,
// percent-encoded), and a hand-built string mismatches it silently — this
// check would simply never fire and `up`/`down` would run on every import.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err: unknown) => {
    console.error(err);
    process.exitCode = 1;
  });
}

export { up, down, loadMigrations };
