--!strict
-- Client-local mixer.  It is intentionally silent until AudioConfig receives
-- real Roblox asset IDs from the approved uploads.
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local AudioConfig: any = require(shared:WaitForChild("AudioConfig"))

local Audio = {}
local folder: Folder? = nil
local sounds: {[string]: Sound} = {}
local muted: {[string]: boolean} = {Music = false, SFX = false, Ambience = false}
local lastPlayed: {[string]: number} = {}
local fades: {[string]: Tween} = {}

local function validSoundId(soundId: any): boolean
	return type(soundId) == "string" and string.match(soundId, "^rbxassetid://[1-9]%d*$") ~= nil
end

local function volumeFor(name: string): number
	local definition = AudioConfig.sounds[name]
	if not definition then return 0 end
	local bus = AudioConfig.buses[definition.bus]
	if not bus or muted[definition.bus] then return 0 end
	local gain = if type(definition.gain) == "number" then math.clamp(definition.gain, 0, 2) else 1
	return bus.volume * gain
end

local function clear()
	for _, fade in pairs(fades) do fade:Cancel() end
	table.clear(fades)
	table.clear(lastPlayed)
	for _, sound in pairs(sounds) do sound:Destroy() end
	table.clear(sounds)
	if folder then folder:Destroy(); folder = nil end
end

function Audio.reload()
	clear()
	local previous = SoundService:FindFirstChild("FishingAudio")
	if previous then previous:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = "FishingAudio"
	folder.Parent = SoundService
	for name, definition in pairs(AudioConfig.sounds) do
		if validSoundId(definition.soundId) then
			local sound = Instance.new("Sound")
			sound.Name = name
			sound.SoundId = definition.soundId
			sound.Looped = definition.looped == true
			local targetVolume = volumeFor(name)
			sound.Volume = if sound.Looped then 0 else targetVolume
			sound.Parent = folder
			sounds[name] = sound
			if sound.Looped and targetVolume > 0 then
				sound:Play()
				fades[name] = TweenService:Create(sound, TweenInfo.new(1.5), {Volume = targetVolume})
				fades[name]:Play()
			end
		end
	end
	-- Prime the two catch feedback cues in the background so the first landing
	-- and bag arrival play on time after a fresh client join.  PreloadAsync is
	-- best-effort: mute state and missing/unpublished IDs still follow the
	-- normal Audio.play path.
	task.spawn(function()
		local preload = {}
		for _, name in {"FishLand", "BagCollect"} do
			local sound = sounds[name]
			if sound then table.insert(preload, sound) end
		end
		if #preload > 0 then pcall(function() ContentProvider:PreloadAsync(preload) end) end
	end)
end

function Audio.play(name: string)
	local sound = sounds[name]
	if not sound or sound.Volume <= 0 then return end
	local now = os.clock()
	local definition = AudioConfig.sounds[name]
	local cooldown = if definition and type(definition.cooldown) == "number" then math.max(0, definition.cooldown) else (if name == "UI" then 0.08 else 0.15)
	if now - (lastPlayed[name] or -math.huge) < cooldown then return end
	lastPlayed[name] = now
	if sound.Looped then
		if not sound.IsPlaying then sound:Play() end
	else
		sound:Play()
	end
end

function Audio.setMuted(bus: string, isMuted: boolean)
	if AudioConfig.buses[bus] == nil then return end
	muted[bus] = isMuted == true
	for name, sound in pairs(sounds) do
		local definition = AudioConfig.sounds[name]
		if definition and definition.bus == bus then
			if fades[name] then fades[name]:Cancel(); fades[name] = nil end
			sound.Volume = volumeFor(name)
			if sound.Looped then
				if sound.Volume > 0 and not sound.IsPlaying then sound:Resume() end
				if sound.Volume == 0 and sound.IsPlaying then sound:Pause() end
			end
		end
	end
end

function Audio.destroy()
	clear()
end

Audio.reload()
return Audio
