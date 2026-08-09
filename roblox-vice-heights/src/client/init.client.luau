--!nonstrict
--[[
	Vice Heights - client bootstrap

	Pulls the initial state snapshot, then starts each front-end module. Every
	module is independent: they all read ClientState and none of them talk to
	each other except through the two explicit hand-offs at the bottom.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local CameraController = require(script.CameraController)
local ClientState = require(script.ClientState)
local Effects = require(script.Effects)
local HUD = require(script.HUD)
local MenuUI = require(script.MenuUI)
local Minimap = require(script.Minimap)
local Notifier = require(script.Notifier)
local VehicleController = require(script.VehicleController)
local WeaponController = require(script.WeaponController)

local player = Players.LocalPlayer

-- Patches can arrive before the snapshot resolves, so listen first and merge
-- the snapshot underneath whatever has already landed.
local pending: { { [string]: any } } = {}
local ready = false

Net.event("State").OnClientEvent:Connect(function(patch)
	if ready then
		ClientState.merge(patch)
	else
		table.insert(pending, patch)
	end
end)

local BOOT = {
	{ "Notifier", Notifier.start },
	{ "HUD", HUD.start },
	{ "Minimap", Minimap.start },
	{ "MenuUI", MenuUI.start },
	{ "Effects", Effects.start },
	{ "CameraController", CameraController.start },
	{ "WeaponController", WeaponController.start },
	{ "VehicleController", VehicleController.start },
}

for _, entry in BOOT do
	local ok, err = pcall(entry[2])
	if not ok then
		warn(string.format("[ViceHeights] client %s failed to start: %s", entry[1], tostring(err)))
	end
end

-- Driving swaps the camera subject to the car and back again.
VehicleController.onDriverChanged(function(model)
	CameraController.setVehicle(model)
end)

local ok, snapshot = pcall(function()
	return Net.fn("Fetch"):InvokeServer()
end)

if ok and type(snapshot) == "table" then
	ClientState.merge(snapshot)
else
	warn("[ViceHeights] initial state fetch failed; running on defaults")
end

ready = true
for _, patch in pending do
	ClientState.merge(patch)
end
table.clear(pending)

print(string.format("[ViceHeights] %s client ready for %s", Config.Game.Name, player.Name))
