local Controller = require("../src/client/IncomePreviewController")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function fishPreview(allowed: boolean, reason: string?): any
	if not allowed then return {ok = false, allowed = false, reason = reason or "当前不可执行"} end
	return {
		ok = true,
		allowed = true,
		reason = "",
		currentTotalPerHour = 10,
		projectedTotalPerHour = 12,
		deltaPerHour = 2,
		showcaseBeforeId = nil,
		showcaseAfterId = "f1",
		showcaseBonusBefore = 0,
		showcaseBonusAfter = 0.05,
		fishBasePerHour = 2,
		currentFishPerHour = 0,
		projectedFishPerHour = 2,
	}
end

local function detailResponse(version: number, id: string, calculatedAt: number, expiresAt: number?): any
	return {
		ok = true,
		kind = "incomePreview",
		requestKind = "detail",
		stateVersion = version,
		calculatedAt = calculatedAt,
		expiresAt = expiresAt,
		id = id,
		placement = fishPreview(true),
		showcase = fishPreview(true),
	}
end

local function mergeResponse(version: number, calculatedAt: number, expiresAt: number?, allowed: boolean?): any
	local merge = if allowed == false
		then {ok = false, allowed = false, reason = "请确认"}
		else {
			ok = true,
			allowed = true,
			reason = "",
			currentTotalPerHour = 10,
			projectedTotalPerHour = 13,
			deltaPerHour = 3,
			showcaseBeforeId = nil,
			showcaseAfterId = nil,
			showcaseBonusBefore = 0,
			showcaseBonusAfter = 0,
			resultBasePerHour = 3.15,
		}
	return {
		ok = true,
		kind = "incomePreview",
		requestKind = "merge",
		stateVersion = version,
		calculatedAt = calculatedAt,
		expiresAt = expiresAt,
		preview = merge,
	}
end

local queue = {}
local delays = {}
local changes = 0
local now = 10
local invoked = {}
local controller = Controller.new({
	invoke = function(payload)
		table.insert(invoked, payload)
		return table.remove(queue, 1)
	end,
	onChanged = function() changes += 1 end,
	schedule = function(fn) table.insert(queue, fn) end,
	delay = function(fn, seconds) table.insert(delays, {fn = fn, seconds = seconds}) end,
	clock = function() return now end,
	timeoutSeconds = 5,
})

local snapshot = {incomeStateVersion = 1, incomePreviewExpiresAt = 1000000100}
expect(controller:requestDetail(snapshot, "f1"), "detail request accepted")
local loading = controller:state()
expect(loading.status == "loading" and #invoked == 0, "request starts asynchronously")
local response = detailResponse(1, "f1", 1000000010, 1000000100)
table.insert(queue, response)
local invokeTask = table.remove(queue, 1)
invokeTask()
local ready = controller:state()
expect(ready.status == "ready" and ready.response == response, "matching response becomes ready")
local stableChanges = changes
expect(controller:requestDetail(snapshot, "f1") and controller:state().status == "ready", "stable snapshot keeps preview")
expect(changes == stableChanges, "stable preview does not redraw")

local newSnapshot = {incomeStateVersion = 2, incomePreviewExpiresAt = 1000000100}
controller:onSnapshot(newSnapshot)
expect(controller:state().status == "idle", "state version invalidates old preview")
expect(controller:requestMerge(newSnapshot, {"f1", "f2", "f3"}), "merge request accepted after invalidation")
expect(controller:requestMerge(newSnapshot, {"f2", "f3", "f4"}), "latest selection queued")
expect(#invoked == 1, "only one request is in flight")
local oldResponse = mergeResponse(2, 1000000010, 1000000100, true)
table.insert(queue, oldResponse)
local firstInvoke = table.remove(queue, 1)
firstInvoke()
expect(#invoked == 2 and controller:state().status == "loading", "queued selection replaces old generation")
local latestResponse = mergeResponse(2, 1000000010, 1000000100, false)
table.insert(queue, latestResponse)
local secondInvoke = table.remove(queue, 1)
secondInvoke()
expect(controller:state().status == "ready" and controller:state().response == latestResponse, "latest response wins")

controller:clear("关闭")
expect(controller:state().status == "idle", "clear removes pending preview")
expect(changes > 0, "lifecycle changes are observable")

-- A -> B -> A must leave B behind the transport and eventually execute A.
local raceQueue = {}
local raceInvoked = {}
local race = Controller.new({
	invoke = function(payload)
		table.insert(raceInvoked, payload)
		return table.remove(raceQueue, 1)
	end,
	schedule = function(fn) table.insert(raceQueue, fn) end,
	delay = function() end,
	clock = function() return 20 end,
})
local raceSnapshot = {incomeStateVersion = 7}
race:requestDetail(raceSnapshot, "a")
race:requestMerge(raceSnapshot, {"b1", "b2", "b3"})
race:requestDetail(raceSnapshot, "a")
expect(#raceInvoked == 0, "race keeps the first call asynchronous")
local firstRaceInvoke = table.remove(raceQueue, 1)
table.insert(raceQueue, detailResponse(7, "a", 1000000020, nil))
firstRaceInvoke()
expect(#raceInvoked == 1, "race first transport invokes once")
local secondRaceInvoke = table.remove(raceQueue, 1)
table.insert(raceQueue, detailResponse(7, "a", 1000000020, nil))
secondRaceInvoke()
expect(#raceInvoked == 2 and race:state().key == "detail|a", "A to B to A coalesces to the latest A")

-- A timeout invalidates the logical selection but leaves the old transport
-- occupied until its eventual return; a late response cannot restore it.
local timeoutQueue = {}
local timeoutDelays = {}
local timeoutInvoked = 0
local timeoutController = Controller.new({
	invoke = function()
		timeoutInvoked += 1
		return detailResponse(8, "late", 1000000030, nil)
	end,
	schedule = function(fn) table.insert(timeoutQueue, fn) end,
	delay = function(fn, seconds) table.insert(timeoutDelays, {fn = fn, seconds = seconds}) end,
	clock = function() return 30 end,
	timeoutSeconds = 1,
})
timeoutController:requestDetail({incomeStateVersion = 8}, "late")
local timeoutFn = table.remove(timeoutDelays, 1).fn
timeoutFn()
expect(timeoutController:state().status == "error", "timeout becomes a stable error")
local lateInvoke = table.remove(timeoutQueue, 1)
lateInvoke()
expect(timeoutInvoked == 1 and timeoutController:state().status == "error", "late response cannot restore timed-out state")

-- A new selection after timeout waits behind the still-running InvokeServer;
-- the second physical call starts only after the first returns.
local queuedTimeoutSchedule = {}
local queuedTimeoutDelays = {}
local queuedTimeoutResponses = {}
local queuedTimeoutInvoked = {}
local queuedTimeoutController = Controller.new({
	invoke = function(payload)
		table.insert(queuedTimeoutInvoked, payload)
		return table.remove(queuedTimeoutResponses, 1)
	end,
	schedule = function(fn) table.insert(queuedTimeoutSchedule, fn) end,
	delay = function(fn, seconds) table.insert(queuedTimeoutDelays, {fn = fn, seconds = seconds}) end,
	clock = function() return 35 end,
	timeoutSeconds = 1,
})
local queuedSnapshot = {incomeStateVersion = 15}
queuedTimeoutController:requestDetail(queuedSnapshot, "a")
local queuedTimeout = table.remove(queuedTimeoutDelays, 1).fn
queuedTimeout()
queuedTimeoutController:requestDetail(queuedSnapshot, "b")
expect(#queuedTimeoutInvoked == 0 and queuedTimeoutController:state().status == "loading", "queued retry waits for physical timeout transport")
table.insert(queuedTimeoutResponses, detailResponse(15, "a", 1000, nil))
table.remove(queuedTimeoutSchedule, 1)()
expect(#queuedTimeoutInvoked == 1 and queuedTimeoutController:state().status == "loading", "pending selection starts after old return")
table.insert(queuedTimeoutResponses, detailResponse(15, "b", 1000, nil))
table.remove(queuedTimeoutSchedule, 1)()
expect(#queuedTimeoutInvoked == 2 and queuedTimeoutController:state().key == "detail|b", "queued selection completes as latest response")

-- Server epoch values are converted to the injected monotonic clock domain.
local monotonicNow = 40
local expiryQueue = {}
local expiryController = Controller.new({
	invoke = function()
		return detailResponse(9, "expiry", 2000000040, 2000000050)
	end,
	schedule = function(fn) table.insert(expiryQueue, fn) end,
	delay = function() end,
	clock = function() return monotonicNow end,
})
expiryController:requestDetail({incomeStateVersion = 9, incomePreviewExpiresAt = 2000000050}, "expiry")
table.remove(expiryQueue, 1)()
expect(expiryController:state().status == "ready", "epoch response is ready before deadline")
monotonicNow = 51
expect(expiryController:state().status == "error", "epoch expiry uses monotonic deadline")

local errorQueue = {}
local errorInvoked = 0
local errorController = Controller.new({
	invoke = function()
		errorInvoked += 1
		return {ok = false, kind = "incomePreview", stateVersion = 10, calculatedAt = 1000000060, reason = "预览请求过快"}
	end,
	schedule = function(fn) table.insert(errorQueue, fn) end,
	delay = function() end,
	clock = function() return 60 end,
})
local errorSnapshot = {incomeStateVersion = 10}
errorController:requestDetail(errorSnapshot, "error")
table.remove(errorQueue, 1)()
expect(errorController:state().status == "error", "server error is shown")
errorController:requestDetail(errorSnapshot, "error")
expect(errorInvoked == 1, "unchanged server error does not retry during render")

-- An explicit retry clears a stable error and starts a new request; a render
-- loop cannot accidentally retry it just because the snapshot was refreshed.
expect(errorController:retry(errorSnapshot), "explicit retry is accepted")
table.remove(errorQueue, 1)()
expect(errorInvoked == 2 and errorController:state().status == "error", "explicit retry invokes transport")

-- A malformed response is rejected before any partial DTO can reach render.
local invalidQueue = {}
local invalidController = Controller.new({
	invoke = function()
		return {ok = true, kind = "incomePreview", requestKind = "detail", stateVersion = 11, calculatedAt = 100, expiresAt = "bad", id = "malformed", placement = fishPreview(true), showcase = fishPreview(true)}
	end,
	schedule = function(fn) table.insert(invalidQueue, fn) end,
	delay = function() end,
	clock = function() return 70 end,
})
invalidController:requestDetail({incomeStateVersion = 11}, "malformed")
table.remove(invalidQueue, 1)()
expect(invalidController:state().status == "error", "invalid expiry response is rejected")

local function assertControllerRejects(response: any, label: string)
	local pendingQueue = {}
	local candidate = Controller.new({
		invoke = function() return response end,
		schedule = function(fn) table.insert(pendingQueue, fn) end,
		delay = function() end,
		clock = function() return 75 end,
	})
	candidate:requestDetail({incomeStateVersion = 16}, "expected")
	table.remove(pendingQueue, 1)()
	expect(candidate:state().status == "error", label)
end
local mismatchedId = detailResponse(16, "other", 100, nil)
assertControllerRejects(mismatchedId, "wrong detail ID is rejected")
local mismatchedKind = detailResponse(16, "expected", 100, nil)
mismatchedKind.requestKind = "merge"
assertControllerRejects(mismatchedKind, "wrong response request kind is rejected")
local malformedNested = detailResponse(16, "expected", 100, nil)
malformedNested.placement = {ok = true, allowed = true, reason = ""}
assertControllerRejects(malformedNested, "malformed nested DTO is rejected")

-- A same-version snapshot that only changes unrelated state keeps a ready
-- projection. Expiry removal is relevant and invalidates it even without a
-- version bump; a malformed snapshot expiry also cannot be treated as nil.
local stableQueue = {}
local stableController = Controller.new({
	invoke = function() return detailResponse(12, "stable", 500, 600) end,
	schedule = function(fn) table.insert(stableQueue, fn) end,
	delay = function() end,
	clock = function() return 80 end,
})
local stableSnapshot = {incomeStateVersion = 12, incomePreviewExpiresAt = 600, coins = 1}
stableController:requestDetail(stableSnapshot, "stable")
table.remove(stableQueue, 1)()
expect(stableController:state().status == "ready", "stable fixture ready")
stableController:onSnapshot({incomeStateVersion = 12, incomePreviewExpiresAt = 600, coins = 2})
expect(stableController:state().status == "ready", "unrelated same-version snapshot preserves ready")
stableController:onSnapshot({incomeStateVersion = 12, incomePreviewExpiresAt = nil, coins = 2})
expect(stableController:state().status == "idle", "expiry removal invalidates ready")

local directExpiryQueue = {}
local directExpiryController = Controller.new({
	invoke = function() return detailResponse(17, "direct", 700, 800) end,
	schedule = function(fn) table.insert(directExpiryQueue, fn) end,
	delay = function() end,
	clock = function() return 81 end,
})
local directExpirySnapshot = {incomeStateVersion = 17, incomePreviewExpiresAt = 800}
directExpiryController:requestDetail(directExpirySnapshot, "direct")
table.remove(directExpiryQueue, 1)()
expect(directExpiryController:state().status == "ready", "direct expiry fixture ready")
expect(directExpiryController:requestDetail({incomeStateVersion = 17, incomePreviewExpiresAt = nil}, "direct"), "changed expiry can request again")
expect(directExpiryController:state().status == "loading", "direct request expiry change invalidates old value")

-- A same-version expiry transition while the first InvokeServer call is still
-- outstanding invalidates the logical selection but must leave that physical
-- transport occupied.  Cover removal, addition, numeric change, and malformed
-- expiry data; the old response must never become ready.
local function assertInflightExpiryInvalidation(nextExpiry: any, label: string)
	local scheduleQueue = {}
	local responseQueue = {}
	local invokedPayloads = {}
	local candidate = Controller.new({
		invoke = function(payload)
			table.insert(invokedPayloads, payload)
			return table.remove(responseQueue, 1)
		end,
		schedule = function(fn) table.insert(scheduleQueue, fn) end,
		delay = function() end,
		clock = function() return 82 end,
	})
	local before = {incomeStateVersion = 18, incomePreviewExpiresAt = 600}
	candidate:requestDetail(before, "expiry-race")
	expect(candidate:state().status == "loading", label .. ": request starts loading")
	candidate:onSnapshot({incomeStateVersion = 18, incomePreviewExpiresAt = nextExpiry})
	expect(candidate:state().status == "idle", label .. ": expiry transition invalidates in-flight selection")
	table.insert(responseQueue, detailResponse(18, "expiry-race", 500, 600))
	table.remove(scheduleQueue, 1)()
	expect(#invokedPayloads == 1 and candidate:state().status == "idle", label .. ": late old response is dropped")
end

assertInflightExpiryInvalidation(nil, "expiry removal")
assertInflightExpiryInvalidation(700, "expiry addition/change")
assertInflightExpiryInvalidation("malformed", "invalid expiry")

-- The deadline is installed before onChanged re-enters state(). Advancing the
-- monotonic clock from that callback therefore observes an expired preview.
local reentryQueue = {}
local reentryNow = 90
local reentryController
local reentryObserved = ""
reentryController = Controller.new({
	invoke = function() return detailResponse(13, "reentry", 900, 910) end,
	schedule = function(fn) table.insert(reentryQueue, fn) end,
	delay = function() end,
	clock = function() return reentryNow end,
	onChanged = function()
		if reentryController and reentryController:state().status == "ready" then
			reentryNow = 101
			reentryObserved = reentryController:state().status
		end
	end,
})
reentryController:requestDetail({incomeStateVersion = 13, incomePreviewExpiresAt = 910}, "reentry")
table.remove(reentryQueue, 1)()
expect(reentryObserved == "error", "ready notification observes preinstalled deadline")

-- Model the real main.client render path: every state notification renders the
-- selected card, and that render requests the same detail again.  A terminal
-- preview error must therefore be coalesced by the controller itself rather
-- than relying on main to remember an extra guard.
local function mainDetailHarness(snapshot: any, responseFactory: (number, any) -> any, clock: () -> number): any
	local harness: any = {scheduleQueue = {}, delayQueue = {}, invokes = 0, renders = 0, snapshot = snapshot}
	local controller: any
	local function render()
		harness.renders += 1
		controller:state()
		controller:requestDetail(harness.snapshot, "f1")
	end
	controller = Controller.new({
		invoke = function(payload)
			harness.invokes += 1
			return responseFactory(harness.invokes, payload)
		end,
		onChanged = render,
		schedule = function(fn) table.insert(harness.scheduleQueue, fn) end,
		delay = function(fn, seconds) table.insert(harness.delayQueue, {fn = fn, seconds = seconds}) end,
		clock = clock,
		timeoutSeconds = 5,
	})
	harness.controller = controller
	harness.render = render
	harness.processOne = function()
		local callback = table.remove(harness.scheduleQueue, 1)
		if callback then callback() end
	end
	return harness
end

local function rateRejectedResponse(version: number, expiresAt: number?): any
	return {
		ok = false,
		kind = "incomePreview",
		requestKind = "detail",
		stateVersion = version,
		calculatedAt = 100,
		expiresAt = expiresAt,
		reason = "预览请求过快",
		id = "f1",
	}
end

local staleSnapshot = {incomeStateVersion = 21, incomePreviewExpiresAt = 100}
local staleHarness = mainDetailHarness(staleSnapshot, function()
	return detailResponse(21, "f1", 100, nil)
end, function() return 10 end)
staleHarness.controller:requestDetail(staleSnapshot, "f1")
staleHarness:processOne()
expect(staleHarness.invokes == 1 and staleHarness.controller:state().status == "error", "stale successful response becomes stable error")
for _ = 1, 5 do staleHarness:render() end
expect(staleHarness.invokes == 1, "repeated main renders do not retry stale expiry")

local rateHarness = mainDetailHarness(staleSnapshot, function()
	return rateRejectedResponse(21, nil)
end, function() return 10 end)
rateHarness.controller:requestDetail(staleSnapshot, "f1")
rateHarness:processOne()
expect(rateHarness.invokes == 1 and rateHarness.controller:state().status == "error", "stale rate rejection becomes stable error")
for _ = 1, 5 do rateHarness:render() end
expect(rateHarness.invokes == 1, "repeated main renders do not retry stale rate rejection")

local nilExpirySnapshot = {incomeStateVersion = 22}
local nilExpiryHarness = mainDetailHarness(nilExpirySnapshot, function()
	return detailResponse(22, "f1", 100, nil)
end, function() return 10 end)
nilExpiryHarness.controller:requestDetail(nilExpirySnapshot, "f1")
nilExpiryHarness:processOne()
expect(nilExpiryHarness.invokes == 1 and nilExpiryHarness.controller:state().status == "ready", "matching nil expiry becomes ready")
nilExpiryHarness:render()
expect(nilExpiryHarness.invokes == 1, "ready nil expiry is stable across repeated render")

local ttlClock = 10
local ttlHarness = mainDetailHarness({incomeStateVersion = 23, incomePreviewExpiresAt = 110}, function()
	ttlClock = 20
	return detailResponse(23, "f1", 100, 110)
end, function() return ttlClock end)
ttlHarness.controller:requestDetail({incomeStateVersion = 23, incomePreviewExpiresAt = 110}, "f1")
ttlHarness:processOne()
expect(ttlHarness.invokes == 1 and ttlHarness.controller:state().status == "error", "transport consuming TTL becomes stable error")
ttlHarness:render()
expect(ttlHarness.invokes == 1, "TTL exhaustion does not render-retry")

local deadlineClock = 10
local deadlineHarness = mainDetailHarness({incomeStateVersion = 24, incomePreviewExpiresAt = 110}, function()
	return detailResponse(24, "f1", 100, 110)
end, function() return deadlineClock end)
deadlineHarness.controller:requestDetail({incomeStateVersion = 24, incomePreviewExpiresAt = 110}, "f1")
deadlineHarness:processOne()
deadlineClock = 20
for index = #deadlineHarness.delayQueue, 1, -1 do
	if deadlineHarness.delayQueue[index].seconds == 10 then
		local deadline = table.remove(deadlineHarness.delayQueue, index).fn
		deadline()
		break
	end
end
expect(deadlineHarness.invokes == 1 and deadlineHarness.controller:state().status == "error", "monotonic deadline becomes stable error")
deadlineHarness:render()
expect(deadlineHarness.invokes == 1, "monotonic deadline does not render-retry")

-- A relevant authoritative snapshot and an explicit retry are the two allowed
-- ways to leave a terminal error.  Both still use the one-transport queue.
local recoveryHarness = mainDetailHarness(staleSnapshot, function(callNumber)
	if callNumber == 1 then return detailResponse(21, "f1", 100, nil) end
	return detailResponse(25, "f1", 100, nil)
end, function() return 10 end)
recoveryHarness.controller:requestDetail(staleSnapshot, "f1")
recoveryHarness:processOne()
local recoveredSnapshot = {incomeStateVersion = 25}
recoveryHarness.snapshot = recoveredSnapshot
recoveryHarness.controller:onSnapshot(recoveredSnapshot)
recoveryHarness:processOne()
expect(recoveryHarness.invokes == 2 and recoveryHarness.controller:state().status == "ready", "new authoritative snapshot recovers stale error")

local retryHarness = mainDetailHarness(staleSnapshot, function()
	return rateRejectedResponse(21, nil)
end, function() return 10 end)
retryHarness.controller:requestDetail(staleSnapshot, "f1")
retryHarness:processOne()
expect(retryHarness.controller:retry(staleSnapshot), "explicit retry leaves stable error")
retryHarness:processOne()
expect(retryHarness.invokes == 2 and retryHarness.controller:state().status == "error", "explicit retry starts exactly one new transport")
retryHarness:render()
expect(retryHarness.invokes == 2, "retry error is stable on later render")

-- An error is scoped to both the selected key and the snapshot version.  A
-- direct caller that supplies a newer version must not reuse the old error.
local versionQueue = {}
local versionInvokes = 0
local versionController = Controller.new({
	invoke = function(payload)
		versionInvokes += 1
		if versionInvokes == 1 then return detailResponse(30, payload.id, 100, nil) end
		return detailResponse(31, payload.id, 100, 110)
	end,
	schedule = function(fn) table.insert(versionQueue, fn) end,
	delay = function() end,
	clock = function() return 10 end,
})
local version30Snapshot = {incomeStateVersion = 30, incomePreviewExpiresAt = 100}
versionController:requestDetail(version30Snapshot, "f1")
table.remove(versionQueue, 1)()
expect(versionController:state().status == "error", "version-scoped fixture reaches error")
local version31Snapshot = {incomeStateVersion = 31, incomePreviewExpiresAt = 110}
expect(versionController:requestDetail(version31Snapshot, "f1"), "new version request is accepted after old error")
table.remove(versionQueue, 1)()
expect(versionInvokes == 2 and versionController:state().status == "ready", "old error is not reused for a newer version")

print("IncomePreviewController.spec: generation, coalescing, snapshot invalidation and stable state PASS")
