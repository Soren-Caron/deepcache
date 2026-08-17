--!strict
--[[
	Fixed-capacity circular buffer.

	Backs the lag-compensation history buffer (20 ticks of entity state) and
	the telemetry event buffer. Writing past capacity overwrites the oldest
	entry rather than growing — bounded memory is the whole point.
]]

local Ring = {}
Ring.__index = Ring

export type Ring<T> = typeof(setmetatable(
	{} :: {
		items: { T },
		capacity: number,
		count: number,
		head: number, -- index of the next write slot, 1-based
	},
	Ring
))

function Ring.new<T>(capacity: number): Ring<T>
	if capacity < 1 then
		error(`Ring.new: capacity must be >= 1, got {capacity}`, 2)
	end
	return setmetatable({
		items = {},
		capacity = capacity,
		count = 0,
		head = 1,
	}, Ring)
end

--- Append, overwriting the oldest entry when full.
--- Returns the evicted value, or nil if nothing was evicted.
function Ring.push<T>(self: Ring<T>, value: T): T?
	local evicted: T? = nil
	if self.count == self.capacity then
		evicted = self.items[self.head]
	else
		self.count += 1
	end
	self.items[self.head] = value
	self.head = (self.head % self.capacity) + 1
	return evicted
end

--- Remove and return the oldest entry, FIFO. nil when empty.
---
--- The history buffer only ever reads by age, but the telemetry buffer drains
--- oldest-first into a batch, and re-reading then clearing would lose anything
--- pushed in between. `head` is the write pointer and does not move.
function Ring.shift<T>(self: Ring<T>): T?
	if self.count == 0 then
		return nil
	end
	local index = self.head - self.count
	if index < 1 then
		index += self.capacity
	end
	local value = self.items[index]
	self.items[index] = nil
	self.count -= 1
	return value
end

--- Age-indexed read: 1 is the newest, `count` is the oldest. nil out of range.
function Ring.get<T>(self: Ring<T>, age: number): T?
	if age < 1 or age > self.count then
		return nil
	end
	local index = self.head - age
	if index < 1 then
		index += self.capacity
	end
	return self.items[index]
end

function Ring.newest<T>(self: Ring<T>): T?
	return Ring.get(self, 1)
end

function Ring.oldest<T>(self: Ring<T>): T?
	return Ring.get(self, self.count)
end

--- Newest-first list. Allocates; not for the hot path.
function Ring.toList<T>(self: Ring<T>): { T }
	local out: { T } = {}
	for age = 1, self.count do
		out[age] = Ring.get(self, age) :: T
	end
	return out
end

function Ring.clear<T>(self: Ring<T>)
	self.items = {}
	self.count = 0
	self.head = 1
end

function Ring.isFull<T>(self: Ring<T>): boolean
	return self.count == self.capacity
end

return Ring
