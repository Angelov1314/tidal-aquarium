--!strict
-- Pure, bounded validation for client request payloads. This module is kept
-- free of Roblox services so the request boundary can be regression-tested by
-- the standalone Luau interpreter.
local RequestValidation = {}
local MutationProtocol
if script then MutationProtocol = require(script.Parent.MutationProtocol) else MutationProtocol = require("./MutationProtocol") end

RequestValidation.MaxDepth = 4
RequestValidation.MaxEntries = 32
RequestValidation.MaxStringLength = 100
RequestValidation.MaxNodes = 256
RequestValidation.MaxStringBytes = 4096

local function finiteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function boundedNumber(value: any): boolean
	return finiteNumber(value) and value > -1e12 and value < 1e12
end

-- Network mutation intents are stricter than the generic bounded payload
-- walker below. Model keeps an omitted-field compatibility path for pure
-- internal callers, but FishingService must require these fields on every
-- RemoteFunction mutation request.
function RequestValidation.validateMutationIntent(action: any, payload: any): (boolean, string?)
	if action == "lock" then
		if type(payload) ~= "table" or type(payload.id) ~= "string" or #payload.id == 0 or #payload.id > 80 then return false, "lock-id" end
		if payload.locked == nil then return false, "lock-state-required" end
		if type(payload.locked) ~= "boolean" then return false, "lock-state-type" end
	elseif action == "upgrade" then
		if type(payload) ~= "table" or type(payload.kind) ~= "string" or #payload.kind == 0 or #payload.kind > 32 then return false, "upgrade-kind" end
		if payload.expectedLevel == nil or payload.expectedCost == nil then return false, "upgrade-intent-required" end
		if not finiteNumber(payload.expectedLevel) or payload.expectedLevel < 0 or payload.expectedLevel % 1 ~= 0 or payload.expectedLevel > 1000000
			or not boundedNumber(payload.expectedCost) or payload.expectedCost < 0 then return false, "upgrade-intent-invalid" end
	end
	return true, nil
end

-- The protocol envelope is checked before a domain command or a DataStore
-- budget-consuming write.  Epoch and sequence comparisons are kept separate
-- so the server can return a current snapshot without executing Model.
function RequestValidation.validateMutationEnvelope(action: any, payload: any, currentEpoch: string?, watermarks: any?): (boolean, string?, string?)
	if not MutationProtocol.isLane(action) then return true, nil, "not-lane" end
	local shapeOk, shapeReason = MutationProtocol.validateRequestShape(action, payload)
	if not shapeOk then return false, shapeReason, "reject" end
	if currentEpoch ~= nil and payload.stateEpoch ~= currentEpoch then return false, "epoch", "reject" end
	if watermarks ~= nil then
		local decision, reason = MutationProtocol.sequenceDecision(action, payload, currentEpoch or payload.stateEpoch, watermarks)
		return decision ~= "reject", reason, decision
	end
	return true, nil, "accept"
end

function RequestValidation.validate(payload: any): (boolean, string?)
	local nodes = 0
	local stringBytes = 0
	local activeTables: {[any]: boolean} = {}

	local function consumeNode(): boolean
		nodes += 1
		return nodes <= RequestValidation.MaxNodes
	end

	local function consumeString(value: string): (boolean, string?)
		if #value > RequestValidation.MaxStringLength then return false, "string-length" end
		if stringBytes + #value > RequestValidation.MaxStringBytes then return false, "string-bytes" end
		stringBytes += #value
		return true, nil
	end

	local function validateKey(key: any): (boolean, string?)
		local kind = type(key)
		if kind ~= "string" and kind ~= "number" then return false, "key-type" end
		if not consumeNode() then return false, "max-nodes" end
		if kind == "number" then
			if not finiteNumber(key) then return false, "key-number" end
			return true, nil
		end
		return consumeString(key)
	end

	local function visit(value: any, depth: number): (boolean, string?)
		if depth > RequestValidation.MaxDepth then return false, "max-depth" end
		if not consumeNode() then return false, "max-nodes" end

		local kind = type(value)
		if kind == "nil" or kind == "boolean" then return true, nil end
		if kind == "number" then
			if not boundedNumber(value) then return false, "number" end
			return true, nil
		end
		if kind == "string" then return consumeString(value) end
		if kind ~= "table" then return false, "type" end
		if activeTables[value] then return false, "cycle" end

		activeTables[value] = true
		local count = 0
		local key: any = nil
		while true do
			local nextKey, child = next(value, key)
			if nextKey == nil then break end
			key = nextKey
			count += 1
			if count > RequestValidation.MaxEntries then
				activeTables[value] = nil
				return false, "max-entries"
			end

			local keyOk, keyReason = validateKey(nextKey)
			if not keyOk then
				activeTables[value] = nil
				return false, keyReason
			end
			local childOk, childReason = visit(child, depth + 1)
			if not childOk then
				activeTables[value] = nil
				return false, childReason
			end
		end
		activeTables[value] = nil
		return true, nil
	end

	return visit(payload, 0)
end

return RequestValidation
