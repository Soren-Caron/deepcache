--!strict
--[[ Field repair, server side.

	The adapter half of `core/sim/Repair`. Core owns charges, the channel and
	the interrupt rule; this owns the Humanoid and the clock.

	**Health is applied here and only here.** The client asks to start and
	watches a bar; it never tells the server how much it healed, for the same
	reason it never reports its own HP. A client trusted to say "I repaired 45"
	would say 100.

	The interrupt is driven from `HealthChanged` rather than polled, because
	the window that matters is small: a hit landing 40 ms before the channel
	completes has to cancel it, and a 20 Hz poll would let a fifth of those
	through as free heals.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local RepairConfig = require(Shared.config.Repair)
local Repair = require(Shared.core.sim.Repair)
local Remotes = require(Shared.net.Remotes)

local TelemetryService = require("./TelemetryService")

local RepairService = {}

local PARAMS: Repair.Params = {
	charges = RepairConfig.charges,
	healAmount = RepairConfig.healAmount,
	channelSeconds = RepairConfig.channelSeconds,
}

type Entry = {
	state: Repair.State,
	connection: RBXScriptConnection?,
	lastHealth: number,
}

local tracked: { [Player]: Entry } = {}

local metrics = {
	started = 0,
	completed = 0,
	interrupted = 0,
	healed = 0,
	refused = 0,
}

--- Whether this player may act. Injected, so death and extraction rules stay
--- owned by RunLifecycleService.
local canAct: ((userId: number) -> boolean)? = nil

function RepairService.setActionPredicate(predicate: (userId: number) -> boolean)
	canAct = predicate
end

local function entryFor(player: Player): Entry
	local existing = tracked[player]
	if existing then
		return existing
	end
	local created: Entry = { state = Repair.new(PARAMS), connection = nil, lastHealth = 0 }
	tracked[player] = created
	return created
end

local function push(player: Player)
	local entry = tracked[player]
	if entry == nil then
		return
	end
	Remotes.event("RepairState"):FireClient(player, {
		charges = entry.state.chargesLeft,
		repairing = Repair.isChannelling(entry.state),
		channelSeconds = RepairConfig.channelSeconds,
	})
end

local function stopWatching(entry: Entry)
	if entry.connection then
		entry.connection:Disconnect()
		entry.connection = nil
	end
end

--- Cancel an in-flight channel and tell the client why.
local function interrupt(player: Player, reason: string)
	local entry = tracked[player]
	if entry == nil then
		return
	end
	if Repair.cancel(entry.state) then
		metrics.interrupted += 1
		stopWatching(entry)
		TelemetryService.emit("repair.interrupted", { reason = reason }, player.UserId)
		push(player)
	end
end

--- Begin a repair. Returns `(false, reason)` on refusal, per CLAUDE.md.
function RepairService.begin(player: Player): (boolean, string?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		metrics.refused += 1
		return false, "no_character"
	end
	if canAct ~= nil and not canAct(player.UserId) then
		metrics.refused += 1
		return false, "not_active"
	end

	local entry = entryFor(player)
	local ok, reason = Repair.begin(entry.state, os.clock(), humanoid.Health, humanoid.MaxHealth, PARAMS)
	if not ok then
		metrics.refused += 1
		push(player)
		return false, reason
	end

	metrics.started += 1
	entry.lastHealth = humanoid.Health

	-- Any drop in health cancels it. Watched rather than polled: a hit landing
	-- 40ms before completion must interrupt, and a 20Hz poll would let a fifth
	-- of those through as free heals.
	stopWatching(entry)
	entry.connection = humanoid.HealthChanged:Connect(function(health: number)
		local current = tracked[player]
		if current == nil then
			return
		end
		if health < current.lastHealth - 0.01 then
			interrupt(player, "damaged")
		end
		current.lastHealth = health
	end)

	push(player)
	return true
end

--- Registered as a TickService phase. Completes channels that have run out.
function RepairService.step(_tick: number, _dt: number)
	local now = os.clock()
	for player, entry in tracked do
		if not Repair.isChannelling(entry.state) then
			continue
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			interrupt(player, "died")
			continue
		end

		local done, heal = Repair.collect(entry.state, now, PARAMS)
		if not done then
			continue
		end

		stopWatching(entry)
		-- Clamped so a repair cannot overheal, and applied before `lastHealth`
		-- is refreshed so the watcher does not read our own heal as damage.
		local before = humanoid.Health
		humanoid.Health = math.min(humanoid.MaxHealth, before + heal)
		entry.lastHealth = humanoid.Health

		metrics.completed += 1
		metrics.healed += humanoid.Health - before
		TelemetryService.emit("repair.complete", {
			healed = math.floor(humanoid.Health - before),
			chargesLeft = entry.state.chargesLeft,
		}, player.UserId)
		push(player)
	end
end

function RepairService.init()
	Remotes.event("RepairRequest").OnServerEvent:Connect(function(player: Player, action: unknown)
		if action == "cancel" then
			interrupt(player, "cancelled")
		else
			RepairService.begin(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local entry = tracked[player]
		if entry then
			stopWatching(entry)
		end
		tracked[player] = nil
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- A new character is a new Humanoid; the old HealthChanged
			-- connection points at a corpse. Charges survive the respawn --
			-- they belong to the run, not the body.
			local entry = tracked[player]
			if entry then
				stopWatching(entry)
				Repair.cancel(entry.state)
			end
			task.defer(push, player)
		end)
	end)
end

--- Fresh charges for everyone. Called when a run starts, since charges are a
--- per-run resource.
function RepairService.resetAll()
	for player, entry in tracked do
		stopWatching(entry)
		Repair.reset(entry.state, PARAMS)
		push(player)
	end
end

function RepairService.getMetrics(): { [string]: any }
	local live = 0
	for _, entry in tracked do
		if Repair.isChannelling(entry.state) then
			live += 1
		end
	end
	return {
		started = metrics.started,
		completed = metrics.completed,
		interrupted = metrics.interrupted,
		healed = metrics.healed,
		refused = metrics.refused,
		channellingNow = live,
		charges = RepairConfig.charges,
		healAmount = RepairConfig.healAmount,
		channelSeconds = RepairConfig.channelSeconds,
	}
end

return RepairService
