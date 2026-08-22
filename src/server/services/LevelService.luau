--!strict
--[[
	Instantiates an `Assemble.Layout` into the DataModel.

	The layout is computed in pure core, which knows nothing about Roblox; this
	is the adapter that turns it into parts. It is deliberately the only place
	that converts the core's plain `{x, y, z}` tables into `Vector3`.

	Geometry contract, which the authored modules at M7 must keep:

	  - A module is a sealed box. Every face without a *used* connector gets a
	    solid wall, so a level has no holes to fall out of.
	  - Doorways are centred on their face, which is what makes two joined
	    modules line up with no per-module offset table. `core/level/Assemble`
	    relies on this and `validate-config` enforces the catalogue side.
	  - Walls are built inside the footprint. Two connected modules each own the
	    wall on their shared face, and building on the shared plane would put
	    two parts in the same space.

	Zone tinting here is a placeholder that makes depth legible while building
	the loop. The real look — lighting presets, fog, post stack — is M7-5.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Assemble = require(Shared.core.level.Assemble)
local Path = require(Shared.core.level.Path)
local Rooms = require(Shared.config.Rooms)
local Zones = require(Shared.config.Zones)
local Types = require(Shared.core.Types)

local LevelService = {}

local FOLDER_NAME = "Level"
local GEOMETRY = Rooms.geometry

local currentLayout: Assemble.Layout? = nil
local spawnPoints: { [string]: { Types.Vec3 } } = {}
local root: Folder? = nil

local function toVector3(v: Types.Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

--- Placeholder tint: deeper zones read darker. Replaced wholesale at M7-5.
local function zoneColor(zone: string): Color3
	local depth = Zones[zone].depth
	local shade = 0.62 - (depth - 1) * 0.14
	return Color3.new(shade, shade, shade + 0.03)
end

local function makePart(name: string, size: Vector3, position: Vector3, parent: Instance, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.Concrete
	part.Color = color
	part.Parent = parent
	return part
end

--- One wall face. Splits around a doorway when the face carries a used
--- connector, and adds the lintel above it so the gap is a doorway rather than
--- a slot open to the ceiling.
local function buildWall(
	parent: Instance,
	face: string,
	module_: Assemble.PlacedModule,
	doorWidth: number?,
	color: Color3
)
	local thickness = GEOMETRY.wallThickness
	local height = GEOMETRY.wallHeight
	local halfW, halfD = module_.width / 2, module_.depth / 2
	local cx, cz = module_.at.x, module_.at.z

	-- `span` is the wall's length along its own axis; `centre` is its midpoint,
	-- inset by half the thickness so the wall sits inside the footprint.
	local horizontal = face == "N" or face == "S"
	local span = if horizontal then module_.width else module_.depth
	local x, z = cx, cz
	if face == "N" then
		z = cz + halfD - thickness / 2
	elseif face == "S" then
		z = cz - halfD + thickness / 2
	elseif face == "E" then
		x = cx + halfW - thickness / 2
	else
		x = cx - halfW + thickness / 2
	end

	local function segment(name: string, length: number, offset: number, yCentre: number, ySize: number)
		if length <= 0.01 or ySize <= 0.01 then
			return
		end
		local size = if horizontal then Vector3.new(length, ySize, thickness) else Vector3.new(thickness, ySize, length)
		local position = if horizontal
			then Vector3.new(x + offset, yCentre, z)
			else Vector3.new(x, yCentre, z + offset)
		makePart(`Wall_{face}_{name}`, size, position, parent, color)
	end

	if doorWidth == nil then
		segment("Solid", span, 0, height / 2, height)
		return
	end

	-- Doorway centred on the face: two jambs and a lintel.
	local jamb = (span - doorWidth) / 2
	segment("JambA", jamb, -(doorWidth + jamb) / 2, height / 2, height)
	segment("JambB", jamb, (doorWidth + jamb) / 2, height / 2, height)

	local lintelHeight = height - GEOMETRY.doorwayHeight
	segment("Lintel", doorWidth, 0, GEOMETRY.doorwayHeight + lintelHeight / 2, lintelHeight)
end

--- Points inside a module, inset from the walls, for enemy and loot spawning.
--- Scaled by floor area so a big room is not as sparse as a corridor.
local function spawnPointsIn(module_: Assemble.PlacedModule): { Types.Vec3 }
	local inset = GEOMETRY.spawnInset
	local usableW = math.max(0, module_.width - inset * 2)
	local usableD = math.max(0, module_.depth - inset * 2)
	if usableW <= 0 or usableD <= 0 then
		-- A corridor narrower than twice the inset still needs one point, or
		-- entities can never spawn in it.
		return { { x = module_.at.x, y = 0, z = module_.at.z } }
	end

	local wanted = math.max(1, math.floor(module_.area / GEOMETRY.studsPerSpawnPoint + 0.5))
	-- Lay them out on the most square grid that holds `wanted`.
	local columns = math.max(1, math.ceil(math.sqrt(wanted)))
	local rows = math.max(1, math.ceil(wanted / columns))

	local out: { Types.Vec3 } = {}
	for row = 1, rows do
		for column = 1, columns do
			local fx = if columns == 1 then 0.5 else (column - 1) / (columns - 1)
			local fz = if rows == 1 then 0.5 else (row - 1) / (rows - 1)
			table.insert(out, {
				x = module_.at.x - usableW / 2 + fx * usableW,
				y = 0,
				z = module_.at.z - usableD / 2 + fz * usableD,
			})
		end
	end
	return out
end

--- Which faces of this module carry a doorway, and how wide.
local function doorWidths(module_: Assemble.PlacedModule): { [string]: number }
	local out: { [string]: number } = {}
	for _, door in module_.doors do
		-- Unused connectors are walled over: the box has to stay sealed.
		if door.toIndex ~= nil then
			out[door.face] = Rooms.connectorWidths[door.size]
		end
	end
	return out
end

--- Default-place scaffolding suppressed while a level is built, and what it
--- was, so `clear` can put it back.
local stashed: { { instance: Instance, property: string, value: any } } = {}

--- The generated level is the ground. The default Baseplate's top surface sits
--- at exactly y = 0, which is where module floors go — leaving it would
--- z-fight across every floor in the level — and the default SpawnLocation
--- would compete with the drop point for arriving players.
---
--- Suppressed rather than deleted, and restored by `clear`, because this runs
--- in Edit mode during verification and destroying scenery in someone's place
--- is not a thing a level builder should do behind their back.
local function suppressScaffolding()
	local function stash(instance: Instance, property: string, value: any)
		table.insert(stashed, { instance = instance, property = property, value = (instance :: any)[property] });
		(instance :: any)[property] = value
	end

	for _, child in Workspace:GetChildren() do
		if child.Name == "Baseplate" and child:IsA("BasePart") then
			stash(child, "Transparency", 1)
			stash(child, "CanCollide", false)
		elseif child:IsA("SpawnLocation") then
			stash(child, "Enabled", false)
		end
	end
end

local function restoreScaffolding()
	for index = #stashed, 1, -1 do
		local entry = stashed[index]
		if entry.instance.Parent ~= nil then
			(entry.instance :: any)[entry.property] = entry.value
		end
	end
	stashed = {}
end

function LevelService.clear()
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	restoreScaffolding()
	root = nil
	currentLayout = nil
	spawnPoints = {}
end

--- Build the level for `seed`. Returns the layout, which every other service
--- needs: pathing, spawn planning, pad schedule, loot placement.
function LevelService.build(seed: number): Assemble.Layout
	LevelService.clear()

	local layout = Assemble.generate(seed, Rooms.modules :: any, Rooms.targetArea)
	suppressScaffolding()

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder:SetAttribute("seed", seed)
	folder:SetAttribute("totalArea", layout.totalArea)

	local modulesFolder = Instance.new("Folder")
	modulesFolder.Name = "Modules"
	modulesFolder.Parent = folder

	spawnPoints = { Perimeter = {}, Processing = {}, Vault = {} }

	for _, module_ in layout.modules do
		local color = zoneColor(module_.zone)
		local model = Instance.new("Model")
		model.Name = string.format("%03d_%s", module_.index, module_.id)
		model:SetAttribute("moduleIndex", module_.index)
		model:SetAttribute("zone", module_.zone)
		model:SetAttribute("hop", module_.hop)
		model:SetAttribute("isSpine", module_.isSpine)
		model.Parent = modulesFolder
		CollectionService:AddTag(model, `Zone_{module_.zone}`)

		local floor = makePart(
			"Floor",
			Vector3.new(module_.width, GEOMETRY.floorThickness, module_.depth),
			Vector3.new(module_.at.x, -GEOMETRY.floorThickness / 2, module_.at.z),
			model,
			color
		)
		model.PrimaryPart = floor

		local widths = doorWidths(module_)
		for _, face in { "N", "S", "E", "W" } do
			buildWall(model, face, module_, widths[face], color)
		end

		for _, point in spawnPointsIn(module_) do
			table.insert(spawnPoints[module_.zone], point)
		end
	end

	-- Extraction pads, one per zone. Visible markers for now; the open/close
	-- schedule and the extraction volume are M2-7.
	local padsFolder = Instance.new("Folder")
	padsFolder.Name = "Pads"
	padsFolder.Parent = folder
	for _, pad in layout.pads do
		local part = makePart(
			`Pad_{pad.zone}`,
			Vector3.new(20, 1, 20),
			Vector3.new(pad.at.x, 0.5, pad.at.z),
			padsFolder,
			Color3.fromRGB(90, 190, 140)
		)
		part.Material = Enum.Material.Neon
		part:SetAttribute("zone", pad.zone)
		part:SetAttribute("moduleIndex", pad.moduleIndex)
		part:SetAttribute("opensAtSeconds", Zones[pad.zone].padOpensAt)
		part.CanCollide = false
		CollectionService:AddTag(part, "ExtractionPad")
	end

	-- Players drop at the entrance, which is module 1 by construction.
	local entrance = layout.modules[1]
	local start = Instance.new("SpawnLocation")
	start.Name = "DropPoint"
	start.Size = Vector3.new(12, 1, 12)
	start.Position = Vector3.new(entrance.at.x, 0.5, entrance.at.z)
	start.Anchored = true
	start.CanCollide = false
	start.Neutral = true
	start.Duration = 0
	start.Color = Color3.fromRGB(200, 170, 90)
	start.Material = Enum.Material.Neon
	start.Parent = folder

	folder.Parent = Workspace
	root = folder
	currentLayout = layout

	return layout
end

function LevelService.getLayout(): Assemble.Layout?
	return currentLayout
end

--- Spawn points for a zone, in layout order. Callers that need randomness
--- bring their own rng — this stays deterministic so a replayed seed places
--- the same wave in the same places.
function LevelService.spawnPointsFor(zone: string): { Types.Vec3 }
	return spawnPoints[zone] or {}
end

--- Which zone band a world position sits in, or nil if it is outside every
--- module. Drives the client's lighting transitions (M7-5).
---
--- Point-in-rect against the placed modules rather than a distance-to-centre
--- nearest search: modules vary from 32x32 to 128x96, so the nearest *centre*
--- to a point standing at the edge of a large room is frequently the centre of
--- a small neighbouring one, and the lighting would flip zones while the
--- player stood still. Containment has no such ambiguity, because modules do
--- not overlap by construction.
function LevelService.zoneAt(position: Vector3): string?
	local layout = currentLayout
	if layout == nil then
		return nil
	end
	for _, placed in layout.modules do
		local halfWidth, halfDepth = placed.width / 2, placed.depth / 2
		if
			position.X >= placed.at.x - halfWidth
			and position.X <= placed.at.x + halfWidth
			and position.Z >= placed.at.z - halfDepth
			and position.Z <= placed.at.z + halfDepth
		then
			return placed.zone
		end
	end
	return nil
end

--- Nearest waypoint to a world position, for entity pathing.
function LevelService.waypointAt(position: Vector3): number?
	local layout = currentLayout
	if layout == nil then
		return nil
	end
	return Path.nearestWaypoint(layout, { x = position.X, y = position.Y, z = position.Z })
end

--- Summary for the diagnostics bridge: enough to tell, from the command bar,
--- whether the level in the world matches the layout that was computed.
function LevelService.describe(): { [string]: any }
	local layout = currentLayout
	if layout == nil or root == nil then
		return { built = false }
	end

	local parts = 0
	for _, descendant in (root :: Folder):GetDescendants() do
		if descendant:IsA("BasePart") then
			parts += 1
		end
	end

	local perZone: { [string]: number } = {}
	for _, module_ in layout.modules do
		perZone[module_.zone] = (perZone[module_.zone] or 0) + 1
	end

	local padRows: { string } = {}
	for _, pad in layout.pads do
		local route = Path.find(layout, 1, pad.moduleIndex)
		table.insert(padRows, string.format(
			"%s: %d studs, %d hops, opens at %ds",
			pad.zone,
			if route then Path.length(layout, route) else -1,
			if route then #route else -1,
			Zones[pad.zone].padOpensAt
		))
	end

	return {
		built = true,
		seed = layout.seed,
		modules = #layout.modules,
		spine = layout.spineCount,
		branches = layout.branchCount,
		totalArea = layout.totalArea,
		targetArea = layout.targetArea,
		parts = parts,
		waypoints = #layout.waypoints,
		modulesPerZone = perZone,
		spawnPoints = {
			Perimeter = #LevelService.spawnPointsFor("Perimeter"),
			Processing = #LevelService.spawnPointsFor("Processing"),
			Vault = #LevelService.spawnPointsFor("Vault"),
		},
		pads = padRows,
		entrance = string.format("%s at (%d, %d)", layout.modules[1].id, layout.modules[1].at.x, layout.modules[1].at.z),
	}
end

return LevelService
