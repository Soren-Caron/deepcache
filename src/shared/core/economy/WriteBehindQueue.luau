--!strict
--[[ M6-2. Pure coalescing write-behind queue.

	DataService (the Roblox adapter) is a thin wrapper around this: `set()`
	on every balance change, `drain()` on a timer, hand the returned pairs
	to `SetAsync`. This module never touches DataStore -- it just decides
	*what* to write and *when*, which is the part worth unit-testing without
	Studio.

	Coalescing: multiple `set()` calls for the same key between drains
	collapse into a single write of the latest value -- exactly what
	"≤1 write per player per 6s" requires, since DataStore per-key write
	limits don't care how many times the value changed in between.

	Ordering: a key's place in the flush order is fixed by when it *first*
	went dirty (or was last flushed), not reset every time `set()` coalesces
	a newer value in. Resetting position on every update would let a
	frequently-updated key's write get pushed back indefinitely, which
	defeats the point of a periodic-write guarantee. Because different keys
	become individually due at different times (a key untouched since its
	last flush becomes due again 6s later, independent of when other keys
	were queued), "due" entries are not always a prefix of the queue --
	`drain` does a stable filter over the whole thing, not a prefix cut.

	`flushAll` is the shutdown path: it ignores the 6s cooldown entirely and
	returns every dirty key, because a value queued but not yet due when the
	server goes down must still be written or it's lost.
]]

local WriteBehindQueue = {}

WriteBehindQueue.DEFAULT_INTERVAL_SECONDS = 6

export type QueueState<V> = {
	order: { string }, -- dirty keys, oldest-due-position first
	pending: { [string]: V }, -- key -> latest not-yet-written value
	lastWriteTs: { [string]: number }, -- key -> when it was last actually flushed
	intervalSeconds: number,
}

function WriteBehindQueue.new<V>(intervalSeconds: number?): QueueState<V>
	return {
		order = {},
		pending = {},
		lastWriteTs = {},
		intervalSeconds = intervalSeconds or WriteBehindQueue.DEFAULT_INTERVAL_SECONDS,
	}
end

--- Record (or coalesce) a value for `key`. Does not change `key`'s position
--- in the flush order if it was already dirty.
function WriteBehindQueue.set<V>(state: QueueState<V>, key: string, value: V): QueueState<V>
	if state.pending[key] == nil then
		table.insert(state.order, key)
	end
	state.pending[key] = value
	return state
end

local function isDue<V>(state: QueueState<V>, key: string, nowTs: number): boolean
	local last = state.lastWriteTs[key]
	return last == nil or nowTs - last >= state.intervalSeconds
end

--- Pull out every dirty key that's due (never written, or >= intervalSeconds
--- since its last flush), in the order they originally went dirty. Keys not
--- yet due stay queued, in their original relative order, for a later call.
function WriteBehindQueue.drain<V>(state: QueueState<V>, nowTs: number): (QueueState<V>, { { key: string, value: V } })
	local out: { { key: string, value: V } } = {}
	local remaining: { string } = {}

	for _, key in state.order do
		if isDue(state, key, nowTs) then
			table.insert(out, { key = key, value = state.pending[key] })
			state.pending[key] = nil
			state.lastWriteTs[key] = nowTs
		else
			table.insert(remaining, key)
		end
	end

	state.order = remaining
	return state, out
end

--- Shutdown path: every dirty key, cooldown ignored, in flush order.
function WriteBehindQueue.flushAll<V>(state: QueueState<V>): (QueueState<V>, { { key: string, value: V } })
	local out: { { key: string, value: V } } = {}
	for _, key in state.order do
		table.insert(out, { key = key, value = state.pending[key] })
		state.pending[key] = nil
		state.lastWriteTs[key] = nil
	end
	state.order = {}
	return state, out
end

--- Diagnostic / testing: how many keys are currently dirty (written or not).
function WriteBehindQueue.pendingCount<V>(state: QueueState<V>): number
	return #state.order
end

return WriteBehindQueue
