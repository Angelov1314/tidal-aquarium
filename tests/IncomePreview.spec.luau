local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function near(actual, expected, tolerance, message)
	expect(type(actual) == "number" and type(expected) == "number" and math.abs(actual - expected) <= tolerance, message or string.format("expected %.8f near %.8f", actual, expected))
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, child in pairs(value) do copied[key] = clone(child) end
	return copied
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not equal(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function snapshot(profile, now)
	local result = Model.snapshot(profile, now)
	expect(result.ok, "fixture snapshot must validate")
	return result
end

local function assertUnchanged(profile, before, message)
	expect(equal(profile, before), message or "income preview must not mutate profile")
end

local function previewChecked(profile, now, request)
	local before = clone(profile)
	local preview = Model.incomePreview(profile, now, request)
	assertUnchanged(profile, before, "income preview must not mutate profile")
	return preview
end

-- Place preview agrees with a real command on a cloned profile and leaves the
-- source profile, settlement cursor, and IDs untouched.
local placeProfile = Model.new(0)
local placeBefore = clone(placeProfile)
local place = previewChecked(placeProfile, 10, {kind = "fish", action = "place", id = "f1"})
expect(place.ok and place.allowed and place.reason == "", "place preview should be allowed")
near(place.currentTotalPerHour, 0, 1e-9)
near(place.projectedTotalPerHour, 1, 1e-9)
near(place.deltaPerHour, 1, 1e-9)
near(place.fishBasePerHour, 1, 1e-9)
near(place.currentFishPerHour, 0, 1e-9)
near(place.projectedFishPerHour, 1, 1e-9)
expect(place.showcaseBeforeId == nil and place.showcaseAfterId == nil, "place showcase IDs")
assertUnchanged(placeProfile, placeBefore)
local placedClone = clone(placeProfile)
expect(Model.command(placedClone, "place", {id = "f1"}, 10).ok, "place command fixture")
near(place.projectedTotalPerHour, snapshot(placedClone, 10).incomePerHour, 1e-9, "place preview must match command snapshot")

-- Removing the only placed fish has the same current/projected contribution as
-- the authoritative snapshot and command, without settling the source.
local removeProfile = Model.new(0)
removeProfile.fish[1].placed = true
local removeBefore = clone(removeProfile)
local removeCurrent = snapshot(removeProfile, 10)
local remove = previewChecked(removeProfile, 10, {kind = "fish", action = "remove", id = "f1"})
expect(remove.ok and remove.allowed, "remove preview should be allowed")
near(remove.currentTotalPerHour, removeCurrent.incomePerHour, 1e-9)
near(remove.currentFishPerHour, removeCurrent.incomePerHour, 1e-9)
near(remove.projectedTotalPerHour, 0, 1e-9)
near(remove.projectedFishPerHour, 0, 1e-9)
assertUnchanged(removeProfile, removeBefore)
local removedClone = clone(removeProfile)
expect(Model.command(removedClone, "remove", {id = "f1"}, 10).ok, "remove command fixture")
near(remove.projectedTotalPerHour, snapshot(removedClone, 10).incomePerHour, 1e-9, "remove preview must match command snapshot")

-- All income multipliers are read at the preview timestamp. The same fixture
-- crosses coin-item and paid-boost expiry without duplicating their formula.
local boostProfile = Model.new(0)
boostProfile.fish[1].placed = true
boostProfile.coinLevel = 2
boostProfile.doubleIncome = true
boostProfile.boostUntil = 100
boostProfile.activeBoosts.coins = {itemId = "coin_tonic", untilTime = 80}
local boostAt79 = snapshot(boostProfile, 79)
local boostPreview79 = previewChecked(boostProfile, 79, {kind = "fish", action = "remove", id = "f1"})
near(boostPreview79.currentTotalPerHour, boostAt79.incomePerHour, 1e-9, "active multipliers use snapshot rate")
expect(boostAt79.activeBoosts.coins ~= nil and boostPreview79.currentFishPerHour > 0, "active coin item should contribute")
local boostAt80 = snapshot(boostProfile, 80)
local boostPreview80 = previewChecked(boostProfile, 80, {kind = "fish", action = "remove", id = "f1"})
expect(boostAt80.activeBoosts.coins == nil, "coin item expires at exact timestamp")
near(boostPreview80.currentTotalPerHour, boostAt80.incomePerHour, 1e-9, "coin item expiry uses snapshot rate")
expect(boostAt80.incomePerHour < boostAt79.incomePerHour, "coin item expiry must reduce current rate")
local boostAt100 = snapshot(boostProfile, 100)
local boostPreview100 = previewChecked(boostProfile, 100, {kind = "fish", action = "remove", id = "f1"})
near(boostPreview100.currentTotalPerHour, boostAt100.incomePerHour, 1e-9, "paid boost expiry uses snapshot rate")
expect(boostAt100.incomePerHour < boostAt80.incomePerHour, "paid boost expiry must reduce current rate")

-- A showcased gilded fish can make placing that fish reduce the total: the
-- scenario removes its old global +5% before adding its own base income.
local gildedProfile = Model.new(0)
gildedProfile.fish[1].placed = true
gildedProfile.fish[1].income = 100
gildedProfile.fish[2].trait = "gilded"
gildedProfile.fish[2].income = 1
gildedProfile.showcaseFishId = gildedProfile.fish[2].id
local gildedBefore = snapshot(gildedProfile, 0)
local gildedProfileBefore = clone(gildedProfile)
local gildedPreview = previewChecked(gildedProfile, 0, {kind = "fish", action = "place", id = "f2"})
expect(gildedPreview.ok and gildedPreview.allowed and gildedPreview.showcaseBeforeId == "f2" and gildedPreview.showcaseAfterId == nil, "placing showcased fish removes showcase")
expect(gildedPreview.showcaseBonusBefore > 0 and gildedPreview.showcaseBonusAfter == 0, "showcase bonus transition")
local gildedClone = clone(gildedProfile)
expect(Model.command(gildedClone, "place", {id = "f2"}, 0).ok, "gilded place command fixture")
local gildedAfter = snapshot(gildedClone, 0)
near(gildedPreview.currentTotalPerHour, gildedBefore.incomePerHour, 1e-9)
near(gildedPreview.projectedTotalPerHour, gildedAfter.incomePerHour, 1e-9)
expect(gildedPreview.deltaPerHour < 0, "placing low-income showcased fish can lower total rate")
assertUnchanged(gildedProfile, gildedProfileBefore)

-- Showcase replacement and hiding use the same scenario calculation. Hiding
-- with no current showcase is a valid no-op preview.
local showcaseProfile = Model.new(0)
showcaseProfile.fish[1].placed = true
showcaseProfile.fish[1].income = 100
showcaseProfile.fish[2].trait = "gilded"
showcaseProfile.showcaseFishId = "f2"
local replacement = previewChecked(showcaseProfile, 0, {kind = "fish", action = "showcase", id = "f3"})
expect(replacement.ok and replacement.allowed and replacement.showcaseBeforeId == "f2" and replacement.showcaseAfterId == "f3", "showcase replacement IDs")
local replacementClone = clone(showcaseProfile)
expect(Model.command(replacementClone, "showcase", {id = "f3"}, 0).ok, "showcase replacement command fixture")
near(replacement.projectedTotalPerHour, snapshot(replacementClone, 0).incomePerHour, 1e-9)
local hide = previewChecked(showcaseProfile, 0, {kind = "fish", action = "hideFish"})
expect(hide.ok and hide.allowed and hide.showcaseBeforeId == "f2" and hide.showcaseAfterId == nil, "hide showcase IDs")
local hideClone = clone(showcaseProfile)
expect(Model.command(hideClone, "hideFish", {}, 0).ok, "hide showcase command fixture")
near(hide.projectedTotalPerHour, snapshot(hideClone, 0).incomePerHour, 1e-9)
local noShowcaseProfile = Model.new(0)
local noShowcase = previewChecked(noShowcaseProfile, 0, {kind = "fish", action = "hideFish"})
expect(noShowcase.ok and noShowcase.allowed and noShowcase.showcaseBeforeId == nil and noShowcase.showcaseAfterId == nil, "hide without showcase is a valid no-op")

-- Merge of placed sources removes their current income and creates one
-- unplaced result. resultBasePerHour is compared only with the real command.
local mergeProfile = Model.new(0)
for _, fish in ipairs(mergeProfile.fish) do fish.placed = true end
mergeProfile.fish[1].income, mergeProfile.fish[2].income, mergeProfile.fish[3].income = 1, 2, 3
local mergeBefore = clone(mergeProfile)
local mergeRequest = {kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3"}}
local merge = previewChecked(mergeProfile, 0, mergeRequest)
expect(merge.ok and merge.allowed and merge.showcaseBeforeId == nil and merge.showcaseAfterId == nil, "placed merge preview should be allowed")
local mergeClone = clone(mergeProfile)
local mergeCommand = Model.command(mergeClone, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3"}}, 0)
expect(mergeCommand.ok, "placed merge command fixture")
local mergeAfter = snapshot(mergeClone, 0)
near(merge.currentTotalPerHour, snapshot(mergeProfile, 0).incomePerHour, 1e-9)
near(merge.projectedTotalPerHour, mergeAfter.incomePerHour, 1e-9)
near(merge.resultBasePerHour, mergeCommand.fish[1].income, 1e-9, "merge base result must come from command")
assertUnchanged(mergeProfile, mergeBefore)

-- Capacity failures expose a hypothetical number but never pretend the
-- blocked command is allowed.
local fullTank = Model.new(0)
fullTank.tankCapacity = 10
for _, fish in ipairs(fullTank.fish) do fish.placed = true end
fullTank.hooks = 8
local caught = Model.command(fullTank, "catch", {zone = 1}, 0, function() return 0 end)
expect(caught.ok and #caught.fish == 8 and caught.fish[1].id == "f4", "full tank candidate fixture")
for idNumber = 5, 11 do
	expect(Model.command(fullTank, "place", {id = "f" .. tostring(idNumber)}, 0).ok, "full tank filler placement")
end
local fullTankBefore = clone(fullTank)
local tankPreview = previewChecked(fullTank, 0, {kind = "fish", action = "place", id = "f4"})
expect(tankPreview.ok and not tankPreview.allowed and tankPreview.reason == "水族馆已满", "full tank must be an explicit capacity block")
local hypotheticalTank = clone(fullTank)
hypotheticalTank.tankCapacity = 11
expect(Model.command(hypotheticalTank, "place", {id = "f4"}, 0).ok, "hypothetical tank placement")
near(tankPreview.projectedTotalPerHour, snapshot(hypotheticalTank, 0).incomePerHour, 1e-9, "full tank projection is hypothetical")
assertUnchanged(fullTank, fullTankBefore)

local fullBag = Model.new(0)
fullBag.bagCapacity = 300
fullBag.hooks = 100
for _, fish in ipairs(fullBag.fish) do fish.placed = true end
for round = 1, 3 do
	local batch = Model.command(fullBag, "catch", {zone = 1}, round, function() return .5 end)
	expect(batch.ok and #batch.fish == 100, "full bag batch fixture")
end
local fullBagBefore = clone(fullBag)
local bagPreview = previewChecked(fullBag, 3, {kind = "fish", action = "remove", id = "f1"})
expect(bagPreview.ok and not bagPreview.allowed and bagPreview.reason == "背包空间不足", "full bag must be an explicit capacity block")
local mergeBagPreview = previewChecked(fullBag, 3, {kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3"}})
expect(mergeBagPreview.ok and not mergeBagPreview.allowed and mergeBagPreview.reason == "背包空间不足", "full bag must block merge of placed materials")
local hypotheticalBag = clone(fullBag)
hypotheticalBag.bagCapacity = 400
expect(Model.command(hypotheticalBag, "remove", {id = "f1"}, 3).ok, "hypothetical bag removal")
near(bagPreview.projectedTotalPerHour, snapshot(hypotheticalBag, 3).incomePerHour, 1e-9, "full bag projection is hypothetical")
assertUnchanged(fullBag, fullBagBefore)

-- Zero base income stays finite and does not create a divide-by-zero path.
local zero = Model.new(0)
zero.fish[1].placed = true
zero.fish[1].income = 0
local zeroPreview = previewChecked(zero, 0, {kind = "fish", action = "remove", id = "f1"})
for _, key in ipairs({"currentTotalPerHour", "projectedTotalPerHour", "deltaPerHour", "fishBasePerHour", "currentFishPerHour", "projectedFishPerHour"}) do
	if zeroPreview[key] ~= nil then expect(finite(zeroPreview[key]), "zero-income preview must stay finite: " .. key) end
end
near(zeroPreview.currentFishPerHour, 0, 1e-9)
near(zeroPreview.projectedFishPerHour, 0, 1e-9)

-- A v1 profile with missing optional metadata keeps frozen income/value and is
-- not migrated or otherwise mutated by the read-only preview.
local legacy = Model.new(0)
legacy.version = 1
legacy.items, legacy.activeBoosts, legacy.requestReceipts = nil, nil, nil
legacy.mutationProtocol, legacy.mutationWatermarks = nil, nil
legacy.fish[1].weightGrams, legacy.fish[1].trait, legacy.fish[1].catchZone, legacy.fish[1].caughtAt, legacy.fish[1].catchSource = nil, nil, nil, nil, nil
local legacyBefore = clone(legacy)
local legacyPreview = previewChecked(legacy, 0, {kind = "fish", action = "place", id = "f1"})
expect(legacyPreview.ok and legacyPreview.allowed and legacy.version == 1, "legacy preview compatibility")
near(legacyPreview.fishBasePerHour, legacyBefore.fish[1].income, 1e-9)
assertUnchanged(legacy, legacyBefore)

-- Malformed times, unknown/duplicate IDs, and invalid materials are explicit
-- errors and never expose an executable-looking projection.
local invalid = Model.new(0)
local badTime = previewChecked(invalid, -1, {kind = "fish", action = "place", id = "f1"})
expect(not badTime.ok and not badTime.allowed and badTime.reason == "时间无效", "invalid time reason")
local unknown = previewChecked(invalid, 0, {kind = "fish", action = "place", id = "missing"})
expect(not unknown.ok and unknown.reason == "找不到鱼", "unknown fish reason")
local duplicate = previewChecked(invalid, 0, {kind = "merge", ids = {"f1", "f1", "f2"}})
expect(not duplicate.ok and duplicate.reason == "合成材料无效", "duplicate merge reason")
local mismatch = Model.new(0)
mismatch.fish[3].species = Config.Species[2].id
local mismatchPreview = previewChecked(mismatch, 0, {kind = "merge", ids = {"f1", "f2", "f3"}})
expect(not mismatchPreview.ok and mismatchPreview.reason == "需要同物种同等级", "mismatched merge reason")
local locked = Model.new(0)
locked.fish[2].locked = true
local lockedPreview = previewChecked(locked, 0, {kind = "merge", ids = {"f1", "f2", "f3"}})
expect(not lockedPreview.ok and lockedPreview.reason == "合成材料不可用", "locked merge reason")

-- Executable commands settle before mutating these actions. A preview at an
-- older timestamp rejects the same way, except for hideFish's intentional
-- no-showcase idempotent no-op.
local stalePlace = Model.new(10)
local stalePlacePreview = previewChecked(stalePlace, 9, {kind = "fish", action = "place", id = "f1"})
expect(not stalePlacePreview.ok and stalePlacePreview.reason == "时间不能倒退", "stale place must reject")
local staleRemove = Model.new(10)
staleRemove.fish[1].placed = true
local staleRemovePreview = previewChecked(staleRemove, 9, {kind = "fish", action = "remove", id = "f1"})
expect(not staleRemovePreview.ok and staleRemovePreview.reason == "时间不能倒退", "stale remove must reject")
local staleShowcase = Model.new(10)
local staleShowcasePreview = previewChecked(staleShowcase, 9, {kind = "fish", action = "showcase", id = "f1"})
expect(not staleShowcasePreview.ok and staleShowcasePreview.reason == "时间不能倒退", "stale showcase must reject")
local staleMerge = Model.new(10)
local staleMergePreview = previewChecked(staleMerge, 9, {kind = "merge", ids = {"f1", "f2", "f3"}})
expect(not staleMergePreview.ok and staleMergePreview.reason == "时间不能倒退", "stale merge must reject")
local staleHide = Model.new(10)
staleHide.showcaseFishId = "f2"
local staleHidePreview = previewChecked(staleHide, 9, {kind = "fish", action = "hideFish"})
expect(not staleHidePreview.ok and staleHidePreview.reason == "时间不能倒退", "stale hide with showcase must reject")
local staleNoShowcase = Model.new(10)
local staleNoShowcasePreview = previewChecked(staleNoShowcase, 9, {kind = "fish", action = "hideFish"})
expect(staleNoShowcasePreview.ok and staleNoShowcasePreview.allowed, "stale hide without showcase remains idempotent")

-- Preview input is an exact three-element array. Sparse arrays and extra
-- keyed fields are rejected rather than being accepted by #ids alone.
local sparseIds = {[1] = "f1", [3] = "f3"}
local sparsePreview = previewChecked(invalid, 0, {kind = "merge", ids = sparseIds})
expect(not sparsePreview.ok and sparsePreview.reason == "需要三条鱼", "sparse merge IDs must reject")
local extraKeyPreview = previewChecked(invalid, 0, {kind = "merge", ids = {"f1", "f2", "f3", label = "extra"}})
expect(not extraKeyPreview.ok and extraKeyPreview.reason == "需要三条鱼", "extra merge keys must reject")

for _, malformedNow in ipairs({0 / 0, math.huge, -math.huge}) do

	local malformedTime = previewChecked(invalid, malformedNow, {kind = "fish", action = "place", id = "f1"})
	expect(not malformedTime.ok and malformedTime.reason == "时间无效", "NaN/Inf preview time must reject")
end

print("IncomePreview.spec: read-only scenarios, expiry, showcase, merge, capacity, legacy, stale-time and invalid-input PASS")
