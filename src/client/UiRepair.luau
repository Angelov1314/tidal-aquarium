--!strict
-- Pure client-side state helpers for the fishing UI repair.  The server remains
-- authoritative; these functions only prevent accidental duplicate requests
-- and keep controls honest while a response is in flight.

-- In a Rojo build this ModuleScript is cloned under PlayerScripts, while the
-- shared folder is a sibling under ReplicatedStorage.  Resolve that topology
-- explicitly; the CLI branch keeps the pure-Luau suite path intact.
local Config = if script then require(game:GetService("ReplicatedStorage"):WaitForChild("FishingShared"):WaitForChild("Config")) else require("../shared/Config")

local UiRepair = {}
local SALE_EPSILON = 0.000001

export type ActionState = {
	enabled: boolean,
	reason: string,
}

local function disabled(reason: string): ActionState
	return {enabled = false, reason = reason}
end

local function enabled(): ActionState
	return {enabled = true, reason = ""}
end

local function displayNumber(value: any, fallback: string): string
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then return fallback end
	return tostring(math.max(0, math.floor(number)))
end

function UiRepair.saleConfirmationKey(fish: any?, showcaseFishId: string?): string
	return table.concat({
		tostring(fish and fish.id), tostring(fish and fish.species), tostring(fish and fish.level),
		tostring(fish and fish.value), tostring(fish and fish.income), tostring(fish and fish.weightGrams),
		tostring(fish and fish.trait), tostring(fish and fish.locked), tostring(fish and fish.placed),
		tostring(fish and fish.salePrice), tostring(showcaseFishId),
	}, "|")
end

function UiRepair.saleConfirmationState(fish: any?, expectedPrice: number?, key: string?, showcaseFishId: string?): ActionState
	if not fish then return disabled("鱼已变化，请重新确认") end
	if fish.locked == true or fish.placed == true then return disabled("鱼状态已变化，请重新确认") end
	if showcaseFishId ~= nil and tostring(showcaseFishId) == tostring(fish.id) then return disabled("展示中的鱼不能消耗，请先收起展示") end
	local quote = fish.salePrice
	if type(expectedPrice) ~= "number" or expectedPrice ~= expectedPrice or expectedPrice == math.huge or expectedPrice == -math.huge or expectedPrice < 0 then return disabled("售价待同步，请刷新") end
	if type(quote) ~= "number" or quote ~= quote or quote == math.huge or quote == -math.huge or quote < 0 then return disabled("售价待同步，请刷新") end
	if math.abs(expectedPrice - quote) > SALE_EPSILON or key ~= UiRepair.saleConfirmationKey(fish, showcaseFishId) then return disabled("鱼状态已变化，请重新确认") end
	return enabled()
end

function UiRepair.countUnplaced(fish: {any}?): number
	local count = 0
	for _, item in ipairs(fish or {}) do
		if item.placed ~= true then count += 1 end
	end
	return count
end

function UiRepair.countPlaced(fish: {any}?): number
	local count = 0
	for _, item in ipairs(fish or {}) do
		if item.placed == true then count += 1 end
	end
	return count
end

function UiRepair.actionState(action: string, fish: any?, context: {[string]: any}?): ActionState
	context = context or {}
	if action == "place" then
		if not fish or fish.placed == true then return disabled("鱼已在水族馆") end
		if (context.placedCount or 0) >= (context.tankCapacity or 0) then return disabled("水族馆已满") end
		return enabled()
	elseif action == "remove" then
		if not fish or fish.placed ~= true then return disabled("鱼不在水族馆") end
		if (context.bagCount or 0) >= (context.bagCapacity or 0) then return disabled("背包已满") end
		return enabled()
	elseif action == "sell" then
		if not fish then return disabled("请选择一条鱼") end
		if fish.locked == true then return disabled("已锁定，先解除保护") end
		if fish.placed == true then return disabled("已入缸，先移出水族馆") end
		if context.showcaseFishId ~= nil and tostring(context.showcaseFishId) == tostring(fish.id) then return disabled("展示中的鱼不能消耗，请先收起展示") end
		if context.requireSaleQuote == true then
			local quote = fish.salePrice
			if type(quote) ~= "number" or quote ~= quote or quote == math.huge or quote == -math.huge or quote < 0 then return disabled("售价待同步，请刷新") end
		end
		return enabled()
	elseif action == "upgrade" then
		local upgrade = context.upgrade
		if type(upgrade) ~= "table" then return disabled("升级信息不可用") end
		if (upgrade.level or 0) >= (upgrade.max or math.huge) then return disabled("已达上限") end
		if (context.coins or 0) < (upgrade.cost or math.huge) then return disabled("金币不足") end
		return enabled()
	elseif action == "travel" then
		if context.unlocked ~= true then return disabled("该水域尚未解锁") end
		return enabled()
	elseif action == "unlock" then
		if context.next ~= true then return disabled("请先解锁前一水域") end
		local currentLevel = tonumber(context.level) or 0
		local requiredLevel = tonumber(context.requiredLevel)
		if requiredLevel and currentLevel < requiredLevel then
			return disabled("等级不足 · 当前 Lv." .. displayNumber(currentLevel, "0") .. " / 需要 Lv." .. displayNumber(requiredLevel, "--"))
		end
		local discoveryCount = tonumber(context.discoveryCount) or 0
		local requiredDiscoveries = tonumber(context.requiredDiscoveries) or math.huge
		if discoveryCount < requiredDiscoveries then
			return disabled("发现数量不足 · 当前 " .. displayNumber(discoveryCount, "0") .. " / 需要 " .. displayNumber(requiredDiscoveries, "--") .. " 种")
		end
		local coins = tonumber(context.coins) or 0
		local cost = tonumber(context.cost) or math.huge
		if coins < cost then
			return disabled("金币不足 · 当前 " .. displayNumber(coins, "0") .. " / 需要 " .. displayNumber(cost, "--") .. " 金币")
		end
		return enabled()
	elseif action == "contract" then
		if context.ready ~= true then return disabled("委托条件不足") end
		local rewardCount = math.floor(tonumber(context.rewardFishCount) or Config.Contract.rewardFishCount)
		if rewardCount < 1 then return disabled("委托奖励配置不可用") end
		if (context.bagCount or 0) + rewardCount > (context.bagCapacity or 0) then return disabled("背包空间不足") end
		return enabled()
	elseif action == "toggleFishing" then
		if context.stopping == true then return enabled() end
		if type(context.currentZone) ~= "number" then return disabled("请先前往可钓鱼水域") end
		if (context.bagCount or 0) + (context.hooks or 0) > (context.bagCapacity or 0) then return disabled("背包空间不足") end
		return enabled()
	end
	return enabled()
end

-- Keep both responsive unlock panels on a complete condition summary.  The
-- renderer may wrap this text into measured rows on narrow layouts.
-- The server still owns the actual command decision; this only describes the
-- snapshot values currently visible to the player.
function UiRepair.unlockRequirements(context: {[string]: any}?): string
	context = context or {}
	if context.unlocked == true then return "已解锁" end
	local parts = {}
	if context.next ~= true then table.insert(parts, "前置水域未解锁") end
	local requiredLevel = tonumber(context.requiredLevel)
	if requiredLevel then
		table.insert(parts, "等级 Lv." .. displayNumber(context.level, "0") .. "/" .. displayNumber(requiredLevel, "--"))
	else
		table.insert(parts, "等级不限")
	end
	table.insert(parts, "金币 " .. displayNumber(context.coins, "0") .. "/" .. displayNumber(context.cost, "--"))
	table.insert(parts, "发现 " .. displayNumber(context.discoveryCount, "0") .. "/" .. displayNumber(context.requiredDiscoveries, "--"))
	return table.concat(parts, " · ")
end

function UiRepair.unlockButtonText(context: {[string]: any}?, state: ActionState, waiting: boolean?): string
	context = context or {}
	if waiting == true then return "处理中…" end
	if context.unlocked == true then return "前往" end
	if state.enabled then return "解锁" end
	if context.next ~= true then return "前置未解锁" end
	local requiredLevel = tonumber(context.requiredLevel)
	if requiredLevel and (tonumber(context.level) or 0) < requiredLevel then return "等级不足" end
	if (tonumber(context.discoveryCount) or 0) < (tonumber(context.requiredDiscoveries) or math.huge) then return "发现不足" end
	if (tonumber(context.coins) or 0) < (tonumber(context.cost) or math.huge) then return "金币不足" end
	return "条件不足"
end

function UiRepair.mergeState(selected: {any}?, context: {[string]: any}?): {enabled: boolean, reason: string, hasPlaced: boolean, requiresPlacedConfirmation: boolean?}
	local items = selected or {}
	context = context or {}
	local hasPlaced = false
	for _, fish in ipairs(items) do
		if fish and fish.placed == true then hasPlaced = true end
	end
	if #items ~= 3 then return {enabled = false, reason = "需要选择三条鱼", hasPlaced = hasPlaced} end
	for _, fish in ipairs(items) do
		if fish and context.showcaseFishId ~= nil and tostring(context.showcaseFishId) == tostring(fish.id) then
			return {enabled = false, reason = "展示中的鱼不能消耗，请先收起展示", hasPlaced = hasPlaced}
		end
	end
	local first = items[1]
	if not first or first.level >= 10 then return {enabled = false, reason = "已达最高等级", hasPlaced = hasPlaced} end
	if first.locked == true then return {enabled = false, reason = "合成材料已锁定，请先解除保护", hasPlaced = hasPlaced} end
	for index = 2, 3 do
		local fish = items[index]
		if not fish or fish.locked == true then
			return {enabled = false, reason = "合成材料已锁定，请先解除保护", hasPlaced = hasPlaced}
		end
		if fish.species ~= first.species or fish.level ~= first.level then
			return {enabled = false, reason = "需要三条相同物种、相同等级的鱼", hasPlaced = hasPlaced}
		end
	end
	local bagAfter = context.bagCount
	if type(bagAfter) == "number" and type(context.bagCapacity) == "number" then
		for _, fish in ipairs(items) do if fish.placed ~= true then bagAfter -= 1 end end
		if bagAfter + 1 > context.bagCapacity then return {enabled = false, reason = "背包空间不足", hasPlaced = hasPlaced} end
	end
	return {enabled = true, reason = "", hasPlaced = hasPlaced, requiresPlacedConfirmation = hasPlaced}
end

function UiRepair.selectionAfterResponse(selected: {string}, submitted: {string}, success: boolean): {string}
	local result = {}
	if not success then
		for _, id in ipairs(selected) do table.insert(result, id) end
		return result
	end
	for _, id in ipairs(selected) do
		if not table.find(submitted, id) then table.insert(result, id) end
	end
	return result
end

-- Exchange selection is deliberately pure and conservative.  The server still
-- revalidates every rule, but the client should never present a confirmation
-- for fish that are locked, placed, above the required level, below the recipe
-- rarity, or duplicated in the same request.
function UiRepair.exchangeFishState(fish: any?, recipe: any?, rarity: number?, showcaseFishId: string?): ActionState
	if not fish then return disabled("请选择鱼") end
	if not recipe then return disabled("请选择兑换配方") end
	if fish.locked == true then return disabled("已锁定") end
	if showcaseFishId ~= nil and tostring(showcaseFishId) == tostring(fish.id) then return disabled("展示中的鱼不能消耗，请先收起展示") end
	if fish.placed == true then return disabled("已入缸") end
	if tonumber(fish.level) ~= tonumber(recipe.requiredLevel or 1) then return disabled("需要 Lv." .. tostring(recipe.requiredLevel or 1)) end
	local fishRarity = tonumber(fish.rarity or rarity or 0) or 0
	if fishRarity < (tonumber(recipe.minRarity) or 1) then return disabled("品质不足") end
	return enabled()
end

function UiRepair.exchangeSelectionState(selected: {any}?, recipe: any?, context: {[string]: any}?, showcaseFishId: string?): {enabled: boolean, reason: string, duplicate: boolean}
	local items = selected or {}
	local seen: {[string]: boolean} = {}
	local duplicate = false
	if #items ~= tonumber(recipe and recipe.fishCount or 3) then
		return {enabled = false, reason = "需要选择三条符合条件的鱼", duplicate = false}
	end
	for _, fish in ipairs(items) do
		local id = tostring(fish and fish.id or "")
		if id == "" or seen[id] then duplicate = true end
		seen[id] = true
		local state = UiRepair.exchangeFishState(fish, recipe, context and context[id], showcaseFishId)
		if not state.enabled then return {enabled = false, reason = state.reason, duplicate = duplicate} end
	end
	if duplicate then return {enabled = false, reason = "兑换材料不能重复", duplicate = true} end
	return {enabled = true, reason = "", duplicate = false}
end

export type ExchangeSelectionReconciliation = {
	ids: {string},
	changed: boolean,
	key: string,
}

local function exchangeSelectionKey(ids: {string}, fishById: {[string]: any}, recipe: any?, rarityContext: {[string]: number}?, showcaseFishId: string?): string
	local parts = {
		tostring(recipe and recipe.id),
		tostring(recipe and recipe.fishCount or 3),
		tostring(recipe and recipe.requiredLevel or 1),
		tostring(recipe and recipe.minRarity or 1),
	}
	for _, id in ipairs(ids) do
		local fish = fishById[id]
		local rarity = rarityContext and rarityContext[id]
		local isShowcase = fish ~= nil and showcaseFishId ~= nil and tostring(showcaseFishId) == tostring(fish.id)
		table.insert(parts, table.concat({
			tostring(id), tostring(fish and fish.level), tostring(fish and fish.locked),
			tostring(fish and fish.placed), tostring(fish and fish.rarity or rarity), tostring(isShowcase),
		}, ":"))
	end
	return table.concat(parts, "|")
end

-- Reconcile the local material list against the current authoritative snapshot.
-- Only selected material state participates in the key, so an unchanged
-- confirmation survives routine snapshots while a missing/locked/placed/
-- showcased/recipe-incompatible material is removed and forces re-confirmation.
function UiRepair.reconcileExchangeSelection(ids: {string}?, fishList: {any}?, recipe: any?, rarityContext: {[string]: number}?, showcaseFishId: string?): ExchangeSelectionReconciliation
	local fishById: {[string]: any} = {}
	for _, fish in ipairs(fishList or {}) do
		local id = tostring(fish and fish.id or "")
		if id ~= "" and fishById[id] == nil then fishById[id] = fish end
	end
	local result = {}
	local seen: {[string]: boolean} = {}
	for _, rawId in ipairs(ids or {}) do
		local id = tostring(rawId)
		if id ~= "" and not seen[id] then
			local fish = fishById[id]
			local rarity = rarityContext and rarityContext[id]
			if UiRepair.exchangeFishState(fish, recipe, rarity, showcaseFishId).enabled then
				table.insert(result, id)
				seen[id] = true
			end
		end
	end
	local changed = #result ~= #(ids or {})
	if not changed then
		for index, rawId in ipairs(ids or {}) do
			if tostring(rawId) ~= result[index] then changed = true; break end
		end
	end
	return {
		ids = result,
		changed = changed,
		key = exchangeSelectionKey(result, fishById, recipe, rarityContext, showcaseFishId),
	}
end

function UiRepair.selectCheapestExchangeFish(fishList: {any}?, recipe: any?, rarityFor: ((any) -> number?)?): {string}
	local eligible = {}
	for _, fish in ipairs(fishList or {}) do
		local rarity = rarityFor and rarityFor(fish) or nil
		if UiRepair.exchangeFishState(fish, recipe, rarity).enabled then table.insert(eligible, fish) end
	end
	table.sort(eligible, function(a, b)
		local aPrice = tonumber(a.salePrice or a.value or math.huge) or math.huge
		local bPrice = tonumber(b.salePrice or b.value or math.huge) or math.huge
		if aPrice == bPrice then return tostring(a.id) < tostring(b.id) end
		return aPrice < bPrice
	end)
	local count = math.min(#eligible, tonumber(recipe and recipe.fishCount or 3) or 3)
	local result = {}
	for index = 1, count do table.insert(result, tostring(eligible[index].id)) end
	return result
end

-- A caller keeps the same id in its logical attempt state and passes it back
-- after a transport failure.  This helper is intentionally deterministic so a
-- retry cannot silently turn into a second logical attempt in UI state.
function UiRepair.selectionByIds(fishList: {any}?, ids: {string}?): {any}
	local result = {}
	local wanted: {[string]: boolean} = {}
	for _, id in ipairs(ids or {}) do wanted[tostring(id)] = true end
	for _, fish in ipairs(fishList or {}) do if wanted[tostring(fish.id)] then table.insert(result, fish) end end
	return result
end

export type RequestGate = {
	begin: (self: RequestGate, action: string, invoke: () -> any, complete: (boolean, any) -> ()) -> boolean,
	isPending: (self: RequestGate, action: string) -> boolean,
	anyPending: (self: RequestGate) -> boolean,
}

-- `spawn` is injected so this module can be tested without Roblox's scheduler.
-- The pending flag is set before spawn is called; a second click in the same
-- frame therefore cannot enqueue another RemoteFunction invocation.
function UiRepair.newRequestGate(spawn: ((() -> ()) -> ()), onPending: ((string, boolean) -> ())?): RequestGate
	local pending: {[string]: boolean} = {}
	local gate = {} :: any

	function gate:isPending(action: string): boolean
		return pending[action] == true
	end

	function gate:anyPending(): boolean
		for _, value in pairs(pending) do
			if value then return true end
		end
		return false
	end

	function gate:begin(action: string, invoke: () -> any, complete: (boolean, any) -> ()): boolean
		if gate:anyPending() then return false end
		pending[action] = true
		if onPending then onPending(action, true) end
		spawn(function()
			local ok, result = pcall(invoke)
			pending[action] = nil
			if onPending then onPending(action, false) end
			complete(ok, result)
		end)
		return true
	end

	return gate
end

return UiRepair
