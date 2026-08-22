--!strict
--[[ M7-5. The post-processing stack's arithmetic: blend between zone presets
	on a transition, then modulate the result by OVERSEER's threat tier.

	Pure, so the whole look can be reasoned about and tested without a
	viewport. The adapter (`client/controllers/LookController`) does nothing
	but push these numbers onto `Lighting` effects.

	**Order matters and is fixed: blend the zones first, then apply threat.**
	The zone preset says where the player *is*; threat tier says how bad it is
	right now. Threatening a half-blended value is correct -- walking from
	Processing into Vault while the director escalates should read as both at
	once. Blending two already-threatened presets would instead interpolate
	the threat response itself, which lags a tier change by the whole 1.5s
	transition and makes the director look slow exactly when it is trying to
	look present.

	docs/08 specifies the threat response as "at threatTier 4-5 the tint pushes
	red, bloom rises, and fog tightens by 20%". Implemented as a *ramp* over
	tiers 3 to 5 rather than a switch that flips at 4: a step change in the
	post stack is a visible pop, and the whole point of driving lighting from
	the director is that escalation reads as escalation. Tier 4 therefore gets
	half the full response, which satisfies the spec's endpoints while keeping
	the transition continuous.
]]

local LightingBlend = {}

export type Preset = {
	tintR: number,
	tintG: number,
	tintB: number,
	saturation: number,
	contrast: number,
	bloom: number,
	fogEnd: number,
}

--- Seconds a zone-to-zone transition takes. docs/08 §Post-processing stack.
LightingBlend.TRANSITION_SECONDS = 1.5

--- Threat modulation is neutral at or below this tier and full at TIER_MAX.
LightingBlend.THREAT_RAMP_START = 3
LightingBlend.THREAT_RAMP_END = 5

--- Full-strength threat response, from docs/08.
LightingBlend.THREAT_TINT_R = 0.18 -- pushed toward red
LightingBlend.THREAT_TINT_G = -0.10
LightingBlend.THREAT_TINT_B = -0.14
LightingBlend.THREAT_BLOOM = 0.7 -- added, not multiplied
LightingBlend.THREAT_FOG_TIGHTEN = 0.20 -- fog end shortens by 20%
LightingBlend.THREAT_CONTRAST = 0.10
LightingBlend.THREAT_SATURATION = 0.12

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

--- 0 at THREAT_RAMP_START and below, 1 at THREAT_RAMP_END and above.
function LightingBlend.threatWeight(threatTier: number): number
	if threatTier ~= threatTier then -- NaN from a malformed director payload
		return 0
	end
	local span = LightingBlend.THREAT_RAMP_END - LightingBlend.THREAT_RAMP_START
	if span <= 0 then
		return 0
	end
	return math.clamp((threatTier - LightingBlend.THREAT_RAMP_START) / span, 0, 1)
end

--- Blend two zone presets. `alpha` 0 gives `from`, 1 gives `to`.
function LightingBlend.lerpPreset(from: Preset, to: Preset, alpha: number): Preset
	local a = math.clamp(alpha, 0, 1)
	return {
		tintR = lerp(from.tintR, to.tintR, a),
		tintG = lerp(from.tintG, to.tintG, a),
		tintB = lerp(from.tintB, to.tintB, a),
		saturation = lerp(from.saturation, to.saturation, a),
		contrast = lerp(from.contrast, to.contrast, a),
		bloom = lerp(from.bloom, to.bloom, a),
		fogEnd = lerp(from.fogEnd, to.fogEnd, a),
	}
end

--- Push a preset toward the threat response. Tier at or below the ramp start
--- returns the preset unchanged.
function LightingBlend.applyThreat(preset: Preset, threatTier: number): Preset
	local weight = LightingBlend.threatWeight(threatTier)
	if weight <= 0 then
		return {
			tintR = preset.tintR,
			tintG = preset.tintG,
			tintB = preset.tintB,
			saturation = preset.saturation,
			contrast = preset.contrast,
			bloom = preset.bloom,
			fogEnd = preset.fogEnd,
		}
	end
	return {
		-- Tint channels are multipliers on the rendered image, so they stay
		-- clamped to [0,1]: a channel above 1 brightens rather than tints and
		-- reads as a blown-out frame, not as menace.
		tintR = math.clamp(preset.tintR + LightingBlend.THREAT_TINT_R * weight, 0, 1),
		tintG = math.clamp(preset.tintG + LightingBlend.THREAT_TINT_G * weight, 0, 1),
		tintB = math.clamp(preset.tintB + LightingBlend.THREAT_TINT_B * weight, 0, 1),
		saturation = preset.saturation + LightingBlend.THREAT_SATURATION * weight,
		contrast = preset.contrast + LightingBlend.THREAT_CONTRAST * weight,
		-- Bloom is additive rather than scaled: a zone with a low bloom floor
		-- would otherwise barely respond to threat at all, and the Perimeter
		-- (bloom 0.6) is exactly where an escalation most needs to be legible.
		bloom = preset.bloom + LightingBlend.THREAT_BLOOM * weight,
		-- Fog *end* is a distance, so tightening means reducing it.
		fogEnd = preset.fogEnd * (1 - LightingBlend.THREAT_FOG_TIGHTEN * weight),
	}
end

--- The full stack: where the player is, how far through a zone transition,
--- and how bad it is. This is the only function the adapter needs.
function LightingBlend.resolve(from: Preset, to: Preset, alpha: number, threatTier: number): Preset
	return LightingBlend.applyThreat(LightingBlend.lerpPreset(from, to, alpha), threatTier)
end

return LightingBlend
