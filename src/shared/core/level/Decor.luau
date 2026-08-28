--!strict
--[[ Where the set dressing goes.

	Rooms assembled by `Assemble` are sealed boxes: a floor, four walls, a
	doorway per used connector. Correct, and completely empty -- from above the
	level reads as a dollhouse of open pens, and from inside every room is the
	same room.

	This decides *where* things go. `LevelService` decides what they are made
	of. Splitting it that way is what makes the interesting part testable: the
	rules below are all spatial constraints, and every one of them is a bug
	that would otherwise only show up by walking into it.

	Three constraints, and they are the whole design:

	  - **Nothing in the middle.** Enemy and loot spawn points live in the
	    interior, and entities steer by seek-and-separate rather than a
	    navmesh, so an obstacle in open floor is something they can wedge
	    against. Props hug the walls, in a band whose width is authored.
	  - **Nothing near a doorway.** A crate half-blocking the only route
	    between two modules is a pathing failure that looks like a level
	    generation bug.
	  - **Deterministic.** Same seed, same room, same props. A replayed run has
	    to look like the run it replays, and a screenshot in a bug report has
	    to be reproducible.

	Ceiling lights are here for the same reason: their spacing is a rule about
	the room's dimensions, not about Roblox.
]]

local Rng = require("../util/Rng")

local Decor = {}

export type Placement = {
	kind: string,
	x: number,
	z: number,
	--- Radians. Props are boxes, so a little rotation stops a row of them
	--- reading as a manufactured line.
	yaw: number,
	--- Multiplier on the kind's authored size.
	scale: number,
}

export type Params = {
	--- How far from the wall a prop may sit, measured from the inner face.
	bandWidth: number,
	--- Clearance kept around the centre of every used doorway.
	doorClearance: number,
	--- Roughly one prop per this much wall-band area.
	studsPerProp: number,
	maxProps: number,
	--- Ceiling fixtures: roughly one per this much floor area.
	studsPerLight: number,
	maxLights: number,
	--- Smallest room dimension that still gets props. Below this the band
	--- overlaps itself and everything lands in the middle anyway.
	minDimension: number,
}

export type Room = {
	x: number,
	z: number,
	width: number,
	depth: number,
	--- Faces with a doorway: "N", "S", "E", "W".
	doorFaces: { string },
}

--- Centre of the doorway on `face`, which `Assemble` guarantees is the centre
--- of that face.
local function doorCentre(room: Room, face: string): (number, number)
	local halfW, halfD = room.width / 2, room.depth / 2
	if face == "N" then
		return room.x, room.z + halfD
	elseif face == "S" then
		return room.x, room.z - halfD
	elseif face == "E" then
		return room.x + halfW, room.z
	end
	return room.x - halfW, room.z
end

--- Is `(x, z)` clear of every doorway?
local function clearOfDoors(room: Room, x: number, z: number, clearance: number): boolean
	for _, face in room.doorFaces do
		local dx, dz = doorCentre(room, face)
		if math.abs(x - dx) < clearance and math.abs(z - dz) < clearance then
			return false
		end
	end
	return true
end

--- Props for one room, hugging the walls.
---
--- `inset` is how far the inner wall face sits from the module bounds, so a
--- prop is never placed inside the wall it leans against.
function Decor.props(room: Room, seed: number, inset: number, params: Params, kinds: { string }): { Placement }
	if room.width < params.minDimension or room.depth < params.minDimension then
		return {}
	end
	if #kinds == 0 then
		return {}
	end

	local halfW = room.width / 2 - inset
	local halfD = room.depth / 2 - inset
	local innerW = math.max(0, halfW * 2 - params.bandWidth * 2)
	local innerD = math.max(0, halfD * 2 - params.bandWidth * 2)
	-- Band area is the full floor minus the clear middle.
	local bandArea = math.max(0, halfW * 2 * halfD * 2 - innerW * innerD)
	local wanted = math.clamp(math.floor(bandArea / params.studsPerProp + 0.5), 0, params.maxProps)
	if wanted == 0 then
		return {}
	end

	local rng = Rng.new(seed)
	local out: { Placement } = {}
	-- Bounded attempts, not "until we have enough": a small room whose doorways
	-- eat most of its band legitimately fits fewer props than the area
	-- suggests, and looping until the quota was met would hang on it.
	local attempts = wanted * 6
	for _ = 1, attempts do
		if #out >= wanted then
			break
		end

		-- Pick a wall, then a point along it inside the band.
		local side = Rng.nextInt(rng) % 4
		local x, z
		if side == 0 then -- N
			x = Rng.nextRange(rng, room.x - halfW, room.x + halfW)
			z = Rng.nextRange(rng, room.z + halfD - params.bandWidth, room.z + halfD)
		elseif side == 1 then -- S
			x = Rng.nextRange(rng, room.x - halfW, room.x + halfW)
			z = Rng.nextRange(rng, room.z - halfD, room.z - halfD + params.bandWidth)
		elseif side == 2 then -- E
			x = Rng.nextRange(rng, room.x + halfW - params.bandWidth, room.x + halfW)
			z = Rng.nextRange(rng, room.z - halfD, room.z + halfD)
		else -- W
			x = Rng.nextRange(rng, room.x - halfW, room.x - halfW + params.bandWidth)
			z = Rng.nextRange(rng, room.z - halfD, room.z + halfD)
		end

		if clearOfDoors(room, x, z, params.doorClearance) then
			table.insert(out, {
				kind = Rng.pick(rng, kinds),
				x = x,
				z = z,
				yaw = Rng.nextRange(rng, -0.25, 0.25),
				scale = Rng.nextRange(rng, 0.85, 1.25),
			})
		end
	end

	return out
end

--- Ceiling fixture positions, on the most square grid that holds the wanted
--- count. Same layout rule as spawn points, for the dull reason that a room
--- lit on a different grid from the one it spawns things on looks wrong in a
--- way nobody can name.
function Decor.ceilingLights(room: Room, params: Params): { { x: number, z: number } }
	local area = room.width * room.depth
	local wanted = math.clamp(math.floor(area / params.studsPerLight + 0.5), 1, params.maxLights)
	local columns = math.max(1, math.ceil(math.sqrt(wanted)))
	local rows = math.max(1, math.ceil(wanted / columns))

	-- Inset so a fixture never lands inside a wall.
	local usableW = room.width * 0.7
	local usableD = room.depth * 0.7

	local out: { { x: number, z: number } } = {}
	for row = 1, rows do
		for column = 1, columns do
			if #out >= wanted then
				break
			end
			local fx = if columns == 1 then 0.5 else (column - 1) / (columns - 1)
			local fz = if rows == 1 then 0.5 else (row - 1) / (rows - 1)
			table.insert(out, {
				x = room.x - usableW / 2 + fx * usableW,
				z = room.z - usableD / 2 + fz * usableD,
			})
		end
	end
	return out
end

--- Evenly spaced pilaster offsets along a wall of length `span`.
---
--- Returns offsets from the wall's midpoint, never closer than `minSpacing`,
--- and empty for a wall too short to carry any -- a corridor with a pilaster
--- every few studs reads as a fence, not as structure.
function Decor.pilasterOffsets(span: number, minSpacing: number): { number }
	if span < minSpacing * 2 then
		return {}
	end
	local count = math.floor(span / minSpacing)
	-- Interior divisions only: a pilaster exactly on the corner doubles up with
	-- the adjoining wall's.
	local out: { number } = {}
	for index = 1, count - 1 do
		table.insert(out, -span / 2 + (span / count) * index)
	end
	return out
end

return Decor
