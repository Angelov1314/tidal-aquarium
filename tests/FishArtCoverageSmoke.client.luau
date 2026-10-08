--!strict
-- Studio-only, read-only fish asset loading gate.
--
-- This smoke deliberately does not mount fish, create fallback geometry, move
-- the camera/player, or touch PlayerGui. It proves the current Studio place
-- contains the complete authored library, then asks ContentProvider to load
-- the actual MeshPart instances and accepts only explicit AssetFetchStatus.Success
-- callbacks. SurfaceAppearance is structure-detected below but cannot be read
-- from a normal LocalScript because its ContentId properties are Plugin Security.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

assert(RunService:IsStudio(), "FISH_ART_QA_STUDIO_ONLY: this gate must run in Roblox Studio")
assert(RunService:IsRunning(), "FISH_ART_QA_STUDIO_ONLY: press Play in the QA place")

local RUN_MARKER = script:GetAttribute("FishArtQARunMarker") or "FISH_ART_QA_STUDIO_20261002"
local SOURCE_HASH = script:GetAttribute("FishArtQASourceSha256") or "standalone-project-source"
local ART_RENDERER_EXPECTED_HASH = script:GetAttribute("FishArtQAExpectedArtRendererSha256") or "standalone-project-art-renderer"
local smokeStartedAt = os.clock()
local TOTAL_DEADLINE_SECONDS = 55
local PRELOAD_DEADLINE_SECONDS = 45
local MAX_PRELOAD_WORKERS = 3
local smokeDeadline = smokeStartedAt + TOTAL_DEADLINE_SECONDS

local function marker(kind, message)
	print(kind .. " marker=" .. tostring(RUN_MARKER) .. " " .. message)
end

local function boundedChild(parent, name, timeoutSeconds)
	local deadline = math.min(smokeDeadline, os.clock() + timeoutSeconds)
	local child = parent:FindFirstChild(name)
	while not child and os.clock() < deadline do
		RunService.Heartbeat:Wait()
		child = parent:FindFirstChild(name)
	end
	assert(child, string.format("FISH_ART_QA_TIMEOUT marker=%s waitingFor=%s.%s elapsed=%.2fs", RUN_MARKER, parent:GetFullName(), name, os.clock() - smokeStartedAt))
	return child
end

marker("FISH_ART_QA_RUN_START", string.format("sourceHash=%s artRendererExpectedHash=%s deadlineSeconds=%d preloadDeadlineSeconds=%d workers=%d", tostring(SOURCE_HASH), tostring(ART_RENDERER_EXPECTED_HASH), TOTAL_DEADLINE_SECONDS, PRELOAD_DEADLINE_SECONDS, MAX_PRELOAD_WORKERS))

local shared = boundedChild(ReplicatedStorage, "FishingShared", 8)
local library = boundedChild(ReplicatedStorage, "FishingArt", 8)
assert(shared:IsA("Folder"), "FISH_ART_QA_STATIC_FAIL: FishingShared must be a Folder")
assert(library:IsA("Folder"), "FISH_ART_QA_STATIC_FAIL: FishingArt must be a Folder")

-- IsA/GetDescendants is allowed in the client, but ColorMap/NormalMap/
-- RoughnessMap/MetalnessMap are Plugin Security properties. Do not probe them
-- or convert a restricted read into a success. An Edit/Plugin exported
-- dependency snapshot is required before this gate can support SurfaceAppearance.
local surfaceAppearances = {}
local surfaceAppearanceSet = {}
for _, object in ipairs(library:GetDescendants()) do
	if object:IsA("SurfaceAppearance") then
		if not surfaceAppearanceSet[object] then
			surfaceAppearanceSet[object] = true
			table.insert(surfaceAppearances, object)
		end
	end
end
if #surfaceAppearances > 0 then
	local reason = "SurfaceAppearance ContentId properties are Plugin Security; requires Edit/Plugin exported dependency snapshot"
	marker("FISH_ART_QA_SURFACEAPPEARANCE_UNSUPPORTED", string.format("count=%d reason=%s", #surfaceAppearances, reason))
	marker("FISH_ART_QA_RESULT_FAIL", string.format("success=0 expected=0 surfaceAppearances=%d reason=%s", #surfaceAppearances, reason))
	error(string.format("FISH_ART_QA_RESULT_FAIL marker=%s reason=%s", RUN_MARKER, reason), 0)
end

local Config = require(boundedChild(shared, "Config", 8))
local ArtCatalog = require(boundedChild(shared, "ArtCatalog", 8))
local ArtRenderer = require(boundedChild(shared, "ArtRenderer", 8))
assert(type(ArtRenderer.textureEvidence) == "function",
	"FISH_ART_QA_STATIC_FAIL: current ArtRenderer has no textureEvidence diagnostic")

local EXPECTED_SPECIES = 70
local EXPECTED_MAPPED_TEMPLATES = 59
local EXPECTED_PROPS = 7
local EXPECTED_LIBRARY_ROOTS = 81
local EXPECTED_MESHPARTS = 82
local EXPECTED_LIBRARY_ONLY = 15

assert(#Config.Species == EXPECTED_SPECIES,
	"FISH_ART_QA_STATIC_FAIL: expected " .. tostring(EXPECTED_SPECIES) .. " species, got " .. tostring(#Config.Species))
assert(#Config.Zones == 9,
	"FISH_ART_QA_STATIC_FAIL: expected nine zones, got " .. tostring(#Config.Zones))

local function sortedKeys(values)
	local keys = {}
	for key in pairs(values) do table.insert(keys, key) end
	table.sort(keys)
	return keys
end

local function countMap(values)
	local count = 0
	for _ in pairs(values) do count += 1 end
	return count
end

local function joinSorted(values, empty)
	local copy = {}
	for _, value in ipairs(values) do table.insert(copy, value) end
	table.sort(copy)
	return #copy > 0 and table.concat(copy, ",") or (empty or "none")
end

local function addUnique(values, seen, value)
	if not seen[value] then
		seen[value] = true
		table.insert(values, value)
	end
end

-- The mapping is checked for all species first. These records also become the
-- species context attached to each later asset callback.
local mappedTemplates = {}
local mappedTemplateSet = {}
local speciesByTemplate = {}
local staticFailures = {}
for _, species in ipairs(Config.Species) do
	local templateName = ArtCatalog.Fish[species.id]
	if type(templateName) ~= "string" or templateName == "" then
		table.insert(staticFailures, species.id .. " -> missing ArtCatalog mapping")
	else
		addUnique(mappedTemplates, mappedTemplateSet, templateName)
		speciesByTemplate[templateName] = speciesByTemplate[templateName] or {}
		table.insert(speciesByTemplate[templateName], species.id)
		local evidence = ArtRenderer.textureEvidence(templateName)
		local source, resolvedName = ArtRenderer.visualSource(species)
		if not evidence.ok then
			table.insert(staticFailures, string.format(
				"%s -> %s evidence meshParts=%d meshIds=%d textureRefs=%d surfaces=%d",
				species.id,
				templateName,
				evidence.meshParts,
				evidence.meshIds,
				evidence.textureRefs,
				evidence.surfaceAppearances
			))
		end
		if source ~= "ImportedTemplate" or resolvedName ~= templateName then
			table.insert(staticFailures, string.format(
				"%s -> %s visualSource=%s resolved=%s",
				species.id,
				templateName,
				tostring(source),
				tostring(resolvedName)
			))
		end
	end
end

local propTemplates = {}
local propTemplateSet = {}
for _, templateName in pairs(ArtCatalog.Props) do
	addUnique(propTemplates, propTemplateSet, templateName)
end
if #propTemplates ~= EXPECTED_PROPS then
	table.insert(staticFailures, string.format("props expected=%d actual=%d", EXPECTED_PROPS, #propTemplates))
end
if #mappedTemplates ~= EXPECTED_MAPPED_TEMPLATES then
	table.insert(staticFailures, string.format("mappedTemplates expected=%d actual=%d", EXPECTED_MAPPED_TEMPLATES, #mappedTemplates))
end

-- Build an inventory from every direct library root and recursively inspect all
-- descendants. This is the part that catches nested gap geometry; no direct
-- child MeshPart shortcut is allowed here.
local libraryRootNames = {}
local libraryRootSet = {}
local templateByMeshPart = {}
local meshParts = {}
local meshPartSet = {}
for _, root in ipairs(library:GetChildren()) do
	if root:IsA("Model") then
		addUnique(libraryRootNames, libraryRootSet, root.Name)
		for _, object in ipairs(root:GetDescendants()) do
			if object:IsA("MeshPart") then
				addUnique(meshParts, meshPartSet, object)
				templateByMeshPart[object] = root.Name
			end
		end
	end
end

if #libraryRootNames ~= EXPECTED_LIBRARY_ROOTS then
	table.insert(staticFailures, string.format("libraryRoots expected=%d actual=%d", EXPECTED_LIBRARY_ROOTS, #libraryRootNames))
end
if #meshParts ~= EXPECTED_MESHPARTS then
	table.insert(staticFailures, string.format("recursiveMeshParts expected=%d actual=%d", EXPECTED_MESHPARTS, #meshParts))
end

local mappedMissing = {}
for _, templateName in ipairs(mappedTemplates) do
	if not libraryRootSet[templateName] then table.insert(mappedMissing, templateName) end
end
local libraryOnly = {}
for _, templateName in ipairs(libraryRootNames) do
	if not mappedTemplateSet[templateName] and not propTemplateSet[templateName] then
		table.insert(libraryOnly, templateName)
	end
end
if #mappedMissing > 0 then
	table.insert(staticFailures, "mappedTemplatesMissingFromLibrary=" .. joinSorted(mappedMissing))
end
if #libraryOnly ~= EXPECTED_LIBRARY_ONLY then
	table.insert(staticFailures, string.format("libraryOnlyTemplates expected=%d actual=%d", EXPECTED_LIBRARY_ONLY, #libraryOnly))
end

local function assetKey(value)
	local raw = tostring(value)
	local numeric = string.match(raw, "%d+")
	if not numeric or numeric == "0" then return nil end
	return numeric
end

local assetRefs = {}
local function ensureAsset(value, kind, templateName)
	local raw = tostring(value)
	local key = assetKey(raw)
	if not key then
		table.insert(staticFailures, string.format(
			"%s has invalid %s=%s species=%s",
			templateName,
			kind,
			raw,
			joinSorted(speciesByTemplate[templateName] or {})
		))
		return nil
	end
	local ref = assetRefs[key]
	if not ref then
		ref = {
			key = key,
			raw = raw,
			kinds = {},
			templates = {},
			templateSet = {},
			species = {},
			speciesSet = {},
		}
		assetRefs[key] = ref
	end
	ref.kinds[kind] = true
	if templateName and not ref.templateSet[templateName] then
		ref.templateSet[templateName] = true
		table.insert(ref.templates, templateName)
	end
	for _, speciesId in ipairs(speciesByTemplate[templateName] or {}) do
		if not ref.speciesSet[speciesId] then
			ref.speciesSet[speciesId] = true
			table.insert(ref.species, speciesId)
		end
	end
	return key
end

local preloadInstances = {}
local preloadInstanceSet = {}
local function addPreloadInstance(instance)
	if not preloadInstanceSet[instance] then
		preloadInstanceSet[instance] = true
		table.insert(preloadInstances, instance)
	end
end

local meshPartMissingMaterial = {}
for _, meshPart in ipairs(meshParts) do
	local templateName = templateByMeshPart[meshPart] or "<unknown-root>"
	local meshId = meshPart.MeshId
	local textureId = meshPart.TextureID
	local meshKey = nil
	if meshId ~= "" then
		meshKey = ensureAsset(meshId, "MeshId", templateName)
	else
		table.insert(staticFailures, string.format(
			"%s missing MeshId species=%s instance=%s",
			templateName,
			joinSorted(speciesByTemplate[templateName] or {}),
			meshPart:GetFullName()
		))
	end
	local textureKey = nil
	if textureId ~= "" then
		textureKey = ensureAsset(textureId, "TextureID", templateName)
	end
	local hasTexture = textureKey ~= nil
	if not meshKey or not hasTexture then
		table.insert(meshPartMissingMaterial, string.format(
			"%s/%s meshId=%s textureId=%s species=%s",
			templateName,
			meshPart:GetFullName(),
			tostring(meshId),
			tostring(textureId),
			joinSorted(speciesByTemplate[templateName] or {})
		))
	end
	addPreloadInstance(meshPart)
end
for _, missing in ipairs(meshPartMissingMaterial) do
	table.insert(staticFailures, "meshPartMissingMaterial=" .. missing)
end

marker("FISH_ART_QA_LIBRARY_INVENTORY", string.format(
	"roots=%d mappedTemplates=%d mappedMissing=%s propTemplates=%s props=%d recursiveMeshParts=%d surfaceAppearances=%d uniqueAssetIds=%d libraryOnlyTemplates=%s",
	#libraryRootNames,
	#mappedTemplates,
	joinSorted(mappedMissing),
	joinSorted(propTemplates),
	#propTemplates,
	#meshParts,
	#surfaceAppearances,
	countMap(assetRefs),
	joinSorted(libraryOnly)
))

if #staticFailures > 0 then
	for _, failure in ipairs(staticFailures) do
		marker("FISH_ART_QA_STATIC_FAIL", failure)
	end
	error(string.format("FISH_ART_QA_STATIC_FAIL marker=%s failures=%d", RUN_MARKER, #staticFailures), 0)
end

local expectedAssetKeys = sortedKeys(assetRefs)
assert(#expectedAssetKeys > 0 and #preloadInstances > 0,
	"FISH_ART_QA_STATIC_FAIL: no MeshPart MeshId/TextureID assets were collected")

local function contextText(ref)
	return string.format(
		"templates=%s species=%s kinds=%s",
		joinSorted(ref.templates),
		joinSorted(sortedKeys(ref.speciesSet)),
		joinSorted(sortedKeys(ref.kinds))
	)
end

-- ContentProvider:PreloadAsync yields until the supplied instances resolve. A
-- small finite worker pool keeps the blocking calls off this smoke's control
-- coroutine; the main coroutine enforces the absolute deadline. A worker that
-- does not return by the deadline is a timeout and therefore a failed gate.
local statusByAsset = {}
local statusTextByAsset = {}
local statusFailureByAsset = {}
local unknownCallbacks = {}
local workerErrors = {}
local callbackCount = 0
local workersFinished = 0
local workerCount = math.min(MAX_PRELOAD_WORKERS, #preloadInstances)
local workerBatches = {}
for workerIndex = 1, workerCount do workerBatches[workerIndex] = {} end
for index, instance in ipairs(preloadInstances) do
	table.insert(workerBatches[((index - 1) % workerCount) + 1], instance)
end

local function recordCallback(assetId, status, workerIndex)
	callbackCount += 1
	local raw = tostring(assetId)
	local key = assetKey(raw)
	if not key or not assetRefs[key] then
		unknownCallbacks[raw .. "@worker" .. tostring(workerIndex)] = tostring(status)
		return
	end
	local text = tostring(status)
	statusTextByAsset[key] = statusTextByAsset[key] and (statusTextByAsset[key] .. "->" .. text) or text
	if status == Enum.AssetFetchStatus.Success then
		if not statusFailureByAsset[key] then statusByAsset[key] = true end
	else
		statusFailureByAsset[key] = true
		statusByAsset[key] = false
	end
end

local preloadStartedAt = os.clock()
local preloadDeadline = math.min(smokeDeadline, preloadStartedAt + PRELOAD_DEADLINE_SECONDS)
for workerIndex, batch in ipairs(workerBatches) do
	task.spawn(function()
		local ok, errorMessage = pcall(function()
			ContentProvider:PreloadAsync(batch, function(assetId, status)
				recordCallback(assetId, status, workerIndex)
			end)
		end)
		if not ok then table.insert(workerErrors, string.format("worker=%d error=%s", workerIndex, tostring(errorMessage))) end
		workersFinished += 1
	end)
end

while workersFinished < workerCount and os.clock() < preloadDeadline do
	RunService.Heartbeat:Wait()
end

local timedOut = workersFinished < workerCount
local successCount = 0
local failureCount = 0
local pendingCount = 0

for _, key in ipairs(expectedAssetKeys) do
	local ref = assetRefs[key]
	if statusByAsset[key] == true and not statusFailureByAsset[key] then
		successCount += 1
	else
		if statusFailureByAsset[key] then
			failureCount += 1
			marker("FISH_ART_QA_ASSET_FAIL", string.format(
				"assetId=%s status=%s %s",
				ref.raw,
				statusTextByAsset[key] or "unknown",
				contextText(ref)
			))
		else
			pendingCount += 1
			marker("FISH_ART_QA_ASSET_TIMEOUT", string.format(
				"assetId=%s status=pending %s",
				ref.raw,
				contextText(ref)
			))
		end
	end
end
for callbackKey, status in pairs(unknownCallbacks) do
	marker("FISH_ART_QA_ASSET_FAIL", "assetId=" .. tostring(callbackKey) .. " status=" .. tostring(status) .. " templates=unknown species=unknown kinds=unknown")
end
for _, workerError in ipairs(workerErrors) do
	marker("FISH_ART_QA_ASSET_FAIL", workerError .. " assetId=worker-error templates=unknown species=unknown kinds=unknown")
end

local elapsed = os.clock() - preloadStartedAt
local unknownCount = countMap(unknownCallbacks)
if timedOut then
	marker("FISH_ART_QA_ASSET_TIMEOUT", string.format(
		"elapsed=%.2fs workersFinished=%d/%d callbacks=%d success=%d expected=%d",
		elapsed,
		workersFinished,
		workerCount,
		callbackCount,
		successCount,
		#expectedAssetKeys
	))
end
if timedOut or #workerErrors > 0 or unknownCount > 0 or failureCount > 0 or pendingCount > 0 then
	marker("FISH_ART_QA_RESULT_FAIL", string.format(
		"elapsed=%.2fs success=%d expected=%d failures=%d pending=%d callbacks=%d libraryRoots=%d mappedTemplates=%d recursiveMeshParts=%d libraryOnly=%d",
		elapsed,
		successCount,
		#expectedAssetKeys,
		failureCount + unknownCount + #workerErrors,
		pendingCount,
		callbackCount,
		#libraryRootNames,
		#mappedTemplates,
		#meshParts,
		#libraryOnly
	))
	error(string.format("FISH_ART_QA_RESULT_FAIL marker=%s success=%d expected=%d", RUN_MARKER, successCount, #expectedAssetKeys), 0)
end

assert(os.clock() <= smokeDeadline, "FISH_ART_QA_RESULT_FAIL: total smoke deadline exceeded")
marker("FISH_ART_QA_RESULT_PASS", string.format(
	"elapsed=%.2fs success=%d expected=%d callbacks=%d species=%d mappedTemplates=%d props=%d libraryRoots=%d recursiveMeshParts=%d libraryOnly=%d staticStatus=Success",
	elapsed,
	successCount,
	#expectedAssetKeys,
	callbackCount,
	#Config.Species,
	#mappedTemplates,
	#propTemplates,
	#libraryRootNames,
	#meshParts,
	#libraryOnly
))
