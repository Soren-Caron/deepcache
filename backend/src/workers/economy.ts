/**
 * M6-5. Nightly economy worker.
 *
 * Reads the trailing 24h of the ledger, runs the PI controller over it, and
 * publishes the result as a new `economy_config` version that game servers
 * pull. Every run writes an `economy_daily` audit row -- including the runs
 * that decide *not* to adjust, because "the controller did nothing last
 * night" and "the controller never ran last night" are different facts and
 * only an audit row distinguishes them.
 *
 * `admin_adjust` is excluded from both totals, matching `Ledger.totals` on
 * the Luau side: a manual correction is not economy activity the loop should
 * react to, and letting one skew the ratio would have the controller chase a
 * number a human just typed in.
 */

import type pg from "pg";
import {
  initialState,
  step,
  type ControllerState,
  type Decision,
  type Observation,
} from "../economy/controller.js";

/** Mirrors Ledger.FAUCETS / Ledger.SINKS. */
const FAUCET_REASONS = [
  "extract_payout",
  "objective_bonus",
  "daily_first",
  "insurance_claim",
  "market_sale",
];
const SINK_REASONS = [
  "repair",
  "ammo",
  "insurance_premium",
  "market_fee",
  "market_purchase",
  "cosmetic",
];

const DAY_MS = 24 * 60 * 60 * 1000;

export interface EconomyRunResult {
  readonly observation: Observation;
  readonly decision: Decision;
  readonly state: ControllerState;
  readonly publishedVersion: number | null;
}

/**
 * Resume the controller from the most recent audit row. Without this the
 * integral term resets on every process restart, which silently discards the
 * accumulated error the I in PI exists to hold.
 */
async function loadState(pool: pg.Pool): Promise<ControllerState> {
  const audit = await pool.query<{ integral: string; clamped_days: number }>(
    `SELECT integral, clamped_days FROM economy_daily
     WHERE applied = true ORDER BY day DESC LIMIT 1`,
  );
  const config = await pool.query<{ multiplier: string }>(
    `SELECT multiplier FROM economy_config ORDER BY version DESC LIMIT 1`,
  );

  const base = initialState();
  return {
    multiplier: config.rows[0] ? Number(config.rows[0].multiplier) : base.multiplier,
    integral: audit.rows[0] ? Number(audit.rows[0].integral) : base.integral,
    clampedDays: audit.rows[0] ? Number(audit.rows[0].clamped_days) : base.clampedDays,
  };
}

async function observe(pool: pg.Pool, windowStart: Date): Promise<Observation> {
  const totals = await pool.query<{ faucet: string | null; sink: string | null }>(
    `SELECT
       SUM(ABS(delta)) FILTER (WHERE reason = ANY($2::text[])) AS faucet,
       SUM(ABS(delta)) FILTER (WHERE reason = ANY($3::text[])) AS sink
     FROM ledger WHERE ts >= $1`,
    [windowStart, FAUCET_REASONS, SINK_REASONS],
  );
  const runs = await pool.query<{ count: string }>(
    `SELECT COUNT(DISTINCT run_id) AS count FROM run_summary WHERE started_at >= $1`,
    [windowStart],
  );

  return {
    faucetTotal: Number(totals.rows[0]?.faucet ?? 0),
    sinkTotal: Number(totals.rows[0]?.sink ?? 0),
    runCount: Number(runs.rows[0]?.count ?? 0),
  };
}

/**
 * One nightly pass. Idempotent per day: the audit row is upserted on `day`,
 * so a worker that runs twice in one day does not publish two versions off
 * the same window and double-count the integral.
 */
export async function runEconomyTick(
  pool: pg.Pool,
  options: { now?: Date; autotuneEnabled?: boolean } = {},
): Promise<EconomyRunResult> {
  const now = options.now ?? new Date();
  const enabled = options.autotuneEnabled ?? true;
  const windowStart = new Date(now.getTime() - DAY_MS);

  const prior = await loadState(pool);
  const observation = await observe(pool, windowStart);
  const { state, decision } = step(prior, observation, enabled);

  const day = now.toISOString().slice(0, 10);
  await pool.query(
    `INSERT INTO economy_daily
       (day, faucet, sink, ratio, multiplier, applied_at, integral, clamped_days, applied, reason, run_count)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
     ON CONFLICT (day) DO UPDATE SET
       faucet = EXCLUDED.faucet, sink = EXCLUDED.sink, ratio = EXCLUDED.ratio,
       multiplier = EXCLUDED.multiplier, applied_at = EXCLUDED.applied_at,
       integral = EXCLUDED.integral, clamped_days = EXCLUDED.clamped_days,
       applied = EXCLUDED.applied, reason = EXCLUDED.reason, run_count = EXCLUDED.run_count`,
    [
      day,
      Math.round(observation.faucetTotal),
      Math.round(observation.sinkTotal),
      decision.ratio,
      decision.multiplier,
      now,
      state.integral,
      state.clampedDays,
      decision.applied,
      decision.reason,
      observation.runCount,
    ],
  );

  if (!decision.applied) {
    return { observation, decision, state, publishedVersion: null };
  }

  // Publish as the next version. Derived from MAX rather than a sequence so a
  // manually inserted override row cannot be silently overwritten by the
  // worker landing on the same number.
  const published = await pool.query<{ version: string }>(
    `INSERT INTO economy_config (version, multiplier, source)
     SELECT COALESCE(MAX(version), 0) + 1, $1, 'controller' FROM economy_config
     RETURNING version`,
    [decision.multiplier],
  );

  return {
    observation,
    decision,
    state,
    publishedVersion: Number(published.rows[0]?.version ?? 0),
  };
}

/** Same started-outside-buildApp reasoning as the rollup and recommend timers. */
export function startEconomyWorker(pool: pg.Pool, intervalMs = DAY_MS): NodeJS.Timeout {
  return setInterval(() => {
    void runEconomyTick(pool).catch(() => {
      // A failed nightly pass must not take the process down; the next one
      // re-reads the same window from the ledger, which is the source of truth.
    });
  }, intervalMs);
}
