--!strict
--[[ M1-10. Client-side render-delay buffer.

	Renders ~100ms in the past so a single dropped packet is invisible.
	Extrapolates at most 80ms past the newest snapshot, then freezes —
	beyond that, extrapolation reads as rubber-banding.
]]

local Types = require("../Types")

export type Sample = {
	pos: Types.Vec3,
	yaw: number,
	state: Types.EntityStateName,
	extrapolated: boolean,
}

local Interpolator = {}
Interpolator.__index = Interpolator

export type Interpolator = typeof(setmetatable({} :: {
	renderDelay: number,
	frames: { { time: number, entities: { Types.EntityView } } },
}, Interpolator))

Interpolator.RENDER_DELAY_MIN = 0.10
Interpolator.RENDER_DELAY_MAX = 0.20
Interpolator.EXTRAPOLATE_MAX = 0.08

function Interpolator.new(): Interpolator
	error("unimplemented: Interpolator.new (M1-10)")
end

--- Insert a received snapshot. Out-of-order arrivals are dropped.
function Interpolator.push(self: Interpolator, time: number, entities: { Types.EntityView })
	error("unimplemented: Interpolator.push (M1-10)")
end

--- Sample one entity at a render time. nil when the entity is unknown.
function Interpolator.sample(self: Interpolator, entityId: number, renderTime: number): Sample?
	error("unimplemented: Interpolator.sample (M1-10)")
end

--- Recompute render delay from observed jitter (p95 + 50ms margin, clamped).
function Interpolator.updateDelay(self: Interpolator, jitterP95: number): number
	error("unimplemented: Interpolator.updateDelay (M1-10)")
end

return Interpolator
