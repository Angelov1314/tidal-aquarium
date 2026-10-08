-- Focused policy-capacity fixtures for the bounded session driver.
-- This test does not alter Model/Config or the natural runner. It constructs
-- an explicit, valid mid-session profile through real Model commands, then
-- injects that profile only through a test-local Model.new adapter so the
-- driver's private management closures can reach their capacity branches.
local Model = require("../src/shared/Model")
local Config = require("../src/shared/Config")
local rngFor = require("../tools/economy_rng")
local Driver = require("../tools/economy_session_driver")

local function expect(condition, message)
	if not condition then error(message or "capacity fixture expectation failed", 2) end
end

local function randomHalf()
	return 0.5
end

local function targetDiscoveries()
	local discovered = { sand_goby = 1 }
	local count = 1
	for speciesId in pairs(Config.SpeciesById) do
		if speciesId ~= "sand_goby" and count < 21 then
			discovered[speciesId] = 1
			count += 1
		end
	end
	expect(count == 21, "fixture requires 21 authored species IDs")
	return discovered
end

local function buildFixture(qualifiesForContract, unprotectedLevel10)
	local profile = Model.new(0)
	-- Fill the bag with real catch commands. The remaining fixture shaping is
	-- explicit save-state setup: the default cases use locked target material,
	-- while the independent level-10 case leaves all target fish unlocked. Both
	-- are valid Model states and keep the capacity branch deterministic.
	for index = 1, 297 do
		local caught = Model.command(profile, "catch", { zone = 1 }, index * 20, randomHalf)
		expect(caught.ok, "real catch command " .. tostring(index))
	end
	expect(#profile.fish == 300, "real commands must fill the 300-slot bag")
	for _, fish in ipairs(profile.fish) do
		fish.species = "sand_goby"
		fish.level = unprotectedLevel10 and 10 or 1
		fish.placed = false
		fish.locked = not unprotectedLevel10
	end
	profile.discovered = qualifiesForContract and targetDiscoveries() or { sand_goby = 1 }
	if unprotectedLevel10 then profile.discovered.sand_goby = 10 end
	profile.dailyCaught = qualifiesForContract and 100 or 0
	profile.day = 0
	profile.contractDay = -1
	profile.coins = 0
	profile.lastSettled = 0
	profile.showcaseFishId = nil
	local valid, message = Model.validate(profile)
	expect(valid, "constructed fixture must validate: " .. tostring(message))
	return profile
end

local function snapshotSignature(snapshot)
	local parts = {
		tostring(snapshot.coins), tostring(snapshot.contractDay), tostring(snapshot.dailyCaught),
		tostring(snapshot.discoveryCount), tostring(#snapshot.fish), tostring(snapshot.bagCapacity),
	}
	local discovered = {}
	for species, level in pairs(snapshot.discovered or {}) do table.insert(discovered, tostring(species) .. ":" .. tostring(level)) end
	table.sort(discovered)
	table.insert(parts, table.concat(discovered, ","))
	for _, fish in ipairs(snapshot.fish) do
		table.insert(parts, table.concat({
			tostring(fish.id), tostring(fish.species), tostring(fish.level), tostring(fish.value), tostring(fish.income),
			tostring(fish.weightGrams), tostring(fish.trait), tostring(fish.catchZone), tostring(fish.caughtAt), tostring(fish.catchSource),
			tostring(fish.placed), tostring(fish.locked),
		}, ":"))
	end
	return table.concat(parts, "|")
end

local FixtureModel = {
	snapshot = Model.snapshot,
	command = Model.command,
	settle = Model.settle,
	validate = Model.validate,
	salePrice = Model.salePrice,
}
local pendingProfile
function FixtureModel.new(now)
	expect(pendingProfile ~= nil, "fixture Model.new called without a prepared profile")
	local profile = pendingProfile
	pendingProfile = nil
	return profile
end

local function runAndCheck(qualifiesForContract, unprotectedLevel10)
	-- Keep a direct profile reference for post-run Model.snapshot/validate.
	local profile = buildFixture(qualifiesForContract, unprotectedLevel10)
	local before = Model.snapshot(profile, 0)
	expect(before.ok, "fixture snapshot before driver")
	local beforeSignature = snapshotSignature(before)
	pendingProfile = profile
	local report = Driver.run({
		seed = 101,
		sessionMinutes = 30,
		days = 1,
		policy = "nurture",
		targetSpecies = "sand_goby",
		maxActions = 25000,
		milestoneEvery = 600,
	}, { Model = FixtureModel, Config = Config, rngFor = rngFor })
	expect(pendingProfile == nil, "driver did not consume fixture profile")
	local after = Model.snapshot(profile, 0)
	expect(after.ok and Model.validate(profile), "post-driver fixture must still validate")
	expect(snapshotSignature(after) == beforeSignature, "capacity stop must preserve fish/assets and contract state")
	expect(report.status == "censored" and report.stopReason == "bag_full_target_protected", "capacity stop reason")
	expect(report.stopReasonClass == "capacity", "capacity stop class")
	expect(report.final and report.final.bag == 300 and report.final.targetPlaced == 0, "capacity fixture final bag")
	expect(report.final.coinResidual == 0 and report.final.unitResidual == 0, "capacity fixture ledger residual")
	expect((report.stats.failedByKind and next(report.stats.failedByKind)) == nil, "capacity policy stop is not command failure")
	expect((report.stats.actionsByKind and next(report.stats.actionsByKind)) == nil, "capacity stop must issue no destructive command")
	return report
end

local protected = runAndCheck(false)
expect((protected.stats.policyStops.capacity_protected_target or 0) > 0, "protected-target capacity policy stop")
expect((protected.stats.policyStops.contract_capacity or 0) == 0, "unqualified fixture must not report contract capacity")

local contractBlocked = runAndCheck(true)
expect((contractBlocked.stats.policyStops.capacity_protected_target or 0) > 0, "contract fixture protected-target stop")
expect((contractBlocked.stats.policyStops.contract_capacity or 0) > 0, "qualified no-three-slots contract capacity stop")
expect((contractBlocked.stats.contractClaims or 0) == 0, "blocked contract must not call contract")

local unlockedLevel10 = runAndCheck(false, true)
expect(unlockedLevel10.final.targetOwnedLevel == 10, "unlocked level-10 target fixture")
expect(unlockedLevel10.final.targetDiscoveredLevel == 10, "level-10 target discovery history fixture")
expect((unlockedLevel10.stats.policyStops.capacity_protected_target or 0) > 0, "unlocked target species exclusion capacity stop")
expect((unlockedLevel10.stats.policyStops.contract_capacity or 0) == 0, "unqualified level-10 fixture contract capacity")

print("EconomySessionCapacity.spec: real Model fill, locked-target, unlocked-level10 target exclusion, contract capacity, no command mutation PASS")
