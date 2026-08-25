--!strict
--[[ Applies enemy strikes to players.

	The adapter half of `core/sim/EnemyAttack`. Everything about *whether* a
	strike is legal and *how much* it does lives in core; what happens here is
	reading live entity state, and writing to a Humanoid.

	Server-authoritative for the same reason player damage is: the client owns
	its character's physics but must never own its health. A client that could
	report its own HP would simply report 100.

	Separate from `CombatService` deliberately. That module is one pipeline —
	validate a player's fire request against rewound history — and it is already
	640 lines of it. Enemy strikes share no step of that pipeline: there is no
	request to validate, no rate limit to enforce, no rewind, and no client
	prediction to reconcile. Folding them in would mean one module with two
	unrelated control flows and a shared name.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local EnemiesConfig = require(Shared.config.Enemies)
local EnemyAttack = require(Shared.core.sim.EnemyAttack)
local Types = require(Shared.core.Types)

local Remotes = require(Shared.net.Remotes)
local EntityService = require("./EntityService")
local TelemetryService = require("./TelemetryService")

local EnemyCombatService = {}

--- Per-kind stats, flattened once. Core cannot read config.
local STATS: { [string]: EnemyAttack.Stats } = {}
for kind, config in EnemiesConfig :: any do
	STATS[kind] = {
		dmg = config.dmg,
		atkRange = config.atkRange,
		atkCooldown = config.atkCooldown,
		falloffStart = config.falloffStart,
		minMultiplier = config.minMultiplier,
	}
end

--- Level geometry only, matching how `CombatService` validates player shots.
--- Characters and entities are excluded: an enemy should be blocked by a wall,
--- not by another enemy standing in front of it.
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Whitelist
sightParams.IgnoreWater = true

local function refreshSightFilter()
	local level = workspace:FindFirstChild("Level")
	sightParams.FilterDescendantsInstances = if level then { level } else {}
end

--- Whether an entity can actually see a player.
---
--- This is the asymmetry the whole difficulty problem came down to: player
--- shots have raycast against level geometry since M1 (`CombatService` step 6,
--- "wall"), and enemy attacks checked distance only. Sentries at 45 studs and
--- Lancers at 55 were shooting through walls from adjacent rooms, so there was
--- no such thing as cover and no way to break contact.
local function canSee(from: Types.Vec3, to: Types.Vec3): boolean
	local origin = Vector3.new(from.x, from.y, from.z)
	local finish = Vector3.new(to.x, to.y, to.z)
	local direction = finish - origin
	if direction.Magnitude < 1e-3 then
		return true
	end
	return workspace:Raycast(origin, direction, sightParams) == nil
end

--- Above this attack range a kind is treated as ranged and its shots are
--- drawn. Comfortably above every melee kind (Skitter 4, Hauler 6, Reclaimer
--- 6, Warden 8) and far below the ranged ones (Sentry 45, Lancer 55).
local MELEE_RANGE = 12

local state = EnemyAttack.new()

local metrics = {
	strikes = 0,
	damageDealt = 0,
	downs = 0,
	lastStrikeKind = "none",
}

--- Whether a player may currently be struck. Injected so extraction and death
--- rules stay owned by RunLifecycleService rather than duplicated here.
local canBeStruck: ((userId: number) -> boolean)? = nil

function EnemyCombatService.setStrikePredicate(predicate: (userId: number) -> boolean)
	canBeStruck = predicate
end

--- Live players as attack targets, with the humanoid needed to apply damage.
local function livingTargets(): ({ EnemyAttack.Target }, { [number]: Humanoid })
	local targets: { EnemyAttack.Target } = {}
	local humanoids: { [number]: Humanoid } = {}

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root ~= nil and root:IsA("BasePart") and humanoid ~= nil and humanoid.Health > 0 then
			if canBeStruck == nil or canBeStruck(player.UserId) then
				table.insert(targets, {
					id = player.UserId,
					pos = Types.vec3(root.Position.X, root.Position.Y, root.Position.Z),
				})
				humanoids[player.UserId] = humanoid
			end
		end
	end

	return targets, humanoids
end

local function attackers(): { EnemyAttack.Attacker }
	local out: { EnemyAttack.Attacker } = {}
	for _, view in EntityService.views() do
		local entity = EntityService.get(view.id)
		if entity ~= nil then
			table.insert(out, {
				id = entity.id,
				kind = entity.kind,
				pos = entity.pos,
				state = entity.state,
				targetId = entity.targetId,
			})
		end
	end
	return out
end

function EnemyCombatService.step(_tick: number, _dt: number)
	local targets, humanoids = livingTargets()
	if #targets == 0 then
		return
	end

	-- The level is rebuilt on run start and by the buildLevel diagnostic, so
	-- the whitelist cannot be captured once at require time.
	refreshSightFilter()

	local strikes = EnemyAttack.step(state, os.clock(), attackers(), targets, STATS, canSee)

	for _, strike in strikes do
		local humanoid = humanoids[strike.targetId]
		-- Re-check health: several entities can resolve in the same tick, and
		-- the first may have already killed the target. Without this, a swarm
		-- posts a death event per attacker.
		if humanoid == nil or humanoid.Health <= 0 then
			continue
		end

		humanoid:TakeDamage(strike.damage)

		-- Show the shot. Ranged kinds only: a Skitter biting you at three studs
		-- does not need a tracer, and drawing one would read as it shooting.
		--
		-- The damage above already landed, while the bolt takes about a tenth
		-- of a second to arrive. That mismatch is deliberate and small: a bolt
		-- slow enough to be honest would be slow enough to dodge, and the
		-- server has already decided the hit.
		local stats = STATS[strike.kind]
		if stats ~= nil and stats.atkRange > MELEE_RANGE then
			local entity = EntityService.get(strike.entityId)
			if entity ~= nil then
				Remotes.event("EnemyShot"):FireAllClients({
					kind = strike.kind,
					from = Vector3.new(entity.pos.x, entity.pos.y, entity.pos.z),
					to = humanoid.RootPart ~= nil and humanoid.RootPart.Position or Vector3.zero,
				})
			end
		end

		metrics.strikes += 1
		metrics.damageDealt += strike.damage
		metrics.lastStrikeKind = strike.kind

		if humanoid.Health <= 0 then
			metrics.downs += 1
			TelemetryService.emit("combat.down", {
				pid = tostring(strike.targetId),
				killerKind = strike.kind,
				entityId = strike.entityId,
				distance = strike.distance,
			})
		end
	end
end

function EnemyCombatService.getMetrics(): { [string]: any }
	return {
		strikes = metrics.strikes,
		damageDealt = metrics.damageDealt,
		downs = metrics.downs,
		lastStrikeKind = metrics.lastStrikeKind,
		pendingCooldowns = EnemyAttack.pendingCount(state),
	}
end

function EnemyCombatService.reset()
	state = EnemyAttack.new()
	metrics.strikes = 0
	metrics.damageDealt = 0
	metrics.downs = 0
	metrics.lastStrikeKind = "none"
end

return EnemyCombatService
