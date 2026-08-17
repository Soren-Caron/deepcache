# 05 — OVERSEER: the LLM Game Master

## The governing idea

**The LLM is an advisor with a clamped budget, not a controller.** A deterministic finite-state director always runs and is always sufficient on its own. OVERSEER proposes modulations to it. Every proposal passes through `Clamp.apply`, which is a pure function that cannot error and always returns a valid decision — whether the input is a perfect response, malformed JSON, or nothing at all.

This is the design decision worth defending in an interview: an LLM in a real-time loop is a *source of suggestions with unbounded latency and unbounded content*. Treat it that way and it's a feature. Treat it as a controller and it's an outage waiting for a timeout.

## Two tiers

```
                     ┌──────────────────────────────────────────┐
   run state ───────►│ Deterministic Director FSM (core/director/Fsm)│──► baseline decision
                     │  BUILD → PRESSURE → SPIKE → LULL → …     │        (always valid)
                     └──────────────────────────────────────────┘
                                     │
                                     ▼
   run state ──► [async, 20 s] ──► /v1/director/tick ──► Ollama (llama3.2:3b) ──► proposal
                                     │                              │
                                     │      (timeout / error / garbage)
                                     ▼                              ▼
                     ┌──────────────────────────────────────────────────┐
                     │ Clamp.apply(proposal | nil, bounds)              │
                     │   → always a DirectorDecision                    │
                     └──────────────────────────────────────────────────┘
                                     │
                                     ▼
                            applied to the run
```

The FSM alone produces a complete, playable, well-paced game. That's the M2 exit criterion, deliberately *before* the LLM is wired up in M4. If the LLM work slipped entirely, the game still ships.

## Cadence and latency

- **Tick every 20 seconds** — 36 calls per 12-minute run.
- **Fully asynchronous.** `DirectorService` fires the request on a coroutine and stores the result when it lands. The 20 Hz loop never awaits anything.
- **Timeout 1200 ms.** Past that, the in-flight response is discarded (not applied late — a stale decision is worse than none).
- **In-flight guard:** never more than one outstanding request. A tick that arrives while one is pending is skipped and counted.
- **Applied at the next tick boundary**, so decisions land deterministically rather than mid-frame.

## Request

The game server posts a compact run-state summary (~350 tokens) to the backend proxy. The backend is the only thing that talks to the model — a Roblox script, a `ModuleScript`, or a config table never does. **Revised at M4 kickoff:** the model runs locally via Ollama (`http://127.0.0.1:11434`) rather than a cloud API, so there is no key to protect here at all — the isolation is kept anyway, because a game server should never be the thing calling out to an LLM host directly regardless of whether that host needs a secret.

```jsonc
POST /v1/director/tick
{
  "runId": "01HX...",
  "t": 312,                          // seconds elapsed
  "squad": [
    { "pid": "a3f9", "hp": 62, "weight": 47, "kills": 14, "deaths": 0, "zone": "Processing" },
    { "pid": "b7c2", "hp": 100, "weight": 12, "kills": 3, "deaths": 1, "zone": "Perimeter" }
  ],
  "pressure": { "aliveEnemies": 18, "budgetSpent": 34, "recentPlayerDamage": 210, "recentEnemyDeaths": 22 },
  "pacing": { "secondsSinceLastFight": 4, "secondsSinceLastLull": 96, "fsmState": "PRESSURE" },
  "objective": { "active": "hold_terminal", "progress": 0.4 },
  "history": ["escalated at 180s", "offered no_loot_window at 240s, declined"]
}
```

`history` is a short rolling list of OVERSEER's own past decisions in plain text — it's what lets the model stay consistent in voice and avoid repeating itself, without sending a full transcript.

## Response contract

Structured output with a strict JSON schema (`output_config.format`), which removes an entire class of parsing failure:

```jsonc
{
  "intent": "punish_greed",            // enum, 8 values, purely for logging + bark tone
  "spawnMultiplier": 1.35,             // number
  "spawnPattern": "flank",             // enum: even | flank | chokepoint | hunt_heaviest
  "objective": {
    "id": "no_loot_window",            // enum — whitelist from Objectives.luau, cannot be invented
    "params": { "durationS": 90 }
  },
  "threatTier": 4,                     // 1–5, drives music + lighting
  "bark": "The heavy one. Second level. Reroute two units — the others can keep their trinkets."
}
```

Schema is defined once in `backend/src/llm/schema.ts` and mirrored in `core/director/Schema.luau` for client-side validation. A test asserts the two stay in sync (compares field names and enum members from a shared JSON file).

## Clamping — where safety actually lives

`core/director/Clamp.luau` is pure, total, and never throws:

| Field | Rule |
|---|---|
| `spawnMultiplier` | clamp to `[0.6, 1.6]`; additionally rate-limited to ±0.25 change per tick so difficulty can't whipsaw |
| `spawnPattern` | must be in enum, else `"even"` |
| `objective.id` | must be in the whitelist **and** not currently on cooldown, else keep the active objective |
| `objective.params` | each param clamped to the per-objective range in `Objectives.luau`; unknown keys dropped |
| `threatTier` | clamp to `[1, 5]`, max ±1 change per tick |
| `bark` | max 180 chars, stripped of control characters, then **must pass content filtering** (below) |
| anything missing | filled from the FSM baseline |
| whole payload malformed / null | return FSM baseline unchanged, increment `fallbackUsed` |

**Scope split on the `objective.id` row, worth being explicit about:** `Clamp.luau` (M4-5) owns the whitelist half — an id outside `Schema.OBJECTIVE_IDS` falls back to the baseline. Cooldown tracking is stateful and lives in the objective system (M4-8) instead, since `Clamp.apply` is pure and has no notion of time or history. In practice this means the caller is responsible for only ever passing `Clamp.apply` a `baseline.objective` that is already cooldown-legal — Clamp enforces "in the whitelist," the caller enforces "and available right now" by construction of what it hands in as the baseline.

**What the model can never touch:** damage numbers, loot tables, drop rates, currency amounts, player HP, extraction timers, or anything in the economy. Those aren't clamped — they're simply not in the schema. The blast radius of a bad model output is "the next 20 seconds are somewhat harder or easier than ideal."

## Content filtering — non-negotiable

Any model-generated text shown to a player goes through Roblox's text filter first:

```lua
local ok, result = pcall(function()
    return TextService:FilterStringAsync(bark, requestingUserId, Enum.TextFilterContext.PublicChat)
end)
if not ok then return CANNED_BARKS[rng:next(#CANNED_BARKS)] end

local ok2, display = pcall(function()
    return result:GetNonChatStringForBroadcastAsync()
end)
if not ok2 then return CANNED_BARKS[rng:next(#CANNED_BARKS)] end
return display
```

Notes that matter:
- `FilterStringAsync` requires a `UserId` of an "author." For generated text, use the run's host player. This is the community-standard approach for AI text on the platform; it's worth flagging in the postmortem as an area where the platform primitive doesn't perfectly fit the use case.
- Filtering is **async** and can fail. It happens in the same coroutine as the director call, before the bark is queued for display — never on the tick path.
- A pool of ~40 hand-written canned barks per intent covers every failure mode. Players never see a blank comms feed, and they never see unfiltered text.

## Model selection and cost

**Revised at M4 kickoff.** The original plan (below, kept for the cost-math rationale, which is still the right way to think about this even though the numbers no longer apply) called for the Anthropic API. The actual decision made at M4 kickoff was to self-host via [Ollama](https://ollama.com) instead: zero marginal cost per run, and running the director on locally-hosted open models is itself a real thing to show on a portfolio, not just an implementation detail chosen to save money.

| Call | Model | Why |
|---|---|---|
| Director tick (36/run) | `llama3.2:3b` via Ollama | Small enough to have a real shot at the 1200ms tick budget on consumer GPU hardware. Latency is still the binding constraint — a bigger local model would blow the budget on every tick, not occasionally. |
| Pre-run briefing (1/run) | `llama3.1:8b` via Ollama | Runs during the drop animation; no hard latency budget, so the larger model is affordable and produces better prose. |
| Post-run debrief (1/run) | `llama3.1:8b` via Ollama | Written to the run summary screen; fully async, no latency budget at all. |

**Request shape for ticks**, against Ollama's native `/api/chat`, `stream:false`, with a JSON-schema-constrained `format` (Ollama's structured-output mechanism — the request-level field is unnested, unlike Anthropic's `output_config.format`):

```ts
await fetch("http://127.0.0.1:11434/api/chat", {
  method: "POST",
  body: JSON.stringify({
    model: "llama3.2:3b",
    stream: false,
    keep_alive: "30m", // see cold-start note below
    messages: [
      { role: "system", content: OVERSEER_SYSTEM },
      { role: "user", content: JSON.stringify(runState) },
    ],
    format: DIRECTOR_JSON_SCHEMA,
    options: { num_predict: 400 },
  }),
});
```

**No prompt-caching trap here — a different one instead.** Ollama has no equivalent of Haiku's 4096-token cache-eligibility floor, so the system prompt's length is no longer load-bearing the way it was for the Anthropic plan (the ≥4200-token target below is historical). The real trap is **cold start**: Ollama unloads an idle model after a default ~5 minutes, and reloading `llama3.2:3b` into VRAM measured at **~40s** — utterly fatal to a 1200ms tick budget if it happens mid-run. `keep_alive` is set explicitly (pinned for the life of the backend process, not left at the default) so the tick model never idles out between 20s ticks.

**Real measured latency**, GPU-warm (RTX 5070 laptop, 8GB VRAM), a tick-shaped request through the real structured-output path — not estimated, not a token-count projection:

```
cold (model not loaded): total_duration ≈ 40.6s (load_duration ≈ 21.7s of that)
warm request 1:           total_time    ≈ 0.905s
warm request 2:           total_time    ≈ 1.009s
```

Under the 1200ms budget, but with real, non-trivial margin only (roughly 15-25%), not headroom to ignore. Expect a measurable `fallbackUsed` rate under real load — the FSM fallback existing for exactly this reason is what makes that an acceptable outcome rather than a bug. `director.decision` telemetry logs latency per call, same as the original plan, so the actual fallback rate is measured once M4-6/M4-10 land, not assumed from this one warm-state sample.

**Cost per run: $0**, after the one-time cost of the hardware already owned. No API bill, no rate limits to design a circuit breaker around in the cloud sense — though the circuit breaker itself (M4-6) still matters, because "Ollama is slow/unresponsive under local load" is a real failure mode even without a network in the picture.

<details>
<summary>Superseded: original Anthropic-based cost math</summary>

| Call | Model | Why |
|---|---|---|
| Director tick (36/run) | `claude-haiku-4-5` | Latency is the binding constraint. Structured JSON extraction on a small state summary doesn't need a frontier model. |
| Pre-run briefing (1/run) | `claude-opus-5` | Sets voice and stakes for the whole run; runs during the drop animation, so 3–4 s is fine. |
| Post-run debrief (1/run) | `claude-opus-5` | Written to the run summary screen; fully async, no latency budget at all. |

```ts
await client.messages.create({
  model: "claude-haiku-4-5",
  max_tokens: 400,
  system: [{ type: "text", text: OVERSEER_SYSTEM, cache_control: { type: "ephemeral" } }],
  output_config: { format: { type: "json_schema", schema: DIRECTOR_SCHEMA } },
  messages: [{ role: "user", content: JSON.stringify(runState) }],
});
```

Prompt caching had a trap: Haiku 4.5's minimum cacheable prefix is 4096 tokens — a shorter system prompt silently does not cache, with no error. The OVERSEER system prompt was sized to exceed 4096 tokens for this reason (`countTokens` ≥ 4200, still a reasonable prompt-design target even without the caching motivation).

```
Ticks:    36 × (~3.0K input, ~180 output)
          input  108K tok — after cache reads, effectively ~15K billable  ≈ $0.015
          output 6.5K tok                                                  ≈ $0.033
Briefing + debrief (Opus, $5/$25): ~4K in, ~600 out                        ≈ $0.035
                                                                    ─────────────
                                                          ≈ $0.08 per 12-min run
```

At 1,000 runs that's ~$80 — comfortably affordable for a portfolio project, and a number worth having on hand because "did you think about cost" is a real interview question that this decision now answers a different way (self-hosted, $0 marginal) rather than avoids.

</details>

## Fallback ladder

Every step is exercised by a test:

1. Structured output parses and validates → clamp → apply.
2. Structured output unavailable (API error) → **fallback parse**: extract the first balanced `{...}` from the response text, `JSON.parse`, validate. This is the DrPocket-style resilience pattern and it earns its place — it's caught real malformed responses in similar systems.
3. Parse fails or validation fails → FSM baseline, `fallbackUsed = true`.
4. Timeout (>1200 ms) → FSM baseline, discard late response.
5. Ollama unreachable or erroring → FSM baseline. After 3 consecutive failures, **circuit breaker opens for 60 s** — stop calling entirely, keep playing, retry after the cooldown. Prevents a stalled local model from burning the tick loop's attention on every single tick.
6. Ollama returns 500 under local resource contention (GPU busy with another request, e.g. briefing and a tick landing at once) → treated the same as a timeout: FSM baseline, counts toward the breaker's failure total. There is no cloud rate limit to honor here, but the local equivalent — one GPU, multiple concurrent requests — gets the same "back off and let it recover" treatment.

**Target: `fallbackUsed` rate < 3% under normal operation.** Tracked on the dashboard. A fallback is not a failure — it's the system working — but a *high* fallback rate means the model or the schema needs work.

## Evaluating the director

The hard question an interviewer will ask: *how do you know the LLM made it better?*

Answer: A/B by run, decided at `run.start` by hashing `runId`.

| Arm | Behavior |
|---|---|
| **A (control)** | FSM only. `directorMul` from the FSM's own pacing curve. |
| **B (treatment)** | FSM + OVERSEER proposals. |

Metrics compared across arms, from telemetry, with a two-sample test:

- **Session length** and **runs per session** (engagement)
- **Extraction rate** — target band 45–60%; the director should hold this steadier than the FSM alone
- **Time-in-combat variance** — lower is *worse* here; good pacing means bigger swings between tension and relief
- **Near-miss rate** — deaths within 20 s of a pad, or extractions below 15% HP. The director's whole job is manufacturing these.
- **Objective completion rate** — is the model picking objectives the squad can actually do?

Sample size comes from `sim/`, which can generate thousands of scripted runs, plus real playtests at M7. The simulated arm validates the *plumbing and statistics*; the real arm validates the *effect*. Being clear about that distinction is more credible than claiming simulated players prove a fun result.

## Prompt design notes

- **System prompt** is a versioned file, `backend/src/llm/prompts/overseer.v1.md`. The version string ships in `director.decision` telemetry, so a prompt change is attributable in the metrics.
- Voice: clinical, faintly amused, institutional. OVERSEER is not evil; it is doing inventory management and the players are the inventory discrepancy.
- The prompt states the clamps explicitly. Telling the model its real bounds produces better proposals than letting it guess and getting clamped.
- Worked examples included: two good decisions with reasoning, two bad ones labeled as bad and why. Examples are the strongest signal in a prompt, so they're chosen to be deliberately varied rather than one gold template.
