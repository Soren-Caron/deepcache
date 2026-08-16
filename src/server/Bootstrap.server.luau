--!strict
--[[
	Server startup.

	Order matters and is documented in docs/02-ARCHITECTURE.md §Boot order.
	Nothing here may block on network I/O — services that need the backend
	(telemetry, OVERSEER, economy config) start with compiled-in defaults and
	catch up asynchronously.

	Phase order inside the tick is the other half of the contract:
	simulate -> record history -> resolve combat -> guard movement -> replicate.
	Combat must resolve against history recorded this tick, and replication must
	see the results of combat, or a kill takes an extra tick to appear.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Branding = require(Shared.config.Branding)
local Rooms = require(Shared.config.Rooms)
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)

local TickService = require("./services/TickService")
local LevelService = require("./services/LevelService")
local EntityService = require("./services/EntityService")
local ReplicationService = require("./services/ReplicationService")
local CombatService = require("./services/CombatService")
local MovementGuardService = require("./services/MovementGuardService")
local Diagnostics = require("./services/Diagnostics")
local TickBench = require("./smoke/TickBench")

--- Carried weight per player, which HuntHeaviest reads. LootService owns this
--- once M2-6's adapter lands; until then it is set by the roster probe so the
--- Reclaimer's targeting can be verified without a full loot pipeline.
local carriedWeight: { [number]: number } = {}

local function playerTargets(): { EntityService.Target }
	local out: { EntityService.Target } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid == nil or humanoid.Health > 0 then
				table.insert(out, {
					id = player.UserId,
					pos = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z },
					weight = carriedWeight[player.UserId] or 0,
				})
			end
		end
	end
	return out
end

local function main()
	Remotes.init()

	-- The level exists before anything that spawns into it. M2-7 takes over
	-- seed selection when the run lifecycle lands; until then every boot builds
	-- the same level, which is what makes a Studio session repeatable.
	local layout = LevelService.build(Rooms.defaultSeed)

	ReplicationService.init()
	CombatService.init()
	MovementGuardService.init()

	EntityService.setTargetProvider(playerTargets)

	TickService.addPhase("sim", EntityService.step)
	TickService.addPhase("history", EntityService.recordHistory)
	TickService.addPhase("combat", CombatService.step)
	TickService.addPhase("movement", MovementGuardService.step)
	TickService.addPhase("replication", ReplicationService.step)

	-- Diagnostics must be registered from this context: the command bar has its
	-- own module registry and would otherwise see fresh, idle service instances.
	Diagnostics.init()
	Diagnostics.register("tickStats", TickService.getStats)
	Diagnostics.register("resetStats", TickService.resetStats)
	Diagnostics.register("entityCount", EntityService.count)
	Diagnostics.register("combatMetrics", CombatService.getMetrics)
	Diagnostics.register("combatTraces", CombatService.getTraces)
	-- Spawn, kill, and watch one entity's corpse in a single call. Split across
	-- separate calls the round-trip latency exceeds the corpse lifetime and the
	-- measurement always reads zero.
	Diagnostics.register("corpseProbe", function()
		local EntityState = require(Shared.core.sim.EntityState)
		local tick = TickService.getTick()
		local entity = EntityService.spawn("Sentry", { x = 40, y = 4, z = 0 }, tick)
		task.wait(0.2)

		local _, died = EntityState.applyDamage(entity, 99999)
		local killedAtTick = TickService.getTick()

		local timeline = {}
		for _ = 1, 18 do
			local live = EntityService.get(entity.id)
			table.insert(timeline, string.format(
				"tickDelta=%d count=%d state=%s",
				TickService.getTick() - killedAtTick,
				EntityService.count(),
				live and live.state or "reaped"
			))
			task.wait(0.1)
		end
		return { died = died, corpseTicks = EntityState.CORPSE_TICKS, timeline = timeline }
	end)

	Diagnostics.register("reload", function(weaponId: string?)
		local id = weaponId or "Sidearm"
		for _, player in Players:GetPlayers() do
			CombatService.reload(player, id)
		end
		return `reloaded {id} for {#Players:GetPlayers()} player(s)`
	end)

	Diagnostics.register("entityDump", function()
		local rows = {}
		for _, view in EntityService.views() do
			local e = EntityService.get(view.id)
			if e then
				table.insert(rows, string.format(
					"id=%d kind=%s state=%s hp=%.0f/%.0f pos=(%.1f,%.1f,%.1f) vel=(%.2f,%.2f,%.2f)",
					e.id, e.kind, e.state, e.hp, e.maxHp,
					e.pos.x, e.pos.y, e.pos.z, e.vel.x, e.vel.y, e.vel.z
				))
			end
		end
		return rows
	end)

	Diagnostics.register("historyDump", function()
		local History = require(Shared.core.net.History)
		local h = EntityService.getHistory()
		local now = TickService.now()
		local rows = {}
		for age = 1, History.frameCount(h) do
			local frame = h.frames.items[(h.frames.head - age - 1) % h.frames.capacity + 1]
			if frame then
				table.insert(rows, string.format("age=%d tick=%d ageMs=%.1f entities=%d",
					age, frame.tick, (now - frame.time) * 1000, #frame.entities))
			end
		end
		return { frameCount = History.frameCount(h), oldestMs = (now - (History.oldestTime(h) or now)) * 1000, rows = rows }
	end)
	-- Level. `buildLevel` takes a seed so a layout seen in a report can be
	-- reproduced in the world; M2-7 will own per-run seed selection.
	Diagnostics.register("buildLevel", function(seed: number?)
		LevelService.build(seed or Rooms.defaultSeed)
		return LevelService.describe()
	end)
	Diagnostics.register("levelInfo", LevelService.describe)
	Diagnostics.register("clearLevel", function()
		LevelService.clear()
		return "level cleared, scaffolding restored"
	end)

	-- M2-4 acceptance: one of each enemy spawns and does what its row in
	-- Enemies.luau says. Spawns them in a ring around the player, steps the
	-- live tick loop, and reports how each one moved — a Sentry that walked or
	-- a Lancer that closed to melee shows up as a number here.
	Diagnostics.register("rosterProbe", function(seconds: number?)
		local player = Players:GetPlayers()[1]
		if player == nil or player.Character == nil then
			return { error = "no player in the session" }
		end
		local root = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart
		local origin = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }

		-- Give the player a carry so HuntHeaviest has something to prefer.
		carriedWeight[player.UserId] = 60

		local kinds = { "Skitter", "Sentry", "Hauler", "Lancer", "Warden", "Reclaimer" }
		local spawned: { [string]: Types.Entity } = {}
		local startDistance: { [string]: number } = {}
		local tick = TickService.getTick()
		for index, kind in kinds do
			local angle = (index / #kinds) * math.pi * 2
			local at = { x = origin.x + math.cos(angle) * 70, y = origin.y, z = origin.z + math.sin(angle) * 70 }
			spawned[kind] = EntityService.spawn(kind :: any, at, tick)
			startDistance[kind] = Types.distance(at, origin)
		end

		task.wait(seconds or 4)

		local rows: { string } = {}
		for _, kind in kinds do
			local entity = EntityService.get(spawned[kind].id)
			if entity == nil then
				table.insert(rows, `{kind}: despawned`)
				continue
			end
			local now = Types.distance(entity.pos, origin)
			local config = (require(Shared.config.Enemies) :: any)[kind]
			table.insert(rows, string.format(
				"%-9s %-13s state=%-6s dist %6.1f -> %6.1f (%+.1f)  speed=%.1f  shielded=%s",
				kind, config.behavior, entity.state, startDistance[kind], now,
				now - startDistance[kind], Types.magnitude(entity.vel),
				tostring(EntityService.isShielded(entity))
			))
		end

		carriedWeight[player.UserId] = 0
		for _, kind in kinds do
			EntityService.remove(spawned[kind].id)
		end
		return rows
	end)

	-- M2-3/M2-4: an entity spawned rooms away must route to the player through
	-- doorways rather than pressing into the wall between them. Reports the
	-- distance trace, so "stuck against geometry" and "walking the long way
	-- round" are distinguishable rather than both reading as slow.
	Diagnostics.register("navProbe", function(moduleIndex: number?, samples: number?)
		local player = Players:GetPlayers()[1]
		if player == nil or player.Character == nil then
			return { error = "no player in the session" }
		end
		local layout = LevelService.getLayout()
		if layout == nil then
			return { error = "no level built" }
		end
		local root = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart

		-- Default to the deepest module: the longest possible route.
		local index = moduleIndex or layout.pads[#layout.pads].moduleIndex
		local module_ = layout.modules[index]
		local at = { x = module_.at.x, y = root.Position.Y, z = module_.at.z }

		local entity = EntityService.spawn("Skitter", at, TickService.getTick())
		local trace: { string } = {}
		local previous = Types.distance(entity.pos, {
			x = root.Position.X, y = root.Position.Y, z = root.Position.Z,
		})
		local startDistance = previous
		local stalled = 0

		for sample = 1, samples or 10 do
			task.wait(1)
			local live = EntityService.get(entity.id)
			if live == nil then
				break
			end
			local target = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
			local distance = Types.distance(live.pos, target)
			local progress = previous - distance
			if progress < 1 then
				stalled += 1
			end
			table.insert(trace, string.format("t=%2ds dist=%6.1f  moved %+5.1f  speed=%4.1f",
				sample, distance, progress, Types.magnitude(live.vel)))
			previous = distance
		end

		EntityService.remove(entity.id)
		return {
			startedFrom = `{module_.id} (module {index}, {module_.zone}, hop {module_.hop})`,
			startDistance = math.floor(startDistance),
			endDistance = math.floor(previous),
			closed = math.floor(startDistance - previous),
			stalledSamples = stalled,
			trace = trace,
		}
	end)

	Diagnostics.register("setCarriedWeight", function(weight: number)
		local player = Players:GetPlayers()[1]
		if player == nil then
			return "no player"
		end
		carriedWeight[player.UserId] = weight
		return `carried weight for {player.Name} set to {weight}`
	end)

	Diagnostics.register("movementMetrics", MovementGuardService.getMetrics)
	Diagnostics.register("bandwidth", ReplicationService.sampleBandwidth)
	Diagnostics.register("bench", TickBench.run)
	Diagnostics.register("benchSweep", TickBench.sweep)
	-- `height` matters: at y = 0 an entity sits half-inside the baseplate, and
	-- the wall raycast then hits the floor before reaching its hitbox. That is
	-- correct behaviour (no shooting through the floor) but it makes for a
	-- misleading smoke test. Real spawn points sit on the floor surface.
	Diagnostics.register("spawn", function(kind: string, count: number, radius: number?, height: number?)
		local tick = TickService.getTick()
		local y = height or 3
		for i = 1, count do
			local angle = (i / count) * math.pi * 2
			local r = radius or 100
			EntityService.spawn(kind :: any, { x = math.cos(angle) * r, y = y, z = math.sin(angle) * r }, tick)
		end
		return EntityService.count()
	end)

	TickService.start()

	print(`[{Branding.gameName}] server up — tick {1 / 20}s, phases: sim/history/combat/movement/replication`)
	print(
		`[{Branding.gameName}] level seed {layout.seed} — {#layout.modules} modules `
			.. `({layout.spineCount} spine + {layout.branchCount} branches), {layout.totalArea} studs^2`
	)
	print(`[{Branding.gameName}] diagnostics: {table.concat(Diagnostics.commands(), ", ")}`)
end

main()
