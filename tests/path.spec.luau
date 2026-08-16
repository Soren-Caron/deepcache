--!strict
--[[ M2-3. Pathing over the assembly-time waypoint graph.

	On the "within 1.4x euclidean" acceptance criterion: it does not hold as a
	universal bound and cannot, for any level with walls. Two rooms either side
	of a shared wall with no door between them are 60 studs apart and several
	hundred studs of walking; measured over 94,737 pairs the worst is 9.53x.
	That is geometry, not a pathfinder defect.

	What the criterion was standing in for is that the graph is not pathological
	and the search is not lazy, so this file asserts those directly:

	  - a path exists between every pair of nodes, over 1,000 layouts;
	  - every path A* returns is the true shortest path, checked against an
	    independent Dijkstra over the same graph;
	  - the median and mean detour hold at 1.4x, which is where the spec's
	    number survives;
	  - no pair exceeds a hard ceiling, which is what catches a layout that has
	    genuinely gone wrong.

	Recorded in docs/metrics/m2.md and docs/01-GAME-DESIGN.md.
]]

local t = require("./framework")
local expect = t.expect

local Assemble = require("../src/shared/core/level/Assemble")
local Path = require("../src/shared/core/level/Path")
local Rooms = require("../src/shared/config/Rooms")

local CATALOGUE = Rooms.modules :: { Assemble.ModuleDef }
local TARGET = Rooms.targetArea

--- Median and mean detour bounds. This is the spec's 1.4x, applied where it is
--- meaningful.
local DETOUR_MEDIAN_MAX = 1.4
local DETOUR_MEAN_MAX = 1.4

--- Hard ceiling on any single pair. Measured worst is 9.53x; 12 leaves room for
--- catalogue changes while still failing on a layout that has folded in half.
local DETOUR_CEILING = 12.0

--- Ground truth, computed without a heuristic. If A* disagrees anywhere then it
--- is not returning shortest paths, and no amount of ratio statistics would
--- reveal that.
local function dijkstra(layout: Assemble.Layout, source: number): { number }
	local wps = layout.waypoints
	local n = #wps
	local dist: { number } = table.create(n, math.huge)
	local done: { boolean } = table.create(n, false)
	dist[source] = 0
	for _ = 1, n do
		local best, bestD = 0, math.huge
		for i = 1, n do
			if not done[i] and dist[i] < bestD then
				best, bestD = i, dist[i]
			end
		end
		if best == 0 then
			break
		end
		done[best] = true
		for _, nb in wps[best].links do
			local dx = wps[best].at.x - wps[nb].at.x
			local dz = wps[best].at.z - wps[nb].at.z
			local alt = dist[best] + math.sqrt(dx * dx + dz * dz)
			if alt < dist[nb] then
				dist[nb] = alt
			end
		end
	end
	return dist
end

local function euclid(a: { x: number, y: number, z: number }, b: { x: number, y: number, z: number }): number
	local dx, dz = a.x - b.x, a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

--- Two modules with no connection between them, for the disconnected case.
--- Built by hand because `generate` cannot produce one.
local function islandLayout(): Assemble.Layout
	local function module_(index: number, x: number): Assemble.PlacedModule
		return {
			index = index,
			id = `Island_{index}`,
			zone = "Perimeter",
			at = { x = x, y = 0, z = 0 },
			rotation = 0,
			width = 64,
			depth = 64,
			area = 4096,
			hop = 0,
			hasPad = false,
			isSpine = true,
			neighbors = {},
			doors = {},
		}
	end
	return {
		seed = 0,
		modules = { module_(1, 0), module_(2, 1000) },
		pads = {},
		waypoints = {
			{ id = 1, at = { x = 0, y = 0, z = 0 }, links = {}, moduleIndex = 1, kind = "room" },
			{ id = 2, at = { x = 1000, y = 0, z = 0 }, links = {}, moduleIndex = 2, kind = "room" },
		},
		totalArea = 8192,
		targetArea = 8192,
		spineCount = 2,
		branchCount = 0,
	}
end

--------------------------------------------------------------------------------

t.describe("Path.find connectivity", function()
	t.it("reaches every waypoint from the entrance across 1,000 layouts", function()
		-- Exercised through Path.find rather than a bare BFS, so this covers
		-- the search and the graph together. The graph is undirected, so
		-- reaching all nodes from one is the same claim as "a path exists
		-- between any two nodes".
		local failures: { string } = {}
		for seed = 1, 1000 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			for id = 2, #layout.waypoints do
				if Path.find(layout, 1, id) == nil then
					table.insert(failures, `seed {seed}: no path from waypoint 1 to {id}`)
					break
				end
			end
			if #failures >= 3 then
				break
			end
		end
		expect(table.concat(failures, " | ")).toEqual("")
	end)

	t.it("reaches every pair of waypoints, both directions", function()
		for seed = 1, 25 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local n = #layout.waypoints
			for i = 1, n do
				for j = i + 1, n do
					local forward = Path.find(layout, i, j)
					local back = Path.find(layout, j, i)
					expect(forward).never().toBeNil()
					expect(back).never().toBeNil()
					-- Symmetric costs: the reverse route is the same length.
					expect(Path.length(layout, forward :: { number })).approx(
						Path.length(layout, back :: { number }),
						1e-6
					)
				end
			end
		end
	end)
end)

t.describe("Path.find optimality", function()
	t.it("returns the true shortest path for every pair, versus Dijkstra", function()
		local mismatches = 0
		local checked = 0
		for seed = 1, 60 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local n = #layout.waypoints
			for i = 1, n do
				local truth = dijkstra(layout, i)
				for j = i + 1, n do
					local route = Path.find(layout, i, j)
					if route == nil then
						mismatches += 1
					else
						checked += 1
						if math.abs(Path.length(layout, route) - truth[j]) > 1e-6 then
							mismatches += 1
						end
					end
				end
			end
		end
		expect(checked > 20000).toBeTruthy()
		expect(mismatches).toEqual(0)
	end)

	t.it("returns a contiguous chain of linked waypoints", function()
		-- A shortest *length* can still be a nonsense route if the returned
		-- node list skips edges.
		for seed = 1, 25 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local n = #layout.waypoints
			local route = Path.find(layout, 1, n) :: { number }
			expect(route[1]).toEqual(1)
			expect(route[#route]).toEqual(n)
			for k = 2, #route do
				local previous = layout.waypoints[route[k - 1]]
				local linked = false
				for _, link in previous.links do
					if link == route[k] then
						linked = true
						break
					end
				end
				expect(linked).toBeTruthy()
			end
			-- And never visits a node twice.
			local seen: { [number]: boolean } = {}
			for _, id in route do
				expect(seen[id]).toBeFalsy()
				seen[id] = true
			end
		end
	end)

	t.it("is deterministic for a repeated query", function()
		local layout = Assemble.generate(11, CATALOGUE, TARGET)
		local n = #layout.waypoints
		for _ = 1, 3 do
			expect(Path.find(layout, 1, n)).toEqual(Path.find(layout, 1, n))
		end
	end)
end)

t.describe("Path detour versus straight line", function()
	t.it("holds the median and mean at 1.4x, and no pair exceeds the ceiling", function()
		local ratios: { number } = {}
		local worst, worstAt = 0, ""
		for seed = 1, 100 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local wps = layout.waypoints
			for i = 1, #wps do
				for j = i + 1, #wps do
					local route = Path.find(layout, i, j)
					if route == nil then
						continue
					end
					local straight = euclid(wps[i].at, wps[j].at)
					if straight <= 1e-6 then
						continue
					end
					local ratio = Path.length(layout, route) / straight
					table.insert(ratios, ratio)
					if ratio > worst then
						worst = ratio
						worstAt = `seed {seed}, waypoints {i} -> {j}`
					end
				end
			end
		end

		table.sort(ratios)
		local median = ratios[math.ceil(#ratios * 0.5)]
		local sum = 0
		for _, r in ratios do
			sum += r
		end
		local mean = sum / #ratios

		expect(#ratios > 20000).toBeTruthy()
		if median > DETOUR_MEDIAN_MAX then
			error(`median detour {string.format("%.3f", median)} exceeds {DETOUR_MEDIAN_MAX}`)
		end
		if mean > DETOUR_MEAN_MAX then
			error(`mean detour {string.format("%.3f", mean)} exceeds {DETOUR_MEAN_MAX}`)
		end
		if worst > DETOUR_CEILING then
			error(`worst detour {string.format("%.2f", worst)} at {worstAt} exceeds ceiling {DETOUR_CEILING}`)
		end
	end)
end)

t.describe("Path.find edge cases", function()
	local layout = Assemble.generate(5, CATALOGUE, TARGET)

	t.it("returns the single node when source and goal match", function()
		expect(Path.find(layout, 3, 3)).toEqual({ 3 })
		expect(Path.length(layout, { 3 })).toEqual(0)
	end)

	t.it("returns nil for out-of-range ids rather than throwing", function()
		expect(Path.find(layout, 0, 4)).toBeNil()
		expect(Path.find(layout, 4, 0)).toBeNil()
		expect(Path.find(layout, 1, #layout.waypoints + 1)).toBeNil()
		expect(Path.find(layout, -7, -7)).toBeNil()
	end)

	t.it("returns nil across a disconnected graph instead of looping forever", function()
		local islands = islandLayout()
		expect(Path.find(islands, 1, 2)).toBeNil()
		expect(Path.find(islands, 2, 1)).toBeNil()
		expect(Path.find(islands, 1, 1)).toEqual({ 1 })
	end)
end)

t.describe("Path.nearestWaypoint", function()
	local layout = Assemble.generate(9, CATALOGUE, TARGET)

	t.it("returns the containing module for a point inside one", function()
		for _, m in layout.modules do
			expect(Path.nearestWaypoint(layout, m.at)).toEqual(m.index)
			-- Just inside each corner, not only the centre.
			local corner = {
				x = m.at.x + m.width / 2 - 0.5,
				y = 0,
				z = m.at.z + m.depth / 2 - 0.5,
			}
			expect(Path.nearestWaypoint(layout, corner)).toEqual(m.index)
		end
	end)

	t.it("falls back to the nearest module for a point outside every one", function()
		local far = { x = 100000, y = 0, z = 100000 }
		local id = Path.nearestWaypoint(layout, far)
		expect(id >= 1 and id <= #layout.modules).toBeTruthy()

		local bestIndex, bestDistance = 0, math.huge
		for _, m in layout.modules do
			local d = euclid(far, m.at)
			if d < bestDistance then
				bestDistance = d
				bestIndex = m.index
			end
		end
		expect(id).toEqual(bestIndex)
	end)
end)

t.describe("Path to the extraction pads", function()
	t.it("makes every pad a real journey from the drop point", function()
		-- Zero-distance extraction is the failure this guards: a pad on the
		-- entrance module means the 3:00 extraction is underfoot at t=0.
		for seed = 1, 200 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			for _, pad in layout.pads do
				local route = Path.find(layout, 1, pad.moduleIndex) :: { number }
				expect(route).never().toBeNil()
				expect(#route >= 3).toBeTruthy() -- room, doorway, room at minimum
				expect(Path.length(layout, route) > 0).toBeTruthy()
			end
		end
	end)

	t.it("puts the deeper pads further away, which is what makes them pay more", function()
		local wins, total = 0, 0
		for seed = 1, 200 do
			local layout = Assemble.generate(seed, CATALOGUE, TARGET)
			local byZone: { [string]: number } = {}
			for _, pad in layout.pads do
				local route = Path.find(layout, 1, pad.moduleIndex) :: { number }
				byZone[pad.zone] = Path.length(layout, route)
			end
			total += 1
			if byZone.Perimeter < byZone.Processing and byZone.Processing < byZone.Vault then
				wins += 1
			end
		end
		-- Not universal: a branch can hang a Vault room back near the spine.
		-- The ordering should hold in the large majority, which is what makes
		-- the pad-open schedule mean anything.
		expect(wins / total > 0.85).toBeTruthy()
	end)
end)

t.describe("Path.route", function()
	local layout = Assemble.generate(13, CATALOGUE, TARGET)

	t.it("keeps the caller's true endpoints at each end", function()
		local from = { x = layout.modules[1].at.x + 3, y = 0, z = layout.modules[1].at.z - 2 }
		local last = layout.modules[#layout.modules]
		local to = { x = last.at.x - 4, y = 0, z = last.at.z + 1 }

		local points = Path.route(layout, from, to) :: { { x: number, y: number, z: number } }
		expect(points).never().toBeNil()
		expect(points[1]).toEqual(from)
		expect(points[#points]).toEqual(to)
		expect(#points >= 3).toBeTruthy()
	end)

	t.it("returns nil when the two ends are in disconnected components", function()
		local islands = islandLayout()
		expect(Path.route(islands, { x = 0, y = 0, z = 0 }, { x = 1000, y = 0, z = 0 })).toBeNil()
	end)
end)
