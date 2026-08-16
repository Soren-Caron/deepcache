--!strict
--[[ M2-9. Deterministic pacing director.

	This is the component that has to keep working when everything else fails,
	so the tests are written against a hostile caller: garbage health values,
	non-finite dt, an adversary picking inputs to make it oscillate.
]]

local t = require("./framework")
local expect = t.expect

local Fsm = require("../src/shared/core/director/Fsm")
local Schema = require("../src/shared/core/director/Schema")
local Rng = require("../src/shared/core/util/Rng")

local TICK = 20 -- director cadence, docs/05
local RUN_TICKS = 36 -- a full 12-minute run

local function input(hp: number, sinceFight: number, elapsed: number): Fsm.FsmInput
	return {
		elapsedSeconds = elapsed,
		pressure = { aliveEnemies = 10, budgetSpent = 30, recentPlayerDamage = 40, recentEnemyDeaths = 5 },
		squadHpFraction = hp,
		secondsSinceLastFight = sinceFight,
	}
end

--- Drive a run, returning the state and decision seen at each tick.
local function runFsm(
	ticks: number,
	hpAt: (tick: number) -> number,
	sinceFightAt: ((tick: number) -> number)?
): { { state: string, decision: Schema.DirectorDecision } }
	local context = Fsm.new()
	local out = {}
	for i = 1, ticks do
		local sinceFight = if sinceFightAt then sinceFightAt(i) else 0
		local decision = Fsm.step(context, input(hpAt(i), sinceFight, i * TICK), TICK)
		table.insert(out, { state = context.state, decision = decision })
	end
	return out
end

local function inList(value: any, list: { any }): boolean
	for _, entry in list do
		if entry == value then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------

t.describe("Fsm state machine", function()
	t.it("starts in BUILD with a valid decision already in hand", function()
		local context = Fsm.new()
		expect(context.state).toEqual("BUILD")
		-- The baseline must be usable before the first step: a director tick
		-- can be in flight before the FSM has ever run.
		local d = context.lastDecision
		expect(inList(d.intent, Schema.INTENTS)).toBeTruthy()
		expect(inList(d.spawnPattern, Schema.SPAWN_PATTERNS)).toBeTruthy()
		expect(inList(d.objective.id, Schema.OBJECTIVE_IDS)).toBeTruthy()
	end)

	t.it("reaches every state during a healthy run", function()
		local seen: { [string]: boolean } = {}
		for _, frame in runFsm(RUN_TICKS, function()
			return 1.0
		end) do
			seen[frame.state] = true
		end
		for _, state in Fsm.STATES do
			if not seen[state] then
				error(`state {state} was never reached in a {RUN_TICKS}-tick run`)
			end
		end
	end)

	t.it("cycles BUILD -> PRESSURE -> SPIKE -> LULL in order when healthy", function()
		local order: { string } = {}
		for _, frame in runFsm(RUN_TICKS, function()
			return 1.0
		end) do
			if #order == 0 or order[#order] ~= frame.state then
				table.insert(order, frame.state)
			end
		end
		expect(order[1]).toEqual("BUILD")
		expect(order[2]).toEqual("PRESSURE")
		expect(order[3]).toEqual("SPIKE")
		expect(order[4]).toEqual("LULL")
		expect(order[5]).toEqual("BUILD")
		-- Roughly two and a half cycles in a run: enough that a player feels
		-- the rhythm, not so many that it reads as noise.
		expect(#order >= 6).toBeTruthy()
	end)

	t.it("breaks to LULL instead of SPIKE when the squad is hurt", function()
		local seen: { [string]: boolean } = {}
		for _, frame in runFsm(RUN_TICKS, function()
			return 0.45 -- below spikeMinHp, above criticalHp
		end) do
			seen[frame.state] = true
		end
		expect(seen.PRESSURE).toBeTruthy()
		expect(seen.LULL).toBeTruthy()
		expect(seen.SPIKE).toBeFalsy()
	end)

	t.it("gives a critical squad relief from any state", function()
		-- Healthy long enough to reach SPIKE, then a sudden collapse.
		local context = Fsm.new()
		for i = 1, RUN_TICKS do
			Fsm.step(context, input(1.0, 0, i * TICK), TICK)
			if context.state == "SPIKE" then
				break
			end
		end
		expect(context.state).toEqual("SPIKE")

		Fsm.step(context, input(0.2, 0, 400), TICK)
		expect(context.state).toEqual("LULL")
	end)

	t.it("escalates out of a stalled lull rather than waiting it out", function()
		local withFights = runFsm(RUN_TICKS, function()
			return 1.0
		end, function()
			return 0
		end)
		local bored = runFsm(RUN_TICKS, function()
			return 1.0
		end, function()
			return 200 -- nothing has happened in over three minutes
		end)
		local function transitions(frames: { { state: string, decision: Schema.DirectorDecision } }): number
			local count = 0
			for i = 2, #frames do
				if frames[i].state ~= frames[i - 1].state then
					count += 1
				end
			end
			return count
		end
		expect(transitions(bored) >= transitions(withFights)).toBeTruthy()
	end)
end)

t.describe("Fsm stability", function()
	t.it("never re-enters a state within 3 ticks of leaving it", function()
		-- Adversarial: health chosen to flip the SPIKE/LULL branch and the
		-- critical-relief rule as often as possible.
		local rng = Rng.new(20250816)
		for trial = 1, 200 do
			local context = Fsm.new()
			local exitedAt: { [string]: number } = {}
			local previous = context.state
			for tick = 1, 60 do
				local hp = Rng.nextNumber(rng)
				local sinceFight = Rng.nextRange(rng, 0, 200)
				Fsm.step(context, input(hp, sinceFight, tick * TICK), TICK)
				if context.state ~= previous then
					local left = exitedAt[context.state]
					if left ~= nil and tick - left < Fsm.MIN_REENTRY_TICKS then
						error(
							`trial {trial}: re-entered {context.state} at tick {tick}, `
								.. `only {tick - left} ticks after leaving it`
						)
					end
					exitedAt[previous] = tick
					previous = context.state
				end
			end
		end
	end)

	t.it("holds the spawn multiplier inside schema bounds under any input", function()
		local rng = Rng.new(7)
		local bounds = Schema.DEFAULT_BOUNDS
		local context = Fsm.new()
		for tick = 1, 2000 do
			local hp = if tick % 17 == 0 then 0 / 0 else Rng.nextNumber(rng) * 3 - 1
			local dt = if tick % 23 == 0 then 0 / 0 else Rng.nextNumber(rng) * 40 - 5
			local decision = Fsm.step(context, input(hp, Rng.nextRange(rng, 0, 300), tick * TICK), dt)

			expect(decision.spawnMultiplier == decision.spawnMultiplier).toBeTruthy()
			expect(decision.spawnMultiplier >= bounds.spawnMultiplierMin).toBeTruthy()
			expect(decision.spawnMultiplier <= bounds.spawnMultiplierMax).toBeTruthy()
			expect(decision.threatTier >= bounds.threatTierMin).toBeTruthy()
			expect(decision.threatTier <= bounds.threatTierMax).toBeTruthy()
			expect(decision.threatTier).toEqual(math.floor(decision.threatTier))
		end
	end)

	t.it("never moves the multiplier or threat tier faster than the rate limit", function()
		local bounds = Schema.DEFAULT_BOUNDS
		local frames = runFsm(RUN_TICKS, function(tick)
			-- Swing health hard, which is what would whipsaw an unlimited curve.
			return if tick % 2 == 0 then 1.0 else 0.1
		end)
		for i = 2, #frames do
			local previous, current = frames[i - 1].decision, frames[i].decision
			expect(math.abs(current.spawnMultiplier - previous.spawnMultiplier) <= bounds.spawnMultiplierMaxDelta + 1e-9).toBeTruthy()
			expect(math.abs(current.threatTier - previous.threatTier) <= bounds.threatTierMaxDelta).toBeTruthy()
		end
	end)

	t.it("always emits a decision the schema accepts", function()
		local rng = Rng.new(99)
		local context = Fsm.new()
		for tick = 1, 500 do
			local decision = Fsm.step(context, input(Rng.nextNumber(rng), Rng.nextRange(rng, 0, 300), tick * TICK), TICK)
			expect(inList(decision.intent, Schema.INTENTS)).toBeTruthy()
			expect(inList(decision.spawnPattern, Schema.SPAWN_PATTERNS)).toBeTruthy()
			expect(inList(decision.objective.id, Schema.OBJECTIVE_IDS)).toBeTruthy()
			-- The FSM has no voice; canned barks arrive with M4-7. A
			-- placeholder here would put unfiltered text on a path to a player.
			expect(decision.bark).toEqual("")
		end
	end)

	t.it("is deterministic for identical input sequences", function()
		local function fingerprint(): string
			local parts: { string } = {}
			for _, frame in runFsm(RUN_TICKS, function(tick)
				return 1 - tick / 60
			end) do
				table.insert(parts, `{frame.state}:{string.format("%.4f", frame.decision.spawnMultiplier)}`)
			end
			return table.concat(parts, "|")
		end
		expect(fingerprint()).toEqual(fingerprint())
	end)
end)

t.describe("Fsm pacing curve", function()
	t.it("produces measurable lulls and spikes rather than a flat line", function()
		-- The M2 exit criterion. A director stuck at one multiplier would pass
		-- every bounds test above and be worthless.
		local multipliers: { number } = {}
		for _, frame in runFsm(RUN_TICKS, function()
			return 1.0
		end) do
			table.insert(multipliers, frame.decision.spawnMultiplier)
		end

		local low, high = math.huge, -math.huge
		local sum = 0
		for _, m in multipliers do
			low = math.min(low, m)
			high = math.max(high, m)
			sum += m
		end
		local mean = sum / #multipliers
		local variance = 0
		for _, m in multipliers do
			variance += (m - mean) ^ 2
		end
		variance /= #multipliers

		-- Spans most of the legal range over a run, and does so repeatedly
		-- rather than drifting once from floor to ceiling.
		expect(high - low > 0.6).toBeTruthy()
		expect(math.sqrt(variance) > 0.15).toBeTruthy()

		local direction, reversals = 0, 0
		for i = 2, #multipliers do
			local delta = multipliers[i] - multipliers[i - 1]
			if math.abs(delta) > 1e-9 then
				local sign = if delta > 0 then 1 else -1
				if direction ~= 0 and sign ~= direction then
					reversals += 1
				end
				direction = sign
			end
		end
		expect(reversals >= 3).toBeTruthy()
	end)

	t.it("reaches both the floor and the ceiling of the curve", function()
		local hitSpike, hitLull = false, false
		for _, frame in runFsm(RUN_TICKS * 2, function()
			return 1.0
		end) do
			if frame.decision.spawnMultiplier >= 1.5 then
				hitSpike = true
			end
			if frame.decision.spawnMultiplier <= 0.75 then
				hitLull = true
			end
		end
		expect(hitSpike).toBeTruthy()
		expect(hitLull).toBeTruthy()
	end)

	t.it("rotates the objective across a run instead of repeating one", function()
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for _, frame in runFsm(RUN_TICKS * 2, function()
			return 1.0
		end) do
			if not seen[frame.decision.objective.id] then
				seen[frame.decision.objective.id] = true
				distinct += 1
			end
		end
		expect(distinct >= 3).toBeTruthy()
	end)
end)
