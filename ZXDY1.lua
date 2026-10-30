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
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local isRunning = true
local activeConnections = {}
local cleanUpInstances = {}

local Events = ReplicatedStorage:WaitForChild("Events", 10)

local Config = {
    AutoCast = false, -- 自动抛竿
    CastDelay = 1.0, -- 抛竿延迟
    CastPower = 100, -- 抛竿力度
    AnchorBar = true, -- 锚定条(小游戏)
    AutoSlam = true, -- 自动猛击
    AutoCharge = true, -- 自动充能
    InstantCatch = true, -- 瞬间捕捉
    AutoSkills = false, -- 自动技能
    SelectedSkill = "One-Strike Heaven Gate", -- 选择的技能
    
    AutoEquipBestBait = false, -- 自动装备最佳鱼饵
    AutoEquipBestRod = false, -- 自动装备最佳鱼竿
    AutoEquipBestOrb = false, -- 自动装备最佳宝珠
    Loadout1_Rod = "Wooden Rod", -- 方案1鱼竿
    Loadout1_Bait = "Basic Bait", -- 方案1鱼饵
    Loadout2_Rod = "Wooden Rod", -- 方案2鱼竿
    Loadout2_Bait = "Basic Bait", -- 方案2鱼饵
    
    AutoSell = false, -- 自动卖鱼
    SellInterval = 30, -- 卖鱼间隔
    AutoFavouriteFish = false, -- 自动收藏鱼
    FavouriteFishName = "Colossal Tigerfish", -- 收藏的鱼名
    MaterialFarming = false, -- 材料收集模式
    
    OctoAutoMinigame = false, -- 章鱼自动小游戏
    AutoFarmBoss = false, -- 自动刷Boss
    AutoFarmSecretBoss = false, -- 自动刷隐藏Boss
    SelectedBoss = "Enzo", -- 选择的Boss
    
    AutoGodSpiritCheck = false, -- 自动检测神灵
    AutoPrayGodSpirit = false, -- 自动祈祷神灵
    AutoServerHopGod = false, -- 自动跳服务器找神灵
    AutoServerHopMaoshan = false, -- 自动跳服务器找茅山
    AutoServerHopTaoist = false, -- 自动跳服务器找道士
    
    AutoTicketQuest = false, -- 自动票据任务
    TicketDifficulty = "Easy", -- 票据任务难度
    AutoClaimDaily = false, -- 自动领取每日奖励
    DailyClaimDelay = 0.5, -- 每日奖励领取延迟
    
    AutoCraftBait = false, -- 自动制作鱼饵
    CraftBaitName = "Nameless Bait", -- 制作鱼饵名称
    CraftAmount = 1, -- 制作数量
    AutoBuyBait = false, -- 自动购买鱼饵
    BuyBaitName = "Ancestral Bait", -- 购买鱼饵名称
    BuyBaitAmount = 5, -- 购买数量
    BuyBaitThreshold = 10, -- 购买阈值
    BuyBaitDelay = 1.0, -- 购买延迟
    
    AutoGacha = false, -- 自动扭蛋
    GachaBanner = "Taiji Banner", -- 扭蛋卡池
    GachaPullsPerAction = 1, -- 每次扭蛋次数
    
    WalkSpeedEnabled = false, -- 启用步行加速
    WalkSpeedValue = 16, -- 步行速度值
    FlyEnabled = false, -- 启用飞行
    FlySpeed = 50, -- 飞行速度
    InfiniteJump = false, -- 无限跳跃
    WalkOnWater = false, -- 水上行走
    Noclip = false, -- 穿墙
    
    ESP_GodSpirit = false, -- 神灵ESP
    ESP_SecretRod = false, -- 秘密鱼竿ESP
    ESP_Boats = false, -- 船只ESP
    ESP_Maoshan = false, -- 茅山ESP
    ESP_Taoist = false, -- 道士ESP
    ESP_Boss = false, -- Boss ESP
    ESP_Players = false, -- 玩家ESP
    FishRedRing = true, -- 鱼红色光圈
    NoFog = false, -- 去除雾霾
    Fullbright = false, -- 全亮
    PerformanceMode = false, -- 性能模式
    HideGameUI = false, -- 隐藏游戏UI
    
    AntiAFK = true, -- 防挂机
    AutoRejoin = false, -- 自动重连
    AutoExecuteOnJoin = false, -- 加入时自动执行
    UIKeybind = Enum.KeyCode.RightControl, -- UI快捷键
    StopKeybind = Enum.KeyCode.End, -- 停止快捷键
    ActiveProfile = "default", -- 当前配置文件
    AutoLoadProfile = true -- 自动加载配置文件
}

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

local Colors = {
    Background       = Color3.fromRGB(15, 12, 22), -- 背景色
    SidebarBg        = Color3.fromRGB(11, 9, 17), -- 侧边栏背景
    BorderPurple     = Color3.fromRGB(168, 85, 247), -- 紫色边框
    BorderSubtle     = Color3.fromRGB(45, 33, 66), -- 淡边框
    Divider          = Color3.fromRGB(36, 26, 54), -- 分隔线

    PurplePrimary    = Color3.fromRGB(216, 160, 255), -- 主紫色
    PurpleAccent     = Color3.fromRGB(168, 85, 247), -- 强调紫色
    PurpleMuted      = Color3.fromRGB(147, 112, 196), -- 柔和紫色
    PurpleDark       = Color3.fromRGB(72, 45, 107), -- 深紫色
    PurpleGlow       = Color3.fromRGB(192, 132, 252), -- 发光紫色

    RowNormal        = Color3.fromRGB(20, 16, 30), -- 行普通色
    RowHover         = Color3.fromRGB(30, 22, 46), -- 行悬停色
    ControlBg        = Color3.fromRGB(28, 20, 44), -- 控件背景
    InputBg          = Color3.fromRGB(18, 14, 26), -- 输入框背景

    TextWhite        = Color3.fromRGB(245, 243, 255), -- 白色文字
    TextSubtle       = Color3.fromRGB(168, 150, 200), -- 淡色文字
    TextMuted        = Color3.fromRGB(110, 95, 138), -- 静音文字

    AccentGreen      = Color3.fromRGB(52, 211, 153), -- 绿色强调
    AccentRed        = Color3.fromRGB(248, 113, 113), -- 红色强调
    AccentOrange     = Color3.fromRGB(251, 146, 60), -- 橙色强调
    AccentYellow     = Color3.fromRGB(250, 204, 21), -- 黄色强调
    AccentBlue       = Color3.fromRGB(96, 165, 250), -- 蓝色强调
    DropdownSelected = Color3.fromRGB(36, 26, 56) -- 下拉选中
}

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
screenGui.Name = "IdenticalHeavyweightFishing"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = getGuiParent()
table.insert(cleanUpInstances, screenGui)

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
    
    pcall(function()
        local leftover = Workspace:FindFirstChild("IdenticalESP")
        if leftover then leftover:Destroy() end
    end)

    pcall(function()
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = 16 end
        Lighting.FogEnd = 100000
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.Ambient = Color3.fromRGB(70, 70, 70)
        Lighting.OutdoorAmbient = Color3.fromRGB(70, 70, 70)
        Lighting.GlobalShadows = true
    end)
    
    if getgenv then getgenv().IdenticalHeavyweightFishingUnload = nil end
end

if getgenv then getgenv().IdenticalHeavyweightFishingUnload = UnloadScript end

local notifContainer = Instance.new("Frame")
notifContainer.Name = "Notifications"
notifContainer.Size = UDim2.new(0, 300, 1, -40)
notifContainer.Position = UDim2.new(1, -315, 0, 20)
notifContainer.BackgroundTransparency = 1
notifContainer.ZIndex = 1000
notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)

local notifLayout = Instance.new("UIListLayout")
notifLayout.SortOrder = Enum.SortOrder.LayoutOrder
notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
notifLayout.Padding = UDim.new(0, 8)
notifLayout.Parent = notifContainer

local function ShowNotification(title, text, notifType, duration)
    if not isRunning then return end
    duration = duration or 3.5
    local accentColor = Colors.PurpleAccent
    if notifType == "SUCCESS" then accentColor = Colors.AccentGreen
    elseif notifType == "WARN" then accentColor = Colors.AccentYellow
    elseif notifType == "ERROR" then accentColor = Colors.AccentRed end

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, 60)
    card.BackgroundColor3 = Colors.Background
    card.BackgroundTransparency = 0.05
    card.BorderSizePixel = 0
    card.ClipsDescendants = true
    card.Parent = notifContainer

    local stroke = Instance.new("UIStroke"); stroke.Color = accentColor; stroke.Thickness = 1.2; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = card
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 20); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 10, 0, 6); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -20, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = title; tLabel.TextColor3 = Colors.PurplePrimary; tLabel.TextSize = 13; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -20, 0, 26); mLabel.Position = UDim2.new(0, 10, 0, 26); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = text; mLabel.TextColor3 = Colors.TextSubtle; mLabel.TextSize = 11; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.Parent = card

    task.delay(duration, function()
        if card and card.Parent then
            TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = 1, Position = card.Position + UDim2.new(1, 20, 0, 0)
            }):Play()
            task.wait(0.35); card:Destroy()
        end
    end)
end

local ToggleUiVisibility

local floatingCrescent = Instance.new("ImageButton")
floatingCrescent.Name = "FloatingCrescent"
floatingCrescent.Size = UDim2.new(0, 44, 0, 44)
floatingCrescent.Position = UDim2.new(0, 20, 0, 20)
floatingCrescent.BackgroundColor3 = Colors.Background
floatingCrescent.BorderSizePixel = 0
floatingCrescent.Visible = false
floatingCrescent.ZIndex = 1000
floatingCrescent.Parent = screenGui
table.insert(cleanUpInstances, floatingCrescent)

do
    local fcCorner = Instance.new("UICorner"); fcCorner.CornerRadius = UDim.new(1, 0); fcCorner.Parent = floatingCrescent
    local fcStroke = Instance.new("UIStroke"); fcStroke.Color = Colors.PurpleAccent; fcStroke.Thickness = 1.5; fcStroke.Parent = floatingCrescent
    local fcIconContainer = Instance.new("Frame"); fcIconContainer.Size = UDim2.new(0, 24, 0, 24); fcIconContainer.Position = UDim2.new(0.5, -12, 0.5, -12); fcIconContainer.BackgroundTransparency = 1; fcIconContainer.ClipsDescendants = true; fcIconContainer.Parent = floatingCrescent
    local fcOuter = Instance.new("Frame"); fcOuter.Size = UDim2.new(0, 24, 0, 24); fcOuter.BackgroundColor3 = Colors.PurplePrimary; fcOuter.BorderSizePixel = 0; fcOuter.Parent = fcIconContainer
    local fcOC = Instance.new("UICorner"); fcOC.CornerRadius = UDim.new(1, 0); fcOC.Parent = fcOuter
    local fcCutout = Instance.new("Frame"); fcCutout.Size = UDim2.new(0, 20, 0, 20); fcCutout.Position = UDim2.new(0, 6, 0, -3); fcCutout.BackgroundColor3 = Colors.Background; fcCutout.BorderSizePixel = 0; fcCutout.Parent = fcOuter
    local fcCC = Instance.new("UICorner"); fcCC.CornerRadius = UDim.new(1, 0); fcCC.Parent = fcCutout

    local fcDragging, fcDragInput, fcDragStart, fcStartPos = false, nil, nil, nil
    floatingCrescent.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            fcDragging = true; fcDragStart = input.Position; fcStartPos = floatingCrescent.Position
            input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then fcDragging = false end end)
        end
    end)
    floatingCrescent.InputChanged:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseMovement then fcDragInput = input end end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if input == fcDragInput and fcDragging then
            local delta = input.Position - fcDragStart
            floatingCrescent.Position = UDim2.new(fcStartPos.X.Scale, fcStartPos.X.Offset + delta.X, fcStartPos.Y.Scale, fcStartPos.Y.Offset + delta.Y)
        end
    end))
    floatingCrescent.MouseEnter:Connect(function()
        TweenService:Create(floatingCrescent, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark}):Play()
        TweenService:Create(fcStroke, TweenInfo.new(0.15), {Color = Colors.PurpleGlow}):Play()
        fcCutout.BackgroundColor3 = Colors.PurpleDark
    end)
    floatingCrescent.MouseLeave:Connect(function()
        TweenService:Create(floatingCrescent, TweenInfo.new(0.15), {BackgroundColor3 = Colors.Background}):Play()
        TweenService:Create(fcStroke, TweenInfo.new(0.15), {Color = Colors.PurpleAccent}):Play()
        fcCutout.BackgroundColor3 = Colors.Background
    end)
    floatingCrescent.MouseButton1Click:Connect(function() if ToggleUiVisibility then ToggleUiVisibility() end end)
end

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 700, 0, 480)
mainFrame.Position = UDim2.new(0.5, -350, 0.5, -240)
mainFrame.BackgroundColor3 = Colors.Background
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui
table.insert(cleanUpInstances, mainFrame)

do
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame
    local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame
end

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Colors.SidebarBg
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

do
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 8); tc.Parent = titleBar
    local tbf = Instance.new("Frame"); tbf.Size = UDim2.new(1, 0, 0, 10); tbf.Position = UDim2.new(0, 0, 1, -10); tbf.BackgroundColor3 = Colors.SidebarBg; tbf.BorderSizePixel = 0; tbf.Parent = titleBar
    local tdiv = Instance.new("Frame"); tdiv.Size = UDim2.new(1, 0, 0, 1); tdiv.Position = UDim2.new(0, 0, 1, -1); tdiv.BackgroundColor3 = Colors.Divider; tdiv.BorderSizePixel = 0; tdiv.Parent = titleBar
end

do
    local cc = Instance.new("Frame"); cc.Size = UDim2.new(0, 16, 0, 16); cc.Position = UDim2.new(0, 14, 0.5, -8); cc.BackgroundTransparency = 1; cc.ClipsDescendants = true; cc.Parent = titleBar
    local co = Instance.new("Frame"); co.Size = UDim2.new(0, 16, 0, 16); co.BackgroundColor3 = Colors.PurpleAccent; co.BorderSizePixel = 0; co.Parent = cc
    Instance.new("UICorner", co).CornerRadius = UDim.new(1, 0)
    local cut = Instance.new("Frame"); cut.Size = UDim2.new(0, 13, 0, 13); cut.Position = UDim2.new(0, 4, 0, -2); cut.BackgroundColor3 = Colors.SidebarBg; cut.BorderSizePixel = 0; cut.Parent = co
    Instance.new("UICorner", cut).CornerRadius = UDim.new(1, 0)
end

local brandTitle = Instance.new("TextLabel")
brandTitle.Size = UDim2.new(0, 150, 1, 0); brandTitle.Position = UDim2.new(0, 36, 0, 0)
brandTitle.BackgroundTransparency = 1; brandTitle.Font = Enum.Font.GothamBold
brandTitle.Text = "IDENTICAL"; brandTitle.TextColor3 = Colors.PurplePrimary
brandTitle.TextSize = 14; brandTitle.TextXAlignment = Enum.TextXAlignment.Left
brandTitle.Parent = titleBar

local gameSubtitle = Instance.new("TextLabel")
gameSubtitle.Size = UDim2.new(0, 200, 1, 0); gameSubtitle.Position = UDim2.new(0, 118, 0, 0)
gameSubtitle.BackgroundTransparency = 1; gameSubtitle.Font = Enum.Font.Gotham
gameSubtitle.Text = "HEAVYWEIGHT FISHING V1.0"; gameSubtitle.TextColor3 = Colors.PurpleMuted
gameSubtitle.TextSize = 10; gameSubtitle.TextXAlignment = Enum.TextXAlignment.Left
gameSubtitle.Parent = titleBar

local winControls = Instance.new("Frame"); winControls.Size = UDim2.new(0, 60, 1, 0); winControls.Position = UDim2.new(1, -65, 0, 0); winControls.BackgroundTransparency = 1; winControls.Parent = titleBar
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 24, 0, 24); minBtn.Position = UDim2.new(0, 4, 0.5, -12); minBtn.BackgroundColor3 = Colors.ControlBg; minBtn.Font = Enum.Font.GothamBold; minBtn.Text = "[-]"; minBtn.TextColor3 = Colors.PurplePrimary; minBtn.TextSize = 11; minBtn.BorderSizePixel = 0; minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 4)
local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 24, 0, 24); closeBtn.Position = UDim2.new(0, 32, 0.5, -12); closeBtn.BackgroundColor3 = Colors.ControlBg; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Text = "[X]"; closeBtn.TextColor3 = Colors.AccentRed; closeBtn.TextSize = 11; closeBtn.BorderSizePixel = 0; closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

do
    local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true; dragStart = input.Position; startPos = mainFrame.Position
            input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    titleBar.InputChanged:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseMovement then dragInput = input end end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
end

local bodyFrame = Instance.new("Frame"); bodyFrame.Name = "Body"; bodyFrame.Size = UDim2.new(1, 0, 1, -62); bodyFrame.Position = UDim2.new(0, 0, 0, 38); bodyFrame.BackgroundTransparency = 1; bodyFrame.Parent = mainFrame

local sidebar = Instance.new("Frame"); sidebar.Name = "Sidebar"; sidebar.Size = UDim2.new(0, 140, 1, 0); sidebar.BackgroundColor3 = Colors.SidebarBg; sidebar.BorderSizePixel = 0; sidebar.Parent = bodyFrame
do local d = Instance.new("Frame"); d.Size = UDim2.new(0, 1, 1, 0); d.Position = UDim2.new(1, -1, 0, 0); d.BackgroundColor3 = Colors.Divider; d.BorderSizePixel = 0; d.Parent = sidebar end

local searchBox = Instance.new("TextBox")
searchBox.Name = "SearchBar"; searchBox.Size = UDim2.new(1, -16, 0, 26); searchBox.Position = UDim2.new(0, 8, 0, 8)
searchBox.BackgroundColor3 = Colors.InputBg; searchBox.Font = Enum.Font.Gotham; searchBox.PlaceholderText = "搜索..."
searchBox.PlaceholderColor3 = Colors.TextMuted; searchBox.Text = ""; searchBox.TextColor3 = Colors.TextWhite
searchBox.TextSize = 11; searchBox.TextXAlignment = Enum.TextXAlignment.Left; searchBox.BorderSizePixel = 0; searchBox.ClearTextOnFocus = false; searchBox.Parent = sidebar
do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = searchBox end
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

local navList = Instance.new("ScrollingFrame"); navList.Name = "NavList"; navList.Size = UDim2.new(1, 0, 1, -44); navList.Position = UDim2.new(0, 0, 0, 42); navList.BackgroundTransparency = 1; navList.BorderSizePixel = 0; navList.ScrollBarThickness = 2; navList.ScrollBarImageColor3 = Colors.BorderSubtle; navList.CanvasSize = UDim2.new(0, 0, 0, 0); navList.AutomaticCanvasSize = Enum.AutomaticSize.Y; navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout"); nl.SortOrder = Enum.SortOrder.LayoutOrder; nl.Padding = UDim.new(0, 4); nl.Parent = navList
    local np = Instance.new("UIPadding"); np.PaddingTop = UDim.new(0, 6); np.PaddingLeft = UDim.new(0, 8); np.PaddingRight = UDim.new(0, 8); np.Parent = navList
end

local contentArea = Instance.new("Frame"); contentArea.Name = "ContentArea"; contentArea.Size = UDim2.new(1, -140, 1, 0); contentArea.Position = UDim2.new(0, 140, 0, 0); contentArea.BackgroundTransparency = 1; contentArea.Parent = bodyFrame

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
    local btn = Instance.new("TextButton"); btn.Name = "TabBtn_" .. name; btn.Size = UDim2.new(1, 0, 0, 30); btn.BackgroundColor3 = Colors.SidebarBg; btn.Font = Enum.Font.GothamBold; btn.Text = name; btn.TextColor3 = Colors.TextSubtle; btn.TextSize = 12; btn.TextXAlignment = Enum.TextXAlignment.Left; btn.BorderSizePixel = 0; btn.Parent = navList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 12); p.Parent = btn end
    local pill = Instance.new("Frame"); pill.Name = "ActivePill"; pill.Size = UDim2.new(0, 3, 0, 16); pill.Position = UDim2.new(0, -9, 0.5, -8); pill.BackgroundColor3 = Colors.PurpleAccent; pill.BorderSizePixel = 0; pill.Visible = false; pill.Parent = btn
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 2)
    btn.MouseButton1Click:Connect(function() SwitchTab(name) end)

    local page = Instance.new("ScrollingFrame"); page.Name = "TabPage_" .. name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1; page.BorderSizePixel = 0; page.ScrollBarThickness = 3; page.ScrollBarImageColor3 = Colors.BorderPurple; page.CanvasSize = UDim2.new(0, 0, 0, 0); page.AutomaticCanvasSize = Enum.AutomaticSize.Y; page.Visible = false; page.Parent = contentArea
    do
        local pl = Instance.new("UIListLayout"); pl.SortOrder = Enum.SortOrder.LayoutOrder; pl.Padding = UDim.new(0, 10); pl.Parent = page
        local pp = Instance.new("UIPadding"); pp.PaddingTop = UDim.new(0, 12); pp.PaddingBottom = UDim.new(0, 16); pp.PaddingLeft = UDim.new(0, 14); pp.PaddingRight = UDim.new(0, 14); pp.Parent = page
    end
    tabFrames[name] = page; tabButtons[name] = btn
    return page
end

local footerBar = Instance.new("Frame"); footerBar.Name = "FooterBar"; footerBar.Size = UDim2.new(1, 0, 0, 24); footerBar.Position = UDim2.new(0, 0, 1, -24); footerBar.BackgroundColor3 = Colors.SidebarBg; footerBar.BorderSizePixel = 0; footerBar.Parent = mainFrame
Instance.new("UICorner", footerBar).CornerRadius = UDim.new(0, 8)
do
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, 0, 0, 10); tf.BackgroundColor3 = Colors.SidebarBg; tf.BorderSizePixel = 0; tf.Parent = footerBar
    local fd = Instance.new("Frame"); fd.Size = UDim2.new(1, 0, 0, 1); fd.BackgroundColor3 = Colors.Divider; fd.BorderSizePixel = 0; fd.Parent = footerBar
end
local footerBrand = Instance.new("TextLabel"); footerBrand.Size = UDim2.new(0, 260, 1, 0); footerBrand.Position = UDim2.new(0, 12, 0, 0); footerBrand.BackgroundTransparency = 1; footerBrand.Font = Enum.Font.Gotham; footerBrand.Text = "Heavyweight Fishing | V1.0"; footerBrand.TextColor3 = Colors.TextMuted; footerBrand.TextSize = 10; footerBrand.TextXAlignment = Enum.TextXAlignment.Left; footerBrand.Parent = footerBar
local footerKey = Instance.new("TextLabel"); footerKey.Size = UDim2.new(0, 280, 1, 0); footerKey.Position = UDim2.new(1, -292, 0, 0); footerKey.BackgroundTransparency = 1; footerKey.Font = Enum.Font.Gotham; footerKey.Text = "[R-CTRL] 菜单 | [END] 停止"; footerKey.TextColor3 = Colors.TextMuted; footerKey.TextSize = 10; footerKey.TextXAlignment = Enum.TextXAlignment.Right; footerKey.Parent = footerBar

ToggleUiVisibility = function()
    mainFrame.Visible = not mainFrame.Visible
    floatingCrescent.Visible = not mainFrame.Visible
end

minBtn.MouseButton1Click:Connect(ToggleUiVisibility)
closeBtn.MouseButton1Click:Connect(UnloadScript)

local function createCategoryHeader(parent, text)
    local hdr = Instance.new("Frame"); hdr.Size = UDim2.new(1, 0, 0, 22); hdr.BackgroundTransparency = 1; hdr.Parent = parent
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, 0, 1, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamBold; lbl.Text = string.upper(text); lbl.TextColor3 = Colors.PurplePrimary; lbl.TextSize = 11; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hdr
    return hdr
end

local function createCardGroup(parent)
    local group = Instance.new("Frame"); group.Size = UDim2.new(1, 0, 0, 0); group.AutomaticSize = Enum.AutomaticSize.Y; group.BackgroundColor3 = Colors.RowNormal; group.BorderSizePixel = 0; group.Parent = parent
    local s = Instance.new("UIStroke"); s.Color = Colors.BorderSubtle; s.Thickness = 1; s.Parent = group
    Instance.new("UICorner", group).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 0); l.Parent = group
    return group
end

local function createBaseRow(parent, labelText, descText, indexSearch)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.Parent = parent
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -190, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = row
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 18); tl.Position = UDim2.new(0, 0, 0, 4); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 12; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 14); dl.Position = UDim2.new(0, 0, 0, 22); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 10; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.Parent = tf
    row.MouseEnter:Connect(function() TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover}):Play() end)
    row.MouseLeave:Connect(function() TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowNormal}):Play() end)
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
    local row = createBaseRow(parent, labelText, descText, indexSearch)
    local state = initialVal or false
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 40, 0, 20); btn.Position = UDim2.new(1, -40, 0.5, -10); btn.BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg; btn.Text = ""; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame"); knob.Size = UDim2.new(0, 14, 0, 14); knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7); knob.BackgroundColor3 = Colors.TextWhite; knob.BorderSizePixel = 0; knob.Parent = btn
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local function updateVisuals()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg}):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), {Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)}):Play()
    end
    btn.MouseButton1Click:Connect(function()
        state = not state
        updateVisuals()
        if type(callback) == "function" then callback(state) end
    end)
    return {frame = row, Set = function(val) state = val; updateVisuals() end, Get = function() return state end}
end

local function createSliderRow(parent, labelText, descText, minVal, maxVal, initialVal, isFloat, suffix, callback, indexSearch)
    local row = createBaseRow(parent, labelText, descText, indexSearch)
    local currentVal = initialVal or minVal; suffix = suffix or ""
    local container = Instance.new("Frame"); container.Size = UDim2.new(0, 180, 0, 24); container.Position = UDim2.new(1, -180, 0.5, -12); container.BackgroundTransparency = 1; container.Parent = row
    local valLabel = Instance.new("TextLabel"); valLabel.Size = UDim2.new(0, 68, 1, 0); valLabel.Position = UDim2.new(1, -68, 0, 0); valLabel.BackgroundTransparency = 1; valLabel.Font = Enum.Font.GothamBold; valLabel.TextColor3 = Colors.PurplePrimary; valLabel.TextSize = 11; valLabel.TextXAlignment = Enum.TextXAlignment.Right; valLabel.Parent = container
    valLabel.Text = isFloat and string.format("%.2f", currentVal)..suffix or tostring(math.floor(currentVal))..suffix
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, -74, 0, 6); track.Position = UDim2.new(0, 0, 0.5, -3); track.BackgroundColor3 = Colors.ControlBg; track.BorderSizePixel = 0; track.Parent = container
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local pct = math.clamp((currentVal - minVal) / (maxVal - minVal), 0, 1)
    local fill = Instance.new("Frame"); fill.Size = UDim2.new(pct, 0, 1, 0); fill.BackgroundColor3 = Colors.PurpleAccent; fill.BorderSizePixel = 0; fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
    local sliding = false
    local function updateFromX(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local val = minVal + (maxVal - minVal) * rel
        if not isFloat then val = math.floor(val + 0.5) end
        currentVal = val; fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val)..suffix or tostring(val)..suffix
        if type(callback) == "function" then callback(val) end
    end
    track.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 then sliding = true; updateFromX(input.Position.X) end end)
    UserInputService.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 then sliding = false end end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input) if sliding and input.UserInputType == Enum.UserInputType.MouseMovement then updateFromX(input.Position.X) end end))
    return {
        frame = row,
        Set = function(val)
            currentVal = math.clamp(val, minVal, maxVal)
            local p2 = (currentVal - minVal) / (maxVal - minVal)
            fill.Size = UDim2.new(p2, 0, 1, 0)
            valLabel.Text = isFloat and string.format("%.2f", currentVal)..suffix or tostring(math.floor(currentVal))..suffix
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
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = true; row.Parent = parent
    local rl = Instance.new("UIListLayout"); rl.SortOrder = Enum.SortOrder.LayoutOrder; rl.Padding = UDim.new(0, 4); rl.Parent = row
    local header = Instance.new("Frame"); header.Size = UDim2.new(1, 0, 0, 42); header.BackgroundTransparency = 1; header.Parent = row
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = header
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -145, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = header
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 18); tl.Position = UDim2.new(0, 0, 0, 4); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 12; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 14); dl.Position = UDim2.new(0, 0, 0, 22); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 10; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.Parent = tf
    local ddBtn = Instance.new("TextButton"); ddBtn.Size = UDim2.new(0, 130, 0, 24); ddBtn.Position = UDim2.new(1, -130, 0.5, -12); ddBtn.BackgroundColor3 = Colors.ControlBg; ddBtn.Font = Enum.Font.GothamBold; ddBtn.Text = tostring(selected) .. "  v"; ddBtn.TextColor3 = Colors.PurplePrimary; ddBtn.TextSize = 11; ddBtn.BorderSizePixel = 0; ddBtn.Parent = header
    Instance.new("UICorner", ddBtn).CornerRadius = UDim.new(0, 4)
    local optC = Instance.new("Frame"); optC.Size = UDim2.new(1, 0, 0, 0); optC.AutomaticSize = Enum.AutomaticSize.Y; optC.BackgroundTransparency = 1; optC.Visible = false; optC.Parent = row
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 10); p.PaddingRight = UDim.new(0, 10); p.PaddingBottom = UDim.new(0, 8); p.Parent = optC end
    Instance.new("UIListLayout", optC).SortOrder = Enum.SortOrder.LayoutOrder
    local optButtons = {}
    local function populate(opts)
        for _, c in ipairs(optC:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
        table.clear(optButtons)
        for _, opt in ipairs(opts) do
            local ob = Instance.new("TextButton"); ob.Size = UDim2.new(1, 0, 0, 26); ob.BackgroundColor3 = (opt == selected) and Colors.DropdownSelected or Colors.InputBg; ob.Font = Enum.Font.Gotham; ob.Text = (opt == selected and "> " or "   ") .. tostring(opt); ob.TextColor3 = (opt == selected) and Colors.PurplePrimary or Colors.TextWhite; ob.TextSize = 11; ob.TextXAlignment = Enum.TextXAlignment.Left; ob.BorderSizePixel = 0; ob.Parent = optC
            Instance.new("UICorner", ob).CornerRadius = UDim.new(0, 4)
            do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 10); p.Parent = ob end
            optButtons[opt] = ob
            ob.MouseEnter:Connect(function() if opt ~= selected then TweenService:Create(ob, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover}):Play() end end)
            ob.MouseLeave:Connect(function() if opt ~= selected then TweenService:Create(ob, TweenInfo.new(0.15), {BackgroundColor3 = Colors.InputBg}):Play() end end)
            ob.MouseButton1Click:Connect(function()
                selected = opt; ddBtn.Text = tostring(opt) .. "  v"; optC.Visible = false
                for oN, b in pairs(optButtons) do b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg; b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite; b.Text = (oN == opt and "> " or "   ") .. tostring(oN) end
                if type(callback) == "function" then callback(opt) end
            end)
        end
    end
    populate(options)
    ddBtn.MouseButton1Click:Connect(function() optC.Visible = not optC.Visible; ddBtn.Text = tostring(selected) .. (optC.Visible and "  ^" or "  v") end)
    header.MouseEnter:Connect(function() TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover}):Play() end)
    header.MouseLeave:Connect(function() TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowNormal}):Play() end)
    if indexSearch ~= false then table.insert(rowSearchIndex, {frame = row, query = (labelText .. " " .. (descText or "")):lower()}) end
    return {
        frame = row,
        Set = function(opt)
            selected = opt; ddBtn.Text = tostring(opt) .. "  v"
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
    local row = createBaseRow(parent, labelText, descText, indexSearch)
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = btnText or "执行"; btn.TextColor3 = Colors.PurplePrimary; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    btn.MouseEnter:Connect(function() TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite}):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg, TextColor3 = Colors.PurplePrimary}):Play() end)
    btn.MouseButton1Click:Connect(function()
        if type(callback) == "function" then pcall(callback) end
    end)
    return btn
end

local function createInfoRow(parent, labelText, valueText, indexSearch)
    local row = createBaseRow(parent, labelText, "", indexSearch)
    local vl = Instance.new("TextLabel"); vl.Size = UDim2.new(0, 140, 1, 0); vl.Position = UDim2.new(1, -140, 0, 0); vl.BackgroundTransparency = 1; vl.Font = Enum.Font.GothamBold; vl.Text = valueText; vl.TextColor3 = Colors.PurplePrimary; vl.TextSize = 11; vl.TextXAlignment = Enum.TextXAlignment.Right; vl.Parent = row
    return {frame = row, Set = function(nv) vl.Text = nv end}
end

local tabFishing   = CreateTab("钓鱼")
local tabBoss      = CreateTab("Boss")
local tabGod       = CreateTab("神灵")
local tabQuests    = CreateTab("任务")
local tabShop      = CreateTab("商店与制作")
local tabTeleports = CreateTab("传送")
local tabVisuals   = CreateTab("视觉")
local tabPlayer    = CreateTab("移动")
local tabProfiles  = CreateTab("配置文件")

SwitchTab("钓鱼")

local allRods = {
    {name = "Wooden Rod", price = 0, power = 8, luck = 1}, -- 木制鱼竿
    {name = "Bamboo Rod", price = 100, power = 11, luck = 5}, -- 竹制鱼竿
    {name = "Iron Hook Rod", price = 500, power = 13, luck = 10}, -- 铁钩鱼竿
    {name = "Steel Rod", price = 1000, power = 17, luck = 11}, -- 钢制鱼竿
    {name = "Enchanted Steel Rod", price = 2000, power = 19, luck = 12}, -- 附魔钢制鱼竿
    {name = "Alloy Rod", price = 5000, power = 22, luck = 5}, -- 合金鱼竿
    {name = "Emerald Rod", price = 10000, power = 25, luck = 10}, -- 翡翠鱼竿
    {name = "Bloodfire Rod", price = 20000, power = 27, luck = 10}, -- 血火鱼竿
    {name = "Shadow Rod", price = 60000, power = 29, luck = 22}, -- 暗影鱼竿
    {name = "Triple Steel Rod", price = 100000, power = 32, luck = 20}, -- 三重钢制鱼竿
    {name = "Golden Rod", price = 200000, power = 35, luck = 22}, -- 黄金鱼竿
    {name = "Grandmaster Steel Rod", price = 250000, power = 37, luck = 10}, -- 大师钢制鱼竿
    {name = "Grandmaster Golden Rod", price = 1000000, power = 45, luck = 30}, -- 大师黄金鱼竿
    {name = "Steel Spine Rod", price = 1500000, power = 48, luck = 20}, -- 钢脊鱼竿
    {name = "Inferno Rod", price = 1500000, power = 48, luck = 18}, -- 炼狱鱼竿
    {name = "Golden Spine Rod", price = 2000000, power = 51, luck = 21}, -- 金脊鱼竿
    {name = "Platinum Spine Rod", price = 3000000, power = 54, luck = 25}, -- 铂金脊鱼竿
    {name = "Diamond Spine Rod", price = 4000000, power = 56, luck = 25}, -- 钻石脊鱼竿
    {name = "Gravisteel Rod", price = 5000000, power = 58, luck = 15}, -- 重力钢鱼竿
    {name = "Auric Gravity Rod", price = 6000000, power = 60, luck = 10}, -- 金色重力鱼竿
    {name = "Inferno Gravity Rod", price = 7000000, power = 62, luck = 20}, -- 炼狱重力鱼竿
    {name = "Cryo Gravity Rod", price = 8000000, power = 65, luck = 36}, -- 冰晶重力鱼竿
    {name = "Thunder Thorn Rod", price = 10000000, power = 67, luck = 30}, -- 雷棘鱼竿
    {name = "Starlight Rod", price = 60000000, power = 83, luck = 15}, -- 星光鱼竿
}

createCategoryHeader(tabFishing, "实时账户与钓鱼统计")
local statsCard = createCardGroup(tabFishing)
local infoEquippedRod = createInfoRow(statsCard, "已装备鱼竿", "无")
local infoEquippedBait = createInfoRow(statsCard, "已装备鱼饵", "无")
local infoFishCaught = createInfoRow(statsCard, "总捕获鱼数", "0")
local infoCash = createInfoRow(statsCard, "当前现金", "$0")

createCategoryHeader(tabFishing, "核心钓鱼自动化")
local fishCard = createCardGroup(tabFishing)

createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿", Config.AutoCast, function(v) Config.AutoCast = v end)
createSliderRow(fishCard, "抛竿延迟", "检测/抛竿频率", 0.5, 5.0, Config.CastDelay, true, "秒", function(v) Config.CastDelay = v end)
createToggleRow(fishCard, "锚定条(小游戏)", "自动居中条并保证捕获进度", Config.AnchorBar, function(v) Config.AnchorBar = v end)
createToggleRow(fishCard, "自动技能(爆发DPS)", "收线时使用鱼竿和小游戏技能", Config.AutoSkills, function(v) Config.AutoSkills = v end)
createToggleRow(fishCard, "自动猛击/暴击", "提示时自动点击猛击按钮造成巨大伤害", Config.AutoSlam, function(v) Config.AutoSlam = v end)
createToggleRow(fishCard, "自动充能耐久", "提示时自动充能鱼线耐久", Config.AutoCharge, function(v) Config.AutoCharge = v end)

createCategoryHeader(tabFishing, "智能自动装备引擎")
local equipCard = createCardGroup(tabFishing)
createToggleRow(equipCard, "自动装备最佳鱼饵", "装备背包中运气最高的鱼饵", Config.AutoEquipBestBait, function(v) Config.AutoEquipBestBait = v end)
createToggleRow(equipCard, "自动装备最佳鱼竿", "装备你拥有的最高威力鱼竿", Config.AutoEquipBestRod, function(v) Config.AutoEquipBestRod = v end)
createToggleRow(equipCard, "自动装备最佳宝珠", "装备最高等级精华宝珠", Config.AutoEquipBestOrb, function(v) Config.AutoEquipBestOrb = v end)

local rodNameList = {}
for _, r in ipairs(allRods) do table.insert(rodNameList, r.name) end
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait"} -- 基础鱼饵, 粗制鱼饵, 腐化精华鱼饵, 精英鱼饵, 先祖鱼饵, 无名鱼饵

createDropdownRow(equipCard, "方案1：鱼竿", "方案1的鱼竿", rodNameList, Config.Loadout1_Rod, function(v) Config.Loadout1_Rod = v end)
createDropdownRow(equipCard, "方案1：鱼饵", "方案1的鱼饵", baitNameList, Config.Loadout1_Bait, function(v) Config.Loadout1_Bait = v end)
createButtonRow(equipCard, "立即装备方案1", "装备方案1选择的鱼竿和鱼饵", "装备#1", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData then
        local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout1_Rod)
        local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
        if isOwned then
            if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout1_Rod) end
            ShowNotification("方案1", "已装备鱼竿: " .. Config.Loadout1_Rod, "SUCCESS")
        else
            ShowNotification("方案1", "你还没有拥有 " .. Config.Loadout1_Rod .. " ！", "WARN")
        end
        local bFolder = pData.Bait:FindFirstChild(Config.Loadout1_Bait)
        if bFolder and bFolder.Value > 0 then
            if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout1_Bait) end
            ShowNotification("方案1", "已装备鱼饵: " .. Config.Loadout1_Bait, "SUCCESS")
        else
            ShowNotification("方案1", "你的背包中 " .. Config.Loadout1_Bait .. " 数量为0。", "WARN")
        end
    end
end)

createDropdownRow(equipCard, "方案2：鱼竿", "方案2的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end)
createDropdownRow(equipCard, "方案2：鱼饵", "方案2的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end)
createButtonRow(equipCard, "立即装备方案2", "装备方案2选择的鱼竿和鱼饵", "装备#2", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData then
        local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout2_Rod)
        local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
        if isOwned then
            if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout2_Rod) end
            ShowNotification("方案2", "已装备鱼竿: " .. Config.Loadout2_Rod, "SUCCESS")
        else
            ShowNotification("方案2", "你还没有拥有 " .. Config.Loadout2_Rod .. " ！", "WARN")
        end
        local bFolder = pData.Bait:FindFirstChild(Config.Loadout2_Bait)
        if bFolder and bFolder.Value > 0 then
            if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout2_Bait) end
            ShowNotification("方案2", "已装备鱼饵: " .. Config.Loadout2_Bait, "SUCCESS")
        else
            ShowNotification("方案2", "你的背包中 " .. Config.Loadout2_Bait .. " 数量为0。", "WARN")
        end
    end
end)

createCategoryHeader(tabFishing, "经济与出售")
local sellCard = createCardGroup(tabFishing)
createToggleRow(sellCard, "自动卖鱼", "定期出售背包中的所有鱼", Config.AutoSell, function(v) Config.AutoSell = v end)
createSliderRow(sellCard, "出售间隔", "出售鱼的频率", 10, 300, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end)

createButtonRow(sellCard, "立即出售并传送到娜娜", "立即传送到娜娜处并出售背包", "立即出售", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-203.5, 7.3, 107.1)
        task.wait(0.3)
        if Events and Events:FindFirstChild("SellFish") then
            Events.SellFish:FireServer("All")
            ShowNotification("鱼已出售", "已将所有鱼卖给娜娜！", "SUCCESS")
        end
    end
end)

local fishList = {"Colossal Tigerfish", "Heavenpiercer Turtle", "Golden Guardian Fish", "Crimson Electric Eel", "Frost Kingfish", "Ascended Perch", "Primordial Kunfish Overlord", "Warbringer Shark", "Mountain Fish", "Tiger Mirefish", "Mirage Lanternfish", "Octoparasitic Fish"} -- 巨型虎鱼, 穿天龟, 黄金守护鱼, 深红电鳗, 冰霜王鱼, 升华鲈鱼, 原始鲲鱼霸主, 战神鲨鱼, 山鱼, 虎纹沼泽鱼, 幻影灯鱼, 章鱼寄生鱼
createToggleRow(sellCard, "自动收藏鱼", "保护选中的鱼不被出售", Config.AutoFavouriteFish, function(v) Config.AutoFavouriteFish = v end)
createDropdownRow(sellCard, "收藏目标", "要保护的鱼类型", fishList, Config.FavouriteFishName, function(v) Config.FavouriteFishName = v end)
createToggleRow(sellCard, "材料收集模式", "阻止自动出售制作材料鱼", Config.MaterialFarming, function(v) Config.MaterialFarming = v end)

createCategoryHeader(tabBoss, "无名章鱼寄生体(隐藏Boss)")
local octoCard = createCardGroup(tabBoss)

createToggleRow(octoCard, "自动小游戏(节奏机器人)", "100%完美节奏点击时机机器人", Config.OctoAutoMinigame, function(v) Config.OctoAutoMinigame = v end)
createButtonRow(octoCard, "传送到章鱼寄生体", "传送到海洋隐藏Boss浮标", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(1608.2, 5.0, -218.3)
        ShowNotification("已传送", "已到达无名章鱼寄生体海洋浮标！", "SUCCESS")
    end
end)
createButtonRow(octoCard, "传送到渔夫之地", "传送到地下渔夫领域", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(112.5, -330.0, -30.8)
        ShowNotification("已传送", "已到达地下渔夫之地！", "SUCCESS")
    end
end)

createCategoryHeader(tabBoss, "Boss自动化")
local bossFarmCard = createCardGroup(tabBoss)
createToggleRow(bossFarmCard, "自动刷Boss(Enzo)", "持续召唤并击败Enzo", Config.AutoFarmBoss, function(v) Config.AutoFarmBoss = v end)
createToggleRow(bossFarmCard, "自动刷隐藏Boss", "自动制作无名鱼饵，召唤并击杀", Config.AutoFarmSecretBoss, function(v) Config.AutoFarmSecretBoss = v end)

createButtonRow(bossFarmCard, "传送到Enzo", "传送到Enzo竞技场", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-115.3, 9.2, 1349.5)
        ShowNotification("已传送", "已到达Enzo！", "SUCCESS")
    end
end)

createCategoryHeader(tabGod, "神灵交互与状态")
local godCard = createCardGroup(tabGod)

createButtonRow(godCard, "检查神灵状态", "检查活跃祝福(黄/蓝/绿)", "检查状态", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData and pData:FindFirstChild("GodSpirit") then
        local y = pData.GodSpirit:FindFirstChild("Yellow") and pData.GodSpirit.Yellow.Value or false
        local b = pData.GodSpirit:FindFirstChild("Blue") and pData.GodSpirit.Blue.Value or false
        local g = pData.GodSpirit:FindFirstChild("Green") and pData.GodSpirit.Green.Value or false
        local msg = string.format("黄色: %s | 蓝色: %s | 绿色: %s", y and "活跃" or "关闭", b and "活跃" or "关闭", g and "活跃" or "关闭")
        ShowNotification("神灵状态", msg, "SUCCESS", 6)
    else
        ShowNotification("神灵", "无法读取神灵数据。", "WARN")
    end
end)

createToggleRow(godCard, "自动祈祷神灵", "在神灵祭坛时自动祈祷", Config.AutoPrayGodSpirit, function(v) Config.AutoPrayGodSpirit = v end)

createButtonRow(godCard, "传送到神灵祭坛", "传送到神灵祭坛(战场岛)", "传送", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local spirit = (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("Spirit")) or (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("God"))
        if spirit then
            root.CFrame = spirit:GetPivot() + Vector3.new(0, 3, 5)
            ShowNotification("神灵", "已传送到神灵祭坛！", "SUCCESS")
        else
            root.CFrame = CFrame.new(1245.7, 19.3, -133.4)
            ShowNotification("神灵", "已传送到神社位置！", "SUCCESS")
        end
    end
end)

local function TriggerPrompt(prompt)
    if fireproximityprompt then
        fireproximityprompt(prompt)
    else
        pcall(function()
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration + 0.05)
            prompt:InputHoldEnd()
        end)
    end
end

createButtonRow(godCard, "立即祈祷神灵", "与神灵祭坛提示交互", "祈祷", function()
    local sp = (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("Spirit")) or (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("God"))
    if sp then
        local found = false
        for _, d in ipairs(sp:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                TriggerPrompt(d)
                found = true
            end
        end
        if found then
            ShowNotification("神灵", "已在祭坛祈祷神灵！", "SUCCESS")
        else
            ShowNotification("神灵", "在神灵上未找到近距离提示。", "WARN")
        end
    else
        ShowNotification("神灵", "此服务器中神灵未生成。", "WARN")
    end
end)

createCategoryHeader(tabGod, "服务器跳转引擎")
local hopCard = createCardGroup(tabGod)
createToggleRow(hopCard, "为神灵跳服务器", "跳转服务器直到找到神灵", Config.AutoServerHopGod, function(v) Config.AutoServerHopGod = v end)
createToggleRow(hopCard, "为茅山跳服务器", "跳转服务器直到找到茅山", Config.AutoServerHopMaoshan, function(v) Config.AutoServerHopMaoshan = v end)
createToggleRow(hopCard, "为道士跳服务器", "跳转服务器直到找到道士", Config.AutoServerHopTaoist, function(v) Config.AutoServerHopTaoist = v end)

local function ServerHop()
    ShowNotification("服务器跳转", "正在搜索最佳服务器...", "WARN")
    pcall(function()
        local placeId = game.PlaceId
        local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Desc&limit=100"
        local res = game:HttpGet(url)
        local body = HttpService:JSONDecode(res)
        if body and body.data then
            for _, s in ipairs(body.data) do
                if s.playing < s.maxPlayers and s.id ~= game.JobId then
                    TeleportService:TeleportToPlaceInstance(placeId, s.id, LocalPlayer)
                    return
                end
            end
        end
    end)
end
createButtonRow(hopCard, "立即跳服务器", "立即跳转到随机不同服务器", "跳转", ServerHop)

createCategoryHeader(tabQuests, "票据任务")
local questCard = createCardGroup(tabQuests)

createToggleRow(questCard, "自动票据任务", "自动接受并提交票据任务", Config.AutoTicketQuest, function(v) Config.AutoTicketQuest = v end)
createDropdownRow(questCard, "难度", "票据任务难度", {"简单", "困难"}, Config.TicketDifficulty, function(v) Config.TicketDifficulty = v end)

createButtonRow(questCard, "手动提交(简单)", "立即提交简单任务", "提交简单", function()
    if Events and Events:FindFirstChild("ClaimQuest") then
        Events.ClaimQuest:FireServer("Ticket", "Easy")
        ShowNotification("任务", "已提交简单票据任务！", "SUCCESS")
    end
end)

createButtonRow(questCard, "手动提交(困难)", "立即提交困难任务", "提交困难", function()
    if Events and Events:FindFirstChild("ClaimQuest") then
        Events.ClaimQuest:FireServer("Ticket", "Hard")
        ShowNotification("任务", "已提交困难票据任务！", "SUCCESS")
    end
end)

createCategoryHeader(tabQuests, "每日任务与奖励")
local dailyCard = createCardGroup(tabQuests)
createButtonRow(dailyCard, "领取每日任务", "检测完成的每日任务并领取", "领取", function()
    if Events and Events:FindFirstChild("ClaimQuest") then
        for i = 1, 4 do Events.ClaimQuest:FireServer("Daily", i) end
        ShowNotification("每日任务", "已领取所有可用的每日任务！", "SUCCESS")
    end
end)

createToggleRow(dailyCard, "自动领取每日奖励", "按顺序领取1到7天的每日奖励", Config.AutoClaimDaily, function(v) Config.AutoClaimDaily = v end)
createSliderRow(dailyCard, "领取延迟", "领取天数之间的延迟", 0.2, 2.0, Config.DailyClaimDelay, true, "秒", function(v) Config.DailyClaimDelay = v end)

createButtonRow(dailyCard, "立即领取第1到7天", "批量领取所有7天每日奖励", "领取全部", function()
    task.spawn(function()
        if Events and Events:FindFirstChild("DailyReward") then
            for day = 1, 7 do
                Events.DailyReward:FireServer(day)
                task.wait(Config.DailyClaimDelay)
            end
            ShowNotification("每日奖励", "已成功领取第1到7天！", "SUCCESS")
        end
    end)
end)

createButtonRow(dailyCard, "兑换所有代码", "兑换所有已知的有效促销代码", "兑换", function()
    local codes = {"33MVisits", "32MVisits", "31MVisits", "30MVisits", "Taiji", "49KLikes", "48KLikes", "47KLikes", "46KLikes", "13KActives", "HWF", "RELEASE"}
    if Events and Events:FindFirstChild("RedeemCode") then
        for _, c in ipairs(codes) do
            Events.RedeemCode:FireServer(c)
            task.wait(0.2)
        end
        ShowNotification("代码", "已兑换所有有效代码！", "SUCCESS")
    end
end)

createCategoryHeader(tabShop, "鱼饵制作与购买")
local baitCard = createCardGroup(tabShop)

local craftBaits = {"Nameless Bait", "Frost Bait", "Rainbow Bait"} -- 无名鱼饵, 冰霜鱼饵, 彩虹鱼饵
createDropdownRow(baitCard, "制作目标", "要制作的神话Boss鱼饵", craftBaits, Config.CraftBaitName, function(v) Config.CraftBaitName = v end)
createSliderRow(baitCard, "制作数量", "每批制作数量", 1, 10, Config.CraftAmount, false, "", function(v) Config.CraftAmount = v end)
createToggleRow(baitCard, "自动制作鱼饵", "材料存在时持续制作", Config.AutoCraftBait, function(v) Config.AutoCraftBait = v end)

local buyBaits = {"Ancestral Bait", "Elite Bait", "Corrupted Essence Bait", "Crude Mash Bait", "Basic Bait"} -- 先祖鱼饵, 精英鱼饵, 腐化精华鱼饵, 粗制鱼饵, 基础鱼饵
createDropdownRow(baitCard, "购买目标", "从八长购买的鱼饵", buyBaits, Config.BuyBaitName, function(v) Config.BuyBaitName = v end)
createSliderRow(baitCard, "购买数量", "每次购买的数量", 1, 50, Config.BuyBaitAmount, false, "", function(v) Config.BuyBaitAmount = v end)
createSliderRow(baitCard, "库存阈值", "库存低于此值时购买", 5, 50, Config.BuyBaitThreshold, false, "", function(v) Config.BuyBaitThreshold = v end)
createToggleRow(baitCard, "自动购买鱼饵", "库存低时自动补货鱼饵", Config.AutoBuyBait, function(v) Config.AutoBuyBait = v end)

createCategoryHeader(tabShop, "逸久贤者(技能商人)")
local sageCard = createCardGroup(tabShop)
local sageSkills = {"One-Strike Heaven Gate", "Taijiquan Technique", "Infinite Sky Ascension", "Rolling Chaos", "Sever the Gate", "Phoenix Strike Art", "Skyfall Stomp", "Beastbreaker Cleave", "Demonfall Technique", "Dragon Strike"} -- 一击天门, 太极拳法, 无限升天, 翻滚混沌, 断门, 凤凰击艺, 天坠践踏, 破兽斩, 魔坠术, 龙击
local chosenSageSkill = sageSkills[1]
createDropdownRow(sageCard, "选择技能", "从逸久贤者处学习的技能", sageSkills, chosenSageSkill, function(v) chosenSageSkill = v end)

createButtonRow(sageCard, "购买技能并传送", "传送到逸久贤者处并购买技能", "购买技能", function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = CFrame.new(-117.5, 6.8, 41.2)
        task.wait(0.3)
        if Events and Events:FindFirstChild("BuySkill") then
            Events.BuySkill:FireServer(chosenSageSkill)
            ShowNotification("逸久贤者", "已购买 " .. chosenSageSkill .. "！", "SUCCESS")
        end
    end
end)

createCategoryHeader(tabShop, "自动扭蛋")
local gachaCard = createCardGroup(tabShop)
createDropdownRow(gachaCard, "扭蛋卡池", "当前召唤卡池", {"太极卡池", "无我卡池"}, Config.GachaBanner, function(v) Config.GachaBanner = v end)
createSliderRow(gachaCard, "每次扭蛋票数", "每次扭蛋动作的票数", 1, 10, Config.GachaPullsPerAction, false, "", function(v) Config.GachaPullsPerAction = v end)
createToggleRow(gachaCard, "自动扭蛋", "自动从选中的卡池抽取", Config.AutoGacha, function(v) Config.AutoGacha = v end)

createCategoryHeader(tabShop, "鱼竿商人目录(按价格排序)")
local rodShopCard = createCardGroup(tabShop)

local function formatNumber(n)
    if n == 0 then return "免费" end
    local formatted = tostring(n)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted .. " 现金"
end

for _, rod in ipairs(allRods) do
    local pStr = formatNumber(rod.price)
    local desc = string.format("威力: %d | 运气: %d%% | %s", rod.power, rod.luck, pStr)
    createButtonRow(rodShopCard, rod.name, desc, "购买", function()
        if Events and Events:FindFirstChild("BuyFishingRod") then
            Events.BuyFishingRod:FireServer(rod.name)
            ShowNotification("鱼竿商人", "尝试购买 " .. rod.name, "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "岛屿进度(1-10)")
local islandCard = createCardGroup(tabTeleports)

local islands = {
    {name = "[1] 起始岛(出生点)", pos = Vector3.new(-200.7, 11.1, 35.9)},
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

createCategoryHeader(tabTeleports, "Boss竞技场与隐藏领域")
local bossRealmCard = createCardGroup(tabTeleports)

local bossRealms = {
    {name = "章鱼寄生体(海洋Boss浮标)", pos = Vector3.new(1608.2, 5.0, -218.3)},
    {name = "渔夫之地(地下领域)", pos = Vector3.new(112.5, -330.0, -30.8)},
    {name = "Enzo Boss竞技场", pos = Vector3.new(-115.3, 9.2, 1349.5)},
}

for _, br in ipairs(bossRealms) do
    createButtonRow(bossRealmCard, br.name, "传送到 " .. br.name, "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(br.pos + Vector3.new(0, 3, 0))
            ShowNotification("传送", "已到达 " .. br.name .. "！", "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "鱼竿商人商店(标迪)")
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
    createButtonRow(rodDealerCard, rd.name, "直接传送到鱼竿商人", "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(rd.pos + Vector3.new(0, 3, 0))
            ShowNotification("鱼竿商人", "已到达 " .. rd.name .. "！", "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "秘密鱼竿位置")
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
    createButtonRow(sRodCard, sr.name, "传送到秘密鱼竿位置", "传送", function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(sr.pos + Vector3.new(0, 3, 0))
            ShowNotification("秘密鱼竿", "已传送到 " .. sr.name .. "！", "SUCCESS")
        end
    end)
end

createCategoryHeader(tabTeleports, "服务器与玩家传送")
local srvCard = createCardGroup(tabTeleports)

local lastTpTarget = nil
createButtonRow(srvCard, "传送到随机玩家", "直接传送到另一个玩家", "传送", function()
    local targets = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            table.insert(targets, p)
        end
    end
    if #targets == 0 then
        ShowNotification("玩家传送", "未找到其他玩家。", "WARN")
        return
    end
    local pool = {}
    for _, p in ipairs(targets) do
        if not (#targets > 1 and p == lastTpTarget) then
            table.insert(pool, p)
        end
    end
    local selected = (#pool > 0 and pool[math.random(1, #pool)]) or targets[math.random(1, #targets)]
    lastTpTarget = selected
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root and selected.Character and selected.Character:FindFirstChild("HumanoidRootPart") then
        root.CFrame = selected.Character.HumanoidRootPart.CFrame + Vector3.new(0, 2, 3)
        ShowNotification("玩家传送", "已传送到 " .. selected.DisplayName, "SUCCESS")
    end
end)

createCategoryHeader(tabVisuals, "世界与实体ESP")
local espCard = createCardGroup(tabVisuals)

createToggleRow(espCard, "神灵ESP", "高亮活跃的神灵", Config.ESP_GodSpirit, function(v) Config.ESP_GodSpirit = v end)
createToggleRow(espCard, "秘密鱼竿ESP", "高亮所有秘密鱼竿位置", Config.ESP_SecretRod, function(v) Config.ESP_SecretRod = v end)
createToggleRow(espCard, "船只ESP", "高亮生成的船只", Config.ESP_Boats, function(v) Config.ESP_Boats = v end)
createToggleRow(espCard, "茅山ESP", "高亮茅山NPC/鱼竿", Config.ESP_Maoshan, function(v) Config.ESP_Maoshan = v end)
createToggleRow(espCard, "道士ESP", "高亮道士NPC/鱼竿", Config.ESP_Taoist, function(v) Config.ESP_Taoist = v end)
createToggleRow(espCard, "Boss ESP", "高亮活跃的Boss生成点", Config.ESP_Boss, function(v) Config.ESP_Boss = v end)
createToggleRow(espCard, "玩家ESP", "高亮其他玩家及距离", Config.ESP_Players, function(v) Config.ESP_Players = v end)
createToggleRow(espCard, "鱼目标光圈", "收线时在钩住的鱼周围显示发光红色光圈", Config.FishRedRing, function(v) Config.FishRedRing = v end)

createCategoryHeader(tabVisuals, "光照与性能")
local perfCard = createCardGroup(tabVisuals)

createToggleRow(perfCard, "无雾无雨", "清除世界雾霾、雨粒子及闪电", Config.NoFog, function(v)
    Config.NoFog = v
    if v then
        Lighting.FogEnd = 1000000
        Lighting.FogStart = 1000000
        local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
        if atmo then
            atmo.Density = 0
            atmo.Haze = 0
            atmo.Glare = 0
        end
        for _, d in ipairs(Camera:GetDescendants()) do
            if d:IsA("ParticleEmitter") then d.Enabled = false end
        end
    else
        Lighting.FogEnd = 100000
        Lighting.FogStart = 0
        local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
        if atmo then
            atmo.Density = 0.3
            atmo.Haze = 0.5
        end
    end
end)

createToggleRow(perfCard, "全亮", "设置最大环境亮度与可见度", Config.Fullbright, function(v)
    Config.Fullbright = v
    if not v then
        Lighting.Brightness = 2
        Lighting.Ambient = Color3.fromRGB(70, 70, 70)
        Lighting.OutdoorAmbient = Color3.fromRGB(70, 70, 70)
        Lighting.GlobalShadows = true
    end
end)

createToggleRow(perfCard, "性能模式(低画质)", "禁用阴影并降低渲染负载", Config.PerformanceMode, function(v)
    Config.PerformanceMode = v
    Lighting.GlobalShadows = not v
end)




createToggleRow(perfCard, "隐藏游戏UI", "隐藏Roblox游戏UI以获得清晰视野", Config.HideGameUI, function(v)
    Config.HideGameUI = v
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        if pg:FindFirstChild("MainGui") then pg.MainGui.Enabled = not v end
        if pg:FindFirstChild("Fisher_GUI") then pg.Fisher_GUI.Enabled = not v end
    end
end)

createButtonRow(perfCard, "解锁全部图鉴", "在游戏图鉴中显示所有109种鱼及物品", "解锁图鉴", function()
    local count = 0
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)
    if pData and pData:FindFirstChild("Index") then
        for _, b in ipairs(pData.Index:GetChildren()) do
            if b:IsA("BoolValue") then b.Value = true end
        end
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Menu") and pg.MainGui.Menu:FindFirstChild("Index") then
        local indexList = pg.MainGui.Menu.Index:FindFirstChild("IndexFrame") and pg.MainGui.Menu.Index.IndexFrame:FindFirstChild("Indexlist")
        if indexList then
            for _, f in ipairs(indexList:GetChildren()) do
                if f:IsA("Frame") then
                    count = count + 1
                    local btn = f:FindFirstChild("Button")
                    if btn then
                        local title = btn:FindFirstChild("Title")
                        if title and title:IsA("TextLabel") then title.Text = f.Name end
                        local detail = btn:FindFirstChild("Detail")
                        if detail then
                            detail.Visible = true
                            for _, img in ipairs(detail:GetDescendants()) do
                                if img:IsA("ImageLabel") then img.ImageColor3 = Color3.new(1, 1, 1) end
                            end
                        end
                    end
                end
            end
        end
    end
    ShowNotification("图鉴已解锁", string.format("已在游戏图鉴中显示 %d 种鱼！", count > 0 and count or 109), "SUCCESS")
end)

createCategoryHeader(tabPlayer, "玩家移动")
local moveCard = createCardGroup(tabPlayer)

createToggleRow(moveCard, "步行加速", "提高移动速度", Config.WalkSpeedEnabled, function(v)
    Config.WalkSpeedEnabled = v
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed = v and Config.WalkSpeedValue or 16 end
end)
createSliderRow(moveCard, "速度值", "目标步行速度", 16, 120, Config.WalkSpeedValue, false, "", function(v)
    Config.WalkSpeedValue = v
    if Config.WalkSpeedEnabled then
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = v end
    end
end)

createToggleRow(moveCard, "飞行", "使用WASD和空格/Shift自由飞行", Config.FlyEnabled, function(v) Config.FlyEnabled = v end)
createSliderRow(moveCard, "飞行速度", "飞行移动速度", 20, 150, Config.FlySpeed, false, "", function(v) Config.FlySpeed = v end)
createToggleRow(moveCard, "无限跳跃", "在空中无限跳跃", Config.InfiniteJump, function(v) Config.InfiniteJump = v end)
createToggleRow(moveCard, "水上行走", "在海面上行走(海平面: 0)", Config.WalkOnWater, function(v) Config.WalkOnWater = v end)
createToggleRow(moveCard, "穿墙", "穿过固体障碍和墙壁", Config.Noclip, function(v) Config.Noclip = v end)

createCategoryHeader(tabPlayer, "防挂机与稳定性")
local stabCard = createCardGroup(tabPlayer)
createToggleRow(stabCard, "防挂机", "防止Roblox 20分钟空闲断开", Config.AntiAFK, function(v) Config.AntiAFK = v end)
createToggleRow(stabCard, "被踢自动重连", "自动重新连接到服务器", Config.AutoRejoin, function(v) Config.AutoRejoin = v end)

createCategoryHeader(tabProfiles, "配置文件管理")
local profCard = createCardGroup(tabProfiles)

createButtonRow(profCard, "保存配置", "将所有设置保存到JSON文件", "保存配置", function()
    if SaveProfile() then
        ShowNotification("配置已保存", "配置文件 'default.json' 保存成功！", "SUCCESS")
    else
        ShowNotification("配置错误", "保存配置文件失败。", "ERROR")
    end
end)

createButtonRow(profCard, "加载配置", "从JSON文件加载设置", "加载配置", function()
    if LoadProfile() then
        ShowNotification("配置已加载", "配置文件 'default.json' 加载成功！", "SUCCESS")
    else
        ShowNotification("配置错误", "未找到已保存的配置文件。", "WARN")
    end
end)

createToggleRow(profCard, "注入时自动加载配置", "启动时自动加载配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end)

createCategoryHeader(tabProfiles, "会话操作")
local credCard = createCardGroup(tabProfiles)
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复光照", "卸载", UnloadScript)

local lastCastTime = 0
local lastSellTime = 0
local lastSkillTime = 0
local lastGachaTime = 0
local lastBaitBuyTime = 0
local lastQuestTime = 0
local lastGodPrayTime = 0
local lastEquipTime = 0
local lastProgressionTime = 0
local lastProtectTime = 0

local craftMaterialFish = {
    ["Mountain Fish"] = true, -- 山鱼
    ["Catfish"] = true, -- 鲶鱼
    ["Crimson Catfish"] = true, -- 深红鲶鱼
    ["Scarlet Fish"] = true, -- 猩红鱼
    ["Elder Scarlet Fish"] = true, -- 长老猩红鱼
    ["Octoparasitic Fish"] = true, -- 章鱼寄生鱼
    ["Tiger Mirefish"] = true, -- 虎纹沼泽鱼
    ["Mirage Lanternfish"] = true, -- 幻影灯鱼
    ["Golden Guardian Fish"] = true, -- 黄金守护鱼
    ["Frost Kingfish"] = true, -- 冰霜王鱼
    ["Frost Queenfish"] = true, -- 冰霜后鱼
    ["Rainbow Dragonfish"] = true, -- 彩虹龙鱼
    ["Sanguine Fish"] = true, -- 血色鱼
}

local waterPlatform = Instance.new("Part")
waterPlatform.Name = "IdenticalWaterPlatform"
waterPlatform.Size = Vector3.new(60, 2, 60)
waterPlatform.Anchored = true
waterPlatform.CanCollide = false
waterPlatform.Transparency = 1
waterPlatform.Parent = Workspace
table.insert(cleanUpInstances, waterPlatform)

table.insert(activeConnections, RunService.Heartbeat:Connect(function(dt)
    if not isRunning then return end
    pcall(function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then return end
        local now = tick()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(LocalPlayer.UserId)

        if Config.WalkSpeedEnabled then
            hum.WalkSpeed = Config.WalkSpeedValue
        end

        if Config.WalkOnWater then
            waterPlatform.CFrame = CFrame.new(root.Position.X, 0, root.Position.Z)
            waterPlatform.CanCollide = (root.Position.Y >= -1)
        else
            waterPlatform.CanCollide = false
        end

        if Config.Noclip then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end

        local isFishing = char:GetAttribute("Fishing") == true
        local isMinigame = char:GetAttribute("Minigame") == true or (pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing") and pg.MainGui.Fishing.Visible)
        local isCD = char:GetAttribute("CDForTheNextThrow") == true
        local isSwimming = char:GetAttribute("Swimming") == true

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
            if Config.AutoCast and not isCD and not isSwimming and (now - lastCastTime >= Config.CastDelay) then
                local canCast = true
                if pData and pData:FindFirstChild("InventoryLimit") then
                    local invCount = 0
                    if pData:FindFirstChild("Inventory") then invCount = invCount + #pData.Inventory:GetChildren() end
                    if pData:FindFirstChild("Hotbar") then
                        for _, item in ipairs(pData.Hotbar:GetChildren()) do
                            if item:FindFirstChild("Quantity") then invCount = invCount + item.Quantity.Value else invCount = invCount + 1 end
                        end
                    end
                    if invCount >= pData.InventoryLimit.Value then
                        canCast = false
                        if Config.AutoSell and (now - lastSellTime >= 5.0) and Events:FindFirstChild("SellFish") then
                            if (Config.MaterialFarming or Config.AutoFavouriteFish) and pData:FindFirstChild("Inventory") then
                                for _, item in ipairs(pData.Inventory:GetChildren()) do
                                    local itemName = item.Name
                                    local isFav = item:FindFirstChild("Favorite") and item.Favorite.Value == true
                                    if not isFav and ((Config.MaterialFarming and craftMaterialFish[itemName]) or (Config.AutoFavouriteFish and itemName == Config.FavouriteFishName)) then
                                        if Events:FindFirstChild("FavoriteItem") then Events.FavoriteItem:FireServer(item) end
                                    end
                                end
                            end
                            Events.SellFish:FireServer("All")
                            lastSellTime = now
                        end
                    end
                end

                if Config.AutoSell and (now - lastSellTime >= Config.SellInterval) and Events:FindFirstChild("SellFish") then
                    if (Config.MaterialFarming or Config.AutoFavouriteFish) and pData and pData:FindFirstChild("Inventory") then
                        for _, item in ipairs(pData.Inventory:GetChildren()) do
                            local itemName = item.Name
                            local isFav = item:FindFirstChild("Favorite") and item.Favorite.Value == true
                            if not isFav and ((Config.MaterialFarming and craftMaterialFish[itemName]) or (Config.AutoFavouriteFish and itemName == Config.FavouriteFishName)) then
                                if Events:FindFirstChild("FavoriteItem") then Events.FavoriteItem:FireServer(item) end
                            end
                        end
                    end
                    Events.SellFish:FireServer("All")
                    lastSellTime = now
                end

                if (Config.MaterialFarming or Config.AutoFavouriteFish) and (now - lastProtectTime >= 1.5) and pData and pData:FindFirstChild("Inventory") then
                    lastProtectTime = now
                    for _, item in ipairs(pData.Inventory:GetChildren()) do
                        local itemName = item.Name
                        local isFav = item:FindFirstChild("Favorite") and item.Favorite.Value == true
                        if not isFav then
                            local shouldProtect = false
                            if Config.MaterialFarming and craftMaterialFish[itemName] then shouldProtect = true end
                            if Config.AutoFavouriteFish and itemName == Config.FavouriteFishName then shouldProtect = true end
                            if shouldProtect and Events:FindFirstChild("FavoriteItem") then
                                Events.FavoriteItem:FireServer(item)
                            end
                        end
                    end
                end

                if canCast and Events and Events:FindFirstChild("Fishing") then
                    Events.Fishing:FireServer(root.CFrame)
                    lastCastTime = now
                end
            end
        end

        if (now - lastEquipTime >= 5.0) and pData then
            lastEquipTime = now
            if Config.AutoEquipBestBait and pData:FindFirstChild("Bait") and pData:FindFirstChild("EquippedBait") and Events:FindFirstChild("EquipBait") then
                local bestBait = nil
                local bestLuck = -1
                local baitLuckMap = {
                    ["Ancestral Bait"] = 50, -- 先祖鱼饵
                    ["Elite Bait"] = 30, -- 精英鱼饵
                    ["Corrupted Essence Bait"] = 18, -- 腐化精华鱼饵
                    ["Crude Mash Bait"] = 8, -- 粗制鱼饵
                    ["Basic Bait"] = 3 -- 基础鱼饵
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

        if Config.AutoSell and (now - lastSellTime >= Config.SellInterval) then
            if Events and Events:FindFirstChild("SellFish") then
                Events.SellFish:FireServer("All")
                lastSellTime = now
            end
        end

        if Config.AutoPrayGodSpirit and (now - lastGodPrayTime >= 3.0) then
            if Workspace:FindFirstChild("NPC") then
                local sp = Workspace.NPC:FindFirstChild("Spirit") or Workspace.NPC:FindFirstChild("God")
                if sp then
                    for _, d in ipairs(sp:GetDescendants()) do
                        if d:IsA("ProximityPrompt") then
                            TriggerPrompt(d)
                            lastGodPrayTime = now
                        end
                    end
                end
            end
        end

        if Config.AutoTicketQuest and (now - lastQuestTime >= 2.0) then
            if Events and Events:FindFirstChild("ClaimQuest") then
                Events.ClaimQuest:FireServer("Ticket", Config.TicketDifficulty)
                lastQuestTime = now
            end
        end

        if Config.AutoClaimDaily and (now - lastCastTime >= 2.0) then
            if Events and Events:FindFirstChild("DailyReward") then
                for day = 1, 7 do Events.DailyReward:FireServer(day) end
            end
        end

        if Config.AutoGacha and (now - lastGachaTime >= 1.5) then
            if Events and Events:FindFirstChild("Gacha") then
                Events.Gacha:FireServer(Config.GachaBanner, Config.GachaPullsPerAction)
                lastGachaTime = now
            end
        end

        if Config.AutoCraftBait and (now - lastCastTime >= 2.0) then
            if Events and Events:FindFirstChild("CraftBait") then
                Events.CraftBait:FireServer(Config.CraftBaitName, Config.CraftAmount)
            end
        end

        if Config.AutoBuyBait and (now - lastBaitBuyTime >= Config.BuyBaitDelay) then
            if Events and Events:FindFirstChild("BuyBait") then
                Events.BuyBait:FireServer(Config.BuyBaitName, Config.BuyBaitAmount)
                lastBaitBuyTime = now
            end
        end

        if Config.OctoAutoMinigame then
            if Events and Events:FindFirstChild("RhythmHit") then
                Events.RhythmHit:FireServer(true, 100)
            end
        end
    end)
end))

local flyBV, flyBG = nil, nil
table.insert(activeConnections, RunService.RenderStepped:Connect(function()
    if not isRunning then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    if Config.FlyEnabled then
        if not flyBV then
            flyBV = Instance.new("BodyVelocity")
            flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
            flyBV.Parent = root
            table.insert(cleanUpInstances, flyBV)

            flyBG = Instance.new("BodyGyro")
            flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
            flyBG.Parent = root
            table.insert(cleanUpInstances, flyBG)
        end

        local camCF = Camera.CFrame
        local dir = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir = dir + camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir = dir - camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir = dir + camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir = dir - camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir = dir - Vector3.new(0, 1, 0) end

        flyBG.CFrame = camCF
        flyBV.Velocity = dir.Unit * Config.FlySpeed
        if dir.Magnitude == 0 then flyBV.Velocity = Vector3.zero end
    else
        if flyBV then flyBV:Destroy(); flyBV = nil end
        if flyBG then flyBG:Destroy(); flyBG = nil end
    end
end))

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
                local cutscene = pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Cutscene")
                if cutscene and cutscene:FindFirstChild("Hurt") then
                    cutscene.Hurt.ImageTransparency = 1
                end
                local impactCutscene = pg:FindFirstChild("Impact") and pg.Impact:FindFirstChild("Cutscene")
                if impactCutscene and impactCutscene:FindFirstChild("Hurt") then
                    impactCutscene.Hurt.ImageTransparency = 1
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

table.insert(activeConnections, UserInputService.JumpRequest:Connect(function()
    if Config.InfiniteJump and isRunning then
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

pcall(function()
    LocalPlayer.Idled:Connect(function()
        if Config.AntiAFK and isRunning then
            local vu = game:GetService("VirtualUser")
            if vu then
                vu:CaptureController()
                vu:ClickButton2(Vector2.new(0, 0))
            end
        end
    end)
end)

local espFolder = Instance.new("Folder")
espFolder.Name = "IdenticalESP"
espFolder.Parent = Workspace
table.insert(cleanUpInstances, espFolder)

local activeESP = {}

local fishRingAnchor = Instance.new("Part")
fishRingAnchor.Name = "FishRingAnchor"
fishRingAnchor.Size = Vector3.new(0.5, 0.5, 0.5)
fishRingAnchor.Transparency = 1
fishRingAnchor.CanCollide = false
fishRingAnchor.Anchored = true
fishRingAnchor.Parent = Workspace
table.insert(cleanUpInstances, fishRingAnchor)

local fishRingAdornment = Instance.new("CylinderHandleAdornment")
fishRingAdornment.Name = "FishRingAdornment"
fishRingAdornment.Adornee = fishRingAnchor
fishRingAdornment.AlwaysOnTop = true
fishRingAdornment.ZIndex = 5
fishRingAdornment.Radius = 6
fishRingAdornment.InnerRadius = 5.2
fishRingAdornment.Height = 0.2
fishRingAdornment.Color3 = Color3.fromRGB(255, 45, 45)
fishRingAdornment.Transparency = 0.2
fishRingAdornment.CFrame = CFrame.Angles(math.rad(90), 0, 0)
fishRingAdornment.Visible = false
fishRingAdornment.Parent = fishRingAnchor

local function AddESP(instance, name, espCategory, color, icon)
    if not instance or activeESP[instance] then return end
    local part = instance:IsA("BasePart") and instance or instance:FindFirstChildWhichIsA("BasePart")
    if not part then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "ESP_" .. name
    bb.Size = UDim2.new(0, 150, 0, 24)
    bb.StudsOffset = Vector3.new(0, 2.5, 0)
    bb.AlwaysOnTop = true
    bb.Adornee = part
    bb.Parent = espFolder

    local f = Instance.new("Frame", bb)
    f.Size = UDim2.new(1, 0, 1, 0)
    f.BackgroundColor3 = Colors.Background
    f.BackgroundTransparency = 0.2
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)
    local s = Instance.new("UIStroke", f)
    s.Color = color or Colors.PurpleAccent
    s.Thickness = 1

    local lbl = Instance.new("TextLabel", f)
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.Text = (icon or "") .. " " .. name
    lbl.TextColor3 = color or Colors.TextWhite
    lbl.TextSize = 10

    activeESP[instance] = {gui = bb, label = lbl, part = part, espCategory = espCategory, name = name, icon = icon or ""}
end

local function RemoveESP(instance)
    local data = activeESP[instance]
    if data then
        if data.gui and data.gui.Parent then data.gui:Destroy() end
        activeESP[instance] = nil
    end
end

table.insert(activeConnections, RunService.RenderStepped:Connect(function()
    if not isRunning then return end

    if Config.Fullbright then
        Lighting.Brightness = 2.5
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1000000
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    end
    if Config.NoFog then
        Lighting.FogEnd = 1000000
        Lighting.FogStart = 1000000
        local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
        if atmo and (atmo.Density > 0 or atmo.Haze > 0) then
            atmo.Density = 0
            atmo.Haze = 0
            atmo.Glare = 0
        end
        for _, d in ipairs(Camera:GetDescendants()) do
            if d:IsA("ParticleEmitter") and d.Enabled then
                d.Enabled = false
            end
        end
    end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                AddESP(p.Character, p.DisplayName, "Players", Colors.PurpleAccent, "👤")
            end
        end
    end

    if Workspace:FindFirstChild("SecretRod") then
        for _, r in ipairs(Workspace.SecretRod:GetChildren()) do
            AddESP(r, r.Name, "SecretRod", Colors.AccentYellow, "🌟")
        end
    end

    if Workspace:FindFirstChild("NPC") then
        local sp = Workspace.NPC:FindFirstChild("Spirit") or Workspace.NPC:FindFirstChild("God")
        if sp then
            AddESP(sp, "神灵", "GodSpirit", Colors.AccentGreen, "⛩️")
        end
    end

    if Workspace:FindFirstChild("Boat") then
        for _, b in ipairs(Workspace.Boat:GetChildren()) do
            AddESP(b, b.Name, "Boats", Colors.AccentBlue, "⛵")
        end
    end

    if Workspace:FindFirstChild("BossSetUp") then
        for _, b in ipairs(Workspace.BossSetUp:GetChildren()) do
            AddESP(b, b.Name, "Boss", Colors.AccentRed, "👹")
        end
    end

    if Workspace:FindFirstChild("NPC") then
        for _, n in ipairs(Workspace.NPC:GetChildren()) do
            if n.Name:find("Taoist") or n.Name:find("Grand Angler") then
                AddESP(n, n.Name, "Taoist", Colors.AccentOrange, "📜")
            elseif n.Name:find("Maoshan") then
                AddESP(n, n.Name, "Maoshan", Colors.PurplePrimary, "✨")
            end
        end
    end

    local camPos = Camera.CFrame.Position
    for inst, data in pairs(activeESP) do
        if not inst.Parent or not data.part.Parent then
            RemoveESP(inst)
        else
            local isEnabled = Config["ESP_" .. data.espCategory]
            data.gui.Enabled = isEnabled and true or false
            if isEnabled then
                local dist = math.floor((camPos - data.part.Position).Magnitude)
                data.label.Text = data.icon .. " " .. data.name .. " [" .. dist .. "米]"
            end
        end
    end

    if Config.FishRedRing then
        local fishPos = nil
        local char = LocalPlayer.Character
        if char then
            for _, d in ipairs(char:GetDescendants()) do
                if (d:IsA("Beam") or d:IsA("RopeConstraint") or d:IsA("SpringConstraint")) and d.Attachment1 then
                    fishPos = d.Attachment1.WorldPosition
                    break
                end
            end
        end
        if not fishPos and Workspace:FindFirstChild("Fishes") then
            local uid = tostring(LocalPlayer.UserId)
            for _, f in ipairs(Workspace.Fishes:GetChildren()) do
                if f:FindFirstChild(uid .. "_PlayerHealth") then
                    if f:FindFirstChild("Model") and f.Model:IsA("Model") then
                        fishPos = f.Model:GetPivot().Position
                    elseif f:FindFirstChild("Buoy") and f.Buoy:IsA("BasePart") then
                        fishPos = f.Buoy.Position
                    end
                    break
                end
            end
        end

        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local isHooked = char and (char:GetAttribute("Fishing") == true or char:GetAttribute("Minigame") == true)
        local fUI = pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing")
        if (isHooked or (fUI and fUI.Visible)) and fishPos then
            fishRingAnchor.Position = fishPos
            fishRingAdornment.Visible = true
        else
            fishRingAdornment.Visible = false
        end
    else
        if fishRingAdornment.Visible then fishRingAdornment.Visible = false end
    end
end))

table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl or input.KeyCode == Config.UIKeybind then
        if ToggleUiVisibility then ToggleUiVisibility() end
    elseif input.KeyCode == Enum.KeyCode.End or input.KeyCode == Config.StopKeybind then
        UnloadScript()
    end
end))

ShowNotification("IDENTICAL V1.0", "Heavyweight Fishing 脚本已就绪！按 R-CTRL 切换菜单。", "SUCCESS", 5)