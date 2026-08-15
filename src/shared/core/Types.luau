--!strict
--[[
	Shared types for pure-core modules.

	Roblox's Vector3/CFrame are engine types unavailable under Lune, so core
	uses plain-table equivalents. Adapters convert at the boundary — that
	conversion is the only place the two representations meet.
]]

export type Vec3 = { x: number, y: number, z: number }

export type EntityKind = "Skitter" | "Sentry" | "Hauler" | "Lancer" | "Warden" | "Reclaimer"

export type EntityStateName = "idle" | "move" | "attack" | "stagger" | "death" | "spawn"

--- The replicated view of an entity: exactly what fits in a snapshot record.
export type EntityView = {
	id: number,
	pos: Vec3,
	yaw: number, -- radians
	state: EntityStateName,
	hpPct: number, -- 0..1
}

--- Full server-side entity. Never leaves the server.
export type Entity = {
	id: number,
	kind: EntityKind,
	pos: Vec3,
	vel: Vec3,
	yaw: number,
	hp: number,
	maxHp: number,
	state: EntityStateName,
	targetId: number?,
	hitboxRadius: number,
	spawnedAtTick: number,
}

export type Zone = "Perimeter" | "Processing" | "Vault"

--- One frame of the simulation, as the director sees it.
export type RunPressure = {
	aliveEnemies: number,
	budgetSpent: number,
	recentPlayerDamage: number,
	recentEnemyDeaths: number,
}

local Types = {}

function Types.vec3(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

function Types.addVec3(a: Vec3, b: Vec3): Vec3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function Types.subVec3(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Types.scaleVec3(v: Vec3, s: number): Vec3
	return { x = v.x * s, y = v.y * s, z = v.z * s }
end

function Types.magnitude(v: Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function Types.distance(a: Vec3, b: Vec3): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Returns the zero vector for a zero-length input rather than NaN.
function Types.normalize(v: Vec3): Vec3
	local m = Types.magnitude(v)
	if m < 1e-9 then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = v.x / m, y = v.y / m, z = v.z / m }
end

function Types.lerpVec3(a: Vec3, b: Vec3, alpha: number): Vec3
	return {
		x = a.x + (b.x - a.x) * alpha,
		y = a.y + (b.y - a.y) * alpha,
		z = a.z + (b.z - a.z) * alpha,
	}
end

return Types
