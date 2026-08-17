import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_BOUNDS,
  INTENTS,
  OBJECTIVE_IDS,
  SPAWN_PATTERNS,
  isIntent,
  isObjectiveId,
  isSpawnPattern,
} from "../src/llm/schema.js";

/**
 * M4-1. Mirrors tests/director-schema.spec.luau -- both languages assert
 * their hand-written enums match the same schema/director-decision.json,
 * which is the actual sync guarantee: neither file trusts the other,
 * both are checked against a third, independent source.
 */

const canonical = JSON.parse(
  readFileSync(new URL("../../schema/director-decision.json", import.meta.url), "utf-8"),
) as {
  intents: string[];
  spawnPatterns: string[];
  objectiveIds: string[];
  bounds: Record<string, number>;
};

describe("schema: enum guards", () => {
  it("isIntent accepts every declared intent and rejects garbage", () => {
    for (const intent of INTENTS) expect(isIntent(intent)).toBe(true);
    expect(isIntent("not_a_real_intent")).toBe(false);
    expect(isIntent(undefined)).toBe(false);
    expect(isIntent(42)).toBe(false);
    expect(isIntent({})).toBe(false);
  });

  it("isSpawnPattern accepts every declared pattern and rejects garbage", () => {
    for (const pattern of SPAWN_PATTERNS) expect(isSpawnPattern(pattern)).toBe(true);
    expect(isSpawnPattern("diagonal")).toBe(false);
    expect(isSpawnPattern(null)).toBe(false);
  });

  it("isObjectiveId accepts every declared id and rejects garbage", () => {
    for (const id of OBJECTIVE_IDS) expect(isObjectiveId(id)).toBe(true);
    expect(isObjectiveId("invent_an_objective")).toBe(false);
    expect(isObjectiveId(false)).toBe(false);
  });
});

describe("schema: sync with schema/director-decision.json", () => {
  it("intents match exactly, same order", () => {
    expect([...INTENTS]).toEqual(canonical.intents);
  });

  it("spawn patterns match exactly, same order", () => {
    expect([...SPAWN_PATTERNS]).toEqual(canonical.spawnPatterns);
  });

  it("objective ids match exactly, same order", () => {
    expect([...OBJECTIVE_IDS]).toEqual(canonical.objectiveIds);
  });

  it("bounds match field by field", () => {
    expect(DEFAULT_BOUNDS.spawnMultiplierMin).toBe(canonical.bounds.spawnMultiplierMin);
    expect(DEFAULT_BOUNDS.spawnMultiplierMax).toBe(canonical.bounds.spawnMultiplierMax);
    expect(DEFAULT_BOUNDS.spawnMultiplierMaxDelta).toBe(canonical.bounds.spawnMultiplierMaxDelta);
    expect(DEFAULT_BOUNDS.threatTierMin).toBe(canonical.bounds.threatTierMin);
    expect(DEFAULT_BOUNDS.threatTierMax).toBe(canonical.bounds.threatTierMax);
    expect(DEFAULT_BOUNDS.threatTierMaxDelta).toBe(canonical.bounds.threatTierMaxDelta);
    expect(DEFAULT_BOUNDS.barkMaxChars).toBe(canonical.bounds.barkMaxChars);
  });
});
