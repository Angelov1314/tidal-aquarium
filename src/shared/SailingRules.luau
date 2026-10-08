--!strict
-- Pure sailing math and input validation.  This module deliberately has no
-- Roblox dependencies so the server movement contract can be exercised by
-- Luau tests before Studio is involved.
local SailingRules = {}

SailingRules.InputLimit = 1
SailingRules.InputTolerance = 0.001
SailingRules.MaxIntentAge = 0.45
SailingRules.IntentRate = 20
SailingRules.IntentInterval = 1 / SailingRules.IntentRate
SailingRules.MaxDeltaTime = 0.12
SailingRules.OceanMargin = 18
SailingRules.DockOffset = 76
SailingRules.SpawnOffset = 96
SailingRules.DockAuthorizationRadius = 24
SailingRules.DockDisembarkRadius = 112
SailingRules.RecoveryLifetime = 10

local function finiteNumber(value: any): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

function SailingRules.isFinite(value: any): boolean
	return finiteNumber(value)
end

function SailingRules.clamp(value: number, minimum: number, maximum: number): number
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

function SailingRules.normalizeIntent(payload: any): ({throttle: number, steer: number}?, string?)
	if type(payload) ~= "table" then return nil, "驾驶输入格式无效。" end
	local throttle = payload.throttle
	local steer = payload.steer
	if not finiteNumber(throttle) or not finiteNumber(steer) then
		return nil, "驾驶输入必须是有限数字。"
	end
	if math.abs(throttle) > SailingRules.InputLimit + SailingRules.InputTolerance
		or math.abs(steer) > SailingRules.InputLimit + SailingRules.InputTolerance then
		return nil, "驾驶输入超出范围。"
	end
	return {
		throttle = SailingRules.clamp(throttle, -SailingRules.InputLimit, SailingRules.InputLimit),
		steer = SailingRules.clamp(steer, -SailingRules.InputLimit, SailingRules.InputLimit),
	}, nil
end

function SailingRules.isOceanPoint(x: number, z: number, ocean: any, margin: number?): boolean
	if not finiteNumber(x) or not finiteNumber(z) or type(ocean) ~= "table" then return false end
	local edge = margin or SailingRules.OceanMargin
	if not finiteNumber(edge) or edge < 0 then return false end
	return x >= ocean.minX + edge
		and x <= ocean.maxX - edge
		and z >= ocean.minZ + edge
		and z <= ocean.maxZ - edge
end

function SailingRules.clampOceanPoint(x: number, z: number, ocean: any, margin: number?): (number, number)
	local edge = margin or SailingRules.OceanMargin
	return SailingRules.clamp(x, ocean.minX + edge, ocean.maxX - edge),
		SailingRules.clamp(z, ocean.minZ + edge, ocean.maxZ - edge)
end

function SailingRules.distance2D(ax: number, az: number, bx: number, bz: number): number
	local dx = ax - bx
	local dz = az - bz
	return math.sqrt(dx * dx + dz * dz)
end

function SailingRules.wrapAngle(angle: number): number
	local twoPi = math.pi * 2
	angle = angle % twoPi
	if angle > math.pi then angle -= twoPi end
	return angle
end

-- Roblox yaw 0 looks down -Z.  Positive steer is the player's right-hand
-- input (D/right), so yaw decreases while the boat turns from north toward
-- +X. Keep this convention in the pure contract so tests and server/client
-- map arrows agree.
function SailingRules.forwardForHeading(heading: number): (number, number)
	return -math.sin(heading), -math.cos(heading)
end

function SailingRules.integrate(
	x: number,
	z: number,
	heading: number,
	velocity: number,
	intent: any,
	deltaTime: number,
	boat: any
): {x: number, z: number, heading: number, velocity: number}
	local normalized = SailingRules.normalizeIntent(intent)
	local input: {throttle: number, steer: number}
	if normalized then input = normalized else input = {throttle = 0, steer = 0} end
	local dt = SailingRules.clamp(deltaTime, 0, SailingRules.MaxDeltaTime)
	local speed = if finiteNumber(boat and boat.speed) then math.max(0, boat.speed) else 0
	local turnSpeed = if finiteNumber(boat and boat.turnSpeed) then math.max(0, boat.turnSpeed) else 0
	local acceleration = if finiteNumber(boat and boat.acceleration) then math.max(0, boat.acceleration) else speed * 2.5
	local drag = if finiteNumber(boat and boat.drag) then math.max(0, boat.drag) else 1.8
	local maxReverse = speed * 0.35

	local nextVelocity = velocity + input.throttle * acceleration * dt
	if math.abs(input.throttle) < 0.001 then
		local decay = math.max(0, 1 - drag * dt)
		nextVelocity *= decay
	end
	nextVelocity = SailingRules.clamp(nextVelocity, -maxReverse, speed)
	local steerFactor = math.min(1, math.abs(nextVelocity) / math.max(speed, 0.001))
	local nextHeading = SailingRules.wrapAngle(heading - input.steer * turnSpeed * dt * (0.25 + 0.75 * steerFactor))
	local forwardX, forwardZ = SailingRules.forwardForHeading(nextHeading)
	return {
		x = x + forwardX * nextVelocity * dt,
		z = z + forwardZ * nextVelocity * dt,
		heading = nextHeading,
		velocity = nextVelocity,
	}
end

return SailingRules
