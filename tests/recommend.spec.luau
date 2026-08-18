--!strict
--[[ M5-9. Accept criteria from tasks/BACKLOG.md: shrinkage suppresses a
	2-count pair; owned items excluded; cold start returns baseline.
]]

local t = require("./framework")
local expect = t.expect

local Recommend = require("../src/shared/core/discovery/Recommend")

t.describe("Recommend.similarity", function()
	t.it("shrinkage suppresses a 2-count pair -- docs/06's own worked example", function()
		-- cooccur=2, count(a)=2, count(b)=2: naive cosine is 2/sqrt(4)=1.0
		-- exactly, matching docs/06's "gets a similarity of 1.0" claim.
		-- Shrinkage pulls it down to 1.0 * 2/(2+10) = 1/6.
		local shrunk = Recommend.similarity(2, 2, 2)
		expect(shrunk).approx(1 / 6, 1e-9)
		expect(shrunk < 0.2).toBeTruthy()
		expect(shrunk).never().toEqual(1.0)
	end)

	t.it("a well-supported pair keeps most of its cosine similarity", function()
		-- cooccur=50, count(a)=100, count(b)=80.
		-- cosine = 50/sqrt(8000) ~= 0.559017. shrunk = cosine*50/60 ~= 0.465847.
		local score = Recommend.similarity(50, 100, 80)
		expect(score).approx(0.465847, 1e-4)
		-- Still meaningfully below the naive cosine -- shrinkage always
		-- pulls down, never up.
		expect(score < 50 / math.sqrt(8000)).toBeTruthy()
	end)

	t.it("is zero whenever either item has never been used", function()
		expect(Recommend.similarity(0, 0, 5)).toEqual(0)
		expect(Recommend.similarity(0, 5, 0)).toEqual(0)
		expect(Recommend.similarity(3, 0, 0)).toEqual(0)
	end)
end)

t.describe("Recommend.scoreItem", function()
	t.it("sums similarity across every owned item, not just the best match", function()
		local cooccur: Recommend.CooccurrenceMatrix = {
			candidate = { itemA = 2, itemB = 2 },
		}
		local counts: Recommend.ItemCounts = { candidate = 2, itemA = 2, itemB = 2 }
		local score = Recommend.scoreItem("candidate", { "itemA", "itemB" }, cooccur, counts)
		-- Both pairs are the same 2/2/2 shape as the shrinkage test above:
		-- each contributes 1/6, summed = 1/3.
		expect(score).approx(1 / 3, 1e-9)
	end)

	t.it("is zero for a candidate that never co-occurred with anything owned", function()
		local score = Recommend.scoreItem("candidate", { "itemA" }, {}, { candidate = 5, itemA = 5 })
		expect(score).toEqual(0)
	end)
end)

t.describe("Recommend.topN / popularityBaseline: owned items excluded", function()
	-- Self-consistent co-occurrence data: cooccur(a,b) can never exceed
	-- min(count(a), count(b)) in a real matrix, so the fixture has to
	-- respect that or the "hand-computed" scores below would be nonsense.
	-- owned: used 30 times. itemA: used 20 times, 15 of them alongside
	-- owned. itemB: used 10 times, 8 of them alongside owned.
	local cooccur: Recommend.CooccurrenceMatrix = {
		itemA = { owned = 15 },
		itemB = { owned = 8 },
		owned = { itemA = 15, itemB = 8 },
	}
	local counts: Recommend.ItemCounts = { owned = 30, itemA = 20, itemB = 10 }

	t.it("topN never recommends an item the player already owns, even if it would score highest", function()
		local recs = Recommend.topN({ "itemA", "itemB", "owned" }, { "owned" }, cooccur, counts, 5)
		for _, rec in recs do
			expect(rec.itemId).never().toEqual("owned")
		end
	end)

	t.it("popularityBaseline also excludes owned items", function()
		local recs = Recommend.popularityBaseline({ "itemA", "itemB", "owned" }, counts, { "owned" }, 5)
		for _, rec in recs do
			expect(rec.itemId).never().toEqual("owned")
		end
		-- itemA (raw count 20) outranks itemB (raw count 10).
		expect(recs[1].itemId).toEqual("itemA")
	end)

	t.it("topN ranks a candidate with stronger co-occurrence higher -- hand-computed", function()
		-- itemA: cosine = 15/sqrt(20*30) = 15/sqrt(600) ~= 0.61237,
		--        shrunk = 0.61237 * 15/25 ~= 0.36742
		-- itemB: cosine = 8/sqrt(10*30) = 8/sqrt(300) ~= 0.46188,
		--        shrunk = 0.46188 * 8/18 ~= 0.20528
		local recs = Recommend.topN({ "itemA", "itemB", "owned" }, { "owned" }, cooccur, counts, 5)
		expect(#recs).toEqual(2)
		expect(recs[1].itemId).toEqual("itemA")
		expect(recs[1].score).approx(0.36742, 1e-4)
		expect(recs[2].itemId).toEqual("itemB")
		expect(recs[2].score).approx(0.20528, 1e-4)
	end)

	t.it("respects the requested N", function()
		local recs = Recommend.topN({ "itemA", "itemB", "owned" }, { "owned" }, cooccur, counts, 1)
		expect(#recs).toEqual(1)
	end)
end)

t.describe("Recommend.recommend: cold start", function()
	local allItems = { "itemA", "itemB", "itemC" }
	local counts: Recommend.ItemCounts = { itemA = 30, itemB = 20, itemC = 5 }
	local cooccur: Recommend.CooccurrenceMatrix = { itemA = { itemB = 15 } }

	t.it("fewer than 3 runs returns the popularity baseline with fallback=true", function()
		local result = Recommend.recommend(0, {}, allItems, cooccur, counts, 3)
		expect(result.fallback).toBeTruthy()
		expect(result.recommendations[1].itemId).toEqual("itemA") -- highest raw count

		local resultAt2 = Recommend.recommend(2, {}, allItems, cooccur, counts, 3)
		expect(resultAt2.fallback).toBeTruthy()
	end)

	t.it("3 or more runs returns personalized scoring with fallback=false", function()
		local result = Recommend.recommend(3, { "itemA" }, allItems, cooccur, counts, 3)
		expect(result.fallback).toBeFalsy()
		-- itemB co-occurs with owned itemA; itemC does not, so itemB must
		-- outrank itemC even though itemC's absolute score is 0 either way
		-- -- this just confirms the personalized path actually ran, not the
		-- baseline path silently reused.
		local ids: { string } = {}
		for _, rec in result.recommendations do
			table.insert(ids, rec.itemId)
		end
		expect(table.find(ids, "itemA")).toEqual(nil) -- owned, excluded
	end)

	t.it("more runs played never itself changes the fallback flag below the threshold", function()
		expect(Recommend.recommend(2, {}, allItems, cooccur, counts, 3).fallback).toBeTruthy()
		expect(Recommend.recommend(1, {}, allItems, cooccur, counts, 3).fallback).toBeTruthy()
		expect(Recommend.recommend(0, {}, allItems, cooccur, counts, 3).fallback).toBeTruthy()
	end)
end)
