--!strict
--[[
	The fixed 20 Hz loop that drives the server.

	Fixed timestep is not a stylistic choice. Lag compensation requires that
	tick N means the same thing on every machine, and a deterministic step is
	what makes the pure-core simulation testable off-engine at all.

	Heartbeat runs at frame rate, which varies. The accumulator converts that
	into a whole number of fixed steps, carrying the remainder forward.

	Budget: 12 ms of the 50 ms tick at 40 entities and 4 players. Overruns are
	logged with a per-phase breakdown rather than silently dropped — a tick
	that quietly takes 60 ms looks like lag, not like a bug.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Instance require, not a relative string require: `src/shared` maps to
-- ReplicatedStorage.Shared while this file lives under ServerScriptService, and
-- relative traversal cannot cross between services. See CLAUDE.md.
local Shared = ReplicatedStorage:WaitForChild("Shared")

local NetcodeConfig = require(Shared.config.Netcode)

export type Phase = {
	name: string,
	fn: (tick: number, dt: number) -> (),
}

export type Stats = {
	ticks: number,
	p50: number,
	p95: number,
	p99: number,
	worst: number,
	overruns: number,
	phaseMs: { [string]: number },
}

local TickService = {}

local TICK_SECONDS = NetcodeConfig.TICK_SECONDS
local BUDGET_MS = NetcodeConfig.TICK_BUDGET_MS
local SAMPLE_WINDOW = 600 -- 30s at 20Hz

--- Guards against a long hitch (a hang, a Studio breakpoint) turning into a
--- burst of catch-up ticks that each run the full simulation.
local MAX_STEPS_PER_FRAME = 5

local phases: { Phase } = {}
local connection: RBXScriptConnection? = nil

local accumulator = 0
local tickIndex = 0
local samples: { number } = {}
local phaseTotals: { [string]: number } = {}
local overruns = 0

--- Register a phase. Order of registration is order of execution.
function TickService.addPhase(name: string, fn: (tick: number, dt: number) -> ())
	assert(connection == nil, "TickService.addPhase: cannot add phases after start()")
	table.insert(phases, { name = name, fn = fn })
	phaseTotals[name] = 0
end

function TickService.getTick(): number
	return tickIndex
end

--- Shared clock. Both sides read `workspace:GetServerTimeNow()`, which Roblox
--- keeps synchronised, so a client timestamp is comparable to a server one
--- without inventing a handshake.
function TickService.now(): number
	return workspace:GetServerTimeNow()
end

local function percentile(sorted: { number }, fraction: number): number
	local count = #sorted
	if count == 0 then
		return 0
	end
	return sorted[math.clamp(math.ceil(count * fraction), 1, count)]
end

function TickService.getStats(): Stats
	local sorted = table.clone(samples)
	table.sort(sorted)

	local worst = 0
	for _, value in sorted do
		worst = math.max(worst, value)
	end

	local phaseMs: { [string]: number } = {}
	local count = math.max(#samples, 1)
	for name, total in phaseTotals do
		phaseMs[name] = total / count
	end

	return {
		ticks = tickIndex,
		p50 = percentile(sorted, 0.50),
		p95 = percentile(sorted, 0.95),
		p99 = percentile(sorted, 0.99),
		worst = worst,
		overruns = overruns,
		phaseMs = phaseMs,
	}
end

function TickService.resetStats()
	table.clear(samples)
	for name in phaseTotals do
		phaseTotals[name] = 0
	end
	overruns = 0
end

local function step()
	tickIndex += 1
	local tickStart = os.clock()

	for _, phase in phases do
		local phaseStart = os.clock()
		debug.profilebegin(phase.name)

		-- One misbehaving phase must not stop the loop: a dead tick loop is a
		-- dead server, while a logged error is recoverable.
		local ok, err = pcall(phase.fn, tickIndex, TICK_SECONDS)
		debug.profileend()

		if not ok then
			warn(`[TickService] phase "{phase.name}" errored on tick {tickIndex}: {err}`)
		end
		phaseTotals[phase.name] += (os.clock() - phaseStart) * 1000
	end

	local elapsedMs = (os.clock() - tickStart) * 1000
	table.insert(samples, elapsedMs)
	if #samples > SAMPLE_WINDOW then
		table.remove(samples, 1)
	end

	if elapsedMs > BUDGET_MS then
		overruns += 1
		-- Rate-limited: a sustained overrun should not itself become the
		-- performance problem by spamming output every tick.
		if overruns % 20 == 1 then
			local parts: { string } = {}
			for _, phase in phases do
				table.insert(parts, `{phase.name}={string.format("%.2f", phaseTotals[phase.name] / math.max(#samples, 1))}ms`)
			end
			warn(
				`[TickService] tick {tickIndex} took {string.format("%.2f", elapsedMs)}ms `
					.. `(budget {BUDGET_MS}ms) — mean per phase: {table.concat(parts, " ")}`
			)
		end
	end
end

function TickService.start()
	assert(connection == nil, "TickService.start: already running")
	accumulator = 0

	connection = RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt

		local steps = 0
		while accumulator >= TICK_SECONDS and steps < MAX_STEPS_PER_FRAME do
			accumulator -= TICK_SECONDS
			steps += 1
			step()
		end

		-- Fell too far behind to catch up. Dropping the backlog keeps the
		-- simulation running in real time instead of spiralling.
		if accumulator >= TICK_SECONDS then
			local dropped = math.floor(accumulator / TICK_SECONDS)
			accumulator = 0
			warn(`[TickService] dropped {dropped} tick(s) after a hitch`)
		end
	end)
end

function TickService.stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

function TickService.isRunning(): boolean
	return connection ~= nil
end

return TickService
