-- Independent Studio presentation QA; no server/economy commands or teleports.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")
local Config = require(game.ReplicatedStorage:WaitForChild("FishingShared"):WaitForChild("EnvironmentConfig"))
local Layout = require(game.ReplicatedStorage.FishingShared.WorldLayout)
local bridge = gui:WaitForChild("EnvironmentQA", 30)
local function expect(value, message) assert(value, message) end
local function count(parent, className)
	local n = 0
	for _, item in ipairs(parent:GetChildren()) do if item:IsA(className) then n += 1 end end
	return n
end
local ok, err = pcall(function()
	expect(bridge, "EnvironmentQA missing")
	local root = workspace:WaitForChild("LocalFishingEnvironment", 10)
	expect(root and root:GetAttribute("Ready"), "environment not ready")
	local initialCount = #root:GetDescendants()
	expect(initialCount == 2 + Config.LightPoolSize * 2 + Config.GlintPoolSize * 2, "unexpected presentation pool size")
	local atmoCount = count(Lighting, "Atmosphere")
	local cloudCount = count(workspace.Terrain, "Clouds")
	expect(atmoCount == 1 and cloudCount == 1, "duplicate atmosphere/clouds")
	bridge:Invoke("setQuality", "high")
	for _, id in ipairs({6, 7, 8, 9}) do
		local zone = Layout.Zones[id]
		local before = bridge:Invoke("snapshot")
		bridge:Invoke("setPosition", Vector3.new(zone.x, 8, zone.z + 76))
		task.wait(.3)
		local entering = bridge:Invoke("snapshot")
		expect(entering.zoneId == id and entering.weight == 1, "wrong region at dock " .. id)
		expect(math.abs(entering.density - before.density) < .035, "abrupt transition " .. id)
		task.wait(8)
		local state = bridge:Invoke("snapshot")
		local target = Config.Presets[id]
		expect(math.abs(state.density - target.density) < .012, "atmosphere did not converge")
		expect(math.abs(state.clouds - target.cloudCover) < .03, "clouds did not converge")
		expect(state.instanceCount == initialCount, "instances accumulate while changing zones")
		expect(state.rate <= Config.MaxParticleRate, "unbounded particle rate")
		expect(state.lights > 0 and state.lights <= Config.LightPoolSize, "local landmark light pool inactive/unbounded")
		expect(state.particleEffect == target.particleEffect, "wrong theme particle profile")
		expect(state.rays > 0 and state.rays <= .05, "sun rays missing/excessive")
		print("ENVIRONMENT_REGION_PASS", id, state.density, state.clouds, state.rate)
	end
	local zone = Layout.Zones[7]
	bridge:Invoke("setPosition", Vector3.new(zone.x, 8, zone.z))
	task.wait(8)
	local high = bridge:Invoke("snapshot").rate
	bridge:Invoke("setQuality", "low")
	task.wait(.3)
	local low = bridge:Invoke("snapshot").rate
	expect(low > 0 and low < high * .45, "low tier did not reduce particles")
	expect(bridge:Invoke("snapshot").lights <= 2, "mobile light cap exceeded")
	bridge:Invoke("setQuality", "off")
	task.wait(.3)
	local off=bridge:Invoke("snapshot")
	expect(off.rate == 0 and off.lights == 0 and off.glints == 0 and off.rays == 0, "off tier retains effects")
	bridge:Invoke("setQuality", "high")
	bridge:Invoke("setPosition", Vector3.new(0, 8, 650))
	task.wait(12)
	local ocean = bridge:Invoke("snapshot")
	expect(ocean.zoneId == 0 and ocean.weight == 0, "open sea retained region")
	expect(ocean.rate < .15, "themed motes did not fade offshore")
	expect(ocean.glints > 0 and ocean.glintRate <= 6 and ocean.lights == 0, "open water glint/light budget")
	bridge:Invoke("setPosition", Vector3.new(8000,8,8000))
	task.wait(.6)
	expect(bridge:Invoke("snapshot").glints == 0, "glints appeared without raycast water")
	expect(count(Lighting, "Atmosphere") == atmoCount and count(workspace.Terrain, "Clouds") == cloudCount, "effect duplication")
	print("ENVIRONMENT_BUDGET_PASS", high, low, ocean.rate, ocean.instanceCount)
	bridge:Invoke("reset")
	task.wait(.3)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local expected = Config.resolve(rootPart.Position.X, rootPart.Position.Z)
		expect(bridge:Invoke("snapshot").zoneId == expected, "reset does not follow character")
	end
	print("ENVIRONMENT_SMOKE_PASS", "four thematic regions, blended transitions, ocean reset, fixed pool and quality tiers")
end)
if bridge then bridge:Invoke("reset") end
if not ok then warn("ENVIRONMENT_SMOKE_FAIL: " .. tostring(err)) end
