--!strict
--[[ Reload timing.

	The cases that matter are the ones that let a player cheat the timer or
	lock themselves out of firing: restarting a reload that is already running,
	reloading a full magazine, completing early, and finishing a reload for a
	weapon that was switched away from.
]]

local t = require("./framework")
local expect = t.expect

local Reload = require("../src/shared/core/sim/Reload")
local Weapons = require("../src/shared/config/Weapons")

local SIDEARM: Reload.Weapon = { magazine = 14, reloadSeconds = 1.4 }
local SLUG: Reload.Weapon = { magazine = 6, reloadSeconds = 2.8 }

--------------------------------------------------------------------------------

t.describe("Reload.begin", function()
	t.it("starts a reload on a partly empty magazine", function()
		local state = Reload.new()
		local ok, reason = Reload.begin(state, "Sidearm", SIDEARM, 3, 0)
		expect(ok).toBeTruthy()
		expect(reason).toBeNil()
		expect(Reload.isReloading(state, "Sidearm", 0)).toBeTruthy()
	end)

	t.it("refuses a full magazine without starting a timer", function()
		-- Not an error worth punishing -- it is a keypress with nothing to do --
		-- but it must not restart the clock either, or holding the key would
		-- lock the weapon out of firing forever.
		local state = Reload.new()
		local ok, reason = Reload.begin(state, "Sidearm", SIDEARM, 14, 0)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("magazine_full")
		expect(Reload.isReloading(state, "Sidearm", 0)).toBeFalsy()
	end)

	t.it("refuses to restart a reload already in flight", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		local ok, reason = Reload.begin(state, "Sidearm", SIDEARM, 0, 0.7)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("already_reloading")
	end)

	t.it("does not let a restart attempt extend the original deadline", function()
		-- The exploit this closes in reverse: if a rejected restart still wrote
		-- the timer, spamming the key would hold the weapon hostage.
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		for at = 0.1, 1.3, 0.1 do
			Reload.begin(state, "Sidearm", SIDEARM, 0, at)
		end
		expect(#Reload.collect(state, 1.4)).toEqual(1)
	end)

	t.it("refuses a non-finite clock", function()
		local state = Reload.new()
		expect(select(2, Reload.begin(state, "Sidearm", SIDEARM, 0, 0 / 0))).toEqual("bad_clock")
		expect(select(2, Reload.begin(state, "Sidearm", SIDEARM, 0, math.huge))).toEqual("bad_clock")
		expect(Reload.pendingCount(state)).toEqual(0)
	end)

	t.it("treats a non-finite or negative duration as instant", function()
		local state = Reload.new()
		Reload.begin(state, "X", { magazine = 5, reloadSeconds = 0 / 0 }, 0, 10)
		expect(#Reload.collect(state, 10)).toEqual(1)
	end)
end)

t.describe("Reload.collect", function()
	t.it("does not complete before the duration elapses", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(#Reload.collect(state, 1.39)).toEqual(0)
		expect(Reload.isReloading(state, "Sidearm", 1.39)).toBeTruthy()
	end)

	t.it("completes at exactly the duration", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(Reload.collect(state, 1.4)).toEqual({ "Sidearm" })
	end)

	t.it("reports a completion once and only once", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(#Reload.collect(state, 5)).toEqual(1)
		expect(#Reload.collect(state, 6)).toEqual(0)
		expect(Reload.pendingCount(state)).toEqual(0)
	end)

	t.it("tracks weapons independently and reports in a stable order", function()
		local state = Reload.new()
		Reload.begin(state, "Slug", SLUG, 0, 0)
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		-- Sidearm is 1.4s, Slug 2.8s.
		expect(Reload.collect(state, 1.5)).toEqual({ "Sidearm" })
		expect(Reload.collect(state, 2.9)).toEqual({ "Slug" })
	end)

	t.it("completes two due reloads in a deterministic order", function()
		local state = Reload.new()
		Reload.begin(state, "Slug", SLUG, 0, 0)
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(Reload.collect(state, 10)).toEqual({ "Sidearm", "Slug" })
	end)

	t.it("completes nothing on a non-finite clock", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(#Reload.collect(state, 0 / 0)).toEqual(0)
		-- And the reload survives it rather than being lost.
		expect(#Reload.collect(state, 1.4)).toEqual(1)
	end)

	t.it("still reports reloading on a non-finite clock rather than ending it", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(Reload.isReloading(state, "Sidearm", 0 / 0)).toBeTruthy()
	end)
end)

t.describe("Reload.cancel", function()
	t.it("abandons an in-flight reload", function()
		-- Switching away must not let the reload finish in your pocket, or
		-- swapping becomes the fastest way to reload everything at once.
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		Reload.cancel(state, "Sidearm")
		expect(Reload.isReloading(state, "Sidearm", 0.1)).toBeFalsy()
		expect(#Reload.collect(state, 10)).toEqual(0)
	end)

	t.it("cancels only the named weapon", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		Reload.begin(state, "Slug", SLUG, 0, 0)
		Reload.cancel(state, "Sidearm")
		expect(Reload.collect(state, 10)).toEqual({ "Slug" })
	end)

	t.it("cancelling an idle weapon is harmless", function()
		local state = Reload.new()
		Reload.cancel(state, "Sidearm")
		expect(Reload.pendingCount(state)).toEqual(0)
	end)

	t.it("cancelAll clears everything, as a death or run end should", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		Reload.begin(state, "Slug", SLUG, 0, 0)
		Reload.cancelAll(state)
		expect(Reload.pendingCount(state)).toEqual(0)
	end)
end)

t.describe("Reload.progress", function()
	t.it("runs 0 to 1 across the reload", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		expect(Reload.progress(state, "Sidearm", SIDEARM, 0)).approx(0, 1e-9)
		expect(Reload.progress(state, "Sidearm", SIDEARM, 0.7)).approx(0.5, 1e-9)
		expect(Reload.progress(state, "Sidearm", SIDEARM, 1.4)).approx(1, 1e-9)
	end)

	t.it("is 1 when idle, so a HUD reads full rather than empty", function()
		local state = Reload.new()
		expect(Reload.progress(state, "Sidearm", SIDEARM, 5)).approx(1, 1e-9)
	end)

	t.it("never leaves the 0..1 range", function()
		local state = Reload.new()
		Reload.begin(state, "Sidearm", SIDEARM, 0, 0)
		for at = -5, 10, 0.25 do
			local p = Reload.progress(state, "Sidearm", SIDEARM, at)
			expect(p >= 0 and p <= 1).toBeTruthy()
		end
	end)
end)

t.describe("Reload against the real weapon table", function()
	t.it("every weapon has a usable magazine and reload time", function()
		for id, weapon in Weapons :: any do
			-- The Arc is a beam and has no discrete magazine; everything else
			-- must be reloadable or it is dry for the rest of the run.
			if weapon.magazine ~= nil then
				expect(type(weapon.magazine) == "number" and weapon.magazine > 0).toBeTruthy()
				expect(
					type(weapon.reloadSeconds) == "number" and weapon.reloadSeconds > 0,
					id
				).toBeTruthy()
			end
		end
	end)

	t.it("a full cycle empties and refills each magazine", function()
		for id, weapon in Weapons :: any do
			if weapon.magazine ~= nil then
				local state = Reload.new()
				local ok = Reload.begin(state, id, weapon, 0, 0)
				expect(ok).toBeTruthy()
				expect(#Reload.collect(state, weapon.reloadSeconds)).toEqual(1)
			end
		end
	end)
end)
