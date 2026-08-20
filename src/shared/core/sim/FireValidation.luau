--!strict
--[[
	The cheap half of fire-request validation — everything that can be decided
	without touching the world.

	Ordered cheapest-rejection-first so an aimbot spamming requests costs a
	token-bucket comparison, not a raycast. The expensive half (rewind, raycast,
	line of sight) lives in the CombatService adapter because it needs the
	engine.

	Nothing here trusts the client. A client timestamp is a hint that gets
	clamped; a claimed origin is a hint that gets replaced when implausible.
]]

local Types = require("../Types")

local FireValidation = {}

export type Bucket = {
	tokens: number,
	capacity: number,
	refillPerSecond: number,
	lastRefill: number,
}

export type Rejection =
	"rate" | "ammo" | "range" | "dead"

--- Token bucket per weapon. Capacity above 1 tolerates a legitimate burst
--- (and ordinary network jitter delivering two requests together) without
--- letting sustained fire exceed the weapon's rate.
function FireValidation.newBucket(refillPerSecond: number, capacity: number?, now: number?): Bucket
	if refillPerSecond <= 0 then
		error(`FireValidation.newBucket: refillPerSecond must be positive, got {refillPerSecond}`, 2)
	end
	local cap = capacity or 2
	return {
		tokens = cap,
		capacity = cap,
		refillPerSecond = refillPerSecond,
		lastRefill = now or 0,
	}
end

--- Refill by elapsed time, then try to spend one token.
--- Returns false when the request arrived faster than the weapon allows.
function FireValidation.tryConsume(bucket: Bucket, now: number): boolean
	local elapsed = math.max(now - bucket.lastRefill, 0)
	bucket.lastRefill = now
	bucket.tokens = math.min(bucket.capacity, bucket.tokens + elapsed * bucket.refillPerSecond)

	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

--- Reconcile a claimed muzzle origin against the server's known player
--- position.
---
--- Beyond tolerance the server *substitutes* its own position rather than
--- rejecting. Honest clients desync briefly all the time — on a spike, up a
--- ramp, mid-knockback — and punishing that would feel like the game eating
--- shots. A liar gets their shot fired from where they actually are, which is
--- the outcome that matters.
function FireValidation.reconcileOrigin(
	claimed: Types.Vec3,
	serverKnown: Types.Vec3,
	tolerance: number
): (Types.Vec3, boolean)
	if Types.distance(claimed, serverKnown) <= tolerance then
		return claimed, false
	end
	return serverKnown, true
end

--- Clamp a client-supplied fire time into the compensation window.
--- Returns the usable time and whether clamping was needed.
function FireValidation.clampFireTime(clientTime: number, now: number, window: number): (number, boolean)
	if clientTime ~= clientTime then
		-- NaN would poison every downstream comparison silently.
		return now, true
	end
	local clamped = math.clamp(clientTime, now - window, now)
	return clamped, clamped ~= clientTime
end

--- Is the target within the weapon's maximum range, with a small tolerance for
--- quantization and interpolation error?
function FireValidation.inRange(origin: Types.Vec3, target: Types.Vec3, maxRange: number, slack: number?): boolean
	return Types.distance(origin, target) <= maxRange + (slack or 2)
end

--- Normalised aim direction. Returns nil for a zero-length, NaN, infinite, or
--- overflowing direction, which a malformed or malicious packet can supply.
---
--- Checking the *magnitude* is finite (rather than only checking the
--- components for NaN) closes two holes that both reached CombatService,
--- which rejects a fire request purely on a nil return here:
---   - an infinite component: inf/inf is NaN, so normalising returned a
---     direction with NaN components instead of nil.
---   - three merely large components (1e200 each): every component is finite,
---     but x^2+y^2+z^2 overflows to inf, and dividing by inf collapsed the
---     result to exactly (0,0,0) -- the zero-length direction this function
---     exists to reject.
function FireValidation.sanitizeDirection(dir: Types.Vec3): Types.Vec3?
	if dir.x ~= dir.x or dir.y ~= dir.y or dir.z ~= dir.z then
		return nil
	end
	local magnitude = Types.magnitude(dir)
	-- NaN fails both comparisons, and inf fails the upper one.
	if not (magnitude >= 1e-6 and magnitude < math.huge) then
		return nil
	end
	return Types.normalize(dir)
end

return FireValidation
