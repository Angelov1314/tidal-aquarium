-- SailingQA client smoke. It drives the real BoatRemotes.Intent path and
-- samples replicated geometry/UI, so a passing test cannot be produced by
-- moving BoatService's private state from a server fixture.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local function expect(condition, message)
	if not condition then error(message, 2) end
end

local function waitForChildBounded(parent, name, timeout, label)
	local deadline = os.clock() + (timeout or 30)
	local candidate = parent:FindFirstChild(name)
	while candidate == nil and os.clock() < deadline do
		task.wait(.1)
		candidate = parent:FindFirstChild(name)
	end
	expect(candidate ~= nil, label or (name .. " did not become ready"))
	return candidate
end

local playerGui = waitForChildBounded(player, "PlayerGui", 12, "PlayerGui did not become ready")
expect(playerGui:IsA("PlayerGui"), "PlayerGui dependency has the wrong class")

local function waitUntil(predicate, timeout, label)
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline do
		local ok, result = pcall(predicate)
		if ok and result then return true end
		task.wait(.1)
	end
	error(label or "condition timed out", 2)
end

local function waitForCharacter(player, timeout, label)
	waitUntil(function() return player.Character ~= nil end, timeout or 30, label or "character did not become ready")
	return player.Character
end

local lastRequestAt = -math.huge
local function invoke(request, action, payload)
	-- Exercise normal requests without accidentally testing the deliberate
	-- 140ms server debounce when adjacent assertions issue calls in one frame.
	local spacing = .2 - (os.clock() - lastRequestAt)
	if spacing > 0 then task.wait(spacing) end
	lastRequestAt = os.clock()
	local ok, result = pcall(function()
		return request:InvokeServer(action, payload or {})
	end)
	expect(ok and type(result) == "table", "BoatRemotes.Request crashed for " .. action)
	return result
end

local function report(remote, kind)
	remote:FireServer({kind = kind})
end

local function qaCall(bridge, command, payload)
	local ok, result = pcall(function() return bridge:Invoke(command, payload) end)
	return ok and result ~= false, result
end

local function eventually(predicate, timeout)
	local deadline = os.clock() + (timeout or 1.5)
	while os.clock() < deadline do
		local ok, result = pcall(predicate)
		if ok and result then return true end
		task.wait(.1)
	end
	return false
end

local function clickOrDirectHandler(button, expected, bridge, command, description)
	local virtualOK, virtualInput = pcall(function() return UserInputService:CreateVirtualInput() end)
	if virtualOK and virtualInput then
		local position = button.AbsolutePosition + button.AbsoluteSize * .5
		local sent = pcall(function()
			virtualInput:SendMousePosition(position)
			virtualInput:SendMouseButton(position, Enum.UserInputType.MouseButton1, true, 0)
			virtualInput:SendMouseButton(position, Enum.UserInputType.MouseButton1, false, 0)
		end)
		if sent and eventually(expected, 1.5) then
			return "VirtualInput"
		end
	end
	-- This fallback is deliberately labelled as a direct handler seam.  It is
	-- useful for state/lifecycle coverage when Studio cannot create virtual
	-- input, but it never claims physical touch/mouse coverage.
	local ok = qaCall(bridge, command)
	expect(ok, description .. " direct handler failed")
	expect(eventually(expected, 1.5), description .. " did not reach expected state")
	return "DirectHandler"
end

local function findDescendant(root, name)
	local object = root and root:FindFirstChild(name, true)
	return object
end

local function findSummonPrompt()
	local docks = workspace:FindFirstChild("SailingDocks")
	if not docks then return nil end
	for _, item in ipairs(docks:GetDescendants()) do
		if item:IsA("ProximityPrompt") and item.Name == "SummonBoatPrompt" then return item end
	end
	return nil
end

local function checkTranslucent(object, name)
	expect(object and object:IsA("GuiObject"), name .. " missing")
	expect(object.BackgroundTransparency >= .24 and object.BackgroundTransparency < 1, name .. " became opaque")
	if object:IsA("TextButton") then expect(object.TextTransparency <= .001, name .. " text became translucent") end
end

local function overlap(a, b)
	if not a or not b or not a:IsA("GuiObject") or not b:IsA("GuiObject") then return false end
	local ap, as = a.AbsolutePosition, a.AbsoluteSize
	local bp, bs = b.AbsolutePosition, b.AbsoluteSize
	return ap.X < bp.X + bs.X and ap.X + as.X > bp.X
		and ap.Y < bp.Y + bs.Y and ap.Y + as.Y > bp.Y
end

local function isShown(object)
	local current = object
	while current and current ~= playerGui do
		if current:IsA("GuiObject") and not current.Visible then return false end
		if current:IsA("ScreenGui") and not current.Enabled then return false end
		current = current.Parent
	end
	return current == playerGui
end

local function resolvedSize(object, viewportX, viewportY)
	local size = object.Size
	return viewportX * size.X.Scale + size.X.Offset, viewportY * size.Y.Scale + size.Y.Offset
end

local function checkMapViewportBounds(panel)
	-- The same smoke is run by the screen operator at 736x414 and 414x736;
	-- inspect the real layout after that viewport settles rather than applying a
	-- desktop AbsoluteSize to a hypothetical orientation.
	local camera = workspace.CurrentCamera
	expect(camera and panel.AbsoluteSize.X > 0 and panel.AbsoluteSize.Y > 0, "map viewport did not settle")
	local viewport = camera.ViewportSize
	local left = panel.AbsolutePosition.X
	local top = panel.AbsolutePosition.Y
	expect(left >= 8 and top >= 8 and left + panel.AbsoluteSize.X <= viewport.X - 8
		and top + panel.AbsoluteSize.Y <= viewport.Y - 8,
		"MapPanel leaves the current safe viewport")
	print(string.format("SAILING_UI_BOUNDS_PASS: viewport=%.0fx%.0f panel=%.0fx%.0f at=%.0f,%.0f", viewport.X, viewport.Y,
		panel.AbsoluteSize.X, panel.AbsoluteSize.Y, left, top))
end

local function checkTouchTargets(gui)
	local required = {"MapButton", "BagButton", "MapClose", "Forward", "Reverse", "Left", "Right", "LeaveBoat", "ReturnHarbor", "SummonButton"}
	for _, name in ipairs(required) do
		local object = findDescendant(gui, name)
		expect(object and object:IsA("GuiButton"), "sailing touch target missing: " .. name)
		expect(object.AbsoluteSize.X >= 44 and object.AbsoluteSize.Y >= 44,
			"sailing touch target below 44px: " .. name)
	end
	local touchGui = playerGui:FindFirstChild("TouchGui")
	local jump = touchGui and findDescendant(touchGui, "JumpButton")
	local exit = findDescendant(gui, "LeaveBoat")
	if jump and exit and isShown(jump) and isShown(exit) then
		expect(not overlap(jump, exit), "LeaveBoat overlaps the default mobile JumpButton")
	end
	if touchGui and touchGui:IsA("ScreenGui") then
		expect(not touchGui.Enabled, "default touch movement must be hidden while driving")
	end
end

local function driveBetweenIslands(request, bridge, root)
	local summoned = invoke(request, "summon", {zone = 1})
	expect(summoned.ok, "cross-island summon failed")
	waitUntil(function()
		local ok, state = qaCall(bridge, "state")
		return ok and state and state.driving
	end, 5, "cross-island seat attachment did not finish")
	local started = os.clock()
	-- Route through open sea, then approach the south-facing Mystic Lake pier.
	-- Every movement goes through the production input path; no pose is assigned.
	for _, waypoint in ipairs({{x = 0, z = 260}, {x = -1400, z = 480}, {x = -1480, z = 390}}) do
		local deadline = os.clock() + 75
		local reached = false
		repeat
			local ok, state = qaCall(bridge, "state")
			expect(ok and state and state.driving and state.position, "lost driver authority during cross-island route")
			local dx, dz = waypoint.x - state.position.x, waypoint.z - state.position.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance < 22 then reached = true break end
			local desired = math.atan2(-dx, -dz)
			local delta = (desired - state.heading + math.pi) % (math.pi * 2) - math.pi
			local throttle = if math.abs(delta) > .8 then 0 else math.clamp(distance / 100, .18, 1)
			qaCall(bridge, "setInput", {throttle = throttle, steer = math.clamp(-delta * 1.5, -1, 1)})
			task.wait(.1)
		until os.clock() >= deadline
		expect(reached, string.format("cross-island route stuck before %.0f,%.0f", waypoint.x, waypoint.z))
	end
	qaCall(bridge, "clearInput")
	local arrived = invoke(request, "snapshot", {})
	local position = arrived.state.position
	expect(position and position.x < -1400 and position.z > 340, "boat did not physically reach Mystic Lake")
	expect((root.Position - Vector3.new(position.x, root.Position.Y, position.z)).Magnitude < 12,
		"character failed to accompany cross-island voyage")
	local landed = invoke(request, "leave", {})
	expect(landed.ok, "could not disembark at Mystic Lake")
	task.wait(.4)
	expect((root.Position - Vector3.new(-1480, root.Position.Y, 336)).Magnitude < 12,
		"disembark did not place character on Mystic Lake pier")
	local ashore = invoke(request, "snapshot", {})
	expect(not ashore.state.active, "dock landing left an active boat behind")
	print(string.format("SAILING_CROSS_ISLAND_PASS: harbor to Mystic Lake, actual intent route, character follows, dock landing, %.1fs", os.clock() - started))
end

local function run()
	expect(RunService:IsStudio(), "SailingSmoke.client must run in Studio")
	local remotes = ReplicatedStorage:WaitForChild("BoatRemotes", 45)
	expect(remotes, "BoatRemotes missing")
	local request = remotes:WaitForChild("Request", 15)
	local intent = remotes:WaitForChild("Intent", 15)
	local reportRemote = ReplicatedStorage:WaitForChild("SailingSmokeReport", 45)
	local gui = playerGui:WaitForChild("SailingUI", 45)
	waitUntil(function() return gui:GetAttribute("SailingClientReady") == true end, 15, "SailingUI did not become ready")
	local bridge = gui:FindFirstChild("SailingQA")
	expect(bridge and bridge:IsA("BindableFunction"),
		"SailingUI.SailingQA is required for deterministic QA input/map phases")
	local bridgeOk, layout = qaCall(bridge, "layout")
	expect(bridgeOk and type(layout) == "table" and layout.panel and layout.chart and layout.safeRoot,
		"SailingQA layout contract is incomplete")
	waitUntil(function() return ReplicatedStorage:GetAttribute("SailingSmokeServerReady") == true end, 90,
		"server did not authorize SailingSmoke summon")
	local summonPrompt
	waitUntil(function()
		summonPrompt = findSummonPrompt()
		return summonPrompt ~= nil
	end, 15, "dock summon prompt missing")
	expect(gui:GetAttribute("CustomSummonPromptStyle") == true, "SailingUI did not advertise custom dock prompt ownership")
	expect(gui:GetAttribute("NativeSummonPromptInput") == true, "SailingUI did not preserve native keyboard/gamepad prompt input")
	expect(summonPrompt.Style == Enum.ProximityPromptStyle.Custom, "dock summon prompt was left in default visual style")
	local summonEnabled = summonPrompt.Enabled

	local initial = invoke(request, "snapshot", {})
	expect(initial.ok and initial.state and initial.state.active and initial.state.driving, "server-summoned boat not visible to client")
	expect(summonPrompt.Enabled == summonEnabled, "custom prompt ownership changed server-controlled Enabled state")
	expect(initial.state.map and #initial.state.map.zones == 9, "boat map snapshot does not contain nine zones")
	local boats = workspace:WaitForChild("SailingBoats", 15)
	local boat
	waitUntil(function()
		for _, candidate in ipairs(boats:GetChildren()) do
			if candidate:GetAttribute("OwnerUserId") == player.UserId then boat = candidate break end
		end
		return boat ~= nil and boat.PrimaryPart ~= nil
	end, 10, "replicated player boat model missing")

	local character = waitForCharacter(player, 30, "character did not become ready for sailing smoke")
	local root = waitForChildBounded(character, "HumanoidRootPart", 10, "HumanoidRootPart did not become ready")
	expect(root:IsA("BasePart"), "HumanoidRootPart dependency has the wrong class")
	local seat = boat:FindFirstChild("CaptainSeat")
	expect(seat and seat:IsA("Seat"), "replicated CaptainSeat missing")
	local reboardPrompt = seat:FindFirstChild("ReboardPrompt")
	expect(reboardPrompt and not reboardPrompt.Enabled, "boarding prompt must not cover the driver controls")

	-- Real movement: only FireServer intent is used. Sample the relative seat
	-- distance during motion to prove the character follows the boat hull.
	local beforeMove = boat:GetPivot().Position
	local beforeHeading = boat:GetPivot():ToEulerAnglesYXZ()
	local maxFollowError = 0
	for _ = 1, 28 do
		expect(qaCall(bridge, "setInput", {throttle = 1, steer = 0}),
			"SailingQA could not send forward intent")
		task.wait(.08)
		if root.Parent and seat.Parent then maxFollowError = math.max(maxFollowError, (root.Position - seat.Position).Magnitude) end
	end
	task.wait(.25)
	local afterMove = invoke(request, "snapshot", {})
	expect(afterMove.ok and afterMove.state and afterMove.state.active, "boat stopped reporting active after forward intent")
	local movedPosition = boat:GetPivot().Position
	expect((movedPosition - beforeMove).Magnitude > 2, "BoatRemotes.Intent did not move the real boat")
	expect((afterMove.state.velocity or 0) > 0, "server did not retain forward boat velocity")

	local headingBeforeTurn = afterMove.state.heading or beforeHeading
	for _ = 1, 24 do
		expect(qaCall(bridge, "setInput", {throttle = 1, steer = 1}),
			"SailingQA could not send steer intent")
		task.wait(.08)
		if root.Parent and seat.Parent then maxFollowError = math.max(maxFollowError, (root.Position - seat.Position).Magnitude) end
	end
	task.wait(.25)
	local afterTurn = invoke(request, "snapshot", {})
	local headingAfterTurn = afterTurn.state and afterTurn.state.heading or headingBeforeTurn
	expect(math.abs(headingAfterTurn - headingBeforeTurn) > .03, "real steer intent did not turn the boat")
	expect(maxFollowError < 12, string.format("character did not follow boat seat (max error %.1f)", maxFollowError))
	report(reportRemote, "motion")
	print(string.format("SAILING_PHASE_MOTION_PASS: moved=%.1f headingDelta=%.3f maxFollowError=%.1f", (movedPosition - beforeMove).Magnitude, math.abs(headingAfterTurn - headingBeforeTurn), maxFollowError))

	-- Open the actual map while driving and inspect the rendered chart. The
	-- marker identity must survive state updates; rebuilding buttons every .12s
	-- makes touch taps lose their target.
	qaCall(bridge, "clearInput")
	local mapButton = findDescendant(gui, "MapButton")
	local mapPanel = layout.panel
	local chart = layout.chart
	expect(mapButton and mapPanel and chart, "sailing map GUI contract missing")
	checkTranslucent(mapButton, "map toggle")
		expect(qaCall(bridge, "setMapOpen", true),
		"SailingQA could not open map through setMapOpen")
	waitUntil(function() return mapPanel.Visible and chart.AbsoluteSize.X > 0 and chart.AbsoluteSize.Y > 0 end, 5, "map panel did not open")
	checkMapViewportBounds(mapPanel)
	local markers = {}
	for _, child in ipairs(chart:GetChildren()) do
		if child:IsA("GuiButton") and child.Name == "ZoneMarker" then table.insert(markers, child) end
	end
	expect(#markers == 9, "map chart does not render nine zone markers")
	local markerIdentity = markers[1]
	task.wait(.45)
	expect(markerIdentity.Parent == chart, "map marker was destroyed during boat state redraw")
	checkTouchTargets(gui)
	local mapClose = findDescendant(gui, "MapClose")
	expect(mapClose and mapClose:IsA("GuiButton"), "map close button missing")
	checkTranslucent(mapClose, "map close")
	for _, marker in ipairs(markers) do checkTranslucent(marker, "map marker") end
	local legacy = playerGui:FindFirstChild("FishingAquariumUI")
	if legacy and legacy:IsA("ScreenGui") then expect(legacy.Enabled == false, "fishing HUD was not hidden while driving") end

	-- Leave while the map is still open. The server state edge must force the
	-- local map closed and release the modal input gate before recovery.
	local leave = invoke(request, "leave", {})
	expect(leave.ok, "offshore leave request failed")
	task.wait(.35)
	expect(not mapPanel.Visible and mapButton.Visible, "forced leave did not close the sailing map modal")
	local afterLeave = invoke(request, "snapshot", {})
	expect(afterLeave.ok and afterLeave.state and afterLeave.state.active and not afterLeave.state.driving,
		"leave did not enter recovery-float state")
	local recovery = boat:FindFirstChild("RecoveryFloat")
	expect(recovery and recovery:IsA("BasePart"), "offshore leave did not create RecoveryFloat")
	expect(reboardPrompt.Enabled, "boarding prompt did not return on the recovery float")
	expect((root.Position - recovery.Position).Magnitude < 10,
		string.format("character was not placed on RecoveryFloat: root=%s pad=%s distance=%.1f", tostring(root.Position), tostring(recovery.Position), (root.Position - recovery.Position).Magnitude))

	local reboard = invoke(request, "reboard", {})
	expect(reboard.ok, "reboard request failed: " .. tostring(reboard.message))
	task.wait(.2)
	local aboard = invoke(request, "snapshot", {})
	expect(aboard.ok and aboard.state and aboard.state.driving, "reboard did not restore driving state")

	local bagButton = findDescendant(gui, "BagButton")
	expect(bagButton and bagButton:IsA("GuiButton") and isShown(bagButton), "boat backpack button is not visible after reboard")
	checkTranslucent(bagButton, "boat backpack")
	local panelOpen = function()
		local current = playerGui:FindFirstChild("FishingAquariumUI")
		local currentPanel = current and findDescendant(current, "ContentPanel")
		return current and current:IsA("ScreenGui") and current.Enabled and currentPanel and currentPanel.Visible and current:GetAttribute("PanelOpen") == true
	end
	local bagInputMode = clickOrDirectHandler(bagButton, panelOpen, bridge, "openBag", "boat backpack")
	expect(panelOpen(), "boat backpack did not open the existing fishing panel")
	local currentLegacy = playerGui:FindFirstChild("FishingAquariumUI")
	local closeButton = currentLegacy and findDescendant(currentLegacy, "CloseButton")
	expect(closeButton and closeButton:IsA("GuiButton"), "fishing panel close button missing after boat backpack open")
	local panelClosed = function()
		local current = playerGui:FindFirstChild("FishingAquariumUI")
		local currentPanel = current and findDescendant(current, "ContentPanel")
		return currentPanel ~= nil and not currentPanel.Visible and current:GetAttribute("PanelOpen") == false
	end
	local closeInputMode = clickOrDirectHandler(closeButton, panelClosed, bridge, "closeBag", "boat backpack close")
	expect(panelClosed(), "boat backpack close did not restore the sailing HUD")

	-- Replace the bridge after ContentPanel is already bound. Sailing must
	-- re-resolve the late child instead of retaining the orphaned event.
	currentLegacy = playerGui:FindFirstChild("FishingAquariumUI")
	local originalBridge = currentLegacy and currentLegacy:FindFirstChild("OpenPage")
	expect(originalBridge and originalBridge:IsA("BindableEvent"), "legacy OpenPage bridge missing")
	local replacementBridge = Instance.new("BindableEvent")
	replacementBridge.Name = "OpenPage"
	local replacementPage = nil
	replacementBridge.Event:Connect(function(page) replacementPage = page end)
	originalBridge.Parent = nil
	replacementBridge.Parent = currentLegacy
	local lateOK = qaCall(bridge, "openBag")
	waitUntil(function() return replacementPage == "背包" end, 3, "late OpenPage replacement was not rebound before timeout")
	expect(lateOK and replacementPage == "背包", "late OpenPage replacement was not rebound")
	replacementBridge.Parent = nil
	originalBridge.Parent = currentLegacy
	task.wait(.15)
	print("SAILING_BAG_BRIDGE_PASS: input=" .. bagInputMode .. ", close=" .. closeInputMode .. ", late replacement rebound; direct handler is not physical input")

	local returned = invoke(request, "returnHarbor", {})
	expect(returned.ok, "returnHarbor request failed")
	task.wait(.35)
	local afterReturn = invoke(request, "snapshot", {})
	expect(afterReturn.ok and afterReturn.state and not afterReturn.state.active, "returnHarbor left active state")
	if legacy and legacy:IsA("ScreenGui") then expect(legacy.Enabled == true, "fishing HUD was not restored at harbor") end

	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	print(string.format("SAILING_PHASE_UI_PASS: current viewport %.0fx%.0f bounds, map markers, 44px targets, HUD hide/restore, leave/reboard/return",
		if viewport then viewport.X else 0, if viewport then viewport.Y else 0))
	driveBetweenIslands(request, bridge, root)
	qaCall(bridge, "clearInput")
	report(reportRemote, "done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	local reportRemote = ReplicatedStorage:FindFirstChild("SailingSmokeReport")
	if reportRemote and reportRemote:IsA("RemoteEvent") then report(reportRemote, "failed") end
	warn("SAILING_CLIENT_FAIL: " .. tostring(err))
else
	print("SAILING_CLIENT_PASS")
end
