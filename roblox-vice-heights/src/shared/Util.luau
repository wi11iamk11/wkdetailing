--!nonstrict
--[[
	Util
	Small helpers shared by both sides. Nothing here knows about gameplay.
]]

local Players = game:GetService("Players")

local Util = {}

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

--- Creates a part with sensible world-geometry defaults and applies `props`.
function Util.part(props: { [string]: any }): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		if key ~= "Parent" then
			(part :: any)[key] = value
		end
	end
	-- Parent last so the part streams out fully built.
	if props.Parent then
		part.Parent = props.Parent
	end
	return part
end

function Util.weld(a: BasePart, b: BasePart): WeldConstraint
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = a
	weld.Part1 = b
	weld.Parent = a
	return weld
end

function Util.attachment(parent: BasePart, name: string, offset: Vector3): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = offset
	attachment.Parent = parent
	return attachment
end

--------------------------------------------------------------------------------
-- Math
--------------------------------------------------------------------------------

function Util.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--- Frame-rate independent exponential smoothing.
function Util.damp(current: number, target: number, smoothing: number, dt: number): number
	return Util.lerp(target, current, math.exp(-dt / math.max(smoothing, 1e-4)))
end

function Util.horizontal(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

--- Random unit vector inside a cone of `spread` radians around `direction`.
function Util.coneSpread(direction: Vector3, spread: number, rng: Random): Vector3
	if spread <= 0 then
		return direction.Unit
	end
	local up = math.abs(direction.Unit.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
	local right = direction:Cross(up).Unit
	local actualUp = right:Cross(direction).Unit
	local angle = rng:NextNumber() * math.pi * 2
	local radius = math.sqrt(rng:NextNumber()) * math.tan(spread)
	return (direction.Unit + right * math.cos(angle) * radius + actualUp * math.sin(angle) * radius).Unit
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

function Util.comma(n: number): string
	local text = tostring(math.floor(math.abs(n) + 0.5))
	local out = ""
	local count = 0
	for i = #text, 1, -1 do
		out = string.sub(text, i, i) .. out
		count += 1
		if count % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return (n < 0 and "-" or "") .. out
end

function Util.money(n: number): string
	return "$" .. Util.comma(n)
end

function Util.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------

function Util.humanoidOf(instance: Instance?): Humanoid?
	if not instance then
		return nil
	end
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

function Util.playerOf(instance: Instance?): Player?
	local humanoid = Util.humanoidOf(instance)
	if not humanoid then
		return nil
	end
	return Players:GetPlayerFromCharacter(humanoid.Parent)
end

function Util.isAlive(character: Model?): boolean
	if not character or not character.Parent then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function Util.rootOf(character: Model?): BasePart?
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--- Body-part name -> damage multiplier bucket. Works for R6 and R15.
function Util.hitZone(partName: string): string
	if partName == "Head" then
		return "Head"
	end
	if
		partName == "Torso"
		or partName == "UpperTorso"
		or partName == "LowerTorso"
		or partName == "HumanoidRootPart"
	then
		return "Torso"
	end
	return "Limb"
end

--------------------------------------------------------------------------------
-- Raycasting
--------------------------------------------------------------------------------

function Util.filterParams(exclude: { Instance }, ignoreWater: boolean?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = ignoreWater ~= false
	return params
end

return Util
