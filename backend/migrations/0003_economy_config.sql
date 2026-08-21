-- +up
-- M6-5. Versioned economy config, served by GET /v1/config and produced by
-- the nightly controller worker.
--
-- Append-only rather than a single mutable row. The version guard on the game
-- side ("ignore anything not newer than what I already have") is only
-- meaningful if versions are monotonic and history is inspectable: when a bad
-- multiplier ships, the question asked is "what did servers actually receive
-- and when", and an UPDATE-in-place table cannot answer it. It also makes a
-- rollback an INSERT of a corrected row rather than a destructive edit.
CREATE TABLE economy_config (
  version     BIGINT PRIMARY KEY,
  multiplier  REAL NOT NULL,
  -- Why this version exists: "controller" for a nightly adjustment,
  -- "seed" for the initial row, "manual" for a human override.
  source      TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Version 0 is reserved: config/Economy.luau ships version 0 as the
-- compiled-in default, and remote config must strictly exceed it. Seeding at
-- 1 means a freshly migrated database is already newer than the defaults, so
-- the pull path is exercised from the first boot rather than silently doing
-- nothing until the first nightly run.
INSERT INTO economy_config (version, multiplier, source) VALUES (1, 1.0, 'seed');

-- The controller's integral and clamp streak have to survive process
-- restarts, or every restart silently resets the accumulated error and the
-- loop starts over from a place it already learned was wrong.
ALTER TABLE economy_daily ADD COLUMN integral REAL NOT NULL DEFAULT 0;
ALTER TABLE economy_daily ADD COLUMN clamped_days INTEGER NOT NULL DEFAULT 0;
ALTER TABLE economy_daily ADD COLUMN applied BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE economy_daily ADD COLUMN reason TEXT NOT NULL DEFAULT '';
ALTER TABLE economy_daily ADD COLUMN run_count INTEGER NOT NULL DEFAULT 0;

-- +down
ALTER TABLE economy_daily DROP COLUMN run_count;
ALTER TABLE economy_daily DROP COLUMN reason;
ALTER TABLE economy_daily DROP COLUMN applied;
ALTER TABLE economy_daily DROP COLUMN clamped_days;
ALTER TABLE economy_daily DROP COLUMN integral;
DROP TABLE economy_config;
