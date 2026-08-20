--!strict

local t = require("./framework")
local expect = t.expect

local Quantize = require("../src/shared/core/net/Quantize")
local Rng = require("../src/shared/core/util/Rng")

local TAU = math.pi * 2

t.describe("net/Quantize position", function()
	t.it("roundtrips 10k random positions within the documented error bound", function()
		local rng = Rng.new(20260815)
		local worst = 0
		for _ = 1, 10000 do
			-- Full representable range, both signs.
			local value = (Rng.nextNumber(rng) * 2 - 1) * 1638
			local back = Quantize.snapPosition(value)
			worst = math.max(worst, math.abs(back - value))
		end
		expect(worst <= Quantize.POSITION_MAX_ERROR).toBeTruthy()
		-- Guard against a change that silently widens the grid: the worst case
		-- over 10k samples should approach the bound, not sit far below it.
		expect(worst > Quantize.POSITION_MAX_ERROR * 0.9).toBeTruthy()
	end)

	t.it("encodes exact grid multiples without error", function()
		for steps = -2000, 2000, 137 do
			local exact = steps * Quantize.POSITION_GRID
			expect(Quantize.encodePosition(exact)).toEqual(steps)
			expect(Quantize.snapPosition(exact)).approx(exact, 1e-12)
		end
	end)

	t.it("handles zero and small negatives without sign errors", function()
		expect(Quantize.encodePosition(0)).toEqual(0)
		expect(Quantize.encodePosition(-0.05)).toEqual(-1)
		expect(Quantize.encodePosition(0.05)).toEqual(1)
		expect(Quantize.snapPosition(-0.024)).approx(0, 1e-12)
		expect(Quantize.snapPosition(-0.026)).approx(-0.05, 1e-12)
	end)

	t.it("saturates at the int16 boundary instead of wrapping", function()
		-- Wrapping would teleport an out-of-bounds entity to the opposite
		-- corner of the level, which is far worse than pinning it at the edge.
		expect(Quantize.encodePosition(99999)).toEqual(32767)
		expect(Quantize.encodePosition(-99999)).toEqual(-32768)
		expect(Quantize.snapPosition(99999) > 0).toBeTruthy()
		expect(Quantize.snapPosition(-99999) < 0).toBeTruthy()
	end)

	t.it("exposes range constants consistent with int16", function()
		expect(Quantize.POSITION_MAX).approx(1638.35, 1e-9)
		expect(Quantize.POSITION_MIN).approx(-1638.4, 1e-9)
		expect(Quantize.encodePosition(Quantize.POSITION_MAX)).toEqual(32767)
		expect(Quantize.encodePosition(Quantize.POSITION_MIN)).toEqual(-32768)
	end)

	t.it("rejects NaN rather than serialising garbage", function()
		expect(function()
			Quantize.encodePosition(0 / 0)
		end).toThrow("NaN")
	end)
end)

t.describe("net/Quantize yaw", function()
	t.it("roundtrips 10k random angles within 0.703 degrees", function()
		local rng = Rng.new(4242)
		local worst = 0
		for _ = 1, 10000 do
			local radians = Rng.nextNumber(rng) * TAU
			local back = Quantize.snapYaw(radians)
			local delta = math.abs(Quantize.yawDelta(radians, back))
			worst = math.max(worst, delta)
		end
		expect(worst <= Quantize.YAW_MAX_ERROR + 1e-12).toBeTruthy()
		expect(math.deg(Quantize.YAW_MAX_ERROR)).approx(0.703, 0.01)
	end)

	t.it("stays in range for every encoded value", function()
		for encoded = 0, 255 do
			local radians = Quantize.decodeYaw(encoded)
			expect(radians >= 0 and radians < TAU).toBeTruthy()
			expect(Quantize.encodeYaw(radians)).toEqual(encoded)
		end
	end)

	t.it("wraps negative and oversized angles instead of clamping", function()
		-- Unlike position, an out-of-range angle is meaningful: it wraps.
		expect(Quantize.encodeYaw(0)).toEqual(0)
		expect(Quantize.encodeYaw(TAU)).toEqual(0)
		expect(Quantize.encodeYaw(-TAU)).toEqual(0)
		expect(Quantize.encodeYaw(TAU * 3)).toEqual(0)
		expect(Quantize.encodeYaw(-math.pi / 2)).toEqual(Quantize.encodeYaw(TAU * 0.75))
	end)

	t.it("never emits 256, which would overflow a uint8", function()
		local rng = Rng.new(7)
		for _ = 1, 5000 do
			local radians = (Rng.nextNumber(rng) * 4 - 2) * TAU
			local encoded = Quantize.encodeYaw(radians)
			expect(encoded >= 0 and encoded <= 255).toBeTruthy()
			expect(encoded).toEqual(math.floor(encoded))
		end
		-- The specific value that rounds up to 256 before wrapping.
		expect(Quantize.encodeYaw(TAU - 1e-9)).toEqual(0)
	end)

	t.it("yawDelta takes the short way round", function()
		local d = Quantize.yawDelta(math.rad(350), math.rad(10))
		expect(math.deg(d)).approx(20, 1e-9)

		local back = Quantize.yawDelta(math.rad(10), math.rad(350))
		expect(math.deg(back)).approx(-20, 1e-9)

		expect(Quantize.yawDelta(0, 0)).approx(0, 1e-12)
		-- Exactly opposite: pi, not -pi, by the (-pi, pi] convention.
		expect(Quantize.yawDelta(0, math.pi)).approx(math.pi, 1e-9)
	end)

	t.it("rejects NaN", function()
		expect(function()
			Quantize.encodeYaw(0 / 0)
		end).toThrow("NaN")
	end)

	-- Regression from an audit pass: `inf % TAU` is NaN in Lua, so an infinite
	-- yaw slipped past the NaN-only guard, returned NaN, and buffer.writeu8
	-- wrote it as 0 without erroring -- silent corruption of exactly the kind
	-- the NaN guard exists to prevent.
	t.it("rejects infinite yaw rather than silently encoding it as 0", function()
		expect(function()
			Quantize.encodeYaw(math.huge)
		end).toThrow("infinite")
		expect(function()
			Quantize.encodeYaw(-math.huge)
		end).toThrow("infinite")
	end)

	-- The counterpart: position and unit encoding are documented to *saturate*
	-- rather than throw, so infinity must stay in-range there, not error.
	t.it("position and unit saturate on infinity instead of throwing", function()
		expect(Quantize.encodePosition(math.huge)).toEqual(32767)
		expect(Quantize.encodePosition(-math.huge)).toEqual(-32768)
		expect(Quantize.encodeUnit(math.huge)).toEqual(255)
		expect(Quantize.encodeUnit(-math.huge)).toEqual(0)
	end)
end)

t.describe("net/Quantize unit", function()
	t.it("roundtrips the unit interval within bound", function()
		local rng = Rng.new(31337)
		local worst = 0
		for _ = 1, 5000 do
			local value = Rng.nextNumber(rng)
			worst = math.max(worst, math.abs(Quantize.snapUnit(value) - value))
		end
		expect(worst <= Quantize.UNIT_MAX_ERROR + 1e-12).toBeTruthy()
	end)

	t.it("maps the endpoints exactly", function()
		expect(Quantize.encodeUnit(0)).toEqual(0)
		expect(Quantize.encodeUnit(1)).toEqual(255)
		expect(Quantize.decodeUnit(0)).toEqual(0)
		expect(Quantize.decodeUnit(255)).toEqual(1)
	end)

	t.it("clamps out-of-range input", function()
		expect(Quantize.encodeUnit(-5)).toEqual(0)
		expect(Quantize.encodeUnit(5)).toEqual(255)
		expect(Quantize.decodeUnit(-5)).toEqual(0)
		expect(Quantize.decodeUnit(999)).toEqual(1)
	end)

	t.it("distinguishes full health from nearly-full", function()
		-- A dead entity and a 1-hp entity must not encode identically, or the
		-- client will render corpses as alive.
		expect(Quantize.encodeUnit(0)).never().toEqual(Quantize.encodeUnit(0.01))
		expect(Quantize.encodeUnit(1)).never().toEqual(Quantize.encodeUnit(0.99))
	end)

	t.it("rejects NaN", function()
		expect(function()
			Quantize.encodeUnit(0 / 0)
		end).toThrow("NaN")
	end)
end)
