--!strict
--[[ M2-7. The run: twelve minutes, three pads, individual extraction.

	All the rules live in `core/sim/Run`, which is testable without a play
	session. This drives it from the tick loop and owns the Roblox-facing half:
	which players are in, standing on a pad, or dead, and telling clients.

	Named `RunLifecycleService` rather than the backlog's `RunService_` — the
	trailing underscore existed only to dodge the clash with Roblox's own
	`RunService`, and a descriptive name does that better.

	Extraction is checked server-side against pad positions every tick. A
	`Touched` event would be simpler and would also let a client fling itself
	at a pad from across the map.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local AbTest = require(Shared.core.director.AbTest)
local Run = require(Shared.core.sim.Run)
local Types = require(Shared.core.Types)
local Branding = require(Shared.config.Branding)
local CombatConfig = require(Shared.config.Combat)
local ZonesConfig = require(Shared.config.Zones)
local Remotes = require(Shared.net.Remotes)

local LevelService = require("./LevelService")
local LootService = require("./LootService")
local TelemetryService = require("./TelemetryService")

local RunLifecycleService = {}

--- How close to a pad's centre counts as standing on it.
local PAD_RADIUS = 12

--- Client state pushes per second. The HUD needs the clock, not every tick.
local PUSH_INTERVAL = 1.0

--- How long after a run ends before a redeploy is honoured. Long enough that
--- the summary is readable, short enough that nobody is waiting on it.
local REDEPLOY_DEBOUNCE = 2.0

local state: Run.RunState? = nil
local schedule: Run.PadSchedule = {}
local sincePush = 0
--- Seconds since the run completed, for the redeploy debounce. Counted rather
--- than read off a clock so the rule stays testable in `core/sim/Run`.
local sinceComplete = 0
--- Set by Bootstrap: how to actually start a fresh run. Injected because
--- restarting touches waves, entities and enemy cooldowns, and this service
--- owns none of those -- reaching into them from here would make the run
--- lifecycle depend on half the server.
local restarter: ((seed: number?) -> ())? = nil
local diedConnections: { [number]: RBXScriptConnection } = {}
--- M4-10: which A/B arm this run is on. nil before a run has started.
local arm: AbTest.Arm? = nil

local function fireAll(payload: { [string]: any })
	Remotes.event("RunEvent"):FireAllClients(payload)
end

local function padPositions(): { { zone: string, at: Types.Vec3 } }
	local layout = LevelService.getLayout()
	if layout == nil then
		return {}
	end
	local out: { { zone: string, at: Types.Vec3 } } = {}
	for _, pad in layout.pads do
		table.insert(out, { zone = pad.zone, at = pad.at })
	end
	return out
end

local function playerPosition(player: Player): Types.Vec3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return nil
	end
	return { x = rootPart.Position.X, y = rootPart.Position.Y, z = rootPart.Position.Z }
end

--- Death is the loss condition, so it has to be watched rather than polled:
--- a player who dies and respawns between two ticks must still drop their
--- loot.
local function watchDeath(player: Player)
	local function bind(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid == nil or not humanoid:IsA("Humanoid") then
			return
		end

		-- The health pool, which Roblox otherwise leaves at its default 100.
		-- Raising MaxHealth alone would leave the player spawning on a partly
		-- empty bar, since Health does not follow it.
		humanoid.MaxHealth = CombatConfig.PLAYER_MAX_HEALTH
		humanoid.Health = humanoid.MaxHealth
		local existing = diedConnections[player.UserId]
		if existing then
			existing:Disconnect()
		end
		diedConnections[player.UserId] = humanoid.Died:Connect(function()
			RunLifecycleService.onDeath(player)
		end)
	end

	if player.Character then
		bind(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		bind(character)
		-- A new Humanoid arrives at default speed; reapply the carry penalty.
		task.defer(function()
			LootService.refresh(player)
		end)
	end)
end

--------------------------------------------------------------------------------

function RunLifecycleService.start(seed: number)
	local ids: { number } = {}
	for _, player in Players:GetPlayers() do
		table.insert(ids, player.UserId)
	end

	state = Run.new(seed, Branding.runLengthSeconds, ids)
	schedule = {}
	for zone, config in ZonesConfig do
		schedule[zone] = config.padOpensAt
	end
	sincePush = 0
	sinceComplete = 0

	LootService.populate(seed)

	-- A run id that is unique per run and reproducible in a report: the seed
	-- alone would collide across servers, and a GUID alone would not tell you
	-- which level to rebuild.
	local runId = `{seed}-{HttpService:GenerateGUID(false)}`
	TelemetryService.setRun(runId)

	-- M4-10: decided once, from runId alone, so it's reproducible from a
	-- logged run without having recorded the arm separately.
	arm = AbTest.assignArm(runId)

	TelemetryService.emit("run.start", {
		seed = seed,
		squadSize = #ids,
		lengthSeconds = Branding.runLengthSeconds,
		arm = arm,
		layout = if LevelService.getLayout() then {
			modules = #(LevelService.getLayout() :: any).modules,
			totalArea = (LevelService.getLayout() :: any).totalArea,
		} else nil,
	})

	fireAll({ kind = "runStarted", seed = seed, lengthSeconds = Branding.runLengthSeconds })
end

function RunLifecycleService.getState(): Run.RunState?
	return state
end

--- How a fresh run gets started. Bootstrap owns the wiring because a restart
--- has to clear entities and reset the wave scheduler too.
function RunLifecycleService.setRestarter(fn: (seed: number?) -> ())
	restarter = fn
end

--- A player asking to drop back in once the run is over.
---
--- Server-authoritative like everything else the client asks for: the rule
--- lives in `Run.canRedeploy`, and a client asking mid-run or twice in a frame
--- is refused. Returns `(false, reason)` rather than throwing, per CLAUDE.md.
function RunLifecycleService.requestRedeploy(player: Player): (boolean, string?)
	local current = state
	if current == nil then
		return false, "no_run"
	end
	if restarter == nil then
		return false, "no_restarter"
	end
	-- Only players who were in the run may restart it. Not a security boundary
	-- so much as a correctness one: a spectator who joined after the end has no
	-- standing to wipe everyone else's summary off the screen.
	if current.players[player.UserId] == nil then
		return false, "not_in_run"
	end

	local ok, reason = Run.canRedeploy(current, sinceComplete, REDEPLOY_DEBOUNCE)
	if not ok then
		return false, reason
	end

	TelemetryService.emit("run.redeploy", {
		afterSeconds = current.elapsedSeconds,
		endReason = current.endReason,
	}, player.UserId)

	;(restarter :: any)(nil)
	return true
end

--- M4-10: nil before any run has started. Arm A (control) is FSM-only --
--- DirectorService reads this to decide whether to call the backend at all.
function RunLifecycleService.getArm(): AbTest.Arm?
	return arm
end

--- Whether a player may still pick things up. LootService asks this so a dead
--- or extracted player cannot keep looting.
function RunLifecycleService.isActive(playerId: number): boolean
	local current = state
	if current == nil then
		return true -- no run in progress: the M1 smoke harness still works
	end
	local player = current.players[playerId]
	return player ~= nil and player.status == "active"
end

function RunLifecycleService.onDeath(player: Player)
	local current = state
	if current == nil then
		return
	end
	local position = playerPosition(player) or { x = 0, y = 0, z = 0 }
	-- Scatter first: kill() zeroes the carry, and the loot has to land
	-- somewhere teammates can reach it.
	local droppedValue = LootService.scatter(player.UserId, position)
	local died = Run.kill(current, player.UserId)
	if died then
		TelemetryService.emit("player.death", {
			tSeconds = current.elapsedSeconds,
			droppedValue = droppedValue,
			position = { x = math.floor(position.x), z = math.floor(position.z) },
		}, player.UserId)
		fireAll({ kind = "playerDied", playerId = player.UserId, droppedValue = droppedValue })
	end
end

local function tryExtractions()
	local current = state
	if current == nil then
		return
	end
	local pads = padPositions()
	if #pads == 0 then
		return
	end

	for _, player in Players:GetPlayers() do
		local runPlayer = current.players[player.UserId]
		if runPlayer == nil or runPlayer.status ~= "active" then
			continue
		end
		local position = playerPosition(player)
		if position == nil then
			continue
		end

		for _, pad in pads do
			if not Run.isPadOpen(current, pad.zone) then
				continue
			end
			if Types.distance(position, pad.at) > PAD_RADIUS then
				continue
			end

			Run.setCarried(
				current,
				player.UserId,
				LootService.carriedWeight(player.UserId),
				LootService.carriedValue(player.UserId)
			)
			local ok = Run.tryExtract(current, player.UserId, pad.zone)
			if ok then
				local banked = current.players[player.UserId].bankedValue
				-- Hand the items over too, or the extracted player keeps the
				-- movement penalty and could bank the same loot at a second pad.
				LootService.bank(player.UserId)
				TelemetryService.emit("extract.success", {
					zone = pad.zone,
					tSeconds = current.elapsedSeconds,
					carriedValue = banked,
				}, player.UserId)
				fireAll({
					kind = "playerExtracted",
					playerId = player.UserId,
					zone = pad.zone,
					value = banked,
				})
			end
			break
		end
	end
end

--- Registered as a TickService phase.
function RunLifecycleService.step(tick: number, dt: number)
	local current = state
	if current == nil then
		return
	end

	LootService.setTick(tick)

	if current.complete then
		sinceComplete += dt
	end

	-- Reconcile the roster rather than relying on PlayerAdded having fired
	-- after the run existed. At boot the server starts the run before the
	-- local player has joined, and a PlayerAdded that lands while `state` is
	-- still nil would drop that player from the run permanently — they would
	-- be in the level, unable to extract, and invisible to the enemy budget.
	-- Reconciling is a handful of table lookups and cannot race.
	for _, player in Players:GetPlayers() do
		if current.players[player.UserId] == nil then
			Run.addPlayer(current, player.UserId)
		end
	end

	-- Carried weight is authoritative on the run state, so the payout and the
	-- movement penalty cannot disagree.
	for _, player in Players:GetPlayers() do
		Run.setCarried(
			current,
			player.UserId,
			LootService.carriedWeight(player.UserId),
			LootService.carriedValue(player.UserId)
		)
	end

	for _, event in Run.step(current, dt, schedule) do
		if event.kind == "padOpened" then
			fireAll({ kind = "padOpened", zone = event.zone })
		elseif event.kind == "died" then
			-- Clock expiry, not a Humanoid death: scatter here too.
			local player = Players:GetPlayerByUserId(event.playerId)
			if player then
				LootService.scatter(event.playerId, playerPosition(player) or { x = 0, y = 0, z = 0 })
			end
			fireAll({ kind = "playerDied", playerId = event.playerId, droppedValue = event.droppedValue })
		elseif event.kind == "runEnded" then
			local summary = Run.summary(current)
			TelemetryService.emit("run.end", {
				outcome = event.reason,
				durationSeconds = current.elapsedSeconds,
				extracted = summary.extracted,
				deaths = summary.died,
				valueExtracted = summary.bankedValue,
				squadSize = current.startingHeadcount,
			})
			-- The run is over; get its events out before anything else can
			-- interrupt, rather than waiting for the next 1s flush tick.
			task.spawn(TelemetryService.flushOnce, true)
			fireAll({ kind = "runEnded", reason = event.reason, summary = summary })
		end
	end

	tryExtractions()

	sincePush += dt
	if sincePush >= PUSH_INTERVAL then
		sincePush = 0
		for _, player in Players:GetPlayers() do
			local runPlayer = current.players[player.UserId]
			-- M7-5: the client drives its lighting transitions off this. The
			-- server sends the zone *name* rather than the client deriving it,
			-- because only the server has the layout -- and shipping the whole
			-- module list to every client just so it can do a point-in-rect
			-- test would be a lot of bandwidth for one string.
			local zone: string? = nil
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				zone = LevelService.zoneAt(root.Position)
			end
			Remotes.event("RunState"):FireClient(player, {
				remaining = Run.secondsRemaining(current),
				elapsed = current.elapsedSeconds,
				openPads = Run.openZones(current),
				status = runPlayer and runPlayer.status or "spectating",
				active = Run.activeCount(current),
				startingHeadcount = current.startingHeadcount,
				complete = current.complete,
				zone = zone,
				-- Whether the redeploy control should be offered. Decided here
				-- rather than by the client re-deriving it from `complete`: the
				-- debounce lives on the server, and a button that appears a
				-- moment before the server will honour it reads as broken.
				canRedeploy = (Run.canRedeploy(current, sinceComplete, REDEPLOY_DEBOUNCE)),
				endReason = current.endReason,
			})
		end
	end
end

function RunLifecycleService.init()
	Remotes.event("RedeployRequest").OnServerEvent:Connect(function(player: Player)
		-- The return value is deliberately dropped. A refusal needs no reply:
		-- the client only offers the button when the last RunState said it was
		-- allowed, so any refusal is either a race with that 1 Hz push or a
		-- client that should not have asked. Either way the next push carries
		-- the truth a beat later.
		RunLifecycleService.requestRedeploy(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		watchDeath(player)
		local current = state
		if current then
			Run.addPlayer(current, player.UserId)
		end
	end)
	for _, player in Players:GetPlayers() do
		watchDeath(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local connection = diedConnections[player.UserId]
		if connection then
			connection:Disconnect()
			diedConnections[player.UserId] = nil
		end
		-- Leaving mid-run is not extracting: whatever they carried is lost, not
		-- banked. Dropping it on the floor would let a squad launder loot by
		-- having one player disconnect on top of a teammate.
		local current = state
		if current then
			Run.kill(current, player.UserId)
		end
	end)
end

function RunLifecycleService.describe(): { [string]: any }
	local current = state
	if current == nil then
		return { running = false }
	end
	local summary = Run.summary(current)
	summary.running = true
	summary.padSchedule = schedule
	return summary
end

return RunLifecycleService
