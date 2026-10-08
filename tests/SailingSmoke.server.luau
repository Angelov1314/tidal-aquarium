-- SailingQA server smoke. This deliberately probes the built world instead of
-- trusting WorldLayout's declared rectangles: the lobe parts and walkable
-- collision are the runtime contract a player actually experiences.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local function waitForChildBounded(parent, name, timeout, label)
	local deadline = os.clock() + (timeout or 30)
	local candidate = parent:FindFirstChild(name)
	while candidate == nil and os.clock() < deadline do
		task.wait(.1)
		candidate = parent:FindFirstChild(name)
	end
	if candidate == nil then error(label or (name .. " did not become ready"), 2) end
	return candidate
end

local function requireModule(parent, name, label)
	local candidate = waitForChildBounded(parent, name, 30, label or (name .. " module did not become ready"))
	if not candidate:IsA("ModuleScript") then error((label or name) .. " must be a ModuleScript", 2) end
	return require(candidate)
end

local shared = waitForChildBounded(ReplicatedStorage, "FishingShared", 30, "FishingShared folder did not become ready")
if not shared:IsA("Folder") then error("FishingShared must be a Folder", 2) end
local Config = requireModule(shared, "Config")
local Layout = requireModule(shared, "WorldLayout")
local Location = requireModule(shared, "FishingLocation")
local Rules = requireModule(shared, "SailingRules")
local serverScript = waitForChildBounded(ServerScriptService, "FishingServer", 30, "FishingServer Script container did not become ready")
if not serverScript:IsA("Script") then error("FishingServer must be a Script container", 2) end
local BoatService = requireModule(serverScript, "BoatService")
local FishingService = requireModule(serverScript, "FishingService")

local function waitUntil(predicate, timeout, label)
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline do
		local ok, result = pcall(predicate)
		if ok and result then return true end
		task.wait(.1)
	end
	error(label or "condition timed out", 2)
end

local function expect(condition, message)
	if not condition then error(message, 2) end
end

local function getCorners(part)
	local half = part.Size * .5
	local corners = {}
	for _, sx in {-1, 1} do
		for _, sy in {-1, 1} do
			for _, sz in {-1, 1} do
				table.insert(corners, part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
			end
		end
	end
	return corners
end

local function hasPrefix(value, prefix)
	return string.sub(value, 1, #prefix) == prefix
end

local function waitForPlayer()
	local player = Players:GetPlayers()[1]
	if player then return player end
	local found = nil
	local connection = Players.PlayerAdded:Connect(function(candidate) found = candidate end)
	local ok, err = pcall(function()
		waitUntil(function() return found ~= nil end, 30, "player did not join sailing smoke")
	end)
	connection:Disconnect()
	if not ok then error(err, 2) end
	return found
end

local function waitForCharacter(player, timeout, label)
	waitUntil(function() return player.Character ~= nil end, timeout or 30, label or "character did not become ready")
	return player.Character
end

local function rayParams(exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filtered = {}
	for _, object in ipairs(exclude or {}) do if object then table.insert(filtered, object) end end
	params.FilterDescendantsInstances = filtered
	params.IgnoreWater = false
	params.RespectCanCollide = true
	return params
end

local function groundAt(x, z, y, extraExclude)
	local exclude = {workspace:FindFirstChild("SailingBoats")}
	for _, object in ipairs(extraExclude or {}) do table.insert(exclude, object) end
	return workspace:Raycast(Vector3.new(x, y or 45, z), Vector3.new(0, -100, 0), rayParams(exclude))
end

local function checkOceanFloor(world, ocean)
	local floorSamples = {
		{ocean.minX + 8, ocean.minZ + 8},
		{ocean.maxX - 8, ocean.minZ + 8},
		{ocean.minX + 8, ocean.maxZ - 8},
		{ocean.maxX - 8, ocean.maxZ - 8},
		{(ocean.minX + ocean.maxX) * .5, (ocean.minZ + ocean.maxZ) * .5},
	}
	local params = rayParams({workspace:FindFirstChild("SailingBoats")})
	params.IgnoreWater = true
	for _, sample in ipairs(floorSamples) do
		local hit = workspace:Raycast(Vector3.new(sample[1], ocean.surfaceY + 1, sample[2]), Vector3.new(0, -60, 0), params)
		expect(hit and hit.Instance and hasPrefix(hit.Instance.Name, "OceanFloor"),
			string.format("ocean floor coverage missing at %.0f,%.0f", sample[1], sample[2]))
	end
end

local function checkZoneGeometry(world, ocean)
	expect(#Config.Zones == 9, "SailingQA requires nine fishing zones")
	local seenShapes = {}
	for zoneId, zone in ipairs(Config.Zones) do
		local layout = Layout.Zones[zoneId]
		expect(layout and zone.center.x == layout.x and zone.center.z == layout.z,
			"Config center drift in zone " .. tostring(zoneId))
		expect(zone.shape == layout.shape and zone.width == layout.width and zone.depth == layout.depth,
			"Config layout metadata drift in zone " .. tostring(zoneId))
		expect(not seenShapes[layout.shape], "zone shapes must be distinct: " .. tostring(layout.shape))
		seenShapes[layout.shape] = true

		local folder = world:FindFirstChild("Zone" .. tostring(zoneId))
		expect(folder and folder:GetAttribute("ZoneShape") == layout.shape, "runtime shape missing in zone " .. tostring(zoneId))
		local landParts = {}
		local minX, minZ = math.huge, math.huge
		local maxX, maxZ = -math.huge, -math.huge
		for _, object in ipairs(folder:GetDescendants()) do
			if object:IsA("BasePart") and (object:GetAttribute("CollisionRole") == "WalkableIsland")
				and hasPrefix(object.Name, "Island") then
				table.insert(landParts, object)
				for _, corner in ipairs(getCorners(object)) do
					minX, maxX = math.min(minX, corner.X), math.max(maxX, corner.X)
					minZ, maxZ = math.min(minZ, corner.Z), math.max(maxZ, corner.Z)
					expect(corner.X >= ocean.minX and corner.X <= ocean.maxX
						and corner.Z >= ocean.minZ and corner.Z <= ocean.maxZ,
						"island footprint exceeds ocean bounds in zone " .. tostring(zoneId))
				end
			end
		end
		expect(#landParts >= 3, "zone needs multiple runtime land lobes: " .. tostring(zoneId))
		local spanX, spanZ = maxX - minX, maxZ - minZ
		expect(math.max(spanX, spanZ) >= 240, "island is not larger than the old radius-70 footprint in zone " .. tostring(zoneId))
		expect(spanX <= layout.width * 1.35 and spanZ <= layout.depth * 1.35,
			"runtime island footprint exceeds authored size in zone " .. tostring(zoneId))

		-- The dock-to-inland walk sample must have real collidable support all
		-- along the centerline; it catches a visual promenade disconnected from
		-- the old dock contract.
		for _, offset in ipairs({76, 68, 60, 52, 44, 36, 30, 25, 20, 10, 0, -6, -12, -20, -40, -60, -80}) do
			local hit = groundAt(zone.center.x, zone.center.z + offset, 45)
			expect(hit and hit.Instance and hit.Instance:IsDescendantOf(folder) and hit.Instance.CanCollide,
				"walkable dock-to-inland gap in zone " .. tostring(zoneId) .. " at z+" .. tostring(offset))
		end

		-- The fishing cast point is beyond the dock and must remain actual water.
		-- Use the same default RespectCanCollide=false query as the fishing client;
		-- the stricter ground query is retained in the diagnostic so a terrain
		-- streaming/voxel timing issue cannot be mistaken for an island blocker.
		local castOrigin = Vector3.new(zone.center.x, ocean.surfaceY + 31, zone.center.z + Location.Cast.zOffset)
		local castDirection = Vector3.new(0, -80, 0)
		local strictParams = rayParams({workspace:FindFirstChild("SailingBoats")})
		local waterParams = rayParams({workspace:FindFirstChild("SailingBoats")})
		waterParams.RespectCanCollide = false
		local castHit, strictHit
		local deadline = os.clock() + 5
		repeat
			castHit = workspace:Raycast(castOrigin, castDirection, waterParams)
			strictHit = workspace:Raycast(castOrigin, castDirection, strictParams)
			if castHit and castHit.Material == Enum.Material.Water then break end
			RunService.Heartbeat:Wait()
		until os.clock() >= deadline
		local function castDetail(hit)
			if not hit then return "hit=nil" end
			return string.format("hit=%s material=%s pos=(%.1f,%.1f,%.1f) canCollide=%s canQuery=%s",
				hit.Instance:GetFullName(), tostring(hit.Material), hit.Position.X, hit.Position.Y, hit.Position.Z,
				tostring(hit.Instance.CanCollide), tostring(hit.Instance.CanQuery))
		end
		expect(castHit and castHit.Material == Enum.Material.Water,
			"cast +82 is not water in zone " .. tostring(zoneId) .. " (default " .. castDetail(castHit)
				.. "; RespectCanCollide " .. castDetail(strictHit) .. ")")

		-- Boat hull clearance is tested as a box, not by checking a decorative
		-- spawn marker. A future lobe or rock must not seal the approach.
		local spawn = Vector3.new(zone.center.x, ocean.surfaceY + .7, zone.center.z + Rules.SpawnOffset)
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		-- Keep FishingWorld in the query. Excluding it would make this a marker
		-- existence check and would miss an island lobe accidentally sealing +92.
		overlap.FilterDescendantsInstances = {workspace:FindFirstChild("SailingBoats")}
		local blockers = workspace:GetPartBoundsInBox(CFrame.new(spawn), Vector3.new(13, 4, 24), overlap)
		for _, blocker in ipairs(blockers) do
			expect(not blocker.CanCollide, "boat spawn +92 is blocked by " .. blocker:GetFullName() .. " in zone " .. tostring(zoneId))
		end
	end
end

local function checkSpawnAndArrivalGround(world, player)
	waitUntil(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		return character and character:FindFirstChild("HumanoidRootPart") and humanoid and humanoid.Health > 0
	end, 30, "character did not become ready for arrival checks")
	local spawn = world:FindFirstChild("HarborSpawn")
	expect(spawn and spawn:IsA("SpawnLocation"), "HarborSpawn missing")
	local spawnHit = groundAt(spawn.Position.X, spawn.Position.Z, 45, {player.Character})
	expect(spawnHit and spawnHit.Instance and spawnHit.Instance.CanCollide and spawnHit.Position.Y > 2.5,
		"HarborSpawn has no walkable collidable ground")

	local first = Config.Zones[1].center
	local arrival = Location.travelPoint(first)
	player.Character:PivotTo(CFrame.new(arrival.x, arrival.y, arrival.z) * CFrame.Angles(0, math.pi, 0))
	local arrivalHit = groundAt(arrival.x, arrival.z, 45, {player.Character})
	expect(arrivalHit and arrivalHit.Instance and arrivalHit.Instance.CanCollide and arrivalHit.Position.Y > 2.5,
		"zone 1 arrival has no collidable dock support")
end

local function checkBoatLifecycle(player)
	local report = ReplicatedStorage:FindFirstChild("SailingSmokeReport")
	if not report then
		report = Instance.new("RemoteEvent")
		report.Name = "SailingSmokeReport"
		report.Parent = ReplicatedStorage
	end
	report.OnServerEvent:Connect(function(sender, payload)
		if sender ~= player or type(payload) ~= "table" then return end
		local kind = payload.kind
		if kind == "motion" then
			ReplicatedStorage:SetAttribute("SailingSmokeClientMotion", true)
		elseif kind == "done" then
			ReplicatedStorage:SetAttribute("SailingSmokeClientDone", true)
		elseif kind == "failed" then
			ReplicatedStorage:SetAttribute("SailingSmokeClientFailed", true)
		end
	end)
	local character = waitForCharacter(player, 30, "character did not become ready for sailing smoke")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	expect(humanoid and humanoid.Health > 0, "player humanoid unavailable for sailing smoke")
	local first = Config.Zones[1].center
	local inland = Vector3.new(first.x, Location.Travel.y, first.z + 25)
	character:PivotTo(CFrame.new(inland))
	BoatService.release(player, "qa preflight")
	local denied = BoatService.handle(player, "summon", {zone = 1})
	expect(not denied.ok, "summon must require physical dock authorization")

	local dock = Location.travelPoint(first)
	character:PivotTo(CFrame.new(dock.x, dock.y, dock.z) * CFrame.Angles(0, math.pi, 0))
	local summoned = BoatService.handle(player, "summon", {zone = 1})
	expect(summoned.ok, "free boat summon failed at dock")
	local state = BoatService.getState(player)
	expect(state and state.model and state.root and state.seat, "BoatService state missing runtime hull/seat")
	waitUntil(function() return state.driver == true and state.seat.Occupant == humanoid end, 5, "boat did not board player")
	local modelBefore = state.model
	ReplicatedStorage:SetAttribute("SailingSmokeServerReady", true)

	waitUntil(function()
		return ReplicatedStorage:GetAttribute("SailingSmokeClientDone") == true
			or ReplicatedStorage:GetAttribute("SailingSmokeClientFailed") == true
	end, 180, "client sailing motion smoke did not finish")
	expect(ReplicatedStorage:GetAttribute("SailingSmokeClientFailed") ~= true, "client sailing motion smoke failed")
	expect(ReplicatedStorage:GetAttribute("SailingSmokeClientMotion") == true,
		"client did not report a real BoatRemotes.Intent motion phase")

	-- The client has exercised actual BoatRemotes.Intent and returned to harbor.
	expect(BoatService.getState(player) == nil, "returnHarbor must destroy the active boat")
	expect(not modelBefore.Parent, "returnHarbor left the boat model alive")

	-- Physical travel can reach a locked dock, but it must not grant a fishing
	-- round. This keeps boat exploration separate from species/zone authority.
	local profile = FishingService.getProfile(player)
	expect(profile, "Studio profile unavailable for unlock guard")
	local savedZone = profile.zone
	profile.zone = 1
	local locked = Config.Zones[2].center
	local lockedPoint = Location.travelPoint(locked)
	character = waitForCharacter(player, 30, "character did not become ready for locked dock check")
	character:PivotTo(CFrame.new(lockedPoint.x, lockedPoint.y, lockedPoint.z) * CFrame.Angles(0, math.pi, 0))
	local fishAttempt = FishingService.handle(player, "toggleFishing", {})
	expect(not fishAttempt.ok, "boat arrival must not bypass fishing unlock")
	profile.zone = savedZone

	-- Exercise the public cleanup seam after a second real summon. This is also
	-- the deterministic fallback for QA teardown if Studio respawn timing varies.
	local harbor = Location.travelPoint(first)
	character:PivotTo(CFrame.new(harbor.x, harbor.y, harbor.z) * CFrame.Angles(0, math.pi, 0))
	local second = BoatService.handle(player, "summon", {zone = 1})
	expect(second.ok, "second boat summon failed after return")
	local secondState = BoatService.getState(player)
	expect(secondState and secondState.model, "second boat state missing")
	waitUntil(function() return secondState.driver == true end, 5, "second boat never attached its driver")
	local traveled = FishingService.handle(player, "travel", {zone = 1})
	expect(traveled.ok, "quick travel from a seated boat failed")
	waitUntil(function() return BoatService.getState(player) == nil end, 3, "boat cleanup did not clear state")
	expect(not secondState.model.Parent, "BoatService.release left model in workspace")
	task.wait(.6)
	local travelRoot = character:FindFirstChild("HumanoidRootPart")
	expect(travelRoot and Rules.distance2D(travelRoot.Position.X, travelRoot.Position.Z, harbor.x, harbor.z) < 10,
		"quick travel was overwritten by the detached seat pose")
	local third = BoatService.handle(player, "summon", {zone = 1})
	expect(third.ok, "aquarium regression boat summon failed")
	local thirdState = BoatService.getState(player)
	waitUntil(function() return thirdState and thirdState.driver == true end, 5, "aquarium regression seat did not attach")
	local visited = FishingService.handle(player, "visitAquarium", {})
	expect(visited.ok and BoatService.getState(player) == nil and not thirdState.model.Parent,
		"aquarium visit failed to release seated boat")
	task.wait(.6)
	expect(travelRoot.Position.X < -70, "aquarium arrival was overwritten by the detached seat pose")
	expect(FishingService.handle(player, "travel", {zone = 1}).ok, "QA could not return to harbor after aquarium check")

	print("SAILING_SERVER_MAP_PASS: 9 runtime footprints, walkable dock-to-inland samples, cast+82 water, ocean floor, boat spawn clearance")
	print("SAILING_SERVER_AUTH_PASS: inland summon rejected, real RemoteIntent client motion/turn/follow/leave/reboard/return observed, fishing unlock preserved")
	print("SAILING_SERVER_CLEANUP_PASS: returnHarbor, seated quick travel and aquarium visit remove boat state/model and preserve arrival")
end

local ok, err = xpcall(function()
	local world = workspace:WaitForChild("FishingWorld", 45)
	expect(world, "FishingWorld was not created")
	waitUntil(function() return world:GetAttribute("Ready") == true end, 45, "FishingWorld did not become ready")
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	local ocean = Layout.Ocean
	expect(world:GetAttribute("OceanMinX") == ocean.minX and world:GetAttribute("OceanMaxX") == ocean.maxX
		and world:GetAttribute("OceanMinZ") == ocean.minZ and world:GetAttribute("OceanMaxZ") == ocean.maxZ,
		"runtime ocean attributes drift from WorldLayout")
	checkOceanFloor(world, ocean)
	checkZoneGeometry(world, ocean)
	local player = waitForPlayer()
	waitUntil(function() return FishingService.getProfile(player) ~= nil end, 30, "Fishing profile did not load")
	checkSpawnAndArrivalGround(world, player)
	checkBoatLifecycle(player)
	ReplicatedStorage:SetAttribute("SailingSmokeServerReady", true)
	ReplicatedStorage:SetAttribute("SailingSmokeServerDone", true)
end, debug.traceback)

if not ok then
	ReplicatedStorage:SetAttribute("SailingSmokeServerFailed", true)
	warn("SAILING_SERVER_FAIL: " .. tostring(err))
else
	print("SAILING_SERVER_PASS")
end
