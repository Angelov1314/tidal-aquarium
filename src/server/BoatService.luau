--!strict
-- Server-authoritative free sailing.  Clients submit only throttle/steer
-- intent; the server owns the boat pose, collision checks and seat lifecycle.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local FishingLocation = require(shared:WaitForChild("FishingLocation"))
local Rules = require(shared:WaitForChild("SailingRules"))
local layoutModule = shared:FindFirstChild("WorldLayout")
local Layout = if layoutModule then require(layoutModule) else nil

local BoatService = {}

local started = false
local intentRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local requestRemote: RemoteFunction? = nil
local boatFolder: Folder? = nil
local dockFolder: Folder? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local playerConnections: {[Player]: {RBXScriptConnection}} = {}
local boats: {[Player]: any} = {}
local boardingCallback: ((Player, boolean, string?) -> ())? = nil

local function clock(): number
	return os.clock()
end

local function color(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	partColor: Color3,
	material: Enum.Material,
	canCollide: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = partColor
	part.Material = material
	part.Anchored = true
	part.CanCollide = canCollide ~= false
	part.CanTouch = false
	part.CanQuery = part.CanCollide
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function worldOcean(): any
	local ocean = Layout and Layout.Ocean
	if type(ocean) == "table"
		and type(ocean.minX) == "number"
		and type(ocean.maxX) == "number"
		and type(ocean.minZ) == "number"
		and type(ocean.maxZ) == "number" then
		return {
			minX = ocean.minX,
			maxX = ocean.maxX,
			minZ = ocean.minZ,
			maxZ = ocean.maxZ,
			surfaceY = if type(ocean.surfaceY) == "number" then ocean.surfaceY else 0,
		}
	end
	local maxX = 0
	for _, zone in ipairs(Config.Zones) do
		local center = zone.center or {x = 0, z = 0}
		maxX = math.max(maxX, math.abs(center.x or 0), math.abs(center.z or 0))
	end
	return {minX = -maxX - 300, maxX = maxX + 300, minZ = -maxX - 300, maxZ = maxX + 300, surfaceY = 0}
end

local function boatTuning(): any
	local tuning = Layout and Layout.Boat
	return {
		speed = if type(tuning) == "table" and type(tuning.speed) == "number" then tuning.speed else 54,
		turnSpeed = if type(tuning) == "table" and type(tuning.turnSpeed) == "number" then tuning.turnSpeed else 1.35,
		acceleration = if type(tuning) == "table" and type(tuning.acceleration) == "number" then tuning.acceleration else nil,
		drag = if type(tuning) == "table" and type(tuning.drag) == "number" then tuning.drag else nil,
	}
end

local function surfaceY(): number
	return worldOcean().surfaceY
end

local function configCenter(zoneId: number)
	local zone = Config.Zones[zoneId]
	if not zone or type(zone.center) ~= "table" then return nil end
	local x, z = zone.center.x, zone.center.z
	if type(x) ~= "number" or type(z) ~= "number" then return nil end
	return x, z
end

local function mapZones(): {any}
	local zones = {}
	for id, zone in ipairs(Config.Zones) do
		local x, z = configCenter(id)
		if x and z then
			local geometry = Layout and Layout.Zones and Layout.Zones[id]
			table.insert(zones, {
				id = id,
				name = zone.name or ("水域 " .. tostring(id)),
				x = x,
				z = z,
				shape = if type(geometry) == "table" then geometry.shape else nil,
				width = if type(geometry) == "table" then geometry.width else nil,
				depth = if type(geometry) == "table" then geometry.depth else nil,
				cost = zone.cost,
				requiredDiscoveries = zone.requiredDiscoveries,
				requiredLevel = zone.requiredLevel,
			})
		end
	end
	return zones
end

local function mapSnapshot(): any
	local ocean = worldOcean()
	return {
		zones = mapZones(),
		ocean = ocean,
		boat = boatTuning(),
	}
end

local function dockPosition(zoneId: number): Vector3?
	local x, z = configCenter(zoneId)
	if not x or not z then return nil end
	return Vector3.new(x, math.max(surfaceY() + 2.5, FishingLocation.Travel.y), z + Rules.DockOffset)
end

local function spawnPosition(zoneId: number): Vector3?
	local x, z = configCenter(zoneId)
	if not x or not z then return nil end
	return Vector3.new(x, surfaceY() + 0.7, z + Rules.SpawnOffset)
end

local function characterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then return nil, nil, nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return character, humanoid, nil
	end
	return character, humanoid, root
end

local function nearestDock(x: number, z: number): (number?, Vector3?, number)
	local bestId: number? = nil
	local bestPosition: Vector3? = nil
	local bestDistance = math.huge
	for id, _ in ipairs(Config.Zones) do
		local point = dockPosition(id)
		if point then
			local distance = Rules.distance2D(x, z, point.X, point.Z)
			if distance < bestDistance then
				bestId, bestPosition, bestDistance = id, point, distance
			end
		end
	end
	return bestId, bestPosition, bestDistance
end

local function authorizedDock(player: Player, requestedId: any): (number?, Vector3?, string?)
	local _, humanoid, root = characterParts(player)
	if not humanoid or not root then return nil, nil, "角色尚未准备好。" end
	local dockId, point, distance = nearestDock(root.Position.X, root.Position.Z)
	if not dockId or not point or distance > Rules.DockAuthorizationRadius then
		return nil, nil, "请在码头召唤免费帆船。"
	end
	if type(requestedId) == "number" and requestedId % 1 == 0 and requestedId ~= dockId then
		-- A prompt may be stale after a map rebuild.  Use the physically nearest
		-- dock rather than trusting a client-supplied zone id.
		return dockId, point, nil
	end
	return dockId, point, nil
end

local function payloadPosition(state: any): any
	if not state then return nil end
	return {x = state.x, y = surfaceY() + 1, z = state.z}
end

local function statePayload(player: Player, notice: string?, includeMap: boolean?): any
	local state = boats[player]
	local result: any = {
		active = state ~= nil,
		driving = state ~= nil and state.driver == true,
		notice = notice,
	}
	if includeMap then result.map = mapSnapshot() end
	if state then
		result.position = payloadPosition(state)
		result.heading = state.heading
		result.velocity = state.velocity
		result.throttle = state.throttle
		result.steer = state.steer
		result.boatName = state.model.Name
		result.dockId = state.dockId
	end
	return result
end

local function emit(player: Player, notice: string?)
	if stateRemote and player.Parent == Players then
		stateRemote:FireClient(player, statePayload(player, notice))
	end
end

local function callBoardingCallback(player: Player, aboard: boolean, reason: string?)
	if boardingCallback then
		pcall(boardingCallback, player, aboard, reason)
	end
end

local function disconnectList(connections: {RBXScriptConnection})
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)
end

local function destroySeatWeld(state: any)
	local seat = state.seat
	if seat then
		for _, child in ipairs(seat:GetChildren()) do
			if child:IsA("Weld") or child:IsA("WeldConstraint") or child.Name == "SeatWeld" then
				child:Destroy()
			end
		end
	end
	local character = state.character
	if character then
		for _, child in ipairs(character:GetDescendants()) do
			if child:IsA("Weld") and child.Name == "SeatWeld" then child:Destroy() end
		end
	end
end

local function detach(state: any)
	state.leaving = true
	if state.seat and state.seat.Parent then state.seat.Disabled = true end
	local humanoid = state.humanoid
	if humanoid and humanoid.Parent then
		humanoid.Sit = false
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
		if state.autoRotate ~= nil then humanoid.AutoRotate = state.autoRotate end
	end
	destroySeatWeld(state)
	state.driver = false
	state.throttle = 0
	state.steer = 0
	state.velocity = 0
end

local function prepareDetachedCharacter(player: Player, character: Model): BasePart?
	-- Let SeatWeld removal reach the physics assembly before taking ownership.
	-- Otherwise the client's old seated pose can overwrite the landing teleport.
	RunService.Heartbeat:Wait()
	local root = character:FindFirstChild("HumanoidRootPart")
	if player.Character ~= character or not root or not root:IsA("BasePart") then return nil end
	pcall(function() root:SetNetworkOwner(nil) end)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	task.delay(.35, function()
		if player.Character == character and root.Parent and not root.Anchored then
			pcall(function() root:SetNetworkOwnershipAuto() end)
		end
	end)
	return root
end

local function placeDetachedCharacter(player: Player, character: Model, target: CFrame)
	if prepareDetachedCharacter(player, character) then character:PivotTo(target) end
end

local function destroyBoat(player: Player, state: any, reason: string?)
	detach(state)
	disconnectList(state.connections)
	if state.model and state.model.Parent then state.model:Destroy() end
	boats[player] = nil
	callBoardingCallback(player, false, reason)
	emit(player, reason)
end

-- Seat.Occupant is observable a few scheduler steps before Roblox creates the
-- SeatWeld.  Treating Occupant alone as authority lets an intent arrive while
-- the character is still standing beside the boat.  Every transition into
-- driving therefore requires both signals, and the helper checks both the
-- seat and character trees because Roblox has moved the weld parent between
-- engine versions.
local function seatConfirmed(state: any): boolean
	local seat = state.seat
	local humanoid = state.humanoid
	if not seat or not seat.Parent or not humanoid or seat.Occupant ~= humanoid then return false end
	if seat:FindFirstChild("SeatWeld", true) then return true end
	local character = state.character
	return character ~= nil and character:FindFirstChild("SeatWeld", true) ~= nil
end

local function confirmBoard(state: any, reason: string): boolean
	if state.leaving or boats[state.player] ~= state or not seatConfirmed(state) then return false end
	local wasDriving = state.driver
	state.driver = true
	state.recovery = false
	local reboardPrompt = state.seat:FindFirstChild("ReboardPrompt")
	if reboardPrompt then reboardPrompt.Enabled = false end
	if not wasDriving then
		callBoardingCallback(state.player, true, reason)
		if reason == "summon" then
			emit(state.player, "已召唤免费帆船，W/S 前进后退，A/D 转向。")
		else
			emit(state.player, "已重新上船。")
		end
	end
	return true
end

local function createRecoveryFloat(state: any): BasePart?
	local model = state.model
	if not model or not model.Parent then return nil end
	local old = model:FindFirstChild("RecoveryFloat")
	if old then old:Destroy() end
	local candidates = {
		Vector3.new(14, 0, 0), Vector3.new(-14, 0, 0),
		Vector3.new(0, 0, 14), Vector3.new(0, 0, -14),
	}
	local ocean = worldOcean()
	for _, offset in ipairs(candidates) do
		local x, z = state.x + offset.X, state.z + offset.Z
		if Rules.isOceanPoint(x, z, ocean, Rules.OceanMargin + 3) then
			local pad = makePart(model, "RecoveryFloat", Vector3.new(8, .35, 8), CFrame.new(x, surfaceY() + .3, z), color(73, 194, 193), Enum.Material.Neon, true)
			pad.Transparency = .1
			pad:SetAttribute("SailingRecovery", true)
			return pad
		end
	end
	return nil
end

local function safeLeave(player: Player, reason: string): boolean
	local state = boats[player]
	if not state then return false end
	local character, humanoid, root = characterParts(player)
	if character then state.character = character end
	if humanoid then state.humanoid = humanoid end
	state.leaving = true
	detach(state)
	if root then
		local dockId, dock, distance = nearestDock(state.x, state.z)
		if dockId and dock and distance <= Rules.DockDisembarkRadius then
			disconnectList(state.connections)
			if state.model and state.model.Parent then state.model:Destroy() end
			boats[player] = nil
			local target = Vector3.new(dock.X, dock.Y, dock.Z)
			placeDetachedCharacter(player, character, CFrame.lookAt(target, target + Vector3.new(0, 0, -1)))
			callBoardingCallback(player, false, reason)
			emit(player, "已在码头安全下船。")
			return true
		end
	end
	-- Offshore exit keeps the server boat as a visible recovery float. This
	-- leaves the player standing on an anchored platform and allows reboard or
	-- returnHarbor without pretending the ocean is walkable terrain.
	local pad = createRecoveryFloat(state)
	if pad and character then
		placeDetachedCharacter(player, character, CFrame.new(pad.Position + Vector3.new(0, 3.3, 0)))
	end
	state.driver = false
	state.leaving = false
	state.recovery = true
	state.lastIntentAt = -math.huge
	state.lastIntentReceived = 0
	local reboardPrompt = state.seat:FindFirstChild("ReboardPrompt")
	if reboardPrompt then reboardPrompt.Enabled = true end
	callBoardingCallback(player, false, reason)
	emit(player, "已放下救生浮台，可重新上船或返回港湾。")
	return true
end

local function collisionParams(state: any): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignores = {state.model}
	if state.character then table.insert(ignores, state.character) end
	params.FilterDescendantsInstances = ignores
	params.IgnoreWater = true
	return params
end

local function blockedAt(state: any, x: number, z: number, delta: Vector3): boolean
	if delta.Magnitude <= 0.001 then return false end
	local params = collisionParams(state)
	local origin = state.root.CFrame
	local ok, result = pcall(function()
		return workspace:Blockcast(origin, Vector3.new(13, 4, 24), delta, params)
	end)
	if ok and result then return true end
	-- Blockcast covers side collisions. A short vertical probe catches a shore
	-- part whose collision box starts outside the hull's first sample.
	local probe = workspace:Raycast(Vector3.new(x, surfaceY() + 16, z), Vector3.new(0, -24, 0), params)
	if probe and probe.Instance and probe.Instance:IsA("BasePart") then
		if probe.Instance.Name ~= "OceanFloor" and probe.Position.Y > surfaceY() - 2 then return true end
	end
	return false
end

local function headingBlocked(state: any, x: number, z: number, heading: number): boolean
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local ignores = {state.model}
	if state.character then table.insert(ignores, state.character) end
	overlap.FilterDescendantsInstances = ignores
	overlap.MaxParts = 32
	local frame = CFrame.new(x, surfaceY() + .7, z) * CFrame.Angles(0, heading, 0)
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInBox(frame, Vector3.new(13, 4, 24), overlap)
	end)
	if not ok or type(parts) ~= "table" then return false end
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") and part.CanCollide and part.Name ~= "OceanFloor" then return true end
	end
	return false
end

local function pivotBoat(state: any)
	local position = Vector3.new(state.x, surfaceY() + .7, state.z)
	state.model:PivotTo(CFrame.new(position) * CFrame.Angles(0, state.heading, 0))
end

local function createBoat(player: Player, dockId: number): (any?, string?)
	local character, humanoid, root = characterParts(player)
	if not character or not humanoid or not root then return nil, "角色尚未准备好。" end
	local start = spawnPosition(dockId)
	if not start then return nil, "码头暂不可用。" end
	local folder = boatFolder or workspace
	local model = Instance.new("Model")
	model.Name = "SailingBoat_" .. tostring(player.UserId)
	model:SetAttribute("SailingBoat", true)
	model:SetAttribute("OwnerUserId", player.UserId)
	model.Parent = folder
	local heading = math.pi -- dock is +Z of the island, so default forward is offshore +Z
	local rootPart = makePart(model, "Hull", Vector3.new(13, 1.4, 24), CFrame.new(start) * CFrame.Angles(0, heading, 0), color(34, 88, 100), Enum.Material.WoodPlanks, true)
	rootPart:SetAttribute("SailingRoot", true)
	model.PrimaryPart = rootPart
	local deck = makePart(model, "Deck", Vector3.new(10.5, .45, 16), rootPart.CFrame * CFrame.new(0, 1, -1), color(234, 193, 112), Enum.Material.WoodPlanks, true)
	deck.CanTouch = false
	local bow = makePart(model, "Bow", Vector3.new(9, 1, 5), rootPart.CFrame * CFrame.new(0, .2, -10), color(45, 111, 120), Enum.Material.Wood, true)
	bow.Shape = Enum.PartType.Wedge
	local stern = makePart(model, "SternRail", Vector3.new(10, 2.8, .35), rootPart.CFrame * CFrame.new(0, 1.9, 8), color(24, 57, 70), Enum.Material.Wood, false)
	local seat = Instance.new("Seat")
	seat.Name = "CaptainSeat"
	seat.Size = Vector3.new(2.6, 1, 2.6)
	seat.CFrame = rootPart.CFrame * CFrame.new(0, 2.1, 1)
	seat.Color = color(242, 177, 72)
	seat.Material = Enum.Material.SmoothPlastic
	seat.Anchored = true
	seat.CanCollide = true
	seat.CanTouch = true
	seat.CanQuery = true
	seat.Parent = model
	seat:SetAttribute("SailingSeat", true)
	local mast = makePart(model, "Mast", Vector3.new(.5, 8, .5), rootPart.CFrame * CFrame.new(0, 4.8, -3), color(27, 53, 62), Enum.Material.Wood, false)
	local sail = makePart(model, "Sail", Vector3.new(.2, 6, 6), rootPart.CFrame * CFrame.new(0, 5, -3) * CFrame.Angles(0, math.pi / 2, 0), color(255, 239, 184), Enum.Material.Fabric, false)
	sail.Transparency = .12
	local title = Instance.new("BillboardGui")
	title.Name = "BoatLabel"
	title.Size = UDim2.fromOffset(200, 54)
	title.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	title.MaxDistance = 120
	title.AlwaysOnTop = false
	title.Adornee = rootPart
	title.Parent = model
	local titleText = Instance.new("TextLabel")
	titleText.BackgroundColor3 = color(20, 48, 66)
	titleText.BackgroundTransparency = .12
	titleText.BorderSizePixel = 0
	titleText.Size = UDim2.fromScale(1, 1)
	titleText.Font = Enum.Font.GothamBold
	titleText.TextColor3 = color(255, 248, 229)
	titleText.TextSize = 14
	titleText.Text = "免费帆船  ·  " .. player.DisplayName
	titleText.Parent = title
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = titleText

	local state = {
		player = player,
		model = model,
		root = rootPart,
		seat = seat,
		character = character,
		humanoid = humanoid,
		dockId = dockId,
		x = start.X,
		z = start.Z,
		heading = heading,
		velocity = 0,
		throttle = 0,
		steer = 0,
		driver = false,
		recovery = false,
		leaving = false,
		lastIntentAt = -math.huge,
		lastIntentReceived = 0,
		lastStateAt = 0,
		lastBlockedNoticeAt = -math.huge,
		boardGraceUntil = clock() + 1.5,
		autoRotate = humanoid.AutoRotate,
		connections = {},
	}
	boats[player] = state
	humanoid.AutoRotate = false
	character:PivotTo(seat.CFrame * CFrame.new(0, 2.5, 0))
	task.defer(function()
		if boats[player] ~= state or not seat.Parent then return end
		local confirmed = false
		for _ = 1, 10 do
			if boats[player] ~= state or state.leaving or not seat.Parent then return end
			seat:Sit(humanoid)
			task.wait(.1)
			if seatConfirmed(state) then
				confirmed = true
				break
			end
		end
		if not confirmed then
			destroyBoat(player, state, "座位连接失败，帆船已收回。")
			return
		end
		confirmBoard(state, "summon")
	end)

	table.insert(state.connections, seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if state.leaving or boats[player] ~= state then return end
		local occupant = seat.Occupant
		if occupant and occupant ~= humanoid then
			occupant.Sit = false
			return
		end
		if occupant == humanoid then
			-- Occupant can fire before SeatWeld exists; defer once and let the
			-- heartbeat retry while the weld is being replicated.
			task.defer(function()
				if boats[player] == state and not state.leaving then confirmBoard(state, "reboard") end
			end)
		elseif state.driver and clock() > state.boardGraceUntil then
			task.defer(function()
				if boats[player] == state and not state.leaving then safeLeave(player, "离座") end
			end)
		end
	end))
	local reboardPrompt = Instance.new("ProximityPrompt")
	reboardPrompt.Name = "ReboardPrompt"
	reboardPrompt.ActionText = "上船"
	reboardPrompt.ObjectText = "你的免费帆船"
	reboardPrompt.HoldDuration = .15
	reboardPrompt.MaxActivationDistance = 14
	reboardPrompt.RequiresLineOfSight = false
	reboardPrompt.Enabled = false
	reboardPrompt.KeyboardKeyCode = Enum.KeyCode.E
	reboardPrompt.Parent = seat
	table.insert(state.connections, reboardPrompt.Triggered:Connect(function(triggering)
		if triggering == player then BoatService.handle(player, "reboard", {}) end
	end))

	return state
end

local function reboard(player: Player): (boolean, string)
	local state = boats[player]
	if not state then return false, "你还没有帆船。" end
	local character, humanoid, root = characterParts(player)
	if not character or not humanoid or not root then return false, "角色尚未准备好。" end
	if (root.Position - state.seat.Position).Magnitude > 18 then return false, "请靠近你的帆船。" end
	if state.seat.Occupant and state.seat.Occupant ~= humanoid then return false, "驾驶席已被占用。" end
	state.character, state.humanoid = character, humanoid
	state.autoRotate = humanoid.AutoRotate
	humanoid.AutoRotate = false
	state.leaving = false
	state.boardGraceUntil = clock() + 1
	state.seat.Disabled = false
	character:PivotTo(state.seat.CFrame * CFrame.new(0, 2.5, 0))
	local confirmed = false
	for _ = 1, 10 do
		if boats[player] ~= state or state.leaving then break end
		state.seat:Sit(humanoid)
		task.wait(.1)
		if seatConfirmed(state) then
			confirmed = true
			break
		end
	end
	if not confirmed then
		destroyBoat(player, state, "座位连接失败，帆船已收回。")
		return false, "座位连接失败，请重新召唤帆船。"
	end
	confirmBoard(state, "reboard")
	local pad = state.model:FindFirstChild("RecoveryFloat")
	if pad then pad:Destroy() end
	return true, "已重新上船。"
end

function BoatService.handle(player: Player, action: any, payload: any): any
	if not player or player.Parent ~= Players then return {ok = false, message = "玩家状态无效。"} end
	if type(action) ~= "string" or #action > 32 then return {ok = false, message = "请求格式无效。"} end
	payload = if type(payload) == "table" then payload else {}
	if action == "snapshot" or action == "map" then
		return {ok = true, state = statePayload(player, nil, true)}
	end
	if action == "summon" then
		if boats[player] then return {ok = false, message = "你已经有一艘帆船。", state = statePayload(player, nil, true)} end
		local dockId, _, reason = authorizedDock(player, payload.zone)
		if not dockId then return {ok = false, message = reason or "请在码头召唤帆船。", state = statePayload(player, nil, true)} end
		local state, createReason = createBoat(player, dockId)
		if not state then return {ok = false, message = createReason or "帆船暂不可用。", state = statePayload(player, nil, true)} end
		return {ok = true, message = "已召唤免费帆船。", state = statePayload(player, nil, true)}
	end
	if action == "reboard" then
		local ok, message = reboard(player)
		return {ok = ok, message = message, state = statePayload(player)}
	end
	if action == "leave" then
		if not boats[player] then return {ok = false, message = "你当前不在帆船上。", state = statePayload(player)} end
		local ok = safeLeave(player, "leave")
		return {ok = ok, message = if ok then "已安全下船。" else "暂时无法下船。", state = statePayload(player)}
	end
	if action == "returnHarbor" then
		local state = boats[player]
		if not state then return {ok = false, message = "你当前没有需要返航的帆船。", state = statePayload(player)} end
		local character = player.Character
		local dock = dockPosition(1)
		if not character or not dock then return {ok = false, message = "港湾暂不可用。", state = statePayload(player)} end
		destroyBoat(player, state, "returnHarbor")
		placeDetachedCharacter(player, character, CFrame.lookAt(dock, dock + Vector3.new(0, 0, -1)))
		return {ok = true, message = "已返回晨湾港口。", state = statePayload(player)}
	end
	return {ok = false, message = "不支持的航行操作。", state = statePayload(player)}
end

local function onRequest(player: Player, action: any, payload: any): any
	local state = boats[player]
	local now = clock()
	local last = state and state.lastRequestAt or (player:GetAttribute("SailingLastRequest") or -math.huge)
	local minimum = if action == "snapshot" or action == "map" then .06 else .14
	if now - last < minimum then return {ok = false, message = "操作过快，请稍后。", state = statePayload(player)} end
	if state then state.lastRequestAt = now else player:SetAttribute("SailingLastRequest", now) end
	return BoatService.handle(player, action, payload)
end

local function onIntent(player: Player, payload: any)
	local state = boats[player]
	if not state or not state.driver or state.leaving then return end
	local now = clock()
	if now - state.lastIntentAt < Rules.IntentInterval then return end
	local intent = Rules.normalizeIntent(payload)
	if not intent then
		state.throttle, state.steer = 0, 0
		return
	end
	local character, humanoid, root = characterParts(player)
	if not character or not humanoid or not root or humanoid ~= state.humanoid then
		destroyBoat(player, state, "角色失效")
		return
	end
	if (root.Position - state.seat.Position).Magnitude > 16 then
		safeLeave(player, "驾驶席距离异常")
		return
	end
	if not seatConfirmed(state) then
		state.driver = false
		state.throttle, state.steer = 0, 0
		return
	end
	if not state.driver then confirmBoard(state, "reboard") end
	state.throttle = intent.throttle
	state.steer = intent.steer
	state.lastIntentAt = now
	state.lastIntentReceived = now
end

local function advanceBoat(state: any, deltaTime: number)
	if not state.driver or state.leaving then return end
	local now = clock()
	if now - state.lastIntentReceived > Rules.MaxIntentAge then
		state.throttle, state.steer = 0, 0
	end
	local nextPose = Rules.integrate(state.x, state.z, state.heading, state.velocity, {
		throttle = state.throttle,
		steer = state.steer,
	}, deltaTime, boatTuning())
	local ocean = worldOcean()
	local nextX, nextZ = Rules.clampOceanPoint(nextPose.x, nextPose.z, ocean, Rules.OceanMargin)
	local dx, dz = nextX - state.x, nextZ - state.z
	-- Check the complete candidate pose.  Checking the current position with
	-- the new heading only catches stationary rotations; checking nextX/nextZ
	-- also prevents a turn plus forward step from crossing a shore corner.
	local turnBlocked = headingBlocked(state, nextX, nextZ, nextPose.heading)
	if math.abs(dx) > .001 or math.abs(dz) > .001 then
		if turnBlocked or blockedAt(state, nextX, nextZ, Vector3.new(dx, 0, dz)) then
			state.velocity = 0
			state.throttle = 0
			if now - state.lastBlockedNoticeAt > 1.2 then
				state.lastBlockedNoticeAt = now
				emit(state.player, "前方有岛岸或码头，已安全减速。")
			end
		else
			state.x, state.z = nextX, nextZ
			state.heading, state.velocity = nextPose.heading, nextPose.velocity
			pivotBoat(state)
		end
	elseif turnBlocked then
		state.velocity = 0
		state.throttle = 0
		if now - state.lastBlockedNoticeAt > 1.2 then
			state.lastBlockedNoticeAt = now
			emit(state.player, "转向空间被岸线占用，请驶回开阔水面。")
		end
	else
		state.heading = nextPose.heading
		state.velocity = nextPose.velocity
		pivotBoat(state)
	end
end

local function onHeartbeat(deltaTime: number)
	local dt = math.min(math.max(deltaTime, 0), Rules.MaxDeltaTime)
	for player, state in pairs(boats) do
		if player.Parent ~= Players or not state.model.Parent then
			destroyBoat(player, state, "生命周期清理")
			continue
		end
		local character, humanoid, root = characterParts(player)
		if not character or not humanoid or not root then
			destroyBoat(player, state, "角色失效")
			continue
		end
		state.character, state.humanoid = character, humanoid
		if state.driver and not seatConfirmed(state) then
			-- A confirmed driver may lose its weld between Heartbeats (manual
			-- jump, respawn, or a physics correction). Stop authority first so a
			-- stale throttle can never move an unoccupied boat.
			state.driver = false
			state.throttle, state.steer = 0, 0
			state.lastIntentReceived = 0
			safeLeave(player, "离座")
		elseif not state.driver and seatConfirmed(state) then
			confirmBoard(state, "reboard")
			advanceBoat(state, dt)
		else
			advanceBoat(state, dt)
		end
		state.lastStateAt += dt
		if state.lastStateAt >= .12 then
			state.lastStateAt = 0
			emit(player)
		end
	end
end

local function createDockPrompts()
	if dockFolder and dockFolder.Parent then return end
	dockFolder = Instance.new("Folder")
	dockFolder.Name = "SailingDocks"
	dockFolder.Parent = workspace
	for id, zone in ipairs(Config.Zones) do
		local dock = dockPosition(id)
		if dock then
			local marker = makePart(dockFolder, "Dock_" .. tostring(id), Vector3.new(8, .5, 8), CFrame.new(dock), color(0, 0, 0), Enum.Material.SmoothPlastic, false)
			marker.Transparency = 1
			marker.CanQuery = false
			marker:SetAttribute("SailingDock", true)
			marker:SetAttribute("Zone", id)
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "SummonBoatPrompt"
			prompt.ActionText = "召唤免费帆船"
			prompt.ObjectText = (zone.name or ("水域 " .. tostring(id))) .. "码头"
			prompt.HoldDuration = .2
			prompt.MaxActivationDistance = Rules.DockAuthorizationRadius
			prompt.RequiresLineOfSight = false
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.Parent = marker
			prompt.Triggered:Connect(function(player)
				BoatService.handle(player, "summon", {zone = id})
			end)
		end
	end
end

local function bindPlayer(player: Player)
	if playerConnections[player] then return end
	local connections = {}
	playerConnections[player] = connections
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		local state = boats[player]
		if state and state.character == character then destroyBoat(player, state, "角色重生") end
	end))
	table.insert(connections, player.AncestryChanged:Connect(function(_, parent)
		if not parent and boats[player] then destroyBoat(player, boats[player], "玩家离开") end
	end))
end

function BoatService.setBoardingCallback(callback: ((Player, boolean, string?) -> ())?)
	boardingCallback = callback
end

function BoatService.getState(player: Player): any?
	return boats[player]
end

function BoatService.getSnapshot(player: Player): any
	return statePayload(player)
end

function BoatService.release(player: Player, reason: string?): boolean
	local state = boats[player]
	if not state then return false end
	destroyBoat(player, state, reason or "release")
	-- FishingService teleports immediately after release for both quick travel
	-- and aquarium visits, so finish the ownership handoff before returning.
	if player.Parent == Players and state.character and player.Character == state.character then
		prepareDetachedCharacter(player, state.character)
	end
	return true
end

function BoatService.start()
	if started then return end
	started = true
	boatFolder = workspace:FindFirstChild("SailingBoats") :: Folder?
	if not boatFolder then
		boatFolder = Instance.new("Folder")
		boatFolder.Name = "SailingBoats"
		boatFolder.Parent = workspace
	end
	local remotes = ReplicatedStorage:FindFirstChild("BoatRemotes") :: Folder?
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "BoatRemotes"
		remotes.Parent = ReplicatedStorage
	end
	intentRemote = remotes:FindFirstChild("Intent") :: RemoteEvent?
	if not intentRemote then intentRemote = Instance.new("RemoteEvent"); intentRemote.Name = "Intent"; intentRemote.Parent = remotes end
	stateRemote = remotes:FindFirstChild("State") :: RemoteEvent?
	if not stateRemote then stateRemote = Instance.new("RemoteEvent"); stateRemote.Name = "State"; stateRemote.Parent = remotes end
	requestRemote = remotes:FindFirstChild("Request") :: RemoteFunction?
	if not requestRemote then requestRemote = Instance.new("RemoteFunction"); requestRemote.Name = "Request"; requestRemote.Parent = remotes end
	intentRemote.OnServerEvent:Connect(onIntent)
	requestRemote.OnServerInvoke = onRequest
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		if boats[player] then destroyBoat(player, boats[player], "玩家离开") end
		if playerConnections[player] then disconnectList(playerConnections[player]); playerConnections[player] = nil end
	end)
	for _, player in ipairs(Players:GetPlayers()) do bindPlayer(player) end
	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	-- World.build creates its folder before the final island is ready. Wait for
	-- the last zone model when possible, but keep a bounded fallback so the
	-- prompts still work in a small Studio fixture with no world builder.
	task.spawn(function()
		local deadline = clock() + 30
		while started and clock() < deadline do
			local world = workspace:FindFirstChild("FishingWorld")
			if world and (world:GetAttribute("Ready") == true or world:FindFirstChild("Zone" .. tostring(#Config.Zones))) then break end
			task.wait(.25)
		end
		if started then createDockPrompts() end
	end)
end

return BoatService
