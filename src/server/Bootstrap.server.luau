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
local Types = require(Shared.core.Types)
local Remotes = require(Shared.net.Remotes)

local TickService = require("./services/TickService")
local EntityService = require("./services/EntityService")
local ReplicationService = require("./services/ReplicationService")
local CombatService = require("./services/CombatService")
local MovementGuardService = require("./services/MovementGuardService")
local Diagnostics = require("./services/Diagnostics")
local TickBench = require("./smoke/TickBench")

local function playerTargets(): { { id: number, pos: Types.Vec3 } }
	local out: { { id: number, pos: Types.Vec3 } } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid == nil or humanoid.Health > 0 then
				table.insert(out, {
					id = player.UserId,
					pos = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z },
				})
			end
		end
	end
	return out
end

local function main()
	Remotes.init()

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
	print(`[{Branding.gameName}] diagnostics: {table.concat(Diagnostics.commands(), ", ")}`)
end

main()
