# DEEPCACHE

> A 3-4 player co-op extraction shooter in Roblox, built as six production-shaped systems around one game loop.
> **Status:** all eight milestones built and green — **1,079 pure-core tests, 139 backend tests**, place published. See [what's left](docs/13-NEXT.md) for the honest remainder.

Salvage crews drop into a derelict automated facility. The facility's caretaker AI — **OVERSEER** — is still running, still talking, and still allocating security response. You have twelve minutes to loot and reach an extraction pad. OVERSEER decides how hard that is, offers you deals, and narrates your run over comms.

OVERSEER is an LLM. That's not a bolt-on feature — it's the diegetic reason the difficulty director has a voice.

---

## Why this project, for this role

The Roblox SWE intern posting names six areas. This project has one system per area, and they share a spine rather than sitting side by side.

| Posting area | System here | The hard part |
|---|---|---|
| Engine, real-time communication | **Authoritative entity netcode** — 20 Hz fixed-tick server sim, delta-compressed binary snapshots, client interpolation, server-side lag compensation | Roblox gives you replication, not netcode. Building rewind-based hit validation inside a 1000-byte unreliable-packet budget is real work. |
| Data processing | **Telemetry pipeline** — batched event stream → Postgres → rollup workers | Backpressure, HTTP budget (500 req/min/server), idempotency, dead-lettering |
| Foundational AI, LLMs | **OVERSEER director** — self-hosted Ollama, structured JSON, clamped authority, hard fallback | Never blocking a 20 Hz loop on a network call; never trusting a model with gameplay authority; content-filtering generated text |
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
docs/11-INTERVIEW-ARTIFACTS.md Metrics captured, demo plan, talking points
docs/12-POSTMORTEM.md          What it is, what worked, what didn't
docs/13-NEXT.md                Working notes: what's verified, what's left, bugs found and fixed
tasks/BACKLOG.md               Atomic, dependency-ordered task list
CLAUDE.md                      Build rules this project follows
```

Read [docs/13-NEXT.md](docs/13-NEXT.md) first if you want the current state; [docs/12-POSTMORTEM.md](docs/12-POSTMORTEM.md) first if you want the retrospective; [docs/02-ARCHITECTURE.md](docs/02-ARCHITECTURE.md) first if you want to start reading code.

---

## Running it

**Toolchain**, once:
```bash
winget install --id=Rojo.Rokit -e || cargo install rokit
rokit install
```
`rokit.toml` pins the Rojo and Lune versions this repo was built against.

**Pure-core tests** — no Roblox, no Studio, no backend:
```bash
lune run tests
```

**Backend**, once you have Docker and Ollama:
```bash
docker compose up -d && npm --prefix backend run dev
npm --prefix backend test
```
Copy `backend/.env.example` to `backend/.env` and fill it in — an `INGEST_SECRET` and `PLAYER_SALT` (both generatable one-liners are in the file's comments), plus your Roblox universe/place IDs once you've published an experience. The director expects a local `ollama serve` with `llama3.2:3b` and `llama3.1:8b` pulled; see [docs/05-OVERSEER-DIRECTOR.md](docs/05-OVERSEER-DIRECTOR.md) for why it's self-hosted rather than a cloud API.

**Roblox side**, via [Rojo](https://rojo.space/):
```bash
rojo serve
```
Then connect the Rojo Studio plugin to a place with *Allow HTTP Requests* and *Enable Studio Access to API Services* both on (Creator Hub → your experience → Settings → Security) — nothing in the telemetry, director, or matchmaking path works without both. Roblox production servers can't reach `localhost`, so the backend needs a real deploy before any of this works outside Studio.

What a human still has to do that nothing here automates: publish the experience, flip those two security toggles, generate the secrets above, run real playtests, and deploy the backend. All of it is a few minutes of clicking, not engineering — see [docs/13-NEXT.md](docs/13-NEXT.md) for the current state of each.

---

## Working title

**DEEPCACHE** — placeholder, chosen because it reads as both loot-and-extract and as something an engineer will smirk at. Rename freely; the string lives in one config file (`src/shared/config/Branding.luau`).
