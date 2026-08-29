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

t.describe("EnemyAttack.step — line of sight", function()
	local function blind()
		return function()
			return false
		end
	end
	local function clear()
		return function()
			return true
		end
	end

	t.it("never strikes through an obstruction", function()
		-- The bug this closes: player shots have raycast against level geometry
		-- since M1, and enemy attacks checked distance only. A Sentry at 45
		-- studs was shooting through walls from an adjacent room, so cover did
		-- not exist and contact could not be broken.
		local state = EnemyAttack.new()
		local hits = 0
		local now = 0
		for _ = 1, 200 do
			hits += #EnemyAttack.step(state, now, { attacker() }, { targetAt(2) }, STATS, blind())
			now += 0.05
		end
		expect(hits).toEqual(0)
	end)

	t.it("does not bank a windup while blocked", function()
		-- Otherwise an entity waits behind a wall accumulating its cooldown and
		-- strikes the instant the player steps into view, with no windup.
		local state = EnemyAttack.new()
		local now = 0
		for _ = 1, 100 do
			EnemyAttack.step(state, now, { attacker() }, { targetAt(2) }, STATS, blind())
			now += 0.05
		end
		-- First tick with sight is the windup, not a hit.
		expect(#EnemyAttack.step(state, now, { attacker() }, { targetAt(2) }, STATS, clear())).toEqual(0)
		expect(#EnemyAttack.step(state, now + 0.8, { attacker() }, { targetAt(2) }, STATS, clear())).toEqual(1)
	end)

	t.it("strikes normally when sight is clear", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS, clear())
		expect(#EnemyAttack.step(state, 0.8, { attacker() }, { targetAt(2) }, STATS, clear())).toEqual(1)
	end)

	t.it("treats an absent predicate as fully visible", function()
		-- Backwards compatible: omitting it is what the module did before.
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(2) }, STATS)
		expect(#EnemyAttack.step(state, 0.8, { attacker() }, { targetAt(2) }, STATS)).toEqual(1)
	end)

	t.it("is asked about the right pair of points", function()
		local seen: { { from: number, to: number } } = {}
		local probe = function(from, to)
			table.insert(seen, { from = from.x, to = to.x })
			return true
		end
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(3) }, STATS, probe)
		expect(#seen).toEqual(1)
		expect(seen[1].from).approx(0, 1e-9)
		expect(seen[1].to).approx(3, 1e-9)
	end)
end)

t.describe("EnemyAttack.step — damage falloff", function()
	local RANGED: { [string]: EnemyAttack.Stats } = {
		Sentry = { dmg = 100, atkRange = 40, atkCooldown = 1, falloffStart = 10, minMultiplier = 0.5 },
	}

	local function strikeAt(distance: number): number
		local state = EnemyAttack.new()
		local a: EnemyAttack.Attacker =
			{ id = 1, kind = "Sentry", pos = { x = 0, y = 0, z = 0 }, state = "attack", targetId = 100 }
		local target = { id = 100, pos = { x = distance, y = 0, z = 0 } }
		EnemyAttack.step(state, 0, { a }, { target }, RANGED)
		local strikes = EnemyAttack.step(state, 1, { a }, { target }, RANGED)
		return if #strikes > 0 then strikes[1].damage else 0
	end

	t.it("deals full damage inside the falloff start", function()
		expect(strikeAt(5)).approx(100, 1e-9)
		expect(strikeAt(10)).approx(100, 1e-9)
	end)

	t.it("deals the floor at maximum range", function()
		expect(strikeAt(40)).approx(50, 1e-9)
	end)

	t.it("interpolates linearly in between", function()
		-- Halfway from 10 to 40 is 25, so halfway from 1.0 to 0.5 is 0.75.
		expect(strikeAt(25)).approx(75, 1e-9)
	end)

	t.it("melee kinds with no falloff configured are unaffected", function()
		local state = EnemyAttack.new()
		EnemyAttack.step(state, 0, { attacker() }, { targetAt(3.9) }, STATS)
		local strikes = EnemyAttack.step(state, 1, { attacker() }, { targetAt(3.9) }, STATS)
		-- A Skitter biting at 3.9 studs is not weaker than at 1 stud.
		expect(strikes[1].damage).approx(8, 1e-9)
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

	-- docs/01 §Scaling -> Survivability records these targets and why.
	local PLAYER_HP = 100
	local SIDEARM_DPS = 22 * 4.0
	local CARBINE_DPS = 17 * 9.0
	--- How many melee attackers physically fit around one player. A 2.5-stud
	--- player ringed by ~2-stud bodies seats about six; summing a per-type cap
	--- of 24 assumes all of them touch you at once, which no geometry allows.
	local MELEE_CONTACT = 6

	t.it("every kind is beatable one-on-one with some reachable weapon", function()
		for kind, config in Enemies do
			local secondsToKillPlayer = PLAYER_HP / (config.dmg / config.atkCooldown)
			local best = config.hp / CARBINE_DPS
			expect(secondsToKillPlayer > best).toBeTruthy()
		end
	end)

	t.it("non-elite kinds are beatable with the starting Sidearm", function()
		-- Elites (budget >= 8) are squad content by design and are excluded.
		-- Everything the baseline planner throws at a lone player is not.
		for kind, config in Enemies do
			if config.budget < 8 then
				local secondsToKillPlayer = PLAYER_HP / (config.dmg / config.atkCooldown)
				expect(secondsToKillPlayer > config.hp / SIDEARM_DPS).toBeTruthy()
			end
		end
	end)

	t.it("a worst-case engagement still leaves time to react", function()
		-- The check that would have caught "impossible to beat". Modelled on
		-- what can actually engage: melee kinds are limited by how many bodies
		-- fit around a player, ranged kinds can all hold a sightline at once
		-- but are subject to falloff at the distance they hold it from.
		local MIN_SURVIVAL_SECONDS = 1.5
		for kind, config in Enemies do
			local dps = config.dmg / config.atkCooldown
			local attackers, multiplier
			if config.atkRange > 10 then
				attackers = config.capPerWave
				multiplier = config.minMultiplier or 1
			else
				attackers = math.min(config.capPerWave, MELEE_CONTACT)
				multiplier = 1
			end
			expect(PLAYER_HP / (dps * attackers * multiplier) >= MIN_SURVIVAL_SECONDS).toBeTruthy()
		end
	end)

	t.it("ranged kinds fall off with distance; melee kinds do not", function()
		for _, config in Enemies do
			if config.atkRange > 10 then
				expect(config.falloffStart ~= nil).toBeTruthy()
				expect(config.falloffStart < config.atkRange).toBeTruthy()
			end
		end
	end)
end)

--------------------------------------------------------------------------------
-- Reach capped by visibility.
--
-- The Vault's fog ends at 45 studs and a Lancer's authored range is 55, so it
-- opened fire from inside the fog -- from a place the renderer deliberately
-- hides. Being hit by something you could never have seen reads as the game
-- cheating rather than as a threat you misplayed, and it was reported that way
-- from play: "the ranged guys shoot from very far away".
--------------------------------------------------------------------------------

t.describe("sim/EnemyAttack effective range", function()
	local EnemyAttack_ = require("../src/shared/core/sim/EnemyAttack")

	t.it("caps reach at what the attacker's zone allows", function()
		-- Lancer 55, Vault fog 45 at 0.8 -> 36.
		expect(EnemyAttack_.effectiveRange(55, 36)).toEqual(36)
	end)

	t.it("never widens a kind's authored range", function()
		-- The Perimeter is visible to 180 studs; a Sentry still only reaches 45.
		expect(EnemyAttack_.effectiveRange(45, 144)).toEqual(45)
	end)

	t.it("falls back to the authored range when visibility is unknown", function()
		-- Outside every module -- there is no zone, so there is no fog rule to
		-- apply, and the kind's own stats stand.
		expect(EnemyAttack_.effectiveRange(55, nil)).toEqual(55)
	end)

	t.it("survives a nonsense cap", function()
		expect(EnemyAttack_.effectiveRange(55, 0 / 0)).toEqual(55)
		expect(EnemyAttack_.effectiveRange(55, -10)).toEqual(0)
	end)

	t.it("keeps every ranged kind inside the darkest zone's visibility", function()
		-- The property that matters, checked against the real config rather
		-- than a fixture: in the zone with the shortest sight line, nothing may
		-- outreach it.
		local Enemies = require("../src/shared/config/Enemies")
		local Zones = require("../src/shared/config/Zones")
		local Combat = require("../src/shared/config/Combat")

		local darkest = math.huge
		for _, zone in Zones :: any do
			darkest = math.min(darkest, zone.lighting.fogEnd)
		end
		local cap = darkest * Combat.ATTACK_VISIBILITY_FRACTION

		for _, config in Enemies :: any do
			expect(EnemyAttack_.effectiveRange(config.atkRange, cap) <= cap + 1e-9).toBeTruthy()
		end
	end)
end)
