-- Local fixed pools; no replicated world edits or per-frame world scans.
local RegionalVFX = {}
local names = {Lamp=true, MoonLantern=true, DockLantern=true, MagmaCore=true,
	DockMagmaGlow=true, SignalOrb=true, DockSignalOrb=true, ReagentBubble=true,
	DockLabBubble=true, HarborBeacon=true, RainbowBeacon=true}
local function anchor(parent, name)
	local p=Instance.new("Part")
	p.Name=name; p.Anchored=true; p.Transparency=1; p.CastShadow=false
	p.CanCollide=false; p.CanTouch=false; p.CanQuery=false
	p.Size=Vector3.new(.5,.1,.5); p.Parent=parent
	return p
end
function RegionalVFX.new(parent, config)
	local self={lights={}, glints={}, candidates={}, connections={}, elapsed=1, alive=true}
	local function register(p)
		if p:IsA("BasePart") and names[p.Name] then self.candidates[p]=true end
	end
	for _, p in ipairs(workspace:GetDescendants()) do register(p) end
	table.insert(self.connections,workspace.DescendantAdded:Connect(register))
	table.insert(self.connections,workspace.DescendantRemoving:Connect(function(p) self.candidates[p]=nil end))
	for i=1,config.LightPoolSize do
		local p=anchor(parent,"LocalLamp"..i)
		local light=Instance.new("PointLight")
		light.Name="LocalFill"; light.Enabled=false; light.Shadows=false
		light.Range=22; light.Brightness=1.5; light.Parent=p
		table.insert(self.lights,{part=p,light=light})
	end
	for i=1,config.GlintPoolSize do
		local p=anchor(parent,"WaterGlint"..i)
		local e=Instance.new("ParticleEmitter")
		e.Name="WaterSparkle"; e.Texture="rbxasset://textures/particles/sparkles_main.dds"
		e.Rate=0; e.Lifetime=NumberRange.new(.45,.8); e.Speed=NumberRange.new(0)
		e.LightEmission=.75; e.LightInfluence=.1; e.Color=ColorSequence.new(Color3.fromRGB(200,246,255))
		e.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(.35,.65),NumberSequenceKeypoint.new(1,0)})
		e.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1),NumberSequenceKeypoint.new(.3,.3),NumberSequenceKeypoint.new(1,1)})
		e.Parent=p; table.insert(self.glints,{part=p,emitter=e})
	end
	function self:update(position, quality, dt, character)
		if not self.alive then return end
		local budget=config.effectBudget(quality)
		local jumped=position and self.position and (position-self.position).Magnitude>80
		if self.quality~=quality or jumped or not position then
			for _, slot in ipairs(self.glints) do slot.emitter:Clear(); slot.emitter.Rate=0 end
			for _, slot in ipairs(self.lights) do slot.light.Enabled=false end
			self.elapsed=1
		end
		self.quality=quality; self.position=position; self.elapsed+=dt
		if self.elapsed<.5 then return end
		self.elapsed=0
		if not position or quality=="off" then return end
		local nearest={}
		for p in pairs(self.candidates) do
			if p.Parent then
				local distance=(p.Position-position).Magnitude
				if distance<config.LightRange then table.insert(nearest,{part=p,distance=distance}) end
			end
		end
		table.sort(nearest,function(a,b) return a.distance<b.distance end)
		for i,slot in ipairs(self.lights) do
			local candidate=i<=budget.lights and nearest[i]
			slot.light.Enabled=candidate~=nil and candidate~=false
			if candidate then
				slot.part.Position=candidate.part.Position; slot.light.Color=candidate.part.Color
				slot.light.Brightness=1.6*math.clamp((config.LightRange-candidate.distance)/20,0,1)
			end
		end
		local params=RaycastParams.new(); params.IgnoreWater=false
		params.FilterType=Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances=character and {parent,character} or {parent}
		local facing=workspace.CurrentCamera and workspace.CurrentCamera.CFrame.LookVector or Vector3.new(0,0,-1)
		local forward=Vector3.new(facing.X,0,facing.Z)
		forward=forward.Magnitude>.01 and forward.Unit or Vector3.new(0,0,-1)
		local right=Vector3.new(-forward.Z,0,forward.X)
		for i,slot in ipairs(self.glints) do
			local point=position+forward*(12+i*5)+right*((i-2)*9)
			local hit=i<=budget.glints and workspace:Raycast(Vector3.new(point.X,math.max(position.Y+8,20),point.Z),Vector3.new(0,-100,0),params)
			if hit and hit.Material==Enum.Material.Water then
				local nextPosition=hit.Position+Vector3.new(0,.1,0)
				if (slot.part.Position-nextPosition).Magnitude>2 then slot.emitter:Clear() end
				slot.part.Position=nextPosition; slot.emitter.Rate=budget.glintRate
			else slot.emitter.Rate=0; slot.emitter:Clear() end
		end
	end
	function self:snapshot()
		local lights,glints,rate=0,0,0
		for _,s in ipairs(self.lights) do if s.light.Enabled then lights+=1 end end
		for _,s in ipairs(self.glints) do if s.emitter.Rate>0 then glints+=1; rate+=s.emitter.Rate end end
		return lights,glints,rate
	end
	function self:destroy()
		self.alive=false
		for _,c in ipairs(self.connections) do c:Disconnect() end
		table.clear(self.candidates)
		for _,s in ipairs(self.lights) do s.part:Destroy() end
		for _,s in ipairs(self.glints) do s.part:Destroy() end
	end
	return self
end
return RegionalVFX
