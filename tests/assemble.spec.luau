--!strict
--[[ M2-1. Level assembly.

	The 1,000-seed sweep is the headline test, but on its own it only proves
	`validate` agrees with `generate`. If both share a blind spot the suite
	stays green while every level is broken. So this file also:

	  - re-derives the constraints from the placed geometry independently of
	    `validate`, on a sample of layouts, and
	  - corrupts known-good layouts and asserts `validate` rejects each one,
	    which is what proves it is a real check rather than a rubber stamp.
]]

local t = require("./framework")
local expect = t.expect

local Assemble = require("../src/shared/core/level/Assemble")
local Rooms = require("../src/shared/config/Rooms")

local CATALOGUE = Rooms.modules :: { Assemble.ModuleDef }
local TARGET = Rooms.targetArea

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out: { [any]: any } = {}
	for k, v in pairs(value :: any) do
		out[k] = deepCopy(v)
	end
	return (out :: any) :: T
end

--- A minimal catalogue that satisfies every precondition: 3 shared modules
--- plus one pad module per zone, all 64x64 so area maths stays obvious.
local function makeCatalogue(): { Assemble.ModuleDef }
	local all: { any } = { "Perimeter", "Processing", "Vault" }
	return {
		{
			id = "Hall_A", zones = all, width = 64, depth = 64, hasPad = false,
			connectors = { { face = "N", size = "large" }, { face = "S", size = "large" } },
		},
		{
			id = "Hall_B", zones = all, width = 64, depth = 64, hasPad = false,
			connectors = {
				{ face = "N", size = "large" }, { face = "S", size = "large" },
				{ face = "E", size = "large" }, { face = "W", size = "large" },
			},
		},
		{
			id = "Hall_C", zones = all, width = 64, depth = 64, hasPad = false,
			connectors = {
				{ face = "N", size = "large" }, { face = "S", size = "large" },
				{ face = "E", size = "large" },
			},
		},
		{
			id = "Pad_Perimeter", zones = { "Perimeter" } :: any, width = 64, depth = 64, hasPad = true,
			connectors = {
				{ face = "N", size = "large" }, { face = "S", size = "large" },
				{ face = "W", size = "large" },
			},
		},
		{
			id = "Pad_Processing", zones = { "Processing" } :: any, width = 64, depth = 64, hasPad = true,
			connectors = {
				{ face = "N", size = "large" }, { face = "S", size = "large" },
				{ face = "W", size = "large" },
			},
		},
		{
			id = "Pad_Vault", zones = { "Vault" } :: any, width = 64, depth = 64, hasPad = true,
			connectors = {
				{ face = "N", size = "large" }, { face = "S", size = "large" },
				{ face = "W", size = "large" },
			},
		},
	}
end

local SIMPLE_TARGET = 4096 * 15

--- Graph distance between two modules, computed here rather than read off the
--- layout, so the no-repeat assertion does not trust the generator's bookkeeping.
local function hopDistances(layout: Assemble.Layout, from: number): { number }
	local dist: { number } = table.create(#layout.modules, -1)
	dist[from] = 0
	local queue = { from }
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		for _, nb in layout.modules[cur].neighbors do
			if dist[nb] == -1 then
				dist[nb] = dist[cur] + 1
				table.insert(queue, nb)
			end
		end
	end
	return dist
end

--------------------------------------------------------------------------------

t.describe("Assemble.generate", function()
	t.it("produces a valid layout for 1,000 consecutive seeds", function()
		local failures: { string } = {}
		for seed = 1, 1000 do
			local ok, result = pcall(function()
				return Assemble.generate(seed, CATALOGUE, TARGET)
			end)
			if not ok then
				table.insert(failures, `seed {seed} threw: {tostring(result)}`)
			else
				local valid, why = Assemble.validate(result :: Assemble.Layout, TARGET)
				if not valid then
					table.insert(failures, `seed {seed}: {tostring(why)}`)
				end
			end
			if #failures >= 3 then
				break
			end
		end
		expect(table.concat(failures, " | ")).toEqual("")
	end)

	t.it("is deterministic: the same seed reproduces the layout exactly", function()
		for _, seed in { 1, 42, 977 } do
			local a = Assemble.generate(seed, CATALOGUE, TARGET)
			local b = Assemble.generate(seed, CATALOGUE, TARGET)
			expect(a).toEqual(b)
		end
	end)

	t.it("different seeds produce different layouts", function()
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for seed = 1, 60 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local parts: { string } = {}
			for _, m in layout.modules do
				table.insert(parts, `{m.id}@{m.at.x},{m.at.z}`)
			end
			local key = table.concat(parts, "|")
			if not seen[key] then
				seen[key] = true
				distinct += 1
			end
		end
		-- Not a determinism test in disguise: a generator that ignored the seed
		-- would score 1 here, and one that only varied module count would score
		-- a handful.
		expect(distinct > 40).toBeTruthy()
	end)

	t.it("places exactly three pads, one per zone, all reachable", function()
		for seed = 1, 50 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local byZone: { [string]: number } = {}
			local padIndices: { number } = {}
			for _, m in layout.modules do
				if m.hasPad then
					byZone[m.zone] = (byZone[m.zone] or 0) + 1
					table.insert(padIndices, m.index)
				end
			end
			expect(#padIndices).toEqual(3)
			expect(byZone.Perimeter).toEqual(1)
			expect(byZone.Processing).toEqual(1)
			expect(byZone.Vault).toEqual(1)

			local dist = hopDistances(layout, 1)
			for _, index in padIndices do
				expect(dist[index] >= 0).toBeTruthy()
			end
			expect(#layout.pads).toEqual(3)
			-- Ordered Perimeter -> Processing -> Vault, which is the order the
			-- pads open in, so consumers can index by depth.
			expect(layout.pads[1].zone).toEqual("Perimeter")
			expect(layout.pads[2].zone).toEqual("Processing")
			expect(layout.pads[3].zone).toEqual("Vault")
		end
	end)

	t.it("never repeats a module id within two hops", function()
		for seed = 1, 50 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			for i = 1, #layout.modules do
				local dist = hopDistances(layout, i)
				for j = 1, #layout.modules do
					if i ~= j and dist[j] >= 0 and dist[j] <= Assemble.NO_REPEAT_WITHIN_HOPS then
						expect(layout.modules[i].id).never().toEqual(layout.modules[j].id)
					end
				end
			end
		end
	end)

	t.it("never overlaps two module footprints", function()
		for seed = 1, 50 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local n = #layout.modules
			for i = 1, n do
				for j = i + 1, n do
					local a, b = layout.modules[i], layout.modules[j]
					local xGap = math.abs(a.at.x - b.at.x) - (a.width + b.width) / 2
					local zGap = math.abs(a.at.z - b.at.z) - (a.depth + b.depth) / 2
					-- Touching (gap == 0) is how connected modules sit; only
					-- interpenetration on BOTH axes is an overlap.
					expect(xGap > -1e-6 or zGap > -1e-6).toBeTruthy()
				end
			end
		end
	end)

	t.it("joins every connection on opposite faces of equal size at one point", function()
		for seed = 1, 50 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local opposite = { N = "S", S = "N", E = "W", W = "E" }
			for i, m in layout.modules do
				for _, door in m.doors do
					if door.toIndex == nil then
						continue
					end
					local other = layout.modules[door.toIndex]
					local back = nil
					for _, candidate in other.doors do
						if candidate.toIndex == i then
							back = candidate
						end
					end
					expect(back).never().toBeNil()
					local backDoor = back :: Assemble.Door
					expect(backDoor.face).toEqual(opposite[door.face])
					expect(backDoor.size).toEqual(door.size)
					expect(backDoor.at.x).approx(door.at.x, 1e-6)
					expect(backDoor.at.z).approx(door.at.z, 1e-6)
				end
			end
		end
	end)

	t.it("keeps total area within tolerance and counts within documented ranges", function()
		for seed = 1, 200 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local total = 0
			for _, m in layout.modules do
				total += m.area
			end
			expect(total).toEqual(layout.totalArea)
			expect(math.abs(total - TARGET) <= TARGET * Assemble.AREA_TOLERANCE).toBeTruthy()

			expect(layout.spineCount >= Assemble.SPINE_MIN).toBeTruthy()
			expect(layout.spineCount <= Assemble.SPINE_MAX).toBeTruthy()
			expect(layout.branchCount >= Assemble.BRANCH_MIN).toBeTruthy()
			expect(layout.branchCount <= Assemble.BRANCH_MAX).toBeTruthy()
			expect(#layout.modules).toEqual(layout.spineCount + layout.branchCount)
		end
	end)

	t.it("orders zones by depth along the spine", function()
		for seed = 1, 50 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local depth = { Perimeter = 1, Processing = 2, Vault = 3 }
			local previous = 0
			for _, m in layout.modules do
				if m.isSpine then
					local d = depth[m.zone]
					-- Monotonic, and never skipping a band.
					expect(d >= previous).toBeTruthy()
					expect(d <= previous + 1).toBeTruthy()
					previous = d
				end
			end
			expect(previous).toEqual(3)
		end
	end)
end)

t.describe("Assemble.generate rejects a broken catalogue", function()
	local function expectThrows(mutate: (cat: { any }) -> (), substring: string)
		local catalogue = makeCatalogue() :: any
		mutate(catalogue)
		expect(function()
			Assemble.generate(1, catalogue, SIMPLE_TARGET)
		end).toThrow(substring)
	end

	t.it("accepts the unmutated control catalogue", function()
		-- Without this the failure cases below could all be passing for the
		-- wrong reason.
		local layout = Assemble.generate(1, makeCatalogue(), SIMPLE_TARGET)
		local ok, why = Assemble.validate(layout, SIMPLE_TARGET)
		expect(why).toBeNil()
		expect(ok).toBeTruthy()
	end)

	t.it("an empty catalogue", function()
		expect(function()
			Assemble.generate(1, {}, SIMPLE_TARGET)
		end).toThrow("catalogue is empty")
	end)

	t.it("a module with too few connectors", function()
		expectThrows(function(cat)
			cat[1].connectors = { { face = "N", size = "large" } }
		end, "expected 2 to 4")
	end)

	t.it("a module with too many connectors", function()
		expectThrows(function(cat)
			table.insert(cat[1].connectors, { face = "E", size = "large" })
			table.insert(cat[1].connectors, { face = "W", size = "large" })
			table.insert(cat[1].connectors, { face = "N", size = "small" })
		end, "expected 2 to 4")
	end)

	t.it("two connectors on the same face", function()
		expectThrows(function(cat)
			cat[1].connectors = {
				{ face = "N", size = "large" },
				{ face = "N", size = "small" },
			}
		end, "two connectors on face N")
	end)

	t.it("a duplicate module id", function()
		expectThrows(function(cat)
			cat[2].id = cat[1].id
		end, "duplicate module id")
	end)

	t.it("an unknown face tag", function()
		expectThrows(function(cat)
			cat[1].connectors[1].face = "UP"
		end, "unknown face")
	end)

	t.it("an unknown connector size", function()
		expectThrows(function(cat)
			cat[1].connectors[1].size = "medium"
		end, "unknown size")
	end)

	t.it("a non-positive extent", function()
		expectThrows(function(cat)
			cat[1].width = 0
		end, "non-positive extents")
	end)

	t.it("a zone with no pad module", function()
		expectThrows(function(cat)
			cat[6].hasPad = false -- Pad_Vault
		end, "no module with a pad serves zone Vault")
	end)

	t.it("a zone with too few modules to avoid repeating", function()
		expectThrows(function(cat)
			-- Strip the shared halls out of Vault, leaving only the pad room.
			for i = 1, 3 do
				cat[i].zones = { "Perimeter", "Processing" }
			end
		end, "at least 3 are needed")
	end)

	t.it("a module serving no zone", function()
		expectThrows(function(cat)
			cat[1].zones = {}
		end, "serves no zone")
	end)
end)

t.describe("Assemble.generate rejects an unreachable area target", function()
	t.it("a target far larger than the catalogue can fill", function()
		expect(function()
			Assemble.generate(1, CATALOGUE, 5000000)
		end).toThrow("no layout within")
	end)

	t.it("a target far smaller than the smallest legal layout", function()
		expect(function()
			Assemble.generate(1, CATALOGUE, 100)
		end).toThrow("no layout within")
	end)

	t.it("a non-positive target", function()
		expect(function()
			Assemble.generate(1, CATALOGUE, 0)
		end).toThrow("targetArea must be positive")
	end)
end)

t.describe("Assemble.validate rejects corrupted layouts", function()
	local function corrupted(mutate: (layout: Assemble.Layout) -> ()): (boolean, string?)
		local layout = deepCopy(Assemble.generate(7, CATALOGUE, TARGET))
		mutate(layout)
		return Assemble.validate(layout, TARGET)
	end

	t.it("overlapping modules", function()
		local ok, why = corrupted(function(layout)
			-- Drop module 3 on top of module 1.
			layout.modules[3].at = { x = layout.modules[1].at.x, y = 0, z = layout.modules[1].at.z }
		end)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "overlap", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("a one-way connection", function()
		local ok, why = corrupted(function(layout)
			for _, door in layout.modules[2].doors do
				if door.toIndex ~= nil then
					door.toIndex = nil
					break
				end
			end
		end)
		expect(ok).toBeFalsy()
		expect(why).never().toBeNil()
	end)

	t.it("a module cut off from the entrance", function()
		local ok, why = corrupted(function(layout)
			local last = layout.modules[#layout.modules]
			for _, nb in last.neighbors do
				local neighbour = layout.modules[nb]
				for i = #neighbour.neighbors, 1, -1 do
					if neighbour.neighbors[i] == last.index then
						table.remove(neighbour.neighbors, i)
					end
				end
			end
			last.neighbors = {}
		end)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "unreachable", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("a missing pad", function()
		local ok, why = corrupted(function(layout)
			layout.modules[layout.pads[3].moduleIndex].hasPad = false
		end)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "pads", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("an area that does not match the footprint", function()
		local ok, why = corrupted(function(layout)
			layout.modules[1].area += 1000
		end)
		expect(ok).toBeFalsy()
		expect(why).never().toBeNil()
	end)

	t.it("a total area outside tolerance", function()
		local layout = deepCopy(Assemble.generate(7, CATALOGUE, TARGET))
		local ok, why = Assemble.validate(layout, TARGET * 3)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "off target", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("a repeated module id brought within two hops", function()
		local ok, why = corrupted(function(layout)
			-- Force a neighbour to share its parent's id.
			local a = layout.modules[1]
			layout.modules[a.neighbors[1]].id = a.id
		end)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "repeats within", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("a hop count that disagrees with the graph", function()
		local ok, why = corrupted(function(layout)
			layout.modules[#layout.modules].hop += 5
		end)
		expect(ok).toBeFalsy()
		expect(string.find(tostring(why), "hop", 1, true) ~= nil).toBeTruthy()
	end)

	t.it("a severed nav graph link", function()
		local ok, why = corrupted(function(layout)
			layout.waypoints[#layout.waypoints].links = {}
		end)
		expect(ok).toBeFalsy()
		expect(why).never().toBeNil()
	end)
end)

t.describe("Assemble.buildNavGraph", function()
	t.it("gives every module exactly one room waypoint", function()
		for seed = 1, 25 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local rooms = 0
			local seen: { [number]: boolean } = {}
			for _, wp in layout.waypoints do
				if wp.kind == "room" then
					rooms += 1
					expect(seen[wp.moduleIndex]).toBeFalsy()
					seen[wp.moduleIndex] = true
					local m = layout.modules[wp.moduleIndex]
					expect(wp.at.x).approx(m.at.x, 1e-9)
					expect(wp.at.z).approx(m.at.z, 1e-9)
				end
			end
			expect(rooms).toEqual(#layout.modules)
		end
	end)

	t.it("puts one door waypoint on each connection, linking exactly two rooms", function()
		for seed = 1, 25 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local connections = 0
			for _, m in layout.modules do
				for _, door in m.doors do
					if door.toIndex ~= nil and door.toIndex > m.index then
						connections += 1
					end
				end
			end
			local doors = 0
			for _, wp in layout.waypoints do
				if wp.kind == "door" then
					doors += 1
					expect(#wp.links).toEqual(2)
					for _, link in wp.links do
						expect(layout.waypoints[link].kind).toEqual("room")
					end
				end
			end
			expect(doors).toEqual(connections)
			-- A tree: every module but the entrance is entered exactly once.
			expect(connections).toEqual(#layout.modules - 1)
		end
	end)

	t.it("connects every waypoint to every other", function()
		for seed = 1, 25 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local seen: { [number]: boolean } = { [1] = true }
			local queue = { 1 }
			local head, reached = 1, 1
			while head <= #queue do
				local cur = queue[head]
				head += 1
				for _, link in layout.waypoints[cur].links do
					if not seen[link] then
						seen[link] = true
						reached += 1
						table.insert(queue, link)
					end
				end
			end
			expect(reached).toEqual(#layout.waypoints)
		end
	end)

	t.it("routes between rooms through doorways, never room to room directly", function()
		local layout = Assemble.generate(3, CATALOGUE, TARGET)
		for _, wp in layout.waypoints do
			if wp.kind == "room" then
				for _, link in wp.links do
					expect(layout.waypoints[link].kind).toEqual("door")
				end
			end
		end
	end)
end)
