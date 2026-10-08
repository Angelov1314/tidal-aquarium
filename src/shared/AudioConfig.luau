--!strict
-- Public source snapshot: audio files and account-specific Roblox sound IDs
-- are intentionally omitted. Supply assets that you are authorized to use.
local AudioConfig = {
	buses = {
		Music = {volume = 0.22},
		SFX = {volume = 0.65},
		Ambience = {volume = 0.20},
	},
	sounds = {
		DawnBay = {bus = "Music", soundId = "", looped = true},
		FishLand = {bus = "SFX", soundId = "", gain = 0.72, cooldown = 0.15},
		BagCollect = {bus = "SFX", soundId = "", gain = 1.38, cooldown = 0.12},
		Cast = {bus = "SFX", soundId = "", cooldown = 0.15},
		Reel = {bus = "SFX", soundId = ""},
		Catch = {bus = "SFX", soundId = "", cooldown = 0.15},
		Rare = {bus = "SFX", soundId = ""},
		Merge = {bus = "SFX", soundId = ""},
		Coin = {bus = "SFX", soundId = ""},
		Place = {bus = "SFX", soundId = ""},
		UI = {bus = "SFX", soundId = ""},
		Shore = {bus = "Ambience", soundId = "", looped = true},
	},
}

return AudioConfig
