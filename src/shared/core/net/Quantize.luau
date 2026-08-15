--!strict
--[[
	Fixed-point encoding for the snapshot wire format.

	The whole snapshot design hangs off a hard constraint: UnreliableRemoteEvent
	silently drops payloads over ~1000 bytes, so an entity record has an 11-byte
	budget. Floats do not fit. See docs/03-NETCODE.md §Wire format.

	  position  int16 on a 0.05-stud grid   -> +/-1638 studs, max error 0.025
	  yaw       uint8, 256 steps            -> max error 0.703 degrees
	  unit      uint8, 0..1 mapped to 0..255 -> max error 0.00196

	Both error bounds are below perceptual threshold at gameplay distances, and
	both are asserted in tests rather than assumed.

	Encoding saturates rather than wrapping. A position beyond the representable
	range is a bug elsewhere (an entity escaped the level), and clamping keeps it
	visible at the boundary instead of teleporting it to the opposite corner,
	which is what int16 overflow would do.
]]

local Quantize = {}

local TAU = math.pi * 2

local INT16_MIN = -32768
local INT16_MAX = 32767
local UINT8_MAX = 255
local YAW_STEPS = 256

Quantize.POSITION_GRID = 0.05
Quantize.POSITION_MIN = INT16_MIN * 0.05 -- -1638.4
Quantize.POSITION_MAX = INT16_MAX * 0.05 -- 1638.35

--- Worst-case roundtrip error, half a step in each case. Tests assert against
--- these rather than hardcoding literals in two places.
Quantize.POSITION_MAX_ERROR = 0.05 / 2
Quantize.YAW_MAX_ERROR = TAU / (YAW_STEPS * 2)
Quantize.UNIT_MAX_ERROR = 1 / (UINT8_MAX * 2)

local function clamp(value: number, min: number, max: number): number
	if value < min then
		return min
	elseif value > max then
		return max
	end
	return value
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

--- Stud offset from the level origin -> int16.
function Quantize.encodePosition(value: number): number
	-- NaN would round to something arbitrary and then serialise silently.
	if value ~= value then
		error("Quantize.encodePosition: value is NaN", 2)
	end
	local steps = math.round(value / Quantize.POSITION_GRID)
	return clamp(steps, INT16_MIN, INT16_MAX)
end

function Quantize.decodePosition(encoded: number): number
	return encoded * Quantize.POSITION_GRID
end

--- The value as it will survive a roundtrip. Delta compression compares
--- quantized values, not raw floats: two positions a micrometre apart encode
--- identically, and re-sending them would waste the byte budget.
function Quantize.snapPosition(value: number): number
	return Quantize.decodePosition(Quantize.encodePosition(value))
end

--------------------------------------------------------------------------------
-- Yaw
--------------------------------------------------------------------------------

--- Radians -> uint8. Any input angle is accepted; it wraps into [0, 2pi).
function Quantize.encodeYaw(radians: number): number
	if radians ~= radians then
		error("Quantize.encodeYaw: radians is NaN", 2)
	end
	-- Lua's % takes the sign of the divisor, so negatives wrap correctly.
	local normalized = radians % TAU
	local steps = math.round(normalized / TAU * YAW_STEPS)
	-- A value just below 2pi rounds up to YAW_STEPS, which is 0 after wrapping.
	return steps % YAW_STEPS
end

function Quantize.decodeYaw(encoded: number): number
	return (encoded % YAW_STEPS) / YAW_STEPS * TAU
end

function Quantize.snapYaw(radians: number): number
	return Quantize.decodeYaw(Quantize.encodeYaw(radians))
end

--------------------------------------------------------------------------------
-- Unit interval (hp fraction, charge, ramp)
--------------------------------------------------------------------------------

function Quantize.encodeUnit(value: number): number
	if value ~= value then
		error("Quantize.encodeUnit: value is NaN", 2)
	end
	return math.round(clamp(value, 0, 1) * UINT8_MAX)
end

function Quantize.decodeUnit(encoded: number): number
	return clamp(encoded, 0, UINT8_MAX) / UINT8_MAX
end

function Quantize.snapUnit(value: number): number
	return Quantize.decodeUnit(Quantize.encodeUnit(value))
end

--------------------------------------------------------------------------------

--- Smallest signed difference between two angles, in (-pi, pi].
--- Interpolation must take the short way round: lerping 350deg -> 10deg
--- naively sweeps backwards through 180deg.
function Quantize.yawDelta(from: number, to: number): number
	local delta = (to - from) % TAU
	if delta > math.pi then
		delta -= TAU
	end
	return delta
end

return Quantize
