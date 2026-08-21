--!strict
--[[ M6-9. Escrow, order lifecycle, and abuse caps.

	The layer between `Market` (which decides *what matches*) and `Ledger`
	(which records *what currency moved*). Neither of those holds inventory,
	and neither knows whether a player is allowed to place an order. This
	does both.

	**The invariant this module exists to enforce:** an item is in exactly
	one place at a time -- a player's inventory, or escrow -- and the
	transition between them is a single indivisible step. docs/07 names
	duping-via-race as the attack; the defence is that nothing here ever
	reads a balance, decides, and then writes. `placeSell` removes from
	inventory and adds to escrow in one call that either fully happens or
	does not happen at all, and there is no intermediate state a concurrent
	caller could observe. Same for credits on the buy side.

	`Escrow.state` is deliberately the single owner of both inventories and
	escrowed holdings, rather than escrow being a separate structure that
	has to be kept in sync with an inventory living somewhere else. Two
	structures that must agree are two structures that will eventually
	disagree; one structure cannot.

	Currency is integral throughout, matching `Market` and the ledger's
	BIGINT columns. Escrowed credits for a buy order are `price * quantity`
	exactly -- the buyer's maximum possible outlay -- so a partial fill can
	always pay out and a cancel can always refund without rounding.

	**Fee accounting on a fill.** The buyer escrowed `price * quantity`.
	They pay the *maker's* price, which for a buy order can be lower than
	their own limit, so the difference is refunded rather than silently
	kept -- a book that quietly pockets price improvement is stealing.
	The seller receives `gross - fee`, the fee goes to the sink, and
	`gross = sellerProceeds + fee` exactly (see Market's header).
]]

local Market = require("./Market")

local Escrow = {}

export type Holding = { [string]: number } -- itemId -> count

export type EscrowedOrder = {
	orderId: string,
	pid: string,
	itemId: string,
	side: Market.Side,
	price: number,
	quantity: number,
	filled: number,
	--- Credits still held for this order (buy side only; 0 for sells).
	creditsHeld: number,
	--- Items still held for this order (sell side only; 0 for buys).
	itemsHeld: number,
}

export type Caps = {
	maxOpenOrdersPerItem: number,
	dailyTradeVolumeCap: number,
	minRunsToSell: number,
}

export type Account = {
	credits: number,
	inventory: Holding,
	runsPlayed: number,
	--- Credits of trade volume transacted in the current day window.
	dailyVolume: number,
}

export type EscrowState = {
	accounts: { [string]: Account },
	orders: { [string]: EscrowedOrder },
	--- Total fees collected, the market sink. Read by the economy rollup.
	feesCollected: number,
}

export type PlaceResult = {
	ok: boolean,
	reason: string?,
}

function Escrow.new(): EscrowState
	return { accounts = {}, orders = {}, feesCollected = 0 }
end

function Escrow.account(state: EscrowState, pid: string): Account
	local existing = state.accounts[pid]
	if existing ~= nil then
		return existing
	end
	local fresh: Account = { credits = 0, inventory = {}, runsPlayed = 0, dailyVolume = 0 }
	state.accounts[pid] = fresh
	return fresh
end

function Escrow.inventoryCount(state: EscrowState, pid: string, itemId: string): number
	return Escrow.account(state, pid).inventory[itemId] or 0
end

--- Items this pid currently has locked in open sell orders.
function Escrow.escrowedCount(state: EscrowState, pid: string, itemId: string): number
	local total = 0
	for _, order in state.orders do
		if order.pid == pid and order.itemId == itemId then
			total += order.itemsHeld
		end
	end
	return total
end

function Escrow.escrowedCredits(state: EscrowState, pid: string): number
	local total = 0
	for _, order in state.orders do
		if order.pid == pid then
			total += order.creditsHeld
		end
	end
	return total
end

local function openOrdersFor(state: EscrowState, pid: string, itemId: string): number
	local count = 0
	for _, order in state.orders do
		if order.pid == pid and order.itemId == itemId and order.filled < order.quantity then
			count += 1
		end
	end
	return count
end

--- Shared gate for both sides. Returns nil when allowed, else a reason.
local function capViolation(
	state: EscrowState,
	pid: string,
	itemId: string,
	side: Market.Side,
	notionalValue: number,
	caps: Caps
): string?
	local account = Escrow.account(state, pid)
	-- docs/07: new accounts (< 5 runs) cannot sell. Buying is unrestricted --
	-- the alt-farming attack is about *extracting* value from throwaway
	-- accounts, and a new account spending its own credits is just a player.
	if side == "sell" and account.runsPlayed < caps.minRunsToSell then
		return "account_too_new_to_sell"
	end
	if openOrdersFor(state, pid, itemId) >= caps.maxOpenOrdersPerItem then
		return "too_many_open_orders_for_item"
	end
	if account.dailyVolume + notionalValue > caps.dailyTradeVolumeCap then
		return "daily_volume_cap_exceeded"
	end
	return nil
end

--- List an item for sale. The item leaves inventory and enters escrow in this
--- one call; there is no window in which it is in both or neither.
function Escrow.placeSell(
	state: EscrowState,
	orderId: string,
	pid: string,
	itemId: string,
	price: number,
	quantity: number,
	caps: Caps
): PlaceResult
	if state.orders[orderId] ~= nil then
		return { ok = false, reason = "duplicate_order_id" }
	end
	if quantity <= 0 or quantity ~= math.floor(quantity) then
		return { ok = false, reason = "quantity_not_positive_integer" }
	end
	if price <= 0 or price ~= math.floor(price) then
		return { ok = false, reason = "price_not_positive_integer" }
	end

	local account = Escrow.account(state, pid)
	local held = account.inventory[itemId] or 0
	if held < quantity then
		return { ok = false, reason = "insufficient_items" }
	end

	local violation = capViolation(state, pid, itemId, "sell", price * quantity, caps)
	if violation ~= nil then
		return { ok = false, reason = violation }
	end

	-- The indivisible transition: out of inventory, into escrow.
	local remaining = held - quantity
	account.inventory[itemId] = if remaining > 0 then remaining else nil
	state.orders[orderId] = {
		orderId = orderId,
		pid = pid,
		itemId = itemId,
		side = "sell",
		price = price,
		quantity = quantity,
		filled = 0,
		creditsHeld = 0,
		itemsHeld = quantity,
	}
	return { ok = true }
end

--- Place a bid. Credits leave the spendable balance and enter escrow.
function Escrow.placeBuy(
	state: EscrowState,
	orderId: string,
	pid: string,
	itemId: string,
	price: number,
	quantity: number,
	caps: Caps
): PlaceResult
	if state.orders[orderId] ~= nil then
		return { ok = false, reason = "duplicate_order_id" }
	end
	if quantity <= 0 or quantity ~= math.floor(quantity) then
		return { ok = false, reason = "quantity_not_positive_integer" }
	end
	if price <= 0 or price ~= math.floor(price) then
		return { ok = false, reason = "price_not_positive_integer" }
	end

	local account = Escrow.account(state, pid)
	local cost = price * quantity
	if account.credits < cost then
		return { ok = false, reason = "insufficient_credits" }
	end

	local violation = capViolation(state, pid, itemId, "buy", cost, caps)
	if violation ~= nil then
		return { ok = false, reason = violation }
	end

	account.credits -= cost
	state.orders[orderId] = {
		orderId = orderId,
		pid = pid,
		itemId = itemId,
		side = "buy",
		price = price,
		quantity = quantity,
		filled = 0,
		creditsHeld = cost,
		itemsHeld = 0,
	}
	return { ok = true }
end

--- Cancel an unfilled or partially filled order. Returns exactly what is
--- still escrowed -- never more (which would mint) and never less (which
--- would confiscate).
function Escrow.cancel(state: EscrowState, orderId: string): (boolean, string?)
	local order = state.orders[orderId]
	if order == nil then
		return false, "unknown_order"
	end
	local account = Escrow.account(state, order.pid)

	if order.itemsHeld > 0 then
		account.inventory[order.itemId] = (account.inventory[order.itemId] or 0) + order.itemsHeld
	end
	if order.creditsHeld > 0 then
		account.credits += order.creditsHeld
	end

	state.orders[orderId] = nil
	return true, nil
end

--- Settle one fill produced by `Market.match`. Moves the item to the buyer,
--- credits to the seller net of fee, and refunds the buyer any price
--- improvement (they escrowed at their own limit but pay the maker's price).
function Escrow.settle(state: EscrowState, fill: Market.Fill): (boolean, string?)
	local buyOrder = state.orders[fill.buyOrderId]
	local sellOrder = state.orders[fill.sellOrderId]
	if buyOrder == nil then
		return false, "unknown_buy_order"
	end
	if sellOrder == nil then
		return false, "unknown_sell_order"
	end
	if sellOrder.itemsHeld < fill.quantity then
		return false, "seller_escrow_underflow"
	end

	local gross = fill.price * fill.quantity
	if buyOrder.creditsHeld < gross then
		return false, "buyer_escrow_underflow"
	end

	local buyer = Escrow.account(state, buyOrder.pid)
	local seller = Escrow.account(state, sellOrder.pid)

	-- Item: seller's escrow -> buyer's inventory.
	sellOrder.itemsHeld -= fill.quantity
	buyer.inventory[fill.itemId] = (buyer.inventory[fill.itemId] or 0) + fill.quantity

	-- Credits: buyer's escrow -> seller, minus the fee sink.
	buyOrder.creditsHeld -= gross
	seller.credits += gross - fill.fee
	state.feesCollected += fill.fee

	-- Price improvement: the buyer escrowed at their own limit price. If the
	-- resting sell was cheaper they pay less, and the surplus is theirs.
	-- Refunding per fill rather than at cancel keeps `creditsHeld` equal to
	-- the true remaining exposure, which is what makes the cancel path exact.
	local improvementPerUnit = buyOrder.price - fill.price
	if improvementPerUnit > 0 then
		local refund = improvementPerUnit * fill.quantity
		buyOrder.creditsHeld -= refund
		buyer.credits += refund
	end

	buyOrder.filled += fill.quantity
	sellOrder.filled += fill.quantity
	buyer.dailyVolume += gross
	seller.dailyVolume += gross

	-- A fully settled order holds nothing and is done; leaving it in the map
	-- would let `cancel` be called on it and refund a second time.
	if buyOrder.filled >= buyOrder.quantity then
		state.orders[fill.buyOrderId] = nil
	end
	if sellOrder.filled >= sellOrder.quantity then
		state.orders[fill.sellOrderId] = nil
	end

	return true, nil
end

--- Total credits in the system: spendable plus escrowed plus fees collected.
--- Conservation checks compare this against its starting value.
function Escrow.totalCredits(state: EscrowState): number
	local total = state.feesCollected
	for _, account in state.accounts do
		total += account.credits
	end
	for _, order in state.orders do
		total += order.creditsHeld
	end
	return total
end

--- Total units of `itemId` in the system: inventories plus escrow.
function Escrow.totalItems(state: EscrowState, itemId: string): number
	local total = 0
	for _, account in state.accounts do
		total += account.inventory[itemId] or 0
	end
	for _, order in state.orders do
		if order.itemId == itemId then
			total += order.itemsHeld
		end
	end
	return total
end

return Escrow
