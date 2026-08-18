import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { getPool } from "../src/db.js";
import { recomputeLoadoutPairs } from "../src/workers/recommend.js";

/**
 * M5-10. recomputeLoadoutPairs does a full TRUNCATE + rebuild of
 * loadout_pairs (docs/04's established "full idempotent recompute, not
 * incremental" pattern, same reasoning as rollup.ts) -- global, not
 * run-scoped, same caveat dashboard.test.ts already documents for
 * run_summary/player_stats. Item ids here are marker-unique so this
 * suite's own known inputs are exactly what a recompute call sees.
 */

let app: FastifyInstance;
const pool = getPool(loadConfig());

const marker = Date.now();
const runA = `recommend-test-a-${marker}`;
const runB = `recommend-test-b-${marker}`;
const pidA = `recommend-pid-a-${marker}`;
const pidB = `recommend-pid-b-${marker}`;
const itemX = `item-x-${marker}`;
const itemY = `item-y-${marker}`;
const itemZ = `item-z-${marker}`;

async function insertEvent(
  runId: string,
  pid: string,
  type: string,
  payload: Record<string, unknown>,
  seq: number,
): Promise<void> {
  await pool.query(
    `INSERT INTO events (ts, run_id, server_id, pid, type, seq, payload)
     VALUES (now(), $1, $2, $3, $4, $5, $6::jsonb)`,
    [runId, "recommend-test-server", pid, type, seq, JSON.stringify(payload)],
  );
}

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  app = await buildApp({ config: loadConfig(), logger: false });
  await app.ready();

  // pidA: successful run, picked up itemX and itemY together -> weight 2.
  await insertEvent(runA, pidA, "loot.pickup", { itemId: itemX }, 1);
  await insertEvent(runA, pidA, "loot.pickup", { itemId: itemY }, 2);
  await insertEvent(runA, pidA, "extract.success", { zone: "Perimeter" }, 3);

  // pidB: unsuccessful run, picked up itemX and itemZ together -> weight 1.
  await insertEvent(runB, pidB, "loot.pickup", { itemId: itemX }, 1);
  await insertEvent(runB, pidB, "loot.pickup", { itemId: itemZ }, 2);
  await insertEvent(runB, pidB, "player.death", { droppedValue: 100 }, 3);

  // pidA is an established player (>= COLD_START_RUNS); pidB is cold-start
  // by simply having no player_stats row at all.
  await pool.query(
    `INSERT INTO player_stats (pid, runs, extracts, deaths, avg_value, rating, rd)
     VALUES ($1, 5, 4, 1, 500, 1500, 200)
     ON CONFLICT (pid) DO UPDATE SET runs = EXCLUDED.runs`,
    [pidA],
  );
});

afterAll(async () => {
  await app.close();
});

describe("recomputeLoadoutPairs", () => {
  it("computes weighted co-occurrence and diagonal counts correctly from real inserted telemetry", async () => {
    const result = await recomputeLoadoutPairs(pool);
    expect(result.pairs).toBeGreaterThan(0);

    const rows = await pool.query<{ item_a: string; item_b: string; cooccur: number }>(
      `SELECT item_a, item_b, cooccur FROM loadout_pairs
       WHERE item_a = ANY($1) AND item_b = ANY($1)`,
      [[itemX, itemY, itemZ]],
    );
    const byKey = new Map(rows.rows.map((r) => [`${r.item_a} ${r.item_b}`, r.cooccur]));

    // itemX+itemY co-occurred once, in pidA's successful run -> weight 2.
    expect(byKey.get(`${itemX} ${itemY}`)).toBe(2);
    expect(byKey.get(`${itemY} ${itemX}`)).toBe(2);
    // itemX+itemZ co-occurred once, in pidB's unsuccessful run -> weight 1.
    expect(byKey.get(`${itemX} ${itemZ}`)).toBe(1);
    // itemX's total count: used in both runs, 2 (successful) + 1 (not) = 3.
    expect(byKey.get(`${itemX} ${itemX}`)).toBe(3);
    expect(byKey.get(`${itemY} ${itemY}`)).toBe(2);
    expect(byKey.get(`${itemZ} ${itemZ}`)).toBe(1);
  });
});

describe("GET /v1/recommend/loadout", () => {
  it("requires a pid", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/recommend/loadout" });
    expect(res.statusCode).toBe(400);
  });

  it("cold start (no player_stats row) returns the popularity baseline with fallback=true", async () => {
    await recomputeLoadoutPairs(pool);
    const res = await app.inject({ method: "GET", url: `/v1/recommend/loadout?pid=${pidB}` });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.fallback).toBe(true);
    for (const rec of body.recommendations) {
      expect(rec.reason).toBe("popular_at_your_rating");
    }
  });

  it("an established player (>= 3 runs) gets personalized scoring, excluding owned items", async () => {
    await recomputeLoadoutPairs(pool);
    const res = await app.inject({ method: "GET", url: `/v1/recommend/loadout?pid=${pidA}` });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.fallback).toBe(false);
    const ids: string[] = body.recommendations.map((r: { itemId: string }) => r.itemId);
    // pidA owns itemX and itemY (picked them up); neither should be recommended back.
    expect(ids).not.toContain(itemX);
    expect(ids).not.toContain(itemY);
    for (const rec of body.recommendations) {
      expect(rec.reason).toBe("pairs_with_owned");
    }
  });
});
