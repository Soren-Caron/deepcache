--!strict
--[[ M6-10. Server side of the market: owns the book and the escrow, and is
	the only thing that decides whether an order is legal.

	The client sends intent and nothing else. Every price, quantity, item id
	and side is re-validated here against `Market.validate` (band, self-trade,
	integral price) and `Escrow` (do they actually hold it, are they inside
	the abuse caps). CLAUDE.md's rule -- never trust the client for currency
	or loot contents -- is the whole design of this file: the request carries
	no balances, no inventory, and no order ids the server did not issue.

	Order ids are minted server-side and namespaced by player, so a client
	cannot cancel someone else's order by guessing an id, and cannot collide
	with one by reusing a value. `cancel` re-checks ownership anyway, because
	an id being unguessable is not the same as it being unforgeable.

	`overseer_shard` is `tradeable = false` in config/Loot: prototype-tier
	items are deliberately outside the economy, and the check lives here
	rather than in the UI because a UI check is a suggestion.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local EconomyConfig = require(Shared.config.Economy)
local Escrow = require(Shared.core.economy.Escrow)
local LootConfig = require(Shared.config.Loot)
local Market = require(Shared.core.economy.Market)
local Remotes = require(Shared.net.Remotes)

local MarketService = {}

type ItemSpec = { rarity: string, weight: number, baseValue: number, tradeable: boolean }

local CAPS: Escrow.Caps = {
	maxOpenOrdersPerItem = EconomyConfig.market.maxOpenOrdersPerItem,
	dailyTradeVolumeCap = EconomyConfig.market.dailyTradeVolumeCap,
	minRunsToSell = EconomyConfig.market.minRunsToSell,
}

local escrow = Escrow.new()
local book = Market.new()
local nextOrderSeq = 0
local metrics = { placed = 0, filled = 0, cancelled = 0, rejected = 0 }

--- Stable pseudonymous key for a player. The market is per-server state in
--- M6; persisting it across servers is M6-11's deployed-backend problem.
local function keyFor(player: Player): string
	return tostring(player.UserId)
end

local function itemSpec(itemId: unknown): ItemSpec?
	if type(itemId) ~= "string" then
		return nil
	end
	local items = LootConfig.items :: { [string]: ItemSpec }
	return items[itemId]
end

--- Seed the 7-day VWAP from base values until real trade telemetry exists.
--- Without a reference price the band check cannot run at all (Market treats
--- a missing vwap as cold-start and skips it), so every item starts anchored
--- to what the loot table already says it is worth.
local function seedVwap()
	local items = LootConfig.items :: { [string]: ItemSpec }
	for itemId, spec in items do
		if spec.tradeable then
			book.vwap7d[itemId] = spec.baseValue
		end
	end
end

function MarketService.setVwap(itemId: string, value: number)
	book.vwap7d[itemId] = value
end

--- Everything the client needs to render the market for one item.
local function snapshotFor(player: Player, itemId: string): { [string]: any }
	local pid = keyFor(player)
	local bids: { any }, asks: { any } = {}, {}

	for _, order in book.bids do
		if order.itemId == itemId and order.filled < order.quantity then
			table.insert(bids, { price = order.price, remaining = order.quantity - order.filled })
		end
	end
	for _, order in book.asks do
		if order.itemId == itemId and order.filled < order.quantity then
			table.insert(asks, { price = order.price, remaining = order.quantity - order.filled })
		end
	end
	-- Best price first, matching how the engine matches.
	table.sort(bids, function(a, b)
		return a.price > b.price
	end)
	table.sort(asks, function(a, b)
		return a.price < b.price
	end)

	local mine: { any } = {}
	for orderId, order in escrow.orders do
		if order.pid == pid then
			table.insert(mine, {
				orderId = orderId,
				itemId = order.itemId,
				side = order.side,
				price = order.price,
				quantity = order.quantity,
				filled = order.filled,
			})
		end
	end
	table.sort(mine, function(a, b)
		return a.orderId < b.orderId
	end)

	local account = Escrow.account(escrow, pid)
	return {
		itemId = itemId,
		bids = bids,
		asks = asks,
		myOrders = mine,
		credits = account.credits,
		inventory = account.inventory[itemId] or 0,
		vwap = book.vwap7d[itemId],
		feeRate = Market.FEE_RATE,
		priceBand = Market.PRICE_BAND,
	}
end

local function push(player: Player, itemId: string, status: string?, reason: string?)
	local payload = snapshotFor(player, itemId)
	payload.status = status
	payload.reason = reason
	Remotes.event("MarketUpdate"):FireClient(player, payload)
end

--- Place an order. Returns (ok, reason) rather than throwing, per CLAUDE.md:
--- a validation failure is an expected outcome, not programmer error.
function MarketService.place(
	player: Player,
	itemId: unknown,
	side: unknown,
	price: unknown,
	quantity: unknown
): (boolean, string?)
	-- Every early return counts as a rejection too. Counting only the ones
	-- that reach Market.validate made `rejected` quietly mean "rejected late",
	-- which is a metric nobody would read correctly.
	local function reject(reason: string): (boolean, string)
		metrics.rejected += 1
		return false, reason
	end

	local spec = itemSpec(itemId)
	if spec == nil then
		return reject("unknown_item")
	end
	if not spec.tradeable then
		return reject("item_not_tradeable")
	end
	if side ~= "buy" and side ~= "sell" then
		return reject("bad_side")
	end
	if type(price) ~= "number" or type(quantity) ~= "number" then
		return reject("bad_numbers")
	end

	local id = itemId :: string
	local pid = keyFor(player)
	nextOrderSeq += 1
	local orderId = `{pid}:{nextOrderSeq}`

	local incoming: Market.Order = {
		id = orderId,
		pid = pid,
		itemId = id,
		side = side :: Market.Side,
		price = price,
		quantity = quantity,
		filled = 0,
		ts = nextOrderSeq,
	}

	-- Book-level legality first (band, self-trade, integral price), then
	-- escrow-level (do they hold it, are they inside the caps). Order matters
	-- only for which reason the player sees; neither is skippable.
	local legal, bookReason = Market.validate(book, incoming)
	if not legal then
		return reject(bookReason or "rejected")
	end

	local reserved = if incoming.side == "sell"
		then Escrow.placeSell(escrow, orderId, pid, id, price, quantity, CAPS)
		else Escrow.placeBuy(escrow, orderId, pid, id, price, quantity, CAPS)
	if not reserved.ok then
		return reject(reserved.reason or "rejected")
	end

	local newBook, fills = Market.match(book, incoming)
	book = newBook
	metrics.placed += 1

	for _, fill in fills do
		local settled = Escrow.settle(escrow, fill)
		if settled then
			metrics.filled += 1
		end
	end

	-- Both sides of a fill need their UI refreshed, not just the taker.
	push(player, id, "placed")
	for _, fill in fills do
		for _, other in Players:GetPlayers() do
			if keyFor(other) == fill.buyerPid or keyFor(other) == fill.sellerPid then
				if other ~= player then
					push(other, id, "filled")
				end
			end
		end
	end
	return true, nil
end

function MarketService.cancel(player: Player, orderId: unknown): (boolean, string?)
	if type(orderId) ~= "string" then
		metrics.rejected += 1
		return false, "bad_order_id"
	end
	local order = escrow.orders[orderId]
	if order == nil then
		metrics.rejected += 1
		return false, "unknown_order"
	end
	-- Ownership re-check: an unguessable id is not an unforgeable one.
	if order.pid ~= keyFor(player) then
		metrics.rejected += 1
		return false, "not_your_order"
	end

	local itemId = order.itemId
	local ok, reason = Escrow.cancel(escrow, orderId)
	if not ok then
		return false, reason
	end
	Market.cancel(book, orderId)
	metrics.cancelled += 1
	push(player, itemId, "cancelled")
	return true, nil
end

--- Grant items/credits into the market account. This is the seam the run
--- loop uses when a player extracts; exposed for diagnostics too.
function MarketService.credit(player: Player, credits: number, items: { [string]: number }?)
	local account = Escrow.account(escrow, keyFor(player))
	account.credits += math.max(0, math.floor(credits))
	if items ~= nil then
		for itemId, count in items do
			account.inventory[itemId] = (account.inventory[itemId] or 0) + count
		end
	end
end

function MarketService.setRunsPlayed(player: Player, runs: number)
	Escrow.account(escrow, keyFor(player)).runsPlayed = runs
end

function MarketService.init()
	seedVwap()
	Remotes.event("MarketRequest").OnServerEvent:Connect(function(player: Player, payload: any)
		if type(payload) ~= "table" then
			return
		end
		local action = payload.action
		if action == "place" then
			local ok, reason = MarketService.place(player, payload.itemId, payload.side, payload.price, payload.quantity)
			if not ok then
				push(player, if type(payload.itemId) == "string" then payload.itemId else "", "rejected", reason)
			end
		elseif action == "cancel" then
			local ok, reason = MarketService.cancel(player, payload.orderId)
			if not ok then
				push(player, if type(payload.itemId) == "string" then payload.itemId else "", "rejected", reason)
			end
		elseif action == "refresh" then
			local itemId = payload.itemId
			if type(itemId) == "string" then
				push(player, itemId, "refreshed")
			end
		end
	end)
end

function MarketService.describe(): { [string]: any }
	local openOrders = 0
	for _ in escrow.orders do
		openOrders += 1
	end
	return {
		placed = metrics.placed,
		filled = metrics.filled,
		cancelled = metrics.cancelled,
		rejected = metrics.rejected,
		openOrders = openOrders,
		feesCollected = escrow.feesCollected,
	}
end

--- Diagnostics/testing: the underlying state, for conservation checks.
function MarketService.state(): (Escrow.EscrowState, Market.OrderBook)
	return escrow, book
end

function MarketService.reset()
	escrow = Escrow.new()
	book = Market.new()
	nextOrderSeq = 0
	metrics = { placed = 0, filled = 0, cancelled = 0, rejected = 0 }
	seedVwap()
end

return MarketService
