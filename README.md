# DEEPCACHE

> A 3-player co-op extraction shooter in Roblox, built as six production-shaped systems around one game loop.
> **Status:** planning complete, M0 not started. Greenfield — no inherited code.

Salvage crews drop into a derelict automated facility. The facility's caretaker AI — **OVERSEER** — is still running, still talking, and still allocating security response. You have twelve minutes to loot and reach an extraction pad. OVERSEER decides how hard that is, offers you deals, and narrates your run over comms.

OVERSEER is an LLM. That's not a bolt-on feature — it's the diegetic reason the difficulty director has a voice.

---

## Why this project, for this role

The Roblox SWE intern posting names six areas. This project has one system per area, and they share a spine rather than sitting side by side.

| Posting area | System here | The hard part |
|---|---|---|
| Engine, real-time communication | **Authoritative entity netcode** — 20 Hz fixed-tick server sim, delta-compressed binary snapshots, client interpolation, server-side lag compensation | Roblox gives you replication, not netcode. Building rewind-based hit validation inside a 1000-byte unreliable-packet budget is real work. |
| Data processing | **Telemetry pipeline** — batched event stream → Postgres → rollup workers | Backpressure, HTTP budget (500 req/min/server), idempotency, dead-lettering |
| Foundational AI, LLMs | **OVERSEER director** — serverless proxy, structured JSON, clamped authority, hard fallback | Never blocking a 20 Hz loop on a network call; never trusting a model with gameplay authority; content-filtering generated text |
| Search and Discovery | **Matchmaking + loadout recommendations** — MemoryStore skill queue, reserved servers, item-item collaborative filtering | Queue fairness vs. wait time; a recommender evaluated against a real baseline |
| Economy | **Server-authoritative ledger + closed-loop tuning + escrowed market** | Sink/faucet ratio as a control problem, not a spreadsheet |
| 3D co-experience, rendering | **Procedural locomotion, ragdolls, stylized look pipeline** | Roblox has no custom shaders — the constraint *is* the problem |

**Distributed systems** shows up in three places at once: cross-server matchmaking state, the telemetry fan-in, and the economy's globally-tuned config fan-out.

Every system emits metrics. The project ships with a dashboard and a written postmortem, because "I built it" is weaker than "I built it and here are the p99 numbers."

---

## Three corrections to the original concept

Stated up front because they change what gets built:

1. **"Rollback netcode" is the wrong frame for Roblox.** Roblox network-owns player character physics; you cannot roll back the engine's character simulation. What you *can* build — and what is more impressive because it's correct — is an authoritative fixed-tick simulation for AI entities (which you fully own), snapshot replication, client-side interpolation, client prediction of the local player's *weapon actions*, and **server-side lag compensation via hitbox history rewind**. See [docs/03-NETCODE.md](docs/03-NETCODE.md).

2. **Roblox has no custom shaders.** "A stylized shader pass" isn't achievable as written. The achievable and more interesting version is a look pipeline built from what the engine does expose: post-processing stack, inverted-hull outlines, `EditableImage`-generated ramp textures (hard client cap: 8 instances), and PBR `SurfaceAppearance`. See [docs/08-PRESENTATION.md](docs/08-PRESENTATION.md).

3. **A "collaborative filtering model" should be scoped honestly.** Item-item cosine similarity over loadout co-occurrence, with a popularity baseline and an offline recall@3 evaluation. Small, real, and defensible in an interview — unlike a vague "small model."

---

## Repository map

```
docs/01-GAME-DESIGN.md         The game: loop, content, feel, numbers
docs/02-ARCHITECTURE.md        Repo layout, module contracts, the pure-core rule
docs/03-NETCODE.md             Tick, snapshots, interpolation, lag comp, anti-cheat
docs/04-TELEMETRY-BACKEND.md   Event schema, batching, backend services, storage
docs/05-OVERSEER-DIRECTOR.md   LLM proxy, prompt contract, clamps, fallback, moderation
docs/06-MATCHMAKING-DISCOVERY.md  Skill model, queue, reserved servers, recommender
docs/07-ECONOMY.md             Ledger, faucets/sinks, control loop, market
docs/08-PRESENTATION.md        Ragdoll, procedural animation, stylized look within engine limits
docs/09-TESTING-SIMULATION.md  Pure-Luau unit tests, headless run simulator, load harness
docs/10-ROADMAP.md             M0–M7, exit criteria, what ships if time runs out
docs/11-INTERVIEW-ARTIFACTS.md Metrics to capture, demo plan, talking points
tasks/BACKLOG.md               Atomic, dependency-ordered task list
CLAUDE.md                      Build rules for autonomous execution
```

Read [docs/10-ROADMAP.md](docs/10-ROADMAP.md) first if you want the schedule; [docs/02-ARCHITECTURE.md](docs/02-ARCHITECTURE.md) first if you want to start building.

---

## Setup — the parts a human has to do

Everything else is automatable. These nine are not:

1. **Install the Luau toolchain** (once):
```bash
winget install --id=Rojo.Rokit -e || cargo install rokit
```
   Then from the repo root: `rokit add rojo-rbx/rojo` and `rokit add lune-org/lune`, then `rokit install`.

2. **Create the Roblox experience.** New baseplate place → publish → note the **universe ID** and **place ID**.

3. **Enable, in Creator Hub → your experience → Settings → Security:** *Allow HTTP Requests* and *Enable Studio Access to API Services*. Nothing in the telemetry, director, or matchmaking path works without both.

4. **Create a second place in the same universe named `Lobby`.** Matchmaking needs it (M5).

5. **Anthropic API key** → put in `backend/.env` as `ANTHROPIC_API_KEY`. It never touches Roblox.

6. **Docker Desktop running** — the local Postgres comes from `docker compose up -d`.

7. **Studio open with the MCP bridge connected** — used for in-engine verification and playtests. ✅ *(already connected)*

8. **Real playtests with real humans** at M4 and M7. Nothing substitutes for this.

9. **Deploy the backend** (Fly.io or Railway) at M6 — Roblox production servers cannot reach `localhost`. Studio can, which is why the whole local dev loop works before this step.

Local dev loop, once 1/6 are done:

```bash
docker compose up -d && npm --prefix backend run dev
```

Studio → `http://127.0.0.1:8787` works from Studio sessions. Production requires step 9.

---

## Working title

**DEEPCACHE** — placeholder, chosen because it reads as both loot-and-extract and as something an engineer will smirk at. Rename freely; the string lives in one config file (`src/shared/config/Branding.luau`).
