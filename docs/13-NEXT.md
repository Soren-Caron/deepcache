# 13 — Next

Working notes for picking this back up. Ordered by what most changes the
experience, not by what is easiest.

Branch: **`feat/wave-spawner`**, **16 commits ahead of `master`, unmerged.**

```
(this)   Add runRestart, fix sprint-after-respawn and third-person aim parallax
76364c5  Fix enemy hitboxes, third-person aim, enemy shot visuals; add sprint
4f81360  Make weapons reloadable (R, auto on empty, timed)
80eef40  Stop enemies hunting in and out of attack range
d3b7de3  Plant enemies on the floor and retune the walk cycle
856ac8b  Replace IK limbs with an R6 skeleton matching the player
e6e9fd2  Plan humanoid rigs (docs/14)
870a534  Fix knee pole and bound planted feet to leg reach
5c9dc27  Update next-steps: rigs done, animation budget now tight
22fd807  Give enemies bodies and the level a per-zone palette
3cb3cbd  Add docs/13-NEXT.md handoff notes
06618ce  Game feel pass: per-kind enemies, crosshair, hitmarker, hit feedback
091c16c  Fix unwinnable difficulty and invisible attackers
4cb65eb  Fix enemy grounding, facing, and crowd spacing
ff9f3b1  Make enemies actually deal damage (M2-4 adapter half)
a0d484d  Wire the enemy budget into real spawns (M2-8 adapter half)
```

State: **935 pure-core · 139 backend** tests green, 146 files pass syntax and
encoding, `rojo build` clean.

**The branch is the largest outstanding decision here.** Sixteen commits, every
one of which is a bug the game visibly had, sitting on a branch named after the
first of them. Merging it is not a formality.

---

## 1. Unverified, verify first

~~**Sprint has never been driven by an actual key press.**~~ Verified with
`user_keyboard_input`. WalkSpeed 16 → 25.60 (16 × 1.6), full bar to empty in
4.65 s against a configured 4.55, regen 14.1/s against a configured 14, speed
dropping back to 16 the frame the bar hit zero. Two full drain/recover cycles
from a *single* `InputBegan`, which is the stutter cycle
`tests/stamina.spec.luau` asserts, now observed in the engine.

The trace also caught a real bug, since fixed: `held` was a latch fed only by
InputBegan/InputEnded, and `CharacterAdded` cleared it — so **sprint was dead
after every respawn** until the player released and re-pressed shift. It now
polls `IsKeyDown`, which cannot desync from the keyboard.

Guard impact measured by A/B: 9 s of sprinting produced 4 violations and 0
corrections; 9 s of *walking* the same path produced the same 4. Sprint is
guard-neutral. Those 4 are pre-existing background noise that decays and has
never reached the correction threshold of 5 — unexplained, not caused by
sprint, and worth a look if it ever climbs.

~~**The hurt vignette has never been seen firing.**~~ Verified: 5 flashes,
32 tinted frames, peak transparency 0.380 against the authored
`1 - HURT_PEAK_TRANSPARENCY` = 0.38, colour RGB(150, 20, 20), each flash
tracking an HP drop (100 → 76 → 52 → 29 → 6) with the quadratic fade visible
across ~0.45 s.

The reason it had never fired is worth keeping: **the probe was being run
after the player had already died**, so the run was `complete`, and
`EnemyCombatService`'s strike predicate correctly refused every attack —
`livingTargets()` returned nothing and the probe reported 0 strikes with no
error. The doc blamed the probe. It was §3's dead run all along. Run
`runRestart` first and it lands 13 strikes.

~~**The hitmarker has never been seen firing either.**~~ Verified with
`user_mouse_input`: 4 clicks, 4 confirmed hits, 4 hitmarker appearances, each
within ~10 ms of its `FireResult`. Two things make this reproducible, and both
cost hours to find:

- **`GetGuiInset()` is (0, 58) here.** `user_mouse_input` takes
  inset-*excluded* coordinates; `GetMouseLocation` returns inset-*included*
  ones. Clicking at a raw `WorldToViewportPoint` aims 58 px high.
- **Aim at a kind that does not move.** Only the Sentry is planted. Against a
  Hauler or Warden the target has walked out from under the cursor by the time
  the click arrives, and the resulting miss looks exactly like a broken
  hitmarker.

**The R6 rig's animation cost has not been re-profiled.** The IK rig measured
1.494 ms against a 2.0 ms budget; rigid limbs should be cheaper, but "should
be" is not a measurement, and the M7-10 figure in `docs/metrics/m7.md` is
stale either way.

---

## 2. Things that are wired but hollow

**No audio — but the layer is built and the blocker is now only asset
selection.** M7-8. `core/audio/Cues` (throttle, pitch jitter, attenuation,
tested), `config/Audio` (15 cues), and `client/AudioController` are all in, and
every cue point is wired: firing, hit confirm, dry fire, reload start/finish,
taking a hit, enemy fire, enemy death, pickup, pad open, run end.

**Every `assetId` is deliberately empty.** Searching the Creator Store for free
weapon audio returned user uploads with no usable provenance — the top results
included one whose own description says it came from *The Elder Scrolls IV:
Oblivion*. Shipping those trades a silent game for a copyright problem in the
one artefact meant to be shown to employers.

Because a wired-but-assetless layer and an unwired one are both silent, the
controller counts: `SoundService.DeepcacheAudio` carries live attributes.
Verified during real combat — **`requested=14, playedNoAsset=6,
suppressedByThrottle=8`**, i.e. 13 `hitTaken` cues plus one `runEnd`, of which
8 were correctly throttled. The path is reachable and the throttle works.

Filling the table in is the whole remaining task; nothing else has to change.

~~**No damage direction indicator.**~~ Landed. `EnemyCombatService` fires a
per-strike `DamageFrom` to the struck player alone; the HUD draws a chevron
rotated by `core/look/DamageArc`. Verified against real Sentry fire: **17
strikes produced 17 events and exactly 1 arrow**, because the merge rule
collapses attackers on a similar bearing rather than ringing the player in
chevrons. Rotation read −179.8° for a shooter almost directly behind, the fade
ran 1.00 → 0.82 smoothly, and the layer was empty again after expiry.

The arrow stores the attacker's **world position**, not a screen angle, and
re-derives the bearing each frame. A stored angle keeps pointing at where the
shooter was relative to where the player *used to be* facing, so turning
toward the arrow swings it further away — worse than no arrow.

**Props are not cover.** The level now has set dressing (see
[docs/08 §0](08-PRESENTATION.md)), and it collides so you cannot walk through
it — but `CanQuery = false`, so shots and enemy line-of-sight pass straight
through and combat is bit-for-bit what it was before. Making props real cover
is the obvious next step and a better game, but it moves damage numbers and
invalidates the §5 difficulty pass, so it deserves its own measurement rather
than arriving as a side effect of a look pass.

~~**Nothing teaches weapon switching or reloading.**~~ Partly addressed. A
legend (`[1-4] weapons  [R] reload  [SHIFT] sprint`) shows for the first 45
seconds, and `[R] RELOAD` appears whenever the magazine is empty. Still no
*pressure* to switch — no ammo economy — so this teaches the controls, not the
tactic.

~~**Enemies should be humanoid.**~~ Landed in `856ac8b`. R6 rigid limbs, the
same skeleton the player character uses; see
[docs/14-HUMANOID-RIGS.md §0](14-HUMANOID-RIGS.md) for why the IK plan in that
same document is wrong.

---

## 3. Known bugs and rough edges

~~**Enemies died into a grey crate.**~~ Reported as "when I sweep kill enemies
it spawns these in their place", and it was the same drift as the hitbox bug.
`RagdollController` was written at M7-4 when entities really were boxes, so the
corpse was a hardcoded 2x2x3 slate part in a fixed brown-grey. The R6 rigs
landed later in `856ac8b` and this was never revisited — a Skitter and a Warden
both died into the same crate.

Corpses are now sized from the kind's own `hitboxRadius` and coloured from the
same palette the renderer uses. Verified by firing one `Ragdoll` payload per
kind: Skitter 2.40x1.68x3.24 red, Lancer 3.00x2.10x4.05 green, Warden
6.00x4.20x8.10 violet.

~~**No healing mechanism at all.**~~ There genuinely was none: 100 HP, Roblox's
default regeneration, and no item, ability or pickup anywhere in `src/`. Forty
damage cost forty seconds of walking it off, which is a large part of why a run
ended in 59 seconds.

**[G] now holds a 2.5s channel for 45 HP, two charges, no refill.** Moving or
taking damage cancels it and the charge is *not* refunded — refunding would make
cancelling free, so the right play would be to start one on every hit and cancel
it. Verified: HP 40 with a real key press healed exactly 45.0 (`completed=1`);
a hit mid-channel gave `interrupted=1` with `completed` unchanged and no health
applied; and the HUD read `[G]x0` afterwards, confirming both charges were spent
by one completion and one interrupt.

The channel sits under the sweep's 3.5s cooldown on purpose, so sweep-then-heal
is possible once per cooldown rather than freely.

~~**Ranged enemies attack from outside the fog.**~~ Reported from play as "the
ranged guys shoot from very far away", and it was real. Enemy reach is authored
per kind while visibility is authored per zone, and nothing reconciled them:

| zone | fog ends at | Sentry 45 | Lancer 55 |
|---|---:|---|---|
| Perimeter | 180 | fine | fine |
| Processing | 90 | fine | fine |
| **Vault** | **45** | on the boundary | **shoots from inside the fog** |

A Lancer in the Vault opened fire from 55 studs into a world the renderer stops
drawing at 45. Being hit by something you could never have seen reads as the
game cheating rather than as a threat you misplayed.

Reach is now capped at `fogEnd * ATTACK_VISIBILITY_FRACTION` (0.8) for the zone
the *attacker* stands in — the shooter is the one who has to be seeable.
Verified in the Vault, where the cap is 36: a Lancer at 50 studs lands **0
strikes**, the same Lancer at 25 lands **4 strikes for 51 damage**.

**Studio "lag" was the laptop, not the game.** Worth writing down because the
measurement looked alarming and meant nothing: 12 fps, pinned at exactly 83.3 ms
across 540 frames, identical with all 63 lights disabled *and* with every entity
rig deleted. GPU 0.00-1.1 ms while CPU sat at 84 and physics held 60. That is a
throttle, not a load — the machine was **on battery at 60% on the Balanced power
scheme**, and Roblox's `FrameRateManager = Automatic` throttles on battery.
Studio was already on the RTX 5070 (confirmed via `nvidia-smi`), so it was never
a GPU-routing problem either. Plug in before profiling anything, and before
recording.

~~**A run ends permanently on player death.**~~ Cheap fix landed:
`bridge:Invoke("runRestart")` clears entities, resets the wave scheduler and
enemy cooldowns, revives or respawns the roster, restarts the clock, and
re-pushes carry so the HUD's weight bar and WalkSpeed are not left stale.
Verified: `complete=true, active=0, died=1, lastReason=run_inactive` →
`complete=false, active=1, died=0, lastReason=cooldown`, and the HUD goes from
`LOST — everything you carried is on the floor` with the crosshair hidden back
to `0 carried · 0 credits at risk` with crosshair and stamina bar visible. No
client change was needed; the 1 Hz `RunState` push does it.

~~**A real lobby/redeploy loop is still the honest fix**~~ — now player-facing.
A `REDEPLOY [ENTER]` control appears when the run ends, sends `RedeployRequest`,
and the server validates it against the pure `Run.canRedeploy`. Verified end to
end: refused `run_in_progress` mid-run, refused `too_soon` 1.3 s after the run
ended, granted at 2.8 s, and **Enter alone restarted the run** (`complete=false,
active=1, died=0`, entities cleared).

Only once the run is *over*, never on individual death — a player whose
teammates are still alive stays dead and spectates, or carrying loot out means
nothing.

**The button itself is unverified, and there is a reason it is not the only
path.** Roblox `GuiObject` events cannot be driven from the Studio automation
bridge: a synthetic click lands provably inside the button's rect (cursor at
697,307 in a rect spanning 567–827 × 281–333) and emits nothing at all, not
even `MouseEnter`. The remote fired by hand works, and Enter works, so the
server half and the client half are both proven — but on a branch with this
much built-and-never-connected history, the primary path should be one a test
can reach. Hence the keybind.

A lobby place with a proper redeploy flow is still the shape this wants
eventually; this is the version that makes a 4-person playtest possible.

**Shots ignored enemies when aiming past them.** Fixed, and the numbers are
worth keeping because they explain "sometimes the bullet doesn't hit them".
Enemy rig parts are `CanQuery = false`, so `aimPoint`'s raycast passed through
every enemy and stopped on the backdrop; the shot then left the *shoulder*
aimed at that far point, and the camera is 12.59 studs behind it. Measured
against a Sentry (radius 2.2) at 26 studs:

| backdrop distance | shot misses centre by | outcome |
|---:|---:|---|
| 40 | 0.21 | hit |
| 80 | 1.94 | hit, barely |
| 120 | 2.39 | **miss** |
| 2000 (open sky) | 3.11 | **miss** |

So a corridor forgave it completely and an open hall never did — which is
exactly the shape of an intermittent bug. `aimPoint` now intersects the entity
spheres with the same pure `core/sim/Raycast` the server judges the shot with,
via `EntityRenderer.aimTargets()`. Same shot afterwards: 0.28 off centre.
Pinned by `tests/raycast.spec.luau` §third-person aim parallax.

Note this is *not* what made the hitmarker verification pass — that was the
GUI-inset correction above. The parallax bug was found while chasing it.

**Warden's hittable fraction got slightly worse.** The hitbox/rig-height fix in
`76364c5` cut unhittable body from 1.00 → 0.14 studs on a Skitter and 1.60 →
0.20 on a Lancer, but moved the Warden 0.20 → 0.39. The residue is the top of
the head, where a sphere has little horizontal extent anyway. Not zero, and not
claimed to be.

~~**Movement stutters and cancels itself, especially on jump or sprint.**~~
Reported from play, and it was two guard bugs stacked.

*Measuring the network instead of the player.* The guard sampled a replicated
position on its own fixed tick and divided by that tick's dt — but positions
arrive in bursts, so some ticks saw nothing and the next absorbed two packets'
worth. An honest player walking at 16 produced per-tick samples of 24.5, 27.0
and 29.9 studs/s against a 21.6 allowance. Roughly one false violation a second
against a decay of one a second, so the score ratcheted upward instead of
settling. Speed is now judged over a **0.75 s window**, which is immune to
bursting and still catches a hack, because a hack sustains.

The same window fixed a second race for free: the client raises its own
WalkSpeed the instant sprint starts and only *then* tells the server, so for one
round trip the guard budgeted 16 against a player doing 25.6. The window uses
the most permissive allowance it saw, so a sprint that began anywhere inside it
is budgeted as a sprint.

*Corrections without evidence.* Far worse. The action branch read only the
standing score, so once it crossed `correctAt` **every subsequent tick issued
another correction** until the score decayed back under — at 1/s from a
threshold of 5, that is seconds of being teleported to your previous position
20 times a second. Live session: **7 violations produced 109 corrections.**
That is not a correction, it is being pinned in place, and it is exactly the
reported symptom. A correction now requires a violation *this* evaluation; the
score still decides whether a fresh one is worth acting on.

Verified: the identical input that produced 6 violations now produces 0, and
the probe that produced 7/109 now produces 0/0. The guard still bites — a real
client-side WalkSpeed hack at 90 was caught at 68–110 studs/s against a 21.6
allowance, 8 violations and 7 corrections, score escalating 5.3 → 16.6 toward
the kick threshold.

**Note the pure tests did not catch either bug**, and could not have: both live
in the relationship between a fixed server tick and a bursty replication
stream, which no unit test was modelling. There are now tests for both — and
the first regression test written for the correction bug **passed against the
bug**, because a single teleport lands the score exactly on the threshold and
one decay tick drops it under. It only became a real test once it pushed the
score clear of the threshold. A regression test that has never been run against
the regression is a guess.

**`onDespawn` releases the part but never removes the entity from
`baseline`.** Harmless today because the next snapshot re-adds it, but the
client's baseline can only grow within a run.

~~**`spawn` diagnostic rings the world origin, not the player.**~~ `spawnAt`
added alongside it: rings the *player*, faces the character's look vector, and
lifts each entity by its own `hitboxRadius` so the sphere is not half-sunk in
the floor. `spawn` is left as it was — several older notes quote its output.

---

## 4. Documentation that contradicts itself

~~**`docs/11-INTERVIEW-ARTIFACTS.md` states planning-era numbers as
measurements.**~~ Fixed. Every figure now cites where it was measured or
carries `[TARGET]`, and the file opens by saying so.

The worst of them was a résumé line claiming "p95 queue waits under 30 s in
simulation" when `metrics/m5.md` had measured **42.8 s and recorded a FAIL** —
an overclaim in material written for job applications, contradicted by this
repo's own data. The `$0.08/run` figure was stale in a different way: the
project moved to self-hosted Ollama, so marginal cost is ~zero, while the real
story is the **~50% fallback rate against a <3% target** and a deliberate
refusal to relax the 1200 ms budget to improve it. `resume.md` had all of this
right the whole time; only docs/11 was wrong.

**`resume.md` is untracked.** It exists at the repo root and is not in git.

---

## 5. Balance, now that it is playable

The numbers were set to clear the guards in `tests/enemyAttack.spec.luau`
(documented in docs/01 §Scaling → Survivability), not from play.

| Knob | Current | Note |
|---|---|---|
| Player HP | 100 | No armour, no mitigation, ~1 HP/s regen |
| Sentry cooldown | 0.75 s | Was 0.35 (31.4 dps); may still be high in packs |
| Hauler `capPerWave` | 3 | Was 4; a 30-damage swing means 4 hits is a kill |
| Wave interval | 12 s | A *minimum*, not a guarantee — gated on outstanding budget |
| `MAX_ALIVE` | 32 | Pinned to `INTEREST_MAX`; do not raise independently |
| `SPRINT_MULTIPLIER` | 1.6 | Untuned by play; multiplies the carry penalty |

Sprint changes disengagement in a way none of these numbers account for: a
player who can outrun a Skitter has a new answer to every fight the difficulty
pass assumed they had to take.

---

## 6. Still open from earlier milestones

- **M0-8** — publish the place; enable *Allow HTTP Requests* and *Studio Access
  to API Services*; create the `Lobby` place. Blocks M5-3/M5-6/M5-7 (the
  matchmaking teleport path has never run against two real places) and the
  `EditableImage` ramps, which compute correctly but cannot be displayed.
- **M6-11** — deploy the backend. Roblox production servers cannot reach
  `localhost`, so the director and telemetry are Studio-only until this lands.
- **M7-6 / M7-8** — outlines and audio. Both asset work.
- **M7-11 / M7-13** — playtest with 4+ humans, and the demo video. Both are
  gated on M0-8 and on the death/restart problem in §3.

---

## 7. The pattern worth remembering

Seven separate features in this branch were **fully built and never
connected**: the budget planner, enemy damage, `entity.targetId`, weapon
switching, the hitmarker hooks, reload, and `Enemies.Lancer.projectile`. Each
looked complete from the code and was invisible in play.

Two more were **dropped in transit**: `kind` and `hpPct`, both silently
discarded by `Interpolator`'s hand-built `Sample` while every snapshot
round-trip test passed.

Two more were **authored twice and allowed to drift**: rig height and
`hitboxRadius` described the same body from different files, so a Lancer had
1.6 studs of head that could not be shot.

And one was **invisible to the tool that was supposed to find it**: enemy rig
parts are `CanQuery = false`, so the client's aim raycast could not see the
things the player was aiming at, and the shot silently used a point behind them
instead. Nothing errored; the aim was simply wrong by an amount that depended
on the room.

A newer entry in the same ledger: **three separate features looked broken and
were not**. The vignette, the hitmarker, and `enemyDamageProbe` were all
working the whole time — hidden behind a dead run, a 58-pixel GUI inset, and a
target that had walked away. Before concluding a feature is broken, check that
the harness is telling the truth: prove the *setup* holds (is the run live? is
the cursor where you think?) before believing the measurement.

When something seems missing in-game, check the wiring before the logic — and
prefer a probe registered from the live context over anything `require`d from
the command bar, which returns a fresh idle copy whose entities no tick phase
ever steps. That trap produced two invalid test results in this branch alone.
