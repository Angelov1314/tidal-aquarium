--!strict
-- A small server-owned bootstrap fence.  The prepare result is read-only;
-- installing a different client owner requires that exact epoch/fence pair.
local HandshakeFence = {}

local function validEpoch(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
end

local function validNonce(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 128
end

local function validFence(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 0
end

function HandshakeFence.prepare(state: any): (boolean, any)
	if type(state) ~= "table" then return false, "state" end
	if state.closed or state.lost or state.saving or state.busy then return false, "busy" end
	if not validEpoch(state.stateEpoch) or not validFence(state.handshakeFence) then return false, "state" end
	return true, {
		prepareHandshake = true,
		stateEpoch = state.stateEpoch,
		handshakeFence = state.handshakeFence,
	}
end

function HandshakeFence.commit(state: any, request: any, makeEpoch: () -> string): (boolean, any)
	if type(state) ~= "table" or type(request) ~= "table" then return false, "request" end
	-- Lost/closed is checked before the idempotent nonce branch.  A closed
	-- owner cannot be resurrected by replaying its last bootstrap payload.
	if state.closed or state.lost or state.saving or state.busy then return false, "busy" end
	if not validEpoch(state.stateEpoch) or not validFence(state.handshakeFence) then return false, "state" end
	if not validNonce(request.clientSessionNonce) then return false, "nonce" end
	if state.clientSessionNonce == request.clientSessionNonce then
		return true, {
			handshake = true,
			stateEpoch = state.stateEpoch,
			handshakeFence = state.handshakeFence,
			changed = false,
		}
	end
	if not validEpoch(request.expectedEpoch) or not validFence(request.expectedFence) then return false, "fence" end
	if request.expectedEpoch ~= state.stateEpoch or request.expectedFence ~= state.handshakeFence then return false, "stale-fence" end
	local nextEpoch = makeEpoch()
	if not validEpoch(nextEpoch) or nextEpoch == state.stateEpoch then return false, "epoch" end
	state.clientSessionNonce = request.clientSessionNonce
	state.stateEpoch = nextEpoch
	state.handshakeFence += 1
	state.snapshotSeq = 0
	return true, {
		handshake = true,
		stateEpoch = state.stateEpoch,
		handshakeFence = state.handshakeFence,
		changed = true,
	}
end

function HandshakeFence.acceptsEpoch(state: any, epoch: any): boolean
	return type(state) == "table" and not state.closed and not state.lost and validEpoch(epoch) and epoch == state.stateEpoch
end

return HandshakeFence
