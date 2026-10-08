local Query = require("../src/server/IncomePreviewQuery")
local Model = require("../src/shared/Model")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

local function spyFor(calls)
	return {
		incomePreview = function(profile, at, request)
			table.insert(calls, {profile = profile, at = at, request = clone(request)})
			return Model.incomePreview(profile, at, request)
		end,
	}
end

-- Detail uses one authoritative call per action and one shared timestamp.  A
-- record with save metadata is accepted without allowing the query to mutate
-- it or to enter settlement/storage code.
local detailProfile = Model.new(0)
local detailRecord = {profile = detailProfile, saving = true, busy = true, lastRequest = 42, incomePreviewLastRequest = nil}
local detailBefore = clone(detailRecord)
local detailCalls = {}
local detailOk, detailBody = Query.run(detailRecord, 100, {kind = "detail", id = "f1"}, spyFor(detailCalls))
expect(detailOk and type(detailBody) == "table", "detail query succeeds from saving-readable record")
expect(#detailCalls == 2, "detail query calls Model exactly twice")
expect(detailCalls[1].at == 100 and detailCalls[2].at == 100, "detail calls share one timestamp")
expect(detailCalls[1].request.action == "place" and detailCalls[1].request.id == "f1", "detail placement action selected")
expect(detailCalls[2].request.action == "showcase" and detailCalls[2].request.id == "f1", "detail showcase action selected")
expect(equal(detailRecord, detailBefore), "detail query does not mutate record or profile")
expect(detailBody.profile == nil and detailBody.items == nil and detailBody.fish == nil, "detail DTO is bounded and excludes profile snapshots")

local expectedPlacement = Model.incomePreview(detailProfile, 100, {kind = "fish", action = "place", id = "f1"})
local expectedShowcase = Model.incomePreview(detailProfile, 100, {kind = "fish", action = "showcase", id = "f1"})
expect(equal(detailBody.placement, expectedPlacement), "detail placement is authoritative Model result")
expect(equal(detailBody.showcase, expectedShowcase), "detail showcase is authoritative Model result")

-- A selected showcase produces the idempotent hide action while preserving the
-- same two-call contract.
local hideProfile = Model.new(0)
hideProfile.showcaseFishId = "f2"
local hideCalls = {}
local hideOk, hideBody = Query.run(hideProfile, 100, {kind = "detail", id = "f2"}, spyFor(hideCalls))
expect(hideOk and #hideCalls == 2 and hideCalls[2].request.action == "hideFish", "showcase detail uses hide action")
expect(hideBody.showcase.ok == true, "hide preview remains a normal nested DTO")

-- Merge performs one and only one Model preview with the exact payload,
-- including acknowledged placed IDs when supplied.
local mergeProfile = Model.new(0)
local mergeBefore = clone(mergeProfile)
local mergeCalls = {}
local mergeRequest = {kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"f1"}}
local mergeOk, mergeBody = Query.run({profile = mergeProfile, saving = true}, 200, mergeRequest, spyFor(mergeCalls))
expect(mergeOk and #mergeCalls == 1, "merge query calls Model exactly once")
expect(mergeCalls[1].at == 200 and equal(mergeCalls[1].request, mergeRequest), "merge request and timestamp are forwarded exactly")
expect(equal(mergeProfile, mergeBefore), "merge query does not mutate profile")
local expectedMerge = Model.incomePreview(mergeProfile, 200, mergeRequest)
expect(equal(mergeBody.preview, expectedMerge), "merge DTO is authoritative Model result")
expect(mergeBody.profile == nil and mergeBody.fish == nil, "merge DTO excludes full profile data")

-- A large inventory fixture exercises the adapter's selected-query boundary:
-- it may scan the authoritative Model inputs, but it never clones or returns
-- the whole inventory and still performs only the two selected detail calls.
local largeProfile = Model.new(0)
local templateFish = clone(largeProfile.fish[1])
for index = 4, 3003 do
	local fish = clone(templateFish)
	fish.id = "f" .. tostring(index)
	table.insert(largeProfile.fish, fish)
end
largeProfile.nextId = 3004
local largeCalls = {}
local largeBeforeCount = #largeProfile.fish
local largeOk, largeBody = Query.run(largeProfile, 300, {kind = "detail", id = "f3003"}, spyFor(largeCalls))
expect(largeOk and #largeCalls == 2 and #largeProfile.fish == largeBeforeCount, "large detail remains selected and bounded")
expect(largeBody.fish == nil and largeBody.profile == nil and largeBody.items == nil, "large detail does not return inventory snapshot")

-- Strict request/time guards fail before Model is called; this is separate from
-- the RemoteFunction/gate integration evidence recorded by FishingService QA.
local rejectedCalls = {}
local rejectedModel = spyFor(rejectedCalls)
local invalidOk = Query.run(detailProfile, 100, {kind = "merge", ids = {"f1", "f2"}}, rejectedModel)
expect(not invalidOk and #rejectedCalls == 0, "invalid request is rejected before Model")
local invalidTimeOk = Query.run(detailProfile, math.huge, {kind = "detail", id = "f1"}, rejectedModel)
expect(not invalidTimeOk and #rejectedCalls == 0, "invalid time is rejected before Model")
local negativeTimeOk, negativeTimeReason = Query.run(detailProfile, -1, {kind = "detail", id = "f1"}, rejectedModel)
expect(not negativeTimeOk and negativeTimeReason == "时间无效" and #rejectedCalls == 0, "negative time is rejected before Model")
local unknownOk, unknownBody = Query.run(detailProfile, 100, {kind = "detail", id = "missing"}, rejectedModel)
expect(unknownOk and #rejectedCalls == 2 and unknownBody.placement.ok == false and unknownBody.showcase.ok == false, "unknown detail stays two authoritative error calls")

print("IncomePreviewQuery.spec: read-only record adapter, exact detail/merge call counts and DTO bounds PASS")
