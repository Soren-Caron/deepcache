--!strict
--[[ M7-4. core/anim/RagdollPool -- the scheduling half of the ragdoll system,
	tested here so the interesting case (pool exhaustion) does not require
	instantiating physics rigs.

	The Studio accept criterion is "kill 20 entities in 2s, pool recycles, no
	error". 20 deaths against 12 slots inside the 8s lifetime means 8 of them
	*must* evict, and what gets evicted is the part worth pinning down.
]]

local t = require("./framework")
local expect = t.expect

local RagdollPool = require("../src/shared/core/anim/RagdollPool")

t.describe("RagdollPool basics", function()
	t.it("matches the documented pool size and lifetime", function()
		expect(RagdollPool.SIZE).toEqual(12)
		expect(RagdollPool.LIFETIME_SECONDS).toEqual(8)
	end)

	t.it("starts empty", function()
		local pool = RagdollPool.new()
		expect(#pool.slots).toEqual(12)
		expect(RagdollPool.activeCount(pool)).toEqual(0)
	end)

	t.it("hands out distinct slots while there is room", function()
		local pool = RagdollPool.new()
		local seen: { [number]: boolean } = {}
		for id = 1, 12 do
			local slot, evicted = RagdollPool.acquire(pool, id, 0)
			expect(evicted).never().toBeTruthy()
			expect(seen[slot.index]).never().toBeTruthy()
			seen[slot.index] = true
		end
		expect(RagdollPool.activeCount(pool)).toEqual(12)
	end)
end)

t.describe("RagdollPool expiry", function()
	t.it("recycles a corpse once it passes the lifetime", function()
		local pool = RagdollPool.new()
		RagdollPool.acquire(pool, 1, 0)
		expect(RagdollPool.activeCount(pool)).toEqual(1)

		expect(#RagdollPool.expire(pool, 7.9)).toEqual(0) -- not yet
		expect(RagdollPool.activeCount(pool)).toEqual(1)

		local freed = RagdollPool.expire(pool, 8.0)
		expect(#freed).toEqual(1)
		expect(RagdollPool.activeCount(pool)).toEqual(0)
		expect(pool.recycled).toEqual(1)
	end)

	t.it("expiry frees slots for reuse without evicting", function()
		local pool = RagdollPool.new()
		for id = 1, 12 do
			RagdollPool.acquire(pool, id, 0)
		end
		-- All 12 have aged out by now.
		local _, evicted = RagdollPool.acquire(pool, 99, 10)
		expect(evicted).never().toBeTruthy()
		expect(pool.evictions).toEqual(0)
	end)

	t.it("expires only what is actually old", function()
		local pool = RagdollPool.new()
		RagdollPool.acquire(pool, 1, 0)
		RagdollPool.acquire(pool, 2, 5)
		local freed = RagdollPool.expire(pool, 9)
		expect(#freed).toEqual(1) -- entity 1 only; entity 2 is 4s old
		expect(RagdollPool.activeCount(pool)).toEqual(1)
	end)
end)

t.describe("RagdollPool exhaustion -- the M7-4 accept criterion", function()
	t.it("20 deaths in 2 seconds never fails, and evicts exactly the overflow", function()
		local pool = RagdollPool.new()
		for id = 1, 20 do
			local now = (id - 1) * 0.1 -- 20 deaths across 2 seconds
			local slot, evicted = RagdollPool.acquire(pool, id, now)
			-- Always succeeds: a death must always produce a body.
			expect(slot).never().toEqual(nil :: any)
			if id <= 12 then
				expect(evicted).never().toBeTruthy()
			else
				expect(evicted).toBeTruthy()
			end
		end
		expect(pool.spawned).toEqual(20)
		expect(pool.evictions).toEqual(8) -- 20 - 12
		expect(RagdollPool.activeCount(pool)).toEqual(12) -- never exceeds the pool
	end)

	t.it("evicts the OLDEST corpse, not the newest death", function()
		-- Priority matters: the corpse the player is looking at is the one
		-- they just made. Dropping the new death to preserve a 7-second-old
		-- body means kills stop producing corpses exactly during a firefight.
		local pool = RagdollPool.new(3)
		RagdollPool.acquire(pool, 100, 0.0) -- oldest
		RagdollPool.acquire(pool, 200, 0.5)
		RagdollPool.acquire(pool, 300, 1.0)

		local slot, evicted = RagdollPool.acquire(pool, 400, 1.5)
		expect(evicted).toBeTruthy()
		expect(slot.entityId).toEqual(400)

		-- 100 is gone; 200, 300 and 400 remain.
		local live: { [number]: boolean } = {}
		for _, s in pool.slots do
			if s.entityId then
				live[s.entityId] = true
			end
		end
		expect(live[100]).never().toBeTruthy()
		expect(live[200]).toBeTruthy()
		expect(live[300]).toBeTruthy()
		expect(live[400]).toBeTruthy()
	end)

	t.it("active count never exceeds the pool size under sustained pressure", function()
		local pool = RagdollPool.new()
		for id = 1, 500 do
			RagdollPool.acquire(pool, id, id * 0.05)
			expect(RagdollPool.activeCount(pool) <= 12).toBeTruthy()
		end
	end)

	t.it("a slow trickle never evicts, because corpses expire first", function()
		-- The realistic case: deaths spaced further apart than the lifetime.
		local pool = RagdollPool.new()
		for id = 1, 50 do
			RagdollPool.acquire(pool, id, id * 9)
		end
		expect(pool.evictions).toEqual(0)
		expect(RagdollPool.activeCount(pool)).toEqual(1)
	end)
end)
