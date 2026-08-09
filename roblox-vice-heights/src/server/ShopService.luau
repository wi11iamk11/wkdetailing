--!nonstrict
--[[
	ShopService
	Everything you can walk up to and use: Ammu-Point, the dealership, your
	garage, the job board, the hospital, the precinct, and the 24/7 stores you
	can hold up.

	Interaction is two-phase. Using a pad asks the server to open a menu, and
	the server remembers nothing about it — every purchase re-verifies that the
	player is standing at a pad of the right kind before taking their money.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)
local VehicleCatalog = require(Shared.VehicleCatalog)
local WeaponCatalog = require(Shared.WeaponCatalog)

local Combat = require(script.Parent.Combat)
local DataService = require(script.Parent.DataService)
local MissionService = require(script.Parent.MissionService)
local PlayerService = require(script.Parent.PlayerService)
local VehicleService = require(script.Parent.VehicleService)
local WantedService = require(script.Parent.WantedService)
local WeaponService = require(script.Parent.WeaponService)

local ShopService = {}

local ARMOR_PRICE = 2500
local HOSPITAL_PRICE = 750
local INTERACT_RANGE = 20

local storeCooldowns: { [string]: number } = {}
local robberies: { [Player]: any } = {}

--------------------------------------------------------------------------------
-- Proximity checks
--------------------------------------------------------------------------------

--- True when the player is genuinely standing at a pad of this kind.
local function atPad(player: Player, kind: string): boolean
	local root = Util.rootOf(player.Character)
	if not root then
		return false
	end
	for _, pad in CollectionService:GetTagged("Interactable") do
		if pad:GetAttribute("Interact") == kind and pad:IsA("BasePart") then
			if (pad.Position - root.Position).Magnitude <= INTERACT_RANGE then
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Menus
--------------------------------------------------------------------------------

local function weaponMenu(player: Player)
	local profile = DataService.get(player)
	local items = {}
	for _, id in WeaponCatalog.ForSale do
		local def = WeaponCatalog.get(id)
		local owned = profile and profile.weapons[id] ~= nil
		table.insert(items, {
			id = id,
			name = def.name,
			price = owned and def.ammoPrice or def.price,
			owned = owned,
			label = owned and string.format("Ammo x%d", def.magazine) or "Buy",
			detail = string.format("%d dmg  %d rnds", def.damage, def.magazine),
		})
	end
	table.insert(items, {
		id = "armor",
		name = "Body Armor",
		price = ARMOR_PRICE,
		owned = false,
		label = "Buy",
		detail = "Absorbs incoming damage",
	})
	return { kind = "GunShop", title = "Ammu-Point", items = items }
end

local function dealershipMenu(player: Player)
	local items = {}
	for _, id in VehicleCatalog.ForSale do
		local def = VehicleCatalog.get(id)
		local owned = DataService.ownsVehicle(player, id)
		table.insert(items, {
			id = id,
			name = def.name,
			price = def.price,
			owned = owned,
			label = owned and "Owned" or "Buy",
			detail = string.format("%s  -  %s", def.class, def.description),
		})
	end
	return { kind = "Dealership", title = "Premium Deluxe Motors", items = items }
end

local function garageMenu(player: Player)
	local profile = DataService.get(player)
	local items = {}
	if profile then
		for id in profile.vehicles do
			local def = VehicleCatalog.get(id)
			if def then
				table.insert(items, {
					id = id,
					name = def.name,
					price = 0,
					owned = true,
					label = "Take out",
					detail = def.class,
				})
			end
		end
	end
	table.sort(items, function(a, b)
		return a.name < b.name
	end)
	return { kind = "Garage", title = "Your Garage", items = items }
end

local function missionMenu(player: Player)
	local snapshot = DataService.snapshot(player)
	local items = {}
	for _, mission in snapshot.missionBoard or {} do
		table.insert(items, {
			id = mission.id,
			name = mission.name,
			price = -mission.payout, -- negative price renders as a payout
			owned = false,
			label = "Accept",
			detail = mission.description,
		})
	end
	return { kind = "MissionBoard", title = "Job Board", items = items }
end

--------------------------------------------------------------------------------
-- Store robbery
--------------------------------------------------------------------------------

local function startRobbery(player: Player, storeId: string)
	local now = os.clock()
	if (storeCooldowns[storeId] or -math.huge) + Config.Economy.StoreRobbery.Cooldown > now then
		DataService.notify(player, "This place has nothing left in the register.", "warn")
		return
	end
	if robberies[player] then
		return
	end

	local root = Util.rootOf(player.Character)
	if not root then
		return
	end

	storeCooldowns[storeId] = now
	local anchor = root.Position
	local finishAt = now + Config.Economy.StoreRobbery.Duration

	robberies[player] = { storeId = storeId, finishAt = finishAt, anchor = anchor }
	WantedService.setStars(player, Config.Economy.StoreRobbery.WantedStars)
	WantedService.addCrime(player, "StoreRobbery")
	DataService.notify(player, "Hold the register. Don't leave.", "warn")

	task.spawn(function()
		while robberies[player] do
			task.wait(0.5)
			local session = robberies[player]
			if not session then
				return
			end
			local current = Util.rootOf(player.Character)
			if not current or not Util.isAlive(player.Character) then
				robberies[player] = nil
				DataService.notify(player, "Robbery botched.", "bad")
				return
			end
			if (current.Position - session.anchor).Magnitude > 30 then
				robberies[player] = nil
				DataService.notify(player, "You left the store empty-handed.", "warn")
				return
			end
			if os.clock() >= session.finishAt then
				robberies[player] = nil
				local payout = math.random(
					Config.Economy.StoreRobbery.Payout.Min,
					Config.Economy.StoreRobbery.Payout.Max
				)
				DataService.addCash(player, payout, "register")
				DataService.notify(player, "Got the money. Now lose the cops.", "good")
				return
			end
			DataService.push(player, {
				robbery = math.max(0, session.finishAt - os.clock()),
			})
		end
	end)
end

--------------------------------------------------------------------------------
-- Purchases
--------------------------------------------------------------------------------

local function buyWeapon(player: Player, weaponId: string)
	local def = WeaponCatalog.get(weaponId)
	if not def or def.melee then
		return
	end

	if DataService.ownsWeapon(player, weaponId) then
		if DataService.trySpend(player, def.ammoPrice) then
			DataService.addReserve(player, weaponId, def.magazine * 2)
			DataService.notify(player, string.format("%s ammo purchased.", def.name), "good")
		else
			DataService.notify(player, "Not enough cash.", "warn")
		end
		return
	end

	if DataService.trySpend(player, def.price) then
		DataService.grantWeapon(player, weaponId)
		DataService.notify(player, string.format("%s purchased.", def.name), "good")
		-- Hand it over immediately rather than on next respawn.
		WeaponService.refreshLoadout(player)
	else
		DataService.notify(player, "Not enough cash.", "warn")
	end
end

local function buyArmor(player: Player)
	local character = player.Character
	if not character then
		return
	end
	if Combat.getArmor(character) >= Config.Combat.MaxArmor then
		DataService.notify(player, "Already fully armoured.", "info")
		return
	end
	if DataService.trySpend(player, ARMOR_PRICE) then
		Combat.setArmor(character, Config.Combat.MaxArmor)
		DataService.push(player, { armor = Config.Combat.MaxArmor })
		DataService.notify(player, "Body armour equipped.", "good")
	else
		DataService.notify(player, "Not enough cash.", "warn")
	end
end

local function buyVehicle(player: Player, vehicleId: string)
	local def = VehicleCatalog.get(vehicleId)
	if not def or not VehicleCatalog.isPurchasable(vehicleId) then
		return
	end
	if DataService.ownsVehicle(player, vehicleId) then
		DataService.notify(player, "You already own that.", "info")
		return
	end
	if DataService.trySpend(player, def.price) then
		DataService.grantVehicle(player, vehicleId)
		DataService.notify(player, string.format("%s purchased.", def.name), "good")
		VehicleService.spawnFor(player, vehicleId)
	else
		DataService.notify(player, "Not enough cash.", "warn")
	end
end

local function heal(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if humanoid.Health >= humanoid.MaxHealth then
		DataService.notify(player, "You're fine.", "info")
		return
	end
	if DataService.trySpend(player, HOSPITAL_PRICE) then
		humanoid.Health = humanoid.MaxHealth
		DataService.notify(player, "Patched up.", "good")
	else
		DataService.notify(player, "Not enough cash.", "warn")
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function ShopService.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		local pad = prompt.Parent
		if not pad or not pad:IsA("BasePart") then
			return
		end
		local kind = pad:GetAttribute("Interact")
		if not kind then
			return
		end
		if not Net.allow(player, "interact", 3, 5) then
			return
		end

		local root = Util.rootOf(player.Character)
		if not root or (root.Position - pad.Position).Magnitude > INTERACT_RANGE then
			return
		end

		if kind == "GunShop" then
			DataService.push(player, { menu = weaponMenu(player) })
		elseif kind == "Dealership" then
			DataService.push(player, { menu = dealershipMenu(player) })
		elseif kind == "Garage" then
			DataService.push(player, { menu = garageMenu(player) })
		elseif kind == "MissionBoard" then
			DataService.push(player, { menu = missionMenu(player) })
		elseif kind == "Hospital" then
			heal(player)
		elseif kind == "PoliceStation" then
			PlayerService.surrender(player)
		elseif kind == "Store" then
			startRobbery(player, tostring(pad:GetAttribute("Id")))
		end
	end)

	Net.event("Purchase").OnServerEvent:Connect(function(player, kind, id)
		if not Net.allow(player, "purchase", 2, 4) then
			return
		end
		if type(kind) ~= "string" or type(id) ~= "string" then
			return
		end

		if kind == "weapon" then
			if not atPad(player, "GunShop") then
				return
			end
			if id == "armor" then
				buyArmor(player)
			else
				buyWeapon(player, id)
			end
		elseif kind == "vehicle" then
			if not atPad(player, "Dealership") then
				return
			end
			buyVehicle(player, id)
		elseif kind == "garage" then
			if not atPad(player, "Garage") then
				return
			end
			VehicleService.spawnFor(player, id)
		elseif kind == "mission" then
			if not atPad(player, "MissionBoard") then
				return
			end
			MissionService.start(player, id)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		robberies[player] = nil
	end)
end

return ShopService
