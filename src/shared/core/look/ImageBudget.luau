--!strict
--[[ M7-7. The EditableImage allocation ledger.

	**The hard limit is 8 live `EditableImage` instances on the client, and
	exceeding it fails at creation with a memory-budget error rather than
	gracefully** (CLAUDE.md, docs/08). That makes this the one budget in the
	project that cannot be discovered empirically in production -- by the time
	you find the cap you have already thrown.

	So the accounting is pure and lives here, separate from the instances
	themselves. `LookController` asks this whether it may allocate *before* it
	calls `Instance.new`, which means the refusal path is exercised by unit
	tests at no cost, instead of by creating nine real images and hoping the
	ninth fails the way the docs say.

	docs/08 fixes the allocation table: slots 1-6 are named uses, 7-8 are
	deliberately reserved. The reserve is not slack to be spent later -- it
	exists because "discovering the cap in production is a bad way to discover
	the cap", and a reserve that anything is allowed to claim is not a reserve.
	`acquire` therefore refuses at 6 for normal callers, and only an explicitly
	reserved request may go past it.
]]

local ImageBudget = {}

--- Roblox's hard cap. Not a tunable.
ImageBudget.HARD_CAP = 8
--- Slots kept back from normal allocation. See the header.
ImageBudget.RESERVED = 2
--- What ordinary callers may use.
ImageBudget.NORMAL_CAP = ImageBudget.HARD_CAP - ImageBudget.RESERVED

export type Purpose =
	"zone_palette" | "damage_state" | "threat_gradient"
	| "noise_detail" | "weapon_heat" | "weapon_charge" | "reserved"

export type Budget = {
	--- purpose -> handle id, so a second acquire for the same purpose reuses
	--- rather than double-allocating.
	held: { [string]: number },
	nextHandle: number,
	liveCount: number,
	--- Diagnostics: how many acquires were refused. A nonzero value in normal
	--- play is the early warning the reserve exists to provide.
	refusals: number,
	peak: number,
}

function ImageBudget.new(): Budget
	return { held = {}, nextHandle = 0, liveCount = 0, refusals = 0, peak = 0 }
end

--- May a caller take another slot right now?
function ImageBudget.canAcquire(budget: Budget, useReserve: boolean): boolean
	local cap = if useReserve then ImageBudget.HARD_CAP else ImageBudget.NORMAL_CAP
	return budget.liveCount < cap
end

--- Take a slot for `purpose`. Returns the handle, or nil with a reason.
---
--- Never throws: the entire point is that the caller finds out it cannot
--- allocate *before* touching `Instance.new`, and a budget manager that
--- errored would just relocate the crash it exists to prevent.
function ImageBudget.acquire(budget: Budget, purpose: string, useReserve: boolean?): (number?, string?)
	local existing = budget.held[purpose]
	if existing ~= nil then
		-- Idempotent by purpose. A caller re-acquiring after a zone change is
		-- asking for "the zone palette image", not for a second one.
		return existing, nil
	end
	if not ImageBudget.canAcquire(budget, useReserve == true) then
		budget.refusals += 1
		local cap = if useReserve == true then ImageBudget.HARD_CAP else ImageBudget.NORMAL_CAP
		return nil, `budget exhausted: {budget.liveCount} live, cap {cap}`
	end

	budget.nextHandle += 1
	local handle = budget.nextHandle
	budget.held[purpose] = handle
	budget.liveCount += 1
	if budget.liveCount > budget.peak then
		budget.peak = budget.liveCount
	end
	return handle, nil
end

--- Give a slot back. Returns whether anything was actually held, so a
--- double-release is visible to a caller that cares rather than silently
--- decrementing the count below zero.
function ImageBudget.release(budget: Budget, purpose: string): boolean
	if budget.held[purpose] == nil then
		return false
	end
	budget.held[purpose] = nil
	budget.liveCount -= 1
	return true
end

function ImageBudget.isHeld(budget: Budget, purpose: string): boolean
	return budget.held[purpose] ~= nil
end

function ImageBudget.describe(budget: Budget): { [string]: any }
	local purposes: { string } = {}
	for purpose in budget.held do
		table.insert(purposes, purpose)
	end
	table.sort(purposes)
	return {
		live = budget.liveCount,
		peak = budget.peak,
		refusals = budget.refusals,
		normalCap = ImageBudget.NORMAL_CAP,
		hardCap = ImageBudget.HARD_CAP,
		held = purposes,
	}
end

return ImageBudget
