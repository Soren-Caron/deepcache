--!strict
--[[ M4-5. Turns anything the model returns into a valid decision.

	This function is total: it must never throw and must always return a
	valid DirectorDecision, for every possible input including nil, garbage,
	wrong types, and out-of-range values. It is the entire safety boundary
	between the LLM and the game. See docs/05-OVERSEER-DIRECTOR.md §Clamping.
]]

local Schema = require("./Schema")

local Clamp = {}

--- Never throws. `baseline` is the FSM decision used to fill anything the
--- proposal fails to supply legally.
function Clamp.apply(
	proposal: unknown,
	baseline: Schema.DirectorDecision,
	bounds: Schema.DirectorBounds
): Schema.DirectorDecision
	error("unimplemented: Clamp.apply (M4-5)")
end

--- Clamp a value into range and additionally limit how far it may move from
--- `previous` in a single tick.
function Clamp.rateLimited(value: number, previous: number, min: number, max: number, maxDelta: number): number
	error("unimplemented: Clamp.rateLimited (M4-5)")
end

--- Strip control characters and truncate. Does NOT content-filter — that is
--- TextService's job and happens in the adapter.
function Clamp.sanitizeBark(text: unknown, maxChars: number): string
	error("unimplemented: Clamp.sanitizeBark (M4-5)")
end

return Clamp
