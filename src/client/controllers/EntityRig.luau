--!strict
--[[ Pooled R6-shaped enemy bodies — the same silhouette as the player.

	**Limbs are rigid and swing from fixed joints.** That is how Roblox's own
	R6 character works: an arm is one part pivoting at the shoulder, a leg is
	one part pivoting at the hip, and neither bends in the middle. Matching it
	is what makes an enemy read as the same kind of thing the player is.

	This replaces an IK-solved two-segment rig. That version placed each limb
	part with `CFrame.lookAt` between solved joint positions, so limbs slid and
	stretched to reach wherever the gait had put a foot instead of rotating
	about a joint — reported as "the legs move so weird", and correctly so:
	nothing about it was pivoting.

	Consequences worth being explicit about:
	  - `core/anim/TwoBoneIk` and `core/anim/StepPlanner` no longer drive
	    rendering. Both remain tested and correct; they are simply the wrong
	    tool for an R6 skeleton, which has no knee to solve. See docs/14.
	  - No ground raycasts per leg, so the 24-ray frame budget is unused by
	    animation now.
	  - Six parts per entity instead of ten to fourteen.

	Everything is `Anchored` and `CanQuery = false`. Limbs that answered
	raycasts would be hit by the combat wall-check on their own body.
]]

local RigsConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").config.Rigs)

local EntityRig = {}

--- R6 proportions, in studs, for a 5-stud-tall reference character. Scaled per
--- kind by `height`. These are Roblox's own defaults: torso 2x2x1, limbs 1x2x1,
--- head 1x1x1 at 1.25 scale.
local REF_HEIGHT = 5

export type Spec = {
	height: number,
	scale: number,
	torsoSize: Vector3,
	headSize: Vector3,
	limbSize: Vector3,
	--- Joint pivots in torso-local space.
	shoulderY: number,
	shoulderX: number,
	hipY: number,
	hipX: number,
	neckY: number,
	--- Height of the torso centre above the entity's ground position.
	torsoCentreY: number,
	hunch: number,
	static: boolean,
	--- Radians of walk cycle per stud travelled, derived from this kind's leg
	--- length. A single shared constant makes tall kinds mince and short kinds
	--- skate, because the ground one step covers scales with the leg.
	radiansPerStud: number,
}

export type Rig = {
	kind: string,
	model: Model,
	torso: BasePart,
	head: BasePart,
	arms: { BasePart },
	legs: { BasePart },
	spec: Spec,
	limbsVisible: boolean,
}

local pools: { [string]: { Rig } } = {}
local specs: { [string]: Spec } = {}

--------------------------------------------------------------------------------

local function buildSpec(kind: string): Spec
	local entry = (RigsConfig.kinds :: any)[kind] or (RigsConfig.kinds :: any).Skitter
	local scale = entry.height / REF_HEIGHT
	local build = entry.build

	-- Width scales with `build` but height does not: a Hauler is broad, not
	-- stretched, and scaling both would just make a bigger Skitter.
	local torsoSize = Vector3.new(2 * scale * build, 2 * scale, 1 * scale * build)
	local limbSize = Vector3.new(1 * scale * build, 2 * scale, 1 * scale * build)
	local headSize = Vector3.new(1.25 * scale * build, 1.25 * scale, 1.25 * scale * build)

	return {
		height = entry.height,
		scale = scale,
		torsoSize = torsoSize,
		headSize = headSize,
		limbSize = limbSize,
		shoulderY = torsoSize.Y * 0.5 - limbSize.Y * 0.125,
		shoulderX = torsoSize.X * 0.5 + limbSize.X * 0.5,
		hipY = -torsoSize.Y * 0.5,
		hipX = limbSize.X * 0.5,
		neckY = torsoSize.Y * 0.5 + headSize.Y * 0.5,
		-- Feet at ground level: legs hang a full limb-length below the hip.
		torsoCentreY = limbSize.Y + torsoSize.Y * 0.5,
		hunch = entry.hunch or 0,
		static = entry.static == true,
		radiansPerStud = (math.pi * 2)
			/ math.max(RigsConfig.WALK.strideFactor * limbSize.Y * math.sin(RigsConfig.WALK.legSwing), 0.1),
	}
end

function EntityRig.spec(kind: string): Spec
	local cached = specs[kind]
	if cached == nil then
		cached = buildSpec(kind)
		specs[kind] = cached
	end
	return cached
end

--------------------------------------------------------------------------------

local function makePart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function build(kind: string): Rig
	local spec = EntityRig.spec(kind)
	local model = Instance.new("Model")
	model.Name = `Rig_{kind}`

	local torso = makePart("Torso", model)
	torso.Size = spec.torsoSize
	model.PrimaryPart = torso

	local head = makePart("Head", model)
	head.Size = spec.headSize

	local arms: { BasePart } = {}
	local legs: { BasePart } = {}
	for index = 1, 2 do
		local arm = makePart(if index == 1 then "LeftArm" else "RightArm", model)
		arm.Size = spec.limbSize
		arms[index] = arm

		local leg = makePart(if index == 1 then "LeftLeg" else "RightLeg", model)
		leg.Size = spec.limbSize
		legs[index] = leg
	end

	return {
		kind = kind,
		model = model,
		torso = torso,
		head = head,
		arms = arms,
		legs = legs,
		spec = spec,
		limbsVisible = true,
	}
end

function EntityRig.acquire(kind: string, parent: Instance): Rig
	local pool = pools[kind]
	if pool ~= nil and #pool > 0 then
		local recycled = table.remove(pool) :: Rig
		recycled.model.Parent = parent
		return recycled
	end
	local rig = build(kind)
	rig.model.Parent = parent
	return rig
end

function EntityRig.release(rig: Rig)
	rig.model.Parent = nil
	local pool = pools[rig.kind]
	if pool == nil then
		pool = {}
		pools[rig.kind] = pool
	end
	table.insert(pool, rig)
end

function EntityRig.setLook(rig: Rig, colour: Color3, material: Enum.Material, transparency: number)
	rig.torso.Color = colour
	rig.torso.Material = material
	rig.torso.Transparency = transparency

	-- The head is brighter than the body so it catches the eye, which is what
	-- makes "it is looking at me" land at a distance.
	rig.head.Color = colour:Lerp(Color3.new(1, 1, 1), 0.3)
	rig.head.Material = material
	rig.head.Transparency = transparency

	local limbColour = colour:Lerp(Color3.new(0, 0, 0), 0.28)
	for _, set in { rig.arms, rig.legs } do
		for _, part in set do
			part.Color = limbColour
			part.Material = material
			part.Transparency = transparency
		end
	end
end

function EntityRig.setLimbsVisible(rig: Rig, visible: boolean)
	if rig.limbsVisible == visible then
		return
	end
	rig.limbsVisible = visible
	local modifier = if visible then 0 else 1
	for _, set in { rig.arms, rig.legs } do
		for _, part in set do
			part.LocalTransparencyModifier = modifier
		end
	end
end

--- Place a limb hanging from `pivot`, swung `angle` radians about the joint's
--- X axis. This is the whole difference from the previous rig: the part
--- rotates *about the joint* and its centre follows, rather than being
--- stretched between two solved endpoints.
local function placeLimb(part: BasePart, pivotCf: CFrame, angle: number, length: number)
	local swung = pivotCf * CFrame.Angles(angle, 0, 0)
	part.CFrame = swung * CFrame.new(0, -length * 0.5, 0)
end

--- Position the whole rig. `position` is the entity's ground point.
---
--- `phase` drives the walk cycle; `stride` is 0 when standing still and 1 at
--- full speed, so a stationary entity holds a neutral pose instead of marching
--- on the spot.
function EntityRig.pose(
	rig: Rig,
	position: Vector3,
	yaw: number,
	scale: number,
	phase: number,
	stride: number,
	lookAt: Vector3?
)
	local spec = rig.spec
	local s = scale

	rig.torso.Size = spec.torsoSize * s
	rig.head.Size = spec.headSize * s
	for _, set in { rig.arms, rig.legs } do
		for _, part in set do
			part.Size = spec.limbSize * s
		end
	end

	local torsoCf = CFrame.new(position + Vector3.new(0, spec.torsoCentreY * s, 0))
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(spec.hunch, 0, 0)
	rig.torso.CFrame = torsoCf

	local headCf = torsoCf * CFrame.new(0, spec.neckY * s, 0)
	if lookAt ~= nil then
		-- Yaw only. A head that pitches at its target looks broken the moment
		-- the target is directly below it.
		local flat = Vector3.new(lookAt.X, headCf.Position.Y, lookAt.Z)
		if (flat - headCf.Position).Magnitude > 1e-3 then
			rig.head.CFrame = CFrame.lookAt(headCf.Position, flat)
		else
			rig.head.CFrame = headCf
		end
	else
		rig.head.CFrame = headCf
	end

	-- Classic contralateral gait: left arm forward with right leg. A static
	-- kind holds its arms at rest and never swings.
	local swing = if spec.static then 0 else math.sin(phase) * stride
	local legSwing = swing * RigsConfig.WALK.legSwing
	local armSwing = swing * RigsConfig.WALK.armSwing
	local length = spec.limbSize.Y * s

	placeLimb(rig.legs[1], torsoCf * CFrame.new(-spec.hipX * s, spec.hipY * s, 0), legSwing, length)
	placeLimb(rig.legs[2], torsoCf * CFrame.new(spec.hipX * s, spec.hipY * s, 0), -legSwing, length)
	placeLimb(rig.arms[1], torsoCf * CFrame.new(-spec.shoulderX * s, spec.shoulderY * s, 0), -armSwing, length)
	placeLimb(rig.arms[2], torsoCf * CFrame.new(spec.shoulderX * s, spec.shoulderY * s, 0), armSwing, length)
end

function EntityRig.pooledCount(): number
	local total = 0
	for _, pool in pools do
		total += #pool
	end
	return total
end

return EntityRig
