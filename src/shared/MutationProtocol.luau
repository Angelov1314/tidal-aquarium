--!strict
-- Small, pure protocol contract shared by the profile model and the request
-- boundary.  The four lane names are intentionally explicit: adding another
-- mutation here requires a new review and a new replay fixture.
local MutationProtocol = {}

MutationProtocol.ProfileVersion = 3
MutationProtocol.ProtocolVersion = 1
MutationProtocol.MaxOperationSeq = 2147483647
MutationProtocol.MaxEpochLength = 128
-- Each lane changes only bounded scalar/item fields or removes at most its
-- fixed input set. Storage reserves this margin before running Model; the
-- exact candidate is still serialized and checked after the transform.
MutationProtocol.MaxLaneDeltaBytes = 65536
-- The bound deliberately covers the known ~1,000-entry legacy map while
-- keeping migration work finite. The actual serialized map is checked again
-- by Storage with its JSON serializer before an UpdateAsync candidate write.
MutationProtocol.LegacyReceiptMaxEntries = 2048
MutationProtocol.LegacyReceiptMaxBytes = 131072
MutationProtocol.Lanes = { "lock", "upgrade", "exchange", "useItem" }

local laneSet = {}
for _, lane in ipairs(MutationProtocol.Lanes) do laneSet[lane] = true end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function MutationProtocol.isLane(action: any): boolean
	return type(action) == "string" and laneSet[action] == true
end

function MutationProtocol.isSequence(value: any): boolean
	return finite(value) and value % 1 == 0 and value >= 1 and value <= MutationProtocol.MaxOperationSeq
end

function MutationProtocol.isWatermark(value: any): boolean
	return finite(value) and value % 1 == 0 and value >= 0 and value <= MutationProtocol.MaxOperationSeq
end

function MutationProtocol.isEpoch(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MutationProtocol.MaxEpochLength
end

function MutationProtocol.newWatermarks(): {[string]: number}
	return { lock = 0, upgrade = 0, exchange = 0, useItem = 0 }
end

function MutationProtocol.clone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = MutationProtocol.clone(child) end
	return copy
end

function MutationProtocol.equal(left: any, right: any): boolean
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not MutationProtocol.equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

function MutationProtocol.validateWatermarks(watermarks: any): (boolean, string?)
	if type(watermarks) ~= "table" then return false, "watermarks-type" end
	for _, lane in ipairs(MutationProtocol.Lanes) do
		if not MutationProtocol.isWatermark(watermarks[lane]) then return false, "watermark-" .. lane end
	end
	for key in pairs(watermarks) do
		if not laneSet[key] then return false, "watermark-extra" end
	end
	return true, nil
end

local function jsonStringBytes(value: string): number
	local bytes = 2
	for index = 1, #value do
		local code = string.byte(value, index)
		if code == 34 or code == 92 then bytes += 2
		elseif code < 32 then bytes += 6
		else bytes += 1 end
	end
	return bytes
end

local function markerBytes(marker: any): number
	if marker == true then return 4 end
	return #string.format("%.17g", marker)
end

-- The fallback estimate is a conservative canonical JSON-like byte count. A
-- server Storage adapter may pass its actual serializer; the returned count is
-- still checked against the same explicit bound before a migrated write.
function MutationProtocol.legacyReceiptStats(map: any, serializer: ((any) -> string)?)
	if map == nil then return true, 0, 0, nil end
	if type(map) ~= "table" then return false, 0, 0, "legacy-map-type" end
	local count, estimatedBytes = 0, 2
	for requestId, marker in pairs(map) do
		count += 1
		if count > MutationProtocol.LegacyReceiptMaxEntries then return false, estimatedBytes, count, "legacy-map-entries" end
		if type(requestId) ~= "string" or #requestId == 0 or #requestId > 128 then return false, estimatedBytes, count, "legacy-map-key" end
		if marker ~= true and (not finite(marker) or marker < 0 or marker > 32503680000) then return false, estimatedBytes, count, "legacy-map-marker" end
		estimatedBytes += jsonStringBytes(requestId) + markerBytes(marker) + 1
		if estimatedBytes > MutationProtocol.LegacyReceiptMaxBytes then return false, estimatedBytes, count, "legacy-map-bytes" end
	end
	if serializer then
		local ok, encoded = pcall(serializer, map)
		if not ok or type(encoded) ~= "string" then return false, estimatedBytes, count, "legacy-map-serialize" end
		if #encoded > MutationProtocol.LegacyReceiptMaxBytes then return false, #encoded, count, "legacy-map-bytes" end
		return true, #encoded, count, nil
	end
	return true, estimatedBytes, count, nil
end

function MutationProtocol.validateRequestShape(action: any, payload: any): (boolean, string?)
	if not MutationProtocol.isLane(action) then return true, nil end
	if type(payload) ~= "table" then return false, "payload-type" end
	if payload.mutationProtocol ~= MutationProtocol.ProtocolVersion then return false, "protocol" end
	if not MutationProtocol.isEpoch(payload.stateEpoch) then return false, "epoch" end
	if not MutationProtocol.isSequence(payload.operationSeq) then return false, "operation-seq" end
	return true, nil
end

function MutationProtocol.sequenceDecision(action: string, payload: any, epoch: string, watermarks: any): (string, string?)
	local shapeOk, shapeReason = MutationProtocol.validateRequestShape(action, payload)
	if not shapeOk then return "reject", shapeReason end
	if payload.stateEpoch ~= epoch then return "reject", "epoch" end
	local current = watermarks[action]
	if not MutationProtocol.isWatermark(current) then return "reject", "watermark" end
	if payload.operationSeq <= current then return "replay", nil end
	if payload.operationSeq ~= current + 1 then return "reject", "sequence-gap" end
	return "accept", nil
end

return MutationProtocol
