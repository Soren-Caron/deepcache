--!strict
--[[ Enemy attack timing and damage.

	The cases that matter are the ones that make a fight unfair in one
	direction or the other: striking on arrival (no reaction window), banking
	cooldowns while out of range (a burst on contact), never striking at all,
	and leaking cooldown entries across a long run.
]]

local t = require("./framework")
local expect = t.expect

local EnemyAttack = require("../src/shared/core/sim/EnemyAttack")
local Enemies = require("../src/shared/config/Enemies")

local STATS: { [string]: EnemyAttack.Stats } = {
	Skitter = { dmg = 8, atkRange = 4, atkCooldown = 0.8 },
	Lancer = { dmg = 14, atkRange = 55, atkCooldown = 1.2 },
}

local function attacker(overrides: { [string]: any }?): EnemyAttack.Attacker
	local base: EnemyAttack.Attacker = {
		id = 1,
		kind = "Skitter",
		pos = { x = 0, y = 0, z = 0 },
		state = "attack",
		targetId = 100,
	}
	for key, value in overrides or {} do
		(base :: any)[key] = value
	end
	return base
end

local function targetAt(x: number): EnemyAttack.Target
	return { id = 100, pos = { x = x, y = 0, z = 0 } }
end

--------------------------------------------------------------------------------

t.describe("EnemyAttack.step — the windup", function()
	t.it("does not strike on the tick it arrives", function()
		local state = EnemyAttack.new()
		local strikes = EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		expect(#strikes).toEqual(0)
	end)

	t.it("does not strike before a full cooldown has elapsed", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 0.79, { attacker() }, { targetAt(2) }, STATS)).toEqual(0)
	end)

	t.it("strikes once the cooldown elapses", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		local strikes = EnemyAttack.step(state, 0.8, { attacker() }, { targetAt(2) }, STATS)
		expect(#strikes).toEqual(1)
		expect(strikes[1].damage).approx(8, 1e-9)
		expect(strikes[1].entityId).toEqual(1)
		expect(strikes[1].targetId).toEqual(100)
	end)

	t.it("holds the cadence over a sustained engagement", function()
		local state = EnemyAttack.new()
		local hits = 0
		local now = 0
		-- 10 seconds at 20 Hz against a 0.8 s cooldown: the windup costs the
		-- first, so 12 rather than 12.5 -> 12.
		for _ = 1, 200 do
			hits += #EnemyAttack.step(state, now, { attacker() }, { targetAt(2) }, STATS)
			now += 0.05
		end
		expect(hits).toEqual(12)
	end)
end)

t.describe("EnemyAttack.step — refusals", function()
	t.it("never strikes outside attack range", function()
		local state = EnemyAttack.new()
		local hits = 0
		local now = 0
		for _ = 1, 200 do
			hits += #EnemyAttack.step(state, now, { attacker() }, { targetAt(40) }, STATS)
			now += 0.05
		end
		expect(hits).toEqual(0)
	end)

	t.it("strikes at exactly the range boundary and not one stud past", function()
		local inRange = EnemyAttack.new()
		EnemyAttack.step(inRange, 0, { attacker() }, { targetAt(4) }, STATS)
		expect(#EnemyAttack.step(inRange, 1, { attacker() }, { targetAt(4) }, STATS)).toEqual(1)

		local outOfRange = EnemyAttack.new()
		EnemyAttack.step(outOfRange, 0, { attacker() }, { targetAt(4.01) }, STATS)
		expect(#EnemyAttack.step(outOfRange, 1, { attacker() }, { targetAt(4.01) }, STATS)).toEqual(0)
	end)

	t.it("never strikes from a non-attack state", function()
		local state = EnemyAttack.new()
		for _, name in { "idle", "move", "stagger", "death", "spawn" } do
			local a = attacker({ state = name })
			EnemyAttack.step(state, 0, { a }, { targetAt(2) }, STATS)
			expect(#EnemyAttack.step(state, 10, { a }, { targetAt(2) }, STATS)).toEqual(0)
		end
	end)

	t.it("does not strike a target that no longer exists", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		-- Player extracted or disconnected between ticks.
		expect(#EnemyAttack.step(state, 10, { attacker() }, {}, STATS)).toEqual(0)
	end)

	t.it("does not strike without a target id", function()
		local state = EnemyAttack.new()
		-- Built literally rather than through `attacker`: a nil override cannot
		-- survive a pairs() copy, so the helper would silently keep the default
		-- and this test would pass no matter what the code did.
		local a: EnemyAttack.Attacker =
			{ id = 1, kind = "Skitter", pos = { x = 0, y = 0, z = 0 }, state = "attack", targetId = nil }
		EnemyAttack.step(state, 0, { a }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 10, { a }, { targetAt(2) }, STATS)).toEqual(0)
	end)

	t.it("ignores a kind with no stats rather than erroring", function()
		local state = EnemyAttack.new()
		local a = attacker({ kind = "Ghost" })
		EnemyAttack.step(state, 0, { a }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 10, { a }, { targetAt(2) }, STATS)).toEqual(0)
	end)

	t.it("deals nothing for a zero or negative damage stat", function()
		local state = EnemyAttack.new()
		local stats = { Skitter = { dmg = 0, atkRange = 4, atkCooldown = 0.8 } }
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, stats)
		expect(#EnemyAttack.step(state, 10, { attacker() }, { targetAt(2) }, stats)).toEqual(0)
	end)
end)

t.describe("EnemyAttack.step — cooldown banking", function()
	t.it("does not bank cooldowns while out of range", function()
		-- The bug this exists to prevent: an entity kept out of range for ten
		-- seconds, then closing, must not discharge ten hits back to back.
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		EnemyAttack.step(state, 0.8, { attacker() }, { targetAt(2) }, STATS)

		-- Ten seconds far away.
		local now = 1
		while now < 11 do
			EnemyAttack.step(state, now, { attacker() }, { targetAt(500) }, STATS)
			now += 0.05
		end

		-- Back in range: at most one hit per cooldown, not a burst.
		local hits = 0
		now = 11
		for _ = 1, 4 do
			hits += #EnemyAttack.step(state, now, { attacker() }, { targetAt(2) }, STATS)
			now += 0.05
		end
		expect(hits).toEqual(1)
	end)

	t.it("advances the next window from now, not from the missed deadline", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		-- Strike arrives late, at t=5 against a deadline of 0.8.
		expect(#EnemyAttack.step(state, 5, { attacker() }, { targetAt(2) }, STATS)).toEqual(1)
		-- Next is due at 5.8, not at 1.6.
		expect(#EnemyAttack.step(state, 5.5, { attacker() }, { targetAt(2) }, STATS)).toEqual(0)
		expect(#EnemyAttack.step(state, 5.8, { attacker() }, { targetAt(2) }, STATS)).toEqual(1)
	end)
end)

t.describe("EnemyAttack.step — multiple attackers", function()
	t.it("tracks cooldowns independently per entity", function()
		local state = EnemyAttack.new()
		local a = attacker({ id = 1 })
		local b = attacker({ id = 2, kind = "Lancer" })
		EnemyAttack.step(state, 0, { a, b }, { targetAt(3) }, STATS)
		-- Skitter is ready at 0.8, Lancer not until 1.2.
		local at09 = EnemyAttack.step(state, 0.9, { a, b }, { targetAt(3) }, STATS)
		expect(#at09).toEqual(1)
		expect(at09[1].entityId).toEqual(1)

		local at13 = EnemyAttack.step(state, 1.3, { a, b }, { targetAt(3) }, STATS)
		expect(#at13).toEqual(1)
		expect(at13[1].entityId).toEqual(2)
	end)

	t.it("lets a swarm hit together once each has served its own windup", function()
		local state = EnemyAttack.new()
		local swarm = {}
		for id = 1, 6 do
			table.insert(swarm, attacker({ id = id }))
		end
		EnemyAttack.step(state, 0, swarm, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 0.8, swarm, { targetAt(2) }, STATS)).toEqual(6)
	end)
end)

t.describe("EnemyAttack — cooldown table hygiene", function()
	t.it("reaps entries for entities that no longer exist", function()
		local state = EnemyAttack.new()
		local swarm = {}
		for id = 1, 50 do
			table.insert(swarm, attacker({ id = id }))
		end
		EnemyAttack.step(state, 0, swarm, { targetAt(2) }, STATS)
		expect(EnemyAttack.pendingCount(state)).toEqual(50)

		-- All but two die.
		EnemyAttack.step(state, 1, { attacker({ id = 1 }), attacker({ id = 2 }) }, { targetAt(2) }, STATS)
		expect(EnemyAttack.pendingCount(state)).toEqual(2)
	end)

	t.it("does not grow across many spawn/death cycles", function()
		local state = EnemyAttack.new()
		local now = 0
		for wave = 1, 60 do
			local swarm = {}
			for i = 1, 20 do
				table.insert(swarm, attacker({ id = wave * 1000 + i }))
			end
			EnemyAttack.step(state, now, swarm, { targetAt(2) }, STATS)
			now += 1
		end
		-- Only the final wave should remain resident.
		expect(EnemyAttack.pendingCount(state)).toEqual(20)
	end)
end)

t.describe("EnemyAttack.step — hostile inputs", function()
	t.it("returns nothing for a non-finite clock rather than firing everything", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 0 / 0, { attacker() }, { targetAt(2) }, STATS)).toEqual(0)
		expect(#EnemyAttack.step(state, math.huge, { attacker() }, { targetAt(2) }, STATS)).toEqual(0)
		-- And the state survives it.
		expect(#EnemyAttack.step(state, 0.8, { attacker() }, { targetAt(2) }, STATS)).toEqual(1)
	end)

	t.it("ignores a non-finite position rather than striking at infinite range", function()
		local state = EnemyAttack.new()
		local a = attacker({ pos = { x = 0 / 0, y = 0, z = 0 } })
		EnemyAttack.step(state, 0, { a }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 10, { a }, { targetAt(2) }, STATS)).toEqual(0)
	end)

	t.it("treats a non-finite damage stat as zero", function()
		local state = EnemyAttack.new()
		local stats = { Skitter = { dmg = 0 / 0, atkRange = 4, atkCooldown = 0.8 } }
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, stats)
		expect(#EnemyAttack.step(state, 10, { attacker() }, { targetAt(2) }, stats)).toEqual(0)
	end)

	t.it("survives a zero cooldown without spinning or erroring", function()
		local state = EnemyAttack.new()
		local stats = { Skitter = { dmg = 8, atkRange = 4, atkCooldown = 0 } }
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, stats)
		-- Every subsequent tick is a hit, which is what a zero cooldown means.
		expect(#EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, stats)).toEqual(1)
	end)
end)

t.describe("EnemyAttack — against the real roster", function()
	t.it("every enemy kind has the stats the resolver needs", function()
		for kind, config in Enemies do
			expect(type(config.dmg) == "number" and config.dmg > 0).toBeTruthy()
			expect(type(config.atkRange) == "number" and config.atkRange > 0).toBeTruthy()
			expect(type(config.atkCooldown) == "number" and config.atkCooldown > 0).toBeTruthy()
		end
	end)

	t.it("a Skitter needs a plausible number of hits to drop a full-health player", function()
		-- 100 HP against 8 damage is 13 hits at 0.8 s -- about 10 seconds of
		-- uninterrupted contact from a single Skitter. If this ever reads as 2
		-- or 3, the config moved and the game became a one-shot.
		local hits = math.ceil(100 / Enemies.Skitter.dmg)
		expect(hits >= 8 and hits <= 20).toBeTruthy()
	end)
end)
