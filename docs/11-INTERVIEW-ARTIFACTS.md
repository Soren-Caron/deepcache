# 11 — Interview Artifacts

The project's purpose is a job. This doc says what to capture along the way so that purpose is served, and what to say about it.

> **Numbers in this document are measured unless marked `[TARGET]`.**
>
> They did not used to be. This file was written before most of the systems
> existed, and several planning-era targets sat here reading as results —
> including one résumé line asserting a matchmaking p95 that the simulator
> had actually measured at **42.8 s against a 30 s target, and recorded as a
> FAIL** ([metrics/m5.md](metrics/m5.md)). Overclaiming in material written
> for job applications is the worst place in this repo to do it, and the
> metrics docs were honest the whole time — only this file was not.
>
> Every figure below now either cites where it was measured or carries
> `[TARGET]`. When the two disagree, `docs/metrics/*` wins.

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

**"Tell me about a hard technical problem."** → Lag compensation. The setup: the player shoots at what they see, which is 100 ms of interpolation delay plus their RTT behind server truth. Validating against the present makes moving targets unhittable; trusting the client makes aimbots. The fix: a 1-second ring buffer of hitbox history, rewind to the shooter's clamped client time, raycast against the rewound state but *current* static geometry. The tradeoff: a 250 ms clamp bounds how far a high-ping player can "shoot around a corner" from the victim's perspective. The number, from [metrics/m1.md](metrics/m1.md): against a *moving* Hauler with `IncomingReplicationLag` injected, **6/6 hits at 0 ms, 150 ms, and 300 ms**. At 300 ms every shot is clamped at exactly the 250 ms window — the design working, not failing. Compensation absorbs 250 ms of roughly 400 ms of error, leaving ~1.2 studs of residual against a 3.4-stud hitbox, which still lands.

The honest caveat that belongs in the same breath: a Hauler moves 3.2 studs in 400 ms against a 3.4-stud hitbox, so this test has limited power to distinguish "compensation works" from "the hitbox is forgiving". Say that before an interviewer asks it.

**"Tell me about working within a constraint."** → The 900-byte snapshot budget. `UnreliableRemoteEvent` silently drops packets over ~1000 bytes. That forced a binary format: quantized int16 positions on a 0.05-stud grid, uint8 yaw, packed state — 11 bytes per entity, 81 entities per packet, with delta compression bringing steady state to ~120 bytes. Quantization error is bounded at 0.025 studs, which is below perceptual threshold and asserted in a test.

**"Tell me about integrating an LLM into something real."** → OVERSEER. The core decision: the model is an advisor with a clamped budget, not a controller. A deterministic FSM always runs and is always sufficient. The LLM proposes; `Clamp.apply` is a pure total function that turns any input — including null, garbage, or a timeout — into a valid decision. Five-layer fallback ladder, circuit breaker, and every generated word passes Roblox's text filter with canned lines behind it. It never blocks the 20 Hz loop — measured at **p95 0.10–0.21 ms with 0 overruns across thousands of ticks, including during live director calls** ([metrics/m4.md](metrics/m4.md)).

The cost story changed and the change is the better answer. It was originally the Anthropic API at an estimated `[TARGET]` $0.08/run; it now runs on **self-hosted Ollama** (`llama3.2:3b` for ticks, `llama3.1:8b` for briefings), so marginal cost per run is effectively zero after the hardware. Measured warm tick latency is **0.905 s and 1.009 s against a 1200 ms budget** — under it, but by 15–25%, not comfortably. That margin is why a nonzero fallback rate is expected rather than treated as a bug, and cold start was measured at **40.6 s**, which is why the model is pinned with `keep_alive`.

The fallback rate is the part to lead with, not bury. Planned `[TARGET]` was <3%, assuming cloud inference. Measured against local hardware at a hard 1200 ms gameplay deadline it is **~50%** — and with the full run-state payload a tick takes **1482 ms, over budget**. The FSM fallback is the common case, not the exception.

That is the answer worth giving, because the interesting decision is what *wasn't* done: the budget was not relaxed to make the number look better. 1200 ms is a gameplay constraint, and a director that stalls the pacing loop is worse than one that falls back to an FSM that was always designed to be sufficient on its own. See [resume.md](../resume.md) for the same table.

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
- **"Matchmaking misses its own wait-time target, and I left the number in."** At the documented default assumptions the simulator reports p95 **42.8 s against a 30 s target**. The cause is structural — an assumed rating spread of 250 against a bucket width of 100, for 3-player squads — so the strict first-15s phase rarely fills and most matches land in the widening phases. The assumed spread could have been narrowed until the target passed. Reporting the failure and its sensitivity is the more useful answer, and it is the one an interviewer can actually probe.

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
- Designed a telemetry pipeline (Luau → Node/Fastify → Postgres) ingesting **859,660 events across 80 batches with zero rejections and zero duplicates** inside a 500 req/min platform ceiling, with batched flushes, idempotent ingest, and drop accounting.
- Integrated a self-hosted LLM game director (Ollama) with structured JSON output, a five-layer fallback ladder, a circuit breaker, and hard clamping — **0.9–1.0 s tick latency against a 1200 ms budget, never blocking the 20 Hz loop (p95 0.10–0.21 ms, 0 overruns)**.
- Implemented cross-server skill-based matchmaking on MemoryStore + reserved servers with lease-based coordinator election and **zero double-matches**, with a population sweep from 5 to 500 quantifying the wait/fairness tradeoff.
- Built a self-tuning economy: double-entry ledger with idempotency guarantees, plus a PI controller targeting a 0.85 sink/faucet ratio from live telemetry, with rate limits, clamps, and audit trail.

Replace every letter-variable with a measured number before this goes anywhere.
