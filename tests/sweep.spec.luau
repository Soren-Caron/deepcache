--!strict
--[[ The melee sweep.

	The cases that matter are the ones that would let a player hit something
	they shouldn't: behind them, through a wall, out of reach, or twice in a
	row without waiting.
]]

local t = require("./framework")
local expect = t.expect

local Sweep = require("../src/shared/core/sim/Sweep")
local Types = require("../src/shared/core/Types")

local v3 = Types.vec3
local ORIGIN = v3(0, 0, 0)
--- Facing +Z, which is `atan2(0, 1) = 0`.
local FACING = 0

local P: Sweep.Params = {
	damage = 55,
	arcRadians = math.rad(120),
	radius = 12,
	cooldownSeconds = 3.5,
}

local function view(id: number, x: number, z: number, state: Types.EntityStateName?): Types.EntityView
	return { id = id, kind = "Skitter" :: any, pos = v3(x, 0, z), yaw = 0, state = state or "move", hpPct = 1 }
end

--- Every target the same size unless a test says otherwise.
local function radii(ids: { number }, r: number?): { [number]: number }
	local out = {}
	for _, id in ids do
		out[id] = r or 1.6
	end
	return out
end

t.describe("sim/Sweep cooldown", function()
	t.it("allows the first swing", function()
		expect(Sweep.ready(nil, 100, P.cooldownSeconds)).toBeTruthy()
	end)

	t.it("refuses a second swing inside the cooldown", function()
		local ok, reason = Sweep.ready(100, 102, P.cooldownSeconds)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("cooling_down")
	end)

	t.it("allows again once the cooldown elapses", function()
		expect(Sweep.ready(100, 103.5, P.cooldownSeconds)).toBeTruthy()
	end)

	t.it("does not grant a free swing on a backwards clock", function()
		-- A client-influenced clock running backwards must not read as a long
		-- wait. This is the same trap FireValidation's token bucket documents.
		local ok, reason = Sweep.ready(100, 90, P.cooldownSeconds)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("cooling_down")
	end)

	t.it("refuses a nonsense clock", function()
		expect(Sweep.ready(100, 0 / 0, P.cooldownSeconds)).toBeFalsy()
		expect(Sweep.ready(100, math.huge, P.cooldownSeconds)).toBeFalsy()
	end)

	t.it("reports time remaining for the HUD", function()
		expect(Sweep.remaining(100, 101, P.cooldownSeconds)).approx(2.5, 1e-9)
		expect(Sweep.remaining(100, 999, P.cooldownSeconds)).toEqual(0)
		expect(Sweep.remaining(nil, 5, P.cooldownSeconds)).toEqual(0)
	end)
end)

t.describe("sim/Sweep geometry", function()
	t.it("hits a target straight ahead", function()
		local hits = Sweep.resolve(ORIGIN, FACING, { view(1, 0, 8) }, radii({ 1 }), P)
		expect(#hits).toEqual(1)
		expect(hits[1].entityId).toEqual(1)
		expect(hits[1].damage).toEqual(P.damage)
	end)

	t.it("misses a target directly behind", function()
		-- The whole reason the arc is measured from the body: a sweep is not a
		-- 360-degree attack.
		expect(#Sweep.resolve(ORIGIN, FACING, { view(1, 0, -8) }, radii({ 1 }), P)).toEqual(0)
	end)

	t.it("hits several targets in one swing", function()
		-- The point of the ability: a swarm at melee range.
		local swarm = { view(1, 0, 6), view(2, 3, 5), view(3, -3, 5), view(4, 5, 4) }
		expect(#Sweep.resolve(ORIGIN, FACING, swarm, radii({ 1, 2, 3, 4 }), P)).toEqual(4)
	end)

	t.it("excludes a target just outside the arc", function()
		-- 120-degree arc: 60 either side. Place one at 75 degrees.
		local angle = math.rad(75)
		local target = view(1, math.sin(angle) * 8, math.cos(angle) * 8)
		expect(#Sweep.resolve(ORIGIN, FACING, { target }, radii({ 1 }), P)).toEqual(0)
	end)

	t.it("includes a target just inside the arc", function()
		local angle = math.rad(45)
		local target = view(1, math.sin(angle) * 8, math.cos(angle) * 8)
		expect(#Sweep.resolve(ORIGIN, FACING, { target }, radii({ 1 }), P)).toEqual(1)
	end)

	t.it("respects the facing rather than assuming +Z", function()
		-- Same target, player turned to face it.
		local target = view(1, 8, 0)
		expect(#Sweep.resolve(ORIGIN, FACING, { target }, radii({ 1 }), P)).toEqual(0)
		expect(#Sweep.resolve(ORIGIN, math.rad(90), { target }, radii({ 1 }), P)).toEqual(1)
	end)

    t.it("handles an arc straddling the yaw wrap-around", function()
		-- Facing just past +pi, with a target just under -pi. Naive subtraction
		-- makes these look almost a full turn apart.
		local target = view(1, math.sin(-3.1) * 6, math.cos(-3.1) * 6)
		expect(#Sweep.resolve(ORIGIN, 3.1, { target }, radii({ 1 }), P)).toEqual(1)
	end)

	t.it("misses a target beyond reach", function()
		expect(#Sweep.resolve(ORIGIN, FACING, { view(1, 0, 40) }, radii({ 1 }), P)).toEqual(0)
	end)

	t.it("measures reach to the hitbox surface, not the centre", function()
		-- A Warden is 4 studs of radius. Its centre at 15 studs is out of a
		-- 12-stud reach, but its body starts at 11. Measuring to centres would
		-- make big enemies harder to sweep than small ones, which is backwards.
		local warden = view(1, 0, 15)
		expect(#Sweep.resolve(ORIGIN, FACING, { warden }, { [1] = 4.0 }, P)).toEqual(1)
		expect(#Sweep.resolve(ORIGIN, FACING, { warden }, { [1] = 1.6 }, P)).toEqual(0)
	end)

	t.it("always catches something the player is standing inside", function()
		-- Bearing is meaningless at zero distance; it must not be decided by
		-- float noise.
		expect(#Sweep.resolve(ORIGIN, FACING, { view(1, 0, 0) }, radii({ 1 }), P)).toEqual(1)
	end)
end)

t.describe("sim/Sweep exclusions", function()
	t.it("skips corpses and spawning entities", function()
		local targets = { view(1, 0, 6, "death"), view(2, 1, 6, "spawn"), view(3, -1, 6) }
		local hits = Sweep.resolve(ORIGIN, FACING, targets, radii({ 1, 2, 3 }), P, { death = true, spawn = true })
		expect(#hits).toEqual(1)
		expect(hits[1].entityId).toEqual(3)
	end)

	t.it("ignores an entity with no known hitbox", function()
		expect(#Sweep.resolve(ORIGIN, FACING, { view(9, 0, 6) }, {}, P)).toEqual(0)
	end)

	t.it("stops at a wall when a visibility test is supplied", function()
		-- A sword does not reach through geometry either.
		local blocked = function() return false end
		expect(#Sweep.resolve(ORIGIN, FACING, { view(1, 0, 6) }, radii({ 1 }), P, nil, blocked)).toEqual(0)
	end)

	t.it("returns nothing when there is nothing in front", function()
		expect(#Sweep.resolve(ORIGIN, FACING, {}, {}, P)).toEqual(0)
	end)
end)

t.describe("sim/Sweep ordering", function()
	t.it("returns hits nearest first", function()
		local targets = { view(1, 0, 10), view(2, 0, 3), view(3, 0, 6) }
		local hits = Sweep.resolve(ORIGIN, FACING, targets, radii({ 1, 2, 3 }), P)
		expect(hits[1].entityId).toEqual(2)
		expect(hits[2].entityId).toEqual(3)
		expect(hits[3].entityId).toEqual(1)
	end)

	t.it("is deterministic when distances tie", function()
		-- Table iteration order is not stable, so ties break on id.
		local targets = { view(7, 3, 5), view(2, -3, 5) }
		local a = Sweep.resolve(ORIGIN, FACING, targets, radii({ 7, 2 }), P)
		local b = Sweep.resolve(ORIGIN, FACING, { targets[2], targets[1] }, radii({ 7, 2 }), P)
		expect(a[1].entityId).toEqual(b[1].entityId)
		expect(a[2].entityId).toEqual(b[2].entityId)
	end)
end)

t.describe("config/Melee", function()
	local Melee = require("../src/shared/config/Melee")

	t.it("is a usable arc rather than a full circle", function()
		expect(Melee.arcDegrees > 0 and Melee.arcDegrees < 360).toBeTruthy()
	end)

	t.it("reaches further than the enemies that close on you", function()
		-- A Skitter attacks at 4 studs and a Warden at 8. A sweep that could
		-- not reach them would never be worth pressing.
		local Enemies = require("../src/shared/config/Enemies")
		expect(Melee.radius > (Enemies :: any).Warden.atkRange).toBeTruthy()
	end)

	t.it("costs enough that it is not a primary weapon", function()
		expect(Melee.cooldownSeconds >= 2).toBeTruthy()
	end)
end)
