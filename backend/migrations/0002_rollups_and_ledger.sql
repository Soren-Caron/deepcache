-- +up
-- Rollups, rebuilt by the M3-5 worker. Safe to drop and regenerate from
-- events -- every column here is a function of the append-only events table,
-- never a source of truth on its own.
CREATE TABLE run_summary (
  run_id TEXT PRIMARY KEY, started_at TIMESTAMPTZ, duration_s REAL,
  squad_size INT, extracted_count INT, death_count INT,
  value_extracted BIGINT, director_calls INT, director_fallbacks INT,
  tick_p95_ms REAL, snapshot_bytes_per_s REAL
);

CREATE TABLE player_stats (
  pid TEXT PRIMARY KEY, runs INT, extracts INT, deaths INT,
  avg_value REAL, rating REAL, rd REAL, last_seen TIMESTAMPTZ
);

-- Co-occurrence, for the M5 recommender. No loadout-selection event exists
-- yet in the catalogue -- players don't choose a loadout, every weapon is
-- available every run -- so the M3-5 worker leaves this empty rather than
-- inventing pairs from nothing. The table exists now because M3-4's scope is
-- "all tables in docs/04 §Schema", and creating it early means M5/M6 land
-- without a migration of their own.
CREATE TABLE loadout_pairs (
  item_a TEXT, item_b TEXT, cooccur INT, PRIMARY KEY (item_a, item_b)
);

CREATE TABLE economy_daily (
  day DATE PRIMARY KEY, faucet BIGINT, sink BIGINT, ratio REAL,
  multiplier REAL, applied_at TIMESTAMPTZ
);

-- Authoritative currency record (M6). idem_key UNIQUE is the entire
-- duplicate-grant defense: a retried payout is a constraint violation,
-- caught and ignored, the same pattern events uses for (run_id, server_id,
-- seq).
CREATE TABLE ledger (
  id BIGSERIAL PRIMARY KEY, pid TEXT NOT NULL, delta BIGINT NOT NULL,
  balance_after BIGINT NOT NULL, reason TEXT NOT NULL, run_id TEXT,
  idem_key TEXT UNIQUE NOT NULL, ts TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ledger_pid_ts_idx ON ledger (pid, ts DESC);

-- +down
DROP TABLE ledger;
DROP TABLE economy_daily;
DROP TABLE loadout_pairs;
DROP TABLE player_stats;
DROP TABLE run_summary;
