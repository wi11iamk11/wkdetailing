--!nonstrict
--[[
	Minimap
	A north-up radar. The street grid is drawn once from CityGrid (the same data
	the world was built from, so the map can never be out of date), then the
	whole map is slid under a fixed centre point as the player moves.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CityGrid = require(Shared.CityGrid)
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local ClientState = require(script.Parent.ClientState)
local UiKit = require(script.Parent.UiKit)

local Minimap = {}

local player = Players.LocalPlayer
local SIZE = 190
local HALF = SIZE / 2

local scale = SIZE / Config.UI.MinimapRange
local world: Frame
local arrow: ImageLabel | TextLabel
local blipPool: { Frame } = {}
local objectiveBlip: Frame

local LANDMARK_COLORS = {
	GunShop = Color3.fromRGB(226, 96, 72),
	Dealership = Color3.fromRGB(96, 168, 236),
	Garage = Color3.fromRGB(180, 180, 190),
	PoliceStation = Color3.fromRGB(70, 120, 240),
	Hospital = Color3.fromRGB(240, 240, 240),
	MissionBoard = Color3.fromRGB(196, 120, 240),
	Store1 = Color3.fromRGB(240, 200, 90),
	Store2 = Color3.fromRGB(240, 200, 90),
	Store3 = Color3.fromRGB(240, 200, 90),
	Spawn = Color3.fromRGB(126, 217, 87),
}

--- World (x, z) -> pixel offset inside the world frame.
local function toPixels(x: number, z: number): (number, number)
	return (x - CityGrid.Origin) * scale, (z - CityGrid.Origin) * scale
end

local function dot(size: number, color: Color3, parent: Instance, zIndex: number?): Frame
	local frame = UiKit.new("Frame", {
		Size = UDim2.fromOffset(size, size),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = zIndex or 3,
		Parent = parent,
	}) :: Frame
	UiKit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = frame })
	return frame
end

local function buildRoads(parent: Instance)
	for _, segment in CityGrid.roadSegments() do
		local x1, z1 = toPixels(segment.from.X, segment.from.Z)
		local x2, z2 = toPixels(segment.to.X, segment.to.Z)
		local thickness = math.max(2, Config.City.RoadWidth * scale)

		UiKit.new("Frame", {
			Size = UDim2.fromOffset(math.max(thickness, x2 - x1), math.max(thickness, z2 - z1)),
			Position = UDim2.fromOffset(
				segment.horizontal and x1 or x1 - thickness / 2,
				segment.horizontal and z1 - thickness / 2 or z1
			),
			BackgroundColor3 = Color3.fromRGB(96, 98, 104),
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = parent,
		})
	end
end

local function buildLandmarks(parent: Instance)
	for name, entry in CityGrid.Landmarks do
		local color = LANDMARK_COLORS[name]
		if color then
			local center = CityGrid.blockCenter(entry.block[1], entry.block[2])
			local x, z = toPixels(center.X, center.Z)
			local blip = dot(7, color, parent, 4)
			blip.Position = UDim2.fromOffset(x, z)
		end
	end
end

--- Grows the reusable blip pool on demand.
local function blipAt(index: number): Frame
	local blip = blipPool[index]
	if not blip then
		blip = dot(6, Color3.fromRGB(226, 72, 72), world, 5)
		blipPool[index] = blip
	end
	return blip
end

--------------------------------------------------------------------------------
-- Live update
--------------------------------------------------------------------------------

local function refreshDynamic()
	local used = 0

	-- Police on your tail.
	local police = workspace:FindFirstChild("Police")
	if police then
		for _, model in police:GetChildren() do
			local root = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if root and humanoid and humanoid.Health > 0 then
				used += 1
				local blip = blipAt(used)
				local x, z = toPixels(root.Position.X, root.Position.Z)
				blip.Position = UDim2.fromOffset(x, z)
				blip.BackgroundColor3 = Color3.fromRGB(226, 72, 72)
				blip.Visible = true
			end
		end
	end

	-- Vehicles you own that are out in the world.
	for _, model in CollectionService:GetTagged("Vehicle") do
		if model:IsA("Model") and model:GetAttribute("OwnerUserId") == player.UserId then
			local chassis = model.PrimaryPart
			if chassis then
				used += 1
				local blip = blipAt(used)
				local x, z = toPixels(chassis.Position.X, chassis.Position.Z)
				blip.Position = UDim2.fromOffset(x, z)
				blip.BackgroundColor3 = Config.UI.Cash
				blip.Visible = true
			end
		end
	end

	for index = used + 1, #blipPool do
		blipPool[index].Visible = false
	end

	-- Current objective.
	local objective = ClientState.get("objective")
	if type(objective) == "table" and typeof(objective.position) == "Vector3" then
		local x, z = toPixels(objective.position.X, objective.position.Z)
		objectiveBlip.Position = UDim2.fromOffset(x, z)
		objectiveBlip.Visible = true
	else
		objectiveBlip.Visible = false
	end
end

function Minimap.start()
	local screen = UiKit.screen("ViceMinimap", 5)

	local frame = UiKit.panel({
		Name = "Minimap",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 24, 1, -56),
		Size = UDim2.fromOffset(SIZE, SIZE),
		BackgroundColor3 = Color3.fromRGB(28, 32, 28),
		BackgroundTransparency = 0.1,
		ClipsDescendants = true,
		Parent = screen,
	})

	UiKit.new("UIStroke", {
		Color = Color3.fromRGB(12, 13, 16),
		Thickness = 2,
		Parent = frame,
	})

	world = UiKit.new("Frame", {
		Name = "World",
		Size = UDim2.fromOffset(CityGrid.Extent * scale, CityGrid.Extent * scale),
		BackgroundTransparency = 1,
		Parent = frame,
	}) :: Frame

	buildRoads(world)
	buildLandmarks(world)

	objectiveBlip = dot(9, Config.UI.Accent, world, 6)
	objectiveBlip.Visible = false

	-- The player stays pinned to the centre; the map moves underneath.
	arrow = UiKit.text({
		Name = "Player",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(HALF, HALF),
		Size = UDim2.fromOffset(18, 18),
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "\u{25B2}",
		ZIndex = 8,
		Parent = frame,
	})

	local sinceDynamic = 0
	RunService.RenderStepped:Connect(function(dt)
		local root = Util.rootOf(player.Character)
		if not root then
			return
		end

		local px, pz = toPixels(root.Position.X, root.Position.Z)
		world.Position = UDim2.fromOffset(HALF - px, HALF - pz)

		-- North-up map, so the arrow carries the heading.
		local look = root.CFrame.LookVector
		arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))

		sinceDynamic += dt
		if sinceDynamic >= 0.12 then
			sinceDynamic = 0
			refreshDynamic()
		end
	end)
end

return Minimap
