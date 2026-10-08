local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function near(actual, expected, tolerance)
	expect(math.abs(actual - expected) <= tolerance, string.format("expected %.8f near %.8f", actual, expected))
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, child in pairs(value) do copied[key] = clone(child) end
	return copied
end

-- A v1 envelope and old fish fixture remain valid. Migration only fills new
-- metadata and is deterministic; frozen value/income are never repriced.
local legacy = Model.new(0)
legacy.version = 1
legacy.mutationProtocol, legacy.mutationWatermarks = nil, nil
local legacyValue, legacyIncome = legacy.fish[1].value, legacy.fish[1].income
legacy.fish[1].weightGrams, legacy.fish[1].trait, legacy.fish[1].catchZone, legacy.fish[1].caughtAt, legacy.fish[1].catchSource = nil, nil, nil, nil, nil
expect(Model.validate(legacy), "old v1 fixture must validate before migration")
expect(Model.migrate(legacy, 123) == true, "v1 profile must migrate")
local migratedWeight, migratedTrait = legacy.fish[1].weightGrams, legacy.fish[1].trait
expect(legacy.version == Model.ProfileVersion and migratedWeight > 0 and migratedTrait == "ordinary", "migration fields")
expect(legacy.fish[1].value == legacyValue and legacy.fish[1].income == legacyIncome, "migration must preserve frozen values")
expect(Model.migrate(legacy, 999) == false and legacy.fish[1].weightGrams == migratedWeight, "migration must be idempotent")

-- The new content contract appends four complete rarity pools without changing
-- the original catalog IDs.
expect(#Config.Rarities == 7 and #Config.Zones >= 9 and #Config.Species >= 70, "theme catalog must be appended")
for zone = 6, 9 do
	local countByRarity = {}
	for _, species in ipairs(Config.Species) do
		if species.zone == zone then countByRarity[species.rarity] = (countByRarity[species.rarity] or 0) + 1 end
	end
	for rarity = 1, 7 do expect((countByRarity[rarity] or 0) >= 1, "theme rarity pool missing") end
end

-- Catch creates stable provenance, integer weight and trait-driven value, and
-- awards XP exactly once. Theme-only zones never leak an old-zone species.
local profile = Model.new(0)
profile.zone, profile.hooks, profile.bagCapacity = 6, 1, 3000
local beforeXP = profile.xp
local caught = Model.command(profile, "catch", { zone = 6 }, 10, function() return 0 end)
expect(caught.ok and #caught.fish == 1, "theme catch")
local newFish = caught.fish[1]
expect(Config.SpeciesById[newFish.species].zone == 6 and newFish.weightGrams > 0 and newFish.weightGrams % 1 == 0, "theme provenance/weight")
expect(Config.Traits[newFish.trait] ~= nil and newFish.catchZone == 6 and newFish.catchSource == "catch", "catch trait/provenance")
expect(profile.xp > beforeXP and caught.xpGained > 0, "catch XP")
local xpAfterCatch = profile.xp

-- Merge conserves frozen base value and deterministically combines weight and
-- trait; neither merge nor sale creates XP.
local mergeProfile = Model.new(0)
mergeProfile.fish[1].value, mergeProfile.fish[2].value, mergeProfile.fish[3].value = 11, 12, 13
mergeProfile.fish[1].weightGrams, mergeProfile.fish[2].weightGrams, mergeProfile.fish[3].weightGrams = 100, 200, 300
mergeProfile.fish[1].trait, mergeProfile.fish[2].trait, mergeProfile.fish[3].trait = "lucky", "gilded", "ordinary"
local mergeXP = mergeProfile.xp
local merged = Model.command(mergeProfile, "merge", { ids = { "f1", "f2", "f3" } }, 1)
expect(merged.ok and mergeProfile.fish[1].value == 36 and mergeProfile.fish[1].weightGrams == 200 and mergeProfile.fish[1].trait == "gilded", "merge conservation")
expect(mergeProfile.xp == mergeXP, "merge must not mint XP")
local soldCoins = mergeProfile.coins
expect(Model.command(mergeProfile, "sell", { id = mergeProfile.fish[1].id }, 2).ok and mergeProfile.xp == mergeXP, "sale must not mint XP")
expect(mergeProfile.coins > soldCoins, "merged sale")

-- Exact snapshot sale quote and actual settlement use the same active coin
-- multiplier. Invalid/duplicate/locked/placed exchange requests are atomic.
local saleProfile = Model.new(0)
saleProfile.items.coin_tonic = 1
local legacyUseAdapter = {legacyRequestReceipts = {}}
expect(Model.command(saleProfile, "useItem", { itemId = "coin_tonic", requestId = "boost-1" }, 0, nil, legacyUseAdapter).ok, "use coin item")
local repeatedBoost = Model.command(saleProfile, "useItem", { itemId = "coin_tonic", requestId = "boost-1" }, 1, nil, legacyUseAdapter)
expect(repeatedBoost.ok and repeatedBoost.replayed and saleProfile.items.coin_tonic == 0, "useItem replay protection")
local quoted = Model.snapshot(saleProfile, 1).fish[1].salePrice
local coinsBefore = saleProfile.coins
local sold = Model.command(saleProfile, "sell", { id = "f1" }, 1)
expect(sold.ok, "quoted sale")
near(saleProfile.coins - coinsBefore, quoted, 1e-9)

local fullBoost = Model.new(0)
fullBoost.items.luck_tonic = 1
fullBoost.activeBoosts.luck = { itemId = "luck_tonic", untilTime = Config.MaxBoostDurationSeconds }
local fullBoostResult = Model.command(fullBoost, "useItem", { itemId = "luck_tonic", requestId = "full-boost" }, 0)
expect(not fullBoostResult.ok and fullBoost.items.luck_tonic == 1, "full boost must not consume item")

-- The held gilded fish changes income only for the interval in which it is
-- active. Consumption now requires explicitly hiding the showcased fish first.
local gildedHeld = Model.new(0)
gildedHeld.fish[1].trait = "gilded"
expect(Model.command(gildedHeld, "showcase", { id = "f1" }, 0).ok, "gilded showcase")
local gildedQuote = Model.snapshot(gildedHeld, 10).fish[1].salePrice
local gildedCoins = gildedHeld.coins
local blockedGildedSale = Model.command(gildedHeld, "sell", { id = "f1" }, 10)
expect(not blockedGildedSale.ok and gildedHeld.showcaseFishId == "f1" and gildedHeld.coins == gildedCoins, "showcased gilded fish stays protected")
expect(Model.command(gildedHeld, "hideFish", {}, 10).ok, "hide gilded showcase before sale")
local hiddenGildedQuote = Model.snapshot(gildedHeld, 10).fish[1].salePrice
local gildedSale = Model.command(gildedHeld, "sell", { id = "f1" }, 10)
expect(gildedSale.ok and gildedHeld.showcaseFishId == nil, "hidden gilded fish can sell")
expect(gildedQuote > hiddenGildedQuote, "showcase bonus only applies while active")
near(gildedHeld.coins - gildedCoins, hiddenGildedQuote, 1e-9)
local gildedIncome = Model.new(0)
gildedIncome.fish[1].placed = true
gildedIncome.fish[2].trait = "gilded"
expect(Model.command(gildedIncome, "showcase", { id = "f2" }, 0).ok, "gilded income showcase")
expect(Model.command(gildedIncome, "hideFish", {}, 3600).ok, "gilded income hide")
near(gildedIncome.coins - 100, 1.05, 1e-9)

local overlappingBoosts = Model.new(0)
overlappingBoosts.fish[1].placed = true
overlappingBoosts.coins, overlappingBoosts.lastSettled = 0, 0
overlappingBoosts.boostUntil = 900
overlappingBoosts.activeBoosts.coins = { itemId = "coin_tonic", untilTime = 1800 }
expect(Model.settle(overlappingBoosts, 3600, false).ok, "paid and coin boost overlap")
near(overlappingBoosts.coins, (900 * 3 + 900 * 1.5 + 1800) / 3600, 1e-9)

-- The same deterministic random source produces different weights for small
-- and giant fish, while the base value receives that size contribution once.
local function sizedCatch(sizeNeedle)
	local p = Model.new(0)
	local calls = 0
	local function random()
		calls += 1
		if calls == 3 then return sizeNeedle end
		return 0.5
	end
	local response = Model.command(p, "catch", { zone = 1 }, 1, random)
	return response.fish[1]
end
local smallFish, giantFish = sizedCatch(0), sizedCatch(0.999)
expect(giantFish.weightGrams > smallFish.weightGrams and giantFish.value > smallFish.value, "size affects weight and value")

local exchangeProfile = Model.new(0)
local exchangeIds = { exchangeProfile.fish[1].id, exchangeProfile.fish[2].id, exchangeProfile.fish[3].id }
local beforeFish, beforeItems, beforeExchangeXP = #exchangeProfile.fish, clone(exchangeProfile.items), exchangeProfile.xp
local duplicate = Model.command(exchangeProfile, "exchange", { recipeId = "exchange_luck", ids = { exchangeIds[1], exchangeIds[1], exchangeIds[2] }, requestId = "bad-dup" }, 0)
expect(not duplicate.ok and #exchangeProfile.fish == beforeFish and exchangeProfile.items.luck_tonic == nil and exchangeProfile.xp == beforeExchangeXP, "duplicate exchange atomic")
exchangeProfile.fish[1].locked = true
local locked = Model.command(exchangeProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "bad-lock" }, 0)
expect(not locked.ok and #exchangeProfile.fish == beforeFish, "locked exchange rejected")
exchangeProfile.fish[1].locked = false
exchangeProfile.fish[1].placed = true
local placed = Model.command(exchangeProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "bad-place" }, 0)
expect(not placed.ok and #exchangeProfile.fish == beforeFish, "placed exchange rejected")
exchangeProfile.fish[1].placed = false
local legacyExchangeAdapter = {legacyRequestReceipts = {}}
local exchange = Model.command(exchangeProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "exchange-1" }, 1, nil, legacyExchangeAdapter)
expect(exchange.ok and #exchangeProfile.fish == 0 and exchangeProfile.items.luck_tonic == 1, "exchange consumes atomically")
local replay = Model.command(exchangeProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "exchange-1" }, 2, nil, legacyExchangeAdapter)
expect(replay.ok and replay.replayed and #exchangeProfile.fish == 0 and exchangeProfile.items.luck_tonic == 1, "exchange replay protection")

-- Active coin income is integrated across expiry boundaries, including the
-- first eight offline hours. At the exact expiry timestamp the boost is gone.
local expiry = Model.new(0)
expiry.fish[1].placed = true
expiry.coins, expiry.lastSettled = 0, 0
expiry.activeBoosts.coins = { itemId = "coin_tonic", untilTime = 600 }
expect(Model.settle(expiry, 8 * 3600, true).ok, "offline expiry settle")
near(expiry.coins, (600 * 1.5 + (8 * 3600 - 600)) / 3600 * 0.5, 1e-8)
local expiredSnapshot = Model.snapshot(expiry, 600)
expect(expiredSnapshot.activeBoosts.coins == nil and expiredSnapshot.incomePerHour == 1, "exact boost expiry")

-- A showcased trait is the only trait bonus source. Showing/placing the fish
-- settles before the held-fish change, so old income is never retroactively
-- recomputed; hiding removes the bonus explicitly.
local held = Model.new(0)
held.fish[1].trait = "lucky"
expect(Model.command(held, "showcase", { id = "f1" }, 10).ok, "showcase")
expect(held.showcaseFishId == "f1" and Model.snapshot(held, 10).effectiveLuck == 3, "held luck bonus")
expect(Model.command(held, "hideFish", {}, 11).ok and held.showcaseFishId == nil and Model.snapshot(held, 11).effectiveLuck == 0, "hide showcase")

-- XP is finite and capped at the level ceiling.
local capped = Model.new(0)
capped.xp = Model.xpThreshold(Config.MaxPlayerLevel) - 1
capped.playerLevel = Config.MaxPlayerLevel - 1
expect(Model.command(capped, "catch", { zone = 1 }, 1, function() return 0 end).ok, "capped catch")
expect(capped.xp <= Model.xpThreshold(Config.MaxPlayerLevel) and capped.playerLevel == Config.MaxPlayerLevel, "XP cap")

print("Progression.spec: migration, weights/traits, theme pools, quotes, exchanges, boosts, showcase and XP PASS")
