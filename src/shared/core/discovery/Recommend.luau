--!strict
--[[ M5-9. Item-item collaborative filtering with cosine similarity and
	shrinkage. See docs/06 §Loadout recommendations.

	Pure: the co-occurrence matrix and item counts arrive as arguments,
	computed nightly by the backend worker (M5-10) from real telemetry.
	This module only knows how to turn those numbers into a ranked list --
	it has no idea what an item is.

	**Replaces a pre-existing M0 scaffold** (`CooccurMatrix` as a single
	`{pairs, counts}` record, one `Recommend.forPlayer(matrix, owned,
	candidates, popularityBaseline)` entry point returning
	`Recommendation`s tagged with a `reason` enum) that this file didn't
	check for before designing its own split (`similarity` / `scoreItem` /
	`topN` / `popularityBaseline` / `recommend`, no `reason` field). The
	`reason` codes from docs/06's response example
	(`pairs_with_owned`/`similar_players`/`popular_at_your_rating`) are not
	reproduced here -- distinguishing which reason applies needs
	information (whether a score came from item-similarity vs.
	rating-bucket popularity) this module's plain float score doesn't
	carry; that would be an addition for M5-10, which does know which code
	path produced a given recommendation. Kept the flatter shape after
	confirming nothing else in the repo referenced the original names yet.
]]

export type CooccurrenceMatrix = { [string]: { [string]: number } }
export type ItemCounts = { [string]: number }

export type Recommendation = {
	itemId: string,
	score: number,
}

export type RecommendResult = {
	recommendations: { Recommendation },
	fallback: boolean,
}

local Recommend = {}

--- docs/06: suppresses noise from rare pairs. Without it, a pair that
--- co-occurred twice (and appeared nowhere else) gets cosine similarity
--- 1.0 and dominates every recommendation it's eligible for.
Recommend.SHRINKAGE = 10

--- docs/06: fewer than 3 runs is cold start -- the popularity baseline,
--- not personalized scoring, since there isn't enough signal yet to trust.
Recommend.COLD_START_RUNS = 3

--- Cosine similarity on raw co-occurrence, then shrunk toward zero for
--- pairs with little support. 0 whenever either item has never been used
--- at all -- sqrt(0) would otherwise divide by zero.
function Recommend.similarity(cooccurCount: number, countA: number, countB: number): number
	if countA <= 0 or countB <= 0 or cooccurCount <= 0 then
		return 0
	end
	local cosine = cooccurCount / math.sqrt(countA * countB)
	return cosine * cooccurCount / (cooccurCount + Recommend.SHRINKAGE)
end

local function contains(list: { string }, value: string): boolean
	for _, v in list do
		if v == value then
			return true
		end
	end
	return false
end

--- Sum of sim'(candidate, owned) over every item the player owns/recently
--- used. A candidate similar to several owned items outranks one similar
--- to only one, which is the whole point of summing rather than averaging.
function Recommend.scoreItem(
	candidateId: string,
	ownedIds: { string },
	cooccur: CooccurrenceMatrix,
	counts: ItemCounts
): number
	local total = 0
	local candidateCount = counts[candidateId] or 0
	local row = cooccur[candidateId]
	for _, ownedId in ownedIds do
		local pairCount = if row then row[ownedId] or 0 else 0
		total += Recommend.similarity(pairCount, candidateCount, counts[ownedId] or 0)
	end
	return total
end

local function sortDescending(recs: { Recommendation })
	table.sort(recs, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		-- Stable tie-break: alphabetical, so output order is deterministic
		-- for testing rather than dependent on table iteration order.
		return a.itemId < b.itemId
	end)
end

--- Personalized top-N, excluding anything the player already owns.
function Recommend.topN(
	allItemIds: { string },
	ownedIds: { string },
	cooccur: CooccurrenceMatrix,
	counts: ItemCounts,
	n: number
): { Recommendation }
	local candidates: { Recommendation } = {}
	for _, itemId in allItemIds do
		if not contains(ownedIds, itemId) then
			local score = Recommend.scoreItem(itemId, ownedIds, cooccur, counts)
			if score > 0 then
				table.insert(candidates, { itemId = itemId, score = score })
			end
		end
	end
	sortDescending(candidates)
	local out: { Recommendation } = {}
	for i = 1, math.min(n, #candidates) do
		table.insert(out, candidates[i])
	end
	return out
end

--- Global top-N by raw equip count, excluding owned items. The cold-start
--- path, and also the baseline offline evaluation (M5-11) compares against.
function Recommend.popularityBaseline(
	allItemIds: { string },
	counts: ItemCounts,
	ownedIds: { string },
	n: number
): { Recommendation }
	local candidates: { Recommendation } = {}
	for _, itemId in allItemIds do
		if not contains(ownedIds, itemId) then
			local count = counts[itemId] or 0
			if count > 0 then
				table.insert(candidates, { itemId = itemId, score = count })
			end
		end
	end
	sortDescending(candidates)
	local out: { Recommendation } = {}
	for i = 1, math.min(n, #candidates) do
		table.insert(out, candidates[i])
	end
	return out
end

--- The whole documented contract in one call: cold start below
--- COLD_START_RUNS falls back to the popularity baseline with
--- `fallback = true`; otherwise personalized scoring, `fallback = false`.
function Recommend.recommend(
	runsPlayed: number,
	ownedIds: { string },
	allItemIds: { string },
	cooccur: CooccurrenceMatrix,
	counts: ItemCounts,
	n: number
): RecommendResult
	if runsPlayed < Recommend.COLD_START_RUNS then
		return {
			recommendations = Recommend.popularityBaseline(allItemIds, counts, ownedIds, n),
			fallback = true,
		}
	end
	return {
		recommendations = Recommend.topN(allItemIds, ownedIds, cooccur, counts, n),
		fallback = false,
	}
end

return Recommend
