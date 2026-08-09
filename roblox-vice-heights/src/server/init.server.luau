--!nonstrict
--[[
	Vice Heights - server bootstrap

	Boot order matters:
	  1. remotes exist before anything can fire them
	  2. the city exists before anything tries to spawn onto it
	  3. DataService is up before PlayerService starts loading profiles
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local DataService = require(script.DataService)
local DayNightService = require(script.DayNightService)
local MissionService = require(script.MissionService)
local PedService = require(script.PedService)
local PlayerService = require(script.PlayerService)
local PoliceService = require(script.PoliceService)
local ShopService = require(script.ShopService)
local VehicleService = require(script.VehicleService)
local WantedService = require(script.WantedService)
local WeaponService = require(script.WeaponService)
local WorldBuilder = require(script.WorldBuilder)

local started = os.clock()

Net.init()
WorldBuilder.build()

local BOOT = {
	{ "DataService", DataService.start },
	{ "WantedService", WantedService.start },
	{ "WeaponService", WeaponService.start },
	{ "VehicleService", VehicleService.start },
	{ "PlayerService", PlayerService.start },
	{ "PedService", PedService.start },
	{ "PoliceService", PoliceService.start },
	{ "MissionService", MissionService.init },
	{ "ShopService", ShopService.start },
	{ "DayNightService", DayNightService.start },
}

for _, entry in BOOT do
	local name, fn = entry[1], entry[2]
	local ok, err = pcall(fn)
	if not ok then
		-- One broken service should not take the whole server down with it.
		warn(string.format("[ViceHeights] %s failed to start: %s", name, tostring(err)))
	end
end

print(
	string.format(
		"[ViceHeights] %s v%s online in %.2fs",
		Config.Game.Name,
		Config.Game.Version,
		os.clock() - started
	)
)
