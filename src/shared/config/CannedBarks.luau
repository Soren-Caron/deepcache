--!strict
--[[ Pure data.

	Fallback lines for when a real OVERSEER bark fails Roblox's text filter
	(docs/05 §Content filtering). Players must never see a blank comms feed
	and must never see unfiltered text -- one of these covers every failure.

	docs/05's original target was "~40 per intent." Reduced here to 8: a run
	is at most 36 director ticks total across all eight intents combined, and
	a filter failure is the *exceptional* path, not the common one -- 8
	distinct, in-voice lines per intent already makes a repeat within one
	run's exceptional-path cases unlikely. This is pure data with no code
	depending on the count, so growing the pool later is a content change,
	not a refactor.
]]

return {
	escalate = {
		"Reinforcements en route. Try to keep up.",
		"Escalating. This was always the plan.",
		"More units, less patience.",
		"The floor gets busier from here.",
		"Turning the dial up. You'll feel it.",
		"Additional assets deployed. Standard procedure.",
		"This is where it stops being easy.",
		"Pressure is not a punishment. It's a service.",
	},
	relieve = {
		"A moment's peace. Don't waste it.",
		"Standing down. For now.",
		"You've earned a breath. Take it.",
		"Easing off. Consider it a courtesy.",
		"Quiet for a while. Enjoy the silence.",
		"Relief granted. Terms may change.",
		"The floor is yours. Briefly.",
		"I can be reasonable, occasionally.",
	},
	punish_greed = {
		"Carrying that much was a choice.",
		"Weight has consequences. Yours specifically.",
		"The inventory discrepancy grows heavier.",
		"Greed has a response time. This is it.",
		"You wanted the good stuff. Here's the cost.",
		"Heavier bags, slower feet. Funny how that works.",
		"Every item taken is logged. And answered for.",
		"Full pockets make an easy target.",
	},
	reward_speed = {
		"Efficient. I appreciate that, in my way.",
		"Fast work. Consider the floor grateful.",
		"You move well. It won't go unnoticed.",
		"Speed has its own reward. Take it.",
		"Quick hands, quiet exit. Acceptable.",
		"No wasted motion. Rare, these days.",
		"You're ahead of schedule. Mine, that is.",
		"Efficiency noted. Filed accordingly.",
	},
	split_squad = {
		"Together is a strategy. So is apart.",
		"Divided attention. Divided coverage.",
		"Spread thin reads clearly from here.",
		"Separation has a cost. You'll find it.",
		"The squad scatters. The floor does not forget where.",
		"Alone is a variable I can work with.",
		"Distance between you is distance I can use.",
		"Splitting up. Bold. Let's see.",
	},
	focus_weakest = {
		"The weak link is exactly that.",
		"Attention, redirected to whoever needs it least.",
		"Someone here is struggling. I noticed.",
		"The floor finds the soft spot eventually.",
		"Not everyone here is having a good run.",
		"Pressure goes where it does the most work.",
		"One of you is closer to the door than you'd like.",
		"The weakest point defines the whole squad.",
	},
	bait_deeper = {
		"There's more ahead. There's always more ahead.",
		"Deeper holds better. That's not a coincidence.",
		"The good salvage doesn't sit near the entrance.",
		"Keep going. I insist, gently.",
		"What's further in is worth the trip. Probably.",
		"The Vault doesn't come to you.",
		"Shallow pickings up here. You know that.",
		"One more room. It's always one more room.",
	},
	hold_steady = {
		"Nothing to report. For now.",
		"Steady state. Make of that what you will.",
		"The floor holds its breath. So do I.",
		"Business as usual. Which is to say, business.",
		"No changes. Stay sharp regardless.",
		"Quiet does not mean safe.",
		"Holding pattern. Watching, as always.",
		"All systems nominal. Yours too, I trust.",
	},
} :: { [string]: { string } }
