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
local Path = require(Shared.core.level.Path)
local Types = require(Shared.core.Types)

local LevelService = require("./LevelService")

local EntityService = {}

--- What a target looks like to an entity. `weight` drives HuntHeaviest and is
--- the reason the Reclaimer is OVERSEER's most legible lever: it goes for the
--- player carrying the most, and the squad can see that it did.
export type Target = { id: number, pos: Types.Vec3, weight: number? }

--- Cached route for one entity. Recomputed when either end moves to a
--- different node, which for a walking entity means a room transition — a few
--- A* calls per second across the whole population rather than one per entity
--- per tick.
type NavRoute = { fromNode: number, toNode: number, nextPos: Types.Vec3? }

local navRoutes: { [number]: NavRoute } = {}

local entities: { [number]: Types.Entity } = {}
local order: { number } = {}
local nextId = 1
local history = History.new(NetcodeConfig.HISTORY_TICKS)

--- Ids that died or left this tick, drained by ReplicationService.
local pendingDespawns: { number } = {}

--- Position provider for player targets, injected by Bootstrap so this module
--- stays free of Players/Character concerns.
local targetProvider: (() -> { Target })? = nil

function EntityService.setTargetProvider(provider: () -> { Target })
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

--- Drop a dead entity's cached route. Without this, ids recycled after the
--- uint16 wrap would inherit a stale path from whatever last held the id.
local function forgetRoute(id: number)
	navRoutes[id] = nil
end

function EntityService.remove(id: number)
	if entities[id] == nil then
		return
	end
	entities[id] = nil
	forgetRoute(id)
	local index = table.find(order, id)
	if index then
		table.remove(order, index)
	end
	table.insert(pendingDespawns, id)
end

--------------------------------------------------------------------------------

--- Returns the whole Target, not just its position: `EnemyAttack` needs to know
--- *who* was chosen so a strike lands on the player the entity is facing rather
--- than on whoever happens to be nearest when damage resolves.
local function nearestTarget(pos: Types.Vec3, targets: { Target }): Target?
	local best: Target? = nil
	local bestDistance = math.huge
	for _, target in targets do
		local distance = Types.distance(pos, target.pos)
		if distance < bestDistance then
			bestDistance = distance
			best = target
		end
	end
	return best
end

--- The player carrying the most. Ties break by id so a replayed run picks the
--- same victim; falling back to nearest keeps the Reclaimer useful before
--- anyone has picked anything up.
local function heaviestTarget(pos: Types.Vec3, targets: { Target }): Target?
	local best: Target? = nil
	for _, target in targets do
		local weight = target.weight or 0
		if best == nil or weight > (best.weight or 0) or (weight == (best.weight or 0) and target.id < best.id) then
			best = target
		end
	end
	if best == nil or (best.weight or 0) <= 0 then
		return nearestTarget(pos, targets)
	end
	return best
end

--- Two points in the same room have no wall between them, so an entity may
--- steer straight at the second. With no level built, everything counts as the
--- same room — the bench harness and the M1 smoke tests run on open ground.
local function sameRoom(a: Types.Vec3, b: Types.Vec3): boolean
	local layout = LevelService.getLayout()
	if layout == nil then
		return true
	end
	return Path.nearestWaypoint(layout, a) == Path.nearestWaypoint(layout, b)
end

--- Where to actually steer, given where the entity wants to end up.
---
--- Steering alone walks into walls: `seek` is a straight line and the level is
--- not convex. Long-range routing is the waypoint graph's job, so this returns
--- the next hop along the path and lets steering handle the last few studs.
--- When both ends are in the same room there is no wall between them and the
--- entity goes direct.
local function routedTarget(entity: Types.Entity, goal: Types.Vec3): Types.Vec3
	local layout = LevelService.getLayout()
	if layout == nil then
		return goal -- no level built (bench harness, smoke tests): steer direct
	end

	local fromNode = Path.nearestWaypoint(layout, entity.pos)
	local toNode = Path.nearestWaypoint(layout, goal)
	if fromNode == toNode then
		return goal
	end

	local cached = navRoutes[entity.id]
	if cached == nil or cached.fromNode ~= fromNode or cached.toNode ~= toNode then
		local route = Path.find(layout, fromNode, toNode)
		local nextPos: Types.Vec3? = nil
		if route ~= nil and #route >= 2 then
			nextPos = layout.waypoints[route[2]].at
		end
		cached = { fromNode = fromNode, toNode = toNode, nextPos = nextPos }
		navRoutes[entity.id] = cached
	end

	return cached.nextPos or goal
end

--- Damage multiplier applied to `entity`, accounting for Warden shields.
---
--- A Warden shields everything near it until it dies, which is what makes it a
--- priority target rather than just a big one. Queried by CombatService at the
--- moment damage is applied, so a Warden dying mid-fight immediately stops
--- protecting its escort.
function EntityService.damageMultiplierFor(entity: Types.Entity): number
	local multiplier = 1
	for _, id in order do
		local other = entities[id]
		if other.kind ~= "Warden" or other.id == entity.id or not EntityState.isAlive(other) then
			continue
		end
		local config = (EnemiesConfig :: any).Warden
		if Types.distance(other.pos, entity.pos) <= config.shieldRadius then
			-- Shields do not stack: two Wardens are twice the problem to kill,
			-- not four times the effective health of everything near them.
			multiplier = math.min(multiplier, 1 - config.shieldReduction)
		end
	end
	return multiplier
end

--- Whether an entity is currently being shielded, for the client's outline and
--- for the diagnostics dump.
function EntityService.isShielded(entity: Types.Entity): boolean
	return EntityService.damageMultiplierFor(entity) < 1
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
		local behavior = config.behavior

		-- HuntHeaviest goes for the biggest carry rather than the closest body.
		local chosen = if behavior == "HuntHeaviest"
			then heaviestTarget(entity.pos, targets)
			else nearestTarget(entity.pos, targets)

		if chosen == nil then
			EntityState.transition(entity, "idle")
			entity.vel = { x = 0, y = 0, z = 0 }
			entity.targetId = nil
			continue
		end

		-- Recorded so `EnemyAttack` strikes whoever this entity actually chose.
		-- The field has existed on Types.Entity since M1 and was never assigned.
		entity.targetId = chosen.id
		local target = chosen.pos

		local distance = Types.distance(entity.pos, target)

		if distance <= config.atkRange then
			EntityState.transition(entity, "attack")
			entity.vel = { x = 0, y = 0, z = 0 }
			entity.yaw = Steering.facingYaw(Types.subVec3(target, entity.pos), entity.yaw)
			continue
		end

		-- A Sentry is area denial: it tracks and suppresses from where it
		-- stands and must be flanked. It never leaves "idle" for "move", so a
		-- client cannot read a walk animation off a turret.
		if behavior == "Static" then
			EntityState.transition(entity, "idle")
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

		-- Route around walls, then steer the last few studs.
		local waypoint = routedTarget(entity, target)

		-- A Lancer holds standoff against the target, but only once it can see
		-- it. Applying keepDistance to a doorway it is walking toward would
		-- make it back away from its own route and deadlock in the corridor.
		local seek
		if behavior == "KeepDistance" and sameRoom(entity.pos, target) then
			seek = Steering.keepDistance(entity.pos, target, config.preferredDistance or 40, config.speed)
		else
			seek = Steering.seek(entity.pos, waypoint, config.speed)
		end

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
	navRoutes = {}
	nextId = 1
	History.clear(history)
end

return EntityService
