-- Read-only runtime scene contract review.
-- This is derived from SailingSmoke.server.luau's map checks.  It never
-- teleports players, calls FishingService/BoatService, unlocks anything, or
-- changes economy state.  NPC checks accept the ground agent's explicit
-- SceneRole/NPC/WorldRole attributes and the NPC name prefix as a fallback.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local WORLD_READY_TIMEOUT = 45
local TERRAIN_WATER_READY_TIMEOUT = 5
local function expect(value, message)
	if not value then error(message, 2) end
end
local function rayParams(exclude, respectCanCollide)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignored = table.clone(exclude or {})
	for _, player in game:GetService("Players"):GetPlayers() do if player.Character then table.insert(ignored, player.Character) end end
	params.FilterDescendantsInstances = ignored
	params.IgnoreWater = false
	if respectCanCollide ~= nil then params.RespectCanCollide = respectCanCollide end
	return params
end
local function groundAt(x, z, y, extraExclude)
	local exclude = {workspace:FindFirstChild("SailingBoats")}
	for _, object in ipairs(extraExclude or {}) do table.insert(exclude, object) end
	return workspace:Raycast(Vector3.new(x, y or 45, z), Vector3.new(0, -100, 0), rayParams(exclude, true))
end
local function corners(part)
	local half = part.Size * .5
	local result = {}
	for _, sx in {-1, 1} do
		for _, sy in {-1, 1} do
			for _, sz in {-1, 1} do
				table.insert(result, part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
			end
		end
	end
	return result
end
local function markedNpc(object)
	local role = object:GetAttribute("SceneRole")
		or object:GetAttribute("WorldRole")
		or object:GetAttribute("Role")
	if role == "NPC" or role == "npc" then return true end
	if object:GetAttribute("NPC") == true or object:GetAttribute("IsNPC") == true then return true end
	return string.find(string.lower(object.Name), "npc", 1, true) ~= nil
end
local function npcRoot(object, world)
	local cursor = object
	while cursor and cursor ~= world do
		if cursor:IsA("Model") and markedNpc(cursor) then return cursor end
		cursor = cursor.Parent
	end
	if markedNpc(object) then return object end
	return nil
end
local function zoneAncestor(object)
	local cursor = object
	while cursor and cursor ~= workspace do
		local id = string.match(cursor.Name, "^Zone(%d+)$")
		if id then return cursor, tonumber(id) end
		cursor = cursor.Parent
	end
	return nil, nil
end
local function npcPosition(object)
	if object:IsA("BasePart") then return object.Position end
	local ok, pivot = pcall(function() return object:GetPivot() end)
	return if ok then pivot.Position else nil
end
local function sameColor(a, b)
	return math.abs(a.R - b.R) < .001 and math.abs(a.G - b.G) < .001 and math.abs(a.B - b.B) < .001
end

local function waitForWorldReady(world, deadline)
	while world:GetAttribute("Ready") ~= true do
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	end
	return true
end

local function terrainWaterReady(Config, Layout, Location)
	if not workspace:FindFirstChildOfClass("Terrain") then return false end
	local ocean = Layout.Ocean
	for _, zone in ipairs(Config.Zones) do
		local exclude = {}
		local boats = workspace:FindFirstChild("SailingBoats")
		if boats then table.insert(exclude, boats) end
		local castOrigin = Vector3.new(zone.center.x, ocean.surfaceY + 31, zone.center.z + Location.Cast.zOffset)
		local hit = workspace:Raycast(castOrigin, Vector3.new(0, -80, 0), rayParams(exclude, false))
		if not hit or hit.Material ~= Enum.Material.Water then return false end
	end
	return true
end

local function waitForTerrainWaterReady(Config, Layout, Location, timeout)
	local deadline = os.clock() + timeout
	repeat
		if terrainWaterReady(Config, Layout, Location) then return true end
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	until false
end

local function run()
	local shared = ReplicatedStorage:WaitForChild("FishingShared", 45)
	local Config = require(shared:WaitForChild("Config"))
	local Layout = require(shared:WaitForChild("WorldLayout"))
	local Location = require(shared:WaitForChild("FishingLocation"))
	local Rules = require(shared:WaitForChild("SailingRules"))
	local worldReadyDeadline = os.clock() + WORLD_READY_TIMEOUT
	local world = workspace:WaitForChild("FishingWorld", math.max(0, worldReadyDeadline - os.clock()))
	expect(world, "FishingWorld missing")
	expect(waitForWorldReady(world, worldReadyDeadline), "FishingWorld did not become Ready within 45 seconds")
	expect(waitForTerrainWaterReady(Config, Layout, Location, TERRAIN_WATER_READY_TIMEOUT),
		"Terrain/water did not become ready within 5 seconds after FishingWorld Ready")
	local ocean = Layout.Ocean
	expect(world:GetAttribute("OceanMinX") == ocean.minX and world:GetAttribute("OceanMaxX") == ocean.maxX
		and world:GetAttribute("OceanMinZ") == ocean.minZ and world:GetAttribute("OceanMaxZ") == ocean.maxZ,
		"runtime ocean attributes drift from WorldLayout")
	local minimumNpcs = tonumber(world:GetAttribute("NPCMinimumPerZone")) or 2
	local npcRoots = {}
	local npcExclude = {}
	for _, object in ipairs(world:GetDescendants()) do
		local root = npcRoot(object, world)
		if root and not npcRoots[root] then
			npcRoots[root] = true
			table.insert(npcExclude, root)
		end
	end
	local totalNpcs = 0
	local dynamicNpcCount = 0
	for zoneId, zone in ipairs(Config.Zones) do
		local layout = Layout.Zones[zoneId]
		expect(layout and zone.center.x == layout.x and zone.center.z == layout.z,
			"config/layout center drift in zone " .. tostring(zoneId))
		local folder = world:FindFirstChild("Zone" .. tostring(zoneId))
		expect(folder and folder:GetAttribute("ZoneShape") == layout.shape, "runtime shape missing in zone " .. tostring(zoneId))
		local landParts = {}
		local minX, minZ = math.huge, math.huge
		local maxX, maxZ = -math.huge, -math.huge
		local surfaceMaterial, surfaceColor
		local surfaceCount = 0
		for _, object in ipairs(folder:GetDescendants()) do
			local lowerName = string.lower(object.Name)
			expect(string.find(lowerName, "shoreridge", 1, true) == nil,
				"legacy ShoreRidge surface remains in zone " .. tostring(zoneId) .. ": " .. object:GetFullName())
			expect(object:GetAttribute("LegacyCoplanar") ~= true and string.find(lowerName, "legacycoplanar", 1, true) == nil,
				"legacy coplanar ground remains in zone " .. tostring(zoneId) .. ": " .. object:GetFullName())
			if object:IsA("BasePart") and object:GetAttribute("GroundLayer") == "BiomeSurface" then
				surfaceCount += 1
				surfaceMaterial = surfaceMaterial or object.Material
				surfaceColor = surfaceColor or object.Color
				expect(object.Material == surfaceMaterial and sameColor(object.Color, surfaceColor),
					"BiomeSurface material/color drift in zone " .. tostring(zoneId))
				expect(object.Anchored and object.CanCollide, "BiomeSurface must be anchored/collidable in zone " .. tostring(zoneId))
			end
			if object:IsA("BasePart") and object:GetAttribute("CollisionRole") == "WalkableIsland" and object.CanCollide then
				table.insert(landParts, object)
				for _, point in ipairs(corners(object)) do
					minX, maxX = math.min(minX, point.X), math.max(maxX, point.X)
					minZ, maxZ = math.min(minZ, point.Z), math.max(maxZ, point.Z)
					expect(point.X >= ocean.minX and point.X <= ocean.maxX and point.Z >= ocean.minZ and point.Z <= ocean.maxZ,
						"island footprint exceeds ocean bounds in zone " .. tostring(zoneId))
				end
			end
		end
		expect(surfaceCount > 0, "zone has no BiomeSurface layer: " .. tostring(zoneId))
		expect(#landParts >= 3, "zone needs multiple runtime land pieces in zone " .. tostring(zoneId))
		expect(math.max(maxX - minX, maxZ - minZ) >= 180, "runtime island footprint is too small in zone " .. tostring(zoneId))

		-- The dock-to-inland centerline must stay physically walkable.
		for _, offset in ipairs({76, 68, 60, 52, 44, 36, 30, 25, 20, 10, 0, -6, -12, -20, -40, -60, -80}) do
			local hit = groundAt(zone.center.x, zone.center.z + offset, 45)
			expect(hit and hit.Instance and hit.Instance:IsDescendantOf(folder) and hit.Instance.CanCollide,
				"walkable centerline gap in zone " .. tostring(zoneId) .. " at z+" .. tostring(offset))
		end

		-- +82 is the authored fishing cast point and must remain actual water.
		local castOrigin = Vector3.new(zone.center.x, ocean.surfaceY + 31, zone.center.z + Location.Cast.zOffset)
		local castHit = workspace:Raycast(castOrigin, Vector3.new(0, -80, 0), rayParams({workspace:FindFirstChild("SailingBoats")}, false))
		expect(castHit and castHit.Material == Enum.Material.Water,
			"cast +" .. tostring(Location.Cast.zOffset) .. " is not water in zone " .. tostring(zoneId))

		-- The boat spawn box must have clear collision, including new NPC props.
		local spawn = Vector3.new(zone.center.x, ocean.surfaceY + .7, zone.center.z + Rules.SpawnOffset)
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		overlap.FilterDescendantsInstances = {workspace:FindFirstChild("SailingBoats")}
		for _, blocker in ipairs(workspace:GetPartBoundsInBox(CFrame.new(spawn), Vector3.new(13, 4, 24), overlap)) do
			expect(not blocker.CanCollide, "boat spawn +" .. tostring(Rules.SpawnOffset) .. " blocked by " .. blocker:GetFullName())
		end

		local perZone = 0
		local perZoneClusters = 0
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and string.match(child.Name, "^SceneryCluster_%d%d$") then
				perZoneClusters += 1
				expect(child:GetAttribute("Zone") == zoneId, "scenery cluster zone drift: " .. child:GetFullName())
			end
		end
		expect(perZoneClusters == 4, "zone " .. tostring(zoneId) .. " has " .. tostring(perZoneClusters) .. " scenery clusters; expected exactly 4")
		for root in pairs(npcRoots) do
			local npcZone, npcZoneId = zoneAncestor(root)
			if npcZone == folder or npcZoneId == zoneId then
				perZone += 1
				local position = npcPosition(root)
				expect(position, "NPC has no world position in zone " .. tostring(zoneId))
				local support = groundAt(position.X, position.Z, math.max(45, position.Y + 20), {root})
				expect(support and support.Instance and support.Instance:IsDescendantOf(folder) and support.Instance.CanCollide,
					"NPC is not supported by walkable land in zone " .. tostring(zoneId) .. ": " .. root:GetFullName())
				local humanoid = root:FindFirstChildOfClass("Humanoid")
				local dynamic = root:GetAttribute("NPC") == true and humanoid ~= nil
				if dynamic then
					dynamicNpcCount += 1
					local rootPart = root.PrimaryPart or root:FindFirstChild("HumanoidRootPart", true) or root:FindFirstChild("Root", true)
					expect(rootPart and rootPart:IsA("BasePart") and not rootPart.Anchored,
						"dynamic NPC needs an unanchored movement root: " .. root:GetFullName())
					for _, part in ipairs(root:GetDescendants()) do
						if part:IsA("BasePart") then
							expect(not part.Anchored, "dynamic NPC body must be unanchored: " .. part:GetFullName())
						end
					end
				else
					local base = root:FindFirstChild("NPCBase", true)
					expect(base and base:IsA("BasePart"), "NPCBase missing in zone " .. tostring(zoneId) .. ": " .. root:GetFullName())
					local baseBottom = base.Position.Y - base.Size.Y * .5
					expect(math.abs(baseBottom - support.Position.Y) <= .15,
						"NPCBase is not seated on support in zone " .. tostring(zoneId) .. ": base=" .. tostring(baseBottom) .. " hit=" .. tostring(support.Position.Y))
					for _, part in ipairs(root:GetDescendants()) do
						if part:IsA("BasePart") then
							expect(part.Anchored and not part.CanCollide,
								"NPC presentation must be anchored/noncolliding: " .. part:GetFullName())
						end
					end
				end
			end
		end
		totalNpcs += perZone
		expect(perZone == minimumNpcs and minimumNpcs == 2,
			"zone " .. tostring(zoneId) .. " has " .. tostring(perZone) .. " NPCs; expected exactly 2")
		print("SCENE_GEOMETRY_ZONE_PASS", zoneId, #landParts, perZone, perZoneClusters, "centerline/cast/boat/NPC clear")
	end
	expect(dynamicNpcCount <= 1, "scene review allows at most one dynamic authored NPC")
	ReplicatedStorage:SetAttribute("SceneGeometryReviewPass", true)
	ReplicatedStorage:SetAttribute("SceneGeometryNPCCount", totalNpcs)
	ReplicatedStorage:SetAttribute("SceneGeometryDynamicNPCCount", dynamicNpcCount)
	print("SCENE_GEOMETRY_PASS", "nine zones, walkable centerlines, cast water, boat clearance, NPC land support", totalNpcs)
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	ReplicatedStorage:SetAttribute("SceneGeometryReviewPass", false)
	warn("SCENE_GEOMETRY_FAIL: " .. tostring(err))
end
