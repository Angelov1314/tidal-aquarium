--!strict
-- Data-only contract for the first authored, animated harbor NPC.
-- The imported model and Animation instances are supplied by the Studio asset
-- handoff; this module intentionally contains no numeric animation IDs.
local NPCConfig = {}

local function isFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

NPCConfig.Harbor = {
	sourceName = "NPC_Greeter_1",
	replacementName = "NPC_Greeter_1",
	templateParent = "ServerStorage",
	templateFolder = "NPCTemplates",
	templateName = "HarborFisher",
	zoneId = 1,
	controller = "Humanoid",
	patrolOffsets = {
		-- Keep the greeter on the left arrival court. The central gate roof and
		-- welcome board occupy x=-10.5..10.5 / z=13..17.
		{x = -27, z = 6},
		{x = -17, z = 6},
		{x = -17, z = 12},
		{x = -27, z = 12},
	},
	animationNames = {idle = "Idle", walk = "Walk"},
}

NPCConfig.Runtime = {
	activationRadius = 260,
	activeCap = 6,
	proximityInterval = 0.5,
	repathCooldown = 1.0,
	waypointTimeout = 4.0,
	agentRadius = 2.2,
	agentHeight = 6.0,
	waypointSpacing = 4.0,
	landSampleSpacing = 2.0,
	-- One shared wall-clock budget covers both tracks while they load in
	-- parallel. It is longer than the observed cold-cache failure window but
	-- remains small enough to fail closed during service startup.
	animationLoadTimeout = 8.0,
	-- The approved in-place Walk clip covers about 3.51 studs/second. Match
	-- Humanoid speed to the authored stride so the feet do not slide.
	walkSpeed = 3.51,
	-- Zone 1's arrival court is x=-33..33 and z=2..27. Keep a margin so
	-- path endpoints cannot spill onto the gate, promenade, or dock lane.
	arrivalMinX = -30,
	arrivalMaxX = 30,
	arrivalMinZ = 5,
	arrivalMaxZ = 25,
}

NPCConfig.isFiniteNumber = isFiniteNumber

local function isArrivalLocalPointValid(x, z)
	local runtime = NPCConfig.Runtime
	return isFiniteNumber(x)
		and isFiniteNumber(z)
		and x >= runtime.arrivalMinX
		and x <= runtime.arrivalMaxX
		and z >= runtime.arrivalMinZ
		and z <= runtime.arrivalMaxZ
end

function NPCConfig.isPatrolOffsetValid(offset)
	if type(offset) ~= "table" then return false end
	return isArrivalLocalPointValid(offset.x, offset.z)
end

function NPCConfig.worldPatrolPoint(zone, offset)
	if type(zone) ~= "table" or not NPCConfig.isPatrolOffsetValid(offset) then return nil end
	if not isFiniteNumber(zone.x) or not isFiniteNumber(zone.z) then return nil end
	local x = zone.x + offset.x
	local z = zone.z + offset.z
	if not isFiniteNumber(x) or not isFiniteNumber(z) then return nil end
	return {x = x, z = z}
end

function NPCConfig.isArrivalPointValid(zone, x, z)
	if type(zone) ~= "table" or not isFiniteNumber(zone.x) or not isFiniteNumber(zone.z) then return false end
	if not isFiniteNumber(x) or not isFiniteNumber(z) then return false end
	return isArrivalLocalPointValid(x - zone.x, z - zone.z)
end

function NPCConfig.isArrivalSegmentValid(zone, fromPoint, toPoint)
	if type(fromPoint) ~= "table" or type(toPoint) ~= "table" then return false end
	if not NPCConfig.isArrivalPointValid(zone, fromPoint.x, fromPoint.z)
		or not NPCConfig.isArrivalPointValid(zone, toPoint.x, toPoint.z) then
		return false
	end
	-- The arrival contract is an axis-aligned rectangle, so the straight line
	-- between two accepted points stays inside it. Keep the explicit extrema
	-- check here so callers cannot accidentally weaken that guarantee when the
	-- envelope is changed later.
	local minX = math.min(fromPoint.x, toPoint.x) - zone.x
	local maxX = math.max(fromPoint.x, toPoint.x) - zone.x
	local minZ = math.min(fromPoint.z, toPoint.z) - zone.z
	local maxZ = math.max(fromPoint.z, toPoint.z) - zone.z
	local runtime = NPCConfig.Runtime
	return isFiniteNumber(minX)
		and isFiniteNumber(maxX)
		and isFiniteNumber(minZ)
		and isFiniteNumber(maxZ)
		and minX >= runtime.arrivalMinX
		and maxX <= runtime.arrivalMaxX
		and minZ >= runtime.arrivalMinZ
		and maxZ <= runtime.arrivalMaxZ
end

function NPCConfig.sampleArrivalSegment(zone, fromPoint, toPoint, supportAt)
	if type(supportAt) ~= "function" or not NPCConfig.isArrivalSegmentValid(zone, fromPoint, toPoint) then
		return false
	end
	local dx = toPoint.x - fromPoint.x
	local dz = toPoint.z - fromPoint.z
	local distance = math.sqrt(dx * dx + dz * dz)
	if not isFiniteNumber(distance) then return false end
	local spacing = NPCConfig.Runtime.landSampleSpacing
	if not isFiniteNumber(spacing) or spacing <= 0 then return false end
	local steps = math.max(1, math.ceil(distance / spacing))
	for index = 0, steps do
		local alpha = index / steps
		local x = fromPoint.x + dx * alpha
		local z = fromPoint.z + dz * alpha
		local ok, supported = pcall(supportAt, x, z)
		if not ok or not supported then return false end
	end
	return true
end

return NPCConfig
