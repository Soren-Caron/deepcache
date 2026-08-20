--!strict
--[[ M6-1. Double-entry currency ledger.

	Balance is derived from the sum of entries, never a mutable counter.
	`idemKey` is the entire duplicate-grant defense: a retried payout is
	detected and ignored. Keys must be deterministic — a random UUID per
	attempt defeats the mechanism entirely.

	Sign convention (not enforced by the type system, so stated here):
	FAUCETS entries carry a positive delta, SINKS entries carry a negative
	one. `admin_adjust` is neither a faucet nor a sink and is excluded from
	`totals()` entirely -- it's an out-of-band correction, not economy
	activity the controller should react to.

	`apply` mutates `state` in place and returns the same reference rather
	than cloning balances/seenKeys/entries on every call. The stub's
	`(LedgerState, boolean)` signature reads as functional-update style, but
	a real clone-per-entry would make the 10k-entry conservation test
	quadratic for no benefit -- nothing here needs snapshot/undo semantics.

	`makeKey` joins fields with `|`, which assumes `runId`/`pid` never
	contain that character. IDs in this project are opaque generated
	strings, not user-authored text, so that holds -- noted because it's the
	one way a "deterministic key" function can be silently wrong.
]]

local Ledger = {}

export type Reason =
	"extract_payout" | "objective_bonus" | "daily_first"
	| "repair" | "ammo" | "insurance_premium" | "insurance_claim"
	| "market_fee" | "market_sale" | "market_purchase"
	| "cosmetic" | "admin_adjust"

export type Entry = {
	pid: string,
	delta: number,
	reason: Reason,
	runId: string?,
	idemKey: string,
	ts: number,
}

export type LedgerState = {
	balances: { [string]: number },
	seenKeys: { [string]: boolean },
	entries: { Entry },
}

--- Why `apply` did what it did.
---   `applied`             — new entry, balance moved.
---   `duplicate`           — idemKey already seen; no change. The caller must
---                           treat this as SUCCESS (docs/07): the effect is
---                           already in the ledger, this is a retry landing.
---   `insufficient_funds`  — rejected; no change. The caller must treat this
---                           as FAILURE and must NOT deliver whatever the
---                           entry was paying for.
export type ApplyStatus = "applied" | "duplicate" | "insufficient_funds"

local FAUCETS: { Reason } = { "extract_payout", "objective_bonus", "daily_first", "insurance_claim", "market_sale" }
local SINKS: { Reason } =
	{ "repair", "ammo", "insurance_premium", "market_fee", "market_purchase", "cosmetic" }

Ledger.FAUCETS = FAUCETS
Ledger.SINKS = SINKS

local FAUCET_SET: { [Reason]: boolean } = {}
for _, r in FAUCETS do
	FAUCET_SET[r] = true
end
local SINK_SET: { [Reason]: boolean } = {}
for _, r in SINKS do
	SINK_SET[r] = true
end

function Ledger.new(): LedgerState
	return {
		balances = {},
		seenKeys = {},
		entries = {},
	}
end

--- Apply an entry.
---
--- Returns `(state, ok, status)`. `ok` answers the only question a caller
--- actually needs — "is this entry's effect accounted for in the ledger?" —
--- and is true for both a fresh apply and a duplicate. `status` says which.
---
--- **Why `ok` is not the same as "the balance changed":** docs/07 specifies
--- that a duplicate idemKey is a success the caller ignores, and separately
--- that a negative balance is rejected. A single boolean cannot carry both,
--- and collapsing them is dangerous in exactly one direction: a caller told
--- `false` for a rejected purchase would follow docs/07's "treat false as
--- success" rule and hand over the goods without ever taking the currency.
--- That is the duplicate-grant bug this whole module exists to prevent,
--- arriving through the error path instead. So the *rejection* gets the
--- distinct value, and `status` disambiguates the rest.
function Ledger.apply(state: LedgerState, entry: Entry): (LedgerState, boolean, ApplyStatus)
	if state.seenKeys[entry.idemKey] then
		return state, true, "duplicate"
	end

	local newBalance = (state.balances[entry.pid] or 0) + entry.delta
	if newBalance < 0 then
		return state, false, "insufficient_funds"
	end

	state.seenKeys[entry.idemKey] = true
	state.balances[entry.pid] = newBalance
	table.insert(state.entries, entry)

	return state, true, "applied"
end

function Ledger.balance(state: LedgerState, pid: string): number
	return state.balances[pid] or 0
end

--- Deterministic key: the same logical grant must always produce the same key.
function Ledger.makeKey(runId: string, pid: string, reason: Reason, sequence: number): string
	return `{runId}|{pid}|{reason}|{sequence}`
end

--- Totals over a window, for the sink/faucet controller. `admin_adjust`
--- entries are excluded -- they are corrections, not economy activity.
--- Both totals are magnitudes (abs of delta), so `sink / faucet` is a
--- meaningful ratio regardless of the entries' stored signs.
function Ledger.totals(state: LedgerState, fromTs: number, toTs: number): { faucet: number, sink: number }
	local faucet = 0
	local sink = 0
	for _, e in state.entries do
		if e.ts >= fromTs and e.ts <= toTs then
			if FAUCET_SET[e.reason] then
				faucet += math.abs(e.delta)
			elseif SINK_SET[e.reason] then
				sink += math.abs(e.delta)
			end
		end
	end
	return { faucet = faucet, sink = sink }
end

return Ledger
