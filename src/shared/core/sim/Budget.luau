--!strict
--[[ M2-8. Enemy budget -> spawn plan.

	The director spends `budget` on enemy costs. Scaling formulas are in
	docs/01-GAME-DESIGN.md §Scaling; only directorMul is model-influenced,
	and it is clamped before it reaches here.
]]

local Types = require("../Types")
local Rng = require("../util/Rng")

export type Spawn = { kind: Types.EntityKind, at: Types.Vec3 }
export type Plan = { spawns: { Spawn }, spent: number }

export type PlanParams = {
	budget: number,
	zone: Types.Zone,
	caps: { [string]: number },
	points: { Types.Vec3 },
	rng: Rng.Rng,
}

local Budget = {}

Budget.BASE = 12

--- enemyBudget(t, n) = BASE * zoneMul * timeRamp(t) * headcountMul(n) * directorMul
function Budget.compute(elapsedSeconds: number, headcount: number, zone: Types.Zone, directorMul: number): number
	error("unimplemented: Budget.compute (M2-8)")
end

function Budget.timeRamp(elapsedSeconds: number): number
	error("unimplemented: Budget.timeRamp (M2-8)")
end

function Budget.headcountMul(headcount: number): number
	error("unimplemented: Budget.headcountMul (M2-8)")
end

--- Spend the budget on concrete spawns. Never exceeds `budget`; respects
--- per-type caps and zone availability; deterministic for a given rng state.
function Budget.plan(params: PlanParams): Plan
	error("unimplemented: Budget.plan (M2-8)")
end

return Budget
