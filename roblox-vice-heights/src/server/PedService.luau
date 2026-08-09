--!nonstrict
--[[
	PedService
	Keeps a believable crowd around wherever players actually are: spawns
	pedestrians on nearby pavement, wanders them between destinations, scatters
	them when shots are fired, and recycles them once they are out of sight.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CityGrid = require(Shared.CityGrid)
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local Combat = require(script.Parent.Combat)
local RigFactory = require(script.Parent.RigFactory)
local WeaponService = require(script.Parent.WeaponService)

local PedService = {}

type Ped = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	nextThink: number,
	panicUntil: number,
	fleeFrom: Vector3?,
	baseSpeed: number,
}

local peds: { [Model]: Ped } = {}
local folder: Folder
local rng = Random.new(Config.Game.Seed + 31)
local aliveCount = 0

local P = Config.Peds

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function anchorPlayer(): (Player?, Vector3?)
	local candidates = {}
	for _, player in Players:GetPlayers() do
		local root = Util.rootOf(player.Character)
		if root then
			table.insert(candidates, { player, root.Position })
		end
	end
	if #candidates == 0 then
		return nil, nil
	end
	local pick = candidates[rng:NextInteger(1, #candidates)]
	return pick[1], pick[2]
end

local function distanceToNearestPlayer(position: Vector3): number
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local root = Util.rootOf(player.Character)
		if root then
			best = math.min(best, (root.Position - position).Magnitude)
		end
	end
	return best
end

--- A pavement point a sensible distance from `origin`.
local function spawnPointNear(origin: Vector3): Vector3?
	for _ = 1, 16 do
		local point = CityGrid.randomSidewalkPoint(rng)
		local distance = (Vector3.new(point.X, origin.Y, point.Z) - origin).Magnitude
		if distance >= P.SpawnRadius.Min and distance <= P.SpawnRadius.Max then
			return Vector3.new(point.X, point.Y + 3.5, point.Z)
		end
	end
	return nil
end

local function despawn(model: Model)
	local ped = peds[model]
	if not ped then
		return
	end
	peds[model] = nil
	aliveCount -= 1
	if model.Parent then
		model:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

local function spawnOne()
	local _, anchor = anchorPlayer()
	if not anchor then
		return
	end

	local point = spawnPointNear(anchor)
	if not point then
		return
	end

	local model = RigFactory.pedestrian(rng)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart

	model:PivotTo(CFrame.new(point) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
	model.Parent = folder

	peds[model] = {
		model = model,
		humanoid = humanoid,
		root = root,
		nextThink = 0,
		panicUntil = 0,
		fleeFrom = nil,
		baseSpeed = humanoid.WalkSpeed,
	}
	aliveCount += 1

	humanoid.Died:Connect(function()
		-- Leave the body around briefly, then recycle.
		task.delay(8, function()
			despawn(model)
		end)
	end)
end

--------------------------------------------------------------------------------
-- Behaviour
--------------------------------------------------------------------------------

local function wander(ped: Ped)
	local from = ped.root.Position
	for _ = 1, 8 do
		local point = CityGrid.randomSidewalkPoint(rng)
		local target = Vector3.new(point.X, point.Y + 3, point.Z)
		local distance = (target - from).Magnitude
		if distance > 25 and distance < 140 then
			ped.humanoid:MoveTo(target)
			return
		end
	end
	ped.humanoid:MoveTo(from + Vector3.new(rng:NextNumber(-30, 30), 0, rng:NextNumber(-30, 30)))
end

local function flee(ped: Ped)
	local away = ped.root.Position - (ped.fleeFrom or ped.root.Position)
	if away.Magnitude < 1 then
		away = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	end
	away = Util.horizontal(away).Unit * 70
	ped.humanoid:MoveTo(ped.root.Position + away)
end

local function think(ped: Ped, now: number)
	if ped.humanoid.Health <= 0 then
		return
	end

	if now < ped.panicUntil then
		ped.humanoid.WalkSpeed = P.FleeSpeed
		flee(ped)
		ped.nextThink = now + 1.2
		return
	end

	ped.humanoid.WalkSpeed = ped.baseSpeed
	wander(ped)
	ped.nextThink = now + rng:NextNumber(3.5, 8)
end

--- Scatters everyone who heard a shot.
function PedService.panic(position: Vector3, radius: number?)
	local reach = radius or P.PanicRadius
	local now = os.clock()
	for _, ped in peds do
		if ped.humanoid.Health > 0 and (ped.root.Position - position).Magnitude <= reach then
			ped.panicUntil = now + P.PanicDuration
			ped.fleeFrom = position
			ped.nextThink = 0
		end
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function PedService.start()
	folder = Instance.new("Folder")
	folder.Name = "Pedestrians"
	folder.Parent = Workspace

	WeaponService.onGunshot(function(position)
		PedService.panic(position)
	end)

	-- A ped watching someone die is just as good a reason to run.
	Combat.onKill(function(humanoid)
		local root = Util.rootOf(humanoid.Parent)
		if root then
			PedService.panic(root.Position, 60)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(P.SpawnInterval)
			if aliveCount < P.MaxAlive and #Players:GetPlayers() > 0 then
				local ok, err = pcall(spawnOne)
				if not ok then
					warn("PedService: spawn failed - " .. tostring(err))
				end
			end
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.5 then
			return
		end
		accumulator = 0

		local now = os.clock()
		for model, ped in peds do
			if not model.Parent or not ped.root.Parent then
				peds[model] = nil
				aliveCount -= 1
				continue
			end
			if ped.humanoid.Health <= 0 then
				continue
			end
			if distanceToNearestPlayer(ped.root.Position) > P.DespawnRadius then
				despawn(model)
				continue
			end
			if now >= ped.nextThink then
				think(ped, now)
			end
		end
	end)
end

return PedService
