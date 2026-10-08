-- Mapped as ResponsiveSmoke to opt in to the existing Studio-only harness.
local player = game.Players.LocalPlayer
local scripts = player:WaitForChild("PlayerScripts")
local responsive = scripts:WaitForChild("ResponsiveHarness", 30)
local ui = scripts:WaitForChild("UIRepairHarness", 30)
local function expect(value, message) assert(value, message) end
local function item(name)
	local result = player.PlayerGui:FindFirstChild(name, true)
	expect(result, "missing " .. name)
	return result
end
local function expectTranslucent(object, description)
	expect(object:IsA("GuiObject"), description .. " is not a GUI object")
	expect(object.BackgroundTransparency >= .24 and object.BackgroundTransparency < 1, description .. " became opaque")
	if object:IsA("TextButton") then expect(object.TextTransparency <= .001, description .. " text became translucent") end
end
local ok, err = pcall(function()
	expect(responsive and ui, "HUD harness missing")
	for _, viewport in ipairs({{736,414}, {852,393}, {393,852}, {320,568}}) do
		responsive:Invoke("viewport", viewport[1], viewport[2], true)
		ui:Invoke("close")
		task.wait(.3)
		local header, fishing, nav, menu, bag = item("EconomyBar"), item("FishingAction"), item("NavViewport"), item("MobileMenuButton"), item("CompactBagButton")
		expect(header.AbsoluteSize.Y <= 48.1 and header.BackgroundTransparency >= .59, "header size/opacity")
		expect(fishing.AbsoluteSize.Y <= 100.1 and fishing.BackgroundTransparency >= .54, "fishing size/opacity")
		expectTranslucent(menu, "mobile menu button")
		expectTranslucent(bag, "compact bag button")
		expectTranslucent(item("FishingToggle"), "fishing toggle")
		expectTranslucent(item("DockButton"), "dock button")
		expect(not nav.Visible and menu.Visible and fishing.Visible, "default HUD not collapsed")
		expect(bag.Visible and bag.AbsoluteSize.X >= 44 and bag.AbsoluteSize.Y >= 44, "catch target unavailable")
		ui:Invoke("menu", true)
		task.wait(.1)
		expect(nav.Visible and not fishing.Visible, "menu expansion does not replace fishing overlay")
		for _, name in ipairs({"钓鱼","背包","水族馆","合成","图鉴","升级","商店"}) do
			local button = item("Tab_" .. name)
			expect(button.AbsoluteSize.X >= 44 and button.AbsoluteSize.Y >= 44, "nav target too small")
			expectTranslucent(button, "nav tab " .. name)
		end
		ui:Invoke("tab", "背包")
		task.wait(.1)
		local contentPanel = item("ContentPanel")
		expect(contentPanel.Visible and not nav.Visible and not fishing.Visible, "bag navigation failed")
		expect(contentPanel.BackgroundTransparency >= .19 and contentPanel.BackgroundTransparency < 1, "content panel became opaque")
		expectTranslucent(item("Tab_背包"), "selected bag tab")
		local bagList = item("BagList")
		local firstCard = bagList:FindFirstChildWhichIsA("TextButton", true)
		if firstCard then expectTranslucent(firstCard, "fish card") end
		ui:Invoke("close")
		task.wait(.1)
		expect(not item("ContentPanel").Visible and fishing.Visible and not nav.Visible, "close does not restore scene")
		print("COMPACT_HUD_VIEWPORT_PASS", viewport[1], viewport[2], header.AbsoluteSize, fishing.AbsoluteSize, header.BackgroundTransparency, fishing.BackgroundTransparency)
	end
	responsive:Invoke("viewport", 1280, 720, false)
	task.wait(.3)
	expect(item("NavViewport").Visible and not item("MobileMenuButton").Visible, "desktop navigation regressed")
	responsive:Invoke("reset")
	ui:Invoke("close")
	print("COMPACT_HUD_SMOKE_PASS", "actual GUI rectangles/opacity/menu/bag/desktop; layout simulation, not physical touch")
end)
if responsive then responsive:Invoke("reset") end
if not ok then warn("COMPACT_HUD_SMOKE_FAIL: " .. tostring(err)) end
