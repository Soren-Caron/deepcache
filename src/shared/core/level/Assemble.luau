--!strict
--[[ M2-1. Seeded level assembly from authored room modules.

	Not noise-generated terrain: a graph walk over hand-authored modules with
	tagged connectors. Constraints (all pads reachable, no module repeated
	within 2 hops, area within +/-15% of target) are checked, not hoped for.
]]

local Types = require("../Types")
local Rng = require("../util/Rng")

export type Connector = { face: "N" | "S" | "E" | "W", size: "small" | "large" }

export type ModuleDef = {
	id: string,
	zone: Types.Zone,
	connectors: { Connector },
	area: number,
	hasPad: boolean,
}

export type PlacedModule = {
	id: string,
	at: Types.Vec3,
	rotation: number,
	hop: number,
}

export type Layout = {
	seed: number,
	modules: { PlacedModule },
	padPositions: { Types.Vec3 },
	waypoints: { { id: number, at: Types.Vec3, links: { number } } },
	totalArea: number,
}

local Assemble = {}

Assemble.SPINE_MIN = 8
Assemble.SPINE_MAX = 12
Assemble.BRANCH_MIN = 4
Assemble.BRANCH_MAX = 6
Assemble.AREA_TOLERANCE = 0.15
Assemble.NO_REPEAT_WITHIN_HOPS = 2

function Assemble.generate(seed: number, catalogue: { ModuleDef }, targetArea: number): Layout
	error("unimplemented: Assemble.generate (M2-1)")
end

--- Verify a layout meets every constraint. Returns false plus the first
--- violation, so a bad module catalogue fails loudly instead of shipping.
function Assemble.validate(layout: Layout, targetArea: number): (boolean, string?)
	error("unimplemented: Assemble.validate (M2-1)")
end

--- Coarse waypoint graph for entity pathing, built at assembly time.
function Assemble.buildNavGraph(layout: Layout): Layout
	error("unimplemented: Assemble.buildNavGraph (M2-1)")
end

return Assemble
