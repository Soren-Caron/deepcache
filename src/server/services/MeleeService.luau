--!strict
--[[ The melee sweep, server side.

	The adapter half of `core/sim/Sweep`. Core decides the geometry and the
	cooldown; this reads the character, applies damage, and tells clients.

	**The origin and facing come from the character, never from the request.**
	The client sends nothing but "I swung" -- no position, no direction, no
	target list. That is not caution for its own sake: an attack that trusted a
	client-supplied origin would let anyone sweep any room in the level from
	the drop point, and unlike a fire request there is no ray to sanity-check
	it against. Sending an empty request makes the whole class of forgery
	impossible rather than merely detectable.

	Separate from `CombatService` for the same reason `EnemyCombatService` is:
	it shares none of that pipeline. There is no rewind (a twelve-stud arc does
	not need lag compensation -- at that range interpolation error is smaller
	than the hitboxes), no ammunition, no per-shot rate limit, and no client
	prediction to reconcile.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local EnemiesConfig = require(Shared.config.Enemies)
local MeleeConfig = require(Shared.config.Melee)
local EntityState = require(Shared.core.sim.EntityState)
local Sweep = require(Shared.core.sim.Sweep)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)
local Wire = require(Shared.net.Wire)

local EntityService = require("./EntityService")
local TelemetryService = require("./TelemetryService")

local MeleeService = {}

local PARAMS: Sweep.Params = {
	damage = MeleeConfig.damage,
	arcRadians = math.rad(MeleeConfig.arcDegrees),
	radius = MeleeConfig.radius,
	cooldownSeconds = MeleeConfig.cooldownSeconds,
}

--- Corpses and mid-spawn entities are not targets, matching how a shot treats
--- them.
local SKIP_STATES: { [Types.EntityStateName]: boolean } = { death = true, spawn = true }

local HITBOX: { [string]: number } = {}
for kind, config in EnemiesConfig :: any do
	HITBOX[kind] = config.hitboxRadius
end

local lastSwingAt: { [Player]: number } = {}

local metrics = {
	swings = 0,
	refusedCooldown = 0,
	refusedNoCharacter = 0,
	hits = 0,
	kills = 0,
	damageDealt = 0,
	bestSwing = 0,
}

--- Walls stop a sword. Same whitelist shape `EnemyCombatService` uses: level
--- geometry only, so another enemy standing in front does not shield the one
--- behind it.
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Whitelist
sightParams.IgnoreWater = true

local function refreshSightFilter()
	local level = workspace:FindFirstChild("Level")
	sightParams.FilterDescendantsInstances = if level then { level } else {}
end

local function canSee(from: Types.Vec3, to: Types.Vec3): boolean
	local origin = Vector3.new(from.x, from.y, from.z)
	local finish = Vector3.new(to.x, to.y, to.z)
	local direction = finish - origin
	if direction.Magnitude < 1e-3 then
		return true
	end
	return workspace:Raycast(origin, direction, sightParams) == nil
end

--- Live entity views plus their hitbox radii, for the arc test.
local function targets(): ({ Types.EntityView }, { [number]: number })
	local views: { Types.EntityView } = {}
	local radii: { [number]: number } = {}
	for _, view in EntityService.views() do
		table.insert(views, view)
		radii[view.id] = HITBOX[view.kind] or 1.5
	end
	return views, radii
end

--- Whether this player may act at all. Injected so death and extraction rules
--- stay owned by RunLifecycleService.
local canAct: ((userId: number) -> boolean)? = nil

function MeleeService.setActionPredicate(predicate: (userId: number) -> boolean)
	canAct = predicate
end

--- Resolve one swing. Returns `(false, reason)` on refusal, per CLAUDE.md.
function MeleeService.swing(player: Player): (boolean, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") or humanoid == nil or humanoid.Health <= 0 then
		metrics.refusedNoCharacter += 1
		return false, "no_character"
	end
	if canAct ~= nil and not canAct(player.UserId) then
		return false, "not_active"
	end

	local now = os.clock()
	local ready, reason = Sweep.ready(lastSwingAt[player], now, PARAMS.cooldownSeconds)
	if not ready then
		metrics.refusedCooldown += 1
		return false, reason
	end
	lastSwingAt[player] = now

	refreshSightFilter()

	-- Facing from the character's own look vector, in the same yaw convention
	-- `Sweep` uses: atan2(x, z).
	local look = root.CFrame.LookVector
	local facingYaw = math.atan2(look.X, look.Z)
	local origin = Types.vec3(root.Position.X, root.Position.Y, root.Position.Z)

	local views, radii = targets()
	local hits = Sweep.resolve(origin, facingYaw, views, radii, PARAMS, SKIP_STATES, canSee)

	metrics.swings += 1
	local landed, killed, dealt = 0, 0, 0

	for index, hit in hits do
		if index > MeleeConfig.maxTargets then
			break
		end
		local entity = EntityService.get(hit.entityId)
		if entity == nil then
			continue
		end

		-- A Warden shielding this entity reduces what lands, exactly as it does
		-- for a bullet. Queried now rather than cached so killing the Warden
		-- helps on the very next swing.
		local damage = hit.damage * EntityService.damageMultiplierFor(entity)
		local applied, died = EntityState.applyDamage(entity, damage)
		landed += 1
		dealt += applied
		if died then
			killed += 1
			-- Impulse away from the player, which is the direction a sweep
			-- would actually throw a body.
			local away = Types.subVec3(entity.pos, origin)
			local direction = if Types.magnitude(away) > 1e-4
				then Types.normalize(away)
				else Types.vec3(0, 1, 0)
			Remotes.event("Ragdoll"):FireAllClients({
				entityId = entity.id,
				kind = entity.kind,
				deathPos = Wire.toVector3(entity.pos),
				deathDir = Wire.toVector3(direction),
				impulseMag = applied,
				killerWeapon = "Sweep",
			})
		end
	end

	metrics.hits += landed
	metrics.kills += killed
	metrics.damageDealt += dealt
	metrics.bestSwing = math.max(metrics.bestSwing, landed)

	-- Everyone sees the arc; only the swinger's client turns `hits` into a
	-- hitmarker.
	Remotes.event("MeleeSwing"):FireAllClients({
		by = player.UserId,
		from = root.Position,
		facing = facingYaw,
		hits = landed,
		radius = MeleeConfig.radius,
		arcDegrees = MeleeConfig.arcDegrees,
	})

	TelemetryService.emit("combat.sweep", {
		targets = landed,
		kills = killed,
		damage = math.floor(dealt),
	}, player.UserId)

	return true
end

function MeleeService.init()
	Remotes.event("MeleeRequest").OnServerEvent:Connect(function(player: Player)
		-- The request carries nothing. See the header: there is no field here
		-- to forge because there is no field.
		MeleeService.swing(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastSwingAt[player] = nil
	end)
end

function MeleeService.getMetrics(): { [string]: any }
	return {
		swings = metrics.swings,
		hits = metrics.hits,
		kills = metrics.kills,
		damageDealt = metrics.damageDealt,
		bestSwing = metrics.bestSwing,
		refusedCooldown = metrics.refusedCooldown,
		refusedNoCharacter = metrics.refusedNoCharacter,
		cooldownSeconds = MeleeConfig.cooldownSeconds,
		radius = MeleeConfig.radius,
		arcDegrees = MeleeConfig.arcDegrees,
	}
end

function MeleeService.reset()
	lastSwingAt = {}
	metrics.swings = 0
	metrics.hits = 0
	metrics.kills = 0
	metrics.damageDealt = 0
	metrics.bestSwing = 0
	metrics.refusedCooldown = 0
	metrics.refusedNoCharacter = 0
end

return MeleeService
