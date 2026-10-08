-- QA-only runtime lifecycle smoke. It verifies two real death/respawn cycles,
-- including the no-Character snapshot window, without accessing main.client
-- closures or adding a production input/economy path.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

local function waitUntil(predicate, timeout, message)
	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		local ok, result = pcall(predicate)
		if ok and result then return end
		RunService.Heartbeat:Wait()
	end
	error(message or "lifecycle condition timed out", 2)
end

local function fishingGui(): ScreenGui
	local candidate = playerGui:FindFirstChild("FishingAquariumUI")
	expect(candidate and candidate:IsA("ScreenGui"), "FishingAquariumUI missing during lifecycle smoke")
	return candidate :: ScreenGui
end

local function currentCharacter(timeout: number, label: string): Model
	waitUntil(function() return player.Character ~= nil end, timeout, label)
	local character = player.Character
	expect(character ~= nil, label)
	return character :: Model
end

local function waitForReady(): RemoteEvent
	expect(script.Parent:FindFirstChild("MainLifecycleSmoke") == script,
		"MainLifecycleSmoke must be the isolated QA sibling")
	local remote = waitForChildBounded(ReplicatedStorage, "MainLifecycleQA", 30, "MainLifecycleQA did not become ready")
	expect(remote:IsA("RemoteEvent"), "MainLifecycleQA is not a RemoteEvent")
	local qaRemote = remote :: RemoteEvent
	waitUntil(function()
		local gui = playerGui:FindFirstChild("FishingAquariumUI")
		local bridge = gui and gui:FindFirstChild("OpenPage", true)
		return player:GetAttribute("MainLifecycleQAReady") == true
			and gui ~= nil and gui:IsA("ScreenGui")
			and bridge ~= nil and bridge:IsA("BindableEvent")
			and gui.Enabled
	end, 30, "main client GUI/bridge/server readiness did not settle")
	return qaRemote
end

local function openBackpack(gui: ScreenGui)
	local bridge = gui:FindFirstChild("OpenPage", true)
	expect(bridge and bridge:IsA("BindableEvent"), "OpenPage bridge missing during lifecycle smoke")
	local pageBridge = bridge :: BindableEvent
	pageBridge:Fire("背包")
	waitUntil(function()
		local current = fishingGui()
		local panel = current:FindFirstChild("ContentPanel", true)
		return current.Enabled and current:GetAttribute("PanelOpen") == true
			and current:GetAttribute("ActiveTab") == "背包"
			and panel and panel:IsA("GuiObject") and panel.Visible
	end, 5, "backpack did not open before lifecycle death")
end

local function waitForRemovalSnapshot(qaRemote: RemoteEvent, previous: Model, expectedDeath: number, expectedMarker: number): Model
	local removingObserved = false
	local removalConnection = player.CharacterRemoving:Connect(function(character)
		if character == previous then
			removingObserved = true
		end
	end)
	qaRemote:FireServer("kill")
	-- Death cleanup is a separate phase.  This assertion runs while the dead
	-- character is still current, so a permanently-false Humanoid.Died guard
	-- cannot be hidden by CharacterRemoving/CharacterAdded recovery handlers.
	waitUntil(function()
		local gui = fishingGui()
		return player.Character == previous
			and gui:GetAttribute("LifecycleDiedCount") ~= nil
			and (gui:GetAttribute("LifecycleDiedCount") :: number) >= expectedDeath
			and gui:GetAttribute("PanelOpen") == false
			and gui:GetAttribute("ActiveTab") == "钓鱼"
	end, 8, "production Humanoid.Died cleanup did not run before removal")
	qaRemote:FireServer("removeCharacter")
	waitUntil(function() return removingObserved and player.Character == nil end, 12,
		"explicit CharacterRemoving did not enter the held no-character phase")
	removalConnection:Disconnect()
	local phaseGui = fishingGui()
	phaseGui:SetAttribute("LifecycleSnapshotAppliedMarker", nil)
	phaseGui:SetAttribute("LifecycleSnapshotAppliedWhileNoCharacter", nil)
	phaseGui:SetAttribute("LifecycleAppliedZone", nil)
	phaseGui:SetAttribute("LifecycleAppliedFishCount", nil)
	phaseGui:SetAttribute("LifecycleAppliedCoins", nil)
	phaseGui:SetAttribute("LifecycleAppliedFishing", nil)
	qaRemote:FireServer("noCharacter")

	-- The marker is written by main.client only after setSnapshot and render;
	-- this extra bit proves that application happened while Character was nil.
	waitUntil(function()
		local gui = fishingGui()
		local marker = gui:GetAttribute("LifecycleSnapshotAppliedMarker")
		local expectedRemoteMarker = qaRemote:GetAttribute("LifecycleExpectedMarker")
			local expectedZone = qaRemote:GetAttribute("LifecycleExpectedZone")
			local expectedFishCount = qaRemote:GetAttribute("LifecycleExpectedFishCount")
			local expectedCoins = qaRemote:GetAttribute("LifecycleExpectedCoins")
			local expectedFishing = qaRemote:GetAttribute("LifecycleExpectedFishing")
			return qaRemote:GetAttribute("LifecycleExpectedValid") == true
				and type(expectedRemoteMarker) == "number"
				and type(expectedZone) == "number"
				and type(expectedFishCount) == "number" and expectedFishCount >= 0
				and type(expectedCoins) == "number"
				and type(expectedFishing) == "boolean"
				and type(marker) == "number" and marker == expectedMarker and marker == expectedRemoteMarker
				and gui:GetAttribute("LifecycleSnapshotAppliedWhileNoCharacter") == true
			and gui:GetAttribute("LifecycleAppliedZone") == expectedZone
			and gui:GetAttribute("LifecycleAppliedFishCount") == expectedFishCount
			and gui:GetAttribute("LifecycleAppliedCoins") == expectedCoins
			and gui:GetAttribute("LifecycleAppliedFishing") == expectedFishing
	end, 8, "full snapshot was not applied with normal fields during no-character phase")

	local nextCharacter: Model? = nil
	local addedConnection = player.CharacterAdded:Connect(function(character) nextCharacter = character end)
	qaRemote:FireServer("resume", expectedMarker)
	waitUntil(function() return nextCharacter ~= nil and nextCharacter ~= previous end, 12,
		"server did not resume the held character phase")
	addedConnection:Disconnect()
	local character = nextCharacter :: Model
	expect(character:WaitForChild("Humanoid", 5) ~= nil, "replacement character Humanoid did not become ready")
	return character
end

local function assertRecovered(label: string, expectedDeath: number)
	local gui = fishingGui()
	expect(gui.Enabled, label .. ": FishingAquariumUI is disabled")
	expect(gui:GetAttribute("PanelOpen") == false, label .. ": stale panel remains open")
	expect(gui:GetAttribute("ActiveTab") == "钓鱼", label .. ": ActiveTab did not return to fishing")
	local diedCount = gui:GetAttribute("LifecycleDiedCount")
	expect(type(diedCount) == "number" and diedCount >= expectedDeath,
		label .. ": production death cleanup marker missing")
	local count = 0
	for _, child in playerGui:GetChildren() do
		if child.Name == "FishingAquariumUI" then count += 1 end
	end
	expect(count == 1, label .. ": GUI replacement left duplicate FishingAquariumUI instances")
end

local function run()
	expect(RunService:IsStudio(), "MainLifecycleSmoke must run in Studio")
	local qaRemote = waitForReady()
	local gui = fishingGui()
	local character = currentCharacter(12, "initial character did not become ready")
	expect(character:WaitForChild("Humanoid", 5) ~= nil, "initial character Humanoid did not become ready")
	openBackpack(gui)
	character = waitForRemovalSnapshot(qaRemote, character, 1, 1)
	waitUntil(function() return player.Character == character end, 3, "first replacement character was not current")
	assertRecovered("after first death/respawn", 1)

	-- Re-open on the new character before killing it. This catches a listener
	-- that was retained from the old character or never rebound.
	openBackpack(fishingGui())
	local secondCharacter = waitForRemovalSnapshot(qaRemote, character, 2, 2)
	waitUntil(function() return player.Character == secondCharacter end, 3, "second replacement character was not current")
	assertRecovered("after second death/respawn", 2)
	print("MAIN_LIFECYCLE_PASS: Died-before-Removing, no-character snapshot apply, held respawn, two-cycle panel recovery and GUI singleton")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then warn("MAIN_LIFECYCLE_FAIL: " .. tostring(err)) end
