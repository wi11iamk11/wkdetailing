--!nonstrict
--[[
	MissionService
	Runs the mission state machine described by MissionCatalog. Each mission is
	an ordered list of stages; this module knows how to enter, evaluate and exit
	each stage kind, so new jobs are added as data rather than code.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CityGrid = require(Shared.CityGrid)
local Config = require(Shared.Config)
local MissionCatalog = require(Shared.MissionCatalog)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local DataService = require(script.Parent.DataService)
local RigFactory = require(script.Parent.RigFactory)
local VehicleService = require(script.Parent.VehicleService)
local WantedService = require(script.Parent.WantedService)

local MissionService = {}

local active: { [Player]: any } = {}
local folder: Folder
local rng = Random.new(os.time() + 53)

--------------------------------------------------------------------------------
-- World helpers
--------------------------------------------------------------------------------

local function resolvePoint(at: string?): Vector3
	if not at or at == "random_road" then
		local point = CityGrid.randomRoadPoint(rng)
		return Vector3.new(point.X, Config.City.GroundY + 3, point.Z)
	end
	local landmark = CityGrid.landmarkPosition(at)
	if landmark then
		return landmark + Vector3.new(0, Config.City.GroundY + 3, -(Config.City.BlockSize * 0.5 + 10))
	end
	local fallback = CityGrid.randomRoadPoint(rng)
	return Vector3.new(fallback.X, Config.City.GroundY + 3, fallback.Z)
end

local function makeMarker(position: Vector3, radius: number): BasePart
	local marker = Util.part({
		Name = "MissionMarker",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(24, radius * 2, radius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, 10, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color = Config.UI.Accent,
		Material = Enum.Material.Neon,
		Transparency = 0.65,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})
	local light = Instance.new("PointLight")
	light.Color = Config.UI.Accent
	light.Range = 40
	light.Brightness = 2
	light.Parent = marker
	return marker
end

local function clearStageObjects(session)
	if session.marker then
		session.marker:Destroy()
		session.marker = nil
	end
	for _, target in session.targets do
		if target.Parent then
			target:Destroy()
		end
	end
	table.clear(session.targets)
end

local function cleanup(player: Player)
	local session = active[player]
	if not session then
		return
	end
	clearStageObjects(session)
	if session.vehicle and session.vehicle.Parent then
		VehicleService.destroy(session.vehicle)
	end
	active[player] = nil
	DataService.push(player, { objective = false })
end

--------------------------------------------------------------------------------
-- Stage lifecycle
--------------------------------------------------------------------------------

local function objectivePayload(session)
	local stage = session.mission.stages[session.stageIndex]
	if not stage then
		return nil
	end
	return {
		mission = session.mission.name,
		text = stage.prompt or "Continue",
		position = session.stagePos,
		stage = session.stageIndex,
		stages = #session.mission.stages,
		timeLeft = session.deadline and math.max(0, session.deadline - os.clock()) or 0,
		extra = session.extraText,
	}
end

local function pushObjective(player: Player, session)
	local payload = objectivePayload(session)
	if payload then
		DataService.push(player, { objective = payload })
	end
end

local function enterStage(player: Player, session)
	local stage = session.mission.stages[session.stageIndex]
	if not stage then
		return
	end

	clearStageObjects(session)
	session.extraText = nil
	session.checkpointIndex = 1
	session.surviveFor = 0

	if stage.kind == "checkpoint" then
		session.checkpoints = {}
		for _ = 1, stage.count or 4 do
			local point = CityGrid.randomRoadPoint(rng)
			table.insert(session.checkpoints, Vector3.new(point.X, Config.City.GroundY + 3, point.Z))
		end
		session.stagePos = session.checkpoints[1]
		session.marker = makeMarker(session.stagePos, stage.radius or 20)
	elseif stage.kind == "eliminate" then
		local root = Util.rootOf(player.Character)
		local origin = root and root.Position or Vector3.zero
		for _ = 1, stage.count or 1 do
			local point = CityGrid.randomSidewalkPoint(rng)
			local target = RigFactory.pedestrian(rng)
			target.Name = "Target"
			target:SetAttribute("NpcKind", "Ped")
			local torso = target:FindFirstChild("Torso") :: BasePart?
			if torso then
				torso.Color = Color3.fromRGB(180, 40, 40)
			end
			target:PivotTo(CFrame.new(Vector3.new(point.X, point.Y + 3.5, point.Z)))
			target.Parent = folder

			local highlight = Instance.new("Highlight")
			highlight.FillColor = Color3.fromRGB(220, 60, 60)
			highlight.FillTransparency = 0.6
			highlight.OutlineColor = Color3.fromRGB(255, 120, 120)
			highlight.Parent = target

			table.insert(session.targets, target)
		end
		session.stagePos = session.targets[1] and session.targets[1]:GetPivot().Position or origin
	else
		session.stagePos = resolvePoint(stage.at)
		session.marker = makeMarker(session.stagePos, stage.radius or 14)

		if stage.spawnVehicle then
			local car =
				VehicleService.spawnStreet(CFrame.new(session.stagePos + Vector3.new(0, 2, 0)), "sultan")
			if car then
				session.vehicle = car
				local highlight = Instance.new("Highlight")
				highlight.FillColor = Config.UI.Accent
				highlight.FillTransparency = 0.75
				highlight.Parent = car
			end
		end
	end

	if stage.wanted then
		WantedService.setStars(player, stage.wanted)
	end

	pushObjective(player, session)
	DataService.notify(player, stage.prompt or "New objective", "info")
end

local function fail(player: Player, reason: string)
	local session = active[player]
	if not session then
		return
	end
	DataService.notify(player, string.format("Mission failed: %s", reason), "bad")
	cleanup(player)
end

local function complete(player: Player)
	local session = active[player]
	if not session then
		return
	end
	local mission = session.mission
	DataService.addCash(player, mission.payout, mission.name)
	DataService.recordMission(player, mission.id)
	DataService.notify(player, string.format("%s complete!", mission.name), "good")
	cleanup(player)
end

local function advance(player: Player, session)
	session.stageIndex += 1
	if session.stageIndex > #session.mission.stages then
		complete(player)
	else
		enterStage(player, session)
	end
end

--------------------------------------------------------------------------------
-- Stage evaluation
--------------------------------------------------------------------------------

local function withinStage(root: BasePart, position: Vector3, radius: number): boolean
	return (Util.horizontal(root.Position - position)).Magnitude <= radius
end

local function evaluate(player: Player, session, dt: number)
	local stage = session.mission.stages[session.stageIndex]
	local root = Util.rootOf(player.Character)
	if not stage or not root then
		return
	end

	local radius = stage.radius or 14

	if stage.kind == "goto" or stage.kind == "collect" then
		if withinStage(root, session.stagePos, radius) then
			if stage.kind == "collect" then
				session.carrying = true
				DataService.notify(player, "Package collected.", "good")
			end
			advance(player, session)
		end
	elseif stage.kind == "deliver" then
		if not withinStage(root, session.stagePos, radius) then
			return
		end
		if stage.requireVehicle then
			local driving = VehicleService.getDriving(player)
			if not driving or (session.vehicle and driving ~= session.vehicle) then
				session.extraText = "Bring the vehicle here"
				return
			end
			if session.vehicle then
				VehicleService.destroy(session.vehicle)
				session.vehicle = nil
			end
		end
		session.carrying = false
		advance(player, session)
	elseif stage.kind == "checkpoint" then
		local point = session.checkpoints[session.checkpointIndex]
		if point and withinStage(root, point, radius) then
			session.checkpointIndex += 1
			local nextPoint = session.checkpoints[session.checkpointIndex]
			if not nextPoint then
				advance(player, session)
				return
			end
			session.stagePos = nextPoint
			if session.marker then
				session.marker:Destroy()
			end
			session.marker = makeMarker(nextPoint, radius)
			session.extraText =
				string.format("Checkpoint %d/%d", session.checkpointIndex - 1, #session.checkpoints)
		end
	elseif stage.kind == "eliminate" then
		local remaining = 0
		for _, target in session.targets do
			local humanoid = target.Parent and target:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				remaining += 1
			end
		end
		session.extraText = string.format("%d remaining", remaining)
		if remaining == 0 then
			advance(player, session)
		end
	elseif stage.kind == "survive" then
		if withinStage(root, session.stagePos, radius) then
			session.surviveFor += dt
			local left = math.max(0, (stage.duration or 15) - session.surviveFor)
			session.extraText = string.format("%s left", Util.clock(left))
			if left <= 0 then
				advance(player, session)
			end
		else
			session.extraText = "Return to the objective"
		end
	elseif stage.kind == "escape" then
		session.extraText = string.format("%d stars", WantedService.getStars(player))
		if not WantedService.isWanted(player) then
			advance(player, session)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function MissionService.start(player: Player, missionId: string)
	if active[player] then
		DataService.notify(player, "Finish your current job first.", "warn")
		return
	end

	local mission = MissionCatalog.get(missionId)
	if not mission then
		return
	end

	local profile = DataService.get(player)
	if not profile then
		return
	end

	local unlocked = false
	for _, candidate in MissionCatalog.available(profile.missions) do
		if candidate.id == missionId then
			unlocked = true
			break
		end
	end
	if not unlocked then
		DataService.notify(player, "That job isn't available yet.", "warn")
		return
	end

	if mission.requireVehicle and not VehicleService.getDriving(player) then
		DataService.notify(player, "You need to be in a vehicle for this one.", "warn")
		return
	end

	active[player] = {
		mission = mission,
		stageIndex = 1,
		deadline = mission.timeLimit and (os.clock() + mission.timeLimit) or nil,
		marker = nil,
		targets = {},
		checkpoints = {},
		checkpointIndex = 1,
		carrying = false,
		surviveFor = 0,
		vehicle = nil,
		stagePos = Vector3.zero,
	}

	if mission.wantedOnStart then
		WantedService.setStars(player, mission.wantedOnStart)
	end

	DataService.notify(player, string.format("%s started.", mission.name), "info")
	enterStage(player, active[player])
end

function MissionService.abandon(player: Player)
	if not active[player] then
		return
	end
	fail(player, "abandoned")
end

function MissionService.isActive(player: Player): boolean
	return active[player] ~= nil
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

-- Named `init` rather than `start` because `MissionService.start` is the
-- mission starter the rest of the game calls.
function MissionService.init()
	folder = Instance.new("Folder")
	folder.Name = "Missions"
	folder.Parent = Workspace

	DataService.registerProvider(function(player)
		local profile = DataService.get(player)
		local list = {}
		if profile then
			for _, mission in MissionCatalog.available(profile.missions) do
				table.insert(list, {
					id = mission.id,
					name = mission.name,
					description = mission.description,
					payout = mission.payout,
					tier = mission.tier,
				})
			end
		end
		-- A client that reconnects mid-job gets its objective back with the
		-- rest of the handshake instead of waiting for the next tick.
		local session = active[player]
		return {
			missionBoard = list,
			objective = session and objectivePayload(session) or false,
		}
	end)

	Net.event("MissionRequest").OnServerEvent:Connect(function(player, action, missionId)
		if not Net.allow(player, "mission", 2, 4) then
			return
		end
		if action == "start" and type(missionId) == "string" then
			MissionService.start(player, missionId)
		elseif action == "abandon" then
			MissionService.abandon(player)
		end
	end)

	Players.PlayerRemoving:Connect(cleanup)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.25 then
			return
		end
		local step = accumulator
		accumulator = 0

		for player, session in active do
			if not player.Parent then
				active[player] = nil
				continue
			end
			if not Util.isAlive(player.Character) then
				fail(player, "you died")
				continue
			end
			if session.deadline and os.clock() > session.deadline then
				fail(player, "out of time")
				continue
			end

			local ok, err = pcall(function()
				evaluate(player, session, step)
			end)
			if not ok then
				warn("MissionService: evaluate failed - " .. tostring(err))
			end

			if active[player] then
				pushObjective(player, session)
			end
		end
	end)
end

return MissionService
