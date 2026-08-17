import { beforeAll, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { closePool, getPool } from "../src/db.js";
import { runRollup } from "../src/rollup.js";

/**
 * docs/04's acceptance criterion for the rollup worker: run it three times
 * over identical input, assert byte-identical output. That is the whole
 * point of "recomputes rather than increments" -- an incrementing worker
 * would triple-count on the second and third run.
 */

let pool: ReturnType<typeof getPool>;
const runId = `rollup-test-${Date.now()}`;
const pidA = `pid-a-${Date.now()}`;
const pidB = `pid-b-${Date.now()}`;

function envelope(
  seq: number,
  type: string,
  ts: number,
  payload: Record<string, unknown>,
  pid: string | null = null,
): unknown[] {
  return [ts, runId, "test-server", pid, type, seq, JSON.stringify(payload)];
}

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  pool = getPool(loadConfig());

  // Insert a realistic small run directly -- this suite is about the
  // rollup's aggregation, not about re-proving ingest, so it writes rows
  // straight into `events` rather than going through HTTP.
  const rows = [
    envelope(1, "run.start", 1700000000, { seed: 1, squadSize: 3 }),
    envelope(2, "extract.success", 1700000100, { zone: "Perimeter", carriedValue: 500 }, pidA),
    envelope(3, "extract.success", 1700000200, { zone: "Processing", carriedValue: 900 }, pidB),
    envelope(4, "player.death", 1700000300, { droppedValue: 200 }, pidA),
    envelope(5, "perf.tick", 1700000050, { p50: 1.1, p95: 2.2, p99: 3.3 }),
    envelope(6, "perf.tick", 1700000150, { p50: 1.3, p95: 2.6, p99: 3.9 }),
    envelope(
      7,
      "run.end",
      1700000400,
      { outcome: "squadResolved", durationSeconds: 400, extracted: 2, deaths: 1, valueExtracted: 1400 },
    ),
  ];

  for (const row of rows) {
    await pool.query(
      `INSERT INTO events (ts, run_id, server_id, pid, type, seq, payload)
       VALUES (to_timestamp($1), $2, $3, $4, $5, $6, $7::jsonb)`,
      row,
    );
  }
});

describe("runRollup", () => {
  it("produces byte-identical run_summary and player_stats across three runs", async () => {
    await runRollup(pool);
    const firstSummary = await pool.query("SELECT * FROM run_summary WHERE run_id = $1", [runId]);
    const firstPlayers = await pool.query(
      "SELECT * FROM player_stats WHERE pid = ANY($1) ORDER BY pid",
      [[pidA, pidB]],
    );

    await runRollup(pool);
    await runRollup(pool);
    const thirdSummary = await pool.query("SELECT * FROM run_summary WHERE run_id = $1", [runId]);
    const thirdPlayers = await pool.query(
      "SELECT * FROM player_stats WHERE pid = ANY($1) ORDER BY pid",
      [[pidA, pidB]],
    );

    expect(thirdSummary.rows).toEqual(firstSummary.rows);
    expect(thirdPlayers.rows).toEqual(firstPlayers.rows);
  });

  it("aggregates run_summary correctly from the event fields", async () => {
    await runRollup(pool);
    const result = await pool.query("SELECT * FROM run_summary WHERE run_id = $1", [runId]);
    const row = result.rows[0];

    expect(row.squad_size).toBe(3);
    expect(row.duration_s).toBeCloseTo(400, 5);
    expect(row.extracted_count).toBe(2);
    expect(row.death_count).toBe(1);
    expect(Number(row.value_extracted)).toBe(1400);
    // Average of 2.2 and 2.6.
    expect(row.tick_p95_ms).toBeCloseTo(2.4, 5);
    // No director.decision events exist yet -- correctly zero, not null,
    // because COUNT(*) FILTER always returns a number even over zero rows.
    expect(row.director_calls).toBe(0);
    expect(row.director_fallbacks).toBe(0);
    // No source event for bandwidth exists yet.
    expect(row.snapshot_bytes_per_s).toBeNull();
  });

  it("aggregates player_stats correctly per pid, ignoring null-pid events", async () => {
    await runRollup(pool);
    const result = await pool.query(
      "SELECT * FROM player_stats WHERE pid = ANY($1) ORDER BY pid",
      [[pidA, pidB]],
    );
    const [a, b] = result.rows as Array<Record<string, unknown>>;

    expect(a?.["pid"]).toBe(pidA);
    expect(a?.["extracts"]).toBe(1);
    expect(a?.["deaths"]).toBe(1);
    expect(Number(a?.["avg_value"])).toBeCloseTo(500, 5);

    expect(b?.["pid"]).toBe(pidB);
    expect(b?.["extracts"]).toBe(1);
    expect(b?.["deaths"]).toBe(0);
    expect(Number(b?.["avg_value"])).toBeCloseTo(900, 5);
  });

  it("seeds a new player at the Glicko defaults and never overwrites them on recompute", async () => {
    await runRollup(pool);
    const before = await pool.query("SELECT rating, rd FROM player_stats WHERE pid = $1", [pidA]);
    expect(before.rows[0].rating).toBeCloseTo(1500, 5);
    expect(before.rows[0].rd).toBeCloseTo(350, 5);

    // Simulate M5's rating engine having updated this player.
    await pool.query("UPDATE player_stats SET rating = 1620, rd = 180 WHERE pid = $1", [pidA]);

    // A rollup rerun -- triggered by new unrelated events landing -- must
    // not clobber a real rating back to the seed default.
    await runRollup(pool);
    const after = await pool.query("SELECT rating, rd FROM player_stats WHERE pid = $1", [pidA]);
    expect(after.rows[0].rating).toBeCloseTo(1620, 5);
    expect(after.rows[0].rd).toBeCloseTo(180, 5);
  });

  it("treats a run with no run.end as unresolved, not as zero", async () => {
    const inProgressId = `rollup-inprogress-${Date.now()}`;
    await pool.query(
      `INSERT INTO events (ts, run_id, server_id, pid, type, seq, payload)
       VALUES (to_timestamp($1), $2, $3, NULL, $4, $5, $6::jsonb)`,
      [1700000000, inProgressId, "test-server", "run.start", 1, JSON.stringify({ seed: 2, squadSize: 2 })],
    );
    await runRollup(pool);

    const result = await pool.query("SELECT * FROM run_summary WHERE run_id = $1", [inProgressId]);
    const row = result.rows[0];
    // Null, not 0: a run that has not finished has not "extracted zero
    // players" -- it has not resolved at all, and the dashboard needs to be
    // able to tell those apart.
    expect(row.extracted_count).toBeNull();
    expect(row.death_count).toBeNull();
    expect(row.duration_s).toBeNull();
    expect(row.squad_size).toBe(2);
  });
});
