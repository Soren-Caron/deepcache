--!strict
--[[
	Worklist for unimplemented core modules.

	Two jobs:

	1. Every stub is *loaded*, which type-checks its contract and catches a
	   broken require path the moment it appears rather than at M4.
	2. Each unimplemented function is recorded as a todo, so `lune run tests`
	   prints the remaining work without ever going red for it.

	As a module is implemented, delete its todos here and add a real spec file.
]]

local t = require("./framework")
local expect = t.expect

-- Loading these is the point: a require failure here is a real failure.
local modules = {
	Types = require("../src/shared/core/Types"),
	Quantize = require("../src/shared/core/net/Quantize"),
	Snapshot = require("../src/shared/core/net/Snapshot"),
	Interpolator = require("../src/shared/core/net/Interpolator"),
	History = require("../src/shared/core/net/History"),
	EntityState = require("../src/shared/core/sim/EntityState"),
	Steering = require("../src/shared/core/sim/Steering"),
	DamageModel = require("../src/shared/core/sim/DamageModel"),
	Budget = require("../src/shared/core/sim/Budget"),
	Schema = require("../src/shared/core/director/Schema"),
	Clamp = require("../src/shared/core/director/Clamp"),
	Fsm = require("../src/shared/core/director/Fsm"),
	Ledger = require("../src/shared/core/economy/Ledger"),
	Controller = require("../src/shared/core/economy/Controller"),
	Market = require("../src/shared/core/economy/Market"),
	Rating = require("../src/shared/core/discovery/Rating"),
	Bucket = require("../src/shared/core/discovery/Bucket"),
	Recommend = require("../src/shared/core/discovery/Recommend"),
	TwoBoneIk = require("../src/shared/core/anim/TwoBoneIk"),
	StepPlanner = require("../src/shared/core/anim/StepPlanner"),
	Assemble = require("../src/shared/core/level/Assemble"),
}

t.describe("core module surface", function()
	t.it("every core module loads", function()
		for name, mod in modules do
			expect(type(mod)).toEqual("table")
		end
	end)

	t.it("Types exposes working vector math (already implemented)", function()
		local T = modules.Types
		expect(T.distance(T.vec3(0, 0, 0), T.vec3(3, 4, 0))).approx(5, 1e-9)
		expect(T.magnitude(T.normalize(T.vec3(9, 0, 0)))).approx(1, 1e-9)
		-- Degenerate input must not produce NaN.
		expect(T.magnitude(T.normalize(T.vec3(0, 0, 0)))).toEqual(0)
		expect(T.lerpVec3(T.vec3(0, 0, 0), T.vec3(10, 0, 0), 0.25).x).approx(2.5, 1e-9)
	end)

	t.it("director constants are internally consistent", function()
		local S = modules.Schema
		local b = S.DEFAULT_BOUNDS
		expect(b.spawnMultiplierMin < b.spawnMultiplierMax).toBeTruthy()
		expect(b.threatTierMin < b.threatTierMax).toBeTruthy()
		expect(#S.OBJECTIVE_IDS).toEqual(5)
		expect(#S.SPAWN_PATTERNS).toEqual(4)
		expect(#S.INTENTS).toEqual(8)
	end)

	t.it("snapshot capacity math matches the documented budget", function()
		-- docs/03-NETCODE.md claims 81 entities per packet.
		expect(modules.Snapshot.capacity()).toEqual(81)
	end)

	t.it("stubs fail loudly rather than returning nil", function()
		expect(function()
			modules.Ledger.new()
		end).toThrow("unimplemented")
		expect(function()
			modules.Rating.new(0)
		end).toThrow("unimplemented")
	end)
end)

-- Worklist -------------------------------------------------------------------

-- M1 pure core is complete: see quantize / snapshot / history / interpolator /
-- sim spec files. What remains in M1 is Roblox adapter code (TickService,
-- EntityService, ReplicationService, CombatService, PredictionController,
-- MovementGuard, EntityRenderer), which is verified in Studio via MCP rather
-- than here.
t.describe("M1 adapters (Studio-verified)", function()
	t.todo("TickService: 20Hz accumulator, per-phase timing")
	t.todo("EntityService: 40 entities stepped, no server-side Instances")
	t.todo("ReplicationService: interest management, bandwidth under budget")
	t.todo("CombatService: fire validation pipeline end to end")
	t.todo("PredictionController: predict + reconcile")
	t.todo("MovementGuard: decaying violation score")
end)

-- Assemble is implemented and covered by tests/assemble.spec.luau.
t.describe("M2 loop", function()
	t.todo("Budget: never exceeds budget, caps respected, deterministic")
	t.todo("Fsm: all states reachable, no ping-pong, output in bounds")
end)

t.describe("M4 director", function()
	t.todo("Schema: enum guards")
	t.todo("Clamp: 20+ malformed inputs all return a valid decision")
	t.todo("Clamp: rate limiting and bark sanitisation")
end)

t.describe("M5 discovery", function()
	t.todo("Rating: matches hand-computed values, rd shrink/grow")
	t.todo("Bucket: widening boundaries, undersized start at 75s")
	t.todo("Recommend: shrinkage suppresses rare pairs, cold start")
end)

t.describe("M6 economy", function()
	t.todo("Ledger: duplicate idemKey no-op, balance = sum, no negatives")
	t.todo("Controller: converges, daily cap, sample floor, clamps hold")
	t.todo("Market: price-time priority, partial fills, self-trade rejected")
	t.todo("Market: fuzz 100k orders conserves currency and items")
end)

t.describe("M7 presentation", function()
	t.todo("TwoBoneIk: reachable / exact / unreachable / degenerate")
	t.todo("StepPlanner: opposing legs never lift together")
end)
