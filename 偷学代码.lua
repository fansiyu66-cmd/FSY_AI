local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- 1. 挂载 UI 到最高层
local ui = Instance.new("ScreenGui")
ui.Name = "IdenticalDataSpy"
ui.DisplayOrder = 999999
ui.ResetOnSpawn = false
pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(ui) end
    ui.Parent = CoreGui
end)
if not ui.Parent then ui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- 2. 悬浮小圆球（点击开关）
local ball = Instance.new("TextButton")
ball.Size = UDim2.new(0, 50, 0, 50)
ball.Position = UDim2.new(0, 20, 0.3, 0)
ball.BackgroundColor3 = Color3.fromRGB(20, 16, 32)
ball.Text = "🔍\n抓包"
ball.TextColor3 = Color3.fromRGB(216, 160, 255)
ball.Font = Enum.Font.GothamBold
ball.TextSize = 12
ball.AutoButtonColor = false
ball.Parent = ui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0) 
corner.Parent = ball

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(168, 85, 247)
stroke.Thickness = 2
stroke.Parent = ball

-- 3. 数据大面板（默认隐藏）
local panel = Instance.new("Frame")
panel.Size = UDim2.new(0.85, 0, 0.55, 0)
panel.Position = UDim2.new(0.5, 0, 0.5, 0)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.BackgroundColor3 = Color3.fromRGB(13, 10, 20)
panel.BackgroundTransparency = 0.05
panel.Visible = false
panel.Parent = ui

Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)
local pStroke = Instance.new("UIStroke")
pStroke.Color = Color3.fromRGB(168, 85, 247)
pStroke.Thickness = 1.5
pStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 36)
title.BackgroundColor3 = Color3.fromRGB(18, 14, 28)
title.Text = "📡 监听面板 (点悬浮球可隐藏)"
title.TextColor3 = Color3.fromRGB(245, 242, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = panel
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

-- 4. 滑动日志框
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -10, 1, -46)
scroll.Position = UDim2.new(0, 5, 0, 40)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.ScrollBarImageColor3 = Color3.fromRGB(168, 85, 247)
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = panel

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = scroll

local logCount = 0
local function AddLog(textStr, color)
    logCount = logCount + 1
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Text = string.format("[%s] %s", os.date("%H:%M:%S"), textStr)
    lbl.TextColor3 = color or Color3.fromRGB(255, 255, 255)
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 13
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextYAlignment = Enum.TextYAlignment.Top
    lbl.LayoutOrder = logCount
    lbl.Parent = scroll
    
    -- 限制最多 60 条防止卡顿
    if #scroll:GetChildren() > 60 then
        for _, child in ipairs(scroll:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
                break
            end
        end
    end
end

-- 5. 悬浮球拖拽与点击逻辑 (手机完美适配)
local dragging = false
local dragStart = nil
local startPos = nil
local dragMovedDist = 0
local activeTouch = nil

local function UpdateDrag(input)
    local delta = input.Position - dragStart
    dragMovedDist = math.max(dragMovedDist, delta.Magnitude)
    ball.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

ball.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        activeTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
        dragStart = input.Position
        startPos = ball.Position
        dragMovedDist = 0
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging then
        if activeTouch then
            if input == activeTouch then UpdateDrag(input) end
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            UpdateDrag(input)
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if dragging then
        if (activeTouch and input == activeTouch) or (not activeTouch and input.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = false
            activeTouch = nil
            -- 如果移动距离极短，判定为“点击” -> 切换面板显隐
            if dragMovedDist < 15 then
                panel.Visible = not panel.Visible
            end
        end
    end
end)

-- 6. 发包拦截监听
pcall(function()
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if (method == "FireServer" or method == "InvokeServer") and not checkcaller() then
            local name = self.Name
            local args = {...}
            local argsStr = ""
            for _, v in ipairs(args) do
                if typeof(v) == "Instance" then argsStr = argsStr .. "[实例:" .. v.Name .. "] "
                else argsStr = argsStr .. tostring(v) .. " " end
            end
            local lowName = name:lower()
            -- 过滤掉频繁的移动、视角等无用发包，防止刷屏
            if not lowName:find("chat") and not lowName:find("input") and not lowName:find("move") and not lowName:find("camera") then
                AddLog(string.format("▶ [发包] %s | 参数: %s", name, argsStr), Color3.fromRGB(52, 211, 153))
            end
        end
        return oldNamecall(self, ...)
    end)
end)

-- 7. 数据属性监听
local pData = nil
for _, fName in ipairs({"Data", "PlayerData", "PlayersData"}) do
    local folder = ReplicatedStorage:FindFirstChild(fName)
    if folder then
        local found = folder:FindFirstChild(tostring(LocalPlayer.UserId)) or folder:FindFirstChild(LocalPlayer.Name)
        if found then pData = found; break end
    end
end

if pData then
    local function WatchItem(item)
        item.AttributeChanged:Connect(function(attr)
            AddLog(string.format("🔔 [属性] %s 变化: %s = %s", item.Name, attr, tostring(item:GetAttribute(attr))), Color3.fromRGB(251, 146, 60))
        end)
        for _, child in ipairs(item:GetChildren()) do
            if child:IsA("ValueBase") then
                child.Changed:Connect(function(newVal)
                    AddLog(string.format("🔔 [子项] %s 变化: %s = %s", item.Name, child.Name, tostring(newVal)), Color3.fromRGB(251, 146, 60))
                end)
            end
        end
        item.ChildAdded:Connect(function(child)
            if child:IsA("ValueBase") then
                AddLog(string.format("🌟 [新增] %s 出现: %s = %s", item.Name, child.Name, tostring(child.Value)), Color3.fromRGB(250, 204, 21))
                child.Changed:Connect(function(newVal)
                    AddLog(string.format("🔔 [子项] %s 变化: %s = %s", item.Name, child.Name, tostring(newVal)), Color3.fromRGB(251, 146, 60))
                end)
            end
        end)
    end

    local inv = pData:FindFirstChild("Inventory") or pData:FindFirstChild("Hotbar")
    if inv then
        for _, item in ipairs(inv:GetChildren()) do WatchItem(item) end
        inv.ChildAdded:Connect(WatchItem)
    end
else
    AddLog("❌ 找不到玩家数据节点，可能被游戏隐藏", Color3.fromRGB(248, 113, 113))
end

AddLog("✅ 监听舱已启动！请去游戏内点一下锁定", Color3.fromRGB(192, 132, 252))