-- Region presentation is local: sailing/fishing authority stays on the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Config = require(ReplicatedStorage:WaitForChild("FishingShared"):WaitForChild("EnvironmentConfig"))
local RegionalVFX = require(script.Parent:WaitForChild("RegionalVFX"))
local terrain = workspace.Terrain
local qaMode = RunService:IsStudio() and script.Parent:FindFirstChild("EnvironmentSmoke") ~= nil

if workspace:FindFirstChild("LocalFishingEnvironment") then return end
local root = Instance.new("Folder")
root.Name = "LocalFishingEnvironment"
root.Parent = workspace

local owned, originals, connections = {}, {}, {}
local function acquire(parent, className, name)
	local object = parent:FindFirstChildOfClass(className)
	if object then return object end
	object = Instance.new(className)
	object.Name = name
	object.Parent = parent
	table.insert(owned, object)
	return object
end
local atmosphere = acquire(Lighting, "Atmosphere", "FishingAtmosphere")
local correction = acquire(Lighting, "ColorCorrectionEffect", "FishingColorCorrection")
local bloom = acquire(Lighting, "BloomEffect", "FishingBloom")
local clouds = acquire(terrain, "Clouds", "FishingClouds")
local rays = acquire(Lighting, "SunRaysEffect", "FishingSunRays")

local function remember(object, properties)
	local saved = {}
	for _, key in ipairs(properties) do
		local ok, value = pcall(function() return object[key] end)
		if ok then saved[key] = value end
	end
	originals[object] = saved
end
remember(Lighting, {"Brightness", "ClockTime", "ExposureCompensation", "Ambient", "OutdoorAmbient", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ShadowSoftness", "LightingStyle", "PrioritizeLightingQuality"})
remember(atmosphere, {"Density", "Haze", "Color", "Decay", "Offset", "Glare"})
remember(correction, {"Enabled", "TintColor", "Saturation", "Contrast"})
remember(bloom, {"Enabled", "Intensity", "Size", "Threshold"})
remember(clouds, {"Enabled", "Cover", "Density", "Color"})
remember(rays, {"Enabled", "Intensity", "Spread"})
remember(terrain, {"WaterColor", "WaterTransparency"})
remember(workspace, {"GlobalWind"})

-- These properties may be editor-only on older clients; retain the place's
-- existing Future configuration if the runtime cannot write them.
local styleApplied = pcall(function() Lighting.LightingStyle = Enum.LightingStyle.Realistic end)
local distanceApplied = pcall(function() Lighting.PrioritizeLightingQuality = false end)
Lighting.EnvironmentDiffuseScale = .7
Lighting.EnvironmentSpecularScale = .85
Lighting.ShadowSoftness = .35
atmosphere.Offset = .25
atmosphere.Glare = .08
correction.Enabled = true
bloom.Enabled = true
bloom.Size = 20
bloom.Threshold = 1.4
clouds.Enabled = true
workspace.GlobalWind = Vector3.new(3, 0, 1)

-- One small reusable volume, not thousands of particles spread over the map.
local volume = Instance.new("Part")
volume.Name = "LocalMotes"
volume.Anchored = true
volume.CanCollide = false
volume.CanTouch = false
volume.CanQuery = false
volume.CastShadow = false
volume.Transparency = 1
volume.Size = Vector3.new(24, 12, 24)
volume.Parent = root
local emitter = Instance.new("ParticleEmitter")
emitter.Name = "ThemeMotes"
emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
emitter.Rate = 0
emitter.Lifetime = NumberRange.new(2, 3)
emitter.Speed = NumberRange.new(.2, .65)
emitter.SpreadAngle = Vector2.new(180, 180)
emitter.Rotation = NumberRange.new(0, 360)
emitter.RotSpeed = NumberRange.new(-12, 12)
emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, .08), NumberSequenceKeypoint.new(.4, .18), NumberSequenceKeypoint.new(1, .04)})
emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(.2, .55), NumberSequenceKeypoint.new(.8, .7), NumberSequenceKeypoint.new(1, 1)})
emitter.LightEmission = .45
emitter.LightInfluence = .3
emitter.Parent = volume
local regional = RegionalVFX.new(root, Config)

local qualityOverride, positionOverride
local current = Config.blend(Config.Presets[0], Config.Presets[0], 1)
local zoneId, zoneWeight = 0, 0
local lastPosition
local alive, accumulator = true, 0
local gameSettings
pcall(function() gameSettings = UserSettings():GetService("UserGameSettings") end)
local function quality()
	if qualityOverride then return qualityOverride end
	local requested = playerGui:GetAttribute("EnvironmentQuality")
	if requested == "high" or requested == "low" or requested == "off" then return requested end
	local saved = 0
	if gameSettings then pcall(function() saved = gameSettings.SavedQualityLevel.Value end) end
	if saved > 0 and saved <= 3 then return "low" end
	if UserInputService.TouchEnabled then return "low" end
	return "high"
end
local function rgb(t) return Color3.fromRGB(t[1], t[2], t[3]) end
local function apply(p)
	Lighting.Brightness = p.brightness
	Lighting.ClockTime = p.clock
	Lighting.ExposureCompensation = p.exposure
	Lighting.Ambient = rgb(p.ambient)
	Lighting.OutdoorAmbient = rgb(p.outdoor)
	atmosphere.Density = p.density
	atmosphere.Haze = p.haze
	atmosphere.Color = rgb(p.atmosphere)
	atmosphere.Decay = rgb(p.decay)
	clouds.Cover = p.cloudCover
	clouds.Density = p.cloudDensity
	clouds.Color = rgb(p.cloudColor)
	correction.TintColor = rgb(p.tint)
	correction.Saturation = p.saturation
	correction.Contrast = p.contrast
	bloom.Intensity = p.bloom
	terrain.WaterColor = rgb(p.water)
	terrain.WaterTransparency = p.waterTransparency
	emitter.Color = ColorSequence.new(rgb(p.particleColor))
	emitter.Acceleration = Vector3.new(0, p.particleRise, 0)
	emitter.Lifetime = NumberRange.new(p.particleLifetime[1], p.particleLifetime[2])
	emitter.Speed = NumberRange.new(p.particleSpeed[1], p.particleSpeed[2])
	emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, p.particleSize[1]), NumberSequenceKeypoint.new(.4, p.particleSize[2]), NumberSequenceKeypoint.new(1, 0)})
	emitter.SpreadAngle = Vector2.new(p.particleSpread[1], p.particleSpread[2])
	emitter.RotSpeed = NumberRange.new(p.particleRotSpeed[1], p.particleRotSpeed[2])
	emitter.LightEmission = p.particleLightEmission
	emitter.LightInfluence = p.particleLightInfluence
	local texture = if p.particleEffect == "lava_embers" then "fire_sparks_main.dds" elseif p.particleEffect == "lab_bubbles" then "forcefield_vortex_main.dds" else "sparkles_main.dds"
	emitter.Texture = "rbxasset://textures/particles/" .. texture
	rays.Intensity = p.sunRays * Config.effectBudget(quality()).rays
	rays.Spread = p.sunSpread
	rays.Enabled = quality() ~= "off"
end

local lastQuality
local function update(dt)
	local character = player.Character
	local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
	local position = positionOverride or (characterRoot and characterRoot.Position)
	local target, nextId, weight = Config.sample(position and position.X, position and position.Z)
	local tier = quality()
	if nextId ~= zoneId or tier ~= lastQuality or not position or (position and lastPosition and (position - lastPosition).Magnitude > 100) then emitter:Clear() end
	zoneId, zoneWeight = nextId, weight
	current = Config.blend(current, target, 1 - math.exp(-dt / Config.ResponseSeconds))
	apply(current)
	if position then volume.Position = position + Vector3.new(0, 5, 0) end
	emitter.Rate = position and Config.particleBudget(current.particleRate, quality()) or 0
	regional:update(position, tier, dt, character)
	lastQuality = tier
	lastPosition = position
	root:SetAttribute("ZoneId", zoneId)
	root:SetAttribute("RegionWeight", zoneWeight)
	root:SetAttribute("Quality", quality())
	root:SetAttribute("ParticleRate", emitter.Rate)
end

local bridge
local function cleanup()
	if not alive then return end
	alive = false
	regional:destroy()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	if bridge then bridge:Destroy() end
	for object, properties in pairs(originals) do
		if object.Parent or object == workspace then
			for key, value in pairs(properties) do pcall(function() object[key] = value end) end
		end
	end
	for _, object in ipairs(owned) do object:Destroy() end
	root:Destroy()
end

local function installBridge()
	if bridge or not RunService:IsStudio() then return end
	bridge = Instance.new("BindableFunction")
	bridge.Name = "EnvironmentQA"
	bridge.OnInvoke = function(command, value)
		if command == "setPosition" then
			if value ~= nil and typeof(value) ~= "Vector3" then return false end
			positionOverride = value
			return true
		elseif command == "setQuality" then
			if value ~= nil and value ~= "high" and value ~= "low" and value ~= "off" then return false end
			qualityOverride = value
			return true
		elseif command == "snapshot" then
			local lights, glints, glintRate = regional:snapshot()
			return {zoneId = zoneId, weight = zoneWeight, rate = emitter.Rate, quality = quality(),
				density = atmosphere.Density, water = terrain.WaterColor, clouds = clouds.Cover,
				lights = lights, glints = glints, glintRate = glintRate, rays = rays.Intensity,
				particleEffect = current.particleEffect, lifetime = emitter.Lifetime.Max,
				instanceCount = #root:GetDescendants(), styleApplied = styleApplied, distanceApplied = distanceApplied}
		elseif command == "reset" then
			positionOverride, qualityOverride = nil, nil
			return true
		elseif command == "cleanup" then
			task.defer(cleanup)
			return true
		end
		return false
	end
	bridge.Parent = playerGui
end
if qaMode then installBridge()
elseif RunService:IsStudio() then
	table.insert(connections, script.Parent.ChildAdded:Connect(function(child)
		if child.Name == "EnvironmentSmoke" then installBridge() end
	end))
end

table.insert(connections, RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < Config.UpdateSeconds then return end
	local elapsed = math.min(accumulator, .5)
	accumulator = 0
	update(elapsed)
end))
table.insert(connections, script.Destroying:Connect(cleanup))
update(Config.UpdateSeconds)
root:SetAttribute("Ready", true)
