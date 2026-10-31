-- ==========================================
-- Roblox 远程事件抓包监听器 (移动端适配版)
-- ==========================================

local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- 1. 安全获取 UI 容器
local function GetGuiParent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    return CoreGui
end

-- 2. 创建主界面 (小巧、可拖动)
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RemoteSpy_Lite"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() ScreenGui.Parent = GetGuiParent() end)

local MainFrame = Instance.new("Frame")
MainFrame.Name = "Main"
MainFrame.Size = UDim2.new(0, 240, 0, 200)
MainFrame.Position = UDim2.new(0, 20, 0, 100)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
MainFrame.BackgroundTransparency = 0.1
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true -- 基础拖动
MainFrame.Parent = ScreenGui

local UICorner = Instance.new("UICorner", MainFrame)
UICorner.CornerRadius = UDim.new(0, 8)

local UIStroke = Instance.new("UIStroke", MainFrame)
UIStroke.Color = Color3.fromRGB(150, 100, 255)
UIStroke.Thickness = 1.5

-- 标题栏
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 26)
Title.BackgroundColor3 = Color3.fromRGB(35, 30, 45)
Title.BackgroundTransparency = 0.2
Title.BorderSizePixel = 0
Title.Font = Enum.Font.GothamBold
Title.Text = "🔍 远程事件监听器 (拖拽我)"
Title.TextColor3 = Color3.fromRGB(216, 160, 255)
Title.TextSize = 12
Title.Parent = MainFrame
Instance.new("UICorner", Title).CornerRadius = UDim.new(0, 8)

-- 控制按钮区域
local BtnFrame = Instance.new("Frame")
BtnFrame.Size = UDim2.new(1, -10, 0, 24)
BtnFrame.Position = UDim2.new(0, 5, 0, 30)
BtnFrame.BackgroundTransparency = 1
BtnFrame.Parent = MainFrame

local StartBtn = Instance.new("TextButton")
StartBtn.Size = UDim2.new(0.5, -2, 1, 0)
StartBtn.Position = UDim2.new(0, 0, 0, 0)
StartBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 100)
StartBtn.Font = Enum.Font.GothamBold
StartBtn.Text = "开启抓包"
StartBtn.TextColor3 = Color3.new(1, 1, 1)
StartBtn.TextSize = 11
StartBtn.Parent = BtnFrame
Instance.new("UICorner", StartBtn).CornerRadius = UDim.new(0, 4)

local ClearBtn = Instance.new("TextButton")
ClearBtn.Size = UDim2.new(0.5, -2, 1, 0)
ClearBtn.Position = UDim2.new(0.5, 2, 0, 0)
ClearBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
ClearBtn.Font = Enum.Font.GothamBold
ClearBtn.Text = "清空日志"
ClearBtn.TextColor3 = Color3.new(1, 1, 1)
ClearBtn.TextSize = 11
ClearBtn.Parent = BtnFrame
Instance.new("UICorner", ClearBtn).CornerRadius = UDim.new(0, 4)

-- 日志显示区域 (ScrollingFrame 适配手机滑动)
local LogFrame = Instance.new("ScrollingFrame")
LogFrame.Size = UDim2.new(1, -10, 1, -60)
LogFrame.Position = UDim2.new(0, 5, 0, 56)
LogFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 15)
LogFrame.BorderSizePixel = 0
LogFrame.ScrollBarThickness = 4
LogFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
LogFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
LogFrame.Parent = MainFrame
Instance.new("UICorner", LogFrame).CornerRadius = UDim.new(0, 6)

local UIListLayout = Instance.new("UIListLayout")
UIListLayout.Padding = UDim.new(0, 4)
UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayout.Parent = LogFrame

local UIPadding = Instance.new("UIPadding")
UIPadding.PaddingTop = UDim.new(0, 4)
UIPadding.PaddingLeft = UDim.new(0, 4)
UIPadding.PaddingRight = UDim.new(0, 4)
UIPadding.Parent = LogFrame

-- 3. 核心抓包逻辑
local isListening = false
local logCount = 0
local MAX_LOGS = 50 -- 限制最大日志数，防止手机卡顿

local function AddLog(remoteName, method, args)
    if not isListening then return end
    
    -- 限制日志数量
    if logCount >= MAX_LOGS then
        local firstChild = LogFrame:FindFirstChildOfClass("TextLabel")
        if firstChild then firstChild:Destroy() end
    else
        logCount = logCount + 1
    end

    -- 判断是否是目标关键字
    local lowerName = remoteName:lower()
    local isTarget = lowerName:find("quest") or lowerName:find("ticket") or lowerName:find("dialog") or lowerName:find("npc") or lowerName:find("talk") or lowerName:find("interact") or lowerName:find("submit")

    local textStr = string.format("[%s] %s", method, remoteName)
    if #args > 0 then
        textStr = textStr .. " | 参数: " .. tostring(args[1])
    end

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 0)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.Text = textStr
    label.TextColor3 = isTarget and Color3.fromRGB(100, 255, 100) or Color3.fromRGB(200, 200, 200) -- 目标事件绿色高亮
    label.TextSize = 10
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextWrapped = true
    label.Parent = LogFrame
    
    -- 如果是目标事件，打印到控制台（方便复制）
    if isTarget then
        print("🎯 发现目标事件:", textStr)
    end
end

-- Hook 逻辑
local hookConnection = nil
local isHooked = false
local oldNamecall = nil

local function ToggleHook(state)
    isListening = state
    if state then
        StartBtn.Text = "停止抓包"
        StartBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
        
        -- 尝试使用 Hook 方式 (最精准)
        if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" and not isHooked then
            local ok = pcall(function()
                local mt = getrawmetatable(game)
                local old = mt.__namecall
                setreadonly(mt, false)
                mt.__namecall = newcclosure(function(self, ...)
                    local method = getnamecallmethod()
                    if not checkcaller() and (method == "FireServer" or method == "InvokeServer") then
                        if typeof(self) == "Instance" and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) then
                            local args = {...}
                            task.spawn(function()
                                pcall(AddLog, self.Name, method, args)
                            end)
                        end
                    end
                    return old(self, ...)
                end)
                setreadonly(mt, true)
                oldNamecall = old
                isHooked = true
            end)
            if not ok then
                warn("Hook 失败，请确保执行器支持 hookmetamethod")
                -- 降级为简单轮询（不太准，但能用）
                isListening = false
                StartBtn.Text = "不支持Hook"
            end
        elseif not isHooked then
            StartBtn.Text = "不支持Hook"
            StartBtn.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
        end
    else
        StartBtn.Text = "开启抓包"
        StartBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 100)
    end
end

StartBtn.MouseButton1Click:Connect(function()
    ToggleHook(not isListening)
end)

ClearBtn.MouseButton1Click:Connect(function()
    for _, child in ipairs(LogFrame:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end
    logCount = 0
end)

-- 手机拖拽优化 (Title栏拖拽)
local dragging = false
local dragInput, dragStart, startPos
Title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)
Title.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

print("✅ 监听器加载成功！请点击【开启抓包】，然后去游戏里和 NPC 对话。")