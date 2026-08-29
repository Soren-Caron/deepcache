--!strict
--[[ Field repair. Pure data, per CLAUDE.md -- no functions, no requires.

	Sized against the damage the roster actually deals. A Hauler hits for 30
	and a Warden for 22, so a 45-point repair is worth roughly a Hauler swing
	and a half -- enough to survive a mistake, not enough to stand in a fight.

	Two charges, not refilling, is the balance decision. Across a twelve-minute
	run that is 90 points of healing against a 100-point health bar: it roughly
	doubles your survivable damage, which turns a single bad room from fatal
	into expensive, and still leaves attrition as the thing that ends runs.

	`channelSeconds` sits deliberately under the sweep's 3.5s cooldown, so the
	intended sequence -- sweep to make space, then heal in it -- is possible
	exactly once per cooldown rather than freely.
]]

local Repair = {}

--- Charges at the start of a run. They do not refill.
Repair.charges = 2

Repair.healAmount = 45

--- Seconds of standing still. Taking damage cancels it and the charge is gone.
Repair.channelSeconds = 2.5

return Repair
