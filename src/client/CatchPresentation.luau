--!strict
-- Client-only catch feedback.  It never edits the profile: the server snapshot
-- remains the source of truth and this controller only owns ephemeral visuals.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local CatchFeedback = require(shared:WaitForChild("CatchFeedback"))
local CatchVFX = require(script.Parent:WaitForChild("CatchVFX"))

local CatchPresentation = {}
local Controller = {}
Controller.__index = Controller

local MAX_WORLD_VISUALS = CatchFeedback.MaxRepresentatives
local SAFE_GROUND_Y = 2.5
local FLIGHT_HEIGHT = 3.2
local HOP_HEIGHT = .55
local HANDOFF_SECONDS = .1
local MIN_VIEWPORT_SIZE = 20
local MAX_VIEWPORT_SIZE = 144

local function finiteVector(value: any): boolean
	return typeof(value) == "Vector3" and value.X == value.X and value.Y == value.Y and value.Z == value.Z
end

local function numberOr(value: any, fallback: number): number
	return type(value) == "number" and value == value and value or fallback
end

local function colorFrom(value: any, fallback: Color3): Color3
	if type(value) ~= "table" then return fallback end
	local r = tonumber(value.r or value[1])
	local g = tonumber(value.g or value[2])
	local b = tonumber(value.b or value[3])
	if not r or not g or not b then return fallback end
	return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function quadratic(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

local function quadratic2(a: Vector2, b: Vector2, c: Vector2, t: number): Vector2
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

local function fishFrame(position: Vector3, direction: Vector3, roll: number): CFrame
	if direction.Magnitude < .001 then direction = Vector3.new(1, 0, 0) end
	-- Imported/procedural fish use +X as their head direction; lookAt's forward
	-- axis is -Z, so keep the authored identity with one fixed quarter turn.
	return CFrame.lookAt(position, position + direction.Unit) * CFrame.Angles(0, math.pi / 2, roll)
end

local function boundsBottomY(model: Model): number
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

local function bottomOffset(model: Model): number
	local pivot = model:GetPivot()
	return boundsBottomY(model) - pivot.Position.Y
end

local function orientedBottomOffset(model: Model, direction: Vector3): number
	-- Flight and landing share this orientation at their seam.  Measure the
	-- actual rotated bounds instead of using the unrotated model offset, then
	-- restore the source pose before the first render frame.
	local original = model:GetPivot()
	model:PivotTo(fishFrame(Vector3.zero, direction, 0))
	local offset = boundsBottomY(model)
	model:PivotTo(original)
	return offset
end

local function setPresentationParts(model: Model)
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

local function proceduralFish(parent: Instance, species: any, fish: any, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "CatchFish_" .. tostring(fish.id or fish.species or "unknown")
	local fallbackColor = Color3.fromRGB(95, 203, 193)
	local color = colorFrom(species and species.color, fallbackColor)
	if fish.mutation == 3 then color = Color3.fromRGB(255, 203, 74) end
	if fish.mutation == 4 then color = Color3.fromRGB(199, 142, 255) end
	local scale = math.clamp((numberOr(fish.level, 1) * .04 + 1), .8, 1.35)
	local shapes = {
		Vector3.new(3.3, 1.65, 1.35), Vector3.new(2.7, 2.15, 1.3),
		Vector3.new(4.3, 1.1, 1.1), Vector3.new(3.2, .85, 2.4),
	}
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Ball
	local shapeIndex = ((numberOr(species and species.shape, 1) - 1) % #shapes) + 1
	body.Size = (shapes[shapeIndex] or shapes[1]) * scale
	body.Color = color
	body.Material = if (species and species.rarity or 1) >= 5 or numberOr(fish.mutation, 1) >= 2 then Enum.Material.Neon else Enum.Material.SmoothPlastic
	body.Parent = model
	local belly = Instance.new("Part")
	belly.Name = "Belly"
	belly.Shape = Enum.PartType.Ball
	belly.Size = Vector3.new(2.4, .95, 1.23) * scale
	belly.Position = Vector3.new(.3, -.34, 0) * scale
	belly.Color = Color3.fromRGB(255, 248, 229)
	belly.Transparency = .08
	belly.Parent = model
	for _, sign in {-1, 1} do
		local tail = Instance.new("Part")
		tail.Name = "Tail"
		tail.Size = Vector3.new(1.35, 1.15, .24) * scale
		tail.CFrame = CFrame.new(Vector3.new(-1.95, sign * .42, 0) * scale) * CFrame.Angles(0, 0, sign * -.6)
		tail.Color = color
		tail.Parent = model
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(.48, .48, .2) * scale
		eye.Position = Vector3.new(1, .28, sign * .59) * scale
		eye.Color = Color3.new(1, 1, 1)
		eye.Parent = model
		local pupil = Instance.new("Part")
		pupil.Name = "Pupil"
		pupil.Shape = Enum.PartType.Ball
		pupil.Size = Vector3.new(.22, .24, .1) * scale
		pupil.Position = Vector3.new(1.1, .29, sign * .69) * scale
		pupil.Color = Color3.fromRGB(24, 55, 68)
		pupil.Parent = model
	end
	body.Parent = model
	model.PrimaryPart = body
	setPresentationParts(model)
	model.Parent = parent
	model:PivotTo(CFrame.new(position))
	model:SetAttribute("FishSpecies", fish.species)
	model:SetAttribute("FishRarity", species and species.rarity or 0)
	return model
end

local function copyViewportModel(model: Model, viewport: ViewportFrame, rotation: CFrame?): boolean
	local ok, clone = pcall(function() return model:Clone() end)
	if not ok or not clone or not clone:IsA("Model") then return false end
	setPresentationParts(clone)
	clone:PivotTo(CFrame.new() * (rotation or CFrame.identity))
	clone.Parent = viewport
	return true
end

local function targetIsUsable(target: any): boolean
	return target ~= nil and typeof(target) == "Instance" and target.Parent ~= nil and target:IsA("GuiObject") and target.Visible
end

function Controller:_now(): number
	local source = self.options.now
	if type(source) == "function" then
		local ok, result = pcall(source)
		if ok and type(result) == "number" then return result end
	end
	return os.clock()
end

function Controller:_audio(name: string)
	local play = self.options.audioPlay
	if type(play) ~= "function" and self.options.audio and type(self.options.audio.play) == "function" then
		play = function(cue: string) self.options.audio.play(cue) end
	end
	if type(play) ~= "function" then return end
	pcall(play, name)
end

function Controller:_trackTween(tween: Tween): Tween
	table.insert(self.tweens, tween)
	return tween
end

function Controller:_bagTarget(): GuiObject?
	local getter = self.options.getBagTarget
	local target: any = nil
	if type(getter) == "function" then
		local ok, result = pcall(getter)
		if not ok then return nil end
		target = result
	else
		target = self.options.bagTarget
	end
	if not targetIsUsable(target) then return nil end
	return target :: GuiObject
end

function Controller:_sourcePosition(): Vector3
	local getter = self.options.getFloatPosition
	if type(getter) == "function" then
		local ok, result = pcall(getter)
		if ok and finiteVector(result) then return result end
	end
	local providedFloat = self.options.float
	if providedFloat and typeof(providedFloat) == "Instance" then
		if providedFloat:IsA("BasePart") then return providedFloat.Position end
		if providedFloat:IsA("Attachment") then return providedFloat.WorldPosition end
	end
	local character = self:_character()
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then return root.Position + root.CFrame.LookVector * 4 + Vector3.new(0, 2, 0) end
	return Vector3.new(0, 5, 0)
end

function Controller:_character(): Model?
	local characterGetter = self.options.getCharacter
	if type(characterGetter) == "function" then
		local ok, result = pcall(characterGetter)
		if ok and typeof(result) == "Instance" and result:IsA("Model") then return result end
	elseif typeof(self.options.character) == "Instance" and self.options.character:IsA("Model") then
		return self.options.character
	end
	return nil
end

function Controller:_surfaceAt(point: Vector3, character: Model?): (Vector3?, Vector3?)
	local origin = point + Vector3.new(0, 35, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = {self.worldFolder}
	if character then table.insert(excluded, character) end
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = false
	local result = workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
	if not result or result.Material == Enum.Material.Water then return nil, nil end
	if result.Position.Y < SAFE_GROUND_Y or result.Position.Y > 25 then return nil, nil end
	if result.Normal.Y < .65 then return nil, nil end
	if result.Instance and result.Instance:IsA("BasePart") and result.Instance.Name == "OceanFloor" then return nil, nil end
	return result.Position, result.Normal
end

function Controller:_landingSurface(source: Vector3): (Vector3?, Vector3?)
	local character = self:_character()
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local originBase = if root and root:IsA("BasePart") then root.Position else source
	local look = if root and root:IsA("BasePart") then root.CFrame.LookVector else Vector3.new(0, 0, -1)
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < .001 then look = Vector3.new(0, 0, -1) else look = look.Unit end
	return self:_surfaceAt(originBase + look * 4, character)
end

function Controller:_project(worldPosition: Vector3): Vector2?
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local ok, point, visible = pcall(function() return camera:WorldToViewportPoint(worldPosition) end)
	if not ok or not point or not visible then return nil end
	return Vector2.new(point.X, point.Y)
end

function Controller:_projectModelSize(model: Model): number?
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local boxCFrame, size = model:GetBoundingBox()
	local half = size * .5
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local visible = false
	for _, x in {-half.X, half.X} do
		for _, y in {-half.Y, half.Y} do
			for _, z in {-half.Z, half.Z} do
				local ok, point, onScreen = pcall(function()
					return camera:WorldToViewportPoint((boxCFrame * CFrame.new(x, y, z)).Position)
				end)
				if ok and point then
					visible = visible or onScreen
					minX = math.min(minX, point.X); minY = math.min(minY, point.Y)
					maxX = math.max(maxX, point.X); maxY = math.max(maxY, point.Y)
				end
			end
		end
	end
	if not visible then return nil end
	return math.clamp(math.max(maxX - minX, maxY - minY), MIN_VIEWPORT_SIZE, MAX_VIEWPORT_SIZE)
end

function Controller:_makeOverlay()
	if self.overlay and self.overlay.Parent then
		if not self.overlayRoot or not self.overlayRoot.Parent then
			local root = Instance.new("Frame")
			root.Name = "CatchOverlayRoot"
			root.BackgroundTransparency = 1
			root.BorderSizePixel = 0
			root.Active = false
			root.Position = UDim2.fromScale(0, 0)
			root.Size = UDim2.fromScale(1, 1)
			root.Parent = self.overlay
			self.overlayRoot = root
		end
		return
	end
	local parent = self.options.overlayParent or self.options.gui
	if not parent or typeof(parent) ~= "Instance" or parent.Parent == nil then return end
	local overlay = Instance.new("ScreenGui")
	overlay.Name = "FishingCatchFeedbackUI"
	overlay.ResetOnSpawn = false
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = 26
	overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay.Parent = parent
	self.overlay = overlay
	local root = Instance.new("Frame")
	root.Name = "CatchOverlayRoot"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = false
	root.Position = UDim2.fromScale(0, 0)
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = overlay
	self.overlayRoot = root
end

function Controller:_targetCenter(target: GuiObject): Vector2
	-- Resolve the bag position against the transparent inset-free root.  This
	-- uses each GUI's actual AbsolutePosition and avoids applying GuiInset a
	-- second time when the existing UIScale UI is inset-aware.
	local origin = Vector2.zero
	if self.overlayRoot and self.overlayRoot.Parent then origin = self.overlayRoot.AbsolutePosition end
	return target.AbsolutePosition + target.AbsoluteSize * .5 - origin
end

function Controller:_makeWorldFolder()
	if self.worldFolder and self.worldFolder.Parent then return end
	local folder = Instance.new("Folder")
	folder.Name = "FishingCatchFeedback"
	folder.Parent = workspace
	self.worldFolder = folder
end

function Controller:_fishModel(fish: any): Model?
	local config = self.options.config
	local speciesById = config and config.SpeciesById
	local species = speciesById and speciesById[fish.species]
	if not species then return nil end
	local safeFish = {
		id = if type(fish.id) == "string" then fish.id else "catch_" .. tostring(os.clock()),
		species = fish.species,
		level = math.max(1, math.floor(numberOr(fish.level, 1))),
		size = math.clamp(math.floor(numberOr(fish.size, 2)), 1, 4),
		mutation = math.clamp(math.floor(numberOr(fish.mutation, 1)), 1, 4),
		value = numberOr(fish.value, 0),
		income = numberOr(fish.income, 0),
	}
	local art = self.options.artRenderer
	if art and type(art.fish) == "function" then
		local ok, model = pcall(function() return art.fish(self.worldFolder, species, safeFish, self.active.source, 1) end)
		if ok and model and model:IsA("Model") then
			setPresentationParts(model)
			return model
		end
	end
	return proceduralFish(self.worldFolder, species, safeFish, self.active.source)
end

function Controller:_makeViewport(item: any, initialSize: number?): ViewportFrame?
	if not self.overlay or not self.overlay.Parent then return nil end
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "CatchFishPreview"
	viewport.BackgroundTransparency = 1
	viewport.AnchorPoint = Vector2.new(.5, .5)
	local size = math.clamp(numberOr(initialSize, 58), MIN_VIEWPORT_SIZE, MAX_VIEWPORT_SIZE)
	viewport.Size = UDim2.fromOffset(size, size)
	viewport.ZIndex = 4
	viewport.Ambient = Color3.new(.75, .75, .75)
	viewport.LightColor = Color3.new(1, .98, .92)
	viewport.LightDirection = Vector3.new(-1, -1, -1)
	local camera = Instance.new("Camera")
	camera.FieldOfView = 36
	camera.CFrame = CFrame.lookAt(Vector3.new(1.2, .75, 5.8), Vector3.zero)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.ImageTransparency = 1
	viewport.Parent = self.overlayRoot or self.overlay
	local worldModel = item.model
	local previewRotation = if worldModel then worldModel:GetPivot().Rotation else CFrame.identity
	if worldModel and copyViewportModel(worldModel, viewport, previewRotation) then
		item.pendingWorldModel = worldModel
		-- Crossfade the anchored world fish into the screen preview.  Keeping
		-- both for the same 0.1s handoff hides the coordinate-space seam while
		-- preserving the fish's live world orientation at the transition.
		local previewFade = self:_trackTween(TweenService:Create(viewport, TweenInfo.new(HANDOFF_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			ImageTransparency = 0,
		}))
		previewFade:Play()
		for _, object in worldModel:GetDescendants() do
			if object:IsA("BasePart") then
				object.LocalTransparencyModifier = 0
				local worldFade = self:_trackTween(TweenService:Create(object, TweenInfo.new(HANDOFF_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					LocalTransparencyModifier = 1,
				}))
				worldFade:Play()
			end
		end
		task.delay(HANDOFF_SECONDS + .02, function()
			if worldModel.Parent then worldModel:Destroy() end
			if item.pendingWorldModel == worldModel then item.pendingWorldModel = nil end
		end)
		item.model = nil
	else
		viewport:Destroy()
		return nil
	end
	return viewport
end

function Controller:_clearItem(item: any)
	if item.model and item.model.Parent then item.model:Destroy() end
	if item.pendingWorldModel and item.pendingWorldModel.Parent then item.pendingWorldModel:Destroy() end
	if item.viewport and item.viewport.Parent then item.viewport:Destroy() end
	item.model = nil
	item.pendingWorldModel = nil
	item.viewport = nil
end

function Controller:_clearActive()
	if not self.active then return end
	for _, item in ipairs(self.active.items) do self:_clearItem(item) end
	self.active = nil
	self:_restoreRod()
end

function Controller:_clearTweens()
	for _, connection in ipairs(self.tweenConnections) do
		if connection.Connected then connection:Disconnect() end
	end
	table.clear(self.tweenConnections)
	for _, tween in ipairs(self.tweens) do tween:Cancel() end
	table.clear(self.tweens)
	for _, pulseScale in ipairs(self.pulseScales) do
		if pulseScale.Parent then
			pulseScale.Scale = 1
			pulseScale:Destroy()
		end
	end
	table.clear(self.pulseScales)
end

function Controller:_restoreRod()
	local setPose = self.options.setRodPose
	if type(setPose) == "function" then pcall(setPose, 0, 0) end
	local setLine = self.options.setLineTightness
	if type(setLine) == "function" then pcall(setLine, 0) end
end

function Controller:_showArrival(count: number)
	self:_clearTweens()
	local target = self:_bagTarget()
	if not target then return end
	self:_makeOverlay()
	if not self.overlay then return end
	local center = self:_targetCenter(target)
	if self.vfx then self.vfx:arrival(self.overlayRoot or self.overlay, center) end
	local badge = Instance.new("TextLabel")
	badge.Name = "CatchBatchCount"
	badge.AnchorPoint = Vector2.new(.5, .5)
	badge.Position = UDim2.fromOffset(center.X, center.Y - 28)
	badge.Size = UDim2.fromOffset(104, 30)
	badge.BackgroundColor3 = Color3.fromRGB(40, 153, 151)
	badge.BackgroundTransparency = .08
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.TextColor3 = Color3.fromRGB(255, 255, 255)
	badge.TextSize = 17
	badge.Text = "+" .. tostring(math.max(0, math.floor(count)))
	badge.ZIndex = 8
	badge.Parent = self.overlayRoot or self.overlay
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = badge
	local outline = Instance.new("UIStroke")
	outline.Color = Color3.fromRGB(255, 248, 229)
	outline.Transparency = .35
	outline.Parent = badge
	local scale = Instance.new("UIScale")
	scale.Scale = .75
	scale.Parent = badge
	local grow = self:_trackTween(TweenService:Create(scale, TweenInfo.new(.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}))
	local fade = self:_trackTween(TweenService:Create(badge, TweenInfo.new(.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, .5), {
		TextTransparency = 1,
		BackgroundTransparency = 1,
	}))
	grow:Play(); fade:Play()
	task.delay(1.0, function() if badge.Parent then badge:Destroy() end end)

	local existingScale = target:FindFirstChild("CatchPulseScale")
	if not existingScale then
		existingScale = Instance.new("UIScale")
		existingScale.Name = "CatchPulseScale"
		existingScale.Scale = 1
		existingScale.Parent = target
		table.insert(self.pulseScales, existingScale)
		local pulseUp = self:_trackTween(TweenService:Create(existingScale, TweenInfo.new(.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 1.14}))
		local pulseDown = self:_trackTween(TweenService:Create(existingScale, TweenInfo.new(.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 1}))
		table.insert(self.tweenConnections, pulseUp.Completed:Connect(function() if existingScale and existingScale.Parent then pulseDown:Play() end end))
		table.insert(self.tweenConnections, pulseDown.Completed:Connect(function() if existingScale and existingScale.Parent then existingScale:Destroy() end end))
		pulseUp:Play()
	end
end

function Controller:_start(event: any)
	local target = self:_bagTarget()
	if not target then return false end
	self:_makeOverlay()
	self:_makeWorldFolder()
	if not self.vfx then self.vfx = CatchVFX.new(self.worldFolder, self.options.vfxQuality) end
	self.vfx:beginBatch()
	local source = self:_sourcePosition()
	local surface, normal = self:_landingSurface(source)
	local character = self:_character()
	if not target or not self.overlay or not self.worldFolder then return false end
	local reps = CatchFeedback.representatives(event.fish, self.options.config and self.options.config.SpeciesById, MAX_WORLD_VISUALS)
	local active = {
		event = event,
		startAt = self:_now(),
		source = source,
		surface = surface,
		normal = normal,
		noSurface = surface == nil,
		landSound = false,
		collectSound = false,
		items = {},
		rare = false,
	}
	self.active = active
	for index, fish in ipairs(reps) do
		local config = self.options.config
		local species = config and config.SpeciesById and config.SpeciesById[fish.species]
		if species and species.rarity and species.rarity >= 4 then active.rare = true end
		local model = self:_fishModel(fish)
		if model then
			local offset = bottomOffset(model)
			local landingPivot: Vector3? = nil
			local landingSurfaceY: number? = nil
			if surface then
				local look = Vector3.new(0, 0, -1)
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
					if look.Magnitude > .001 then look = look.Unit end
				end
				local right = Vector3.new(-look.Z, 0, look.X)
				if right.Magnitude < .001 then right = Vector3.new(1, 0, 0) else right = right.Unit end
				local side = (index - (#reps + 1) * .5) * 1.15
				local forward = ((index % 2) - .5) * .65
				local point = surface + right * side + look * forward
				local itemSurface = self:_surfaceAt(point, character)
				if itemSurface then
					-- The pivot height affects the flight direction, while that
					-- direction affects the rotated bounds. Iterate to the small
					-- fixed point so flight's final frame and landing's first frame
					-- have the same pivot and contact height.
					for _ = 1, 3 do
						local destination = Vector3.new(itemSurface.X, itemSurface.Y - offset, itemSurface.Z)
						offset = orientedBottomOffset(model, destination - active.source)
					end
					landingPivot = Vector3.new(itemSurface.X, itemSurface.Y - offset, itemSurface.Z)
					landingSurfaceY = itemSurface.Y
				end
			end
			table.insert(active.items, {
				fish = fish,
				model = model,
				offset = (index - 1) * CatchFeedback.StaggerSeconds,
				bottomOffset = offset,
				landing = landingPivot,
				surfaceY = landingSurfaceY,
				phase = "flight",
				viewport = nil,
				screenStart = nil,
			})
		end
	end
	-- Splash is one per catch batch, even when all 100 hooks return fish.
	self.vfx:burst(1, "splash", source, false)
	self:_connect()
	return true
end

function Controller:_connect()
	if self.renderConnection then return end
	local source = self.options.runService or RunService
	local signal = source and source.RenderStepped
	if not signal or type(signal.Connect) ~= "function" then return end
	self.renderConnection = signal:Connect(function()
		self:_step(self:_now())
	end)
end

function Controller:_finish()
	local active = self.active
	if not active or active.collectSound then return end
	active.collectSound = true
	self:_audio("BagCollect")
	self:_showArrival(numberOr(active.event.count, 0))
	self:_clearActive()
	task.delay(1.1, function()
		if not self.active then self:_clearTweens() end
	end)
	if #self.queue > 0 then task.defer(function() self:_pump() end) end
end

function Controller:_phase(active: any, item: any, localElapsed: number): (string, number)
	if active.noSurface or not item.landing then
		-- With no validated landing geometry, go from the float projection into a
		-- compact screen-space collect.  There is no artificial landing pause and
		-- no FishLand cue for this fallback path.
		if localElapsed < CatchFeedback.FlightSeconds then
			return "flight", math.clamp(localElapsed / CatchFeedback.FlightSeconds, 0, 1)
		end
		local bagTime = localElapsed - CatchFeedback.FlightSeconds
		if bagTime < CatchFeedback.BagSeconds then return "bag", math.clamp(bagTime / CatchFeedback.BagSeconds, 0, 1) end
		return "done", 1
	end
	return CatchFeedback.phaseAt(localElapsed, if active.rare then CatchFeedback.RareLingerSeconds else 0)
end

function Controller:_step(now: number)
	local active = self.active
	if not active then
		if self.renderConnection then self.renderConnection:Disconnect(); self.renderConnection = nil end
		return
	end
	local target = self:_bagTarget()
	if not target then self:cancel("bag-target") return end
	if not self.overlay or not self.overlay.Parent then self:cancel("overlay") return end
	local elapsed = math.max(0, now - active.startAt)
	if self.vfx then self.vfx:refresh() end
	local allDone = true
	local landed = false
	for index, item in ipairs(active.items) do
		local localElapsed = elapsed - item.offset
		local phase, progress = self:_phase(active, item, localElapsed)
		item.phase = phase
		if phase == "flight" then
			allDone = false
			local t = smooth(progress)
			local destination = item.landing or active.source
			local midpoint = (active.source + destination) * .5
			local controlHeight = math.max(active.source.Y, destination.Y) + FLIGHT_HEIGHT
			local control = Vector3.new(midpoint.X, controlHeight, midpoint.Z)
			local position = quadratic(active.source, control, destination, t)
			if item.model and item.model.Parent then
				local velocity = destination - active.source
				if velocity.Magnitude < .01 then velocity = Vector3.new(1, 0, 0) end
				item.model:PivotTo(fishFrame(position, velocity, math.sin(t * math.pi) * .16))
			end
		elseif phase == "landing" then
			allDone = false
			if item.landing then
				if not item.landingVFX then
					item.landingVFX = true
					self.vfx:burst(index + 1, "landing", Vector3.new(item.landing.X, item.surfaceY or item.landing.Y, item.landing.Z), active.rare)
				end
				landed = true
				local destination = item.landing or active.source
				local hop = math.sin(math.clamp(progress, 0, 1) * math.pi) * HOP_HEIGHT
				local position = destination + Vector3.new(0, hop, 0)
				if item.model and item.model.Parent then
					local direction = destination - active.source
					item.model:PivotTo(fishFrame(position, direction, math.sin(progress * math.pi) * .24))
					-- Rotation changes the world-space bounding box. Correct its
					-- actual bottom every frame so the hop contacts the raycast
					-- surface without clipping through the dock.
					local actualBottom = boundsBottomY(item.model)
					local correction = ((item.surfaceY or destination.Y) + hop) - actualBottom
					if math.abs(correction) > .001 then
						local pivot = item.model:GetPivot()
						item.model:PivotTo(CFrame.new(pivot.Position + Vector3.new(0, correction, 0)) * pivot.Rotation)
					end
				end
			end
		elseif phase == "bag" then
			allDone = false
			if not active.noSurface and not active.landSound and landed then
				active.landSound = true
				self:_audio("FishLand")
			end
			if not item.viewport then
				local current = if item.model and item.model.Parent then self:_project(item.model:GetPivot().Position) else nil
				item.screenStart = current or self:_targetCenter(target)
				item.screenSize = if item.model and item.model.Parent then self:_projectModelSize(item.model) else nil
				item.viewport = self:_makeViewport(item, item.screenSize)
			end
			local startPoint = item.screenStart or self:_targetCenter(target)
			local endPoint = self:_targetCenter(target)
			local t = smooth(progress)
			local control = (startPoint + endPoint) * .5 + Vector2.new(0, -math.max(28, (startPoint - endPoint).Magnitude * .18))
			local point = quadratic2(startPoint, control, endPoint, t)
			if item.viewport and item.viewport.Parent then
				local size = numberOr(item.screenSize, 58) + (20 - numberOr(item.screenSize, 58)) * t
				item.viewport.Position = UDim2.fromOffset(point.X, point.Y)
				item.viewport.Size = UDim2.fromOffset(size, size)
			end
		elseif phase == "done" then
			if not active.noSurface and not active.landSound and landed then
				active.landSound = true
				self:_audio("FishLand")
			end
			if item.viewport and item.viewport.Parent then item.viewport:Destroy(); item.viewport = nil end
			if item.model and item.model.Parent then item.model:Destroy(); item.model = nil end
		else
			allDone = false
		end
		if phase ~= "done" then allDone = false end
	end
	if not active.noSurface and landed and not active.landSound then
		active.landSound = true
		self:_audio("FishLand")
	end
	local setPose = self.options.setRodPose
	if type(setPose) == "function" then
		local lift = if elapsed < CatchFeedback.FlightSeconds then smooth(elapsed / CatchFeedback.FlightSeconds) else 1 - smooth(math.clamp((elapsed - CatchFeedback.FlightSeconds) / .45, 0, 1))
		pcall(setPose, lift, elapsed)
	end
	local setLine = self.options.setLineTightness
	if type(setLine) == "function" then pcall(setLine, if elapsed < CatchFeedback.FlightSeconds then smooth(elapsed / CatchFeedback.FlightSeconds) else 0) end
	if allDone or (#active.items == 0 and elapsed >= CatchFeedback.FlightSeconds + CatchFeedback.BagSeconds) then self:_finish() end
end

function Controller:_pump()
	if self.destroyed or self.active then return end
	local nextEvent = table.remove(self.queue, 1)
	if nextEvent and not self:_start(nextEvent) then
		-- A destroyed UI or missing character should discard only the visual
		-- presentation; the server snapshot still contains the reward.
		self:_clearActive()
		if #self.queue > 0 then task.defer(function() self:_pump() end) end
	end
end

function Controller:playBatch(event: any): boolean
	if self.destroyed or not CatchFeedback.validateBatch(event) then return false end
	if not CatchFeedback.acceptBatch(self.seen, self.seenOrder, event.batchId) then return false end
	if #self.queue >= CatchFeedback.MaxPendingBatches then table.remove(self.queue, 1) end
	table.insert(self.queue, event)
	self:_pump()
	return true
end

function Controller:cancel(_reason: string?)
	if self.vfx then self.vfx:destroy(); self.vfx = nil end
	self:_clearActive()
	table.clear(self.queue)
	if self.renderConnection then self.renderConnection:Disconnect(); self.renderConnection = nil end
	self:_clearTweens()
	if self.overlayRoot and self.overlayRoot.Parent then
		self.overlayRoot:ClearAllChildren()
	else
		if self.overlay then self.overlay:ClearAllChildren() end
		self.overlayRoot = nil
	end
	if self.worldFolder then self.worldFolder:ClearAllChildren() end
end

function Controller:destroy()
	if self.destroyed then return end
	self.destroyed = true
	self:cancel("destroy")
	if self.overlay and self.overlay.Parent then self.overlay:Destroy() end
	if self.worldFolder and self.worldFolder.Parent then self.worldFolder:Destroy() end
	self.overlay = nil
	self.overlayRoot = nil
	self.worldFolder = nil
end

function CatchPresentation.new(options: {[string]: any}?): any
	local self = setmetatable({}, Controller)
	self.options = options or {}
	self.queue = {}
	self.seen = {}
	self.seenOrder = {}
	self.active = nil
	self.overlay = nil
	self.overlayRoot = nil
	self.worldFolder = nil
	self.renderConnection = nil
	self.tweens = {}
	self.tweenConnections = {}
	self.pulseScales = {}
	self.destroyed = false
	return self
end

return CatchPresentation
