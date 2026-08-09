--!nonstrict
--[[
	UiKit
	Thin helpers for building the interface in code. Not a framework — just
	enough to keep the HUD modules readable.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local UiKit = {}

UiKit.Colors = Config.UI

--- `UiKit.new("TextLabel", { ... }, { child, child })`
function UiKit.new(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local instance = Instance.new(className)
	if props then
		for key, value in props do
			if key ~= "Parent" then
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if props and props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

function UiKit.screen(name: string, order: number): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild(name)
	if existing then
		return existing :: ScreenGui
	end
	return UiKit.new("ScreenGui", {
		Name = name,
		DisplayOrder = order,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	}) :: ScreenGui
end

function UiKit.panel(props: { [string]: any }): Frame
	local merged = {
		BackgroundColor3 = Config.UI.Panel,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}
	for key, value in props do
		merged[key] = value
	end
	local frame = UiKit.new("Frame", merged) :: Frame
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = frame })
	return frame
end

function UiKit.text(props: { [string]: any }): TextLabel
	local merged = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextColor3 = Config.UI.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 16,
		RichText = true,
	}
	for key, value in props do
		merged[key] = value
	end
	return UiKit.new("TextLabel", merged) :: TextLabel
end

function UiKit.button(props: { [string]: any }): TextButton
	local merged = {
		BackgroundColor3 = Color3.fromRGB(38, 40, 46),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextColor3 = Config.UI.Text,
		TextSize = 15,
		AutoButtonColor = true,
	}
	for key, value in props do
		merged[key] = value
	end
	local button = UiKit.new("TextButton", merged) :: TextButton
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = button })
	return button
end

--- A labelled progress bar (health, armour, robbery timers).
function UiKit.bar(color: Color3, props: { [string]: any }): (Frame, Frame)
	local track = UiKit.panel(props)
	track.BackgroundColor3 = Color3.fromRGB(12, 13, 16)
	track.BackgroundTransparency = 0.35

	local fill = UiKit.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = track,
	}) :: Frame
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = fill })

	return track, fill
end

return UiKit
