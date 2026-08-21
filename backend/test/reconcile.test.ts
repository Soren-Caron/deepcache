import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { closePool, getPool } from "../src/db.js";
import { reconcile } from "../src/workers/reconcile.js";

/**
 * M6-7. The accept criterion is "over 2,000 simulated runs, zero mismatches",
 * so the headline test simulates 2,000 real runs through real ledger rows in
 * real Postgres and reconciles them. A mock would prove nothing: the job is
 * two SQL aggregations and a comparison.
 */

const config = loadConfig();
const PID_PREFIX = "recon-";

beforeAll(() => {
  process.env["NODE_ENV"] = "test";
});

afterAll(async () => {
  const pool = getPool(config);
  await pool.query("DELETE FROM ledger WHERE pid LIKE $1", [`${PID_PREFIX}%`]);
  await pool.query("DELETE FROM balance_cache WHERE pid LIKE $1", [`${PID_PREFIX}%`]);
  await closePool();
});

beforeEach(async () => {
  // Scoped by pid prefix, not TRUNCATE: other test files run in parallel
  // against this same database.
  const pool = getPool(config);
  await pool.query("DELETE FROM ledger WHERE pid LIKE $1", [`${PID_PREFIX}%`]);
  await pool.query("DELETE FROM balance_cache WHERE pid LIKE $1", [`${PID_PREFIX}%`]);
});

let idem = 0;

/** Append one entry, maintaining the running balance the way the game does. */
async function append(
  pid: string,
  delta: number,
  reason: string,
  runId: string,
  runningBalance: number,
): Promise<number> {
  idem += 1;
  const next = runningBalance + delta;
  await getPool(config).query(
    `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [pid, delta, next, reason, runId, `recon-${idem}-${Date.now()}-${Math.random()}`],
  );
  return next;
}

async function setCache(pid: string, balance: number): Promise<void> {
  await getPool(config).query(
    `INSERT INTO balance_cache (pid, cached_balance, server_id)
     VALUES ($1,$2,'test-server')
     ON CONFLICT (pid) DO UPDATE SET cached_balance = EXCLUDED.cached_balance`,
    [pid, balance],
  );
}

async function onlyOurs(pid?: string) {
  const report = await reconcile(getPool(config));
  return {
    ...report,
    mismatches: report.mismatches.filter(
      (m) => m.pid.startsWith(PID_PREFIX) && (pid === undefined || m.pid === pid),
    ),
  };
}

describe("M6-7 reconciliation", () => {
  it("2,000 simulated runs reconcile with zero mismatches", async () => {
    // The accept criterion, run for real. 40 players across 2,000 runs, each
    // run producing the faucet/sink mix a real run does.
    const PLAYERS = 40;
    const RUNS = 2000;
    const balances = new Map<string, number>();
    for (let p = 0; p < PLAYERS; p += 1) {
      balances.set(`${PID_PREFIX}p${p}`, 0);
    }

    const pool = getPool(config);
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      let seq = 0;
      for (let run = 0; run < RUNS; run += 1) {
        const pid = `${PID_PREFIX}p${run % PLAYERS}`;
        const runId = `${PID_PREFIX}run-${run}`;
        let balance = balances.get(pid) as number;

        // A run's worth of entries, in the order the game emits them. Values
        // vary per run so the sums are not trivially uniform.
        const entries: Array<[string, number]> = [
          ["extract_payout", 250 + (run % 7) * 100],
          ["objective_bonus", (run % 3) * 400],
          ["repair", -(40 + (run % 5) * 10)],
          ["ammo", -(25 * (1 + (run % 4)))],
        ];
        for (const [reason, delta] of entries) {
          if (delta === 0) continue;
          // Never drive the balance negative -- the ledger rejects that, and a
          // fixture that produced it would be testing an impossible state.
          if (balance + delta < 0) continue;
          seq += 1;
          balance += delta;
          await client.query(
            `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key)
             VALUES ($1,$2,$3,$4,$5,$6)`,
            [pid, delta, balance, reason, runId, `recon-bulk-${seq}`],
          );
        }
        balances.set(pid, balance);
      }

      // The game writes its cache behind; it should agree exactly.
      for (const [pid, balance] of balances) {
        await client.query(
          `INSERT INTO balance_cache (pid, cached_balance, server_id)
           VALUES ($1,$2,'test-server')
           ON CONFLICT (pid) DO UPDATE SET cached_balance = EXCLUDED.cached_balance`,
          [pid, balance],
        );
      }
      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }

    const report = await onlyOurs();
    expect(report.mismatches).toEqual([]);
    // Sanity: the run actually produced the volume it claims to have.
    expect(report.entriesChecked).toBeGreaterThan(RUNS * 2);
  }, 120_000);

  it("detects a cache that has drifted from the ledger", async () => {
    const pid = `${PID_PREFIX}drift`;
    let balance = 0;
    balance = await append(pid, 1000, "extract_payout", "run-a", balance);
    balance = await append(pid, -250, "repair", "run-b", balance);
    await setCache(pid, balance + 500); // the game thinks it has 500 more

    const report = await onlyOurs(pid);
    expect(report.mismatches).toHaveLength(1);
    const m = report.mismatches[0];
    expect(m.kind).toBe("cache_drift");
    expect(m.expected).toBe(750);
    expect(m.actual).toBe(1250);
    expect(m.delta).toBe(500);
    expect(m.likelyRunId).toBe("run-b");
  });

  it("does not report a player whose cache has not been written yet", async () => {
    // The write-behind queue coalesces at one write per player per 6s, so a
    // player whose first payout landed seconds ago legitimately has no cache
    // row. Counting that as drift makes zero mismatches unreachable.
    const pid = `${PID_PREFIX}nocache`;
    await append(pid, 500, "extract_payout", "run-a", 0);
    const report = await onlyOurs(pid);
    expect(report.mismatches).toEqual([]);
  });

  it("detects corruption inside the ledger itself, which the cache check cannot", async () => {
    // If the authoritative store is wrong, a cache agreeing with it is also
    // wrong and the comparison passes. The running-balance chain catches it.
    const pid = `${PID_PREFIX}broken`;
    await append(pid, 1000, "extract_payout", "run-a", 0);
    // A row whose balance_after does not follow from the previous one.
    idem += 1;
    await getPool(config).query(
      `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [pid, -100, 5000, "repair", "run-b", `recon-broken-${idem}-${Date.now()}`],
    );
    // Cache agrees with the corrupted running balance, so cache_drift is silent.
    await setCache(pid, 900);

    const report = await onlyOurs(pid);
    const broken = report.mismatches.filter((m) => m.kind === "running_balance_broken");
    expect(broken).toHaveLength(1);
    expect(broken[0].expected).toBe(900); // 1000 - 100
    expect(broken[0].actual).toBe(5000);
    expect(broken[0].likelyRunId).toBe("run-b");
  });

  it("reports one break per player, not every row after it", async () => {
    // Once the chain is broken every later row is off by the same amount;
    // reporting all of them buries the row that actually matters.
    const pid = `${PID_PREFIX}cascade`;
    await append(pid, 1000, "extract_payout", "run-a", 0);
    for (let i = 0; i < 5; i += 1) {
      idem += 1;
      await getPool(config).query(
        `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [pid, 10, 9999 + i, "extract_payout", `run-${i}`, `recon-casc-${idem}-${Date.now()}`],
      );
    }
    const report = await onlyOurs(pid);
    const broken = report.mismatches.filter((m) => m.kind === "running_balance_broken");
    expect(broken).toHaveLength(1);
  });

  it("never mutates balances -- reconciliation reports, it does not repair", async () => {
    // docs/07: a nonzero count is a bug report, not a tuning knob. A job that
    // silently rewrites balances destroys the evidence and would launder a
    // duping exploit into a legitimate-looking number.
    const pid = `${PID_PREFIX}readonly`;
    const balance = await append(pid, 1000, "extract_payout", "run-a", 0);
    await setCache(pid, balance + 777);

    await reconcile(getPool(config));

    const after = await getPool(config).query(
      "SELECT cached_balance FROM balance_cache WHERE pid = $1",
      [pid],
    );
    expect(Number(after.rows[0].cached_balance)).toBe(1777); // untouched
    const ledgerAfter = await getPool(config).query(
      "SELECT SUM(delta) AS s FROM ledger WHERE pid = $1",
      [pid],
    );
    expect(Number(ledgerAfter.rows[0].s)).toBe(1000); // untouched
  });
});
