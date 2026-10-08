local Model = require("../src/shared/Model")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

local function unchanged(profile, before, message)
	expect(equal(profile, before), message or "rejected consumption must be atomic")
end

-- Showcase consumption is a new P1 rejection. These fixtures intentionally
-- exercise the old successful paths before the protection implementation.
local showcasedSell = Model.new(0)
showcasedSell.showcaseFishId = "f1"
local showcasedSellBefore = clone(showcasedSell)
local sellResult = Model.command(showcasedSell, "sell", {id = "f1"}, 0)
expect(not sellResult.ok and sellResult.message == "展示中的鱼不能消耗，请先收起展示", "showcased sell must reject")
unchanged(showcasedSell, showcasedSellBefore)

local showcasedMerge = Model.new(0)
showcasedMerge.showcaseFishId = "f1"
local showcasedMergeBefore = clone(showcasedMerge)
local mergeResult = Model.command(showcasedMerge, "merge", {ids = {"f1", "f2", "f3"}}, 0)
expect(not mergeResult.ok and mergeResult.message == "展示中的鱼不能消耗，请先收起展示", "showcased merge must reject")
unchanged(showcasedMerge, showcasedMergeBefore)

local showcasedExchange = Model.new(0)
showcasedExchange.showcaseFishId = "f1"
local showcasedExchangeBefore = clone(showcasedExchange)
local exchangeResult = Model.command(showcasedExchange, "exchange", {
	recipeId = "exchange_luck",
	ids = {"f1", "f2", "f3"},
	requestId = "consumption-showcase-exchange",
}, 0)
expect(not exchangeResult.ok and exchangeResult.message == "展示中的鱼不能消耗，请先收起展示", "showcased exchange must reject")
unchanged(showcasedExchange, showcasedExchangeBefore)
expect(Model.command(showcasedExchange, "hideFish", {}, 0).ok, "hide showcase must remain available")
expect(Model.command(showcasedExchange, "sell", {id = "f1"}, 0).ok, "hidden fish can sell normally")

-- The guard must run before settlement as well as before deletion.  This
-- fixture has elapsed time and an earning aquarium fish, so a rejected
-- showcased action would otherwise change lastSettled/income state.
for _, action in ipairs({"sell", "merge", "exchange"}) do
	local progressed = Model.new(10)
	if action == "exchange" then
		local caught = Model.command(progressed, "catch", {zone = 1}, 10, function() return .5 end)
		expect(caught.ok and #caught.fish == 1, "progressed exchange fixture catch")
		progressed.fish[4].placed = true
		progressed.fish[4].income = 123
	else
		progressed.fish[2].placed = true
		progressed.fish[2].income = 123
	end
	progressed.showcaseFishId = "f1"
	local before = clone(progressed)
	local payload = if action == "sell" then {id = "f1"} elseif action == "merge" then {ids = {"f1", "f2", "f3"}} else {recipeId = "exchange_luck", ids = {"f1", "f2", "f3"}, requestId = "progressed-" .. action}
	local blocked = Model.command(progressed, action, payload, 20)
	expect(not blocked.ok and blocked.message == "展示中的鱼不能消耗，请先收起展示", action .. " showcase guard must precede settlement")
	unchanged(progressed, before, action .. " showcase rejection must preserve elapsed profile")
end

-- A supplied quote is a confirmation guard, while omitted quotes retain the
-- legacy internal-call compatibility path.
local quoted = Model.new(0)
local quotedFish = quoted.fish[1]
local quote = Model.salePrice(quoted, quotedFish, 0)
local staleQuoteBefore = clone(quoted)
local staleQuote = Model.command(quoted, "sell", {id = quotedFish.id, expectedSalePrice = quote + 1}, 0)
expect(not staleQuote.ok and staleQuote.message == "售价已变化，请重新确认", "changed sale quote must reject")
unchanged(quoted, staleQuoteBefore)
local invalidQuoteBefore = clone(quoted)
local invalidQuote = Model.command(quoted, "sell", {id = quotedFish.id, expectedSalePrice = 0 / 0}, 0)
expect(not invalidQuote.ok and invalidQuote.message == "售价确认无效", "nonfinite sale quote must reject")
unchanged(quoted, invalidQuoteBefore)
for _, badQuote in ipairs({math.huge, -math.huge, -1}) do
	local badProfile = Model.new(0)
	local before = clone(badProfile)
	local bad = Model.command(badProfile, "sell", {id = "f1", expectedSalePrice = badQuote}, 0)
	expect(not bad.ok and bad.message == "售价确认无效", "infinite or negative sale quote must reject")
	unchanged(badProfile, before)
end
local matchingQuote = Model.command(quoted, "sell", {id = quotedFish.id, expectedSalePrice = quote}, 0)
expect(matchingQuote.ok and #quoted.fish == 2, "matching sale quote must consume once")
local coinsAfterSale = quoted.coins
local repeatedSale = Model.command(quoted, "sell", {id = quotedFish.id}, 0)
expect(not repeatedSale.ok and quoted.coins == coinsAfterSale, "selling a removed fish cannot grant again")
local legacySale = Model.new(0)
expect(Model.command(legacySale, "sell", {id = "f1"}, 0).ok, "omitted quote preserves legacy internal callers")

-- An explicit acknowledgement must exactly describe the current placed
-- subset. Its order is irrelevant, but holes, duplicates, extras and stale
-- placed state are rejected without settlement or deletion.
local placed = Model.new(0)
for _, fish in ipairs(placed.fish) do fish.placed = true end
local noAckBefore = clone(placed)
local noAck = Model.command(placed, "merge", {ids = {"f1", "f2", "f3"}}, 0)
expect(not noAck.ok and noAck.message == "请确认移出入缸材料", "placed merge requires acknowledgement")
unchanged(placed, noAckBefore)
local wrongAckBefore = clone(placed)
local wrongAck = Model.command(placed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2"}}, 0)
expect(not wrongAck.ok and wrongAck.message == "入缸确认不完整", "incomplete placed acknowledgement must reject")
unchanged(placed, wrongAckBefore)
local duplicateAckBefore = clone(placed)
local duplicateAck = Model.command(placed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f1", "f2"}}, 0)
expect(not duplicateAck.ok and duplicateAck.message == "入缸确认无效", "duplicate placed acknowledgement must reject")
unchanged(placed, duplicateAckBefore)
local extraAckBefore = clone(placed)
local extraAck = Model.command(placed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3", "f99"}}, 0)
expect(not extraAck.ok and extraAck.message == "入缸确认无效", "extra placed acknowledgement must reject")
unchanged(placed, extraAckBefore)
local exactPlaced = Model.command(placed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f3", "f1", "f2"}}, 0)
expect(exactPlaced.ok and #placed.fish == 1 and placed.fish[1].placed == false, "exact placed acknowledgement permits merge")

local mixed = Model.new(0)
mixed.fish[1].placed = true
local mixedWrongBefore = clone(mixed)
local mixedWrong = Model.command(mixed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f2"}}, 0)
expect(not mixedWrong.ok and mixedWrong.message == "入缸确认无效", "acknowledgement cannot name unplaced source")
unchanged(mixed, mixedWrongBefore)
local mixedExact = Model.command(mixed, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1"}}, 0)
expect(mixedExact.ok, "mixed exact acknowledgement permits merge")

local staleAck = Model.new(0)
staleAck.fish[1].placed = true
staleAck.fish[2].placed = true
staleAck.fish[3].placed = false
staleAck.fish[1].placed = false
local staleAckBefore = clone(staleAck)
local staleAckResult = Model.command(staleAck, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2"}}, 0)
expect(not staleAckResult.ok and staleAckResult.message == "入缸确认无效", "stale placed acknowledgement must reject")
unchanged(staleAck, staleAckBefore)

local malformedAck = Model.new(0)
for _, fish in ipairs(malformedAck.fish) do fish.placed = true end
local holeAck = Model.command(malformedAck, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {[1] = "f1", [3] = "f3"}}, 0)
expect(not holeAck.ok and holeAck.message == "入缸确认无效", "hole in placed acknowledgement must reject")
local extraKeyAck = Model.command(malformedAck, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3", note = "unexpected"}}, 0)
expect(not extraKeyAck.ok and extraKeyAck.message == "入缸确认无效", "extra acknowledgement key must reject")
local extraMergeKey = Model.command(Model.new(0), "merge", {ids = {"f1", "f2", "f3", note = "unexpected"}}, 0)
expect(not extraMergeKey.ok and extraMergeKey.message == "需要三条鱼", "extra merge ID key must reject")

local ordinaryMerge = Model.new(0)
local ordinaryMergeResult = Model.command(ordinaryMerge, "merge", {ids = {"f1", "f2", "f3"}}, 0)
expect(ordinaryMergeResult.ok, "unplaced merge keeps omitted acknowledgement compatibility")

-- Preview uses the same qualifications without mutating state and agrees with
-- a real command after a valid acknowledgement.
local previewShowcase = Model.new(0)
previewShowcase.showcaseFishId = "f1"
local previewShowcaseBefore = clone(previewShowcase)
local blockedPreview = Model.incomePreview(previewShowcase, 0, {kind = "merge", ids = {"f1", "f2", "f3"}})
expect(blockedPreview.ok and not blockedPreview.allowed and blockedPreview.reason == "展示中的鱼不能消耗，请先收起展示", "preview blocks showcased material")
unchanged(previewShowcase, previewShowcaseBefore, "showcase preview is read-only")
local previewPlaced = Model.new(0)
for _, fish in ipairs(previewPlaced.fish) do fish.placed = true end
local missingAckPreviewBefore = clone(previewPlaced)
local missingAckPreview = Model.incomePreview(previewPlaced, 0, {kind = "merge", ids = {"f1", "f2", "f3"}})
expect(missingAckPreview.ok and not missingAckPreview.allowed and missingAckPreview.reason == "请确认移出入缸材料", "preview blocks missing placed acknowledgement")
unchanged(previewPlaced, missingAckPreviewBefore, "placed acknowledgement preview is read-only")
local exactPreview = Model.incomePreview(previewPlaced, 0, {kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3"}})
expect(exactPreview.ok and exactPreview.allowed, "preview accepts exact placed acknowledgement")
local previewClone = clone(previewPlaced)
local previewCommand = Model.command(previewClone, "merge", {ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1", "f2", "f3"}}, 0)
expect(previewCommand.ok, "preview comparison command succeeds")
local previewSnapshot = Model.snapshot(previewClone, 0)
expect(exactPreview.projectedTotalPerHour == previewSnapshot.incomePerHour, "acknowledged preview matches command snapshot")

print("ConsumptionProtection.spec: showcase, sale quote, placed acknowledgement, preview and atomicity PASS")
