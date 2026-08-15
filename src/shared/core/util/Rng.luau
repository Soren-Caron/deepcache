--!strict
--[[
	Deterministic seeded PRNG.

	Roblox's `Random` is a global that does not exist under Lune, so pure-core
	code cannot use it. This is a plain xorshift32 implemented on bit32, which
	is part of the Luau standard library and available in both runtimes.

	Determinism is not a nicety here: level assembly, spawn planning, and every
	randomised test replay the same seed and expect the same result.
]]

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable(
	{} :: {
		state: number,
	},
	Rng
))

--- Create a generator. Seed 0 is remapped, since xorshift is degenerate at 0.
function Rng.new(seed: number): Rng
	local s = bit32.band(math.floor(seed), 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9 -- golden-ratio constant; any nonzero value works
	end
	return setmetatable({ state = s }, Rng)
end

--- Next raw uint32.
function Rng.nextInt(self: Rng): number
	local s = self.state
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	self.state = s
	return s
end

--- Float in [0, 1).
function Rng.nextNumber(self: Rng): number
	return Rng.nextInt(self) / 4294967296
end

--- Integer in [min, max] inclusive. Errors if max < min.
function Rng.nextRange(self: Rng, min: number, max: number): number
	if max < min then
		error(`Rng.nextRange: max ({max}) < min ({min})`, 2)
	end
	local span = max - min + 1
	return min + (Rng.nextInt(self) % span)
end

--- True with the given probability in [0, 1].
function Rng.chance(self: Rng, probability: number): boolean
	return Rng.nextNumber(self) < probability
end

--- Uniformly pick one element. Errors on an empty list.
function Rng.pick<T>(self: Rng, list: { T }): T
	if #list == 0 then
		error("Rng.pick: empty list", 2)
	end
	return list[Rng.nextRange(self, 1, #list)]
end

--- Fisher-Yates, in place. Returns the same table for chaining.
function Rng.shuffle<T>(self: Rng, list: { T }): { T }
	for i = #list, 2, -1 do
		local j = Rng.nextRange(self, 1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

--- Snapshot / restore, so a sequence can be replayed from a midpoint.
function Rng.getState(self: Rng): number
	return self.state
end

function Rng.setState(self: Rng, state: number)
	local s = bit32.band(math.floor(state), 0xFFFFFFFF)
	self.state = if s == 0 then 0x9E3779B9 else s
end

return Rng
