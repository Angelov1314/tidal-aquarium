-- Server-owned held-fish presentation.  The snapshot is authoritative: this
-- module never accepts client geometry, names, weights, rarity or level.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))

local Showcase = {}
local states = {}

local MODEL_NAME = "OpenCloudFishShowcase"
local PLAQUE_NAME = "ShowcasePlaque"
local HOLD_OFFSET = CFrame.new(1.35, 0.35, -1.15) * CFrame.Angles(0, math.rad(90), math.rad(-8))

local function firstChild(parent, names)
	for _, name in ipairs(names) do
		local child = parent and parent:FindFirstChild(name)
		if child then return child end
	end
	return nil
end

local function findFish(snapshot, id)
	if type(snapshot) ~= "table" or type(id) ~= "string" then return nil end
	for _, fish in ipairs(snapshot.fish or {}) do
		if type(fish) == "table" and fish.id == id then return fish end
	end
	-- Economy snapshots keep fish in `fish`; this narrow fallback accepts an
	-- item projection without trusting any fields that are not in Config.
	for _, item in ipairs(snapshot.items or {}) do
		if type(item) == "table" and item.id == id and item.species then return item end
	end
	return nil
end

local function restorePose(state)
	for _, entry in ipairs(state.pose or {}) do
		if entry.joint and entry.joint.Parent then entry.joint.C0 = entry.c0 end
	end
	state.pose = {}
end

local function clearVisual(state)
	if not state then return end
	if state.model and state.model.Parent then state.model:Destroy() end
	state.model = nil
	state.fishId = nil
	restorePose(state)
end

local function presentationScale(fish)
	local grams = tonumber(fish and fish.weightGrams) or 0
	local weightScale = if grams > 0 then 0.78 + math.clamp(math.log(math.max(grams, 1)) / math.log(10000), 0, 1) * 0.48 else 0.92
	local sizeScale = ({[1] = 0.84, [2] = 1, [3] = 1.12, [4] = 1.28})[tonumber(fish and fish.size) or 2] or 1
	return math.clamp(weightScale * sizeScale, 0.65, 1.35)
end

local function setPartSafety(model)
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") then
			object.Anchored = false
			object.Massless = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.CastShadow = true
		elseif object:IsA("LuaSourceContainer") then
			object:Destroy()
		end
	end
end

local function weldParts(model, torso)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then return nil end
	model.PrimaryPart = primary
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") and object ~= primary then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "ShowcasePartWeld"
			weld.Part0 = primary
			weld.Part1 = object
			weld.Parent = object
		end
	end
	local torsoWeld = Instance.new("WeldConstraint")
	torsoWeld.Name = "ShowcaseTorsoWeld"
	torsoWeld.Part0 = torso
	torsoWeld.Part1 = primary
	torsoWeld.Parent = primary
	return primary
end

local function applyCarryPose(state, torso)
	local joints = {
		{names = {LeftShoulder = true, ["Left Shoulder"] = true}, angle = math.rad(-18), roll = math.rad(-12)},
		{names = {RightShoulder = true, ["Right Shoulder"] = true}, angle = math.rad(-18), roll = math.rad(12)},
	}
	for _, spec in ipairs(joints) do
		local joint
		-- R6 places shoulders directly under Torso; R15 may expose them under
		-- a nested rig container. Match both by name and torso/upper-arm link so
		-- an unrelated Motor6D cannot be posed accidentally.
		for _, object in ipairs(torso.Parent:GetDescendants()) do
			if object:IsA("Motor6D") and spec.names[object.Name]
				and (object.Part0 == torso or object.Part1 == torso) then
				joint = object
				break
			end
		end
		if joint then
			table.insert(state.pose, {joint = joint, c0 = joint.C0})
			joint.C0 = joint.C0 * CFrame.Angles(spec.angle, 0, spec.roll)
		end
	end
end

local function plaque(primary, species, fish)
	local rarity = Config.Rarities[tonumber(species.rarity) or 1]
	local rarityName = rarity and rarity.name or ("品质 " .. tostring(species.rarity or "?"))
	local grams = math.max(0, math.floor(tonumber(fish.weightGrams) or 0))
	local level = math.max(1, math.floor(tonumber(fish.level) or 1))
	local gui = Instance.new("BillboardGui")
	gui.Name = PLAQUE_NAME
	gui.Adornee = primary
	gui.Size = UDim2.fromOffset(220, 76)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 70
	gui.AlwaysOnTop = false
	gui.Parent = primary
	local frame = Instance.new("Frame")
	frame.Name = "Background"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(22, 45, 56)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local text = Instance.new("TextLabel")
	text.Name = "Details"
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, -12, 1, -8)
	text.Position = UDim2.fromOffset(6, 4)
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = Color3.fromRGB(255, 246, 222)
	text.TextSize = 14
	text.TextWrapped = true
	text.Text = string.format("%s\n%d g  ·  %s  ·  Lv.%d", tostring(species.name or species.id), grams, rarityName, level)
	text.Parent = frame
end

local function ensureState(player)
	local state = states[player]
	if state then return state end
	state = {model = nil, fishId = nil, character = nil, pose = {}}
	states[player] = state
	state.characterAdded = player.CharacterAdded:Connect(function(character)
		-- Selection remains in the server snapshot.  The visual is rebuilt by the
		-- next authoritative snapshot after respawn, never from client input.
		if states[player] == state then
			clearVisual(state)
			state.character = character
		end
	end)
	return state
end

local function buildVisual(state, player, species, fish, character)
	local torso = firstChild(character, {"UpperTorso", "Torso", "HumanoidRootPart"})
	if not torso or not torso:IsA("BasePart") then return false end
	local model = ArtRenderer.fish(character, species, fish, torso.Position, presentationScale(fish))
	if not model then return false end
	model.Name = MODEL_NAME
	model:SetAttribute("ShowcaseFishId", fish.id)
	model:SetAttribute("FishSpecies", fish.species)
	model:SetAttribute("FishName", species.name)
	model:SetAttribute("WeightGrams", math.max(0, math.floor(tonumber(fish.weightGrams) or 0)))
	model:SetAttribute("FishRarity", species.rarity)
	model:SetAttribute("FishLevel", math.max(1, math.floor(tonumber(fish.level) or 1)))
	model:SetAttribute("ServerOwned", true)
	setPartSafety(model)
	model:PivotTo(torso.CFrame * HOLD_OFFSET)
	local primary = weldParts(model, torso)
	if not primary then model:Destroy(); return false end
	applyCarryPose(state, torso)
	plaque(primary, species, fish)
	state.model = model
	state.fishId = fish.id
	state.character = character
	return true
end

function Showcase.update(player, snapshot)
	if not player or type(snapshot) ~= "table" then return false end
	local state = ensureState(player)
	local character = player.Character
	if state.character ~= character then
		clearVisual(state)
		state.character = character
	end
	-- Fishing keeps the selected ID in the authoritative snapshot so its
	-- bounded trait bonus can remain active.  It only hides the held model.
	if snapshot.fishing == true then
		clearVisual(state)
		return true
	end
	local fishId = snapshot.showcaseFishId
	local fish = findFish(snapshot, fishId)
	local species = fish and Config.SpeciesById[fish.species]
	if not fishId or not fish or fish.placed == true or not species or not character then
		clearVisual(state)
		return true
	end
	if state.model and state.model.Parent == character and state.fishId == fishId then return true end
	clearVisual(state)
	return buildVisual(state, player, species, fish, character)
end

function Showcase.remove(player)
	local state = states[player]
	if not state then return end
	clearVisual(state)
	if state.characterAdded then state.characterAdded:Disconnect() end
	states[player] = nil
end

return Showcase
