--!strict

local t = require("./framework")
local expect = t.expect

local Raycast = require("../src/shared/core/sim/Raycast")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3
local FORWARD = v3(0, 0, 1)

local function view(id: number, x: number, y: number, z: number, state: Types.EntityStateName?): Types.EntityView
	return { id = id, kind = "Skitter" :: any, pos = v3(x, y, z), yaw = 0, state = state or "move", hpPct = 1 }
end

t.describe("sim/Raycast raySphere", function()
	t.it("hits a sphere dead ahead at the near surface", function()
		-- Sphere centre 10 away, radius 2, so the ray enters at 8.
		expect(Raycast.raySphere(v3(0, 0, 0), FORWARD, v3(0, 0, 10), 2)).approx(8, 1e-9)
	end)

	t.it("misses a sphere off to the side", function()
		expect(Raycast.raySphere(v3(0, 0, 0), FORWARD, v3(50, 0, 10), 2)).toBeNil()
	end)

	t.it("misses a sphere behind the ray", function()
		expect(Raycast.raySphere(v3(0, 0, 0), FORWARD, v3(0, 0, -10), 2)).toBeNil()
	end)

	t.it("treats an origin inside the hitbox as point-blank contact", function()
		-- Muzzle inside the target is a hit, not a miss.
		expect(Raycast.raySphere(v3(0, 0, 10), FORWARD, v3(0, 0, 10), 2)).toEqual(0)
		expect(Raycast.raySphere(v3(0, 0, 9), FORWARD, v3(0, 0, 10), 2)).toEqual(0)
	end)

	t.it("grazes a tangent correctly", function()
		-- Offset exactly equal to the radius: a single tangent point.
		local hit = Raycast.raySphere(v3(2, 0, 0), FORWARD, v3(0, 0, 10), 2)
		expect(hit).never().toBeNil()
		expect(hit :: number).approx(10, 1e-6)
	end)

	t.it("misses just outside the radius", function()
		expect(Raycast.raySphere(v3(2.001, 0, 0), FORWARD, v3(0, 0, 10), 2)).toBeNil()
	end)

	t.it("rejects a non-positive radius", function()
		expect(Raycast.raySphere(v3(0, 0, 0), FORWARD, v3(0, 0, 10), 0)).toBeNil()
		expect(Raycast.raySphere(v3(0, 0, 0), FORWARD, v3(0, 0, 10), -2)).toBeNil()
	end)

	t.it("works along an arbitrary direction", function()
		local dir = Types.normalize(v3(1, 0, 1))
		local center = Types.scaleVec3(dir, 20)
		expect(Raycast.raySphere(v3(0, 0, 0), dir, center, 3)).approx(17, 1e-6)
	end)

	t.it("works with a vertical component", function()
		expect(Raycast.raySphere(v3(0, 0, 0), v3(0, 1, 0), v3(0, 10, 0), 2)).approx(8, 1e-9)
	end)
end)

t.describe("sim/Raycast nearestEntity", function()
	local radii = { [1] = 2, [2] = 2, [3] = 2 }

	t.it("picks the closest of several entities in line", function()
		local entities = { view(3, 0, 0, 30), view(1, 0, 0, 10), view(2, 0, 0, 20) }
		local hit = Raycast.nearestEntity(v3(0, 0, 0), FORWARD, entities, radii, 100) :: Raycast.SphereHit
		expect(hit.entityId).toEqual(1)
		expect(hit.distance).approx(8, 1e-9)
	end)

	t.it("returns the impact point", function()
		local hit = Raycast.nearestEntity(v3(0, 0, 0), FORWARD, { view(1, 0, 0, 10) }, radii, 100) :: Raycast.SphereHit
		expect(hit.point.z).approx(8, 1e-9)
	end)

	t.it("respects maxDistance", function()
		-- maxDistance is the wall distance: a shot must not pass through
		-- geometry to reach a target behind it.
		local entities = { view(1, 0, 0, 50) }
		expect(Raycast.nearestEntity(v3(0, 0, 0), FORWARD, entities, radii, 20)).toBeNil()
		expect(Raycast.nearestEntity(v3(0, 0, 0), FORWARD, entities, radii, 100)).never().toBeNil()
	end)

	t.it("skips entities in excluded states", function()
		local entities = { view(1, 0, 0, 10, "death"), view(2, 0, 0, 20) }
		local hit = Raycast.nearestEntity(v3(0, 0, 0), FORWARD, entities, radii, 100, { death = true }) :: Raycast.SphereHit
		expect(hit.entityId).toEqual(2)
	end)

	t.it("ignores entities with no known radius", function()
		expect(Raycast.nearestEntity(v3(0, 0, 0), FORWARD, { view(99, 0, 0, 10) }, radii, 100)).toBeNil()
	end)

	t.it("returns nil when nothing is in the way", function()
		expect(Raycast.nearestEntity(v3(0, 0, 0), FORWARD, {}, radii, 100)).toBeNil()
		expect(Raycast.nearestEntity(v3(0, 0, 0), FORWARD, { view(1, 100, 0, 10) }, radii, 100)).toBeNil()
	end)
end)

t.describe("sim/Raycast headshot", function()
	t.it("counts a hit in the upper fraction", function()
		expect(Raycast.isHeadshot(v3(0, 1.5, 0), v3(0, 0, 0), 2, 0.6)).toBeTruthy()
	end)

	t.it("does not count a body hit", function()
		expect(Raycast.isHeadshot(v3(0, 0.5, 0), v3(0, 0, 0), 2, 0.6)).toBeFalsy()
		expect(Raycast.isHeadshot(v3(0, -1, 0), v3(0, 0, 0), 2, 0.6)).toBeFalsy()
	end)
end)
