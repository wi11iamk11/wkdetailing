--!nonstrict
--[[
	MissionCatalog
	Mission definitions. Each mission is a small state machine described as an
	ordered list of stages; MissionService interprets them so adding content
	means adding data, not code.

	Stage kinds:
		goto      reach a position within `radius`
		collect   reach a position and pick up a carried item
		deliver   reach a position while carrying
		eliminate kill `count` spawned targets
		survive   stay alive for `duration` seconds
		checkpoint drive through an ordered list of points
		escape    lose the wanted level
]]

local MissionCatalog = {}

MissionCatalog.Missions = {
	{
		id = "courier",
		name = "Special Delivery",
		giver = "MissionBoard",
		tier = 1,
		payout = 2200,
		description = "Pick up a package downtown and drop it at the docks. Don't be slow.",
		timeLimit = 180,
		stages = {
			{ kind = "collect", at = "random_road", radius = 12, prompt = "Collect the package" },
			{ kind = "deliver", at = "Store3", radius = 16, prompt = "Deliver the package" },
		},
	},

	{
		id = "repo",
		name = "Repo Man",
		giver = "MissionBoard",
		tier = 1,
		payout = 3400,
		wantedOnStart = 1,
		description = "Boost a car the boss says he owns. He does not own it.",
		timeLimit = 240,
		stages = {
			{
				kind = "goto",
				at = "random_road",
				radius = 14,
				prompt = "Find the target vehicle",
				spawnVehicle = true,
			},
			{
				kind = "deliver",
				at = "Garage",
				radius = 20,
				prompt = "Return the vehicle to the garage",
				requireVehicle = true,
			},
		},
	},

	{
		id = "streetrace",
		name = "Midnight Circuit",
		giver = "MissionBoard",
		tier = 2,
		payout = 5200,
		requireVehicle = true,
		description = "Four checkpoints, one lap, no excuses. Bring a car.",
		timeLimit = 150,
		stages = {
			{ kind = "checkpoint", count = 5, radius = 22, prompt = "Hit the checkpoints" },
		},
	},

	{
		id = "cleanup",
		name = "Loose Ends",
		giver = "MissionBoard",
		tier = 2,
		payout = 6800,
		wantedOnStart = 2,
		description = "Three witnesses. Make them not witnesses.",
		timeLimit = 300,
		stages = {
			{ kind = "eliminate", count = 3, radius = 200, prompt = "Eliminate the targets", armed = true },
			{ kind = "escape", prompt = "Lose the cops" },
		},
	},

	{
		id = "heist",
		name = "The Vault Job",
		giver = "MissionBoard",
		tier = 3,
		payout = 18500,
		description = "Hit the store, hold the register, and get gone before the heat lands.",
		timeLimit = 420,
		stages = {
			{ kind = "goto", at = "Store2", radius = 16, prompt = "Get to the store" },
			{ kind = "survive", duration = 20, radius = 26, prompt = "Empty the register", wanted = 3 },
			{ kind = "deliver", at = "Garage", radius = 20, prompt = "Stash the money" },
			{ kind = "escape", prompt = "Lose the cops" },
		},
	},
}

MissionCatalog.ById = {}
for _, mission in MissionCatalog.Missions do
	MissionCatalog.ById[mission.id] = mission
end

function MissionCatalog.get(id: string)
	return MissionCatalog.ById[id]
end

--- Missions the player can currently take, given how many they have finished.
function MissionCatalog.available(completed: { [string]: number }): { any }
	local done = 0
	for _ in completed do
		done += 1
	end
	local out = {}
	for _, mission in MissionCatalog.Missions do
		-- Tier 2 unlocks after one job, tier 3 after three.
		local required = (mission.tier == 1 and 0) or (mission.tier == 2 and 1) or 3
		if done >= required then
			table.insert(out, mission)
		end
	end
	return out
end

return MissionCatalog
