# 12 — DEEPCACHE Postmortem

## 1. What it is

DEEPCACHE is a server-authoritative extraction shooter built in Roblox, used
as a vehicle for the systems underneath it rather than as a game pitch: a
fixed-tick netcode stack with delta-compressed binary snapshots and lag
compensation, a telemetry pipeline into Postgres, an LLM game director with a
hard clamping boundary, cross-server matchmaking on MemoryStore, and a
self-tuning economy with a double-entry ledger. The organising constraint —
and the thing that made the rest possible — is that **all gameplay logic lives
in engine-free pure Luau under `src/shared/core/`**, so it runs under Lune in a
terminal and is unit-testable without Studio, without a human, and without a
play session. Roblox-facing code is a deliberately thin adapter around it.

```
  Roblox client ──┐                            ┌── Ollama (llama3.2:3b)
                  │  UnreliableRemoteEvent     │      ▲
                  ▼  (binary snapshots)        │      │ structured JSON
  Roblox server ──┼── pure core (Lune-tested) ─┘      │
       │          │   net · sim · director            │
       │          │   economy · discovery · anim      │
       │          └──────────────────────────────┐    │
       │ HMAC-signed NDJSON batches              │    │
       ▼                                         ▼    │
  Node/Fastify ── Postgres ── rollup · recommender · economy · reconcile
       │                                              │
       └──────────── /v1/config, /v1/director/tick ───┘
```

At the time of writing: **797 pure-core tests**, 139 backend tests, 18
simulation tests, all green; `rojo build` clean; encoding, syntax and config
validators clean.

---

## 2. Six systems, six numbers

**Netcode — 896 bytes at 81 entities, against a hard 900-byte ceiling.**
`UnreliableRemoteEvent` silently drops payloads over ~1000 bytes, so the
snapshot format is 5 header bytes plus 11 per entity and asserts its own
budget at encode time. Real bandwidth at the 32-entity interest cap is
**1.87 KB/s per client**. Server tick p95 is **1.16 ms against a 12 ms
budget** — 9.7% of allowance.

**Telemetry — a 10,000-line batch ingested in 375 ms, against a 500 ms
budget.** A 2,000-run simulated season produced 859,660 accepted events with
**0 rejected and 0 duplicates**, dedupe enforced by a unique index on
`(run_id, server_id, seq)` rather than by application logic.

**Director — ~0.9–1.0 s per tick against a 1200 ms budget, warm.** The margin
is real but thin, and at full run-state payload size a warm tick measured
**1482 ms** — over budget, so the FSM fallback is the common case rather than
an exception. That is recorded as measured rather than tuned away.

**Matchmaking — p95 wait of 42.8 s against a <30 s target. It failed.** The
simulator says so plainly at the documented assumptions (rating σ=250, squad
size 3, bucket width 100). Coordinator election over a MemoryStore lease
recovers within the 10 s TTL with zero double-matches.

**Economy — 100,000 fuzzed market orders conserving currency and items
exactly, and 2,000 simulated runs reconciling with zero mismatches.** The PI
controller converges to the 0.85 sink/faucet target, though not inside the
14-day exit target — measured **24 days**, because the 3%/day rate cap, not
the gains, is the binding constraint.

**Presentation — 0.080 ms interpolation and 0.439 ms animation+IK per frame at
40 entities**, against docs/08 budgets of 1.5 ms and 2.0 ms. Leg raycasts
peaked at exactly **24/24** and never exceeded the cap in any configuration.

---

## 3. What broke

This is the longest section on purpose. Every item below was found by
something running, not by reading code.

### The fuzz test that found a 50% rejection rate

`Market.validate` rejected a player's order as a self-trade whenever they held
*any* resting order on the opposite side of that item — crossing or not. A
resting buy at 150 and a new sell at 200 from the same player got rejected,
even though those two orders could never fill each other.

Every hand-written self-trade test used crossing prices, so all of them passed
under the wrong rule. What caught it was the fuzz harness's own sanity
assertion — `acceptedCount > 50000`, added only to check the run had actually
exercised matching at scale. At 100k orders, book depth grew until roughly
**half of all order flow** was being rejected. The lesson generalised: several
bugs in this project were caught by assertions that existed to check a test
was not vacuous, not by assertions about the behaviour under test.

### Currency created out of nothing, 5% of the time

The ledger stores `delta` and `balance_after` as Postgres `BIGINT` — credits
are whole numbers — while `Market` computed `fee = price * quantity * 0.05` as
a float. Rounding a float fee and a float proceeds independently into BIGINT
does not conserve currency: at a 5% fee, a gross of 10 gives `fee = 0.5` and
`proceeds = 9.5`, which round to 1 and 10 and **mint a credit**. That is every
gross ending in a multiple of ten, i.e. 5% of all integer amounts.

The fuzz test could not have caught it, because despite an accept criterion
reading "conserves currency and items exactly", it only ever checked *item*
quantities. Fixed by requiring integral prices, flooring the fee, and deriving
proceeds by subtraction — and by making the fuzz test actually assert
`sellerReceived + fees == buyerPaid`.

### A cold-start trap that killed the director permanently

docs/metrics/m4.md claimed Ollama's cold start was "mitigated with
`keep_alive` pinned on every request". It is not, and the failure is worse
than slow — it is permanent. `keep_alive` only applies to a request Ollama
actually *finishes*; a tick request is aborted at 1200 ms, and a cold load
takes far longer. So from a cold model every tick starts a load, abandons it,
never establishes the pin, and fails identically forever.

Proven rather than argued: three consecutive ticks against an evicted model
all returned `error=timeout`, and `GET /api/ps` afterwards showed **no model
loaded at all**. The director had degraded to pure-FSM with no path back. Fixed
with an out-of-band boot warm-up on a 90 s deadline; the 1200 ms tick budget
stays strict because it is a gameplay constraint.

### Pressing space got you kicked

Reported from an actual playtest: jumping produced a stutter, a wall of
`Remote event invocation queue exhausted` warnings doubling 1→2→4→8→16, and
then a kick for a speed violation.

One root cause. `MovementGuard` measured a single **3D** displacement against
`maxSpeed`, which is a **walk** speed of 16 studs/s. Gravity is not: a default
jump leaves the ground at 53 studs/s. The guard was charging players for
gravity. Measured in a real session with the player standing perfectly still —
horizontal displacement 0.00 on every tick — a standing jump accrued 2.57× the
allowance per airborne tick and tripped a correction 12 ticks in. That
correction *was* the stutter: the server CFraming the player back mid-air.

The remote spam was the same bug's other face — nothing on the client was
connected to `PositionCorrection` at all, so corrections backed up an
unconsumed queue and never reliably landed anyway, since Roblox network-owns
the character and a server-side CFrame write is a request the client's physics
can overwrite.

The fix separated horizontal and vertical budgets. **And then the fix had its
own hole**, found by probing it adversarially rather than declaring victory: a
fly hack rising at 40 studs/s scored zero, because that is *below* the jump
impulse and every individual frame is indistinguishable from a jump.
Instantaneous speed cannot separate them; duration can, because gravity ends a
real jump within about four ticks. A sustained-rise counter closed it.

### A gait where half the legs never moved

`StepPlanner` alternates leg groups so opposing legs never lift together.
Serving whichever leg asks first *looks* like alternation and is not: a leg
lands and, still inside the same `step()` call, is planted again and already
past the threshold, so it re-commits before any other group is considered. Its
group is then permanently in flight and the opposing gate never opens.

Measured on a quadruped over 900 frames before the fix: **2 steps for group 1,
zero for group 2**, with group 2's feet left 90 studs behind the body. After
choosing the serving group explicitly: 58 versus 56 steps, ratio 1.04.

### Two writers on one property

M4-9 drove `ColorCorrectionEffect` from the HUD for threat tier; M7-5 drove
the same effect from the zone preset. Two writers means whichever tween lands
last wins, and the stack flickers between answers — the exact failure the
HUD's own header warns about ("two sources for one number is how a HUD ends up
confidently lying"). Then the *fix* introduced a sibling of the same bug: post
effects stack by **class**, not by name, so creating a `DeepcacheBloom` beside
a Studio-authored `Bloom` produced two BloomEffects that multiply. Both found
by counting effects in a live session.

### Bugs the audit pass found by reading

A dedicated review of M2–M6 found seven more, of which the two sharpest were:

- **`Clamp.apply` fell back to a literal.** `spawnPattern` alone fell back to
  `"even"` instead of the FSM baseline — as docs/05 specified. The FSM emits
  `flank` in PRESSURE and `chokepoint` in SPIKE, so a malformed model field
  silently downgraded a deliberate pacing decision. A model that fails should
  never be able to *change* gameplay. It survived because the clamp fixture's
  own baseline was `"even"`, making both behaviours identical in every test.
- **`Ledger.apply` returned `false` for two incompatible outcomes** —
  "duplicate, already counted" (which docs/07 says to treat as success) and
  "rejected, insufficient funds" (which must not be). A caller following the
  documented rule would hand over goods without taking currency: the
  duplicate-grant bug the ledger exists to prevent, arriving through the error
  path.

Two patterns produced most of these, and both are worth carrying forward:
**guards that check NaN but not infinity** (three separate instances, where
`inf` produced exactly the silent corruption the NaN check existed to
prevent), and **test fixtures that made the wrong behaviour indistinguishable
from the right one** (four instances).

---

## 4. What I'd do differently

**Measure the thing the criterion names, not a proxy for it.** The market fuzz
test claimed to prove currency conservation and checked only items. The
out-of-bounds movement test drove the exact buggy path and asserted only on
the reason string, never the corrected position. In both cases the test was
written to the shape of the feature rather than to the words of the
requirement, and in both cases that is precisely where the bug lived.

**Vary fixtures away from defaults deliberately.** Four separate bugs survived
because a fixture happened to equal the fallback value, or used crossing
prices, or moved along a single axis. A fixture that matches the default is a
test that cannot fail.

**Write the adapter alongside the remote.** `PositionCorrection` was declared,
fired, and never consumed — for several milestones. A remote that is fired but
never listened to is worse than an unused one: it backs up a queue and the
resulting log line names the symptom, not the cause.

**Be more suspicious of documented mitigations.** "Mitigated with `keep_alive`"
was written down after a real measurement and was still wrong, because the
measurement did not include the abort path. A mitigation that has not been
tested *in the failure mode it mitigates* is a hypothesis.

**Scope regret: the market.** docs/10's own cut list puts the market first to
drop, and that judgement was right. It is the largest single chunk of M6 and
the least load-bearing for what the project is meant to demonstrate; the
ledger and the controller carry that weight on their own.

---

## 5. What's simplified vs. production

- **One backend, one region, no deploy.** Everything runs against a local
  Postgres and a local Ollama. M6-11 (deploy) and M0-8 (a published place) are
  open, which also means the matchmaking teleport path (M5-6/M5-7) has never
  run against two real places.
- **The director is unauthenticated.** `/v1/director/tick` has no HMAC while
  `/v1/ingest` does. Fine locally; an unauthenticated LLM proxy must not ship.
- **Market state is per-server and in memory.** Escrow and the order book do
  not persist or span servers; that is what a deployed backend is for.
- **No real playtest.** M7-11 needs four or more humans and has not happened,
  so every number here is from simulation, synthetic load, or single-player
  Studio sessions.
- **Entities render as boxes.** The gait and IK are computed, LOD'd and
  budgeted, but there is no limb geometry for the solved joints to drive yet,
  so "no popping at LOD transitions" is unverified rather than verified.
- **Insurance, cosmetics and market fees are the only sinks wired end to end.**
  The faucet/sink table in docs/07 is fully implemented in `Payouts` but not
  every reason code has a gameplay path that emits it yet.
- **`setWorldBounds` is never called**, so the movement guard's out-of-bounds
  branch is dead code in practice.
