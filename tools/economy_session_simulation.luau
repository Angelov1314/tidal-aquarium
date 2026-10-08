-- Thin CLI for the bounded natural-session driver.
local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")
local rngFor = require("./economy_rng")
local Driver = require("./economy_session_driver")

local args = { ... }

local function fail(message)
	error(message, 0)
end

local function integer(value, option)
	local parsed = tonumber(value)
	if not parsed or math.floor(parsed) ~= parsed then fail(option .. " must be an integer") end
	return parsed
end

local function parseOptions()
	local options = {
		seed = 101,
		sessionMinutes = 60,
		days = 2,
		policy = "nurture",
		targetSpecies = "sand_goby",
		maxActions = 25000,
		milestoneEvery = 1800,
		stream = false,
	}
	local index = 1
	while index <= #args do
		local token = args[index]
		local key, inline = string.match(token, "^%-%-([%a%-]+)=(.*)$")
		if not key then key = string.match(token, "^%-%-([%a%-]+)$") end
		if not key then fail("unexpected positional argument: " .. token) end
		if key == "stream" then
			if inline ~= nil and inline ~= "true" then fail("--stream does not take a value") end
			options.stream = true
		else
			local value = inline
			if value == nil then
				index += 1
				value = args[index]
			end
			if value == nil or string.sub(value, 1, 2) == "--" then fail("--" .. key .. " requires a value") end
			if key == "seed" then options.seed = integer(value, "--seed")
			elseif key == "session-minutes" then options.sessionMinutes = integer(value, "--session-minutes")
			elseif key == "days" then options.days = integer(value, "--days")
			elseif key == "policy" then options.policy = value
			elseif key == "target-species" then options.targetSpecies = value
			elseif key == "max-actions" then options.maxActions = integer(value, "--max-actions")
			elseif key == "milestone-every" then options.milestoneEvery = integer(value, "--milestone-every")
			else fail("unknown option --" .. key) end
		end
		index += 1
	end
	return options
end

local function valueText(value)
	if value == nil then return nil end
	if type(value) == "boolean" then return value and "true" or "false" end
	return tostring(value)
end

local function mapSummary(values)
	local keys = {}
	for key in pairs(values or {}) do table.insert(keys, key) end
	table.sort(keys)
	if #keys == 0 then return "none" end
	local result = {}
	for _, key in ipairs(keys) do table.insert(result, key .. ":" .. tostring(values[key])) end
	return table.concat(result, ",")
end

local ROW_KEYS = {
	"policy", "targetSpecies", "day", "phase", "at", "offline", "zone", "discoveries", "dailyCaught", "contractDay",
	"targetOwnedLevel", "targetDiscoveredLevel", "targetUnits", "tankCapacity", "placed", "bag", "bagCapacity", "hooks",
	"coins", "incomePerHour", "actions", "catches", "merges", "replacements", "tankUpgrades", "boostStarts", "contractClaims",
	"offlineCreditedSeconds", "offlineUncreditedSeconds",
	"sourceIds", "acknowledgedPlacedIds", "outputId", "level",
	"sourceTrace", "outputTrace", "start", "finish", "lastSettled", "gapSeconds", "creditedSeconds", "uncreditedSeconds",
	"gained", "replayGained", "beforeBoostActive", "afterBoostActive", "beforeDiscoveries", "afterDiscoveries", "beforeFish", "afterFish",
	"beforeContractDay", "afterContractDay",
}

local function emitEvent(event)
	local fields = { event.kind }
	for _, key in ipairs(ROW_KEYS) do
		local value = valueText(event.row and event.row[key])
		if value ~= nil then table.insert(fields, key .. "=" .. value) end
	end
	print(table.concat(fields, "\t"))
end

local options = parseOptions()
local ok, optionError = Driver.validateOptions(options, Config)
if not ok then fail(optionError) end
print(string.format("ECONOMY_SESSION\tformatVersion=2\tseed=%d\tpolicy=%s\tsessionMinutes=%d\tdays=%d\ttargetSpecies=%s\tmaxActions=%d\tmilestoneEvery=%d\tactionTimeModel=zero_seconds\ttravelModel=not_simulated\tofflineRule=8h_at_50_percent", options.seed, options.policy, options.sessionMinutes, options.days, options.targetSpecies, options.maxActions, options.milestoneEvery))
local report = Driver.run(options, { Model = Model, Config = Config, rngFor = rngFor, emit = emitEvent })
if report.status == "error" then
	print("SESSION_CENSOR\tstatus=error\treason=" .. tostring(report.stopReason))
	fail("session run failed: " .. tostring(report.stopReason))
end

local final = report.final or {}
local stats = report.stats or {}
local failureCount = 0
for _, count in pairs(stats.failedByKind or {}) do failureCount += count end
print(string.format("SESSION_RESULT\tstatus=%s\tseed=%d\tpolicy=%s\tactions=%d\tzone=%s\tdiscoveries=%s\ttargetOwnedLevel=%s\ttargetDiscoveredLevel=%s\ttargetPlaced=%s\townedLevel10=%s\tdiscoveredLevel10=%s\tcoins=%s\tbaseUnits=%s\tbag=%s\tplaced=%s\ttankCapacity=%s\ttargetMerges=%s\tscheduledDays=%s\tcompletedDays=%s\tobservedDays=%s\tobservedAt=%s\tstopAt=%s\tsnapshotAt=%s\tlastSettled=%s\tstopReason=%s\tstopReasonClass=%s\tfailedActions=%d\tfailedByKind=%s\tpolicyStops=%s\tunlockReservations=%s\tunlockAttempts=%s", report.status, report.seed, report.policy, report.actionCount, tostring(final.zone), tostring(final.discoveries), tostring(final.targetOwnedLevel), tostring(final.targetDiscoveredLevel), tostring(final.targetPlaced), tostring(report.firstOwnedLevel10), tostring(report.firstDiscoveredLevel10), tostring(final.coins), tostring(final.baseUnits), tostring(final.bag), tostring(final.placed), tostring(final.tankCapacity), tostring(#(stats.targetMergeRecords or {})), tostring(report.scheduledDays), tostring(report.completedDays), tostring(report.observedDays), tostring(report.observedAt), tostring(report.stopAt), tostring(final.snapshotAt), tostring(final.lastSettled), tostring(report.stopReason), tostring(report.stopReasonClass), failureCount, mapSummary(stats.failedByKind), mapSummary(stats.policyStops), tostring(stats.unlockReservations or 0), tostring(stats.unlockAttempts or 0)))
print(string.format("SESSION_MONEY\tinitialCoins=%s\tpassiveIncome=%s\tsaleIncome=%s\tupgradeSpend=%s\tzoneSpend=%s\tcoinResidual=%s\tcoinResidualTolerance=0.000001\tofflineCreditedSeconds=%d\tofflineUncreditedSeconds=%d", tostring(report.initialCoins), tostring(stats.passiveIncome or 0), tostring(stats.saleIncome or 0), tostring(stats.upgradeSpend or 0), tostring(stats.zoneSpend or 0), tostring(final.coinResidual), stats.offlineCreditedSeconds or 0, stats.offlineUncreditedSeconds or 0))
print(string.format("SESSION_UNITS\tinitial=%s\tcatch=%s\tcontract=%s\tsold=%s\texchanged=%s\tmergeConsumed=%s\tmergeCreated=%s\tfinal=%s\tunitResidual=%s", tostring(report.initialBaseUnits), tostring(stats.catchUnits or 0), tostring(stats.contractUnits or 0), tostring(stats.soldUnits or 0), tostring(stats.exchangedUnits or 0), tostring(stats.mergeConsumedUnits or 0), tostring(stats.mergeCreatedUnits or 0), tostring(final.baseUnits), tostring(final.unitResidual)))
if report.status == "censored" then
	print(string.format("SESSION_CENSOR\tstatus=censored\treason=%s\tstopReasonClass=%s\tscheduledDays=%s\tcompletedDays=%s\tobservedDays=%s\tobservedAt=%s\tstopAt=%s\tsnapshotAt=%s\tlastSettled=%s", tostring(report.stopReason), tostring(report.stopReasonClass), tostring(report.scheduledDays), tostring(report.completedDays), tostring(report.observedDays), tostring(report.observedAt), tostring(report.stopAt), tostring(final.snapshotAt), tostring(final.lastSettled)))
end
print("ECONOMY_SESSION_END\tstatus=" .. tostring(report.status) .. "\tseed=" .. tostring(report.seed) .. "\tpolicy=" .. tostring(report.policy))
