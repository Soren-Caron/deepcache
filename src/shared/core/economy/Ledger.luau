--!strict
--[[ M6-1. Double-entry currency ledger.

	Balance is derived from the sum of entries, never a mutable counter.
	`idemKey` is the entire duplicate-grant defense: a retried payout is
	detected and ignored. Keys must be deterministic — a random UUID per
	attempt defeats the mechanism entirely.
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

local FAUCETS: { Reason } = { "extract_payout", "objective_bonus", "daily_first", "insurance_claim", "market_sale" }
local SINKS: { Reason } =
	{ "repair", "ammo", "insurance_premium", "market_fee", "market_purchase", "cosmetic" }

Ledger.FAUCETS = FAUCETS
Ledger.SINKS = SINKS

function Ledger.new(): LedgerState
	error("unimplemented: Ledger.new (M6-1)")
end

--- Apply an entry. Returns `applied = false` when idemKey was already seen —
--- that is a successful no-op, not an error. Rejects entries that would drive
--- a balance negative.
function Ledger.apply(state: LedgerState, entry: Entry): (LedgerState, boolean)
	error("unimplemented: Ledger.apply (M6-1)")
end

function Ledger.balance(state: LedgerState, pid: string): number
	error("unimplemented: Ledger.balance (M6-1)")
end

--- Deterministic key: the same logical grant must always produce the same key.
function Ledger.makeKey(runId: string, pid: string, reason: Reason, sequence: number): string
	error("unimplemented: Ledger.makeKey (M6-1)")
end

--- Totals over a window, for the sink/faucet controller.
function Ledger.totals(state: LedgerState, fromTs: number, toTs: number): { faucet: number, sink: number }
	error("unimplemented: Ledger.totals (M6-1)")
end

return Ledger
