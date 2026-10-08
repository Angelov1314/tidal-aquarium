-- QA project only. Verifies uploaded Meshy fish in the presentation adapter.
-- This smoke test has no dependency on audio or the economy service.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local Catalog = require(shared:WaitForChild("ArtCatalog"))
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local ThemeContent = require(shared:WaitForChild("ThemeContent"))

local expectedSpeciesCount = 70
local expectedZoneCount = 9
local expectedFishTemplateCount = 74
assert(#Config.Species == expectedSpeciesCount, "Species count changed: " .. tostring(#Config.Species))
assert(#Config.Zones == expectedZoneCount, "Zone count changed: " .. tostring(#Config.Zones))

local function hasTexture(template)
    for _, object in template:GetDescendants() do
        if object:IsA("MeshPart") and object.TextureID ~= "" then return true end
        if object:IsA("SurfaceAppearance") and object.ColorMap ~= "" then return true end
    end
    return false
end

local function inspectTemplate(name)
    local template = assert(ArtRenderer.template(name), "Missing Meshy template: " .. name)
    local meshes = 0
    for _, object in template:GetDescendants() do
        if object:IsA("MeshPart") then
            meshes += 1
            assert(object.MeshId ~= "", name .. " missing uploaded mesh")
        end
    end
    assert(meshes > 0, name .. " has no MeshPart")
    assert(hasTexture(template), name .. " missing TextureID or SurfaceAppearance ColorMap")
    return template
end

local function addLabel(parent, text, position)
    local anchor = Instance.new("Part")
    anchor.Name = "LabelAnchor"
    anchor.Size = Vector3.new(.1, .1, .1)
    anchor.Transparency = 1
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanTouch = false
    anchor.CanQuery = false
    anchor.Position = position + Vector3.new(0, 2.6, 0)
    anchor.Parent = parent

    local gui = Instance.new("BillboardGui")
    gui.Name = "Label"
    gui.Size = UDim2.fromOffset(240, 42)
    gui.AlwaysOnTop = true
    gui.Parent = anchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundColor3 = Color3.fromRGB(20, 48, 66)
    label.BackgroundTransparency = .1
    label.TextColor3 = Color3.fromRGB(255, 248, 229)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 18
    label.Text = text
    label.Parent = gui
end

local speciesIds = {}
for _, species in Config.Species do
    assert(not speciesIds[species.id], "Duplicate species ID: " .. species.id)
    speciesIds[species.id] = true
    local template = Catalog.Fish[species.id]
    assert(template and ArtRenderer.template(template), "Species template missing: " .. species.id)
end
for _, species in ThemeContent.Species do
    assert(Catalog.Fish[species.id] == species.template, "Theme catalog mapping changed: " .. species.id)
end
local propNames = {}
for _, name in Catalog.Props do propNames[name] = true end
local fishTemplateNames = {}
for _, child in ReplicatedStorage:WaitForChild("FishingArt"):GetChildren() do
    if child:IsA("Model") and not propNames[child.Name] then table.insert(fishTemplateNames, child.Name) end
end
table.sort(fishTemplateNames)
assert(#fishTemplateNames == expectedFishTemplateCount,
    "Fish template count changed: " .. tostring(#fishTemplateNames))
assert(speciesIds.rose_hammerhead and speciesIds.deep_crownfish, "Meshy species IDs missing")
assert(Config.SpeciesById.rose_hammerhead.name == "玫瑰萌鲨", "rose_hammerhead display name changed")
assert(Catalog.Fish.rose_hammerhead == "SharkPuppy", "SharkPuppy catalog mapping missing")
for _, name in fishTemplateNames do inspectTemplate(name) end
local display = workspace:FindFirstChild("MeshyArtSmokeDisplay")
if display then display:Destroy() end
display = Instance.new("Folder")
display.Name = "MeshyArtSmokeDisplay"
display:SetAttribute("QAOnly", true)
display.Parent = workspace

local platform = Instance.new("Part")
platform.Name = "Platform"
platform.Size = Vector3.new(18, 1, 9)
platform.Position = Vector3.new(0, 7, 22)
platform.Anchored = true
platform.CanCollide = false
platform.CanTouch = false
platform.CanQuery = false
platform.Color = Color3.fromRGB(36, 93, 108)
platform.Material = Enum.Material.Slate
platform.Parent = display

local cases = {
    { id = "rose_hammerhead", name = "SharkPuppy", species = Config.SpeciesById.rose_hammerhead, position = Vector3.new(-4, 9, 22) },
}
for _, entry in cases do
    local fish = { id = "Meshy_" .. entry.id, level = 1, mutation = 1 }
    local model = assert(ArtRenderer.fish(display, entry.species, fish, entry.position, 1), "ArtRenderer.fish returned nil: " .. entry.id)
    assert(model:GetAttribute("SourceTemplate") == entry.name, "Wrong source template: " .. entry.id)
    local extents = model:GetExtentsSize()
    local largest = math.max(extents.X, extents.Y, extents.Z)
    assert(math.abs(largest - 3.3) < .03, "Fish scale invalid: " .. entry.id)
    local meshes = 0
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            assert(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery,
                "Fish collision state invalid: " .. entry.id)
        end
        if object:IsA("MeshPart") then
            meshes += 1
            assert(object.MeshId ~= "", "Rendered mesh missing: " .. entry.id)
        end
    end
    assert(meshes > 0, "Rendered mesh missing: " .. entry.id)
    local contentProvider = game:GetService("ContentProvider")
    local loaded = 0
    contentProvider:PreloadAsync({model}, function(assetId, status)
        assert(status == Enum.AssetFetchStatus.Success, "Meshy asset failed to load: " .. assetId)
        loaded += 1
    end)
    assert(loaded > 0, "No Meshy assets were preloaded")
    addLabel(display, entry.species.name .. "  ·  " .. entry.name, entry.position)
end

print(string.format("FISHING_MESHY_ART_PASS: %d species; %d fish templates; SharkPuppy rendered, textured, scaled, and non-colliding", #Config.Species, #fishTemplateNames))
