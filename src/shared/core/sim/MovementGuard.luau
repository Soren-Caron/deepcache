--!strict
--[[
	Server-side plausibility checking for player movement.

	Roblox network-owns the player's character, so the server cannot be
	authoritative here without destroying how movement feels. What it can do is
	notice when the client is claiming something impossible.

	This is honest about what it is: it stops trivial cheats and produces the
	telemetry needed to spot the rest. A determined cheater who stays inside the
	speed budget gets through, and pretending otherwise would be worse than
	saying so.

	Violations accumulate into a decaying score rather than tripping on a single
	frame. One bad frame is ordinary — a lag spike, a ramp, knockback. A
	sustained pattern is not.
]]

local Types = require("../Types")

local MovementGuard = {}

export type Params = {
	--- Multiplier on max speed before a frame counts as a violation.
	speedMargin: number,
	--- Single-frame displacement that is never legitimate.
	teleportThreshold: number,
	--- Score decay per second.
	decayPerSecond: number,
	correctAt: number,
	kickAt: number,
	worldMin: Types.Vec3?,
	worldMax: Types.Vec3?,
}

export type State = {
	score: number,
	totalViolations: number,
}

export type Action = "ok" | "correct" | "kick"

export type Verdict = {
	action: Action,
	score: number,
	--- Empty when the frame was clean.
	reasons: { string },
	--- Where the server thinks the player should be, when action ~= "ok".
	correctedPos: Types.Vec3?,
}

local DEFAULT_PARAMS: Params = {
	speedMargin = 1.35,
	teleportThreshold = 40,
	decayPerSecond = 1.0,
	correctAt = 5,
	kickAt = 20,
}

MovementGuard.DEFAULT_PARAMS = DEFAULT_PARAMS

function MovementGuard.new(): State
	return { score = 0, totalViolations = 0 }
end

--- Decay the score toward zero. Called every tick, including clean ones.
function MovementGuard.decay(state: State, dt: number, params: Params): State
	state.score = math.max(0, state.score - params.decayPerSecond * dt)
	return state
end

--- Evaluate one movement step.
---
--- `maxSpeed` is the player's current allowance, which already accounts for
--- carried weight — a heavily loaded player moves slower, and the guard must
--- use the same number the movement code does or it will flag honest players.
function MovementGuard.check(
	state: State,
	previousPos: Types.Vec3,
	newPos: Types.Vec3,
	dt: number,
	maxSpeed: number,
	params: Params
): Verdict
	local reasons: { string } = {}
	local corrected: Types.Vec3? = nil

	if dt <= 0 then
		return { action = "ok", score = state.score, reasons = reasons }
	end

	-- NaN or infinite coordinates: a malformed packet, not a lag spike.
	local finite = newPos.x == newPos.x
		and newPos.y == newPos.y
		and newPos.z == newPos.z
		and math.abs(newPos.x) ~= math.huge
		and math.abs(newPos.y) ~= math.huge
		and math.abs(newPos.z) ~= math.huge
	if not finite then
		state.score += params.kickAt
		state.totalViolations += 1
		return {
			action = "kick",
			score = state.score,
			reasons = { "non_finite_position" },
			correctedPos = previousPos,
		}
	end

	local displacement = Types.distance(previousPos, newPos)

	-- Teleport: no legitimate mechanic moves this far in one frame.
	if displacement > params.teleportThreshold then
		state.score += 5
		state.totalViolations += 1
		table.insert(reasons, "teleport")
		corrected = previousPos
	else
		-- Speed, with margin for slopes, knockback, and latency.
		local allowed = maxSpeed * params.speedMargin * dt
		if displacement > allowed then
			-- Weight the violation by how far past the budget it went, so a
			-- marginal overshoot barely registers and a large one escalates.
			local excess = displacement / math.max(allowed, 1e-6)
			state.score += math.min(excess, 5)
			state.totalViolations += 1
			table.insert(reasons, "speed")
			corrected = previousPos
		end
	end

	-- Outside the level volume.
	local min, max = params.worldMin, params.worldMax
	if min and max then
		if
			newPos.x < min.x or newPos.x > max.x
			or newPos.y < min.y or newPos.y > max.y
			or newPos.z < min.z or newPos.z > max.z
		then
			state.score += 2
			state.totalViolations += 1
			table.insert(reasons, "out_of_bounds")
			corrected = {
				x = math.clamp(newPos.x, min.x, max.x),
				y = math.clamp(newPos.y, min.y, max.y),
				z = math.clamp(newPos.z, min.z, max.z),
			}
		end
	end

	local action: Action = "ok"
	if state.score >= params.kickAt then
		action = "kick"
	elseif state.score >= params.correctAt then
		action = "correct"
	elseif #reasons > 0 then
		-- Flagged but under threshold: let it ride. This is the branch that
		-- keeps honest players with bad connections from being punished.
		action = "ok"
	end

	return {
		action = action,
		score = state.score,
		reasons = reasons,
		correctedPos = if action ~= "ok" then corrected or previousPos else nil,
	}
end

return MovementGuard
