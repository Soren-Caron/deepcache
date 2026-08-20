--!strict
--[[ M6-2. core/economy/WriteBehindQueue -- coalescing, ordering, and the
	shutdown flush path, per the BACKLOG accept criteria.
]]

local t = require("./framework")
local expect = t.expect

local WBQ = require("../src/shared/core/economy/WriteBehindQueue")

t.describe("WriteBehindQueue.set / drain -- coalescing", function()
	t.it("multiple set() calls before a drain collapse into one write of the latest value", function()
		local state = WBQ.new(6)
		state = WBQ.set(state, "p1", 10)
		state = WBQ.set(state, "p1", 20)
		state = WBQ.set(state, "p1", 30)

		local _, out = WBQ.drain(state, 0)
		expect(#out).toEqual(1)
		expect(out[1].key).toEqual("p1")
		expect(out[1].value).toEqual(30)
	end)

	t.it("a brand-new key is due immediately -- there's no prior write to rate-limit against", function()
		local state = WBQ.new(6)
		state = WBQ.set(state, "p1", 100)
		local _, out = WBQ.drain(state, 0)
		expect(#out).toEqual(1)
	end)
end)

t.describe("WriteBehindQueue.drain -- ordering", function()
	t.it("due keys flush in the order they first went dirty", function()
		local state = WBQ.new(6)
		state = WBQ.set(state, "p1", "a")
		state = WBQ.set(state, "p2", "b")
		state = WBQ.set(state, "p3", "c")

		local _, out = WBQ.drain(state, 0)
		expect(#out).toEqual(3)
		expect(out[1].key).toEqual("p1")
		expect(out[2].key).toEqual("p2")
		expect(out[3].key).toEqual("p3")
	end)

	t.it("re-coalescing an already-dirty key does not move it in the flush order", function()
		local state = WBQ.new(6)
		state = WBQ.set(state, "p1", "a1")
		state = WBQ.set(state, "p2", "b1")
		state = WBQ.set(state, "p1", "a2") -- p1 updated again, after p2 went dirty

		local _, out = WBQ.drain(state, 0)
		expect(#out).toEqual(2)
		expect(out[1].key).toEqual("p1")
		expect(out[1].value).toEqual("a2") -- coalesced to the latest value
		expect(out[2].key).toEqual("p2")
	end)

	t.it("due-ness is not a prefix cut: a later key can become due before an earlier one", function()
		local state = WBQ.new(6)

		-- p1 is written and flushed at t=0 (next eligible at t=6).
		state = WBQ.set(state, "p1", "a1")
		local out1
		state, out1 = WBQ.drain(state, 0)
		expect(#out1).toEqual(1)

		-- p1 goes dirty again at t=0.5; p2 goes dirty (fresh, never written) at t=1.
		state = WBQ.set(state, "p1", "a2")
		state = WBQ.set(state, "p2", "b1")

		-- At t=2, p1 is still within its 6s cooldown but p2 has never been
		-- written, so p2 -- despite being queued *behind* p1 -- flushes first.
		local out2
		state, out2 = WBQ.drain(state, 2)
		expect(#out2).toEqual(1)
		expect(out2[1].key).toEqual("p2")
		expect(WBQ.pendingCount(state)).toEqual(1) -- p1 still queued

		-- At t=6.5, p1's cooldown (since its t=0 flush) has elapsed.
		local out3
		state, out3 = WBQ.drain(state, 6.5)
		expect(#out3).toEqual(1)
		expect(out3[1].key).toEqual("p1")
		expect(out3[1].value).toEqual("a2")
	end)
end)

t.describe("WriteBehindQueue.flushAll -- shutdown", function()
	t.it("returns every dirty key regardless of cooldown, and clears the queue", function()
		local state = WBQ.new(6)
		state = WBQ.set(state, "p1", "a")
		local out1
		state, out1 = WBQ.drain(state, 0) -- p1 flushed, next eligible at t=6
		expect(#out1).toEqual(1)

		state = WBQ.set(state, "p1", "a2") -- dirty again, nowhere near due
		state = WBQ.set(state, "p2", "b")

		local out2
		state, out2 = WBQ.flushAll(state)
		expect(#out2).toEqual(2)
		expect(out2[1].key).toEqual("p1")
		expect(out2[1].value).toEqual("a2")
		expect(out2[2].key).toEqual("p2")

		expect(WBQ.pendingCount(state)).toEqual(0)
		local out3
		state, out3 = WBQ.drain(state, 100)
		expect(#out3).toEqual(0)
	end)
end)
