--!strict
--[[
	Client-side render-delay buffer.

	The client renders entities ~100ms in the past. That deliberate lag is what
	makes a dropped 20Hz packet invisible: the next one arrives 50ms later and
	there is still a future frame to interpolate toward. Rendering at the newest
	received position instead would stutter on every lost packet.

	Past the newest frame the buffer extrapolates along last-known velocity for
	at most EXTRAPOLATE_MAX, then freezes. Extrapolating further looks like
	rubber-banding — the entity confidently walks into a wall and snaps back —
	and freezing is the less dishonest failure.

	Render delay adapts to observed jitter: a client on a bad connection trades
	a little responsiveness for smoothness automatically.
]]

local Types = require("../Types")
local Quantize = require("./Quantize")

export type Sample = {
	pos: Types.Vec3,
	yaw: number,
	state: Types.EntityStateName,
	--- True when the sample is beyond the newest received frame, so the
	--- renderer can fade or flag it if desired.
	extrapolated: boolean,
}

type Frame = {
	time: number,
	byId: { [number]: Types.EntityView },
	ids: { number },
}

local Interpolator = {}
Interpolator.__index = Interpolator

export type Interpolator = typeof(setmetatable(
	{} :: {
		frames: { Frame },
		renderDelay: number,
		retention: number,
		arrivals: { number },
		lastArrival: number?,
	},
	Interpolator
))

Interpolator.RENDER_DELAY_MIN = 0.10
Interpolator.RENDER_DELAY_MAX = 0.20
Interpolator.EXTRAPOLATE_MAX = 0.08
Interpolator.JITTER_MARGIN = 0.05
Interpolator.RETENTION = 1.0
Interpolator.JITTER_SAMPLES = 60

function Interpolator.new(): Interpolator
	return setmetatable({
		frames = {},
		renderDelay = Interpolator.RENDER_DELAY_MIN,
		retention = Interpolator.RETENTION,
		arrivals = {},
		lastArrival = nil,
	}, Interpolator)
end

--------------------------------------------------------------------------------

--- Insert a received snapshot. Returns false when the frame was rejected.
---
--- Out-of-order arrivals are dropped rather than sorted in. On an unreliable
--- channel a late packet is stale by definition, and splicing it behind the
--- newest frame would make an entity visibly step backwards.
function Interpolator.push(self: Interpolator, time: number, entities: { Types.EntityView }): boolean
	local newest = self.frames[#self.frames]
	if newest ~= nil and time <= newest.time then
		return false
	end

	local byId: { [number]: Types.EntityView } = {}
	local ids: { number } = table.create(#entities)
	for i, e in entities do
		byId[e.id] = e
		ids[i] = e.id
	end
	table.insert(self.frames, { time = time, byId = byId, ids = ids })

	-- Trim frames older than the retention window, always keeping enough to
	-- interpolate and to derive a velocity.
	local cutoff = time - self.retention
	while #self.frames > 3 and self.frames[1].time < cutoff do
		table.remove(self.frames, 1)
	end

	return true
end

--- Record packet arrival wall-time, for jitter estimation.
function Interpolator.observeArrival(self: Interpolator, arrivalTime: number)
	local previous = self.lastArrival
	self.lastArrival = arrivalTime
	if previous == nil then
		return
	end
	table.insert(self.arrivals, arrivalTime - previous)
	if #self.arrivals > Interpolator.JITTER_SAMPLES then
		table.remove(self.arrivals, 1)
	end
end

--- p95 deviation of inter-arrival time from the expected tick interval.
function Interpolator.jitterP95(self: Interpolator, expectedInterval: number): number
	local count = #self.arrivals
	if count < 4 then
		return 0
	end
	local deviations: { number } = table.create(count)
	for i, gap in self.arrivals do
		deviations[i] = math.abs(gap - expectedInterval)
	end
	table.sort(deviations)
	local index = math.clamp(math.ceil(count * 0.95), 1, count)
	return deviations[index]
end

--- Recompute render delay from observed jitter. Clamped to
--- [RENDER_DELAY_MIN, RENDER_DELAY_MAX].
function Interpolator.updateDelay(self: Interpolator, jitterP95: number): number
	local target = math.max(Interpolator.RENDER_DELAY_MIN, jitterP95 + Interpolator.JITTER_MARGIN)
	self.renderDelay = math.clamp(target, Interpolator.RENDER_DELAY_MIN, Interpolator.RENDER_DELAY_MAX)
	return self.renderDelay
end

function Interpolator.newestTime(self: Interpolator): number?
	local newest = self.frames[#self.frames]
	return if newest then newest.time else nil
end

function Interpolator.frameCount(self: Interpolator): number
	return #self.frames
end

--- Entity ids present in the newest frame — what the renderer should draw.
function Interpolator.knownIds(self: Interpolator): { number }
	local newest = self.frames[#self.frames]
	return if newest then newest.ids else {}
end

--------------------------------------------------------------------------------

local function toSample(view: Types.EntityView, extrapolated: boolean): Sample
	return {
		pos = { x = view.pos.x, y = view.pos.y, z = view.pos.z },
		yaw = view.yaw,
		state = view.state,
		extrapolated = extrapolated,
	}
end

--- Newest-first search for the two most recent frames containing `entityId`.
local function lastTwoContaining(self: Interpolator, entityId: number): (Frame?, Frame?)
	local newer: Frame? = nil
	for i = #self.frames, 1, -1 do
		local frame = self.frames[i]
		if frame.byId[entityId] ~= nil then
			if newer == nil then
				newer = frame
			else
				return self.frames[i], newer
			end
		end
	end
	return nil, newer
end

--- Sample one entity at a render time. nil when the entity is unknown.
function Interpolator.sample(self: Interpolator, entityId: number, renderTime: number): Sample?
	local count = #self.frames
	if count == 0 then
		return nil
	end

	local newest = self.frames[count]
	local oldest = self.frames[1]

	-- Ahead of the newest frame: extrapolate, then freeze.
	if renderTime > newest.time then
		local current = newest.byId[entityId]
		if current == nil then
			return nil
		end

		local older, newer = lastTwoContaining(self, entityId)
		if older == nil or newer == nil then
			return toSample(current, true)
		end

		local span = newer.time - older.time
		if span <= 1e-9 then
			return toSample(current, true)
		end

		local a = older.byId[entityId] :: Types.EntityView
		local b = newer.byId[entityId] :: Types.EntityView
		-- Freeze at the cap rather than continuing to advance.
		local dt = math.min(renderTime - newer.time, Interpolator.EXTRAPOLATE_MAX)
		local scale = dt / span

		return {
			pos = {
				x = b.pos.x + (b.pos.x - a.pos.x) * scale,
				y = b.pos.y + (b.pos.y - a.pos.y) * scale,
				z = b.pos.z + (b.pos.z - a.pos.z) * scale,
			},
			yaw = b.yaw + Quantize.yawDelta(a.yaw, b.yaw) * scale,
			state = b.state,
			extrapolated = true,
		}
	end

	-- Behind the oldest retained frame: clamp.
	if renderTime <= oldest.time then
		local view = oldest.byId[entityId]
		return if view then toSample(view, false) else nil
	end

	-- Find the bracketing pair.
	for i = count, 2, -1 do
		local newerFrame = self.frames[i]
		local olderFrame = self.frames[i - 1]
		if renderTime >= olderFrame.time and renderTime <= newerFrame.time then
			local a = olderFrame.byId[entityId]
			local b = newerFrame.byId[entityId]

			-- Present in only one of the pair: no pair to blend, so take what
			-- exists rather than dropping the entity for a frame and making it
			-- flicker.
			if a == nil and b == nil then
				return nil
			elseif a == nil then
				return toSample(b :: Types.EntityView, false)
			elseif b == nil then
				return toSample(a, false)
			end

			local span = newerFrame.time - olderFrame.time
			local alpha = if span > 1e-9 then (renderTime - olderFrame.time) / span else 0

			return {
				pos = Types.lerpVec3(a.pos, b.pos, alpha),
				yaw = a.yaw + Quantize.yawDelta(a.yaw, b.yaw) * alpha,
				-- Discrete: snap to the nearer frame rather than blending.
				state = if alpha < 0.5 then a.state else b.state,
				extrapolated = false,
			}
		end
	end

	return nil
end

return Interpolator
