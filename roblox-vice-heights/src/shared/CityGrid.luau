--!nonstrict
--[[
	CityGrid
	Pure math describing the street layout. The world builder, the police AI,
	the pedestrian spawner and the minimap all read the city from here, so the
	map only ever exists in one place.

	Layout (looking down the +Y axis):

		road 0   road 1   road 2
		  |        |        |
		--+--------+--------+--   <- road 0 (Z)
		  | block  | block  |
		  | (0,0)  | (1,0)  |
		--+--------+--------+--   <- road 1 (Z)

	Roads are indexed 0..Blocks on each axis, blocks 0..Blocks-1.
]]

local Config = require(script.Parent.Config)

local CityGrid = {}

local C = Config.City

CityGrid.Pitch = C.BlockSize + C.RoadWidth
CityGrid.Extent = C.Blocks * CityGrid.Pitch + C.RoadWidth
CityGrid.Origin = -CityGrid.Extent / 2
CityGrid.HalfExtent = CityGrid.Extent / 2

--- World coordinate of the centreline of road `k` (0..Blocks) on either axis.
function CityGrid.roadCoord(k: number): number
	return CityGrid.Origin + C.RoadWidth / 2 + k * CityGrid.Pitch
end

--- World coordinate of the centre of block `i` (0..Blocks-1) on either axis.
function CityGrid.blockCoord(i: number): number
	return CityGrid.Origin + C.RoadWidth + i * CityGrid.Pitch + C.BlockSize / 2
end

--- Centre of block (i, j) on the ground plane.
function CityGrid.blockCenter(i: number, j: number): Vector3
	return Vector3.new(CityGrid.blockCoord(i), C.GroundY, CityGrid.blockCoord(j))
end

--- Centre of the intersection where road `ki` crosses road `kj`.
function CityGrid.intersection(ki: number, kj: number): Vector3
	return Vector3.new(CityGrid.roadCoord(ki), C.GroundY, CityGrid.roadCoord(kj))
end

function CityGrid.inBounds(position: Vector3): boolean
	local limit = CityGrid.HalfExtent
	return math.abs(position.X) <= limit and math.abs(position.Z) <= limit
end

--- Distance from `coord` to the nearest road centreline on that axis, plus the
--- index of that road. Used for both snapping and "am I on tarmac" tests.
local function nearestRoad(coord: number): (number, number)
	local raw = (coord - CityGrid.Origin - C.RoadWidth / 2) / CityGrid.Pitch
	local k = math.clamp(math.floor(raw + 0.5), 0, C.Blocks)
	return k, coord - CityGrid.roadCoord(k)
end

CityGrid.nearestRoadIndex = nearestRoad

function CityGrid.isOnRoad(position: Vector3): boolean
	local _, dx = nearestRoad(position.X)
	local _, dz = nearestRoad(position.Z)
	local half = C.RoadWidth / 2
	return math.abs(dx) <= half or math.abs(dz) <= half
end

--- Snaps a world position onto the nearest road centreline, keeping it on the
--- axis it is already closest to so cars do not get yanked sideways.
function CityGrid.snapToRoad(position: Vector3): Vector3
	local kx, dx = nearestRoad(position.X)
	local kz, dz = nearestRoad(position.Z)
	if math.abs(dx) < math.abs(dz) then
		return Vector3.new(CityGrid.roadCoord(kx), position.Y, position.Z)
	end
	return Vector3.new(position.X, position.Y, CityGrid.roadCoord(kz))
end

--- A drivable lane position: on a road, offset into the right-hand lane.
function CityGrid.laneOffset(): number
	return C.RoadWidth / 4
end

--- Picks a random point on the road network.
function CityGrid.randomRoadPoint(rng: Random): Vector3
	local along = rng:NextNumber(-CityGrid.HalfExtent + 40, CityGrid.HalfExtent - 40)
	local k = rng:NextInteger(0, C.Blocks)
	local lane = CityGrid.roadCoord(k) + (rng:NextInteger(0, 1) == 0 and -1 or 1) * CityGrid.laneOffset()
	if rng:NextInteger(0, 1) == 0 then
		return Vector3.new(lane, C.GroundY, along)
	end
	return Vector3.new(along, C.GroundY, lane)
end

--- Picks a random point on a sidewalk (just outside a block edge).
function CityGrid.randomSidewalkPoint(rng: Random): Vector3
	local i = rng:NextInteger(0, C.Blocks - 1)
	local j = rng:NextInteger(0, C.Blocks - 1)
	local cx, cz = CityGrid.blockCoord(i), CityGrid.blockCoord(j)
	local edge = C.BlockSize / 2 + C.SidewalkWidth / 2
	local t = rng:NextNumber(-C.BlockSize / 2, C.BlockSize / 2)
	local side = rng:NextInteger(1, 4)
	if side == 1 then
		return Vector3.new(cx + t, C.GroundY + C.SidewalkHeight, cz - edge)
	elseif side == 2 then
		return Vector3.new(cx + t, C.GroundY + C.SidewalkHeight, cz + edge)
	elseif side == 3 then
		return Vector3.new(cx - edge, C.GroundY + C.SidewalkHeight, cz + t)
	end
	return Vector3.new(cx + edge, C.GroundY + C.SidewalkHeight, cz + t)
end

--- Every intersection centre, useful for streetlights and roadblocks.
function CityGrid.intersections(): { Vector3 }
	local out = {}
	for ki = 0, C.Blocks do
		for kj = 0, C.Blocks do
			table.insert(out, CityGrid.intersection(ki, kj))
		end
	end
	return out
end

--- Road segments as {from, to} pairs on the ground plane. The minimap draws
--- these directly rather than re-deriving the layout.
function CityGrid.roadSegments(): { { from: Vector3, to: Vector3, horizontal: boolean } }
	local out = {}
	local a = CityGrid.Origin
	local b = CityGrid.Origin + CityGrid.Extent
	for k = 0, C.Blocks do
		local c = CityGrid.roadCoord(k)
		table.insert(out, {
			from = Vector3.new(a, 0, c),
			to = Vector3.new(b, 0, c),
			horizontal = true,
		})
		table.insert(out, {
			from = Vector3.new(c, 0, a),
			to = Vector3.new(c, 0, b),
			horizontal = false,
		})
	end
	return out
end

--- Named plots reserved for landmarks. Kept here so the world builder, the
--- shops and the minimap agree on where things are without passing state.
CityGrid.Landmarks = {
	Spawn = { block = { 3, 4 }, label = "Vespucci Plaza" },
	GunShop = { block = { 1, 2 }, label = "Ammu-Point" },
	Dealership = { block = { 5, 2 }, label = "Premium Deluxe Motors" },
	Garage = { block = { 3, 5 }, label = "Your Garage" },
	PoliceStation = { block = { 6, 5 }, label = "Police Precinct" },
	Hospital = { block = { 2, 6 }, label = "Central Medical" },
	MissionBoard = { block = { 4, 3 }, label = "Job Board" },
	Store1 = { block = { 0, 0 }, label = "24/7 Northside" },
	Store2 = { block = { 7, 3 }, label = "24/7 Eastgate" },
	Store3 = { block = { 2, 7 }, label = "24/7 Docks" },
	Park = { block = { 5, 6 }, label = "Legion Park" },
}

function CityGrid.landmarkPosition(name: string): Vector3?
	local entry = CityGrid.Landmarks[name]
	if not entry then
		return nil
	end
	return CityGrid.blockCenter(entry.block[1], entry.block[2])
end

--- True when this block is claimed by a landmark, so the builder skips it.
function CityGrid.landmarkAt(i: number, j: number): (string?, any)
	for name, entry in CityGrid.Landmarks do
		if entry.block[1] == i and entry.block[2] == j then
			return name, entry
		end
	end
	return nil, nil
end

return CityGrid
