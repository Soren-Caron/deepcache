--!strict
--[[ M2-8. Enemy budget and spawn planning.

	The formulas are checked against hand-computed values from
	docs/01-GAME-DESIGN.md §Scaling rather than against a re-implementation of
	themselves, which would pass whatever the code did.
]]

local t = require("./framework")
local expect = t.expect

local Budget = require("../src/shared/core/sim/Budget")
local Schema = require("../src/shared/core/director/Schema")
local Rng = require("../src/shared/core/util/Rng")
local Enemies = require("../src/shared/config/Enemies")
local Zones = require("../src/shared/config/Zones")
local Branding = require("../src/shared/config/Branding")

local POINTS = {
	{ x = 0, y = 0, z = 0 },
	{ x = 10, y = 0, z = 0 },
	{ x = 0, y = 0, z = 10 },
	{ x = -25, y = 0, z = 40 },
}

--- The live roster, mapped the way the adapter will map it.
local function roster(): { Budget.EnemyOption }
	local out: { Budget.EnemyOption } = {}
	for name, e in Enemies do
		table.insert(out, {
			kind = name :: any,
			cost = e.budget,
			zones = e.zones :: any,
			capPerWave = e.capPerWave,
			directorOnly = (e :: any).directorOnly,
		})
	end
	table.sort(out, function(a, b)
		return a.kind < b.kind
	end)
	return out
end

local function plan(budget: number, zone: string, seed: number, caps: { [string]: number }?): Budget.Plan
	return Budget.plan({
		budget = budget,
		zone = zone :: any,
		roster = roster(),
		caps = caps or {},
		points = POINTS,
		rng = Rng.new(seed),
	})
end

--------------------------------------------------------------------------------

t.describe("Budget.timeRamp", function()
	t.it("matches the documented curve at both ends and the midpoint", function()
		expect(Budget.timeRamp(0)).approx(1.0, 1e-9)
		expect(Budget.timeRamp(360)).approx(1.45, 1e-9)
		expect(Budget.timeRamp(720)).approx(1.9, 1e-9)
	end)

	t.it("holds at 1.9 past the end of the run rather than growing", function()
		-- A run ticks past its nominal length while the last player extracts.
		-- An unclamped ramp would raise the budget during exactly the moment
		-- the level is supposed to be emptying.
		expect(Budget.timeRamp(721)).approx(1.9, 1e-9)
		expect(Budget.timeRamp(100000)).approx(1.9, 1e-9)
	end)

	t.it("clamps negative and non-finite time to the start of the run", function()
		expect(Budget.timeRamp(-1)).approx(1.0, 1e-9)
		expect(Budget.timeRamp(-100000)).approx(1.0, 1e-9)
		expect(Budget.timeRamp(0 / 0)).approx(1.0, 1e-9)
		expect(Budget.timeRamp(math.huge)).approx(1.0, 1e-9)
	end)

	t.it("increases monotonically across the run", function()
		local previous = -math.huge
		for second = 0, 720, 5 do
			local value = Budget.timeRamp(second)
			expect(value >= previous).toBeTruthy()
			previous = value
		end
	end)

	t.it("ramps over the configured run length", function()
		-- The 720 in the formula is the run length; if Branding moves and this
		-- does not, the curve silently stops matching the design.
		expect(Budget.RAMP_SECONDS).toEqual(Branding.runLengthSeconds)
	end)
end)

t.describe("Budget.headcountMul", function()
	t.it("matches the documented values for every squad size", function()
		expect(Budget.headcountMul(1)).approx(1.0, 1e-9)
		expect(Budget.headcountMul(2)).approx(1.4, 1e-9)
		expect(Budget.headcountMul(3)).approx(1.8, 1e-9)
		expect(Budget.headcountMul(4)).approx(2.2, 1e-9)
	end)

	t.it("handles an empty and a non-finite squad without going negative", function()
		expect(Budget.headcountMul(0)).approx(0.6, 1e-9)
		expect(Budget.headcountMul(-3)).approx(0.6, 1e-9)
		expect(Budget.headcountMul(0 / 0)).approx(1.0, 1e-9)
	end)
end)

t.describe("Budget.compute", function()
	t.it("matches a hand-computed budget", function()
		-- BASE 12 x Perimeter 1.0 x timeRamp(360) 1.45 x 3 players 1.8 x 1.0
		expect(Budget.compute(360, 3, Zones.Perimeter.budgetMultiplier, 1.0)).approx(31.32, 1e-6)
		-- BASE 12 x Vault 2.2 x timeRamp(720) 1.9 x 4 players 2.2 x 1.6
		-- = 26.4 x 1.9 = 50.16 x 2.2 = 110.352 x 1.6
		expect(Budget.compute(720, 4, Zones.Vault.budgetMultiplier, 1.6)).approx(176.5632, 1e-4)
		-- The floor: drop moment, solo, Perimeter, director at minimum.
		expect(Budget.compute(0, 1, 1.0, 0.6)).approx(7.2, 1e-9)
	end)

	t.it("scales linearly in the director multiplier within bounds", function()
		local low = Budget.compute(300, 3, 1.5, 0.8)
		local high = Budget.compute(300, 3, 1.5, 1.6)
		expect(high / low).approx(2.0, 1e-9)
	end)

	t.it("clamps the director multiplier even though M4 already does", function()
		local ceiling = Budget.compute(300, 3, 1.5, Budget.DIRECTOR_MUL_MAX)
		expect(Budget.compute(300, 3, 1.5, 99)).approx(ceiling, 1e-9)
		expect(Budget.compute(300, 3, 1.5, 1e9)).approx(ceiling, 1e-9)

		local floor = Budget.compute(300, 3, 1.5, Budget.DIRECTOR_MUL_MIN)
		expect(Budget.compute(300, 3, 1.5, 0)).approx(floor, 1e-9)
		expect(Budget.compute(300, 3, 1.5, -50)).approx(floor, 1e-9)
	end)

	t.it("keeps its clamp in step with the director schema", function()
		expect(Budget.DIRECTOR_MUL_MIN).toEqual(Schema.DEFAULT_BOUNDS.spawnMultiplierMin)
		expect(Budget.DIRECTOR_MUL_MAX).toEqual(Schema.DEFAULT_BOUNDS.spawnMultiplierMax)
	end)

	t.it("never returns a negative or non-finite budget", function()
		for _, elapsed in { -100, 0, 360, 720, 5000, 0 / 0, math.huge } do
			for _, headcount in { -1, 0, 1, 4, 0 / 0 } do
				for _, director in { -5, 0.6, 1.0, 1.6, 99, 0 / 0 } do
					local value = Budget.compute(elapsed, headcount, 1.5, director)
					expect(value >= 0).toBeTruthy()
					expect(value == value).toBeTruthy()
					expect(value ~= math.huge).toBeTruthy()
				end
			end
		end
	end)
end)

t.describe("Budget.plan", function()
	t.it("never spends more than the budget", function()
		for seed = 1, 200 do
			for _, zone in { "Perimeter", "Processing", "Vault" } do
				for _, allowance in { 0, 1, 7, 40, 137 } do
					local result = plan(allowance, zone, seed)
					expect(result.spent <= allowance).toBeTruthy()
				end
			end
		end
	end)

	t.it("leaves only change smaller than the cheapest remaining option", function()
		-- Proves the budget is actually being used, not that spending nothing
		-- also satisfies "never exceeds".
		local cheapest = math.huge
		for _, option in roster() do
			if not option.directorOnly then
				cheapest = math.min(cheapest, option.cost)
			end
		end
		for seed = 1, 50 do
			local result = plan(60, "Vault", seed)
			expect(60 - result.spent < cheapest or #result.spawns == 0).toBeTruthy()
			expect(#result.spawns > 0).toBeTruthy()
		end
	end)

	t.it("respects per-type caps from the roster", function()
		local caps: { [string]: number } = {}
		for name, e in Enemies do
			caps[name] = e.capPerWave
		end
		for seed = 1, 50 do
			-- A budget far larger than any wave, so caps are the only limit.
			local result = plan(5000, "Vault", seed)
			local counts: { [string]: number } = {}
			for _, spawn in result.spawns do
				counts[spawn.kind] = (counts[spawn.kind] or 0) + 1
			end
			for kind, count in counts do
				expect(count <= caps[kind]).toBeTruthy()
			end
		end
	end)

	t.it("respects a caps override tighter than the roster", function()
		for seed = 1, 25 do
			local result = plan(5000, "Vault", seed, { Skitter = 3, Lancer = 1 })
			local counts: { [string]: number } = {}
			for _, spawn in result.spawns do
				counts[spawn.kind] = (counts[spawn.kind] or 0) + 1
			end
			expect((counts.Skitter or 0) <= 3).toBeTruthy()
			expect((counts.Lancer or 0) <= 1).toBeTruthy()
		end
	end)

	t.it("only spawns enemies available in the requested zone", function()
		local allowed: { [string]: { [string]: boolean } } = {}
		for name, e in Enemies do
			allowed[name] = {}
			for _, z in e.zones do
				allowed[name][z] = true
			end
		end
		for seed = 1, 50 do
			for _, zone in { "Perimeter", "Processing", "Vault" } do
				for _, spawn in plan(200, zone, seed).spawns do
					expect(allowed[spawn.kind][zone]).toBeTruthy()
				end
			end
		end
	end)

	t.it("never spawns a director-only enemy", function()
		-- The Reclaimer is OVERSEER's lever. If the baseline planner could
		-- produce one, an unreachable backend would still send them.
		for seed = 1, 100 do
			for _, zone in { "Perimeter", "Processing", "Vault" } do
				for _, spawn in plan(5000, zone, seed).spawns do
					expect(spawn.kind).never().toEqual("Reclaimer")
				end
			end
		end
	end)

	t.it("is deterministic for a fixed seed", function()
		for _, seed in { 1, 17, 4242 } do
			expect(plan(90, "Processing", seed)).toEqual(plan(90, "Processing", seed))
		end
	end)

	t.it("produces different plans for different seeds", function()
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for seed = 1, 40 do
			local parts: { string } = {}
			for _, spawn in plan(90, "Vault", seed).spawns do
				table.insert(parts, `{spawn.kind}@{spawn.at.x},{spawn.at.z}`)
			end
			local key = table.concat(parts, "|")
			if not seen[key] then
				seen[key] = true
				distinct += 1
			end
		end
		expect(distinct > 20).toBeTruthy()
	end)

	t.it("spends nothing on a zero or negative budget", function()
		for _, allowance in { 0, -1, -1000 } do
			local result = plan(allowance, "Perimeter", 3)
			expect(result.spent).toEqual(0)
			expect(#result.spawns).toEqual(0)
		end
	end)

	t.it("spends nothing rather than erroring on a non-finite budget", function()
		local result = plan(0 / 0, "Perimeter", 3)
		expect(result.spent).toEqual(0)
		expect(#result.spawns).toEqual(0)
	end)

	t.it("places every spawn on one of the supplied points", function()
		local result = plan(200, "Vault", 8)
		for _, spawn in result.spawns do
			local matched = false
			for _, point in POINTS do
				if spawn.at.x == point.x and spawn.at.z == point.z then
					matched = true
					break
				end
			end
			expect(matched).toBeTruthy()
		end
		-- Positions are copies: mutating a spawn must not edit the point list.
		result.spawns[1].at.x = 99999
		expect(POINTS[1].x).never().toEqual(99999)
	end)

	t.it("reports spent as the exact sum of what it placed", function()
		local costs: { [string]: number } = {}
		for name, e in Enemies do
			costs[name] = e.budget
		end
		for seed = 1, 50 do
			local result = plan(120, "Processing", seed)
			local total = 0
			for _, spawn in result.spawns do
				total += costs[spawn.kind]
			end
			expect(result.spent).toEqual(total)
		end
	end)

	t.it("throws when given no spawn points", function()
		expect(function()
			Budget.plan({
				budget = 50,
				zone = "Perimeter" :: any,
				roster = roster(),
				caps = {},
				points = {},
				rng = Rng.new(1),
			})
		end).toThrow("no spawn points")
	end)

	t.it("throws on a zero-cost enemy rather than looping forever", function()
		expect(function()
			Budget.plan({
				budget = 50,
				zone = "Perimeter" :: any,
				roster = { {
					kind = "Skitter" :: any,
					cost = 0,
					zones = { "Perimeter" } :: any,
					capPerWave = 10,
				} },
				caps = {},
				points = POINTS,
				rng = Rng.new(1),
			})
		end).toThrow("costs must be at least 1")
	end)

	t.it("spends nothing when no roster entry serves the zone", function()
		local result = Budget.plan({
			budget = 500,
			zone = "Perimeter" :: any,
			roster = { {
				kind = "Warden" :: any,
				cost = 9,
				zones = { "Vault" } :: any,
				capPerWave = 2,
			} },
			caps = {},
			points = POINTS,
			rng = Rng.new(1),
		})
		expect(result.spent).toEqual(0)
		expect(#result.spawns).toEqual(0)
	end)

	t.it("honours relative weights", function()
		-- Skitters weighted 9:1 against an equal-cost alternative should
		-- dominate, and the loser should still appear.
		local counts = { Skitter = 0, Sentry = 0 }
		for seed = 1, 300 do
			local result = Budget.plan({
				budget = 6,
				zone = "Perimeter" :: any,
				roster = {
					{ kind = "Skitter" :: any, cost = 2, zones = { "Perimeter" } :: any, capPerWave = 99, weight = 9 },
					{ kind = "Sentry" :: any, cost = 2, zones = { "Perimeter" } :: any, capPerWave = 99, weight = 1 },
				},
				caps = {},
				points = POINTS,
				rng = Rng.new(seed),
			})
			for _, spawn in result.spawns do
				counts[spawn.kind] += 1
			end
		end
		expect(counts.Skitter > counts.Sentry * 4).toBeTruthy()
		expect(counts.Sentry > 0).toBeTruthy()
	end)

	t.it("scales spawn count with the computed budget", function()
		-- The end-to-end claim: a later, fuller, deeper run is a bigger wave.
		local early = plan(Budget.compute(0, 1, Zones.Perimeter.budgetMultiplier, 1.0), "Perimeter", 5)
		local late = plan(Budget.compute(700, 4, Zones.Vault.budgetMultiplier, 1.6), "Vault", 5)
		expect(late.spent > early.spent * 3).toBeTruthy()
	end)
end)
