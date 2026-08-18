--!strict
--[[ M4-10. Deterministic A/B arm assignment by runId.

	docs/05 §Evaluating the director: arm A is the FSM alone (control), arm B
	is the FSM plus OVERSEER proposals (treatment). Assignment must be a pure
	function of runId -- reproducible from a logged run without needing to
	have recorded the arm separately -- and reusing the already-tested
	SHA-256 (core/telemetry/Hmac) means this isn't a second hash
	implementation to trust.
]]

local Hmac = require("../telemetry/Hmac")

export type Arm = "A" | "B"

local AbTest = {}

--- The last hex digit of sha256(runId) is uniform over 0-15; splitting at 8
--- gives an even A/B division without needing a second RNG or a counter
--- that would make assignment depend on call order instead of runId alone.
function AbTest.assignArm(runId: string): Arm
	local digest = Hmac.sha256(runId)
	local lastChar = string.sub(digest, -1)
	local value = tonumber(lastChar, 16) or 0
	return if value < 8 then "A" else "B"
end

return AbTest
