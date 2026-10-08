--!nonstrict
-- One authored harbor NPC with server-owned navigation and animation state.
-- The service is deliberately fail-closed: until Studio supplies a validated
-- template and its authored Animation instances, the original static NPC is
-- left in place and the rest of FishingService continues to start.
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local NPCConfig = require(shared:WaitForChild("NPCConfig"))
local WorldLayout = require(shared:WaitForChild("WorldLayout"))

local NPCService = {}
local started = false
local startupRunning = false
local lifecycleGeneration = 0
local heartbeatConnection = nil
local activeState = nil

local GROUNDING_TOLERANCE = 0.01

local function status(message)
	warn("[NPCService] " .. message)
end

local function findRoot(model)
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
	for _, name in ipairs({"HumanoidRootPart", "RootPart", "Root", "LowerTorso"}) do
		local candidate = model:FindFirstChild(name, true)
		if candidate and candidate:IsA("BasePart") then return candidate end
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("RootPart") == true then
			return descendant
		end
	end
	return nil
end

local function findAnimation(model, name)
	local animations = model:FindFirstChild("Animations")
	local candidate = animations and animations:FindFirstChild(name, true)
	if candidate and candidate:IsA("Animation") then return candidate end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Animation") and descendant.Name == name then return descendant end
	end
	return nil
end

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and NPCConfig.isFiniteNumber(value.X)
		and NPCConfig.isFiniteNumber(value.Y)
		and NPCConfig.isFiniteNumber(value.Z)
end

local function validateSingleAssembly(root, parts)
	local ok, connectedParts = pcall(function()
		return root:GetConnectedParts(true)
	end)
	if not ok or type(connectedParts) ~= "table" then
		return false, "root assembly could not be inspected"
	end
	local connected = {[root] = true}
	for _, connectedPart in ipairs(connectedParts) do
		connected[connectedPart] = true
	end
	for _, part in ipairs(parts) do
		if not connected[part] then
			return false, "template has a disconnected body part: " .. part:GetFullName()
		end
	end
	return true
end

local function validateTemplate(template)
	if not template or not template:IsA("Model") then return nil, "template is not a Model" end
	local root = findRoot(template)
	if not root then return nil, "template has no PrimaryPart or root part" end
	local humanoid = template:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil, "template has no Humanoid" end
	local idle = findAnimation(template, NPCConfig.Harbor.animationNames.idle)
	local walk = findAnimation(template, NPCConfig.Harbor.animationNames.walk)
	if not idle or idle.AnimationId == "" then return nil, "template Idle animation is missing or unpublished" end
	if not walk or walk.AnimationId == "" then return nil, "template Walk animation is missing or unpublished" end
	local jointCount = 0
	local parts = {}
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			if descendant.Anchored then
				return nil, "template has an anchored body part: " .. descendant:GetFullName()
			end
		end
		if descendant:IsA("Bone") or descendant:IsA("Motor6D") then jointCount += 1 end
	end
	-- GetConnectedParts only describes an active Workspace/WorldModel
	-- assembly. ServerStorage templates are intentionally checked for their
	-- authored parts above; the live clone is checked after it is parented.
	if jointCount < 2 then return nil, "template has no articulated rig joints" end
	return {
		rootName = root.Name,
		idleName = idle.Name,
		walkName = walk.Name,
		jointCount = jointCount,
		partCount = #parts,
	}
end

local function findTemplate()
	-- The frozen handoff contract is server-only. Do not discover arbitrary
	-- ReplicatedStorage art while the Studio export is still pending.
	if NPCConfig.Harbor.templateParent ~= "ServerStorage" then return nil end
	local folder = ServerStorage:FindFirstChild(NPCConfig.Harbor.templateFolder)
	local template = folder and folder:FindFirstChild(NPCConfig.Harbor.templateName)
	return template
end

local function makeRaycastParams(exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignored = {}
	for _, object in ipairs(exclude or {}) do
		if object then table.insert(ignored, object) end
	end
	local boats = workspace:FindFirstChild("SailingBoats")
	if boats then table.insert(ignored, boats) end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then table.insert(ignored, player.Character) end
	end
	params.FilterDescendantsInstances = ignored
	params.IgnoreWater = false
	params.RespectCanCollide = true
	return params
end

local function groundAt(zoneFolder, x, z, exclude)
	if not NPCConfig.isFiniteNumber(x) or not NPCConfig.isFiniteNumber(z) then return nil end
	local hit = workspace:Raycast(Vector3.new(x, 48, z), Vector3.new(0, -96, 0), makeRaycastParams(exclude))
	if not hit or not hit.Instance or hit.Material == Enum.Material.Water then return nil end
	if not hit.Instance:IsDescendantOf(zoneFolder) or not hit.Instance.CanCollide then return nil end
	if hit.Instance:GetAttribute("CollisionRole") ~= "WalkableIsland" then return nil end
	return hit
end

local function visibleMeshBottomY(model)
	local bottom = math.huge
	local visibleMeshCount = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("MeshPart") and descendant.Transparency < 1 then
			local size = descendant.Size
			if not isFiniteVector3(size) or size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
				return nil, "visible MeshPart has an invalid size: " .. descendant:GetFullName()
			end
			local half = size * .5
			local cframe = descendant.CFrame
			local corners = {
				Vector3.new(-half.X, -half.Y, -half.Z),
				Vector3.new(-half.X, -half.Y, half.Z),
				Vector3.new(-half.X, half.Y, -half.Z),
				Vector3.new(-half.X, half.Y, half.Z),
				Vector3.new(half.X, -half.Y, -half.Z),
				Vector3.new(half.X, -half.Y, half.Z),
				Vector3.new(half.X, half.Y, -half.Z),
				Vector3.new(half.X, half.Y, half.Z),
			}
			for _, corner in ipairs(corners) do
				local worldCorner = cframe:PointToWorldSpace(corner)
				if not isFiniteVector3(worldCorner) then
					return nil, "visible MeshPart has a non-finite world corner: " .. descendant:GetFullName()
				end
				bottom = math.min(bottom, worldCorner.Y)
			end
			visibleMeshCount += 1
		end
	end
	if visibleMeshCount == 0 or bottom == math.huge or not NPCConfig.isFiniteNumber(bottom) then
		return nil, "model has no valid visible MeshPart grounding geometry"
	end
	return bottom
end

local function nearestPlayer(position)
	local nearest = nil
	local nearestDistance = NPCConfig.Runtime.activationRadius
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and findRoot(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local distance = (root.Position - position).Magnitude
			if distance <= nearestDistance then
				nearest = player
				nearestDistance = distance
			end
		end
	end
	return nearest
end

local function hasBoatOverlap(position, model)
	if not isFiniteVector3(position) then return true end
	local boats = workspace:FindFirstChild("SailingBoats")
	if not boats then return false end
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = {model}
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(position), Vector3.new(7, 8, 7), overlap)) do
		if part:IsDescendantOf(boats) and part.CanCollide then return true end
	end
	return false
end

local function projectWaypoint(state, position)
	local zone = WorldLayout.Zones[NPCConfig.Harbor.zoneId]
	if not zone or not isFiniteVector3(position)
		or not NPCConfig.isArrivalPointValid(zone, position.X, position.Z) then
		return nil
	end
	local support = groundAt(state.zoneFolder, position.X, position.Z, {state.model})
	if not support or hasBoatOverlap(support.Position, state.model) then return nil end
	local projected = Vector3.new(position.X, support.Position.Y + state.rootGroundOffset, position.Z)
	return isFiniteVector3(projected) and projected or nil
end

local function segmentHasLandSupport(state, fromPosition, toPosition)
	local zone = WorldLayout.Zones[NPCConfig.Harbor.zoneId]
	if not zone or not isFiniteVector3(fromPosition) or not isFiniteVector3(toPosition) then return false end
	return NPCConfig.sampleArrivalSegment(zone,
		{x = fromPosition.X, z = fromPosition.Z},
		{x = toPosition.X, z = toPosition.Z},
		function(x, z)
			local support = groundAt(state.zoneFolder, x, z, {state.model})
			if not support then return false end
			return not hasBoatOverlap(Vector3.new(x, support.Position.Y + state.rootGroundOffset, z), state.model)
		end)
end

local function makeTargets(state)
	local zone = WorldLayout.Zones[NPCConfig.Harbor.zoneId]
	local targets = {}
	for _, offset in ipairs(NPCConfig.Harbor.patrolOffsets) do
		local point = NPCConfig.worldPatrolPoint(zone, offset)
		if point then
			local target = projectWaypoint(state, Vector3.new(point.x, 0, point.z))
			if target then table.insert(targets, target) end
		end
	end
	return targets
end

local function setMotionAttribute(state, motion)
	state.motion = motion
	state.model:SetAttribute("NPCMotionState", motion)
end

local function playTrack(state, name)
	local track = state.tracks[name]
	if not track then return end
	for otherName, other in pairs(state.tracks) do
		if otherName ~= name and other.IsPlaying then other:Stop(.12) end
	end
	if not track.IsPlaying then
		track:Play(.12)
		if name == "walk" then
			state.walkCount += 1
			state.model:SetAttribute("NPCWalkCount", state.walkCount)
		end
	end
	setMotionAttribute(state, name == "walk" and "Walk" or "Idle")
end

local function stopPathConnection(state)
	if state.pathConnection then
		state.pathConnection:Disconnect()
		state.pathConnection = nil
	end
end

local function stopMotion(state)
	state.generation += 1
	state.blocked = false
	stopPathConnection(state)
	if state.humanoid and state.root then state.humanoid:MoveTo(state.root.Position) end
	state.moving = false
	playTrack(state, "idle")
end

local function computePath(state, target)
	local path = PathfindingService:CreatePath({
		AgentRadius = NPCConfig.Runtime.agentRadius,
		AgentHeight = NPCConfig.Runtime.agentHeight,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointSpacing = NPCConfig.Runtime.waypointSpacing,
		Costs = {Water = math.huge},
	})
	local ok, err = pcall(function()
		path:ComputeAsync(state.root.Position, target)
	end)
	if not ok then
		status("path computation failed: " .. tostring(err))
		return nil
	end
	if path.Status ~= Enum.PathStatus.Success then return nil end
	return path
end

local function moveToWaypoint(state, target, generation)
	if state.generation ~= generation or not state.active or state.blocked then return false end
	local projectedTarget = projectWaypoint(state, target)
	if not projectedTarget then
		state.blocked = true
		state.generation += 1
		return false
	end
	if not segmentHasLandSupport(state, state.lastWaypointPosition or state.root.Position, projectedTarget) then
		state.blocked = true
		state.generation += 1
		return false
	end
	local reached = nil
	local connection = state.humanoid.MoveToFinished:Connect(function(value) reached = value end)
	state.humanoid:MoveTo(projectedTarget)
	local deadline = os.clock() + NPCConfig.Runtime.waypointTimeout
	while reached == nil and os.clock() < deadline do
		if state.generation ~= generation or not state.active or state.blocked or not state.model.Parent then break end
		RunService.Heartbeat:Wait()
	end
	connection:Disconnect()
	local success = reached == true and state.generation == generation and not state.blocked and state.active
	if success then state.lastWaypointPosition = projectedTarget end
	return success
end

local function followPath(state, path)
	local waypoints = path:GetWaypoints()
	if #waypoints < 2 then return false end
	local route = {}
	local previous = state.root.Position
	for index, waypoint in ipairs(waypoints) do
		local projected = projectWaypoint(state, waypoint.Position)
		if not projected or not segmentHasLandSupport(state, previous, projected) then
			state.blocked = true
			state.generation += 1
			return false
		end
		table.insert(route, projected)
		previous = projected
	end
	local generation = state.generation
	state.blocked = false
	state.pathConnection = path.Blocked:Connect(function(blockedWaypointIndex)
		if blockedWaypointIndex >= 1 then
			state.blocked = true
			state.generation += 1
		end
	end)
	state.moving = true
	state.lastWaypointPosition = route[1]
	playTrack(state, "walk")
	for index = 2, #route do
		if not moveToWaypoint(state, route[index], generation) then
			stopPathConnection(state)
			state.moving = false
			playTrack(state, "idle")
			return false
		end
	end
	stopPathConnection(state)
	state.moving = false
	playTrack(state, "idle")
	return true
end

local function patrolLoop(state)
	while state.alive and state.active do
		local targets = makeTargets(state)
		if #targets == 0 then
			status("no valid arrival-land patrol targets")
			task.wait(NPCConfig.Runtime.repathCooldown)
		else
			state.targets = targets
			state.targetIndex = (state.targetIndex % #targets) + 1
			local path = computePath(state, targets[state.targetIndex])
			if path then
				state.pathCount += 1
				state.model:SetAttribute("NPCPathCount", state.pathCount)
				followPath(state, path)
			else
				playTrack(state, "idle")
			end
			task.wait(NPCConfig.Runtime.repathCooldown)
		end
	end
	state.moving = false
	if state.alive then stopMotion(state) end
	state.workerRunning = false
	-- A deactivation can race the worker's final loop check. If a player
	-- reactivates the NPC in that window, restart from the worker's own exit so
	-- the active state cannot remain stranded with no patrol task.
	if state.alive and state.active then
		state.workerRunning = true
		task.spawn(patrolLoop, state)
	end
end

local function copyRoleLabel(source, target)
	local sourceLabel = source:FindFirstChild("Label", true)
	if not sourceLabel or not sourceLabel:IsA("BillboardGui") then return end
	local candidate = target:FindFirstChild("Head", true)
	local anchor = if candidate and (candidate:IsA("BasePart") or candidate:IsA("Attachment")) then candidate else findRoot(target)
	if not anchor then return end
	local label = sourceLabel:Clone()
	label.Parent = anchor
end

local function setServerOwnership(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			pcall(function()
				if descendant:CanSetNetworkOwnership() then descendant:SetNetworkOwner(nil) end
			end)
		end
	end
end

local function alignToGround(model, root, support)
	if not support or not isFiniteVector3(support.Position) then
		return nil, nil, "ground support has an invalid position"
	end
	local beforeBottom, beforeError = visibleMeshBottomY(model)
	if not beforeBottom then return nil, nil, beforeError end
	local offset = support.Position.Y - beforeBottom
	if not NPCConfig.isFiniteNumber(offset) then
		return nil, nil, "visible MeshPart grounding offset is non-finite"
	end
	local pivot = model:GetPivot()
	-- Pre-multiply so the translation is in world Y even when the model pivot
	-- has authored pitch/roll.  This is the one placement correction before
	-- animation preload; no per-frame pose correction is performed.
	model:PivotTo(CFrame.new(0, offset, 0) * pivot)
	local afterBottom, afterError = visibleMeshBottomY(model)
	if not afterBottom then return nil, nil, afterError end
	if math.abs(afterBottom - support.Position.Y) > GROUNDING_TOLERANCE then
		return nil, nil, string.format(
			"visible MeshPart grounding did not settle on support (bottom %.6f, support %.6f)",
			afterBottom,
			support.Position.Y)
	end
	local rootGroundOffset = root.Position.Y - afterBottom
	if not NPCConfig.isFiniteNumber(rootGroundOffset) then
		return nil, nil, "root ground offset is non-finite after visible MeshPart grounding"
	end
	return rootGroundOffset, afterBottom
end

local function discardTrack(track)
	if not track then return end
	pcall(function() track:Stop(0) end)
	pcall(function() track:Destroy() end)
end

local function beginAnimationPreload(animations, canContinue)
	local state = {
		done = false,
		ok = false,
		error = nil,
		failure = nil,
		cancelled = false,
	}
	state.thread = task.spawn(function()
		if canContinue and not canContinue() then
			state.cancelled = true
			state.done = true
			return
		end
		local ok, err = pcall(function()
			-- PreloadAsync is deliberately isolated from the service coroutine. It
			-- warms both authored clips but cannot delay FishingService startup.
			ContentProvider:PreloadAsync(animations, function(contentId, fetchStatus)
				if state.cancelled then return end
				if fetchStatus ~= Enum.AssetFetchStatus.Success then
					state.failure = tostring(contentId) .. ":" .. tostring(fetchStatus)
				end
			end)
		end)
		state.ok = ok
		state.error = if ok then nil else tostring(err)
		state.done = true
	end)
	return state
end

local function cancelAnimationPreload(state)
	if not state or state.done then return end
	state.cancelled = true
	if state.thread then pcall(task.cancel, state.thread) end
end

local function preloadSummary(state)
	if not state then return "not-started" end
	if state.failure then return "asset-failure:" .. state.failure end
	if state.error then return "error:" .. state.error end
	if not state.done then return "pending" end
	return state.ok and "complete" or "failed"
end

local function trackLength(track)
	local ok, length = pcall(function() return track.Length end)
	if not ok or type(length) ~= "number" or not NPCConfig.isFiniteNumber(length) or length <= 0 then
		return 0
	end
	return length
end

local function loadAnimationTracks(animator, entries, canContinue, preloadState)
	local tracks = {}
	for _, entry in ipairs(entries) do
		local ok, track = pcall(function()
			return animator:LoadAnimation(entry.animation)
		end)
		if not ok or typeof(track) ~= "Instance" or not track:IsA("AnimationTrack") then
			for _, loaded in pairs(tracks) do discardTrack(loaded) end
			cancelAnimationPreload(preloadState)
			return nil, entry.label .. " animation did not return an AnimationTrack"
		end
		tracks[entry.key] = track
	end

	local deadline = os.clock() + NPCConfig.Runtime.animationLoadTimeout
	while true do
		if canContinue and not canContinue() then
			for _, track in pairs(tracks) do discardTrack(track) end
			cancelAnimationPreload(preloadState)
			return nil, "animation load cancelled"
		end
		local ready = true
		for _, entry in ipairs(entries) do
			if trackLength(tracks[entry.key]) <= 0 then
				ready = false
				break
			end
		end
		if ready then
			cancelAnimationPreload(preloadState)
			return tracks
		end
		if os.clock() >= deadline then
			local idleLength = trackLength(tracks.idle)
			local walkLength = trackLength(tracks.walk)
			status(string.format(
				"animation readiness timeout after %.1fs (Idle Length %.3f, Walk Length %.3f, preload %s)",
				NPCConfig.Runtime.animationLoadTimeout,
				idleLength,
				walkLength,
				preloadSummary(preloadState)))
			for _, track in pairs(tracks) do discardTrack(track) end
			cancelAnimationPreload(preloadState)
			return nil, "authored animations did not load before the bounded readiness deadline"
		end
		RunService.Heartbeat:Wait()
	end
end

local function startRuntime(source, template, validation, canContinue)
	local world = workspace:FindFirstChild("FishingWorld")
	local zoneFolder = world and world:FindFirstChild("Zone" .. tostring(NPCConfig.Harbor.zoneId))
	if not zoneFolder then return nil, "Zone 1 folder missing" end
	local sourcePivot = source:GetPivot()
	local clone = template:Clone()
	clone.Name = NPCConfig.Harbor.replacementName
	local root = findRoot(clone)
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		clone:Destroy()
		return nil, "template clone lost root or Humanoid"
	end
	-- Set these before parenting. A malformed imported neck joint can otherwise
	-- kill the clone during the parent/physics yield and leave no usable avatar.
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	-- Keep the validated physics root seated while Roblox resolves authored
	-- animation lengths. The static source remains visible until both tracks
	-- pass their bounded readiness check.
	root.Anchored = true
	clone.Parent = zoneFolder
	local cloneParts = {}
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then table.insert(cloneParts, descendant) end
	end
	local connected, connectionError = validateSingleAssembly(root, cloneParts)
	if not connected then
		clone:Destroy()
		return nil, connectionError
	end
	clone:PivotTo(sourcePivot)
	clone.PrimaryPart = root
	local support = groundAt(zoneFolder, sourcePivot.Position.X, sourcePivot.Position.Z, {clone})
	if not support then
		clone:Destroy()
		return nil, "source pivot has no arrival-land support"
	end
	local rootGroundOffset, visibleGroundBottom, groundingError = alignToGround(clone, root, support)
	if not rootGroundOffset then
		clone:Destroy()
		return nil, groundingError or "visible MeshPart grounding failed"
	end
	local rootHeight = root.Size.Y
	if not NPCConfig.isFiniteNumber(rootHeight) or rootHeight <= 0 then
		clone:Destroy()
		return nil, "root has an invalid height for HipHeight derivation"
	end
	local derivedHipHeight = rootGroundOffset - rootHeight * .5
	if not NPCConfig.isFiniteNumber(derivedHipHeight) or derivedHipHeight <= .25 or derivedHipHeight >= 8 then
		clone:Destroy()
		return nil, string.format("visible MeshPart grounding produced impossible HipHeight %.6f", derivedHipHeight)
	end
	humanoid.HipHeight = derivedHipHeight
	humanoid.AutoRotate = true
	humanoid.WalkSpeed = NPCConfig.Runtime.walkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local idleAnimation = findAnimation(clone, validation.idleName)
	local walkAnimation = findAnimation(clone, validation.walkName)
	if not idleAnimation or not walkAnimation then
		clone:Destroy()
		return nil, "template clone lost authored animations"
	end
	local preloadState = beginAnimationPreload({idleAnimation, walkAnimation}, canContinue)
	local loadedTracks, trackError = loadAnimationTracks(animator, {
		{key = "idle", label = "Idle", animation = idleAnimation},
		{key = "walk", label = "Walk", animation = walkAnimation},
	}, canContinue, preloadState)
	if not loadedTracks then
		clone:Destroy()
		return nil, trackError
	end
	local idleTrack = loadedTracks.idle
	local walkTrack = loadedTracks.walk
	idleTrack.Looped = true
	walkTrack.Looped = true
	idleTrack.Priority = Enum.AnimationPriority.Idle
	walkTrack.Priority = Enum.AnimationPriority.Movement
	if not canContinue() then
		discardTrack(idleTrack)
		discardTrack(walkTrack)
		clone:Destroy()
		return nil, "NPC startup cancelled"
	end
	root.Anchored = false
	setServerOwnership(clone)
	clone:SetAttribute("Zone", NPCConfig.Harbor.zoneId)
	clone:SetAttribute("Role", "Greeter")
	clone:SetAttribute("NPC", true)
	clone:SetAttribute("SceneRole", "NPC")
	clone:SetAttribute("NPCController", "Humanoid")
	clone:SetAttribute("NPCMotionState", "Idle")
	clone:SetAttribute("NPCPathCount", 0)
	clone:SetAttribute("NPCWalkCount", 0)
	clone:SetAttribute("NPCJointCount", validation.jointCount)
	clone:SetAttribute("NPCIdleTrackLength", idleTrack.Length)
	clone:SetAttribute("NPCWalkTrackLength", walkTrack.Length)
	clone:SetAttribute("NPCGroundY", support.Position.Y)
	clone:SetAttribute("NPCRootGroundOffset", rootGroundOffset)
	clone:SetAttribute("NPCVisibleGroundBottom", visibleGroundBottom)
	clone:SetAttribute("NPCGroundingContract", "visible-mesh-corners-v1")
	clone:SetAttribute("NPCSource", NPCConfig.Harbor.sourceName)
	copyRoleLabel(source, clone)

	local state = {
		alive = true,
		active = false,
		moving = false,
		blocked = false,
		workerRunning = false,
		generation = 0,
		model = clone,
		root = root,
		humanoid = humanoid,
		zoneFolder = zoneFolder,
		rootGroundOffset = rootGroundOffset,
		tracks = {idle = idleTrack, walk = walkTrack},
		pathCount = 0,
		walkCount = 0,
		targetIndex = 0,
		motion = "Idle",
	}
	return state
end

function NPCService.start()
	if started or startupRunning then return end
	started = true
	startupRunning = true
	lifecycleGeneration += 1
	local generation = lifecycleGeneration
	local canContinue = function()
		return started and lifecycleGeneration == generation
	end
	local function finishStartup()
		if lifecycleGeneration == generation then startupRunning = false end
	end
	local world = workspace:FindFirstChild("FishingWorld")
	local zoneFolder = world and world:FindFirstChild("Zone" .. tostring(NPCConfig.Harbor.zoneId))
	local source = zoneFolder and zoneFolder:FindFirstChild(NPCConfig.Harbor.sourceName)
	local template = findTemplate()
	if world then world:SetAttribute("NPCIntegrationStatus", "PendingStudioTemplate") end
	if not source or not source:IsA("Model") then
		status("source NPC missing; leaving world unchanged")
		finishStartup()
		return
	end
	if not template then
		status("validated template not present; leaving static NPC in place")
		finishStartup()
		return
	end
	local validation, validationError = validateTemplate(template)
	if not validation then
		if world then world:SetAttribute("NPCIntegrationStatus", "RejectedTemplate") end
		status("template rejected: " .. tostring(validationError))
		finishStartup()
		return
	end
	local state, runtimeError = startRuntime(source, template, validation, canContinue)
	if not state then
		if canContinue() then
			if world then world:SetAttribute("NPCIntegrationStatus", "RejectedRuntime") end
			status("runtime clone rejected: " .. tostring(runtimeError))
		else
			-- stop() invalidates the generation while the bounded animation load is
			-- yielding. Keep the cancellation from overwriting its stopped state.
			status("NPC startup cancelled")
		end
		finishStartup()
		return
	end
	if not canContinue() then
		for _, track in pairs(state.tracks or {}) do discardTrack(track) end
		if state.model then state.model:Destroy() end
		finishStartup()
		return
	end
	local backup = ServerStorage:FindFirstChild("FishingNPCBackups")
	if not backup then
		backup = Instance.new("Folder")
		backup.Name = "FishingNPCBackups"
		backup.Parent = ServerStorage
	end
	local sourceParent = source.Parent
	source.Parent = backup
	state.source = source
	state.sourceParent = sourceParent
	state.backup = backup
	activeState = state
	world:SetAttribute("NPCDynamicReady", true)
	world:SetAttribute("NPCIntegrationStatus", "Validated")
	playTrack(state, "idle")
	finishStartup()

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not state.alive or not state.model.Parent then return end
		state.proximityClock = (state.proximityClock or 0) + deltaTime
		if state.proximityClock < NPCConfig.Runtime.proximityInterval then return end
		state.proximityClock = 0
		local player = nearestPlayer(state.root.Position)
		local nextActive = player ~= nil
		if state.active and not nextActive then
			state.active = false
			stopMotion(state)
		elseif nextActive then
			state.active = true
			-- Check this on every active tick. The prior transition-only check
			-- could lose a reactivation while an old worker was exiting.
			if not state.workerRunning then
				state.workerRunning = true
				task.spawn(patrolLoop, state)
			end
		end
	end)
	status("started validated Zone 1 harbor NPC")
end

function NPCService.stop()
	if not started and not startupRunning then return end
	started = false
	lifecycleGeneration += 1
	startupRunning = false
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	local state = activeState
	activeState = nil
	if not state then
		local world = workspace:FindFirstChild("FishingWorld")
		if world then
			world:SetAttribute("NPCDynamicReady", false)
			world:SetAttribute("NPCIntegrationStatus", "Stopped")
		end
		status("stopped before dynamic harbor NPC activation")
		return
	end
	state.alive = false
	state.active = false
	state.generation += 1
	stopPathConnection(state)
	for _, track in pairs(state.tracks or {}) do
		pcall(function() track:Stop(.1) end)
	end
	if state.model then state.model:Destroy() end
	if state.source and state.sourceParent then state.source.Parent = state.sourceParent end
	local world = workspace:FindFirstChild("FishingWorld")
	if world then
		world:SetAttribute("NPCDynamicReady", false)
		world:SetAttribute("NPCIntegrationStatus", "Stopped")
	end
	status("stopped and restored static harbor NPC")
end

function NPCService.getActiveModel()
	return activeState and activeState.model or nil
end

return NPCService
