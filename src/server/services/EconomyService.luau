--!strict
--[[ M6-3 + M6-6. The economy adapter: ledger entries for real run events,
	and the live config pull.

	All the arithmetic lives in `core/economy/Payouts` and all the adopt-or-
	reject logic in `core/economy/ConfigGuard`. This file supplies the things
	only the engine knows -- that a player extracted, how long the run was,
	what the backend answered -- and owns the ledger state.

	**Boot never depends on the backend.** The compiled-in `config/Economy`
	defaults are in place before the first pull is even attempted, so a
	backend that is down, slow, or serving garbage costs nothing but a stale
	multiplier. That is the M6-6 accept criterion, and it is why the pull runs
	on its own thread rather than blocking `init`.

	**Idempotency keys are constructed from run identity, never from a
	counter that resets.** `Ledger.makeKey(runId, pid, reason, sequence)` with
	a per-(run, pid, reason) sequence means a retried payout produces the same
	key and is absorbed as a duplicate. A random key per attempt, or a
	sequence that restarted at server boot, would defeat the entire mechanism
	-- docs/07 calls this out as the detail to get right.
]]

local HttpService = game:GetService("HttpService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local ConfigGuard = require(Shared.core.economy.ConfigGuard)
local EconomyConfig = require(Shared.config.Economy)
local Ledger = require(Shared.core.economy.Ledger)
local Payouts = require(Shared.core.economy.Payouts)
local BackendConfig = require("../config/Backend")

local EconomyService = {}

local RATES: Payouts.Rates = {
	extractBasePayout = EconomyConfig.faucets.extractBasePayout,
	extractValueRate = EconomyConfig.faucets.extractValueRate,
	objectiveBonus = EconomyConfig.faucets.objectiveBonus,
	dailyFirstExtract = EconomyConfig.faucets.dailyFirstExtract,
	repairPerMinute = EconomyConfig.sinks.repairPerMinute,
	ammoPerMagazine = EconomyConfig.sinks.ammoPerMagazine,
	insurancePremiumRate = EconomyConfig.sinks.insurancePremiumRate,
	insuranceRecoveryRate = EconomyConfig.sinks.insuranceRecoveryRate,
}

local ledger = Ledger.new()
local liveConfig: ConfigGuard.EconomyPayload = {
	version = EconomyConfig.version,
	payoutMultiplier = EconomyConfig.payoutMultiplier,
}

local metrics = {
	pulls = 0,
	adopted = 0,
	rejected = 0,
	lastReason = "",
	lastError = "",
	entries = 0,
	duplicates = 0,
	insured = 0,
}

--- Per-(run, pid, reason) sequence, so a retry rebuilds the same idemKey.
local sequences: { [string]: number } = {}
--- Declared carry value per (run, pid) for players who bought insurance.
local insured: { [string]: number } = {}

local function nextSequence(runId: string, pid: string, reason: Ledger.Reason): number
	local key = `{runId}|{pid}|{reason}`
	local next = (sequences[key] or 0) + 1
	sequences[key] = next
	return next
end

--- Record one economic event. `magnitude` is always positive; the sign comes
--- from the reason code via Payouts.signedDelta, so no call site can turn a
--- sink into a faucet by passing the wrong sign.
function EconomyService.record(
	runId: string,
	pid: string,
	reason: Ledger.Reason,
	magnitude: number,
	nowTs: number
): (boolean, string)
	local sequence = nextSequence(runId, pid, reason)
	local entry: Ledger.Entry = {
		pid = pid,
		delta = Payouts.signedDelta(reason, magnitude),
		reason = reason,
		runId = runId,
		idemKey = Ledger.makeKey(runId, pid, reason, sequence),
		ts = nowTs,
	}
	local _, ok, status = Ledger.apply(ledger, entry)
	if status == "duplicate" then
		metrics.duplicates += 1
	elseif ok then
		metrics.entries += 1
	end
	return ok, status
end

function EconomyService.balance(pid: string): number
	return Ledger.balance(ledger, pid)
end

function EconomyService.multiplier(): number
	return liveConfig.payoutMultiplier
end

--------------------------------------------------------------------------------
-- Run events (M6-3)
--------------------------------------------------------------------------------

--- Successful extraction. Pays the base + carried value, the objective bonus,
--- and the once-daily bonus when this is the player's first extract today.
function EconomyService.onExtract(
	runId: string,
	pid: string,
	carriedValue: number,
	objectivesCompleted: number,
	isFirstToday: boolean,
	nowTs: number
)
	local m = liveConfig.payoutMultiplier
	EconomyService.record(runId, pid, "extract_payout", Payouts.extractPayout(carriedValue, RATES, m), nowTs)
	if objectivesCompleted > 0 then
		EconomyService.record(
			runId, pid, "objective_bonus",
			Payouts.objectiveBonus(objectivesCompleted, RATES, m), nowTs
		)
	end
	if isFirstToday then
		EconomyService.record(runId, pid, "daily_first", Payouts.dailyFirstExtract(RATES, m), nowTs)
	end
end

--- End-of-run sinks. Charged whether the player extracted or died -- the gear
--- was used either way, which is the point of a tax on playing.
function EconomyService.onRunEnd(runId: string, pid: string, runSeconds: number, magazinesUsed: number, nowTs: number)
	local repair = Payouts.repairCost(runSeconds, RATES)
	if repair > 0 then
		EconomyService.record(runId, pid, "repair", repair, nowTs)
	end
	local ammo = Payouts.ammoCost(magazinesUsed, RATES)
	if ammo > 0 then
		EconomyService.record(runId, pid, "ammo", ammo, nowTs)
	end
end

--- Buy insurance before the drop, on a declared carry value.
function EconomyService.buyInsurance(runId: string, pid: string, declaredValue: number, nowTs: number): (boolean, string)
	local premium = Payouts.insurancePremium(declaredValue, RATES)
	local ok, status = EconomyService.record(runId, pid, "insurance_premium", premium, nowTs)
	if ok then
		insured[`{runId}|{pid}`] = declaredValue
		metrics.insured += 1
	end
	return ok, status
end

--- Death. Pays a claim only if a premium was actually charged for this run,
--- and only up to the value that premium covered.
function EconomyService.onDeath(runId: string, pid: string, lostValue: number, nowTs: number): number
	local declared = insured[`{runId}|{pid}`]
	if declared == nil then
		return 0
	end
	local claim = Payouts.insuranceClaim(lostValue, declared, RATES)
	if claim > 0 then
		EconomyService.record(runId, pid, "insurance_claim", claim, nowTs)
	end
	return claim
end

--- Forget a finished run's per-run state, so a long-lived server does not
--- accumulate a sequence entry for every (run, pid, reason) it has ever seen.
function EconomyService.forgetRun(runId: string)
	for key in sequences do
		if string.sub(key, 1, #runId + 1) == runId .. "|" then
			sequences[key] = nil
		end
	end
	for key in insured do
		if string.sub(key, 1, #runId + 1) == runId .. "|" then
			insured[key] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Config pull (M6-6)
--------------------------------------------------------------------------------

--- One pull. Never throws; returns whether a new config was adopted.
function EconomyService.pullConfig(): boolean
	if not BackendConfig.enabled then
		return false
	end
	metrics.pulls += 1

	local url = `{BackendConfig.baseUrl}{BackendConfig.configPath}?since={liveConfig.version}`
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		metrics.lastError = tostring(response)
		return false
	end
	local httpResponse = response :: any
	if not httpResponse.Success then
		metrics.lastError = `http {httpResponse.StatusCode}`
		return false
	end

	local decoded: any
	local decodeOk = pcall(function()
		decoded = HttpService:JSONDecode(httpResponse.Body)
	end)
	if not decodeOk then
		metrics.lastError = "malformed json"
		metrics.rejected += 1
		return false
	end
	metrics.lastError = ""

	-- `current: true` means the backend agrees we already have the newest.
	if type(decoded) == "table" and decoded.current == true then
		metrics.lastReason = "current"
		return false
	end

	local payload = if type(decoded) == "table" then decoded.config else nil
	local adopted, verdict = ConfigGuard.adopt(liveConfig, payload)
	liveConfig = adopted
	if verdict.accept then
		metrics.adopted += 1
		metrics.lastReason = "adopted"
		return true
	end
	metrics.rejected += 1
	metrics.lastReason = verdict.reason or "rejected"
	return false
end

local polling = false

--- Start the periodic pull. Returns immediately: the first pull happens on
--- its own thread so a slow or dead backend cannot delay server startup.
function EconomyService.startConfigPolling()
	if polling then
		return
	end
	polling = true
	task.spawn(function()
		while polling do
			EconomyService.pullConfig()
			task.wait(BackendConfig.configPollSeconds)
		end
	end)
end

function EconomyService.stopConfigPolling()
	polling = false
end

function EconomyService.describe(): { [string]: any }
	return {
		configVersion = liveConfig.version,
		payoutMultiplier = liveConfig.payoutMultiplier,
		pulls = metrics.pulls,
		adopted = metrics.adopted,
		rejected = metrics.rejected,
		lastReason = metrics.lastReason,
		lastError = metrics.lastError,
		entries = metrics.entries,
		duplicates = metrics.duplicates,
		insuredPlayers = metrics.insured,
		polling = polling,
	}
end

--- Testing/diagnostics: wipe ledger and per-run state without a server restart.
function EconomyService.reset()
	ledger = Ledger.new()
	sequences = {}
	insured = {}
	metrics.entries, metrics.duplicates, metrics.insured = 0, 0, 0
end

return EconomyService
