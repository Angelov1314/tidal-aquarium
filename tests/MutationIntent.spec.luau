local Model = require("../src/shared/Model")
local RequestValidation = require("../src/shared/RequestValidation")

local function expect(condition: boolean, message: string)
	if not condition then error(message, 2) end
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

local function equal(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

local function validateIntent(action: string, payload: any, expectedReason: string?)
	local ok, reason = RequestValidation.validateMutationIntent(action, payload)
	expect(ok == (expectedReason == nil), action .. " intent acceptance changed")
	if expectedReason then expect(reason == expectedReason, action .. " intent reason changed: " .. tostring(reason)) end
end

-- The network gate requires explicit desired lock state. False is a valid value;
-- omitting it is a different request and must not fall back to toggling.
validateIntent("lock", {id = "f1"}, "lock-state-required")
validateIntent("lock", {id = "f1", locked = "true"}, "lock-state-type")
validateIntent("lock", {id = "f1", locked = false})
validateIntent("lock", {id = "f1", locked = true})
validateIntent("upgrade", {kind = "hooks"}, "upgrade-intent-required")
validateIntent("upgrade", {kind = "hooks", expectedLevel = 1}, "upgrade-intent-required")
validateIntent("upgrade", {kind = "hooks", expectedLevel = 1, expectedCost = 0 / 0}, "upgrade-intent-invalid")
validateIntent("upgrade", {kind = "hooks", expectedLevel = 1.5, expectedCost = 10}, "upgrade-intent-invalid")
validateIntent("upgrade", {kind = "hooks", expectedLevel = 1, expectedCost = 10})
validateIntent("sell", {id = "f1"})

-- Explicit desired state is idempotent in both directions. Repeating the same
-- payload never toggles the fish back to the opposite state.
local lockProfile = Model.new(0)
local lockOn = Model.command(lockProfile, "lock", {id = "f1", locked = true}, 0)
expect(lockOn.ok and lockProfile.fish[1].locked == true, "explicit lock=true must set locked")
local lockOnAgain = Model.command(lockProfile, "lock", {id = "f1", locked = true}, 0)
expect(lockOnAgain.ok and lockProfile.fish[1].locked == true, "repeated lock=true must remain locked")
local lockOff = Model.command(lockProfile, "lock", {id = "f1", locked = false}, 0)
expect(lockOff.ok and lockProfile.fish[1].locked == false, "explicit lock=false must clear locked")
local lockOffAgain = Model.command(lockProfile, "lock", {id = "f1", locked = false}, 0)
expect(lockOffAgain.ok and lockProfile.fish[1].locked == false, "repeated lock=false must remain unlocked")

-- Model keeps its old omitted-field toggle only for pure/internal callers. A
-- partial intent is rejected instead of silently taking that compatibility path.
local partialLock = Model.new(0)
local partialLockBefore = clone(partialLock)
local partialLockResult = Model.command(partialLock, "lock", {id = "f1", locked = nil}, 0)
expect(partialLockResult.ok and partialLock.fish[1].locked == true, "omitted lock field remains internal toggle compatibility")
expect(partialLockBefore.fish[1].locked == false, "lock fixture starts unlocked")
local malformedLock = Model.new(0)
local malformedLockBefore = clone(malformedLock)
local malformedLockResult = Model.command(malformedLock, "lock", {id = "f1", locked = "false"}, 0)
expect(not malformedLockResult.ok and malformedLockResult.message == "锁定状态无效", "partial invalid lock state must reject")
expect(equal(malformedLock, malformedLockBefore), "invalid lock state must be atomic")

-- Every upgrade kind uses a snapshot-bound expected level/cost. Retrying the
-- old intent after success rejects before settlement and therefore cannot spend
-- another coin. A fresh snapshot intent remains usable.
local upgradeKinds = {"hooks", "luck", "coins", "tank", "bag"}
for _, kind in ipairs(upgradeKinds) do
	local profile = Model.new(0)
	profile.coins = 100000000
	local beforeInfo = Model.snapshot(profile, 0).upgrades[kind]
	expect(beforeInfo.cost ~= nil, kind .. " fixture must not start at cap")
	local first = Model.command(profile, "upgrade", {kind = kind, expectedLevel = beforeInfo.level, expectedCost = beforeInfo.cost}, 0)
	expect(first.ok, kind .. " current upgrade intent must succeed")
	local coinsAfterFirst = profile.coins
	local levelAfterFirst = Model.snapshot(profile, 0).upgrades[kind].level
	local replay = Model.command(profile, "upgrade", {kind = kind, expectedLevel = beforeInfo.level, expectedCost = beforeInfo.cost}, 0)
	expect(not replay.ok and replay.message == "升级状态已变化，请刷新", kind .. " stale replay must reject")
	expect(profile.coins == coinsAfterFirst, kind .. " stale replay must not deduct coins")
	expect(Model.snapshot(profile, 0).upgrades[kind].level == levelAfterFirst, kind .. " stale replay must not increment level")
	local nextInfo = Model.snapshot(profile, 0).upgrades[kind]
	local second = Model.command(profile, "upgrade", {kind = kind, expectedLevel = nextInfo.level, expectedCost = nextInfo.cost}, 0)
	expect(second.ok, kind .. " refreshed upgrade intent must succeed")
end

local staleCostProfile = Model.new(0)
staleCostProfile.coins = 1000000
local staleCostInfo = Model.snapshot(staleCostProfile, 0).upgrades.hooks
local staleCostBefore = clone(staleCostProfile)
local staleCost = Model.command(staleCostProfile, "upgrade", {kind = "hooks", expectedLevel = staleCostInfo.level, expectedCost = staleCostInfo.cost + 1}, 0)
expect(not staleCost.ok and staleCost.message == "升级状态已变化，请刷新", "stale upgrade cost must reject")
expect(equal(staleCostProfile, staleCostBefore), "stale upgrade cost must be atomic")

local staleLevelProfile = Model.new(0)
staleLevelProfile.coins = 1000000
local staleLevelInfo = Model.snapshot(staleLevelProfile, 0).upgrades.luck
local staleLevelBefore = clone(staleLevelProfile)
local staleLevel = Model.command(staleLevelProfile, "upgrade", {kind = "luck", expectedLevel = staleLevelInfo.level + 1, expectedCost = staleLevelInfo.cost}, 0)
expect(not staleLevel.ok and staleLevel.message == "升级状态已变化，请刷新", "stale upgrade level must reject")
expect(equal(staleLevelProfile, staleLevelBefore), "stale upgrade level must be atomic")

local partialUpgrade = Model.new(0)
local partialInfo = Model.snapshot(partialUpgrade, 0).upgrades.hooks
local partialUpgradeResult = Model.command(partialUpgrade, "upgrade", {kind = "hooks", expectedLevel = partialInfo.level}, 0)
expect(not partialUpgradeResult.ok and partialUpgradeResult.message == "升级确认无效", "partial upgrade intent must reject")
local invalidUpgrade = Model.new(0)
local invalidInfo = Model.snapshot(invalidUpgrade, 0).upgrades.hooks
for _, value in ipairs({0 / 0, math.huge, -math.huge, -1}) do
	local before = clone(invalidUpgrade)
	local invalid = Model.command(invalidUpgrade, "upgrade", {kind = "hooks", expectedLevel = invalidInfo.level, expectedCost = value}, 0)
	expect(not invalid.ok and invalid.message == "升级确认无效", "invalid upgrade cost must reject")
	expect(equal(invalidUpgrade, before), "invalid upgrade cost must be atomic")
end

print("MutationIntent.spec: network intent gate, explicit lock state, five upgrade kinds, stale replay and atomic rejection PASS")
