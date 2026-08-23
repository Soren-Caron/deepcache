--!strict
--[[ When to spend the enemy budget, and how much of it is left to spend.

	`core/sim/Budget` answers "given a budget, which enemies and where". It does
	not answer "is now the time, and how much budget is actually outstanding" —
	that gap is why the budget planner sat unwired from M2-8 until this module
	existed. This is the missing half, kept pure for the same reason Budget is:
	pacing bugs are the kind you cannot reproduce on demand in a play session.

	The formula in docs/01 §Scaling describes a **standing pressure level**, not
	a per-wave allowance. `timeRamp` growing across the run only makes sense as
	"how much enemy should be alive right now"; read as a per-wave grant it would
	mean the *rate* of spawning compounds, which empties the budget into an
	unplayable crowd by minute eight. So a wave tops the live population back up
	toward the target rather than adding to it, and `aliveValue` — the cost of
	everything currently breathing — is what gets subtracted.

	That reading also supplies `RunPressure.budgetSpent`, which DirectorService
	has been sending as a hardcoded 0 since M4: the budget currently standing on
	the floor *is* the pressure the director is asking about.
]]

export type State = {
	secondsSinceWave: number,
	wavesSpawned: number,
	--- Budget granted to the last wave that actually fired. Diagnostic only.
	lastSpend: number,
}

export type Params = {
	intervalSeconds: number,
	firstWaveDelaySeconds: number,
	maxAlive: number,
	minWaveBudget: number,
}

--- Everything the decision depends on, as plain numbers. The adapter resolves
--- zone, headcount and director multiplier into `targetBudget` before calling.
export type Context = {
	runActive: boolean,
	aliveCount: number,
	aliveValue: number,
	targetBudget: number,
}

export type Decision = {
	spawn: boolean,
	--- Budget the wave may spend. Zero unless `spawn`.
	budgetToSpend: number,
	--- Entity slots left under `maxAlive`. A plan is trimmed to this, because
	--- Budget.plan reasons about cost and knows nothing about population.
	maxSpawns: number,
	--- Why this tick did or did not produce a wave. Surfaced in diagnostics:
	--- "no enemies spawned" and "enemies deliberately withheld" look identical
	--- from inside a play session, and that ambiguity is what hid the unwired
	--- spawner for five milestones.
	reason: string,
}

local WaveScheduler = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function WaveScheduler.new(): State
	return { secondsSinceWave = 0, wavesSpawned = 0, lastSpend = 0 }
end

--- Cost of everything alive, from a per-kind census and a per-kind cost table.
--- Kinds missing from `costs` contribute nothing rather than erroring: an
--- entity the roster no longer lists is a content change, not a crash.
function WaveScheduler.aliveValue(census: { [string]: number }, costs: { [string]: number }): number
	local total = 0
	for kind, count in census do
		local cost = costs[kind]
		if cost ~= nil and isFinite(cost) and isFinite(count) then
			total += math.max(0, cost) * math.max(0, count)
		end
	end
	return total
end

--- Cut a plan down to `maxSpawns` entries, preserving order.
function WaveScheduler.trim<T>(spawns: { T }, maxSpawns: number): { T }
	if not isFinite(maxSpawns) or maxSpawns >= #spawns then
		return spawns
	end
	local limit = math.max(0, math.floor(maxSpawns))
	local out: { T } = table.create(limit)
	for index = 1, limit do
		out[index] = spawns[index]
	end
	return out
end

local function hold(reason: string, maxSpawns: number): Decision
	return { spawn = false, budgetToSpend = 0, maxSpawns = maxSpawns, reason = reason }
end

--- Advance the timer and decide whether this tick opens a wave.
---
--- Mutates `state`. Never spawns while the run is inactive, never exceeds
--- `maxAlive`, and never grants a wave smaller than `minWaveBudget`.
function WaveScheduler.step(state: State, dt: number, ctx: Context, params: Params): Decision
	local slots = math.max(0, math.floor(params.maxAlive - ctx.aliveCount))

	if not ctx.runActive then
		-- Reset rather than freeze: a fresh run should wait out the full first
		-- delay, not inherit a timer that ran down between runs.
		state.secondsSinceWave = 0
		return hold("run_inactive", slots)
	end

	if isFinite(dt) and dt > 0 then
		state.secondsSinceWave += dt
	end

	local due = if state.wavesSpawned == 0 then params.firstWaveDelaySeconds else params.intervalSeconds
	if state.secondsSinceWave < due then
		return hold("cooldown", slots)
	end

	-- The cooldown elapsed, so re-arm it regardless of what happens below. A
	-- blocked wave then retries on the next interval instead of firing the
	-- instant one entity dies, which would turn the population ceiling into a
	-- trickle of single spawns.
	state.secondsSinceWave = 0

	if slots <= 0 then
		return hold("at_cap", 0)
	end

	local target = if isFinite(ctx.targetBudget) then math.max(0, ctx.targetBudget) else 0
	local alive = if isFinite(ctx.aliveValue) then math.max(0, ctx.aliveValue) else 0
	local remaining = target - alive

	if remaining < params.minWaveBudget then
		return hold("pressure_satisfied", slots)
	end

	state.wavesSpawned += 1
	state.lastSpend = remaining
	return { spawn = true, budgetToSpend = remaining, maxSpawns = slots, reason = "wave" }
end

function WaveScheduler.describe(state: State): { [string]: any }
	return {
		secondsSinceWave = state.secondsSinceWave,
		wavesSpawned = state.wavesSpawned,
		lastSpend = state.lastSpend,
	}
end

return WaveScheduler
