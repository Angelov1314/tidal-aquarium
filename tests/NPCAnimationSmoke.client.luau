--!nonstrict
-- Formal client-side NPC animation acceptance smoke.
--
-- This script observes the ordinary server NPCService track. It never creates,
-- loads, plays, stops, or replaces an Animation/AnimationTrack, and it does not
-- move the player. The temporary camera framing is restored on every exit.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then return end

local WORLD_READY_TIMEOUT = 45
local NPC_READY_TIMEOUT = 35
local SAMPLE_WINDOW = 18
local POSE_DELTA_THRESHOLD = 0.0001

local function expect(value, message)
	if not value then error(message, 2) end
end

local function waitUntil(predicate, timeout)
	local deadline = os.clock() + timeout
	repeat
		if predicate() then return true end
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	until false
end

local function rootOf(model)
	return model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart", true)
		or model:FindFirstChild("RootPart", true)
		or model:FindFirstChild("Root", true)
end

local function findAnimation(model, name)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Animation") and descendant.Name == name then return descendant end
	end
	return nil
end

local function walkTrack(animator, walkAnimation)
	local ok, track = pcall(function()
		return animator:GetTrackByAnimationId(walkAnimation.AnimationId)
	end)
	if ok and track and track:IsA("AnimationTrack") then return track end
	for _, candidate in ipairs(animator:GetPlayingAnimationTracks()) do
		local okAnimation, animation = pcall(function() return candidate.Animation end)
		if okAnimation and animation and animation.AnimationId == walkAnimation.AnimationId then return candidate end
	end
	return nil
end

local function animationTrack(animator, animation)
	local ok, track = pcall(function()
		return animator:GetTrackByAnimationId(animation.AnimationId)
	end)
	if ok and track and track:IsA("AnimationTrack") then return track end
	for _, candidate in ipairs(animator:GetPlayingAnimationTracks()) do
		local okAnimation, candidateAnimation = pcall(function() return candidate.Animation end)
		if okAnimation and candidateAnimation and candidateAnimation.AnimationId == animation.AnimationId then
			return candidate
		end
	end
	return nil
end

local function cframeDelta(before, after)
	local relative = before:ToObjectSpace(after)
	local _, angle = relative:ToAxisAngle()
	return relative.Position.Magnitude + math.abs(angle)
end

local function isRootBone(bone)
	local name = string.lower(bone.Name)
	return name == "root" or name == "rootpart" or name == "humanoidrootpart"
end

local function bonePose(bone, root)
	local transform = nil
	local okTransform, value = pcall(function() return bone.Transform end)
	if okTransform and typeof(value) == "CFrame" then transform = value end
	local relative = nil
	local okWorld, transformed = pcall(function() return bone.TransformedWorldCFrame end)
	if okWorld and typeof(transformed) == "CFrame" then
		local okRelative, valueRelative = pcall(function()
			return root.CFrame:ToObjectSpace(transformed)
		end)
		if okRelative then relative = valueRelative end
	end
	return transform, relative
end

local function countSet(values)
	local count = 0
	for _ in pairs(values) do count += 1 end
	return count
end

local camera = nil
local oldCameraType = nil
local oldCameraCFrame = nil
local oldCameraSubject = nil
local oldCameraFieldOfView = nil

local function restoreCamera()
	if not camera or not camera.Parent then return end
	if oldCameraCFrame then camera.CFrame = oldCameraCFrame end
	if oldCameraSubject then camera.CameraSubject = oldCameraSubject end
	if oldCameraFieldOfView then camera.FieldOfView = oldCameraFieldOfView end
	if oldCameraType then camera.CameraType = oldCameraType end
end

local function frameNpc(root)
	local current = workspace.CurrentCamera
	local deadline = os.clock() + 5
	while not current and os.clock() < deadline do
		RunService.Heartbeat:Wait()
		current = workspace.CurrentCamera
	end
	expect(current, "CurrentCamera was not created")
	camera = current
	oldCameraType = camera.CameraType
	oldCameraCFrame = camera.CFrame
	oldCameraSubject = camera.CameraSubject
	oldCameraFieldOfView = camera.FieldOfView
	local focus = root.Position + Vector3.new(0, 0.4, 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(8, 3.5, 12), focus)
end

local function run()
	local player = Players.LocalPlayer
	expect(player, "NPCAnimationSmoke requires a local player")
	local shared = ReplicatedStorage:WaitForChild("FishingShared", WORLD_READY_TIMEOUT)
	expect(shared, "FishingShared missing")
	local NPCConfig = require(shared:WaitForChild("NPCConfig"))
	local world = workspace:WaitForChild("FishingWorld", WORLD_READY_TIMEOUT)
	expect(world, "FishingWorld missing")
	expect(waitUntil(function() return world:GetAttribute("Ready") == true end, WORLD_READY_TIMEOUT),
		"FishingWorld did not become Ready")
	local zone = world:WaitForChild("Zone1", 5)
	expect(zone, "Zone1 missing")
	local npc = nil
	expect(waitUntil(function()
		for _, child in ipairs(zone:GetChildren()) do
			if child:IsA("Model") and child:GetAttribute("NPC") == true then
				npc = child
				return true
			end
		end
		return false
	end, NPC_READY_TIMEOUT), "validated dynamic harbor NPC did not appear")
	expect(world:GetAttribute("NPCIntegrationStatus") == "Validated", "NPC integration status must be validated")
	expect(npc, "dynamic harbor NPC missing")
	local root = rootOf(npc)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	expect(root and humanoid and humanoid.Health > 0, "dynamic NPC root or Humanoid is not alive")
	local animator = nil
	local idleAnimation = nil
	local walkAnimation = nil
	expect(waitUntil(function()
		animator = humanoid:FindFirstChildOfClass("Animator")
		idleAnimation = findAnimation(npc, NPCConfig.Harbor.animationNames.idle)
		walkAnimation = findAnimation(npc, NPCConfig.Harbor.animationNames.walk)
		return animator and idleAnimation and walkAnimation
	end, NPC_READY_TIMEOUT), "authored Idle/Walk animations or Animator are missing")
	expect(walkAnimation.AnimationId ~= "" and idleAnimation.AnimationId ~= "", "authored animation is unpublished")
	expect(NPC_READY_TIMEOUT > NPCConfig.Runtime.animationLoadTimeout + 5,
		"client smoke readiness budget must exceed the server animation deadline")

	local bones = {}
	for _, descendant in ipairs(npc:GetDescendants()) do
		if descendant:IsA("Bone") and not isRootBone(descendant) then
			table.insert(bones, descendant)
		end
	end
	expect(#bones >= 2, "dynamic NPC has no non-root bones to observe")
	frameNpc(root)

	local previousTime = nil
	local previousPoses = {}
	local changedBones = {}
	local changedLeftArm = false
	local changedRightArm = false
	local changedLeg = false
	local sawWalk = false
	local timeAdvanced = false
	local samples = 0
	local deadline = os.clock() + SAMPLE_WINDOW
	while os.clock() < deadline do
		RunService.RenderStepped:Wait()
		local track = walkTrack(animator, walkAnimation)
		if track and track.IsPlaying and track.WeightCurrent > 0.05 then
			sawWalk = true
			local timePosition = track.TimePosition
			if previousTime ~= nil and math.abs(timePosition - previousTime) > 0.0001 then
				timeAdvanced = true
			end
			previousTime = timePosition
			local currentPoses = {}
			for _, bone in ipairs(bones) do
				local transform, relative = bonePose(bone, root)
				currentPoses[bone] = {transform = transform, relative = relative}
				local previous = previousPoses[bone]
				if previous then
					local transformDelta = 0
					local relativeDelta = 0
					if previous.transform and transform then
						transformDelta = cframeDelta(previous.transform, transform)
					end
					if previous.relative and relative then
						relativeDelta = cframeDelta(previous.relative, relative)
					end
					local delta = math.max(transformDelta, relativeDelta)
					if delta > POSE_DELTA_THRESHOLD then
						changedBones[bone] = true
						local lowerName = string.lower(bone.Name)
						-- Formal limb evidence uses the bone's own Transform. A
						-- root-relative world pose is retained above as a diagnostic,
						-- but cannot turn root-only motion into an animation pass.
						if transformDelta > POSE_DELTA_THRESHOLD then
							if string.find(lowerName, "upperarm_l", 1, true)
								or string.find(lowerName, "lowerarm_l", 1, true) then
								changedLeftArm = true
							elseif string.find(lowerName, "upperarm_r", 1, true)
								or string.find(lowerName, "lowerarm_r", 1, true) then
								changedRightArm = true
							elseif string.find(lowerName, "thigh", 1, true)
								or string.find(lowerName, "calf", 1, true) then
								changedLeg = true
							end
						end
					end
				end
			end
			previousPoses = currentPoses
			samples += 1
			if timeAdvanced
				and countSet(changedBones) >= 2
				and changedLeftArm
				and changedRightArm
				and changedLeg
				and samples >= 3 then
				break
			end
		else
			previousTime = nil
			previousPoses = {}
		end
	end
	expect(sawWalk, "server-driven Walk track never became visible with positive weight")
	expect(timeAdvanced, "server-driven Walk TimePosition did not advance across rendered frames")
	expect(countSet(changedBones) >= 2, "only root or rigid-body motion was observed; no two non-root bone poses changed")
	expect(changedLeftArm and changedRightArm and changedLeg,
		"server-driven Walk did not change both arm sides and a weighted leg Transform")

	local idlePreviousTime = nil
	local idleSeen = false
	local idleAdvanced = false
	local idleDeadline = os.clock() + NPC_READY_TIMEOUT
	while os.clock() < idleDeadline do
		RunService.RenderStepped:Wait()
		local track = animationTrack(animator, idleAnimation)
		if track and track.IsPlaying and track.WeightCurrent > 0.05 then
			idleSeen = true
			if idlePreviousTime ~= nil and math.abs(track.TimePosition - idlePreviousTime) > 0.0001 then
				idleAdvanced = true
				break
			end
			idlePreviousTime = track.TimePosition
		else
			idlePreviousTime = nil
		end
	end
	expect(idleSeen, "server-driven Idle track did not become visible with positive weight")
	expect(idleAdvanced, "server-driven Idle TimePosition did not advance across rendered frames")

	ReplicatedStorage:SetAttribute("NPCAnimationSmokePass", true)
	print("NPC_ANIMATION_PASS", "server-driven Walk TimePosition and non-root limb deformation observed", "samples", samples)
end

local ok, err = xpcall(run, debug.traceback)
restoreCamera()
if not ok then
	ReplicatedStorage:SetAttribute("NPCAnimationSmokePass", false)
	warn("NPC_ANIMATION_FAIL: " .. tostring(err))
end
