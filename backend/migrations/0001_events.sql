-- +up
-- Append-only. Never updated, never deleted in normal operation.
--
-- The unique index on (run_id, server_id, seq) is a divergence from the
-- schema as first drafted in docs/04-TELEMETRY-BACKEND.md, which had no
-- uniqueness constraint at all. M3-3's acceptance criteria require that a
-- replayed batch — the game server retrying a POST it never got an ack for —
-- inserts zero new rows. Without this constraint that retry would double
-- every event in the batch, and a game server has no other way to know
-- whether its previous attempt actually landed.
CREATE TABLE events (
  id          BIGSERIAL PRIMARY KEY,
  ts          TIMESTAMPTZ  NOT NULL,
  run_id      TEXT         NOT NULL,
  server_id   TEXT         NOT NULL,
  pid         TEXT,
  type        TEXT         NOT NULL,
  seq         BIGINT       NOT NULL,
  payload     JSONB        NOT NULL,
  ingested_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX events_dedupe_key ON events (run_id, server_id, seq);
CREATE INDEX events_run_id_idx ON events (run_id);
CREATE INDEX events_type_ts_idx ON events (type, ts DESC);
CREATE INDEX events_pid_ts_idx ON events (pid, ts DESC) WHERE pid IS NOT NULL;

-- +down
DROP TABLE events;
