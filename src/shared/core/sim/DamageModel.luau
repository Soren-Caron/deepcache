--!strict
--[[ M1-6. Damage, distance falloff, armor. ]]

local DamageModel = {}

export type DamageInput = {
	baseDamage: number,
	distance: number,
	falloffStart: number,
	falloffEnd: number,
	minMultiplier: number,
	armor: number,
	headshot: boolean,
}

--- Linear falloff between falloffStart and falloffEnd, floored at
--- minMultiplier. Returns 1.0 inside falloffStart.
function DamageModel.falloff(distance: number, falloffStart: number, falloffEnd: number, minMultiplier: number): number
	error("unimplemented: DamageModel.falloff (M1-6)")
end

--- Final damage after falloff, headshot bonus, and armor. Never negative.
function DamageModel.compute(input: DamageInput): number
	error("unimplemented: DamageModel.compute (M1-6)")
end

return DamageModel
