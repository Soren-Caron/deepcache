--!strict
--[[
	Injected time source.

	Pure-core code may never read a clock — `os.time`, `os.clock`, and
	`tick()` are all banned inside core/. Time arrives as a value so that
	simulations replay deterministically and tests can drive time forward
	without sleeping.

	Adapters construct a Clock backed by the real engine clock; tests
	construct a manual one and step it.
]]

local Clock = {}
Clock.__index = Clock

export type Clock = typeof(setmetatable(
	{} :: {
		now: number,
		source: (() -> number)?,
	},
	Clock
))

--- A clock the caller advances by hand. The only kind valid inside core/.
function Clock.manual(startAt: number?): Clock
	return setmetatable({ now = startAt or 0, source = nil }, Clock)
end

--- A clock backed by a real time source. Adapters only.
function Clock.fromSource(source: () -> number): Clock
	return setmetatable({ now = source(), source = source }, Clock)
end

function Clock.get(self: Clock): number
	if self.source then
		self.now = (self.source :: () -> number)()
	end
	return self.now
end

--- Advance a manual clock. Errors on a source-backed clock, since silently
--- ignoring the call would make a test look like it was driving time when it
--- was not.
function Clock.advance(self: Clock, seconds: number): number
	if self.source then
		error("Clock.advance: cannot advance a source-backed clock", 2)
	end
	if seconds < 0 then
		error(`Clock.advance: seconds must be >= 0, got {seconds}`, 2)
	end
	self.now += seconds
	return self.now
end

function Clock.set(self: Clock, seconds: number)
	if self.source then
		error("Clock.set: cannot set a source-backed clock", 2)
	end
	self.now = seconds
end

return Clock
