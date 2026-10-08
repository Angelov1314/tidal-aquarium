--!strict
-- Runtime UI repair smoke. This exercises the real PlayerGui controls and then
-- samples the real GuiObject tree. It is included only by qa.project.json.
--
-- Input contract: use the documented UserInputService:CreateVirtualInput()
-- path first. If the running Studio build rejects it, this test uses the
-- narrow `UIRepairHarness` BindableFunction seam exposed by main.client only when
-- both RunService:IsStudio() and this test script are present. The seam must
-- dispatch the same real tab/button handlers; this test never reconstructs UI
-- and never invokes undocumented GuiButton methods.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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

local function findText(root: Instance, prefix: string, exact: boolean?): TextLabel?
	for _, item in root:GetDescendants() do
		if item:IsA("TextLabel") and item.Visible then
			local text = item.Text
			if (exact and text == prefix) or ((not exact) and string.sub(text, 1, #prefix) == prefix) then
				return item
			end
		end
	end
	return nil
end

local function containsText(root: Instance, needle: string): TextLabel?
	for _, item in root:GetDescendants() do
		if item:IsA("TextLabel") and item.Visible and string.find(item.Text, needle, 1, true) ~= nil then
			return item
		end
	end
	return nil
end

local function findButton(root: Instance, text: string, exact: boolean?): TextButton?
	for _, item in root:GetDescendants() do
		if item:IsA("TextButton") and item.Visible then
			local value = item.Text
			if (exact and value == text) or ((not exact) and string.find(value, text, 1, true) ~= nil) then
				return item
			end
		end
	end
	return nil
end

local function findNamed(root: Instance, names: {string}): GuiObject?
	for _, name in names do
		local item = root:FindFirstChild(name, true)
		if item and item:IsA("GuiObject") and item.Visible then return item end
	end
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

local function waitRender()
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
end

local function titleIs(root: Instance, prefix: string): boolean
	return findText(root, prefix, false) ~= nil
end

local function visibleScroll(root: Instance, leftSide: boolean?): ScrollingFrame?
	local candidates = {}
	for _, item in root:GetDescendants() do
		if item:IsA("ScrollingFrame") and item.Visible and item.AbsoluteSize.X > 100 and item.AbsoluteSize.Y > 100 then
			table.insert(candidates, item)
		end
	end
	table.sort(candidates, function(a, b) return a.AbsolutePosition.X < b.AbsolutePosition.X end)
	if leftSide == nil then return candidates[1] end
	for _, item in candidates do
		local isLeft = item.AbsolutePosition.X < root.AbsolutePosition.X + root.AbsoluteSize.X * .52
		if isLeft == leftSide then return item end
	end
	return nil
end

local function inactive(button: TextButton): boolean
	if not button.Active then return true end
	local ok, interactable = pcall(function() return button.Interactable end)
	return ok and interactable == false
end

local function run(): ()
	assert(RunService:IsStudio(), "UIRepairSmoke must run in Studio")
	assert(waitUntil(function() return ReplicatedStorage:GetAttribute("StudioSmokeReady") == true end, 36), "StudioSmoke did not finish before UI smoke deadline")

	local gui = playerGui:FindFirstChild("FishingAquariumUI")
	assert(gui and gui:IsA("ScreenGui"), "FishingAquariumUI missing")
	local main = gui:FindFirstChild("ContentPanel", true)
	assert(main and main:IsA("Frame"), "ContentPanel missing")
	local request = ReplicatedStorage:WaitForChild("FishingRemotes"):WaitForChild("Request") :: RemoteFunction
	local state, snapshotReason = readSnapshotBounded(request)
	assert(type(state) == "table", "UI smoke snapshot unavailable: " .. tostring(snapshotReason))
	local unplaced = 0
	for _, fish in state.fish or {} do if not fish.placed then unplaced += 1 end end

	local virtualInput: any = nil
	local inputMode = "BindableFunction"
	local virtualOK, candidate = pcall(function() return UserInputService:CreateVirtualInput() end)
	if virtualOK and candidate ~= nil then
		virtualInput = candidate
		inputMode = "VirtualInput"
	end
	print("UI_REPAIR_INPUT_MODE: " .. inputMode)

	local qaHarness: BindableFunction? = nil
	local function invokeHarness(command: string, value: any, description: string): any
		assert(waitUntil(function()
			if qaHarness and qaHarness.Parent then return true end
			local candidateHarness = script.Parent:FindFirstChild("UIRepairHarness")
			if candidateHarness and candidateHarness:IsA("BindableFunction") then
				qaHarness = candidateHarness
				return true
			end
			return false
		end, 5), "UI_REPAIR_INPUT_UNAVAILABLE: UIRepairHarness missing for " .. description)
		local ok, result = pcall(function() return (qaHarness :: BindableFunction):Invoke(command, value) end)
		assert(ok and result ~= false, "UI_REPAIR_HARNESS_FAILED: " .. description .. ": " .. tostring(result))
		return result
	end

	local function click(button: TextButton, expected: () -> boolean, description: string, harnessCommand: string?, harnessValue: any?)
		if virtualInput then
			local position = button.AbsolutePosition + button.AbsoluteSize * .5
			local sent = pcall(function()
				virtualInput:SendMousePosition(position)
				virtualInput:SendMouseButton(position, Enum.UserInputType.MouseButton1, true, 0)
				virtualInput:SendMouseButton(position, Enum.UserInputType.MouseButton1, false, 0)
			end)
			if sent then
				task.wait(.25)
				local changed, reached = pcall(expected)
				if changed and reached then return end
			end
			virtualInput = nil
			inputMode = "BindableFunction"
		end
		assert(harnessCommand ~= nil, "UI_REPAIR_INPUT_UNAVAILABLE: no harness command for " .. description)
		invokeHarness(harnessCommand :: string, harnessValue, description)
		assert(waitUntil(expected, 1.5), description .. " did not reach expected state")
	end

	local bagTab = findButton(gui, "背包", true)
	local aquariumTab = findButton(gui, "水族馆", true)
	local mergeTab = findButton(gui, "合成", true)
	local indexTab = findButton(gui, "图鉴", true)
	local upgradeTab = findButton(gui, "升级", true)
	local shopTab = findButton(gui, "商店", true)
	assert(bagTab and aquariumTab and mergeTab and indexTab and upgradeTab and shopTab, "UI navigation tabs missing")

	click(bagTab, function() return titleIs(main, "背包") end, "bag tab", "tab", "背包")
	waitRender()
	local bagTitle = findText(main, "背包", false)
	assert(bagTitle and string.find(bagTitle.Text, tostring(unplaced) .. "/" .. tostring(state.bagCapacity), 1, true) ~= nil,
		"bag title must count unplaced fish")
	print("UI_REPAIR_PASS: bag occupancy " .. tostring(unplaced) .. "/" .. tostring(state.bagCapacity))

	local audioButton = findButton(gui, "音频", true)
	local audioPanel = gui:FindFirstChild("AudioSettings", true)
	assert(audioButton and audioPanel and audioPanel:IsA("Frame"), "audio controls missing")
	-- Invoke the same production audio handler twice through the Studio-only
	-- bridge so the mute state returns to its initial value. This avoids
	-- treating a restricted native input API as a successful click.
	invokeHarness("audio", "Music", "audio panel open")
	assert(audioPanel.Visible, "audio harness did not open panel")
	assert(findButton(audioPanel, "音乐：开", true) or findButton(audioPanel, "音乐：关", true), "music toggle missing")
	invokeHarness("audio", "Music", "audio toggle restore")
	invokeHarness("close", nil, "reset after audio panel")
	assert(waitUntil(function() return not main.Visible end, 1.5), "close handler did not hide main panel")

	click(aquariumTab, function() return titleIs(main, "水族馆") end, "aquarium tab", "tab", "水族馆")
	waitRender()
	assert(containsText(main, "入缸") ~= nil, "aquarium occupancy summary missing")

	click(mergeTab, function() return titleIs(main, "三合一") end, "merge tab", "tab", "合成")
	waitRender()
	local instructions = findText(main, "选择三条", false)
	local pageText = findText(main, "材料第", false)
	assert(instructions and pageText, "merge instructions or pagination missing")
	assert(not overlaps(instructions, pageText), "merge instructions overlap pagination")
	local mergeScroll = findNamed(main, {"MergeMaterials", "MergeList"})
		or visibleScroll(main, true)
	local previewLabel = findText(main, "从左侧", false)
	local mergePreview = previewLabel and previewLabel.Parent
	assert(mergeScroll and mergePreview and mergePreview:IsA("GuiObject"), "merge list/preview missing")
	assert(not overlaps(mergeScroll, mergePreview :: GuiObject), "merge materials overlap preview")
	local function findBottomButton(root: GuiObject): TextButton?
		local candidate: TextButton? = nil
		for _, item in root:GetDescendants() do
			if item:IsA("TextButton") and item.Visible and (not candidate or item.AbsolutePosition.Y > (candidate :: TextButton).AbsolutePosition.Y) then
				candidate = item
			end
		end
		return candidate
	end
	local mergeButton = findBottomButton(mergePreview :: GuiObject)
	assert(mergeButton and inactive(mergeButton), "invalid empty merge must be unavailable")

	-- Select one real material through the card's Activated handler, or through
	-- the harness's mergeSelect(value) bridge when VirtualInput is restricted.
	local firstMergeFish: any = nil
	for _, fish in state.fish or {} do
		if fish.locked ~= true then firstMergeFish = fish; break end
	end
	local firstCard: TextButton? = nil
	for _, item in mergeScroll:GetChildren() do
		if item:IsA("TextButton") and item.Visible and item.Text == "" then firstCard = item; break end
	end
	if firstCard and firstMergeFish then
		click(firstCard, function() return containsText(main, "已选择 1 / 3") ~= nil end, "merge material selection", "mergeSelect", firstMergeFish.id)
		local selectedBefore = containsText(main, "已选择 1 / 3")
		assert(selectedBefore ~= nil, "merge selection was not rendered")
		local currentPreview = selectedBefore.Parent
		assert(currentPreview and currentPreview:IsA("GuiObject"), "merge selection preview missing after render")
		local currentMergeButton = findBottomButton(currentPreview :: GuiObject)
		assert(currentMergeButton and inactive(currentMergeButton), "partial merge must remain unavailable")
	end
	print("UI_REPAIR_PASS: merge geometry and selection availability")

	click(indexTab, function() return titleIs(main, "鱼类图鉴") end, "index tab", "tab", "图鉴")
	waitRender()
	assert(findText(main, "未发现", false) or findText(main, "最高 Lv.", false), "index cards missing")

	click(upgradeTab, function() return titleIs(main, "升级与水域") end, "upgrade tab", "tab", "升级")
	waitRender()
	local upgradeScroll = findNamed(main, {"UpgradeScroll", "UpgradeList"}) or visibleScroll(main, nil)
	local oddsButton = findButton(main, "查看当前掉落概率", false)
	assert(upgradeScroll and oddsButton, "upgrade scroll or odds footer missing")
	assert(not oddsButton:IsDescendantOf(upgradeScroll), "odds footer must sit outside upgrade scroll")
	assert(not overlaps(upgradeScroll, oddsButton), "odds footer overlaps upgrade scroll")
	click(oddsButton, function() return titleIs(main, "当前掉落概率") end, "odds footer", "tab", "概率")
	print("UI_REPAIR_PASS: upgrade footer outside scroll")

	click(shopTab, function() return titleIs(main, "商店") end, "shop tab", "tab", "商店")
	waitRender()
	local disabled = {}
	for _, item in main:GetDescendants() do
		if item:IsA("TextButton") and item.Visible and item.Text == "暂不可用" then table.insert(disabled, item) end
	end
	assert(#disabled > 0, "demo shop must expose disabled purchase controls")
	for _, item in disabled do assert(inactive(item), "disabled shop button is still interactive") end
	print("UI_REPAIR_PASS: disabled shop controls")

	local fishing = gui:FindFirstChild("FishingAction", true)
	assert(fishing and fishing:IsA("Frame"), "FishingAction missing")
	local zoneText = findText(fishing, "港湾钓点", false) or containsText(fishing, "非钓鱼区域")
	assert(zoneText, "fishing location label missing")
	if type(state.currentZone) == "number" then
		assert(string.find(zoneText.Text, tostring(state.currentZone) .. " 区", 1, true) ~= nil,
			"fishing UI must show currentZone, not highest unlocked zone")
	else
		assert(string.find(zoneText.Text, "非钓鱼区域", 1, true) ~= nil, "outside water must show non-fishing state")
	end
	print("UI_REPAIR_PASS: current zone versus unlock zone")
	print("UI_REPAIR_PASS: navigation, geometry, availability and current-zone checks complete")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then warn("UI_REPAIR_FAIL: " .. tostring(err)) end
