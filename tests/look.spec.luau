--!strict
--[[ M7-5 / M7-7. core/look: the post-stack arithmetic, palette ramps, and the
	EditableImage allocation ledger.

	The budget in particular is tested here rather than in Studio on purpose:
	exceeding 8 live EditableImage instances fails at creation with a
	memory-budget error, so "the 9th allocation is refused cleanly" has to be
	provable without ever creating nine.
]]

local t = require("./framework")
local expect = t.expect

local ImageBudget = require("../src/shared/core/look/ImageBudget")
local LightingBlend = require("../src/shared/core/look/LightingBlend")
local Ramp = require("../src/shared/core/look/Ramp")
local ZonesConfig = require("../src/shared/config/Zones")

--------------------------------------------------------------------------------
-- LightingBlend
--------------------------------------------------------------------------------

local PERIMETER = ZonesConfig.Perimeter.lighting :: LightingBlend.Preset
local VAULT = ZonesConfig.Vault.lighting :: LightingBlend.Preset

t.describe("LightingBlend.lerpPreset", function()
	t.it("alpha 0 and 1 are the endpoints exactly", function()
		local atStart = LightingBlend.lerpPreset(PERIMETER, VAULT, 0)
		expect(atStart.fogEnd).approx(PERIMETER.fogEnd, 1e-9)
		expect(atStart.bloom).approx(PERIMETER.bloom, 1e-9)

		local atEnd = LightingBlend.lerpPreset(PERIMETER, VAULT, 1)
		expect(atEnd.fogEnd).approx(VAULT.fogEnd, 1e-9)
		expect(atEnd.contrast).approx(VAULT.contrast, 1e-9)
	end)

	t.it("the midpoint is the mean, hand-checked against config", function()
		-- Perimeter fogEnd 180, Vault 45 -> 112.5. bloom 0.6 -> 1.8 -> 1.2.
		local mid = LightingBlend.lerpPreset(PERIMETER, VAULT, 0.5)
		expect(mid.fogEnd).approx(112.5, 1e-9)
		expect(mid.bloom).approx(1.2, 1e-9)
		expect(mid.saturation).approx((-0.10 + -0.40) / 2, 1e-9)
	end)

	t.it("alpha outside [0,1] clamps rather than extrapolating", function()
		-- Extrapolating a fog distance produces a negative one, which is not a
		-- thing the renderer can be given.
		local under = LightingBlend.lerpPreset(PERIMETER, VAULT, -5)
		expect(under.fogEnd).approx(PERIMETER.fogEnd, 1e-9)
		local over = LightingBlend.lerpPreset(PERIMETER, VAULT, 5)
		expect(over.fogEnd).approx(VAULT.fogEnd, 1e-9)
	end)

	t.it("the documented transition length is 1.5s", function()
		expect(LightingBlend.TRANSITION_SECONDS).toEqual(1.5)
	end)
end)

t.describe("LightingBlend.threatWeight", function()
	t.it("is neutral at and below the ramp start", function()
		expect(LightingBlend.threatWeight(1)).toEqual(0)
		expect(LightingBlend.threatWeight(2)).toEqual(0)
		expect(LightingBlend.threatWeight(3)).toEqual(0)
	end)

	t.it("ramps rather than switching, so tier 4 is half strength", function()
		-- A step change in the post stack is a visible pop; escalation should
		-- read as escalation.
		expect(LightingBlend.threatWeight(4)).approx(0.5, 1e-9)
		expect(LightingBlend.threatWeight(5)).toEqual(1)
	end)

	t.it("saturates above tier 5 and never goes negative", function()
		expect(LightingBlend.threatWeight(9)).toEqual(1)
		expect(LightingBlend.threatWeight(-3)).toEqual(0)
	end)

	t.it("a NaN tier is treated as no threat rather than poisoning the stack", function()
		-- The tier arrives from the director; Clamp should never emit NaN, but
		-- a NaN reaching Lighting would blank the screen rather than fail loud.
		expect(LightingBlend.threatWeight(0 / 0)).toEqual(0)
	end)
end)

t.describe("LightingBlend.applyThreat", function()
	t.it("leaves a preset untouched at low tiers", function()
		local out = LightingBlend.applyThreat(PERIMETER, 1)
		expect(out.fogEnd).approx(PERIMETER.fogEnd, 1e-9)
		expect(out.bloom).approx(PERIMETER.bloom, 1e-9)
		expect(out.tintR).approx(PERIMETER.tintR, 1e-9)
	end)

	t.it("tightens fog by exactly 20% at full threat", function()
		local out = LightingBlend.applyThreat(PERIMETER, 5)
		expect(out.fogEnd).approx(PERIMETER.fogEnd * 0.8, 1e-9)
	end)

	t.it("pushes the tint toward red", function()
		local out = LightingBlend.applyThreat(PERIMETER, 5)
		expect(out.tintR > PERIMETER.tintR or PERIMETER.tintR >= 1).toBeTruthy()
		expect(out.tintG < PERIMETER.tintG).toBeTruthy()
		expect(out.tintB < PERIMETER.tintB).toBeTruthy()
		-- Red relative to the other channels is what "pushes red" means; the
		-- absolute value can clamp at 1.
		local before = PERIMETER.tintR - PERIMETER.tintB
		local after = out.tintR - out.tintB
		expect(after > before).toBeTruthy()
	end)

	t.it("raises bloom additively so a dim zone still responds", function()
		-- Scaling instead would make the Perimeter (bloom 0.6) barely react,
		-- and the Perimeter is exactly where escalation needs to be legible.
		local out = LightingBlend.applyThreat(PERIMETER, 5)
		expect(out.bloom).approx(PERIMETER.bloom + LightingBlend.THREAT_BLOOM, 1e-9)
	end)

	t.it("never lets a tint channel leave [0,1]", function()
		-- A channel above 1 brightens rather than tints: a blown-out frame,
		-- not menace.
		for tier = 1, 5 do
			for _, preset in { PERIMETER, VAULT, ZonesConfig.Processing.lighting } do
				local out = LightingBlend.applyThreat(preset :: LightingBlend.Preset, tier)
				expect(out.tintR >= 0 and out.tintR <= 1).toBeTruthy()
				expect(out.tintG >= 0 and out.tintG <= 1).toBeTruthy()
				expect(out.tintB >= 0 and out.tintB <= 1).toBeTruthy()
			end
		end
	end)

	t.it("never produces a negative fog distance", function()
		for tier = 0, 10 do
			local out = LightingBlend.applyThreat(VAULT, tier)
			expect(out.fogEnd > 0).toBeTruthy()
		end
	end)
end)

t.describe("LightingBlend.resolve -- zones blend first, then threat applies", function()
	t.it("equals applyThreat(lerpPreset(...)) exactly", function()
		local expected = LightingBlend.applyThreat(LightingBlend.lerpPreset(PERIMETER, VAULT, 0.3), 4)
		local actual = LightingBlend.resolve(PERIMETER, VAULT, 0.3, 4)
		expect(actual.fogEnd).approx(expected.fogEnd, 1e-12)
		expect(actual.bloom).approx(expected.bloom, 1e-12)
		expect(actual.tintR).approx(expected.tintR, 1e-12)
	end)

	t.it("a tier change is felt immediately, even mid-transition", function()
		-- The ordering that matters. If threat were baked into each endpoint
		-- and then blended, a tier change would take the full 1.5s transition
		-- to appear -- making the director look slow exactly when it is trying
		-- to look present.
		local calm = LightingBlend.resolve(PERIMETER, VAULT, 0.5, 1)
		local alarmed = LightingBlend.resolve(PERIMETER, VAULT, 0.5, 5)
		expect(alarmed.fogEnd < calm.fogEnd).toBeTruthy()
		expect(alarmed.bloom > calm.bloom).toBeTruthy()
	end)

	t.it("descending the zones desaturates and closes the fog in", function()
		-- docs/08's stated intent: "the zones read as descent without any new
		-- art". Worth pinning, since it is a property of the config values.
		local perimeter = LightingBlend.resolve(PERIMETER, PERIMETER, 0, 1)
		local vault = LightingBlend.resolve(VAULT, VAULT, 0, 1)
		expect(vault.saturation < perimeter.saturation).toBeTruthy()
		expect(vault.fogEnd < perimeter.fogEnd).toBeTruthy()
		expect(vault.contrast > perimeter.contrast).toBeTruthy()
	end)
end)

--------------------------------------------------------------------------------
-- Ramp
--------------------------------------------------------------------------------

t.describe("Ramp.sample", function()
	local twoStop = Ramp.new({
		{ position = 0, color = Ramp.color(0, 0, 0) },
		{ position = 1, color = Ramp.color(1, 0.5, 0.25) },
	})

	t.it("returns the endpoints exactly", function()
		local start = Ramp.sample(twoStop, 0)
		expect(start.r).toEqual(0)
		local finish = Ramp.sample(twoStop, 1)
		expect(finish.r).toEqual(1)
		expect(finish.g).toEqual(0.5)
		expect(finish.b).toEqual(0.25)
	end)

	t.it("the midpoint is the mean of the surrounding stops", function()
		local mid = Ramp.sample(twoStop, 0.5)
		expect(mid.r).approx(0.5, 1e-9)
		expect(mid.g).approx(0.25, 1e-9)
		expect(mid.b).approx(0.125, 1e-9)
	end)

	t.it("clamps outside [0,1] rather than extrapolating past the palette", function()
		expect(Ramp.sample(twoStop, -2).r).toEqual(0)
		expect(Ramp.sample(twoStop, 7).r).toEqual(1)
	end)

	t.it("interpolates within the correct segment of a three-stop ramp", function()
		local three = Ramp.new({
			{ position = 0.0, color = Ramp.color(0, 0, 0) },
			{ position = 0.25, color = Ramp.color(1, 1, 1) },
			{ position = 1.0, color = Ramp.color(0, 0, 0) },
		})
		expect(Ramp.sample(three, 0.125).r).approx(0.5, 1e-9)
		expect(Ramp.sample(three, 0.25).r).approx(1, 1e-9)
		-- Halfway down the long second segment.
		expect(Ramp.sample(three, 0.625).r).approx(0.5, 1e-9)
	end)

	t.it("a single-stop ramp is that colour everywhere", function()
		local flat = Ramp.new({ { position = 0.5, color = Ramp.color(0.2, 0.4, 0.6) } })
		for _, position in { 0, 0.5, 1 } do
			expect(Ramp.sample(flat, position).g).approx(0.4, 1e-9)
		end
	end)

	t.it("coincident stops make a hard edge rather than dividing by zero", function()
		local hard = Ramp.new({
			{ position = 0, color = Ramp.color(0, 0, 0) },
			{ position = 0.5, color = Ramp.color(0, 0, 0) },
			{ position = 0.5, color = Ramp.color(1, 1, 1) },
			{ position = 1, color = Ramp.color(1, 1, 1) },
		})
		expect(Ramp.sample(hard, 0.4999).r < 0.01).toBeTruthy()
		expect(Ramp.sample(hard, 0.5).r).toEqual(1)
	end)
end)

t.describe("Ramp.new validation", function()
	t.it("rejects an empty stop list", function()
		expect(function()
			Ramp.new({})
		end).toThrow("at least one stop")
	end)

	t.it("rejects unsorted stops rather than silently sorting them", function()
		-- Re-sorting would hide an authoring mistake that is otherwise obvious.
		expect(function()
			Ramp.new({
				{ position = 0.8, color = Ramp.color(0, 0, 0) },
				{ position = 0.2, color = Ramp.color(1, 1, 1) },
			})
		end).toThrow("before the previous stop")
	end)

	t.it("rejects a stop outside [0,1]", function()
		expect(function()
			Ramp.new({ { position = 1.5, color = Ramp.color(0, 0, 0) } })
		end).toThrow("outside")
	end)
end)

t.describe("Ramp.rasterize", function()
	local ramp = Ramp.new({
		{ position = 0, color = Ramp.color(0, 0, 0) },
		{ position = 1, color = Ramp.color(1, 1, 1) },
	})

	t.it("produces exactly the requested width", function()
		expect(#Ramp.rasterize(ramp, 256)).toEqual(256)
		expect(#Ramp.rasterize(ramp, 1)).toEqual(1)
	end)

	t.it("the first and last pixels are the ramp's own endpoints", function()
		-- An off-by-one here shows up as a palette that never quite reaches
		-- its darkest or brightest colour.
		local pixels = Ramp.rasterize(ramp, 64)
		expect(pixels[1].r).toEqual(0)
		expect(pixels[64].r).toEqual(1)
	end)

	t.it("is monotonic across a monotonic ramp", function()
		local pixels = Ramp.rasterize(ramp, 128)
		for i = 2, #pixels do
			expect(pixels[i].r >= pixels[i - 1].r).toBeTruthy()
		end
	end)

	t.it("rejects a zero or negative width", function()
		expect(function()
			Ramp.rasterize(ramp, 0)
		end).toThrow("width must be")
	end)
end)

t.describe("Ramp presets", function()
	t.it("the damage ramp runs critical-red to healthy-green", function()
		local ramp = Ramp.damageState()
		local critical = Ramp.sample(ramp, 0)
		local healthy = Ramp.sample(ramp, 1)
		expect(critical.r > critical.g).toBeTruthy()
		expect(healthy.g > healthy.r).toBeTruthy()
	end)

	t.it("the threat ramp gets redder with tier", function()
		local ramp = Ramp.threatTier()
		local calm = Ramp.sample(ramp, 0)
		local alarmed = Ramp.sample(ramp, 1)
		expect(alarmed.r - alarmed.b > calm.r - calm.b).toBeTruthy()
	end)
end)

--------------------------------------------------------------------------------
-- ImageBudget
--------------------------------------------------------------------------------

t.describe("ImageBudget -- the 8-instance cap", function()
	t.it("matches the documented caps", function()
		expect(ImageBudget.HARD_CAP).toEqual(8)
		expect(ImageBudget.RESERVED).toEqual(2)
		expect(ImageBudget.NORMAL_CAP).toEqual(6)
	end)

	t.it("hands out slots up to the normal cap", function()
		local budget = ImageBudget.new()
		for i = 1, ImageBudget.NORMAL_CAP do
			local handle, reason = ImageBudget.acquire(budget, `use{i}`)
			expect(handle).never().toEqual(nil :: any)
			expect(reason).toEqual(nil :: any)
		end
		expect(budget.liveCount).toEqual(6)
	end)

	t.it("refuses the 7th normal allocation cleanly, without throwing", function()
		-- The M7-7 accept criterion. Refusing has to be a return value, not an
		-- error: the whole point is that the caller learns it cannot allocate
		-- *before* touching Instance.new, and a manager that threw would just
		-- relocate the crash it exists to prevent.
		local budget = ImageBudget.new()
		for i = 1, ImageBudget.NORMAL_CAP do
			ImageBudget.acquire(budget, `use{i}`)
		end

		local handle, reason
		local ok = pcall(function()
			handle, reason = ImageBudget.acquire(budget, "one_too_many")
		end)
		expect(ok).toBeTruthy() -- did not throw
		expect(handle).toEqual(nil :: any)
		expect(reason).never().toEqual(nil :: any)
		expect(budget.liveCount).toEqual(6) -- nothing was consumed by the refusal
		expect(budget.refusals).toEqual(1)
	end)

	t.it("the reserve is not spendable by ordinary callers", function()
		-- A reserve anything may claim is not a reserve.
		local budget = ImageBudget.new()
		for i = 1, ImageBudget.NORMAL_CAP do
			ImageBudget.acquire(budget, `use{i}`)
		end
		expect(ImageBudget.canAcquire(budget, false)).never().toBeTruthy()
		expect(ImageBudget.canAcquire(budget, true)).toBeTruthy()
	end)

	t.it("even a reserved caller cannot exceed the hard cap", function()
		local budget = ImageBudget.new()
		for i = 1, ImageBudget.HARD_CAP do
			local handle = ImageBudget.acquire(budget, `use{i}`, true)
			expect(handle).never().toEqual(nil :: any)
		end
		expect(budget.liveCount).toEqual(8)
		local ninth, reason = ImageBudget.acquire(budget, "ninth", true)
		expect(ninth).toEqual(nil :: any)
		expect(reason).never().toEqual(nil :: any)
		expect(budget.liveCount).toEqual(8)
	end)

	t.it("acquiring the same purpose twice reuses the slot", function()
		-- A caller re-acquiring after a zone change wants "the zone palette
		-- image", not a second one.
		local budget = ImageBudget.new()
		local first = ImageBudget.acquire(budget, "zone_palette")
		local second = ImageBudget.acquire(budget, "zone_palette")
		expect(second).toEqual(first)
		expect(budget.liveCount).toEqual(1)
	end)

	t.it("release frees the slot for someone else", function()
		local budget = ImageBudget.new()
		for i = 1, ImageBudget.NORMAL_CAP do
			ImageBudget.acquire(budget, `use{i}`)
		end
		expect(ImageBudget.acquire(budget, "late")).toEqual(nil :: any)

		expect(ImageBudget.release(budget, "use1")).toBeTruthy()
		expect(budget.liveCount).toEqual(5)
		expect(ImageBudget.acquire(budget, "late")).never().toEqual(nil :: any)
	end)

	t.it("a double release does not drive the count negative", function()
		local budget = ImageBudget.new()
		ImageBudget.acquire(budget, "zone_palette")
		expect(ImageBudget.release(budget, "zone_palette")).toBeTruthy()
		expect(ImageBudget.release(budget, "zone_palette")).never().toBeTruthy()
		expect(budget.liveCount).toEqual(0)
	end)

	t.it("tracks peak usage, which is the number docs/08 wants monitored", function()
		-- The exit criterion is "allocation never exceeds 6 of 8 in normal
		-- play", which is a statement about the peak, not the instantaneous.
		local budget = ImageBudget.new()
		for i = 1, 5 do
			ImageBudget.acquire(budget, `use{i}`)
		end
		for i = 1, 5 do
			ImageBudget.release(budget, `use{i}`)
		end
		expect(budget.liveCount).toEqual(0)
		expect(budget.peak).toEqual(5)
		expect(ImageBudget.describe(budget).peak).toEqual(5)
	end)

	t.it("a full acquire/release cycle over many zone changes never leaks", function()
		-- The realistic failure: the zone palette is re-acquired on every
		-- transition and the old one is never released, so the budget bleeds
		-- one slot per zone until the 7th transition throws.
		local budget = ImageBudget.new()
		for _ = 1, 100 do
			ImageBudget.acquire(budget, "zone_palette")
			ImageBudget.release(budget, "zone_palette")
		end
		expect(budget.liveCount).toEqual(0)
		expect(budget.refusals).toEqual(0)
		expect(budget.peak).toEqual(1)
	end)
end)
