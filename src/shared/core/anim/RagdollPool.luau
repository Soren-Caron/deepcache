--!strict
--[[ M7-4. Ragdoll slot accounting.

	docs/08: ragdoll physics is client-only and never replicated, drawn from a
	pool of 12 rigs recycled after 8 seconds. This module owns *which slot is
	free and when*; the client adapter owns the actual rigs and the impulses.

	Splitting it out is not ceremony. The interesting behaviour is what happens
	when the pool is exhausted -- 20 entities dying in 2 seconds against 12
	slots is the accept criterion -- and that is a scheduling question with an
	exact answer, testable without instantiating a single physics rig.

	**Exhaustion recycles the oldest rather than dropping the newest.** A
	corpse that has been lying there 7 seconds has already been seen; the one
	that just died is the one the player is looking at, because they just shot
	it. Dropping the new death to preserve an old corpse gets the priority
	exactly backwards, and in a firefight -- precisely when the pool runs out --
	it means the kills you are actively making stop producing bodies.
]]

local RagdollPool = {}

--- docs/08 §Ragdolls.
RagdollPool.SIZE = 12
RagdollPool.LIFETIME_SECONDS = 8

export type Slot = {
	index: number,
	--- nil when free.
	entityId: number?,
	spawnedAt: number,
}

export type Pool = {
	slots: { Slot },
	--- Diagnostics: how many deaths had to evict a live corpse.
	evictions: number,
	spawned: number,
	recycled: number,
}

function RagdollPool.new(size: number?): Pool
	local count = size or RagdollPool.SIZE
	local slots: { Slot } = table.create(count)
	for index = 1, count do
		slots[index] = { index = index, entityId = nil, spawnedAt = 0 }
	end
	return { slots = slots, evictions = 0, spawned = 0, recycled = 0 }
end

--- Retire any corpse older than the lifetime. Returns the slot indices that
--- became free, so the adapter knows which rigs to hide.
function RagdollPool.expire(pool: Pool, now: number): { number }
	local freed: { number } = {}
	for _, slot in pool.slots do
		if slot.entityId ~= nil and now - slot.spawnedAt >= RagdollPool.LIFETIME_SECONDS then
			slot.entityId = nil
			pool.recycled += 1
			table.insert(freed, slot.index)
		end
	end
	return freed
end

--- Claim a slot for `entityId`. Always succeeds -- see the header for why
--- exhaustion evicts the oldest corpse rather than refusing the new death.
--- Returns the slot and whether an eviction was needed.
function RagdollPool.acquire(pool: Pool, entityId: number, now: number): (Slot, boolean)
	RagdollPool.expire(pool, now)

	for _, slot in pool.slots do
		if slot.entityId == nil then
			slot.entityId = entityId
			slot.spawnedAt = now
			pool.spawned += 1
			return slot, false
		end
	end

	-- Full. Evict the oldest.
	local oldest = pool.slots[1]
	for _, slot in pool.slots do
		if slot.spawnedAt < oldest.spawnedAt then
			oldest = slot
		end
	end
	oldest.entityId = entityId
	oldest.spawnedAt = now
	pool.spawned += 1
	pool.evictions += 1
	return oldest, true
end

function RagdollPool.activeCount(pool: Pool): number
	local count = 0
	for _, slot in pool.slots do
		if slot.entityId ~= nil then
			count += 1
		end
	end
	return count
end

function RagdollPool.describe(pool: Pool): { [string]: any }
	return {
		size = #pool.slots,
		active = RagdollPool.activeCount(pool),
		spawned = pool.spawned,
		recycled = pool.recycled,
		evictions = pool.evictions,
		lifetimeSeconds = RagdollPool.LIFETIME_SECONDS,
	}
end

return RagdollPool
