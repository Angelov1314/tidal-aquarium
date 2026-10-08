-- Procedural island authoring for the shared nine-zone world.
--
-- World owns the ocean, aquarium and fish presentation. This module owns the
-- walkable island silhouette, dock contract and landmarks so adding a zone
-- does not grow another copy of the old circular-cylinder layout in World.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("FishingShared")
local ArtRenderer = require(shared:WaitForChild("ArtRenderer"))
local FishingLocation = require(shared:WaitForChild("FishingLocation"))

local IslandBuilder = {}

local sand = Color3.fromRGB(241, 216, 163)
local wood = Color3.fromRGB(180, 125, 80)
local navy = Color3.fromRGB(28, 58, 71)
local cream = Color3.fromRGB(255, 246, 222)

-- x/z are fractions of the authored width/depth. Every recipe is biased to
-- negative Z; the centerline from z+27.65 through z+80.35 remains a physical
-- dock, and z+82 remains water for casting and the boat approach.
local SHAPES = {
	harbor_crescent = {
		{ x = 0, z = -.32, w = .64, d = .56, yaw = .04 },
		{ x = -.34, z = -.18, w = .34, d = .37, yaw = -.14 },
		{ x = .34, z = -.22, w = .34, d = .44, yaw = .13 },
		{ x = -.25, z = -.70, w = .48, d = .48, yaw = -.07 },
		{ x = .28, z = -.67, w = .38, d = .42, yaw = .09 },
	},
	coral_fan = {
		{ x = 0, z = -.39, w = .38, d = .40, yaw = 0 },
		{ x = -.28, z = -.27, w = .30, d = .42, yaw = -.28 },
		{ x = .28, z = -.28, w = .30, d = .44, yaw = .28 },
		{ x = -.42, z = -.49, w = .24, d = .33, yaw = -.52 },
		{ x = .42, z = -.50, w = .24, d = .34, yaw = .52 },
		{ x = 0, z = -.76, w = .68, d = .36, yaw = 0 },
	},
	trench_hook = {
		{ x = -.10, z = -.34, w = .43, d = .58, yaw = -.06 },
		{ x = .27, z = -.27, w = .31, d = .36, yaw = .35 },
		{ x = .40, z = -.53, w = .28, d = .48, yaw = .48 },
		{ x = .14, z = -.76, w = .42, d = .40, yaw = .05 },
		{ x = -.36, z = -.72, w = .26, d = .34, yaw = -.24 },
	},
	moon_ring = {
		{ x = -.30, z = -.34, w = .27, d = .48, yaw = -.08 },
		{ x = .30, z = -.34, w = .27, d = .48, yaw = .08 },
		{ x = -.04, z = -.64, w = .40, d = .30, yaw = 0 },
		{ x = .02, z = -.88, w = .64, d = .20, yaw = 0 },
		{ x = -.02, z = -.08, w = .56, d = .20, yaw = 0 },
	},
	rainbow_steps = {
		{ x = 0, z = -.28, w = .72, d = .30, yaw = 0 },
		{ x = -.25, z = -.51, w = .42, d = .29, yaw = -.08 },
		{ x = .28, z = -.52, w = .40, d = .29, yaw = .08 },
		{ x = -.05, z = -.76, w = .78, d = .34, yaw = 0 },
		{ x = .12, z = -.93, w = .52, d = .18, yaw = .02 },
	},
	mystic_isle = {
		{ x = 0, z = -.33, w = .70, d = .48, yaw = 0 },
		{ x = -.34, z = -.45, w = .29, d = .34, yaw = -.2 },
		{ x = .34, z = -.48, w = .29, d = .40, yaw = .2 },
		{ x = 0, z = -.75, w = .82, d = .39, yaw = 0 },
	},
	basalt_hook = {
		{ x = -.05, z = -.31, w = .48, d = .45, yaw = -.05 },
		{ x = -.34, z = -.47, w = .30, d = .40, yaw = -.32 },
		{ x = -.43, z = -.73, w = .27, d = .48, yaw = -.42 },
		{ x = -.12, z = -.91, w = .46, d = .24, yaw = -.08 },
		{ x = .28, z = -.74, w = .35, d = .29, yaw = .35 },
	},
	signal_atoll = {
		{ x = -.30, z = -.38, w = .28, d = .46, yaw = -.05 },
		{ x = .30, z = -.38, w = .28, d = .46, yaw = .05 },
		{ x = 0, z = -.67, w = .55, d = .26, yaw = 0 },
		{ x = 0, z = -.90, w = .84, d = .23, yaw = 0 },
		{ x = 0, z = -.10, w = .55, d = .18, yaw = 0 },
	},
	laboratory_spur = {
		{ x = 0, z = -.30, w = .76, d = .36, yaw = 0 },
		{ x = -.27, z = -.58, w = .45, d = .31, yaw = -.08 },
		{ x = .31, z = -.58, w = .40, d = .32, yaw = .1 },
		{ x = -.10, z = -.82, w = .68, d = .34, yaw = -.02 },
		{ x = .25, z = -.94, w = .30, d = .17, yaw = .16 },
	},
}

local function colorFrom(value, fallback)
	if type(value) ~= "table" then return fallback end
	local r, g, b = tonumber(value.r), tonumber(value.g), tonumber(value.b)
	if not r or not g or not b then return fallback end
	return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
end

local function makePart(stats, parent, name, size, cf, color, material, canCollide, transparency)
	local object = Instance.new("Part")
	stats.instances += 1
	object.Name = name
	object.Size = size
	object.CFrame = cf
	object.Color = color
	object.Material = material or Enum.Material.SmoothPlastic
	object.Anchored = true
	object.TopSurface = Enum.SurfaceType.Smooth
	object.BottomSurface = Enum.SurfaceType.Smooth
	object.Transparency = transparency or 0
	object.CanCollide = canCollide ~= false
	object.CanTouch = canCollide ~= false
	object.CanQuery = canCollide ~= false
	object.Parent = parent
	return object
end

local function makeBall(stats, parent, name, position, size, color, material, canCollide)
	local object = makePart(stats, parent, name, size, CFrame.new(position), color, material, canCollide)
	object.Shape = Enum.PartType.Ball
	return object
end

local function makeCylinder(stats, parent, name, position, radius, height, color, material, canCollide)
	-- Roblox cylinders use their local X axis as the long axis. Rotate that
	-- axis upright so towers/pools are vertical instead of lying on a side.
	local object = makePart(stats, parent, name, Vector3.new(height, radius * 2, radius * 2),
		CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2), color, material, canCollide)
	object.Shape = Enum.PartType.Cylinder
	return object
end

local function decorPart(stats, parent, name, size, cf, color, material, transparency)
	return makePart(stats, parent, name, size, cf, color, material, false, transparency)
end

local function decorBall(stats, parent, name, position, size, color, material)
	return makeBall(stats, parent, name, position, size, color, material, false)
end

local function label(stats, anchor, title, sub, width, height, offset, maxDistance)
	local gui = Instance.new("BillboardGui")
	stats.instances += 1
	gui.Name = "Label"
	local finalWidth = math.clamp(width or 180, 100, 200)
	local finalHeight = math.clamp(height or 45, 34, 48)
	local finalMaxDistance = math.min(maxDistance or 55, 55)
	local compact = finalWidth <= 120 or finalHeight <= 36
	gui.Size = UDim2.fromOffset(finalWidth, finalHeight)
	gui.StudsOffsetWorldSpace = offset or Vector3.new(0, 4, 0)
	gui.MaxDistance = finalMaxDistance
	gui.AlwaysOnTop = false
	gui.Parent = anchor
	local back = Instance.new("Frame")
	stats.instances += 1
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = navy
	back.BackgroundTransparency = .85
	back.BorderSizePixel = 0
	back.Parent = gui
	local corner = Instance.new("UICorner")
	stats.instances += 1
	corner.CornerRadius = UDim.new(0, compact and 8 or 10)
	corner.Parent = back
	local text = Instance.new("TextLabel")
	stats.instances += 1
	text.Name = "Title"
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromOffset(8, 4)
	text.Size = UDim2.new(1, -16, .55, 0)
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = cream
	text.TextSize = compact and 13 or 16
	text.TextStrokeColor3 = navy
	text.TextStrokeTransparency = .2
	text.Text = title
	text.Parent = back
	local detail = text:Clone()
	stats.instances += 1
	detail.Name = "Detail"
	detail.Position = UDim2.new(0, 8, .55, 0)
	detail.Size = UDim2.new(1, -16, .4, 0)
	detail.TextSize = compact and 9 or 11
	detail.TextColor3 = Color3.fromRGB(159, 226, 212)
	detail.TextStrokeColor3 = navy
	detail.TextStrokeTransparency = .3
	detail.Text = sub or ""
	detail.Parent = back
	return text, detail
end

local function palette(zone)
	local tint = colorFrom(zone.color, Color3.fromRGB(63, 174, 196))
	if zone.theme == "mystic_lake" then
		return Color3.fromRGB(58, 78, 84), Enum.Material.Slate, Color3.fromRGB(65, 151, 151), Enum.Material.Grass, Color3.fromRGB(159, 187, 179), Enum.Material.WoodPlanks, wood
	elseif zone.theme == "lava_fishing_ground" then
		return Color3.fromRGB(48, 39, 44), Enum.Material.Slate, Color3.fromRGB(78, 50, 53), Enum.Material.Slate, Color3.fromRGB(111, 68, 59), Enum.Material.Slate, Color3.fromRGB(91, 61, 55)
	elseif zone.theme == "alien_waters" then
		return Color3.fromRGB(43, 56, 70), Enum.Material.Metal, Color3.fromRGB(49, 104, 111), Enum.Material.Slate, Color3.fromRGB(91, 139, 151), Enum.Material.Metal, Color3.fromRGB(66, 99, 107)
	elseif zone.theme == "chemistry_lab" then
		return Color3.fromRGB(109, 124, 134), Enum.Material.Metal, Color3.fromRGB(151, 181, 185), Enum.Material.Metal, Color3.fromRGB(199, 216, 220), Enum.Material.Metal, Color3.fromRGB(151, 168, 177)
	end
	-- Shared zones keep a warm, muted surface language.  Do not derive the
	-- walkable ground from the ocean tint: zone 1's teal accent otherwise
	-- turns the sand into a water-like cyan plane at the spawn camera.
	local common = {
		[1] = {Color3.fromRGB(177, 153, 112), Enum.Material.Sandstone, Color3.fromRGB(211, 191, 146), Enum.Material.Sand, Color3.fromRGB(242, 225, 181)},
		[2] = {Color3.fromRGB(77, 95, 79), Enum.Material.Slate, Color3.fromRGB(106, 145, 109), Enum.Material.Grass, Color3.fromRGB(183, 179, 137)},
		[3] = {Color3.fromRGB(66, 79, 88), Enum.Material.Slate, Color3.fromRGB(95, 119, 121), Enum.Material.Slate, Color3.fromRGB(171, 163, 137)},
		[4] = {Color3.fromRGB(73, 69, 92), Enum.Material.Slate, Color3.fromRGB(112, 100, 134), Enum.Material.Slate, Color3.fromRGB(183, 167, 169)},
		[5] = {Color3.fromRGB(116, 89, 75), Enum.Material.Slate, Color3.fromRGB(180, 141, 103), Enum.Material.Sandstone, Color3.fromRGB(228, 197, 150)},
	}
	local selected = common[tonumber(zone.id) or 1] or common[1]
	return selected[1], selected[2], selected[3], selected[4], selected[5], Enum.Material.Sandstone, wood
end

local function buildSilhouette(stats, parent, zone, islandColor, islandMaterial, shoreColor, shoreMaterial)
	local recipe = SHAPES[zone.shape] or SHAPES.harbor_crescent
	local x, z = zone.x or zone.center.x, zone.z or zone.center.z
	for index, segment in ipairs(recipe) do
		local segmentX = x + segment.x * zone.width
		local segmentZ = z + segment.z * zone.depth
		local rotation = CFrame.Angles(0, segment.yaw or 0, 0)
		-- Keep overlapping authored lobes visually unified while giving their
		-- top faces a small deterministic height separation for depth precision.
		-- The final lobe is only 0.10 studs higher, below a noticeable step.
		local surfaceLift = (index - 1) * .025
		local foundation = makePart(stats, parent, "IslandLand_" .. string.format("%02d", index),
			Vector3.new(zone.width * segment.w, 5.9 + surfaceLift, zone.depth * segment.d),
			CFrame.new(segmentX, -.05 + surfaceLift * .5, segmentZ) * rotation, islandColor, islandMaterial, true)
		foundation:SetAttribute("CollisionRole", "WalkableIsland")
		foundation:SetAttribute("ZoneShape", zone.shape)
		local shore = makePart(stats, parent, "IslandShore_" .. string.format("%02d", index),
			Vector3.new(zone.width * segment.w * .985, 1.1 + surfaceLift, zone.depth * segment.d * .985),
			CFrame.new(segmentX, 3.45 + surfaceLift * .5, segmentZ) * rotation, shoreColor, shoreMaterial, true)
		shore:SetAttribute("CollisionRole", "WalkableIsland")
		shore:SetAttribute("GroundLayer", "BiomeSurface")
		shore:SetAttribute("SurfaceLift", surfaceLift)
	end
end

local function bench(stats, parent, x, z, yaw)
	local base = CFrame.new(x, 4.6, z) * CFrame.Angles(0, yaw or 0, 0)
	makePart(stats, parent, "BenchSeat", Vector3.new(7, .6, 2), base, wood, Enum.Material.WoodPlanks, true)
	makePart(stats, parent, "BenchBack", Vector3.new(7, 2, .35), base * CFrame.new(0, 1, 1), cream, Enum.Material.WoodPlanks, true)
	for _, dx in {-2.5, 2.5} do
		makePart(stats, parent, "BenchLeg", Vector3.new(.5, 1.5, 1.6), base * CFrame.new(dx, -1, 0), navy, Enum.Material.SmoothPlastic, true)
	end
end

local function palm(stats, parent, x, z, scale, tint)
	local s = scale or 1
	if ArtRenderer.clone("Palm", parent, CFrame.new(x, 3, z), 17 * s) then return end
	local trunk = makePart(stats, parent, "PalmTrunk", Vector3.new(1.6 * s, 14 * s, 1.6 * s),
		CFrame.new(x + 1 * s, 3 + 7 * s, z) * CFrame.Angles(0, 0, -.13), Color3.fromRGB(144, 101, 65), Enum.Material.Wood, false)
	local top = Vector3.new(x + 2 * s, 3 + 14 * s, z)
	for j = 1, 7 do
		local angle = j * math.pi * 2 / 7
		decorPart(stats, parent, "PalmLeaf", Vector3.new(3 * s, .45 * s, 10 * s),
			CFrame.new(top) * CFrame.Angles(0, angle, 0) * CFrame.new(0, -.5 * s, 4 * s) * CFrame.Angles(.18, 0, 0), tint or Color3.fromRGB(61, 146, 111), Enum.Material.SmoothPlastic)
	end
	for j = 1, 3 do decorBall(stats, parent, "Coconut", top + Vector3.new(j - 2, -1, j % 2), Vector3.one * 1.5 * s, Color3.fromRGB(112, 77, 54)) end
	trunk:SetAttribute("CollisionRole", "Decoration")
end

local function addCommonLandmarks(stats, parent, zone, zoneIndex, shoreColor)
	local x, z = zone.x or zone.center.x, zone.z or zone.center.z
	if zoneIndex == 1 then
		makeCylinder(stats, parent, "HarborLighthouse", Vector3.new(x - 92, 20, z - 92), 10, 32, Color3.fromRGB(229, 112, 89), Enum.Material.Brick, true)
		makeBall(stats, parent, "HarborBeacon", Vector3.new(x - 92, 39, z - 92), Vector3.one * 6, Color3.fromRGB(255, 232, 130), Enum.Material.Neon, false)
		decorPart(stats, parent, "HarborFlag", Vector3.new(13, 5, .3), CFrame.new(x - 80, 33, z - 92), Color3.fromRGB(61, 137, 190), Enum.Material.Fabric)
		palm(stats, parent, x - 145, z - 120, 1.1, shoreColor)
		palm(stats, parent, x + 150, z - 115, .9, shoreColor)
	elseif zoneIndex == 2 then
		for i, dx in ipairs({-85, -30, 25, 80}) do
			local coral = makeCylinder(stats, parent, "CoralSpire", Vector3.new(x + dx, 13 + (i % 2) * 5, z - 118 + (i % 2) * 12), 7 - i * .5, 22 + (i % 2) * 7, Color3.fromRGB(224, 111 + i * 9, 127), Enum.Material.SmoothPlastic, true)
			coral:SetAttribute("Landmark", "coral_fan")
		end
		for _, dx in {-54, 54} do
			makePart(stats, parent, "CoralArchPost", Vector3.new(6, 21, 6), CFrame.new(x + dx, 14, z - 48), Color3.fromRGB(201, 99, 126), Enum.Material.SmoothPlastic, true)
		end
		makePart(stats, parent, "CoralArchTop", Vector3.new(114, 6, 7), CFrame.new(x, 25, z - 48), Color3.fromRGB(238, 155, 139), Enum.Material.SmoothPlastic, true)
		palm(stats, parent, x - 145, z - 100, .85, shoreColor)
	elseif zoneIndex == 3 then
		makePart(stats, parent, "TrenchLookout", Vector3.new(16, 48, 16), CFrame.new(x + 92, 27, z - 118), Color3.fromRGB(38, 63, 87), Enum.Material.Slate, true)
		makePart(stats, parent, "TrenchLookoutCap", Vector3.new(27, 3, 27), CFrame.new(x + 92, 52, z - 118), Color3.fromRGB(83, 180, 208), Enum.Material.Neon, false)
		for _, dx in {-72, -38, 38, 72} do
			makePart(stats, parent, "TrenchRidge", Vector3.new(8, 18, 12), CFrame.new(x + dx, 12, z - 80), Color3.fromRGB(42, 60, 76), Enum.Material.Slate, true)
		end
	elseif zoneIndex == 4 then
		for i = 1, 7 do
			local angle = i * math.pi * 2 / 7
			local lantern = decorBall(stats, parent, "MoonLantern", Vector3.new(x + math.cos(angle) * 74, 13, z - 96 + math.sin(angle) * 47), Vector3.one * 3.2, Color3.fromRGB(188, 230, 222), Enum.Material.Neon)
			lantern:SetAttribute("Landmark", "moon_ring")
		end
		local ring = makeCylinder(stats, parent, "MoonRing", Vector3.new(x, 9, z - 105), 38, .8, Color3.fromRGB(151, 116, 194), Enum.Material.Neon, false)
		ring.CFrame = ring.CFrame * CFrame.Angles(math.rad(90), 0, 0)
	elseif zoneIndex == 5 then
		local colors = {
			Color3.fromRGB(239, 98, 129), Color3.fromRGB(244, 177, 67), Color3.fromRGB(111, 205, 126),
			Color3.fromRGB(82, 172, 230), Color3.fromRGB(158, 112, 222),
		}
		for i, dx in ipairs({-80, -40, 0, 40, 80}) do
			makePart(stats, parent, "RainbowPrism", Vector3.new(18, 10 + i * 3, 18), CFrame.new(x + dx, 5 + (i * 1.5), z - 105), colors[i], Enum.Material.Glass, false, .1)
		end
		makePart(stats, parent, "RainbowBeacon", Vector3.new(12, 42, 12), CFrame.new(x, 25, z - 105), Color3.fromRGB(252, 210, 81), Enum.Material.Neon, false)
	end
end

local function addThemeLandmark(stats, parent, zone)
	local theme = zone.theme
	if type(theme) ~= "string" then return end
	local x, z = zone.x or zone.center.x, zone.z or zone.center.z
	local set = Instance.new("Model")
	stats.instances += 1
	set.Name = "ThemeEnvironment_" .. theme
	set.Parent = parent
	local sign = decorPart(stats, set, "ThemeSign", Vector3.new(20, 4.4, .8), CFrame.new(x, 10, z - 34), navy, Enum.Material.Wood)
	label(stats, sign, zone.name or theme, "主题水域 · 沿侧路前往垂钓栈桥", 300, 68, Vector3.new(0, 3.7, 0))

	if theme == "mystic_lake" then
		local pool = makeCylinder(stats, set, "MoonPool", Vector3.new(x, 4.2, z - 58), 22, 1.2, Color3.fromRGB(67, 143, 173), Enum.Material.Glass, false)
		pool.Transparency = .2
		for i = 1, 7 do
			local angle = i * math.pi * 2 / 7
			decorBall(stats, set, "LotusPad", Vector3.new(x + math.cos(angle) * 29, 5.2, z - 58 + math.sin(angle) * 19), Vector3.new(4.6, .5, 3.2), Color3.fromRGB(104, 196, 164), Enum.Material.Grass)
		end
		for _, dx in {-43, 43} do
			decorPart(stats, set, "MoonLanternPost", Vector3.new(.8, 12, .8), CFrame.new(x + dx, 9, z - 72), Color3.fromRGB(105, 73, 91), Enum.Material.Wood)
			decorBall(stats, set, "MoonLantern", Vector3.new(x + dx, 16, z - 72), Vector3.one * 3.5, Color3.fromRGB(183, 230, 222), Enum.Material.Neon)
		end
	elseif theme == "lava_fishing_ground" then
		local crater = makeCylinder(stats, set, "VolcanicCrater", Vector3.new(x, 5, z - 108), 56, 1.2, Color3.fromRGB(55, 41, 46), Enum.Material.Slate, false)
		crater.Transparency = .08
		local magmaPool = makeCylinder(stats, set, "MagmaPool", Vector3.new(x, 5.7, z - 108), 39, .28, Color3.fromRGB(240, 69, 39), Enum.Material.Neon, false)
		magmaPool.Transparency = .12
		for i, dx in ipairs({-72, -43, 43, 72}) do
			local pillar = makeCylinder(stats, set, "BasaltPillar", Vector3.new(x + dx, 11 + (i % 2) * 3, z - 74 + (i % 2) * 5), 5 + (i % 2), 19 + (i % 2) * 8, Color3.fromRGB(67, 48, 53), Enum.Material.Slate, false)
			pillar:SetAttribute("Landmark", "lava_basalt")
			decorBall(stats, set, "MagmaCore", Vector3.new(x + dx, 22 + (i % 2) * 3, z - 74 + (i % 2) * 5), Vector3.one * 4.4, Color3.fromRGB(242, 83, 47), Enum.Material.Neon)
		end
		decorPart(stats, set, "BasaltBridge", Vector3.new(110, .8, 3.4), CFrame.new(x, 5.2, z - 52), Color3.fromRGB(83, 59, 58), Enum.Material.Slate)
	elseif theme == "alien_waters" then
		for i = 1, 5 do
			local angle = i * math.pi * 2 / 5
			local floating = decorBall(stats, set, "FloatingMonolith", Vector3.new(x + math.cos(angle) * 55, 29 + (i % 2) * 8, z - 82 + math.sin(angle) * 22), Vector3.new(10 + i, 18, 9 + i), Color3.fromRGB(71, 91, 111), Enum.Material.Slate)
			floating:SetAttribute("Landmark", "alien_floating_rock")
		end
		for i = 1, 8 do
			local angle = i * math.pi / 4
			local orb = decorBall(stats, set, "SignalOrb", Vector3.new(x + math.cos(angle) * 64, 10 + (i % 2) * 7, z - 82 + math.sin(angle) * 20), Vector3.one * (2.4 + (i % 2) * .8), Color3.fromRGB(73, 229, 212), Enum.Material.Neon)
			orb.Transparency = .08
		end
		for _, dx in {-46, 46} do
			local ring = makeCylinder(stats, set, "OrbitRing", Vector3.new(x + dx, 16, z - 76), 9, .5, Color3.fromRGB(139, 102, 237), Enum.Material.Neon, false)
			ring.CFrame = ring.CFrame * CFrame.Angles(math.rad(90), 0, math.rad(18))
		end
		decorPart(stats, set, "AlienPanel", Vector3.new(48, 8, .6), CFrame.new(x, 10, z - 111), Color3.fromRGB(39, 78, 99), Enum.Material.Metal)
	elseif theme == "chemistry_lab" then
		local hall = decorPart(stats, set, "LaboratoryHall", Vector3.new(150, 3, 76), CFrame.new(x, 5.4, z - 82), Color3.fromRGB(84, 111, 126), Enum.Material.Metal)
		hall:SetAttribute("Landmark", "laboratory_hall")
		for _, dx in {-66, 66} do
			for _, dz in {-110, -54} do
				decorPart(stats, set, "LabFrame", Vector3.new(6, 30, 6), CFrame.new(x + dx, 19, z + dz), Color3.fromRGB(182, 200, 207), Enum.Material.Metal)
			end
		end
		decorPart(stats, set, "LabRoofBeam", Vector3.new(150, 5, 7), CFrame.new(x, 34, z - 82), Color3.fromRGB(141, 163, 174), Enum.Material.Metal)
		for _, dx in {-56, -19, 19, 56} do
			local tank = decorPart(stats, set, "LabTank", Vector3.new(12, 12, 8), CFrame.new(x + dx, 10, z - 77), Color3.fromRGB(142, 205, 220), Enum.Material.Glass, .38)
			tank:SetAttribute("ThemeProp", "chemistry_lab")
			decorBall(stats, set, "ReagentBubble", Vector3.new(x + dx - 2, 14, z - 77), Vector3.one * 2.2, Color3.fromRGB(169, 126, 223), Enum.Material.Neon)
			decorBall(stats, set, "ReagentBubble", Vector3.new(x + dx + 2.2, 9, z - 77), Vector3.one * 1.4, Color3.fromRGB(96, 212, 169), Enum.Material.Neon)
		end
		local pipe = decorPart(stats, set, "LabPipe", Vector3.new(125, .9, .9), CFrame.new(x, 20, z - 106), Color3.fromRGB(183, 184, 201), Enum.Material.Metal)
		pipe:SetAttribute("ThemeProp", "chemistry_lab")
		for _, dx in {-44, 44} do
			local tank = decorPart(stats, set, "DockLabTank", Vector3.new(7, 7, 5), CFrame.new(x + dx, 8, z + 20), Color3.fromRGB(142, 205, 220), Enum.Material.Glass, .42)
			tank:SetAttribute("ThemeProp", "chemistry_lab")
			decorBall(stats, set, "DockLabBubble", Vector3.new(x + dx, 13, z + 20), Vector3.one * 1.8, Color3.fromRGB(169, 126, 223), Enum.Material.Neon)
		end
	end
end

local function newDecorationSet(stats, parent, name)
	local set = Instance.new("Model")
	stats.instances += 1
	set.Name = name
	set.Parent = parent
	return set
end

local function markDecoration(object, role)
	object:SetAttribute("CollisionRole", "Decoration")
	object:SetAttribute("SceneryRole", role)
	return object
end

local function boundsXZ(model)
	local boxCFrame, size = model:GetBoundingBox()
	local half = size * .5
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, sx in {-1, 1} do
		for _, sy in {-1, 1} do
			for _, sz in {-1, 1} do
				local point = (boxCFrame * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)).Position
				minX = math.min(minX, point.X)
				maxX = math.max(maxX, point.X)
				minZ = math.min(minZ, point.Z)
				maxZ = math.max(maxZ, point.Z)
			end
		end
	end
	return {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
end

local function overlapsXZ(bounds, minX, maxX, minZ, maxZ, clearance)
	local margin = clearance or 0
	return bounds.maxX >= minX - margin and bounds.minX <= maxX + margin
		and bounds.maxZ >= minZ - margin and bounds.minZ <= maxZ + margin
end

local function supportAt(zoneParent, x, z)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = {zoneParent}
	local result = workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -160, 0), rayParams)
	if not result or not result.Instance:IsA("BasePart") then return nil end
	if not result.Instance.CanCollide or result.Instance.Material == Enum.Material.Water then return nil end
	return result
end

local function supportedOnFourCorners(zoneParent, bounds)
	local centerX = (bounds.minX + bounds.maxX) * .5
	local centerZ = (bounds.minZ + bounds.maxZ) * .5
	local samples = {
		{centerX, centerZ},
		{bounds.minX, bounds.minZ},
		{bounds.minX, bounds.maxZ},
		{bounds.maxX, bounds.minZ},
		{bounds.maxX, bounds.maxZ},
	}
	local supportName
	for _, sample in ipairs(samples) do
		local result = supportAt(zoneParent, sample[1], sample[2])
		if not result then return nil end
		supportName = result.Instance.Name
	end
	return supportName
end

local function naturePlacementAllowed(zone, zoneParent, model, clusterX, clusterZ)
	local bounds = boundsXZ(model)
	local clearance = .25
	local zoneX, zoneZ = zone.x or zone.center.x, zone.z or zone.center.z
	local route = {minX = zoneX - 30, maxX = zoneX - 14, minZ = zoneZ + 3, maxZ = zoneZ + 15}
	local gate = {minX = zoneX - 10.5, maxX = zoneX + 10.5, minZ = zoneZ + 13, maxZ = zoneZ + 17}
	if overlapsXZ(bounds, route.minX, route.maxX, route.minZ, route.maxZ, clearance) then
		return nil, "npc-route-overlap"
	end
	if overlapsXZ(bounds, gate.minX, gate.maxX, gate.minZ, gate.maxZ, clearance) then
		return nil, "gate-reserve-overlap"
	end
	if bounds.maxZ >= zoneZ + 30 and bounds.minZ <= zoneZ + 80 then
		return nil, "dock-channel-overlap"
	end
	-- Preserve the two functional arrival markers in this cluster. The
	-- imported Bush occupies the old CoastalShrub visual position; the three
	-- low plants are placed beside it with a conservative clearance.
	if overlapsXZ(bounds, clusterX - 5.7, clusterX - .3, clusterZ - 1.1, clusterZ + 3.1, clearance) then
		return nil, "wayfinding-stone-overlap"
	end
	if overlapsXZ(bounds, clusterX + 6.6, clusterX + 7.4, clusterZ + 1.6, clusterZ + 2.4, clearance) then
		return nil, "path-marker-overlap"
	end
	local supportName = supportedOnFourCorners(zoneParent, bounds)
	if not supportName then return nil, "missing-four-point-support" end
	return supportName
end

local function addNatureNearshore(stats, parent, set, zone, clusterX, clusterZ, groundY)
	local placements = {
		{key = "Bush", x = clusterX + 3, z = clusterZ - 1, role = "author_nearshore_bush_replacing_coastal_shrub"},
		{key = "PlantFlowers", x = clusterX + 2, z = clusterZ + 4.5, role = "author_supplemental_plant"},
		{key = "FlowerClump", x = clusterX + 5, z = clusterZ + 4.5, role = "author_flower_clump"},
		{key = "GrassSmall", x = clusterX + 5, z = clusterZ + 6.5, role = "author_grass_small"},
	}
	local added = 0
	for _, placement in ipairs(placements) do
		local model = ArtRenderer.cloneNatureGrounded(
			placement.key,
			nil,
			CFrame.new(placement.x, groundY or 4, placement.z),
			nil,
			groundY or 4
		)
		if model then
			local supportName, reason = naturePlacementAllowed(zone, parent, model, clusterX, clusterZ)
			if supportName then
				model.Name = "Nature_" .. placement.key
				model:SetAttribute("CollisionRole", "Decoration")
				model:SetAttribute("SceneryRole", placement.role)
				model:SetAttribute("SupportPart", supportName)
				model.Parent = set
				stats.instances += 1 + #model:GetDescendants()
				added += 1
			else
				warn(string.format("NATURE_ART_PLACEMENT_SKIP key=%s reason=%s", placement.key, reason or "unknown"))
				model:Destroy()
			end
		else
			warn("NATURE_ART_TEMPLATE_MISSING key=" .. placement.key)
		end
	end
	set:SetAttribute("NatureArtCount", added)
	return added
end

local function addSceneryCluster(stats, parent, zone, zoneIndex, clusterIndex, position, theme, groundY)
	local set = newDecorationSet(stats, parent, "SceneryCluster_" .. string.format("%02d", clusterIndex))
	set:SetAttribute("Zone", zoneIndex)
	set:SetAttribute("Purpose", clusterIndex <= 2 and "ArrivalWayfinding" or "DeepPathLandmark")
	set:SetAttribute("Theme", theme or "coastal")
	local x, z = position.x, position.z
	local yOffset = (groundY or 4) - 4

	if theme == "mystic_lake" then
		for i, offset in ipairs({{-4, 0}, {2, -2}, {6, 2}}) do
			local stem = decorPart(stats, set, "MoonMushroomStem", Vector3.new(.8, 3.2, .8), CFrame.new(x + offset[1], 5.6 + yOffset, z + offset[2]), Color3.fromRGB(118, 92, 112), Enum.Material.Wood)
			markDecoration(stem, "mystic_mushroom")
			local cap = decorBall(stats, set, "MoonMushroomCap", Vector3.new(x + offset[1], 7.25 + yOffset, z + offset[2]), Vector3.new(3.4, 1.35, 3.4), i == 2 and Color3.fromRGB(205, 145, 226) or Color3.fromRGB(115, 202, 179), Enum.Material.Neon)
			markDecoration(cap, "mystic_mushroom")
		end
		local glow = decorBall(stats, set, "LakeGlow", Vector3.new(x + 1, 5.1 + yOffset, z + 4), Vector3.one * 1.4, Color3.fromRGB(171, 255, 204), Enum.Material.Neon)
		glow.Transparency = .12
		markDecoration(glow, "mystic_waypoint")
	elseif theme == "lava_fishing_ground" then
		for i, offset in ipairs({{-4, 1}, {1, -2}, {6, 2}}) do
			local height = 3.8 + i * .7
			local basalt = decorPart(stats, set, "BasaltCluster", Vector3.new(3.2, height, 3.2), CFrame.new(x + offset[1], 4 + height * .5 + yOffset, z + offset[2]) * CFrame.Angles(0, i * .32, (i - 2) * .08), Color3.fromRGB(57, 45, 49), Enum.Material.Slate)
			markDecoration(basalt, "lava_basalt")
			local ember = decorBall(stats, set, "ClusterEmber", Vector3.new(x + offset[1], 4.5 + height + yOffset, z + offset[2]), Vector3.one * (1.15 + i * .18), Color3.fromRGB(242, 83, 47), Enum.Material.Neon)
			markDecoration(ember, "lava_ember")
		end
	elseif theme == "alien_waters" then
		for i, offset in ipairs({{-4, 1}, {1, -2}, {6, 2}}) do
			local height = 5 + i * 1.2
			local crystal = decorPart(stats, set, "SignalCrystal", Vector3.new(2.4, height, 2.4), CFrame.new(x + offset[1], 4 + height * .5 + yOffset, z + offset[2]) * CFrame.Angles(0, i * .37, .12 * (i - 2)), Color3.fromRGB(72, 146, 161), Enum.Material.Glass, .08)
			markDecoration(crystal, "alien_crystal")
			local orb = decorBall(stats, set, "SignalMote", Vector3.new(x + offset[1], 5.4 + height + yOffset, z + offset[2]), Vector3.one * (1.1 + i * .2), i == 2 and Color3.fromRGB(157, 109, 236) or Color3.fromRGB(73, 229, 212), Enum.Material.Neon)
			markDecoration(orb, "alien_signal")
		end
	elseif theme == "chemistry_lab" then
		local rack = decorPart(stats, set, "FieldRack", Vector3.new(10, 3.2, 2.8), CFrame.new(x, 5.6 + yOffset, z), Color3.fromRGB(112, 139, 151), Enum.Material.Metal)
		markDecoration(rack, "lab_field_rack")
		for i, dx in ipairs({-3.2, 0, 3.2}) do
			local tank = decorPart(stats, set, "FieldSample", Vector3.new(2.2, 3.4, 1.8), CFrame.new(x + dx, 7.2 + yOffset, z), Color3.fromRGB(142, 205, 220), Enum.Material.Glass, .34)
			markDecoration(tank, "lab_sample")
			local bubble = decorBall(stats, set, "SampleBubble", Vector3.new(x + dx + (i - 2) * .25, 8.6 + yOffset, z - .95), Vector3.one * .65, i == 2 and Color3.fromRGB(169, 126, 223) or Color3.fromRGB(96, 212, 169), Enum.Material.Neon)
			markDecoration(bubble, "lab_sample")
		end
	else
		local stone = decorBall(stats, set, "WayfindingStone", Vector3.new(x - 3, 4.8 + yOffset, z + 1), Vector3.new(5.4, 2.2, 4.2), Color3.fromRGB(101, 119, 112), Enum.Material.Slate)
		markDecoration(stone, "coastal_stone")
		if zoneIndex == 1 and clusterIndex == 2 then
			addNatureNearshore(stats, parent, set, zone, x, z, groundY or 4)
		else
			local shrub = decorBall(stats, set, "CoastalShrub", Vector3.new(x + 3, 5.1 + yOffset, z - 1), Vector3.new(5.8, 2.7, 4.6), Color3.fromRGB(73, 155, 113), Enum.Material.Grass)
			markDecoration(shrub, "coastal_shrub")
		end
		local marker = decorPart(stats, set, "PathMarker", Vector3.new(.8, 3.2, .8), CFrame.new(x + 7, 5.6 + yOffset, z + 2), Color3.fromRGB(180, 125, 80), Enum.Material.Wood)
		markDecoration(marker, "coastal_waypoint")
	end
	return set
end

local function addNpc(stats, parent, zone, zoneIndex, role, position, yaw, outfitColor, accentColor, title, detail, groundY)
	local model = newDecorationSet(stats, parent, "NPC_" .. role .. "_" .. tostring(zoneIndex))
	model:SetAttribute("Zone", zoneIndex)
	model:SetAttribute("Role", role)
	model:SetAttribute("Simulation", "StaticPresentation")
	model:SetAttribute("CollisionRole", "Decoration")
	groundY = groundY or 4
	local pivot = CFrame.new(position.x, groundY, position.z) * CFrame.Angles(0, yaw or math.pi, 0)

	local base = decorBall(stats, model, "NPCBase", Vector3.new(position.x, groundY + .12, position.z), Vector3.new(3.8, .24, 3.8), accentColor, Enum.Material.SmoothPlastic)
	markDecoration(base, "npc_base")
	local torso = decorPart(stats, model, "Torso", Vector3.new(2.8, 2.2, 1.8), pivot * CFrame.new(0, 3.1, 0), outfitColor, Enum.Material.SmoothPlastic)
	markDecoration(torso, "npc_body")
	model.PrimaryPart = torso
	for _, side in ipairs({-1, 1}) do
		local leg = decorPart(stats, model, "Leg", Vector3.new(.82, 2.2, .9), pivot * CFrame.new(side * .72, 1.1, 0), navy, Enum.Material.SmoothPlastic)
		markDecoration(leg, "npc_body")
		local arm = decorPart(stats, model, "Arm", Vector3.new(.72, 2.65, .72), pivot * CFrame.new(side * 1.75, 3.1, 0) * CFrame.Angles(0, 0, side * -.12), outfitColor:Lerp(accentColor, .18), Enum.Material.SmoothPlastic)
		markDecoration(arm, "npc_body")
	end
	local head = decorBall(stats, model, "Head", (pivot * CFrame.new(0, 5.4, 0)).Position, Vector3.new(2.65, 2.65, 2.65), Color3.fromRGB(247, 198, 157), Enum.Material.SmoothPlastic)
	markDecoration(head, "npc_face")
	local hat = decorPart(stats, model, "Hat", Vector3.new(3.35, .55, 2.65), pivot * CFrame.new(0, 6.9, 0), accentColor, Enum.Material.SmoothPlastic)
	markDecoration(hat, "npc_outfit")
	for _, side in ipairs({-1, 1}) do
		local eye = decorBall(stats, model, "Eye", (pivot * CFrame.new(side * .48, 5.57, -1.18)).Position, Vector3.new(.28, .28, .18), navy, Enum.Material.SmoothPlastic)
		markDecoration(eye, "npc_face")
	end
	local smile = decorPart(stats, model, "Smile", Vector3.new(.65, .12, .12), pivot * CFrame.new(0, 5.05, -1.2), Color3.fromRGB(133, 73, 75), Enum.Material.SmoothPlastic)
	markDecoration(smile, "npc_face")

	if role == "Greeter" then
		local pennant = decorPart(stats, model, "WelcomePennant", Vector3.new(.25, 4.5, .25), pivot * CFrame.new(-2.1, 2.8, 0), wood, Enum.Material.Wood)
		markDecoration(pennant, "npc_greeter")
		local flag = decorPart(stats, model, "WelcomeFlag", Vector3.new(2.5, 1.4, .18), pivot * CFrame.new(-1.1, 4.1, 0), accentColor, Enum.Material.Fabric)
		markDecoration(flag, "npc_greeter")
	elseif role == "Researcher" then
		local clipboard = decorPart(stats, model, "Clipboard", Vector3.new(1.1, 1.45, .18), pivot * CFrame.new(-1.55, 2.1, -1.05), cream, Enum.Material.SmoothPlastic)
		markDecoration(clipboard, "npc_researcher")
		local lens = decorBall(stats, model, "ResearchLens", (pivot * CFrame.new(.86, 5.57, -1.15)).Position, Vector3.new(.52, .52, .18), accentColor, Enum.Material.Neon)
		markDecoration(lens, "npc_researcher")
	else
		local rod = decorPart(stats, model, "FishingRod", Vector3.new(.22, 5.5, .22), pivot * CFrame.new(1.45, 3.0, -.3) * CFrame.Angles(0, 0, math.rad(-18)), wood, Enum.Material.Wood)
		markDecoration(rod, "npc_angler")
		local bobber = decorBall(stats, model, "Bobber", (pivot * CFrame.new(2.25, 5.1, -.45)).Position, Vector3.one * .8, Color3.fromRGB(255, 116, 84), Enum.Material.Neon)
		markDecoration(bobber, "npc_angler")
	end
	label(stats, head, title, detail, 100, 34, Vector3.new(0, 2.3, 0), 30)
	return model
end

local function addIslandDressing(stats, parent, zone, zoneIndex, shoreColor)
	local x, z = zone.x or zone.center.x, zone.z or zone.center.z
	local recipe = SHAPES[zone.shape] or SHAPES.harbor_crescent
	local theme = zone.theme
	-- Two small arrival groups sit beside the court; they frame the route while
	-- leaving the central spawn, gate and dock line open.
	addSceneryCluster(stats, parent, zone, zoneIndex, 1, {x = x - 24, z = z + 7}, theme, 4)
	addSceneryCluster(stats, parent, zone, zoneIndex, 2, {x = x + 24, z = z + 7}, theme, 4)

	local deepSegment = recipe[#recipe]
	local sideSegment = recipe[math.max(1, #recipe - 1)]
	local deepX = x + deepSegment.x * zone.width
	local deepZ = z + deepSegment.z * zone.depth
	local sideX = x + sideSegment.x * zone.width
	local sideZ = z + sideSegment.z * zone.depth
	local deepGroundY = 4 + math.max(0, #recipe - 1) * .025
	local sideGroundY = 4 + math.max(0, #recipe - 2) * .025
	local contextRole, contextTitle, contextDetail
	if theme == "mystic_lake" then
		contextRole, contextTitle, contextDetail = "Researcher", "湖光研究员", "同种同级三鱼可合成"
	elseif theme == "alien_waters" then
		contextRole, contextTitle, contextDetail = "Researcher", "星潮研究员", "到栈桥尽头抛竿"
	elseif theme == "chemistry_lab" then
		contextRole, contextTitle, contextDetail = "Researcher", "水样研究员", "同种同级三鱼可合成"
	elseif theme == "lava_fishing_ground" then
		contextRole, contextTitle, contextDetail = "Angler", "熔岩垂钓员", "到栈桥尽头抛竿"
	else
		contextRole, contextTitle, contextDetail = "Angler", "深水垂钓员", "到栈桥尽头抛竿"
	end
	addSceneryCluster(stats, parent, zone, zoneIndex, 3, {x = deepX, z = deepZ}, theme, deepGroundY)
	addSceneryCluster(stats, parent, zone, zoneIndex, 4, {x = sideX, z = sideZ}, theme, sideGroundY)

	addNpc(stats, parent, zone, zoneIndex, "Greeter", {x = x - 17, z = z + 7}, math.pi, shoreColor:Lerp(cream, .34), shoreColor:Lerp(navy, .25), "迎宾员", "沿路看地标")
	addNpc(stats, parent, zone, zoneIndex, contextRole, {x = deepX, z = deepZ + 7}, 0, shoreColor:Lerp(navy, .26), shoreColor:Lerp(cream, .18), contextTitle, contextDetail, deepGroundY)
end

function IslandBuilder.build(parent, zone, zoneIndex)
	local stats = { instances = 0 }
	local x, z = zone.x or zone.center.x, zone.z or zone.center.z
	local islandColor, islandMaterial, shoreColor, shoreMaterial, promenadeColor, promenadeMaterial, dockColor = palette(zone)
	parent:SetAttribute("ZoneShape", zone.shape)
	parent:SetAttribute("ZoneWidth", zone.width)
	parent:SetAttribute("ZoneDepth", zone.depth)
	parent:SetAttribute("LandCollision", true)

	buildSilhouette(stats, parent, zone, islandColor, islandMaterial, shoreColor, shoreMaterial)

	-- The promenade and dock are kept at the original numeric contract. The
	-- land silhouette ends before the pier's centerline so the +Z boat channel
	-- cannot be sealed by a larger island footprint.
	-- A broad arrival court is the walkable neck between the north-biased
	-- silhouette and the old harbor spawn/promenade. It ends before the dock's
	-- over-water section, leaving the +Z boat channel open.
	local arrivalFoundation = makePart(stats, parent, "ArrivalFoundation", Vector3.new(66, 5.9, 25), CFrame.new(x, -.05, z + 14.5), islandColor, islandMaterial, true)
	arrivalFoundation:SetAttribute("CollisionRole", "WalkableIsland")
	local arrivalCourt = makePart(stats, parent, "ArrivalCourt", Vector3.new(66, 1.1, 25), CFrame.new(x, 3.45, z + 14.5), shoreColor, shoreMaterial, true)
	arrivalCourt:SetAttribute("CollisionRole", "WalkableIsland")
	arrivalCourt:SetAttribute("GroundLayer", "BiomeSurface")
	-- Some silhouettes deliberately pull their center lobe farther north to
	-- create a hook or ring. A straight, narrow neck closes that gap all the
	-- way into the authored land while retaining the wider irregular shoreline
	-- on either side.
	local neckStart = z - zone.depth * .42
	local neckEnd = z + 2
	local neckLength = neckEnd - neckStart
	local neckCenter = (neckStart + neckEnd) * .5
	local neckFoundation = makePart(stats, parent, "ArrivalNeckFoundation", Vector3.new(66, 5.9, neckLength), CFrame.new(x, -.05, neckCenter), islandColor, islandMaterial, true)
	neckFoundation:SetAttribute("CollisionRole", "WalkableIsland")
	local neck = makePart(stats, parent, "ArrivalNeck", Vector3.new(66, 1.1, neckLength), CFrame.new(x, 3.462, neckCenter), shoreColor, shoreMaterial, true)
	neck:SetAttribute("CollisionRole", "WalkableIsland")
	neck:SetAttribute("GroundLayer", "BiomeSurface")
	-- The inset promenade stops at the first physical dock plank.  It sits a
	-- fraction above the court so its path material reads clearly without a
	-- coplanar texture seam.
	local promenade = makePart(stats, parent, "Promenade", Vector3.new(66, .12, 10.4), CFrame.new(x, 4.06, z + 22.45), promenadeColor, promenadeMaterial, true)
	promenade:SetAttribute("GroundLayer", "PathInset")
	for j = 0, 10 do
		makePart(stats, parent, "DockPlank", Vector3.new(16, .8, 4.7), CFrame.new(x, 3.6, z + 30 + j * 4.8), dockColor, Enum.Material.WoodPlanks, true)
	end
	local marker = makePart(stats, parent, "FishingMarker", Vector3.new(10, .16, 1.2), CFrame.new(x, 4.12, z + 75.5), Color3.fromRGB(89, 224, 207), Enum.Material.Neon, false)
	marker:SetAttribute("Zone", zoneIndex)
	marker:SetAttribute("SurfaceY", FishingLocation.Pier.surfaceY)
	marker:SetAttribute("TravelZOffset", FishingLocation.Travel.zOffset)
	marker:SetAttribute("CastZOffset", FishingLocation.Cast.zOffset)
	label(stats, marker, "垂钓点", "站在栈桥尽头，面向海水", 210, 54, Vector3.new(0, 2.5, 0))

	ArtRenderer.clone("FishingBucket", parent, CFrame.new(x + 6.2, 4.9, z + 72), 1.8)
	ArtRenderer.cloneGrounded("RodRack", parent, CFrame.new(x + 5.5, 4, z + 45), 4, 4)
	ArtRenderer.cloneGrounded("LureDisplayBoard", parent, CFrame.new(x - 22, 4.9, z + 19.8), 2.2, 4.9)
	local landing = ArtRenderer.clone("Dock", parent, CFrame.new(x + 17, 3.9, z + 61), 18)
	if landing then
		landing:PivotTo(landing:GetPivot() * CFrame.new(0, -landing:GetExtentsSize().Y, 0))
	end
	makePart(stats, parent, "DockCollision", Vector3.new(18, .6, 18), CFrame.new(x + 17, 3.5, z + 61), dockColor, Enum.Material.WoodPlanks, true, 1)
	ArtRenderer.clone("Boat", parent, CFrame.new(x + 22, -.3, z + 78) * CFrame.Angles(0, .25, 0), 14)

	for j = 0, 5 do
		for _, dx in {-9, 9} do
			makePart(stats, parent, "DockPost", Vector3.new(1.2, 8, 1.2), CFrame.new(x + dx, 1, z + 30 + j * 9.5), navy, Enum.Material.Wood, true)
			local cap = makeBall(stats, parent, "Lamp", Vector3.new(x + dx, 5.3, z + 30 + j * 9.5), Vector3.one * 1.5, cream, Enum.Material.Neon, false)
			cap.Material = Enum.Material.Neon
		end
	end
	local board = makePart(stats, parent, "WelcomeBoard", Vector3.new(13, 5, 1), CFrame.new(x, 9, z + 15), navy, Enum.Material.Wood, true)
	label(stats, board, zone.name or ("水域 " .. tostring(zoneIndex)), "沿木栈桥垂钓 · 每轮20秒", 200, 48, Vector3.new(0, 3, 0), 55)
	for _, dx in {-8, 8} do makePart(stats, parent, "GatePost", Vector3.new(1, 11, 1), CFrame.new(x + dx, 8, z + 15), wood, Enum.Material.Wood, true) end
	makePart(stats, parent, "GateRoof", Vector3.new(21, 1.2, 4), CFrame.new(x, 14, z + 15), shoreColor:Lerp(navy, .35), Enum.Material.Wood, true)

	-- Rocks form an uneven shoreline but deliberately skip the south-facing
	-- centerline so the dock and approach remain visible and navigable.
	for j = 1, 10 do
		local angle = j * 2.399
		local localX = math.cos(angle) * zone.width * .40
		local localZ = -zone.depth * .47 + math.sin(angle) * zone.depth * .35
		local rock = makeBall(stats, parent, "ShoreRock", Vector3.new(x + localX, 3, z + localZ), Vector3.new(5 + j % 3, 3 + j % 2, 5), shoreColor:Lerp(navy, .42), Enum.Material.Slate, true)
		rock:SetAttribute("CollisionRole", "ShoreEdge")
	end
	bench(stats, parent, x - 22, z + 20, 0)
	bench(stats, parent, x + 22, z + 20, 0)
	addThemeLandmark(stats, parent, zone)
	if not zone.theme then addCommonLandmarks(stats, parent, zone, zoneIndex, shoreColor) end
	addIslandDressing(stats, parent, zone, zoneIndex, shoreColor)

	if zoneIndex > 1 then
		local gate = makePart(stats, parent, "Portal", Vector3.new(8, .3, 8), CFrame.new(x, 4.1, z - 5), shoreColor:Lerp(cream, .4), Enum.Material.Neon, false)
		label(stats, gate, "水域 " .. tostring(zoneIndex), "乘船前往下一座岛", 220, 58, Vector3.new(0, 4, 0))
	end

	parent:SetAttribute("BuilderPartCount", stats.instances)
	return stats
end

return IslandBuilder
