--!nonstrict
--[[
	DataService
	Owns the player profile: cash, unlocked weapons, owned vehicles and mission
	history. Also the single place that pushes state to clients.

	Persistence degrades gracefully: if DataStores are unavailable (Studio
	without API access, or an outage) profiles live in memory for the session
	and the game keeps running.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)
local VehicleCatalog = require(Shared.VehicleCatalog)
local WeaponCatalog = require(Shared.WeaponCatalog)

local DataService = {}

local profiles: { [Player]: any } = {}
local providers: { (Player) -> { [string]: any } } = {}
local store: DataStore? = nil
local persistent = false

local function defaultProfile()
	local weapons = {}
	for _, id in WeaponCatalog.Starter do
		local def = WeaponCatalog.get(id)
		weapons[id] = { reserve = def and def.reserve or 0 }
	end

	local vehicles = {}
	vehicles[VehicleCatalog.StarterVehicle] = true

	return {
		version = 1,
		cash = Config.Economy.StartingCash,
		bank = Config.Economy.StartingBank,
		weapons = weapons,
		vehicles = vehicles,
		missions = {}, -- missionId -> completion count
		stats = {
			kills = 0,
			deaths = 0,
			busted = 0,
			distanceDriven = 0,
			earned = 0,
		},
	}
end

--- Fills in anything a profile saved by an older build is missing.
local function reconcile(profile)
	local base = defaultProfile()
	for key, value in base do
		if profile[key] == nil then
			profile[key] = value
		end
	end
	for key, value in base.stats do
		if profile.stats[key] == nil then
			profile.stats[key] = value
		end
	end
	profile.cash = math.clamp(tonumber(profile.cash) or 0, 0, Config.Economy.MaxCashOnHand)
	profile.bank = math.clamp(tonumber(profile.bank) or 0, 0, Config.Economy.MaxCashOnHand)
	return profile
end

local function key(player: Player): string
	return "player_" .. player.UserId
end

local function retry<T>(label: string, fn: () -> T): (boolean, T?)
	local delaySeconds = 1
	for attempt = 1, Config.Data.MaxRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt == Config.Data.MaxRetries then
			warn(
				string.format(
					"[ViceHeights] %s failed after %d attempts: %s",
					label,
					attempt,
					tostring(result)
				)
			)
		else
			task.wait(delaySeconds)
			delaySeconds *= Config.Data.RetryBackoff
		end
	end
	return false, nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function DataService.load(player: Player)
	local profile = defaultProfile()

	if persistent and store then
		local ok, saved = retry("load " .. player.Name, function()
			return (store :: DataStore):GetAsync(key(player))
		end)
		if ok and type(saved) == "table" then
			profile = reconcile(saved)
		end
	end

	profiles[player] = profile

	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = profile.cash
	cash.Parent = stats
	stats.Parent = player

	player:SetAttribute("Cash", profile.cash)
	return profile
end

function DataService.save(player: Player)
	local profile = profiles[player]
	if not profile or not persistent or not store then
		return
	end
	retry("save " .. player.Name, function()
		return (store :: DataStore):UpdateAsync(key(player), function()
			return profile
		end)
	end)
end

function DataService.release(player: Player)
	DataService.save(player)
	profiles[player] = nil
	Net.clearLimits(player)
end

function DataService.get(player: Player)
	return profiles[player]
end

--------------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------------

local function syncCash(player: Player, profile)
	player:SetAttribute("Cash", profile.cash)
	local stats = player:FindFirstChild("leaderstats")
	local cash = stats and stats:FindFirstChild("Cash")
	if cash then
		(cash :: IntValue).Value = profile.cash
	end
end

function DataService.addCash(player: Player, amount: number, reason: string?)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.cash = math.clamp(profile.cash + amount, 0, Config.Economy.MaxCashOnHand)
	if amount > 0 then
		profile.stats.earned += amount
	end
	syncCash(player, profile)
	DataService.push(player, { cash = profile.cash })

	if reason then
		DataService.notify(
			player,
			string.format("%s%s  %s", amount >= 0 and "+" or "-", Util.money(math.abs(amount)), reason),
			amount >= 0 and "cash" or "warn"
		)
	end
end

--- Spends money if the player has it. Returns false and does nothing otherwise.
function DataService.trySpend(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or amount < 0 or profile.cash < amount then
		return false
	end
	profile.cash -= amount
	syncCash(player, profile)
	DataService.push(player, { cash = profile.cash })
	return true
end

--------------------------------------------------------------------------------
-- Ownership
--------------------------------------------------------------------------------

function DataService.ownsWeapon(player: Player, weaponId: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.weapons[weaponId] ~= nil
end

function DataService.grantWeapon(player: Player, weaponId: string, reserve: number?)
	local profile = profiles[player]
	local def = WeaponCatalog.get(weaponId)
	if not profile or not def then
		return
	end
	local entry = profile.weapons[weaponId]
	if entry then
		entry.reserve += reserve or def.reserve
	else
		profile.weapons[weaponId] = { reserve = reserve or def.reserve }
	end
	DataService.push(player, { weapons = profile.weapons })
end

function DataService.addReserve(player: Player, weaponId: string, amount: number): boolean
	local profile = profiles[player]
	if not profile or not profile.weapons[weaponId] then
		return false
	end
	profile.weapons[weaponId].reserve = math.max(0, profile.weapons[weaponId].reserve + amount)
	DataService.push(player, { weapons = profile.weapons })
	return true
end

function DataService.ownsVehicle(player: Player, vehicleId: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.vehicles[vehicleId] == true
end

function DataService.grantVehicle(player: Player, vehicleId: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.vehicles[vehicleId] = true
	DataService.push(player, { vehicles = profile.vehicles })
end

function DataService.recordMission(player: Player, missionId: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.missions[missionId] = (profile.missions[missionId] or 0) + 1
	DataService.push(player, { missions = profile.missions })
end

function DataService.bumpStat(player: Player, stat: string, amount: number)
	local profile = profiles[player]
	if not profile or profile.stats[stat] == nil then
		return
	end
	profile.stats[stat] += amount
end

--------------------------------------------------------------------------------
-- Client state
--------------------------------------------------------------------------------

--- Services register a provider so the initial Fetch always returns everything
--- without DataService needing to know what a wanted level or a magazine is.
function DataService.registerProvider(fn: (Player) -> { [string]: any })
	table.insert(providers, fn)
end

function DataService.snapshot(player: Player): { [string]: any }
	local profile = profiles[player]
	local state: { [string]: any } = {}
	if profile then
		state.cash = profile.cash
		state.bank = profile.bank
		state.weapons = profile.weapons
		state.vehicles = profile.vehicles
		state.missions = profile.missions
		state.stats = profile.stats
	end
	for _, provider in providers do
		local extra = provider(player)
		if extra then
			for k, v in extra do
				state[k] = v
			end
		end
	end
	return state
end

--- Sends a partial state patch the client merges into its local mirror.
function DataService.push(player: Player, patch: { [string]: any })
	if not player.Parent then
		return
	end
	Net.event("State"):FireClient(player, patch)
end

function DataService.notify(player: Player, text: string, style: string?)
	if not player.Parent then
		return
	end
	Net.event("Notify"):FireClient(player, { text = text, style = style or "info" })
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function DataService.start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.Data.StoreName)
	end)
	if ok and result then
		store = result
		persistent = not RunService:IsStudio()
	end
	if not persistent then
		warn("[ViceHeights] DataStores unavailable; profiles are session-only")
	end

	Net.fn("Fetch").OnServerInvoke = function(player)
		-- The client may ask before its profile finishes loading.
		for _ = 1, 100 do
			if profiles[player] then
				break
			end
			task.wait(0.1)
		end
		return DataService.snapshot(player)
	end

	task.spawn(function()
		while true do
			task.wait(Config.Data.AutosaveInterval)
			for _, player in Players:GetPlayers() do
				if profiles[player] then
					task.spawn(DataService.save, player)
				end
			end
		end
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			DataService.save(player)
		end
		if not RunService:IsStudio() then
			task.wait(2)
		end
	end)
end

return DataService
