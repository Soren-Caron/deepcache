--!strict
--[[
	Owns every AI entity.

	Entities are plain Luau tables. There is no Instance, no Humanoid, and no
	network ownership on the server side — that is what makes 40+ entities
	affordable and authoritative at the same time. Clients build Instances to
	render them; the server never does.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local EnemiesConfig = require(Shared.config.Enemies)
local NetcodeConfig = require(Shared.config.Netcode)
local EntityState = require(Shared.core.sim.EntityState)
local Steering = require(Shared.core.sim.Steering)
local History = require(Shared.core.net.History)
local Types = require(Shared.core.Types)

local EntityService = {}

local entities: { [number]: Types.Entity } = {}
local order: { number } = {}
local nextId = 1
local history = History.new(NetcodeConfig.HISTORY_TICKS)

--- Ids that died or left this tick, drained by ReplicationService.
local pendingDespawns: { number } = {}

--- Position provider for player targets, injected by Bootstrap so this module
--- stays free of Players/Character concerns.
local targetProvider: (() -> { { id: number, pos: Types.Vec3 } })? = nil

function EntityService.setTargetProvider(provider: () -> { { id: number, pos: Types.Vec3 } })
	targetProvider = provider
end

function EntityService.spawn(kind: Types.EntityKind, pos: Types.Vec3, tick: number): Types.Entity
	local config = (EnemiesConfig :: any)[kind]
	if config == nil then
		error(`EntityService.spawn: unknown entity kind "{kind}"`, 2)
	end

	local id = nextId
	nextId += 1
	-- uint16 on the wire; wrapping would collide with a live entity.
	if nextId > 65535 then
		nextId = 1
	end

	local entity = EntityState.create(id, kind, pos, tick, {
		hp = config.hp,
		hitboxRadius = config.hitboxRadius,
	})

	entities[id] = entity
	table.insert(order, id)
	return entity
end

function EntityService.get(id: number): Types.Entity?
	return entities[id]
end

function EntityService.count(): number
	return #order
end

function EntityService.getHistory(): History.History
	return history
end

--- Stable-ordered live entity views, for replication.
function EntityService.views(): { Types.EntityView }
	local out: { Types.EntityView } = table.create(#order)
	for i, id in order do
		out[i] = EntityState.toView(entities[id])
	end
	return out
end

function EntityService.drainDespawns(): { number }
	if #pendingDespawns == 0 then
		return {}
	end
	local drained = pendingDespawns
	pendingDespawns = {}
	return drained
end

function EntityService.remove(id: number)
	if entities[id] == nil then
		return
	end
	entities[id] = nil
	local index = table.find(order, id)
	if index then
		table.remove(order, index)
	end
	table.insert(pendingDespawns, id)
end

--------------------------------------------------------------------------------

local function nearestTarget(pos: Types.Vec3, targets: { { id: number, pos: Types.Vec3 } }): Types.Vec3?
	local best: Types.Vec3? = nil
	local bestDistance = math.huge
	for _, target in targets do
		local distance = Types.distance(pos, target.pos)
		if distance < bestDistance then
			bestDistance = distance
			best = target.pos
		end
	end
	return best
end

--- One simulation step. Registered as a TickService phase.
function EntityService.step(tick: number, dt: number)
	local targets = if targetProvider then targetProvider() else {}

	-- Neighbour positions for separation. At 40 entities the O(n^2) pass is
	-- ~1600 distance checks per tick, which is cheaper than maintaining a
	-- spatial hash at this scale. Revisit past ~150 entities.
	local positions: { Types.Vec3 } = table.create(#order)
	for i, id in order do
		positions[i] = entities[id].pos
	end

	local reap: { number } = {}

	for index, id in order do
		local entity = entities[id]

		if entity.state == "death" then
			EntityState.markDeath(entity, tick)
			if EntityState.shouldReap(entity, tick) then
				table.insert(reap, id)
			end
			continue
		end

		if entity.state == "spawn" then
			EntityState.transition(entity, "idle")
		end

		local config = (EnemiesConfig :: any)[entity.kind]
		local target = nearestTarget(entity.pos, targets)

		if target == nil then
			EntityState.transition(entity, "idle")
			entity.vel = { x = 0, y = 0, z = 0 }
			continue
		end

		local distance = Types.distance(entity.pos, target)

		if distance <= config.atkRange then
			EntityState.transition(entity, "attack")
			entity.vel = { x = 0, y = 0, z = 0 }
			entity.yaw = Steering.facingYaw(Types.subVec3(target, entity.pos), entity.yaw)
			continue
		end

		EntityState.transition(entity, "move")

		local neighbours: { Types.Vec3 } = {}
		for otherIndex, otherPos in positions do
			if otherIndex ~= index then
				table.insert(neighbours, otherPos)
			end
		end

		local seek = if config.behavior == "KeepDistance"
			then Steering.keepDistance(entity.pos, target, config.preferredDistance or 40, config.speed)
			else Steering.seek(entity.pos, target, config.speed)

		local separate = Steering.separate(entity.pos, neighbours, entity.hitboxRadius * 2.5)

		local velocity = Steering.combine({
			{ force = seek, weight = 1.0 },
			{ force = Types.scaleVec3(separate, config.speed), weight = 0.8 },
		}, config.speed)

		entity.vel = velocity
		entity.pos = Types.addVec3(entity.pos, Types.scaleVec3(velocity, dt))
		entity.yaw = Steering.facingYaw(velocity, entity.yaw)
	end

	for _, id in reap do
		EntityService.remove(id)
	end
end

--- Record this tick into the rewind buffer. Registered as its own phase so it
--- always runs after simulation and before replication.
function EntityService.recordHistory(tick: number, _dt: number)
	History.record(history, tick, workspace:GetServerTimeNow(), EntityService.views())
end

function EntityService.reset()
	entities = {}
	order = {}
	pendingDespawns = {}
	nextId = 1
	History.clear(history)
end

return EntityService
