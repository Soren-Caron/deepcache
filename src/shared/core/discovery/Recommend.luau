--!strict
--[[ M5-9. Item-item collaborative filtering.

	Cosine similarity with shrinkage. Without shrinkage a pair that co-occurred
	twice scores 1.0 and dominates everything — the most common failure mode in
	naive CF, and the reason LAMBDA exists.
]]

local Recommend = {}

export type CooccurMatrix = {
	pairs: { [string]: { [string]: number } },
	counts: { [string]: number },
}

export type Recommendation = {
	itemId: string,
	score: number,
	reason: "pairs_with_owned" | "similar_players" | "popular_at_your_rating",
}

Recommend.LAMBDA = 10
Recommend.TOP_N = 3

function Recommend.similarity(matrix: CooccurMatrix, a: string, b: string): number
	error("unimplemented: Recommend.similarity (M5-9)")
end

--- Score candidates against the player's owned items. Owned items are
--- excluded from the output.
function Recommend.forPlayer(
	matrix: CooccurMatrix,
	owned: { string },
	candidates: { string },
	popularityBaseline: { string }
): { Recommendation }
	error("unimplemented: Recommend.forPlayer (M5-9)")
end

return Recommend
