import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { closePool, getPool } from "../src/db.js";
import { runEconomyTick } from "../src/workers/economy.js";
import { validateConfigRow } from "../src/routes/config.js";
import { MULT_MAX, MULT_MIN, step, initialState } from "../src/economy/controller.js";

/**
 * M6-5. Real Postgres, not a mock: the worker's whole job is aggregating the
 * ledger and publishing a version, and both halves are SQL. A mock would only
 * prove the queries are well-formed strings.
 */

let app: FastifyInstance;
const config = loadConfig();

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  app = await buildApp({ config, logger: false });
  await app.ready();
});

afterAll(async () => {
  await app.close();
  await closePool();
});

beforeEach(async () => {
  const pool = getPool(config);
  await pool.query("DELETE FROM ledger");
  await pool.query("DELETE FROM economy_daily");
  await pool.query("DELETE FROM economy_config");
  await pool.query("INSERT INTO economy_config (version, multiplier, source) VALUES (1, 1.0, 'seed')");
  // Only this file's own seeded runs. `observe()` counts every run in the
  // window, so runs left behind by an earlier test in this file push a later
  // one over MIN_RUNS and it silently stops testing what it says it does --
  // exactly how the "sample too small" case first passed for the wrong reason.
  // Scoped by prefix rather than TRUNCATE because other test files run in
  // parallel against this same database.
  await pool.query("DELETE FROM run_summary WHERE run_id LIKE 'econ-run-%'");
});

/**
 * A far-future base instant, not `new Date()`.
 *
 * `observe()` counts every run in the trailing 24h across the whole
 * `run_summary` table, which is exactly right in production and hostile to a
 * test suite: vitest runs test files in parallel against one Postgres, so
 * rows written by rollup/ingest tests near the real present would drift into
 * the window and make `runCount` nondeterministic. Anchoring the window in
 * 2090 means only rows this file seeds can possibly fall inside it, without
 * deleting data other files are concurrently relying on.
 */
const BASE = new Date("2090-01-01T12:00:00.000Z");
function at(offsetMs: number): Date {
  return new Date(BASE.getTime() + offsetMs);
}

let idem = 0;
async function ledgerEntry(reason: string, delta: number, ts: Date): Promise<void> {
  idem += 1;
  await getPool(config).query(
    `INSERT INTO ledger (pid, delta, balance_after, reason, run_id, idem_key, ts)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    ["pid-1", delta, 0, reason, "run-1", `idem-${idem}-${Date.now()}`, ts],
  );
}

async function seedRuns(count: number, ts: Date): Promise<void> {
  const pool = getPool(config);
  for (let i = 0; i < count; i += 1) {
    await pool.query(
      `INSERT INTO run_summary (run_id, started_at) VALUES ($1,$2)
       ON CONFLICT (run_id) DO NOTHING`,
      [`econ-run-${i}-${ts.getTime()}`, ts],
    );
  }
}

describe("economy controller (TS mirror of Controller.luau)", () => {
  // The Luau suite pins these exact numbers in tests/controller.spec.luau.
  // Checking the mirror against the same hand-computed values is what stops
  // the two implementations drifting apart silently.
  it("matches the Luau single-step hand computation", () => {
    const { state, decision } = step(
      initialState(),
      { faucetTotal: 1000, sinkTotal: 750, runCount: 300 },
      true,
    );
    expect(decision.ratio).toBeCloseTo(0.75, 9);
    expect(state.integral).toBeCloseTo(0.1, 9);
    expect(state.multiplier).toBeCloseTo(0.97, 9);
  });

  it("skips entirely below the sample floor, freezing the integral", () => {
    const prior = { multiplier: 1.1, integral: 0.5, clampedDays: 0 };
    const { state, decision } = step(
      prior,
      { faucetTotal: 1000, sinkTotal: 500, runCount: 199 },
      true,
    );
    expect(decision.applied).toBe(false);
    expect(state.integral).toBe(0.5);
    expect(state.multiplier).toBe(1.1);
  });

  it("holds the clamps over 365 adversarial days", () => {
    let state = initialState();
    for (let day = 1; day <= 365; day += 1) {
      const obs =
        day % 2 === 0
          ? { faucetTotal: 1_000_000, sinkTotal: 1, runCount: 1000 }
          : { faucetTotal: 1, sinkTotal: 1_000_000, runCount: 1000 };
      const next = step(state, obs, true);
      expect(next.state.multiplier).toBeGreaterThanOrEqual(MULT_MIN - 1e-9);
      expect(next.state.multiplier).toBeLessThanOrEqual(MULT_MAX + 1e-9);
      state = next.state;
    }
  });
});

describe("nightly economy worker", () => {
  it("aggregates the trailing 24h of the ledger and publishes a new version", async () => {
    const now = at(0);
    const inWindow = at(-60 * 60 * 1000);
    await ledgerEntry("extract_payout", 1000, inWindow);
    await ledgerEntry("repair", -750, inWindow);
    await seedRuns(250, inWindow);

    const result = await runEconomyTick(getPool(config), { now });

    expect(result.observation.faucetTotal).toBe(1000);
    expect(result.observation.sinkTotal).toBe(750);
    expect(result.decision.applied).toBe(true);
    expect(result.decision.ratio).toBeCloseTo(0.75, 6);
    expect(result.publishedVersion).toBe(2);
  });

  it("ignores ledger entries older than the window", async () => {
    const now = at(0);
    const old = at(-48 * 60 * 60 * 1000);
    await ledgerEntry("extract_payout", 9999, old);
    await ledgerEntry("extract_payout", 1000, at(-1000));
    await ledgerEntry("repair", -850, at(-1000));
    await seedRuns(250, at(-1000));

    const result = await runEconomyTick(getPool(config), { now });
    expect(result.observation.faucetTotal).toBe(1000);
  });

  it("excludes admin_adjust from both totals", async () => {
    // A manual correction is not economy activity; letting it skew the ratio
    // has the controller chase a number a human just typed in.
    const now = at(0);
    const ts = at(-1000);
    await ledgerEntry("extract_payout", 1000, ts);
    await ledgerEntry("repair", -850, ts);
    await ledgerEntry("admin_adjust", 500000, ts);
    await seedRuns(250, ts);

    const result = await runEconomyTick(getPool(config), { now });
    expect(result.observation.faucetTotal).toBe(1000);
    expect(result.observation.sinkTotal).toBe(850);
  });

  it("writes an audit row even when it decides not to adjust", async () => {
    // "Did nothing" and "never ran" are different facts.
    const now = at(0);
    await ledgerEntry("extract_payout", 100, at(-1000));
    await seedRuns(5, at(-1000)); // below MIN_RUNS

    const result = await runEconomyTick(getPool(config), { now });
    expect(result.decision.applied).toBe(false);
    expect(result.publishedVersion).toBeNull();

    const audit = await getPool(config).query(
      "SELECT applied, reason, run_count FROM economy_daily",
    );
    expect(audit.rowCount).toBe(1);
    expect(audit.rows[0].applied).toBe(false);
    expect(String(audit.rows[0].reason)).toContain("sample too small");
  });

  it("does not publish a second version when run twice in the same day", async () => {
    const now = at(0);
    const ts = at(-1000);
    await ledgerEntry("extract_payout", 1000, ts);
    await ledgerEntry("repair", -750, ts);
    await seedRuns(250, ts);

    await runEconomyTick(getPool(config), { now });
    await runEconomyTick(getPool(config), { now });

    const audit = await getPool(config).query("SELECT COUNT(*) AS c FROM economy_daily");
    expect(Number(audit.rows[0].c)).toBe(1);
  });

  it("resumes the integral across restarts instead of resetting it", async () => {
    // The I in PI is precisely the accumulated error; a restart that zeroes it
    // discards everything the loop has learned.
    const now = at(0);
    const ts = at(-1000);
    await ledgerEntry("extract_payout", 1000, ts);
    await ledgerEntry("repair", -750, ts);
    await seedRuns(250, ts);

    const first = await runEconomyTick(getPool(config), { now });
    expect(first.state.integral).toBeCloseTo(0.1, 6);

    // A fresh call reads state back from the audit row, as a new process would.
    const tomorrow = at(24 * 60 * 60 * 1000);
    await ledgerEntry("extract_payout", 1000, new Date(tomorrow.getTime() - 1000));
    await ledgerEntry("repair", -750, new Date(tomorrow.getTime() - 1000));
    await seedRuns(250, new Date(tomorrow.getTime() - 1000));
    const second = await runEconomyTick(getPool(config), { now: tomorrow });

    // Integral accumulated rather than restarting from 0.
    expect(second.state.integral).toBeGreaterThan(first.state.integral);
  });

  it("the kill switch freezes the multiplier", async () => {
    const now = at(0);
    const ts = at(-1000);
    await ledgerEntry("extract_payout", 100000, ts);
    await ledgerEntry("repair", -1, ts);
    await seedRuns(250, ts);

    const result = await runEconomyTick(getPool(config), { now, autotuneEnabled: false });
    expect(result.decision.applied).toBe(false);
    expect(result.publishedVersion).toBeNull();
  });
});

describe("GET /v1/config", () => {
  async function get(url: string) {
    return app.inject({ method: "GET", url });
  }

  it("serves the highest version", async () => {
    await getPool(config).query(
      "INSERT INTO economy_config (version, multiplier, source) VALUES (7, 0.9, 'controller')",
    );
    const res = await get("/v1/config");
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      current: false,
      config: { version: 7, payoutMultiplier: expect.closeTo(0.9, 5), source: "controller" },
    });
  });

  it("reports current when the caller already has the newest version", async () => {
    await getPool(config).query(
      "INSERT INTO economy_config (version, multiplier, source) VALUES (7, 0.9, 'controller')",
    );
    const res = await get("/v1/config?since=7");
    expect(res.json()).toEqual({ current: true, config: null });
  });

  it("still serves when the caller's version is older", async () => {
    await getPool(config).query(
      "INSERT INTO economy_config (version, multiplier, source) VALUES (7, 0.9, 'controller')",
    );
    const res = await get("/v1/config?since=3");
    expect(res.json().config.version).toBe(7);
  });

  it("skips an out-of-range row and serves the newest valid one instead", async () => {
    // The accept criterion: out-of-range config rejected wholesale. A manual
    // INSERT bypasses the controller's clamp, and shipping that to every live
    // server is the failure this guards.
    const pool = getPool(config);
    await pool.query(
      "INSERT INTO economy_config (version, multiplier, source) VALUES (5, 1.0, 'controller')",
    );
    await pool.query(
      "INSERT INTO economy_config (version, multiplier, source) VALUES (6, 9.99, 'manual')",
    );

    const res = await get("/v1/config");
    expect(res.json().config.version).toBe(5);
    expect(res.json().config.payoutMultiplier).toBeCloseTo(1.0, 5);
  });

  it("rejects a non-integer since rather than coercing it", async () => {
    const res = await get("/v1/config?since=abc");
    expect(res.statusCode).toBe(400);
  });
});

describe("validateConfigRow", () => {
  it("accepts the clamp boundaries", () => {
    expect(validateConfigRow({ version: 1, multiplier: MULT_MIN }).ok).toBe(true);
    expect(validateConfigRow({ version: 1, multiplier: MULT_MAX }).ok).toBe(true);
  });

  it("rejects just outside the boundaries", () => {
    expect(validateConfigRow({ version: 1, multiplier: MULT_MIN - 0.01 }).ok).toBe(false);
    expect(validateConfigRow({ version: 1, multiplier: MULT_MAX + 0.01 }).ok).toBe(false);
  });

  it("rejects a non-finite multiplier and a bad version", () => {
    expect(validateConfigRow({ version: 1, multiplier: Number.NaN }).ok).toBe(false);
    expect(validateConfigRow({ version: 0, multiplier: 1.0 }).ok).toBe(false);
  });
});
