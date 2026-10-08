-- Real-engine QA for the four native Quaternius Nature templates and their
-- first Zone 1 presentation slice. This is read-only: it inspects the world
-- built by IslandBuilder and never creates or replaces scene instances.
--
-- EXECUTION CONTEXT: paste this source into the already-reviewed Studio Play
-- Server Command Bar, with the required command-bar permission, after the
-- world has been built. Do not map it as a formal ordinary ServerScript.
-- In an ordinary runtime ServerScript, reading a public
-- SurfaceAppearance.ColorMap may be rejected with "lacking Plugin"; that is
-- an execution-context limitation, not a product-resource failure. Keep the
-- assertions below intact and do not replace this check with hidden
-- TexturePack access or a permission bypass.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EXPECTED = {
	{key = "PlantFlowers", role = "author_supplemental_plant"},
	{key = "Bush", role = "author_nearshore_bush_replacing_coastal_shrub"},
	{key = "FlowerClump", role = "author_flower_clump"},
	{key = "GrassSmall", role = "author_grass_small"},
}
local ALPHA = {PlantFlowers = true, Bush = true, FlowerClump = true}

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

local function boundsXZ(model)
	local boxCFrame, size = model:GetBoundingBox()
	local half = size * .5
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, sx in {-1, 1} do
		for _, sy in {-1, 1} do
			for _, sz in {-1, 1} do
				local point = (boxCFrame * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)).Position
				minX = math.min(minX, point.X); maxX = math.max(maxX, point.X)
				minZ = math.min(minZ, point.Z); maxZ = math.max(maxZ, point.Z)
			end
		end
	end
	return {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
end

local function overlaps(a, minX, maxX, minZ, maxZ, margin)
	return a.maxX >= minX - margin and a.minX <= maxX + margin
		and a.maxZ >= minZ - margin and a.minZ <= maxZ + margin
end

local function supportAt(zone, x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {zone}
	params.RespectCanCollide = true
	params.IgnoreWater = false
	local result = workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -160, 0), params)
	return result and result.Instance:IsA("BasePart") and result.Instance.CanCollide
		and result.Instance:GetAttribute("CollisionRole") == "WalkableIsland"
		and result.Material ~= Enum.Material.Water and result
end

local function fourPointSupport(zone, bounds)
	local samples = {
		{(bounds.minX + bounds.maxX) * .5, (bounds.minZ + bounds.maxZ) * .5},
		{bounds.minX, bounds.minZ}, {bounds.minX, bounds.maxZ},
		{bounds.maxX, bounds.minZ}, {bounds.maxX, bounds.maxZ},
	}
	for _, sample in ipairs(samples) do
		expect(supportAt(zone, sample[1], sample[2]), "NatureArt lacks collidable four-point Zone 1 support")
	end
	return true
end

local function inspectTemplate(library, entry)
	local template = library:FindFirstChild(entry.key)
	expect(template and template:IsA("Model"), "missing native NatureArt model " .. entry.key)
	local meshCount, textureCount, surfaceCount = 0, 0, 0
	for _, object in ipairs(template:GetDescendants()) do
		if object:IsA("MeshPart") then
			meshCount += 1
			expect(object.MeshId ~= "", entry.key .. " MeshId missing")
			expect(object.TextureID ~= "", entry.key .. " public TextureID missing")
			textureCount += 1
			expect(object.DoubleSided == true, entry.key .. " must be public DoubleSided=true")
			expect(object.Transparency == 0, entry.key .. " must be public Transparency=0")
		elseif object:IsA("SurfaceAppearance") then
			surfaceCount += 1
		end
	end
	expect(meshCount == 1, entry.key .. " must have one native MeshPart")
	expect(textureCount == 1, entry.key .. " must have one public texture reference")
	if ALPHA[entry.key] then
		expect(surfaceCount == 1, entry.key .. " alpha material must have one SurfaceAppearance")
		local mesh = template:FindFirstChildWhichIsA("MeshPart", true)
		local surface = template:FindFirstChildWhichIsA("SurfaceAppearance", true)
		expect(surface.AlphaMode == Enum.AlphaMode.Transparency, entry.key .. " AlphaMode mismatch")
		expect(surface.ColorMap == mesh.TextureID, entry.key .. " ColorMap must equal public TextureID")
	else
		expect(surfaceCount == 0, "GrassSmall must keep the opaque no-SurfaceAppearance policy")
	end
	return template
end

local function run()
	local world = workspace:WaitForChild("FishingWorld", 45)
	expect(world and waitUntil(function() return world:GetAttribute("Ready") == true end, 45),
		"FishingWorld did not become Ready")
	local library = ReplicatedStorage:WaitForChild("NatureArt", 10)
	expect(library and library:IsA("Folder"), "ReplicatedStorage.NatureArt missing")
	local shared = ReplicatedStorage:WaitForChild("FishingShared", 10)
	local ArtCatalog = require(shared:WaitForChild("ArtCatalog"))
	local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
	local zone = world:WaitForChild("Zone1", 10)
	local cluster = zone:WaitForChild("SceneryCluster_02", 10)
	expect(cluster:FindFirstChild("WayfindingStone"), "WayfindingStone navigation landmark was removed")
	expect(cluster:FindFirstChild("PathMarker"), "PathMarker navigation landmark was removed")
	expect(not cluster:FindFirstChild("CoastalShrub"), "Zone 1 CoastalShrub visual was not replaced")

	local zoneX, zoneZ = 0, 0
	local route = {minX = zoneX - 30, maxX = zoneX - 14, minZ = zoneZ + 3, maxZ = zoneZ + 15}
	local gate = {minX = zoneX - 10.5, maxX = zoneX + 10.5, minZ = zoneZ + 13, maxZ = zoneZ + 17}
	local found = 0
	for _, entry in ipairs(EXPECTED) do
		expect(ArtCatalog.NatureArt[entry.key] == entry.key, "ArtCatalog NatureArt mapping changed: " .. entry.key)
		local template = inspectTemplate(library, entry)
		expect(ArtRenderer.natureTemplate(entry.key) == template, "ArtRenderer NatureArt lookup mismatch: " .. entry.key)
		local model = cluster:FindFirstChild("Nature_" .. entry.key)
		expect(model and model:IsA("Model"), "missing placed NatureArt model " .. entry.key)
		expect(model:GetAttribute("SourcePackage") == "Quaternius Ultimate Stylized Nature", entry.key .. " source package missing")
		expect(model:GetAttribute("NatureRole") == entry.key, entry.key .. " NatureRole missing")
		expect(model:GetAttribute("SceneryRole") == entry.role, entry.key .. " scenery role missing")
		for _, object in ipairs(model:GetDescendants()) do
			if object:IsA("BasePart") then
				expect(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery,
					entry.key .. " presentation parts must be inert")
			end
		end
		local bounds = boundsXZ(model)
		expect(not overlaps(bounds, route.minX, route.maxX, route.minZ, route.maxZ, .25), entry.key .. " overlaps NPC route")
		expect(not overlaps(bounds, gate.minX, gate.maxX, gate.minZ, gate.maxZ, .25), entry.key .. " overlaps gate reserve")
		expect(bounds.maxZ < zoneZ + 30, entry.key .. " enters dock channel")
		fourPointSupport(zone, bounds)
		found += 1
	end
	expect(found == #EXPECTED, "not all four NatureArt models were placed")
	ReplicatedStorage:SetAttribute("NatureArtSmokePass", true)
	print("NATURE_ART_SMOKE_PASS", "native templates, public material adaptation, four-point support and route clearance", "assets", found)
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	ReplicatedStorage:SetAttribute("NatureArtSmokePass", false)
	warn("NATURE_ART_SMOKE_FAIL: " .. tostring(err))
end
