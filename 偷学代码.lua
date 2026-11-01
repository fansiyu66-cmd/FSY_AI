local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

-- 1. 创建手机专用显示面板
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdenticalDiagUI"
screenGui.ResetOnSpawn = false
if gethui then screenGui.Parent = gethui() else screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0.85, 0, 0.4, 0)
frame.Position = UDim2.new(0.5, 0, 0.3, 0)
frame.BackgroundColor3 = Color3.fromRGB(20, 16, 32)
frame.BorderSizePixel = 2
frame.BorderColor3 = Color3.fromRGB(192, 132, 252)
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local textLabel = Instance.new("TextLabel")
textLabel.Size = UDim2.new(1, -20, 1, -20)
textLabel.Position = UDim2.new(0, 10, 0, 10)
textLabel.BackgroundTransparency = 1
textLabel.TextColor3 = Color3.fromRGB(245, 242, 255)
textLabel.Font = Enum.Font.GothamBold
textLabel.TextSize = 14
textLabel.TextWrapped = true
textLabel.TextXAlignment = Enum.TextXAlignment.Left
textLabel.TextYAlignment = Enum.TextYAlignment.Top
textLabel.Text = "🔍 正在初始化...\n请稍后..."
textLabel.Parent = frame

-- 2. 抓取目标鱼的数据结构
local function GetTargetItem()
    local pData = nil
    for _, fName in ipairs({"Data", "PlayerData", "PlayersData"}) do
        local folder = ReplicatedStorage:FindFirstChild(fName)
        if folder then
            local uidStr = tostring(LocalPlayer.UserId)
            local found = folder:FindFirstChild(uidStr) or folder:FindFirstChild(LocalPlayer.Name)
            if found then pData = found; break end
        end
    end
    if not pData then return nil end
    
    local inv = pData:FindFirstChild("Inventory") or pData:FindFirstChild("Hotbar")
    if not inv then return nil end
    
    for _, item in ipairs(inv:GetChildren()) do
        if item.Name:lower():find("orca") or item.Name:lower():find("wraith") then
            return item
        end
    end
    -- 如果没找到目标鱼，随便返回一条
    return inv:GetChildren()[1]
end

local targetFish = GetTargetItem()
local fishDataStr = "未在背包找到鱼"

if targetFish then
    local attrs = {}
    for k, v in pairs(targetFish:GetAttributes()) do
        table.insert(attrs, tostring(k) .. "=" .. tostring(v))
    end
    local children = {}
    for _, c in ipairs(targetFish:GetChildren()) do
        local val = c:IsA("ValueBase") and ("=" .. tostring(c.Value)) or ""
        table.insert(children, c.Name .. val)
    end
    fishDataStr = string.format("🎯 目标鱼: %s\n[属性]: %s\n[子节点]: %s", 
        targetFish.Name, 
        (#attrs > 0 and table.concat(attrs, ", ") or "无"), 
        (#children > 0 and table.concat(children, ", ") or "无")
    )
end

textLabel.Text = "🎯 已找到目标鱼:\n" .. fishDataStr .. "\n\n👇 请立刻去游戏里手动点一下【收藏/星星】按钮！\n脚本正在全速拦截发包..."

-- 3. 暴力监听底层所有发包
local oldNamecall
local hookSuccess = pcall(function()
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method == "FireServer" and not checkcaller() then
            local name = self.Name
            local args = {...}
            local lowerName = name:lower()
            
            -- 只要名字里带 fav, lock, star 就拦截
            if lowerName:find("fav") or lowerName:find("lock") or lowerName:find("star") then
                local argsStr = ""
                for i, v in ipairs(args) do
                    if typeof(v) == "Instance" then
                        argsStr = argsStr .. "[实例:" .. v.Name .. "] "
                    else
                        argsStr = argsStr .. tostring(v) .. " "
                    end
                end
                
                local resultStr = string.format(
                    "✅ 拦截成功！\n\n事件名: %s\n参数: %s\n\n(已自动复制到剪贴板，请发给我)", 
                    name, 
                    argsStr
                )
                
                task.spawn(function()
                    textLabel.Text = resultStr
                    textLabel.TextColor3 = Color3.fromRGB(52, 211, 153) -- 绿色
                    if setclipboard then setclipboard(resultStr) end
                end)
                return -- 拦截真实请求，防止干扰
            end
        end
        return oldNamecall(self, ...)
    end)
end)

if not hookSuccess then
    textLabel.Text = "❌ 你的执行器不支持 Hook。\n请直接在群里@我。\n\n目标鱼数据:\n" .. fishDataStr
    if setclipboard then setclipboard(fishDataStr) end
end

-- 4. 点击关闭面板
frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        screenGui:Destroy()
        if restorefunction then pcall(restorefunction, game) end
    end
end)