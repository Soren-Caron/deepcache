# 10 — Roadmap

Eight milestones. Each ends in something demonstrable, and each has exit criteria that are checked, not felt.

**The ordering principle:** netcode first because nothing works without it, telemetry second because three systems consume it, then the consumers in parallel, presentation last. **M4 is the "shippable" line** — if everything after it were cut, what exists is a complete, playable, instrumented game rather than five half-systems.

The percentages are rough effort share, not a schedule. Calendar time depends entirely on hours available per week.

---

## M0 — Skeleton (5%)

Nothing playable. Everything after this is faster because of it.

**Build:** Rojo project, rokit toolchain pinned, `git init`, folder tree from [02](02-ARCHITECTURE.md), Lune test runner, empty pure-core modules with signatures and failing stub tests, `docker-compose.yml` with Postgres, Fastify skeleton with `/healthz`, CI workflow.

**Exit:**
- `lune run tests` runs and reports (stubs may fail, but the runner works).
- `rojo build` produces a place file.
- `docker compose up -d && curl localhost:8787/healthz` → 200.
- CI green on all three jobs.
- A trivial script synced from disk appears in Studio.

---

## M1 — Netcode core (20%)

The hardest milestone, done first, on purpose.

**Build:** Fixed 20 Hz `TickService`. Entity system with non-Humanoid entities in pure Luau. `Snapshot` encode/decode with the binary format and the 900-byte assert. Delta compression + keyframes. Interest management. Client `Interpolator` with adaptive render delay. `History` ring buffer. Fire request → lag-compensated validation → hit event. Client prediction + reconciliation. `MovementGuard`. One weapon (Sidearm), one enemy (Skitter), a flat test arena.

**Exit:**
- All `core/net/*` and `core/sim/*` tests green.
- 40 entities, tick p95 < 12 ms (measured by `TickBench` in Studio, output quoted).
- Snapshot bandwidth < 6 KB/s per client at 3 players.
- Two clients in a Studio play session, both see the same entities moving smoothly.
- Hit registration works at 50 / 150 / 300 ms injected latency; a moving target can be hit at 300 ms.
- Mispredict rate < 2% over a 5-minute session.

**Demo:** two windows, injected lag, shooting a moving Skitter, with the latency HUD visible.

---

## M2 — Playable loop (15%)

**Build:** Modular level assembly from ~12 room modules (full 24 later). Full enemy roster. All four weapons. Loot spawning, weight, pickup/drop. Extraction pads with timers. Run lifecycle and the 12-minute clock. Death and loss of carried loot. **Deterministic Director FSM** — no LLM yet. Basic HUD.

**Exit:**
- A full run is playable start to finish: drop → loot → fight → extract.
- Level assembly guarantees all three pads reachable across 1,000 seeded generations (asserted in a pure-core test).
- FSM produces a legible pacing curve — measurable lulls and spikes, not a flat line.
- 3-player Studio session completes a run with no errors.

**This is where the game becomes a game.** Playtest it with real people here, informally, before continuing.

---

## M3 — Telemetry pipeline + dashboard (12%)

**Build:** `TelemetryService` with ring buffer, batching, retry, drop counters. Backend `/v1/ingest` with HMAC auth and validation. Postgres schema + migrations. Rollup worker. **`sim/` run simulator.** Dashboard page.

**Exit:**
- A live run's events land in Postgres end to end.
- `sim/` generates 2,000 runs across 30 simulated days; rollups populate; dashboard renders real charts.
- Rollup idempotency verified — three runs of the worker produce identical output.
- Ingest handles a 10k-line batch in < 500 ms.
- Backend killed mid-run → game continues, drop counter increments, recovers on restart.

**Demo:** the dashboard, populated. This is the artifact that makes everything downstream measurable.

---

## M4 — OVERSEER (15%) ← **shippable line**

**Build:** `/v1/director/tick` proxy. System prompt v1 (≥4200 tokens for cache eligibility). Structured output schema, mirrored to Luau. `Clamp` with exhaustive tests. Fallback ladder including balanced-JSON extraction. Circuit breaker. `TextService` filtering with canned-bark fallback. Comms HUD panel. Threat-tier → lighting hook. Objective system. A/B assignment by run.

**Exit:**
- Director tick round-trips in < 1200 ms p95; the 20 Hz loop never stalls (asserted by tick timing during director calls).
- `fallbackUsed` rate < 3% over 200 runs.
- Every malformed-input test case in `Clamp` returns a valid decision.
- Backend unplugged mid-run → FSM takes over, gameplay unaffected, breaker opens and recovers.
- No unfiltered model text can reach a player — verified by forcing filter failure.
- Cost per run measured from `director.decision` token counts and within 2× the $0.08 estimate.

**Stop here if time runs out.** What exists is a complete co-op extraction shooter with real netcode, a full telemetry pipeline, an LLM game master with production-grade safety, and a dashboard proving it works. That is a strong project on its own.

---

## M5 — Matchmaking & discovery (12%)

**Build:** Lobby place. MemoryStore queue with sorted maps. Coordinator election via lease. Squad formation, `ReserveServer`, `TeleportAsync`. Rating computation backend-side. Widening schedule and backfill. Recommender worker, `/v1/recommend/loadout`, offline eval script, lobby UI.

**Exit:**
- Players queue in the lobby and land in a reserved run server together.
- Coordinator killed mid-operation → another takes over within 12 s, zero double-matches.
- `sim/matchmaking` reports wait-time percentiles across populations 5–500.
- Recommender eval runs and reports recall@3 against the popularity baseline — **whatever the result**.

---

## M6 — Economy (12%)

**Build:** Ledger with idempotency, Postgres + DataStore write-behind, reconciliation job. Faucets and sinks. Insurance. PI controller + nightly worker + config fan-out with schema validation and version guard. Market: escrow, order book, matching engine, price bands, abuse caps. Market UI. **Backend deployed** (Fly.io) so production servers can reach it.

**Exit:**
- Market fuzz test: 100k random orders, zero currency or items created or destroyed.
- Ledger reconciliation over 2,000 simulated runs: zero mismatches.
- Controller converges from a seeded 30% imbalance within 14 simulated days without oscillating.
- Config fan-out works live: change the multiplier in the DB, servers pick it up within 10 minutes, out-of-range values rejected wholesale.
- Deployed backend reachable from a published place.

---

## M7 — Presentation, polish, and the writeup (9%)

**Build:** Procedural locomotion + IK for all legged entities. Ragdoll pooling. Zone lighting presets + threat-tier modulation. Inverted-hull outlines. `EditableImage` ramps within the 8-instance budget. Audio pass. Full 24 room modules. **Postmortem document. Demo video. Dashboard cleanup.**

**Exit:**
- Client frame budget met at 40 entities (profiled, numbers recorded).
- No visible popping at LOD transitions.
- `EditableImage` allocation never exceeds 6 of 8 in normal play.
- Real playtest, 4+ people, full session, feedback recorded.
- Postmortem written, including what didn't work.
- 3–5 minute demo video: one run, with the dashboard shown alongside.

---

## Cut list, in cut order

If time compresses, drop from the bottom:

1. Market (keep the ledger and the controller — the market is the largest chunk of M6 and the least load-bearing)
2. Map-variant recommendations (loadout recommendations stay)
3. Inverted-hull outlines (post-processing alone carries the look)
4. Backfill matchmaking (plain queue is enough to demonstrate the distributed problem)
5. Arc weapon (three weapons cover the netcode profiles)
6. Zone count: 3 → 2

**Never cut:** the pure-core test suite, the telemetry pipeline, the director fallback ladder, content filtering, or the postmortem. The first four are what make it production-shaped; the last is what makes it legible to an interviewer.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Tick budget blown by entity count | Medium | Measured at M1, before anything depends on it. LOD and interest caps are the levers. |
| `UnreliableRemoteEvent` behaves differently than documented under load | Medium | Hard assert at 900 bytes; M1 exit criterion includes a real two-client test. Fallback: split into two packets at 20 Hz, halving effective entity count per packet. |
| MemoryStore quotas insufficient for the queue | Low | Queue entries are tiny and TTL'd at 120 s. Fallback: single-server matchmaking, documented as a limitation. |
| `TextService` filtering fails or is unavailable | Low | Canned barks are the fallback path and are built first, not last. |
| Anthropic latency spikes past the timeout | Medium | The FSM is a complete director on its own. High fallback rate degrades flavor, not playability. |
| Scope creep | **High** | This is the real risk. The cut list above exists to be used, and `CLAUDE.md` forbids building outside the current milestone. |
