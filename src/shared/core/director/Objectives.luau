--!strict
--[[ M4-8. Objective cooldown gate.

	Completes the split documented in Clamp.luau and docs/05 §Clamping:
	`Clamp.apply` owns "is this id in the whitelist" (stateless, pure,
	total). This module owns "and is it available *right now*" (stateful --
	an objective that just finished cannot be re-issued immediately). Kept
	separate rather than folded into Clamp because Clamp's contract is
	"never throws, always total, no notion of time" -- cooldown tracking is
	explicitly about time, so it does not belong there.

	Core cannot read config (see the M1-4/M2-8 precedent in tasks/BACKLOG.md),
	so cooldown durations arrive as an argument -- the adapter owns the
	mapping from `config/Objectives.luau`.
]]

export type ObjectiveState = {
	activeId: string,
	--- Seconds-elapsed timestamp at which a given id becomes choosable again.
	--- Absent means "never issued, always available."
	availableAt: { [string]: number },
}

local Objectives = {}

function Objectives.new(initialId: string): ObjectiveState
	return {
		activeId = initialId,
		availableAt = {},
	}
end

--- Whether `id` could be chosen right now, ignoring whether it is even a
--- real objective id -- that check is Clamp's job, upstream of this one.
function Objectives.isAvailable(state: ObjectiveState, id: string, nowSeconds: number): boolean
	local availableAt = state.availableAt[id]
	return availableAt == nil or nowSeconds >= availableAt
end

--- Resolves a candidate id (from the FSM's rotation or a clamped LLM
--- proposal -- either way, already known to be a real objective id by the
--- time this is called) against cooldown state. Returns the candidate if
--- it is available now, otherwise keeps whatever is already active: an
--- objective on cooldown never interrupts one still legitimately running.
function Objectives.resolve(state: ObjectiveState, candidateId: string, nowSeconds: number): string
	if Objectives.isAvailable(state, candidateId, nowSeconds) then
		return candidateId
	end
	return state.activeId
end

--- Commits `resolvedId` as active. A genuine change starts the *previous*
--- objective's cooldown -- the one being entered needs no cooldown of its
--- own until it, in turn, is replaced. Re-issuing the id already active is
--- a no-op: holding an objective steady across ticks must never reset or
--- extend anything.
function Objectives.issue(
	state: ObjectiveState,
	resolvedId: string,
	nowSeconds: number,
	cooldownSecondsById: { [string]: number }
)
	if resolvedId == state.activeId then
		return
	end
	local previous = state.activeId
	state.availableAt[previous] = nowSeconds + (cooldownSecondsById[previous] or 0)
	state.activeId = resolvedId
end

return Objectives
