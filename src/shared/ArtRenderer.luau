-- Presentation-only adapter. Imported geometry never changes gameplay records.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(script.Parent.ArtCatalog)
local ArtRenderer = {}

local FALLBACK_COLOR = Color3.fromRGB(95, 203, 193)

local function numberOr(value, fallback)
    return type(value) == "number" and value == value and value or fallback
end

local function colorFrom(value, fallback)
    if type(value) ~= "table" then return fallback end
    local r = tonumber(value.r or value[1])
    local g = tonumber(value.g or value[2])
    local b = tonumber(value.b or value[3])
    if not r or not g or not b then return fallback end
    return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
end

local function libraryTemplate(libraryName, name)
    local library = ReplicatedStorage:FindFirstChild(libraryName)
    if not library then return nil end
    local template = library:FindFirstChild(name)
    if template and template:IsA("Model") and template:FindFirstChildWhichIsA("BasePart", true) then return template end
    return nil
end

function ArtRenderer.template(name)
    return libraryTemplate("FishingArt", name)
end

function ArtRenderer.natureTemplate(name)
    return libraryTemplate("NatureArt", name)
end

local function cloneTemplate(template, name, parent, pivot, targetLength, sourcePackage)
    if not template then return nil end
    local model = template:Clone()
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            object.Anchored = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.CastShadow = true
        elseif object:IsA("LuaSourceContainer") then
            object:Destroy()
        end
    end
    if not model.PrimaryPart then model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true) end
    if targetLength then
        local size = model:GetExtentsSize()
        local length = math.max(size.X, size.Y, size.Z)
        if length > 0.001 then model:ScaleTo(model:GetScale() * targetLength / length) end
    end
    model:SetAttribute("SourceTemplate", name)
    if sourcePackage then model:SetAttribute("SourcePackage", sourcePackage) end
    model.Parent = parent
    model:PivotTo(pivot)
    return model
end

function ArtRenderer.clone(name, parent, pivot, targetLength)
    return cloneTemplate(ArtRenderer.template(name), name, parent, pivot, targetLength)
end

-- Nature assets remain a separate authored library. Missing mapped models
-- return nil so callers can skip the decoration without creating procedural
-- geometry that would be mistaken for the source asset.
function ArtRenderer.cloneNature(name, parent, pivot, targetLength)
    local model = cloneTemplate(
        ArtRenderer.natureTemplate(name),
        name,
        parent,
        pivot,
        targetLength,
        "Quaternius Ultimate Stylized Nature"
    )
    if model then model:SetAttribute("NatureRole", name) end
    return model
end

local function boundsBottomY(model)
    local boxCFrame, size = model:GetBoundingBox()
    local half = size * .5
    local bottom = math.huge
    for _, x in {-half.X, half.X} do
        for _, y in {-half.Y, half.Y} do
            for _, z in {-half.Z, half.Z} do
                bottom = math.min(bottom, (boxCFrame * CFrame.new(x, y, z)).Position.Y)
            end
        end
    end
    return bottom
end

-- Clone a static prop and use its world-space geometry bounds to put its
-- lowest point on the requested surface.  This deliberately does not assume
-- that the imported model's long axis is its local Y axis.
local function groundModel(model, groundY)
    if not model then return nil end
    local bottom = boundsBottomY(model)
    local delta = (groundY or 0) - bottom
    if math.abs(delta) > .0001 then
        local current = model:GetPivot()
        model:PivotTo(CFrame.new(current.Position + Vector3.new(0, delta, 0)) * current.Rotation)
    end
    model:SetAttribute("GroundY", groundY or 0)
    return model
end

function ArtRenderer.cloneGrounded(name, parent, pivot, targetLength, groundY)
    return groundModel(ArtRenderer.clone(name, parent, pivot, targetLength), groundY)
end

function ArtRenderer.cloneNatureGrounded(name, parent, pivot, targetLength, groundY)
    return groundModel(ArtRenderer.cloneNature(name, parent, pivot, targetLength), groundY)
end

local function rodEndpoints(model)
    -- Imported rods in this batch use local +Y for the tip and -Y for the
    -- grip.  The bounding box center keeps the calculation valid when the
    -- source pivot is not exactly at the mesh center.
    local boxCFrame, size = model:GetBoundingBox()
    local halfLength = size.Y * .5
    local tipWorld = boxCFrame.Position + boxCFrame.UpVector * halfLength
    local gripWorld = boxCFrame.Position - boxCFrame.UpVector * halfLength
    local pivot = model:GetPivot()
    return pivot:PointToObjectSpace(gripWorld), pivot:PointToObjectSpace(tipWorld)
end

local function authoredRodEndpoints(model)
	local artPivot = model:FindFirstChild("ArtPivot", true)
	if not artPivot then return nil, nil, nil end
	local grip = artPivot:FindFirstChild("RodGrip")
	local tip = artPivot:FindFirstChild("RodTip")
	if not grip or not tip or not grip:IsA("Attachment") or not tip:IsA("Attachment") then
		return nil, nil, nil
	end
	local pivot = model:GetPivot()
	return pivot:PointToObjectSpace(grip.WorldPosition), pivot:PointToObjectSpace(tip.WorldPosition), tip, grip
end

-- Equip the imported fishing rod as a presentation-only character child.
-- `gripCFrame` is the desired world-space grip point and orientation.  The
-- returned handle owns an idempotent cleanup function and the real tip
-- attachment used by the fishing Beam.
function ArtRenderer.heldRod(parent, hand, gripCFrame, targetLength)
    if not parent or not hand or not hand:IsA("BasePart") then return nil end
    local name = Catalog.Props.FishingRod
    local template = ArtRenderer.template(name)
    if not template then return nil end

    local model = template:Clone()
    local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
    if not primary then model:Destroy(); return nil end
    model.PrimaryPart = primary

    local constraints = {}
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            object.Anchored = false
            object.Massless = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.CastShadow = true
        elseif object:IsA("LuaSourceContainer") then
            object:Destroy()
        end
    end

    local length = targetLength or 3.5
    local size = model:GetExtentsSize()
    local longest = math.max(size.X, size.Y, size.Z)
    if longest > .001 then model:ScaleTo(model:GetScale() * length / longest) end

    -- Parent before reading authored attachment WorldPosition so Roblox has a
    -- complete world transform for ArtPivot.RodGrip/RodTip.  No frame yields
    -- between this assignment and the final welds, so an unanchored clone
    -- cannot escape the character before it is constrained.
    model.Parent = parent
	local gripLocal, tipLocal, authoredTip, authoredGrip = authoredRodEndpoints(model)
	if not gripLocal or not tipLocal then gripLocal, tipLocal = rodEndpoints(model) end
	local pose = gripCFrame or hand.CFrame
	model:PivotTo(pose * CFrame.new(-gripLocal))
    model.Name = "LocalFishingRod"
    model:SetAttribute("SourceTemplate", name)
    model:SetAttribute("RodTargetLength", length)
    model:SetAttribute("RodGripLocal", gripLocal)
    model:SetAttribute("RodTipLocal", tipLocal)

    local tip = authoredTip
    if not tip then
        tip = Instance.new("Attachment")
        tip.Name = "FishingRodTip"
        tip:SetAttribute("RodTip", true)
        tip.Parent = primary
        tip.WorldCFrame = model:GetPivot() * CFrame.new(tipLocal)
    end

	-- A Weld with explicit offsets follows the animated hand while leaving the
	-- character's native shoulder/hand joints untouched.  WeldConstraint stores
	-- the current pose only and cannot provide the small lift used by catch
	-- feedback without moving the character, so the presentation joint owns the
	-- offset instead.
	local gripWorldCFrame = if authoredGrip and authoredGrip:IsA("Attachment") then authoredGrip.WorldCFrame else model:GetPivot() * CFrame.new(gripLocal)
	local handWeld = Instance.new("Weld")
	handWeld.Name = "FishingRodHandWeld"
	handWeld.Part0 = hand
	handWeld.Part1 = primary
	handWeld.C0 = hand.CFrame:ToObjectSpace(gripWorldCFrame)
	handWeld.C1 = primary.CFrame:ToObjectSpace(gripWorldCFrame)
	handWeld.Parent = primary
	table.insert(constraints, handWeld)
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") and object ~= primary then
            local weld = Instance.new("WeldConstraint")
            weld.Name = "FishingRodPartWeld"
            weld.Part0 = primary
            weld.Part1 = object
            weld.Parent = object
            table.insert(constraints, weld)
        end
    end

    local cleaned = false
	local handle = {
		model = model,
		tip = tip,
		handJoint = handWeld,
	}
	local baseC0 = handWeld.C0
	handle.setLift = function(amount)
		if cleaned or not handWeld.Parent then return end
		local lift = math.clamp(tonumber(amount) or 0, 0, 1)
		handWeld.C0 = baseC0 * CFrame.Angles(math.rad(16) * lift, 0, 0)
	end
    handle.cleanup = function()
        if cleaned then return end
        cleaned = true
        for _, constraint in constraints do
            if constraint.Parent then constraint:Destroy() end
        end
        if model.Parent then model:Destroy() end
    end
    handle.getTip = function()
        if cleaned or not tip.Parent then return nil end
        return tip
    end
    return handle
end

local function inspectTexture(template)
    local meshParts = 0
    local meshIds = 0
    local textureRefs = 0
    local surfaceAppearances = 0
    for _, object in template:GetDescendants() do
        if object:IsA("MeshPart") then
            meshParts += 1
            if object.MeshId ~= "" then meshIds += 1 end
            if object.TextureID ~= "" then textureRefs += 1 end
        elseif object:IsA("SurfaceAppearance") then
            surfaceAppearances += 1
            if object.ColorMap ~= "" then textureRefs += 1 end
        end
    end
    return {
        ok = meshParts > 0 and meshIds > 0 and textureRefs > 0,
        meshParts = meshParts,
        meshIds = meshIds,
        textureRefs = textureRefs,
        surfaceAppearances = surfaceAppearances,
    }
end

-- Keep the material gate strict: geometry alone is not an imported visual.
-- The returned evidence is useful to QA without accepting blank author meshes.
function ArtRenderer.textureEvidence(name)
    local template = ArtRenderer.template(name)
    if not template then
        return {
            ok = false,
            reason = "missing-template",
            meshParts = 0,
            meshIds = 0,
            textureRefs = 0,
            surfaceAppearances = 0,
        }
    end
    local evidence = inspectTexture(template)
    if not evidence.ok then evidence.reason = "missing-mesh-or-texture" end
    return evidence
end

function ArtRenderer.natureEvidence(name)
    local template = ArtRenderer.natureTemplate(name)
    if not template then
        return {
            ok = false,
            reason = "missing-template",
            meshParts = 0,
            meshIds = 0,
            textureRefs = 0,
            surfaceAppearances = 0,
        }
    end
    local evidence = inspectTexture(template)
    if not evidence.ok then evidence.reason = "missing-mesh-or-texture" end
    return evidence
end

local function hasUploadedTexture(template)
    return inspectTexture(template).ok
end

local function setPresentationParts(model)
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            object.Anchored = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.CastShadow = true
        elseif object:IsA("LuaSourceContainer") then
            object:Destroy()
        end
    end
    if not model.PrimaryPart then model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true) end
end

-- The imported library is source-backed geometry. Every mapped species is
-- allowed through only after the strict mesh-plus-texture gate above; the
-- procedural model remains a bounded failure path for missing mappings or
-- unavailable engine assets. This is presentation geometry only; fish records
-- and economy data stay on the server unchanged.
local function proceduralFish(parent, species, fish, position, targetLength)
    local model = Instance.new("Model")
    model.Name = "Fish_" .. tostring(fish and fish.id or (species and species.id) or "unknown")

    local rarity = math.clamp(math.floor(numberOr(species and species.rarity, 1)), 1, 7)
    local shapeIndex = ((math.floor(numberOr(species and species.shape, 1)) - 1) % 4) + 1
    local color = colorFrom(species and species.color, FALLBACK_COLOR)
    local mutation = math.clamp(math.floor(numberOr(fish and fish.mutation, 1)), 1, 4)
    if mutation == 3 then color = color:Lerp(Color3.fromRGB(255, 204, 100), .45) end
    if mutation == 4 then color = color:Lerp(Color3.fromRGB(208, 165, 255), .45) end
    local accent = color:Lerp(Color3.fromRGB(255, 248, 229), .2)
    local scale = math.clamp(numberOr(fish and fish.level, 1) * .04 + 1, .8, 1.35)
    local shapes = {
        Vector3.new(3.2, 1.55, 1.3), -- rounded fish
        Vector3.new(2.65, 2.15, 1.3), -- tall angelfish-like fish
        Vector3.new(4.35, 1.08, 1.02), -- long fish
        Vector3.new(3.35, .82, 2.35), -- ray-like fish
    }
    local body = Instance.new("Part")
    body.Name = "Body"
    body.Shape = Enum.PartType.Ball
    body.Size = shapes[shapeIndex] * scale
    body.Color = color
    body.Material = if rarity >= 5 or mutation >= 2 then Enum.Material.Neon else Enum.Material.SmoothPlastic
    body.Parent = model

    local belly = Instance.new("Part")
    belly.Name = "Belly"
    belly.Shape = Enum.PartType.Ball
    belly.Size = Vector3.new(2.35, .9, 1.18) * scale
    belly.Position = Vector3.new(.25, -.3, 0) * scale
    belly.Color = Color3.fromRGB(255, 248, 229)
    belly.Transparency = .08
    belly.Parent = model

    local tailWidth = if shapeIndex == 4 then 1.5 else 1.15
    for _, sign in {-1, 1} do
        local tail = Instance.new("Part")
        tail.Name = "Tail"
        tail.Size = Vector3.new(if shapeIndex == 3 then 1.65 else 1.35, tailWidth, .24) * scale
        tail.CFrame = CFrame.new(Vector3.new(-1.95, sign * (if shapeIndex == 4 then .32 else .42), 0) * scale)
            * CFrame.Angles(0, 0, sign * -.6)
        tail.Color = accent
        tail.Material = body.Material
        tail.Parent = model

        local eye = Instance.new("Part")
        eye.Name = "Eye"
        eye.Shape = Enum.PartType.Ball
        eye.Size = Vector3.new(.46, .46, .2) * scale
        eye.Position = Vector3.new(1, .27, sign * .59) * scale
        eye.Color = Color3.new(1, 1, 1)
        eye.Parent = model

        local pupil = Instance.new("Part")
        pupil.Name = "Pupil"
        pupil.Shape = Enum.PartType.Ball
        pupil.Size = Vector3.new(.21, .23, .1) * scale
        pupil.Position = Vector3.new(1.1, .28, sign * .69) * scale
        pupil.Color = Color3.fromRGB(24, 55, 68)
        pupil.Parent = model
    end

    if shapeIndex == 2 or shapeIndex == 4 then
        local fin = Instance.new("WedgePart")
        fin.Name = "DorsalFin"
        fin.Size = Vector3.new(1.15, .72, .18) * scale
        fin.CFrame = CFrame.new(Vector3.new(-.1, 1.0, 0) * scale) * CFrame.Angles(0, 0, math.rad(-18))
        fin.Color = accent
        fin.Material = body.Material
        fin.Parent = model
    end

    model.PrimaryPart = body
    setPresentationParts(model)
    local desiredLength = math.max(.1, numberOr(targetLength, 3.3))
    local extents = model:GetExtentsSize()
    local longest = math.max(extents.X, extents.Y, extents.Z)
    if longest > .001 then model:ScaleTo(model:GetScale() * desiredLength / longest) end
    model.Parent = parent
    model:PivotTo(CFrame.new(position))
    model:SetAttribute("FishSpecies", fish and fish.species or (species and species.id))
    model:SetAttribute("FishRarity", rarity)
    model:SetAttribute("SwimCenter", position)
    model:SetAttribute("SwimSeed", tonumber(string.sub(tostring(fish and fish.id or ""), 2)) or #tostring(fish and fish.id or "") * .7)
    model:SetAttribute("FishLevel", numberOr(fish and fish.level, 1))
    model:SetAttribute("FishVisualSource", "ProceduralFallback")
    model:SetAttribute("FishVisualShape", shapeIndex)
    return model
end

function ArtRenderer.hasUploadedTexture(name)
    local template = ArtRenderer.template(name)
    return template ~= nil and hasUploadedTexture(template)
end

function ArtRenderer.visualSource(species)
    local name = species and Catalog.Fish[species.id]
    if name and ArtRenderer.hasUploadedTexture(name) then
        return "ImportedTemplate", name
    end
    return "ProceduralFallback", name
end

function ArtRenderer.fish(parent, species, fish, position, sizeScale, forceFallback)
    species = species or {}
    fish = fish or {}
    position = position or Vector3.zero
    local name = Catalog.Fish[species.id]
    local template = if not forceFallback and name then ArtRenderer.template(name) else nil
    -- Old raw FBX imports can lose their material colors in Studio. Keep a
    -- source-backed model only when the uploaded mesh also has its texture.
    if template and hasUploadedTexture(template) then
        local model = ArtRenderer.clone(name, parent, CFrame.new(position), 3.3 * math.max(.1, numberOr(sizeScale, 1)))
        if model then
            model.Name = "Fish_" .. tostring(fish.id or species.id or "unknown")
            model:SetAttribute("SwimCenter", position)
            model:SetAttribute("SwimSeed", tonumber(string.sub(tostring(fish.id or ""), 2)) or #tostring(fish.id or "") * .7)
            model:SetAttribute("FishLevel", numberOr(fish.level, 1))
            model:SetAttribute("FishRarity", numberOr(species.rarity, 1))
            model:SetAttribute("FishSpecies", fish.species or species.id)
            model:SetAttribute("FishVisualSource", "ImportedTemplate")
            model:SetAttribute("SourceTemplate", name)
            if numberOr(fish.mutation, 1) >= 3 then
                local tint = if fish.mutation == 3 then Color3.fromRGB(255, 204, 100) else Color3.fromRGB(208, 165, 255)
                for _, object in model:GetDescendants() do
                    if object:IsA("BasePart") then object.Color = object.Color:Lerp(tint, .35) end
                end
            end
            return model
        end
    end
    return proceduralFish(parent, species, fish, position, 3.3 * math.max(.1, numberOr(sizeScale, 1)))
end

-- Mount the same fish visual used by world catches into a ViewportFrame.
-- Imported meshes and fallback geometry vary in pivot and aspect ratio, so the
-- bounds are centered first and the camera distance is derived from the real
-- extents instead of a fixed source pivot.
function ArtRenderer.mountPreview(viewport, species, fish, targetLength, forceFallback)
    if not viewport or not viewport:IsA("ViewportFrame") then return nil end
    local requestedLength = math.max(.1, numberOr(targetLength, 3.3))
    local model = ArtRenderer.fish(viewport, species, fish, Vector3.zero, requestedLength / 3.3, forceFallback)
    if not model then return nil end
    local boxCFrame, size = model:GetBoundingBox()
    local pivot = model:GetPivot()
    model:PivotTo(CFrame.new(pivot.Position - boxCFrame.Position) * pivot.Rotation)

    local fieldOfView = 32
    local radius = math.max(.05, size.Magnitude * .5)
    local distance = radius / math.tan(math.rad(fieldOfView * .5)) * 1.18
    local direction = Vector3.new(.22, .12, 1).Unit
    local camera = Instance.new("Camera")
    camera.Name = "FishPreviewCamera"
    camera.FieldOfView = fieldOfView
    camera.CFrame = CFrame.lookAt(direction * distance, Vector3.zero)
    camera.Parent = viewport
    viewport.CurrentCamera = camera
    viewport.Ambient = Color3.new(.75, .75, .75)
    viewport.LightColor = Color3.new(1, .98, .92)
    viewport.LightDirection = Vector3.new(-1, -1, -1)
    viewport:SetAttribute("FishVisualSource", model:GetAttribute("FishVisualSource") or "ProceduralFallback")
    local sourceTemplate = model:GetAttribute("SourceTemplate")
    if sourceTemplate then viewport:SetAttribute("SourceTemplate", sourceTemplate) end
    return model, camera
end

return ArtRenderer
