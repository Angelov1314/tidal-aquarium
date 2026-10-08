--!strict
-- Responsive runtime smoke. The mobile runner configures one target viewport
-- in Edit mode before each PlayClient session. This script measures the real
-- camera viewport and PlayerGui bounds; it never treats pure arithmetic as a
-- device pass.
--
-- Studio-only production seam contract (owned by main.client): when this
-- script is present, create the existing UIRepairHarness BindableFunction
-- under script.Parent. Keep its real-handler commands:
--   Invoke("tab", tabName), Invoke("mergeSelect", fishId),
--   Invoke("audio", "Music"), Invoke("close"), Invoke("refresh").
-- The seam must remain absent from the normal Demo.
--
-- Preferred QA names are Navigation, BagList/BagDetail, MergeMaterials/
-- MergePreview, UpgradeScroll/UpgradeOdds. Semantic fallbacks below keep the
-- smoke useful while the renderer is being renamed, but missing names are
-- reported so a broad ContentViewport cannot silently replace a page list.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local StudioTestService = game:GetService("StudioTestService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local ArtCatalog = require(shared:WaitForChild("ArtCatalog"))
local ThemeContent = require(shared:WaitForChild("ThemeContent"))
local expectedSpeciesCount = 70
local expectedZoneCount = 9
local expectedFishTemplateCount = 74
assert(#Config.Species == expectedSpeciesCount, "Responsive smoke species count changed: " .. tostring(#Config.Species))
assert(#Config.Zones == expectedZoneCount, "Responsive smoke zone count changed: " .. tostring(#Config.Zones))
for _, species in ThemeContent.Species do
	assert(ArtCatalog.Fish[species.id] == species.template, "Responsive theme mapping changed: " .. species.id)
end
local propNames = {}
for _, name in ArtCatalog.Props do propNames[name] = true end
local fishTemplateCount = 0
for _, child in ReplicatedStorage:WaitForChild("FishingArt"):GetChildren() do
	if child:IsA("Model") and not propNames[child.Name] then fishTemplateCount += 1 end
end
assert(fishTemplateCount == expectedFishTemplateCount, "Responsive smoke fish template count changed: " .. tostring(fishTemplateCount))
local failures: {string} = {}
local warnings: {string} = {}
local orientationActual = false
local simulatedViewport: Vector2? = nil

local targets = {
	{name = "phone-320x568", width = 320, height = 568, orientation = Enum.ScreenOrientation.Portrait, compact = true, touch = true},
	{name = "phone-360x800", width = 360, height = 800, orientation = Enum.ScreenOrientation.Portrait, compact = true, touch = true},
	{name = "phone-390x844", width = 390, height = 844, orientation = Enum.ScreenOrientation.Portrait, compact = true, touch = true},
	{name = "landscape-844x390", width = 844, height = 390, orientation = Enum.ScreenOrientation.LandscapeLeft, compact = true, touch = true},
	{name = "tablet-1024x768", width = 1024, height = 768, orientation = Enum.ScreenOrientation.LandscapeLeft, compact = false, touch = true},
	{name = "desktop-1280x720", width = 1280, height = 720, orientation = Enum.ScreenOrientation.LandscapeLeft, compact = false, touch = false},
}

local function warn(message: string)
	table.insert(warnings, message)
	print("MOBILE_RESPONSIVE_WARN: " .. message)
end

local function check(condition: boolean, message: string): boolean
	if not condition then
		table.insert(failures, message)
		warn(message)
	end
	return condition
end

local function waitUntil(predicate: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	repeat
		local ok, value = pcall(predicate)
		if ok and value then return true end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
	return false
end

local SNAPSHOT_RPC_TIMEOUT = 4
local SNAPSHOT_SPACING = 0.16

local function invokeSnapshotBounded(request: RemoteFunction, payload: any, deadline: number): (boolean, any?, string?)
	if os.clock() >= deadline then return false, nil, "timeout" end
	local finished = false
	local callOk = false
	local response: any = nil
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

local function readSnapshotBounded(request: RemoteFunction, outerDeadline: number?): (any?, string?)
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

local function waitRender()
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
end

local function actuallyVisible(item: Instance): boolean
	local cursor: Instance? = item
	while cursor do
		if cursor:IsA("GuiObject") and not cursor.Visible then return false end
		if cursor:IsA("ScreenGui") and not cursor.Enabled then return false end
		cursor = cursor.Parent
	end
	return true
end

local function containsText(root: Instance, needle: string): TextLabel?
	for _, item in root:GetDescendants() do
		if item:IsA("TextLabel") and actuallyVisible(item) and string.find(item.Text, needle, 1, true) ~= nil then
			return item
		end
	end
	return nil
end

local function exactButton(root: Instance, text: string): TextButton?
	for _, item in root:GetDescendants() do
		if item:IsA("TextButton") and actuallyVisible(item) and item.Text == text then return item end
	end
	return nil
end

local function containsButton(root: Instance, text: string): TextButton?
	for _, item in root:GetDescendants() do
		if item:IsA("TextButton") and actuallyVisible(item) and string.find(item.Text, text, 1, true) ~= nil then return item end
	end
	return nil
end

local function namedGui(root: Instance, names: {string}): GuiObject?
	for _, name in names do
		local item = root:FindFirstChild(name, true)
		if item and item:IsA("GuiObject") and actuallyVisible(item) then return item end
	end
	return nil
end

local function visibleScroll(root: Instance, preferredNames: {string}): ScrollingFrame?
	for _, name in preferredNames do
		local item = root:FindFirstChild(name, true)
		if item and item:IsA("ScrollingFrame") and actuallyVisible(item) then return item end
	end
	-- Do not fall back to ContentViewport: it is the page host and would hide a
	-- missing page-specific list name behind a false positive.
	return nil
end

local function rect(item: GuiObject): (number, number, number, number)
	local p, s = item.AbsolutePosition, item.AbsoluteSize
	return p.X, p.Y, p.X + s.X, p.Y + s.Y
end

local function overlaps(a: GuiObject, b: GuiObject): boolean
	local al, at, ar, ab = rect(a)
	local bl, bt, br, bb = rect(b)
	return al < br - 1 and bl < ar - 1 and at < bb - 1 and bt < ab - 1
end

local function viewport(): Vector2
	if simulatedViewport then return simulatedViewport end
	local camera = workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.zero
end

local function withinViewport(item: GuiObject, v: Vector2, margin: number?): boolean
	local left, top, right, bottom = rect(item)
	local m = margin or 2
	return left >= -m and top >= -m and right <= v.X + m and bottom <= v.Y + m
end

local function insetSafeBounds(v: Vector2): (number, number, number, number)
	local gui = playerGui:FindFirstChild("FishingAquariumUI")
	local root = gui and gui:FindFirstChild("ResponsiveRoot", true)
	if root and root:IsA("GuiObject") and root.AbsoluteSize.X > 0 and root.AbsoluteSize.Y > 0 then
		local p, s = root.AbsolutePosition, root.AbsoluteSize
		return p.X, p.Y, p.X + s.X, p.Y + s.Y
	end
	local topLeft, bottomRight = GuiService:GetGuiInset()
	return topLeft.X, topLeft.Y, v.X - bottomRight.X, v.Y - bottomRight.Y
end

local function withinSafe(item: GuiObject, v: Vector2): boolean
	local left, top, right, bottom = rect(item)
	local safeLeft, safeTop, safeRight, safeBottom = insetSafeBounds(v)
	return left >= safeLeft - 4 and top >= safeTop - 4 and right <= safeRight + 4 and bottom <= safeBottom + 4
end

local harness: BindableFunction? = nil
local function invokeHarness(command: string, value: any, description: string): boolean
	if not harness then
		local candidate = script.Parent:FindFirstChild("UIRepairHarness")
		if candidate and candidate:IsA("BindableFunction") then harness = candidate end
	end
	if not harness then
		check(false, "UIRepairHarness missing for " .. description)
		return false
	end
	local ok, result = pcall(function() return (harness :: BindableFunction):Invoke(command, value) end)
	if not ok or result == false then
		check(false, "UIRepairHarness failed for " .. description .. ": " .. tostring(result))
		return false
	end
	return true
end

local responsiveHarness: BindableFunction? = nil
local function invokeResponsive(command: string, value: any, height: any, touch: any): boolean
	if not responsiveHarness then
		local candidate = script.Parent:FindFirstChild("ResponsiveHarness")
		if candidate and candidate:IsA("BindableFunction") then responsiveHarness = candidate end
	end
	if not responsiveHarness then return false end
	local ok, result = pcall(function()
		return (responsiveHarness :: BindableFunction):Invoke(command, value, height, touch)
	end)
	return ok and type(result) == "table" and result.ok == true
end

local function layoutProbe(target: any): boolean
	local moduleScript = script.Parent:FindFirstChild("ResponsiveLayout")
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("ResponsiveLayout module unavailable; layout-only target=" .. target.name)
		return false
	end
	local okRequire, moduleOrError = pcall(require, moduleScript)
	if not okRequire or type(moduleOrError) ~= "table" then
		warn("ResponsiveLayout require failed target=" .. target.name .. " error=" .. tostring(moduleOrError))
		return false
	end
	local resolver = moduleOrError.compute
	if type(resolver) ~= "function" then
		warn("ResponsiveLayout.compute missing target=" .. target.name)
		return false
	end
	local okResolve, result = pcall(function()
		return resolver(target.width, target.height, 0, 0, 0, 0, true)
	end)
	if not okResolve or type(result) ~= "table" then
		warn("ResponsiveLayout.compute failed target=" .. target.name .. " error=" .. tostring(result))
		return false
	end
	local safe = result.safe or result.safeRect
	if type(safe) == "table" then
		check((safe.width or target.width) <= target.width and (safe.height or target.height) <= target.height,
			"layout safe rect exceeds target " .. target.name)
	end
	return true
end

local function targetByName(name: string): any
	for _, target in targets do if target.name == name then return target end end
	return nil
end

local function targetArgs(): string?
	local ok, args = pcall(function() return StudioTestService:GetTestArgs() end)
	if ok and type(args) == "string" then return args end
	return nil
end

local function activeTarget(): any
	local injected = ReplicatedStorage:GetAttribute("MobileResponsiveTarget")
	if type(injected) == "string" then
		local target = targetByName(injected)
		if target then return target end
		-- The runner uses the explicit layout-only token for its guarded
		-- fallback; do not infer a device target from a desktop viewport.
		return nil
	end
	local name = targetArgs()
	if name then
		local target = targetByName(name)
		if target then return target end
	end
	return nil
end

local function inspectButtons(gui: ScreenGui, target: any, v: Vector2)
	local count = 0
	local smallest = math.huge
	local smallestName = ""
	for _, item in gui:GetDescendants() do
		if item:IsA("TextButton") and actuallyVisible(item) then
			count += 1
			local size = math.min(item.AbsoluteSize.X, item.AbsoluteSize.Y)
			if size < smallest then smallest, smallestName = size, item:GetFullName() end
			if target.compact or target.touch then
				check(size >= 44, string.format("compact target %s button below 44px: %s %.1fx%.1f", target.name, item:GetFullName(), item.AbsoluteSize.X, item.AbsoluteSize.Y))
			end
		end
	end
	check(count > 0, "no visible TextButton controls at " .. target.name)
	print(string.format("MOBILE_BUTTONS target=%s count=%d smallest=%.1f name=%s", target.name, count, smallest, smallestName))

	local audioButton = exactButton(gui, "音频")
	if audioButton then check(withinSafe(audioButton, v), "audio button leaves viewport " .. target.name) end
	local fishing = gui:FindFirstChild("FishingAction", true)
	if fishing and fishing:IsA("GuiObject") and actuallyVisible(fishing) then check(withinSafe(fishing, v), "FishingAction leaves safe viewport " .. target.name) end
end

local function inspectNavigation(gui: ScreenGui, target: any, v: Vector2)
	local nav = namedGui(gui, {"NavViewport"})
	local tabs = {"钓鱼", "背包", "水族馆", "合成", "图鉴", "升级", "商店"}
	if not nav then
		check(false, "NavViewport missing at " .. target.name)
		return
	end
	local bagButton: GuiObject? = if target.compact then gui:FindFirstChild("CompactBagButton", true) :: GuiObject? else exactButton(nav, "背包")
	local shopButton = exactButton(nav, "商店")
	for _, tab in tabs do
		check(exactButton(nav, tab) ~= nil, "navigation tab missing " .. tab .. " at " .. target.name)
	end
	if nav:IsA("ScrollingFrame") then
		local canvas = nav.AbsoluteCanvasSize
		check(canvas.X >= #tabs * 44 - 1 or nav.CanvasSize.X.Offset >= #tabs * 44 - 1,
			"navigation is not horizontally scrollable at " .. target.name)
		local original = nav.CanvasPosition
		nav.CanvasPosition = Vector2.new(math.max(0, canvas.X - nav.AbsoluteSize.X), original.Y)
		waitRender()
		if shopButton then
			local shopInBounds = withinSafe(shopButton, v)
			check(shopInBounds, "last navigation tab leaves viewport at end " .. target.name)
			if not shopInBounds then
				print(string.format("MOBILE_NAV_BOUNDS: target=%s navPos=%.1fx%.1f navSize=%.1fx%.1f canvas=%.1fx%.1f canvasPos=%.1fx%.1f shopPos=%.1fx%.1f shopSize=%.1fx%.1f", target.name, nav.AbsolutePosition.X, nav.AbsolutePosition.Y, nav.AbsoluteSize.X, nav.AbsoluteSize.Y, canvas.X, canvas.Y, nav.CanvasPosition.X, nav.CanvasPosition.Y, shopButton.AbsolutePosition.X, shopButton.AbsolutePosition.Y, shopButton.AbsoluteSize.X, shopButton.AbsoluteSize.Y))
			end
		end
		if bagButton and actuallyVisible(bagButton) then
			check(withinSafe(bagButton, v), "compact bag catch target leaves viewport at nav end " .. target.name)
		else
			check(false, (if target.compact then "CompactBagButton missing/hidden at " else "navigation bag tab missing/hidden at ") .. target.name)
		end
		nav.CanvasPosition = original
		waitRender()
	end
end

local function inspectPage(gui: ScreenGui, target: any, tab: string, title: string, pageName: string)
	if not invokeHarness("tab", tab, pageName .. " tab") then return end
	waitRender()
	local main = gui:FindFirstChild("ContentPanel", true)
	if not main or not main:IsA("Frame") then
		check(false, "ContentPanel missing on " .. pageName)
		return
	end
	check(main.Visible, pageName .. " panel not visible")
	local heading = containsText(main, title)
	check(heading ~= nil, pageName .. " title missing")
	local v = viewport()
	if main.Visible then check(withinSafe(main, v), pageName .. " panel leaves safe viewport at " .. target.name) end

	if pageName == "bag" then
		local list = visibleScroll(main, {"BagList"})
		local detail = main:FindFirstChild("BagDetail", true)
		check(list ~= nil, "bag list missing at " .. target.name)
		check(detail ~= nil and detail:IsA("GuiObject"), "bag detail missing at " .. target.name)
		if list and detail and detail:IsA("GuiObject") then
			check(not overlaps(list, detail), "bag list/detail overlap at " .. target.name)
		end
		if target.compact then
			local content = main:FindFirstChild("ContentViewport", true)
			local header = gui:FindFirstChild("EconomyBar", true)
			local nav = gui:FindFirstChild("NavViewport", true)
			check(content ~= nil and content:IsA("GuiObject") and content.AbsoluteSize.Y >= 200,
				"compact bag content window is too short at " .. target.name)
			if target.name == "landscape-844x390" and list then
				local firstCard = list:FindFirstChild("FishCard_f1", true)
				check(firstCard ~= nil and firstCard:IsA("GuiObject") and withinSafe(firstCard, v),
					"landscape bag first fish is below the initial viewport at " .. target.name)
			end
			check(header == nil or not header.Visible, "compact bag left economy HUD visible at " .. target.name)
			check(nav == nil or not nav.Visible, "compact bag left navigation HUD visible at " .. target.name)
			local sailing = playerGui:FindFirstChild("SailingUI")
			if sailing then
				local mapButton = sailing:FindFirstChild("MapButton", true)
				local summonButton = sailing:FindFirstChild("SummonButton", true)
				local mapPanel = sailing:FindFirstChild("MapPanel", true)
				check(mapButton == nil or not mapButton.Visible, "compact bag left sailing map HUD visible at " .. target.name)
				check(summonButton == nil or not summonButton.Visible, "compact bag left summon HUD visible at " .. target.name)
				check(mapPanel == nil or not mapPanel.Visible, "compact bag left sailing map panel visible at " .. target.name)
			end
		end
	elseif pageName == "aquarium" then
		local hero = namedGui(main, {"AquariumHero"})
		local list = visibleScroll(main, {"AquariumList"})
		check(hero ~= nil, "aquarium hero missing at " .. target.name)
		check(list ~= nil, "aquarium list missing at " .. target.name)
		if hero then check(withinSafe(hero, viewport()), "aquarium hero leaves safe viewport at " .. target.name) end
	elseif pageName == "merge" then
		local list = visibleScroll(main, {"MergeList"})
		local previewLabel = containsText(main, "从左侧") or containsText(main, "已选择")
		local preview = previewLabel and previewLabel.Parent
		check(list ~= nil, "merge materials missing at " .. target.name)
		check(preview ~= nil and preview:IsA("GuiObject"), "merge preview missing at " .. target.name)
		if list and preview and preview:IsA("GuiObject") then
			check(not overlaps(list, preview), "merge materials/preview overlap at " .. target.name)
		end
	elseif pageName == "index" then
		local list = visibleScroll(main, {"IndexGrid"})
		check(list ~= nil, "index grid missing at " .. target.name)
		if list then
			local entries = 0
			for _, child in list:GetChildren() do
				if child:IsA("TextButton") and string.sub(child.Name, 1, 6) == "Index_" then entries += 1 end
			end
			check(entries == expectedSpeciesCount, "index coverage changed at " .. target.name .. ": " .. tostring(entries))
		end
	elseif pageName == "upgrade" then
		local list = visibleScroll(main, {"UpgradeScroll"})
		local odds = containsButton(main, "概率")
		check(list ~= nil, "upgrade list missing at " .. target.name)
		if list then
			local zones = 0
			for _, child in list:GetChildren() do
				if child:IsA("Frame") and string.sub(child.Name, 1, 5) == "Zone_" then zones += 1 end
			end
			check(zones == expectedZoneCount, "zone coverage changed at " .. target.name .. ": " .. tostring(zones))
		end
		check(odds ~= nil, "upgrade odds action missing at " .. target.name)
		if list and odds then
			check(not odds:IsDescendantOf(list), "upgrade odds footer unexpectedly inside UpgradeScroll at " .. target.name)
			check(not overlaps(list, odds), "upgrade odds footer overlaps scroll at " .. target.name)
		end
	elseif pageName == "shop" then
		check(containsButton(main, "购买") ~= nil or containsButton(main, "暂不可用") ~= nil, "shop action missing at " .. target.name)
	elseif pageName == "odds" then
		check(containsButton(main, "返回升级") ~= nil, "odds back action missing at " .. target.name)
	end
	inspectButtons(gui, target, v)
end

local function inspectBagDetail(gui: ScreenGui, target: any, state: any)
	local firstFish: any = nil
	for _, fish in state.fish or {} do
		if fish.locked ~= true then firstFish = fish; break end
	end
	if not firstFish then
		warn("no unlocked fish available for bag detail at " .. target.name)
		return
	end
	if not invokeHarness("bagSelect", firstFish.id, "bag detail selection") then return end
	waitRender()
	local detail = gui:FindFirstChild("BagDetail", true)
	check(detail ~= nil and detail:IsA("GuiObject") and actuallyVisible(detail), "bag detail selection did not reveal detail at " .. target.name)
	if not detail or not detail:IsA("GuiObject") then return end
	check(containsText(detail, "Lv.") ~= nil, "bag detail stats missing at " .. target.name)
	for _, name in {"PlacementAction", "LockAction", "SaleAction"} do
		local action = detail:FindFirstChild(name, true)
		check(action ~= nil and action:IsA("TextButton") and actuallyVisible(action), "bag detail action missing " .. name .. " at " .. target.name)
		if action and action:IsA("TextButton") and (target.compact or target.touch) then
			check(math.min(action.AbsoluteSize.X, action.AbsoluteSize.Y) >= 44, "bag detail action below 44px " .. name .. " at " .. target.name)
		end
	end
end

local function inspectSelection(gui: ScreenGui, target: any, state: any)
	if not invokeHarness("tab", "合成", "selection tab") then return end
	waitRender()
	if containsText(gui, "已选择 1 / 3") ~= nil then
		return
	end
	local firstFish: any = nil
	for _, fish in state.fish or {} do
		if fish.locked ~= true then firstFish = fish; break end
	end
	if not firstFish then
		warn("no unlocked fish available for selection retention at " .. target.name)
		return
	end
	invokeHarness("mergeSelect", firstFish.id, "merge selection")
	invokeHarness("refresh", nil, "merge refresh")
	waitRender()
	check(containsText(gui, "已选择 1 / 3") ~= nil, "merge selection was not rendered at " .. target.name)
end

local function inspectOrientationRetention(gui: ScreenGui, target: any): boolean
	local function layoutOrientationSimulation(): boolean
		local selectedBefore = containsText(gui, "已选择 1 / 3") ~= nil
		local changed = invokeResponsive("viewport", target.height, target.width, target.touch)
		if changed then waitRender() end
		local restored = invokeResponsive("viewport", target.width, target.height, target.touch)
		if restored then waitRender() end
		local selectionRetained = containsText(gui, "已选择 1 / 3") ~= nil
		local tabRetained = containsText(gui, "三合一") ~= nil
		check(changed and restored, "guarded orientation simulation unavailable at " .. target.name)
		check(not selectedBefore or selectionRetained, "merge selection lost in orientation layout simulation at " .. target.name)
		check(tabRetained, "active merge tab lost in orientation layout simulation at " .. target.name)
		local reset = invokeResponsive("reset", nil, nil, nil)
		if reset then waitRender() end
		print(string.format("MOBILE_ORIENTATION_LAYOUT_SIM: target=%s changed=%s restored=%s selection=%s actualDevice=false", target.name, tostring(changed), tostring(restored), tostring(selectionRetained)))
		return changed and restored and reset and (not selectedBefore or selectionRetained) and tabRetained
	end

	local serviceOk, simulator = pcall(function() return game:GetService("StudioDeviceSimulatorService") end)
	if not serviceOk or simulator == nil then
		return layoutOrientationSimulation()
	end
	local originalOk, original = pcall(function() return (simulator :: any):GetOrientationAsync() end)
	if not originalOk then
		return layoutOrientationSimulation()
	end
	local flipped = if target.orientation == Enum.ScreenOrientation.Portrait then Enum.ScreenOrientation.LandscapeLeft else Enum.ScreenOrientation.Portrait
	local flipOk, flipError = pcall(function() (simulator :: any):SetOrientationAsync(flipped) end)
	if not flipOk then
		warn("device orientation change unavailable at " .. target.name .. ": " .. tostring(flipError))
		return layoutOrientationSimulation()
	end
	local aspectChanged = waitUntil(function()
		local v = viewport()
		return if flipped == Enum.ScreenOrientation.Portrait then v.Y > v.X else v.X > v.Y
	end, 5)
	check(aspectChanged, "orientation did not change at " .. target.name)
	local restoreOk, restoreError = pcall(function() (simulator :: any):SetOrientationAsync(target.orientation) end)
	if not restoreOk then
		warn("device orientation restore failed at " .. target.name .. ": " .. tostring(restoreError))
		return layoutOrientationSimulation()
	end
	local restored = waitUntil(function()
		local v = viewport()
		return math.abs(v.X - target.width) <= 3 and math.abs(v.Y - target.height) <= 3
	end, 5)
	check(restored, "orientation restore viewport mismatch at " .. target.name)
	local selectionRetained = containsText(gui, "已选择 1 / 3") ~= nil
	check(selectionRetained, "merge selection lost across orientation at " .. target.name)
	check(containsText(gui, "三合一") ~= nil, "active merge tab lost across orientation at " .. target.name)
	orientationActual = true
	print(string.format("MOBILE_ORIENTATION_RETENTION: target=%s original=%s flipped=%s restored=%s selection=%s", target.name, tostring(original), tostring(flipped), tostring(restored), tostring(selectionRetained)))
	return aspectChanged and restoreOk and restored and selectionRetained
end

local function runActual(target: any): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		check(false, "camera missing for " .. target.name)
		return false
	end
	local preferredOrientationOk, preferredOrientationError = pcall(function()
		(playerGui :: any).ScreenOrientation = target.orientation
	end)
	print("MOBILE_PLAYERGUI_ORIENTATION: target=" .. target.name .. " ok=" .. tostring(preferredOrientationOk) .. " error=" .. tostring(preferredOrientationError) .. " current=" .. tostring((playerGui :: any).CurrentScreenOrientation))
	local viewportReady = waitUntil(function()
		local v = viewport()
		return math.abs(v.X - target.width) <= 3 and math.abs(v.Y - target.height) <= 3
	end, 8)
	check(viewportReady, "viewport did not settle for " .. target.name)
	waitRender()
	local v = viewport()
	check(math.abs(v.X - target.width) <= 3 and math.abs(v.Y - target.height) <= 3,
		string.format("device viewport mismatch %s expected=%dx%d actual=%dx%d", target.name, target.width, target.height, v.X, v.Y))
	print(string.format("MOBILE_DEVICE_TARGET: %s expected=%dx%d actual=%dx%d", target.name, target.width, target.height, v.X, v.Y))

	local gui = playerGui:FindFirstChild("FishingAquariumUI")
	if not gui or not gui:IsA("ScreenGui") then
		check(false, "FishingAquariumUI missing at " .. target.name)
		return false
	end
	local root = gui:FindFirstChild("ResponsiveRoot", true)
	if root and root:IsA("GuiObject") then
		print(string.format("MOBILE_GUI_ROOT: target=%s position=%.1fx%.1f size=%.1fx%.1f", target.name, root.AbsolutePosition.X, root.AbsolutePosition.Y, root.AbsoluteSize.X, root.AbsoluteSize.Y))
	end
	print(string.format("MOBILE_CAMERA_VIEWPORT: target=%s size=%.1fx%.1f", target.name, viewport().X, viewport().Y))
	local request = ReplicatedStorage:WaitForChild("FishingRemotes"):WaitForChild("Request") :: RemoteFunction
	local state, snapshotReason = readSnapshotBounded(request)
	check(type(state) == "table", "snapshot unavailable at " .. target.name .. ": " .. tostring(snapshotReason))
	if type(state) ~= "table" then return false end
	inspectSelection(gui, target, state)
	inspectOrientationRetention(gui, target)
	inspectNavigation(gui, target, v)
	inspectPage(gui, target, "背包", "背包", "bag")
	inspectBagDetail(gui, target, state)
	inspectPage(gui, target, "水族馆", "水族馆", "aquarium")
	inspectPage(gui, target, "合成", "三合一", "merge")
	inspectPage(gui, target, "图鉴", "鱼类图鉴", "index")
	inspectPage(gui, target, "升级", "升级与水域", "upgrade")
	inspectPage(gui, target, "商店", "商店", "shop")
	inspectPage(gui, target, "概率", "当前掉落概率", "odds")
	invokeHarness("audio", "Music", "audio reachability")
	local audioPanel = gui:FindFirstChild("AudioSettings", true)
	check(audioPanel ~= nil and audioPanel:IsA("GuiObject") and audioPanel.Visible, "audio panel unavailable at " .. target.name)
	inspectButtons(gui, target, viewport())
	invokeHarness("audio", "Music", "audio state restore")
	invokeHarness("close", nil, "return to fishing")
	return true
end

local function runLayoutOnly()
	local purePassed = 0
	for _, target in targets do if layoutProbe(target) then purePassed += 1 end end
	local ready = waitUntil(function() return ReplicatedStorage:GetAttribute("StudioSmokeReady") == true end, 45)
	if not ready then
		warn("StudioSmoke did not finish before layout-only responsive smoke")
		print(string.format("MOBILE_LAYOUT_RUNTIME_SUMMARY: passed=0/%d; device=false input=false blocked=smoke-ready", #targets))
		return
	end
	local gui = playerGui:FindFirstChild("FishingAquariumUI")
	local harnessUsed = false
	local runtimePassed = 0
	if gui and gui:IsA("ScreenGui") then
		local request = ReplicatedStorage:WaitForChild("FishingRemotes"):WaitForChild("Request") :: RemoteFunction
		local state, snapshotReason = readSnapshotBounded(request)
		check(type(state) == "table", "layout-only snapshot unavailable: " .. tostring(snapshotReason))
		if type(state) ~= "table" then
			print(string.format("MOBILE_LAYOUT_RUNTIME_SUMMARY: passed=0/%d; device=false input=false blocked=snapshot", #targets))
			return
		end
		for _, target in targets do
			local beforeFailures = #failures
			local simulated = invokeResponsive("viewport", target.width, target.height, true)
			if not simulated then
				warn("ResponsiveHarness unavailable; target remains layout arithmetic only " .. target.name)
				break
			end
			harnessUsed = true
			simulatedViewport = Vector2.new(target.width, target.height)
			waitRender()
			local root = gui:FindFirstChild("ResponsiveRoot", true)
			local nav = gui:FindFirstChild("NavViewport", true)
			local bag = gui:FindFirstChild("CompactBagButton", true)
			if root and root:IsA("GuiObject") then
				check(math.abs(root.AbsoluteSize.X - target.width) <= 2 and math.abs(root.AbsoluteSize.Y - target.height) <= 2, "simulated root size mismatch " .. target.name)
			end
			if nav and nav:IsA("GuiObject") then check(withinSafe(nav, simulatedViewport), "simulated nav leaves safe root " .. target.name) end
			if target.compact and bag and bag:IsA("GuiObject") then check(withinSafe(bag, simulatedViewport), "simulated compact bag target leaves safe root " .. target.name) end
			inspectSelection(gui, target, state)
			inspectOrientationRetention(gui, target)
			-- The orientation seam restores the root to its safe size. Reapply the
			-- target before measuring every page below.
			invokeResponsive("viewport", target.width, target.height, target.touch)
			simulatedViewport = Vector2.new(target.width, target.height)
			waitRender()
			inspectNavigation(gui, target, simulatedViewport)
			inspectPage(gui, target, "背包", "背包", "bag")
			inspectBagDetail(gui, target, state)
			inspectPage(gui, target, "水族馆", "水族馆", "aquarium")
			inspectPage(gui, target, "合成", "三合一", "merge")
			inspectPage(gui, target, "图鉴", "鱼类图鉴", "index")
			inspectPage(gui, target, "升级", "升级与水域", "upgrade")
			inspectPage(gui, target, "商店", "商店", "shop")
			inspectPage(gui, target, "概率", "当前掉落概率", "odds")
			invokeHarness("audio", "Music", "layout audio reachability")
			local audioPanel = gui:FindFirstChild("AudioSettings", true)
			check(audioPanel ~= nil and audioPanel:IsA("GuiObject") and audioPanel.Visible, "layout audio panel unavailable at " .. target.name)
			inspectButtons(gui, target, simulatedViewport)
			invokeHarness("audio", "Music", "layout audio state restore")
			invokeHarness("close", nil, "layout return to fishing")
			if #failures == beforeFailures then
				runtimePassed += 1
				print(string.format("MOBILE_LAYOUT_RUNTIME_PASS: target=%s device=false input=false", target.name))
			else
				print(string.format("MOBILE_LAYOUT_RUNTIME_FAIL: target=%s newFailures=%d device=false input=false", target.name, #failures - beforeFailures))
			end
		end
		invokeResponsive("reset", nil, nil, nil)
		waitRender()
		simulatedViewport = nil
	else
		harnessUsed = false
	end
	print(string.format("MOBILE_LAYOUT_RUNTIME_SUMMARY: passed=%d/%d pure=%d/%d harness=%s; device=false input=false", runtimePassed, #targets, purePassed, #targets, tostring(harnessUsed)))
end

local function run(): ()
	assert(RunService:IsStudio(), "ResponsiveSmoke must run in Studio")
	local target = activeTarget()
	if not target then
		runLayoutOnly()
		return
	end
	assert(waitUntil(function() return ReplicatedStorage:GetAttribute("StudioSmokeReady") == true end, 45),
		"StudioSmoke did not finish before responsive smoke deadline")
	local started = os.clock()
	local ok, errorText = xpcall(function() runActual(target) end, debug.traceback)
	if not ok then check(false, "responsive target crashed " .. target.name .. ": " .. tostring(errorText)) end
	print(string.format("MOBILE_TARGET_DONE: %s elapsed=%.2f failures=%d warnings=%d", target.name, os.clock() - started, #failures, #warnings))
	if #failures == 0 then
		print("MOBILE_RESPONSIVE_PASS: target=" .. target.name .. " actual DeviceSimulator viewport and GUI checks; orientation=" .. (if orientationActual then "device" else "layout-simulation"))
	else
		warn("MOBILE_RESPONSIVE_FAIL: target=" .. target.name .. " failures=" .. tostring(#failures))
	end
end

local ok, errorText = xpcall(run, debug.traceback)
if not ok then warn("MOBILE_RESPONSIVE_FAIL: harness crashed: " .. tostring(errorText)) end
