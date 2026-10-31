-- 启动前安全获取执行器环境；部分执行器没有 getgenv
local sharedEnv = nil
if type(getgenv) == "function" then
    local envOk, envValue = pcall(getgenv)
    if envOk and type(envValue) == "table" then sharedEnv = envValue end
end

if not game:IsLoaded() then game.Loaded:Wait() end

-- 重复执行时先卸载旧实例；卸载失败不阻断本次启动
if sharedEnv and type(sharedEnv.IdenticalHeavyweightFishingUnload) == "function" then
    pcall(sharedEnv.IdenticalHeavyweightFishingUnload)
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
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Camera = Workspace.CurrentCamera

local isRunning = true
local activeConnections = {}
local cleanUpInstances = {}
local UIControls = {}
local currentSkillIndex = 1
local lockedCFrame = nil

-- 角色零件与物理缓存（优化 GC）
local cachedCharacterParts = {}
local cachedFishConstraint = nil
local lastConstraintSearch = 0

local Events = ReplicatedStorage:WaitForChild("Events", 10)
if not Events then
    warn("[IDENTICAL] 10 秒内未找到 ReplicatedStorage.Events；界面仍会加载，但依赖 Events 的功能暂不可用。")
end

local Config = {
    UIScale = 0.75,
    AutoCast = false,
    CastDelay = 1.0,
    CastPower = 100,
    PositionLock = false,
    AnchorBar = true,
    AutoSlam = true,
    AutoCharge = true,
    InstantCatch = true,
    BossAutoSkills = true,
    AutoSkills = false,
    SkillZ = true,
    SkillX = true,
    SkillC = true,
    SkillV = true,
    SkillOrder = "Z,X,C,V",
    SkillInterval = 1.5,
    SelectedSkill = "One-Strike Heaven Gate",
    
    AutoEquipBestBait = false,
    AutoEquipBestRod = false,
    AutoEquipBestOrb = false,
    Loadout1_Rod = "Wooden Rod",
    Loadout1_Bait = "Basic Bait",
    Loadout2_Rod = "Wooden Rod",
    Loadout2_Bait = "Basic Bait",
    
    AutoSell = false,
    SellInterval = 30,
    AutoFavouriteFish = true,
    AutoProtectRareBossFish = true,
    FavouriteFishName = "Colossal Tigerfish",
    CustomProtectedFish = "Wraith*,Colossal Tigerfish,Octoparasitic Fish,Primordial Kunfish Overlord,Heavenpiercer Turtle",
    MaterialFarming = true,
    
    OctoAutoMinigame = false,
    AutoFarmBoss = false,
    AutoFarmSecretBoss = false,
    SelectedBoss = "Enzo",
    
    AutoGodSpiritCheck = false,
    AutoPrayGodSpirit = false,
    AutoServerHopGod = false,
    AutoServerHopMaoshan = false,
    AutoServerHopTaoist = false,
    
    AutoTicketQuest = false,
    TicketDifficulty = "简单",
    AutoClaimDaily = false,
    DailyClaimDelay = 0.5,
    
    AutoCraftBait = false,
    CraftBaitName = "Nameless Bait",
    CraftAmount = 1,
    AutoBuyBait = false,
    BuyBaitName = "Ancestral Bait",
    BuyBaitAmount = 5,
    BuyBaitThreshold = 10,
    BuyBaitDelay = 1.0,
    

    WalkSpeedEnabled = false,
    WalkSpeedValue = 16,
    FlyEnabled = false,
    FlySpeed = 50,
    InfiniteJump = false,
    WalkOnWater = false,
    Noclip = false,
    
    ESP_GodSpirit = false,
    ESP_SecretRod = false,
    ESP_Boats = false,
    ESP_Maoshan = false,
    ESP_Taoist = false,
    ESP_Boss = false,
    ESP_Players = false,
    FishRedRing = true,
    NoFog = false,
    Fullbright = false,
    PerformanceMode = false,
    Disable3DRendering = false,
    HideGameUI = false,
    
    AntiAFK = true,
    AutoRejoin = false,
    AutoExecuteOnJoin = false,
    UIKeybind = Enum.KeyCode.RightControl,
    StopKeybind = Enum.KeyCode.End,
    ActiveProfile = "default",
    AutoLoadProfile = true
}

local QuestDiffMap = {
    ["简单"] = "Easy",
    ["困难"] = "Hard",
    ["Easy"] = "Easy",
    ["Hard"] = "Hard"
}

-- 执行器 Hook 属于可选能力：安装失败不能阻止主界面加载
if sharedEnv then
    sharedEnv.IdenticalFishingConfig = Config
    sharedEnv.IdenticalFishingRunning = true

    local hookReady =
        type(hookmetamethod) == "function"
        and type(newcclosure) == "function"
        and type(getnamecallmethod) == "function"
        and type(checkcaller) == "function"

    if hookReady and not sharedEnv.IdenticalHookInstalled then
        local hookOk, hookErr = pcall(function()
            local oldNamecall
            oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                local method = getnamecallmethod()
                if method == "FireServer" and not checkcaller() and typeof(self) == "Instance" then
                    local cfg = sharedEnv.IdenticalFishingConfig
                    if sharedEnv.IdenticalFishingRunning and cfg then
                        local assistActive = cfg.AnchorBar or cfg.OctoAutoMinigame or cfg.AutoFarmSecretBoss or cfg.AutoFarmBoss
                        local rName = self.Name
                        if rName == "FishingMinigame" and assistActive then
                            local args = {...}
                            local action = tostring(args[1])
                            if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar") or action:find("Fail") or action:find("Miss") then
                                return oldNamecall(self, "In bar", unpack(args, 2))
                            end
                        elseif (rName == "Slam" or rName:find("Rhythm") or rName:find("QTE") or rName:find("Octo")) and (assistActive or cfg.AutoSlam) then
                            local args = {...}
                            local firstArg = args[1]
                            if firstArg == nil or firstArg == false or tostring(firstArg):lower():find("miss") or tostring(firstArg):lower():find("fail") or tostring(firstArg):lower():find("bad") then
                                if rName == "Slam" then
                                    return oldNamecall(self, "Perfect")
                                else
                                    args[1] = (type(firstArg) == "boolean") and true or "Perfect"
                                    if args[2] == nil or type(args[2]) == "number" then args[2] = 100 end
                                    return oldNamecall(self, unpack(args))
                                end
                            end
                        elseif rName == "Charge" and (assistActive or cfg.AutoCharge) then
                            local args = {...}
                            if args[1] == nil or (type(args[1]) == "number" and args[1] < 100) then
                                return oldNamecall(self, 100)
                            end
                        end
                    end
                end
                return oldNamecall(self, ...)
            end))
            if type(oldNamecall) ~= "function" then
                error("hookmetamethod 未返回原始 __namecall")
            end
        end)

        if hookOk then
            sharedEnv.IdenticalHookInstalled = true
        else
            warn("[IDENTICAL] Hook 安装失败，已跳过可选 Hook：" .. tostring(hookErr))
        end
    elseif not hookReady then
        warn("[IDENTICAL] 当前执行器缺少完整 Hook API，已跳过 Hook；主界面仍会继续加载。")
    end
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
        if typeof(v) == "EnumItem" then data[k] = {__enum = tostring(v)} else data[k] = v end
    end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if ok and writefile then pcall(function() writefile(path, encoded) end); return true end
    return false
end

local blackOutFrame, mainFrameScale, ApplyLightingSettings

local function SyncUIWithConfig()
    for key, ctrl in pairs(UIControls) do
        if Config[key] ~= nil and ctrl and ctrl.Set then
            -- 传入 silent=true 仅同步UI视觉状态，避免启动时触发 false 分支副作用弄乱游戏界面
            pcall(ctrl.Set, Config[key], true)
        end
    end
    if mainFrameScale and mainFrameScale.Parent then
        mainFrameScale.Scale = Config.UIScale or 0.75
    end
    if Config.Fullbright or Config.NoFog then
        if ApplyLightingSettings then pcall(ApplyLightingSettings) end
    end
    if Config.Disable3DRendering and blackOutFrame then
        blackOutFrame.Visible = true
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
    end
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
                        if enumType and enumName and Enum[enumType] and Enum[enumType][enumName] then Config[k] = Enum[enumType][enumName] end
                    elseif Config[k] ~= nil then Config[k] = v end
                end
                if Config.SkillInterval == 0.8 or Config.SkillInterval == 2.0 then Config.SkillInterval = 1.5 end
                currentSkillIndex = 1
                SyncUIWithConfig()
                return true
            end
        end
    end
    return false
end

if Config.AutoLoadProfile then pcall(LoadProfile, "default") end

local CustomTP_FILE = PROFILE_DIR .. "/CustomTPs.json"
local CustomTPs = {}

local function LoadCustomTPs()
    EnsureProfileDir()
    if readfile then
        local ok, content = pcall(function() return readfile(CustomTP_FILE) end)
        if ok and content and #content > 0 then
            local decOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
            if decOk and type(decoded) == "table" then CustomTPs = decoded end
        end
    end
end

local function SaveCustomTPs()
    EnsureProfileDir()
    if writefile then
        local ok, encoded = pcall(function() return HttpService:JSONEncode(CustomTPs) end)
        if ok then pcall(function() writefile(CustomTP_FILE, encoded) end) end
    end
end

LoadCustomTPs()

local Colors = {
    Background       = Color3.fromRGB(13, 10, 20),
    SidebarBg        = Color3.fromRGB(18, 14, 28),
    BorderPurple     = Color3.fromRGB(168, 85, 247),
    BorderSubtle     = Color3.fromRGB(45, 34, 68),
    Divider          = Color3.fromRGB(38, 28, 58),
    PurplePrimary    = Color3.fromRGB(216, 160, 255),
    PurpleAccent     = Color3.fromRGB(192, 132, 252),
    PurpleMuted      = Color3.fromRGB(154, 143, 176),
    PurpleDark       = Color3.fromRGB(68, 42, 102),
    PurpleGlow       = Color3.fromRGB(224, 185, 255),
    RowNormal        = Color3.fromRGB(20, 16, 32),
    RowHover         = Color3.fromRGB(28, 22, 44),
    ControlBg        = Color3.fromRGB(28, 22, 44),
    InputBg          = Color3.fromRGB(16, 12, 24),
    TextWhite        = Color3.fromRGB(245, 242, 255),
    TextSubtle       = Color3.fromRGB(168, 150, 200),
    TextMuted        = Color3.fromRGB(130, 115, 155),
    AccentGreen      = Color3.fromRGB(52, 211, 153),
    AccentRed        = Color3.fromRGB(248, 113, 113),
    AccentOrange     = Color3.fromRGB(251, 146, 60),
    AccentYellow     = Color3.fromRGB(250, 204, 21),
    AccentBlue       = Color3.fromRGB(96, 165, 250),
    DropdownSelected = Color3.fromRGB(42, 30, 66)
}

local function getGuiParent()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, canCore = pcall(function()
        local test = Instance.new("Folder")
        test.Parent = CoreGui
        test:Destroy()
        return CoreGui
    end)
    if ok and canCore then return canCore end
    local pg = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
    return pg
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdenticalHeavyweightFishing"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local setParentOk = pcall(function() screenGui.Parent = getGuiParent() end)
if not setParentOk or not screenGui.Parent then
    pcall(function() screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) end)
end
table.insert(cleanUpInstances, screenGui)

blackOutFrame = Instance.new("Frame")
blackOutFrame.Name = "PowerSaveOverlay"
blackOutFrame.Size = UDim2.new(1, 0, 1, 0)
blackOutFrame.BackgroundColor3 = Color3.fromRGB(5, 5, 8)
blackOutFrame.BorderSizePixel = 0
blackOutFrame.Visible = false
blackOutFrame.ZIndex = 0
blackOutFrame.Parent = screenGui
local blackOutLabel = Instance.new("TextLabel")
blackOutLabel.Size = UDim2.new(1, 0, 0, 40)
blackOutLabel.Position = UDim2.new(0, 0, 0.1, 0)
blackOutLabel.BackgroundTransparency = 1
blackOutLabel.Font = Enum.Font.GothamBold
blackOutLabel.Text = "⚡ 极致省电挂机模式运行中 (已关闭 3D 渲染)"
blackOutLabel.TextColor3 = Colors.PurplePrimary
blackOutLabel.TextSize = 16
blackOutLabel.Parent = blackOutFrame

local function UnloadScript()
    isRunning = false
    if sharedEnv then
        sharedEnv.IdenticalFishingRunning = false
        sharedEnv.IdenticalHeavyweightFishingUnload = nil
        sharedEnv.IdenticalFishingConfig = nil
    end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    for _, conn in ipairs(activeConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(activeConnections)
    for _, inst in ipairs(cleanUpInstances) do pcall(function() if inst and inst.Parent then inst:Destroy() end end) end
    table.clear(cleanUpInstances)
    table.clear(cachedCharacterParts)
    pcall(function() local leftover = Workspace:FindFirstChild("IdenticalESP"); if leftover then leftover:Destroy() end end)
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then
            if pg:FindFirstChild("MainGui") then pg.MainGui.Enabled = true end
            if pg:FindFirstChild("Fisher_GUI") then pg.Fisher_GUI.Enabled = true end
        end
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = 16 end
        Lighting.FogEnd = 100000; Lighting.Brightness = 2; Lighting.ClockTime = 14
        Lighting.Ambient = Color3.fromRGB(70, 70, 70); Lighting.OutdoorAmbient = Color3.fromRGB(70, 70, 70); Lighting.GlobalShadows = true
    end)
end

if sharedEnv then sharedEnv.IdenticalHeavyweightFishingUnload = UnloadScript end

local notifContainer = Instance.new("Frame"); notifContainer.Name = "Notifications"; notifContainer.Size = UDim2.new(0, 300, 1, -40); notifContainer.Position = UDim2.new(1, -315, 0, 20); notifContainer.BackgroundTransparency = 1; notifContainer.ZIndex = 1000; notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)
local notifLayout = Instance.new("UIListLayout"); notifLayout.SortOrder = Enum.SortOrder.LayoutOrder; notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom; notifLayout.Padding = UDim.new(0, 8); notifLayout.Parent = notifContainer

local function ShowNotification(title, text, notifType, duration)
    if not isRunning then return end
    duration = duration or 3.5
    local accentColor = Colors.PurpleAccent
    if notifType == "SUCCESS" then accentColor = Colors.AccentGreen elseif notifType == "WARN" then accentColor = Colors.AccentYellow elseif notifType == "ERROR" then accentColor = Colors.AccentRed end
    local card = Instance.new("Frame"); card.Size = UDim2.new(1, 0, 0, 62); card.Position = UDim2.new(1, 30, 0, 0); card.BackgroundColor3 = Colors.Background; card.BackgroundTransparency = 0.08; card.BorderSizePixel = 0; card.ClipsDescendants = true; card.Parent = notifContainer
    local stroke = Instance.new("UIStroke"); stroke.Color = accentColor; stroke.Thickness = 1.2; stroke.Transparency = 0.2; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = card
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 20); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 12, 0, 6); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -24, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = title; tLabel.TextColor3 = Colors.PurplePrimary; tLabel.TextSize = 13; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -24, 0, 28); mLabel.Position = UDim2.new(0, 12, 0, 26); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = text; mLabel.TextColor3 = Colors.TextSubtle; mLabel.TextSize = 11; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.Parent = card
    TweenService:Create(card, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(0, 0, 0, 0)}):Play()
    task.delay(duration, function()
        if card and card.Parent then
            local tw = TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1, Position = card.Position + UDim2.new(1, 40, 0, 0)})
            tw:Play()
            tw.Completed:Wait()
            if card and card.Parent then card:Destroy() end
        end
    end)
end

local isHopping = false
local function ServerHop()
    if isHopping then return end
    isHopping = true
    ShowNotification("服务器跳转", "正在搜索可用服务器...", "WARN")
    task.spawn(function()
        local ok = pcall(function()
            local placeId = game.PlaceId
            local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Desc&limit=100"
            local body = HttpService:JSONDecode(game:HttpGet(url))
            if body and body.data then
                local candidates = {}
                for _, s in ipairs(body.data) do
                    if type(s.playing) == "number" and type(s.maxPlayers) == "number" and s.playing < s.maxPlayers and s.id ~= game.JobId then
                        table.insert(candidates, s.id)
                    end
                end
                if #candidates > 0 then
                    local chosen = candidates[math.random(1, #candidates)]
                    TeleportService:TeleportToPlaceInstance(placeId, chosen, LocalPlayer)
                    return
                end
            end
        end)
        task.wait(4)
        isHopping = false
        if not ok then ShowNotification("服务器跳转", "获取服务器列表失败，稍后重试。", "ERROR") end
    end)
end

local ToggleUiVisibility, mainFrame
local floatingCrescent = Instance.new("ImageButton")
floatingCrescent.Name = "FloatingCrescent"
floatingCrescent.Size = UDim2.new(0, 48, 0, 48)
floatingCrescent.Position = UDim2.new(0, 18, 0, 300)
floatingCrescent.BackgroundColor3 = Colors.Background
floatingCrescent.BorderSizePixel = 0
floatingCrescent.Visible = false
floatingCrescent.ZIndex = 1000
floatingCrescent.Parent = screenGui
table.insert(cleanUpInstances, floatingCrescent)

local fcCutoutRef = nil

do
    local fcCorner = Instance.new("UICorner"); fcCorner.CornerRadius = UDim.new(1, 0); fcCorner.Parent = floatingCrescent
    local fcStroke = Instance.new("UIStroke"); fcStroke.Color = Colors.PurpleAccent; fcStroke.Thickness = 1.8; fcStroke.Transparency = 0.2; fcStroke.Parent = floatingCrescent
    
    local fcIconContainer = Instance.new("Frame"); fcIconContainer.Size = UDim2.new(0, 26, 0, 26); fcIconContainer.Position = UDim2.new(0.5, -13, 0.5, -13); fcIconContainer.BackgroundTransparency = 1; fcIconContainer.ClipsDescendants = true; fcIconContainer.Parent = floatingCrescent
    local fcOuter = Instance.new("Frame"); fcOuter.Size = UDim2.new(0, 26, 0, 26); fcOuter.BackgroundColor3 = Colors.PurplePrimary; fcOuter.BorderSizePixel = 0; fcOuter.Parent = fcIconContainer
    local fcOC = Instance.new("UICorner"); fcOC.CornerRadius = UDim.new(1, 0); fcOC.Parent = fcOuter
    local fcCutout = Instance.new("Frame"); fcCutout.Size = UDim2.new(0, 22, 0, 22); fcCutout.Position = UDim2.new(0, 7, 0, -3); fcCutout.BackgroundColor3 = Colors.Background; fcCutout.BorderSizePixel = 0; fcCutout.Parent = fcOuter
    local fcCC = Instance.new("UICorner"); fcCC.CornerRadius = UDim.new(1, 0); fcCC.Parent = fcCutout
    fcCutoutRef = fcCutout

    local dot = Instance.new("Frame"); dot.Size = UDim2.new(0, 8, 0, 8); dot.Position = UDim2.new(1, -9, 1, -9); dot.BackgroundColor3 = Colors.AccentGreen; dot.BorderSizePixel = 0; dot.Parent = floatingCrescent
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local dotStroke = Instance.new("UIStroke", dot); dotStroke.Color = Colors.Background; dotStroke.Thickness = 1.2

    local fcDragging, fcDragInput, fcDragStart, fcStartPos = false, nil, nil, nil
    local dragMovedDistance = 0

    floatingCrescent.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            fcDragging = true
            dragMovedDistance = 0
            fcDragStart = input.Position
            fcStartPos = floatingCrescent.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    fcDragging = false
                end
            end)
        end
    end)

    floatingCrescent.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            fcDragInput = input
        end
    end)

    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if input == fcDragInput and fcDragging and fcDragStart and fcStartPos then
            local delta = input.Position - fcDragStart
            dragMovedDistance = delta.Magnitude
            local cam = Workspace.CurrentCamera or Camera
            local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
            -- 修复：先计算绝对屏幕坐标再 clamp，彻底解决只能左右/往下拖不能往上的问题
            local absX = fcStartPos.X.Scale * vp.X + fcStartPos.X.Offset + delta.X
            local absY = fcStartPos.Y.Scale * vp.Y + fcStartPos.Y.Offset + delta.Y
            local clampedX = math.clamp(absX, 10, math.max(10, vp.X - 58))
            local clampedY = math.clamp(absY, 10, math.max(10, vp.Y - 58))
            floatingCrescent.Position = UDim2.new(0, clampedX, 0, clampedY)
        end
    end))

    floatingCrescent.MouseEnter:Connect(function()
        TweenService:Create(floatingCrescent, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = Colors.RowHover}):Play()
        TweenService:Create(fcStroke, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Colors.PurpleGlow, Transparency = 0}):Play()
        if fcCutoutRef then fcCutoutRef.BackgroundColor3 = Colors.RowHover end
    end)

    floatingCrescent.MouseLeave:Connect(function()
        TweenService:Create(floatingCrescent, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = Colors.Background}):Play()
        TweenService:Create(fcStroke, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Colors.PurpleAccent, Transparency = 0.2}):Play()
        if fcCutoutRef then fcCutoutRef.BackgroundColor3 = Colors.Background end
    end)

    local lastToggleClick = 0
    local function handleToggleTrigger()
        if dragMovedDistance > 8 then return end
        local now = tick()
        if now - lastToggleClick < 0.25 then return end
        lastToggleClick = now
        if ToggleUiVisibility then ToggleUiVisibility() end
    end

    floatingCrescent.MouseButton1Click:Connect(handleToggleTrigger)
    if floatingCrescent.Activated then floatingCrescent.Activated:Connect(handleToggleTrigger) end

    task.spawn(function()
        while isRunning and floatingCrescent and floatingCrescent.Parent do
            if floatingCrescent.Visible and not (mainFrame and mainFrame.Visible) then
                pcall(function()
                    TweenService:Create(fcStroke, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency = 0.08, Color = Colors.PurpleGlow}):Play()
                end)
                task.wait(1.4)
                if not isRunning or not floatingCrescent.Visible then break end
                pcall(function()
                    TweenService:Create(fcStroke, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency = 0.55, Color = Colors.PurpleAccent}):Play()
                end)
                task.wait(1.4)
            else
                task.wait(0.5)
            end
        end
    end)
end

mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mainFrame.Position = UDim2.fromScale(0.5, 0.5)
mainFrame.Size = UDim2.fromOffset(700, 480)
mainFrame.BackgroundColor3 = Colors.Background
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Visible = true
mainFrame.Parent = screenGui
table.insert(cleanUpInstances, mainFrame)

mainFrameScale = Instance.new("UIScale")
mainFrameScale.Parent = mainFrame
mainFrameScale.Scale = Config.UIScale

local function UpdateMainFrameScale()
    if not mainFrame or not mainFrame.Parent then return end
    local cam = Workspace.CurrentCamera or Camera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    if vp.X <= 0 or vp.Y <= 0 then return end
    
    local maxScaleX = (vp.X - 30) / 700
    local maxScaleY = (vp.Y - 24) / 480
    local autoMaxScale = math.clamp(math.min(maxScaleX, maxScaleY), 0.45, 1.0)
    local targetScale = math.min(Config.UIScale or 0.75, autoMaxScale)
    
    if mainFrameScale and mainFrameScale.Parent then
        mainFrameScale.Scale = targetScale
    end
    
    if notifContainer and notifContainer.Parent then
        local nw = math.clamp(vp.X * 0.45, 180, 280)
        notifContainer.Size = UDim2.new(0, nw, 1, -40)
        notifContainer.Position = UDim2.new(1, -(nw + 15), 0, 20)
    end
end
UpdateMainFrameScale()
if Camera then table.insert(activeConnections, Camera:GetPropertyChangedSignal("ViewportSize"):Connect(UpdateMainFrameScale)) end

do local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame; local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame end

local titleBar = Instance.new("Frame"); titleBar.Name = "TitleBar"; titleBar.Size = UDim2.new(1, 0, 0, 38); titleBar.BackgroundColor3 = Colors.SidebarBg; titleBar.BorderSizePixel = 0; titleBar.Parent = mainFrame
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

local brandTitle = Instance.new("TextLabel"); brandTitle.Size = UDim2.new(0, 150, 1, 0); brandTitle.Position = UDim2.new(0, 36, 0, 0); brandTitle.BackgroundTransparency = 1; brandTitle.Font = Enum.Font.GothamBold; brandTitle.Text = "IDENTICAL"; brandTitle.TextColor3 = Colors.PurplePrimary; brandTitle.TextSize = 14; brandTitle.TextXAlignment = Enum.TextXAlignment.Left; brandTitle.Parent = titleBar
local gameSubtitle = Instance.new("TextLabel"); gameSubtitle.Size = UDim2.new(0, 200, 1, 0); gameSubtitle.Position = UDim2.new(0, 118, 0, 0); gameSubtitle.BackgroundTransparency = 1; gameSubtitle.Font = Enum.Font.Gotham; gameSubtitle.Text = "HEAVYWEIGHT FISHING V1.6"; gameSubtitle.TextColor3 = Colors.PurpleMuted; gameSubtitle.TextSize = 10; gameSubtitle.TextXAlignment = Enum.TextXAlignment.Left; gameSubtitle.Parent = titleBar

local winControls = Instance.new("Frame"); winControls.Size = UDim2.new(0, 60, 1, 0); winControls.Position = UDim2.new(1, -65, 0, 0); winControls.BackgroundTransparency = 1; winControls.Parent = titleBar
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 24, 0, 24); minBtn.Position = UDim2.new(0, 4, 0.5, -12); minBtn.BackgroundColor3 = Colors.ControlBg; minBtn.Font = Enum.Font.GothamBold; minBtn.Text = "[-]"; minBtn.TextColor3 = Colors.PurplePrimary; minBtn.TextSize = 11; minBtn.BorderSizePixel = 0; minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 4)
local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 24, 0, 24); closeBtn.Position = UDim2.new(0, 32, 0.5, -12); closeBtn.BackgroundColor3 = Colors.ControlBg; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Text = "[X]"; closeBtn.TextColor3 = Colors.AccentRed; closeBtn.TextSize = 11; closeBtn.BorderSizePixel = 0; closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

do
    local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = mainFrame.Position
            input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    titleBar.InputChanged:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            local cam = Workspace.CurrentCamera or Camera
            local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
            -- 使用绝对坐标 + 简单边界限制，避免 Scale/Offset 混合导致位置异常
            local absX = startPos.X.Scale * vp.X + startPos.X.Offset + delta.X
            local absY = startPos.Y.Scale * vp.Y + startPos.Y.Offset + delta.Y
            -- 限制主窗口不要完全拖出屏幕（保留至少 60px 可见）
            local frameW = mainFrame.AbsoluteSize.X > 0 and mainFrame.AbsoluteSize.X or 700
            local frameH = mainFrame.AbsoluteSize.Y > 0 and mainFrame.AbsoluteSize.Y or 480
            absX = math.clamp(absX, -frameW + 60, vp.X - 60)
            absY = math.clamp(absY, -frameH + 40, vp.Y - 40)
            mainFrame.Position = UDim2.new(0, absX, 0, absY)
        end
    end))
end

local bodyFrame = Instance.new("Frame"); bodyFrame.Name = "Body"; bodyFrame.Size = UDim2.new(1, 0, 1, -62); bodyFrame.Position = UDim2.new(0, 0, 0, 38); bodyFrame.BackgroundTransparency = 1; bodyFrame.Parent = mainFrame

local sidebar = Instance.new("Frame"); sidebar.Name = "Sidebar"; sidebar.Size = UDim2.new(0, 140, 1, 0); sidebar.BackgroundColor3 = Colors.SidebarBg; sidebar.BorderSizePixel = 0; sidebar.Parent = bodyFrame
do local d = Instance.new("Frame"); d.Size = UDim2.new(0, 1, 1, 0); d.Position = UDim2.new(1, -1, 0, 0); d.BackgroundColor3 = Colors.Divider; d.BorderSizePixel = 0; d.Parent = sidebar end

local searchBox = Instance.new("TextBox"); searchBox.Name = "SearchBar"; searchBox.Size = UDim2.new(1, -16, 0, 26); searchBox.Position = UDim2.new(0, 8, 0, 8); searchBox.BackgroundColor3 = Colors.InputBg; searchBox.Font = Enum.Font.Gotham; searchBox.PlaceholderText = "搜索功能..."; searchBox.PlaceholderColor3 = Colors.TextMuted; searchBox.Text = ""; searchBox.TextColor3 = Colors.TextWhite; searchBox.TextSize = 11; searchBox.TextXAlignment = Enum.TextXAlignment.Left; searchBox.BorderSizePixel = 0; searchBox.ClearTextOnFocus = false; searchBox.Parent = sidebar
do
    local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = searchBox
    Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0, 6)
    local sStroke = Instance.new("UIStroke", searchBox); sStroke.Color = Colors.BorderSubtle; sStroke.Thickness = 1
    searchBox.Focused:Connect(function() TweenService:Create(sStroke, TweenInfo.new(0.15), {Color = Colors.PurpleAccent}):Play() end)
    searchBox.FocusLost:Connect(function() TweenService:Create(sStroke, TweenInfo.new(0.15), {Color = Colors.BorderSubtle}):Play() end)
end

local rowSearchIndex = {}
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = searchBox.Text:lower()
    for _, item in ipairs(rowSearchIndex) do
        if q == "" or item.query:find(q, 1, true) then item.frame.Visible = true else item.frame.Visible = false end
    end
end)

local navList = Instance.new("ScrollingFrame"); navList.Name = "NavList"; navList.Size = UDim2.new(1, 0, 1, -44); navList.Position = UDim2.new(0, 0, 0, 42); navList.BackgroundTransparency = 1; navList.BorderSizePixel = 0; navList.ScrollBarThickness = 2; navList.ScrollBarImageColor3 = Colors.BorderSubtle; navList.CanvasSize = UDim2.new(0, 0, 0, 0); navList.AutomaticCanvasSize = Enum.AutomaticSize.Y; navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout"); nl.SortOrder = Enum.SortOrder.LayoutOrder; nl.Padding = UDim.new(0, 4); nl.Parent = navList
    local np = Instance.new("UIPadding"); np.PaddingTop = UDim.new(0, 6); np.PaddingLeft = UDim.new(0, 8); np.PaddingRight = UDim.new(0, 8); np.Parent = navList
end

local contentArea = Instance.new("Frame"); contentArea.Name = "ContentArea"; contentArea.Size = UDim2.new(1, -140, 1, 0); contentArea.Position = UDim2.new(0, 140, 0, 0); contentArea.BackgroundTransparency = 1; contentArea.Parent = bodyFrame
local tabFrames = {}; local tabButtons = {}

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
local footerBrand = Instance.new("TextLabel"); footerBrand.Size = UDim2.new(0, 260, 1, 0); footerBrand.Position = UDim2.new(0, 12, 0, 0); footerBrand.BackgroundTransparency = 1; footerBrand.Font = Enum.Font.Gotham; footerBrand.Text = "Heavyweight Fishing | V1.6"; footerBrand.TextColor3 = Colors.TextMuted; footerBrand.TextSize = 10; footerBrand.TextXAlignment = Enum.TextXAlignment.Left; footerBrand.Parent = footerBar
local footerKey = Instance.new("TextLabel"); footerKey.Size = UDim2.new(0, 280, 1, 0); footerKey.Position = UDim2.new(1, -292, 0, 0); footerKey.BackgroundTransparency = 1; footerKey.Font = Enum.Font.Gotham; footerKey.Text = "[R-CTRL] 菜单 | [END] 停止"; footerKey.TextColor3 = Colors.TextMuted; footerKey.TextSize = 10; footerKey.TextXAlignment = Enum.TextXAlignment.Right; footerKey.Parent = footerBar

local isUiAnimating = false

local function OpenUI()
    if not mainFrame then return end
    isUiAnimating = true
    UpdateMainFrameScale()
    mainFrame.Visible = true
    if floatingCrescent then floatingCrescent.Visible = false end
    
    pcall(function()
        local targetScale = mainFrameScale.Scale
        mainFrameScale.Scale = targetScale * 0.88
        mainFrame.BackgroundTransparency = 0.25
        TweenService:Create(mainFrameScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Scale = targetScale
        }):Play()
        TweenService:Create(mainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 0
        }):Play()
    end)
    task.delay(0.22, function()
        isUiAnimating = false
        if mainFrame then mainFrame.BackgroundTransparency = 0 end
    end)
end

local function CloseUI()
    if not mainFrame then return end
    isUiAnimating = true
    pcall(function()
        TweenService:Create(mainFrameScale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Scale = mainFrameScale.Scale * 0.88
        }):Play()
        TweenService:Create(mainFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            BackgroundTransparency = 0.4
        }):Play()
    end)
    task.delay(0.18, function()
        if mainFrame then
            mainFrame.Visible = false
            mainFrame.BackgroundTransparency = 0
            if mainFrameScale then mainFrameScale.Scale = Config.UIScale or 0.75 end
        end
        if floatingCrescent then
            floatingCrescent.Visible = true
            pcall(function()
                floatingCrescent.Size = UDim2.new(0, 36, 0, 36)
                TweenService:Create(floatingCrescent, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                    Size = UDim2.new(0, 48, 0, 48)
                }):Play()
            end)
        end
        isUiAnimating = false
    end)
end

ToggleUiVisibility = function()
    if mainFrame and mainFrame.Visible then
        CloseUI()
    else
        OpenUI()
    end
end

minBtn.MouseButton1Click:Connect(ToggleUiVisibility)
if minBtn.Activated then minBtn.Activated:Connect(ToggleUiVisibility) end

closeBtn.MouseButton1Click:Connect(UnloadScript)
if closeBtn.Activated then closeBtn.Activated:Connect(UnloadScript) end

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
    if indexSearch ~= false then table.insert(rowSearchIndex, {frame = row, query = (labelText .. " " .. (descText or "")):lower()}) end
    return row
end

local function createToggleRow(parent, labelText, descText, initialVal, callback, configKey, indexSearch)
    if type(initialVal) == "function" then indexSearch = callback; callback = initialVal; initialVal = false end
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
    btn.MouseButton1Click:Connect(function() state = not state; updateVisuals(); if type(callback) == "function" then callback(state) end end)
    local ctrl = {frame = row, Set = function(val, silent) state = not not val; updateVisuals(); if not silent and type(callback) == "function" then callback(state) end end, Get = function() return state end}
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

local function createSliderRow(parent, labelText, descText, minVal, maxVal, initialVal, isFloat, suffix, callback, configKey, indexSearch)
    local row = createBaseRow(parent, labelText, descText, indexSearch)
    local currentVal = initialVal or minVal; suffix = suffix or ""
    local container = Instance.new("Frame"); container.Size = UDim2.new(0, 180, 0, 36); container.Position = UDim2.new(1, -180, 0.5, -18); container.BackgroundTransparency = 1; container.Parent = row
    local valLabel = Instance.new("TextLabel"); valLabel.Size = UDim2.new(0, 68, 1, 0); valLabel.Position = UDim2.new(1, -68, 0, 0); valLabel.BackgroundTransparency = 1; valLabel.Font = Enum.Font.GothamBold; valLabel.TextColor3 = Colors.PurplePrimary; valLabel.TextSize = 11; valLabel.TextXAlignment = Enum.TextXAlignment.Right; valLabel.Parent = container
    local touchArea = Instance.new("Frame"); touchArea.Size = UDim2.new(1, -74, 1, 0); touchArea.Position = UDim2.new(0, 0, 0, 0); touchArea.BackgroundTransparency = 1; touchArea.ClipsDescendants = false; touchArea.Parent = container
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, 0, 0, 6); track.Position = UDim2.new(0, 0, 0.5, -3); track.BackgroundColor3 = Colors.ControlBg; track.BorderSizePixel = 0; track.Parent = touchArea
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local fill = Instance.new("Frame"); fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = Colors.PurpleAccent; fill.BorderSizePixel = 0; fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame"); knob.Size = UDim2.new(0, 14, 0, 14); knob.BackgroundColor3 = Colors.PurpleAccent; knob.BorderSizePixel = 0; knob.Parent = touchArea
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local function updateVisual(val)
        local pct = math.clamp((val - minVal) / (maxVal - minVal), 0, 1)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, -7, 0.5, -7)
        valLabel.Text = isFloat and string.format("%.2f", val)..suffix or tostring(math.floor(val))..suffix
    end
    updateVisual(currentVal)
    local sliding = false
    local function updateFromX(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local val = minVal + (maxVal - minVal) * rel
        if not isFloat then val = math.floor(val + 0.5) end
        currentVal = val; updateVisual(currentVal)
        if type(callback) == "function" then callback(val) end
    end
    touchArea.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            local p = row
            while p and not p:IsA("ScrollingFrame") do p = p.Parent end
            if p then p.ScrollingEnabled = false end
            updateFromX(input.Position.X)
        end
    end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then updateFromX(input.Position.X) end
    end))
    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            sliding = false
            local p = row
            while p and not p:IsA("ScrollingFrame") do p = p.Parent end
            if p then p.ScrollingEnabled = true end
        end
    end))
    local ctrl = { frame = row, Set = function(val, silent) currentVal = math.clamp(tonumber(val) or minVal, minVal, maxVal); updateVisual(currentVal); if not silent and type(callback) == "function" then callback(currentVal) end end }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

local function createDropdownRow(parent, labelText, descText, options, initialVal, callback, configKey, indexSearch)
    if type(options) == "table" and type(initialVal) == "function" then indexSearch = callback; callback = initialVal; initialVal = options[1] end
    local selected = initialVal or options[1]
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = true; row.Parent = parent
    local rl = Instance.new("UIListLayout"); rl.SortOrder = Enum.SortOrder.LayoutOrder; rl.Padding = UDim.new(0, 4); rl.Parent = row
    local header = Instance.new("Frame"); header.Size = UDim2.new(1, 0, 0, 42); header.BackgroundTransparency = 1; header.Parent = row
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = header
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -145, 1, 0); tf.BackgroundTransparency = 1; tf.BorderSizePixel = 0; tf.Parent = header
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
    local ctrl = {
        frame = row,
        Set = function(opt, silent)
            selected = opt
            ddBtn.Text = tostring(opt) .. "  v"
            for oN, b in pairs(optButtons) do
                b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg
                b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite
                b.Text = (oN == opt and "> " or "   ") .. tostring(oN)
            end
            if not silent and type(callback) == "function" then callback(opt) end
        end,
        Get = function() return selected end,
        Refresh = function(newOpts)
            if type(newOpts) == "table" and #newOpts > 0 then
                populate(newOpts)
                if not optButtons[selected] then
                    selected = newOpts[1]
                    ddBtn.Text = tostring(selected) .. "  v"
                    if type(callback) == "function" then callback(selected) end
                end
            end
        end
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

local function createButtonRow(parent, labelText, descText, btnText, callback, indexSearch)
    if type(descText) == "function" then indexSearch = btnText; callback = descText; btnText = "执行"; descText = "" elseif type(btnText) == "function" then indexSearch = callback; callback = btnText; btnText = descText; descText = "" end
    local row = createBaseRow(parent, labelText, descText, indexSearch)
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = btnText or "执行"; btn.TextColor3 = Colors.PurplePrimary; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    btn.MouseEnter:Connect(function() TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite}):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg, TextColor3 = Colors.PurplePrimary}):Play() end)
    btn.MouseButton1Click:Connect(function() if type(callback) == "function" then pcall(callback) end end)
    return btn
end

local function createInfoRow(parent, labelText, valueText, indexSearch)
    local row = createBaseRow(parent, labelText, "", indexSearch)
    local vl = Instance.new("TextLabel"); vl.Size = UDim2.new(0, 140, 1, 0); vl.Position = UDim2.new(1, -140, 0, 0); vl.BackgroundTransparency = 1; vl.Font = Enum.Font.GothamBold; vl.Text = valueText; vl.TextColor3 = Colors.PurplePrimary; vl.TextSize = 11; vl.TextXAlignment = Enum.TextXAlignment.Right; vl.Parent = row
    return {frame = row, Set = function(nv) vl.Text = nv end}
end

local tabDashboard = CreateTab("仪表盘")
local tabFishing   = CreateTab("钓鱼")
local tabBoss      = CreateTab("Boss")
local tabGod       = CreateTab("神灵")
local tabQuests    = CreateTab("任务")
local tabShop      = CreateTab("商店与制作")
local tabTeleports = CreateTab("传送")
local tabVisuals   = CreateTab("视觉")
local tabPlayer    = CreateTab("移动")
local tabProfiles  = CreateTab("配置文件")

local DashUI = {}

local function SafeTeleport(targetCF)
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = targetCF
        root.AssemblyLinearVelocity = Vector3.zero
        if Config.PositionLock then lockedCFrame = targetCF end
        return true
    end
    return false
end

do
-- Dashboard Cards Construction

if navList:FindFirstChildOfClass("UIListLayout") then
    navList:FindFirstChildOfClass("UIListLayout").FillDirection = Enum.FillDirection.Vertical
end

SwitchTab("仪表盘")

-- ==========================================
-- 仪表盘卡片构建
-- ==========================================
local dashLayout = Instance.new("UIListLayout")
dashLayout.Padding = UDim.new(0, 8)
dashLayout.SortOrder = Enum.SortOrder.LayoutOrder
dashLayout.Parent = tabDashboard

local function CreateDashRow()
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 72)
    row.BackgroundTransparency = 1
    row.Parent = tabDashboard
    local rl = Instance.new("UIListLayout")
    rl.FillDirection = Enum.FillDirection.Horizontal
    rl.HorizontalAlignment = Enum.HorizontalAlignment.Left
    rl.SortOrder = Enum.SortOrder.LayoutOrder
    rl.Padding = UDim.new(0, 8)
    rl.Parent = row
    return row
end

local function CreateDashCard(parent, title, icon, color)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0.333, -6, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 16, 32)
    card.BorderSizePixel = 0
    card.Parent = parent
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", card)
    stroke.Color = Color3.fromRGB(48, 36, 72)
    stroke.Thickness = 1
    stroke.Transparency = 0.35

    card.MouseEnter:Connect(function()
        TweenService:Create(card, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(26, 21, 42)}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.15), {Color = Colors.PurpleAccent, Transparency = 0.1}):Play()
    end)
    card.MouseLeave:Connect(function()
        TweenService:Create(card, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(20, 16, 32)}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.15), {Color = Color3.fromRGB(48, 36, 72), Transparency = 0.35}):Play()
    end)

    local titleRow = Instance.new("Frame")
    titleRow.Size = UDim2.new(1, -14, 0, 18)
    titleRow.Position = UDim2.new(0, 8, 0, 8)
    titleRow.BackgroundTransparency = 1
    titleRow.Parent = card

    local iconLbl = Instance.new("TextLabel")
    iconLbl.Size = UDim2.new(0, 18, 1, 0)
    iconLbl.BackgroundTransparency = 1
    iconLbl.Font = Enum.Font.GothamBold
    iconLbl.Text = icon
    iconLbl.TextSize = 13
    iconLbl.TextXAlignment = Enum.TextXAlignment.Left
    iconLbl.Parent = titleRow

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -22, 1, 0)
    titleLbl.Position = UDim2.new(0, 20, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.Gotham
    titleLbl.Text = title
    titleLbl.TextColor3 = Colors.TextMuted
    titleLbl.TextSize = 11
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
    titleLbl.Parent = titleRow

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.new(1, -14, 0, 28)
    valLbl.Position = UDim2.new(0, 8, 0, 32)
    valLbl.BackgroundTransparency = 1
    valLbl.Font = Enum.Font.GothamBold
    valLbl.Text = "..."
    valLbl.TextColor3 = color
    valLbl.TextSize = 15
    valLbl.TextXAlignment = Enum.TextXAlignment.Left
    valLbl.TextTruncate = Enum.TextTruncate.AtEnd
    valLbl.Parent = card

    return valLbl
end

local row1 = CreateDashRow()
DashUI.lblRod = CreateDashCard(row1, "当前鱼竿", "🎣", Colors.PurplePrimary)
DashUI.lblBait = CreateDashCard(row1, "当前鱼饵", "🪱", Colors.AccentOrange)
DashUI.lblPos = CreateDashCard(row1, "当前位置", "📍", Colors.AccentBlue)

local row2 = CreateDashRow()
DashUI.lblHangTime = CreateDashCard(row2, "挂机时长", "⏳", Colors.AccentYellow)
DashUI.lblTotalFish = CreateDashCard(row2, "总钓获", "🐟", Colors.PurplePrimary)
DashUI.lblFishSpeed = CreateDashCard(row2, "钓鱼速度", "⚡", Colors.AccentGreen)

local row3 = CreateDashRow()
DashUI.lblCash = CreateDashCard(row3, "当前资金", "💰", Colors.AccentGreen)
DashUI.lblCashSpeed = CreateDashCard(row3, "赚钱速度", "📈", Colors.AccentGreen)
DashUI.lblGems = CreateDashCard(row3, "当前宝石", "💎", Colors.AccentBlue)

local row4 = CreateDashRow()
DashUI.lblTicket = CreateDashCard(row4, "任务券", "🎫", Colors.AccentOrange)
DashUI.lblQuest = CreateDashCard(row4, "今日完成", "📜", Colors.AccentYellow)
DashUI.lblBag = CreateDashCard(row4, "背包容量", "🎒", Colors.TextWhite)

local row5 = CreateDashRow()
DashUI.lblPing = CreateDashCard(row5, "网络延迟", "📶", Colors.AccentGreen)
local lblEmpty1 = CreateDashCard(row5, "版本", "✨", Colors.PurpleMuted)
lblEmpty1.Text = "IDENTICAL V1.6"
local lblEmpty2 = CreateDashCard(row5, "状态", "🟢", Colors.AccentGreen)
lblEmpty2.Text = "极速挂机中"

-- ==========================================
-- 钓鱼页面
-- ==========================================
end -- end of Dashboard Cards Construction

local allRods = {
    {name = "Wooden Rod", price = 0, power = 8, luck = 1}, {name = "Bamboo Rod", price = 100, power = 11, luck = 5},
    {name = "Iron Hook Rod", price = 500, power = 13, luck = 10}, {name = "Steel Rod", price = 1000, power = 17, luck = 11},
    {name = "Enchanted Steel Rod", price = 2000, power = 19, luck = 12}, {name = "Alloy Rod", price = 5000, power = 22, luck = 5},
    {name = "Emerald Rod", price = 10000, power = 25, luck = 10}, {name = "Bloodfire Rod", price = 20000, power = 27, luck = 10},
    {name = "Shadow Rod", price = 60000, power = 29, luck = 22}, {name = "Triple Steel Rod", price = 100000, power = 32, luck = 20},
    {name = "Golden Rod", price = 200000, power = 35, luck = 22}, {name = "Grandmaster Steel Rod", price = 250000, power = 37, luck = 10},
    {name = "Grandmaster Golden Rod", price = 1000000, power = 45, luck = 30}, {name = "Steel Spine Rod", price = 1500000, power = 48, luck = 20},
    {name = "Inferno Rod", price = 1500000, power = 48, luck = 18}, {name = "Golden Spine Rod", price = 2000000, power = 51, luck = 21},
    {name = "Platinum Spine Rod", price = 3000000, power = 54, luck = 25}, {name = "Diamond Spine Rod", price = 4000000, power = 56, luck = 25},
    {name = "Gravisteel Rod", price = 5000000, power = 58, luck = 15}, {name = "Auric Gravity Rod", price = 6000000, power = 60, luck = 10},
    {name = "Inferno Gravity Rod", price = 7000000, power = 62, luck = 20}, {name = "Cryo Gravity Rod", price = 8000000, power = 65, luck = 36},
    {name = "Thunder Thorn Rod", price = 10000000, power = 67, luck = 30}, {name = "Starlight Rod", price = 60000000, power = 83, luck = 15},
}

do
createCategoryHeader(tabFishing, "实时账户与钓鱼统计")
local statsCard = createCardGroup(tabFishing)
DashUI.infoEquippedRod = createInfoRow(statsCard, "已装备鱼竿", "无")
DashUI.infoEquippedBait = createInfoRow(statsCard, "已装备鱼饵", "无")
DashUI.infoFishCaught = createInfoRow(statsCard, "总捕获鱼数", "0")
DashUI.infoCash = createInfoRow(statsCard, "当前现金", "$0")

createCategoryHeader(tabFishing, "核心钓鱼自动化")
local fishCard = createCardGroup(tabFishing)
createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿", Config.AutoCast, function(v) Config.AutoCast = v end, "AutoCast")
createSliderRow(fishCard, "抛竿延迟", "检测/抛竿频率", 0.1, 10.0, Config.CastDelay, true, "秒", function(v) Config.CastDelay = v end, "CastDelay")


createToggleRow(fishCard, "锁定当前坐标", "防止钓鱼或刷Boss时被击退偏移水面(传送自动同步)", Config.PositionLock, function(v)
    Config.PositionLock = v
    if v then
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then lockedCFrame = root.CFrame; ShowNotification("位置锁定", "已锁定当前钓鱼坐标！", "SUCCESS") end
    else
        lockedCFrame = nil
    end
end, "PositionLock")
createToggleRow(fishCard, "锚定条(小游戏)", "自动居中条并保证捕获进度", Config.AnchorBar, function(v) Config.AnchorBar = v end, "AnchorBar")
createToggleRow(fishCard, "秒钓/快速捕获(InstantCatch)", "小游戏期间双倍速率推进捕获进度条", Config.InstantCatch, function(v) Config.InstantCatch = v end, "InstantCatch")
createToggleRow(fishCard, "自动技能(爆发DPS)", "收线时严格按顺序从第1个勾选技能起手轮换", Config.AutoSkills, function(v) Config.AutoSkills = v; currentSkillIndex = 1 end, "AutoSkills")
createToggleRow(fishCard, "使用技能 Z", "勾选后才会释放 Z 技能", Config.SkillZ, function(v) Config.SkillZ = v; currentSkillIndex = 1 end, "SkillZ")
createToggleRow(fishCard, "使用技能 X", "勾选后才会释放 X 技能", Config.SkillX, function(v) Config.SkillX = v; currentSkillIndex = 1 end, "SkillX")
createToggleRow(fishCard, "使用技能 C", "勾选后才会释放 C 技能", Config.SkillC, function(v) Config.SkillC = v; currentSkillIndex = 1 end, "SkillC")
createToggleRow(fishCard, "使用技能 V", "勾选后才会释放 V 技能", Config.SkillV, function(v) Config.SkillV = v; currentSkillIndex = 1 end, "SkillV")

do
    local orderRow = createBaseRow(fishCard, "技能释放顺序", "标准顺序为 Z,X,C,V（每次进小游戏固定从第1个起手）", true)
    local orderBox = Instance.new("TextBox")
    orderBox.Size = UDim2.new(0, 130, 0, 24)
    orderBox.Position = UDim2.new(1, -130, 0.5, -12)
    orderBox.BackgroundColor3 = Colors.ControlBg
    orderBox.Font = Enum.Font.GothamBold
    orderBox.Text = Config.SkillOrder or "Z,X,C,V"
    orderBox.PlaceholderText = "Z,X,C,V"
    orderBox.TextColor3 = Colors.PurplePrimary
    orderBox.PlaceholderColor3 = Colors.TextMuted
    orderBox.TextSize = 11
    orderBox.BorderSizePixel = 0
    orderBox.ClearTextOnFocus = false
    orderBox.Parent = orderRow
    Instance.new("UICorner", orderBox).CornerRadius = UDim.new(0, 4)
    orderBox.FocusLost:Connect(function()
        local text = orderBox.Text:gsub("%s+", ""):upper()
        if text == "" then text = "Z,X,C,V" end
        Config.SkillOrder = text
        orderBox.Text = text
        currentSkillIndex = 1
        ShowNotification("技能顺序", "已更新为: " .. text .. " (已重置从第1个起手)", "SUCCESS")
    end)
    UIControls["SkillOrder"] = { Set = function(val) orderBox.Text = tostring(val) end }
end

createSliderRow(fishCard, "技能间隔", "技能释放间隔（建议 1.2~1.5 秒打满伤害，防伤害不足超时）", 0.5, 5.0, Config.SkillInterval, true, "秒", function(v) Config.SkillInterval = v end, "SkillInterval")
createToggleRow(fishCard, "自动猛击/暴击", "提示时自动点击猛击按钮造成巨大伤害", Config.AutoSlam, function(v) Config.AutoSlam = v end, "AutoSlam")
createToggleRow(fishCard, "自动充能耐久", "提示时自动充能鱼线耐久", Config.AutoCharge, function(v) Config.AutoCharge = v end, "AutoCharge")

end -- end of fishCard

do
createCategoryHeader(tabFishing, "智能自动装备引擎")
local equipCard = createCardGroup(tabFishing)
createToggleRow(equipCard, "自动装备最佳鱼饵", "装备背包中运气最高的鱼饵", Config.AutoEquipBestBait, function(v) Config.AutoEquipBestBait = v end, "AutoEquipBestBait")
createToggleRow(equipCard, "自动装备最佳鱼竿", "装备你拥有的最高威力鱼竿", Config.AutoEquipBestRod, function(v) Config.AutoEquipBestRod = v end, "AutoEquipBestRod")
createToggleRow(equipCard, "自动装备最佳宝珠", "装备最高等级精华宝珠", Config.AutoEquipBestOrb, function(v) Config.AutoEquipBestOrb = v end, "AutoEquipBestOrb")

local rodNameList = {}
for _, r in ipairs(allRods) do table.insert(rodNameList, r.name) end
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait"}

createDropdownRow(equipCard, "方案1：鱼竿", "方案1的鱼竿", rodNameList, Config.Loadout1_Rod, function(v) Config.Loadout1_Rod = v end, "Loadout1_Rod")
createDropdownRow(equipCard, "方案1：鱼饵", "方案1的鱼饵", baitNameList, Config.Loadout1_Bait, function(v) Config.Loadout1_Bait = v end, "Loadout1_Bait")
createButtonRow(equipCard, "立即装备方案1", "装备方案1选择的鱼竿和鱼饵", "装备#1", function()
    task.spawn(function()
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
        if pData then
            local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout1_Rod)
            local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
            if isOwned then
                if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout1_Rod) end
                ShowNotification("方案1", "已装备鱼竿: " .. Config.Loadout1_Rod, "SUCCESS")
            else ShowNotification("方案1", "你还没有拥有 " .. Config.Loadout1_Rod .. " ！", "WARN") end
            local bFolder = pData.Bait:FindFirstChild(Config.Loadout1_Bait)
            if bFolder and bFolder.Value > 0 then
                if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout1_Bait) end
                ShowNotification("方案1", "已装备鱼饵: " .. Config.Loadout1_Bait, "SUCCESS")
            else ShowNotification("方案1", "你的背包中 " .. Config.Loadout1_Bait .. " 数量为0。", "WARN") end
        end
    end)
end)

createDropdownRow(equipCard, "方案2：鱼竿", "方案2的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end, "Loadout2_Rod")
createDropdownRow(equipCard, "方案2：鱼饵", "方案2的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end, "Loadout2_Bait")
createButtonRow(equipCard, "立即装备方案2", "装备方案2选择的鱼竿和鱼饵", "装备#2", function()
    task.spawn(function()
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
        if pData then
            local rFolder = pData.FishingRodInventory:FindFirstChild(Config.Loadout2_Rod)
            local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
            if isOwned then
                if Events:FindFirstChild("EquipFishingRod") then Events.EquipFishingRod:InvokeServer(Config.Loadout2_Rod) end
                ShowNotification("方案2", "已装备鱼竿: " .. Config.Loadout2_Rod, "SUCCESS")
            else ShowNotification("方案2", "你还没有拥有 " .. Config.Loadout2_Rod .. " ！", "WARN") end
            local bFolder = pData.Bait:FindFirstChild(Config.Loadout2_Bait)
            if bFolder and bFolder.Value > 0 then
                if Events:FindFirstChild("EquipBait") then Events.EquipBait:InvokeServer(Config.Loadout2_Bait) end
                ShowNotification("方案2", "已装备鱼饵: " .. Config.Loadout2_Bait, "SUCCESS")
            else ShowNotification("方案2", "你的背包中 " .. Config.Loadout2_Bait .. " 数量为0。", "WARN") end
        end
    end)
end)

end -- end of equipCard scope

local craftMaterialFish = {
    ["Mountain Fish"] = true, ["Catfish"] = true, ["Crimson Catfish"] = true,
    ["Scarlet Fish"] = true, ["Elder Scarlet Fish"] = true, ["Octoparasitic Fish"] = true,
    ["Tiger Mirefish"] = true, ["Mirage Lanternfish"] = true, ["Golden Guardian Fish"] = true,
    ["Frost Kingfish"] = true, ["Frost Queenfish"] = true, ["Rainbow Dragonfish"] = true,
    ["Sanguine Fish"] = true
}

-- 精准稀有/Boss鱼词库（避免使用过宽泛的单字如 king/spirit 误锁普通鱼）
local rareBossKeywords = {
    "wraith", "octoparasitic", "overlord", "heavenpiercer",
    "primordial", "colossal tigerfish", "ascended perch", "warbringer shark",
    "crimson electric eel", "golden guardian", "frost kingfish", "frost queenfish",
    "rainbow dragonfish", "sanguine fish", "starlight", "leviathan", "kraken"
}

-- 提取纯鱼名：自动剥离游戏在背包实例名后追加的 " | 1849724.37" 唯一ID/重量后缀
local function GetPureFishName(rawName)
    if not rawName then return "" end
    local s = tostring(rawName)
    local beforePipe = s:match("^(.-)%s*|")
    if beforePipe and #beforePipe > 0 then
        return beforePipe:match("^%s*(.-)%s*$")
    end
    return s:match("^%s*(.-)%s*$")
end

-- 检查鱼实例是否已经在服务端处于上锁/收藏状态（兼容多种子节点命名、布尔/数值类型与Attribute）
local function IsFishItemFavorited(item)
    if not item then return false end
    local favNames = {"Favorite", "Favorited", "Favourite", "Favourited", "Locked", "Lock", "IsFavorite", "IsLocked", "Star", "Starred"}
    for i = 1, #favNames do
        local ch = item:FindFirstChild(favNames[i])
        if ch then
            if ch:IsA("ValueBase") then
                local v = ch.Value
                if v == true or v == 1 or tostring(v):lower() == "true" then return true end
            else
                return true
            end
        end
    end
    for i = 1, #favNames do
        local attr = item:GetAttribute(favNames[i])
        if attr == true or attr == 1 or tostring(attr):lower() == "true" then
            return true
        end
    end
    return false
end

-- 编译通配符/前缀/后缀/精确/包含匹配器（全小写缓存，零重复编译开销）
local patternCache = {}
local function BuildFishMatcher(patternStr)
    if not patternStr then return nil end
    local raw = tostring(patternStr):match("^%s*(.-)%s*$")
    local pipePrefix = raw:match("^(.-)%s*|%s*[%d%.]+$")
    if pipePrefix and #pipePrefix > 0 then
        raw = pipePrefix:match("^%s*(.-)%s*$")
    end
    if raw == "" then return nil end
    local lower = raw:lower()
    local cached = patternCache[lower]
    if cached then return cached end

    local mode, body
    if lower:sub(1, 1) == "=" then
        mode, body = "exact", lower:sub(2):match("^%s*(.-)%s*$")
    elseif lower:sub(1, 1) == "^" then
        mode, body = "prefix", lower:sub(2):match("^%s*(.-)%s*$")
    elseif lower:sub(-1) == "$" then
        mode, body = "suffix", lower:sub(1, -2):match("^%s*(.-)%s*$")
    elseif lower:find("[%*%?]") then
        mode, body = "wildcard", lower
    else
        mode, body = "contains", lower
    end

    if not body or body == "" then return nil end

    local matcher
    if mode == "exact" then
        matcher = function(pureLower, fullLower)
            return pureLower == body or fullLower == body
        end
    elseif mode == "prefix" then
        matcher = function(pureLower)
            return pureLower:sub(1, #body) == body
        end
    elseif mode == "suffix" then
        matcher = function(pureLower)
            return #pureLower >= #body and pureLower:sub(-#body) == body
        end
    elseif mode == "contains" then
        matcher = function(pureLower, fullLower)
            return pureLower:find(body, 1, true) ~= nil or fullLower:find(body, 1, true) ~= nil
        end
    else
        local escaped = body:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
        escaped = escaped:gsub("%*", ".*"):gsub("%?", ".")
        local luaPattern = "^" .. escaped .. "$"
        matcher = function(pureLower)
            return pureLower:find(luaPattern) ~= nil
        end
    end

    patternCache[lower] = matcher
    return matcher
end

local cachedRuleMatchers = {}
local cachedRuleSource = nil
local function GetRuleMatchers()
    local src = Config.CustomProtectedFish or ""
    if src == cachedRuleSource then return cachedRuleMatchers end
    table.clear(cachedRuleMatchers)
    for token in string.gmatch(src, "([^,，;；\n\r]+)") do
        local m = BuildFishMatcher(token)
        if m then table.insert(cachedRuleMatchers, m) end
    end
    cachedRuleSource = src
    return cachedRuleMatchers
end

local function ShouldProtectFishItem(item)
    if not item then return false end
    local fullName = item.Name
    local pureName = GetPureFishName(fullName)
    local pureLower = pureName:lower()
    local fullLower = fullName:lower()

    if Config.MaterialFarming and craftMaterialFish[pureName] then
        return true
    end
    if Config.AutoProtectRareBossFish then
        for _, kw in ipairs(rareBossKeywords) do
            if pureLower:find(kw, 1, true) then return true end
        end
        local rarityObj = item:FindFirstChild("Rarity") or item:FindFirstChild("Tier")
        if rarityObj and rarityObj.Value then
            local rStr = tostring(rarityObj.Value):lower()
            if rStr:find("mythic") or rStr:find("secret") or rStr:find("boss") or rStr:find("legend") or rStr:find("divine") or rStr:find("supreme") then
                return true
            end
        end
    end
    if Config.AutoFavouriteFish then
        if Config.FavouriteFishName and Config.FavouriteFishName ~= "" then
            local targetPure = GetPureFishName(Config.FavouriteFishName):lower()
            if targetPure ~= "" and pureLower == targetPure then
                return true
            end
        end
        local matchers = GetRuleMatchers()
        for i = 1, #matchers do
            if matchers[i](pureLower, fullLower) then
                return true
            end
        end
    end
    return false
end

-- 防翻转稳定上锁引擎（彻底解决 Toggle 远程事件在延迟下反复“上锁→解锁→上锁”闪烁问题）：
-- 1) FavoriteItem 是 Toggle 开关，一旦发送上锁请求，必须留出充足的 8 秒同步冷却期（lastLockSentAt），绝不在飞行途中补发第 2 次把锁解开！
-- 2) 一旦检测到某条鱼已处于上锁状态（IsFishItemFavorited == true），记入 knownLockedUntil（15秒保护记忆），绝不清空发送冷却或重复触发！
-- 3) 每次扫描最多只给 3 条未锁保护鱼发送请求，避免 14 条鱼同帧并发撑爆服务端队列导致高延迟。
local lastLockSentAt = setmetatable({}, { __mode = "k" })
local knownLockedUntil = setmetatable({}, { __mode = "k" })
local lastLockSentByName = {}

local function IsEffectivelyLocked(item, now)
    now = now or tick()
    if IsFishItemFavorited(item) then
        knownLockedUntil[item] = now + 15.0
        return true
    end
    local untilTime = knownLockedUntil[item]
    if untilTime and now < untilTime then
        return true
    end
    return false
end

local function TryFavoriteProtectedFish(pData)
    if not pData or not Events then return 0 end
    local favRem = Events:FindFirstChild("FavoriteItem")
    local now = tick()
    local unfavProtectedCount = 0
    local sentThisPass = 0
    local containers = { pData:FindFirstChild("Inventory"), pData:FindFirstChild("Hotbar") }

    for _, folder in ipairs(containers) do
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                local isFav = IsEffectivelyLocked(item, now)
                if not isFav and ShouldProtectFishItem(item) then
                    unfavProtectedCount = unfavProtectedCount + 1
                    if favRem and sentThisPass < 3 then
                        local lastInstTime = lastLockSentAt[item] or 0
                        local lastNameTime = lastLockSentByName[item.Name] or 0
                        local lastSent = math.max(lastInstTime, lastNameTime)
                        -- 8秒防抖窗口：确保前一次 Toggle 请求早已在服务端结算完毕，绝不连发两次导致解锁
                        if (now - lastSent) >= 8.0 then
                            lastLockSentAt[item] = now
                            lastLockSentByName[item.Name] = now
                            sentThisPass = sentThisPass + 1
                            pcall(function() favRem:FireServer(item) end)
                        end
                    end
                end
            end
        end
    end

    for k in pairs(lastLockSentAt) do
        if not k or not k.Parent then lastLockSentAt[k] = nil end
    end
    for k in pairs(knownLockedUntil) do
        if not k or not k.Parent then knownLockedUntil[k] = nil end
    end
    return unfavProtectedCount
end

-- 铁壁级安全卖鱼（带 protectedPureSet 二次校验 + 3.5秒上锁稳定等待）：
local isSellingInProgress = false
local useNameForSingleSell = false

local function SafeSellAllFish(pData)
    if isSellingInProgress or not Events or not Events:FindFirstChild("SellFish") then return end
    isSellingInProgress = true
    task.spawn(function()
        pcall(function()
            local sellRem = Events:FindFirstChild("SellFish")
            if not sellRem or not pData then return end

            local needProtection = Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish
            local unlockedProtectedNames = {}
            local protectedPureSet = {}
            local sellableItems = {}

            local function ScanBagState()
                table.clear(unlockedProtectedNames)
                table.clear(protectedPureSet)
                table.clear(sellableItems)
                local now = tick()
                local containers = { pData:FindFirstChild("Inventory"), pData:FindFirstChild("Hotbar") }
                for _, folder in ipairs(containers) do
                    if folder then
                        for _, item in ipairs(folder:GetChildren()) do
                            local pure = GetPureFishName(item.Name)
                            local pureLow = pure:lower()
                            if ShouldProtectFishItem(item) then
                                protectedPureSet[pureLow] = true
                                -- 必须真实检测到服务端已上锁（IsFishItemFavorited），才允许放行 SellFish("All")
                                if not IsFishItemFavorited(item) then
                                    table.insert(unlockedProtectedNames, pure)
                                end
                            elseif not IsEffectivelyLocked(item, now) then
                                table.insert(sellableItems, item)
                            end
                        end
                    end
                end
            end

            if needProtection then
                TryFavoriteProtectedFish(pData)
                ScanBagState()
                if #unlockedProtectedNames > 0 then
                    local waitStart = tick()
                    while tick() - waitStart < 3.5 do
                        task.wait(0.35)
                        TryFavoriteProtectedFish(pData)
                        ScanBagState()
                        if #unlockedProtectedNames == 0 then break end
                    end
                end
            else
                ScanBagState()
            end

            if #unlockedProtectedNames == 0 then
                -- 确认背包中所有保护鱼均已 100% 真实挂上锁标（无任何未锁保护鱼），安全调用 All
                sellRem:FireServer("All")
            else
                -- 存在尚未完成上锁的保护鱼：绝对禁止调用 SellFish("All")！
                -- 对普通可卖鱼逐条出售，且在出售前做二次实时校验（既不在 protectedPureSet 中、也不命中保护规则、也未上锁）
                local batchParamMode = useNameForSingleSell and "name" or "instance"
                local probeSwitched = false
                local successCount = 0

                for idx, normalItem in ipairs(sellableItems) do
                    if normalItem and normalItem.Parent then
                        local pureLow = GetPureFishName(normalItem.Name):lower()
                        local isSafeToSell = (not protectedPureSet[pureLow])
                            and (not ShouldProtectFishItem(normalItem))
                            and (not IsEffectivelyLocked(normalItem, tick()))
                        if isSafeToSell then
                            local arg = (batchParamMode == "name") and normalItem.Name or normalItem
                            pcall(function() sellRem:FireServer(arg) end)
                            task.wait(0.06)
                            if idx == 1 and normalItem.Parent and not probeSwitched then
                                probeSwitched = true
                                batchParamMode = (batchParamMode == "instance") and "name" or "instance"
                                local altArg = (batchParamMode == "name") and normalItem.Name or normalItem
                                pcall(function() sellRem:FireServer(altArg) end)
                                task.wait(0.06)
                            end
                            if not normalItem.Parent then
                                successCount = successCount + 1
                            end
                        end
                    end
                end

                if successCount >= 2 or (successCount == 1 and #sellableItems == 1) then
                    useNameForSingleSell = (batchParamMode == "name")
                end

                ShowNotification(
                    "防误卖保护已拦截全体出售",
                    string.format("保护鱼 [%s] 正在等待服务端上锁确认，已阻止 SellAll 并仅出售普通鱼！", unlockedProtectedNames[1]),
                    "WARN",
                    5
                )
            end
        end)
        task.wait(0.2)
        isSellingInProgress = false
    end)
end

local function TriggerPrompt(prompt)
    if fireproximityprompt then fireproximityprompt(prompt) else pcall(function() prompt:InputHoldBegin(); task.wait(prompt.HoldDuration + 0.05); prompt:InputHoldEnd() end) end
end

local RunTicketQuestAction

do
createCategoryHeader(tabFishing, "经济与出售 (通配符+防误卖铁壁系统)")
local sellCard = createCardGroup(tabFishing)
createToggleRow(sellCard, "自动卖鱼", "定期安全出售普通鱼（发现未锁保护鱼时自动拦截SellAll）", Config.AutoSell, function(v) Config.AutoSell = v end, "AutoSell")
createSliderRow(sellCard, "出售间隔(秒)", "出售鱼的频率 (10秒-60分钟)", 10, 3600, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end, "SellInterval")
createButtonRow(sellCard, "立即出售并传送到娜娜", "传送到娜娜处并安全出售非保护鱼（绝不误卖保护名单）", "立即出售", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    if SafeTeleport(CFrame.new(-203.5, 7.3, 107.1)) then
        task.wait(0.3)
        SafeSellAllFish(pData)
    end
end)

local baseFishList = {
    "Wraith Orca", "Colossal Tigerfish", "Heavenpiercer Turtle", "Golden Guardian Fish",
    "Crimson Electric Eel", "Frost Kingfish", "Frost Queenfish",
    "Ascended Perch", "Primordial Kunfish Overlord", "Warbringer Shark",
    "Mountain Fish", "Tiger Mirefish", "Mirage Lanternfish",
    "Octoparasitic Fish", "Rainbow Dragonfish", "Sanguine Fish",
    "Crimson Catfish", "Elder Scarlet Fish", "Scarlet Fish", "Catfish"
}

createToggleRow(sellCard, "自动保护所有Boss/神话稀有鱼", "智能识别Wraith/Orca/Overlord/King等稀有鱼并防卖", Config.AutoProtectRareBossFish, function(v) Config.AutoProtectRareBossFish = v end, "AutoProtectRareBossFish")
createToggleRow(sellCard, "材料收集模式", "自动保护所有制作神话鱼饵所需的材料鱼", Config.MaterialFarming, function(v) Config.MaterialFarming = v end, "MaterialFarming")
createToggleRow(sellCard, "启用自定义多选收藏名单", "启用下方通配符/前缀/关键词保护名单", Config.AutoFavouriteFish, function(v) Config.AutoFavouriteFish = v end, "AutoFavouriteFish")

local favDropdownCtrl = createDropdownRow(sellCard, "选择鱼类 (可扫描背包刷新)", "自动剥离后缀ID显示纯鱼名，方便直接添加", baseFishList, Config.FavouriteFishName, function(v) Config.FavouriteFishName = v end, "FavouriteFishName")

local customFavBox = nil
do
    local listRow = createBaseRow(sellCard, "受保护鱼名单 (支持前缀/通配符)", "支持 Wraith*(前缀)、*Orca(后缀)、=Catfish(精确)、wr(包含)，逗号分隔", true)
    listRow.Size = UDim2.new(1, 0, 0, 56)
    customFavBox = Instance.new("TextBox")
    customFavBox.Size = UDim2.new(0, 220, 0, 40)
    customFavBox.Position = UDim2.new(1, -220, 0.5, -20)
    customFavBox.BackgroundColor3 = Colors.ControlBg
    customFavBox.Font = Enum.Font.GothamBold
    customFavBox.Text = Config.CustomProtectedFish or ""
    customFavBox.PlaceholderText = "例: Wraith*, *Orca, =Catfish"
    customFavBox.TextColor3 = Colors.PurplePrimary
    customFavBox.PlaceholderColor3 = Colors.TextMuted
    customFavBox.TextSize = 10
    customFavBox.TextWrapped = true
    customFavBox.MultiLine = false
    customFavBox.BorderSizePixel = 0
    customFavBox.ClearTextOnFocus = false
    customFavBox.Parent = listRow
    Instance.new("UICorner", customFavBox).CornerRadius = UDim.new(0, 4)
    customFavBox.FocusLost:Connect(function()
        Config.CustomProtectedFish = customFavBox.Text
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
        TryFavoriteProtectedFish(pData)
        ShowNotification("保护名单已生效", "当前规则: " .. (Config.CustomProtectedFish ~= "" and Config.CustomProtectedFish or "空"), "SUCCESS")
    end)
    UIControls["CustomProtectedFish"] = { Set = function(val) customFavBox.Text = tostring(val or "") end }
end

createButtonRow(sellCard, "[预览] 预览保护名单命中结果", "扫描背包，显示哪些鱼会被保护(不卖)、哪些鱼会被出售", "预览结果", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    if not pData then
        ShowNotification("预览失败", "未读取到玩家背包数据。", "WARN")
        return
    end
    TryFavoriteProtectedFish(pData)
    local protList, sellList = {}, {}
    local containers = { pData:FindFirstChild("Inventory"), pData:FindFirstChild("Hotbar") }
    for _, folder in ipairs(containers) do
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                local pure = GetPureFishName(item.Name)
                local lockedTag = IsFishItemFavorited(item) and "[已锁]" or "[防卖保护]"
                if ShouldProtectFishItem(item) or IsFishItemFavorited(item) then
                    table.insert(protList, pure .. lockedTag)
                else
                    table.insert(sellList, pure)
                end
            end
        end
    end
    local function SummarizeList(tbl)
        if #tbl == 0 then return "无" end
        local maxShow = math.min(#tbl, 6)
        local slice = {}
        for i = 1, maxShow do table.insert(slice, tbl[i]) end
        local str = table.concat(slice, ", ")
        if #tbl > maxShow then str = str .. string.format(" 等%d条", #tbl) end
        return str
    end
    ShowNotification(
        "背包防误卖预览结果",
        string.format("保护不卖(%d条): %s\n将会出售(%d条): %s", #protList, SummarizeList(protList), #sellList, SummarizeList(sellList)),
        "SUCCESS",
        8
    )
end)

createButtonRow(sellCard, "[+] 将上方选中鱼加入保护名单", "把下拉框选中的纯鱼名追加到多选不卖名单中", "加入名单", function()
    local target = GetPureFishName(Config.FavouriteFishName)
    if not target or target == "" then return end
    local cur = Config.CustomProtectedFish or ""
    for token in string.gmatch(cur, "([^,，;；]+)") do
        if GetPureFishName(token):lower() == target:lower() then
            ShowNotification("已在名单中", target .. " 已经在保护名单里了！", "WARN")
            return
        end
    end
    Config.CustomProtectedFish = (cur == "" and target) or (cur .. "," .. target)
    if customFavBox then customFavBox.Text = Config.CustomProtectedFish end
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    TryFavoriteProtectedFish(pData)
    ShowNotification("已添加保护", "已将 [" .. target .. "] 加入防误卖保护名单！", "SUCCESS")
end)

createButtonRow(sellCard, "[刷新] 扫描当前背包鱼类到下拉框", "读取背包和快捷栏现有鱼类(自动去除数字后缀ID)", "扫描背包", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    local merged = {}
    local seen = {}
    if pData then
        for _, folderName in ipairs({"Inventory", "Hotbar"}) do
            local f = pData:FindFirstChild(folderName)
            if f then
                for _, item in ipairs(f:GetChildren()) do
                    local pure = GetPureFishName(item.Name)
                    if pure ~= "" and not seen[pure] then
                        seen[pure] = true
                        table.insert(merged, pure)
                    end
                end
            end
        end
    end
    for _, name in ipairs(baseFishList) do
        if not seen[name] then
            seen[name] = true
            table.insert(merged, name)
        end
    end
    if favDropdownCtrl and favDropdownCtrl.Refresh then
        favDropdownCtrl.Refresh(merged)
    end
    ShowNotification("扫描完成", string.format("已刷新纯鱼名列表（共 %d 种可选）！", #merged), "SUCCESS")
end)

-- ==========================================
-- Boss 页面
-- ==========================================
createCategoryHeader(tabBoss, "无名章鱼寄生体(隐藏Boss)")
local octoCard = createCardGroup(tabBoss)
createToggleRow(octoCard, "自动小游戏(节奏机器人)", "零延迟锁定Boss判定条、完美触发QTE节奏与交互", Config.OctoAutoMinigame, function(v) Config.OctoAutoMinigame = v end, "OctoAutoMinigame")
createToggleRow(octoCard, "Boss战自动技能(Z/X/C/V)", "打章鱼或Boss小游戏时自动按顺序释放勾选技能", Config.BossAutoSkills, function(v) Config.BossAutoSkills = v end, "BossAutoSkills")
createButtonRow(octoCard, "传送到章鱼寄生体", "传送到海洋隐藏Boss浮标(自动同步坐标锁)", "传送", function()
    if SafeTeleport(CFrame.new(1608.2, 5.0, -218.3)) then ShowNotification("已传送", "已到达无名章鱼寄生体海洋浮标！", "SUCCESS") end
end)
createButtonRow(octoCard, "传送到渔夫之地", "传送到地下渔夫领域(自动同步坐标锁)", "传送", function()
    if SafeTeleport(CFrame.new(112.5, -330.0, -30.8)) then ShowNotification("已传送", "已到达地下渔夫之地！", "SUCCESS") end
end)

createCategoryHeader(tabBoss, "Boss自动化")
local bossFarmCard = createCardGroup(tabBoss)
createToggleRow(bossFarmCard, "自动刷Boss(Enzo)", "自动前往Enzo竞技场并循环触发挑战", Config.AutoFarmBoss, function(v) Config.AutoFarmBoss = v end, "AutoFarmBoss")
createToggleRow(bossFarmCard, "自动刷隐藏Boss", "自动制作/保护无名鱼饵并前往章鱼浮标垂钓", Config.AutoFarmSecretBoss, function(v) Config.AutoFarmSecretBoss = v end, "AutoFarmSecretBoss")
createButtonRow(bossFarmCard, "传送到Enzo", "传送到Enzo竞技场(自动同步坐标锁)", "传送", function()
    if SafeTeleport(CFrame.new(-115.3, 9.2, 1349.5)) then ShowNotification("已传送", "已到达Enzo！", "SUCCESS") end
end)

-- ==========================================
-- 神灵页面
-- ==========================================
createCategoryHeader(tabGod, "神灵交互与状态")
local godCard = createCardGroup(tabGod)
createButtonRow(godCard, "检查神灵状态", "检查活跃祝福(黄/蓝/绿)", "检查状态", function()
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    if pData and pData:FindFirstChild("GodSpirit") then
        local y = pData.GodSpirit:FindFirstChild("Yellow") and pData.GodSpirit.Yellow.Value or false
        local b = pData.GodSpirit:FindFirstChild("Blue") and pData.GodSpirit.Blue.Value or false
        local g = pData.GodSpirit:FindFirstChild("Green") and pData.GodSpirit.Green.Value or false
        ShowNotification("神灵状态", string.format("黄色: %s | 蓝色: %s | 绿色: %s", y and "活跃" or "关闭", b and "活跃" or "关闭", g and "活跃" or "关闭"), "SUCCESS", 6)
    else ShowNotification("神灵", "无法读取神灵数据。", "WARN") end
end)
createToggleRow(godCard, "自动祈祷神灵", "在神灵祭坛时自动祈祷", Config.AutoPrayGodSpirit, function(v) Config.AutoPrayGodSpirit = v end, "AutoPrayGodSpirit")
createButtonRow(godCard, "传送到神灵祭坛", "传送到神灵祭坛(战场岛)", "传送", function()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local spirit = (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("Spirit")) or (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("God"))
        if spirit then root.CFrame = spirit:GetPivot() + Vector3.new(0, 3, 5); ShowNotification("神灵", "已传送到神灵祭坛！", "SUCCESS")
        else root.CFrame = CFrame.new(1245.7, 19.3, -133.4); ShowNotification("神灵", "已传送到神社位置！", "SUCCESS") end
    end
end)

createButtonRow(godCard, "立即祈祷神灵", "与神灵祭坛提示交互", "祈祷", function()
    local sp = (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("Spirit")) or (Workspace:FindFirstChild("NPC") and Workspace.NPC:FindFirstChild("God"))
    if sp then
        local found = false
        for _, d in ipairs(sp:GetDescendants()) do if d:IsA("ProximityPrompt") then TriggerPrompt(d); found = true end end
        if found then ShowNotification("神灵", "已在祭坛祈祷神灵！", "SUCCESS") else ShowNotification("神灵", "在神灵上未找到近距离提示。", "WARN") end
    else ShowNotification("神灵", "此服务器中神灵未生成。", "WARN") end
end)

createCategoryHeader(tabGod, "服务器跳转引擎")
local hopCard = createCardGroup(tabGod)
createToggleRow(hopCard, "为神灵跳服务器", "若当前服无神灵，自动跳服寻找", Config.AutoServerHopGod, function(v) Config.AutoServerHopGod = v end, "AutoServerHopGod")
createToggleRow(hopCard, "为茅山跳服务器", "若当前服无茅山，自动跳服寻找", Config.AutoServerHopMaoshan, function(v) Config.AutoServerHopMaoshan = v end, "AutoServerHopMaoshan")
createToggleRow(hopCard, "为道士跳服务器", "若当前服无道士，自动跳服寻找", Config.AutoServerHopTaoist, function(v) Config.AutoServerHopTaoist = v end, "AutoServerHopTaoist")
createButtonRow(hopCard, "立即跳服务器", "立即跳转到随机不同服务器", "跳转", ServerHop)

-- ==========================================
-- 任务页面 (V2.0 安全单发 + 严格状态检测 + 零UI误触)
-- ==========================================
local questAlternateToggle = false

local function SafeFireOneRemote(rem, ...)
    if not rem then return false end
    local args = {...}
    if rem:IsA("RemoteEvent") then
        pcall(function() rem:FireServer(unpack(args)) end)
        return true
    elseif rem:IsA("RemoteFunction") then
        -- 必须使用 task.spawn 异步调用，防止在 Heartbeat 中同步 yield 报错中断
        task.spawn(function() pcall(function() rem:InvokeServer(unpack(args)) end) end)
        return true
    end
    return false
end

RunTicketQuestAction = function(diffArg, manualNotify)
    if not Events then return false end
    diffArg = diffArg or (QuestDiffMap[Config.TicketDifficulty] or "Easy")
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))

    -- 1) 严格的状态检测（区分：未接取 / 进行中未完成 / 已完成可领奖 / 无本地数据）
    local needAccept = false
    local canClaim = false
    local hasData = false

    if pData then
        local qFolder = pData:FindFirstChild("TicketQuest") or pData:FindFirstChild("Quests") or pData:FindFirstChild("Quest")
        if qFolder then
            hasData = true
            local prog = qFolder:FindFirstChild("Progress") or qFolder:FindFirstChild("Current") or qFolder:FindFirstChild("Amount")
            local goal = qFolder:FindFirstChild("Goal") or qFolder:FindFirstChild("Target") or qFolder:FindFirstChild("Max")
            local active = qFolder:FindFirstChild("Active") or qFolder:FindFirstChild("Accepted")

            local isActive = true
            if active and active:IsA("ValueBase") then
                isActive = (active.Value == true or active.Value == 1)
            end

            if not isActive then
                needAccept = true
                canClaim = false
            elseif prog and goal and prog:IsA("ValueBase") and goal:IsA("ValueBase") then
                local pVal = tonumber(prog.Value) or 0
                local gVal = tonumber(goal.Value) or 0
                if gVal <= 0 then
                    needAccept = true
                    canClaim = false
                elseif pVal >= gVal then
                    needAccept = false
                    canClaim = true
                else
                    -- 任务正在进行中且进度未满：静默等待钓鱼完成，绝不乱发提交包
                    needAccept = false
                    canClaim = false
                end
            elseif prog and prog:IsA("ValueBase") then
                -- 有进度节点但无目标节点：保守静默，仅手动点击时强制尝试
                needAccept = false
                canClaim = manualNotify and true or false
            else
                needAccept = true
                canClaim = false
            end
        end
    end

    -- 若本地 pData 没有暴露任务文件夹，则使用奇偶轮替单发；手动点击时若无明确未接取状态则允许直接尝试提交
    if not hasData then
        questAlternateToggle = not questAlternateToggle
        if questAlternateToggle then
            canClaim = true
            needAccept = false
        else
            needAccept = true
            canClaim = true
        end
    elseif manualNotify and not needAccept then
        canClaim = true
    end

    -- 2) 严格单发机制（手动与自动共享安全单发逻辑，每次最多只发 1 个请求并立即 break）
    local sent = false

    if needAccept then
        local acceptNames = {"AcceptQuest", "StartQuest", "GetQuest", "TakeQuest", "TicketQuest"}
        for _, aName in ipairs(acceptNames) do
            local rem = Events:FindFirstChild(aName)
            if rem then
                sent = SafeFireOneRemote(rem, "Ticket", diffArg)
                break
            end
        end
    end

    if not sent and (canClaim or needAccept) then
        local claimNames = {"ClaimQuest", "SubmitQuest", "CompleteQuest", "Quest", "TicketQuest"}
        for _, cName in ipairs(claimNames) do
            local rem = Events:FindFirstChild(cName)
            if rem then
                sent = SafeFireOneRemote(rem, "Ticket", diffArg)
                break
            end
        end
    end

    if manualNotify then
        ShowNotification("票据任务", string.format("已安全单发 [%s] 票据任务请求！", diffArg), "SUCCESS")
    end
    return sent
end

createCategoryHeader(tabQuests, "票据任务 (V2.0 安全单发+防封限流)")
local questCard = createCardGroup(tabQuests)
createToggleRow(questCard, "自动票据任务", "智能检测进度并单发接取/提交（8秒安全间隔防限流）", Config.AutoTicketQuest, function(v) Config.AutoTicketQuest = v end, "AutoTicketQuest")
createDropdownRow(questCard, "难度", "票据任务难度", {"简单", "困难"}, Config.TicketDifficulty, function(v) Config.TicketDifficulty = v end, "TicketDifficulty")
createButtonRow(questCard, "手动提交/接取(简单)", "立即安全单发简单任务请求", "执行简单", function()
    RunTicketQuestAction("Easy", true)
end)
createButtonRow(questCard, "手动提交/接取(困难)", "立即安全单发困难任务请求", "执行困难", function()
    RunTicketQuestAction("Hard", true)
end)
createButtonRow(questCard, "[诊断] 查看任务接口与数据结构", "扫描 Events 与 Data 中的真实任务节点名称并弹窗显示", "扫描结构", function()
    local remNames = {}
    if Events then
        for _, ch in ipairs(Events:GetChildren()) do
            local cn = ch.Name:lower()
            if cn:find("quest") or cn:find("ticket") or cn:find("daily") or cn:find("claim") or cn:find("reward") then
                table.insert(remNames, ch.Name .. "(" .. ch.ClassName:gsub("Remote", "") .. ")")
            end
        end
    end
    local dataNames = {}
    local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
    if pData then
        for _, ch in ipairs(pData:GetChildren()) do
            local cn = ch.Name:lower()
            if cn:find("quest") or cn:find("ticket") or cn:find("daily") or cn:find("task") then
                local valStr = ch:IsA("ValueBase") and ("=" .. tostring(ch.Value)) or ("[" .. #ch:GetChildren() .. "子项]")
                table.insert(dataNames, ch.Name .. valStr)
            end
        end
    end
    local msg = string.format("事件: %s\n数据: %s", (#remNames > 0 and table.concat(remNames, ", ") or "无"), (#dataNames > 0 and table.concat(dataNames, ", ") or "无"))
    if setclipboard then pcall(function() setclipboard(msg) end) end
    ShowNotification("任务结构诊断 (已复制)", msg, "SUCCESS", 10)
end)

createCategoryHeader(tabQuests, "每日任务与奖励 (带防封延迟与冷却锁)")
local dailyCard = createCardGroup(tabQuests)
local isClaimingDailyTask = false
local isClaimingDailySign = false

createButtonRow(dailyCard, "领取每日任务", "按 0.5 秒安全间隔顺序领取已完成的每日任务", "领取", function()
    if isClaimingDailyTask then
        ShowNotification("每日任务", "正在顺序领取中，请稍候...", "WARN")
        return
    end
    isClaimingDailyTask = true
    task.spawn(function()
        if Events then
            local claimRem = Events:FindFirstChild("ClaimQuest") or Events:FindFirstChild("ClaimDailyQuest")
            if claimRem then
                for i = 1, 4 do
                    SafeFireOneRemote(claimRem, "Daily", i)
                    task.wait(0.5)
                end
                ShowNotification("每日任务", "已安全顺序尝试领取每日任务！", "SUCCESS")
            else
                ShowNotification("每日任务", "未找到每日任务远程事件。", "WARN")
            end
        end
        task.wait(2.0)
        isClaimingDailyTask = false
    end)
end)

createToggleRow(dailyCard, "自动领取每日奖励", "每 5 分钟按安全间隔顺序尝试领取 1~7 天签到奖励", Config.AutoClaimDaily, function(v) Config.AutoClaimDaily = v end, "AutoClaimDaily")
createSliderRow(dailyCard, "领取延迟", "领取天数之间的安全间隔", 0.3, 2.0, Config.DailyClaimDelay, true, "秒", function(v) Config.DailyClaimDelay = v end, "DailyClaimDelay")

createButtonRow(dailyCard, "立即尝试领取签到", "按顺序间隔尝试领取 1 到 7 天签到奖励", "领取签到", function()
    if isClaimingDailySign then
        ShowNotification("每日奖励", "正在顺序领取签到中，请勿连点！", "WARN")
        return
    end
    isClaimingDailySign = true
    task.spawn(function()
        if Events then
            local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
            if dailyRem then
                local delaySec = math.max(0.4, tonumber(Config.DailyClaimDelay) or 0.5)
                for day = 1, 7 do
                    SafeFireOneRemote(dailyRem, day)
                    task.wait(delaySec)
                end
                ShowNotification("每日奖励", "已按安全间隔顺序尝试领取 1~7 天！", "SUCCESS")
            end
        end
        task.wait(3.0)
        isClaimingDailySign = false
    end)
end)

-- ==========================================
-- 商店页面
-- ==========================================
createCategoryHeader(tabShop, "鱼饵制作与购买")
local baitCard = createCardGroup(tabShop)
local craftBaits = {"Nameless Bait", "Frost Bait", "Rainbow Bait"}
createDropdownRow(baitCard, "制作目标", "要制作的神话Boss鱼饵", craftBaits, Config.CraftBaitName, function(v) Config.CraftBaitName = v end, "CraftBaitName")
createSliderRow(baitCard, "制作数量", "每批制作数量", 1, 10, Config.CraftAmount, false, "", function(v) Config.CraftAmount = v end, "CraftAmount")
createToggleRow(baitCard, "自动制作鱼饵", "材料存在时持续制作", Config.AutoCraftBait, function(v) Config.AutoCraftBait = v end, "AutoCraftBait")
local buyBaits = {"Ancestral Bait", "Elite Bait", "Corrupted Essence Bait", "Crude Mash Bait", "Basic Bait"}
createDropdownRow(baitCard, "购买目标", "从八长购买的鱼饵", buyBaits, Config.BuyBaitName, function(v) Config.BuyBaitName = v end, "BuyBaitName")
createSliderRow(baitCard, "购买数量", "每次购买的数量", 1, 50, Config.BuyBaitAmount, false, "", function(v) Config.BuyBaitAmount = v end, "BuyBaitAmount")
createSliderRow(baitCard, "库存阈值", "库存低于此值时才自动购买", 5, 50, Config.BuyBaitThreshold, false, "", function(v) Config.BuyBaitThreshold = v end, "BuyBaitThreshold")
createToggleRow(baitCard, "自动购买鱼饵", "库存低于阈值时自动补货鱼饵", Config.AutoBuyBait, function(v) Config.AutoBuyBait = v end, "AutoBuyBait")

-- ==========================================
-- 传送页面
-- ==========================================
createCategoryHeader(tabTeleports, "自定义传送点 (支持单独删除)")
local customTPCard = createCardGroup(tabTeleports)

local inputRow = Instance.new("Frame"); inputRow.Size = UDim2.new(1, 0, 0, 42); inputRow.BackgroundColor3 = Colors.RowNormal; inputRow.BorderSizePixel = 0; inputRow.Parent = customTPCard
local box = Instance.new("TextBox"); box.Size = UDim2.new(1, -115, 0, 26); box.Position = UDim2.new(0, 10, 0.5, -13); box.BackgroundColor3 = Colors.InputBg; box.Font = Enum.Font.Gotham; box.PlaceholderText = "输入传送名称..."; box.PlaceholderColor3 = Colors.TextMuted; box.Text = ""; box.TextColor3 = Colors.TextWhite; box.TextSize = 11; box.BorderSizePixel = 0; box.ClearTextOnFocus = false; box.Parent = inputRow
do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = box end
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)

local saveBtn = Instance.new("TextButton"); saveBtn.Size = UDim2.new(0, 90, 0, 26); saveBtn.Position = UDim2.new(1, -100, 0.5, -13); saveBtn.BackgroundColor3 = Colors.PurpleAccent; saveBtn.Font = Enum.Font.GothamBold; saveBtn.Text = "保存当前位置"; saveBtn.TextColor3 = Colors.TextWhite; saveBtn.TextSize = 11; saveBtn.BorderSizePixel = 0; saveBtn.Parent = inputRow
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 4)

local coordRow = Instance.new("Frame"); coordRow.Size = UDim2.new(1, 0, 0, 42); coordRow.BackgroundColor3 = Colors.RowNormal; coordRow.BorderSizePixel = 0; coordRow.Parent = customTPCard
local coordLabel = Instance.new("TextLabel"); coordLabel.Size = UDim2.new(1, -115, 1, 0); coordLabel.Position = UDim2.new(0, 10, 0, 0); coordLabel.BackgroundTransparency = 1; coordLabel.Font = Enum.Font.GothamBold; coordLabel.Text = "当前坐标: 点击右侧读取"; coordLabel.TextColor3 = Colors.AccentGreen; coordLabel.TextSize = 11; coordLabel.TextXAlignment = Enum.TextXAlignment.Left; coordLabel.Parent = coordRow
local readBtn = Instance.new("TextButton"); readBtn.Size = UDim2.new(0, 90, 0, 26); readBtn.Position = UDim2.new(1, -100, 0.5, -13); readBtn.BackgroundColor3 = Colors.ControlBg; readBtn.Font = Enum.Font.GothamBold; readBtn.Text = "读取当前 XYZ"; readBtn.TextColor3 = Colors.PurplePrimary; readBtn.TextSize = 11; readBtn.BorderSizePixel = 0; readBtn.Parent = coordRow
Instance.new("UICorner", readBtn).CornerRadius = UDim.new(0, 4)

local listFrame = Instance.new("Frame"); listFrame.Size = UDim2.new(1, 0, 0, 0); listFrame.AutomaticSize = Enum.AutomaticSize.Y; listFrame.BackgroundTransparency = 1; listFrame.Parent = customTPCard
local ll = Instance.new("UIListLayout"); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = listFrame

local function RefreshCustomTPs()
    for _, child in ipairs(listFrame:GetChildren()) do if child:IsA("Frame") then child:Destroy() end end
    for i, tp in ipairs(CustomTPs) do
        local coordText = string.format("X: %.1f | Y: %.1f | Z: %.1f", tp.x, tp.y, tp.z)
        local row = createBaseRow(listFrame, tp.name, coordText, false)
        
        local tpBtn = Instance.new("TextButton")
        tpBtn.Size = UDim2.new(0, 62, 0, 24)
        tpBtn.Position = UDim2.new(1, -92, 0.5, -12)
        tpBtn.BackgroundColor3 = Colors.ControlBg
        tpBtn.Font = Enum.Font.GothamBold
        tpBtn.Text = "传送"
        tpBtn.TextColor3 = Colors.PurplePrimary
        tpBtn.TextSize = 11
        tpBtn.BorderSizePixel = 0
        tpBtn.Parent = row
        Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)
        tpBtn.MouseButton1Click:Connect(function()
            local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if root then root.CFrame = CFrame.new(tp.x, tp.y + 3, tp.z); ShowNotification("传送", "已到达: " .. tp.name, "SUCCESS") end
        end)

        local delBtn = Instance.new("TextButton")
        delBtn.Size = UDim2.new(0, 24, 0, 24)
        delBtn.Position = UDim2.new(1, -24, 0.5, -12)
        delBtn.BackgroundColor3 = Colors.ControlBg
        delBtn.Font = Enum.Font.GothamBold
        delBtn.Text = "X"
        delBtn.TextColor3 = Colors.AccentRed
        delBtn.TextSize = 11
        delBtn.BorderSizePixel = 0
        delBtn.Parent = row
        Instance.new("UICorner", delBtn).CornerRadius = UDim.new(0, 4)
        delBtn.MouseButton1Click:Connect(function()
            table.remove(CustomTPs, i)
            SaveCustomTPs()
            RefreshCustomTPs()
            ShowNotification("已删除", "已移除传送点: " .. tp.name, "WARN")
        end)
    end
end

readBtn.MouseButton1Click:Connect(function()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local p = root.Position
        coordLabel.Text = string.format("X: %.1f | Y: %.1f | Z: %.1f", p.X, p.Y, p.Z)
        ShowNotification("当前坐标", string.format("X: %.1f, Y: %.1f, Z: %.1f", p.X, p.Y, p.Z), "SUCCESS")
    end
end)
saveBtn.MouseButton1Click:Connect(function()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local name = box.Text; if name == "" then name = "自定义点 " .. (#CustomTPs + 1) end
        local p = root.Position
        table.insert(CustomTPs, {name = name, x = p.X, y = p.Y, z = p.Z})
        SaveCustomTPs(); RefreshCustomTPs(); box.Text = ""
        coordLabel.Text = string.format("已保存: X:%.1f, Y:%.1f, Z:%.1f", p.X, p.Y, p.Z)
        ShowNotification("保存成功", string.format("已记录 %s 坐标:\nX: %.1f | Y: %.1f | Z: %.1f", name, p.X, p.Y, p.Z), "SUCCESS", 5)
    end
end)
createButtonRow(customTPCard, "清空所有自定义点", "删除所有已保存的自定义坐标", "清空", function()
    CustomTPs = {}; SaveCustomTPs(); RefreshCustomTPs(); coordLabel.Text = "当前坐标: 点击右侧读取"; ShowNotification("已清空", "所有自定义传送点已删除", "SUCCESS")
end)
RefreshCustomTPs()

end -- end of Sell/Boss/God/Quests/Shop/CustomTP scope

local liveNPCs = { God = {pos = nil, name = "神灵", icon = "⛩️"}, Taoist = {pos = nil, name = "道士", icon = "📜"}, Maoshan = {pos = nil, name = "茅山", icon = "✨"} }
local function GetNPCPosition(npc)
    if not npc then return nil end
    local hrp = npc:FindFirstChild("HumanoidRootPart"); if hrp then return hrp.Position end
    if npc:IsA("Model") then
        local success, cf = pcall(function() return npc:GetBoundingBox() end)
        if success and cf then return cf.Position end
        local success2, pivot = pcall(function() return npc:GetPivot().Position end)
        if success2 then return pivot end
    end
    if npc:IsA("BasePart") then return npc.Position end
    local basePart = npc:FindFirstChildWhichIsA("BasePart"); if basePart then return basePart.Position end
    return nil
end

do
createCategoryHeader(tabTeleports, "特殊NPC实时传送")
local liveNPCCard = createCardGroup(tabTeleports)
local function CreateNPCRow(key, data)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.Parent = liveNPCCard
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -110, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = row
    local title = Instance.new("TextLabel"); title.Size = UDim2.new(1, 0, 0, 18); title.Position = UDim2.new(0, 0, 0, 4); title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.Text = data.icon .. " " .. data.name .. " (未检测到)"; title.TextColor3 = Colors.TextMuted; title.TextSize = 12; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = tf
    local desc = Instance.new("TextLabel"); desc.Size = UDim2.new(1, 0, 0, 14); desc.Position = UDim2.new(0, 0, 0, 22); desc.BackgroundTransparency = 1; desc.Font = Enum.Font.Gotham; desc.Text = "等待刷新..."; desc.TextColor3 = Colors.TextMuted; desc.TextSize = 10; desc.TextXAlignment = Enum.TextXAlignment.Left; desc.Parent = tf
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = "传送"; btn.TextColor3 = Colors.TextMuted; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    data.ui_title = title; data.ui_desc = desc; data.ui_btn = btn
    btn.MouseButton1Click:Connect(function()
        if data.pos then
            local char = LocalPlayer.Character; local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local dir = (root.Position - data.pos); dir = Vector3.new(dir.X, 0, dir.Z)
                if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) else dir = dir.Unit end
                local targetPos = data.pos + dir * 6 + Vector3.new(0, 10, 0)
                local rayParams = RaycastParams.new(); rayParams.FilterType = Enum.RaycastFilterType.Exclude; rayParams.FilterDescendantsInstances = {char, Workspace:FindFirstChild("IdenticalESP")}
                local rayResult = Workspace:Raycast(targetPos, Vector3.new(0, -50, 0), rayParams)
                if rayResult then targetPos = rayResult.Position + Vector3.new(0, 3, 0) else targetPos = data.pos + dir * 6 + Vector3.new(0, 3, 0) end
                SafeTeleport(CFrame.new(targetPos, data.pos))
                ShowNotification("传送成功", "已到达 " .. data.name .. " 的安全位置", "SUCCESS")
            end
        else ShowNotification("提示", "当前服务器未检测到 " .. data.name, "WARN") end
    end)
end
for key, data in pairs(liveNPCs) do CreateNPCRow(key, data) end

createCategoryHeader(tabTeleports, "岛屿进度(1-10)")
local islandCard = createCardGroup(tabTeleports)
local islands = {
    {name = "[1] 起始岛", pos = Vector3.new(-200.7, 11.1, 35.9)}, {name = "[2] 竹岛", pos = Vector3.new(-1223.0, 7.3, -24.1)},
    {name = "[3] 辐射岛", pos = Vector3.new(65.5, 8.8, 1181.3)}, {name = "[4] 主权岛", pos = Vector3.new(-1276.4, 8.8, 1239.7)},
    {name = "[5] 鲈鱼岛", pos = Vector3.new(-62.0, 11.9, -1321.4)}, {name = "[6] 冰霜岛", pos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {name = "[7] 椰子岛", pos = Vector3.new(1493.6, 9.1, -1430.6)}, {name = "[8] 琥珀岛", pos = Vector3.new(1259.4, 9.1, 1401.5)},
    {name = "[9] 战场岛", pos = Vector3.new(1393.5, 11.3, 169.6)}, {name = "[10] 雾峰岛", pos = Vector3.new(2660.2, 8.8, -86.7)},
}
for _, isl in ipairs(islands) do
    createButtonRow(islandCard, isl.name, "传送到 " .. isl.name, "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(isl.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. isl.name, "SUCCESS") end
    end)
end

createCategoryHeader(tabTeleports, "Boss竞技场与隐藏领域")
local bossRealmCard = createCardGroup(tabTeleports)
local bossRealms = {
    {name = "章鱼寄生体", pos = Vector3.new(1608.2, 5.0, -218.3)}, {name = "渔夫之地", pos = Vector3.new(112.5, -330.0, -30.8)}, {name = "Enzo竞技场", pos = Vector3.new(-115.3, 9.2, 1349.5)},
}
for _, br in ipairs(bossRealms) do
    createButtonRow(bossRealmCard, br.name, "传送到 " .. br.name, "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(br.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. br.name, "SUCCESS") end
    end)
end

createCategoryHeader(tabTeleports, "鱼竿商人商店(标迪)")
local rodDealerCard = createCardGroup(tabTeleports)
local rodDealers = {
    {name = "[1] 起始岛商人", pos = Vector3.new(-151.4, 8.7, -49.9)}, {name = "[2] 竹岛商人", pos = Vector3.new(-1236.8, 7.3, -174.1)},
    {name = "[3] 辐射岛商人", pos = Vector3.new(138.4, 9.0, 1179.7)}, {name = "[4] 主权岛商人", pos = Vector3.new(-1262.6, 8.2, 1202.2)},
    {name = "[5] 鲈鱼岛商人", pos = Vector3.new(-9.5, 9.2, -1330.0)}, {name = "[6] 冰霜岛商人", pos = Vector3.new(-1400.4, 9.2, -1490.6)},
    {name = "[7] 椰子岛商人", pos = Vector3.new(1446.0, 9.3, -1408.0)}, {name = "[8] 琥珀岛商人", pos = Vector3.new(1292.7, 8.2, 1497.4)},
}
for _, rd in ipairs(rodDealers) do
    createButtonRow(rodDealerCard, rd.name, "直接传送到鱼竿商人", "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(rd.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. rd.name, "SUCCESS") end
    end)
end

createCategoryHeader(tabTeleports, "秘密鱼竿位置")
local sRodCard = createCardGroup(tabTeleports)
local secretRods = {
    {name = "锚定鱼竿", pos = Vector3.new(-1208.5, 56.3, 1646.2)}, {name = "火焰鲨鱼竿", pos = Vector3.new(-8.4, 53.9, 6.7)},
    {name = "海妖鱼竿", pos = Vector3.new(1543.8, 73.4, 1490.9)}, {name = "升华竹竿", pos = Vector3.new(-1360.6, 140.6, 31.0)},
    {name = "生命绽放鱼竿", pos = Vector3.new(-114.9, 74.9, -1533.2)}, {name = "恶魔鱼竿", pos = Vector3.new(1181.9, 82.9, -1243.8)}
}
for _, sr in ipairs(secretRods) do
    createButtonRow(sRodCard, sr.name, "传送到秘密鱼竿位置", "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(sr.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. sr.name, "SUCCESS") end
    end)
end

createCategoryHeader(tabTeleports, "服务器与玩家传送")
local srvCard = createCardGroup(tabTeleports)

-- 玩家选择与传送（可指定具体玩家）
local selectedPlayerName = nil
local playerNameToObj = {}   -- Name -> Player

local function BuildPlayerOptions()
    local opts = {}
    playerNameToObj = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local label = p.DisplayName
            if p.DisplayName ~= p.Name then
                label = p.DisplayName .. " (@" .. p.Name .. ")"
            end
            table.insert(opts, label)
            playerNameToObj[label] = p
            playerNameToObj[p.Name] = p
            playerNameToObj[p.DisplayName] = p
        end
    end
    table.sort(opts)
    return opts
end

local playerOpts = BuildPlayerOptions()
local playerDropdown = createDropdownRow(srvCard, "选择玩家", "选择要传送过去的玩家（点击刷新更新列表）", #playerOpts > 0 and playerOpts or {"暂无其他玩家"}, playerOpts[1] or "暂无其他玩家", function(v)
    selectedPlayerName = v
end, "SelectedPlayer", false)
selectedPlayerName = playerOpts[1]  -- 初始选中第一个

createButtonRow(srvCard, "刷新玩家列表", "重新获取当前服务器所有玩家", "刷新", function()
    local opts = BuildPlayerOptions()
    if #opts == 0 then
        playerDropdown.Refresh({"暂无其他玩家"})
        selectedPlayerName = nil
        ShowNotification("玩家列表", "当前服务器没有其他玩家", "WARN")
    else
        playerDropdown.Refresh(opts)
        selectedPlayerName = opts[1]
        ShowNotification("玩家列表", "已刷新，共 " .. #opts .. " 名玩家", "SUCCESS")
    end
end)

createButtonRow(srvCard, "传送到选中玩家", "传送到你选择的玩家附近", "传送", function()
    if not selectedPlayerName or selectedPlayerName == "暂无其他玩家" then
        ShowNotification("玩家传送", "请先选择一个玩家（可先点刷新）", "WARN")
        return
    end
    local target = playerNameToObj[selectedPlayerName]
    -- 再兜底用名字匹配一次（防止列表过期）
    if not target or not target.Parent then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and (p.Name == selectedPlayerName or p.DisplayName == selectedPlayerName or (p.DisplayName .. " (@" .. p.Name .. ")") == selectedPlayerName) then
                target = p
                break
            end
        end
    end
    if not target or not target.Character or not target.Character:FindFirstChild("HumanoidRootPart") then
        ShowNotification("玩家传送", "目标玩家不存在或未加载角色，请刷新列表后重试", "ERROR")
        return
    end
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        root.CFrame = target.Character.HumanoidRootPart.CFrame + Vector3.new(0, 2, 3)
        ShowNotification("玩家传送", "已传送到 " .. (target.DisplayName or target.Name), "SUCCESS")
    else
        ShowNotification("玩家传送", "本地角色未找到", "ERROR")
    end
end)

-- 保留随机传送
local lastTpTarget = nil
createButtonRow(srvCard, "传送到随机玩家", "随机传送到当前服务器另一个玩家附近", "传送", function()
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
        if not (#targets > 1 and p == lastTpTarget) then table.insert(pool, p) end
    end
    local selected = (#pool > 0 and pool[math.random(1, #pool)]) or targets[math.random(1, #targets)]
    lastTpTarget = selected
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root and selected.Character and selected.Character:FindFirstChild("HumanoidRootPart") then
        root.CFrame = selected.Character.HumanoidRootPart.CFrame + Vector3.new(0, 2, 3)
        ShowNotification("玩家传送", "已传送到 " .. selected.DisplayName, "SUCCESS")
    end
end)

end -- end of Teleports scope

-- ==========================================
-- 视觉设置函数（移出每帧渲染循环）
-- ==========================================
ApplyLightingSettings = function()
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
        if atmo then
            atmo.Density = 0
            atmo.Haze = 0
            atmo.Glare = 0
        end
        if Camera then
            for _, d in ipairs(Camera:GetDescendants()) do
                if d:IsA("ParticleEmitter") and d.Enabled then d.Enabled = false end
            end
        end
    end
end

do
createCategoryHeader(tabVisuals, "世界与实体ESP")
local espCard = createCardGroup(tabVisuals)
createToggleRow(espCard, "神灵ESP", "高亮活跃的神灵", Config.ESP_GodSpirit, function(v) Config.ESP_GodSpirit = v end, "ESP_GodSpirit")
createToggleRow(espCard, "秘密鱼竿ESP", "高亮所有秘密鱼竿位置", Config.ESP_SecretRod, function(v) Config.ESP_SecretRod = v end, "ESP_SecretRod")
createToggleRow(espCard, "船只ESP", "高亮生成的船只", Config.ESP_Boats, function(v) Config.ESP_Boats = v end, "ESP_Boats")
createToggleRow(espCard, "茅山ESP", "高亮茅山NPC/鱼竿", Config.ESP_Maoshan, function(v) Config.ESP_Maoshan = v end, "ESP_Maoshan")
createToggleRow(espCard, "道士ESP", "高亮道士NPC/鱼竿", Config.ESP_Taoist, function(v) Config.ESP_Taoist = v end, "ESP_Taoist")
createToggleRow(espCard, "Boss ESP", "高亮活跃的Boss生成点", Config.ESP_Boss, function(v) Config.ESP_Boss = v end, "ESP_Boss")
createToggleRow(espCard, "玩家ESP", "高亮其他玩家及距离", Config.ESP_Players, function(v) Config.ESP_Players = v end, "ESP_Players")
createToggleRow(espCard, "鱼目标光圈", "收线时在钩住的鱼周围显示发光红色光圈", Config.FishRedRing, function(v) Config.FishRedRing = v end, "FishRedRing")

createCategoryHeader(tabVisuals, "光照与性能")
local perfCard = createCardGroup(tabVisuals)
createToggleRow(perfCard, "无雾无雨", "清除世界雾霾、雨粒子及闪电", Config.NoFog, function(v)
    Config.NoFog = v
    if v then
        ApplyLightingSettings()
    else
        Lighting.FogEnd = 100000; Lighting.FogStart = 0
        local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere"); if atmo then atmo.Density = 0.3; atmo.Haze = 0.5 end
    end
end, "NoFog")
createToggleRow(perfCard, "全亮", "设置最大环境亮度与可见度", Config.Fullbright, function(v)
    Config.Fullbright = v
    if v then
        ApplyLightingSettings()
    else
        Lighting.Brightness = 2; Lighting.Ambient = Color3.fromRGB(70, 70, 70); Lighting.OutdoorAmbient = Color3.fromRGB(70, 70, 70); Lighting.GlobalShadows = true
    end
end, "Fullbright")
createToggleRow(perfCard, "性能模式(低画质)", "禁用阴影并降低渲染负载", Config.PerformanceMode, function(v) Config.PerformanceMode = v; Lighting.GlobalShadows = not v end, "PerformanceMode")
createToggleRow(perfCard, "关闭3D渲染(省电挂机)", "黑屏关闭3D画面渲染，大幅降低CPU/GPU占用", Config.Disable3DRendering, function(v)
    Config.Disable3DRendering = v
    blackOutFrame.Visible = v
    pcall(function() RunService:Set3dRenderingEnabled(not v) end)
end, "Disable3DRendering")
createToggleRow(perfCard, "隐藏游戏UI", "隐藏Roblox游戏UI以获得清晰视野", Config.HideGameUI, function(v)
    Config.HideGameUI = v
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then if pg:FindFirstChild("MainGui") then pg.MainGui.Enabled = not v end; if pg:FindFirstChild("Fisher_GUI") then pg.Fisher_GUI.Enabled = not v end end
end, "HideGameUI")

-- ==========================================
-- 移动页面
-- ==========================================
createCategoryHeader(tabPlayer, "玩家移动")
local moveCard = createCardGroup(tabPlayer)
createToggleRow(moveCard, "步行加速", "提高移动速度", Config.WalkSpeedEnabled, function(v)
    Config.WalkSpeedEnabled = v
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed = v and Config.WalkSpeedValue or 16 end
end, "WalkSpeedEnabled")
createSliderRow(moveCard, "速度值", "目标步行速度", 16, 120, Config.WalkSpeedValue, false, "", function(v)
    Config.WalkSpeedValue = v
    if Config.WalkSpeedEnabled then local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.WalkSpeed = v end end
end, "WalkSpeedValue")
createToggleRow(moveCard, "飞行", "PC: WASD+空格/Shift | 手机: 摇杆移动+跳跃上升（开启后悬停不掉落）", Config.FlyEnabled, function(v) Config.FlyEnabled = v end, "FlyEnabled")
createSliderRow(moveCard, "飞行速度", "飞行移动速度", 20, 150, Config.FlySpeed, false, "", function(v) Config.FlySpeed = v end, "FlySpeed")
createToggleRow(moveCard, "无限跳跃", "在空中无限跳跃", Config.InfiniteJump, function(v) Config.InfiniteJump = v end, "InfiniteJump")
createToggleRow(moveCard, "水上行走", "在海面上行走(海平面: 0)", Config.WalkOnWater, function(v) Config.WalkOnWater = v end, "WalkOnWater")
createToggleRow(moveCard, "穿墙", "穿过固体障碍和墙壁 (零GC优化)", Config.Noclip, function(v) Config.Noclip = v end, "Noclip")

createCategoryHeader(tabPlayer, "防挂机与稳定性")
local stabCard = createCardGroup(tabPlayer)
createToggleRow(stabCard, "防挂机", "防止Roblox 20分钟空闲断开", Config.AntiAFK, function(v) Config.AntiAFK = v end, "AntiAFK")
createToggleRow(stabCard, "被踢自动重连", "断线或报错弹窗时自动重连服务器", Config.AutoRejoin, function(v) Config.AutoRejoin = v end, "AutoRejoin")

-- ==========================================
-- 配置页面
-- ==========================================
createCategoryHeader(tabProfiles, "界面设置")
local uiCard = createCardGroup(tabProfiles)
local scaleDebounceThread = nil
createSliderRow(uiCard, "窗口缩放比例", "调节界面大小（拖动不卡，松手后生效）", 0.5, 1.2, Config.UIScale, true, "x", function(v)
    Config.UIScale = v
    if scaleDebounceThread then
        pcall(task.cancel, scaleDebounceThread)
        scaleDebounceThread = nil
    end
    scaleDebounceThread = task.delay(0.12, function()
        if mainFrameScale and mainFrameScale.Parent then
            mainFrameScale.Scale = Config.UIScale
        end
        scaleDebounceThread = nil
    end)
end, "UIScale")

createCategoryHeader(tabProfiles, "配置文件管理")
local profCard = createCardGroup(tabProfiles)
createButtonRow(profCard, "保存配置", "将所有设置保存到JSON文件", "保存配置", function()
    if SaveProfile() then ShowNotification("配置已保存", "配置文件 'default.json' 保存成功！", "SUCCESS") else ShowNotification("配置错误", "保存配置文件失败。", "ERROR") end
end)
createButtonRow(profCard, "加载配置", "从JSON文件加载设置并同步界面", "加载配置", function()
    if LoadProfile() then
        ShowNotification("配置已加载", "配置文件 'default.json' 加载并同步成功！", "SUCCESS")
        if mainFrameScale then mainFrameScale.Scale = Config.UIScale end
    else
        ShowNotification("配置错误", "未找到已保存的配置文件。", "WARN")
    end
end)
createToggleRow(profCard, "注入时自动加载配置", "启动时自动加载配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end, "AutoLoadProfile")

createCategoryHeader(tabProfiles, "会话操作")
local credCard = createCardGroup(tabProfiles)
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复所有设置", "卸载", UnloadScript)
end -- end of Visuals/Player/Profiles scope

-- 自动修复/清理之前版本误开启的 MainGui 隐藏弹窗层（如“正在保存数据...”、“点击以关闭”等）
pcall(function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    if mg then
        for _, ch in ipairs(mg:GetChildren()) do
            if ch:IsA("GuiObject") and ch.Name ~= "Fishing" then
                -- 检查是否包含误弹出的加载/保存/抽卡结算或测试层文字
                local shouldHide = false
                local n = ch.Name:lower()
                if n:find("load") or n:find("save") or n:find("saving") or n:find("cutscene") or n:find("intro") or n:find("title") or n:find("result") or n:find("reward") or n:find("gacha") or n:find("popup") or n:find("black") or n:find(" splash") then
                    shouldHide = true
                else
                    for _, sub in ipairs(ch:GetDescendants()) do
                        if sub:IsA("TextLabel") or sub:IsA("TextButton") then
                            local t = sub.Text or ""
                            if t:find("正在保存") or t:find("点击以关闭") or t:find("HEAVYWEIGHT") or t:find("Cộng hòa") or t:find("Kính gửi") then
                                shouldHide = true
                                break
                            end
                        end
                    end
                end
                if shouldHide then
                    ch.Visible = false
                end
            end
        end
    end
end)

SyncUIWithConfig()

-- ==========================================
-- 角色零件监听（用于零开销 Noclip）
-- ==========================================
local function CacheCharacterParts(char)
    table.clear(cachedCharacterParts)
    cachedFishConstraint = nil
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then table.insert(cachedCharacterParts, part) end
    end
    table.insert(activeConnections, char.DescendantAdded:Connect(function(part)
        if part:IsA("BasePart") then table.insert(cachedCharacterParts, part) end
    end))
    table.insert(activeConnections, char.DescendantRemoving:Connect(function(part)
        local idx = table.find(cachedCharacterParts, part)
        if idx then table.remove(cachedCharacterParts, idx) end
        if cachedFishConstraint == part then cachedFishConstraint = nil end
    end))
end

if LocalPlayer.Character then CacheCharacterParts(LocalPlayer.Character) end
table.insert(activeConnections, LocalPlayer.CharacterAdded:Connect(CacheCharacterParts))

-- Noclip 在 Stepped 中执行，直接遍历缓存数组，无新表创建开销
table.insert(activeConnections, RunService.Stepped:Connect(function()
    if isRunning and Config.Noclip then
        for i = 1, #cachedCharacterParts do
            local p = cachedCharacterParts[i]
            if p and p.CanCollide then p.CanCollide = false end
        end
    end
end))

-- 环境光照守候
table.insert(activeConnections, Lighting.Changed:Connect(function()
    if isRunning and (Config.Fullbright or Config.NoFog) then
        ApplyLightingSettings()
    end
end))

-- 被踢重连（多通道守候：标准 ErrorPrompt 弹窗 + 静默踢人 OnTeleport/PlayerRemoving 监听）
pcall(function()
    local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
    local overlay = promptGui and promptGui:WaitForChild("promptOverlay", 5)
    if overlay then
        table.insert(activeConnections, overlay.ChildAdded:Connect(function(child)
            if isRunning and Config.AutoRejoin and child.Name == "ErrorPrompt" then
                ShowNotification("自动重连", "检测到断线弹窗，3秒后自动重新连接...", "WARN")
                task.wait(3)
                if isRunning and Config.AutoRejoin then
                    TeleportService:Teleport(game.PlaceId, LocalPlayer)
                end
            end
        end))
    end
    -- 针对静默踢人或服务端强制传送回大厅的兜底通道
    table.insert(activeConnections, LocalPlayer.OnTeleport:Connect(function(teleportState)
        if isRunning and Config.AutoRejoin and teleportState == Enum.TeleportState.Failed then
            task.wait(3)
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end
    end))
end)

-- ==========================================
-- ESP 管理系统 (后台扫描 + 节流渲染)
-- ==========================================
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

    activeESP[instance] = {
        gui = bb,
        label = lbl,
        part = part,
        espCategory = espCategory,
        name = name,
        icon = icon or "",
        lastDist = -1
    }
end

local function RemoveESP(instance)
    local data = activeESP[instance]
    if data then
        if data.gui and data.gui.Parent then data.gui:Destroy() end
        activeESP[instance] = nil
    end
end

-- 1.0 秒低频实体扫描与自动跳服
task.spawn(function()
    local wasFound = {God = false, Taoist = false, Maoshan = false}
    local lastHopCheck = tick()
    while isRunning do
        task.wait(Config.Disable3DRendering and 2.5 or 1.0)
        pcall(function()
            local npcFolder = Workspace:FindFirstChild("NPC")
            local char = LocalPlayer.Character
            local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
            local found = {God = false, Taoist = false, Maoshan = false}

            if npcFolder then
                for _, npc in ipairs(npcFolder:GetChildren()) do
                    local name = npc.Name
                    local pos = GetNPCPosition(npc)
                    if pos then
                        local key = nil
                        if name == "Spirit" or name == "God" then
                            key = "God"
                            AddESP(npc, "神灵", "GodSpirit", Colors.AccentGreen, "⛩️")
                        elseif name:find("Taoist") or name:find("Grand Angler") then
                            key = "Taoist"
                            AddESP(npc, name, "Taoist", Colors.AccentOrange, "📜")
                        elseif name:find("Maoshan") then
                            key = "Maoshan"
                            AddESP(npc, name, "Maoshan", Colors.PurplePrimary, "✨")
                        end
                        if key then
                            liveNPCs[key].pos = pos
                            found[key] = true
                            if not wasFound[key] then
                                ShowNotification("NPC 降临", liveNPCs[key].name .. " 已在服务器刷新！", "SUCCESS", 5)
                            end
                        end
                    end
                end
            end

            for key, data in pairs(liveNPCs) do
                if found[key] then
                    data.ui_title.Text = data.icon .. " " .. data.name .. " (已找到)"
                    data.ui_title.TextColor3 = Colors.AccentGreen
                    if myPos then data.ui_desc.Text = string.format("距离你: %d 米", math.floor((myPos - data.pos).Magnitude)) else data.ui_desc.Text = "位置已获取" end
                    data.ui_btn.BackgroundColor3 = Colors.PurpleAccent; data.ui_btn.TextColor3 = Colors.TextWhite; data.ui_btn.Text = "立即传送"
                else
                    data.pos = nil; data.ui_title.Text = data.icon .. " " .. data.name .. " (未检测到)"; data.ui_title.TextColor3 = Colors.TextMuted
                    data.ui_desc.Text = "等待刷新..."; data.ui_btn.BackgroundColor3 = Colors.ControlBg; data.ui_btn.TextColor3 = Colors.TextMuted; data.ui_btn.Text = "传送"
                end
            end
            wasFound = found

            if tick() - lastHopCheck >= 8.0 then
                lastHopCheck = tick()
                if (Config.AutoServerHopGod and not found.God) or
                   (Config.AutoServerHopMaoshan and not found.Maoshan) or
                   (Config.AutoServerHopTaoist and not found.Taoist) then
                    ServerHop()
                end
            end

            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                    AddESP(p.Character, p.DisplayName, "Players", Colors.PurpleAccent, "👤")
                end
            end
            if Workspace:FindFirstChild("SecretRod") then
                for _, r in ipairs(Workspace.SecretRod:GetChildren()) do AddESP(r, r.Name, "SecretRod", Colors.AccentYellow, "🌟") end
            end
            if Workspace:FindFirstChild("Boat") then
                for _, b in ipairs(Workspace.Boat:GetChildren()) do AddESP(b, b.Name, "Boats", Colors.AccentBlue, "⛵") end
            end
            if Workspace:FindFirstChild("BossSetUp") then
                for _, b in ipairs(Workspace.BossSetUp:GetChildren()) do AddESP(b, b.Name, "Boss", Colors.AccentRed, "👹") end
            end
        end)
    end
end)

-- 0.15 秒轻量 ESP 文字与开关刷新（彻底解放 RenderStepped）
task.spawn(function()
    while isRunning do
        task.wait(Config.Disable3DRendering and 1.0 or 0.15)
        if not Config.Disable3DRendering then
        pcall(function()
            local currentCamera = Workspace.CurrentCamera or Camera
            if not currentCamera then return end
            local camPos = currentCamera.CFrame.Position
            for inst, data in pairs(activeESP) do
                if not inst.Parent or not data.part.Parent then
                    RemoveESP(inst)
                else
                    local isEnabled = Config["ESP_" .. data.espCategory]
                    if data.gui.Enabled ~= isEnabled then data.gui.Enabled = isEnabled end
                    if isEnabled then
                        local dist = math.floor((camPos - data.part.Position).Magnitude)
                        if data.lastDist ~= dist then
                            data.lastDist = dist
                            data.label.Text = data.icon .. " " .. data.name .. " [" .. dist .. "米]"
                        end
                    end
                end
            end
        end)
        end
    end
end)

-- ==========================================
-- 仪表盘与自动装备异步更新协程
-- ==========================================
task.spawn(function()
    local startTime = tick()
    local startFish = 0
    local startCash = 0
    local initDone = false
    local lastEquipCheck = 0
    
    while isRunning do
        task.wait(0.5)
        pcall(function()
            local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))
            local now = tick()
            local elapsed = now - startTime
            
            local h = math.floor(elapsed / 3600)
            local m = math.floor((elapsed % 3600) / 60)
            local s = math.floor(elapsed % 60)
            DashUI.lblHangTime.Text = string.format("%02d:%02d:%02d", h, m, s)

            local pingOk, pingVal = pcall(function() return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue()) end)
            if pingOk then DashUI.lblPing.Text = pingVal .. " ms" else DashUI.lblPing.Text = "N/A" end

            local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if root then DashUI.lblPos.Text = string.format("%.0f, %.0f, %.0f", root.Position.X, root.Position.Y, root.Position.Z) end

            if pData then
                if not initDone then
                    startFish = pData:FindFirstChild("FishCaught") and pData.FishCaught.Value or 0
                    startCash = pData:FindFirstChild("Cash") and pData.Cash.Value or 0
                    initDone = true
                end

                local currentFish = pData:FindFirstChild("FishCaught") and pData.FishCaught.Value or 0
                local currentCash = pData:FindFirstChild("Cash") and pData.Cash.Value or 0
                
                DashUI.lblTotalFish.Text = string.format("%d 条", currentFish)
                DashUI.infoFishCaught.Set(tostring(currentFish))
                DashUI.infoCash.Set("$" .. tostring(currentCash))

                if currentCash >= 1000000000 then
                    DashUI.lblCash.Text = string.format("$%.2fB", currentCash / 1000000000)
                elseif currentCash >= 1000000 then
                    DashUI.lblCash.Text = string.format("$%.2fM", currentCash / 1000000)
                elseif currentCash >= 1000 then
                    DashUI.lblCash.Text = string.format("$%.1fK", currentCash / 1000)
                else
                    DashUI.lblCash.Text = "$" .. tostring(currentCash)
                end

                if elapsed > 5 then
                    local fishSpeed = math.max(0, ((currentFish - startFish) / elapsed) * 3600)
                    DashUI.lblFishSpeed.Text = string.format("%.0f 条/h", fishSpeed)
                    local cashSpeed = math.max(0, ((currentCash - startCash) / elapsed) * 3600)
                    if cashSpeed >= 1000000 then
                        DashUI.lblCashSpeed.Text = string.format("$%.1fM/h", cashSpeed / 1000000)
                    elseif cashSpeed >= 1000 then
                        DashUI.lblCashSpeed.Text = string.format("$%.1fK/h", cashSpeed / 1000)
                    else
                        DashUI.lblCashSpeed.Text = string.format("$%.0f/h", cashSpeed)
                    end
                else
                    DashUI.lblCashSpeed.Text = "$0/h"
                end

                if pData:FindFirstChild("FishingRod") and pData.FishingRod.Value ~= "" then
                    DashUI.lblRod.Text = pData.FishingRod.Value
                    DashUI.infoEquippedRod.Set(pData.FishingRod.Value)
                end
                if pData:FindFirstChild("EquippedBait") and pData.EquippedBait.Value ~= "" then
                    DashUI.lblBait.Text = pData.EquippedBait.Value
                    DashUI.infoEquippedBait.Set(pData.EquippedBait.Value)
                end
                
                local gemsVal = 0
                if pData:FindFirstChild("Gems") then gemsVal = pData.Gems.Value
                elseif pData:FindFirstChild("Gem") then gemsVal = pData.Gem.Value
                elseif pData:FindFirstChild("Diamonds") then gemsVal = pData.Diamonds.Value end
                if gemsVal >= 1000000000 then DashUI.lblGems.Text = string.format("%.1fB", gemsVal / 1000000000)
                elseif gemsVal >= 1000000 then DashUI.lblGems.Text = string.format("%.1fM", gemsVal / 1000000)
                else DashUI.lblGems.Text = tostring(gemsVal) end

                local ticketsVal = 0
                if pData:FindFirstChild("Tickets") then ticketsVal = pData.Tickets.Value
                elseif pData:FindFirstChild("Ticket") then ticketsVal = pData.Ticket.Value end
                if ticketsVal >= 1000000000 then DashUI.lblTicket.Text = string.format("%.1fB", ticketsVal / 1000000000)
                elseif ticketsVal >= 1000000 then DashUI.lblTicket.Text = string.format("%.1fM", ticketsVal / 1000000)
                else DashUI.lblTicket.Text = tostring(ticketsVal) end

                local dailyDone = "0"
                if pData:FindFirstChild("DailyQuestsDone") then dailyDone = tostring(pData.DailyQuestsDone.Value) elseif pData:FindFirstChild("DailyProgress") then dailyDone = tostring(pData.DailyProgress.Value) end
                DashUI.lblQuest.Text = dailyDone .. " 个"

                local invCount = 0
                if pData:FindFirstChild("Inventory") then invCount = invCount + #pData.Inventory:GetChildren() end
                if pData:FindFirstChild("Hotbar") then
                    for _, item in ipairs(pData.Hotbar:GetChildren()) do if item:FindFirstChild("Quantity") then invCount = invCount + item.Quantity.Value else invCount = invCount + 1 end end
                end
                local limit = pData:FindFirstChild("InventoryLimit") and pData.InventoryLimit.Value or "?"
                DashUI.lblBag.Text = invCount .. " / " .. tostring(limit)

                if now - lastEquipCheck >= 5.0 then
                    lastEquipCheck = now
                    if Config.AutoEquipBestBait and not Config.AutoFarmSecretBoss and pData:FindFirstChild("Bait") and pData:FindFirstChild("EquippedBait") and Events and Events:FindFirstChild("EquipBait") then
                        local curEquipped = pData.EquippedBait.Value
                        local isSpecialBossBait = (curEquipped == "Nameless Bait" or curEquipped == "Frost Bait" or curEquipped == "Rainbow Bait")
                        if not isSpecialBossBait then
                            local bestBait, bestLuck = nil, -1
                            local baitLuckMap = { ["Ancestral Bait"] = 50, ["Elite Bait"] = 30, ["Corrupted Essence Bait"] = 18, ["Crude Mash Bait"] = 8, ["Basic Bait"] = 3 }
                            for bName, bLuck in pairs(baitLuckMap) do
                                local bVal = pData.Bait:FindFirstChild(bName)
                                if bVal and bVal.Value > 0 and bLuck > bestLuck then bestLuck = bLuck; bestBait = bName end
                            end
                            if bestBait and curEquipped ~= bestBait then
                                task.spawn(function() pcall(function() Events.EquipBait:InvokeServer(bestBait) end) end)
                            end
                        end
                    end
                    if Config.AutoEquipBestRod and pData:FindFirstChild("FishingRodInventory") and pData:FindFirstChild("FishingRod") and Events and Events:FindFirstChild("EquipFishingRod") then
                        local bestRod, bestPower = nil, -1
                        for _, r in ipairs(allRods) do
                            local rFolder = pData.FishingRodInventory:FindFirstChild(r.name)
                            local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
                            if isOwned and r.power > bestPower then bestPower = r.power; bestRod = r.name end
                        end
                        if bestRod and pData.FishingRod.Value ~= bestRod then
                            task.spawn(function() pcall(function() Events.EquipFishingRod:InvokeServer(bestRod) end) end)
                        end
                    end
                    if Config.AutoEquipBestOrb and pData:FindFirstChild("Orb") and Events and Events:FindFirstChild("EquipOrb") then
                        local orbs = pData.Orb:GetChildren()
                        if #orbs > 0 then
                            local targetOrb = orbs[#orbs].Name
                            task.spawn(function() pcall(function() Events.EquipOrb:InvokeServer(targetOrb) end) end)
                        end
                    end
                end
            end
        end)
    end
end)

-- ==========================================
-- 自动化循环 Heartbeat (逻辑与物理分离)
-- ==========================================
do
local lastCastTime = 0
local lastSellTime = 0
local lastSkillTime = 0
local lastBaitBuyTime = 0
local lastQuestTime = 0
local lastGodPrayTime = 0
local lastProgressionTime = 0
local lastProtectTime = 0
local lastDailyTime = 0
local lastCraftTime = 0
local lastBossTime = 0
local lastSlamChargeTime = 0
local lastRhythmTime = 0
local lastHookScanTime = 0
local cachedIsHooked = false
local cachedHookedPos = nil
local wasInMinigame = false

local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local function FireGuiButton(btn)
    if not btn or not btn.Visible then return end
    if firesignal then
        pcall(function() firesignal(btn.MouseButton1Click) end)
        pcall(function() firesignal(btn.Activated) end)
    elseif getconnections then
        pcall(function()
            for _, conn in ipairs(getconnections(btn.MouseButton1Click)) do conn:Fire() end
            for _, conn in ipairs(getconnections(btn.Activated)) do conn:Fire() end
        end)
    end
end

-- 零GC事件缓存：仅缓存 Boss/章鱼 ProximityPrompt，不触碰无关游戏UI按钮
local cachedBossPrompts = {}
local function IsBossPromptCandidate(inst)
    if not inst or not inst:IsA("ProximityPrompt") then return false end
    local full = inst:GetFullName():lower()
    return (full:find("boss") or full:find("octo") or full:find("parasite") or full:find("angler") or full:find("rhythm") or full:find("buoy")) ~= nil
end

pcall(function()
    for _, d in ipairs(Workspace:GetDescendants()) do
        if IsBossPromptCandidate(d) then table.insert(cachedBossPrompts, d) end
    end
    table.insert(activeConnections, Workspace.DescendantAdded:Connect(function(d)
        if IsBossPromptCandidate(d) then table.insert(cachedBossPrompts, d) end
    end))
    table.insert(activeConnections, Workspace.DescendantRemoving:Connect(function(d)
        local idx = table.find(cachedBossPrompts, d)
        if idx then table.remove(cachedBossPrompts, idx) end
    end))
end)

local waterPlatform = Instance.new("Part"); waterPlatform.Name = "IdenticalWaterPlatform"; waterPlatform.Size = Vector3.new(60, 2, 60); waterPlatform.Anchored = true; waterPlatform.CanCollide = false; waterPlatform.Transparency = 1; waterPlatform.Parent = Workspace
table.insert(cleanUpInstances, waterPlatform)

local uidHealthKey = tostring(LocalPlayer.UserId) .. "_PlayerHealth"

table.insert(activeConnections, RunService.Heartbeat:Connect(function(dt)
    if not isRunning then return end
    pcall(function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then return end
        local now = tick()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local pData = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(tostring(LocalPlayer.UserId))

        if Config.WalkSpeedEnabled then hum.WalkSpeed = Config.WalkSpeedValue end
        if Config.WalkOnWater then waterPlatform.CFrame = CFrame.new(root.Position.X, 0, root.Position.Z); waterPlatform.CanCollide = (root.Position.Y >= -1) else waterPlatform.CanCollide = false end

        if Config.PositionLock then
            if not lockedCFrame then lockedCFrame = root.CFrame end
            if (root.Position - lockedCFrame.Position).Magnitude > 3.5 then
                root.CFrame = lockedCFrame
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end

        if now - lastHookScanTime >= 0.25 then
            lastHookScanTime = now
            cachedIsHooked = false
            cachedHookedPos = nil
            if Workspace:FindFirstChild("Fishes") then
                for _, f in ipairs(Workspace.Fishes:GetChildren()) do
                    if f:FindFirstChild(uidHealthKey) then
                        cachedIsHooked = true
                        if f:FindFirstChild("Model") and f.Model:IsA("Model") then
                            cachedHookedPos = f.Model:GetPivot().Position
                        elseif f:FindFirstChild("Buoy") and f.Buoy:IsA("BasePart") then
                            cachedHookedPos = f.Buoy.Position
                        end
                        break
                    end
                end
            end
        end

        local fUI = pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing")
        local bossBar = fUI and fUI:FindFirstChild("BossFightBar")
        local inUndergroundRealm = (root.Position.Y < -50)

        local isFishing = char:GetAttribute("Fishing") == true
        -- 核心小游戏判定：优先通过属性与UI检测，若UI有延迟则通过 cachedIsHooked 兜底，绝不漏放技能导致伤害不足被踢
        local isMinigame = char:GetAttribute("Minigame") == true
            or (fUI and fUI.Visible)
            or (bossBar and bossBar.Visible)
            or cachedIsHooked
        local isCD = char:GetAttribute("CDForTheNextThrow") == true
        local isSwimming = char:GetAttribute("Swimming") == true
        local useMinigameAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss

        -- 状态边沿检测：每次刚进入小游戏瞬间，强制重置技能索引为 1（保证 100% 从第 1 个勾选技能如 Z 起手）
        if isMinigame and not wasInMinigame then
            wasInMinigame = true
            currentSkillIndex = 1
            -- 留出 0.2 秒小游戏 UI 弹出缓冲期后立即释放第 1 个技能 Z
            local interval = Config.SkillInterval or 1.5
            lastSkillTime = now - interval + 0.2
        elseif not isMinigame and wasInMinigame then
            wasInMinigame = false
            currentSkillIndex = 1
        end

        if (Config.AutoFarmBoss or Config.AutoFarmSecretBoss) and not isMinigame and not isFishing and not cachedIsHooked and (now - lastBossTime >= 2.5) then
            lastBossTime = now
            if Config.AutoFarmSecretBoss then
                local bVal = pData and pData:FindFirstChild("Bait") and pData.Bait:FindFirstChild("Nameless Bait")
                if (not bVal or bVal.Value <= 0) and Events and Events:FindFirstChild("CraftBait") then
                    Events.CraftBait:FireServer("Nameless Bait", 1)
                elseif bVal and bVal.Value > 0 and pData:FindFirstChild("EquippedBait") and pData.EquippedBait.Value ~= "Nameless Bait" then
                    task.spawn(function() pcall(function() Events.EquipBait:InvokeServer("Nameless Bait") end) end)
                end
                if not inUndergroundRealm then
                    local octoPos = Vector3.new(1608.2, 5.0, -218.3)
                    if (root.Position - octoPos).Magnitude > 15 then
                        SafeTeleport(CFrame.new(octoPos))
                    end
                end
                for i = 1, #cachedBossPrompts do
                    local pr = cachedBossPrompts[i]
                    if pr and pr.Parent and pr.Enabled then TriggerPrompt(pr) end
                end
            elseif Config.AutoFarmBoss then
                local enzoPos = Vector3.new(-115.3, 9.2, 1349.5)
                if (root.Position - enzoPos).Magnitude > 15 then
                    SafeTeleport(CFrame.new(enzoPos))
                end
                if Workspace:FindFirstChild("BossSetUp") then
                    for _, d in ipairs(Workspace.BossSetUp:GetDescendants()) do
                        if d:IsA("ProximityPrompt") then TriggerPrompt(d) end
                    end
                end
            end
        end

        if isMinigame then
            if fUI and fUI.Visible then
                if useMinigameAssist then
                    local barFrame = fUI:FindFirstChild("BarFrame")
                    if barFrame and barFrame:FindFirstChild("Bar") then
                        barFrame.Bar.Position = UDim2.new(0.5, 0, 0.5, 0)
                    end
                    if bossBar and bossBar.Visible and bossBar:FindFirstChild("Bar") and bossBar:FindFirstChild("Hitbox") then
                        bossBar.Bar.Position = bossBar.Hitbox.Position
                        bossBar.Bar.Rotation = bossBar.Hitbox.Rotation
                    end
                end
                if (now - lastSlamChargeTime >= 0.08) then
                    local didFire = false
                    if (Config.AutoSlam or useMinigameAssist) and fUI:FindFirstChild("PerfectButton") and fUI.PerfectButton.Visible then
                        FireGuiButton(fUI.PerfectButton)
                        if Events and Events:FindFirstChild("Slam") then Events.Slam:FireServer("Perfect") end
                        didFire = true
                    end
                    if (Config.AutoCharge or useMinigameAssist) and fUI:FindFirstChild("Charge") and fUI.Charge.Visible then
                        if fUI.Charge:IsA("GuiButton") then FireGuiButton(fUI.Charge) end
                        if Events and Events:FindFirstChild("Charge") then Events.Charge:FireServer(100) end
                        didFire = true
                    end
                    if didFire then lastSlamChargeTime = now end
                end
                local progInterval = Config.InstantCatch and 0.05 or 0.08
                if useMinigameAssist and (now - lastProgressionTime >= progInterval) then
                    if Events and Events:FindFirstChild("UpdateFishProgression") then
                        Events.UpdateFishProgression:FireServer()
                        if Config.InstantCatch then Events.UpdateFishProgression:FireServer() end
                    end
                    if Events and Events:FindFirstChild("FishingMinigame") then
                        Events.FishingMinigame:FireServer("In bar")
                    end
                    lastProgressionTime = now
                end
            end

            -- 严格按技能释放顺序轮换（从第1个勾选技能起手），多通道触发提高成功率
            if (Config.AutoSkills or Config.BossAutoSkills) and (now - lastSkillTime >= (Config.SkillInterval or 1.5)) then
                local enabledSkills = {}
                local orderStr = (Config.SkillOrder or "Z,X,C,V"):upper():gsub("[%s,;|/]+", "")
                -- 按用户填写的顺序提取 Z/X/C/V，并只保留已勾选的技能
                for i = 1, #orderStr do
                    local sk = orderStr:sub(i, i)
                    if sk == "Z" or sk == "X" or sk == "C" or sk == "V" then
                        local allowed = (sk == "Z" and Config.SkillZ) or (sk == "X" and Config.SkillX)
                            or (sk == "C" and Config.SkillC) or (sk == "V" and Config.SkillV)
                        if allowed then
                            local already = false
                            for _, e in ipairs(enabledSkills) do if e == sk then already = true break end end
                            if not already then table.insert(enabledSkills, sk) end
                        end
                    end
                end
                -- 兜底：如果顺序字符串解析失败，按 Z→X→C→V 默认顺序
                if #enabledSkills == 0 then
                    if Config.SkillZ then table.insert(enabledSkills, "Z") end
                    if Config.SkillX then table.insert(enabledSkills, "X") end
                    if Config.SkillC then table.insert(enabledSkills, "C") end
                    if Config.SkillV then table.insert(enabledSkills, "V") end
                end
                if #enabledSkills > 0 then
                    if not currentSkillIndex or currentSkillIndex < 1 or currentSkillIndex > #enabledSkills then
                        currentSkillIndex = 1
                    end
                    local sk = enabledSkills[currentSkillIndex]

                    -- 通道1：优先 Remote（最稳定）
                    pcall(function()
                        if Events then
                            local trigRem = Events:FindFirstChild("TriggerMinigameSkill")
                            local useRem = Events:FindFirstChild("UseSkill")
                            if trigRem then trigRem:FireServer(sk) end
                            if useRem then useRem:FireServer(sk) end
                            -- 部分版本可能用数字或全名，额外尝试
                            if trigRem then pcall(function() trigRem:FireServer(sk:lower()) end) end
                            if useRem then pcall(function() useRem:FireServer(sk:lower()) end) end
                        end
                    end)

                    -- 通道2：模拟按键（PC + 部分手机执行器有效）
                    pcall(function()
                        if VirtualInputManager and Enum.KeyCode[sk] then
                            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode[sk], false, game)
                            task.delay(0.06, function()
                                pcall(function()
                                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode[sk], false, game)
                                end)
                            end)
                        end
                    end)

                    -- 通道3：尝试点击游戏内技能按钮（兼容手机触摸UI）
                    pcall(function()
                        local pg = LocalPlayer:FindFirstChild("PlayerGui")
                        if not pg then return end
                        local searchRoots = {}
                        if fUI then table.insert(searchRoots, fUI) end
                        if pg:FindFirstChild("MainGui") then table.insert(searchRoots, pg.MainGui) end
                        if pg:FindFirstChild("Fisher_GUI") then table.insert(searchRoots, pg.Fisher_GUI) end
                        for _, rootInst in ipairs(searchRoots) do
                            for _, d in ipairs(rootInst:GetDescendants()) do
                                if (d:IsA("GuiButton") or d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
                                    local name = (d.Name or ""):upper()
                                    local txt = ""
                                    if d:IsA("TextButton") then
                                        txt = (d.Text or ""):upper()
                                    else
                                        local tl = d:FindFirstChildOfClass("TextLabel")
                                        if tl then txt = (tl.Text or ""):upper() end
                                    end
                                    if name == sk or name:find(sk, 1, true) or txt == sk or txt:find(sk, 1, true) then
                                        if d.AbsoluteSize.X > 5 then
                                            FireGuiButton(d)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                    end)

                    -- 严格按顺序前进（不管是否成功触发，保证轮换不乱）
                    currentSkillIndex = (currentSkillIndex % #enabledSkills) + 1
                    lastSkillTime = now
                end
            end
        elseif isFishing then
            lastCastTime = now
        else
            if (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish) and (now - lastProtectTime >= 3.0) and pData then
                lastProtectTime = now
                TryFavoriteProtectedFish(pData)
            end

            if Config.AutoSell and (now - lastSellTime >= Config.SellInterval) then
                SafeSellAllFish(pData)
                lastSellTime = now
            end

            local shouldAutoCast = Config.AutoCast or Config.AutoFarmBoss or Config.AutoFarmSecretBoss
            if shouldAutoCast and not isCD and not isSwimming and (now - lastCastTime >= Config.CastDelay) then
                local canCast = true
                if pData and pData:FindFirstChild("InventoryLimit") then
                    local invCount = 0
                    if pData:FindFirstChild("Inventory") then invCount = invCount + #pData.Inventory:GetChildren() end
                    if pData:FindFirstChild("Hotbar") then
                        for _, item in ipairs(pData.Hotbar:GetChildren()) do
                            if item:FindFirstChild("Quantity") then invCount = invCount + item.Quantity.Value else invCount = invCount + 1 end
                        end
                    end
                    local maxLim = pData.InventoryLimit.Value
                    -- 达到 90% 容量提前触发自动出售，避免 100% 满包卡顿抛竿
                    if Config.AutoSell and maxLim > 0 and invCount >= math.floor(maxLim * 0.9) and (now - lastSellTime >= 5.0) then
                        SafeSellAllFish(pData)
                        lastSellTime = now
                    end
                    if invCount >= maxLim then
                        canCast = false
                    end
                end
                if canCast and Events and Events:FindFirstChild("Fishing") then
                    Events.Fishing:FireServer(root.CFrame)
                    lastCastTime = now
                end
            end
        end

        if Config.AutoPrayGodSpirit and (now - lastGodPrayTime >= 3.0) then
            lastGodPrayTime = now
            if Workspace:FindFirstChild("NPC") then
                local sp = Workspace.NPC:FindFirstChild("Spirit") or Workspace.NPC:FindFirstChild("God")
                if sp then
                    for _, d in ipairs(sp:GetDescendants()) do
                        if d:IsA("ProximityPrompt") then TriggerPrompt(d) end
                    end
                end
            end
        end

        if Config.AutoTicketQuest and (now - lastQuestTime >= 3.5) then
            lastQuestTime = now
            if RunTicketQuestAction then
                local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
                local didSend = RunTicketQuestAction(diffArg, false)
                if didSend then
                    -- 成功发包后额外拉长冷却间隔（合计约 10 秒），贴近真人操作防限流
                    lastQuestTime = now + 6.5
                end
            end
        end

        if Config.AutoClaimDaily and (now - lastDailyTime >= 300.0) then
            lastDailyTime = now
            if Events then
                local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
                if dailyRem then
                    task.spawn(function()
                        local delaySec = math.max(0.4, tonumber(Config.DailyClaimDelay) or 0.5)
                        for day = 1, 7 do
                            if not isRunning or not Config.AutoClaimDaily then break end
                            if dailyRem:IsA("RemoteEvent") then
                                pcall(function() dailyRem:FireServer(day) end)
                            elseif dailyRem:IsA("RemoteFunction") then
                                pcall(function() dailyRem:InvokeServer(day) end)
                            end
                            task.wait(delaySec)
                        end
                    end)
                end
            end
        end

        if Config.AutoCraftBait and (now - lastCraftTime >= 2.0) then
            lastCraftTime = now
            if Events and Events:FindFirstChild("CraftBait") then
                Events.CraftBait:FireServer(Config.CraftBaitName, Config.CraftAmount)
            end
        end

        if Config.AutoBuyBait and (now - lastBaitBuyTime >= Config.BuyBaitDelay) then
            lastBaitBuyTime = now
            if pData and pData:FindFirstChild("Bait") and Events and Events:FindFirstChild("BuyBait") then
                local bFolder = pData.Bait:FindFirstChild(Config.BuyBaitName)
                local currentAmount = bFolder and bFolder.Value or 0
                if currentAmount < Config.BuyBaitThreshold then
                    Events.BuyBait:FireServer(Config.BuyBaitName, Config.BuyBaitAmount)
                end
            end
        end

        if Config.OctoAutoMinigame and (now - lastRhythmTime >= 0.08) then
            lastRhythmTime = now
            if Events then
                local rhythmRemoteNames = {"RhythmHit", "Rhythm", "RhythmMinigame", "OctoMinigame", "OctoHit", "ParasiteMinigame", "QTE", "MinigameHit"}
                for _, rName in ipairs(rhythmRemoteNames) do
                    local rem = Events:FindFirstChild(rName)
                    if rem and rem:IsA("RemoteEvent") then
                        rem:FireServer(true, 100)
                        rem:FireServer("Perfect")
                    end
                end
                if isMinigame then
                    if Events:FindFirstChild("UpdateFishProgression") then Events.UpdateFishProgression:FireServer() end
                    if Events:FindFirstChild("FishingMinigame") then Events.FishingMinigame:FireServer("In bar") end
                end
            end
            if inUndergroundRealm then
                for i = 1, #cachedBossPrompts do
                    local pr = cachedBossPrompts[i]
                    if pr and pr.Parent and pr.Enabled then TriggerPrompt(pr) end
                end
            end
        end
    end)
end))

-- ==========================================
-- 纯净渲染循环 RenderStepped (极致低延迟)
-- ==========================================
local flyBV, flyBG = nil, nil
table.insert(activeConnections, RunService.RenderStepped:Connect(function()
    if not isRunning then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local hum = char:FindFirstChildOfClass("Humanoid")

    if Config.FlyEnabled then
        -- 创建/恢复 BodyVelocity + BodyGyro
        if not flyBV or flyBV.Parent ~= root then
            if flyBV then
                local oldIdx = table.find(cleanUpInstances, flyBV)
                if oldIdx then table.remove(cleanUpInstances, oldIdx) end
                pcall(function() flyBV:Destroy() end)
            end
            flyBV = Instance.new("BodyVelocity")
            flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
            flyBV.Velocity = Vector3.zero
            flyBV.Parent = root
            table.insert(cleanUpInstances, flyBV)
        end
        if not flyBG or flyBG.Parent ~= root then
            if flyBG then
                local oldIdx = table.find(cleanUpInstances, flyBG)
                if oldIdx then table.remove(cleanUpInstances, oldIdx) end
                pcall(function() flyBG:Destroy() end)
            end
            flyBG = Instance.new("BodyGyro")
            flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
            flyBG.Parent = root
            table.insert(cleanUpInstances, flyBG)
        end

        -- 防止 Humanoid 抢控制权（关键！否则飞不起来）
        if hum then
            hum.PlatformStand = true
        end

        local cam = Workspace.CurrentCamera or Camera
        local camCF = cam and cam.CFrame or CFrame.new()
        local dir = Vector3.zero

        -- ===== PC 键盘控制 =====
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir = dir + camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir = dir - camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir = dir + camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir = dir - camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
            dir = dir - Vector3.new(0, 1, 0)
        end

        -- ===== 手机 / 手柄：虚拟摇杆 (Humanoid.MoveDirection) =====
        -- 这样手机上推摇杆就能飞，不用键盘
        if hum and hum.MoveDirection.Magnitude > 0.08 then
            -- 把摇杆方向投影到摄像机水平面，保持自然手感
            local flatLook = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
            local flatRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
            if flatLook.Magnitude > 0.01 then flatLook = flatLook.Unit end
            if flatRight.Magnitude > 0.01 then flatRight = flatRight.Unit end

            -- MoveDirection 已是世界坐标，直接叠加更稳定；也可以用下面相对摄像机写法
            dir = dir + hum.MoveDirection
            -- 如果想完全相对摄像机水平方向，可用：
            -- dir = dir + flatLook * hum.MoveDirection.Z + flatRight * hum.MoveDirection.X
        end

        -- 手机上想上升/下降：可以用跳跃键（JumpRequest 会触发）或保持悬停
        -- 这里额外支持：如果同时按着跳跃且在飞，就上升
        if UserInputService:IsKeyDown(Enum.KeyCode.ButtonA) then  -- 手柄A / 部分手机映射
            dir = dir + Vector3.new(0, 1, 0)
        end

        flyBG.CFrame = CFrame.new(root.Position, root.Position + camCF.LookVector)
        if dir.Magnitude > 0.05 then
            flyBV.Velocity = dir.Unit * (Config.FlySpeed or 50)
        else
            -- 无输入时悬停（防止掉落）
            flyBV.Velocity = Vector3.zero
        end

        -- 双保险：直接写速度，防止游戏覆盖 BodyVelocity
        root.AssemblyLinearVelocity = flyBV.Velocity
    else
        -- 关闭飞行时清理
        if flyBV then
            local idx = table.find(cleanUpInstances, flyBV)
            if idx then table.remove(cleanUpInstances, idx) end
            pcall(function() flyBV:Destroy() end)
            flyBV = nil
        end
        if flyBG then
            local idx = table.find(cleanUpInstances, flyBG)
            if idx then table.remove(cleanUpInstances, idx) end
            pcall(function() flyBG:Destroy() end)
            flyBG = nil
        end
        if hum and hum.PlatformStand then
            hum.PlatformStand = false
        end
    end

    pcall(function()
        local useAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss
        if useAssist then
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local fUI = pg and pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Fishing")
            if fUI and fUI.Visible then
                local barFrame = fUI:FindFirstChild("BarFrame")
                if barFrame and barFrame:FindFirstChild("Bar") then
                    barFrame.Bar.Position = UDim2.new(0.5, 0, 0.5, 0)
                end
                local bossBar = fUI:FindFirstChild("BossFightBar")
                if bossBar and bossBar.Visible and bossBar:FindFirstChild("Bar") and bossBar:FindFirstChild("Hitbox") then
                    bossBar.Bar.Position = bossBar.Hitbox.Position
                    bossBar.Bar.Rotation = bossBar.Hitbox.Rotation
                end
                local hpPlayer = fUI:FindFirstChild("HPPlayer")
                if hpPlayer and hpPlayer:FindFirstChild("ProgressionBar") and hpPlayer.ProgressionBar:FindFirstChild("Bar") then
                    hpPlayer.ProgressionBar.Bar.Size = UDim2.new(1, 0, 1, 0)
                end
                local cutscene = pg:FindFirstChild("MainGui") and pg.MainGui:FindFirstChild("Cutscene")
                if cutscene and cutscene:FindFirstChild("Hurt") then cutscene.Hurt.ImageTransparency = 1 end
                local impactCutscene = pg:FindFirstChild("Impact") and pg.Impact:FindFirstChild("Cutscene")
                if impactCutscene and impactCutscene:FindFirstChild("Hurt") then impactCutscene.Hurt.ImageTransparency = 1 end
            end
        end

        if Config.FishRedRing then
            local fishPos = nil
            local now = tick()
            if (not cachedFishConstraint or not cachedFishConstraint.Parent or not cachedFishConstraint.Attachment1) and (now - lastConstraintSearch >= 0.5) then
                lastConstraintSearch = now
                if char then
                    for _, d in ipairs(char:GetChildren()) do
                        if d:IsA("Tool") then
                            for _, sub in ipairs(d:GetDescendants()) do
                                if (sub:IsA("Beam") or sub:IsA("RopeConstraint") or sub:IsA("SpringConstraint")) and sub.Attachment1 then
                                    cachedFishConstraint = sub
                                    break
                                end
                            end
                        end
                        if cachedFishConstraint then break end
                    end
                end
            end

            if cachedFishConstraint and cachedFishConstraint.Attachment1 then
                fishPos = cachedFishConstraint.Attachment1.WorldPosition
            else
                fishPos = cachedHookedPos
            end

            local isHooked = char and (char:GetAttribute("Fishing") == true or char:GetAttribute("Minigame") == true or cachedIsHooked)
            if isHooked and fishPos then
                fishRingAnchor.Position = fishPos
                if not fishRingAdornment.Visible then fishRingAdornment.Visible = true end
            else
                if fishRingAdornment.Visible then fishRingAdornment.Visible = false end
            end
        else
            if fishRingAdornment.Visible then fishRingAdornment.Visible = false end
        end
    end)
end))

local function ConnectDynamicMinigameRemote(rem)
    if not rem or not rem:IsA("RemoteEvent") then return end
    local rName = rem.Name
    if rName == "Slam" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(slamEvent)
            if isRunning and (Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoSlam) then
                if typeof(slamEvent) == "Instance" and slamEvent:IsA("RemoteEvent") then
                    pcall(function() slamEvent:FireServer("Perfect") end)
                else
                    pcall(function() rem:FireServer("Perfect") end)
                end
            end
        end))
    elseif rName == "Charge" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(chargeEvent)
            if isRunning and (Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoCharge) then
                if typeof(chargeEvent) == "Instance" and chargeEvent:IsA("RemoteEvent") then
                    pcall(function() chargeEvent:FireServer(100) end)
                else
                    pcall(function() rem:FireServer(100) end)
                end
            end
        end))
    elseif rName:find("Rhythm") or rName:find("Octo") or rName:find("QTE") or rName:find("Boss") then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(dynArg, ...)
            if isRunning and (Config.OctoAutoMinigame or Config.AnchorBar) then
                if typeof(dynArg) == "Instance" and dynArg:IsA("RemoteEvent") then
                    pcall(function() dynArg:FireServer("Perfect") end)
                    pcall(function() dynArg:FireServer(true, 100) end)
                else
                    pcall(function() rem:FireServer("Perfect") end)
                    pcall(function() rem:FireServer(true, 100) end)
                end
            end
        end))
    end
end

if Events then
    for _, child in ipairs(Events:GetChildren()) do
        ConnectDynamicMinigameRemote(child)
    end
    table.insert(activeConnections, Events.ChildAdded:Connect(ConnectDynamicMinigameRemote))
end
end -- end of Runtime Loops scope

table.insert(activeConnections, UserInputService.JumpRequest:Connect(function()
    if not isRunning then return end
    if Config.FlyEnabled then
        -- 手机上按跳跃键时，飞行状态下短暂上升
        if flyBV and flyBV.Parent then
            flyBV.Velocity = flyBV.Velocity + Vector3.new(0, Config.FlySpeed or 50, 0)
        end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then
            root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + Vector3.new(0, Config.FlySpeed or 50, 0)
        end
        return
    end
    if Config.InfiniteJump then
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

pcall(function()
    table.insert(activeConnections, LocalPlayer.Idled:Connect(function()
        if Config.AntiAFK and isRunning then
            local vu = game:GetService("VirtualUser")
            if vu then
                vu:CaptureController()
                vu:ClickButton2(Vector2.new(0, 0))
            end
        end
    end))
end)

table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl or input.KeyCode == Config.UIKeybind then
        if ToggleUiVisibility then ToggleUiVisibility() end
    elseif input.KeyCode == Enum.KeyCode.End or input.KeyCode == Config.StopKeybind then
        UnloadScript()
    end
end))

ShowNotification("🌙 IDENTICAL V1.6", "脚本已加载完成！控制台已就绪，点击 [-] 可收起为悬浮小月亮", "SUCCESS", 4.5)
