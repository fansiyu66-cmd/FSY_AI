-- [[ 重型钓鱼 (Heavyweight Fishing) 手机&电脑自适应精简版 ]]
-- 保留核心功能：自动钓鱼、小游戏完美收线、自动卖鱼(含0-60分钟定时卖鱼&传送往返)/防爆背包、防挂机与断线重连、全地图与NPC传送、配置管理
-- 手机端特别优化：
--   1. 大幅缩小窗口尺寸 + 自动适配手机屏幕分辨率，不再遮挡游戏画面
--   2. 全面支持手机触屏拖动窗口、拖动悬浮球、滑动滑块 (支持 Touch 触控事件)
--   3. 悬浮球常驻屏幕左上角，手机点击一下即可随时收起/展开菜单
--   4. 设置页新增【界面缩放比例 (50%~120%)】滑块，可自由调节窗口大小

if not game:IsLoaded() then game.Loaded:Wait() end

if getgenv and getgenv().IdenticalHeavyweightFishingUnload then
    pcall(getgenv().IdenticalHeavyweightFishingUnload)
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local isRunning = true
local activeConnections = {}
local cleanUpInstances = {}

local Events = ReplicatedStorage:WaitForChild("Events", 10)

-- 判断是否为手机/触屏设备
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- 配置项
local Config = {
    -- 核心钓鱼
    AutoCast = false, -- 自动抛竿
    CastDelay = 1.0, -- 抛竿延迟
    CastPower = 100, -- 抛竿力度
    AnchorBar = true, -- 锚定条/小游戏锁定
    AutoSlam = true, -- 自动猛击
    AutoCharge = true, -- 自动充能
    AutoSkills = false, -- 自动技能
    
    -- 自动装备
    AutoEquipBestBait = false, -- 自动装备最佳鱼饵
    AutoEquipBestRod = false, -- 自动装备最佳鱼竿
    AutoEquipBestOrb = false, -- 自动装备最佳宝珠
    Loadout1_Rod = "Wooden Rod", -- 方案1鱼竿
    Loadout1_Bait = "Basic Bait", -- 方案1鱼饵
    Loadout2_Rod = "Wooden Rod", -- 方案2鱼竿
    Loadout2_Bait = "Basic Bait", -- 方案2鱼饵
    
    -- 卖鱼与经济 (原有基础 + 0~60分钟定时优化)
    AutoSell = false, -- 原有自动卖鱼(按秒/满包触发)
    SellInterval = 30, -- 原有卖鱼间隔(秒)
    TimedSellEnabled = false, -- 开启分钟级定时自动卖鱼
    TimedSellMinutes = 30, -- 定时卖鱼间隔(0~60分钟，默认30分钟)
    SellTpAndReturn = true, -- 定时卖鱼时自动传送到娜娜处卖鱼并返回原钓鱼位置
    AutoFavouriteFish = false, -- 自动收藏保护选中的鱼
    FavouriteFishName = "Colossal Tigerfish", -- 收藏保护目标
    MaterialFarming = false, -- 材料收集模式(自动保护制作材料鱼)
    
    -- 防挂机与稳定性
    AntiAFK = true, -- 防挂机(防止20分钟未操作断开)
    AutoRejoin = false, -- 被踢/断线自动重连
    
    -- 界面与配置
    UIScalePercent = isMobile and 80 or 95, -- UI缩放百分比(手机默认80%更小巧)
    UIKeybind = Enum.KeyCode.RightControl, -- 界面快捷键
    StopKeybind = Enum.KeyCode.End, -- 卸载快捷键
    ActiveProfile = "default", -- 配置文件名
    AutoLoadProfile = true -- 自动加载配置
}

-- 小游戏网络钩子(防止脱钩)
if hookmetamethod and newcclosure then
    local fmRemote = Events and Events:FindFirstChild("FishingMinigame")
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if (self == fmRemote or (typeof(self) == "Instance" and self.Name == "FishingMinigame")) and method == "FireServer" and not checkcaller() then
            if isRunning and Config and Config.AnchorBar then
                local args = {...}
                local action = tostring(args[1])
                if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar") then
                    return oldNamecall(self, "In bar", unpack(args, 2))
                end
            end
        end
        return oldNamecall(self, ...)
    end))
end

-- 配置文件读写
local PROFILE_DIR = "Identical/HeavyweightFishing"

local function EnsureProfileDir()
    if makefolder then
        pcall(function()
            if not isfolder("Identical") then makefolder("Identical") end
            if not isfolder(PROFILE_DIR) then makefolder(PROFILE_DIR) end
        end)
    end
end

local function SaveProfile(name)
    EnsureProfileDir()
    local path = PROFILE_DIR .. "/" .. (name or Config.ActiveProfile) .. ".json"
    local data = {}
    for k, v in pairs(Config) do
        if typeof(v) == "EnumItem" then
            data[k] = {__enum = tostring(v)}
        else
            data[k] = v
        end
    end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if ok and writefile then
        pcall(function() writefile(path, encoded) end)
        return true
    end
    return false
end

local function LoadProfile(name)
    local path = PROFILE_DIR .. "/" .. (name or Config.ActiveProfile) .. ".json"
    if readfile then
        local ok, content = pcall(function() return readfile(path) end)
        if ok and content and #content > 0 then
            local decOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
            if decOk and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    if type(v) == "table" and v.__enum then
                        local enumType, enumName = v.__enum:match("Enum%.(%w+)%.(%w+)")
                        if enumType and enumName and Enum[enumType] and Enum[enumType][enumName] then
                            Config[k] = Enum[enumType][enumName]
                        end
                    elseif Config[k] ~= nil then
                        Config[k] = v
                    end
                end
                return true
            end
        end
    end
    return false
end

if Config.AutoLoadProfile then pcall(LoadProfile, "default") end

-- 调色板
local Colors = {
    Background       = Color3.fromRGB(15, 12, 22),
    SidebarBg        = Color3.fromRGB(11, 9, 17),
    BorderPurple     = Color3.fromRGB(168, 85, 247),
    BorderSubtle     = Color3.fromRGB(45, 33, 66),
    Divider          = Color3.fromRGB(36, 26, 54),

    PurplePrimary    = Color3.fromRGB(216, 160, 255),
    PurpleAccent     = Color3.fromRGB(168, 85, 247),
    PurpleMuted      = Color3.fromRGB(147, 112, 196),
    PurpleDark       = Color3.fromRGB(72, 45, 107),
    PurpleGlow       = Color3.fromRGB(192, 132, 252),

    RowNormal        = Color3.fromRGB(20, 16, 30),
    RowHover         = Color3.fromRGB(30, 22, 46),
    ControlBg        = Color3.fromRGB(28, 20, 44),
    InputBg          = Color3.fromRGB(18, 14, 26),

    TextWhite        = Color3.fromRGB(245, 243, 255),
    TextSubtle       = Color3.fromRGB(168, 150, 200),
    TextMuted        = Color3.fromRGB(110, 95, 138),

    AccentGreen      = Color3.fromRGB(52, 211, 153),
    AccentRed        = Color3.fromRGB(248, 113, 113),
    AccentYellow     = Color3.fromRGB(250, 204, 21),
    DropdownSelected = Color3.fromRGB(36, 26, 56)
}

-- GUI容器选择
local function getGuiParent()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, gui = pcall(function() return CoreGui end)
    if ok and gui then return gui end
    return LocalPlayer:WaitForChild("PlayerGui", 5) or LocalPlayer:FindFirstChild("PlayerGui")
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdenticalHeavyweightFishing_Lite"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = getGuiParent()
table.insert(cleanUpInstances, screenGui)

-- 脚本卸载函数
local function UnloadScript()
    isRunning = false
    for _, conn in ipairs(activeConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(activeConnections)
    
    for _, inst in ipairs(cleanUpInstances) do
        pcall(function()
            if inst and inst.Parent then inst:Destroy() end
        end)
    end
    table.clear(cleanUpInstances)
    
    if getgenv then getgenv().IdenticalHeavyweightFishingUnload = nil end
end

if getgenv then getgenv().IdenticalHeavyweightFishingUnload = UnloadScript end

-- 通知系统 (针对手机缩小尺寸，避免挡住右侧操作)
local notifContainer = Instance.new("Frame")
notifContainer.Name = "Notifications"
notifContainer.Size = UDim2.new(0, 220, 1, -30)
notifContainer.Position = UDim2.new(1, -230, 0, 15)
notifContainer.BackgroundTransparency = 1
notifContainer.ZIndex = 1000
notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)

local notifLayout = Instance.new("UIListLayout")
notifLayout.SortOrder = Enum.SortOrder.LayoutOrder
notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
notifLayout.Padding = UDim.new(0, 6)
notifLayout.Parent = notifContainer

local function ShowNotification(title, text, notifType, duration)
    if not isRunning then return end
    duration = duration or 2.8
    local accentColor = Colors.PurpleAccent
    if notifType == "SUCCESS" then accentColor = Colors.AccentGreen
    elseif notifType == "WARN" then accentColor = Colors.AccentYellow
    elseif notifType == "ERROR" then accentColor = Colors.AccentRed end

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, 48)
    card.BackgroundColor3 = Colors.Background
    card.BackgroundTransparency = 0.08
    card.BorderSizePixel = 0
    card.ClipsDescendants = true
    card.Parent = notifContainer

    local stroke = Instance.new("UIStroke"); stroke.Color = accentColor; stroke.Thickness = 1; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = card
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 16); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 8, 0, 4); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -16, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = title; tLabel.TextColor3 = Colors.PurplePrimary; tLabel.TextSize = 11; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -16, 0, 22); mLabel.Position = UDim2.new(0, 8, 0, 20); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = text; mLabel.TextColor3 = Colors.TextSubtle; tLabel.TextSize = 11; mLabel.TextSize = 10; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.Parent = card

    task.delay(duration, function()
        if card and card.Parent then
            TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = 1, Position = card.Position + UDim2.new(1, 20, 0, 0)
            }):Play()
            task.wait(0.3); card:Destroy()
        end
    end)
end

-- 通用触控/鼠标拖拽绑定函数 (兼容手机Touch与电脑鼠标)
local function MakeDraggable(triggerGui, targetGui)
    local dragging = false
    local dragInput = nil
    local dragStart = nil
    local startPos = nil
    local moved = false

    triggerGui.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = targetGui.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    triggerGui.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            if delta.Magnitude > 4 then moved = true end
            targetGui.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))

    return function() return moved end
end

-- 常驻悬浮球 (手机端随时点击隐藏/显示菜单，支持手指拖动位置)
local ToggleUiVisibility
local floatingCrescent = Instance.new("TextButton")
floatingCrescent.Name = "FloatingCrescent"
floatingCrescent.Size = UDim2.new(0, 42, 0, 42)
floatingCrescent.Position = UDim2.new(0, 16, 0, 60)
floatingCrescent.BackgroundColor3 = Colors.Background
floatingCrescent.BackgroundTransparency = 0.1
floatingCrescent.BorderSizePixel = 0
floatingCrescent.Text = "钓"
floatingCrescent.Font = Enum.Font.GothamBold
floatingCrescent.TextColor3 = Colors.PurplePrimary
floatingCrescent.TextSize = 15
floatingCrescent.Visible = true -- 常驻显示，方便手机一键收起/打开
floatingCrescent.ZIndex = 1000
floatingCrescent.Parent = screenGui
table.insert(cleanUpInstances, floatingCrescent)

do
    local fcCorner = Instance.new("UICorner"); fcCorner.CornerRadius = UDim.new(1, 0); fcCorner.Parent = floatingCrescent
    local fcStroke = Instance.new("UIStroke"); fcStroke.Color = Colors.PurpleAccent; fcStroke.Thickness = 1.8; fcStroke.Parent = floatingCrescent
    local wasDragged = MakeDraggable(floatingCrescent, floatingCrescent)
    floatingCrescent.Activated:Connect(function()
        if not wasDragged() and ToggleUiVisibility then
            ToggleUiVisibility()
        end
    end)
end

-- 主窗口 (紧凑尺寸 460x290，专门适配手机横屏，不再占满屏幕)
local BASE_WIDTH = 460
local BASE_HEIGHT = 290

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, BASE_WIDTH, 0, BASE_HEIGHT)
mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
mainFrame.BackgroundColor3 = Colors.Background
mainFrame.BackgroundTransparency = 0.04
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui
table.insert(cleanUpInstances, mainFrame)

-- UI整体缩放器 (自动根据手机屏幕高度适配 + 支持手动调整)
local uiScale = Instance.new("UIScale")
uiScale.Parent = mainFrame

local function ApplyUIScale()
    local vp = Camera and Camera.ViewportSize or Vector2.new(800, 450)
    local userScale = (Config.UIScalePercent or 85) / 100
    -- 确保窗口高度不超过屏幕高度的 78%，宽度不超过屏幕宽度的 75%
    local maxScaleH = (vp.Y * 0.78) / BASE_HEIGHT
    local maxScaleW = (vp.X * 0.75) / BASE_WIDTH
    local autoMax = math.min(maxScaleH, maxScaleW, 1.2)
    uiScale.Scale = math.clamp(userScale, 0.5, math.max(0.65, autoMax))
end
ApplyUIScale()
if Camera then
    table.insert(activeConnections, Camera:GetPropertyChangedSignal("ViewportSize"):Connect(ApplyUIScale))
end

do
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame
    local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame
end

-- 标题栏 (高度压缩为 32px)
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Colors.SidebarBg
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

do
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 8); tc.Parent = titleBar
    local tbf = Instance.new("Frame"); tbf.Size = UDim2.new(1, 0, 0, 8); tbf.Position = UDim2.new(0, 0, 1, -8); tbf.BackgroundColor3 = Colors.SidebarBg; tbf.BorderSizePixel = 0; tbf.Parent = titleBar
    local tdiv = Instance.new("Frame"); tdiv.Size = UDim2.new(1, 0, 0, 1); tdiv.Position = UDim2.new(0, 0, 1, -1); tdiv.BackgroundColor3 = Colors.Divider; tdiv.BorderSizePixel = 0; tdiv.Parent = titleBar
end

local brandTitle = Instance.new("TextLabel")
brandTitle.Size = UDim2.new(0, 80, 1, 0); brandTitle.Position = UDim2.new(0, 12, 0, 0)
brandTitle.BackgroundTransparency = 1; brandTitle.Font = Enum.Font.GothamBold
brandTitle.Text = "重型钓鱼"; brandTitle.TextColor3 = Colors.PurplePrimary
brandTitle.TextSize = 13; brandTitle.TextXAlignment = Enum.TextXAlignment.Left
brandTitle.Parent = titleBar

local gameSubtitle = Instance.new("TextLabel")
gameSubtitle.Size = UDim2.new(0, 220, 1, 0); gameSubtitle.Position = UDim2.new(0, 78, 0, 0)
gameSubtitle.BackgroundTransparency = 1; gameSubtitle.Font = Enum.Font.Gotham
gameSubtitle.Text = "手机自适应版 (点左侧[钓]球可收起)"; gameSubtitle.TextColor3 = Colors.PurpleMuted
gameSubtitle.TextSize = 10; gameSubtitle.TextXAlignment = Enum.TextXAlignment.Left
gameSubtitle.Parent = titleBar

local winControls = Instance.new("Frame"); winControls.Size = UDim2.new(0, 62, 1, 0); winControls.Position = UDim2.new(1, -66, 0, 0); winControls.BackgroundTransparency = 1; winControls.Parent = titleBar
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 26, 0, 22); minBtn.Position = UDim2.new(0, 2, 0.5, -11); minBtn.BackgroundColor3 = Colors.ControlBg; minBtn.Font = Enum.Font.GothamBold; minBtn.Text = "收起"; minBtn.TextColor3 = Colors.PurplePrimary; minBtn.TextSize = 10; minBtn.BorderSizePixel = 0; minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 4)
local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 26, 0, 22); closeBtn.Position = UDim2.new(0, 32, 0.5, -11); closeBtn.BackgroundColor3 = Colors.ControlBg; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Text = "×"; closeBtn.TextColor3 = Colors.AccentRed; closeBtn.TextSize = 14; closeBtn.BorderSizePixel = 0; closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

-- 标题栏拖动 (支持手机触控拖动窗口)
MakeDraggable(titleBar, mainFrame)

local bodyFrame = Instance.new("Frame"); bodyFrame.Name = "Body"; bodyFrame.Size = UDim2.new(1, 0, 1, -52); bodyFrame.Position = UDim2.new(0, 0, 0, 32); bodyFrame.BackgroundTransparency = 1; bodyFrame.Parent = mainFrame

-- 紧凑侧边栏 (宽度 92px)
local sidebar = Instance.new("Frame"); sidebar.Name = "Sidebar"; sidebar.Size = UDim2.new(0, 92, 1, 0); sidebar.BackgroundColor3 = Colors.SidebarBg; sidebar.BorderSizePixel = 0; sidebar.Parent = bodyFrame
do local d = Instance.new("Frame"); d.Size = UDim2.new(0, 1, 1, 0); d.Position = UDim2.new(1, -1, 0, 0); d.BackgroundColor3 = Colors.Divider; d.BorderSizePixel = 0; d.Parent = sidebar end

local searchBox = Instance.new("TextBox")
searchBox.Name = "SearchBar"; searchBox.Size = UDim2.new(1, -12, 0, 22); searchBox.Position = UDim2.new(0, 6, 0, 6)
searchBox.BackgroundColor3 = Colors.InputBg; searchBox.Font = Enum.Font.Gotham; searchBox.PlaceholderText = "搜索..."
searchBox.PlaceholderColor3 = Colors.TextMuted; searchBox.Text = ""; searchBox.TextColor3 = Colors.TextWhite
searchBox.TextSize = 10; searchBox.TextXAlignment = Enum.TextXAlignment.Left; searchBox.BorderSizePixel = 0; searchBox.ClearTextOnFocus = false; searchBox.Parent = sidebar
do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 6); p.Parent = searchBox end
Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0, 4)

local rowSearchIndex = {}
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = searchBox.Text:lower()
    for _, item in ipairs(rowSearchIndex) do
        if q == "" or item.query:find(q, 1, true) then
            item.frame.Visible = true
        else
            item.frame.Visible = false
        end
    end
end)

local navList = Instance.new("ScrollingFrame"); navList.Name = "NavList"; navList.Size = UDim2.new(1, 0, 1, -34); navList.Position = UDim2.new(0, 0, 0, 32); navList.BackgroundTransparency = 1; navList.BorderSizePixel = 0; navList.ScrollBarThickness = 2; navList.ScrollBarImageColor3 = Colors.BorderSubtle; navList.CanvasSize = UDim2.new(0, 0, 0, 0); navList.AutomaticCanvasSize = Enum.AutomaticSize.Y; navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout"); nl.SortOrder = Enum.SortOrder.LayoutOrder; nl.Padding = UDim.new(0, 4); nl.Parent = navList
    local np = Instance.new("UIPadding"); np.PaddingTop = UDim.new(0, 4); np.PaddingLeft = UDim.new(0, 6); np.PaddingRight = UDim.new(0, 6); np.Parent = navList
end

local contentArea = Instance.new("Frame"); contentArea.Name = "ContentArea"; contentArea.Size = UDim2.new(1, -92, 1, 0); contentArea.Position = UDim2.new(0, 92, 0, 0); contentArea.BackgroundTransparency = 1; contentArea.Parent = bodyFrame

local tabFrames = {}
local tabButtons = {}

local function SwitchTab(tabName)
    for name, frame in pairs(tabFrames) do frame.Visible = (name == tabName) end
    for name, btn in pairs(tabButtons) do
        if name == tabName then
            TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite}):Play()
            local pill = btn:FindFirstChild("ActivePill"); if pill then pill.Visible = true end
        else
            TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.SidebarBg, TextColor3 = Colors.TextSubtle}):Play()
            local pill = btn:FindFirstChild("ActivePill"); if pill then pill.Visible = false end
        end
    end
end

local function CreateTab(name)
    local btn = Instance.new("TextButton"); btn.Name = "TabBtn_" .. name; btn.Size = UDim2.new(1, 0, 0, 28); btn.BackgroundColor3 = Colors.SidebarBg; btn.Font = Enum.Font.GothamBold; btn.Text = name; btn.TextColor3 = Colors.TextSubtle; btn.TextSize = 11; btn.TextXAlignment = Enum.TextXAlignment.Left; btn.BorderSizePixel = 0; btn.Parent = navList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 10); p.Parent = btn end
    local pill = Instance.new("Frame"); pill.Name = "ActivePill"; pill.Size = UDim2.new(0, 3, 0, 14); pill.Position = UDim2.new(0, -7, 0.5, -7); pill.BackgroundColor3 = Colors.PurpleAccent; pill.BorderSizePixel = 0; pill.Visible = false; pill.Parent = btn
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 2)
    btn.Activated:Connect(function() SwitchTab(name) end)

    local page = Instance.new("ScrollingFrame"); page.Name = "TabPage_" .. name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1; page.BorderSizePixel = 0; page.ScrollBarThickness = 4; page.ScrollBarImageColor3 = Colors.BorderPurple; page.CanvasSize = UDim2.new(0, 0, 0, 0); page.AutomaticCanvasSize = Enum.AutomaticSize.Y; page.Visible = false; page.Parent = contentArea
    do
        local pl = Instance.new("UIListLayout"); pl.SortOrder = Enum.SortOrder.LayoutOrder; pl.Padding = UDim.new(0, 6); pl.Parent = page
        local pp = Instance.new("UIPadding"); pp.PaddingTop = UDim.new(0, 8); pp.PaddingBottom = UDim.new(0, 12); pp.PaddingLeft = UDim.new(0, 10); pp.PaddingRight = UDim.new(0, 10); pp.Parent = page
    end
    tabFrames[name] = page; tabButtons[name] = btn
    return page
end

-- 底部栏 (20px)
local footerBar = Instance.new("Frame"); footerBar.Name = "FooterBar"; footerBar.Size = UDim2.new(1, 0, 0, 20); footerBar.Position = UDim2.new(0, 0, 1, -20); footerBar.BackgroundColor3 = Colors.SidebarBg; footerBar.BorderSizePixel = 0; footerBar.Parent = mainFrame
Instance.new("UICorner", footerBar).CornerRadius = UDim.new(0, 8)
do
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, 0, 0, 8); tf.BackgroundColor3 = Colors.SidebarBg; tf.BorderSizePixel = 0; tf.Parent = footerBar
    local fd = Instance.new("Frame"); fd.Size = UDim2.new(1, 0, 0, 1); fd.BackgroundColor3 = Colors.Divider; fd.BorderSizePixel = 0; fd.Parent = footerBar
end
local footerBrand = Instance.new("TextLabel"); footerBrand.Size = UDim2.new(0.5, -10, 1, 0); footerBrand.Position = UDim2.new(0, 10, 0, 0); footerBrand.BackgroundTransparency = 1; footerBrand.Font = Enum.Font.Gotham; footerBrand.Text = "Heavyweight Fishing | 手机精简版"; footerBrand.TextColor3 = Colors.TextMuted; footerBrand.TextSize = 9; footerBrand.TextXAlignment = Enum.TextXAlignment.Left; footerBrand.Parent = footerBar
local footerKey = Instance.new("TextLabel"); footerKey.Size = UDim2.new(0.5, -10, 1, 0); footerKey.Position = UDim2.new(0.5, 0, 0, 0); footerKey.BackgroundTransparency = 1; footerKey.Font = Enum.Font.Gotham; footerKey.Text = "点左上角[钓]球随时隐藏界面"; footerKey.TextColor3 = Colors.TextMuted; footerKey.TextSize = 9; footerKey.TextXAlignment = Enum.TextXAlignment.Right; footerKey.Parent = footerBar

ToggleUiVisibility = function()
    mainFrame.Visible = not mainFrame.Visible
    floatingCrescent.Text = mainFrame.Visible and "收" or "钓"
    floatingCrescent.BackgroundColor3 = mainFrame.Visible and Colors.PurpleDark or Colors.Background
end

minBtn.Activated:Connect(ToggleUiVisibility)
closeBtn.Activated:Connect(UnloadScript)

-- UI 构建辅助函数 (紧凑行高 36px，适配小屏)
local function createCategoryHeader(parent, text)
    local hdr = Instance.new("Frame"); hdr.Size = UDim2.new(1, 0, 0, 18); hdr.BackgroundTransparency = 1; hdr.Parent = parent
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, 0, 1, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamBold; lbl.Text = string.upper(text); lbl.TextColor3 = Colors.PurplePrimary; lbl.TextSize = 10; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hdr
    return hdr
end

local function createCardGroup(parent)
    local group = Instance.new("Frame"); group.Size = UDim2.new(1, 0, 0, 0); group.AutomaticSize = Enum.AutomaticSize.Y; group.BackgroundColor3 = Colors.RowNormal; group.BorderSizePixel = 0; group.Parent = parent
    local s = Instance.new("UIStroke"); s.Color = Colors.BorderSubtle; s.Thickness = 1; s.Parent = group
    Instance.new("UICorner", group).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 0); l.Parent = group
    return group
end

local function createBaseRow(parent, labelText, descText, rightReserve, indexSearch)
    rightReserve = rightReserve or 130
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 36); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.Parent = parent
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -rightReserve, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = row
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 16); tl.Position = UDim2.new(0, 0, 0, 3); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 11; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.TextTruncate = Enum.TextTruncate.AtEnd; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 13); dl.Position = UDim2.new(0, 0, 0, 19); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 9; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.TextTruncate = Enum.TextTruncate.AtEnd; dl.Parent = tf
    if indexSearch ~= false then
        table.insert(rowSearchIndex, {frame = row, query = (labelText .. " " .. (descText or "")):lower()})
    end
    return row
end

local function createToggleRow(parent, labelText, descText, initialVal, callback, indexSearch)
    if type(initialVal) == "function" then
        indexSearch = callback
        callback = initialVal
        initialVal = false
    end
    local row = createBaseRow(parent, labelText, descText, 50, indexSearch)
    local state = initialVal or false
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 38, 0, 20); btn.Position = UDim2.new(1, -38, 0.5, -10); btn.BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg; btn.Text = ""; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame"); knob.Size = UDim2.new(0, 14, 0, 14); knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7); knob.BackgroundColor3 = Colors.TextWhite; knob.BorderSizePixel = 0; knob.Parent = btn
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local function updateVisuals()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg}):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), {Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)}):Play()
    end
    btn.Activated:Connect(function()
        state = not state
        updateVisuals()
        if type(callback) == "function" then callback(state) end
    end)
    return {frame = row, Set = function(val) state = val; updateVisuals() end, Get = function() return state end}
end

-- 滑块组件 (全面支持手机手指触摸滑动 Touch 与鼠标拖动)
local function createSliderRow(parent, labelText, descText, minVal, maxVal, initialVal, isFloat, suffix, callback, indexSearch)
    local row = createBaseRow(parent, labelText, descText, 140, indexSearch)
    local currentVal = initialVal or minVal; suffix = suffix or ""
    local container = Instance.new("Frame"); container.Size = UDim2.new(0, 132, 0, 26); container.Position = UDim2.new(1, -132, 0.5, -13); container.BackgroundTransparency = 1; container.Parent = row
    local valLabel = Instance.new("TextLabel"); valLabel.Size = UDim2.new(0, 52, 1, 0); valLabel.Position = UDim2.new(1, -52, 0, 0); valLabel.BackgroundTransparency = 1; valLabel.Font = Enum.Font.GothamBold; valLabel.TextColor3 = Colors.PurplePrimary; valLabel.TextSize = 10; valLabel.TextXAlignment = Enum.TextXAlignment.Right; valLabel.Parent = container
    valLabel.Text = isFloat and string.format("%.1f", currentVal)..suffix or tostring(math.floor(currentVal))..suffix

    -- 扩大触控区域方便手指滑动
    local touchHitbox = Instance.new("TextButton"); touchHitbox.Size = UDim2.new(1, -56, 1, 0); touchHitbox.Position = UDim2.new(0, 0, 0, 0); touchHitbox.BackgroundTransparency = 1; touchHitbox.Text = ""; touchHitbox.Parent = container
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, 0, 0, 6); track.Position = UDim2.new(0, 0, 0.5, -3); track.BackgroundColor3 = Colors.ControlBg; track.BorderSizePixel = 0; track.Parent = touchHitbox
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local pct = math.clamp((currentVal - minVal) / (maxVal - minVal), 0, 1)
    local fill = Instance.new("Frame"); fill.Size = UDim2.new(pct, 0, 1, 0); fill.BackgroundColor3 = Colors.PurpleAccent; fill.BorderSizePixel = 0; fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local sliding = false
    local function updateFromX(x)
        local absX = track.AbsolutePosition.X
        local absW = math.max(1, track.AbsoluteSize.X)
        local rel = math.clamp((x - absX) / absW, 0, 1)
        local val = minVal + (maxVal - minVal) * rel
        if not isFloat then val = math.floor(val + 0.5) end
        currentVal = val; fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.1f", val)..suffix or tostring(val)..suffix
        if type(callback) == "function" then callback(val) end
    end

    touchHitbox.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            updateFromX(input.Position.X)
        end
    end)
    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end))
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromX(input.Position.X)
        end
    end))

    return {
        frame = row,
        Set = function(val)
            currentVal = math.clamp(val, minVal, maxVal)
            local p2 = (currentVal - minVal) / (maxVal - minVal)
            fill.Size = UDim2.new(p2, 0, 1, 0)
            valLabel.Text = isFloat and string.format("%.1f", currentVal)..suffix or tostring(math.floor(currentVal))..suffix
        end
    }
end

local function createDropdownRow(parent, labelText, descText, options, initialVal, callback, indexSearch)
    if type(options) == "table" and type(initialVal) == "function" then
        indexSearch = callback
        callback = initialVal
        initialVal = options[1]
    end
    local selected = initialVal or options[1]
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 36); row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = true; row.Parent = parent
    local rl = Instance.new("UIListLayout"); rl.SortOrder = Enum.SortOrder.LayoutOrder; rl.Padding = UDim.new(0, 2); rl.Parent = row
    local header = Instance.new("Frame"); header.Size = UDim2.new(1, 0, 0, 36); header.BackgroundTransparency = 1; header.Parent = row
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8); pad.Parent = header
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -118, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = header
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 16); tl.Position = UDim2.new(0, 0, 0, 3); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 11; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 13); dl.Position = UDim2.new(0, 0, 0, 19); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 9; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.Parent = tf
    local ddBtn = Instance.new("TextButton"); ddBtn.Size = UDim2.new(0, 110, 0, 22); ddBtn.Position = UDim2.new(1, -110, 0.5, -11); ddBtn.BackgroundColor3 = Colors.ControlBg; ddBtn.Font = Enum.Font.GothamBold; ddBtn.Text = tostring(selected) .. " v"; ddBtn.TextColor3 = Colors.PurplePrimary; ddBtn.TextSize = 10; ddBtn.TextTruncate = Enum.TextTruncate.AtEnd; ddBtn.BorderSizePixel = 0; ddBtn.Parent = header
    Instance.new("UICorner", ddBtn).CornerRadius = UDim.new(0, 4)
    local optC = Instance.new("Frame"); optC.Size = UDim2.new(1, 0, 0, 0); optC.AutomaticSize = Enum.AutomaticSize.Y; optC.BackgroundTransparency = 1; optC.Visible = false; optC.Parent = row
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.PaddingRight = UDim.new(0, 8); p.PaddingBottom = UDim.new(0, 6); p.Parent = optC end
    Instance.new("UIListLayout", optC).SortOrder = Enum.SortOrder.LayoutOrder
    local optButtons = {}
    local function populate(opts)
        for _, c in ipairs(optC:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
        table.clear(optButtons)
        for _, opt in ipairs(opts) do
            local ob = Instance.new("TextButton"); ob.Size = UDim2.new(1, 0, 0, 24); ob.BackgroundColor3 = (opt == selected) and Colors.DropdownSelected or Colors.InputBg; ob.Font = Enum.Font.Gotham; ob.Text = (opt == selected and "> " or "   ") .. tostring(opt); ob.TextColor3 = (opt == selected) and Colors.PurplePrimary or Colors.TextWhite; ob.TextSize = 10; ob.TextXAlignment = Enum.TextXAlignment.Left; ob.BorderSizePixel = 0; ob.Parent = optC
            Instance.new("UICorner", ob).CornerRadius = UDim.new(0, 4)
            do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = ob end
            optButtons[opt] = ob
            ob.Activated:Connect(function()
                selected = opt; ddBtn.Text = tostring(opt) .. " v"; optC.Visible = false
                for oN, b in pairs(optButtons) do b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg; b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite; b.Text = (oN == opt and "> " or "   ") .. tostring(oN) end
                if type(callback) == "function" then callback(opt) end
            end)
        end
    end
    populate(options)
    ddBtn.Activated:Connect(function() optC.Visible = not optC.Visible; ddBtn.Text = tostring(selected) .. (optC.Visible and " ^" or " v") end)
    if indexSearch ~= false then table.insert(rowSearchIndex, {frame = row, query = (labelText .. " " .. (descText or "")):lower()}) end
    return {
        frame = row,
        Set = function(opt)
            selected = opt; ddBtn.Text = tostring(opt) .. " v"
            for oN, b in pairs(optButtons) do b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg; b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite; b.Text = (oN == opt and "> " or "   ") .. tostring(oN) end
        end,
        Get = function() return selected end
    }
end

local function createButtonRow(parent, labelText, descText, btnText, callback, indexSearch)
    if type(descText) == "function" then
        indexSearch = btnText
        callback = descText
        btnText = "执行"
        descText = ""
    elseif type(btnText) == "function" then
        indexSearch = callback
        callback = btnText
        btnText = descText
        descText = ""
    end
    local row = createBaseRow(parent, labelText, descText, 82, indexSearch)
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 74, 0, 22); btn.Position = UDim2.new(1, -74, 0.5, -11); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = btnText or "执行"; btn.TextColor3 = Colors.PurplePrimary; btn.TextSize = 10; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    btn.Activated:Connect(function()
        if type(callback) == "function" then pcall(callback) end
    end)
    return btn
end

local function createInfoRow(parent, labelText, valueText, indexSearch)
    local row = createBaseRow(parent, labelText, "", 120, indexSearch)
    local vl = Instance.new("TextLabel"); vl.Size = UDim2.new(0, 115, 1, 0); vl.Position = UDim2.new(1, -115, 0, 0); vl.BackgroundTransparency = 1; vl.Font = Enum.Font.GothamBold; vl.Text = valueText; vl.TextColor3 = Colors.PurplePrimary; vl.TextSize = 10; vl.TextXAlignment = Enum.TextXAlignment.Right; vl.Parent = row
    return {frame = row, Set = function(nv) vl.Text = nv end}
end

-- 创建精简后的3个选项卡
local tabFishing   = CreateTab("钓鱼")
local tabTeleports = CreateTab("传送")
local tabSettings  = CreateTab("设置")

SwitchTab("钓鱼")

-- 鱼竿数据表
local allRods = {
    {name = "Wooden Rod", price = 0, power = 8, luck = 1},
    {name = "Bamboo Rod", price = 100, power = 11, luck = 5},
    {name = "Iron Hook Rod", price = 500, power = 13, luck = 10},
    {name = "Steel Rod", price = 1000, power = 17, luck = 11},
    {name = "Enchanted Steel Rod", price = 2000, power = 19, luck = 12},
    {name = "Alloy Rod", price = 5000, power = 22, luck = 5},
    {name = "Emerald Rod", price = 10000, power = 25, luck = 10},
    {name = "Bloodfire Rod", price = 20000, power = 27, luck = 10},
    {name = "Shadow Rod", price = 60000, power = 29, luck = 22},
    {name = "Triple Steel Rod", price = 100000, power = 32, luck = 20},
    {name = "Golden Rod", price = 200000, power = 35, luck = 22},
    {name = "Grandmaster Steel Rod", price = 250000, power = 37, luck = 10},
    {name = "Grandmaster Golden Rod", price = 1000000, power = 45, luck = 30},
    {name = "Steel Spine Rod", price = 1500000, power = 48, luck = 20},
    {name = "Inferno Rod", price = 1500000, power = 48, luck = 18},
    {name = "Golden Spine Rod", price = 2000000, power = 51, luck = 21},
    {name = "Platinum Spine Rod", price = 3000000, power = 54, luck = 25},
    {name = "Diamond Spine Rod", price = 4000000, power = 56, luck = 25},
    {name = "Gravisteel Rod", price = 5000000, power = 58, luck = 15},
    {name = "Auric Gravity Rod", price = 6000000, power = 60, luck = 10},
    {name = "Inferno Gravity Rod", price = 7000000, power = 62, luck = 20},
    {name = "Cryo Gravity Rod", price = 8000000, power = 65, luck = 36},
    {name = "Thunder Thorn Rod", price = 10000000, power = 67, luck = 30},
    {name = "Starlight Rod", price = 60000000, power = 83, luck = 15},
}

-- 定时卖鱼计时器变量提前声明
local lastTimedSellTick = tick()
local isSellingProcess = false

----------------------------------------------------------------------
-- [选项卡 1] 钓鱼自动化、出售与防挂机
----------------------------------------------------------------------

createCategoryHeader(tabFishing, "核心钓鱼自动化")
local fishCard = createCardGroup(tabFishing)
createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿", Config.AutoCast, function(v) Config.AutoCast = v end)
createSliderRow(fishCard, "抛竿延迟", "每次抛竿间隔", 0.5, 5.0, Config.CastDelay, true, "秒", function(v) Config.CastDelay = v end)
createToggleRow(fishCard, "锚定条(小游戏锁定)", "自动居中小游戏条，100%捕获", Config.AnchorBar, function(v) Config.AnchorBar = v end)
createToggleRow(fishCard, "自动猛击/暴击", "提示时自动点击猛击打出暴击", Config.AutoSlam, function(v) Config.AutoSlam = v end)
createToggleRow(fishCard, "自动充能耐久", "提示时自动充能鱼线耐久", Config.AutoCharge, function(v) Config.AutoCharge = v end)
createToggleRow(fishCard, "自动技能(爆发DPS)", "收线时自动释放鱼竿技能", Config.AutoSkills, function(v) Config.AutoSkills = v end)

createCategoryHeader(tabFishing, "经济与出售 (含0~60分钟定时)")
local sellCard = createCardGroup(tabFishing)

-- 新增：0~60分钟定时自动卖鱼
createToggleRow(sellCard, "开启分钟级定时卖鱼", "按设定的分钟数(0~60分)周期自动卖鱼", Config.TimedSellEnabled, function(v)
    Config.TimedSellEnabled = v
    lastTimedSellTick = tick()
    if v and Config.TimedSellMinutes > 0 then
        ShowNotification("定时卖鱼", string.format("已开启！每 %d 分钟自动卖鱼。", Config.TimedSellMinutes), "SUCCESS")
    elseif v and Config.TimedSellMinutes == 0 then
        ShowNotification("定时卖鱼", "请拖动滑块选择 1~60 分钟。", "WARN")
    else
        ShowNotification("定时卖鱼", "已关闭分钟定时卖鱼。", "WARN")
    end
end)

createSliderRow(sellCard, "定时卖鱼时间(0~60分)", "每隔多少分钟自动卖鱼(如30分)", 0, 60, Config.TimedSellMinutes, false, "分", function(v)
    Config.TimedSellMinutes = v
    lastTimedSellTick = tick()
end)

createToggleRow(sellCard, "卖鱼传送娜娜并返回原位", "到时间传去娜娜卖鱼后传回原钓点", Config.SellTpAndReturn, function(v)
    Config.SellTpAndReturn = v
end)

local infoTimedSellCountdown = createInfoRow(sellCard, "距离下次定时卖鱼", "未开启")

-- 原有快速自动卖鱼 (按秒/满包)
createToggleRow(sellCard, "自动卖鱼(原有秒级模式)", "背包满或按秒级间隔出售", Config.AutoSell, function(v) Config.AutoSell = v end)
createSliderRow(sellCard, "秒级出售间隔", "原有秒级卖鱼频率", 10, 300, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end)

createButtonRow(sellCard, "立即传送到娜娜并卖鱼", "手动传去娜娜处清空出售背包", "立即出售", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-203.5, 7.3, 107.1)
        task.wait(0.3)
        if Events and Events:FindFirstChild("SellFish") then
            Events.SellFish:FireServer("All")
            ShowNotification("卖鱼", "已将所有鱼卖给娜娜！", "SUCCESS")
        end
    end
end)

local fishList = {"Colossal Tigerfish", "Heavenpiercer Turtle", "Golden Guardian Fish", "Crimson Electric Eel", "Frost Kingfish", "Ascended Perch", "Primordial Kunfish Overlord", "Warbringer Shark", "Mountain Fish", "Tiger Mirefish", "Mirage Lanternfish", "Octoparasitic Fish"}
createToggleRow(sellCard, "自动收藏保护鱼", "保护选中的目标鱼不被出售", Config.AutoFavouriteFish, function(v) Config.AutoFavouriteFish = v end)
createDropdownRow(sellCard, "收藏保护目标", "选择要保护的珍稀鱼类", fishList, Config.FavouriteFishName, function(v) Config.FavouriteFishName = v end)
createToggleRow(sellCard, "材料收集保护", "自动锁定制作材料鱼防误卖", Config.MaterialFarming, function(v) Config.MaterialFarming = v end)

createCategoryHeader(tabFishing, "防挂机与稳定性")
local afkCard = createCardGroup(tabFishing)
createToggleRow(afkCard, "防挂机 (Anti-AFK)", "防止Roblox 20分钟无操作踢出", Config.AntiAFK, function(v)
    Config.AntiAFK = v
    ShowNotification("防挂机", v and "已开启防挂机保护！" or "已关闭防挂机保护。", v and "SUCCESS" or "WARN")
end)
createToggleRow(afkCard, "被踢/断线自动重连", "掉线或被踢时自动重新进服", Config.AutoRejoin, function(v)
    Config.AutoRejoin = v
    ShowNotification("自动重连", v and "已开启断线自动重连！" or "已关闭断线自动重连。", v and "SUCCESS" or "WARN")
end)

createCategoryHeader(tabFishing, "智能自动装备与统计")
local equipCard = createCardGroup(tabFishing)
local infoEquippedRod = createInfoRow(equipCard, "已装备鱼竿", "检测中...")
local infoEquippedBait = createInfoRow(equipCard, "已装备鱼饵", "检测中...")
local infoFishCaught = createInfoRow(equipCard, "总捕获鱼数", "0")
local infoCash = createInfoRow(equipCard, "当前现金", "$0")

createToggleRow(equipCard, "自动装备最佳鱼饵", "自动装备运气最高的鱼饵", Config.AutoEquipBestBait, function(v) Config.AutoEquipBestBait = v end)
createToggleRow(equipCard, "自动装备最佳鱼竿", "自动装备最高威力鱼竿", Config.AutoEquipBestRod, function(v) Config.AutoEquipBestRod = v end)
createToggleRow(equipCard, "自动装备最佳宝珠", "自动装备最高品质宝珠", Config.AutoEquipBestOrb, function(v) Config.AutoEquipBestOrb = v end)

local rodNameList = {}
for _, r in ipairs(allRods) do table.insert(rodNameList, r.name) end
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait"}

createDropdownRow(equipCard, "方案1鱼竿", "方案1保存的鱼竿", rodNameList, Config.Loadout1_Rod, function(v) Config.Loadout1_Rod = v end)
createDropdownRow(equipCard, "方案1鱼饵", "方案1保存的鱼饵", baitNameList, Config.Loadout1_Bait, function(v) Config.Loadout1_Bait = v end)
createButtonRow(equipCard, "切换方案1", "立即装备方案1配置", "装备#1", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData then
        local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout1_Rod)
        local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
        if isOwned then
            if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout1_Rod) end
            ShowNotification("方案1", "已装备鱼竿: " .. Config.Loadout1_Rod, "SUCCESS")
        else
            ShowNotification("方案1", "尚未拥有 " .. Config.Loadout1_Rod, "WARN")
        end
        local bFolder = pData.Bait:FindFirstChild(Config.Loadout1_Bait)
        if bFolder and bFolder.Value > 0 then
            if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout1_Bait) end
            ShowNotification("方案1", "已装备鱼饵: " .. Config.Loadout1_Bait, "SUCCESS")
        else
            ShowNotification("方案1", "背包中 " .. Config.Loadout1_Bait .. " 数量为0", "WARN")
        end
    end
end)

createDropdownRow(equipCard, "方案2鱼竿", "方案2保存的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end)
createDropdownRow(equipCard, "方案2鱼饵", "方案2保存的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end)
createButtonRow(equipCard, "切换方案2", "立即装备方案2配置", "装备#2", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData then
        local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout2_Rod)
        local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
        if isOwned then
            if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout2_Rod) end
            ShowNotification("方案2", "已装备鱼竿: " .. Config.Loadout2_Rod, "SUCCESS")
        else
            ShowNotification("方案2", "尚未拥有 " .. Config.Loadout2_Rod, "WARN")
        end
        local bFolder = pData.Bait:FindFirstChild(Config.Loadout2_Bait)
        if bFolder and bFolder.Value > 0 then
            if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout2_Bait) end
            ShowNotification("方案2", "已装备鱼饵: " .. Config.Loadout2_Bait, "SUCCESS")
        else
            ShowNotification("方案2", "背包中 " .. Config.Loadout2_Bait .. " 数量为0", "WARN")
        end
    end
end)

----------------------------------------------------------------------
-- [选项卡 2] 常用与岛屿传送
----------------------------------------------------------------------

createCategoryHeader(tabTeleports, "NPC与核心功能点")
local npcTpCard = createCardGroup(tabTeleports)

createButtonRow(npcTpCard, "娜娜 (卖鱼NPC)", "传送到起始岛娜娜身边卖鱼", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-203.5, 7.3, 107.1)
        ShowNotification("传送", "已传送到娜娜(卖鱼NPC)！", "SUCCESS")
    end
end)

createButtonRow(npcTpCard, "起始岛码头 (出生点)", "传送到起始岛中心码头", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-200.7, 11.1, 35.9)
        ShowNotification("传送", "已传送到起始岛码头！", "SUCCESS")
    end
end)

createCategoryHeader(tabTeleports, "岛屿进度 (1-10号岛屿)")
local islandCard = createCardGroup(tabTeleports)

local islands = {
    {name = "[1] 起始岛", pos = Vector3.new(-200.7, 11.1, 35.9)},
    {name = "[2] 竹岛", pos = Vector3.new(-1223.0, 7.3, -24.1)},
    {name = "[3] 辐射岛", pos = Vector3.new(65.5, 8.8, 1181.3)},
    {name = "[4] 主权岛", pos = Vector3.new(-1276.4, 8.8, 1239.7)},
    {name = "[5] 鲈鱼岛", pos = Vector3.new(-62.0, 11.9, -1321.4)},
    {name = "[6] 冰霜岛", pos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {name = "[7] 椰子岛", pos = Vector3.new(1493.6, 9.1, -1430.6)},
    {name = "[8] 琥珀岛", pos = Vector3.new(1259.4, 9.1, 1401.5)},
    {name = "[9] 战场岛", pos = Vector3.new(1393.5, 11.3, 169.6)},
    {name = "[10] 雾峰岛", pos = Vector3.new(2660.2, 8.8, -86.7)},
}

for _, isl in ipairs(islands) do
    createButtonRow(islandCard, isl.name, "传送到 " .. isl.name, "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(isl.pos + Vector3.new(0, 3, 0))
            ShowNotification("传送", "已到达 " .. isl.name .. "！", "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "各岛鱼竿商人 (标迪)")
local rodDealerCard = createCardGroup(tabTeleports)

local rodDealers = {
    {name = "[1] 起始岛商人", pos = Vector3.new(-151.4, 8.7, -49.9)},
    {name = "[2] 竹岛商人", pos = Vector3.new(-1236.8, 7.3, -174.1)},
    {name = "[3] 辐射岛商人", pos = Vector3.new(138.4, 9.0, 1179.7)},
    {name = "[4] 主权岛商人", pos = Vector3.new(-1262.6, 8.2, 1202.2)},
    {name = "[5] 鲈鱼岛商人", pos = Vector3.new(-9.5, 9.2, -1330.0)},
    {name = "[6] 冰霜岛商人", pos = Vector3.new(-1400.4, 9.2, -1490.6)},
    {name = "[7] 椰子岛商人", pos = Vector3.new(1446.0, 9.3, -1408.0)},
    {name = "[8] 琥珀岛商人", pos = Vector3.new(1292.7, 8.2, 1497.4)},
}

for _, rd in ipairs(rodDealers) do
    createButtonRow(rodDealerCard, rd.name, "传送到对应鱼竿商人", "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(rd.pos + Vector3.new(0, 3, 0))
            ShowNotification("传送", "已到达 " .. rd.name .. "！", "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "秘密鱼竿坐标")
local sRodCard = createCardGroup(tabTeleports)

local secretRods = {
    {name = "锚定鱼竿", pos = Vector3.new(-1208.5, 56.3, 1646.2)},
    {name = "火焰鲨鱼竿", pos = Vector3.new(-8.4, 53.9, 6.7)},
    {name = "海妖鱼竿", pos = Vector3.new(1543.8, 73.4, 1490.9)},
    {name = "升华竹竿", pos = Vector3.new(-1360.6, 140.6, 31.0)},
    {name = "生命绽放鱼竿", pos = Vector3.new(-114.9, 74.9, -1533.2)},
    {name = "恶魔鱼竿", pos = Vector3.new(1181.9, 82.9, -1243.8)}
}

for _, sr in ipairs(secretRods) do
    createButtonRow(sRodCard, sr.name, "传送到秘密鱼竿拾取点", "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(sr.pos + Vector3.new(0, 3, 0))
            ShowNotification("传送", "已传送到 " .. sr.name .. "！", "SUCCESS")
        end
    end)
end

----------------------------------------------------------------------
-- [选项卡 3] 设置与手机屏幕缩放
----------------------------------------------------------------------

createCategoryHeader(tabSettings, "手机界面大小调节")
local uiCard = createCardGroup(tabSettings)
createSliderRow(uiCard, "窗口缩放比例", "觉得窗口太大可往左拉小(50%~120%)", 50, 120, Config.UIScalePercent, false, "%", function(v)
    Config.UIScalePercent = v
    ApplyUIScale()
end)
createButtonRow(uiCard, "窗口位置居中复位", "如果不小心把窗口拖出屏幕可点此复位", "居中", function()
    mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
end)

createCategoryHeader(tabSettings, "配置文件管理")
local profCard = createCardGroup(tabSettings)

createButtonRow(profCard, "保存配置", "将当前设置保存到本地JSON", "保存", function()
    if SaveProfile() then
        ShowNotification("配置", "配置保存成功！", "SUCCESS")
    else
        ShowNotification("配置", "保存配置失败。", "ERROR")
    end
end)

createButtonRow(profCard, "加载配置", "从本地JSON读取保存的设置", "读取", function()
    if LoadProfile() then
        ApplyUIScale()
        ShowNotification("配置", "配置读取成功！", "SUCCESS")
    else
        ShowNotification("配置", "未找到已保存的配置。", "WARN")
    end
end)

createToggleRow(profCard, "启动自动加载配置", "注入时自动加载默认配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end)

createCategoryHeader(tabSettings, "会话操作")
local credCard = createCardGroup(tabSettings)
createButtonRow(credCard, "手动重新加入当前服务器", "立即重连当前服务器", "重连", function()
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end)
createButtonRow(credCard, "卸载脚本", "安全退出并移除所有界面与监听", "卸载", UnloadScript)

----------------------------------------------------------------------
-- 核心逻辑主循环
----------------------------------------------------------------------

local lastCastTime = 0
local lastSellTime = 0
local lastSkillTime = 0
local lastEquipTime = 0
local lastProgressionTime = 0
local lastProtectTime = 0
local lastAntiAfkTick = 0

local craftMaterialFish = {
    ["Mountain Fish"] = true,
    ["Catfish"] = true,
    ["Crimson Catfish"] = true,
    ["Scarlet Fish"] = true,
    ["Elder Scarlet Fish"] = true,
    ["Octoparasitic Fish"] = true,
    ["Tiger Mirefish"] = true,
    ["Mirage Lanternfish"] = true,
    ["Golden Guardian Fish"] = true,
    ["Frost Kingfish"] = true,
    ["Frost Queenfish"] = true,
    ["Rainbow Dragonfish"] = true,
    ["Sanguine Fish"] = true,
}

-- 保护目标鱼不被出售的辅助函数
local function ProtectTargetFish(pData)
    if (Config.MaterialFarming or Config.AutoFavouriteFish) and pData and pData:FindFirstChild("Inventory") then
        for _, item in ipairs(pData.Inventory:GetChildren()) do
            local itemName = item.Name
            local isFav = item:FindFirstChild("Favorite") and item.Favorite.Value == true
            if not isFav and ((Config.MaterialFarming and craftMaterialFish[itemName]) or (Config.AutoFavouriteFish and itemName == Config.FavouriteFishName)) then
                if Events and Events:FindFirstChild("FavoriteItem") then
                    Events.FavoriteItem:FireServer(item)
                end
            end
        end
    end
end

-- 执行卖鱼流程 (支持直接远程卖鱼 或 传送到娜娜处卖鱼并返回原位)
local function ExecuteSellRoutine(pData, useTeleport, notifyReason)
    if isSellingProcess then return end
    isSellingProcess = true
    task.spawn(function()
        pcall(function()
            ProtectTargetFish(pData)
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if useTeleport and root then
                local savedCFrame = root.CFrame
                root.CFrame = CFrame.new(-203.5, 7.3, 107.1)
                task.wait(0.35)
                if Events and Events:FindFirstChild("SellFish") then
                    Events.SellFish:FireServer("All")
                end
                task.wait(0.35)
                if root and root.Parent then
                    root.CFrame = savedCFrame
                end
            else
                if Events and Events:FindFirstChild("SellFish") then
                    Events.SellFish:FireServer("All")
                end
            end
            if notifyReason then
                ShowNotification("自动卖鱼", notifyReason, "SUCCESS")
            end
        end)
        lastSellTime = tick()
        isSellingProcess = false
    end)
end

table.insert(activeConnections, RunService.Heartbeat:Connect(function(dt)
    if not isRunning then return end
    pcall(function()
        local now = tick()

        -- 主动防挂机保活 (每60秒模拟一次微小虚拟输入防止闲置计时累积)
        if Config.AntiAFK and (now - lastAntiAfkTick >= 60) then
            lastAntiAfkTick = now
            pcall(function()
                if VirtualUser then
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new(0, 0))
                end
            end)
        end

        -- 更新 0~60 分钟定时卖鱼倒计时显示
        if Config.TimedSellEnabled and Config.TimedSellMinutes > 0 then
            local targetSeconds = Config.TimedSellMinutes * 60
            local elapsed = now - lastTimedSellTick
            local remaining = math.max(0, math.floor(targetSeconds - elapsed))
            local mins = math.floor(remaining / 60)
            local secs = remaining % 60
            infoTimedSellCountdown.Set(string.format("%02d分%02d秒", mins, secs))
        elseif Config.TimedSellEnabled and Config.TimedSellMinutes == 0 then
            infoTimedSellCountdown.Set("已设0分钟(暂停)")
        else
            infoTimedSellCountdown.Set("未开启")
        end

        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then return end
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)

        local isFishing = char:GetAttribute("Fishing") == true
        local isMinigame = char:GetAttribute("Minigame") == true or (pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing") and pg.MainGui.Fishing.Visible)
        local isCD = char:GetAttribute("CDForTheNextThrow") == true
        local isSwimming = char:GetAttribute("Swimming") == true

        -- 小游戏自动化
        if isMinigame then
            local fUI = pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing")
            if fUI and fUI.Visible then
                if Config.AnchorBar then
                    local barFrame = fUI:FindFirstChild("BarFrame")
                    if barFrame and barFrame:FindFirstChild("Bar") then
                        barFrame.Bar:TweenPosition(UDim2.new(0.5, 0, 0.5, 0), Enum.EasingDirection.InOut, Enum.EasingStyle.Linear, 0, true)
                        barFrame.Bar.Position = UDim2.new(0.5, 0, 0.5, 0)
                    end
                end

                if Config.AutoSlam and fUI:FindFirstChild("PerfectButton") and fUI.PerfectButton.Visible then
                    if Events:FindFirstChild("Slam") then
                        Events.Slam:FireServer()
                    end
                end

                if Config.AutoCharge and fUI:FindFirstChild("Charge") and fUI.Charge.Visible then
                    if Events:FindFirstChild("Charge") then
                        Events.Charge:FireServer()
                    end
                end

                if Config.AnchorBar and (now - lastProgressionTime >= 0.08) then
                    if Events and Events:FindFirstChild("UpdateFishProgression") then
                        Events.UpdateFishProgression:FireServer()
                    end
                    lastProgressionTime = now
                end

                if Config.AutoSkills and (now - lastSkillTime >= 0.15) then
                    for _, sk in ipairs({"Z", "X", "C", "V"}) do
                        if Events:FindFirstChild("UseSkill") then Events.UseSkill:FireServer(sk) end
                        if Events:FindFirstChild("TriggerMinigameSkill") then Events.TriggerMinigameSkill:FireServer(sk) end
                    end
                    lastSkillTime = now
                end
            end
        elseif isFishing then
            lastCastTime = now
        else
            -- 非收杆/小游戏状态下：优先检测 0~60 分钟定时自动卖鱼是否到期
            if Config.TimedSellEnabled and Config.TimedSellMinutes > 0 and not isSellingProcess then
                local targetSeconds = Config.TimedSellMinutes * 60
                if (now - lastTimedSellTick) >= targetSeconds then
                    lastTimedSellTick = now
                    ExecuteSellRoutine(
                        pData,
                        Config.SellTpAndReturn,
                        string.format("已到 %d 分钟，自动完成卖鱼！", Config.TimedSellMinutes)
                    )
                    return
                end
            end

            -- 自动抛竿与原有自动卖鱼逻辑
            if Config.AutoCast and not isCD and not isSwimming and not isSellingProcess and (now - lastCastTime >= Config.CastDelay) then
                local canCast = true
                if pData and pData:FindFirstChild("InventoryLimit") then
                    local invCount = 0
                    if pData:FindFirstChild("Inventory") then invCount = invCount + #pData.Inventory:GetChildren() end
                    if pData:FindFirstChild("Hotbar") then
                        for _, item in ipairs(pData.Hotbar:GetChildren()) do
                            if item:FindFirstChild("Quantity") then invCount = invCount + item.Quantity.Value else invCount = invCount + 1 end
                        end
                    end
                    -- 背包满时自动出售
                    if invCount >= pData.InventoryLimit.Value then
                        canCast = false
                        if (Config.AutoSell or Config.TimedSellEnabled) and (now - lastSellTime >= 5.0) then
                            ExecuteSellRoutine(pData, Config.SellTpAndReturn, "背包已满，已自动清空出售！")
                        end
                    end
                end

                -- 原有按秒定时自动卖鱼
                if Config.AutoSell and (now - lastSellTime >= Config.SellInterval) then
                    ExecuteSellRoutine(pData, false, nil)
                end

                -- 保护鱼收藏检查
                if (Config.MaterialFarming or Config.AutoFavouriteFish) and (now - lastProtectTime >= 1.5) then
                    lastProtectTime = now
                    ProtectTargetFish(pData)
                end

                -- 执行抛竿
                if canCast and not isSellingProcess and Events and Events:FindFirstChild("Fishing") then
                    Events.Fishing:FireServer(root.CFrame)
                    lastCastTime = now
                end
            else
                -- 即使未开启自动抛竿，如果开启了原有的按秒自动卖鱼也正常运作
                if Config.AutoSell and not isSellingProcess and (now - lastSellTime >= Config.SellInterval) then
                    ExecuteSellRoutine(pData, false, nil)
                end
            end
        end

        -- 装备与数据定期刷新 (每5秒更新一次状态)
        if (now - lastEquipTime >= 5.0) and pData then
            lastEquipTime = now
            if Config.AutoEquipBestBait and pData:FindFirstChild("Bait") and pData:FindFirstChild("EquippedBait") and Events:FindFirstChild("EquipBait") then
                local bestBait = nil
                local bestLuck = -1
                local baitLuckMap = {
                    ["Ancestral Bait"] = 50,
                    ["Elite Bait"] = 30,
                    ["Corrupted Essence Bait"] = 18,
                    ["Crude Mash Bait"] = 8,
                    ["Basic Bait"] = 3
                }
                for bName, bLuck in pairs(baitLuckMap) do
                    local bVal = pData.Bait:FindFirstChild(bName)
                    if bVal and bVal.Value > 0 and bLuck > bestLuck then
                        bestLuck = bLuck
                        bestBait = bName
                    end
                end
                if bestBait and pData.EquippedBait.Value ~= bestBait then
                    Events.EquipBait:InvokeServer(bestBait)
                end
            end

            if Config.AutoEquipBestRod and pData:FindFirstChild("FishingRodInventory") and pData:FindFirstChild("FishingRod") and Events:FindFirstChild("EquipFishingRod") then
                local bestRod = nil
                local bestPower = -1
                for _, r in ipairs(allRods) do
                    local rFolder = pData.FishingRodInventory:FindFirstChild(r.name)
                    local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
                    if isOwned and r.power > bestPower then
                        bestPower = r.power
                        bestRod = r.name
                    end
                end
                if bestRod and pData.FishingRod.Value ~= bestRod then
                    Events.EquipFishingRod:InvokeServer(bestRod)
                end
            end

            if Config.AutoEquipBestOrb and pData:FindFirstChild("Orb") and Events:FindFirstChild("EquipOrb") then
                local orbs = pData.Orb:GetChildren()
                if #orbs > 0 then
                    local bestOrb = orbs[#orbs].Name
                    Events.EquipOrb:InvokeServer(bestOrb)
                end
            end

            if pData:FindFirstChild("FishingRod") and pData.FishingRod.Value ~= "" then infoEquippedRod.Set(pData.FishingRod.Value) end
            if pData:FindFirstChild("EquippedBait") and pData.EquippedBait.Value ~= "" then infoEquippedBait.Set(pData.EquippedBait.Value) end
            if pData:FindFirstChild("FishCaught") then infoFishCaught.Set(tostring(pData.FishCaught.Value)) end
            if pData:FindFirstChild("Cash") then infoCash.Set("$" .. tostring(pData.Cash.Value)) end
        end
    end)
end))

-- 小游戏视觉辅助 (对齐条和进度)
table.insert(activeConnections, RunService.RenderStepped:Connect(function()
    if not isRunning then return end
    pcall(function()
        if Config.AnchorBar then
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            if pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing") and pg.MainGui.Fishing.Visible then
                local fUI = pg.MainGui.Fishing
                local barFrame = fUI:FindFirstChild("BarFrame")
                if barFrame and barFrame:FindFirstChild("Bar") then
                    barFrame.Bar.Position = UDim2.new(0.5, 0, 0.5, 0)
                end
                local bossBar = fUI:FindFirstChild("BossFightBar")
                if bossBar and bossBar.Visible and bossBar:FindFirstChild("Bar") and bossBar:FindFirstChild("Hitbox") then
                    bossBar.Bar.Position = bossBar.Hitbox.Position
                end
                local hpPlayer = fUI:FindFirstChild("HPPlayer")
                if hpPlayer and hpPlayer:FindFirstChild("ProgressionBar") then
                    local pBar = hpPlayer.ProgressionBar
                    if pBar:FindFirstChild("Bar") then
                        pBar.Bar.Size = UDim2.new(1, 0, 1, 0)
                    end
                end
                if fUI:FindFirstChild("PerfectButton") and fUI.PerfectButton.Visible then
                    if Events and Events:FindFirstChild("Slam") then Events.Slam:FireServer("Perfect") end
                end
                if fUI:FindFirstChild("Charge") and fUI.Charge.Visible then
                    if Events and Events:FindFirstChild("Charge") then Events.Charge:FireServer(100) end
                end
            end
        end
    end)
end))

if Events and Events:FindFirstChild("Slam") then
    table.insert(activeConnections, Events.Slam.OnClientEvent:Connect(function(slamEvent)
        if isRunning and Config.AnchorBar and typeof(slamEvent) == "Instance" then
            pcall(function() slamEvent:FireServer("Perfect") end)
        end
    end))
end

if Events and Events:FindFirstChild("Charge") then
    table.insert(activeConnections, Events.Charge.OnClientEvent:Connect(function(chargeEvent)
        if isRunning and Config.AnchorBar and typeof(chargeEvent) == "Instance" then
            pcall(function() chargeEvent:FireServer(100) end)
        end
    end))
end

-- 双重防挂机 (禁用Idled内置踢出事件 + VirtualUser响应)
pcall(function()
    if getconnections then
        for _, conn in pairs(getconnections(LocalPlayer.Idled)) do
            if conn.Disable then conn:Disable()
            elseif conn.Disconnect then conn:Disconnect() end
        end
    end
end)

table.insert(activeConnections, LocalPlayer.Idled:Connect(function()
    if Config.AntiAFK and isRunning then
        pcall(function()
            if VirtualUser then
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end
        end)
    end
end))

-- 断线/被踢自动重连监听
pcall(function()
    table.insert(activeConnections, GuiService.ErrorMessageChanged:Connect(function()
        if Config.AutoRejoin and isRunning then
            task.wait(2)
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end
    end))
end)

-- 快捷键监听 (电脑端备用)
table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl or input.KeyCode == Config.UIKeybind then
        if ToggleUiVisibility then ToggleUiVisibility() end
    elseif input.KeyCode == Enum.KeyCode.End or input.KeyCode == Config.StopKeybind then
        UnloadScript()
    end
end))

ShowNotification("重型钓鱼", "手机优化版已就绪！点左上角【收/钓】悬浮球可随时收起菜单。", "SUCCESS", 4)
