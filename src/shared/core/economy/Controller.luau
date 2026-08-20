--!strict
--[[ M6-4. PI controller for the global payout multiplier.

	No derivative term: daily economy data from a small population is mostly
	noise, and D amplifies it. See docs/07-ECONOMY.md §The controller.

	"Skip the update entirely" (sample floor, kill switch) means exactly
	that: `state` comes back unchanged, including `integral` -- a skipped
	day must not accumulate error, or the next real update would react to a
	day that never happened.

	`clampedDays` increments whenever the *post-clamp* multiplier lands
	within a float epsilon of MULT_MIN/MULT_MAX, and resets otherwise. It's
	exposed on state so the nightly worker (M6-5, an adapter) can raise the
	"reached a clamp for 3 consecutive days" alert -- this module only
	tracks the count, it doesn't alert.
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

local CLAMP_EPSILON = 1e-9

function Controller.new(): ControllerState
	return {
		multiplier = 1.0,
		integral = 0,
		clampedDays = 0,
	}
end

--- One nightly update. Skips (applied = false, with a reason) when the sample
--- is too small. Never moves more than MAX_DAILY_DELTA, never leaves
--- [MULT_MIN, MULT_MAX], and tracks consecutive clamped days for alerting.
function Controller.step(state: ControllerState, obs: Observation, enabled: boolean): (ControllerState, Decision)
	local ratio = obs.sinkTotal / math.max(obs.faucetTotal, 1)

	if not enabled then
		return state, { multiplier = state.multiplier, applied = false, reason = "autotune disabled", ratio = ratio }
	end
	if obs.runCount < Controller.MIN_RUNS then
		return state,
			{
				multiplier = state.multiplier,
				applied = false,
				reason = `sample too small ({obs.runCount} < {Controller.MIN_RUNS})`,
				ratio = ratio,
			}
	end

	local err = Controller.TARGET_RATIO - ratio
	local newIntegral = math.clamp(state.integral + err, -Controller.I_MAX, Controller.I_MAX)
	local adjust = Controller.KP * err + Controller.KI * newIntegral

	local rangeClamped = math.clamp(state.multiplier * (1 - adjust), Controller.MULT_MIN, Controller.MULT_MAX)
	local delta = math.clamp(rangeClamped - state.multiplier, -Controller.MAX_DAILY_DELTA, Controller.MAX_DAILY_DELTA)
	local newMultiplier = state.multiplier + delta

	local atClamp = newMultiplier <= Controller.MULT_MIN + CLAMP_EPSILON
		or newMultiplier >= Controller.MULT_MAX - CLAMP_EPSILON
	local newClampedDays = if atClamp then state.clampedDays + 1 else 0

	local newState: ControllerState = {
		multiplier = newMultiplier,
		integral = newIntegral,
		clampedDays = newClampedDays,
	}
	return newState, { multiplier = newMultiplier, applied = true, reason = "updated", ratio = ratio }
end

return Controller
