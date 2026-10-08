-- Emits deterministic complete snapshot fixtures for before/after equality.
local Model = require("../src/shared/Model")
local Fixture = require("./snapshot_performance_fixture")

for _, count in ipairs({ 300, 1500, 3100 }) do
	for _, scenario in ipairs({ { name = "no-showcase", showcase = false }, { name = "showcase-last", showcase = true } }) do
		local profile = Fixture.profile(Model, count, scenario.showcase)
		local snapshot = Model.snapshot(profile, 86400)
		print(string.format("SNAPSHOT_CANONICAL,scenario=%s,n=%d,%s", scenario.name, count, Fixture.canonical(snapshot)))
	end
end

print("SNAPSHOT_CANONICAL_DONE")
