--!strict
-- Read-only income preview lifecycle.  It has no Roblox dependencies beyond
-- resolving the shared protocol when loaded by the real client.  A transport
-- remains busy until its InvokeServer call returns, even when its logical
-- selection has been invalidated, so timeout/version changes never create a
-- second concurrent request.
local Request = if script
	then require(game:GetService("ReplicatedStorage"):WaitForChild("FishingShared"):WaitForChild("IncomePreviewRequest"))
	else require("../shared/IncomePreviewRequest")

local IncomePreviewController = {}

export type State = {
	status: string,
	key: string,
	generation: number,
	version: any?,
	response: any?,
	reason: string?,
}

type Options = {
	invoke: (payload: any) -> any,
	onChanged: (() -> ())?,
	schedule: ((fn: () -> ()) -> ())?,
	delay: ((fn: () -> (), seconds: number) -> ())?,
	clock: (() -> number)?,
	timeoutSeconds: number?,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function cloneState(source: State): State
	return {
		status = source.status,
		key = source.key,
		generation = source.generation,
		version = source.version,
		response = source.response,
		reason = source.reason,
	}
end

local function versionOf(snapshot: any): any
	return snapshot and snapshot.incomeStateVersion or nil
end

local function validVersion(version: any): boolean
	return finite(version) and version >= 0 and version % 1 == 0
end

function IncomePreviewController.new(options: Options)
	local controller = {} :: any
	local schedule = options.schedule or function(fn: () -> ()) task.spawn(fn) end
	local delay = options.delay or function(fn: () -> (), seconds: number) task.delay(seconds, fn) end
	local clock = options.clock or os.clock
	local timeoutSeconds = math.max(0.25, options.timeoutSeconds or 5)
	local generation = 0
	local currentSnapshot: any = nil
	local active: any = nil -- logical request still eligible to update state
	local pending: any = nil -- newest selection waiting behind a real transport
	local transportBusy = false
	local transportRequest: any = nil
	local expiresAtMonotonic: number? = nil
	local lastPayload: any = nil
	local state: State = {status = "idle", key = "", generation = 0, version = nil, response = nil, reason = nil}

	local function changed()
		if options.onChanged then options.onChanged() end
	end

	local function setState(nextState: State, notify: boolean?)
		state = nextState
		if nextState.status ~= "ready" then expiresAtMonotonic = nil end
		if notify ~= false then changed() end
	end

	local function clearState(reason: string?, notify: boolean?)
		setState({status = "idle", key = "", generation = generation, version = nil, response = nil, reason = reason}, notify)
	end

	local function setError(key: string, requestGeneration: number, version: any, reason: string, notify: boolean?)
		setState({status = "error", key = key, generation = requestGeneration, version = version, response = nil, reason = reason}, notify)
	end

	local function currentVersionMatches(version: any): boolean
		return versionOf(currentSnapshot) == version
	end

	local function snapshotExpiryMatches(response: any, snapshot: any): boolean
		local expiry = snapshot and snapshot.incomePreviewExpiresAt or nil
		return (expiry == nil or finite(expiry)) and expiry == response.expiresAt
	end

	local function responseIsValid(response: any, request: any): (boolean, string?)
		return Request.validateResponse(response, request.payload, request.version)
	end

	local startPending: any
	local function finishTransport(request: any, callOk: boolean, response: any, failureReason: string?)
		if transportRequest ~= request then return end
		-- The actual remote invocation is complete. Only now may a queued latest
		-- selection start; an invalidated/timed-out request still occupied this
		-- transport until this point.
		transportBusy = false
		transportRequest = nil
		if pending then
			local nextRequest = pending
			pending = nil
			startPending(nextRequest)
			return
		end
		if active ~= request then return end
		active = nil
		if request.generation ~= generation or not currentVersionMatches(request.version) or request.key ~= state.key then
			clearState("收益预览已过期，请刷新", true)
			return
		end
		if not callOk then
			setError(request.key, generation, request.version, failureReason or "收益预览网络失败，请重试")
			return
		end
		local responseValid, responseReason = responseIsValid(response, request)
		if not responseValid then
			setError(request.key, generation, request.version, "收益预览响应无效：" .. tostring(responseReason or "请刷新"))
			return
		end
		-- A same-version boost can expire or begin while the remote call is in
		-- flight.  The response must match the newest snapshot before it can
		-- become visible, even if an onSnapshot callback arrived too late to
		-- clear the logical request.
		if not snapshotExpiryMatches(response, currentSnapshot) then
			setError(request.key, generation, request.version, "收益加成已变化，请刷新")
			return
		end
		if response.ok == false then
			setError(request.key, generation, request.version, response.reason or "收益预览被拒绝，请刷新")
			return
		end
		-- `calculatedAt`/`expiresAt` are server epoch values. Establish the
		-- monotonic deadline before notifying render; a synchronous render may
		-- immediately call state() or request() again.
		local expiresAt = response.expiresAt
		expiresAtMonotonic = nil
		local expiryDelay: number? = nil
		if finite(expiresAt) then
			-- calculatedAt is a server epoch while clock() is monotonic on the
			-- client. Convert the TTL, discounting observed transport time, and
			-- never compare the two clock domains directly.
			local ttl = expiresAt - response.calculatedAt
			local monotonicNow = clock()
			local elapsed = math.max(0, monotonicNow - request.startedAt)
			local remaining = ttl - elapsed
			if remaining <= 0 then
				setError(request.key, generation, request.version, "收益加成已变化，请刷新")
				return
			end
			expiresAtMonotonic = monotonicNow + remaining
			expiryDelay = remaining
		end
		setState({status = "ready", key = request.key, generation = generation, version = request.version, response = response, reason = nil})
		if expiryDelay then
			local capturedGeneration = generation
			local capturedKey = request.key
			local capturedVersion = request.version
			delay(function()
				if generation ~= capturedGeneration or state.key ~= capturedKey or state.version ~= capturedVersion or state.status ~= "ready" then return end
				if expiresAtMonotonic and clock() >= expiresAtMonotonic then
					setError(capturedKey, capturedGeneration, capturedVersion, "收益加成已变化，请刷新")
				end
			end, expiryDelay)
		end
	end

	startPending = function(request: any)
		if transportBusy then
			pending = request
			return
		end
		active = request
		transportBusy = true
		transportRequest = request
		request.startedAt = clock()
		-- Request initiation must not synchronously re-enter the page render.
		setState({status = "loading", key = request.key, generation = request.generation, version = request.version, response = nil, reason = nil}, false)
		schedule(function()
			if transportRequest ~= request then return end
			local ok, response = pcall(options.invoke, request.payload)
			finishTransport(request, ok, response, ok and nil or "收益预览网络失败，请重试")
		end)
		local capturedRequest = request
		delay(function()
			if transportRequest ~= capturedRequest or active ~= capturedRequest then return end
			-- Keep transportBusy true. The old InvokeServer call can still return;
			-- a newer request waits in pending until that happens.
			active = nil
			if pending == nil and capturedRequest.generation == generation then
				setError(capturedRequest.key, generation, capturedRequest.version, "收益预览请求超时，请重试")
			end
		end, timeoutSeconds)
	end

	function controller:state(): State
		if state.status == "ready" and expiresAtMonotonic and clock() >= expiresAtMonotonic then
			setError(state.key, state.generation, state.version, "收益加成已变化，请刷新", false)
		end
		return cloneState(state)
	end

	function controller:onSnapshot(nextSnapshot: any)
		local previousVersion = versionOf(currentSnapshot)
		local previousExpiry = currentSnapshot and currentSnapshot.incomePreviewExpiresAt or nil
		local nextExpiry = nextSnapshot and nextSnapshot.incomePreviewExpiresAt or nil
		currentSnapshot = nextSnapshot
		if previousVersion ~= nil and previousVersion ~= versionOf(nextSnapshot) then
			generation += 1
			active = nil
			pending = nil
			clearState("收益状态已变化，请刷新", true)
		elseif previousVersion ~= nil and (nextExpiry == nil or finite(nextExpiry)) and previousExpiry ~= nextExpiry then
			-- The logical selection is no longer safe even though the state version
			-- did not move.  Keep the physical transport occupied so a late
			-- InvokeServer return cannot create a concurrent call.
			generation += 1
			active = nil
			pending = nil
			clearState("收益加成已变化，请刷新", true)
		elseif previousVersion ~= nil and nextExpiry ~= nil and not finite(nextExpiry) then
			generation += 1
			active = nil
			pending = nil
			clearState("收益加成已变化，请刷新", true)
		elseif state.status == "ready" and state.response then
			local previousExpiry = state.response.expiresAt
			-- A same-version snapshot may omit the expiry when a boost ended or
			-- introduce one when it started. Either change invalidates the old
			-- projection; only an unrelated snapshot with the exact same expiry
			-- keeps it stable. Invalid expiry data is never treated as nil.
			local nextExpiryValid = nextExpiry == nil or finite(nextExpiry)
			if not nextExpiryValid or nextExpiry ~= previousExpiry then
				clearState("收益加成已变化，请刷新", true)
			end
		end
	end

	function controller:request(payload: any, nextSnapshot: any): boolean
		local valid, reason = Request.validate(payload)
		if not valid then
			generation += 1
			active = nil
			pending = nil
			lastPayload = nil
			clearState(reason or "预览请求无效")
			return false
		end
		local key = Request.key(payload)
		local version = versionOf(nextSnapshot)
		if not validVersion(version) then
			generation += 1
			active = nil
			pending = nil
			lastPayload = nil
			clearState("收益状态版本待同步")
			return false
		end
		currentSnapshot = nextSnapshot
		if state.status == "ready" and state.response and not snapshotExpiryMatches(state.response, nextSnapshot) then
			clearState("收益加成已变化，请刷新", false)
		end
		if state.status == "ready" and state.key == key and state.response and state.response.stateVersion == version then return true end
		if state.status == "error" and state.key == key and state.generation == generation and state.version == version then return true end
		if active and active.key == key and active.version == version and active.generation == generation then return true end
		if pending and pending.key == key and pending.version == version then return true end
		generation += 1
		local newRequest = {payload = payload, key = key, version = version, generation = generation, startedAt = 0}
		lastPayload = payload
		if transportBusy then
			pending = newRequest
			setState({status = "loading", key = key, generation = generation, version = version, response = nil, reason = nil}, false)
		else
			startPending(newRequest)
		end
		return true
	end

	function controller:requestDetail(nextSnapshot: any, id: string): boolean
		return controller:request(Request.detail(id), nextSnapshot)
	end

	function controller:requestMerge(nextSnapshot: any, ids: {string}, acknowledgedPlacedIds: {string}?): boolean
		return controller:request(Request.merge(ids, acknowledgedPlacedIds), nextSnapshot)
	end

	function controller:retry(payloadOrSnapshot: any, maybeSnapshot: any): boolean
		if state.status ~= "error" then return false end
		local payload = if maybeSnapshot ~= nil then payloadOrSnapshot else lastPayload
		local nextSnapshot = if maybeSnapshot ~= nil then maybeSnapshot else payloadOrSnapshot
		if payload == nil then return false end
		-- Clear only the logical error. If a timed-out InvokeServer is still
		-- physically running, request() queues behind transportBusy rather than
		-- opening a second RemoteFunction call.
		clearState(nil, false)
		return controller:request(payload, nextSnapshot or currentSnapshot)
	end

	function controller:clear(reason: string?, notify: boolean?)
		generation += 1
		active = nil
		pending = nil
		lastPayload = nil
		clearState(reason, notify)
	end

	return controller
end

return IncomePreviewController
