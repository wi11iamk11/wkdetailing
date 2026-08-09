--!nonstrict
--[[
	Net
	Declarative remote registry. Every remote in the game is named here once, so
	a typo is a runtime error at startup instead of a silent no-op later.

	The server creates the folder and instances; the client waits for them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

-- client -> server, and server -> client. Direction is documented, not enforced
-- by the transport; each handler validates its own payload.
Net.Events = {
	-- server -> client
	State = "State", -- full/partial player state push (cash, wanted, ammo...)
	Notify = "Notify", -- toast messages
	Mission = "Mission", -- mission start/progress/complete
	Effect = "Effect", -- one-shot cosmetic effects (tracers, explosions)
	Hitmarker = "Hitmarker", -- confirmed hit feedback for the shooter
	VehicleAssigned = "VehicleAssigned",

	-- client -> server
	Interact = "Interact", -- "use" a world object by id
	Purchase = "Purchase",
	WeaponFire = "WeaponFire",
	WeaponReload = "WeaponReload",
	WeaponEquip = "WeaponEquip",
	VehicleRequest = "VehicleRequest",
	VehicleTelemetry = "VehicleTelemetry", -- steer angle etc. for remote visuals
	MissionRequest = "MissionRequest",
}

Net.Functions = {
	Fetch = "Fetch", -- initial state handshake
}

local folder: Folder

local function container(): Folder
	if folder and folder.Parent then
		return folder
	end
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild("Remotes")
		if not existing then
			existing = Instance.new("Folder")
			existing.Name = "Remotes"
			existing.Parent = ReplicatedStorage
		end
		folder = existing :: Folder
	else
		folder = ReplicatedStorage:WaitForChild("Remotes", 30) :: Folder
		assert(folder, "Net: remotes folder never replicated")
	end
	return folder
end

local function get(name: string, className: string): Instance
	local parent = container()
	local found = parent:FindFirstChild(name)
	if found then
		return found
	end
	if RunService:IsServer() then
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = parent
		return remote
	end
	local waited = parent:WaitForChild(name, 30)
	assert(waited, string.format("Net: remote %q never replicated", name))
	return waited
end

--- Creates every declared remote. Server-only; call once during bootstrap.
function Net.init()
	assert(RunService:IsServer(), "Net.init is server-only")
	for _, name in Net.Events do
		get(name, "RemoteEvent")
	end
	for _, name in Net.Functions do
		get(name, "RemoteFunction")
	end
end

function Net.event(name: string): RemoteEvent
	assert(Net.Events[name], string.format("Net: unknown event %q", tostring(name)))
	return get(name, "RemoteEvent") :: RemoteEvent
end

function Net.fn(name: string): RemoteFunction
	assert(Net.Functions[name], string.format("Net: unknown function %q", tostring(name)))
	return get(name, "RemoteFunction") :: RemoteFunction
end

--------------------------------------------------------------------------------
-- Rate limiting
--------------------------------------------------------------------------------

local buckets: { [string]: { tokens: number, updated: number } } = {}

--- Simple token bucket keyed by player + tag. Returns false when the caller is
--- over budget; every client -> server handler runs through this.
function Net.allow(player: Player, tag: string, perSecond: number, burst: number?): boolean
	local key = string.format("%d:%s", player.UserId, tag)
	local cap = burst or perSecond
	local now = os.clock()
	local bucket = buckets[key]
	if not bucket then
		bucket = { tokens = cap, updated = now }
		buckets[key] = bucket
	end
	bucket.tokens = math.min(cap, bucket.tokens + (now - bucket.updated) * perSecond)
	bucket.updated = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

function Net.clearLimits(player: Player)
	local prefix = tostring(player.UserId) .. ":"
	for key in buckets do
		if string.sub(key, 1, #prefix) == prefix then
			buckets[key] = nil
		end
	end
end

return Net
