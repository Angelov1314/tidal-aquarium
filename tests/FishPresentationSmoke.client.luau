-- QA project only. Verifies the shared fish visual contract used by catches,
-- bag/detail cards and the discovered index.  This script is the sole UI
-- presentation smoke in fishshoreqa.project.json; UIRepairSmoke is excluded
-- so both tests never rebuild or drive the same PlayerGui in one Play session.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local ArtCatalog = require(shared:WaitForChild("ArtCatalog"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local FishingLocation = require(shared:WaitForChild("FishingLocation"))
local ThemeContent = require(shared:WaitForChild("ThemeContent"))
local smokeStartedAt = os.clock()
-- Keep the QA harness below Studio's one-minute Play budget while allowing a
-- cold Creator asset cache enough time to report every requested asset.
local smokeDeadline = smokeStartedAt + 58

local SNAPSHOT_RPC_TIMEOUT = 4
local SNAPSHOT_SPACING = 0.16

local function invokeSnapshotBounded(request, payload, deadline)
	if os.clock() >= deadline then return false, nil, "timeout" end
	local finished = false
	local callOk = false
	local response = nil
	local abandoned = false
	task.spawn(function()
		if abandoned or os.clock() >= deadline then
			abandoned = true
			return
		end
		local ok, result = pcall(function() return request:InvokeServer("snapshot", payload) end)
		if abandoned or os.clock() >= deadline then
			abandoned = true
			return
		end
		callOk, response, finished = ok, result, true
	end)
	while not finished and os.clock() < deadline do RunService.Heartbeat:Wait() end
	if os.clock() >= deadline then
		abandoned = true
		return false, nil, "timeout"
	end
	if not finished then
		abandoned = true
		return false, nil, "timeout"
	end
	if not callOk then return false, nil, "transport" end
	return true, response, nil
end

local function readSnapshotBounded(request, outerDeadline)
	local overallDeadline = outerDeadline or (os.clock() + SNAPSHOT_RPC_TIMEOUT * 2 + SNAPSHOT_SPACING + 0.1)
	local prepareOk, prepared, prepareFailure = invokeSnapshotBounded(request, {prepareHandshake = true}, math.min(overallDeadline, os.clock() + SNAPSHOT_RPC_TIMEOUT))
	if not prepareOk then return nil, prepareFailure == "timeout" and "prepare-timeout" or "prepare-transport" end
	if type(prepared) ~= "table" or prepared.ok ~= true or prepared.prepareHandshake ~= true then return nil, "prepare-rejected" end
	local epoch = prepared.stateEpoch
	if type(epoch) ~= "string" or #epoch == 0 then return nil, "epoch-missing" end
	local spacingDeadline = os.clock() + SNAPSHOT_SPACING
	while os.clock() < spacingDeadline do
		if os.clock() >= overallDeadline then return nil, "snapshot-timeout" end
		RunService.Heartbeat:Wait()
	end
	if os.clock() >= overallDeadline then return nil, "snapshot-timeout" end
	local snapshotOk, snapshotResponse, snapshotFailure = invokeSnapshotBounded(request, {stateEpoch = epoch}, math.min(overallDeadline, os.clock() + SNAPSHOT_RPC_TIMEOUT))
	if not snapshotOk then return nil, snapshotFailure == "timeout" and "snapshot-timeout" or "snapshot-transport" end
	if type(snapshotResponse) ~= "table" or snapshotResponse.ok ~= true or type(snapshotResponse.state) ~= "table" then return nil, "snapshot-rejected" end
	local state = snapshotResponse.state
	if state.stateEpoch ~= epoch then return nil, "epoch-mismatch" end
	return state, nil
end

local expectedSpeciesCount = 70
local expectedZoneCount = 9
local expectedFishTemplateCount = 74
assert(#Config.Species == expectedSpeciesCount, "Species count changed: " .. tostring(#Config.Species))
assert(#Config.Zones == expectedZoneCount, "Zone count changed: " .. tostring(#Config.Zones))

-- The library itself is the authoritative imported-template inventory.  The
-- species and theme maps below still prove every gameplay record resolves to
-- its authored ArtCatalog/ThemeContent template, while this inventory also
-- covers the 15 library-only source meshes.
local propNames = {}
for _, name in ArtCatalog.Props do propNames[name] = true end
local importedTemplates = {}
local importedTemplateSet = {}
local function addImportedTemplate(name: any, context: string)
	assert(type(name) == "string" and name ~= "", context .. " has no template mapping")
	if not importedTemplateSet[name] then
		importedTemplateSet[name] = true
		table.insert(importedTemplates, name)
	end
end

local library = ReplicatedStorage:WaitForChild("FishingArt")
for _, child in library:GetChildren() do
	if child:IsA("Model") and not propNames[child.Name] then addImportedTemplate(child.Name, "FishingArt " .. child.Name) end
end
for _, species in Config.Species do
	local template = ArtCatalog.Fish[species.id]
	assert(template and ArtRenderer.template(template), "Species template missing: " .. species.id)
	addImportedTemplate(template, "Species " .. species.id)
end
for _, species in ThemeContent.Species do
	local template = ArtCatalog.Fish[species.id]
	assert(template == species.template, "Theme template mapping changed: " .. species.id)
	assert(ArtRenderer.template(template), "Theme template missing: " .. species.id)
	addImportedTemplate(template, "Theme " .. species.id)
end
table.sort(importedTemplates)
assert(#importedTemplates == expectedFishTemplateCount,
	"Fish template count changed: " .. tostring(#importedTemplates))
local preloadInstances = {}
local preloadSeen = {}
local preloadAssetIds = {}
local preloadStatuses = {}
local preloadStatusText = {}
local preloadStartedAt = 0
local preloadDeadline = 0
local function assetKey(value)
	local text = tostring(value)
	return string.match(text, "%d+") or text
end
local function rememberAsset(value, templateName)
	local text = tostring(value)
	if text ~= "" then preloadAssetIds[assetKey(text)] = templateName end
end

for _, name in importedTemplates do
	local template = assert(ArtRenderer.template(name), "Imported fish template missing: " .. name)
	local meshCount = 0
	local textured = false
	for _, object in template:GetDescendants() do
		if object:IsA("MeshPart") then
			meshCount += 1
			assert(object.MeshId ~= "", name .. " has an empty MeshId")
			rememberAsset(object.MeshId, name)
			if object.TextureID ~= "" then rememberAsset(object.TextureID, name) end
			if object.TextureID ~= "" then textured = true end
			if not preloadSeen[object] then
				preloadSeen[object] = true
				table.insert(preloadInstances, object)
			end
		end
		if object:IsA("SurfaceAppearance") then
			if object.ColorMap ~= "" then
				rememberAsset(object.ColorMap, name)
				textured = true
			end
			if not preloadSeen[object] then
				preloadSeen[object] = true
				table.insert(preloadInstances, object)
			end
		end
	end
	assert(meshCount > 0 and textured, name .. " is not a textured imported fish")
end

-- PreloadAsync is deliberately isolated in a spawned task. Creator asset
-- fetches can be cold on a new Studio process, so the absolute per-run budget
-- is 45 seconds. The smoke continues its server/UI checks while this task
-- reports one status callback per requested asset; the final gate still
-- requires every expected callback to be Success.
assert(#preloadInstances > 0 and next(preloadAssetIds) ~= nil, "imported fish has no preloadable assets")
local preloadDone = false
local preloadOK = false
local preloadError: any = nil
local preloadFailures = {}
local preloadCallbacks = 0
local function mapCount(values)
	local count = 0
	for _ in values do count += 1 end
	return count
end
local function listText(values, limit)
	local output = {}
	for index, value in values do
		if index > limit then
			table.insert(output, "…+" .. tostring(#values - limit))
			break
		end
		table.insert(output, value)
	end
	return table.concat(output, ",")
end
local function preloadDiagnostic()
	local pending = {}
	local failed = {}
	for assetId, templateName in pairs(preloadAssetIds) do
		local status = preloadStatuses[assetId]
		if status == nil then
			table.insert(pending, templateName .. ":" .. assetId)
		elseif status ~= true then
			table.insert(failed, templateName .. ":" .. assetId .. "=" .. tostring(preloadStatusText[assetId] or "unknown"))
		end
	end
	for _, failure in preloadFailures do table.insert(failed, failure) end
	table.sort(pending)
	table.sort(failed)
	return string.format(
		"elapsed=%.2fs callbacks=%d expectedAssets=%d pending=[%s] failures=[%s] error=%s",
		os.clock() - preloadStartedAt,
		preloadCallbacks,
		mapCount(preloadAssetIds),
		listText(pending, 12),
		listText(failed, 12),
		tostring(preloadError)
	)
end
preloadStartedAt = os.clock()
preloadDeadline = preloadStartedAt + 45
task.spawn(function()
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(preloadInstances, function(assetId, status)
			preloadCallbacks += 1
			local raw = tostring(assetId)
			local key = assetKey(raw)
			preloadStatuses[key] = status == Enum.AssetFetchStatus.Success
			preloadStatusText[key] = tostring(status)
			if status ~= Enum.AssetFetchStatus.Success then
				table.insert(preloadFailures, raw .. "=" .. tostring(status))
			end
		end)
	end)
	preloadOK = ok
	preloadError = err
	preloadDone = true
end)

-- The server smoke holds a real 20-second round after moving the player to
-- the dock. Observe the production LocalBobber while that round is active and
-- verify its settled position raycasts to water beyond the island waterline.
-- This catches a client fallback that visually exists but still lands inland.
local bobberCheck = {done = false, ok = false, detail = "not observed"}
task.spawn(function()
	local player = Players.LocalPlayer
	local deadline = math.min(smokeDeadline - 4, os.clock() + 34)
	while os.clock() < deadline do
		local candidate = workspace:FindFirstChild("LocalBobber")
		if candidate and candidate:IsA("BasePart") then
			task.wait(.6) -- let the authored rod-tip cast settle onto the water target
			if candidate.Parent then
				local position = candidate.Position
				local center = Config.Zones[1].center
				local beyondWaterline = position.Z >= center.z + FishingLocation.Pier.waterlineZOffset
				local rayParams = RaycastParams.new()
				rayParams.FilterType = Enum.RaycastFilterType.Exclude
				rayParams.FilterDescendantsInstances = {player.Character}
				local hit = workspace:Raycast(position + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), rayParams)
				local waterHit = hit ~= nil and hit.Material == Enum.Material.Water
				bobberCheck.done = true
				bobberCheck.ok = beyondWaterline and waterHit
				bobberCheck.detail = string.format("position=(%.2f,%.2f,%.2f) beyondWaterline=%s waterHit=%s", position.X, position.Y, position.Z, tostring(beyondWaterline), tostring(waterHit))
				if bobberCheck.ok then
					print("FISH_PRESENTATION_BOBBER_PASS: " .. bobberCheck.detail)
				else
					warn("FISH_PRESENTATION_BOBBER_FAIL: " .. bobberCheck.detail)
				end
				return
			end
		end
		RunService.Heartbeat:Wait()
	end
	bobberCheck.done = true
	bobberCheck.detail = "LocalBobber was not observed during the bounded 20-second server round"
	warn("FISH_PRESENTATION_BOBBER_FAIL: " .. bobberCheck.detail)
end)

local importedSpecies = 0
for _, species in Config.Species do
	local source = ArtRenderer.visualSource(species)
	if source == "ImportedTemplate" then importedSpecies += 1 end
end
assert(importedSpecies == expectedSpeciesCount, "Imported coverage changed: " .. tostring(importedSpecies))

local fixture = Instance.new("Folder")
fixture.Name = "FishPresentationSmokeFixture"
fixture:SetAttribute("QAOnly", true)
fixture.Parent = workspace

local cases = {}
for _, species in Config.Species do
	table.insert(cases, {
		species = species.id,
		expected = "ImportedTemplate",
		template = ArtCatalog.Fish[species.id],
	})
end
assert(#cases == expectedSpeciesCount, "Presentation case coverage changed: " .. tostring(#cases))

for index, entry in cases do
	local species = assert(Config.SpeciesById[entry.species], "Species fixture missing: " .. entry.species)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview_" .. entry.species
	viewport.Size = UDim2.fromOffset(100, 100)
	viewport.Parent = fixture
	local fish = {id = "presentation_" .. entry.species, species = entry.species, level = 1, size = 2, mutation = 1}
	local model = assert(ArtRenderer.mountPreview(viewport, species, fish, 3.3), "Preview model missing: " .. entry.species)
	assert(viewport.CurrentCamera ~= nil, "Preview camera missing: " .. entry.species)
	assert(model:GetAttribute("FishVisualSource") == entry.expected, "Visual source mismatch: " .. entry.species)
	if entry.template then assert(model:GetAttribute("SourceTemplate") == entry.template, "Template mismatch: " .. entry.species) end
	local box = model:GetBoundingBox()
	assert(box.Position.Magnitude < .02, "Preview bounds are not centered: " .. entry.species)
	local parts = 0
	for _, object in model:GetDescendants() do
		if object:IsA("BasePart") then
			parts += 1
			assert(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery, "Unsafe preview part: " .. entry.species)
		end
	end
	assert(parts > 0, "Preview has no visible parts: " .. entry.species)
	model:SetAttribute("CaseIndex", index)
end

fixture:Destroy()

-- Wait for the server smoke to finish its merge/place/travel setup before
-- inspecting live PlayerGui. The harness calls the same production tab and
-- selection handlers; it does not reconstruct cards or invoke hidden UI APIs.
local player = Players.LocalPlayer
local function remainingTimeout(maximum)
	return math.max(0, math.min(maximum, smokeDeadline - os.clock()))
end
local playerGui = player:WaitForChild("PlayerGui", remainingTimeout(5))
assert(playerGui, "PlayerGui did not appear before smoke deadline")
local readyDeadline = math.min(smokeDeadline - 8, os.clock() + 36)
while ReplicatedStorage:GetAttribute("StudioSmokeReady") ~= true and os.clock() < readyDeadline do
	RunService.Heartbeat:Wait()
end
assert(ReplicatedStorage:GetAttribute("StudioSmokeReady") == true, "StudioSmoke did not finish before fish presentation UI check")

local gui = playerGui:WaitForChild("FishingAquariumUI", remainingTimeout(5))
assert(gui and gui:IsA("ScreenGui"), "FishingAquariumUI missing")
local remotes = ReplicatedStorage:WaitForChild("FishingRemotes", remainingTimeout(5))
assert(remotes, "FishingRemotes missing before smoke deadline")
local request = remotes:WaitForChild("Request", remainingTimeout(5)) :: RemoteFunction
assert(request, "FishingRemotes.Request missing before smoke deadline")
local state, snapshotReason = readSnapshotBounded(request, smokeDeadline - 2)
assert(type(state) == "table", "fish presentation snapshot unavailable: " .. tostring(snapshotReason))
local liveFish = state.fish and state.fish[1]
assert(liveFish and liveFish.species == "white_koi", "starter fish identity missing after StudioSmoke")

local harness = script.Parent:WaitForChild("UIRepairHarness", remainingTimeout(5))
assert(harness and harness:IsA("BindableFunction"), "FishPresentationSmoke UI harness missing")
local function waitUntil(predicate, timeout)
	local deadline = math.min(smokeDeadline - 2, os.clock() + timeout)
	repeat
		local ok, value = pcall(predicate)
		if ok and value then return true end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
	return false
end
local function viewportFor(root, description)
	local viewport = root and root:FindFirstChild("FishPreviewViewport", true)
	assert(viewport and viewport:IsA("ViewportFrame"), description .. " viewport missing")
	assert(viewport.CurrentCamera ~= nil, description .. " viewport camera missing")
	return viewport
end

assert(harness:Invoke("tab", "背包") == true, "could not open bag through production harness")
assert(waitUntil(function() return gui:FindFirstChild("BagDetail", true) ~= nil end, 3), "bag page did not render")
local card = gui:FindFirstChild("FishCard_" .. tostring(liveFish.id), true)
assert(card and card:IsA("TextButton"), "starter fish bag card missing")
local cardViewport = viewportFor(card, "bag card")
assert(card:GetAttribute("FishVisualSource") == "ImportedTemplate", "bag card lost imported fish identity")
assert(cardViewport:GetAttribute("SourceTemplate") == "Koi", "bag card source template changed")
assert(harness:Invoke("bagSelect", liveFish.id) == true, "could not select starter fish through production harness")
assert(waitUntil(function()
	local detail = gui:FindFirstChild("BagDetail", true)
	return detail ~= nil and detail:GetAttribute("FishVisualSource") == "ImportedTemplate"
end, 3), "bag detail did not expose imported fish identity")
local detail = gui:FindFirstChild("BagDetail", true)
assert(detail, "bag detail missing after selection")
local detailViewport = viewportFor(detail, "bag detail")
assert(detailViewport:GetAttribute("SourceTemplate") == "Koi", "bag detail source template changed")
print("FISH_PRESENTATION_UI_PASS: bag card/detail Koi viewport identity")

assert(harness:Invoke("tab", "图鉴") == true, "could not open index through production harness")
assert(waitUntil(function() return gui:FindFirstChild("Index_white_koi", true) ~= nil end, 3), "discovered index did not render")
local discovered = gui:FindFirstChild("Index_white_koi", true)
assert(discovered and discovered:IsA("TextButton"), "discovered Koi index card missing")
local discoveredViewport = viewportFor(discovered, "discovered index")
assert(discovered:GetAttribute("FishVisualSource") == "ImportedTemplate", "discovered index lost imported fish identity")
assert(discoveredViewport:GetAttribute("SourceTemplate") == "Koi", "discovered index source template changed")
local fallbackId: string? = nil
local fallback: TextButton? = nil
for _, species in Config.Species do
	if not (state.discovered and state.discovered[species.id]) and species.id ~= liveFish.species then
		local candidate = gui:FindFirstChild("Index_" .. species.id, true)
		if candidate and candidate:IsA("TextButton") then
			fallbackId = species.id
			fallback = candidate
			break
		end
	end
end
assert(fallback and fallbackId, "an undiscovered index card is required")
assert(not state.discovered or not state.discovered[fallbackId], "undiscovered index unexpectedly marked discovered")
local fallbackViewport = viewportFor(fallback, "undiscovered index")
assert(fallback:GetAttribute("FishVisualSource") == "ProceduralFallback", "undiscovered index must retain fallback provenance")
assert(fallbackViewport:GetAttribute("SourceTemplate") == nil, "undiscovered index must hide imported template provenance")
local fallbackLabel = fallback:FindFirstChildWhichIsA("TextLabel", true)
assert(fallbackLabel and fallbackLabel.Text == "未发现", "undiscovered index must hide species name")
print("FISH_PRESENTATION_INDEX_PASS: discovered Koi imported viewport; undiscovered " .. tostring(fallbackId) .. " remains hidden fallback")

local preloadWaitDeadline = math.min(preloadDeadline, smokeDeadline - 2)
while not preloadDone and os.clock() < preloadWaitDeadline do
	RunService.Heartbeat:Wait()
end
if not preloadDone then
	warn("FISH_PRESENTATION_ASSET_TIMEOUT: ContentProvider:PreloadAsync exceeded 45s for " .. tostring(#importedTemplates) .. " imported fish templates; " .. preloadDiagnostic())
	assert(false, "bounded imported fish preload timed out: " .. preloadDiagnostic())
end
if not preloadOK then
	warn("FISH_PRESENTATION_ASSET_FAIL: " .. preloadDiagnostic())
	assert(false, "imported fish preload failed: " .. preloadDiagnostic())
end
if #preloadFailures > 0 then
	warn("FISH_PRESENTATION_ASSET_FAIL: " .. preloadDiagnostic())
	assert(false, "imported fish asset fetch reported failure: " .. preloadDiagnostic())
end
assert(preloadCallbacks > 0, "ContentProvider returned no AssetFetchStatus callbacks: " .. preloadDiagnostic())
local missingStatuses = {}
for assetId, templateName in pairs(preloadAssetIds) do
	if preloadStatuses[assetId] ~= true then table.insert(missingStatuses, templateName .. ":" .. assetId) end
end
if #missingStatuses > 0 then
	warn("FISH_PRESENTATION_ASSET_PENDING: " .. preloadDiagnostic())
end
assert(#missingStatuses == 0, "imported fish asset status callbacks incomplete: " .. preloadDiagnostic())
print(string.format("FISH_PRESENTATION_ASSET_PASS: templates=%d expectedAssets=%d callbacks=%d elapsed=%.2fs status=Success", #importedTemplates, mapCount(preloadAssetIds), preloadCallbacks, os.clock() - preloadStartedAt))

assert(waitUntil(function() return bobberCheck.done end, math.min(2, remainingTimeout(2))), "bounded LocalBobber check did not complete before smoke deadline")
assert(bobberCheck.ok, "LocalBobber over-water raycast failed: " .. bobberCheck.detail)
harness:Invoke("tab", "钓鱼")
assert(os.clock() < smokeDeadline, "FishPresentationSmoke exceeded 58-second harness budget")
print(string.format("FISH_PRESENTATION_PASS: %d imported templates; %d/%d catalog species covered; %d zones; mapped species previews, bag/detail/index identities and water bobber verified", #importedTemplates, importedSpecies, expectedSpeciesCount, #Config.Zones))
