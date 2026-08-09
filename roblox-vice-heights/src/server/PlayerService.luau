--!nonstrict
--[[
	PlayerService
	Join/leave, character setup, and the two ways a criminal career ends:
	wasted (hospital bill) and busted (the cops take a cut and your freedom).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CityGrid = require(Shared.CityGrid)
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local Combat = require(script.Parent.Combat)
local DataService = require(script.Parent.DataService)
local WantedService = require(script.Parent.WantedService)
local WeaponService = require(script.Parent.WeaponService)

local PlayerService = {}

local pendingSpawn: { [Player]: Vector3 } = {}
local respawnListeners: { (Player, Model) -> () } = {}

function PlayerService.onSpawn(fn)
	table.insert(respawnListeners, fn)
end

local function landmarkSpawn(name: string): Vector3
	local position = CityGrid.landmarkPosition(name)
	if not position then
		return Vector3.new(0, Config.City.GroundY + 6, 0)
	end
	-- Step out onto the pavement in front of the building.
	return position + Vector3.new(0, Config.City.GroundY + 6, -(Config.City.BlockSize * 0.5 + 14))
end

--------------------------------------------------------------------------------
-- Character
--------------------------------------------------------------------------------

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	humanoid.MaxHealth = Config.Combat.MaxHealth
	humanoid.Health = Config.Combat.MaxHealth
	Combat.setArmor(character, 0)
	character:SetAttribute("LastAttackerUserId", 0)

	-- Roblox re-parents the backpack on respawn, so rebuild the loadout here.
	task.defer(function()
		WeaponService.refreshLoadout(player)
		DataService.push(player, { armor = 0, health = humanoid.Health })
	end)

	local target = pendingSpawn[player]
	if target then
		pendingSpawn[player] = nil
		task.defer(function()
			if character.Parent then
				character:PivotTo(CFrame.new(target))
			end
		end)
	end

	humanoid.HealthChanged:Connect(function(health)
		DataService.push(player, { health = health })
	end)

	humanoid.Died:Connect(function()
		PlayerService.onDeath(player, character)
	end)

	for _, listener in respawnListeners do
		task.spawn(listener, player, character)
	end
end

function PlayerService.onDeath(player: Player, character: Model)
	DataService.bumpStat(player, "deaths", 1)

	local profile = DataService.get(player)
	if profile then
		local fee =
			math.min(profile.cash * Config.Economy.HospitalFee.Percent, Config.Economy.HospitalFee.Max)
		fee = math.floor(fee)
		if fee > 0 then
			DataService.addCash(player, -fee, "medical bill")
		end
	end

	WantedService.clear(player)
	pendingSpawn[player] = landmarkSpawn("Hospital")
	DataService.notify(player, "WASTED", "bad")
end

--- Called by the police once they have a wanted player cornered.
function PlayerService.bust(player: Player)
	local character = player.Character
	if not character or not Util.isAlive(character) then
		return
	end

	local profile = DataService.get(player)
	if profile then
		local fee = math.min(profile.cash * Config.Economy.BustedFee.Percent, Config.Economy.BustedFee.Max)
		fee = math.floor(fee)
		if fee > 0 then
			DataService.addCash(player, -fee, "bail and impound")
		end
	end

	DataService.bumpStat(player, "busted", 1)
	WantedService.clear(player)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = humanoid.MaxHealth
	end
	Combat.setArmor(character, 0)
	character:PivotTo(CFrame.new(landmarkSpawn("PoliceStation")))

	DataService.notify(player, "BUSTED", "bad")
	DataService.push(player, { armor = 0 })
end

--- Voluntary surrender at the precinct: cheaper than being taken in.
function PlayerService.surrender(player: Player)
	if not WantedService.isWanted(player) then
		DataService.notify(player, "Nothing to surrender for.", "info")
		return
	end
	local profile = DataService.get(player)
	if profile then
		local fee = math.floor(math.min(profile.cash * 0.1, 4000))
		if fee > 0 then
			DataService.addCash(player, -fee, "fine")
		end
	end
	WantedService.clear(player)
	DataService.notify(player, "Charges settled. Stay out of trouble.", "good")
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function PlayerService.start()
	local function setup(player: Player)
		DataService.load(player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(setup)
	for _, player in Players:GetPlayers() do
		task.spawn(setup, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		pendingSpawn[player] = nil
		DataService.release(player)
	end)
end

return PlayerService
