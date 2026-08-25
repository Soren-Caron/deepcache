--!strict
--[[
	Server startup.

	Order matters and is documented in docs/02-ARCHITECTURE.md §Boot order.
	Nothing here may block on network I/O — services that need the backend
	(telemetry, OVERSEER, economy config) start with compiled-in defaults and
	catch up asynchronously.

	Phase order inside the tick is the other half of the contract:
	spawn waves -> simulate -> record history -> resolve combat -> resolve
	enemy strikes -> guard movement -> advance the run -> replicate. Waves come
	first so an entity spawned this tick is stepped and recorded into history on
	the same tick. Combat must resolve against history recorded this tick, and
	enemy strikes after it so an entity killed this tick cannot swing back from
	beyond the grave. Replication must see the results of both, or a kill takes
	an extra tick to appear.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Branding = require(Shared.config.Branding)
local Rooms = require(Shared.config.Rooms)
local Types = require(Shared.core.Types)
local Run = require(Shared.core.sim.Run)
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
local EnemyCombatService = require("./services/EnemyCombatService")
local MovementGuardService = require("./services/MovementGuardService")
local DirectorService = require("./services/DirectorService")
local WaveService = require("./services/WaveService")
local QueueService = require("./services/QueueService")
local EconomyService = require("./services/EconomyService")
local MarketService = require("./services/MarketService")
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

	-- OVERSEER (M4): the FSM baseline runs regardless of backend
	-- availability, per this file's own boot-order contract above.
	DirectorService.start()
	-- M6-6: compiled-in defaults are already live; this only ever upgrades
	-- them, and runs on its own thread so a dead backend cannot delay boot.
	EconomyService.startConfigPolling()
	MarketService.init()

	-- The guard has to use the same speed the movement code does. It defaulted
	-- to a flat 16, which is merely lenient for a loaded player — but once
	-- weight makes people slower, a guard that still assumes 16 is checking a
	-- limit nobody can reach.
	MovementGuardService.setSpeedProvider(function(player: Player): number
		local weight = LootService.carriedWeight(player.UserId)
		local Loot = require(Shared.core.sim.Loot)
		local Economy = require(Shared.config.Economy)
		local Movement = require(Shared.config.Movement)
		local speed = LootService.BASE_WALK_SPEED * Loot.speedMultiplier(weight, Economy.weight.tiers :: any)
		-- A sprinting player legitimately exceeds walk speed, and a guard that
		-- does not know about it kicks them for it -- exactly the shape of the
		-- jump bug, where the budget was a walk speed and gravity was not.
		if MovementGuardService.isSprinting(player) then
			speed *= Movement.SPRINT_MULTIPLIER
		end
		return speed
	end)

	EntityService.setTargetProvider(playerTargets)

	-- M2-8's adapter half. The budget planner has existed since M2 but nothing
	-- called it, so a real session contained no enemies at all.
	WaveService.setRunProvider(function(): WaveService.RunView
		local run = RunLifecycleService.getState()
		if run == nil then
			return { active = false, elapsedSeconds = 0, headcount = 0, seed = 0 }
		end
		return {
			active = not run.complete and Run.activeCount(run) > 0,
			elapsedSeconds = run.elapsedSeconds,
			-- Live count, not startingHeadcount: budget should fall as a squad
			-- dies or extracts, or the last player alive inherits pressure
			-- scaled for a full team.
			headcount = Run.activeCount(run),
			seed = run.seed,
		}
	end)
	-- Closes the loop the other way: the director's pressure input has been a
	-- hardcoded 0 since M4 because nothing tracked spent budget.
	DirectorService.setBudgetSpentProvider(WaveService.aliveValue)

	-- A player who already died or extracted is out of the run and must stop
	-- being a valid target, or corpses and extracted players keep soaking hits.
	-- Same predicate LootService uses, for the same reason.
	EnemyCombatService.setStrikePredicate(RunLifecycleService.isActive)

	-- Before `sim`, so an entity spawned this tick is stepped and recorded into
	-- the rewind history on the same tick it appears. After replication it
	-- would exist for a tick without being in any snapshot.
	TickService.addPhase("waves", WaveService.step)
	TickService.addPhase("sim", EntityService.step)
	TickService.addPhase("history", EntityService.recordHistory)
	TickService.addPhase("combat", CombatService.step)
	-- After `combat`, so an entity killed by a player this tick does not also
	-- get to land a strike from beyond the grave.
	TickService.addPhase("enemyCombat", EnemyCombatService.step)
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
					"id=%d kind=%s state=%s hp=%.0f/%.0f pos=(%.1f,%.1f,%.1f) vel=(%.2f,%.2f,%.2f) yaw=%.4f",
					e.id, e.kind, e.state, e.hp, e.maxHp,
					e.pos.x, e.pos.y, e.pos.z, e.vel.x, e.vel.y, e.vel.z, e.yaw
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

	-- M3-8 failure drill: push a burst of synthetic events so the ring buffer
	-- can be forced past capacity deterministically, rather than waiting on
	-- incidental gameplay volume to maybe overflow it during an outage window.
	Diagnostics.register("telemetrySpam", function(count: number?)
		local n = count or 100
		for i = 1, n do
			TelemetryService.emit("diagnostic.spam", { i = i })
		end
		return `emitted {n} synthetic events`
	end)
	Diagnostics.register("telemetryFlush", function()
		local landed = TelemetryService.flushOnce(true)
		return { landed = landed, state = TelemetryService.describe() }
	end)

	Diagnostics.register("directorInfo", DirectorService.describe)

	-- M4-6 acceptance: force a tick synchronously (rather than waiting out the
	-- real 20s cadence) and wait for its async backend call to resolve, so a
	-- Studio smoke test can observe the real outcome -- FSM decision, whether
	-- a proposal landed, breaker state -- without a 20-minute wait for enough
	-- natural ticks to happen.
	Diagnostics.register("directorForceTick", function(maxWaitSeconds: number?)
		DirectorService.tick()
		local deadline = os.clock() + (maxWaitSeconds or 3)
		while DirectorService.describe().inFlight and os.clock() < deadline do
			task.wait(0.05)
		end
		return DirectorService.describe()
	end)

	-- M4-7 acceptance: force a real filter failure (userId 0 is not a real
	-- player and genuinely fails FilterStringAsync -- no mock needed) and
	-- confirm a canned line comes back, never the raw text.
	Diagnostics.register("directorForceFilterBark", function(rawBark: string?, intent: string?, userId: number?)
		return DirectorService.forceFilterBark(rawBark or "raw unfiltered text", intent or "hold_steady", userId or 0)
	end)

	Diagnostics.register("economyInfo", EconomyService.describe)
	Diagnostics.register("marketInfo", MarketService.describe)

	-- M7-5 acceptance needs screenshots taken *in* each zone, and walking
	-- there takes minutes. Repositioning has to forgive the movement guard on
	-- every frame it holds the player, for the reason MovementGuardService.
	-- forgive documents: the guard cannot tell a server teleport from a client
	-- one by looking at positions, so a legitimate reposition reads as exactly
	-- the signature it exists to catch. Same pattern as extractProbe above.
	Diagnostics.register("teleportToZone", function(zone: string?)
		local target = zone or "Vault"
		local player = Players:GetPlayers()[1]
		if player == nil then
			return { error = "no player connected" }
		end
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart == nil or not rootPart:IsA("BasePart") then
			return { error = "no character" }
		end
		local layout = LevelService.getLayout()
		if layout == nil then
			return { error = "no layout" }
		end

		-- The largest module in the band, so the camera has room and the shot
		-- is not a close-up of a wall.
		local best: any = nil
		for _, placed in layout.modules do
			if placed.zone == target and (best == nil or placed.area > best.area) then
				best = placed
			end
		end
		if best == nil then
			return { error = `no module in zone {target}` }
		end

		local destination = Vector3.new(best.at.x, 8, best.at.z)
		for _ = 1, 16 do
			rootPart.CFrame = CFrame.new(destination)
			MovementGuardService.forgive(player)
			task.wait(0.05)
		end
		return {
			zone = target,
			moduleId = best.id,
			at = { x = math.floor(destination.X), z = math.floor(destination.Z) },
			zoneAtDestination = LevelService.zoneAt(rootPart.Position),
			movement = MovementGuardService.getMetrics(),
		}
	end)

	-- M6-10 acceptance: list, bid, fill, cancel, driven against the real
	-- MarketService with a real connected player, and checked for
	-- conservation at the end. Exercises the server path the UI calls, so a
	-- pass here means the panel's buttons have something working behind them.
	Diagnostics.register("marketProbe", function(itemId: string?)
		local Escrow_ = require(Shared.core.economy.Escrow)
		local id = itemId or "optics_module"
		local player = Players:GetPlayers()[1]
		if player == nil then
			return { error = "no player connected -- join before running this" }
		end
		MarketService.reset()
		MarketService.setRunsPlayed(player, 50)
		MarketService.credit(player, 100000, { [id] = 10 })

		local escrowState = MarketService.state()
		local startCredits = Escrow_.totalCredits(escrowState)
		local startItems = Escrow_.totalItems(escrowState, id)

		local steps = {}
		-- LIST
		local listOk, listReason = MarketService.place(player, id, "sell", 200, 3)
		table.insert(steps, `list sell 3@200 -> {tostring(listOk)} {tostring(listReason)}`)
		-- BID that does not cross (below the ask)
		local bidOk, bidReason = MarketService.place(player, id, "buy", 150, 2)
		table.insert(steps, `bid 2@150 (no cross) -> {tostring(bidOk)} {tostring(bidReason)}`)
		-- Snapshot the book depth
		local _, bookState = MarketService.state()
		local asks, bids = 0, 0
		for _, o in bookState.asks do
			if o.itemId == id then asks += 1 end
		end
		for _, o in bookState.bids do
			if o.itemId == id then bids += 1 end
		end
		table.insert(steps, `book now: {bids} bid(s), {asks} ask(s)`)

		-- CANCEL the resting bid
		local myOrderId: string? = nil
		for orderId, order in escrowState.orders do
			if order.side == "buy" then myOrderId = orderId end
		end
		local cancelOk, cancelReason = MarketService.cancel(player, myOrderId or "")
		table.insert(steps, `cancel bid -> {tostring(cancelOk)} {tostring(cancelReason)}`)

		-- Rejections the client must not be able to talk its way past.
		local badItem = { MarketService.place(player, "overseer_shard", "sell", 100, 1) }
		table.insert(steps, `sell untradeable -> {tostring(badItem[1])} {tostring(badItem[2])}`)
		local badPrice = { MarketService.place(player, id, "sell", 99.5, 1) }
		table.insert(steps, `fractional price -> {tostring(badPrice[1])} {tostring(badPrice[2])}`)
		local outOfBand = { MarketService.place(player, id, "sell", 99999, 1) }
		table.insert(steps, `out of band -> {tostring(outOfBand[1])} {tostring(outOfBand[2])}`)
		local missing = { MarketService.cancel(player, "999999:1") }
		table.insert(steps, `cancel a nonexistent id -> {tostring(missing[1])} {tostring(missing[2])}`)

		-- The ownership check specifically. A nonexistent id above exits at
		-- "unknown_order" and never reaches it, so an order that really does
		-- exist under a different pid is planted to exercise the branch that
		-- stops one player cancelling another's order and pocketing the escrow.
		local Escrow2 = require(Shared.core.economy.Escrow)
		local victimEscrow = MarketService.state()
		local victim = Escrow2.account(victimEscrow, "someone-else")
		victim.runsPlayed = 50
		victim.inventory[id] = 3
		Escrow2.placeSell(victimEscrow, "someone-else:1", "someone-else", id, 200, 1, {
			maxOpenOrdersPerItem = 5, dailyTradeVolumeCap = math.huge, minRunsToSell = 5,
		})
		local stolen = { MarketService.cancel(player, "someone-else:1") }
		table.insert(steps, `cancel another player's real order -> {tostring(stolen[1])} {tostring(stolen[2])}`)
		table.insert(
			steps,
			`victim's escrow intact after the attempt: {tostring(Escrow2.escrowedCount(victimEscrow, "someone-else", id) == 1)}`
		)

		-- The victim account planted above was seeded with 3 items *after*
		-- `startItems` was captured, so the raw totals legitimately differ by
		-- exactly that. Accounting for it explicitly beats comparing against a
		-- stale baseline and reporting a conservation failure that is really a
		-- fixture artifact -- a false alarm on a conservation check is worse
		-- than no check, because it trains you to ignore it.
		local PLANTED = 3
		return {
			steps = steps,
			creditsConserved = Escrow_.totalCredits(escrowState) == startCredits,
			itemsConserved = Escrow_.totalItems(escrowState, id) == startItems + PLANTED,
			startCredits = startCredits,
			endCredits = Escrow_.totalCredits(escrowState),
			startItems = startItems,
			plantedItems = PLANTED,
			endItems = Escrow_.totalItems(escrowState, id),
			info = MarketService.describe(),
		}
	end)

	-- The fill half, which needs two distinct pids. Uses the real engine but
	-- seeds a second account directly, since a second human is not available
	-- in a Studio smoke test.
	Diagnostics.register("marketFillProbe", function(itemId: string?)
		local Escrow_ = require(Shared.core.economy.Escrow)
		local Market_ = require(Shared.core.economy.Market)
		local id = itemId or "optics_module"
		local player = Players:GetPlayers()[1]
		if player == nil then
			return { error = "no player connected" }
		end
		MarketService.reset()
		MarketService.setRunsPlayed(player, 50)
		MarketService.credit(player, 100000, { [id] = 5 })

		local escrowState, bookState = MarketService.state()
		local counterparty = "counterparty-pid"
		local other = Escrow_.account(escrowState, counterparty)
		other.credits = 100000
		other.runsPlayed = 50
		other.inventory[id] = 5

		local startCredits = Escrow_.totalCredits(escrowState)
		local startItems = Escrow_.totalItems(escrowState, id)

		-- Counterparty rests an ask; the player's bid crosses it.
		Escrow_.placeSell(escrowState, "cp:1", counterparty, id, 180, 2, {
			maxOpenOrdersPerItem = 5, dailyTradeVolumeCap = math.huge, minRunsToSell = 5,
		})
		local newBook, restFills = Market_.match(bookState, {
			id = "cp:1", pid = counterparty, itemId = id, side = "sell",
			price = 180, quantity = 2, filled = 0, ts = 1,
		})
		MarketService.setVwap(id, 180)
		local _ = restFills
		local _ = newBook

		local ok, reason = MarketService.place(player, id, "buy", 200, 2)
		local afterEscrow = select(1, MarketService.state())
		return {
			placed = ok,
			reason = reason,
			-- Total holdings, not the delta: the player was seeded with 5 and
			-- buys 2, so 7 is the correct answer and 2 would be the wrong one.
			playerTotalItems = Escrow_.inventoryCount(afterEscrow, tostring(player.UserId), id),
			counterpartyCredits = Escrow_.account(afterEscrow, counterparty).credits,
			feesCollected = afterEscrow.feesCollected,
			creditsConserved = Escrow_.totalCredits(afterEscrow) == startCredits,
			itemsConserved = Escrow_.totalItems(afterEscrow, id) == startItems,
			info = MarketService.describe(),
		}
	end)

	-- M6-3 acceptance: "each reason code produces a ledger entry with the
	-- right sign." Drives a whole run through the real service -- extract,
	-- objective bonus, daily first, repair, ammo, insurance premium and a
	-- death claim -- and reports the signed delta each reason produced, so
	-- the sign is observed rather than asserted about.
	Diagnostics.register("economyRunProbe", function(runId: string?, pid: string?)
		local run = runId or `probe-{os.time()}`
		local player = pid or "probe-pid"
		EconomyService.reset()
		local now = os.time()

		-- Seed a starting balance. Without it the very first entry (an
		-- insurance premium, a sink) would be correctly rejected for
		-- insufficient funds and the probe would report a zero-signed sink,
		-- which reads like a bug in the sign rule rather than the ledger's
		-- negative-balance guard doing its job. A real player arrives with
		-- credits from previous runs; `admin_adjust` is the sanctioned way to
		-- put them there.
		EconomyService.record(run, player, "admin_adjust", 5000, now)

		local before = EconomyService.balance(player)
		EconomyService.buyInsurance(run, player, 2000, now)
		local afterPremium = EconomyService.balance(player)
		EconomyService.onExtract(run, player, 1000, 1, true, now)
		local afterExtract = EconomyService.balance(player)
		EconomyService.onRunEnd(run, player, 600, 7, now)
		local afterSinks = EconomyService.balance(player)
		local claim = EconomyService.onDeath(run, player, 2000, now)
		local afterClaim = EconomyService.balance(player)

		return {
			insurancePremium = afterPremium - before, -- expect negative
			faucetsOnExtract = afterExtract - afterPremium, -- expect positive
			sinksOnRunEnd = afterSinks - afterExtract, -- expect negative
			insuranceClaim = afterClaim - afterSinks, -- expect positive
			claimAmount = claim,
			finalBalance = afterClaim,
			info = EconomyService.describe(),
		}
	end)

	-- M6-1 acceptance, in-engine: the same idemKey applied twice must be
	-- absorbed as a duplicate rather than double-granting.
	Diagnostics.register("economyIdempotency", function()
		EconomyService.reset()
		local now = os.time()
		local first = { EconomyService.record("dup-run", "dup-pid", "extract_payout", 500, now) }
		local balanceAfterFirst = EconomyService.balance("dup-pid")
		-- Same run/pid/reason but a fresh sequence is a *different* grant, so
		-- to test the duplicate path the ledger is driven directly.
		local Ledger_ = require(Shared.core.economy.Ledger)
		return {
			firstOk = first[1],
			firstStatus = first[2],
			balanceAfterFirst = balanceAfterFirst,
			sameKeyTwiceIsDuplicate = (function()
				local state = Ledger_.new()
				local key = Ledger_.makeKey("r", "p", "extract_payout", 1)
				local entry = { pid = "p", delta = 100, reason = "extract_payout" :: any, runId = "r", idemKey = key, ts = 0 }
				local _, ok1, s1 = Ledger_.apply(state, entry)
				local _, ok2, s2 = Ledger_.apply(state, entry)
				return `{tostring(ok1)}/{s1} then {tostring(ok2)}/{s2}, balance={Ledger_.balance(state, "p")}`
			end)(),
		}
	end)

	-- M6-6 acceptance: force a config pull and report what happened. Run it
	-- with the backend stopped to see defaults survive with no error.
	Diagnostics.register("economyPullConfig", function()
		local adopted = EconomyService.pullConfig()
		return { adopted = adopted, info = EconomyService.describe() }
	end)

	-- M5-4 acceptance: two coordinators racing to claim the same queue
	-- entry -- exactly one must win. Both "coordinators" are real,
	-- independent calls into the real MemoryStoreSortedMap; nothing here
	-- is simulated except that they run in one process instead of two.
	Diagnostics.register("queueClaimRace", function(bucket: number, pid: string, rating: number)
		QueueService.join(bucket, pid, rating, os.time(), 60)
		local resultA = QueueService.tryClaim(bucket, pid)
		local resultB = QueueService.tryClaim(bucket, pid)
		return { firstClaim = resultA, secondClaim = resultB, exactlyOneWon = (resultA ~= resultB) }
	end)

	Diagnostics.register("queueJoinLeave", function(bucket: number, pid: string, rating: number)
		local joined = QueueService.join(bucket, pid, rating, os.time(), 60)
		local listed = QueueService.listBucket(bucket, 50)
		local left = QueueService.leave(bucket, pid)
		local listedAfter = QueueService.listBucket(bucket, 50)
		return { joined = joined, listedCount = #listed, left = left, listedAfterCount = #listedAfter }
	end)

	-- M5-5 acceptance: kill the coordinator (stop renewing), confirm
	-- another instance takes over once the real 10s lease expires.
	Diagnostics.register("coordinatorTryBecome", function(instanceId: string)
		return { became = QueueService.tryBecomeCoordinator(instanceId), current = QueueService.currentCoordinator() }
	end)
	Diagnostics.register("coordinatorCurrent", function()
		return QueueService.currentCoordinator()
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

	Diagnostics.register("waveInfo", WaveService.describe)
	Diagnostics.register("enemyCombatMetrics", EnemyCombatService.getMetrics)

	-- Enemy damage acceptance: stand a player in a swarm and report what
	-- actually lands. Reads HP directly rather than trusting the metrics
	-- counter, so "damage was dealt" and "the player's health moved" are
	-- checked independently -- the whole gap this closes was a counter that
	-- would have read zero while everything else looked correct.
	Diagnostics.register("enemyDamageProbe", function(kind: string?, count: number?, seconds: number?)
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid == nil or rootPart == nil or not rootPart:IsA("BasePart") then
			return { error = "no character" }
		end

		local enemyKind = kind or "Skitter"
		local config = (require(Shared.config.Enemies) :: any)[enemyKind]
		if config == nil then
			return { error = `unknown kind {enemyKind}` }
		end

		EnemyCombatService.reset()
		humanoid.Health = humanoid.MaxHealth
		local startHp = humanoid.Health
		local startMetrics = EnemyCombatService.getMetrics()

		-- Spawn a ring just inside attack range so contact is immediate and
		-- the measurement is of damage, not of pathing.
		local origin = rootPart.Position
		local spawned: { number } = {}
		local n = count or 3
		local tick = TickService.getTick()
		for i = 1, n do
			local angle = (i / n) * math.pi * 2
			local radius = math.max(2, config.atkRange - 1)
			local entity = EntityService.spawn(enemyKind :: any, {
				x = origin.X + math.cos(angle) * radius,
				y = origin.Y,
				z = origin.Z + math.sin(angle) * radius,
			}, tick)
			table.insert(spawned, entity.id)
		end

		local rows: { string } = {}
		local duration = seconds or 5
		local elapsed = 0
		local lowestHp = startHp
		while elapsed < duration do
			task.wait(0.5)
			elapsed += 0.5
			local m = EnemyCombatService.getMetrics()
			lowestHp = math.min(lowestHp, humanoid.Health)
			table.insert(rows, string.format(
				"t=%4.1fs  hp=%6.1f  strikes=%3d  dealt=%6.1f  cooldowns=%d",
				elapsed, humanoid.Health, m.strikes, m.damageDealt, m.pendingCooldowns
			))
			if humanoid.Health <= 0 then
				break
			end
		end

		for _, id in spawned do
			EntityService.remove(id)
		end
		local finalMetrics = EnemyCombatService.getMetrics()
		humanoid.Health = humanoid.MaxHealth

		return {
			kind = enemyKind,
			spawned = n,
			expectedDamagePerHit = config.dmg,
			expectedCooldown = config.atkCooldown,
			hpBefore = startHp,
			lowestHp = lowestHp,
			-- Health observed on the Humanoid, against damage the resolver
			-- believes it dealt. These disagree by design: Roblox's default
			-- health regeneration ticks 1%/s of MaxHealth between strikes, so
			-- damageDealt legitimately exceeds the HP drop over any window
			-- longer than a second. Reporting both is what makes that visible
			-- rather than looking like an accounting bug.
			hpDropObserved = startHp - lowestHp,
			damageResolverDealt = finalMetrics.damageDealt,
			healthActuallyMoved = lowestHp < startHp,
			metrics = finalMetrics,
			timeline = rows,
		}
	end)

	-- Waves are on a 12s interval and the first is held 20s, so watching one
	-- arrive means sitting through a real minute per sample. This drives the
	-- live service through several intervals at once and reports what each
	-- decision was -- including the refusals, which is what distinguishes
	-- "withheld deliberately" from "silently broken".
	Diagnostics.register("waveProbe", function(seconds: number?, step: number?)
		local total = seconds or 90
		local chunk = step or 1
		local rows: { string } = {}
		local before = WaveService.describe()
		table.insert(rows, string.format(
			"start: alive=%d aliveValue=%.0f zone=%s",
			before.aliveCount, before.aliveValue, tostring(before.lastZone)
		))

		local elapsed = 0
		local lastWaves = before.waves
		while elapsed < total do
			-- Step the scheduler directly with a synthetic dt. The tick phase
			-- advances by real dt, and 90 real seconds is not a smoke test.
			WaveService.step(TickService.getTick(), chunk)
			elapsed += chunk
			local now = WaveService.describe()
			if now.waves > lastWaves then
				table.insert(rows, string.format(
					"t=%3ds  WAVE  target=%.0f aliveValue=%.0f -> alive=%d  zone=%s",
					elapsed, now.targetBudget, now.aliveValue, now.aliveCount, tostring(now.lastZone)
				))
				lastWaves = now.waves
			end
			task.wait()
		end

		local after = WaveService.describe()
		table.insert(rows, string.format(
			"end: waves=%d spawned=%d reclaimers=%d alive=%d/%d lastReason=%s",
			after.waves, after.spawned, after.reclaimersSummoned,
			after.aliveCount, after.maxAlive, tostring(after.lastReason)
		))
		return { rows = rows, info = after, census = after.census }
	end)

	Diagnostics.register("waveReset", function()
		WaveService.reset()
		for _, view in EntityService.views() do
			EntityService.remove(view.id)
		end
		return WaveService.describe()
	end)

	-- Line-of-sight acceptance. Must be a registered handler rather than a
	-- command-bar script: `require`-ing EntityService from the bar returns a
	-- fresh idle copy whose entities no tick phase ever steps, so they sit in
	-- `spawn` forever and never attack -- which reads exactly like a working
	-- line-of-sight check and is not one.
	Diagnostics.register("losProbe", function(kind: string?, seconds: number?)
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if rootPart == nil or humanoid == nil or not rootPart:IsA("BasePart") then
			return { error = "no character" }
		end
		local enemyKind = kind or "Sentry"
		local duration = seconds or 5

		local level = Workspace:FindFirstChild("Level")
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Whitelist
		params.FilterDescendantsInstances = if level then { level } else {}
		local origin = rootPart.Position + Vector3.new(0, 2, 0)

		--- Anchor the player for the duration. Without it the character drifts,
		--- the distance being reported is not the distance damage was resolved
		--- at, and a mobile enemy walks out from behind the wall the test is
		--- supposed to be about.
		local function measure(at: Vector3, label: string)
			humanoid.Health = humanoid.MaxHealth
			local wasAnchored = rootPart.Anchored
			rootPart.Anchored = true

			local before = EnemyCombatService.getMetrics()
			local entity = EntityService.spawn(
				enemyKind :: any,
				{ x = at.X, y = rootPart.Position.Y, z = at.Z },
				TickService.getTick()
			)

			-- Sample whether sight is genuinely obstructed rather than trusting
			-- the placement: "0 strikes" only proves the line-of-sight check if
			-- the line was actually blocked the whole time.
			local blockedSamples, samples = 0, 0
			local deadline = os.clock() + duration
			while os.clock() < deadline do
				local live = EntityService.get(entity.id)
				if live ~= nil then
					local from = Vector3.new(live.pos.x, live.pos.y, live.pos.z)
					if Workspace:Raycast(from, rootPart.Position - from, params) ~= nil then
						blockedSamples += 1
					end
					samples += 1
				end
				task.wait(0.1)
			end

			local after = EnemyCombatService.getMetrics()
			local live = EntityService.get(entity.id)
			local endDistance = if live ~= nil
				then (Vector3.new(live.pos.x, live.pos.y, live.pos.z) - rootPart.Position).Magnitude
				else -1
			EntityService.remove(entity.id)
			rootPart.Anchored = wasAnchored

			local strikes = after.strikes - before.strikes
			local damage = after.damageDealt - before.damageDealt
			return string.format(
				"%-16s endDist=%5.1f state=%-6s blocked=%3d%% strikes=%2d damage=%6.1f perHit=%s",
				label, endDistance, live and live.state or "gone",
				math.floor(100 * blockedSamples / math.max(samples, 1)),
				strikes, damage,
				if strikes > 0 then string.format("%.2f", damage / strikes) else "n/a"
			)
		end

		local rows: { string } = {}

		-- Eight directions, not four: from an open floor tile the axis-aligned
		-- rays often all miss, and "no wall within range" is a skipped test
		-- dressed up as a result.
		local DIRECTIONS = {}
		for i = 0, 7 do
			local a = (i / 8) * math.pi * 2
			table.insert(DIRECTIONS, Vector3.new(math.cos(a), 0, math.sin(a)))
		end

		-- Blocked: just past the first wall found within attack range.
		local blocked: Vector3? = nil
		for _, d in DIRECTIONS do
			local r = Workspace:Raycast(origin, d * 60, params)
			if r ~= nil and r.Distance > 6 and r.Distance < 40 then
				blocked = r.Position + d * 5
				break
			end
		end
		rows[#rows + 1] = if blocked ~= nil
			then measure(blocked, "behind a wall")
			else "behind a wall    -- no wall within range from here"

		-- Clear: a direction with nothing in the way.
		local clear: Vector3? = nil
		for _, d in DIRECTIONS do
			if Workspace:Raycast(origin, d * 26, params) == nil then
				clear = rootPart.Position + d * 24
				break
			end
		end
		rows[#rows + 1] = if clear ~= nil
			then measure(clear, "clear sightline")
			else "clear sightline  -- no clear 26-stud line from here"

		humanoid.Health = humanoid.MaxHealth
		return rows
	end)

	-- Reload acceptance: empty a magazine, reload it, and confirm firing is
	-- refused for the whole window and permitted after. Registered here rather
	-- than driven from the command bar, which gets a fresh idle CombatService.
	Diagnostics.register("reloadProbe", function(weaponId: string?)
		local player = Players:GetPlayers()[1]
		if player == nil then
			return { error = "no player connected" }
		end
		local id = weaponId or "Sidearm"
		local weapon = (require(Shared.config.Weapons) :: any)[id]
		if weapon == nil or weapon.magazine == nil then
			return { error = `{id} has no magazine` }
		end

		local rows: { string } = {}
		local function fireOnce(): string
			local before = CombatService.getMetrics()
			CombatService.submit(player, {
				seq = 0,
				clientTime = TickService.now(),
				origin = Vector3.new(0, 5, 0),
				direction = Vector3.new(0, 0, 1),
				weaponId = id,
			})
			task.wait(0.12)
			local after = CombatService.getMetrics()
			if after.rejectedReloading > before.rejectedReloading then
				return "rejected:reloading"
			elseif after.rejectedAmmo > before.rejectedAmmo then
				return "rejected:ammo"
			elseif after.rejectedRate > before.rejectedRate then
				return "rejected:rate"
			end
			return "accepted"
		end

		CombatService.reload(player, id)
		task.wait(0.15)

		-- Drain the magazine. Rate limiting means this needs spacing.
		local interval = 1 / (weapon.rps or 4) + 0.03
		for _ = 1, weapon.magazine do
			CombatService.submit(player, {
				seq = 0,
				clientTime = TickService.now(),
				origin = Vector3.new(0, 5, 0),
				direction = Vector3.new(0, 0, 1),
				weaponId = id,
			})
			task.wait(interval)
		end
		rows[#rows + 1] = `after draining {weapon.magazine} rounds, firing -> {fireOnce()}`

		local started, reason = CombatService.requestReload(player, id)
		rows[#rows + 1] = `requestReload -> {tostring(started)} {tostring(reason)}`

		-- Mid-reload: must be refused.
		task.wait(weapon.reloadSeconds * 0.4)
		rows[#rows + 1] = `firing mid-reload ({string.format("%.1f", weapon.reloadSeconds * 0.4)}s in) -> {fireOnce()}`

		-- A second request while one is in flight must not restart the timer.
		local again, againReason = CombatService.requestReload(player, id)
		rows[#rows + 1] = `requestReload again mid-reload -> {tostring(again)} {tostring(againReason)}`

		-- Wait out the remainder.
		task.wait(weapon.reloadSeconds)
		rows[#rows + 1] = `firing after the reload window -> {fireOnce()}`

		-- Reloading a full magazine is a no-op, not a lockout.
		CombatService.reload(player, id)
		task.wait(0.1)
		local fullOk, fullReason = CombatService.requestReload(player, id)
		rows[#rows + 1] = `requestReload on a full magazine -> {tostring(fullOk)} {tostring(fullReason)}`

		return { weapon = id, reloadSeconds = weapon.reloadSeconds, steps = rows, metrics = CombatService.getMetrics() }
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

	print(
		`[{Branding.gameName}] server up — tick {1 / 20}s, `
			.. `phases: waves/sim/history/combat/enemyCombat/movement/run/replication`
	)
	print(
		`[{Branding.gameName}] level seed {layout.seed} — {#layout.modules} modules `
			.. `({layout.spineCount} spine + {layout.branchCount} branches), {layout.totalArea} studs^2`
	)
	print(`[{Branding.gameName}] diagnostics: {table.concat(Diagnostics.commands(), ", ")}`)
end

main()
