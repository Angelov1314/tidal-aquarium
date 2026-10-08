local UiRepair = require("../src/client/UiRepair")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local fish = {
	{id = "f1", species = "white_koi", level = 1, placed = false, locked = false},
	{id = "f2", species = "white_koi", level = 1, placed = true, locked = false},
	{id = "f3", species = "white_koi", level = 1, placed = false, locked = false},
}
expect(UiRepair.countUnplaced(fish) == 2, "bag count excludes placed fish")
expect(UiRepair.countPlaced(fish) == 1, "placed count is separate")

local merge = UiRepair.mergeState(fish)
expect(merge.enabled and merge.hasPlaced and merge.requiresPlacedConfirmation, "placed fish remains valid merge material with explicit confirmation")
for index = 1, 3 do
	local showcasedMerge = UiRepair.mergeState({fish[1], fish[2], fish[3]}, {showcaseFishId = fish[index].id})
	expect(not showcasedMerge.enabled and showcasedMerge.reason == "展示中的鱼不能消耗，请先收起展示", "merge blocks each showcased material position " .. tostring(index))
end
local mismatched = {fish[1], fish[2], {species = "blue_tang", level = 1, placed = false}}
expect(not UiRepair.mergeState(mismatched).enabled, "mixed species cannot merge")
local locked = {fish[1], fish[2], {species = "white_koi", level = 1, placed = false, locked = true}}
expect(not UiRepair.mergeState(locked).enabled, "locked material cannot merge")
expect(#UiRepair.selectionAfterResponse({"f1", "f2", "f3"}, {"f1", "f2"}, false) == 3, "failed merge preserves selection")
local afterSuccess = UiRepair.selectionAfterResponse({"f1", "f2", "f3"}, {"f1", "f2"}, true)
expect(#afterSuccess == 1 and afterSuccess[1] == "f3", "successful merge clears only submitted selection")

local fullTank = UiRepair.actionState("place", fish[1], {placedCount = 10, tankCapacity = 10})
expect(not fullTank.enabled and fullTank.reason == "水族馆已满", "full tank disables placement with reason")
local fullBag = UiRepair.actionState("remove", fish[2], {bagCount = 300, bagCapacity = 300})
expect(not fullBag.enabled and fullBag.reason == "背包已满", "full bag disables removal with reason")
local protected = UiRepair.actionState("sell", fish[2], {})
expect(not protected.enabled and protected.reason == "已入缸，先移出水族馆", "placed fish cannot be sold")
local showcased = UiRepair.actionState("sell", fish[1], {showcaseFishId = "f1"})
expect(not showcased.enabled and showcased.reason == "展示中的鱼不能消耗，请先收起展示", "showcased fish cannot be sold")
local missingSaleQuote = UiRepair.actionState("sell", fish[1], {requireSaleQuote = true})
expect(not missingSaleQuote.enabled and missingSaleQuote.reason == "售价待同步，请刷新", "sale confirmation requires an authoritative quote")
local quotedFish = {id = "q1", species = "white_koi", level = 1, value = 10, income = 2, weightGrams = 5, trait = "ordinary", salePrice = 12, placed = false, locked = false}
local confirmationKey = UiRepair.saleConfirmationKey(quotedFish, nil)
expect(UiRepair.saleConfirmationState(quotedFish, 12, confirmationKey, nil).enabled, "unchanged fish and quote preserve sale confirmation")
local changedQuote = table.clone(quotedFish); changedQuote.salePrice = 13
expect(not UiRepair.saleConfirmationState(changedQuote, 12, confirmationKey, nil).enabled, "changed quote clears sale confirmation")
local showcasedQuote = table.clone(quotedFish)
expect(not UiRepair.saleConfirmationState(showcasedQuote, 12, confirmationKey, "q1").enabled, "showcase change clears sale confirmation")
local placedQuote = table.clone(quotedFish); placedQuote.placed = true
expect(not UiRepair.saleConfirmationState(placedQuote, 12, confirmationKey, nil).enabled, "placement change clears sale confirmation")
local poor = UiRepair.actionState("upgrade", nil, {coins = 4, upgrade = {level = 0, max = 5, cost = 5}})
expect(not poor.enabled and poor.reason == "金币不足", "insufficient coins disables upgrade")
local fullMerge = UiRepair.mergeState({
	{species = "white_koi", level = 1, placed = true},
	{species = "white_koi", level = 1, placed = true},
	{species = "white_koi", level = 1, placed = true},
}, {bagCount = 300, bagCapacity = 300})
expect(not fullMerge.enabled and fullMerge.reason == "背包空间不足", "full bag disables all-placed merge")
local fullCatch = UiRepair.actionState("toggleFishing", nil, {currentZone = 1, bagCount = 300, bagCapacity = 300, hooks = 1})
expect(not fullCatch.enabled and fullCatch.reason == "背包空间不足", "full bag disables fishing")
local fullContract = UiRepair.actionState("contract", nil, {ready = true, bagCount = 298, bagCapacity = 300})
expect(not fullContract.enabled and fullContract.reason == "背包空间不足", "full bag disables contract")
local customContract = UiRepair.actionState("contract", nil, {ready = true, rewardFishCount = 2, bagCount = 298, bagCapacity = 300})
expect(customContract.enabled and Config.Contract.rewardFishCount == 3, "contract count defaults to shared config and accepts caller override")

local lowLevelUnlock = UiRepair.actionState("unlock", nil, {
	next = true,
	level = 4,
	requiredLevel = 10,
	coins = 999999,
	cost = 450000,
	discoveryCount = 99,
	requiredDiscoveries = 36,
})
expect(not lowLevelUnlock.enabled, "level gate disables unlock even with enough coins and discoveries")
expect(string.find(lowLevelUnlock.reason, "当前 Lv.4 / 需要 Lv.10", 1, true) ~= nil, "level gate explains current and required levels")
local lowLevelContext = {
	next = true,
	level = 4,
	requiredLevel = 10,
	coins = 999999,
	cost = 450000,
	discoveryCount = 99,
	requiredDiscoveries = 36,
}
expect(UiRepair.unlockButtonText(lowLevelContext, lowLevelUnlock, false) == "等级不足", "level-gated unlock has a specific disabled label")
local exactUnlock = UiRepair.actionState("unlock", nil, {
	next = true,
	level = 10,
	requiredLevel = 10,
	coins = 450000,
	cost = 450000,
	discoveryCount = 36,
	requiredDiscoveries = 36,
})
expect(exactUnlock.enabled, "unlock is enabled when every condition is exactly satisfied")
expect(UiRepair.unlockButtonText({next = true}, exactUnlock, false) == "解锁", "satisfied unlock has an unlock label")
expect(UiRepair.unlockButtonText({next = true}, exactUnlock, true) == "处理中…", "pending unlock has a waiting label")
expect(UiRepair.unlockRequirements({
	next = true,
	level = 4,
	requiredLevel = 10,
	coins = 100,
	cost = 450000,
	discoveryCount = 6,
	requiredDiscoveries = 36,
}) == "等级 Lv.4/10 · 金币 100/450000 · 发现 6/36", "locked row shows complete current and required conditions")
local prerequisite = UiRepair.actionState("unlock", nil, {
	next = false,
	level = 50,
	requiredLevel = 10,
	coins = 999999,
	cost = 450000,
	discoveryCount = 99,
	requiredDiscoveries = 36,
})
expect(not prerequisite.enabled and prerequisite.reason == "请先解锁前一水域", "future zone stays blocked by its prerequisite")
expect(UiRepair.unlockButtonText({next = false}, prerequisite, false) == "前置未解锁", "future zone has a specific prerequisite label")
expect(string.find(UiRepair.unlockRequirements({
	next = false,
	level = 50,
	requiredLevel = 10,
	coins = 999999,
	cost = 450000,
	discoveryCount = 99,
	requiredDiscoveries = 36,
}), "前置水域未解锁", 1, true) == 1, "future zone explains the prerequisite while retaining conditions")
expect(UiRepair.unlockRequirements({unlocked = true}) == "已解锁", "unlocked zone keeps a clear travel state")
expect(UiRepair.unlockButtonText({unlocked = true}, UiRepair.actionState("travel", nil, {unlocked = true}), false) == "前往", "unlocked zone has a travel label")

local recipe = {fishCount = 3, minRarity = 2, requiredLevel = 1}
local exchangeFish = {
	{id = "e1", species = "white_koi", level = 1, rarity = 2, salePrice = 90, placed = false, locked = false},
	{id = "e2", species = "jade_tetra", level = 1, rarity = 3, salePrice = 30, placed = false, locked = false},
	{id = "e3", species = "azure_seahorse", level = 1, rarity = 2, salePrice = 60, placed = false, locked = false},
	{id = "e4", species = "white_koi", level = 2, rarity = 4, salePrice = 1, placed = false, locked = false},
	{id = "e5", species = "white_koi", level = 1, rarity = 4, salePrice = 2, placed = true, locked = false},
	{id = "e6", species = "white_koi", level = 1, rarity = 4, salePrice = 3, placed = false, locked = true},
}
expect(UiRepair.exchangeFishState(exchangeFish[1], recipe, 2).enabled, "eligible Lv1 unplaced fish can exchange")
expect(not UiRepair.exchangeFishState(exchangeFish[4], recipe, 4).enabled, "wrong level cannot exchange")
expect(not UiRepair.exchangeFishState(exchangeFish[5], recipe, 4).enabled, "placed fish cannot exchange")
local cheapest = UiRepair.selectCheapestExchangeFish(exchangeFish, recipe, function(fish) return fish.rarity end)
expect(#cheapest == 3 and cheapest[1] == "e2" and cheapest[2] == "e3" and cheapest[3] == "e1", "auto exchange picks three cheapest eligible fish")
local selectedExchange = UiRepair.selectionByIds(exchangeFish, {"e1", "e2", "e3"})
expect(UiRepair.exchangeSelectionState(selectedExchange, recipe, {e1 = 2, e2 = 3, e3 = 2}).enabled, "different species can form an exchange")
expect(not UiRepair.exchangeSelectionState(selectedExchange, recipe, {e1 = 2, e2 = 3, e3 = 2}, "e1").enabled, "showcased exchange material is blocked")
local duplicateExchange = UiRepair.selectionByIds(exchangeFish, {"e1", "e1", "e2"})
expect(not UiRepair.exchangeSelectionState(duplicateExchange, recipe, {e1 = 2, e2 = 3}).enabled, "duplicate exchange IDs are rejected")

local rarityContext = {e1 = 2, e2 = 3, e3 = 2, e4 = 4, e5 = 4, e6 = 4}
local stableExchange = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, exchangeFish, recipe, rarityContext, nil)
local stableRepeat = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, exchangeFish, recipe, rarityContext, nil)
expect(not stableExchange.changed and stableExchange.key == stableRepeat.key, "unchanged exchange materials preserve the same confirmation key")
local unrelatedFish = {}
for _, item in ipairs(exchangeFish) do
	local copy = table.clone(item)
	if copy.id == "e4" then copy.locked = true end
	table.insert(unrelatedFish, copy)
end
local unrelatedChange = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, unrelatedFish, recipe, rarityContext, nil)
expect(not unrelatedChange.changed and unrelatedChange.key == stableExchange.key, "unselected fish changes do not clear exchange confirmation")
local lockedMaterial = {}
for _, item in ipairs(exchangeFish) do
	local copy = table.clone(item)
	if copy.id == "e2" then copy.locked = true end
	table.insert(lockedMaterial, copy)
end
local lockedReconciled = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, lockedMaterial, recipe, rarityContext, nil)
expect(lockedReconciled.changed and #lockedReconciled.ids == 2 and lockedReconciled.ids[1] == "e1" and lockedReconciled.ids[2] == "e3", "locked selected material is pruned and invalidates confirmation")
local showcasedReconciled = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, exchangeFish, recipe, rarityContext, "e2")
expect(showcasedReconciled.changed and #showcasedReconciled.ids == 2 and showcasedReconciled.ids[1] == "e1" and showcasedReconciled.ids[2] == "e3", "showcased selected material is pruned")
local missingReconciled = UiRepair.reconcileExchangeSelection({"e1", "missing", "e3"}, exchangeFish, recipe, rarityContext, nil)
expect(missingReconciled.changed and #missingReconciled.ids == 2 and missingReconciled.ids[1] == "e1" and missingReconciled.ids[2] == "e3", "missing selected material is pruned")
local stricterRecipe = {id = "exchange_strict", fishCount = 3, minRarity = 3, requiredLevel = 1}
local recipeReconciled = UiRepair.reconcileExchangeSelection({"e1", "e2", "e3"}, exchangeFish, stricterRecipe, rarityContext, nil)
expect(recipeReconciled.changed and #recipeReconciled.ids == 1 and recipeReconciled.ids[1] == "e2" and recipeReconciled.key ~= stableExchange.key, "recipe rarity change prunes ineligible materials and changes the key")
local duplicateReconciled = UiRepair.reconcileExchangeSelection({"e1", "e1", "e2"}, exchangeFish, recipe, rarityContext, nil)
expect(duplicateReconciled.changed and #duplicateReconciled.ids == 2, "duplicate selected material is deduplicated")

local queue = {}
local transitions = {}
local calls = 0
local completed = {}
local gate = UiRepair.newRequestGate(function(fn)
	table.insert(queue, fn)
end, function(action, pending)
	table.insert(transitions, action .. ":" .. tostring(pending))
end)

expect(gate:begin("merge", function()
	calls += 1
	return {ok = false, message = "拒绝"}
end, function(ok, result)
	table.insert(completed, {ok = ok, result = result})
end), "first request accepted")
expect(gate:isPending("merge") and gate:anyPending(), "pending is visible before spawn runs")
expect(not gate:begin("merge", function()
	calls += 1
end, function() end), "duplicate request is suppressed synchronously")
expect(calls == 0, "duplicate guard runs before the scheduler")
expect(not gate:begin("sell", function()
	calls += 1
end, function() end), "different mutation is also blocked while one is pending")
queue[1]()
expect(calls == 1 and not gate:isPending("merge"), "request completes and releases guard")
expect(#completed == 1 and completed[1].ok and completed[1].result.ok == false, "failed response reaches caller for retry")

expect(gate:begin("merge", function()
	calls += 1
	return {ok = true}
end, function(ok, result)
	table.insert(completed, {ok = ok, result = result})
end), "retry after failure is accepted")
queue[2]()
expect(calls == 2 and #completed == 2 and completed[2].result.ok, "successful retry completes")

expect(gate:begin("sell", function() error("transport") end, function(ok) table.insert(completed, {ok = ok}) end), "transport attempt accepted")
queue[3]()
expect(not completed[3].ok and not gate:anyPending(), "transport failure releases the guard")
expect(transitions[1] == "merge:true" and transitions[2] == "merge:false", "pending callbacks are ordered")

local unlockQueue = {}
local unlockGate = UiRepair.newRequestGate(function(fn)
	table.insert(unlockQueue, fn)
end)
expect(unlockGate:begin("unlock", function() return {ok = true} end, function() end), "unlock request enters pending state")
expect(unlockGate:isPending("unlock") and not unlockGate:begin("unlock", function() error("duplicate unlock") end, function() end), "pending unlock suppresses duplicate input")
unlockQueue[1]()
expect(not unlockGate:isPending("unlock"), "unlock pending state clears after response")

print("UiRepair.spec: bag, merge, unlock level gate, availability, duplicate suppression and retry PASS")
