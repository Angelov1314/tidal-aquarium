-- Pure Luau proof for Storage session ownership and same-user serialization.
-- This deliberately drives UpdateAsync from coroutines; it never connects to a
-- Roblox DataStore or uses a real player.
local Storage = require("../src/server/Storage")
local Model = require("../src/shared/Model")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function player(userId, name)
	return {UserId = userId, Name = name or ("Player" .. tostring(userId))}
end

local function envelope(profile, jobId, leaseToken, untilTime)
	return {
		data = profile,
		lease = {
			jobId = jobId or "storage-concurrency-job",
			token = leaseToken or "old-token",
			["until"] = untilTime or (os.time() + 100),
		},
	}
end

local function makeStore()
	local store = {
		value = nil,
		updates = 0,
		blockNext = false,
		failed = false,
		history = {},
	}
	function store:UpdateAsync(_: string, callback: any)
		self.updates += 1
		if self.blockNext then
			self.blockNext = false
			coroutine.yield("fake UpdateAsync gate")
		end
		if self.failed then
			callback(self.value)
			error("simulated UpdateAsync failure")
		end
		local nextValue = callback(self.value)
		if nextValue ~= nil then self.value = nextValue end
		table.insert(self.history, self.value)
		return self.value
	end
	return store
end

local function makeStorage(store, model)
	return setmetatable({
		model = model or Model,
		records = {},
		loading = {},
		mode = "live",
		store = store,
		jobId = "storage-concurrency-job",
		options = {},
		budgetAdapter = {available = function() return 8 end},
		serializeAdapter = function() return "{}" end,
	mutationBudgetReserve = {read = 1, write = 1},
	mutationBytesPerWindow = 4000000,
	mutationDeltaReserveBytes = 65536,
	keyUsage = {},
	}, Storage)
end

-- Reproduction: both old and new implementations enter UpdateAsync only after
-- the first coroutine has yielded. The fixed implementation rejects player B
-- while player A owns the load slot, so A remains the sole session owner.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local userId = 41001
	local oldPlayer, newPlayer = player(userId, "old"), player(userId, "new")
	store.blockNext = true
	local loading = coroutine.create(function()
		return storage:load(oldPlayer)
	end)
	local started, marker = coroutine.resume(loading)
	expect(started and marker == "fake UpdateAsync gate", "first load must yield inside UpdateAsync")
	-- The fake gates only the first datastore call; current Storage lets this
	-- second load complete and then the resumed first load overwrites its record.
	local acceptedB = storage:load(newPlayer)
	expect(not acceptedB, "same-user load must be rejected while another load yields")
	local finished, acceptedA, profileA, reasonA = coroutine.resume(loading)
	expect(finished and acceptedA and profileA and not reasonA, "first load should complete once the gate opens")
	expect(storage.records[userId].owner == oldPlayer, "first player must own the published record")
end

-- If the Player leaves while load is still yielding, close cancels the claim.
-- A lease that was already committed is released before the load returns, so
-- no ghost record survives the PlayerRemoving/onAdded race.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local p = player(41007, "leaving")
	store.blockNext = true
	local loading = coroutine.create(function()
		return storage:load(p)
	end)
	local started, marker = coroutine.resume(loading)
	expect(started and marker == "fake UpdateAsync gate", "leave fixture must yield inside UpdateAsync")
	storage:close(p)
	expect(storage.loading[p.UserId] and storage.loading[p.UserId].cancelled, "close must cancel an in-flight load claim")
	local finished, accepted = coroutine.resume(loading)
	expect(finished and not accepted and storage.records[p.UserId] == nil and storage.loading[p.UserId] == nil,
		"cancelled load must not publish a ghost session")
	expect(store.value and store.value.lease["until"] < os.time(), "cancelled load must release its lease")
end

-- An UpdateAsync error releases the in-process loading claim, so a retry can
-- make progress without inventing a new profile.
do
	local store = makeStore()
	store.failed = true
	local storage = makeStorage(store)
	local p = player(41002)
	local failed = storage:load(p)
	expect(not failed and storage.records[p.UserId] == nil and storage.loading[p.UserId] == nil,
		"failed load must clear its in-process claim")
	store.failed = false
	local retried, profile = storage:load(p)
	expect(retried and profile and storage.records[p.UserId].owner == p, "load retry must remain possible after failure")
end

-- Migration failure is rejected inside the lease-acquiring UpdateAsync
-- candidate. The old expired envelope remains untouched; no partial lease or
-- data write is published.
do
	local activeStore = makeStore()
	activeStore.value = envelope(Model.new(0), "other-job", "active-token", os.time() + 100)
	local activeStorage = makeStorage(activeStore)
	local activeRejected = activeStorage:load(player(41003))
	expect(not activeRejected and activeStore.updates == 1 and activeStore.value.lease.token == "active-token",
		"a live foreign lease must remain untouched and reject the load")

	local store = makeStore()
	store.value = envelope(Model.new(0), "other-job", "old-token", os.time() - 1)
	local failingModel = {}
	for key, value in pairs(Model) do failingModel[key] = value end
	failingModel.migrate = function()
		error("simulated migration failure")
	end
	local storage = makeStorage(store, failingModel)
	local p = player(41003)
	local failed = storage:load(p)
	expect(not failed and storage.records[p.UserId] == nil and storage.loading[p.UserId] == nil,
		"migration failure must not publish a session")
	expect(store.updates == 1 and store.value.lease.token == "old-token" and store.value.lease["until"] < os.time(),
		"migration failure must leave the old envelope unchanged")
end

-- A stale close from an old Player object must not close the new object's
-- record after a same-user reconnect.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local userId = 41004
	local oldPlayer, newPlayer = player(userId, "old"), player(userId, "new")
	expect(storage:load(oldPlayer), "old player should load")
	storage:close(oldPlayer)
	expect(storage.records[userId] == nil, "old session should close before reconnect")
	expect(storage:load(newPlayer), "new player should load after old close")
	local newRecord = storage.records[userId]
	local callbackCalled = false
	storage:close(oldPlayer, function() callbackCalled = true end)
	expect(callbackCalled and storage.records[userId] == newRecord and not newRecord.closing,
		"stale old-player close must leave the new session open")
end

-- Close marks the record before its final save yields. A reconnect during that
-- interval is rejected and cannot publish a second session.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local userId = 41005
	local current, reconnect = player(userId, "current"), player(userId, "reconnect")
	expect(storage:load(current), "current player should load")
	store.blockNext = true
	local closing = coroutine.create(function()
		storage:close(current)
	end)
	local started, marker = coroutine.resume(closing)
	expect(started and marker == "fake UpdateAsync gate" and storage.records[userId].closing,
		"close must expose the closing state while final save is in flight")
	expect(not storage:load(reconnect), "load during close must be rejected")
	local finished = coroutine.resume(closing)
	expect(finished and coroutine.status(closing) == "dead" and storage.records[userId] == nil,
		"close should remove its record after save and release complete")
end

-- A save is serialized per owned record; an old object cannot transact against
-- the replacement record while the current object's write is yielding.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local userId = 41006
	local current, stale = player(userId, "current"), player(userId, "stale")
	expect(storage:load(current), "save fixture should load")
	storage:markDirty(current)
	store.blockNext = true
	local saving = coroutine.create(function()
		return storage:save(current)
	end)
	local started, marker = coroutine.resume(saving)
	expect(started and marker == "fake UpdateAsync gate" and storage:isSaving(current),
		"save should hold the per-record write lock while UpdateAsync yields")
	local secondSave, saveReason = storage:save(current)
	expect(not secondSave and saveReason == "存档正在写入，请稍后再试。", "overlapping save must be rejected")
	local staleTransaction = storage:transaction(stale, function(candidate)
		candidate.coins += 1
		return true
	end)
	expect(not staleTransaction, "stale player must not transact against a replacement record")
	local completed, saved = coroutine.resume(saving)
	expect(completed and saved and coroutine.status(saving) == "dead", "first save should finish after gate opens")
end

-- Mutation admission checks the current profile's serialized size and the
-- datastore budget before invoking Model.  A rejected lane therefore cannot
-- consume a sequence or mutate a candidate in memory.
do
	local storage = makeStorage(makeStore())
	local p = player(41008, "admission")
	local profile = Model.new(os.time())
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	local transformations = 0
	storage.mutationBytesPerWindow = 1
	local rejectedByBytes = storage:transaction(p, function(candidate)
		transformations += 1
		candidate.coins += 100
		return true
	end, "mutation")
	expect(not rejectedByBytes and transformations == 0 and profile.coins == 100, "byte admission must reject before Model")
	storage.mutationBytesPerWindow = 4 * 1024 * 1024
	storage.budgetAdapter = {available = function() return 0 end}
	local rejectedByBudget = storage:transaction(p, function(candidate)
		transformations += 1
		candidate.coins += 100
		return true
	end, "mutation")
	expect(not rejectedByBudget and transformations == 0 and profile.coins == 100, "budget admission must reject before Model")
end

-- Admission uses the complete {data, lease} envelope, rounds each attempt to
-- 1 KiB, and keeps one future autosave/renewal envelope reserved.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local p = player(41009, "envelope")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	storage.serializeAdapter = function(value)
		return if type(value) == "table" and value.data ~= nil then string.rep("x", 1025) else "{}"
	end
	storage.mutationBytesPerWindow = 4095
	storage.mutationDeltaReserveBytes = 0
	local transforms = 0
	local rejected = storage:transaction(p, function(candidate)
		transforms += 1
		candidate.coins += 1
		return true
	end, "mutation")
	expect(not rejected and transforms == 0, "rounded complete envelope plus future reserve must reject before transform")
end

-- Three 1 KiB envelopes fit under a 4 KiB cap while the fourth envelope's
-- future reserve is retained; the fourth transform must never run.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local p = player(41010, "future-reserve")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	storage.serializeAdapter = function(value)
		return if type(value) == "table" and value.data ~= nil then string.rep("x", 1024) else "{}"
	end
	storage.mutationBytesPerWindow = 4096
	storage.mutationDeltaReserveBytes = 0
	local transforms = 0
	local function mutate(candidate)
		transforms += 1
		candidate.coins += 1
		return true
	end
	expect(storage:transaction(p, mutate, "mutation"), "first reserved mutation should fit")
	expect(storage:transaction(p, mutate, "mutation"), "second mutation should fit while retaining one future envelope")
	expect(storage:transaction(p, mutate, "mutation"), "third mutation should fit while retaining one future envelope")
	local beforeFourth = transforms
	expect(not storage:transaction(p, mutate, "mutation") and transforms == beforeFourth, "fourth mutation must preserve the future renewal slot")
	expect(storage.keyUsage[storage:_key(p.UserId)].total == 3072, "rounded write samples must be charged once per attempt")
end

-- The renewal/autosave may consume the single envelope reserved by a
-- mutation. It must not demand a second future copy at the cap boundary.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local p = player(41013, "renewal-reserve")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	storage.serializeAdapter = function(value)
		return if type(value) == "table" and value.data ~= nil then string.rep("x", 1024) else "{}"
	end
	storage.mutationBytesPerWindow = 2048
	storage.mutationDeltaReserveBytes = 0
	expect(storage:transaction(p, function(candidate)
		candidate.coins += 1
		return true
	end, "mutation"), "mutation should fit with one renewal reserve")
	expect(storage:save(p) , "autosave should consume the reserved renewal envelope")
	expect(storage.keyUsage[storage:_key(p.UserId)].total == 2048 and store.updates == 2,
		"mutation plus one autosave should consume exactly two rounded attempts")
end

-- An UpdateAsync failure remains conservatively charged even though the
-- profile is not published; this prevents immediate retry storms.
do
	local store = makeStore()
	store.failed = true
	local storage = makeStorage(store)
	local p = player(41011, "failed-write")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	storage.serializeAdapter = function(value)
		return if type(value) == "table" and value.data ~= nil then string.rep("x", 1024) else "{}"
	end
	storage.mutationBytesPerWindow = 4096
	storage.mutationDeltaReserveBytes = 0
	local ok = storage:transaction(p, function(candidate)
		candidate.coins += 1
		return true
	end, "mutation")
	expect(not ok and storage.keyUsage[storage:_key(p.UserId)].total == 1024, "failed UpdateAsync must retain one rounded attempt charge")
end

-- Release retries are independently charged, and expired samples age out of
-- the rolling window before a new release/write is admitted.
do
	local store = makeStore()
	store.failed = true
	local storage = makeStorage(store)
	local p = player(41012, "release")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
	storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
	storage.serializeAdapter = function(value)
		return if type(value) == "table" and value.data ~= nil then string.rep("x", 1024) else "{}"
	end
	storage.mutationBytesPerWindow = 2048
	storage.mutationDeltaReserveBytes = 0
	storage:_release(p, storage.records[p.UserId])
	expect(storage.keyUsage[storage:_key(p.UserId)].total == 2048, "each failed release attempt must be charged")
	local usage = storage.keyUsage[storage:_key(p.UserId)]
	for _, sample in usage.samples do sample.at = os.clock() - 61 end
	expect(storage:_trackWriteBytes(p, 1024) and usage.total == 1024, "expired rolling samples must age out")
end

-- Handshake readiness uses the last committed lease TTL for live/test records;
-- a successful renewal updates that local gate without an extra read.
do
	local store = makeStore()
	local storage = makeStorage(store)
	local p = player(41014, "lease-gate")
	local profile = Model.new(os.time())
	store.value = envelope(profile, "other-job", "old", os.time() - 1)
	expect(storage:load(p), "expired prior lease should be claimable by this job")
	expect(storage:isHandshakeReady(p), "fresh committed lease should allow handshake")
	local record = storage.records[p.UserId]
	record.leaseUntil = os.time() - 1
	expect(not storage:isHandshakeReady(p), "expired cached lease must reject handshake")
	record.leaseUntil = os.time() + 1
	expect(storage:isHandshakeReady(p), "unexpired cached lease must allow handshake")
	storage:markDirty(p)
	expect(storage:save(p), "successful save should renew the cached lease")
	expect(storage.records[p.UserId].leaseUntil > os.time() + 1 and storage:isHandshakeReady(p),
		"committed renewal must restore the lease gate")
end

-- Supplemental r7 budget contract fixture. Keep the reviewed 65,536-byte
-- mutation delta enabled and make the serializer expose a candidate that grows
-- to the delta boundary, plus a candidate that exceeds it. This exercises
-- Storage:transaction with the actual pre-Model and exact-candidate gates; it
-- does not claim a cloud quota.
do
	local function variableEnvelopeSize(value)
		local data = type(value) == "table" and value.data or nil
		local raw = if type(data) ~= "table" then 1025
			elseif data.coins >= 300 then 67585
			elseif data.coins >= 200 then 66561
			else 1025
		return string.rep("x", raw)
	end

	-- The pre-Model worst-case bound is 2 * ceil((E + delta) / 1024) * 1024.
	-- Just below that bound, the transform must not run at all.
	do
		local store = makeStore()
		local storage = makeStorage(store)
		local p = player(41015, "delta-zero-transform")
		local profile = Model.new(0)
		store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
		storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
		storage.serializeAdapter = variableEnvelopeSize
		storage.mutationBytesPerWindow = 135167
		local transforms = 0
		local ok = storage:transaction(p, function(candidate)
			transforms += 1
			candidate.coins = 200
			return true
		end, "mutation")
		expect(not ok and transforms == 0 and store.updates == 0 and profile.coins == 100,
			"nonzero delta must reject below the pre-Model bound without running Model")
	end

	-- A candidate that grows from 1,025 raw bytes to 66,561 raw bytes (the
	-- reviewed 65,536-byte delta) is accepted at the exact bound. The mutation
	-- and next full-envelope autosave each charge their actual rounded envelope;
	-- delta headroom is not counted as a second usage sample.
	do
		local store = makeStore()
		local storage = makeStorage(store)
		local p = player(41016, "delta-candidate-growth")
		local profile = Model.new(0)
		store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
		storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
		storage.serializeAdapter = variableEnvelopeSize
		storage.mutationBytesPerWindow = 135168
		local transforms = 0
		local ok = storage:transaction(p, function(candidate)
			transforms += 1
			candidate.coins = 200
			return true
		end, "mutation")
		expect(ok and transforms == 1 and store.updates == 1 and profile.coins == 200,
			"candidate growth must commit at the exact source bound")
		expect(storage.keyUsage[storage:_key(p.UserId)].total == 67584,
			"mutation must charge the actual rounded candidate envelope")
		expect(storage:save(p) and store.updates == 2 and storage.keyUsage[storage:_key(p.UserId)].total == 135168,
			"the next autosave must charge one additional actual rounded envelope")
	end

	-- A candidate that grows beyond the reviewed delta has an actual rounded
	-- current+future cost above the cap. It is rejected after candidate
	-- evaluation, with no UpdateAsync attempt and a stable profile.
	do
		local store = makeStore()
		local storage = makeStorage(store)
		local p = player(41017, "delta-boundary-reject")
		local profile = Model.new(0)
		store.value = envelope(profile, "storage-concurrency-job", "old", os.time() + 100)
		storage.records[p.UserId] = {owner = p, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "old"}
		storage.serializeAdapter = variableEnvelopeSize
		storage.mutationBytesPerWindow = 135168
		local transforms = 0
		local ok = storage:transaction(p, function(candidate)
			transforms += 1
			candidate.coins = 300
			return true
		end, "mutation")
		local usage = storage.keyUsage[storage:_key(p.UserId)]
		expect(not ok and transforms == 1 and store.updates == 0 and profile.coins == 100
			and (usage == nil or usage.total == 0),
			"candidate growth beyond the reviewed delta must fail closed without a write charge")
	end
end

print("StorageConcurrency.spec: load/save serialization, migration cleanup, close ownership PASS")
