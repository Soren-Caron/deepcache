-- +up
-- M6-7. The game's cached per-player balance, as last reported by a server.
--
-- This is the DataStore-side number in docs/07's "fast cache in-game,
-- authoritative log in Postgres, nightly reconciliation" split, mirrored here
-- so the reconciliation job has something to compare the ledger against
-- without reaching into Roblox. The ledger stays authoritative; nothing reads
-- this to decide what a player can afford.
CREATE TABLE balance_cache (
  pid            TEXT PRIMARY KEY,
  cached_balance BIGINT NOT NULL,
  -- Which server last wrote it, and when. A drift investigation starts with
  -- "who reported this and how stale is it".
  server_id      TEXT,
  reported_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +down
DROP TABLE balance_cache;
