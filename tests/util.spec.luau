--!strict

local t = require("./framework")
local expect = t.expect

local Rng = require("../src/shared/core/util/Rng")
local Ring = require("../src/shared/core/util/Ring")
local Result = require("../src/shared/core/util/Result")
local Clock = require("../src/shared/core/util/Clock")

--------------------------------------------------------------------------------

t.describe("util/Rng", function()
	t.it("is deterministic for a given seed", function()
		local a, b = Rng.new(12345), Rng.new(12345)
		for _ = 1, 100 do
			expect(Rng.nextInt(a)).toEqual(Rng.nextInt(b))
		end
	end)

	t.it("produces different streams for different seeds", function()
		local a, b = Rng.new(1), Rng.new(2)
		local same = 0
		for _ = 1, 50 do
			if Rng.nextInt(a) == Rng.nextInt(b) then
				same += 1
			end
		end
		expect(same < 5).toBeTruthy()
	end)

	t.it("remaps seed 0 instead of degenerating", function()
		local zero = Rng.new(0)
		-- xorshift is a fixed point at 0; a naive impl returns 0 forever.
		expect(Rng.nextInt(zero)).never().toEqual(0)
		expect(Rng.nextInt(zero)).never().toEqual(0)
	end)

	t.it("nextNumber stays in [0, 1)", function()
		local r = Rng.new(99)
		for _ = 1, 1000 do
			local v = Rng.nextNumber(r)
			expect(v >= 0 and v < 1).toBeTruthy()
		end
	end)

	t.it("nextRange respects inclusive bounds", function()
		local r = Rng.new(7)
		local seenMin, seenMax = false, false
		for _ = 1, 2000 do
			local v = Rng.nextRange(r, 3, 6)
			expect(v >= 3 and v <= 6).toBeTruthy()
			expect(v).toEqual(math.floor(v))
			if v == 3 then seenMin = true end
			if v == 6 then seenMax = true end
		end
		expect(seenMin).toBeTruthy()
		expect(seenMax).toBeTruthy()
	end)

	t.it("nextRange handles a single-value span", function()
		local r = Rng.new(3)
		for _ = 1, 20 do
			expect(Rng.nextRange(r, 5, 5)).toEqual(5)
		end
	end)

	t.it("nextRange rejects an inverted range", function()
		local r = Rng.new(3)
		expect(function()
			Rng.nextRange(r, 10, 2)
		end).toThrow("max")
	end)

	t.it("pick rejects an empty list", function()
		local r = Rng.new(3)
		expect(function()
			Rng.pick(r, {} :: { number })
		end).toThrow("empty")
	end)

	t.it("shuffle preserves membership", function()
		local r = Rng.new(42)
		local list = { 1, 2, 3, 4, 5, 6, 7, 8 }
		Rng.shuffle(r, list)
		table.sort(list)
		expect(list).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8 })
	end)

	t.it("state can be saved and restored to replay a sequence", function()
		local r = Rng.new(2024)
		Rng.nextInt(r)
		local saved = Rng.getState(r)
		local expected = { Rng.nextInt(r), Rng.nextInt(r), Rng.nextInt(r) }
		Rng.setState(r, saved)
		expect({ Rng.nextInt(r), Rng.nextInt(r), Rng.nextInt(r) }).toEqual(expected)
	end)
end)

--------------------------------------------------------------------------------

t.describe("util/Ring", function()
	t.it("rejects a zero capacity", function()
		expect(function()
			Ring.new(0)
		end).toThrow("capacity")
	end)

	t.it("reads back newest-first before wrapping", function()
		local r = Ring.new(5) :: Ring.Ring<number>
		Ring.push(r, 10)
		Ring.push(r, 20)
		Ring.push(r, 30)
		expect(Ring.get(r, 1)).toEqual(30)
		expect(Ring.get(r, 2)).toEqual(20)
		expect(Ring.get(r, 3)).toEqual(10)
		expect(Ring.get(r, 4)).toBeNil()
	end)

	t.it("evicts the oldest entry when full", function()
		local r = Ring.new(3) :: Ring.Ring<number>
		expect(Ring.push(r, 1)).toBeNil()
		expect(Ring.push(r, 2)).toBeNil()
		expect(Ring.push(r, 3)).toBeNil()
		expect(Ring.push(r, 4)).toEqual(1)
		expect(Ring.toList(r)).toEqual({ 4, 3, 2 })
	end)

	t.it("stays correct across multiple wraparounds", function()
		local capacity = 20
		local r = Ring.new(capacity) :: Ring.Ring<number>
		for i = 1, 105 do
			Ring.push(r, i)
		end
		-- History holds 20 ticks; after 105 pushes the window is 86..105.
		expect(Ring.newest(r)).toEqual(105)
		expect(Ring.oldest(r)).toEqual(86)
		expect(r.count).toEqual(capacity)
	end)

	t.it("rejects an out-of-range age", function()
		local r = Ring.new(4) :: Ring.Ring<number>
		Ring.push(r, 1)
		expect(Ring.get(r, 0)).toBeNil()
		expect(Ring.get(r, 2)).toBeNil()
		expect(Ring.get(r, -1)).toBeNil()
	end)

	t.it("clear resets to empty and can be reused", function()
		local r = Ring.new(3) :: Ring.Ring<number>
		Ring.push(r, 1)
		Ring.push(r, 2)
		Ring.clear(r)
		expect(r.count).toEqual(0)
		expect(Ring.newest(r)).toBeNil()
		Ring.push(r, 9)
		expect(Ring.newest(r)).toEqual(9)
	end)

	t.it("reports fullness", function()
		local r = Ring.new(2) :: Ring.Ring<number>
		expect(Ring.isFull(r)).toBeFalsy()
		Ring.push(r, 1)
		Ring.push(r, 2)
		expect(Ring.isFull(r)).toBeTruthy()
	end)
end)

--------------------------------------------------------------------------------

t.describe("util/Result", function()
	t.it("carries a success value", function()
		local r = Result.ok(42)
		expect(r.ok).toBeTruthy()
		expect(Result.unwrapOr(r, 0)).toEqual(42)
	end)

	t.it("carries a failure reason", function()
		local r = Result.err("fire rate exceeded") :: Result.Result<number>
		expect(r.ok).toBeFalsy()
		expect(Result.unwrapOr(r, -1)).toEqual(-1)
	end)

	t.it("map transforms success and passes errors through", function()
		local doubled = Result.map(Result.ok(21), function(n: number)
			return n * 2
		end)
		expect(Result.unwrapOr(doubled, 0)).toEqual(42)

		local failed = Result.map(Result.err("nope") :: Result.Result<number>, function(n: number)
			return n * 2
		end)
		expect(failed.ok).toBeFalsy()
	end)

	t.it("andThen chains fallible steps and short-circuits", function()
		local function positive(n: number): Result.Result<number>
			if n > 0 then
				return Result.ok(n)
			end
			return Result.err("not positive")
		end

		expect(Result.unwrapOr(Result.andThen(Result.ok(5), positive), 0)).toEqual(5)
		expect(Result.andThen(Result.ok(-5), positive).ok).toBeFalsy()
		expect(Result.andThen(Result.err("earlier") :: Result.Result<number>, positive).ok).toBeFalsy()
	end)

	t.it("expect throws with context on failure", function()
		expect(function()
			Result.expect(Result.err("bad input") :: Result.Result<number>, "while parsing")
		end).toThrow("while parsing: bad input")
	end)
end)

--------------------------------------------------------------------------------

t.describe("util/Clock", function()
	t.it("starts where told and advances by hand", function()
		local c = Clock.manual(100)
		expect(Clock.get(c)).toEqual(100)
		Clock.advance(c, 0.05)
		expect(Clock.get(c)).approx(100.05, 1e-9)
	end)

	t.it("defaults to zero", function()
		expect(Clock.get(Clock.manual())).toEqual(0)
	end)

	t.it("rejects negative advance", function()
		local c = Clock.manual()
		expect(function()
			Clock.advance(c, -1)
		end).toThrow("seconds")
	end)

	t.it("reads through to a source-backed clock", function()
		local fake = 5
		local c = Clock.fromSource(function()
			return fake
		end)
		expect(Clock.get(c)).toEqual(5)
		fake = 9
		expect(Clock.get(c)).toEqual(9)
	end)

	t.it("refuses to advance a source-backed clock rather than silently ignoring", function()
		local c = Clock.fromSource(function()
			return 0
		end)
		expect(function()
			Clock.advance(c, 1)
		end).toThrow("source-backed")
		expect(function()
			Clock.set(c, 1)
		end).toThrow("source-backed")
	end)
end)
