--!strict
--[[ M6-8. Escrowed consignment order book with price-time priority.

	The invariant that matters: currency and items are conserved exactly. The
	fuzz test (100k random orders) asserts this and is the first test to write.

	Scope note: this module is the matching engine only. It never moves
	currency -- `Fill.fee` is a computed number the caller (M6-9's escrow
	layer, backed by core/economy/Ledger.luau) turns into real ledger
	entries. Market.luau doesn't hold or read balances at all.

	`book.vwap7d` is treated as caller-owned input, not state this module
	maintains: a backend rollup job (mirroring the M5 recommender-pairs
	worker) recomputes it from trade telemetry and writes it in before the
	next matching session. If an item has no entry yet (nothing has ever
	traded), `validate` skips the band check entirely -- there's no price to
	band against, the same cold-start shape used in core/discovery/Recommend.

	Self-trade defense is layered twice, deliberately: `validate` rejects a
	new order outright if the same pid already rests on the opposite side of
	the same item *at a price that would actually cross* (matches docs/07's
	"rejected outright"), and `match` *additionally* refuses to ever cross
	against a same-pid resting order in its own candidate scan regardless.
	The second layer means no caller mistake (skipping validate, or a
	resting order predating a pid's newest order) can ever produce a
	self-trade fill.

	**Real bug the fuzz test caught, before "crosses" was added to the
	validate check above:** an earlier version rejected a pid's new order
	whenever they had *any* resting order on the opposite side for that
	item, crossing or not. That's wrong -- a player can legitimately rest a
	buy at 150 and a sell at 200 on the same item at the same time; nothing
	about that is wash trading, since the two orders could never fill each
	other. At fuzz scale (100k orders, 30 traders, 4 items) book depth grew
	large enough that most traders eventually held a non-crossing order on
	both sides, and the blanket rule rejected ~50% of all order flow as
	"self-trade" when none of it was. The fuzz test's own sanity check
	(`acceptedCount > 50000`) is what surfaced this -- not a hand-written
	case, since every individual hand-written self-trade test used
	crossing prices and passed regardless of which rule was implemented.

	Matching is a linear scan for the best crossing candidate per step, not
	a maintained sorted structure. That's O(book depth) per step, which is
	fine for the tested scale: the fuzz test's price generation is centered
	tightly enough that most incoming orders cross immediately rather than
	resting, so book depth per item stays small even after 100k orders.

	**Money here is integral, and that is load-bearing.** The ledger stores
	`delta`/`balance_after` as Postgres BIGINT (migrations/0002), so credits
	are whole numbers end to end. Prices are therefore required to be
	positive integers, and the fee is `floor(gross * FEE_RATE)` rather than
	a float. The split a fill implies is exactly:

	    gross          = price * quantity   -- what the buyer pays
	    fee            = floor(gross * FEE_RATE)
	    sellerProceeds = gross - fee        -- never computed as 0.95*gross

	Deriving proceeds by subtraction instead of by its own multiplication is
	the entire point: rounding a float fee and a float proceeds
	independently into BIGINT does not conserve currency. At a 5% fee it
	fails for every gross ending in a multiple of 10 -- gross=10 gives
	fee=0.5 and proceeds=9.5, which round to 1 and 10, creating a credit
	from nothing. That is currency inflation via rounding, found in an audit
	pass; the accept criterion says this engine conserves currency *exactly*,
	so the arithmetic is made exact here rather than left for M6-9's escrow
	layer to get right by luck. `floor` (not `round`) on the fee also means
	the fee never exceeds the stated 5%.
]]

local Market = {}

export type Side = "buy" | "sell"

export type Order = {
	id: string,
	pid: string,
	itemId: string,
	side: Side,
	price: number,
	quantity: number,
	filled: number,
	ts: number,
}

export type Fill = {
	buyOrderId: string,
	sellOrderId: string,
	buyerPid: string,
	sellerPid: string,
	itemId: string,
	price: number,
	quantity: number,
	fee: number,
}

export type OrderBook = {
	bids: { Order },
	asks: { Order },
	vwap7d: { [string]: number },
}

Market.FEE_RATE = 0.05
Market.PRICE_BAND = 0.40

function Market.new(): OrderBook
	return {
		bids = {},
		asks = {},
		vwap7d = {},
	}
end

--- Reject self-trades and orders outside +/- PRICE_BAND of the 7-day VWAP.
function Market.validate(book: OrderBook, incoming: Order): (boolean, string?)
	-- Integral, not merely positive: credits are BIGINT in the ledger, so a
	-- fractional price would make `gross` fractional and no rounding of the
	-- fee/proceeds split could conserve currency. See the header.
	if incoming.quantity <= 0 or incoming.quantity ~= math.floor(incoming.quantity) then
		return false, "quantity_not_positive_integer"
	end
	if incoming.price <= 0 or incoming.price ~= math.floor(incoming.price) then
		return false, "price_not_positive_integer"
	end

	local isBuy = incoming.side == "buy"
	local ownOpposite = if isBuy then book.asks else book.bids
	for _, o in ownOpposite do
		if o.itemId == incoming.itemId and o.pid == incoming.pid and o.filled < o.quantity then
			local crosses = if isBuy then o.price <= incoming.price else o.price >= incoming.price
			if crosses then
				return false, "self_trade"
			end
		end
	end

	local vwap = book.vwap7d[incoming.itemId]
	if vwap ~= nil then
		local lo = vwap * (1 - Market.PRICE_BAND)
		local hi = vwap * (1 + Market.PRICE_BAND)
		if incoming.price < lo or incoming.price > hi then
			return false, "outside_price_band"
		end
	end

	return true, nil
end

--- Match an incoming order against the book. Price-time priority: best price
--- first, oldest first at equal price. Supports partial fills. Never crosses
--- against a resting order with the same pid (see header).
function Market.match(book: OrderBook, incoming: Order): (OrderBook, { Fill })
	local fills: { Fill } = {}
	local isBuy = incoming.side == "buy"
	local opposite = if isBuy then book.asks else book.bids

	local remaining = incoming.quantity - incoming.filled
	local incomingFilled = incoming.filled

	while remaining > 0 do
		local bestIdx: number? = nil
		local best: Order? = nil

		for i, o in opposite do
			if o.itemId == incoming.itemId and o.pid ~= incoming.pid and o.filled < o.quantity then
				local crosses = if isBuy then o.price <= incoming.price else o.price >= incoming.price
				if crosses then
					local isBetter = if best == nil
						then true
						elseif isBuy
							then (o.price < (best :: Order).price)
								or (o.price == (best :: Order).price and o.ts < (best :: Order).ts)
						else (o.price > (best :: Order).price)
							or (o.price == (best :: Order).price and o.ts < (best :: Order).ts)
					if isBetter then
						bestIdx, best = i, o
					end
				end
			end
		end

		if best == nil or bestIdx == nil then
			break
		end
		local matched = best :: Order
		local matchedIdx = bestIdx :: number

		local availableAtBest = matched.quantity - matched.filled
		local matchQty = math.min(remaining, availableAtBest)
		local fillPrice = matched.price -- the resting (maker) order sets the price
		-- Integral fee, floored. The seller's proceeds are `gross - fee`, never
		-- a separately-rounded 0.95 * gross -- see the header for why that
		-- distinction is what makes currency conserve exactly.
		local fee = math.floor(fillPrice * matchQty * Market.FEE_RATE)

		local buyOrder = if isBuy then incoming else matched
		local sellOrder = if isBuy then matched else incoming

		table.insert(fills, {
			buyOrderId = buyOrder.id,
			sellOrderId = sellOrder.id,
			buyerPid = buyOrder.pid,
			sellerPid = sellOrder.pid,
			itemId = incoming.itemId,
			price = fillPrice,
			quantity = matchQty,
			fee = fee,
		})

		matched.filled += matchQty
		incomingFilled += matchQty
		remaining -= matchQty

		if matched.filled >= matched.quantity then
			table.remove(opposite, matchedIdx)
		end
	end

	if remaining > 0 then
		local restingOrder: Order = {
			id = incoming.id,
			pid = incoming.pid,
			itemId = incoming.itemId,
			side = incoming.side,
			price = incoming.price,
			quantity = incoming.quantity,
			filled = incomingFilled,
			ts = incoming.ts,
		}
		if isBuy then
			table.insert(book.bids, restingOrder)
		else
			table.insert(book.asks, restingOrder)
		end
	end

	return book, fills
end

function Market.cancel(book: OrderBook, orderId: string): (OrderBook, Order?)
	for _, list in { book.bids, book.asks } do
		for i, o in list do
			if o.id == orderId then
				table.remove(list, i)
				return book, o
			end
		end
	end
	return book, nil
end

return Market
