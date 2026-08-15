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

local DamageModel = require(Shared.core.sim.DamageModel)
local EntityState = require(Shared.core.sim.EntityState)
local FireValidation = require(Shared.core.sim.FireValidation)
local Raycast = require(Shared.core.sim.Raycast)
local History = require(Shared.core.net.History)
local Types = require(Shared.core.Types)

local Remotes = require(Shared.net.Remotes)
local Wire = require(Shared.net.Wire)
local EntityService = require("./EntityService")
local TickService = require("./TickService")

local CombatService = {}

type PlayerState = {
	buckets: { [string]: FireValidation.Bucket },
	ammo: { [string]: number },
	queue: { { request: Wire.FireRequest, receivedAt: number } },
}

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
		buckets[name] = FireValidation.newBucket(rate, 2, TickService.now())
		ammo[name] = weapon.magazine
	end

	local created: PlayerState = { buckets = buckets, ammo = ammo, queue = {} }
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
		rewindClamped = if rewound then rewound.clamped else false,
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

--------------------------------------------------------------------------------

function CombatService.init()
	Remotes.event("FireRequest").OnServerEvent:Connect(function(player, payload)
		-- 1. Shape. Remote payloads are attacker-controlled.
		local request = Wire.parseFireRequest(payload)
		if request == nil then
			return
		end

		local state = stateFor(player)
		-- Bound the queue: a client flooding requests must not grow it without
		-- limit. The rate bucket rejects them anyway, but not before they are
		-- allocated.
		if #state.queue >= 16 then
			return
		end

		metrics.requests += 1
		table.insert(state.queue, { request = request, receivedAt = TickService.now() })
	end)

	Players.PlayerRemoving:Connect(function(player)
		players[player] = nil
	end)
end

--- Registered as a TickService phase.
function CombatService.step(_tick: number, _dt: number)
	local now = TickService.now()
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
	CombatService.resetMetrics()
end

return CombatService
