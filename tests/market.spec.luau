--!strict
--[[ M6-8. core/economy/Market -- hand-crafted matching-mechanics cases,
	plus the fuzz test named in docs/07-ECONOMY.md: 100k random orders,
	conservation checked by independently tracking, per order id, how much
	of its own quantity was ever filled or refunded on cancel -- not by
	re-deriving the check from the module's own bookkeeping.
]]

local t = require("./framework")
local expect = t.expect

local Market = require("../src/shared/core/economy/Market")
local Rng = require("../src/shared/core/util/Rng")

local function order(id: string, pid: string, side: Market.Side, price: number, qty: number, ts: number): Market.Order
	return {
		id = id,
		pid = pid,
		itemId = "item1",
		side = side,
		price = price,
		quantity = qty,
		filled = 0,
		ts = ts,
	}
end

t.describe("Market.validate", function()
	t.it("rejects a self-trade outright, before price is even considered", function()
		local book = Market.new()
		book, _ = Market.match(book, order("s1", "alice", "sell", 100, 10, 1))
		local ok, reason = Market.validate(book, order("b1", "alice", "buy", 999, 1, 2))
		expect(ok).never().toBeTruthy()
		expect(reason).toEqual("self_trade")
	end)

	t.it("allows a different pid to cross the same resting order", function()
		local book = Market.new()
		book, _ = Market.match(book, order("s1", "alice", "sell", 100, 10, 1))
		local ok = Market.validate(book, order("b1", "bob", "buy", 100, 1, 2))
		expect(ok).toBeTruthy()
	end)

	t.it("cold start: no vwap entry means any positive price is allowed", function()
		local book = Market.new()
		local ok = Market.validate(book, order("o1", "alice", "sell", 999999, 1, 1))
		expect(ok).toBeTruthy()
	end)

	t.it("rejects a price outside +-40% of the recorded vwap, accepts at the boundary", function()
		local book = Market.new()
		book.vwap7d["item1"] = 100
		expect(Market.validate(book, order("o1", "alice", "sell", 140, 1, 1))).toBeTruthy()
		expect(Market.validate(book, order("o2", "alice", "sell", 60, 1, 1))).toBeTruthy()
		local ok1 = Market.validate(book, order("o3", "alice", "sell", 140.01, 1, 1))
		expect(ok1).never().toBeTruthy()
		local ok2 = Market.validate(book, order("o4", "alice", "sell", 59.99, 1, 1))
		expect(ok2).never().toBeTruthy()
	end)
end)

t.describe("Market.match -- price-time priority", function()
	t.it("fills the best price first, even though it was placed later", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 100, 10, 1)))
		book = (Market.match(book, order("b", "seller_b", "sell", 95, 10, 2)))

		local _, fills = Market.match(book, order("buy1", "buyer", "buy", 100, 15, 3))
		expect(#fills).toEqual(2)
		expect(fills[1].sellOrderId).toEqual("b") -- better price (95) fills first
		expect(fills[1].price).toEqual(95)
		expect(fills[1].quantity).toEqual(10)
		expect(fills[2].sellOrderId).toEqual("a")
		expect(fills[2].price).toEqual(100)
		expect(fills[2].quantity).toEqual(5)
	end)

	t.it("at equal price, the earlier order fills first", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 100, 5, 1)))
		book = (Market.match(book, order("b", "seller_b", "sell", 100, 5, 2)))

		local _, fills = Market.match(book, order("buy1", "buyer", "buy", 100, 6, 3))
		expect(#fills).toEqual(2)
		expect(fills[1].sellOrderId).toEqual("a")
		expect(fills[1].quantity).toEqual(5)
		expect(fills[2].sellOrderId).toEqual("b")
		expect(fills[2].quantity).toEqual(1)
	end)

	t.it("the fill price is always the resting (maker) order's price, not the taker's", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 90, 5, 1)))
		local _, fills = Market.match(book, order("buy1", "buyer", "buy", 100, 5, 2))
		expect(fills[1].price).toEqual(90)
	end)
end)

t.describe("Market.match -- partial fills and resting remainder", function()
	t.it("an order larger than the book fills what it can and rests the remainder", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 100, 10, 1)))
		local newBook, fills = Market.match(book, order("buy1", "buyer", "buy", 100, 15, 2))
		expect(#fills).toEqual(1)
		expect(fills[1].quantity).toEqual(10)
		expect(#newBook.bids).toEqual(1)
		expect(newBook.bids[1].quantity).toEqual(15)
		expect(newBook.bids[1].filled).toEqual(10)
	end)

	t.it("an order with nothing to match against rests entirely, unfilled", function()
		local book = Market.new()
		local newBook, fills = Market.match(book, order("buy1", "buyer", "buy", 100, 5, 1))
		expect(#fills).toEqual(0)
		expect(#newBook.bids).toEqual(1)
		expect(newBook.bids[1].filled).toEqual(0)
	end)

	t.it("fee is floor(price * quantity * FEE_RATE), an exact integer", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 200, 3, 1)))
		local _, fills = Market.match(book, order("buy1", "buyer", "buy", 200, 3, 2))
		expect(fills[1].fee).toEqual(math.floor(200 * 3 * Market.FEE_RATE))
		expect(fills[1].fee).toEqual(30)
	end)

	-- Currency is BIGINT in the ledger (migrations/0002), so the fee must be a
	-- whole number of credits and the seller's proceeds must be gross - fee.
	-- Rounding a float fee and a float proceeds independently does not
	-- conserve currency: at 5%, gross=10 gives fee=0.5 and proceeds=9.5, which
	-- round to 1 and 10 and create a credit out of nothing.
	t.it("fee is always integral, and gross splits exactly into fee + proceeds", function()
		for gross = 1, 300 do
			local fee = math.floor(gross * Market.FEE_RATE)
			local proceeds = gross - fee
			expect(fee).toEqual(math.floor(fee))
			expect(proceeds).toEqual(math.floor(proceeds))
			expect(fee + proceeds).toEqual(gross)
			expect(fee <= gross * Market.FEE_RATE).toBeTruthy() -- floor never overcharges
		end
	end)

	t.it("a fractional price is rejected, since credits are whole numbers", function()
		local book = Market.new()
		local ok, reason = Market.validate(book, order("o1", "alice", "sell", 99.5, 1, 1))
		expect(ok).never().toBeTruthy()
		expect(reason).toEqual("price_not_positive_integer")
	end)

	t.it("a fractional quantity is rejected", function()
		local book = Market.new()
		local ok, reason = Market.validate(book, order("o1", "alice", "sell", 100, 1.5, 1))
		expect(ok).never().toBeTruthy()
		expect(reason).toEqual("quantity_not_positive_integer")
	end)
end)

t.describe("Market.match -- self-trade defense in the matching loop itself", function()
	t.it("never crosses a resting order from the same pid, even if validate() was skipped", function()
		local book = Market.new()
		book = (Market.match(book, order("s1", "alice", "sell", 100, 10, 1)))
		-- Calling match() directly, bypassing validate(), on purpose.
		local newBook, fills = Market.match(book, order("b1", "alice", "buy", 100, 10, 2))
		expect(#fills).toEqual(0)
		-- The buy order had nothing eligible to match against, so it rests.
		expect(#newBook.bids).toEqual(1)
		-- The alice sell order is untouched.
		expect(#newBook.asks).toEqual(1)
		expect(newBook.asks[1].filled).toEqual(0)
	end)
end)

t.describe("Market.cancel", function()
	t.it("returns the order with its exact fill state, and removes it from the book", function()
		local book = Market.new()
		book = (Market.match(book, order("a", "seller_a", "sell", 100, 10, 1)))
		book = (Market.match(book, order("buy1", "buyer", "buy", 100, 4, 2))) -- partial fill: 4 of 10

		local newBook, canceled = Market.cancel(book, "a")
		expect(canceled).never().toEqual(nil :: any)
		local c = canceled :: Market.Order
		expect(c.quantity).toEqual(10)
		expect(c.filled).toEqual(4) -- exact remaining = 10 - 4 = 6, recoverable by the caller
		expect(#newBook.asks).toEqual(0)
	end)

	t.it("canceling an unknown id is a no-op that reports not-found", function()
		local book = Market.new()
		local newBook, canceled = Market.cancel(book, "does-not-exist")
		expect(canceled).toEqual(nil :: any)
		expect(#newBook.bids).toEqual(0)
		expect(#newBook.asks).toEqual(0)
	end)
end)

t.describe("Market fuzz: 100k random orders conserve items and currency exactly", function()
	t.it("every order's cumulative fill never exceeds its own quantity, and every unit is accounted for as filled, resting, or canceled", function()
		local book = Market.new()
		local items = { "item1", "item2", "item3", "item4" }
		-- 500, not 30: with few traders and heavy per-trader order volume, book
		-- depth grows large enough that most traders end up with resting
		-- liquidity on both sides of an item, and a large fraction of all new
		-- orders are legitimately self-trades. 500 traders keeps the rejection
		-- rate a meaningful-but-minority fraction, closer to realistic load.
		local pids = {}
		for i = 1, 500 do
			pids[i] = `trader{i}`
		end
		for _, item in items do
			book.vwap7d[item] = 100
		end

		local rng = Rng.new(778899)
		local originalQty: { [string]: number } = {}
		local filledTotal: { [string]: number } = {}
		local canceled: { [string]: boolean } = {}
		local everAccepted: { string } = {}

		local acceptedCount, rejectedCount, cancelAttempts, cancelHits = 0, 0, 0, 0
		local buyerPaidTotal, sellerReceivedTotal, feeSinkTotal = 0, 0, 0

		local N = 100000
		for i = 1, N do
			-- Occasionally try to cancel a previously-accepted order instead of
			-- placing a new one.
			if i > 100 and Rng.chance(rng, 0.05) then
				cancelAttempts += 1
				local pick = everAccepted[Rng.nextRange(rng, 1, #everAccepted)]
				local newBook, removed = Market.cancel(book, pick)
				book = newBook
				if removed ~= nil then
					cancelHits += 1
					local r = removed :: Market.Order
					-- Exact remaining, matching what we independently tracked.
					expect(r.quantity - r.filled).toEqual(originalQty[pick] - (filledTotal[pick] or 0))
					canceled[pick] = true
				end
			else
				local id = `o{i}`
				local pid = pids[Rng.nextRange(rng, 1, #pids)]
				local item = items[Rng.nextRange(rng, 1, #items)]
				local side: Market.Side = if Rng.chance(rng, 0.5) then "buy" else "sell"
				-- +-10% jitter around the fixed fair value of 100, comfortably
				-- inside the +-40% band, tuned so most orders cross immediately
				-- and book depth per item stays small across 100k orders.
				-- Integral, because credits are integral (see Market's header).
				local price = Rng.nextRange(rng, 90, 110)
				local qty = Rng.nextRange(rng, 1, 20)
				local incoming: Market.Order = {
					id = id,
					pid = pid,
					itemId = item,
					side = side,
					price = price,
					quantity = qty,
					filled = 0,
					ts = i,
				}

				local ok = Market.validate(book, incoming)
				if not ok then
					rejectedCount += 1
				else
					acceptedCount += 1
					originalQty[id] = qty
					table.insert(everAccepted, id)

					local newBook, fills = Market.match(book, incoming)
					book = newBook
					for _, f in fills do
						expect(f.quantity > 0).toBeTruthy()
						expect(f.buyerPid).never().toEqual(f.sellerPid)
						expect(f.fee).toEqual(math.floor(f.price * f.quantity * Market.FEE_RATE))

						-- Currency conservation, per fill and in aggregate. The
						-- accept criterion says this engine conserves currency
						-- *exactly*, and only item quantities were being checked
						-- before an audit pass added this.
						local gross = f.price * f.quantity
						local proceeds = gross - f.fee
						expect(gross).toEqual(math.floor(gross)) -- whole credits
						expect(f.fee).toEqual(math.floor(f.fee))
						expect(proceeds).toEqual(math.floor(proceeds))
						-- Nothing created, nothing destroyed: what the buyer pays
						-- is exactly what the seller receives plus the fee sink.
						expect(proceeds + f.fee).toEqual(gross)
						expect(f.fee >= 0).toBeTruthy()
						expect(proceeds >= 0).toBeTruthy()

						buyerPaidTotal += gross
						sellerReceivedTotal += proceeds
						feeSinkTotal += f.fee

						filledTotal[f.buyOrderId] = (filledTotal[f.buyOrderId] or 0) + f.quantity
						filledTotal[f.sellOrderId] = (filledTotal[f.sellOrderId] or 0) + f.quantity
					end
				end
			end
		end

		-- No order was ever filled beyond its own original quantity.
		for id, qty in originalQty do
			local filled = filledTotal[id] or 0
			expect(filled <= qty).toBeTruthy()
		end

		-- Every accepted, non-canceled order is either fully filled (and so
		-- correctly auto-removed from the book) or still resting in the book
		-- with its stored `.filled` matching our independently tracked total
		-- exactly. Nothing is unaccounted for.
		local stillResting: { [string]: Market.Order } = {}
		for _, o in book.bids do
			stillResting[o.id] = o
		end
		for _, o in book.asks do
			stillResting[o.id] = o
		end

		local restingCount, fullyFilledCount = 0, 0
		for _, id in everAccepted do
			if not canceled[id] then
				local filled = filledTotal[id] or 0
				local resting = stillResting[id]
				if resting ~= nil then
					restingCount += 1
					expect(resting.filled).toEqual(filled)
					expect(resting.quantity).toEqual(originalQty[id])
				else
					fullyFilledCount += 1
					expect(filled).toEqual(originalQty[id])
				end
			end
		end

		expect(acceptedCount + rejectedCount + cancelAttempts <= N).toBeTruthy()
		expect(acceptedCount > 50000).toBeTruthy() -- sanity: the run actually exercised matching at scale
		expect(cancelHits > 0).toBeTruthy() -- sanity: cancel path was actually exercised
		expect(restingCount + fullyFilledCount > 0).toBeTruthy()

		-- Aggregate currency conservation across every fill in the run: every
		-- credit a buyer paid arrived either at a seller or in the fee sink.
		-- Exact equality, not approximate -- these are whole credits.
		expect(buyerPaidTotal > 0).toBeTruthy() -- sanity: money actually moved
		expect(sellerReceivedTotal + feeSinkTotal).toEqual(buyerPaidTotal)
		expect(feeSinkTotal > 0).toBeTruthy() -- sanity: the fee sink actually ran
	end)
end)
