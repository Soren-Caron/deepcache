--!strict
--[[ M6-4. PI controller for the global payout multiplier.

	No derivative term: daily economy data from a small population is mostly
	noise, and D amplifies it. See docs/07-ECONOMY.md §The controller.
]]

local Controller = {}

export type ControllerState = {
	multiplier: number,
	integral: number,
	clampedDays: number,
}

export type Observation = {
	faucetTotal: number,
	sinkTotal: number,
	runCount: number,
}

export type Decision = {
	multiplier: number,
	applied: boolean,
	reason: string,
	ratio: number,
}

Controller.TARGET_RATIO = 0.85
Controller.KP = 0.35
Controller.KI = 0.05
Controller.I_MAX = 2.0
Controller.MULT_MIN = 0.80
Controller.MULT_MAX = 1.25
Controller.MAX_DAILY_DELTA = 0.03
Controller.MIN_RUNS = 200

function Controller.new(): ControllerState
	error("unimplemented: Controller.new (M6-4)")
end

--- One nightly update. Skips (applied = false, with a reason) when the sample
--- is too small. Never moves more than MAX_DAILY_DELTA, never leaves
--- [MULT_MIN, MULT_MAX], and tracks consecutive clamped days for alerting.
function Controller.step(state: ControllerState, obs: Observation, enabled: boolean): (ControllerState, Decision)
	error("unimplemented: Controller.step (M6-4)")
end

return Controller
