--!nonstrict
--[[
	ClientState
	A local mirror of whatever the server has told us about this player. The
	server sends partial patches; everything on the client reads from here
	instead of holding its own copy, so the HUD, the minimap and the menus can
	never disagree.
]]

local ClientState = {}

local state: { [string]: any } = {
	cash = 0,
	bank = 0,
	wanted = 0,
	heat = 0,
	health = 100,
	armor = 0,
	equipped = "fists",
	mag = 0,
	weapons = {},
	vehicles = {},
	missions = {},
	objective = false,
	menu = false,
}

local listeners: { [string]: { (any) -> () } } = {}
local anyListeners: { ({ [string]: any }) -> () } = {}

function ClientState.get(key: string): any
	return state[key]
end

function ClientState.all(): { [string]: any }
	return state
end

--- Subscribes to one key. Fires immediately with the current value so callers
--- do not have to handle "before the first patch" separately.
function ClientState.onChange(key: string, fn: (any) -> ())
	local bucket = listeners[key]
	if not bucket then
		bucket = {}
		listeners[key] = bucket
	end
	table.insert(bucket, fn)
	task.spawn(fn, state[key])
end

function ClientState.onAny(fn: ({ [string]: any }) -> ())
	table.insert(anyListeners, fn)
end

function ClientState.merge(patch: { [string]: any })
	if type(patch) ~= "table" then
		return
	end

	local changed = {}
	for key, value in patch do
		-- `false` is how the server clears a key (nil would not survive the wire).
		local resolved = value
		state[key] = resolved
		changed[key] = resolved
	end

	for key, value in changed do
		local bucket = listeners[key]
		if bucket then
			for _, fn in bucket do
				task.spawn(fn, value)
			end
		end
	end
	for _, fn in anyListeners do
		task.spawn(fn, changed)
	end
end

return ClientState
