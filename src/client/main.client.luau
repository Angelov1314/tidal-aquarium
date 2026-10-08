--!strict
-- Coastal Fishing Aquarium client.  The server remains authoritative for every
-- economic action; this file only presents snapshots and requests commands.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("FishingRemotes")
local request = remotes:WaitForChild("Request") :: RemoteFunction
local stateEvent = remotes:WaitForChild("State") :: RemoteEvent
local shared = ReplicatedStorage:FindFirstChild("FishingShared")
local Config = if shared then require(shared:WaitForChild("Config")) else nil
local UiStyle = if shared then require(shared:WaitForChild("UiStyle")) else nil
local FishingLocation = if shared then require(shared:WaitForChild("FishingLocation")) else nil
local Audio = require(script.Parent:WaitForChild("Audio"))
local UiRepair = require(script.Parent:WaitForChild("UiRepair"))
local ResponsiveLayout = require(script.Parent:WaitForChild("ResponsiveLayout"))
local ArtRenderer = require(ReplicatedStorage.FishingShared:WaitForChild("ArtRenderer"))
local ArtCredits = require(ReplicatedStorage.FishingShared:WaitForChild("ArtCredits"))
local CatchPresentation = require(script.Parent:WaitForChild("CatchPresentation"))

local old = playerGui:FindFirstChild("FishingAquariumUI")
if old then old:Destroy() end
local oldCatchOverlay = playerGui:FindFirstChild("FishingCatchFeedbackUI")
if oldCatchOverlay then oldCatchOverlay:Destroy() end
local oldCatchFolder = workspace:FindFirstChild("FishingCatchFeedback")
if oldCatchFolder then oldCatchFolder:Destroy() end

local C = {
	cream = Color3.fromRGB(255, 248, 229), paper = Color3.fromRGB(246, 237, 210),
	navy = Color3.fromRGB(20, 48, 66), navy2 = Color3.fromRGB(31, 68, 85),
	teal = Color3.fromRGB(40, 153, 151), sea = Color3.fromRGB(95, 203, 193),
	ink = Color3.fromRGB(24, 55, 68), muted = Color3.fromRGB(94, 119, 124),
	gold = Color3.fromRGB(238, 177, 73), red = Color3.fromRGB(201, 84, 77),
	green = Color3.fromRGB(59, 154, 110), white = Color3.fromRGB(255, 255, 255),
}

local render: any
local updateViewportLayout: any = nil
local snapshot: {[string]: any}? = nil
local selectedId: string? = nil
local bagPage = 1
local mergePage = 1
local bagFilter = "全部"
local mergeIds: {string} = {}
local duplicateConfirm = false
local activeTab = "钓鱼"
local panelOpen = false
local renderedFishSignature = ""
local cosmetics: {Instance} = {}
local heldRodHandle: any = nil
local bobber: BasePart? = nil
local bobberBasePosition: Vector3? = nil
local bobberCastStart: Vector3? = nil
local bobberCastAt = 0
local fishingLine: Beam? = nil
local selectedContractSpecies: string? = nil
local catchPresentation: any = nil
local clientRenderConnection: RBXScriptConnection? = nil
local scrollPositions: {[string]: Vector2} = {}
local renderedScrollKey = ""
local requestGate: any = nil
local layout = ResponsiveLayout.compute(1180, 760, nil, nil, nil, nil, UserInputService.TouchEnabled)
local viewportConnection: RBXScriptConnection? = nil
local cameraConnection: RBXScriptConnection? = nil
local rootSizeConnection: RBXScriptConnection? = nil
local pendingScrollPosition: Vector2? = nil
local bagDetailReveal = false
local mergePreviewReveal = false
local forcedLayoutViewport: {width: number, height: number, touch: boolean}? = nil
local shopMode = "store"
local exchangeRecipeId: string? = nil
local exchangeSelectedIds: {string} = {}
local exchangeConfirm = false
local exchangeRequestId: string? = nil
local exchangeSelectionKey: string? = nil
local useItemConfirmId: string? = nil
local useItemRequestId: string? = nil
local saleConfirmId: string? = nil
local saleExpectedPrice: number? = nil
local saleConfirmationKey: string? = nil
local mergeConfirm = false
local mergeConfirmationKey: string? = nil
local requestSerial = 0
local pendingBridgePage: string? = nil
local setActiveTabBridge: any = nil
local lifecycle = {
	alive = true,
	generation = 0,
	characterGeneration = 0,
	characterReady = player.Character ~= nil,
	knownFishCount = -1,
	connections = {},
	sailingHudState = nil,
	publishFishingSnapshotZone = nil,
	-- A normal Studio session with no sibling smoke script must not expose QA
	-- attributes. The isolated QA mapping includes this sibling at startup.
	qaMode = RunService:IsStudio() and script.Parent:FindFirstChild("MainLifecycleSmoke") ~= nil,
}

lifecycle.mutationState = require(script.Parent:WaitForChild("MutationLaneState")).new(HttpService:GenerateGUID(false))
lifecycle.sailingHudState = if shared then require(shared:WaitForChild("SailingHudState")) else nil

local MAIN_GUI_OWNER = "FishingAquariumGuiOwner"
local mainGuiOwnerToken = tostring(script) .. ":" .. tostring(os.clock())

local function setSnapshot(nextState: any, handshake: boolean?): (boolean, number)
	if not lifecycle.alive then return false, 0 end
	if not lifecycle.mutationState:acceptSnapshot(nextState, handshake == true) then return false, 0 end
	snapshot = nextState
	if lifecycle.publishFishingSnapshotZone then
		lifecycle.publishFishingSnapshotZone(nextState and nextState.zone, lifecycle.generation)
	end
	if requestGate and requestGate.incomePreview then requestGate.incomePreview:onSnapshot(nextState) end
	return true, lifecycle.mutationState:reconcileAcceptedSnapshot()
end

local buttonStyles: {[TextButton]: {color: Color3, enabled: boolean, selected: boolean, card: boolean, tween: any}} = {}

local function surfaceTransparency(state: string, card: boolean?): number
	if UiStyle then
		return if card then UiStyle.cardTransparency(state) else UiStyle.buttonTransparency(state)
	end
	if state == "disabled" then return .45 end
	if state == "hover" or state == "selected" then return .25 end
	return .35
end

local function panelSurfaceTransparency(): number
	return if UiStyle then UiStyle.panelTransparency else .2
end

local function currentButtonTransparency(style: any): number
	local state = if not style.enabled then "disabled" elseif style.selected then "selected" else "normal"
	return surfaceTransparency(state, style.card)
end

local function stopButtonTween(style: any)
	if style and style.tween then
		style.tween:Cancel()
		style.tween = nil
	end
end

local function tweenButton(x: TextButton, style: any, properties: {[string]: any})
	stopButtonTween(style)
	local tween = TweenService:Create(x, TweenInfo.new(.12), properties)
	style.tween = tween
	tween.Completed:Connect(function()
		if buttonStyles[x] == style and style.tween == tween then style.tween = nil end
	end)
	tween:Play()
end

local gui = Instance.new("ScreenGui")
gui.Name = "FishingAquariumUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.DisplayOrder = 25
gui.Parent = playerGui
gui:SetAttribute(MAIN_GUI_OWNER, mainGuiOwnerToken)

local function ownsCapturedMainGui(expectedGeneration: number?, expectedGui: ScreenGui?, expectedToken: string?): boolean
	local current = expectedGui or gui
	return lifecycle.alive
		and current == gui
		and current.Parent == playerGui
		and playerGui:FindFirstChild("FishingAquariumUI") == current
		and current:GetAttribute(MAIN_GUI_OWNER) == (expectedToken or mainGuiOwnerToken)
		and (expectedGeneration == nil or lifecycle.generation == expectedGeneration)
end
gui:SetAttribute("PanelOpen", false)
gui:SetAttribute("ActiveTab", activeTab)
-- This projection is deliberately nil until the existing Main handshake or a
-- later fenced snapshot is accepted. Sailing reads it through its existing
-- exact GUI binding; it never opens FishingRemotes itself.
gui:SetAttribute("FishingSnapshotZone", nil)
lifecycle.publishFishingSnapshotZone = function(value: any, expectedGeneration: number?)
	if not ownsCapturedMainGui(expectedGeneration, gui, mainGuiOwnerToken) then return end
	local contract = lifecycle.sailingHudState
	local zoneCount = if Config and type(Config.Zones) == "table" then #Config.Zones else 0
	local validated = if contract and contract.validatedZone then contract.validatedZone(value, zoneCount) else 1
	if ownsCapturedMainGui(expectedGeneration, gui, mainGuiOwnerToken) then
		gui:SetAttribute("FishingSnapshotZone", validated)
	end
end
-- Production clients use this narrow page bridge instead of reaching into
-- private UI closures.  Sailing may request the existing backpack page, but
-- it cannot invoke an economic command through this event. Keep the local
-- Instance scoped to this initialization block so the main client stays below
-- Luau's 200-register limit in its late Studio harness closure.
do
	local openPageEvent = Instance.new("BindableEvent")
	openPageEvent.Name = "OpenPage"
	openPageEvent.Parent = gui
	openPageEvent.Event:Connect(function(page: any)
		if not ownsCapturedMainGui() then return end
		if type(page) ~= "string"
			or (page ~= "钓鱼" and page ~= "背包" and page ~= "水族馆" and page ~= "合成"
				and page ~= "图鉴" and page ~= "升级" and page ~= "商店" and page ~= "概率" and page ~= "鸣谢") then return end
		if setActiveTabBridge then setActiveTabBridge(page) else pendingBridgePage = page end
	end)
end
-- Let mobile devices choose portrait or landscape instead of inheriting a
-- forced landscape sensor mode from the place/StarterGui configuration.
pcall(function()
	(playerGui :: any).ScreenOrientation = Enum.ScreenOrientation.Sensor
end)

-- This transparent safe-area probe follows ScreenGui's IgnoreGuiInset policy.
-- Layout uses its AbsoluteSize instead of subtracting Camera.ViewportSize and
-- GuiInset independently, so compact geometry is measured in one coordinate
-- system.  ResponsiveSmoke may resize this frame only in its guarded Studio
-- fixture; production never exposes a control endpoint for it.
local layoutRoot = Instance.new("Frame")
layoutRoot.Name = "ResponsiveRoot"
layoutRoot.BackgroundTransparency = 1
layoutRoot.BorderSizePixel = 0
layoutRoot.Size = UDim2.fromScale(1, 1)
layoutRoot.Position = UDim2.fromOffset(0, 0)
layoutRoot.Active = false
layoutRoot.ZIndex = 0
layoutRoot.Parent = gui

local function corner(parent: Instance, radius: number)
	local x = Instance.new("UICorner"); x.CornerRadius = UDim.new(0, radius); x.Parent = parent
end
local function stroke(parent: Instance, color: Color3, alpha: number?)
	local x = Instance.new("UIStroke"); x.Color = color; x.Transparency = alpha or 0; x.Thickness = 1; x.Parent = parent
end
local function label(parent: Instance, text: string, size: number, color: Color3, bold: boolean?): TextLabel
	local x = Instance.new("TextLabel")
	x.BackgroundTransparency = 1; x.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	x.Text = text; x.TextSize = size; x.TextColor3 = color; x.TextXAlignment = Enum.TextXAlignment.Left
	x.TextYAlignment = Enum.TextYAlignment.Center; x.TextWrapped = true; x.Parent = parent
	return x
end
local function setButtonEnabled(x: TextButton, enabled: boolean, color: Color3?, selected: boolean?)
	local style = buttonStyles[x]
	if style then
		stopButtonTween(style)
		style.enabled = enabled
		if color then style.color = color end
		if selected ~= nil then style.selected = selected end
	end
	x.Active = enabled
	x.Selectable = enabled
	-- All visual states are owned by this constructor so Roblox defaults cannot
	-- compete with the shared transparency tokens.
	x.AutoButtonColor = false
	if style then
		x.BackgroundColor3 = if enabled then style.color else C.muted
		x.BackgroundTransparency = currentButtonTransparency(style)
		x.TextTransparency = 0
	end
end
local function button(parent: Instance, text: string, color: Color3, selected: boolean?, card: boolean?): TextButton
	local x = Instance.new("TextButton")
	x.AutoButtonColor = false; x.BackgroundColor3 = color; x.BackgroundTransparency = surfaceTransparency(if selected then "selected" else "normal", card); x.BorderSizePixel = 0
	x.Font = Enum.Font.GothamBold; x.Text = text; x.TextSize = 14; x.TextColor3 = C.white
	x.TextTransparency = 0; x.TextStrokeColor3 = C.navy; x.TextStrokeTransparency = .78
	buttonStyles[x] = {color = color, enabled = true, selected = selected == true, card = card == true, tween = nil}
	x.Destroying:Connect(function()
		local style = buttonStyles[x]
		stopButtonTween(style)
		buttonStyles[x] = nil
	end)
	x.Parent = parent; corner(x, 10)
	x.MouseEnter:Connect(function()
		local style = buttonStyles[x]
		if style and style.enabled then
			tweenButton(x, style, {
				BackgroundColor3 = style.color:Lerp(C.white, .12),
				BackgroundTransparency = surfaceTransparency(if style.selected then "selected" else "hover", style.card),
			})
		end
	end)
	x.MouseLeave:Connect(function()
		local style = buttonStyles[x]
		if style then
			tweenButton(x, style, {
				BackgroundColor3 = if style.enabled then style.color else C.muted,
				BackgroundTransparency = currentButtonTransparency(style),
			})
		end
	end)
	return x
end
local function panel(parent: Instance): Frame
	local x = Instance.new("Frame"); x.BackgroundColor3 = C.cream; x.BackgroundTransparency = panelSurfaceTransparency(); x.BorderSizePixel = 0; x.Parent = parent; corner(x, 18); stroke(x, C.sea, .45); return x
end
local function clear(parent: Instance)
	for _, child in parent:GetChildren() do if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end end
end
local function fishColor(fish: any): Color3
	if Config and Config.SpeciesById and Config.SpeciesById[fish.species] then
		local c = Config.SpeciesById[fish.species].color
		if c then return Color3.fromRGB(c.r or c[1], c.g or c[2], c.b or c[3]) end
	end
	return C.sea
end
local function speciesName(fish: any): string
	if Config and Config.SpeciesById and Config.SpeciesById[fish.species] then return Config.SpeciesById[fish.species].name or fish.species end
	return tostring(fish.species or "未知鱼")
end
local function findFish(id: string?): any
	if not snapshot or not id then return nil end
	for _, f in snapshot.fish or {} do if f.id == id then return f end end
	return nil
end
local function money(n: number?): string
	n = math.floor(n or 0)
	if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
	if n >= 1000 then return string.format("%.1fK", n / 1000) end
	return tostring(n)
end
local function moneyPrecise(n: number?): string
	local value = n or 0
	if value >= 1000000 then return string.format("%.2fM", value / 1000000) end
	if value >= 1000 then return string.format("%.2fK", value / 1000) end
	return string.format("%.2f", value)
end
local function fishDescriptors(fish: any): (string, string, string)
	local species = Config and Config.SpeciesById and Config.SpeciesById[fish.species]
	local rarity = species and Config.Rarities and Config.Rarities[species.rarity]
	local size = Config and Config.Sizes and Config.Sizes[fish.size]
	local mutation = Config and Config.Mutations and Config.Mutations[fish.mutation]
	return rarity and rarity.name or "未知品质", size and size.name or "标准", mutation and mutation.name or "普通"
end

local fallbackTraits = {
	ordinary = {name = "普通", sellMultiplier = 1},
	lucky = {name = "幸运", luckBonus = 3, sellMultiplier = 1},
	gilded = {name = "镀金", coinBonus = .05, sellMultiplier = 1},
	scholarly = {name = "博学", xpBonus = .1, sellMultiplier = 1},
}

local function fishWeight(fish: any): string
	local grams = tonumber(fish and fish.weightGrams)
	if not grams or grams <= 0 then return "重量待同步" end
	return string.format("%.2f kg", grams / 1000)
end

local function traitInfo(fish: any): any
	local id = tostring(fish and fish.trait or "ordinary")
	local configured = Config and Config.Traits and Config.Traits[id]
	return configured or fallbackTraits[id] or {name = id}
end

local function traitText(fish: any): string
	local info = traitInfo(fish)
	local bonuses = {}
	local luck = tonumber(info.luckBonus)
	local coins = tonumber(info.coinBonus)
	local xp = tonumber(info.xpBonus)
	local sell = tonumber(info.valueMultiplier or info.sellMultiplier)
	if luck and luck ~= 0 then table.insert(bonuses, "幸运+" .. tostring(luck)) end
	if coins and coins ~= 0 then table.insert(bonuses, "金币+" .. tostring(math.floor(coins * 100 + .5)) .. "%") end
	if xp and xp ~= 0 then table.insert(bonuses, "经验+" .. tostring(math.floor(xp * 100 + .5)) .. "%") end
	if sell and sell ~= 1 then table.insert(bonuses, "售价×" .. string.format("%.2f", sell)) end
	return tostring(info.name or fish and fish.trait or "普通") .. (if #bonuses > 0 then "（" .. table.concat(bonuses, "、") .. "）" else "")
end

local function fishRarity(fish: any): number
	local species = Config and Config.SpeciesById and Config.SpeciesById[fish and fish.species]
	return tonumber(fish and fish.rarity or species and species.rarity or 0) or 0
end

local function exactSaleQuote(fish: any, snapshotState: any?): number
	if type(fish and fish.salePrice) == "number" then return fish.salePrice end
	-- Existing saves and an in-flight legacy response can lack salePrice.  Keep
	-- the old display formula only for that compatibility window; new snapshots
	-- are authoritative through the server-provided quote above.
	local level = tonumber(snapshotState and snapshotState.coinLevel or 0) or 0
	return (tonumber(fish and fish.value) or 0) * (1 + level * .05)
end

local function saleQuoteAvailable(fish: any): boolean
	local quote = fish and fish.salePrice
	return type(quote) == "number" and quote == quote and quote ~= math.huge and quote ~= -math.huge and quote >= 0
end

local function saleConfirmationSignature(fish: any): string
	return UiRepair.saleConfirmationKey(fish, snapshot and snapshot.showcaseFishId)
end

local function clearSaleConfirmation()
	saleConfirmId = nil
	saleExpectedPrice = nil
	saleConfirmationKey = nil
end

local function clearMergeConfirmation()
	mergeConfirm = false
	mergeConfirmationKey = nil
end

local function clearExchangeConfirmation()
	exchangeConfirm = false
	exchangeRequestId = nil
	exchangeSelectionKey = nil
end

local function mergeConfirmationSignature(state: any?): string
	local parts = {tostring(state and state.showcaseFishId), tostring(state and state.bagCapacity), tostring(state and state.tankCapacity)}
	for _, id in ipairs(mergeIds) do
		local selected = nil
		for _, fish in ipairs(state and state.fish or {}) do if fish.id == id then selected = fish; break end end
		table.insert(parts, table.concat({tostring(id), tostring(selected and selected.species), tostring(selected and selected.level), tostring(selected and selected.placed), tostring(selected and selected.locked), tostring(selected and selected.value), tostring(selected and selected.income), tostring(selected and selected.weightGrams), tostring(selected and selected.trait)}, ":"))
	end
	return table.concat(parts, "|")
end

local function exchangeRecipes(): {any}
	local recipes = Config and Config.ExchangeRecipes
	if type(recipes) ~= "table" then return {} end
	return recipes
end

local function recipeById(id: string?): any
	if not id then return nil end
	for _, recipe in ipairs(exchangeRecipes()) do if tostring(recipe.id) == id then return recipe end end
	return nil
end

local function boostItems(): {[string]: any}
	local items = Config and Config.BoostItems
	return if type(items) == "table" then items else {}
end

local function remainingBoost(boost: any): number
	if type(boost) ~= "table" then return 0 end
	local remaining = tonumber(boost.remainingSeconds)
	if remaining then return math.max(0, remaining) end
	local untilTime = tonumber(boost.untilTime)
	return if untilTime then math.max(0, untilTime - os.time()) else 0
end

local function boostStatus(snapshotState: any, kind: string): any
	local active = snapshotState and snapshotState.activeBoosts and snapshotState.activeBoosts[kind]
	if type(active) ~= "table" then return nil end
	local copy = {}
	for key, value in active do copy[key] = value end
	copy.remainingSeconds = remainingBoost(active)
	return copy
end

local function progressText(snapshotState: any): string
	local level = tonumber(snapshotState and snapshotState.playerLevel or 1) or 1
	local xp = tonumber(snapshotState and snapshotState.xp or 0) or 0
	local nextXp = snapshotState and snapshotState.xpToNextLevel
	local luck = tonumber(snapshotState and (snapshotState.effectiveLuck or snapshotState.luck) or 0) or 0
	local xpText = if nextXp == nil then tostring(xp) .. " XP" else tostring(xp) .. " XP · 距下一级 " .. tostring(nextXp)
	return "Lv." .. tostring(level) .. " · " .. xpText .. " · 有效幸运 " .. tostring(luck)
end

local function newRequestId(prefix: string): string
	requestSerial += 1
	local ok, guid = pcall(function() return HttpService:GenerateGUID(false) end)
	if ok and type(guid) == "string" then return prefix .. ":" .. guid end
	return prefix .. ":" .. tostring(requestSerial) .. ":" .. string.format("%.6f", os.clock())
end

local function speciesForFish(fish: any): any
	local species = Config and Config.SpeciesById and Config.SpeciesById[fish and fish.species]
	if species then return species end
	return {
		id = tostring(fish and fish.species or "unknown"),
		name = tostring(fish and fish.species or "未知鱼"),
		rarity = 1,
		shape = 1,
		color = {r = 95, g = 203, b = 193},
	}
end

-- All fish UI surfaces use the same bounds-centered preview mount as catches.
-- The model carries its provenance in FishVisualSource, so a missing catalog
-- asset remains an explicit procedural fallback instead of a fake imported
-- thumbnail or an eye-only placeholder.
local function mountFishPreview(parent: Instance, species: any, fish: any, forceFallback: boolean?): (ViewportFrame?, Model?)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "FishPreviewViewport"
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.Position = UDim2.fromOffset(0, 0)
	viewport.Ambient = Color3.new(.75, .75, .75)
	viewport.LightColor = Color3.new(1, .98, .92)
	viewport.LightDirection = Vector3.new(-1, -1, -1)
	viewport.Parent = parent
	local model = ArtRenderer.mountPreview(viewport, species, fish, 3.3, forceFallback == true)
	if not model then
		viewport:Destroy()
		return nil, nil
	end
	local source = model:GetAttribute("FishVisualSource") or "ProceduralFallback"
	viewport:SetAttribute("FishVisualSource", source)
	parent:SetAttribute("FishVisualSource", source)
	local template = model:GetAttribute("SourceTemplate")
	if template then parent:SetAttribute("SourceTemplate", template) end
	return viewport, model
end

local header = panel(gui)
header.Name = "EconomyBar"; header.AnchorPoint = Vector2.new(.5, 0); header.Position = UDim2.fromScale(.5, .018); header.Size = UDim2.fromOffset(650, 66)
header.BackgroundTransparency = .6
local logo = label(header, "潮汐水族馆 Demo", 17, C.navy, true); logo.Position = UDim2.fromOffset(18, 4); logo.Size = UDim2.fromOffset(148, 28)
local sub = label(header, "SFX · elevenlabs.io", 10, C.teal, true); sub.Position = UDim2.fromOffset(19, 31); sub.Size = UDim2.fromOffset(130, 17)
local coinText = label(header, "◉ 0", 16, C.gold, true); coinText.Position = UDim2.fromOffset(182, 8); coinText.Size = UDim2.fromOffset(116, 24)
local incomeText = label(header, "⌂ 0 / 时", 13, C.green, true); incomeText.Position = UDim2.fromOffset(182, 34); incomeText.Size = UDim2.fromOffset(136, 20)
local hookText = label(header, "⚓ 1 鱼钩", 14, C.navy, true); hookText.Position = UDim2.fromOffset(330, 9); hookText.Size = UDim2.fromOffset(112, 22)
local tankText = label(header, "▣ 0 / 10 入缸", 13, C.muted, true); tankText.Position = UDim2.fromOffset(330, 34); tankText.Size = UDim2.fromOffset(140, 20)
local storageBadge = label(header, "存档：--", 11, C.muted, true); storageBadge.TextXAlignment = Enum.TextXAlignment.Right; storageBadge.Position = UDim2.fromOffset(550, 22); storageBadge.Size = UDim2.fromOffset(80, 20)
local audioButton = button(header, "音频", C.navy2); audioButton.Position = UDim2.fromOffset(482, 18); audioButton.Size = UDim2.fromOffset(62, 30)
audioButton.Name = "AudioButton"
local bagShortcut = button(header, "背包", C.teal); bagShortcut.Name = "CompactBagButton"; bagShortcut.Visible = false
for _, headerText in {logo, sub, coinText, incomeText, hookText, tankText, storageBadge} do
	headerText.TextWrapped = false
	headerText.TextTruncate = Enum.TextTruncate.AtEnd
end

local audioPanel = panel(gui)
audioPanel.Name = "AudioSettings"; audioPanel.Visible = false; audioPanel.ZIndex = 20; audioPanel.AnchorPoint = Vector2.new(.5, 0); audioPanel.Position = UDim2.fromScale(.5, .095); audioPanel.Size = UDim2.fromOffset(240, 140)
local audioPanelSuppressed = false
local audioPanelBeforeModal = false
local audioTitle = label(audioPanel, "音频设置（本次会话）", 14, C.navy, true); audioTitle.Position = UDim2.fromOffset(14, 8); audioTitle.Size = UDim2.fromOffset(210, 22); audioTitle.ZIndex = 21
local mutedBuses: {[string]: boolean} = {Music = false, SFX = false, Ambience = false}
local audioToggles: {[string]: TextButton} = {}
local function toggleAudio(bus: string, title: string, toggle: TextButton)
	if not ownsCapturedMainGui() then return end
	mutedBuses[bus] = not mutedBuses[bus]
	Audio.setMuted(bus, mutedBuses[bus])
	toggle.Text = title .. (if mutedBuses[bus] then "：关" else "：开")
	if bus ~= "SFX" or not mutedBuses[bus] then Audio.play("UI") end
end
local function audioToggle(bus: string, title: string, y: number)
	local toggle = button(audioPanel, title .. "：开", C.teal); toggle.Position = UDim2.fromOffset(14, y); toggle.Size = UDim2.fromOffset(212, 25); toggle.ZIndex = 21
	audioToggles[bus] = toggle
	toggle.Activated:Connect(function()
		if not ownsCapturedMainGui() then return end
		toggleAudio(bus, title, toggle)
	end)
end
audioToggle("Music", "音乐", 36)
audioToggle("SFX", "音效", 64)
audioToggle("Ambience", "环境", 92)
audioButton.Activated:Connect(function()
	if not ownsCapturedMainGui() then return end
	audioPanel.Visible = not audioPanel.Visible
	Audio.play("UI")
end)

local toast = label(gui, "", 14, C.cream, true); toast.Visible = false; toast.BackgroundColor3 = C.navy; toast.AnchorPoint = Vector2.new(.5, 0); toast.Position = UDim2.fromScale(.5, .115); toast.Size = UDim2.fromOffset(360, 38); toast.TextXAlignment = Enum.TextXAlignment.Center; toast.ZIndex = 10; corner(toast, 12)
local toastToken = 0
local function notify(text: string, good: boolean?)
	if not lifecycle.alive then return end
	toastToken += 1; local token = toastToken; toast.Text = text; toast.BackgroundColor3 = if good then C.green else C.navy; toast.Visible = true
	local generation = lifecycle.generation
	task.delay(3, function()
		if lifecycle.alive and lifecycle.generation == generation and token == toastToken then toast.Visible = false end
	end)
end

local main = panel(gui)
main.Name = "ContentPanel"; main.Visible = false; main.AnchorPoint = Vector2.new(.5, 1); main.Position = UDim2.fromScale(.5, .87); main.Size = UDim2.fromOffset(760, 500)
local mainTitle = label(main, "", 21, C.navy, true); mainTitle.Name = "PageTitle"; mainTitle.Position = UDim2.fromOffset(24, 14); mainTitle.Size = UDim2.fromOffset(470, 30)
local close = button(main, "×", C.navy); close.Name = "CloseButton"; close.Position = UDim2.fromOffset(710, 14); close.Size = UDim2.fromOffset(30, 30)
close.Activated:Connect(function()
	if not ownsCapturedMainGui() then return end
	panelOpen = false
	main.Visible = false
	clearSaleConfirmation()
	clearMergeConfirmation()
	if requestGate and requestGate.incomePreview then requestGate.incomePreview:clear("关闭背包面板") end
	gui:SetAttribute("PanelOpen", false)
	gui:SetAttribute("ActiveTab", activeTab)
	if updateViewportLayout then updateViewportLayout() elseif render then render(true) end
end)
local content = Instance.new("ScrollingFrame"); content.Name = "ContentViewport"; content.BackgroundTransparency = 1; content.BorderSizePixel = 0; content.ScrollBarThickness = 5; content.ScrollBarImageColor3 = C.teal; content.ScrollingDirection = Enum.ScrollingDirection.Y; content.ScrollingEnabled = false; content.AutomaticCanvasSize = Enum.AutomaticSize.None; content.CanvasSize = UDim2.new(); content.Position = UDim2.fromOffset(16, 54); content.Size = UDim2.new(1, -32, 1, -66); content.Parent = main

local fishingCard = panel(gui)
fishingCard.Name = "FishingAction"; fishingCard.AnchorPoint = Vector2.new(.5, 1); fishingCard.Position = UDim2.fromScale(.5, .865); fishingCard.Size = UDim2.fromOffset(360, 130)
local fishTitle = label(fishingCard, "港湾钓点", 19, C.navy, true); fishTitle.Position = UDim2.fromOffset(18, 12); fishTitle.Size = UDim2.fromOffset(190, 25)
fishTitle.TextWrapped = false; fishTitle.TextTruncate = Enum.TextTruncate.AtEnd
local fishDetail = label(fishingCard, "准备好收线", 13, C.muted, false); fishDetail.Position = UDim2.fromOffset(18, 39); fishDetail.Size = UDim2.fromOffset(260, 21)
local fishProgressBack = Instance.new("Frame"); fishProgressBack.BackgroundColor3 = C.paper; fishProgressBack.Position = UDim2.fromOffset(18, 66); fishProgressBack.Size = UDim2.fromOffset(324, 8); fishProgressBack.Parent = fishingCard; corner(fishProgressBack, 4)
local fishProgress = Instance.new("Frame"); fishProgress.BackgroundColor3 = C.teal; fishProgress.Size = UDim2.fromScale(0, 1); fishProgress.Parent = fishProgressBack; corner(fishProgress, 4)
local fishButton = button(fishingCard, "开始连续垂钓", C.teal); fishButton.Position = UDim2.fromOffset(18, 85); fishButton.Size = UDim2.fromOffset(212, 32)
fishButton.Name = "FishingToggle"
local dockButton = button(fishingCard, "前往码头", C.navy2); dockButton.Position = UDim2.fromOffset(238, 85); dockButton.Size = UDim2.fromOffset(104, 32)
dockButton.Name = "DockButton"

local nav = Instance.new("ScrollingFrame"); nav.Name = "NavViewport"; nav.BackgroundColor3 = C.navy; nav.BorderSizePixel = 0; nav.ScrollBarThickness = 0; nav.ScrollingDirection = Enum.ScrollingDirection.X; nav.ScrollingEnabled = false; nav.AutomaticCanvasSize = Enum.AutomaticSize.None; nav.CanvasSize = UDim2.new(); nav.AnchorPoint = Vector2.new(.5, 1); nav.Position = UDim2.fromScale(.5, .985); nav.Size = UDim2.fromOffset(748, 56); nav.Parent = gui; corner(nav, 18); stroke(nav, C.sea, .55)
local navLayout = Instance.new("UIListLayout"); navLayout.FillDirection = Enum.FillDirection.Horizontal; navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center; navLayout.VerticalAlignment = Enum.VerticalAlignment.Center; navLayout.Padding = UDim.new(0, 3); navLayout.SortOrder = Enum.SortOrder.LayoutOrder; navLayout.Parent = nav
local tabs = {"钓鱼", "背包", "水族馆", "合成", "图鉴", "升级", "商店"}
local tabButtons: {[string]: TextButton} = {}
local mobileMenuOpen = false
local menuButton = button(gui, "菜单", C.navy)
menuButton.Name = "MobileMenuButton"
menuButton.ZIndex = 12
local function updateHudVisibility()
	local modal = layout.modal == true
	local showSceneHud = not modal
	header.Visible = showSceneHud
	nav.Visible = showSceneHud and (not layout.compact or mobileMenuOpen)
	menuButton.Visible = showSceneHud and layout.compact
	menuButton.Text = if mobileMenuOpen then "收起" else "菜单"
	fishingCard.Visible = showSceneHud and not panelOpen and not (layout.compact and mobileMenuOpen)
	if modal then
		if not audioPanelSuppressed then
			audioPanelBeforeModal = audioPanel.Visible
			audioPanelSuppressed = true
		end
		audioPanel.Visible = false
		audioButton.Visible = false
	elseif audioPanelSuppressed then
		audioPanel.Visible = audioPanelBeforeModal
		audioPanelSuppressed = false
		audioButton.Visible = true
	else
		audioButton.Visible = true
	end
end
menuButton.Activated:Connect(function()
	if not ownsCapturedMainGui() then return end
	mobileMenuOpen = not mobileMenuOpen
	updateHudVisibility()
	Audio.play("UI")
end)
local function setActiveTab(name: string)
	if not ownsCapturedMainGui() then return end
	if name ~= "背包" then clearSaleConfirmation() end
	if name ~= "合成" then clearMergeConfirmation() end
	if requestGate and requestGate.incomePreview and (activeTab ~= name or (name ~= "背包" and name ~= "合成")) then
		requestGate.incomePreview:clear("切换收益预览页面")
	end
	activeTab = name
	mobileMenuOpen = false
	panelOpen = name ~= "钓鱼"
	main.Visible = panelOpen
	gui:SetAttribute("PanelOpen", panelOpen)
	gui:SetAttribute("ActiveTab", activeTab)
	updateHudVisibility()
	for tab, each in tabButtons do
		setButtonEnabled(each, true, if tab == activeTab then C.teal else C.navy, tab == activeTab)
	end
	if layout.compact then
		local index = table.find(tabs, name)
		if index then
			local itemX = (index - 1) * (layout.navButtonWidth + 3)
			local maximum = math.max(0, nav.CanvasSize.X.Offset - layout.nav.width)
			nav.CanvasPosition = Vector2.new(math.clamp(itemX - math.max(0, (layout.nav.width - layout.navButtonWidth) * .5), 0, maximum), 0)
		end
	end
	if updateViewportLayout then updateViewportLayout() elseif render then render(true) end
end
local function selectBagFish(id: string): boolean
	if not ownsCapturedMainGui() then return false end
	local fish = findFish(id)
	if not fish then return false end
	clearSaleConfirmation()
	if requestGate and requestGate.incomePreview then requestGate.incomePreview:clear("已切换鱼") end
	selectedId = fish.id
	if layout.stackPages then bagDetailReveal = true end
	setActiveTab("背包")
	return true
end
for i, name in tabs do
	local b = button(nav, name, C.navy); b.Name = "Tab_" .. name; b.LayoutOrder = i; b.Size = UDim2.fromOffset(101, 42); b.TextSize = 13; tabButtons[name] = b
	b.Activated:Connect(function()
		if not ownsCapturedMainGui() then return end
		Audio.play("UI")
		setActiveTab(name)
	end)
end
bagShortcut.Activated:Connect(function()
	if not ownsCapturedMainGui() then return end
	Audio.play("UI")
	setActiveTab("背包")
end)

setActiveTabBridge = setActiveTab
if pendingBridgePage then
	local requestedPage = pendingBridgePage
	pendingBridgePage = nil
	setActiveTab(requestedPage)
end

local function setRect(target: GuiObject, rect: ResponsiveLayout.Rect)
	target.Position = UDim2.fromOffset(rect.x, rect.y)
	target.Size = UDim2.fromOffset(rect.width, rect.height)
end

local function contentScrollEnabled(): boolean
	-- Desktop keeps its existing fixed pages, but the expanded exchange page is
	-- intentionally a real scrolling page so all three recipes, inventory rows,
	-- preview and eligible fish remain reachable without enlarging the panel.
	return layout.contentScroll or (activeTab == "商店" and shopMode == "exchange")
end

local function applyViewportLayout()
	if not lifecycle.alive then return end
	setRect(header, layout.header)
	header.AnchorPoint = Vector2.new(0, 0)
	setRect(main, layout.main)
	main.AnchorPoint = Vector2.new(0, 0)
	local contentX = layout.content.x - layout.main.x
	local contentY = layout.content.y - layout.main.y
	content.Position = UDim2.fromOffset(contentX, contentY)
	content.Size = UDim2.fromOffset(layout.content.width, layout.content.height)
	content.ScrollingEnabled = contentScrollEnabled()
	content.ScrollBarThickness = if contentScrollEnabled() then 5 else 0
	setRect(nav, layout.nav)
	nav.AnchorPoint = Vector2.new(0, 0)
	nav.BackgroundTransparency = if layout.compact then .45 else .15
	menuButton.Position = UDim2.fromOffset(layout.nav.x + (layout.nav.width - 64) * .5, layout.nav.y + 2)
	menuButton.Size = UDim2.fromOffset(64, 44)
	-- Expanded navigation sits above the persistent menu handle.
	if layout.compact then nav.Position = UDim2.fromOffset(layout.nav.x, layout.nav.y - 52) end
	navLayout.HorizontalAlignment = if layout.compact then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Center
	nav.ScrollingEnabled = layout.compact
	local navGap = 3
	local navContentWidth = #tabs * layout.navButtonWidth + (#tabs - 1) * navGap + (if layout.compact then 16 else 0)
	nav.CanvasSize = UDim2.fromOffset(math.max(layout.nav.width, navContentWidth), layout.nav.height)
	for _, name in tabs do
		local tab = tabButtons[name]
		tab.Size = UDim2.fromOffset(layout.navButtonWidth, layout.navButtonHeight)
		tab.TextSize = if layout.compact then 14 else 13
	end
	setRect(fishingCard, layout.fishing)
	fishingCard.AnchorPoint = Vector2.new(0, 0)
	updateHudVisibility()
	setRect(audioPanel, layout.audio)
	audioPanel.AnchorPoint = Vector2.new(0, 0)
	local audioButtonHeight = layout.minTouchTarget
	local compactButtonY = if layout.compact then layout.compactBag.y - layout.header.y else 11
	audioButton.Position = UDim2.fromOffset(if layout.compact then layout.header.width - 58 else 482, compactButtonY)
	audioButton.Size = UDim2.fromOffset(if layout.compact then 52 else 62, audioButtonHeight)
	bagShortcut.Visible = layout.compact
	bagShortcut.Position = UDim2.fromOffset(layout.compactBag.x - layout.header.x, layout.compactBag.y - layout.header.y)
	bagShortcut.Size = UDim2.fromOffset(layout.compactBag.width, layout.compactBag.height)
	bagShortcut.TextSize = 13
	header.BackgroundTransparency = .6
	fishingCard.BackgroundTransparency = .55
	logo.Visible = not layout.compact
	sub.Visible = not layout.compact
	storageBadge.Visible = not layout.compact
	tankText.Visible = not layout.compact
	hookText.Visible = not layout.compact or layout.header.width >= 420
	if layout.compact then
		local statsWidth = math.max(1, layout.header.width - 138)
		local coinWidth = if layout.header.width >= 420 then statsWidth * .58 else statsWidth
		coinText.Position = UDim2.fromOffset(10, 3); coinText.Size = UDim2.fromOffset(coinWidth, 21); coinText.TextSize = 14
		incomeText.Position = UDim2.fromOffset(10, 25); incomeText.Size = UDim2.fromOffset(statsWidth, 17); incomeText.TextSize = 11
		hookText.Position = UDim2.fromOffset(16 + coinWidth, 5); hookText.Size = UDim2.fromOffset(math.max(1, statsWidth - coinWidth - 6), 20); hookText.TextSize = 12
		mainTitle.Position = UDim2.fromOffset(12, 10); mainTitle.Size = UDim2.fromOffset(math.max(1, layout.main.width - 72), 32)
		mainTitle.TextSize = 18
	else
		sub.Visible = true
		logo.Position = UDim2.fromOffset(18, 4); logo.Size = UDim2.fromOffset(148, 28)
		sub.Position = UDim2.fromOffset(19, 31); sub.Size = UDim2.fromOffset(130, 17)
		logo.TextSize = 17; sub.TextSize = 10
		coinText.Position = UDim2.fromOffset(182, 8); coinText.Size = UDim2.fromOffset(116, 24); coinText.TextSize = 16
		incomeText.Position = UDim2.fromOffset(182, 34); incomeText.Size = UDim2.fromOffset(136, 20); incomeText.TextSize = 13
		hookText.Position = UDim2.fromOffset(330, 9); hookText.Size = UDim2.fromOffset(112, 22); hookText.TextSize = 14
		tankText.Position = UDim2.fromOffset(330, 34); tankText.Size = UDim2.fromOffset(140, 20); tankText.TextSize = 13
		storageBadge.Position = UDim2.fromOffset(550, 22); storageBadge.Size = UDim2.fromOffset(80, 20); storageBadge.TextSize = 11
		mainTitle.Position = UDim2.fromOffset(24, 14); mainTitle.Size = UDim2.fromOffset(math.max(1, layout.main.width - 88), 30)
		mainTitle.TextSize = 21
	end
	local closeSize = layout.minTouchTarget
	close.Position = UDim2.fromOffset(layout.main.width - closeSize - 12, if layout.compact then 10 else 14)
	close.Size = UDim2.fromOffset(closeSize, closeSize)
	local audioWidth = math.max(1, layout.audio.width - 28)
	for bus, toggle in audioToggles do
		toggle.Size = UDim2.fromOffset(audioWidth, layout.minTouchTarget)
		toggle.Position = UDim2.fromOffset(14, if bus == "Music" then 36 elseif bus == "SFX" then 36 + layout.minTouchTarget + 4 else 36 + (layout.minTouchTarget + 4) * 2)
	end
	if layout.compact or layout.touch then
		fishTitle.Position = UDim2.fromOffset(8, 4); fishTitle.Size = UDim2.fromOffset(layout.fishing.width - 16, 18); fishTitle.TextSize = 13
		fishDetail.Position = UDim2.fromOffset(8, 23); fishDetail.Size = UDim2.fromOffset(layout.fishing.width - 16, 16); fishDetail.TextSize = 11; fishDetail.TextYAlignment = Enum.TextYAlignment.Center
		fishDetail.TextWrapped = false; fishDetail.TextTruncate = Enum.TextTruncate.AtEnd
		fishProgressBack.Position = UDim2.fromOffset(8, 42); fishProgressBack.Size = UDim2.fromOffset(layout.fishing.width - 16, 4)
		local half = (layout.fishing.width - 22) * .5
		fishButton.Position = UDim2.fromOffset(8, 50); fishButton.Size = UDim2.fromOffset(half, 44); fishButton.TextSize = 12
		dockButton.Position = UDim2.fromOffset(14 + half, 50); dockButton.Size = UDim2.fromOffset(half, 44); dockButton.TextSize = 12
	else
		fishTitle.TextSize = 19; fishDetail.TextWrapped = true
		fishTitle.Position = UDim2.fromOffset(18, 12); fishTitle.Size = UDim2.fromOffset(190, 25)
		fishDetail.Position = UDim2.fromOffset(18, 39); fishDetail.Size = UDim2.fromOffset(260, 21); fishDetail.TextSize = 13; fishDetail.TextYAlignment = Enum.TextYAlignment.Center
		fishProgressBack.Position = UDim2.fromOffset(18, 66); fishProgressBack.Size = UDim2.fromOffset(324, 8)
		fishButton.Position = UDim2.fromOffset(18, 85); fishButton.Size = UDim2.fromOffset(212, 32)
		dockButton.Position = UDim2.fromOffset(238, 85); dockButton.Size = UDim2.fromOffset(104, 32)
	end
	toast.Position = UDim2.fromOffset(layout.width * .5, layout.header.y + layout.header.height + 4)
	toast.Size = UDim2.fromOffset(math.min(360, math.max(1, layout.safeWidth - 16)), if layout.touch then 44 else 38)
	if render then render(true) end
end

updateViewportLayout = function()
	if not lifecycle.alive then return end
	local camera = workspace.CurrentCamera
	local rootSize = layoutRoot.AbsoluteSize
	if forcedLayoutViewport then
		layout = ResponsiveLayout.compute(forcedLayoutViewport.width, forcedLayoutViewport.height, nil, nil, nil, nil, forcedLayoutViewport.touch, panelOpen)
	elseif rootSize.X > 0 and rootSize.Y > 0 then
		layout = ResponsiveLayout.compute(rootSize.X, rootSize.Y, nil, nil, nil, nil, UserInputService.TouchEnabled, panelOpen)
	elseif camera then
		local size = camera.ViewportSize
		layout = ResponsiveLayout.compute(size.X, size.Y, nil, nil, nil, nil, UserInputService.TouchEnabled, panelOpen)
	end
	applyViewportLayout()
end

local function bindViewportCamera(camera: Camera?)
	if viewportConnection then viewportConnection:Disconnect(); viewportConnection = nil end
	if camera then viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateViewportLayout) end
end

bindViewportCamera(workspace.CurrentCamera)
rootSizeConnection = layoutRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateViewportLayout)
cameraConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindViewportCamera(workspace.CurrentCamera)
	updateViewportLayout()
end)
updateViewportLayout()

local function actionPending(action: string): boolean
	return (requestGate ~= nil and requestGate:isPending(action)) or lifecycle.mutationState:isPending(action)
end
local function anyRequestPending(): boolean
	return (requestGate ~= nil and requestGate:anyPending()) or lifecycle.mutationState:anyPending()
end

local function copyIds(ids: {string}): {string}
	local copy = {}
	for _, id in ipairs(ids) do table.insert(copy, id) end
	return copy
end

requestGate = UiRepair.newRequestGate(function(fn: () -> ())
	local generation = lifecycle.generation
	task.spawn(function()
		if ownsCapturedMainGui(generation, gui, mainGuiOwnerToken) then fn() end
	end)
end, function()
	if ownsCapturedMainGui() and render then render(true) end
end)

requestGate.incomePreview = require(script.Parent:WaitForChild("IncomePreviewController")).new({
	invoke = function(payload: any)
		local generation = lifecycle.generation
		local ownerGui = gui
		local ownerToken = mainGuiOwnerToken
		if not ownsCapturedMainGui(generation, ownerGui, ownerToken) then return nil end
		local ok, result = pcall(function() return request:InvokeServer("incomePreview", payload) end)
		if not ownsCapturedMainGui(generation, ownerGui, ownerToken) or not ok then return nil end
		return result
	end,
	schedule = function(fn: () -> ())
		local generation = lifecycle.generation
		task.spawn(function()
			if ownsCapturedMainGui(generation, gui, mainGuiOwnerToken) then fn() end
		end)
	end,
	delay = function(fn: () -> (), seconds: number)
		local generation = lifecycle.generation
		task.delay(seconds, function()
			if ownsCapturedMainGui(generation, gui, mainGuiOwnerToken) then fn() end
		end)
	end,
	clock = os.clock,
		onChanged = function()
		if ownsCapturedMainGui() and render then render(true) end
	end,
	})

local function invokeSnapshotBounded(payload: any): (boolean, any)
	local finished = false
	local callOk = false
	local response: any = nil
	task.spawn(function()
		local ok, result = pcall(function() return request:InvokeServer("snapshot", payload) end)
		if finished then return end
		finished, callOk, response = true, ok, result
	end)
	local deadline = os.clock() + 4
	while not finished and os.clock() < deadline do task.wait(.05) end
	if not finished then
		finished = true
		return false, nil
	end
	return callOk, response
end

function lifecycle.recoverMutation(action: string, ownerGeneration: number, ownerGui: ScreenGui, ownerToken: string)
	task.spawn(function()
		for attempt = 1, 2 do
			if not lifecycle.mutationState:beginResync(action) then return end
			if attempt > 1 then task.wait(.5) end
			if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return end
			local epoch = lifecycle.mutationState:getEpoch()
			if not epoch then return end
			local ok, response = invokeSnapshotBounded({stateEpoch = epoch})
			if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return end
			if ok and type(response) == "table" and type(response.state) == "table" then
				local accepted, released = setSnapshot(response.state, false)
				if not accepted then continue end
				if released > 0 then
					notify("状态已更新，请检查本次操作结果")
					if render then render(true) end
					return
				end
				local status = lifecycle.mutationState:reconcile(action, nil, response.ok == true)
				if status == "released-check-state" then
					notify("状态已更新，请检查本次操作结果")
					if render then render(true) end
					return
				end
				if not lifecycle.mutationState:unknown(action) then return end
			end
		end
		if lifecycle.mutationState:manualRecoveryRequired(action) and ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then
			notify("操作结果未知，请退出并重新加入游戏检查结果")
			if render then render(true) end
		end
	end)
end

function lifecycle.completeRequest(action: string, ownerGeneration: number, ownerGui: ScreenGui, ownerToken: string, ok: boolean, result: any, submittedMergeIds: {string})
	if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return end
	-- Known responses invalidate confirmation state. A transport-unknown lane
	-- keeps the exact intent so the player can retry the same sequence.
	local lane = lifecycle.mutationState:isLane(action)
	local unknownResult = lane and type(result) == "table" and result.mutationStatus == "unknown"
	if (ok and not unknownResult) or not lane then
		clearSaleConfirmation()
		clearMergeConfirmation()
		if action == "exchange" then clearExchangeConfirmation() end
	end
	if not ok then
		if lifecycle.mutationState:isLane(action) then
			lifecycle.mutationState:markTransportUnknown(action)
			notify("连接暂不可用，正在保留本次操作")
			lifecycle.recoverMutation(action, ownerGeneration, ownerGui, ownerToken)
		else
			notify("连接暂不可用")
		end
	else
		local acceptedState = true
		local released = 0
		if result and result.state then acceptedState, released = setSnapshot(result.state, false) end
		if lifecycle.mutationState:isLane(action) then
			if result and result.mutationStatus == "unknown" then
				lifecycle.mutationState:markTransportUnknown(action)
				lifecycle.recoverMutation(action, ownerGeneration, ownerGui, ownerToken)
			elseif released > 0 then
				notify("状态已更新，请检查本次操作结果")
			else
				local status = lifecycle.mutationState:reconcile(action, if acceptedState and result then result.state else nil, result and result.ok == true)
				if status == "released-check-state" then notify("状态已更新，请检查本次操作结果") end
			end
		end
		if result and action == "merge" then mergeIds = UiRepair.selectionAfterResponse(mergeIds, submittedMergeIds, result.ok == true) end
		if result and result.ok == true and action == "sellDuplicates" then duplicateConfirm = false end
		if result and result.ok == true and action == "exchange" then exchangeSelectedIds = {} end
		if result and result.ok == true and action == "useItem" then useItemConfirmId = nil; useItemRequestId = nil end
		if result and result.message then notify(result.message, result.ok) end
	end
	if ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) and render then render(true) end
end

local function send(action: string, payload: any?): boolean
	local ownerGui = gui
	local ownerGeneration = lifecycle.generation
	local ownerToken = mainGuiOwnerToken
	if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return false end
	local requestPayload: any = payload or {}
	if lifecycle.mutationState:isLane(action) then
		if requestGate:anyPending() then notify("操作处理中，请稍候"); return false end
		local laneOk, lanePayload, laneReason = lifecycle.mutationState:begin(action, requestPayload)
		if not laneOk then
			if laneReason == "mutation-unknown" then notify("上次操作结果未知，请保持相同操作重试；若仍未知，请退出并重新加入游戏检查结果") else notify("操作处理中，请稍候") end
			return false
		end
		requestPayload = lanePayload
	end
	local submittedMergeIds = if action == "merge" and type(requestPayload.ids) == "table" then copyIds(requestPayload.ids) else {}
	if lifecycle.mutationState:isLane(action) then
		local operationSeq = requestPayload.operationSeq
		local attempt = lifecycle.mutationState:attempt(action)
		task.spawn(function()
			local finished = false
			task.delay(8, function()
				if finished or not lifecycle.mutationState:isCurrent(action, operationSeq, attempt) then return end
				finished = true
				lifecycle.mutationState:markTransportUnknown(action)
				notify("连接响应超时，正在保留本次操作")
				lifecycle.recoverMutation(action, ownerGeneration, ownerGui, ownerToken)
				if ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) and render then render(true) end
			end)
			local ok, result = pcall(function() return request:InvokeServer(action, requestPayload) end)
			if finished or not lifecycle.mutationState:isCurrent(action, operationSeq, attempt) then return end
			finished = true
			lifecycle.completeRequest(action, ownerGeneration, ownerGui, ownerToken, ok, result, submittedMergeIds)
		end)
		if (action == "travel" or action == "visitAquarium") and catchPresentation then catchPresentation:cancel("travel") end
		if ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) and render then render(true) end
		return true
	end
	local accepted = requestGate:begin(action, function()
		if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return nil end
		local ok, result = pcall(function() return request:InvokeServer(action, requestPayload) end)
		if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return nil end
		if not ok then error(result) end
		return result
			end, function(ok, result) lifecycle.completeRequest(action, ownerGeneration, ownerGui, ownerToken, ok, result, submittedMergeIds) end)
	if not accepted then
		if not ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) then return false end
		notify("操作处理中，请稍候")
		return false
	end
	if (action == "travel" or action == "visitAquarium") and catchPresentation then
		catchPresentation:cancel("travel")
	end
	if ownsCapturedMainGui(ownerGeneration, ownerGui, ownerToken) and render then render(true) end
	return true
end

local function makeFishCard(parent: Instance, fish: any, width: number, click: ((any) -> ())?): TextButton
	local b = button(parent, "", C.paper, false, true); b.Name = "FishCard_" .. tostring(fish.id); b.Text = ""; b.BackgroundColor3 = C.paper; b.Size = UDim2.fromOffset(width, 80); stroke(b, fishColor(fish), .35)
	b:SetAttribute("SalePrice", exactSaleQuote(fish, snapshot))
	local icon = Instance.new("Frame"); icon.BackgroundColor3 = fishColor(fish); icon.Position = UDim2.fromOffset(8, 10); icon.Size = UDim2.fromOffset(58, 58); icon.Parent = b; corner(icon, 18)
	local species = speciesForFish(fish)
	local _, fishArt = mountFishPreview(icon, species, fish)
	if fishArt then b:SetAttribute("FishVisualSource", fishArt:GetAttribute("FishVisualSource") or "ProceduralFallback") end
	local name = label(b, speciesName(fish), 14, C.ink, true); name.Position = UDim2.fromOffset(75, 7); name.Size = UDim2.new(1, -84, 0, 20)
	local info = label(b, "Lv." .. tostring(fish.level) .. " · " .. fishWeight(fish) .. " · 售价 " .. moneyPrecise(exactSaleQuote(fish, snapshot)), 10, C.muted, false); info.Position = UDim2.fromOffset(75, 29); info.Size = UDim2.new(1, -84, 0, 18)
	local _, sizeName, mutationName = fishDescriptors(fish)
	local placedTag = fish.placed and " · 已入缸" or ""
	local lockTag = fish.locked and " · 已锁" or ""
	local showcaseTag = snapshot and snapshot.showcaseFishId == fish.id and " · 已选炫耀鱼" or ""
	local tags = label(b, traitText(fish) .. " · " .. sizeName .. "·" .. mutationName .. lockTag .. placedTag .. showcaseTag, 9, if fish.locked then C.gold elseif fish.placed then C.navy2 else C.teal, true); tags.Position = UDim2.fromOffset(75, 49); tags.Size = UDim2.new(1, -84, 0, 17)
	if click then b.Activated:Connect(function() click(fish) end) end
	return b
end

local function scroll(parent: Instance): ScrollingFrame
	local s = Instance.new("ScrollingFrame"); s.BackgroundTransparency = 1; s.BorderSizePixel = 0; s.ScrollBarThickness = 5; s.ScrollBarImageColor3 = C.teal; s.AutomaticCanvasSize = Enum.AutomaticSize.Y; s.CanvasSize = UDim2.new(); s.Parent = parent
	return s
end
local function listLayout(parent: Instance, padding: number)
	local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, padding); l.Parent = parent; return l
end

local function setPageCanvas(height: number)
	if contentScrollEnabled() then
		content.CanvasSize = UDim2.fromOffset(layout.content.width, math.max(layout.content.height, height))
	else
		content.CanvasSize = UDim2.new()
	end
end

local function pageWidth(): number
	return layout.content.width
end

local function bagDetailLayout(width: number): ResponsiveLayout.BagDetailMetrics
	return ResponsiveLayout.computeBagDetail(width, layout.stackPages, layout.landscape, layout.modal)
end

local function populateBagDetail(detail: Frame, fish: any?, bagCount: number, placedCount: number, bagCapacity: number, tankCapacity: number)
	if not fish then
		local empty = label(detail, "选择一条鱼", 17, C.muted, true); empty.Name = "BagDetailEmpty"; empty.Size = UDim2.new(1, 0, 1, 0); empty.TextXAlignment = Enum.TextXAlignment.Center
		return
	end
	local function incomePreviewLine(previewState: any, preview: any, actionLabel: string): string
		if not previewState or previewState.status == "loading" then return "收益预览：请求中…" end
		if previewState.status == "error" then return "收益预览：" .. tostring(previewState.reason or "待更新") .. " · 请重新选择" end
		if previewState.status ~= "ready" or type(preview) ~= "table" then return "收益预览：待更新" end
		if preview.ok ~= true then return "收益预览：不可执行 · " .. tostring(preview.reason or "当前状态不可用") end
		if type(preview.projectedTotalPerHour) ~= "number" or preview.projectedTotalPerHour ~= preview.projectedTotalPerHour or preview.projectedTotalPerHour == math.huge or preview.projectedTotalPerHour == -math.huge
			or type(preview.deltaPerHour) ~= "number" or preview.deltaPerHour ~= preview.deltaPerHour or preview.deltaPerHour == math.huge or preview.deltaPerHour == -math.huge then
			return "收益预览：数据待更新"
		end
		local total = preview.projectedTotalPerHour
		local delta = preview.deltaPerHour
		local line = string.format("%s鱼缸总时产 %s (%+.2f)", actionLabel, moneyPrecise(total), delta)
		if preview.allowed ~= true then line ..= " · " .. tostring(preview.reason or "当前不可执行") end
		return line
	end
	local compact = layout.stackPages
	local width = detail.AbsoluteSize.X > 0 and detail.AbsoluteSize.X or pageWidth()
	local detailMetrics = bagDetailLayout(width)
	local horizontal = detailMetrics.horizontal
	if requestGate and requestGate.incomePreview and snapshot then requestGate.incomePreview:requestDetail(snapshot, fish.id) end
	local previewState = if requestGate and requestGate.incomePreview then requestGate.incomePreview:state() else nil
	local preview = if horizontal then detailMetrics.preview else {x = (width - 100) * .5, y = if compact then 16 else 20, width = 100, height = 100}
	local col = fishColor(fish); local orb = Instance.new("Frame"); orb.Name = "FishPreview"; orb.BackgroundColor3 = col; orb.Position = UDim2.fromOffset(preview.x, preview.y); orb.Size = UDim2.fromOffset(preview.width, preview.height); orb.Parent = detail; corner(orb, if horizontal then 56 else 45)
	local _, detailArt = mountFishPreview(orb, speciesForFish(fish), fish)
	if detailArt then detail:SetAttribute("FishVisualSource", detailArt:GetAttribute("FishVisualSource") or "ProceduralFallback") end
	local title = label(detail, speciesName(fish), 19, C.ink, true); title.Name = "BagDetailTitle"; title.TextXAlignment = if horizontal then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center; title.Position = if horizontal then UDim2.fromOffset(detailMetrics.info.x, 12) else UDim2.fromOffset(12, if compact then 124 else 130); title.Size = UDim2.fromOffset(if horizontal then detailMetrics.info.width else math.max(1, width - 24), 27)
	local rarityName, sizeName, mutationName = fishDescriptors(fish)
	local sale = exactSaleQuote(fish, snapshot)
	local saleConfirming = saleConfirmId == fish.id and saleExpectedPrice ~= nil
	local placementAction = if fish.placed then "remove" else "place"
	local placementState = UiRepair.actionState(placementAction, fish, {placedCount = placedCount, tankCapacity = tankCapacity, bagCount = bagCount, bagCapacity = bagCapacity})
	local saleState = UiRepair.actionState("sell", fish, {showcaseFishId = snapshot and snapshot.showcaseFishId, requireSaleQuote = true})
	local placementPending = anyRequestPending()
	local placementEnabled = placementState.enabled and not placementPending and not saleConfirming
	local placementText = if saleConfirming then "先取消出售确认" elseif placementPending then "处理中…" elseif placementState.enabled then (if fish.placed then "移出水族馆" else "放入水族馆") else placementState.reason
	local locationText = fish.placed and "正在水族馆中" or "背包中"
	if not placementState.enabled then locationText = placementState.reason elseif not saleState.enabled then locationText = locationText .. " · 不可出售" end
	local showcaseActive = snapshot and snapshot.showcaseFishId == fish.id
	local showcaseState = if fish.placed then "已入缸的鱼不能展示" elseif showcaseActive then (if snapshot and snapshot.fishing then "已选炫耀鱼 · 钓鱼时暂收起，加成保留" else "已选炫耀鱼 · 特性加成已计入有效属性") elseif snapshot and snapshot.showcaseFishId then "会替换当前展示鱼" else "未展示"
	local placementPreview = previewState and previewState.response and previewState.response.placement
	local showcasePreview = previewState and previewState.response and previewState.response.showcase
	local placementPreviewText = incomePreviewLine(previewState, placementPreview, if fish.placed then "移出后" else "放入后")
	local showcasePreviewText = incomePreviewLine(previewState, showcasePreview, if showcaseActive then "收起展示后" else "展示后")
	local statsText = if horizontal then string.format("%s · %s · %s · Lv.%d\n%s · 特性：%s\n售价 %s · 基础时产 %s 金币\n%s\n%s", rarityName, sizeName, mutationName, fish.level, fishWeight(fish), traitText(fish), moneyPrecise(sale), moneyPrecise(fish.income), locationText, showcaseState) elseif compact then string.format("%s · %s · %s\n%s · 特性：%s\n等级 Lv.%d\n实际售价 %s 金币\n基础时产 %s 金币\n%s\n%s\n%s\n%s", rarityName, sizeName, mutationName, fishWeight(fish), traitText(fish), fish.level, moneyPrecise(sale), moneyPrecise(fish.income), locationText, showcaseState, placementPreviewText, showcasePreviewText) else string.format("%s · %s · %s · Lv.%d\n%s · 特性：%s\n售价 %s · 基础时产 %s 金币\n%s · %s\n%s\n%s", rarityName, sizeName, mutationName, fish.level, fishWeight(fish), traitText(fish), moneyPrecise(sale), moneyPrecise(fish.income), locationText, showcaseState, placementPreviewText, showcasePreviewText)
	local statsHeight = if compact then 118 else 86
	local stats = label(detail, statsText, if horizontal then 13 elseif compact then 11 else 10, C.muted, false); stats.Name = "BagDetailStats"; stats.TextYAlignment = if horizontal then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center; stats.Position = if horizontal then UDim2.fromOffset(detailMetrics.info.x, 44) else UDim2.fromOffset(12, if compact then 157 else 158); stats.Size = UDim2.fromOffset(if horizontal then detailMetrics.info.width else math.max(1, width - 24), if horizontal then detailMetrics.info.height - 44 else statsHeight)
	local firstActionY = if compact then 282 else 240
	local actionHeight = if compact then 44 else 30
	local actionWidth = if compact then width - 24 else 118
	local a = button(detail, placementText, if placementEnabled then C.teal else C.muted); a.Name = "PlacementAction"; if horizontal then local r = detailMetrics.actions[1]; a.Position = UDim2.fromOffset(r.x, r.y); a.Size = UDim2.fromOffset(r.width, r.height) else a.Position = UDim2.fromOffset(if compact then 12 else 18, firstActionY); a.Size = UDim2.fromOffset(math.max(1, actionWidth), actionHeight) end; if horizontal then a.TextSize = 12; a.TextWrapped = true end; setButtonEnabled(a, placementEnabled, C.teal); a.Activated:Connect(function() if placementEnabled then send(placementAction, {id = fish.id}) else notify(if saleConfirming then "请先取消出售确认" else placementState.reason) end end)
	local lockPending = anyRequestPending()
	local lockWidth = if compact then math.max(1, (width - 30) * .5) else 118
	local lockY = if compact then firstActionY + actionHeight + 8 else 280
	local lockEnabled = not lockPending and not saleConfirming
	local b = button(detail, if lockPending then "处理中…" elseif saleConfirming then "先取消出售确认" else (fish.locked and "解除锁定" or "锁定保护"), C.navy2); b.Name = "LockAction"; if horizontal then local r = detailMetrics.actions[2]; b.Position = UDim2.fromOffset(r.x, r.y); b.Size = UDim2.fromOffset(r.width, r.height) else b.Position = UDim2.fromOffset(if compact then 12 else 18, lockY); b.Size = UDim2.fromOffset(lockWidth, actionHeight) end; if horizontal then b.TextSize = 12; b.TextWrapped = true end; setButtonEnabled(b, lockEnabled, C.navy2); b.Activated:Connect(function() if lockEnabled then send("lock", {id = fish.id, locked = not fish.locked}) else notify(if saleConfirming then "请先取消出售确认" else "操作处理中，请稍候") end end)
	local salePending = anyRequestPending()
	local saleEnabled = saleState.enabled and not salePending
	local saleText = if salePending then "处理中…" elseif saleConfirming then "取消出售" elseif saleState.enabled then "出售" else "不可出售"
	local c = button(detail, saleText, if saleEnabled then C.gold else C.muted); c.Name = "SaleAction"; if horizontal then local r = detailMetrics.actions[3]; c.Position = UDim2.fromOffset(r.x, r.y); c.Size = UDim2.fromOffset(r.width, r.height) else c.Position = UDim2.fromOffset(if compact then 18 + lockWidth + 6 else 144, lockY); c.Size = UDim2.fromOffset(if compact then lockWidth else 118, actionHeight) end; if horizontal then c.TextSize = 12; c.TextWrapped = true end; setButtonEnabled(c, saleEnabled, C.gold)
	c.Activated:Connect(function()
		if salePending then notify("操作处理中，请稍候") elseif saleConfirming then clearSaleConfirmation(); render(true) elseif saleState.enabled then
			if not saleQuoteAvailable(fish) then notify("售价待同步，请刷新") else
				saleConfirmId = fish.id
				saleExpectedPrice = fish.salePrice
				saleConfirmationKey = saleConfirmationSignature(fish)
				render(true)
			end
		else notify(saleState.reason) end
	end)
	local showcaseAction = if showcaseActive then "hideFish" else "showcase"
	local showcasePending = actionPending("showcase") or actionPending("hideFish")
	local showcaseEnabled = not fish.placed and not showcasePending
	local showcaseText = if showcasePending then "处理中…" elseif showcaseActive then "收起展示" elseif snapshot and snapshot.showcaseFishId then "替换展示鱼" else "抱出来展示"
	local showcaseButton = button(detail, if saleConfirming then "确认出售 " .. moneyPrecise(saleExpectedPrice) else showcaseText, saleConfirming and saleEnabled and C.gold or (showcaseEnabled and C.teal or C.muted)); showcaseButton.Name = if saleConfirming then "SaleConfirmAction" else "ShowcaseAction"; if horizontal then local r = detailMetrics.actions[4]; showcaseButton.Position = UDim2.fromOffset(r.x, r.y); showcaseButton.Size = UDim2.fromOffset(r.width, r.height) else showcaseButton.Position = UDim2.fromOffset(if compact then 12 else 144, if compact then lockY + actionHeight + 8 else firstActionY); showcaseButton.Size = UDim2.fromOffset(if compact then math.max(1, width - 24) else 118, actionHeight) end; if horizontal then showcaseButton.TextSize = 12; showcaseButton.TextWrapped = true end; setButtonEnabled(showcaseButton, if saleConfirming then saleEnabled else showcaseEnabled, saleConfirming and C.gold or C.teal)
	showcaseButton.Activated:Connect(function()
		if saleConfirming then
			if saleEnabled and saleExpectedPrice ~= nil then send("sell", {id = fish.id, expectedSalePrice = saleExpectedPrice}) else notify(saleState.reason) end
		elseif not showcaseEnabled then notify(if fish.placed then "已入缸的鱼不能展示" else "展示操作处理中，请稍候") elseif showcaseAction == "hideFish" then send("hideFish", {}) else send("showcase", {id = fish.id}) end
	end)
	if horizontal then
		local previewX = detailMetrics.actions[1].x
		local previewRight = detailMetrics.actions[4].x + detailMetrics.actions[4].width
		local previewWidth = math.max(1, previewRight - previewX)
		local placementPreviewLabel = label(detail, placementPreviewText, 11, C.muted, false)
		placementPreviewLabel.Name = "PlacementIncomePreview"
		placementPreviewLabel.Position = UDim2.fromOffset(previewX, 128)
		placementPreviewLabel.Size = UDim2.fromOffset(previewWidth, 28)
		placementPreviewLabel.TextYAlignment = Enum.TextYAlignment.Top
		local showcasePreviewLabel = label(detail, showcasePreviewText, 11, C.muted, false)
		showcasePreviewLabel.Name = "ShowcaseIncomePreview"
		showcasePreviewLabel.Position = UDim2.fromOffset(previewX, 160)
		showcasePreviewLabel.Size = UDim2.fromOffset(previewWidth, 28)
		showcasePreviewLabel.TextYAlignment = Enum.TextYAlignment.Top
		local back = button(detail, "返回鱼列表", C.navy2)
		back.Name = "BagDetailBack"
		back.Position = UDim2.fromOffset(preview.x, preview.y + preview.height + 8)
		back.Size = UDim2.fromOffset(preview.width, 44)
		back.TextSize = 12
		back.TextWrapped = true
			back.Activated:Connect(function()
				clearSaleConfirmation()
				if requestGate and requestGate.incomePreview then requestGate.incomePreview:clear("返回鱼列表") end
				selectedId = nil
				bagDetailReveal = false
				pendingScrollPosition = Vector2.zero
			if render then render(true) end
		end)
	end
end

local function renderBag()
	local fishList = snapshot and snapshot.fish or {}
	if saleConfirmId then
		local confirmingFish = findFish(saleConfirmId)
		local confirmationState = UiRepair.saleConfirmationState(confirmingFish, saleExpectedPrice, saleConfirmationKey, snapshot and snapshot.showcaseFishId)
		if not confirmationState.enabled then clearSaleConfirmation() end
	end
	local bagCount = UiRepair.countUnplaced(fishList)
	local placedCount = UiRepair.countPlaced(fishList)
	local bagCapacity = snapshot and snapshot.bagCapacity or 0
	local tankCapacity = snapshot and snapshot.tankCapacity or 0
	mainTitle.Text = "背包  ·  " .. tostring(bagCount) .. "/" .. tostring(bagCapacity)
	clear(content)
	local filters = {"全部", "未入缸", "已入缸", "已锁定"}
	local filtered = {}
	for _, f in fishList do
		if bagFilter == "全部" or (bagFilter == "未入缸" and not f.placed) or (bagFilter == "已入缸" and f.placed) or (bagFilter == "已锁定" and f.locked) then table.insert(filtered, f) end
	end
	local perPage = 24
	local pages = math.max(1, math.ceil(#filtered / perPage)); bagPage = math.clamp(bagPage, 1, pages)
	local firstIndex = (bagPage - 1) * perPage + 1
	local lastIndex = math.min(#filtered, bagPage * perPage)
	local visibleCount = math.max(0, lastIndex - firstIndex + 1)
	local width = pageWidth()
	local listY: number
	local listHeight: number
	local detailY: number
	local detailHeight: number
	local landscapeModal = layout.modal and layout.landscape
	local detailMetrics = bagDetailLayout(width)
	if layout.stackPages then
		local filterBarWidth = if landscapeModal then math.max(44, width - 156) else width
		local filterBar = Instance.new("ScrollingFrame"); filterBar.Name = "BagFilters"; filterBar.BackgroundTransparency = 1; filterBar.BorderSizePixel = 0; filterBar.ScrollBarThickness = 0; filterBar.ScrollingDirection = Enum.ScrollingDirection.X; filterBar.ScrollingEnabled = true; filterBar.Size = UDim2.fromOffset(filterBarWidth, 48); filterBar.Position = UDim2.fromOffset(0, 0); filterBar.CanvasSize = UDim2.fromOffset(#filters * 84 + (#filters - 1) * 6, 48); filterBar.Parent = content
		local filterLayout = Instance.new("UIListLayout"); filterLayout.FillDirection = Enum.FillDirection.Horizontal; filterLayout.Padding = UDim.new(0, 6); filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center; filterLayout.SortOrder = Enum.SortOrder.LayoutOrder; filterLayout.Parent = filterBar
		for i, f in filters do
			local b = button(filterBar, f, if bagFilter == f then C.teal else C.navy2, bagFilter == f); b.Name = "BagFilter_" .. f; b.LayoutOrder = i; b.Size = UDim2.fromOffset(84, 44); b.TextSize = 12; b.Activated:Connect(function() bagFilter = f; bagPage = 1; render(true) end)
		end
		local note = label(content, string.format("第 %d / %d 页 · 每页 24 条", bagPage, pages), 12, C.muted, false); note.Name = "BagPageLabel"; note.TextWrapped = false
		if landscapeModal then
			note.Text = string.format("%d/%d", bagPage, pages)
			note.Position = UDim2.fromOffset(width - 150, 0); note.Size = UDim2.fromOffset(54, 44); note.TextXAlignment = Enum.TextXAlignment.Center
		else
			note.Position = UDim2.fromOffset(0, 52); note.Size = UDim2.fromOffset(math.max(1, width - 104), 44)
		end
		local prev = button(content, "‹", C.navy2); prev.Name = "BagPrev"; prev.Position = UDim2.fromOffset(width - 96, if landscapeModal then 0 else 52); prev.Size = UDim2.fromOffset(44, 44); setButtonEnabled(prev, bagPage > 1, C.navy2); prev.Activated:Connect(function() if bagPage > 1 then bagPage -= 1; render(true) end end)
		local nextB = button(content, "›", C.navy2); nextB.Name = "BagNext"; nextB.Position = UDim2.fromOffset(width - 48, if landscapeModal then 0 else 52); nextB.Size = UDim2.fromOffset(44, 44); setButtonEnabled(nextB, bagPage < pages, C.navy2); nextB.Activated:Connect(function() if bagPage < pages then bagPage += 1; render(true) end end)
		if landscapeModal then
			listY = 52
		else
			local cleanup = panel(content); cleanup.Name = "BagCleanup"; cleanup.Position = UDim2.fromOffset(0, 102); cleanup.Size = UDim2.fromOffset(width, 92); cleanup.BackgroundColor3 = C.paper
			local cleanupText = label(cleanup, duplicateConfirm and "确认后仅出售符合条件的重复鱼，无法撤销。" or "仅卖普通～稀有的一级、普通变异、小型/标准鱼；每种至少保留 3 条。锁定、入缸和高级鱼不卖。", 10, C.muted, false); cleanupText.Position = UDim2.fromOffset(12, 4); cleanupText.Size = UDim2.fromOffset(math.max(1, width - 24), 32)
			local cleanupPending = anyRequestPending()
			local cleanupButton = button(cleanup, if cleanupPending then "处理中…" elseif duplicateConfirm then "确认出售重复鱼" else "清理重复鱼", if cleanupPending then C.muted elseif duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending); cleanupButton.Name = "DuplicateSaleAction"; cleanupButton.Position = UDim2.fromOffset(12, 42); cleanupButton.Size = UDim2.fromOffset(math.max(1, width - 24), 44); setButtonEnabled(cleanupButton, not cleanupPending, if duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending)
			cleanupButton.Activated:Connect(function() if cleanupPending then notify("操作处理中，请稍候") elseif duplicateConfirm then send("sellDuplicates", {}) else duplicateConfirm = true; render(true) end end)
			listY = 204
		end
		listHeight = math.max(80, visibleCount * 87 - 7)
	else
		for i, f in filters do local b = button(content, f, if bagFilter == f then C.teal else C.navy2, bagFilter == f); b.Name = "BagFilter_" .. f; b.Position = UDim2.fromOffset((i - 1) * 92, 0); b.Size = UDim2.fromOffset(84, 28); b.Activated:Connect(function() bagFilter = f; bagPage = 1; render(true) end) end
		local note = label(content, string.format("第 %d / %d 页 · 每页 24 条", bagPage, pages), 12, C.muted, false); note.Name = "BagPageLabel"; note.Position = UDim2.fromOffset(390, 3); note.Size = UDim2.fromOffset(210, 22)
		local prev = button(content, "‹", C.navy2); prev.Name = "BagPrev"; prev.Position = UDim2.fromOffset(610, 0); prev.Size = UDim2.fromOffset(34, 28); setButtonEnabled(prev, bagPage > 1, C.navy2); prev.Activated:Connect(function() if bagPage > 1 then bagPage -= 1; render(true) end end)
		local nextB = button(content, "›", C.navy2); nextB.Name = "BagNext"; nextB.Position = UDim2.fromOffset(650, 0); nextB.Size = UDim2.fromOffset(34, 28); setButtonEnabled(nextB, bagPage < pages, C.navy2); nextB.Activated:Connect(function() if bagPage < pages then bagPage += 1; render(true) end end)
		local cleanup = panel(content); cleanup.Name = "BagCleanup"; cleanup.Position = UDim2.fromOffset(0, 36); cleanup.Size = UDim2.fromOffset(728, 40); cleanup.BackgroundColor3 = C.paper
		local cleanupText = label(cleanup, duplicateConfirm and "确认后仅出售符合条件的重复鱼，无法撤销。" or "仅卖普通～稀有的一级、普通变异、小型/标准鱼；每种至少保留 3 条。锁定、入缸和高级鱼不卖。", 10, C.muted, false); cleanupText.Position = UDim2.fromOffset(12, 3); cleanupText.Size = UDim2.fromOffset(492, 34)
		local cleanupPending = anyRequestPending()
		local cleanupButton = button(cleanup, if cleanupPending then "处理中…" elseif duplicateConfirm then "确认出售重复鱼" else "清理重复鱼", if cleanupPending then C.muted elseif duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending); cleanupButton.Name = "DuplicateSaleAction"; cleanupButton.Position = UDim2.fromOffset(522, 5); cleanupButton.Size = UDim2.fromOffset(194, 30); setButtonEnabled(cleanupButton, not cleanupPending, if duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending)
		cleanupButton.Activated:Connect(function() if cleanupPending then notify("操作处理中，请稍候") elseif duplicateConfirm then send("sellDuplicates", {}) else duplicateConfirm = true; render(true) end end)
		listY = 84
		listHeight = 344
	end
	local cardWidth = if layout.stackPages then width else 422
	local s = scroll(content); s.Name = "BagList"; s.Position = UDim2.fromOffset(0, listY); s.Size = UDim2.fromOffset(if layout.stackPages then width else 430, listHeight); s.ScrollBarThickness = if layout.stackPages then 0 else 5; listLayout(s, 7)
	for i = firstIndex, lastIndex do
		makeFishCard(s, filtered[i], cardWidth, function(f) selectBagFish(f.id) end)
	end
	if visibleCount == 0 then local empty = label(s, "当前筛选没有鱼。", 15, C.muted, false); empty.Name = "BagEmpty"; empty.Size = UDim2.fromOffset(math.max(1, width - 12), 55) end
	if layout.stackPages then
		if landscapeModal then
			local cleanupY = listY + listHeight + 12
			local cleanup = panel(content); cleanup.Name = "BagCleanup"; cleanup.Position = UDim2.fromOffset(0, cleanupY); cleanup.Size = UDim2.fromOffset(width, 92); cleanup.BackgroundColor3 = C.paper
			local cleanupText = label(cleanup, duplicateConfirm and "确认后仅出售符合条件的重复鱼，无法撤销。" or "仅卖普通～稀有的一级、普通变异、小型/标准鱼；每种至少保留 3 条。锁定、入缸和高级鱼不卖。", 10, C.muted, false); cleanupText.Position = UDim2.fromOffset(12, 4); cleanupText.Size = UDim2.fromOffset(math.max(1, width - 24), 32)
			local cleanupPending = anyRequestPending()
			local cleanupButton = button(cleanup, if cleanupPending then "处理中…" elseif duplicateConfirm then "确认出售重复鱼" else "清理重复鱼", if cleanupPending then C.muted elseif duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending); cleanupButton.Name = "DuplicateSaleAction"; cleanupButton.Position = UDim2.fromOffset(12, 42); cleanupButton.Size = UDim2.fromOffset(math.max(1, width - 24), 44); setButtonEnabled(cleanupButton, not cleanupPending, if duplicateConfirm then C.red else C.gold, duplicateConfirm and not cleanupPending)
			cleanupButton.Activated:Connect(function() if cleanupPending then notify("操作处理中，请稍候") elseif duplicateConfirm then send("sellDuplicates", {}) else duplicateConfirm = true; render(true) end end)
			detailY = cleanupY + 104
			detailHeight = detailMetrics.height
		else
			detailY = listY + listHeight + 12
			detailHeight = 450
		end
		local detail = panel(content); detail.Name = "BagDetail"; detail.Position = UDim2.fromOffset(0, detailY); detail.Size = UDim2.fromOffset(width, detailHeight)
		populateBagDetail(detail, findFish(selectedId), bagCount, placedCount, bagCapacity, tankCapacity)
		if bagDetailReveal then pendingScrollPosition = Vector2.new(0, detailY); bagDetailReveal = false end
		setPageCanvas(detailY + detailHeight)
	else
		detailY = 84
		detailHeight = 344
		local detail = panel(content); detail.Name = "BagDetail"; detail.Position = UDim2.fromOffset(448, detailY); detail.Size = UDim2.fromOffset(280, detailHeight)
		populateBagDetail(detail, findFish(selectedId), bagCount, placedCount, bagCapacity, tankCapacity)
		setPageCanvas(0)
	end
end

local function renderAquarium()
	mainTitle.Text = "水族馆"
	clear(content)
	local placed = {}; for _, f in snapshot.fish or {} do if f.placed then table.insert(placed, f) end end
	local width = pageWidth()
	local compact = layout.stackPages
	local heroHeight = if compact then 156 else 105
	local hero = panel(content); hero.Name = "AquariumHero"; hero.Size = UDim2.fromOffset(width, heroHeight); hero.BackgroundColor3 = C.navy
	local h = label(hero, "你的潮汐缸", 19, C.cream, true); h.Name = "AquariumTitle"; h.Position = UDim2.fromOffset(if compact then 16 else 20, if compact then 8 else 13); h.Size = UDim2.fromOffset(math.max(1, width - 32), 28)
	local visitPending = anyRequestPending()
	local visit = button(hero, visitPending and "处理中…" or "参观我的鱼缸", visitPending and C.muted or C.teal); visit.Name = "VisitAquarium"; visit.Position = UDim2.fromOffset(if compact then 16 else 560, if compact then 42 else 13); visit.Size = UDim2.fromOffset(if compact then width - 32 else 148, if compact then 44 else 30); setButtonEnabled(visit, not visitPending, C.teal); visit.Activated:Connect(function() if not visitPending then send("visitAquarium", {}) else notify("操作处理中，请稍候") end end)
	local d = label(hero, string.format("%d / %d 条入缸 · 每小时 %.2f 金币", #placed, snapshot.tankCapacity or 0, snapshot.incomePerHour or 0), 14, C.sea, true); d.Name = "AquariumStats"; d.Position = UDim2.fromOffset(if compact then 16 else 20, if compact then 93 else 45); d.Size = UDim2.fromOffset(math.max(1, width - 32), 25)
	local incomeHint = label(hero, "鱼只在入缸后产出金币", 12, C.cream, false); incomeHint.Position = UDim2.fromOffset(if compact then 16 else 20, if compact then 121 else 73); incomeHint.Size = UDim2.fromOffset(math.max(1, width - 32), 22)
	local listY = if compact then heroHeight + 12 else 120
	local listHeight = if compact then math.max(60, #placed * 87 - 7) else 308
	local s = scroll(content); s.Name = "AquariumList"; s.Position = UDim2.fromOffset(0, listY); s.Size = UDim2.fromOffset(width, listHeight); s.ScrollBarThickness = if compact then 0 else 5; listLayout(s, 7)
	if #placed == 0 then local empty = label(s, "水族馆还是空的。到背包选择鱼，放入这里开始产出。", 15, C.muted, false); empty.Name = "AquariumEmpty"; empty.Size = UDim2.fromOffset(math.max(1, width - 20), 55) else for _, f in placed do makeFishCard(s, f, width, function(one) selectBagFish(one.id) end) end end
	setPageCanvas(listY + listHeight)
end

local function toggleMergeSelection(one: any)
	if anyRequestPending() then notify("操作处理中，请稍候"); return end
	if snapshot and snapshot.showcaseFishId == one.id then notify("展示中的鱼不能消耗，请先收起展示"); return end
	if one.locked and not table.find(mergeIds, one.id) then notify("已锁定材料不能加入合成"); return end
	local at = table.find(mergeIds, one.id)
	if at then table.remove(mergeIds, at) elseif #mergeIds < 3 then table.insert(mergeIds, one.id) else notify("最多选择三条鱼") end
	clearMergeConfirmation()
	-- Keep the material list in place while the player picks the first two
	-- fish; reveal the preview only once the three-material set is complete.
	if layout.stackPages and #mergeIds >= 3 then mergePreviewReveal = true end
	render(true)
end

local function renderMerge()
	mainTitle.Text = "三合一 · 同物种、同等级"
	clear(content)
	local width = pageWidth()
	local compact = layout.stackPages
	local instr = label(content, "选择三条未锁定的同物种同等级鱼。已入缸材料也可合成，但成功后会从水族馆移除。", 13, C.muted, false); instr.Name = "MergeInstruction"; instr.Position = UDim2.fromOffset(0, 0); instr.Size = UDim2.fromOffset(width, if compact then 42 else 26)
	if not anyRequestPending() then
		local existing = {}
		for _, fish in snapshot.fish or {} do existing[fish.id] = true end
		local pruned = {}
		for _, id in mergeIds do if existing[id] and id ~= snapshot.showcaseFishId then table.insert(pruned, id) end end
		mergeIds = pruned
		if #mergeIds < 3 then clearMergeConfirmation() end
	end
	if mergeConfirm and mergeConfirmationKey ~= mergeConfirmationSignature(snapshot) then clearMergeConfirmation() end
	local candidates = {}; for _, f in snapshot.fish or {} do if f.id ~= snapshot.showcaseFishId and (not f.locked or table.find(mergeIds, f.id)) then table.insert(candidates, f) end end
	local pages = math.max(1, math.ceil(#candidates / 24)); mergePage = math.clamp(mergePage, 1, pages)
	local pageY = if compact then 48 else 31
	local pageText = label(content, string.format("材料第 %d / %d 页", mergePage, pages), 12, C.muted, false); pageText.Name = "MergePageLabel"; pageText.Position = UDim2.fromOffset(0, pageY); pageText.Size = UDim2.fromOffset(if compact then width - 104 else 180, if compact then 44 else 22)
	local back = button(content, "‹", C.navy2); back.Name = "MergePrev"; back.Position = UDim2.fromOffset(if compact then width - 96 else 300, if compact then pageY else 29); back.Size = UDim2.fromOffset(if compact then 44 else 34, if compact then 44 else 28); setButtonEnabled(back, mergePage > 1, C.navy2); back.Activated:Connect(function() if mergePage > 1 then mergePage -= 1; render(true) end end)
	local forward = button(content, "›", C.navy2); forward.Name = "MergeNext"; forward.Position = UDim2.fromOffset(if compact then width - 48 else 340, if compact then pageY else 29); forward.Size = UDim2.fromOffset(if compact then 44 else 34, if compact then 44 else 28); setButtonEnabled(forward, mergePage < pages, C.navy2); forward.Activated:Connect(function() if mergePage < pages then mergePage += 1; render(true) end end)
	local listY = if compact then 100 else 64
	local visibleCount = math.max(0, math.min(#candidates, mergePage * 24) - ((mergePage - 1) * 24))
	local listHeight = if compact then math.max(80, visibleCount * 87 - 7) else 364
	local listWidth = if compact then width else 430
	local cardWidth = if compact then width else 422
	local s = scroll(content); s.Name = "MergeList"; s.Position = UDim2.fromOffset(0, listY); s.Size = UDim2.fromOffset(listWidth, listHeight); s.ScrollBarThickness = if compact then 0 else 5; listLayout(s, 7)
	for i = (mergePage - 1) * 24 + 1, math.min(#candidates, mergePage * 24) do
		local f = candidates[i]
		local card = makeFishCard(s, f, cardWidth, toggleMergeSelection)
		if table.find(mergeIds, f.id) then setButtonEnabled(card, true, C.sea, true) end
		if anyRequestPending() then setButtonEnabled(card, false, C.paper) end
	end
	local previewY = if compact then listY + listHeight + 12 else 64
	local previewWidth = if compact then width else 280
	local previewHeight = if compact then 370 else 364
	local preview = panel(content); preview.Name = "MergePreview"; preview.Position = UDim2.fromOffset(if compact then 0 else 448, previewY); preview.Size = UDim2.fromOffset(previewWidth, previewHeight)
	local selected = {}; for _, id in mergeIds do local f = findFish(id); if f then table.insert(selected, f) end end
	local mergeState = UiRepair.mergeState(selected, {bagCount = UiRepair.countUnplaced(snapshot.fish or {}), bagCapacity = snapshot.bagCapacity or 0, showcaseFishId = snapshot.showcaseFishId})
	local mergePreviewState = if requestGate and requestGate.incomePreview then requestGate.incomePreview:state() else nil
	if #selected == 3 and mergeState.enabled and requestGate and requestGate.incomePreview and snapshot then
		local acknowledgedPlacedIds: {string}? = nil
		if mergeConfirm then
			acknowledgedPlacedIds = {}
			for _, fish in selected do if fish.placed then table.insert(acknowledgedPlacedIds, fish.id) end end
		end
		requestGate.incomePreview:requestMerge(snapshot, copyIds(mergeIds), acknowledgedPlacedIds)
		mergePreviewState = requestGate.incomePreview:state()
	elseif requestGate and requestGate.incomePreview and mergePreviewState and mergePreviewState.status ~= "idle" then
		requestGate.incomePreview:clear("请选择三条材料", false)
		mergePreviewState = requestGate.incomePreview:state()
	end
	local text = #selected == 0 and "从左侧选择材料" or string.format("已选择 %d / 3 条", #selected)
	local pre = label(preview, text, 17, C.ink, true); pre.Name = "MergeSelectionSummary"; pre.TextXAlignment = Enum.TextXAlignment.Center; pre.Position = UDim2.fromOffset(12, 14); pre.Size = UDim2.fromOffset(math.max(1, previewWidth - 24), 26)
	for i, f in selected do local row = label(preview, speciesName(f) .. "  Lv." .. f.level, 13, C.ink, true); row.Name = "MergeMaterial_" .. tostring(i); row.Position = UDim2.fromOffset(25, 55 + (i - 1) * 27); row.Size = UDim2.fromOffset(math.max(1, previewWidth - 50), 23) end
	local warning = label(preview, mergeState.hasPlaced and "⚠ 含已入缸材料\n合成成功后这些鱼会从水族馆移除。" or "", 11, C.red, true); warning.Name = "MergeWarning"; warning.Position = UDim2.fromOffset(20, 142); warning.Size = UDim2.fromOffset(math.max(1, previewWidth - 40), 44)
	local mergePreview = mergePreviewState and mergePreviewState.response and mergePreviewState.response.preview
	local detailText = mergeState.enabled and "收益预览：请求中…" or mergeState.reason
	if mergeState.enabled and mergePreviewState and mergePreviewState.status == "error" then
		detailText = "收益预览：" .. tostring(mergePreviewState.reason or "待刷新") .. " · 请重新选择材料"
	elseif mergeState.enabled and type(mergePreview) == "table" and mergePreview.ok == true then
		local mergeResultBase = mergePreview.resultBasePerHour
		local mergeCurrent = mergePreview.currentTotalPerHour
		local mergeProjected = mergePreview.projectedTotalPerHour
		local mergeDelta = mergePreview.deltaPerHour
		local numericPreview = type(mergeResultBase) == "number" and mergeResultBase == mergeResultBase and mergeResultBase ~= math.huge and mergeResultBase ~= -math.huge
			and type(mergeCurrent) == "number" and mergeCurrent == mergeCurrent and mergeCurrent ~= math.huge and mergeCurrent ~= -math.huge
			and type(mergeProjected) == "number" and mergeProjected == mergeProjected and mergeProjected ~= math.huge and mergeProjected ~= -math.huge
			and type(mergeDelta) == "number" and mergeDelta == mergeDelta and mergeDelta ~= math.huge and mergeDelta ~= -math.huge
		if numericPreview then
			detailText = string.format("预览：%s Lv.%d\n结果基础时产 %s/时\n合成前鱼缸 %s/时\n合成后鱼缸 %s/时 (%+.2f)", speciesName(selected[1]), selected[1].level + 1, moneyPrecise(mergeResultBase), moneyPrecise(mergeCurrent), moneyPrecise(mergeProjected), mergeDelta)
			if mergePreview.allowed ~= true then detailText ..= "\n不可执行 · " .. tostring(mergePreview.reason or "当前不可执行") end
		else
			detailText = "收益预览：数据待更新"
		end
	elseif mergeState.enabled and type(mergePreview) == "table" then
		detailText = "收益预览不可执行 · " .. tostring(mergePreview.reason or "材料状态已变化") .. " · 请重新选择材料"
	end
	local detail = label(preview, detailText, 13, mergeState.enabled and C.muted or C.red, false); detail.Name = "MergeDetail"; detail.Position = UDim2.fromOffset(24, 195); detail.Size = UDim2.fromOffset(math.max(1, previewWidth - 48), 78)
	local mergePending = anyRequestPending()
	local mergeEnabled = mergeState.enabled and not mergePending
	local mergeNeedsConfirmation = mergeState.enabled and mergeState.hasPlaced and not mergeConfirm
	local mergeText = if mergePending then "处理中…" elseif not mergeState.enabled then "确认合成" elseif mergeNeedsConfirmation then "核对移出并合成" elseif mergeConfirm then "确认移出并合成" else "确认合成"
	local merge = button(preview, mergeText, mergeEnabled and (mergeConfirm and C.gold or C.teal) or C.muted); merge.Name = "MergeAction"; merge.Position = UDim2.fromOffset(if compact then 12 else 18, if compact then 314 else 314); merge.Size = UDim2.fromOffset(if compact then math.max(1, previewWidth - 24) else 244, if compact then 44 else 34); setButtonEnabled(merge, mergeEnabled, mergeConfirm and C.gold or C.teal); merge.Activated:Connect(function()
		if mergePending then notify("合成处理中，请稍候") elseif not mergeState.enabled then notify(mergeState.reason) elseif mergeNeedsConfirmation then mergeConfirm = true; mergeConfirmationKey = mergeConfirmationSignature(snapshot); render(true) else
			local acknowledgedPlacedIds = {}
			for _, fish in selected do if fish.placed then table.insert(acknowledgedPlacedIds, fish.id) end end
			send("merge", {ids = copyIds(mergeIds), acknowledgedPlacedIds = acknowledgedPlacedIds})
		end
	end)
	if compact and mergePreviewReveal then pendingScrollPosition = Vector2.new(0, previewY); mergePreviewReveal = false end
	setPageCanvas(previewY + previewHeight)
end

local function renderIndex()
	local speciesCatalog = Config and Config.Species or {}
	local catalogCount = tonumber(snapshot.catalogCount) or #speciesCatalog
	mainTitle.Text = "鱼类图鉴  ·  " .. tostring(snapshot.discoveryCount or 0) .. " / " .. tostring(catalogCount)
	clear(content)
	if not selectedContractSpecies then for id in snapshot.discovered or {} do selectedContractSpecies = id; break end end
	local compact = layout.stackPages
	local width = pageWidth()
	local currentDay = tonumber(snapshot.currentDay)
	local ready = currentDay ~= nil and (snapshot.discoveryCount or 0) >= 21 and (snapshot.dailyCaught or 0) >= 100 and snapshot.contractDay ~= currentDay
	local contractName = selectedContractSpecies and speciesName({species = selectedContractSpecies}) or "先选择已发现鱼种"
	local contractDefinition = Config and Config.Contract
	local contractRewardCount = contractDefinition and contractDefinition.rewardFishCount or 0
	local selectedHistoryLevel = selectedContractSpecies and snapshot.discovered and snapshot.discovered[selectedContractSpecies] or nil
	local contractRewardLevel = if Config and Config.contractRewardLevel then Config.contractRewardLevel(selectedHistoryLevel) else 0
	local contractPreview = selectedContractSpecies and string.format("本次奖励：%s ×%d · Lv.%d 标准鱼", contractName, contractRewardCount, contractRewardLevel) or "点按已发现鱼种以预览本次委托奖励"
	local contractWaiting = anyRequestPending()
	local contractClaimedToday = currentDay ~= nil and snapshot.contractDay == currentDay
	local contractHasSelection = selectedContractSpecies ~= nil and selectedHistoryLevel ~= nil
	local contractDiscoveryReady = (snapshot.discoveryCount or 0) >= 21
	local contractCatchReady = (snapshot.dailyCaught or 0) >= 100
	local contractState = UiRepair.actionState("contract", nil, {ready = ready and contractHasSelection, rewardFishCount = contractRewardCount, bagCount = UiRepair.countUnplaced(snapshot.fish or {}), bagCapacity = snapshot.bagCapacity or 0})
	local contractEnabled = contractState.enabled and not contractWaiting
	local contractStatus = if contractClaimedToday then "今日委托已领取" elseif not contractHasSelection then "请选择已发现鱼种" elseif not contractDiscoveryReady then string.format("发现不足：%d/21", snapshot.discoveryCount or 0) elseif not contractCatchReady then string.format("今日捕获不足：%d/100", snapshot.dailyCaught or 0) elseif contractState.reason == "背包空间不足" then "背包空间不足" elseif contractState.enabled then "可以领取" else contractState.reason
	local contractText = if contractWaiting then "处理中…" elseif contractClaimedToday then "今日已领取" elseif contractState.enabled then string.format("定向培育 · %s ×%d · Lv.%d", contractName, contractRewardCount, contractRewardLevel) else contractStatus
	local contract = button(content, contractText, contractEnabled and C.teal or C.muted); contract.Name = "ContractAction"; contract.Position = UDim2.fromOffset(0, 0); contract.Size = UDim2.fromOffset(if compact then width else 420, if compact then 44 else 34); setButtonEnabled(contract, contractEnabled, C.teal)
	contract.Activated:Connect(function() if contractEnabled then send("contract", {species = selectedContractSpecies}) else notify(if contractWaiting then "操作处理中，请稍候" else contractStatus) end end)
	local hintY = if compact then 50 else 40
	local hintText = contractStatus .. " · " .. contractPreview .. "，每日一次。\n收集 " .. tostring(catalogCount) .. " 种鱼，点亮图鉴；未发现的鱼种会保持隐藏。"
	local measuredHint = TextService:GetTextSize(hintText, 11, Enum.Font.Gotham, Vector2.new(math.max(1, width), 10000))
	local hintHeight = math.max(if compact then 58 else 42, math.ceil(measuredHint.Y) + 4)
	local hint = label(content, hintText, 11, C.muted, false); hint.Name = "IndexHint"; hint.Position = UDim2.fromOffset(0, hintY); hint.Size = UDim2.fromOffset(width, hintHeight)
	local gridY = hintY + hintHeight + 4
	local columns = if compact then (if width >= 360 then 2 else 1) else 4
	local cellGap = if compact then 8 else 12
	local cellWidth = if compact then math.max(1, (width - (columns - 1) * cellGap) / columns) else 168
	local gridHeight = if compact then math.max(82, math.ceil(math.max(1, #speciesCatalog) / columns) * (82 + 8)) else 384
	local s = scroll(content); s.Name = "IndexGrid"; s.Position = UDim2.fromOffset(0, gridY); s.Size = UDim2.fromOffset(width, gridHeight); s.ScrollBarThickness = if compact then 0 else 5
	local grid = Instance.new("UIGridLayout"); grid.CellSize = UDim2.fromOffset(cellWidth, 82); grid.CellPadding = UDim2.fromOffset(cellGap, if compact then 8 else 10); grid.Parent = s
	for _, species in ipairs(speciesCatalog) do
		local discovered = snapshot.discovered and snapshot.discovered[species.id]
		local b = button(s, "", if discovered then C.paper else C.navy, false, true); b.Name = "Index_" .. species.id; b.Text = ""; b.Size = UDim2.fromOffset(cellWidth, 82); stroke(b, if discovered then C.sea else C.navy2, .3)
		local bubble = Instance.new("Frame"); bubble.Name = "FishPreview"; bubble.BackgroundColor3 = if discovered then Color3.fromRGB(species.color.r or species.color[1], species.color.g or species.color[2], species.color.b or species.color[3]) else C.navy2; bubble.Position = UDim2.fromOffset(9, 13); bubble.Size = UDim2.fromOffset(54, 54); bubble.Parent = b; corner(bubble, 20)
		local previewFish = {id = "index_" .. species.id, species = species.id, level = 1, size = 2, mutation = 1}
		local _, indexArt = mountFishPreview(bubble, species, previewFish, not discovered)
		if indexArt then
			b:SetAttribute("FishVisualSource", indexArt:GetAttribute("FishVisualSource") or "ProceduralFallback")
			if not discovered then
				-- Keep undiscovered silhouettes mysterious while still rendering a
				-- real fish shape; discovered entries show the textured/imported
				-- visual when that species has an imported template.
				for _, object in indexArt:GetDescendants() do
					if object:IsA("BasePart") then
						object.Color = C.navy2
						object.Material = Enum.Material.SmoothPlastic
					end
				end
			end
		end
		local n = label(b, if discovered then species.name else "未发现", 13, if discovered then C.ink else C.cream, true); n.Position = UDim2.fromOffset(70, 13); n.Size = UDim2.fromOffset(math.max(1, cellWidth - 80), 24)
		local lv = label(b, discovered and "最高 Lv." .. discovered or "前往水域探索", 11, if discovered then C.teal else C.sea, false); lv.Position = UDim2.fromOffset(70, 40); lv.Size = UDim2.fromOffset(math.max(1, cellWidth - 80), 24)
		if discovered then b.Activated:Connect(function() selectedContractSpecies = species.id; render(true) end) end
	end
	setPageCanvas(if compact then gridY + gridHeight else 0)
end

local function renderUpgrades()
	mainTitle.Text = "升级与水域"
	clear(content)
	local width = pageWidth()
	local compact = layout.stackPages
	local names = {hooks = "鱼钩", luck = "幸运", coins = "金币加成", tank = "鱼缸容量", bag = "背包容量"}
	local function unlockConditionHeight(text: string, maxWidth: number): number
		local bounds = TextService:GetTextSize(text, 12, Enum.Font.Gotham, Vector2.new(math.max(1, maxWidth), 10000))
		return math.max(18, math.ceil(bounds.Y + 4))
	end
	if compact then
		local s = scroll(content); s.Name = "UpgradeScroll"; s.Position = UDim2.fromOffset(0, 0); s.Size = UDim2.fromOffset(width, 1); s.ScrollBarThickness = 0
		local y = 0
		local upgradeOrder = {"hooks", "luck", "coins", "tank", "bag"}
		for _, key in upgradeOrder do
			local title = names[key]
			local u = snapshot.upgrades and snapshot.upgrades[key] or {}
			local state = UiRepair.actionState("upgrade", nil, {coins = snapshot.coins or 0, upgrade = u})
			local cap = (u.level or 0) >= (u.max or math.huge)
			local waiting = anyRequestPending()
			local row = panel(s); row.Name = "Upgrade_" .. key; row.Position = UDim2.fromOffset(0, y); row.Size = UDim2.fromOffset(width, 104)
			local a = label(row, title .. "  Lv." .. tostring(u.level or 0) .. "/" .. tostring(u.max or "--"), 15, C.ink, true); a.Position = UDim2.fromOffset(12, 8); a.Size = UDim2.fromOffset(math.max(1, width - 24), 22)
			local upgradeDetail = if cap then "已达上限" else "下一次费用：" .. money(u.cost) .. " 金币" .. (if state.enabled then "" else " · " .. state.reason)
			local d = label(row, upgradeDetail, 12, C.muted, false); d.Position = UDim2.fromOffset(12, 32); d.Size = UDim2.fromOffset(math.max(1, width - 24), 18)
			local upgradeEnabled = state.enabled and not waiting
			local b = button(row, if waiting then "处理中…" elseif cap then "已满级" elseif state.enabled then "升级" else state.reason, if upgradeEnabled then C.teal else C.muted); b.Name = "UpgradeAction_" .. key; b.Position = UDim2.fromOffset(12, 56); b.Size = UDim2.fromOffset(math.max(1, width - 24), 44); setButtonEnabled(b, upgradeEnabled, C.teal); b.Activated:Connect(function() if upgradeEnabled then send("upgrade", {kind = key, expectedLevel = u.level, expectedCost = u.cost}) else notify(if waiting then "操作处理中，请稍候" else state.reason) end end)
			y += 114
		end
		local divider = label(s, tostring(#(Config and Config.Zones or {})) .. "片海域", 17, C.navy, true); divider.Name = "ZoneHeading"; divider.Position = UDim2.fromOffset(0, y); divider.Size = UDim2.fromOffset(width, 36); y += 42
		for _, z in (Config and Config.Zones or {}) do
			local unlocked = (snapshot.zone or 1) >= z.id
			local nextZone = z.id == (snapshot.zone or 1) + 1
			local unlockContext = {unlocked = unlocked, next = nextZone, level = snapshot.playerLevel, requiredLevel = z.requiredLevel, coins = snapshot.coins or 0, cost = z.cost or math.huge, discoveryCount = snapshot.discoveryCount or 0, requiredDiscoveries = z.requiredDiscoveries or math.huge}
			local zoneState = if unlocked then UiRepair.actionState("travel", nil, {unlocked = true}) else UiRepair.actionState("unlock", nil, unlockContext)
			local waiting = anyRequestPending()
			local reqText = if unlocked then "已解锁" else UiRepair.unlockRequirements(unlockContext)
			local conditionHeight = unlockConditionHeight(reqText, width - 24)
			local buttonY = 32 + conditionHeight + 6
			local rowHeight = math.max(106, buttonY + 44 + 6)
			local row = panel(s); row.Name = "Zone_" .. tostring(z.id); row.Position = UDim2.fromOffset(0, y); row.Size = UDim2.fromOffset(width, rowHeight)
			local n = label(row, z.name, 15, C.ink, true); n.Position = UDim2.fromOffset(12, 8); n.Size = UDim2.fromOffset(math.max(1, width - 24), 22)
			local req = label(row, reqText, 12, unlocked and C.green or C.muted, false); req.Position = UDim2.fromOffset(12, 32); req.Size = UDim2.fromOffset(math.max(1, width - 24), conditionHeight); req.TextYAlignment = Enum.TextYAlignment.Top
			local zoneEnabled = zoneState.enabled and not waiting
			local zoneText = UiRepair.unlockButtonText(unlockContext, zoneState, waiting)
			local b = button(row, zoneText, if zoneEnabled then C.teal else C.muted); b.Name = "ZoneAction_" .. tostring(z.id); b.Position = UDim2.fromOffset(12, buttonY); b.Size = UDim2.fromOffset(math.max(1, width - 24), 44); setButtonEnabled(b, zoneEnabled, C.teal)
			b.Activated:Connect(function() if zoneEnabled then send(if unlocked then "travel" else "unlock", {zone = z.id}) else notify(if waiting then "操作处理中，请稍候" else zoneState.reason) end end)
			y += rowHeight + 10
		end
		-- The list ends at the zone rows.  Keep the odds action as a sibling so
		-- its hitbox is never clipped by or mistaken for list content.
		s.Size = UDim2.fromOffset(width, math.max(1, y))
		local odds = button(content, "查看当前掉落概率", C.navy); odds.Name = "OddsFooter"; odds.Position = UDim2.fromOffset(0, y + 8); odds.Size = UDim2.fromOffset(width, 44); odds.Activated:Connect(function() setActiveTab("概率") end)
		y += 60
		setPageCanvas(y)
	else
		local s = scroll(content); s.Name = "UpgradeScroll"; s.Position = UDim2.fromOffset(0, 0); s.Size = UDim2.fromOffset(728, 382); listLayout(s, 10)
		for key, title in names do
			local u = snapshot.upgrades and snapshot.upgrades[key] or {}; local state = UiRepair.actionState("upgrade", nil, {coins = snapshot.coins or 0, upgrade = u}); local cap = (u.level or 0) >= (u.max or math.huge); local waiting = anyRequestPending()
			local row = panel(s); row.Name = "Upgrade_" .. key; row.Size = UDim2.fromOffset(720, 57); local a = label(row, title .. "  Lv." .. tostring(u.level or 0) .. "/" .. tostring(u.max or "--"), 15, C.ink, true); a.Position = UDim2.fromOffset(15, 8); a.Size = UDim2.fromOffset(280, 22)
			local upgradeDetail = if cap then "已达上限" else "下一次费用：" .. money(u.cost) .. " 金币" .. (if state.enabled then "" else " · " .. state.reason)
			local d = label(row, upgradeDetail, 12, C.muted, false); d.Position = UDim2.fromOffset(15, 31); d.Size = UDim2.fromOffset(430, 18)
			local upgradeEnabled = state.enabled and not waiting
			local b = button(row, if waiting then "处理中…" elseif cap then "已满级" elseif state.enabled then "升级" else state.reason, if upgradeEnabled then C.teal else C.muted); b.Name = "UpgradeAction_" .. key; b.Position = UDim2.fromOffset(620, 13); b.Size = UDim2.fromOffset(84, 32); setButtonEnabled(b, upgradeEnabled, C.teal); b.Activated:Connect(function() if upgradeEnabled then send("upgrade", {kind = key, expectedLevel = u.level, expectedCost = u.cost}) else notify(if waiting then "操作处理中，请稍候" else state.reason) end end)
		end
		local divider = label(s, tostring(#(Config and Config.Zones or {})) .. "片海域", 17, C.navy, true); divider.Name = "ZoneHeading"; divider.Size = UDim2.fromOffset(720, 36)
		for _, z in (Config and Config.Zones or {}) do
			local unlocked = (snapshot.zone or 1) >= z.id; local nextZone = z.id == (snapshot.zone or 1) + 1; local unlockContext = {unlocked = unlocked, next = nextZone, level = snapshot.playerLevel, requiredLevel = z.requiredLevel, coins = snapshot.coins or 0, cost = z.cost or math.huge, discoveryCount = snapshot.discoveryCount or 0, requiredDiscoveries = z.requiredDiscoveries or math.huge}; local zoneState = if unlocked then UiRepair.actionState("travel", nil, {unlocked = true}) else UiRepair.actionState("unlock", nil, unlockContext); local waiting = anyRequestPending()
			local reqText = if unlocked then "已解锁" else UiRepair.unlockRequirements(unlockContext)
			local conditionWidth = 590
			local conditionHeight = unlockConditionHeight(reqText, conditionWidth)
			local rowHeight = math.max(58, 31 + conditionHeight + 9)
			local row = panel(s); row.Name = "Zone_" .. tostring(z.id); row.Size = UDim2.fromOffset(720, rowHeight); local n = label(row, z.name, 15, C.ink, true); n.Position = UDim2.fromOffset(15, 8); n.Size = UDim2.fromOffset(200, 22)
			local req = label(row, reqText, 12, unlocked and C.green or C.muted, false); req.Position = UDim2.fromOffset(15, 31); req.Size = UDim2.fromOffset(conditionWidth, conditionHeight); req.TextYAlignment = Enum.TextYAlignment.Top
			local zoneEnabled = zoneState.enabled and not waiting
			local zoneText = UiRepair.unlockButtonText(unlockContext, zoneState, waiting)
			local b = button(row, zoneText, if zoneEnabled then C.teal else C.muted); b.Name = "ZoneAction_" .. tostring(z.id); b.Position = UDim2.fromOffset(620, math.max(13, math.floor((rowHeight - 32) / 2))); b.Size = UDim2.fromOffset(84, 32); setButtonEnabled(b, zoneEnabled, C.teal)
			b.Activated:Connect(function() if zoneEnabled then send(if unlocked then "travel" else "unlock", {zone = z.id}) else notify(if waiting then "操作处理中，请稍候" else zoneState.reason) end end)
		end
		local odds = button(content, "查看当前掉落概率", C.navy); odds.Name = "OddsFooter"; odds.Position = UDim2.fromOffset(0, 390); odds.Size = UDim2.fromOffset(218, 34); odds.Activated:Connect(function() setActiveTab("概率") end)
		setPageCanvas(0)
	end
end

local function formatDuration(seconds: number): string
	local value = math.max(0, math.floor(seconds or 0))
	local minutes = math.floor(value / 60)
	local remainder = value % 60
	return if minutes > 0 then string.format("%d分%02d秒", minutes, remainder) else tostring(remainder) .. "秒"
end

local function displayBoostEntries(recipes: {any}): {any}
	local entries = {}
	for itemId, info in pairs(boostItems()) do
		if type(info) == "table" then
			local copy = {}
			for key, value in info do copy[key] = value end
			copy.itemId = tostring(copy.itemId or itemId)
			table.insert(entries, copy)
		end
	end
	if #entries == 0 then
		local fallbacks = {
			{itemId = "luck_tonic", id = "luck_tonic", name = "幸运药剂", kind = "luck", amount = 10, durationSeconds = 600},
			{itemId = "coin_tonic", id = "coin_tonic", name = "金币药剂", kind = "coins", multiplier = 1.5, durationSeconds = 600},
			{itemId = "xp_tonic", id = "xp_tonic", name = "经验药剂", kind = "xp", multiplier = 1.5, durationSeconds = 600},
		}
		for _, fallback in ipairs(fallbacks) do table.insert(entries, fallback) end
	end
	table.sort(entries, function(a, b) return tostring(a.itemId) < tostring(b.itemId) end)
	return entries
end

local function boostDescription(info: any): string
	local effect = {}
	local kind = tostring(info.kind or "")
	local names = {luck = "幸运药剂", coins = "金币药剂", xp = "经验药剂"}
	local displayName = tostring(info.name or names[kind] or "增益物品")
	local amount = tonumber(info.amount) or 0
	local multiplier = tonumber(info.multiplier) or 0
	if kind == "luck" and amount ~= 0 then table.insert(effect, "幸运+" .. tostring(amount)) end
	if kind == "coins" and multiplier ~= 0 then table.insert(effect, "金币×" .. tostring(multiplier)) end
	if kind == "xp" and multiplier ~= 0 then table.insert(effect, "经验×" .. tostring(multiplier)) end
	local duration = tonumber(info.durationSeconds)
	if duration and duration > 0 then table.insert(effect, formatDuration(duration)) end
	return displayName .. (if #effect > 0 then " · " .. table.concat(effect, "、") else "")
end

local function itemDisplayName(itemId: any): string
	local id = tostring(itemId or "")
	local info = boostItems()[id]
	if type(info) == "table" then
		local names = {luck = "幸运药剂", coins = "金币药剂", xp = "经验药剂"}
		return tostring(info.name or names[tostring(info.kind or "")] or "增益物品")
	end
	local names = {luck_tonic = "幸运药剂", coin_tonic = "金币药剂", xp_tonic = "经验药剂"}
	return names[id] or "增益物品"
end

local function renderExchange()
	mainTitle.Text = "鱼类交换"
	clear(content)
	local compact = layout.stackPages
	local width = pageWidth()
	local back = button(content, "返回商店", C.navy2); back.Name = "ExchangeBack"; back.Position = UDim2.fromOffset(if compact then 0 else math.max(0, width - 128), 0); back.Size = UDim2.fromOffset(if compact then width else 128, if compact then 44 else 30); back.Activated:Connect(function() shopMode = "store"; clearExchangeConfirmation(); render(true) end)
	local y = if compact then 52 else 42
	local status = label(content, progressText(snapshot), 12, C.muted, true); status.Name = "ProgressStatus"; status.Position = UDim2.fromOffset(0, y); status.Size = UDim2.fromOffset(width, if compact then 28 else 24)
	y += if compact then 34 else 30
	local recipes = exchangeRecipes()
	if #recipes == 0 then
		recipes = {
			{id = "exchange_luck", itemId = "luck_tonic", name = "幸运药剂", fishCount = 3, count = 3, minRarity = 1, requiredLevel = 1},
			{id = "exchange_coins", itemId = "coin_tonic", name = "金币药剂", fishCount = 3, count = 3, minRarity = 2, requiredLevel = 1},
			{id = "exchange_xp", itemId = "xp_tonic", name = "经验药剂", fishCount = 3, count = 3, minRarity = 3, requiredLevel = 1},
		}
	end
	if not recipeById(exchangeRecipeId) then exchangeRecipeId = tostring(recipes[1].id) end
	local recipe = recipeById(exchangeRecipeId) or recipes[1]
	exchangeRecipeId = tostring(recipe.id)
	local fishList = snapshot and snapshot.fish or {}
	local rarityContext: {[string]: number} = {}
	for _, fish in ipairs(fishList) do rarityContext[tostring(fish.id)] = fishRarity(fish) end
	local selectionSync = UiRepair.reconcileExchangeSelection(exchangeSelectedIds, fishList, recipe, rarityContext, snapshot and snapshot.showcaseFishId)
	if selectionSync.changed then
		exchangeSelectedIds = selectionSync.ids
		clearExchangeConfirmation()
	elseif exchangeConfirm and exchangeSelectionKey ~= nil and exchangeSelectionKey ~= selectionSync.key then
		clearExchangeConfirmation()
	end
	exchangeSelectionKey = selectionSync.key
	local selected = UiRepair.selectionByIds(fishList, exchangeSelectedIds)
	local selectionState = UiRepair.exchangeSelectionState(selected, recipe, rarityContext, snapshot and snapshot.showcaseFishId)
	local items = snapshot and snapshot.items or {}
	local boostEntries = displayBoostEntries(recipes)
	local inventoryHeading = label(content, "增益物品 · " .. progressText(snapshot), 14, C.navy, true); inventoryHeading.Name = "ConsumablesHeading"; inventoryHeading.Position = UDim2.fromOffset(0, y); inventoryHeading.Size = UDim2.fromOffset(width, 24)
	y += 30
	for _, info in ipairs(boostEntries) do
		local itemId = tostring(info.itemId)
		local count = tonumber(items[itemId] or 0) or 0
		local active = boostStatus(snapshot, tostring(info.kind or ""))
		local activeText = if active then "生效中 · 剩余 " .. formatDuration(active.remainingSeconds or 0) else "未激活"
		local rowHeight = if compact then 104 else 58
		local row = panel(content); row.Name = "Consumable_" .. itemId; row.Position = UDim2.fromOffset(0, y); row.Size = UDim2.fromOffset(width, rowHeight)
		local desc = label(row, boostDescription(info), 13, C.ink, true); desc.Position = UDim2.fromOffset(12, 8); desc.Size = UDim2.fromOffset(if compact then width - 24 else math.max(1, width - 210), 22)
		local detail = label(row, "库存 ×" .. tostring(count) .. " · " .. activeText, 11, active and C.green or C.muted, false); detail.Position = UDim2.fromOffset(12, 32); detail.Size = UDim2.fromOffset(if compact then width - 24 else math.max(1, width - 210), 18)
		local itemPending = actionPending("useItem")
		local confirming = useItemConfirmId == itemId
		local canUse = count > 0 and not itemPending
		local useText = if itemPending then "处理中…" elseif confirming then "再次确认使用" else "使用"
		local useButton = button(row, useText, canUse and (confirming and C.gold or C.teal) or C.muted); useButton.Name = "UseItem_" .. itemId; useButton.Position = UDim2.fromOffset(if compact then 12 else width - 116, if compact then 54 else 12); useButton.Size = UDim2.fromOffset(if compact then width - 24 else 104, 44); setButtonEnabled(useButton, canUse, confirming and C.gold or C.teal)
		useButton.Activated:Connect(function()
			if not canUse then notify(if itemPending then "物品使用处理中，请稍候" else "没有可用的该物品") elseif not confirming then useItemConfirmId = itemId; useItemRequestId = newRequestId("useItem"); render(true) else send("useItem", {itemId = itemId, requestId = useItemRequestId}) end
		end)
		y += rowHeight + (if compact then 8 else 6)
	end
	local recipeHeading = label(content, "选择兑换配方", 14, C.navy, true); recipeHeading.Name = "ExchangeRecipesHeading"; recipeHeading.Position = UDim2.fromOffset(0, y); recipeHeading.Size = UDim2.fromOffset(width, 24)
	y += 30
	for index, each in ipairs(recipes) do
		local activeRecipe = tostring(each.id) == exchangeRecipeId
		local req = "消耗 " .. tostring(each.fishCount or 3) .. " 条 Lv." .. tostring(each.requiredLevel or 1) .. " · 最低品质 " .. tostring(each.minRarity or 1)
		local recipeButton = button(content, tostring(each.name or itemDisplayName(each.itemId)) .. " → 获得 " .. itemDisplayName(each.itemId) .. "  ·  " .. req, activeRecipe and C.teal or C.navy2, activeRecipe); recipeButton.Name = "ExchangeRecipe_" .. tostring(each.id); recipeButton.Position = UDim2.fromOffset(0, y); recipeButton.Size = UDim2.fromOffset(width, 44); recipeButton.TextSize = 11; recipeButton.Activated:Connect(function() exchangeRecipeId = tostring(each.id); exchangeSelectedIds = {}; clearExchangeConfirmation(); render(true) end)
		y += 50
	end
	local auto = button(content, "自动选择最便宜的三条符合条件鱼", C.navy2); auto.Name = "ExchangeAutoSelect"; auto.Position = UDim2.fromOffset(0, y); auto.Size = UDim2.fromOffset(width, 44); auto.Activated:Connect(function()
		local autoFish = {}
		for _, fish in ipairs(fishList) do if tostring(fish.id) ~= tostring(snapshot and snapshot.showcaseFishId) then table.insert(autoFish, fish) end end
		exchangeSelectedIds = UiRepair.selectCheapestExchangeFish(autoFish, recipe, function(fish) return fishRarity(fish) end)
		clearExchangeConfirmation()
		render(true)
	end)
	y += 54
	local previewHeight = if compact then 222 else 194
	local preview = panel(content); preview.Name = "ExchangePreview"; preview.Position = UDim2.fromOffset(0, y); preview.Size = UDim2.fromOffset(width, previewHeight); preview.BackgroundColor3 = C.paper
	local previewTitle = label(preview, if selectionState.enabled then "已选材料 · 请核对后确认" else selectionState.reason, 13, selectionState.enabled and C.navy or C.red, true); previewTitle.Position = UDim2.fromOffset(12, 8); previewTitle.Size = UDim2.fromOffset(width - 24, 22)
	local slotWidth = if compact then math.max(1, (width - 36) / 3) else 142
	for slot = 1, 3 do
		local fish = selected[slot]
		local x = if compact then 12 + (slot - 1) * (slotWidth + 6) else 18 + (slot - 1) * 150
		local slotFrame = panel(preview); slotFrame.Name = "ExchangePreviewSlot" .. tostring(slot); slotFrame.Position = UDim2.fromOffset(x, 36); slotFrame.Size = UDim2.fromOffset(slotWidth, if compact then 104 else 98); slotFrame.BackgroundColor3 = fish and C.cream or C.paper
		if fish then
			local icon = Instance.new("Frame"); icon.Name = "FishPreview"; icon.BackgroundColor3 = fishColor(fish); icon.Position = UDim2.fromOffset((slotWidth - 54) * .5, 4); icon.Size = UDim2.fromOffset(54, 54); icon.Parent = slotFrame; corner(icon, 20); mountFishPreview(icon, speciesForFish(fish), fish)
			local fishName = label(slotFrame, speciesName(fish), 10, C.ink, true); fishName.Position = UDim2.fromOffset(4, 61); fishName.Size = UDim2.fromOffset(slotWidth - 8, 16); fishName.TextXAlignment = Enum.TextXAlignment.Center
			local fishMeta = label(slotFrame, fishWeight(fish) .. " · " .. moneyPrecise(exactSaleQuote(fish, snapshot)), 9, C.muted, false); fishMeta.Position = UDim2.fromOffset(4, 78); fishMeta.Size = UDim2.fromOffset(slotWidth - 8, 16); fishMeta.TextXAlignment = Enum.TextXAlignment.Center
		else
			local empty = label(slotFrame, "空位", 11, C.muted, false); empty.Size = UDim2.fromScale(1, 1); empty.TextXAlignment = Enum.TextXAlignment.Center
		end
	end
	local confirmPending = actionPending("exchange")
	local confirmEnabled = selectionState.enabled and not confirmPending
	local confirmText = if confirmPending then "处理中…" elseif not selectionState.enabled then "先选满三条鱼" elseif exchangeConfirm then "确认消耗并兑换" else "核对后继续"
	local confirm = button(preview, confirmText, confirmEnabled and (exchangeConfirm and C.gold or C.teal) or C.muted, exchangeConfirm and confirmEnabled); confirm.Name = "ExchangeConfirm"; confirm.Position = UDim2.fromOffset(if compact then 12 else 18, if compact then 150 else 142); confirm.Size = UDim2.fromOffset(if compact then width - 24 else 244, 44); setButtonEnabled(confirm, confirmEnabled, exchangeConfirm and C.gold or C.teal, exchangeConfirm and confirmEnabled); confirm.Activated:Connect(function()
		if not confirmEnabled then notify(if confirmPending then "兑换处理中，请稍候" else selectionState.reason) elseif not exchangeConfirm then exchangeConfirm = true; exchangeSelectionKey = selectionSync.key; exchangeRequestId = exchangeRequestId or newRequestId("exchange"); render(true) else send("exchange", {recipeId = tostring(recipe.id), ids = copyIds(exchangeSelectedIds), requestId = exchangeRequestId}) end
	end)
	y += previewHeight + 12
	local eligibleNote = label(content, "仅显示未锁定、未入缸、指定等级且品质达标的鱼；当前展示鱼会保留，点选鱼可手动替换自动选择。", 11, C.muted, false); eligibleNote.Name = "ExchangeEligibilityNote"; eligibleNote.Position = UDim2.fromOffset(0, y); eligibleNote.Size = UDim2.fromOffset(width, 36)
	y += 42
	local eligible = {}
	for _, fish in ipairs(fishList) do
		if tostring(fish.id) ~= tostring(snapshot and snapshot.showcaseFishId) and UiRepair.exchangeFishState(fish, recipe, fishRarity(fish), snapshot and snapshot.showcaseFishId).enabled then table.insert(eligible, fish) end
	end
	local listHeight = if compact then math.max(180, math.min(330, #eligible * 64)) else math.max(160, math.min(240, #eligible * 58))
	local list = scroll(content); list.Name = "ExchangeFishList"; list.Position = UDim2.fromOffset(0, y); list.Size = UDim2.fromOffset(width, listHeight); list.ScrollBarThickness = if compact then 0 else 5; listLayout(list, 6)
	for _, fish in ipairs(eligible) do
		local chosen = table.find(exchangeSelectedIds, tostring(fish.id)) ~= nil
		local fishButton = button(list, (chosen and "✓ " or "＋ ") .. speciesName(fish) .. " · " .. fishWeight(fish) .. " · " .. traitText(fish) .. " · 售价 " .. moneyPrecise(exactSaleQuote(fish, snapshot)), chosen and C.teal or C.paper, chosen, true); fishButton.Name = "ExchangeFish_" .. tostring(fish.id); fishButton.Size = UDim2.fromOffset(width, if compact then 58 else 52); fishButton.TextColor3 = chosen and C.white or C.ink; fishButton.TextSize = 10; fishButton.Activated:Connect(function()
			local existing = table.find(exchangeSelectedIds, tostring(fish.id))
			if existing then table.remove(exchangeSelectedIds, existing); clearExchangeConfirmation() elseif #exchangeSelectedIds < (tonumber(recipe.fishCount) or 3) then table.insert(exchangeSelectedIds, tostring(fish.id)); clearExchangeConfirmation() else notify("已经选满三条鱼，请先移除一条") end
			render(true)
		end)
	end
	if #eligible == 0 then local empty = label(list, "没有符合条件的鱼。需要未锁定、未入缸、指定等级和品质达标的鱼。", 12, C.muted, false); empty.Size = UDim2.fromOffset(width, 60) end
	setPageCanvas(y + listHeight + 8)
end

local function renderShop()
	if shopMode == "exchange" then
		renderExchange()
		return
	end
	mainTitle.Text = "商店"
	clear(content)
	local compact = layout.stackPages
	local width = pageWidth()
	local enabled = snapshot.paidAvailable == true
	local introHeight = if compact then 42 else 30
	local intro = label(content, enabled and "付费功能已由服务器配置。所有购买由 Roblox 官方交易处理。" or "演示模式：商品尚未配置，无法购买。", 14, if enabled then C.green else C.red, true); intro.Name = "ShopIntro"; intro.Position = UDim2.fromOffset(0, 0); intro.Size = UDim2.fromOffset(width, introHeight)
	local progress = label(content, progressText(snapshot), 11, C.muted, false); progress.Name = "ShopProgress"; progress.Position = UDim2.fromOffset(0, introHeight + 4); progress.Size = UDim2.fromOffset(width, 22)
	local exchangeButton = button(content, "鱼类交换 · 兑换增益物品", C.teal); exchangeButton.Name = "ExchangeHub"; exchangeButton.Position = UDim2.fromOffset(0, introHeight + 30); exchangeButton.Size = UDim2.fromOffset(width, if compact then 44 else 34); exchangeButton.Activated:Connect(function() shopMode = "exchange"; exchangeRecipeId = nil; exchangeSelectedIds = {}; clearExchangeConfirmation(); render(true) end)
	local products = {{"水族馆产出 ×2", "永久提升入缸收益，不影响捕鱼数量。"}, {"30 分钟产出 ×2", "临时提升入缸收益，可与永久权益叠加。"}}
	local y = if compact then introHeight + 84 else introHeight + 72
	for i, p in products do
		local rowHeight = if compact then 132 else 82
		local row = panel(content); row.Name = "ShopProduct_" .. tostring(i); row.Position = UDim2.fromOffset(0, y); row.Size = UDim2.fromOffset(width, rowHeight)
		local n = label(row, p[1], 17, C.ink, true); n.Position = UDim2.fromOffset(if compact then 14 else 18, 11); n.Size = UDim2.fromOffset(if compact then width - 28 else 360, 24)
		local d = label(row, p[2], 12, C.muted, false); d.Position = UDim2.fromOffset(if compact then 14 else 18, 40); d.Size = UDim2.fromOffset(if compact then width - 28 else 430, if compact then 28 else 26)
		local waiting = anyRequestPending(); local purchaseEnabled = enabled and not waiting
		local b = button(row, waiting and "处理中…" or (enabled and "购买" or "暂不可用"), purchaseEnabled and C.teal or C.muted); b.Name = "PurchaseAction_" .. tostring(i); b.Position = UDim2.fromOffset(if compact then 14 else 604, if compact then 80 else 25); b.Size = UDim2.fromOffset(if compact then width - 28 else 105, if compact then 44 else 32); setButtonEnabled(b, purchaseEnabled, C.teal); b.Activated:Connect(function() if purchaseEnabled then send(if i == 1 then "purchasePass" else "purchaseBoost", {}) else notify(if waiting then "操作处理中，请稍候" else "商品 ID 或支付资格尚未配置") end end)
		y += if compact then rowHeight + 10 else 94
	end
	local credits = button(content, "素材鸣谢", C.navy2); credits.Name = "CreditsFooter"; credits.Position = UDim2.fromOffset(0, y + (if compact then 2 else 8)); credits.Size = UDim2.fromOffset(width, math.max(if compact then 44 else 30, layout.minTouchTarget)); credits.Activated:Connect(function() setActiveTab("鸣谢") end)
	setPageCanvas(if compact then y + (if compact then math.max(58, layout.minTouchTarget + 14) else 42) else 0)
end

local function renderCredits()
	mainTitle.Text = ArtCredits.title or "素材鸣谢"
	clear(content)
	local compact = layout.stackPages
	local width = pageWidth()
	local back = button(content, "返回商店", C.navy2); back.Name = "CreditsBack"; back.Position = UDim2.fromOffset(if compact then 0 else math.max(0, width - 128), 0); back.Size = UDim2.fromOffset(if compact then width else 128, math.max(if compact then 44 else 30, layout.minTouchTarget)); back.Activated:Connect(function() setActiveTab("商店") end)
	local intro = label(content, ArtCredits.intro or "感谢这些创作者为潮汐水族馆提供美术与音效素材。", 13, C.muted, false); intro.Name = "CreditsIntro"; intro.Position = UDim2.fromOffset(0, if compact then 52 else 0); intro.Size = UDim2.fromOffset(if compact then width else math.max(1, width - 144), if compact then 42 else 30); intro.TextYAlignment = Enum.TextYAlignment.Top
	local listY = if compact then 104 else math.max(42, back.Size.Y.Offset + 8)
	local list: ScrollingFrame
	if compact then
		list = content
	else
		list = scroll(content)
		list.Name = "CreditsScroll"
		list.Position = UDim2.fromOffset(0, listY)
		list.Size = UDim2.fromOffset(width, math.max(1, layout.content.height - listY))
		list.ScrollBarThickness = 5
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	end
	local y = if compact then listY else 0
	local entryIndex = 0
	local function wrappedURL(value: any): string
		local url = tostring(value or "未记录")
		local chunkSize = if compact then 34 else 82
		local chunks = {}
		for start = 1, #url, chunkSize do table.insert(chunks, string.sub(url, start, start + chunkSize - 1)) end
		return table.concat(chunks, "\n")
	end
	local function textHeight(value: string, textSize: number, minimum: number, bold: boolean?): number
		local font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
		local bounds = TextService:GetTextSize(value, textSize, font, Vector2.new(math.max(1, width - 24), 10000))
		return math.max(minimum, bounds.Y + 4)
	end
	local function addSection(title: string, entries: {any})
		local heading = label(list, title, 16, C.navy, true); heading.Name = "CreditsSection_" .. title; heading.Position = UDim2.fromOffset(0, y); heading.Size = UDim2.fromOffset(width, 28)
		y += 34
		for _, entry in entries do
			entryIndex += 1
			local creatorText = tostring(entry.creator or "未知创作者") .. " · " .. tostring(entry.license or "许可未记录")
			local modelsText = "模型：" .. table.concat(entry.modelNames or {}, "、")
			local licenseText = "许可链接：" .. wrappedURL(entry.licenseURL)
			local sourceParts = {}
			for _, sourceURL in entry.sourceURLs or {} do table.insert(sourceParts, wrappedURL(sourceURL)) end
			local sourceText = "来源：" .. table.concat(sourceParts, "\n")
			local adaptationText = "适配：" .. tostring(entry.adaptation or "")
			local creatorHeight = textHeight(creatorText, 15, 24, true)
			local modelsHeight = textHeight(modelsText, 11, 22)
			local licenseHeight = textHeight(licenseText, 10, 18)
			local sourceHeight = textHeight(sourceText, 10, 18)
			local adaptationHeight = textHeight(adaptationText, 11, 22)
			local cardHeight = 8 + creatorHeight + 4 + modelsHeight + 4 + licenseHeight + 4 + sourceHeight + 4 + adaptationHeight + 10
			local card = panel(list); card.Name = "CreditEntry_" .. tostring(entryIndex); card.Position = UDim2.fromOffset(0, y); card.Size = UDim2.fromOffset(width, cardHeight)
			local cardWidth = math.max(1, width - 24)
			local cardY = 8
			local creator = label(card, creatorText, 15, C.ink, true); creator.Name = "CreditCreator"; creator.Position = UDim2.fromOffset(12, cardY); creator.Size = UDim2.fromOffset(cardWidth, creatorHeight); creator.TextYAlignment = Enum.TextYAlignment.Top; cardY += creatorHeight + 4
			local models = label(card, modelsText, 11, C.muted, false); models.Name = "CreditModels"; models.Position = UDim2.fromOffset(12, cardY); models.Size = UDim2.fromOffset(cardWidth, modelsHeight); models.TextYAlignment = Enum.TextYAlignment.Top; cardY += modelsHeight + 4
			local license = label(card, licenseText, 10, C.teal, false); license.Name = "CreditLicenseURL"; license.Position = UDim2.fromOffset(12, cardY); license.Size = UDim2.fromOffset(cardWidth, licenseHeight); license.TextYAlignment = Enum.TextYAlignment.Top; cardY += licenseHeight + 4
			local source = label(card, sourceText, 10, C.teal, false); source.Name = "CreditSourceURLs"; source.Position = UDim2.fromOffset(12, cardY); source.Size = UDim2.fromOffset(cardWidth, sourceHeight); source.TextYAlignment = Enum.TextYAlignment.Top; cardY += sourceHeight + 4
			local adaptation = label(card, adaptationText, 11, C.muted, false); adaptation.Name = "CreditAdaptation"; adaptation.Position = UDim2.fromOffset(12, cardY); adaptation.Size = UDim2.fromOffset(cardWidth, adaptationHeight); adaptation.TextYAlignment = Enum.TextYAlignment.Top
			y += cardHeight + 8
		end
	end
	addSection("鱼类素材", ArtCredits.fish or {})
	addSection("音效素材", ArtCredits.audio or {})
	if compact then
		setPageCanvas(y + 8)
	else
		list.AutomaticCanvasSize = Enum.AutomaticSize.None
		list.CanvasSize = UDim2.fromOffset(width, y + 8)
		setPageCanvas(0)
	end
end

local function renderOdds()
	mainTitle.Text = "当前掉落概率"
	clear(content)
	local compact = layout.stackPages
	local width = pageWidth()
	local back = button(content, "返回升级", C.navy2); back.Name = "OddsBack"; back.Position = UDim2.fromOffset(if compact then 0 else 600, 0); back.Size = UDim2.fromOffset(if compact then width else 128, if compact then 44 else 30); back.Activated:Connect(function() setActiveTab("升级") end)
	local note = label(content, "幸运只调整品质权重；每一钩独立抽取，以下为当前水域实际概率。", 13, C.muted, false); note.Name = "OddsNote"; note.Position = UDim2.fromOffset(0, if compact then 52 else 0); note.Size = UDim2.fromOffset(if compact then width else 560, if compact then 38 else 30)
	local listY = if compact then 98 else 42
	local rowHeight = if compact then 56 else 45
	local rowGap = 7
	local totalHeight = #((snapshot.odds or {})) * (rowHeight + rowGap)
	local s = scroll(content); s.Name = "OddsScroll"; s.Position = UDim2.fromOffset(0, listY); s.Size = UDim2.fromOffset(width, if compact then math.max(1, totalHeight) else 386); s.ScrollBarThickness = if compact then 0 else 5; listLayout(s, rowGap)
	for i, percent in snapshot.odds or {} do
		local row = panel(s); row.Name = "OddsRow_" .. tostring(i); row.Size = UDim2.fromOffset(width, rowHeight)
		local rarity = Config and Config.Rarities and Config.Rarities[i]
		local n = label(row, rarity and rarity.name or ("品质 " .. i), 14, C.ink, true); n.Position = UDim2.fromOffset(15, 10); n.Size = UDim2.fromOffset(math.max(1, width - 190), 22)
		local p = label(row, string.format("%.3f%%", tonumber(percent) or 0), 16, C.teal, true); p.TextXAlignment = Enum.TextXAlignment.Right; p.Position = UDim2.fromOffset(math.max(1, width - 180), 10); p.Size = UDim2.fromOffset(165, 22)
	end
	setPageCanvas(if compact then listY + totalHeight else 0)
end

local function renderFishing()
	local fishing = snapshot and snapshot.fishing
	updateHudVisibility()
	if not snapshot then return end
	local zone = tonumber(snapshot.currentZone)
	local waiting = anyRequestPending()
	local fishingState = UiRepair.actionState("toggleFishing", nil, {currentZone = zone, stopping = fishing == true, bagCount = UiRepair.countUnplaced(snapshot.fish or {}), bagCapacity = snapshot.bagCapacity or 0, hooks = snapshot.hooks or 0})
	local left = math.max(0, snapshot.secondsLeft or 0)
	local compactCopy = layout.compact or layout.touch
	if not zone then
		fishTitle.Text = "非钓鱼区域"
		fishDetail.Text = if compactCopy then "先到可钓水域" else "前往已解锁水域的钓鱼岸边后才能垂钓"
		fishProgress.Size = UDim2.fromScale(0, 1)
		fishButton.Text = fishingState.reason
	else
		local zoneConfig = Config and Config.Zones and Config.Zones[zone]
		fishTitle.Text = tostring(zoneConfig and zoneConfig.name or ("水域 " .. tostring(zone))) .. " · 钓点"
		if fishing then fishDetail.Text = string.format(if compactCopy then "垂钓中 · %d 秒后收线" else "鱼线已下水 · %d 秒后收线", math.ceil(left)); fishButton.Text = "停止垂钓"; fishProgress.Size = UDim2.fromScale(math.clamp(1 - left / 20, 0, 1), 1) else fishDetail.Text = fishingState.enabled and (if compactCopy then "20秒 · 每钩1条鱼" else "每 20 秒，每枚鱼钩各捕获一条鱼") or fishingState.reason; fishButton.Text = fishingState.enabled and "开始连续垂钓" or fishingState.reason; fishProgress.Size = UDim2.fromScale(0, 1) end
	end
	if waiting then fishButton.Text = "处理中…" end
	setButtonEnabled(fishButton, fishingState.enabled and not waiting, C.teal)
	setButtonEnabled(dockButton, not waiting, C.navy2)
	if zone and not fishing and not waiting and (snapshot.totalCaught or 0) == 0 and #(snapshot.fish or {}) >= 3 then
		fishDetail.Text = if compactCopy then "提示：三条鱼可入缸或三合一" else "新手提示：三条初始鱼可放入水族馆，或直接三合一"
	end
end
fishButton.Activated:Connect(function()
	if anyRequestPending() then notify("操作处理中，请稍候") elseif snapshot then
		local state = UiRepair.actionState("toggleFishing", nil, {currentZone = tonumber(snapshot.currentZone), stopping = snapshot.fishing == true, bagCount = UiRepair.countUnplaced(snapshot.fish or {}), bagCapacity = snapshot.bagCapacity or 0, hooks = snapshot.hooks or 0})
		if state.enabled then send("toggleFishing", {}) else notify(state.reason) end
	else notify("请先前往可钓鱼水域") end
end)
dockButton.Activated:Connect(function()
	if anyRequestPending() then notify("操作处理中，请稍候") else send("travel", {zone = (snapshot and (snapshot.currentZone or snapshot.zone)) or 1}) end
end)

local function scrollKey(): string
	return activeTab .. "|" .. bagFilter .. "|" .. tostring(bagPage) .. "|" .. tostring(mergePage)
end

render = function(force: boolean?)
	if not ownsCapturedMainGui() or not snapshot then return end
	for tab, each in tabButtons do setButtonEnabled(each, true, if tab == activeTab then C.teal else C.navy, tab == activeTab) end
	coinText.Text = "◉ " .. money(snapshot.coins); incomeText.Text = "⌂ " .. string.format("%.2f",snapshot.incomePerHour or 0) .. " / 时"; hookText.Text = "⚓ " .. tostring(snapshot.hooks or 1) .. " 鱼钩"
	local placed = 0; for _, f in snapshot.fish or {} do if f.placed then placed += 1 end end
	local storageNames = {session = "本次试玩", test = "测试云存档", live = "云存档"}
	tankText.Text = string.format("▣ %d / %d 入缸", placed, snapshot.tankCapacity or 0); storageBadge.Text = "存档：" .. (storageNames[snapshot.storageMode] or tostring(snapshot.storageMode or "--"))
	renderFishing()
	if not panelOpen then return end
	main.Visible = true
	local fishState = {}
	for _, f in snapshot.fish or {} do table.insert(fishState, table.concat({tostring(f.id), tostring(f.species), tostring(f.level), tostring(f.placed), tostring(f.locked), tostring(f.value), tostring(f.income), tostring(f.weightGrams), tostring(f.trait), tostring(f.salePrice)}, ":")) end
	local itemState = {}
	for itemId, count in pairs(snapshot.items or {}) do table.insert(itemState, tostring(itemId) .. ":" .. tostring(count)) end
	table.sort(itemState)
	local boostState = {}
	for kind, boost in pairs(snapshot.activeBoosts or {}) do table.insert(boostState, table.concat({tostring(kind), tostring(boost and boost.itemId), tostring(boost and boost.untilTime), tostring(math.floor(remainingBoost(boost))), tostring(boost and boost.amount), tostring(boost and boost.multiplier)}, ":")) end
	table.sort(boostState)
	local pendingSignature = ""
	for _, action in {"place", "remove", "sell", "sellDuplicates", "lock", "merge", "exchange", "useItem", "showcase", "hideFish", "upgrade", "unlock", "contract", "travel", "visitAquarium", "toggleFishing", "purchasePass", "purchaseBoost"} do if actionPending(action) then pendingSignature ..= action .. "," end end
	local signature = activeTab .. "|" .. shopMode .. "|" .. tostring(selectedId) .. "|" .. tostring(bagPage) .. "|" .. tostring(mergePage) .. "|" .. tostring(duplicateConfirm) .. "|" .. tostring(exchangeRecipeId) .. "|" .. table.concat(exchangeSelectedIds, ",") .. "|" .. tostring(exchangeConfirm) .. "|" .. tostring(exchangeSelectionKey) .. "|" .. tostring(useItemConfirmId) .. "|" .. tostring(saleConfirmId) .. "|" .. tostring(saleExpectedPrice) .. "|" .. tostring(saleConfirmationKey) .. "|" .. tostring(mergeConfirm) .. "|" .. tostring(mergeConfirmationKey) .. "|" .. bagFilter .. "|" .. table.concat(mergeIds, ",") .. "|" .. tostring(snapshot.coins) .. "|" .. tostring(snapshot.coinLevel) .. "|" .. tostring(snapshot.bagCapacity) .. "|" .. tostring(snapshot.tankCapacity) .. "|" .. tostring(snapshot.currentZone) .. "|" .. tostring(snapshot.currentDay) .. "|" .. tostring(snapshot.incomeStateVersion) .. "|" .. tostring(snapshot.incomePreviewExpiresAt) .. "|" .. tostring(snapshot.fishing) .. "|" .. tostring(snapshot.showcaseFishId) .. "|" .. tostring(snapshot.xp) .. "|" .. tostring(snapshot.playerLevel) .. "|" .. tostring(snapshot.xpToNextLevel) .. "|" .. tostring(snapshot.effectiveLuck) .. "|" .. table.concat(itemState, ",") .. "|" .. table.concat(boostState, ",") .. "|" .. pendingSignature .. "|" .. table.concat(fishState, ";")
	if activeTab == "图鉴" then signature ..= "|" .. tostring(snapshot.discoveryCount) .. "|" .. tostring(snapshot.dailyCaught) .. "|" .. tostring(snapshot.contractDay) .. "|" .. tostring(selectedContractSpecies)
	elseif activeTab == "升级" then
		signature ..= "|" .. tostring(snapshot.zone) .. "|" .. tostring(snapshot.discoveryCount)
		for key, upgrade in snapshot.upgrades or {} do signature ..= "|" .. tostring(key) .. ":" .. tostring(upgrade.level) .. ":" .. tostring(upgrade.cost) .. ":" .. tostring(upgrade.max) end
	elseif activeTab == "商店" then signature ..= "|" .. tostring(snapshot.paidAvailable)
	elseif activeTab == "水族馆" then signature ..= "|" .. tostring(snapshot.tankCapacity) .. "|" .. tostring(snapshot.incomePerHour)
	elseif activeTab == "概率" then signature ..= "|" .. tostring(snapshot.luck)
	elseif activeTab == "鸣谢" then signature ..= "|" .. tostring(ArtCredits.title) end
	if not force and signature == renderedFishSignature and activeTab ~= "钓鱼" then return end
	local previousScroll = content:FindFirstChildWhichIsA("ScrollingFrame", true)
	if renderedScrollKey ~= "" then
		if contentScrollEnabled() then scrollPositions[renderedScrollKey] = content.CanvasPosition
		elseif previousScroll then scrollPositions[renderedScrollKey] = previousScroll.CanvasPosition end
	end
	local nextScrollKey = scrollKey()
	renderedFishSignature = signature
	renderedScrollKey = nextScrollKey
	content.ScrollingEnabled = contentScrollEnabled()
	content.ScrollBarThickness = if contentScrollEnabled() then 5 else 0
	if activeTab == "背包" then renderBag() elseif activeTab == "水族馆" then renderAquarium() elseif activeTab == "合成" then renderMerge() elseif activeTab == "图鉴" then renderIndex() elseif activeTab == "升级" then renderUpgrades() elseif activeTab == "商店" then renderShop() elseif activeTab == "概率" then renderOdds() elseif activeTab == "鸣谢" then renderCredits() end
	local generation = lifecycle.generation
	task.defer(function()
		if not lifecycle.alive or lifecycle.generation ~= generation or playerGui:FindFirstChild("FishingAquariumUI") ~= gui or not gui.Parent or renderedScrollKey ~= nextScrollKey then return end
		local newScroll = content:FindFirstChildWhichIsA("ScrollingFrame", true)
		local position = pendingScrollPosition or scrollPositions[nextScrollKey] or Vector2.zero
		pendingScrollPosition = nil
		if contentScrollEnabled() then content.CanvasPosition = position elseif newScroll then newScroll.CanvasPosition = position end
	end)
end

lifecycle.connections.state = stateEvent.OnClientEvent:Connect(function(newState)
	if not ownsCapturedMainGui() then return end
	if not lifecycle.qaMode and RunService:IsStudio() then
		lifecycle.qaMode = script.Parent:FindFirstChild("MainLifecycleSmoke") ~= nil
	end
	if type(newState) == "table" then
		if newState.kind == "timer" then
			if snapshot then snapshot.secondsLeft = newState.secondsLeft; render(false) end
			return
		end
		if newState.kind == "audio" then
			if type(newState.cue) == "string" then Audio.play(newState.cue) end
			return
		end
		if newState.kind == "catch" then
			if lifecycle.characterReady and player.Character and catchPresentation then catchPresentation:playBatch(newState) end
			return
		end
			local acceptedSnapshot, releasedUnknown = setSnapshot(newState, false)
			if not acceptedSnapshot then return end
			if releasedUnknown > 0 then notify("状态已更新，请检查本次操作结果") end
			if newState.notice then notify(newState.notice, true) end
			render(false)
			local appliedSnapshot = snapshot
			if lifecycle.qaMode and type(appliedSnapshot) == "table" and type(appliedSnapshot.lifecycleQaMarker) == "number" then
				-- QA-only readback happens after the real snapshot/render path.  The
				-- no-character bit makes the fixture prove delivery during the respawn
				-- gap instead of merely observing a server FireClient call.
				gui:SetAttribute("LifecycleSnapshotAppliedMarker", appliedSnapshot.lifecycleQaMarker)
				gui:SetAttribute("LifecycleSnapshotAppliedWhileNoCharacter", player.Character == nil)
				gui:SetAttribute("LifecycleAppliedZone", if type(appliedSnapshot.currentZone) == "number" then appliedSnapshot.currentZone else -1)
				gui:SetAttribute("LifecycleAppliedFishCount", if type(appliedSnapshot.fish) == "table" then #appliedSnapshot.fish else -1)
				gui:SetAttribute("LifecycleAppliedCoins", if type(appliedSnapshot.coins) == "number" then appliedSnapshot.coins else -1)
				gui:SetAttribute("LifecycleAppliedFishing", appliedSnapshot.fishing == true)
			end
	end
end)

-- Small client-only cosmetic: one imported rod (or the old fallback) and
-- bobber while the player fishes.  The renderer owns the rod tip and weld
-- cleanup; this script only owns the Beam and bobber presentation.
local function fallbackHeldRod(parent: Instance, hand: BasePart, gripCFrame: CFrame, length: number)
	local rod = Instance.new("Part")
	rod.Name = "LocalFishingRod"
	rod.Anchored = false
	rod.Massless = true
	rod.CanCollide = false
	rod.CanTouch = false
	rod.CanQuery = false
	rod.Material = Enum.Material.Wood
	rod.Color = Color3.fromRGB(107, 73, 43)
	rod.Size = Vector3.new(.12, length, .12)
	rod.CFrame = gripCFrame * CFrame.new(0, length * .5, 0)
	local tip = Instance.new("Attachment")
	tip.Name = "FishingRodTip"
	tip:SetAttribute("RodTip", true)
	tip.Position = Vector3.new(0, length * .5, 0)
	tip.Parent = rod
	local weld = Instance.new("Weld")
	weld.Name = "FishingRodHandWeld"
	weld.Part0 = hand
	weld.Part1 = rod
	weld.C0 = hand.CFrame:ToObjectSpace(gripCFrame)
	weld.C1 = rod.CFrame:ToObjectSpace(gripCFrame)
	weld.Parent = rod
	rod.Parent = parent
	local cleaned = false
	local handle: any = {
		model = rod,
		tip = tip,
		handJoint = weld,
		cleanup = function()
			if cleaned then return end
			cleaned = true
			if rod.Parent then rod:Destroy() end
		end,
	}
	local baseC0 = weld.C0
	handle.setLift = function(amount: number)
		if cleaned or not weld.Parent then return end
		local lift = math.clamp(tonumber(amount) or 0, 0, 1)
		weld.C0 = baseC0 * CFrame.Angles(math.rad(16) * lift, 0, 0)
	end
	return handle
end

local function clearCosmetics()
	if heldRodHandle then
		heldRodHandle.cleanup()
		heldRodHandle = nil
	end
	if bobber then
		bobber:Destroy()
		bobber = nil
	end
	bobberBasePosition = nil
	bobberCastStart = nil
	bobberCastAt = 0
	fishingLine = nil
	for _, item in cosmetics do
		if item.Parent then item:Destroy() end
	end
	table.clear(cosmetics)
end

local function fishingCharacter()
	local char = player.Character
	if not char then return nil, nil end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	if not humanoid or humanoid.Health <= 0 or not hand or not hand:IsA("BasePart") then return char, nil end
	return char, hand
end

local function updateCosmetics()
	clearCosmetics()
	if not snapshot or not snapshot.fishing then return end
	local char, hand = fishingCharacter()
	if not char or not hand then return end

	local rodLength = 3.5
	local gripCFrame = hand.CFrame * CFrame.new(0, -.2, 0) * CFrame.Angles(math.rad(-70), 0, 0)
	heldRodHandle = ArtRenderer.heldRod(char, hand, gripCFrame, rodLength)
	if not heldRodHandle then
		heldRodHandle = fallbackHeldRod(char, hand, gripCFrame, rodLength)
	end
	if not heldRodHandle or not heldRodHandle.tip or not heldRodHandle.tip.Parent then return end

	bobber = Instance.new("Part")
	bobber.Name = "LocalBobber"
	bobber.Anchored = true
	bobber.CanCollide = false
	bobber.CanTouch = false
	bobber.CanQuery = false
	bobber.Shape = Enum.PartType.Ball
	bobber.Material = Enum.Material.Neon
	bobber.Color = C.red
	bobber.Size = Vector3.new(.32, .32, .32)
	local tipFrame = heldRodHandle.tip.WorldCFrame
	local root = char:FindFirstChild("HumanoidRootPart")
	local forward = root and root:IsA("BasePart") and root.CFrame.LookVector or tipFrame.LookVector
	forward = Vector3.new(forward.X, 0, forward.Z)
	if forward.Magnitude < .001 then forward = Vector3.new(0, 0, -1) else forward = forward.Unit end
	local right = Vector3.new(-forward.Z, 0, forward.X)
	if right.Magnitude < .001 then right = Vector3.new(1, 0, 0) else right = right.Unit end
	-- The default travel spawn is on the dock centerline, so a fixed forward
	-- offset can put the float inside the pier. Try a small, bounded set of
	-- forward then forward-diagonal water candidates and accept only a water
	-- ray hit. This runs once when cosmetics are rebuilt, never per frame.
	local candidateOffsets = {
		forward * 5,
		right * 12 + forward * 6,
		-right * 12 + forward * 6,
		right * 14 + forward * 12,
		-right * 14 + forward * 12,
		forward * 18,
	}
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = {char}
	for _, item in cosmetics do table.insert(excluded, item) end
	rayParams.FilterDescendantsInstances = excluded
	rayParams.IgnoreWater = false
	local waterTarget: Vector3? = nil
	for _, offset in candidateOffsets do
		local candidate = tipFrame.Position + offset
		local hit = workspace:Raycast(candidate + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), rayParams)
		if hit and hit.Material == Enum.Material.Water then
			waterTarget = hit.Position + Vector3.new(0, .15, 0)
			break
		end
	end
	if not waterTarget then
		-- If streaming temporarily hides Terrain, use the same zone-relative
		-- waterfront point that the server and World marker publish. This keeps
		-- the cosmetic bobber over water instead of falling back to an arbitrary
		-- forward point that can land on the island or pier.
		local zoneId = tonumber(snapshot and snapshot.currentZone)
		local zone = zoneId and Config and Config.Zones and Config.Zones[zoneId]
		if not zone or not FishingLocation then return end
		waterTarget = Vector3.new(zone.center.x, FishingLocation.Cast.y, zone.center.z + FishingLocation.Cast.zOffset)
	end
	bobberBasePosition = waterTarget
	bobberCastStart = tipFrame.Position + forward * 1.2
	bobberCastAt = os.clock()
	bobber.CFrame = CFrame.new(bobberCastStart)
	bobber.Parent = workspace

	local float = Instance.new("Attachment")
	float.Name = "FishingFloat"
	float.Parent = bobber
	local line = Instance.new("Beam")
	line.Name = "LocalFishingLine"
	line.Attachment0 = heldRodHandle.tip
	line.Attachment1 = float
	line.Width0 = .035
	line.Width1 = .025
	line.FaceCamera = true
	line.Color = ColorSequence.new(C.cream)
	line.Transparency = NumberSequence.new(.1)
	line.Parent = heldRodHandle.model
	fishingLine = line
end

local function bindCharacter(character: Model)
	if not ownsCapturedMainGui() then return end
	local guiGeneration = lifecycle.generation
	local generation = lifecycle.characterGeneration
	task.defer(function()
		if not ownsCapturedMainGui(guiGeneration, gui, mainGuiOwnerToken)
			or lifecycle.characterGeneration ~= generation or player.Character ~= character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if not ownsCapturedMainGui(guiGeneration, gui, mainGuiOwnerToken)
			or lifecycle.characterGeneration ~= generation or player.Character ~= character then return end
		if humanoid and humanoid:IsA("Humanoid") and character.Parent then
			if lifecycle.connections.humanoid then lifecycle.connections.humanoid:Disconnect() end
				lifecycle.connections.humanoid = humanoid.Died:Connect(function()
					if not ownsCapturedMainGui(guiGeneration, gui, mainGuiOwnerToken)
						or lifecycle.characterGeneration ~= generation or player.Character ~= character
						or humanoid.Parent ~= character or character:FindFirstChildOfClass("Humanoid") ~= humanoid then return end
				if not lifecycle.qaMode and RunService:IsStudio() then
					lifecycle.qaMode = script.Parent:FindFirstChild("MainLifecycleSmoke") ~= nil
				end
				if lifecycle.qaMode then
					local count = gui:GetAttribute("LifecycleDiedCount")
					gui:SetAttribute("LifecycleDiedCount", (if type(count) == "number" then count else 0) + 1)
				end
				if catchPresentation then catchPresentation:cancel("death") end
				setActiveTab("钓鱼")
				clearCosmetics()
			end)
		end
	end)
end

	lifecycle.connections.characterRemoving = player.CharacterRemoving:Connect(function()
		if not ownsCapturedMainGui() then clearCosmetics(); return end
		lifecycle.characterReady = false
		lifecycle.characterGeneration += 1
		if lifecycle.connections.humanoid then lifecycle.connections.humanoid:Disconnect(); lifecycle.connections.humanoid = nil end
		if requestGate and requestGate.incomePreview then requestGate.incomePreview:clear("角色移除", false) end
		if catchPresentation then catchPresentation:cancel("respawn") end
		setActiveTab("钓鱼")
		clearCosmetics()
	end)
	lifecycle.connections.characterAdded = player.CharacterAdded:Connect(function(character)
		if not ownsCapturedMainGui() then clearCosmetics(); return end
		lifecycle.characterReady = true
		lifecycle.characterGeneration += 1
		if catchPresentation then catchPresentation:cancel("respawn") end
		setActiveTab("钓鱼")
		clearCosmetics()
		bindCharacter(character)
		local guiGeneration = lifecycle.generation
		local generation = lifecycle.characterGeneration
		task.defer(function()
			if ownsCapturedMainGui(guiGeneration, gui, mainGuiOwnerToken)
				and lifecycle.characterGeneration == generation and player.Character == character then updateCosmetics() end
		end)
	end)
if player.Character then bindCharacter(player.Character) end

catchPresentation = CatchPresentation.new({
	overlayParent = playerGui,
	config = Config,
	artRenderer = ArtRenderer,
	runService = RunService,
	audioPlay = function(name: string)
		if ownsCapturedMainGui() then Audio.play(name) end
	end,
	getBagTarget = function() if layout.compact and bagShortcut.Visible then return bagShortcut end return tabButtons["背包"] end,
	getCharacter = function() return player.Character end,
	getFloatPosition = function()
		if bobber and bobber.Parent then return bobber.Position end
		return nil
	end,
	setRodPose = function(amount: number)
		if heldRodHandle and heldRodHandle.setLift then heldRodHandle.setLift(amount) end
	end,
	setLineTightness = function(amount: number)
		if fishingLine and fishingLine.Parent then
			local value = math.clamp(amount, 0, 1)
			fishingLine.Width0 = .035 + value * .018
			fishingLine.Width1 = .025 + value * .012
		end
	end,
})

-- UIRepairSmoke and FishPresentationSmoke use this documented BindableFunction
-- bridge to call the same navigation/selection/audio handlers when the guarded
-- Studio QA scripts are present. Their runtime state checks do not claim
-- physical-input coverage; the free Demo never creates the endpoint.
--
-- StarterPlayerScripts siblings can be cloned after main.client starts. A
-- one-shot FindFirstChild gate therefore races QA startup and permanently
-- omits the bridge. Keep the exact Studio/name guard, but also listen for the
-- late sibling and install once it arrives.
do
	lifecycle.studioHarness = {installed = false, connection = nil :: RBXScriptConnection?}
	lifecycle.studioHarness.install = function()
		if not ownsCapturedMainGui() or lifecycle.studioHarness.installed or not RunService:IsStudio() then return end
		local qaScript = script.Parent:FindFirstChild("UIRepairSmoke") or script.Parent:FindFirstChild("ResponsiveSmoke") or script.Parent:FindFirstChild("FishPresentationSmoke")
		if not qaScript then return end
		if not ownsCapturedMainGui() then return end
		local oldHarness = script.Parent:FindFirstChild("UIRepairHarness")
		if oldHarness then
			if not ownsCapturedMainGui() then return end
			oldHarness:Destroy()
		end
		if not ownsCapturedMainGui() then return end
		local harness = Instance.new("BindableFunction")
		harness.Name = "UIRepairHarness"
		harness.OnInvoke = function(command: any, value: any): any
			if not ownsCapturedMainGui() then return false end
			if command == "menu" then mobileMenuOpen = value == true; updateHudVisibility(); return true end
			if command == "tab" and type(value) == "string" then setActiveTab(value); return true end
			if command == "close" then setActiveTab("钓鱼"); return true end
			if command == "filter" and type(value) == "string" then bagFilter = value; bagPage = 1; setActiveTab("背包"); return true end
			if command == "bagSelect" and type(value) == "string" then return selectBagFish(value) end
			if command == "mergeSelect" and type(value) == "string" then
				local fish = findFish(value)
				if not fish then return false end
				setActiveTab("合成")
				toggleMergeSelection(fish)
				return true
			end
			if command == "audio" and type(value) == "string" and audioToggles[value] then
				local titles = {Music = "音乐", SFX = "音效", Ambience = "环境"}
				audioPanel.Visible = true
				toggleAudio(value, titles[value], audioToggles[value])
				return true
			end
				if command == "refresh" then if render then render(true) end; return true end
				return false
			end
		if not ownsCapturedMainGui() then harness:Destroy(); return end
		harness.Parent = script.Parent
		if not ownsCapturedMainGui() then harness:Destroy(); return end
		lifecycle.studioHarness.installed = true
		print("UI_REPAIR_HARNESS_READY")
			if lifecycle.studioHarness.connection then
				lifecycle.studioHarness.connection:Disconnect()
				lifecycle.studioHarness.connection = nil
			end
			lifecycle.connections.studioHarness = nil
	end
		if RunService:IsStudio() then
		lifecycle.studioHarness.install()
			if not lifecycle.studioHarness.installed then
				lifecycle.studioHarness.connection = script.Parent.ChildAdded:Connect(function(child)
					if ownsCapturedMainGui() and (child.Name == "UIRepairSmoke" or child.Name == "ResponsiveSmoke" or child.Name == "FishPresentationSmoke") then lifecycle.studioHarness.install() end
				end)
				lifecycle.connections.studioHarness = lifecycle.studioHarness.connection
				-- Recheck after the current startup turn in case the sibling was cloned
				-- during this script's initial setup without a ChildAdded callback here.
				task.defer(function(expectedGeneration, expectedGui, expectedToken)
					if ownsCapturedMainGui(expectedGeneration, expectedGui, expectedToken) then lifecycle.studioHarness.install() end
				end, lifecycle.generation, gui, mainGuiOwnerToken)
		end
	end
end

-- ResponsiveSmoke gets a separate Studio-only seam.  `viewport` deliberately
-- reports layout simulation; device/input acceptance must still use Studio's
-- device emulator.  The seam resizes the same safe root that production uses,
-- so QA measures real AbsolutePosition/AbsoluteSize after the renderer runs.
if RunService:IsStudio() and script.Parent:FindFirstChild("ResponsiveSmoke") and ownsCapturedMainGui() then
	(function()
		local oldHarness = script.Parent:FindFirstChild("ResponsiveHarness")
		if oldHarness then
			if not ownsCapturedMainGui() then return end
			oldHarness:Destroy()
		end
		if not ownsCapturedMainGui() then return end
		local harness = Instance.new("BindableFunction")
	harness.Name = "ResponsiveHarness"
	harness.OnInvoke = function(command: any, value: any, height: any, touch: any): any
		if not ownsCapturedMainGui() then return {ok = false, message = "GUI ownership lost"} end
			if command == "viewport" and type(value) == "number" and type(height) == "number" then
				layoutRoot.Position = UDim2.fromOffset(0, 0)
				layoutRoot.Size = UDim2.fromOffset(value, height)
				forcedLayoutViewport = {width = value, height = height, touch = touch == true}
				layout = ResponsiveLayout.compute(value, height, nil, nil, nil, nil, touch == true, panelOpen)
				applyViewportLayout()
				return {ok = true, mode = "layout-simulation", width = value, height = height, compact = layout.compact, touch = layout.touch, bagTarget = bagShortcut.Visible}
			end
			if command == "reset" then
				forcedLayoutViewport = nil
				layoutRoot.Position = UDim2.fromOffset(0, 0)
				layoutRoot.Size = UDim2.fromScale(1, 1)
				updateViewportLayout()
				return {ok = true, mode = "safe-root"}
			end
			if command == "measure" and type(value) == "string" then
				local target = gui:FindFirstChild(value, true)
				if target and target:IsA("GuiObject") then
					return {ok = true, name = value, visible = target.Visible, x = target.AbsolutePosition.X, y = target.AbsolutePosition.Y, width = target.AbsoluteSize.X, height = target.AbsoluteSize.Y}
				end
				return {ok = false, name = value}
			end
				if command == "state" then return {ok = true, mode = "safe-root", compact = layout.compact, touch = layout.touch, activeTab = activeTab, selectedId = selectedId, mergeCount = #mergeIds} end
				return {ok = false, message = "unknown responsive command"}
			end
		if not ownsCapturedMainGui() then harness:Destroy(); return end
		harness.Parent = script.Parent
		if not ownsCapturedMainGui() then harness:Destroy(); return end
		print("RESPONSIVE_HARNESS_READY")
	end)()
end

gui.Destroying:Connect(function()
	if requestGate and requestGate.incomePreview then requestGate.incomePreview:clear("Fishing UI 已销毁", false) end
	lifecycle.alive = false
	lifecycle.publishFishingSnapshotZone = nil
	lifecycle.characterReady = false
	lifecycle.generation += 1
	for key, connection in pairs(lifecycle.connections) do
		connection:Disconnect()
		lifecycle.connections[key] = nil
	end
	if catchPresentation then catchPresentation:destroy() end
	clearCosmetics()
	if clientRenderConnection then clientRenderConnection:Disconnect(); clientRenderConnection = nil end
	if viewportConnection then viewportConnection:Disconnect(); viewportConnection = nil end
	if cameraConnection then cameraConnection:Disconnect(); cameraConnection = nil end
	if rootSizeConnection then rootSizeConnection:Disconnect(); rootSizeConnection = nil end
end)

clientRenderConnection = RunService.RenderStepped:Connect(function()
	if not ownsCapturedMainGui() then return end
	if bobber and bobber.Parent and bobberBasePosition then
		local now = os.clock()
		local travel = math.clamp((now - bobberCastAt) / .35, 0, 1)
		local eased = travel * travel * (3 - 2 * travel)
		local castPosition = if bobberCastStart and travel < 1 then bobberCastStart:Lerp(bobberBasePosition, eased) else bobberBasePosition
		if travel >= 1 then bobberCastStart = nil end
		bobber.CFrame = CFrame.new(castPosition + Vector3.new(0, math.sin(now * 2.4) * .07, 0))
	end
	local char, hand = fishingCharacter()
	local wanted = snapshot ~= nil and snapshot.fishing == true and char ~= nil and hand ~= nil
	local equipped = heldRodHandle ~= nil and heldRodHandle.model ~= nil and heldRodHandle.model.Parent ~= nil
	if wanted and not equipped then
		updateCosmetics()
	elseif not wanted and equipped then
		clearCosmetics()
	end
end)
task.spawn(function()
	local generation = lifecycle.generation
	local ownerGui = gui
	local ownerToken = mainGuiOwnerToken
	for attempt = 1, 30 do
		if not ownsCapturedMainGui(generation, ownerGui, ownerToken) or snapshot then break end
		local preparedOk, prepared = invokeSnapshotBounded({prepareHandshake = true})
		if not ownsCapturedMainGui(generation, ownerGui, ownerToken) then return end
		local ok, result = false, nil
		if preparedOk and type(prepared) == "table" and prepared.prepareHandshake == true
			and type(prepared.stateEpoch) == "string" and type(prepared.handshakeFence) == "number" then
			-- A late prepare response cannot authorize a dead/replaced GUI to
			-- install a new owner. The server fence protects the delayed commit.
			ok, result = invokeSnapshotBounded({
				handshake = true,
				clientSessionNonce = lifecycle.mutationState.nonce,
				expectedEpoch = prepared.stateEpoch,
				expectedFence = prepared.handshakeFence,
			})
		end
		if not ownsCapturedMainGui(generation, ownerGui, ownerToken) then return end
		if ok and type(result) == "table" and result.handshake == true and type(result.state) == "table" and setSnapshot(result.state, true) then
				lifecycle.knownFishCount = #(snapshot.fish or {})
			render(true)
				if (snapshot.totalCaught or 0) == 0 and lifecycle.knownFishCount >= 3 then notify("新手提示：试试放入水族馆，或在合成页三合一", true) end
			break
		end
		if attempt == 1 then notify("正在连接渔港服务…") end
		task.wait(1)
	end
	if ownsCapturedMainGui(generation, gui, mainGuiOwnerToken) and not snapshot then notify("渔港服务尚未就绪，请稍后重试") end
end)
