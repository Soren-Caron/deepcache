--!strict
--[[ M7-7. Palette ramps: the pixel data written into an `EditableImage`.

	A ramp is a list of colour stops at positions in [0,1]; sampling it gives
	the colour at any point between. `LookController` turns a ramp into actual
	pixels; everything about *what* those pixels are lives here, where it can
	be tested without holding one of the eight scarce EditableImage instances.

	Colours are plain {r,g,b} tables in [0,1] rather than Color3, because
	Color3 is a Roblox type and this has to run under Lune.

	Stops are required to be sorted and in range at construction rather than
	sorted on the fly at every sample. A ramp is built once and sampled per
	pixel -- for a 256-wide ramp that is 256 samples per regeneration, and
	re-validating the stop list on each one is work that buys nothing.
]]

local Ramp = {}

export type Color = { r: number, g: number, b: number }
export type Stop = { position: number, color: Color }
export type Ramp = { stops: { Stop } }

local function clamp01(value: number): number
	if value ~= value then -- NaN
		return 0
	end
	return math.clamp(value, 0, 1)
end

function Ramp.color(r: number, g: number, b: number): Color
	return { r = clamp01(r), g = clamp01(g), b = clamp01(b) }
end

--- Build a ramp. Errors on an empty or unsorted stop list: both are
--- programmer error rather than bad runtime data, and a silently re-sorted
--- ramp hides an authoring mistake that would otherwise be obvious.
function Ramp.new(stops: { Stop }): Ramp
	if #stops == 0 then
		error("Ramp.new: needs at least one stop", 2)
	end
	local previous = -math.huge
	for index, stop in stops do
		if stop.position < 0 or stop.position > 1 then
			error(`Ramp.new: stop {index} position {stop.position} outside [0,1]`, 2)
		end
		if stop.position < previous then
			error(`Ramp.new: stop {index} at {stop.position} is before the previous stop`, 2)
		end
		previous = stop.position
	end
	return { stops = stops }
end

--- Colour at `t`. Clamps outside [0,1] rather than extrapolating: a ramp has
--- endpoints, and continuing the last gradient past them produces colours the
--- palette never contained.
function Ramp.sample(ramp: Ramp, t: number): Color
	local stops = ramp.stops
	local position = clamp01(t)

	if position <= stops[1].position then
		return stops[1].color
	end
	local last = stops[#stops]
	if position >= last.position then
		return last.color
	end

	-- The *last* stop at or before `position`, not the first segment that
	-- happens to contain it. Coincident stops are a legitimate way to author a
	-- hard edge in a palette, and scanning forward for the first containing
	-- segment resolves an exact hit on the edge to the colour *before* it --
	-- so the edge appears one sample late and the new colour never renders at
	-- its own stop position. Taking the last match puts the edge exactly where
	-- it was authored.
	local lower = 1
	for index = 1, #stops do
		if stops[index].position <= position then
			lower = index
		else
			break
		end
	end

	local a = stops[lower]
	local b = stops[lower + 1]
	if b == nil then
		return a.color
	end
	local span = b.position - a.position
	if span <= 0 then
		return a.color
	end
	local alpha = (position - a.position) / span
	return {
		r = a.color.r + (b.color.r - a.color.r) * alpha,
		g = a.color.g + (b.color.g - a.color.g) * alpha,
		b = a.color.b + (b.color.b - a.color.b) * alpha,
	}
end

--- Flatten to `width` evenly spaced samples, which is what gets written into
--- an EditableImage row. The first sample is exactly t=0 and the last exactly
--- t=1, so the ramp's authored endpoints survive rasterisation -- an
--- off-by-one here shows up as a palette that never quite reaches its own
--- darkest or brightest colour.
function Ramp.rasterize(ramp: Ramp, width: number): { Color }
	if width < 1 then
		error(`Ramp.rasterize: width must be >= 1, got {width}`, 2)
	end
	local out: { Color } = table.create(width)
	if width == 1 then
		out[1] = Ramp.sample(ramp, 0)
		return out
	end
	for i = 1, width do
		out[i] = Ramp.sample(ramp, (i - 1) / (width - 1))
	end
	return out
end

--- Entity damage-state ramp: healthy through hurt to critical. Allocation #2
--- in docs/08's EditableImage table.
function Ramp.damageState(): Ramp
	return Ramp.new({
		{ position = 0.0, color = Ramp.color(0.85, 0.16, 0.16) }, -- critical
		{ position = 0.5, color = Ramp.color(0.92, 0.72, 0.24) }, -- hurt
		{ position = 1.0, color = Ramp.color(0.62, 0.78, 0.68) }, -- healthy
	})
end

--- Threat-tier gradient for the comms panel. Allocation #3.
function Ramp.threatTier(): Ramp
	return Ramp.new({
		{ position = 0.0, color = Ramp.color(0.80, 0.86, 0.92) },
		{ position = 0.5, color = Ramp.color(0.92, 0.82, 0.62) },
		{ position = 1.0, color = Ramp.color(1.00, 0.47, 0.39) },
	})
end

return Ramp
