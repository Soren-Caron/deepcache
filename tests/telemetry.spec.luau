--!strict
--[[ M3-1. Telemetry ring buffer.

	The buffer's job is to never be the reason the game stops, so the tests are
	mostly about what it does when things go wrong: full, backend down, batch
	failed, retried.
]]

local t = require("./framework")
local expect = t.expect

local Buffer = require("../src/shared/core/telemetry/Buffer")
local Ring = require("../src/shared/core/util/Ring")

local CONTEXT = { runId = "run-1", serverId = "job-abc", placeId = 1234, pid = "a3f9" }

local function push(buffer: Buffer.Buffer, eventType: string, now: number?): Buffer.Envelope
	return Buffer.push(buffer, eventType, { value = 1 }, CONTEXT, now or 0)
end

--------------------------------------------------------------------------------

t.describe("Ring.shift", function()
	t.it("removes oldest first and leaves the rest in order", function()
		local ring = Ring.new(4)
		for _, value in { "a", "b", "c" } do
			Ring.push(ring, value)
		end
		expect(Ring.shift(ring)).toEqual("a")
		expect(Ring.shift(ring)).toEqual("b")
		expect(ring.count).toEqual(1)
		expect(Ring.shift(ring)).toEqual("c")
		expect(Ring.shift(ring)).toBeNil()
		expect(ring.count).toEqual(0)
	end)

	t.it("keeps order when pushes and shifts interleave across the wrap", function()
		local ring = Ring.new(3)
		Ring.push(ring, 1)
		Ring.push(ring, 2)
		Ring.push(ring, 3)
		expect(Ring.shift(ring)).toEqual(1)
		Ring.push(ring, 4) -- wraps into the freed slot
		expect(Ring.shift(ring)).toEqual(2)
		expect(Ring.shift(ring)).toEqual(3)
		expect(Ring.shift(ring)).toEqual(4)
	end)

	t.it("leaves an overwritten ring reading oldest-first", function()
		local ring = Ring.new(3)
		for value = 1, 5 do
			Ring.push(ring, value) -- 1 and 2 are overwritten
		end
		expect(Ring.shift(ring)).toEqual(3)
		expect(Ring.shift(ring)).toEqual(4)
		expect(Ring.shift(ring)).toEqual(5)
	end)
end)

t.describe("Buffer envelope", function()
	t.it("stamps every field the backend requires", function()
		local buffer = Buffer.new()
		local envelope = Buffer.push(buffer, "combat.hit", { damage = 22 }, CONTEXT, 1234.5)

		expect(envelope.v).toEqual(Buffer.ENVELOPE_VERSION)
		expect(envelope.ts).toEqual(1234.5)
		expect(envelope.runId).toEqual("run-1")
		expect(envelope.serverId).toEqual("job-abc")
		expect(envelope.placeId).toEqual(1234)
		expect(envelope.pid).toEqual("a3f9")
		expect(envelope.type).toEqual("combat.hit")
		expect(envelope.p.damage).toEqual(22)
	end)

	t.it("numbers events monotonically from 1", function()
		local buffer = Buffer.new()
		for index = 1, 50 do
			expect(push(buffer, "tick").seq).toEqual(index)
		end
	end)

	t.it("keeps numbering through drops, so the gap is visible", function()
		-- `seq` is how the rollup worker detects loss: max seq versus event
		-- count. Renumbering on flush would close the gap and hide it.
		local buffer = Buffer.new(4)
		for _ = 1, 10 do
			push(buffer, "tick")
		end
		local batch = Buffer.drain(buffer, 1)
		expect(#batch).toEqual(4)
		expect(batch[1].seq).toEqual(7) -- 1..6 were overwritten
		expect(batch[4].seq).toEqual(10)
		expect(buffer.dropped).toEqual(6)
	end)
end)

t.describe("Buffer overflow", function()
	t.it("drops the oldest and counts it", function()
		local buffer = Buffer.new(3)
		push(buffer, "a")
		push(buffer, "b")
		push(buffer, "c")
		expect(buffer.dropped).toEqual(0)

		push(buffer, "d")
		expect(buffer.dropped).toEqual(1)
		expect(Buffer.count(buffer)).toEqual(3)

		local batch = Buffer.drain(buffer, 0)
		-- The newest events survive: they describe the run happening now.
		expect(batch[1].type).toEqual("b")
		expect(batch[3].type).toEqual("d")
	end)

	t.it("never grows past capacity however long the backend is down", function()
		local buffer = Buffer.new(100)
		for _ = 1, 10000 do
			push(buffer, "tick")
		end
		expect(Buffer.count(buffer)).toEqual(100)
		expect(buffer.ring.capacity).toEqual(100)
		expect(buffer.dropped).toEqual(9900)
	end)

	t.it("reports drops with the batch and clears them only on commit", function()
		local buffer = Buffer.new(2)
		for _ = 1, 5 do
			push(buffer, "tick")
		end

		local _, dropped = Buffer.drain(buffer, 1)
		expect(dropped).toEqual(3)
		-- Not yet acknowledged: a failed post must not lose the count.
		expect(buffer.droppedSinceFlush).toEqual(3)

		Buffer.commit(buffer)
		expect(buffer.droppedSinceFlush).toEqual(0)
		-- The lifetime total is not reset.
		expect(buffer.dropped).toEqual(3)
	end)
end)

t.describe("Buffer flush conditions", function()
	t.it("flushes once the batch size is reached", function()
		local buffer = Buffer.new(1000, 200, 5)
		for _ = 1, 199 do
			push(buffer, "tick")
		end
		expect(Buffer.shouldFlush(buffer, 0)).toBeFalsy()
		push(buffer, "tick")
		expect(Buffer.shouldFlush(buffer, 0)).toBeTruthy()
	end)

	t.it("flushes on the interval even with a single event", function()
		local buffer = Buffer.new(1000, 200, 5)
		push(buffer, "tick")
		expect(Buffer.shouldFlush(buffer, 4.9)).toBeFalsy()
		expect(Buffer.shouldFlush(buffer, 5.0)).toBeTruthy()
	end)

	t.it("never flushes an empty buffer", function()
		local buffer = Buffer.new()
		expect(Buffer.shouldFlush(buffer, 0)).toBeFalsy()
		expect(Buffer.shouldFlush(buffer, 1e6)).toBeFalsy()
		-- A quiet server must not post empty batches forever.
		push(buffer, "tick")
		Buffer.drain(buffer, 10)
		expect(Buffer.shouldFlush(buffer, 1e6)).toBeFalsy()
	end)

	t.it("restarts the interval from the last drain", function()
		local buffer = Buffer.new(1000, 200, 5)
		push(buffer, "tick")
		Buffer.drain(buffer, 10)
		push(buffer, "tick")
		expect(Buffer.shouldFlush(buffer, 14.9)).toBeFalsy()
		expect(Buffer.shouldFlush(buffer, 15.0)).toBeTruthy()
	end)

	t.it("caps a drain at the batch size and leaves the rest queued", function()
		local buffer = Buffer.new(1000, 10, 5)
		for _ = 1, 25 do
			push(buffer, "tick")
		end
		expect(#Buffer.drain(buffer, 1)).toEqual(10)
		expect(Buffer.count(buffer)).toEqual(15)
		expect(Buffer.shouldFlush(buffer, 1)).toBeTruthy()
	end)
end)

t.describe("Buffer requeue after a failed post", function()
	t.it("puts the batch back ahead of newer events", function()
		local buffer = Buffer.new(100, 2, 5)
		push(buffer, "a")
		push(buffer, "b")
		local batch = Buffer.drain(buffer, 1)
		expect(#batch).toEqual(2)

		-- The post failed, and the game kept playing meanwhile.
		push(buffer, "c")
		Buffer.requeue(buffer, batch)

		local retry = Buffer.drain(buffer, 2)
		expect(retry[1].type).toEqual("a")
		expect(retry[2].type).toEqual("b")
		expect(Buffer.count(buffer)).toEqual(1)
		expect((Buffer.drain(buffer, 3))[1].type).toEqual("c")
	end)

	t.it("stays bounded when retries pile up", function()
		-- A dead backend retrying forever must not be what unbounds the buffer.
		local buffer = Buffer.new(10, 10, 5)
		for _ = 1, 10 do
			push(buffer, "tick")
		end
		local batch = Buffer.drain(buffer, 1)
		for _ = 1, 10 do
			push(buffer, "new")
		end
		Buffer.requeue(buffer, batch)

		expect(Buffer.count(buffer)).toEqual(10)
		expect(buffer.dropped > 0).toBeTruthy()
	end)

	t.it("survives a requeue of an empty batch", function()
		local buffer = Buffer.new(10)
		push(buffer, "a")
		Buffer.requeue(buffer, {})
		expect(Buffer.count(buffer)).toEqual(1)
		expect((Buffer.drain(buffer, 1))[1].type).toEqual("a")
	end)
end)

t.describe("Buffer.stats", function()
	t.it("reports what the dashboard needs to see a hole", function()
		local buffer = Buffer.new(4, 2, 5)
		for _ = 1, 9 do
			push(buffer, "tick")
		end
		Buffer.drain(buffer, 1)
		Buffer.commit(buffer)

		local stats = Buffer.stats(buffer)
		expect(stats.capacity).toEqual(4)
		expect(stats.seq).toEqual(9)
		expect(stats.dropped).toEqual(5)
		expect(stats.flushes).toEqual(1)
		expect(stats.queued).toEqual(2)
	end)
end)
