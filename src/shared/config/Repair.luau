--!strict
--[[ Field repair. Pure data, per CLAUDE.md -- no functions, no requires.

	A completed repair restores **full health**, whatever the deficit. There is
	no heal-size tunable here any more: the charge is the whole cost.

	That makes `charges` the only thing holding healing in check, so it has to
	stay small. Two full heals across a twelve-minute run means the run can
	survive three near-deaths and no more, and it keeps attrition as the thing
	that ends runs. Raising it to three or four does not make the game a bit
	easier -- it removes the pressure entirely.

	The earlier fixed 45-point heal was dropped because it made a charge worth
	less the healthier you were, so the correct play was to walk around hurt
	waiting for the value to be there.

	`channelSeconds` sits deliberately under the sweep's 3.5s cooldown, so the
	intended sequence -- sweep to make space, then heal in it -- is possible
	exactly once per cooldown rather than freely.
]]

local Repair = {}

--- Charges at the start of a run. They do not refill. The only limit on
--- healing, now that each one is a full heal.
Repair.charges = 2

--- Seconds of standing still. Taking damage cancels it and the charge is gone.
---
--- Was 2.5, which played as sluggish: with an all-or-nothing payout the key
--- did visibly nothing for two and a half seconds. Health now arrives on an
--- accelerating curve from the first frame, and the channel is shorter, so it
--- reads as fast without becoming free.
Repair.channelSeconds = 1.6

return Repair
