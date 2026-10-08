--!strict
-- Canonical, Roblox-free world geometry contract.
--
-- The server builder and the boat controller deliberately consume the same
-- numbers.  Keep this module data-only so the Luau contract specs can run
-- outside Studio and so a client map can draw the same two-dimensional chart.
local WorldLayout = {}

-- The eight outer islands use an irregular ring around the original harbor.
-- Nearest-neighbour spacing is about 1023..1500 studs; the south (positive-Z) side
-- stays open around each +Z pier for the boat approach and cast channel.
WorldLayout.Zones = {
	[1] = { x = 0, z = 0, shape = "harbor_crescent", width = 420, depth = 390 },
	[2] = { x = 1260, z = -360, shape = "coral_fan", width = 360, depth = 330 },
	[3] = { x = 420, z = -1420, shape = "trench_hook", width = 390, depth = 340 },
	[4] = { x = -1120, z = -820, shape = "moon_ring", width = 430, depth = 350 },
	[5] = { x = 1500, z = 1080, shape = "rainbow_steps", width = 400, depth = 380 },
	[6] = { x = -1480, z = 260, shape = "mystic_isle", width = 410, depth = 350 },
	[7] = { x = -380, z = 1450, shape = "basalt_hook", width = 370, depth = 430 },
	[8] = { x = 1460, z = -1600, shape = "signal_atoll", width = 390, depth = 420 },
	[9] = { x = 650, z = 1650, shape = "laboratory_spur", width = 360, depth = 410 },
}

-- Water is filled in bounded X strips by World.build. A 640 x 4150 x 18
-- strip is about 747,000 4-stud terrain voxels, keeping each FillBlock well
-- below the large single-region threshold while covering every route and
-- shoreline.  The floor is placed at y=-18 and the water surface is y=0.
WorldLayout.Ocean = {
	minX = -1900,
	maxX = 1900,
	minZ = -2250,
	maxZ = 1900,
	surfaceY = 0,
}

WorldLayout.Boat = {
	speed = 54,
	turnSpeed = 1.55,
}

function WorldLayout.zone(id)
	return WorldLayout.Zones[id]
end

function WorldLayout.center(id)
	local zone = WorldLayout.Zones[id]
	if not zone then return nil end
	return { x = zone.x, z = zone.z }
end

function WorldLayout.bounds(zone)
	return {
		-- The silhouettes use small rotated lobes, so their conservative X
		-- bound is a little wider than the nominal width. The arrival court
		-- intentionally reaches +Z 34 to meet the existing promenade/spawn.
		minX = zone.x - zone.width * 0.58,
		maxX = zone.x + zone.width * 0.58,
		-- Island silhouettes are intentionally biased north (-Z) so every
		-- +Z pier has real water from the last plank (z+80) to the boat lane.
		minZ = zone.z - zone.depth * 1.05,
		maxZ = zone.z + 40,
	}
end

return WorldLayout
