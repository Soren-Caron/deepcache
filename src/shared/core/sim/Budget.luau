--!strict
--[[ M2-8. Enemy budget -> spawn plan.

	The director spends `budget` on enemy costs. Scaling formulas are in
	docs/01-GAME-DESIGN.md §Scaling; only directorMul is model-influenced,
	and it is clamped before it reaches here.

		enemyBudget(t, n) = BASE * zoneMul * timeRamp(t) * headcountMul(n) * directorMul
		timeRamp(t)       = 1 + 0.9 * (t / 720)
		headcountMul(n)   = 0.6 + 0.4 * n

	Two things this module deliberately does not do:

	  - **Read config.** The zone multiplier and the enemy roster arrive as
	    arguments. Core stays runnable under Lune with no Roblox and no config
	    coupling, and the adapter owns the mapping from `Zones.budgetMultiplier`
	    and `Enemies` to these parameters.
	  - **Trust the director.** `directorMul` is clamped here even though M4's
	    `Clamp` already bounds it. This is the last arithmetic before spawn
	    counts, and an unclamped multiplier turns a bad model response into an
	    unplayable wave rather than a logged warning.
]]

local Types = require("../Types")
local Rng = require("../util/Rng")

export type Spawn = { kind: Types.EntityKind, at: Types.Vec3 }
export type Plan = { spawns: { Spawn }, spent: number }

--- One spawnable enemy, as the planner sees it. Mirrors the fields of
--- `config/Enemies.luau` that matter for spawning and nothing else.
export type EnemyOption = {
	kind: Types.EntityKind,
	cost: number,
	zones: { Types.Zone },
	capPerWave: number,
	--- Reclaimer and anything else OVERSEER summons directly. Never spawned by
	--- the baseline planner, so an unreachable backend cannot produce one.
	directorOnly: boolean?,
	--- Relative pick weight among affordable options. Defaults to 1.
	weight: number?,
}

export type PlanParams = {
	budget: number,
	zone: Types.Zone,
	roster: { EnemyOption },
	--- Per-kind overrides of `capPerWave`, for the director to tighten a type
	--- without editing the roster. Missing kinds fall back to `capPerWave`.
	caps: { [string]: number },
	points: { Types.Vec3 },
	rng: Rng.Rng,
}

local Budget = {}

Budget.BASE = 12

--- Seconds over which the time ramp runs to full. Must match
--- `Branding.runLengthSeconds`, which `tests/budget.spec.luau` asserts — the
--- constant lives here rather than in config because core cannot read config,
--- and a silent divergence would flatten the curve the design specifies.
Budget.RAMP_SECONDS = 720
Budget.RAMP_GAIN = 0.9

Budget.HEADCOUNT_BASE = 0.6
Budget.HEADCOUNT_PER_PLAYER = 0.4

--- Mirrors `Schema.DEFAULT_BOUNDS.spawnMultiplier{Min,Max}`. Duplicated rather
--- than required, because `core/sim` depending on `core/director` would invert
--- the layering — the director drives the simulation, not the reverse. A test
--- asserts the two stay equal.
Budget.DIRECTOR_MUL_MIN = 0.6
Budget.DIRECTOR_MUL_MAX = 1.6

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

--- 1 at the drop, 1.9 at the end of the run.
---
--- Clamped at both ends: a run can tick slightly past its nominal length while
--- the last player extracts, and an unclamped ramp would keep growing the
--- budget during exactly the moment the level is supposed to be emptying.
function Budget.timeRamp(elapsedSeconds: number): number
	if not isFinite(elapsedSeconds) then
		return 1
	end
	local t = math.clamp(elapsedSeconds, 0, Budget.RAMP_SECONDS)
	return 1 + Budget.RAMP_GAIN * (t / Budget.RAMP_SECONDS)
end

--- 1.0 at one player, 1.8 at three, 2.2 at four.
function Budget.headcountMul(headcount: number): number
	if not isFinite(headcount) then
		return Budget.HEADCOUNT_BASE + Budget.HEADCOUNT_PER_PLAYER
	end
	local n = math.max(0, headcount)
	return Budget.HEADCOUNT_BASE + Budget.HEADCOUNT_PER_PLAYER * n
end

--- enemyBudget(t, n) = BASE * zoneMul * timeRamp(t) * headcountMul(n) * directorMul
---
--- `zoneMultiplier` is `Zones[zone].budgetMultiplier`, passed in rather than
--- read, so this stays a pure function of its arguments.
function Budget.compute(
	elapsedSeconds: number,
	headcount: number,
	zoneMultiplier: number,
	directorMul: number
): number
	local zoneMul = if isFinite(zoneMultiplier) then math.max(0, zoneMultiplier) else 1
	local director = if isFinite(directorMul) then directorMul else 1
	director = math.clamp(director, Budget.DIRECTOR_MUL_MIN, Budget.DIRECTOR_MUL_MAX)

	return Budget.BASE * zoneMul * Budget.timeRamp(elapsedSeconds) * Budget.headcountMul(headcount) * director
end

--- Spend the budget on concrete spawns. Never exceeds `budget`; respects
--- per-type caps and zone availability; deterministic for a given rng state.
---
--- Spends until nothing affordable is left rather than until the budget is
--- exactly zero: leftover smaller than the cheapest remaining option is
--- returned unspent, which is why `spent` is reported rather than assumed.
function Budget.plan(params: PlanParams): Plan
	if #params.points == 0 then
		-- Not a validation failure the caller can recover from: a level always
		-- has spawn points, so an empty list means the adapter is broken and
		-- silently spawning nothing would hide it until a playtest.
		error("Budget.plan: no spawn points supplied", 2)
	end

	local spawns: { Spawn } = {}
	local counts: { [string]: number } = {}
	local spent = 0

	local budget = if isFinite(params.budget) then math.max(0, params.budget) else 0

	local function capFor(option: EnemyOption): number
		local override = params.caps[option.kind]
		return if override ~= nil then override else option.capPerWave
	end

	local function servesZone(option: EnemyOption): boolean
		for _, z in option.zones do
			if z == params.zone then
				return true
			end
		end
		return false
	end

	local eligible: { EnemyOption } = {}
	for _, option in params.roster do
		if option.cost < 1 then
			-- A zero-cost enemy would never exhaust the budget and the loop
			-- below would not terminate.
			error(`Budget.plan: "{option.kind}" costs {option.cost}; costs must be at least 1`, 2)
		end
		if not option.directorOnly and servesZone(option) then
			table.insert(eligible, option)
		end
	end

	while true do
		local affordable: { EnemyOption } = {}
		local totalWeight = 0
		for _, option in eligible do
			local used = counts[option.kind] or 0
			if option.cost <= budget - spent and used < capFor(option) then
				table.insert(affordable, option)
				totalWeight += math.max(0, option.weight or 1)
			end
		end
		if #affordable == 0 or totalWeight <= 0 then
			break
		end

		-- Weighted pick. Walking the list in roster order keeps this
		-- reproducible for a given rng state.
		local roll = Rng.nextNumber(params.rng) * totalWeight
		local chosen = affordable[#affordable]
		local cumulative = 0
		for _, option in affordable do
			cumulative += math.max(0, option.weight or 1)
			if roll < cumulative then
				chosen = option
				break
			end
		end

		local point = params.points[Rng.nextRange(params.rng, 1, #params.points)]
		table.insert(spawns, { kind = chosen.kind, at = { x = point.x, y = point.y, z = point.z } })
		counts[chosen.kind] = (counts[chosen.kind] or 0) + 1
		spent += chosen.cost
	end

	return { spawns = spawns, spent = spent }
end

return Budget
