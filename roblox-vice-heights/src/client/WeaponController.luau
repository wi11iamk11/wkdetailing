--!nonstrict
--[[
	WeaponController
	Aiming, firing, reloading and the crosshair.

	The client picks the direction and draws the feedback; the server decides
	what was hit. Local ammo is a prediction that the next server patch
	overwrites, which keeps the readout snappy without making it authoritative.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)
local WeaponCatalog = require(Shared.WeaponCatalog)

local CameraController = require(script.Parent.CameraController)
local ClientState = require(script.Parent.ClientState)
local Effects = require(script.Parent.Effects)
local MenuUI = require(script.Parent.MenuUI)
local UiKit = require(script.Parent.UiKit)

local WeaponController = {}

local player = Players.LocalPlayer

local firing = false
local lastFire = 0
local equipped = "fists"
local reloadingUntil = 0

local crosshair: Frame
local strokes: { Frame } = {}
local hitmarker: TextLabel
local currentSpread = 0

--------------------------------------------------------------------------------
-- Crosshair
--------------------------------------------------------------------------------

local function buildCrosshair(parent: Instance)
	crosshair = UiKit.new("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Parent = parent,
	}) :: Frame

	local specs = {
		{ UDim2.fromOffset(2, 10), Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0.5), Vector2.new(0, -1) },
		{ UDim2.fromOffset(2, 10), Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0.5), Vector2.new(0, 1) },
		{ UDim2.fromOffset(10, 2), Vector2.new(1, 0.5), UDim2.fromScale(0.5, 0.5), Vector2.new(-1, 0) },
		{ UDim2.fromOffset(10, 2), Vector2.new(0, 0.5), UDim2.fromScale(0.5, 0.5), Vector2.new(1, 0) },
	}

	for index, spec in specs do
		local stroke = UiKit.new("Frame", {
			Name = "Stroke" .. index,
			Size = spec[1],
			AnchorPoint = spec[2],
			Position = spec[3],
			BackgroundColor3 = Color3.fromRGB(240, 240, 244),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = crosshair,
		}) :: Frame
		stroke:SetAttribute("DirX", spec[4].X)
		stroke:SetAttribute("DirY", spec[4].Y)
		table.insert(strokes, stroke)
	end

	hitmarker = UiKit.text({
		Name = "Hitmarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextTransparency = 1,
		Text = "\u{00D7}",
		Parent = crosshair,
	})
end

local function updateCrosshair(dt: number)
	local def = WeaponCatalog.get(equipped)
	if not def then
		return
	end

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local moving = humanoid and humanoid.MoveDirection.Magnitude > 0.1
	local target = 6 + (def.spread or 0) * 260 + (moving and 6 or 0)
	if def.melee then
		target = 4
	end

	currentSpread = Util.damp(currentSpread, target, 0.08, dt)

	for _, stroke in strokes do
		local dx = stroke:GetAttribute("DirX") * currentSpread
		local dy = stroke:GetAttribute("DirY") * currentSpread
		stroke.Position = UDim2.new(0.5, dx, 0.5, dy)
	end

	crosshair.Visible = not MenuUI.isOpen()
end

local function flashHitmarker(killed: boolean)
	hitmarker.TextColor3 = killed and Color3.fromRGB(226, 72, 72) or Color3.fromRGB(255, 255, 255)
	hitmarker.TextTransparency = 0
	task.delay(0.12, function()
		hitmarker.TextTransparency = 1
	end)
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

--- Where the crosshair is actually pointing in the world.
local function aimPoint(range: number, ignore: { Instance }): Vector3
	local camera = Workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	local params = Util.filterParams(ignore)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * range, params)
	return result and result.Position or (ray.Origin + ray.Direction * range)
end

local function tryFire()
	local def = WeaponCatalog.get(equipped)
	if not def or MenuUI.isOpen() then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local head = character and character:FindFirstChild("Head")
	if not humanoid or humanoid.Health <= 0 or not head then
		return
	end
	-- No drive-by shooting; it would need a whole seated aiming rig.
	if humanoid.SeatPart then
		return
	end

	local now = os.clock()
	if now - lastFire < def.fireRate or now < reloadingUntil then
		return
	end

	if not def.melee then
		local mag = ClientState.get("mag") or 0
		if mag <= 0 then
			WeaponController.reload()
			return
		end
		ClientState.merge({ mag = mag - 1 })
	end

	lastFire = now

	local origin = (head :: BasePart).Position
	local target = aimPoint(def.range, { character })
	local direction = (target - origin)
	if direction.Magnitude < 0.01 then
		return
	end
	direction = direction.Unit

	Net.event("WeaponFire"):FireServer(origin, direction)

	if def.loud then
		Effects.muzzleFlash(origin + direction * 2)
		Effects.tracer(origin + direction * 2, target, equipped)
		CameraController.addRecoil(def.recoil or 0)
		currentSpread += 6
	end
end

function WeaponController.reload()
	local def = WeaponCatalog.get(equipped)
	if not def or def.melee or os.clock() < reloadingUntil then
		return
	end
	if (ClientState.get("mag") or 0) >= def.magazine then
		return
	end
	reloadingUntil = os.clock() + def.reloadTime
	Net.event("WeaponReload"):FireServer()
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function bindInput()
	ContextActionService:BindAction("ViceFire", function(_, state)
		if state == Enum.UserInputState.Begin then
			firing = true
			tryFire()
		elseif state == Enum.UserInputState.End then
			firing = false
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

	ContextActionService:BindAction("ViceReload", function(_, state)
		if state == Enum.UserInputState.Begin then
			WeaponController.reload()
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.R, Enum.KeyCode.ButtonX)

	ContextActionService:BindAction("ViceAim", function(_, state)
		local def = WeaponCatalog.get(equipped)
		local active = state == Enum.UserInputState.Begin
		CameraController.setAiming(active and def ~= nil and not def.melee, def and def.scope)
		return Enum.ContextActionResult.Pass
	end, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)
end

--------------------------------------------------------------------------------
-- Equipment tracking
--------------------------------------------------------------------------------

local function watchCharacter(character: Model)
	local function scan()
		local tool = character:FindFirstChildOfClass("Tool")
		local id = tool and tool:GetAttribute("WeaponId") or "fists"
		if id ~= equipped then
			equipped = id
			reloadingUntil = 0
			ClientState.merge({ equipped = id })
		end
	end

	character.ChildAdded:Connect(scan)
	character.ChildRemoved:Connect(scan)
	scan()
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function WeaponController.start()
	local screen = UiKit.screen("ViceCrosshair", 8)
	buildCrosshair(screen)
	bindInput()

	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	Net.event("Hitmarker").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" then
			flashHitmarker(payload.killed == true)
		end
	end)

	ClientState.onChange("reloading", function(value)
		if type(value) == "number" and value > 0 then
			reloadingUntil = os.clock() + value
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		updateCrosshair(dt)

		local def = WeaponCatalog.get(equipped)
		if firing and def and def.auto then
			tryFire()
		end
	end)

	-- Releasing the button outside the window should still stop automatic fire.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			firing = false
		end
	end)
end

return WeaponController
