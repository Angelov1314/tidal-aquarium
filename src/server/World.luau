-- Procedural layout with licensed, replaceable fish and prop templates.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("FishingShared"):WaitForChild("Config"))
local ArtRenderer = require(ReplicatedStorage.FishingShared:WaitForChild("ArtRenderer"))
local FishingLocation = require(ReplicatedStorage.FishingShared:WaitForChild("FishingLocation"))
local WorldLayout = require(ReplicatedStorage.FishingShared:WaitForChild("WorldLayout"))
local IslandBuilder = require(script.Parent:WaitForChild("IslandBuilder"))
local Showcase = require(script.Parent:WaitForChild("Showcase"))
local World = {}
local root
local plots = {}
local owned = {}
local signatures = {}
local sand = Color3.fromRGB(241, 216, 163)
local wood = Color3.fromRGB(180, 125, 80)
local navy = Color3.fromRGB(28, 58, 71)
local cream = Color3.fromRGB(255, 246, 222)

local function part(parent, name, size, cf, color, material, transparency)
    local p = Instance.new("Part")
    p.Name = name
    p.Size = size
    p.CFrame = cf
    p.Color = color
    p.Material = material or Enum.Material.SmoothPlastic
    p.Anchored = true
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    p.Transparency = transparency or 0
    p.Parent = parent
    return p
end

local function ball(parent, name, pos, size, color)
    local p = part(parent, name, size, CFrame.new(pos), color)
    p.Shape = Enum.PartType.Ball
    p.CanCollide = false
    return p
end

local function cylinder(parent, name, pos, radius, height, color, material)
    local p = part(parent, name, Vector3.new(height, radius * 2, radius * 2), CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2), color, material)
    p.Shape = Enum.PartType.Cylinder
    return p
end

local function label(anchor, title, sub, width, height, offset)
    local gui = Instance.new("BillboardGui")
    gui.Name = "Label"
    gui.Size = UDim2.fromOffset(width or 270, height or 70)
    gui.StudsOffsetWorldSpace = offset or Vector3.new(0, 4, 0)
    gui.MaxDistance = 110
    gui.AlwaysOnTop = false
    gui.Parent = anchor
    local back = Instance.new("Frame")
    back.Size = UDim2.fromScale(1, 1)
    back.BackgroundColor3 = navy
    back.BackgroundTransparency = .08
    back.BorderSizePixel = 0
    back.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = back
    local text = Instance.new("TextLabel")
    text.Name = "Title"
    text.BackgroundTransparency = 1
    text.Position = UDim2.fromOffset(8, 4)
    text.Size = UDim2.new(1, -16, .55, 0)
    text.Font = Enum.Font.GothamBold
    text.TextColor3 = cream
    text.TextSize = 18
    text.Text = title
    text.Parent = back
    local desc = text:Clone()
    desc.Name = "Detail"
    desc.Position = UDim2.new(0, 8, .55, 0)
    desc.Size = UDim2.new(1, -16, .4, 0)
    desc.TextSize = 12
    desc.TextColor3 = Color3.fromRGB(159, 226, 212)
    desc.Text = sub or ""
    desc.Parent = back
    return text, desc
end

local function palm(parent, x, z, scale, tint)
    local s = scale or 1
    if ArtRenderer.clone("Palm", parent, CFrame.new(x, 3, z), 17*s) then return end
    local base = Vector3.new(x, 3, z)
    local trunk = part(parent, "PalmTrunk", Vector3.new(1.6*s, 14*s, 1.6*s), CFrame.new(base + Vector3.new(1*s, 7*s, 0)) * CFrame.Angles(0,0,-.13), Color3.fromRGB(144, 101, 65), Enum.Material.Wood)
    trunk.CanCollide = false
    local top = base + Vector3.new(2*s, 14*s, 0)
    for j=1,7 do
        local angle = j * math.pi * 2 / 7
        local cf = CFrame.new(top) * CFrame.Angles(0,angle,0) * CFrame.new(0,-.5*s,4*s) * CFrame.Angles(.18,0,0)
        local leaf = part(parent,"PalmLeaf",Vector3.new(3*s,.45*s,10*s),cf,tint or Color3.fromRGB(61,146,111),Enum.Material.SmoothPlastic)
        leaf.CanCollide = false
    end
    for j=1,3 do ball(parent,"Coconut",top+Vector3.new(j-2,-1,j%2),Vector3.one*1.5*s,Color3.fromRGB(112,77,54)) end
end

local function bench(parent, x, z, yaw)
    local base = CFrame.new(x,4.6,z)*CFrame.Angles(0,yaw or 0,0)
    part(parent,"BenchSeat",Vector3.new(7,.6,2),base,wood,Enum.Material.WoodPlanks)
    part(parent,"BenchBack",Vector3.new(7,2,.35),base*CFrame.new(0,1,1),cream,Enum.Material.WoodPlanks)
    for _,dx in {-2.5,2.5} do part(parent,"BenchLeg",Vector3.new(.5,1.5,1.6),base*CFrame.new(dx,-1,0),navy) end
end

local function decorPart(parent, name, size, cf, color, material, transparency)
    local object = part(parent, name, size, cf, color, material, transparency)
    object.CanCollide = false
    object.CanTouch = false
    object.CanQuery = false
    return object
end

local function decorBall(parent, name, position, size, color, material)
    local object = ball(parent, name, position, size, color)
    object.Material = material or Enum.Material.SmoothPlastic
    object.CanTouch = false
    object.CanQuery = false
    return object
end

local function themedEnvironment(parent, zoneIndex, zone)
    local theme = zone.theme
    if type(theme) ~= "string" then return end
    local x, z = zone.center.x, zone.center.z
    local set = Instance.new("Model")
    set.Name = "ThemeEnvironment_" .. theme
    set.Parent = parent
    local sign = decorPart(set, "ThemeSign", Vector3.new(20, 4.4, .8), CFrame.new(x, 9, z - 27), navy, Enum.Material.Wood)
    label(sign, zone.name, "主题水域 · 沿侧路前往垂钓栈桥", 300, 68, Vector3.new(0, 3.7, 0))

    if theme == "mystic_lake" then
        local pool = cylinder(set, "MoonPool", Vector3.new(x, 3.3, z - 12), 13, 1.2, Color3.fromRGB(67, 143, 173), Enum.Material.Glass)
        pool.CanCollide, pool.CanTouch, pool.CanQuery = false, false, false
        for i = 1, 5 do
            local angle = i * math.pi * 2 / 5
            decorBall(set, "LotusPad", Vector3.new(x + math.cos(angle) * 15, 4.3, z - 12 + math.sin(angle) * 12), Vector3.new(3.8, .45, 2.8), Color3.fromRGB(104, 196, 164), Enum.Material.Grass)
        end
        for _, dx in {-26, 26} do
            decorPart(set, "MoonLanternPost", Vector3.new(.8, 8, .8), CFrame.new(x + dx, 7, z - 23), Color3.fromRGB(105, 73, 91), Enum.Material.Wood)
            decorBall(set, "MoonLantern", Vector3.new(x + dx, 11.5, z - 23), Vector3.one * 2.4, Color3.fromRGB(183, 230, 222), Enum.Material.Neon)
            decorPart(set, "DockLanternPost", Vector3.new(.55, 6, .55), CFrame.new(x + (dx > 0 and 24 or -24), 7, z + 68), Color3.fromRGB(105, 73, 91), Enum.Material.Wood)
            decorBall(set, "DockLantern", Vector3.new(x + (dx > 0 and 24 or -24), 10, z + 68), Vector3.one * 1.7, Color3.fromRGB(183, 230, 222), Enum.Material.Neon)
        end
    elseif theme == "lava_fishing_ground" then
        for _, dx in {-31, -21, 21, 31} do
            local pillar = cylinder(set, "BasaltPillar", Vector3.new(x + dx, 7, z - 20 + (math.abs(dx) % 3)), 2.3, 9, Color3.fromRGB(67, 48, 53), Enum.Material.Slate)
            pillar.CanCollide, pillar.CanTouch, pillar.CanQuery = false, false, false
            decorBall(set, "MagmaCore", Vector3.new(x + dx, 11.5, z - 20 + (math.abs(dx) % 3)), Vector3.one * 2.2, Color3.fromRGB(242, 83, 47), Enum.Material.Neon)
        end
        decorPart(set, "BasaltBridge", Vector3.new(42, .55, 2.2), CFrame.new(x, 4.2, z - 15), Color3.fromRGB(83, 59, 58), Enum.Material.Slate)
        for _, dx in {-26, 26} do
            local vent = decorPart(set, "DockMagmaVent", Vector3.new(4, 1.1, 4), CFrame.new(x + dx, 4.7, z + 68), Color3.fromRGB(72, 48, 50), Enum.Material.Slate)
            vent.Shape = Enum.PartType.Cylinder
            vent.CFrame = vent.CFrame * CFrame.Angles(0, 0, math.rad(90))
            decorBall(set, "DockMagmaGlow", Vector3.new(x + dx, 5.5, z + 68), Vector3.one * 1.3, Color3.fromRGB(242, 83, 47), Enum.Material.Neon)
        end
    elseif theme == "alien_waters" then
        for i = 1, 6 do
            local angle = i * math.pi / 3
            local orb = decorBall(set, "SignalOrb", Vector3.new(x + math.cos(angle) * 29, 7 + (i % 2) * 3, z - 20 + math.sin(angle) * 8), Vector3.one * (1.8 + (i % 2) * .7), Color3.fromRGB(73, 229, 212), Enum.Material.Neon)
            orb.Transparency = .08
        end
        for _, dx in {-23, 23} do
            local ring = cylinder(set, "OrbitRing", Vector3.new(x + dx, 9, z - 24), 5.5, .35, Color3.fromRGB(139, 102, 237), Enum.Material.Neon)
            ring.CFrame = ring.CFrame * CFrame.Angles(math.rad(90), 0, math.rad(18))
            ring.CanCollide, ring.CanTouch, ring.CanQuery = false, false, false
        end
        decorPart(set, "AlienPanel", Vector3.new(24, 5, .45), CFrame.new(x, 7, z - 31), Color3.fromRGB(39, 78, 99), Enum.Material.Metal)
        for _, dx in {-27, 27} do
            decorPart(set, "DockSignalPylon", Vector3.new(1.2, 8, 1.2), CFrame.new(x + dx, 7, z + 70), Color3.fromRGB(53, 92, 105), Enum.Material.Metal)
            decorBall(set, "DockSignalOrb", Vector3.new(x + dx, 11.5, z + 70), Vector3.one * 2, Color3.fromRGB(73, 229, 212), Enum.Material.Neon)
        end
    elseif theme == "chemistry_lab" then
        for _, dx in {-24, -8, 8, 24} do
            local tank = decorPart(set, "LabTank", Vector3.new(7, 7, 5), CFrame.new(x + dx, 7, z - 21), Color3.fromRGB(142, 205, 220), Enum.Material.Glass, .38)
            tank:SetAttribute("ThemeProp", "chemistry_lab")
            decorBall(set, "ReagentBubble", Vector3.new(x + dx - 1, 9, z - 21), Vector3.one * 1.2, Color3.fromRGB(169, 126, 223), Enum.Material.Neon)
            decorBall(set, "ReagentBubble", Vector3.new(x + dx + 1.2, 6.5, z - 21), Vector3.one * .8, Color3.fromRGB(96, 212, 169), Enum.Material.Neon)
        end
        local pipe = decorPart(set, "LabPipe", Vector3.new(55, .5, .5), CFrame.new(x, 12, z - 28), Color3.fromRGB(183, 184, 201), Enum.Material.Metal)
        pipe:SetAttribute("ThemeProp", "chemistry_lab")
        for _, dx in {-25, 25} do
            local tank = decorPart(set, "DockLabTank", Vector3.new(5, 5, 3.5), CFrame.new(x + dx, 6.5, z + 69), Color3.fromRGB(142, 205, 220), Enum.Material.Glass, .42)
            tank:SetAttribute("ThemeProp", "chemistry_lab")
            decorBall(set, "DockLabBubble", Vector3.new(x + dx, 9.5, z + 69), Vector3.one * 1.4, Color3.fromRGB(169, 126, 223), Enum.Material.Neon)
        end
    end
end

local function fishModel(parent, species, fish, position, sizeScale)
    local sizeEntry = Config.Sizes[fish.size]
    local artScale = math.clamp((sizeScale or 1) * (sizeEntry and sizeEntry.multiplier or 1)^.33 * (1+(fish.level-1)*.045),.55,1.8)
    local imported = ArtRenderer.fish(parent, species, fish, position, artScale)
    if imported then return imported end
    local model = Instance.new("Model")
    model.Name = "Fish_" .. fish.id
    local color = Color3.fromRGB((species.color or Config.Rarities[species.rarity].color).r, (species.color or Config.Rarities[species.rarity].color).g, (species.color or Config.Rarities[species.rarity].color).b)
    if fish.mutation == 3 then color = Color3.fromRGB(255,203,74) end
    if fish.mutation == 4 then color = Color3.fromRGB(199,142,255) end
    local sizeEntry = Config.Sizes[fish.size]
    local s = math.clamp((sizeScale or 1) * (sizeEntry and sizeEntry.multiplier or 1)^.33 * (1+(fish.level-1)*.045),.55,1.8)
    local shapes={Vector3.new(3.3,1.65,1.35),Vector3.new(2.7,2.15,1.3),Vector3.new(4.3,1.1,1.1),Vector3.new(3.2,.85,2.4)}
    local body = ball(model,"Body",Vector3.zero,shapes[species.shape or 1]*s,color)
    local belly = ball(model,"Belly",Vector3.new(.3,-.34,0)*s,Vector3.new(2.4,.95,1.23)*s,cream)
    belly.Transparency = .08
    for _,sign in {-1,1} do
        local tail = part(model,"Tail",Vector3.new(1.35,1.15,.24)*s,CFrame.new(Vector3.new(-1.95,sign*.42,0)*s)*CFrame.Angles(0,0,sign*-.6),color)
        tail.CanCollide = false
        ball(model,"Eye",Vector3.new(1,.28,sign*.59)*s,Vector3.new(.48,.48,.2)*s,Color3.new(1,1,1))
        ball(model,"Pupil",Vector3.new(1.1,.29,sign*.69)*s,Vector3.new(.22,.24,.1)*s,navy)
        local fin = part(model,"Fin",Vector3.new(.9,.15,.65)*s,CFrame.new(Vector3.new(-.15,-.27,sign*.83)*s)*CFrame.Angles(0,sign*.35,0),color:Lerp(cream,.25))
        fin.CanCollide=false
    end
    local dorsal = part(model,"Dorsal",Vector3.new(1.3,.6,.22)*s,CFrame.new(Vector3.new(-.2,1,0)*s)*CFrame.Angles(0,0,-.2),color)
    dorsal.CanCollide=false
    if species.rarity>=5 or fish.mutation>=2 then
        body.Material=Enum.Material.Neon
        body.Color=color:Lerp(cream,.2)
    end
    model.PrimaryPart=body
    model.Parent=parent
    model:PivotTo(CFrame.new(position))
    model:SetAttribute("SwimCenter",position)
    model:SetAttribute("SwimSeed",tonumber(string.sub(fish.id,2)) or #fish.id * .7)
    return model
end

function World.build()
    if root and root.Parent then return end
    root = Instance.new("Folder")
    root.Name = "FishingWorld"
    root:SetAttribute("Ready", false)
    root.Parent = workspace
    local terrain=workspace.Terrain
    terrain.WaterColor=Color3.fromRGB(39,162,175)
    terrain.WaterTransparency=.35
    terrain.WaterReflectance=.35
    terrain.WaterWaveSize=.12
    terrain.WaterWaveSpeed=7
    local ocean = WorldLayout.Ocean
    -- Fill bounded X strips instead of one giant terrain region. Each strip
    -- is at most 640 x 4150 x 18 studs (~747k four-stud voxels), while the
    -- combined ocean covers every island, dock and boat route.
    local stripWidth = 640
    local cursorX = ocean.minX
    local stripCount = 0
    while cursorX < ocean.maxX do
        local width = math.min(stripWidth, ocean.maxX - cursorX)
        local centerX = cursorX + width * .5
        terrain:FillBlock(CFrame.new(centerX, ocean.surfaceY - 9, (ocean.minZ + ocean.maxZ) * .5),
            Vector3.new(width, 18, ocean.maxZ - ocean.minZ), Enum.Material.Water)
        cursorX += width
        stripCount += 1
    end
    -- BasePart axes cap at 2048 studs in current Roblox, so tile the sand
    -- floor as 960-stud pieces. The repeated OceanFloor name keeps existing
    -- downward-ray fixtures compatible while avoiding an oversized part.
    local floorTileSize = 960
    local floorTileCount = 0
    local floorX = ocean.minX
    while floorX < ocean.maxX do
        local tileWidth = math.min(floorTileSize, ocean.maxX - floorX)
        local floorZ = ocean.minZ
        while floorZ < ocean.maxZ do
            local tileDepth = math.min(floorTileSize, ocean.maxZ - floorZ)
            local floor = part(root, "OceanFloor", Vector3.new(tileWidth, 2, tileDepth),
                CFrame.new(floorX + tileWidth * .5, ocean.surfaceY - 18, floorZ + tileDepth * .5), sand, Enum.Material.Sand)
            floor:SetAttribute("OceanMinX", floorX)
            floor:SetAttribute("OceanMaxX", floorX + tileWidth)
            floor:SetAttribute("OceanMinZ", floorZ)
            floor:SetAttribute("OceanMaxZ", floorZ + tileDepth)
            floor:SetAttribute("WaterSurfaceY", ocean.surfaceY)
            floorTileCount += 1
            floorZ += tileDepth
        end
        floorX += tileWidth
    end
    local zonePartCount = 0
    for zoneIndex,zone in ipairs(Config.Zones) do
        local folder=Instance.new("Model")
        folder.Name="Zone"..zoneIndex
        folder.Parent=root
        local geometry = WorldLayout.Zones[zoneIndex]
        zone.x, zone.z = geometry.x, geometry.z
        zone.shape, zone.width, zone.depth = geometry.shape, geometry.width, geometry.depth
        local built = IslandBuilder.build(folder, zone, zoneIndex)
        local baseParts = 0
        for _, object in folder:GetDescendants() do
            if object:IsA("BasePart") then baseParts += 1 end
        end
        zonePartCount += baseParts
        folder:SetAttribute("BasePartCount", baseParts)
        folder:SetAttribute("BuilderInstanceCount", built.instances)
    end
    -- Main harbor boutique and aquarium plaza.
    part(root,"Plaza",Vector3.new(115,4,220),CFrame.new(-127,1,0),cream,Enum.Material.Sandstone)
    part(root,"PlazaBridge",Vector3.new(55,1,16),CFrame.new(-64,3.1,0),wood,Enum.Material.WoodPlanks)
    part(root,"PlazaPath",Vector3.new(12,.15,206),CFrame.new(-135,3.1,0),Color3.fromRGB(209,220,204),Enum.Material.Cobblestone)
    local welcome=part(root,"AquariumSign",Vector3.new(22,5,1),CFrame.new(-132,9,-106),navy)
    label(welcome,"潮汐水族馆","把每一次相遇，养成一片海",310,74,Vector3.new(0,4,0))
    for i=1,8 do
        local col=(i-1)%2
        local row=math.floor((i-1)/2)
        local x,z=-101-col*60,-76+row*49
        local model=Instance.new("Model")
        model.Name="Aquarium"..i
        model.Parent=root
        local base=part(model,"Base",Vector3.new(40,.8,38),CFrame.new(x,3.6,z),navy,Enum.Material.SmoothPlastic)
        part(model,"TankFloor",Vector3.new(33,.5,27),CFrame.new(x,4.4,z),sand,Enum.Material.Sand)
        part(model,"Water",Vector3.new(32,7.5,26),CFrame.new(x,8,z),Color3.fromRGB(58,179,197),Enum.Material.Glass,.7).CanCollide=false
        for _,dz in {-14,14} do part(model,"Glass",Vector3.new(35,9,.3),CFrame.new(x,8.5,z+dz),Color3.fromRGB(159,232,235),Enum.Material.Glass,.65) end
        for _,dx in {-17,17} do part(model,"Glass",Vector3.new(.3,9,28),CFrame.new(x+dx,8.5,z),Color3.fromRGB(159,232,235),Enum.Material.Glass,.65) end
        for _,dx in {-17,17} do for _,dz in {-14,14} do part(model,"TankPost",Vector3.new(.7,10,.7),CFrame.new(x+dx,8.8,z+dz),wood) end end
        for _,dz in {-14,14} do part(model,"TankRim",Vector3.new(35,.6,.7),CFrame.new(x,13.5,z+dz),wood) end
        for j=1,4 do
            local pos=Vector3.new(x-12+j*5,5,z+8)
            local coral=ball(model,"Coral",pos,Vector3.new(2,3+j%2,2),j%2==0 and Color3.fromRGB(236,144,134) or Color3.fromRGB(98,165,136))
            coral.Material=Enum.Material.SmoothPlastic
        end
        local anchor=part(model,"Nameplate",Vector3.new(16,1.5,.5),CFrame.new(x,5,z-18),navy)
        local title,detail=label(anchor,"空闲水族箱 "..i,"等待收藏家入住",235,60,Vector3.new(0,1,0))
        local fishes=Instance.new("Folder")
        fishes.Name="SwimmingFish"
        fishes.Parent=model
        plots[i]={model=model,center=Vector3.new(x,8.5,z),title=title,detail=detail,fish=fishes,base=base}
    end
    local spawn=Instance.new("SpawnLocation")
    spawn.Name="HarborSpawn"
    spawn.Size=Vector3.new(8,1,8)
    spawn.CFrame=CFrame.new(0,4.3,-6)*CFrame.Angles(0,math.pi,0)
    spawn.Anchored=true
    spawn.Transparency=1
    spawn.CanCollide=false
    spawn.Neutral=true
    spawn.Duration=0
    spawn.Parent=root
    root:SetAttribute("OceanFillStripCount", stripCount)
    root:SetAttribute("OceanFloorTileCount", floorTileCount)
    root:SetAttribute("OceanEstimatedVoxelCount", math.ceil((ocean.maxX - ocean.minX) * (ocean.maxZ - ocean.minZ) * 18 / 64))
    root:SetAttribute("ZoneBasePartCount", zonePartCount)
    root:SetAttribute("OceanMinX", ocean.minX)
    root:SetAttribute("OceanMaxX", ocean.maxX)
    root:SetAttribute("OceanMinZ", ocean.minZ)
    root:SetAttribute("OceanMaxZ", ocean.maxZ)
    root:SetAttribute("OceanSurfaceY", ocean.surfaceY)
    root:SetAttribute("BoatSpeed", WorldLayout.Boat.speed)
    root:SetAttribute("BoatTurnSpeed", WorldLayout.Boat.turnSpeed)
    root:SetAttribute("Ready", true)
    print(string.format("FISHING_WORLD_READY: %d zones / 8 aquarium plots / %d base parts / %d water strips", #Config.Zones, zonePartCount, stripCount))
end

function World.assign(player,index)
    local plot=plots[index]
    if not plot then return false end
    owned[player]=index
    plot.title.Text=player.DisplayName.." 的水族馆"
    plot.detail.Text="从背包放入鱼，开始赚金币"
    return true
end

function World.remove(player)
    Showcase.remove(player)
    local index=owned[player]
    if index and plots[index] then
        plots[index].fish:ClearAllChildren()
        plots[index].title.Text="空闲水族箱 "..index
        plots[index].detail.Text="等待收藏家入住"
    end
    owned[player]=nil
    signatures[player]=nil
end

function World.update(player,snapshot)
    -- Showcase must be updated even before a private plot is assigned; this
    -- also hides the held fish while a fishing round is active.
    Showcase.update(player,snapshot)
    local plot=plots[owned[player]]
    if not plot then return end
    local placed={}
    local keys={}
    for _,f in ipairs(snapshot.fish or {}) do
        if f.placed then
            table.insert(placed,f)
            table.insert(keys,f.id..":"..f.level)
        end
    end
    table.sort(keys)
    plot.detail.Text=string.format("%d / %d 条  ·  %.1f 金币/小时",#placed,snapshot.tankCapacity or 10,snapshot.incomePerHour or 0)
    local signature=table.concat(keys,"|")
    if signatures[player]==signature then return end
    signatures[player]=signature
    plot.fish:ClearAllChildren()
    table.sort(placed,function(a,b) return a.income>b.income end)
    for i=1,math.min(12,#placed) do
        local f=placed[i]
        local species=Config.SpeciesById[f.species]
        if species then
            local offset=Vector3.new(((i-1)%4-1.5)*6,((i-1)%3-1)*1.5,(math.floor((i-1)/4)-1)*6)
            fishModel(plot.fish,species,f,plot.center+offset,1)
        end
    end
end

function World.travel(player,zone)
    local entry=Config.Zones[zone]
    local character=player.Character
    if not entry or not character then return false end
    local destination=FishingLocation.travelPoint(entry.center)
    character:PivotTo(CFrame.new(destination.x,destination.y,destination.z)*CFrame.Angles(0,math.pi,0))
    return true
end

function World.visitAquarium(player)
    local plot=plots[owned[player]]
    if not plot or not player.Character then return false end
    local pos=plot.center+Vector3.new(0,-1,-22)
    player.Character:PivotTo(CFrame.lookAt(pos,plot.center))
    return true
end

function World.getZone(player)
    local character=player.Character
    local hrp=character and character:FindFirstChild("HumanoidRootPart")
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    if not hrp or not humanoid or humanoid.Health<=0 then return nil end
    local pos=hrp.Position
    return FishingLocation.zoneAt(pos.X,pos.Y,pos.Z,Config.Zones)
end

return World
