--!nonstrict
--[[
	MenuUI
	The shop / garage / job board window. The server decides what is in the list
	and re-checks every purchase, so this file is presentation only.
]]

local ContextActionService = game:GetService("ContextActionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local ClientState = require(script.Parent.ClientState)
local UiKit = require(script.Parent.UiKit)

local MenuUI = {}

local PURCHASE_KIND = {
	GunShop = "weapon",
	Dealership = "vehicle",
	Garage = "garage",
	MissionBoard = "mission",
}

local screen: ScreenGui
local window: Frame
local titleLabel: TextLabel
local list: ScrollingFrame
local open = false

local function clearList()
	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function priceText(price: number): string
	if price < 0 then
		return string.format("<font color='#7ed957'>+%s</font>", Util.money(-price))
	elseif price == 0 then
		return "Free"
	end
	return Util.money(price)
end

local function addRow(menuKind: string, item, order: number)
	local affordable = item.price <= 0 or (ClientState.get("cash") or 0) >= item.price

	local row = UiKit.new("Frame", {
		Name = item.id,
		Size = UDim2.new(1, -8, 0, 62),
		BackgroundColor3 = Color3.fromRGB(26, 28, 33),
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = list,
	}) :: Frame
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = row })

	UiKit.text({
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -160, 0, 20),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Text = item.name,
		Parent = row,
	})

	UiKit.text({
		Position = UDim2.fromOffset(14, 30),
		Size = UDim2.new(1, -160, 0, 18),
		TextSize = 13,
		TextColor3 = Config.UI.Muted,
		Text = item.detail or "",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	UiKit.text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -120, 0, 20),
		Size = UDim2.fromOffset(100, 22),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = affordable and Config.UI.Text or Config.UI.Health,
		Text = priceText(item.price),
		Parent = row,
	})

	local button = UiKit.button({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(96, 34),
		Text = item.label or "Buy",
		BackgroundColor3 = affordable and Config.UI.Accent or Color3.fromRGB(48, 50, 56),
		TextColor3 = affordable and Color3.fromRGB(20, 20, 22) or Config.UI.Muted,
		Parent = row,
	})

	button.Activated:Connect(function()
		local kind = PURCHASE_KIND[menuKind]
		if not kind then
			return
		end
		if kind == "mission" then
			Net.event("MissionRequest"):FireServer("start", item.id)
			MenuUI.close()
		else
			Net.event("Purchase"):FireServer(kind, item.id)
			if kind == "garage" or kind == "vehicle" then
				MenuUI.close()
			end
		end
	end)
end

function MenuUI.show(menu)
	if type(menu) ~= "table" or type(menu.items) ~= "table" then
		return
	end

	titleLabel.Text = menu.title or "Shop"
	clearList()

	for index, item in menu.items do
		addRow(menu.kind, item, index)
	end
	list.CanvasSize = UDim2.fromOffset(0, #menu.items * 68 + 8)

	open = true
	screen.Enabled = true
	window.Visible = true
end

function MenuUI.close()
	open = false
	window.Visible = false
	screen.Enabled = false
	-- Clearing server-side state means re-using the pad reopens a fresh menu.
	ClientState.merge({ menu = false })
end

function MenuUI.isOpen(): boolean
	return open
end

function MenuUI.start()
	screen = UiKit.screen("ViceMenu", 30)
	screen.Enabled = false

	local dim = UiKit.new("Frame", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = screen,
	})

	window = UiKit.panel({
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 460),
		BackgroundTransparency = 0.02,
		Visible = false,
		Parent = dim,
	})

	titleLabel = UiKit.text({
		Position = UDim2.fromOffset(24, 18),
		Size = UDim2.new(1, -120, 0, 30),
		Font = Enum.Font.GothamBold,
		TextSize = 24,
		Text = "Shop",
		Parent = window,
	})

	local close = UiKit.button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 18),
		Size = UDim2.fromOffset(76, 30),
		Text = "Close",
		Parent = window,
	})
	close.Activated:Connect(MenuUI.close)

	list = UiKit.new("ScrollingFrame", {
		Name = "Items",
		Position = UDim2.fromOffset(20, 62),
		Size = UDim2.new(1, -40, 1, -82),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Config.UI.Muted,
		CanvasSize = UDim2.fromOffset(0, 0),
		Parent = window,
	}) :: ScrollingFrame

	UiKit.new("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})

	ClientState.onChange("menu", function(value)
		if type(value) == "table" then
			MenuUI.show(value)
		end
	end)

	ContextActionService:BindAction("ViceCloseMenu", function(_, inputState)
		if inputState == Enum.UserInputState.Begin and open then
			MenuUI.close()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)
end

return MenuUI
