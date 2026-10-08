-- Repeatable Luau CPU benchmark for Model.snapshot.
-- Run from this directory's caller with the recovery Luau executable.
local Model = require("../src/shared/Model")
local Fixture = require("./snapshot_performance_fixture")

local sizes = { 300, 1500, 3100 }
local warmups = 10
local samples = 20
local now = 86400

local function runScenario(name, withShowcase, count)
	local profile = Fixture.profile(Model, count, withShowcase)
	for _ = 1, warmups do Model.snapshot(profile, now) end
	local elapsed = {}
	local result
	for sample = 1, samples do
		local started = os.clock()
		result = Model.snapshot(profile, now)
		elapsed[sample] = (os.clock() - started) * 1000
	end
	print(string.format(
		"SNAPSHOT_BENCH,scenario=%s,n=%d,warmups=%d,samples=%d,fish=%d,showcase=%s,firstSale=%.9f,lastSale=%.9f",
		name,
		count,
		warmups,
		samples,
		#result.fish,
		withShowcase and "gilded-last" or "none",
		result.fish[1].salePrice,
		result.fish[#result.fish].salePrice
	))
	for sample = 1, samples do
		print(string.format("SNAPSHOT_SAMPLE,scenario=%s,n=%d,sample=%d,elapsedCpuMs=%.9f", name, count, sample, elapsed[sample]))
	end
end

for _, count in ipairs(sizes) do
	runScenario("no-showcase", false, count)
	runScenario("showcase-last", true, count)
end

print("SNAPSHOT_BENCH_DONE")
