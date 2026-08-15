--!strict
--[[
	Entity struct and state machine.

	Entities are plain tables, never Roblox Instances. The server owns them
	entirely — no Humanoid, no network ownership, no engine physics. That is
	what makes authoritative simulation and snapshot replication possible at
	40+ entities. Instances exist only on clients, for rendering.

	Stats arrive as a parameter rather than being read from config, so this
	module stays free of any dependency the adapter owns.
]]

local Types = require("../Types")

export type Stats = {
	hp: number,
	hitboxRadius: number,
}

local EntityState = {}

--- Legal transitions. Anything not listed is rejected, which is what keeps a
--- dead entity from walking: `death` has no outgoing edges.
local TRANSITIONS: { [Types.EntityStateName]: { Types.EntityStateName } } = {
	spawn = { "idle", "move" },
	idle = { "move", "attack", "stagger", "death" },
	move = { "idle", "attack", "stagger", "death" },
	attack = { "idle", "move", "stagger", "death" },
	stagger = { "idle", "move", "death" },
	death = {},
}

EntityState.TRANSITIONS = TRANSITIONS

function EntityState.create(
	id: number,
	kind: Types.EntityKind,
	pos: Types.Vec3,
	tick: number,
	stats: Stats
): Types.Entity
	if stats.hp <= 0 then
		error(`EntityState.create: hp must be positive, got {stats.hp}`, 2)
	end
	return {
		id = id,
		kind = kind,
		pos = { x = pos.x, y = pos.y, z = pos.z },
		vel = { x = 0, y = 0, z = 0 },
		yaw = 0,
		hp = stats.hp,
		maxHp = stats.hp,
		state = "spawn",
		targetId = nil,
		hitboxRadius = stats.hitboxRadius,
		spawnedAtTick = tick,
		diedAtTick = nil,
	}
end

function EntityState.canTransition(from: Types.EntityStateName, to: Types.EntityStateName): boolean
	local allowed = TRANSITIONS[from]
	if allowed == nil then
		return false
	end
	for _, candidate in allowed do
		if candidate == to then
			return true
		end
	end
	return false
end

--- Attempt a transition. Returns false and leaves the entity untouched when
--- the transition is illegal — an invalid transition is a logic bug in a
--- behaviour, not a reason to crash the tick.
function EntityState.transition(entity: Types.Entity, to: Types.EntityStateName): boolean
	if entity.state == to then
		return true
	end
	if not EntityState.canTransition(entity.state, to) then
		return false
	end
	entity.state = to
	return true
end

function EntityState.isAlive(entity: Types.Entity): boolean
	return entity.state ~= "death" and entity.hp > 0
end

--- Corpses linger so the client can play a death animation and spawn a
--- ragdoll before the entity disappears, and so a shot already in flight can
--- still resolve against it.
EntityState.CORPSE_TICKS = 20

--- Stamp the death tick. Idempotent, so calling it every tick while dead does
--- not keep pushing the reap deadline out.
function EntityState.markDeath(entity: Types.Entity, tick: number)
	if entity.state == "death" and entity.diedAtTick == nil then
		entity.diedAtTick = tick
	end
end

--- Should this corpse be removed?
---
--- Deliberately keyed on `diedAtTick`, never `spawnedAtTick`. An earlier
--- version compared against the spawn tick, which is almost always far in the
--- past, so every corpse was reaped one tick after dying — the client never
--- saw the death state, and a shot fired just before the kill found nothing to
--- rewind onto.
function EntityState.shouldReap(entity: Types.Entity, tick: number): boolean
	if entity.state ~= "death" then
		return false
	end
	local diedAt = entity.diedAtTick
	if diedAt == nil then
		return false
	end
	return tick - diedAt > EntityState.CORPSE_TICKS
end

--- Apply damage. Returns the damage actually applied and whether this killed
--- the entity, so the caller can award credit exactly once.
function EntityState.applyDamage(entity: Types.Entity, amount: number): (number, boolean)
	if amount <= 0 or not EntityState.isAlive(entity) then
		return 0, false
	end
	local applied = math.min(amount, entity.hp)
	entity.hp -= applied
	if entity.hp <= 0 then
		entity.hp = 0
		entity.state = "death"
		entity.vel = { x = 0, y = 0, z = 0 }
		return applied, true
	end
	return applied, false
end

--- Strip a full entity down to its replicated view — exactly the fields that
--- fit in an 11-byte snapshot record.
function EntityState.toView(entity: Types.Entity): Types.EntityView
	return {
		id = entity.id,
		pos = { x = entity.pos.x, y = entity.pos.y, z = entity.pos.z },
		yaw = entity.yaw,
		state = entity.state,
		hpPct = if entity.maxHp > 0 then entity.hp / entity.maxHp else 0,
	}
end

return EntityState
