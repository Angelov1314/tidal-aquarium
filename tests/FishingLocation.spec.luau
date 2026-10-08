local Config = require("../src/shared/Config")
local FishingLocation = require("../src/shared/FishingLocation")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function near(actual, expected, tolerance, message)
	expect(math.abs(actual - expected) <= tolerance, message or string.format("expected %.3f near %.3f", actual, expected))
end

expect(#Config.Zones == 9, "location contract expects nine zone centers")
local pier = FishingLocation.Pier
expect(pier.physicalMinZOffset < pier.waterlineZOffset and pier.waterlineZOffset < pier.minZOffset and pier.maxZOffset < pier.physicalMaxZOffset, "waterfront player footprint must stay inside physical pier")
expect(pier.surfaceY == 4 and pier.minRootY > pier.surfaceY, "pier surface and player height must be explicit")

for zoneIndex, zone in ipairs(Config.Zones) do
	local destination = FishingLocation.travelPoint(zone.center)
	near(destination.x, zone.center.x, 1e-9, "travel x must stay on the pier centerline")
	near(destination.y, FishingLocation.Travel.y, 1e-9, "travel y contract changed")
	near(destination.z, zone.center.z + 76, 1e-9, "travel must land at over-water pier tip")
	expect(destination.z - zone.center.z > 70, "travel destination must be beyond island radius")
	expect(FishingLocation.zoneAt(destination.x, destination.y, destination.z, Config.Zones) == zoneIndex, "travel destination must be fishable")

	-- The center of the island and the old z+42 travel point are inland.
	expect(FishingLocation.zoneAt(zone.center.x, 7, zone.center.z + 20, Config.Zones) == nil, "inland promenade must not fish")
	expect(FishingLocation.zoneAt(zone.center.x, 7, zone.center.z + 42, Config.Zones) == nil, "old mid-pier travel point must not fish")
	-- A player beside the 16-stud pier is outside the supported fishing platform.
	expect(FishingLocation.zoneAt(zone.center.x + 8, 7, zone.center.z + 76, Config.Zones) == nil, "off-pier position must not fish")
	-- Height and dead-player checks are represented by the contract's vertical band;
	-- World.getZone additionally rejects missing/dead Humanoids at runtime.
	expect(FishingLocation.zoneAt(zone.center.x, pier.minRootY - .01, zone.center.z + 76, Config.Zones) == nil, "below dock height must not fish")
	expect(FishingLocation.zoneAt(zone.center.x, pier.maxRootY + .01, zone.center.z + 76, Config.Zones) == nil, "above dock height must not fish")
end

-- Aquarium positions live well away from every waterfront footprint.
expect(FishingLocation.zoneAt(-101, 7.5, -98, Config.Zones) == nil, "aquarium position must not fish")

print("FishingLocation.spec: nine dock destinations, inland/off-pier/height/aquarium rejection PASS")
