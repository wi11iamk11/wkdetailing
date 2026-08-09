--!nonstrict
--[[
	RigFactory
	Builds R6 character rigs from primitives so the game ships with zero asset
	dependencies. Pedestrians and police are both made here.

	The joint offsets below are the canonical R6 values; changing them will make
	limbs detach visually from the torso.
]]

local PhysicsService = game:GetService("PhysicsService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local RigFactory = {}

RigFactory.CollisionGroup = "NPC"

-- Roblox's public R6 animation set. Loading is wrapped in pcall so the game
-- still runs (rigs just slide) if the assets are unavailable.
local ANIMATIONS = {
	idle = "rbxassetid://180435571",
	walk = "rbxassetid://180426354",
	jump = "rbxassetid://125750702",
	fall = "rbxassetid://180436148",
}

local RIGHT = CFrame.new(0, 0, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0)
local LEFT = CFrame.new(0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0)
local FLIP = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0)

local groupReady = false
local groupUsable = false

function RigFactory.ensureCollisionGroup()
	if groupReady then
		return
	end
	groupReady = true
	-- Assigning a part to a group that was never registered throws, so the
	-- group is only used if registration actually succeeded.
	groupUsable = pcall(function()
		PhysicsService:RegisterCollisionGroup(RigFactory.CollisionGroup)
		-- NPCs walk through each other instead of forming shoving matches.
		PhysicsService:CollisionGroupSetCollidable(
			RigFactory.CollisionGroup,
			RigFactory.CollisionGroup,
			false
		)
	end)
	if not groupUsable then
		warn("RigFactory: NPC collision group unavailable; crowds will jostle")
	end
end

local function npcGroup(): string?
	return groupUsable and RigFactory.CollisionGroup or nil
end

local function limb(name: string, size: Vector3, color: Color3, parent: Model): BasePart
	return Util.part({
		Name = name,
		Size = size,
		Color = color,
		Anchored = false,
		CanCollide = true,
		Material = Enum.Material.SmoothPlastic,
		CollisionGroup = npcGroup(),
		Parent = parent,
	})
end

local function motor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1
	joint.Parent = part0
end

local function playAnimations(humanoid: Humanoid)
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	local tracks: { [string]: AnimationTrack } = {}
	for name, id in ANIMATIONS do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Core
			track.Looped = (name == "idle" or name == "walk")
			tracks[name] = track
		end
	end

	if not tracks.idle and not tracks.walk then
		return -- animations unavailable; rig still functions
	end

	local current: AnimationTrack? = nil
	local function switch(track: AnimationTrack?, speed: number?)
		if track == current then
			if track and speed then
				track:AdjustSpeed(speed)
			end
			return
		end
		if current then
			current:Stop(0.15)
		end
		current = track
		if track then
			track:Play(0.15)
			track:AdjustSpeed(speed or 1)
		end
	end

	humanoid.Running:Connect(function(speed)
		if speed > 0.5 then
			switch(tracks.walk, math.clamp(speed / 14, 0.5, 2.2))
		else
			switch(tracks.idle, 1)
		end
	end)

	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Freefall then
			switch(tracks.fall, 1)
		elseif new == Enum.HumanoidStateType.Jumping then
			switch(tracks.jump, 1)
		end
	end)

	switch(tracks.idle, 1)
end

--- Builds a complete R6 rig. `look` controls colouring only.
function RigFactory.build(name: string, look: { shirt: Color3, pants: Color3, skin: Color3 }): Model
	RigFactory.ensureCollisionGroup()

	local model = Instance.new("Model")
	model.Name = name

	local root = limb("HumanoidRootPart", Vector3.new(2, 2, 1), look.shirt, model)
	root.Transparency = 1
	root.CanCollide = false

	local torso = limb("Torso", Vector3.new(2, 2, 1), look.shirt, model)
	local head = limb("Head", Vector3.new(2, 1, 1), look.skin, model)
	local rightArm = limb("Right Arm", Vector3.new(1, 2, 1), look.skin, model)
	local leftArm = limb("Left Arm", Vector3.new(1, 2, 1), look.skin, model)
	local rightLeg = limb("Right Leg", Vector3.new(1, 2, 1), look.pants, model)
	local leftLeg = limb("Left Leg", Vector3.new(1, 2, 1), look.pants, model)

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = head

	for _, side in { -0.28, 0.28 } do
		local eye = Util.part({
			Name = "Eye",
			Size = Vector3.new(0.16, 0.16, 0.08),
			Color = Color3.fromRGB(24, 24, 28),
			Anchored = false,
			CanCollide = false,
			Massless = true,
			CollisionGroup = npcGroup(),
			CFrame = head.CFrame * CFrame.new(side, 0.12, -0.62),
			Parent = model,
		})
		Util.weld(head, eye)
	end

	motor("RootJoint", root, torso, FLIP, FLIP)
	motor("Neck", torso, head, CFrame.new(0, 1, 0) * FLIP, CFrame.new(0, -0.5, 0) * FLIP)
	motor("Right Shoulder", torso, rightArm, CFrame.new(1, 0.5, 0) * RIGHT, CFrame.new(-0.5, 0.5, 0) * RIGHT)
	motor("Left Shoulder", torso, leftArm, CFrame.new(-1, 0.5, 0) * LEFT, CFrame.new(0.5, 0.5, 0) * LEFT)
	motor("Right Hip", torso, rightLeg, CFrame.new(1, -1, 0) * RIGHT, CFrame.new(0.5, 1, 0) * RIGHT)
	motor("Left Hip", torso, leftLeg, CFrame.new(-1, -1, 0) * LEFT, CFrame.new(-0.5, 1, 0) * LEFT)

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = Config.Peds.Health
	humanoid.Health = Config.Peds.Health
	humanoid.WalkSpeed = 10
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	-- Streams in whole; a half-arrived pedestrian is worse than none.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- Deferred so the caller has parented the rig before we try to play
	-- anything, and guarded so a bad animation asset costs us motion, not NPCs.
	task.defer(function()
		if model.Parent and humanoid.Parent then
			local ok, err = pcall(playAnimations, humanoid)
			if not ok then
				warn("RigFactory: animation setup failed - " .. tostring(err))
			end
		end
	end)

	return model
end

local function pick(list: { any }, rng: Random)
	return list[rng:NextInteger(1, #list)]
end

function RigFactory.pedestrian(rng: Random): Model
	local shirt = pick(Config.Peds.Shirts, rng)
	local model = RigFactory.build("Pedestrian", {
		shirt = shirt,
		pants = Color3.fromRGB(52, 56, 64),
		skin = pick(Config.Peds.Skins, rng),
	})
	model:SetAttribute("NpcKind", "Ped")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	humanoid.WalkSpeed = rng:NextNumber(Config.Peds.WalkSpeed.Min, Config.Peds.WalkSpeed.Max)
	return model
end

function RigFactory.officer(rng: Random, health: number): Model
	local model = RigFactory.build("Officer", {
		shirt = Color3.fromRGB(38, 54, 96),
		pants = Color3.fromRGB(28, 32, 44),
		skin = pick(Config.Peds.Skins, rng),
	})
	model:SetAttribute("NpcKind", "Cop")

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.WalkSpeed = 17

	-- Peaked cap so officers read as police at a distance.
	local head = model:FindFirstChild("Head") :: BasePart
	local cap = Util.part({
		Name = "Cap",
		Size = Vector3.new(2.1, 0.45, 2.1),
		Color = Color3.fromRGB(24, 30, 46),
		Anchored = false,
		CanCollide = false,
		Massless = true,
		CollisionGroup = npcGroup(),
		CFrame = head.CFrame * CFrame.new(0, 0.62, 0),
		Parent = model,
	})
	Util.weld(head, cap)

	-- A sidearm, purely cosmetic; damage is dealt by PoliceService.
	local torso = model:FindFirstChild("Torso") :: BasePart
	local gun = Util.part({
		Name = "Sidearm",
		Size = Vector3.new(0.3, 0.7, 1.5),
		Color = Color3.fromRGB(38, 40, 46),
		Anchored = false,
		CanCollide = false,
		Massless = true,
		CFrame = torso.CFrame * CFrame.new(1.5, -0.4, -0.9),
		Parent = model,
	})
	local rightArm = model:FindFirstChild("Right Arm") :: BasePart
	Util.weld(rightArm, gun)

	return model
end

return RigFactory
