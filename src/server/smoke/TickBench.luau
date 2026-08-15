--!strict
--[[
	In-engine tick budget benchmark.

		-- via the Studio MCP bridge, on the Server datamodel:
		local Bench = require(game.ServerScriptService.Server.smoke.TickBench)
		return Bench.run({ entities = 60, ticks = 600 })

	This is the one M1 number that cannot come from a terminal. The pure-core
	benchmark bounds serialization; the tick budget depends on the engine —
	Heartbeat scheduling, Instance access, and the raycasts CombatService makes.

	Budget: 12 ms of the 50 ms tick at 40 entities and 4 players
	(docs/03-NETCODE.md §What gets measured).

	Lives under src/server rather than tools/ so it syncs with the rest of the
	place and can use ordinary relative requires.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)
local Types = require(Shared.core.Types)

-- Same-subtree traversal, so these stay as relative string requires.
local TickService = require("../services/TickService")
local EntityService = require("../services/EntityService")

local TickBench = {}

export type Options = {
	entities: number?,
	ticks: number?,
	spawnRadius: number?,
}

export type Report = {
	entities: number,
	ticks: number,
	p50: number,
	p95: number,
	p99: number,
	worst: number,
	budgetMs: number,
	withinBudget: boolean,
	phaseMs: { [string]: number },
	overruns: number,
}

local KINDS: { Types.EntityKind } = { "Skitter", "Sentry", "Hauler", "Lancer", "Warden" }

--- Spawn N entities, let the live tick loop run, and report timings.
---
--- Deliberately measures the *real* loop rather than calling step() directly:
--- a synthetic harness would miss Heartbeat scheduling overhead, which is part
--- of the budget being claimed.
function TickBench.run(options: Options?): Report
	local opts = options or {}
	local entityCount = opts.entities or 60
	local tickCount = opts.ticks or 600
	local radius = opts.spawnRadius or 120

	assert(TickService.isRunning(), "TickBench: TickService is not running — is the server bootstrapped?")

	EntityService.reset()
	TickService.resetStats()

	local startTick = TickService.getTick()
	for i = 1, entityCount do
		local angle = (i / entityCount) * math.pi * 2
		EntityService.spawn(
			KINDS[(i - 1) % #KINDS + 1],
			{ x = math.cos(angle) * radius, y = 0, z = math.sin(angle) * radius },
			startTick
		)
	end

	local deadline = os.clock() + (tickCount / NetcodeConfig.TICK_RATE) + 5
	while TickService.getTick() - startTick < tickCount do
		if os.clock() > deadline then
			warn("[TickBench] timed out waiting for ticks")
			break
		end
		task.wait(0.1)
	end

	local stats = TickService.getStats()

	return {
		entities = entityCount,
		ticks = TickService.getTick() - startTick,
		p50 = stats.p50,
		p95 = stats.p95,
		p99 = stats.p99,
		worst = stats.worst,
		budgetMs = NetcodeConfig.TICK_BUDGET_MS,
		withinBudget = stats.p95 <= NetcodeConfig.TICK_BUDGET_MS,
		phaseMs = stats.phaseMs,
		overruns = stats.overruns,
	}
end

--- Sweep entity counts to find where the budget breaks. More useful than a
--- single pass/fail: it says how much headroom M2's content has.
function TickBench.sweep(counts: { number }?, ticksEach: number?): { Report }
	local list = counts or { 10, 20, 40, 60, 80 }
	local reports: { Report } = {}
	for i, count in list do
		reports[i] = TickBench.run({ entities = count, ticks = ticksEach or 200 })
	end
	return reports
end

return TickBench
