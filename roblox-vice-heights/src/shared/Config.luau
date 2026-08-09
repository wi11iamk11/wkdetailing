--!nonstrict
--[[
	Config
	Central tuning table for Vice Heights. Everything a designer would want to
	touch lives here so gameplay can be rebalanced without reading systems code.
]]

local Config = {}

Config.Game = {
	Name = "Vice Heights",
	Version = "0.1.0",
	-- Changing the seed regenerates a completely different city layout.
	Seed = 20260809,
}

--------------------------------------------------------------------------------
-- City generation
--------------------------------------------------------------------------------

Config.City = {
	Blocks = 8, -- city is Blocks x Blocks city blocks
	BlockSize = 160, -- studs, edge of a block (not counting road)
	RoadWidth = 40, -- studs, full width of a street
	SidewalkWidth = 8,
	SidewalkHeight = 0.6,

	FloorHeight = 12,
	MinFloors = 2,
	MaxFloors = 22,

	GroundY = 0,
	LaneDashSpacing = 40,
	LaneDashLength = 12,

	-- Hard ceiling so a bad seed can never bury the client under geometry.
	MaxParts = 14000,

	Palette = {
		Road = Color3.fromRGB(52, 54, 58),
		RoadLine = Color3.fromRGB(226, 208, 120),
		Crosswalk = Color3.fromRGB(232, 232, 232),
		Sidewalk = Color3.fromRGB(150, 152, 155),
		Ground = Color3.fromRGB(86, 108, 74),
		Sand = Color3.fromRGB(217, 202, 156),
		Park = Color3.fromRGB(78, 122, 66),
	},

	BuildingColors = {
		Color3.fromRGB(196, 186, 170),
		Color3.fromRGB(168, 160, 152),
		Color3.fromRGB(210, 196, 176),
		Color3.fromRGB(136, 142, 150),
		Color3.fromRGB(178, 148, 132),
		Color3.fromRGB(120, 128, 132),
		Color3.fromRGB(206, 168, 148),
		Color3.fromRGB(148, 156, 168),
	},

	WindowColor = Color3.fromRGB(58, 74, 92),
	WindowColorLit = Color3.fromRGB(248, 224, 152),
}

--------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------

Config.Economy = {
	StartingCash = 1500,
	StartingBank = 0,
	MaxCashOnHand = 10000000,

	-- Killing a civilian drops a little pocket change (and a lot of heat).
	PedCashDrop = { Min = 15, Max = 120 },

	StoreRobbery = {
		Duration = 12, -- seconds you must survive at the register
		Payout = { Min = 900, Max = 2400 },
		Cooldown = 300, -- per store, seconds
		WantedStars = 2,
	},

	-- Medical bill on death, capped so a broke player is never stuck.
	HospitalFee = { Percent = 0.10, Max = 5000 },
	-- Bribes, impound and "lost property" when the cops take you in.
	BustedFee = { Percent = 0.25, Max = 15000 },
}

--------------------------------------------------------------------------------
-- Wanted level
--------------------------------------------------------------------------------

Config.Wanted = {
	MaxStars = 5,
	-- Heat points required for each star (index = star count).
	StarThresholds = { 60, 180, 400, 750, 1300 },
	MaxHeat = 1800,

	-- Heat bleeds off only while no officer has eyes on you.
	DecayPerSecond = 24,
	-- Seconds out of police line-of-sight before decay begins.
	CooldownDelay = 12,

	Crimes = {
		VehicleTheft = 45,
		DiscardedWeaponFire = 25, -- firing a gun in public
		PedKill = 90,
		CopKill = 260,
		VehicleAssault = 70, -- running someone over
		StoreRobbery = 220,
		CopVehicleDestroyed = 150,
	},
	-- Repeat crimes of the same type within this window are discounted so a
	-- single shotgun blast into a crowd does not instantly max the meter.
	CrimeStackWindow = 4,
	CrimeStackFalloff = 0.45,
}

--------------------------------------------------------------------------------
-- Police response
--------------------------------------------------------------------------------

Config.Police = {
	-- Indexed by star count.
	Tiers = {
		[1] = { Foot = 2, Cars = 0, Health = 100, Damage = 8, Accuracy = 0.35, FireRate = 1.1 },
		[2] = { Foot = 3, Cars = 1, Health = 110, Damage = 10, Accuracy = 0.45, FireRate = 0.9 },
		[3] = { Foot = 4, Cars = 2, Health = 125, Damage = 12, Accuracy = 0.55, FireRate = 0.75 },
		[4] = { Foot = 6, Cars = 3, Health = 145, Damage = 15, Accuracy = 0.65, FireRate = 0.6 },
		[5] = { Foot = 8, Cars = 4, Health = 175, Damage = 18, Accuracy = 0.72, FireRate = 0.45 },
	},

	SpawnDistance = { Min = 140, Max = 260 },
	DespawnDistance = 700,
	EngageRange = 90,
	SightRange = 220,
	RepathInterval = 0.9,
	MaxTotalCops = 26,

	-- Busted: hold a low-health wanted player at gunpoint long enough.
	Bust = {
		Range = 14,
		HealthThreshold = 30,
		HoldTime = 3.0,
	},
}

--------------------------------------------------------------------------------
-- Pedestrians and traffic
--------------------------------------------------------------------------------

Config.Peds = {
	MaxAlive = 34,
	SpawnRadius = { Min = 90, Max = 300 },
	DespawnRadius = 460,
	SpawnInterval = 0.6,
	WalkSpeed = { Min = 7, Max = 11 },
	FleeSpeed = 20,
	Health = 100,
	-- How long a ped screams and runs after hearing gunfire.
	PanicDuration = 12,
	PanicRadius = 90,

	Shirts = {
		Color3.fromRGB(196, 76, 76),
		Color3.fromRGB(76, 120, 196),
		Color3.fromRGB(88, 168, 108),
		Color3.fromRGB(228, 188, 96),
		Color3.fromRGB(160, 96, 188),
		Color3.fromRGB(232, 232, 236),
		Color3.fromRGB(64, 68, 76),
	},
	Skins = {
		Color3.fromRGB(238, 200, 168),
		Color3.fromRGB(214, 166, 124),
		Color3.fromRGB(168, 118, 82),
		Color3.fromRGB(118, 78, 54),
		Color3.fromRGB(82, 54, 38),
	},
}

Config.Traffic = {
	ParkedCarsPerBlock = { Min = 1, Max = 3 },
	MaxParkedCars = 60,
}

--------------------------------------------------------------------------------
-- Vehicles
--------------------------------------------------------------------------------

Config.Vehicle = {
	MaxPerPlayer = 2,
	-- An abandoned player-spawned car cleans itself up.
	AbandonDespawnTime = 180,
	-- Parked street cars re-anchor once nobody has touched them for a while.
	RestAnchorDelay = 25,

	StudsPerSecondToMph = 0.62,

	MaxHealth = 100,
	CollisionDamageThreshold = 55, -- studs/sec of impact velocity
	CollisionDamageScale = 0.55,
	ExplosionDamage = 65,
	ExplosionRadius = 22,

	-- Arcade suspension model (see VehicleController). Stiffness and damping are
	-- mass-normalised (units of 1/s^2 and 1/s) so the same numbers feel the same
	-- on a compact and on a truck.
	SuspensionStiffness = 400,
	SuspensionDamping = 32,
	AntiRoll = 0.6,
	MaxSuspensionTravel = 1.3,
	-- Ride height above the wheel radius.
	RideHeight = 0.6,

	-- Handling model.
	MaxSteerAngle = 0.55, -- radians at a standstill
	SteerSpeedFalloff = 0.68, -- how much steering lock is lost at top speed
	SteerRate = 6.0, -- radians/sec the virtual wheel turns toward input
	GripAccelLimit = 12, -- multiplied by the vehicle's grip stat
	HandbrakeGripScale = 0.28,
	AirControl = 0.25,
	FlipRecoveryTime = 3.0,
}

--------------------------------------------------------------------------------
-- Combat
--------------------------------------------------------------------------------

Config.Combat = {
	HeadshotMultiplier = 2.4,
	LimbMultiplier = 0.75,
	MaxHealth = 100,
	MaxArmor = 100,
	-- Anti-cheat: a reported shot origin must be near the shooter's head.
	MaxOriginError = 12,
	-- Grace on the client-authoritative fire rate check.
	FireRateTolerance = 0.85,
	ArmorAbsorb = 0.6, -- fraction of damage armor eats first
}

--------------------------------------------------------------------------------
-- World cycle
--------------------------------------------------------------------------------

Config.DayNight = {
	Enabled = true,
	MinutesPerDay = 24, -- real minutes for one in-game day
	StartClockTime = 9.5,
	NightStart = 18.5,
	NightEnd = 6.0,
}

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

Config.Data = {
	StoreName = "ViceHeights_Profiles_v1",
	AutosaveInterval = 120,
	MaxRetries = 4,
	RetryBackoff = 2,
}

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

Config.UI = {
	Accent = Color3.fromRGB(255, 196, 62),
	Cash = Color3.fromRGB(126, 217, 87),
	Health = Color3.fromRGB(226, 72, 72),
	Armor = Color3.fromRGB(96, 168, 236),
	Panel = Color3.fromRGB(18, 19, 22),
	Text = Color3.fromRGB(238, 238, 240),
	Muted = Color3.fromRGB(150, 152, 158),
	MinimapRange = 260, -- studs shown edge to edge on the radar
}

return Config
