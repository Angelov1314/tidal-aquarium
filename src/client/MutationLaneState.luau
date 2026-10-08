--!strict
-- Client-only state machine for the four mutation lanes. It never invokes a
-- RemoteFunction; main.client owns transport and GUI ownership checks.
local MutationProtocol
if script then MutationProtocol = require(game:GetService("ReplicatedStorage"):WaitForChild("FishingShared"):WaitForChild("MutationProtocol")) else MutationProtocol = require("../shared/MutationProtocol") end

local MutationLaneState = {}
MutationLaneState.__index = MutationLaneState

local function watermarksEqualOrNewer(current: any, incoming: any): boolean
	local valid = MutationProtocol.validateWatermarks(incoming)
	if not valid then return false end
	for _, lane in ipairs(MutationProtocol.Lanes) do
		if incoming[lane] < (current[lane] or 0) then return false end
	end
	return true
end

function MutationLaneState.new(nonce: string)
	return setmetatable({
		nonce = nonce,
		epoch = nil,
		snapshotSeq = -1,
		watermarks = MutationProtocol.newWatermarks(),
		pending = {},
	}, MutationLaneState)
end

function MutationLaneState:isLane(action: any): boolean
	return MutationProtocol.isLane(action)
end

function MutationLaneState:getEpoch(): string?
	return self.epoch
end

function MutationLaneState:installHandshake(state: any): boolean
	if type(state) ~= "table" or state.mutationProtocol ~= MutationProtocol.ProtocolVersion
		or not MutationProtocol.isEpoch(state.stateEpoch) or not MutationProtocol.isWatermark(state.snapshotSeq)
		or not watermarksEqualOrNewer(self.watermarks, state.mutationWatermarks) then return false end
	if self.epoch ~= nil and self.epoch ~= state.stateEpoch then return false end
	self.epoch = state.stateEpoch
	self.snapshotSeq = state.snapshotSeq
	self.watermarks = MutationProtocol.clone(state.mutationWatermarks)
	return true
end

function MutationLaneState:acceptSnapshot(state: any, handshake: boolean?): boolean
	if handshake then return self:installHandshake(state) end
	if type(state) ~= "table" or self.epoch == nil or state.mutationProtocol ~= MutationProtocol.ProtocolVersion
		or state.stateEpoch ~= self.epoch or not MutationProtocol.isWatermark(state.snapshotSeq)
		or state.snapshotSeq < self.snapshotSeq or not watermarksEqualOrNewer(self.watermarks, state.mutationWatermarks) then return false end
	self.snapshotSeq = state.snapshotSeq
	self.watermarks = MutationProtocol.clone(state.mutationWatermarks)
	return true
end

-- A full snapshot has already passed the epoch/sequence/watermark fence when
-- this is called.  An UNKNOWN request therefore may be released only as a
-- conservative "check state" outcome once its lane watermark is consumed;
-- this never claims that the original callback was observed.
function MutationLaneState:reconcileAcceptedSnapshot(): number
	local released = 0
	for _, lane in ipairs(MutationProtocol.Lanes) do
		if self.pending[lane] and self.pending[lane].unknown
			and self:reconcile(lane, nil, nil) == "released-check-state" then
			released += 1
		end
	end
	return released
end

function MutationLaneState:begin(action: string, payload: any): (boolean, any, string?)
	if not self:isLane(action) then return true, payload or {}, nil end
	if self.epoch == nil then return false, nil, "handshake-required" end
	local existing = self.pending[action]
	if existing then
		local intent = MutationProtocol.clone(payload or {})
		if type(intent) == "table" then
			intent.mutationProtocol, intent.stateEpoch, intent.operationSeq = nil, nil, nil
		end
		local existingIntent = MutationProtocol.clone(existing.request)
		existingIntent.mutationProtocol, existingIntent.stateEpoch, existingIntent.operationSeq = nil, nil, nil
		if existing.unknown and MutationProtocol.equal(existingIntent, intent) then
			existing.attempt += 1
			return true, MutationProtocol.clone(existing.request), "retry-unknown"
		end
		return false, nil, if existing.unknown then "mutation-unknown" else "pending"
	end
	local request = MutationProtocol.clone(payload or {})
	request.mutationProtocol = MutationProtocol.ProtocolVersion
	request.stateEpoch = self.epoch
	request.operationSeq = (self.watermarks[action] or 0) + 1
	self.pending[action] = {seq = request.operationSeq, request = MutationProtocol.clone(request), unknown = false, resyncAttempts = 0, attempt = 1}
	return true, request, nil
end

function MutationLaneState:attempt(action: string): number
	local pending = self.pending[action]
	return pending and pending.attempt or 0
end

function MutationLaneState:isCurrent(action: string, seq: number, attempt: number): boolean
	local pending = self.pending[action]
	return pending ~= nil and pending.seq == seq and pending.attempt == attempt
end

function MutationLaneState:isPending(action: string): boolean
	return self.pending[action] ~= nil
end

function MutationLaneState:anyPending(): boolean
	for _, pending in pairs(self.pending) do if pending ~= nil then return true end end
	return false
end

function MutationLaneState:markTransportUnknown(action: string): boolean
	local pending = self.pending[action]
	if not pending then return false end
	pending.unknown = true
	return true
end

function MutationLaneState:beginResync(action: string): boolean
	local pending = self.pending[action]
	if not pending or not pending.unknown or pending.resyncAttempts >= 2 then return false end
	pending.resyncAttempts += 1
	return true
end

function MutationLaneState:pendingRequest(action: string): any?
	local pending = self.pending[action]
	return pending and MutationProtocol.clone(pending.request) or nil
end

function MutationLaneState:reconcile(action: string, state: any, responseOk: boolean?): string
	local pending = self.pending[action]
	if not pending then return "none" end
	if type(state) == "table" then self:acceptSnapshot(state, false) end
	local current = self.watermarks[action] or 0
	if pending.unknown then
		if current >= pending.seq then self.pending[action] = nil; return "released-check-state" end
		return "unknown"
	end
	if responseOk == true and current >= pending.seq then self.pending[action] = nil; return "committed" end
	if responseOk == false then self.pending[action] = nil; return "rejected" end
	return "pending"
end

function MutationLaneState:unknown(action: string): boolean
	local pending = self.pending[action]
	return pending ~= nil and pending.unknown == true
end

function MutationLaneState:manualRecoveryRequired(action: string): boolean
	local pending = self.pending[action]
	return pending ~= nil and pending.unknown == true and pending.resyncAttempts >= 2
end

return MutationLaneState
