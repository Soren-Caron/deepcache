--!strict
--[[ M4-1. Director response shape.

	Mirrors backend/src/llm/schema.ts. Both are hand-written to match
	schema/director-decision.json, and a test in each language asserts they
	stay in sync — a drift here means the model is being asked for a shape
	the game cannot consume.
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

local function tableContains(list: { string }, value: unknown): boolean
	if type(value) ~= "string" then
		return false
	end
	for _, candidate in list do
		if candidate == value then
			return true
		end
	end
	return false
end

function Schema.isIntent(value: unknown): boolean
	return tableContains(INTENTS, value)
end

function Schema.isSpawnPattern(value: unknown): boolean
	return tableContains(SPAWN_PATTERNS, value)
end

function Schema.isObjectiveId(value: unknown): boolean
	return tableContains(OBJECTIVE_IDS, value)
end

return Schema
