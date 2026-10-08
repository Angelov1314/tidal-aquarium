--!strict
-- Ephemeral server-side gate for read-only income previews.  It deliberately
-- lives outside FishingService so the independent rate boundary is executable
-- in a pure test without constructing Roblox services or a player profile.
local IncomePreviewGate = {}

function IncomePreviewGate.requestKind(value: any): string
	return if value == "detail" or value == "merge" then value else "unknown"
end

function IncomePreviewGate.allow(record: any, at: number, interval: number?): boolean
	if type(record) ~= "table" or type(at) ~= "number" or at ~= at or at == math.huge or at == -math.huge then return false end
	local minimumInterval = if type(interval) == "number" and interval >= 0 then interval else 0.15
	local last = record.incomePreviewLastRequest
	if type(last) == "number" and at - last < minimumInterval then return false end
	record.incomePreviewLastRequest = at
	return true
end

return IncomePreviewGate
