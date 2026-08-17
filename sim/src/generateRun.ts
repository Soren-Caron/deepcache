/**
 * Pure generation of one run's worth of envelopes. No network, no clock read
 * -- `nowSeconds` and the `Rng` are both injected, so a seed reproduces the
 * exact same run byte-for-byte. Mirrors the game's own "core has no clock,
 * time is a parameter" rule, for the same reason: a simulator that is not
 * reproducible cannot reproduce the dashboard bug it just caused.
 */

import type { ItemDef } from "./items.js";
import { ITEMS, valueOf } from "./items.js";
import type { Archetype } from "./archetypes.js";
import { ARCHETYPES } from "./archetypes.js";
import type { Rng } from "./rng.js";

export interface Envelope {
  v: number;
  ts: number;
  runId: string;
  serverId: string;
  placeId: number;
  pid: string | null;
  type: string;
  seq: number;
  p: Record<string, unknown>;
}

export interface Player {
  readonly pid: string;
  readonly archetype: Archetype;
}

const PLACE_ID = 1;
const RUN_LENGTH_SECONDS = 720;
const ZONES = ["Perimeter", "Processing", "Vault"] as const;
const WEAPONS = ["Sidearm", "Carbine", "Slug", "Arc"] as const;

function pickItem(rng: Rng): ItemDef {
  // Same shape as core/sim/Loot.rollItem: rarity weighted, common most
  // likely, prototype rare. Not the exact per-zone weights from
  // config/Loot.luau -- this only needs to be plausible, not load-bearing.
  const roll = rng.nextFloat();
  const rarity = roll < 0.55 ? "common" : roll < 0.85 ? "uncommon" : roll < 0.97 ? "rare" : "prototype";
  const candidates = ITEMS.filter((item) => item.rarity === rarity);
  return rng.pick(candidates);
}

/**
 * Generates one run's envelopes for a squad. `seq` is per (run_id,
 * server_id), starting fresh at 1 for every run -- matching
 * `core/telemetry/Buffer.push`, which numbers from 1 per buffer, and this
 * function stands in for one game server's buffer over one run's lifetime.
 */
export function generateRun(
  rng: Rng,
  runId: string,
  serverId: string,
  players: readonly Player[],
  startTs: number,
): Envelope[] {
  const events: Envelope[] = [];
  let seq = 0;
  const push = (type: string, ts: number, p: Record<string, unknown>, pid: string | null = null): void => {
    seq += 1;
    events.push({ v: 1, ts, runId, serverId, placeId: PLACE_ID, pid, type, seq, p });
  };

  const seed = rng.nextRange(1, 1_000_000);
  push("run.start", startTs, { seed, squadSize: players.length, lengthSeconds: RUN_LENGTH_SECONDS });

  // How long each player actually stays in -- a run can end before 720s if
  // everyone has already resolved, same as a real squad clearing out early.
  const outcomes: Array<{
    player: Player;
    extracted: boolean;
    tSeconds: number;
    carriedValue: number;
    carriedWeight: number;
  }> = [];

  for (const player of players) {
    const durationFraction = 0.35 + rng.nextFloat() * 0.6;
    const tSeconds = Math.floor(RUN_LENGTH_SECONDS * durationFraction);

    // Combat: fires scaled by the archetype's rate over the time they were
    // actually in the level.
    const minutesPlayed = tSeconds / 60;
    const fires = Math.round(player.archetype.firesPerMinute * minutesPlayed * (0.6 + rng.nextFloat() * 0.8));
    for (let i = 0; i < fires; i += 1) {
      const ts = startTs + rng.nextRange(1, Math.max(1, tSeconds));
      const weapon = rng.pick(player.archetype.preferredWeapons.length > 0 ? player.archetype.preferredWeapons : WEAPONS);
      const rttMs = rng.nextRange(20, 320);
      push("combat.fire", ts, { weapon, kind: weapon === "Slug" ? "projectile" : weapon === "Arc" ? "beam" : "hitscan", rttMs }, player.pid);

      if (rng.chance(player.archetype.accuracy)) {
        const damage = rng.nextRange(15, 70);
        push(
          "combat.hit",
          ts,
          {
            weapon,
            targetKind: rng.pick(["Skitter", "Sentry", "Hauler", "Lancer", "Warden"]),
            damage,
            distance: rng.nextRange(3, 90),
            headshot: rng.chance(0.15),
            died: rng.chance(0.2),
            shielded: rng.chance(0.05),
          },
          player.pid,
        );
      }
    }

    // Loot: scaled by greed. Weight accumulates until it either clears the
    // cap (this player is now "in trouble", docs/01's own vocabulary) or the
    // run ends.
    let carriedWeight = 0;
    let carriedValue = 0;
    const pickups = rng.nextRange(2, 14);
    for (let i = 0; i < pickups; i += 1) {
      if (carriedWeight >= player.archetype.greedWeightCap) break;
      const item = pickItem(rng);
      const ts = startTs + rng.nextRange(1, Math.max(1, tSeconds));
      const value = Math.round(valueOf(item));
      carriedWeight += item.weight;
      carriedValue += value;
      push(
        "loot.pickup",
        ts,
        { itemId: item.id, rarity: item.rarity, weight: item.weight, value, totalWeight: carriedWeight },
        player.pid,
      );
    }

    // Whether they get out: the archetype's base chance, penalised the
    // further over its own greed cap this run happened to go -- greed
    // does not kill by fixed odds, it kills by how far you pushed it.
    const overCap = Math.max(0, carriedWeight - player.archetype.greedWeightCap);
    const extractChance = Math.max(0.05, player.archetype.extractChance - overCap * 0.01);
    const extracted = rng.chance(extractChance);

    outcomes.push({ player, extracted, tSeconds, carriedValue, carriedWeight });
  }

  for (const outcome of outcomes) {
    const ts = startTs + outcome.tSeconds;
    if (outcome.extracted) {
      const zone = rng.pick(ZONES);
      push("extract.success", ts, { zone, tSeconds: outcome.tSeconds, carriedValue: outcome.carriedValue }, outcome.player.pid);
    } else {
      push("player.death", ts, { droppedValue: outcome.carriedValue }, outcome.player.pid);
    }
  }

  // A couple of perf samples through the run, in the range actually measured
  // in Studio (docs/metrics/m1.md, m2.md): comfortably under budget, with
  // occasional noise.
  const sampleCount = rng.nextRange(2, 4);
  for (let i = 0; i < sampleCount; i += 1) {
    const ts = startTs + rng.nextRange(1, RUN_LENGTH_SECONDS);
    const p50 = 0.08 + rng.nextFloat() * 0.15;
    push("perf.tick", ts, {
      p50,
      p95: p50 + rng.nextFloat() * 0.3,
      p99: p50 + rng.nextFloat() * 0.6,
      overruns: rng.chance(0.03) ? 1 : 0,
      ticks: 1200,
      entityCount: rng.nextRange(8, 42),
    });
  }

  const endTs = startTs + Math.max(...outcomes.map((o) => o.tSeconds), 1);
  const extracted = outcomes.filter((o) => o.extracted).length;
  const deaths = outcomes.length - extracted;
  const valueExtracted = outcomes.filter((o) => o.extracted).reduce((sum, o) => sum + o.carriedValue, 0);
  push("run.end", endTs, {
    outcome: deaths === outcomes.length ? "timeout" : "squadResolved",
    durationSeconds: endTs - startTs,
    extracted,
    deaths,
    valueExtracted,
    squadSize: players.length,
  });

  return events;
}

export { ARCHETYPES };
