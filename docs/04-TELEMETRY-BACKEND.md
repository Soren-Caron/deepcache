# 04 — Telemetry & Backend

Built second, right after netcode, because matchmaking, the economy controller, and the recommender all read from it. It is the project's data plane.

## The binding constraint

**`HttpService` allows 500 requests/minute per game server.** That's 8.3/s shared across telemetry, director calls, economy config, and matchmaking. A per-event HTTP call is not an inefficiency — it is an outage. Everything batches.

Budget allocation per server:

| Consumer | Requests/min | Notes |
|---|---|---|
| Telemetry flush | 12 | every 5 s |
| Director tick | 3 | every 20 s |
| Economy config poll | 0.1 | every 10 min |
| Matchmaking (lobby only) | 6 | lobby servers only, not run servers |
| **Total** | **~21** | 4% of budget — deliberately enormous headroom for retries and bursts |

## Event envelope

Every event, without exception:

```jsonc
{
  "v": 1,
  "ts": 1755302400.123,      // server os.time() + fractional, UTC
  "runId": "01HX...",        // ULID, generated at run start
  "serverId": "job-abc123",  // game.JobId
  "placeId": 1234567890,
  "pid": "a3f9...",          // HMAC-SHA256(userId, PLAYER_SALT) — pseudonymous, stable, not reversible
  "type": "combat.hit",
  "seq": 4821,               // monotonic per server; gaps mean drops
  "p": { }                   // type-specific payload
}
```

`pid` is hashed on the game server with a salt held only in the backend env. Analytics work across runs; the raw user ID never leaves Roblox. This is a deliberate privacy posture and it's worth saying out loud in an interview.

`seq` is how loss is detected: the rollup worker flags any run whose max `seq` exceeds its event count.

## Event catalogue

| Type | Payload | Feeds |
|---|---|---|
| `run.start` | seed, zone layout hash, squad size, ratings | matchmaking eval, repro |
| `run.end` | outcome, duration, extracted value, deaths | rating, economy |
| `player.spawn` / `player.death` | position, cause, killer kind, carried weight | balance, director eval |
| `combat.fire` | weapon, hit bool, rttMs, rewindMs, rejectReason | **netcode metrics** |
| `combat.hit` | target kind, damage, distance, headshot | balance |
| `loot.pickup` / `loot.drop` | itemId, rarity, weight, totalWeight | economy, weight tuning |
| `extract.attempt` / `extract.success` | padId, tSeconds, carriedValue | economy faucet |
| `objective.issue` / `objective.complete` | objectiveId, source (`fsm`\|`llm`), params | **director eval** |
| `director.decision` | proposal, clampedTo, latencyMs, fallbackUsed, tokensIn/Out | **director eval, cost** |
| `economy.txn` | delta, reason, balanceAfter, idempotencyKey | ledger reconciliation |
| `market.order` / `market.fill` | itemId, price, qty, feePaid | market health |
| `perf.tick` | p50/p95 tick ms, entityCount, snapshotBytes | **netcode metrics** |
| `anticheat.flag` | rule, score, action | security |

`director.decision` and `perf.tick` are the two that make the whole project quantifiable. They get first-class treatment.

## Client-side buffering (Roblox)

`TelemetryService`:

```
emit(type, payload) → append to ring buffer (cap 2000)
flush when: 200 events buffered, OR 5 s elapsed, OR run ends (forced flush)
```

- **Serialize** as newline-delimited JSON, gzip via `HttpService` compression if available, POST to `/v1/ingest`.
- **Retry:** exponential backoff 1 s → 2 s → 4 s → 8 s, max 4 attempts. On final failure, drop the batch and emit a local `telemetry.dropped` counter that rides the *next* successful batch — so loss is always visible in the data.
- **Ring buffer overflow** drops oldest and increments the same counter. Never block gameplay to preserve telemetry.
- **Run end** forces a synchronous-ish flush with a 3-second grace before the server shuts down (`game:BindToClose`).

Authentication: HMAC-SHA256 over `timestamp + nonce + body` with a shared secret in a server-only `ModuleScript`. Plus `placeId` allowlist and per-`serverId` rate limiting at the edge. Roblox has no per-server identity primitive, so this is defense-in-depth rather than real auth — the backend treats all game-server input as semi-trusted and validates ranges on ingest.

## Backend

**Node 24 + TypeScript + Fastify + Postgres 16.** Chosen for one reason above all: it runs entirely locally under Docker, which means the backend, the economy, and the recommender can all be built and tested with zero external accounts and zero deploys. Studio can reach `127.0.0.1`, so the full loop closes on one machine.

```bash
docker compose up -d          # postgres:16 on 5432
npm --prefix backend run dev  # fastify on 8787, watch mode
npm --prefix backend test     # vitest
```

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/ingest` | NDJSON batch. Validates envelope, rejects the batch on schema failure with per-line detail. Returns `{accepted, rejected}`. |
| `POST` | `/v1/director/tick` | LLM proxy. See [05](05-OVERSEER-DIRECTOR.md). |
| `POST` | `/v1/director/brief` | Pre-run briefing (Opus, higher latency tolerance). |
| `GET` | `/v1/config` | Economy tunables, versioned. |
| `GET` | `/v1/recommend/loadout?pid=` | Top-3 loadout recommendation + reason codes. |
| `GET` | `/v1/rating?pid=` | Current skill rating (matchmaking read path). |
| `POST` | `/v1/rating/batch` | Post-run rating updates. |
| `GET` | `/healthz`, `/metrics` | Liveness + Prometheus-format counters. |

Ingest is the only high-volume path. It writes and returns; all analysis is asynchronous.

### Schema

```sql
-- Append-only. Never updated, never deleted in normal operation.
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
CREATE UNIQUE INDEX ON events (run_id, server_id, seq);
CREATE INDEX ON events (run_id);
CREATE INDEX ON events (type, ts DESC);
CREATE INDEX ON events (pid, ts DESC) WHERE pid IS NOT NULL;
```

**As built (M3-3):** the unique index above was not in the original draft of this
schema. `/v1/ingest`'s acceptance criterion is that a replayed batch — the game
server retrying a POST it never got an ack for — inserts zero new rows, and
that is a database guarantee, not application logic: the insert is a single
bulk `INSERT ... ON CONFLICT (run_id, server_id, seq) DO NOTHING`, so a replay
racing a fresh batch from the same server cannot double-insert between a
SELECT and an INSERT the way a check-then-insert in application code could.
The response distinguishes three outcomes rather than the two sketched above —
`{ accepted, rejected, duplicates }`. A replayed event is neither new data nor
malformed input; folding it into either bucket would make either dedupe or
data loss invisible in the response.

```sql
-- Rollups, rebuilt by workers. Safe to drop and regenerate from events.
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

CREATE TABLE loadout_pairs (             -- co-occurrence, for the recommender
  item_a TEXT, item_b TEXT, cooccur INT, PRIMARY KEY (item_a, item_b)
);

CREATE TABLE economy_daily (
  day DATE PRIMARY KEY, faucet BIGINT, sink BIGINT, ratio REAL,
  multiplier REAL, applied_at TIMESTAMPTZ
);

CREATE TABLE ledger (                    -- authoritative currency record
  id BIGSERIAL PRIMARY KEY, pid TEXT NOT NULL, delta BIGINT NOT NULL,
  balance_after BIGINT NOT NULL, reason TEXT NOT NULL, run_id TEXT,
  idem_key TEXT UNIQUE NOT NULL, ts TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`idem_key UNIQUE` is the entire duplicate-grant defense. A retried payout is a constraint violation, caught and ignored.

### Workers

Run on intervals inside the same process (a real deployment would separate them; saying so is part of the postmortem):

- **`rollup`** — every 60 s, materializes `run_summary` and `player_stats` from new events. Idempotent: keyed on `run_id`, recomputes rather than increments, so a crashed run is self-healing.
- **`economy`** — nightly, computes sink/faucet ratio, runs the PI controller, writes `economy_daily`, publishes a new config version. See [07](07-ECONOMY.md).
- **`recommend`** — nightly, rebuilds `loadout_pairs` and the item-item similarity matrix. See [06](06-MATCHMAKING-DISCOVERY.md).

### Dashboard

A single static page served at `/` reading `/metrics` and a few JSON endpoints. Charts: tick time p95 over time, snapshot bandwidth, hit-registration latency histogram, director latency and fallback rate, sink/faucet ratio with the multiplier overlaid, matchmaking wait-time distribution.

This is not a nice-to-have. It is the artifact that turns "I built systems" into "here is what they did." Build it at M3, not at the end.

## Failure behavior, stated explicitly

| Failure | Behavior |
|---|---|
| Backend down | Game continues fully. Telemetry buffers then drops with a counter. Director falls back to FSM. Economy uses compiled-in defaults. **No gameplay path blocks on the backend.** |
| Postgres down | Ingest returns 503; game servers retry then drop. No data corruption — events are append-only. |
| Ingest schema rejection | Per-line rejection reported; valid lines in the batch still commit. |
| Duplicate batch (retry after a timeout that actually succeeded) | `(run_id, server_id, seq)` dedupe on insert. Idempotent by construction. |
| Clock skew between game server and backend | `ts` is trusted for ordering *within* a run; `ingested_at` is authoritative for cross-run windows. |

## Tests

- Envelope validator: valid, missing field, wrong type, out-of-range `ts`, oversized payload.
- Ingest: partial-batch rejection, duplicate `seq` dedupe, 10k-line batch under 500 ms.
- Rollup idempotency: run the worker three times on the same events, assert identical output.
- Ledger uniqueness: concurrent identical `idem_key` inserts → exactly one row.
- End-to-end: `sim/` generates 500 runs → ingest → rollups populate → dashboard renders. This one is the M3 exit criterion.
