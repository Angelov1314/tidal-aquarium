-- G1 economy baseline simulation.
--
-- This is an offline, pure-Luau harness.  It intentionally drives the same
-- Model.command/Model.settle/Model.snapshot APIs used by the server.  The
-- only direct profile edits are explicitly marked fixture setup: drop-rate
-- batches and invariant checks must not be read as new-player progression.

local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")
local rngFor = require("./economy_rng")

local args = { ... }

local ROUND_SECONDS = Config.RoundSeconds
local OFFLINE_SECONDS = 8 * 3600
local HORIZON_SECONDS = 2 * 3600
local MAX_CONFIGURED_HORIZON_SECONDS = 7 * 24 * 3600
local TRAVEL_SECONDS_PER_ZONE = 30
local SEEDS = { 101, 203, 307, 401, 503, 601, 709, 809 }
local SHORT_SEED = 424242
local SHORT_HORIZON = 10 * ROUND_SECONDS
local DROP_BATCHES = 200
local EPSILON = 0.000001

local function parseInteger(value, option)
	local number = tonumber(value)
	if not number or math.floor(number) ~= number then error(option .. " must be an integer", 0) end
	return number
end

local function parseOptions()
	local options = {
		mode = nil,
		seed = nil,
		strategy = nil,
		horizon = nil,
		milestoneEvery = nil,
		stream = false,
		pressure = false,
		hasConfiguredLongRun = false,
	}
	local index = 1
	while index <= #args do
		local token = args[index]
		local key, inlineValue = string.match(token, "^%-%-([%a%-]+)=(.*)$")
		if not key then key = string.match(token, "^%-%-([%a%-]+)$") end
		if key then
			local value = inlineValue
			if key == "stream" then
				if value ~= nil and value ~= "true" then error("--stream does not take a value", 0) end
				options.stream = true
			elseif key == "pressure" then
				if value ~= nil and value ~= "true" then error("--pressure does not take a value", 0) end
				options.pressure = true
			else
				if value == nil then
					index += 1
					value = args[index]
				end
				if value == nil or string.sub(value, 1, 2) == "--" then error("--" .. key .. " requires a value", 0) end
				if key == "seed" then
					options.seed = parseInteger(value, "--seed")
					options.hasConfiguredLongRun = true
				elseif key == "strategy" then
					options.strategy = value
					options.hasConfiguredLongRun = true
				elseif key == "horizon" then
					options.horizon = parseInteger(value, "--horizon")
					options.hasConfiguredLongRun = true
				elseif key == "milestone-every" then
					options.milestoneEvery = parseInteger(value, "--milestone-every")
					options.hasConfiguredLongRun = true
				else
					error("unknown option --" .. key, 0)
				end
			end
		else
			if options.mode ~= nil then error("unexpected positional argument: " .. token, 0) end
			options.mode = token
		end
		index += 1
	end
	options.mode = options.mode or "all"
	if options.strategy ~= nil and options.strategy ~= "regular" and options.strategy ~= "collection" and options.strategy ~= "optimized" and options.strategy ~= "atlas" then
		error("--strategy must be regular, collection, optimized, or atlas", 0)
	end
	if options.horizon ~= nil and (options.horizon <= 0 or options.horizon > MAX_CONFIGURED_HORIZON_SECONDS) then
		error("--horizon must be in 1..604800 seconds", 0)
	end
	if options.milestoneEvery ~= nil and options.milestoneEvery <= 0 then error("--milestone-every must be positive", 0) end
	if options.stream then options.hasConfiguredLongRun = true end
	if options.pressure then options.hasConfiguredLongRun = true end
	if options.hasConfiguredLongRun and options.mode ~= "long" then error("long-run selectors require mode=long", 0) end
	if options.hasConfiguredLongRun and (options.seed == nil or options.strategy == nil) then
		error("configured long runs require both --seed and --strategy", 0)
	end
	if options.pressure and options.strategy ~= "atlas" then
		error("--pressure requires --strategy=atlas", 0)
	end
	return options
end

local options = parseOptions()
local mode = options.mode

local function printf(format, ...)
	print(string.format(format, ...))
end

local function expect(condition, message)
	if not condition then error(message or "economy simulation assertion failed", 2) end
end

local function near(actual, expected, tolerance, message)
	expect(math.abs(actual - expected) <= tolerance, message or string.format("%.12f != %.12f", actual, expected))
end

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do table.insert(keys, key) end
	table.sort(keys)
	return keys
end

local function rarityIndexForFish(fish)
	local species = Config.SpeciesById[fish.species]
	return species and species.rarity or 0
end

local function rarityName(index)
	local rarity = Config.Rarities[index]
	return rarity and rarity.name or "?"
end

local function countFish(snapshot, placed)
	local count = 0
	for _, fish in ipairs(snapshot.fish) do
		if placed == nil or fish.placed == placed then count += 1 end
	end
	return count
end

local function copyArray(values)
	local result = {}
	for index, value in ipairs(values) do result[index] = value end
	return result
end

local function mapFish(snapshot)
	local byId = {}
	for _, fish in ipairs(snapshot.fish) do byId[fish.id] = fish end
	return byId
end

local function profileSnapshot(sim)
	local snapshot = Model.snapshot(sim.profile, sim.now)
	expect(snapshot.ok, "snapshot failed: " .. tostring(snapshot.message))
	return snapshot
end

local function validProfile(sim, context)
	local valid, message = Model.validate(sim.profile)
	expect(valid, (context or "profile") .. ": " .. tostring(message))
	return true
end

-- Reward-pressure branches operate on a deep copy taken immediately after a
-- real contract command.  They are diagnostic counterfactuals: every mutation
-- still goes through Model.command, while the natural run's profile is never
-- changed by the branch.
local function cloneDiagnostic(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do copy[cloneDiagnostic(key, seen)] = cloneDiagnostic(item, seen) end
	return copy
end

local function snapshotForPressure(profile, now, context)
	local valid, message = Model.validate(profile)
	expect(valid, (context or "pressure profile") .. ": " .. tostring(message))
	local snapshot = Model.snapshot(profile, now)
	expect(snapshot.ok, (context or "pressure snapshot") .. ": " .. tostring(snapshot.message))
	return snapshot
end

local function pressureAssets(snapshot)
	return string.format(
		"coins=%.2f	hooks=%d	bag=%d	bagCapacity=%d	placed=%d	tankCapacity=%d	fish=%d	incomePerHour=%.6f",
		snapshot.coins,
		snapshot.hooks,
		countFish(snapshot, false),
		snapshot.bagCapacity,
		countFish(snapshot, true),
		snapshot.tankCapacity,
		#snapshot.fish,
		snapshot.incomePerHour
	)
end

local function pressureFindFish(snapshot, id)
	for _, fish in ipairs(snapshot.fish) do if fish.id == id then return fish end end
	return nil
end

local function pressureLowestPlaced(snapshot)
	local best
	for _, fish in ipairs(snapshot.fish) do
		if fish.placed and not fish.locked then
			if not best or fish.income < best.income or (fish.income == best.income and fish.id < best.id) then best = fish end
		end
	end
	if best then return best end
	for _, fish in ipairs(snapshot.fish) do
		if fish.placed and (not best or fish.income < best.income or (fish.income == best.income and fish.id < best.id)) then best = fish end
	end
	return best
end

local function pressureUpgradeHooks(profile, now, random)
	local before = snapshotForPressure(profile, now, "hook pressure before")
	local startingCoins, startingHooks = before.coins, before.hooks
	local purchased, spent, stopReason = 0, 0, "unknown"
	while true do
		local snapshot = snapshotForPressure(profile, now, "hook pressure step")
		if snapshot.hooks >= Config.MaxHooks then
			stopReason = "max_hooks"
			before = snapshot
			break
		end
		local info = snapshot.upgrades.hooks
		if not info or not info.cost then
			stopReason = "no_hook_upgrade"
			before = snapshot
			break
		end
		local result = Model.command(profile, "upgrade", { kind = "hooks" }, now, random)
		if not result.ok then
			stopReason = tostring(result.message)
			before = snapshotForPressure(profile, now, "hook pressure rejected")
			break
		end
		purchased += 1
		spent += info.cost
	end
	local after = snapshotForPressure(profile, now, "hook pressure after")
	return {
		startingCoins = startingCoins,
		startingHooks = startingHooks,
		purchased = purchased,
		spent = spent,
		stopReason = stopReason,
		after = after,
	}
end

local function runRewardPressureBranches(sim, contractTarget, rewardFish)
	local rewardIds = {}
	for _, fish in ipairs(rewardFish or {}) do table.insert(rewardIds, fish.id) end
	if #rewardIds ~= 3 then error("reward pressure requires exactly three contract fish", 0) end
	local firstReward = rewardFish[1]
	local species = Config.SpeciesById[contractTarget]
	local rarity = species and Config.Rarities[species.rarity]
	printf(
		"REWARD_PRESSURE\tstrategy=%s\tseed=%d\tcontractAt=%d\ttarget=%s\ttargetRarity=%d\trewardCount=%d\trewardLevel=%d\trewardValueEach=%.2f\trewardIncomeEachPerHour=%.6f\tbranchSource=natural_contract_profile_copy",
		sim.strategy,
		sim.seed,
		sim.now,
		contractTarget,
		species and species.rarity or 0,
		#rewardIds,
		firstReward.level,
		firstReward.value,
		firstReward.income
	)
	for _, branch in ipairs({ "place", "sell" }) do
		local profile = cloneDiagnostic(sim.profile)
		local before = snapshotForPressure(profile, sim.now, branch .. " branch before")
		local mergedResult = Model.command(profile, "merge", { ids = rewardIds }, sim.now, rngFor(sim.seed + (branch == "place" and 17001 or 17002)))
		expect(mergedResult.ok and mergedResult.fish and mergedResult.fish[1], branch .. " branch merge failed")
		local merged = mergedResult.fish[1]
		local mergedSnapshot = snapshotForPressure(profile, sim.now, branch .. " branch merged")
		local mergedCurrent = pressureFindFish(mergedSnapshot, merged.id)
		expect(mergedCurrent ~= nil, branch .. " branch merged fish missing")
		local saleQuote = Model.salePrice(profile, mergedCurrent, sim.now)
		local removed = "none"
		local operation = "none"
		local operationResult = nil
		if branch == "place" then
			local low = pressureLowestPlaced(mergedSnapshot)
			if low then
				removed = low.id
				operationResult = Model.command(profile, "remove", { id = low.id }, sim.now, rngFor(sim.seed + 17003))
				expect(operationResult.ok, "place branch remove failed: " .. tostring(operationResult.message))
				operation = "remove_low_income_then_place_merged_reward"
				operationResult = Model.command(profile, "place", { id = merged.id }, sim.now, rngFor(sim.seed + 17004))
				expect(operationResult.ok, "place branch place failed: " .. tostring(operationResult.message))
			else
				operation = "skipped_missing_placed_fish"
			end
		else
			operation = "sell_merged_reward"
			operationResult = Model.command(profile, "sell", { id = merged.id }, sim.now, rngFor(sim.seed + 17005))
			expect(operationResult.ok, "sell branch sale failed: " .. tostring(operationResult.message))
		end
		local afterOperation = snapshotForPressure(profile, sim.now, branch .. " branch operation")
		local hookProbe = pressureUpgradeHooks(profile, sim.now, rngFor(sim.seed + (branch == "place" and 17006 or 17007)))
		local afterHooks = hookProbe.after
		printf(
			"REWARD_PRESSURE_BRANCH\tstrategy=%s\tseed=%d\tbranch=%s\tstatus=%s\toperation=%s\tremovedFish=%s\tmergedFish=%s\tmergedLevel=%d\tmergedValue=%.2f\tmergedIncomePerHour=%.6f\tsaleQuote=%.2f\tsaleEarned=%s\tbefore{%s}\tafterOperation{%s}\thookProbeStartingCoins=%.2f\thookProbeStartingHooks=%d\thooksPurchased=%d\thookSpend=%.2f\thookStop=%s\tafterHooks{%s}",
			sim.strategy,
			sim.seed,
			branch,
			operationResult == nil and "skipped" or "completed",
			operation,
			removed,
			merged.id,
			merged.level,
			merged.value,
			merged.income,
			saleQuote,
			operationResult and operationResult.salePrice and string.format("%.2f", operationResult.salePrice) or "none",
			pressureAssets(before),
			pressureAssets(afterOperation),
			hookProbe.startingCoins,
			hookProbe.startingHooks,
			hookProbe.purchased,
			hookProbe.spent,
			hookProbe.stopReason,
			pressureAssets(afterHooks)
		)
	end
end

local function highestFishLevel(snapshot)
	local highest = 0
	for _, level in pairs(snapshot.discovered) do
		if level > highest then highest = level end
	end
	for _, fish in ipairs(snapshot.fish) do
		if fish.level > highest then highest = fish.level end
	end
	return highest
end

local function makeMilestoneObserver(strategy, seed, horizon, interval)
	local nextPeriodic = interval
	local emittedCheckpoints = {}
	local emittedEvents = {}
	local checkpoints = {
		{ label = "time25pct", at = math.floor(horizon * 0.25) },
		{ label = "time50pct", at = math.floor(horizon * 0.50) },
		{ label = "time75pct", at = math.floor(horizon * 0.75) },
	}
	local events = { "zone9", "discoveries70", "level10" }

	local function emit(sim, snapshot, kind, label, reached, scheduledAt, status)
		printf(
			"MILESTONE\tstrategy=%s\tseed=%d\thorizon=%d\tkind=%s\tlabel=%s\treached=%s\tstatus=%s\tscheduledAt=%d\tobservedAt=%d\tzone=%d\tdiscoveries=%d\tplayerLevel=%d\tmaxFishLevel=%d\tcoins=%.2f\tbag=%d\tbagCapacity=%d\thooks=%d\tcatchCalls=%d\tfishCaught=%d\tstopReason=%s",
			strategy,
			seed,
			horizon,
			kind,
			label,
			tostring(reached),
			status,
			scheduledAt,
			sim.now,
			snapshot.zone,
			snapshot.discoveryCount,
			snapshot.playerLevel,
			highestFishLevel(snapshot),
			snapshot.coins,
			countFish(snapshot, false),
			snapshot.bagCapacity,
			snapshot.hooks,
			sim.stats.catchCalls,
			sim.stats.fishCaught,
			tostring(sim.stopReason or "none")
		)
	end

	local function eventReached(snapshot, label)
		if label == "zone9" then return snapshot.zone >= 9 end
		if label == "discoveries70" then return snapshot.discoveryCount >= 70 end
		if label == "level10" then return highestFishLevel(snapshot) >= 10 end
		return false
	end

	return function(sim, snapshot, reason)
		while nextPeriodic <= horizon and nextPeriodic <= sim.now do
			local duplicateCheckpoint = false
			for _, checkpoint in ipairs(checkpoints) do
				if checkpoint.at == nextPeriodic then duplicateCheckpoint = true; break end
			end
			if not duplicateCheckpoint then
				emit(sim, snapshot, "time", "periodic", true, nextPeriodic, "observed")
			end
			nextPeriodic += interval
		end
		for index, checkpoint in ipairs(checkpoints) do
			if not emittedCheckpoints[index] and sim.now >= checkpoint.at then
				emittedCheckpoints[index] = true
				emit(sim, snapshot, "time", checkpoint.label, true, checkpoint.at, "observed")
			end
		end
		for _, label in ipairs(events) do
			if not emittedEvents[label] and eventReached(snapshot, label) then
				emittedEvents[label] = true
				emit(sim, snapshot, "event", label, true, sim.now, "observed")
			end
		end
		if reason ~= "final" then return end
		for index, checkpoint in ipairs(checkpoints) do
			if not emittedCheckpoints[index] then
				emittedCheckpoints[index] = true
				emit(sim, snapshot, "time", checkpoint.label, false, checkpoint.at, "censored")
			end
		end
		for _, label in ipairs(events) do
			if not emittedEvents[label] then
				emittedEvents[label] = true
				emit(sim, snapshot, "event", label, false, horizon, "censored")
			end
		end
		local completed = not sim.stopped and sim.endAt >= horizon
		emit(sim, snapshot, "terminal", "run", completed, horizon, completed and "completed" or "censored")
	end
end

local function increment(map, key, amount)
	map[key] = (map[key] or 0) + (amount or 1)
end

local function makeRun(strategy, seed, horizon, observer, pressureEnabled)
	local profile = Model.new(0)
	return {
		strategy = strategy,
		seed = seed,
		horizon = horizon,
		profile = profile,
		now = 0,
		observer = observer,
		pressureEnabled = pressureEnabled == true,
		currentCatchZone = 1,
		random = rngFor(seed),
		requestSerial = 0,
		stopped = false,
		stopReason = nil,
		stats = {
			initialCoins = profile.coins,
			actions = {},
			failed = {},
			catchCalls = 0,
			fishCaught = 0,
			fishSold = 0,
			fishMerged = 0,
			mergeByLevel = {},
			passiveIncome = 0,
			saleIncome = 0,
			upgradeSpend = 0,
			zoneSpend = 0,
			contractClaims = 0,
			contractFailures = 0,
			contractTarget = nil,
			contractTargetPolicy = strategy == "atlas" and "highestValueDiscovered" or "firstDiscovered",
			rewardPressureCaptured = false,
			exchanges = {},
			itemUses = {},
			bagFullStops = 0,
			firstRareTime = nil,
			firstRareSpecies = nil,
			firstCatchTime = nil,
			lastCatchTime = nil,
			firstDiscovery70Time = nil,
			firstLevel10Time = nil,
			zoneUnlockTimes = {},
			offlineGain = 0,
			offlineRepeatGain = 0,
			travelSeconds = 0,
			coinsAtEnd = nil,
			coinsAfterOffline = nil,
			endIncomePerHour = nil,
			offlineReturnIncomePerHour = nil,
			accountingDifference = nil,
			travelTruncated = false,
		}
	}
end

local function recordDiscoveryMilestones(sim, snapshot)
	local stats = sim.stats
	if snapshot.discoveryCount >= 70 and not stats.firstDiscovery70Time then stats.firstDiscovery70Time = sim.now end
	if not stats.firstLevel10Time then
		for _, level in pairs(snapshot.discovered) do
			if level >= 10 then stats.firstLevel10Time = sim.now; break end
		end
	end
	for _, fish in ipairs(snapshot.fish) do
		if rarityIndexForFish(fish) >= 3 and not stats.firstRareTime then
			stats.firstRareTime, stats.firstRareSpecies = sim.now, fish.species
		end
		if fish.level >= 10 and not stats.firstLevel10Time then stats.firstLevel10Time = sim.now end
	end
end

local function issue(sim, action, payload)
	local stats = sim.stats
	local beforeCoins = sim.profile.coins
	local beforeSnapshot = profileSnapshot(sim)
	local result = Model.command(sim.profile, action, payload or {}, sim.now, sim.random)
	local afterCoins = sim.profile.coins
	local coinDelta = afterCoins - beforeCoins
	increment(stats.actions, action)
	local knownCost = 0
	if action == "upgrade" then
		local upgrade = beforeSnapshot.upgrades[payload.kind]
		knownCost = upgrade and upgrade.cost or 0
	elseif action == "unlock" then
		local zone = Config.Zones[payload.zone]
		knownCost = zone and zone.cost or 0
	end
	-- Commands settle passive aquarium income before their own mutation.  The
	-- delta can therefore include a sale/reward or an upgrade/unlock spend.
	-- Classify it here instead of treating every positive delta as passive.
	if action == "sell" or action == "sellDuplicates" then
		local earned = result.earned or 0
		if coinDelta - earned > EPSILON then stats.passiveIncome += coinDelta - earned end
	elseif action == "upgrade" or action == "unlock" then
		if result.ok and coinDelta + knownCost > EPSILON then
			stats.passiveIncome += coinDelta + knownCost
		elseif not result.ok and coinDelta > EPSILON then
			stats.passiveIncome += coinDelta
		end
	elseif coinDelta > EPSILON then
		stats.passiveIncome += coinDelta
	end
	if not result.ok then
		increment(stats.failed, action .. ":" .. tostring(result.message))
		validProfile(sim, action .. " rejected")
		return result, beforeSnapshot
	end
	if action == "sell" or action == "sellDuplicates" then
		local earned = result.earned or 0
		stats.saleIncome += earned
		stats.fishSold += result.soldCount or 1
	elseif action == "upgrade" then
		if knownCost > 0 then stats.upgradeSpend += knownCost end
	elseif action == "unlock" then
		local zone = Config.Zones[payload.zone]
		if zone then stats.zoneSpend += zone.cost end
		stats.zoneUnlockTimes[payload.zone] = sim.now
	elseif action == "merge" then
		stats.fishMerged += 1
		local output = result.fish and result.fish[1]
		if output then increment(stats.mergeByLevel, tostring(output.level)) end
	elseif action == "catch" then
		stats.catchCalls += 1
		stats.fishCaught += #(result.fish or {})
		stats.firstCatchTime = stats.firstCatchTime or sim.now
		stats.lastCatchTime = sim.now
		for _, fish in ipairs(result.fish or {}) do
			if rarityIndexForFish(fish) >= 3 and not stats.firstRareTime then
				stats.firstRareTime, stats.firstRareSpecies = sim.now, fish.species
			end
		end
	elseif action == "contract" then
		stats.contractClaims += 1
	elseif action == "exchange" then
		increment(stats.exchanges, result.itemId or payload.recipeId)
	elseif action == "useItem" then
		increment(stats.itemUses, result.itemId or payload.itemId)
	end
	local afterSnapshot = profileSnapshot(sim)
	recordDiscoveryMilestones(sim, afterSnapshot)
	validProfile(sim, action)
	if sim.observer then sim.observer(sim, afterSnapshot, "command:" .. action) end
	return result, afterSnapshot
end

local function settle(sim, at, offline)
	local beforeCoins = sim.profile.coins
	local result = Model.settle(sim.profile, at, offline == true)
	expect(result.ok, "settle failed: " .. tostring(result.message))
	local delta = sim.profile.coins - beforeCoins
	if delta > 0 then sim.stats.passiveIncome += delta end
	sim.now = at
	validProfile(sim, offline and "offline settle" or "settle")
	return result
end

local function fishGroups(snapshot, predicate)
	local groups = {}
	for _, fish in ipairs(snapshot.fish) do
		if (not predicate or predicate(fish)) then
			groups[fish.species] = groups[fish.species] or {}
			table.insert(groups[fish.species], fish)
		end
	end
	return groups
end

local function atlasCatchZoneForSpecies(snapshot, species)
	local legacyZone = 1
	for zone = 1, snapshot.zone do
		local definition = Config.Zones[zone]
		if not definition or definition.themeOnly ~= true then legacyZone = zone end
	end
	local definition = Config.Zones[species.zone]
	if definition and definition.themeOnly == true then return species.zone end
	return legacyZone
end

local function chooseAtlasCatchZone(snapshot)
	local targetZone
	for _, species in ipairs(Config.Species) do
		if species.zone <= snapshot.zone and not snapshot.discovered[species.id] then
			local catchZone = atlasCatchZoneForSpecies(snapshot, species)
			if not targetZone or catchZone < targetZone then targetZone = catchZone end
		end
	end
	return targetZone or snapshot.zone
end

local function atlasMissingByAuthorZone(snapshot)
	local missing = {}
	for _, species in ipairs(Config.Species) do
		if species.zone <= snapshot.zone and not snapshot.discovered[species.id] then
			missing[species.zone] = missing[species.zone] or {}
			table.insert(missing[species.zone], species.id)
		end
	end
	local groups = {}
	for _, zone in ipairs(sortedKeys(missing)) do
		table.sort(missing[zone])
		table.insert(groups, tostring(zone) .. ":" .. table.concat(missing[zone], ","))
	end
	return #groups > 0 and table.concat(groups, ";") or "none"
end

local function mergeAvailable(sim, aggressive)
	if not aggressive then return end
	for level = 1, 9 do
		local changed = true
		while changed do
			changed = false
			local snapshot = profileSnapshot(sim)
			local groups = fishGroups(snapshot, function(fish)
				return fish.level == level and not fish.placed and not fish.locked
			end)
			for _, species in ipairs(sortedKeys(groups)) do
				local group = groups[species]
				while #group >= 3 do
					local ids = { group[1].id, group[2].id, group[3].id }
					local result = issue(sim, "merge", { ids = ids })
					if not result.ok then break end
					changed = true
					for _ = 1, 3 do table.remove(group, 1) end
				end
			end
		end
	end
end

local function highestIncomeFish(snapshot, candidates)
	local best
	for _, fish in ipairs(candidates) do
		if not best or fish.income > best.income or (fish.income == best.income and fish.value > best.value) then best = fish end
	end
	return best
end

local function placeUseful(sim)
	local snapshot = profileSnapshot(sim)
	local candidates = {}
	for _, fish in ipairs(snapshot.fish) do
		if not fish.placed and not fish.locked then table.insert(candidates, fish) end
	end
	table.sort(candidates, function(a, b)
		if a.income ~= b.income then return a.income > b.income end
		if a.value ~= b.value then return a.value > b.value end
		return a.id < b.id
	end)
	for _, fish in ipairs(candidates) do
		local current = profileSnapshot(sim)
		if countFish(current, true) >= current.tankCapacity then break end
		-- Keeping the first representative of every discovered species makes
		-- the collection policy auditable; merged or high-income fish fill spare
		-- tank slots for the other policies.
		local shouldPlace = fish.level > 1 or sim.strategy ~= "collection" or current.discovered[fish.species] == 1
		if shouldPlace then issue(sim, "place", { id = fish.id }) end
	end
end

local function protectedRepresentatives(snapshot, strategy)
	local keep = {}
	local bestBySpecies = {}
	for _, fish in ipairs(snapshot.fish) do
		if not fish.placed and not fish.locked then
			local best = bestBySpecies[fish.species]
			if not best or fish.level > best.level or (fish.level == best.level and fish.value > best.value) then bestBySpecies[fish.species] = fish end
		end
	end
	for species, fish in pairs(bestBySpecies) do keep[fish.id] = true end
	if strategy == "collection" then
		-- Collection keeps all currently unplaced fish.  This deliberately lets
		-- capacity become a measured stopping constraint instead of selling it.
		for _, fish in ipairs(snapshot.fish) do if not fish.placed then keep[fish.id] = true end end
	end
	return keep
end

local function sellExcess(sim, force)
	local snapshot = profileSnapshot(sim)
	local bagCount = countFish(snapshot, false)
	local threshold = force and 0 or math.floor(snapshot.bagCapacity * 0.75)
	if bagCount < threshold then return 0 end
	local keep = protectedRepresentatives(snapshot, sim.strategy)
	local sold = 0
	for _, fish in ipairs(snapshot.fish) do
		if not fish.placed and not fish.locked and not keep[fish.id] then
			local result = issue(sim, "sell", { id = fish.id })
			if result.ok then sold += 1 end
		end
	end
	return sold
end

local function eligibleForRecipe(snapshot, recipeId)
	local recipe
	for _, item in ipairs(Config.ExchangeRecipes) do if item.id == recipeId then recipe = item; break end end
	if not recipe then return {} end
	local result = {}
	for _, fish in ipairs(snapshot.fish) do
		local rarity = rarityIndexForFish(fish)
		if not fish.placed and not fish.locked and fish.level == (recipe.requiredLevel or 1) and rarity >= (recipe.minRarity or 1) then
			table.insert(result, fish)
		end
	end
	table.sort(result, function(a, b) return a.id < b.id end)
	return result
end

local function maybeBoost(sim)
	if sim.strategy == "collection" then return end
	local snapshot = profileSnapshot(sim)
	local priority = (sim.strategy == "optimized" or sim.strategy == "atlas") and { "exchange_luck", "exchange_coins", "exchange_xp" } or { "exchange_luck" }
	for _, recipeId in ipairs(priority) do
		local kind = string.sub(recipeId, 10)
		if kind == "luck" then kind = "luck" elseif kind == "coins" then kind = "coins" else kind = "xp" end
		local active = snapshot.activeBoosts[kind]
		local itemId = kind == "luck" and "luck_tonic" or (kind == "coins" and "coin_tonic" or "xp_tonic")
		local items = eligibleForRecipe(snapshot, recipeId)
		if not active and #items >= 3 then
			sim.requestSerial += 1
			local ids = { items[1].id, items[2].id, items[3].id }
			local exchanged = issue(sim, "exchange", { recipeId = recipeId, ids = ids, requestId = sim.strategy .. ":exchange:" .. tostring(sim.requestSerial) })
			if exchanged.ok then
				sim.requestSerial += 1
				issue(sim, "useItem", { itemId = itemId, requestId = sim.strategy .. ":use:" .. tostring(sim.requestSerial) })
				return
			end
		end
	end
end

local function claimContract(sim)
	local snapshot = profileSnapshot(sim)
	if snapshot.contractDay == math.floor(sim.now / 86400) then return end
	if snapshot.discoveryCount < 21 or snapshot.dailyCaught < 100 then return end
	local target
	if sim.strategy == "atlas" then
		local bestValue = -1
		for _, species in ipairs(Config.Species) do
			if snapshot.discovered[species.id] then
				local rarity = Config.Rarities[species.rarity]
				local value = rarity and rarity.sell or 0
				if value > bestValue or (value == bestValue and (not target or species.id < target)) then
					target, bestValue = species.id, value
				end
			end
		end
	else
		for _, species in ipairs(Config.Species) do
			if snapshot.discovered[species.id] then target = species.id; break end
		end
	end
	if target then
		sim.stats.contractTarget = target
		local result = issue(sim, "contract", { species = target })
		if not result.ok then
			sim.stats.contractFailures += 1
		elseif sim.pressureEnabled and not sim.stats.rewardPressureCaptured then
			sim.stats.rewardPressureCaptured = true
			runRewardPressureBranches(sim, target, result.fish)
		end
	end
end

local function canUnlockNext(sim, snapshot)
	local nextZone = snapshot.zone + 1
	local zone = Config.Zones[nextZone]
	if not zone then return false end
	if zone.requiredLevel and snapshot.playerLevel < zone.requiredLevel then return false end
	if snapshot.discoveryCount < (zone.requiredDiscoveries or 0) then return false end
	return true
end

local function tryUnlock(sim)
	while true do
		if sim.now >= sim.horizon then return end
		local snapshot = profileSnapshot(sim)
		local zone = Config.Zones[snapshot.zone + 1]
		if not zone or not canUnlockNext(sim, snapshot) or snapshot.coins + EPSILON < zone.cost then return end
		local result = issue(sim, "unlock", { zone = zone.id })
		if not result.ok then return end
		-- Model has no travel command.  This is the explicit simulation
		-- assumption used in the report; settlement during the trip remains
		-- server-authoritative via Model.settle.
		local arrival = math.min(sim.now + TRAVEL_SECONDS_PER_ZONE, sim.horizon)
		sim.stats.travelSeconds += arrival - sim.now
		if arrival < sim.now + TRAVEL_SECONDS_PER_ZONE then sim.stats.travelTruncated = true end
		settle(sim, arrival, false)
		sim.currentCatchZone = zone.id
		if sim.now >= sim.horizon then return end
	end
end

local function upgradePriority(strategy, snapshot)
	if strategy == "collection" then return { "hooks", "coins" } end
	if strategy == "optimized" or strategy == "atlas" then
		if snapshot.hooks < 25 then return { "hooks", "coins", "luck", "bag" } end
		return { "hooks", "coins", "luck", "bag" }
	end
	return { "hooks", "coins", "luck" }
end

local function tryUpgrades(sim)
	local guard = 0
	while guard < 16 do
		guard += 1
		local snapshot = profileSnapshot(sim)
		local reserve = 0
		local nextZone = Config.Zones[snapshot.zone + 1]
		if nextZone and canUnlockNext(sim, snapshot) then reserve = nextZone.cost end
		local upgraded = false
		for _, kind in ipairs(upgradePriority(sim.strategy, snapshot)) do
			local info = snapshot.upgrades[kind]
			if info and info.cost and snapshot.coins + EPSILON >= info.cost and snapshot.coins - info.cost + EPSILON >= reserve then
				local result = issue(sim, "upgrade", { kind = kind })
				if result.ok then upgraded = true; break end
			end
		end
		if not upgraded then break end
	end
end

local function manage(sim, beforeCatch)
	-- Order keeps command permissions and settlement visible: merge/capacity,
	-- then collection action, then rewards/boosts and finally growth spending.
	if sim.strategy == "optimized" or sim.strategy == "regular" or sim.strategy == "atlas" then mergeAvailable(sim, true) end
	placeUseful(sim)
	claimContract(sim)
	-- The daily contract creates three real rewards at the selected species'
	-- historical level (capped by the shared contract definition). Regular and
	-- optimized policies merge that reward before the duplicate-sale pass so
	-- the report can show its actual level/income step instead of silently
	-- selling two of the three reward records.
	if sim.strategy == "optimized" or sim.strategy == "regular" or sim.strategy == "atlas" then mergeAvailable(sim, true) end
	maybeBoost(sim)
	sellExcess(sim, beforeCatch == true)
	tryUnlock(sim)
	if sim.now >= sim.horizon then return end
	tryUpgrades(sim)
	-- A newly unlocked zone is available after travel; refill the tank or clean
	-- up once more before fishing.
	if sim.strategy ~= "collection" then
		mergeAvailable(sim, true)
		placeUseful(sim)
		sellExcess(sim, false)
	end
end

local function travelToCatchZone(sim, targetZone)
	if sim.strategy ~= "atlas" or sim.currentCatchZone == targetZone then return true end
	local arrival = math.min(sim.now + TRAVEL_SECONDS_PER_ZONE, sim.horizon)
	sim.stats.travelSeconds += arrival - sim.now
	if arrival < sim.now + TRAVEL_SECONDS_PER_ZONE then sim.stats.travelTruncated = true end
	settle(sim, arrival, false)
	sim.currentCatchZone = targetZone
	return sim.now < sim.horizon
end

local function runSimulation(strategy, seed, horizon, observer, pressureEnabled)
	local sim = makeRun(strategy, seed, horizon, observer, pressureEnabled)
	while sim.now < horizon and not sim.stopped do
		manage(sim, true)
		if sim.now >= horizon then break end
		local snapshot = profileSnapshot(sim)
		local catchZone = snapshot.zone
		if sim.strategy == "atlas" then catchZone = chooseAtlasCatchZone(snapshot) end
		if not travelToCatchZone(sim, catchZone) then break end
		local catchAt = sim.now + ROUND_SECONDS
		-- FishingService resolves a round at endsAt=startedAt+RoundSeconds.
		-- Do not create a catch whose completion lies beyond the requested
		-- horizon; settle the already accrued aquarium income instead.
		if catchAt > horizon then break end
		if countFish(snapshot, false) + snapshot.hooks > snapshot.bagCapacity then
			sim.stats.bagFullStops += 1
			sim.stopped, sim.stopReason = true, "背包空间不足（管理后仍无法容纳下一批）"
			break
		end
		sim.now = catchAt
		local result = issue(sim, "catch", { zone = catchZone })
		if not result.ok then
			if tostring(result.message) == "背包空间不足" then
				sim.stats.bagFullStops += 1
				sim.stopped, sim.stopReason = true, "背包空间不足"
				break
			end
			sim.stopped, sim.stopReason = true, tostring(result.message)
			break
		end
	end
	if not sim.stopped and sim.now < horizon then
		settle(sim, horizon, false)
	elseif sim.now >= horizon then
		-- A catch completion or a capped travel leg reached the horizon exactly.
		validProfile(sim, "horizon boundary")
	else
		-- Keep a final cursor and snapshot for a censored run.  No horizon is
		-- reported as completion when capacity stopped it early.
		validProfile(sim, "stopped run")
	end
	sim.endAt = sim.now
	sim.stats.coinsAtEnd = sim.profile.coins
	local expectedCoins = sim.stats.initialCoins + sim.stats.passiveIncome + sim.stats.saleIncome - sim.stats.upgradeSpend - sim.stats.zoneSpend
	sim.stats.accountingDifference = sim.profile.coins - expectedCoins
	near(sim.stats.accountingDifference, 0, 1e-6, string.format("coin accounting failed for %s/%d", strategy, seed))
	local endSnapshot = profileSnapshot(sim)
	if sim.observer then sim.observer(sim, endSnapshot, "final") end
	sim.stats.endIncomePerHour = endSnapshot.incomePerHour
	local beforeOffline = sim.profile.coins
	local offline = Model.settle(sim.profile, sim.now + OFFLINE_SECONDS, true)
	expect(offline.ok, "offline return failed: " .. tostring(offline.message))
	sim.stats.offlineGain = sim.profile.coins - beforeOffline
	local afterOffline = sim.profile.coins
	local repeated = Model.settle(sim.profile, sim.now + OFFLINE_SECONDS, true)
	expect(repeated.ok, "offline replay failed: " .. tostring(repeated.message))
	sim.stats.offlineRepeatGain = sim.profile.coins - afterOffline
	sim.stats.coinsAfterOffline = sim.profile.coins
	sim.now += OFFLINE_SECONDS
	local returnSnapshot = profileSnapshot(sim)
	sim.stats.offlineReturnIncomePerHour = returnSnapshot.incomePerHour
	-- End-time milestones are intentionally collected before offline return;
	-- offline settlement grants coins only and never creates a fish/discovery.
	return sim, endSnapshot, returnSnapshot
end

local function formatTime(value)
	if value == nil then return "censored" end
	return string.format("%.0fs", value)
end

local function printRun(sim, snapshot, returnSnapshot)
	local stats = sim.stats
	local merges = {}
	for _, level in ipairs(sortedKeys(stats.mergeByLevel)) do table.insert(merges, "L" .. level .. "=" .. tostring(stats.mergeByLevel[level])) end
	local unlocks = {}
	for zone = 2, #Config.Zones do
		if stats.zoneUnlockTimes[zone] then table.insert(unlocks, tostring(zone) .. "@" .. formatTime(stats.zoneUnlockTimes[zone])) end
	end
	printf("RUN\tstrategy=%s\tseed=%d\thorizon=%d\tendAt=%d\thorizonReached=%s\tstopped=%s\tstopReason=%s\ttravelTruncated=%s", sim.strategy, sim.seed, sim.horizon, sim.endAt, tostring(not sim.stopped and sim.endAt >= sim.horizon), tostring(sim.stopped), tostring(sim.stopReason or "none"), tostring(stats.travelTruncated))
	printf("RESULT\tstrategy=%s\tseed=%d\tzone=%d\tdiscoveries=%d\tfirstCatch=%s\tlastCatch=%s\tfirstRare=%s\tfirstRareSpecies=%s\tlevel=%d\tfirstLv10=%s\tcoinsAtEnd=%.2f\tcoinsAfterOffline=%.2f\thooks=%d\tbag=%d\ttank=%d\tendIncomePerHour=%.2f\tofflineReturnIncomePerHour=%.2f\tcatchCalls=%d\tfishCaught=%d\tfishSold=%d\tfishMerged=%d\tfullBagStops=%d", sim.strategy, sim.seed, snapshot.zone, snapshot.discoveryCount, formatTime(stats.firstCatchTime), formatTime(stats.lastCatchTime), formatTime(stats.firstRareTime), tostring(stats.firstRareSpecies or "censored"), snapshot.playerLevel, formatTime(stats.firstLevel10Time), stats.coinsAtEnd, stats.coinsAfterOffline, snapshot.hooks, countFish(snapshot, false), countFish(snapshot, true), stats.endIncomePerHour, stats.offlineReturnIncomePerHour, stats.catchCalls, stats.fishCaught, stats.fishSold, stats.fishMerged, stats.bagFullStops)
	printf("MONEY\tstrategy=%s\tseed=%d\tinitial=%.2f\tpassive=%.2f\tsales=%.2f\tupgradeSpend=%.2f\tzoneSpend=%.2f\taccountingDifference=%.12f\tofflineGain=%.2f\tofflineRepeatGain=%.2f\ttravelSeconds=%d", sim.strategy, sim.seed, stats.initialCoins, stats.passiveIncome, stats.saleIncome, stats.upgradeSpend, stats.zoneSpend, stats.accountingDifference, stats.offlineGain, stats.offlineRepeatGain, stats.travelSeconds)
	printf("ACTIONS\tstrategy=%s\tseed=%d\tmerges=%s\tcontracts=%d\tcontractTarget=%s\tcontractFailures=%d\texchanges=%s\titemUses=%s\tunlocks=%s", sim.strategy, sim.seed, table.concat(merges, ","), stats.contractClaims, tostring(stats.contractTarget or "none"), stats.contractFailures, table.concat((function() local a = {}; for _, id in ipairs(sortedKeys(stats.exchanges)) do table.insert(a, id .. "=" .. stats.exchanges[id]) end; return a end)(), ","), table.concat((function() local a = {}; for _, id in ipairs(sortedKeys(stats.itemUses)) do table.insert(a, id .. "=" .. stats.itemUses[id]) end; return a end)(), ","), table.concat(unlocks, ","))
	printf("CENSOR\tstrategy=%s\tseed=%d\tfull70=%s\tlv10=%s\tzone9=%s\tendAtHorizon=%s", sim.strategy, sim.seed, tostring(stats.firstDiscovery70Time ~= nil), tostring(stats.firstLevel10Time ~= nil), tostring(snapshot.zone >= 9), tostring(not sim.stopped and sim.endAt >= sim.horizon))
end

local function printParameterTables()
	printf("SECTION\tparameters")
	printf("MODEL\tprofileVersion=%d\troundSeconds=%d\tmaxHooks=%d\tmaxEffectiveLuck=%d\tmaxLuckUpgrade=%d\tmaxBag=%d\tmaxTank=%d", Model.ProfileVersion, ROUND_SECONDS, Config.MaxHooks, Config.MaxEffectiveLuck, Config.MaxLuck, Config.MaxBagCapacity, Config.MaxTankCapacity)
	for _, luck in ipairs({ 0, 25, 50, 63, 75 }) do
		local odds = Model.odds(luck)
		for index, chance in ipairs(odds) do printf("ODDS\tluck=%d\trarity=%d\tname=%s\tprobability=%.10f\tpercent=%.7f", luck, index, rarityName(index), chance, chance * 100) end
	end
	printf("ROUND\tseconds=%d\thooks=100\tcatchesPerHour=%.2f\tfishPer100HookBatch=100", ROUND_SECONDS, 3600 / ROUND_SECONDS)
	for index, range in ipairs(Config.WeightRanges) do printf("WEIGHT_DEFAULT\trarity=%d\tname=%s\tminGrams=%d\tmaxGrams=%d\tstandardGrams=%d", index, rarityName(index), range.min, range.max, range.standard) end
	for _, trait in ipairs(Config.TraitEntries) do printf("TRAIT\tid=%s\tname=%s\tchance=%.4f\tvalueMultiplier=%.2f\tluckBonus=%d\tcoinBonus=%.4f\txpBonus=%.4f", trait.id, trait.name, trait.chance, trait.valueMultiplier, trait.luckBonus, trait.coinBonus, trait.xpBonus) end
	for index, mutation in ipairs(Config.Mutations) do printf("MUTATION\tindex=%d\tname=%s\tchance=%.6f\tvalueMultiplier=%.2f", index, mutation.name, mutation.chance, mutation.multiplier) end
	for index, rarity in ipairs(Config.Rarities) do printf("SALE\trarity=%d\tname=%s\tstandardValueCoins=%.2f\tbaseIncomePerHour=%.2f", index, rarity.name, rarity.sell, rarity.income) end
	for _, itemId in ipairs(sortedKeys(Config.BoostItems)) do
		local item = Config.BoostItems[itemId]
		printf("BOOST\tid=%s\tkind=%s\tdurationSeconds=%d\tamount=%d\tmultiplier=%.2f\tmaxBoostSeconds=%d", item.id, item.kind, item.durationSeconds, item.amount, item.multiplier, Config.MaxBoostDurationSeconds)
	end
	printf("BOOST_SHOWCASE\tluckyLuckBonus=%d\tgildedCoinBonus=%.4f\tscholarlyXpBonus=%.4f", Config.Traits.lucky.luckBonus, Config.Traits.gilded.coinBonus, Config.Traits.scholarly.xpBonus)
	printf("MERGE\tlevel=1\tlevel10Sources=%d\tlevel6SourcesForOneLevel10=%d\tdailyLevel6Fish=3\tdailyRewardsForOneLevel10=%d", 3 ^ 9, 3 ^ 4, (3 ^ 4) / 3)
	local milestones = {
		{ "hooks", { 1, 2, 5, 10, 25, 50, 100 } },
		{ "luck", { 0, 10, 25, 50 } },
		{ "coins", { 0, 10, 20, 30 } },
		{ "tank", { 10, 20, 50, 100 } },
		{ "bag", { 300, 500, 1000, 3000 } },
	}
	for _, spec in ipairs(milestones) do
		local kind, levels = spec[1], spec[2]
		for _, target in ipairs(levels) do
			local total = 0
			if kind == "hooks" then for level = 1, target - 1 do total += Config.hookCost(level) end
			elseif kind == "luck" then for level = 0, target - 1 do total += Config.luckCost(level) end
			elseif kind == "coins" then for level = 0, target - 1 do total += Config.coinCost(level) end
			elseif kind == "tank" then for capacity = 10, target - 1 do total += Config.tankCost(capacity) end
			elseif kind == "bag" then for capacity = 300, target - 100, 100 do total += Config.bagCost(capacity) end end
			printf("UPGRADE_TOTAL\tkind=%s\ttarget=%d\tcumulativeCoins=%.2f", kind, target, total)
		end
	end
	for _, zone in ipairs(Config.Zones) do printf("ZONE\tid=%d\tname=%s\tcost=%d\trequiredDiscoveries=%d\trequiredLevel=%s\tthemeOnly=%s", zone.id, zone.name, zone.cost, zone.requiredDiscoveries or 0, tostring(zone.requiredLevel or 1), tostring(zone.themeOnly == true)) end
	for _, item in ipairs(Config.Species) do
		if item.baseWeightGrams then printf("WEIGHT_THEME\tzone=%d\tspecies=%s\tbaseWeightGrams=%d", item.zone, item.id, item.baseWeightGrams) end
	end
end

local function runDropFixture()
	printf("SECTION\tdrop_fixture\tlabel=non_player_growth_fixture\tbatches=%d\tbatchHooks=100", DROP_BATCHES)
	for _, luck in ipairs({ 0, 25, 50, 63 }) do
		local counts, values, weights, traitCounts, mutationCounts = {}, 0, 0, {}, {}
		for index = 1, #Config.Rarities do counts[index] = 0 end
		local seed = 900000 + luck * 1000
		for batch = 1, DROP_BATCHES do
			local profile = Model.new(0) -- isolated fixture; starter fish are not counted
			profile.hooks, profile.bagCapacity = 100, Config.MaxBagCapacity
			profile.luck = math.min(luck, Config.MaxLuck)
			if luck == 63 then
				-- The 63 point fixture is the currently reachable path: upgrade
				-- luck 50 + one 10-luck tonic + one showcased lucky fish (+3).
				profile.fish[1].trait = "lucky" -- fixture setup, not growth
				profile.items.luck_tonic = 1
				local boost = Model.command(profile, "useItem", { itemId = "luck_tonic", requestId = "fixture-luck-" .. tostring(batch) }, 0)
				expect(boost.ok, "63 luck fixture boost failed")
				local showcase = Model.command(profile, "showcase", { id = profile.fish[1].id }, 0)
				expect(showcase.ok and Model.effectiveLuck(profile, 0) == 63, "63 luck fixture showcase failed")
			end
			local random = rngFor(seed + batch)
			local response = Model.command(profile, "catch", { zone = 1 }, 20, random)
			expect(response.ok and #response.fish == 100, "drop fixture catch batch failed")
			for _, fish in ipairs(response.fish) do
				local rarity = rarityIndexForFish(fish)
				counts[rarity] += 1
				values += fish.value
				weights += fish.weightGrams
				increment(traitCounts, fish.trait)
				increment(mutationCounts, tostring(fish.mutation))
			end
		end
		local total = DROP_BATCHES * 100
		local countText = {}
		for index = 1, #counts do table.insert(countText, tostring(index) .. "=" .. tostring(counts[index])) end
		printf("DROP\tluck=%d\ttotalFish=%d\tcounts=%s\tmeanValue=%.4f\tmeanWeightGrams=%.2f", luck, total, table.concat(countText, ","), values / total, weights / total)
		local traitText, mutationText = {}, {}
		for _, id in ipairs(sortedKeys(traitCounts)) do table.insert(traitText, id .. "=" .. tostring(traitCounts[id])) end
		for _, id in ipairs(sortedKeys(mutationCounts)) do table.insert(mutationText, id .. "=" .. tostring(mutationCounts[id])) end
		printf("DROP_DETAIL\tluck=%d\ttraits=%s\tmutations=%s", luck, table.concat(traitText, ","), table.concat(mutationText, ","))
	end
	printf("DROP\tluck=75\tnote=Model.odds cap alias only; current defined effective path is upgrade50+potion10+showcaseLucky3=63")
end

local function runInvariantChecks()
	printf("SECTION\tinvariants\tlabel=real_model_checks")
	-- Snapshot/merge/sale conservation through authoritative commands.
	local p = Model.new(0)
	local before = Model.snapshot(p, 0)
	local ids = { before.fish[1].id, before.fish[2].id, before.fish[3].id }
	local merged = Model.command(p, "merge", { ids = ids }, 0)
	expect(merged.ok and #p.fish == 1, "merge invariant failed")
	local afterMerge = Model.snapshot(p, 0)
	near(afterMerge.fish[1].value, 30, 1e-9, "merge value conservation failed")
	local sell = Model.command(p, "sell", { id = afterMerge.fish[1].id }, 1)
	expect(sell.ok and sell.earned > 0, "sale invariant failed")
	-- Replay protections are tested with real level-one fish and commands.
	local replayProfile = Model.new(0)
	local replaySnapshot = Model.snapshot(replayProfile, 0)
	local exchangeIds = { replaySnapshot.fish[1].id, replaySnapshot.fish[2].id, replaySnapshot.fish[3].id }
	local legacyExchangeAdapter = {legacyRequestReceipts = {}}
	local exchange = Model.command(replayProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "invariant-exchange" }, 0, nil, legacyExchangeAdapter)
	expect(exchange.ok and replayProfile.items.luck_tonic == 1, "exchange invariant failed")
	local exchangeReplay = Model.command(replayProfile, "exchange", { recipeId = "exchange_luck", ids = exchangeIds, requestId = "invariant-exchange" }, 1, nil, legacyExchangeAdapter)
	expect(exchangeReplay.ok and exchangeReplay.replayed and replayProfile.items.luck_tonic == 1, "exchange replay invariant failed")
	local legacyUseAdapter = {legacyRequestReceipts = {}}
	local use = Model.command(replayProfile, "useItem", { itemId = "luck_tonic", requestId = "invariant-use" }, 1, nil, legacyUseAdapter)
	expect(use.ok, "use item invariant failed")
	local useReplay = Model.command(replayProfile, "useItem", { itemId = "luck_tonic", requestId = "invariant-use" }, 2, nil, legacyUseAdapter)
	expect(useReplay.ok and useReplay.replayed, "use item replay invariant failed")
	-- Offline settlement must cap at the first eight hours and must be
	-- idempotent at the same requested login timestamp.
	local offline = Model.new(0)
	offline.fish[1].placed = true -- fixture setup, not player growth
	offline.coins, offline.lastSettled = 0, 0
	local rate = offline.fish[1].income
	local first = Model.settle(offline, 20 * 3600, true)
	expect(first.ok, "offline invariant failed")
	near(offline.coins, rate * 8 * 0.5, 1e-8, "offline cap invariant failed")
	local coinsAfter = offline.coins
	local repeatSettle = Model.settle(offline, 20 * 3600, true)
	expect(repeatSettle.ok, "offline replay settle failed")
	near(offline.coins, coinsAfter, 1e-10, "offline double settlement invariant failed")
	-- Explicit horizon-travel fixture: it has enough discoveries/coins to
	-- unlock zone 2 at t=0, but a 30s travel leg is clipped to a 10s horizon.
	local travel = makeRun("optimized", 777, 10)
	travel.profile.coins = 2500 -- fixture setup, not player growth
	for index = 1, 6 do travel.profile.discovered[Config.Species[index].id] = 1 end
	validProfile(travel, "travel fixture")
	tryUnlock(travel)
	expect(travel.profile.zone == 2 and travel.now == 10 and travel.stats.travelSeconds == 10 and travel.stats.travelTruncated, "travel horizon clipping failed")
	printf("INVARIANT\tmergeValue=true\texchangeReplay=true\tuseReplay=true\toffline8h50pct=true\tofflineNoDoubleSettlement=true")
	printf("TRAVEL_CHECK\tfixture=true\tzone=%d\tendAt=%d\thorizon=%d\ttravelSeconds=%d\ttruncated=%s", travel.profile.zone, travel.now, travel.horizon, travel.stats.travelSeconds, tostring(travel.stats.travelTruncated))
end

local function mergeFixtureTarget(profile, targetSpecies, now)
	local mergedCount = 0
	for level = 1, 9 do
		while true do
			local snapshot = Model.snapshot(profile, now)
			expect(snapshot.ok, "contract fixture snapshot failed")
			local ids = {}
			for _, fish in ipairs(snapshot.fish) do
				if fish.species == targetSpecies and fish.level == level and not fish.placed and not fish.locked then
					table.insert(ids, fish.id)
					if #ids == 3 then break end
				end
			end
			if #ids < 3 then break end
			local merged = Model.command(profile, "merge", { ids = ids }, now)
			expect(merged.ok, "contract fixture merge failed: " .. tostring(merged.message))
			mergedCount += 1
		end
	end
	return mergedCount
end

local function runContractGrowthFixture()
	local targetSpecies = "nebula_jelly"
	expect(Config.SpeciesById[targetSpecies] ~= nil, "contract fixture target missing")
	local profile = Model.new(0)
	local initialFish = #profile.fish
	local initialTargetFish = 0
	-- Fixture setup supplies the discovery and daily-catch gates. All reward,
	-- merge, settlement and validation mutations below use Model.command.
	for index = 1, 21 do profile.discovered[Config.Species[index].id] = 1 end
	profile.discovered[targetSpecies] = 1
	local initialDiscoveryCount = 0
	for _ in pairs(profile.discovered) do initialDiscoveryCount += 1 end
	printf("SECTION\tcontract_growth_fixture\ttarget=%s\tinitialFish=%d\tinitialTargetFish=%d\tinitialTargetHistory=%d\tdiscovered=%d\tdailyCaughtGate=100\tmode=fixture_not_natural_player", targetSpecies, initialFish, initialTargetFish, profile.discovered[targetSpecies], initialDiscoveryCount)
	local firstLevel10Day
	local claims = 0
	for day = 1, 40 do
		local now = day * 86400 + 3600
		-- Explicitly satisfy the once-per-day 100-catch gate; this fixture does
		-- not claim to model the time or inventory cost of those catches.
		profile.day, profile.dailyCaught = day, 100
		local historyBefore = profile.discovered[targetSpecies] or 1
		local claim = Model.command(profile, "contract", { species = targetSpecies }, now)
		expect(claim.ok and #claim.fish == Config.Contract.rewardFishCount, "contract fixture claim failed")
		claims += 1
		local rewardLevel = claim.fish[1].level
		local mergedCount = mergeFixtureTarget(profile, targetSpecies, now)
		local snapshot = Model.snapshot(profile, now)
		expect(snapshot.ok, "contract fixture post-merge snapshot failed")
		local highest = snapshot.discovered[targetSpecies] or 0
		for _, fish in ipairs(snapshot.fish) do if fish.species == targetSpecies and fish.level > highest then highest = fish.level end end
		printf("CONTRACT_FIXTURE_DAY\tday=%d\thistoryBefore=%d\trewardLevel=%d\tmerged=%d\thistoryAfter=%d\ttargetFish=%d", day, historyBefore, rewardLevel, mergedCount, highest, (function() local n = 0; for _, fish in ipairs(snapshot.fish) do if fish.species == targetSpecies then n += 1 end end; return n end)())
		if highest >= 10 then firstLevel10Day = day; break end
	end
	expect(firstLevel10Day ~= nil, "contract fixture did not reach level 10 within bound")
	validProfile({ profile = profile }, "contract growth fixture")
	printf("CONTRACT_FIXTURE_RESULT\tfirstLevel10Day=%d\tclaims=%d\tinitialFish=%d\tinitialTargetFish=%d\tdailyCaughtGate=100\tassumption=one_claim_per_day_and_all_target_materials_merged", firstLevel10Day, claims, initialFish, initialTargetFish)
end

local function runShort()
	printf("SECTION\tshort_validation\tseed=%d\thorizon=%d", SHORT_SEED, SHORT_HORIZON)
	local sim, snapshot, returnSnapshot = runSimulation("optimized", SHORT_SEED, SHORT_HORIZON)
	printRun(sim, snapshot, returnSnapshot)
	expect(sim.stats.firstCatchTime == ROUND_SECONDS, "short first catch must complete at 20 seconds")
	expect(sim.stats.lastCatchTime <= SHORT_HORIZON, "short catch completed beyond horizon")
	expect(sim.stats.catchCalls == math.floor(SHORT_HORIZON / ROUND_SECONDS), "short catch count must match completed rounds")
	printf("SHORT_CHECK\tvalid=true\tfirstCatch=%d\tlastCatch=%d\tcatchCalls=%d\taccounting=command_settle_snapshot\tperformance=completed", sim.stats.firstCatchTime, sim.stats.lastCatchTime, sim.stats.catchCalls)
end

local function runBaseline()
	printf("SECTION\tbaseline\thorizonSeconds=%d\tseedCount=%d\tseeds=%s", HORIZON_SECONDS, #SEEDS, table.concat(SEEDS, ","))
	for _, strategy in ipairs({ "regular", "collection", "optimized" }) do
		for _, seed in ipairs(SEEDS) do
			local sim, snapshot, returnSnapshot = runSimulation(strategy, seed, HORIZON_SECONDS)
			printRun(sim, snapshot, returnSnapshot)
		end
	end
end

local function runLong(runOptions)
	local configured = runOptions.hasConfiguredLongRun
	local horizon = runOptions.horizon or 24 * 3600
	if not configured then
		printf("SECTION\tlong_probe\thorizonSeconds=%d\tseedCount=3\tlabel=cost_guided_probe", horizon)
		for index, strategy in ipairs({ "regular", "collection", "optimized" }) do
			local sim, snapshot, returnSnapshot = runSimulation(strategy, SEEDS[index], horizon)
			printRun(sim, snapshot, returnSnapshot)
		end
		return
	end
	local strategies = runOptions.strategy and { runOptions.strategy } or { "regular", "collection", "optimized" }
	local seeds = runOptions.seed and { runOptions.seed } or SEEDS
	local interval = runOptions.milestoneEvery or 3600
	local label = configured and "configured_stream_probe" or "cost_guided_probe"
	printf("SECTION\tlong_probe\thorizonSeconds=%d\tseedCount=%d\tstrategyCount=%d\tlabel=%s\tstream=%s", horizon, #seeds, #strategies, label, tostring(configured))
	for _, strategy in ipairs(strategies) do
		for _, seed in ipairs(seeds) do
			local observer = configured and makeMilestoneObserver(strategy, seed, horizon, interval) or nil
			if observer then
				printf("STREAM\tstrategy=%s\tseed=%d\thorizon=%d\tmilestoneEvery=%d\tobserver=existing_command_snapshots", strategy, seed, horizon, interval)
			end
			local sim, snapshot, returnSnapshot = runSimulation(strategy, seed, horizon, observer, runOptions.pressure)
			printRun(sim, snapshot, returnSnapshot)
			if strategy == "atlas" then
				printf("ATLAS\tstrategy=atlas\tseed=%d\tcurrentCatchZone=%d\tmissingByAuthorZone=%s\tcontractTargetPolicy=%s\ttravelSeconds=%d", seed, sim.currentCatchZone, atlasMissingByAuthorZone(snapshot), sim.stats.contractTargetPolicy, sim.stats.travelSeconds)
			end
		end
	end
end

printf("ECONOMY_SIMULATION\tversion=2026-10-02-g1\tmode=%s\tmodel=real_shared_Model\tconfig=real_shared_Config", mode)
if mode == "parameters" then
	printParameterTables()
elseif mode == "drop" then
	printParameterTables()
	runDropFixture()
	runInvariantChecks()
elseif mode == "short" then
	runShort()
	runInvariantChecks()
elseif mode == "baseline" then
	runBaseline()
	runInvariantChecks()
elseif mode == "long" then
	runLong(options)
	if options.pressure then runContractGrowthFixture() end
	runInvariantChecks()
else
	printParameterTables()
	runDropFixture()
	runShort()
	runBaseline()
	runLong(options)
	runInvariantChecks()
end

print("ECONOMY_SIMULATION_END")
