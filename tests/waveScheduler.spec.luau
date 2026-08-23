--!strict
--[[ Wave scheduling — when the enemy budget is spent, and how much is left.

	The interesting cases are all refusals: a scheduler that spawns is easy, and
	every bug this module can have is a case where it spawns when it should not
	(during a dead run, past the population ceiling, or a one-enemy trickle) or
	stops spawning forever. Those get the coverage.
]]

local t = require("./framework")
local expect = t.expect

local WaveScheduler = require("../src/shared/core/sim/WaveScheduler")
local Waves = require("../src/shared/config/Waves")
local Enemies = require("../src/shared/config/Enemies")

local PARAMS: WaveScheduler.Params = {
	intervalSeconds = 12,
	firstWaveDelaySeconds = 20,
	maxAlive = 40,
	minWaveBudget = 3,
}

local function ctx(overrides: { [string]: any }?): WaveScheduler.Context
	local base: WaveScheduler.Context = {
		runActive = true,
		aliveCount = 0,
		aliveValue = 0,
		targetBudget = 12,
	}
	for key, value in overrides or {} do
		(base :: any)[key] = value
	end
	return base
end

--- Advance a scheduler by `seconds` in 0.05 s ticks, returning every decision
--- that opened a wave. Ticking at the real tick rate rather than in one jump
--- is the point: a scheduler that only works when handed the whole interval at
--- once does not work at 20 Hz.
local function run(
	state: WaveScheduler.State,
	seconds: number,
	context: WaveScheduler.Context,
	params: WaveScheduler.Params?
): { WaveScheduler.Decision }
	local fired: { WaveScheduler.Decision } = {}
	local ticks = math.floor(seconds / 0.05)
	for _ = 1, ticks do
		local decision = WaveScheduler.step(state, 0.05, context, params or PARAMS)
		if decision.spawn then
			table.insert(fired, decision)
		end
	end
	return fired
end

--------------------------------------------------------------------------------

t.describe("WaveScheduler.step — cadence", function()
	t.it("withholds the first wave for the longer first-wave delay", function()
		local state = WaveScheduler.new()
		-- 19 s is past the 12 s steady-state interval but short of the 20 s
		-- grace. A scheduler that used the wrong constant would fire here.
		expect(#run(state, 19, ctx())).toEqual(0)
		expect(state.wavesSpawned).toEqual(0)
	end)

	t.it("opens the first wave once the delay elapses", function()
		local state = WaveScheduler.new()
		local fired = run(state, 21, ctx())
		expect(#fired).toEqual(1)
		expect(fired[1].reason).toEqual("wave")
		expect(state.wavesSpawned).toEqual(1)
	end)

	t.it("uses the shorter interval for every wave after the first", function()
		local state = WaveScheduler.new()
		-- 20 s grace + 4 x 12 s = 68 s. Held at zero alive so nothing else
		-- can suppress a wave, isolating cadence as the only variable.
		local fired = run(state, 68.5, ctx())
		expect(#fired).toEqual(5)
	end)

	t.it("does not fire twice within one interval", function()
		local state = WaveScheduler.new()
		-- Exactly 20 s fires wave 1 and leaves the timer at zero, so the
		-- follow-up window is a clean interval rather than an interval plus
		-- whatever overshoot the first leg happened to bank.
		expect(#run(state, 20, ctx())).toEqual(1)
		expect(#run(state, 11.9, ctx())).toEqual(0)
	end)
end)

t.describe("WaveScheduler.step — refusals", function()
	t.it("never spawns while the run is inactive", function()
		local state = WaveScheduler.new()
		local fired = run(state, 300, ctx({ runActive = false }))
		expect(#fired).toEqual(0)
		expect(state.wavesSpawned).toEqual(0)
	end)

	t.it("resets the timer when the run ends, so the next run waits out the full delay", function()
		local state = WaveScheduler.new()
		-- Bank 19 s of cooldown, then end the run.
		run(state, 19, ctx())
		WaveScheduler.step(state, 0.05, ctx({ runActive = false }), PARAMS)
		expect(state.secondsSinceWave).toEqual(0)
		-- A carried-over timer would fire almost immediately here.
		expect(#run(state, 19, ctx())).toEqual(0)
	end)

	t.it("refuses to exceed the population ceiling", function()
		local state = WaveScheduler.new()
		local full = ctx({ aliveCount = 40, targetBudget = 500 })
		expect(#run(state, 60, full)).toEqual(0)
		-- 20, not 12: no wave has fired yet, so the first-wave grace is still
		-- the governing interval. See the dedicated test below.
		local decision = WaveScheduler.step(state, 20, full, PARAMS)
		expect(decision.reason).toEqual("at_cap")
		expect(decision.maxSpawns).toEqual(0)
	end)

	t.it("keeps applying the first-wave grace until a wave actually fires", function()
		-- `wavesSpawned` advances on spawn, not on elapsed time, so a run that
		-- spends its opening minute at the population cap still gets the full
		-- grace once slots free rather than an immediate wave.
		local state = WaveScheduler.new()
		run(state, 60, ctx({ aliveCount = 40, targetBudget = 500 }))
		expect(state.wavesSpawned).toEqual(0)
		expect(#run(state, 12.5, ctx({ targetBudget = 500 }))).toEqual(0)
		expect(#run(state, 8, ctx({ targetBudget = 500 }))).toEqual(1)
	end)

	t.it("refuses a wave smaller than the minimum, rather than trickling one enemy in", function()
		local state = WaveScheduler.new()
		-- Target 12, alive worth 10 -> only 2 outstanding, under the floor of 3.
		local decision = WaveScheduler.step(state, 21, ctx({ aliveValue = 10 }), PARAMS)
		expect(decision.spawn).toBeFalsy()
		expect(decision.reason).toEqual("pressure_satisfied")
	end)

	t.it("grants a wave at exactly the minimum budget", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ aliveValue = 9 }), PARAMS)
		expect(decision.spawn).toBeTruthy()
		expect(decision.budgetToSpend).approx(3, 1e-9)
	end)

	t.it("re-arms after a refusal instead of firing the instant a slot frees", function()
		local state = WaveScheduler.new()
		-- Blocked at the cap when the cooldown expires.
		WaveScheduler.step(state, 21, ctx({ aliveCount = 40, targetBudget = 500 }), PARAMS)
		-- Slots free immediately, but the interval has been re-armed, so the
		-- very next tick must not spawn.
		local decision = WaveScheduler.step(state, 0.05, ctx({ aliveCount = 0, targetBudget = 500 }), PARAMS)
		expect(decision.spawn).toBeFalsy()
		expect(decision.reason).toEqual("cooldown")
		-- And it recovers rather than stalling. 20 s because no wave has fired
		-- yet, so the first-wave grace is still what governs.
		expect(#run(state, 20.5, ctx({ aliveCount = 0, targetBudget = 500 }))).toEqual(1)
	end)
end)

t.describe("WaveScheduler.step — outputs", function()
	t.it("spends exactly the outstanding budget, not the whole target", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ targetBudget = 50, aliveValue = 18 }), PARAMS)
		expect(decision.budgetToSpend).approx(32, 1e-9)
	end)

	t.it("reports the slots left under the ceiling", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ aliveCount = 33, targetBudget = 500 }), PARAMS)
		expect(decision.maxSpawns).toEqual(7)
	end)

	t.it("never reports negative slots when the ceiling is already breached", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ aliveCount = 55, targetBudget = 500 }), PARAMS)
		expect(decision.maxSpawns).toEqual(0)
	end)
end)

t.describe("WaveScheduler.step — hostile inputs", function()
	t.it("ignores NaN and infinite dt rather than jamming the timer", function()
		local state = WaveScheduler.new()
		for _ = 1, 100 do
			WaveScheduler.step(state, 0 / 0, ctx(), PARAMS)
			WaveScheduler.step(state, math.huge, ctx(), PARAMS)
		end
		expect(state.secondsSinceWave).toEqual(0)
		expect(state.wavesSpawned).toEqual(0)
		-- Still functional afterwards: a poisoned accumulator would never fire.
		expect(#run(state, 21, ctx())).toEqual(1)
	end)

	t.it("ignores negative dt", function()
		local state = WaveScheduler.new()
		WaveScheduler.step(state, -1000, ctx(), PARAMS)
		expect(state.secondsSinceWave).toEqual(0)
	end)

	t.it("treats a non-finite target budget as zero rather than spawning forever", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ targetBudget = math.huge }), PARAMS)
		expect(decision.spawn).toBeFalsy()
		local nan = WaveScheduler.step(state, 21, ctx({ targetBudget = 0 / 0 }), PARAMS)
		expect(nan.spawn).toBeFalsy()
	end)

	t.it("treats a non-finite alive value as zero rather than suppressing every wave", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ aliveValue = 0 / 0, targetBudget = 12 }), PARAMS)
		expect(decision.spawn).toBeTruthy()
		expect(decision.budgetToSpend).approx(12, 1e-9)
	end)

	t.it("treats a negative target budget as zero", function()
		local state = WaveScheduler.new()
		local decision = WaveScheduler.step(state, 21, ctx({ targetBudget = -500 }), PARAMS)
		expect(decision.spawn).toBeFalsy()
	end)
end)

t.describe("WaveScheduler.aliveValue", function()
	t.it("sums cost times count against the real roster", function()
		local costs: { [string]: number } = {}
		for kind, config in Enemies do
			costs[kind] = config.budget
		end
		-- 3 Skitters (1) + 2 Sentries (2) + 1 Warden (9) = 3 + 4 + 9 = 16.
		local value = WaveScheduler.aliveValue({ Skitter = 3, Sentry = 2, Warden = 1 }, costs)
		expect(value).approx(16, 1e-9)
	end)

	t.it("is zero for an empty census", function()
		expect(WaveScheduler.aliveValue({}, { Skitter = 1 })).toEqual(0)
	end)

	t.it("ignores kinds the cost table does not list", function()
		-- A roster change should not crash a live server mid-run.
		expect(WaveScheduler.aliveValue({ Ghost = 99 }, { Skitter = 1 })).toEqual(0)
	end)

	t.it("ignores non-finite counts and costs", function()
		expect(WaveScheduler.aliveValue({ Skitter = 0 / 0 }, { Skitter = 1 })).toEqual(0)
		expect(WaveScheduler.aliveValue({ Skitter = 3 }, { Skitter = math.huge })).toEqual(0)
	end)
end)

t.describe("WaveScheduler.trim", function()
	t.it("returns the list untouched when it already fits", function()
		local spawns = { "a", "b" }
		expect(WaveScheduler.trim(spawns, 5)).toEqual({ "a", "b" })
	end)

	t.it("cuts to the limit, preserving order", function()
		expect(WaveScheduler.trim({ "a", "b", "c", "d" }, 2)).toEqual({ "a", "b" })
	end)

	t.it("returns empty at a limit of zero or below", function()
		expect(WaveScheduler.trim({ "a", "b" }, 0)).toEqual({})
		expect(WaveScheduler.trim({ "a", "b" }, -3)).toEqual({})
	end)
end)

t.describe("Waves config", function()
	t.it("delays the first wave longer than the steady-state interval", function()
		-- If these invert, players are dropped straight into a fight.
		expect(Waves.FIRST_WAVE_DELAY_SECONDS > Waves.INTERVAL_SECONDS).toBeTruthy()
	end)

	t.it("never allows more live entities than a client can be shown", function()
		-- Was `>=`, which permitted the exact bug it should have caught:
		-- replication sends at most INTEREST_MAX entities and the renderer
		-- releases anything missing from a snapshot, so any entity above that
		-- cap is alive and attacking while invisible to everyone.
		local Netcode = require("../src/shared/config/Netcode")
		expect(Waves.MAX_ALIVE <= Netcode.INTEREST_MAX).toBeTruthy()
	end)

	t.it("sets a minimum wave at least as large as the cheapest enemy", function()
		local cheapest = math.huge
		for _, config in Enemies do
			cheapest = math.min(cheapest, config.budget)
		end
		expect(Waves.MIN_WAVE_BUDGET >= cheapest).toBeTruthy()
	end)
end)
