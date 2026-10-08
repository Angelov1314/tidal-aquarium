local Model = require("../src/shared/Model")
local Fixture = require("../tools/snapshot_performance_fixture")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do copy[clone(key, seen)] = clone(item, seen) end
	return copy
end

local function same(a, b, path)
	path = path or "root"
	if type(a) ~= type(b) then return false, path .. ": type" end
	if type(a) ~= "table" then
		if a ~= b then return false, path .. ": value" end
		return true
	end
	for key, value in pairs(a) do
		local equal, mismatch = same(value, b[key], path .. "." .. tostring(key))
		if not equal then return false, mismatch end
	end
	for key in pairs(b) do
		if a[key] == nil then return false, path .. "." .. tostring(key) .. ": missing" end
	end
	return true
end

for _, count in ipairs({ 300, 1500, 3100 }) do
	for _, withShowcase in ipairs({ false, true }) do
		local profile = Fixture.profile(Model, count, withShowcase)
		local before = clone(profile)
		local now = 86400
		local snapshot = Model.snapshot(profile, now)
		expect(snapshot.ok and #snapshot.fish == count, "snapshot fixture output count")
		for index, fish in ipairs(profile.fish) do
			expect(snapshot.fish[index].salePrice == Model.salePrice(profile, fish, now), "snapshot salePrice must use Model.salePrice formula")
		end
		local unchanged, mismatch = same(profile, before)
		expect(unchanged, "snapshot mutated profile at " .. tostring(mismatch))

		local expired = Model.snapshot(profile, now + 1)
		expect(expired.fish[#expired.fish].salePrice == Model.salePrice(profile, profile.fish[#profile.fish], now + 1), "time transition sale price")
		profile.showcaseFishId = nil
		local hidden = Model.snapshot(profile, now)
		for index, fish in ipairs(profile.fish) do
			expect(hidden.fish[index].salePrice == Model.salePrice(profile, fish, now), "showcase transition sale price")
		end
	end
end

-- The valid boost boundary remains part of the snapshot formula and does not
-- turn salePrice into an income preview or a stale cache.
local boosted = Fixture.profile(Model, 300, true)
boosted.activeBoosts.coins = { itemId = "coin_tonic", untilTime = 90000 }
local boostedSnapshot = Model.snapshot(boosted, 86400)
for index, fish in ipairs(boosted.fish) do
	expect(boostedSnapshot.fish[index].salePrice == Model.salePrice(boosted, fish, 86400), "active coin boost parity")
end
local expiredBoostSnapshot = Model.snapshot(boosted, 90000)
for index, fish in ipairs(boosted.fish) do
	expect(expiredBoostSnapshot.fish[index].salePrice == Model.salePrice(boosted, fish, 90000), "expired coin boost parity")
end

-- Traits and income-only flags must not change the sale-price contract. The
-- profile still exercises a showcased gilded fish, a legacy record, a paid
-- income boost and the double-income flag together.
local mixed = Fixture.profile(Model, 300, true)
mixed.fish[1].trait = nil
mixed.fish[1].weightGrams = nil
mixed.fish[1].catchZone = nil
mixed.fish[1].caughtAt = nil
mixed.fish[1].catchSource = nil
mixed.doubleIncome = true
mixed.boostUntil = 90000
mixed.activeBoosts.coins = { itemId = "coin_tonic", untilTime = 90000 }
local mixedSnapshot = Model.snapshot(mixed, 86400)
expect(mixedSnapshot.incomePerHour == Model.incomeRate(mixed, 86400), "income flags must retain the shared income formula")
for index, fish in ipairs(mixed.fish) do
	local expected = Model.salePrice(mixed, fish, 86400)
	expect(mixedSnapshot.fish[index].salePrice == expected, "legacy/income-only flags must not alter sale price")
end

print("SnapshotPerformance.spec: all tests passed")
