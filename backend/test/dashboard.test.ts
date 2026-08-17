import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { getPool } from "../src/db.js";
import type { DashboardData } from "../src/routes/dashboard.js";

/**
 * The dashboard's aggregate queries (runs, players, tick p95) read the
 * whole `events`/`run_summary`/`player_stats` tables with no run_id scope,
 * by design -- a real dashboard aggregates across everything. That means
 * this suite can't assert exact totals without depending on what other
 * test files (rollup.test.ts, ingest.test.ts) happen to have inserted, so
 * it asserts shape everywhere and exact values only for rows it inserts
 * itself with markers no other suite touches (combat.fire, a far-future
 * perf.tick day).
 */

let app: FastifyInstance;
const pool = getPool(loadConfig());

const marker = Date.now();
const runId = `dashboard-test-${marker}`;
// Far beyond any other suite's fixed epoch timestamps, so this lands on a
// day nothing else contributes to.
const tickDayEpoch = 1893456000 + marker / 1000; // ~2030, offset to stay unique across reruns
const tickDay = new Date(tickDayEpoch * 1000).toISOString().slice(0, 10);

async function insertEvent(
  type: string,
  ts: number,
  payload: Record<string, unknown>,
  seq: number,
): Promise<void> {
  await pool.query(
    `INSERT INTO events (ts, run_id, server_id, pid, type, seq, payload)
     VALUES (to_timestamp($1), $2, $3, NULL, $4, $5, $6::jsonb)`,
    [ts, runId, "dashboard-test-server", type, seq, JSON.stringify(payload)],
  );
}

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  app = await buildApp({ config: loadConfig(), logger: false });
  await app.ready();

  await insertEvent("perf.tick", tickDayEpoch, { p50: 5, p95: 9.99, p99: 15 }, 1);
  // One event per histogram bucket edge, chosen so bucketing math is exercised
  // end-to-end rather than just unit-tested against the bucket array in isolation.
  await insertEvent("combat.fire", tickDayEpoch, { rttMs: 37 }, 2); // 0-50ms
  await insertEvent("combat.fire", tickDayEpoch, { rttMs: 275 }, 3); // 250-300ms
  await insertEvent("combat.fire", tickDayEpoch, { rttMs: 999 }, 4); // overflow (400ms+)
});

afterAll(async () => {
  await app.close();
});

describe("GET /v1/dashboard/data", () => {
  it("returns the documented shape", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/dashboard/data" });
    expect(res.statusCode).toBe(200);
    const data = res.json() as DashboardData;

    expect(Array.isArray(data.tickP95)).toBe(true);
    expect(Array.isArray(data.hitLatencyHistogram)).toBe(true);
    expect(typeof data.runs.totalRuns).toBe("number");
    expect(typeof data.players.totalPlayers).toBe("number");
    expect(Array.isArray(data.notYetEmitted)).toBe(true);
  });

  it("names the exact four charts with no real data source yet", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/dashboard/data" });
    const data = res.json() as DashboardData;

    expect(data.notYetEmitted).toEqual([
      { chart: "Director latency and fallback rate", milestone: "M4", eventType: "director.decision" },
      {
        chart: "Sink/faucet ratio with multiplier overlay",
        milestone: "M6",
        eventType: "economy.txn / economy_daily",
      },
      {
        chart: "Matchmaking wait-time distribution",
        milestone: "M5",
        eventType: "queue.wait (not yet defined)",
      },
      {
        chart: "Snapshot bandwidth",
        milestone: "unscheduled",
        eventType: "ReplicationService does not emit telemetry yet",
      },
    ]);
  });

  it("aggregates perf.tick into a day-bucketed p95 series", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/dashboard/data" });
    const data = res.json() as DashboardData;

    const point = data.tickP95.find((p) => p.day === tickDay);
    expect(point).toBeDefined();
    expect(point?.p95).toBeCloseTo(9.99, 5);
  });

  it("buckets combat.fire rttMs into the documented 50ms histogram, including overflow", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/dashboard/data" });
    const data = res.json() as DashboardData;

    const byLabel = new Map(data.hitLatencyHistogram.map((b) => [b.label, b.count]));
    expect(byLabel.get("0-50ms")).toBe(1);
    expect(byLabel.get("250-300ms")).toBe(1);
    expect(byLabel.get("400ms+")).toBe(1);
    // Buckets this suite put nothing in stay at zero rather than undefined.
    expect(byLabel.get("50-100ms")).toBe(0);
  });
});

describe("GET /", () => {
  it("renders self-contained HTML with no external dependency", async () => {
    const res = await app.inject({ method: "GET", url: "/" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toContain("text/html");
    expect(res.body).toContain("DEEPCACHE");
    expect(res.body).not.toMatch(/https?:\/\/(?!.*schema)/i);
  });

  it("shows named placeholders instead of fabricated numbers for unimplemented charts", async () => {
    const res = await app.inject({ method: "GET", url: "/" });
    expect(res.body).toContain("Director latency and fallback rate");
    expect(res.body).toContain("director.decision");
    expect(res.body).toContain("No data yet");
  });

  it("renders the real tick and latency charts as inline SVG", async () => {
    const res = await app.inject({ method: "GET", url: "/" });
    expect(res.body).toContain("<svg");
    expect(res.body).toContain("polyline");
  });
});
