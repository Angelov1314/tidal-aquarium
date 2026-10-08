local RequestValidation = require("../src/shared/RequestValidation")

local function expect(condition: boolean, message: string)
	if not condition then error(message, 2) end
end

local function accepted(payload: any, label: string)
	local ok, reason = RequestValidation.validate(payload)
	expect(ok, label .. " should be accepted; reason=" .. tostring(reason))
end

local function rejected(payload: any, label: string, expectedReason: string?)
	local ok, reason = RequestValidation.validate(payload)
	expect(not ok, label .. " should be rejected")
	if expectedReason then expect(reason == expectedReason, label .. " reason changed: " .. tostring(reason)) end
end

-- Preserve every payload shape currently sent to FishingService. Generic
-- validation must not become an action schema or reject empty/nil payloads.
local actionPayloads = {
	{name = "snapshot nil", payload = nil},
	{name = "snapshot empty", payload = {}},
	{name = "toggleFishing", payload = {}},
	{name = "travel", payload = {zone = 1}},
	{name = "place", payload = {id = "f1"}},
	{name = "remove", payload = {id = "f1"}},
	{name = "sell", payload = {id = "f1"}},
	{name = "sellDuplicates", payload = {}},
	{name = "lock", payload = {id = "f1"}},
	{name = "merge", payload = {ids = {"f1", "f2", "f3"}}},
	{name = "upgrade", payload = {kind = "hooks"}},
	{name = "unlock", payload = {zone = 2}},
	{name = "contract", payload = {species = "white_koi"}},
	{name = "exchange", payload = {recipeId = "exchange_luck", ids = {"f1", "f2", "f3"}, requestId = "r1"}},
	{name = "useItem", payload = {itemId = "luck_tonic", requestId = "r2"}},
	{name = "showcase", payload = {id = "f1"}},
	{name = "hideFish", payload = {}},
	{name = "visitAquarium", payload = {}},
	{name = "purchasePass", payload = {}},
	{name = "purchaseBoost", payload = {}},
}
for _, sample in ipairs(actionPayloads) do
	accepted(sample.payload, sample.name)
end

-- Legacy scalar and structural boundaries remain valid, including a value at
-- depth four, 32 entries, and strings of exactly 100 bytes.
accepted({falseValue = false, zero = 0, lower = -999999999999, upper = 999999999999}, "legacy scalar payload")
accepted({a = {b = {c = {d = true}}}}, "depth-four payload")
accepted({short = string.rep("x", 100), [string.rep("k", 100)] = true}, "100-byte strings")
local thirtyTwo = {}
for i = 1, 32 do thirtyTwo["k" .. i] = i end
accepted(thirtyTwo, "32-entry table")

-- Numeric values retain the old finite range and reject all NaN/Inf forms.
for _, value in ipairs({0 / 0, math.huge, -math.huge}) do
	rejected({value = value}, "non-finite value")
end
rejected({lower = -1e12}, "lower numeric limit")
rejected({upper = 1e12}, "upper numeric limit")

-- Depth and per-table width limits are still enforced.
rejected({a = {b = {c = {d = {e = true}}}}}, "depth-five payload", "max-depth")
local thirtyThree = {}
for i = 1, 33 do thirtyThree["k" .. i] = i end
rejected(thirtyThree, "33-entry table", "max-entries")

-- Keys have the same bounded text semantics as values, and only string and
-- finite numeric key types are accepted.
rejected({[string.rep("k", 101)] = true}, "oversized string key", "string-length")
rejected({[math.huge] = true}, "infinite numeric key", "key-number")
rejected({[true] = true}, "boolean key", "key-type")
local functionKey = {}
functionKey[function() end] = true
rejected(functionKey, "function key", "key-type")

-- Unknown values fail closed instead of reaching domain commands.
rejected(function() end, "function value", "type")
local threadValue = coroutine.create(function() end)
rejected(threadValue, "thread value", "type")

-- A cyclic table must fail safely instead of recursing forever.
local cyclic = {}
cyclic.self = cyclic
rejected(cyclic, "cyclic table", "cycle")

-- Global node budget counts the root, every key and every value. This tree is
-- locally within depth/entry limits but exceeds 256 nodes and must stop there.
local wideNodes = {}
for branchIndex = 1, 32 do
	local branch = {}
	for valueIndex = 1, 8 do branch["v" .. valueIndex] = valueIndex end
	wideNodes["b" .. branchIndex] = branch
end
rejected(wideNodes, "global node budget", "max-nodes")

-- Because every table entry contributes one key and one value node, reachable
-- tree sizes are odd. The largest reachable payload at a 256-node limit is
-- therefore 255 nodes; it is accepted, while the next reachable size (257)
-- is rejected.
local exactNodes = {}
for branchIndex = 1, 31 do
	local branch = {}
	local valueCount = if branchIndex == 1 then 6 else 3
	for valueIndex = 1, valueCount do branch["v" .. valueIndex] = valueIndex end
	exactNodes["b" .. branchIndex] = branch
end
accepted(exactNodes, "255-node boundary")
for valueIndex = 1, 7 do exactNodes.b1["v" .. valueIndex] = valueIndex end
rejected(exactNodes, "257-node over-boundary", "max-nodes")

-- Global string bytes include keys and values. Keep node count below 256 so
-- this case proves the byte budget independently of the node budget.
local wideText = {}
for branchIndex = 1, 16 do
	local branch = {}
	for valueIndex = 1, 4 do branch["v" .. valueIndex] = string.rep("x", 100) end
	wideText["b" .. branchIndex] = branch
end
rejected(wideText, "global string-byte budget", "string-bytes")

-- The byte boundary is independently reachable below the node budget: 160
-- strings total 4096 bytes, then one value grows by one byte to 4097.
local exactBytes = {}
local firstBranchValueKey = ""
for branchIndex = 1, 20 do
	local branch = {}
	for valueIndex = 1, 4 do
		local key = string.rep("k", 24) .. tostring(valueIndex)
		local length = if branchIndex == 1 then 49 else 25
		branch[key] = string.rep("v", length)
		if branchIndex == 1 and valueIndex == 1 then firstBranchValueKey = key end
	end
	exactBytes[branchIndex] = branch
end
accepted(exactBytes, "4096-byte boundary")
exactBytes[1][firstBranchValueKey] = string.rep("v", 50)
rejected(exactBytes, "4097-byte over-boundary", "string-bytes")

-- A wide flat table is rejected after the 32nd entry, so counting never
-- requires walking an unbounded input.
local overWide = {}
for i = 1, 100 do overWide[i] = true end
rejected(overWide, "early entry-budget stop", "max-entries")

print("RequestValidation.spec: 20 legacy payloads plus scalar, depth, width, key, cycle, node and byte-budget regressions PASS")
