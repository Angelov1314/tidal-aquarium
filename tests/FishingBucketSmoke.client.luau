-- QA project only. Verifies the imported bucket is placed once beside every
-- dock, including the four ThemeContent zones.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local world = workspace:WaitForChild("FishingWorld", 30)
assert(world, "FishingWorld did not build")
local expectedZoneCount = 9
assert(#Config.Zones == expectedZoneCount, "Zone count changed: " .. tostring(#Config.Zones))
assert(ArtRenderer.template("FishingBucket"), "FishingBucket template missing")

local found = 0
local preloadInstances = {}
local preloadSeen = {}
local expectedAssets = {}
local expectedKinds = { mesh = 0, texture = 0 }

local function numericAssetId(value)
	local text = tostring(value)
	return string.match(text, "[?&]id=(%d+)")
		or string.match(text, "rbxassetid://(%d+)")
		or string.match(text, "^%s*(%d+)%s*$")
		or string.match(text, "/(%d+)[/?#]")
		or string.match(text, "/(%d+)$")
end

local function expectAsset(kind, rawValue)
	local numericId = numericAssetId(rawValue)
	assert(numericId, "FishingBucket " .. kind .. " ID is not numeric: " .. tostring(rawValue))
	local expected = expectedAssets[numericId]
	if not expected then
		expected = { raw = tostring(rawValue), mesh = false, texture = false }
		expectedAssets[numericId] = expected
	end
	if not expected[kind] then
		expected[kind] = true
		expectedKinds[kind] += 1
	end
end

for zoneIndex, zoneConfig in ipairs(Config.Zones) do

	local zone = world:WaitForChild("Zone" .. zoneIndex, 10)
	assert(zone, "Zone missing: " .. zoneIndex)
	local bucket = zone:FindFirstChild("FishingBucket")
	assert(bucket and bucket:IsA("Model"), "FishingBucket missing in zone " .. zoneIndex)
	found += 1

	local expected = Vector3.new(zoneConfig.center.x + 6.2, 4.9, zoneConfig.center.z + 72)
	local pivot = bucket:GetPivot().Position
	assert((pivot - expected).Magnitude < .05, "FishingBucket pivot misplaced in zone " .. zoneIndex)
	local extents = bucket:GetExtentsSize()
	local largest = math.max(extents.X, extents.Y, extents.Z)
	assert(math.abs(largest - 1.8) < .03, "FishingBucket scale invalid in zone " .. zoneIndex)
	assert(math.abs(pivot.Y - extents.Y / 2 - 4.0) < .05, "FishingBucket base is off dock top in zone " .. zoneIndex)

	local meshes = 0
	for _, object in bucket:GetDescendants() do

		if object:IsA("MeshPart") then
			meshes += 1
			assert(object.MeshId ~= "", "FishingBucket mesh missing in zone " .. zoneIndex)
			assert(object.TextureID ~= "", "FishingBucket texture missing in zone " .. zoneIndex)
			if not preloadSeen[object] then
				preloadSeen[object] = true
				table.insert(preloadInstances, object)
			end
			expectAsset("mesh", object.MeshId)
			expectAsset("texture", object.TextureID)
		end
		if object:IsA("BasePart") then
			assert(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery,
				"FishingBucket collision flags unsafe in zone " .. zoneIndex)
		end
	end
	assert(meshes > 0, "FishingBucket has no mesh geometry in zone " .. zoneIndex)
end

assert(found == #Config.Zones, "Expected one FishingBucket per zone")
assert(#preloadInstances > 0, "FishingBucket has no MeshPart instances to preload")
assert(expectedKinds.mesh > 0, "FishingBucket has no expected mesh ID")
assert(expectedKinds.texture > 0, "FishingBucket has no expected texture ID")

local callbackStatus = {}
local callbackRaw = {}
local callbackCount = 0
ContentProvider:PreloadAsync(preloadInstances, function(assetId, status)
	local rawAssetId = tostring(assetId)
	local numericId = numericAssetId(rawAssetId)
	assert(numericId, "FishingBucket preload callback returned a non-numeric asset ID: " .. rawAssetId)
	assert(expectedAssets[numericId], "FishingBucket preload callback returned an unexpected asset: " .. rawAssetId)
	assert(status == Enum.AssetFetchStatus.Success, "FishingBucket asset failed to load: " .. rawAssetId .. " (" .. tostring(status) .. ")")
	callbackStatus[numericId] = status
	callbackRaw[numericId] = rawAssetId
	callbackCount += 1
end)
local expectedCount = 0
for numericId, expected in pairs(expectedAssets) do
	expectedCount += 1
	assert(callbackStatus[numericId] == Enum.AssetFetchStatus.Success,
		"FishingBucket " .. (expected.mesh and "mesh" or "texture") .. " asset had no successful fetch callback: " .. expected.raw
			.. " (callback=" .. tostring(callbackRaw[numericId]) .. ")")
end
assert(callbackCount >= expectedCount, "FishingBucket preload callback count was incomplete")
print("FISHING_BUCKET_PASS: " .. found .. "/" .. tostring(expectedZoneCount) .. " dock buckets loaded, scaled, grounded, textured, and non-colliding")
