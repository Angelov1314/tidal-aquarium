-- Synthetic, valid profile fixtures for the snapshot performance contract.
-- This module is benchmark/test tooling only; it never ships in the place.
local Fixture = {}

local function fishRecord(index, placed, trait)
	return {
		id = "f" .. tostring(index),
		species = "white_koi",
		level = 1,
		size = 2,
		mutation = 1,
		value = 10 + index % 17,
		income = 1,
		placed = placed,
		locked = false,
		weightGrams = 100,
		trait = trait or "ordinary",
		catchZone = 1,
		caughtAt = 0,
		catchSource = "snapshot-performance",
	}
end

function Fixture.profile(Model, count, withShowcase)
	local profile = Model.new(0)
	profile.bagCapacity = 3000
	profile.tankCapacity = 100
	profile.fish = {}
	profile.nextId = count + 1
	profile.showcaseFishId = nil
	for index = 1, count do
		local placed = index <= 100
		local trait = withShowcase and index == count and "gilded" or "ordinary"
		table.insert(profile.fish, fishRecord(index, placed, trait))
	end
	if withShowcase then profile.showcaseFishId = "f" .. tostring(count) end
	return profile
end

local function keySortKey(key)
	return type(key) .. ":" .. tostring(key)
end

-- A deterministic, lossless-enough textual representation for before/after
-- fixture comparison. Snapshot values are JSON-safe primitives/tables.
function Fixture.canonical(value)
	local valueType = type(value)
	if valueType == "nil" then return "nil" end
	if valueType == "string" then return string.format("%q", value) end
	if valueType == "number" or valueType == "boolean" then return tostring(value) end
	if valueType ~= "table" then error("unexpected snapshot value type: " .. valueType) end
	local keys = {}
	for key in pairs(value) do table.insert(keys, key) end
	table.sort(keys, function(a, b) return keySortKey(a) < keySortKey(b) end)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, Fixture.canonical(key) .. "=" .. Fixture.canonical(value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

return Fixture
