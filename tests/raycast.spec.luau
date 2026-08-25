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

--------------------------------------------------------------------------------
-- Third-person aim parallax.
--
-- Not a test of Raycast's arithmetic so much as of the geometry lesson behind
-- how the client aims. Enemy rig parts are `CanQuery = false`, so a Roblox
-- raycast through the cursor sails past them and stops on whatever is behind.
-- The shot then leaves the *shoulder*, roughly twelve studs in front of the
-- camera, aimed at that far point -- and the two rays diverge in proportion to
-- how much further the backdrop is than the target.
--
-- Measured in Studio against a Sentry (radius 2.2) at 26 studs, camera 12.6
-- studs behind the shoulder: a backdrop at 40 studs left the shot 0.21 off
-- centre and it hit; open sky left it 3.11 off centre and it could not hit at
-- any range. The fix is to aim at the sphere the server will actually test,
-- which is what these cases pin.
--------------------------------------------------------------------------------

t.describe("sim/Raycast third-person aim parallax", function()
	--- Perpendicular distance from `centre` to the ray from `origin` toward
	--- `aim` -- how far off centre a shot fired at `aim` passes.
	local function missDistance(origin: Types.Vec3, aim: Types.Vec3, centre: Types.Vec3): number
		local d = Types.normalize(Types.subVec3(aim, origin))
		local toCentre = Types.subVec3(centre, origin)
		local projection = toCentre.x * d.x + toCentre.y * d.y + toCentre.z * d.z
		local lengthSq = toCentre.x * toCentre.x + toCentre.y * toCentre.y + toCentre.z * toCentre.z
		return math.sqrt(math.max(0, lengthSq - projection * projection))
	end

	-- The Studio geometry, reduced to round numbers. The offset that matters is
	-- the one *across* the line of fire, not the one along it: a camera directly
	-- behind the shoulder produces no parallax at all. Roblox's third-person
	-- camera sits behind and well above, and it is the height that does the
	-- damage.
	local CAMERA = v3(0, 8, -10)
	local SHOULDER = v3(0, 0, 0)
	local TARGET = v3(0, 0, 26)
	local RADIUS = 2.2

	t.it("aiming at a distant backdrop misses a target the cursor is over", function()
		-- The camera ray passes exactly through the target centre, so the cursor
		-- is dead on it. Extended to a backdrop 200 studs out, the shoulder shot
		-- aimed there still misses -- which is the whole bug.
		local direction = Types.normalize(Types.subVec3(TARGET, CAMERA))
		local backdrop = Types.addVec3(CAMERA, Types.scaleVec3(direction, 200))
		expect(missDistance(SHOULDER, backdrop, TARGET) > RADIUS).toBeTruthy()
	end)

	t.it("aiming at the sphere the ray actually meets hits it", function()
		local direction = Types.normalize(Types.subVec3(TARGET, CAMERA))
		local hit = Raycast.nearestEntity(
			CAMERA,
			direction,
			{ view(1, TARGET.x, TARGET.y, TARGET.z) },
			{ [1] = RADIUS },
			2000
		) :: Raycast.SphereHit
		expect(hit).never().toBeNil()
		expect(missDistance(SHOULDER, hit.point, TARGET) <= RADIUS).toBeTruthy()
	end)

	t.it("the error grows with how far past the target the backdrop is", function()
		-- Monotonic, which is why a corridor forgave the bug and an open hall
		-- did not: "sometimes the bullet does not hit them" was this.
		local direction = Types.normalize(Types.subVec3(TARGET, CAMERA))
		local previous = -1
		for _, distance in { 40, 60, 80, 120, 200, 500, 2000 } do
			local backdrop = Types.addVec3(CAMERA, Types.scaleVec3(direction, distance))
			local miss = missDistance(SHOULDER, backdrop, TARGET)
			expect(miss > previous).toBeTruthy()
			previous = miss
		end
	end)

	t.it("a backdrop close behind the target is nearly harmless", function()
		-- The reason this survived to now: in a tight room the bug is invisible.
		local direction = Types.normalize(Types.subVec3(TARGET, CAMERA))
		local backdrop = Types.addVec3(CAMERA, Types.scaleVec3(direction, 40))
		expect(missDistance(SHOULDER, backdrop, TARGET) < RADIUS).toBeTruthy()
	end)
end)
