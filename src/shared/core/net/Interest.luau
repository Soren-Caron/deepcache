--!strict
--[[
	Interest management: which entities a given client is told about.

	A packet holds 81 entity records and the interest cap is 32, so on a busy
	tick most of the simulation is deliberately not replicated to any one
	player. Choosing well is what keeps bandwidth at ~2 KB/s instead of ~6.

	Score = proximity + engagement + starvation:

	  1 / (distance + 1)          near things matter most
	  + ATTACK_BONUS              something attacking you matters more
	  + starvation bonus          anything unsent for a while gets a turn

	Divergence from docs/03-NETCODE.md: the plan wrote the starvation term as
	`0.3 * ticksSinceLastSent`, which grows without bound and would eventually
	dominate proximity entirely — a distant idle entity would outrank one
	chewing on your face. It is normalised here to saturate at STARVATION_BONUS
	after STARVATION_FULL_TICKS, which preserves the anti-starvation intent
	(nothing stays frozen when you turn around) without inverting the ordering.
]]

local Types = require("../Types")

export type Params = {
	radius: number,
	maxCount: number,
	--- Entity ids currently attacking this viewer.
	attacking: { [number]: boolean }?,
	--- Tick each entity was last sent to this viewer.
	lastSentTick: { [number]: number }?,
	currentTick: number,
}

local Interest = {}

Interest.ATTACK_BONUS = 0.5
Interest.STARVATION_BONUS = 0.3
Interest.STARVATION_FULL_TICKS = 20

function Interest.score(
	distance: number,
	isAttacking: boolean,
	ticksSinceLastSent: number
): number
	local proximity = 1 / (math.max(distance, 0) + 1)
	local engagement = if isAttacking then Interest.ATTACK_BONUS else 0
	local starvation = Interest.STARVATION_BONUS
		* math.clamp(ticksSinceLastSent / Interest.STARVATION_FULL_TICKS, 0, 1)
	return proximity + engagement + starvation
end

--- Pick the entities this viewer should receive, highest score first.
---
--- Ties break on entity id so the result is deterministic: an unstable
--- ordering would make deltas churn between two equivalent sets and waste the
--- byte budget re-sending unchanged entities.
function Interest.select(
	entities: { Types.EntityView },
	viewerPos: Types.Vec3,
	params: Params
): { Types.EntityView }
	local attacking = params.attacking or {}
	local lastSent = params.lastSentTick or {}

	type Scored = { view: Types.EntityView, score: number }
	local candidates: { Scored } = {}

	for _, view in entities do
		local distance = Types.distance(view.pos, viewerPos)
		if distance <= params.radius then
			local sentAt = lastSent[view.id]
			local since = if sentAt ~= nil then params.currentTick - sentAt else Interest.STARVATION_FULL_TICKS
			candidates[#candidates + 1] = {
				view = view,
				score = Interest.score(distance, attacking[view.id] == true, since),
			}
		end
	end

	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.view.id < b.view.id
	end)

	local limit = math.min(params.maxCount, #candidates)
	local out: { Types.EntityView } = table.create(limit)
	for i = 1, limit do
		out[i] = candidates[i].view
	end
	return out
end

return Interest
