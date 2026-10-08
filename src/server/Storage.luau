--!strict
-- Studio is session-only by default. Live saves use a per-server lease and never
-- replace a profile with a partially written copy.
local Storage = {}
Storage.__index = Storage
local LEASE_SECONDS = 120
local MUTATION_WINDOW_SECONDS = 60
local BYTE_CHARGE_UNIT = 1024
local DEFAULT_MUTATION_BYTES_PER_WINDOW = 4000000
local MutationProtocol = if script then require(game:GetService("ReplicatedStorage"):WaitForChild("FishingShared"):WaitForChild("MutationProtocol")) else require("../shared/MutationProtocol")

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function replaceStable(target: any, source: any)
	for key in pairs(target) do target[key] = nil end
	for key, value in pairs(source) do target[key] = clone(value) end
end

local function token(jobId: string): string
	return jobId .. ":" .. tostring(os.clock()) .. ":" .. tostring(math.random(1, 2 ^ 30))
end

local function retryWait(seconds: number)
	if task ~= nil and task.wait then task.wait(seconds) end
end

function Storage.new(model: any, options: any?)
	local self = setmetatable({}, Storage)
	self.model, self.records, self.loading, self.mode, self.store = model, {}, {}, "session", nil
	self.options = options or {}
	self.budgetAdapter = self.options.budgetAdapter
	self.serializeAdapter = self.options.serializeAdapter
	-- One slot is consumed by the mutation and one remains reserved for the
	-- lease/autosave path. The byte cap follows the documented per-key rolling
	-- budget and is overrideable by a reviewed adapter.
	self.mutationBudgetReserve = self.options.mutationBudgetReserve or { read = 2, write = 2 }
	self.mutationBytesPerWindow = if self.options.mutationBytesPerWindow ~= nil then self.options.mutationBytesPerWindow else DEFAULT_MUTATION_BYTES_PER_WINDOW
	self.mutationDeltaReserveBytes = if self.options.mutationDeltaReserveBytes ~= nil then self.options.mutationDeltaReserveBytes else MutationProtocol.MaxLaneDeltaBytes
	self.keyUsage = {}
	self.jobId = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(math.random(1, 1e9)))
	self.namespace = "FishingAquarium_v1"
	if not game:GetService("RunService"):IsStudio() then
		self.mode = "live"
	elseif game:GetService("ServerScriptService"):GetAttribute("FishingUseTestDataStore") == true then
		self.mode, self.namespace = "test", self.namespace .. "_TEST"
	end
	if self.mode ~= "session" then
		local ok, store = pcall(function() return game:GetService("DataStoreService"):GetDataStore(self.namespace) end)
		if ok then self.store = store else self.mode = "unavailable" end
	end
	return self
end

function Storage:getMode(): string return self.mode end
function Storage:_key(userId: number): string return "player_" .. tostring(userId) end

-- Player objects are the in-process session identity. UserId is only the cloud
-- key; accepting a different object with the same UserId would let a delayed
-- save/close from an old connection mutate the replacement session.
function Storage:_recordFor(player: Player): any?
	local record = self.records[player.UserId]
	if not record or record.owner ~= player then return nil end
	return record
end

local function validEnvelope(model: any, envelope: any): boolean
	return type(envelope) == "table" and type(envelope.data) == "table" and model.validate(envelope.data)
		and type(envelope.lease) == "table" and type(envelope.lease.jobId) == "string"
		and type(envelope.lease.token) == "string" and type(envelope.lease["until"]) == "number"
		and envelope.lease["until"] == envelope.lease["until"] and envelope.lease["until"] > -math.huge and envelope.lease["until"] < math.huge
end

local function storageBudget(storage: any, kind: string): number?
	if storage.budgetAdapter and type(storage.budgetAdapter.available) == "function" then
		local ok, available = pcall(storage.budgetAdapter.available, storage.budgetAdapter, kind)
		if not ok or type(available) ~= "number" or available ~= available then return nil end
		return available
	end
	if storage.mode == "session" then return math.huge end
	local ok, available = pcall(function()
		local service = game:GetService("DataStoreService")
		local requestType = if kind == "read" then Enum.DataStoreRequestType.StandardRead else Enum.DataStoreRequestType.StandardWrite
		return service:GetRequestBudgetForRequestType(requestType)
	end)
	if not ok or type(available) ~= "number" or available ~= available then return nil end
	return available
end

local function serializedBytes(storage: any, value: any): number?
	if storage.serializeAdapter and type(storage.serializeAdapter) == "function" then
		local ok, encoded = pcall(storage.serializeAdapter, value)
		if not ok or type(encoded) ~= "string" then return nil end
		return #encoded
	end
	local ok, encoded = pcall(function() return game:GetService("HttpService"):JSONEncode(value) end)
	if not ok or type(encoded) ~= "string" then return nil end
	return #encoded
end

local function roundedCharge(rawBytes: number): number?
	if type(rawBytes) ~= "number" or rawBytes ~= rawBytes or rawBytes < 0 or rawBytes == math.huge then return nil end
	return math.ceil(rawBytes / BYTE_CHARGE_UNIT) * BYTE_CHARGE_UNIT
end

function Storage:_envelopeCharge(profile: any, lease: any): (number?, number?)
	local raw = serializedBytes(self, {data = profile, lease = lease})
	if raw == nil then return nil, nil end
	return raw, roundedCharge(raw)
end

function Storage:_windowUsage(player: Player): (any, number)
	self.keyUsage = self.keyUsage or {}
	local key = self:_key(player.UserId)
	local usage = self.keyUsage[key] or {samples = {}, total = 0}
	local cutoff = os.clock() - MUTATION_WINDOW_SECONDS
	local kept, total = {}, 0
	for _, sample in ipairs(usage.samples or {}) do
		if type(sample) == "table" and type(sample.at) == "number" and sample.at >= cutoff and type(sample.bytes) == "number" and sample.bytes >= 0 then
			table.insert(kept, sample)
			total += sample.bytes
		end
	end
	usage.samples, usage.total = kept, total
	self.keyUsage[key] = usage
	return usage, total
end

function Storage:_budgetGate(readRequired: number, writeRequired: number): (boolean, string?)
	if self.mode == "session" then return true, nil end
	local readBudget, writeBudget = storageBudget(self, "read"), storageBudget(self, "write")
	if readBudget == nil or writeBudget == nil then return false, "存档服务预算不可用，为保护进度已拒绝操作。" end
	if readBudget < readRequired or writeBudget < writeRequired then return false, "存档服务繁忙，请稍后重试。" end
	return true, nil
end

function Storage:_reserveEnvelopeBytes(player: Player, profile: any, lease: any): boolean
	local _, charged = self:_envelopeCharge(profile, lease)
	if charged == nil then return false end
	return self:_trackWriteBytes(player, charged)
end

local function legacyMapWithinBound(storage: any, profile: any): boolean
	if type(profile) ~= "table" or profile.requestReceipts == nil then return true end
	local serializer = storage.serializeAdapter
	if serializer == nil then
		serializer = function(value: any): string return game:GetService("HttpService"):JSONEncode(value) end
	end
	local ok = MutationProtocol.legacyReceiptStats(profile.requestReceipts, serializer)
	return ok == true
end

function Storage:_canStartMutation(record: any): (boolean, string?)
	if record.mutationBusy then return false, "操作正在处理，请稍后。" end
	local reserve = self.mutationBudgetReserve or {read = 0, write = 0}
	local budgetOk, budgetReason = self:_budgetGate(reserve.read or 0, reserve.write or 0)
	if not budgetOk then return false, budgetReason end
	record.mutationBusy = true
	return true, nil
end

function Storage:_finishMutation(record: any)
	if record then record.mutationBusy = false end
end

function Storage:_trackWriteBytes(player: Player, bytes: number): boolean
	if type(bytes) ~= "number" or bytes < 0 then return false end
	local usage, total = self:_windowUsage(player)
	local limit = self.mutationBytesPerWindow
	if type(limit) ~= "number" or limit < 0 or total + bytes > limit then return false end
	table.insert(usage.samples, {at = os.clock(), bytes = bytes})
	usage.total = total + bytes
	return true
end

function Storage:_preflightEnvelopeBytes(player: Player, profile: any, lease: any, writeKind: string?, phase: string?): (boolean, string?)
	if self.mode == "session" then return true, nil end
	if type(self.mutationBytesPerWindow) ~= "number" or self.mutationBytesPerWindow < 0 then return false, "存档写入预算不可用，为保护进度已拒绝操作。" end
	local raw, rounded = self:_envelopeCharge(profile, lease)
	if raw == nil or rounded == nil then return false, "存档序列化器不可用，为保护进度已拒绝操作。" end
	local deltaReserve = if writeKind == "mutation" or writeKind == "load" then (self.mutationDeltaReserveBytes or 0) else 0
	-- Before Model/migration, reserve the reviewed one-transform growth bound
	-- plus one complete future envelope.  Once the candidate has been built,
	-- its actual complete envelope is known; reserve that actual envelope twice
	-- (the committed mutation and its next autosave/renewal).  The latter is
	-- admission headroom, not a second usage sample or backend charge.
	local primary = if phase == "candidate" then rounded else roundedCharge(raw + deltaReserve)
	if primary == nil then return false, "存档序列化器不可用，为保护进度已拒绝操作。" end
	-- Keep one complete future autosave/renewal envelope in this rolling
	-- window. This is an in-process admission gate, not a backend quota claim.
	local future = if phase == "candidate" and (writeKind == "mutation" or writeKind == "load")
		then rounded
		elseif writeKind == "mutation" or writeKind == "load" then primary
		else 0
	local _, total = self:_windowUsage(player)
	if total + primary + future > self.mutationBytesPerWindow then return false, "存档写入预算已满，请稍后重试。" end
	return true, nil
end

local function clearLoading(storage: any, userId: number, claim: any)
	if storage.loading[userId] == claim then storage.loading[userId] = nil end
end

local function finishLoadFailure(storage: any, player: Player, userId: number, claim: any, leaseToken: string?, reason: string)
	-- A successful lease write is followed by migration/validation in memory.
	-- Release only the token this load acquired; a changed token must be left
	-- alone so this cleanup cannot overwrite another server's live lease.
	if leaseToken then
		pcall(function() storage:_releaseLease(player, leaseToken) end)
	end
	clearLoading(storage, userId, claim)
	return false, nil, reason
end

function Storage:load(player: Player): (boolean, any?, string?)
	local now = os.time()
	local userId = player.UserId
	self.loading = self.loading or {}
	-- Reserve the UserId before any yielding call. This closes the check/yield
	-- gap where two Player objects could both pass the old records check.
	if self.records[userId] then return false,nil,"上次会话仍在保存，请稍后重新加入。" end
	if self.loading[userId] then return false,nil,"存档正在加载，请稍后重新加入。" end
	local claim = {owner = player, cancelled = false}
	self.loading[userId] = claim
	local function fail(reason: string, leaseToken: string?)
		return finishLoadFailure(self, player, userId, claim, leaseToken, reason)
	end
	if self.mode == "session" then
		local created, profile = pcall(self.model.new, now)
		if not created or type(profile) ~= "table" then return fail("存档创建失败，为保护存档无法进入。", nil) end
		local valid, validProfile = pcall(self.model.validate, profile)
		if not valid or not validProfile then return fail("存档创建后校验失败，为保护存档无法进入。", nil) end
		if claim.cancelled or self.loading[userId] ~= claim or self.records[userId] then
			return fail("存档加载已取消，为保护存档无法进入。", nil)
		end
		self.records[userId] = {owner = player, profile = profile, saving = false, closed = false, dirty = true, lost = false, leaseToken = "session", leaseUntil = nil}
		clearLoading(self, userId, claim)
		return true, profile
	end
	if not self.store then return fail("存档服务不可用，已为保护存档拒绝进入。", nil) end
	if self.mode ~= "session" and serializedBytes(self, {}) == nil then return fail("存档序列化器不可用，为保护存档无法进入。", nil) end
	local loadBudgetOk, loadBudgetReason = self:_budgetGate(2, 2)
	if not loadBudgetOk then return fail(loadBudgetReason or "存档服务繁忙，为保护存档无法进入。", nil) end
	local leaseToken = token(self.jobId)
	local loadAttemptCharged = false
	local loadAttemptCharge: number? = nil
	local ok, committed = pcall(function()
		return self.store:UpdateAsync(self:_key(userId), function(old)
			if old == nil then
				local profile = self.model.new(now)
				local lease = {jobId = self.jobId, token = leaseToken, ["until"] = now + LEASE_SECONDS}
				local preflightOk = self:_preflightEnvelopeBytes(player, profile, lease, "load")
				local _, charge = self:_envelopeCharge(profile, lease)
				if not preflightOk or charge == nil then return nil end
				loadAttemptCharge = math.max(loadAttemptCharge or 0, charge)
				return {data = profile, lease = lease}
			end
			if not validEnvelope(self.model, old) then return nil end
			if not legacyMapWithinBound(self, old.data) then return nil end
			local lease = old.lease
			if lease.jobId ~= self.jobId and lease["until"] > now then return nil end
			local nextLease = {jobId = self.jobId, token = leaseToken, ["until"] = now + LEASE_SECONDS}
			local beforeMigrationOk = self:_preflightEnvelopeBytes(player, old.data, nextLease, "load")
			if not beforeMigrationOk then return nil end
			local candidate = clone(old.data)
			if type(self.model.migrate) == "function" then
				local migratedOk, migrated = pcall(self.model.migrate, candidate, now)
				if not migratedOk or migrated == false and candidate.version ~= self.model.ProfileVersion then return nil end
			end
			local candidateValid = false
			local validationOk, valid = pcall(self.model.validate, candidate)
			candidateValid = validationOk and valid == true
			if not candidateValid then return nil end
			local afterMigrationOk = self:_preflightEnvelopeBytes(player, candidate, nextLease, "load", "candidate")
			local _, charge = self:_envelopeCharge(candidate, nextLease)
			if not afterMigrationOk or charge == nil then return nil end
			loadAttemptCharge = math.max(loadAttemptCharge or 0, charge)
			return {data = candidate, lease = nextLease}
		end)
	end)
	if loadAttemptCharge ~= nil then loadAttemptCharged = self:_trackWriteBytes(player, loadAttemptCharge) end
	local envelopeOk, committedValid = false, false
	if ok then envelopeOk, committedValid = pcall(validEnvelope, self.model, committed) end
	if not ok or not envelopeOk or not committedValid or committed.lease.jobId ~= self.jobId or committed.lease.token ~= leaseToken then
		return fail("存档正在被另一台服务器使用、损坏或读取失败。", if loadAttemptCharged then leaseToken else nil)
	end
	if self.mode ~= "session" and not loadAttemptCharged then
		return fail("存档写入预算已满，为保护存档无法进入。", leaseToken)
	end
	if claim.cancelled or self.loading[userId] ~= claim then
		return fail("存档加载已取消，为保护存档无法进入。", leaseToken)
	end
	local cloned, profile = pcall(clone, committed.data)
	if not cloned or type(profile) ~= "table" then return fail("存档读取失败，为保护存档无法进入。", leaseToken) end
	-- Migration was performed on the UpdateAsync candidate above. This second
	-- in-memory check protects the stable session reference without creating a
	-- second write or a replayable side effect.
	local migrated = committed.data.version == self.model.ProfileVersion
	local validMigrated, validProfile = pcall(self.model.validate, profile)
	if not validMigrated or not validProfile then return fail("存档迁移后校验失败，为保护存档无法进入。", leaseToken) end
	if claim.cancelled or self.loading[userId] ~= claim or self.records[userId] then
		return fail("存档加载已取消，为保护存档无法进入。", leaseToken)
	end
	self.records[userId] = {owner = player, profile = profile, saving = false, closed = false, dirty = migrated, lost = false, leaseToken = leaseToken, leaseUntil = committed.lease["until"]}
	clearLoading(self, userId, claim)
	return true, profile
end

function Storage:get(player: Player): any? local r = self:_recordFor(player); return r and r.profile or nil end
function Storage:isSaving(player: Player): boolean local r = self:_recordFor(player); return r ~= nil and r.saving == true end
function Storage:isLost(player: Player): boolean local r = self:_recordFor(player); return r ~= nil and r.lost == true end
function Storage:isHandshakeReady(player: Player): boolean
	local record = self:_recordFor(player)
	if record == nil or record.saving or record.closed or record.closing or record.lost then return false end
	if self.mode == "session" then return true end
	local untilTime = record.leaseUntil
	return type(untilTime) == "number" and untilTime == untilTime and untilTime > os.time() and untilTime < math.huge
end
function Storage:markDirty(player: Player) local r = self:_recordFor(player); if r and not r.closed then r.dirty = true end end

function Storage:_write(player: Player, transform: ((any) -> boolean)?, allowClosing: boolean?, writeKind: string?): (boolean, string?)
	local record = self:_recordFor(player)
	if not record or record.closed or record.lost then return false, "存档会话已关闭。" end
	if record.closing and not allowClosing then return false, "存档正在关闭。" end
	if record.saving then return false, "存档正在写入，请稍后再试。" end
	if record.mutationBusy and writeKind ~= "mutation" then return false, "操作正在处理，请稍后。" end
	local now, leaseToken = os.time(), token(self.jobId)
	local plannedLease = {jobId = self.jobId, token = leaseToken, ["until"] = now + LEASE_SECONDS}
	local preflightOk, preflightReason = self:_preflightEnvelopeBytes(player, record.profile, plannedLease, writeKind)
	if not preflightOk then return false, preflightReason end
	if writeKind == "mutation" then
		local ready, reason = self:_canStartMutation(record)
		if not ready then return false, reason end
	else
		local budgetOk, budgetReason = self:_budgetGate(1, 1)
		if not budgetOk then return false, budgetReason end
	end
	-- Transform exactly once before UpdateAsync: callbacks are allowed to be retried.
	local candidate = clone(record.profile)
	if transform then
		local transformed, accepted = pcall(transform, candidate)
		if not transformed then self:_finishMutation(record); return false, "操作未保存。" end
		if not accepted then self:_finishMutation(record); return false, "操作未保存。" end
	end
	local valid, validCandidate = pcall(self.model.validate, candidate)
	if not valid or not validCandidate then self:_finishMutation(record); return false, "存档数据校验失败。" end
	if self.mode ~= "session" then
		local exactPreflightOk = self:_preflightEnvelopeBytes(player, candidate, plannedLease, writeKind, "candidate")
		if not exactPreflightOk or not self:_reserveEnvelopeBytes(player, candidate, plannedLease) then
			self:_finishMutation(record)
			return false, "存档序列化预算不足，为保护进度已拒绝操作。"
		end
	end
	if self.mode == "session" then
		replaceStable(record.profile, candidate)
		record.dirty = false
		self:_finishMutation(record)
		return true
	end
	if not self.store then self:_finishMutation(record); return false, "存档服务不可用。" end
	record.saving = true
	local ok, committed = pcall(function()
		return self.store:UpdateAsync(self:_key(player.UserId), function(old)
			-- This callback has no observable local side effects and is safe to retry.
			if not validEnvelope(self.model, old) or old.lease.jobId ~= self.jobId or old.lease.token ~= record.leaseToken then return nil end
			return {data = candidate, lease = plannedLease}
		end)
	end)
	record.saving = false
	self:_finishMutation(record)
	local envelopeOk, committedValid = false, false
	if ok then envelopeOk, committedValid = pcall(validEnvelope, self.model, committed) end
	if not ok or not envelopeOk or not committedValid or committed.lease.jobId ~= self.jobId or committed.lease.token ~= leaseToken then
		record.lost, record.closed = true, true
		return false, "存档租约已失效或保存未确认；已停止本会话以保护存档。"
	end
	-- Keep FishingService's profile reference stable after a successful write.
	replaceStable(record.profile, committed.data)
	record.leaseToken = leaseToken
	record.leaseUntil = committed.lease["until"]
	record.dirty = false
	return true
end

function Storage:save(player: Player, allowClosing: boolean?): (boolean, string?)
	local record = self:_recordFor(player)
	if not record then return true end
	-- A clean live profile still needs to renew its lease before it expires.
	if not record.dirty and self.mode == "session" then return true end
	return self:_write(player, nil, allowClosing, "autosave")
end

function Storage:transaction(player: Player, transform: (any) -> boolean, writeKind: string?): (boolean, string?)
	local record = self:_recordFor(player)
	if not record or record.lost then return false, "未加载存档。" end
	return self:_write(player, transform, false, writeKind)
end

function Storage:_release(player: Player, record: any)
	if self.mode == "session" or not self.store or record.lost or type(record.leaseToken) ~= "string" then return end
	for _ = 1, 2 do
		local now, releaseToken = os.time(), token(self.jobId)
		local releaseLease = {jobId = self.jobId, token = releaseToken, ["until"] = now - 1}
		local budgetOk = self:_budgetGate(1, 1)
		local preflightOk = true
		if budgetOk and record.profile then
			preflightOk = self:_preflightEnvelopeBytes(player, record.profile, releaseLease, "release")
		end
		if not budgetOk or not preflightOk then
			retryWait(0.25)
			continue
		end
		local releaseAttemptCharge: number? = nil
		if record.profile then
			local _, plannedCharge = self:_envelopeCharge(record.profile, releaseLease)
			releaseAttemptCharge = plannedCharge
		end
		local ok, committed = pcall(function()
			return self.store:UpdateAsync(self:_key(player.UserId), function(old)
				if not validEnvelope(self.model, old) or old.lease.jobId ~= self.jobId or old.lease.token ~= record.leaseToken then return nil end
				local admissionOk = self:_preflightEnvelopeBytes(player, old.data, releaseLease, "release")
				if not admissionOk then return nil end
				local _, charge = self:_envelopeCharge(old.data, releaseLease)
				if charge == nil then return nil end
				releaseAttemptCharge = math.max(releaseAttemptCharge or 0, charge)
				return {data = old.data, lease = releaseLease}
			end)
		end)
		local charged = releaseAttemptCharge == nil or self:_trackWriteBytes(player, releaseAttemptCharge)
		local envelopeOk, committedValid = false, false
		if ok then envelopeOk, committedValid = pcall(validEnvelope, self.model, committed) end
		if charged and ok and envelopeOk and committedValid and committed.lease.token == releaseToken then return end
		retryWait(0.25)
	end
	if warn then warn("Fishing Storage: failed to release lease for " .. tostring(player.UserId)) end
end

function Storage:_releaseLease(player: Player, leaseToken: string)
	self:_release(player, {leaseToken = leaseToken, lost = false, profile = nil})
end

function Storage:_finishClose(player: Player, record: any)
	if self.records[player.UserId] ~= record or record.owner ~= player then return true end
	if record.saving then return false end
	if not record.lost then self:save(player, true) end -- final save / clean lease renewal
	if record.saving then return false end
	self:_release(player, record)
	record.closed = true
	if self.records[player.UserId] == record then self.records[player.UserId] = nil end
	return true
end

function Storage:close(player: Player, finished: (() -> ())?)
	local userId = player.UserId
	local record = self.records[userId]
	if record and record.owner ~= player then
		if finished then finished() end
		return
	end
	if not record then
		local claim = self.loading and self.loading[userId]
		if claim and claim.owner == player then claim.cancelled = true end
		if finished then finished() end
		return
	end
	if record.closing then
		if finished then finished() end
		return
	end
	local function done() if finished then finished() end end
	record.closing = true
	local deadline = os.clock() + 8
	while record.saving and os.clock() < deadline do task.wait() end
	if self:_finishClose(player, record) then
		done()
		return
	end
	-- Do not drop the record after an in-flight write. The continuation performs the
	-- final save/release once Roblox returns, while gameplay is already detached.
	warn("Fishing Storage: waiting for in-flight save during close for " .. tostring(player.UserId))
	task.spawn(function()
		while record.saving do task.wait() end
		self:_finishClose(player, record)
		done()
	end)
end

return Storage
