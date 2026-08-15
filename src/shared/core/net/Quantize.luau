--!strict
--[[ M1-1. Fixed-point encoding for the snapshot wire format.

	Positions ride as int16 on a 0.05-stud grid (±1638 studs), yaw as uint8
	(256 steps), hp as uint8. See docs/03-NETCODE.md §Wire format.
]]

local Quantize = {}

Quantize.POSITION_GRID = 0.05
Quantize.POSITION_MIN = -1638.0
Quantize.POSITION_MAX = 1638.0

--- Stud offset from level origin -> int16.
function Quantize.encodePosition(value: number): number
	error("unimplemented: Quantize.encodePosition (M1-1)")
end

function Quantize.decodePosition(encoded: number): number
	error("unimplemented: Quantize.decodePosition (M1-1)")
end

--- Radians in [0, 2pi) -> uint8.
function Quantize.encodeYaw(radians: number): number
	error("unimplemented: Quantize.encodeYaw (M1-1)")
end

function Quantize.decodeYaw(encoded: number): number
	error("unimplemented: Quantize.decodeYaw (M1-1)")
end

--- Fraction in [0, 1] -> uint8.
function Quantize.encodeUnit(value: number): number
	error("unimplemented: Quantize.encodeUnit (M1-1)")
end

function Quantize.decodeUnit(encoded: number): number
	error("unimplemented: Quantize.decodeUnit (M1-1)")
end

return Quantize
