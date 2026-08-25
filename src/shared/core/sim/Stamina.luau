--!strict
--[[ Sprint stamina.

	Pure, and time is injected, so a 12-second drain is testable in
	microseconds and the exhaustion edges can be hit exactly rather than
	approached by playing.

	Two rules shape it, and both exist to stop the same thing — sprint becoming
	a permanent state you hold down and forget about:

	  - **Exhaustion locks you out.** Emptying the bar does not merely stop the
	    sprint, it refuses to start another until the bar has recovered past a
	    threshold. Without that, a player taps sprint every frame and moves at
	    an average well above walk speed forever, which is the same bug as an
	    animation-cancel exploit wearing different clothes.
	  - **Regeneration is delayed.** Recovery only begins after a short pause
	    from the last sprint, so disengaging costs something.

	The weight system already slows a loaded player (`core/sim/Loot`), and this
	multiplies on top of it rather than replacing it: sprinting while heavy is
	still slower than sprinting while empty.
]]

local Stamina = {}

export type State = {
	--- 0..max.
	current: number,
	--- True while the player is actually sprinting.
	sprinting: boolean,
	--- Locked out after exhaustion until `recoverTo` is reached.
	exhausted: boolean,
	--- Seconds since sprinting stopped, for the regeneration delay.
	sinceSprint: number,
}

export type Params = {
	max: number,
	drainPerSecond: number,
	regenPerSecond: number,
	--- Seconds after sprinting stops before regeneration begins.
	regenDelay: number,
	--- Fraction of max that must be recovered before sprinting is allowed
	--- again after exhaustion.
	recoverFraction: number,
	--- Minimum stamina required to *start* a sprint.
	minToStart: number,
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Stamina.new(params: Params): State
	return { current = params.max, sprinting = false, exhausted = false, sinceSprint = math.huge }
end

--- Whether a sprint may begin right now.
function Stamina.canSprint(state: State, params: Params): boolean
	if state.exhausted then
		return false
	end
	return state.current >= params.minToStart
end

--- Advance one step. `wants` is the player's input; whether it is granted is
--- this function's decision, not theirs.
---
--- Returns the state's own `sprinting` flag for convenience, so a caller can
--- set walk speed from the return without re-reading the table.
function Stamina.step(state: State, dt: number, wants: boolean, params: Params): boolean
	if not isFinite(dt) or dt <= 0 then
		return state.sprinting
	end

	-- Movement input is required, but so is having any left. A player holding
	-- sprint against an empty bar is not sprinting.
	local granted = wants and (state.sprinting or Stamina.canSprint(state, params)) and not state.exhausted

	if granted then
		state.current -= params.drainPerSecond * dt
		state.sinceSprint = 0
		if state.current <= 0 then
			state.current = 0
			-- Exhaustion, not merely empty: see the header. Tapping sprint on
			-- an empty bar must not keep granting single frames of it.
			state.exhausted = true
			granted = false
		end
	else
		state.sinceSprint += dt
		if state.sinceSprint >= params.regenDelay then
			state.current = math.min(params.max, state.current + params.regenPerSecond * dt)
		end
		if state.exhausted and state.current >= params.max * params.recoverFraction then
			state.exhausted = false
		end
	end

	state.sprinting = granted
	return granted
end

--- 0..1, for a bar.
function Stamina.fraction(state: State, params: Params): number
	if params.max <= 0 then
		return 0
	end
	return math.clamp(state.current / params.max, 0, 1)
end

function Stamina.reset(state: State, params: Params)
	state.current = params.max
	state.sprinting = false
	state.exhausted = false
	state.sinceSprint = math.huge
end

return Stamina
