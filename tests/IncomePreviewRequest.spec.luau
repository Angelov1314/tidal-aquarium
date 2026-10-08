local Request = require("../src/shared/IncomePreviewRequest")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local detail = Request.detail("f1")
local validDetail, detailReason = Request.validate(detail)
expect(validDetail and detailReason == nil and Request.key(detail) == "detail|f1", "valid detail request")
local merge = Request.merge({"f1", "f2", "f3"}, {"f2"})
local validMerge = Request.validate(merge)
expect(validMerge and Request.key(merge) == "merge|f1|f2|f3|ack|f2", "valid merge request")

local invalidRequests = {
	{kind = "detail", id = ""},
	{kind = "detail", id = "f1", extra = true},
	{kind = "merge", ids = {[1] = "f1", [3] = "f3"}},
	{kind = "merge", ids = {"f1", "f1", "f2"}},
	{kind = "merge", ids = {"f1", "f2", "f3", note = "extra"}},
	{kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {[2] = "f2"}},
	{kind = "merge", ids = {"f1", "f2", "f3"}, acknowledgedPlacedIds = {"missing", "missing"}},
}
for index, payload in ipairs(invalidRequests) do
	local valid = Request.validate(payload)
	expect(not valid, "invalid request rejected " .. tostring(index))
end

local function detailPreview(blocked)
	if blocked then return {ok = false, allowed = false, reason = "水族馆已满"} end
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

local function mergePreview()
	return {
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
end

local detailResponse = {
	ok = true,
	kind = "incomePreview",
	requestKind = "detail",
	stateVersion = 4,
	calculatedAt = 100,
	expiresAt = 120,
	id = "f1",
	placement = detailPreview(),
	showcase = detailPreview(),
}
local validDetailResponse, validDetailReason = Request.validateResponse(detailResponse, detail, 4)
expect(validDetailResponse and validDetailReason == nil, "complete detail response is valid")

local noExpiryResponse = {}
for key, value in pairs(detailResponse) do noExpiryResponse[key] = value end
noExpiryResponse.expiresAt = nil
local validNoExpiry = Request.validateResponse(noExpiryResponse, detail, 4)
expect(validNoExpiry, "nil expiry is valid")

local blockedResponse = {}
for key, value in pairs(detailResponse) do blockedResponse[key] = value end
blockedResponse.placement = detailPreview(true)
local validBlocked = Request.validateResponse(blockedResponse, detail, 4)
expect(validBlocked, "nested blocked preview remains displayable")

local mergeResponse = {
	ok = true,
	kind = "incomePreview",
	requestKind = "merge",
	stateVersion = 4,
	calculatedAt = 100,
	expiresAt = nil,
	preview = mergePreview(),
}
local validMergeResponse = Request.validateResponse(mergeResponse, merge, 4)
expect(validMergeResponse, "complete merge response is valid")

local function copyTable(source)
	local result = {}
	for key, value in pairs(source) do result[key] = value end
	return result
end

local topError = {
	ok = false,
	kind = "incomePreview",
	requestKind = "detail",
	stateVersion = 4,
	calculatedAt = 100,
	reason = "预览请求过快，请稍后。",
}
expect(Request.validateResponse(topError, detail, 4), "top-level server error is valid")
local badTopErrorExpiry = copyTable(topError)
badTopErrorExpiry.expiresAt = "later"
expect(not Request.validateResponse(badTopErrorExpiry, detail, 4), "top-level error rejects invalid expiry")

local invalidResponses = {}
local wrongKind = copyTable(detailResponse); wrongKind.requestKind = "merge"; table.insert(invalidResponses, wrongKind)
local wrongId = copyTable(detailResponse); wrongId.id = "f2"; table.insert(invalidResponses, wrongId)
local wrongVersion = copyTable(detailResponse); wrongVersion.stateVersion = 4.5; table.insert(invalidResponses, wrongVersion)
local negativeVersion = copyTable(detailResponse); negativeVersion.stateVersion = -1; table.insert(invalidResponses, negativeVersion)
local missingCalculatedAt = copyTable(detailResponse); missingCalculatedAt.calculatedAt = nil; table.insert(invalidResponses, missingCalculatedAt)
local stringExpiry = copyTable(detailResponse); stringExpiry.expiresAt = "120"; table.insert(invalidResponses, stringExpiry)
local nanExpiry = copyTable(detailResponse); nanExpiry.expiresAt = 0 / 0; table.insert(invalidResponses, nanExpiry)
local infiniteExpiry = copyTable(detailResponse); infiniteExpiry.expiresAt = math.huge; table.insert(invalidResponses, infiniteExpiry)
local pastExpiry = copyTable(detailResponse); pastExpiry.expiresAt = 99; table.insert(invalidResponses, pastExpiry)
local extraTop = copyTable(detailResponse); extraTop.unexpected = true; table.insert(invalidResponses, extraTop)
local missingPlacement = copyTable(detailResponse); missingPlacement.placement = nil; table.insert(invalidResponses, missingPlacement)
local badAllowed = copyTable(detailResponse); badAllowed.placement = detailPreview(); badAllowed.placement.allowed = "yes"; table.insert(invalidResponses, badAllowed)
local badNumber = copyTable(detailResponse); badNumber.placement = detailPreview(); badNumber.placement.deltaPerHour = math.huge; table.insert(invalidResponses, badNumber)
local extraNested = copyTable(detailResponse); extraNested.placement = detailPreview(); extraNested.placement.unexpected = true; table.insert(invalidResponses, extraNested)
local longReason = copyTable(detailResponse); longReason.placement = {ok = false, allowed = false, reason = string.rep("x", 201)}; table.insert(invalidResponses, longReason)
for index, response in ipairs(invalidResponses) do
	local valid = Request.validateResponse(response, detail, 4)
	expect(not valid, "invalid response rejected " .. tostring(index))
end

print("IncomePreviewRequest.spec: exact payload/response shape, finite expiry and nested DTO guards PASS")
