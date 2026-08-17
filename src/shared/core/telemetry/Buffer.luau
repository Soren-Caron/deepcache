--!strict
--[[ M3-1. The telemetry ring buffer.

	Every gameplay system emits into this; a worker drains it and posts batches
	to the backend. It sits between "the game is producing events" and "the
	network might be down", so its only real job is to never become the reason
	the game stops.

	Three rules follow from that:

	  - **Bounded.** A fixed ring. If the backend is unreachable for ten minutes
	    the buffer does not grow — it drops.
	  - **Drops the oldest, and counts them.** Newer events describe the run
	    that is happening now. A drop that nobody counted is indistinguishable
	    from an event that never happened, so the counter ships with the next
	    successful batch and the dashboard can see the hole.
	  - **`seq` is assigned on push, not on flush.** It is monotonic per server
	    and the rollup worker detects loss by comparing max `seq` against the
	    event count. Numbering at flush time would renumber around the gap and
	    hide exactly what it exists to reveal.

	Pure: no clock, no HTTP. Time is passed in.
]]

local Ring = require("../util/Ring")

export type Envelope = {
	v: number,
	ts: number,
	runId: string,
	serverId: string,
	placeId: number,
	pid: string?,
	type: string,
	seq: number,
	p: { [string]: any },
}

export type Buffer = {
	ring: Ring.Ring<Envelope>,
	seq: number,
	dropped: number,
	--- Dropped since the last successful flush, shipped with the next batch.
	droppedSinceFlush: number,
	lastFlushTime: number,
	flushCount: number,
	maxBatch: number,
	flushIntervalSeconds: number,
}

local Buffer = {}

--- Envelope version. Bump when the shape changes so the backend can reject or
--- migrate rather than guess.
Buffer.ENVELOPE_VERSION = 1

--- Flush when either is true: enough events, or enough time. Both matter — a
--- busy server would otherwise sit on a full buffer, and a quiet one would
--- never ship the handful of events that say it was quiet.
Buffer.MAX_BATCH = 200
Buffer.FLUSH_INTERVAL_SECONDS = 5

--- Ring capacity. Five batches of headroom: enough to ride out a few failed
--- posts without dropping, small enough that a dead backend cannot balloon
--- server memory.
Buffer.CAPACITY = 1000

function Buffer.new(capacity: number?, maxBatch: number?, flushInterval: number?): Buffer
	return {
		ring = Ring.new(capacity or Buffer.CAPACITY),
		seq = 0,
		dropped = 0,
		droppedSinceFlush = 0,
		lastFlushTime = 0,
		flushCount = 0,
		maxBatch = maxBatch or Buffer.MAX_BATCH,
		flushIntervalSeconds = flushInterval or Buffer.FLUSH_INTERVAL_SECONDS,
	}
end

--- Add an event. Returns the envelope, so the caller can log or inspect the
--- `seq` it was given.
function Buffer.push(
	buffer: Buffer,
	eventType: string,
	payload: { [string]: any },
	context: { runId: string, serverId: string, placeId: number, pid: string? },
	now: number
): Envelope
	buffer.seq += 1

	local envelope: Envelope = {
		v = Buffer.ENVELOPE_VERSION,
		ts = now,
		runId = context.runId,
		serverId = context.serverId,
		placeId = context.placeId,
		pid = context.pid,
		type = eventType,
		seq = buffer.seq,
		p = payload,
	}

	if buffer.ring.count >= buffer.ring.capacity then
		-- Full: the oldest event is overwritten. Count it, because the gap in
		-- `seq` is the only other evidence it existed.
		buffer.dropped += 1
		buffer.droppedSinceFlush += 1
	end
	Ring.push(buffer.ring, envelope)

	return envelope
end

function Buffer.count(buffer: Buffer): number
	return buffer.ring.count
end

--- Whether a flush is due. Either condition alone is enough.
function Buffer.shouldFlush(buffer: Buffer, now: number): boolean
	if buffer.ring.count == 0 then
		return false
	end
	if buffer.ring.count >= buffer.maxBatch then
		return true
	end
	return now - buffer.lastFlushTime >= buffer.flushIntervalSeconds
end

--- Take up to `maxBatch` events, oldest first.
---
--- Does **not** clear the drop counter: that happens in `commit`, once the
--- batch is known to have landed. A batch that fails to post has to be
--- retried, and the drop count has to survive with it.
function Buffer.drain(buffer: Buffer, now: number): ({ Envelope }, number)
	local out: { Envelope } = {}
	local limit = math.min(buffer.maxBatch, buffer.ring.count)
	for _ = 1, limit do
		local item = Ring.shift(buffer.ring)
		if item == nil then
			break
		end
		table.insert(out, item)
	end
	buffer.lastFlushTime = now
	return out, buffer.droppedSinceFlush
end

--- Acknowledge a batch that reached the backend.
function Buffer.commit(buffer: Buffer)
	buffer.flushCount += 1
	buffer.droppedSinceFlush = 0
end

--- Put a failed batch back at the front, oldest first, so ordering survives a
--- retry. Events that no longer fit are dropped and counted — the buffer is
--- bounded, and a retry storm must not be the thing that unbounds it.
function Buffer.requeue(buffer: Buffer, batch: { Envelope })
	local existing: { Envelope } = {}
	while true do
		local item = Ring.shift(buffer.ring)
		if item == nil then
			break
		end
		table.insert(existing, item)
	end

	for _, envelope in batch do
		if buffer.ring.count >= buffer.ring.capacity then
			buffer.dropped += 1
			buffer.droppedSinceFlush += 1
		end
		Ring.push(buffer.ring, envelope)
	end
	for _, envelope in existing do
		if buffer.ring.count >= buffer.ring.capacity then
			buffer.dropped += 1
			buffer.droppedSinceFlush += 1
		end
		Ring.push(buffer.ring, envelope)
	end
end

function Buffer.stats(buffer: Buffer): { [string]: number }
	return {
		queued = buffer.ring.count,
		capacity = buffer.ring.capacity,
		seq = buffer.seq,
		dropped = buffer.dropped,
		droppedSinceFlush = buffer.droppedSinceFlush,
		flushes = buffer.flushCount,
	}
end

return Buffer
