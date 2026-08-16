--!strict
--[[ M2-3. Pathfinding over the assembly-time waypoint graph.

	Not `PathfindingService`: at 40+ entities, per-entity engine pathfinding is
	the tick budget. The graph here is tiny — one node per room plus one per
	doorway, so ~35 nodes for a full level — and a path over it is a few
	microseconds.

	A* with a euclidean heuristic, which is admissible because every edge cost
	is the straight-line distance between its endpoints, so the heuristic can
	never exceed the true remaining cost. The open set is a linear scan rather
	than a heap: at this node count the scan wins on constant factors and is
	much easier to read.

	Ties are broken by waypoint id so a path is reproducible. Two entities
	asked for the same route get the same answer, and a replayed run walks the
	same corridors.
]]

local Types = require("../Types")
local Assemble = require("./Assemble")

export type Layout = Assemble.Layout

local Path = {}

local function distance(a: Types.Vec3, b: Types.Vec3): number
	local dx, dz = a.x - b.x, a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

--- Shortest route between two waypoints, inclusive of both. Returns nil if the
--- graph does not connect them, which a validated layout never does — callers
--- still have to handle it, because a hand-built or partially loaded layout
--- can.
function Path.find(layout: Layout, fromId: number, toId: number): { number }?
	local waypoints = layout.waypoints
	local n = #waypoints
	if fromId < 1 or fromId > n or toId < 1 or toId > n then
		return nil
	end
	if fromId == toId then
		return { fromId }
	end

	local goal = waypoints[toId].at
	local gScore: { number } = table.create(n, math.huge)
	local fScore: { number } = table.create(n, math.huge)
	local cameFrom: { number } = table.create(n, 0)
	local closed: { boolean } = table.create(n, false)
	local open: { boolean } = table.create(n, false)

	gScore[fromId] = 0
	fScore[fromId] = distance(waypoints[fromId].at, goal)
	open[fromId] = true

	while true do
		-- Cheapest open node. Linear because n is ~35; a heap here would be
		-- more code and slower.
		local current = 0
		local best = math.huge
		for i = 1, n do
			if open[i] and fScore[i] < best then
				best = fScore[i]
				current = i
			end
		end
		if current == 0 then
			return nil -- open set exhausted: disconnected
		end
		if current == toId then
			break
		end

		open[current] = false
		closed[current] = true

		for _, neighbour in waypoints[current].links do
			if closed[neighbour] then
				continue
			end
			local tentative = gScore[current] + distance(waypoints[current].at, waypoints[neighbour].at)
			-- Strict improvement only, so equal-cost routes resolve to the
			-- first neighbour encountered, which is id order.
			if tentative < gScore[neighbour] then
				cameFrom[neighbour] = current
				gScore[neighbour] = tentative
				fScore[neighbour] = tentative + distance(waypoints[neighbour].at, goal)
				open[neighbour] = true
			end
		end
	end

	local reversed: { number } = { toId }
	local cursor = toId
	while cursor ~= fromId do
		cursor = cameFrom[cursor]
		if cursor == 0 then
			return nil
		end
		table.insert(reversed, cursor)
	end

	local out: { number } = {}
	for i = #reversed, 1, -1 do
		table.insert(out, reversed[i])
	end
	return out
end

--- Walked length of a waypoint path, in studs.
function Path.length(layout: Layout, path: { number }): number
	local total = 0
	for i = 2, #path do
		total += distance(layout.waypoints[path[i - 1]].at, layout.waypoints[path[i]].at)
	end
	return total
end

--- The room waypoint for the module containing `position`, or if the point is
--- outside every module, the nearest room waypoint. Entities and players live
--- at arbitrary positions; the graph does not.
function Path.nearestWaypoint(layout: Layout, position: Types.Vec3): number
	local bestId, bestDistance = 0, math.huge
	for _, m in layout.modules do
		local insideX = math.abs(position.x - m.at.x) <= m.width / 2
		local insideZ = math.abs(position.z - m.at.z) <= m.depth / 2
		if insideX and insideZ then
			return m.index -- room waypoint ids match module indices
		end
		local d = distance(position, m.at)
		if d < bestDistance or (d == bestDistance and m.index < bestId) then
			bestDistance = d
			bestId = m.index
		end
	end
	return bestId
end

--- Convenience for callers holding world positions rather than node ids: the
--- route from one point to another, as points to walk, with the true endpoints
--- at each end.
function Path.route(layout: Layout, from: Types.Vec3, to: Types.Vec3): { Types.Vec3 }?
	local path = Path.find(layout, Path.nearestWaypoint(layout, from), Path.nearestWaypoint(layout, to))
	if path == nil then
		return nil
	end

	local points: { Types.Vec3 } = { { x = from.x, y = from.y, z = from.z } }
	for _, id in path do
		local at = layout.waypoints[id].at
		table.insert(points, { x = at.x, y = at.y, z = at.z })
	end
	table.insert(points, { x = to.x, y = to.y, z = to.z })
	return points
end

return Path
