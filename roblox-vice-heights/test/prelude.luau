--!nonstrict
--[[
	Test prelude: a small Roblox API mock.

	Enough of the engine to actually *run* the game's modules outside Studio:
	instances, signals, the datatypes we use, a cooperative task scheduler and
	a flat-ground raycaster. It is not an emulator — it exists so `luau` can
	execute the real gameplay code and surface runtime errors.
]]

local Mock = {}

--------------------------------------------------------------------------------
-- Scheduler
--------------------------------------------------------------------------------

local clock = 0
local queue = {} -- { time, thread | fn }

local function schedule(at, thread)
	table.insert(queue, { time = at, thread = thread })
end

local task = {}

function task.spawn(fn, ...)
	local thread = type(fn) == "thread" and fn or coroutine.create(fn)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		error("task.spawn: " .. tostring(err), 0)
	end
	return thread
end

function task.defer(fn, ...)
	local args = table.pack(...)
	schedule(
		clock,
		coroutine.create(function()
			fn(table.unpack(args, 1, args.n))
		end)
	)
end

function task.delay(seconds, fn, ...)
	local args = table.pack(...)
	schedule(
		clock + (seconds or 0),
		coroutine.create(function()
			fn(table.unpack(args, 1, args.n))
		end)
	)
	return {}
end

function task.wait(seconds)
	local thread = coroutine.running()
	schedule(clock + (seconds or 0), thread)
	coroutine.yield()
	return seconds or 0
end

function task.cancel() end

--- Advances the fake clock and resumes anything that came due.
function Mock.step(dt)
	clock += dt
	local due = {}
	local remaining = {}
	for _, entry in queue do
		if entry.time <= clock then
			table.insert(due, entry)
		else
			table.insert(remaining, entry)
		end
	end
	queue = remaining

	for _, entry in due do
		if coroutine.status(entry.thread) == "suspended" then
			local ok, err = coroutine.resume(entry.thread)
			if not ok then
				error("scheduled thread: " .. tostring(err), 0)
			end
		end
	end
end

function Mock.now()
	return clock
end

local os_ = {
	clock = function()
		return clock
	end,
	time = function()
		return 1770000000 + math.floor(clock)
	end,
}

--------------------------------------------------------------------------------
-- Datatypes
--------------------------------------------------------------------------------

local Vector3 = {}
Vector3.__index = Vector3

local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

function Vector3.new(x, y, z)
	return v3(x, y, z)
end

Vector3.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(a)
	return string.format("(%.2f, %.2f, %.2f)", a.X, a.Y, a.Z)
end
Vector3.__mul = function(a, b)
	if type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	if type(a) == "number" then
		return v3(b.X * a, b.Y * a, b.Z * a)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
		if m < 1e-9 then
			return v3(0, 0, 0)
		end
		return v3(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3, key)
end
function Vector3:Dot(b)
	return self.X * b.X + self.Y * b.Y + self.Z * b.Z
end
function Vector3:Cross(b)
	return v3(self.Y * b.Z - self.Z * b.Y, self.Z * b.X - self.X * b.Z, self.X * b.Y - self.Y * b.X)
end
function Vector3:Lerp(b, t)
	return self + (b - self) * t
end

Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)
Vector3.xAxis = v3(1, 0, 0)
Vector3.yAxis = v3(0, 1, 0)
Vector3.zAxis = v3(0, 0, 1)

local Vector2 = {}
Vector2.__index = Vector2
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, Vector2)
end

--------------------------------------------------------------------------------
-- CFrame (position + row-major 3x3 rotation)
--------------------------------------------------------------------------------

local CFrame = {}
CFrame.__index = CFrame

local function cf(px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({
		p = v3(px, py, pz),
		r = { r00, r01, r02, r10, r11, r12, r20, r21, r22 },
	}, CFrame)
end

local function identity(px, py, pz)
	return cf(px or 0, py or 0, pz or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
end

local function matMul(a, b)
	local out = {}
	for row = 0, 2 do
		for col = 0, 2 do
			local sum = 0
			for k = 0, 2 do
				sum += a[row * 3 + k + 1] * b[k * 3 + col + 1]
			end
			out[row * 3 + col + 1] = sum
		end
	end
	return out
end

local function matApply(r, vec)
	return v3(
		r[1] * vec.X + r[2] * vec.Y + r[3] * vec.Z,
		r[4] * vec.X + r[5] * vec.Y + r[6] * vec.Z,
		r[7] * vec.X + r[8] * vec.Y + r[9] * vec.Z
	)
end

local function matApplyT(r, vec)
	return v3(
		r[1] * vec.X + r[4] * vec.Y + r[7] * vec.Z,
		r[2] * vec.X + r[5] * vec.Y + r[8] * vec.Z,
		r[3] * vec.X + r[6] * vec.Y + r[9] * vec.Z
	)
end

function CFrame.new(...)
	local args = { ... }
	local count = select("#", ...)
	if count == 0 then
		return identity(0, 0, 0)
	elseif count == 1 and type(args[1]) == "table" then
		return identity(args[1].X, args[1].Y, args[1].Z)
	elseif count == 2 then
		return CFrame.lookAt(args[1], args[2])
	elseif count == 3 then
		return identity(args[1], args[2], args[3])
	elseif count == 12 then
		return cf(table.unpack(args))
	end
	return identity(args[1] or 0, args[2] or 0, args[3] or 0)
end

function CFrame.lookAt(from, to, up)
	up = up or Vector3.yAxis
	local forward = (to - from)
	if forward.Magnitude < 1e-6 then
		forward = v3(0, 0, -1)
	else
		forward = forward.Unit
	end
	local right = forward:Cross(up)
	if right.Magnitude < 1e-6 then
		right = forward:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local realUp = right:Cross(forward).Unit
	return cf(
		from.X,
		from.Y,
		from.Z,
		right.X,
		realUp.X,
		-forward.X,
		right.Y,
		realUp.Y,
		-forward.Y,
		right.Z,
		realUp.Z,
		-forward.Z
	)
end

function CFrame.Angles(x, y, z)
	local cx, sx = math.cos(x), math.sin(x)
	local cy, sy = math.cos(y), math.sin(y)
	local cz, sz = math.cos(z), math.sin(z)
	local rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	local r = matMul(matMul(rx, ry), rz)
	return cf(0, 0, 0, table.unpack(r))
end

CFrame.fromEulerAnglesXYZ = CFrame.Angles
CFrame.identity = identity(0, 0, 0)

CFrame.__mul = function(a, b)
	if getmetatable(b) == Vector3 then
		return a.p + matApply(a.r, b)
	end
	local r = matMul(a.r, b.r)
	local p = a.p + matApply(a.r, b.p)
	return cf(p.X, p.Y, p.Z, table.unpack(r))
end
CFrame.__add = function(a, b)
	return cf(a.p.X + b.X, a.p.Y + b.Y, a.p.Z + b.Z, table.unpack(a.r))
end
CFrame.__index = function(self, key)
	if key == "Position" or key == "p" then
		return rawget(self, "p")
	elseif key == "X" then
		return rawget(self, "p").X
	elseif key == "Y" then
		return rawget(self, "p").Y
	elseif key == "Z" then
		return rawget(self, "p").Z
	elseif key == "LookVector" then
		local r = rawget(self, "r")
		return v3(-r[3], -r[6], -r[9])
	elseif key == "RightVector" then
		local r = rawget(self, "r")
		return v3(r[1], r[4], r[7])
	elseif key == "UpVector" then
		local r = rawget(self, "r")
		return v3(r[2], r[5], r[8])
	elseif key == "Rotation" then
		local r = rawget(self, "r")
		return cf(0, 0, 0, table.unpack(r))
	end
	return rawget(CFrame, key)
end

function CFrame:VectorToObjectSpace(vec)
	return matApplyT(rawget(self, "r"), vec)
end
function CFrame:VectorToWorldSpace(vec)
	return matApply(rawget(self, "r"), vec)
end
function CFrame:PointToObjectSpace(point)
	return matApplyT(rawget(self, "r"), point - rawget(self, "p"))
end
function CFrame:Inverse()
	local r = rawget(self, "r")
	local inv = { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
	local p = -matApplyT(r, rawget(self, "p"))
	return cf(p.X, p.Y, p.Z, table.unpack(inv))
end
function CFrame:ToEulerAnglesYXZ()
	local r = rawget(self, "r")
	local x = math.asin(math.clamp(-r[6], -1, 1))
	local y = math.atan2(r[3], r[9])
	local z = math.atan2(r[4], r[5])
	return x, y, z
end
CFrame.ToOrientation = CFrame.ToEulerAnglesYXZ
function CFrame:Lerp(other, t)
	local p = rawget(self, "p"):Lerp(rawget(other, "p"), t)
	-- Good enough for a smoke test: snap rotation past the halfway point.
	local r = t < 0.5 and rawget(self, "r") or rawget(other, "r")
	return cf(p.X, p.Y, p.Z, table.unpack(r))
end

--------------------------------------------------------------------------------
-- Simple value types
--------------------------------------------------------------------------------

local Color3 = {}
Color3.__index = Color3
local function color(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, Color3)
end
function Color3.new(r, g, b)
	return color(r or 0, g or 0, b or 0)
end
function Color3.fromRGB(r, g, b)
	return color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h, s, v)
	return color(h, s, v)
end

local UDim = {}
UDim.__index = UDim
function UDim.new(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDim)
end

local UDim2 = {}
UDim2.__index = UDim2
local function udim2(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }, UDim2)
end
function UDim2.new(xs, xo, ys, yo)
	return udim2(xs or 0, xo or 0, ys or 0, yo or 0)
end
function UDim2.fromOffset(x, y)
	return udim2(0, x or 0, 0, y or 0)
end
function UDim2.fromScale(x, y)
	return udim2(x or 0, 0, y or 0, 0)
end

local function PhysicalProperties_new(...)
	return { ... }
end
local function TweenInfo_new(...)
	return { ... }
end

local Random = {}
Random.__index = Random
function Random.new(seed)
	local self = setmetatable({}, Random)
	self.state = (seed or 0) % 2147483647
	if self.state <= 0 then
		self.state += 2147483646
	end
	return self
end
function Random:NextNumber(a, b)
	self.state = (self.state * 16807) % 2147483647
	local r = self.state / 2147483647
	if a and b then
		return a + r * (b - a)
	end
	return r
end
function Random:NextInteger(a, b)
	return math.floor(self:NextNumber() * (b - a + 1)) + a
end

--------------------------------------------------------------------------------
-- Enum (auto-vivifying)
--------------------------------------------------------------------------------

local enumItemMeta = {
	__tostring = function(self)
		return "Enum." .. self.EnumType .. "." .. self.Name
	end,
	__eq = function(a, b)
		return a.EnumType == b.EnumType and a.Name == b.Name
	end,
}

local Enum = setmetatable({}, {
	__index = function(self, enumType)
		local items = setmetatable({}, {
			__index = function(bucket, name)
				local item = setmetatable({ Name = name, EnumType = enumType, Value = 0 }, enumItemMeta)
				rawset(bucket, name, item)
				return item
			end,
		})
		-- A few enum values are read as numbers by the game code.
		if enumType == "RenderPriority" then
			items = setmetatable({}, {
				__index = function(bucket, name)
					local item = { Name = name, EnumType = enumType, Value = 200 }
					rawset(bucket, name, item)
					return item
				end,
			})
		end
		rawset(self, enumType, items)
		return items
	end,
})

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end

function Signal:Connect(fn)
	table.insert(self.handlers, fn)
	local connection
	connection = {
		Connected = true,
		Disconnect = function()
			connection.Connected = false
			for index, handler in self.handlers do
				if handler == fn then
					table.remove(self.handlers, index)
					break
				end
			end
		end,
	}
	return connection
end

Signal.Once = Signal.Connect

function Signal:Fire(...)
	for _, fn in table.clone(self.handlers) do
		task.spawn(fn, ...)
	end
end

function Signal:Wait()
	return nil
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local CLASS_PARENTS = {
	Part = "BasePart",
	MeshPart = "BasePart",
	Seat = "BasePart",
	VehicleSeat = "BasePart",
	SpawnLocation = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	PVInstance = "Instance",
	Folder = "Instance",
	Humanoid = "Instance",
	Tool = "Instance",
	Frame = "GuiObject",
	TextLabel = "GuiObject",
	TextButton = "GuiObject",
	ImageLabel = "GuiObject",
	ScrollingFrame = "GuiObject",
	GuiObject = "Instance",
	ScreenGui = "Instance",
	SurfaceGui = "Instance",
	RemoteEvent = "Instance",
	RemoteFunction = "Instance",
	Motor6D = "Instance",
	WeldConstraint = "Instance",
	Attachment = "Instance",
	VectorForce = "Instance",
	Torque = "Instance",
	PointLight = "Instance",
	SpotLight = "Instance",
	ProximityPrompt = "Instance",
	Highlight = "Instance",
	Explosion = "Instance",
	Smoke = "Instance",
	Animation = "Instance",
	Animator = "Instance",
	SpecialMesh = "Instance",
	IntValue = "Instance",
	UICorner = "Instance",
	UIListLayout = "Instance",
	UIStroke = "Instance",
}

local EVENTS = {
	Died = true,
	HealthChanged = true,
	Running = true,
	StateChanged = true,
	Seated = true,
	Touched = true,
	TouchEnded = true,
	Equipped = true,
	Unequipped = true,
	Activated = true,
	ChildAdded = true,
	ChildRemoved = true,
	DescendantAdded = true,
	AncestryChanged = true,
	Changed = true,
	PlayerAdded = true,
	PlayerRemoving = true,
	CharacterAdded = true,
	CharacterRemoving = true,
	PromptTriggered = true,
	OnServerEvent = true,
	OnClientEvent = true,
	Heartbeat = true,
	Stepped = true,
	RenderStepped = true,
	Completed = true,
	MoveToFinished = true,
	InputBegan = true,
	InputEnded = true,
	InputChanged = true,
}

local Instance = {}
local instanceMethods = {}

local function isA(self, className)
	local current = rawget(self, "_class")
	while current do
		if current == className then
			return true
		end
		current = CLASS_PARENTS[current]
	end
	return className == "Instance"
end

local function setParent(self, parent)
	local old = rawget(self, "_parent")
	if old then
		local siblings = rawget(old, "_children")
		for index, child in siblings do
			if child == self then
				table.remove(siblings, index)
				break
			end
		end
	end
	rawset(self, "_parent", parent)
	if parent then
		table.insert(rawget(parent, "_children"), self)
		local signal = rawget(parent, "_signals").ChildAdded
		if signal then
			signal:Fire(self)
		end
	end
end

local InstanceMT = {
	__index = function(self, key)
		local props = rawget(self, "_props")
		local value = props[key]
		if value ~= nil then
			return value
		end
		if key == "Parent" then
			return rawget(self, "_parent")
		end
		if key == "ClassName" then
			return rawget(self, "_class")
		end
		local method = instanceMethods[key]
		if method then
			return method
		end
		if EVENTS[key] then
			local signals = rawget(self, "_signals")
			if not signals[key] then
				signals[key] = Signal.new()
			end
			return signals[key]
		end
		for _, child in rawget(self, "_children") do
			if rawget(child, "_props").Name == key then
				return child
			end
		end
		return nil
	end,

	__newindex = function(self, key, value)
		if key == "Parent" then
			setParent(self, value)
			return
		end
		rawget(self, "_props")[key] = value
		local watchers = rawget(self, "_propSignals")[key]
		if watchers then
			watchers:Fire()
		end
	end,

	__tostring = function(self)
		return rawget(self, "_props").Name or rawget(self, "_class")
	end,
}

local function newInstance(className)
	local self = setmetatable({
		_class = className,
		_props = { Name = className },
		_children = {},
		_parent = nil,
		_signals = {},
		_propSignals = {},
		_attributes = {},
		_attrSignals = {},
	}, InstanceMT)
	return self
end

function instanceMethods.IsA(self, className)
	return isA(self, className)
end

function instanceMethods.GetChildren(self)
	return table.clone(rawget(self, "_children"))
end

function instanceMethods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, child in rawget(node, "_children") do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function instanceMethods.FindFirstChild(self, name)
	for _, child in rawget(self, "_children") do
		if rawget(child, "_props").Name == name then
			return child
		end
	end
	return nil
end

function instanceMethods.WaitForChild(self, name)
	return instanceMethods.FindFirstChild(self, name)
end

function instanceMethods.FindFirstChildOfClass(self, className)
	for _, child in rawget(self, "_children") do
		if rawget(child, "_class") == className then
			return child
		end
	end
	return nil
end

function instanceMethods.FindFirstChildWhichIsA(self, className)
	for _, child in rawget(self, "_children") do
		if isA(child, className) then
			return child
		end
	end
	return nil
end

function instanceMethods.FindFirstAncestorOfClass(self, className)
	local node = rawget(self, "_parent")
	while node do
		if rawget(node, "_class") == className then
			return node
		end
		node = rawget(node, "_parent")
	end
	return nil
end

function instanceMethods.FindFirstAncestorWhichIsA(self, className)
	local node = rawget(self, "_parent")
	while node do
		if isA(node, className) then
			return node
		end
		node = rawget(node, "_parent")
	end
	return nil
end

function instanceMethods.IsDescendantOf(self, other)
	local node = rawget(self, "_parent")
	while node do
		if node == other then
			return true
		end
		node = rawget(node, "_parent")
	end
	return false
end

function instanceMethods.Destroy(self)
	setParent(self, nil)
	rawset(self, "_destroyed", true)
end

function instanceMethods.ClearAllChildren(self)
	for _, child in table.clone(rawget(self, "_children")) do
		instanceMethods.Destroy(child)
	end
end

function instanceMethods.SetAttribute(self, name, value)
	rawget(self, "_attributes")[name] = value
	local signal = rawget(self, "_attrSignals")[name]
	if signal then
		signal:Fire()
	end
end

function instanceMethods.GetAttribute(self, name)
	return rawget(self, "_attributes")[name]
end

function instanceMethods.GetAttributeChangedSignal(self, name)
	local signals = rawget(self, "_attrSignals")
	if not signals[name] then
		signals[name] = Signal.new()
	end
	return signals[name]
end

function instanceMethods.GetPropertyChangedSignal(self, name)
	local signals = rawget(self, "_propSignals")
	if not signals[name] then
		signals[name] = Signal.new()
	end
	return signals[name]
end

function instanceMethods.GetPivot(self)
	local props = rawget(self, "_props")
	if props.CFrame then
		return props.CFrame
	end
	local primary = props.PrimaryPart
	if primary then
		return rawget(primary, "_props").CFrame or CFrame.new()
	end
	return CFrame.new()
end

function instanceMethods.PivotTo(self, target)
	local props = rawget(self, "_props")
	if isA(self, "BasePart") then
		props.CFrame = target
		return
	end
	local primary = props.PrimaryPart
	if primary then
		rawget(primary, "_props").CFrame = target
	end
	for _, child in rawget(self, "_children") do
		if isA(child, "BasePart") and child ~= primary then
			rawget(child, "_props").CFrame = target
		end
	end
end

instanceMethods.SetPrimaryPartCFrame = instanceMethods.PivotTo

function instanceMethods.Clone(self)
	local copy = newInstance(rawget(self, "_class"))
	for key, value in rawget(self, "_props") do
		rawget(copy, "_props")[key] = value
	end
	return copy
end

-- BasePart / Humanoid / other class-specific methods.
function instanceMethods.SetNetworkOwner() end
function instanceMethods.SetNetworkOwnershipAuto() end
function instanceMethods.GetNetworkOwner()
	return nil
end
function instanceMethods.CanSetNetworkOwnership()
	return true, nil
end
function instanceMethods.GetVelocityAtPosition()
	return Vector3.zero
end
function instanceMethods.ApplyImpulse() end

function instanceMethods.TakeDamage(self, amount)
	local props = rawget(self, "_props")
	props.Health = math.max(0, (props.Health or 100) - amount)
	local changed = rawget(self, "_signals").HealthChanged
	if changed then
		changed:Fire(props.Health)
	end
	if props.Health <= 0 then
		local died = rawget(self, "_signals").Died
		if died then
			died:Fire()
		end
	end
end

function instanceMethods.MoveTo(self, target)
	rawget(self, "_props").MoveTarget = target
end

function instanceMethods.Sit(self, humanoid)
	rawget(self, "_props").Occupant = humanoid
	if humanoid then
		rawget(humanoid, "_props").SeatPart = self
		local seated = rawget(humanoid, "_signals").Seated
		if seated then
			seated:Fire(true, self)
		end
	end
	local watchers = rawget(self, "_propSignals").Occupant
	if watchers then
		watchers:Fire()
	end
end

function instanceMethods.LoadAnimation(self)
	return {
		Priority = nil,
		Looped = false,
		Play = function() end,
		Stop = function() end,
		AdjustSpeed = function() end,
	}
end

-- Remotes are wired straight through, so a server FireClient really does run
-- the client handler. That is the point: it exercises both sides for real.
local function clientSignal(self)
	local signals = rawget(self, "_signals")
	if not signals.OnClientEvent then
		signals.OnClientEvent = Signal.new()
	end
	return signals.OnClientEvent
end

local function serverSignal(self)
	local signals = rawget(self, "_signals")
	if not signals.OnServerEvent then
		signals.OnServerEvent = Signal.new()
	end
	return signals.OnServerEvent
end

function instanceMethods.FireClient(self, player, ...)
	if player == Mock.localPlayer then
		clientSignal(self):Fire(...)
	end
end

function instanceMethods.FireAllClients(self, ...)
	clientSignal(self):Fire(...)
end

function instanceMethods.FireServer(self, ...)
	serverSignal(self):Fire(Mock.localPlayer, ...)
end

function instanceMethods.InvokeServer(self, ...)
	local handler = rawget(self, "_props").OnServerInvoke
	if handler then
		return handler(Mock.localPlayer, ...)
	end
	return nil
end

function Instance.new(className, parent)
	local created = newInstance(className)
	-- Defaults the game code reads back.
	local props = rawget(created, "_props")
	if isA(created, "BasePart") then
		props.CFrame = CFrame.new()
		props.Position = Vector3.zero
		props.Size = Vector3.new(4, 1, 2)
		props.Anchored = false
		props.AssemblyLinearVelocity = Vector3.zero
		props.AssemblyAngularVelocity = Vector3.zero
		props.AssemblyCenterOfMass = Vector3.zero
		props.AssemblyMass = 1200
	elseif className == "Humanoid" then
		props.Health = 100
		props.MaxHealth = 100
		props.WalkSpeed = 16
		props.MoveDirection = Vector3.zero
	elseif className == "VehicleSeat" then
		props.Throttle = 0
		props.Steer = 0
	end
	if parent then
		setParent(created, parent)
	end
	return created
end

-- BasePart.Position must track CFrame; the game reads both.
local basePartPosition = InstanceMT.__index
InstanceMT.__index = function(self, key)
	if key == "Position" and isA(self, "BasePart") then
		local props = rawget(self, "_props")
		if props.CFrame then
			return props.CFrame.Position
		end
	end
	return basePartPosition(self, key)
end

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

local services = {}

local function service(className, name)
	local instance = newInstance(className)
	rawget(instance, "_props").Name = name or className
	services[name or className] = instance
	return instance
end

local Workspace = service("Workspace", "Workspace")
rawget(Workspace, "_props").Gravity = 196.2
local terrain = Instance.new("Terrain", Workspace)
rawget(terrain, "_props").Name = "Terrain"
function instanceMethods.FillBlock() end

local camera = Instance.new("Camera", Workspace)
rawget(camera, "_props").Name = "Camera"
rawget(camera, "_props").CFrame = CFrame.new()
rawget(camera, "_props").ViewportSize = Vector2.new(1920, 1080)
rawget(camera, "_props").FieldOfView = 70
rawget(Workspace, "_props").CurrentCamera = camera
function instanceMethods.ViewportPointToRay()
	return { Origin = Vector3.new(0, 20, 0), Direction = Vector3.new(0, 0, -1) }
end

--- Flat ground at y = 0.4 plus a hard floor, which is all CarSim needs.
local groundPart = Instance.new("Part", Workspace)
rawget(groundPart, "_props").Name = "MockGround"

function instanceMethods.Raycast(self, origin, direction)
	if direction.Y >= -1e-6 then
		return nil
	end
	local groundY = 0.4
	if origin.Y <= groundY then
		return nil
	end
	local t = (groundY - origin.Y) / direction.Y
	if t < 0 or t > 1 then
		return nil
	end
	local hit = origin + direction * t
	return {
		Position = hit,
		Normal = Vector3.yAxis,
		Distance = (hit - origin).Magnitude,
		Instance = groundPart,
		Material = Enum.Material.Asphalt,
	}
end

function instanceMethods.GetPartBoundsInBox()
	return {}
end

--- Brute-force stand-in for the broadphase. Correct, not fast.
function instanceMethods.GetPartBoundsInRadius(self, position, radius)
	local out = {}
	for _, descendant in instanceMethods.GetDescendants(self) do
		if isA(descendant, "BasePart") then
			local props = rawget(descendant, "_props")
			if props.CFrame and (props.CFrame.Position - position).Magnitude <= radius then
				table.insert(out, descendant)
			end
		end
	end
	return out
end

local ReplicatedStorage = service("ReplicatedStorage")
local ServerScriptService = service("ServerScriptService")
local ServerStorage = service("ServerStorage")
local Lighting = service("Lighting")
rawget(Lighting, "_props").ClockTime = 14
rawget(Lighting, "_props").Brightness = 2
local SoundService = service("SoundService")
local StarterPlayer = service("StarterPlayer")

local Players = service("Players")
rawget(Players, "_props")._list = {}
function instanceMethods.GetPlayers(self)
	return table.clone(rawget(self, "_props")._list or {})
end
function instanceMethods.GetPlayerFromCharacter(self, character)
	for _, player in rawget(self, "_props")._list or {} do
		if rawget(player, "_props").Character == character then
			return player
		end
	end
	return nil
end

local RunService = service("RunService")
function instanceMethods.IsServer()
	return Mock.isServer
end
function instanceMethods.IsClient()
	return not Mock.isServer
end
function instanceMethods.IsStudio()
	return true
end
function instanceMethods.BindToRenderStep(self, _, _, fn)
	rawget(self, "_props")._renderBindings = rawget(self, "_props")._renderBindings or {}
	table.insert(rawget(self, "_props")._renderBindings, fn)
end
function instanceMethods.UnbindFromRenderStep() end

local CollectionService = service("CollectionService")
local tags = {}
function instanceMethods.AddTag(_, instance, tag)
	tags[tag] = tags[tag] or {}
	table.insert(tags[tag], instance)
end
function instanceMethods.RemoveTag() end
function instanceMethods.HasTag(_, instance, tag)
	for _, tagged in tags[tag] or {} do
		if tagged == instance then
			return true
		end
	end
	return false
end
function instanceMethods.GetTagged(_, tag)
	local out = {}
	for _, instance in tags[tag] or {} do
		if not rawget(instance, "_destroyed") then
			table.insert(out, instance)
		end
	end
	return out
end
function instanceMethods.GetInstanceAddedSignal(self, tag)
	local signals = rawget(self, "_signals")
	signals["tag_" .. tag] = signals["tag_" .. tag] or Signal.new()
	return signals["tag_" .. tag]
end

local PathfindingService = service("PathfindingService")
function instanceMethods.CreatePath()
	local path = newInstance("Path")
	rawget(path, "_props").Status = Enum.PathStatus.Success
	return path
end
function instanceMethods.ComputeAsync(self, from, to)
	rawget(self, "_props")._from = from
	rawget(self, "_props")._to = to
end
function instanceMethods.GetWaypoints(self)
	local props = rawget(self, "_props")
	local from, to = props._from or Vector3.zero, props._to or Vector3.zero
	local out = {}
	for step = 0, 4 do
		table.insert(out, {
			Position = from:Lerp(to, step / 4),
			Action = Enum.PathWaypointAction.Walk,
		})
	end
	return out
end

local ProximityPromptService = service("ProximityPromptService")
local ContextActionService = service("ContextActionService")
function instanceMethods.BindAction() end
function instanceMethods.UnbindAction() end

local UserInputService = service("UserInputService")
function instanceMethods.IsKeyDown()
	return false
end
function instanceMethods.IsGamepadButtonDown()
	return false
end
function instanceMethods.GetConnectedGamepads()
	return {}
end
function instanceMethods.GetGamepadState()
	return {}
end

local TweenService = service("TweenService")
function instanceMethods.Create()
	return { Play = function() end, Cancel = function() end, Completed = Signal.new() }
end

local Debris = service("Debris")
function instanceMethods.AddItem() end

local PhysicsService = service("PhysicsService")
function instanceMethods.RegisterCollisionGroup() end
function instanceMethods.CollisionGroupSetCollidable() end

local DataStoreService = service("DataStoreService")
function instanceMethods.GetDataStore()
	local store = newInstance("DataStore")
	return store
end
function instanceMethods.GetAsync()
	return nil
end
function instanceMethods.UpdateAsync()
	return nil
end
function instanceMethods.SetAsync()
	return nil
end

--------------------------------------------------------------------------------
-- game
--------------------------------------------------------------------------------

local game = newInstance("DataModel")
rawget(game, "_props").Name = "game"
for _, instance in services do
	setParent(instance, game)
end

function instanceMethods.GetService(self, name)
	local found = services[name]
	if not found then
		found = service(name, name)
		setParent(found, game)
	end
	return found
end
function instanceMethods.BindToClose() end

Mock.game = game
Mock.services = services
Mock.Signal = Signal
Mock.isServer = true
Mock.tags = tags

--------------------------------------------------------------------------------
-- Globals exported to the bundled game code
--------------------------------------------------------------------------------

local function typeofShim(value)
	local meta = getmetatable(value)
	if meta == Vector3 then
		return "Vector3"
	end
	if meta == CFrame then
		return "CFrame"
	end
	if meta == Color3 then
		return "Color3"
	end
	if meta == InstanceMT then
		return "Instance"
	end
	if meta == UDim2 then
		return "UDim2"
	end
	return type(value)
end

local function warnShim(...)
	local parts = {}
	for index = 1, select("#", ...) do
		parts[index] = tostring((select(index, ...)))
	end
	print("[warn] " .. table.concat(parts, " "))
	Mock.warnings = (Mock.warnings or 0) + 1
	table.insert(Mock.warningLog, table.concat(parts, " "))
end

Mock.warningLog = {}

Mock.env = {
	game = game,
	workspace = Workspace,
	Instance = Instance,
	Vector3 = Vector3,
	Vector2 = Vector2,
	CFrame = CFrame,
	Color3 = Color3,
	UDim = UDim,
	UDim2 = UDim2,
	Enum = Enum,
	Random = Random,
	task = task,
	os = os_,
	typeof = typeofShim,
	warn = warnShim,
	PhysicalProperties = { new = PhysicalProperties_new },
	TweenInfo = { new = TweenInfo_new },
	RaycastParams = {
		new = function()
			return { FilterType = nil, FilterDescendantsInstances = {}, IgnoreWater = true }
		end,
	},
}

return Mock
