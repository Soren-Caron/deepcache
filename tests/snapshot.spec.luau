--!strict

local t = require("./framework")
local expect = t.expect

local Snapshot = require("../src/shared/core/net/Snapshot")
local Quantize = require("../src/shared/core/net/Quantize")
local Types = require("../src/shared/core/Types")
local Rng = require("../src/shared/core/util/Rng")

local ORIGIN = Types.vec3(0, 0, 0)
local OFFSET_ORIGIN = Types.vec3(1000, -50, -2000)

local STATES: { Types.EntityStateName } = { "idle", "move", "attack", "stagger", "death", "spawn" }

local function view(id: number, x: number, y: number, z: number, yaw: number?, state: Types.EntityStateName?, hp: number?): Types.EntityView
	return {
		id = id,
		pos = Types.vec3(x, y, z),
		yaw = yaw or 0,
		state = state or "idle",
		hpPct = hp or 1,
	}
end

local function randomViews(rng: Rng.Rng, count: number, spread: number): { Types.EntityView }
	local out: { Types.EntityView } = {}
	for i = 1, count do
		out[i] = view(
			i,
			(Rng.nextNumber(rng) * 2 - 1) * spread,
			(Rng.nextNumber(rng) * 2 - 1) * spread,
			(Rng.nextNumber(rng) * 2 - 1) * spread,
			Rng.nextNumber(rng) * math.pi * 2,
			STATES[Rng.nextRange(rng, 1, #STATES)],
			Rng.nextNumber(rng)
		)
	end
	return out
end

--- Assert two views match within the quantization error bounds.
local function expectViewClose(actual: Types.EntityView, expected: Types.EntityView)
	expect(actual.id).toEqual(expected.id)
	expect(actual.state).toEqual(expected.state)
	expect(actual.pos.x).approx(expected.pos.x, Quantize.POSITION_MAX_ERROR + 1e-9)
	expect(actual.pos.y).approx(expected.pos.y, Quantize.POSITION_MAX_ERROR + 1e-9)
	expect(actual.pos.z).approx(expected.pos.z, Quantize.POSITION_MAX_ERROR + 1e-9)
	expect(math.abs(Quantize.yawDelta(expected.yaw, actual.yaw)) <= Quantize.YAW_MAX_ERROR + 1e-9).toBeTruthy()
	expect(actual.hpPct).approx(expected.hpPct, Quantize.UNIT_MAX_ERROR + 1e-9)
end

--------------------------------------------------------------------------------

t.describe("net/Snapshot format", function()
	t.it("matches the documented byte budget", function()
		expect(Snapshot.MAX_BYTES).toEqual(900)
		expect(Snapshot.HEADER_BYTES).toEqual(5)
		expect(Snapshot.ENTITY_BYTES).toEqual(11)
		expect(Snapshot.capacity()).toEqual(81)
		expect(Snapshot.byteSize(81)).toEqual(896)
		expect(Snapshot.byteSize(81) <= Snapshot.MAX_BYTES).toBeTruthy()
	end)

	t.it("encodes exactly header + 11 bytes per entity", function()
		local rng = Rng.new(1)
		for _, n in { 0, 1, 5, 40, 81 } do
			local b = Snapshot.encode(7, randomViews(rng, n, 100), ORIGIN)
			expect(buffer.len(b)).toEqual(5 + n * 11)
		end
	end)

	t.it("fits 81 entities and refuses 82", function()
		local rng = Rng.new(2)
		expect(function()
			Snapshot.encode(1, randomViews(rng, 81, 100), ORIGIN)
		end).never().toThrow()

		expect(function()
			Snapshot.encode(1, randomViews(rng, 82, 100), ORIGIN)
		end).toThrow("exceeds")
	end)

	t.it("every 900-byte-budget packet stays under the drop threshold", function()
		-- The failure this guards is silent: an oversized UnreliableRemoteEvent
		-- payload is dropped with no error anywhere.
		local rng = Rng.new(3)
		local b = Snapshot.encode(1, randomViews(rng, 81, 1600), ORIGIN)
		expect(buffer.len(b) <= 1000).toBeTruthy()
	end)
end)

t.describe("net/Snapshot encode/decode", function()
	t.it("roundtrips an empty snapshot", function()
		local decoded = Snapshot.decode(Snapshot.encode(0, {}, ORIGIN), ORIGIN)
		expect(decoded.tick).toEqual(0)
		expect(#decoded.entities).toEqual(0)
		expect(decoded.isKeyframe).toBeTruthy()
	end)

	t.it("roundtrips 40 entities within error bounds", function()
		local rng = Rng.new(11)
		local entities = randomViews(rng, 40, 800)
		local decoded = Snapshot.decode(Snapshot.encode(123, entities, ORIGIN), ORIGIN)

		expect(decoded.tick).toEqual(123)
		expect(#decoded.entities).toEqual(40)
		for i, expected in entities do
			expectViewClose(decoded.entities[i], expected)
		end
	end)

	t.it("preserves entity order", function()
		local entities = { view(9, 1, 2, 3), view(4, 4, 5, 6), view(77, 7, 8, 9) }
		local decoded = Snapshot.decode(Snapshot.encode(1, entities, ORIGIN), ORIGIN)
		expect({ decoded.entities[1].id, decoded.entities[2].id, decoded.entities[3].id }).toEqual({ 9, 4, 77 })
	end)

	t.it("roundtrips every state code", function()
		local entities: { Types.EntityView } = {}
		for i, state in STATES do
			entities[i] = view(i, 0, 0, 0, 0, state)
		end
		local decoded = Snapshot.decode(Snapshot.encode(1, entities, ORIGIN), ORIGIN)
		for i, state in STATES do
			expect(decoded.entities[i].state).toEqual(state)
		end
	end)

	t.it("encodes positions relative to a non-zero origin", function()
		-- Absolute coordinates far from origin would blow the int16 range;
		-- relative encoding is what keeps a large level representable.
		local entities = { view(1, 1000.5, -50.25, -2000.75) }
		local decoded = Snapshot.decode(Snapshot.encode(1, entities, OFFSET_ORIGIN), OFFSET_ORIGIN)
		expectViewClose(decoded.entities[1], entities[1])
	end)

	t.it("preserves large tick values", function()
		local decoded = Snapshot.decode(Snapshot.encode(4294967295, {}, ORIGIN), ORIGIN)
		expect(decoded.tick).toEqual(4294967295)
	end)

	t.it("rejects an entity id that does not fit uint16", function()
		expect(function()
			Snapshot.encode(1, { view(70000, 0, 0, 0) }, ORIGIN)
		end).toThrow("uint16")
	end)

	t.it("rejects a truncated packet instead of reading garbage", function()
		local full = Snapshot.encode(1, { view(1, 1, 1, 1), view(2, 2, 2, 2) }, ORIGIN)
		local truncated = buffer.create(buffer.len(full) - 4)
		buffer.copy(truncated, 0, full, 0, buffer.len(full) - 4)
		expect(function()
			Snapshot.decode(truncated, ORIGIN)
		end).toThrow("truncated")
	end)

	t.it("rejects a buffer too short to hold a header", function()
		expect(function()
			Snapshot.decode(buffer.create(3), ORIGIN)
		end).toThrow("too short")
	end)
end)

t.describe("net/Snapshot delta compression", function()
	t.it("sends nothing when nothing changed", function()
		local rng = Rng.new(21)
		local entities = randomViews(rng, 30, 500)
		local delta = Snapshot.encodeDelta(2, entities, entities, ORIGIN)
		expect(buffer.len(delta)).toEqual(Snapshot.HEADER_BYTES)
		expect(Snapshot.decode(delta, ORIGIN).isKeyframe).toBeFalsy()
	end)

	t.it("ignores sub-grid movement", function()
		-- Jitter below the 0.05 grid must not cost a slot, or the delta buys
		-- nothing over a full snapshot.
		local base = { view(1, 10, 20, 30) }
		local nudged = { view(1, 10.001, 20.002, 30.001) }
		expect(buffer.len(Snapshot.encodeDelta(2, nudged, base, ORIGIN))).toEqual(Snapshot.HEADER_BYTES)
	end)

	t.it("carries an entity that moved more than one grid step", function()
		local base = { view(1, 10, 20, 30), view(2, 0, 0, 0) }
		local moved = { view(1, 10.5, 20, 30), view(2, 0, 0, 0) }
		local delta = Snapshot.encodeDelta(2, moved, base, ORIGIN)
		local decoded = Snapshot.decode(delta, ORIGIN)
		expect(#decoded.entities).toEqual(1)
		expect(decoded.entities[1].id).toEqual(1)
	end)

	t.it("carries a state or hp change with no movement", function()
		local base = { view(1, 5, 5, 5, 0, "move", 1.0) }
		expect(#Snapshot.decode(Snapshot.encodeDelta(2, { view(1, 5, 5, 5, 0, "death", 1.0) }, base, ORIGIN), ORIGIN).entities).toEqual(1)
		expect(#Snapshot.decode(Snapshot.encodeDelta(2, { view(1, 5, 5, 5, 0, "move", 0.5) }, base, ORIGIN), ORIGIN).entities).toEqual(1)
		expect(#Snapshot.decode(Snapshot.encodeDelta(2, { view(1, 5, 5, 5, 1.0, "move", 1.0) }, base, ORIGIN), ORIGIN).entities).toEqual(1)
	end)

	t.it("treats a newly visible entity as changed", function()
		local base = { view(1, 0, 0, 0) }
		local grown = { view(1, 0, 0, 0), view(2, 9, 9, 9) }
		local decoded = Snapshot.decode(Snapshot.encodeDelta(3, grown, base, ORIGIN), ORIGIN)
		expect(#decoded.entities).toEqual(1)
		expect(decoded.entities[1].id).toEqual(2)
	end)

	t.it("applyDelta keeps unmentioned entities and appends new ones", function()
		local base = { view(1, 0, 0, 0), view(2, 5, 5, 5) }
		local next_ = { view(1, 0, 0, 0), view(2, 6, 5, 5), view(3, 1, 1, 1) }
		local merged = Snapshot.applyDelta(base, Snapshot.encodeDelta(4, next_, base, ORIGIN), ORIGIN)

		expect(#merged.entities).toEqual(3)
		expect({ merged.entities[1].id, merged.entities[2].id, merged.entities[3].id }).toEqual({ 1, 2, 3 })
		expect(merged.entities[2].pos.x).approx(6, Quantize.POSITION_MAX_ERROR + 1e-9)
		expect(merged.entities[1].pos.x).approx(0, 1e-9)
	end)

	t.it("applyDelta never removes an entity", function()
		-- Omission from an unreliable packet is indistinguishable from packet
		-- loss, so despawns travel on the reliable channel instead.
		local base = { view(1, 0, 0, 0), view(2, 5, 5, 5) }
		local merged = Snapshot.applyDelta(base, Snapshot.encodeDelta(5, { view(1, 0, 0, 0) }, base, ORIGIN), ORIGIN)
		expect(#merged.entities).toEqual(2)
	end)

	t.it("reconstructs a 200-tick sequence identically to full snapshots", function()
		-- The end-to-end property that matters: replaying keyframes + deltas
		-- must land on exactly what a full snapshot would have carried.
		local rng = Rng.new(99)
		local count = 25
		local entities = randomViews(rng, count, 300)

		local baseline: { Types.EntityView } = {}
		local reconstructed: { Types.EntityView } = {}

		for tick = 0, 199 do
			-- Move a random subset; leave the rest still.
			for _ = 1, 6 do
				local e = entities[Rng.nextRange(rng, 1, count)]
				e.pos = Types.vec3(
					e.pos.x + (Rng.nextNumber(rng) * 2 - 1) * 2,
					e.pos.y,
					e.pos.z + (Rng.nextNumber(rng) * 2 - 1) * 2
				)
				e.yaw = e.yaw + (Rng.nextNumber(rng) * 2 - 1) * 0.3
				e.hpPct = math.max(0, e.hpPct - Rng.nextNumber(rng) * 0.01)
			end

			if Snapshot.isKeyframeTick(tick) then
				local decoded = Snapshot.decode(Snapshot.encode(tick, entities, ORIGIN), ORIGIN)
				reconstructed = decoded.entities
				baseline = decoded.entities
			else
				local merged = Snapshot.applyDelta(baseline, Snapshot.encodeDelta(tick, entities, baseline, ORIGIN), ORIGIN)
				reconstructed = merged.entities
				baseline = merged.entities
			end

			local truth = Snapshot.decode(Snapshot.encode(tick, entities, ORIGIN), ORIGIN)
			expect(#reconstructed).toEqual(#truth.entities)
			for i, expected in truth.entities do
				local got = reconstructed[i]
				expect(got.id).toEqual(expected.id)
				expect(got.pos.x).approx(expected.pos.x, 1e-9)
				expect(got.pos.y).approx(expected.pos.y, 1e-9)
				expect(got.pos.z).approx(expected.pos.z, 1e-9)
				expect(got.yaw).approx(expected.yaw, 1e-9)
				expect(got.hpPct).approx(expected.hpPct, 1e-9)
				expect(got.state).toEqual(expected.state)
			end
		end
	end)

	t.it("delta is materially smaller than a keyframe in steady state", function()
		-- If this stops holding, delta compression is not earning its complexity.
		local rng = Rng.new(1234)
		local count = 40
		local entities = randomViews(rng, count, 400)
		local baseline = Snapshot.decode(Snapshot.encode(0, entities, ORIGIN), ORIGIN).entities

		-- Only a quarter of the set moves on a given tick, which is typical:
		-- most entities are idle, dead, or out of aggro range.
		for _ = 1, 10 do
			local e = entities[Rng.nextRange(rng, 1, count)]
			e.pos = Types.vec3(e.pos.x + 1, e.pos.y, e.pos.z + 1)
		end

		local deltaBytes = buffer.len(Snapshot.encodeDelta(1, entities, baseline, ORIGIN))
		local keyframeBytes = buffer.len(Snapshot.encode(1, entities, ORIGIN))
		expect(deltaBytes < keyframeBytes / 2).toBeTruthy()
	end)

	t.it("marks keyframes and deltas distinguishably", function()
		expect(Snapshot.decode(Snapshot.encode(1, {}, ORIGIN), ORIGIN).isKeyframe).toBeTruthy()
		expect(Snapshot.decode(Snapshot.encodeDelta(1, {}, {}, ORIGIN), ORIGIN).isKeyframe).toBeFalsy()
		expect(Snapshot.isKeyframeTick(0)).toBeTruthy()
		expect(Snapshot.isKeyframeTick(20)).toBeTruthy()
		expect(Snapshot.isKeyframeTick(19)).toBeFalsy()
	end)
end)
