--!strict

local t = require("./framework")
local expect = t.expect

local DamageModel = require("../src/shared/core/sim/DamageModel")
local EntityState = require("../src/shared/core/sim/EntityState")
local Steering = require("../src/shared/core/sim/Steering")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3

--------------------------------------------------------------------------------
-- DamageModel
--------------------------------------------------------------------------------

t.describe("sim/DamageModel falloff", function()
	t.it("is full damage at and inside falloffStart", function()
		expect(DamageModel.falloff(0, 45, 110, 0.45)).toEqual(1)
		expect(DamageModel.falloff(45, 45, 110, 0.45)).toEqual(1)
	end)

	t.it("is the floor at and beyond falloffEnd", function()
		expect(DamageModel.falloff(110, 45, 110, 0.45)).toEqual(0.45)
		expect(DamageModel.falloff(5000, 45, 110, 0.45)).toEqual(0.45)
	end)

	t.it("interpolates linearly between the boundaries", function()
		-- Midpoint of [45, 110] is 77.5 -> halfway between 1.0 and 0.45.
		expect(DamageModel.falloff(77.5, 45, 110, 0.45)).approx(0.725, 1e-9)
		expect(DamageModel.falloff(61.25, 45, 110, 0.45)).approx(0.8625, 1e-9)
	end)

	t.it("is monotonically non-increasing with distance", function()
		local previous = math.huge
		for distance = 0, 200, 2 do
			local value = DamageModel.falloff(distance, 45, 110, 0.45)
			expect(value <= previous + 1e-12).toBeTruthy()
			previous = value
		end
	end)

	t.it("degenerates to a step when start equals end", function()
		-- Slug config has falloffStart == falloffEnd; this must not divide by zero.
		expect(DamageModel.falloff(199, 200, 200, 1.0)).toEqual(1)
		expect(DamageModel.falloff(201, 200, 200, 0.5)).toEqual(0.5)
	end)
end)

t.describe("sim/DamageModel compute", function()
	local function input(overrides: { [string]: any }): DamageModel.DamageInput
		local base: { [string]: any } = {
			baseDamage = 100,
			distance = 0,
			falloffStart = 45,
			falloffEnd = 110,
			minMultiplier = 0.5,
			armor = 0,
			headshot = false,
			headshotMultiplier = 2,
		}
		for k, value in overrides do
			base[k] = value
		end
		return base :: any
	end

	t.it("returns base damage at point blank with no armor", function()
		expect(DamageModel.compute(input({}))).approx(100, 1e-9)
	end)

	t.it("applies the headshot multiplier", function()
		expect(DamageModel.compute(input({ headshot = true }))).approx(200, 1e-9)
	end)

	t.it("defaults the headshot multiplier to 1 when absent", function()
		-- Built literally rather than via the override helper: assigning nil in
		-- a table literal does not create the key, so an override cannot
		-- express "remove this field".
		expect(DamageModel.compute({
			baseDamage = 100,
			distance = 0,
			falloffStart = 45,
			falloffEnd = 110,
			minMultiplier = 0.5,
			armor = 0,
			headshot = true,
		})).approx(100, 1e-9)
	end)

	t.it("stacks falloff and headshot", function()
		-- At falloffEnd the multiplier is 0.5; a headshot doubles it back.
		expect(DamageModel.compute(input({ distance = 110, headshot = true }))).approx(100, 1e-9)
	end)

	t.it("reduces damage by armor", function()
		expect(DamageModel.compute(input({ armor = 0.25 }))).approx(75, 1e-9)
		expect(DamageModel.compute(input({ armor = 0.5 }))).approx(50, 1e-9)
	end)

	t.it("caps armor below total immunity", function()
		-- A fully immune entity is an unwinnable softlock, so armor saturates.
		expect(DamageModel.compute(input({ armor = 1 }))).approx(5, 1e-9)
		expect(DamageModel.compute(input({ armor = 99 }))).approx(5, 1e-9)
		expect(DamageModel.compute(input({ armor = 1 })) > 0).toBeTruthy()
	end)

	t.it("treats negative armor as zero", function()
		expect(DamageModel.compute(input({ armor = -5 }))).approx(100, 1e-9)
	end)

	t.it("never returns negative damage", function()
		expect(DamageModel.compute(input({ baseDamage = -50 }))).toEqual(0)
		expect(DamageModel.compute(input({ baseDamage = 0 }))).toEqual(0)
	end)

	t.it("treats negative distance as point blank", function()
		expect(DamageModel.compute(input({ distance = -10 }))).approx(100, 1e-9)
	end)
end)

--------------------------------------------------------------------------------
-- EntityState
--------------------------------------------------------------------------------

local STATS: EntityState.Stats = { hp = 100, hitboxRadius = 2 }

t.describe("sim/EntityState", function()
	t.it("creates an entity in the spawn state at full health", function()
		local e = EntityState.create(7, "Skitter", v3(1, 2, 3), 42, STATS)
		expect(e.id).toEqual(7)
		expect(e.kind).toEqual("Skitter")
		expect(e.state).toEqual("spawn")
		expect(e.hp).toEqual(100)
		expect(e.maxHp).toEqual(100)
		expect(e.spawnedAtTick).toEqual(42)
		expect(e.pos).toEqual({ x = 1, y = 2, z = 3 })
	end)

	t.it("copies the position rather than aliasing the caller's table", function()
		local pos = v3(1, 2, 3)
		local e = EntityState.create(1, "Skitter", pos, 0, STATS)
		pos.x = 999
		expect(e.pos.x).toEqual(1)
	end)

	t.it("rejects non-positive hp", function()
		expect(function()
			EntityState.create(1, "Skitter", v3(0, 0, 0), 0, { hp = 0, hitboxRadius = 1 })
		end).toThrow("hp")
	end)

	t.it("enforces the transition table", function()
		expect(EntityState.canTransition("spawn", "move")).toBeTruthy()
		expect(EntityState.canTransition("move", "attack")).toBeTruthy()
		expect(EntityState.canTransition("attack", "death")).toBeTruthy()
		-- spawn cannot jump straight to attacking
		expect(EntityState.canTransition("spawn", "attack")).toBeFalsy()
		-- stagger cannot attack without recovering first
		expect(EntityState.canTransition("stagger", "attack")).toBeFalsy()
	end)

	t.it("makes death terminal", function()
		-- The bug this prevents is corpses that stand up and keep attacking.
		for _, target in { "idle", "move", "attack", "stagger", "spawn" } do
			expect(EntityState.canTransition("death", target :: any)).toBeFalsy()
		end
	end)

	t.it("refuses an illegal transition without mutating or throwing", function()
		local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
		expect(EntityState.transition(e, "attack")).toBeFalsy()
		expect(e.state).toEqual("spawn")
		expect(EntityState.transition(e, "move")).toBeTruthy()
		expect(e.state).toEqual("move")
	end)

	t.it("treats a self-transition as a no-op success", function()
		local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
		EntityState.transition(e, "idle")
		expect(EntityState.transition(e, "idle")).toBeTruthy()
		expect(e.state).toEqual("idle")
	end)

	t.it("applies damage and reports the kill exactly once", function()
		local e = EntityState.create(1, "Hauler", v3(0, 0, 0), 0, STATS)
		local applied, died = EntityState.applyDamage(e, 30)
		expect(applied).toEqual(30)
		expect(died).toBeFalsy()
		expect(e.hp).toEqual(70)

		applied, died = EntityState.applyDamage(e, 500)
		-- Overkill is clipped, so a killing blow cannot over-credit damage.
		expect(applied).toEqual(70)
		expect(died).toBeTruthy()
		expect(e.hp).toEqual(0)
		expect(e.state).toEqual("death")

		-- A second hit on a corpse must not re-award the kill.
		applied, died = EntityState.applyDamage(e, 50)
		expect(applied).toEqual(0)
		expect(died).toBeFalsy()
	end)

	t.it("ignores zero and negative damage", function()
		local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
		expect(select(1, EntityState.applyDamage(e, 0))).toEqual(0)
		expect(select(1, EntityState.applyDamage(e, -10))).toEqual(0)
		expect(e.hp).toEqual(100)
	end)

	t.it("produces a view with hp as a fraction", function()
		local e = EntityState.create(3, "Warden", v3(5, 6, 7), 0, STATS)
		EntityState.applyDamage(e, 25)
		local view = EntityState.toView(e)
		expect(view.id).toEqual(3)
		expect(view.hpPct).approx(0.75, 1e-9)
		expect(view.pos).toEqual({ x = 5, y = 6, z = 7 })
	end)

	-- Regression: corpses were reaped one tick after dying because the reap
	-- clock was derived from spawnedAtTick (almost always far in the past)
	-- instead of the death tick. The client never saw the death state, and a
	-- shot fired just before the kill found nothing left to rewind onto.
	-- Caught in a Studio smoke test; the rule now lives here so it cannot
	-- regress silently.
	t.describe("corpse lifetime", function()
		local function killed(tick: number): Types.Entity
			local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
			EntityState.transition(e, "idle")
			EntityState.applyDamage(e, 9999)
			EntityState.markDeath(e, tick)
			return e
		end

		t.it("does not reap a living entity", function()
			local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
			expect(EntityState.shouldReap(e, 100000)).toBeFalsy()
		end)

		t.it("stamps the death tick, not the spawn tick", function()
			-- The entity spawned at tick 0 and died at 500. If the reap clock
			-- used spawnedAtTick it would fire immediately.
			local e = killed(500)
			expect(e.diedAtTick).toEqual(500)
			expect(e.spawnedAtTick).toEqual(0)
			expect(EntityState.shouldReap(e, 501)).toBeFalsy()
		end)

		t.it("keeps the corpse for exactly CORPSE_TICKS", function()
			local e = killed(500)
			expect(EntityState.shouldReap(e, 500 + EntityState.CORPSE_TICKS)).toBeFalsy()
			expect(EntityState.shouldReap(e, 500 + EntityState.CORPSE_TICKS + 1)).toBeTruthy()
		end)

		t.it("markDeath is idempotent so the deadline cannot be pushed out", function()
			-- step() calls it every tick while dead; if it re-stamped, the
			-- corpse would live forever.
			local e = killed(500)
			for tick = 501, 600 do
				EntityState.markDeath(e, tick)
			end
			expect(e.diedAtTick).toEqual(500)
			expect(EntityState.shouldReap(e, 600)).toBeTruthy()
		end)

		t.it("never reaps a corpse that was never stamped", function()
			local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
			EntityState.transition(e, "idle")
			EntityState.applyDamage(e, 9999)
			expect(e.state).toEqual("death")
			expect(EntityState.shouldReap(e, 100000)).toBeFalsy()
		end)
	end)

	t.it("gives a view that does not alias the entity", function()
		local e = EntityState.create(1, "Skitter", v3(0, 0, 0), 0, STATS)
		local view = EntityState.toView(e)
		e.pos.x = 100
		expect(view.pos.x).toEqual(0)
	end)
end)

--------------------------------------------------------------------------------
-- Steering
--------------------------------------------------------------------------------

t.describe("sim/Steering seek", function()
	t.it("points at the target with the requested speed", function()
		local force = Steering.seek(v3(0, 0, 0), v3(10, 0, 0), 5)
		expect(force.x).approx(5, 1e-9)
		expect(force.z).approx(0, 1e-9)
		expect(Types.magnitude(force)).approx(5, 1e-9)
	end)

	t.it("ignores vertical offset", function()
		-- Entities are ground-bound; a target overhead must not launch them.
		local force = Steering.seek(v3(0, 0, 0), v3(0, 100, 10), 5)
		expect(force.y).toEqual(0)
		expect(force.z).approx(5, 1e-9)
	end)

	t.it("returns zero at the target rather than NaN", function()
		local force = Steering.seek(v3(3, 0, 3), v3(3, 0, 3), 5)
		expect(Types.magnitude(force)).toEqual(0)
		expect(force.x == force.x).toBeTruthy()
	end)

	t.it("converges when stepped", function()
		local pos = v3(0, 0, 0)
		local target = v3(30, 0, 40) -- 50 studs away
		local dt = 1 / 20
		for _ = 1, 200 do
			local velocity = Steering.seek(pos, target, 12)
			pos = Types.addVec3(pos, Types.scaleVec3(velocity, dt))
			if Types.distance(pos, target) < 0.5 then
				break
			end
		end
		expect(Types.distance(pos, target) < 0.5).toBeTruthy()
	end)
end)

t.describe("sim/Steering separate", function()
	t.it("pushes directly away from a single neighbour", function()
		local force = Steering.separate(v3(0, 0, 0), { v3(1, 0, 0) }, 5)
		expect(force.x < 0).toBeTruthy()
		expect(force.z).approx(0, 1e-9)
	end)

	t.it("pushes harder the closer the neighbour is", function()
		local near = Types.magnitude(Steering.separate(v3(0, 0, 0), { v3(0.5, 0, 0) }, 5))
		local far = Types.magnitude(Steering.separate(v3(0, 0, 0), { v3(4, 0, 0) }, 5))
		expect(near > far).toBeTruthy()
	end)

	t.it("ignores neighbours beyond the radius", function()
		expect(Types.magnitude(Steering.separate(v3(0, 0, 0), { v3(50, 0, 0) }, 5))).toEqual(0)
	end)

	t.it("resolves exact overlap deterministically instead of producing NaN", function()
		local a = Steering.separate(v3(0, 0, 0), { v3(0, 0, 0) }, 5)
		local b = Steering.separate(v3(0, 0, 0), { v3(0, 0, 0) }, 5)
		expect(Types.magnitude(a) > 0).toBeTruthy()
		expect(a.x == a.x).toBeTruthy()
		-- Determinism matters: a replayed simulation must not diverge.
		expect(a).toEqual(b)
	end)

	t.it("separates a co-located crowd when stepped", function()
		local positions = {}
		for i = 1, 20 do
			-- Start nearly on top of each other.
			positions[i] = v3(i * 0.01, 0, 0)
		end

		for _ = 1, 400 do
			local next_ = {}
			for i, pos in positions do
				local neighbours = {}
				for j, other in positions do
					if i ~= j then
						table.insert(neighbours, other)
					end
				end
				local push = Steering.separate(pos, neighbours, 3)
				next_[i] = Types.addVec3(pos, Types.scaleVec3(push, 0.05))
			end
			positions = next_
		end

		local worstOverlap = math.huge
		for i, a in positions do
			for j, b in positions do
				if i < j then
					worstOverlap = math.min(worstOverlap, Types.distance(a, b))
				end
			end
		end
		expect(worstOverlap > 0.5).toBeTruthy()
	end)
end)

t.describe("sim/Steering avoid", function()
	t.it("steers laterally around an obstacle ahead", function()
		local force = Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0.5, 0, 5), 10)
		expect(Types.magnitude(force) > 0).toBeTruthy()
		-- Obstacle sits to the right, so steer left (negative x here).
		expect(force.x < 0).toBeTruthy()
	end)

	t.it("ignores an obstacle behind", function()
		expect(Types.magnitude(Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0, 0, -5), 10))).toEqual(0)
	end)

	t.it("ignores an obstacle out of range", function()
		expect(Types.magnitude(Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0, 0, 50), 10))).toEqual(0)
	end)

	t.it("returns zero when stationary", function()
		expect(Types.magnitude(Steering.avoid(v3(0, 0, 0), v3(0, 0, 0), v3(0, 0, 5), 10))).toEqual(0)
	end)

	t.it("picks a side deterministically when dead ahead", function()
		-- Head-on with no lateral offset must not deadlock at zero.
		local force = Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0, 0, 5), 10)
		expect(Types.magnitude(force) > 0).toBeTruthy()
	end)

	t.it("steers harder as the obstacle gets closer", function()
		local near = Types.magnitude(Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0, 0, 1), 10))
		local far = Types.magnitude(Steering.avoid(v3(0, 0, 0), v3(0, 0, 1), v3(0, 0, 9), 10))
		expect(near > far).toBeTruthy()
	end)
end)

t.describe("sim/Steering keepDistance", function()
	t.it("advances when too far", function()
		local force = Steering.keepDistance(v3(0, 0, 0), v3(100, 0, 0), 40, 12)
		expect(force.x > 0).toBeTruthy()
	end)

	t.it("retreats when too close", function()
		local force = Steering.keepDistance(v3(0, 0, 0), v3(5, 0, 0), 40, 12)
		expect(force.x < 0).toBeTruthy()
	end)

	t.it("holds still inside the dead band", function()
		-- Without hysteresis a Lancer jitters across the preferred radius
		-- every tick, which reads as a twitching bug.
		expect(Types.magnitude(Steering.keepDistance(v3(0, 0, 0), v3(40, 0, 0), 40, 12))).toEqual(0)
		expect(Types.magnitude(Steering.keepDistance(v3(0, 0, 0), v3(38, 0, 0), 40, 12))).toEqual(0)
		expect(Types.magnitude(Steering.keepDistance(v3(0, 0, 0), v3(43, 0, 0), 40, 12))).toEqual(0)
	end)

	t.it("settles into the band when stepped", function()
		local pos = v3(0, 0, 0)
		local target = v3(120, 0, 0)
		for _ = 1, 500 do
			pos = Types.addVec3(pos, Types.scaleVec3(Steering.keepDistance(pos, target, 40, 12), 1 / 20))
		end
		local distance = Types.distance(pos, target)
		expect(distance > 40 * 0.9 - 1 and distance < 40 * 1.1 + 1).toBeTruthy()
	end)
end)

t.describe("sim/Steering combine", function()
	t.it("sums weighted forces", function()
		local result = Steering.combine({
			{ force = v3(1, 0, 0), weight = 2 },
			{ force = v3(0, 0, 1), weight = 3 },
		}, 100)
		expect(result.x).approx(2, 1e-9)
		expect(result.z).approx(3, 1e-9)
	end)

	t.it("clamps to maxSpeed", function()
		local result = Steering.combine({ { force = v3(100, 0, 0), weight = 1 } }, 12)
		expect(Types.magnitude(result)).approx(12, 1e-9)
	end)

	t.it("leaves an under-speed result untouched", function()
		local result = Steering.combine({ { force = v3(3, 0, 4), weight = 1 } }, 12)
		expect(Types.magnitude(result)).approx(5, 1e-9)
	end)

	t.it("handles an empty force list", function()
		expect(Types.magnitude(Steering.combine({}, 12))).toEqual(0)
	end)

	t.it("cancels opposing forces to zero", function()
		local result = Steering.combine({
			{ force = v3(5, 0, 0), weight = 1 },
			{ force = v3(-5, 0, 0), weight = 1 },
		}, 12)
		expect(Types.magnitude(result)).approx(0, 1e-9)
	end)
end)

t.describe("sim/Steering facingYaw", function()
	t.it("faces the direction of travel", function()
		expect(Steering.facingYaw(v3(0, 0, 1), 0)).approx(0, 1e-9)
		expect(Steering.facingYaw(v3(1, 0, 0), 0)).approx(math.pi / 2, 1e-9)
	end)

	t.it("keeps the current facing when stationary", function()
		-- Snapping to zero when an entity stops looks like a glitch.
		expect(Steering.facingYaw(v3(0, 0, 0), 1.234)).toEqual(1.234)
	end)

	t.it("holds facing for an offset below the caller's minimum magnitude", function()
		-- The bug this closes: a 0.3-stud offset is numerically fine, so the
		-- EPSILON floor accepts it, but its *direction* swings through tens of
		-- degrees per tick as the target shuffles. Enemies crowded onto a
		-- player spun violently as a result.
		expect(Steering.facingYaw(v3(0.3, 0, 0), 1.234, 2)).toEqual(1.234)
		-- Above the floor it still tracks normally.
		expect(Steering.facingYaw(v3(9, 0, 0), 1.234, 2)).approx(math.pi / 2, 1e-9)
	end)
end)

t.describe("sim/Steering angleDelta", function()
	t.it("takes the short way round the seam", function()
		-- 350 degrees left is really 10 degrees right.
		local from = math.rad(355)
		local to = math.rad(5)
		expect(Steering.angleDelta(from, to)).approx(math.rad(10), 1e-9)
		expect(Steering.angleDelta(to, from)).approx(math.rad(-10), 1e-9)
	end)

	t.it("is zero for identical angles and for full turns", function()
		expect(Steering.angleDelta(1.1, 1.1)).approx(0, 1e-9)
		expect(Steering.angleDelta(1.1, 1.1 + math.pi * 2)).approx(0, 1e-9)
	end)

	t.it("never exceeds half a turn in either direction", function()
		for degrees = -720, 720, 7 do
			local delta = Steering.angleDelta(0, math.rad(degrees))
			expect(math.abs(delta) <= math.pi + 1e-9).toBeTruthy()
		end
	end)
end)

t.describe("sim/Steering slewYaw", function()
	t.it("caps a turn at the rate limit", function()
		-- 3 rad/s for 0.05 s is 0.15 rad, however far away the target is.
		-- Deliberately not +/- math.pi here: exactly half a turn is a tie, and
		-- that case is pinned separately below.
		expect(Steering.slewYaw(0, 2.0, 3, 0.05)).approx(0.15, 1e-9)
		expect(Steering.slewYaw(0, -2.0, 3, 0.05)).approx(-0.15, 1e-9)
	end)

	t.it("resolves an exact half-turn consistently rather than jittering", function()
		-- A target dead behind is equally close either way. The choice does not
		-- matter; making the same choice every tick does, or the entity picks a
		-- new direction each frame and vibrates in place.
		local first = Steering.slewYaw(0, math.pi, 3, 0.05)
		expect(Steering.slewYaw(0, math.pi, 3, 0.05)).toEqual(first)
		expect(Steering.slewYaw(0, -math.pi, 3, 0.05)).toEqual(first)
	end)

	t.it("snaps exactly when the remaining turn fits inside one step", function()
		expect(Steering.slewYaw(0, 0.1, 3, 0.05)).approx(0.1, 1e-9)
	end)

	t.it("turns the short way across the seam rather than unwinding", function()
		local from = math.rad(355)
		local next_ = Steering.slewYaw(from, math.rad(5), 3, 0.05)
		-- Must increase past 360, not sweep back down through 180.
		expect(Steering.angleDelta(from, next_) > 0).toBeTruthy()
	end)

	t.it("converges rather than oscillating around the target", function()
		local yaw = 0
		local desired = math.rad(170)
		for _ = 1, 200 do
			yaw = Steering.slewYaw(yaw, desired, 3, 0.05)
		end
		expect(Steering.angleDelta(yaw, desired)).approx(0, 1e-9)
	end)

	t.it("cannot reverse facing in a single tick", function()
		-- The visible symptom: an instant 180 at 20 Hz reads as a spin.
		local flipped = Steering.slewYaw(0, math.pi, 3, 0.05)
		expect(math.abs(flipped) < math.pi / 2).toBeTruthy()
	end)

	t.it("holds facing for non-finite or non-positive inputs", function()
		expect(Steering.slewYaw(1.5, 0 / 0, 3, 0.05)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, 3, 0)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, 3, -1)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, 3, 0 / 0)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, 3, math.huge)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, 0, 0.05)).toEqual(1.5)
		expect(Steering.slewYaw(1.5, 2, -3, 0.05)).toEqual(1.5)
	end)
end)
