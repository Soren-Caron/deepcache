--!strict
--[[ Damage direction indicator.

	The case that matters most is the sign. An indicator that points the wrong
	way round is worse than none at all, because the player learns to trust it
	and then turns into the shot.
]]

local t = require("./framework")
local expect = t.expect

local DamageArc = require("../src/shared/core/look/DamageArc")

--- Roblox cameras look down -Z at identity, so that is the facing used
--- throughout rather than an arbitrary one.
local LOOK_X, LOOK_Z = 0, -1

t.describe("look/DamageArc bearing", function()
	t.it("points straight ahead at zero", function()
		expect(DamageArc.bearing(LOOK_X, LOOK_Z, 0, -10)).approx(0, 1e-9)
	end)

	t.it("points behind at pi", function()
		expect(math.abs(DamageArc.bearing(LOOK_X, LOOK_Z, 0, 10))).approx(math.pi, 1e-9)
	end)

	t.it("puts an attacker on the player's right at +pi/2", function()
		-- Facing -Z, the player's right hand points toward +X.
		expect(DamageArc.bearing(LOOK_X, LOOK_Z, 10, 0)).approx(math.pi / 2, 1e-9)
	end)

	t.it("puts an attacker on the player's left at -pi/2", function()
		expect(DamageArc.bearing(LOOK_X, LOOK_Z, -10, 0)).approx(-math.pi / 2, 1e-9)
	end)

	t.it("is unaffected by distance", function()
		local near = DamageArc.bearing(LOOK_X, LOOK_Z, 3, -3)
		local far = DamageArc.bearing(LOOK_X, LOOK_Z, 300, -300)
		expect(near).approx(far, 1e-9)
	end)

	t.it("rotates with the camera", function()
		-- Turning to face the attacker must bring the bearing to zero. This is
		-- the property the HUD actually depends on.
		local attackerX, attackerZ = 10, 0
		expect(DamageArc.bearing(attackerX, attackerZ, attackerX, attackerZ)).approx(0, 1e-9)
	end)

	t.it("stays inside -pi..pi for a full sweep", function()
		for degrees = 0, 359 do
			local radians = math.rad(degrees)
			local bearing = DamageArc.bearing(LOOK_X, LOOK_Z, math.cos(radians), math.sin(radians))
			expect(bearing >= -math.pi and bearing <= math.pi).toBeTruthy()
		end
	end)

	t.it("returns zero rather than erroring on degenerate input", function()
		expect(DamageArc.bearing(0, 0, 1, 1)).toEqual(0)
		expect(DamageArc.bearing(LOOK_X, LOOK_Z, 0, 0)).toEqual(0)
	end)
end)

t.describe("look/DamageArc opacity", function()
	t.it("is full at the moment of the hit", function()
		expect(DamageArc.opacity(0, 1.2)).approx(1, 1e-9)
	end)

	t.it("is zero once expired", function()
		expect(DamageArc.opacity(1.2, 1.2)).toEqual(0)
		expect(DamageArc.opacity(99, 1.2)).toEqual(0)
	end)

	t.it("decays faster than linear", function()
		-- Halfway through its life a linear fade sits at 0.5; this must be
		-- below that, or several hits in a row smear together.
		expect(DamageArc.opacity(0.6, 1.2) < 0.5).toBeTruthy()
	end)

	t.it("never increases", function()
		local previous = math.huge
		for step = 0, 24 do
			local value = DamageArc.opacity(step * 0.05, 1.2)
			expect(value <= previous).toBeTruthy()
			previous = value
		end
	end)

	t.it("handles hostile input", function()
		expect(DamageArc.opacity(0 / 0, 1.2)).toEqual(0)
		expect(DamageArc.opacity(-1, 1.2)).toEqual(0)
		expect(DamageArc.opacity(0.5, 0)).toEqual(0)
	end)
end)

t.describe("look/DamageArc merging", function()
	t.it("merges two attackers on nearly the same bearing", function()
		expect(DamageArc.shouldMerge(1.0, 1.1, 0.4)).toBeTruthy()
	end)

	t.it("keeps genuinely different directions apart", function()
		expect(DamageArc.shouldMerge(0, math.pi, 0.4)).toBeFalsy()
	end)

	t.it("takes the short way round the circle", function()
		-- Just either side of directly-behind: 0.28 rad apart, not 6.0.
		expect(DamageArc.shouldMerge(-3.0, 3.0, 0.4)).toBeTruthy()
	end)
end)

t.describe("sim/Run redeploy", function()
	local Run = require("../src/shared/core/sim/Run")

	local SCHEDULE = { Perimeter = 180, Processing = 360, Vault = 540 }

	--- Kill everyone and advance one tick.
	---
	--- `Run.kill` marks the player dead but does not end the run: completion is
	--- decided in `Run.step`, which is what emits `runEnded`. Asserting on
	--- `complete` straight after a kill tests a state that never occurs in the
	--- live loop, where the run phase always steps afterwards.
	local function endRun(state: Run.RunState, ids: { number })
		for _, id in ids do
			Run.kill(state, id)
		end
		Run.step(state, 0.05, SCHEDULE)
	end

	t.it("refuses while the run is still going", function()
		local state = Run.new(1, 720, { 10 })
		local ok, reason = Run.canRedeploy(state, 99, 2)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("run_in_progress")
	end)

	t.it("allows once the run is over and the debounce has passed", function()
		local state = Run.new(1, 720, { 10 })
		endRun(state, { 10 })
		expect(state.complete).toBeTruthy()
		expect(Run.canRedeploy(state, 3, 2)).toBeTruthy()
	end)

	t.it("debounces a spamming client", function()
		-- Without this, a held key restarts the run every frame and rebuilds
		-- the loot table each time.
		local state = Run.new(1, 720, { 10 })
		endRun(state, { 10 })
		local ok, reason = Run.canRedeploy(state, 0.1, 2)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("too_soon")
	end)

	t.it("refuses a nonsense clock", function()
		local state = Run.new(1, 720, { 10 })
		endRun(state, { 10 })
		expect(Run.canRedeploy(state, 0 / 0, 2)).toBeFalsy()
		expect(Run.canRedeploy(state, -5, 2)).toBeFalsy()
	end)

	t.it("keeps a dead player dead while a teammate is still alive", function()
		-- The rule that gives the run its stake: one death in a squad is not a
		-- reason to hand everyone a fresh start.
		local state = Run.new(1, 720, { 10, 11 })
		Run.kill(state, 10)
		expect(state.complete).toBeFalsy()
		local ok, reason = Run.canRedeploy(state, 99, 2)
		expect(ok).toBeFalsy()
		expect(reason).toEqual("run_in_progress")
	end)
end)
