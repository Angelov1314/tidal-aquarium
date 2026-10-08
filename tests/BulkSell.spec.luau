local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function add(profile, speciesId, options)
	options = options or {}
	local species = Config.SpeciesById[speciesId]
	local rarity = Config.Rarities[species.rarity]
	local fish = {
		id = "f" .. tostring(profile.nextId), species = speciesId, level = options.level or 1,
		size = options.size or 1, mutation = options.mutation or 1,
		value = options.value or rarity.sell, income = options.income or rarity.income,
		placed = options.placed == true, locked = options.locked == true,
	}
	profile.nextId += 1
	table.insert(profile.fish, fish)
	profile.discovered[speciesId] = math.max(profile.discovered[speciesId] or 0, fish.level)
	return fish
end

local function contains(profile, id)
	for _, fish in ipairs(profile.fish) do if fish.id == id then return true end end
	return false
end
local function levelOneCount(profile, speciesId)
	local count = 0
	for _, fish in ipairs(profile.fish) do if fish.species == speciesId and fish.level == 1 then count += 1 end end
	return count
end

local profile = Model.new(0)
profile.coins, profile.coinLevel = 0, 2 -- sale multiplier is 1.10

-- The three starter fish are sell candidates.  These protected common fish all
-- count toward the same three-copy reserve, so every eligible white-koi copy sells.
local locked = add(profile, "white_koi", { locked = true })
local placed = add(profile, "white_koi", { placed = true })
local large = add(profile, "white_koi", { size = 3 })
local mutated = add(profile, "white_koi", { mutation = 2 })

-- High rarity, upgraded, large, mutated, locked, and placed fish are never bulk-sold.
local epic = add(profile, "violet_lionfish")
local upgraded = add(profile, "white_koi", { level = 2 })
local extraLocked = add(profile, "white_koi", { locked = true })
expect(Model.validate(profile), "fixture must be a valid profile")

local response = Model.command(profile, "sellDuplicates", {}, 0)
expect(response.ok, "eligible duplicates should sell")
expect(response.soldCount == 3, "only the three eligible starter copies sell")
expect(math.abs(response.earned - 33) < 1e-9 and math.abs(profile.coins - 33) < 1e-9, "coin bonus applies once to total value")
expect(levelOneCount(profile, "white_koi") == 5, "protected copies count toward reserve and remain")
for _, fish in ipairs({ locked, placed, large, mutated, epic, upgraded, extraLocked }) do
	expect(contains(profile, fish.id), "protected fish must remain: " .. fish.id)
end

-- A repeat finds no eligible duplicate and cannot grant coins a second time.
local beforeCoins, beforeFish = profile.coins, #profile.fish
local repeated = Model.command(profile, "sellDuplicates", {}, 0)
expect(not repeated.ok and repeated.soldCount == nil, "second bulk sale has no work")
expect(profile.coins == beforeCoins and #profile.fish == beforeFish, "repeat is non-mutating")

-- Six ordinary copies retain exactly three merge materials.
local reserve = Model.new(0)
add(reserve, "white_koi")
add(reserve, "white_koi")
add(reserve, "white_koi")
local reserveResult = Model.command(reserve, "sellDuplicates", {}, 0)
expect(reserveResult.ok and reserveResult.soldCount == 3 and #reserve.fish == 3, "three plain copies are retained")

print("BulkSell.spec: all tests passed")
