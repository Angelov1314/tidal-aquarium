-- Studio-only fixtures: visual callbacks never award fish or currency.
local player=game.Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui")
local scripts=player:WaitForChild("PlayerScripts")
local Catch=require(scripts:WaitForChild("CatchPresentation"))
local Config=require(game.ReplicatedStorage:WaitForChild("FishingShared"):WaitForChild("Config"))
local fixture=Instance.new("ScreenGui"); fixture.Name="CatchVFXFixture"; fixture.Parent=gui
local bag=Instance.new("Frame"); bag.Size=UDim2.fromOffset(44,44); bag.Position=UDim2.fromOffset(24,24); bag.BackgroundTransparency=1; bag.Parent=fixture
local ground=Instance.new("Part"); ground.Name="CatchVFXGround"; ground.Anchored=true; ground.CanCollide=false
ground.Size=Vector3.new(24,1,24); ground.Position=Vector3.new(5000,3,4996); ground.Transparency=1; ground.Parent=workspace
local controller
local function expect(v,m) assert(v,m) end
local ok,err=pcall(function()
	-- World/GUI startup can stall rendering; begin only after rendered frames.
	for _=1,3 do game:GetService("RunService").RenderStepped:Wait() end
	local rare="white_koi"
	for id,species in pairs(Config.SpeciesById) do if species.rarity>=4 then rare=id; break end end
	local highCount,lowCount
	for _,tier in ipairs({"high","low","off"}) do
		local cues={}
		controller=Catch.new({config=Config,overlayParent=gui,vfxQuality=tier,
			getBagTarget=function() return bag end, getFloatPosition=function() return Vector3.new(5000,1.2,5000) end,
			audioPlay=function(name) cues[name]=(cues[name] or 0)+1 end})
		local fish={}
		for i=1,3 do fish[i]={id="vfx"..i,species=rare,level=1,size=2,mutation=1} end
		local event={kind="catch",batchId="vfx:"..tier,count=100,zone=1,fish=fish}
		expect(controller:playBatch(event),"batch rejected")
		expect(not controller:playBatch(event),"duplicate replay")
		local deadline=os.clock()+8
		repeat game:GetService("RunService").RenderStepped:Wait() until cues.BagCollect or os.clock()>deadline
		expect(cues.FishLand==1 and cues.BagCollect==1,"audio timing/callback regression: land="..tostring(cues.FishLand).." bag="..tostring(cues.BagCollect))
		local vfx=controller.vfx
		expect(vfx and #vfx.slots==4 and vfx.bursts<=4 and vfx.emitted<=33,"100 fish exceeds VFX cap")
		for _,slot in ipairs(vfx.slots) do expect(not slot.light.Enabled,"completed burst left a light enabled") end
		if tier=="high" then highCount=vfx.emitted; expect(highCount==33,"landing bursts missing")
		elseif tier=="low" then lowCount=vfx.emitted; expect(lowCount==14 and lowCount<highCount,"mobile reduction missing")
		else expect(vfx.emitted==0,"off emits particles") end
		print("CATCH_VFX_TIER_PASS",tier,vfx.emitted,vfx.bursts)
		controller:destroy(); controller=nil
	end
	controller=Catch.new({config=Config,overlayParent=gui,vfxQuality="high",getBagTarget=function() return bag end,
		getFloatPosition=function() return Vector3.new(5000,1.2,5000) end})
	controller:playBatch({kind="catch",batchId="vfx:cancel",count=1,zone=1,fish={{id="cancel",species="white_koi",level=1,size=2,mutation=1}}})
	controller:cancel("test")
	expect(controller.vfx==nil and #controller.worldFolder:GetChildren()==0,"cancel leaked VFX")
	controller:destroy(); controller=nil
	print("CATCH_VFX_SMOKE_PASS","high/low/off,100-fish cap,audio,dedupe,cancel,destroy")
end)
if controller then controller:destroy() end
fixture:Destroy(); ground:Destroy()
if not ok then warn("CATCH_VFX_SMOKE_FAIL: "..tostring(err)) end
