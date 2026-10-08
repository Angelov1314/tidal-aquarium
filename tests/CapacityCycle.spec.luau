local Model = require("../src/shared/Model")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function count(profile, placed)
	local total = 0
	for _, fish in ipairs(profile.fish) do
		if fish.placed == placed then total += 1 end
	end
	return total
end

-- The intentional placed-material merge must conserve the three source records,
-- remove them from the tank, and create exactly one unplaced result.
local placedMerge = Model.new(0)
local placedIds = {placedMerge.fish[1].id, placedMerge.fish[2].id, placedMerge.fish[3].id}
for _, fish in ipairs(placedMerge.fish) do fish.placed = true end
local merged = Model.command(placedMerge, "merge", {ids = placedIds, acknowledgedPlacedIds = placedIds}, 1)
expect(merged.ok and #placedMerge.fish == 1, "placed merge should consume exactly three sources")
expect(count(placedMerge, true) == 0 and count(placedMerge, false) == 1, "placed merge result must return to the bag")
expect(Model.validate(placedMerge), "placed merge result must remain valid")

-- Fill exactly 300 bag slots with three placed starters, then lower the legal
-- capacity to that exact count. A merge of three placed sources would add one
-- bag item and must fail atomically without removing tank fish.
local full = Model.new(0)
local fullIds = {full.fish[1].id, full.fish[2].id, full.fish[3].id}
for _, fish in ipairs(full.fish) do fish.placed = true end
full.hooks = 100
full.bagCapacity = 3000
for round = 1, 3 do
	local caught = Model.command(full, "catch", {zone = 1}, round, function() return .5 end)
	expect(caught.ok and #caught.fish == 100, "100-hook fill round must be complete")
end
expect(count(full, false) == 300 and count(full, true) == 3, "fill fixture must have exact 300/3 split")
full.hooks = 1
full.bagCapacity = 300
expect(Model.validate(full), "exact capacity fixture must be valid")
local beforeFish, beforePlaced = #full.fish, count(full, true)
local rejected = Model.command(full, "merge", {ids = fullIds, acknowledgedPlacedIds = fullIds}, 10)
expect(not rejected.ok and #full.fish == beforeFish and count(full, true) == beforePlaced, "full-bag placed merge must reject atomically")
expect(Model.validate(full), "rejected full-bag merge must preserve a valid profile")

print("CapacityCycle.spec: placed merge conservation and exact full-bag atomicity PASS")
