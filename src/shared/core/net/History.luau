--!strict
--[[
	Server-side hitbox history for lag compensation.

	The problem: a player shoots at what they *see*, which is the interpolation
	render delay (~100ms) plus their own latency behind server truth. Validating
	against the server's present makes moving targets unhittable; trusting the
	client's claimed hit makes aimbots trivial. So the server rewinds: it keeps
	a second of entity positions and re-runs the raycast against the world as it
	appeared to that shooter.

	The cost is paid by the victim — at high enough latency you can be shot after
	you believe you reached cover. LAGCOMP_WINDOW bounds how much of that
	unfairness is tolerated; beyond it the shot is validated against the oldest
	frame in the window instead, which favours the victim.

	Divergence from the stub signature: rewind returns a result table rather than
	a bare list. CombatService needs to know whether the requested time was
	clamped in order to emit the "rewind window overrun rate" metric named in
	docs/03-NETCODE.md §What gets measured, and threading that through a second
	return value made every call site awkward.
]]

local Types = require("../Types")
local Quantize = require("./Quantize")
local Ring = require("../util/Ring")

export type Frame = {
	tick: number,
	time: number,
	entities: { Types.EntityView },
}

export type RewindResult = {
	entities: { Types.EntityView },
	--- What the caller asked for, before clamping.
	requestedTime: number,
	--- What was actually used.
	actualTime: number,
	--- True when requestedTime fell outside the compensation window.
	clamped: boolean,
}

local History = {}
History.__index = History

export type History = typeof(setmetatable(
	{} :: {
		frames: Ring.Ring<Frame>,
		capacity: number,
		window: number,
	},
	History
))

History.DEFAULT_CAPACITY = 20
History.LAGCOMP_WINDOW = 0.25

function History.new(capacity: number?, window: number?): History
	local cap = capacity or History.DEFAULT_CAPACITY
	if cap < 2 then
		-- One frame cannot be interpolated between, which defeats the purpose.
		error(`History.new: capacity must be >= 2, got {cap}`, 2)
	end
	return setmetatable({
		frames = Ring.new(cap) :: Ring.Ring<Frame>,
		capacity = cap,
		window = window or History.LAGCOMP_WINDOW,
	}, History)
end

--- Record one tick. Entities are shallow-copied so later mutation of the live
--- simulation cannot retroactively rewrite history — the bug this prevents is
--- subtle and would make every rewind silently agree with the present.
function History.record(self: History, tick: number, time: number, entities: { Types.EntityView })
	local snapshot: { Types.EntityView } = table.create(#entities)
	for i, e in entities do
		snapshot[i] = {
			id = e.id,
			kind = e.kind,
			pos = { x = e.pos.x, y = e.pos.y, z = e.pos.z },
			yaw = e.yaw,
			state = e.state,
			hpPct = e.hpPct,
		}
	end
	Ring.push(self.frames, { tick = tick, time = time, entities = snapshot })
end

function History.frameCount(self: History): number
	return self.frames.count
end

function History.newestTime(self: History): number?
	local frame = Ring.newest(self.frames)
	return if frame then frame.time else nil
end

function History.oldestTime(self: History): number?
	local frame = Ring.oldest(self.frames)
	return if frame then frame.time else nil
end

function History.clear(self: History)
	Ring.clear(self.frames)
end

--------------------------------------------------------------------------------

local function lerpView(a: Types.EntityView, b: Types.EntityView, alpha: number): Types.EntityView
	return {
		id = a.id,
		pos = Types.lerpVec3(a.pos, b.pos, alpha),
		-- Shortest arc: naively lerping 350deg -> 10deg sweeps the long way.
		yaw = a.yaw + Quantize.yawDelta(a.yaw, b.yaw) * alpha,
		-- Discrete fields snap to the nearer frame; a half-dead entity or a
		-- half-attacking one is not a meaningful thing to hit.
		state = if alpha < 0.5 then a.state else b.state,
		hpPct = a.hpPct + (b.hpPct - a.hpPct) * alpha,
	}
end

local function byId(entities: { Types.EntityView }): { [number]: Types.EntityView }
	local map: { [number]: Types.EntityView } = {}
	for _, e in entities do
		map[e.id] = e
	end
	return map
end

--- Blend two frames. Entities present in only one frame are carried through
--- unchanged: an entity that spawned or despawned mid-window was still visible
--- to the shooter for part of it, and refusing to include it would silently
--- eat legitimate hits.
local function blend(a: Frame, b: Frame, alpha: number): { Types.EntityView }
	local aById = byId(a.entities)
	local out: { Types.EntityView } = {}
	local seen: { [number]: boolean } = {}

	for _, newer in b.entities do
		seen[newer.id] = true
		local older = aById[newer.id]
		out[#out + 1] = if older then lerpView(older, newer, alpha) else newer
	end
	for _, older in a.entities do
		if not seen[older.id] then
			out[#out + 1] = older
		end
	end

	return out
end

--- Entity positions as of `targetTime`.
---
--- `targetTime` is clamped to [now - window, now]. Returns nil only when no
--- frames have been recorded at all.
function History.rewind(self: History, targetTime: number, now: number): RewindResult?
	local count = self.frames.count
	if count == 0 then
		return nil
	end

	local earliest = now - self.window
	local actual = math.clamp(targetTime, earliest, now)
	local clamped = actual ~= targetTime

	-- Ring is newest-first: age 1 is the newest frame.
	local newest = Ring.get(self.frames, 1) :: Frame
	if actual >= newest.time then
		-- The server does not extrapolate forward; the present is authoritative.
		return {
			entities = newest.entities,
			requestedTime = targetTime,
			actualTime = newest.time,
			clamped = clamped,
		}
	end

	local oldest = Ring.get(self.frames, count) :: Frame
	if actual <= oldest.time then
		-- Ran off the back of the buffer. Report it as clamped so the caller
		-- can count it: a high rate here means the buffer is too short for the
		-- population's latency, which is a tuning signal, not a bug to hide.
		return {
			entities = oldest.entities,
			requestedTime = targetTime,
			actualTime = oldest.time,
			clamped = true,
		}
	end

	-- Walk newest -> oldest for the bracketing pair. At 20 frames this is
	-- cheaper than a binary search and branch-free in the common case, where
	-- the target is only a few ticks back.
	for age = 1, count - 1 do
		local newer = Ring.get(self.frames, age) :: Frame
		local older = Ring.get(self.frames, age + 1) :: Frame
		if actual >= older.time and actual <= newer.time then
			local span = newer.time - older.time
			local alpha = if span > 1e-9 then (actual - older.time) / span else 0
			return {
				entities = blend(older, newer, alpha),
				requestedTime = targetTime,
				actualTime = actual,
				clamped = clamped,
			}
		end
	end

	-- Unreachable given the bounds checks above, but returning the newest frame
	-- is the safe fallback if frame times ever arrive out of order.
	return {
		entities = newest.entities,
		requestedTime = targetTime,
		actualTime = newest.time,
		clamped = true,
	}
end

return History
