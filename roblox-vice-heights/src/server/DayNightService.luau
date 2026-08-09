--!nonstrict
--[[
	DayNightService
	Runs the clock and flips the city's lights. Street lamps and headlights come
	on at dusk, which is also when the place starts to look like the game it is
	imitating.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local VehicleFactory = require(script.Parent.VehicleFactory)

local DayNightService = {}

local D = Config.DayNight
local isNight = false

local function nightAt(clockTime: number): boolean
	return clockTime >= D.NightStart or clockTime < D.NightEnd
end

local function setStreetlights(on: boolean)
	for _, lamp in CollectionService:GetTagged("Streetlight") do
		local light = lamp:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = on
		end
		if lamp:IsA("BasePart") then
			lamp.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
		end
	end
end

local function setVehicleLights(on: boolean)
	for _, model in CollectionService:GetTagged("Vehicle") do
		if model:IsA("Model") then
			VehicleFactory.setLights(model, on)
		end
	end
end

local function applyNight(night: boolean)
	isNight = night
	Lighting.Brightness = night and 0.8 or 2.4
	Lighting.OutdoorAmbient = night and Color3.fromRGB(48, 52, 72) or Color3.fromRGB(108, 110, 128)
	Lighting.FogColor = night and Color3.fromRGB(24, 26, 38) or Color3.fromRGB(174, 184, 202)
	Lighting.FogEnd = night and 1400 or 2600
	setStreetlights(night)
	setVehicleLights(night)
end

function DayNightService.isNight(): boolean
	return isNight
end

function DayNightService.start()
	if not D.Enabled then
		Lighting.ClockTime = D.StartClockTime
		return
	end

	Lighting.ClockTime = D.StartClockTime
	applyNight(nightAt(D.StartClockTime))

	-- 24 in-game hours per D.MinutesPerDay real minutes.
	local hoursPerSecond = 24 / (D.MinutesPerDay * 60)
	local sinceLightCheck = 0

	RunService.Heartbeat:Connect(function(dt)
		Lighting.ClockTime = (Lighting.ClockTime + hoursPerSecond * dt) % 24

		sinceLightCheck += dt
		if sinceLightCheck < 5 then
			return
		end
		sinceLightCheck = 0

		local night = nightAt(Lighting.ClockTime)
		if night ~= isNight then
			applyNight(night)
		elseif night then
			-- Cars that spawned after dusk still need their lights turned on.
			setVehicleLights(true)
		end
	end)
end

return DayNightService
