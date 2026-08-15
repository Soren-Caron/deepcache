--!strict
--[[
	Damage resolution: distance falloff, headshot bonus, armor.

	Server-only. The client never computes damage — it predicts *presentation*
	(tracer, hitmarker) and takes the number from the authoritative hit event.
]]

local DamageModel = {}

export type DamageInput = {
	baseDamage: number,
	distance: number,
	falloffStart: number,
	falloffEnd: number,
	minMultiplier: number,
	--- 0..1. Capped at MAX_ARMOR so nothing is ever fully immune.
	armor: number,
	headshot: boolean,
	headshotMultiplier: number?,
}

--- Total immunity turns an encounter into an unwinnable softlock, so armor
--- saturates below 1 no matter what a config or a buff stack says.
DamageModel.MAX_ARMOR = 0.95

--- Linear falloff between falloffStart and falloffEnd, floored at
--- minMultiplier. Returns 1.0 at or inside falloffStart.
function DamageModel.falloff(
	distance: number,
	falloffStart: number,
	falloffEnd: number,
	minMultiplier: number
): number
	if distance <= falloffStart then
		return 1
	end
	if distance >= falloffEnd then
		return minMultiplier
	end
	-- Degenerate config (start == end) is a step, not a divide by zero.
	local span = falloffEnd - falloffStart
	if span <= 1e-9 then
		return minMultiplier
	end
	local alpha = (distance - falloffStart) / span
	return 1 + (minMultiplier - 1) * alpha
end

--- Final damage. Never negative, never NaN.
function DamageModel.compute(input: DamageInput): number
	if input.baseDamage <= 0 then
		return 0
	end

	local multiplier = DamageModel.falloff(
		math.max(input.distance, 0),
		input.falloffStart,
		input.falloffEnd,
		input.minMultiplier
	)

	local damage = input.baseDamage * multiplier

	if input.headshot then
		damage *= input.headshotMultiplier or 1
	end

	local armor = math.clamp(input.armor, 0, DamageModel.MAX_ARMOR)
	damage *= 1 - armor

	return math.max(damage, 0)
end

return DamageModel
