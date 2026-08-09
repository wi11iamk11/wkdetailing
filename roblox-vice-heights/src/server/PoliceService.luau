--!nonstrict
--[[
	PoliceService
	The response to your wanted level.

	Each star tier defines how many officers and cruisers should be hunting a
	player. A slow tick reconciles that against reality — spawning, retargeting
	and retiring officers — while a fast tick drives the cruisers through
	CarSim, the same physics the player's own car uses.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CarSim = require(Shared.CarSim)
local CityGrid = require(Shared.CityGrid)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local Combat = require(script.Parent.Combat)
local PlayerService = require(script.Parent.PlayerService)
local RigFactory = require(script.Parent.RigFactory)
local VehicleService = require(script.Parent.VehicleService)
local WantedService = require(script.Parent.WantedService)

local PoliceService = {}

local POL = Config.Police

type Cop = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	target: Player?,
	role: string, -- "foot" | "driver"
	vehicle: Model?,
	sim: any,
	waypoints: { PathWaypoint },
	waypointIndex: number,
	nextRepath: number,
	nextShot: number,
	bustProgress: number,
	stuckSince: number,
	reverseUntil: number,
	tier: any,
}

local cops: { [Model]: Cop } = {}
local folder: Folder
local rng = Random.new(os.time() + 77)
local copCount = 0
local lastSpawn = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tierFor(stars: number)
	return POL.Tiers[math.clamp(stars, 1, Config.Wanted.MaxStars)]
end

local function assignedTo(player: Player): (number, number)
	local foot, cars = 0, 0
	for _, cop in cops do
		if cop.target == player then
			if cop.role == "driver" and cop.vehicle then
				cars += 1
			else
				foot += 1
			end
		end
	end
	return foot, cars
end

local function retire(model: Model)
	local cop = cops[model]
	if not cop then
		return
	end
	cops[model] = nil
	copCount -= 1
	if cop.vehicle and cop.vehicle.Parent then
		VehicleService.destroy(cop.vehicle)
	end
	if model.Parent then
		model:Destroy()
	end
end

--- A road point the right distance from the target to arrive from off-screen.
local function spawnPointFor(targetPosition: Vector3, onRoad: boolean): Vector3?
	for _ = 1, 24 do
		local point = onRoad and CityGrid.randomRoadPoint(rng) or CityGrid.randomSidewalkPoint(rng)
		local flat = Vector3.new(point.X, targetPosition.Y, point.Z)
		local distance = (flat - targetPosition).Magnitude
		if distance >= POL.SpawnDistance.Min and distance <= POL.SpawnDistance.Max then
			return Vector3.new(point.X, Config.City.GroundY + (onRoad and 4 or 4.5), point.Z)
		end
	end
	return nil
end

local function hasLineOfSight(cop: Cop, targetRoot: BasePart): boolean
	local head = cop.model:FindFirstChild("Head") :: BasePart?
	if not head then
		return false
	end
	local origin = head.Position
	local direction = targetRoot.Position - origin
	if direction.Magnitude > POL.SightRange then
		return false
	end
	local params = Util.filterParams({ cop.model })
	local result = Workspace:Raycast(origin, direction, params)
	if not result then
		return true
	end
	return result.Instance:IsDescendantOf(targetRoot.Parent)
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

local function spawnOfficer(target: Player, position: Vector3, stars: number): Cop?
	local tier = tierFor(stars)
	local model = RigFactory.officer(rng, tier.Health)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart

	model:PivotTo(CFrame.new(position))
	model.Parent = folder

	local cop: Cop = {
		model = model,
		humanoid = humanoid,
		root = root,
		target = target,
		role = "foot",
		vehicle = nil,
		sim = nil,
		waypoints = {},
		waypointIndex = 1,
		nextRepath = 0,
		nextShot = 0,
		bustProgress = 0,
		stuckSince = 0,
		reverseUntil = 0,
		tier = tier,
	}
	cops[model] = cop
	copCount += 1

	humanoid.Died:Connect(function()
		task.delay(10, function()
			retire(model)
		end)
	end)

	return cop
end

local function spawnCruiser(target: Player, position: Vector3, stars: number)
	local cframe = CFrame.new(position)
	local car = VehicleService.spawnPolice(cframe)
	if not car then
		return
	end

	local cop = spawnOfficer(target, position + Vector3.new(0, 2, 0), stars)
	if not cop then
		VehicleService.destroy(car)
		return
	end

	cop.role = "driver"
	cop.vehicle = car
	cop.sim = CarSim.new(car)
	if cop.sim then
		cop.sim:setIgnored({ cop.model, folder })
	end

	local seat = car:FindFirstChild("DriverSeat")
	if seat and seat:IsA("VehicleSeat") then
		task.defer(function()
			if cop.humanoid.Parent and seat.Parent then
				seat:Sit(cop.humanoid)
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Foot behaviour
--------------------------------------------------------------------------------

local function repath(cop: Cop, targetRoot: BasePart)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2.5,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 6,
	})

	local ok = pcall(function()
		path:ComputeAsync(cop.root.Position, targetRoot.Position)
	end)

	if ok and path.Status == Enum.PathStatus.Success then
		cop.waypoints = path:GetWaypoints()
		cop.waypointIndex = 2 -- the first waypoint is where we already stand
	else
		-- Fall back to walking straight at them; better than freezing.
		cop.waypoints = {}
		cop.humanoid:MoveTo(targetRoot.Position)
	end
	cop.nextRepath = os.clock() + POL.RepathInterval
end

local function followPath(cop: Cop, targetRoot: BasePart)
	if #cop.waypoints == 0 then
		cop.humanoid:MoveTo(targetRoot.Position)
		return
	end

	local waypoint = cop.waypoints[cop.waypointIndex]
	if not waypoint then
		cop.waypoints = {}
		return
	end

	if (Util.horizontal(waypoint.Position - cop.root.Position)).Magnitude < 4 then
		cop.waypointIndex += 1
		waypoint = cop.waypoints[cop.waypointIndex]
		if not waypoint then
			cop.waypoints = {}
			return
		end
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		cop.humanoid.Jump = true
	end
	cop.humanoid:MoveTo(waypoint.Position)
end

local function shoot(cop: Cop, target: Player, targetRoot: BasePart, distance: number)
	local now = os.clock()
	if now < cop.nextShot then
		return
	end
	cop.nextShot = now + cop.tier.FireRate * rng:NextNumber(0.85, 1.25)

	-- Face the target so the shot reads as deliberate.
	local look = CFrame.lookAt(
		cop.root.Position,
		Vector3.new(targetRoot.Position.X, cop.root.Position.Y, targetRoot.Position.Z)
	)
	cop.root.CFrame = look

	-- Accuracy falls off with range; a miss still draws a tracer past the ear.
	local rangeFactor = 1 - math.clamp(distance / POL.EngageRange, 0, 1) * 0.45
	local hit = rng:NextNumber() < cop.tier.Accuracy * rangeFactor

	local head = cop.model:FindFirstChild("Head") :: BasePart?
	local origin = head and head.Position or cop.root.Position
	local endPoint = targetRoot.Position

	if hit then
		local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			Combat.damage(humanoid, cop.tier.Damage, nil)
		end
	else
		endPoint += Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(-2, 5), rng:NextNumber(-6, 6))
	end

	local payload = { kind = "tracer", from = origin, to = endPoint, weapon = "police" }
	for _, player in Players:GetPlayers() do
		local root = Util.rootOf(player.Character)
		if root and (root.Position - origin).Magnitude < 400 then
			Net.event("Effect"):FireClient(player, payload)
		end
	end
end

local function tickFoot(cop: Cop, dt: number)
	local target = cop.target
	if not target or not target.Parent then
		retire(cop.model)
		return
	end

	local targetRoot = Util.rootOf(target.Character)
	if not targetRoot or not Util.isAlive(target.Character) then
		cop.bustProgress = 0
		return
	end

	local distance = (targetRoot.Position - cop.root.Position).Magnitude
	local visible = hasLineOfSight(cop, targetRoot)
	if visible and distance <= POL.SightRange then
		WantedService.markSeen(target)
	end

	if distance <= POL.EngageRange and visible then
		cop.humanoid:MoveTo(cop.root.Position)
		shoot(cop, target, targetRoot, distance)

		-- Cornered and bleeding: take them in rather than finish them.
		local humanoid = target.Character:FindFirstChildOfClass("Humanoid")
		if
			humanoid
			and distance <= POL.Bust.Range
			and humanoid.Health <= POL.Bust.HealthThreshold
			and WantedService.isWanted(target)
		then
			cop.bustProgress += dt
			if cop.bustProgress >= POL.Bust.HoldTime then
				cop.bustProgress = 0
				PlayerService.bust(target)
			end
		else
			cop.bustProgress = 0
		end
	else
		cop.bustProgress = 0
		if os.clock() >= cop.nextRepath then
			repath(cop, targetRoot)
		end
		followPath(cop, targetRoot)
	end
end

--------------------------------------------------------------------------------
-- Driving behaviour
--------------------------------------------------------------------------------

local function driveInput(cop: Cop, targetPosition: Vector3): CarSim.Input
	local chassis = cop.vehicle and cop.vehicle.PrimaryPart
	if not chassis then
		return CarSim.ZeroInput
	end

	local cframe = chassis.CFrame
	local toTarget = Util.horizontal(targetPosition - cframe.Position)
	local distance = toTarget.Magnitude
	if distance < 1 then
		return CarSim.ZeroInput
	end

	local localDir = cframe:VectorToObjectSpace(toTarget.Unit)
	local angle = math.atan2(localDir.X, -localDir.Z)
	local steer = math.clamp(angle / 0.7, -1, 1)
	local throttle = 1

	if distance < 60 then
		throttle = 0.35
	end
	if distance < 30 then
		throttle = -0.5 -- ease off and let the officer get out
	end

	-- Reverse out of whatever we drove into.
	local now = os.clock()
	local speed = chassis.AssemblyLinearVelocity.Magnitude
	if speed < 4 and throttle > 0 then
		if cop.stuckSince == 0 then
			cop.stuckSince = now
		elseif now - cop.stuckSince > 2 then
			cop.reverseUntil = now + 1.5
			cop.stuckSince = 0
		end
	else
		cop.stuckSince = 0
	end

	if now < cop.reverseUntil then
		return { throttle = -1, steer = -steer, handbrake = false }
	end

	-- Slow down for anything directly ahead.
	local params = Util.filterParams({ cop.vehicle, cop.model })
	local ahead = Workspace:Raycast(cframe.Position, cframe.LookVector * 28, params)
	if ahead then
		throttle = math.min(throttle, 0.25)
		steer = math.clamp(steer + (localDir.X >= 0 and -0.6 or 0.6), -1, 1)
	end

	return { throttle = throttle, steer = steer, handbrake = false }
end

local function dismount(cop: Cop)
	cop.role = "foot"
	cop.humanoid.Sit = false
	if cop.sim then
		cop.sim:release()
		cop.sim = nil
	end
	local car = cop.vehicle
	cop.vehicle = nil
	if car then
		car:SetAttribute("Abandoned", true)
		task.delay(30, function()
			if car.Parent then
				VehicleService.destroy(car)
			end
		end)
	end
end

local function tickDriver(cop: Cop, dt: number)
	local target = cop.target
	local targetRoot = target and Util.rootOf(target.Character)
	if not targetRoot then
		return
	end
	if not cop.vehicle or not cop.vehicle.Parent or cop.humanoid.Health <= 0 then
		dismount(cop)
		return
	end

	local chassis = cop.vehicle.PrimaryPart
	local distance = (targetRoot.Position - chassis.Position).Magnitude
	if distance < 34 or distance > POL.DespawnDistance then
		dismount(cop)
		return
	end

	WantedService.markSeen(target)
end

--------------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------------

local function reconcile()
	local now = os.clock()
	local wanted = WantedService.wantedPlayers()

	-- Retire anyone whose target went quiet or got too far away.
	for model, cop in cops do
		if not model.Parent then
			cops[model] = nil
			copCount -= 1
			continue
		end
		local target = cop.target
		if not target or not target.Parent or not WantedService.isWanted(target) then
			retire(model)
			continue
		end
		local targetRoot = Util.rootOf(target.Character)
		if targetRoot and (targetRoot.Position - cop.root.Position).Magnitude > POL.DespawnDistance then
			retire(model)
		end
	end

	if now - lastSpawn < 0.45 or copCount >= POL.MaxTotalCops then
		return
	end

	for _, player in wanted do
		local root = Util.rootOf(player.Character)
		if not root or not Util.isAlive(player.Character) then
			continue
		end

		local stars = WantedService.getStars(player)
		local tier = tierFor(stars)
		local foot, cars = assignedTo(player)

		if cars < tier.Cars then
			local point = spawnPointFor(root.Position, true)
			if point then
				spawnCruiser(player, point, stars)
				lastSpawn = now
				return
			end
		end

		if foot < tier.Foot then
			local point = spawnPointFor(root.Position, false)
			if point then
				spawnOfficer(player, point, stars)
				lastSpawn = now
				return
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function PoliceService.start()
	folder = Instance.new("Folder")
	folder.Name = "Police"
	folder.Parent = Workspace

	-- Cruisers are server-simulated, so they need a step every frame.
	RunService.Heartbeat:Connect(function(dt)
		for _, cop in cops do
			if cop.role == "driver" and cop.sim and cop.vehicle and cop.vehicle.Parent then
				local target = cop.target
				local targetRoot = target and Util.rootOf(target.Character)
				if targetRoot and cop.humanoid.Health > 0 then
					cop.sim:step(dt, driveInput(cop, targetRoot.Position))
				else
					cop.sim:step(dt, CarSim.ZeroInput)
				end
			end
		end
	end)

	local decisionClock = 0
	RunService.Heartbeat:Connect(function(dt)
		decisionClock += dt
		if decisionClock < 0.3 then
			return
		end
		local step = decisionClock
		decisionClock = 0

		for model, cop in cops do
			if not model.Parent or cop.humanoid.Health <= 0 then
				continue
			end
			local ok, err = pcall(function()
				if cop.role == "driver" then
					tickDriver(cop, step)
				else
					tickFoot(cop, step)
				end
			end)
			if not ok then
				warn("PoliceService: cop tick failed - " .. tostring(err))
			end
		end

		reconcile()
	end)

	-- Losing your stars calls off the chase immediately.
	WantedService.onChanged(function(player, stars)
		if stars > 0 then
			return
		end
		for model, cop in cops do
			if cop.target == player then
				task.delay(rng:NextNumber(0.5, 2.5), function()
					retire(model)
				end)
			end
		end
	end)
end

return PoliceService
