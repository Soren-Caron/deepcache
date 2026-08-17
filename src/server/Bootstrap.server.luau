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
local Wire = require(Shared.net.Wire)

local TickService = require("./services/TickService")
local TelemetryService = require("./services/TelemetryService")
local LevelService = require("./services/LevelService")
local LootService = require("./services/LootService")
local RunLifecycleService = require("./services/RunLifecycleService")
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

	-- Telemetry starts before anything that emits, so no event is lost to a
	-- buffer that did not exist yet.
	TelemetryService.start()

	-- The level exists before anything that spawns into it. M2-7 takes over
	-- seed selection when the run lifecycle lands; until then every boot builds
	-- the same level, which is what makes a Studio session repeatable.
	local layout = LevelService.build(Rooms.defaultSeed)

	ReplicationService.init()
	CombatService.init()
	MovementGuardService.init()
	LootService.init()
	RunLifecycleService.init()

	-- Loot asks the run whether a player may still carry, so a dead or
	-- extracted player cannot keep looting.
	LootService.setCarryPredicate(RunLifecycleService.isActive)

	-- The guard has to use the same speed the movement code does. It defaulted
	-- to a flat 16, which is merely lenient for a loaded player — but once
	-- weight makes people slower, a guard that still assumes 16 is checking a
	-- limit nobody can reach.
	MovementGuardService.setSpeedProvider(function(player: Player): number
		local weight = LootService.carriedWeight(player.UserId)
		local Loot = require(Shared.core.sim.Loot)
		local Economy = require(Shared.config.Economy)
		return LootService.BASE_WALK_SPEED * Loot.speedMultiplier(weight, Economy.weight.tiers :: any)
	end)

	EntityService.setTargetProvider(playerTargets)

	TickService.addPhase("sim", EntityService.step)
	TickService.addPhase("history", EntityService.recordHistory)
	TickService.addPhase("combat", CombatService.step)
	TickService.addPhase("movement", MovementGuardService.step)
	-- After combat and movement: extraction and death must see this tick's
	-- outcomes, or a player killed on the tick they reach a pad extracts anyway.
	TickService.addPhase("run", RunLifecycleService.step)
	TickService.addPhase("replication", ReplicationService.step)

	RunLifecycleService.start(Rooms.defaultSeed)

	-- perf.tick is one of the two events docs/04 calls first-class, because it
	-- is what makes the netcode claims checkable against real sessions rather
	-- than against a bench. Sampled every 30s: a per-tick event would be 20
	-- times a second of telemetry describing telemetry.
	task.spawn(function()
		while true do
			task.wait(30)
			local stats = TickService.getStats()
			TelemetryService.emit("perf.tick", {
				p50 = stats.p50,
				p95 = stats.p95,
				p99 = stats.p99,
				overruns = stats.overruns,
				ticks = stats.ticks,
				entityCount = EntityService.count(),
			})
			TickService.resetStats()
		end
	end)

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

	-- M2-7 acceptance: stand on an open pad and extract. Holds the player there
	-- across several ticks because the client owns the character and reverts a
	-- single server-side move, and forgives the guard each time — otherwise the
	-- reposition is scored as the exact teleport signature it exists to catch.
	Diagnostics.register("extractProbe", function(zone: string?)
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart == nil then
			return { error = "no character" }
		end
		local level = Workspace:FindFirstChild("Level")
		local pads = level and level:FindFirstChild("Pads")
		if pads == nil then
			return { error = "no pads" }
		end

		local target: BasePart? = nil
		for _, pad in pads:GetChildren() do
			if pad:IsA("BasePart") and (zone == nil or pad:GetAttribute("zone") == zone) then
				target = pad
				break
			end
		end
		if target == nil then
			return { error = `no pad for zone {tostring(zone)}` }
		end

		local pad = target :: BasePart
		local carriedBefore = LootService.carriedValue(player.UserId)
		local weightBefore = LootService.carriedWeight(player.UserId)

		for _ = 1, 24 do
			rootPart.CFrame = CFrame.new(pad.Position + Vector3.new(0, 4, 0))
			MovementGuardService.forgive(player)
			task.wait(0.05)
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		return {
			pad = pad:GetAttribute("zone"),
			carriedBefore = string.format("%.0f kg, %d credits", weightBefore, carriedBefore),
			carriedAfter = string.format(
				"%.0f kg, %d credits",
				LootService.carriedWeight(player.UserId),
				LootService.carriedValue(player.UserId)
			),
			walkSpeed = humanoid and humanoid.WalkSpeed or -1,
			run = RunLifecycleService.describe(),
		}
	end)
	Diagnostics.register("lootInfo", LootService.describe)

	-- M2-6 acceptance, end to end on the running instance: stand the player on
	-- the nearest item, take it, and report the reach rule refusing a grab from
	-- across the level.
	Diagnostics.register("pickupProbe", function(count: number?)
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart == nil then
			return { error = "no character" }
		end
		local folder = workspace:FindFirstChild("GroundLoot")
		if folder == nil then
			return { error = "no ground loot" }
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rows: { string } = { string.format("WalkSpeed at rest: %.2f", humanoid.WalkSpeed) }

		local parts: { BasePart } = {}
		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") then
				table.insert(parts, part)
			end
		end
		-- Nearest first, not heaviest first. The character is network-owned by
		-- the client, so a long server-side teleport is reverted before the
		-- reach check runs and every distant item reads as `tooFar` — an
		-- artifact of the harness, not of the rule.
		table.sort(parts, function(a, b)
			return (a.Position - rootPart.Position).Magnitude < (b.Position - rootPart.Position).Magnitude
		end)

		for index = 1, math.min(count or 4, #parts) do
			local part = parts[index]
			rootPart.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
			-- A server-side reposition is indistinguishable from a teleport
			-- hack by position alone, so tell the guard this one was ours.
			MovementGuardService.forgive(player)
			task.wait(0.25)
			local ok, reason = LootService.tryPickup(player, part:GetAttribute("uid"))
			task.wait(0.2)
			rows[#rows + 1] = string.format(
				"take %-16s %2dkg -> %-5s %-10s carried=%3.0fkg WalkSpeed=%.2f",
				part.Name, part:GetAttribute("weight") :: number, tostring(ok), reason or "",
				LootService.carriedWeight(player.UserId), humanoid.WalkSpeed
			)
		end

		-- Reach: the ProximityPrompt is client-side convenience, not security.
		for _, part in parts do
			if part.Parent ~= nil and (part.Position - rootPart.Position).Magnitude > 150 then
				local ok, reason = LootService.tryPickup(player, part:GetAttribute("uid"))
				rows[#rows + 1] = string.format(
					"grab from %.0f studs away -> %s %s",
					(part.Position - rootPart.Position).Magnitude, tostring(ok), reason or ""
				)
				break
			end
		end

		return rows
	end)
	Diagnostics.register("runInfo", RunLifecycleService.describe)
	Diagnostics.register("telemetryInfo", TelemetryService.describe)
	Diagnostics.register("telemetryFlush", function()
		local landed = TelemetryService.flushOnce(true)
		return { landed = landed, state = TelemetryService.describe() }
	end)

	-- M2-7 acceptance: drive a whole run without waiting twelve real minutes.
	-- Fast-forwards the clock a chunk at a time and reports what fired.
	Diagnostics.register("runProbe", function(stepSeconds: number?, steps: number?)
		local Run = require(Shared.core.sim.Run)
		local run = RunLifecycleService.getState()
		if run == nil then
			return { error = "no run in progress" }
		end

		local rows: { string } = {}
		local chunk = stepSeconds or 60
		for _ = 1, steps or 13 do
			local before = run.elapsedSeconds
			-- Step the core state directly: the tick phase advances by real dt,
			-- and a twelve-minute run is not a smoke test anyone will run.
			for _, event in Run.step(run, chunk, { Perimeter = 180, Processing = 360, Vault = 540 }) do
				table.insert(rows, string.format("t=%4ds  %s %s", math.floor(run.elapsedSeconds),
					event.kind, (event :: any).zone or (event :: any).reason or ""))
			end
			if run.complete then
				break
			end
			if run.elapsedSeconds == before then
				break
			end
		end

		local summary = Run.summary(run)
		table.insert(rows, string.format(
			"end: complete=%s reason=%s extracted=%d died=%d active=%d banked=%d",
			tostring(summary.complete), tostring(summary.endReason),
			summary.extracted, summary.died, summary.active, summary.bankedValue
		))
		return rows
	end)
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

	-- M2-5 acceptance: all four weapons fire and deal damage, each through its
	-- own netcode path. Spawns a fresh target per weapon at a fixed distance so
	-- the numbers are comparable, and reports what actually landed.
	Diagnostics.register("weaponProbe", function(distance: number?)
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart == nil then
			return { error = "no character" }
		end

		local range = distance or 40
		local rows: { string } = {}

		for _, weaponId in { "Sidearm", "Carbine", "Slug", "Arc" } do
			local weapon = (require(Shared.config.Weapons) :: any)[weaponId]
			local origin = rootPart.Position + Vector3.new(0, 2, 0)

			-- Place the target where it can actually be shot. The level is a
			-- real building: a target at a fixed 40 studs lands behind the
			-- room's wall, every hitscan shot correctly stops on the wall, and
			-- the probe reads as "the weapon is broken" when the weapon is
			-- fine. Measure the clear distance first.
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { character }
			local blocked = workspace:Raycast(origin, Vector3.new(0, 0, range + 10), params)
			local clear = if blocked then math.max(8, blocked.Distance - 6) else range
			local target = origin + Vector3.new(0, 0, math.min(range, clear))

			-- A Hauler: big enough to hit reliably, tough enough to survive a
			-- burst so the damage total is readable rather than clipped.
			local entity = EntityService.spawn("Hauler", Wire.toVec3(target), TickService.getTick())
			local before = entity.hp
			CombatService.reload(player, weaponId)

			-- Let the entity age into the rewind buffer and out of `spawn`
			-- state. Hitscan resolves against history, so an entity fired at on
			-- the tick it spawned is genuinely not there yet to be hit — the
			-- projectile and beam paths read the present and would hit it.
			task.wait(0.4)

			-- Enough requests to show a burst, a projectile flight, or a ramp.
			local shots = if weapon.kind == "beam" then 40 else 3
			for _ = 1, shots do
				CombatService.submit(player, {
					seq = 0,
					clientTime = TickService.now(),
					origin = origin,
					direction = Vector3.new(0, 0, 1),
					weaponId = weaponId,
				})
				task.wait(if weapon.kind == "beam" then 0.05 else 0.35)
			end
			-- Let a projectile finish its flight.
			task.wait(0.6)

			local live = EntityService.get(entity.id)
			local after = if live then live.hp else 0
			rows[#rows + 1] = string.format(
				"%-8s %-10s %2d req at %4.1f studs -> %6.1f damage (hp %5.0f -> %5.0f)%s",
				weaponId, weapon.kind, shots, (target - origin).Magnitude, before - after, before, after,
				if live == nil then "  TARGET DIED" else ""
			)
			if live then
				EntityService.remove(entity.id)
			end
		end

		rows[#rows + 1] = string.format("projectiles still in flight: %d", CombatService.projectileCount())
		return rows
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

	print(`[{Branding.gameName}] server up — tick {1 / 20}s, phases: sim/history/combat/movement/run/replication`)
	print(
		`[{Branding.gameName}] level seed {layout.seed} — {#layout.modules} modules `
			.. `({layout.spineCount} spine + {layout.branchCount} branches), {layout.totalArea} studs^2`
	)
	print(`[{Branding.gameName}] diagnostics: {table.concat(Diagnostics.commands(), ", ")}`)
end

main()
