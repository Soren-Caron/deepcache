import { describe, expect, it } from "vitest";
import { ARCHETYPES, generateRun, type Player } from "../src/generateRun.js";
import { Rng } from "../src/rng.js";

/**
 * Pure generation, no network -- structural correctness of what the network
 * layer will send, checked independently of whether a backend is even
 * running.
 */

function squad(size: number): Player[] {
  return Array.from({ length: size }, (_, i) => ({
    pid: `test-player-${i}`,
    archetype: ARCHETYPES[i % ARCHETYPES.length] as (typeof ARCHETYPES)[number],
  }));
}

describe("generateRun", () => {
  it("is deterministic for a given seed", () => {
    const a = generateRun(new Rng(42), "run-a", "server-a", squad(3), 1_700_000_000);
    const b = generateRun(new Rng(42), "run-a", "server-a", squad(3), 1_700_000_000);
    expect(b).toEqual(a);
  });

  it("produces different output for different seeds", () => {
    const a = generateRun(new Rng(1), "run-a", "server-a", squad(3), 1_700_000_000);
    const b = generateRun(new Rng(2), "run-a", "server-a", squad(3), 1_700_000_000);
    expect(b).not.toEqual(a);
  });

  it("starts with run.start and ends with run.end", () => {
    const events = generateRun(new Rng(7), "run-x", "server-x", squad(2), 1_700_000_000);
    expect(events[0]?.type).toBe("run.start");
    expect(events[events.length - 1]?.type).toBe("run.end");
  });

  it("numbers seq monotonically from 1 with no gaps", () => {
    const events = generateRun(new Rng(7), "run-x", "server-x", squad(4), 1_700_000_000);
    events.forEach((e, i) => expect(e.seq).toBe(i + 1));
  });

  it("stamps every envelope with the shape backend/src/ingest/validate.ts requires", () => {
    const events = generateRun(new Rng(7), "run-x", "server-x", squad(3), 1_700_000_000);
    for (const e of events) {
      expect(e.v).toBe(1);
      expect(Number.isFinite(e.ts)).toBe(true);
      expect(e.ts).toBeGreaterThan(0);
      expect(e.runId).toBe("run-x");
      expect(e.serverId).toBe("server-x");
      expect(Number.isInteger(e.placeId)).toBe(true);
      expect(typeof e.type).toBe("string");
      expect(e.type.length).toBeGreaterThan(0);
      expect(Number.isInteger(e.seq)).toBe(true);
      expect(typeof e.p).toBe("object");
    }
  });

  it("produces exactly one run.end per run, with a squad-sized outcome", () => {
    const events = generateRun(new Rng(3), "run-y", "server-y", squad(4), 1_700_000_000);
    const ends = events.filter((e) => e.type === "run.end");
    expect(ends).toHaveLength(1);
    const payload = ends[0]?.p as { extracted: number; deaths: number; squadSize: number };
    expect(payload.extracted + payload.deaths).toBe(payload.squadSize);
    expect(payload.squadSize).toBe(4);
  });

  it("gives every player exactly one resolution: extract.success or player.death, never both, never neither", () => {
    const players = squad(4);
    const events = generateRun(new Rng(11), "run-z", "server-z", players, 1_700_000_000);
    for (const player of players) {
      const resolutions = events.filter(
        (e) => e.pid === player.pid && (e.type === "extract.success" || e.type === "player.death"),
      );
      expect(resolutions).toHaveLength(1);
    }
  });

  it("never lets a player carry past their archetype's greed cap", () => {
    // Regression guard: greedWeightCap is meant to be an upper bound on how
    // much a pickup loop adds, not a target it always reaches.
    for (let seed = 1; seed <= 30; seed += 1) {
      const players = squad(3);
      const events = generateRun(new Rng(seed), `run-${seed}`, "server-cap", players, 1_700_000_000);
      const pickups = events.filter((e) => e.type === "loot.pickup");
      const lastWeightByPid = new Map<string, number>();
      for (const e of pickups) {
        const payload = e.p as { totalWeight: number };
        lastWeightByPid.set(e.pid as string, payload.totalWeight);
      }
      for (const player of players) {
        const final = lastWeightByPid.get(player.pid) ?? 0;
        // One item's worth of headroom past the cap: the loop breaks after
        // adding an item that crossed the threshold, it doesn't pre-check.
        expect(final).toBeLessThanOrEqual(player.archetype.greedWeightCap + 30);
      }
    }
  });

  it("keeps every event's timestamp within the run's own window", () => {
    const startTs = 1_700_000_000;
    const events = generateRun(new Rng(9), "run-w", "server-w", squad(3), startTs);
    for (const e of events) {
      expect(e.ts).toBeGreaterThanOrEqual(startTs);
      expect(e.ts).toBeLessThanOrEqual(startTs + 720 + 1);
    }
  });
});
