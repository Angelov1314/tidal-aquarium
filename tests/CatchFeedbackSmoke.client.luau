local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local CatchFeedback = require(shared:WaitForChild("CatchFeedback"))
local Config = require(shared:WaitForChild("Config"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local CatchPresentation = require(Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("CatchPresentation"))

local reps = {
	{id = "f1", species = "white_koi", level = 1, size = 2, mutation = 1},
}
local event = {kind = "catch", batchId = "qa-session:1", count = 100, zone = 1, fish = reps}
assert(CatchFeedback.validateBatch(event), "feedback event contract rejected")
assert(#CatchFeedback.representatives(reps, nil) == 1, "feedback representative missing")
local seen, order = {}, {}
assert(CatchFeedback.acceptBatch(seen, order, event.batchId), "feedback batch was not accepted")
assert(not CatchFeedback.acceptBatch(seen, order, event.batchId), "feedback duplicate replayed")
assert(not CatchFeedback.validateBatch({kind = "catch", batchId = "qa-session:bad", count = 101, zone = 1, fish = reps}), "feedback count cap missing")
assert(CatchFeedback.phaseAt(0) == "flight", "feedback flight phase missing")
assert(CatchFeedback.phaseAt(CatchFeedback.FlightSeconds + CatchFeedback.LandingSeconds + CatchFeedback.BagSeconds + .01) == "done", "feedback done phase missing")

local fixtureGui = Instance.new("ScreenGui")
fixtureGui.Name = "CatchFeedbackSmokeFixture"
fixtureGui.IgnoreGuiInset = false
fixtureGui.ResetOnSpawn = false
fixtureGui.DisplayOrder = 30
fixtureGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local bagTarget = Instance.new("Frame")
bagTarget.Name = "BagTarget"
bagTarget.BackgroundTransparency = 1
bagTarget.Position = UDim2.fromOffset(24, 24)
bagTarget.Size = UDim2.fromOffset(44, 44)
bagTarget.Parent = fixtureGui

-- Keep the Studio smoke path independent of the live map.  The fixture is
-- above SAFE_GROUND_Y and far from OceanFloor/water, so the real landing ray
-- and FishLand branch are exercised deterministically.
local ground = Instance.new("Part")
ground.Name = "CatchFeedbackSmokeGround"
ground.Anchored = true
ground.CanCollide = false
ground.CanTouch = false
ground.CanQuery = true
ground.Size = Vector3.new(24, 1, 24)
ground.Position = Vector3.new(5000, 3, 4996)
ground.Transparency = 1
ground.Parent = workspace

local sourcePosition = Vector3.new(5000, 1.2, 5000)

local renderReadyDeadline = os.clock() + 2
local renderReadyFrames = 0
repeat
	RunService.RenderStepped:Wait()
	renderReadyFrames += 1
until (renderReadyFrames >= 2 and fixtureGui.AbsoluteSize.X > 0 and bagTarget.AbsoluteSize.X > 0 and workspace.CurrentCamera ~= nil)
	or os.clock() >= renderReadyDeadline
assert(renderReadyFrames >= 2 and fixtureGui.AbsoluteSize.X > 0 and bagTarget.AbsoluteSize.X > 0 and workspace.CurrentCamera ~= nil, "catch fixture GUI/camera did not settle")

local cues = {}
local arrivalCenter: Vector2? = nil
local controller = CatchPresentation.new({
	overlayParent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	config = Config,
	artRenderer = ArtRenderer,
	runService = RunService,
	getBagTarget = function() return bagTarget end,
	getFloatPosition = function() return sourcePosition end,
	getCharacter = function() return nil end,
	audioPlay = function(name)
		table.insert(cues, name)
		if name == "BagCollect" then arrivalCenter = bagTarget.AbsolutePosition + bagTarget.AbsoluteSize * .5 end
	end,
})
assert(controller:playBatch(event), "fixture batch did not start")
assert(not controller:playBatch(event), "fixture duplicate replayed")
local arrivalDeadline = os.clock() + 8
local root, badge
repeat
	root = controller.overlayRoot
	badge = root and root:FindFirstChild("CatchBatchCount")
	if arrivalCenter ~= nil and badge and badge:IsA("GuiObject") then break end
	RunService.RenderStepped:Wait()
until os.clock() >= arrivalDeadline
assert(badge and badge:IsA("GuiObject") and root and root:IsA("GuiObject"), "arrival badge missing")
assert(arrivalCenter ~= nil, "BagCollect target center was not captured")
local expected = arrivalCenter + Vector2.new(0, -28)
local actual = badge.AbsolutePosition + badge.AbsoluteSize * .5
print("CATCH_FEEDBACK_ALIGNMENT_DELTA: " .. tostring((actual - expected).Magnitude))
assert((actual - expected).Magnitude < 3, "catch badge is misaligned with bag target")
local function cueCount(name)
	local count = 0
	for _, cue in ipairs(cues) do if cue == name then count += 1 end end
	return count
end
assert(cueCount("FishLand") == 1, "FishLand callback missing or duplicated")
assert(table.find(cues, "BagCollect") ~= nil, "BagCollect callback missing")
assert(cueCount("BagCollect") == 1, "BagCollect callback duplicated")
controller:destroy()

local cancelController = CatchPresentation.new({
	overlayParent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	config = Config,
	artRenderer = ArtRenderer,
	runService = RunService,
	getBagTarget = function() return bagTarget end,
	getFloatPosition = function() return sourcePosition end,
	getCharacter = function() return nil end,
	audioPlay = function(name) table.insert(cues, name) end,
})
local cancelEvent = {kind = "catch", batchId = "qa-session:cancel", count = 1, zone = 1, fish = reps}
assert(cancelController:playBatch(cancelEvent), "cancel fixture batch did not start")
task.wait(.2)
cancelController:cancel("qa-cleanup")
assert(cueCount("FishLand") == 1 and cueCount("BagCollect") == 1, "cancel played catch SFX early")
cancelController:destroy()
ground:Destroy()

local fallbackController = CatchPresentation.new({
	overlayParent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	config = Config,
	artRenderer = ArtRenderer,
	runService = RunService,
	getBagTarget = function() return bagTarget end,
	getFloatPosition = function() return Vector3.new(7000, 1.2, 7000) end,
	getCharacter = function() return nil end,
	audioPlay = function(name) table.insert(cues, name) end,
})
local fallbackEvent = {kind = "catch", batchId = "qa-session:fallback", count = 1, zone = 1, fish = reps}
assert(fallbackController:playBatch(fallbackEvent), "fallback fixture batch did not start")
local fallbackDeadline = os.clock() + 8
repeat
	if cueCount("BagCollect") >= 2 then break end
	RunService.RenderStepped:Wait()
until os.clock() >= fallbackDeadline
assert(cueCount("FishLand") == 1, "no-surface fallback emitted FishLand")
assert(cueCount("BagCollect") == 2, "no-surface fallback missed BagCollect")
fallbackController:destroy()
fixtureGui:Destroy()
local leakedFolder = workspace:FindFirstChild("FishingCatchFeedback")
assert(not leakedFolder, "catch feedback folder leaked after destroy")
print("CATCH_FEEDBACK_PASS: contract, ground landing, SFX timing, inset alignment, dedupe and cleanup verified")
