--!strict
--[[ When an enemy in `attack` state actually lands a hit, and for how much.

	The adapter half of a gap that outlived five milestones: `EntityService`
	transitioned entities to `"attack"`, faced them at the target, and stopped.
	`Enemies.dmg` and `Enemies.atkCooldown` were read by nothing anywhere in
	`src/`, so a player could stand in a crowd indefinitely. M2-4's acceptance
	criterion measured *distance closed*, which is why it passed: it proved
	enemies arrive and said nothing about what happens next.

	Two rules shape everything here.

	**Arriving is not attacking.** An entity that reaches you must wait a full
	cooldown before its first hit. Striking on arrival means a swarm that closes
	simultaneously deletes a player in one tick with no counterplay, and it
	makes the Skitter's 0.8 s cooldown meaningless for the hit that actually
	matters. The windup is the reaction window.

	**Cooldowns are per entity, keyed by id, and must be reaped.** A long run
	spawns and kills hundreds of entities; a table keyed by id that only ever
	grows is a leak that a play session will never surface but a 12-minute run
	at 40 entities absolutely will.
]]

local Types = require("../Types")

export type Stats = {
	dmg: number,
	atkRange: number,
	atkCooldown: number,
}

--- One entity, as the attack resolver sees it. Mirrors the fields of
--- `Types.Entity` that matter and nothing else, so this stays testable without
--- constructing full entities.
export type Attacker = {
	id: number,
	kind: string,
	pos: Types.Vec3,
	state: string,
	targetId: number?,
}

export type Target = {
	id: number,
	pos: Types.Vec3,
}

export type Strike = {
	entityId: number,
	kind: string,
	targetId: number,
	damage: number,
	distance: number,
}

export type State = {
	--- entityId -> the time its next strike becomes legal.
	readyAt: { [number]: number },
}

local EnemyAttack = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function EnemyAttack.new(): State
	return { readyAt = {} }
end

--- Drop cooldown entries for entities that no longer exist. Called by `step`,
--- exposed for tests.
function EnemyAttack.reap(state: State, liveIds: { [number]: boolean })
	for id in state.readyAt do
		if not liveIds[id] then
			state.readyAt[id] = nil
		end
	end
end

function EnemyAttack.pendingCount(state: State): number
	local n = 0
	for _ in state.readyAt do
		n += 1
	end
	return n
end

--- Resolve every strike legal at `now`.
---
--- Mutates `state`. Returns the strikes to apply; applying them is the
--- adapter's job, because damage lands on a Humanoid and this module may not
--- know what one is.
function EnemyAttack.step(
	state: State,
	now: number,
	attackers: { Attacker },
	targets: { Target },
	stats: { [string]: Stats }
): { Strike }
	local strikes: { Strike } = {}

	if not isFinite(now) then
		-- A poisoned clock must not make every entity attack at once, nor
		-- advance any cooldown into a state it can never recover from.
		return strikes
	end

	local targetsById: { [number]: Target } = {}
	for _, target in targets do
		targetsById[target.id] = target
	end

	local live: { [number]: boolean } = {}

	for _, attacker in attackers do
		live[attacker.id] = true

		local config = stats[attacker.kind]
		if config == nil or attacker.state ~= "attack" then
			continue
		end

		local target = if attacker.targetId ~= nil then targetsById[attacker.targetId] else nil
		if target == nil then
			continue
		end

		local distance = Types.distance(attacker.pos, target.pos)
		if not isFinite(distance) or distance > config.atkRange then
			continue
		end

		local ready = state.readyAt[attacker.id]
		if ready == nil then
			-- First sighting: arm the cooldown rather than striking. See the
			-- "arriving is not attacking" rule above.
			state.readyAt[attacker.id] = now + math.max(0, config.atkCooldown)
			continue
		end

		if now < ready then
			continue
		end

		local damage = math.max(0, if isFinite(config.dmg) then config.dmg else 0)
		if damage > 0 then
			table.insert(strikes, {
				entityId = attacker.id,
				kind = attacker.kind,
				targetId = target.id,
				damage = damage,
				distance = distance,
			})
		end

		-- Advance from `now`, not from `ready`. Advancing from `ready` lets an
		-- entity that was out of range for ten seconds bank ten cooldowns and
		-- discharge them in ten consecutive ticks the moment it closes.
		state.readyAt[attacker.id] = now + math.max(0, config.atkCooldown)
	end

	EnemyAttack.reap(state, live)
	return strikes
end

return EnemyAttack
