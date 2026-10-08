-- Studio-callable persistence regression check. It uses no DataStore service.
-- Require this module and call the returned function from a Studio server test.
local Storage = require(game:GetService("ServerScriptService"):WaitForChild("FishingServer"):WaitForChild("Storage"))
local Model = require(game:GetService("ReplicatedStorage"):WaitForChild("FishingShared"):WaitForChild("Model"))

local function envelope(profile)
	return {data = profile, lease = {jobId = "fake-job", token = "old", ["until"] = os.time() + 100}}
end

return function()
	local player = {UserId = 991337}
	local profile = Model.new(os.time())
	local fakeStore = {value = envelope(profile)}
	function fakeStore:UpdateAsync(_: string, callback: any)
		-- Roblox may retry a callback. Both invocations see the same old snapshot.
		local first = callback(self.value)
		local second = callback(self.value)
		self.value = second or first
		return self.value
	end
	local storage = setmetatable({model = Model, records = {}, mode = "live", store = fakeStore, jobId = "fake-job", serializeAdapter = function() return "{}" end, mutationBytesPerWindow = 4 * 1024 * 1024, mutationDeltaReserveBytes = 65536, keyUsage = {}}, Storage)
	storage.records[player.UserId] = {owner = player, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	local stable = profile
	local transformations = 0
	assert(storage:_write(player, function(candidate)
		transformations += 1
		candidate.coins += 7
		return true
	end))
	assert(transformations == 1, "a retried UpdateAsync callback must not repeat a grant")
	assert(storage.records[player.UserId].profile == stable and stable.coins == 107, "profile identity must remain stable")
	-- Persisted receipt markers and grants share one transaction, including retries.
	local function grant(candidate)
		if candidate.receipts["receipt-test"] then return true end
		candidate.boostUntil = math.max(os.time(),candidate.boostUntil)+1800
		candidate.receipts["receipt-test"]=os.time()
		return true
	end
	assert(storage:transaction(player,grant))
	local expiry=profile.boostUntil
	assert(storage:transaction(player,grant) and profile.boostUntil==expiry,"receipt replay must not extend twice")
	local previousToken=storage.records[player.UserId].leaseToken
	storage.records[player.UserId].dirty=false
	assert(storage:save(player) and storage.records[player.UserId].leaseToken~=previousToken,"clean save renews lease")
	assert(not storage:load(player),"same-process reconnect cannot replace an active record")
	local oldCoins=profile.coins
	assert(not storage:transaction(player,function(candidate) candidate.coins+=100;error("transform failure") end))
	assert(profile.coins==oldCoins,"throwing transform cannot grant")

	local failingProfile = Model.new(os.time())
	local failingStore = {value = envelope(failingProfile)}
	function failingStore:UpdateAsync(_: string, callback: any)
		callback(self.value)
		error("simulated write failure")
	end
	local failed = setmetatable({model = Model, records = {}, mode = "live", store = failingStore, jobId = "fake-job", serializeAdapter = function() return "{}" end, mutationBytesPerWindow = 4 * 1024 * 1024, mutationDeltaReserveBytes = 65536, keyUsage = {}}, Storage)
	failed.records[player.UserId] = {owner = player, profile = failingProfile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	assert(not failed:_write(player, function(candidate) candidate.coins += 7; return true end))
	assert(failingProfile.coins == 100 and failed.records[player.UserId].lost, "failed save must not grant or keep gameplay active")
	return true
end
