--!strict
--[[ M6-9. core/economy/Escrow -- the two accept criteria from BACKLOG
	("item cannot be in escrow and inventory simultaneously", "cancel returns
	exact escrow"), the abuse caps from docs/07, and an end-to-end fuzz that
	drives Escrow + Market together and asserts credits and items are
	conserved exactly across the whole pipeline.
]]

local t = require("./framework")
local expect = t.expect

local Escrow = require("../src/shared/core/economy/Escrow")
local Market = require("../src/shared/core/economy/Market")
local Rng = require("../src/shared/core/util/Rng")

local CAPS: Escrow.Caps = {
	maxOpenOrdersPerItem = 5,
	dailyTradeVolumeCap = 25000,
	minRunsToSell = 5,
}

--- An account with enough history to trade and the given holdings.
local function seed(state: Escrow.EscrowState, pid: string, credits: number, items: { [string]: number })
	local account = Escrow.account(state, pid)
	account.credits = credits
	account.runsPlayed = 10
	for id, count in items do
		account.inventory[id] = count
	end
end

t.describe("Escrow: an item is in exactly one place", function()
	t.it("listing moves the item out of inventory and into escrow, never both", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 3 })

		local result = Escrow.placeSell(state, "o1", "alice", "relic", 100, 2, CAPS)
		expect(result.ok).toBeTruthy()

		-- The accept criterion, stated directly.
		expect(Escrow.inventoryCount(state, "alice", "relic")).toEqual(1)
		expect(Escrow.escrowedCount(state, "alice", "relic")).toEqual(2)
		-- And the total is unchanged: nothing was duplicated or destroyed.
		expect(Escrow.totalItems(state, "relic")).toEqual(3)
	end)

	t.it("cannot list more than is held, even across several orders", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 3 })

		expect(Escrow.placeSell(state, "o1", "alice", "relic", 100, 2, CAPS).ok).toBeTruthy()
		-- Only 1 left in inventory; the escrowed 2 must not be listable again.
		local second = Escrow.placeSell(state, "o2", "alice", "relic", 100, 2, CAPS)
		expect(second.ok).never().toBeTruthy()
		expect(second.reason).toEqual("insufficient_items")
		expect(Escrow.totalItems(state, "relic")).toEqual(3)
	end)

	t.it("listing the last item removes the inventory key rather than leaving a zero", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 1 })
		Escrow.placeSell(state, "o1", "alice", "relic", 100, 1, CAPS)
		expect(Escrow.inventoryCount(state, "alice", "relic")).toEqual(0)
		expect(Escrow.totalItems(state, "relic")).toEqual(1)
	end)

	t.it("credits leave the spendable balance when a bid is placed", function()
		local state = Escrow.new()
		seed(state, "bob", 1000, {})
		expect(Escrow.placeBuy(state, "b1", "bob", "relic", 100, 3, CAPS).ok).toBeTruthy()
		expect(Escrow.account(state, "bob").credits).toEqual(700)
		expect(Escrow.escrowedCredits(state, "bob")).toEqual(300)
		expect(Escrow.totalCredits(state)).toEqual(1000)
	end)

	t.it("cannot bid more credits than are spendable", function()
		local state = Escrow.new()
		seed(state, "bob", 250, {})
		local result = Escrow.placeBuy(state, "b1", "bob", "relic", 100, 3, CAPS)
		expect(result.ok).never().toBeTruthy()
		expect(result.reason).toEqual("insufficient_credits")
		expect(Escrow.account(state, "bob").credits).toEqual(250)
	end)
end)

t.describe("Escrow.cancel returns exact escrow", function()
	t.it("an untouched sell returns every item", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 3 })
		Escrow.placeSell(state, "o1", "alice", "relic", 100, 2, CAPS)

		expect(Escrow.cancel(state, "o1")).toBeTruthy()
		expect(Escrow.inventoryCount(state, "alice", "relic")).toEqual(3)
		expect(Escrow.escrowedCount(state, "alice", "relic")).toEqual(0)
		expect(Escrow.totalItems(state, "relic")).toEqual(3)
	end)

	t.it("an untouched buy returns every credit", function()
		local state = Escrow.new()
		seed(state, "bob", 1000, {})
		Escrow.placeBuy(state, "b1", "bob", "relic", 100, 3, CAPS)

		expect(Escrow.cancel(state, "b1")).toBeTruthy()
		expect(Escrow.account(state, "bob").credits).toEqual(1000)
		expect(Escrow.totalCredits(state)).toEqual(1000)
	end)

	t.it("a partially filled sell returns only the unsold remainder", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 5 })
		seed(state, "bob", 1000, {})
		Escrow.placeSell(state, "s1", "alice", "relic", 100, 5, CAPS)
		Escrow.placeBuy(state, "b1", "bob", "relic", 100, 2, CAPS)

		local ok = Escrow.settle(state, {
			buyOrderId = "b1",
			sellOrderId = "s1",
			buyerPid = "bob",
			sellerPid = "alice",
			itemId = "relic",
			price = 100,
			quantity = 2,
			fee = math.floor(100 * 2 * Market.FEE_RATE),
		})
		expect(ok).toBeTruthy()

		expect(Escrow.cancel(state, "s1")).toBeTruthy()
		-- 5 listed, 2 sold, so exactly 3 come back -- not 5, not 0.
		expect(Escrow.inventoryCount(state, "alice", "relic")).toEqual(3)
		expect(Escrow.totalItems(state, "relic")).toEqual(5)
	end)

	t.it("cancelling twice does not refund twice", function()
		local state = Escrow.new()
		seed(state, "bob", 1000, {})
		Escrow.placeBuy(state, "b1", "bob", "relic", 100, 3, CAPS)

		expect(Escrow.cancel(state, "b1")).toBeTruthy()
		local second, reason = Escrow.cancel(state, "b1")
		expect(second).never().toBeTruthy()
		expect(reason).toEqual("unknown_order")
		expect(Escrow.account(state, "bob").credits).toEqual(1000)
	end)

	t.it("a fully filled order is gone and cannot be cancelled for a refund", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 2 })
		seed(state, "bob", 1000, {})
		Escrow.placeSell(state, "s1", "alice", "relic", 100, 2, CAPS)
		Escrow.placeBuy(state, "b1", "bob", "relic", 100, 2, CAPS)
		Escrow.settle(state, {
			buyOrderId = "b1", sellOrderId = "s1", buyerPid = "bob", sellerPid = "alice",
			itemId = "relic", price = 100, quantity = 2,
			fee = math.floor(100 * 2 * Market.FEE_RATE),
		})

		local ok, reason = Escrow.cancel(state, "s1")
		expect(ok).never().toBeTruthy()
		expect(reason).toEqual("unknown_order")
	end)
end)

t.describe("Escrow.settle", function()
	t.it("moves the item to the buyer and credits to the seller net of fee", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 1 })
		seed(state, "bob", 500, {})
		Escrow.placeSell(state, "s1", "alice", "relic", 200, 1, CAPS)
		Escrow.placeBuy(state, "b1", "bob", "relic", 200, 1, CAPS)

		local fee = math.floor(200 * Market.FEE_RATE) -- 10
		expect(Escrow.settle(state, {
			buyOrderId = "b1", sellOrderId = "s1", buyerPid = "bob", sellerPid = "alice",
			itemId = "relic", price = 200, quantity = 1, fee = fee,
		})).toBeTruthy()

		expect(Escrow.inventoryCount(state, "bob", "relic")).toEqual(1)
		expect(Escrow.inventoryCount(state, "alice", "relic")).toEqual(0)
		expect(Escrow.account(state, "alice").credits).toEqual(200 - fee)
		expect(state.feesCollected).toEqual(fee)
		-- 500 started with bob; alice got 190, the sink got 10.
		expect(Escrow.totalCredits(state)).toEqual(500)
	end)

	t.it("refunds price improvement instead of pocketing it", function()
		-- The buyer bid 200 but the resting ask was 150. They must pay 150 and
		-- get the 50 difference back -- a book that keeps it is stealing.
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 1 })
		seed(state, "bob", 500, {})
		Escrow.placeSell(state, "s1", "alice", "relic", 150, 1, CAPS)
		Escrow.placeBuy(state, "b1", "bob", "relic", 200, 1, CAPS)

		local fee = math.floor(150 * Market.FEE_RATE)
		Escrow.settle(state, {
			buyOrderId = "b1", sellOrderId = "s1", buyerPid = "bob", sellerPid = "alice",
			itemId = "relic", price = 150, quantity = 1, fee = fee,
		})

		-- 500 - 200 escrowed = 300, then +50 improvement refunded.
		expect(Escrow.account(state, "bob").credits).toEqual(350)
		expect(Escrow.totalCredits(state)).toEqual(500)
	end)
end)

t.describe("Escrow abuse caps (docs/07)", function()
	t.it("an account under the run floor cannot sell", function()
		local state = Escrow.new()
		local account = Escrow.account(state, "fresh")
		account.runsPlayed = 4 -- one short of minRunsToSell
		account.inventory["relic"] = 5

		local result = Escrow.placeSell(state, "o1", "fresh", "relic", 100, 1, CAPS)
		expect(result.ok).never().toBeTruthy()
		expect(result.reason).toEqual("account_too_new_to_sell")
	end)

	t.it("but a new account may still buy -- alt farming is about extracting value", function()
		local state = Escrow.new()
		local account = Escrow.account(state, "fresh")
		account.runsPlayed = 0
		account.credits = 1000
		expect(Escrow.placeBuy(state, "b1", "fresh", "relic", 100, 1, CAPS).ok).toBeTruthy()
	end)

	t.it("caps open orders per item, and the cap is per item not global", function()
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 20, shard = 5 })
		for i = 1, CAPS.maxOpenOrdersPerItem do
			expect(Escrow.placeSell(state, `r{i}`, "alice", "relic", 100, 1, CAPS).ok).toBeTruthy()
		end
		local overflow = Escrow.placeSell(state, "r6", "alice", "relic", 100, 1, CAPS)
		expect(overflow.ok).never().toBeTruthy()
		expect(overflow.reason).toEqual("too_many_open_orders_for_item")

		-- A different item is unaffected.
		expect(Escrow.placeSell(state, "s1", "alice", "shard", 100, 1, CAPS).ok).toBeTruthy()
	end)

	t.it("caps daily traded volume", function()
		local state = Escrow.new()
		seed(state, "whale", 0, { relic = 100 })
		Escrow.account(state, "whale").dailyVolume = CAPS.dailyTradeVolumeCap - 100

		-- 100 of headroom left; a 200-credit order must not fit.
		local result = Escrow.placeSell(state, "o1", "whale", "relic", 200, 1, CAPS)
		expect(result.ok).never().toBeTruthy()
		expect(result.reason).toEqual("daily_volume_cap_exceeded")

		-- Exactly at the cap is allowed.
		expect(Escrow.placeSell(state, "o2", "whale", "relic", 100, 1, CAPS).ok).toBeTruthy()
	end)

	t.it("rejects a duplicate order id rather than overwriting escrow", function()
		-- Overwriting would strand the first order's escrow with no way to
		-- reclaim it -- items destroyed by a reused id.
		local state = Escrow.new()
		seed(state, "alice", 0, { relic = 5 })
		expect(Escrow.placeSell(state, "o1", "alice", "relic", 100, 1, CAPS).ok).toBeTruthy()
		local dup = Escrow.placeSell(state, "o1", "alice", "relic", 100, 1, CAPS)
		expect(dup.ok).never().toBeTruthy()
		expect(dup.reason).toEqual("duplicate_order_id")
		expect(Escrow.totalItems(state, "relic")).toEqual(5)
	end)
end)

t.describe("Escrow + Market end to end: conservation under fuzz", function()
	t.it("20k random place/cancel/match operations conserve credits and items exactly", function()
		local state = Escrow.new()
		local book = Market.new()
		local items = { "relic", "shard", "core" }
		local pids = {}
		for i = 1, 40 do
			pids[i] = `trader{i}`
		end

		local STARTING_CREDITS = 50000
		local STARTING_ITEMS = 20
		for _, pid in pids do
			local account = Escrow.account(state, pid)
			account.credits = STARTING_CREDITS
			account.runsPlayed = 50
			-- Volume caps would dominate a fuzz run of this length; this test is
			-- about conservation, and the caps have their own tests above.
			account.dailyVolume = 0
			for _, item in items do
				account.inventory[item] = STARTING_ITEMS
			end
		end
		for _, item in items do
			book.vwap7d[item] = 100
		end

		local expectedCredits = #pids * STARTING_CREDITS
		local expectedItems: { [string]: number } = {}
		for _, item in items do
			expectedItems[item] = #pids * STARTING_ITEMS
		end

		local caps: Escrow.Caps = {
			maxOpenOrdersPerItem = 5,
			dailyTradeVolumeCap = math.huge,
			minRunsToSell = 5,
		}

		local rng = Rng.new(20260821)
		local live: { string } = {}
		local nextId = 0
		local placed, settled, cancelled = 0, 0, 0

		for step = 1, 20000 do
			if #live > 0 and Rng.chance(rng, 0.25) then
				local idx = Rng.nextRange(rng, 1, #live)
				local orderId = live[idx]
				table.remove(live, idx)
				-- May already be gone via a fill; cancel reports that honestly.
				local ok = Escrow.cancel(state, orderId)
				if ok then
					cancelled += 1
					Market.cancel(book, orderId)
				end
			else
				nextId += 1
				local orderId = `o{nextId}`
				local pid = pids[Rng.nextRange(rng, 1, #pids)]
				local itemId = items[Rng.nextRange(rng, 1, #items)]
				local price = Rng.nextRange(rng, 80, 120)
				local quantity = Rng.nextRange(rng, 1, 4)
				local side: Market.Side = if Rng.chance(rng, 0.5) then "buy" else "sell"

				local incoming: Market.Order = {
					id = orderId, pid = pid, itemId = itemId, side = side,
					price = price, quantity = quantity, filled = 0, ts = step,
				}
				if Market.validate(book, incoming) then
					local reserved = if side == "sell"
						then Escrow.placeSell(state, orderId, pid, itemId, price, quantity, caps)
						else Escrow.placeBuy(state, orderId, pid, itemId, price, quantity, caps)
					if reserved.ok then
						placed += 1
						table.insert(live, orderId)
						local newBook, fills = Market.match(book, incoming)
						book = newBook
						for _, fill in fills do
							local ok, reason = Escrow.settle(state, fill)
							-- A settle failure would mean escrow and the book
							-- disagree about what exists -- fail loudly rather
							-- than let the conservation check paper over it.
							expect(ok).toBeTruthy()
							expect(reason).toEqual(nil :: any)
							settled += 1
						end
					end
				end
			end

			-- Continuous invariant, not just an end-state check: no account may
			-- ever hold negative credits, and no escrow may go negative.
			if step % 500 == 0 then
				for _, pid in pids do
					expect(Escrow.account(state, pid).credits >= 0).toBeTruthy()
				end
				for _, order in state.orders do
					expect(order.creditsHeld >= 0).toBeTruthy()
					expect(order.itemsHeld >= 0).toBeTruthy()
				end
			end
		end

		-- Sanity: the run actually exercised all three paths.
		expect(placed > 1000).toBeTruthy()
		expect(settled > 100).toBeTruthy()
		expect(cancelled > 100).toBeTruthy()

		-- The invariant. Exact equality -- these are whole credits and whole
		-- items, and "approximately conserved" is not conserved.
		expect(Escrow.totalCredits(state)).toEqual(expectedCredits)
		for _, item in items do
			expect(Escrow.totalItems(state, item)).toEqual(expectedItems[item])
		end
		expect(state.feesCollected > 0).toBeTruthy() -- the sink really ran
	end)
end)
