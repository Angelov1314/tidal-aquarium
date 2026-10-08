-- Plain data/math: shared by the client renderer and standalone Luau tests.
local Layout = require(script and script.Parent.WorldLayout or "./WorldLayout")
local Config = {}

Config.FadeDistance = 180
Config.ResponseSeconds = 2.5
Config.UpdateSeconds = .1
Config.MaxParticleRate = 10
-- Regional presentation is deliberately bounded.  The client owns one
-- theme emitter, a small water-glint pool and a fixed number of local lights;
-- these values are also the contract used by the Studio smoke test.
Config.LightPoolSize = 4
Config.LightRange = 118
Config.GlintPoolSize = 3

function Config.effectBudget(quality)
	if quality == "off" then return {lights=0, glints=0, glintRate=0, rays=0} end
	if quality == "low" then return {lights=2, glints=2, glintRate=1, rays=.35} end
	return {lights=Config.LightPoolSize, glints=Config.GlintPoolSize, glintRate=2, rays=1}
end

local ocean = {
	brightness = 2.35, clock = 14.1, exposure = 0,
	ambient = {110, 126, 140}, outdoor = {145, 163, 176},
	density = .22, haze = 1.05, atmosphere = {193, 226, 238}, decay = {119, 149, 170},
	cloudCover = .32, cloudDensity = .3, cloudColor = {246, 250, 255},
	tint = {255, 252, 245}, saturation = .06, contrast = .03, bloom = .08,
	water = {39, 154, 172}, waterTransparency = .28,
	particleRate = 0, particleEffect = "none", particleColor = {220, 255, 240},
	particleRise = .4, particleLifetime = {2, 3}, particleSpeed = {.2, .65},
	particleSize = {.08, .18}, particleSpread = {180, 180}, particleRotSpeed = {-12, 12},
	particleLightEmission = .45, particleLightInfluence = .3,
	sunRays = .045, sunSpread = .72,
}

local function preset(name, changes)
	local result = {name = name}
	for key, value in pairs(ocean) do result[key] = value end
	for key, value in pairs(changes or {}) do result[key] = value end
	return result
end

Config.Presets = {
	[0] = preset("开放海洋"),
	[1] = preset("晨湾暖阳", {clock = 14.6, outdoor = {169, 172, 166}, cloudCover = .25}),
	[2] = preset("珊瑚晴空", {water = {41, 175, 175}, atmosphere = {183, 232, 237}, cloudCover = .18}),
	[3] = preset("蓝潮海雾", {water = {29, 109, 148}, atmosphere = {168, 199, 223}, haze = 1.5, cloudCover = .52}),
	[4] = preset("月影暮色", {clock = 17.7, brightness = 1.75, ambient = {118, 117, 153}, outdoor = {142, 144, 182}, atmosphere = {186, 191, 225}, water = {74, 122, 166}, tint = {239, 239, 255}}),
	[5] = preset("虹光霞云", {clock = 16.3, atmosphere = {226, 208, 233}, cloudColor = {255, 231, 242}, water = {75, 161, 180}, tint = {255, 242, 249}}),
	-- Fireflies drift slowly with a soft upward bias and long, sparse lives.
	[6] = preset("神秘湖微光", {
		brightness = 1.95, density = .29, haze = 1.8, atmosphere = {169, 216, 202}, decay = {96, 143, 142}, water = {39, 131, 128}, cloudCover = .55,
		particleRate = 6, particleEffect = "mystic_fireflies", particleColor = {171, 255, 204}, particleRise = .12,
		particleLifetime = {2.8, 4.4}, particleSpeed = {.04, .28}, particleSize = {.09, .25}, particleSpread = {180, 180}, particleRotSpeed = {-18, 18},
		particleLightEmission = .85, particleLightInfluence = .08, sunRays = .035, sunSpread = .8,
	}),
	-- Embers move decisively upward from the basalt landmarks and expire fast.
	[7] = preset("熔岩余烬", {
		clock = 16.4, brightness = 2, ambient = {135, 110, 107}, outdoor = {167, 139, 125}, atmosphere = {224, 184, 158}, decay = {149, 119, 113}, haze = 1.7, cloudCover = .7, cloudColor = {182, 174, 173}, water = {57, 110, 121}, tint = {255, 237, 220},
		particleRate = 8, particleEffect = "lava_embers", particleColor = {255, 172, 76}, particleRise = 1.1,
		particleLifetime = {1.05, 2.05}, particleSpeed = {.18, .82}, particleSize = {.07, .22}, particleSpread = {42, 42}, particleRotSpeed = {-35, 35},
		particleLightEmission = .72, particleLightInfluence = .16, sunRays = .04, sunSpread = .64,
	}),
	-- Alien motes are almost weightless, wide-spread and slow enough to read as stars.
	[8] = preset("外星星尘", {
		brightness = 1.9, ambient = {117, 112, 151}, outdoor = {146, 147, 183}, atmosphere = {190, 187, 229}, decay = {114, 128, 166}, cloudCover = .48, cloudColor = {218, 213, 251}, water = {56, 153, 168}, tint = {243, 239, 255},
		particleRate = 5, particleEffect = "alien_stars", particleColor = {163, 232, 255}, particleRise = .02,
		particleLifetime = {3.2, 5.2}, particleSpeed = {.03, .19}, particleSize = {.045, .16}, particleSpread = {180, 180}, particleRotSpeed = {-8, 8},
		particleLightEmission = .9, particleLightInfluence = .04, sunRays = .03, sunSpread = .86,
	}),
	-- Bubbles travel upward in a narrow column with a slightly larger read.
	[9] = preset("实验室冷光", {
		brightness = 2.2, ambient = {124, 145, 156}, outdoor = {169, 188, 193}, atmosphere = {206, 232, 239}, haze = .85, cloudCover = .42, water = {75, 171, 181}, saturation = .01,
		particleRate = 4, particleEffect = "lab_bubbles", particleColor = {143, 235, 221}, particleRise = .48,
		particleLifetime = {1.8, 3.2}, particleSpeed = {.08, .34}, particleSize = {.13, .34}, particleSpread = {24, 24}, particleRotSpeed = {-12, 12},
		particleLightEmission = .55, particleLightInfluence = .12, sunRays = .05, sunSpread = .7,
	}),
}

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- The island footprint is north-biased; include the pier/boat approach too.
function Config.regionWeight(id, x, z)
	if not finite(x) or not finite(z) then return 0 end
	local zone = Layout.Zones[id]
	if not zone then return 0 end
	local b = Layout.bounds(zone)
	local dx = math.max(b.minX - x, 0, x - b.maxX)
	local dz = math.max(b.minZ - z, 0, z - (zone.z + 112))
	local t = math.clamp(1 - math.sqrt(dx * dx + dz * dz) / Config.FadeDistance, 0, 1)
	return t * t * (3 - 2 * t)
end

function Config.resolve(x, z)
	local id, weight = 0, 0
	for candidate = 1, #Layout.Zones do
		local w = Config.regionWeight(candidate, x, z)
		if w > weight then id, weight = candidate, w end
	end
	return id, weight
end

function Config.blend(a, b, alpha)
	alpha = finite(alpha) and math.clamp(alpha, 0, 1) or 0
	local result = {name = b.name}
	for key, value in pairs(a) do
		if type(value) == "number" then
			result[key] = value + (b[key] - value) * alpha
		elseif type(value) == "table" then
			result[key] = {}
			for i = 1, #value do result[key][i] = value[i] + (b[key][i] - value[i]) * alpha end
		else
			-- Theme/profile identifiers are intentionally discrete.  Switching
			-- them at the beginning of a fade lets the bounded emitter reuse its
			-- instances while all numeric motion/color values still ease in.
			result[key] = b[key]
		end
	end
	return result
end

function Config.sample(x, z)
	local id, weight = Config.resolve(x, z)
	return Config.blend(Config.Presets[0], Config.Presets[id], weight), id, weight
end

function Config.particleBudget(rate, quality)
	if not finite(rate) or quality == "off" then return 0 end
	return math.clamp(rate, 0, Config.MaxParticleRate) * (quality == "low" and .35 or 1)
end

return Config
