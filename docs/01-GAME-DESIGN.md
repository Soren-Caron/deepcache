# 01 — Game Design

## The pitch in one breath

Three salvagers drop into a derelict facility run by a still-conscious caretaker AI. Twelve minutes to loot and reach an extraction pad. Everything you carry is at risk until you're out. OVERSEER watches, comments, escalates, and occasionally offers you a deal you shouldn't take.

## Design pillars, in priority order

1. **The server is right and it still feels instant.** Every shot is validated server-side, and the player never perceives that. If it feels laggy, the netcode is wrong, not the design.
2. **OVERSEER must feel like a character, not a difficulty slider with a voice.** It gets to make decisions with visible consequences, inside bounds it cannot escape.
3. **Weight is the tension.** Loot slows you down. The extraction timer doesn't care.
4. **Every run produces data.** If a system can't be measured, it isn't finished.
5. **Content is data.** Adding an enemy, weapon, room module, or objective is a table row.

## The loop

```
LOBBY ──► DROP ──────────────► RUN (12:00) ──────────────► EXTRACT ──► DEBRIEF
                                 │                            │
        matchmake by skill       │  loot · fight · objectives │  bank loot
        pick loadout             │  OVERSEER escalates        │  rating update
        (recommended)            │  weight accumulates        │  ledger credit
                                 │                            │
                                 └──► DEATH ──► lose carried loot, keep stash
```

- **Run length:** 12:00 hard cap. Extraction pads open at 3:00, 6:00, 9:00 — a pad that opens later is deeper in and pays better.
- **Squad size:** 1–4, tuned for 3. Enemy budget scales with headcount (see §Scaling).
- **On death:** you drop everything carried this run. Teammates can grab it. Your permanent stash is untouched. One self-revive item exists and is expensive.
- **On extract:** carried loot is banked to the stash and converted to credits at market rate. Rating updates. Run summary posts to telemetry.

**Individual extraction.** Each player extracts independently. One player leaving does not end the run for the rest — it makes it harder, because enemy budget does not scale back down mid-run. This is the social pressure point and it is deliberate.

## The level

Not fully procedural terrain — **procedurally assembled from hand-authored room modules**, which gives variety without the art cost or the pathfinding pathologies of noise-generated space.

- ~24 authored modules (12 at M2), each a sealed box with 2–4 tagged connector faces (`N/S/E/W`, `size: small|large`). Catalogue: `src/shared/config/Rooms.luau`.
- Assembly: seeded graph walk places a spine of 8–12 modules, then branches 4–6 dead-end rooms off it. Seed is per-run and logged, so any run is reproducible for debugging.
- Constraint solver guarantees: all three extraction pads reachable, no module repeated within 2 hops, total floor area within ±15% of target.
- Nav: baked `PathfindingModifier` volumes per module, stitched at connectors. Entities path on a coarse waypoint graph built at assembly time, not on Roblox `PathfindingService` per-entity (too slow at 40+ entities).

**As built (M2-1, `core/level/Assemble.luau`).** Five things the spec did not pin down, settled by making it run:

- **At most one connector per face.** The generator identifies a module's mating door by face alone; two connectors on one face would make that ambiguous. Enforced in `validate-config`.
- **A module lists *zones*, not a zone.** Corridors and junctions serve all three bands. With one zone each, every band would need four dedicated rooms just to satisfy the no-repeat-within-2-hops rule — 12 rooms of pure connective tissue before a single interesting one. Mirrors how `Enemies.zones` already works.
- **Spine and branch counts are searched, not drawn.** The spec asks for both a count in a fixed range and area within ±15%. Module areas span 1024–10752 studs², so counts drawn independently miss the area window on ~13% of seeds. The walk measures the area it actually achieves on its first pass and recomputes the count from that, which satisfies both constraints without a tuning constant. Counts still land in the documented 8–12 / 4–6 ranges.
- **Exactly one pad per zone**, at a random index inside that zone's band. "All three pads reachable" is checked by BFS from the entrance over every module, not just the pads.
- **Connectors sit at face midpoints**, which is what makes joined doorways coincide with no per-module offset table. This is now an authoring constraint on the Studio geometry: a doorway off-centre on its face will line up in the layout maths and visibly not in the level.

Area is derived as `width * depth` rather than authored, so the two cannot drift.

**Nav, as built (M2-3, `core/level/Path.luau`).** One waypoint per room centre
and one per doorway, ~35 nodes for a full level; A* with a euclidean heuristic.
Rooms never link directly to each other — a route between two rooms goes through
the doorway node, which is where the geometry forces you, so following
consecutive nodes in a straight line stays inside the level.

The "path length within 1.4× euclidean" constraint **does not hold and cannot**:
two rooms either side of a shared wall are 60 studs apart in a straight line and
several hundred studs of walking. It holds at the median (1.33) and the mean
(1.36); the worst single pair is 9.53×. Replaced by three checks that mean what
the original was reaching for — optimality against an independent Dijkstra (0
disagreements over 94,737 pairs), the median/mean bound, and a hard ceiling.
Numbers in [docs/metrics/m2.md](metrics/m2.md).

**Open design question: the level is a tree.** Spine plus dead-end branches gives
17 connections for 18 modules and no loops, so every route backtracks and a third
of waypoint pairs walk more than 1.4× the straight line. Loops cannot be closed
for free — measured 0 across 300 layouts, because face-midpoint connectors almost
never leave two unused doors coincident. Adding them means steering placement to
mate a module against two doors at once, which changes level topology and so is
a design call, not an implementation one.

**Zones.** Three depth bands (Perimeter / Processing / Vault). Deeper = better loot, more enemies, worse lighting, and the extraction pad that opens later.

## Enemies

Custom non-`Humanoid` entities — this is a netcode decision as much as a design one (see [03-NETCODE](03-NETCODE.md)). Roblox never network-owns them; the server does, fully.

| Name | Role | Behavior | Introduced |
|---|---|---|---|
| **Skitter** | swarm | fast, low HP, closes distance in packs | Perimeter |
| **Sentry** | area denial | static, tracks and suppresses, must be flanked | Perimeter |
| **Hauler** | tank | slow, heavy, blocks corridors, drops good loot | Processing |
| **Lancer** | ranged | keeps distance, forces you out of cover | Processing |
| **Warden** | elite | shields nearby enemies until killed; priority target | Vault |
| **Reclaimer** | pressure | spawns only via OVERSEER escalation, hunts the highest-weight player | any |

The Reclaimer is OVERSEER's most legible lever: it exists specifically so the director's decisions are *visible* to players. When OVERSEER says "I'm sending someone for the one carrying the most," a Reclaimer spawns and it is true.

Data-driven — `src/shared/config/Enemies.luau`:

```lua
Skitter = { hp = 45, speed = 22, dmg = 8,  atkRange = 4,  budget = 1, behavior = "SwarmNearest" },
Hauler  = { hp = 420, speed = 8,  dmg = 30, atkRange = 6,  budget = 5, behavior = "PushObjective" },
Lancer  = { hp = 90, speed = 12, dmg = 14, atkRange = 55, budget = 3, behavior = "KeepDistance", projectile = "Slug" },
```

`budget` is the currency the director spends. See [05-OVERSEER-DIRECTOR](05-OVERSEER-DIRECTOR.md).

## Weight — the core tension

Every loot item has `weight`. Total carried weight maps to a movement multiplier:

| Weight | Speed | Feel |
|---|---|---|
| 0–20 | 1.00× | free |
| 21–40 | 0.92× | noticeable |
| 41–60 | 0.82× | committed |
| 61–80 | 0.70× | in trouble |
| 81+ | 0.55× | you should have left |

You can drop items instantly (one keypress, no animation) — the decision is always available, which is what makes it agonizing. Dropped loot persists and is visible to everyone.

## Weapons

Four, each a distinct engagement range and a distinct netcode profile:

| Weapon | Mechanic | Why it exists technically |
|---|---|---|
| **Sidearm** | hitscan, fast, low damage | baseline lag-compensated hitscan |
| **Carbine** | hitscan, burst, medium | tests fire-rate validation under burst |
| **Slug** | projectile, travel time, drop | tests server-simulated projectiles (no rewind needed — projectile is an entity) |
| **Arc** | continuous beam, damage ramps on sustained target | tests per-tick continuous validation instead of discrete events |

Ammo is server-authoritative; the client predicts the decrement and reconciles.

### Field repair

There was no healing at all until now: a 100 HP pool (Roblox's Humanoid
default, never set by this project), its default ~1 HP/s
regeneration, and a twelve-minute run — so forty damage cost forty seconds of
walking it off, and one bad room was unrecoverable rather than expensive.

**[G] starts a 1.6-second channel and restores full health. Two charges, and
they do not refill.** The shape preserves the run's tension instead of removing
it. A regenerating heal turns every fight into attrition the player wins by
waiting; finite charges make "do I burn one here" a real question, which is the
same question the whole game is about.

It is a **press, not a hold**, and pressing again abandons a channel in
progress. It was a hold, briefly, and that was a trap: a tap started the
channel and the key release cancelled it milliseconds later, so the player
spent a charge, got a third of a hit point, and had nothing on screen saying
why. Pressing [G] *while already moving* is refused outright rather than
started and immediately cancelled — a refusal costs nothing, a cancel costs the
charge.

The heal is to full rather than a fixed number of points because a fixed heal
made a charge worth less the healthier you were, so the optimal play was to
walk around hurt waiting for one to be worth spending. Full heals move the
decision to *when*, and make the scarcity legible: two charges is two mistakes.
That also makes `charges` the only limit on healing in the game, which is why
it stays at two.

Health arrives continuously across the channel against `progress²` rather than
all at the end, so the bar moves from the first frame — but the final third
carries more than the first two thirds combined, so finishing still matters.

**Moving cancels it, taking damage cancels it, and the charge is not
refunded.** Refunding would make a cancelled channel free, so the correct play
would be to start one every time you were hit and cancel it. Losing the charge
means you commit.

The channel is deliberately shorter than the sweep's cooldown, so the intended
sequence — sweep to make space, heal in it — is possible once per cooldown
rather than freely.

### The sweep

Every weapon above is a ray, which leaves one hole in the fight: a Skitter
swarm closing to four studs is a target you cannot miss and cannot clear,
because one hitscan round kills exactly one of them.

**[F] sweeps a 120-degree arc, 12 studs, on a 3.5-second cooldown.** It is
shaped as an escape rather than a damage upgrade: 55 damage kills a Skitter
outright and takes a third off a Lancer, but it does not meaningfully dent a
Warden's 700. It buys space; it does not win a fight with an elite.

Two rules keep it from becoming a primary weapon. The arc is measured from the
*body's* facing, not the camera, so a player cannot hit something behind them
by flicking the mouse. And reach is measured to the near surface of a target's
hitbox rather than its centre, so a wide enemy is caught from further out than
a narrow one — measuring to centres would make big enemies *harder* to sweep
than small ones, which is backwards.

The request carries nothing: no position, no direction, no target list. The
server takes all three from the character. That is not caution for its own
sake — unlike a fire request there is no ray to sanity-check an origin
against, so a client-supplied one would let anyone sweep any room in the level
from the drop point. An empty request makes the forgery impossible rather than
merely detectable.

## Objectives

OVERSEER issues one active objective at a time, chosen from a **whitelist** the model may pick from but never invent:

| ID | Ask | Reward |
|---|---|---|
| `purge_node` | Destroy a marked processing node | credits + spawn lull |
| `hold_terminal` | Stand in a zone for 45 s | rare loot cache |
| `escort_cart` | Move a slow cart to a pad | large payout, heavy pressure |
| `no_loot_window` | Extract nothing for 90 s | multiplier on next payout |
| `hunt_warden` | Kill a specific marked elite | unique cosmetic drop chance |

The model chooses *which* and sets bounded parameters. It cannot author a new objective, and it cannot set rewards outside the clamped table.

## Scaling

```
enemyBudget(t, n) = BASE * zoneMul(depth) * timeRamp(t) * headcountMul(n) * directorMul
timeRamp(t)       = 1 + 0.9 * (t / 720)                    -- +90% across a full run
headcountMul(n)   = 0.6 + 0.4 * n                          -- 1p = 1.0, 3p = 1.8, 4p = 2.2
directorMul       ∈ [0.6, 1.6]                             -- OVERSEER's only spawn lever, hard-clamped
```

`BASE = 12`. Budget is spent on enemy `budget` costs by a weighted picker respecting per-type caps and zone availability. Everything except `directorMul` is deterministic and testable in pure Luau.

### Survivability

Left unstated until a play session came back as "impossible to beat", which it measurably was. These are the targets the balance tests now enforce.

| Rule | Target | Why |
|---|---|---|
| Worst-case engagement | player survives **≥ 1.5 s** at full health | Enough to identify the threat and start moving. Below this, death precedes reaction. |
| One-on-one, non-elite | winnable with the **starting Sidearm** | Anything the baseline planner sends at a lone player must be beatable with what that player actually has. |
| One-on-one, elite (`budget ≥ 8`) | winnable with **some reachable weapon** | Wardens and Reclaimers are squad content; they may beat a Sidearm, but not every weapon. |

"Worst case" is modelled on what can physically engage, not on a naive sum of per-type caps: melee kinds are limited to the **six** bodies that fit around one player, while ranged kinds may all hold a sightline at once but are subject to falloff at the distance they hold it from. Summing `capPerWave` assumes 24 Skitters touch you simultaneously, which no geometry allows.

**Enemy attacks require line of sight**, checked by the same raycast against level geometry that validates player shots. Without it there is no cover, no way to break contact, and a Sentry's 45-stud range means an entire wing of the facility is under fire at once.

**Ranged kinds fall off with distance; melee kinds do not.** A Skitter biting at 3.9 studs is not weaker than at 1 stud. A Sentry at the edge of its envelope should suppress rather than execute.

### Cadence

The formula above is a **standing pressure level, not a per-wave allowance** — this was left unstated until the spawner was actually wired, and it is the load-bearing half. Read as a per-wave grant, `timeRamp` would mean the *rate* of spawning compounds, which buries the level in enemies by minute eight. Read as a target population, it means "this much enemy should be alive right now", which is what the curve is shaped like.

So a wave **tops the live population back up toward the target** rather than adding to it. The outstanding budget is `target − aliveValue`, where `aliveValue` is the summed cost of everything currently breathing. Corpses do not count: a body on the floor is not pressure.

| Tunable | Value | Why |
|---|---:|---|
| `INTERVAL_SECONDS` | 12 | Minimum spacing between waves |
| `FIRST_WAVE_DELAY_SECONDS` | 20 | Longer than the interval — dropping into a fight before the player has their bearings reads as unfair rather than tense |
| `MAX_ALIVE` | 40 | Hard population ceiling, independent of budget. Matches docs/08's profiled frame budgets and sits above the netcode's 32-entity interest cap |
| `MIN_WAVE_BUDGET` | 3 | Without a floor, one kill re-opens the budget and the next wave trickles a single Skitter in, which reads as popping rather than as a wave |

**`INTERVAL_SECONDS` is a minimum, not a guarantee.** A wave fires only if the outstanding budget clears `MIN_WAVE_BUDGET` when the interval expires; otherwise it re-arms and re-checks a full interval later. Measured in-engine: with the first wave at 20.06 s, the second landed at 44.03 s rather than 32 s, because outstanding pressure did not clear the floor until the time ramp had grown the target. Pacing is driven by what is still alive, not by the clock alone.

The **Reclaimer is spawned outside this budget**, and only when the director's `spawnPattern` is `hunt_heaviest` and none is already alive. It is `directorOnly`, so the weighted picker never selects it — this is the sole path that produces one, which is what makes the director's decision legible to players as the design intends. The consequence is that a Reclaimer overshoots the standing target by its cost of 8 and suppresses the next wave or two; that is self-correcting and intended, since a Reclaimer *is* the pressure.

## Economy surface (design view; mechanics in [07-ECONOMY](07-ECONOMY.md))

- **Credits** — soft currency. Faucets: extraction payout, objective bonus, first-extract-of-day. Sinks: gear repair, ammo, insurance, market fee, cosmetics.
- **Salvage** — the actual items. Tradeable on a consignment market with escrow. Never purchasable with real money.
- **Insurance** — pay before drop, recover a fraction of carried loot on death. A sink that directly modulates risk appetite, which makes it the most interesting knob in the whole economy.

## What is explicitly not in scope

Stated so it doesn't creep in: PvP, base building, crafting trees, seasons/battle pass, voice chat, mobile-specific UI, cross-place inventory beyond the lobby. Each is defensible and none of them serve the six systems this project exists to demonstrate.
