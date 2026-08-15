--!strict
--[[ M2-9. Deterministic pacing director.

	The safety net. This alone produces a complete, well-paced game — the LLM
	only modulates it. If OVERSEER is unreachable, this is what runs, and the
	game must remain fully playable.
]]

local Schema = require("./Schema")
local Types = require("../Types")

export type FsmState = "BUILD" | "PRESSURE" | "SPIKE" | "LULL"

export type FsmContext = {
	state: FsmState,
	secondsInState: number,
	secondsSinceLastLull: number,
	lastDecision: Schema.DirectorDecision,
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

function Fsm.new(): FsmContext
	error("unimplemented: Fsm.new (M2-9)")
end

--- Advance the pacing state machine and produce the baseline decision.
--- Output spawnMultiplier must always be within Schema.DEFAULT_BOUNDS.
function Fsm.step(context: FsmContext, input: FsmInput, dt: number): Schema.DirectorDecision
	error("unimplemented: Fsm.step (M2-9)")
end

return Fsm
