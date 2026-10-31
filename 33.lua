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

-- 保存脚本启动前的环境值，卸载时恢复原状，避免强制写入固定画质参数。
local originalLightingState = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    FogStart = Lighting.FogStart,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
}
-- 仅恢复本脚本实际修改过的视觉对象，避免关闭功能时写入猜测值。
local originalAtmosphereState = setmetatable({}, {__mode = "k"})
local originalParticleState = setmetatable({}, {__mode = "k"})
local originalGameGuiState = setmetatable({}, {__mode = "k"})
local function RememberAtmosphere(atmo)
    if atmo and atmo:IsA("Atmosphere") and not originalAtmosphereState[atmo] then
        originalAtmosphereState[atmo] = {
            Density = atmo.Density,
            Haze = atmo.Haze,
            Glare = atmo.Glare,
            Offset = atmo.Offset,
            Color = atmo.Color,
            Decay = atmo.Decay,
        }
    end
end
local function RestoreNoFogChanges()
    Lighting.FogEnd = originalLightingState.FogEnd
    Lighting.FogStart = originalLightingState.FogStart
    for atmo, state in pairs(originalAtmosphereState) do
        if atmo and atmo.Parent then
            pcall(function()
                atmo.Density = state.Density
                atmo.Haze = state.Haze
                atmo.Glare = state.Glare
                if state.Offset ~= nil then atmo.Offset = state.Offset end
                if state.Color ~= nil then atmo.Color = state.Color end
                if state.Decay ~= nil then atmo.Decay = state.Decay end
            end)
        end
    end
    for emitter, wasEnabled in pairs(originalParticleState) do
        if emitter and emitter.Parent then pcall(function() emitter.Enabled = wasEnabled end) end
    end
end

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Camera = Workspace.CurrentCamera
local function SetGameUIHidden(hidden)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, guiName in ipairs({"MainGui", "Fisher_GUI"}) do
        local gui = pg:FindFirstChild(guiName)
        if gui and gui:IsA("ScreenGui") then
            if originalGameGuiState[gui] == nil then originalGameGuiState[gui] = gui.Enabled end
            if hidden then
                gui.Enabled = false
            else
                gui.Enabled = originalGameGuiState[gui]
            end
        end
    end
end

local isRunning = true
local activeConnections = {}
local cameraViewportConn = nil
local UpdateMainFrameScale
local function BindCameraViewportSignal(cam)
    if cameraViewportConn then
        pcall(function() cameraViewportConn:Disconnect() end)
        cameraViewportConn = nil
    end
    if cam then
        cameraViewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if isRunning and UpdateMainFrameScale then
                UpdateMainFrameScale()
            end
        end)
    end
end
table.insert(activeConnections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
    BindCameraViewportSignal(Camera)
    if isRunning and UpdateMainFrameScale then
        UpdateMainFrameScale()
    end
end))
local cleanUpInstances = {}
local UIControls = {}
local currentSkillIndex = 1
local lockedCFrame = nil
local flyAscendUntil = 0
local currentlyOpenDropdown = nil

-- 动态探测并缓存玩家数据容器，兼容 Data / PlayerData / PlayersData 结构更新
local cachedDataContainer = nil
local cachedPlayerDataNode = nil
local warnedMissingDataRoot = false
local function GetPlayerData()
    if cachedPlayerDataNode and cachedPlayerDataNode.Parent then
        return cachedPlayerDataNode
    end
    local uidStr = tostring(LocalPlayer.UserId)
    if cachedDataContainer and cachedDataContainer.Parent then
        local found = cachedDataContainer:FindFirstChild(uidStr) or cachedDataContainer:FindFirstChild(LocalPlayer.Name)
        if found then
            cachedPlayerDataNode = found
            return found
        end
    end
    for _, folderName in ipairs({"Data", "PlayerData", "PlayersData"}) do
        local folder = ReplicatedStorage:FindFirstChild(folderName)
        if folder then
            local found = folder:FindFirstChild(uidStr) or folder:FindFirstChild(LocalPlayer.Name)
            if found then
                cachedDataContainer = folder
                cachedPlayerDataNode = found
                return found
            end
        end
    end
    if not warnedMissingDataRoot then
        warnedMissingDataRoot = true
        warn("[IDENTICAL] 尚未找到 ReplicatedStorage 下的玩家数据节点，等待角色数据加载...")
    end
    return nil
end

-- 角色零件与物理缓存（优化 GC）
local cachedCharacterParts = {}
local characterConnections = {}
-- 仅记录本脚本实际改动过的碰撞属性；关闭或卸载时恢复。
local originalCanCollide = setmetatable({}, {__mode = "k"})
local originalHumanoidState = setmetatable({}, {__mode = "k"})
local function RememberHumanoidState(hum)
    if hum and not originalHumanoidState[hum] then
        originalHumanoidState[hum] = {
            WalkSpeed = hum.WalkSpeed,
            PlatformStand = hum.PlatformStand,
        }
    end
end
local noclipWasActive = false
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
    RhythmAccuracy = 100,
    AutoEnzoMinigame = false,
    AutoFarmBoss = false,
    EnzoDifficulty = "简单",
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
    AutoGiveMonkey = false,
    MonkeyGiveCount = 100,
    
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
-- 以下兼容字段目前没有可靠的游戏数据/交互依据，不应在 UI 中标记为已实现：
-- CastPower、SelectedSkill、SelectedBoss、AutoGodSpiritCheck、AutoExecuteOnJoin。
-- 保留字段以兼容旧配置文件，但不将它们当作有效功能。

local QuestDiffMap = {
    ["简单"] = "Easy",
    ["困难"] = "Hard",
    ["Easy"] = "Easy",
    ["Hard"] = "Hard"
}

-- 执行器能力集中探测表（Capabilities）与可选 Hook 生命周期管理
local Capabilities = {
    FileIO = (type(readfile) == "function" and type(writefile) == "function"),
    FolderIO = (type(makefolder) == "function" and type(isfolder) == "function"),
    Clipboard = (type(setclipboard) == "function"),
    ProximityPrompt = (type(fireproximityprompt) == "function"),
    SignalFire = (type(firesignal) == "function" or type(getconnections) == "function"),
    Http = (type(request) == "function" or type(http_request) == "function" or (type(syn) == "table" and type(syn.request) == "function") or (type(http) == "table" and type(http.request) == "function")),
    Hook = (type(hookmetamethod) == "function" and type(newcclosure) == "function" and type(getnamecallmethod) == "function" and type(checkcaller) == "function"),
}

if sharedEnv then
    sharedEnv.IdenticalFishingConfig = Config
    sharedEnv.IdenticalFishingRunning = true

    if Capabilities.Hook and not sharedEnv.IdenticalHookInstalled then
        local preSavedNamecall = nil
        if type(getrawmetatable) == "function" then
            pcall(function()
                local mt = getrawmetatable(game)
                if type(mt) == "table" and type(rawget(mt, "__namecall")) == "function" then
                    preSavedNamecall = rawget(mt, "__namecall")
                end
            end)
        end

        local hookOk, hookErr = pcall(function()
            local oldNamecall = preSavedNamecall
            local retNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                local orig = oldNamecall or (sharedEnv and sharedEnv.IdenticalOldNamecall)
                if type(orig) ~= "function" then return nil end
                if not sharedEnv or not sharedEnv.IdenticalFishingRunning then
                    return orig(self, ...)
                end
                local method = getnamecallmethod()
                if method == "FireServer" and not checkcaller() and typeof(self) == "Instance" then
                    local cfg = sharedEnv.IdenticalFishingConfig
                    if cfg then
                        local assistActive = cfg.AnchorBar or cfg.OctoAutoMinigame or cfg.AutoFarmSecretBoss or cfg.AutoFarmBoss
                        local okName, rName = pcall(function() return self.Name end)
                        if okName and type(rName) == "string" then
                            if rName == "FishingMinigame" and assistActive then
                                local args = {...}
                                local action = tostring(args[1])
                                if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar") or action:find("Fail") or action:find("Miss") then
                                    return orig(self, "In bar", unpack(args, 2))
                                end
                            elseif rName == "Slam" and cfg.AutoSlam then
                                local args = {...}
                                local firstArg = args[1]
                                if firstArg == nil or firstArg == false or tostring(firstArg):lower():find("miss") or tostring(firstArg):lower():find("fail") or tostring(firstArg):lower():find("bad") then
                                    return orig(self, "Perfect")
                                end
                            elseif (rName:find("Rhythm") or rName:find("QTE") or rName:find("Octo")) and (cfg.OctoAutoMinigame or cfg.AutoSlam) then
                                local args = {...}
                                local firstArg = args[1]
                                if firstArg == nil or firstArg == false or tostring(firstArg):lower():find("miss") or tostring(firstArg):lower():find("fail") or tostring(firstArg):lower():find("bad") then
                                    args[1] = (type(firstArg) == "boolean") and true or "Perfect"
                                    if args[2] == nil or type(args[2]) == "number" then args[2] = 100 end
                                    return orig(self, unpack(args))
                                end
                            elseif rName == "Charge" and cfg.AutoCharge then
                                local args = {...}
                                if args[1] == nil or (type(args[1]) == "number" and args[1] < 100) then
                                    return orig(self, 100)
                                end
                            end
                        end
                    end
                end
                return orig(self, ...)
            end))
            if type(retNamecall) == "function" then
                oldNamecall = retNamecall
            end
            if type(oldNamecall) == "function" then
                sharedEnv.IdenticalOldNamecall = oldNamecall
                sharedEnv.IdenticalHookInstalled = true
            else
                sharedEnv.IdenticalOldNamecall = nil
                sharedEnv.IdenticalHookInstalled = false
                if type(restorefunction) == "function" then pcall(restorefunction, game) end
                warn("[IDENTICAL] hookmetamethod 未返回原始 __namecall，已启用安全保护分支。")
            end
        end)

        if not hookOk then
            warn("[IDENTICAL] Hook 安装失败，已跳过可选 Hook：" .. tostring(hookErr))
        end
    elseif not Capabilities.Hook then
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

local function NormalizeProfileName(name)
    if type(name) ~= "string" then name = "default" end
    name = name:match("^%s*(.-)%s*$") or ""
    name = name:gsub("[/\\:%*?\"<>|%.%c]", "")
    if name == "" then name = "default" end
    return name:sub(1, 32)
end

local function GetProfilePath(name)
    return PROFILE_DIR .. "/" .. NormalizeProfileName(name or Config.ActiveProfile) .. ".json"
end

-- 对旧配置执行边界校验：类型正确不代表数值一定合理。
local ConfigNumericBounds = {
    UIScale = {0.5, 1.2}, CastDelay = {0.1, 10}, CastPower = {0, 100},
    SkillInterval = {0.5, 5}, SellInterval = {5, 3600}, DailyClaimDelay = {0.3, 2},
    CraftAmount = {1, 10}, BuyBaitAmount = {1, 50}, BuyBaitThreshold = {5, 50},
    BuyBaitDelay = {5, 3600}, WalkSpeedValue = {16, 120}, FlySpeed = {20, 150},
    MonkeyGiveCount = {1, 500},
    RhythmAccuracy = {50, 100},
}

local function SanitizeConfigValue(key, value, defaultValue)
    if type(value) ~= type(defaultValue) then return defaultValue end
    local bounds = ConfigNumericBounds[key]
    if bounds and type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return defaultValue end
        return math.clamp(value, bounds[1], bounds[2])
    end
    if type(value) == "string" then
        if #value > 256 then return defaultValue end
        if key == "ActiveProfile" then return NormalizeProfileName(value) end
    end
    return value
end

local function SaveProfile(name)
    EnsureProfileDir()
    local path = GetProfilePath(name)
    local data = {}
    for k, v in pairs(Config) do
        if typeof(v) == "EnumItem" then data[k] = {__enum = tostring(v)} else data[k] = v end
    end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if ok and type(writefile) == "function" then
        local writeOk = pcall(function() writefile(path, encoded) end)
        return writeOk == true
    end
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
    if Config.Fullbright or Config.NoFog or Config.PerformanceMode then
        if ApplyLightingSettings then pcall(ApplyLightingSettings) end
    end
    if Config.HideGameUI then pcall(SetGameUIHidden, true) end
    if Config.Disable3DRendering and blackOutFrame then
        blackOutFrame.Visible = true
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
    end
end

local function LoadProfile(name)
    local path = GetProfilePath(name)
    if readfile then
        local ok, content = pcall(function() return readfile(path) end)
        if ok and content and #content > 0 then
            local decOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
            if decOk and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    local current = Config[k]
                    if current ~= nil and type(v) == "table" and type(v.__enum) == "string" and typeof(current) == "EnumItem" then
                        local enumType, enumName = v.__enum:match("Enum%.(%w+)%.(%w+)")
                        if enumType and enumName and Enum[enumType] and Enum[enumType][enumName] then
                            Config[k] = Enum[enumType][enumName]
                        end
                    elseif current ~= nil and typeof(current) ~= "EnumItem" then
                        -- 保留旧版配置兼容，同时拒绝类型错误、异常长度和越界数值。
                        Config[k] = SanitizeConfigValue(k, v, current)
                    end
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
            if decOk and type(decoded) == "table" then
                local validated = {}
                for _, item in ipairs(decoded) do
                    if type(item) == "table" and type(item.name) == "string"
                        and type(item.x) == "number" and type(item.y) == "number" and type(item.z) == "number"
                        and item.x == item.x and item.y == item.y and item.z == item.z
                        and math.abs(item.x) < 1000000 and math.abs(item.y) < 1000000 and math.abs(item.z) < 1000000 then
                        table.insert(validated, {
                            name = item.name:sub(1, 48),
                            x = item.x, y = item.y, z = item.z,
                        })
                        if #validated >= 100 then break end
                    end
                end
                CustomTPs = validated
            end
        end
    end
end

local function SaveCustomTPs()
    EnsureProfileDir()
    if type(writefile) == "function" then
        local ok, encoded = pcall(function() return HttpService:JSONEncode(CustomTPs) end)
        if ok then
            local writeOk = pcall(function() writefile(CustomTP_FILE, encoded) end)
            return writeOk == true
        end
    end
    return false
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
screenGui.IgnoreGuiInset = true
pcall(function() screenGui.ScreenInsets = Enum.ScreenInsets.None end)
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
do
    local blackOutLabel = Instance.new("TextLabel")
    blackOutLabel.Size = UDim2.new(1, 0, 0, 40)
    blackOutLabel.Position = UDim2.new(0, 0, 0.1, 0)
    blackOutLabel.BackgroundTransparency = 1
    blackOutLabel.Font = Enum.Font.GothamBold
    blackOutLabel.Text = "⚡ 极致省电挂机模式运行中 (已关闭 3D 渲染)"
    blackOutLabel.TextColor3 = Colors.PurplePrimary
    blackOutLabel.TextSize = 16
    blackOutLabel.Parent = blackOutFrame
end

-- 预声明需要在卸载时重置的缓存与状态变量
local patternCache = {}
local patternCacheCount = 0
local cachedRuleMatchers = {}
local cachedRuleSource = nil
local lastLockSentAt = setmetatable({}, { __mode = "k" })
local knownLockedUntil = setmetatable({}, { __mode = "k" })
local lastLockSentByName = {}
local isSellingInProgress = false
local useNameForSingleSell = false
local isClaimingDailyTask = false
local isClaimingDailySign = false
local activePromptTasks = setmetatable({}, { __mode = "k" })
local OnlineNPCs = {}
local isMicroTeleportingNPC = false
local DismissStuckPromptsAndRestore
local liveNPCOrder = {
    "Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber",
    "Taoist", "Maoshan", "DumbGuy",
    "VermilionBird", "BlackTortoise", "WhiteTiger", "AzureDragon"
}
local liveNPCs = {
    Spirit_Bamboo = {pos = nil, inst = nil, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), name = "竹岛神灵 (Bamboo Spirit)", icon = "⛩️", desc = "神灵 #1 · 竹岛 [2] · 50M祈祷祝福"},
    Spirit_Frost  = {pos = nil, inst = nil, fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4), name = "冰霜岛神灵 (Frost Spirit)", icon = "❄️", desc = "神灵 #2 · 冰霜岛 [6] · 50M祈祷祝福"},
    Spirit_Amber  = {pos = nil, inst = nil, fallbackPos = Vector3.new(1259.4, 9.1, 1401.5), name = "琥珀岛神灵 (Amber Spirit)", icon = "🔥", desc = "神灵 #3 · 琥珀岛 [8] · 50M祈祷祝福"},
    Taoist        = {pos = nil, inst = nil, fallbackPos = nil, name = "道士商人 (Taoist Merchant)", icon = "📜", desc = "流动商人 · 100M道士珠 / 200M极鹰猎 / 接神灵任务"},
    Maoshan       = {pos = nil, inst = nil, fallbackPos = nil, name = "茅山商人 (Maoshan Merchant)", icon = "✨", desc = "流动商人 · 300M茅山竿 / 200M茅山珠 / 镇江"},
    DumbGuy       = {pos = nil, inst = nil, fallbackPos = nil, name = "傻子隐藏商人 (Dumb Guy)", icon = "🃏", desc = "轮换隐藏商人 · 六脉神鹰 / 道士卡"},
    VermilionBird = {pos = nil, inst = nil, fallbackPos = nil, name = "四圣兽·朱雀 (Vermilion Bird)", icon = "🦅", desc = "四圣兽之首 · 50%减CD+重置冷却 / 朱雀Boss"},
    BlackTortoise = {pos = nil, inst = nil, fallbackPos = nil, name = "四圣兽·玄武 (Black Tortoise)", icon = "🐢", desc = "四圣兽之盾 · 20秒无敌+回血眩晕 / 玄武血脉Boss"},
    WhiteTiger    = {pos = nil, inst = nil, fallbackPos = nil, name = "四圣兽·白虎 (White Tiger)", icon = "🐯", desc = "四圣兽之锋 · 50%暴击+100%暴伤叠层"},
    AzureDragon   = {pos = nil, inst = nil, fallbackPos = nil, name = "四圣兽·青龙 (Azure Dragon)", icon = "🐉", desc = "四圣兽之威 · 150%增伤+低血无视无敌"},
}

-- 卸载过程只允许执行一次，防止关闭按钮、重复执行和重生回调并发触发清理。
-- 注意：卸载时不直接覆写 Config.FlyEnabled / Config.Noclip，避免破坏用户内存中或即将保存的配置，
-- 所有物理与穿墙循环均通过 isRunning 状态位安全停止并恢复原状。
local unloadStarted = false
local function UnloadScript()
    if unloadStarted then return false end
    unloadStarted = true
    isRunning = false
    flyAscendUntil = 0
    currentlyOpenDropdown = nil
    if cameraViewportConn then
        pcall(function() cameraViewportConn:Disconnect() end)
        cameraViewportConn = nil
    end
    if sharedEnv then
        sharedEnv.IdenticalFishingRunning = false
        sharedEnv.IdenticalHeavyweightFishingUnload = nil
        sharedEnv.IdenticalFishingConfig = nil
        if sharedEnv.IdenticalHookInstalled and type(sharedEnv.IdenticalOldNamecall) == "function" then
            if type(restorefunction) == "function" then
                local resOk = pcall(restorefunction, game)
                if resOk then
                    sharedEnv.IdenticalHookInstalled = false
                    sharedEnv.IdenticalOldNamecall = nil
                end
            end
        end
    end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    for _, conn in ipairs(activeConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(activeConnections)
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    for _, inst in ipairs(cleanUpInstances) do pcall(function() if inst and inst.Parent then inst:Destroy() end end) end
    table.clear(cleanUpInstances)
    -- 先恢复角色状态，再清空缓存，避免卸载时留下穿墙/飞行状态。
    -- 每个对象单独保护：单个已销毁对象恢复失败，不应阻断其余对象恢复。
    for part, oldValue in pairs(originalCanCollide) do
        if part and part.Parent then
            pcall(function() part.CanCollide = oldValue end)
        end
    end
    table.clear(originalCanCollide)
    for hum, state in pairs(originalHumanoidState) do
        if hum and hum.Parent then
            pcall(function()
                hum.PlatformStand = state.PlatformStand
                hum.WalkSpeed = state.WalkSpeed
            end)
        end
    end
    table.clear(originalHumanoidState)
    table.clear(cachedCharacterParts)
    pcall(function() local leftover = Workspace:FindFirstChild("IdenticalESP"); if leftover then leftover:Destroy() end end)
    pcall(function()
        for gui, wasEnabled in pairs(originalGameGuiState) do
            if gui and gui.Parent then pcall(function() gui.Enabled = wasEnabled end) end
        end
        table.clear(originalGameGuiState)
        pcall(RestoreNoFogChanges)
        for property, value in pairs(originalLightingState) do
            pcall(function() Lighting[property] = value end)
        end
    end)
    table.clear(patternCache)
    patternCacheCount = 0
    table.clear(cachedRuleMatchers)
    cachedRuleSource = nil
    table.clear(lastLockSentAt)
    table.clear(knownLockedUntil)
    table.clear(lastLockSentByName)
    table.clear(activePromptTasks)
    if DismissStuckPromptsAndRestore then pcall(DismissStuckPromptsAndRestore, false) end
    table.clear(OnlineNPCs)
    isMicroTeleportingNPC = false
    isSellingInProgress = false
    useNameForSingleSell = false
    isClaimingDailyTask = false
    isClaimingDailySign = false
    cachedFishConstraint = nil
    lockedCFrame = nil
    noclipWasActive = false
    return true
end

if sharedEnv then sharedEnv.IdenticalHeavyweightFishingUnload = UnloadScript end

local notifContainer = Instance.new("Frame"); notifContainer.Name = "Notifications"; notifContainer.Size = UDim2.new(0, 300, 1, -40); notifContainer.Position = UDim2.new(1, -315, 0, 20); notifContainer.BackgroundTransparency = 1; notifContainer.ZIndex = 1000; notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)
local notifLayout = Instance.new("UIListLayout"); notifLayout.SortOrder = Enum.SortOrder.LayoutOrder; notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom; notifLayout.Padding = UDim.new(0, 8); notifLayout.Parent = notifContainer

local activeNotifCards = {}
local recentNotifMap = {}
local MAX_NOTIF_CARDS = 4

local function ShowNotification(title, text, notifType, duration)
    if not isRunning or not notifContainer or not notifContainer.Parent then return end
    duration = duration or 3.2
    local now = tick()
    local dedupKey = tostring(title) .. "|" .. tostring(text)
    if recentNotifMap[dedupKey] and (now - recentNotifMap[dedupKey] < 1.2) then
        return
    end
    recentNotifMap[dedupKey] = now
    for k, t in pairs(recentNotifMap) do
        if now - t > 5.0 then recentNotifMap[k] = nil end
    end

    for i = #activeNotifCards, 1, -1 do
        if not activeNotifCards[i] or not activeNotifCards[i].Parent then
            table.remove(activeNotifCards, i)
        end
    end
    while #activeNotifCards >= MAX_NOTIF_CARDS do
        local oldest = table.remove(activeNotifCards, 1)
        if oldest and oldest.Parent then pcall(function() oldest:Destroy() end) end
    end

    local accentColor = Colors.PurpleAccent
    if notifType == "SUCCESS" then accentColor = Colors.AccentGreen elseif notifType == "WARN" then accentColor = Colors.AccentYellow elseif notifType == "ERROR" then accentColor = Colors.AccentRed end

    -- 使用外层透明 slot 承接 UIListLayout 排版，内层 card 独立做横向滑入动画，彻底消除 UIListLayout 与 Position Tween 冲突卡顿
    local slot = Instance.new("Frame"); slot.Size = UDim2.new(1, 0, 0, 62); slot.BackgroundTransparency = 1; slot.BorderSizePixel = 0; slot.Parent = notifContainer
    table.insert(activeNotifCards, slot)

    local card = Instance.new("Frame"); card.Size = UDim2.new(1, 0, 1, 0); card.Position = UDim2.new(1, 30, 0, 0); card.BackgroundColor3 = Colors.Background; card.BackgroundTransparency = 0.06; card.BorderSizePixel = 0; card.ClipsDescendants = true; card.Active = true; card.Parent = slot
    local stroke = Instance.new("UIStroke"); stroke.Color = accentColor; stroke.Thickness = 1.2; stroke.Transparency = 0.2; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = card
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 20); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 12, 0, 6); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -24, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = title; tLabel.TextColor3 = Colors.PurplePrimary; tLabel.TextSize = 13; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -24, 0, 28); mLabel.Position = UDim2.new(0, 12, 0, 26); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = text; mLabel.TextColor3 = Colors.TextSubtle; mLabel.TextSize = 11; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.Parent = card

    TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = UDim2.new(0, 0, 0, 0)}):Play()

    local dismissed = false
    local function dismissCard()
        if dismissed then return end
        dismissed = true
        if not isRunning then
            if slot and slot.Parent then pcall(function() slot:Destroy() end) end
            return
        end
        if slot and slot.Parent and card and card.Parent then
            pcall(function()
                TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1, Position = UDim2.new(1, 40, 0, 0)}):Play()
            end)
            task.delay(0.24, function()
                if slot and slot.Parent then pcall(function() slot:Destroy() end) end
            end)
        end
    end

    -- 支持手指/鼠标轻触通知卡片立即滑出关闭，不遮挡手机屏幕操作
    card.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dismissCard()
        end
    end)

    task.delay(duration, dismissCard)
end

local isHopping = false
local function FetchUrlBody(url)
    local reqFn = (type(syn) == "table" and type(syn.request) == "function" and syn.request)
        or (type(http) == "table" and type(http.request) == "function" and http.request)
        or (type(http_request) == "function" and http_request)
        or (type(request) == "function" and request)
    if reqFn then
        local ok, res = pcall(reqFn, {Url = url, Method = "GET"})
        if ok and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then
            return res.Body
        end
    end
    if type(httpget) == "function" then
        local ok, body = pcall(httpget, url)
        if ok and type(body) == "string" and #body > 0 then return body end
    end
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" and #body > 0 then return body end
    return nil
end

local function ServerHop()
    if isHopping then return end
    isHopping = true
    ShowNotification("服务器跳转", "正在搜索可用服务器...", "WARN")
    task.spawn(function()
        local teleported = false
        local placeId = game.PlaceId
        local ok = pcall(function()
            local apiHost = "games." .. "roblox.com"
            local url = string.format("https://%s/v1/games/%s/servers/Public?sortOrder=Desc&limit=100", apiHost, tostring(placeId))
            local rawBody = FetchUrlBody(url)
            local body = rawBody and HttpService:JSONDecode(rawBody) or nil
            if body and body.data then
                local candidates = {}
                for _, s in ipairs(body.data) do
                    if type(s.playing) == "number" and type(s.maxPlayers) == "number" and s.playing < s.maxPlayers and s.id ~= game.JobId then
                        table.insert(candidates, s.id)
                    end
                end
                if #candidates > 0 then
                    local chosen = candidates[math.random(1, #candidates)]
                    teleported = true
                    TeleportService:TeleportToPlaceInstance(placeId, chosen, LocalPlayer)
                    return
                end
            end
        end)
        if not teleported then
            local fallbackOk = pcall(function()
                ShowNotification("服务器跳转", "列表接口受限或无空位，正在尝试随机重连服务器...", "WARN")
                TeleportService:Teleport(placeId, LocalPlayer)
            end)
            if not ok and not fallbackOk then
                ShowNotification("服务器跳转", "获取服务器列表失败，稍后重试。", "ERROR")
            end
        end
        task.wait(4)
        isHopping = false
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

    local fcDragging = false
    local fcActiveTouch = nil
    local fcDragStart = nil
    local fcStartAbs = nil
    local dragMovedDistance = 0
    local fcInputEndConn = nil

    local function getScreenBoundsSize()
        if screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize.Y > 0 then
            return screenGui.AbsoluteSize
        end
        local cam = Workspace.CurrentCamera or Camera
        return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    end

    local function updateCrescentPosition(inputPos)
        if not fcDragging or not fcDragStart or not fcStartAbs then return end
        local delta = inputPos - fcDragStart
        dragMovedDistance = math.max(dragMovedDistance, delta.Magnitude)
        local vp = getScreenBoundsSize()
        local guiOrigin = (screenGui and screenGui.Parent and screenGui.AbsolutePosition) or Vector2.zero
        local btnW = floatingCrescent.AbsoluteSize.X > 0 and floatingCrescent.AbsoluteSize.X or 48
        local btnH = floatingCrescent.AbsoluteSize.Y > 0 and floatingCrescent.AbsoluteSize.Y or 48
        local localX = (fcStartAbs.X - guiOrigin.X) + delta.X
        local localY = (fcStartAbs.Y - guiOrigin.Y) + delta.Y
        local clampedX = math.clamp(localX, 0, math.max(0, vp.X - btnW))
        local clampedY = math.clamp(localY, 0, math.max(0, vp.Y - btnH))
        floatingCrescent.Position = UDim2.fromOffset(clampedX, clampedY)
    end

    floatingCrescent.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            fcDragging = true
            fcActiveTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
            dragMovedDistance = 0
            fcDragStart = input.Position
            local vp = getScreenBoundsSize()
            local curPos = floatingCrescent.Position
            if floatingCrescent.AbsolutePosition.X ~= 0 or floatingCrescent.AbsolutePosition.Y ~= 0 then
                fcStartAbs = floatingCrescent.AbsolutePosition
            else
                fcStartAbs = Vector2.new(curPos.X.Scale * vp.X + curPos.X.Offset, curPos.Y.Scale * vp.Y + curPos.Y.Offset)
            end
            if fcInputEndConn then pcall(function() fcInputEndConn:Disconnect() end); fcInputEndConn = nil end
            fcInputEndConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                    fcDragging = false
                    fcActiveTouch = nil
                    if fcInputEndConn then pcall(function() fcInputEndConn:Disconnect() end); fcInputEndConn = nil end
                elseif fcDragging and (input == fcActiveTouch or input.UserInputType == Enum.UserInputType.Touch) then
                    updateCrescentPosition(input.Position)
                end
            end)
        end
    end)

    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if not fcDragging then return end
        if fcActiveTouch then
            if input == fcActiveTouch or input.UserInputType == Enum.UserInputType.Touch then
                updateCrescentPosition(input.Position)
            end
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            updateCrescentPosition(input.Position)
        end
    end))

    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if not fcDragging then return end
        if (fcActiveTouch and input == fcActiveTouch) or (not fcActiveTouch and input.UserInputType == Enum.UserInputType.MouseButton1) then
            fcDragging = false
            fcActiveTouch = nil
            if fcInputEndConn then pcall(function() fcInputEndConn:Disconnect() end); fcInputEndConn = nil end
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

    if floatingCrescent.Activated then
        floatingCrescent.Activated:Connect(handleToggleTrigger)
    else
        floatingCrescent.MouseButton1Click:Connect(handleToggleTrigger)
    end

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

UpdateMainFrameScale = function()
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
BindCameraViewportSignal(Camera)

do local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame; local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame end

local rowSearchIndex = {}
local navList, tabCanvasRefreshers, SwitchTab, CreateTab, CloseUI
do -- Window Frame Construction Scope
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
    local dragging = false
    local activeDragTouch = nil
    local dragStart = nil
    local startPos = nil
    local titleInputEndConn = nil

    local function updateMainFrameDrag(inputPos)
        if not dragging or not dragStart or not startPos then return end
        local delta = inputPos - dragStart
        local vp = (screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize)
            or ((Workspace.CurrentCamera or Camera) and (Workspace.CurrentCamera or Camera).ViewportSize)
            or Vector2.new(1280, 720)
        local absX = startPos.X.Scale * vp.X + startPos.X.Offset + delta.X
        local absY = startPos.Y.Scale * vp.Y + startPos.Y.Offset + delta.Y
        local frameW = mainFrame.AbsoluteSize.X > 0 and mainFrame.AbsoluteSize.X or 700
        local frameH = mainFrame.AbsoluteSize.Y > 0 and mainFrame.AbsoluteSize.Y or 480
        absX = math.clamp(absX, -frameW + 60, vp.X - 60)
        absY = math.clamp(absY, -frameH + 40, vp.Y - 40)
        mainFrame.Position = UDim2.fromOffset(absX, absY)
    end

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            activeDragTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
            dragStart = input.Position
            startPos = mainFrame.Position
            if titleInputEndConn then pcall(function() titleInputEndConn:Disconnect() end); titleInputEndConn = nil end
            titleInputEndConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                    dragging = false
                    activeDragTouch = nil
                    if titleInputEndConn then pcall(function() titleInputEndConn:Disconnect() end); titleInputEndConn = nil end
                elseif dragging and (input == activeDragTouch or input.UserInputType == Enum.UserInputType.Touch) then
                    updateMainFrameDrag(input.Position)
                end
            end)
        end
    end)

    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if activeDragTouch then
            if input == activeDragTouch or input.UserInputType == Enum.UserInputType.Touch then
                updateMainFrameDrag(input.Position)
            end
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            updateMainFrameDrag(input.Position)
        end
    end))

    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if not dragging then return end
        if (activeDragTouch and input == activeDragTouch) or (not activeDragTouch and input.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = false
            activeDragTouch = nil
            if titleInputEndConn then pcall(function() titleInputEndConn:Disconnect() end); titleInputEndConn = nil end
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

rowSearchIndex = {}
local currentActiveTab = nil
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = searchBox.Text:lower():match("^%s*(.-)%s*$")
    local cardHasVisible = {}
    local allCards = {}
    for i = 1, #rowSearchIndex do
        local item = rowSearchIndex[i]
        local f = item.frame
        if f and f.Parent then
            local show = (q == "" or item.query:find(q, 1, true) ~= nil)
            if f.Visible ~= show then f.Visible = show end
            local p = f.Parent
            if p and p:IsA("Frame") then
                allCards[p] = true
                if show then cardHasVisible[p] = true end
            end
        end
    end
    for cardGroup in pairs(allCards) do
        local shouldShowCard = (q == "") or (cardHasVisible[cardGroup] == true)
        if cardGroup.Visible ~= shouldShowCard then
            cardGroup.Visible = shouldShowCard
        end
    end
    if currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab] then
        pcall(tabCanvasRefreshers[currentActiveTab])
    end
end)

-- 手机端滚动：不依赖 UIListLayout.AbsoluteContentSize（对 AutomaticSize 子项经常算矮），
-- 改为直接累加可见子控件真实高度，彻底解决“滑到一半就到底/弹回、下面功能够不到”。
local function BindVerticalCanvas(scrollFrame, listLayout, extraPadding)
    extraPadding = extraPadding or 0
    scrollFrame.Active = true
    scrollFrame.ScrollingEnabled = true
    scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    scrollFrame.ElasticBehavior = Enum.ElasticBehavior.Never
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    scrollFrame.ScrollBarThickness = math.max(scrollFrame.ScrollBarThickness, 4)

    local lastCanvasH = -1
    local refreshing = false
    local listPadding = 0
    if listLayout and listLayout.Padding then
        listPadding = listLayout.Padding.Offset or 0
    end

    local function measureContentHeight()
        local padY = 0
        local uiPad = scrollFrame:FindFirstChildOfClass("UIPadding")
        if uiPad then
            padY = (uiPad.PaddingTop and uiPad.PaddingTop.Offset or 0)
                + (uiPad.PaddingBottom and uiPad.PaddingBottom.Offset or 0)
        end

        -- UIScale 在祖先上时 AbsoluteSize 是屏幕像素，CanvasSize 需要本地坐标。
        -- 必须把 Absolute 高度除以 scale，否则 Canvas 会偏小导致“滑不到底”。
        local scale = 1
        if mainFrameScale and mainFrameScale.Parent and type(mainFrameScale.Scale) == "number" and mainFrameScale.Scale > 0.05 then
            scale = mainFrameScale.Scale
        end

        local totalAbs = 0
        local visibleCount = 0
        for _, child in ipairs(scrollFrame:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible
                and not child:IsA("UIListLayout")
                and not child:IsA("UIPadding")
                and not child:IsA("UICorner")
                and not child:IsA("UIStroke")
                and not child:IsA("UIGridLayout")
                and not child:IsA("UIPageLayout") then
                local h = child.AbsoluteSize.Y
                -- AutomaticSize 卡片在首帧可能仍是 0，退回用 AbsoluteContentSize / 子项累加
                if h < 1 and child.AutomaticSize ~= Enum.AutomaticSize.None then
                    local subLayout = child:FindFirstChildOfClass("UIListLayout")
                    if subLayout and subLayout.AbsoluteContentSize.Y > 0 then
                        -- AbsoluteContentSize 已是本地坐标，转成“假 Absolute”再统一除 scale
                        h = subLayout.AbsoluteContentSize.Y * scale
                    else
                        local subH = 0
                        for _, sub in ipairs(child:GetChildren()) do
                            if sub:IsA("GuiObject") and sub.Visible
                                and not sub:IsA("UIListLayout") and not sub:IsA("UIPadding")
                                and not sub:IsA("UICorner") and not sub:IsA("UIStroke") then
                                subH = subH + math.max(sub.AbsoluteSize.Y, 0)
                            end
                        end
                        if subH > 0 then h = subH end
                    end
                end
                if h > 0 then
                    totalAbs = totalAbs + h
                    visibleCount = visibleCount + 1
                end
            end
        end
        if visibleCount > 1 then
            -- listPadding 是本地 Offset，先乘 scale 再和 Absolute 一起除
            totalAbs = totalAbs + (listPadding * (visibleCount - 1) * scale)
        end

        local totalLocal = totalAbs / scale
        -- AbsoluteContentSize 本身就是本地坐标，与转换后的 total 取较大值
        local layoutH = (listLayout and listLayout.AbsoluteContentSize.Y or 0) + padY
        totalLocal = math.max(totalLocal + padY, layoutH)
        -- 额外多留一点底部余量，避免最后一项贴边或被裁切
        return totalLocal + extraPadding
    end

    local function refreshCanvas()
        if refreshing or not scrollFrame or not scrollFrame.Parent then return end
        refreshing = true
        pcall(function()
            local contentHeight = measureContentHeight()
            local viewportHeight = scrollFrame.AbsoluteWindowSize.Y
            if viewportHeight < 1 then
                viewportHeight = scrollFrame.AbsoluteSize.Y
            end
            local canvasHeight = math.max(math.ceil(contentHeight), 1)

            if math.abs(canvasHeight - lastCanvasH) >= 1 then
                lastCanvasH = canvasHeight
                scrollFrame.CanvasSize = UDim2.new(0, 0, 0, canvasHeight)
            end

            -- 仅内容变短越界时回拉，避免下滑被弹回
            local maxY = math.max(0, canvasHeight - math.max(viewportHeight, 1))
            local curY = scrollFrame.CanvasPosition.Y
            if curY > maxY + 2 then
                scrollFrame.CanvasPosition = Vector2.new(scrollFrame.CanvasPosition.X, maxY)
            elseif curY < 0 then
                scrollFrame.CanvasPosition = Vector2.new(scrollFrame.CanvasPosition.X, 0)
            end
        end)
        refreshing = false
    end

    local refreshQueued = false
    local lastRefreshTime = 0
    local function requestRefresh()
        if refreshQueued or not isRunning or not scrollFrame or not scrollFrame.Parent then return end
        refreshQueued = true
        local elapsed = tick() - lastRefreshTime
        if elapsed >= 0.08 then
            task.defer(function()
                refreshQueued = false
                lastRefreshTime = tick()
                if isRunning then refreshCanvas() end
            end)
        else
            task.delay(0.08 - elapsed, function()
                refreshQueued = false
                lastRefreshTime = tick()
                if isRunning then refreshCanvas() end
            end)
        end
    end

    local function bindChildSignals(child)
        if child:IsA("GuiObject") then
            table.insert(activeConnections, child:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestRefresh))
            table.insert(activeConnections, child:GetPropertyChangedSignal("Visible"):Connect(requestRefresh))
        end
    end

    if listLayout then
        table.insert(activeConnections, listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(requestRefresh))
    end
    table.insert(activeConnections, scrollFrame:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(requestRefresh))
    table.insert(activeConnections, scrollFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestRefresh))
    table.insert(activeConnections, scrollFrame.ChildAdded:Connect(function(child)
        requestRefresh()
        bindChildSignals(child)
    end))
    for _, child in ipairs(scrollFrame:GetChildren()) do
        bindChildSignals(child)
    end

    requestRefresh()
    task.delay(0.1, function() if isRunning then refreshCanvas() end end)
    task.delay(0.35, function() if isRunning then refreshCanvas() end end)
    task.delay(1.0, function() if isRunning then refreshCanvas() end end)
    return requestRefresh
end

navList = Instance.new("ScrollingFrame"); navList.Name = "NavList"; navList.Size = UDim2.new(1, 0, 1, -44); navList.Position = UDim2.new(0, 0, 0, 42); navList.BackgroundTransparency = 1; navList.BorderSizePixel = 0; navList.ScrollBarThickness = 3; navList.ScrollBarImageColor3 = Colors.BorderSubtle; navList.CanvasSize = UDim2.new(0, 0, 0, 0); navList.AutomaticCanvasSize = Enum.AutomaticSize.None; navList.Active = true; navList.ScrollingEnabled = true; navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout"); nl.SortOrder = Enum.SortOrder.LayoutOrder; nl.Padding = UDim.new(0, 4); nl.Parent = navList
    local np = Instance.new("UIPadding"); np.PaddingTop = UDim.new(0, 6); np.PaddingLeft = UDim.new(0, 8); np.PaddingRight = UDim.new(0, 8); np.Parent = navList
    BindVerticalCanvas(navList, nl, 6)
end

local contentArea = Instance.new("Frame"); contentArea.Name = "ContentArea"; contentArea.Size = UDim2.new(1, -140, 1, 0); contentArea.Position = UDim2.new(0, 140, 0, 0); contentArea.BackgroundTransparency = 1; contentArea.Parent = bodyFrame
local tabFrames = {}; local tabButtons = {}; local tabTweens = {}

tabCanvasRefreshers = {}

SwitchTab = function(tabName)
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
    currentActiveTab = tabName
    for name, frame in pairs(tabFrames) do
        local isTarget = (name == tabName)
        if frame.Visible ~= isTarget then frame.Visible = isTarget end
    end
    for name, btn in pairs(tabButtons) do
        local tw = tabTweens[name]
        if name == tabName then
            if tw and tw.active then tw.active:Play() end
            if tw and tw.pill then tw.pill.Visible = true end
        else
            if tw and tw.inactive then tw.inactive:Play() end
            if tw and tw.pill then tw.pill.Visible = false end
        end
    end
    -- 切换标签后重新计算当前页 Canvas，避免高度仍是旧值导致滑不动/弹回
    local refresher = tabCanvasRefreshers[tabName]
    if refresher then
        task.defer(refresher)
        task.delay(0.1, refresher)
    end
end

CreateTab = function(name)
    local btn = Instance.new("TextButton"); btn.Name = "TabBtn_" .. name; btn.Size = UDim2.new(1, 0, 0, 30); btn.BackgroundColor3 = Colors.SidebarBg; btn.Font = Enum.Font.GothamBold; btn.Text = name; btn.TextColor3 = Colors.TextSubtle; btn.TextSize = 12; btn.TextXAlignment = Enum.TextXAlignment.Left; btn.BorderSizePixel = 0; btn.Parent = navList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 12); p.Parent = btn end
    local pill = Instance.new("Frame"); pill.Name = "ActivePill"; pill.Size = UDim2.new(0, 3, 0, 16); pill.Position = UDim2.new(0, -9, 0.5, -8); pill.BackgroundColor3 = Colors.PurpleAccent; pill.BorderSizePixel = 0; pill.Visible = false; pill.Parent = btn
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 2)
    tabTweens[name] = {
        active = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite}),
        inactive = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.SidebarBg, TextColor3 = Colors.TextSubtle}),
        pill = pill,
    }
    btn.MouseButton1Click:Connect(function() SwitchTab(name) end)

    local page = Instance.new("ScrollingFrame"); page.Name = "TabPage_" .. name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1; page.BorderSizePixel = 0; page.ScrollBarThickness = 4; page.ScrollBarImageColor3 = Colors.BorderPurple; page.CanvasSize = UDim2.new(0, 0, 0, 0); page.AutomaticCanvasSize = Enum.AutomaticSize.None; page.Active = true; page.ScrollingEnabled = true; page.ScrollingDirection = Enum.ScrollingDirection.Y; page.ElasticBehavior = Enum.ElasticBehavior.Never; page.Visible = false; page.Parent = contentArea
    do
        local pl = Instance.new("UIListLayout"); pl.SortOrder = Enum.SortOrder.LayoutOrder; pl.Padding = UDim.new(0, 10); pl.Parent = page
        local pp = Instance.new("UIPadding"); pp.PaddingTop = UDim.new(0, 12); pp.PaddingBottom = UDim.new(0, 20); pp.PaddingLeft = UDim.new(0, 14); pp.PaddingRight = UDim.new(0, 14); pp.Parent = page
        local refresher = BindVerticalCanvas(page, pl, 40)
        tabCanvasRefreshers[name] = refresher
        -- 页面从隐藏变为可见时布局才会正确计算 AbsoluteSize，必须再刷一次
        page:GetPropertyChangedSignal("Visible"):Connect(function()
            if page.Visible then
                task.defer(refresher)
                task.delay(0.12, refresher)
                task.delay(0.4, refresher)
            end
        end)
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
    if not mainFrame or isUiAnimating then return end
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

CloseUI = function()
    if not mainFrame or isUiAnimating then return end
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
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
    if isUiAnimating then return end
    if mainFrame and mainFrame.Visible then
        CloseUI()
    else
        OpenUI()
    end
end

-- Activated 同时覆盖鼠标与触摸；不要再并行绑定 MouseButton1Click，避免一次点击执行两次。
if minBtn.Activated then
    minBtn.Activated:Connect(ToggleUiVisibility)
else
    minBtn.MouseButton1Click:Connect(ToggleUiVisibility)
end
if closeBtn.Activated then
    closeBtn.Activated:Connect(UnloadScript)
else
    closeBtn.MouseButton1Click:Connect(UnloadScript)
end
end -- end of Window Frame Construction Scope

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
    local enterTween = TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover})
    local leaveTween = TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowNormal})
    row.MouseEnter:Connect(function() enterTween:Play() end)
    row.MouseLeave:Connect(function() leaveTween:Play() end)
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
    local onBtnTw = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleAccent})
    local offBtnTw = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg})
    local onKnobTw = TweenService:Create(knob, TweenInfo.new(0.15), {Position = UDim2.new(1, -17, 0.5, -7)})
    local offKnobTw = TweenService:Create(knob, TweenInfo.new(0.15), {Position = UDim2.new(0, 3, 0.5, -7)})
    local function updateVisuals(instant)
        if instant then
            btn.BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg
            knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        elseif state then
            onBtnTw:Play(); onKnobTw:Play()
        else
            offBtnTw:Play(); offKnobTw:Play()
        end
    end
    btn.MouseButton1Click:Connect(function() state = not state; updateVisuals(false); if type(callback) == "function" then callback(state) end end)
    local ctrl = {frame = row, Set = function(val, silent) state = not not val; updateVisuals(silent == true); if not silent and type(callback) == "function" then callback(state) end end, Get = function() return state end}
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
    local activeTouch = nil
    local activeScrollFrame = nil
    local previousScrollingEnabled = nil
    touchArea.Active = true
    local function findScrollFrame()
        local p = row
        while p and not p:IsA("ScrollingFrame") do p = p.Parent end
        return p
    end
    local function finishSliding()
        sliding = false
        activeTouch = nil
        if activeScrollFrame and activeScrollFrame.Parent and previousScrollingEnabled ~= nil then
            activeScrollFrame.ScrollingEnabled = previousScrollingEnabled
        end
        activeScrollFrame = nil
        previousScrollingEnabled = nil
    end
    local function updateFromX(x)
        local width = track.AbsoluteSize.X
        if not width or width <= 0 or maxVal <= minVal then return end
        local rel = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
        local val = minVal + (maxVal - minVal) * rel
        if isFloat then
            val = math.floor(val * 100 + 0.5) / 100
        else
            val = math.floor(val + 0.5)
        end
        if val == currentVal then return end
        currentVal = val
        updateVisual(currentVal)
        if type(callback) == "function" then
            local ok, err = pcall(callback, val)
            if not ok then warn("[IDENTICAL] 滑块回调失败: " .. tostring(err)) end
        end
    end
    touchArea.InputBegan:Connect(function(input)
        if sliding then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            activeTouch = input.UserInputType == Enum.UserInputType.Touch and input or nil
            activeScrollFrame = findScrollFrame()
            if activeScrollFrame then
                previousScrollingEnabled = activeScrollFrame.ScrollingEnabled
                activeScrollFrame.ScrollingEnabled = false
            end
            updateFromX(input.Position.X)
        end
    end)
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if not sliding then return end
        if activeTouch then
            if input == activeTouch then updateFromX(input.Position.X) end
        elseif input.UserInputType == Enum.UserInputType.MouseMovement then
            updateFromX(input.Position.X)
        end
    end))
    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if not sliding then return end
        if activeTouch and input == activeTouch then
            finishSliding()
        elseif not activeTouch and input.UserInputType == Enum.UserInputType.MouseButton1 then
            finishSliding()
        end
    end))
    local ctrl = { frame = row, Set = function(val, silent) currentVal = math.clamp(tonumber(val) or minVal, minVal, maxVal); updateVisual(currentVal); if not silent and type(callback) == "function" then callback(currentVal) end end }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

local function createDropdownRow(parent, labelText, descText, options, initialVal, callback, configKey, indexSearch)
    if type(options) == "table" and type(initialVal) == "function" then indexSearch = callback; callback = initialVal; initialVal = options[1] end
    local selected = initialVal or options[1]
    -- ClipsDescendants 关闭，避免展开下拉时高度被裁切，导致父级 ScrollingFrame 内容高度算少、滑不动/弹回
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = false; row.Parent = parent
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
            local obEnterTw = TweenService:Create(ob, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover})
            local obLeaveTw = TweenService:Create(ob, TweenInfo.new(0.15), {BackgroundColor3 = Colors.InputBg})
            ob.MouseEnter:Connect(function() if opt ~= selected then obEnterTw:Play() end end)
            ob.MouseLeave:Connect(function() if opt ~= selected then obLeaveTw:Play() end end)
            ob.MouseButton1Click:Connect(function()
                selected = opt; ddBtn.Text = tostring(opt) .. "  v"; optC.Visible = false
                if currentlyOpenDropdown and currentlyOpenDropdown.optC == optC then currentlyOpenDropdown = nil end
                for oN, b in pairs(optButtons) do b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg; b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite; b.Text = (oN == opt and "> " or "   ") .. tostring(oN) end
                if type(callback) == "function" then callback(opt) end
            end)
        end
    end
    populate(options)
    local function closeThisDropdown()
        if optC and optC.Parent then
            optC.Visible = false
            ddBtn.Text = tostring(selected) .. "  v"
        end
    end
    ddBtn.MouseButton1Click:Connect(function()
        local willOpen = not optC.Visible
        if willOpen then
            if currentlyOpenDropdown and currentlyOpenDropdown.optC ~= optC and currentlyOpenDropdown.Close then
                pcall(currentlyOpenDropdown.Close)
            end
            currentlyOpenDropdown = {optC = optC, Close = closeThisDropdown}
        else
            if currentlyOpenDropdown and currentlyOpenDropdown.optC == optC then
                currentlyOpenDropdown = nil
            end
        end
        optC.Visible = willOpen
        ddBtn.Text = tostring(selected) .. (willOpen and "  ^" or "  v")
    end)
    local hdrEnterTw = TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover})
    local hdrLeaveTw = TweenService:Create(row, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowNormal})
    header.MouseEnter:Connect(function() hdrEnterTw:Play() end)
    header.MouseLeave:Connect(function() hdrLeaveTw:Play() end)
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
    local btnEnterTween = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite})
    local btnLeaveTween = TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg, TextColor3 = Colors.PurplePrimary})
    btn.MouseEnter:Connect(function() btnEnterTween:Play() end)
    btn.MouseLeave:Connect(function() btnLeaveTween:Play() end)
    btn.MouseButton1Click:Connect(function() if type(callback) == "function" then pcall(callback) end end)
    return btn
end

local function createInfoRow(parent, labelText, valueText, indexSearch)
    local row = createBaseRow(parent, labelText, "", indexSearch)
    local vl = Instance.new("TextLabel"); vl.Size = UDim2.new(0, 140, 1, 0); vl.Position = UDim2.new(1, -140, 0, 0); vl.BackgroundTransparency = 1; vl.Font = Enum.Font.GothamBold; vl.Text = valueText; vl.TextColor3 = Colors.PurplePrimary; vl.TextSize = 11; vl.TextXAlignment = Enum.TextXAlignment.Right; vl.Parent = row
    return {frame = row, Set = function(nv) vl.Text = nv end}
end

local DashUI = {}
local SafeTeleport, allRods, TryFavoriteProtectedFish, SafeSellAllFish, TriggerPrompt, EnsureFishingRodEquipped, TeleportToDragonSea
local RunTicketQuestAction, RunGiveFishToMonkeyBatch, GetNPCPosition, FireGuiButton
local GetNearestIslandInfo, ImportantDialogueNPCs, FourSacredBeastsSpecs, DoesInstanceMatchNPCSpec, TriggerNPCInstancePrompts
do -- Tab & Feature Construction Scope
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

DashUI = {}

SafeTeleport = function(targetCF)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and (tonumber(hum.Health) or 100) <= 0 then return false end
    local root = char and char:FindFirstChild("HumanoidRootPart")
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
-- 仪表盘卡片构建（复用 CreateTab 已创建的 UIListLayout，避免双布局冲突）
-- ==========================================
local existingDashLayout = tabDashboard:FindFirstChildOfClass("UIListLayout")
if existingDashLayout then
    existingDashLayout.Padding = UDim.new(0, 8)
    existingDashLayout.SortOrder = Enum.SortOrder.LayoutOrder
end

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
    card.BackgroundColor3 = Colors.RowNormal
    card.BorderSizePixel = 0
    card.Parent = parent
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", card)
    stroke.Color = Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.Transparency = 0.35

    local cardEnterTw = TweenService:Create(card, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowHover})
    local strokeEnterTw = TweenService:Create(stroke, TweenInfo.new(0.15), {Color = Colors.PurpleAccent, Transparency = 0.1})
    local cardLeaveTw = TweenService:Create(card, TweenInfo.new(0.15), {BackgroundColor3 = Colors.RowNormal})
    local strokeLeaveTw = TweenService:Create(stroke, TweenInfo.new(0.15), {Color = Colors.BorderSubtle, Transparency = 0.35})
    card.MouseEnter:Connect(function() cardEnterTw:Play(); strokeEnterTw:Play() end)
    card.MouseLeave:Connect(function() cardLeaveTw:Play(); strokeLeaveTw:Play() end)

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

allRods = {
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
local function EquipLoadoutAction(slotLabel, rodName, baitName)
    task.spawn(function()
        pcall(function()
            local pData = GetPlayerData()
            if not pData then
                ShowNotification(slotLabel, "未读取到玩家数据，请稍后再试。", "WARN")
                return
            end
            local rodInv = pData:FindFirstChild("FishingRodInventory")
            local rFolder = rodInv and rodInv:FindFirstChild(rodName)
            local isOwned = rFolder and rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
            if isOwned then
                local equipRodRem = Events and Events:FindFirstChild("EquipFishingRod")
                if equipRodRem then pcall(function() equipRodRem:InvokeServer(rodName) end) end
                ShowNotification(slotLabel, "已装备鱼竿: " .. tostring(rodName), "SUCCESS")
            else
                ShowNotification(slotLabel, "你还没有拥有 " .. tostring(rodName) .. " ！", "WARN")
            end
            local baitInv = pData:FindFirstChild("Bait")
            local bFolder = baitInv and baitInv:FindFirstChild(baitName)
            if bFolder and tonumber(bFolder.Value) and bFolder.Value > 0 then
                local equipBaitRem = Events and Events:FindFirstChild("EquipBait")
                if equipBaitRem then pcall(function() equipBaitRem:InvokeServer(baitName) end) end
                ShowNotification(slotLabel, "已装备鱼饵: " .. tostring(baitName), "SUCCESS")
            else
                ShowNotification(slotLabel, "你的背包中 " .. tostring(baitName) .. " 数量为0。", "WARN")
            end
        end)
    end)
end

createButtonRow(equipCard, "立即装备方案1", "装备方案1选择的鱼竿和鱼饵", "装备#1", function()
    EquipLoadoutAction("方案1", Config.Loadout1_Rod, Config.Loadout1_Bait)
end)

createDropdownRow(equipCard, "方案2：鱼竿", "方案2的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end, "Loadout2_Rod")
createDropdownRow(equipCard, "方案2：鱼饵", "方案2的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end, "Loadout2_Bait")
createButtonRow(equipCard, "立即装备方案2", "装备方案2选择的鱼竿和鱼饵", "装备#2", function()
    EquipLoadoutAction("方案2", Config.Loadout2_Rod, Config.Loadout2_Bait)
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

-- 提取纯鱼名：带弱表/容量缓存，自动剥离背包实例名后追加的 " | 1849724.37" 后缀
local pureNameCache = {}
local pureNameCacheCount = 0
local function GetPureFishName(rawName)
    if not rawName then return "" end
    local s = (typeof(rawName) == "Instance") and rawName.Name or tostring(rawName)
    local cached = pureNameCache[s]
    if cached then return cached end
    local beforePipe = s:match("^(.-)%s*|")
    local res = (beforePipe and #beforePipe > 0) and beforePipe:match("^%s*(.-)%s*$") or s:match("^%s*(.-)%s*$")
    if pureNameCacheCount >= 512 then
        table.clear(pureNameCache)
        pureNameCacheCount = 0
    end
    pureNameCache[s] = res
    pureNameCacheCount = pureNameCacheCount + 1
    return res
end

-- 检查鱼实例是否已经在服务端处于上锁/收藏状态（使用哈希集合 + 单次 GetChildren 遍历，消除 10x FindFirstChild 开销）
local favNameSet = {
    Favorite = true, Favorited = true, Favourite = true, Favourited = true,
    Locked = true, Lock = true, IsFavorite = true, IsLocked = true, Star = true, Starred = true,
}
local function IsFishItemFavorited(item)
    if not item then return false end
    for _, ch in ipairs(item:GetChildren()) do
        if favNameSet[ch.Name] then
            if ch:IsA("ValueBase") then
                local v = ch.Value
                if v == true or v == 1 or tostring(v):lower() == "true" then return true end
            else
                return true
            end
        end
    end
    for name in pairs(favNameSet) do
        local attr = item:GetAttribute(name)
        if attr == true or attr == 1 or tostring(attr):lower() == "true" then
            return true
        end
    end
    return false
end

-- 编译通配符/前缀/后缀/精确/包含匹配器（全小写缓存，带容量上限防内存泄漏）
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

    if patternCacheCount >= 256 then
        table.clear(patternCache)
        patternCacheCount = 0
    end
    patternCache[lower] = matcher
    patternCacheCount = patternCacheCount + 1
    return matcher
end
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
-- 使用顶部预声明的防翻转上锁状态表（卸载时统一清空）

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

TryFavoriteProtectedFish = function(pData)
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
    for name, sentTime in pairs(lastLockSentByName) do
        if (now - sentTime) >= 8.0 then lastLockSentByName[name] = nil end
    end
    return unfavProtectedCount
end

-- 铁壁级安全卖鱼（带 protectedPureSet 二次校验 + 3.5秒上锁稳定等待）：

SafeSellAllFish = function(pData)
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
                    local lastUnlockedCount = #unlockedProtectedNames
                    local stablePasses = 0
                    while tick() - waitStart < 3.5 do
                        task.wait(0.35)
                        TryFavoriteProtectedFish(pData)
                        ScanBagState()
                        if #unlockedProtectedNames == 0 then break end
                        if #unlockedProtectedNames == lastUnlockedCount then
                            stablePasses = stablePasses + 1
                            if stablePasses >= 3 then break end
                        else
                            stablePasses = 0
                            lastUnlockedCount = #unlockedProtectedNames
                        end
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

TriggerPrompt = function(prompt)
    if not prompt or not prompt.Parent or not prompt.Enabled then return end
    if type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
    else
        -- 降级分支使用防重入异步协程执行 Hold，严禁在 Heartbeat 主循环中同步 task.wait 阻塞帧
        if activePromptTasks[prompt] then return end
        activePromptTasks[prompt] = true
        task.spawn(function()
            pcall(function()
                prompt:InputHoldBegin()
                task.wait(math.clamp(tonumber(prompt.HoldDuration) or 0, 0, 5) + 0.05)
                if isRunning and prompt and prompt.Parent then
                    prompt:InputHoldEnd()
                end
            end)
            activePromptTasks[prompt] = nil
        end)
    end
end

-- RunTicketQuestAction & RunGiveFishToMonkeyBatch pre-declared
GetNPCPosition = function(npc)
    if not npc then return nil end
    local hrp = npc:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp.Position end
    if npc:IsA("Model") then
        local success, cf = pcall(function() return npc:GetBoundingBox() end)
        if success and cf then return cf.Position end
        local success2, pivot = pcall(function() return npc:GetPivot().Position end)
        if success2 and pivot then return pivot end
    end
    if npc:IsA("BasePart") then return npc.Position end
    local basePart = npc:FindFirstChildWhichIsA("BasePart", true)
    if basePart then return basePart.Position end
    return nil
end
FireGuiButton = function(btn)
    if not btn or not btn:IsA("GuiButton") or not btn.Visible or not btn.Active then return false end
    local firedAny = false
    if type(firesignal) == "function" then
        if pcall(function() firesignal(btn.Activated) end) then firedAny = true end
        if pcall(function() firesignal(btn.MouseButton1Click) end) then firedAny = true end
        pcall(function() if btn.MouseButton1Down then firesignal(btn.MouseButton1Down) end end)
        pcall(function() if btn.MouseButton1Up then firesignal(btn.MouseButton1Up) end end)
        pcall(function() if btn.TouchTap then firesignal(btn.TouchTap) end end)
        if firedAny then return true end
    end
    if type(getconnections) == "function" then
        local ok = pcall(function()
            for _, sig in ipairs({btn.Activated, btn.MouseButton1Click, btn.MouseButton1Down, btn.TouchTap}) do
                if sig then
                    for _, conn in ipairs(getconnections(sig)) do conn:Fire() end
                end
            end
        end)
        if ok then return true end
    end
    return firedAny
end

do
createCategoryHeader(tabFishing, "经济与出售 (通配符+防误卖铁壁系统)")
local sellCard = createCardGroup(tabFishing)
createToggleRow(sellCard, "自动卖鱼", "定期安全出售普通鱼（发现未锁保护鱼时自动拦截SellAll）", Config.AutoSell, function(v) Config.AutoSell = v end, "AutoSell")
createSliderRow(sellCard, "出售间隔(秒)", "出售鱼的频率 (10秒-60分钟)", 10, 3600, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end, "SellInterval")
createButtonRow(sellCard, "立即出售并传送到娜娜", "传送到娜娜处并安全出售非保护鱼（绝不误卖保护名单）", "立即出售", function()
    local pData = GetPlayerData()
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
        local pData = GetPlayerData()
        TryFavoriteProtectedFish(pData)
        ShowNotification("保护名单已生效", "当前规则: " .. (Config.CustomProtectedFish ~= "" and Config.CustomProtectedFish or "空"), "SUCCESS")
    end)
    UIControls["CustomProtectedFish"] = { Set = function(val) customFavBox.Text = tostring(val or "") end }
end

createButtonRow(sellCard, "[预览] 预览保护名单命中结果", "扫描背包，显示哪些鱼会被保护(不卖)、哪些鱼会被出售", "预览结果", function()
    local pData = GetPlayerData()
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
    local pData = GetPlayerData()
    TryFavoriteProtectedFish(pData)
    ShowNotification("已添加保护", "已将 [" .. target .. "] 加入防误卖保护名单！", "SUCCESS")
end)

createButtonRow(sellCard, "[刷新] 扫描当前背包鱼类到下拉框", "读取背包和快捷栏现有鱼类(自动去除数字后缀ID)", "扫描背包", function()
    local pData = GetPlayerData()
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
-- Boss 页面 (完全对齐 V1.0 稳定版布局：无名章鱼寄生体 + 恩佐/龙钓海 + 自动传送防冲突)
-- ==========================================
TeleportToDragonSea = function()
    -- 优先在 Workspace / BossSetUp 中查找龙钓海 / Mountain Dragon Whale / Dragon 实体或区域坐标，兜底前往雾峰岛龙域
    local targetPos = nil
    for _, folder in ipairs({Workspace:FindFirstChild("BossSetUp"), Workspace:FindFirstChild("Islands"), Workspace:FindFirstChild("Map"), Workspace}) do
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do
                local cn = (ch.Name or ""):lower()
                if cn:find("dragon") or cn:find("whale") or cn:find("long") or cn:find("龙") then
                    local p = GetNPCPosition(ch)
                    if p then targetPos = p; break end
                end
            end
        end
        if targetPos then break end
    end
    targetPos = targetPos or Vector3.new(2660.2, 8.8, -86.7)
    if SafeTeleport(CFrame.new(targetPos + Vector3.new(0, 3, 0))) then
        ShowNotification("已传送", "已到达龙钓海！", "SUCCESS")
        return true
    end
    return false
end

createCategoryHeader(tabBoss, "无名章鱼寄生体(隐藏BOSS)")
local octoCard = createCardGroup(tabBoss)
createToggleRow(octoCard, "自动玩小游戏 (节奏机器人)", "机器人自动安全打拍子", Config.OctoAutoMinigame, function(v)
    Config.OctoAutoMinigame = v
end, "OctoAutoMinigame")
createSliderRow(octoCard, "节奏命中率 (Accuracy %)", "打拍子准确度 (92% - 96% 保证鱼竿绝对安全)", 50, 100, Config.RhythmAccuracy, false, "%", function(v)
    Config.RhythmAccuracy = v
end, "RhythmAccuracy")
createButtonRow(octoCard, "传送到章鱼寄生体", "传送到海洋隐藏Boss浮标", "传送", function()
    if SafeTeleport(CFrame.new(1608.2, 5.0, -218.3)) then ShowNotification("已传送", "已到达无名章鱼寄生体海洋浮标！", "SUCCESS") end
end)
createButtonRow(octoCard, "传送到渔夫之地", "传送到地下渔夫领域", "传送", function()
    if SafeTeleport(CFrame.new(112.5, -330.0, -30.8)) then ShowNotification("已传送", "已到达地下渔夫之地！", "SUCCESS") end
end)

createCategoryHeader(tabBoss, "恩佐 龙钓海")
local bossFarmCard = createCardGroup(tabBoss)
createToggleRow(bossFarmCard, "自动刷Boss(Enzo)", "持续召唤并击败Enzo (开启后自动传送到Enzo竞技场)", Config.AutoFarmBoss, function(v)
    Config.AutoFarmBoss = v
    if v then
        -- 互斥保护：开启自动刷Enzo时自动关闭自动刷隐藏Boss，防止两边抢传送导致死循环闪烁
        if Config.AutoFarmSecretBoss then
            Config.AutoFarmSecretBoss = false
            if UIControls["AutoFarmSecretBoss"] and UIControls["AutoFarmSecretBoss"].Set then
                pcall(function() UIControls["AutoFarmSecretBoss"].Set(false, true) end)
            end
        end
        if EnsureFishingRodEquipped then pcall(EnsureFishingRodEquipped) end
        SafeTeleport(CFrame.new(-115.3, 9.2, 1349.5))
        ShowNotification("自动刷Enzo", "已传送至Enzo竞技场并开始持续召唤挑战！", "SUCCESS", 3)
    end
end, "AutoFarmBoss")
createDropdownRow(bossFarmCard, "Boss难度", "选择要刷的Boss难度 (简单/困难/噩梦)", {"简单", "困难", "噩梦"}, Config.EnzoDifficulty, function(v)
    Config.EnzoDifficulty = v
end, "EnzoDifficulty")
createToggleRow(bossFarmCard, "自动刷隐藏Boss", "自动制作无名鱼饵，召唤并击杀 (开启后自动传送到章鱼浮标)", Config.AutoFarmSecretBoss, function(v)
    Config.AutoFarmSecretBoss = v
    if v then
        -- 互斥保护：开启自动刷隐藏Boss时自动关闭自动刷Enzo，防止坐标冲突
        if Config.AutoFarmBoss then
            Config.AutoFarmBoss = false
            if UIControls["AutoFarmBoss"] and UIControls["AutoFarmBoss"].Set then
                pcall(function() UIControls["AutoFarmBoss"].Set(false, true) end)
            end
        end
        if EnsureFishingRodEquipped then pcall(EnsureFishingRodEquipped) end
        SafeTeleport(CFrame.new(1608.2, 5.0, -218.3))
        ShowNotification("自动刷隐藏Boss", "已传送至章鱼浮标并启动自动召唤！", "SUCCESS", 3)
    end
end, "AutoFarmSecretBoss")
createToggleRow(bossFarmCard, "自动恩佐/龙钓海小游戏", "自动完成恩佐与龙钓海拔河QTE判定条 (极小概率封号)", Config.AutoEnzoMinigame, function(v)
    Config.AutoEnzoMinigame = v
end, "AutoEnzoMinigame")
createToggleRow(bossFarmCard, "Boss战自动技能(Z/X/C/V)", "打Enzo或隐藏Boss时自动按顺序释放勾选技能", Config.BossAutoSkills, function(v)
    Config.BossAutoSkills = v
end, "BossAutoSkills")
createButtonRow(bossFarmCard, "传送到Enzo", "传送到Enzo竞技场", "传送", function()
    if SafeTeleport(CFrame.new(-115.3, 9.2, 1349.5)) then ShowNotification("已传送", "已到达Enzo竞技场！", "SUCCESS") end
end)
createButtonRow(bossFarmCard, "传送到龙钓海", "传送到龙钓海", "传送", function()
    TeleportToDragonSea()
end)
end -- end of Sell and Boss UI scope

-- ==========================================
-- V5.0 全图深度 NPC 雷达 + 双引擎对话 (直连 + 岛屿流式预加载微瞬移) + 一键传送
-- ==========================================
local function SafeFireOneRemote(rem, ...)
    if typeof(rem) ~= "Instance" or not rem.Parent then return false, "remote_unavailable" end
    local args = {...}
    if rem:IsA("RemoteEvent") then
        local ok, err = pcall(function() rem:FireServer(unpack(args)) end)
        if not ok then return false, tostring(err) end
        return true, "event_sent"
    elseif rem:IsA("RemoteFunction") then
        local ok, err = pcall(function()
            task.spawn(function()
                pcall(function() rem:InvokeServer(unpack(args)) end)
            end)
        end)
        if not ok then return false, tostring(err) end
        return true, "invoke_queued"
    end
    return false, "unsupported_instance"
end

-- 10 大岛屿中心锚点（用于判定神灵/同名 NPC 属于哪座岛，以及驱动 RequestStreamAroundAsync 流式加载）
local IslandCenters = {
    {id = 1,  name = "起始岛 (Beginning Isle)",   pos = Vector3.new(-200.7, 11.1, 35.9)},
    {id = 2,  name = "竹岛 (Bamboo Isle)",        pos = Vector3.new(-1223.0, 7.3, -24.1)},
    {id = 3,  name = "辐射岛 (Fallout Isle)",     pos = Vector3.new(65.5, 8.8, 1181.3)},
    {id = 4,  name = "主权岛 (Sovereign Isle)",   pos = Vector3.new(-1276.4, 8.8, 1239.7)},
    {id = 5,  name = "鲈鱼岛 (Perch Isle)",       pos = Vector3.new(-62.0, 11.9, -1321.4)},
    {id = 6,  name = "冰霜岛 (Frost Isle)",       pos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {id = 7,  name = "椰子岛 (Coconut Isle)",     pos = Vector3.new(1493.6, 9.1, -1430.6)},
    {id = 8,  name = "琥珀岛 (Amber Isle)",       pos = Vector3.new(1259.4, 9.1, 1401.5)},
    {id = 9,  name = "战场岛 (Battlefield Isle)", pos = Vector3.new(1393.5, 11.3, 169.6)},
    {id = 10, name = "雾峰岛 (Mistpeak Isle)",    pos = Vector3.new(2660.2, 8.8, -86.7)},
}

GetNearestIslandInfo = function(pos)
    if not pos then return nil end
    local bestIsl, bestDist = nil, math.huge
    for _, isl in ipairs(IslandCenters) do
        local d = (pos - isl.pos).Magnitude
        if d < bestDist then
            bestDist = d
            bestIsl = isl
        end
    end
    return bestIsl, bestDist
end

-- 尝试请求服务端流式加载指定坐标周围的地图与 NPC 模型
local function TryStreamAroundPosition(pos)
    if not pos then return end
    pcall(function()
        if type(LocalPlayer.RequestStreamAroundAsync) == "function" then
            task.spawn(function()
                pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, 2) end)
            end)
        end
    end)
end

-- ==========================================
-- 📦 官方完整 NPC 数据库（涵盖全部核心、主线、后期、流动商人、三个神灵与四圣兽）
-- ==========================================
ImportantDialogueNPCs = {
    -- 1. 起始岛与核心系统 NPC
    {cnName = "票据任务员 (Quest Giver)", internalName = "Quest Giver", desc = "每日票据任务 (起始岛 [1] Easy / Hard 抽卡券任务)", aliases = {"Quest Giver", "QuestGiver", "TicketQuest", "Ticket NPC", "Ticket", "DailyQuest"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "南江 (Nanjang / Nanjiang)", internalName = "Nanjang", desc = "抽特质 物品交换 (初始岛 [1] 技能特质重铸 / 洗练四圣兽)", aliases = {"Nanjang", "Nanjiang", "TraitNPC", "Trait"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "初始岛楚依旧 (Sage Yiju)", internalName = "Sage Yiju", desc = "买技能 对话 (初始岛 [1] 基础 Cash 金币钓鱼技能商店)", aliases = {"Sage Yiju", "Sage Yijiu", "Chu Yijiu", "Sage Eiju"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9), preferPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "技能升级师 (Skill Upgrades)", internalName = "Skill Upgrades", desc = "技能强化 (各岛通用 · 消耗精华 Essences 提升技能伤害)", aliases = {"Skill Upgrades", "Skill Upgrade", "SkillUpgrades", "UpgradeSkill"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "世界表弟 (Biao Di)", internalName = "Biao Di", desc = "主线 任务 对话 (鱼竿商店 / 神话竿合成 / 冰霜&椰子岛鱼竿任务)", aliases = {"Biao Di", "BiaoDi", "Rod Seller", "RodDealer"}, fallbackPos = Vector3.new(-151.4, 8.7, -49.9)},
    {cnName = "天气岛楚新 (Chu Xin)", internalName = "Chu Xin", desc = "主线任务 (各岛码头出售并生成船只 Spawn Boat)", aliases = {"Chu Xin", "ChuXin", "Boat Seller", "Spawn Boat"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "楚无双 / 表哥 (Biao Ge)", internalName = "Biao Ge", desc = "设出生点 主线 宝珠任务 (记录当前岛屿重生点 Set Spawn)", aliases = {"Biao Ge", "Chu Wu Shuang", "Set Spawn", "SpawnPoint"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "娜娜 (Nana)", internalName = "Nana", desc = "卖鱼商人 (各岛收购鱼类换取 Cash 核心经济)", aliases = {"Nana", "Fish Buyer", "SellNPC"}, fallbackPos = Vector3.new(-203.5, 7.3, 107.1)},
    {cnName = "八长 (Ba Chang)", internalName = "Ba Chang", desc = "鱼饵商人 (出售 Luck 鱼饵与制作彩虹/冰霜神话鱼饵)", aliases = {"Ba Chang", "Bai Chang", "Bait Seller"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},

    -- 2. 各岛高阶主线与专属技能 NPC
    {cnName = "升天国 / 夏钓帝 (Ha Dieu De)", internalName = "Ha Dieu De", desc = "任务 技能升级 (冰霜岛 [6] 斩天门V3 Sever The Gate v3 任务)", aliases = {"Ha Dieu De", "Sheng Tian Guo", "Sever The Gate", "Gate v3", "Xia Diaodi"}, fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4), preferPos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {cnName = "北冥 (Bac Minh)", internalName = "Bac Minh", desc = "买技能 任务 主线 (椰子岛 [7] 北冥宝珠 Bac Minh Orb 主线)", aliases = {"Bac Minh", "Bei Ming", "BacMinh", "BeiMing"}, fallbackPos = Vector3.new(1493.6, 9.1, -1430.6), preferPos = Vector3.new(1493.6, 9.1, -1430.6)},
    {cnName = "断杆 (Dawan Gan / Duan Gan)", internalName = "Dawan Gan", desc = "公会 创造公会 主线 (战场岛/雾峰岛 登仙十钓/破天四技能)", aliases = {"Dawan Gan", "Duan Gan", "DuanGan", "Doan Can", "Guild"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "战场岛楚依旧 (Sage Yijiu)", internalName = "Sage Yijiu", desc = "买技能 任务 (战场岛 [9] 5阶段终极主线: 钻石竿→一钩霸主)", aliases = {"Sage Yijiu", "Sage Yiju", "Chu Yijiu", "Sage Eiju"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "失明的大钓鱼人 (Blind Grand Angler)", internalName = "Blind Grand Angler", desc = "任务 对话 (战场岛 [9] 星辰大钓术·极 Astral Grand Art Zenith)", aliases = {"Blind Grand Angler", "Grand Angler", "BlindAngler", "Blind"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "竹岛江老 (Giang Lao)", internalName = "Giang Lao", desc = "任务 对话 (竹岛 [2] 无影太极击 Shadowless Taji + 神圣竹竿)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), preferPos = Vector3.new(-1223.0, 7.3, -24.1)},
    {cnName = "战场岛江老 (Giang Lao BF)", internalName = "Giang Lao", desc = "主线任务 (战场岛 [9] 升仙太极术 Ascended Taji Art 任务)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "老江 (Old Jiang)", internalName = "Old Jiang", desc = "普通升级任务 (竹岛/主权岛 经验与等级提升支线)", aliases = {"Old Jiang", "Giang Lao", "Jiang Lao"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1)},
    {cnName = "钓科威 / 老吴 (Lao Ngo)", internalName = "Lao Ngo", desc = "主线任务 (战场岛 [9] 碎心斩V2 Heartbreaker Cleave V2 任务)", aliases = {"Lao Ngo", "Diao Ke Wei", "Lao Wu", "Heartbreaker"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "暗影 (The Shadow)", internalName = "The Shadow", desc = "升级角色 (起始岛瀑布后秘密洞穴 · 献祭资源突破角色等级)", aliases = {"The Shadow", "Shadow", "An Ying", "Dark", "Upgrade Character"}, fallbackPos = Vector3.new(-8.4, 53.9, 6.7)},

    -- 3. 后期门派与英雄任务 NPC（加入多英文/越文内部别名 + 跨岛巡检定位，解决远距离找不到问题）
    {cnName = "少林 / 花和尚 (Shaolin)", internalName = "Shaolin", desc = "购买 (少林钓法 / 降龙伏虎 / 如来神掌 武学技能)", aliases = {"Shaolin", "Monk", "Flower Monk", "Thieu Lam", "Hoa Thuong", "Buddha", "Tathagata", "Dragon Subjugation"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "五指钓王 (Five Finger King)", internalName = "Five Finger King", desc = "主线任务(天气鱼) (琥珀岛/雾峰岛 提交指定天气稀有鱼)", aliases = {"Five Finger", "Wu Zhi", "Weather King", "Finger", "Ngu Chi", "World Angler"}, fallbackPos = Vector3.new(1259.4, 9.1, 1401.5), altPositions = {Vector3.new(1259.4, 9.1, 1401.5), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "史星钓 / 石克翔 (Shi Xing Diao)", internalName = "Shi Xing Diao", desc = "主线任务 (雾峰岛 [10] 高阶钓鱼人主线任务挑战)", aliases = {"Shi Xing Diao", "ShiXingDiao", "石克翔", "史星钓", "World Angler", "Star Angler"}, fallbackPos = Vector3.new(2660.2, 8.8, -86.7), altPositions = {Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "楚天骄 (Chu Tian Jiao)", internalName = "Chu Tian Jiao", desc = "主线任务 (战场岛/雾峰岛 天骄专属进阶试炼任务)", aliases = {"Chu Tian Jiao", "ChuTianJiao", "Tian Jiao", "Thien Kieu", "Pride", "Celestial"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1259.4, 9.1, 1401.5)}},
    {cnName = "亚索 (Yasuo)", internalName = "Yasuo", desc = "主线任务 (鲈鱼岛/战场岛/雾峰岛 疾风剑豪斩风钓法全套技能)", aliases = {"Yasuo", "Wind", "Swordsman", "Wanderer", "Ronin", "Chem Gio", "Triple"}, fallbackPos = Vector3.new(-62.0, 11.9, -1321.4), altPositions = {Vector3.new(-62.0, 11.9, -1321.4), Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(65.5, 8.8, 1181.3)}},

    -- 4. 流动商人 / 隐藏商人
    {cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", desc = "流动商人 (100M道士珠 / 200M极鹰猎 / 接取「三个神灵」任务)", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi", "Tieu Dao Si"}, fallbackPos = nil, isRoaming = true},
    {cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", desc = "流动商人 (300M茅山竿 / 200M茅山珠 / 200M镇江技能)", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan", "Dai Su Huynh"}, fallbackPos = nil, isRoaming = true},
    {cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", desc = "轮换隐藏商人 (六脉神鹰 Six Vein Divine Hawk / 道士商店卡)", aliases = {"Dumb Guy", "Dumb Man", "Dumb", "Thang Ngu"}, fallbackPos = nil, isRoaming = true},
}

-- 三个神灵专属配置表（放在神灵页面与传送页面，不再混在任务页底部）
local ThreeSpiritsSpecs = {
    {
        liveKey = "Spirit_Bamboo",
        cnName = "神灵 #1 · 竹岛神灵 (Bamboo Isle)",
        internalName = "Spirit",
        islandName = "[2] 竹岛",
        desc = "竹岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得竹岛神灵祝福)",
        aliases = {"Spirit", "God", "Spirits", "Shrine", "Bamboo Spirit"},
        fallbackPos = Vector3.new(-1223.0, 7.3, -24.1),
        preferPos = Vector3.new(-1223.0, 7.3, -24.1),
    },
    {
        liveKey = "Spirit_Frost",
        cnName = "神灵 #2 · 冰霜岛神灵 (Frost Isle)",
        internalName = "Spirit",
        islandName = "[6] 冰霜岛",
        desc = "冰霜岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得霜岛神灵祝福)",
        aliases = {"Spirit", "God", "Spirits", "Shrine", "Frost Spirit"},
        fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4),
        preferPos = Vector3.new(-1366.0, 11.9, -1495.4),
    },
    {
        liveKey = "Spirit_Amber",
        cnName = "神灵 #3 · 琥珀岛神灵 (Amber Isle)",
        internalName = "Spirit",
        islandName = "[8] 琥珀岛",
        desc = "琥珀岛祭坛 · 每次祈祷花费 50M Cash (集齐三岛祝福解锁幻影灯笼鱼克制技)",
        aliases = {"Spirit", "God", "Spirits", "Shrine", "Amber Spirit"},
        fallbackPos = Vector3.new(1259.4, 9.1, 1401.5),
        preferPos = Vector3.new(1259.4, 9.1, 1401.5),
    },
}

-- 四圣兽配置表（用于神灵页状态监控、世界 Boss/圣兽实体雷达报警与特质检测）
FourSacredBeastsSpecs = {
    {
        liveKey = "VermilionBird",
        cnName = "🦅 朱雀 (Vermilion Bird)",
        engName = "Vermilion Bird",
        aliases = {"Vermilion Bird", "Vermillion Bird", "Vermilion", "Vermillion", "Chu Tuoc", "Phoenix"},
        desc = "0.1%神话特质(-50%冷却+25%伤害+重置CD) / 朱雀Boss (Vermilion Bird Li)",
        color = Colors.AccentRed,
    },
    {
        liveKey = "BlackTortoise",
        cnName = "🐢 玄武 (Black Tortoise)",
        engName = "Black Tortoise",
        aliases = {"Black Tortoise", "Tortoise", "Huyen Vu", "Black Tortoise Bloodline"},
        desc = "0.1%神话特质(+15%回血+30%伤害+眩晕+低血20秒无敌) / 玄武血脉Boss",
        color = Colors.AccentBlue,
    },
    {
        liveKey = "WhiteTiger",
        cnName = "🐯 白虎 (White Tiger)",
        engName = "White Tiger",
        aliases = {"White Tiger", "Bach Ho"},
        desc = "0.1%神话特质(+50%暴击率+100%暴击伤害+每次释放叠5%暴击)",
        color = Colors.TextWhite,
    },
    {
        liveKey = "AzureDragon",
        cnName = "🐉 青龙 (Azure Dragon)",
        engName = "Azure Dragon",
        aliases = {"Azure Dragon", "Thanh Long", "Dragon"},
        desc = "0.1%神话特质(+100~150%伤害-20%冷却+低血穿透Boss无敌)",
        color = Colors.AccentGreen,
    },
}

local TicketQuestNPCSpec = ImportantDialogueNPCs[1]

-- 深度文本与属性匹配：预编译 spec 关键词 + 弱表缓存每个 NPC 的全树特征文本（将每秒 1680 次 GetDescendants 降为 0 次，彻底消除雷达扫描卡顿）
local npcTextSummaryCache = setmetatable({}, { __mode = "k" })

local function GetCompiledSpecKeywords(spec)
    if spec._compiledKeywords then return spec._compiledKeywords end
    local kwList = {}
    local seenKw = {}
    local function addKw(s)
        if not s or s == "" then return end
        local low = s:lower()
        if low ~= "" and not seenKw[low] then
            seenKw[low] = true
            table.insert(kwList, low)
        end
    end
    addKw(spec.internalName)
    if spec.cnName then
        local pureCn = spec.cnName:match("^([^%(%s/]+)")
        if pureCn and #pureCn >= 2 then addKw(pureCn) end
    end
    if spec.aliases then
        for i = 1, #spec.aliases do addKw(spec.aliases[i]) end
    end
    spec._compiledKeywords = kwList
    return kwList
end

local function GetInstanceSearchableSummary(inst)
    local now = tick()
    local cached = npcTextSummaryCache[inst]
    if cached and (now - cached.time < 10.0) and cached.name == inst.Name then
        return cached.summary
    end
    local parts = { (inst.Name or ""):lower() }
    local hum = inst:FindFirstChildOfClass("Humanoid")
    if hum and hum.DisplayName and hum.DisplayName ~= "" then
        table.insert(parts, hum.DisplayName:lower())
    end
    for _, sub in ipairs(inst:GetDescendants()) do
        if sub:IsA("ProximityPrompt") then
            if sub.ObjectText and sub.ObjectText ~= "" then table.insert(parts, sub.ObjectText:lower()) end
            if sub.ActionText and sub.ActionText ~= "" then table.insert(parts, sub.ActionText:lower()) end
        elseif sub:IsA("TextLabel") and sub.Text and sub.Text ~= "" and #sub.Text <= 60 then
            table.insert(parts, sub.Text:lower())
        end
    end
    local summary = table.concat(parts, " | ")
    npcTextSummaryCache[inst] = { summary = summary, time = now, name = inst.Name }
    return summary
end

DoesInstanceMatchNPCSpec = function(inst, spec)
    if not inst or not spec or inst == LocalPlayer.Character then return false end
    local okPlr, plr = pcall(function() return Players:GetPlayerFromCharacter(inst) end)
    if okPlr and plr then return false end
    local kwList = GetCompiledSpecKeywords(spec)
    local nLow = (inst.Name or ""):lower()
    for i = 1, #kwList do
        local kw = kwList[i]
        if nLow == kw or nLow:find(kw, 1, true) then
            return true
        end
    end
    local summary = GetInstanceSearchableSummary(inst)
    for i = 1, #kwList do
        local kw = kwList[i]
        if summary:find(kw, 1, true) then
            return true
        end
    end
    return false
end

-- 维护全局 ProximityPrompt 缓存与原始属性保护表（彻底解决：
-- 1) GetDescendants 全图扫描卡顿；
-- 2) 连续触发对话时 oldDist 被污染为 999999 导致手机屏幕一直残留“老江 聊天 / 石克翔 聊天”交互框跟着角色跑的 Bug！）
local originalPromptState = setmetatable({}, { __mode = "k" })
local currentlyTriggeringPrompts = setmetatable({}, { __mode = "k" })
local cachedAllPrompts = {}
local lastAllPromptsScan = 0

local function RememberPromptState(pr)
    if not pr then return { dist = 10, los = true, hold = 0 } end
    local existing = originalPromptState[pr]
    if existing then return existing end
    local rawDist = tonumber(pr.MaxActivationDistance) or 10
    -- 绝不把已被污染的超大距离（如 999999）当成原始距离记录！
    if rawDist > 35 or rawDist <= 0 then rawDist = 10 end
    local state = {
        dist = rawDist,
        los = (pr.RequiresLineOfSight ~= false),
        hold = math.clamp(tonumber(pr.HoldDuration) or 0, 0, 5),
    }
    originalPromptState[pr] = state
    return state
end

local function RestoreSinglePrompt(pr, forcePulseHide)
    if not pr or not pr.Parent then return end
    local orig = RememberPromptState(pr)
    currentlyTriggeringPrompts[pr] = nil
    pcall(function()
        pr.MaxActivationDistance = orig.dist
        pr.RequiresLineOfSight = orig.los
        pr.HoldDuration = orig.hold
        if forcePulseHide then
            -- 关键修复：当玩家远离 NPC 或关闭对话后，短暂关闭再开启 Enabled，
            -- 强制 Roblox ProximityPromptService 触发 PromptHidden 事件，立即销毁屏幕上粘滞的“老江 聊天 / 石克翔 聊天”悬浮框！
            pr.Enabled = false
            task.delay(0.12, function()
                if pr and pr.Parent and not currentlyTriggeringPrompts[pr] then
                    pcall(function()
                        pr.MaxActivationDistance = orig.dist
                        pr.RequiresLineOfSight = orig.los
                        pr.HoldDuration = orig.hold
                        pr.Enabled = true
                    end)
                end
            end)
        end
    end)
end

DismissStuckPromptsAndRestore = function(forceScanAll)
    local char = LocalPlayer.Character
    local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
    for pr, orig in pairs(originalPromptState) do
        if pr and pr.Parent and not currentlyTriggeringPrompts[pr] then
            local pPos = GetNPCPosition(pr.Parent)
            local isFar = (not myPos or not pPos) or ((myPos - pPos).Magnitude > (orig.dist + 4))
            if isFar or (tonumber(pr.MaxActivationDistance) or 0) > 35 then
                RestoreSinglePrompt(pr, isFar)
            end
        end
    end
    if forceScanAll then
        pcall(function()
            for _, d in ipairs(Workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") and d.Parent then
                    if not table.find(cachedAllPrompts, d) then
                        table.insert(cachedAllPrompts, d)
                    end
                    if not currentlyTriggeringPrompts[d] then
                        local distVal = tonumber(d.MaxActivationDistance) or 10
                        if distVal > 35 then
                            RestoreSinglePrompt(d, true)
                        else
                            RememberPromptState(d)
                        end
                    end
                end
            end
            lastAllPromptsScan = tick()
        end)
    end
    -- 额外清理 PlayerGui / CoreGui 下任何绑定在远端 NPC (>22米) 上的残留 ProximityPrompt BillboardGui
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        for _, container in ipairs({pg, CoreGui}) do
            if container then
                for _, g in ipairs(container:GetChildren()) do
                    if g:IsA("ScreenGui") or g:IsA("Folder") then
                        local gn = g.Name:lower()
                        if gn:find("proximityprompt") or gn:find("prompt") then
                            for _, bb in ipairs(g:GetDescendants()) do
                                if bb:IsA("BillboardGui") and bb.Adornee and myPos then
                                    local aPos = GetNPCPosition(bb.Adornee)
                                    if aPos and (myPos - aPos).Magnitude > 22 then
                                        bb.Enabled = false
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
end

-- 增量维护 cachedAllPrompts（通过 DescendantAdded / DescendantRemoving 实时同步，仅在缓存为空时才做一次兜底扫描，彻底告别周期性全图 GetDescendants）
table.insert(activeConnections, Workspace.DescendantAdded:Connect(function(d)
    if d and d:IsA("ProximityPrompt") then
        if not table.find(cachedAllPrompts, d) then
            table.insert(cachedAllPrompts, d)
        end
        if not currentlyTriggeringPrompts[d] and (tonumber(d.MaxActivationDistance) or 10) <= 35 then
            RememberPromptState(d)
        end
    end
end))
table.insert(activeConnections, Workspace.DescendantRemoving:Connect(function(d)
    if d and d:IsA("ProximityPrompt") then
        local idx = table.find(cachedAllPrompts, d)
        if idx then table.remove(cachedAllPrompts, idx) end
    end
end))

local function GetCachedWorkspacePrompts()
    local i = 1
    while i <= #cachedAllPrompts do
        local pr = cachedAllPrompts[i]
        if not pr or not pr.Parent then
            table.remove(cachedAllPrompts, i)
        else
            i = i + 1
        end
    end
    local now = tick()
    if #cachedAllPrompts == 0 and (now - lastAllPromptsScan >= 10.0) then
        lastAllPromptsScan = now
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Parent then
                table.insert(cachedAllPrompts, d)
                if not currentlyTriggeringPrompts[d] and (tonumber(d.MaxActivationDistance) or 10) <= 35 then
                    RememberPromptState(d)
                end
            end
        end
    end
    return cachedAllPrompts
end

-- 在全图中查找匹配的 NPC 实例（支持深入岛屿子文件夹与按 preferPos 距离排序）
local function FindNPCInstancesBySpec(spec)
    local results = {}
    local seen = {}
    if spec.liveKey and liveNPCs[spec.liveKey] and liveNPCs[spec.liveKey].inst and liveNPCs[spec.liveKey].inst.Parent then
        local cachedInst = liveNPCs[spec.liveKey].inst
        seen[cachedInst] = true
        table.insert(results, cachedInst)
    end
    if spec.internalName and OnlineNPCs[spec.internalName] then
        local cached = OnlineNPCs[spec.internalName]
        if cached.instance and cached.instance.Parent and not seen[cached.instance] then
            seen[cached.instance] = true
            table.insert(results, cached.instance)
        end
    end

    local searchContainers = {}
    for _, folderName in ipairs({"NPC", "NPCs", "Interactables", "DialogueNPCs", "QuestNPCs", "Map", "Islands", "World", "BossSetUp", "Fishes"}) do
        local f = Workspace:FindFirstChild(folderName)
        if f then table.insert(searchContainers, f) end
    end

    local function checkNode(inst)
        if not inst or seen[inst] then return end
        if DoesInstanceMatchNPCSpec(inst, spec) then
            seen[inst] = true
            table.insert(results, inst)
        end
    end

    for _, container in ipairs(searchContainers) do
        for _, ch in ipairs(container:GetChildren()) do
            checkNode(ch)
            if ch:IsA("Folder") or ch:IsA("Model") then
                for _, sub in ipairs(ch:GetChildren()) do
                    checkNode(sub)
                end
            end
        end
    end

    -- 全图 ProximityPrompt 反向溯源兜底（带 2.5s 缓存节流，专为挂载在深层岛屿建筑下的 NPC 设计，不卡主线程）
    if #results == 0 then
        local allPrompts = GetCachedWorkspacePrompts()
        for i = 1, #allPrompts do
            local d = allPrompts[i]
            if d and d.Parent then
                local okAnc, anc = pcall(function() return d:FindFirstAncestorOfClass("Model") end)
                local model = (okAnc and anc) or d.Parent
                if model and not seen[model] and DoesInstanceMatchNPCSpec(model, spec) then
                    seen[model] = true
                    table.insert(results, model)
                end
            end
        end
    end

    local anchorPos = spec.preferPos or spec.fallbackPos
    if anchorPos and #results > 1 then
        table.sort(results, function(a, b)
            local pa = GetNPCPosition(a) or Vector3.zero
            local pb = GetNPCPosition(b) or Vector3.zero
            return (pa - anchorPos).Magnitude < (pb - anchorPos).Magnitude
        end)
    end
    return results
end

-- 检测游戏内的 NPC 对话框 UI 是否已经弹出（带热点引用缓存 + 定向扫描，绝不每秒遍历整个 MainGui）
local cachedDialogueNode = nil
local function IsDialogueUIOpen()
    if cachedDialogueNode and cachedDialogueNode.Parent and cachedDialogueNode.Visible and cachedDialogueNode.AbsoluteSize.X > 20 then
        local sg = cachedDialogueNode:FindFirstAncestorOfClass("ScreenGui")
        if not sg or sg.Enabled then return true end
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "IdenticalHeavyweightFishing" and gui.Name ~= "RobloxGui" then
            local gName = gui.Name:lower()
            if gName:find("dialogue") or gName:find("dialog") or gName:find("talk") or gName:find("npc") or gName:find("chat") then
                for _, d in ipairs(gui:GetDescendants()) do
                    if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Visible and d.AbsoluteSize.X > 20 then
                        cachedDialogueNode = d
                        return true
                    end
                end
            else
                -- 仅检查 ScreenGui 顶层及二级对话相关面板，避免每秒全量 GetDescendants 遍历 MainGui 的数百个背包/商店节点
                for _, topChild in ipairs(gui:GetChildren()) do
                    if topChild:IsA("GuiObject") and topChild.Visible then
                        local cn = topChild.Name:lower()
                        if cn:find("dialogue") or cn:find("dialog") or cn:find("talk") or cn:find("npc") or cn:find("chat") or cn:find("interact") then
                            for _, d in ipairs(topChild:GetDescendants()) do
                                if d:IsA("TextButton") and d.Visible and d.AbsoluteSize.X > 20 then
                                    local t = (d.Text or ""):lower()
                                    if t:find("没关系") or t:find("主线") or t:find("任务") or t:find("对话")
                                        or t:find("nevermind") or t:find("cancel") or t:find("goodbye")
                                        or t:find("accept") or t:find("quest") or t:find("shop")
                                        or t:find("easy") or t:find("hard") or t:find("简单") or t:find("困难") then
                                        cachedDialogueNode = d
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- 触发指定 NPC 实例上的所有 ProximityPrompt / ClickDetector（防 999999 污染 + 脉冲清除残留交互 UI）
TriggerNPCInstancePrompts = function(npcInst)
    if not npcInst or not npcInst.Parent then return false end
    local triggered = false
    local prompts = {}
    if npcInst:IsA("ProximityPrompt") then
        table.insert(prompts, npcInst)
    else
        for _, d in ipairs(npcInst:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                table.insert(prompts, d)
            elseif d:IsA("ClickDetector") and type(fireclickdetector) == "function" then
                pcall(fireclickdetector, d)
                triggered = true
            end
        end
        if #prompts == 0 and npcInst.Parent then
            for _, d in ipairs(npcInst.Parent:GetChildren()) do
                if d:IsA("ProximityPrompt") then table.insert(prompts, d) end
            end
        end
    end

    for _, pr in ipairs(prompts) do
        if pr and pr.Parent then
            local orig = RememberPromptState(pr)
            currentlyTriggeringPrompts[pr] = true
            pcall(function()
                pr.Enabled = true
                pr.RequiresLineOfSight = false
                pr.MaxActivationDistance = 999999
                pr.HoldDuration = 0
            end)
            if type(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, pr)
                triggered = true
                -- C++ fireproximityprompt 为同步瞬发，触发后立即还原真实距离，防止残留 999999
                pcall(function()
                    pr.MaxActivationDistance = orig.dist
                    pr.RequiresLineOfSight = orig.los
                    pr.HoldDuration = orig.hold
                end)
                currentlyTriggeringPrompts[pr] = nil
            else
                TriggerPrompt(pr)
                triggered = true
            end
            task.delay(0.18, function()
                if pr and pr.Parent then
                    local char = LocalPlayer.Character
                    local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
                    local pPos = GetNPCPosition(pr.Parent)
                    local isFar = (not myPos or not pPos) or ((myPos - pPos).Magnitude > (orig.dist + 4))
                    RestoreSinglePrompt(pr, isFar)
                end
            end)
        end
    end
    return triggered
end

-- 自动点击当前弹出的 NPC 对话框选项（优先扫描对话/任务相关 ScreenGui，且完全等于匹配优先、包含次之）
local function AutoClickDialogueOption(preferredKeywords)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end
    local priorityGuis, fallbackGuis = {}, {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Name ~= "IdenticalHeavyweightFishing" and gui.Name ~= "RobloxGui" and gui.Enabled then
            local gn = gui.Name:lower()
            if gn:find("dialogue") or gn:find("dialog") or gn:find("talk") or gn:find("npc") or gn:find("chat") or gn:find("quest") then
                table.insert(priorityGuis, gui)
            else
                table.insert(fallbackGuis, gui)
            end
        end
    end
    local orderedGuis = (#priorityGuis > 0) and priorityGuis or fallbackGuis
    local candidates = {}
    local function collectFromGuis(guiList)
        for _, gui in ipairs(guiList) do
            for _, d in ipairs(gui:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.Active and d.AbsoluteSize.X > 10 then
                    local txt = ""
                    if d:IsA("TextButton") then
                        txt = (d.Text or ""):lower():match("^%s*(.-)%s*$")
                    else
                        local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                        if lbl then txt = (lbl.Text or ""):lower():match("^%s*(.-)%s*$") end
                    end
                    local bName = (d.Name or ""):lower():match("^%s*(.-)%s*$")
                    table.insert(candidates, { btn = d, txt = txt, bName = bName })
                end
            end
        end
    end
    collectFromGuis(orderedGuis)
    if #candidates == 0 and #priorityGuis > 0 then
        collectFromGuis(fallbackGuis)
    end
    -- 第一轮：完全匹配优先
    for _, kw in ipairs(preferredKeywords) do
        local kwLow = kw:lower()
        for _, c in ipairs(candidates) do
            if c.txt == kwLow or c.bName == kwLow then
                FireGuiButton(c.btn)
                return true
            end
        end
    end
    -- 第二轮：子串包含匹配
    for _, kw in ipairs(preferredKeywords) do
        local kwLow = kw:lower()
        for _, c in ipairs(candidates) do
            if (c.txt ~= "" and c.txt:find(kwLow, 1, true)) or (c.bName ~= "" and c.bName:find(kwLow, 1, true)) then
                FireGuiButton(c.btn)
                return true
            end
        end
    end
    return false
end

-- 一键传送到指定 NPC 面前（优先使用雷达精确坐标，未加载时飞往所属岛屿并自动对齐到加载出的 NPC 身边）
local function TeleportToNPCSpec(spec)
    if not spec then return false end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then
        ShowNotification("传送失败", "本地角色尚未加载完成。", "ERROR", 3)
        return false
    end

    local internalName = spec.internalName or spec.cnName or "NPC"
    local npcInstances = FindNPCInstancesBySpec(spec)
    local primaryInst = npcInstances[1]
    local cachedRadar = OnlineNPCs[internalName]
    local liveEntry = spec.liveKey and liveNPCs[spec.liveKey]
    local targetPos = (primaryInst and GetNPCPosition(primaryInst))
        or (liveEntry and liveEntry.pos)
        or (cachedRadar and cachedRadar.pos)
        or spec.preferPos
        or spec.fallbackPos

    if not targetPos then
        ShowNotification("传送提示", string.format("当前服务器暂未检测到 [%s] 刷新。", spec.cnName or internalName), "WARN", 4)
        return false
    end

    TryStreamAroundPosition(targetPos)
    SafeTeleport(CFrame.new(targetPos + Vector3.new(0, 3, 4), targetPos))
    ShowNotification("NPC 传送", "正在前往: " .. tostring(spec.cnName or internalName), "SUCCESS", 3)

    -- 到达岛屿后等待 0.28 秒流式加载完成，若扫描到真实 NPC 模型则二次精准对齐到他面前 3 米处
    task.spawn(function()
        task.wait(0.28)
        pcall(function()
            local loadedList = FindNPCInstancesBySpec(spec)
            if #loadedList > 0 then
                local exactPos = GetNPCPosition(loadedList[1])
                if exactPos then
                    OnlineNPCs[internalName] = { instance = loadedList[1], pos = exactPos, time = tick() }
                    SafeTeleport(CFrame.new(exactPos + Vector3.new(0, 3, 3.5), exactPos))
                end
            end
        end)
    end)
    return true
end

-- 核心双引擎对话（引擎1：名称直连零位移 -> 引擎2：岛屿流式预加载 + 微瞬移贴脸强制触发）
local function OpenRemoteNPCDialogue(spec, silent, postDialogueCallback)
    if not spec then return false end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then
        if not silent then ShowNotification("对话失败", "本地角色尚未加载完成。", "WARN", 3) end
        return false
    end

    local internalName = spec.internalName or spec.cnName or "NPC"
    local cachedRadar = OnlineNPCs[internalName]
    local liveEntry = spec.liveKey and liveNPCs[spec.liveKey]
    local npcInstances = FindNPCInstancesBySpec(spec)
    local primaryInst = npcInstances[1] or (liveEntry and liveEntry.inst) or (cachedRadar and cachedRadar.instance)
    local targetPos = (primaryInst and GetNPCPosition(primaryInst))
        or (liveEntry and liveEntry.pos)
        or (cachedRadar and cachedRadar.pos)
        or spec.preferPos
        or spec.fallbackPos

    if not primaryInst and not targetPos and not spec.altPositions then
        if not silent then
            ShowNotification("未探测到 NPC", string.format("雷达未在当前服务器检测到 [%s]，可能尚未刷新。", spec.cnName or internalName), "WARN", 4)
        end
        return false
    end

    task.spawn(function()
        -- 🥇 引擎 1：尝试原位名称直连触发（不移动角色）
        local directTried = false
        if primaryInst and primaryInst.Parent then
            if TriggerNPCInstancePrompts(primaryInst) then
                directTried = true
            end
        end
        if Events then
            local dlgRemoteNames = {"Dialogue", "Talk", "TalkToNPC", "NPCDialogue", "OpenDialogue", "InteractNPC", "NPCInteract", "Interact", "StartDialogue", "QuestDialogue"}
            for _, rName in ipairs(dlgRemoteNames) do
                local rem = Events:FindFirstChild(rName)
                if rem then
                    if primaryInst then SafeFireOneRemote(rem, primaryInst) end
                    SafeFireOneRemote(rem, internalName)
                    directTried = true
                end
            end
        end

        if directTried then
            task.wait(0.22)
            if IsDialogueUIOpen() then
                DismissStuckPromptsAndRestore(false)
                if not silent then
                    ShowNotification("角色", string.format("已打开 %s 的对话 (直连成功)。", internalName), "SUCCESS", 3)
                end
                if type(postDialogueCallback) == "function" then
                    pcall(postDialogueCallback)
                end
                return
            end
            DismissStuckPromptsAndRestore(false)
        end

        -- 🥈 引擎 2：岛屿流式预加载 + 微瞬移贴脸强制触发（彻底解决后期岛屿亚索/少林/楚天骄等被卸载导致只弹悬浮窗的问题）
        if not isMicroTeleportingNPC then
            isMicroTeleportingNPC = true
            local savedCF = root.CFrame
            local savedVel = root.AssemblyLinearVelocity
            local candidatePositions = {}
            if targetPos then table.insert(candidatePositions, targetPos) end
            if spec.altPositions then
                for _, ap in ipairs(spec.altPositions) do
                    local dup = false
                    for _, ep in ipairs(candidatePositions) do
                        if (ep - ap).Magnitude < 25 then dup = true; break end
                    end
                    if not dup then table.insert(candidatePositions, ap) end
                end
            end

            pcall(function()
                local dialogueOpened = false
                for _, probePos in ipairs(candidatePositions) do
                    if not isRunning then break end
                    TryStreamAroundPosition(probePos)
                    -- 第一步：先瞬移到岛屿锚点，让 Roblox 客户端把该岛上的 NPC 模型流式加载出来
                    root.CFrame = CFrame.new(probePos + Vector3.new(0, 3, 2))
                    root.AssemblyLinearVelocity = Vector3.zero
                    task.wait(0.28)

                    local nearInstances = FindNPCInstancesBySpec(spec)
                    local nearTriggered = false
                    if #nearInstances > 0 then
                        local exactNPC = nearInstances[1]
                        local exactPos = GetNPCPosition(exactNPC)
                        if exactPos then
                            OnlineNPCs[internalName] = { instance = exactNPC, pos = exactPos, time = tick() }
                            -- 第二步：如果 NPC 真实位置距离岛屿中心超过 12 米，再贴脸瞬移到该 NPC 面前 2 米处确保通过服务端距离校验！
                            if (root.Position - exactPos).Magnitude > 10 then
                                root.CFrame = CFrame.new(exactPos + Vector3.new(0, 2.5, 2))
                                root.AssemblyLinearVelocity = Vector3.zero
                                task.wait(0.18)
                            end
                        end
                        for _, inst in ipairs(nearInstances) do
                            if TriggerNPCInstancePrompts(inst) then
                                nearTriggered = true
                            end
                        end
                    end

                    -- 兜底：若仍未匹配到名字，触发当前位置 30 米内非商人的任务/对话 ProximityPrompt
                    if not nearTriggered then
                        local myNowPos = root.Position
                        local bestPr, bestDist = nil, 32
                        local allPrompts = GetCachedWorkspacePrompts()
                        for i = 1, #allPrompts do
                            local d = allPrompts[i]
                            if d and d.Parent then
                                local okAnc, anc = pcall(function() return d:FindFirstAncestorOfClass("Model") end)
                                local model = (okAnc and anc) or d.Parent
                                local mName = (model and model.Name or ""):lower()
                                if mName ~= "nana" and mName ~= "ba chang" and mName ~= "biao ge" then
                                    local pPos = GetNPCPosition(model)
                                    if pPos then
                                        local dist = (pPos - myNowPos).Magnitude
                                        if dist < bestDist then
                                            bestDist = dist
                                            bestPr = d
                                        end
                                    end
                                end
                            end
                        end
                        if bestPr then
                            local pPos = GetNPCPosition(bestPr.Parent)
                            if pPos and (root.Position - pPos).Magnitude > 10 then
                                root.CFrame = CFrame.new(pPos + Vector3.new(0, 2.5, 2))
                                root.AssemblyLinearVelocity = Vector3.zero
                                task.wait(0.15)
                            end
                            TriggerNPCInstancePrompts(bestPr)
                            nearTriggered = true
                        end
                    end

                    task.wait(0.25)
                    if IsDialogueUIOpen() or nearTriggered then
                        dialogueOpened = true
                        break
                    end
                end

                if type(postDialogueCallback) == "function" then
                    pcall(postDialogueCallback)
                    task.wait(0.22)
                end
            end)

            -- 恢复玩家原位，并立即还原/脉冲关闭所有远端 NPC 的 ProximityPrompt 悬浮提示框（彻底解决“老江 聊天 / 石克翔 聊天”粘在屏幕上的问题）
            if root and root.Parent then
                root.CFrame = savedCF
                root.AssemblyLinearVelocity = savedVel
            end
            isMicroTeleportingNPC = false
            DismissStuckPromptsAndRestore(false)
            task.delay(0.3, function()
                if isRunning then DismissStuckPromptsAndRestore(false) end
            end)
            if not silent then
                ShowNotification("角色", string.format("已打开 %s 的对话。", internalName), "SUCCESS", 3.5)
            end
        elseif not silent then
            ShowNotification("角色", string.format("已发送 %s 对话请求。", internalName), "WARN", 3)
        end
    end)
    return true
end

-- 为每一行同时创建【传送】与【对话】双按钮的专用行组件
local function createNPCDualActionRow(parent, labelText, descText, onTeleport, onDialogue)
    local row = createBaseRow(parent, labelText, descText, true)
    local tpBtn = Instance.new("TextButton")
    tpBtn.Size = UDim2.new(0, 56, 0, 24)
    tpBtn.Position = UDim2.new(1, -126, 0.5, -12)
    tpBtn.BackgroundColor3 = Colors.ControlBg
    tpBtn.Font = Enum.Font.GothamBold
    tpBtn.Text = "传送"
    tpBtn.TextColor3 = Colors.AccentBlue
    tpBtn.TextSize = 11
    tpBtn.BorderSizePixel = 0
    tpBtn.Parent = row
    Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)
    local tpEnterTween = TweenService:Create(tpBtn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite})
    local tpLeaveTween = TweenService:Create(tpBtn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg, TextColor3 = Colors.AccentBlue})
    tpBtn.MouseEnter:Connect(function() tpEnterTween:Play() end)
    tpBtn.MouseLeave:Connect(function() tpLeaveTween:Play() end)
    tpBtn.MouseButton1Click:Connect(function() if type(onTeleport) == "function" then pcall(onTeleport) end end)

    local dlgBtn = Instance.new("TextButton")
    dlgBtn.Size = UDim2.new(0, 64, 0, 24)
    dlgBtn.Position = UDim2.new(1, -64, 0.5, -12)
    dlgBtn.BackgroundColor3 = Colors.ControlBg
    dlgBtn.Font = Enum.Font.GothamBold
    dlgBtn.Text = "对话"
    dlgBtn.TextColor3 = Colors.PurplePrimary
    dlgBtn.TextSize = 11
    dlgBtn.BorderSizePixel = 0
    dlgBtn.Parent = row
    Instance.new("UICorner", dlgBtn).CornerRadius = UDim.new(0, 4)
    local dlgEnterTween = TweenService:Create(dlgBtn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.PurpleDark, TextColor3 = Colors.TextWhite})
    local dlgLeaveTween = TweenService:Create(dlgBtn, TweenInfo.new(0.15), {BackgroundColor3 = Colors.ControlBg, TextColor3 = Colors.PurplePrimary})
    dlgBtn.MouseEnter:Connect(function() dlgEnterTween:Play() end)
    dlgBtn.MouseLeave:Connect(function() dlgLeaveTween:Play() end)
    dlgBtn.MouseButton1Click:Connect(function() if type(onDialogue) == "function" then pcall(onDialogue) end end)
    return row
end

-- ==========================================
-- 神灵页面（三个神灵分类管理 + 道士接任务 + 四圣兽特质与Boss监控）
-- ==========================================
do
createCategoryHeader(tabGod, "三个神灵世界事件 (竹岛 / 冰霜岛 / 琥珀岛 · 50M 祈祷)")
local godCard = createCardGroup(tabGod)

createButtonRow(godCard, "检查三个神灵祝福状态", "检查竹岛/冰霜岛/琥珀岛三个神灵祝福进度与场上活跃神灵", "检查状态", function()
    local pData = GetPlayerData()
    local activeIslandNames = {}
    for _, spSpec in ipairs(ThreeSpiritsSpecs) do
        local entry = liveNPCs[spSpec.liveKey]
        if entry and entry.pos then
            table.insert(activeIslandNames, spSpec.islandName)
        end
    end
    local worldStr = (#activeIslandNames > 0) and ("当前刷新: " .. table.concat(activeIslandNames, ", ")) or "当前服未刷新神灵"
    if pData and pData:FindFirstChild("GodSpirit") then
        local y = pData.GodSpirit:FindFirstChild("Yellow") and pData.GodSpirit.Yellow.Value or false
        local b = pData.GodSpirit:FindFirstChild("Blue") and pData.GodSpirit.Blue.Value or false
        local g = pData.GodSpirit:FindFirstChild("Green") and pData.GodSpirit.Green.Value or false
        ShowNotification("三个神灵状态", string.format("黄(琥珀): %s | 蓝(冰霜): %s | 绿(竹岛): %s\n%s", y and "已祝福" or "未完成", b and "已祝福" or "未完成", g and "已祝福" or "未完成", worldStr), "SUCCESS", 6)
    else
        ShowNotification("三个神灵状态", worldStr .. " (未读取到本地 GodSpirit 节点)", "WARN", 5)
    end
end)

createToggleRow(godCard, "自动祈祷神灵", "当附近或当前服存在神灵祭坛时自动触发祈祷交互", Config.AutoPrayGodSpirit, function(v) Config.AutoPrayGodSpirit = v end, "AutoPrayGodSpirit")

createButtonRow(godCard, "一键寻找并祈祷当前服活跃神灵", "自动检测竹岛/冰霜岛/琥珀岛哪个神灵已刷新并立即前往祈祷", "立即祈祷", function()
    for _, spSpec in ipairs(ThreeSpiritsSpecs) do
        local entry = liveNPCs[spSpec.liveKey]
        if entry and entry.pos then
            OpenRemoteNPCDialogue(spSpec, false)
            return
        end
    end
    -- 若雷达尚未扫到，尝试扫描 NPC 文件夹下的 Spirit / God
    local npcFolder = Workspace:FindFirstChild("NPC") or Workspace:FindFirstChild("NPCs")
    local sp = npcFolder and (npcFolder:FindFirstChild("Spirit") or npcFolder:FindFirstChild("God"))
    if sp then
        OpenRemoteNPCDialogue({cnName = "活跃神灵", internalName = sp.Name, aliases = {"Spirit", "God"}, fallbackPos = GetNPCPosition(sp)}, false)
    else
        ShowNotification("三个神灵", "当前服务器竹岛/冰霜岛/琥珀岛均未检测到活跃神灵（每小时整点刷新10分钟）。", "WARN", 5)
    end
end)

-- 三个神灵分岛独立行（每行均支持【传送】到该岛祭坛 + 远程/微瞬移【祈祷/对话】）
for _, spSpec in ipairs(ThreeSpiritsSpecs) do
    createNPCDualActionRow(godCard, spSpec.cnName, spSpec.desc, function()
        TeleportToNPCSpec(spSpec)
    end, function()
        OpenRemoteNPCDialogue(spSpec, false)
    end)
end

createCategoryHeader(tabGod, "流动商人与「三个神灵」任务接取")
local roamGodCard = createCardGroup(tabGod)
createNPCDualActionRow(roamGodCard, "道士商人 (Taoist Merchant)", "接取「三个神灵」前置任务 / 购买 100M 道士珠与 200M 极鹰猎", function()
    TeleportToNPCSpec({cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", liveKey = "Taoist", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi"}})
end, function()
    OpenRemoteNPCDialogue({cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", liveKey = "Taoist", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi"}}, false)
end)
createNPCDualActionRow(roamGodCard, "茅山商人 (Maoshan Merchant)", "购买 300M 茅山竿(105威力) / 200M 茅山珠 / 200M 镇江技能", function()
    TeleportToNPCSpec({cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", liveKey = "Maoshan", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan"}})
end, function()
    OpenRemoteNPCDialogue({cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", liveKey = "Maoshan", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan"}}, false)
end)
createNPCDualActionRow(roamGodCard, "傻子隐藏商人 (Dumb Guy)", "轮换隐藏商人 · 获取六脉神鹰 Six Vein Divine Hawk 技能", function()
    TeleportToNPCSpec({cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", liveKey = "DumbGuy", aliases = {"Dumb Guy", "Dumb Man", "Dumb"}})
end, function()
    OpenRemoteNPCDialogue({cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", liveKey = "DumbGuy", aliases = {"Dumb Guy", "Dumb Man", "Dumb"}}, false)
end)

createCategoryHeader(tabGod, "四圣兽 (朱雀 / 玄武 / 白虎 / 青龙 · 神话特质与圣兽Boss雷达)")
local beastCard = createCardGroup(tabGod)
createButtonRow(beastCard, "检查四圣兽特质与场上圣兽状态", "扫描当前已装备技能是否拥有四圣兽特质，并检测场上四圣兽Boss", "检查四圣兽", function()
    local pData = GetPlayerData()
    local ownedBeasts = {}
    if pData then
        for _, d in ipairs(pData:GetDescendants()) do
            if d:IsA("ValueBase") and type(d.Value) == "string" then
                local vLow = d.Value:lower()
                for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                    for _, al in ipairs(bSpec.aliases) do
                        if vLow:find(al:lower(), 1, true) then
                            table.insert(ownedBeasts, bSpec.cnName .. "(" .. d.Parent.Name .. ")")
                            break
                        end
                    end
                end
            end
        end
    end
    local spawnedBeasts = {}
    for _, bSpec in ipairs(FourSacredBeastsSpecs) do
        local entry = liveNPCs[bSpec.liveKey]
        if entry and entry.pos then
            table.insert(spawnedBeasts, bSpec.cnName)
        end
    end
    local traitMsg = (#ownedBeasts > 0) and table.concat(ownedBeasts, ", ") or "暂未洗出四圣兽特质"
    local worldMsg = (#spawnedBeasts > 0) and table.concat(spawnedBeasts, ", ") or "当前服无四圣兽Boss刷新"
    ShowNotification("四圣兽状态总览", string.format("已持有特质: %s\n世界雷达: %s", traitMsg, worldMsg), "SUCCESS", 6)
end)

createNPCDualActionRow(beastCard, "前往南江洗练四圣兽特质 (Nanjang)", "初始岛每次消耗 5 水晶重铸特质 (四圣兽 0.1% 概率自动弹窗提醒)", function()
    TeleportToNPCSpec(ImportantDialogueNPCs[2])
end, function()
    OpenRemoteNPCDialogue(ImportantDialogueNPCs[2], false)
end)

for _, bSpec in ipairs(FourSacredBeastsSpecs) do
    bSpec.internalName = bSpec.engName
    createNPCDualActionRow(beastCard, bSpec.cnName, bSpec.desc, function()
        TeleportToNPCSpec(bSpec)
    end, function()
        OpenRemoteNPCDialogue(bSpec, false)
    end)
end

createCategoryHeader(tabGod, "服务器跳转引擎")
local hopCard = createCardGroup(tabGod)
createToggleRow(hopCard, "为神灵跳服务器", "若当前服无神灵，自动跳服寻找", Config.AutoServerHopGod, function(v) Config.AutoServerHopGod = v end, "AutoServerHopGod")
createToggleRow(hopCard, "为茅山跳服务器", "若当前服无茅山，自动跳服寻找", Config.AutoServerHopMaoshan, function(v) Config.AutoServerHopMaoshan = v end, "AutoServerHopMaoshan")
createToggleRow(hopCard, "为道士跳服务器", "若当前服无道士，自动跳服寻找", Config.AutoServerHopTaoist, function(v) Config.AutoServerHopTaoist = v end, "AutoServerHopTaoist")
createButtonRow(hopCard, "立即跳服务器", "立即跳转到随机不同服务器", "跳转", ServerHop)
end -- end of God UI scope

-- ==========================================
-- 🎫 票据任务与全量 NPC 传送+对话面板
-- ==========================================
RunTicketQuestAction = function(diffArg, manualNotify)
    diffArg = diffArg or (QuestDiffMap[Config.TicketDifficulty] or "Easy")
    local isHard = (diffArg == "Hard" or diffArg == "困难")
    local diffKey = isHard and "Hard" or "Easy"
    local diffCN = isHard and "困难" or "简单"

    if Events then
        local questRemNames = {
            "TicketQuest", "Quest", "AcceptQuest", "ClaimQuest", "SubmitQuest",
            "CompleteQuest", "StartQuest", "GetQuest", "TakeQuest", "DialogueQuest"
        }
        for _, rName in ipairs(questRemNames) do
            local rem = Events:FindFirstChild(rName)
            if rem then
                if rName == "TicketQuest" then
                    SafeFireOneRemote(rem, diffKey)
                else
                    SafeFireOneRemote(rem, "Ticket", diffKey)
                end
                break
            end
        end
    end

    OpenRemoteNPCDialogue(TicketQuestNPCSpec, true, function()
        local diffKeywords = isHard
            and {"困难", "Hard", "挑战", "Hard Quest", "票据"}
            or  {"简单", "Easy", "普通", "Easy Quest", "票据"}
        AutoClickDialogueOption(diffKeywords)
        task.wait(0.3)
        AutoClickDialogueOption({"接受", "接取", "提交", "领取", "完成", "确定", "Accept", "Claim", "Submit", "Complete", "Yes", "主线任务"})
        task.wait(0.3)
        AutoClickDialogueOption({"确定", "确认", "提交", "领取", "Yes", "Confirm", "Claim", "Accept"})
    end)

    if manualNotify then
        ShowNotification("票据任务", string.format("已对 [Quest Giver] 执行 [%s] 票据任务远程对话与接取/提交！", diffCN), "SUCCESS", 3.5)
    end
    return true
end

do
createCategoryHeader(tabQuests, "票据任务 (双引擎: 直连 + 微瞬移保底)")
local questCard = createCardGroup(tabQuests)
createToggleRow(questCard, "自动票据任务", "自动找 Quest Giver 发起对话、接受并提交票据任务", Config.AutoTicketQuest, function(v)
    Config.AutoTicketQuest = v
    if v then
        task.spawn(function()
            local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
            RunTicketQuestAction(diffArg, false)
        end)
    end
end, "AutoTicketQuest")
createDropdownRow(questCard, "难度", "票据任务难度 (自动/手动通用)", {"简单", "困难", "Easy", "Hard"}, Config.TicketDifficulty, function(v) Config.TicketDifficulty = v end, "TicketDifficulty")
createButtonRow(questCard, "接受并提交票据任务(简单)", "对 Quest Giver 发起简单任务对话 (含微瞬移保底)", "执行简单", function()
    RunTicketQuestAction("Easy", true)
end)
createButtonRow(questCard, "接受并提交票据任务(困难)", "对 Quest Giver 发起困难任务对话 (含微瞬移保底)", "执行困难", function()
    RunTicketQuestAction("Hard", true)
end)

createCategoryHeader(tabQuests, "每日任务与奖励")
local dailyCard = createCardGroup(tabQuests)

createButtonRow(dailyCard, "领取每日任务", "检测完成的每日任务并领取", "领取", function()
    if isClaimingDailyTask then
        ShowNotification("每日任务", "正在顺序领取中，请稍候...", "WARN")
        return
    end
    isClaimingDailyTask = true
    task.spawn(function()
        if Events then
            local claimRem = Events:FindFirstChild("ClaimQuest") or Events:FindFirstChild("ClaimDailyQuest") or Events:FindFirstChild("DailyQuest")
            if claimRem then
                for i = 1, 4 do
                    SafeFireOneRemote(claimRem, "Daily", i)
                    SafeFireOneRemote(claimRem, i)
                    task.wait(0.45)
                end
                ShowNotification("每日任务", "已按顺序发送每日任务领取请求！", "SUCCESS")
            else
                ShowNotification("每日任务", "未找到每日任务远程事件。", "WARN")
            end
        end
        task.wait(1.5)
        isClaimingDailyTask = false
    end)
end)

createToggleRow(dailyCard, "自动领取每日奖励", "按顺序领取1到7天的每日奖励", Config.AutoClaimDaily, function(v) Config.AutoClaimDaily = v end, "AutoClaimDaily")
createSliderRow(dailyCard, "领取延迟", "领取天数之间的延迟", 0.3, 2.0, Config.DailyClaimDelay, true, "秒", function(v) Config.DailyClaimDelay = v end, "DailyClaimDelay")

createButtonRow(dailyCard, "立即领取第1到7天", "批量领取所有7天每日奖励", "领取全部", function()
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
        task.wait(2.5)
        isClaimingDailySign = false
    end)
end)

local isRedeemingCodes = false
local knownActiveCodes = {
    "Legendary", "BannerShop", "WeeklyUPD1", "85KLikes", "25KActives",
    "Riku", "SON", "VermilionBird", "80KLikes", "Welcome", "HWF", "AXO",
    "60KLikes", "50KLikes", "41MVisits", "40MVisits", "39MVisits",
    "33MVisits", "32MVisits", "31MVisits", "SeeYouSoon", "13KActives", "6KActives"
}
createButtonRow(dailyCard, "兑换所有代码", "兑换所有已知的有效促销代码", "兑换", function()
    if isRedeemingCodes then
        ShowNotification("兑换代码", "正在批量兑换代码中，请稍候...", "WARN")
        return
    end
    isRedeemingCodes = true
    task.spawn(function()
        local codeRem = nil
        if Events then
            for _, rName in ipairs({"RedeemCode", "Code", "Codes", "UseCode", "ClaimCode", "PromoCode"}) do
                local found = Events:FindFirstChild(rName)
                if found then codeRem = found; break end
            end
        end
        if codeRem then
            ShowNotification("兑换代码", string.format("开始批量兑换 %d 个促销代码...", #knownActiveCodes), "SUCCESS", 4)
            for _, codeStr in ipairs(knownActiveCodes) do
                if not isRunning then break end
                SafeFireOneRemote(codeRem, codeStr)
                task.wait(0.25)
            end
            ShowNotification("兑换完成", "所有已知有效代码已尝试兑换完毕！", "SUCCESS", 4.5)
        else
            ShowNotification("兑换代码", "当前服务器未找到代码兑换远程接口。", "WARN", 4)
        end
        task.wait(1.0)
        isRedeemingCodes = false
    end)
end)

-- ==========================================
-- NPC 对话与一键传送 (每行均配【传送】+【对话】双按钮，解决远距离岛屿流式卸载问题)
-- ==========================================
createCategoryHeader(tabQuests, "NPC对话与传送 (每行支持: [传送] 到面前 + 远距离 [对话])")
local npcTalkCard = createCardGroup(tabQuests)

for _, npcSpec in ipairs(ImportantDialogueNPCs) do
    createNPCDualActionRow(npcTalkCard, npcSpec.cnName, npcSpec.desc, function()
        TeleportToNPCSpec(npcSpec)
    end, function()
        OpenRemoteNPCDialogue(npcSpec, false)
    end)
end

-- ==========================================
-- NPC 任务 (自动把鱼给猴子等专项 NPC 提交任务)
-- ==========================================
createCategoryHeader(tabQuests, "NPC任务")
local npcQuestSubCard = createCardGroup(tabQuests)

local MonkeyNPCSpec = {
    cnName = "猴子",
    internalName = "Monkey",
    aliases = {"Monkey", "MonkeyKing", "WuKong", "Ape", "Khi"},
    fallbackPos = nil,
}

local isGivingMonkeyFish = false
RunGiveFishToMonkeyBatch = function()
    if isGivingMonkeyFish or not isRunning then return end
    isGivingMonkeyFish = true
    task.spawn(function()
        pcall(function()
            local maxGive = tonumber(Config.MonkeyGiveCount) or 100
            OpenRemoteNPCDialogue(MonkeyNPCSpec, true, function()
                AutoClickDialogueOption({"给鱼", "提交", "喂食", "Give", "Submit", "Feed", "Yes", "确定", "主线任务"})
            end)
            if Events then
                for _, rName in ipairs({"GiveFish", "SubmitFish", "MonkeyQuest", "FeedMonkey", "Monkey", "QuestSubmit", "GiveItem"}) do
                    local rem = Events:FindFirstChild(rName)
                    if rem then
                        SafeFireOneRemote(rem, "Monkey", maxGive)
                        break
                    end
                end
            end
        end)
        task.wait(2.0)
        isGivingMonkeyFish = false
    end)
end

createToggleRow(npcQuestSubCard, "自动把鱼给猴子", "收集千金台任务 (自动远程向猴子提交鱼类)", Config.AutoGiveMonkey, function(v)
    Config.AutoGiveMonkey = v
    if v then RunGiveFishToMonkeyBatch() end
end, "AutoGiveMonkey")
createDropdownRow(npcQuestSubCard, "给鱼数量", "最大给鱼数量", {"10", "25", "50", "100", "200", "500"}, tostring(Config.MonkeyGiveCount or 100), function(v)
    Config.MonkeyGiveCount = tonumber(v) or 100
end, "MonkeyGiveCount")

end -- end of Quests UI scope

-- ==========================================
-- 商店页面
-- ==========================================
do
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
            if SafeTeleport(CFrame.new(tp.x, tp.y + 3, tp.z)) then
                ShowNotification("传送", "已到达: " .. tp.name, "SUCCESS")
            end
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
        local name = (box.Text or ""):gsub("[%c]", ""):sub(1, 48)
        if name == "" then name = "自定义点 " .. (#CustomTPs + 1) end
        if #CustomTPs >= 100 then
            ShowNotification("保存失败", "自定义传送点最多保存 100 个，请先删除旧项目。", "WARN")
            return
        end
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

do
createCategoryHeader(tabTeleports, "特殊NPC实时检测与传送 (三个神灵 + 茅山/道士 + 四圣兽)")
local liveNPCCard = createCardGroup(tabTeleports)
local function CreateNPCRow(key, data)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.Parent = liveNPCCard
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -110, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = row
    local title = Instance.new("TextLabel"); title.Size = UDim2.new(1, 0, 0, 18); title.Position = UDim2.new(0, 0, 0, 4); title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.Text = data.icon .. " " .. data.name .. " (未检测到)"; title.TextColor3 = Colors.TextMuted; title.TextSize = 12; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = tf
    local desc = Instance.new("TextLabel"); desc.Size = UDim2.new(1, 0, 0, 14); desc.Position = UDim2.new(0, 0, 0, 22); desc.BackgroundTransparency = 1; desc.Font = Enum.Font.Gotham; desc.Text = data.desc or "等待刷新..."; desc.TextColor3 = Colors.TextMuted; desc.TextSize = 10; desc.TextXAlignment = Enum.TextXAlignment.Left; desc.Parent = tf
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = data.fallbackPos and "前往岛屿" or "传送"; btn.TextColor3 = Colors.TextMuted; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    data.ui_title = title; data.ui_desc = desc; data.ui_btn = btn
    btn.MouseButton1Click:Connect(function()
        local targetDest = data.pos or data.fallbackPos
        if targetDest then
            local char = LocalPlayer.Character; local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                TryStreamAroundPosition(targetDest)
                local dir = (root.Position - targetDest); dir = Vector3.new(dir.X, 0, dir.Z)
                if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) else dir = dir.Unit end
                local targetPos = targetDest + dir * 6 + Vector3.new(0, 10, 0)
                local rayParams = RaycastParams.new(); rayParams.FilterType = Enum.RaycastFilterType.Exclude
                local ignoreList = {}
                if char then table.insert(ignoreList, char) end
                local espInst = Workspace:FindFirstChild("IdenticalESP")
                if espInst then table.insert(ignoreList, espInst) end
                rayParams.FilterDescendantsInstances = ignoreList
                local rayResult = Workspace:Raycast(targetPos, Vector3.new(0, -50, 0), rayParams)
                if rayResult then targetPos = rayResult.Position + Vector3.new(0, 3, 0) else targetPos = targetDest + dir * 6 + Vector3.new(0, 3, 0) end
                SafeTeleport(CFrame.new(targetPos, targetDest))
                if data.pos then
                    ShowNotification("传送成功", "已到达活跃 " .. data.name .. " 的安全位置！", "SUCCESS")
                else
                    ShowNotification("已前往祭坛岛屿", "已传送到 " .. data.name .. " 所在岛屿，正在检测是否刷新...", "WARN")
                end
            end
        else
            ShowNotification("提示", "当前服务器未检测到 " .. data.name .. " 刷新。", "WARN")
        end
    end)
end
for _, key in ipairs(liveNPCOrder) do
    if liveNPCs[key] then CreateNPCRow(key, liveNPCs[key]) end
end

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
    if playerDropdown and playerDropdown.Get then
        selectedPlayerName = playerDropdown.Get()
    end
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
    if SafeTeleport(target.Character.HumanoidRootPart.CFrame + Vector3.new(0, 2, 3)) then
        ShowNotification("玩家传送", "已传送到 " .. (target.DisplayName or target.Name), "SUCCESS")
    else
        ShowNotification("玩家传送", "本地角色未就绪", "ERROR")
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
    if selected.Character and selected.Character:FindFirstChild("HumanoidRootPart") then
        if SafeTeleport(selected.Character.HumanoidRootPart.CFrame + Vector3.new(0, 2, 3)) then
            ShowNotification("玩家传送", "已传送到 " .. selected.DisplayName, "SUCCESS")
        end
    end
end)

end -- end of Teleports scope

-- ==========================================
-- 视觉设置函数（移出每帧渲染循环）
-- ==========================================
local isApplyingLighting = false
local lastCameraParticleScan = 0
ApplyLightingSettings = function()
    if not isRunning or isApplyingLighting then return end
    isApplyingLighting = true
    pcall(function()
    if Config.Fullbright then
        Lighting.Brightness = 2.5
        Lighting.ClockTime = 14
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    else
        Lighting.Brightness = originalLightingState.Brightness
        Lighting.ClockTime = originalLightingState.ClockTime
        Lighting.Ambient = originalLightingState.Ambient
        Lighting.OutdoorAmbient = originalLightingState.OutdoorAmbient
    end
    -- 性能模式只负责阴影；全亮关闭后也不会错误覆盖性能模式。
    if Config.Fullbright or Config.PerformanceMode then
        Lighting.GlobalShadows = false
    else
        Lighting.GlobalShadows = originalLightingState.GlobalShadows
    end
    if Config.NoFog then
        Lighting.FogEnd = 1000000
        Lighting.FogStart = 1000000
        local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
        if atmo then
            RememberAtmosphere(atmo)
            atmo.Density = 0
            atmo.Haze = 0
            atmo.Glare = 0
        end
        local now = tick()
        local currentCamera = Workspace.CurrentCamera or Camera
        if currentCamera and (now - lastCameraParticleScan >= 2.0) then
            lastCameraParticleScan = now
            for _, d in ipairs(currentCamera:GetDescendants()) do
                if d:IsA("ParticleEmitter") then
                    if originalParticleState[d] == nil then originalParticleState[d] = d.Enabled end
                    if d.Enabled then d.Enabled = false end
                end
            end
        end
    end
    end)
    isApplyingLighting = false
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
createToggleRow(perfCard, "无雾无雨", "临时隐藏雾效与相机粒子，关闭后恢复原状态", Config.NoFog, function(v)
    Config.NoFog = v
    if not v then RestoreNoFogChanges() end
    ApplyLightingSettings()
end, "NoFog")
createToggleRow(perfCard, "全亮", "临时提高环境亮度，关闭后恢复原状态", Config.Fullbright, function(v)
    Config.Fullbright = v
    ApplyLightingSettings()
end, "Fullbright")
createToggleRow(perfCard, "性能模式(关闭阴影)", "仅关闭全局阴影；不改动纹理、特效和渲染距离", Config.PerformanceMode, function(v)
    Config.PerformanceMode = v
    ApplyLightingSettings()
end, "PerformanceMode")
createToggleRow(perfCard, "关闭3D渲染(省电挂机)", "黑屏关闭3D画面渲染，大幅降低CPU/GPU占用", Config.Disable3DRendering, function(v)
    Config.Disable3DRendering = v
    blackOutFrame.Visible = v
    local ok = pcall(function() RunService:Set3dRenderingEnabled(not v) end)
    if v and not ok then
        ShowNotification("省电挂机提示", "当前执行器不支持底层关闭 3D 渲染，已启用黑屏遮罩降低 UI 与 ESP 刷新负载。", "WARN", 5)
    end
end, "Disable3DRendering")
createToggleRow(perfCard, "隐藏游戏UI", "隐藏指定游戏界面，关闭后恢复原来的显示状态", Config.HideGameUI, function(v)
    Config.HideGameUI = v
    SetGameUIHidden(v)
end, "HideGameUI")

-- ==========================================
-- 移动页面
-- ==========================================
createCategoryHeader(tabPlayer, "玩家移动")
local moveCard = createCardGroup(tabPlayer)
createToggleRow(moveCard, "步行加速", "提高移动速度", Config.WalkSpeedEnabled, function(v)
    Config.WalkSpeedEnabled = v
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if hum then
        RememberHumanoidState(hum)
        local saved = originalHumanoidState[hum]
        hum.WalkSpeed = v and Config.WalkSpeedValue or (saved and saved.WalkSpeed or 16)
    end
end, "WalkSpeedEnabled")
createSliderRow(moveCard, "速度值", "目标步行速度", 16, 120, Config.WalkSpeedValue, false, "", function(v)
    Config.WalkSpeedValue = v
    if Config.WalkSpeedEnabled then
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then RememberHumanoidState(hum); hum.WalkSpeed = v end
    end
end, "WalkSpeedValue")
createToggleRow(moveCard, "飞行", "PC: WASD+空格/Shift | 手机: 摇杆移动+跳跃上升（开启后悬停不掉落）", Config.FlyEnabled, function(v) Config.FlyEnabled = v end, "FlyEnabled")
createSliderRow(moveCard, "飞行速度", "飞行移动速度", 20, 150, Config.FlySpeed, false, "", function(v) Config.FlySpeed = v end, "FlySpeed")
createToggleRow(moveCard, "无限跳跃", "在空中无限跳跃", Config.InfiniteJump, function(v) Config.InfiniteJump = v end, "InfiniteJump")
createToggleRow(moveCard, "水上行走", "在海面上行走(海平面: 0)", Config.WalkOnWater, function(v) Config.WalkOnWater = v end, "WalkOnWater")
createToggleRow(moveCard, "穿墙", "穿过固体障碍和墙壁 (零GC优化)", Config.Noclip, function(v)
    Config.Noclip = v
    if not v then
        for part, oldValue in pairs(originalCanCollide) do
            if part and part.Parent then part.CanCollide = oldValue end
        end
        table.clear(originalCanCollide)
        noclipWasActive = false
    end
end, "Noclip")

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

-- 全部 UI 构建完成后，强制按真实子项高度刷新每个标签页 Canvas（解决钓鱼页滑到一半到底）
task.defer(function()
    for name, refresher in pairs(tabCanvasRefreshers) do
        pcall(refresher)
    end
end)
task.delay(0.4, function()
    for name, refresher in pairs(tabCanvasRefreshers) do
        pcall(refresher)
    end
end)
task.delay(1.2, function()
    for name, refresher in pairs(tabCanvasRefreshers) do
        pcall(refresher)
    end
end)
end -- end of Visuals/Player/Profiles scope
end -- end of Tab & Feature Construction Scope

-- 自动装备背包中的鱼竿工具（解决打 Enzo 时提示 "Equip your fishing rod to fight the boss!" 以及未拿鱼竿导致手机端右侧[钓鱼]按键消失的问题）
EnsureFishingRodEquipped = function()
    local char = LocalPlayer.Character
    if not char then return false end
    local existingTool = char:FindFirstChildOfClass("Tool")
    if existingTool then return true end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if not hum or not bp then return false end
    local bestTool = nil
    local pData = GetPlayerData()
    local equippedRodName = pData and pData:FindFirstChild("FishingRod") and pData.FishingRod.Value or nil
    for _, tool in ipairs(bp:GetChildren()) do
        if tool:IsA("Tool") then
            local tn = tool.Name:lower()
            if (equippedRodName and tool.Name == equippedRodName) or tn:find("rod") or tn:find("钓") or tn:find("竿") or tn:find("fish") then
                bestTool = tool
                break
            end
            if not bestTool then bestTool = tool end
        end
    end
    if bestTool then
        pcall(function() hum:EquipTool(bestTool) end)
        return true
    end
    return false
end

-- 保持 MainGui / Fisher_GUI 原生界面结构纯净，启动时不篡改任何子面板 Visible 状态，确保钓鱼按钮与 Boss 弹窗 100% 原生正常工作

SyncUIWithConfig()

-- ==========================================
-- 角色零件监听（用于零开销 Noclip）
-- ==========================================
local function CacheCharacterParts(char)
    -- 角色重生时先断开旧角色监听，避免每次重生都累积两个事件连接，同时清理已销毁旧零件引用。
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    table.clear(cachedCharacterParts)
    for part in pairs(originalCanCollide) do
        if not part or not part.Parent then originalCanCollide[part] = nil end
    end
    cachedFishConstraint = nil
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then table.insert(cachedCharacterParts, part) end
    end
    table.insert(characterConnections, char.DescendantAdded:Connect(function(part)
        if part:IsA("BasePart") then table.insert(cachedCharacterParts, part) end
    end))
    table.insert(characterConnections, char.DescendantRemoving:Connect(function(part)
        local idx = table.find(cachedCharacterParts, part)
        if idx then table.remove(cachedCharacterParts, idx) end
        if cachedFishConstraint == part then cachedFishConstraint = nil end
    end))
end

if LocalPlayer.Character then CacheCharacterParts(LocalPlayer.Character) end
table.insert(activeConnections, LocalPlayer.CharacterAdded:Connect(CacheCharacterParts))

-- Noclip 在 Stepped 中执行，直接遍历缓存数组，无新表创建开销
table.insert(activeConnections, RunService.Stepped:Connect(function()
    if not isRunning then return end
    if Config.Noclip then
        noclipWasActive = true
        for i = 1, #cachedCharacterParts do
            local part = cachedCharacterParts[i]
            if part and part.Parent then
                if originalCanCollide[part] == nil then originalCanCollide[part] = part.CanCollide end
                if part.CanCollide then part.CanCollide = false end
            end
        end
    elseif noclipWasActive then
        for part, oldValue in pairs(originalCanCollide) do
            if part and part.Parent then part.CanCollide = oldValue end
        end
        table.clear(originalCanCollide)
        noclipWasActive = false
    end
end))

-- 环境光照守候（涵盖全亮、去雾与性能模式关闭阴影）
table.insert(activeConnections, Lighting.Changed:Connect(function()
    if isRunning and (Config.Fullbright or Config.NoFog or Config.PerformanceMode) then
        ApplyLightingSettings()
    end
end))

-- 被踢重连（多通道守候 + isRejoining 防重入锁，避免重复触发两次 Teleport）
pcall(function()
    local isRejoining = false
    local function TryTriggerRejoin(reasonMsg)
        if isRejoining or not isRunning or not Config.AutoRejoin then return end
        isRejoining = true
        if reasonMsg then
            ShowNotification("自动重连", reasonMsg, "WARN")
        end
        task.delay(3, function()
            if isRunning and Config.AutoRejoin then
                pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
            end
            task.delay(10, function() isRejoining = false end)
        end)
    end
    task.spawn(function()
        local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
        local overlay = promptGui and promptGui:WaitForChild("promptOverlay", 5)
        if overlay and isRunning then
            table.insert(activeConnections, overlay.ChildAdded:Connect(function(child)
                if child and child.Name == "ErrorPrompt" then
                    TryTriggerRejoin("检测到断线弹窗，3秒后自动重新连接...")
                end
            end))
        end
    end)
    table.insert(activeConnections, LocalPlayer.OnTeleport:Connect(function(teleportState)
        if teleportState == Enum.TeleportState.Failed then
            TryTriggerRejoin("检测到传送失败，3秒后自动重连...")
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

-- 启动瞬间自动执行一次全图 ProximityPrompt 净化（即使上次旧脚本遗留了 999999 粘滞弹窗也能在 1 秒内立即清除）
task.spawn(function()
    task.wait(0.2)
    if isRunning and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(true)
    end
end)

-- 1.0 秒全自动雷达扫描（覆盖：竹岛/冰霜岛/琥珀岛三个神灵 + 茅山/道士/傻子商人 + 四圣兽Boss/特质 + 全量NPC缓存 + 对话退出自动清残留框）
task.spawn(function()
    local wasFound = {}
    local notifiedTraits = {}
    local lastHopCheck = tick()
    local wasDialogueOpen = false
    while isRunning do
        task.wait(Config.Disable3DRendering and 2.5 or 1.0)
        pcall(function()
            local nowDialogueOpen = IsDialogueUIOpen()
            if wasDialogueOpen and not nowDialogueOpen and DismissStuckPromptsAndRestore then
                -- 当玩家点击“没关系”退出对话瞬间，自动脉冲重置远端 ProximityPrompt，彻底杜绝交互框残留在屏幕上
                DismissStuckPromptsAndRestore(false)
            elseif not nowDialogueOpen and not isMicroTeleportingNPC and DismissStuckPromptsAndRestore then
                DismissStuckPromptsAndRestore(false)
            end
            wasDialogueOpen = nowDialogueOpen

            local char = LocalPlayer.Character
            local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
            local found = {}
            local foundOnlinePass = {}

            local scanFolders = {
                Workspace:FindFirstChild("NPC"),
                Workspace:FindFirstChild("NPCs"),
                Workspace:FindFirstChild("Interactables"),
                Workspace:FindFirstChild("BossSetUp"),
                Workspace:FindFirstChild("Fishes"),
            }

            local function inspectEntity(npc)
                if not npc or npc == char or (not npc:IsA("Model") and not npc:IsA("BasePart")) then return end
                if Players:GetPlayerFromCharacter(npc) then return end
                local name = npc.Name or ""
                local nLow = name:lower()
                local pos = GetNPCPosition(npc)
                if not pos then return end

                -- 1) 三个神灵分岛识别（根据坐标自动归入：竹岛神灵 / 冰霜岛神灵 / 琥珀岛神灵）
                if nLow == "spirit" or nLow == "god" or nLow == "spirits" or nLow:find("spirit") then
                    local isl = GetNearestIslandInfo(pos)
                    local spKey = "Spirit_Amber"
                    local spTitle = "琥珀岛神灵"
                    if isl and isl.id == 2 then
                        spKey = "Spirit_Bamboo"; spTitle = "竹岛神灵"
                    elseif isl and isl.id == 6 then
                        spKey = "Spirit_Frost"; spTitle = "冰霜岛神灵"
                    elseif isl and isl.id == 8 then
                        spKey = "Spirit_Amber"; spTitle = "琥珀岛神灵"
                    else
                        -- 按距离三座神灵岛最近的一座归类
                        local dBam = (pos - Vector3.new(-1223.0, 7.3, -24.1)).Magnitude
                        local dFro = (pos - Vector3.new(-1366.0, 11.9, -1495.4)).Magnitude
                        local dAmb = (pos - Vector3.new(1259.4, 9.1, 1401.5)).Magnitude
                        if dBam <= dFro and dBam <= dAmb then
                            spKey = "Spirit_Bamboo"; spTitle = "竹岛神灵"
                        elseif dFro <= dBam and dFro <= dAmb then
                            spKey = "Spirit_Frost"; spTitle = "冰霜岛神灵"
                        end
                    end
                    AddESP(npc, spTitle, "GodSpirit", Colors.AccentGreen, "⛩️")
                    liveNPCs[spKey].pos = pos
                    liveNPCs[spKey].inst = npc
                    found[spKey] = true
                    found.AnySpirit = true
                    if not wasFound[spKey] then
                        ShowNotification("⛩️ 神灵降临", liveNPCs[spKey].name .. " 已在服务器刷新！", "SUCCESS", 6)
                    end
                elseif nLow:find("taoist") or nLow:find("xiao daoshi") then
                    AddESP(npc, name, "Taoist", Colors.AccentOrange, "📜")
                    liveNPCs.Taoist.pos = pos
                    liveNPCs.Taoist.inst = npc
                    found.Taoist = true
                    if not wasFound.Taoist then
                        ShowNotification("📜 道士商人降临", "道士商人 (Taoist Merchant) 已在服务器刷新！", "SUCCESS", 6)
                    end
                elseif nLow:find("maoshan") or nLow:find("mao shan") then
                    AddESP(npc, name, "Maoshan", Colors.PurplePrimary, "✨")
                    liveNPCs.Maoshan.pos = pos
                    liveNPCs.Maoshan.inst = npc
                    found.Maoshan = true
                    if not wasFound.Maoshan then
                        ShowNotification("✨ 茅山商人降临", "茅山商人 (Maoshan Merchant) 已在服务器刷新！", "SUCCESS", 6)
                    end
                elseif nLow:find("dumb") or nLow:find("thang ngu") then
                    AddESP(npc, "傻子商人 (Dumb Guy)", "Taoist", Colors.AccentYellow, "🃏")
                    liveNPCs.DumbGuy.pos = pos
                    liveNPCs.DumbGuy.inst = npc
                    found.DumbGuy = true
                    if not wasFound.DumbGuy then
                        ShowNotification("🃏 隐藏商人降临", "傻子隐藏商人 (Dumb Guy) 已在服务器刷新！", "SUCCESS", 6)
                    end
                end

                -- 2) 四圣兽（朱雀 / 玄武 / 白虎 / 青龙）Boss 或特殊实体检测与弹窗报警
                for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                    local matchedBeast = false
                    for _, al in ipairs(bSpec.aliases) do
                        if nLow:find(al:lower(), 1, true) then
                            matchedBeast = true
                            break
                        end
                    end
                    if matchedBeast then
                        local bKey = bSpec.liveKey
                        AddESP(npc, bSpec.cnName, "Boss", bSpec.color, "🐉")
                        liveNPCs[bKey].pos = pos
                        liveNPCs[bKey].inst = npc
                        found[bKey] = true
                        if not wasFound[bKey] then
                            ShowNotification("🔥 四圣兽现世", bSpec.cnName .. " 已在当前服务器出现！", "SUCCESS", 6)
                        end
                    end
                end

                -- 3) 同步更新通用 NPC 雷达缓存 OnlineNPCs
                for _, spec in ipairs(ImportantDialogueNPCs) do
                    if DoesInstanceMatchNPCSpec(npc, spec) then
                        foundOnlinePass[spec.internalName] = true
                        OnlineNPCs[spec.internalName] = { instance = npc, pos = pos, time = tick() }
                    end
                end
            end

            for _, folder in ipairs(scanFolders) do
                if folder then
                    for _, ch in ipairs(folder:GetChildren()) do
                        inspectEntity(ch)
                        if ch:IsA("Folder") or ch:IsA("Model") then
                            for _, sub in ipairs(ch:GetChildren()) do
                                inspectEntity(sub)
                            end
                        end
                    end
                end
            end
            -- 针对直接放在 Workspace 根目录下的特殊 Model 仅按关键词过滤检查，避免每秒遍历全图地形零件
            for _, ch in ipairs(Workspace:GetChildren()) do
                if ch:IsA("Model") and ch ~= char then
                    local cn = ch.Name:lower()
                    if cn:find("spirit") or cn:find("god") or cn:find("taoist") or cn:find("maoshan")
                        or cn:find("dumb") or cn:find("bird") or cn:find("tortoise") or cn:find("tiger")
                        or cn:find("dragon") or cn:find("boss") or cn:find("yasuo") or cn:find("shaolin") then
                        inspectEntity(ch)
                    end
                end
            end

            -- 清理已消失的通用 NPC 缓存
            for k, v in pairs(OnlineNPCs) do
                if not foundOnlinePass[k] and (tick() - (v.time or 0) > 6.0) then
                    OnlineNPCs[k] = nil
                end
            end

            -- 4) 检查玩家技能槽是否新洗出了四圣兽神话特质（每 6 秒定向扫描非鱼类容器，0.1% 概率出货时立即弹窗恭贺，绝不遍历数百条背包鱼造成卡顿）
            local pData = GetPlayerData()
            if pData and (tick() - (notifiedTraits._lastScan or 0) >= 6.0) then
                notifiedTraits._lastScan = tick()
                for _, topFolder in ipairs(pData:GetChildren()) do
                    local fn = topFolder.Name
                    if fn ~= "Inventory" and fn ~= "Hotbar" and fn ~= "FishingRodInventory" and fn ~= "Bait" then
                        local toCheck = topFolder:GetDescendants()
                        table.insert(toCheck, topFolder)
                        for i = 1, #toCheck do
                            local d = toCheck[i]
                            if d:IsA("ValueBase") and type(d.Value) == "string" and d.Value ~= "" then
                                local vLow = d.Value:lower()
                                for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                                    for _, al in ipairs(bSpec.aliases) do
                                        if vLow:find(al:lower(), 1, true) then
                                            local noticeKey = bSpec.liveKey .. "_" .. d:GetFullName()
                                            if not notifiedTraits[noticeKey] then
                                                notifiedTraits[noticeKey] = true
                                                ShowNotification("🎉 四圣兽神话特质降临！", string.format("检测到四圣兽 [%s] 已激活于 [%s]！", bSpec.cnName, d.Parent and d.Parent.Name or d.Name), "SUCCESS", 8)
                                            end
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- 5) 刷新传送页面的 10 个特殊 NPC 实时状态行
            for _, key in ipairs(liveNPCOrder) do
                local data = liveNPCs[key]
                if data and data.ui_title then
                    if found[key] and data.pos then
                        data.ui_title.Text = data.icon .. " " .. data.name .. " (🟢 已刷新)"
                        data.ui_title.TextColor3 = Colors.AccentGreen
                        if myPos then
                            local isl = GetNearestIslandInfo(data.pos)
                            local islTag = isl and (" · " .. isl.name) or ""
                            data.ui_desc.Text = string.format("距离你: %d 米%s", math.floor((myPos - data.pos).Magnitude), islTag)
                        else
                            data.ui_desc.Text = "位置已锁定，点击立即传送"
                        end
                        data.ui_btn.BackgroundColor3 = Colors.PurpleAccent
                        data.ui_btn.TextColor3 = Colors.TextWhite
                        data.ui_btn.Text = "立即传送"
                    else
                        data.pos = nil
                        data.inst = nil
                        data.ui_title.Text = data.icon .. " " .. data.name .. " (未检测到)"
                        data.ui_title.TextColor3 = Colors.TextMuted
                        data.ui_desc.Text = data.desc or "等待刷新..."
                        data.ui_btn.BackgroundColor3 = Colors.ControlBg
                        data.ui_btn.TextColor3 = data.fallbackPos and Colors.PurplePrimary or Colors.TextMuted
                        data.ui_btn.Text = data.fallbackPos and "前往岛屿" or "传送"
                    end
                end
            end
            wasFound = found

            if tick() - lastHopCheck >= 8.0 then
                lastHopCheck = tick()
                local inCombatNow = LocalPlayer.Character and LocalPlayer.Character:GetAttribute("Minigame") == true
                if not inCombatNow and (
                   (Config.AutoServerHopGod and not found.AnySpirit) or
                   (Config.AutoServerHopMaoshan and not found.Maoshan) or
                   (Config.AutoServerHopTaoist and not found.Taoist)) then
                    ServerHop()
                end
            end

            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                    AddESP(p.Character, p.DisplayName, "Players", Colors.PurpleAccent, "👤")
                end
            end
            local srFolder = Workspace:FindFirstChild("SecretRod")
            if srFolder then
                for _, r in ipairs(srFolder:GetChildren()) do AddESP(r, r.Name, "SecretRod", Colors.AccentYellow, "🌟") end
            end
            local boatFolder = Workspace:FindFirstChild("Boat")
            if boatFolder then
                for _, b in ipairs(boatFolder:GetChildren()) do AddESP(b, b.Name, "Boats", Colors.AccentBlue, "⛵") end
            end
            local bossFolder = Workspace:FindFirstChild("BossSetUp")
            if bossFolder then
                for _, b in ipairs(bossFolder:GetChildren()) do AddESP(b, b.Name, "Boss", Colors.AccentRed, "👹") end
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
    local lastPingCheck = 0
    
    while isRunning do
        task.wait(0.5)
        pcall(function()
            local pData = GetPlayerData()
            local now = tick()
            local elapsed = now - startTime
            
            local h = math.floor(elapsed / 3600)
            local m = math.floor((elapsed % 3600) / 60)
            local s = math.floor(elapsed % 60)
            DashUI.lblHangTime.Text = string.format("%02d:%02d:%02d", h, m, s)

            if now - lastPingCheck >= 2.0 then
                lastPingCheck = now
                local pingOk, pingVal = pcall(function() return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue()) end)
                if pingOk then DashUI.lblPing.Text = pingVal .. " ms" else DashUI.lblPing.Text = "N/A" end
            end

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
local lastFullBagSellTime = 0
local lastSkillTime = 0
local lastBaitBuyTime = 0
local lastQuestTime = 0
local lastMonkeyTime = 0
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

-- FireGuiButton 已提升至上层作用域，供任务对话与小游戏共用

-- 零GC事件缓存：缓存 Boss/章鱼/Enzo ProximityPrompt + 缓存 Z/X/C/V 技能按钮 + 缓存 PlayerGui/PlayerData 引用
local cachedBossPrompts = {}
local cachedSkillButtons = {}
local lastSkillBtnScanTime = 0
local lastGuiDataCacheTime = 0
local cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar = nil, nil, nil, nil, nil
local lastFishRingPos = nil
local cachedMobileFishBtn = nil
local lastMobileFishBtnScan = 0
local lastQTEHitTime = 0

-- 查找手机端右侧【钓鱼】圆钮（仅在实际触发拔河 QTE 时使用 firesignal 安全调用，绝不发全局屏幕点击）
local function GetMobileFishingButton(now)
    if cachedMobileFishBtn and cachedMobileFishBtn.Parent and cachedMobileFishBtn.Visible then
        return cachedMobileFishBtn
    end
    if now - lastMobileFishBtnScan < 2.0 then return cachedMobileFishBtn end
    lastMobileFishBtnScan = now
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    for _, gName in ipairs({"MainGui", "Fisher_GUI"}) do
        local g = pg:FindFirstChild(gName)
        if g then
            for _, d in ipairs(g:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
                    local txt = ""
                    if d:IsA("TextButton") then
                        txt = (d.Text or ""):lower():match("^%s*(.-)%s*$")
                    else
                        local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                        if lbl then txt = (lbl.Text or ""):lower():match("^%s*(.-)%s*$") end
                    end
                    local dn = (d.Name or ""):lower()
                    if (txt == "钓鱼" or txt == "fish" or dn == "fishbutton" or dn == "fishingbutton")
                        and not txt:find("自动") and not txt:find("auto") and not dn:find("auto") then
                        cachedMobileFishBtn = d
                        return d
                    end
                end
            end
        end
    end
    return nil
end

-- 仅当用户显式开启 Config.AutoFarmBoss 时，自动在弹出的 Boss Fight 窗口中选择难度（简单/困难/噩梦）并点击 Fight
local function TrySelectAndStartEnzoModal(mainGui)
    if not Config.AutoFarmBoss or not mainGui then return false end
    for _, ch in ipairs(mainGui:GetChildren()) do
        if ch:IsA("GuiObject") and ch.Visible and ch.Name ~= "Fishing" then
            local fightBtn = nil
            local diffBtns = {}
            local okBtn = nil
            for _, d in ipairs(ch:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.Active then
                    local txt = ""
                    if d:IsA("TextButton") then
                        txt = (d.Text or ""):lower():match("^%s*(.-)%s*$")
                    else
                        local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                        if lbl then txt = (lbl.Text or ""):lower():match("^%s*(.-)%s*$") end
                    end
                    local dn = (d.Name or ""):lower()
                    if txt == "fight" or txt == "战斗" or txt == "挑战" or dn == "fight" or dn == "fightbutton" then
                        fightBtn = d
                    elseif txt == "normal" or txt == "普通" or txt == "简单" or txt == "正常" or dn == "normal" or dn == "easy" then
                        diffBtns["Easy"] = d
                    elseif txt == "hard" or txt == "困难" or dn == "hard" then
                        diffBtns["Hard"] = d
                    elseif txt == "nightmare" or txt == "噩梦" or txt == "梦魇" or dn == "nightmare" then
                        diffBtns["Nightmare"] = d
                    elseif txt == "好的" or txt == "ok" then
                        okBtn = d
                    end
                end
            end
            if fightBtn and (diffBtns["Easy"] or diffBtns["Hard"] or diffBtns["Nightmare"]) then
                EnsureFishingRodEquipped()
                local pref = tostring(Config.EnzoDifficulty or "简单")
                local targetDiffBtn = diffBtns["Easy"]
                if pref:find("噩梦") or pref:lower():find("nightmare") then
                    targetDiffBtn = diffBtns["Nightmare"] or targetDiffBtn
                elseif pref:find("困难") or pref:lower():find("hard") then
                    targetDiffBtn = diffBtns["Hard"] or targetDiffBtn
                end
                if targetDiffBtn then FireGuiButton(targetDiffBtn) end
                FireGuiButton(fightBtn)
                return true
            elseif okBtn then
                FireGuiButton(okBtn)
                return true
            else
                -- 检测结算掉落弹窗（如视频中的“点击以关闭”、“亲族杀戮钓鱼艺术”、“好的”），自动点击关闭，无缝进入下一轮挑战
                for _, sub in ipairs(ch:GetDescendants()) do
                    if (sub:IsA("TextButton") or sub:IsA("ImageButton")) and sub.Visible and sub.Active then
                        local st = (sub.Text or ""):lower()
                        if st:find("点击以关闭") or st:find("关闭") or st:find("close") or st:find("claim") or st:find("ok") or st:find("好的") then
                            FireGuiButton(sub)
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function RefreshGuiAndDataRefs(now)
    if now - lastGuiDataCacheTime < 0.4 and cachedPG and cachedPG.Parent then
        return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
    end
    lastGuiDataCacheTime = now
    cachedPData = GetPlayerData()
    cachedPG = LocalPlayer:FindFirstChild("PlayerGui")
    cachedMainGui = cachedPG and cachedPG:FindFirstChild("MainGui")
    cachedFUI = cachedMainGui and cachedMainGui:FindFirstChild("Fishing")
    cachedBossBar = cachedFUI and cachedFUI:FindFirstChild("BossFightBar")
    return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
end

local SKILL_KEYS = {"Z", "X", "C", "V"}
local function GetCachedSkillButton(sk, now)
    local btn = cachedSkillButtons[sk]
    if btn and btn.Parent and btn.Visible and btn.AbsoluteSize.X > 5 then
        return btn
    end
    if now - lastSkillBtnScanTime < 2.5 then return nil end
    lastSkillBtnScanTime = now
    table.clear(cachedSkillButtons)
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local searchRoots = {}
    if cachedFUI then table.insert(searchRoots, cachedFUI) end
    if cachedMainGui then table.insert(searchRoots, cachedMainGui) end
    if pg:FindFirstChild("Fisher_GUI") then table.insert(searchRoots, pg.Fisher_GUI) end
    for _, rootInst in ipairs(searchRoots) do
        for _, d in ipairs(rootInst:GetDescendants()) do
            if (d:IsA("GuiButton") or d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 5 then
                local name = (d.Name or ""):upper()
                local txt = ""
                if d:IsA("TextButton") then
                    txt = (d.Text or ""):upper()
                else
                    local tl = d:FindFirstChildOfClass("TextLabel")
                    if tl then txt = (tl.Text or ""):upper() end
                end
                for kIdx = 1, #SKILL_KEYS do
                    local key = SKILL_KEYS[kIdx]
                    if not cachedSkillButtons[key] and (name == key or name:find(key, 1, true) or txt == key or txt:find(key, 1, true)) then
                        cachedSkillButtons[key] = d
                    end
                end
            end
        end
    end
    return cachedSkillButtons[sk]
end

local function PruneAndTriggerBossPrompts()
    local i = 1
    while i <= #cachedBossPrompts do
        local pr = cachedBossPrompts[i]
        if not pr or not pr.Parent then
            table.remove(cachedBossPrompts, i)
        else
            if pr.Enabled then TriggerPrompt(pr) end
            i = i + 1
        end
    end
end

local function IsBossPromptCandidate(inst)
    if not inst or not inst:IsA("ProximityPrompt") then return false end
    local full = inst:GetFullName():lower()
    return (full:find("boss") or full:find("enzo") or full:find("octo") or full:find("parasite") or full:find("angler") or full:find("rhythm") or full:find("buoy")) ~= nil
end

pcall(function()
    table.insert(activeConnections, Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("ProximityPrompt") and IsBossPromptCandidate(d) then
            table.insert(cachedBossPrompts, d)
        end
    end))
    table.insert(activeConnections, Workspace.DescendantRemoving:Connect(function(d)
        if d:IsA("ProximityPrompt") then
            local idx = table.find(cachedBossPrompts, d)
            if idx then table.remove(cachedBossPrompts, idx) end
        end
    end))
    -- 异步分帧扫描现有 ProximityPrompt，避免启动瞬间全图 GetDescendants 造成卡顿
    task.spawn(function()
        pcall(function()
            local descendants = Workspace:GetDescendants()
            for i = 1, #descendants do
                if not isRunning then break end
                local d = descendants[i]
                if IsBossPromptCandidate(d) and not table.find(cachedBossPrompts, d) then
                    table.insert(cachedBossPrompts, d)
                end
                if i % 400 == 0 then task.wait() end
            end
        end)
    end)
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
        local pData, _, mainGui, fUI, bossBar = RefreshGuiAndDataRefs(now)

        if Config.WalkSpeedEnabled then
            RememberHumanoidState(hum)
            hum.WalkSpeed = Config.WalkSpeedValue
        end
        if Config.WalkOnWater then
            local targetPos = Vector3.new(root.Position.X, 0, root.Position.Z)
            if (waterPlatform.Position - targetPos).Magnitude > 1.5 then
                waterPlatform.CFrame = CFrame.new(targetPos)
            end
            local shouldCollide = (root.Position.Y >= -1)
            if waterPlatform.CanCollide ~= shouldCollide then waterPlatform.CanCollide = shouldCollide end
        elseif waterPlatform.CanCollide then
            waterPlatform.CanCollide = false
        end

        if Config.PositionLock and not isMicroTeleportingNPC then
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

        -- fUI 与 bossBar 已由 RefreshGuiAndDataRefs(now) 缓存提供
        local inUndergroundRealm = (root.Position.Y < -50)

        local isFishing = char:GetAttribute("Fishing") == true
        -- 核心小游戏判定：优先通过属性与UI检测，若UI有延迟则通过 cachedIsHooked 兜底，绝不漏放技能导致伤害不足被踢
        local isMinigame = char:GetAttribute("Minigame") == true
            or (fUI and fUI.Visible)
            or (bossBar and bossBar.Visible)
            or cachedIsHooked
        local isCD = char:GetAttribute("CDForTheNextThrow") == true
        local isSwimming = char:GetAttribute("Swimming") == true
        local useMinigameAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoEnzoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss

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

        local bossCheckInterval = Config.AutoFarmBoss and 1.5 or 2.5
        if (Config.AutoFarmBoss or Config.AutoFarmSecretBoss) and not isMinigame and not isFishing and not cachedIsHooked and (now - lastBossTime >= bossCheckInterval) then
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
                PruneAndTriggerBossPrompts()
            elseif Config.AutoFarmBoss then
                EnsureFishingRodEquipped()
                local enzoPos = Vector3.new(-115.3, 9.2, 1349.5)
                if (root.Position - enzoPos).Magnitude > 15 then
                    SafeTeleport(CFrame.new(enzoPos))
                end
                if not TrySelectAndStartEnzoModal(mainGui) then
                    PruneAndTriggerBossPrompts()
                    local bossSetup = Workspace:FindFirstChild("BossSetUp")
                    if bossSetup then
                        for _, ch in ipairs(bossSetup:GetChildren()) do
                            if ch:IsA("ProximityPrompt") then
                                TriggerPrompt(ch)
                            else
                                local pr = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                                if pr then TriggerPrompt(pr) end
                            end
                        end
                    end
                end
            end
        end

        if isMinigame then
            if fUI and fUI.Visible then
                -- Bar 与 BossFightBar 位置对齐已統一由 RenderStepped 在渲染前执行，消除每帧双写开销
                if (now - lastSlamChargeTime >= 0.08) then
                    local didFire = false
                    if Config.AutoSlam and fUI:FindFirstChild("PerfectButton") and fUI.PerfectButton.Visible then
                        FireGuiButton(fUI.PerfectButton)
                        if Events and Events:FindFirstChild("Slam") then Events.Slam:FireServer("Perfect") end
                        didFire = true
                    end
                    if Config.AutoCharge and fUI:FindFirstChild("Charge") and fUI.Charge.Visible then
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

            -- 严格区分普通钓鱼自动技能（AutoSkills）与 Boss 战自动技能（BossAutoSkills）
            -- 地下渔夫之地平时钓普通鱼不视为 Boss 战，仅在出现 Boss 血条或开启自动刷 Boss/隐藏 Boss 时视为 Boss 战
            local isBossEncounter = (bossBar ~= nil and bossBar.Visible) or Config.AutoFarmBoss or Config.AutoFarmSecretBoss or Config.AutoEnzoMinigame
            local shouldFireSkills = (isBossEncounter and Config.BossAutoSkills) or (not isBossEncounter and Config.AutoSkills)
            -- 严格按技能释放顺序轮换（从第1个勾选技能起手），多通道触发提高成功率
            if shouldFireSkills and (now - lastSkillTime >= (Config.SkillInterval or 1.5)) then
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

                    -- 通道1：优先单一有效 Remote 发送（避免同帧连发 4 次引发服务端 CD 校验异常）
                    pcall(function()
                        if Events then
                            local rem = Events:FindFirstChild("TriggerMinigameSkill") or Events:FindFirstChild("UseSkill")
                            if rem then rem:FireServer(sk) end
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

                    -- 通道3：使用 O(1) 缓存点击游戏内技能按钮（彻底消除每次放技能遍历整个 MainGui:GetDescendants 的卡顿）
                    pcall(function()
                        local btn = GetCachedSkillButton(sk, now)
                        if btn then FireGuiButton(btn) end
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
                    -- 达到 90% 容量提前触发自动出售（使用独立冷却计时器 lastFullBagSellTime，不与定时出售互相干扰）
                    if Config.AutoSell and maxLim > 0 and invCount >= math.floor(maxLim * 0.9) and (now - lastFullBagSellTime >= 5.0) then
                        SafeSellAllFish(pData)
                        lastFullBagSellTime = now
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
            for _, spKey in ipairs({"Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber"}) do
                local entry = liveNPCs[spKey]
                if entry and entry.inst and entry.inst.Parent then
                    TriggerNPCInstancePrompts(entry.inst)
                end
            end
            local npcFolder = Workspace:FindFirstChild("NPC") or Workspace:FindFirstChild("NPCs")
            if npcFolder then
                for _, ch in ipairs(npcFolder:GetChildren()) do
                    local cn = ch.Name:lower()
                    if cn == "spirit" or cn == "god" or cn:find("spirit") then
                        TriggerNPCInstancePrompts(ch)
                    end
                end
            end
        end

        if Config.AutoTicketQuest and not isMinigame and not isFishing and (now - lastQuestTime >= 8.0) then
            lastQuestTime = now
            if RunTicketQuestAction then
                local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
                RunTicketQuestAction(diffArg, false)
            end
        end

        if Config.AutoGiveMonkey and (now - lastMonkeyTime >= 4.0) then
            lastMonkeyTime = now
            if RunGiveFishToMonkeyBatch then RunGiveFishToMonkeyBatch() end
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

        if Config.AutoCraftBait and (now - lastCraftTime >= 10.0) then
            lastCraftTime = now
            if Events and Events:FindFirstChild("CraftBait") then
                Events.CraftBait:FireServer(Config.CraftBaitName, Config.CraftAmount)
            end
        end

        if Config.AutoBuyBait and (now - lastBaitBuyTime >= math.max(5, tonumber(Config.BuyBaitDelay) or 30)) then
            lastBaitBuyTime = now
            if pData and pData:FindFirstChild("Bait") and Events and Events:FindFirstChild("BuyBait") then
                local bFolder = pData.Bait:FindFirstChild(Config.BuyBaitName)
                local currentAmount = bFolder and bFolder.Value or 0
                if currentAmount < Config.BuyBaitThreshold then
                    Events.BuyBait:FireServer(Config.BuyBaitName, Config.BuyBaitAmount)
                end
            end
        end

        if (Config.OctoAutoMinigame or Config.AutoEnzoMinigame) and (now - lastRhythmTime >= 0.10) then
            lastRhythmTime = now
            local acc = tonumber(Config.RhythmAccuracy) or 100
            local hitPass = (acc >= 100) or (math.random(1, 100) <= acc)
            if hitPass and Events then
                local rhythmRemoteNames = {"RhythmHit", "Rhythm", "RhythmMinigame", "OctoMinigame", "OctoHit", "ParasiteMinigame", "QTE", "BossQTE", "BossMinigame", "MinigameHit"}
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
            -- 当 BossFightBar (恩佐/龙钓海判定条) 真实显示或处于 Boss 战期间时，安全触发钓鱼按钮信号与自动判定
            if hitPass and (bossBar and bossBar.Visible or isBossEncounter) and (now - lastQTEHitTime >= 0.14) then
                lastQTEHitTime = now
                local fishBtn = GetMobileFishingButton(now)
                if fishBtn and fishBtn.Visible then
                    FireGuiButton(fishBtn)
                end
                if bossBar and bossBar:IsA("GuiButton") then FireGuiButton(bossBar) end
            end
            if Config.OctoAutoMinigame and inUndergroundRealm then
                PruneAndTriggerBossPrompts()
            end
        end
    end)
end))

-- ==========================================
-- 纯净渲染循环 RenderStepped (极致低延迟)
-- ==========================================
local flyBV, flyBG = nil, nil
-- 手机端跳跃按钮是一次性 JumpRequest；用短时上升窗口交给飞行循环统一处理，
-- 避免 JumpRequest 写入的 Y 速度被下一帧 RenderStepped 覆盖。
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
            RememberHumanoidState(hum)
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

        -- 垂直控制：PC 空格/Shift；手机点击跳跃按钮触发短时上升脉冲。
        if UserInputService:IsKeyDown(Enum.KeyCode.ButtonA) then
            dir = dir + Vector3.new(0, 1, 0)
        end
        if os.clock() < flyAscendUntil then
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
        flyAscendUntil = 0
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
        if hum then
            local saved = originalHumanoidState[hum]
            hum.PlatformStand = saved and saved.PlatformStand or false
        end
    end

    pcall(function()
        local useAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoEnzoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss
        if useAssist then
            local _, pg, mainGui, fUI, bossBar = RefreshGuiAndDataRefs(tick())
            if fUI and fUI.Visible then
                if Config.AnchorBar then
                    local barFrame = fUI:FindFirstChild("BarFrame")
                    if barFrame and barFrame:FindFirstChild("Bar") then
                        barFrame.Bar.Position = UDim2.new(0.5, 0, 0.5, 0)
                    end
                end
                if (Config.AutoEnzoMinigame or Config.OctoAutoMinigame or Config.AnchorBar) and bossBar and bossBar.Visible then
                    local bBar = bossBar:FindFirstChild("Bar")
                    local bHit = bossBar:FindFirstChild("Hitbox") or bossBar:FindFirstChild("GreenZone") or bossBar:FindFirstChild("Target")
                    if bBar and bHit then
                        bBar.Position = bHit.Position
                        if bHit.Rotation and bBar.Rotation then
                            bBar.Rotation = bHit.Rotation
                        end
                    end
                end
                if Config.AnchorBar then
                    local hpPlayer = fUI:FindFirstChild("HPPlayer")
                    if hpPlayer and hpPlayer:FindFirstChild("ProgressionBar") and hpPlayer.ProgressionBar:FindFirstChild("Bar") then
                        hpPlayer.ProgressionBar.Bar.Size = UDim2.new(1, 0, 1, 0)
                    end
                end
                local cutscene = mainGui and mainGui:FindFirstChild("Cutscene")
                local hurt1 = cutscene and cutscene:FindFirstChild("Hurt")
                if hurt1 and (hurt1:IsA("ImageLabel") or hurt1:IsA("ImageButton") or hurt1.ImageTransparency ~= nil) then
                    pcall(function() hurt1.ImageTransparency = 1 end)
                end
                local impactGui = pg and pg:FindFirstChild("Impact")
                local impactCutscene = impactGui and impactGui:FindFirstChild("Cutscene")
                local hurt2 = impactCutscene and impactCutscene:FindFirstChild("Hurt")
                if hurt2 and (hurt2:IsA("ImageLabel") or hurt2:IsA("ImageButton") or hurt2.ImageTransparency ~= nil) then
                    pcall(function() hurt2.ImageTransparency = 1 end)
                end
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
                local needUpdate = (not lastFishRingPos)
                    or (not fishRingAdornment.Visible)
                    or ((fishPos - lastFishRingPos).Magnitude > 0.08)
                if needUpdate then
                    fishRingAnchor.Position = fishPos
                    lastFishRingPos = fishPos
                    fishRingAdornment.Visible = true
                end
            else
                if fishRingAdornment.Visible then
                    fishRingAdornment.Visible = false
                    lastFishRingPos = nil
                end
            end
        else
            if fishRingAdornment.Visible then
                fishRingAdornment.Visible = false
                lastFishRingPos = nil
            end
        end
    end)
end))

local function ConnectDynamicMinigameRemote(rem)
    if not rem or not rem:IsA("RemoteEvent") then return end
    local rName = rem.Name
    if rName == "Slam" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(slamEvent)
            if isRunning and Config.AutoSlam then
                if typeof(slamEvent) == "Instance" and slamEvent:IsA("RemoteEvent") then
                    pcall(function() slamEvent:FireServer("Perfect") end)
                else
                    pcall(function() rem:FireServer("Perfect") end)
                end
            end
        end))
    elseif rName == "Charge" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(chargeEvent)
            if isRunning and Config.AutoCharge then
                if typeof(chargeEvent) == "Instance" and chargeEvent:IsA("RemoteEvent") then
                    pcall(function() chargeEvent:FireServer(100) end)
                else
                    pcall(function() rem:FireServer(100) end)
                end
            end
        end))
    elseif rName:find("Rhythm") or rName:find("Octo") or rName:find("QTE") or rName:find("Boss") then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(dynArg, ...)
            if isRunning and (Config.OctoAutoMinigame or Config.AutoEnzoMinigame or Config.AnchorBar) then
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
        -- JumpRequest 只记录上升意图；由 RenderStepped 统一写入速度，避免被覆盖。
        flyAscendUntil = os.clock() + 0.35
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
    elseif input.KeyCode == Enum.KeyCode.Escape and mainFrame and mainFrame.Visible then
        CloseUI()
    elseif input.KeyCode == Enum.KeyCode.End or input.KeyCode == Config.StopKeybind then
        UnloadScript()
    end
end))

ShowNotification("🌙 IDENTICAL V1.6", "脚本已加载完成！控制台已就绪，点击 [-] 可收起为悬浮小月亮", "SUCCESS", 4.5)
