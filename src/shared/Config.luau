-- Shared, presentation-safe balance data.  Keep this module free of Roblox APIs.
local Config = {}
local WorldLayout
if script then
	WorldLayout = require(script.Parent:WaitForChild("WorldLayout"))
else
	WorldLayout = require("./WorldLayout")
end

Config.RoundSeconds = 20
Config.MaxHooks = 100
Config.MaxLuck = 50
-- Luck upgrades stop at MaxLuck. Temporary items and the one showcased fish may
-- raise the effective value, but never beyond this presentation-safe cap.
Config.MaxEffectiveLuck = 75
Config.MaxCoinLevel = 30
Config.MaxTankCapacity = 100
Config.MaxBagCapacity = 3000
Config.MaxPlayerLevel = 50
Config.MaxBoostDurationSeconds = 3600
Config.MaxItemStack = 9999
Config.Products = { DoubleIncomePassId = 0, BoostProductId = 0, Enabled = false }

Config.Rarities = {
	{ name = "普通·白", color = { r = 235, g = 241, b = 245 }, chance = 0.60, sell = 10, income = 1 },
	{ name = "优良·绿", color = { r = 92, g = 205, b = 118 }, chance = 0.25, sell = 25, income = 2.5 },
	{ name = "稀有·蓝", color = { r = 74, g = 159, b = 239 }, chance = 0.10, sell = 75, income = 7.5 },
	{ name = "史诗·紫", color = { r = 164, g = 103, b = 222 }, chance = 0.038, sell = 250, income = 25 },
	{ name = "传说·金", color = { r = 245, g = 193, b = 57 }, chance = 0.01, sell = 1000, income = 100 },
	{ name = "神话·红", color = { r = 235, g = 78, b = 74 }, chance = 0.0018, sell = 5000, income = 500 },
	{ name = "秘藏·虹彩", color = { r = 245, g = 110, b = 197 }, chance = 0.0002, sell = 25000, income = 2500 },
}

Config.Sizes = {
	{ name = "小型", chance = 0.25, multiplier = 0.8 },
	{ name = "标准", chance = 0.55, multiplier = 1 },
	{ name = "大型", chance = 0.17, multiplier = 1.35 },
	{ name = "巨型", chance = 0.03, multiplier = 2 },
}

Config.Mutations = {
	{ name = "普通", chance = 0.94, multiplier = 1 },
	{ name = "闪光", chance = 0.045, multiplier = 1.5 },
	{ name = "黄金", chance = 0.013, multiplier = 2.5 },
	{ name = "棱彩", chance = 0.002, multiplier = 5 },
}

-- Traits are deliberately data-only.  `valueMultiplier` is frozen into a new
-- catch's base value; the other bonuses apply only while this trait is the
-- single showcased fish.  This prevents hoarding a bag full of lucky/gilded
-- fish from silently stacking economy bonuses.
Config.Traits = {
	ordinary = { id = "ordinary", name = "普通", valueMultiplier = 1, luckBonus = 0, coinBonus = 0, xpBonus = 0, chance = 0.82 },
	lucky = { id = "lucky", name = "幸运", valueMultiplier = 1.10, luckBonus = 3, coinBonus = 0, xpBonus = 0, chance = 0.08 },
	gilded = { id = "gilded", name = "镀金", valueMultiplier = 1.25, luckBonus = 0, coinBonus = 0.05, xpBonus = 0, chance = 0.07 },
	scholarly = { id = "scholarly", name = "学者", valueMultiplier = 1.15, luckBonus = 0, coinBonus = 0, xpBonus = 0.10, chance = 0.03 },
}
Config.TraitEntries = { Config.Traits.ordinary, Config.Traits.lucky, Config.Traits.gilded, Config.Traits.scholarly }
Config.TraitPriority = { ordinary = 1, lucky = 2, gilded = 3, scholarly = 4 }

-- Weight ranges are in grams. ThemeContent species may provide their own
-- `weightMin`/`weightMax`; these values keep the original catalog usable when
-- a species only has rarity metadata.
Config.WeightRanges = {
	{ min = 80, max = 140, standard = 100 },
	{ min = 160, max = 300, standard = 220 },
	{ min = 320, max = 600, standard = 450 },
	{ min = 700, max = 1300, standard = 1000 },
	{ min = 1500, max = 2800, standard = 2100 },
	{ min = 3200, max = 6000, standard = 4500 },
	{ min = 7000, max = 14000, standard = 10000 },
}

-- A daily contract helps continue a species' existing merge path. It never
-- creates a level-six jump from a first discovery, and the cap keeps legacy
-- high-history records from escalating future contract rewards above level 6.
Config.Contract = {
	rewardFishCount = 3,
	minimumRewardLevel = 1,
	maximumRewardLevel = 6,
}

function Config.contractRewardLevel(historyLevel)
	local level = tonumber(historyLevel) or Config.Contract.minimumRewardLevel
	if level ~= level or level == math.huge or level == -math.huge then level = Config.Contract.minimumRewardLevel end
	level = math.floor(level)
	return math.max(Config.Contract.minimumRewardLevel, math.min(Config.Contract.maximumRewardLevel, level))
end

-- The recipes and item records are a shared UI/server contract. A recipe takes
-- exactly three unplaced, unlocked level-one fish whose species rarity reaches
-- the recipe threshold. The server remains authoritative over eligibility.
Config.ExchangeRecipes = {
	{ id = "exchange_luck", itemId = "luck_tonic", name = "幸运药剂", fishCount = 3, count = 3, minRarity = 1, requiredLevel = 1 },
	{ id = "exchange_coins", itemId = "coin_tonic", name = "金币加成药剂", fishCount = 3, count = 3, minRarity = 2, requiredLevel = 1 },
	{ id = "exchange_xp", itemId = "xp_tonic", name = "经验加成药剂", fishCount = 3, count = 3, minRarity = 3, requiredLevel = 1 },
}
Config.BoostItems = {
	luck_tonic = { id = "luck_tonic", name = "幸运药剂", kind = "luck", durationSeconds = 600, amount = 10, multiplier = 1 },
	coin_tonic = { id = "coin_tonic", name = "金币加成药剂", kind = "coins", durationSeconds = 600, amount = 0, multiplier = 1.5 },
	xp_tonic = { id = "xp_tonic", name = "经验加成药剂", kind = "xp", durationSeconds = 600, amount = 0, multiplier = 1.5 },
}

Config.Zones = {
	{ id = 1, name = "晨湾", cost = 0, requiredDiscoveries = 0, center = { x = 0, z = 0 }, color = { r = 63, g = 174, b = 196 } },
	{ id = 2, name = "珊瑚浅滩", cost = 2500, requiredDiscoveries = 6, center = { x = 200, z = 0 }, color = { r = 239, g = 136, b = 122 } },
	{ id = 3, name = "蓝潮海沟", cost = 15000, requiredDiscoveries = 14, center = { x = 400, z = 0 }, color = { r = 51, g = 107, b = 188 } },
	{ id = 4, name = "月影礁", cost = 75000, requiredDiscoveries = 24, center = { x = 600, z = 0 }, color = { r = 104, g = 86, b = 166 } },
	{ id = 5, name = "虹光深海", cost = 350000, requiredDiscoveries = 35, center = { x = 800, z = 0 }, color = { r = 239, g = 180, b = 61 } },
}

-- Six species per rarity; their zone layout is 1,1,2,3,4,5 for every tier.
local speciesRows = {
	{"white_koi","白云锦鲤"},{"sand_goby","金沙虾虎"},{"mint_molly","薄荷茉莉"},{"reed_carp","芦苇鲤"},{"sunny_dace","晴日雅罗"},{"pearl_sardine","珍珠沙丁"},
	{"jade_tetra","翡翠灯鱼"},{"coral_butterfly","珊瑚蝶鱼"},{"seafoam_dory","海沫多莉"},{"moss_catfish","苔纹鲶"},{"lime_angelfish","青柠神仙"},{"kelp_rabbitfish","海带兔鱼"},
	{"azure_seahorse","湛蓝海马"},{"stripe_clownfish","斑纹小丑鱼"},{"crystal_ray","水晶鳐"},{"moon_jellyfish","月光水母"},{"cobalt_parrotfish","钴蓝鹦嘴鱼"},{"glacier_eel","冰川鳗"},
	{"violet_lionfish","紫雾狮子鱼"},{"orchid_octopus","兰花章鱼"},{"star_manta","星砂蝠鲼"},{"twilight_squid","暮色乌贼"},{"amethyst_tuna","紫晶金枪鱼"},{"deep_crownfish","深海冠鱼"},
	{"golden_arowana","金鳞龙鱼"},{"amber_swordfish","琥珀旗鱼"},{"sun_crowned_koi","日冕锦鲤"},{"treasure_turtle","宝匣海龟"},{"royal_marlin","皇家枪鱼"},{"aurora_whale","极光鲸"},
	{"crimson_dragonfish","赤焰龙鱼"},{"rose_hammerhead","玫瑰萌鲨"},{"ember_lobster","余烬龙虾"},{"blood_moon_ray","血月鳐"},{"scarlet_leviathan","绯红巨兽"},{"volcanic_serpent","熔岩海蛇"},
	{"rainbow_kirin","虹彩麒麟鱼"},{"prism_narwhal","棱镜独角鲸"},{"nebula_jelly","星云水母"},{"dream_coral_dragon","幻珊龙"},{"celestial_koi","天穹锦鲤"},{"eternal_phoenixfish","永昼凤尾鱼"},
}

Config.Species = {}
Config.SpeciesById = {}
for rarity = 1, #Config.Rarities do
	for column = 1, 6 do
		local row = speciesRows[(rarity - 1) * 6 + column]
		local zone = (column <= 2 and 1) or (column - 1)
		local item = { id = row[1], name = row[2], rarity = rarity, zone = zone,
			color = Config.Rarities[rarity].color, shape = ((column - 1) % 4) + 1 }
		table.insert(Config.Species, item)
		Config.SpeciesById[item.id] = item
	end
end

-- ThemeContent is authored by the world/content agent. Requiring it is
-- optional so the domain tests and old CLI fixtures still run before that
-- module is present. Existing IDs are never replaced; theme data is appended
-- in the order authored by the content module.
local function optionalThemeContent()
	local ok, content
	if script then
		local module = script.Parent:FindFirstChild("ThemeContent")
		if module then ok, content = pcall(require, module) end
	else
		ok, content = pcall(require, "./ThemeContent")
	end
	if ok and type(content) == "table" then return content end
	return nil
end

local theme = optionalThemeContent()
if theme then
	for _, zone in ipairs(theme.Zones or {}) do
		if type(zone) == "table" and type(zone.id) == "number" and not Config.Zones[zone.id] then
			Config.Zones[zone.id] = zone
		end
	end
	for _, species in ipairs(theme.Species or {}) do
		if type(species) == "table" and type(species.id) == "string" and not Config.SpeciesById[species.id] then
			local rarity = Config.Rarities[species.rarity]
			local item = {
				id = species.id,
				name = species.name or species.id,
				rarity = species.rarity,
				zone = species.zone,
				color = species.color or (rarity and rarity.color) or { r = 255, g = 255, b = 255 },
				shape = species.shape or 1,
				weightMin = species.weightMin,
				weightMax = species.weightMax,
				baseWeightGrams = species.baseWeightGrams,
				artKey = species.artKey,
				template = species.template,
				theme = species.theme,
			}
			table.insert(Config.Species, item)
			Config.SpeciesById[item.id] = item
		end
	end
end

-- WorldLayout is the single coordinate authority. Keep the economy/content
-- records above readable and stable, then attach their geometry contract once
-- all optional themed records have been appended. This changes only geometry;
-- IDs, costs, unlocks and species remain owned by Config/ThemeContent.
Config.WorldLayout = WorldLayout
for id, layout in pairs(WorldLayout.Zones) do
	local zone = Config.Zones[id]
	if zone then
		zone.x = layout.x
		zone.z = layout.z
		zone.center = { x = layout.x, z = layout.z }
		zone.shape = layout.shape
		zone.width = layout.width
		zone.depth = layout.depth
	end
end

function Config.hookCost(level) return 100 * level * level end
function Config.luckCost(level) return math.ceil(1000 * (1.18 ^ level)) end
function Config.coinCost(level) return math.ceil(750 * (1.22 ^ level)) end
-- Tank grows one slot at a time. Bag grows in 100-slot pages.
function Config.tankCost(capacity) return 500 * capacity * capacity end
function Config.bagCost(capacity) return 500 * ((capacity / 100) ^ 2) end

return Config
