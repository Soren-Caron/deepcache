--!strict
--[[
	Snapshot serialization benchmark.

		lune run tools/loadtest/serialize

	Measures the wire format independently of the engine, so a format
	regression shows up in a terminal in two seconds rather than in a Studio
	playtest. Runs in CI.

	This does NOT measure the server tick budget — that needs the real engine
	and lives in tools/smoke/TickBench.luau, driven through the Studio MCP
	bridge. What this bounds is the serialization cost and the bandwidth claim
	in docs/03-NETCODE.md §What gets measured.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local NetcodeConfig = require("../../src/shared/config/Netcode")
local Snapshot = require("../../src/shared/core/net/Snapshot")
local Types = require("../../src/shared/core/Types")
local Rng = require("../../src/shared/core/util/Rng")

local ITERATIONS = 10000

-- Read from config rather than redeclaring. Local copies of these constants
-- are how the interest cap and the bandwidth budget silently drifted out of
-- agreement in the first place.
local TICK_RATE = NetcodeConfig.TICK_RATE
local INTEREST_MAX = NetcodeConfig.INTEREST_MAX
local BANDWIDTH_BUDGET_KBPS = NetcodeConfig.BANDWIDTH_BUDGET_KBPS

local ORIGIN = Types.vec3(0, 0, 0)
local STATES: { Types.EntityStateName } = { "idle", "move", "attack", "stagger", "death", "spawn" }

local function makeEntities(rng: Rng.Rng, count: number): { Types.EntityView }
	local out: { Types.EntityView } = table.create(count)
	for i = 1, count do
		out[i] = {
			id = i,
			pos = Types.vec3(
				(Rng.nextNumber(rng) * 2 - 1) * 800,
				(Rng.nextNumber(rng) * 2 - 1) * 50,
				(Rng.nextNumber(rng) * 2 - 1) * 800
			),
			yaw = Rng.nextNumber(rng) * math.pi * 2,
			state = STATES[Rng.nextRange(rng, 1, #STATES)],
			hpPct = Rng.nextNumber(rng),
		}
	end
	return out
end

--- Move a fraction of the set, as a real tick would.
local function jostle(rng: Rng.Rng, entities: { Types.EntityView }, fraction: number)
	local moves = math.max(1, math.floor(#entities * fraction))
	for _ = 1, moves do
		local e = entities[Rng.nextRange(rng, 1, #entities)]
		e.pos = Types.vec3(e.pos.x + (Rng.nextNumber(rng) * 2 - 1), e.pos.y, e.pos.z + (Rng.nextNumber(rng) * 2 - 1))
		e.yaw += (Rng.nextNumber(rng) * 2 - 1) * 0.2
	end
end

local function nsPerOp(seconds: number, ops: number): number
	return seconds / ops * 1e9
end

local function bench(label: string, count: number, movingFraction: number)
	local rng = Rng.new(20260815)
	local entities = makeEntities(rng, count)
	local baseline = Snapshot.decode(Snapshot.encode(0, entities, ORIGIN), ORIGIN).entities

	-- Keyframe encode
	local start = os.clock()
	local encoded: buffer = Snapshot.encode(0, entities, ORIGIN)
	for i = 1, ITERATIONS do
		encoded = Snapshot.encode(i, entities, ORIGIN)
	end
	local encodeSeconds = os.clock() - start
	local keyframeBytes = buffer.len(encoded)

	-- Keyframe decode
	start = os.clock()
	for _ = 1, ITERATIONS do
		Snapshot.decode(encoded, ORIGIN)
	end
	local decodeSeconds = os.clock() - start

	-- Delta encode, with a realistic fraction of the set moving
	jostle(rng, entities, movingFraction)
	start = os.clock()
	local delta: buffer = Snapshot.encodeDelta(1, entities, baseline, ORIGIN)
	for i = 1, ITERATIONS do
		delta = Snapshot.encodeDelta(i, entities, baseline, ORIGIN)
	end
	local deltaSeconds = os.clock() - start
	local deltaBytes = buffer.len(delta)

	-- Delta apply
	start = os.clock()
	for _ = 1, ITERATIONS do
		Snapshot.applyDelta(baseline, delta, ORIGIN)
	end
	local applySeconds = os.clock() - start

	stdio.write(`\n{label} — {count} entities, {math.floor(movingFraction * 100)}% moving\n`)
	stdio.write(`  keyframe encode   {string.format("%8.0f", nsPerOp(encodeSeconds, ITERATIONS))} ns/op   {keyframeBytes} bytes\n`)
	stdio.write(`  keyframe decode   {string.format("%8.0f", nsPerOp(decodeSeconds, ITERATIONS))} ns/op\n`)
	stdio.write(`  delta encode      {string.format("%8.0f", nsPerOp(deltaSeconds, ITERATIONS))} ns/op   {deltaBytes} bytes\n`)
	stdio.write(`  delta apply       {string.format("%8.0f", nsPerOp(applySeconds, ITERATIONS))} ns/op\n`)
	stdio.write(`  bytes/entity      {string.format("%.2f", keyframeBytes / count)}\n`)

	return keyframeBytes, deltaBytes
end

--------------------------------------------------------------------------------

stdio.write(stdio.color("cyan") .. "snapshot serialization benchmark" .. stdio.color("reset") .. "\n")
stdio.write(`{ITERATIONS} iterations per measurement\n`)

bench("small", 8, 0.5)
local interestBytes, interestDelta = bench("interest cap", INTEREST_MAX, 0.25)
local maxBytes = bench("packet max", Snapshot.capacity(), 0.25)

--------------------------------------------------------------------------------
-- Budget assertions
--------------------------------------------------------------------------------

local problems: { string } = {}

if maxBytes > Snapshot.MAX_BYTES then
	table.insert(problems, `full packet is {maxBytes} bytes, over the {Snapshot.MAX_BYTES} budget`)
end
if maxBytes > 1000 then
	table.insert(problems, `full packet is {maxBytes} bytes, above the UnreliableRemoteEvent drop threshold`)
end

-- Two figures, because they differ by 4x and only one of them bounds anything.
-- Typical: one keyframe per second plus 19 deltas at 25% churn.
local typicalKbps = (interestBytes + interestDelta * (TICK_RATE - 1)) / 1024
-- Worst case: every visible entity changes every tick, so deltas cost as much
-- as keyframes. This is what a live session with 40 entities all chasing the
-- player actually produces, measured at 6.10 KB/s.
local worstKbps = (Snapshot.HEADER_BYTES + INTEREST_MAX * Snapshot.ENTITY_BYTES) * TICK_RATE / 1024

stdio.write(`\nbandwidth per client at the {INTEREST_MAX}-entity interest cap\n`)
stdio.write(`  typical (25% moving) {string.format("%6.2f", typicalKbps)} KB/s\n`)
stdio.write(`  worst   (all moving) {string.format("%6.2f", worstKbps)} KB/s\n`)
stdio.write(`  budget               {string.format("%6.2f", BANDWIDTH_BUDGET_KBPS)} KB/s\n`)

-- The worst case is the one that must fit: it is reachable in normal play.
if worstKbps > BANDWIDTH_BUDGET_KBPS then
	table.insert(
		problems,
		`worst-case {string.format("%.2f", worstKbps)} KB/s exceeds the {BANDWIDTH_BUDGET_KBPS} KB/s budget`
	)
end

stdio.write("\n")
if #problems > 0 then
	stdio.write(stdio.color("red") .. `budget check FAILED ({#problems})` .. stdio.color("reset") .. "\n")
	for _, p in problems do
		stdio.write(`  - {p}\n`)
	end
	stdio.write("\n")
	process.exit(1)
end

stdio.write(stdio.color("green") .. "budget check passed" .. stdio.color("reset") .. "\n\n")
process.exit(0)
