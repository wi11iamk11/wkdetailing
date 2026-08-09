--!nonstrict
--[[
	WantedService
	The heat meter. Crimes add heat, heat maps to stars, and heat only bleeds
	away once no officer has had eyes on the player for a while — which is what
	makes hiding feel like a decision rather than a timer.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local DataService = require(script.Parent.DataService)

local WantedService = {}

type Heat = {
	heat: number,
	stars: number,
	lastSeen: number,
	recent: { [string]: number },
}

local heats: { [Player]: Heat } = {}
local listeners: { (Player, number, number) -> () } = {}

local W = Config.Wanted

local function ensure(player: Player): Heat
	local entry = heats[player]
	if not entry then
		entry = { heat = 0, stars = 0, lastSeen = 0, recent = {} }
		heats[player] = entry
	end
	return entry
end

local function starsFor(heat: number): number
	local stars = 0
	for index, threshold in W.StarThresholds do
		if heat >= threshold then
			stars = index
		end
	end
	return stars
end

local function apply(player: Player, entry: Heat)
	local stars = starsFor(entry.heat)
	if stars == entry.stars then
		DataService.push(player, { heat = entry.heat })
		return
	end

	local previous = entry.stars
	entry.stars = stars
	DataService.push(player, { wanted = stars, heat = entry.heat })

	if stars > previous then
		DataService.notify(
			player,
			string.format("Wanted level: %d star%s", stars, stars == 1 and "" or "s"),
			"wanted"
		)
	elseif stars == 0 then
		DataService.notify(player, "You lost the cops.", "good")
	end

	for _, listener in listeners do
		task.spawn(listener, player, stars, previous)
	end
end

--- Fires (player, newStars, oldStars) whenever the star count changes.
function WantedService.onChanged(fn: (Player, number, number) -> ())
	table.insert(listeners, fn)
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

function WantedService.getStars(player: Player): number
	local entry = heats[player]
	return entry and entry.stars or 0
end

function WantedService.getHeat(player: Player): number
	local entry = heats[player]
	return entry and entry.heat or 0
end

function WantedService.isWanted(player: Player): boolean
	return WantedService.getStars(player) > 0
end

--- Everyone the police should currently be hunting, most wanted first.
function WantedService.wantedPlayers(): { Player }
	local out = {}
	for player, entry in heats do
		if entry.stars > 0 and player.Parent then
			table.insert(out, player)
		end
	end
	table.sort(out, function(a, b)
		return heats[a].stars > heats[b].stars
	end)
	return out
end

--------------------------------------------------------------------------------
-- Mutation
--------------------------------------------------------------------------------

--- Records a crime by name (see Config.Wanted.Crimes). Repeats of the same
--- crime inside the stack window are discounted so one shotgun blast into a
--- crowd does not jump straight to five stars.
function WantedService.addCrime(player: Player, crime: string, multiplier: number?)
	local value = W.Crimes[crime]
	if not value or not player.Parent then
		return
	end

	local entry = ensure(player)
	local now = os.clock()
	local last = entry.recent[crime]
	local scale = multiplier or 1

	if last and now - last < W.CrimeStackWindow then
		scale *= W.CrimeStackFalloff
	end
	entry.recent[crime] = now

	entry.heat = math.clamp(entry.heat + value * scale, 0, W.MaxHeat)
	-- Committing a crime counts as being noticed.
	entry.lastSeen = now
	apply(player, entry)
end

function WantedService.addHeat(player: Player, amount: number)
	local entry = ensure(player)
	entry.heat = math.clamp(entry.heat + amount, 0, W.MaxHeat)
	if amount > 0 then
		entry.lastSeen = os.clock()
	end
	apply(player, entry)
end

--- Forces a minimum star count, used by scripted mission beats.
function WantedService.setStars(player: Player, stars: number)
	local entry = ensure(player)
	stars = math.clamp(stars, 0, W.MaxStars)
	if stars == 0 then
		entry.heat = 0
	else
		entry.heat = math.max(entry.heat, W.StarThresholds[stars])
		entry.lastSeen = os.clock()
	end
	apply(player, entry)
end

function WantedService.clear(player: Player)
	local entry = ensure(player)
	entry.heat = 0
	entry.recent = {}
	apply(player, entry)
end

--- Called by the police AI every time an officer can actually see the player.
function WantedService.markSeen(player: Player)
	local entry = heats[player]
	if entry then
		entry.lastSeen = os.clock()
	end
end

--- Seconds since an officer last had eyes on the player.
function WantedService.timeSinceSeen(player: Player): number
	local entry = heats[player]
	if not entry then
		return math.huge
	end
	return os.clock() - entry.lastSeen
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function WantedService.start()
	Players.PlayerAdded:Connect(function(player)
		ensure(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		heats[player] = nil
	end)

	DataService.registerProvider(function(player)
		local entry = ensure(player)
		return { wanted = entry.stars, heat = entry.heat, maxHeat = W.MaxHeat }
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.5 then
			return
		end
		local step = accumulator
		accumulator = 0

		for player, entry in heats do
			if entry.heat > 0 and os.clock() - entry.lastSeen >= W.CooldownDelay then
				entry.heat = math.max(0, entry.heat - W.DecayPerSecond * step)
				apply(player, entry)
			end
		end
	end)
end

return WantedService
