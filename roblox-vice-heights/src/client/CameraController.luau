--!nonstrict
--[[
	CameraController
	Keeps Roblox's own camera (so mouse look, zoom and touch all behave the way
	players expect) and layers three things on top:

	  * the camera follows the car instead of the driver while you are driving
	  * a field-of-view change while aiming, including sniper scopes
	  * additive recoil that decays, applied after the default camera has run
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Util = require(Shared.Util)

local CameraController = {}

local player = Players.LocalPlayer
local BASE_FOV = 70

local recoilPitch = 0
local recoilYaw = 0
local aiming = false
local fovTween: Tween? = nil

local function camera(): Camera
	return Workspace.CurrentCamera
end

--- Adds a kick, in degrees. Decays back to zero over the next few frames.
function CameraController.addRecoil(degrees: number)
	recoilPitch += math.rad(degrees)
	recoilYaw += math.rad((math.random() - 0.5) * degrees * 0.6)
end

function CameraController.setAiming(active: boolean, scope: number?)
	if aiming == active then
		return
	end
	aiming = active

	local target = BASE_FOV
	if active then
		target = scope and (BASE_FOV / scope) or BASE_FOV * 0.75
	end

	if fovTween then
		fovTween:Cancel()
	end
	fovTween = TweenService:Create(camera(), TweenInfo.new(0.18), { FieldOfView = target })
	fovTween:Play()
end

--- Called by VehicleController: point the camera at the car, not the driver.
function CameraController.setVehicle(model: Model?)
	local cam = camera()
	if model and model.PrimaryPart then
		cam.CameraSubject = model.PrimaryPart
		player.CameraMaxZoomDistance = 90
	else
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			cam.CameraSubject = humanoid
		end
		player.CameraMaxZoomDistance = 60
	end
end

--- While aiming on foot, turn the character to face where the camera looks so
--- shots leave the barrel in the direction the crosshair points.
local function faceCamera(dt: number)
	if not aiming then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = Util.rootOf(character)
	if not humanoid or not root or humanoid.SeatPart then
		return
	end

	local look = camera().CFrame.LookVector
	local flat = Util.horizontal(look)
	if flat.Magnitude < 0.01 then
		return
	end

	local goal = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	root.CFrame = root.CFrame:Lerp(goal, math.clamp(dt * 14, 0, 1))
end

function CameraController.start()
	camera().FieldOfView = BASE_FOV

	player.CharacterAdded:Connect(function()
		aiming = false
		camera().FieldOfView = BASE_FOV
		task.defer(CameraController.setVehicle, nil)
	end)

	-- Run after the default camera script so our offset is not overwritten.
	RunService:BindToRenderStep("ViceCameraOffset", Enum.RenderPriority.Camera.Value + 1, function(dt)
		faceCamera(dt)

		if recoilPitch ~= 0 or recoilYaw ~= 0 then
			local cam = camera()
			cam.CFrame = cam.CFrame * CFrame.Angles(recoilPitch, recoilYaw, 0)

			-- Exponential decay, frame-rate independent.
			local keep = math.exp(-dt / 0.08)
			recoilPitch *= keep
			recoilYaw *= keep
			if math.abs(recoilPitch) < 1e-4 then
				recoilPitch = 0
			end
			if math.abs(recoilYaw) < 1e-4 then
				recoilYaw = 0
			end
		end
	end)
end

return CameraController
