local Config = require("../src/shared/Config")
local ThemeContent = require("../src/shared/ThemeContent")
local FishingLocation = require("../src/shared/FishingLocation")
local WorldLayout = require("../src/shared/WorldLayout")

local function expect(condition, message)
	if not condition then error(message, 2) end
end

local ocean = WorldLayout.Ocean
expect(type(ocean) == "table", "ocean contract missing")
expect(ocean.minX < ocean.maxX and ocean.minZ < ocean.maxZ, "ocean bounds must be ordered")
expect(type(ocean.surfaceY) == "number", "ocean surface must be numeric")
expect(type(WorldLayout.Boat.speed) == "number" and WorldLayout.Boat.speed > 0, "boat speed contract missing")
expect(type(WorldLayout.Boat.turnSpeed) == "number" and WorldLayout.Boat.turnSpeed > 0, "boat turn speed contract missing")

local seenShapes = {}
local nearest = {}
local nearestMin, nearestMax = math.huge, -math.huge
for id = 1, 9 do
	local zone = WorldLayout.Zones[id]
	expect(type(zone) == "table", "missing world zone " .. tostring(id))
	expect(type(zone.x) == "number" and type(zone.z) == "number", "zone coordinates must be numeric")
	expect(zone.width >= 300 and zone.width <= 450, "zone width outside 300..450: " .. tostring(id))
	expect(zone.depth >= 300 and zone.depth <= 450, "zone depth outside 300..450: " .. tostring(id))
	expect(type(zone.shape) == "string" and #zone.shape > 0, "zone shape missing: " .. tostring(id))
	expect(not seenShapes[zone.shape], "zone silhouettes must have distinct shape contracts")
	seenShapes[zone.shape] = id

	local bounds = WorldLayout.bounds(zone)
	expect(bounds.minX < bounds.maxX and bounds.minZ < bounds.maxZ, "invalid land bounds: " .. tostring(id))
	expect(bounds.minX >= ocean.minX + 80 and bounds.maxX <= ocean.maxX - 80, "zone leaves insufficient ocean X margin: " .. tostring(id))
	expect(bounds.minZ >= ocean.minZ + 80 and bounds.maxZ <= ocean.maxZ - 80, "zone leaves insufficient ocean Z margin: " .. tostring(id))
	-- The +Z pier and cast point are outside the conservative land bound.
	expect(bounds.maxZ < zone.z + FishingLocation.Cast.zOffset, "land blocks the +Z cast channel: " .. tostring(id))

	local configZone = Config.Zones[id]
	expect(configZone and configZone.id == id, "Config zone ID drift: " .. tostring(id))
	expect(configZone.center.x == zone.x and configZone.center.z == zone.z, "Config center drift: " .. tostring(id))
	expect(configZone.x == zone.x and configZone.z == zone.z, "Config coordinate hook drift: " .. tostring(id))
	expect(configZone.shape == zone.shape and configZone.width == zone.width and configZone.depth == zone.depth, "Config geometry hook drift: " .. tostring(id))

	local closest = math.huge
	for otherId = 1, 9 do
		if otherId ~= id then
			local other = WorldLayout.Zones[otherId]
			local distance = math.sqrt((zone.x - other.x) ^ 2 + (zone.z - other.z) ^ 2)
			closest = math.min(closest, distance)
		end
	end
	nearest[id] = closest
	nearestMin = math.min(nearestMin, closest)
	nearestMax = math.max(nearestMax, closest)
	expect(closest >= 1000 and closest <= 1800, "nearest island spacing outside 1000..1800: " .. tostring(id) .. " = " .. tostring(closest))
end

expect(WorldLayout.Zones[1].x == 0 and WorldLayout.Zones[1].z == 0, "harbor must remain at origin")
for _, zone in ipairs(ThemeContent.Zones) do
	local layout = WorldLayout.Zones[zone.id]
	expect(layout and zone.center.x == layout.x and zone.center.z == layout.z, "theme authoring center drift: " .. tostring(zone.id))
end

-- Keep the original fishing contract intact for every expanded dock.
for id, zone in ipairs(Config.Zones) do
	local travel = FishingLocation.travelPoint(zone.center)
	expect(travel.x == zone.center.x and travel.z == zone.center.z + 76, "travel point drift: " .. tostring(id))
	expect(FishingLocation.zoneAt(travel.x, travel.y, travel.z, Config.Zones) == id, "travel point must remain fishable: " .. tostring(id))
	expect(FishingLocation.zoneAt(zone.center.x, 7, zone.center.z + 82, Config.Zones) == nil, "cast point must remain outside standing dock: " .. tostring(id))
end

print(string.format("WorldLayout.spec: 9 distinct %dx%d..%dx%d islands, nearest spacing %.1f..%.1f, ocean %.0fx%.0f with 80-stud margins, boat %.1f PASS",
	300, 300, 450, 450, nearestMin, nearestMax, ocean.maxX - ocean.minX, ocean.maxZ - ocean.minZ, WorldLayout.Boat.speed))
