/**
 * M3-7/M4-11. A single static page at `/`, reading a small JSON API, no
 * external CDN dependency -- consistent with docs/04's "runs entirely
 * locally, zero external accounts" posture for the rest of the stack.
 * Charts are hand-drawn inline SVG, not a charting library.
 *
 * docs/04 names six charts. Three have a real source event now: tick p95
 * (`perf.tick`), hit-registration latency (`combat.fire.rttMs`), and
 * director latency/fallback rate (`director.decision`, M4). The other two
 * need event types that do not exist yet -- `economy.txn`/`economy_daily`
 * is M6, matchmaking wait time is M5. Rather than fabricate numbers to
 * satisfy "every chart renders non-empty" as originally written, those
 * render an explicit "not yet emitted" placeholder naming the milestone
 * that adds them. A dashboard that quietly invented data to look finished
 * would be a worse artifact than one that says what it does not know yet.
 *
 * "Cost/run" (M4-11's original wording) is $0 after the one-time hardware
 * cost -- OVERSEER runs on self-hosted Ollama, not a metered API. Shown as
 * that fact, not a fabricated dollar figure. See CLAUDE.md §Model choices.
 */

import type { FastifyInstance } from "fastify";
import { getPool } from "../db.js";

interface TickPoint {
  day: string;
  p95: number;
}

interface HistogramBucket {
  label: string;
  count: number;
}

interface RunAggregate {
  totalRuns: number;
  resolvedRuns: number;
  extractedTotal: number;
  squadTotal: number;
  avgValueExtracted: number | null;
  avgDurationSeconds: number | null;
}

interface PlayerAggregate {
  totalPlayers: number;
  avgRuns: number | null;
  avgExtracts: number | null;
  avgDeaths: number | null;
}

interface ArmStats {
  decisions: number;
  fallbackRate: number | null;
}

interface DirectorAggregate {
  totalDecisions: number;
  avgLatencyMs: number | null;
  p95LatencyMs: number | null;
  fallbackRate: number | null;
  armA: ArmStats;
  armB: ArmStats;
}

export interface DashboardData {
  tickP95: TickPoint[];
  hitLatencyHistogram: HistogramBucket[];
  runs: RunAggregate;
  players: PlayerAggregate;
  director: DirectorAggregate;
  notYetEmitted: Array<{ chart: string; milestone: string; eventType: string }>;
}

const LATENCY_BUCKET_EDGES = [0, 50, 100, 150, 200, 250, 300, 350, 400];

async function fetchDashboardData(app: FastifyInstance): Promise<DashboardData> {
  const pool = getPool(app.config);

  const tickRows = await pool.query<{ day: string; p95: number | null }>(`
    SELECT to_char(date_trunc('day', ts), 'YYYY-MM-DD') AS day,
           avg((payload->>'p95')::real) AS p95
    FROM events
    WHERE type = 'perf.tick'
    GROUP BY 1
    ORDER BY 1
  `);

  const latencyRows = await pool.query<{ rtt_ms: number | null }>(`
    SELECT (payload->>'rttMs')::int AS rtt_ms
    FROM events
    WHERE type = 'combat.fire'
  `);
  const buckets: HistogramBucket[] = [];
  for (let i = 0; i < LATENCY_BUCKET_EDGES.length - 1; i += 1) {
    const lo = LATENCY_BUCKET_EDGES[i] as number;
    const hi = LATENCY_BUCKET_EDGES[i + 1] as number;
    buckets.push({ label: `${lo}-${hi}ms`, count: 0 });
  }
  const overflow: HistogramBucket = { label: `${LATENCY_BUCKET_EDGES.at(-1)}ms+`, count: 0 };
  for (const row of latencyRows.rows) {
    const value = row.rtt_ms;
    if (value === null) continue;
    const bucketIndex = buckets.findIndex((_, i) => {
      const lo = LATENCY_BUCKET_EDGES[i] as number;
      const hi = LATENCY_BUCKET_EDGES[i + 1] as number;
      return value >= lo && value < hi;
    });
    if (bucketIndex === -1) {
      overflow.count += 1;
    } else {
      (buckets[bucketIndex] as HistogramBucket).count += 1;
    }
  }
  buckets.push(overflow);

  const runRow = await pool.query<{
    total_runs: string;
    resolved_runs: string;
    extracted_total: string | null;
    squad_total: string | null;
    // avg() over a numeric column returns NUMERIC, which pg parses as a
    // string (not a number) to avoid silently truncating precision.
    avg_value: string | null;
    avg_duration: string | null;
  }>(`
    SELECT
      count(*)::text AS total_runs,
      count(*) FILTER (WHERE extracted_count IS NOT NULL)::text AS resolved_runs,
      sum(extracted_count)::text AS extracted_total,
      sum(squad_size)::text AS squad_total,
      avg(value_extracted) AS avg_value,
      avg(duration_s) AS avg_duration
    FROM run_summary
  `);
  const r = runRow.rows[0];

  const directorRow = await pool.query<{
    total: string;
    fallbacks: string;
    // avg() returns NUMERIC (string); percentile_cont returns double
    // precision, which pg parses as a real number already -- verified
    // directly rather than assumed, see docs/metrics/m4.md.
    avg_latency: string | null;
    p95_latency: number | null;
    arm_a_total: string;
    arm_a_fallbacks: string;
    arm_b_total: string;
    arm_b_fallbacks: string;
  }>(`
    SELECT
      count(*)::text AS total,
      count(*) FILTER (WHERE (payload->>'fallbackUsed')::boolean)::text AS fallbacks,
      avg((payload->>'latencyMs')::float) AS avg_latency,
      percentile_cont(0.95) WITHIN GROUP (ORDER BY (payload->>'latencyMs')::float) AS p95_latency,
      count(*) FILTER (WHERE payload->>'arm' = 'A')::text AS arm_a_total,
      count(*) FILTER (WHERE payload->>'arm' = 'A' AND (payload->>'fallbackUsed')::boolean)::text AS arm_a_fallbacks,
      count(*) FILTER (WHERE payload->>'arm' = 'B')::text AS arm_b_total,
      count(*) FILTER (WHERE payload->>'arm' = 'B' AND (payload->>'fallbackUsed')::boolean)::text AS arm_b_fallbacks
    FROM events
    WHERE type = 'director.decision'
  `);
  const d = directorRow.rows[0];
  const armStats = (total: string | undefined, fallbacks: string | undefined): ArmStats => {
    const totalN = Number(total ?? 0);
    const fallbacksN = Number(fallbacks ?? 0);
    return { decisions: totalN, fallbackRate: totalN > 0 ? fallbacksN / totalN : null };
  };

  const playerRow = await pool.query<{
    total_players: string;
    avg_runs: string | null;
    avg_extracts: string | null;
    avg_deaths: string | null;
  }>(`
    SELECT count(*)::text AS total_players, avg(runs) AS avg_runs,
           avg(extracts) AS avg_extracts, avg(deaths) AS avg_deaths
    FROM player_stats
  `);
  const p = playerRow.rows[0];

  return {
    tickP95: tickRows.rows.map((row) => ({ day: row.day, p95: row.p95 ?? 0 })),
    hitLatencyHistogram: buckets,
    runs: {
      totalRuns: Number(r?.total_runs ?? 0),
      resolvedRuns: Number(r?.resolved_runs ?? 0),
      extractedTotal: Number(r?.extracted_total ?? 0),
      squadTotal: Number(r?.squad_total ?? 0),
      avgValueExtracted: r?.avg_value === null || r?.avg_value === undefined ? null : Number(r.avg_value),
      avgDurationSeconds: r?.avg_duration === null || r?.avg_duration === undefined ? null : Number(r.avg_duration),
    },
    players: {
      totalPlayers: Number(p?.total_players ?? 0),
      avgRuns: p?.avg_runs === null || p?.avg_runs === undefined ? null : Number(p.avg_runs),
      avgExtracts: p?.avg_extracts === null || p?.avg_extracts === undefined ? null : Number(p.avg_extracts),
      avgDeaths: p?.avg_deaths === null || p?.avg_deaths === undefined ? null : Number(p.avg_deaths),
    },
    director: {
      totalDecisions: Number(d?.total ?? 0),
      avgLatencyMs: d?.avg_latency === null || d?.avg_latency === undefined ? null : Number(d.avg_latency),
      p95LatencyMs: d?.p95_latency ?? null,
      fallbackRate:
        Number(d?.total ?? 0) > 0 ? Number(d?.fallbacks ?? 0) / Number(d?.total ?? 0) : null,
      armA: armStats(d?.arm_a_total, d?.arm_a_fallbacks),
      armB: armStats(d?.arm_b_total, d?.arm_b_fallbacks),
    },
    notYetEmitted: [
      { chart: "Sink/faucet ratio with multiplier overlay", milestone: "M6", eventType: "economy.txn / economy_daily" },
      { chart: "Matchmaking wait-time distribution", milestone: "M5", eventType: "queue.wait (not yet defined)" },
      { chart: "Snapshot bandwidth", milestone: "unscheduled", eventType: "ReplicationService does not emit telemetry yet" },
    ],
  };
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

function renderPage(data: DashboardData): string {
  const extractionRate = data.runs.totalRuns > 0 ? (data.runs.resolvedRuns / data.runs.totalRuns) * 100 : 0;
  const survivalRate = data.runs.squadTotal > 0 ? (data.runs.extractedTotal / data.runs.squadTotal) * 100 : 0;

  const tickMax = Math.max(1, ...data.tickP95.map((p) => p.p95));
  const tickPoints = data.tickP95
    .map((p, i) => {
      const x = data.tickP95.length > 1 ? (i / (data.tickP95.length - 1)) * 760 : 0;
      const y = 140 - (p.p95 / tickMax) * 130;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");

  const histMax = Math.max(1, ...data.hitLatencyHistogram.map((b) => b.count));
  const barWidth = 760 / data.hitLatencyHistogram.length;
  const histBars = data.hitLatencyHistogram
    .map((b, i) => {
      const h = (b.count / histMax) * 130;
      const x = i * barWidth + 4;
      const y = 140 - h;
      return `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${(barWidth - 8).toFixed(1)}" height="${h.toFixed(1)}" fill="#6fa8dc" />
        <text x="${(x + (barWidth - 8) / 2).toFixed(1)}" y="156" font-size="10" fill="#9aa4b2" text-anchor="middle">${escapeHtml(b.label)}</text>`;
    })
    .join("\n");

  const placeholders = data.notYetEmitted
    .map(
      (item) => `<div class="card placeholder">
        <h3>${escapeHtml(item.chart)}</h3>
        <p class="empty">No data yet — needs <code>${escapeHtml(item.eventType)}</code>, landing at <strong>${escapeHtml(item.milestone)}</strong>.</p>
      </div>`,
    )
    .join("\n");

  const fmt = (n: number | null, digits = 0): string => (n === null ? "—" : n.toFixed(digits));
  const fmtPct = (n: number | null): string => (n === null ? "—" : `${(n * 100).toFixed(1)}%`);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>DEEPCACHE telemetry</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px; background: #0f1115; color: #e6e9ef;
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .subtitle { color: #9aa4b2; margin: 0 0 24px; font-size: 13px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; }
  .card {
    background: #171a21; border: 1px solid #262b36; border-radius: 8px;
    padding: 16px 20px;
  }
  .card h3 { margin: 0 0 12px; font-size: 14px; color: #cdd3dc; }
  .stat-row { display: flex; gap: 24px; flex-wrap: wrap; margin-bottom: 8px; }
  .stat { min-width: 100px; }
  .stat .value { font-size: 22px; font-weight: 600; color: #f0f2f5; }
  .stat .label { font-size: 11px; color: #8891a0; text-transform: uppercase; letter-spacing: 0.04em; }
  .empty { color: #7d8695; font-style: italic; margin: 0; }
  .placeholder { opacity: 0.7; }
  code { background: #1f232c; padding: 1px 5px; border-radius: 3px; font-size: 12px; }
  svg { display: block; width: 100%; height: auto; }
  .footer { margin-top: 24px; color: #666e7c; font-size: 12px; }
</style>
</head>
<body>
  <h1>DEEPCACHE — telemetry</h1>
  <p class="subtitle">Reading run_summary, player_stats and events directly. No external service, no CDN.</p>

  <div class="grid">
    <div class="card">
      <h3>Runs</h3>
      <div class="stat-row">
        <div class="stat"><div class="value">${data.runs.totalRuns}</div><div class="label">total</div></div>
        <div class="stat"><div class="value">${fmt(extractionRate, 1)}%</div><div class="label">resolved</div></div>
        <div class="stat"><div class="value">${fmt(survivalRate, 1)}%</div><div class="label">player survival</div></div>
        <div class="stat"><div class="value">${fmt(data.runs.avgValueExtracted, 0)}</div><div class="label">avg value / extract</div></div>
        <div class="stat"><div class="value">${fmt(data.runs.avgDurationSeconds, 0)}s</div><div class="label">avg duration</div></div>
      </div>
    </div>

    <div class="card">
      <h3>Players</h3>
      <div class="stat-row">
        <div class="stat"><div class="value">${data.players.totalPlayers}</div><div class="label">seen</div></div>
        <div class="stat"><div class="value">${fmt(data.players.avgRuns, 1)}</div><div class="label">avg runs</div></div>
        <div class="stat"><div class="value">${fmt(data.players.avgExtracts, 1)}</div><div class="label">avg extracts</div></div>
        <div class="stat"><div class="value">${fmt(data.players.avgDeaths, 1)}</div><div class="label">avg deaths</div></div>
      </div>
    </div>

    <div class="card">
      <h3>Tick time p95 over time</h3>
      ${
        data.tickP95.length === 0
          ? '<p class="empty">No perf.tick events yet.</p>'
          : `<svg viewBox="0 0 780 160"><polyline points="${tickPoints}" fill="none" stroke="#7ee787" stroke-width="2" /></svg>
             <p class="empty">${data.tickP95.length} day(s), max ${tickMax.toFixed(2)}ms</p>`
      }
    </div>

    <div class="card">
      <h3>Hit-registration latency (combat.fire rttMs)</h3>
      ${
        data.hitLatencyHistogram.every((b) => b.count === 0)
          ? '<p class="empty">No combat.fire events yet.</p>'
          : `<svg viewBox="0 0 780 170">${histBars}</svg>`
      }
    </div>

    <div class="card">
      <h3>Director (OVERSEER) — latency, fallback rate, A/B</h3>
      ${
        data.director.totalDecisions === 0
          ? '<p class="empty">No director.decision events yet.</p>'
          : `<div class="stat-row">
              <div class="stat"><div class="value">${data.director.totalDecisions}</div><div class="label">decisions</div></div>
              <div class="stat"><div class="value">${fmt(data.director.avgLatencyMs, 0)}ms</div><div class="label">avg latency</div></div>
              <div class="stat"><div class="value">${fmt(data.director.p95LatencyMs, 0)}ms</div><div class="label">p95 latency</div></div>
              <div class="stat"><div class="value">${fmtPct(data.director.fallbackRate)}</div><div class="label">fallback rate</div></div>
              <div class="stat"><div class="value">$0</div><div class="label">cost / run (self-hosted)</div></div>
            </div>
            <p class="empty">A/B — arm A (FSM only): ${data.director.armA.decisions} decisions.
              Arm B (FSM + OVERSEER): ${data.director.armB.decisions} decisions,
              ${fmtPct(data.director.armB.fallbackRate)} fallback.</p>`
      }
    </div>

    ${placeholders}
  </div>

  <p class="footer">Generated server-side on each request from live rollup tables. Refresh to update.</p>
</body>
</html>`;
}

export async function registerDashboardRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/dashboard/data", async () => fetchDashboardData(app));

  app.get("/", async (_request, reply) => {
    const data = await fetchDashboardData(app);
    return reply.header("content-type", "text/html; charset=utf-8").send(renderPage(data));
  });
}
