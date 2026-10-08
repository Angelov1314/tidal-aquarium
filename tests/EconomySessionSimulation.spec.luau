local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")
local rngFor = require("../tools/economy_rng")
local Driver = require("../tools/economy_session_driver")

local function expect(condition, message)
	if not condition then error(message or "economy session expectation failed", 2) end
end

local function near(actual, expected, tolerance)
	expect(math.abs(actual - expected) <= tolerance, string.format("expected %.12f near %.12f", actual, expected))
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local baseOptions = {
	seed = 101,
	sessionMinutes = 30,
	days = 1,
	policy = "nurture",
	targetSpecies = "sand_goby",
	maxActions = 500,
	milestoneEvery = 600,
}

local valid, message = Driver.validateOptions(baseOptions, Config)
expect(valid and message == nil, "valid options rejected")
local days45 = clone(baseOptions); days45.days = 45
expect(Driver.validateOptions(days45, Config), "45-day bound must be accepted")
local days46 = clone(baseOptions); days46.days = 46
expect(not Driver.validateOptions(days46, Config), "46-day bound must be rejected")
local badPolicy = clone(baseOptions); badPolicy.policy = "optimized"
expect(not Driver.validateOptions(badPolicy, Config), "unknown policy must be rejected")
local badTarget = clone(baseOptions); badTarget.targetSpecies = "missing_species"
expect(not Driver.validateOptions(badTarget, Config), "unknown target must be rejected")
local badSeed = clone(baseOptions); badSeed.seed = 1.5
expect(not Driver.validateOptions(badSeed, Config), "fractional seed must be rejected")

local randomA, randomB = rngFor(424242), rngFor(424242)
for _ = 1, 12 do near(randomA(), randomB(), 0) end
local invalidSeedOk = pcall(function() rngFor(1.5) end)
expect(not invalidSeedOk, "rng boundary must reject fractional seed")

local starter = Model.new(0)
local starterSnapshot = Model.snapshot(starter, 0)
expect(starterSnapshot.ok and #starterSnapshot.fish == 3, "Model.new starter fixture")
expect(Driver.inventoryBaseUnits(starterSnapshot) == 3, "starter base units")

-- Use real commands to move the three starters into the tank, then merge with
-- the exact placed acknowledgement set. No fish placement field is edited by
-- this conformance fixture.
local placed = Model.new(0)
local placedIds = {}
for _, fish in ipairs(placed.fish) do
	local result = Model.command(placed, "place", { id = fish.id }, 0, function() return 0.5 end)
	expect(result.ok, "place command for merge fixture")
	table.insert(placedIds, fish.id)
end
local mergeBefore = Model.snapshot(placed, 0)
local mergeResult = Model.command(placed, "merge", { ids = placedIds, acknowledgedPlacedIds = placedIds }, 1, function() return 0.5 end)
expect(mergeResult.ok and mergeResult.fish and mergeResult.fish[1].level == 2, "placed merge command")
local mergeAfter = Model.snapshot(placed, 1)
expect(mergeAfter.ok and Driver.inventoryBaseUnits(mergeAfter) == Driver.inventoryBaseUnits(mergeBefore), "merge base units")
expect(#mergeAfter.fish == 1 and not mergeAfter.fish[1].placed, "placed merge output returns to bag")

-- The real offline path advances the settlement cursor, applies its 50%
-- multiplier, expires an active coin boost at 600 seconds, and never credits
-- the same interval twice. With one placed 1/h fish and a 1.5x coin item at
-- t=0, the eight-hour credit is 600*1.5*.5/3600 + 28200*.5/3600.
local offline = Model.new(0)
expect(Model.command(offline, "place", { id = "f1" }, 0, function() return 0.5 end).ok, "offline placement")
local function greenRandom() return 0.65 end
for index = 1, 3 do
	local caughtGreen = Model.command(offline, "catch", { zone = 1 }, 0, greenRandom)
	expect(caughtGreen.ok, "green fixture catch " .. tostring(index))
end
local greenIds = {}
for _, fish in ipairs(offline.fish) do
	if not fish.placed and Config.SpeciesById[fish.species].rarity >= 2 then table.insert(greenIds, fish.id) end
end
expect(#greenIds == 3, "coin boost material fixture")
expect(Model.command(offline, "exchange", { recipeId = "exchange_coins", ids = greenIds, requestId = "offline-coin-exchange" }, 0, greenRandom).ok, "coin exchange")
expect(Model.command(offline, "useItem", { itemId = "coin_tonic", requestId = "offline-coin-use" }, 0, greenRandom).ok, "coin boost use")
local beforeOffline = Model.snapshot(offline, 0)
local offlineResult = Model.settle(offline, 86400, true)
expect(offlineResult.ok and offline.lastSettled == 86400, "offline settle cursor")
near(offlineResult.gained, 4.041666666666667, 1e-9)
local afterOffline = Model.snapshot(offline, 86400)
expect(afterOffline.ok and afterOffline.coins == 100 + offlineResult.gained, "offline coin credit")
expect(#afterOffline.fish == #beforeOffline.fish and afterOffline.discoveryCount == beforeOffline.discoveryCount, "offline must not create fish or discovery")
local replayResult = Model.settle(offline, 86400, true)
expect(replayResult.ok and replayResult.gained == 0 and offline.lastSettled == 86400, "same-time offline replay")

local boost = Model.new(0)
local ids = { boost.fish[1].id, boost.fish[2].id, boost.fish[3].id }
local exchanged = Model.command(boost, "exchange", { recipeId = "exchange_luck", ids = ids, requestId = "session-spec-exchange" }, 0, function() return 0.5 end)
expect(exchanged.ok and boost.items.luck_tonic == 1, "exchange command")
local used = Model.command(boost, "useItem", { itemId = "luck_tonic", requestId = "session-spec-use" }, 0, function() return 0.5 end)
expect(used.ok and used.untilTime == 600, "boost command expiry")
local boostBefore = clone(Model.snapshot(boost, 599))
expect(Model.settle(boost, 601, false).ok, "boost expiry settle")
local boostAfter = Model.snapshot(boost, 601)
expect(boostAfter.ok and boostAfter.activeBoosts.luck == nil, "expired boost is not active")
expect(boostBefore.items.luck_tonic == 0 and boostAfter.items.luck_tonic == 0, "boost item accounting")

-- The driver itself must complete a real two-day bounded schedule and preserve
-- ledger residuals. Management actions are command-driven; the final report
-- keeps the target merge IDs so a placed-material acknowledgement is auditable.
local runOptions = clone(baseOptions)
runOptions.days = 2
runOptions.maxActions = 4000
local run = Driver.run(runOptions, { Model = Model, Config = Config, rngFor = rngFor })
expect(run.status == "completed" and #run.sessions == 2, "driver must complete two sessions")
expect(run.sessions[2].day == 1 and run.sessions[2].at == 88200 and run.sessions[2].dailyCaught > 0, "driver UTC session end")
expect(run.initialBaseUnits == 3 and run.final ~= nil, "driver final evidence")
expect(run.scheduledDays == 2 and run.completedDays == 2 and run.observedDays == 2, "driver day accounting")
expect(math.abs(run.final.unitResidual or 99) <= 1e-6, "driver unit ledger")
expect(math.abs(run.final.coinResidual or 99) <= 1e-6, "driver coin ledger")
expect(run.policy == "nurture" and run.assumptions.travelModel == "not_simulated", "driver policy metadata")
expect(#(run.stats.targetMergeRecords or {}) > 0, "driver target merge evidence")
expect((run.stats.unlockReservations or 0) > 0, "qualified run should reserve a qualified unlock")
expect((run.stats.policyStops.contract_gate_unmet or 0) > 0 and (run.stats.failedByKind["contract_gate_unmet"] or 0) == 0, "contract gate is policy state, not command failure")
for _, mergeRecord in ipairs(run.stats.targetMergeRecords) do
	expect(mergeRecord.outputId ~= nil and mergeRecord.sourceIds ~= "", "target merge IDs")
end

local censoredOptions = clone(baseOptions)
censoredOptions.maxActions = 1
local censored = Driver.run(censoredOptions, { Model = Model, Config = Config, rngFor = rngFor })
expect(censored.status == "censored" and censored.stopReason == "max_actions", "action budget censor")
expect(#censored.sessions == 0 and censored.final and censored.final.at == 0, "censor must not advance another session")
expect(censored.scheduledDays == 1 and censored.completedDays == 0 and censored.observedDays == 1, "censor day prefix")
expect(censored.stopAt == censored.observedAt and censored.final.snapshotAt <= censored.stopAt and censored.final.lastSettled <= censored.final.snapshotAt, "censor cursor relation")
expect((censored.stats.unlockReservations or 0) == 0, "low discovery/level must not reserve unlock")
expect(Driver.classifyStopReason("max_actions") == "action_budget" and Driver.classifyStopReason("bag_full_target_protected") == "capacity", "stop classification")

-- This real three-action fresh-profile boundary proves that an unqualified
-- zone cost is not reserved: management can still spend the 100-coin hook
-- upgrade, while no catch has occurred and the resulting hook count is 2.
local maxThreeOptions = clone(baseOptions)
maxThreeOptions.maxActions = 3
local maxThree = Driver.run(maxThreeOptions, { Model = Model, Config = Config, rngFor = rngFor })
expect(maxThree.status == "censored" and maxThree.stopReason == "max_actions", "maxActions=3 boundary censor")
expect(maxThree.final and maxThree.final.hooks == 2 and maxThree.stats.upgradeSpend == 100 and maxThree.stats.catches == 0, "unqualified unlock must not block hook upgrade")

local saleOptions = clone(baseOptions)
saleOptions.policy = "sale"
saleOptions.maxActions = 1000
local saleRun = Driver.run(saleOptions, { Model = Model, Config = Config, rngFor = rngFor })
expect(saleRun.status == "completed" and saleRun.policy == "sale", "sale policy completion")
local saleFinal = saleRun.final
expect(saleFinal.targetPlaced == 0, "sale policy must keep target out of tank")
for _, fish in ipairs(saleFinal and saleRun.stats and saleRun.stats.targetMergeRecords or {}) do
	-- Sale policy still merges target material, but target placement is excluded
	-- by the policy; the record remains useful for source-level accounting.
	expect(fish.outputId ~= nil, "sale target merge record")
end

print("EconomySessionSimulation.spec: options, RNG, real commands, offline cap, boost expiry, and bounded ledger PASS")
