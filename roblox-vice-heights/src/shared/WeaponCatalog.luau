--!nonstrict
--[[
	WeaponCatalog
	Weapon stats are shared: the client uses them for feel (recoil, spread,
	fire rate) and the server uses the same numbers to validate what the client
	claims happened.
]]

local WeaponCatalog = {}

WeaponCatalog.Weapons = {
	fists = {
		name = "Fists",
		slot = 1,
		price = 0,
		damage = 12,
		range = 8,
		fireRate = 0.5,
		melee = true,
		magazine = 0,
		reserve = 0,
		spread = 0,
		recoil = 0,
		pellets = 1,
		loud = false,
	},

	pistol = {
		name = "Pistol",
		slot = 2,
		price = 1200,
		ammoPrice = 90, -- per magazine
		damage = 24,
		range = 320,
		fireRate = 0.16,
		magazine = 12,
		reserve = 60,
		reloadTime = 1.5,
		spread = 0.012,
		recoil = 1.4,
		pellets = 1,
		auto = false,
		loud = true,
		model = { length = 1.6, color = Color3.fromRGB(58, 60, 66) },
	},

	smg = {
		name = "Micro SMG",
		slot = 3,
		price = 7500,
		ammoPrice = 180,
		damage = 17,
		range = 260,
		fireRate = 0.075,
		magazine = 30,
		reserve = 150,
		reloadTime = 2.0,
		spread = 0.035,
		recoil = 1.0,
		pellets = 1,
		auto = true,
		loud = true,
		model = { length = 2.4, color = Color3.fromRGB(44, 46, 52) },
	},

	shotgun = {
		name = "Pump Shotgun",
		slot = 4,
		price = 11000,
		ammoPrice = 220,
		damage = 11, -- per pellet
		range = 90,
		fireRate = 0.85,
		magazine = 8,
		reserve = 40,
		reloadTime = 2.8,
		spread = 0.09,
		recoil = 4.5,
		pellets = 8,
		auto = false,
		loud = true,
		model = { length = 3.2, color = Color3.fromRGB(78, 56, 40) },
	},

	rifle = {
		name = "Assault Rifle",
		slot = 5,
		price = 24000,
		ammoPrice = 320,
		damage = 26,
		range = 420,
		fireRate = 0.1,
		magazine = 30,
		reserve = 180,
		reloadTime = 2.4,
		spread = 0.022,
		recoil = 1.8,
		pellets = 1,
		auto = true,
		loud = true,
		model = { length = 3.4, color = Color3.fromRGB(52, 54, 46) },
	},

	sniper = {
		name = "Sniper Rifle",
		slot = 6,
		price = 45000,
		ammoPrice = 500,
		damage = 95,
		range = 1400,
		fireRate = 1.5,
		magazine = 5,
		reserve = 25,
		reloadTime = 3.4,
		spread = 0.001,
		recoil = 6.0,
		pellets = 1,
		auto = false,
		loud = true,
		scope = 4.5, -- FOV divisor when aiming
		model = { length = 4.6, color = Color3.fromRGB(40, 42, 48) },
	},
}

--- Shop order for Ammu-Point.
WeaponCatalog.ForSale = { "pistol", "smg", "shotgun", "rifle", "sniper" }

--- Loadout every player starts with.
WeaponCatalog.Starter = { "fists", "pistol" }

function WeaponCatalog.get(id: string)
	return WeaponCatalog.Weapons[id]
end

--- Damage after distance falloff. Guns keep full damage to 60% of their range
--- then taper to 45% at maximum range.
function WeaponCatalog.damageAt(id: string, distance: number): number
	local weapon = WeaponCatalog.Weapons[id]
	if not weapon then
		return 0
	end
	local full = weapon.range * 0.6
	if distance <= full then
		return weapon.damage
	end
	local t = math.clamp((distance - full) / math.max(weapon.range - full, 1), 0, 1)
	return weapon.damage * (1 - 0.55 * t)
end

return WeaponCatalog
