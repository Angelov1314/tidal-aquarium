local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end
local function near(actual, expected, tolerance)
	expect(math.abs(actual - expected) <= tolerance, string.format("expected %.5f near %.5f", actual, expected))
end
local function ids(profile)
	return { profile.fish[1].id, profile.fish[2].id, profile.fish[3].id }
end

-- Config completeness and probability normalization are data-contract tests.
expect(#Config.Rarities == 7 and #Config.Species >= 42 and #Config.Zones >= 5, "catalog must be complete")
expect(Config.Contract.rewardFishCount == 3 and Config.Contract.minimumRewardLevel == 1 and Config.Contract.maximumRewardLevel == 6, "contract reward definition")
expect(Config.contractRewardLevel(nil) == 1 and Config.contractRewardLevel(1) == 1 and Config.contractRewardLevel(5) == 5 and Config.contractRewardLevel(6) == 6 and Config.contractRewardLevel(10) == 6, "contract reward level clamp")
for zone = 1, 5 do
	for rarity = 1, 7 do
		local found = false
		for _, species in ipairs(Config.Species) do if species.zone <= zone and species.rarity == rarity then found = true end end
		expect(found, "every zone must have each rarity")
	end
end
for _, luck in ipairs({ 0, 1, 25, 50, -10, 999 }) do
	local total = 0; for _, chance in ipairs(Model.odds(luck)) do total += chance end; near(total, 1, 1e-10)
end
near(Model.odds(50)[1], .51849291, 1e-6)

local profile = Model.new(0)
expect(#profile.fish == 3 and profile.discovered.white_koi == 1, "starter fish must be mergeable and discovered")
local invalid = Model.command(profile, "catch", { zone = 1 }, -1, function() return 0 end)
expect(not invalid.ok and #profile.fish == 3, "invalid time must not mutate")

local merged = Model.command(profile, "merge", { ids = ids(profile) }, 10)
expect(merged.ok and #profile.fish == 1 and profile.fish[1].level == 2, "three starters merge")
near(profile.fish[1].value, 30, 1e-9)
near(profile.fish[1].income, 3.15, 1e-9)
local duplicate = Model.command(profile, "merge", { ids = { profile.fish[1].id, profile.fish[1].id, profile.fish[1].id } }, 11)
expect(not duplicate.ok and #profile.fish == 1, "duplicate merge IDs rejected without mutation")

-- Locking blocks sale and lock itself has no hidden economic effect.
local locked = Model.command(profile, "lock", { id = profile.fish[1].id }, 12)
expect(locked.ok and profile.fish[1].locked, "lock works")
expect(not Model.command(profile, "sell", { id = profile.fish[1].id }, 13).ok, "locked fish cannot sell")
Model.command(profile, "lock", { id = profile.fish[1].id }, 14)
expect(Model.command(profile, "place", { id = profile.fish[1].id }, 20).ok, "place works")
expect(not Model.command(profile, "sell", { id = profile.fish[1].id }, 21).ok, "placed fish cannot sell")
expect(Model.command(profile, "remove", { id = profile.fish[1].id }, 22).ok, "remove works")

-- A deterministic catch at zone one always uses a zone-one common species; high zones stay unavailable.
local caught = Model.command(profile, "catch", { zone = 1 }, 30, function() return 0 end)
expect(caught.ok and #caught.fish == profile.hooks, "catch creates exactly hooks")
expect(Config.SpeciesById[caught.fish[1].species].zone == 1 and caught.fish[1].size == 1 and caught.fish[1].mutation == 1, "catch uses deterministic weighted selections")
expect(not Model.command(profile, "catch", { zone = 2 }, 31, function() return 0 end).ok, "locked zone rejected")

-- Contract rewards use the same authored weight range and merge powers as
-- normal fish. This is a pure fixture with all gates already satisfied.
local weightedSpecies
for _, species in ipairs(Config.Species) do if species.baseWeightGrams then weightedSpecies = species; break end end
expect(weightedSpecies ~= nil, "themed contract fixture requires authored weight")
local contractFixture = Model.new(86400)
for _, species in ipairs(Config.Species) do contractFixture.discovered[species.id] = 1 end
contractFixture.day, contractFixture.dailyCaught = 1, 100
local contractClaim = Model.command(contractFixture, "contract", {species = weightedSpecies.id}, 86500)
expect(contractClaim.ok and #contractClaim.fish == Config.Contract.rewardFishCount and contractClaim.fish[1].level == 1, "first contract stays at historical level")
expect(contractClaim.fish[1].weightGrams == weightedSpecies.baseWeightGrams, "contract uses authored standard weight")
local contractRarity = Config.Rarities[weightedSpecies.rarity]
near(contractClaim.fish[1].value, contractRarity.sell, 1e-9)
near(contractClaim.fish[1].income, contractRarity.income, 1e-9)
local contractIds = {contractClaim.fish[1].id, contractClaim.fish[2].id, contractClaim.fish[3].id}
local contractMerge = Model.command(contractFixture, "merge", {ids = contractIds}, 86501)
expect(contractMerge.ok and contractMerge.fish[1].level == 2 and contractFixture.discovered[weightedSpecies.id] == 2, "contract rewards merge into next level")
near(contractMerge.fish[1].value, contractRarity.sell * 3, 1e-9)
near(contractMerge.fish[1].income, contractRarity.income * 3 * 1.05, 1e-9)

-- Capacity preflight prevents partial catch rewards.
profile.hooks = 100
expect(Model.command(profile, "catch", { zone = 1 }, 31, function() return .5 end).ok, "first bulk catch")
expect(Model.command(profile, "catch", { zone = 1 }, 32, function() return .5 end).ok, "second bulk catch")
local before = #profile.fish
expect(not Model.command(profile, "catch", { zone = 1 }, 33).ok and #profile.fish == before, "full bag is atomic")
profile.hooks = 1

-- Offline settlement caps to eight hours and is idempotent on repeated login.
for _, fish in ipairs(profile.fish) do fish.placed = false end
profile.fish[1].placed = true; profile.lastSettled = 0; profile.coins = 0
local rate = profile.fish[1].income
expect(Model.settle(profile, 20 * 3600, true).ok, "offline settle")
near(profile.coins, rate * 8 * .5, 1e-8)
local afterFirst = profile.coins
expect(Model.settle(profile, 20 * 3600, true).ok, "repeat offline settle")
near(profile.coins, afterFirst, 1e-10)

-- The offline cap covers the first eight hours after logout, preserving an
-- early boost instead of incorrectly looking only at the final eight hours.
profile.coins, profile.lastSettled, profile.boostUntil = 0, 0, 1800
expect(Model.settle(profile, 20 * 3600, true).ok, "boosted offline settle")
near(profile.coins, rate * (8 + .5) * .5, 1e-8)
expect(profile.lastSettled == 20 * 3600, "capped offline settle advances the cursor")

-- Boost expires mid-settlement; only its actual interval is doubled.
profile.coins = 0; profile.lastSettled = 0; profile.boostUntil = 1800; profile.doubleIncome = false
expect(Model.settle(profile, 3600, false).ok, "boost settle")
near(profile.coins, rate * 1.5, 1e-8)

-- Snapshot is JSON-safe and excludes receipts/private purchase markers.
profile.receipts.secret = true
local coinsBeforeSnapshot, settledBeforeSnapshot = profile.coins, profile.lastSettled
local snapshot = Model.snapshot(profile, 3600)
expect(snapshot.receipts == nil and snapshot.incomePerHour >= 0 and #snapshot.odds == 7, "snapshot hides private state")
expect(profile.coins == coinsBeforeSnapshot and profile.lastSettled == settledBeforeSnapshot, "snapshot is read-only")
expect(snapshot.incomePerHour == rate, "expired boost must not inflate snapshot income")
profile.boostUntil = 7200
expect(Model.snapshot(profile, 3600).incomePerHour == rate * 2, "active boost shown in snapshot income")

-- Day rollover cannot turn yesterday's catches into a new daily contract claim.
local rollover = Model.new(0)
for _, species in ipairs(Config.Species) do rollover.discovered[species.id] = 1 end
rollover.day, rollover.dailyCaught, rollover.bagCapacity = 0, 100, 3000
expect(not Model.command(rollover, "contract", { species = "white_koi" }, 86400).ok, "previous day catches do not qualify")
local rolloverSnapshot = Model.snapshot(rollover, 86400)
expect(rolloverSnapshot.currentDay == 1 and rolloverSnapshot.dailyCaught == 0, "snapshot exposes current UTC day and hides stale daily progress")

-- A claim immediately before UTC midnight is yesterday's claim.  After a
-- zero-catch rollover, today's 100 catches make the next claim eligible.
local claimRollover = Model.new(0)
for _, species in ipairs(Config.Species) do claimRollover.discovered[species.id] = 1 end
claimRollover.day, claimRollover.dailyCaught = 0, 100
expect(Model.command(claimRollover, "contract", {species = "white_koi"}, 86399).ok, "yesterday claim fixture")
local afterMidnight = Model.snapshot(claimRollover, 86400)
expect(afterMidnight.currentDay == 1 and afterMidnight.contractDay == 0 and afterMidnight.dailyCaught == 0, "yesterday claim remains distinguishable after zero-catch rollover")
claimRollover.day, claimRollover.dailyCaught = 1, 100
expect(Model.command(claimRollover, "contract", {species = "white_koi"}, 86500).ok, "today claim after fresh catches")

-- Corrupt counters, IDs, and receipt marker values fail validation before mutation.
local corrupt = Model.new(0); corrupt.fish[1].id = "bad"; expect(not Model.validate(corrupt), "invalid fish ID rejected")
corrupt = Model.new(0); corrupt.totalCaught = -1; expect(not Model.validate(corrupt), "negative counter rejected")
corrupt = Model.new(0); corrupt.receipts.x = {}; expect(not Model.validate(corrupt), "bad receipt marker rejected")

-- Randomized sample: odds are statistically sane and output species obeys the payload-zone pool.
local seed = 1234567
local function rng()
	seed = (seed * 48271) % 2147483647
	return seed / 2147483647
end
local sample = Model.new(0); sample.hooks = 100; sample.bagCapacity = 3000; sample.zone = 5
local counts = { 0, 0, 0, 0, 0, 0, 0 }
for round = 1, 20 do
	local response = Model.command(sample, "catch", { zone = 3 }, round, rng)
	expect(response.ok and #response.fish == 100, "100-hook catch remains exact")
	for _, fish in ipairs(response.fish) do
		local species = Config.SpeciesById[fish.species]; counts[species.rarity] += 1; expect(species.zone <= 3, "zone pool leak")
	end
end
expect(counts[1] > counts[2] and counts[2] > counts[3] and counts[3] > counts[4], "sampled rarity order")

print("Model.spec: all tests passed")
