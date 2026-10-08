-- Read-only acceptance smoke for the single authored harbor NPC.
-- Run in Studio with one player so distance activation can exercise the real
-- server loop. This script never seeds economy state or unlocks content.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WORLD_READY_TIMEOUT = 45
-- Leave room beyond the server's shared cold-animation readiness budget and
-- one bounded heartbeat before declaring replacement startup failed.
local NPC_READY_TIMEOUT = 30

local function expect(value, message)
	if not value then error(message, 2) end
end

local function waitUntil(predicate, timeout)
	local deadline = os.clock() + timeout
	repeat
		if predicate() then return true end
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	until false
end

local function rootOf(model)
	return model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart", true)
		or model:FindFirstChild("Root", true)
		or model:FindFirstChild("RootPart", true)
end

local function visibleMeshBottomY(model)
	local bottom = math.huge
	local visibleMeshCount = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("MeshPart") and descendant.Transparency < 1 then
			local half = descendant.Size * .5
			local cframe = descendant.CFrame
			local corners = {
				Vector3.new(-half.X, -half.Y, -half.Z),
				Vector3.new(-half.X, -half.Y, half.Z),
				Vector3.new(-half.X, half.Y, -half.Z),
				Vector3.new(-half.X, half.Y, half.Z),
				Vector3.new(half.X, -half.Y, -half.Z),
				Vector3.new(half.X, -half.Y, half.Z),
				Vector3.new(half.X, half.Y, -half.Z),
				Vector3.new(half.X, half.Y, half.Z),
			}
			for _, corner in ipairs(corners) do
				bottom = math.min(bottom, cframe:PointToWorldSpace(corner).Y)
			end
			visibleMeshCount += 1
		end
	end
	return if visibleMeshCount > 0 and bottom ~= math.huge then bottom else nil
end

local function horizontalDistance(fromPosition, toPosition)
	local dx = fromPosition.X - toPosition.X
	local dz = fromPosition.Z - toPosition.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function findAnimation(model, name)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Animation") and descendant.Name == name then return descendant end
	end
	return nil
end

local function findStaticNpcCount(world)
	local count = 0
	for _, object in ipairs(world:GetDescendants()) do
		if object:IsA("Model") and string.match(object.Name, "^NPC_") and object:GetAttribute("NPC") ~= true then
			count += 1
		end
	end
	return count
end

local function groundAt(world, model, position)
	local zone = world:FindFirstChild("Zone1")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignored = {model}
	local boats = workspace:FindFirstChild("SailingBoats")
	if boats then table.insert(ignored, boats) end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then table.insert(ignored, player.Character) end
	end
	params.FilterDescendantsInstances = ignored
	params.RespectCanCollide = true
	params.IgnoreWater = false
	local hit = workspace:Raycast(Vector3.new(position.X, position.Y + 20, position.Z), Vector3.new(0, -50, 0), params)
	return hit and hit.Instance and hit.Instance:IsDescendantOf(zone) and hit.Instance.CanCollide
		and hit.Instance:GetAttribute("CollisionRole") == "WalkableIsland"
		and hit.Material ~= Enum.Material.Water and hit
end

local function run()
	local shared = ReplicatedStorage:WaitForChild("FishingShared", WORLD_READY_TIMEOUT)
	local NPCConfig = require(shared:WaitForChild("NPCConfig"))
	local WorldLayout = require(shared:WaitForChild("WorldLayout"))
	expect(NPC_READY_TIMEOUT > NPCConfig.Runtime.animationLoadTimeout + 5,
		"NPC smoke readiness budget must exceed the server animation deadline")
	local world = workspace:WaitForChild("FishingWorld", WORLD_READY_TIMEOUT)
	expect(world, "FishingWorld missing")
	expect(waitUntil(function() return world:GetAttribute("Ready") == true end, WORLD_READY_TIMEOUT),
		"FishingWorld did not become Ready")
	local zone = world:WaitForChild("Zone1", 5)
	expect(zone, "Zone1 missing")
	local dynamicNpcs = {}
	local npc = nil
	local dynamicReady = waitUntil(function()
		dynamicNpcs = {}
		for _, child in ipairs(zone:GetChildren()) do
			if child:IsA("Model") and child:GetAttribute("NPC") == true then
				table.insert(dynamicNpcs, child)
			end
		end
		npc = dynamicNpcs[1]
		return #dynamicNpcs == 1
	end, NPC_READY_TIMEOUT)
	expect(dynamicReady, "validated dynamic harbor NPC did not appear; status=" .. tostring(world:GetAttribute("NPCIntegrationStatus")))
	expect(#dynamicNpcs == 1, "exactly one dynamic harbor NPC must be present")
	expect(world:GetAttribute("NPCIntegrationStatus") == "Validated", "NPC integration status must be validated")
	expect(npc:GetAttribute("NPCController") == "Humanoid", "dynamic NPC controller contract missing")
	expect((npc:GetAttribute("NPCJointCount") or 0) >= 2, "dynamic NPC must expose an articulated rig")
	expect((npc:GetAttribute("NPCIdleTrackLength") or 0) > 0 and (npc:GetAttribute("NPCWalkTrackLength") or 0) > 0,
		"authored animation tracks must have loaded lengths before replacement")
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local root = rootOf(npc)
	expect(humanoid and root, "dynamic NPC root or Humanoid missing")
	expect(waitUntil(function()
		return humanoid.Health > 0 and humanoid.RootPart == root
	end, NPC_READY_TIMEOUT), "dynamic NPC Humanoid must be alive with RootPart bound to its validated root")
	expect(not root.Anchored, "dynamic NPC root must be unanchored")
	local connected = {[root] = true}
	for _, part in ipairs(root:GetConnectedParts(true)) do connected[part] = true end
	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("BasePart") then
			expect(connected[part], "dynamic NPC body must share one root assembly: " .. part:GetFullName())
		end
	end
	local idle = findAnimation(npc, NPCConfig.Harbor.animationNames.idle)
	local walk = findAnimation(npc, NPCConfig.Harbor.animationNames.walk)
	expect(idle and idle:IsA("Animation") and idle.AnimationId ~= "", "authored Idle animation missing")
	expect(walk and walk:IsA("Animation") and walk.AnimationId ~= "", "authored Walk animation missing")
	expect(findStaticNpcCount(world) == 17, "exactly one static NPC should be replaced")
	local sourceCount = 0
	for _, object in ipairs(world:GetDescendants()) do
		if object:IsA("Model") and object.Name == NPCConfig.Harbor.sourceName then sourceCount += 1 end
	end
	expect(sourceCount == 1 and npc.Name == NPCConfig.Harbor.replacementName,
		"replacement must leave one replicated source-name model and no duplicate")

	local zoneLayout = WorldLayout.Zones[NPCConfig.Harbor.zoneId]
	local previousPoint = {x = root.Position.X, z = root.Position.Z}
	for _, offset in ipairs(NPCConfig.Harbor.patrolOffsets) do
		expect(NPCConfig.isPatrolOffsetValid(offset), "patrol candidate escaped the arrival envelope")
		local point = NPCConfig.worldPatrolPoint(zoneLayout, offset)
		expect(point, "patrol candidate could not project to Zone 1")
		local support = groundAt(world, npc, Vector3.new(point.x, root.Position.Y, point.z))
		expect(support, "patrol candidate did not project onto collidable Zone 1 land")
		expect(NPCConfig.isArrivalSegmentValid(zoneLayout, previousPoint, point),
		"patrol candidate segment escaped the arrival envelope")
		expect(NPCConfig.sampleArrivalSegment(zoneLayout, previousPoint, point, function(x, z)
			return not not groundAt(world, npc, Vector3.new(x, root.Position.Y, z))
		end), "patrol candidate segment crossed a land hole")
		previousPoint = point
	end
	expect(not NPCConfig.isPatrolOffsetValid({x = 0, z = NPCConfig.Runtime.arrivalMaxZ + 1}),
		"patrol envelope must reject the dock corridor")
	local waterParams = RaycastParams.new()
	waterParams.FilterType = Enum.RaycastFilterType.Exclude
	local waterIgnored = {npc}
	local boats = workspace:FindFirstChild("SailingBoats")
	if boats then table.insert(waterIgnored, boats) end
	waterParams.FilterDescendantsInstances = waterIgnored
	waterParams.IgnoreWater = false
	local waterHit = workspace:Raycast(Vector3.new(0, 31, 82), Vector3.new(0, -80, 0), waterParams)
	expect(waterHit and waterHit.Material == Enum.Material.Water, "water rejection probe must remain water")

	local initial = root.Position
	local sawPath = waitUntil(function() return (npc:GetAttribute("NPCPathCount") or 0) > 0 end, NPC_READY_TIMEOUT)
	expect(sawPath, "NPC did not compute a path within the bounded window")
	local sawWalk = waitUntil(function() return (npc:GetAttribute("NPCWalkCount") or 0) > 0 end, NPC_READY_TIMEOUT)
	expect(sawWalk, "NPC did not enter Walk animation within the bounded window")
	local moved = waitUntil(function()
		return humanoid.Health > 0
			and humanoid.RootPart == root
			and horizontalDistance(root.Position, initial) > 2
	end, NPC_READY_TIMEOUT)
	expect(moved, "NPC root did not move during authored patrol")
	expect(waitUntil(function() return npc:GetAttribute("NPCMotionState") == "Idle" end, NPC_READY_TIMEOUT),
		"NPC did not return to Idle after movement")
	expect(humanoid.Health > 0, "NPC Humanoid died during authored patrol")
	expect(humanoid.RootPart == root, "NPC Humanoid.RootPart changed during authored patrol")
	local support = groundAt(world, npc, root.Position)
	expect(support, "NPC root is not supported by Zone 1 land")
	local visibleBottom = visibleMeshBottomY(npc)
	expect(visibleBottom ~= nil, "settled NPC has no visible MeshPart envelope")
	local visibleContactDelta = math.abs(visibleBottom - support.Position.Y)
	expect(visibleContactDelta <= 0.05,
		string.format("settled visible MeshPart envelope is %.6f studs from support", visibleContactDelta))
	ReplicatedStorage:SetAttribute("NPCVisibleMeshContactPass", true)
	expect(NPCConfig.isArrivalPointValid(zoneLayout, root.Position.X, root.Position.Z),
		"NPC reached outside the arrival-land envelope")
	local npcGroundY = npc:GetAttribute("NPCGroundY")
	local rootGroundOffset = npc:GetAttribute("NPCRootGroundOffset")
	expect(NPCConfig.isFiniteNumber(npcGroundY) and NPCConfig.isFiniteNumber(rootGroundOffset),
		"NPC ground and root offset attributes must be finite")
	local expectedRootY = npcGroundY + rootGroundOffset
	expect(math.abs(root.Position.Y - expectedRootY) <= 1,
		"NPC root height drifted more than 1 stud from its validated ground offset")

	ReplicatedStorage:SetAttribute("NPCServiceSmokePass", true)
	print("NPC_VISIBLE_PART_ENVELOPE_PASS", "settled visible MeshPart rest envelope meets land support; this is not animated sole proof", "delta", visibleContactDelta)
	print("NPC_SERVICE_PASS", "one authored harbor NPC walked on Zone 1 land and returned idle", "staticNPCs", findStaticNpcCount(world))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	ReplicatedStorage:SetAttribute("NPCServiceSmokePass", false)
	ReplicatedStorage:SetAttribute("NPCVisibleMeshContactPass", false)
	warn("NPC_SERVICE_FAIL: " .. tostring(err))
end
