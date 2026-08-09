--!nonstrict
--[[
	Effects
	Purely local world effects: bullet tracers and muzzle flashes. Nothing here
	is authoritative, and none of it is replicated — every client draws its own.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local Effects = {}

local folder: Folder

local TRACER_COLORS = {
	police = Color3.fromRGB(120, 180, 255),
	default = Color3.fromRGB(255, 226, 150),
}

function Effects.tracer(from: Vector3, to: Vector3, weapon: string?)
	local delta = to - from
	local distance = delta.Magnitude
	if distance < 1 or distance > 2000 then
		return
	end

	local beam = Util.part({
		Name = "Tracer",
		Size = Vector3.new(0.12, 0.12, distance),
		CFrame = CFrame.lookAt(from + delta / 2, to),
		Color = TRACER_COLORS[weapon or "default"] or TRACER_COLORS.default,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 0.25,
		Parent = folder,
	})

	TweenService:Create(beam, TweenInfo.new(0.09), { Transparency = 1 }):Play()
	Debris:AddItem(beam, 0.12)
end

function Effects.muzzleFlash(position: Vector3)
	local flash = Util.part({
		Name = "Muzzle",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.9, 0.9, 0.9),
		CFrame = CFrame.new(position),
		Color = Color3.fromRGB(255, 224, 150),
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = folder,
	})

	local light = Instance.new("PointLight")
	light.Brightness = 4
	light.Range = 14
	light.Color = Color3.fromRGB(255, 214, 140)
	light.Parent = flash

	TweenService:Create(flash, TweenInfo.new(0.07), {
		Transparency = 1,
		Size = Vector3.new(1.8, 1.8, 1.8),
	}):Play()
	Debris:AddItem(flash, 0.09)
end

function Effects.impact(position: Vector3, normal: Vector3)
	local mark = Util.part({
		Name = "Impact",
		Size = Vector3.new(0.35, 0.35, 0.05),
		CFrame = CFrame.lookAt(position + normal * 0.03, position + normal),
		Color = Color3.fromRGB(30, 30, 32),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 0.2,
		Parent = folder,
	})
	TweenService:Create(mark, TweenInfo.new(3, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	Debris:AddItem(mark, 3.2)
end

function Effects.start()
	folder = Instance.new("Folder")
	folder.Name = "ClientEffects"
	folder.Parent = Workspace

	Net.event("Effect").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if
			payload.kind == "tracer"
			and typeof(payload.from) == "Vector3"
			and typeof(payload.to) == "Vector3"
		then
			Effects.tracer(payload.from, payload.to, payload.weapon)
			Effects.muzzleFlash(payload.from)
		end
	end)
end

return Effects
