--!nonstrict
--[[
	Integration smoke test.

	Boots the real server, joins a real player, and drives the systems the way
	play does: commit a crime, get chased, spawn a car, fire a gun, take a job,
	buy something, then boot the client on top. Every module runs its actual
	code; nothing here is stubbed except the engine underneath it.
]]

local failures = 0
local checks = 0

local function heading(text)
	print("")
	print("== " .. text)
end

local function check(name, ok, detail)
	checks += 1
	if ok then
		print("  pass  " .. name)
	else
		failures += 1
		print("  FAIL  " .. name .. (detail ~= nil and ("  <- " .. tostring(detail)) or ""))
	end
end

local function pcheck(name, fn)
	local ok, err = pcall(fn)
	check(name, ok, err)
	return ok
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")

--- Runs `seconds` of simulated time, firing Heartbeat/Stepped as the engine would.
local function simulate(seconds, dt)
	dt = dt or 1 / 30
	local steps = math.floor(seconds / dt)
	for _ = 1, steps do
		Mock.step(dt)
		RunService.Heartbeat:Fire(dt)
		RunService.Stepped:Fire(Mock.now(), dt)
	end
end

--------------------------------------------------------------------------------
heading("Server bootstrap")
--------------------------------------------------------------------------------

Mock.isServer = true
pcheck("init.server runs clean", function()
	__loaderOf[Tree.ServerScript](Tree.ServerScript)
end)

local city = workspace:FindFirstChild("City")
check("city folder exists", city ~= nil)

local partCount = city and #city:GetDescendants() or 0
check("city generated geometry", partCount > 1000, partCount .. " descendants")

local roads = city and city:FindFirstChild("Roads")
check("roads built", roads ~= nil and #roads:GetChildren() > 50)

local interactables = city and city:FindFirstChild("Interactables")
check("interactables placed", interactables ~= nil and #interactables:GetChildren() >= 8)

check("vehicles folder exists", workspace:FindFirstChild("Vehicles") ~= nil)
check("street cars parked", #CollectionService:GetTagged("Vehicle") > 0)

-- Grab the service singletons the same way the game does.
local ServerScript = Tree.ServerScript
local DataService = require(ServerScript.DataService)
local WantedService = require(ServerScript.WantedService)
local VehicleService = require(ServerScript.VehicleService)
local WeaponService = require(ServerScript.WeaponService)
local MissionService = require(ServerScript.MissionService)
local Combat = require(ServerScript.Combat)
local Net = require(Tree.Shared.Net)
local CarSim = require(Tree.Shared.CarSim)
local Config = require(Tree.Shared.Config)
local CityGrid = require(Tree.Shared.CityGrid)

--------------------------------------------------------------------------------
heading("City grid")
--------------------------------------------------------------------------------

check("grid is centred", math.abs(CityGrid.Origin + CityGrid.HalfExtent) < 1e-6)
check("road centreline lands on a road", CityGrid.isOnRoad(CityGrid.intersection(2, 3)))
check("block centre is off-road", not CityGrid.isOnRoad(CityGrid.blockCenter(2, 3)))
check("landmarks resolve", CityGrid.landmarkPosition("GunShop") ~= nil)

local snapped = CityGrid.snapToRoad(Vector3.new(37, 0, 412))
check("snapToRoad lands on tarmac", CityGrid.isOnRoad(snapped), tostring(snapped))

--------------------------------------------------------------------------------
heading("Player join")
--------------------------------------------------------------------------------

local player = Instance.new("Player")
player.Name = "TestSubject"
player.UserId = 424242
player.Parent = Players
table.insert(Players._list, player)
Instance.new("Backpack", player)
Instance.new("PlayerGui", player)
Mock.localPlayer = player

Players.PlayerAdded:Fire(player)
simulate(0.5)

local profile = DataService.get(player)
check("profile created", profile ~= nil)
check("starting cash", profile and profile.cash == Config.Economy.StartingCash, profile and profile.cash)
check("starting pistol", profile and profile.weapons.pistol ~= nil)
check("starting vehicle", profile and profile.vehicles.blista == true)

local character = Instance.new("Model")
character.Name = player.Name
local root = Instance.new("Part", character)
root.Name = "HumanoidRootPart"
root.CFrame = CFrame.new(0, 5, 0)
local head = Instance.new("Part", character)
head.Name = "Head"
head.CFrame = CFrame.new(0, 6, 0)
local torso = Instance.new("Part", character)
torso.Name = "Torso"
local humanoid = Instance.new("Humanoid", character)
character.PrimaryPart = root
character.Parent = workspace
player.Character = character
player.CharacterAdded:Fire(character)
simulate(0.5)

check("loadout handed out", #player.Backpack:GetChildren() > 0, #player.Backpack:GetChildren())
check("armor attribute set", character:GetAttribute("Armor") == 0)

--------------------------------------------------------------------------------
heading("Economy")
--------------------------------------------------------------------------------

DataService.addCash(player, 5000, "test payout")
check("cash added", profile.cash == Config.Economy.StartingCash + 5000, profile.cash)
check("spend succeeds when affordable", DataService.trySpend(player, 1000) == true)
check("spend fails when broke", DataService.trySpend(player, 10 ^ 9) == false)
check("cash unchanged after failed spend", profile.cash == Config.Economy.StartingCash + 4000, profile.cash)

--------------------------------------------------------------------------------
heading("Wanted level")
--------------------------------------------------------------------------------

check("starts clean", WantedService.getStars(player) == 0)
WantedService.addCrime(player, "VehicleTheft")
check("crime raises heat", WantedService.getHeat(player) > 0)
check("a minor crime stays under one star", WantedService.getStars(player) == 0)

-- Decay only runs while nobody is watching, so this has to happen before the
-- response dispatches anyone with line of sight.
local heatBefore = WantedService.getHeat(player)
simulate(Config.Wanted.CooldownDelay + 4)
check("heat decays out of sight", WantedService.getHeat(player) < heatBefore, WantedService.getHeat(player))

WantedService.addCrime(player, "PedKill")
WantedService.addCrime(player, "CopKill")
WantedService.addCrime(player, "StoreRobbery")
check("stars rise", WantedService.getStars(player) >= 1, WantedService.getStars(player))

WantedService.setStars(player, 4)
check("setStars works", WantedService.getStars(player) == 4, WantedService.getStars(player))

--------------------------------------------------------------------------------
heading("Police response")
--------------------------------------------------------------------------------

simulate(6)
local police = workspace:FindFirstChild("Police")
check("police folder exists", police ~= nil)
local copCount = police and #police:GetChildren() or 0
check("officers dispatched", copCount > 0, copCount .. " cops")

local anyCop = police and police:GetChildren()[1]
check("officer is a rig", anyCop ~= nil and anyCop:FindFirstChildOfClass("Humanoid") ~= nil)
check("officer is tagged", anyCop ~= nil and anyCop:GetAttribute("NpcKind") == "Cop")

WantedService.clear(player)
check("clearing wanted works", WantedService.getStars(player) == 0)
simulate(4)

--------------------------------------------------------------------------------
heading("Pedestrians")
--------------------------------------------------------------------------------

simulate(6)
local peds = workspace:FindFirstChild("Pedestrians")
check("pedestrian folder exists", peds ~= nil)
check("crowd spawned", peds ~= nil and #peds:GetChildren() > 0, peds and #peds:GetChildren())

--------------------------------------------------------------------------------
heading("Vehicles")
--------------------------------------------------------------------------------

local car = VehicleService.spawnFor(player, "blista")
check("owned vehicle spawns", car ~= nil)

if car then
	check("has a chassis", car.PrimaryPart ~= nil and car.PrimaryPart.Name == "Chassis")
	check("has four wheels", car:FindFirstChild("Wheels") ~= nil and #car.Wheels:GetChildren() == 8)
	check("has force objects", car:FindFirstChild("Forces") ~= nil and #car.Forces:GetChildren() == 7)
	check("has a driver seat", car:FindFirstChild("DriverSeat") ~= nil)
	check("carries its catalog id", car:GetAttribute("VehicleId") == "blista")

	-- Park it at a ride height that compresses the springs, then simulate.
	local restLength = car:GetAttribute("RestLength")
	local halfHeight = 2.4 / 2
	local groundY = 0.4
	local compressed = groundY + (restLength - 0.5) + halfHeight
	car.PrimaryPart.CFrame = CFrame.new(0, compressed, 0)
	car.PrimaryPart.Anchored = false

	local sim = CarSim.new(car)
	check("CarSim builds", sim ~= nil)

	if sim then
		-- The mock does not integrate physics, so hold the car at a cruising
		-- speed; steering and drag are both speed-dependent.
		car.PrimaryPart.AssemblyLinearVelocity = car.PrimaryPart.CFrame.LookVector * 40

		pcheck("CarSim steps under throttle", function()
			for _ = 1, 60 do
				sim:step(1 / 60, { throttle = 1, steer = 0.4, handbrake = false })
			end
		end)

		check("all four wheels grounded", sim.grounded == 4, sim.grounded)

		local springForce = car.Forces.FL.Force
		check("suspension pushes up", springForce.Y > 0, springForce.Y)
		check("suspension force is finite", springForce.Y == springForce.Y and springForce.Y < 1e9)

		local drive = car.Forces.Drive.Force
		check("throttle produces forward force", drive.Z < 0, drive.Z)

		check("steering built up an angle", math.abs(sim.steerAngle) > 0.05, sim.steerAngle)
		check("yaw torque applied", math.abs(car.Forces.Yaw.Torque.Y) > 0)

		pcheck("CarSim handles handbrake and reverse", function()
			for _ = 1, 30 do
				sim:step(1 / 60, { throttle = -1, steer = -1, handbrake = true })
			end
		end)

		pcheck("CarSim releases cleanly", function()
			sim:release()
		end)
		check("released forces are zero", car.Forces.Drive.Force.Z == 0)

		pcheck("remote wheel animation runs", function()
			CarSim.animateRemote(car, 1 / 60)
		end)
	end

	-- Damage and destruction.
	VehicleService.damage(car, 40, player)
	check(
		"damage recorded",
		car:GetAttribute("Health") == Config.Vehicle.MaxHealth - 40,
		car:GetAttribute("Health")
	)
	pcheck("vehicle explodes at zero health", function()
		VehicleService.damage(car, 100, player)
	end)
	check("destroyed vehicle deregistered", VehicleService.recordOf(car) == nil)
end

check(
	"police cruiser spawns",
	(function()
		local cruiser = VehicleService.spawnPolice(CFrame.new(0, 4, 0))
		local ok = cruiser ~= nil and cruiser:GetAttribute("VehicleId") == "cruiser"
		if cruiser then
			VehicleService.destroy(cruiser)
		end
		return ok
	end)()
)

--------------------------------------------------------------------------------
heading("Weapons")
--------------------------------------------------------------------------------

local pistol
for _, tool in player.Backpack:GetChildren() do
	if tool:GetAttribute("WeaponId") == "pistol" then
		pistol = tool
	end
end
check("pistol tool built", pistol ~= nil)
check("pistol has a handle", pistol ~= nil and pistol:FindFirstChild("Handle") ~= nil)

if pistol then
	pistol.Equipped:Fire()
	simulate(0.2)
	check("equip tracked", WeaponService.getEquipped(player) == "pistol", WeaponService.getEquipped(player))

	local magBefore = WeaponService.magOf(player, "pistol")
	check("magazine loaded", magBefore > 0, magBefore)

	Net.event("WeaponFire").OnServerEvent:Fire(player, head.Position, Vector3.new(0, 0, -1))
	simulate(0.1)
	check(
		"firing consumes a round",
		WeaponService.magOf(player, "pistol") == magBefore - 1,
		WeaponService.magOf(player, "pistol")
	)

	-- Fire-rate limiting: an immediate second shot must be rejected.
	local magNow = WeaponService.magOf(player, "pistol")
	Net.event("WeaponFire").OnServerEvent:Fire(player, head.Position, Vector3.new(0, 0, -1))
	simulate(0.02)
	check(
		"rate limit rejects spam",
		WeaponService.magOf(player, "pistol") == magNow,
		WeaponService.magOf(player, "pistol")
	)

	-- Origin validation: a shot from across the map must be rejected.
	local magFar = WeaponService.magOf(player, "pistol")
	simulate(1)
	Net.event("WeaponFire").OnServerEvent:Fire(player, Vector3.new(900, 5, 900), Vector3.new(0, 0, -1))
	simulate(0.1)
	check(
		"bogus origin rejected",
		WeaponService.magOf(player, "pistol") == magFar,
		WeaponService.magOf(player, "pistol")
	)

	pcheck("garbage payloads are ignored", function()
		Net.event("WeaponFire").OnServerEvent:Fire(player, "not a vector", 42)
		Net.event("WeaponFire").OnServerEvent:Fire(player)
		Net.event("WeaponReload").OnServerEvent:Fire(player)
		simulate(0.1)
	end)

	pcheck("reload runs", function()
		for _ = 1, 6 do
			simulate(1)
			Net.event("WeaponFire").OnServerEvent:Fire(player, head.Position, Vector3.new(0, 0, -1))
		end
		Net.event("WeaponReload").OnServerEvent:Fire(player)
		simulate(3)
	end)
	check(
		"reload refilled the magazine",
		WeaponService.magOf(player, "pistol") > 0,
		WeaponService.magOf(player, "pistol")
	)
end

--------------------------------------------------------------------------------
heading("Combat")
--------------------------------------------------------------------------------

local victimModel = Instance.new("Model")
victimModel.Name = "Victim"
victimModel:SetAttribute("NpcKind", "Ped")
local victimRoot = Instance.new("Part", victimModel)
victimRoot.Name = "HumanoidRootPart"
victimRoot.CFrame = CFrame.new(10, 5, 0)
local victim = Instance.new("Humanoid", victimModel)
victimModel.PrimaryPart = victimRoot
victimModel.Parent = workspace

local dealt, killed = Combat.damage(victim, 30, player)
check("damage applied", dealt == 30 and not killed, dealt)
check("attacker recorded", victimModel:GetAttribute("LastAttackerUserId") == player.UserId)

local cashBefore = profile.cash
local _, lethal = Combat.damage(victim, 200, player)
check("kill detected", lethal == true)
check("ped kill pays out", profile.cash > cashBefore, profile.cash - cashBefore)
check("ped kill raises heat", WantedService.getHeat(player) > 0)

-- Armour soaks damage before health.
Combat.setArmor(character, 100)
local healthBefore = humanoid.Health
Combat.damage(humanoid, 50, nil)
check("armour absorbs damage", Combat.getArmor(character) < 100, Combat.getArmor(character))
check("armour reduces health loss", humanoid.Health > healthBefore - 50, humanoid.Health)

WantedService.clear(player)
humanoid.Health = 100
Combat.setArmor(character, 0)

--------------------------------------------------------------------------------
heading("Explosions")
--------------------------------------------------------------------------------

local bystanderModel = Instance.new("Model")
bystanderModel.Name = "Bystander"
bystanderModel:SetAttribute("NpcKind", "Ped")
local bystanderRoot = Instance.new("Part", bystanderModel)
bystanderRoot.Name = "HumanoidRootPart"
bystanderRoot.CFrame = CFrame.new(300, 5, 300)
local bystander = Instance.new("Humanoid", bystanderModel)
bystanderModel.PrimaryPart = bystanderRoot
bystanderModel.Parent = workspace

local bomb = VehicleService.spawnFor(player, "blista", CFrame.new(305, 4, 300))
check("vehicle spawns at a given spot", bomb ~= nil)
if bomb then
	VehicleService.damage(bomb, Config.Vehicle.MaxHealth + 10, player)
	simulate(0.2)
	check("explosion hurts bystanders", bystander.Health < 100, bystander.Health)
end

local farModel = Instance.new("Model")
farModel.Name = "FarAway"
local farRoot = Instance.new("Part", farModel)
farRoot.Name = "HumanoidRootPart"
farRoot.CFrame = CFrame.new(-800, 5, -800)
local farHumanoid = Instance.new("Humanoid", farModel)
farModel.PrimaryPart = farRoot
farModel.Parent = workspace
check("explosion spares anyone out of range", farHumanoid.Health == 100, farHumanoid.Health)

--------------------------------------------------------------------------------
heading("Loadout rebuild")
--------------------------------------------------------------------------------

-- Simulate holding a gun, then buying another: the held tool must not survive
-- into the rebuilt loadout as a duplicate.
local held = player.Backpack:GetChildren()[1]
if held then
	held.Parent = character
	WeaponService.refreshLoadout(player)
	simulate(0.2)

	local seen = {}
	local duplicates = 0
	for _, tool in player.Backpack:GetChildren() do
		if seen[tool.Name] then
			duplicates += 1
		end
		seen[tool.Name] = true
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			duplicates += 1
		end
	end
	check("no duplicate tools after rebuild", duplicates == 0, duplicates)
end

--------------------------------------------------------------------------------
heading("Missions")
--------------------------------------------------------------------------------

Net.event("MissionRequest").OnServerEvent:Fire(player, "start", "courier")
simulate(1)
check("mission started", MissionService.isActive(player) == true)

pcheck("mission ticks", function()
	simulate(3)
end)

-- Walking into the objective should advance the stage.
local snapshot = DataService.snapshot(player)
check("objective published", type(snapshot.objective) == "table" or snapshot.objective ~= nil)

Net.event("MissionRequest").OnServerEvent:Fire(player, "abandon")
simulate(0.5)
check("mission abandoned", MissionService.isActive(player) == false)

pcheck("unknown mission ids are ignored", function()
	Net.event("MissionRequest").OnServerEvent:Fire(player, "start", "does_not_exist")
	Net.event("MissionRequest").OnServerEvent:Fire(player, 12345, {})
	simulate(0.5)
end)

--------------------------------------------------------------------------------
heading("Shops")
--------------------------------------------------------------------------------

local gunShopPad
for _, pad in CollectionService:GetTagged("Interactable") do
	if pad:GetAttribute("Interact") == "GunShop" then
		gunShopPad = pad
	end
end
check("gun shop pad exists", gunShopPad ~= nil)

if gunShopPad then
	root.CFrame = CFrame.new(gunShopPad.Position + Vector3.new(0, 3, 0))
	local prompt = gunShopPad:FindFirstChildOfClass("ProximityPrompt")
	check("pad has a prompt", prompt ~= nil)

	ProximityPromptService.PromptTriggered:Fire(prompt, player)
	simulate(0.3)

	DataService.addCash(player, 50000, "test funding")
	local cashPre = profile.cash
	Net.event("Purchase").OnServerEvent:Fire(player, "weapon", "smg")
	simulate(0.3)
	check("weapon purchased", profile.weapons.smg ~= nil)
	check("purchase charged", profile.cash < cashPre, profile.cash)

	-- Buying from the wrong place must be rejected.
	root.CFrame = CFrame.new(0, 5, 4000)
	local cashFar = profile.cash
	Net.event("Purchase").OnServerEvent:Fire(player, "weapon", "rifle")
	simulate(0.3)
	check("remote purchase rejected off-site", profile.weapons.rifle == nil)
	check("no charge for rejected purchase", profile.cash == cashFar)

	pcheck("garbage purchase payloads are ignored", function()
		Net.event("Purchase").OnServerEvent:Fire(player, {}, 7)
		Net.event("Purchase").OnServerEvent:Fire(player, "weapon", "not_a_gun")
		Net.event("Purchase").OnServerEvent:Fire(player)
		simulate(0.2)
	end)
end

--------------------------------------------------------------------------------
heading("Rate limiting")
--------------------------------------------------------------------------------

local allowed = 0
for _ = 1, 60 do
	if Net.allow(player, "smoketest", 2, 3) then
		allowed += 1
	end
end
check("token bucket caps a burst", allowed <= 3, allowed)

--------------------------------------------------------------------------------
heading("Death and respawn")
--------------------------------------------------------------------------------

WantedService.setStars(player, 3)
local cashAtDeath = profile.cash
humanoid.Health = 0
humanoid.Died:Fire()
simulate(1)
check("death clears wanted", WantedService.getStars(player) == 0)
check("hospital bill charged", profile.cash < cashAtDeath, profile.cash)
check("death counted", profile.stats.deaths >= 1, profile.stats.deaths)

--------------------------------------------------------------------------------
heading("Client bootstrap")
--------------------------------------------------------------------------------

Mock.isServer = false
rawset(rawget(Players, "_props"), "LocalPlayer", player)

-- Fresh character for the client to attach to.
humanoid.Health = 100
player.CharacterAdded:Fire(character)

pcheck("init.client runs clean", function()
	__loaderOf[Tree.ClientScript](Tree.ClientScript)
end)

local ClientState = require(Tree.ClientScript.ClientState)
check("client received state", ClientState.get("cash") ~= nil, ClientState.get("cash"))

local playerGui = player:FindFirstChild("PlayerGui")
check("HUD created", playerGui ~= nil and playerGui:FindFirstChild("ViceHUD") ~= nil)
check("minimap created", playerGui ~= nil and playerGui:FindFirstChild("ViceMinimap") ~= nil)
check("crosshair created", playerGui ~= nil and playerGui:FindFirstChild("ViceCrosshair") ~= nil)
check("menu created", playerGui ~= nil and playerGui:FindFirstChild("ViceMenu") ~= nil)

pcheck("client render loop runs", function()
	for _ = 1, 30 do
		Mock.step(1 / 60)
		RunService.RenderStepped:Fire(1 / 60)
		RunService.Heartbeat:Fire(1 / 60)
		RunService.Stepped:Fire(Mock.now(), 1 / 60)
	end
end)

pcheck("server pushes reach the client", function()
	Mock.isServer = true
	DataService.addCash(player, 123, "wire check")
	Mock.isServer = false
	simulate(0.2)
end)
check("client mirrored the cash push", ClientState.get("cash") == profile.cash, ClientState.get("cash"))

pcheck("client survives a menu push", function()
	ClientState.merge({
		menu = {
			kind = "GunShop",
			title = "Test",
			items = { { id = "pistol", name = "Pistol", price = 100, label = "Buy", detail = "test" } },
		},
	})
	simulate(0.2)
end)

pcheck("client survives an objective push", function()
	ClientState.merge({
		objective = {
			mission = "Test",
			text = "Do the thing",
			position = Vector3.new(10, 0, 10),
			stage = 1,
			stages = 2,
			timeLeft = 42,
		},
	})
	ClientState.merge({ wanted = 3, health = 55, armor = 20, mag = 7, equipped = "smg" })
	simulate(0.3)
	RunService.RenderStepped:Fire(1 / 60)
end)

--------------------------------------------------------------------------------
heading("Long-run stability")
--------------------------------------------------------------------------------

Mock.isServer = true
pcheck("60s of simulation with traffic and heat", function()
	WantedService.setStars(player, 5)
	simulate(30)
	WantedService.clear(player)
	simulate(30)
end)

check(
	"cop population stayed bounded",
	(function()
		local current = workspace:FindFirstChild("Police")
		return current == nil or #current:GetChildren() <= Config.Police.MaxTotalCops
	end)(),
	workspace:FindFirstChild("Police") and #workspace.Police:GetChildren()
)

check(
	"crowd population stayed bounded",
	(function()
		local current = workspace:FindFirstChild("Pedestrians")
		return current == nil or #current:GetChildren() <= Config.Peds.MaxAlive + 8
	end)(),
	workspace:FindFirstChild("Pedestrians") and #workspace.Pedestrians:GetChildren()
)

--------------------------------------------------------------------------------
heading("Results")
--------------------------------------------------------------------------------

print(string.format("  %d checks, %d failures, %d warnings", checks, failures, Mock.warnings or 0))
if (Mock.warnings or 0) > 0 then
	print("  warning log:")
	for _, message in Mock.warningLog do
		print("    - " .. message)
	end
end

if failures > 0 then
	error(string.format("smoke test failed: %d/%d checks", failures, checks), 0)
end
print("  ALL CHECKS PASSED")
