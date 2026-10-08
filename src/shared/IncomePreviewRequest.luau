--!strict
-- Exact wire shape for the read-only income preview request.  The generic
-- RequestValidation guard still runs at the RemoteFunction boundary; this
-- module adds action-specific shape and array checks without touching profile
-- data or Roblox services.
local IncomePreviewRequest = {}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 80
end

local function exactKeys(value: any, allowed: {[string]: boolean}): boolean
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then return false end
	end
	return true
end

local function idArray(value: any, minimum: number, maximum: number): ({string}?, string?)
	if type(value) ~= "table" then return nil, "数组无效" end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then return nil, "数组无效" end
		count += 1
	end
	if count < minimum or count > maximum then return nil, "数组长度无效" end
	local result = {}
	local seen: {[string]: boolean} = {}
	for index = 1, count do
		local id = value[index]
		if not validId(id) or seen[id] then return nil, "ID 数组无效" end
		seen[id] = true
		result[index] = id
	end
	return result, nil
end

local function validVersion(value: any): boolean
	return finite(value) and value >= 0 and value % 1 == 0
end

local function validResponseExpiry(response: any): boolean
	if response.expiresAt == nil then return true end
	return finite(response.expiresAt) and response.expiresAt >= response.calculatedAt
end

local function validOptionalNumber(value: any): boolean
	return value == nil or finite(value)
end

local function validOptionalId(value: any): boolean
	return value == nil or validId(value)
end

local function validReason(value: any): boolean
	return type(value) == "string" and #value <= 200
end

local function validPreview(value: any, requireResultBase: boolean, allowFishFields: boolean): boolean
	if type(value) ~= "table" then return false end
	if value.ok == false then
		if not exactKeys(value, {ok = true, allowed = true, reason = true}) then return false end
		return value.allowed == false and validReason(value.reason)
	end
	if value.ok ~= true then return false end
	local allowedKeys = {
		ok = true,
		allowed = true,
		reason = true,
		currentTotalPerHour = true,
		projectedTotalPerHour = true,
		deltaPerHour = true,
		showcaseBeforeId = true,
		showcaseAfterId = true,
		showcaseBonusBefore = true,
		showcaseBonusAfter = true,
		resultBasePerHour = requireResultBase,
		fishBasePerHour = allowFishFields,
		currentFishPerHour = allowFishFields,
		projectedFishPerHour = allowFishFields,
	}
	if not exactKeys(value, allowedKeys) then return false end
	if type(value.allowed) ~= "boolean" or not validReason(value.reason) then return false end
	for _, key in ipairs({"currentTotalPerHour", "projectedTotalPerHour", "deltaPerHour", "showcaseBonusBefore", "showcaseBonusAfter"}) do
		if not finite(value[key]) then return false end
	end
	if requireResultBase and not finite(value.resultBasePerHour) then return false end
	if not validOptionalNumber(value.resultBasePerHour) then return false end
	if not validOptionalNumber(value.fishBasePerHour) then return false end
	if not validOptionalNumber(value.currentFishPerHour) then return false end
	if not validOptionalNumber(value.projectedFishPerHour) then return false end
	if not validOptionalId(value.showcaseBeforeId) or not validOptionalId(value.showcaseAfterId) then return false end
	return true
end

function IncomePreviewRequest.validate(payload: any): (boolean, string?)
	if type(payload) ~= "table" or type(payload.kind) ~= "string" then return false, "预览请求无效" end
	if payload.kind == "detail" then
		if not exactKeys(payload, {kind = true, id = true}) or not validId(payload.id) then return false, "详情预览请求无效" end
		return true, nil
	elseif payload.kind == "merge" then
		if not exactKeys(payload, {kind = true, ids = true, acknowledgedPlacedIds = true}) then return false, "合成预览请求无效" end
		local ids, idsReason = idArray(payload.ids, 3, 3)
		if not ids then return false, idsReason end
		if payload.acknowledgedPlacedIds ~= nil then
			local _, ackReason = idArray(payload.acknowledgedPlacedIds, 0, 3)
			if ackReason then return false, "入缸确认无效" end
		end
		return true, nil
	end
	return false, "预览类型无效"
end

function IncomePreviewRequest.validateResponse(response: any, request: any, expectedVersion: any): (boolean, string?)
	local requestValid, requestReason = IncomePreviewRequest.validate(request)
	if not requestValid then return false, requestReason or "预览请求无效" end
	if type(response) ~= "table" then return false, "预览响应无效" end
	if response.kind ~= "incomePreview" or response.requestKind ~= request.kind then return false, "预览响应类型不匹配" end
	if not validVersion(expectedVersion) or response.stateVersion ~= expectedVersion or not validVersion(response.stateVersion) then return false, "预览响应版本不匹配" end
	if not finite(response.calculatedAt) or not validResponseExpiry(response) then return false, "预览响应时间无效" end
	if response.ok == false then
		if not exactKeys(response, {ok = true, kind = true, requestKind = true, stateVersion = true, calculatedAt = true, expiresAt = true, reason = true}) then return false, "预览错误响应结构无效" end
		if not validReason(response.reason) then return false, "预览错误原因无效" end
		return true, nil
	end
	if response.ok ~= true then return false, "预览响应状态无效" end
	if request.kind == "detail" then
		if not exactKeys(response, {ok = true, kind = true, requestKind = true, stateVersion = true, calculatedAt = true, expiresAt = true, id = true, placement = true, showcase = true}) then return false, "详情响应结构无效" end
		if response.id ~= request.id or not validId(response.id) then return false, "详情响应鱼 ID 不匹配" end
		if not validPreview(response.placement, false, true) or not validPreview(response.showcase, false, true) then return false, "详情预览结构无效" end
		return true, nil
	end
	if not exactKeys(response, {ok = true, kind = true, requestKind = true, stateVersion = true, calculatedAt = true, expiresAt = true, preview = true}) then return false, "合成响应结构无效" end
	if not validPreview(response.preview, true, false) then return false, "合成预览结构无效" end
	return true, nil
end

function IncomePreviewRequest.detail(id: string): {kind: string, id: string}
	return {kind = "detail", id = id}
end

function IncomePreviewRequest.merge(ids: {string}, acknowledgedPlacedIds: {string}?): {[string]: any}
	local payload: {[string]: any} = {kind = "merge", ids = {}}
	for index, id in ipairs(ids) do payload.ids[index] = id end
	if acknowledgedPlacedIds ~= nil then
		payload.acknowledgedPlacedIds = {}
		for index, id in ipairs(acknowledgedPlacedIds) do payload.acknowledgedPlacedIds[index] = id end
	end
	return payload
end

function IncomePreviewRequest.key(payload: any): string
	local valid = IncomePreviewRequest.validate(payload)
	if not valid then return "" end
	if payload.kind == "detail" then return "detail|" .. payload.id end
	local parts = {"merge"}
	for _, id in ipairs(payload.ids) do table.insert(parts, id) end
	table.insert(parts, "ack")
	for _, id in ipairs(payload.acknowledgedPlacedIds or {}) do table.insert(parts, id) end
	return table.concat(parts, "|")
end

return IncomePreviewRequest
