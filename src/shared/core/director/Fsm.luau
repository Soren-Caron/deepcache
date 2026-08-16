--!strict
--[[ M2-9. Deterministic pacing director.

	The safety net. This alone produces a complete, well-paced game — the LLM
	only modulates it. If OVERSEER is unreachable, this is what runs, and the
	game must remain fully playable.

	                 ┌─────────┐  fight has run long   ┌──────────┐
	                 │  BUILD  │──────────────────────►│ PRESSURE │
	                 └─────────┘                       └──────────┘
	                      ▲                             │        │
	          rested      │                     squad   │        │ squad hurt
	                      │                     healthy │        │
	                 ┌─────────┐                        ▼        │
	                 │  LULL   │◄───────────────── ┌───────┐     │
	                 └─────────┘   spike spent     │ SPIKE │     │
	                      ▲                        └───────┘     │
	                      └──────────────────────────────────────┘
	                          squad critical, from any state

	The cycle is the pacing curve: build tension, sustain it, break it with a
	spike, then give the squad room to loot and reposition before starting
	again. Roughly two and a half cycles fit in a 12-minute run.

	**Every state has a floor on how long it holds, and no state can be
	re-entered within `MIN_REENTRY_TICKS` director ticks.** Difficulty that
	whipsaws reads as broken rather than dynamic, and the LLM tier at M4 will
	be layered on top of this output — an unstable baseline would make the
	model's contribution impossible to measure in the A/B.

	Tuning lives in `Fsm.TUNING` rather than `config/`, matching `Assemble`:
	these are constants intrinsic to this state machine, not content. Core does
	not read config — see the M1-4 note in tasks/BACKLOG.md.
]]

local Schema = require("./Schema")
local Types = require("../Types")

export type FsmState = "BUILD" | "PRESSURE" | "SPIKE" | "LULL"

export type FsmContext = {
	state: FsmState,
	secondsInState: number,
	secondsSinceLastLull: number,
	lastDecision: Schema.DirectorDecision,
	--- Director ticks since the run started. Re-entry is bounded in ticks, not
	--- seconds, so the guarantee holds exactly whatever cadence the adapter
	--- runs at.
	tick: number,
	--- Tick index at which each state was last left. A state absent here has
	--- never been left.
	lastExitTick: { [string]: number },
	--- Rotates on each entry to BUILD, so a run does not repeat one objective.
	objectiveIndex: number,
}

export type FsmInput = {
	elapsedSeconds: number,
	pressure: Types.RunPressure,
	squadHpFraction: number,
	secondsSinceLastFight: number,
}

local Fsm = {}

local STATES: { FsmState } = { "BUILD", "PRESSURE", "SPIKE", "LULL" }

Fsm.STATES = STATES

local TUNING = {
	--- Minimum seconds a state holds before it will consider moving on.
	---
	--- These are not free choices: the multiplier is rate limited to
	--- `spawnMultiplierMaxDelta` per tick, so a state has to hold long enough
	--- for the curve to actually reach its target. The lull is the binding
	--- case — falling from the spike ceiling to the lull floor is 0.88, which
	--- is four ticks at 0.25. At the 35 seconds first tried, LULL lasted two
	--- ticks and bottomed out at 1.10: nominally a lull, in practice harder
	--- than BUILD. Relief that never arrives is worse than no lull at all,
	--- because the pacing curve reads as noise instead of rhythm.
	buildSeconds = 45,
	pressureSeconds = 60,
	spikeSeconds = 40,
	lullSeconds = 80,

	--- A squad at or below this fraction of health gets relief early, from any
	--- state. This is the only transition that ignores the dwell floor.
	criticalHp = 0.35,
	--- A spike is only worth it against a squad that can survive it; below
	--- this, PRESSURE breaks to LULL instead.
	spikeMinHp = 0.5,
	--- Quiet for this long means the pacing curve has stalled. Nothing is
	--- happening and the run is being wasted, so skip ahead.
	boredomSeconds = 75,

	--- Baseline spawn multiplier per state, before health modulation and rate
	--- limiting. This is the pacing curve.
	multiplier = {
		BUILD = 0.95,
		PRESSURE = 1.25,
		SPIKE = 1.6,
		LULL = 0.6,
	} :: { [string]: number },

	--- Threat tier per state, shown to the player through lighting at M4-9.
	threat = {
		BUILD = 2,
		PRESSURE = 3,
		SPIKE = 5,
		LULL = 1,
	} :: { [string]: number },

	--- How strongly squad health pulls the multiplier away from its baseline.
	--- Centred at 0.6: a healthy squad gets slightly more, a hurt one less.
	hpPivot = 0.6,
	hpGain = 0.3,
}

Fsm.TUNING = TUNING

--- Director ticks that must pass before a state can be entered again. The
--- acceptance criterion is "no state ping-pongs within 3 ticks"; enforcing it
--- explicitly is more honest than hoping the dwell floors imply it.
Fsm.MIN_REENTRY_TICKS = 3

local INTENT: { [string]: Schema.Intent } = {
	BUILD = "hold_steady",
	PRESSURE = "escalate",
	SPIKE = "punish_greed",
	LULL = "relieve",
}

local PATTERN: { [string]: Schema.SpawnPattern } = {
	BUILD = "even",
	PRESSURE = "flank",
	SPIKE = "chokepoint",
	LULL = "even",
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitise(value: number, fallback: number): number
	return if isFinite(value) then value else fallback
end

function Fsm.new(): FsmContext
	return {
		state = "BUILD",
		secondsInState = 0,
		secondsSinceLastLull = 0,
		tick = 0,
		lastExitTick = {},
		objectiveIndex = 1,
		lastDecision = {
			intent = INTENT.BUILD,
			spawnMultiplier = TUNING.multiplier.BUILD,
			spawnPattern = PATTERN.BUILD,
			objective = { id = Schema.OBJECTIVE_IDS[1], params = {} },
			threatTier = TUNING.threat.BUILD,
			bark = "",
		},
	}
end

--- The state this context would like to move to, ignoring the re-entry guard.
--- Returns the current state when it wants to stay.
local function desiredState(context: FsmContext, input: FsmInput): FsmState
	local state = context.state
	local hp = math.clamp(sanitise(input.squadHpFraction, 1), 0, 1)
	local dwell = context.secondsInState

	-- Relief for a squad about to wipe, from anywhere. Deliberately exempt
	-- from the dwell floor: holding a spike against a squad at 20% health to
	-- satisfy a pacing rule is the state machine working against the game.
	if hp <= TUNING.criticalHp and state ~= "LULL" then
		return "LULL"
	end

	if state == "BUILD" then
		local bored = sanitise(input.secondsSinceLastFight, 0) >= TUNING.boredomSeconds
		if dwell >= TUNING.buildSeconds or bored then
			return "PRESSURE"
		end
	elseif state == "PRESSURE" then
		if dwell >= TUNING.pressureSeconds then
			return if hp >= TUNING.spikeMinHp then "SPIKE" else "LULL"
		end
	elseif state == "SPIKE" then
		if dwell >= TUNING.spikeSeconds then
			return "LULL"
		end
	elseif state == "LULL" then
		local bored = sanitise(input.secondsSinceLastFight, 0) >= TUNING.boredomSeconds
		if dwell >= TUNING.lullSeconds or bored then
			return "BUILD"
		end
	end

	return state
end

--- Advance the pacing state machine and produce the baseline decision.
--- Output spawnMultiplier is always within Schema.DEFAULT_BOUNDS.
function Fsm.step(context: FsmContext, input: FsmInput, dt: number): Schema.DirectorDecision
	local step = math.max(0, sanitise(dt, 0))
	context.tick += 1
	context.secondsInState += step
	context.secondsSinceLastLull += step

	local target = desiredState(context, input)
	if target ~= context.state then
		-- A state that was left recently cannot be re-entered yet. Blocked
		-- transitions hold rather than falling through to a third state:
		-- picking a different destination to stay busy is exactly the
		-- whipsawing this guard exists to prevent.
		local exited = context.lastExitTick[target]
		if exited == nil or context.tick - exited >= Fsm.MIN_REENTRY_TICKS then
			context.lastExitTick[context.state] = context.tick
			context.state = target
			context.secondsInState = 0

			if target == "LULL" then
				context.secondsSinceLastLull = 0
			elseif target == "BUILD" then
				context.objectiveIndex = context.objectiveIndex % #Schema.OBJECTIVE_IDS + 1
			end
		end
	end

	local state = context.state
	local bounds = Schema.DEFAULT_BOUNDS
	local previous = context.lastDecision

	local hp = math.clamp(sanitise(input.squadHpFraction, 1), 0, 1)
	local target_ = TUNING.multiplier[state] + (hp - TUNING.hpPivot) * TUNING.hpGain
	target_ = math.clamp(target_, bounds.spawnMultiplierMin, bounds.spawnMultiplierMax)

	-- Rate limited to the same per-tick delta the LLM tier is held to, so the
	-- baseline cannot whipsaw either. A state change is a step in the curve,
	-- not a jump.
	local multiplier = math.clamp(
		target_,
		previous.spawnMultiplier - bounds.spawnMultiplierMaxDelta,
		previous.spawnMultiplier + bounds.spawnMultiplierMaxDelta
	)
	multiplier = math.clamp(multiplier, bounds.spawnMultiplierMin, bounds.spawnMultiplierMax)

	local threat = math.clamp(
		TUNING.threat[state],
		previous.threatTier - bounds.threatTierMaxDelta,
		previous.threatTier + bounds.threatTierMaxDelta
	)
	threat = math.clamp(math.floor(threat + 0.5), bounds.threatTierMin, bounds.threatTierMax)

	local decision: Schema.DirectorDecision = {
		intent = INTENT[state],
		spawnMultiplier = multiplier,
		spawnPattern = PATTERN[state],
		objective = {
			-- Params are left empty: the per-objective ranges live in
			-- Objectives.luau, which core does not read. M4-8's objective
			-- system fills defaults.
			id = Schema.OBJECTIVE_IDS[context.objectiveIndex],
			params = {},
		},
		threatTier = threat,
		-- The FSM has no voice. Canned barks arrive with M4-7; emitting a
		-- placeholder here would put unfiltered text on the path to a player.
		bark = "",
	}

	context.lastDecision = decision
	return decision
end

return Fsm
