local Rules = require("../src/shared/SailingRules")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local normalized, reason = Rules.normalizeIntent({throttle = .5, steer = -.25})
expect(normalized and reason == nil and normalized.throttle == .5 and normalized.steer == -.25, "valid intent should normalize")

for _, value in ipairs({0 / 0, math.huge, -math.huge}) do
	local safe = Rules.normalizeIntent({throttle = value, steer = 0})
	expect(safe == nil, "non-finite throttle must be rejected")
	safe = Rules.normalizeIntent({throttle = 0, steer = value})
	expect(safe == nil, "non-finite steer must be rejected")
end

expect(Rules.normalizeIntent({throttle = 1.1, steer = 0}) == nil, "out-of-range throttle must be rejected")
expect(Rules.normalizeIntent({throttle = 0, steer = -1.1}) == nil, "out-of-range steer must be rejected")

local ocean = {minX = -100, maxX = 100, minZ = -200, maxZ = 200}
expect(Rules.isOceanPoint(0, 0, ocean), "center should be in ocean")
expect(not Rules.isOceanPoint(-100, 0, ocean), "ocean edge must retain margin")
local x, z = Rules.clampOceanPoint(-1000, 1000, ocean)
expect(x == -82 and z == 182, "ocean clamp should retain boat margin")

local pose = Rules.integrate(0, 0, 0, 0, {throttle = 1, steer = 0}, .1, {
	speed = 40,
	turnSpeed = 1.2,
	acceleration = 80,
})
expect(pose.velocity > 0 and pose.z < 0, "forward motion should use Roblox -Z heading")
local turned = Rules.integrate(pose.x, pose.z, pose.heading, pose.velocity, {throttle = 1, steer = 1}, .1, {
	speed = 40,
	turnSpeed = 1.2,
	acceleration = 80,
})
expect(turned.heading < pose.heading, "positive steer should turn right from north")
expect(turned.x > pose.x, "positive steer should move toward +X")

print("SailingRules.spec: finite intent, ocean bounds, server movement integration PASS")
