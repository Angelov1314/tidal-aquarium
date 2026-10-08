-- Bounded natural-session driver for the G1 economy evidence slice.
-- This module intentionally receives Model/Config/RNG so tests and the CLI use
-- the same authoritative command, settlement, snapshot, and validation paths.
local Driver = {}

local OFFLINE_CAP_SECONDS = 8 * 3600
local EPSILON = 0.000001
local MANAGEMENT_INTERVAL_ROUNDS = 5

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
	return finite(value) and math.floor(value) == value
end

local function expect(condition, message)
	if not condition then error(message or "session driver assertion failed", 2) end
end

function Driver.classifyStopReason(reason)
	if reason == nil then return "none" end
	if reason == "max_actions" then return "action_budget" end
	if string.find(reason, "bag_full", 1, true) or string.find(reason, "bag_sell", 1, true) or reason == "contract_capacity" then
		return "capacity"
	end
	if string.find(reason, "catch:", 1, true) or string.find(reason, "settle:", 1, true) or string.find(reason, "snapshot:", 1, true) then
		return "command_failure"
	end
	if string.find(reason, "residual:", 1, true) or string.find(reason, "invalid_", 1, true) then return "error" end
	return "policy"
end

local function countFish(snapshot, placed)
	local count = 0
	for _, fish in ipairs(snapshot.fish or {}) do
		if placed == nil or fish.placed == placed then count += 1 end
	end
	return count
end

local function fishMap(snapshot)
	local result = {}
	for _, fish in ipairs(snapshot.fish or {}) do result[fish.id] = fish end
	return result
end

local function fishUnits(fish)
	return 3 ^ ((fish.level or 1) - 1)
end

function Driver.inventoryBaseUnits(snapshot)
	local total = 0
	for _, fish in ipairs(snapshot.fish or {}) do total += fishUnits(fish) end
	return total
end

local function maxFishLevel(snapshot, species)
	local highest = 0
	for _, fish in ipairs(snapshot.fish or {}) do
		if (species == nil or fish.species == species) and fish.level > highest then highest = fish.level end
	end
	return highest
end

local function maxDiscoveredLevel(snapshot, species)
	if species then return snapshot.discovered and snapshot.discovered[species] or 0 end
	local highest = 0
	for _, level in pairs(snapshot.discovered or {}) do if level > highest then highest = level end end
	return highest
end

local function fishById(snapshot, id)
	for _, fish in ipairs(snapshot.fish or {}) do if fish.id == id then return fish end end
	return nil
end

local function rowFor(snapshot, state, day, at, phase)
	local targetOwned = maxFishLevel(snapshot, state.targetSpecies)
	local targetDiscovered = maxDiscoveredLevel(snapshot, state.targetSpecies)
	return {
		day = day,
		phase = phase,
		at = at,
		zone = snapshot.zone,
		discoveries = snapshot.discoveryCount,
		dailyCaught = snapshot.dailyCaught,
		contractDay = snapshot.contractDay,
		targetOwnedLevel = targetOwned,
		targetDiscoveredLevel = targetDiscovered,
		targetUnits = state.targetUnits(snapshot),
		tankCapacity = snapshot.tankCapacity,
		placed = countFish(snapshot, true),
		bag = countFish(snapshot, false),
		bagCapacity = snapshot.bagCapacity,
		hooks = snapshot.hooks,
		coins = snapshot.coins,
		incomePerHour = snapshot.incomePerHour,
		actions = state.actionCount,
		catches = state.stats.catches,
		merges = state.stats.merges,
		replacements = state.stats.replacements,
		tankUpgrades = state.stats.tankUpgrades,
		boostStarts = state.stats.boostStarts,
		contractClaims = state.stats.contractClaims,
	}
end

function Driver.validateOptions(options, config)
	if type(options) ~= "table" then return false, "options must be a table" end
	if not integer(options.seed) then return false, "seed must be an integer" end
	if options.sessionMinutes ~= 30 and options.sessionMinutes ~= 60 and options.sessionMinutes ~= 90 then
		return false, "sessionMinutes must be 30, 60, or 90"
	end
	if not integer(options.days) or options.days < 1 or options.days > 45 then return false, "days must be in 1..45" end
	local policy = options.policy or "nurture"
	if policy ~= "sale" and policy ~= "nurture" then return false, "policy must be sale or nurture" end
	local targetSpecies = options.targetSpecies or "sand_goby"
	if type(targetSpecies) ~= "string" or not config or not config.SpeciesById or not config.SpeciesById[targetSpecies] then
		return false, "target species is unknown"
	end
	if not integer(options.maxActions) or options.maxActions <= 0 or options.maxActions > 5000000 then return false, "maxActions must be in 1..5000000" end
	if not integer(options.milestoneEvery) or options.milestoneEvery <= 0 then return false, "milestoneEvery must be positive" end
	return true
end

local function sortById(values)
	table.sort(values, function(a, b) return a.id < b.id end)
	return values
end

local function sortedCandidates(values, descending)
	table.sort(values, function(a, b)
		if a.income ~= b.income then
			if descending then return a.income > b.income end
			return a.income < b.income
		end
		if a.value ~= b.value then
			if descending then return a.value > b.value end
			return a.value < b.value
		end
		return a.id < b.id
	end)
	return values
end

local function copyArray(values)
	local copy = {}
	for index, value in ipairs(values) do copy[index] = value end
	return copy
end

local function tableHas(values, wanted)
	for _, value in ipairs(values) do if value == wanted then return true end end
	return false
end

function Driver.run(options, deps)
	deps = deps or {}
	local Model, Config, rngFor = deps.Model, deps.Config, deps.rngFor
	expect(Model and Config and rngFor, "Model, Config, and rngFor are required")
	local validOptions, optionError = Driver.validateOptions(options, Config)
	if not validOptions then return { status = "error", stopReason = optionError } end
	local policy = options.policy or "nurture"
	local targetSpecies = options.targetSpecies or "sand_goby"
	local emit = deps.emit or function() end
	local random = rngFor(options.seed)
	local profile = Model.new(0)
	local sessionSeconds = options.sessionMinutes * 60
	local report = {
		status = "running",
		stopReason = nil,
		seed = options.seed,
		policy = policy,
		sessionMinutes = options.sessionMinutes,
		days = options.days,
		scheduledDays = options.days,
		observedDays = 0,
		completedDays = 0,
		targetSpecies = targetSpecies,
		maxActions = options.maxActions,
		actionCount = 0,
		observedAt = 0,
		stopAt = nil,
		initialCoins = profile.coins,
		initialBaseUnits = nil,
		assumptions = {
			actionTimeModel = "zero_seconds",
			travelModel = "not_simulated",
			managementEveryRounds = MANAGEMENT_INTERVAL_ROUNDS,
			offlineRule = "8h_at_50_percent",
			policySale = "target_never_placed_and_capacity_sells",
			policyNurture = "target_may_be_placed_and_income_replaced",
		},
		sessions = {},
		firstOwnedLevel10 = nil,
		firstDiscoveredLevel10 = nil,
		firstTargetOwnedLevel10 = nil,
		firstTargetDiscoveredLevel10 = nil,
		final = nil,
	}
	local stats = {
		catches = 0,
		contracts = 0,
		merges = 0,
		mergeConsumedUnits = 0,
		mergeCreatedUnits = 0,
		catchUnits = 0,
		contractUnits = 0,
		soldUnits = 0,
		exchangedUnits = 0,
		passiveIncome = 0,
		saleIncome = 0,
		upgradeSpend = 0,
		zoneSpend = 0,
		replacements = 0,
		tankUpgrades = 0,
		boostStarts = 0,
		boostExpires = 0,
		boostKinds = {},
		targetMergeRecords = {},
		contractClaims = 0,
		actionsByKind = {},
		failedByKind = {},
		policyStops = {},
		unlockReservations = 0,
		unlockAttempts = 0,
		offlineCreditedSeconds = 0,
		offlineUncreditedSeconds = 0,
		offlineRecords = {},
	}
	local initialCoins = profile.coins
	local initialSnapshot = Model.snapshot(profile, 0)
	expect(initialSnapshot.ok, "initial snapshot failed")
	local initialUnits = Driver.inventoryBaseUnits(initialSnapshot)
	report.initialBaseUnits = initialUnits
	local previousBoostKinds = {}

	local state = {
		targetSpecies = targetSpecies,
		actionCount = 0,
		stats = stats,
		targetUnits = function(snapshot)
			local total = 0
			for _, fish in ipairs(snapshot.fish or {}) do if fish.species == targetSpecies then total += fishUnits(fish) end end
			return total
		end,
	}
	local roundSeconds = Config.RoundSeconds
	local lastActualAt = 0
	local observedAt = 0
	-- The candidate experiment owns a single detached snapshot slot.  The
	-- epoch is local to this Driver run and advances around every mutating
	-- Model call, including calls that return a failed result.
	local snapshotCacheStats = deps.snapshotCacheStats
	if type(snapshotCacheStats) == "table" then
		snapshotCacheStats.requests = 0
		snapshotCacheStats.cacheHits = 0
		snapshotCacheStats.cacheMisses = 0
		snapshotCacheStats.invalidations = 0
		snapshotCacheStats.failedSnapshots = 0
	end
	local profileEpoch = 0
	local cachedSnapshot = nil
	local cachedAt = nil
	local cachedEpoch = nil
	local cachedValid = false

	local function stop(reason, status)
		if not report.stopReason then report.stopReason = reason end
		if not report.stopAt then report.stopAt = observedAt end
		report.stopReasonClass = Driver.classifyStopReason(report.stopReason)
		if status then report.status = status end
	end

	local function policyStop(kind)
		stats.policyStops[kind] = (stats.policyStops[kind] or 0) + 1
	end
	if not integer(roundSeconds) or roundSeconds <= 0 then stop("invalid_round_seconds", "error") end

	local function incrementSnapshotStat(key)
		if type(snapshotCacheStats) == "table" then snapshotCacheStats[key] = (snapshotCacheStats[key] or 0) + 1 end
	end

	local function invalidateSnapshotCache()
		profileEpoch += 1
		cachedSnapshot = nil
		cachedAt = nil
		cachedEpoch = nil
		cachedValid = false
		incrementSnapshotStat("invalidations")
	end

	local function snapshot(at)
		incrementSnapshotStat("requests")
		if cachedValid and cachedEpoch == profileEpoch and cachedAt == at then
			incrementSnapshotStat("cacheHits")
			return cachedSnapshot
		end
		incrementSnapshotStat("cacheMisses")
		local result = Model.snapshot(profile, at)
		if not result.ok then
			incrementSnapshotStat("failedSnapshots")
			stop("snapshot:" .. tostring(result.message), "error")
			return nil
		end
		cachedSnapshot = result
		cachedAt = at
		cachedEpoch = profileEpoch
		cachedValid = true
		return result
	end

	local function validate(context)
		local valid, message = Model.validate(profile)
		if not valid then stop((context or "validate") .. ":" .. tostring(message), "error"); return false end
		return true
	end

	local function recordLevels(snap, at)
		local owned = maxFishLevel(snap)
		local discovered = maxDiscoveredLevel(snap)
		if owned >= 10 and not report.firstOwnedLevel10 then report.firstOwnedLevel10 = at end
		if discovered >= 10 and not report.firstDiscoveredLevel10 then report.firstDiscoveredLevel10 = at end
		local targetOwned = maxFishLevel(snap, targetSpecies)
		local targetDiscovered = maxDiscoveredLevel(snap, targetSpecies)
		if targetOwned >= 10 and not report.firstTargetOwnedLevel10 then report.firstTargetOwnedLevel10 = at end
		if targetDiscovered >= 10 and not report.firstTargetDiscoveredLevel10 then report.firstTargetDiscoveredLevel10 = at end
		for kind, active in pairs(snap.activeBoosts or {}) do
			if not previousBoostKinds[kind] then
				stats.boostStarts += 1
				stats.boostKinds[kind] = (stats.boostKinds[kind] or 0) + 1
			end
			previousBoostKinds[kind] = active.untilTime
		end
		for kind in pairs(previousBoostKinds) do
			if not (snap.activeBoosts or {})[kind] then stats.boostExpires += 1; previousBoostKinds[kind] = nil end
		end
	end

	local function emitRow(kind, snap, day, at, phase, extra)
		local row = rowFor(snap, state, day, at, phase)
		row.policy = policy
		row.targetSpecies = targetSpecies
		row.offlineCreditedSeconds = stats.offlineCreditedSeconds
		row.offlineUncreditedSeconds = stats.offlineUncreditedSeconds
		for key, value in pairs(extra or {}) do row[key] = value end
		emit({ kind = kind, row = row })
	end

	local function call(action, payload, at)
		if report.status ~= "running" then return nil, nil, nil end
		if state.actionCount >= options.maxActions then stop("max_actions", "censored"); return nil, nil, nil end
		local before = snapshot(at)
		if not before then return nil, nil, nil end
		local beforeMap = fishMap(before)
		local beforeCoins = profile.coins
		state.actionCount += 1
		lastActualAt = at
		observedAt = at
		report.actionCount = state.actionCount
		stats.actionsByKind[action] = (stats.actionsByKind[action] or 0) + 1
		local knownCost = 0
		if action == "upgrade" and before.upgrades[payload.kind] then knownCost = before.upgrades[payload.kind].cost or 0 end
		if action == "unlock" and Config.Zones[payload.zone] then knownCost = Config.Zones[payload.zone].cost or 0 end
		invalidateSnapshotCache()
		local result = Model.command(profile, action, payload or {}, at, random)
		invalidateSnapshotCache()
		local after = snapshot(at)
		if not after then return result, before, nil end
		local earned = result and result.earned or 0
		local coinDelta = profile.coins - beforeCoins
		local chargedCost = result and result.ok and knownCost or 0
		stats.passiveIncome += coinDelta - earned + chargedCost
		if action == "sell" and result and result.ok then stats.saleIncome += earned end
		if action == "upgrade" and result and result.ok then stats.upgradeSpend += knownCost end
		if action == "unlock" and result and result.ok then stats.zoneSpend += knownCost end
		if not result or not result.ok then
			local failureKey = action .. ":" .. tostring(result and result.message or "unknown")
			stats.failedByKind[failureKey] = (stats.failedByKind[failureKey] or 0) + 1
			recordLevels(after, at)
			return result, before, after
		end
		if action == "catch" then
			stats.catches += #(result.fish or {})
			for _, fish in ipairs(result.fish or {}) do stats.catchUnits += fishUnits(fish) end
		elseif action == "contract" then
			stats.contracts += 1
			stats.contractClaims += 1
			for _, fish in ipairs(result.fish or {}) do stats.contractUnits += fishUnits(fish) end
		elseif action == "sell" then
			local fish = beforeMap[payload.id]
			if fish then stats.soldUnits += fishUnits(fish) end
		elseif action == "exchange" then
			for _, id in ipairs(payload.ids or {}) do
				local fish = beforeMap[id]
				if fish then stats.exchangedUnits += fishUnits(fish) end
			end
		elseif action == "merge" then
			local removed, created = 0, 0
			local createdId, targetMerge = nil, false
			for _, id in ipairs(payload.ids or {}) do
				local fish = beforeMap[id]
				if fish and not fishMap(after)[id] then removed += fishUnits(fish) end
				if fish and fish.species == targetSpecies then targetMerge = true end
			end
			for _, fish in ipairs(after.fish or {}) do
				if not beforeMap[fish.id] then created += fishUnits(fish); createdId = fish.id end
			end
			stats.mergeConsumedUnits += removed
			stats.mergeCreatedUnits += created
			stats.merges += 1
			if targetMerge then
				local idsText, acknowledgements = {}, {}
				for _, id in ipairs(payload.ids or {}) do table.insert(idsText, id) end
				for _, id in ipairs(payload.acknowledgedPlacedIds or {}) do table.insert(acknowledgements, id) end
				local outputLevel
				for _, fish in ipairs(after.fish or {}) do if fish.id == createdId then outputLevel = fish.level; break end end
				local sourceTrace = {}
				for _, id in ipairs(payload.ids or {}) do
					local source = beforeMap[id]
					if source then table.insert(sourceTrace, table.concat({ source.id, source.species, source.level, source.value, source.income, source.catchSource, source.placed and "placed" or "bag" }, ":")) end
				end
				local outputTrace
				for _, fish in ipairs(after.fish or {}) do if fish.id == createdId then outputTrace = table.concat({ fish.id, fish.species, fish.level, fish.value, fish.income, fish.catchSource, fish.placed and "placed" or "bag" }, ":"); break end end
				local record = { at = at, sourceIds = table.concat(idsText, ","), acknowledgedPlacedIds = table.concat(acknowledgements, ","), sourceTrace = table.concat(sourceTrace, ";"), outputId = createdId, outputTrace = outputTrace, level = outputLevel }
				table.insert(stats.targetMergeRecords, record)
				emit({ kind = "TARGET_MERGE", row = record })
			end
			if removed ~= created then stop("merge_units:" .. tostring(removed) .. ":" .. tostring(created), "error") end
		elseif action == "remove" then
			-- A successful remove changes only placement; no ledger units move.
		elseif action == "place" then
			-- A successful place changes only placement; no ledger units move.
		end
		recordLevels(after, at)
		return result, before, after
	end

	local function settle(at, offline)
		if report.status ~= "running" then return nil end
		lastActualAt = at
		observedAt = at
		invalidateSnapshotCache()
		local result = Model.settle(profile, at, offline == true)
		invalidateSnapshotCache()
		if not result.ok then stop("settle:" .. tostring(result.message), "error"); return result end
		stats.passiveIncome += result.gained or 0
		return result
	end

	local function eligibleTargetGroups(snap)
		local groups = {}
		for _, fish in ipairs(snap.fish or {}) do
			if fish.species == targetSpecies and not fish.locked then
				groups[fish.level] = groups[fish.level] or {}
				table.insert(groups[fish.level], fish)
			end
		end
		return groups
	end

	local function mergeTarget(at)
		local changed = false
		local snap = snapshot(at)
		if not snap then return false end
		local groups = eligibleTargetGroups(snap)
		for level = 1, 9 do
			local group = groups[level]
			if group then
				sortById(group)
				while #group >= 3 and report.status == "running" do
					local sources = { table.remove(group, 1), table.remove(group, 1), table.remove(group, 1) }
					local ids, acknowledged = {}, {}
					for _, fish in ipairs(sources) do
						table.insert(ids, fish.id)
						if fish.placed then table.insert(acknowledged, fish.id) end
					end
					local result = call("merge", { ids = ids, acknowledgedPlacedIds = acknowledged }, at)
					if not result or not result.ok then break end
					changed = true
				end
			end
		end
		return changed
	end

	local function sellForCapacity(at, reserve)
		local changed = false
		reserve = reserve or 1
		while report.status == "running" do
			local snap = snapshot(at)
			if not snap then return changed end
			if countFish(snap, false) + reserve <= snap.bagCapacity then return changed end
			local candidates = {}
			for _, fish in ipairs(snap.fish or {}) do
				if not fish.placed and not fish.locked and fish.species ~= targetSpecies then table.insert(candidates, fish) end
			end
			sortedCandidates(candidates, false)
			local candidate = candidates[1]
			if not candidate then
				policyStop("capacity_protected_target")
				stop("bag_full_target_protected", "censored")
				return changed
			end
			local result = call("sell", { id = candidate.id, expectedSalePrice = candidate.salePrice }, at)
			if not result or not result.ok then stop("bag_sell_failed", "censored"); return changed end
			changed = true
		end
		return changed
	end

	local function placeHighestIncome(at)
		local changed = false
		local snap = snapshot(at)
		if not snap then return false end
		local candidates = {}
		for _, fish in ipairs(snap.fish or {}) do
			local allowTarget = policy == "nurture"
			if not fish.placed and not fish.locked and (allowTarget or fish.species ~= targetSpecies) then table.insert(candidates, fish) end
		end
		sortedCandidates(candidates, true)
		for _, candidate in ipairs(candidates) do
			if report.status ~= "running" then break end
			local current = snapshot(at)
			if not current then break end
			if countFish(current, true) < current.tankCapacity then
				local result = call("place", { id = candidate.id }, at)
				if result and result.ok then changed = true end
			else
				local placed = {}
				for _, fish in ipairs(current.fish or {}) do if fish.placed then table.insert(placed, fish) end end
				sortedCandidates(placed, false)
				local lowest = placed[1]
				if lowest and (candidate.income > lowest.income or (candidate.income == lowest.income and candidate.value > lowest.value)) then
					sellForCapacity(at, 1)
					local removed = call("remove", { id = lowest.id }, at)
					if removed and removed.ok then
						local result = call("place", { id = candidate.id }, at)
						if result and result.ok then stats.replacements += 1; changed = true end
					end
				end
			end
		end
		return changed
	end

	local function maybeBoost(at)
		local snap = snapshot(at)
		if not snap then return false end
		local recipe, ids
		for _, candidateRecipe in ipairs(Config.ExchangeRecipes or {}) do
			local item = Config.BoostItems[candidateRecipe.itemId]
			local kind = item and item.kind
			if kind and not (snap.activeBoosts or {})[kind] then
				local candidateIds = {}
				for _, fish in ipairs(snap.fish or {}) do
					local species = Config.SpeciesById[fish.species]
					if #candidateIds < (candidateRecipe.fishCount or 3) and fish.level == (candidateRecipe.requiredLevel or 1) and not fish.placed and not fish.locked and fish.species ~= targetSpecies and species and species.rarity >= (candidateRecipe.minRarity or 1) then table.insert(candidateIds, fish.id) end
				end
				if #candidateIds == (candidateRecipe.fishCount or 3) then recipe, ids = candidateRecipe, candidateIds; break end
			end
		end
		if not recipe then return false end
		local serial = tostring(state.actionCount + 1)
		local exchanged = call("exchange", { recipeId = recipe.id, ids = ids, requestId = "session-exchange-" .. serial }, at)
		if not exchanged or not exchanged.ok then return false end
		local itemId = recipe.itemId
		local used = call("useItem", { itemId = itemId, requestId = "session-use-" .. serial }, at)
		return used and used.ok or false
	end

	local function maybeClaimContract(at)
		local snap = snapshot(at)
		if not snap or snap.contractDay == snap.currentDay then return false end
		if not snap.discovered[targetSpecies] or snap.discoveryCount < 21 or snap.dailyCaught < 100 then
			policyStop("contract_gate_unmet")
			return false
		end
		if not sellForCapacity(at, 3) then
			local available = snapshot(at)
			if not available or countFish(available, false) + 3 > available.bagCapacity then
				policyStop("contract_capacity")
				return false
			end
		end
		local result = call("contract", { species = targetSpecies }, at)
		return result and result.ok or false
	end

	local function maybeUpgrade(at)
		local snap = snapshot(at)
		if not snap then return false end
		local reservedUnlockCost = 0
		if snap.zone < #Config.Zones then
			local nextZone = Config.Zones[snap.zone + 1]
			if nextZone and snap.discoveryCount >= (nextZone.requiredDiscoveries or 0) and (not nextZone.requiredLevel or snap.playerLevel >= nextZone.requiredLevel) then
				reservedUnlockCost = nextZone.cost or 0
				stats.unlockReservations += 1
			end
		end
		local kinds
		if policy == "nurture" then kinds = { "tank", "hooks", "bag", "luck", "coins" } else kinds = { "hooks", "bag", "luck", "coins" } end
		for _, kind in ipairs(kinds) do
			local info = snap.upgrades[kind]
			if info and info.cost and snap.coins - reservedUnlockCost + EPSILON >= info.cost then
				local result = call("upgrade", { kind = kind }, at)
				if result and result.ok then
					if kind == "tank" then stats.tankUpgrades += 1 end
					return true
				end
			end
		end
		return false
	end

	local function maybeUnlock(at)
		local snap = snapshot(at)
		if not snap or snap.zone >= #Config.Zones then return false end
		local nextZone = Config.Zones[snap.zone + 1]
		if not nextZone or snap.coins + EPSILON < (nextZone.cost or 0) or snap.discoveryCount < (nextZone.requiredDiscoveries or 0) then return false end
		if nextZone.requiredLevel and snap.playerLevel < nextZone.requiredLevel then return false end
		stats.unlockAttempts += 1
		local result = call("unlock", { zone = snap.zone + 1 }, at)
		return result and result.ok or false
	end

	local function manage(at)
		if report.status ~= "running" then return end
		mergeTarget(at)
		maybeClaimContract(at)
		maybeBoost(at)
		maybeUpgrade(at)
		maybeUnlock(at)
		local reserveSnapshot = snapshot(at)
		sellForCapacity(at, (reserveSnapshot and reserveSnapshot.hooks or 1) * MANAGEMENT_INTERVAL_ROUNDS)
		placeHighestIncome(at)
	end

	local function settleOffline(at, day, previousAt)
		local gap = math.max(0, at - previousAt)
		local before = snapshot(previousAt)
		local beforeLastSettled = profile.lastSettled
		local result = settle(at, true)
		if result then
			stats.offlineCreditedSeconds += math.min(gap, OFFLINE_CAP_SECONDS)
			stats.offlineUncreditedSeconds += math.max(0, gap - OFFLINE_CAP_SECONDS)
			local after = snapshot(at)
			invalidateSnapshotCache()
			local replay = Model.settle(profile, at, true)
			invalidateSnapshotCache()
			local afterReplay = snapshot(at)
			local record = {
				day = day,
				start = beforeLastSettled,
				finish = at,
				lastSettled = profile.lastSettled,
				gapSeconds = gap,
				creditedSeconds = math.min(gap, OFFLINE_CAP_SECONDS),
				uncreditedSeconds = math.max(0, gap - OFFLINE_CAP_SECONDS),
				gained = result.gained or 0,
				replayGained = replay and replay.gained or nil,
				beforeBoostActive = before and next(before.activeBoosts or {}) ~= nil or false,
				afterBoostActive = after and next(after.activeBoosts or {}) ~= nil or false,
				beforeDiscoveries = before and before.discoveryCount or nil,
				afterDiscoveries = afterReplay and afterReplay.discoveryCount or nil,
				beforeFish = before and #before.fish or nil,
				afterFish = afterReplay and #afterReplay.fish or nil,
				beforeContractDay = before and before.contractDay or nil,
				afterContractDay = afterReplay and afterReplay.contractDay or nil,
			}
			table.insert(stats.offlineRecords, record)
			emit({ kind = "OFFLINE_SETTLE", row = record })
		end
		return result, gap
	end

	local previousSessionEnd = 0
	local nextMilestone
	for day = 0, options.days - 1 do
		if report.status ~= "running" then break end
		local sessionStart = day * 86400
		if day > 0 then
			local offlineResult, gap = settleOffline(sessionStart, day, previousSessionEnd)
			if not offlineResult then break end
		end
		local sessionEnd = sessionStart + sessionSeconds
		nextMilestone = sessionStart + options.milestoneEvery
		local beforeSession = snapshot(sessionStart)
		if not beforeSession then break end
		report.observedDays += 1
		recordLevels(beforeSession, sessionStart)
		emitRow("SESSION_START", beforeSession, day, sessionStart, "start", { offline = day > 0 })
		local cursor = sessionStart
		observedAt = cursor
		manage(cursor)
		local roundIndex = 0
		while cursor + roundSeconds <= sessionEnd and report.status == "running" do
			-- Management actions are policy work, not player-time. Rechecking every
			-- five rounds keeps the real command path bounded without cloning the
			-- old runner's per-fish snapshot loop.
			if roundIndex > 0 and roundIndex % MANAGEMENT_INTERVAL_ROUNDS == 0 then manage(cursor) end
			if report.status ~= "running" then break end
			cursor += roundSeconds
			roundIndex += 1
			observedAt = cursor
			local snapBeforeCatch = snapshot(cursor)
			local result = call("catch", { zone = snapBeforeCatch and snapBeforeCatch.zone or 1 }, cursor)
			if not result or not result.ok then
				if report.status == "running" then stop("catch:" .. tostring(result and result.message or "unknown"), "censored") end
				break
			end
			if cursor >= nextMilestone then
				local milestone = snapshot(cursor)
				if milestone then
					recordLevels(milestone, cursor)
					emitRow("SESSION_MILESTONE", milestone, day, cursor, "milestone", {})
				end
				while nextMilestone <= cursor do nextMilestone += options.milestoneEvery end
			end
		end
		if report.status == "running" then
			manage(sessionEnd)
			local settled = settle(sessionEnd, false)
			if settled then
				local ending = snapshot(sessionEnd)
				if ending then
					recordLevels(ending, sessionEnd)
					local session = rowFor(ending, state, day, sessionEnd, "end")
					session.policy = policy
					session.targetSpecies = targetSpecies
					session.offlineCreditedSeconds = stats.offlineCreditedSeconds
					session.offlineUncreditedSeconds = stats.offlineUncreditedSeconds
					table.insert(report.sessions, session)
					emit({ kind = "SESSION_END", row = session })
				end
			end
		end
		previousSessionEnd = sessionEnd
	end

	local finalAt = lastActualAt
	local finalSnapshot = snapshot(finalAt)
	if finalSnapshot and validate("final") then
		recordLevels(finalSnapshot, finalAt)
		local finalUnits = Driver.inventoryBaseUnits(finalSnapshot)
		local expectedUnits = initialUnits + stats.catchUnits + stats.contractUnits - stats.soldUnits - stats.exchangedUnits - stats.mergeConsumedUnits + stats.mergeCreatedUnits
		local unitResidual = finalUnits - expectedUnits
		if math.abs(unitResidual) > EPSILON then stop("unit_residual:" .. tostring(unitResidual), "error") end
		local expectedCoins = initialCoins + stats.passiveIncome + stats.saleIncome - stats.upgradeSpend - stats.zoneSpend
		local coinResidual = profile.coins - expectedCoins
		if math.abs(coinResidual) > EPSILON then stop("coin_residual:" .. tostring(coinResidual), "error") end
		report.final = {
			at = finalAt,
			snapshotAt = finalAt,
			observedAt = observedAt,
			stopAt = report.stopAt,
			lastSettled = profile.lastSettled,
			zone = finalSnapshot.zone,
			discoveries = finalSnapshot.discoveryCount,
			ownedLevel10 = report.firstOwnedLevel10,
			discoveredLevel10 = report.firstDiscoveredLevel10,
			targetOwnedLevel = maxFishLevel(finalSnapshot, targetSpecies),
			targetDiscoveredLevel = maxDiscoveredLevel(finalSnapshot, targetSpecies),
			targetPlaced = 0,
			baseUnits = finalUnits,
			coins = finalSnapshot.coins,
			incomePerHour = finalSnapshot.incomePerHour,
			bag = countFish(finalSnapshot, false),
			placed = countFish(finalSnapshot, true),
			tankCapacity = finalSnapshot.tankCapacity,
			bagCapacity = finalSnapshot.bagCapacity,
			hooks = finalSnapshot.hooks,
			unitResidual = unitResidual,
			coinResidual = coinResidual,
		}
		for _, fish in ipairs(finalSnapshot.fish or {}) do if fish.species == targetSpecies and fish.placed then report.final.targetPlaced += 1 end end
	end
	if report.status == "running" then report.status = "completed" end
	report.actionCount = state.actionCount
	report.observedAt = observedAt
	if not report.stopAt then report.stopAt = observedAt end
	report.completedDays = #report.sessions
	report.stopReasonClass = Driver.classifyStopReason(report.stopReason)
	report.stats = stats
	report.baseUnits = report.final and report.final.baseUnits or nil
	report.coins = report.final and report.final.coins or profile.coins
	report.boosts = { starts = stats.boostStarts, expires = stats.boostExpires, kinds = stats.boostKinds }
	return report
end

return Driver
