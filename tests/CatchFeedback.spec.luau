local CatchFeedback = require("../src/shared/CatchFeedback")
local Config = require("../src/shared/Config")

local function expect(condition, message)
	if not condition then error(message or "expectation failed", 2) end
end

local caught = {}
for index = 1, 100 do
	local species = Config.Species[((index - 1) % #Config.Species) + 1]
	table.insert(caught, {
		id = "f" .. tostring(index), species = species.id, level = index % 10 + 1,
		size = index % 4 + 1, mutation = index % 4 + 1, value = index, income = index,
	})
end
local reps = CatchFeedback.representatives(caught, Config.SpeciesById)
expect(#reps == 3, "representatives must cap at three")
expect(Config.SpeciesById[reps[1].species].rarity >= Config.SpeciesById[reps[2].species].rarity, "representatives must prioritize rarity")
expect(CatchFeedback.validateBatch({kind = "catch", batchId = "session-1:1", count = 100, zone = 1, fish = reps}), "100-hook batch contract must validate")
expect(not CatchFeedback.validateBatch({kind = "catch", batchId = "session-1:bad", count = 101, zone = 1, fish = reps}), "batch count above hook cap must reject")
expect(not CatchFeedback.validateBatch({kind = "catch", batchId = "session-1:bad2", count = 1, zone = 1, fish = {{species = "white_koi"}}}), "incomplete representative must reject")
local seen, order = {}, {}
expect(CatchFeedback.acceptBatch(seen, order, "session-1:1"), "first batch should be accepted")
expect(not CatchFeedback.acceptBatch(seen, order, "session-1:1"), "duplicate batch must be ignored")

local previous = "flight"
local sampled = {}
for hz = 30, 120, 30 do
	if hz == 30 or hz == 60 or hz == 120 then
		local phases = {}
		local frame = 0
		while frame <= math.ceil(CatchFeedback.batchDuration(3, true) * hz) do
			local phase = CatchFeedback.phaseAt(frame / hz)
			phases[phase] = true
			frame += 1
		end
		expect(phases.flight and phases.landing and phases.bag and phases.done, tostring(hz) .. "Hz must visit every phase")
		sampled[hz] = true
	end
end
expect(sampled[30] and sampled[60] and sampled[120], "timeline sample rates missing")
expect(CatchFeedback.batchDuration(3, true) < 2.1, "catch presentation should stay close to two seconds")
print("CatchFeedback.spec: cap, exact count, malformed input, duplicate-safe timeline and 30/60/120Hz phases PASS")
