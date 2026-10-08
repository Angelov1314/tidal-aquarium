--!strict
-- Pure contracts for the short catch presentation.  Server and client use the
-- same bounded representative ordering and phase timings; no gameplay state is
-- inferred from this module.

local CatchFeedback = {}

CatchFeedback.MaxRepresentatives = 3
CatchFeedback.MaxPendingBatches = 4
CatchFeedback.MaxRememberedBatches = 64
CatchFeedback.MaxCount = 100
CatchFeedback.FlightSeconds = 0.55
CatchFeedback.LandingSeconds = 0.65
CatchFeedback.BagSeconds = 0.55
CatchFeedback.StaggerSeconds = 0.06
CatchFeedback.RareLingerSeconds = 0.10
CatchFeedback.TotalSeconds = CatchFeedback.FlightSeconds + CatchFeedback.LandingSeconds + CatchFeedback.BagSeconds

local function numberOr(value: any, fallback: number): number
	return type(value) == "number" and value == value and value or fallback
end

local function speciesRarity(fish: any, speciesById: {[string]: any}?): number
	if type(fish) ~= "table" then return 0 end
	if type(fish.rarity) == "number" then return fish.rarity end
	local species = speciesById and speciesById[fish.species]
	return species and numberOr(species.rarity, 0) or 0
end

local function copyRecord(record: any): any
	local copied = {}
	if type(record) ~= "table" then return copied end
	for key, value in pairs(record) do
		local valueType = type(value)
		if valueType == "string" or valueType == "number" or valueType == "boolean" then
			copied[key] = value
		end
	end
	return copied
end

-- Pick representatives for visual feedback only.  The input order is never
-- used as a gameplay signal; ties are resolved by stable fields so a 100-hook
-- result always produces the same visible three records.
function CatchFeedback.representatives(fish: any, speciesById: {[string]: any}?, limit: number?): {any}
	local candidates = {}
	if type(fish) == "table" then
		for _, record in ipairs(fish) do
			if type(record) == "table" and type(record.species) == "string" then
				table.insert(candidates, record)
			end
		end
	end
	table.sort(candidates, function(a, b)
		local rarityA = speciesRarity(a, speciesById)
		local rarityB = speciesRarity(b, speciesById)
		if rarityA ~= rarityB then return rarityA > rarityB end
		local sizeA = numberOr(a.size, 0)
		local sizeB = numberOr(b.size, 0)
		if sizeA ~= sizeB then return sizeA > sizeB end
		local mutationA = numberOr(a.mutation, 0)
		local mutationB = numberOr(b.mutation, 0)
		if mutationA ~= mutationB then return mutationA > mutationB end
		local levelA = numberOr(a.level, 0)
		local levelB = numberOr(b.level, 0)
		if levelA ~= levelB then return levelA > levelB end
		local speciesA = tostring(a.species)
		local speciesB = tostring(b.species)
		if speciesA ~= speciesB then return speciesA < speciesB end
		return tostring(a.id or "") < tostring(b.id or "")
	end)
	local result = {}
	local cap = math.clamp(math.floor(numberOr(limit, CatchFeedback.MaxRepresentatives)), 0, CatchFeedback.MaxRepresentatives)
	for index = 1, math.min(cap, #candidates) do table.insert(result, copyRecord(candidates[index])) end
	return result
end

function CatchFeedback.validateBatch(event: any): boolean
	if type(event) ~= "table" or event.kind ~= "catch" then return false end
	if type(event.batchId) ~= "string" or #event.batchId < 1 or #event.batchId > 160 then return false end
	if type(event.count) ~= "number" or event.count < 1 or event.count % 1 ~= 0 or event.count > CatchFeedback.MaxCount then return false end
	if type(event.zone) ~= "number" or event.zone < 1 or event.zone % 1 ~= 0 then return false end
	if type(event.fish) ~= "table" or #event.fish < 1 or #event.fish > CatchFeedback.MaxRepresentatives then return false end
	for _, fish in ipairs(event.fish) do
		if type(fish) ~= "table" or type(fish.id) ~= "string" or type(fish.species) ~= "string"
			or type(fish.level) ~= "number" or fish.level < 1 or fish.level % 1 ~= 0
			or type(fish.size) ~= "number" or fish.size < 1 or fish.size % 1 ~= 0
			or type(fish.mutation) ~= "number" or fish.mutation < 1 or fish.mutation % 1 ~= 0 then
			return false
		end
	end
	return true
end

function CatchFeedback.acceptBatch(seen: {[string]: boolean}, order: {string}, batchId: string): boolean
	if seen[batchId] then return false end
	seen[batchId] = true
	table.insert(order, batchId)
	while #order > CatchFeedback.MaxRememberedBatches do
		local old = table.remove(order, 1)
		if old then seen[old] = nil end
	end
	return true
end

function CatchFeedback.phaseAt(elapsed: number, stagger: number?): (string, number)
	local time = math.max(0, numberOr(elapsed, 0))
	local offset = math.max(0, numberOr(stagger, 0))
	if time < CatchFeedback.FlightSeconds then
		return "flight", math.clamp(time / CatchFeedback.FlightSeconds, 0, 1)
	end
	local landingEnd = CatchFeedback.FlightSeconds + CatchFeedback.LandingSeconds
	if time < landingEnd then
		return "landing", math.clamp((time - CatchFeedback.FlightSeconds) / CatchFeedback.LandingSeconds, 0, 1)
	end
	local bagTime = time - landingEnd - offset
	if bagTime < 0 then return "landing", 1 end
	if bagTime < CatchFeedback.BagSeconds then
		return "bag", math.clamp(bagTime / CatchFeedback.BagSeconds, 0, 1)
	end
	return "done", 1
end

function CatchFeedback.batchDuration(representativeCount: number, rare: boolean?): number
	local count = math.max(0, math.floor(numberOr(representativeCount, 0)))
	local staggerTail = math.max(0, count - 1) * CatchFeedback.StaggerSeconds
	return CatchFeedback.TotalSeconds + staggerTail + (rare and CatchFeedback.RareLingerSeconds or 0)
end

return CatchFeedback
