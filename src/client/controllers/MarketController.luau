--!strict
--[[ M6-10. The market panel: order book, your open orders, and the controls
	to list, bid, and cancel.

	Displays only, like the HUD. Every number shown arrives from the server in
	a `MarketUpdate`, including the player's own balance and inventory —
	nothing here computes what a trade *would* cost and then trusts it, and
	nothing here decides whether an order is legal. The client asks; the
	server answers. A rejected order comes back with a reason code, which is
	rendered verbatim rather than second-guessed, because a UI that predicts
	rejection reasons will eventually disagree with the server about them.

	Built in code for the same reason the HUD is: the item list is driven off
	`config/Loot`, and a StarterGui tree would have to be kept in sync with it
	by hand.

	Toggled with M. Hidden by default: the market is a between-runs activity
	and a panel covering a third of the screen during a firefight is a
	liability.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Branding = require(Shared.config.Branding)
local LootConfig = require(Shared.config.Loot)
local Remotes = require(Shared.net.Remotes)

local MarketController = {}

type ItemSpec = { rarity: string, weight: number, baseValue: number, tradeable: boolean }

local player = Players.LocalPlayer
local gui: ScreenGui? = nil
local visible = false

--- Which item the panel is showing. Only tradeable items are selectable.
local tradeableIds: { string } = {}
local selectedIndex = 1

local refs: { [string]: any } = {}
local latest: { [string]: any }? = nil

local BG = Color3.fromRGB(16, 18, 22)
local PANEL = Color3.fromRGB(26, 29, 35)
local TEXT = Color3.fromRGB(224, 228, 235)
local DIM = Color3.fromRGB(140, 148, 160)
local BID = Color3.fromRGB(120, 200, 140)
local ASK = Color3.fromRGB(220, 130, 120)
local ACCENT = Color3.fromRGB(240, 196, 96)

local function collectTradeable()
	local items = LootConfig.items :: { [string]: ItemSpec }
	local ids: { string } = {}
	for itemId, spec in items do
		if spec.tradeable then
			table.insert(ids, itemId)
		end
	end
	table.sort(ids)
	tradeableIds = ids
end

local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3?, align: Enum.TextXAlignment?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = Enum.Font.Code
	l.TextSize = 14
	l.TextColor3 = color or TEXT
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = PANEL
	b.BorderSizePixel = 0
	b.Font = Enum.Font.Code
	b.TextSize = 14
	b.TextColor3 = color
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b
	return b
end

local function numberBox(parent: Instance, placeholder: string, size: UDim2, pos: UDim2): TextBox
	local box = Instance.new("TextBox")
	box.Size = size
	box.Position = pos
	box.BackgroundColor3 = PANEL
	box.BorderSizePixel = 0
	box.Font = Enum.Font.Code
	box.TextSize = 14
	box.TextColor3 = TEXT
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = DIM
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = box
	return box
end

local function selectedItem(): string
	return tradeableIds[selectedIndex] or ""
end

local function requestRefresh()
	Remotes.event("MarketRequest"):FireServer({ action = "refresh", itemId = selectedItem() })
end

--- Parse a box as a positive integer. Prices and quantities are whole
--- credits and whole items server-side; sending a float just earns a
--- rejection round trip, so it is caught here as a courtesy -- the server
--- still validates independently.
local function readPositiveInt(box: TextBox): number?
	local value = tonumber(box.Text)
	if value == nil or value ~= math.floor(value) or value <= 0 then
		return nil
	end
	return value
end

local function submit(side: string)
	local price = readPositiveInt(refs.priceBox)
	local quantity = readPositiveInt(refs.qtyBox)
	if price == nil or quantity == nil then
		refs.status.Text = "price and quantity must be whole numbers above zero"
		refs.status.TextColor3 = ASK
		return
	end
	Remotes.event("MarketRequest"):FireServer({
		action = "place",
		itemId = selectedItem(),
		side = side,
		price = price,
		quantity = quantity,
	})
end

local function render()
	local data = latest
	if data == nil or gui == nil then
		return
	end

	local itemId = tostring(data.itemId)
	refs.itemName.Text = itemId
	refs.credits.Text = `credits {data.credits or 0}`
	refs.holdings.Text = `holding {data.inventory or 0}`
	refs.vwap.Text = if data.vwap then `ref {math.floor(data.vwap)}  band +/-{math.floor((data.priceBand or 0) * 100)}%` else "no reference price"

	local bidLines: { string } = {}
	for i, entry in (data.bids or {}) :: { any } do
		if i > 6 then
			break
		end
		table.insert(bidLines, string.format("%6d  x%d", entry.price, entry.remaining))
	end
	local askLines: { string } = {}
	for i, entry in (data.asks or {}) :: { any } do
		if i > 6 then
			break
		end
		table.insert(askLines, string.format("%6d  x%d", entry.price, entry.remaining))
	end
	refs.bids.Text = if #bidLines > 0 then table.concat(bidLines, "\n") else "  (none)"
	refs.asks.Text = if #askLines > 0 then table.concat(askLines, "\n") else "  (none)"

	for _, child in refs.ordersList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local y = 0
	for _, order in (data.myOrders or {}) :: { any } do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 20)
		row.Position = UDim2.new(0, 0, 0, y)
		row.Parent = refs.ordersList
		local remaining = order.quantity - order.filled
		label(
			row,
			string.format("%s %s %d x%d", order.side == "buy" and "BID" or "ASK", order.itemId, order.price, remaining),
			UDim2.new(1, -70, 1, 0),
			UDim2.new(0, 0, 0, 0),
			if order.side == "buy" then BID else ASK
		)
		local cancelBtn = button(row, "cancel", UDim2.new(0, 62, 0, 18), UDim2.new(1, -64, 0, 1), TEXT)
		local capturedId = order.orderId
		local capturedItem = order.itemId
		cancelBtn.Activated:Connect(function()
			Remotes.event("MarketRequest"):FireServer({
				action = "cancel",
				orderId = capturedId,
				itemId = capturedItem,
			})
		end)
		y += 22
	end
	refs.ordersList.CanvasSize = UDim2.new(0, 0, 0, y)

	local status = data.status
	if status == "rejected" then
		refs.status.Text = `rejected: {tostring(data.reason)}`
		refs.status.TextColor3 = ASK
	elseif status == "filled" then
		refs.status.Text = "an order of yours filled"
		refs.status.TextColor3 = BID
	elseif status == "placed" then
		refs.status.Text = "order placed"
		refs.status.TextColor3 = BID
	elseif status == "cancelled" then
		refs.status.Text = "order cancelled, escrow returned"
		refs.status.TextColor3 = TEXT
	end
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "DeepcacheMarket"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Size = UDim2.new(0, 520, 0, 400)
	root.Position = UDim2.new(0.5, -260, 0.5, -200)
	root.BackgroundColor3 = BG
	root.BorderSizePixel = 0
	root.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = root

	label(root, `{Branding.gameName} MARKET`, UDim2.new(1, -20, 0, 22), UDim2.new(0, 12, 0, 8), ACCENT)
	label(root, "[M] close", UDim2.new(0, 100, 0, 22), UDim2.new(1, -108, 0, 8), DIM, Enum.TextXAlignment.Right)

	refs.itemName = label(root, "", UDim2.new(0, 220, 0, 20), UDim2.new(0, 12, 0, 36), TEXT)
	refs.vwap = label(root, "", UDim2.new(0, 260, 0, 20), UDim2.new(0, 12, 0, 54), DIM)
	refs.credits = label(root, "", UDim2.new(0, 140, 0, 20), UDim2.new(1, -152, 0, 36), ACCENT, Enum.TextXAlignment.Right)
	refs.holdings = label(root, "", UDim2.new(0, 140, 0, 20), UDim2.new(1, -152, 0, 54), DIM, Enum.TextXAlignment.Right)

	local prev = button(root, "<", UDim2.new(0, 26, 0, 22), UDim2.new(0, 240, 0, 35), TEXT)
	local nxt = button(root, ">", UDim2.new(0, 26, 0, 22), UDim2.new(0, 270, 0, 35), TEXT)
	prev.Activated:Connect(function()
		selectedIndex = if selectedIndex <= 1 then #tradeableIds else selectedIndex - 1
		requestRefresh()
	end)
	nxt.Activated:Connect(function()
		selectedIndex = if selectedIndex >= #tradeableIds then 1 else selectedIndex + 1
		requestRefresh()
	end)

	label(root, "BIDS", UDim2.new(0, 120, 0, 18), UDim2.new(0, 12, 0, 84), BID)
	label(root, "ASKS", UDim2.new(0, 120, 0, 18), UDim2.new(0, 150, 0, 84), ASK)
	refs.bids = label(root, "", UDim2.new(0, 130, 0, 110), UDim2.new(0, 12, 0, 102), BID)
	refs.bids.TextYAlignment = Enum.TextYAlignment.Top
	refs.asks = label(root, "", UDim2.new(0, 130, 0, 110), UDim2.new(0, 150, 0, 102), ASK)
	refs.asks.TextYAlignment = Enum.TextYAlignment.Top

	label(root, "YOUR ORDERS", UDim2.new(0, 200, 0, 18), UDim2.new(0, 296, 0, 84), TEXT)
	local orders = Instance.new("ScrollingFrame")
	orders.Size = UDim2.new(0, 212, 0, 130)
	orders.Position = UDim2.new(0, 296, 0, 102)
	orders.BackgroundTransparency = 1
	orders.BorderSizePixel = 0
	orders.ScrollBarThickness = 4
	orders.CanvasSize = UDim2.new(0, 0, 0, 0)
	orders.Parent = root
	refs.ordersList = orders

	refs.priceBox = numberBox(root, "price", UDim2.new(0, 92, 0, 26), UDim2.new(0, 12, 0, 250))
	refs.qtyBox = numberBox(root, "qty", UDim2.new(0, 66, 0, 26), UDim2.new(0, 110, 0, 250))
	local bidBtn = button(root, "PLACE BID", UDim2.new(0, 110, 0, 26), UDim2.new(0, 184, 0, 250), BID)
	local askBtn = button(root, "LIST FOR SALE", UDim2.new(0, 130, 0, 26), UDim2.new(0, 300, 0, 250), ASK)
	bidBtn.Activated:Connect(function()
		submit("buy")
	end)
	askBtn.Activated:Connect(function()
		submit("sell")
	end)

	refs.status = label(root, "", UDim2.new(1, -24, 0, 20), UDim2.new(0, 12, 0, 286), DIM)
	label(
		root,
		"fee 5% on every fill, paid by the seller. escrow moves when the order is placed.",
		UDim2.new(1, -24, 0, 34),
		UDim2.new(0, 12, 0, 310),
		DIM
	).TextWrapped = true

	gui = screen
end

function MarketController.toggle()
	visible = not visible
	if gui then
		gui.Enabled = visible
	end
	if visible then
		requestRefresh()
	end
end

function MarketController.isVisible(): boolean
	return visible
end

function MarketController.start()
	collectTradeable()
	build()

	Remotes.event("MarketUpdate").OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		latest = payload
		render()
	end)

	ContextActionService:BindAction("DeepcacheToggleMarket", function(_, state)
		if state == Enum.UserInputState.Begin then
			MarketController.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.M)
end

return MarketController
