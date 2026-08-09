--!nonstrict
--[[
	VehicleController
	Drives the car the local player is sitting in.

	The server hands network ownership to the driver, so the physics run here:
	every Stepped we read the seat's input, run CarSim, and let the resulting
	motion replicate. Steering angle is mirrored back to the server at a low
	rate purely so other clients can animate the front wheels.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CarSim = require(Shared.CarSim)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Util = require(Shared.Util)

local HUD = require(script.Parent.HUD)

local VehicleController = {}

local player = Players.LocalPlayer
local REMOTE_RANGE = 320
local TELEMETRY_RATE = 1 / 10

local current: { model: Model, sim: any, seat: VehicleSeat }? = nil
local telemetryClock = 0
local driverListeners: { (Model?) -> () } = {}

--- Fires with the vehicle the player is driving, or nil when they get out.
function VehicleController.onDriverChanged(fn)
	table.insert(driverListeners, fn)
end

function VehicleController.getVehicle(): Model?
	return current and current.model or nil
end

local function announce(model: Model?)
	for _, fn in driverListeners do
		task.spawn(fn, model)
	end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

--- VehicleSeat already folds keyboard, gamepad and touch movement into
--- Throttle/Steer, so we start from those and layer analog steering on top.
local function readInput(seat: VehicleSeat): CarSim.Input
	local throttle = seat.Throttle
	local steer = seat.Steer

	local gamepads = UserInputService:GetConnectedGamepads()
	if #gamepads > 0 then
		local state = UserInputService:GetGamepadState(gamepads[1])
		for _, input in state do
			if input.KeyCode == Enum.KeyCode.Thumbstick1 and math.abs(input.Position.X) > 0.12 then
				steer = input.Position.X
			elseif input.KeyCode == Enum.KeyCode.ButtonR2 and input.Position.Z > 0.05 then
				throttle = input.Position.Z
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 and input.Position.Z > 0.05 then
				throttle = -input.Position.Z
			end
		end
	end

	local handbrake = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonX)

	return { throttle = throttle, steer = steer, handbrake = handbrake }
end

--------------------------------------------------------------------------------
-- Seat tracking
--------------------------------------------------------------------------------

local function stop()
	if not current then
		return
	end
	current.sim:release()
	current = nil
	HUD.setVehicle(nil)
	announce(nil)
end

local function begin(seat: VehicleSeat)
	local model = seat:FindFirstAncestorWhichIsA("Model")
	if not model or not model:GetAttribute("VehicleId") then
		return
	end

	-- Give the server a moment to transfer network ownership before we start
	-- pushing forces into an assembly we do not own yet.
	task.wait(0.25)

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.SeatPart ~= seat then
		return
	end

	local sim = CarSim.new(model)
	if not sim then
		warn("VehicleController: could not build a sim for " .. model.Name)
		return
	end
	sim:setIgnored({ player.Character })

	current = { model = model, sim = sim, seat = seat }
	announce(model)
end

local function onSeated(active: boolean, seat: BasePart?)
	if not active or not seat then
		stop()
		return
	end
	if seat:IsA("VehicleSeat") and seat.Name == "DriverSeat" then
		task.spawn(begin, seat)
	else
		stop()
	end
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.Seated:Connect(onSeated)
	humanoid.Died:Connect(stop)
end

--------------------------------------------------------------------------------
-- Remote vehicles
--------------------------------------------------------------------------------

local function animateOthers(dt: number)
	local root = Util.rootOf(player.Character)
	if not root then
		return
	end
	local origin = root.Position

	for _, model in CollectionService:GetTagged("Vehicle") do
		if model:IsA("Model") and (not current or model ~= current.model) then
			local chassis = model.PrimaryPart
			if chassis and (chassis.Position - origin).Magnitude < REMOTE_RANGE then
				CarSim.animateRemote(model, dt)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function VehicleController.start()
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	RunService.Stepped:Connect(function(_, dt)
		if not current then
			return
		end

		local model = current.model
		if not model.Parent or not model.PrimaryPart then
			stop()
			return
		end

		local input = readInput(current.seat)
		current.sim:step(dt, input)
		HUD.setVehicle(model, current.sim:speedMph())

		telemetryClock += dt
		if telemetryClock >= TELEMETRY_RATE then
			telemetryClock = 0
			-- Normalised to -1..1 so the receiving client can scale it back out.
			Net.event("VehicleTelemetry")
				:FireServer(current.sim.steerAngle / Config.Vehicle.MaxSteerAngle, input.throttle)
		end
	end)

	RunService.Heartbeat:Connect(animateOthers)
end

return VehicleController
