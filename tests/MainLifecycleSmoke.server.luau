-- QA-only server driver for the main client character lifecycle smoke.
-- This file is mapped only by mainlifecycleqa.project.json and is never part
-- of the playable place. It holds respawn until the client confirms that the
-- real full snapshot was applied while no Character existed.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Do not let Roblox auto-respawn between client removal and snapshot ack. The
-- fixture explicitly resumes each bounded phase.
Players.CharacterAutoLoads = false

local function waitForChildBounded(parent, name, timeout, label)
	local deadline = os.clock() + (timeout or 30)
	local candidate = parent:FindFirstChild(name)
	while candidate == nil and os.clock() < deadline do
		task.wait(.1)
		candidate = parent:FindFirstChild(name)
	end
	if candidate == nil then error(label or (name .. " did not become ready"), 2) end
	return candidate
end

local remote = ReplicatedStorage:FindFirstChild("MainLifecycleQA")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "MainLifecycleQA"
	remote.Parent = ReplicatedStorage
end
if not remote:IsA("RemoteEvent") then error("MainLifecycleQA must be a RemoteEvent", 2) end

local serverScript = waitForChildBounded(ServerScriptService, "FishingServer", 30, "FishingServer Script container did not become ready")
if not serverScript:IsA("Script") then error("FishingServer must be a Script container", 2) end
local fishingServiceModule = waitForChildBounded(serverScript, "FishingService", 30, "FishingService module did not become ready")
if not fishingServiceModule:IsA("ModuleScript") then error("FishingService must be a ModuleScript", 2) end
local fishingService = require(fishingServiceModule)
local fishingRemotes = waitForChildBounded(ReplicatedStorage, "FishingRemotes", 30, "FishingRemotes folder did not become ready")
if not fishingRemotes:IsA("Folder") then error("FishingRemotes must be a Folder", 2) end
local stateRemote = waitForChildBounded(fishingRemotes, "State", 15, "FishingRemotes.State did not become ready")
if not stateRemote:IsA("RemoteEvent") then error("FishingRemotes.State must be a RemoteEvent", 2) end
local lifecycleMarker = 0
local removalMarkers: {[Player]: number} = {}
local pendingRespawns: {[Player]: Model} = {}
local boundPlayers: {[Player]: boolean} = {}
local qaEpochs: {[Player]: string} = {}

local function qaSnapshot(player: Player): any
	local epoch = qaEpochs[player]
	if not epoch then
		local protocol = fishingService.getProtocolState(player)
		epoch = protocol and protocol.stateEpoch
		if type(epoch) ~= "string" then return {ok = false, message = "QA protocol epoch unavailable"} end
		qaEpochs[player] = epoch
	end
	local response = fishingService.handle(player, "snapshot", {stateEpoch = epoch})
	if type(response) == "table" and type(response.state) == "table" and type(response.state.stateEpoch) == "string" then qaEpochs[player] = response.state.stateEpoch end
	return response
end

local function publishSnapshotDuringRemoval(player: Player)
	lifecycleMarker += 1
	local response = qaSnapshot(player)
	if type(response) == "table" and type(response.state) == "table" then
		-- The extra field is QA-only and is attached to the returned snapshot
		-- clone; it never changes the authoritative profile/economy.
		response.state.lifecycleQaMarker = lifecycleMarker
		removalMarkers[player] = lifecycleMarker
		-- Publish the expected values through the isolated QA RemoteEvent.  The
		-- client compares these with attributes written after its real
		-- setSnapshot/render path, so a marker copied from a fixture input cannot
		-- satisfy the no-character assertion.
		remote:SetAttribute("LifecycleExpectedMarker", lifecycleMarker)
		local zone = response.state.currentZone
		local zoneValid = zone == nil or type(zone) == "number"
		local expectedZone = if type(zone) == "number" then zone else -1
		local fishValid = type(response.state.fish) == "table"
		local expectedFishCount = if fishValid then #response.state.fish else -1
		local coinsValid = type(response.state.coins) == "number"
		local expectedCoins = if coinsValid then response.state.coins else -1
		local fishingValid = type(response.state.fishing) == "boolean"
		local expectedFishing = if fishingValid then response.state.fishing else false
		remote:SetAttribute("LifecycleExpectedZone", expectedZone)
		remote:SetAttribute("LifecycleExpectedFishCount", expectedFishCount)
		remote:SetAttribute("LifecycleExpectedCoins", expectedCoins)
		remote:SetAttribute("LifecycleExpectedFishing", expectedFishing)
		remote:SetAttribute("LifecycleExpectedValid", zoneValid and fishValid and coinsValid and fishingValid)
		stateRemote:FireClient(player, response.state)
	end
end

local function bindRemovalSnapshot(player: Player)
	if boundPlayers[player] then return end
	boundPlayers[player] = true
	player.CharacterRemoving:Connect(function(character)
		pendingRespawns[player] = character
	end)
	player.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			boundPlayers[player] = nil
			pendingRespawns[player] = nil
			removalMarkers[player] = nil
			qaEpochs[player] = nil
		end
	end)
end

local function waitForFishingRecord(player: Player): boolean
	for _ = 1, 80 do
		local ok, response = pcall(function() return qaSnapshot(player) end)
		if ok and type(response) == "table" and type(response.state) == "table" then return true end
		task.wait(.25)
	end
	return false
end

local function ensureCharacter(player: Player): boolean
	if player.Character ~= nil then return true end
	-- Connect before LoadCharacter so a synchronous CharacterAdded cannot be
	-- missed by the fixture startup handshake.
	local added: Model? = nil
	local addedConnection = player.CharacterAdded:Connect(function(character)
		added = character
	end)
	local ok, err = pcall(function() player:LoadCharacter() end)
	if not ok then warn("MAIN_LIFECYCLE_SERVER_LOAD_FAIL: " .. player.Name .. " " .. tostring(err)) end
	local deadline = os.clock() + 12
	while player.Parent and player.Character == nil and os.clock() < deadline do
		task.wait()
	end
	addedConnection:Disconnect()
	return player.Character ~= nil and (added == nil or player.Character == added)
end

local function preparePlayer(player: Player)
	bindRemovalSnapshot(player)
	local characterReady = ensureCharacter(player)
	local ready = characterReady and stateRemote ~= nil and waitForFishingRecord(player)
	player:SetAttribute("MainLifecycleQAReady", ready)
	print("MAIN_LIFECYCLE_SERVER_READY: " .. player.Name .. " ready=" .. tostring(ready))
end

local function removeCharacterForQA(player: Player)
	local character = player.Character
	if not character then return end
	pendingRespawns[player] = character
	-- Health=0 is deliberately a separate phase.  The client must first prove
	-- that production Humanoid.Died cleanup ran; only then do we create the
	-- explicit no-character window used by the snapshot assertion.
	local ok, err = pcall(function() character:Destroy() end)
	if not ok then warn("MAIN_LIFECYCLE_SERVER_REMOVE_FAIL: " .. player.Name .. " " .. tostring(err)) end
	if player.Character == character then
		pcall(function() player.Character = nil end)
	end
end

remote.OnServerEvent:Connect(function(player, command, marker)
	if command == "kill" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then humanoid.Health = 0 end
	elseif command == "removeCharacter" then
		if player.Parent and player.Character ~= nil then removeCharacterForQA(player) end
	elseif command == "noCharacter" then
		-- Send the authoritative snapshot only after the client has observed the
		-- no-character phase. This removes transport-order ambiguity while still
		-- keeping the player in the server CharacterRemoving hold.
		if player.Parent and player.Character == nil and pendingRespawns[player] ~= nil then
			publishSnapshotDuringRemoval(player)
		end
	elseif command == "resume" then
		local expected = tonumber(marker)
		if player.Parent and player.Character == nil and pendingRespawns[player] ~= nil
			and expected ~= nil and removalMarkers[player] == expected then
			pendingRespawns[player] = nil
			player:LoadCharacter()
		end
	end
end)

Players.PlayerAdded:Connect(function(player)
	task.spawn(preparePlayer, player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(preparePlayer, player)
end
