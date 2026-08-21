--!strict
--[[ M6-3. Faucets, sinks, and insurance -- the rules that decide how many
	credits a run creates or destroys, and why.

	Pure: every amount is a function of numbers passed in. The adapter
	(`server/services/EconomyService`) is what knows a run happened and turns
	each result into a `Ledger.Entry`.

	**Sign convention is enforced here, not left to call sites.** Every
	function returns a magnitude, and `Payouts.signedDelta` is the single
	place that decides whether a reason code adds or removes credits, by
	consulting `Ledger.FAUCETS` / `Ledger.SINKS`. A sink that accidentally
	shipped a positive delta would be a currency faucet nobody planned, which
	is precisely the failure the M6-3 accept criterion ("each reason code
	produces a ledger entry with the right sign") is checking for. Deriving
	the sign from the same table the ledger's own `totals()` uses means the
	two cannot disagree.

	**The multiplier touches faucets only.** docs/07 is explicit: the
	controller tunes extraction payout and objective bonus, never sinks and
	never drop rates. Players notice a price rise far more than a payout dip,
	and changing what drops changes gameplay while changing what it is worth
	changes only the economy. `applyMultiplier` is therefore called on the
	faucet paths and nowhere else, and `repairCost`/`ammoCost` do not take a
	multiplier argument at all -- the type makes the rule unbreakable rather
	than relying on everyone remembering it.

	**Insurance is the interesting sink.** The premium is paid *before* the
	drop, on a declared carry value, and pays back a fraction of the loot
	actually lost on death. Its uptake rate is a direct readout of population
	risk appetite; docs/07 wants it in the 30-60% band.
]]

local Ledger = require("./Ledger")

local Payouts = {}

export type Rates = {
	extractBasePayout: number,
	extractValueRate: number,
	objectiveBonus: number,
	dailyFirstExtract: number,
	repairPerMinute: number,
	ammoPerMagazine: number,
	insurancePremiumRate: number,
	insuranceRecoveryRate: number,
}

--- Credits are whole numbers (the ledger's columns are BIGINT), so every
--- amount floors. Flooring rather than rounding means a faucet never pays a
--- credit more than the formula says and a sink never charges one more.
local function whole(value: number): number
	if value ~= value then -- NaN in, 0 out: never emit a poisoned amount.
		return 0
	end
	return math.max(0, math.floor(value))
end

--------------------------------------------------------------------------------
-- Faucets
--------------------------------------------------------------------------------

--- Extraction payout: a flat base plus a share of what was carried out.
function Payouts.extractPayout(carriedValue: number, rates: Rates, multiplier: number): number
	return whole((rates.extractBasePayout + carriedValue * rates.extractValueRate) * multiplier)
end

function Payouts.objectiveBonus(completedCount: number, rates: Rates, multiplier: number): number
	return whole(completedCount * rates.objectiveBonus * multiplier)
end

--- Paid once per player per day, on their first successful extraction.
function Payouts.dailyFirstExtract(rates: Rates, multiplier: number): number
	return whole(rates.dailyFirstExtract * multiplier)
end

--------------------------------------------------------------------------------
-- Sinks
--------------------------------------------------------------------------------

--- Gear repair scales with run length: a soft tax on playing.
--- No multiplier argument, by design -- see the header.
function Payouts.repairCost(runSeconds: number, rates: Rates): number
	return whole((runSeconds / 60) * rates.repairPerMinute)
end

--- Ammo scales with usage: a tax on inefficiency.
function Payouts.ammoCost(magazinesUsed: number, rates: Rates): number
	return whole(magazinesUsed * rates.ammoPerMagazine)
end

--------------------------------------------------------------------------------
-- Insurance
--------------------------------------------------------------------------------

--- Charged up front on the value the player declares they are carrying in.
function Payouts.insurancePremium(declaredValue: number, rates: Rates): number
	return whole(declaredValue * rates.insurancePremiumRate)
end

--- Paid out on death, as a fraction of what was actually lost.
---
--- Capped at the declared value the premium was charged on: without the cap a
--- player could insure a trivial carry, pick up a fortune, die on purpose and
--- claim against loot they never paid to cover. That turns the most
--- interesting sink in the economy into its largest faucet.
function Payouts.insuranceClaim(lostValue: number, declaredValue: number, rates: Rates): number
	local covered = math.min(math.max(lostValue, 0), math.max(declaredValue, 0))
	return whole(covered * rates.insuranceRecoveryRate)
end

--------------------------------------------------------------------------------
-- Sign
--------------------------------------------------------------------------------

local FAUCET_SET: { [Ledger.Reason]: boolean } = {}
for _, reason in Ledger.FAUCETS do
	FAUCET_SET[reason] = true
end
local SINK_SET: { [Ledger.Reason]: boolean } = {}
for _, reason in Ledger.SINKS do
	SINK_SET[reason] = true
end

--- Turn a magnitude into a signed ledger delta for `reason`.
---
--- Faucets are positive, sinks negative. `admin_adjust` belongs to neither
--- list -- it is a correction that can legitimately go either way -- so its
--- amount is passed through with whatever sign the caller supplied, and it is
--- the one reason code this function does not decide for.
function Payouts.signedDelta(reason: Ledger.Reason, amount: number): number
	if reason == "admin_adjust" then
		return math.floor(amount)
	end
	local magnitude = whole(math.abs(amount))
	if SINK_SET[reason] then
		return -magnitude
	end
	if FAUCET_SET[reason] then
		return magnitude
	end
	-- Unreachable while Reason stays a closed union and both tables cover it;
	-- a new reason code added to neither list lands here rather than silently
	-- becoming a faucet.
	error(`Payouts.signedDelta: "{reason}" is in neither FAUCETS nor SINKS`, 2)
end

return Payouts
