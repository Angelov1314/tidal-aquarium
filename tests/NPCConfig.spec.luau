local NPCConfig = require("../src/shared/NPCConfig")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local harbor = NPCConfig.Harbor
local runtime = NPCConfig.Runtime
local zone = {x = 100, z = -40}
expect(harbor.sourceName == harbor.replacementName and harbor.sourceName == "NPC_Greeter_1",
	"harbor replacement identity must remain stable")
expect(harbor.zoneId == 1, "harbor NPC must stay in Zone 1")
expect(harbor.controller == "Humanoid", "runtime controller contract must be explicit")
expect(harbor.templateParent == "ServerStorage", "template must remain server-only until Studio handoff")
expect(type(harbor.templateFolder) == "string" and #harbor.templateFolder > 0, "template folder missing")
expect(type(harbor.templateName) == "string" and #harbor.templateName > 0, "template name missing")
expect(harbor.AnimationId == nil and harbor.animationId == nil, "config must not carry invented animation IDs")
expect(harbor.animationNames.idle == "Idle" and harbor.animationNames.walk == "Walk",
	"authored animation names must remain stable")
expect(type(harbor.patrolOffsets) == "table" and #harbor.patrolOffsets >= 2, "patrol needs multiple candidates")

local expectedCourt = {
	{x = -27, z = 6},
	{x = -17, z = 6},
	{x = -17, z = 12},
	{x = -27, z = 12},
}
expect(#harbor.patrolOffsets == #expectedCourt, "harbor patrol must use the four-point left court")
for index, expected in ipairs(expectedCourt) do
	local actual = harbor.patrolOffsets[index]
	expect(actual.x == expected.x and actual.z == expected.z,
		"harbor patrol point changed from the reviewed left-court route")
end

local seen = {}
for _, offset in ipairs(harbor.patrolOffsets) do
	expect(NPCConfig.isPatrolOffsetValid(offset), "patrol candidate must stay inside arrival envelope")
	local key = tostring(offset.x) .. ":" .. tostring(offset.z)
	expect(not seen[key], "patrol candidates must be distinct")
	seen[key] = true
	local point = NPCConfig.worldPatrolPoint(zone, offset)
	expect(point and point.x == zone.x + offset.x and point.z == zone.z + offset.z,
		"world patrol projection must preserve zone center")
end
local sourcePoint = {x = zone.x - 17, z = zone.z + 7}
local previousCourtPoint = sourcePoint
for _, offset in ipairs(expectedCourt) do
	local courtPoint = NPCConfig.worldPatrolPoint(zone, offset)
	expect(NPCConfig.isArrivalSegmentValid(zone, previousCourtPoint, courtPoint),
		"source-to-court segment must stay inside the reviewed arrival boundary")
	previousCourtPoint = courtPoint
end
expect(NPCConfig.isArrivalSegmentValid(zone, previousCourtPoint, sourcePoint),
	"left-court return segment must stay inside the reviewed arrival boundary")
expect(not NPCConfig.isPatrolOffsetValid({x = runtime.arrivalMinX - 1, z = runtime.arrivalMinZ}),
	"patrol projection must reject points outside the arrival envelope")
local nan = math.huge - math.huge
expect(not NPCConfig.isPatrolOffsetValid({x = nan, z = runtime.arrivalMinZ}),
	"patrol projection must reject NaN coordinates")
expect(not NPCConfig.isPatrolOffsetValid({x = math.huge, z = runtime.arrivalMinZ}),
	"patrol projection must reject infinite coordinates")
expect(NPCConfig.worldPatrolPoint(zone, {x = nan, z = 10}) == nil,
	"world projection must reject non-finite offsets")
expect(NPCConfig.worldPatrolPoint({x = math.huge, z = 0}, {x = 0, z = 10}) == nil,
	"world projection must reject non-finite zone centers")

local startPoint = {x = zone.x - 20, z = zone.z + 8}
local endPoint = {x = zone.x + 20, z = zone.z + 20}
expect(NPCConfig.isArrivalPointValid(zone, startPoint.x, startPoint.z),
	"accepted patrol start must lie inside the arrival envelope")
expect(NPCConfig.isArrivalSegmentValid(zone, startPoint, endPoint),
	"accepted patrol segment must stay inside the arrival envelope")
expect(not NPCConfig.isArrivalSegmentValid(zone, startPoint, {x = zone.x + runtime.arrivalMaxX + 1, z = endPoint.z}),
	"patrol segment must reject an out-of-envelope waypoint")

local holeX = zone.x
local sampled = 0
local clearWithoutHole = NPCConfig.sampleArrivalSegment(zone, startPoint, endPoint, function(x, z)
	sampled += 1
	return NPCConfig.isFiniteNumber(x) and NPCConfig.isFiniteNumber(z)
end)
expect(clearWithoutHole and sampled >= 2, "land validation must sample the segment")
local holeDetected = NPCConfig.sampleArrivalSegment(zone, startPoint, endPoint, function(x, z)
	return math.abs(x - holeX) > 1
end)
expect(not holeDetected, "land validation must reject a hole between valid endpoints")
expect(not NPCConfig.sampleArrivalSegment(zone, startPoint, endPoint, function(x, z)
	return x == x and z == z and false
end), "land validation must fail when a sample has no support")

for _, key in ipairs({"activationRadius", "activeCap", "proximityInterval", "repathCooldown", "waypointTimeout", "agentRadius", "agentHeight", "waypointSpacing", "landSampleSpacing", "animationLoadTimeout", "walkSpeed"}) do
	expect(type(runtime[key]) == "number" and runtime[key] > 0, "runtime bound missing: " .. key)
end
expect(runtime.waypointTimeout >= runtime.repathCooldown, "waypoint timeout must leave room for bounded repath")

print("NPCConfig.spec: authored template contract, bounded patrol envelope and timing policy PASS")
