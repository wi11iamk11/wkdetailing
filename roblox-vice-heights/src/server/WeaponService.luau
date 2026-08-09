--!nonstrict
--[[
	WeaponService
	Server-authoritative gunplay.

	The client reports where it aimed, never what it hit. The server re-rolls the
	spread and does its own raycasts, so a modified client can at best point the
	barrel somewhere silly — it cannot invent hits, damage or ammunition.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)
local WeaponCatalog = require(Shared.WeaponCatalog)

local Combat = require(script.Parent.Combat)
local DataService = require(script.Parent.DataService)
local WantedService = require(script.Parent.WantedService)

local WeaponService = {}

type State = {
	equipped: string,
	mag: { [string]: number },
	lastFire: number,
	reloadUntil: number,
}

local states: { [Player]: State } = {}
local gunshotListeners: { (Vector3, Player) -> () } = {}
local rng = Random.new(os.time() + 11)

--- Fires (position, shooter) whenever a loud weapon goes off. PedService uses
--- this to scatter the crowd without WeaponService knowing pedestrians exist.
function WeaponService.onGunshot(fn)
	table.insert(gunshotListeners, fn)
end

local function ensure(player: Player): State
	local state = states[player]
	if not state then
		state = { equipped = "fists", mag = {}, lastFire = 0, reloadUntil = 0 }
		states[player] = state
	end
	return state
end

function WeaponService.getEquipped(player: Player): string
	return ensure(player).equipped
end

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

local function buildTool(weaponId: string): Tool?
	local def = WeaponCatalog.get(weaponId)
	if not def or def.melee then
		return nil
	end

	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute("WeaponId", weaponId)

	local spec = def.model or { length = 2, color = Color3.fromRGB(50, 52, 58) }

	local handle = Util.part({
		Name = "Handle",
		Size = Vector3.new(0.4, 0.9, spec.length),
		Color = spec.color,
		Material = Enum.Material.Metal,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = tool,
	})

	local barrel = Util.part({
		Name = "Barrel",
		Size = Vector3.new(0.22, 0.22, spec.length * 0.55),
		CFrame = handle.CFrame * CFrame.new(0, 0.25, -spec.length * 0.55),
		Color = Color3.fromRGB(32, 34, 38),
		Material = Enum.Material.Metal,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Parent = tool,
	})
	Util.weld(handle, barrel)

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -spec.length * 0.3)
	muzzle.Parent = barrel

	-- Point the barrel down the arm rather than out of the palm.
	tool.GripPos = Vector3.new(0, -0.2, 0.35)
	tool.GripForward = Vector3.new(0, 0, -1)
	tool.GripRight = Vector3.new(1, 0, 0)
	tool.GripUp = Vector3.new(0, 1, 0)

	return tool
end

local function bindTool(player: Player, tool: Tool, weaponId: string)
	tool.Equipped:Connect(function()
		ensure(player).equipped = weaponId
		DataService.push(player, { equipped = weaponId, mag = WeaponService.magOf(player, weaponId) })
	end)
	tool.Unequipped:Connect(function()
		local state = ensure(player)
		if state.equipped == weaponId then
			state.equipped = "fists"
			DataService.push(player, { equipped = "fists" })
		end
	end)
end

--- Rebuilds the player's backpack from their profile.
function WeaponService.refreshLoadout(player: Player)
	local profile = DataService.get(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not profile or not backpack then
		return
	end

	backpack:ClearAllChildren()
	-- An equipped tool lives on the character, not in the backpack, so it has
	-- to be cleared too or buying a gun mid-fight duplicates the one in hand.
	local character = player.Character
	if character then
		for _, child in character:GetChildren() do
			if child:IsA("Tool") then
				child:Destroy()
			end
		end
	end

	local state = ensure(player)
	state.equipped = "fists"

	for weaponId in profile.weapons do
		local def = WeaponCatalog.get(weaponId)
		if def and not def.melee then
			local tool = buildTool(weaponId)
			if tool then
				bindTool(player, tool, weaponId)
				tool.Parent = backpack
			end
			-- Respawning tops off the magazine but not the reserve.
			state.mag[weaponId] = def.magazine
		end
	end

	DataService.push(player, { equipped = "fists", mag = 0, weapons = profile.weapons })
end

function WeaponService.magOf(player: Player, weaponId: string): number
	local state = ensure(player)
	return state.mag[weaponId] or 0
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

--- The shooter draws their own tracer the instant they click, so they are
--- deliberately excluded here rather than seeing a second one a ping later.
local function broadcastTracer(origin: Vector3, hit: Vector3, weaponId: string, shooter: Player)
	local payload = { kind = "tracer", from = origin, to = hit, weapon = weaponId }
	for _, player in Players:GetPlayers() do
		if player ~= shooter then
			local root = Util.rootOf(player.Character)
			if root and (root.Position - origin).Magnitude < 400 then
				Net.event("Effect"):FireClient(player, payload)
			end
		end
	end
end

--- Anyone who could plausibly have witnessed a gunshot. Only the two NPC
--- folders are searched: an automatic weapon fires this a dozen times a second,
--- so it must never walk the whole workspace.
local WITNESS_RANGE = 90

local function witnessesNear(position: Vector3): boolean
	for _, folderName in { "Pedestrians", "Police" } do
		local folder = Workspace:FindFirstChild(folderName)
		if folder then
			for _, model in folder:GetChildren() do
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					local root = model:FindFirstChild("HumanoidRootPart")
					if root and (root.Position - position).Magnitude < WITNESS_RANGE then
						return true
					end
				end
			end
		end
	end
	return false
end

local function fireOnce(player: Player, def, weaponId: string, origin: Vector3, direction: Vector3)
	local character = player.Character
	local params = Util.filterParams({ character })

	local hits = 0
	for _ = 1, def.pellets or 1 do
		local spread = Util.coneSpread(direction, def.spread or 0, rng)
		local result = Workspace:Raycast(origin, spread * def.range, params)
		local endPoint = result and result.Position or (origin + spread * def.range)

		if result then
			local humanoid = Util.humanoidOf(result.Instance)
			if humanoid and humanoid.Health > 0 and humanoid.Parent ~= character then
				local distance = (result.Position - origin).Magnitude
				local damage = WeaponCatalog.damageAt(weaponId, distance)
				local zone = Util.hitZone(result.Instance.Name)
				if zone == "Head" then
					damage *= Config.Combat.HeadshotMultiplier
				elseif zone == "Limb" then
					damage *= Config.Combat.LimbMultiplier
				end

				local _, killed = Combat.damage(humanoid, damage, player)
				hits += 1
				Net.event("Hitmarker"):FireClient(player, { killed = killed, zone = zone })
			end
		end

		broadcastTracer(origin, endPoint, weaponId, player)
	end
	return hits
end

local function onFire(player: Player, origin: Vector3, direction: Vector3)
	local state = ensure(player)
	local weaponId = state.equipped
	local def = WeaponCatalog.get(weaponId)
	if not def then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not Util.isAlive(character) then
		return
	end

	local now = os.clock()
	if now < state.reloadUntil then
		return
	end
	if now - state.lastFire < def.fireRate * Config.Combat.FireRateTolerance then
		return
	end
	-- The barrel has to be roughly where the player is.
	if (origin - (head :: BasePart).Position).Magnitude > Config.Combat.MaxOriginError then
		return
	end

	if not def.melee then
		local mag = state.mag[weaponId] or 0
		if mag <= 0 then
			return
		end
		state.mag[weaponId] = mag - 1
	end

	state.lastFire = now
	fireOnce(player, def, weaponId, origin, direction.Unit)
	DataService.push(player, { mag = state.mag[weaponId] or 0 })

	if def.loud then
		for _, listener in gunshotListeners do
			task.spawn(listener, origin, player)
		end
		if witnessesNear(origin) then
			WantedService.addCrime(player, "DiscardedWeaponFire")
		end
	end
end

local function onReload(player: Player)
	local state = ensure(player)
	local weaponId = state.equipped
	local def = WeaponCatalog.get(weaponId)
	local profile = DataService.get(player)
	if not def or def.melee or not profile then
		return
	end

	local entry = profile.weapons[weaponId]
	if not entry or entry.reserve <= 0 then
		DataService.notify(player, "Out of ammo.", "warn")
		return
	end

	local mag = state.mag[weaponId] or 0
	if mag >= def.magazine or os.clock() < state.reloadUntil then
		return
	end

	local needed = math.min(def.magazine - mag, entry.reserve)
	state.reloadUntil = os.clock() + def.reloadTime
	DataService.push(player, { reloading = def.reloadTime })

	task.delay(def.reloadTime, function()
		if not player.Parent or states[player] ~= state then
			return
		end
		local current = DataService.get(player)
		if not current or not current.weapons[weaponId] then
			return
		end
		local take = math.min(needed, current.weapons[weaponId].reserve)
		current.weapons[weaponId].reserve -= take
		state.mag[weaponId] = (state.mag[weaponId] or 0) + take
		DataService.push(player, {
			mag = state.mag[weaponId],
			weapons = current.weapons,
			reloading = 0,
		})
	end)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function WeaponService.start()
	DataService.registerProvider(function(player)
		local state = ensure(player)
		return {
			equipped = state.equipped,
			mag = state.mag[state.equipped] or 0,
			armor = Combat.getArmor(player.Character),
		}
	end)

	Net.event("WeaponFire").OnServerEvent:Connect(function(player, origin, direction)
		if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
			return
		end
		if direction.Magnitude < 0.01 or origin ~= origin then
			return
		end
		-- Hard ceiling above any weapon's real rate of fire.
		if not Net.allow(player, "fire", 20, 8) then
			return
		end
		onFire(player, origin, direction)
	end)

	Net.event("WeaponReload").OnServerEvent:Connect(function(player)
		if not Net.allow(player, "reload", 2, 3) then
			return
		end
		onReload(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return WeaponService
