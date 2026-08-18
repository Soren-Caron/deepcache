--!strict
--[[ M5-4/M5-5. MemoryStore-backed matchmaking queue and lease-based
	coordinator election. See docs/06 §Architecture.

	**A real API behavior, verified directly in Studio before trusting it,
	not assumed from documentation:** `MemoryStoreSortedMap:RemoveAsync`
	does NOT report whether it actually removed an existing entry --
	confirmed empirically: removing a real key and removing an
	already-absent key both return the same thing (no meaningful second
	value). The first draft of this file used `RemoveAsync`'s return value
	as the claim-race compare-and-set primitive; it does not work, and a
	real two-caller race test proved it (both calls read as "did not
	claim"). `MemoryStoreSortedMap:UpdateAsync` DOES give a real
	atomic-write signal -- its transform function's return value becomes
	the call's return value on success, and returning `nil` from the
	transform *aborts the whole write*, leaving whatever was already there
	untouched (verified: a second racing `UpdateAsync` whose transform
	returned `nil` did not overwrite the first caller's value). Every
	genuinely atomic operation below is built on `UpdateAsync`, not
	`RemoveAsync`, because of this.

	Coordinator election is a MemoryStore key with a 10s lease: `UpdateAsync`
	writes `instanceId` only if the current holder is nil (never set, or
	the previous lease expired) or is already this same instance (a
	renewal); a live lease held by someone else aborts the write. A crashed
	coordinator's lease simply expires after 10s -- no explicit handoff or
	heartbeat-miss detection needed, MemoryStore's own TTL does the work.

	Queue-entry claiming writes a claimed-marker sentinel via the same
	`UpdateAsync` pattern (an entry can only be claimed once, by whichever
	caller's `UpdateAsync` transform actually ran against the real,
	unclaimed value), then best-effort cleans the key up with `RemoveAsync`
	-- cleanup failing cannot cause a double-match, since the claim itself
	already happened atomically; `listBucket` also filters the marker
	defensively in case cleanup hasn't landed yet.

	This module deliberately stops at the primitives M5-4 and M5-5's own
	accept criteria are about (claim atomicity, lease takeover). Actually
	forming squads and calling ReserveServer/TeleportAsync is M5-6, which
	needs a second real published place to teleport to and is blocked on
	M0-8/M5-3 (human tasks) -- not implemented here, not stubbed with a
	fake "second server" that would prove nothing real.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")

local QueueService = {}

QueueService.COORDINATOR_TTL_SECONDS = 10

local LEASES_MAP_NAME = "deepcache:leases"
local COORDINATOR_KEY = "deepcache:coordinator"
local QUEUE_MAP_PREFIX = "deepcache:queue:bucket:"
local CLAIMED_MARKER = "__claimed__"
local CLAIM_MARKER_TTL_SECONDS = 30

export type QueueEntry = {
	pid: string,
	rating: number,
	ts: number,
}

local function queueMapFor(bucket: number): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(QUEUE_MAP_PREFIX .. tostring(bucket))
end

--- Adds `pid` to `bucket`'s queue. `ttlSeconds` bounds how long a stale
--- entry can linger if a player disconnects without leaving cleanly --
--- this is not the widening-schedule TTL (core/discovery/Bucket owns
--- that), it's a dead-entry backstop.
function QueueService.join(bucket: number, pid: string, rating: number, nowTs: number, ttlSeconds: number): boolean
	local map = queueMapFor(bucket)
	local ok = pcall(function()
		map:SetAsync(pid, { pid = pid, rating = rating, ts = nowTs }, ttlSeconds)
	end)
	return ok
end

--- Removes `pid` from `bucket`'s queue. Not race-sensitive the way
--- tryClaim is -- a player leaving voluntarily doesn't need compare-and-
--- set -- so this only reports whether the call itself succeeded, not
--- whether an entry actually existed (RemoveAsync cannot tell us that).
function QueueService.leave(bucket: number, pid: string): boolean
	local map = queueMapFor(bucket)
	local ok = pcall(function()
		map:RemoveAsync(pid)
	end)
	return ok
end

--- Attempts to atomically claim `pid` out of `bucket`'s queue for a match.
--- Returns true only if THIS call's UpdateAsync transform actually ran
--- against a real, not-yet-claimed entry. If another coordinator already
--- claimed it (or it never existed), this returns false and the caller
--- must not treat that player as claimed.
function QueueService.tryClaim(bucket: number, pid: string): boolean
	local map = queueMapFor(bucket)
	local ok, result = pcall(function()
		return map:UpdateAsync(pid, function(current: any)
			if current == nil or current == CLAIMED_MARKER then
				return nil -- abort: already gone or already claimed
			end
			return CLAIMED_MARKER
		end, CLAIM_MARKER_TTL_SECONDS)
	end)
	local won = ok and result == CLAIMED_MARKER
	if won then
		-- Best-effort cleanup so the key stops appearing at all. A failed
		-- cleanup here cannot cause a double-claim -- the claim already
		-- happened atomically above -- only a stale-looking listing until
		-- the marker's own TTL expires.
		pcall(function()
			map:RemoveAsync(pid)
		end)
	end
	return won
end

function QueueService.listBucket(bucket: number, count: number): { QueueEntry }
	local map = queueMapFor(bucket)
	local ok, result = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, count)
	end)
	if not ok or result == nil then
		return {}
	end
	local out: { QueueEntry } = {}
	for _, item in result :: { any } do
		if item.value ~= CLAIMED_MARKER then
			table.insert(out, item.value :: QueueEntry)
		end
	end
	return out
end

--- Attempts to become (or renew, if already held by `instanceId`) the
--- coordinator. Returns true if this instance holds the lease after the
--- call. The check ("is anyone else already holding a live lease") and
--- the write happen as one atomic MemoryStore operation -- checking with
--- a separate GetAsync first would leave a race window between the check
--- and the write, which is exactly the bug a lease exists to prevent.
function QueueService.tryBecomeCoordinator(instanceId: string): boolean
	local map = MemoryStoreService:GetSortedMap(LEASES_MAP_NAME)
	local ok, result = pcall(function()
		return map:UpdateAsync(COORDINATOR_KEY, function(current: string?)
			if current == nil or current == instanceId then
				return instanceId
			end
			return nil -- abort: a different instance holds a live lease
		end, QueueService.COORDINATOR_TTL_SECONDS)
	end)
	return ok and result == instanceId
end

--- Who currently holds the coordinator lease, if anyone (nil if expired
--- or never claimed). Diagnostic/testing use -- the coordinator loop
--- itself only needs the boolean from tryBecomeCoordinator.
function QueueService.currentCoordinator(): string?
	local map = MemoryStoreService:GetSortedMap(LEASES_MAP_NAME)
	local ok, result = pcall(function()
		return map:GetAsync(COORDINATOR_KEY)
	end)
	if not ok then
		return nil
	end
	return result :: string?
end

return QueueService
