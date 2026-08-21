--!strict
--[[ M6-6. Decides whether a config payload from the backend is fit to adopt.

	Pure, because this is the decision that matters and it must be testable
	without a backend, without Studio, and without waiting for a nightly
	worker. The adapter (`server/services/EconomyService`) does the HTTP call
	and the retry; this says yes or no.

	Two independent rules, per docs/07 and the M6-5/M6-6 accept criteria:

	  **Version guard.** Adopt only what is strictly newer than what is
	  already held. `config/Economy.luau` ships `version = 0`, so any real
	  remote config beats the compiled-in defaults exactly once, and a stale
	  replica or a replayed response can never walk a server *backwards* to a
	  multiplier the controller has already moved on from.

	  **Schema validation, wholesale.** A payload is adopted in full or
	  rejected in full. There is no partial adoption and no per-field
	  fallback, because a config that is half new and half default is a
	  combination nobody tested and nobody can reproduce from the version
	  number alone. "Wholesale" is the accept criterion's own word.

	Rejection is never fatal. The caller keeps whatever it already had --
	compiled-in defaults at boot, or the last good remote config -- which is
	why `EconomyService` can come up with the backend down and simply carry
	on. See docs/07 §Persistence.
]]

local ConfigGuard = {}

--- Mirrors the controller's own clamp range. A multiplier outside it means
--- something bypassed the controller, and the game should not be the place
--- that discovers whether that was survivable.
ConfigGuard.MULT_MIN = 0.80
ConfigGuard.MULT_MAX = 1.25

export type EconomyPayload = {
	version: number,
	payoutMultiplier: number,
}

export type Verdict = {
	accept: boolean,
	--- Present when `accept` is false. A stable machine-readable code, not
	--- prose, so telemetry can count rejection kinds without parsing.
	reason: string?,
}

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Is this payload structurally a config at all?
function ConfigGuard.isWellFormed(payload: unknown): boolean
	if type(payload) ~= "table" then
		return false
	end
	local p = payload :: { [string]: any }
	if not isFiniteNumber(p.version) or p.version < 0 or p.version ~= math.floor(p.version) then
		return false
	end
	if not isFiniteNumber(p.payoutMultiplier) then
		return false
	end
	return true
end

--- Should `payload` replace a config currently at `currentVersion`?
---
--- Never throws, for any input, including nil and arbitrary garbage: this
--- runs on a response from the network, and a config pull that can error is a
--- config pull that can take a server down at boot.
function ConfigGuard.evaluate(payload: unknown, currentVersion: number): Verdict
	if not ConfigGuard.isWellFormed(payload) then
		return { accept = false, reason = "malformed" }
	end
	local p = payload :: EconomyPayload

	-- Strictly newer. Equal is not newer: re-adopting the same version is a
	-- no-op at best, and at worst hides that the backend has stopped
	-- advancing.
	if p.version <= currentVersion then
		return { accept = false, reason = "not_newer" }
	end

	if p.payoutMultiplier < ConfigGuard.MULT_MIN or p.payoutMultiplier > ConfigGuard.MULT_MAX then
		return { accept = false, reason = "multiplier_out_of_range" }
	end

	return { accept = true }
end

--- Apply `payload` over `current` if it passes, else return `current`
--- untouched. The returned table is always safe to use.
function ConfigGuard.adopt(current: EconomyPayload, payload: unknown): (EconomyPayload, Verdict)
	local verdict = ConfigGuard.evaluate(payload, current.version)
	if not verdict.accept then
		return current, verdict
	end
	local p = payload :: EconomyPayload
	-- A fresh table rather than a mutation: the caller may still be holding a
	-- reference to the previous config, and a config that changes underneath
	-- a reader mid-run is a race nobody will find twice.
	return { version = p.version, payoutMultiplier = p.payoutMultiplier }, verdict
end

return ConfigGuard
