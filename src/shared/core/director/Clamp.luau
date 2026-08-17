--!strict
--[[ M4-5. Turns anything the model returns into a valid decision.

	This function is total: it must never throw and must always return a
	valid DirectorDecision, for every possible input including nil, garbage,
	wrong types, and out-of-range values. It is the entire safety boundary
	between the LLM and the game. See docs/05-OVERSEER-DIRECTOR.md §Clamping.

	Scope note: docs/05's clamping table lists "objective.id must be in the
	whitelist and not currently on cooldown" as one rule. This module owns the
	whitelist half. Cooldown tracking is stateful (M4-8, the objective
	system) and lives above Clamp: the caller is responsible for ensuring
	`baseline.objective` already reflects a cooldown-legal objective before
	calling apply, since Clamp itself has no notion of time or history.
]]

local Schema = require("./Schema")
local Objectives = require("../../config/Objectives")

type ObjectiveParamRange = { min: number, max: number, default: number }
type ObjectiveSpec = { cooldownSeconds: number, rewardCredits: number?, rewardMultiplier: number?, params: { [string]: ObjectiveParamRange } }

local Clamp = {}

--- true for any finite number; false for NaN, +-inf, and non-numbers.
local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and (value :: number) == (value :: number)
		and value ~= math.huge and value ~= -math.huge
end

local function toFiniteNumber(value: unknown, fallback: number): number
	if isFiniteNumber(value) then
		return value :: number
	end
	return fallback
end

--- Clamp a value into range and additionally limit how far it may move from
--- `previous` in a single tick.
function Clamp.rateLimited(value: number, previous: number, min: number, max: number, maxDelta: number): number
	local v = value
	if not isFiniteNumber(v) then
		v = previous
	end
	v = math.clamp(v, min, max)
	v = math.clamp(v, previous - maxDelta, previous + maxDelta)
	-- Re-clamp: if `previous` itself sat outside [min, max] (shouldn't happen
	-- for a well-formed baseline, but this function must be total for any
	-- input), the delta window above could still land outside range.
	v = math.clamp(v, min, max)
	return v
end

--- Strip control characters and truncate. Does NOT content-filter — that is
--- TextService's job and happens in the adapter.
function Clamp.sanitizeBark(text: unknown, maxChars: number): string
	if type(text) ~= "string" then
		return ""
	end
	local stripped = string.gsub(text :: string, "%c", "")
	if #stripped > maxChars then
		stripped = string.sub(stripped, 1, maxChars)
	end
	return stripped
end

local function clampObjectiveParams(id: string, rawParams: unknown): { [string]: number }
	local spec = (Objectives :: { [string]: ObjectiveSpec })[id]
	local out: { [string]: number } = {}
	if spec == nil then
		return out
	end
	local params: { [string]: any } = if type(rawParams) == "table" then rawParams :: any else {}
	-- Only known param names for this objective are ever copied in, which is
	-- what "unknown keys dropped" means: a key not in the whitelist below
	-- simply never gets read.
	for paramName, range in spec.params do
		local value = toFiniteNumber(params[paramName], range.default)
		out[paramName] = math.clamp(value, range.min, range.max)
	end
	return out
end

local function clampObjective(
	proposed: unknown,
	baseline: { id: string, params: { [string]: number } }
): { id: string, params: { [string]: number } }
	if type(proposed) ~= "table" then
		return baseline
	end
	local o = proposed :: { [string]: any }
	if not Schema.isObjectiveId(o.id) then
		return baseline
	end
	local id = o.id :: string
	return { id = id, params = clampObjectiveParams(id, o.params) }
end

--- Never throws. `baseline` is the FSM decision used to fill anything the
--- proposal fails to supply legally, and the reference point rate limits
--- move away from.
function Clamp.apply(
	proposal: unknown,
	baseline: Schema.DirectorDecision,
	bounds: Schema.DirectorBounds
): Schema.DirectorDecision
	if type(proposal) ~= "table" then
		return baseline
	end
	local p = proposal :: { [string]: any }

	local intent: Schema.Intent = if Schema.isIntent(p.intent) then p.intent else baseline.intent

	local spawnMultiplier = Clamp.rateLimited(
		toFiniteNumber(p.spawnMultiplier, baseline.spawnMultiplier),
		baseline.spawnMultiplier,
		bounds.spawnMultiplierMin,
		bounds.spawnMultiplierMax,
		bounds.spawnMultiplierMaxDelta
	)

	local spawnPattern: Schema.SpawnPattern = if Schema.isSpawnPattern(p.spawnPattern) then p.spawnPattern else "even"

	local objective = clampObjective(p.objective, baseline.objective)

	local threatTierRaw = Clamp.rateLimited(
		toFiniteNumber(p.threatTier, baseline.threatTier),
		baseline.threatTier,
		bounds.threatTierMin,
		bounds.threatTierMax,
		bounds.threatTierMaxDelta
	)
	local threatTier = math.floor(threatTierRaw + 0.5)

	local bark = Clamp.sanitizeBark(p.bark, bounds.barkMaxChars)
	if bark == "" then
		bark = baseline.bark
	end

	return {
		intent = intent,
		spawnMultiplier = spawnMultiplier,
		spawnPattern = spawnPattern,
		objective = objective,
		threatTier = threatTier,
		bark = bark,
	}
end

return Clamp
