-- QA project only. Verifies all imported prop contracts, nine-zone placement,
-- real mesh/texture fetches, and held-rod cleanup.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local Catalog = require(shared:WaitForChild("ArtCatalog"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local world = workspace:WaitForChild("FishingWorld", 30)
assert(world, "FishingWorld did not build")
local expectedZoneCount = 9
assert(#Config.Zones == expectedZoneCount, "Zone count changed: " .. tostring(#Config.Zones))

local expectedAssets = {}
local expectedKinds = {mesh = 0, texture = 0}
local preloadInstances = {}
local preloadSeen = {}

local function numericAssetId(value)
	local text = tostring(value)
	return string.match(text, "[?&]id=(%d+)")
		or string.match(text, "rbxassetid://(%d+)")
		or string.match(text, "^%s*(%d+)%s*$")
		or string.match(text, "/(%d+)[/?#]")
		or string.match(text, "/(%d+)$")
end

local function expectAsset(kind, rawValue, context)
	local numericId = numericAssetId(rawValue)
	assert(numericId, context .. " " .. kind .. " ID is not numeric: " .. tostring(rawValue))
	local expected = expectedAssets[numericId]
	if not expected then
		expected = {raw = tostring(rawValue), mesh = false, texture = false}
		expectedAssets[numericId] = expected
	end
	if not expected[kind] then
		expected[kind] = true
		expectedKinds[kind] += 1
	end
end

local function collectMeshPart(object, context)
	assert(object.MeshId ~= "", context .. " missing mesh ID")
	expectAsset("mesh", object.MeshId, context)
	local texture = object.TextureID
	if texture == "" then
		local appearance = object:FindFirstChildWhichIsA("SurfaceAppearance")
		texture = appearance and appearance.ColorMap or ""
	end
	assert(texture ~= "", context .. " missing texture ID or ColorMap")
	expectAsset("texture", texture, context)
	if not preloadSeen[object] then
		preloadSeen[object] = true
		table.insert(preloadInstances, object)
	end
end

local function inspectMeshes(container, context)
	local count = 0
	for _, object in container:GetDescendants() do
		if object:IsA("MeshPart") then
			count += 1
			collectMeshPart(object, context)
		end
	end
	assert(count > 0, context .. " has no MeshPart geometry")
	return count
end

local templateNames = {}
for alias, name in Catalog.Props do templateNames[alias] = name end
for alias, name in templateNames do
	assert(name == alias, "Catalog alias changed for " .. alias)
	local template = assert(ArtRenderer.template(name), "Missing fishing prop template: " .. name)
	inspectMeshes(template, name .. " template")
	if alias == "FishingRod" then
		local artPivot = template:FindFirstChild("ArtPivot", true)
		local grip = artPivot and artPivot:FindFirstChild("RodGrip")
		local tip = artPivot and artPivot:FindFirstChild("RodTip")
		assert(grip and grip:IsA("Attachment"), "FishingRod ArtPivot.RodGrip attachment missing")
		assert(tip and tip:IsA("Attachment"), "FishingRod ArtPivot.RodTip attachment missing")
	end
end

local function bounds(container)
	local boxCFrame, size = container:GetBoundingBox()
	local half = size * .5
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, x in {-half.X, half.X} do
		for _, y in {-half.Y, half.Y} do
			for _, z in {-half.Z, half.Z} do
				local point = (boxCFrame * CFrame.new(x, y, z)).Position
				minX, maxX = math.min(minX, point.X), math.max(maxX, point.X)
				minY, maxY = math.min(minY, point.Y), math.max(maxY, point.Y)
				minZ, maxZ = math.min(minZ, point.Z), math.max(maxZ, point.Z)
			end
		end
	end
	return minX, maxX, minY, maxY, minZ, maxZ
end

local function inspectStatic(model, expectedX, groundY, context, zCenter)
	assert(model and model:IsA("Model"), context .. " model missing")
	local pivot = model:GetPivot().Position
	assert(math.abs(pivot.X - expectedX) < .08, context .. " x placement changed")
	local minX, maxX, minY = bounds(model)
	assert(math.abs(minY - groundY) < .08, context .. " ground contact changed")
	local extents = model:GetExtentsSize()
	assert(math.max(extents.X, extents.Y, extents.Z) <= 4.03, context .. " exceeds static target size")
	if zCenter then assert(math.abs(pivot.Z - zCenter) < .08, context .. " z placement changed") end
	for _, object in model:GetDescendants() do
		if object:IsA("BasePart") then
			assert(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery,
				context .. " collision flags unsafe")
		end
		if object:IsA("MeshPart") then collectMeshPart(object, context) end
	end
	return minX, maxX
end

local staticCount = 0
for zoneIndex, zoneConfig in ipairs(Config.Zones) do
	local zone = world:WaitForChild("Zone" .. zoneIndex, 10)
	assert(zone, "Zone missing: " .. zoneIndex)
	local rack = zone:FindFirstChild("RodRack")
	local board = zone:FindFirstChild("LureDisplayBoard")
	assert(rack and board, "Rack/board pair missing in zone " .. zoneIndex)
	local rackCount, boardCount = 0, 0
	for _, child in zone:GetChildren() do
		if child.Name == "RodRack" then rackCount += 1 end
		if child.Name == "LureDisplayBoard" then boardCount += 1 end
	end
	assert(rackCount == 1 and boardCount == 1, "Expected one rack and board in zone " .. zoneIndex)
	local rackMinX, rackMaxX = inspectStatic(rack, zoneConfig.center.x + 5.5, 4, "RodRack zone " .. zoneIndex, zoneConfig.center.z + 45)
	assert(rackMinX >= zoneConfig.center.x - 8.05 and rackMaxX <= zoneConfig.center.x + 8.05,
		"RodRack leaves dock width in zone " .. zoneIndex)
	assert(rackMinX >= zoneConfig.center.x + 3 - .05, "RodRack blocks central dock path in zone " .. zoneIndex)
	local _, boardMaxX = inspectStatic(board, zoneConfig.center.x - 22, 4.9,
		"LureDisplayBoard zone " .. zoneIndex, zoneConfig.center.z + 19.8)
	assert(boardMaxX < zoneConfig.center.x - 3, "LureDisplayBoard blocks central path in zone " .. zoneIndex)
	assert(zone:FindFirstChild("FishingBucket"), "Existing bucket missing in zone " .. zoneIndex)
	staticCount += 2
end
assert(staticCount == #Config.Zones * 2, "Expected one rack and board per zone")

local avatar = Instance.new("Model")
avatar.Name = "FishingPropsArtSmokeAvatar"
-- Keep the synthetic fixture out of Workspace physics while still checking
-- that the helper never changes an initially unanchored character root.
avatar.Parent = ReplicatedStorage
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.Position = Vector3.new(0, 30, 0)
root.Anchored = false
root.Massless = true
root.CanCollide = false
root.Parent = avatar
local hand = Instance.new("Part")
hand.Name = "RightHand"
hand.Size = Vector3.new(.4, .8, .4)
hand.Position = Vector3.new(1, 30, 0)
hand.Anchored = false
hand.Massless = true
hand.CanCollide = false
hand.Parent = avatar

local function inspectHeld(handle, context, collectAssets)
	assert(handle and handle.model and handle.model.Parent == avatar, context .. " model missing")
	assert(handle.tip and handle.tip:IsA("Attachment"), context .. " real tip attachment missing")
	local artPivot = handle.model:FindFirstChild("ArtPivot", true)
	local grip = artPivot and artPivot:FindFirstChild("RodGrip")
	local authoredTip = artPivot and artPivot:FindFirstChild("RodTip")
	assert(grip and grip:IsA("Attachment") and authoredTip and authoredTip:IsA("Attachment"), context .. " authored rod endpoints missing")
	assert((grip.WorldPosition - hand.Position).Magnitude < .02, context .. " grip endpoint misses hand")
	assert((handle.tip.WorldPosition - authoredTip.WorldPosition).Magnitude < .02, context .. " tip attachment endpoint changed")
	local handJointFound = false
	local primary = handle.model.PrimaryPart
	assert(primary and primary:IsA("BasePart"), context .. " held primary part missing")
	for _, object in handle.model:GetDescendants() do
		if object:IsA("BasePart") then
			assert(not object.Anchored and object.Massless and not object.CanCollide and not object.CanTouch and not object.CanQuery,
				context .. " held part state unsafe")
			if object:IsA("MeshPart") and collectAssets ~= false then collectMeshPart(object, context) end
		end
		if (object:IsA("Weld") or object:IsA("Motor6D")) and object.Name == "FishingRodHandWeld" then
			assert(object.Part0 == hand and object.Part1 == primary, context .. " hand joint endpoints changed")
			handJointFound = true
		end
	end
	assert(handJointFound, context .. " hand presentation joint missing")
	assert(not root.Anchored, context .. " changed character root anchor")
end

local first = assert(ArtRenderer.heldRod(avatar, hand, hand.CFrame, 3.5), "First held rod attach failed")
inspectHeld(first, "first held rod", false)
first.cleanup()
first.cleanup()
assert(first.model.Parent == nil, "First held rod cleanup leaked model")

local second = assert(ArtRenderer.heldRod(avatar, hand, hand.CFrame, 3.5), "Repeat held rod attach failed")
inspectHeld(second, "repeat held rod")

local respawnAvatar = Instance.new("Model")
respawnAvatar.Name = "FishingPropsArtSmokeRespawn"
respawnAvatar.Parent = ReplicatedStorage
local respawnHand = hand:Clone()
respawnHand.Name = "RightHand"
respawnHand.Parent = respawnAvatar
local respawnRod = assert(ArtRenderer.heldRod(respawnAvatar, respawnHand, respawnHand.CFrame, 3.5), "Respawn held rod attach failed")
local respawnModel = respawnRod.model
respawnAvatar:Destroy()
respawnRod.cleanup()
respawnRod.cleanup()
assert(respawnModel.Parent == nil, "Respawn cleanup leaked rod model")

local callbackStatus = {}
local callbackCount = 0
local callbackErrors = {}
assert(expectedKinds.mesh > 0 and expectedKinds.texture > 0, "No real mesh/texture assets collected")
ContentProvider:PreloadAsync(preloadInstances, function(assetId, status)
	local rawAssetId = tostring(assetId)
	local numericId = numericAssetId(rawAssetId)
	callbackCount += 1
	if not numericId then
		table.insert(callbackErrors, "non-numeric ID: " .. rawAssetId)
		return
	end
	if not expectedAssets[numericId] then
		table.insert(callbackErrors, "unexpected ID: " .. rawAssetId)
		return
	end
	if status ~= Enum.AssetFetchStatus.Success then
		table.insert(callbackErrors, "fetch failed: " .. rawAssetId .. " (" .. tostring(status) .. ")")
		return
	end
	callbackStatus[numericId] = status
end)
assert(#callbackErrors == 0, "Fishing prop preload callback errors: " .. table.concat(callbackErrors, " | "))
local expectedCount = 0
for numericId, expected in pairs(expectedAssets) do
	expectedCount += 1
	assert(callbackStatus[numericId] == Enum.AssetFetchStatus.Success,
		"Fishing prop asset had no successful callback: " .. expected.raw)
end
assert(callbackCount >= expectedCount, "Fishing prop preload callbacks incomplete")

second.cleanup()
assert(second.model.Parent == nil, "Repeat held rod cleanup leaked model")
avatar:Destroy()
local propCount = 0
for _ in templateNames do propCount += 1 end
print("FISHING_PROPS_PASS: " .. propCount .. " templates; " .. staticCount .. " static rack/board placements across " .. tostring(expectedZoneCount) .. " zones; real mesh/texture assets preloaded; held rod repeat/respawn cleanup passed")
