--!nonstrict
--[[
	VehicleCatalog
	Every drivable vehicle. `handling` values feed the arcade physics model in
	VehicleController; `body` values feed VehicleFactory's part builder.

	power        forward acceleration force per stud of mass
	topSpeed     studs/sec the drag curve settles at
	grip         lateral friction coefficient (higher = less drift)
	turnRate     peak yaw torque scale
	brakeForce   deceleration force when braking
	mass         approximate chassis density multiplier
]]

local VehicleCatalog = {}

local function def(entry)
	return entry
end

VehicleCatalog.Vehicles = {
	sultan = def({
		name = "Sultan RS",
		class = "Sports",
		price = 24000,
		description = "Balanced all-rounder. Grips like it's on rails.",
		body = {
			size = Vector3.new(6.4, 2.4, 14.5),
			color = Color3.fromRGB(196, 60, 60),
			roofColor = Color3.fromRGB(30, 32, 36),
			wheelRadius = 1.7,
			wheelWidth = 1.1,
			style = "coupe",
		},
		handling = {
			power = 168,
			topSpeed = 205,
			grip = 15.5,
			turnRate = 3.5,
			brakeForce = 155,
			mass = 1.0,
		},
	}),

	bison = def({
		name = "Bison XL",
		class = "Truck",
		price = 18000,
		description = "Heavy pickup. Slow to stop, hard to stop.",
		body = {
			size = Vector3.new(7.2, 3.2, 16.5),
			color = Color3.fromRGB(48, 92, 148),
			roofColor = Color3.fromRGB(38, 40, 44),
			wheelRadius = 2.1,
			wheelWidth = 1.4,
			style = "truck",
		},
		handling = {
			power = 150,
			topSpeed = 160,
			grip = 12.0,
			turnRate = 2.5,
			brakeForce = 120,
			mass = 1.8,
		},
	}),

	comet = def({
		name = "Comet Turbo",
		class = "Super",
		price = 92000,
		description = "Absurd top end. Respect the throttle.",
		body = {
			size = Vector3.new(6.6, 2.0, 14.0),
			color = Color3.fromRGB(238, 214, 76),
			roofColor = Color3.fromRGB(24, 24, 28),
			wheelRadius = 1.6,
			wheelWidth = 1.3,
			style = "super",
		},
		handling = {
			power = 235,
			topSpeed = 268,
			grip = 17.0,
			turnRate = 3.9,
			brakeForce = 185,
			mass = 0.85,
		},
	}),

	blista = def({
		name = "Blista Compact",
		class = "Compact",
		price = 6500,
		description = "Cheap, cheerful, surprisingly nimble.",
		body = {
			size = Vector3.new(5.8, 2.4, 12.0),
			color = Color3.fromRGB(96, 168, 108),
			roofColor = Color3.fromRGB(84, 148, 96),
			wheelRadius = 1.5,
			wheelWidth = 1.0,
			style = "compact",
		},
		handling = {
			power = 132,
			topSpeed = 158,
			grip = 14.0,
			turnRate = 3.8,
			brakeForce = 130,
			mass = 0.8,
		},
	}),

	ambulance = def({
		name = "Ambulance",
		class = "Emergency",
		price = 30000,
		description = "Boxy, boaty, and everyone gets out of the way.",
		body = {
			size = Vector3.new(7.0, 4.2, 17.0),
			color = Color3.fromRGB(240, 240, 244),
			roofColor = Color3.fromRGB(220, 222, 226),
			wheelRadius = 2.0,
			wheelWidth = 1.2,
			style = "van",
		},
		handling = {
			power = 140,
			topSpeed = 150,
			grip = 11.5,
			turnRate = 2.4,
			brakeForce = 118,
			mass = 1.7,
		},
	}),

	-- Not purchasable: spawned by the police response system.
	cruiser = def({
		name = "Police Cruiser",
		class = "Emergency",
		price = -1,
		description = "Standard issue interceptor.",
		body = {
			size = Vector3.new(6.8, 2.6, 15.2),
			color = Color3.fromRGB(240, 240, 244),
			roofColor = Color3.fromRGB(28, 30, 34),
			wheelRadius = 1.8,
			wheelWidth = 1.1,
			style = "cruiser",
			lightbar = true,
		},
		handling = {
			power = 178,
			topSpeed = 198,
			grip = 15.0,
			turnRate = 3.3,
			brakeForce = 160,
			mass = 1.15,
		},
	}),
}

--- Vehicles the dealership will sell, in display order.
VehicleCatalog.ForSale = { "blista", "bison", "sultan", "ambulance", "comet" }

--- What every new player already owns.
VehicleCatalog.StarterVehicle = "blista"

function VehicleCatalog.get(id: string)
	return VehicleCatalog.Vehicles[id]
end

function VehicleCatalog.isPurchasable(id: string): boolean
	local entry = VehicleCatalog.Vehicles[id]
	return entry ~= nil and entry.price >= 0
end

return VehicleCatalog
