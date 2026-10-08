--!strict
-- Pure server adapter for the income-preview wire DTO.  It deliberately
-- accepts a profile or a record containing `profile`, but never settles,
-- marks dirty, advances IDs, or touches a Roblox service.  FishingService
-- supplies the live record; tests can supply a small Model spy to prove the
-- exact authoritative call count without mirroring Model's arithmetic.
local Request
local Model
if script then
	local shared = game:GetService("ReplicatedStorage"):WaitForChild("FishingShared")
	Request = require(shared:WaitForChild("IncomePreviewRequest"))
	Model = require(shared:WaitForChild("Model"))
else
	Request = require("../shared/IncomePreviewRequest")
	Model = require("../shared/Model")
end

local IncomePreviewQuery = {}

local function profileOf(value: any): any?
	if type(value) ~= "table" then return nil end
	if type(value.profile) == "table" then return value.profile end
	return value
end

local function findFish(profile: any, id: string): any?
	for _, fish in ipairs(profile.fish or {}) do
		if fish.id == id then return fish end
	end
	return nil
end

function IncomePreviewQuery.run(recordOrProfile: any, at: any, payload: any, modelOverride: any?): (boolean, any)
	local profile = profileOf(recordOrProfile)
	if profile == nil then return false, "存档不可用" end
	local valid, reason = Request.validate(payload)
	if not valid then return false, reason or "预览请求无效" end
	if type(at) ~= "number" or at ~= at or at == math.huge or at == -math.huge or at < 0 then return false, "时间无效" end
	local model = modelOverride or Model
	if type(model) ~= "table" or type(model.incomePreview) ~= "function" then return false, "预览模型不可用" end

	if payload.kind == "detail" then
		-- The two choices are calculated independently from the same profile and
		-- timestamp.  The fish lookup only selects the action; Model remains the
		-- authority for all preconditions and numeric fields.
		local fish = findFish(profile, payload.id)
		local placementAction = if fish and fish.placed then "remove" else "place"
		local showcaseAction = if profile.showcaseFishId == payload.id then "hideFish" else "showcase"
		local placement = model.incomePreview(profile, at, {kind = "fish", action = placementAction, id = payload.id})
		local showcaseRequest: {[string]: any} = {kind = "fish", action = showcaseAction}
		if showcaseAction == "showcase" then showcaseRequest.id = payload.id end
		local showcase = model.incomePreview(profile, at, showcaseRequest)
		return true, {requestKind = "detail", id = payload.id, placement = placement, showcase = showcase}
	end

	local mergeRequest: {[string]: any} = {kind = "merge", ids = payload.ids}
	if payload.acknowledgedPlacedIds ~= nil then mergeRequest.acknowledgedPlacedIds = payload.acknowledgedPlacedIds end
	return true, {requestKind = "merge", preview = model.incomePreview(profile, at, mergeRequest)}
end

return IncomePreviewQuery
