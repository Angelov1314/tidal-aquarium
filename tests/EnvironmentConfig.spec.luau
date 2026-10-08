local E = require("../src/shared/EnvironmentConfig")
local W = require("../src/shared/WorldLayout")
local function expect(c, m) assert(c, m) end
for id, zone in ipairs(W.Zones) do
	local b = W.bounds(zone)
	for _, point in {{zone.x, zone.z + 96}, {zone.x, b.minZ}, {b.minX, zone.z - 100}, {b.maxX, zone.z - 100}} do
		local found, weight = E.resolve(point[1], point[2])
		expect(found == id and weight == 1, "zone footprint or dock missed: " .. id)
	end
	local x, z = b.maxX + E.FadeDistance * .5, zone.z
	expect(math.abs(E.regionWeight(id, x, z) - .5) < 1e-8, "fade midpoint")
	expect(E.regionWeight(id, b.maxX + E.FadeDistance, z) == 0, "fade end")
	local before = E.regionWeight(id, x - .01, z)
	local after = E.regionWeight(id, x + .01, z)
	expect(before > after and before - after < .001, "border discontinuity")
	local p = E.sample(zone.x, zone.z)
	expect(p.name == E.Presets[id].name and p.density <= .32 and p.brightness >= 1.7, "readable preset")
	expect(p.particleRate <= E.MaxParticleRate, "particle cap")
end
for _, point in {{0, 650}, {800, 400}, {100000, 100000}, {0/0, 0}, {math.huge, 0}, {0, -math.huge}} do
	local id, weight = E.resolve(point[1], point[2])
	expect(id == 0 and weight == 0, "open ocean / invalid position must be neutral")
end
local low = E.particleBudget(8, "low")
for _,tier in ipairs({"high", "low", "off"}) do
	local budget = E.effectBudget(tier)
	expect(budget.lights <= 4 and budget.glints <= 3, "fixed pool exceeded")
	expect(budget.glints * budget.glintRate + E.particleBudget(10, tier) <= 16, "total steady particle budget")
	if tier == "off" then expect(budget.lights + budget.glints + budget.rays == 0, "off retains visual effects") end
end
local effects = {}
for id=6,9 do
	local theme=E.Presets[id]
	expect(not effects[theme.particleEffect], "themes must have distinct particle profiles")
	effects[theme.particleEffect]=true
	expect(theme.particleLifetime[2]<=5.2 and theme.sunRays<=.05, "unbounded lifetime or sun glare")
end
expect(low > 0 and low < E.particleBudget(8, "high"), "low quality must reduce rate")
expect(E.particleBudget(100, "high") == E.MaxParticleRate, "oversized rate not capped")
expect(E.particleBudget(8, "off") == 0 and E.particleBudget(0/0, "high") == 0, "off/invalid")
local p = E.blend(E.Presets[0], E.Presets[7], .5)
expect(p.water[1] == (E.Presets[0].water[1] + E.Presets[7].water[1]) / 2, "color interpolation")
expect(E.Presets[0].water[1] == 39, "blend must not mutate source")
print("EnvironmentConfig.spec: nine footprints/docks, ocean fallback, smooth borders, finite inputs and quality budgets PASS")
