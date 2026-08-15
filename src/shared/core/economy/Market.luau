--!strict
--[[ M6-8. Escrowed consignment order book with price-time priority.

	The invariant that matters: currency and items are conserved exactly. The
	fuzz test (100k random orders) asserts this and is the first test to write.
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
	error("unimplemented: Market.new (M6-8)")
end

--- Match an incoming order against the book. Price-time priority: best price
--- first, oldest first at equal price. Supports partial fills.
function Market.match(book: OrderBook, incoming: Order): (OrderBook, { Fill })
	error("unimplemented: Market.match (M6-8)")
end

--- Reject self-trades and orders outside +/- PRICE_BAND of the 7-day VWAP.
function Market.validate(book: OrderBook, incoming: Order): (boolean, string?)
	error("unimplemented: Market.validate (M6-8)")
end

function Market.cancel(book: OrderBook, orderId: string): (OrderBook, Order?)
	error("unimplemented: Market.cancel (M6-8)")
end

return Market
