-- Deterministic, server-owned domain model. It deliberately accepts no Instances.
local Config
if script then Config = require(script.Parent.Config) else Config = require("./Config") end
local MutationProtocol
if script then MutationProtocol = require(script.Parent.MutationProtocol) else MutationProtocol = require("./MutationProtocol") end

local Model = {}
local EPSILON = 0.000001
local MAX_TIME = 32503680000
local PROFILE_VERSION = MutationProtocol.ProfileVersion
local LEGACY_PROFILE_VERSION = 2

Model.ProfileVersion = PROFILE_VERSION

local function finiteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
	return finiteNumber(value) and value % 1 == 0
end

local function validNow(now)
	return finiteNumber(now) and now >= 0
end

local function result(ok, message, fish)
	return { ok = ok, message = message, fish = fish }
end

local function fishId(number)
	return "f" .. tostring(number)
end

local function round(value, places)
	local scale = 10 ^ (places or 0)
	return math.floor(value * scale + 0.5) / scale
end

local function countPlaced(profile)
	local n = 0
	for _, fish in ipairs(profile.fish or {}) do
		if type(fish) == "table" and fish.placed then n += 1 end
	end
	return n
end

local function countBag(profile)
	local n = 0
	for _, fish in ipairs(profile.fish or {}) do
		if type(fish) == "table" and not fish.placed then n += 1 end
	end
	return n
end

local function discoveryCount(profile)
	local n = 0
	for _ in pairs(profile.discovered or {}) do n += 1 end
	return n
end

local function findFish(profile, id)
	if type(id) ~= "string" then return nil end
	for index, fish in ipairs(profile.fish or {}) do
		if fish.id == id then return fish, index end
	end
	return nil
end

local function speciesFor(fish)
	return type(fish) == "table" and Config.SpeciesById[fish.species] or nil
end

local function traitFor(fish)
	local trait = type(fish) == "table" and fish.trait or nil
	return Config.Traits[trait] or Config.Traits.ordinary
end

local function weightRangeFor(species, rarityIndex)
	if type(species) == "table" and integer(species.weightMin) and integer(species.weightMax)
		and species.weightMin > 0 and species.weightMax >= species.weightMin then
		return { min = species.weightMin, max = species.weightMax, standard = species.baseWeightGrams or math.floor((species.weightMin + species.weightMax) / 2) }
	end
	if type(species) == "table" and integer(species.baseWeightGrams) and species.baseWeightGrams > 0 then
		local base = species.baseWeightGrams
		return { min = math.max(1, math.floor(base * 0.85)), max = math.max(1, math.ceil(base * 1.15)), standard = base }
	end
	return Config.WeightRanges[rarityIndex or 1] or Config.WeightRanges[1]
end

local function legacyWeightGrams(fish)
	local species = speciesFor(fish)
	local rarityIndex = species and species.rarity or 1
	local range = weightRangeFor(species, rarityIndex)
	local size = Config.Sizes[fish.size]
	local mutation = Config.Mutations[fish.mutation]
	local value = range.standard * (size and size.multiplier or 1) * (mutation and mutation.multiplier or 1)
	return math.max(1, math.min(1000000000, math.floor(value + 0.5)))
end

local function fishWeight(fish)
	return integer(fish.weightGrams) and fish.weightGrams > 0 and fish.weightGrams or legacyWeightGrams(fish)
end

local function fishTrait(fish)
	return Config.Traits[fish.trait] and fish.trait or "ordinary"
end

local function fishCatchZone(fish)
	local species = speciesFor(fish)
	return integer(fish.catchZone) and fish.catchZone or (species and species.zone or 1)
end

local function fishCaughtAt(fish, profile)
	if finiteNumber(fish.caughtAt) and fish.caughtAt >= 0 then return fish.caughtAt end
	return finiteNumber(profile.lastSettled) and profile.lastSettled or 0
end

local function fishCatchSource(fish)
	return type(fish.catchSource) == "string" and fish.catchSource or "legacy"
end

local function copyFish(fish, profile, now, saleMultiplier)
	local copied = {
		id = fish.id,
		species = fish.species,
		level = fish.level,
		size = fish.size,
		mutation = fish.mutation,
		value = fish.value,
		income = fish.income,
		placed = fish.placed,
		locked = fish.locked,
		weightGrams = fishWeight(fish),
		trait = fishTrait(fish),
		catchZone = fishCatchZone(fish),
		caughtAt = fishCaughtAt(fish, profile or {}),
		catchSource = fishCatchSource(fish),
	}
	if profile and validNow(now) then
		-- snapshot passes one factor shared by every fish. Other command paths
		-- leave this nil and continue through the authoritative salePrice entry.
		copied.salePrice = if saleMultiplier ~= nil then fish.value * saleMultiplier else Model.salePrice(profile, fish, now)
	end
	return copied
end

local function safeRandom(random)
	local value = type(random) == "function" and random() or math.random()
	if not finiteNumber(value) then return 0.5 end
	if value < 0 then return 0 end
	if value >= 1 then return 1 - EPSILON end
	return value
end

local function weightedIndex(items, random, odds)
	if #items == 0 then return 0 end
	local needle, total = safeRandom(random), 0
	for i, item in ipairs(items) do total += odds and odds[i] or item.chance or 1 end
	needle *= total
	local running = 0
	for i, item in ipairs(items) do
		running += odds and odds[i] or item.chance or 1
		if needle < running then return i end
	end
	return #items
end

local function xpThreshold(level)
	if level <= 1 then return 0 end
	return 100 * (level - 1) * level / 2
end

local function maxXP()
	return xpThreshold(Config.MaxPlayerLevel or 50)
end

local function levelForXP(xp)
	local level = 1
	local maximum = Config.MaxPlayerLevel or 50
	for candidate = 2, maximum do
		if xp + EPSILON >= xpThreshold(candidate) then level = candidate else break end
	end
	return level
end

local function itemForKind(profile, kind)
	local active = profile.activeBoosts and profile.activeBoosts[kind]
	if type(active) ~= "table" or not finiteNumber(active.untilTime) then return nil end
	local item = Config.BoostItems[active.itemId]
	if not item or item.kind ~= kind then return nil end
	return active, item
end

local function activeItemMultiplier(profile, kind, at)
	if not validNow(at) then return 1 end
	local active, item = itemForKind(profile, kind)
	if active and active.untilTime > at then return item.multiplier or 1 end
	return 1
end

local function showcaseFishById(profile, showcaseId)
	if type(showcaseId) ~= "string" then return nil end
	local fish = findFish(profile, showcaseId)
	if fish and not fish.placed then return fish end
	return nil
end

local function showcaseFish(profile)
	return showcaseFishById(profile, profile.showcaseFishId)
end

local function showcasedTraitBonusForId(profile, field, showcaseId)
	local fish = showcaseFishById(profile, showcaseId)
	local trait = fish and traitFor(fish)
	return trait and trait[field] or 0
end

local function showcasedTraitBonus(profile, field)
	local fish = showcaseFish(profile)
	return fish and traitFor(fish)[field] or 0
end

local function coinMultiplierForShowcase(profile, at, showcaseId)
	local multiplier = 1 + (profile.coinLevel or 0) * 0.05
	multiplier *= activeItemMultiplier(profile, "coins", at)
	multiplier *= 1 + showcasedTraitBonusForId(profile, "coinBonus", showcaseId)
	return multiplier
end

local function coinMultiplier(profile, at)
	return coinMultiplierForShowcase(profile, at, profile.showcaseFishId)
end

local function incomeMultiplierForShowcase(profile, at, showcaseId)
	local multiplier = coinMultiplierForShowcase(profile, at, showcaseId)
	if profile.doubleIncome then multiplier *= 2 end
	local paidBoostActive = validNow(at) and profile.boostUntil > at
	if paidBoostActive then multiplier *= 2 end
	return multiplier
end

local function placedIncomeTotal(profile, excludedIds)
	local total = 0
	for _, fish in ipairs(profile.fish or {}) do
		if fish.placed and not (excludedIds and excludedIds[fish.id]) then total += fish.income end
	end
	return total
end

local function mergedBaseIncome(sources)
	local total = 0
	for _, fish in ipairs(sources) do total += fish.income end
	return total * 1.05
end

-- Mutation requests use dense, bounded ID arrays.  Keeping this validation
-- shared lets the server command and read-only merge preview agree on holes,
-- duplicate IDs, and unexpected keys without trusting # on a sparse table.
local function denseIdArray(value)
	if type(value) ~= "table" then return nil end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > 32 then return nil end
		count += 1
	end
	if count > 32 then return nil end
	local ids = {}
	for index = 1, count do
		local id = value[index]
		if type(id) ~= "string" or #id == 0 or #id > 80 then return nil end
		ids[index] = id
	end
	return ids
end

-- Returns hardInvalid for malformed/extra/duplicate acknowledgements.  A
-- missing or incomplete set is a validly shaped request that still needs an
-- explicit UI confirmation, which incomePreview reports as allowed=false.
local function placedAcknowledgement(sources, value)
	local required, requiredCount = {}, 0
	for _, fish in ipairs(sources) do
		if fish.placed then required[fish.id] = true; requiredCount += 1 end
	end
	if value == nil then
		if requiredCount == 0 then return true, nil, false end
		return false, "请确认移出入缸材料", false
	end
	local ids = denseIdArray(value)
	if not ids then return false, "入缸确认无效", true end
	local seen = {}
	for _, id in ipairs(ids) do
		if seen[id] or not required[id] then return false, "入缸确认无效", true end
		seen[id] = true
	end
	for id in pairs(required) do
		if not seen[id] then return false, "入缸确认不完整", false end
	end
	return true, nil, false
end

local function incomeRate(profile, at)
	return placedIncomeTotal(profile) * incomeMultiplierForShowcase(profile, at, profile.showcaseFishId)
end

local function xpMultiplier(profile, at)
	return activeItemMultiplier(profile, "xp", at) * (1 + showcasedTraitBonus(profile, "xpBonus"))
end

function Model.odds(luck)
	if not finiteNumber(luck) then luck = 0 end
	local maxEffective = Config.MaxEffectiveLuck or Config.MaxLuck
	luck = math.clamp(luck, 0, maxEffective)
	local multipliers = { 0, .2, .5, 1, 1.5, 2, 3 }
	local weights, total = {}, 0
	for i, rarity in ipairs(Config.Rarities) do
		local weight = rarity.chance * (1 + (luck / Config.MaxLuck) * (multipliers[i] or multipliers[#multipliers]))
		weights[i] = weight
		total += weight
	end
	for i = 1, #weights do weights[i] /= total end
	return weights
end

function Model.xpThreshold(level)
	return xpThreshold(math.clamp(level, 1, Config.MaxPlayerLevel or 50))
end

function Model.playerProgress(profile)
	local xp = integer(profile.xp) and math.clamp(profile.xp, 0, maxXP()) or 0
	local level = levelForXP(xp)
	local nextThreshold = level < (Config.MaxPlayerLevel or 50) and xpThreshold(level + 1) or xp
	return { xp = xp, totalXP = xp, playerLevel = level, xpToNextLevel = math.max(0, nextThreshold - xp) }
end

function Model.effectiveLuck(profile, now)
	local luck = integer(profile.luck) and profile.luck or 0
	local active, item = itemForKind(profile, "luck")
	if validNow(now) and active and active.untilTime > now then luck += item.amount or 0 end
	luck += showcasedTraitBonus(profile, "luckBonus")
	return math.clamp(luck, 0, Config.MaxEffectiveLuck or Config.MaxLuck)
end

function Model.salePrice(profile, fish, now)
	if type(fish) ~= "table" or not finiteNumber(fish.value) then return 0 end
	return fish.value * coinMultiplier(profile, now)
end

Model.incomeRate = incomeRate

local function upgradeInfo(profile)
	local function row(cost, level, maximum)
		if level >= maximum then return { cost = nil, level = level, max = maximum } end
		return { cost = cost, level = level, max = maximum }
	end
	return {
		hooks = row(Config.hookCost(profile.hooks), profile.hooks, Config.MaxHooks),
		luck = row(Config.luckCost(profile.luck), profile.luck, Config.MaxLuck),
		coins = row(Config.coinCost(profile.coinLevel), profile.coinLevel, Config.MaxCoinLevel),
		tank = row(Config.tankCost(profile.tankCapacity), profile.tankCapacity, Config.MaxTankCapacity),
		bag = row(Config.bagCost(profile.bagCapacity), profile.bagCapacity, Config.MaxBagCapacity),
	}
end

local function validateItems(profile)
	if profile.items == nil then return true end
	if type(profile.items) ~= "table" then return false end
	for itemId, count in pairs(profile.items) do
		if type(itemId) ~= "string" or not Config.BoostItems[itemId] or not integer(count)
			or count < 0 or count > (Config.MaxItemStack or 9999) then return false end
	end
	return true
end

local function validateActiveBoosts(profile)
	if profile.activeBoosts == nil then return true end
	if type(profile.activeBoosts) ~= "table" then return false end
	for kind, active in pairs(profile.activeBoosts) do
		if (kind ~= "luck" and kind ~= "coins" and kind ~= "xp") or type(active) ~= "table"
			or type(active.itemId) ~= "string" or not Config.BoostItems[active.itemId]
			or Config.BoostItems[active.itemId].kind ~= kind or not finiteNumber(active.untilTime)
			or active.untilTime < 0 or active.untilTime > MAX_TIME then return false end
	end
	return true
end

local function validateRequestReceipts(profile)
	local ok = MutationProtocol.legacyReceiptStats(profile.requestReceipts)
	return ok
end

function Model.validate(profile)
	if type(profile) ~= "table" or (profile.version ~= 1 and profile.version ~= LEGACY_PROFILE_VERSION and profile.version ~= PROFILE_VERSION)
		or not finiteNumber(profile.coins) or profile.coins < 0 then return false, "存档无效" end
	if profile.version == PROFILE_VERSION then
		if profile.mutationProtocol ~= MutationProtocol.ProtocolVersion then return false, "存档协议版本无效" end
		local watermarksValid = MutationProtocol.validateWatermarks(profile.mutationWatermarks)
		if not watermarksValid or profile.requestReceipts ~= nil then return false, "存档水位无效" end
	else
		if profile.mutationProtocol ~= nil or profile.mutationWatermarks ~= nil then return false, "旧存档混入新协议" end
		if not validateRequestReceipts(profile) then return false, "旧请求回执无效" end
	end
	for _, key in ipairs({ "hooks", "luck", "coinLevel", "tankCapacity", "bagCapacity", "zone", "nextId", "lastSettled", "totalCaught", "day", "dailyCaught", "contractDay", "boostUntil" }) do
		if not finiteNumber(profile[key]) then return false, "存档字段无效: " .. key end
	end
	if not integer(profile.hooks) or profile.hooks < 1 or profile.hooks > Config.MaxHooks
		or not integer(profile.luck) or profile.luck < 0 or profile.luck > Config.MaxLuck
		or not integer(profile.coinLevel) or profile.coinLevel < 0 or profile.coinLevel > Config.MaxCoinLevel
		or not integer(profile.tankCapacity) or profile.tankCapacity < 10 or profile.tankCapacity > Config.MaxTankCapacity
		or not integer(profile.bagCapacity) or profile.bagCapacity < 300 or profile.bagCapacity > Config.MaxBagCapacity
		or profile.bagCapacity % 100 ~= 0 or not integer(profile.zone) or profile.zone < 1 or profile.zone > #Config.Zones
		or not integer(profile.nextId) or profile.nextId < 1 or profile.nextId > 9007199254740991
		or profile.lastSettled < 0 or profile.lastSettled > MAX_TIME
		or not integer(profile.totalCaught) or profile.totalCaught < 0 or not integer(profile.day) or profile.day < 0
		or not integer(profile.dailyCaught) or profile.dailyCaught < 0 or not integer(profile.contractDay) or profile.contractDay < -1
		or profile.boostUntil < 0 or profile.boostUntil > MAX_TIME
		or type(profile.doubleIncome) ~= "boolean" then return false, "存档范围无效" end
	if profile.xp ~= nil and (not integer(profile.xp) or profile.xp < 0 or profile.xp > maxXP()) then return false, "经验数据无效" end
	if profile.playerLevel ~= nil and (not integer(profile.playerLevel) or profile.playerLevel < 1 or profile.playerLevel > (Config.MaxPlayerLevel or 50)) then return false, "等级数据无效" end
	if profile.showcaseFishId ~= nil and (type(profile.showcaseFishId) ~= "string" or #profile.showcaseFishId > 80) then return false, "展示鱼数据无效" end
	if type(profile.fish) ~= "table" or type(profile.discovered) ~= "table" or type(profile.receipts) ~= "table" then return false, "存档集合无效" end
	if not validateItems(profile) or not validateActiveBoosts(profile) then return false, "物品数据无效" end
	local ids = {}
	for _, fish in ipairs(profile.fish) do
		local idNumber = type(fish) == "table" and type(fish.id) == "string" and tonumber(string.match(fish.id, "^f(%d+)$"))
		if type(fish) ~= "table" or not idNumber or idNumber < 1 or idNumber % 1 ~= 0 or idNumber >= profile.nextId or ids[fish.id] or not Config.SpeciesById[fish.species]
			or not integer(fish.level) or fish.level < 1 or fish.level > 10 or not integer(fish.size) or not Config.Sizes[fish.size]
			or not integer(fish.mutation) or not Config.Mutations[fish.mutation] or not finiteNumber(fish.value) or fish.value < 0
			or not finiteNumber(fish.income) or fish.income < 0 or type(fish.placed) ~= "boolean" or type(fish.locked) ~= "boolean" then return false, "鱼数据无效" end
		if fish.weightGrams ~= nil and (not integer(fish.weightGrams) or fish.weightGrams < 1 or fish.weightGrams > 1000000000) then return false, "鱼重量无效" end
		if fish.trait ~= nil and not Config.Traits[fish.trait] then return false, "鱼特性无效" end
		if fish.catchZone ~= nil and (not integer(fish.catchZone) or fish.catchZone < 1 or fish.catchZone > #Config.Zones) then return false, "捕获水域无效" end
		if fish.caughtAt ~= nil and (not finiteNumber(fish.caughtAt) or fish.caughtAt < 0 or fish.caughtAt > MAX_TIME) then return false, "捕获时间无效" end
		if fish.catchSource ~= nil and (type(fish.catchSource) ~= "string" or #fish.catchSource > 32) then return false, "捕获来源无效" end
		ids[fish.id] = true
	end
	if countPlaced(profile) > profile.tankCapacity or countBag(profile) > profile.bagCapacity then return false, "存档容量无效" end
	if profile.showcaseFishId then
		local showcased = findFish(profile, profile.showcaseFishId)
		if not showcased or showcased.placed then return false, "展示鱼无效" end
	end
	for species, level in pairs(profile.discovered) do if not Config.SpeciesById[species] or not integer(level) or level < 1 or level > 10 then return false, "图鉴无效" end end
	for receipt, marker in pairs(profile.receipts) do
		if type(receipt) ~= "string" or #receipt > 128 or (marker ~= true and (not finiteNumber(marker) or marker < 0 or marker > MAX_TIME)) then return false, "回执无效" end
	end
	return true
end

-- Returns whether the profile was changed. Storage calls this only after an
-- envelope has passed validation, so legacy values are never repriced or
-- rerolled while an invalid DataStore payload is being inspected.
function Model.migrate(profile, now)
	if type(profile) ~= "table" then return false end
	local changed = false
	local function setIfMissing(key, value)
		if profile[key] == nil then profile[key] = value; changed = true end
	end
	if profile.version == 1 then profile.version = LEGACY_PROFILE_VERSION; changed = true end
	setIfMissing("items", {})
	setIfMissing("activeBoosts", {})
	-- Legacy request IDs are not sequence watermarks. They are inspected and
	-- bounded at the envelope boundary, then discarded only in this candidate
	-- before the atomic v3 write. Paid receipts are never touched here.
	if profile.version == LEGACY_PROFILE_VERSION then
		local legacyOk = MutationProtocol.legacyReceiptStats(profile.requestReceipts)
		if not legacyOk then return false end
		profile.requestReceipts = nil
		profile.mutationProtocol = MutationProtocol.ProtocolVersion
		profile.mutationWatermarks = MutationProtocol.newWatermarks()
		profile.version = PROFILE_VERSION
		changed = true
	elseif profile.version == PROFILE_VERSION then
		if profile.mutationProtocol ~= MutationProtocol.ProtocolVersion then return false end
		if not MutationProtocol.validateWatermarks(profile.mutationWatermarks) then return false end
	end
	-- nil is already the correct absent value; assigning it would make every
	-- migration look dirty and cause a needless save on each reconnect.
	local xp = integer(profile.xp) and math.clamp(profile.xp, 0, maxXP()) or 0
	if profile.xp ~= xp then profile.xp = xp; changed = true end
	local level = levelForXP(xp)
	if profile.playerLevel ~= level then profile.playerLevel = level; changed = true end
	for _, fish in ipairs(profile.fish or {}) do
		if fish.weightGrams == nil then fish.weightGrams = legacyWeightGrams(fish); changed = true end
		if fish.trait == nil then fish.trait = "ordinary"; changed = true end
		if fish.catchZone == nil then fish.catchZone = fishCatchZone(fish); changed = true end
		-- Use the persisted settlement cursor as the legacy timestamp. Runtime
		-- load time would make the same old record migrate to different data.
		if fish.caughtAt == nil then fish.caughtAt = fishCaughtAt(fish, profile); changed = true end
		if fish.catchSource == nil then fish.catchSource = "legacy"; changed = true end
	end
	if profile.showcaseFishId then
		local fish = findFish(profile, profile.showcaseFishId)
		if not fish or fish.placed then profile.showcaseFishId = nil; changed = true end
	end
	return changed
end

local function addDiscovery(profile, species, level)
	profile.discovered[species] = math.max(profile.discovered[species] or 0, level)
end

local function addFish(profile, options)
	local fish = {
		id = fishId(profile.nextId),
		species = options.species,
		level = options.level,
		size = options.size,
		mutation = options.mutation,
		value = options.value,
		income = options.income,
		placed = options.placed == true,
		locked = options.locked == true,
		weightGrams = options.weightGrams,
		trait = options.trait or "ordinary",
		catchZone = options.catchZone,
		caughtAt = options.caughtAt,
		catchSource = options.catchSource or "legacy",
	}
	profile.nextId += 1
	table.insert(profile.fish, fish)
	addDiscovery(profile, options.species, options.level)
	return fish
end

local function settleForCommand(profile, now)
	local settled = Model.settle(profile, now, false)
	if not settled.ok then return nil, settled end
	return true
end

local function validPayloadId(payload)
	return type(payload) == "table" and type(payload.id) == "string" and #payload.id <= 80
end

local function validRequestId(payload)
	return type(payload) == "table" and type(payload.requestId) == "string" and #payload.requestId > 0 and #payload.requestId <= 128
end

local function utcDay(now)
	return math.floor(now / 86400)
end

local function requestReplay(context, requestId)
	local store = type(context) == "table" and context.legacyRequestReceipts
	return type(store) == "table" and store[requestId] ~= nil
end

local function rememberRequest(context, requestId)
	local store = type(context) == "table" and context.legacyRequestReceipts
	if type(store) == "table" then store[requestId] = true end
end

function Model.mutationWatermarks(profile): {[string]: number}
	if type(profile) ~= "table" or type(profile.mutationWatermarks) ~= "table" then
		return MutationProtocol.newWatermarks()
	end
	return profile.mutationWatermarks
end

function Model.mutationDecision(profile, action: string, payload: any, epoch: string): (string, string?)
	return MutationProtocol.sequenceDecision(action, payload, epoch, Model.mutationWatermarks(profile))
end

function Model.advanceMutationWatermark(profile, action: string, operationSeq: number): boolean
	if not MutationProtocol.isLane(action) or not MutationProtocol.isSequence(operationSeq) then return false end
	local watermarks = Model.mutationWatermarks(profile)
	if watermarks[action] ~= operationSeq - 1 then return false end
	watermarks[action] = operationSeq
	profile.mutationProtocol = MutationProtocol.ProtocolVersion
	return true
end

local function recipeById(id)
	for _, recipe in ipairs(Config.ExchangeRecipes or {}) do if recipe.id == id then return recipe end end
	return nil
end

local function itemCount(profile, itemId)
	return profile.items and profile.items[itemId] or 0
end

local function chooseCatchPool(zone, rarity)
	local zoneDefinition = Config.Zones[zone]
	local pool = {}
	for _, species in ipairs(Config.Species) do
		local eligible = species.rarity == rarity and (((zoneDefinition and zoneDefinition.themeOnly) and species.zone == zone) or ((not zoneDefinition or not zoneDefinition.themeOnly) and species.zone <= zone))
		if eligible then table.insert(pool, species) end
	end
	-- A theme is allowed to fall back to the legacy cumulative pool only if an
	-- incomplete content module was installed. Complete themes never reach this.
	if #pool == 0 then
		for _, species in ipairs(Config.Species) do if species.rarity == rarity and species.zone <= zone then table.insert(pool, species) end end
	end
	return pool
end

local function rollWeight(species, rarity, sizeIndex, random)
	local range = weightRangeFor(species, rarity)
	local span = range.max - range.min + 1
	local size = Config.Sizes[sizeIndex]
	return math.max(1, math.floor((range.min + safeRandom(random) * span) * (size and size.multiplier or 1) + 0.5))
end

local function valueForCatch(rarityIndex, sizeIndex, mutationIndex, weightGrams, trait, weightStandard)
	local rarity = Config.Rarities[rarityIndex]
	local size = Config.Sizes[sizeIndex]
	local mutation = Config.Mutations[mutationIndex]
	local speciesRange = Config.WeightRanges[rarityIndex] or Config.WeightRanges[1]
	local standard = weightStandard or speciesRange.standard
	-- Size is represented by the rolled weight. Dividing by the standard weight
	-- keeps that size contribution from being multiplied a second time here.
	local weightMultiplier = weightGrams / standard
	local value = rarity.sell * weightMultiplier * mutation.multiplier * (trait.valueMultiplier or 1)
	return math.max(0.01, round(value, 2))
end

local function xpForCatch(rarityIndex, weightGrams, trait, profile, now)
	local base = rarityIndex * 10 + math.max(1, math.floor(weightGrams / 100))
	return math.max(1, math.floor(base * (1 + (trait.xpBonus or 0)) * xpMultiplier(profile, now) + 0.5))
end

function Model.addExperience(profile, amount)
	if not finiteNumber(amount) or amount <= 0 then return 0 end
	local before = integer(profile.xp) and profile.xp or 0
	local after = math.min(maxXP(), math.floor(before + amount + 0.5))
	profile.xp = after
	profile.playerLevel = levelForXP(after)
	return after - before
end

function Model.settle(profile, now, offline)
	local valid, message = Model.validate(profile)
	if not valid then return result(false, message) end
	if not validNow(now) then return result(false, "时间无效") end
	if now < profile.lastSettled then return result(false, "时间不能倒退") end
	local start = profile.lastSettled
	local finish = offline and math.min(now, start + 8 * 3600) or now
	local boundaries = { start, finish }
	local coinBoost = itemForKind(profile, "coins")
	local coinUntil = coinBoost and coinBoost.untilTime
	if profile.boostUntil > start and profile.boostUntil < finish then table.insert(boundaries, profile.boostUntil) end
	if coinUntil and coinUntil > start and coinUntil < finish then table.insert(boundaries, coinUntil) end
	table.sort(boundaries)
	local gained = 0
	for index = 1, #boundaries - 1 do
		local from, to = boundaries[index], boundaries[index + 1]
		if to > from then gained += incomeRate(profile, from + EPSILON) * (to - from) / 3600 * (offline and 0.5 or 1) end
	end
	profile.coins += gained
	profile.lastSettled = now
	return { ok = true, message = "已结算", gained = gained }
end

function Model.new(now)
	if not validNow(now) then now = 0 end
	local profile = {
		version = PROFILE_VERSION,
		coins = 100,
		hooks = 1,
		luck = 0,
		coinLevel = 0,
		tankCapacity = 10,
		bagCapacity = 300,
		zone = 1,
		fish = {},
		discovered = {},
		nextId = 1,
		lastSettled = now,
		totalCaught = 0,
		day = 0,
		dailyCaught = 0,
		contractDay = -1,
		boostUntil = 0,
		doubleIncome = false,
		receipts = {},
		xp = 0,
		playerLevel = 1,
		items = {},
		activeBoosts = {},
		mutationProtocol = MutationProtocol.ProtocolVersion,
		mutationWatermarks = MutationProtocol.newWatermarks(),
		showcaseFishId = nil,
	}
	local starter = Config.Species[1]
	for _ = 1, 3 do
		addFish(profile, { species = starter.id, level = 1, size = 2, mutation = 1, value = Config.Rarities[1].sell, income = Config.Rarities[1].income, weightGrams = Config.WeightRanges[1].standard, trait = "ordinary", catchZone = 1, caughtAt = now, catchSource = "starter" })
	end
	return profile
end

function Model.command(profile, action, payload, now, random, context)
	local valid, message = Model.validate(profile)
	if not valid then return result(false, message) end
	if type(action) ~= "string" or type(payload) ~= "table" or not validNow(now) then return result(false, "请求无效") end
	-- Old v1 saves are normally migrated at the storage boundary. This fallback
	-- is delayed until after request-shape/time checks so a rejected request does
	-- not mutate a legacy profile while filling metadata.
	if profile.version == 1 then Model.migrate(profile, now) end
	if action == "catch" then
		if not integer(payload.zone) or payload.zone < 1 or payload.zone > profile.zone or payload.zone > #Config.Zones then return result(false, "水域无效") end
		if countBag(profile) + profile.hooks > profile.bagCapacity then return result(false, "背包空间不足") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		local caught, rarityOdds, earnedXP = {}, Model.odds(Model.effectiveLuck(profile, now)), 0
		for _ = 1, profile.hooks do
			local rarity = weightedIndex(Config.Rarities, random, rarityOdds)
			local pool = chooseCatchPool(payload.zone, rarity)
			if #pool == 0 then return result(false, "该水域缺少完整鱼群配置") end
			local species = pool[weightedIndex(pool, random)]
			local size, mutation = weightedIndex(Config.Sizes, random), weightedIndex(Config.Mutations, random)
			local trait = Config.TraitEntries[weightedIndex(Config.TraitEntries, random)] or Config.Traits.ordinary
			local weightGrams = rollWeight(species, rarity, size, random)
			local value = valueForCatch(rarity, size, mutation, weightGrams, trait, weightRangeFor(species, rarity).standard)
			local sizeMutation = Config.Sizes[size].multiplier * Config.Mutations[mutation].multiplier
			local fish = addFish(profile, { species = species.id, level = 1, size = size, mutation = mutation, value = value, income = Config.Rarities[rarity].income * sizeMutation, weightGrams = weightGrams, trait = trait.id, catchZone = payload.zone, caughtAt = now, catchSource = "catch" })
			table.insert(caught, copyFish(fish, profile, now))
			earnedXP += xpForCatch(rarity, weightGrams, trait, profile, now)
		end
		local awardedXP = Model.addExperience(profile, earnedXP)
		profile.totalCaught += #caught
		local day = utcDay(now)
		if profile.day ~= day then profile.day = day; profile.dailyCaught = 0 end
		profile.dailyCaught += #caught
		return { ok = true, message = "捕获成功", fish = caught, xpGained = awardedXP, totalXP = profile.xp, playerLevel = profile.playerLevel }
	elseif action == "sellDuplicates" then
		local levelOneCounts, candidates = {}, {}
		for _, fish in ipairs(profile.fish) do if fish.level == 1 then levelOneCounts[fish.species] = (levelOneCounts[fish.species] or 0) + 1 end end
		for _, fish in ipairs(profile.fish) do
			local species = Config.SpeciesById[fish.species]
			if fish.level == 1 and not fish.placed and not fish.locked and fish.id ~= profile.showcaseFishId and species.rarity <= 3 and fish.mutation == 1 and fish.size <= 2 then table.insert(candidates, fish) end
		end
		local remaining, sellIds = {}, {}
		for species, count in pairs(levelOneCounts) do remaining[species] = count end
		for _, fish in ipairs(candidates) do
			if (remaining[fish.species] or 0) > 3 then remaining[fish.species] -= 1; sellIds[fish.id] = true end
		end
		local soldCount = 0
		for _ in pairs(sellIds) do soldCount += 1 end
		if soldCount == 0 then return result(false, "没有可安全出售的重复鱼") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		local earned = 0
		for _, fish in ipairs(profile.fish) do if sellIds[fish.id] then earned += Model.salePrice(profile, fish, now) end end
		for i = #profile.fish, 1, -1 do if sellIds[profile.fish[i].id] then table.remove(profile.fish, i) end end
		profile.coins += earned
		return { ok = true, message = "已出售 " .. tostring(soldCount) .. " 条安全重复鱼", soldCount = soldCount, earned = earned }
	elseif action == "place" or action == "remove" or action == "sell" or action == "lock" then
		if not validPayloadId(payload) then return result(false, "鱼 ID 无效") end
		local fish, index = findFish(profile, payload.id)
		if not fish then return result(false, "找不到鱼") end
		if action == "place" then
			if fish.placed then return result(false, "鱼已在水族馆") end
			if countPlaced(profile) >= profile.tankCapacity then return result(false, "水族馆已满") end
			local ok, err = settleForCommand(profile, now); if not ok then return err end
			if profile.showcaseFishId == fish.id then profile.showcaseFishId = nil end
			fish.placed = true
		elseif action == "remove" then
			if not fish.placed then return result(false, "鱼不在水族馆") end
			if countBag(profile) >= profile.bagCapacity then return result(false, "背包空间不足") end
			local ok, err = settleForCommand(profile, now); if not ok then return err end
			fish.placed = false
		elseif action == "sell" then
			if fish.placed or fish.locked then return result(false, "锁定或入缸的鱼不能出售") end
			if profile.showcaseFishId == fish.id then return result(false, "展示中的鱼不能消耗，请先收起展示") end
			if payload.expectedSalePrice ~= nil then
				if not finiteNumber(payload.expectedSalePrice) or payload.expectedSalePrice < 0 then return result(false, "售价确认无效") end
				if math.abs(payload.expectedSalePrice - Model.salePrice(profile, fish, now)) > EPSILON then return result(false, "售价已变化，请重新确认") end
			end
			local ok, err = settleForCommand(profile, now); if not ok then return err end
			local earned = Model.salePrice(profile, fish, now)
			table.remove(profile.fish, index)
			profile.coins += earned
			return { ok = true, message = "出售成功", earned = earned, salePrice = earned }
		else
			-- Pure/internal legacy callers may omit `locked`; the network gate
			-- always supplies it, and an explicit false is a real desired state.
			if payload.locked ~= nil and type(payload.locked) ~= "boolean" then return result(false, "锁定状态无效") end
			fish.locked = if payload.locked == nil then not fish.locked else payload.locked
		end
		return result(true, action == "lock" and "锁定状态已更新" or "操作成功", { copyFish(fish, profile, now) })
	elseif action == "merge" then
		local requestedMergeIds = denseIdArray(payload.ids)
		if not requestedMergeIds or #requestedMergeIds ~= 3 then return result(false, "需要三条鱼") end
		local sources, seen = {}, {}
		for i = 1, 3 do
			local id = requestedMergeIds[i]
			if type(id) ~= "string" or seen[id] then return result(false, "合成材料无效") end
			seen[id] = true
			local fish = findFish(profile, id)
			if not fish or fish.locked then return result(false, "合成材料不可用") end
			table.insert(sources, fish)
		end
		if sources[1].level >= 10 then return result(false, "已达最高等级") end
		for i = 2, 3 do if sources[i].species ~= sources[1].species or sources[i].level ~= sources[1].level then return result(false, "需要同物种同等级") end end
		if profile.showcaseFishId and seen[profile.showcaseFishId] then return result(false, "展示中的鱼不能消耗，请先收起展示") end
		local acknowledged, acknowledgementMessage = placedAcknowledgement(sources, payload.acknowledgedPlacedIds)
		if not acknowledged then return result(false, acknowledgementMessage) end
		local bagAfter = countBag(profile)
		for _, fish in ipairs(sources) do if not fish.placed then bagAfter -= 1 end end
		if bagAfter + 1 > profile.bagCapacity then return result(false, "背包空间不足") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		local value, weightTotal, latestCaught, catchZone = 0, 0, 0, 1
		local selectedTrait, selectedPriority = "ordinary", 0
		for _, fish in ipairs(sources) do
			value += fish.value
			weightTotal += fishWeight(fish)
			latestCaught = math.max(latestCaught, fishCaughtAt(fish, profile))
			catchZone = math.max(catchZone, fishCatchZone(fish))
			local trait = fishTrait(fish)
			local priority = Config.TraitPriority[trait] or 0
			if priority > selectedPriority then selectedTrait, selectedPriority = trait, priority end
		end
		for i = #profile.fish, 1, -1 do if seen[profile.fish[i].id] then table.remove(profile.fish, i) end end
		local income = mergedBaseIncome(sources)
		local merged = addFish(profile, { species = sources[1].species, level = sources[1].level + 1, size = sources[1].size, mutation = sources[1].mutation, value = value, income = income, weightGrams = math.max(1, math.floor(weightTotal / 3 + 0.5)), trait = selectedTrait, catchZone = catchZone, caughtAt = latestCaught, catchSource = "merge" })
		return result(true, "合成成功", { copyFish(merged, profile, now) })
	elseif action == "upgrade" then
		if type(payload.kind) ~= "string" then return result(false, "升级无效") end
		local info = upgradeInfo(profile)[payload.kind]
		if not info then return result(false, "升级无效") end
		local hasExpectedLevel = payload.expectedLevel ~= nil
		local hasExpectedCost = payload.expectedCost ~= nil
		if hasExpectedLevel or hasExpectedCost then
			if not hasExpectedLevel or not hasExpectedCost
				or not integer(payload.expectedLevel) or payload.expectedLevel < 0
				or not finiteNumber(payload.expectedCost) or payload.expectedCost < 0 then
				return result(false, "升级确认无效")
			end
			if info.cost == nil or payload.expectedLevel ~= info.level or math.abs(payload.expectedCost - info.cost) > EPSILON then
				return result(false, "升级状态已变化，请刷新")
			end
		end
		if not info.cost then return result(false, "已达上限") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		if profile.coins + EPSILON < info.cost then return result(false, "金币不足") end
		profile.coins -= info.cost
		if payload.kind == "hooks" then profile.hooks += 1 elseif payload.kind == "luck" then profile.luck += 1 elseif payload.kind == "coins" then profile.coinLevel += 1 elseif payload.kind == "tank" then profile.tankCapacity += 1 else profile.bagCapacity += 100 end
		return result(true, "升级成功")
	elseif action == "unlock" then
		if not integer(payload.zone) or payload.zone ~= profile.zone + 1 then return result(false, "只能解锁下一水域") end
		local zone = Config.Zones[payload.zone]
		if not zone then return result(false, "水域无效") end
		if zone.requiredLevel and Model.playerProgress(profile).playerLevel < zone.requiredLevel then return result(false, "玩家等级不足") end
		if discoveryCount(profile) < zone.requiredDiscoveries then return result(false, "解锁条件不足") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		if profile.coins + EPSILON < zone.cost then return result(false, "金币不足") end
		profile.coins -= zone.cost
		profile.zone = payload.zone
		return result(true, "水域已解锁")
	elseif action == "contract" then
		if type(payload.species) ~= "string" or not Config.SpeciesById[payload.species] or not profile.discovered[payload.species] then return result(false, "委托目标无效") end
		local today = utcDay(now)
		local caughtToday = profile.day == today and profile.dailyCaught or 0
		if discoveryCount(profile) < 21 or caughtToday < 100 or profile.contractDay == today then return result(false, "委托条件不足") end
		local contract = Config.Contract
		local rewardCount = contract.rewardFishCount
		if countBag(profile) + rewardCount > profile.bagCapacity then return result(false, "背包空间不足") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		local species = Config.SpeciesById[payload.species]
		local rarity = Config.Rarities[species.rarity]
		local rewardLevel = Config.contractRewardLevel(profile.discovered[species.id])
		local levelMultiplier = 3 ^ (rewardLevel - 1)
		local incomeMultiplier = levelMultiplier * (1.05 ^ (rewardLevel - 1))
		local weightRange = weightRangeFor(species, species.rarity)
		local fish = {}
		for _ = 1, rewardCount do
			table.insert(fish, copyFish(addFish(profile, { species = species.id, level = rewardLevel, size = 2, mutation = 1, value = rarity.sell * levelMultiplier, income = rarity.income * incomeMultiplier, weightGrams = weightRange.standard, trait = "ordinary", catchZone = species.zone, caughtAt = now, catchSource = "contract" }), profile, now))
		end
		profile.contractDay = today
		return result(true, "委托奖励已领取", fish)
	elseif action == "exchange" then
		if not validRequestId(payload) or type(payload.recipeId) ~= "string" or type(payload.ids) ~= "table" then return result(false, "兑换请求无效") end
		if requestReplay(context, payload.requestId) then return { ok = true, message = "兑换请求已处理", replayed = true } end
		local recipe = recipeById(payload.recipeId)
		local requiredCount = recipe and (recipe.fishCount or recipe.count or 3) or 0
		if not recipe or #payload.ids ~= requiredCount then return result(false, "兑换配方无效") end
		local sources, seen = {}, {}
		for _, id in ipairs(payload.ids) do
			if type(id) ~= "string" or seen[id] then return result(false, "兑换材料重复") end
			seen[id] = true
			local fish = findFish(profile, id)
			local species = fish and speciesFor(fish)
			if not fish or fish.placed or fish.locked or fish.level ~= (recipe.requiredLevel or 1) or not species or species.rarity < (recipe.minRarity or 1) then return result(false, "兑换材料不符合条件") end
			table.insert(sources, fish)
		end
		if profile.showcaseFishId and seen[profile.showcaseFishId] then return result(false, "展示中的鱼不能消耗，请先收起展示") end
		if itemCount(profile, recipe.itemId) >= (Config.MaxItemStack or 9999) then return result(false, "道具已达持有上限") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		for i = #profile.fish, 1, -1 do if seen[profile.fish[i].id] then table.remove(profile.fish, i) end end
		profile.items = profile.items or {}
		profile.items[recipe.itemId] = itemCount(profile, recipe.itemId) + 1
		rememberRequest(context, payload.requestId)
		return { ok = true, message = "兑换成功", itemId = recipe.itemId, count = 1, consumedIds = payload.ids }
	elseif action == "useItem" then
		if not validRequestId(payload) or type(payload.itemId) ~= "string" then return result(false, "使用请求无效") end
		if requestReplay(context, payload.requestId) then return { ok = true, message = "使用请求已处理", replayed = true } end
		local item = Config.BoostItems[payload.itemId]
		if not item or itemCount(profile, payload.itemId) < 1 then return result(false, "道具不足") end
		local active = profile.activeBoosts and profile.activeBoosts[item.kind]
		local maximumUntil = now + (Config.MaxBoostDurationSeconds or 3600)
		if active and active.untilTime >= maximumUntil then return result(false, "同类加成已达时长上限") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		local startAt = now
		if active and active.untilTime > now then startAt = active.untilTime end
		local untilTime = math.min(startAt + item.durationSeconds, now + (Config.MaxBoostDurationSeconds or 3600))
		profile.items[payload.itemId] -= 1
		profile.activeBoosts = profile.activeBoosts or {}
		profile.activeBoosts[item.kind] = { itemId = item.id, untilTime = untilTime }
		rememberRequest(context, payload.requestId)
		return { ok = true, message = "道具已使用", itemId = item.id, kind = item.kind, untilTime = untilTime }
	elseif action == "showcase" then
		if not validPayloadId(payload) then return result(false, "展示鱼 ID 无效") end
		local fish = findFish(profile, payload.id)
		if not fish then return result(false, "找不到鱼") end
		if fish.placed then return result(false, "入缸的鱼不能抱出展示") end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		profile.showcaseFishId = fish.id
		return { ok = true, message = "已抱鱼展示", showcaseFishId = fish.id, fish = copyFish(fish, profile, now) }
	elseif action == "hideFish" then
		if profile.showcaseFishId == nil then return { ok = true, message = "展示已收起", showcaseFishId = nil } end
		local ok, err = settleForCommand(profile, now); if not ok then return err end
		profile.showcaseFishId = nil
		return { ok = true, message = "展示已收起", showcaseFishId = nil }
	end
	return result(false, "未知操作")
end

local function previewFailure(reason)
	return { ok = false, allowed = false, reason = reason }
end

local function previewValues(profile, now, currentBase, beforeShowcaseId, projectedBase, afterShowcaseId, fish, projectedPlaced, resultBase)
	local currentMultiplier = incomeMultiplierForShowcase(profile, now, beforeShowcaseId)
	local projectedMultiplier = incomeMultiplierForShowcase(profile, now, afterShowcaseId)
	local currentTotal = currentBase * currentMultiplier
	local projectedTotal = projectedBase * projectedMultiplier
	local preview = {
		ok = true,
		allowed = true,
		reason = "",
		currentTotalPerHour = currentTotal,
		projectedTotalPerHour = projectedTotal,
		deltaPerHour = projectedTotal - currentTotal,
		showcaseBeforeId = beforeShowcaseId,
		showcaseAfterId = afterShowcaseId,
		showcaseBonusBefore = showcasedTraitBonusForId(profile, "coinBonus", beforeShowcaseId),
		showcaseBonusAfter = showcasedTraitBonusForId(profile, "coinBonus", afterShowcaseId),
		resultBasePerHour = resultBase,
	}
	if fish then
		preview.fishBasePerHour = fish.income
		preview.currentFishPerHour = fish.placed and fish.income * currentMultiplier or 0
		preview.projectedFishPerHour = projectedPlaced and fish.income * projectedMultiplier or 0
	end
	return preview
end

local function incomePreviewFish(profile, now, request)
	if type(request.action) ~= "string" then return previewFailure("预览动作无效") end
	local action = request.action
	if action == "hideFish" then
		if request.id ~= nil then return previewFailure("隐藏展示不接受鱼 ID") end
		local currentBase = placedIncomeTotal(profile)
		local showcase = showcaseFish(profile)
		local beforeShowcaseId = showcase and showcase.id or nil
		-- The command is intentionally idempotent when there is no current
		-- showcase, so this one no-op does not need to settle or reject an old
		-- timestamp. Hiding an existing showcase follows command settlement.
		if showcase and now < profile.lastSettled then return previewFailure("时间不能倒退") end
		local preview = previewValues(profile, now, currentBase, beforeShowcaseId, currentBase, nil, nil, nil, nil)
		return preview
	end
	if action ~= "place" and action ~= "remove" and action ~= "showcase" then return previewFailure("预览动作无效") end
	if type(request.id) ~= "string" or #request.id == 0 or #request.id > 80 then return previewFailure("鱼 ID 无效") end
	local fish = findFish(profile, request.id)
	if not fish then return previewFailure("找不到鱼") end

	local currentBase = placedIncomeTotal(profile)
	local showcase = showcaseFish(profile)
	local beforeShowcaseId = showcase and showcase.id or nil
	local afterShowcaseId = beforeShowcaseId
	local projectedBase = currentBase
	local projectedPlaced = fish.placed
	local allowed = true
	local reason = ""
	if action == "place" then
		if fish.placed then return previewFailure("鱼已在水族馆") end
		projectedBase += fish.income
		projectedPlaced = true
		if afterShowcaseId == fish.id then afterShowcaseId = nil end
		if countPlaced(profile) >= profile.tankCapacity then
			allowed = false
			reason = "水族馆已满"
		end
	elseif action == "remove" then
		if not fish.placed then return previewFailure("鱼不在水族馆") end
		projectedBase -= fish.income
		projectedPlaced = false
		if countBag(profile) >= profile.bagCapacity then
			allowed = false
			reason = "背包空间不足"
		end
	elseif action == "showcase" then
		if fish.placed then return previewFailure("入缸的鱼不能抱出展示") end
		afterShowcaseId = fish.id
		projectedPlaced = false
	end
	if allowed and now < profile.lastSettled then return previewFailure("时间不能倒退") end

	local preview = previewValues(profile, now, currentBase, beforeShowcaseId, projectedBase, afterShowcaseId, fish, projectedPlaced, nil)
	preview.allowed = allowed
	preview.reason = reason
	return preview
end

local function exactThreeIds(ids)
	local dense = denseIdArray(ids)
	return dense ~= nil and #dense == 3
end

local function incomePreviewMerge(profile, now, request)
	if not exactThreeIds(request.ids) then return previewFailure("需要三条鱼") end
	local seen, sources = {}, {}
	for index = 1, 3 do
		local id = request.ids[index]
		if type(id) ~= "string" or #id == 0 or #id > 80 or seen[id] then return previewFailure("合成材料无效") end
		seen[id] = true
		local fish = findFish(profile, id)
		if not fish then return previewFailure("找不到鱼") end
		if fish.locked then return previewFailure("合成材料不可用") end
		table.insert(sources, fish)
	end
	local first = sources[1]
	if first.level >= 10 then return previewFailure("已达最高等级") end
	for index = 2, 3 do
		if sources[index].species ~= first.species or sources[index].level ~= first.level then return previewFailure("需要同物种同等级") end
	end

	local currentBase = placedIncomeTotal(profile)
	local resultBase = mergedBaseIncome(sources)
	local bagAfter = countBag(profile)
	local removedPlaced = {}
	for _, fish in ipairs(sources) do
		if fish.placed then removedPlaced[fish.id] = true else bagAfter -= 1 end
	end
	local showcase = showcaseFish(profile)
	local beforeShowcaseId = showcase and showcase.id or nil
	local afterShowcaseId = if beforeShowcaseId and seen[beforeShowcaseId] then nil else beforeShowcaseId
	local projectedBase = placedIncomeTotal(profile, removedPlaced)
	local preview = previewValues(profile, now, currentBase, beforeShowcaseId, projectedBase, afterShowcaseId, nil, nil, resultBase)
	local acknowledgementOk, acknowledgementReason, hardInvalid = placedAcknowledgement(sources, request.acknowledgedPlacedIds)
	if hardInvalid then return previewFailure(acknowledgementReason) end
	local capacityBlocked = bagAfter + 1 > profile.bagCapacity
	local blockedReason = nil
	if beforeShowcaseId and seen[beforeShowcaseId] then
		blockedReason = "展示中的鱼不能消耗，请先收起展示"
	elseif not acknowledgementOk then
		blockedReason = acknowledgementReason
	elseif capacityBlocked then
		blockedReason = "背包空间不足"
	end
	if not blockedReason and now < profile.lastSettled then return previewFailure("时间不能倒退") end
	if blockedReason then
		preview.allowed = false
		preview.reason = blockedReason
	end
	return preview
end

function Model.incomePreview(profile, now, request)
	if not validNow(now) then return previewFailure("时间无效") end
	local valid, message = Model.validate(profile)
	if not valid then return previewFailure(message or "存档无效") end
	if type(request) ~= "table" or type(request.kind) ~= "string" then return previewFailure("预览请求无效") end
	if request.kind == "fish" then return incomePreviewFish(profile, now, request) end
	if request.kind == "merge" then return incomePreviewMerge(profile, now, request) end
	return previewFailure("预览类型无效")
end

function Model.snapshot(profile, now)
	local valid, message = Model.validate(profile)
	if not valid then return { ok = false, message = message } end
	local fish = {}
	-- Sale price uses one profile-wide coin factor. Computing it once avoids
	-- rescanning the profile for the same showcased fish for every copy.
	local saleMultiplier = validNow(now) and coinMultiplier(profile, now) or nil
	for _, item in ipairs(profile.fish) do table.insert(fish, copyFish(item, profile, now, saleMultiplier)) end
	table.sort(fish, function(a, b) return tonumber(string.sub(a.id, 2)) < tonumber(string.sub(b.id, 2)) end)
	local odds = {}
	for i, value in ipairs(Model.odds(Model.effectiveLuck(profile, now))) do odds[i] = value * 100 end
	local discovered = {}
	for species, level in pairs(profile.discovered) do discovered[species] = level end
	local progress = Model.playerProgress(profile)
	local items = {}
	for itemId in pairs(Config.BoostItems) do items[itemId] = itemCount(profile, itemId) end
	local activeBoosts = {}
	if validNow(now) then
		for kind, active in pairs(profile.activeBoosts or {}) do
			local item = Config.BoostItems[active.itemId]
			if item and active.untilTime > now then
				activeBoosts[kind] = { itemId = item.id, kind = item.kind, untilTime = active.untilTime, remainingSeconds = math.max(0, active.untilTime - now), amount = item.amount or 0, multiplier = item.multiplier or 1 }
			end
		end
	end
	local showcase = showcaseFish(profile)
	local showcaseFishId = showcase and showcase.id or nil
	local displayedDailyCaught = validNow(now) and profile.day == utcDay(now) and profile.dailyCaught or 0
		return {
		ok = true,
		version = profile.version,
		mutationProtocol = profile.mutationProtocol,
		mutationWatermarks = MutationProtocol.clone(Model.mutationWatermarks(profile)),
		coins = profile.coins,
		hooks = profile.hooks,
		luck = profile.luck,
		effectiveLuck = Model.effectiveLuck(profile, now),
		coinLevel = profile.coinLevel,
		tankCapacity = profile.tankCapacity,
		bagCapacity = profile.bagCapacity,
		zone = profile.zone,
		fish = fish,
		discovered = discovered,
		nextId = profile.nextId,
		lastSettled = profile.lastSettled,
		totalCaught = profile.totalCaught,
		day = profile.day,
		-- `day` is the persisted progress cursor.  The client needs the
		-- authoritative UTC day as well so a claim made yesterday is not
		-- mistaken for today's claim before the player catches anything.
		currentDay = validNow(now) and utcDay(now) or nil,
		dailyCaught = displayedDailyCaught,
		contractDay = profile.contractDay,
		boostUntil = profile.boostUntil,
		doubleIncome = profile.doubleIncome,
		incomePerHour = incomeRate(profile, now),
		odds = odds,
		upgrades = upgradeInfo(profile),
		discoveryCount = discoveryCount(profile),
		xp = progress.xp,
		totalXP = progress.totalXP,
		playerLevel = progress.playerLevel,
		xpToNextLevel = progress.xpToNextLevel,
		showcaseFishId = showcaseFishId,
		items = items,
		activeBoosts = activeBoosts,
	}
end

return Model
