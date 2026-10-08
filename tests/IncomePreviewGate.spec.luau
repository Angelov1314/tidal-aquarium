local Gate = require("../src/server/IncomePreviewGate")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local record = {lastRequest = 42}
expect(Gate.requestKind("detail") == "detail", "detail kind is preserved")
expect(Gate.requestKind("merge") == "merge", "merge kind is preserved")
expect(Gate.requestKind("sell") == "unknown", "arbitrary payload kind is sanitized")
expect(Gate.requestKind(nil) == "unknown", "missing payload kind is sanitized")
expect(Gate.allow(record, 10, 0.15), "first preview is accepted")
expect(record.incomePreviewLastRequest == 10 and record.lastRequest == 42, "preview gate has separate state")
expect(not Gate.allow(record, 10.1, 0.15), "preview burst is rejected")
expect(Gate.allow(record, 10.15, 0.15), "preview resumes after interval")
expect(not Gate.allow(record, math.huge, 0.15), "nonfinite server time is rejected")
print("IncomePreviewGate.spec: independent preview throttle PASS")
