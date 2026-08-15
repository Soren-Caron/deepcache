# 11 — Interview Artifacts

The project's purpose is a job. This doc says what to capture along the way so that purpose is served, and what to say about it.

## The four deliverables

1. **A playable place link.** Someone can click it and be in a run within 30 seconds.
2. **A live dashboard** with real numbers from real and simulated runs.
3. **A postmortem** (2–3 pages) — what was built, what the numbers say, what didn't work.
4. **A 3–5 minute demo video** — one run, dashboard alongside, narrated.

The dashboard is the differentiator. Most portfolio games are a video and a link. Almost none can answer "what's your p99 hit-registration latency" with a chart.

## Numbers to have memorized

Capture these continuously, not at the end. Every one comes from the telemetry pipeline.

| System | Number | Why it lands |
|---|---|---|
| Netcode | tick p50/p95/p99 in ms, against the 50 ms budget | shows you know a real-time loop has a deadline |
| Netcode | snapshot bytes/s/client; bytes/entity | shows you optimized a wire format, with the number to prove it |
| Netcode | hit-registration RTT p50/p95/p99 at 50/150/300 ms injected latency | this is the lag-compensation proof |
| Netcode | mispredict rate | shows prediction is measured, not assumed |
| Telemetry | events/run, batches/min vs. the 500/min ceiling | shows you designed against a platform constraint |
| Telemetry | ingest throughput, p95 latency, drop rate | ordinary backend competence |
| Director | tick latency p50/p95, fallback rate, cost per run | shows LLM integration treated as an engineering problem |
| Director | A/B deltas on extraction rate and near-miss rate | shows you tried to *prove* the feature worked |
| Matchmaking | wait p50/p95/p99 across simulated populations; intra-squad spread | the fairness/latency tradeoff, quantified |
| Matchmaking | coordinator failover time; double-match count (0) | the distributed-systems proof |
| Discovery | recall@3 vs. popularity baseline | shows you evaluated rather than shipped a vibe |
| Economy | sink/faucet ratio over time with the multiplier overlaid | the closed loop, visible in one chart |
| Economy | reconciliation mismatches (0); duplicate grants caught | correctness under retry |
| Presentation | client frame budget by subsystem at 40 entities | shows profiling, not guessing |

## Six stories, one per posting area

Each is a two-minute answer with a number in it.

**"Tell me about a hard technical problem."** → Lag compensation. The setup: the player shoots at what they see, which is 100 ms of interpolation delay plus their RTT behind server truth. Validating against the present makes moving targets unhittable; trusting the client makes aimbots. The fix: a 1-second ring buffer of hitbox history, rewind to the shooter's clamped client time, raycast against the rewound state but *current* static geometry. The tradeoff: a 250 ms clamp bounds how far a high-ping player can "shoot around a corner" from the victim's perspective. The number: hits register on a moving target at 300 ms simulated RTT, p95 confirmation at X ms.

**"Tell me about working within a constraint."** → The 900-byte snapshot budget. `UnreliableRemoteEvent` silently drops packets over ~1000 bytes. That forced a binary format: quantized int16 positions on a 0.05-stud grid, uint8 yaw, packed state — 11 bytes per entity, 81 entities per packet, with delta compression bringing steady state to ~120 bytes. Quantization error is bounded at 0.025 studs, which is below perceptual threshold and asserted in a test.

**"Tell me about integrating an LLM into something real."** → OVERSEER. The core decision: the model is an advisor with a clamped budget, not a controller. A deterministic FSM always runs and is always sufficient. The LLM proposes; `Clamp.apply` is a pure total function that turns any input — including null, garbage, or a timeout — into a valid decision. Five-layer fallback ladder, circuit breaker, and every generated word passes Roblox's text filter with canned lines behind it. It never blocks the 20 Hz loop. Fallback rate under 3%, $0.08 per run measured from token counts.

**"Tell me about a data pipeline."** → 500 HTTP requests per minute per server is the hard ceiling. Everything batches: 5-second flushes, 12 requests/min, 4% of budget, with the rest as headroom for retries. Idempotency at the database level via a unique constraint on the idempotency key, so a retried payout is a caught constraint violation rather than a duplicate grant. Drop counters ride the *next* successful batch, so loss is always visible in the data rather than silently absent.

**"Tell me about a distributed systems problem."** → Cross-server matchmaking. Every lobby server runs the same coordinator loop, so without coordination they form conflicting matches from the same queue. Solution: a MemoryStore lease with a 10-second TTL elects one coordinator; queue entries are removed with compare-and-set *before* the teleport is issued, so a player can never be double-matched. Crashed coordinator is replaced within 12 seconds. Verified by killing it mid-operation.

**"Tell me about a system you tuned."** → The economy. Sink/faucet ratio is a control problem, not a spreadsheet. A PI controller reads the trailing 24 hours from the same telemetry pipeline and nudges a global payout multiplier toward a 0.85 target. Deliberately no derivative term — daily data from a small population is noise, and D amplifies it. Guardrails: ±3% per day, hard clamps, a sample-size floor, a kill switch, and a full audit trail. Validated against seeded imbalances in simulation, where ground truth is known.

## Things to say honestly

Credibility comes from the caveats, not despite them.

- **"This isn't rollback netcode."** Roblox network-owns player characters; you can't roll back the engine's character sim. It's authoritative fixed-tick entity simulation with snapshot interpolation and server-side lag compensation. Knowing the difference is the point.
- **"Roblox has no custom shaders."** The stylized look is post-processing, inverted-hull outlines, and `EditableImage` ramps within an 8-instance cap. It's a fixed-function pipeline problem.
- **"The movement anti-cheat is plausibility checking, not prevention."** The client owns its character. Budget-based violation scoring stops trivial cheats and generates telemetry for the rest. A determined cheater gets through, and pretending otherwise would be worse.
- **"Most of the population data is simulated."** The simulator validates plumbing, statistics, and convergence. It does not prove the game is fun or that the director improves player experience. The real playtests are small.
- **"The recommender might tie the popularity baseline."** With 40 items and a small population, that's a plausible and interesting outcome. Report whatever the eval says.
- **"The backend workers share a process."** A real deployment separates them. It's a known simplification, not an oversight.

## The postmortem

Three pages, structured as:

1. **What it is** — one paragraph plus the architecture diagram.
2. **Six systems, six numbers** — one short section each, leading with the metric.
3. **What broke** — the genuinely hard bugs, how they were found, what the fix was. This section is the most valuable one and it should be the longest.
4. **What I'd do differently** — architecture regrets, scope regrets, measurement regrets.
5. **What's simplified vs. production** — the honest list above.

Write section 3 *as it happens*, in a running log. Reconstructing debugging stories months later produces vague ones, and vague debugging stories are worse than none.

## Résumé lines (draft from actuals, don't ship placeholders)

- Built a server-authoritative multiplayer shooter in Roblox with a fixed 20 Hz simulation tick, delta-compressed binary snapshots (11 B/entity, <6 KB/s/client), client-side interpolation, and server-side lag compensation via hitbox-history rewind — hits register correctly at 300 ms simulated RTT.
- Designed a telemetry pipeline (Luau → Node/Fastify → Postgres) handling ~N events per run within a 500 req/min platform ceiling, with batched flushes, idempotent ingest, and drop accounting.
- Integrated an LLM game director through a serverless proxy with structured JSON output, a five-layer fallback ladder, a circuit breaker, and hard clamping — <3% fallback rate at $0.08/run, never blocking the real-time loop.
- Implemented cross-server skill-based matchmaking on MemoryStore + reserved servers with lease-based coordinator election, achieving p95 queue waits under 30 s in simulation with zero double-matches.
- Built a self-tuning economy: double-entry ledger with idempotency guarantees, plus a PI controller targeting a 0.85 sink/faucet ratio from live telemetry, with rate limits, clamps, and audit trail.

Replace every letter-variable with a measured number before this goes anywhere.
