--!strict
-- Studio-only asset capture harness for the four authored fishing themes.
-- This script is intentionally read-only with respect to the fishing service:
-- it builds no profile requests and only changes the local camera/HUD while a
-- capture phase is active.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

if not RunService:IsStudio() then
	return
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local ThemeContent = require(shared:WaitForChild("ThemeContent"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))

local SCENE_HOLD_SECONDS = 18
local STABILIZE_SECONDS = 1.25
local PREVIEW_ZONES = { 6, 7, 8, 9 }

local sceneDefinitions = {
	[6] = {
		stableId = "scene_6_mystic_lake",
		theme = "mystic_lake",
		props = { "ThemeSign", "MoonPool", "LotusPad", "MoonLantern", "DockLantern" },
	},
	[7] = {
		stableId = "scene_7_lava_fishing_ground",
		theme = "lava_fishing_ground",
		props = { "ThemeSign", "BasaltPillar", "MagmaCore", "BasaltBridge", "DockMagmaVent", "DockMagmaGlow" },
	},
	[8] = {
		stableId = "scene_8_alien_waters",
		theme = "alien_waters",
		props = { "ThemeSign", "SignalOrb", "OrbitRing", "AlienPanel", "DockSignalPylon", "DockSignalOrb" },
	},
	[9] = {
		stableId = "scene_9_chemistry_lab",
		theme = "chemistry_lab",
		props = { "ThemeSign", "LabTank", "ReagentBubble", "LabPipe", "DockLabTank", "DockLabBubble" },
	},
}

local galleryDefinitions = {
	[6] = { stableId = "gallery_6_mystic_lake", theme = "mystic_lake" },
	[7] = { stableId = "gallery_7_lava_fishing_ground", theme = "lava_fishing_ground" },
	[8] = { stableId = "gallery_8_alien_waters", theme = "alien_waters" },
	[9] = { stableId = "gallery_9_chemistry_lab", theme = "chemistry_lab" },
}

local oldHud: ScreenGui? = nil
local oldHudEnabled: boolean? = nil
local captureGui: ScreenGui? = nil
local captureBoard: Frame? = nil
local captureLabel: TextLabel? = nil
local camera: Camera? = nil
local oldCameraType: Enum.CameraType? = nil
local oldCameraCFrame: CFrame? = nil
local oldCameraSubject: Instance? = nil
local oldCameraFieldOfView: number? = nil

local function restoreLocalView()
	if oldHud and oldHud.Parent and oldHudEnabled ~= nil then
		oldHud.Enabled = oldHudEnabled
	end
	if camera and camera.Parent then
		if oldCameraCFrame then camera.CFrame = oldCameraCFrame end
		if oldCameraSubject then camera.CameraSubject = oldCameraSubject end
		if oldCameraFieldOfView then camera.FieldOfView = oldCameraFieldOfView end
		if oldCameraType then camera.CameraType = oldCameraType end
	end
	if captureGui and captureGui.Parent then
		captureGui:Destroy()
	end
	if captureBoard and captureBoard.Parent then
		captureBoard:Destroy()
	end
end

local function colorFrom(data, fallback)
	if type(data) ~= "table" then return fallback end
	return Color3.fromRGB(
		math.clamp(tonumber(data.r) or fallback.R * 255, 0, 255),
		math.clamp(tonumber(data.g) or fallback.G * 255, 0, 255),
		math.clamp(tonumber(data.b) or fallback.B * 255, 0, 255)
	)
end

local function waitForCurrentCamera(): Camera
	local current = workspace.CurrentCamera
	if not current then
		workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
		current = workspace.CurrentCamera
	end
	assert(current, "CurrentCamera was not created")
	return current
end

local function themeById(zoneId)
	for _, zone in ipairs(ThemeContent.Zones or {}) do
		if zone.id == zoneId then return zone end
	end
	return nil
end

local function speciesForZone(zoneId)
	local result = {}
	for _, species in ipairs(ThemeContent.Species or {}) do
		if species.zone == zoneId then
			table.insert(result, species)
		end
	end
	table.sort(result, function(left, right)
		return (left.rarity or 0) < (right.rarity or 0)
	end)
	return result
end

local function prepareWorld()
	local world = workspace:WaitForChild("FishingWorld", 30)
	assert(world, "FishingWorld was not built by the server")
	local zones = {}
	for _, zoneId in ipairs(PREVIEW_ZONES) do
		local authoredZone = assert(themeById(zoneId), "missing authored theme zone " .. tostring(zoneId))
		assert(authoredZone.themeOnly == true, "theme capture requires themeOnly zone " .. tostring(zoneId))
		local definition = assert(sceneDefinitions[zoneId], "missing scene definition " .. tostring(zoneId))
		local zoneModel = world:WaitForChild("Zone" .. tostring(zoneId), 30)
		assert(zoneModel, "missing real world Zone" .. tostring(zoneId))
		local themeSet = zoneModel:FindFirstChild("ThemeEnvironment_" .. definition.theme)
		assert(themeSet and themeSet:IsA("Model"), "missing real theme environment " .. definition.theme)
		for _, propName in ipairs(definition.props) do
			assert(themeSet:FindFirstChild(propName, true), definition.theme .. " missing prop " .. propName)
		end
		assert(zoneModel:FindFirstChild("FishingMarker"), definition.theme .. " missing fishing marker")
		assert(zoneModel:FindFirstChild("DockPlank"), definition.theme .. " missing dock planks")
		local species = speciesForZone(zoneId)
		assert(#species == 7, definition.theme .. " must contain seven authored fish")
		table.insert(zones, {
			id = zoneId,
			authored = authoredZone,
			definition = definition,
			model = zoneModel,
			themeSet = themeSet,
			species = species,
		})
	end
	return world, zones
end

local function preloadFishTemplates(zones)
	local preloadInstances = {}
	local seen = {}
	local speciesCount = 0
	for _, zone in ipairs(zones) do
		for _, species in ipairs(zone.species) do
			speciesCount += 1
			local templateName = assert(species.template, "theme fish has no template " .. tostring(species.id))
			local template = ArtRenderer.template(templateName)
			assert(template, "missing imported fish template " .. templateName)
			if not seen[template] then
				seen[template] = true
				table.insert(preloadInstances, template)
			end
			for _, object in ipairs(template:GetDescendants()) do
				if (object:IsA("MeshPart") or object:IsA("SurfaceAppearance")) and not seen[object] then
					seen[object] = true
					table.insert(preloadInstances, object)
				end
			end
		end
	end
	local failures = {}
	local callbacks = 0
	local ok, errorMessage = pcall(function()
		ContentProvider:PreloadAsync(preloadInstances, function(assetId, status)
			callbacks += 1
			if status ~= Enum.AssetFetchStatus.Success then
				table.insert(failures, tostring(assetId) .. ":" .. tostring(status))
			end
		end)
	end)
	assert(ok, "theme asset preload failed: " .. tostring(errorMessage))
	assert(#failures == 0, "theme asset preload returned failures: " .. table.concat(failures, ", "))
	print(string.format("THEME_CAPTURE_PRELOAD_PASS: %d fish templates / %d instances / %d callbacks", speciesCount, #preloadInstances, callbacks))
end

local function makeTextLabel(parent, name, text, size, position, textSize)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 247, 226)
	label.TextSize = textSize
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = text
	label.Parent = parent
	return label
end

local function setupCaptureUi()
	local hudCandidate = playerGui:WaitForChild("FishingAquariumUI", 10)
	oldHud = hudCandidate :: ScreenGui?
	if oldHud and oldHud:IsA("ScreenGui") then
		oldHudEnabled = oldHud.Enabled
		oldHud.Enabled = false
	else
		oldHud = nil
	end

	captureGui = Instance.new("ScreenGui")
	captureGui.Name = "ThemeCaptureOverlay"
	captureGui.ResetOnSpawn = false
	captureGui.IgnoreGuiInset = true
	captureGui.DisplayOrder = 2000
	captureGui.Parent = playerGui

	local labelBack = Instance.new("Frame")
	labelBack.Name = "PreviewLabel"
	labelBack.Size = UDim2.fromOffset(360, 58)
	labelBack.AnchorPoint = Vector2.new(1, 0)
	labelBack.Position = UDim2.new(1, -12, 0, 12)
	labelBack.BackgroundColor3 = Color3.fromRGB(20, 34, 45)
	labelBack.BackgroundTransparency = 0.16
	labelBack.BorderSizePixel = 0
	labelBack.Parent = captureGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = labelBack
	captureLabel = makeTextLabel(labelBack, "Text", "素材预览 · 非正式游戏UI", UDim2.new(1, -16, 1, -8), UDim2.fromOffset(8, 4), 16)
	captureLabel.TextYAlignment = Enum.TextYAlignment.Center

	captureBoard = Instance.new("Frame")
	captureBoard.Name = "ThemeFishGallery"
	captureBoard.AnchorPoint = Vector2.new(0.5, 0.5)
	captureBoard.Position = UDim2.fromScale(0.5, 0.54)
	captureBoard.Size = UDim2.fromScale(0.92, 0.86)
	captureBoard.BackgroundColor3 = Color3.fromRGB(22, 37, 47)
	captureBoard.BackgroundTransparency = 0.08
	captureBoard.BorderSizePixel = 0
	captureBoard.Visible = false
	captureBoard.Parent = captureGui
	local boardCorner = Instance.new("UICorner")
	boardCorner.CornerRadius = UDim.new(0, 14)
	boardCorner.Parent = captureBoard
	return captureGui, captureBoard
end

local function setCaptureLabel(text)
	if captureLabel then captureLabel.Text = text end
end

local function frameScene(zone)
	assert(camera, "capture camera is not ready")
	captureBoard.Visible = false
	local themeFrame, themeSize = zone.themeSet:GetBoundingBox()
	local center = zone.authored.center
	local dockPoint = Vector3.new(center.x, 7, center.z + 60)
	local themePoint = themeFrame.Position
	local focus = Vector3.new((themePoint.X + dockPoint.X) * 0.5, 8, (themePoint.Z + dockPoint.Z) * 0.5)
	local extent = math.max(themeSize.X, themeSize.Z, 86)
	local distance = math.clamp(extent * 1.42, 124, 182)
	local lateralSign = if zone.id % 2 == 0 then -1 else 1
	local cameraPosition = focus + Vector3.new(lateralSign * distance * 0.74, distance * 0.47, distance * 0.93)
	camera.FieldOfView = 52
	camera.CFrame = CFrame.lookAt(cameraPosition, focus)
	setCaptureLabel(string.format("素材预览 · 非正式游戏UI\n%d区 %s · 实景主题与垂钓栈桥", zone.id, zone.authored.name))
end

local function clearBoard()
	assert(captureBoard, "capture board is not ready")
	for _, child in ipairs(captureBoard:GetChildren()) do
		child:Destroy()
	end
end

local function addFishCard(parent, species, cardIndex)
	local card = Instance.new("Frame")
	card.Name = "FishCard_" .. species.id
	card.BackgroundColor3 = colorFrom(species.color, Color3.fromRGB(83, 141, 157))
	card.BackgroundTransparency = 0.2
	card.BorderSizePixel = 0
	card.LayoutOrder = cardIndex
	card.Parent = parent
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "ImportedFishPreview"
	viewport.Size = UDim2.new(1, -10, 0, 70)
	viewport.Position = UDim2.fromOffset(5, 5)
	viewport.BackgroundColor3 = Color3.fromRGB(12, 25, 32)
	viewport.BackgroundTransparency = 0.12
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(190, 190, 190)
	viewport.LightColor = Color3.fromRGB(255, 250, 235)
	viewport.Parent = card

	local fishRecord = {
		id = "theme_capture_" .. species.id,
		species = species.id,
		level = 1,
		size = 2,
		mutation = 1,
	}
	local targetLength = 3.05 + math.clamp((species.rarity or 1) * 0.13, 0, 0.9)
	local model = ArtRenderer.mountPreview(viewport, species, fishRecord, targetLength, false)
	assert(model, "ArtRenderer did not mount " .. tostring(species.id))
	assert(viewport:GetAttribute("FishVisualSource") == "ImportedTemplate", "non-imported preview for " .. tostring(species.id))

	local rarity = Config.Rarities[species.rarity]
	local rarityName = if rarity then rarity.name else ("品质 " .. tostring(species.rarity))
	local fishName = makeTextLabel(card, "FishName", tostring(species.name), UDim2.new(1, -10, 0, 17), UDim2.fromOffset(5, 77), 12)
	fishName.TextXAlignment = Enum.TextXAlignment.Center
	local detail = makeTextLabel(card, "Rarity", rarityName, UDim2.new(1, -10, 0, 15), UDim2.fromOffset(5, 92), 10)
	detail.TextXAlignment = Enum.TextXAlignment.Center
	detail.TextColor3 = if rarity then colorFrom(rarity.color, Color3.fromRGB(255, 247, 226)) else Color3.fromRGB(255, 247, 226)
end

local function frameGallery(zone)
	assert(captureBoard, "capture board is not ready")
	captureBoard.Visible = true
	clearBoard()
	setCaptureLabel(string.format("素材预览 · 非正式游戏UI\n%d区 %s · 7种真实导入鱼类", zone.id, zone.authored.name))
	makeTextLabel(captureBoard, "Title", string.format("%s · 鱼类素材预览", zone.authored.name), UDim2.new(1, -28, 0, 34), UDim2.fromOffset(14, 8), 20)
	local subtitle = makeTextLabel(captureBoard, "Subtitle", "真实导入鱼类 · 7种鱼 · 中文名与品质", UDim2.new(1, -28, 0, 20), UDim2.fromOffset(14, 42), 11)
	subtitle.TextColor3 = Color3.fromRGB(177, 224, 214)
	local grid = Instance.new("Frame")
	grid.Name = "FishGrid"
	grid.Size = UDim2.new(1, -28, 1, -76)
	grid.Position = UDim2.fromOffset(14, 68)
	grid.BackgroundTransparency = 1
	grid.Parent = captureBoard
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(150, 104)
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.FillDirectionMaxCells = 4
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for index, species in ipairs(zone.species) do
		addFishCard(grid, species, index)
	end
end

local function holdStable(phaseId, pass)
	task.wait(STABILIZE_SECONDS)
	print(string.format("THEME_CAPTURE_READY:%s:pass%d", phaseId, pass))
	local deadline = os.clock() + SCENE_HOLD_SECONDS
	while os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
end

local function runCapture()
	local _, zones = prepareWorld()
	preloadFishTemplates(zones)
	setupCaptureUi()
	camera = waitForCurrentCamera()
	oldCameraType = camera.CameraType
	oldCameraCFrame = camera.CFrame
	oldCameraSubject = camera.CameraSubject
	oldCameraFieldOfView = camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable

	local byId = {}
	for _, zone in ipairs(zones) do byId[zone.id] = zone end
	local manifest = {
		"scene_6_mystic_lake",
		"scene_7_lava_fishing_ground",
		"scene_8_alien_waters",
		"scene_9_chemistry_lab",
		"gallery_6_mystic_lake",
		"gallery_7_lava_fishing_ground",
		"gallery_8_alien_waters",
		"gallery_9_chemistry_lab",
	}
	print("THEME_CAPTURE_MANIFEST: " .. table.concat(manifest, " -> "))
	for pass = 1, 2 do
		for _, zoneId in ipairs(PREVIEW_ZONES) do
			local scene = sceneDefinitions[zoneId]
			local zone = byId[zoneId]
			assert(scene and zone)
			frameScene(zone)
			holdStable(scene.stableId, pass)
		end
		for _, zoneId in ipairs(PREVIEW_ZONES) do
			local gallery = galleryDefinitions[zoneId]
			local zone = byId[zoneId]
			assert(gallery and zone)
			frameGallery(zone)
			holdStable(gallery.stableId, pass)
		end
	end
	print("THEME_CAPTURE_DONE: 8 phases x 2 passes")
end

local ok, errorMessage = xpcall(runCapture, debug.traceback)
restoreLocalView()
if not ok then
	warn("THEME_CAPTURE_FAIL: " .. tostring(errorMessage))
else
	print("THEME_CAPTURE_CLEANUP_PASS: camera and production HUD restored")
end
