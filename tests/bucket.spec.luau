--!strict
--[[ M5-2. Bucketing and the widening schedule. Accept criteria from
	tasks/BACKLOG.md: boundaries exact, no player in two buckets, 75s
	triggers undersized start.
]]

local t = require("./framework")
local expect = t.expect

local Bucket = require("../src/shared/core/discovery/Bucket")

t.describe("Bucket.bucketFor", function()
	t.it("matches docs/06's own worked example: 1250 -> bucket 12", function()
		expect(Bucket.bucketFor(1250)).toEqual(12)
	end)

	t.it("boundaries are exact: 1299 stays in 12, 1300 moves to 13", function()
		expect(Bucket.bucketFor(1299)).toEqual(12)
		expect(Bucket.bucketFor(1300)).toEqual(13)
	end)

	t.it("boundaries are exact at zero and the first width", function()
		expect(Bucket.bucketFor(0)).toEqual(0)
		expect(Bucket.bucketFor(99)).toEqual(0)
		expect(Bucket.bucketFor(100)).toEqual(1)
	end)

	t.it("no player is ever in two buckets: bucketFor is a pure function of rating alone", function()
		-- Every rating in a dense sweep maps to exactly one bucket, and the
		-- same rating always maps to the same bucket -- there is no
		-- membership ambiguity to test for beyond "the function is pure,"
		-- which this sweep demonstrates isn't merely assumed.
		for rating = 1000, 2000, 7 do
			local a = Bucket.bucketFor(rating)
			local b = Bucket.bucketFor(rating)
			expect(a).toEqual(b)
			expect(a).toEqual(math.floor(rating / 100))
		end
	end)
end)

t.describe("Bucket.stageFor", function()
	t.it("own bucket only below 15s", function()
		expect(Bucket.stageFor(0)).toEqual("own")
		expect(Bucket.stageFor(14.9)).toEqual("own")
	end)

	t.it("radius1 from exactly 15s", function()
		expect(Bucket.stageFor(15)).toEqual("radius1")
		expect(Bucket.stageFor(29.9)).toEqual("radius1")
	end)

	t.it("radius2 from exactly 30s", function()
		expect(Bucket.stageFor(30)).toEqual("radius2")
		expect(Bucket.stageFor(44.9)).toEqual("radius2")
	end)

	t.it("any bucket from exactly 45s", function()
		expect(Bucket.stageFor(45)).toEqual("any")
		expect(Bucket.stageFor(74.9)).toEqual("any")
	end)

	t.it("75s triggers undersized start -- the literal accept criterion", function()
		expect(Bucket.stageFor(75)).toEqual("undersized")
		expect(Bucket.stageFor(74.999)).toEqual("any")
		expect(Bucket.stageFor(75.001)).toEqual("undersized")
		expect(Bucket.stageFor(1000)).toEqual("undersized")
	end)
end)

t.describe("Bucket.inSearchRange", function()
	t.it("'own' matches only the exact same bucket", function()
		expect(Bucket.inSearchRange(12, 12, "own")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 11, "own")).toBeFalsy()
		expect(Bucket.inSearchRange(12, 13, "own")).toBeFalsy()
	end)

	t.it("'radius1' boundary is exact: distance 1 in, distance 2 out", function()
		expect(Bucket.inSearchRange(12, 11, "radius1")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 13, "radius1")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 10, "radius1")).toBeFalsy()
		expect(Bucket.inSearchRange(12, 14, "radius1")).toBeFalsy()
	end)

	t.it("'radius2' boundary is exact: distance 2 in, distance 3 out", function()
		expect(Bucket.inSearchRange(12, 10, "radius2")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 14, "radius2")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 9, "radius2")).toBeFalsy()
		expect(Bucket.inSearchRange(12, 15, "radius2")).toBeFalsy()
	end)

	t.it("'any' and 'undersized' accept every candidate regardless of distance", function()
		expect(Bucket.inSearchRange(12, 0, "any")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 999, "any")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 0, "undersized")).toBeTruthy()
		expect(Bucket.inSearchRange(12, 999, "undersized")).toBeTruthy()
	end)
end)
