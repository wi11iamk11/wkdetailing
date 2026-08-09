--!nonstrict
--[[
	Notifier
	Toast messages. The server sends {text, style}; big story beats like WASTED
	and BUSTED get the full-screen treatment instead of a toast.
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local UiKit = require(script.Parent.UiKit)

local Notifier = {}

local STYLES = {
	info = Config.UI.Text,
	good = Config.UI.Cash,
	warn = Config.UI.Accent,
	cash = Config.UI.Cash,
	wanted = Config.UI.Accent,
	bad = Config.UI.Health,
}

local BANNERS = {
	WASTED = Color3.fromRGB(196, 48, 48),
	BUSTED = Color3.fromRGB(72, 132, 220),
}

local stack: Frame
local banner: TextLabel

local function toast(text: string, style: string)
	local color = STYLES[style] or Config.UI.Text

	local frame = UiKit.panel({
		Size = UDim2.fromOffset(320, 34),
		BackgroundTransparency = 0.15,
		Parent = stack,
	})

	local stripe = UiKit.new("Frame", {
		Size = UDim2.fromOffset(4, 34),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = frame,
	})
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 2), Parent = stripe })

	UiKit.text({
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -22, 1, 0),
		TextSize = 15,
		TextColor3 = color,
		Text = text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})

	frame.BackgroundTransparency = 1
	TweenService:Create(frame, TweenInfo.new(0.18), { BackgroundTransparency = 0.15 }):Play()

	task.delay(4.5, function()
		if not frame.Parent then
			return
		end
		local fade = TweenService:Create(frame, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		frame:Destroy()
	end)
end

local function showBanner(text: string)
	banner.Text = text
	banner.TextColor3 = BANNERS[text] or Config.UI.Text
	banner.TextTransparency = 1
	banner.Visible = true

	TweenService:Create(banner, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
	task.delay(2.8, function()
		local fade = TweenService:Create(banner, TweenInfo.new(0.8), { TextTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		banner.Visible = false
	end)
end

function Notifier.push(text: string, style: string?)
	if BANNERS[text] then
		showBanner(text)
	else
		toast(text, style or "info")
	end
end

function Notifier.start()
	local screen = UiKit.screen("ViceNotifications", 20)

	stack = UiKit.new("Frame", {
		Name = "Stack",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -110),
		Size = UDim2.fromOffset(320, 220),
		BackgroundTransparency = 1,
		Parent = screen,
	}) :: Frame

	UiKit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stack,
	})

	banner = UiKit.text({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(600, 90),
		Font = Enum.Font.GothamBlack,
		TextSize = 76,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		Visible = false,
		Text = "",
		Parent = screen,
	})

	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and type(payload.text) == "string" then
			Notifier.push(payload.text, payload.style)
		end
	end)
end

return Notifier
