-- Pure mapping contract. Engine material loading is covered by
-- FishArtCoverageSmoke.client.luau; this spec only checks the data side.
local Config = require("../src/shared/Config")
local Catalog = require("../src/shared/ArtCatalog")
local ThemeContent = require("../src/shared/ThemeContent")

local function expect(condition, message)
	if not condition then error(message, 2) end
end

expect(#Config.Species == 70, "fish art coverage expects 70 species")
expect(#Config.Zones == 9, "fish art coverage expects nine zones")
local seenIds = {}
local seenNames = {}
for _, species in ipairs(Config.Species) do
	expect(not seenIds[species.id], "duplicate species id: " .. tostring(species.id))
	seenIds[species.id] = true
	local template = Catalog.Fish[species.id]
	expect(type(template) == "string" and template ~= "", "missing ArtCatalog mapping: " .. tostring(species.id))
	seenNames[template] = true
end

local themeCount = 0
for _, species in ipairs(ThemeContent.Species) do
	themeCount += 1
	expect(Catalog.Fish[species.id] == species.template, "theme mapping drift: " .. species.id)
	expect(seenIds[species.id] == true, "theme species not appended: " .. species.id)
end
expect(themeCount == 28, "theme art coverage expects 28 species")

local propCount = 0
for alias, template in pairs(Catalog.Props) do
	propCount += 1
	expect(alias ~= "" and type(template) == "string" and template ~= "", "invalid prop mapping")
end
expect(propCount == 7, "prop catalog count changed")
local uniqueTemplateCount = 0
for _ in pairs(seenNames) do uniqueTemplateCount += 1 end
print(string.format("FishArtCoverage.spec: %d species, %d unique mapped templates, %d themed species, %d props PASS", #Config.Species, uniqueTemplateCount, themeCount, propCount))
