--!nonstrict
--[[
	VehicleFactory
	Builds a drivable car out of primitives.

	The physics model is a raycast-suspension arcade car: the chassis is the only
	collider, and four VectorForces at the corners hold it up. Wheels are massless
	visual parts on Motor6Ds, animated by whoever owns the vehicle.

	Everything the driver's client needs to simulate the car lives on the model as
	instances (forces, attachments) or attributes, so the client never has to
	create replicated objects.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CarSim = require(Shared.CarSim)
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local VehicleCatalog = require(Shared.VehicleCatalog)

local VehicleFactory = {}

VehicleFactory.CornerNames = { "FL", "FR", "RL", "RR" }

--- Wheel geometry comes from CarSim so the parts we build and the physics that
--- drives them can never disagree about where a wheel is.
local function cornerOffsets(body)
	return CarSim.cornerOffsets(body.size, body.wheelWidth)
end

local function bodyPart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Model): BasePart
	return Util.part({
		Name = name,
		Size = size,
		CFrame = cframe,
		Color = color,
		Anchored = false,
		CanCollide = false,
		Massless = true,
		Material = Enum.Material.Metal,
		Parent = parent,
	})
end

local function addBodywork(model: Model, chassis: BasePart, body)
	local size = body.size
	local style = body.style

	local cabinHeight = (style == "van" and size.Y * 0.55) or size.Y * 0.72
	local cabinLength = (style == "van" and size.Z * 0.62) or size.Z * 0.44
	local cabinOffsetZ = (style == "truck" and -size.Z * 0.08) or size.Z * 0.02

	local cabin = bodyPart(
		"Cabin",
		Vector3.new(size.X * 0.86, cabinHeight, cabinLength),
		chassis.CFrame * CFrame.new(0, size.Y / 2 + cabinHeight / 2 - 0.1, cabinOffsetZ),
		body.roofColor,
		model
	)
	cabin.Material = Enum.Material.SmoothPlastic
	Util.weld(chassis, cabin)

	-- Glass band around the cabin reads as windows without any textures.
	local glass = bodyPart(
		"Glass",
		Vector3.new(size.X * 0.88, cabinHeight * 0.5, cabinLength * 1.02),
		cabin.CFrame * CFrame.new(0, cabinHeight * 0.12, 0),
		Color3.fromRGB(38, 48, 62),
		model
	)
	glass.Material = Enum.Material.Glass
	glass.Reflectance = 0.25
	Util.weld(chassis, glass)

	-- Headlights and tail lights.
	local lightZ = -size.Z / 2 + 0.25
	for _, side in { -1, 1 } do
		local headlight = bodyPart(
			"Headlight",
			Vector3.new(size.X * 0.2, 0.45, 0.4),
			chassis.CFrame * CFrame.new(side * size.X * 0.32, -0.1, lightZ),
			Color3.fromRGB(255, 246, 214),
			model
		)
		headlight.Material = Enum.Material.Neon
		Util.weld(chassis, headlight)

		local beam = Instance.new("SpotLight")
		beam.Name = "Beam"
		beam.Angle = 70
		beam.Brightness = 2.2
		beam.Range = 55
		beam.Face = Enum.NormalId.Front
		beam.Color = Color3.fromRGB(255, 248, 224)
		beam.Enabled = false
		beam.Parent = headlight

		local tail = bodyPart(
			"Taillight",
			Vector3.new(size.X * 0.2, 0.35, 0.35),
			chassis.CFrame * CFrame.new(side * size.X * 0.32, -0.1, size.Z / 2 - 0.2),
			Color3.fromRGB(190, 40, 40),
			model
		)
		tail.Material = Enum.Material.Neon
		Util.weld(chassis, tail)
	end

	if body.lightbar then
		local bar = Instance.new("Folder")
		bar.Name = "Lightbar"
		bar.Parent = model
		for index, info in { { -1, Color3.fromRGB(255, 40, 40) }, { 1, Color3.fromRGB(50, 90, 255) } } do
			local lamp = bodyPart(
				"Lamp" .. index,
				Vector3.new(size.X * 0.3, 0.35, 0.7),
				cabin.CFrame * CFrame.new(info[1] * size.X * 0.2, cabinHeight / 2 + 0.2, 0),
				info[2],
				model
			)
			lamp.Material = Enum.Material.Neon
			lamp.Parent = bar
			Util.weld(cabin, lamp)

			local light = Instance.new("PointLight")
			light.Color = info[2]
			light.Brightness = 3
			light.Range = 26
			light.Enabled = false
			light.Parent = lamp
		end
	end
end

local function addWheels(model: Model, chassis: BasePart, body)
	local offsets = cornerOffsets(body)
	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = model

	local restLength = body.wheelRadius + Config.Vehicle.RideHeight

	for _, corner in VehicleFactory.CornerNames do
		local offset = offsets[corner]
		-- Wheel centre hangs below the chassis floor by the ride height.
		local wheelCenter = offset - Vector3.new(0, restLength - body.wheelRadius, 0)

		local wheel = Util.part({
			Name = corner,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(body.wheelWidth, body.wheelRadius * 2, body.wheelRadius * 2),
			CFrame = chassis.CFrame * CFrame.new(wheelCenter),
			Color = Color3.fromRGB(28, 28, 32),
			Material = Enum.Material.SmoothPlastic,
			Anchored = false,
			CanCollide = false,
			CanQuery = false,
			Massless = true,
			Parent = wheels,
		})

		local hub = Util.part({
			Name = "Hub",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(body.wheelWidth * 1.05, body.wheelRadius * 1.1, body.wheelRadius * 1.1),
			CFrame = wheel.CFrame,
			Color = Color3.fromRGB(178, 180, 186),
			Material = Enum.Material.Metal,
			Anchored = false,
			CanCollide = false,
			CanQuery = false,
			Massless = true,
			Parent = wheels,
		})
		Util.weld(wheel, hub)

		local joint = Instance.new("Motor6D")
		joint.Name = corner
		joint.Part0 = chassis
		joint.Part1 = wheel
		joint.C0 = CFrame.new(wheelCenter)
		joint.C1 = CFrame.new()
		joint.Parent = chassis
	end
end

local function addPhysics(model: Model, chassis: BasePart, body)
	local offsets = cornerOffsets(body)

	local forces = Instance.new("Folder")
	forces.Name = "Forces"
	forces.Parent = model

	for _, corner in VehicleFactory.CornerNames do
		local attachment = Util.attachment(chassis, "Susp" .. corner, offsets[corner])
		local force = Instance.new("VectorForce")
		force.Name = corner
		force.Attachment0 = attachment
		force.ApplyAtCenterOfMass = false
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.Force = Vector3.zero
		force.Parent = forces
	end

	local center = Util.attachment(chassis, "Center", Vector3.zero)

	local drive = Instance.new("VectorForce")
	drive.Name = "Drive"
	drive.Attachment0 = center
	drive.ApplyAtCenterOfMass = true
	drive.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	drive.Force = Vector3.zero
	drive.Parent = forces

	local grip = Instance.new("VectorForce")
	grip.Name = "Grip"
	grip.Attachment0 = center
	grip.ApplyAtCenterOfMass = true
	grip.RelativeTo = Enum.ActuatorRelativeTo.World
	grip.Force = Vector3.zero
	grip.Parent = forces

	local yaw = Instance.new("Torque")
	yaw.Name = "Yaw"
	yaw.Attachment0 = center
	yaw.RelativeTo = Enum.ActuatorRelativeTo.World
	yaw.Torque = Vector3.zero
	yaw.Parent = forces
end

local function addSeats(model: Model, chassis: BasePart, body)
	local size = body.size
	local seatY = size.Y / 2 - 0.4
	local seatZ = size.Z * 0.06

	local driver = Instance.new("VehicleSeat")
	driver.Name = "DriverSeat"
	driver.Size = Vector3.new(2, 0.4, 2)
	driver.CFrame = chassis.CFrame * CFrame.new(-size.X * 0.2, seatY, seatZ)
	driver.Color = Color3.fromRGB(40, 42, 48)
	driver.Material = Enum.Material.Fabric
	driver.Anchored = false
	driver.CanCollide = false
	driver.Massless = true
	driver.MaxSpeed = 0 -- we drive it ourselves; the built-in controller stays off
	driver.Torque = 0
	driver.TurnSpeed = 0
	driver.HeadsUpDisplay = false
	driver.Parent = model
	Util.weld(chassis, driver)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ActionText = "Drive"
	prompt.ObjectText = model:GetAttribute("DisplayName") or "Vehicle"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = driver

	local passenger = Instance.new("Seat")
	passenger.Name = "PassengerSeat"
	passenger.Size = Vector3.new(2, 0.4, 2)
	passenger.CFrame = chassis.CFrame * CFrame.new(size.X * 0.2, seatY, seatZ)
	passenger.Color = Color3.fromRGB(40, 42, 48)
	passenger.Material = Enum.Material.Fabric
	passenger.Anchored = false
	passenger.CanCollide = false
	passenger.Massless = true
	passenger.Parent = model
	Util.weld(chassis, passenger)

	local ridePrompt = Instance.new("ProximityPrompt")
	ridePrompt.Name = "RidePrompt"
	ridePrompt.ActionText = "Ride"
	ridePrompt.ObjectText = model:GetAttribute("DisplayName") or "Vehicle"
	ridePrompt.HoldDuration = 0
	ridePrompt.MaxActivationDistance = 12
	ridePrompt.RequiresLineOfSight = false
	ridePrompt.Parent = passenger
end

--- Creates a vehicle model, unparented and unanchored, positioned at `cframe`.
function VehicleFactory.create(vehicleId: string, cframe: CFrame, overrides: { [string]: any }?): Model?
	local def = VehicleCatalog.get(vehicleId)
	if not def then
		warn("VehicleFactory: unknown vehicle " .. tostring(vehicleId))
		return nil
	end

	local body = table.clone(def.body)
	if overrides and overrides.color then
		body.color = overrides.color
	end

	local model = Instance.new("Model")
	model.Name = def.name
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("DisplayName", def.name)
	model:SetAttribute("Health", Config.Vehicle.MaxHealth)
	model:SetAttribute("Steer", 0)
	model:SetAttribute("Throttle", 0)
	model:SetAttribute("RestLength", body.wheelRadius + Config.Vehicle.RideHeight)
	model:SetAttribute("WheelRadius", body.wheelRadius)
	-- Atomic so the car never streams in as a pile of loose parts.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local chassis = Util.part({
		Name = "Chassis",
		Size = body.size,
		CFrame = cframe,
		Color = body.color,
		Material = Enum.Material.Metal,
		Anchored = true, -- unanchored by VehicleService once it is in the world
		CanCollide = true,
		CanTouch = true,
		Parent = model,
	})
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.9 * def.handling.mass, 0.42, 0.05, 1, 1)

	addBodywork(model, chassis, body)
	addWheels(model, chassis, body)
	addPhysics(model, chassis, body)
	addSeats(model, chassis, body)

	model.PrimaryPart = chassis
	return model
end

--- Toggles headlights and (for police) the lightbar.
function VehicleFactory.setLights(model: Model, on: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("SpotLight") and descendant.Name == "Beam" then
			descendant.Enabled = on
		end
	end
end

function VehicleFactory.setSiren(model: Model, on: boolean)
	local bar = model:FindFirstChild("Lightbar")
	if not bar then
		return
	end
	for _, lamp in bar:GetChildren() do
		local light = lamp:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = on
		end
	end
end

return VehicleFactory
