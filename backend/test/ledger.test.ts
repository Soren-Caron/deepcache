import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { closePool, getPool } from "../src/db.js";

/**
 * M3-4's acceptance criterion, stated in docs/04: "idem_key UNIQUE is the
 * entire duplicate-grant defense. A retried payout is a constraint
 * violation, caught and ignored." This is the ledger write path M6 will
 * build on top of; what's tested here is that the constraint itself holds
 * under real concurrency, not application-level "check then insert" logic
 * that a race could slip through.
 */

let pool: ReturnType<typeof getPool>;

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  pool = getPool(loadConfig());
  // Schema reset happens once, in test/global-setup.ts. See ingest.test.ts's
  // beforeAll for why this must not also reset it.
});

afterAll(async () => {
  await closePool();
});

async function tryInsert(idemKey: string, delta: number): Promise<boolean> {
  const result = await pool.query(
    `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (idem_key) DO NOTHING
     RETURNING id`,
    ["pid-1", delta, 1000 + delta, "extract_payout", "run-1", idemKey],
  );
  return (result.rowCount ?? 0) > 0;
}

describe("ledger idem_key uniqueness", () => {
  it("a duplicate idem_key sent sequentially is a no-op", async () => {
    const key = `seq-${Date.now()}`;
    expect(await tryInsert(key, 500)).toBe(true);
    expect(await tryInsert(key, 500)).toBe(false);

    const rows = await pool.query("SELECT count(*)::int AS n FROM ledger WHERE idem_key = $1", [key]);
    expect(rows.rows[0].n).toBe(1);
  });

  it("ten concurrent identical idem_key inserts land exactly one row", async () => {
    // The real failure this constraint prevents: a client retrying a payout
    // request because it never saw the response, racing its own retry
    // against the original attempt. A sequential test cannot catch a race;
    // this fires all ten at once against the same connection pool.
    const key = `concurrent-${Date.now()}`;
    const attempts = await Promise.all(
      Array.from({ length: 10 }, () => tryInsert(key, 250)),
    );

    const successes = attempts.filter(Boolean).length;
    expect(successes).toBe(1);

    const rows = await pool.query("SELECT count(*)::int AS n, delta FROM ledger WHERE idem_key = $1 GROUP BY delta", [key]);
    expect(rows.rows).toHaveLength(1);
    expect(rows.rows[0].n).toBe(1);
  });

  it("different idem_keys never collide", async () => {
    const stamp = Date.now();
    const results = await Promise.all([
      tryInsert(`distinct-a-${stamp}`, 100),
      tryInsert(`distinct-b-${stamp}`, 200),
      tryInsert(`distinct-c-${stamp}`, 300),
    ]);
    expect(results).toEqual([true, true, true]);
  });
});
