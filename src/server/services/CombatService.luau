--!strict
--[[
	Fire request validation, with lag compensation.

	Requests are queued as they arrive and resolved at a tick boundary, so two
	shots in the same tick resolve in a defined order rather than racing.

	Pipeline, cheapest rejection first — an aimbot spamming requests should cost
	a float comparison, not a raycast:

	  1. shape        malformed payloads never reach game logic
	  2. rate         token bucket per weapon
	  3. ammo         server-side count
	  4. origin       implausible muzzle position is replaced, not rejected
	  5. rewind       entity positions as the shooter saw them
	  6. wall         engine raycast against level geometry only
	  7. entity       pure ray-sphere against rewound hitboxes, nearer than the wall
	  8. damage       falloff, headshot, armor

	Steps 5-7 are the reason this exists. Validating against the present would
	make every moving target unhittable at any real latency.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local WeaponsConfig = require(Shared.config.Weapons)
local EnemiesConfig = require(Shared.config.Enemies)

local Ballistics = require(Shared.core.sim.Ballistics)
local DamageModel = require(Shared.core.sim.DamageModel)
local EntityState = require(Shared.core.sim.EntityState)
local FireValidation = require(Shared.core.sim.FireValidation)
local Raycast = require(Shared.core.sim.Raycast)
local History = require(Shared.core.net.History)
local Types = require(Shared.core.Types)

local Remotes = require(Shared.net.Remotes)
local Wire = require(Shared.net.Wire)
local EntityService = require("./EntityService")
local TelemetryService = require("./TelemetryService")
local TickService = require("./TickService")

local CombatService = {}

--- Sustained-fire state for a beam weapon: which entity it is on, and for how
--- long. Lives per player per weapon because the ramp is the weapon's whole
--- identity — see `core/sim/Ballistics`.
type BeamState = { targetId: number?, seconds: number, lastTick: number }

type PlayerState = {
	buckets: { [string]: FireValidation.Bucket },
	ammo: { [string]: number },
	queue: { { request: Wire.FireRequest, receivedAt: number } },
	beams: { [string]: BeamState },
}

--- A Slug in flight. It is a real thing in the world with a position, which is
--- exactly why it needs no lag compensation: a hit is decided by where the
--- projectile *is*, not by rewinding to where a target *was*.
type Projectile = {
	owner: Player,
	weaponId: string,
	seq: number,
	pos: Types.Vec3,
	vel: Types.Vec3,
	gravity: number,
	travelled: number,
	maxRange: number,
	character: Model?,
}

local projectiles: { Projectile } = {}

export type Metrics = {
	requests: number,
	hits: number,
	rejectedRate: number,
	rejectedAmmo: number,
	originSubstituted: number,
	rewindClamped: number,
}

--- Ring of the last few resolutions with their internal decisions. Without
--- this, a shot that "just misses" gives you nothing to debug — every metric
--- reads clean because no rule rejected it.
export type Trace = {
	seq: number,
	rewindAgeMs: number,
	rewindClamped: boolean,
	candidates: number,
	withRadius: number,
	wallDistance: number,
	wallInstance: string,
	hitId: number?,
	hitDistance: number?,
	outcome: string,
}

local traces: { Trace } = {}
local TRACE_LIMIT = 20

local function pushTrace(trace: Trace)
	table.insert(traces, trace)
	if #traces > TRACE_LIMIT then
		table.remove(traces, 1)
	end
end

local players: { [Player]: PlayerState } = {}
local metrics: Metrics = {
	requests = 0,
	hits = 0,
	rejectedRate = 0,
	rejectedAmmo = 0,
	originSubstituted = 0,
	rewindClamped = 0,
}

--- Corpses and entities still spawning are not hittable.
local UNHITTABLE: { [Types.EntityStateName]: boolean } = { death = true, spawn = true }

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

local function stateFor(player: Player): PlayerState
	local existing = players[player]
	if existing then
		return existing
	end

	local buckets: { [string]: FireValidation.Bucket } = {}
	local ammo: { [string]: number } = {}
	for name, weapon in WeaponsConfig :: any do
		local rate = if weapon.kind == "beam" then 20 else weapon.rps
		-- Capacity must cover a full burst. The Carbine fires 3 rounds faster
		-- than its sustained rate, so a 2-token bucket rejects the third round
		-- of every burst as a rate violation — the weapon would be unusable in
		-- exactly the way it is designed to be used.
		local capacity = math.max(2, weapon.burst or 0)
		buckets[name] = FireValidation.newBucket(rate, capacity, TickService.now())
		ammo[name] = weapon.magazine
	end

	local created: PlayerState = { buckets = buckets, ammo = ammo, queue = {}, beams = {} }
	players[player] = created
	return created
end

function CombatService.getMetrics(): Metrics
	return table.clone(metrics)
end

function CombatService.getTraces(): { Trace }
	return table.clone(traces)
end

function CombatService.resetMetrics()
	metrics = {
		requests = 0,
		hits = 0,
		rejectedRate = 0,
		rejectedAmmo = 0,
		originSubstituted = 0,
		rewindClamped = 0,
	}
end

--- Refill a magazine. Reload timing and UI land in M2; this is the hook.
function CombatService.reload(player: Player, weaponId: string)
	local weapon = (WeaponsConfig :: any)[weaponId]
	if weapon == nil then
		return
	end
	stateFor(player).ammo[weaponId] = weapon.magazine
	Remotes.event("AmmoSync"):FireClient(player, { weaponId = weaponId, ammo = weapon.magazine })
end

--------------------------------------------------------------------------------

local function reject(player: Player, seq: number, reason: string)
	Remotes.event("FireResult"):FireClient(player, {
		seq = seq,
		hit = false,
		rejected = reason,
	})
end

--- Apply damage and tell the shooter. Shared by all three weapon paths so the
--- falloff, headshot and Warden-shield rules cannot drift between them.
local function damageEntity(
	player: Player,
	seq: number,
	entity: Types.Entity,
	weaponId: string,
	weapon: any,
	baseDamage: number,
	distance: number,
	hitPoint: Types.Vec3,
	allowHeadshot: boolean
): (number, boolean)
	local enemyConfig = (EnemiesConfig :: any)[entity.kind]
	local headshot = allowHeadshot and Raycast.isHeadshot(hitPoint, entity.pos, entity.hitboxRadius)

	local damage = DamageModel.compute({
		baseDamage = baseDamage,
		distance = distance,
		falloffStart = weapon.falloffStart,
		falloffEnd = weapon.falloffEnd,
		minMultiplier = weapon.minMultiplier,
		armor = enemyConfig.armor or 0,
		headshot = headshot,
		headshotMultiplier = weapon.headshotMultiplier,
	})

	-- A Warden shielding this entity reduces what lands. Queried now rather
	-- than cached, so killing the Warden helps on the very next shot.
	damage *= EntityService.damageMultiplierFor(entity)

	local applied, died = EntityState.applyDamage(entity, damage)
	metrics.hits += 1

	TelemetryService.emit("combat.hit", {
		weapon = weaponId,
		targetKind = entity.kind,
		damage = applied,
		distance = math.floor(distance),
		headshot = headshot,
		died = died,
		shielded = EntityService.isShielded(entity),
	}, player.UserId)

	Remotes.event("FireResult"):FireClient(player, {
		seq = seq,
		hit = true,
		entityId = entity.id,
		damage = applied,
		died = died,
		hitPos = Wire.toVector3(hitPoint),
	})

	if died then
		-- M7-4. Fired to ALL clients, not just the shooter: everyone in the
		-- fight should see the body. docs/08 keeps ragdoll physics entirely
		-- client-side, so this carries only what each client needs to start
		-- its own simulation. Two players ending up with different poses is
		-- expected and costs nothing, because nothing in the game reads corpse
		-- position.
		--
		-- The impulse direction is derived from the hit geometry that is
		-- already here -- centre minus impact point, which runs from the
		-- surface the round struck into the body, i.e. roughly the way the
		-- round was travelling. Threading the shot direction down through the
		-- whole damage call chain would touch every caller to deliver one
		-- vector that can be reconstructed on the spot.
		local impact = Types.subVec3(entity.pos, hitPoint)
		local impulseDir = if Types.magnitude(impact) > 1e-4
			then Types.normalize(impact)
			else Types.vec3(0, 1, 0)
		Remotes.event("Ragdoll"):FireAllClients({
			entityId = entity.id,
			kind = entity.kind,
			deathPos = Wire.toVector3(entity.pos),
			deathDir = Wire.toVector3(impulseDir),
			impulseMag = applied,
			killerWeapon = weaponId,
		})
	end
	return applied, died
end

--- Nearest live entity along a segment, stopping at level geometry.
local function traceSegment(
	origin: Types.Vec3,
	direction: Types.Vec3,
	maxDistance: number,
	ignore: Instance?,
	candidates: { Types.EntityView }
): (Raycast.SphereHit?, number)
	wallParams.FilterDescendantsInstances = if ignore then { ignore } else {}
	local wallHit = workspace:Raycast(
		Wire.toVector3(origin),
		Wire.toVector3(direction) * maxDistance,
		wallParams
	)
	local wallDistance = if wallHit then wallHit.Distance else maxDistance

	local radii: { [number]: number } = {}
	for _, view in candidates do
		local entity = EntityService.get(view.id)
		if entity then
			radii[view.id] = entity.hitboxRadius
		end
	end

	return Raycast.nearestEntity(origin, direction, candidates, radii, wallDistance, UNHITTABLE), wallDistance
end

local function resolve(player: Player, request: Wire.FireRequest, now: number)
	local state = stateFor(player)
	local weapon = (WeaponsConfig :: any)[request.weaponId]
	if weapon == nil then
		reject(player, request.seq, "unknown_weapon")
		return
	end

	-- 2. Rate
	if not FireValidation.tryConsume(state.buckets[request.weaponId], now) then
		metrics.rejectedRate += 1
		reject(player, request.seq, "rate")
		return
	end

	-- 3. Ammo
	local remaining = state.ammo[request.weaponId] or 0
	if remaining <= 0 then
		metrics.rejectedAmmo += 1
		reject(player, request.seq, "ammo")
		return
	end
	state.ammo[request.weaponId] = remaining - 1

	-- 4. Origin
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		reject(player, request.seq, "no_character")
		return
	end

	local serverKnown = Wire.toVec3(root.Position)
	local claimed = Wire.toVec3(request.origin)
	local origin, substituted = FireValidation.reconcileOrigin(
		claimed,
		serverKnown,
		NetcodeConfig.ORIGIN_TOLERANCE
	)
	if substituted then
		metrics.originSubstituted += 1
	end

	local direction = FireValidation.sanitizeDirection(Wire.toVec3(request.direction))
	if direction == nil then
		reject(player, request.seq, "bad_direction")
		return
	end

	TelemetryService.emit("combat.fire", {
		weapon = request.weaponId,
		kind = weapon.kind,
		rttMs = math.floor((now - request.clientTime) * 1000),
	}, player.UserId)

	-- Projectile and beam weapons diverge here, before lag compensation,
	-- because neither one needs it. A Slug is an object in the world; an Arc
	-- is contact evaluated this tick. Rewinding either would be answering a
	-- question nobody asked.
	if weapon.kind == "projectile" then
		table.insert(projectiles, {
			owner = player,
			weaponId = request.weaponId,
			seq = request.seq,
			pos = origin,
			vel = Ballistics.velocityAt(direction, weapon.projectileSpeed, weapon.gravity, 0),
			gravity = weapon.gravity,
			travelled = 0,
			maxRange = weapon.range,
			character = character,
		})
		-- Not a hit and not a rejection: the shot is away and its outcome
		-- arrives later. The client predicts a tracer, never a hitmarker.
		Remotes.event("FireResult"):FireClient(player, { seq = request.seq, hit = false, inFlight = true })
		return
	end

	if weapon.kind == "beam" then
		CombatService.resolveBeam(player, state, request, weapon, origin, direction, now)
		return
	end

	-- 5. Rewind
	local fireTime, clamped = FireValidation.clampFireTime(
		request.clientTime,
		now,
		NetcodeConfig.LAGCOMP_WINDOW
	)
	if clamped then
		metrics.rewindClamped += 1
	end

	local rewound = History.rewind(EntityService.getHistory(), fireTime, now)
	local candidates: { Types.EntityView } = if rewound then rewound.entities else EntityService.views()

	-- 6. Wall — engine raycast against level geometry only. Entities have no
	-- server Instance, so nothing here can collide with them.
	wallParams.FilterDescendantsInstances = { character }
	local maxRange = weapon.range
	local wallHit = workspace:Raycast(
		Wire.toVector3(origin),
		Wire.toVector3(direction) * maxRange,
		wallParams
	)
	local wallDistance = if wallHit then wallHit.Distance else maxRange

	-- 7. Entity
	local radii: { [number]: number } = {}
	for _, view in candidates do
		local entity = EntityService.get(view.id)
		if entity then
			radii[view.id] = entity.hitboxRadius
		end
	end

	local hit = Raycast.nearestEntity(origin, direction, candidates, radii, wallDistance, UNHITTABLE)

	local withRadius = 0
	for _ in radii do
		withRadius += 1
	end
	local trace: Trace = {
		seq = request.seq,
		rewindAgeMs = (now - (if rewound then rewound.actualTime else now)) * 1000,
		-- Report the *effective* clamp from clampFireTime, not History's.
		-- History receives an already-clamped time, so its own flag is always
		-- false and reads as "no clamping happened" when the opposite is true.
		rewindClamped = clamped,
		candidates = #candidates,
		withRadius = withRadius,
		wallDistance = wallDistance,
		wallInstance = if wallHit then wallHit.Instance:GetFullName() else "none",
		hitId = if hit then hit.entityId else nil,
		hitDistance = if hit then hit.distance else nil,
		outcome = if hit then "hit" else "miss",
	}
	pushTrace(trace)

	if hit == nil then
		Remotes.event("FireResult"):FireClient(player, { seq = request.seq, hit = false })
		return
	end

	local entity = EntityService.get(hit.entityId)
	if entity == nil or not EntityState.isAlive(entity) then
		Remotes.event("FireResult"):FireClient(player, { seq = request.seq, hit = false })
		return
	end

	-- 8. Damage
	local enemyConfig = (EnemiesConfig :: any)[entity.kind]
	local headshot = Raycast.isHeadshot(hit.point, entity.pos, entity.hitboxRadius)
	local damage = DamageModel.compute({
		baseDamage = weapon.damage or weapon.damagePerSecond or 0,
		distance = hit.distance,
		falloffStart = weapon.falloffStart,
		falloffEnd = weapon.falloffEnd,
		minMultiplier = weapon.minMultiplier,
		armor = enemyConfig.armor or 0,
		headshot = headshot,
		headshotMultiplier = weapon.headshotMultiplier,
	})

	local applied, died = EntityState.applyDamage(entity, damage)
	metrics.hits += 1

	Remotes.event("FireResult"):FireClient(player, {
		seq = request.seq,
		hit = true,
		entityId = entity.id,
		damage = applied,
		died = died,
		hitPos = Wire.toVector3(hit.point),
	})
end

--- Arc. Validated per tick against the present rather than per shot against
--- the past: there is no discrete event to rewind to, only "is the beam on
--- this target right now, and for how long has it been".
function CombatService.resolveBeam(
	player: Player,
	state: PlayerState,
	request: Wire.FireRequest,
	weapon: any,
	origin: Types.Vec3,
	direction: Types.Vec3,
	now: number
)
	local beam = state.beams[request.weaponId]
	if beam == nil then
		beam = { targetId = nil, seconds = 0, lastTick = now }
		state.beams[request.weaponId] = beam
	end

	local dt = math.clamp(now - beam.lastTick, 0, 0.25)
	beam.lastTick = now

	local hit = traceSegment(origin, direction, weapon.range, player.Character, EntityService.views())
	local entity = if hit then EntityService.get(hit.entityId) else nil
	if entity ~= nil and not EntityState.isAlive(entity) then
		entity = nil
	end

	local onSameTarget = entity ~= nil and beam.targetId == entity.id
	beam.seconds = Ballistics.arcTick(beam.seconds, dt, onSameTarget)
	beam.targetId = if entity then entity.id else nil

	if entity == nil or hit == nil then
		Remotes.event("FireResult"):FireClient(player, { seq = request.seq, hit = false })
		return
	end

	local ramp = Ballistics.arcRamp(beam.seconds, weapon.rampPerSecond, weapon.rampMax)
	local tickDamage = Ballistics.arcDamage(dt, weapon.damagePerSecond, ramp)

	-- Headshots are off for the beam: it is a sustained contact weapon, and a
	-- multiplier that flickered as the beam drifted across a hitbox would be
	-- noise rather than skill. `headshotMultiplier` is 1.0 in config anyway.
	damageEntity(player, request.seq, entity, request.weaponId, weapon, tickDamage, hit.distance, hit.point, false)
end

--- Advance every Slug in flight by one tick. Runs before queued requests are
--- resolved, so a projectile fired last tick lands before a new one is
--- created and the order of events in a burst stays defined.
function CombatService.stepProjectiles(dt: number)
	if #projectiles == 0 then
		return
	end

	local surviving: { Projectile } = {}
	local views = EntityService.views()

	for _, projectile in projectiles do
		local weapon = (WeaponsConfig :: any)[projectile.weaponId]
		local nextPos, nextVel = Ballistics.step(projectile.pos, projectile.vel, projectile.gravity, dt)

		local delta = Types.subVec3(nextPos, projectile.pos)
		local segment = Types.magnitude(delta)
		if segment <= 1e-6 then
			continue -- degenerate step; drop rather than loop forever
		end
		local direction = Types.normalize(delta)

		local hit = traceSegment(projectile.pos, direction, segment, projectile.character, views)
		if hit ~= nil then
			local entity = EntityService.get(hit.entityId)
			if entity ~= nil and EntityState.isAlive(entity) then
				damageEntity(
					projectile.owner,
					projectile.seq,
					entity,
					projectile.weaponId,
					weapon,
					weapon.damage,
					projectile.travelled + hit.distance,
					hit.point,
					true
				)
			end
			continue -- spent, whether it hit an entity or a wall
		end

		projectile.pos = nextPos
		projectile.vel = nextVel
		projectile.travelled += segment

		-- Range is measured along the flight path, not as straight-line
		-- distance, so a lobbed shot is not secretly longer-ranged.
		if projectile.travelled < projectile.maxRange and projectile.owner.Parent ~= nil then
			table.insert(surviving, projectile)
		end
	end

	projectiles = surviving
end

function CombatService.projectileCount(): number
	return #projectiles
end

--------------------------------------------------------------------------------

--- Enqueue an already-shape-checked request.
---
--- The remote handler and the diagnostics probes share this so a scripted shot
--- travels the identical path a real one does — queueing, rate limiting, ammo,
--- lag compensation and all. A probe that bypassed the queue would be testing
--- a code path no player can reach.
function CombatService.submit(player: Player, request: Wire.FireRequest): boolean
	local state = stateFor(player)
	-- Bound the queue: a client flooding requests must not grow it without
	-- limit. The rate bucket rejects them anyway, but not before they are
	-- allocated.
	if #state.queue >= 16 then
		return false
	end
	metrics.requests += 1
	table.insert(state.queue, { request = request, receivedAt = TickService.now() })
	return true
end

function CombatService.init()
	Remotes.event("FireRequest").OnServerEvent:Connect(function(player, payload)
		-- 1. Shape. Remote payloads are attacker-controlled.
		local request = Wire.parseFireRequest(payload)
		if request == nil then
			return
		end

		CombatService.submit(player, request)
	end)

	Players.PlayerRemoving:Connect(function(player)
		players[player] = nil
	end)
end

--- Registered as a TickService phase.
function CombatService.step(_tick: number, dt: number)
	local now = TickService.now()
	CombatService.stepProjectiles(dt)
	for player, state in players do
		if player.Parent == nil then
			continue
		end
		local queued = state.queue
		state.queue = {}
		for _, entry in queued do
			local ok, err = pcall(resolve, player, entry.request, now)
			if not ok then
				warn(`[CombatService] resolve failed for {player.Name}: {err}`)
			end
		end
	end
end

function CombatService.reset()
	players = {}
	projectiles = {}
	CombatService.resetMetrics()
end

return CombatService
