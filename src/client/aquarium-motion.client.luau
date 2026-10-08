-- Client-side presentation only; economic fish records remain on the server.
local RunService=game:GetService("RunService")
local world=workspace:WaitForChild("FishingWorld")
local swimmers={}
local function register(object)
    if object:IsA("Model") and object:GetAttribute("SwimCenter") then swimmers[object]=true end
end
world.DescendantAdded:Connect(function(object)
    if object:IsA("Model") then task.defer(register,object) end
end)
for _,object in ipairs(world:GetDescendants()) do register(object) end
local elapsed=0
RunService.RenderStepped:Connect(function(dt)
    elapsed+=dt
    local camera=workspace.CurrentCamera
    if not camera then return end
    for model in pairs(swimmers) do
        if not model.Parent then swimmers[model]=nil continue end
        local center=model:GetAttribute("SwimCenter")
        if not center or (camera.CFrame.Position-center).Magnitude>180 then continue end
        local phase=elapsed*.38+(model:GetAttribute("SwimSeed") or 0)*1.71
        local pos=center+Vector3.new(math.sin(phase)*2,math.sin(phase*1.8)*.35,math.cos(phase)*1.7)
        local yaw=math.atan2(math.sin(phase)*1.7,math.cos(phase)*2)
        model:PivotTo(CFrame.new(pos)*CFrame.Angles(0,yaw,math.sin(phase*2)*.04))
    end
end)
