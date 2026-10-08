-- Independent sailing HUD. It never edits FishingAquariumUI's layout and it
-- never sends the legacy travel action: a map click only selects a destination
-- and shows the server-authoritative direction/distance while the player sails.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("BoatRemotes")
local request = remotes:WaitForChild("Request") :: RemoteFunction
local intent = remotes:WaitForChild("Intent") :: RemoteEvent
local stateEvent = remotes:WaitForChild("State") :: RemoteEvent
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local UiStyle = require(shared:WaitForChild("UiStyle"))
local SailingHudState = require(shared:WaitForChild("SailingHudState"))

local map: any = nil
local boatState: any = {active = false, driving = false}
local fishingSnapshotZone: number? = nil
local selectedZone = 1
local mapOpen = false
local hudState = SailingHudState.new()
local pendingNeutral = false
local clearInput: any = nil
local legacyVisibilitySaved: boolean? = nil
local legacyVisibilityInstance: ScreenGui? = nil
local legacyVisibilityToken: string? = nil
local touchGuiVisibilitySaved: boolean? = nil
local touchGuiVisibilityInstance: ScreenGui? = nil
local touchGuiVisibilityToken: string? = nil
-- Persist ownership on the exact GUI instance so a replacement Sailing script
-- can take over safely while an old Deferred cleanup becomes a no-op.
local visibilityOwnerToken = tostring(script) .. ":" .. tostring(os.clock())
local ownedSailingGui: ScreenGui? = nil
local SAILING_GUI_OWNER = "SailingGuiOwner"
local LEGACY_VISIBILITY_TOKEN = "SailingLegacyVisibilityOwner"
local LEGACY_VISIBILITY_SAVED = "SailingLegacyVisibilitySaved"
local TOUCH_VISIBILITY_TOKEN = "SailingTouchVisibilityOwner"
local TOUCH_VISIBILITY_SAVED = "SailingTouchVisibilitySaved"
local PROMPT_STYLE_OWNER = "SailingPromptStyleOwner"
local PROMPT_STYLE_SAVED = "SailingPromptStyleSaved"
local keys: {[Enum.KeyCode]: boolean} = {}
local touchHeld: {[string]: boolean} = {}
local lastIntentAt = 0
local sentMovingIntent = false
local mapSignature = ""
local renderedUnlock = -1
local lastViewportKey = ""
local lastDockCheckAt = 0
local toastUntil = 0
local qaMode = false
local updateStatus: any = nil
local lifecycle = {alive = true, generation = 0, characterGeneration = 0, characterReady = player.Character ~= nil, openingPage = false, openingToken = 0, connections = {}, redrawChart = nil}
local summonPromptStyles: {[ProximityPrompt]: {previousStyle: Enum.ProximityPromptStyle, token: string}} = {}
local summonPromptAddedConnection: RBXScriptConnection? = nil
local summonPromptShownConnection: RBXScriptConnection? = nil
local fishingGuiAddedConnection: RBXScriptConnection? = nil
local fishingGuiRemovedConnection: RBXScriptConnection? = nil
local fishingGuiEnabledConnection: RBXScriptConnection? = nil
local fishingPanelConnection: RBXScriptConnection? = nil
local fishingGuiAttributeConnection: RBXScriptConnection? = nil
local fishingGuiDescendantConnection: RBXScriptConnection? = nil
local fishingGui: ScreenGui? = nil
local fishingPanel: GuiObject? = nil
local openPageBridge: BindableEvent? = nil
local fishingPanelOpen = false
local legacyHiddenBySailing = false
if RunService:IsStudio() then
	local qaSibling = script.Parent:FindFirstChild("SailingSmoke") or script.Parent:WaitForChild("SailingSmoke", 3)
	qaMode = qaSibling ~= nil
end
local qaInput: {throttle: number, steer: number}? = nil

local function ownsCurrentSailingGui(): boolean
	local current = ownedSailingGui
	return lifecycle.alive
		and current ~= nil
		and current.Parent == playerGui
		and playerGui:FindFirstChild("SailingUI") == current
		and current:GetAttribute(SAILING_GUI_OWNER) == visibilityOwnerToken
end

local function ownsCapturedSailingGui(expectedGui: ScreenGui?, expectedGeneration: number?, expectedToken: string?): boolean
	return ownsCurrentSailingGui()
		and ownedSailingGui == expectedGui
		and (expectedGeneration == nil or lifecycle.generation == expectedGeneration)
		and (expectedToken == nil or visibilityOwnerToken == expectedToken)
end

local function trackConnection(key: string, signal: any, callback: any): any
	local previous = lifecycle.connections[key]
	if previous then previous:Disconnect() end
	-- Long-lived signals belong to this exact SailingUI instance. An old
	-- connection can otherwise run between Instance:Destroy() and its deferred
	-- cleanup and mutate a replacement UI.
	local connection = signal:Connect(function(...)
		if not ownsCurrentSailingGui() then return end
		callback(...)
	end)
	lifecycle.connections[key] = connection
	return connection
end

local function disconnectConnection(key: string)
	local connection = lifecycle.connections[key]
	if connection then connection:Disconnect(); lifecycle.connections[key] = nil end
end

local function stopLifecycle()
	if not lifecycle.alive then return end
	lifecycle.alive = false
	lifecycle.generation += 1
	for key, connection in pairs(lifecycle.connections) do
		connection:Disconnect()
		lifecycle.connections[key] = nil
	end
end

local palette = {
	ink = Color3.fromRGB(20, 48, 66),
	ink2 = Color3.fromRGB(31, 68, 85),
	cream = Color3.fromRGB(255, 248, 229),
	sea = Color3.fromRGB(94, 203, 193),
	gold = Color3.fromRGB(238, 177, 73),
	green = Color3.fromRGB(87, 201, 142),
	muted = Color3.fromRGB(119, 143, 148),
	locked = Color3.fromRGB(97, 110, 117),
	red = Color3.fromRGB(209, 95, 91),
	map = Color3.fromRGB(151, 206, 203),
}

local buttonStyles: {[TextButton]: {color: Color3, selected: boolean, tween: any}} = {}

local function stopButtonTween(style: any)
	if style and style.tween then
		style.tween:Cancel()
		style.tween = nil
	end
end

local function animateButton(item: TextButton, style: any, properties: {[string]: any})
	stopButtonTween(style)
	local tween = TweenService:Create(item, TweenInfo.new(.12), properties)
	style.tween = tween
	tween.Completed:Connect(function()
		if buttonStyles[item] == style and style.tween == tween then style.tween = nil end
	end)
	tween:Play()
end

local function buttonTransparency(state: string): number
	return UiStyle.buttonTransparency(state)
end

local function rounded(instance: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function stroke(instance: Instance, color: Color3, transparency: number?)
	local line = Instance.new("UIStroke")
	line.Color = color
	line.Transparency = transparency or 0
	line.Thickness = 1
	line.Parent = instance
end

local function label(parent: Instance, text: string, size: number, textColor: Color3, bold: boolean?): TextLabel
	local item = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	item.Text = text
	item.TextSize = size
	item.TextColor3 = textColor
	item.TextWrapped = true
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextYAlignment = Enum.TextYAlignment.Center
	item.Parent = parent
	return item
end

local function button(parent: Instance, text: string, buttonColor: Color3, selected: boolean?): TextButton
	local item = Instance.new("TextButton")
	item.AutoButtonColor = false
	item.BackgroundColor3 = buttonColor
	item.BackgroundTransparency = buttonTransparency(if selected then "selected" else "normal")
	item.BorderSizePixel = 0
	item.Font = Enum.Font.GothamBold
	item.Text = text
	item.TextColor3 = palette.cream
	item.TextTransparency = 0
	item.TextStrokeColor3 = palette.ink
	item.TextStrokeTransparency = .78
	item.TextSize = 14
	item.Active = true
	item.Selectable = true
	buttonStyles[item] = {color = buttonColor, selected = selected == true, tween = nil}
	item.Destroying:Connect(function()
		local style = buttonStyles[item]
		stopButtonTween(style)
		buttonStyles[item] = nil
	end)
	item.Parent = parent
	rounded(item, 12)
	item.MouseEnter:Connect(function()
		local style = buttonStyles[item]
		if style then
			animateButton(item, style, {
				BackgroundColor3 = style.color:Lerp(Color3.new(1, 1, 1), .12),
				BackgroundTransparency = buttonTransparency(if style.selected then "selected" else "hover"),
			})
		end
	end)
	item.MouseLeave:Connect(function()
		local style = buttonStyles[item]
		if style then
			animateButton(item, style, {
				BackgroundColor3 = style.color,
				BackgroundTransparency = buttonTransparency(if style.selected then "selected" else "normal"),
			})
		end
	end)
	return item
end

local old = playerGui:FindFirstChild("SailingUI")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "SailingUI"
gui.DisplayOrder = 40
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ownedSailingGui = gui
gui:SetAttribute(SAILING_GUI_OWNER, visibilityOwnerToken)
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "SafeRoot"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundTransparency = 1
root.Parent = gui

local status = Instance.new("Frame")
status.Name = "SailingStatus"
status.AnchorPoint = Vector2.new(0, 0)
status.Position = UDim2.fromOffset(18, 18)
status.Size = UDim2.fromOffset(250, 76)
status.BackgroundColor3 = palette.ink
status.BackgroundTransparency = .08
status.BorderSizePixel = 0
status.Visible = false
status.Parent = root
rounded(status, 16)
stroke(status, palette.sea, .35)
local statusTitle = label(status, "", 16, palette.cream, true)
statusTitle.Position = UDim2.fromOffset(14, 8)
statusTitle.Size = UDim2.new(1, -28, 0, 26)
local statusDetail = label(status, "", 12, palette.map, false)
statusDetail.Position = UDim2.fromOffset(14, 37)
statusDetail.Size = UDim2.new(1, -28, 0, 28)

local toast = label(root, "", 13, palette.cream, true)
toast.Name = "SailingNotice"
toast.AnchorPoint = Vector2.new(.5, 0)
toast.Position = UDim2.new(.5, 0, 0, 18)
toast.Size = UDim2.fromOffset(360, 42)
toast.BackgroundColor3 = palette.ink
toast.BackgroundTransparency = .08
toast.BorderSizePixel = 0
toast.TextXAlignment = Enum.TextXAlignment.Center
toast.Visible = false
rounded(toast, 12)
stroke(toast, palette.gold, .35)

local mapButton = button(root, "海图", palette.ink2)
mapButton.Name = "MapButton"
mapButton.AnchorPoint = Vector2.new(1, 0)
mapButton.Position = UDim2.new(1, -18, 0, 112)
mapButton.Size = UDim2.fromOffset(62, 48)
mapButton.TextSize = 15

local bagButton = button(root, "背包", palette.sea)
bagButton.Name = "BagButton"
bagButton.AnchorPoint = Vector2.new(1, 0)
bagButton.Position = UDim2.new(1, -18, 0, 56)
bagButton.Size = UDim2.fromOffset(62, 44)
bagButton.TextSize = 14
bagButton.Visible = false

local summonButton = button(root, "召唤免费帆船", palette.sea)
summonButton.Name = "SummonButton"
summonButton.AnchorPoint = Vector2.new(1, 0)
summonButton.Position = UDim2.new(1, -18, 0, 168)
summonButton.Size = UDim2.fromOffset(154, 48)
summonButton.Visible = false

local function isSummonPrompt(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("ProximityPrompt") and instance.Name == "SummonBoatPrompt" and instance:FindFirstAncestor("SailingDocks") ~= nil
end

local function customSummonHudAvailable(): boolean
	return gui.Parent == playerGui and gui.Enabled and summonButton.Parent == root
end

local function promptStyleName(style: Enum.ProximityPromptStyle): string
	return if style == Enum.ProximityPromptStyle.Custom then "Custom" else "Default"
end

local function promptStyleFromName(value: any): Enum.ProximityPromptStyle?
	if value == "Custom" then return Enum.ProximityPromptStyle.Custom end
	if value == "Default" then return Enum.ProximityPromptStyle.Default end
	return nil
end

local function syncSummonPromptStyles()
	local custom = customSummonHudAvailable()
	for prompt, record in pairs(summonPromptStyles) do
		if prompt.Parent == nil then
			summonPromptStyles[prompt] = nil
		elseif record.token ~= visibilityOwnerToken
			or prompt:GetAttribute(PROMPT_STYLE_OWNER) ~= visibilityOwnerToken then
			-- A replacement SailingUI owns this prompt now.  The old script must
			-- not restore its native style over the replacement's custom state.
			summonPromptStyles[prompt] = nil
		elseif custom then
			pcall(function() prompt.Style = Enum.ProximityPromptStyle.Custom end)
		else
			pcall(function() prompt.Style = record.previousStyle end)
		end
	end
end

local function registerSummonPrompt(prompt: ProximityPrompt)
	if not isSummonPrompt(prompt) then return end
	local record = summonPromptStyles[prompt]
	if record == nil or record.token ~= visibilityOwnerToken
		or prompt:GetAttribute(PROMPT_STYLE_OWNER) ~= visibilityOwnerToken then
		local inherited = promptStyleFromName(prompt:GetAttribute(PROMPT_STYLE_SAVED))
		local previous = inherited or (record and record.previousStyle) or prompt.Style
		record = {previousStyle = previous, token = visibilityOwnerToken}
		summonPromptStyles[prompt] = record
		prompt:SetAttribute(PROMPT_STYLE_OWNER, visibilityOwnerToken)
		prompt:SetAttribute(PROMPT_STYLE_SAVED, promptStyleName(previous))
	end
	syncSummonPromptStyles()
end

local function restoreSummonPromptStyles()
	for prompt, record in pairs(summonPromptStyles) do
		if prompt.Parent ~= nil
			and record.token == visibilityOwnerToken
			and prompt:GetAttribute(PROMPT_STYLE_OWNER) == visibilityOwnerToken then
			pcall(function() prompt.Style = record.previousStyle end)
			prompt:SetAttribute(PROMPT_STYLE_OWNER, nil)
			prompt:SetAttribute(PROMPT_STYLE_SAVED, nil)
		end
	end
	table.clear(summonPromptStyles)
end

local function refreshBoatHud()
	if updateStatus then updateStatus() end
end

local function syncHudState()
	local nextState, effect = SailingHudState.transition(hudState, {
		kind = "driving",
		value = boatState.active == true and boatState.driving == true,
	})
	hudState = nextState
	if effect.neutral then
		if clearInput then clearInput(true, true) else pendingNeutral = true end
	end
	nextState, effect = SailingHudState.transition(hudState, {kind = "map", value = mapOpen})
	hudState = nextState
	if effect.neutral then
		if clearInput then clearInput(true, true) else pendingNeutral = true end
	end
	nextState, effect = SailingHudState.transition(hudState, {kind = "panel", value = fishingPanelOpen})
	hudState = nextState
	if effect.neutral then
		if clearInput then clearInput(true, true) else pendingNeutral = true end
	end
end

local function updateFishingPanelState()
	if not lifecycle.alive then return end
	local visible = fishingPanel ~= nil and fishingPanel.Visible
	local advertised = if fishingGui then fishingGui:GetAttribute("PanelOpen") else nil
	local enabled = fishingGui ~= nil and fishingGui.Enabled
	local nextOpen = SailingHudState.effectivePanelOpen(enabled, visible, advertised)
	local wasOpen = fishingPanelOpen
	-- An external owner can disable the legacy ScreenGui while a panel is open.
	-- Close that blocking context once, then allow the next explicit bag intent
	-- to re-enable the GUI through requestFishingPage.
	if wasOpen and not nextOpen and enabled ~= true and not lifecycle.openingPage then
		if fishingPanel then fishingPanel.Visible = false end
		if fishingGui then fishingGui:SetAttribute("PanelOpen", false) end
	end
	fishingPanelOpen = nextOpen
	if fishingPanelOpen and mapOpen then
		mapOpen = false
	end
	syncHudState()
	refreshBoatHud()
end

local function readFishingSnapshotZone(boundGui: ScreenGui?): number?
	if not boundGui or boundGui.Parent ~= playerGui or playerGui:FindFirstChild("FishingAquariumUI") ~= boundGui then return nil end
	local value = boundGui:GetAttribute("FishingSnapshotZone")
	if value == nil then return nil end
	return SailingHudState.validatedZone(value, #Config.Zones)
end

local function ownsBoundFishingGui(boundGui: ScreenGui?, expectedGeneration: number): boolean
	return lifecycle.alive
		and fishingGui == boundGui
		and boundGui ~= nil
		and boundGui.Parent == playerGui
		and playerGui:FindFirstChild("FishingAquariumUI") == boundGui
		and lifecycle.generation == expectedGeneration
end

local function updateFishingSnapshotProjection(boundGui: ScreenGui?): boolean
	local nextZone = readFishingSnapshotZone(boundGui)
	if nextZone == fishingSnapshotZone then return false end
	fishingSnapshotZone = nextZone
	renderedUnlock = -1
	if mapOpen and lifecycle.redrawChart then lifecycle.redrawChart() end
	return true
end

local function bindFishingPanel()
	if not ownsCurrentSailingGui() then return end
	local candidate = playerGui:FindFirstChild("FishingAquariumUI")
	local nextGui: ScreenGui? = if candidate and candidate:IsA("ScreenGui") then candidate else nil
	local foundPanel = if candidate then candidate:FindFirstChild("ContentPanel", true) else nil
	local nextPanel: GuiObject? = if foundPanel and foundPanel:IsA("GuiObject") then foundPanel else nil
	if nextPanel == fishingPanel and nextGui == fishingGui then
		updateFishingSnapshotProjection(nextGui)
		openPageBridge = nil
		if nextGui then
			local bridge = nextGui:FindFirstChild("OpenPage", true)
			if bridge and bridge:IsA("BindableEvent") then openPageBridge = bridge end
		end
		updateFishingPanelState()
		refreshBoatHud()
		return
	end
	disconnectConnection("fishingPanel")
	disconnectConnection("fishingGuiEnabled")
	disconnectConnection("fishingGuiAttribute")
	disconnectConnection("fishingGuiDescendant")
	fishingPanelConnection = nil
	fishingGuiEnabledConnection = nil
	fishingGuiAttributeConnection = nil
	fishingGuiDescendantConnection = nil
	fishingGui = nextGui
	fishingPanel = nextPanel
	updateFishingSnapshotProjection(fishingGui)
	openPageBridge = nil
	if fishingGui then
		local boundGui = fishingGui
		local boundGeneration = lifecycle.generation
		local bridge = fishingGui:FindFirstChild("OpenPage", true)
		if bridge and bridge:IsA("BindableEvent") then openPageBridge = bridge end
		fishingGuiEnabledConnection = trackConnection("fishingGuiEnabled", fishingGui:GetPropertyChangedSignal("Enabled"), function()
			if not ownsBoundFishingGui(boundGui, boundGeneration) then return end
			updateFishingPanelState()
		end)
		fishingGuiAttributeConnection = trackConnection("fishingGuiAttribute", fishingGui.AttributeChanged, function(attributeName)
			if not ownsBoundFishingGui(boundGui, boundGeneration) then return end
			if attributeName == "FishingSnapshotZone" then
				if updateFishingSnapshotProjection(boundGui) then refreshBoatHud() end
			elseif attributeName == "PanelOpen" or attributeName == "ActiveTab" then
				updateFishingPanelState()
			end
		end)
		fishingGuiDescendantConnection = trackConnection("fishingGuiDescendant", fishingGui.DescendantAdded, function(child)
			if not ownsBoundFishingGui(boundGui, boundGeneration) then return end
			if child.Name == "ContentPanel" or child.Name == "OpenPage" then
				local generation = boundGeneration
				task.defer(function()
					if ownsCurrentSailingGui() and ownsBoundFishingGui(boundGui, generation) then bindFishingPanel() end
				end)
			end
		end)
	end
	if fishingPanel then
		local boundPanel = fishingPanel
		local boundGui = fishingGui
		local boundGeneration = lifecycle.generation
		fishingPanelConnection = trackConnection("fishingPanel", fishingPanel:GetPropertyChangedSignal("Visible"), function()
			if not ownsBoundFishingGui(boundGui, boundGeneration) or fishingPanel ~= boundPanel then return end
			updateFishingPanelState()
		end)
	end
	updateFishingPanelState()
end

local closingContextPanel = false
local function closeContextPanel()
	if not lifecycle.alive or not fishingPanelOpen or closingContextPanel then return end
	closingContextPanel = true
	local bridge = openPageBridge
	if bridge and bridge.Parent then
		pcall(function() bridge:Fire("钓鱼") end)
	end
	closingContextPanel = false
	-- If the page bridge was not available during a GUI replacement, still
	-- clear the visible local panel and let the next bind reconcile attributes.
	if fishingPanelOpen then
		if fishingPanel then fishingPanel.Visible = false end
		if fishingGui then fishingGui:SetAttribute("PanelOpen", false) end
		fishingPanelOpen = false
	end
end

local controls = Instance.new("Frame")
controls.Name = "BoatControls"
controls.AnchorPoint = Vector2.new(.5, 1)
controls.Position = UDim2.new(.5, 0, 1, -26)
controls.Size = UDim2.fromOffset(304, 122)
controls.BackgroundTransparency = 1
controls.Visible = false
controls.Parent = root

local throttlePanel = Instance.new("Frame")
throttlePanel.Name = "ThrottlePanel"
throttlePanel.Size = UDim2.fromOffset(184, 114)
throttlePanel.Position = UDim2.fromOffset(0, 4)
throttlePanel.BackgroundColor3 = palette.ink
throttlePanel.BackgroundTransparency = .08
throttlePanel.BorderSizePixel = 0
throttlePanel.Parent = controls
rounded(throttlePanel, 18)
stroke(throttlePanel, palette.sea, .4)
local throttleHint = label(throttlePanel, "航行", 12, palette.map, true)
throttleHint.Position = UDim2.fromOffset(14, 8)
throttleHint.Size = UDim2.fromOffset(50, 22)

local reverseButton = button(throttlePanel, "后退", palette.ink2)
reverseButton.Name = "Reverse"
reverseButton.Position = UDim2.fromOffset(12, 43)
reverseButton.Size = UDim2.fromOffset(74, 54)
reverseButton.TextSize = 15
local forwardButton = button(throttlePanel, "前进", palette.sea)
forwardButton.Name = "Forward"
forwardButton.Position = UDim2.fromOffset(96, 43)
forwardButton.Size = UDim2.fromOffset(74, 54)
forwardButton.TextSize = 15

local steerPanel = Instance.new("Frame")
steerPanel.Name = "SteerPanel"
steerPanel.AnchorPoint = Vector2.new(1, 0)
steerPanel.Position = UDim2.new(1, 0, 0, 4)
steerPanel.Size = UDim2.fromOffset(116, 114)
steerPanel.BackgroundColor3 = palette.ink
steerPanel.BackgroundTransparency = .08
steerPanel.BorderSizePixel = 0
steerPanel.Parent = controls
rounded(steerPanel, 18)
stroke(steerPanel, palette.sea, .4)
local steerHint = label(steerPanel, "转向", 12, palette.map, true)
steerHint.Position = UDim2.fromOffset(14, 8)
steerHint.Size = UDim2.fromOffset(60, 22)
local leftButton = button(steerPanel, "◀", palette.ink2)
leftButton.Name = "Left"
leftButton.Position = UDim2.fromOffset(8, 43)
leftButton.Size = UDim2.fromOffset(48, 54)
leftButton.TextSize = 20
local rightButton = button(steerPanel, "▶", palette.ink2)
rightButton.Name = "Right"
rightButton.Position = UDim2.fromOffset(60, 43)
rightButton.Size = UDim2.fromOffset(48, 54)
rightButton.TextSize = 20

local exitButton = button(root, "下船", palette.red)
exitButton.Name = "LeaveBoat"
exitButton.AnchorPoint = Vector2.new(1, 1)
exitButton.Position = UDim2.new(1, -18, 0, 282)
exitButton.Size = UDim2.fromOffset(76, 48)
exitButton.Visible = false

local returnButton = button(root, "返航港湾", palette.ink2)
returnButton.Name = "ReturnHarbor"
returnButton.AnchorPoint = Vector2.new(1, 0)
returnButton.Position = UDim2.new(1, -18, 0, 172)
returnButton.Size = UDim2.fromOffset(112, 48)
returnButton.Visible = false

local mapPanel = Instance.new("Frame")
mapPanel.Name = "MapPanel"
mapPanel.AnchorPoint = Vector2.new(.5, .5)
mapPanel.Position = UDim2.fromScale(.5, .5)
-- The scale contract keeps the panel inside both the 736x414 landscape and
-- 414x736 portrait QA viewports; UISizeConstraint caps desktop tablets while
-- layoutMapPanel arranges the chart/detail columns from the safe root size.
mapPanel.Size = UDim2.new(.92, 0, .75, 0)
mapPanel.BackgroundColor3 = palette.ink
mapPanel.BackgroundTransparency = UiStyle.panelTransparency
mapPanel.BorderSizePixel = 0
mapPanel.Visible = false
mapPanel.Parent = root
rounded(mapPanel, 20)
stroke(mapPanel, palette.sea, .25)
local mapSizeConstraint = Instance.new("UISizeConstraint")
mapSizeConstraint.MinSize = Vector2.new(280, 300)
mapSizeConstraint.MaxSize = Vector2.new(700, 560)
mapSizeConstraint.Parent = mapPanel

local mapTitle = label(mapPanel, "海图 · 航行目的地", 18, palette.cream, true)
mapTitle.Position = UDim2.fromOffset(18, 14)
mapTitle.Size = UDim2.new(1, -80, 0, 30)
local mapClose = button(mapPanel, "×", palette.ink2)
mapClose.Name = "MapClose"
mapClose.AnchorPoint = Vector2.new(1, 0)
mapClose.Position = UDim2.new(1, -12, 0, 12)
mapClose.Size = UDim2.fromOffset(44, 44)
mapClose.TextSize = 24

local chart = Instance.new("Frame")
chart.Name = "Chart"
chart.Position = UDim2.fromOffset(18, 58)
chart.Size = UDim2.new(1, -36, 0, 286)
chart.BackgroundColor3 = Color3.fromRGB(31, 97, 112)
chart.BackgroundTransparency = .15
chart.BorderSizePixel = 0
chart.ClipsDescendants = true
chart.Parent = mapPanel
rounded(chart, 16)

local chartHint = label(chart, "选择目的地查看航向；航行不会跳过钓鱼解锁。", 11, palette.cream, false)
chartHint.Position = UDim2.fromOffset(12, 8)
chartHint.Size = UDim2.new(1, -24, 0, 22)

local destination = label(mapPanel, "", 13, palette.cream, true)
destination.Position = UDim2.fromOffset(18, 356)
destination.Size = UDim2.new(1, -36, 0, 56)

local mapActionHint = label(mapPanel, "", 12, palette.map, false)
mapActionHint.Position = UDim2.fromOffset(18, 414)
mapActionHint.Size = UDim2.new(1, -36, 0, 28)

local function adoptInheritedLegacyVisibility()
	if legacyVisibilityInstance ~= nil then return end
	local legacy = playerGui:FindFirstChild("FishingAquariumUI")
	if not legacy or not legacy:IsA("ScreenGui") then return end
	local saved = legacy:GetAttribute(LEGACY_VISIBILITY_SAVED)
	local previousOwner = legacy:GetAttribute(LEGACY_VISIBILITY_TOKEN)
	if previousOwner == nil or type(saved) ~= "boolean" then return end
	-- This is an explicit current-lifecycle handoff, not cleanup fallback:
	-- claim the inherited marker before restoring it so a late old Destroying
	-- callback cannot touch this instance or clear its responsibility.
	legacyVisibilityInstance = legacy
	legacyVisibilityToken = visibilityOwnerToken
	legacyVisibilitySaved = saved
	legacyHiddenBySailing = true
	legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, visibilityOwnerToken)
	legacy.Enabled = saved
	legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, nil)
	legacy:SetAttribute(LEGACY_VISIBILITY_SAVED, nil)
	legacyVisibilityInstance = nil
	legacyVisibilityToken = nil
	legacyVisibilitySaved = nil
	legacyHiddenBySailing = false
end

local function hideLegacy(hidden: boolean)
	local legacy = playerGui:FindFirstChild("FishingAquariumUI")
	if hidden then
		if lifecycle.openingPage or not legacy or not legacy:IsA("ScreenGui") then return end
		if legacyVisibilityInstance ~= legacy then
			-- Finalize only the exact object previously owned by this lifecycle.
			-- A same-name replacement is never looked up or restored here.
			if legacyVisibilityInstance and legacyVisibilityToken
				and SailingHudState.ownsVisibility(legacyVisibilityInstance, legacyVisibilityToken,
					legacyVisibilityInstance, legacyVisibilityInstance:GetAttribute(LEGACY_VISIBILITY_TOKEN)) then
				legacyVisibilityInstance:SetAttribute(LEGACY_VISIBILITY_TOKEN, nil)
				legacyVisibilityInstance:SetAttribute(LEGACY_VISIBILITY_SAVED, nil)
			end
			local saved = legacy:GetAttribute(LEGACY_VISIBILITY_SAVED)
			legacyVisibilitySaved = if type(saved) == "boolean" then saved else legacy.Enabled
			legacyVisibilityInstance = legacy
			legacyVisibilityToken = visibilityOwnerToken
			legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, visibilityOwnerToken)
			legacy:SetAttribute(LEGACY_VISIBILITY_SAVED, legacyVisibilitySaved)
			legacyHiddenBySailing = true
		elseif not legacyHiddenBySailing then
			legacyVisibilitySaved = legacy.Enabled
			legacyVisibilityToken = visibilityOwnerToken
			legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, visibilityOwnerToken)
			legacy:SetAttribute(LEGACY_VISIBILITY_SAVED, legacyVisibilitySaved)
			legacyHiddenBySailing = true
		end
		legacy.Enabled = false
	elseif legacyHiddenBySailing then
		local ownedInstance = legacyVisibilityInstance
		local ownedToken = legacyVisibilityToken
		local saved = legacyVisibilitySaved
		legacyVisibilitySaved = nil
		legacyVisibilityInstance = nil
		legacyVisibilityToken = nil
		legacyHiddenBySailing = false
		if ownedInstance and ownedInstance.Parent and ownedToken
			and SailingHudState.ownsVisibility(ownedInstance, ownedToken, ownedInstance,
				ownedInstance:GetAttribute(LEGACY_VISIBILITY_TOKEN)) then
			ownedInstance.Enabled = saved ~= false
			ownedInstance:SetAttribute(LEGACY_VISIBILITY_TOKEN, nil)
			ownedInstance:SetAttribute(LEGACY_VISIBILITY_SAVED, nil)
		end
	end
end

local function enableLegacyForPanel()
	local legacy = playerGui:FindFirstChild("FishingAquariumUI")
	if legacy and legacy:IsA("ScreenGui") then
		-- Claim the exact instance before enabling it. If an old Sailing script
		-- left an owner marker, its later cleanup becomes a no-op.
		legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, visibilityOwnerToken)
		legacy.Enabled = true
		legacy:SetAttribute(LEGACY_VISIBILITY_TOKEN, nil)
		legacy:SetAttribute(LEGACY_VISIBILITY_SAVED, nil)
		legacyVisibilitySaved = nil
		legacyVisibilityInstance = nil
		legacyVisibilityToken = nil
		legacyHiddenBySailing = false
	end
end

local function hideTouchGui(hidden: boolean)
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if hidden then
		if touchGui and touchGui:IsA("ScreenGui") then
			if touchGuiVisibilityInstance ~= touchGui then
				local saved = touchGui:GetAttribute(TOUCH_VISIBILITY_SAVED)
				touchGuiVisibilitySaved = if type(saved) == "boolean" then saved else touchGui.Enabled
				touchGuiVisibilityInstance = touchGui
				touchGuiVisibilityToken = visibilityOwnerToken
				touchGui:SetAttribute(TOUCH_VISIBILITY_TOKEN, visibilityOwnerToken)
				touchGui:SetAttribute(TOUCH_VISIBILITY_SAVED, touchGuiVisibilitySaved)
			end
			touchGui.Enabled = false
		end
	elseif touchGuiVisibilitySaved ~= nil then
		local ownedInstance = touchGuiVisibilityInstance
		local ownedToken = touchGuiVisibilityToken
		local saved = touchGuiVisibilitySaved
		touchGuiVisibilitySaved = nil
		touchGuiVisibilityInstance = nil
		touchGuiVisibilityToken = nil
		if ownedInstance and ownedInstance.Parent and ownedToken
			and SailingHudState.ownsVisibility(ownedInstance, ownedToken, ownedInstance,
				ownedInstance:GetAttribute(TOUCH_VISIBILITY_TOKEN)) then
			ownedInstance.Enabled = saved == true
			ownedInstance:SetAttribute(TOUCH_VISIBILITY_TOKEN, nil)
			ownedInstance:SetAttribute(TOUCH_VISIBILITY_SAVED, nil)
		end
	end
end

local function adoptInheritedTouchGuiVisibility()
	if touchGuiVisibilityInstance ~= nil then return end
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if not touchGui or not touchGui:IsA("ScreenGui") then return end
	local saved = touchGui:GetAttribute(TOUCH_VISIBILITY_SAVED)
	local previousOwner = touchGui:GetAttribute(TOUCH_VISIBILITY_TOKEN)
	if previousOwner == nil or type(saved) ~= "boolean" then return end
	-- See adoptInheritedLegacyVisibility: transfer the exact instance/token in
	-- the current lifecycle before restoring an inherited hidden state.
	touchGuiVisibilityInstance = touchGui
	touchGuiVisibilityToken = visibilityOwnerToken
	touchGuiVisibilitySaved = saved
	touchGui:SetAttribute(TOUCH_VISIBILITY_TOKEN, visibilityOwnerToken)
	touchGui.Enabled = saved
	touchGui:SetAttribute(TOUCH_VISIBILITY_TOKEN, nil)
	touchGui:SetAttribute(TOUCH_VISIBILITY_SAVED, nil)
	touchGuiVisibilityInstance = nil
	touchGuiVisibilityToken = nil
	touchGuiVisibilitySaved = nil
end

local function showNotice(message: string?, duration: number?)
	if not lifecycle.alive or not message or message == "" then return end
	toast.Text = message
	toast.Visible = true
	toastUntil = os.clock() + (duration or 2.4)
	local generation = lifecycle.generation
	task.delay(duration or 2.4, function()
		if ownsCurrentSailingGui() and lifecycle.generation == generation and os.clock() >= toastUntil then toast.Visible = false end
	end)
end

local function currentUnlock(): number
	return SailingHudState.validatedZone(fishingSnapshotZone, #Config.Zones)
end

local function fallbackMap(): any
	local zones = {}
	local layoutModule = shared:FindFirstChild("WorldLayout")
	local layout = if layoutModule then require(layoutModule) else nil
	for id, zone in ipairs(Config.Zones) do
		local geometry = layout and layout.Zones and layout.Zones[id]
		local center = zone.center or {x = 0, z = 0}
		table.insert(zones, {
			id = id,
			name = zone.name or ("水域 " .. tostring(id)),
			x = center.x,
			z = center.z,
			shape = geometry and geometry.shape,
			width = geometry and geometry.width,
			depth = geometry and geometry.depth,
			cost = zone.cost,
			requiredDiscoveries = zone.requiredDiscoveries,
			requiredLevel = zone.requiredLevel,
		})
	end
	local ocean = layout and layout.Ocean or {minX = -1900, maxX = 1900, minZ = -1900, maxZ = 1900, surfaceY = 0}
	return {zones = zones, ocean = ocean, boat = layout and layout.Boat}
end

local function refreshMap(nextMap: any?)
	local candidate = if type(nextMap) == "table" and type(nextMap.zones) == "table" then nextMap else (map or fallbackMap())
	local parts = {}
	for _, zone in ipairs(candidate.zones or {}) do
		table.insert(parts, table.concat({tostring(zone.id), tostring(zone.x), tostring(zone.z), tostring(zone.name)}, ":"))
	end
	local signature = table.concat(parts, "|")
	if signature == mapSignature and map then return false end
	map = candidate
	mapSignature = signature
	return true
end

local function zoneById(id: number): any?
	for _, zone in ipairs((map and map.zones) or {}) do
		if zone.id == id then return zone end
	end
	return nil
end

local function nearestZoneToBoat(): number
	if not boatState.position or not map then return selectedZone end
	local best, distance = selectedZone, math.huge
	for _, zone in ipairs(map.zones or {}) do
		local dx = zone.x - boatState.position.x
		local dz = zone.z - boatState.position.z
		local value = math.sqrt(dx * dx + dz * dz)
		if value < distance then best, distance = zone.id, value end
	end
	return best
end

local function nearDock(): boolean
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then return false end
	for _, zone in ipairs((map and map.zones) or {}) do
		local dx = rootPart.Position.X - zone.x
		local dz = rootPart.Position.Z - (zone.z + 76)
		if math.sqrt(dx * dx + dz * dz) <= 24 then return true end
	end
	return false
end

local function layoutMapPanel(): boolean
	local viewport = root.AbsoluteSize
	if viewport.X <= 0 or viewport.Y <= 0 then return false end
	local wide = viewport.X > viewport.Y and viewport.X >= 600
	local width = math.max(280, math.min(700, viewport.X * .92))
	local height = math.max(300, math.min(560, viewport.Y * .75))
	local key = string.format("%d:%d", math.floor(viewport.X), math.floor(viewport.Y))
	if key == lastViewportKey then return false end
	lastViewportKey = key
	mapPanel.Size = UDim2.new(.92, 0, .75, 0)
	if wide then
		local chartWidth = math.floor(width * .64)
		local chartHeight = math.max(220, height - 76)
		chart.Position = UDim2.fromOffset(18, 58)
		chart.Size = UDim2.fromOffset(chartWidth, chartHeight)
		local detailX = chartWidth + 32
		destination.Position = UDim2.fromOffset(detailX, 96)
		destination.Size = UDim2.new(1, -detailX - 18, 0, 100)
		mapActionHint.Position = UDim2.fromOffset(detailX, 214)
		mapActionHint.Size = UDim2.new(1, -detailX - 18, 0, 90)
	else
		local chartHeight = math.max(150, height - 214)
		chart.Position = UDim2.fromOffset(18, 58)
		chart.Size = UDim2.new(1, -36, 0, chartHeight)
		destination.Position = UDim2.fromOffset(18, 58 + chartHeight + 12)
		destination.Size = UDim2.new(1, -36, 0, 56)
		mapActionHint.Position = UDim2.fromOffset(18, 58 + chartHeight + 70)
		mapActionHint.Size = UDim2.new(1, -36, 0, 28)
	end
	return true
end

local function directionText(zone: any?): (string, string)
	if not zone then return "未选择目的地", "打开海图选择一个水域。" end
	if not boatState.position then return zone.name, "召唤帆船后显示航向与距离。" end
	local dx = zone.x - boatState.position.x
	local dz = zone.z - boatState.position.z
	local distance = math.sqrt(dx * dx + dz * dz)
	local angle = math.atan2(dx, -dz)
	local directions = {"北", "东北", "东", "东南", "南", "西南", "西", "西北"}
	local index = math.floor(((angle + math.pi / 8) % (math.pi * 2)) / (math.pi / 4)) + 1
	return string.format("→ %s · %s", directions[index] or "北", zone.name), string.format("距离 %.0f studs", distance)
end

local function updateDestination()
	local zone = zoneById(selectedZone)
	local title, distance = directionText(zone)
	local unlocked = zone and zone.id <= currentUnlock()
	local lockText = if unlocked then "可航行 · 可钓鱼" else "可航行 · 钓鱼未解锁"
	destination.Text = title .. "\n" .. distance .. "  ·  " .. lockText
	mapActionHint.Text = if boatState.active
		then "驾驶中可随时查看方向；到岸后请在码头下船。"
		else "先在任意已建码头召唤免费帆船，再按方向航行。"
end

local function redrawChart()
	for _, child in ipairs(chart:GetChildren()) do
		if child:IsA("TextButton") and child.Name == "ZoneMarker" then child:Destroy() end
	end
	refreshMap(nil)
	local zones = map and map.zones or {}
	if #zones == 0 then return end
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, zone in ipairs(zones) do
		minX, maxX = math.min(minX, zone.x), math.max(maxX, zone.x)
		minZ, maxZ = math.min(minZ, zone.z), math.max(maxZ, zone.z)
	end
	local spanX, spanZ = math.max(1, maxX - minX), math.max(1, maxZ - minZ)
	local chartWidth = math.max(1, chart.AbsoluteSize.X > 0 and chart.AbsoluteSize.X or chart.Size.X.Offset)
	local chartHeight = math.max(1, chart.AbsoluteSize.Y > 0 and chart.AbsoluteSize.Y or chart.Size.Y.Offset)
	local marginX = math.min(70, math.max(42, chartWidth * .18))
	local marginTop = math.min(58, math.max(44, chartHeight * .16))
	local marginBottom = math.min(40, math.max(24, chartHeight * .1))
	for _, zone in ipairs(zones) do
		local px = marginX + (zone.x - minX) / spanX * math.max(1, chartWidth - marginX * 2)
		local py = marginTop + (zone.z - minZ) / spanZ * math.max(1, chartHeight - marginTop - marginBottom)
		local unlocked = zone.id <= currentUnlock()
		local marker = button(chart, tostring(zone.id), if zone.id == selectedZone then palette.gold elseif unlocked then palette.green else palette.locked, zone.id == selectedZone)
		marker.Name = "ZoneMarker"
		marker.AnchorPoint = Vector2.new(.5, .5)
		marker.Position = UDim2.fromOffset(px, py)
		marker.Size = UDim2.fromOffset(46, 46)
		marker.TextSize = 13
		marker:SetAttribute("Zone", zone.id)
		local markerName = label(marker, if zone.id == selectedZone then (zone.name or ("水域 " .. tostring(zone.id))) else "", 10, palette.cream, true)
		markerName.AnchorPoint = Vector2.new(.5, 0)
		markerName.Position = UDim2.new(.5, 0, 1, 2)
		markerName.Size = UDim2.fromOffset(116, 24)
		markerName.TextXAlignment = Enum.TextXAlignment.Center
		markerName.TextColor3 = palette.cream
		markerName.Visible = zone.id == selectedZone
		local markerGui = ownedSailingGui
		local markerGeneration = lifecycle.generation
		marker.Activated:Connect(function()
			if not ownsCapturedSailingGui(markerGui, markerGeneration, visibilityOwnerToken) then return end
			selectedZone = zone.id
			redrawChart()
			updateDestination()
		end)
		rounded(marker, 20)
	end
	renderedUnlock = currentUnlock()
	updateDestination()
end
lifecycle.redrawChart = redrawChart

updateStatus = function()
	if not lifecycle.alive then return end
	local active = boatState.active == true
	local driving = active and boatState.driving == true
	if not driving then
		adoptInheritedLegacyVisibility()
		adoptInheritedTouchGuiVisibility()
	end
	if hudState.driving and not driving then
		if mapOpen then
			mapOpen = false
			mapPanel.Visible = false
		end
		if fishingPanelOpen then
		-- A forced disembark/death cannot leave a modal and its stale input
		-- context behind.  The main client also receives this close through the
		-- published attribute when the panel exists.
			closeContextPanel()
		end
	end
	syncHudState()
	local panelBlockingHud = fishingPanelOpen
	status.Visible = active and not panelBlockingHud
	mapPanel.Visible = mapOpen and not panelBlockingHud
	mapButton.Visible = not mapOpen and not panelBlockingHud
	bagButton.Visible = driving and not mapOpen and not panelBlockingHud
	controls.Visible = driving and not mapOpen and not panelBlockingHud
	exitButton.Visible = driving and not mapOpen and not panelBlockingHud
	returnButton.Visible = active and not mapOpen and not panelBlockingHud
	summonButton.Visible = not active and not mapOpen and not panelBlockingHud and nearDock()
	if mapOpen then
		hideLegacy(true)
		hideTouchGui(true)
	elseif panelBlockingHud then
		-- Sailing hid the legacy ScreenGui for driving.  A real bag request
		-- keeps ContentPanel visible, so restore the ScreenGui without using
		-- its Enabled property as the panel-open state.
		hideLegacy(false)
		if active and boatState.driving == true then hideTouchGui(true) else hideTouchGui(false) end
	elseif driving then
		local velocity = math.floor(math.abs(boatState.velocity or 0))
		statusTitle.Text = if boatState.driving then "正在航行" else "救生浮台"
		local headingText, distanceText = directionText(zoneById(selectedZone))
		statusDetail.Text = string.format("航速 %d  ·  %s  ·  %s", velocity, headingText, distanceText)
		if not lifecycle.openingPage then hideLegacy(true) end
		hideTouchGui(true)
	else
		hideLegacy(false)
		hideTouchGui(false)
	end
	if active and not boatState.driving then
		statusTitle.Text = "救生浮台"
		statusDetail.Text = "已安全离船  ·  可重新上船或返回港湾"
	end
	updateDestination()
end

-- Dock prompts keep their enabled state and server Triggered path.  The
-- sailing HUD owns only their presentation, so the stock prompt cannot sit on
-- top of the fishing panel.  A one-time workspace scan plus DescendantAdded
-- covers dock creation without a per-frame world traversal.
for _, instance in workspace:GetDescendants() do
	if instance:IsA("ProximityPrompt") then registerSummonPrompt(instance) end
end
summonPromptAddedConnection = trackConnection("summonPromptAdded", workspace.DescendantAdded, function(instance)
	if not lifecycle.alive then return end
	if instance:IsA("ProximityPrompt") then registerSummonPrompt(instance) end
end)
summonPromptShownConnection = trackConnection("summonPromptShown", ProximityPromptService.PromptShown, function(prompt)
	if not lifecycle.alive then return end
	if isSummonPrompt(prompt) then
		registerSummonPrompt(prompt)
		refreshBoatHud()
	end
end)

fishingGuiAddedConnection = trackConnection("fishingGuiAdded", playerGui.ChildAdded, function(child)
	if not lifecycle.alive then return end
		if child.Name == "FishingAquariumUI" then
			local generation = lifecycle.generation
			task.defer(function()
				if ownsCurrentSailingGui() and lifecycle.generation == generation then bindFishingPanel() end
			end)
			task.delay(.2, function()
				if ownsCurrentSailingGui() and lifecycle.generation == generation then bindFishingPanel() end
			end)
	end
end)
fishingGuiRemovedConnection = trackConnection("fishingGuiRemoved", playerGui.ChildRemoved, function(child)
	if not lifecycle.alive then return end
	if child.Name == "FishingAquariumUI" then
		local currentGui = playerGui:FindFirstChild("FishingAquariumUI")
		-- A delayed removal for an older same-name GUI must never clear the
		-- panel bridge that is already bound to its replacement.  If the old
		-- bound instance is the one being removed while a valid replacement is
		-- present, bind that replacement immediately; the queued ChildAdded
		-- retry is only a fallback.
		if child ~= fishingGui then
			if currentGui and currentGui ~= fishingGui then bindFishingPanel() end
			return
		end
		if currentGui and currentGui ~= child then
			bindFishingPanel()
			return
		end
		disconnectConnection("fishingPanel")
		disconnectConnection("fishingGuiEnabled")
		disconnectConnection("fishingGuiAttribute")
		disconnectConnection("fishingGuiDescendant")
		fishingPanelConnection = nil
		fishingGuiEnabledConnection = nil
		fishingGuiAttributeConnection = nil
		fishingGuiDescendantConnection = nil
		fishingGui = nil
		fishingPanel = nil
		if updateFishingSnapshotProjection(nil) then refreshBoatHud() end
		openPageBridge = nil
		fishingPanelOpen = false
		syncHudState()
		refreshBoatHud()
	end
end)
bindFishingPanel()
do
	local generation = lifecycle.generation
	task.delay(.2, function()
		if ownsCurrentSailingGui() and lifecycle.generation == generation then bindFishingPanel() end
	end)
end
syncSummonPromptStyles()
trackConnection("sailingGuiEnabled", gui:GetPropertyChangedSignal("Enabled"), function()
	if not lifecycle.alive then return end
	syncSummonPromptStyles()
	refreshBoatHud()
end)
gui.Destroying:Connect(function()
	if clearInput then clearInput(true, true, gui, lifecycle.generation, visibilityOwnerToken, true) end
	stopLifecycle()
	fishingSnapshotZone = nil
	hideLegacy(false)
	hideTouchGui(false)
	hudState = SailingHudState.new()
	restoreSummonPromptStyles()
	summonPromptAddedConnection = nil
	summonPromptShownConnection = nil
	fishingGuiAddedConnection = nil
	fishingGuiRemovedConnection = nil
	fishingGuiEnabledConnection = nil
	fishingPanelConnection = nil
	fishingGuiAttributeConnection = nil
	fishingGuiDescendantConnection = nil
	lifecycle.redrawChart = nil
end)

local function setMapOpen(open: boolean)
	if not ownsCurrentSailingGui() or (open and fishingPanelOpen) then return end
	mapOpen = open
	mapPanel.Visible = open
	syncHudState()
	if not open and clearInput then clearInput(true) end
	if open then
		hideLegacy(true)
		layoutMapPanel()
		redrawChart()
	else
		if not boatState.active then hideLegacy(false); hideTouchGui(false) end
	end
	updateStatus()
end

local function invoke(action: string, payload: any?): any?
	local ownerGui = ownedSailingGui
	local ownerGeneration = lifecycle.generation
	local ownerToken = visibilityOwnerToken
	if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return nil end
	local ok, result = pcall(function()
		return request:InvokeServer(action, payload or {})
	end)
	if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return nil end
	if not ok or type(result) ~= "table" then return nil end
	if result.state then
		boatState = result.state
		local changed = refreshMap(boatState.map)
		selectedZone = zoneById(selectedZone) and selectedZone or nearestZoneToBoat()
		updateStatus()
		if mapOpen and changed then redrawChart() end
	end
	if result.message and result.message ~= "" then showNotice(result.message, if result.ok then 1.8 else 3.2) end
	return result
end

mapButton.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	setMapOpen(not mapOpen)
end)
mapClose.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	setMapOpen(false)
end)
summonButton.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	local result = invoke("summon", {zone = selectedZone})
	if not ownsCurrentSailingGui() then return end
	if result and result.ok then setMapOpen(false) end
end)
exitButton.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	invoke("leave", {})
end)
returnButton.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	invoke("returnHarbor", {})
end)

local function bindHold(buttonObject: TextButton, key: string)
	local ownerGui = ownedSailingGui
	local ownerGeneration = lifecycle.generation
	local ownerToken = visibilityOwnerToken
	buttonObject.InputBegan:Connect(function(input)
		if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return end
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then touchHeld[key] = true end
	end)
	buttonObject.InputEnded:Connect(function(input)
		if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return end
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then touchHeld[key] = nil end
	end)
	buttonObject.MouseLeave:Connect(function()
		if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return end
		touchHeld[key] = nil
	end)
end
bindHold(forwardButton, "forward")
bindHold(reverseButton, "reverse")
bindHold(leftButton, "left")
bindHold(rightButton, "right")

local function focusedTextBox(): boolean
	local ok, focused = pcall(function() return UserInputService:GetFocusedTextBox() end)
	return ok and focused ~= nil
end

trackConnection("inputBegan", UserInputService.InputBegan, function(input, processed)
	if not lifecycle.alive then return end
	local key = input.KeyCode
	if processed or focusedTextBox() then return end
	if key == Enum.KeyCode.M then
		if not fishingPanelOpen then setMapOpen(not mapOpen) end
		return
	end
	if SailingHudState.blocksIntent(hudState) then return end
	if key == Enum.KeyCode.W or key == Enum.KeyCode.Up or key == Enum.KeyCode.S or key == Enum.KeyCode.Down
		or key == Enum.KeyCode.A or key == Enum.KeyCode.Left or key == Enum.KeyCode.D or key == Enum.KeyCode.Right then
		keys[key] = true
	end
	if key == Enum.KeyCode.Space and boatState.active and boatState.driving then invoke("leave", {}) end
end)
trackConnection("inputEnded", UserInputService.InputEnded, function(input)
	if not lifecycle.alive then return end
	keys[input.KeyCode] = nil
end)

local function inputVector(): (number, number)
	if SailingHudState.blocksIntent(hudState) then return 0, 0 end
	if qaInput then return qaInput.throttle, qaInput.steer end
	local throttle = 0
	if keys[Enum.KeyCode.W] or keys[Enum.KeyCode.Up] or touchHeld.forward then throttle += 1 end
	if keys[Enum.KeyCode.S] or keys[Enum.KeyCode.Down] or touchHeld.reverse then throttle -= 1 end
	local steer = 0
	if keys[Enum.KeyCode.D] or keys[Enum.KeyCode.Right] or touchHeld.right then steer += 1 end
	if keys[Enum.KeyCode.A] or keys[Enum.KeyCode.Left] or touchHeld.left then steer -= 1 end
	return math.clamp(throttle, -1, 1), math.clamp(steer, -1, 1)
end

clearInput = function(sendStop: boolean, forceNeutral: boolean?, expectedGui: ScreenGui?, expectedGeneration: number?, expectedToken: string?, allowTeardown: boolean?)
	table.clear(keys)
	table.clear(touchHeld)
	qaInput = nil
	local canSendNeutral = ownsCapturedSailingGui(expectedGui or ownedSailingGui, expectedGeneration, expectedToken)
	if allowTeardown then
		local teardownGui = expectedGui or ownedSailingGui
		local currentNamedGui = playerGui:FindFirstChild("SailingUI")
		-- Destroying can run after the instance has left PlayerGui.  Preserve one
		-- safe neutral for this exact owner when no replacement has appeared, but
		-- never let an old instance stop a replacement that already owns the name.
		canSendNeutral = lifecycle.alive
			and teardownGui ~= nil
			and ownedSailingGui == teardownGui
			and teardownGui:GetAttribute(SAILING_GUI_OWNER) == (expectedToken or visibilityOwnerToken)
			and (currentNamedGui == nil or currentNamedGui == teardownGui)
	end
	if canSendNeutral and sendStop and (forceNeutral == true or sentMovingIntent) then
		intent:FireServer({throttle = 0, steer = 0})
	end
	sentMovingIntent = false
end
if pendingNeutral and clearInput then
	clearInput(true, true)
	pendingNeutral = false
end

local function resetSailingContext()
	if not lifecycle.alive then return end
	boatState = {active = false, driving = false}
	mapOpen = false
	mapPanel.Visible = false
	clearInput(true, true)
	closeContextPanel()
	fishingPanelOpen = false
	hudState = SailingHudState.new()
	updateStatus()
end

trackConnection("characterRemoving", player.CharacterRemoving, function()
	if not lifecycle.alive then return end
	lifecycle.characterReady = false
	lifecycle.characterGeneration += 1
	resetSailingContext()
end)
trackConnection("characterAdded", player.CharacterAdded, function(character)
	if not lifecycle.alive then return end
	lifecycle.characterReady = true
	lifecycle.characterGeneration += 1
	local generation = lifecycle.characterGeneration
	task.defer(function()
		if ownsCurrentSailingGui() and lifecycle.characterGeneration == generation and player.Character == character then
			resetSailingContext()
		end
	end)
end)

local function openingPageAcknowledged(page: string): boolean
	return SailingHudState.openingAcknowledged(
		lifecycle.alive
			and fishingGui ~= nil
			and fishingGui.Parent == playerGui
			and fishingGui.Enabled,
		lifecycle.alive and fishingPanel ~= nil and fishingPanel.Parent ~= nil and fishingPanel.Visible,
		fishingGui and fishingGui:GetAttribute("PanelOpen"),
		fishingGui and fishingGui:GetAttribute("ActiveTab"),
		page
	)
end

local function finishOpeningPage(token: number, acknowledged: boolean)
	if not ownsCurrentSailingGui() or not lifecycle.openingPage or lifecycle.openingToken ~= token then return end
	lifecycle.openingPage = false
	updateFishingPanelState()
	refreshBoatHud()
	if not acknowledged then showNotice("背包界面尚未就绪") end
end

local function requestFishingPage(page: string): boolean
	local ownerGui = ownedSailingGui
	local ownerGeneration = lifecycle.generation
	local ownerToken = visibilityOwnerToken
	if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken)
		or lifecycle.openingPage or not SailingHudState.canOpenPage(page) then return false end
	local token: number? = nil
	if page == "背包" then
		lifecycle.openingPage = true
		lifecycle.openingToken += 1
		token = lifecycle.openingToken
		enableLegacyForPanel()
	end
	local bridge = openPageBridge
	if not bridge or bridge.Parent == nil then
		bindFishingPanel()
		bridge = openPageBridge
	end
	if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) or not bridge then
		if token then
			lifecycle.openingPage = false
			updateFishingPanelState()
			refreshBoatHud()
		end
		return false
	end
	local ok = pcall(function() bridge:Fire(page) end)
	if not ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken) then return false end
	if not ok then
		if token then finishOpeningPage(token, false) end
		return false
	end
	if token then
		local openingToken = token
		task.spawn(function()
			local deadline = os.clock() + 2
			while ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken)
				and lifecycle.openingPage and lifecycle.openingToken == openingToken and os.clock() < deadline do
				if openingPageAcknowledged(page) then
					finishOpeningPage(openingToken, true)
					return
				end
				local currentGui = playerGui:FindFirstChild("FishingAquariumUI")
				if currentGui ~= fishingGui then bindFishingPanel() end
				task.wait()
			end
				if ownsCapturedSailingGui(ownerGui, ownerGeneration, ownerToken)
					and lifecycle.openingPage and lifecycle.openingToken == openingToken then
				finishOpeningPage(openingToken, openingPageAcknowledged(page))
			end
		end)
	end
	return true
end

bagButton.Activated:Connect(function()
	if not ownsCurrentSailingGui() then return end
	if not boatState.active or not boatState.driving or mapOpen or fishingPanelOpen then return end
	if not requestFishingPage("背包") then showNotice("背包界面尚未就绪") end
end)

-- Studio-only seam for SailingSmoke. Production has no sibling named
-- SailingSmoke, so this BindableFunction is never created in the playable
-- place. It drives the same map/input functions used by keyboard and touch.
if qaMode then
	local qa = Instance.new("BindableFunction")
	qa.Name = "SailingQA"
	qa.OnInvoke = function(command: any, value: any): any
		if not ownsCurrentSailingGui() then return false end
		if command == "setMapOpen" then
			setMapOpen(value == true)
			return true
		end
		if command == "setInput" then
			if type(value) ~= "table" then return false end
			local throttle = tonumber(value.throttle)
			local steer = tonumber(value.steer)
			if not throttle or not steer or throttle ~= throttle or steer ~= steer then return false end
			qaInput = {throttle = math.clamp(throttle, -1, 1), steer = math.clamp(steer, -1, 1)}
			return true
		end
		if command == "clearInput" then
			qaInput = nil
			clearInput(true)
			return true
		end
		if command == "openBag" then
			-- This is a direct handler seam for deterministic Studio smoke.  The
			-- physical path remains BagButton.Activated in production; smoke must
			-- use UserInputService:CreateVirtualInput when it claims a click.
			return requestFishingPage("背包")
		end
		if command == "closeBag" then
			closeContextPanel()
			return true
		end
		if command == "layout" then
			layoutMapPanel()
			return {panel = mapPanel, chart = chart, safeRoot = root}
		end
		if command == "state" then return boatState end
		return false
	end
	qa.Parent = gui
	gui:SetAttribute("SailingQAReady", true)
end

trackConnection("renderStepped", RunService.RenderStepped, function()
	if not lifecycle.alive then return end
	if pendingNeutral and clearInput then
		clearInput(true, true)
		pendingNeutral = false
	end
	local resized = layoutMapPanel()
	if mapOpen and resized then redrawChart() end
	local hudNow = os.clock()
	if hudNow - lastDockCheckAt > .35 and not boatState.active then
		lastDockCheckAt = hudNow
		summonButton.Visible = not mapOpen and not fishingPanelOpen and nearDock()
	end
	if not boatState.active or not boatState.driving or mapOpen or fishingPanelOpen or SailingHudState.blocksIntent(hudState) then
		if mapOpen or fishingPanelOpen then clearInput(true) end
		return
	end
	if qaMode and not qaInput then return end
	local now = os.clock()
	if now - lastIntentAt < .075 then return end
	lastIntentAt = now
	local throttle, steer = inputVector()
	intent:FireServer({throttle = throttle, steer = steer})
	sentMovingIntent = math.abs(throttle) > .001 or math.abs(steer) > .001
end)

trackConnection("windowFocusReleased", UserInputService.WindowFocusReleased, function()
	if lifecycle.alive then clearInput(true) end
end)

trackConnection("boatState", stateEvent.OnClientEvent, function(nextState)
	if not lifecycle.alive or not lifecycle.characterReady or type(nextState) ~= "table" then return end
	boatState = nextState
	local changed = refreshMap(nextState.map)
	if nextState.active and not zoneById(selectedZone) then selectedZone = nearestZoneToBoat() end
	updateStatus()
	if nextState.notice then showNotice(nextState.notice) end
	if mapOpen and changed then redrawChart() end
end)

refreshMap(nil)
redrawChart()
updateStatus()

-- StudioQA may inspect these attributes without reaching into local closures.
gui:SetAttribute("SailingClientReady", true)
gui:SetAttribute("MapOnlySelectsDestinations", true)
gui:SetAttribute("CustomSummonPromptStyle", true)
gui:SetAttribute("NativeSummonPromptInput", true)
