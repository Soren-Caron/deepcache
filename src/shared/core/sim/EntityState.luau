--!strict
--[[ M1-4. Entity struct and state machine. ]]

local Types = require("../Types")

local EntityState = {}

--- Legal state transitions. Anything not listed here is rejected.
local TRANSITIONS: { [Types.EntityStateName]: { Types.EntityStateName } } = {
	spawn = { "idle", "move" },
	idle = { "move", "attack", "stagger", "death" },
	move = { "idle", "attack", "stagger", "death" },
	attack = { "idle", "move", "stagger", "death" },
	stagger = { "idle", "move", "death" },
	death = {},
}

EntityState.TRANSITIONS = TRANSITIONS

function EntityState.create(id: number, kind: Types.EntityKind, pos: Types.Vec3, tick: number): Types.Entity
	error("unimplemented: EntityState.create (M1-4)")
end

function EntityState.canTransition(from: Types.EntityStateName, to: Types.EntityStateName): boolean
	error("unimplemented: EntityState.canTransition (M1-4)")
end

function EntityState.transition(entity: Types.Entity, to: Types.EntityStateName): boolean
	error("unimplemented: EntityState.transition (M1-4)")
end

--- Strip a full entity down to its replicated view.
function EntityState.toView(entity: Types.Entity): Types.EntityView
	error("unimplemented: EntityState.toView (M1-4)")
end

return EntityState
