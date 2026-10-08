-- Included ONLY in qa.project.json, never the playable delivery.
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local ServerScriptService=game:GetService("ServerScriptService")
local function clone(value)
    if type(value)~="table" then return value end
    local out={} for k,v in pairs(value) do out[k]=clone(v) end return out
end
local function destinationToVector3(point)
    return Vector3.new(point.x,point.y,point.z)
end
local ok,err=xpcall(function()
    local service=require(ServerScriptService:WaitForChild("FishingServer"):WaitForChild("FishingService"))
    local world=require(ServerScriptService.FishingServer.World)
    local model=require(ReplicatedStorage:WaitForChild("FishingShared").Model)
    local config=require(ReplicatedStorage.FishingShared.Config)
    local location=require(ReplicatedStorage.FishingShared.FishingLocation)
    local player=Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
    local deadline=os.clock()+30
    while not service.getProfile(player) and os.clock()<deadline do task.wait(.1) end
    local profile=assert(service.getProfile(player),"profile loaded")
    local character = player.Character or player.CharacterAdded:Wait()
    character:WaitForChild("HumanoidRootPart")
    local clientNonce="studio-smoke-client-session"
    local protocolState=service.getProtocolState(player)
    local clientEpoch=protocolState and protocolState.stateEpoch or nil
    local laneSeq={lock=0,upgrade=0,exchange=0,useItem=0}
    local laneRequests={}
    local function action(name,payload)
        local body=clone(payload or {})
        if name=="snapshot" then
            if clientEpoch then body={stateEpoch=clientEpoch} else body={handshake=true,clientSessionNonce=clientNonce} end
        elseif name=="lock" or name=="upgrade" or name=="exchange" or name=="useItem" then
            local identity=tostring(body.requestId or body.id or body.kind or name)
            local previous=laneRequests[name]
            if previous and previous.identity==identity then
                body=clone(previous.body)
            else
                laneSeq[name]=(laneSeq[name] or 0)+1
                body.mutationProtocol=1
                body.stateEpoch=clientEpoch
                body.operationSeq=laneSeq[name]
                laneRequests[name]={identity=identity,body=clone(body)}
            end
        end
        local response=service.handle(player,name,body)
        if type(response)=="table" and type(response.state)=="table" then
            clientEpoch=response.state.stateEpoch or clientEpoch
            for lane,value in pairs(response.state.mutationWatermarks or {}) do laneSeq[lane]=value end
        end
        return response
    end
    local smokeZoneCount=9
    local themedProps={
        [6]={"MoonPool","MoonLantern"},
        [7]={"BasaltPillar","MagmaCore"},
        [8]={"SignalOrb","OrbitRing"},
        [9]={"LabTank","LabPipe"},
    }
    assert(require(script.Parent.StorageSpec)(),"storage retry/failure suite")
    print("FISHING_STORAGE_PASS: callback retry, failed write, stable profile identity")
    assert(#config.Species>=70 and #config.Rarities==7 and #config.Zones>=9,"expanded catalog")
    assert(workspace.FishingWorld:FindFirstChild("Aquarium8"),"eight plots")
    assert(action("snapshot").state.storageMode=="session","Studio must not touch live saves")
    assert(not action("catch",{zone=1}).ok,"client cannot award fish")
    assert(not action("travel",{zone=5}).ok,"locked zone travel")
    assert(not action("purchasePass").ok,"unconfigured shop disabled")
    player.Character:PivotTo(CFrame.new(0,8,-15))
    task.wait(.3)
    assert(not action("toggleFishing").ok,"offshore position rejected")
    assert(action("merge",{ids={profile.fish[1].id,profile.fish[1].id,profile.fish[2].id}}).ok==false,"duplicate IDs rejected")
    assert(action("merge",{ids={profile.fish[1].id,profile.fish[2].id,profile.fish[3].id}}).ok,"starter merge")
    assert(#profile.fish==1 and profile.fish[1].level==2 and math.abs(profile.fish[1].income-3.15)<1e-6)
    assert(action("place",{id=profile.fish[1].id}).ok,"place fish")
    assert(not action("sell",{id=profile.fish[1].id}).ok,"placed fish cannot sell")
    local upgradeInfo=action("snapshot").state.upgrades.hooks
    assert(action("upgrade",{kind="hooks",expectedLevel=upgradeInfo.level,expectedCost=upgradeInfo.cost}).ok and profile.hooks==2,"coin cost upgrade")
    -- QA-only fixture: keep saved progression semantics visible while checking
    -- that live location is derived from the character, not profile.zone.
    profile.zone = smokeZoneCount
    -- Every unlocked zone must use the supported over-water pier tip. The
    -- marker and the shared numeric contract make this visible and testable.
    for zoneIndex=1,smokeZoneCount do
        assert(action("travel",{zone=zoneIndex}).ok,"dock travel "..zoneIndex)
        task.wait(.1)
        local entry=config.Zones[zoneIndex]
        local destination=location.travelPoint(entry.center)
        local rootPart=player.Character:FindFirstChild("HumanoidRootPart")
        assert(rootPart and (rootPart.Position-destinationToVector3(destination)).Magnitude < 1,"travel destination mismatch")
        assert(rootPart.Position.Z-entry.center.z>70,"travel must be beyond island radius")
        assert(world.getZone(player)==zoneIndex,"travel destination must be fishable")
        local zoneModel=workspace.FishingWorld:FindFirstChild("Zone"..zoneIndex)
        assert(zoneModel,"zone model missing")
        local marker=zoneModel:FindFirstChild("FishingMarker")
        assert(marker and marker:GetAttribute("Zone")==zoneIndex,"visible fishing marker missing")
        local supportRayParams=RaycastParams.new()
        supportRayParams.FilterType=Enum.RaycastFilterType.Exclude
        supportRayParams.FilterDescendantsInstances={player.Character}
        local dockHit=workspace:Raycast(Vector3.new(destination.x,31,destination.z),Vector3.new(0,-32,0),supportRayParams)
        assert(dockHit and dockHit.Instance and dockHit.Instance.Name=="DockPlank","travel must stand over a DockPlank")
        if zoneIndex>=6 then
            assert(entry.themeOnly==true and type(entry.theme)=="string","theme-only zone contract")
            local themeSet=zoneModel:FindFirstChild("ThemeEnvironment_"..entry.theme)
            assert(themeSet,"theme environment missing "..tostring(entry.theme))
            local propFound=false
            for _,propName in ipairs(themedProps[zoneIndex] or {}) do
                if themeSet:FindFirstChild(propName,true) then propFound=true break end
            end
            assert(propFound,"theme prop missing "..tostring(entry.theme))
            local themedCast=workspace:Raycast(Vector3.new(entry.center.x,31,entry.center.z+location.Cast.zOffset),Vector3.new(0,-80,0),supportRayParams)
            assert(themedCast and themedCast.Material==Enum.Material.Water,"theme cast target must resolve to water")
        end
    end
    assert(action("travel",{zone=1}).ok,"dock travel")
    task.wait(.4)
    assert(world.getZone(player)==1,"server derived zone")
    player.Character:PivotTo(CFrame.new(0,7,42))
    assert(world.getZone(player)==nil,"inland promenade must not count as a fishing zone")
    player.Character:PivotTo(CFrame.new(8,7,76))
    assert(world.getZone(player)==nil,"off-pier position must not count as a fishing zone")
    player.Character:PivotTo(CFrame.new(0,7,76))
    assert(world.getZone(player)==1,"return to supported pier")
    local castHit=workspace:Raycast(Vector3.new(0,31,location.Cast.zOffset),Vector3.new(0,-80,0))
    assert(castHit and castHit.Material==Enum.Material.Water,"cast target must resolve to over-water terrain")
    local dockState = action("snapshot").state
    assert(dockState.zone == smokeZoneCount and dockState.currentZone == 1,"snapshot must separate unlock zone from current dock zone")
    assert(type(dockState.xp)=="number" and type(dockState.playerLevel)=="number" and type(dockState.xpToNextLevel)=="number" and type(dockState.items)=="table" and type(dockState.activeBoosts)=="table","progression snapshot contract")
    local before=profile.totalCaught
    assert(action("toggleFishing").ok,"begin actual 20sec round")
    task.wait(22)
    assert(profile.totalCaught==before+2,"real timer awards exactly2 hooks")
    assert(action("toggleFishing").ok,"stop auto fishing")
    local heldFish
    for _, fish in ipairs(profile.fish) do if not fish.placed then heldFish=fish; break end end
    assert(heldFish and action("showcase",{id=heldFish.id}).ok,"showcase fish")
    local heldId=action("snapshot").state.showcaseFishId
    assert(heldId==heldFish.id,"showcase snapshot id")
    task.wait(.1)
    local showcaseModel=character:FindFirstChild("OpenCloudFishShowcase")
    assert(showcaseModel and showcaseModel:GetAttribute("ShowcaseFishId")==heldId,"showcase model must be server-owned")
    assert(action("toggleFishing").ok,"showcase starts fishing")
    assert(action("snapshot").state.showcaseFishId==heldId,"fishing preserves held trait")
    task.wait(.1)
    assert(not character:FindFirstChild("OpenCloudFishShowcase"),"fishing temporarily hides showcase model")
    assert(action("toggleFishing").ok,"stop showcase fishing")
    task.wait(.1)
    assert(character:FindFirstChild("OpenCloudFishShowcase"),"stopping fishing restores showcase model")
    assert(action("hideFish").ok,"hide showcase fish")
    task.wait(.1)
    assert(action("snapshot").state.showcaseFishId==nil and not character:FindFirstChild("OpenCloudFishShowcase"),"hide clears showcase model")
    local tank=workspace.FishingWorld:FindFirstChild("Aquarium1")
    assert(tank and #tank.SwimmingFish:GetChildren()==1,"placed fish rendered")
    print("FISHING_REALTIME_PASS: 20sec/2hooks, merge, place, upgrade, server zone, disabled purchase")
    -- Keep the service record live while replacing only its profile table
    -- contents. This fixture exercises request replay and returned snapshots
    -- without racing the client presentation smoke, which waits for Ready.
    local featureSavedProfile=clone(profile)
    local featureSavedPivot=character:GetPivot()
    local featureFixture=model.new(os.time())
    featureFixture.zone=smokeZoneCount
    featureFixture.bagCapacity=300
    for k in pairs(profile) do profile[k]=nil end
    for k,v in pairs(featureFixture) do profile[k]=clone(v) end
    assert(model.validate(profile),"service feature fixture profile")
    local featureSnapshot=action("snapshot").state
    local featureFish=featureSnapshot.fish[1]
    assert(featureFish and type(featureFish.weightGrams)=="number" and featureFish.weightGrams>0,"snapshot fish weight")
    assert(type(featureFish.trait)=="string" and #featureFish.trait>0,"snapshot fish trait")
    assert(type(featureFish.salePrice)=="number" and featureFish.salePrice>0,"snapshot fish sale price")
    assert(type(featureSnapshot.items)=="table" and type(featureSnapshot.activeBoosts)=="table","snapshot item/boost maps")
    local exchangeIds={featureSnapshot.fish[1].id,featureSnapshot.fish[2].id,featureSnapshot.fish[3].id}
    local exchangePayload={recipeId="exchange_luck",ids=exchangeIds,requestId="studio-exchange-1"}
    local exchangeResult=action("exchange",exchangePayload)
    assert(exchangeResult.ok and exchangeResult.state and exchangeResult.state.items.luck_tonic==1,"service exchange snapshot")
    assert(#profile.fish==0,"exchange consumes exactly the requested fish")
    local exchangeReplay=action("exchange",exchangePayload)
    assert(exchangeReplay.ok and exchangeReplay.state.items.luck_tonic==1 and #profile.fish==0,"exchange replay does not consume again")
    local usePayload={itemId="luck_tonic",requestId="studio-use-1"}
    local useResult=action("useItem",usePayload)
    local activeLuck=useResult.state and useResult.state.activeBoosts and useResult.state.activeBoosts.luck
    assert(useResult.ok and useResult.state.items.luck_tonic==0 and activeLuck and activeLuck.kind=="luck" and activeLuck.remainingSeconds>0,"service useItem boost snapshot")
    local useReplay=action("useItem",usePayload)
    local replayBoost=useReplay.state and useReplay.state.activeBoosts and useReplay.state.activeBoosts.luck
    assert(useReplay.ok and useReplay.state.items.luck_tonic==0 and replayBoost and replayBoost.untilTime==activeLuck.untilTime,"useItem replay does not consume again")
    assert(model.validate(profile),"service feature fixture remains valid")
    for k in pairs(profile) do profile[k]=nil end
    for k,v in pairs(featureSavedProfile) do profile[k]=clone(v) end
    character:PivotTo(featureSavedPivot)
    assert(model.validate(profile),"restored service profile")
    local restoredFeatureState=action("snapshot").state
    restoredFeatureState.fishing=false
    world.update(player,restoredFeatureState)
    task.wait(.1)
    assert(not character:FindFirstChild("OpenCloudFishShowcase"),"restored hidden showcase state")
    print("FISHING_ECONOMY_SERVICE_PASS: snapshot fish fields, exchange/useItem replay, boosts, showcase visual hide/restore")
    local saved=clone(profile)
    profile.hooks=100
    local oldCount=#profile.fish
    local caught=model.command(profile,"catch",{zone=1},os.time(),function() return .3 end)
    assert(caught.ok and #profile.fish==oldCount+100,"100hook batch")
    profile.coins=1e12
    assert(not action("upgrade",{kind="hooks"}).ok and profile.hooks==100,"hard hook cap")
    -- Fill bag to capacity, then ensure scheduler refuses to start.
    while #profile.fish-1+100<=300 do assert(model.command(profile,"catch",{zone=1},os.time(),function() return .3 end).ok) end
    assert(not action("toggleFishing").ok,"capacity checked before round")
    for k in pairs(profile) do profile[k]=nil end
    for k,v in pairs(saved) do profile[k]=v end
    assert(model.validate(profile))
    world.update(player,model.snapshot(profile,os.time()))
    assert(action("visitAquarium").ok,"visit assigned aquarium")
    assert(world.getZone(player)==nil,"aquarium is not a fishing zone")
    local aquariumState = action("snapshot").state
    assert(aquariumState.zone == smokeZoneCount and aquariumState.currentZone == nil,"aquarium snapshot must not report unlock zone as current")
    assert(not action("toggleFishing").ok,"cannot fish from aquarium")
    assert(action("travel",{zone=1}).ok,"return to dock")
    task.wait(.4)
    local returnedState = action("snapshot").state
    assert(returnedState.zone == smokeZoneCount and returnedState.currentZone == 1,"post-travel current zone mismatch")
    -- Use an isolated character fixture so this smoke never kills or races the
    -- real test player while checking the server's dead-player guard.
    local deadDummy=Instance.new("Model")
    deadDummy.Name="ShoreDeadDummy"
    local deadRoot=Instance.new("Part")
    deadRoot.Name="HumanoidRootPart"
    deadRoot.Size=Vector3.new(2,2,1)
    deadRoot.CFrame=CFrame.new(0,7,76)
    deadRoot.Anchored=true
    deadRoot.CanCollide=false
    deadRoot.Parent=deadDummy
    local deadHumanoid=Instance.new("Humanoid")
    deadHumanoid.Parent=deadDummy
    deadHumanoid.Health=0
    assert(world.getZone({Character=deadDummy})==nil,"dead player must not fish")
    deadDummy:Destroy()
    print("FISHING_SHORE_PASS: nine over-water travel points, themed props, markers, cast water, inland/off-pier/aquarium/dead rejection")
    print("FISHING_CURRENT_ZONE_PASS: unlock=9 dock=1 aquarium=nil")
    print("FISHING_SMOKE_PASS:"..tostring(#config.Species).."species/7tiers/"..tostring(#config.Zones).."zones/8plots,100hooks,capacity,merge,replay,storage")
    ReplicatedStorage:SetAttribute("StudioSmokeReady", true)
end,debug.traceback)
if not ok then warn("FISHING_SMOKE_FAIL: "..tostring(err)) end
