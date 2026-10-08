local Model=require("../src/shared/Model")
local Config=require("../src/shared/Config")
local function near(a,b) assert(math.abs(a-b)<1e-6,tostring(a).." != "..tostring(b)) end
local p=Model.new(0)
p.coins=100000000
for _=1,99 do assert(Model.command(p,"upgrade",{kind="hooks"},0).ok) end
assert(p.hooks==100)
near(100000000-p.coins,32835000)
local before=p.coins
assert(not Model.command(p,"upgrade",{kind="hooks"},0).ok and p.coins==before)
p.luck=50;p.coinLevel=30
assert(not Model.command(p,"upgrade",{kind="luck"},0).ok)
assert(not Model.command(p,"upgrade",{kind="coins"},0).ok)
-- A level-ten merge is still deterministic and cannot be used as level-eleven input.
for _,f in ipairs(p.fish) do f.level=9;f.value=10*3^8;f.income=3.15^8 end
assert(Model.command(p,"merge",{ids={"f1","f2","f3"}},0).ok)
near(p.fish[1].value,10*19683)
near(p.fish[1].income,3.15^9)
assert(p.fish[1].level==10 and p.discovered.white_koi==10)
local p2=Model.new(0)
for _,f in ipairs(p2.fish) do f.level=10 end
assert(not Model.command(p2,"merge",{ids={"f1","f2","f3"}},0).ok and #p2.fish==3)
p2.fish[1].level=1;p2.fish[2].level=1;p2.fish[3].level=1;p2.fish[3].species=Config.Species[2].id
assert(not Model.command(p2,"merge",{ids={"f1","f2","f3"}},0).ok and #p2.fish==3)
-- Boost + permanent + coin upgrades: only time inside the boost window receives all factors.
local income=Model.new(100)
income.fish[1].placed=true;income.doubleIncome=true;income.coinLevel=30;income.boostUntil=1900;income.coins=0
assert(Model.settle(income,3700,false).ok)
near(income.coins,7.5)
assert(Model.settle(income,3700,true).ok);near(income.coins,7.5)
assert(not Model.settle(income,3699,true).ok);near(income.coins,7.5)
-- Daily reward follows the selected species' historical level. A first-level
-- target gets three level-one fish, while a progressed target is capped at
-- level six for future claims.
local daily=Model.new(86400)
for i=1,21 do daily.discovered[Config.Species[i].id]=1 end
daily.day=1;daily.dailyCaught=100
local claimed=Model.command(daily,"contract",{species="white_koi"},86500)
assert(claimed.ok and #claimed.fish==Config.Contract.rewardFishCount and claimed.fish[1].level==1)
near(claimed.fish[1].value,10)
near(claimed.fish[1].income,1)
assert(daily.discovered.white_koi==1)
assert(not Model.command(daily,"contract",{species="white_koi"},86501).ok)
assert(daily.contractDay==1)
-- A sale never removes lifetime collection progress and cannot be replayed.
local sold=Model.command(daily,"sell",{id=claimed.fish[1].id},86502)
assert(sold.ok and daily.discovered.white_koi==1)
local after=daily.coins
assert(not Model.command(daily,"sell",{id=claimed.fish[1].id},86503).ok and daily.coins==after)

local progressed=Model.new(86400)
for i=1,21 do progressed.discovered[Config.Species[i].id]=1 end
progressed.discovered.white_koi=5;progressed.day=1;progressed.dailyCaught=100
local progressedClaim=Model.command(progressed,"contract",{species="white_koi"},86500)
assert(progressedClaim.ok and progressedClaim.fish[1].level==5)
near(progressedClaim.fish[1].value,10*3^4)
near(progressedClaim.fish[1].income,1*3^4*1.05^4)

local capped=Model.new(86400)
for i=1,21 do capped.discovered[Config.Species[i].id]=1 end
capped.discovered.white_koi=10;capped.day=1;capped.dailyCaught=100
local cappedClaim=Model.command(capped,"contract",{species="white_koi"},86500)
assert(cappedClaim.ok and cappedClaim.fish[1].level==Config.Contract.maximumRewardLevel)
near(cappedClaim.fish[1].value,10*3^5)
near(cappedClaim.fish[1].income,1*3^5*1.05^5)

-- Existing high-level fish and historical discovery records are never
-- repriced or downgraded when a later contract is claimed.
local preserved=Model.new(86400)
for i=1,21 do preserved.discovered[Config.Species[i].id]=1 end
preserved.discovered.white_koi=9
preserved.day=1;preserved.dailyCaught=100
preserved.fish[1].level=7
preserved.fish[1].value=10*3^6
preserved.fish[1].income=3.15^6
local oldValue,oldIncome=preserved.fish[1].value,preserved.fish[1].income
local preservedClaim=Model.command(preserved,"contract",{species="white_koi"},86500)
assert(preservedClaim.ok and preserved.discovered.white_koi==9 and preserved.fish[1].level==7)
near(preserved.fish[1].value,oldValue)
near(preserved.fish[1].income,oldIncome)

-- Full-bag rejection is atomic: no contract day, fish, history or coins change.
local full=Model.new(86400)
for i=1,21 do full.discovered[Config.Species[i].id]=1 end
full.day=1;full.dailyCaught=100;full.hooks=99
assert(Model.command(full,"catch",{zone=1},86500,function() return 0 end).ok)
assert(Model.command(full,"catch",{zone=1},86501,function() return 0 end).ok)
assert(Model.command(full,"catch",{zone=1},86502,function() return 0 end).ok)
local fullCount, fullCoins, fullNextId = #full.fish, full.coins, full.nextId
assert(fullCount==300 and not Model.command(full,"contract",{species="white_koi"},86503).ok)
assert(#full.fish==fullCount and full.coins==fullCoins and full.nextId==fullNextId and full.contractDay==-1)

assert(not Model.command(daily,"catch",{zone=0/0},86504).ok)
assert(not Model.command(daily,"merge",{ids={}},86504).ok)
print("ModelEdges.spec: caps, level10, value conservation, stacking, contracts, replay PASS")
