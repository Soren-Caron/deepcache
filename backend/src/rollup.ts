/**
 * M3-5. Materializes run_summary and player_stats from the append-only
 * events table.
 *
 * docs/04: "Idempotent: keyed on run_id, recomputes rather than increments,
 * so a crashed run is self-healing." That is a specific design choice, not
 * an implementation detail: every column here is a full re-aggregation over
 * `events` for that key, upserted with `ON CONFLICT DO UPDATE`, never a
 * delta applied to the previous row. A worker that incremented instead would
 * double-count on any retry after a partial failure; this one produces the
 * same row whether it runs once or a hundred times over unchanged input.
 *
 * `rating`/`rd` are the one exception, and deliberately so: they are seeded
 * to the standard Glicko starting values (1500 / 350) only for a
 * never-before-seen pid, and never touched on conflict. M5's rating engine
 * owns those two columns once it exists; a "recompute everything" rollup
 * that also reset a player's rating every 60 seconds would erase real
 * rating history the moment it landed.
 */

import type pg from "pg";

export interface RollupResult {
  readonly runsUpserted: number;
  readonly playersUpserted: number;
}

const RUN_SUMMARY_SQL = `
  INSERT INTO run_summary (
    run_id, started_at, duration_s, squad_size, extracted_count,
    death_count, value_extracted, director_calls, director_fallbacks,
    tick_p95_ms, snapshot_bytes_per_s
  )
  SELECT
    run_id,
    MIN(ts) FILTER (WHERE type = 'run.start')                                   AS started_at,
    MAX((payload->>'durationSeconds')::real) FILTER (WHERE type = 'run.end')    AS duration_s,
    MAX((payload->>'squadSize')::int) FILTER (WHERE type = 'run.start')         AS squad_size,
    MAX((payload->>'extracted')::int) FILTER (WHERE type = 'run.end')          AS extracted_count,
    MAX((payload->>'deaths')::int) FILTER (WHERE type = 'run.end')             AS death_count,
    MAX((payload->>'valueExtracted')::bigint) FILTER (WHERE type = 'run.end') AS value_extracted,
    COUNT(*) FILTER (WHERE type = 'director.decision')                          AS director_calls,
    COUNT(*) FILTER (
      WHERE type = 'director.decision' AND (payload->>'fallbackUsed')::boolean
    )                                                                           AS director_fallbacks,
    AVG((payload->>'p95')::real) FILTER (WHERE type = 'perf.tick')             AS tick_p95_ms,
    -- No source event carries bandwidth yet -- ReplicationService does not
    -- emit telemetry as of M3. NULL, not 0: a run with unmeasured bandwidth
    -- is not the same claim as a run that used none.
    NULL::real                                                                 AS snapshot_bytes_per_s
  FROM events
  GROUP BY run_id
  ON CONFLICT (run_id) DO UPDATE SET
    started_at           = EXCLUDED.started_at,
    duration_s           = EXCLUDED.duration_s,
    squad_size           = EXCLUDED.squad_size,
    extracted_count      = EXCLUDED.extracted_count,
    death_count           = EXCLUDED.death_count,
    value_extracted       = EXCLUDED.value_extracted,
    director_calls        = EXCLUDED.director_calls,
    director_fallbacks    = EXCLUDED.director_fallbacks,
    tick_p95_ms           = EXCLUDED.tick_p95_ms,
    snapshot_bytes_per_s  = EXCLUDED.snapshot_bytes_per_s
`;

const PLAYER_STATS_SQL = `
  INSERT INTO player_stats (pid, runs, extracts, deaths, avg_value, rating, rd, last_seen)
  SELECT
    pid,
    COUNT(DISTINCT run_id)                                                  AS runs,
    COUNT(*) FILTER (WHERE type = 'extract.success')                       AS extracts,
    COUNT(*) FILTER (WHERE type = 'player.death')                          AS deaths,
    AVG((payload->>'carriedValue')::real) FILTER (WHERE type = 'extract.success') AS avg_value,
    1500::real AS rating, -- Glicko default. Only used for a brand-new pid;
    350::real  AS rd,     -- the UPDATE branch below never touches either.
    MAX(ts) AS last_seen
  FROM events
  WHERE pid IS NOT NULL
  GROUP BY pid
  ON CONFLICT (pid) DO UPDATE SET
    runs      = EXCLUDED.runs,
    extracts  = EXCLUDED.extracts,
    deaths    = EXCLUDED.deaths,
    avg_value = EXCLUDED.avg_value,
    last_seen = EXCLUDED.last_seen
`;

export async function runRollup(pool: pg.Pool): Promise<RollupResult> {
  const client = await pool.connect();
  try {
    // One transaction: a dashboard read landing between the two statements
    // must never see a run_summary row without its player_stats siblings
    // reflecting the same snapshot of events.
    await client.query("BEGIN");
    const runs = await client.query(RUN_SUMMARY_SQL);
    const players = await client.query(PLAYER_STATS_SQL);
    await client.query("COMMIT");
    return { runsUpserted: runs.rowCount ?? 0, playersUpserted: players.rowCount ?? 0 };
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Starts the interval loop docs/04 describes ("every 60s, inside the same
 * process"). Not called from tests or from `buildApp` -- a timer that
 * outlives the test it was started in is exactly the kind of thing that
 * makes a test suite hang on exit for a reason nobody can see in the
 * failure output.
 */
export function startRollupWorker(pool: pg.Pool, intervalMs = 60_000): NodeJS.Timeout {
  return setInterval(() => {
    runRollup(pool).catch((err: unknown) => {
      console.error("[rollup] failed:", err);
    });
  }, intervalMs);
}
