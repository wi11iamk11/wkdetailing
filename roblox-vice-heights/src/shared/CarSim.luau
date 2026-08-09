--!nonstrict
--[[
	CarSim
	The arcade vehicle model, shared so a player-driven car and a police AI car
	behave identically.

	Four downward raycasts stand in for wheels. Each contributes a spring force
	at its corner, which gives roll, pitch and squat for free. On top of that:
	a forward drive force, a lateral grip force that can be broken loose with
	the handbrake, and a yaw torque that chases the yaw rate a real steered
	wheelbase would produce.

	Whoever owns the assembly's physics calls `step`. Everyone else calls
	`animateRemote` to keep the wheels turning cosmetically.
]]

local Config = require(script.Parent.Config)
local VehicleCatalog = require(script.Parent.VehicleCatalog)

local CarSim = {}
CarSim.__index = CarSim

local V = Config.Vehicle
local CORNERS = { "FL", "FR", "RL", "RR" }
local IS_FRONT = { FL = true, FR = true, RL = false, RR = false }

export type Input = {
	throttle: number, -- -1 (reverse/brake) .. 1
	steer: number, -- -1 (left) .. 1 (right)
	handbrake: boolean,
}

local ZERO_INPUT: Input = { throttle = 0, steer = 0, handbrake = false }
CarSim.ZeroInput = ZERO_INPUT

--- Wheel attachment offsets in chassis space, rebuilt from the body size so
--- CarSim never has to be kept in sync with VehicleFactory by hand.
local function cornerOffsets(size: Vector3, wheelWidth: number): { [string]: Vector3 }
	local x = size.X / 2 - wheelWidth * 0.35
	local z = size.Z / 2 * 0.62
	local y = -size.Y / 2
	return {
		FL = Vector3.new(-x, y, -z),
		FR = Vector3.new(x, y, -z),
		RL = Vector3.new(-x, y, z),
		RR = Vector3.new(x, y, z),
	}
end

CarSim.cornerOffsets = cornerOffsets

function CarSim.new(model: Model)
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		return nil
	end

	local def = VehicleCatalog.get(model:GetAttribute("VehicleId"))
	if not def then
		return nil
	end

	local forces = model:FindFirstChild("Forces")
	if not forces then
		return nil
	end

	local self = setmetatable({}, CarSim)
	self.model = model
	self.chassis = chassis
	self.def = def
	self.handling = def.handling
	self.body = def.body
	self.wheelRadius = model:GetAttribute("WheelRadius") or def.body.wheelRadius
	self.restLength = model:GetAttribute("RestLength") or (self.wheelRadius + V.RideHeight)
	self.offsets = cornerOffsets(def.body.size, def.body.wheelWidth)

	self.springs = {}
	for _, corner in CORNERS do
		self.springs[corner] = forces:FindFirstChild(corner)
	end
	self.drive = forces:FindFirstChild("Drive")
	self.grip = forces:FindFirstChild("Grip")
	self.yaw = forces:FindFirstChild("Yaw")

	self.motors = {}
	for _, corner in CORNERS do
		self.motors[corner] = chassis:FindFirstChild(corner)
	end

	self.steerAngle = 0
	self.spin = 0
	self.grounded = 0
	self.speed = 0
	self.upsideDownFor = 0
	self.rayParams = RaycastParams.new()
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.rayParams.FilterDescendantsInstances = { model }
	self.rayParams.IgnoreWater = true

	-- Approximate yaw inertia of a box; only used to scale the steering torque.
	self.inertiaShape = (def.body.size.X ^ 2 + def.body.size.Z ^ 2) / 12

	return self
end

--- Keeps characters and other vehicles out of the suspension rays.
function CarSim:setIgnored(instances: { Instance })
	local list = { self.model }
	for _, instance in instances do
		table.insert(list, instance)
	end
	self.rayParams.FilterDescendantsInstances = list
end

local function velocityAt(chassis: BasePart, worldPosition: Vector3): Vector3
	local offset = worldPosition - chassis.AssemblyCenterOfMass
	return chassis.AssemblyLinearVelocity + chassis.AssemblyAngularVelocity:Cross(offset)
end

function CarSim:_suspension(dt: number): number
	local chassis = self.chassis
	local cf = chassis.CFrame
	local up = cf.UpVector
	local mass = chassis.AssemblyMass
	local quarter = mass / 4
	local maxRay = self.restLength + V.MaxSuspensionTravel

	local accel: { [string]: number } = {}
	local distance: { [string]: number } = {}
	local grounded = 0

	for _, corner in CORNERS do
		local origin = cf * self.offsets[corner]
		local hit = workspace:Raycast(origin, -up * maxRay, self.rayParams)
		if hit then
			local dist = (hit.Position - origin).Magnitude
			distance[corner] = dist
			local compression = self.restLength - dist
			if compression > 0 then
				grounded += 1
				local relative = velocityAt(chassis, origin):Dot(up)
				accel[corner] = V.SuspensionStiffness * compression - V.SuspensionDamping * relative
			else
				accel[corner] = 0
			end
		else
			distance[corner] = maxRay
			accel[corner] = 0
		end
	end

	-- Anti-roll bars: transfer load across each axle so the car does not lean
	-- over and trip on itself in a hard turn.
	local function bar(left: string, right: string)
		local delta = (distance[right] - distance[left]) * V.SuspensionStiffness * V.AntiRoll
		accel[left] = math.max(0, accel[left] - delta)
		accel[right] = math.max(0, accel[right] + delta)
	end
	bar("FL", "FR")
	bar("RL", "RR")

	for _, corner in CORNERS do
		local spring = self.springs[corner]
		if spring then
			spring.Force = up * math.max(0, accel[corner]) * quarter
		end
	end

	self.distance = distance
	self.grounded = grounded
	return grounded
end

function CarSim:_drive(dt: number, input: Input, groundFraction: number)
	local chassis = self.chassis
	local cf = chassis.CFrame
	local mass = chassis.AssemblyMass
	local velocity = chassis.AssemblyLinearVelocity
	local handling = self.handling

	local forwardSpeed = velocity:Dot(cf.LookVector)
	self.speed = forwardSpeed

	local throttle = math.clamp(input.throttle, -1, 1)
	local accel = 0

	if input.handbrake then
		accel = -math.sign(forwardSpeed) * handling.brakeForce * 0.9
	elseif throttle > 0.02 then
		if forwardSpeed < -1 then
			accel = handling.brakeForce * throttle -- braking out of reverse
		else
			local fade = 1 - math.clamp(forwardSpeed / handling.topSpeed, 0, 1) ^ 1.4
			accel = handling.power * throttle * fade
		end
	elseif throttle < -0.02 then
		if forwardSpeed > 1 then
			accel = -handling.brakeForce * -throttle
		else
			accel = handling.power * throttle * 0.42 -- reverse gear is slow
		end
	else
		accel = -math.sign(forwardSpeed) * 14 -- engine braking
	end

	-- Aerodynamic drag sets the real top speed.
	local ratio = math.abs(forwardSpeed) / handling.topSpeed
	accel -= math.sign(forwardSpeed) * handling.power * ratio * ratio

	-- Never let engine braking or drag push the car backwards through zero.
	if math.abs(forwardSpeed) < 1.5 and math.abs(throttle) < 0.02 and not input.handbrake then
		accel = -forwardSpeed * 6
	end

	if self.drive then
		-- Attachment-relative: the chassis faces -Z.
		self.drive.Force = Vector3.new(0, 0, -accel * mass * math.max(groundFraction, 0.05))
	end

	-- Lateral grip.
	if self.grip then
		local right = cf.RightVector
		local lateral = velocity:Dot(right)
		local coefficient = handling.grip * (input.handbrake and V.HandbrakeGripScale or 1)
		local limit = handling.grip * V.GripAccelLimit
		local lateralAccel = math.clamp(-lateral * coefficient, -limit, limit)
		self.grip.Force = right * lateralAccel * mass * groundFraction
	end
end

function CarSim:_steer(dt: number, input: Input, groundFraction: number)
	local chassis = self.chassis
	local handling = self.handling
	local mass = chassis.AssemblyMass

	local speedRatio = math.clamp(math.abs(self.speed) / handling.topSpeed, 0, 1)
	local lock = V.MaxSteerAngle * (1 - V.SteerSpeedFalloff * speedRatio)
	local target = math.clamp(input.steer, -1, 1) * lock

	local rate = V.SteerRate * dt
	self.steerAngle += math.clamp(target - self.steerAngle, -rate, rate)

	if not self.yaw then
		return
	end

	local wheelbase = self.body.size.Z * 0.62 * 2
	-- Bicycle model: yaw rate = v * tan(steer) / wheelbase.
	local desired = (self.speed / wheelbase) * math.tan(self.steerAngle)
	desired = math.clamp(desired, -3.2, 3.2)

	local actual = chassis.AssemblyAngularVelocity.Y
	local inertia = mass * self.inertiaShape
	local authority = groundFraction > 0 and 1 or V.AirControl
	local torque = (desired - actual) * handling.turnRate * inertia * authority

	self.yaw.Torque = Vector3.new(0, math.clamp(torque, -inertia * 40, inertia * 40), 0)
end

function CarSim:_wheels(dt: number)
	local circumference = self.wheelRadius
	self.spin += (self.speed / math.max(circumference, 0.1)) * dt
	if self.spin > math.pi * 2 or self.spin < -math.pi * 2 then
		self.spin %= math.pi * 2
	end

	for _, corner in CORNERS do
		local motor = self.motors[corner]
		if motor then
			local base = self.offsets[corner]
			local drop = (self.distance and self.distance[corner] or self.restLength) - self.wheelRadius
			local steer = IS_FRONT[corner] and -self.steerAngle or 0
			motor.C0 = CFrame.new(base.X, base.Y - drop, base.Z)
				* CFrame.Angles(0, steer, 0)
				* CFrame.Angles(self.spin, 0, 0)
		end
	end
end

--- Rights the car if it has been resting on its roof.
function CarSim:_recover(dt: number)
	local chassis = self.chassis
	local upright = chassis.CFrame.UpVector.Y
	if upright < 0.25 and chassis.AssemblyLinearVelocity.Magnitude < 8 then
		self.upsideDownFor += dt
		if self.upsideDownFor >= V.FlipRecoveryTime then
			self.upsideDownFor = 0
			local position = chassis.Position + Vector3.new(0, 4, 0)
			local _, yaw = chassis.CFrame:ToEulerAnglesYXZ()
			chassis.AssemblyLinearVelocity = Vector3.zero
			chassis.AssemblyAngularVelocity = Vector3.zero
			self.model:PivotTo(CFrame.new(position) * CFrame.Angles(0, yaw, 0))
		end
	else
		self.upsideDownFor = 0
	end
end

--- One physics step. Call from Heartbeat (or RenderStepped) on the peer that
--- owns the vehicle's assembly.
function CarSim:step(dt: number, input: Input?)
	dt = math.clamp(dt, 1 / 240, 1 / 15)
	local chassis = self.chassis
	if not chassis.Parent or chassis.Anchored then
		return
	end

	local resolved: Input = input or ZERO_INPUT
	local grounded = self:_suspension(dt)
	local fraction = grounded / 4

	self:_drive(dt, resolved, fraction)
	self:_steer(dt, resolved, fraction)
	self:_wheels(dt)
	self:_recover(dt)
end

--- Zeroes every force. Used when a driver leaves so the car coasts to a stop
--- instead of holding the last throttle input forever.
function CarSim:release()
	for _, corner in CORNERS do
		local spring = self.springs[corner]
		if spring then
			spring.Force = Vector3.zero
		end
	end
	if self.drive then
		self.drive.Force = Vector3.zero
	end
	if self.grip then
		self.grip.Force = Vector3.zero
	end
	if self.yaw then
		self.yaw.Torque = Vector3.zero
	end
end

function CarSim:speedStuds(): number
	return self.chassis.AssemblyLinearVelocity.Magnitude
end

function CarSim:speedMph(): number
	return self:speedStuds() * V.StudsPerSecondToMph
end

--------------------------------------------------------------------------------
-- Remote (non-simulated) vehicles
--------------------------------------------------------------------------------

-- Per-model cache. This runs every frame for every visible car, so the wheel
-- geometry is resolved once rather than rebuilt sixty times a second.
local remote: { [Model]: { spin: number, offsets: { [string]: Vector3 }, radius: number, drop: number } } = {}

local function remoteState(model: Model, def)
	local cached = remote[model]
	if cached then
		return cached
	end
	local radius = model:GetAttribute("WheelRadius") or def.body.wheelRadius
	local rest = model:GetAttribute("RestLength") or (radius + V.RideHeight)
	cached = {
		spin = 0,
		offsets = cornerOffsets(def.body.size, def.body.wheelWidth),
		radius = radius,
		drop = rest - radius,
	}
	remote[model] = cached
	return cached
end

--- Cosmetic wheel animation for cars this peer is not simulating. Uses the
--- replicated Steer attribute and the chassis velocity; no raycasts.
function CarSim.animateRemote(model: Model, dt: number)
	local chassis = model.PrimaryPart
	if not chassis then
		return
	end
	local def = VehicleCatalog.get(model:GetAttribute("VehicleId"))
	if not def then
		return
	end

	local state = remoteState(model, def)
	local steer = (model:GetAttribute("Steer") or 0) * V.MaxSteerAngle
	local speed = chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector)
	state.spin = (state.spin + (speed / math.max(state.radius, 0.1)) * dt) % (math.pi * 2)

	for _, corner in CORNERS do
		local motor = chassis:FindFirstChild(corner)
		if motor and motor:IsA("Motor6D") then
			local base = state.offsets[corner]
			motor.C0 = CFrame.new(base.X, base.Y - state.drop, base.Z)
				* CFrame.Angles(0, IS_FRONT[corner] and -steer or 0, 0)
				* CFrame.Angles(state.spin, 0, 0)
		end
	end
end

function CarSim.forgetRemote(model: Model)
	remote[model] = nil
end

return CarSim
