/**
 * M4-1. Director response shape.
 *
 * Mirrors src/shared/core/director/Schema.luau. Both are hand-written to
 * match schema/director-decision.json, and a test in each language asserts
 * they stay in sync -- a drift here means the model is being asked for a
 * shape the game cannot consume.
 */

export const INTENTS = [
  "escalate",
  "relieve",
  "punish_greed",
  "reward_speed",
  "split_squad",
  "focus_weakest",
  "bait_deeper",
  "hold_steady",
] as const;

export const SPAWN_PATTERNS = ["even", "flank", "chokepoint", "hunt_heaviest"] as const;

export const OBJECTIVE_IDS = [
  "purge_node",
  "hold_terminal",
  "escort_cart",
  "no_loot_window",
  "hunt_warden",
] as const;

export type Intent = (typeof INTENTS)[number];
export type SpawnPattern = (typeof SPAWN_PATTERNS)[number];
export type ObjectiveId = (typeof OBJECTIVE_IDS)[number];

export interface DirectorDecision {
  readonly intent: Intent;
  readonly spawnMultiplier: number;
  readonly spawnPattern: SpawnPattern;
  readonly objective: { readonly id: ObjectiveId; readonly params: Readonly<Record<string, number>> };
  readonly threatTier: number;
  readonly bark: string;
}

export interface DirectorBounds {
  readonly spawnMultiplierMin: number;
  readonly spawnMultiplierMax: number;
  readonly spawnMultiplierMaxDelta: number;
  readonly threatTierMin: number;
  readonly threatTierMax: number;
  readonly threatTierMaxDelta: number;
  readonly barkMaxChars: number;
}

export const DEFAULT_BOUNDS: DirectorBounds = {
  spawnMultiplierMin: 0.6,
  spawnMultiplierMax: 1.6,
  spawnMultiplierMaxDelta: 0.25,
  threatTierMin: 1,
  threatTierMax: 5,
  threatTierMaxDelta: 1,
  barkMaxChars: 180,
};

export function isIntent(value: unknown): value is Intent {
  return typeof value === "string" && (INTENTS as readonly string[]).includes(value);
}

export function isSpawnPattern(value: unknown): value is SpawnPattern {
  return typeof value === "string" && (SPAWN_PATTERNS as readonly string[]).includes(value);
}

export function isObjectiveId(value: unknown): value is ObjectiveId {
  return typeof value === "string" && (OBJECTIVE_IDS as readonly string[]).includes(value);
}

/** JSON Schema for Ollama's structured-output `format` field. */
export const DIRECTOR_JSON_SCHEMA = {
  type: "object",
  properties: {
    intent: { type: "string", enum: INTENTS },
    spawnMultiplier: { type: "number" },
    spawnPattern: { type: "string", enum: SPAWN_PATTERNS },
    objective: {
      type: "object",
      properties: {
        id: { type: "string", enum: OBJECTIVE_IDS },
        params: { type: "object" },
      },
      required: ["id", "params"],
    },
    threatTier: { type: "integer" },
    bark: { type: "string" },
  },
  required: ["intent", "spawnMultiplier", "spawnPattern", "objective", "threatTier", "bark"],
} as const;
