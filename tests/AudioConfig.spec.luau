local AudioConfig = require("../src/shared/AudioConfig")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local expected = {
	DawnBay = "Music", FishLand = "SFX", BagCollect = "SFX", Cast = "SFX", Reel = "SFX", Catch = "SFX", Rare = "SFX",
	Merge = "SFX", Coin = "SFX", Place = "SFX", UI = "SFX", Shore = "Ambience",
}

for name, bus in pairs(expected) do
	local definition = AudioConfig.sounds[name]
	expect(definition ~= nil, name .. " must be configured")
	expect(definition.bus == bus, name .. " bus mismatch")
	expect(type(definition.soundId) == "string" and (definition.soundId == "" or string.match(definition.soundId, "^rbxassetid://[1-9]%d*$")), name .. " asset reference invalid")
end
for _, name in ipairs({"FishLand", "BagCollect"}) do
	local definition = AudioConfig.sounds[name]
	expect(type(definition.gain) == "number" and definition.gain > 0 and definition.gain <= 2, name .. " gain invalid")
	expect(type(definition.cooldown) == "number" and definition.cooldown >= 0, name .. " cooldown invalid")
end
expect(AudioConfig.sounds.DawnBay.looped == true and AudioConfig.sounds.Shore.looped == true, "bed tracks must loop")
for bus, config in pairs(AudioConfig.buses) do
	expect(type(config.volume) == "number" and config.volume >= 0 and config.volume <= 1, bus .. " volume invalid")
end

print("AudioConfig.spec.luau passed")
