--!strict
--[[ M4-1. Director response shape.

	Mirrors backend/src/llm/schema.ts. Both are generated from the shared
	schema.json and a test asserts they stay in sync — a drift here means the
	model is being asked for a shape the game cannot consume.
]]

local Schema = {}

export type Intent =
	"escalate" | "relieve" | "punish_greed" | "reward_speed"
	| "split_squad" | "focus_weakest" | "bait_deeper" | "hold_steady"

export type SpawnPattern = "even" | "flank" | "chokepoint" | "hunt_heaviest"

export type ObjectiveId =
	"purge_node" | "hold_terminal" | "escort_cart" | "no_loot_window" | "hunt_warden"

export type DirectorDecision = {
	intent: Intent,
	spawnMultiplier: number,
	spawnPattern: SpawnPattern,
	objective: { id: ObjectiveId, params: { [string]: number } },
	threatTier: number,
	bark: string,
}

export type DirectorBounds = {
	spawnMultiplierMin: number,
	spawnMultiplierMax: number,
	spawnMultiplierMaxDelta: number,
	threatTierMin: number,
	threatTierMax: number,
	threatTierMaxDelta: number,
	barkMaxChars: number,
}

local INTENTS: { Intent } = {
	"escalate", "relieve", "punish_greed", "reward_speed",
	"split_squad", "focus_weakest", "bait_deeper", "hold_steady",
}

local SPAWN_PATTERNS: { SpawnPattern } = { "even", "flank", "chokepoint", "hunt_heaviest" }

local OBJECTIVE_IDS: { ObjectiveId } =
	{ "purge_node", "hold_terminal", "escort_cart", "no_loot_window", "hunt_warden" }

local DEFAULT_BOUNDS: DirectorBounds = {
	spawnMultiplierMin = 0.6,
	spawnMultiplierMax = 1.6,
	spawnMultiplierMaxDelta = 0.25,
	threatTierMin = 1,
	threatTierMax = 5,
	threatTierMaxDelta = 1,
	barkMaxChars = 180,
}

Schema.INTENTS = INTENTS
Schema.SPAWN_PATTERNS = SPAWN_PATTERNS
Schema.OBJECTIVE_IDS = OBJECTIVE_IDS
Schema.DEFAULT_BOUNDS = DEFAULT_BOUNDS

function Schema.isIntent(value: unknown): boolean
	error("unimplemented: Schema.isIntent (M4-1)")
end

function Schema.isSpawnPattern(value: unknown): boolean
	error("unimplemented: Schema.isSpawnPattern (M4-1)")
end

function Schema.isObjectiveId(value: unknown): boolean
	error("unimplemented: Schema.isObjectiveId (M4-1)")
end

return Schema
