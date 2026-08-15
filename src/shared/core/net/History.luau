--!strict
--[[ M1-5. Server-side hitbox history for lag compensation.

	Keeps 1 second (20 ticks) of entity positions so a fire request can be
	validated against what the shooter actually saw. See docs/03-NETCODE.md
	§Lag compensation.
]]

local Types = require("../Types")

export type Frame = {
	tick: number,
	time: number,
	entities: { Types.EntityView },
}

local History = {}
History.__index = History

export type History = typeof(setmetatable({} :: {
	capacity: number,
}, History))

History.DEFAULT_CAPACITY = 20
History.LAGCOMP_WINDOW = 0.25

function History.new(capacity: number?): History
	error("unimplemented: History.new (M1-5)")
end

function History.record(self: History, tick: number, time: number, entities: { Types.EntityView })
	error("unimplemented: History.record (M1-5)")
end

--- Entity positions as of `targetTime`, interpolated between recorded frames.
--- `targetTime` is clamped to [now - LAGCOMP_WINDOW, now]; returns nil only
--- when the buffer holds no usable frames at all.
function History.rewind(self: History, targetTime: number, now: number): { Types.EntityView }?
	error("unimplemented: History.rewind (M1-5)")
end

return History
