local Model = require("../src/shared/Model")
local MutationProtocol = require("../src/shared/MutationProtocol")
local RequestValidation = require("../src/shared/RequestValidation")

local function expect(value: boolean, message: string)
	if not value then error(message, 2) end
end

local function clone(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

-- A real old profile is accepted before migration, keeps the paid receipt
-- meaning, and atomically replaces only the old GUID map with four zero lanes.
local legacy = Model.new(0)
legacy.version = 2
legacy.mutationProtocol, legacy.mutationWatermarks = nil, nil
legacy.requestReceipts = { ["old-guid-1"] = true, ["old-guid-2"] = 1700000000 }
legacy.receipts = { ["paid-receipt"] = true }
expect(Model.validate(legacy), "valid v2 profile must validate before migration")
expect(Model.migrate(legacy, 20), "v2 profile must migrate")
expect(legacy.version == 3 and legacy.requestReceipts == nil, "migration must remove GUID map")
expect(legacy.receipts["paid-receipt"] == true, "migration must preserve paid receipts")
expect(MutationProtocol.validateWatermarks(legacy.mutationWatermarks), "migration must install all lane watermarks")
expect(Model.migrate(legacy, 21) == false, "v3 migration must be idempotent")

-- A large but bounded legacy map remains migratable; malformed/future/mixed
-- protocol input is refused before any candidate mutation.
local large = Model.new(0)
large.version = 2
large.mutationProtocol, large.mutationWatermarks = nil, nil
large.requestReceipts = {}
for index = 1, 1000 do large.requestReceipts["legacy-" .. tostring(index)] = true end
expect(Model.validate(large), "known 1000-entry v2 map must remain valid")
expect(MutationProtocol.legacyReceiptStats(large.requestReceipts), "known map must stay within explicit bounds")
local malformed = Model.new(0)
malformed.version = 2
malformed.mutationProtocol, malformed.mutationWatermarks = nil, nil
malformed.requestReceipts = {bad = {nested = true}}
expect(not Model.validate(malformed), "malformed legacy marker must fail closed")
local mixed = Model.new(0)
mixed.version = 2
mixed.mutationProtocol, mixed.mutationWatermarks = MutationProtocol.ProtocolVersion, MutationProtocol.newWatermarks()
expect(not Model.validate(mixed), "legacy profile with new fields must fail closed")
local future = clone(Model.new(0)); future.version = 4
expect(not Model.validate(future), "future profile version must fail closed")

-- Protocol sequence is per lane, rejects gaps, and does not infer sequence
-- from a GUID or from another lane.
local epoch = "opaque-epoch-a"
local watermarks = MutationProtocol.newWatermarks()
local lock1 = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 1, id = "f1", locked = false}
local decision = MutationProtocol.sequenceDecision("lock", lock1, epoch, watermarks)
expect(decision == "accept", "first lane sequence must accept")
watermarks.lock = 1
expect(MutationProtocol.sequenceDecision("lock", lock1, epoch, watermarks) == "replay", "same lane replay must be recognized")
local gap = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 3, id = "f1", locked = true}
expect(MutationProtocol.sequenceDecision("lock", gap, epoch, watermarks) == "reject", "sequence gap must reject")
local upgrade1 = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 1, kind = "hooks", expectedLevel = 0, expectedCost = 1}
expect(MutationProtocol.sequenceDecision("upgrade", upgrade1, epoch, watermarks) == "accept", "lanes must have independent watermarks")
expect(RequestValidation.validateMutationEnvelope("lock", lock1, epoch, watermarks), "valid lane envelope must pass")
local wrongEpoch = clone(lock1); wrongEpoch.stateEpoch = "other"
local wrongOk, wrongReason = RequestValidation.validateMutationEnvelope("lock", wrongEpoch, epoch, watermarks)
expect(not wrongOk and wrongReason == "epoch", "wrong epoch must reject before Model")

-- ABA uses sequence order rather than desired boolean: false seq1, true seq2,
-- then delayed false seq1 is a replay and cannot unlock the newer true state.
local profile = Model.new(0)
local p1 = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 1, id = "f1", locked = false}
local p2 = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 2, id = "f1", locked = true}
local modelCalls = 0
local function applyLane(request: any)
	local decision = Model.mutationDecision(profile, "lock", request, epoch)
	if decision ~= "accept" then return {ok = true, replayed = true} end
	modelCalls += 1
	local response = Model.command(profile, "lock", request, 0, nil, {source = "remote"})
	if response.ok then expect(Model.advanceMutationWatermark(profile, "lock", request.operationSeq), "lane watermark advance") end
	return response
end
expect(applyLane(p1).ok and modelCalls == 1, "seq1 false must apply")
expect(applyLane(p2).ok and modelCalls == 2, "seq2 true must apply")
local delayedP1 = applyLane(p1)
expect(delayedP1.ok and delayedP1.replayed and modelCalls == 2, "delayed seq1 must be rejected before Model")
expect(profile.fish[1].locked == true and profile.mutationWatermarks.lock == 2, "newer lock must remain true")
local p3 = {mutationProtocol = 1, stateEpoch = epoch, operationSeq = 3, id = "f1", locked = false}
expect(applyLane(p3).ok and profile.fish[1].locked == false, "new seq3 false must apply")
local delayedP2 = applyLane(p2)
expect(delayedP2.ok and delayedP2.replayed and modelCalls == 3 and profile.fish[1].locked == false, "delayed seq2 must not re-lock")

print("MutationProtocol.spec: v2 migration bounds, paid receipt preservation, epoch/sequence fences and ABA PASS")
