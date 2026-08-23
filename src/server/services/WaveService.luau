--!strict
--[[ Spends the enemy budget into real entities.

	The adapter half of M2-8. `core/sim/Budget` has computed spawn plans since
	M2 and `core/sim/WaveScheduler` decides when to ask for one; this is the
	thin layer that resolves live game state into their arguments and turns the
	resulting plan into `EntityService.spawn` calls. All arithmetic lives in
	core — what happens here is lookups.

	Until this existed, `EntityService.spawn` was reachable only from
	diagnostics and benchmarks, so a real play session contained no enemies at
	all. That was invisible from inside the game (an empty room looks like a
	quiet room) and is why `WaveScheduler.Decision.reason` is surfaced in
	diagnostics rather than kept internal.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Budget = require(Shared.core.sim.Budget)
local WaveScheduler = require(Shared.core.sim.WaveScheduler)
local Rng = require(Shared.core.util.Rng)
local Types = require(Shared.core.Types)
local EnemiesConfig = require(Shared.config.Enemies)
local ZonesConfig = require(Shared.config.Zones)
local WavesConfig = require(Shared.config.Waves)

local EntityService = require("./EntityService")
local LevelService = require("./LevelService")
local DirectorService = require("./DirectorService")

local WaveService = {}

--- What the scheduler needs to know about the run, injected rather than
--- required: `RunLifecycleService` already reaches into most of the server,
--- and Bootstrap is where that wiring belongs.
export type RunView = {
	active: boolean,
	elapsedSeconds: number,
	headcount: number,
	seed: number,
}

local PARAMS: WaveScheduler.Params = {
	intervalSeconds = WavesConfig.INTERVAL_SECONDS,
	firstWaveDelaySeconds = WavesConfig.FIRST_WAVE_DELAY_SECONDS,
	maxAlive = WavesConfig.MAX_ALIVE,
	minWaveBudget = WavesConfig.MIN_WAVE_BUDGET,
}

--- Per-kind spawn cost, flattened once. `WaveScheduler.aliveValue` takes a
--- plain table so core never reads config.
local COSTS: { [string]: number } = {}
for kind, config in EnemiesConfig :: any do
	COSTS[kind] = config.budget
end

local ROSTER: { Budget.EnemyOption } = {}
for kind, config in EnemiesConfig :: any do
	table.insert(ROSTER, {
		kind = kind :: any,
		cost = config.budget,
		zones = config.zones,
		capPerWave = config.capPerWave,
		directorOnly = config.directorOnly,
	})
end
-- Sorted so a given rng state produces the same wave every time. Iteration
-- order over a hash table is not stable, and an unsorted roster would make
-- seeded runs irreproducible for no visible reason.
table.sort(ROSTER, function(a, b)
	return a.kind < b.kind
end)

local state = WaveScheduler.new()
local rng = Rng.new(1)
local seededFor = -1

local runProvider: (() -> RunView)? = nil

local metrics = {
	waves = 0,
	spawned = 0,
	reclaimersSummoned = 0,
	lastReason = "never_stepped",
	lastZone = "none",
	lastTargetBudget = 0,
	lastAliveValue = 0,
}

function WaveService.setRunProvider(provider: () -> RunView)
	runProvider = provider
end

--- The deepest zone any live player occupies.
---
--- A simplification, deliberately: pressure is a squad-level number and the
--- roster is zone-gated, so a single zone has to be chosen. Deepest rather
--- than nearest-player or most-populated because it is the zone the squad has
--- collectively earned, and because it degrades safely — the worst case is
--- that a straggler in Perimeter meets Vault-tier pressure, which is a harder
--- game rather than a broken one. With squads of 1-3 who move together it is
--- almost always unanimous anyway.
local function deepestPlayerZone(): string?
	local best: string? = nil
	local bestDepth = -1
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid == nil or humanoid.Health > 0 then
				local zone = LevelService.zoneAt(root.Position)
				local config = zone and (ZonesConfig :: any)[zone]
				if config ~= nil and config.depth > bestDepth then
					bestDepth = config.depth
					best = zone
				end
			end
		end
	end
	return best
end

--- Live entities by kind, and the total. Corpses are excluded from both: a
--- body on the floor is not pressure, and counting it would let a pile of
--- corpses hold the population ceiling closed and starve the wave.
local function census(): ({ [string]: number }, number)
	local counts: { [string]: number } = {}
	local alive = 0
	for _, view in EntityService.views() do
		local entity = EntityService.get(view.id)
		if entity ~= nil and entity.state ~= "death" then
			counts[entity.kind] = (counts[entity.kind] or 0) + 1
			alive += 1
		end
	end
	return counts, alive
end

--- Budget currently standing on the floor. This is `RunPressure.budgetSpent`,
--- which DirectorService has sent as a hardcoded 0 since M4.
function WaveService.aliveValue(): number
	local counts = census()
	return WaveScheduler.aliveValue(counts, COSTS)
end

function WaveService.step(tick: number, dt: number)
	local run = if runProvider ~= nil then runProvider() else nil
	local zone = deepestPlayerZone()
	local counts, aliveCount = census()
	local aliveValue = WaveScheduler.aliveValue(counts, COSTS)

	-- No resolvable zone means no roster and no spawn points, so it is not a
	-- state a wave can be planned in even though the run is live.
	local active = run ~= nil and run.active and zone ~= nil

	local targetBudget = 0
	local decision = DirectorService.getDecision()
	if active and run ~= nil and zone ~= nil then
		if run.seed ~= seededFor then
			-- Re-seed per run so a given run seed replays the same waves.
			rng = Rng.new(run.seed)
			seededFor = run.seed
		end
		targetBudget = Budget.compute(
			run.elapsedSeconds,
			run.headcount,
			(ZonesConfig :: any)[zone].budgetMultiplier,
			decision.spawnMultiplier
		)
	end

	local outcome = WaveScheduler.step(state, dt, {
		runActive = active,
		aliveCount = aliveCount,
		aliveValue = aliveValue,
		targetBudget = targetBudget,
	}, PARAMS)

	metrics.lastReason = outcome.reason
	metrics.lastZone = zone or "none"
	metrics.lastTargetBudget = targetBudget
	metrics.lastAliveValue = aliveValue

	if not outcome.spawn or zone == nil then
		return
	end

	local points = LevelService.spawnPointsFor(zone)
	if #points == 0 then
		-- Budget.plan treats this as programmer error and throws. Throwing
		-- inside a tick phase every interval would be a wall of identical
		-- errors, so it is reported once per attempt instead.
		metrics.lastReason = "no_spawn_points"
		return
	end

	local plan = Budget.plan({
		budget = outcome.budgetToSpend,
		zone = zone :: any,
		roster = ROSTER,
		caps = {},
		points = points,
		rng = rng,
	})

	local spawns = WaveScheduler.trim(plan.spawns, outcome.maxSpawns)
	for _, spawn in spawns do
		EntityService.spawn(spawn.kind, spawn.at, tick)
	end
	metrics.waves += 1
	metrics.spawned += #spawns

	-- docs/01: the Reclaimer is OVERSEER's most legible lever — it exists so
	-- the director's decisions are visible to players. It is `directorOnly`,
	-- so the budget planner never picks it; this is the only path that spawns
	-- one, and only when the director actually asked for that pattern.
	if
		decision.spawnPattern == "hunt_heaviest"
		and (counts.Reclaimer or 0) == 0
		and #spawns < outcome.maxSpawns
	then
		local point = points[Rng.nextRange(rng, 1, #points)]
		EntityService.spawn("Reclaimer", Types.vec3(point.x, point.y, point.z), tick)
		metrics.reclaimersSummoned += 1
		metrics.spawned += 1
	end
end

function WaveService.reset()
	state = WaveScheduler.new()
	seededFor = -1
	metrics.waves = 0
	metrics.spawned = 0
	metrics.reclaimersSummoned = 0
	metrics.lastReason = "reset"
end

function WaveService.describe(): { [string]: any }
	local counts, aliveCount = census()
	local info = WaveScheduler.describe(state)
	info.waves = metrics.waves
	info.spawned = metrics.spawned
	info.reclaimersSummoned = metrics.reclaimersSummoned
	info.lastReason = metrics.lastReason
	info.lastZone = metrics.lastZone
	info.targetBudget = metrics.lastTargetBudget
	info.aliveValue = metrics.lastAliveValue
	info.aliveCount = aliveCount
	info.maxAlive = PARAMS.maxAlive
	info.census = counts
	return info
end

return WaveService
