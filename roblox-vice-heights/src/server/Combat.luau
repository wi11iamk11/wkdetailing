--!nonstrict
--[[
	Combat
	One place where damage is applied, so armour, kill attribution, wanted-level
	consequences and cash drops can never drift apart between the weapon system,
	the police and vehicle impacts.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)

local DataService = require(script.Parent.DataService)
local WantedService = require(script.Parent.WantedService)

local Combat = {}

local killListeners: { (victim: Humanoid, attacker: Player?, kind: string) -> () } = {}
local rng = Random.new(os.time())

--- Fires (victimHumanoid, attackerPlayer, victimKind) on every death we cause.
function Combat.onKill(fn)
	table.insert(killListeners, fn)
end

function Combat.getArmor(character: Model?): number
	if not character then
		return 0
	end
	return character:GetAttribute("Armor") or 0
end

function Combat.setArmor(character: Model?, value: number)
	if not character then
		return
	end
	character:SetAttribute("Armor", math.clamp(value, 0, Config.Combat.MaxArmor))
end

--- Classifies a humanoid so callers do not have to know how NPCs are tagged.
function Combat.kindOf(humanoid: Humanoid): string
	local character = humanoid.Parent
	if character and Players:GetPlayerFromCharacter(character) then
		return "Player"
	end
	local tag = character and character:GetAttribute("NpcKind")
	return tag or "Unknown"
end

--- Applies damage with armour, attribution and consequences.
--- Returns the damage actually dealt and whether it was lethal.
function Combat.damage(humanoid: Humanoid, amount: number, attacker: Player?): (number, boolean)
	if not humanoid or humanoid.Health <= 0 or amount <= 0 then
		return 0, false
	end

	local character = humanoid.Parent
	local kind = Combat.kindOf(humanoid)
	local applied = amount

	-- Armour eats a fraction of incoming damage until it is gone.
	if kind == "Player" then
		local armor = Combat.getArmor(character)
		if armor > 0 then
			local absorbed = math.min(armor, amount * Config.Combat.ArmorAbsorb)
			Combat.setArmor(character, armor - absorbed)
			applied = amount - absorbed
			local victim = Players:GetPlayerFromCharacter(character)
			if victim then
				DataService.push(victim, { armor = Combat.getArmor(character) })
			end
		end
	end

	humanoid:TakeDamage(applied)

	if attacker and character then
		character:SetAttribute("LastAttackerUserId", attacker.UserId)
		character:SetAttribute("LastAttackedAt", os.time())
	end

	local killed = humanoid.Health <= 0
	if not killed then
		return applied, false
	end

	if attacker and attacker.Parent then
		if kind == "Ped" then
			WantedService.addCrime(attacker, "PedKill")
			local drop = rng:NextInteger(Config.Economy.PedCashDrop.Min, Config.Economy.PedCashDrop.Max)
			DataService.addCash(attacker, drop, "picked up")
			DataService.bumpStat(attacker, "kills", 1)
		elseif kind == "Cop" then
			WantedService.addCrime(attacker, "CopKill")
			DataService.bumpStat(attacker, "kills", 1)
		elseif kind == "Player" then
			WantedService.addCrime(attacker, "PedKill")
			DataService.bumpStat(attacker, "kills", 1)
		end
	end

	for _, listener in killListeners do
		task.spawn(listener, humanoid, attacker, kind)
	end

	return applied, true
end

--- Damage everything alive inside a sphere. Used by explosions.
--- Queries the broadphase rather than walking the workspace: an explosion in a
--- city of thousands of parts should cost the same as one in an empty field.
function Combat.splash(position: Vector3, radius: number, amount: number, attacker: Player?)
	local seen: { [Humanoid]: boolean } = {}

	for _, part in workspace:GetPartBoundsInRadius(position, radius) do
		local humanoid = Util.humanoidOf(part)
		if humanoid and not seen[humanoid] and humanoid.Health > 0 then
			seen[humanoid] = true
			local root = Util.rootOf(humanoid.Parent)
			local distance = root and (root.Position - position).Magnitude or radius
			local falloff = 1 - math.clamp(distance / radius, 0, 1) * 0.6
			Combat.damage(humanoid, amount * falloff, attacker)
		end
	end
end

return Combat
