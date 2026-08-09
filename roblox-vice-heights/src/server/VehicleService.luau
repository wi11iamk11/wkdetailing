--!nonstrict
--[[
	VehicleService
	Spawns, tracks and destroys every car in the world.

	Ownership rule: whoever is in the driver's seat simulates the car, so the
	server hands them network ownership on entry and takes it back on exit.
	Parked street cars stay anchored until someone touches them, which keeps a
	city full of props off the physics budget entirely.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local CityGrid = require(Shared.CityGrid)
local Net = require(Shared.Net)
local Util = require(Shared.Util)
local VehicleCatalog = require(Shared.VehicleCatalog)

local Combat = require(script.Parent.Combat)
local DataService = require(script.Parent.DataService)
local VehicleFactory = require(script.Parent.VehicleFactory)
local WantedService = require(script.Parent.WantedService)
local WorldBuilder = require(script.Parent.WorldBuilder)

local VehicleService = {}

local V = Config.Vehicle

type Record = {
	model: Model,
	chassis: BasePart,
	kind: string, -- "street" | "owned" | "police" | "mission"
	owner: Player?,
	spawnedAt: number,
	lastOccupied: number,
	lastSpeed: number,
	driver: Player?,
	stolenBy: { [number]: boolean },
	anchoredParked: boolean,
}

local records: { [Model]: Record } = {}
local folder: Folder
local rng = Random.new(Config.Game.Seed + 7)
local touchDebounce: { [Instance]: number } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ownedCount(player: Player): number
	local count = 0
	for _, record in records do
		if record.kind == "owned" and record.owner == player then
			count += 1
		end
	end
	return count
end

local function oldestOwned(player: Player): Model?
	local best, bestTime = nil, math.huge
	for model, record in records do
		if record.kind == "owned" and record.owner == player and record.spawnedAt < bestTime then
			best, bestTime = model, record.spawnedAt
		end
	end
	return best
end

function VehicleService.destroy(model: Model)
	local record = records[model]
	if not record then
		if model.Parent then
			model:Destroy()
		end
		return
	end
	records[model] = nil
	if model.Parent then
		model:Destroy()
	end
end

function VehicleService.getDriving(player: Player): Model?
	for model, record in records do
		if record.driver == player then
			return model
		end
	end
	return nil
end

function VehicleService.recordOf(model: Model): Record?
	return records[model]
end

function VehicleService.all(): { [Model]: Record }
	return records
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

local function register(model: Model, kind: string, owner: Player?): Model
	local chassis = model.PrimaryPart :: BasePart
	chassis.Anchored = false

	records[model] = {
		model = model,
		chassis = chassis,
		kind = kind,
		owner = owner,
		spawnedAt = os.clock(),
		lastOccupied = os.clock(),
		lastSpeed = 0,
		driver = nil,
		stolenBy = {},
		anchoredParked = false,
	}

	if owner then
		model:SetAttribute("OwnerUserId", owner.UserId)
	end
	model:SetAttribute("Kind", kind)
	CollectionService:AddTag(model, "Vehicle")
	model.Parent = folder
	return model
end

--- Finds a clear patch of road near `origin` to drop a car onto.
local function findSpawnCFrame(origin: Vector3): CFrame
	for _ = 1, 12 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(18, 55)
		local candidate = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local snapped = CityGrid.snapToRoad(candidate)
		local position = Vector3.new(snapped.X, Config.City.GroundY + 4, snapped.Z)

		local region = Workspace:GetPartBoundsInBox(CFrame.new(position), Vector3.new(10, 8, 20))
		local blocked = false
		for _, part in region do
			if
				part:IsDescendantOf(folder)
				or part.Parent and part.Parent:FindFirstChildOfClass("Humanoid")
			then
				blocked = true
				break
			end
		end
		if not blocked then
			-- Face along the road we snapped to.
			local _, dx = CityGrid.nearestRoadIndex(candidate.X)
			local facing = math.abs(dx) < Config.City.RoadWidth / 2 and 0 or math.pi / 2
			return CFrame.new(position) * CFrame.Angles(0, facing, 0)
		end
	end
	local fallback = CityGrid.snapToRoad(origin)
	return CFrame.new(fallback.X, Config.City.GroundY + 4, fallback.Z)
end

VehicleService.findSpawnCFrame = findSpawnCFrame

--- Delivers a vehicle the player owns. Enforces the per-player cap.
function VehicleService.spawnFor(player: Player, vehicleId: string, cframe: CFrame?): Model?
	if not DataService.ownsVehicle(player, vehicleId) then
		DataService.notify(player, "You don't own that vehicle.", "warn")
		return nil
	end

	if ownedCount(player) >= V.MaxPerPlayer then
		local old = oldestOwned(player)
		if old then
			VehicleService.destroy(old)
		end
	end

	local root = Util.rootOf(player.Character)
	local where = cframe or findSpawnCFrame(root and root.Position or Vector3.zero)
	local model = VehicleFactory.create(vehicleId, where)
	if not model then
		return nil
	end

	register(model, "owned", player)
	Net.event("VehicleAssigned"):FireClient(player, model)
	DataService.notify(player, string.format("%s delivered.", model.Name), "good")
	return model
end

function VehicleService.spawnStreet(cframe: CFrame, vehicleId: string?): Model?
	local id = vehicleId
	if not id then
		local pool = VehicleCatalog.ForSale
		id = pool[rng:NextInteger(1, #pool)]
	end
	local model = VehicleFactory.create(id, cframe, {
		color = Color3.fromHSV(rng:NextNumber(), rng:NextNumber(0.15, 0.7), rng:NextNumber(0.35, 0.9)),
	})
	if not model then
		return nil
	end
	register(model, "street", nil)
	-- Parked cars sleep until disturbed.
	model.PrimaryPart.Anchored = true
	records[model].anchoredParked = true
	return model
end

function VehicleService.spawnPolice(cframe: CFrame): Model?
	local model = VehicleFactory.create("cruiser", cframe)
	if not model then
		return nil
	end
	register(model, "police", nil)
	VehicleFactory.setSiren(model, true)
	return model
end

--------------------------------------------------------------------------------
-- Damage
--------------------------------------------------------------------------------

function VehicleService.explode(model: Model, blame: Player?)
	local record = records[model]
	local chassis = model.PrimaryPart
	if not chassis then
		VehicleService.destroy(model)
		return
	end

	local explosion = Instance.new("Explosion")
	explosion.Position = chassis.Position
	explosion.BlastRadius = V.ExplosionRadius
	explosion.BlastPressure = 120000
	-- Roblox's explosion supplies the shove; damage goes through Combat so
	-- armour, attribution and kill consequences all still apply.
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = Workspace

	Combat.splash(chassis.Position, V.ExplosionRadius, V.ExplosionDamage, blame or record and record.driver)

	if record and record.kind == "police" and blame then
		WantedService.addCrime(blame, "CopVehicleDestroyed")
	end
	VehicleService.destroy(model)
end

function VehicleService.damage(model: Model, amount: number, blame: Player?)
	local record = records[model]
	if not record then
		return
	end
	local health = (model:GetAttribute("Health") or V.MaxHealth) - amount
	model:SetAttribute("Health", math.max(0, health))

	if health <= 0 then
		VehicleService.explode(model, blame or record.driver)
	elseif health <= V.MaxHealth * 0.3 then
		-- Smoke from the engine bay once the car is limping.
		local chassis = model.PrimaryPart
		if chassis and not chassis:FindFirstChild("Smoke") then
			local smoke = Instance.new("Smoke")
			smoke.Size = 3
			smoke.Opacity = 0.25
			smoke.RiseVelocity = 6
			smoke.Color = Color3.fromRGB(60, 60, 62)
			smoke.Parent = chassis
		end
	end
end

--------------------------------------------------------------------------------
-- Seating
--------------------------------------------------------------------------------

local function onDriverChanged(model: Model, record: Record, seat: VehicleSeat)
	local occupant = seat.Occupant
	local chassis = record.chassis

	-- Hide the "Drive" prompt from whoever is already driving.
	local prompt = seat:FindFirstChild("EnterPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = occupant == nil
	end

	if occupant then
		local player = Players:GetPlayerFromCharacter(occupant.Parent)
		record.driver = player
		record.lastOccupied = os.clock()

		if record.anchoredParked then
			chassis.Anchored = false
			record.anchoredParked = false
		end

		if player then
			model:SetAttribute("DriverUserId", player.UserId)
			pcall(function()
				chassis:SetNetworkOwner(player)
			end)

			local isTheft = record.kind == "street"
				or (record.kind == "owned" and record.owner ~= player)
				or record.kind == "police"
			if isTheft and not record.stolenBy[player.UserId] then
				record.stolenBy[player.UserId] = true
				WantedService.addCrime(player, "VehicleTheft")
				DataService.notify(player, "Grand theft auto.", "warn")
			end
		else
			-- An NPC took the wheel; the server drives it.
			pcall(function()
				chassis:SetNetworkOwner(nil)
			end)
		end
	else
		record.driver = nil
		record.lastOccupied = os.clock()
		model:SetAttribute("DriverUserId", 0)
		model:SetAttribute("Throttle", 0)
		model:SetAttribute("Steer", 0)
		pcall(function()
			chassis:SetNetworkOwnershipAuto()
		end)
	end
end

local function bindSeats(model: Model, record: Record)
	local driverSeat = model:FindFirstChild("DriverSeat")
	if driverSeat and driverSeat:IsA("VehicleSeat") then
		driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			onDriverChanged(model, record, driverSeat)
		end)
	end
end

local function seatPlayer(player: Player, seat: BasePart)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = Util.rootOf(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	if (root.Position - seat.Position).Magnitude > 20 then
		return -- prompt distance is client-enforced; verify it here too
	end
	if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then
		return
	end
	-- Never turf out whoever got there first.
	if (seat :: any).Occupant ~= nil then
		return
	end
	(seat :: any):Sit(humanoid)
end

--------------------------------------------------------------------------------
-- Collisions
--------------------------------------------------------------------------------

local function onChassisTouched(model: Model, record: Record, other: BasePart)
	local humanoid = Util.humanoidOf(other)
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local speed = record.chassis.AssemblyLinearVelocity.Magnitude
	if speed < 26 then
		return
	end

	local victim = humanoid.Parent
	local now = os.clock()
	if touchDebounce[victim] and now - touchDebounce[victim] < 1.2 then
		return
	end
	touchDebounce[victim] = now

	-- Do not let a car mince its own driver or passengers.
	local driverPlayer = record.driver
	if driverPlayer and driverPlayer.Character == victim then
		return
	end
	if humanoid.SeatPart and humanoid.SeatPart:IsDescendantOf(model) then
		return
	end

	humanoid:TakeDamage(math.min(100, (speed - 20) * 2.2))

	if driverPlayer then
		local kind = victim:GetAttribute("NpcKind")
		if kind == "Cop" then
			WantedService.addCrime(driverPlayer, "CopKill", 0.6)
		elseif kind == "Ped" or Players:GetPlayerFromCharacter(victim) then
			WantedService.addCrime(driverPlayer, "VehicleAssault")
		end
	end
end

--------------------------------------------------------------------------------
-- Maintenance
--------------------------------------------------------------------------------

local function nearestPlayerDistance(position: Vector3): number
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local root = Util.rootOf(player.Character)
		if root then
			best = math.min(best, (root.Position - position).Magnitude)
		end
	end
	return best
end

local function maintain()
	local now = os.clock()
	for model, record in records do
		if not model.Parent or not record.chassis.Parent then
			records[model] = nil
			continue
		end

		local speed = record.chassis.AssemblyLinearVelocity.Magnitude

		-- Impact damage from a sudden loss of speed.
		local drop = record.lastSpeed - speed
		if drop > V.CollisionDamageThreshold then
			VehicleService.damage(
				model,
				(drop - V.CollisionDamageThreshold) * V.CollisionDamageScale,
				record.driver
			)
		end
		record.lastSpeed = speed

		if record.driver then
			record.lastOccupied = now
			continue
		end

		local idle = now - record.lastOccupied
		if
			record.kind == "owned"
			and idle > V.AbandonDespawnTime
			and nearestPlayerDistance(record.chassis.Position) > 120
		then
			VehicleService.destroy(model)
		elseif
			record.kind == "street"
			and not record.anchoredParked
			and idle > V.RestAnchorDelay
			and speed < 2
		then
			record.chassis.Anchored = true
			record.anchoredParked = true
		elseif
			record.kind == "police"
			and idle > 45
			and nearestPlayerDistance(record.chassis.Position) > 220
		then
			VehicleService.destroy(model)
		end
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function VehicleService.start()
	folder = Instance.new("Folder")
	folder.Name = "Vehicles"
	folder.Parent = Workspace

	-- Seed the streets with parked cars.
	local spots = WorldBuilder.parkingSpots()
	for index = #spots, 2, -1 do
		local swap = rng:NextInteger(1, index)
		spots[index], spots[swap] = spots[swap], spots[index]
	end
	local target = math.min(Config.Traffic.MaxParkedCars, #spots)
	for index = 1, target do
		VehicleService.spawnStreet(spots[index])
	end

	-- Late-bind every registered vehicle's seats and collisions.
	CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(function(model)
		local record = records[model]
		if not record then
			return
		end
		bindSeats(model, record)
		record.chassis.Touched:Connect(function(other)
			onChassisTouched(model, record, other)
		end)
	end)
	for model, record in records do
		bindSeats(model, record)
		record.chassis.Touched:Connect(function(other)
			onChassisTouched(model, record, other)
		end)
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= "EnterPrompt" and prompt.Name ~= "RidePrompt" then
			return
		end
		if not Net.allow(player, "seat", 3, 5) then
			return
		end
		local seat = prompt.Parent
		if seat and seat:IsA("BasePart") then
			seatPlayer(player, seat)
		end
	end)

	Net.event("VehicleRequest").OnServerEvent:Connect(function(player, action, vehicleId)
		if not Net.allow(player, "vehicleRequest", 1, 3) then
			return
		end
		if action == "spawn" and type(vehicleId) == "string" then
			VehicleService.spawnFor(player, vehicleId)
		elseif action == "despawn" then
			for model, record in records do
				if record.kind == "owned" and record.owner == player and not record.driver then
					VehicleService.destroy(model)
				end
			end
		end
	end)

	-- The driver's client tells us where the wheels are pointing so every other
	-- client can animate them. Purely cosmetic, so it is rate limited and never
	-- trusted for anything else.
	Net.event("VehicleTelemetry").OnServerEvent:Connect(function(player, steer, throttle)
		if type(steer) ~= "number" or steer ~= steer then
			return
		end
		if not Net.allow(player, "telemetry", 12, 16) then
			return
		end
		local model = VehicleService.getDriving(player)
		if model then
			model:SetAttribute("Steer", math.clamp(steer, -1, 1))
			model:SetAttribute("Throttle", math.clamp(tonumber(throttle) or 0, -1, 1))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for model, record in records do
			if record.owner == player then
				VehicleService.destroy(model)
			end
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.25 then
			return
		end
		accumulator = 0
		maintain()
	end)
end

return VehicleService
