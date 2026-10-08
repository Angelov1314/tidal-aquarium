-- Isolated server smoke: uses synthetic rigs and never moves a real player.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Showcase = require(game:GetService("ServerScriptService").FishingServer.Showcase)
local Config = require(ReplicatedStorage.FishingShared.Config)

local function expect(condition, message)
	if not condition then error(message, 2) end
end

local function rigFixture(r15)
	local rig = Instance.new("Model")
	rig.Name = r15 and "ShowcaseSmokeR15" or "ShowcaseSmokeR6"
	rig.Parent = workspace
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.Parent = rig
	local torso = Instance.new("Part")
	torso.Name = r15 and "UpperTorso" or "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CFrame = CFrame.new(0, 6, 0)
	torso.Anchored = true
	torso.Parent = rig
	local left = Instance.new("Part")
	left.Name = r15 and "LeftUpperArm" or "Left Arm"
	left.Size = Vector3.new(1, 2, 1)
	left.CFrame = torso.CFrame * CFrame.new(-1.5, 0, 0)
	left.Anchored = true
	left.Parent = rig
	local right = left:Clone()
	right.Name = r15 and "RightUpperArm" or "Right Arm"
	right.CFrame = torso.CFrame * CFrame.new(1.5, 0, 0)
	right.Parent = rig
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = rig
	local function shoulder(name, part)
		local motor = Instance.new("Motor6D")
		motor.Name = name
		motor.Part0 = torso
		motor.Part1 = part
		motor.C0 = CFrame.new(part.Position - torso.Position)
		motor.C1 = CFrame.new()
		motor.Parent = r15 and rig or torso
		return motor
	end
	local leftJoint = shoulder(r15 and "LeftShoulder" or "Left Shoulder", left)
	local rightJoint = shoulder(r15 and "RightShoulder" or "Right Shoulder", right)
	local added = Instance.new("BindableEvent")
	return rig, {Character = rig, CharacterAdded = added.Event}, torso, leftJoint, rightJoint, added
end

local species = Config.Species[1]
local function snapshot(fishing, placed)
	return {
		fishing = fishing == true,
		showcaseFishId = "f1",
		fish = {{id = "f1", species = species.id, level = 2, size = 2, placed = placed == true, weightGrams = 420, trait = "ordinary"}},
	}
end

for _, r15 in ipairs({false, true}) do
	local rig, fakePlayer, torso, leftJoint, rightJoint, added = rigFixture(r15)
	local originalLeft, originalRight = leftJoint.C0, rightJoint.C0
	expect(Showcase.update(fakePlayer, snapshot(false, false)), "showcase update should build synthetic rig")
	local display = rig:FindFirstChild("OpenCloudFishShowcase")
	expect(display and display:GetAttribute("ShowcaseFishId") == "f1", "server display identity")
	expect(display:FindFirstChild("ShowcaseTorsoWeld", true), "display welded to torso")
	expect(display:FindFirstChild("ShowcasePlaque", true), "display plaque")
	expect(leftJoint.C0 ~= originalLeft and rightJoint.C0 ~= originalRight, "carry pose applied")
	for _, object in ipairs(display:GetDescendants()) do
		if object:IsA("BasePart") then
			expect(object.Massless and not object.CanCollide and not object.CanTouch and not object.CanQuery, "display parts must be inert")
		end
	end

	-- Starting a round hides the model but leaves the selected ID in the
	-- authoritative snapshot; stopping the round reconstitutes it.
	expect(Showcase.update(fakePlayer, snapshot(true, false)), "fishing hides display")
	expect(rig:FindFirstChild("OpenCloudFishShowcase") == nil, "fishing display hidden")
	expect(leftJoint.C0 == originalLeft and rightJoint.C0 == originalRight, "pose restored while hidden")
	expect(Showcase.update(fakePlayer, snapshot(false, false)), "stop fishing restores display")
	expect(rig:FindFirstChild("OpenCloudFishShowcase") ~= nil, "display restored after fishing")

	local placedState = snapshot(false, true)
	placedState.showcaseFishId = "f1"
	Showcase.update(fakePlayer, placedState)
	expect(rig:FindFirstChild("OpenCloudFishShowcase") == nil, "placed fish cannot remain held")
	Showcase.update(fakePlayer, {fishing = false, showcaseFishId = nil, fish = placedState.fish})
	expect(rig:FindFirstChild("OpenCloudFishShowcase") == nil, "hide selection cleans display")
	Showcase.remove(fakePlayer)
	added:Destroy()
	rig:Destroy()
end

print("ShowcaseSmoke: isolated R6/R15 pose, weld, inert parts, fishing hide/restore, placed/hide cleanup PASS")
