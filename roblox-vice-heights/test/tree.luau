--!nonstrict
-- Builds the instance tree that default.project.json describes, so
-- `require(script.Parent.X)` and `ReplicatedStorage.Shared` resolve the same
-- way they would in Studio.

local function node(className, name, parent)
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local SharedFolder = node("Folder", "Shared", ReplicatedStorage)
local ServerScript = node("Script", "Server", ServerScriptService)
local StarterPlayerScripts = node("Folder", "StarterPlayerScripts", StarterPlayer)
local ClientScript = node("LocalScript", "Client", StarterPlayerScripts)

local PARENTS = {
	shared = SharedFolder,
	server = ServerScript,
	client = ClientScript,
}

for key, loader in __loaders do
	local folder, name = string.match(key, "^(%a+)/(.+)$")
	if name == "__entry" then
		local entry = folder == "server" and ServerScript or ClientScript
		__loaderOf[entry] = loader
	else
		local module = node("ModuleScript", name, PARENTS[folder])
		__loaderOf[module] = loader
	end
end

local Tree = {
	Shared = SharedFolder,
	ServerScript = ServerScript,
	ClientScript = ClientScript,
}
