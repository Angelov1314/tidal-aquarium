-- Read-only GUI property review. It waits for a PlayerGui attribute so
-- CompactHUDSmoke can finish first and does not fight its responsive harness.
-- Manual Studio client command (after the scene settles):
--   local p = game:GetService("Players").LocalPlayer
--   local g = p:WaitForChild("PlayerGui")
--   g:SetAttribute("SceneUIReviewRequireMap", false)
--   g:SetAttribute("SceneUIReviewStart", true)
-- Set SceneUIReviewRequireMap=true and open SailingUI.MapButton (or press M)
-- before setting SceneUIReviewStart when the map overlay must be included.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local BUTTON_MIN_TRANSPARENCY = .24
local SURFACE_MIN_TRANSPARENCY = .19

local function waitRender()
	for _ = 1, 3 do RunService.RenderStepped:Wait() end
end
local function visible(item)
	local cursor = item
	while cursor do
		if cursor:IsA("GuiObject") and not cursor.Visible then return false end
		if cursor:IsA("ScreenGui") and not cursor.Enabled then return false end
		cursor = cursor.Parent
	end
	return true
end
local function expect(value, message)
	if not value then error(message, 2) end
end
local function find(name, root)
	local item = root and root:FindFirstChild(name, true)
	return item
end
local function checkButtons(root, label)
	expect(root, label .. " root missing")
	local count = 0
	local function check(item)
		if item:IsA("TextButton") then
			count += 1
			expect(item.BackgroundTransparency >= BUTTON_MIN_TRANSPARENCY,
				label .. " opaque button " .. item:GetFullName() .. " alpha=" .. tostring(item.BackgroundTransparency))
			expect(item.TextTransparency <= .01, label .. " button text became transparent: " .. item:GetFullName())
			expect(item.AutoButtonColor == false,
				label .. " AutoButtonColor can overwrite hover transparency: " .. item:GetFullName())
		end
	end
	check(root)
	for _, item in ipairs(root:GetDescendants()) do
		check(item)
	end
	expect(count > 0, label .. " has no TextButtons")
	return count
end
local function checkSurface(item, label, minimum)
	expect(item and item:IsA("GuiObject"), label .. " surface missing")
	expect(item.BackgroundTransparency >= (minimum or SURFACE_MIN_TRANSPARENCY),
		label .. " surface is opaque alpha=" .. tostring(item.BackgroundTransparency))
end
local function checkCoreGui()
	local gui = playerGui:FindFirstChild("FishingAquariumUI")
	expect(gui and gui:IsA("ScreenGui"), "FishingAquariumUI missing")
	local economy = find("EconomyBar", gui)
	local fishing = find("FishingAction", gui)
	checkSurface(economy, "primary EconomyBar")
	checkSurface(fishing, "primary FishingAction")
	checkButtons(economy, "primary EconomyBar")
	checkButtons(fishing, "primary FishingAction")
	local nav = find("NavViewport", gui)
	local menu = find("MobileMenuButton", gui)
	expect(nav or menu, "navigation/menu surfaces missing")
	if nav then checkSurface(nav, "navigation NavViewport", .14); checkButtons(nav, "navigation NavViewport") end
	if menu then
		checkSurface(menu, "navigation MobileMenuButton")
		checkButtons(menu, "navigation MobileMenuButton")
	end
	return gui
end
local function checkBackpack(gui)
	local panel = find("ContentPanel", gui)
	expect(panel and panel.Visible, "backpack ContentPanel is not visible")
	local title = find("PageTitle", panel)
	expect(title and string.find(title.Text, "背包", 1, true), "backpack page was not selected")
	checkSurface(panel, "backpack ContentPanel")
	local count = checkButtons(panel, "backpack ContentPanel")
	print("SCENE_UI_BACKPACK_PASS", count, "buttons translucent/text opaque")
end
local function checkMap()
	local sailing = playerGui:FindFirstChild("SailingUI")
	local panel = sailing and sailing:FindFirstChild("MapPanel", true)
	if not panel or not panel.Visible then
		print("SCENE_UI_MAP_PENDING", "open SailingUI.MapButton or press M, then rerun SceneUIHarness checkMap")
		return false
	end
	checkSurface(panel, "sailing MapPanel")
	local count = checkButtons(panel, "sailing MapPanel")
	print("SCENE_UI_MAP_PASS", count, "buttons translucent/text opaque")
	return true
end
local function requireUiRepairHarness()
	local harness = script.Parent:FindFirstChild("UIRepairHarness")
	expect(harness and harness:IsA("BindableFunction"),
		"UIRepairHarness missing; run ResponsiveSmoke first so navigation checks cannot false-pass")
	return harness
end
local function invokeUi(command, value)
	local harness = requireUiRepairHarness()
	local ok, result = pcall(function() return harness:Invoke(command, value) end)
	expect(ok and result ~= false, "UIRepairHarness command failed: " .. command)
	return true
end
local function run(requireMap)
	requireUiRepairHarness()
	waitRender()
	local gui = checkCoreGui()
	if invokeUi("menu", true) then
		waitRender()
		checkCoreGui()
	end
	if invokeUi("tab", "背包") then
		waitRender()
		checkBackpack(gui)
	end
	invokeUi("close")
	waitRender()
	local mapPass = checkMap()
	if requireMap then expect(mapPass, "map review requested while MapPanel is closed") end
	playerGui:SetAttribute("SceneUIReviewPass", true)
	print("SCENE_UI_PASS", "primary board, nav/menu, backpack, map=" .. tostring(mapPass))
	return true
end

local harness = Instance.new("BindableFunction")
harness.Name = "SceneUIHarness"
harness.OnInvoke = function(command, value)
		if command == "check" then return pcall(run, value == true) end
		if command == "checkMap" then return pcall(checkMap) end
		return false
	end
harness.Parent = script.Parent

local function maybeRun()
	if playerGui:GetAttribute("SceneUIReviewStart") ~= true then return end
	local ok, err = pcall(run, playerGui:GetAttribute("SceneUIReviewRequireMap") == true)
	if not ok then
		playerGui:SetAttribute("SceneUIReviewPass", false)
		warn("SCENE_UI_FAIL: " .. tostring(err))
	end
end
playerGui:GetAttributeChangedSignal("SceneUIReviewStart"):Connect(maybeRun)
playerGui:GetAttributeChangedSignal("SceneUIReviewRequireMap"):Connect(function()
	if playerGui:GetAttribute("SceneUIReviewRequireMap") == true then
		local ok, err = pcall(checkMap)
		if not ok then warn("SCENE_UI_MAP_FAIL: " .. tostring(err)) end
	end
end)
