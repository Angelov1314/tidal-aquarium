--!strict
local Monetization = {}
Monetization.__index = Monetization

local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")

function Monetization.new(config: any, model: any, storage: any, changed: (Player, string?) -> ())
	return setmetatable({config = config, model = model, storage = storage, changed = changed, policyCache = {}}, Monetization)
end

function Monetization:_configured(): boolean
	local products = self.config.Products or {}
	-- Income products can become coins, and coins buy luck.  Do not enable them until
	-- the experience has an explicitly reviewed policy path and real IDs.
	return products.Enabled == true and products.PolicyReviewed == true
		and type(products.DoubleIncomePassId) == "number" and products.DoubleIncomePassId > 0
		and type(products.BoostProductId) == "number" and products.BoostProductId > 0
end

function Monetization:availableFor(player: Player): (boolean, string)
	if not self:_configured() then
		return false, "付费功能未配置：演示版不会发起 Robux 购买。"
	end
	local cached = self.policyCache[player.UserId]
	if cached and cached.expires > os.clock() then return cached.allowed, cached.reason end
	local ok, policy = pcall(function() return PolicyService:GetPolicyInfoForPlayerAsync(player) end)
	local allowed, reason = true, ""
	if not ok or type(policy) ~= "table" then allowed, reason = false, "无法验证付费随机物品政策，已关闭购买。"
	elseif policy.ArePaidRandomItemsRestricted == true then allowed, reason = false, "该地区/账户不允许此类付费路径。" end
	self.policyCache[player.UserId] = {allowed = allowed, reason = reason, expires = os.clock() + 60}
	return allowed, reason
end

function Monetization:refreshOwnership(player: Player, profile: any, settleOnline: boolean?): boolean
	if self.storage:isSaving(player) or self.storage:isLost(player) then return false end
	profile = self.storage:get(player)
	if not profile then return false end
	local allowed = self:availableFor(player)
	-- A disabled or unverified policy path must not resurrect an entitlement that
	-- happened to be present in an older save.
	if not allowed then
		if profile.doubleIncome then profile.doubleIncome = false; self.storage:markDirty(player) end
		return false
	end
	local id = self.config.Products.DoubleIncomePassId
	local ok, owns = pcall(function() return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id) end)
	if not ok then return false end
	if profile.doubleIncome ~= owns then
		if settleOnline then self.model.settle(profile, os.time(), false) end
		profile.doubleIncome = owns
		self.storage:markDirty(player)
	end
	return owns
end

function Monetization:restorePass(player: Player, profile: any)
	if self:refreshOwnership(player, profile, true) then
		self.storage:save(player)
		self.changed(player, "已恢复双倍养殖收益。")
	end
end

function Monetization:promptPass(player: Player): (boolean, string)
	local allowed, reason = self:availableFor(player)
	if not allowed then return false, reason end
	local ok = pcall(function() MarketplaceService:PromptGamePassPurchase(player, self.config.Products.DoubleIncomePassId) end)
	return ok, ok and "已打开购买窗口。" or "无法打开购买窗口。"
end

function Monetization:promptBoost(player: Player): (boolean, string)
	local allowed, reason = self:availableFor(player)
	if not allowed then return false, reason end
	local ok = pcall(function() MarketplaceService:PromptProductPurchase(player, self.config.Products.BoostProductId) end)
	return ok, ok and "已打开购买窗口。" or "无法打开购买窗口。"
end

function Monetization:bind()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not self:_configured() or not purchased or passId ~= self.config.Products.DoubleIncomePassId then return end
		if self.storage:isSaving(player) or self.storage:isLost(player) then return end
		local profile = self.storage:get(player)
		if not profile then return end
		self.model.settle(profile, os.time(), false)
		profile.doubleIncome = true
		self.storage:markDirty(player)
		self.storage:save(player)
		self.changed(player, "双倍养殖收益已启用。")
	end)
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		if not self:_configured() or receiptInfo.ProductId ~= self.config.Products.BoostProductId then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local player = game:GetService("Players"):GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local ok = self.storage:transaction(player, function(profile)
			profile.receipts = profile.receipts or {}
			if profile.receipts[purchaseId] then return true end
			self.model.settle(profile, os.time(), false)
			profile.boostUntil = math.max(profile.boostUntil or 0, os.time()) + 1800
			profile.receipts[purchaseId] = os.time()
			return true
		end)
		if not ok then return Enum.ProductPurchaseDecision.NotProcessedYet end
		self.changed(player, "30 分钟双倍养殖收益已到账。")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

return Monetization
