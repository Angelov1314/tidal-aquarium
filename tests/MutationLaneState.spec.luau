local MutationLaneState = require("../src/client/MutationLaneState")

local function expect(value: boolean, message: string)
	if not value then error(message, 2) end
end

local function state(epoch: string, seq: number, lockWatermark: number)
	return {
		mutationProtocol = 1,
		stateEpoch = epoch,
		snapshotSeq = seq,
		mutationWatermarks = {lock = lockWatermark, upgrade = 0, exchange = 0, useItem = 0},
	}
end

local client = MutationLaneState.new("client-nonce-a")
expect(client:installHandshake(state("epoch-a", 1, 0)), "same nonce handshake must install epoch")
local ok, request = client:begin("lock", {id = "f1", locked = true})
expect(ok and request.operationSeq == 1 and request.stateEpoch == "epoch-a", "lane request must freeze seq and epoch")
client:markTransportUnknown("lock")
local retryOk, retry = client:begin("lock", {id = "f1", locked = true})
expect(retryOk and retry.operationSeq == 1 and retry.stateEpoch == "epoch-a", "unknown retry must preserve exact payload")
local changedRetry = client:begin("lock", {id = "f1", locked = false})
expect(not changedRetry, "unknown cannot be replaced by a different payload")
expect(not client:acceptSnapshot(state("other-epoch", 2, 1), false), "ordinary wrong epoch snapshot must reject")
expect(client:acceptSnapshot(state("epoch-a", 2, 0), false), "low watermark snapshot may be observed while unknown")
expect(client:beginResync("lock"), "first bounded resync must be allowed")
expect(client:beginResync("lock"), "second bounded resync must be allowed")
expect(not client:beginResync("lock"), "recovery must stop after two bounded reads")
local released = client:reconcile("lock", state("epoch-a", 3, 1), false)
expect(released == "released-check-state" and not client:unknown("lock"), "consumed watermark releases only as check-state")

-- A later full snapshot follows the same conservative release path even when
-- it did not arrive as a response to the original request.  The helper must
-- release the UNKNOWN lane once, without claiming the callback succeeded.
local snapshotReleaseOk, snapshotReleaseRequest = client:begin("lock", {id = "f1", locked = false})
expect(snapshotReleaseOk and snapshotReleaseRequest.operationSeq == 2, "next lock intent starts after consumed watermark")
client:markTransportUnknown("lock")
expect(client:acceptSnapshot(state("epoch-a", 4, 2), false), "current epoch snapshot must be accepted")
expect(client:reconcileAcceptedSnapshot() == 1 and not client:isPending("lock"), "accepted full snapshot releases consumed UNKNOWN once")
expect(client:reconcileAcceptedSnapshot() == 0, "snapshot release must be idempotent")

-- Controlled transport adapter case: an invoke that never returns is marked
-- UNKNOWN by the deadline path, gets exactly two bounded reads, and a late
-- old-owner response cannot clear the recreated GUI's pending request.
local stalled = MutationLaneState.new("client-stalled")
expect(stalled:installHandshake(state("epoch-stalled", 1, 0)), "stalled handshake")
local stalledOk, stalledRequest = stalled:begin("upgrade", {kind = "hooks", expectedLevel = 0, expectedCost = 1})
expect(stalledOk and stalledRequest.operationSeq == 1, "stalled request starts")
stalled:markTransportUnknown("upgrade")
expect(stalled:beginResync("upgrade") and stalled:beginResync("upgrade"), "stalled request has two reads")
expect(stalled:manualRecoveryRequired("upgrade"), "stalled request reaches manual recovery")
local replacement = MutationLaneState.new("client-replacement")
expect(replacement:installHandshake(state("epoch-replacement", 1, 0)), "replacement handshake")
expect(not replacement:acceptSnapshot(state("epoch-stalled", 2, 1), false), "late old epoch cannot clear new owner")

-- A recreated GUI uses a new nonce/helper and cannot reuse the old epoch or
-- seq1; the server handshake is responsible for issuing the new epoch.
local recreated = MutationLaneState.new("client-nonce-b")
expect(recreated:installHandshake(state("epoch-b", 1, 1)), "new GUI must install the new fenced epoch")
local nextOk, nextRequest = recreated:begin("lock", {id = "f1", locked = false})
expect(nextOk and nextRequest.operationSeq == 2 and nextRequest.stateEpoch == "epoch-b", "new GUI must continue from authoritative watermark")
print("MutationLaneState.spec: handshake fence, exact UNKNOWN retry, bounded resync and GUI recreation PASS")
