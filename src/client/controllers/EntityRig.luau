--!strict
--[[ Pooled multi-part enemy bodies, driven by the gait and IK solutions.

	`core/anim/StepPlanner` and `core/anim/TwoBoneIk` have produced foot and
	knee positions every frame since M7-1, and until now nothing consumed them:
	every entity rendered as one box, so the animation work was real, budgeted,
	profiled — and invisible. This is the geometry it moves.

	Rigs are pooled per kind rather than globally. A Reclaimer has six legs and
	a Lancer two, so a shared pool would mean rebuilding limbs on almost every
	acquire; keyed by kind, a recycled rig already has the right skeleton and
	only needs recolouring.

	Everything is `Anchored` and `CanQuery = false`. Legs that participated in
	raycasts would be hit by the gait's own ground probes, and each foot would
	resolve to the top of the leg above it.
]]

local RigsConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").config.Rigs)

local EntityRig = {}

export type Limb = { upper: BasePart, lower: BasePart }

export type Rig = {
	kind: string,
	model: Model,
	body: BasePart,
	limbs: { Limb },
	--- Cached so the driver does not re-read config every frame.
	spec: any,
	legsVisible: boolean,
}

local pools: { [string]: { Rig } } = {}

local function v3(t: any): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

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

--- Build a rig for `kind`. Falls back to the Skitter plan for an unknown kind
--- rather than erroring: a roster addition should render as *something*.
local function build(kind: string): Rig
	local spec = (RigsConfig :: any)[kind] or (RigsConfig :: any).Skitter

	local model = Instance.new("Model")
	model.Name = `Rig_{kind}`

	local body = makePart("Body", model)
	body.Size = v3(spec.bodySize)
	model.PrimaryPart = body

	local limbs: { Limb } = {}
	for index in spec.legs do
		local upper = makePart(`Leg{index}Upper`, model)
		upper.Size = Vector3.new(spec.legThickness, spec.legThickness, spec.upperLength)
		local lower = makePart(`Leg{index}Lower`, model)
		lower.Size = Vector3.new(spec.legThickness * 0.82, spec.legThickness * 0.82, spec.lowerLength)
		table.insert(limbs, { upper = upper, lower = lower })
	end

	return { kind = kind, model = model, body = body, limbs = limbs, spec = spec, legsVisible = true }
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
	-- A freshly built rig has never been placed, so its limbs sit at the world
	-- origin until the first frame that solves them. Collapse them onto the
	-- body up front so there is no frame where that is visible.
	for _, limb in rig.limbs do
		limb.upper.CFrame = rig.body.CFrame
		limb.lower.CFrame = rig.body.CFrame
	end
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
	rig.body.Color = colour
	rig.body.Material = material
	rig.body.Transparency = transparency
	-- Limbs sit a shade darker so the silhouette reads as a body with legs
	-- rather than one solid mass of colour.
	local limbColour = colour:Lerp(Color3.new(0, 0, 0), 0.35)
	for _, limb in rig.limbs do
		limb.upper.Color = limbColour
		limb.lower.Color = limbColour
		limb.upper.Material = material
		limb.lower.Material = material
		limb.upper.Transparency = transparency
		limb.lower.Transparency = transparency
	end
end

--- Hide limbs without destroying them. At `clip` and beyond a leg is a couple
--- of pixels and solving it is pure cost, but rebuilding the rig when the
--- entity comes back would churn Instances every time a player turns around.
function EntityRig.setLegsVisible(rig: Rig, visible: boolean)
	if rig.legsVisible == visible then
		return
	end
	rig.legsVisible = visible
	for _, limb in rig.limbs do
		limb.upper.LocalTransparencyModifier = if visible then 0 else 1
		limb.lower.LocalTransparencyModifier = if visible then 0 else 1
		if not visible then
			-- Park on the body rather than leaving them wherever they last
			-- were. A hidden limb is never placed, so a rig that goes out of
			-- view and comes back would otherwise be shown for one frame with
			-- its legs still at their old position -- and a rig that was built
			-- but never placed at all has them at the world origin, stretching
			-- a limb across the map the instant it becomes visible.
			limb.upper.CFrame = rig.body.CFrame
			limb.lower.CFrame = rig.body.CFrame
		end
	end
end

--- Place one limb so it spans `from` -> `joint` -> `to`.
local function placeLimb(limb: Limb, from: Vector3, joint: Vector3, to: Vector3)
	local upperVec = joint - from
	local upperLen = upperVec.Magnitude
	if upperLen > 1e-3 then
		limb.upper.Size = Vector3.new(limb.upper.Size.X, limb.upper.Size.Y, upperLen)
		limb.upper.CFrame = CFrame.lookAt(from, joint) * CFrame.new(0, 0, -upperLen / 2)
	end

	local lowerVec = to - joint
	local lowerLen = lowerVec.Magnitude
	if lowerLen > 1e-3 then
		limb.lower.Size = Vector3.new(limb.lower.Size.X, limb.lower.Size.Y, lowerLen)
		limb.lower.CFrame = CFrame.lookAt(joint, to) * CFrame.new(0, 0, -lowerLen / 2)
	end
end

EntityRig.placeLimb = placeLimb

--- Body transform. Legs are placed separately by the caller, which owns the
--- gait state and decides whether the IK ran this frame.
function EntityRig.setBody(rig: Rig, position: Vector3, yaw: number, scale: number)
	local spec = rig.spec
	rig.body.Size = v3(spec.bodySize) * scale
	rig.body.CFrame = CFrame.new(position + Vector3.new(0, spec.bodyOffsetY * scale, 0))
		* CFrame.Angles(0, yaw, 0)
end

function EntityRig.pooledCount(): number
	local total = 0
	for _, pool in pools do
		total += #pool
	end
	return total
end

return EntityRig
