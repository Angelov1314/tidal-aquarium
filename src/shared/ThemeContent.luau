-- Canonical content contract for the four themed fishing locations.
-- Economy code appends these records to Config without renumbering the
-- original 42 species or five zones.
local ThemeContent = {}
local WorldLayout
if script then
	WorldLayout = require(script.Parent:WaitForChild("WorldLayout"))
else
	WorldLayout = require("./WorldLayout")
end

local function center(id)
	local layout = WorldLayout.Zones[id]
	return { x = layout.x, z = layout.z }
end

ThemeContent.Zones = {
	{
		id = 6,
		name = "神秘湖",
		theme = "mystic_lake",
		cost = 450000,
		requiredDiscoveries = 36,
		discoveries = 36,
		requiredLevel = 10,
		center = center(6),
		color = { r = 88, g = 160, b = 177 },
		themeOnly = true,
	},
	{
		id = 7,
		name = "熔岩渔场",
		theme = "lava_fishing_ground",
		cost = 650000,
		requiredDiscoveries = 39,
		discoveries = 39,
		requiredLevel = 15,
		center = center(7),
		color = { r = 208, g = 79, b = 52 },
		themeOnly = true,
	},
	{
		id = 8,
		name = "外星水域",
		theme = "alien_waters",
		cost = 900000,
		requiredDiscoveries = 42,
		discoveries = 42,
		requiredLevel = 20,
		center = center(8),
		color = { r = 112, g = 225, b = 194 },
		themeOnly = true,
	},
	{
		id = 9,
		name = "化学实验室",
		theme = "chemistry_lab",
		cost = 1200000,
		requiredDiscoveries = 45,
		discoveries = 45,
		requiredLevel = 25,
		center = center(9),
		color = { r = 169, g = 126, b = 223 },
		themeOnly = true,
	},
}

-- Seven species per theme, in rarity order.  Template names are stable
-- integration keys for the generated FishingArt derivatives.
ThemeContent.Species = {
	-- 神秘湖: reflective water, lotus and moonlight accents.
	{ id = "mystic_lake_lotus_carp", name = "莲影锦鲤", zone = 6, rarity = 1, color = { r = 119, g = 186, b = 188 }, shape = 1, baseWeightGrams = 240, template = "MysticLake_LotusCarp", theme = "mystic_lake" },
	{ id = "mystic_lake_lantern_goby", name = "灯笼虾虎", zone = 6, rarity = 2, color = { r = 104, g = 218, b = 190 }, shape = 2, baseWeightGrams = 360, template = "MysticLake_LanternGoby", theme = "mystic_lake" },
	{ id = "mystic_lake_moonfin", name = "月弦鱼", zone = 6, rarity = 3, color = { r = 89, g = 157, b = 236 }, shape = 3, baseWeightGrams = 620, template = "MysticLake_Moonfin", theme = "mystic_lake" },
	{ id = "mystic_lake_spirit_koi", name = "灵纹锦鲤", zone = 6, rarity = 4, color = { r = 167, g = 117, b = 231 }, shape = 1, baseWeightGrams = 1100, template = "MysticLake_SpiritKoi", theme = "mystic_lake" },
	{ id = "mystic_lake_oracle_eel", name = "预言鳗", zone = 6, rarity = 5, color = { r = 245, g = 195, b = 66 }, shape = 4, baseWeightGrams = 1700, template = "MysticLake_OracleEel", theme = "mystic_lake" },
	{ id = "mystic_lake_moon_whale", name = "月潮鲸", zone = 6, rarity = 6, color = { r = 231, g = 87, b = 115 }, shape = 2, baseWeightGrams = 4200, template = "MysticLake_MoonWhale", theme = "mystic_lake" },
	{ id = "mystic_lake_aurora_dragon", name = "极光湖龙", zone = 6, rarity = 7, color = { r = 245, g = 121, b = 206 }, shape = 3, baseWeightGrams = 6800, template = "MysticLake_AuroraDragon", theme = "mystic_lake" },

	-- 熔岩渔场: basalt, ember and heat-shimmer accents.
	{ id = "lava_fishing_cinder_guppy", name = "烬火鳍", zone = 7, rarity = 1, color = { r = 222, g = 112, b = 59 }, shape = 1, baseWeightGrams = 260, template = "LavaFishing_CinderGuppy", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_ash_puffer", name = "灰烬河豚", zone = 7, rarity = 2, color = { r = 236, g = 145, b = 63 }, shape = 2, baseWeightGrams = 420, template = "LavaFishing_AshPuffer", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_magma_tetra", name = "岩浆灯鱼", zone = 7, rarity = 3, color = { r = 242, g = 83, b = 47 }, shape = 3, baseWeightGrams = 700, template = "LavaFishing_MagmaTetra", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_basalt_lionfish", name = "玄武狮鱼", zone = 7, rarity = 4, color = { r = 174, g = 66, b = 52 }, shape = 4, baseWeightGrams = 1250, template = "LavaFishing_BasaltLionfish", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_ember_swordfish", name = "余烬剑鱼", zone = 7, rarity = 5, color = { r = 247, g = 177, b = 48 }, shape = 1, baseWeightGrams = 2100, template = "LavaFishing_EmberSwordfish", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_volcano_ray", name = "火山鳐", zone = 7, rarity = 6, color = { r = 239, g = 68, b = 46 }, shape = 2, baseWeightGrams = 5000, template = "LavaFishing_VolcanoRay", theme = "lava_fishing_ground" },
	{ id = "lava_fishing_inferno_serpent", name = "炼狱海蛇", zone = 7, rarity = 7, color = { r = 255, g = 104, b = 47 }, shape = 3, baseWeightGrams = 8400, template = "LavaFishing_InfernoSerpent", theme = "lava_fishing_ground" },

	-- 外星水域: bioluminescent fins, rings and low-gravity forms.
	{ id = "alien_waters_ring_minno", name = "环星米诺", zone = 8, rarity = 1, color = { r = 90, g = 209, b = 190 }, shape = 2, baseWeightGrams = 220, template = "AlienWaters_RingMinno", theme = "alien_waters" },
	{ id = "alien_waters_neon_molly", name = "霓虹茉莉", zone = 8, rarity = 2, color = { r = 91, g = 232, b = 224 }, shape = 1, baseWeightGrams = 390, template = "AlienWaters_NeonMolly", theme = "alien_waters" },
	{ id = "alien_waters_comet_tetra", name = "彗尾灯鱼", zone = 8, rarity = 3, color = { r = 74, g = 178, b = 245 }, shape = 3, baseWeightGrams = 680, template = "AlienWaters_CometTetra", theme = "alien_waters" },
	{ id = "alien_waters_void_octopus", name = "虚空章鱼", zone = 8, rarity = 4, color = { r = 152, g = 111, b = 236 }, shape = 4, baseWeightGrams = 1200, template = "AlienWaters_VoidOctopus", theme = "alien_waters" },
	{ id = "alien_waters_prism_narwhal", name = "棱彩独角鲸", zone = 8, rarity = 5, color = { r = 246, g = 207, b = 75 }, shape = 2, baseWeightGrams = 2300, template = "AlienWaters_PrismNarwhal", theme = "alien_waters" },
	{ id = "alien_waters_quasar_manta", name = "类星体蝠鲼", zone = 8, rarity = 6, color = { r = 229, g = 82, b = 180 }, shape = 3, baseWeightGrams = 5300, template = "AlienWaters_QuasarManta", theme = "alien_waters" },
	{ id = "alien_waters_galaxy_whale", name = "银河巨鲸", zone = 8, rarity = 7, color = { r = 204, g = 102, b = 255 }, shape = 1, baseWeightGrams = 9200, template = "AlienWaters_GalaxyWhale", theme = "alien_waters" },

	-- 化学实验室: glass, bubble, reagent and safe laboratory accents.
	{ id = "chemistry_lab_buffer_betta", name = "缓冲斗鱼", zone = 9, rarity = 1, color = { r = 118, g = 190, b = 224 }, shape = 1, baseWeightGrams = 250, template = "ChemistryLab_BufferBetta", theme = "chemistry_lab" },
	{ id = "chemistry_lab_catalyst_carp", name = "催化鲤", zone = 9, rarity = 2, color = { r = 96, g = 212, b = 169 }, shape = 2, baseWeightGrams = 410, template = "ChemistryLab_CatalystCarp", theme = "chemistry_lab" },
	{ id = "chemistry_lab_phosphor_eel", name = "荧光鳗", zone = 9, rarity = 3, color = { r = 99, g = 193, b = 244 }, shape = 4, baseWeightGrams = 720, template = "ChemistryLab_PhosphorEel", theme = "chemistry_lab" },
	{ id = "chemistry_lab_crystal_jelly", name = "晶体水母", zone = 9, rarity = 4, color = { r = 177, g = 121, b = 228 }, shape = 3, baseWeightGrams = 1300, template = "ChemistryLab_CrystalJelly", theme = "chemistry_lab" },
	{ id = "chemistry_lab_mercury_tuna", name = "银汞金枪鱼", zone = 9, rarity = 5, color = { r = 240, g = 197, b = 72 }, shape = 1, baseWeightGrams = 2400, template = "ChemistryLab_MercuryTuna", theme = "chemistry_lab" },
	{ id = "chemistry_lab_reactor_ray", name = "反应堆鳐", zone = 9, rarity = 6, color = { r = 233, g = 75, b = 118 }, shape = 2, baseWeightGrams = 5600, template = "ChemistryLab_ReactorRay", theme = "chemistry_lab" },
	{ id = "chemistry_lab_quanta_dragon", name = "量子实验龙", zone = 9, rarity = 7, color = { r = 237, g = 108, b = 219 }, shape = 4, baseWeightGrams = 9800, template = "ChemistryLab_QuantaDragon", theme = "chemistry_lab" },
}

ThemeContent.SpeciesById = {}
ThemeContent.SpeciesByTemplate = {}
for _, species in ipairs(ThemeContent.Species) do
	ThemeContent.SpeciesById[species.id] = species
	ThemeContent.SpeciesByTemplate[species.template] = species
end

return ThemeContent
