-- Small cosmetic pool independent of fish meshes, bounding boxes and rewards.
local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local TweenService=game:GetService("TweenService")
local VFX={}
function VFX.new(parent, override)
	local self={slots={}, sparks={}, tweens={}, emitted=0, bursts=0, alive=true}
	local gui=Players.LocalPlayer:WaitForChild("PlayerGui")
	local settings=UserSettings():GetService("UserGameSettings")
	function self:quality()
		local requested=override or gui:GetAttribute("EnvironmentQuality")
		if requested=="off" or requested=="low" or requested=="high" then return requested end
		local saved=settings.SavedQualityLevel.Value
		return (UIS.TouchEnabled or (saved>0 and saved<=3)) and "low" or "high"
	end
	for i=1,4 do
		local p=Instance.new("Part"); p.Name="CatchBurst"..i; p.Transparency=1; p.Size=Vector3.one*.1
		p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false; p.Parent=parent
		local e=Instance.new("ParticleEmitter"); e.Name="CatchSparkle"; e.Rate=0; e.Enabled=false
		e.Texture="rbxasset://textures/particles/sparkles_main.dds"; e.LightEmission=.65; e.LightInfluence=.2
		e.Lifetime=NumberRange.new(.25,.5); e.Speed=NumberRange.new(1.4,3.2); e.SpreadAngle=Vector2.new(65,65)
		e.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,.16),NumberSequenceKeypoint.new(.3,.24),NumberSequenceKeypoint.new(1,0)})
		e.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,.15),NumberSequenceKeypoint.new(1,1)})
		e.Parent=p
		local light=Instance.new("PointLight"); light.Name="CatchGlow"; light.Enabled=false; light.Shadows=false; light.Range=7; light.Parent=p
		table.insert(self.slots,{part=p,emitter=e,light=light})
	end
	function self:clear()
		for _,t in ipairs(self.tweens) do t:Cancel() end; table.clear(self.tweens)
		for _,p in ipairs(self.sparks) do p:Destroy() end; table.clear(self.sparks)
		for _,s in ipairs(self.slots) do s.emitter:Clear(); s.light.Enabled=false end
	end
	function self:beginBatch()
		self:clear(); self.emitted=0; self.bursts=0
	end
	function self:refresh()
		if self:quality()=="off" then self:clear() end
	end
	function self:burst(index, kind, position, rare)
		local tier=self:quality()
		if not self.alive or tier=="off" or not self.slots[index] then return end
		local s=self.slots[index]
		s.part.Position=position
		local color=kind=="splash" and Color3.fromRGB(163,234,255) or (rare and Color3.fromRGB(255,215,125) or Color3.fromRGB(164,255,220))
		s.emitter.Color=ColorSequence.new(color)
		s.emitter.Acceleration=Vector3.new(0,kind=="splash" and -8 or 1,0)
		local n=kind=="splash" and (tier=="low" and 5 or 12) or (tier=="low" and 3 or 7)
		s.emitter:Emit(n); self.emitted+=n; self.bursts+=1
		if rare and kind~="splash" and tier=="high" then
			s.light.Color=color; s.light.Brightness=.65; s.light.Enabled=true
			local t=TweenService:Create(s.light,TweenInfo.new(.35),{Brightness=0}); t:Play(); table.insert(self.tweens,t)
			t.Completed:Once(function(state)
				if state==Enum.PlaybackState.Completed and self.alive and s.light.Parent then s.light.Enabled=false end
			end)
		end
	end
	function self:arrival(parentGui, center)
		local tier=self:quality(); if tier=="off" then return end
		local count=tier=="low" and 3 or 6
		for i=1,count do
			local angle=i*math.pi*2/count
			local p=Instance.new("Frame"); p.Name="BagSparkle"; p.AnchorPoint=Vector2.new(.5,.5)
			p.Position=UDim2.fromOffset(center.X,center.Y); p.Size=UDim2.fromOffset(4,4); p.Rotation=45
			p.BackgroundColor3=Color3.fromRGB(255,227,144); p.BorderSizePixel=0; p.ZIndex=9; p.Parent=parentGui
			table.insert(self.sparks,p)
			local t=TweenService:Create(p,TweenInfo.new(.42,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{
				Position=UDim2.fromOffset(center.X+math.cos(angle)*28,center.Y+math.sin(angle)*28), BackgroundTransparency=1, Size=UDim2.fromOffset(1,1)})
			t:Play(); table.insert(self.tweens,t)
			task.delay(.5,function() if p.Parent then p:Destroy() end end)
		end
	end
	function self:destroy()
		if not self.alive then return end
		self.alive=false; self:clear()
		for _,s in ipairs(self.slots) do s.part:Destroy() end
		table.clear(self.slots)
	end
	return self
end
return VFX
