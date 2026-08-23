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

local EntityService = require("./EntityService")
local TelemetryService = require("./TelemetryService")

local EnemyCombatService = {}

--- Per-kind stats, flattened once. Core cannot read config.
local STATS: { [string]: EnemyAttack.Stats } = {}
for kind, config in EnemiesConfig :: any do
	STATS[kind] = { dmg = config.dmg, atkRange = config.atkRange, atkCooldown = config.atkCooldown }
end

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
	local strikes = EnemyAttack.step(state, os.clock(), attackers(), targets, STATS)

	for _, strike in strikes do
		local humanoid = humanoids[strike.targetId]
		-- Re-check health: several entities can resolve in the same tick, and
		-- the first may have already killed the target. Without this, a swarm
		-- posts a death event per attacker.
		if humanoid == nil or humanoid.Health <= 0 then
			continue
		end

		humanoid:TakeDamage(strike.damage)
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
