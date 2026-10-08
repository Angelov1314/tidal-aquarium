local HandshakeFence = require("../src/shared/HandshakeFence")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local nextEpoch = 0
local function newEpoch()
	nextEpoch += 1
	return "epoch-" .. tostring(nextEpoch)
end

local state = {
	stateEpoch = "epoch-a",
	handshakeFence = 0,
	clientSessionNonce = nil,
	busy = false,
	saving = false,
	lost = false,
	closed = false,
}

local preparedAOk, preparedA = HandshakeFence.prepare(state)
local preparedBOk, preparedB = HandshakeFence.prepare(state)
expect(preparedAOk and preparedBOk and preparedA.stateEpoch == "epoch-a" and preparedB.handshakeFence == 0,
	"prepare must be read-only and return the current fence")

local committedBOk, committedB = HandshakeFence.commit(state, {
	clientSessionNonce = "owner-b",
	expectedEpoch = preparedB.stateEpoch,
	expectedFence = preparedB.handshakeFence,
}, newEpoch)
expect(committedBOk and committedB.changed and state.clientSessionNonce == "owner-b", "owner B must install from its prepare")
expect(not HandshakeFence.acceptsEpoch(state, "epoch-a") and HandshakeFence.acceptsEpoch(state, committedB.stateEpoch),
	"old A epoch must be fenced after B install")
expect(not HandshakeFence.acceptsEpoch(state, preparedA.stateEpoch), "late A mutation and snapshot must both reject the old epoch")

local lateAOk = HandshakeFence.commit(state, {
	clientSessionNonce = "owner-a",
	expectedEpoch = preparedA.stateEpoch,
	expectedFence = preparedA.handshakeFence,
}, newEpoch)
expect(not lateAOk and state.clientSessionNonce == "owner-b", "late A commit must be rejected without rotating B")

-- A lost response may replay the exact B payload with its old prepare values;
-- the current nonce is idempotent and returns B's installed epoch/fence.
local retryBOk, retryB = HandshakeFence.commit(state, {
	clientSessionNonce = "owner-b",
	expectedEpoch = preparedB.stateEpoch,
	expectedFence = preparedB.handshakeFence,
}, newEpoch)
expect(retryBOk and not retryB.changed and retryB.stateEpoch == committedB.stateEpoch and retryB.handshakeFence == committedB.handshakeFence,
	"same nonce retry must remain stable after a lost response")

state.busy = true
local busyPrepared = HandshakeFence.prepare(state)
local busyCommit = HandshakeFence.commit(state, {
	clientSessionNonce = "owner-c",
	expectedEpoch = state.stateEpoch,
	expectedFence = state.handshakeFence,
}, newEpoch)
expect(not busyPrepared and not busyCommit, "busy state must reject prepare and commit")
state.busy = false
state.lost = true
expect(not HandshakeFence.prepare(state) and not HandshakeFence.commit(state, {
	clientSessionNonce = "owner-b",
	expectedEpoch = state.stateEpoch,
	expectedFence = state.handshakeFence,
}, newEpoch), "lost state must not be resurrected by same nonce")

print("HandshakeFence.spec: prepare/commit fence, ABA late owner, idempotent retry, busy/lost guards PASS")
