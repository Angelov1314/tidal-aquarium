--!strict
-- Shared waterfront contract. Keep this numeric so server tests can exercise the
-- exact footprint without Roblox objects, while World converts Vector3 values.
local FishingLocation = {}

-- The primary dock is made from 16-stud-wide planks centered at x=0 and
-- spanning z+27.65 through z+80.35. Only its end beyond the island's radius
-- 70 waterline is fishable. The margins below describe where a
-- HumanoidRootPart may stand while keeping its body on that over-water
-- platform.
FishingLocation.Pier = {
	halfWidth = 7.25,
	waterlineZOffset = 70,
	minZOffset = 72,
	maxZOffset = 79,
	physicalMinZOffset = 27.65,
	physicalMaxZOffset = 80.35,
	surfaceY = 4,
	minRootY = 4.5,
	maxRootY = 13.5,
}

FishingLocation.Travel = {
	y = 7,
	zOffset = 76,
}

-- The first forward cast sample from the travel pose lands beyond the last
-- plank (z+81), over the water. This is also useful to clients that need a
-- deterministic fallback when their water raycast is temporarily unavailable.
FishingLocation.Cast = {
	y = 1.15,
	zOffset = 82,
}

function FishingLocation.travelPoint(center: {x: number, z: number}): {x: number, y: number, z: number}
	return {
		x = center.x,
		y = FishingLocation.Travel.y,
		z = center.z + FishingLocation.Travel.zOffset,
	}
end

function FishingLocation.zoneAt(x: number, y: number, z: number, zones: {{center: {x: number, z: number}}}): number?
	local pier = FishingLocation.Pier
	if y < pier.minRootY or y > pier.maxRootY then return nil end
	for index, zone in ipairs(zones) do
		local center = zone.center
		local localX = x - center.x
		local localZ = z - center.z
		if math.abs(localX) <= pier.halfWidth
			and localZ >= pier.minZOffset
			and localZ <= pier.maxZOffset then
			return index
		end
	end
	return nil
end

return FishingLocation
