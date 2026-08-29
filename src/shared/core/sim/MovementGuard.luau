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

	**Horizontal and vertical are budgeted separately, and that is not a
	refinement — it is the difference between working and kicking everyone who
	presses space.** `maxSpeed` is a *walk* speed (WalkSpeed 16 by default).
	Gravity is not: a default jump leaves the ground at ~53 studs/s and a fall
	keeps accelerating at 196 studs/s². Measuring one 3D displacement against a
	horizontal budget therefore charges the player for gravity. Measured in a
	real Play session, a player standing perfectly still (horizontal
	displacement 0.00) and simply jumping accrued 2.57x the allowance per
	airborne tick, hit `correct` 12 ticks in, and reached the kick threshold
	over a few jumps. The vertical axis gets its own budget for that reason.

	Rise and fall are budgeted differently on purpose. Going *up* faster than a
	jump impulse is not something Roblox physics does, so `maxRiseSpeed` stays
	tight and still catches a fly hack. Going *down* fast is just gravity, so
	`maxFallSpeed` is generous — a cheat that consists of falling is not a
	cheat. Both are injected by the adapter from real engine values rather than
	hardcoded here, per CLAUDE.md's rule about keeping core engine-free.
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
	--- Fastest legitimate *upward* speed, studs/s. A jump impulse is the only
	--- thing in normal play that moves a character up, so this stays tight
	--- enough to still catch a fly hack.
	maxRiseSpeed: number,
	--- Fastest legitimate *downward* speed, studs/s. Free fall accelerates
	--- without limit until something stops it, so this is deliberately
	--- generous: falling fast is gravity, not cheating.
	maxFallSpeed: number,
	--- Seconds of movement averaged together before speed is judged.
	---
	--- **This is what stops the guard measuring the network instead of the
	--- player.** The server samples a replicated position on its own fixed
	--- tick, but positions arrive in bursts: several ticks see no change, then
	--- one absorbs two packets' worth of movement. Divided by that tick's dt
	--- it reads as a huge speed. Measured in a real session, an honest player
	--- walking at 16 produced per-tick samples of 24.5, 27.0 and 29.9 studs/s
	--- against a 21.6 allowance, purely from replication jitter -- roughly one
	--- false violation a second, against a decay of one a second, so the score
	--- ratcheted upward until it crossed `correctAt` and yanked the player
	--- back. That is what a stutter that cancels your movement is.
	---
	--- Averaging over a window is immune to burstiness and still catches the
	--- thing worth catching, because a speed hack sustains by definition. The
	--- cost is detection latency of about one window, which is nothing next to
	--- the score threshold it then has to climb.
	windowSeconds: number,
	--- How many consecutive ticks a player may rise faster than their own
	--- ground speed before it stops being a jump. Instantaneous speed cannot
	--- separate a jump from a slow fly hack -- a hack rising at 40 studs/s is
	--- *below* the jump impulse -- but duration can: gravity turns a real jump
	--- around in `v0 / g` seconds, roughly 5 ticks at 20Hz for Roblox
	--- defaults. Sustained climbing past that is not physics.
	maxRiseTicks: number,
	worldMin: Types.Vec3?,
	worldMax: Types.Vec3?,
}

export type State = {
	score: number,
	totalViolations: number,
	--- Consecutive ticks spent rising faster than ground movement could
	--- explain. See `maxRiseTicks`.
	risingTicks: number,
	--- Movement accumulated since the last speed judgement. See
	--- `Params.windowSeconds`.
	windowTime: number,
	windowHorizontal: number,
	windowRise: number,
	windowFall: number,
	--- The most permissive allowance seen during the window.
	---
	--- Most permissive, not the latest, and that also fixes a second bug: the
	--- client raises its own WalkSpeed the instant sprint starts and only then
	--- tells the server, so for one round trip the guard was budgeting a walk
	--- speed against a sprint. Taking the maximum over the window means a
	--- sprint that began at any point inside it is budgeted as a sprint.
	--- Erring permissive is correct here: the cost of a false negative is one
	--- cheater moving slightly faster, and the cost of a false positive is
	--- teleporting an honest player backwards.
	windowAllowance: number,
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
	-- Roblox defaults: JumpHeight 7.2 with gravity 196.2 leaves the ground at
	-- sqrt(2*g*h) = 53.15 studs/s. Rounded up to 60 for headroom on ramps and
	-- knockback. The adapter overrides this from the live engine values.
	maxRiseSpeed = 60,
	-- ~250 studs/s is a fall of roughly 160 studs. Comfortably above anything
	-- inside a level, and still 12.5 studs/tick at 20Hz -- well under the
	-- 40-stud teleport threshold, so the two checks cannot contradict.
	maxFallSpeed = 250,
	-- A real jump exceeds walking speed upward for about 4 ticks before
	-- gravity brings it back under. 10 is ~2.5x that -- generous enough that
	-- no legitimate arc trips it, tight enough that a sustained climb does.
	maxRiseTicks = 10,
	-- Long enough to absorb replication bursting, short enough that a real
	-- speed hack is flagged within a second.
	windowSeconds = 0.75,
}

MovementGuard.DEFAULT_PARAMS = DEFAULT_PARAMS

function MovementGuard.new(): State
	return {
		score = 0,
		totalViolations = 0,
		risingTicks = 0,
		windowTime = 0,
		windowHorizontal = 0,
		windowRise = 0,
		windowFall = 0,
		windowAllowance = 0,
	}
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
		-- Speed, with margin for slopes, knockback, and latency. Horizontal
		-- and vertical are budgeted separately: `maxSpeed` is a walk speed and
		-- has nothing to say about gravity. Charging a jump against it kicks
		-- players for pressing space (see the note at the top of this file).
		local dx = newPos.x - previousPos.x
		local dy = newPos.y - previousPos.y
		local dz = newPos.z - previousPos.z

		-- Accumulate rather than judge. One tick of a replicated position is a
		-- statement about when packets arrived, not about how fast the player
		-- moved; see `Params.windowSeconds`.
		state.windowTime += dt
		state.windowHorizontal += math.sqrt(dx * dx + dz * dz)
		if dy >= 0 then
			state.windowRise += dy
		else
			state.windowFall += -dy
		end
		state.windowAllowance = math.max(state.windowAllowance, maxSpeed)

		if state.windowTime >= params.windowSeconds then
			local window = state.windowTime
			local allowedHorizontal = state.windowAllowance * params.speedMargin * window
			local allowedRise = params.maxRiseSpeed * params.speedMargin * window
			local allowedFall = params.maxFallSpeed * params.speedMargin * window

			-- Whichever axis overran by the larger factor sets the severity, so a
			-- player who is both running and falling is not charged twice for one
			-- stretch of ordinary movement.
			local horizontalExcess = state.windowHorizontal / math.max(allowedHorizontal, 1e-6)
			local riseExcess = state.windowRise / math.max(allowedRise, 1e-6)
			local fallExcess = state.windowFall / math.max(allowedFall, 1e-6)
			local verticalExcess = math.max(riseExcess, fallExcess)
			local excess = math.max(horizontalExcess, verticalExcess)

			if excess > 1 then
				-- Weight the violation by how far past the budget it went, so a
				-- marginal overshoot barely registers and a large one escalates.
				state.score += math.min(excess, 5)
				state.totalViolations += 1
				-- Name the axis that actually overran; "speed" alone sent a real
				-- investigation looking at horizontal movement that was zero.
				table.insert(reasons, if verticalExcess > horizontalExcess then "vertical_speed" else "speed")
				corrected = previousPos
			end

			state.windowTime = 0
			state.windowHorizontal = 0
			state.windowRise = 0
			state.windowFall = 0
			state.windowAllowance = 0
		end

		-- Sustained climb. A per-tick speed check cannot catch a fly hack that
		-- rises slower than a jump impulse, because that frame looks exactly
		-- like a jump. What separates them is that gravity ends a jump: rising
		-- faster than your own ground speed is only possible for the few ticks
		-- before the arc turns over. Walking up a ramp never qualifies, since
		-- that cannot outpace `maxSpeed` in the first place.
		if dy > 0 and (dy / dt) > maxSpeed then
			state.risingTicks += 1
		else
			state.risingTicks = 0
		end
		if state.risingTicks > params.maxRiseTicks then
			state.score += 5
			state.totalViolations += 1
			table.insert(reasons, "sustained_rise")
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
			-- Clamp whatever correction is already standing, NOT newPos. If a
			-- teleport or speed violation already fired, `corrected` is
			-- previousPos and must stay there: clamping newPos instead would
			-- hand a cheater the boundary point, which is a successful
			-- long-distance teleport earned by breaking two rules at once
			-- rather than one. Only when this is the sole violation does the
			-- clamped new position become the correction, since then there is
			-- no safer place to fall back to.
			local base = corrected or newPos
			corrected = {
				x = math.clamp(base.x, min.x, max.x),
				y = math.clamp(base.y, min.y, max.y),
				z = math.clamp(base.z, min.z, max.z),
			}
		end
	end

	-- **A correction needs evidence *this* evaluation, not just a standing
	-- score.** Without the `#reasons > 0` term this branch fires on every
	-- subsequent tick until the score decays back under the threshold -- at one
	-- point per second from a threshold of five, that is several seconds of the
	-- player being teleported to their previous position twenty times a second.
	-- Measured in a live session: 7 violations produced 109 corrections. From
	-- the player's side that is not a correction, it is being pinned in place,
	-- and it is exactly the "stutters and cancels the movement I wanted"
	-- report this came from.
	--
	-- The score still does the escalating: it is what decides whether a fresh
	-- violation is worth acting on, and it keeps climbing toward `kickAt` for
	-- someone who keeps producing them. It just no longer manufactures evidence
	-- of its own.
	local action: Action = "ok"
	if state.score >= params.kickAt then
		action = "kick"
	elseif #reasons > 0 and state.score >= params.correctAt then
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
