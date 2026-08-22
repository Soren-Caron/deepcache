--!strict
--[[ M7-3. Animation LOD tiers and the per-frame raycast allocator.

	docs/08 §LOD, exactly:

	    < 40 studs   full      procedural legs, IK, per-leg raycasts, clips
	    40-90        reduced   legs at half rate, no ground raycasts, clips
	    90-150       clip      authored loop only, no IK, no raycasts
	    > 150        culled    outside the interest radius, not replicated

	And a hard budget: **at most 24 leg raycasts per frame across all
	entities**, allocated by distance priority, with entities that miss out
	reusing their previous ground plane.

	Pure, so the allocator can be tested against 40 entities without a running
	game -- which matters because the interesting property is not "does it cast
	rays" but "does it *never* exceed 24 while still preferring the entities
	closest to the camera", and that is a statement about a sort and a counter.

	**Priority is by distance, not by need.** An entity at 5 studs whose ground
	plane is a frame stale is far more visible than one at 38 studs in the same
	state, so the near entity wins even if the far one has waited longer. The
	alternative -- round-robin fairness -- spreads staleness evenly, which
	sounds better and looks worse: it means the entity filling the screen is
	stale one frame in three.
]]

local Lod = {}

export type Tier = "full" | "reduced" | "clip" | "culled"

--- docs/08 §LOD boundaries, in studs.
Lod.FULL_MAX = 40
Lod.REDUCED_MAX = 90
Lod.CLIP_MAX = 150

--- docs/08: "max 24 leg raycasts per frame across all entities".
Lod.RAYCAST_BUDGET = 24

--- Only the `full` tier casts ground rays at all.
function Lod.tierFor(distance: number): Tier
	if distance ~= distance then -- NaN: treat as furthest, never as nearest
		return "culled"
	end
	if distance < Lod.FULL_MAX then
		return "full"
	elseif distance < Lod.REDUCED_MAX then
		return "reduced"
	elseif distance < Lod.CLIP_MAX then
		return "clip"
	end
	return "culled"
end

--- Does this tier step its gait every frame, or every other frame?
--- `reduced` runs at half rate, which is the cheap half of its saving.
function Lod.shouldStepGait(tier: Tier, frame: number): boolean
	if tier == "full" then
		return true
	end
	if tier == "reduced" then
		return frame % 2 == 0
	end
	return false
end

export type Candidate = {
	id: number,
	distance: number,
}

--- Choose which entities get a ground raycast this frame.
---
--- Returns a set keyed by entity id. Everything not in it reuses its previous
--- ground plane, which docs/08 notes is invisible at those distances.
function Lod.allocateRaycasts(candidates: { Candidate }, budget: number?): { [number]: boolean }
	local limit = budget or Lod.RAYCAST_BUDGET
	local granted: { [number]: boolean } = {}
	if limit <= 0 then
		return granted
	end

	-- Only `full` entities are eligible; the other tiers do not cast by
	-- definition, so including them would let a distant entity consume budget
	-- it is documented never to use.
	local eligible: { Candidate } = {}
	for _, candidate in candidates do
		if Lod.tierFor(candidate.distance) == "full" then
			table.insert(eligible, candidate)
		end
	end

	-- Nearest first. Ties broken by id so the allocation is deterministic:
	-- two entities at exactly equal distance must not swap places frame to
	-- frame, or they alternate stale planes forever.
	table.sort(eligible, function(a, b)
		if a.distance == b.distance then
			return a.id < b.id
		end
		return a.distance < b.distance
	end)

	local count = 0
	for _, candidate in eligible do
		if count >= limit then
			break
		end
		granted[candidate.id] = true
		count += 1
	end
	return granted
end

--- How many entities sit in each tier. Used by the frame-budget telemetry so
--- a profile can be read against what was actually being simulated.
function Lod.census(candidates: { Candidate }): { [string]: number }
	local counts = { full = 0, reduced = 0, clip = 0, culled = 0 }
	for _, candidate in candidates do
		local tier = Lod.tierFor(candidate.distance)
		counts[tier] += 1
	end
	return counts
end

return Lod
