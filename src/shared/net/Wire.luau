--!strict
--[[
	Payload shapes crossing the network, plus the conversions between Roblox
	types and the plain tables pure core uses.

	This is the only place those two representations meet. Core never sees a
	Vector3; the engine never sees a `{x, y, z}` table.
]]

local Types = require("../core/Types")

local Wire = {}

--- Client -> server. Every field is a claim, not a fact.
export type FireRequest = {
	--- Monotonic per client. Echoed back so the client can match the result to
	--- its prediction and measure round-trip latency.
	seq: number,
	--- Client's view of when it fired, on the shared server clock. Clamped
	--- into the compensation window before use.
	clientTime: number,
	origin: Vector3,
	direction: Vector3,
	weaponId: string,
}

--- Server -> client. Authoritative.
export type FireResult = {
	seq: number,
	hit: boolean,
	entityId: number?,
	damage: number?,
	died: boolean?,
	hitPos: Vector3?,
	--- Present when the request was refused, for telemetry and client logging.
	rejected: string?,
}

export type DespawnBatch = {
	ids: { number },
}

export type AmmoSync = {
	weaponId: string,
	ammo: number,
}

--------------------------------------------------------------------------------

function Wire.toVec3(v: Vector3): Types.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

function Wire.toVector3(v: Types.Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

--- Yaw from a Roblox CFrame, matching Steering.facingYaw's convention
--- (atan2(x, z), zero along +Z).
function Wire.yawFromCFrame(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(look.X, look.Z)
end

function Wire.cframeFromYaw(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, yaw, 0)
end

--------------------------------------------------------------------------------

--- Validate an inbound fire request's shape before anything else touches it.
--- Remote payloads are attacker-controlled: a client can send a table with any
--- field of any type, or nothing at all.
function Wire.parseFireRequest(payload: unknown): FireRequest?
	if typeof(payload) ~= "table" then
		return nil
	end
	local t = payload :: { [string]: unknown }

	local seq = t.seq
	local clientTime = t.clientTime
	local origin = t.origin
	local direction = t.direction
	local weaponId = t.weaponId

	if typeof(seq) ~= "number" or seq ~= seq or seq < 0 then
		return nil
	end
	if typeof(clientTime) ~= "number" or clientTime ~= clientTime then
		return nil
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return nil
	end
	if typeof(weaponId) ~= "string" or #weaponId == 0 or #weaponId > 32 then
		return nil
	end

	return {
		seq = seq :: number,
		clientTime = clientTime :: number,
		origin = origin :: Vector3,
		direction = direction :: Vector3,
		weaponId = weaponId :: string,
	}
end

return Wire
