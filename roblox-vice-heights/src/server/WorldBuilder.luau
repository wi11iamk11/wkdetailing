--!nonstrict
--[[
	WorldBuilder
	Generates the whole city at runtime from Config.Game.Seed. Nothing is
	hand-placed in the data model, so the map is reproducible, diffable and
	re-rollable by changing one number.

	Build order: ground -> roads -> sidewalks -> blocks (buildings, parks,
	landmarks) -> street furniture. A part budget guards against a pathological
	seed burying the client in geometry.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local CityGrid = require(Shared.CityGrid)
local Util = require(Shared.Util)

local WorldBuilder = {}

local C = Config.City
local P = C.Palette

local partsMade = 0
local rng = Random.new(Config.Game.Seed)

local folders: { [string]: Folder } = {}

local function budgetOk(): boolean
	return partsMade < C.MaxParts
end

local function make(props): BasePart?
	if not budgetOk() then
		return nil
	end
	partsMade += 1
	return Util.part(props)
end

local function folder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local function pick(list: { any })
	return list[rng:NextInteger(1, #list)]
end

--------------------------------------------------------------------------------
-- Signage
--------------------------------------------------------------------------------

local function sign(parent: Instance, cframe: CFrame, width: number, text: string, color: Color3)
	local board = make({
		Name = "Sign",
		Size = Vector3.new(width, 3.4, 0.4),
		CFrame = cframe,
		Color = color,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	if not board then
		return
	end

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = board

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = Color3.fromRGB(250, 250, 252)
	label.TextScaled = true
	label.Parent = gui
end

--------------------------------------------------------------------------------
-- Interactables
--------------------------------------------------------------------------------

--- Places a marker part carrying a ProximityPrompt. Services bind behaviour by
--- reading the `Interact` attribute, so the world stays free of gameplay code.
local function interactable(cframe: CFrame, kind: string, id: string, actionText: string, objectText: string)
	local pad = make({
		Name = kind .. "_" .. id,
		Size = Vector3.new(7, 0.3, 7),
		CFrame = cframe,
		Color = Config.UI.Accent,
		Material = Enum.Material.Neon,
		Transparency = 0.35,
		CanCollide = false,
		Parent = folders.Interactables,
	})
	if not pad then
		return
	end
	pad:SetAttribute("Interact", kind)
	pad:SetAttribute("Id", id)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	CollectionService:AddTag(pad, "Interactable")
end

--------------------------------------------------------------------------------
-- Ground, water, roads
--------------------------------------------------------------------------------

local function buildGround()
	local margin = 260
	make({
		Name = "Ground",
		Size = Vector3.new(CityGrid.Extent + margin * 2, 2, CityGrid.Extent + margin * 2),
		CFrame = CFrame.new(0, C.GroundY - 1, 0),
		Color = P.Ground,
		Material = Enum.Material.Grass,
		Parent = folders.Terrain,
	})

	-- Beach strip and ocean south of the city.
	make({
		Name = "Beach",
		Size = Vector3.new(CityGrid.Extent + margin * 2, 2, 220),
		CFrame = CFrame.new(0, C.GroundY - 1, CityGrid.HalfExtent + margin - 110),
		Color = P.Sand,
		Material = Enum.Material.Sand,
		Parent = folders.Terrain,
	})

	pcall(function()
		local width = CityGrid.Extent + margin * 2
		Workspace.Terrain:FillBlock(
			CFrame.new(0, C.GroundY - 9, CityGrid.HalfExtent + margin + 190),
			Vector3.new(width, 18, 380),
			Enum.Material.Water
		)
	end)
end

local function buildRoads()
	local length = CityGrid.Extent
	local roads = folders.Roads

	for k = 0, C.Blocks do
		local coord = CityGrid.roadCoord(k)

		for axis = 1, 2 do
			local horizontal = axis == 1
			local size = horizontal and Vector3.new(length, 0.4, C.RoadWidth)
				or Vector3.new(C.RoadWidth, 0.4, length)
			local position = horizontal and Vector3.new(0, C.GroundY + 0.2, coord)
				or Vector3.new(coord, C.GroundY + 0.2, 0)

			make({
				Name = string.format("Road_%s_%d", horizontal and "H" or "V", k),
				Size = size,
				CFrame = CFrame.new(position),
				Color = P.Road,
				Material = Enum.Material.Asphalt,
				Parent = roads,
			})

			-- Dashed centre line, skipped where it would cross an intersection.
			local dashes = math.floor(length / C.LaneDashSpacing)
			for d = 0, dashes do
				local along = CityGrid.Origin + d * C.LaneDashSpacing + C.LaneDashSpacing / 2
				local _, offset = CityGrid.nearestRoadIndex(along)
				if math.abs(offset) > C.RoadWidth / 2 + 4 then
					local dashSize = horizontal and Vector3.new(C.LaneDashLength, 0.1, 0.8)
						or Vector3.new(0.8, 0.1, C.LaneDashLength)
					local dashPos = horizontal and Vector3.new(along, C.GroundY + 0.42, coord)
						or Vector3.new(coord, C.GroundY + 0.42, along)
					make({
						Name = "Dash",
						Size = dashSize,
						CFrame = CFrame.new(dashPos),
						Color = P.RoadLine,
						Material = Enum.Material.SmoothPlastic,
						CanQuery = false,
						Parent = roads,
					})
				end
			end
		end
	end

	-- Crosswalk bands on alternating intersections.
	for ki = 0, C.Blocks do
		for kj = 0, C.Blocks do
			if (ki + kj) % 2 == 0 then
				local center = CityGrid.intersection(ki, kj)
				local reach = C.RoadWidth / 2 + 2
				local bands = {
					{ Vector3.new(0, 0, -reach), Vector3.new(C.RoadWidth * 0.8, 0.1, 3) },
					{ Vector3.new(0, 0, reach), Vector3.new(C.RoadWidth * 0.8, 0.1, 3) },
					{ Vector3.new(-reach, 0, 0), Vector3.new(3, 0.1, C.RoadWidth * 0.8) },
					{ Vector3.new(reach, 0, 0), Vector3.new(3, 0.1, C.RoadWidth * 0.8) },
				}
				for _, band in bands do
					make({
						Name = "Crosswalk",
						Size = band[2],
						CFrame = CFrame.new(center + band[1] + Vector3.new(0, 0.42, 0)),
						Color = P.Crosswalk,
						Material = Enum.Material.SmoothPlastic,
						CanQuery = false,
						Parent = folders.Roads,
					})
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Blocks
--------------------------------------------------------------------------------

local function buildSidewalk(cx: number, cz: number)
	local span = C.BlockSize + C.SidewalkWidth * 2
	make({
		Name = "Sidewalk",
		Size = Vector3.new(span, C.SidewalkHeight, span),
		CFrame = CFrame.new(cx, C.GroundY + C.SidewalkHeight / 2, cz),
		Color = P.Sidewalk,
		Material = Enum.Material.Concrete,
		Parent = folders.Sidewalks,
	})
end

local function buildTower(cx: number, cz: number, sizeX: number, sizeZ: number, parent: Instance)
	local floors = rng:NextInteger(C.MinFloors, C.MaxFloors)
	local height = floors * C.FloorHeight
	local base = C.GroundY + C.SidewalkHeight
	local color = pick(C.BuildingColors)

	make({
		Name = "Building",
		Size = Vector3.new(sizeX, height, sizeZ),
		CFrame = CFrame.new(cx, base + height / 2, cz),
		Color = color,
		Material = Enum.Material.Concrete,
		Parent = parent,
	})

	-- Window bands: one ring per floor, thinned out on tall towers so a
	-- skyscraper does not cost twenty parts on its own.
	local step = math.max(1, math.ceil(floors / 12))
	for floorIndex = 1, floors, step do
		local lit = rng:NextNumber() < 0.22
		make({
			Name = "Windows",
			Size = Vector3.new(sizeX + 0.25, 3, sizeZ + 0.25),
			CFrame = CFrame.new(cx, base + floorIndex * C.FloorHeight - C.FloorHeight * 0.45, cz),
			Color = lit and C.WindowColorLit or C.WindowColor,
			Material = lit and Enum.Material.Neon or Enum.Material.Glass,
			Reflectance = lit and 0 or 0.2,
			CanQuery = false,
			Parent = parent,
		})
	end

	-- Roof detail.
	make({
		Name = "Roof",
		Size = Vector3.new(sizeX * 0.6, 3, sizeZ * 0.6),
		CFrame = CFrame.new(cx, base + height + 1.5, cz),
		Color = Color3.fromRGB(96, 98, 104),
		Material = Enum.Material.Metal,
		Parent = parent,
	})
end

local function buildBlockOfTowers(i: number, j: number)
	local cx, cz = CityGrid.blockCoord(i), CityGrid.blockCoord(j)
	local layout = rng:NextInteger(1, 3)
	local inset = 6
	local usable = C.BlockSize - inset

	if layout == 1 then
		buildTower(cx, cz, usable, usable, folders.Buildings)
	elseif layout == 2 then
		local half = usable / 2 - 3
		for _, offset in { -1, 1 } do
			buildTower(cx + offset * (usable / 4 + 1.5), cz, half, usable, folders.Buildings)
		end
	else
		local half = usable / 2 - 3
		for _, ox in { -1, 1 } do
			for _, oz in { -1, 1 } do
				buildTower(
					cx + ox * (usable / 4 + 1.5),
					cz + oz * (usable / 4 + 1.5),
					half,
					half,
					folders.Buildings
				)
			end
		end
	end
end

local function buildPark(i: number, j: number)
	local cx, cz = CityGrid.blockCoord(i), CityGrid.blockCoord(j)
	make({
		Name = "Lawn",
		Size = Vector3.new(C.BlockSize, 0.3, C.BlockSize),
		CFrame = CFrame.new(cx, C.GroundY + C.SidewalkHeight + 0.15, cz),
		Color = P.Park,
		Material = Enum.Material.Grass,
		Parent = folders.Props,
	})

	for _ = 1, 14 do
		local x = cx + rng:NextNumber(-C.BlockSize / 2 + 10, C.BlockSize / 2 - 10)
		local z = cz + rng:NextNumber(-C.BlockSize / 2 + 10, C.BlockSize / 2 - 10)
		local height = rng:NextNumber(9, 16)
		local base = C.GroundY + C.SidewalkHeight

		make({
			Name = "Trunk",
			Size = Vector3.new(1.4, height, 1.4),
			CFrame = CFrame.new(x, base + height / 2, z),
			Color = Color3.fromRGB(96, 68, 44),
			Material = Enum.Material.Wood,
			Parent = folders.Props,
		})
		make({
			Name = "Canopy",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1, 1, 1) * rng:NextNumber(9, 14),
			CFrame = CFrame.new(x, base + height + 2, z),
			Color = Color3.fromRGB(62, 112, 58),
			Material = Enum.Material.Grass,
			CanCollide = false,
			Parent = folders.Props,
		})
	end
end

--------------------------------------------------------------------------------
-- Landmarks
--------------------------------------------------------------------------------

local LANDMARK_STYLE = {
	Spawn = { color = Color3.fromRGB(180, 176, 168), height = 8 },
	GunShop = { color = Color3.fromRGB(112, 76, 60), height = 20, kind = "GunShop", action = "Browse" },
	Dealership = { color = Color3.fromRGB(76, 108, 156), height = 20, kind = "Dealership", action = "Browse" },
	Garage = { color = Color3.fromRGB(96, 100, 108), height = 16, kind = "Garage", action = "Open" },
	PoliceStation = {
		color = Color3.fromRGB(56, 72, 108),
		height = 26,
		kind = "PoliceStation",
		action = "Surrender",
	},
	Hospital = { color = Color3.fromRGB(224, 226, 232), height = 30, kind = "Hospital", action = "Treat" },
	MissionBoard = {
		color = Color3.fromRGB(120, 96, 152),
		height = 14,
		kind = "MissionBoard",
		action = "Read",
	},
	Store1 = { color = Color3.fromRGB(196, 148, 76), height = 12, kind = "Store", action = "Rob" },
	Store2 = { color = Color3.fromRGB(196, 148, 76), height = 12, kind = "Store", action = "Rob" },
	Store3 = { color = Color3.fromRGB(196, 148, 76), height = 12, kind = "Store", action = "Rob" },
	Park = { color = Color3.fromRGB(78, 122, 66), height = 0 },
}

local function buildLandmark(name: string, entry, i: number, j: number)
	local style = LANDMARK_STYLE[name]
	if not style then
		buildBlockOfTowers(i, j)
		return
	end

	local cx, cz = CityGrid.blockCoord(i), CityGrid.blockCoord(j)
	local base = C.GroundY + C.SidewalkHeight

	if name == "Park" then
		buildPark(i, j)
		return
	end

	if name == "Spawn" then
		make({
			Name = "Plaza",
			Size = Vector3.new(C.BlockSize, 0.4, C.BlockSize),
			CFrame = CFrame.new(cx, base + 0.2, cz),
			Color = Color3.fromRGB(178, 174, 166),
			Material = Enum.Material.Pavement,
			Parent = folders.Props,
		})

		local spawnPoint = Instance.new("SpawnLocation")
		spawnPoint.Name = "CitySpawn"
		spawnPoint.Size = Vector3.new(24, 0.6, 24)
		spawnPoint.CFrame = CFrame.new(cx, base + 0.6, cz)
		spawnPoint.Anchored = true
		spawnPoint.CanCollide = true
		spawnPoint.Color = Color3.fromRGB(198, 194, 186)
		spawnPoint.Material = Enum.Material.Pavement
		spawnPoint.Neutral = true
		spawnPoint.Duration = 0
		spawnPoint.Parent = folders.Props

		sign(
			folders.Props,
			CFrame.new(cx, base + 9, cz - C.BlockSize / 2 + 4),
			24,
			entry.label,
			Color3.fromRGB(60, 62, 70)
		)
		return
	end

	local depth = C.BlockSize * 0.7
	make({
		Name = name,
		Size = Vector3.new(C.BlockSize * 0.8, style.height, depth),
		CFrame = CFrame.new(cx, base + style.height / 2, cz),
		Color = style.color,
		Material = Enum.Material.Concrete,
		Parent = folders.Landmarks,
	})

	-- Storefront glass facing the street (-Z side).
	make({
		Name = "Storefront",
		Size = Vector3.new(C.BlockSize * 0.7, math.min(style.height * 0.5, 8), 0.6),
		CFrame = CFrame.new(cx, base + 5, cz - depth / 2 - 0.3),
		Color = Color3.fromRGB(46, 58, 74),
		Material = Enum.Material.Glass,
		Reflectance = 0.3,
		Parent = folders.Landmarks,
	})

	sign(
		folders.Landmarks,
		CFrame.new(cx, base + style.height + 2.5, cz - depth / 2 - 0.4),
		C.BlockSize * 0.7,
		entry.label,
		style.color
	)

	if style.kind then
		interactable(
			CFrame.new(cx, base + 0.4, cz - depth / 2 - 6),
			style.kind,
			name,
			style.action or "Use",
			entry.label
		)
	end
end

--------------------------------------------------------------------------------
-- Street furniture
--------------------------------------------------------------------------------

local function buildStreetlights()
	for ki = 0, C.Blocks do
		for kj = 0, C.Blocks do
			if (ki + kj) % 2 == 1 then
				continue
			end
			local center = CityGrid.intersection(ki, kj)
			local x = center.X + C.RoadWidth / 2 + 2
			local z = center.Z + C.RoadWidth / 2 + 2
			local base = C.GroundY + C.SidewalkHeight

			make({
				Name = "LightPole",
				Size = Vector3.new(0.6, 18, 0.6),
				CFrame = CFrame.new(x, base + 9, z),
				Color = Color3.fromRGB(72, 74, 80),
				Material = Enum.Material.Metal,
				Parent = folders.Props,
			})
			make({
				Name = "LightArm",
				Size = Vector3.new(5, 0.4, 0.4),
				CFrame = CFrame.new(x - 2.5, base + 18, z),
				Color = Color3.fromRGB(72, 74, 80),
				Material = Enum.Material.Metal,
				Parent = folders.Props,
			})
			local lamp = make({
				Name = "Streetlamp",
				Size = Vector3.new(1.6, 0.5, 1.2),
				CFrame = CFrame.new(x - 5, base + 17.8, z),
				Color = Color3.fromRGB(255, 236, 190),
				Material = Enum.Material.Neon,
				CanCollide = false,
				Parent = folders.Props,
			})
			if lamp then
				local light = Instance.new("PointLight")
				light.Name = "Glow"
				light.Brightness = 1.6
				light.Range = 34
				light.Color = Color3.fromRGB(255, 232, 178)
				light.Enabled = false
				light.Parent = lamp
				CollectionService:AddTag(lamp, "Streetlight")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

function WorldBuilder.build(): Folder
	local city = folder("City", Workspace)
	for _, name in { "Terrain", "Roads", "Sidewalks", "Buildings", "Props", "Landmarks", "Interactables" } do
		folders[name] = folder(name, city)
	end

	local started = os.clock()
	buildGround()
	buildRoads()

	for i = 0, C.Blocks - 1 do
		for j = 0, C.Blocks - 1 do
			buildSidewalk(CityGrid.blockCoord(i), CityGrid.blockCoord(j))
			local name, entry = CityGrid.landmarkAt(i, j)
			if name then
				buildLandmark(name, entry, i, j)
			elseif rng:NextNumber() < 0.08 then
				buildPark(i, j)
			else
				buildBlockOfTowers(i, j)
			end
		end
	end

	buildStreetlights()

	if not budgetOk() then
		warn(string.format("WorldBuilder: hit the %d part budget; some geometry was skipped", C.MaxParts))
	end

	print(
		string.format(
			"[ViceHeights] City built: %d parts in %.2fs (seed %d)",
			partsMade,
			os.clock() - started,
			Config.Game.Seed
		)
	)

	return city
end

--- Spots where street cars can be parked: along the kerb of each block.
function WorldBuilder.parkingSpots(): { CFrame }
	local spots = {}
	local offset = C.BlockSize / 2 + C.SidewalkWidth + 5
	for i = 0, C.Blocks - 1 do
		for j = 0, C.Blocks - 1 do
			local cx, cz = CityGrid.blockCoord(i), CityGrid.blockCoord(j)
			table.insert(spots, CFrame.new(cx - 22, C.GroundY + 3, cz - offset))
			table.insert(
				spots,
				CFrame.new(cx + 22, C.GroundY + 3, cz + offset) * CFrame.Angles(0, math.pi, 0)
			)
			table.insert(
				spots,
				CFrame.new(cx - offset, C.GroundY + 3, cz + 22) * CFrame.Angles(0, math.pi / 2, 0)
			)
			table.insert(
				spots,
				CFrame.new(cx + offset, C.GroundY + 3, cz - 22) * CFrame.Angles(0, -math.pi / 2, 0)
			)
		end
	end
	return spots
end

return WorldBuilder
