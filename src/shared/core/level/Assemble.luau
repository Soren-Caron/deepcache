--!strict
--[[ M2-1. Seeded level assembly from authored room modules.

	Not noise-generated terrain: a graph walk over hand-authored modules with
	tagged connectors. Constraints (all pads reachable, no module repeated
	within 2 hops, area within +/-15% of target) are checked, not hoped for.

	Shape of the algorithm:

	  1. Draw a spine length in [8, 12] and a branch count in [4, 6].
	  2. Split the spine into three zone bands (Perimeter -> Processing ->
	     Vault) and nominate one index per band to carry that zone's pad.
	  3. Depth-first walk. At each step the frontier is the previously placed
	     spine module; candidates are (free door x module x rotation) triples
	     that mate on face and size, land on unoccupied floor, and do not repeat
	     an id within 2 graph hops. Candidates are ordered by how close their
	     area is to the per-module ideal, then the top few are shuffled, so the
	     walk steers toward the area target while staying varied.
	  4. Once the spine is down, hang the branches off its free doors as dead
	     ends. Branch failure backtracks into the spine — the two phases are one
	     search, because a spine with too few free doors is not a valid spine.
	  5. Build the nav graph and validate.

	Why area steering rather than sampling counts independently: the spec asks
	for both a module count in a fixed range AND total area within +/-15% of
	target. Module areas span 1024 to 10752 square studs, so counts drawn blind
	miss the area window most of the time and the generator degenerates into
	rejection sampling. Steering makes both constraints hold in one pass.

	Everything here is pure: no Roblox globals, no clock. Given a seed and a
	catalogue the layout is bit-identical on every run and in both runtimes.
]]

local Types = require("../Types")
local Rng = require("../util/Rng")

export type Face = "N" | "S" | "E" | "W"
export type ConnectorSize = "small" | "large"
export type Connector = { face: Face, size: ConnectorSize }

export type ModuleDef = {
	id: string,
	zones: { Types.Zone },
	connectors: { Connector },
	width: number, -- X extent in studs, unrotated
	depth: number, -- Z extent in studs, unrotated
	hasPad: boolean,
}

--- One connector of a placed module, in world space. `toIndex` is the module
--- on the other side, or nil if the door leads nowhere.
export type Door = {
	face: Face, -- world-space face, after rotation
	size: ConnectorSize,
	at: Types.Vec3,
	toIndex: number?,
}

export type PlacedModule = {
	index: number,
	id: string,
	zone: Types.Zone,
	at: Types.Vec3, -- centre, y = 0
	rotation: number, -- degrees clockwise, one of 0/90/180/270
	width: number, -- X extent after rotation
	depth: number, -- Z extent after rotation
	area: number,
	hop: number, -- graph distance from the entrance
	hasPad: boolean,
	isSpine: boolean,
	neighbors: { number },
	doors: { Door },
}

export type Pad = {
	zone: Types.Zone,
	at: Types.Vec3,
	moduleIndex: number,
}

export type Waypoint = {
	id: number,
	at: Types.Vec3,
	links: { number },
	moduleIndex: number,
	kind: "room" | "door",
}

export type Layout = {
	seed: number,
	modules: { PlacedModule },
	pads: { Pad },
	waypoints: { Waypoint },
	totalArea: number,
	targetArea: number,
	spineCount: number,
	branchCount: number,
}

local Assemble = {}

Assemble.SPINE_MIN = 8
Assemble.SPINE_MAX = 12
Assemble.BRANCH_MIN = 4
Assemble.BRANCH_MAX = 6
Assemble.AREA_TOLERANCE = 0.15
Assemble.NO_REPEAT_WITHIN_HOPS = 2
Assemble.PADS_REQUIRED = 3

--- How many of the best-scoring candidates are eligible to be picked first.
--- 1 would be pure greedy and produce one layout per module count.
Assemble.CANDIDATE_POOL = 3

--- Modules at the tail of the walk are placed pure best-fit, no shuffle. They
--- are the branches, which have the fewest candidates and are the last chance
--- to correct accumulated area error; randomising them spends variety where it
--- is least visible and costs the most.
Assemble.GREEDY_TAIL = 6

--- Search ceiling. A catalogue that cannot tile stops with a clear error
--- instead of spinning; hit in practice only by a broken module set.
Assemble.MAX_PLACEMENTS = 40000

--- Floating point slack for coincident faces, in studs.
local EPS = 1e-6

local ZONE_ORDER: { Types.Zone } = { "Perimeter", "Processing", "Vault" }
local FACE_ORDER: { Face } = { "N", "E", "S", "W" }
local FACE_INDEX: { [Face]: number } = { N = 1, E = 2, S = 3, W = 4 }
local OPPOSITE: { [Face]: Face } = { N = "S", S = "N", E = "W", W = "E" }
local OUTWARD: { [Face]: { x: number, z: number } } = {
	N = { x = 0, z = 1 },
	S = { x = 0, z = -1 },
	E = { x = 1, z = 0 },
	W = { x = -1, z = 0 },
}

Assemble.ZONE_ORDER = ZONE_ORDER

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function rotateFace(face: Face, rotation: number): Face
	local steps = (math.floor(rotation / 90)) % 4
	return FACE_ORDER[((FACE_INDEX[face] - 1 + steps) % 4) + 1]
end

--- Extents after rotation. 90 and 270 swap the axes.
local function extentsOf(def: ModuleDef, rotation: number): (number, number)
	if (math.floor(rotation / 90)) % 2 == 1 then
		return def.depth, def.width
	end
	return def.width, def.depth
end

--- Connectors sit at face midpoints, so a door position is fully determined by
--- the placed box and the face. This is why joined modules line up exactly.
local function doorPosition(cx: number, cz: number, w: number, d: number, face: Face): Types.Vec3
	if face == "N" then
		return { x = cx, y = 0, z = cz + d / 2 }
	elseif face == "S" then
		return { x = cx, y = 0, z = cz - d / 2 }
	elseif face == "E" then
		return { x = cx + w / 2, y = 0, z = cz }
	end
	return { x = cx - w / 2, y = 0, z = cz }
end

local function rectsOverlap(
	ax: number, az: number, aw: number, ad: number,
	bx: number, bz: number, bw: number, bd: number
): boolean
	local axMin, axMax = ax - aw / 2, ax + aw / 2
	local azMin, azMax = az - ad / 2, az + ad / 2
	local bxMin, bxMax = bx - bw / 2, bx + bw / 2
	local bzMin, bzMax = bz - bd / 2, bz + bd / 2
	-- Shared faces are legal; only genuine interpenetration is not.
	return axMin < bxMax - EPS and bxMin < axMax - EPS and azMin < bzMax - EPS and bzMin < azMax - EPS
end

local function defArea(def: ModuleDef): number
	return def.width * def.depth
end

local function servesZone(def: ModuleDef, zone: Types.Zone): boolean
	for _, z in def.zones do
		if z == zone then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Catalogue preconditions
--------------------------------------------------------------------------------

--- A broken catalogue must fail here, with a reason, rather than as an opaque
--- search timeout twenty seconds later.
local function assertCatalogue(catalogue: { ModuleDef })
	if #catalogue == 0 then
		error("Assemble: catalogue is empty", 3)
	end

	local seenIds: { [string]: boolean } = {}
	for _, def in catalogue do
		if type(def.id) ~= "string" or #def.id == 0 then
			error("Assemble: module with a missing id", 3)
		end
		if seenIds[def.id] then
			error(`Assemble: duplicate module id "{def.id}"`, 3)
		end
		seenIds[def.id] = true

		if def.width <= 0 or def.depth <= 0 then
			error(`Assemble: module "{def.id}" has non-positive extents`, 3)
		end
		local n = #def.connectors
		if n < 2 or n > 4 then
			error(`Assemble: module "{def.id}" has {n} connectors, expected 2 to 4`, 3)
		end
		local seenFaces: { [string]: boolean } = {}
		for _, c in def.connectors do
			if OPPOSITE[c.face] == nil then
				error(`Assemble: module "{def.id}" has an unknown face "{tostring(c.face)}"`, 3)
			end
			if c.size ~= "small" and c.size ~= "large" then
				error(`Assemble: module "{def.id}" connector has an unknown size "{tostring(c.size)}"`, 3)
			end
			if seenFaces[c.face] then
				error(`Assemble: module "{def.id}" has two connectors on face {c.face}`, 3)
			end
			seenFaces[c.face] = true
		end
		if #def.zones == 0 then
			error(`Assemble: module "{def.id}" serves no zone`, 3)
		end
	end

	-- Each band needs one pad module and enough distinct modules that
	-- consecutive placements can differ. Two would deadlock the no-repeat rule
	-- the moment a band is longer than two modules.
	for _, zone in ZONE_ORDER do
		local available, pads = 0, 0
		for _, def in catalogue do
			if servesZone(def, zone) then
				available += 1
				if def.hasPad then
					pads += 1
				end
			end
		end
		if pads == 0 then
			error(`Assemble: no module with a pad serves zone {zone}`, 3)
		end
		if available < 3 then
			error(
				`Assemble: zone {zone} has {available} module(s); at least 3 are needed to avoid repeating within {Assemble.NO_REPEAT_WITHIN_HOPS} hops`,
				3
			)
		end
	end
end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

type Candidate = {
	parentIndex: number,
	doorIndex: number,
	def: ModuleDef,
	rotation: number,
	childFace: Face,
	cx: number,
	cz: number,
	w: number,
	d: number,
	score: number,
}

type State = {
	rng: Rng.Rng,
	catalogue: { ModuleDef },
	targetArea: number,
	plannedTotal: number,
	spineLength: number,
	branchCount: number,
	bandZone: { Types.Zone }, -- per spine index
	padAtIndex: { [number]: boolean },
	placed: { PlacedModule },
	placedArea: number,
	placements: number,
	exhausted: boolean,
}

--- Target area for the next module, given what is already down and how many
--- are still to come. Steering on this is what keeps the total in the window.
local function idealArea(state: State): number
	local remaining = state.plannedTotal - #state.placed
	if remaining <= 0 then
		return 0
	end
	return math.max(0, (state.targetArea - state.placedArea) / remaining)
end

--- Ids within NO_REPEAT_WITHIN_HOPS of the attachment point. The new module is
--- a leaf, so its 2-hop neighbourhood is exactly the parent plus the parent's
--- existing neighbours.
local function forbiddenIdsAt(state: State, parentIndex: number): { [string]: boolean }
	local forbidden: { [string]: boolean } = {}
	local parent = state.placed[parentIndex]
	forbidden[parent.id] = true
	for _, n in parent.neighbors do
		forbidden[state.placed[n].id] = true
	end
	return forbidden
end

local function fits(state: State, cx: number, cz: number, w: number, d: number): boolean
	for _, p in state.placed do
		if rectsOverlap(cx, cz, w, d, p.at.x, p.at.z, p.width, p.depth) then
			return false
		end
	end
	return true
end

local function collectCandidates(
	state: State,
	parentIndices: { number },
	zone: Types.Zone?,
	wantPad: boolean
): { Candidate }
	local out: { Candidate } = {}
	local ideal = idealArea(state)

	for _, parentIndex in parentIndices do
		local parent = state.placed[parentIndex]
		local forbidden = forbiddenIdsAt(state, parentIndex)
		local targetZone = zone or parent.zone

		for doorIndex, door in parent.doors do
			if door.toIndex ~= nil then
				continue
			end
			local needFace = OPPOSITE[door.face]

			for _, def in state.catalogue do
				if def.hasPad ~= wantPad then
					continue
				end
				if forbidden[def.id] then
					continue
				end
				if not servesZone(def, targetZone) then
					continue
				end

				for _, connector in def.connectors do
					if connector.size ~= door.size then
						continue
					end
					for rotation = 0, 270, 90 do
						if rotateFace(connector.face, rotation) ~= needFace then
							continue
						end
						local w, d = extentsOf(def, rotation)
						-- Push the child back off the shared door by half its
						-- extent along the mating axis.
						local out2 = OUTWARD[needFace]
						local half = if out2.x ~= 0 then w / 2 else d / 2
						local cx = door.at.x - out2.x * half
						local cz = door.at.z - out2.z * half
						if fits(state, cx, cz, w, d) then
							table.insert(out, {
								parentIndex = parentIndex,
								doorIndex = doorIndex,
								def = def,
								rotation = rotation,
								childFace = needFace,
								cx = cx,
								cz = cz,
								w = w,
								d = d,
								score = math.abs(defArea(def) - ideal),
							})
						end
					end
				end
			end
		end
	end

	return out
end

--- Best-first by area fit, with the top CANDIDATE_POOL shuffled so a seed
--- changes the layout rather than only its size.
---
--- The pool narrows to pure best-fit for the last two modules. Randomising
--- there spends variety where it is least visible and most expensive: those
--- placements are the only ones left to absorb accumulated area error.
local function orderCandidates(state: State, candidates: { Candidate }): { Candidate }
	table.sort(candidates, function(a: Candidate, b: Candidate): boolean
		if a.score ~= b.score then
			return a.score < b.score
		end
		if a.def.id ~= b.def.id then
			return a.def.id < b.def.id
		end
		if a.rotation ~= b.rotation then
			return a.rotation < b.rotation
		end
		if a.parentIndex ~= b.parentIndex then
			return a.parentIndex < b.parentIndex
		end
		return a.doorIndex < b.doorIndex
	end)

	local remaining = state.plannedTotal - #state.placed
	local width = if remaining <= Assemble.GREEDY_TAIL then 1 else Assemble.CANDIDATE_POOL
	local pool = math.min(width, #candidates)
	if pool > 1 then
		local pick = Rng.nextRange(state.rng, 1, pool)
		if pick > 1 then
			table.insert(candidates, 1, table.remove(candidates, pick) :: Candidate)
		end
	end
	return candidates
end

--- Keep only the spine placements that move away from what is already built.
---
--- A self-avoiding walk in the plane curls up. Once it does, the only modules
--- that still fit are the small ones, which is what drags total area below
--- target and pushes the search into backtracking. Requiring each spine step
--- to land further from the placed centroid than its parent did straightens
--- the walk, and a spine that reads as a route through the facility rather
--- than a knot is the better level anyway.
---
--- A predicate, not a weight: comparing "closeness to ideal area" against
--- "distance in studs" needs an exchange rate, and any exchange rate here
--- would be a constant tuned to one catalogue. Falls back to the unfiltered
--- set when nothing points outward, so this can never make a layout
--- impossible — only less likely to be a knot.
local function preferOutward(state: State, candidates: { Candidate }): { Candidate }
	local n = #state.placed
	if n == 0 then
		return candidates
	end

	local cx, cz = 0, 0
	for _, p in state.placed do
		cx += p.at.x
		cz += p.at.z
	end
	cx, cz = cx / n, cz / n

	local function distFrom(x: number, z: number): number
		local dx, dz = x - cx, z - cz
		return math.sqrt(dx * dx + dz * dz)
	end

	local outward: { Candidate } = {}
	for _, c in candidates do
		local parent = state.placed[c.parentIndex]
		if distFrom(c.cx, c.cz) > distFrom(parent.at.x, parent.at.z) then
			table.insert(outward, c)
		end
	end

	return if #outward > 0 then outward else candidates
end

local function makeDoors(def: ModuleDef, rotation: number, cx: number, cz: number, w: number, d: number): { Door }
	local doors: { Door } = {}
	for _, connector in def.connectors do
		local face = rotateFace(connector.face, rotation)
		table.insert(doors, {
			face = face,
			size = connector.size,
			at = doorPosition(cx, cz, w, d, face),
			toIndex = nil,
		})
	end
	table.sort(doors, function(a: Door, b: Door): boolean
		return FACE_INDEX[a.face] < FACE_INDEX[b.face]
	end)
	return doors
end

local function push(state: State, candidate: Candidate, zone: Types.Zone, isSpine: boolean): PlacedModule
	local index = #state.placed + 1
	local parent = state.placed[candidate.parentIndex]
	local placed: PlacedModule = {
		index = index,
		id = candidate.def.id,
		zone = zone,
		at = { x = candidate.cx, y = 0, z = candidate.cz },
		rotation = candidate.rotation,
		width = candidate.w,
		depth = candidate.d,
		area = candidate.w * candidate.d,
		hop = parent.hop + 1,
		hasPad = candidate.def.hasPad,
		isSpine = isSpine,
		neighbors = { candidate.parentIndex },
		doors = makeDoors(candidate.def, candidate.rotation, candidate.cx, candidate.cz, candidate.w, candidate.d),
	}

	-- Link both sides. The child's mating door is the one facing back at the
	-- parent; faces are unique per module, so that identifies it exactly.
	for _, door in placed.doors do
		if door.face == candidate.childFace then
			door.toIndex = candidate.parentIndex
			break
		end
	end
	parent.doors[candidate.doorIndex].toIndex = index
	table.insert(parent.neighbors, index)

	table.insert(state.placed, placed)
	state.placedArea += placed.area
	state.placements += 1
	if state.placements > Assemble.MAX_PLACEMENTS then
		state.exhausted = true
	end
	return placed
end

local function pop(state: State, candidate: Candidate)
	local placed = table.remove(state.placed) :: PlacedModule
	state.placedArea -= placed.area
	local parent = state.placed[candidate.parentIndex]
	parent.doors[candidate.doorIndex].toIndex = nil
	table.remove(parent.neighbors)
end

local function freeDoorCount(state: State): number
	local n = 0
	for _, p in state.placed do
		if p.isSpine then
			for _, door in p.doors do
				if door.toIndex == nil then
					n += 1
				end
			end
		end
	end
	return n
end

local function spineIndices(state: State): { number }
	local out: { number } = {}
	for _, p in state.placed do
		if p.isSpine then
			table.insert(out, p.index)
		end
	end
	return out
end

local placeStep: (state: State, step: number) -> boolean

--- One DFS across both phases. Branch failure must be able to undo spine
--- choices: a spine whose modules leave fewer free doors than the branch count
--- is not a valid spine, and only the search knows that.
function placeStep(state: State, step: number): boolean
	if state.exhausted then
		return false
	end
	if step > state.plannedTotal then
		return true
	end

	local isSpine = step <= state.spineLength

	local parents: { number }
	local zone: Types.Zone?
	if isSpine then
		parents = { step - 1 }
		zone = state.bandZone[step]
	else
		parents = spineIndices(state)
		zone = nil -- inherit from the parent
	end

	local wantPad = isSpine and state.padAtIndex[step] == true
	local raw = collectCandidates(state, parents, zone, wantPad)
	-- Branches are meant to fill in around the spine, so they are not steered
	-- outward; only the spine is.
	local candidates = orderCandidates(state, if isSpine then preferOutward(state, raw) else raw)

	for _, candidate in candidates do
		local placedZone = zone or state.placed[candidate.parentIndex].zone
		push(state, candidate, placedZone, isSpine)
		local ok = true
		if isSpine and step == state.spineLength and freeDoorCount(state) < state.branchCount then
			ok = false
		end
		if ok and placeStep(state, step + 1) then
			return true
		end
		pop(state, candidate)
		if state.exhausted then
			return false
		end
	end
	return false
end

--- The root has no parent, so it is placed directly rather than through a
--- candidate. Rotation is drawn too: it rotates the whole level, which is
--- invisible on its own but changes every subsequent placement.
local function placeRoot(state: State): boolean
	type Root = { def: ModuleDef, rotation: number, score: number }
	local roots: { Root } = {}
	local ideal = idealArea(state)
	local wantPad = state.padAtIndex[1] == true

	for _, def in state.catalogue do
		if def.hasPad ~= wantPad or not servesZone(def, state.bandZone[1]) then
			continue
		end
		for rotation = 0, 270, 90 do
			table.insert(roots, { def = def, rotation = rotation, score = math.abs(defArea(def) - ideal) })
		end
	end
	if #roots == 0 then
		return false
	end

	table.sort(roots, function(a: Root, b: Root): boolean
		if a.score ~= b.score then
			return a.score < b.score
		end
		if a.def.id ~= b.def.id then
			return a.def.id < b.def.id
		end
		return a.rotation < b.rotation
	end)
	local pool = math.min(Assemble.CANDIDATE_POOL, #roots)
	if pool > 1 then
		local pick = Rng.nextRange(state.rng, 1, pool)
		if pick > 1 then
			table.insert(roots, 1, table.remove(roots, pick) :: Root)
		end
	end

	for _, root in roots do
		local w, d = extentsOf(root.def, root.rotation)
		local placed: PlacedModule = {
			index = 1,
			id = root.def.id,
			zone = state.bandZone[1],
			at = { x = 0, y = 0, z = 0 },
			rotation = root.rotation,
			width = w,
			depth = d,
			area = w * d,
			hop = 0,
			hasPad = root.def.hasPad,
			isSpine = true,
			neighbors = {},
			doors = makeDoors(root.def, root.rotation, 0, 0, w, d),
		}
		state.placed = { placed }
		state.placedArea = placed.area
		state.placements += 1
		if placeStep(state, 2) then
			return true
		end
		if state.exhausted then
			return false
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

--- Split the spine into three zone bands, deepest last. Rounding keeps every
--- band at 2 or more for every legal spine length.
local function makeBands(spineLength: number): { Types.Zone }
	local perimeter = math.floor(spineLength / 3 + 0.5)
	local processing = math.floor(spineLength / 3 + 0.5)
	local vault = spineLength - perimeter - processing

	local bands: { Types.Zone } = {}
	for _ = 1, perimeter do
		table.insert(bands, "Perimeter")
	end
	for _ = 1, processing do
		table.insert(bands, "Processing")
	end
	for _ = 1, vault do
		table.insert(bands, "Vault")
	end
	return bands
end

--- Module counts to try, most plausible first, walking outward from the
--- estimate and preferring the larger side on ties.
local function countOrder(estimate: number, minTotal: number, maxTotal: number): { number }
	local order: { number } = {}
	local function add(n: number)
		if n >= minTotal and n <= maxTotal then
			table.insert(order, n)
		end
	end
	add(estimate)
	for delta = 1, maxTotal - minTotal do
		add(estimate + delta)
		add(estimate - delta)
	end
	return order
end

local function feasibleBranchCounts(plannedTotal: number): { number }
	local out: { number } = {}
	for b = Assemble.BRANCH_MIN, Assemble.BRANCH_MAX do
		local spine = plannedTotal - b
		if spine >= Assemble.SPINE_MIN and spine <= Assemble.SPINE_MAX then
			table.insert(out, b)
		end
	end
	return out
end

--- One greedy walk at a fixed module count. Returns whatever it placed and the
--- area it reached, in or out of the window — judging the result is the
--- caller's job, and the out-of-window areas are what calibrate the next try.
local function attempt(
	rng: Rng.Rng,
	catalogue: { ModuleDef },
	targetArea: number,
	plannedTotal: number,
	branchCount: number
): ({ PlacedModule }?, number?)
	local spineLength = plannedTotal - branchCount
	local bands = makeBands(spineLength)

	-- One pad per band, at a random index inside it.
	local padAtIndex: { [number]: boolean } = {}
	for _, zone in ZONE_ORDER do
		local first: number?, last: number? = nil, nil
		for i, z in bands do
			if z == zone then
				first = first or i
				last = i
			end
		end
		if first and last then
			padAtIndex[Rng.nextRange(rng, first, last)] = true
		end
	end

	local state: State = {
		rng = rng,
		catalogue = catalogue,
		targetArea = targetArea,
		plannedTotal = plannedTotal,
		spineLength = spineLength,
		branchCount = branchCount,
		bandZone = bands,
		padAtIndex = padAtIndex,
		placed = {},
		placedArea = 0,
		placements = 0,
		exhausted = false,
	}

	if not placeRoot(state) then
		return nil, nil
	end
	return state.placed, state.placedArea
end

function Assemble.generate(seed: number, catalogue: { ModuleDef }, targetArea: number): Layout
	assertCatalogue(catalogue)
	if targetArea <= 0 then
		error(`Assemble: targetArea must be positive, got {targetArea}`, 2)
	end

	local rng = Rng.new(seed)

	-- Module count is searched, not guessed. The walk is greedy, so a given
	-- count yields essentially one area; if that area misses the window it is
	-- the count that was wrong, not the walk.
	--
	-- The catalogue mean is only a first guess, and a biased one: connector
	-- sizes, zone bands and the no-repeat rule all shrink the reachable set, so
	-- modules actually land ~6% below the raw mean. Rather than correcting that
	-- with a factor measured against this one catalogue, the first walk is used
	-- to measure the achievable mean directly and the count is recomputed from
	-- it. Two walks, no constants, and it stays right when the catalogue does
	-- not.
	local meanArea = 0
	for _, def in catalogue do
		meanArea += defArea(def)
	end
	meanArea /= #catalogue

	local minTotal = Assemble.SPINE_MIN + Assemble.BRANCH_MIN
	local maxTotal = Assemble.SPINE_MAX + Assemble.BRANCH_MAX
	local estimate = math.clamp(math.floor(targetArea / meanArea + 0.5), minTotal, maxTotal)

	local chosen: { PlacedModule }? = nil
	local chosenArea = 0
	local spineLength, branchCount = 0, 0
	local tiled = false
	local closest: number? = nil
	local tried: { [number]: boolean } = {}

	--- Walk once at this module count. Keeps the in-window result closest to
	--- target rather than the first one that merely qualifies: accepting the
	--- first means always accepting the smallest allowed level, which is a 13%
	--- systematic shortfall against whatever size the designer asked for.
	local function tryCount(total: number): number?
		if total < minTotal or total > maxTotal or tried[total] then
			return nil
		end
		tried[total] = true

		for _, b in Rng.shuffle(rng, feasibleBranchCounts(total)) do
			local placed, area = attempt(rng, catalogue, targetArea, total, b)
			if placed == nil or area == nil then
				continue -- this branch split could not tile; try another
			end
			tiled = true
			local err = math.abs(area - targetArea)
			if closest == nil or err < math.abs(closest - targetArea) then
				closest = area
			end
			if err <= targetArea * Assemble.AREA_TOLERANCE then
				if chosen == nil or err < math.abs(chosenArea - targetArea) then
					chosen = placed
					chosenArea = area
					spineLength = total - b
					branchCount = b
				end
			end
			return area
		end
		return nil
	end

	local firstArea = tryCount(estimate)
	if firstArea ~= nil and firstArea > 0 then
		local achievableMean = firstArea / estimate
		tryCount(math.clamp(math.floor(targetArea / achievableMean + 0.5), minTotal, maxTotal))
	end
	if chosen == nil then
		-- Calibration missed. Fall back to scanning outward from the estimate.
		for _, total in countOrder(estimate, minTotal, maxTotal) do
			tryCount(total)
			if chosen ~= nil then
				break
			end
		end
	end

	if chosen == nil then
		if not tiled then
			error(`Assemble: no valid layout for seed {seed}; the catalogue cannot tile`, 2)
		end
		error(
			string.format(
				"Assemble: no layout within +/-%.0f%% of target area %.0f for seed %d (closest %.0f); "
					.. "the catalogue cannot fill a level this size at %d-%d modules",
				Assemble.AREA_TOLERANCE * 100,
				targetArea,
				seed,
				closest or 0,
				minTotal,
				maxTotal
			),
			2
		)
	end
	local placedModules = (chosen :: any) :: { PlacedModule }

	local pads: { Pad } = {}
	local totalArea = 0
	for _, p in placedModules do
		totalArea += p.area
	end
	for _, zone in ZONE_ORDER do
		for _, p in placedModules do
			if p.hasPad and p.zone == zone then
				table.insert(pads, { zone = zone, at = p.at, moduleIndex = p.index })
			end
		end
	end

	local layout: Layout = {
		seed = seed,
		modules = placedModules,
		pads = pads,
		waypoints = {},
		totalArea = totalArea,
		targetArea = targetArea,
		spineCount = spineLength,
		branchCount = branchCount,
	}

	-- Every consumer of a layout wants the nav graph, and a Layout carrying an
	-- empty `waypoints` would be a trap. Build it here rather than making it
	-- the caller's job to remember.
	Assemble.buildNavGraph(layout)

	local ok, why = Assemble.validate(layout, targetArea)
	if not ok then
		error(`Assemble: generated layout for seed {seed} failed validation: {why}`, 2)
	end

	return layout
end

--- Verify a layout meets every constraint. Returns false plus the first
--- violation, so a bad module catalogue fails loudly instead of shipping.
---
--- Deliberately re-derives everything from the placed geometry rather than
--- trusting the generator's bookkeeping: this is the check that catches a
--- generator bug, so sharing state with it would defeat the point.
function Assemble.validate(layout: Layout, targetArea: number): (boolean, string?)
	local modules = layout.modules
	local n = #modules
	if n == 0 then
		return false, "layout has no modules"
	end
	if layout.spineCount < Assemble.SPINE_MIN or layout.spineCount > Assemble.SPINE_MAX then
		return false, `spine of {layout.spineCount} outside [{Assemble.SPINE_MIN}, {Assemble.SPINE_MAX}]`
	end
	if layout.branchCount < Assemble.BRANCH_MIN or layout.branchCount > Assemble.BRANCH_MAX then
		return false, `branch count {layout.branchCount} outside [{Assemble.BRANCH_MIN}, {Assemble.BRANCH_MAX}]`
	end
	if n ~= layout.spineCount + layout.branchCount then
		return false, `{n} modules placed but spine + branches is {layout.spineCount + layout.branchCount}`
	end

	-- Geometry: nothing interpenetrates.
	for i = 1, n do
		local a = modules[i]
		if a.width <= 0 or a.depth <= 0 then
			return false, `module {i} ({a.id}) has non-positive extents`
		end
		if math.abs(a.area - a.width * a.depth) > EPS then
			return false, `module {i} ({a.id}) area {a.area} does not match {a.width} x {a.depth}`
		end
		for j = i + 1, n do
			local b = modules[j]
			if rectsOverlap(a.at.x, a.at.z, a.width, a.depth, b.at.x, b.at.z, b.width, b.depth) then
				return false, `modules {i} ({a.id}) and {j} ({b.id}) overlap`
			end
		end
	end

	-- Connections: mutual, opposite-facing, same size, coincident.
	for i = 1, n do
		local a = modules[i]
		for _, door in a.doors do
			local to = door.toIndex
			if to == nil then
				continue
			end
			if to < 1 or to > n then
				return false, `module {i} ({a.id}) has a door to out-of-range index {to}`
			end
			local b = modules[to]
			local back: Door? = nil
			for _, other in b.doors do
				if other.toIndex == i then
					back = other
					break
				end
			end
			if back == nil then
				return false, `module {i} ({a.id}) connects to {to} ({b.id}) but not the reverse`
			end
			local backDoor = back :: Door
			if backDoor.face ~= OPPOSITE[door.face] then
				return false, `modules {i} and {to} join on {door.face}/{backDoor.face}, which are not opposite`
			end
			if backDoor.size ~= door.size then
				return false, `modules {i} and {to} join a {door.size} door to a {backDoor.size} one`
			end
			if math.abs(backDoor.at.x - door.at.x) > 1e-4 or math.abs(backDoor.at.z - door.at.z) > 1e-4 then
				return false, `modules {i} and {to} have doorways that do not coincide`
			end
		end
	end

	-- Connectivity and hop distances, derived by BFS rather than trusted.
	local dist: { number } = table.create(n, -1)
	dist[1] = 0
	local queue: { number } = { 1 }
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		for _, nb in modules[cur].neighbors do
			if nb < 1 or nb > n then
				return false, `module {cur} has out-of-range neighbour {nb}`
			end
			if dist[nb] == -1 then
				dist[nb] = dist[cur] + 1
				table.insert(queue, nb)
			end
		end
	end
	for i = 1, n do
		if dist[i] == -1 then
			return false, `module {i} ({modules[i].id}) is unreachable from the entrance`
		end
		if modules[i].hop ~= dist[i] then
			return false, `module {i} ({modules[i].id}) records hop {modules[i].hop}, BFS says {dist[i]}`
		end
	end

	-- Pads: one per zone, all three present, all reachable (implied by the
	-- connectivity check above, which every module had to pass).
	local padZones: { [string]: number } = {}
	local padCount = 0
	for i = 1, n do
		if modules[i].hasPad then
			padCount += 1
			padZones[modules[i].zone] = (padZones[modules[i].zone] or 0) + 1
		end
	end
	if padCount ~= Assemble.PADS_REQUIRED then
		return false, `{padCount} pads placed, expected {Assemble.PADS_REQUIRED}`
	end
	for _, zone in ZONE_ORDER do
		if (padZones[zone] or 0) ~= 1 then
			return false, `zone {zone} has {padZones[zone] or 0} pads, expected exactly 1`
		end
	end
	if #layout.pads ~= Assemble.PADS_REQUIRED then
		return false, `pads list has {#layout.pads} entries, expected {Assemble.PADS_REQUIRED}`
	end
	for _, pad in layout.pads do
		local m = modules[pad.moduleIndex]
		if m == nil or not m.hasPad or m.zone ~= pad.zone then
			return false, `pad entry for zone {pad.zone} does not match module {pad.moduleIndex}`
		end
	end

	-- No module id repeats within NO_REPEAT_WITHIN_HOPS graph hops.
	for i = 1, n do
		local seen: { [number]: boolean } = { [i] = true }
		local frontier: { number } = { i }
		for _ = 1, Assemble.NO_REPEAT_WITHIN_HOPS do
			local nextFrontier: { number } = {}
			for _, cur in frontier do
				for _, nb in modules[cur].neighbors do
					if not seen[nb] then
						seen[nb] = true
						table.insert(nextFrontier, nb)
						if modules[nb].id == modules[i].id then
							return false,
								`module id "{modules[i].id}" repeats within {Assemble.NO_REPEAT_WITHIN_HOPS} hops (indices {i} and {nb})`
						end
					end
				end
			end
			frontier = nextFrontier
		end
	end

	-- Total area within tolerance.
	local total = 0
	for i = 1, n do
		total += modules[i].area
	end
	if math.abs(total - layout.totalArea) > 1e-6 then
		return false, `layout records totalArea {layout.totalArea} but modules sum to {total}`
	end
	local allowed = targetArea * Assemble.AREA_TOLERANCE
	if math.abs(total - targetArea) > allowed then
		return false,
			string.format(
				"total area %.0f is %.1f%% off target %.0f, outside +/-%.0f%%",
				total,
				(total - targetArea) / targetArea * 100,
				targetArea,
				Assemble.AREA_TOLERANCE * 100
			)
	end

	-- Nav graph: one room waypoint per module, links symmetric, fully connected.
	local wps = layout.waypoints
	if #wps == 0 then
		return false, "nav graph is empty"
	end
	local roomFor: { [number]: number } = {}
	for _, wp in wps do
		if wp.kind == "room" then
			if roomFor[wp.moduleIndex] then
				return false, `module {wp.moduleIndex} has two room waypoints`
			end
			roomFor[wp.moduleIndex] = wp.id
		end
	end
	for i = 1, n do
		if roomFor[i] == nil then
			return false, `module {i} ({modules[i].id}) has no room waypoint`
		end
	end
	for _, wp in wps do
		for _, link in wp.links do
			local other = wps[link]
			if other == nil then
				return false, `waypoint {wp.id} links to missing waypoint {link}`
			end
			local mutual = false
			for _, back in other.links do
				if back == wp.id then
					mutual = true
					break
				end
			end
			if not mutual then
				return false, `waypoint link {wp.id} -> {link} is not mutual`
			end
		end
	end
	local seenWp: { [number]: boolean } = { [1] = true }
	local wpQueue: { number } = { 1 }
	local wpHead, reached = 1, 1
	while wpHead <= #wpQueue do
		local cur = wpQueue[wpHead]
		wpHead += 1
		for _, link in wps[cur].links do
			if not seenWp[link] then
				seenWp[link] = true
				reached += 1
				table.insert(wpQueue, link)
			end
		end
	end
	if reached ~= #wps then
		return false, `nav graph is disconnected: {reached} of {#wps} waypoints reachable`
	end

	return true, nil
end

--- Coarse waypoint graph for entity pathing, built at assembly time.
---
--- One node per room centre, one per doorway. Rooms never link directly to
--- each other: travel between two rooms goes through the doorway node, which
--- is where the geometry actually forces you, so a straight-line follow of
--- consecutive nodes stays inside the level.
function Assemble.buildNavGraph(layout: Layout): Layout
	local waypoints: { Waypoint } = {}

	for _, m in layout.modules do
		waypoints[m.index] = {
			id = m.index,
			at = { x = m.at.x, y = 0, z = m.at.z },
			links = {},
			moduleIndex = m.index,
			kind = "room",
		}
	end

	local function link(a: number, b: number)
		table.insert(waypoints[a].links, b)
		table.insert(waypoints[b].links, a)
	end

	for _, m in layout.modules do
		for _, door in m.doors do
			local to = door.toIndex
			-- Each connection produces one node; the lower index owns it.
			if to ~= nil and to > m.index then
				local id = #waypoints + 1
				waypoints[id] = {
					id = id,
					at = { x = door.at.x, y = 0, z = door.at.z },
					links = {},
					moduleIndex = m.index,
					kind = "door",
				}
				link(id, m.index)
				link(id, to)
			end
		end
	end

	layout.waypoints = waypoints
	return layout
end

return Assemble
