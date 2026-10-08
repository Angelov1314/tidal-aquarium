--!strict
-- All authority lives here: clients request intent, while this service derives zone,
-- timing, capacity and randomness on the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local shared = ReplicatedStorage:WaitForChild("FishingShared")
local Config = require(shared:WaitForChild("Config"))
local Model = require(shared:WaitForChild("Model"))
local CatchFeedback = require(shared:WaitForChild("CatchFeedback"))
local IncomePreviewRequest = require(shared:WaitForChild("IncomePreviewRequest"))
local RequestValidation = require(shared:WaitForChild("RequestValidation"))
local Storage = require(script.Parent.Storage)
local Monetization = require(script.Parent.Monetization)
local World = require(script.Parent.World)
-- Sailing owns the boat model and seat weld. Travel/aquarium pivots must release
-- it first so a legacy convenience teleport cannot carry a stale SeatWeld.
local BoatService = require(script.Parent:WaitForChild("BoatService"))
local NPCService = require(script.Parent:WaitForChild("NPCService"))
local IncomePreviewGate = require(script.Parent:WaitForChild("IncomePreviewGate"))
local IncomePreviewQuery = require(script.Parent:WaitForChild("IncomePreviewQuery"))
local MutationProtocol = require(shared:WaitForChild("MutationProtocol"))
local HandshakeFence = require(shared:WaitForChild("HandshakeFence"))

local FishingService = {}

local storage = Storage.new(Model)
local records: {[Player]: any} = {}
local plots: {[number]: Player} = {}
local remotes: Folder? = nil
local requestRemote: RemoteFunction? = nil
local stateRemote: RemoteEvent? = nil
local monetization: any = nil
local started = false
local pendingCloses = 0
local sessionSequence = 0

local CORE_ACTIONS = {
	place = true, remove = true, sell = true, sellDuplicates = true, lock = true,
	merge = true, upgrade = true, unlock = true, contract = true,
	exchange = true, useItem = true, showcase = true, hideFish = true,
}

local function mutationIntentMessage(action: string, reason: string?): string
	if action == "lock" then
		if reason == "lock-state-required" then return "锁定请求缺少明确状态，请刷新后重试。" end
		if reason == "lock-state-type" then return "锁定状态无效。" end
		return "锁定请求格式无效。"
	end
	if action == "upgrade" then
		if reason == "upgrade-intent-required" then return "升级快照已过期，请刷新后重试。" end
		if reason == "upgrade-intent-invalid" then return "升级确认无效。" end
		return "升级请求格式无效。"
	end
	return "请求意图无效。"
end

local function mutationProtocolMessage(reason: string?): string
	if reason == "epoch" then return "客户端会话已更新，请重新连接。" end
	if reason == "sequence-gap" then return "操作顺序已变化，请刷新后重试。" end
	if reason == "replay" then return "请求已处理。" end
	if reason == "budget" then return "存档服务繁忙，请稍后重试。" end
	return "请求协议无效。"
end

local function now(): number return os.time() end

local function newOpaqueEpoch(): string
	local ok, value = pcall(function() return HttpService:GenerateGUID(false) end)
	if ok and type(value) == "string" and #value > 0 then return value end
	return tostring(os.clock()) .. ":" .. tostring(math.random(1, 2147483647))
end

local function getRecord(player: Player): any?
	return records[player]
end

-- Saved progression (`state.zone`) is the highest unlocked water.  The UI also
-- needs the player's actual live fishing location, which must come from the
-- world and must not mutate the profile.  Keep this helper above snapshot so
-- every snapshot path (including travel and aquarium transitions) uses the
-- same safe projection.
local function currentZone(player: Player): number?
	local ok, zone = pcall(function() return World.getZone(player) end)
	if ok and type(zone) == "number" then return zone end
	return nil
end

local function incomePreviewExpiry(profile: any, at: number): number?
	local expiry: number? = nil
	local function consider(value: any)
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or value <= at then return end
		if expiry == nil or value < expiry then expiry = value end
	end
	consider(profile.boostUntil)
	local activeCoins = profile.activeBoosts and profile.activeBoosts.coins
	if type(activeCoins) == "table" then consider(activeCoins.untilTime) end
	return expiry
end

local function snapshot(player: Player, notice: string?, advanceSequence: boolean?): any?
	local record = getRecord(player)
	if not record or not record.profile then return nil end
	if advanceSequence ~= false then record.snapshotSeq = (record.snapshotSeq or 0) + 1 end
	local at = now()
	local state = Model.snapshot(record.profile, at)
	state.currentZone = currentZone(player)
	local secondsLeft = 0
	if record.fishing then secondsLeft = math.max(0, record.endsAt - at) end
	state.fishing = record.fishing == true
	state.secondsLeft = secondsLeft
	state.storageMode = storage:getMode()
	state.notice = notice
	state.plotIndex = record.plotIndex
	state.incomeStateVersion = record.incomeStateVersion or 0
	state.incomePreviewExpiresAt = incomePreviewExpiry(record.profile, at)
	state.mutationProtocol = MutationProtocol.ProtocolVersion
	state.stateEpoch = record.stateEpoch
	state.handshakeFence = record.handshakeFence
	state.snapshotSeq = record.snapshotSeq or 0
	state.mutationWatermarks = Model.mutationWatermarks(record.profile)
	local paid = false
	if monetization then paid = select(1, monetization:availableFor(player)) end
	state.paidAvailable = paid
	return state
end

local function bumpIncomeState(record: any)
	record.incomeStateVersion = (record.incomeStateVersion or 0) + 1
end

local function incomePreviewResponse(record: any, at: number, requestKind: string): any
	return {
		ok = true,
		kind = "incomePreview",
		requestKind = requestKind,
		stateVersion = record.incomeStateVersion or 0,
		calculatedAt = at,
		expiresAt = incomePreviewExpiry(record.profile, at),
	}
end

local function incomePreviewError(record: any, requestKind: any, reason: string, calculatedAt: number?): any
	local at = calculatedAt or now()
	return {
		ok = false,
		kind = "incomePreview",
		requestKind = IncomePreviewGate.requestKind(requestKind),
		stateVersion = record.incomeStateVersion or 0,
		calculatedAt = at,
		expiresAt = incomePreviewExpiry(record.profile, at),
		reason = reason,
	}
end

local function handleIncomePreview(player: Player, payload: any): any
	local record = getRecord(player)
	if not record then return {ok = false, kind = "incomePreview", reason = "存档尚未就绪。"} end
	local valid, reason = IncomePreviewRequest.validate(payload)
	if not valid then return incomePreviewError(record, type(payload) == "table" and payload.kind or nil, reason or "预览请求无效") end
	local at = now()
	local response = incomePreviewResponse(record, at, payload.kind)
	-- The query adapter owns the exact Model call count and keeps this Remote
	-- handler read-only. It accepts the live record so saving-related fields
	-- remain available without exposing or mutating them.
	local queryOk, bodyOrReason = IncomePreviewQuery.run(record, at, payload, Model)
	if not queryOk then return incomePreviewError(record, payload.kind, tostring(bodyOrReason or "预览失败"), at) end
	for key, value in pairs(bodyOrReason) do response[key] = value end
	return response
end

local function push(player: Player, notice: string?)
	local state = snapshot(player, notice)
	if not state then return end
	if stateRemote then stateRemote:FireClient(player, state) end
	local updated, updateResult = pcall(function() return World.update(player, state) end)
	if not updated or updateResult == false then warn("Fishing World.update failed for " .. player.Name) end
	local record = getRecord(player)
	if record then record.lastPush = now() end
end

-- Audio is a separate, ephemeral state event.  It must never be folded into a
-- snapshot: clients also receive snapshots as RemoteFunction return values.
local function pushAudio(player: Player, cue: string)
	if stateRemote then stateRemote:FireClient(player, {kind = "audio", cue = cue}) end
end

local function actionCue(action: string): string?
	if action == "merge" then return "Merge" end
	if action == "sell" or action == "sellDuplicates" then return "Coin" end
	if action == "place" then return "Place" end
	if action == "exchange" or action == "useItem" then return "BagCollect" end
	return nil
end

local function stopFishing(player: Player, notice: string?)
	local record = getRecord(player)
	if not record or not record.fishing then return end
	record.fishing = false
	record.endsAt = 0
	push(player, notice)
end

local function pushCatch(player: Player, record: any, result: any, zone: number)
	if not stateRemote or not record or type(result) ~= "table" or type(result.fish) ~= "table" then return end
	record.batchSequence = (record.batchSequence or 0) + 1
	local event = {
		kind = "catch",
		batchId = tostring(record.sessionId) .. ":" .. tostring(record.batchSequence),
		count = #result.fish,
		zone = zone,
		fish = CatchFeedback.representatives(result.fish, Config.SpeciesById, CatchFeedback.MaxRepresentatives),
	}
	stateRemote:FireClient(player, event)
end

local function beginRound(player: Player): (boolean, string)
	local record = getRecord(player)
	if not record then return false, "存档尚未就绪。" end
	local zone = currentZone(player)
	if not zone or zone > record.profile.zone then return false, "请站在已解锁水域的钓鱼岸边。" end
	local bagCount = 0
	for _, fish in ipairs(record.profile.fish) do if not fish.placed then bagCount += 1 end end
	if bagCount + record.profile.hooks > record.profile.bagCapacity then return false, "背包容量不足，已暂停垂钓。" end
	record.fishing = true
	record.zone = zone
	record.endsAt = now() + Config.RoundSeconds
	push(player)
	return true, "开始垂钓。"
end

local function settle(profile: any)
	Model.settle(profile, now(), false)
end

function FishingService.getProfile(player: Player): any?
	-- This is intentionally not exposed over a RemoteFunction.
	if not game:GetService("RunService"):IsStudio() then return nil end
	local record = getRecord(player)
	return record and record.profile or nil
end

function FishingService.getProtocolState(player: Player): any?
	-- Read-only isolated QA seam. It does not install an epoch or mutate a
	-- session; production callers cannot use it outside Studio.
	if not game:GetService("RunService"):IsStudio() then return nil end
	local record = getRecord(player)
	if not record then return nil end
	return {stateEpoch = record.stateEpoch, handshakeFence = record.handshakeFence, mutationWatermarks = Model.mutationWatermarks(record.profile)}
end

function FishingService.handle(player: Player, action: any, payload: any): any
	local record = getRecord(player)
	if not record then return {ok = false, message = "存档尚未就绪。"} end
	if storage:isLost(player) then
		stopFishing(player)
		player:Kick("存档租约已失效，为保护进度已停止本会话。")
		return {ok = false, message = "存档租约已失效。"}
	end
	if type(action) ~= "string" or #action > 32 then return {ok = false, message = "请求格式无效。"} end
	-- Check mutation intent before the generic walker so malformed lock/upgrade
	-- fields (including NaN/Inf) receive an action-specific refusal and current
	-- state instead of falling through as an anonymous shape error.
	local earlyIntentOk, earlyIntentReason = true, nil
	if CORE_ACTIONS[action] then earlyIntentOk, earlyIntentReason = RequestValidation.validateMutationIntent(action, payload) end
	if not earlyIntentOk then return {ok = false, message = mutationIntentMessage(action, earlyIntentReason), state = snapshot(player)} end
	if not RequestValidation.validate(payload) then return {ok = false, message = "请求格式无效。", state = snapshot(player)} end
	-- Read-only income previews use their own exact protocol and never enter
	-- storage/save or mutation handling below.
	if action == "incomePreview" then return handleIncomePreview(player, payload) end
	if action == "snapshot" then
		if type(payload) == "table" and payload.prepareHandshake == true then
			if not storage:isHandshakeReady(player) or record.busy then return {ok = false, message = "存档正在写入，请稍后重试。"} end
			local prepared, preparation = HandshakeFence.prepare(record)
			if not prepared then return {ok = false, message = "存档正在写入，请稍后重试。"} end
			return {ok = true, prepareHandshake = true, message = "", stateEpoch = preparation.stateEpoch, handshakeFence = preparation.handshakeFence}
		end
		if type(payload) == "table" and payload.handshake == true then
			if not storage:isHandshakeReady(player) or record.busy then return {ok = false, message = "存档正在写入，请稍后重试。"} end
			local committed, handshakeOrReason = HandshakeFence.commit(record, payload, newOpaqueEpoch)
			if not committed then return {ok = false, message = handshakeOrReason == "stale-fence" and "会话握手已过期，请重新准备。" or "会话握手无效。"} end
			return {ok = true, handshake = true, message = "", state = snapshot(player), stateEpoch = handshakeOrReason.stateEpoch, handshakeFence = handshakeOrReason.handshakeFence}
		end
		if record.busy or storage:isSaving(player) then return {ok = false, message = "存档正在写入，请稍后重试。"} end
		if type(payload) ~= "table" or payload.stateEpoch ~= record.stateEpoch then return {ok = false, message = "客户端会话已更新，请重新握手。"} end
		return {ok = true, message = "", state = snapshot(player)}
	end
	if MutationProtocol.isLane(action) then
		local envelopeOk, envelopeReason, decision = RequestValidation.validateMutationEnvelope(action, payload, record.stateEpoch, Model.mutationWatermarks(record.profile))
		if decision == "replay" then return {ok = true, replayed = true, message = mutationProtocolMessage("replay"), state = snapshot(player)} end
		if not envelopeOk then return {ok = false, message = mutationProtocolMessage(envelopeReason), state = snapshot(player)} end
	end
	if storage:isSaving(player) then return {ok = false, message = "存档正在写入，请稍后重试。"} end
	if action == "toggleFishing" then
		if record.fishing then
			stopFishing(player, "已停止垂钓。")
			return {ok = true, message = "已停止垂钓。", state = snapshot(player)}
		end
		local ok, message = beginRound(player)
		if ok then pushAudio(player, "Cast") end
		return {ok = ok, message = message, state = snapshot(player, ok and nil or message)}
	end
	if action == "travel" then
		if type(payload) ~= "table" or type(payload.zone) ~= "number" or payload.zone % 1 ~= 0 then return {ok = false, message = "水域参数无效。"} end
		local zone = payload.zone
		if zone < 1 or zone > #Config.Zones or zone > record.profile.zone then return {ok = false, message = "该水域尚未解锁。"} end
		stopFishing(player)
		BoatService.release(player, "travel")
		pcall(function() World.travel(player, zone) end)
		push(player, "已前往水域。")
		return {ok = true, message = "已前往水域。", state = snapshot(player)}
	end
	if action == "visitAquarium" then
		stopFishing(player)
		BoatService.release(player, "visitAquarium")
		local ok, moved = pcall(function() return World.visitAquarium(player) end)
		if not ok or not moved then return {ok=false,message="水族馆暂不可用。",state=snapshot(player)} end
		push(player,"欢迎回到你的水族馆。")
		return {ok=true,message="已前往个人水族馆。",state=snapshot(player)}
	end
	if action == "purchasePass" or action == "purchaseBoost" then
		local ok, message
		if action == "purchasePass" then
			ok, message = monetization:promptPass(player)
		else
			ok, message = monetization:promptBoost(player)
		end
		return {ok = ok, message = message, state = snapshot(player, message)}
	end
	-- Catch is omitted on purpose.  Only the scheduler below can call Model.command("catch").
	if not CORE_ACTIONS[action] then return {ok = false, message = "不支持的操作。"} end
	record.busy = true
	local oldState = snapshot(player)
	local outcome: any = nil
	local committed, transactionReason = true, nil
	if MutationProtocol.isLane(action) then
		committed, transactionReason = storage:transaction(player, function(candidate)
			local decision, decisionReason = Model.mutationDecision(candidate, action, payload, record.stateEpoch)
			if decision ~= "accept" then
				outcome = {ok = false, message = mutationProtocolMessage(decisionReason)}
				return false
			end
			local commandOk, commandResult = pcall(function()
				return Model.command(candidate, action, payload, now(), math.random, {source = "remote"})
			end)
			if not commandOk or type(commandResult) ~= "table" then
				outcome = {ok = false, message = "操作未完成。"}
				return false
			end
			outcome = commandResult
			if not outcome.ok then return false end
			if not Model.advanceMutationWatermark(candidate, action, payload.operationSeq) then
				outcome = {ok = false, message = "操作顺序已变化，请刷新后重试。"}
				return false
			end
			return true
		end, "mutation")
	else
		local commandOk, commandResult = pcall(function()
			return Model.command(record.profile, action, payload, now(), math.random, {source = "remote"})
		end)
		if commandOk then outcome = commandResult end
	end
	record.busy = false
	if type(outcome) ~= "table" then
		return {ok = false, message = "操作未完成。", state = oldState}
	end
	if MutationProtocol.isLane(action) and not committed then
		if outcome.ok == true then
			return {ok = false, mutationStatus = "unknown", message = transactionReason or "存档保存未确认。", state = oldState}
		end
		return {ok = false, message = outcome.message or transactionReason or "操作未完成。", state = snapshot(player)}
	end
	if outcome.ok then
		-- Stop the round only after the domain command has accepted the fish. A
		-- rejected/forged ID must leave the active fishing session untouched.
		bumpIncomeState(record)
		if action == "showcase" and record.fishing then stopFishing(player, "已停止垂钓，准备展示鱼。") end
		if not MutationProtocol.isLane(action) then storage:markDirty(player) end
		push(player, outcome.message)
		local cue = actionCue(action)
		if cue then pushAudio(player, cue) end
	end
	return {ok = outcome.ok == true, message = outcome.message or "", fish = outcome.fish, state = snapshot(player, outcome.ok and nil or outcome.message)}
end

local function onRequest(player: Player, action: any, payload: any): any
	local record = getRecord(player)
	if not record then return {ok = false, message = "正在加载存档。"} end
	if action == "incomePreview" then
		if not IncomePreviewGate.allow(record, os.clock(), 0.15) then
			return incomePreviewError(record, type(payload) == "table" and payload.kind or nil, "预览请求过快，请稍后。")
		end
		return FishingService.handle(player, action, payload)
	end
	local t = os.clock()
	if record.busy or (record.lastRequest and t - record.lastRequest < 0.15) then return {ok = false, message = "操作过快，请稍后。"} end
	record.lastRequest = t
	return FishingService.handle(player, action, payload)
end

local function assignPlot(player: Player): number?
	for index = 1, 8 do
		if not plots[index] then plots[index] = player return index end
	end
	return nil
end

local function onAdded(player: Player)
	local index = assignPlot(player)
	if not index then player:Kick("本服务器的 8 个私人水族馆席位已满，请加入其他服务器。") return end
	local ok, profile, reason = storage:load(player)
	if not ok then
		plots[index] = nil
		player:Kick(reason or "存档读取失败，为保护存档无法进入。")
		return
	end
	-- PlayerRemoving may have fired while DataStore load yielded. Release the just
	-- acquired lease and plot instead of creating a ghost session.
	if player.Parent ~= Players then
		plots[index] = nil
		storage:close(player)
		return
	end
	-- Verify pass ownership before calculating the offline segment. This deliberately
	-- avoids an online settlement until after the offline calculation is complete.
	monetization:refreshOwnership(player, profile, false)
	if player.Parent ~= Players then
		plots[index]=nil
		storage:close(player)
		return
	end
	local settled = Model.settle(profile, now(), true)
	if not settled.ok then
		plots[index] = nil
		storage:close(player)
		player:Kick("离线收益结算失败，为保护存档无法进入。")
		return
	end
	storage:markDirty(player)
	sessionSequence += 1
	records[player] = {
		profile = profile,
		plotIndex = index,
		fishing = false,
		endsAt = 0,
		lastPush = 0,
		busy = false,
		sessionId = tostring(player.UserId) .. "-" .. tostring(sessionSequence),
		batchSequence = 0,
		incomeStateVersion = 0,
		incomePreviewLastRequest = nil,
		clientSessionNonce = nil,
		stateEpoch = newOpaqueEpoch(),
		handshakeFence = 0,
		snapshotSeq = 0,
	}
	local assigned, worldAssigned = pcall(function() return World.assign(player, index) end)
	if not assigned or worldAssigned == false then warn("Fishing World.assign failed for " .. player.Name) end
	push(player, storage:getMode() == "session" and "Studio 会话存档：退出后不会保留。" or nil)
end

local function onRemoving(player: Player)
	BoatService.release(player, "playerRemoving")
	local record = records[player]
	if not record then return end
	pendingCloses += 1
	stopFishing(player)
	pcall(function() World.remove(player) end)
	plots[record.plotIndex] = nil
	records[player] = nil
	storage:close(player, function() pendingCloses -= 1 end)
end

local function tick()
	while started do
		task.wait(1)
		for player, record in pairs(records) do
			-- A save copies the profile before UpdateAsync.  Do not let a timed catch or
			-- settlement mutate it during that write, otherwise a successful old copy
			-- could replace newer state when the write finishes.
			if storage:isLost(player) then
				stopFishing(player)
				player:Kick("存档租约已失效，为保护进度已停止本会话。")
				continue
			end
				if storage:isSaving(player) then continue end
				if record.busy then continue end
			local profile = record.profile
			if record.fishing then
				local zone = currentZone(player)
				if zone ~= record.zone or zone == nil or zone > profile.zone then
					stopFishing(player, "离开钓鱼区域，已停止垂钓。")
				elseif now() >= record.endsAt then
					local ok, result = pcall(function() return Model.command(profile, "catch", {zone = zone}, now(), math.random) end)
					if ok and type(result) == "table" and result.ok then
						bumpIncomeState(record)
						storage:markDirty(player)
						-- The normal snapshot remains authoritative.  Catch celebration is
						-- a separate bounded event and never replays from inventory length.
						push(player)
						pushCatch(player, record, result, zone)
						local startedRound, reason = beginRound(player)
						if not startedRound then stopFishing(player, reason) end
					else
						stopFishing(player, (type(result) == "table" and result.message) or "无法开始下一轮垂钓。")
					end
				elseif now() ~= record.lastPush then
					-- A countdown must not retransmit up to 3,000 inventory records.
					if stateRemote then stateRemote:FireClient(player,{kind="timer",secondsLeft=math.max(0,record.endsAt-now())}) end
					record.lastPush=now()
				end
			end
			if now() - (record.lastSettle or 0) >= 15 then
				settle(profile)
				record.lastSettle = now()
				storage:markDirty(player)
				push(player)
			end
			if now() - (record.lastSave or 0) >= 60 then
				record.lastSave = now()
				task.spawn(function() storage:save(player) end)
			end
		end
	end
end

function FishingService.start()
	if started then return end
	started = true
	World.build()
	-- NPCService is fail-closed until the imported cartoon rig and authored
	-- animations are present; keep remotes/player startup independent from its
	-- bounded Studio animation-readiness wait.
	task.spawn(function()
		local ok, err = pcall(NPCService.start)
		if not ok then
			NPCService.stop()
			warn("NPCService startup failed: " .. tostring(err))
		end
	end)
	remotes = ReplicatedStorage:FindFirstChild("FishingRemotes") :: Folder?
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "FishingRemotes"
		remotes.Parent = ReplicatedStorage
	end
	requestRemote = remotes:FindFirstChild("Request") :: RemoteFunction?
	if not requestRemote then requestRemote = Instance.new("RemoteFunction"); requestRemote.Name = "Request"; requestRemote.Parent = remotes end
	stateRemote = remotes:FindFirstChild("State") :: RemoteEvent?
	if not stateRemote then stateRemote = Instance.new("RemoteEvent"); stateRemote.Name = "State"; stateRemote.Parent = remotes end
	monetization = Monetization.new(Config, Model, storage, function(player: Player, notice: string?)
		local record = getRecord(player)
		if record then bumpIncomeState(record) end
		push(player, notice)
	end)
	monetization:bind()
	-- Boarding offshore makes World.getZone return nil on its next server tick;
	-- stop immediately as well so no final fishing round can overlap summon.
	BoatService.setBoardingCallback(function(player, aboard, reason)
		if aboard then stopFishing(player, "已登船，垂钓已暂停。") end
	end)
	requestRemote.OnServerInvoke = onRequest
	Players.PlayerAdded:Connect(onAdded)
	Players.PlayerRemoving:Connect(onRemoving)
	game:BindToClose(function()
		NPCService.stop()
		local closing = Players:GetPlayers()
		for _, player in ipairs(closing) do task.spawn(onRemoving, player) end
		local deadline = os.clock() + 10
		while (next(records) ~= nil or pendingCloses > 0) and os.clock() < deadline do task.wait() end
	end)
	for _, player in ipairs(Players:GetPlayers()) do task.spawn(onAdded, player) end
	task.spawn(tick)
end

return FishingService
