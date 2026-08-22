--!strict
--[[ M7-3. core/anim/Lod -- tier boundaries and the 24-raycast budget.

	The Studio criterion is "40 entities, no popping at boundaries; raycast
	counter never exceeds 24". The counter half is a statement about a sort and
	a limit, which is exactly the kind of thing to prove here rather than by
	watching a number in a viewport.
]]

local t = require("./framework")
local expect = t.expect

local Lod = require("../src/shared/core/anim/Lod")

t.describe("Lod.tierFor -- docs/08 boundaries", function()
	t.it("matches the documented distances", function()
		expect(Lod.FULL_MAX).toEqual(40)
		expect(Lod.REDUCED_MAX).toEqual(90)
		expect(Lod.CLIP_MAX).toEqual(150)
		expect(Lod.RAYCAST_BUDGET).toEqual(24)
	end)

	t.it("assigns each band correctly", function()
		expect(Lod.tierFor(0)).toEqual("full")
		expect(Lod.tierFor(39.9)).toEqual("full")
		expect(Lod.tierFor(40)).toEqual("reduced")
		expect(Lod.tierFor(89.9)).toEqual("reduced")
		expect(Lod.tierFor(90)).toEqual("clip")
		expect(Lod.tierFor(149.9)).toEqual("clip")
		expect(Lod.tierFor(150)).toEqual("culled")
		expect(Lod.tierFor(10000)).toEqual("culled")
	end)

	t.it("has no gap or overlap at any boundary", function()
		-- Every distance must land in exactly one tier. A gap here is an
		-- entity that renders as nothing.
		for distance = 0, 200, 0.5 do
			local tier = Lod.tierFor(distance)
			expect(tier == "full" or tier == "reduced" or tier == "clip" or tier == "culled").toBeTruthy()
		end
	end)

	t.it("treats NaN as furthest, never as nearest", function()
		-- A NaN distance sorting to the front would hand it a raycast slot
		-- ahead of an entity actually on screen.
		expect(Lod.tierFor(0 / 0)).toEqual("culled")
	end)
end)

t.describe("Lod.shouldStepGait", function()
	t.it("full steps every frame", function()
		for frame = 1, 10 do
			expect(Lod.shouldStepGait("full", frame)).toBeTruthy()
		end
	end)

	t.it("reduced steps at half rate", function()
		local stepped = 0
		for frame = 1, 100 do
			if Lod.shouldStepGait("reduced", frame) then
				stepped += 1
			end
		end
		expect(stepped).toEqual(50)
	end)

	t.it("clip and culled never step the gait", function()
		for frame = 1, 10 do
			expect(Lod.shouldStepGait("clip", frame)).never().toBeTruthy()
			expect(Lod.shouldStepGait("culled", frame)).never().toBeTruthy()
		end
	end)
end)

t.describe("Lod.allocateRaycasts -- the 24/frame budget", function()
	local function candidates(count: number, spacing: number): { Lod.Candidate }
		local out: { Lod.Candidate } = {}
		for i = 1, count do
			out[i] = { id = i, distance = i * spacing }
		end
		return out
	end

	local function size(granted: { [number]: boolean }): number
		local n = 0
		for _ in granted do
			n += 1
		end
		return n
	end

	t.it("never exceeds the budget, with 40 entities all in range", function()
		-- The Studio criterion, as a unit test. 40 entities inside 40 studs
		-- means every one is eligible and 16 must go without.
		local all: { Lod.Candidate } = {}
		for i = 1, 40 do
			all[i] = { id = i, distance = i * 0.5 } -- 0.5 .. 20 studs, all "full"
		end
		local granted = Lod.allocateRaycasts(all)
		expect(size(granted)).toEqual(24)
	end)

	t.it("grants everyone when there are fewer than the budget", function()
		local granted = Lod.allocateRaycasts(candidates(10, 1))
		expect(size(granted)).toEqual(10)
	end)

	t.it("prefers the nearest entities", function()
		-- 30 entities at 1..30 studs; the 24 nearest are ids 1..24.
		local granted = Lod.allocateRaycasts(candidates(30, 1))
		for id = 1, 24 do
			expect(granted[id]).toBeTruthy()
		end
		for id = 25, 30 do
			expect(granted[id]).never().toBeTruthy()
		end
	end)

	t.it("only 'full' tier entities are eligible at all", function()
		-- A distant entity consuming budget it is documented never to use
		-- would starve a near one that needs it.
		local mixed: { Lod.Candidate } = {
			{ id = 1, distance = 10 }, -- full
			{ id = 2, distance = 50 }, -- reduced
			{ id = 3, distance = 100 }, -- clip
			{ id = 4, distance = 200 }, -- culled
		}
		local granted = Lod.allocateRaycasts(mixed)
		expect(granted[1]).toBeTruthy()
		expect(granted[2]).never().toBeTruthy()
		expect(granted[3]).never().toBeTruthy()
		expect(granted[4]).never().toBeTruthy()
		expect(size(granted)).toEqual(1)
	end)

	t.it("never exceeds the budget under any random population", function()
		-- Fuzzed rather than argued: the budget is a hard cap from docs/08,
		-- and a single frame over it is a frame over it.
		local seed = 12345
		local function nextRandom(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		for _ = 1, 500 do
			local population: { Lod.Candidate } = {}
			local count = math.floor(nextRandom() * 80) + 1
			for i = 1, count do
				population[i] = { id = i, distance = nextRandom() * 200 }
			end
			expect(size(Lod.allocateRaycasts(population)) <= Lod.RAYCAST_BUDGET).toBeTruthy()
		end
	end)

	t.it("is deterministic for equal distances, so entities do not swap frame to frame", function()
		-- Two entities at exactly equal distance alternating places would give
		-- each of them a stale plane every other frame, forever.
		local tied: { Lod.Candidate } = {}
		for i = 1, 30 do
			tied[i] = { id = i, distance = 10 }
		end
		local first = Lod.allocateRaycasts(tied)
		for _ = 1, 5 do
			local again = Lod.allocateRaycasts(tied)
			for id = 1, 30 do
				expect(again[id] == first[id]).toBeTruthy()
			end
		end
	end)

	t.it("a zero budget grants nothing rather than erroring", function()
		expect(size(Lod.allocateRaycasts(candidates(10, 1), 0))).toEqual(0)
	end)

	t.it("an empty population is fine", function()
		expect(size(Lod.allocateRaycasts({}))).toEqual(0)
	end)
end)

t.describe("Lod.census", function()
	t.it("counts each tier", function()
		local mixed: { Lod.Candidate } = {
			{ id = 1, distance = 5 },
			{ id = 2, distance = 30 },
			{ id = 3, distance = 60 },
			{ id = 4, distance = 120 },
			{ id = 5, distance = 500 },
		}
		local counts = Lod.census(mixed)
		expect(counts.full).toEqual(2)
		expect(counts.reduced).toEqual(1)
		expect(counts.clip).toEqual(1)
		expect(counts.culled).toEqual(1)
	end)
end)
