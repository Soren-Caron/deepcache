--!strict
--[[ M2-5. Arc ramp curve and Slug travel/drop maths. ]]

local t = require("./framework")
local expect = t.expect

local Ballistics = require("../src/shared/core/sim/Ballistics")
local Types = require("../src/shared/core/Types")
local Weapons = require("../src/shared/config/Weapons")

local ARC = Weapons.Arc
local SLUG = Weapons.Slug

--------------------------------------------------------------------------------

t.describe("Ballistics.arcRamp", function()
	t.it("starts at 1 and compounds per second", function()
		expect(Ballistics.arcRamp(0, ARC.rampPerSecond, ARC.rampMax)).approx(1.0, 1e-9)
		expect(Ballistics.arcRamp(1, 1.15, 3.0)).approx(1.15, 1e-9)
		expect(Ballistics.arcRamp(2, 1.15, 3.0)).approx(1.3225, 1e-9)
		expect(Ballistics.arcRamp(3, 1.15, 3.0)).approx(1.520875, 1e-9)
	end)

	t.it("clamps at rampMax and stays there", function()
		expect(Ballistics.arcRamp(100, 1.15, 3.0)).toEqual(3.0)
		expect(Ballistics.arcRamp(1e6, 1.15, 3.0)).toEqual(3.0)
		-- The cap is reached around 7.9s at 1.15/s; just past it must be capped.
		expect(Ballistics.arcRamp(8, 1.15, 3.0)).toEqual(3.0)
		expect(Ballistics.arcRamp(7, 1.15, 3.0) < 3.0).toBeTruthy()
	end)

	t.it("increases monotonically up to the cap", function()
		local previous = 0
		for tenths = 0, 120 do
			local value = Ballistics.arcRamp(tenths / 10, ARC.rampPerSecond, ARC.rampMax)
			expect(value >= previous).toBeTruthy()
			previous = value
		end
	end)

	t.it("never dips below 1 or returns a non-finite value", function()
		for _, seconds in { -5, -0.001, 0, 0 / 0, math.huge } do
			local value = Ballistics.arcRamp(seconds, ARC.rampPerSecond, ARC.rampMax)
			expect(value == value).toBeTruthy()
			expect(value >= 1).toBeTruthy()
			expect(value <= ARC.rampMax).toBeTruthy()
		end
	end)

	t.it("treats a degenerate ramp rate as no ramp", function()
		-- A rate below 1 would make sustained fire weaker over time.
		expect(Ballistics.arcRamp(5, 0.5, 3.0)).toEqual(1)
		expect(Ballistics.arcRamp(5, 1.15, 0.5)).toEqual(1)
	end)
end)

t.describe("Ballistics.arcTick", function()
	t.it("builds credit while the beam holds a target", function()
		local seconds = 0
		for _ = 1, 20 do
			seconds = Ballistics.arcTick(seconds, 0.05, true)
		end
		expect(seconds).approx(1.0, 1e-9)
	end)

	t.it("bleeds credit faster than it builds when the beam comes off", function()
		-- Sweeping between targets must not preserve the ramp, or the beam's
		-- commitment cost disappears.
		local seconds = Ballistics.arcTick(2.0, 0.5, false)
		expect(seconds).approx(2.0 - 0.5 * Ballistics.ARC_DECAY_RATE, 1e-9)
		expect(Ballistics.ARC_DECAY_RATE > 1).toBeTruthy()
	end)

	t.it("floors at zero rather than going negative", function()
		expect(Ballistics.arcTick(0.1, 10, false)).toEqual(0)
		expect(Ballistics.arcTick(0, 1, false)).toEqual(0)
	end)

	t.it("survives a non-finite dt", function()
		expect(Ballistics.arcTick(1, 0 / 0, true)).toEqual(1)
		expect(Ballistics.arcTick(1, math.huge, true)).toEqual(1)
	end)

	t.it("a full hold reaches the cap, an interrupted one does not", function()
		local held, broken = 0, 0
		for tick = 1, 200 do
			held = Ballistics.arcTick(held, 0.05, true)
			-- The interrupted beam comes off target every fourth tick.
			broken = Ballistics.arcTick(broken, 0.05, tick % 4 ~= 0)
		end
		expect(Ballistics.arcRamp(held, ARC.rampPerSecond, ARC.rampMax)).toEqual(ARC.rampMax)
		expect(Ballistics.arcRamp(broken, ARC.rampPerSecond, ARC.rampMax) < ARC.rampMax).toBeTruthy()
	end)
end)

t.describe("Ballistics.arcDamage", function()
	t.it("is damage per second scaled by tick length and ramp", function()
		expect(Ballistics.arcDamage(0.05, 40, 1.0)).approx(2.0, 1e-9)
		expect(Ballistics.arcDamage(0.05, 40, 3.0)).approx(6.0, 1e-9)
	end)

	t.it("sums to the configured dps over a second of unramped contact", function()
		local total = 0
		for _ = 1, 20 do
			total += Ballistics.arcDamage(0.05, ARC.damagePerSecond, 1.0)
		end
		expect(total).approx(ARC.damagePerSecond, 1e-9)
	end)

	t.it("never deals negative damage", function()
		expect(Ballistics.arcDamage(-1, 40, 1)).toEqual(0)
		expect(Ballistics.arcDamage(0.05, -40, 1)).toEqual(0)
		expect(Ballistics.arcDamage(0 / 0, 40, 1)).toEqual(0)
	end)
end)

t.describe("Ballistics projectile motion", function()
	local FLAT = { x = 0, y = 0, z = 1 }
	local ORIGIN = { x = 0, y = 10, z = 0 }

	t.it("travels at the configured speed along the aim axis", function()
		local at = Ballistics.positionAt(ORIGIN, FLAT, SLUG.projectileSpeed, SLUG.gravity, 0.5)
		expect(at.z).approx(SLUG.projectileSpeed * 0.5, 1e-9)
		expect(at.x).approx(0, 1e-9)
	end)

	t.it("drops by 1/2 g t^2", function()
		local at = Ballistics.positionAt(ORIGIN, FLAT, SLUG.projectileSpeed, SLUG.gravity, 1.0)
		expect(at.y).approx(10 - 0.5 * SLUG.gravity, 1e-9)
	end)

	t.it("matches the documented feel at range", function()
		-- 180 studs/s, g = 14: a 120-stud shot takes 2/3 s and drops ~3.1 studs,
		-- which is the difference between a body shot and a leg shot.
		local time = Ballistics.timeOfFlight(120, SLUG.projectileSpeed)
		expect(time).approx(120 / 180, 1e-9)
		expect(Ballistics.dropOverDistance(120, SLUG.projectileSpeed, SLUG.gravity)).approx(3.111, 0.01)
		-- At point blank the drop is negligible, which is why it feels hitscan
		-- up close.
		expect(Ballistics.dropOverDistance(20, SLUG.projectileSpeed, SLUG.gravity) < 0.1).toBeTruthy()
	end)

	t.it("drops more the further it flies, always", function()
		local previous = -1
		for distance = 0, 200, 5 do
			local drop = Ballistics.dropOverDistance(distance, SLUG.projectileSpeed, SLUG.gravity)
			expect(drop >= previous).toBeTruthy()
			previous = drop
		end
	end)

	t.it("normalises the aim vector so muzzle speed cannot be inflated", function()
		-- A caller passing an un-normalised direction would otherwise get a
		-- faster projectile than the weapon allows.
		local unit = Ballistics.positionAt(ORIGIN, { x = 0, y = 0, z = 1 }, 100, 0, 1)
		local long = Ballistics.positionAt(ORIGIN, { x = 0, y = 0, z = 25 }, 100, 0, 1)
		expect(long.z).approx(unit.z, 1e-9)
	end)

	t.it("treats a zero-length direction as no travel rather than NaN", function()
		local at = Ballistics.positionAt(ORIGIN, { x = 0, y = 0, z = 0 }, 180, 14, 1)
		expect(at.x == at.x and at.y == at.y and at.z == at.z).toBeTruthy()
		expect(at.x).approx(0, 1e-9)
		expect(at.z).approx(0, 1e-9)
	end)

	t.it("integrates to within half a gravity-step of the closed form", function()
		-- The server ticks the projectile rather than evaluating the closed
		-- form, so the two must not diverge over a full flight.
		local dt = 1 / 20
		local position = ORIGIN
		local velocity = Ballistics.velocityAt(FLAT, SLUG.projectileSpeed, SLUG.gravity, 0)
		local elapsed = 0
		for _ = 1, 20 do
			position, velocity = Ballistics.step(position, velocity, SLUG.gravity, dt)
			elapsed += dt
		end
		local exact = Ballistics.positionAt(ORIGIN, FLAT, SLUG.projectileSpeed, SLUG.gravity, elapsed)
		expect(position.z).approx(exact.z, 1e-6)
		-- Semi-implicit Euler lags the closed form by g*dt*t/2 in the vertical.
		expect(position.y).approx(exact.y, 0.5 * SLUG.gravity * dt * elapsed + 1e-6)
		expect(Types.distance(position, exact) < 2).toBeTruthy()
	end)

	t.it("reports an infinite flight time for a zero-speed projectile", function()
		expect(Ballistics.timeOfFlight(100, 0)).toEqual(math.huge)
		expect(Ballistics.dropOverDistance(100, 0, 14)).toEqual(math.huge)
	end)
end)

t.describe("Ballistics.launchAngle", function()
	t.it("returns the flat solution that lands on target", function()
		local angle = Ballistics.launchAngle(120, SLUG.projectileSpeed, SLUG.gravity) :: number
		expect(angle).never().toBeNil()
		expect(angle > 0).toBeTruthy()

		-- Fire at that elevation and check it comes back to launch height at
		-- the requested distance.
		local dir = { x = 0, y = math.sin(angle), z = math.cos(angle) }
		local flight = 2 * SLUG.projectileSpeed * math.sin(angle) / SLUG.gravity
		local at = Ballistics.positionAt({ x = 0, y = 0, z = 0 }, dir, SLUG.projectileSpeed, SLUG.gravity, flight)
		expect(at.y).approx(0, 1e-6)
		expect(at.z).approx(120, 1e-4)
	end)

	t.it("returns nil past maximum range instead of a bogus angle", function()
		expect(Ballistics.launchAngle(1e6, SLUG.projectileSpeed, SLUG.gravity)).toBeNil()
		expect(Ballistics.launchAngle(100, 0, 14)).toBeNil()
	end)

	t.it("is a flat shot with no gravity", function()
		expect(Ballistics.launchAngle(500, 180, 0)).toEqual(0)
	end)
end)
