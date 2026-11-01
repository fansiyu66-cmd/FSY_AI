local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- 1. 尝试将 UI 挂载到最高层（防遮挡）
local ui = Instance.new("ScreenGui")
ui.Name = "DeepSpy_V3"
ui.DisplayOrder = 2147483647 -- 极限层级，绝对不被遮挡
ui.IgnoreGuiInset = true

local success = pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(ui) end
    ui.Parent = CoreGui
end)
if not success or not ui.Parent then
    pcall(function() ui.Parent = gethui() end)
end
if not ui.Parent then ui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- 2. 悬浮球
local ball = Instance.new("TextButton")
ball.Size = UDim2.new(0, 50, 0, 50)
ball.Position = UDim2.new(0, 20, 0.2, 0)
ball.BackgroundColor3 = Color3.fromRGB(248, 113, 113)
ball.Text = "🕵️\n深度抓包"
ball.TextColor3 = Color3.fromRGB(255, 255, 255)
ball.Font = Enum.Font.GothamBold
ball.TextSize = 12
ball.AutoButtonColor = false
ball.Parent = ui
Instance.new("UICorner", ball).CornerRadius = UDim.new(1, 0)

-- 3. 大面板
local panel = Instance.new("Frame")
panel.Size = UDim2.new(0.95, 0, 0.7, 0)
panel.Position = UDim2.new(0.5, 0, 0.5, 0)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.BackgroundColor3 = Color3.fromRGB(10, 8, 15)
panel.Visible = false
panel.Parent = ui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 40)
title.BackgroundColor3 = Color3.fromRGB(30, 20, 40)
title.Text = "🕵️ 深度监听 (点悬浮球隐藏 | 截屏此面板)"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = panel

-- 清空按钮
local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 60, 0, 26)
clearBtn.Position = UDim2.new(1, -70, 0, 7)
clearBtn.BackgroundColor3 = Color3.fromRGB(100, 50, 50)
clearBtn.Text = "清空"
clearBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.Parent = title
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -10, 1, -50)
scroll.Position = UDim2.new(0, 5, 0, 45)
scroll.BackgroundTransparency = 1
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = panel
Instance.new("UIListLayout", scroll).Padding = UDim.new(0, 4)

local logCount = 0
local function AddLog(text, color)
    print(text) -- 同步输出到执行器控制台
    
    logCount = logCount + 1
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = color or Color3.fromRGB(255, 255, 255)
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 12
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = scroll
    
    if #scroll:GetChildren() > 50 then
        for _, c in ipairs(scroll:GetChildren()) do
            if c:IsA("TextLabel") then c:Destroy(); break end
        end
    end
end

clearBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    logCount = 0
end)

-- 4. 拖拽与点击逻辑
local dragging, dragStart, startPos, dragMoved = false, nil, nil, 0
local activeTouch = nil

local function UpdateDrag(input)
    local delta = input.Position - dragStart
    dragMoved = math.max(dragMoved, delta.Magnitude)
    ball.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

ball.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; activeTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
        dragStart = input.Position; startPos = ball.Position; dragMoved = 0
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and ((activeTouch and input == activeTouch) or (not activeTouch and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        UpdateDrag(input)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if dragging and ((activeTouch and input == activeTouch) or (not activeTouch and input.UserInputType == Enum.UserInputType.MouseButton1)) then
        dragging = false; activeTouch = nil
        if dragMoved < 15 then panel.Visible = not panel.Visible end
    end
end)

-- 5. 核心 1：抓取所有发包 (不管名字叫啥，不管过滤条件)
pcall(function()
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if not checkcaller() and (method == "FireServer" or method == "InvokeServer") then
            local args = {...}
            local argsStr = ""
            for i = 1, #args do
                local v = args[i]
                if typeof(v) == "Instance" then argsStr = argsStr .. "[实例:" .. v.Name .. "] "
                elseif type(v) == "table" then argsStr = argsStr .. "[表] "
                else argsStr = argsStr .. tostring(v) .. " " end
            end
            -- 为了不刷屏，如果参数太长就截断
            if #argsStr > 60 then argsStr = string.sub(argsStr, 1, 60) .. "..." end
            
            task.spawn(function()
                AddLog(string.format("▶ [发包] %s\n参数: %s", self.Name, argsStr), Color3.fromRGB(52, 211, 153))
            end)
        end
        return oldNamecall(self, ...)
    end)
    AddLog("✅ 发包监听已开启", Color3.fromRGB(52, 211, 153))
end)

-- 6. 核心 2：抓取你点击的 UI 按钮
local oldIndex
pcall(function()
    oldIndex = hookmetamethod(game, "__index", function(t, k)
        if not checkcaller() and k == "Activated" and typeof(t) == "Instance" and t:IsA("GuiButton") then
            task.spawn(function()
                AddLog(string.format("🖱️ [点击按钮] %s (父级: %s)", t.Name, t.Parent and t.Parent.Name or "未知"), Color3.fromRGB(96, 165, 250))
            end)
        end
        return oldIndex(t, k)
    end)
    AddLog("✅ UI点击监听已开启", Color3.fromRGB(96, 165, 250))
end)

-- 7. 核心 3：抓取背包数据属性变化
local pData = nil
for _, fName in ipairs({"Data", "PlayerData", "PlayersData"}) do
    local folder = ReplicatedStorage:FindFirstChild(fName)
    if folder then
        local found = folder:FindFirstChild(tostring(LocalPlayer.UserId)) or folder:FindFirstChild(LocalPlayer.Name)
        if found then pData = found; break end
    end
end

if pData then
    local inv = pData:FindFirstChild("Inventory") or pData:FindFirstChild("Hotbar")
    if inv then
        local function WatchItem(item)
            item.AttributeChanged:Connect(function(attr)
                task.spawn(function()
                    AddLog(string.format("🔔 [数据变] %s 属性: %s = %s", item.Name, attr, tostring(item:GetAttribute(attr))), Color3.fromRGB(251, 146, 60))
                end)
            end)
            for _, c in ipairs(item:GetChildren()) do
                if c:IsA("ValueBase") then
                    c.Changed:Connect(function(newVal)
                        task.spawn(function()
                            AddLog(string.format("🔔 [数据变] %s 子项: %s = %s", item.Name, c.Name, tostring(newVal)), Color3.fromRGB(251, 146, 60))
                        end)
                    end)
                end
            end
        end
        for _, item in ipairs(inv:GetChildren()) do WatchItem(item) end
        inv.ChildAdded:Connect(WatchItem)
        AddLog("✅ 数据变化监听已开启", Color3.fromRGB(251, 146, 60))
    end
else
    AddLog("❌ 找不到数据节点", Color3.fromRGB(248, 113, 113))
end

AddLog("👇 请去点【锁定】按钮", Color3.fromRGB(255, 255, 255))