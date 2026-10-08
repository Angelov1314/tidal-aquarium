local ThemeContent = require("../src/shared/ThemeContent")
local ArtCatalog = require("../src/shared/ArtCatalog")
local Config = require("../src/shared/Config")
local WorldLayout = require("../src/shared/WorldLayout")

local function expect(condition, message)
	if not condition then error(message, 2) end
end

expect(#ThemeContent.Zones == 4, "four themed zones")
local expected = {
	[6] = {name = "神秘湖", theme = "mystic_lake", cost = 450000, discoveries = 36, level = 10},
	[7] = {name = "熔岩渔场", theme = "lava_fishing_ground", cost = 650000, discoveries = 39, level = 15},
	[8] = {name = "外星水域", theme = "alien_waters", cost = 900000, discoveries = 42, level = 20},
	[9] = {name = "化学实验室", theme = "chemistry_lab", cost = 1200000, discoveries = 45, level = 25},
}

local seenIds, seenNames, seenTemplates = {}, {}, {}
for _, zone in ipairs(ThemeContent.Zones) do
	local contract = expected[zone.id]
	expect(contract ~= nil, "unexpected themed zone id")
	expect(zone.name == contract.name and zone.theme == contract.theme, "zone identity")
	local layout = WorldLayout.Zones[zone.id]
	expect(layout ~= nil and zone.center.x == layout.x and zone.center.z == layout.z, "zone center must follow WorldLayout")
	expect(zone.cost == contract.cost and zone.requiredDiscoveries == contract.discoveries and zone.discoveries == contract.discoveries, "zone unlock cost/discoveries")
	expect(zone.requiredLevel == contract.level and zone.themeOnly == true, "zone level/theme-only contract")
	local rarityCount = {}
	for _, species in ipairs(ThemeContent.Species) do
		if species.zone == zone.id then
			rarityCount[species.rarity] = (rarityCount[species.rarity] or 0) + 1
			expect(type(species.baseWeightGrams) == "number" and species.baseWeightGrams > 0, "positive themed base weight")
			expect(ArtCatalog.Fish[species.id] == species.template, "catalog template mapping")
			expect(seenIds[species.id] == nil and seenNames[species.name] == nil and seenTemplates[species.template] == nil, "duplicate themed key")
			seenIds[species.id], seenNames[species.name], seenTemplates[species.template] = true, true, true
		end
	end
	for rarity = 1, 7 do expect(rarityCount[rarity] == 1, "each themed zone has one species per rarity") end
end
expect(#ThemeContent.Species == 28, "28 themed species")
expect(#Config.Zones == 9 and #Config.Species == 70, "Config appends themed content to 9 zones / 70 species")

print("ThemeContent.spec: 4 zones, 28 species, complete rarity pools, stable template mappings PASS")
