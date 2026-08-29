--!strict
--[[ Set dressing placement.

	The constraints that matter are the ones that would break gameplay rather
	than look wrong: a prop in open floor is something an entity can wedge
	against, and a prop in a doorway is a pathing failure that reads as a level
	generation bug.
]]

local t = require("./framework")
local expect = t.expect

local Decor = require("../src/shared/core/level/Decor")

local P: Decor.Params = {
	bandWidth = 7,
	doorClearance = 14,
	studsPerProp = 220,
	maxProps = 14,
	studsPerLight = 1100,
	maxLights = 9,
	minDimension = 20,
}

local INSET = 2

local function room(width: number, depth: number, doors: { string }?): Decor.Room
	return { x = 0, z = 0, width = width, depth = depth, doorFaces = doors or {} }
end

t.describe("level/Decor props", function()
	t.it("places props in a room with room to spare", function()
		expect(#Decor.props(room(64, 64), 1, INSET, P, { "crate" }) > 0).toBeTruthy()
	end)

	t.it("keeps every prop inside the walls", function()
		local r = room(64, 48, { "N" })
		for _, p in Decor.props(r, 7, INSET, P, { "crate", "barrel" }) do
			expect(math.abs(p.x) <= r.width / 2 - INSET + 1e-6).toBeTruthy()
			expect(math.abs(p.z) <= r.depth / 2 - INSET + 1e-6).toBeTruthy()
		end
	end)

	t.it("leaves the middle of the room clear", function()
		-- The constraint entities depend on: spawn points and steering both use
		-- the interior, and nothing steers around an obstacle it cannot see.
		local r = room(80, 80)
		local halfW = r.width / 2 - INSET
		local halfD = r.depth / 2 - INSET
		for _, p in Decor.props(r, 3, INSET, P, { "crate" }) do
			local inBand = math.abs(p.x) >= halfW - P.bandWidth or math.abs(p.z) >= halfD - P.bandWidth
			expect(inBand).toBeTruthy()
		end
	end)

	t.it("keeps clear of every doorway", function()
		local r = room(96, 96, { "N", "S", "E", "W" })
		for _, p in Decor.props(r, 11, INSET, P, { "crate" }) do
			for _, face in r.doorFaces do
				local dx = if face == "E" then r.width / 2 elseif face == "W" then -r.width / 2 else 0
				local dz = if face == "N" then r.depth / 2 elseif face == "S" then -r.depth / 2 else 0
				local blocking = math.abs(p.x - dx) < P.doorClearance and math.abs(p.z - dz) < P.doorClearance
				expect(blocking).toBeFalsy()
			end
		end
	end)

	t.it("is deterministic for a seed", function()
		local a = Decor.props(room(64, 64, { "N" }), 42, INSET, P, { "crate", "barrel" })
		local b = Decor.props(room(64, 64, { "N" }), 42, INSET, P, { "crate", "barrel" })
		expect(#a).toEqual(#b)
		for index, p in a do
			expect(p.x).approx(b[index].x, 1e-9)
			expect(p.z).approx(b[index].z, 1e-9)
			expect(p.kind).toEqual(b[index].kind)
		end
	end)

	t.it("differs between seeds", function()
		local a = Decor.props(room(64, 64), 1, INSET, P, { "crate" })
		local b = Decor.props(room(64, 64), 2, INSET, P, { "crate" })
		local same = #a == #b
		if same then
			for index, p in a do
				if math.abs(p.x - b[index].x) > 1e-6 then
					same = false
					break
				end
			end
		end
		expect(same).toBeFalsy()
	end)

	t.it("skips rooms too small to dress", function()
		expect(#Decor.props(room(12, 12), 1, INSET, P, { "crate" })).toEqual(0)
	end)

	t.it("respects the cap", function()
		expect(#Decor.props(room(400, 400), 1, INSET, P, { "crate" }) <= P.maxProps).toBeTruthy()
	end)

	t.it("terminates when doorways eat the whole band", function()
		-- A small room ringed by doors may legitimately fit nothing. The
		-- placement loop is bounded rather than "retry until the quota is met",
		-- which would hang here.
		local tight: Decor.Params = table.clone(P)
		tight.doorClearance = 200
		expect(#Decor.props(room(64, 64, { "N", "S", "E", "W" }), 5, INSET, tight, { "crate" })).toEqual(0)
	end)

	t.it("returns nothing when given no kinds", function()
		expect(#Decor.props(room(64, 64), 1, INSET, P, {})).toEqual(0)
	end)

	t.it("varies scale and yaw", function()
		local props = Decor.props(room(96, 96), 9, INSET, P, { "crate" })
		local sawDifferentScale = false
		for index = 2, #props do
			if math.abs(props[index].scale - props[1].scale) > 1e-6 then
				sawDifferentScale = true
				break
			end
		end
		expect(#props > 1 and sawDifferentScale).toBeTruthy()
	end)
end)

t.describe("level/Decor ceiling lights", function()
	t.it("always lights a room at least once", function()
		-- A room with no fixture is a black box once it has a ceiling.
		expect(#Decor.ceilingLights(room(16, 16), P)).toEqual(1)
	end)

	t.it("scales with area", function()
		local small = #Decor.ceilingLights(room(32, 32), P)
		local large = #Decor.ceilingLights(room(128, 96), P)
		expect(large > small).toBeTruthy()
	end)

	t.it("respects the cap", function()
		expect(#Decor.ceilingLights(room(500, 500), P) <= P.maxLights).toBeTruthy()
	end)

	t.it("keeps fixtures inside the room", function()
		local r = room(128, 96)
		for _, l in Decor.ceilingLights(r, P) do
			expect(math.abs(l.x) < r.width / 2).toBeTruthy()
			expect(math.abs(l.z) < r.depth / 2).toBeTruthy()
		end
	end)

	t.it("centres a single fixture", function()
		local l = Decor.ceilingLights(room(20, 20), P)[1]
		expect(l.x).approx(0, 1e-9)
		expect(l.z).approx(0, 1e-9)
	end)
end)

t.describe("level/Decor pilasters", function()
	t.it("gives none to a short wall", function()
		expect(#Decor.pilasterOffsets(20, 24)).toEqual(0)
	end)

	t.it("divides a long wall", function()
		expect(#Decor.pilasterOffsets(96, 24) > 0).toBeTruthy()
	end)

	t.it("never lands on a corner", function()
		local span = 96
		for _, offset in Decor.pilasterOffsets(span, 24) do
			expect(math.abs(offset) < span / 2 - 1e-6).toBeTruthy()
		end
	end)

	t.it("spaces them evenly", function()
		local offsets = Decor.pilasterOffsets(120, 24)
		expect(#offsets >= 2).toBeTruthy()
		local gap = offsets[2] - offsets[1]
		for index = 3, #offsets do
			expect(offsets[index] - offsets[index - 1]).approx(gap, 1e-9)
		end
	end)
end)
