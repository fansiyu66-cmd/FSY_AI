-- ============================================================================
-- 【模块 01：执行器环境初始化与Roblox核心服务引用】
-- 作用说明：
--   1. 安全获取执行器全局环境 (getgenv)，并在重复注入时自动调用上一次的卸载函数清理旧实例；
--   2. 集中获取 Players / Workspace / ReplicatedStorage / RunService 等核心服务。
-- 后续修改指引：
--   - 若需引入新的 Roblox 服务（如 MarketplaceService），请在此模块顶部统一 GetService。
-- ============================================================================
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

-- ============================================================================
-- 【模块 02：原始画质/雾效/游戏原生UI状态备份与还原】
-- 作用说明：
--   1. 备份启动前的 Lighting 光照、Atmosphere 大气雾效、相机粒子及原生 ScreenGui 显隐状态；
--   2. 提供 RestoreNoFogChanges() 与 SetGameUIHidden()，在关闭视觉功能或卸载脚本时精确恢复原状。
-- 后续修改指引：
--   - 若游戏新增了原生 HUD 界面名称，可在 SetGameUIHidden 的 {"MainGui", "Fisher_GUI"} 列表中追加。
-- ============================================================================
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
-- 备份单个 Atmosphere 大气实例的初始参数（仅首次修改前记录）
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
-- 还原「无雾无雨」修改过的雾距、Atmosphere 大气参数及相机粒子特效
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
-- 切换游戏原生 HUD（MainGui / Fisher_GUI）显隐状态，并在关闭隐藏时恢复原值
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

-- ============================================================================
-- 【模块 03：全局生命周期控制、按需拖拽连接池与视口防抖缩放监听】
-- 作用说明：
--   1. 维护脚本运行标志位 isRunning、全局常驻事件表 activeConnections、临时拖拽连接池 activeDragConns；
--   2. 监听屏幕旋转或窗口大小变化 (ViewportSize)，通过 task.defer 合并同一帧内的缩放重算请求。
-- 后续修改指引：
--   - 凡是新增的全局常驻事件连接，请 table.insert 到 activeConnections；拖拽类临时连接请用 RegisterTempDragConn。
-- ============================================================================
local isRunning = true
local activeConnections = {}
-- [性能优化 #1 / 建议 #6,#20] 动态拖拽连接池与呼吸灯协程句柄：仅在拖拽进行中挂载 UIS 连接，松手立即断开，Unload 时兜底清理
local activeDragConns = {}
local fcBreathThread = nil
-- 注册按需创建的临时拖拽事件连接，便于松手或卸载时统一清理
local function RegisterTempDragConn(conn)
    if conn then activeDragConns[conn] = true end
    return conn
end
-- 立即断开并从连接池移除指定的临时拖拽连接
local function DisconnectTempDragConn(conn)
    if conn then
        activeDragConns[conn] = nil
        pcall(function() conn:Disconnect() end)
    end
    return nil
end
local attrCharConn = nil -- 角色 AttributeChanged 连接；重生时替换，Unload 时单独断开
local cameraViewportConn = nil
local UpdateMainFrameScale, BindCameraViewportSignal
do
    -- [性能优化 #2 / 建议 #9] 合并同一帧内多次 ViewportSize / CurrentCamera 变化触发的缩放计算，避免拖拽窗口或旋转屏幕时连续重排抖动
    local scaleUpdateQueued = false
    local function RequestMainFrameScaleUpdate()
        if scaleUpdateQueued or not isRunning then return end
        scaleUpdateQueued = true
        task.defer(function()
            scaleUpdateQueued = false
            if isRunning and UpdateMainFrameScale then
                UpdateMainFrameScale()
            end
        end)
    end
    -- 绑定当前相机 ViewportSize 变化信号，窗口尺寸或横竖屏变化时自适应重算缩放
    BindCameraViewportSignal = function(cam)
        if cameraViewportConn then
            pcall(function() cameraViewportConn:Disconnect() end)
            cameraViewportConn = nil
        end
        if cam then
            cameraViewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(RequestMainFrameScaleUpdate)
        end
    end
    table.insert(activeConnections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        Camera = Workspace.CurrentCamera
        BindCameraViewportSignal(Camera)
        RequestMainFrameScaleUpdate()
    end))
end
local cleanUpInstances = {}
local UIControls = {}
local currentSkillIndex = 1
local lockedCFrame = nil
local flyAscendUntil = 0
local currentlyOpenDropdown = nil

-- ============================================================================
-- 【模块 04：玩家数据节点动态探测与角色碰撞/物理缓存】
-- 作用说明：
--   1. GetPlayerData() 自动在 ReplicatedStorage 下探测并缓存当前玩家的 Data 节点（含鱼竿/鱼饵/背包/金币等）；
--   2. 维护角色肢体碰撞表 originalCanCollide 与 Humanoid 原始移速/状态备份表，供穿墙与飞行功能安全读写。
-- 后续修改指引：
--   - 若游戏更新改名了数据文件夹（非 Data/PlayerData/PlayersData），在 GetPlayerData 的列表中添加新名字即可。
-- ============================================================================
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
-- 备份角色 Humanoid 原始移速与 PlatformStand 状态，供关闭加速/飞行或卸载时还原
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

-- ============================================================================
-- 【模块 05：全局功能默认配置表 (Config) 与中英映射字典】
-- 作用说明：
--   1. 集中定义所有功能的默认开关、延迟参数、保护鱼名单、快捷键等配置项；
--   2. 提供任务难度 (QuestDiffMap) 与扭蛋卡池 (GachaBannerMap) 的中英文参数映射。
-- 后续修改指引：
--   - 修改任意功能的默认初始状态、默认保护鱼或默认快捷键，直接修改下方 Config 对应字段即可。
-- ============================================================================
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
    AutoProtectRareBossFish = false,
    FavouriteFishName = "Wraith Orca",
    CustomProtectedFish = "",
    FavPacketMode = "实例对象(item)",
    MaterialFarming = false,

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
    AutoGacha = false,
    GachaBanner = "太极卡池",
    GachaPullsPerAction = 1,

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

local GachaBannerMap = {
    ["太极卡池"] = "Taiji Banner",
    ["无我卡池"] = "Selflessness Banner",
    ["Taiji Banner"] = "Taiji Banner",
    ["Selflessness Banner"] = "Selflessness Banner"
}

-- ============================================================================
-- 【模块 06：执行器能力探测 (Capabilities) 与 __namecall 远程事件拦截 Hook】
-- 作用说明：
--   1. 自动检测当前执行器是否支持文件读写、剪贴板、fireproximityprompt、firesignal 及 hookmetamethod；
--   2. 若支持 Hook，拦截 FireServer 实现：小游戏 "Out of bar" 自动改判 "In bar"、猛击/节奏自动 "Perfect"、
--      蓄力自动 100，以及发包级防误卖拦截（命中保护鱼或包内有保护鱼时禁止 SellAll）。
-- 后续修改指引：
--   - 若游戏新增了小游戏或卖鱼远程事件名称，可在 __namecall 分支的 rName 判断中补充。
-- ============================================================================
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

        local function getInstanceName(inst)
            return inst.Name
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
                        local assistActive = cfg.AnchorBar or cfg.OctoAutoMinigame or cfg.AutoEnzoMinigame or cfg.AutoFarmSecretBoss or cfg.AutoFarmBoss
                        local okName, rName = pcall(getInstanceName, self)
                        if okName and type(rName) == "string" then
                            if rName == "FishingMinigame" and assistActive then
                                local args = {...}
                                local action = tostring(args[1])
                                if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar", 1, true) or action:find("Fail", 1, true) or action:find("Miss", 1, true) then
                                    return orig(self, "In bar", unpack(args, 2))
                                end
                            elseif rName == "Slam" and cfg.AutoSlam then
                                local args = {...}
                                local firstArg = args[1]
                                local firstStr = firstArg ~= nil and tostring(firstArg):lower() or ""
                                if firstArg == nil or firstArg == false or firstStr:find("miss", 1, true) or firstStr:find("fail", 1, true) or firstStr:find("bad", 1, true) then
                                    return orig(self, "Perfect")
                                end
                            elseif (rName:find("Rhythm", 1, true) or rName:find("QTE", 1, true) or rName:find("Octo", 1, true)) and (cfg.OctoAutoMinigame or cfg.AutoEnzoMinigame or cfg.AutoSlam) then
                                local args = {...}
                                local firstArg = args[1]
                                local firstStr = firstArg ~= nil and tostring(firstArg):lower() or ""
                                if firstArg == nil or firstArg == false or firstStr:find("miss", 1, true) or firstStr:find("fail", 1, true) or firstStr:find("bad", 1, true) then
                                    args[1] = (type(firstArg) == "boolean") and true or "Perfect"
                                    if args[2] == nil or type(args[2]) == "number" then args[2] = 100 end
                                    return orig(self, unpack(args))
                                end

                            elseif rName == "Charge" and cfg.AutoCharge then
                                local args = {...}
                                if args[1] == nil or (type(args[1]) == "number" and args[1] < 100) then
                                    return orig(self, 100)
                                end
                            elseif (rName == "SellFish" or rName == "SellItem" or rName == "SellAll") and sharedEnv and type(sharedEnv.IdenticalIsSellArgBlocked) == "function" then
                                -- 发包级卖鱼拦截：遍历全部参数（或 SellAll 无参），命中保护鱼/已锁鱼时直接拦截丢弃
                                local args = {...}
                                if rName == "SellAll" or #args == 0 then
                                    local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, "All")
                                    if okCheck and isBlocked then return nil end
                                else
                                    for aIdx = 1, #args do
                                        local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, args[aIdx])
                                        if okCheck and isBlocked then return nil end
                                    end
                                end
                            elseif (rName == "FavoriteItem" or rName == "FavouriteItem" or rName == "FavoriteFish" or rName == "FavouriteFish"
                                or rName == "LockFish" or rName == "LockItem" or rName == "Lock" or rName == "Favorite" or rName == "Favourite") then
                                local args = {...}
                                if sharedEnv then
                                    sharedEnv.IdenticalLearnedFavRemote = self
                                    if typeof(args[1]) == "Instance" then
                                        sharedEnv.IdenticalLearnedFavFormat = "instance"
                                    elseif type(args[1]) == "string" and type(args[2]) == "string" then
                                        sharedEnv.IdenticalLearnedFavFormat = "action_name"
                                    elseif type(args[1]) == "string" then
                                        sharedEnv.IdenticalLearnedFavFormat = "name"
                                    end
                                end
                                if sharedEnv and type(sharedEnv.IdenticalIsFavToggleBlocked) == "function" then
                                    local okFav, blockFav = pcall(sharedEnv.IdenticalIsFavToggleBlocked, args[1], args[2])
                                    if okFav and blockFav then
                                        return nil
                                    end
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

-- ============================================================================
-- 【模块 07：本地配置文件 (Profile) 与自定义传送点 JSON 持久化】
-- 作用说明：
--   1. 将 Config 配置与自定义传送点保存至本地工作区 Identical/HeavyweightFishing 目录；
--   2. 加载旧配置时通过 ConfigNumericBounds 执行数值范围钳制，防止异常数值导致逻辑出错。
-- 后续修改指引：
--   - 若新增了滑块配置项，建议在 ConfigNumericBounds 中同步添加 {最小值, 最大值} 校验范围。
-- ============================================================================
local SaveProfile, SyncUIWithConfig, LoadProfile, LoadCustomTPs, SaveCustomTPs
local CustomTPs = {}
local blackOutFrame, mainFrameScale, ApplyLightingSettings
do
local PROFILE_DIR = "Identical/HeavyweightFishing"

-- 确保本地配置目录 Identical/HeavyweightFishing 存在
local function EnsureProfileDir()
    if makefolder then
        pcall(function()
            if not isfolder("Identical") then makefolder("Identical") end
            if not isfolder(PROFILE_DIR) then makefolder(PROFILE_DIR) end
        end)
    end
end

-- 过滤配置文件名中的非法路径字符并限制最大长度
local function NormalizeProfileName(name)
    if type(name) ~= "string" then name = "default" end
    name = name:match("^%s*(.-)%s*$") or ""
    name = name:gsub("[/\\:%*?\"<>|%.%c]", "")
    if name == "" then name = "default" end
    return name:sub(1, 32)
end

-- 获取指定配置文件的完整 JSON 存储路径
local function GetProfilePath(name)
    return PROFILE_DIR .. "/" .. NormalizeProfileName(name or Config.ActiveProfile) .. ".json"
end

-- 对旧配置执行边界校验：类型正确不代表数值一定合理。
local ConfigNumericBounds = {
    UIScale = {0.5, 1.2}, CastDelay = {0.1, 10}, CastPower = {0, 100},
    SkillInterval = {0.5, 5}, SellInterval = {10, 3600}, DailyClaimDelay = {0.3, 2},
    CraftAmount = {1, 10}, BuyBaitAmount = {1, 50}, BuyBaitThreshold = {5, 50},
    BuyBaitDelay = {5, 3600}, GachaPullsPerAction = {1, 10},
    WalkSpeedValue = {16, 120}, FlySpeed = {20, 150},
    MonkeyGiveCount = {10, 500},
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

-- 将当前 Config 表序列化为 JSON 并写入本地配置文件（兼容 EnumItem 转换）
SaveProfile = function(name)
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

-- 将 Config 内存配置同步到所有已注册的 UI 控件及视觉/渲染开关（静默模式不触发额外副作用）
SyncUIWithConfig = function()
    for key, ctrl in pairs(UIControls) do
        if Config[key] ~= nil and ctrl and ctrl.Set then
            -- 传入 silent=true 仅同步UI视觉状态，避免启动时触发 false 分支副作用弄乱游戏界面
            pcall(ctrl.Set, Config[key], true)
        end
    end
    if UpdateMainFrameScale then
        pcall(UpdateMainFrameScale, true)
    elseif mainFrameScale and mainFrameScale.Parent then
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

-- 从本地 JSON 文件读取配置并执行类型与数值范围校验后同步至 UI
LoadProfile = function(name)
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
                if Config.FavPacketMode == "完整鱼名(item.Name)" or not Config.FavPacketMode or Config.FavPacketMode == "" then
                    Config.FavPacketMode = "实例对象(item)"
                end
                if Config.AutoFarmBoss and Config.AutoFarmSecretBoss then
                    Config.AutoFarmBoss = false
                end
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

-- 从本地 CustomTPs.json 加载用户保存的自定义传送坐标列表
LoadCustomTPs = function()
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

-- 将当前自定义传送点列表持久化保存到本地 CustomTPs.json
SaveCustomTPs = function()
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
end -- end of Module 07 Profile & CustomTP Scope

-- ============================================================================
-- 【模块 08：UI 主题配色方案 (Colors)、ScreenGui 挂载与省电黑屏遮罩】
-- 作用说明：
--   1. 统一定义暗夜紫主题色板 Colors；
--   2. 优先使用 gethui / CoreGui 安全挂载主界面 ScreenGui，并创建“关闭3D渲染”时使用的全屏省电遮罩 blackOutFrame。
-- 后续修改指引：
--   - 想要更换脚本整体界面主题色（如改为蓝黑/翠绿风格），只需调整 Colors 表中的 RGB 值。
-- ============================================================================
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

-- 按优先级（gethui -> CoreGui -> PlayerGui）安全获取 UI 挂载父容器
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

-- ============================================================================
-- 【模块 09：运行时状态表、10大特殊NPC雷达字典 (liveNPCs) 与安全卸载函数 (UnloadScript)】
-- 作用说明：
--   1. 预声明鱼名匹配缓存、上锁状态缓存、全图特殊 NPC 字典 liveNPCs（三岛神灵 + 道士/茅山/傻子商人 + 四圣兽）；
--   2. UnloadScript() 负责一键断开所有事件连接、取消协程、销毁 UI 与 ESP 实例，并恢复画质、碰撞与角色状态。
-- 后续修改指引：
--   - 若需在“传送 -> 特殊NPC实时检测”中新增监控目标，可在 liveNPCOrder 与 liveNPCs 中添加配置项。
-- ============================================================================
-- 预声明需要在卸载时重置的缓存与状态变量
local patternCache = {}
local patternCacheCount = 0
local cachedRuleMatchers = {}
local cachedRuleSource = nil
-- 收藏与安全卖鱼状态表（弱键表自动随实例销毁回收，防止内存泄漏与 Toggle 翻转）
local knownLockedUntil = setmetatable({}, { __mode = "k" })   -- 已确认上锁实例的冷却时间戳
local watchedBagFolders = setmetatable({}, { __mode = "k" })  -- 已挂载 ChildAdded 自动收藏监听的背包容器集合
local isSellingInProgress = false                             -- 卖鱼协程互斥锁，防止并发重入
local singleSellFormat = nil                                  -- 记忆已验证成功的单条卖鱼参数格式 ("instance" / "name")
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
        -- 保持 IdenticalHookInstalled = true，由 __namecall 内部检测 IdenticalFishingRunning == false 自动直通原函数，
        -- 避免对 DataModel(game) 错误调用 restorefunction 导致移动端执行器崩溃或二次注入套娃 Hook
        sharedEnv.IdenticalFishingRunning = false
        sharedEnv.IdenticalHeavyweightFishingUnload = nil
        sharedEnv.IdenticalFishingConfig = nil
    end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    pcall(function() RunService:UnbindFromRenderStep("IdenticalForceFishBtnVisible") end)
    if attrCharConn then
        pcall(function() attrCharConn:Disconnect() end)
        attrCharConn = nil
    end
    -- [性能优化 #1 清理兜底] 取消悬浮球呼吸协程并断开所有未释放的临时拖拽连接
    if fcBreathThread then
        pcall(task.cancel, fcBreathThread)
        fcBreathThread = nil
    end
    for conn in pairs(activeDragConns) do pcall(function() conn:Disconnect() end) end
    table.clear(activeDragConns)
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
    pcall(function() local leftover2 = Workspace:FindFirstChild("IdenticalESPAnchors"); if leftover2 then leftover2:Destroy() end end)
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
    table.clear(knownLockedUntil)
    table.clear(watchedBagFolders)
    table.clear(activePromptTasks)
    if DismissStuckPromptsAndRestore then pcall(DismissStuckPromptsAndRestore, false) end
    table.clear(OnlineNPCs)
    isMicroTeleportingNPC = false
    isSellingInProgress = false
    singleSellFormat = nil
    isClaimingDailyTask = false
    isClaimingDailySign = false
    if sharedEnv then
        sharedEnv.IdenticalIsSellArgBlocked = nil
        sharedEnv.IdenticalIsFavToggleBlocked = nil
        sharedEnv.IdenticalKeepFishBtnVisible = false
        sharedEnv.IdenticalProtectedFishBtn = nil
        sharedEnv.IdenticalProtectedFishContainer = nil
    end
    cachedFishConstraint = nil
    lockedCFrame = nil
    noclipWasActive = false
    return true
end

if sharedEnv then sharedEnv.IdenticalHeavyweightFishingUnload = UnloadScript end

-- ============================================================================
-- 【模块 10：右上角防刷屏通知弹窗系统 (ShowNotification) 与跨服跳转 (ServerHop)】
-- 作用说明：
--   1. ShowNotification() 提供带 1.2s 同文去重、最多 4 张卡片队列、支持手指轻触即关的滑入式通知卡片；
--   2. ServerHop() 请求 Roblox 公开服务器列表 API，挑选未满员的不同实例执行跨服跳转（失败时自动回退随机重连）。
-- 后续修改指引：
--   - 调整 MAX_NOTIF_CARDS 可改变同时显示的最大通知数量；调整 ServerHop 的 85.0 秒冷却可改变自动跳服间隔。
-- ============================================================================
local notifContainer = Instance.new("Frame"); notifContainer.Name = "Notifications"; notifContainer.Size = UDim2.new(0, 300, 1, -40); notifContainer.Position = UDim2.new(1, -315, 0, 20); notifContainer.BackgroundTransparency = 1; notifContainer.ZIndex = 1000; notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)
local ShowNotification, ServerHop
do
local notifLayout = Instance.new("UIListLayout"); notifLayout.SortOrder = Enum.SortOrder.LayoutOrder; notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom; notifLayout.Padding = UDim.new(0, 8); notifLayout.Parent = notifContainer

local activeNotifCards = {}
local recentNotifMap = {}
local MAX_NOTIF_CARDS = 4

-- 右上角通知卡片弹窗（带 1.2s 同文去重、最多 4 张队列限制及点击即关交互）
ShowNotification = function(title, text, notifType, duration)
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
local lastLocalHopTime = 0
-- 兼容多种执行器 HTTP 接口发起 GET 请求并返回响应文本
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

-- 搜索人数未满的非当前服务器实例并执行跨服传送（带 85 秒自动跳服冷却与随机重连兜底）
ServerHop = function(manualClick)
    if isHopping then return end
    local now = tick()
    local prevHopTime = math.max(lastLocalHopTime, (sharedEnv and type(sharedEnv.IdenticalLastHopTime) == "number") and sharedEnv.IdenticalLastHopTime or 0)
    if not manualClick and prevHopTime > 0 and (now - prevHopTime < 85.0) then
        return
    end
    isHopping = true
    lastLocalHopTime = now
    if sharedEnv then sharedEnv.IdenticalLastHopTime = now end
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
end -- end of Module 10 Notification & ServerHop Scope

-- ============================================================================
-- 【模块 11：悬浮小月亮按钮 (FloatingCrescent) 与主窗口自适应缩放容器 (MainFrame)】
-- 作用说明：
--   1. 构建最小化后的悬浮小月亮图标，采用按需挂载 UIS 连接实现零平时开销拖拽，并在主界面打开时自动休眠呼吸灯协程；
--   2. 构建 700x480 主窗口容器与自适应 UIScale，确保在手机小屏与 PC 大屏下均完整显示不越界。
-- 后续修改指引：
--   - 若需修改悬浮球初始位置或尺寸，可调整 floatingCrescent.Position / Size。
-- ============================================================================
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
    local fcDragChangedConn = nil
    local fcDragEndedConn = nil

    -- 获取当前屏幕可视区域像素尺寸，用于悬浮球与主窗口拖拽边界钳制
    local function getScreenBoundsSize()
        if screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize.Y > 0 then
            return screenGui.AbsoluteSize
        end
        local cam = Workspace.CurrentCamera or Camera
        return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    end

    -- 根据鼠标/触控位移实时更新悬浮小月亮位置并限制在屏幕范围内
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

    -- [性能优化 #1] 悬浮球拖拽仅在按下期间连接全局 UIS，结束拖拽立即断开，平时零 UIS 回调开销
    local function stopCrescentDrag()
        fcDragging = false
        fcActiveTouch = nil
        fcInputEndConn = DisconnectTempDragConn(fcInputEndConn)
        fcDragChangedConn = DisconnectTempDragConn(fcDragChangedConn)
        fcDragEndedConn = DisconnectTempDragConn(fcDragEndedConn)
    end

    floatingCrescent.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            stopCrescentDrag()
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
            fcInputEndConn = RegisterTempDragConn(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                    stopCrescentDrag()
                elseif fcDragging and (input == fcActiveTouch or input.UserInputType == Enum.UserInputType.Touch) then
                    updateCrescentPosition(input.Position)
                end
            end))
            fcDragChangedConn = RegisterTempDragConn(UserInputService.InputChanged:Connect(function(changedInput)
                if not fcDragging then return end
                if fcActiveTouch then
                    if changedInput == fcActiveTouch or changedInput.UserInputType == Enum.UserInputType.Touch then
                        updateCrescentPosition(changedInput.Position)
                    end
                elseif changedInput.UserInputType == Enum.UserInputType.MouseMovement then
                    updateCrescentPosition(changedInput.Position)
                end
            end))
            fcDragEndedConn = RegisterTempDragConn(UserInputService.InputEnded:Connect(function(endedInput)
                if not fcDragging then return end
                if (fcActiveTouch and endedInput == fcActiveTouch) or (not fcActiveTouch and endedInput.UserInputType == Enum.UserInputType.MouseButton1) then
                    stopCrescentDrag()
                end
            end))
        end
    end)

    -- [性能优化 #3] 预创建并复用悬浮球悬停与呼吸脉冲 Tween，避免每次悬停/每 1.4s 重复创建 Tween 实例
    local fcHoverInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local fcEnterBgTw = TweenService:Create(floatingCrescent, fcHoverInfo, {BackgroundColor3 = Colors.RowHover})
    local fcEnterStrokeTw = TweenService:Create(fcStroke, fcHoverInfo, {Color = Colors.PurpleGlow, Transparency = 0})
    local fcLeaveBgTw = TweenService:Create(floatingCrescent, fcHoverInfo, {BackgroundColor3 = Colors.Background})
    local fcLeaveStrokeTw = TweenService:Create(fcStroke, fcHoverInfo, {Color = Colors.PurpleAccent, Transparency = 0.2})

    floatingCrescent.MouseEnter:Connect(function()
        fcEnterBgTw:Play()
        fcEnterStrokeTw:Play()
        if fcCutoutRef then fcCutoutRef.BackgroundColor3 = Colors.RowHover end
    end)

    floatingCrescent.MouseLeave:Connect(function()
        fcLeaveBgTw:Play()
        fcLeaveStrokeTw:Play()
        if fcCutoutRef then fcCutoutRef.BackgroundColor3 = Colors.Background end
    end)

    local lastToggleClick = 0
    -- 悬浮小月亮点击回调（排除拖拽移动误触与 0.25s 连点抖动后切换主窗口显隐）
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

    -- [性能优化 #3 & Bug修复 / 建议 #1]
    -- 1) 主面板打开、悬浮球隐藏期间通过 GetPropertyChangedSignal("Visible"):Wait() 完全休眠，消除每 0.5s 空转唤醒；
    -- 2) 修复原代码第 1054 行 `if not floatingCrescent.Visible then break end` 导致半途打开主面板后呼吸灯协程永久退出的 Bug。
    local fcPulseInfo = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    local fcPulseInTw = TweenService:Create(fcStroke, fcPulseInfo, {Transparency = 0.08, Color = Colors.PurpleGlow})
    local fcPulseOutTw = TweenService:Create(fcStroke, fcPulseInfo, {Transparency = 0.55, Color = Colors.PurpleAccent})
    local fcVisibleSignal = floatingCrescent:GetPropertyChangedSignal("Visible")
    fcBreathThread = task.spawn(function()
        while isRunning and floatingCrescent and floatingCrescent.Parent do
            if not floatingCrescent.Visible or (mainFrame and mainFrame.Visible) then
                pcall(function() fcPulseInTw:Cancel(); fcPulseOutTw:Cancel() end)
                fcVisibleSignal:Wait()
                if not isRunning or not floatingCrescent or not floatingCrescent.Parent then break end
            end
            if floatingCrescent.Visible and not (mainFrame and mainFrame.Visible) then
                pcall(function() fcPulseInTw:Play() end)
                task.wait(1.4)
                if not isRunning or not floatingCrescent or not floatingCrescent.Parent then break end
                if not floatingCrescent.Visible or (mainFrame and mainFrame.Visible) then
                    pcall(function() fcPulseInTw:Cancel() end)
                else
                    pcall(function() fcPulseOutTw:Play() end)
                    task.wait(1.4)
                end
            else
                task.wait(0.25)
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

-- [性能优化 #2 / 建议 #9] 缓存上次计算的视口尺寸与缩放值，未发生变化时跳过 UIScale 与通知容器重设
do
    local lastScaledViewport = nil
    local lastScaledConfigVal = nil
    local lastComputedTargetScale = nil
    UpdateMainFrameScale = function(forceApply)
        if not mainFrame or not mainFrame.Parent then return end
        local cam = Workspace.CurrentCamera or Camera
        local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
        if vp.X <= 0 or vp.Y <= 0 then return end
        local cfgScale = Config.UIScale or 0.75
        if not forceApply and lastScaledViewport == vp and lastScaledConfigVal == cfgScale then
            if mainFrameScale and mainFrameScale.Parent and lastComputedTargetScale and mainFrameScale.Scale ~= lastComputedTargetScale then
                mainFrameScale.Scale = lastComputedTargetScale
            end
            return
        end
        lastScaledViewport = vp
        lastScaledConfigVal = cfgScale

        local maxScaleX = (vp.X - 30) / 700
        local maxScaleY = (vp.Y - 24) / 480
        local autoMaxScale = math.clamp(math.min(maxScaleX, maxScaleY), 0.45, 1.2)
        local targetScale = math.min(cfgScale, autoMaxScale)
        lastComputedTargetScale = targetScale

        if mainFrameScale and mainFrameScale.Parent and mainFrameScale.Scale ~= targetScale then
            mainFrameScale.Scale = targetScale
        end

        if notifContainer and notifContainer.Parent then
            local nw = math.clamp(vp.X * 0.45, 180, 280)
            notifContainer.Size = UDim2.new(0, nw, 1, -40)
            notifContainer.Position = UDim2.new(1, -(nw + 15), 0, 20)
        end
    end
end
UpdateMainFrameScale()
BindCameraViewportSignal(Camera)

do local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame; local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame end

local rowSearchIndex = {}
local navList, tabCanvasRefreshers, currentActiveTab, SwitchTab, CreateTab, CloseUI
-- ============================================================================
-- 【模块 12：主窗口框架构建（标题栏拖拽、搜索防抖过滤、移动端防弹回滚动与标签页路由）】
-- 作用说明：
--   1. 构建顶部标题栏（含最小化 [-] 与带二次确认弹窗的关闭 [X] 按钮）、左侧导航栏、搜索框与底部状态栏；
--   2. BindVerticalCanvas() 通过真实可见子项高度累加计算 CanvasSize，解决手机端 AutomaticSize 滑不到底或回弹问题；
--   3. CreateTab() 与 SwitchTab() 负责标签页切换与按需刷新当前可见页滚动高度。
-- 后续修改指引：
--   - 如需调整窗口标题文字或版本号，修改此模块内的 brandTitle.Text 与 gameSubtitle.Text。
-- ============================================================================
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

-- 右上角窗口控制：加大按钮 + 拉开间距，降低手机/平板误触 [X] 的概率
local winControls = Instance.new("Frame"); winControls.Size = UDim2.new(0, 84, 1, 0); winControls.Position = UDim2.new(1, -90, 0, 0); winControls.BackgroundTransparency = 1; winControls.Parent = titleBar
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 30, 0, 30); minBtn.Position = UDim2.new(0, 4, 0.5, -15); minBtn.BackgroundColor3 = Colors.ControlBg; minBtn.Font = Enum.Font.GothamBold; minBtn.Text = "[-]"; minBtn.TextColor3 = Colors.PurplePrimary; minBtn.TextSize = 13; minBtn.BorderSizePixel = 0; minBtn.AutoButtonColor = true; minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)
local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 30, 0, 30); closeBtn.Position = UDim2.new(0, 50, 0.5, -15); closeBtn.BackgroundColor3 = Colors.ControlBg; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Text = "[X]"; closeBtn.TextColor3 = Colors.AccentRed; closeBtn.TextSize = 13; closeBtn.BorderSizePixel = 0; closeBtn.AutoButtonColor = true; closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

do
    local dragging = false
    local activeDragTouch = nil
    local dragStart = nil
    local startPos = nil
    local titleInputEndConn = nil

    -- 根据标题栏拖拽位移更新主窗口位置并保留边缘可见区域防拖出屏幕
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
        -- mainFrame 使用中心锚点 AnchorPoint = (0.5, 0.5)，按半宽/半高限位防止标题栏被拖出屏幕左/上边界无法拖回
        local halfW = frameW * 0.5
        local halfH = frameH * 0.5
        local minX = math.min(60 - halfW, vp.X * 0.5)
        local maxX = math.max(vp.X - 60 + halfW, vp.X * 0.5)
        local minY = math.min(halfH, vp.Y * 0.5)
        local maxY = math.max(vp.Y - 38 + halfH, vp.Y * 0.5)
        absX = math.clamp(absX, minX, maxX)
        absY = math.clamp(absY, minY, maxY)
        mainFrame.Position = UDim2.fromOffset(absX, absY)
    end

    -- [性能优化 #1] 主窗口标题栏拖拽仅在按下期间连接全局 UIS，松手立即断开
    local titleDragChangedConn = nil
    local titleDragEndedConn = nil
    local function stopTitleDrag()
        dragging = false
        activeDragTouch = nil
        titleInputEndConn = DisconnectTempDragConn(titleInputEndConn)
        titleDragChangedConn = DisconnectTempDragConn(titleDragChangedConn)
        titleDragEndedConn = DisconnectTempDragConn(titleDragEndedConn)
    end

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            stopTitleDrag()
            dragging = true
            activeDragTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
            dragStart = input.Position
            startPos = mainFrame.Position
            titleInputEndConn = RegisterTempDragConn(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState.Cancel == input.UserInputState then
                    stopTitleDrag()
                elseif dragging and (input == activeDragTouch or input.UserInputType == Enum.UserInputType.Touch) then
                    updateMainFrameDrag(input.Position)
                end
            end))
            titleDragChangedConn = RegisterTempDragConn(UserInputService.InputChanged:Connect(function(changedInput)
                if not dragging then return end
                if activeDragTouch then
                    if changedInput == activeDragTouch or changedInput.UserInputType == Enum.UserInputType.Touch then
                        updateMainFrameDrag(changedInput.Position)
                    end
                elseif changedInput.UserInputType == Enum.UserInputType.MouseMovement then
                    updateMainFrameDrag(changedInput.Position)
                end
            end))
            titleDragEndedConn = RegisterTempDragConn(UserInputService.InputEnded:Connect(function(endedInput)
                if not dragging then return end
                if (activeDragTouch and endedInput == activeDragTouch) or (not activeDragTouch and endedInput.UserInputType == Enum.UserInputType.MouseButton1) then
                    stopTitleDrag()
                end
            end))
        end
    end)
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
currentActiveTab = nil
-- [性能优化 #4 / 建议 #8,#15] 搜索框输入防抖（120ms）+ 新旧词对比短路 + 临时表复用（零 GC 分配）
do
    local lastSearchQuery = ""
    local searchDebounceThread = nil
    local cardHasVisible = {}
    local allCards = {}
    local function applySearchFilter(q)
        lastSearchQuery = q
        table.clear(cardHasVisible)
        table.clear(allCards)
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
        table.clear(cardHasVisible)
        table.clear(allCards)
        if currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab] then
            pcall(tabCanvasRefreshers[currentActiveTab])
        end
    end
    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        local q = searchBox.Text:lower():match("^%s*(.-)%s*$")
        if q == lastSearchQuery then return end
        if searchDebounceThread then
            pcall(task.cancel, searchDebounceThread)
            searchDebounceThread = nil
        end
        if q == "" then
            applySearchFilter(q)
        else
            searchDebounceThread = task.delay(0.12, function()
                searchDebounceThread = nil
                if isRunning then applySearchFilter(q) end
            end)
        end
    end)
end

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

    -- [性能优化 #5 / 建议 #13] 缓存 UIPadding 引用，避免每次重算高度都调用 FindFirstChildOfClass
    local cachedUiPad = scrollFrame:FindFirstChildOfClass("UIPadding")
    local function measureContentHeight()
        local padY = 0
        local uiPad = (cachedUiPad and cachedUiPad.Parent == scrollFrame) and cachedUiPad or scrollFrame:FindFirstChildOfClass("UIPadding")
        if uiPad then
            cachedUiPad = uiPad
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
        -- [性能优化 #5 / 建议 #14] 隐藏中的 TabPage 不做无效子项遍历测量（切换到该页 Visible=true 时会自动触发刷新）
        if refreshing or not scrollFrame or not scrollFrame.Parent or not scrollFrame.Visible then return end
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
        -- 节流从 0.08s 放宽到 0.15s，减少拖拽时信号风暴
        if elapsed >= 0.15 then
            task.defer(function()
                refreshQueued = false
                lastRefreshTime = tick()
                if isRunning then refreshCanvas() end
            end)
        else
            task.delay(0.15 - elapsed, function()
                refreshQueued = false
                lastRefreshTime = tick()
                if isRunning then refreshCanvas() end
            end)
        end
    end

    -- 弱表按 child 去重存储，对象销毁后条目自动消失，避免 UI 重建时连接堆积进 activeConnections
    local childSizeConns = setmetatable({}, { __mode = "k" })

    local function bindChildSignals(child)
        if child:IsA("GuiObject") and not childSizeConns[child] then
            childSizeConns[child] =
                child:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestRefresh)
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

    if scrollFrame.Visible then
        requestRefresh()
        task.delay(0.1, function() if isRunning and scrollFrame.Visible then refreshCanvas() end end)
        task.delay(0.35, function() if isRunning and scrollFrame.Visible then refreshCanvas() end end)
    end
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

    -- 切换当前激活的导航标签页，播放高亮过渡动画并重算目标页滚动高度
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

    -- 创建左侧导航按钮与对应的右侧自适应滚动页面容器
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

    -- 展开主窗口并隐藏悬浮小月亮（带缩放与透明度淡入动画）
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

    -- 最小化主窗口并弹出悬浮小月亮图标
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
            if UpdateMainFrameScale then UpdateMainFrameScale(true) end
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

    -- 切换主窗口展开/最小化状态
ToggleUiVisibility = function()
    if isUiAnimating then return end
    if mainFrame and mainFrame.Visible then
        CloseUI()
    else
        OpenUI()
    end
end

-- 最小化：单击即可（手机/PC 统一用 Activated，避免与 MouseButton1Click 双触发）
if minBtn.Activated then
    minBtn.Activated:Connect(ToggleUiVisibility)
else
    minBtn.MouseButton1Click:Connect(ToggleUiVisibility)
end
-- 关闭：弹出确认框，点「确认退出」才真正卸载，避免误触
do
    local confirmOverlay = nil
    local function CloseUnloadConfirm()
        if confirmOverlay and confirmOverlay.Parent then
            pcall(function() confirmOverlay:Destroy() end)
        end
        confirmOverlay = nil
    end
    -- 弹出退出确认模态框，防止手指误触右上角 [X] 直接关闭脚本
    local function ShowUnloadConfirm()
        if confirmOverlay and confirmOverlay.Parent then
            return
        end
        local parentGui = screenGui
        if not parentGui or not parentGui.Parent then return end

        confirmOverlay = Instance.new("Frame")
        confirmOverlay.Name = "UnloadConfirmOverlay"
        confirmOverlay.Size = UDim2.new(1, 0, 1, 0)
        confirmOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        confirmOverlay.BackgroundTransparency = 0.45
        confirmOverlay.BorderSizePixel = 0
        confirmOverlay.ZIndex = 2000
        confirmOverlay.Active = true
        confirmOverlay.Parent = parentGui
        table.insert(cleanUpInstances, confirmOverlay)

        local card = Instance.new("Frame")
        card.Name = "ConfirmCard"
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.fromScale(0.5, 0.5)
        card.Size = UDim2.new(0, 300, 0, 150)
        card.BackgroundColor3 = Colors.Background
        card.BorderSizePixel = 0
        card.ZIndex = 2001
        card.Parent = confirmOverlay
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
        local stroke = Instance.new("UIStroke")
        stroke.Color = Colors.BorderPurple
        stroke.Thickness = 1.5
        stroke.Parent = card

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -24, 0, 28)
        title.Position = UDim2.new(0, 12, 0, 14)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.Text = "确认退出脚本？"
        title.TextColor3 = Colors.PurplePrimary
        title.TextSize = 16
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 2002
        title.Parent = card

        local desc = Instance.new("TextLabel")
        desc.Size = UDim2.new(1, -24, 0, 40)
        desc.Position = UDim2.new(0, 12, 0, 46)
        desc.BackgroundTransparency = 1
        desc.Font = Enum.Font.Gotham
        desc.Text = "退出后将停止挂机并恢复游戏设置。\n此操作可随时重新注入脚本。"
        desc.TextColor3 = Colors.TextSubtle
        desc.TextSize = 12
        desc.TextXAlignment = Enum.TextXAlignment.Left
        desc.TextYAlignment = Enum.TextYAlignment.Top
        desc.TextWrapped = true
        desc.ZIndex = 2002
        desc.Parent = card

        local cancelBtn = Instance.new("TextButton")
        cancelBtn.Size = UDim2.new(0, 110, 0, 32)
        cancelBtn.Position = UDim2.new(0, 16, 1, -46)
        cancelBtn.BackgroundColor3 = Colors.ControlBg
        cancelBtn.Font = Enum.Font.GothamBold
        cancelBtn.Text = "取消"
        cancelBtn.TextColor3 = Colors.TextWhite
        cancelBtn.TextSize = 13
        cancelBtn.BorderSizePixel = 0
        cancelBtn.ZIndex = 2002
        cancelBtn.Parent = card
        Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0, 6)

        local okBtn = Instance.new("TextButton")
        okBtn.Size = UDim2.new(0, 110, 0, 32)
        okBtn.Position = UDim2.new(1, -126, 1, -46)
        okBtn.BackgroundColor3 = Color3.fromRGB(120, 40, 50)
        okBtn.Font = Enum.Font.GothamBold
        okBtn.Text = "确认退出"
        okBtn.TextColor3 = Colors.AccentRed
        okBtn.TextSize = 13
        okBtn.BorderSizePixel = 0
        okBtn.ZIndex = 2002
        okBtn.Parent = card
        Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 6)

        local function bindClick(btn, fn)
            if btn.Activated then
                btn.Activated:Connect(fn)
            else
                btn.MouseButton1Click:Connect(fn)
            end
        end
        bindClick(cancelBtn, CloseUnloadConfirm)
        bindClick(okBtn, function()
            CloseUnloadConfirm()
            UnloadScript()
        end)
        -- 点遮罩空白处也视为取消
        confirmOverlay.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local pos = input.Position
                local cpos = card.AbsolutePosition
                local csize = card.AbsoluteSize
                local inside = pos.X >= cpos.X and pos.X <= cpos.X + csize.X
                    and pos.Y >= cpos.Y and pos.Y <= cpos.Y + csize.Y
                if not inside then
                    CloseUnloadConfirm()
                end
            end
        end)
    end

    local function onCloseClick()
        ShowUnloadConfirm()
    end
    if closeBtn.Activated then
        closeBtn.Activated:Connect(onCloseClick)
    else
        closeBtn.MouseButton1Click:Connect(onCloseClick)
    end
end
end -- end of Window Frame Construction Scope

local DashUI = {}
local SafeTeleport, allRods, TryFavoriteProtectedFish, SafeSellAllFish, TriggerPrompt, EnsureFishingRodEquipped, TeleportToDragonSea
local IsToolFishingRod, IsCharacterHoldingFishingRod, RestoreMobileFishingButtonUI
local RunTicketQuestAction, RunGiveFishToMonkeyBatch, GetNPCPosition, FireGuiButton
-- [Bug修复 #1] 预声明 IsDialogueUIOpen 与 cachedBossPrompts，修复原代码 IsDialogueUIOpen 局限于子 do-end 作用域导致雷达协程每轮调用 nil 报错中断的严重 Bug
local GetNearestIslandInfo, ImportantDialogueNPCs, FourSacredBeastsSpecs, DoesInstanceMatchNPCSpec, TriggerNPCInstancePrompts, IsDialogueUIOpen
local TryStreamAroundPosition, IsMapOrIslandContainer, ResolvePromptEntity, GetInstanceSearchableSummary, GetCachedWorkspacePrompts
local cachedBossPrompts = {}

-- ============================================================================
-- 【模块 13：通用 UI 控件工厂函数与十大标签页初始化】
-- 作用说明：
--   1. 封装 createCategoryHeader / createCardGroup / createToggleRow / createSliderRow / createDropdownRow /
--      createButtonRow / createInfoRow 七大标准组件，统一处理悬停动画、搜索索引注册与 Config 双向同步；
--   2. 初始化「仪表盘、钓鱼、Boss、神灵、任务、商店与制作、传送、视觉、移动、配置文件」十大页面及仪表盘实时数据卡片。
-- 后续修改指引：
--   - 后续在任意标签页新增功能行，直接调用这组 create*Row 工厂函数即可自动接入搜索与配置保存。
-- ============================================================================
do -- Tab & Feature Construction Scope
-- 创建分组小标题行（紫色大写文字）
local function createCategoryHeader(parent, text)
    local hdr = Instance.new("Frame"); hdr.Size = UDim2.new(1, 0, 0, 22); hdr.BackgroundTransparency = 1; hdr.Parent = parent
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, 0, 1, 0); lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamBold; lbl.Text = string.upper(text); lbl.TextColor3 = Colors.PurplePrimary; lbl.TextSize = 11; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hdr
    return hdr
end

-- 创建圆角带描边的卡片式控件分组容器（高度随子项自动撑开）
local function createCardGroup(parent)
    local group = Instance.new("Frame"); group.Size = UDim2.new(1, 0, 0, 0); group.AutomaticSize = Enum.AutomaticSize.Y; group.BackgroundColor3 = Colors.RowNormal; group.BorderSizePixel = 0; group.Parent = parent
    local s = Instance.new("UIStroke"); s.Color = Colors.BorderSubtle; s.Thickness = 1; s.Parent = group
    Instance.new("UICorner", group).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 0); l.Parent = group
    return group
end

-- 创建通用功能行底板（含主标题、副标题描述、悬停高亮及搜索关键词索引注册）
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

-- 创建开关行组件（支持平滑拨动动画、Config 绑定与静默状态同步）
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

-- 创建数值滑块行组件（按下时动态挂载输入监听并锁定外层滚动，松手即刻释放）
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
    local sliderInputSelfConn = nil
    local sliderChangedConn = nil
    local sliderEndedConn = nil
    touchArea.Active = true
    local function findScrollFrame()
        local p = row
        while p and not p:IsA("ScrollingFrame") do p = p.Parent end
        return p
    end
    -- [性能优化 #1 / 建议 #6,#20] 滑动条按下时才动态连接 UIS.InputChanged/InputEnded，松手立即 Disconnect，彻底消除 24+ 条常驻 UIS 连接
    local function finishSliding()
        sliding = false
        activeTouch = nil
        sliderInputSelfConn = DisconnectTempDragConn(sliderInputSelfConn)
        sliderChangedConn = DisconnectTempDragConn(sliderChangedConn)
        sliderEndedConn = DisconnectTempDragConn(sliderEndedConn)
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
            finishSliding()
            sliding = true
            activeTouch = input.UserInputType == Enum.UserInputType.Touch and input or nil
            activeScrollFrame = findScrollFrame()
            if activeScrollFrame then
                previousScrollingEnabled = activeScrollFrame.ScrollingEnabled
                activeScrollFrame.ScrollingEnabled = false
            end
            updateFromX(input.Position.X)
            sliderInputSelfConn = RegisterTempDragConn(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                    finishSliding()
                end
            end))
            sliderChangedConn = RegisterTempDragConn(UserInputService.InputChanged:Connect(function(changedInput)
                if not sliding then return end
                if activeTouch then
                    if changedInput == activeTouch then updateFromX(changedInput.Position.X) end
                elseif changedInput.UserInputType == Enum.UserInputType.MouseMovement then
                    updateFromX(changedInput.Position.X)
                end
            end))
            sliderEndedConn = RegisterTempDragConn(UserInputService.InputEnded:Connect(function(endedInput)
                if not sliding then return end
                if activeTouch and endedInput == activeTouch then
                    finishSliding()
                elseif not activeTouch and endedInput.UserInputType == Enum.UserInputType.MouseButton1 then
                    finishSliding()
                end
            end))
        end
    end)
    local ctrl = { frame = row, Set = function(val, silent) currentVal = math.clamp(tonumber(val) or minVal, minVal, maxVal); updateVisual(currentVal); if not silent and type(callback) == "function" then callback(currentVal) end end }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

-- 创建下拉选择行组件（支持动态刷新选项列表与单开互斥收起）
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

-- 创建带右侧操作按钮的功能行组件
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

-- 创建只读键值对信息展示行组件
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

DashUI = {}

-- 安全传送角色至目标 CFrame（自动预加载目标流式区域、校验角色存活、清零物理惯性，并在开启坐标锁定时同步更新锚点）
SafeTeleport = function(targetCF)
    if not targetCF then return false end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and (tonumber(hum.Health) or 100) <= 0 then return false end
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        pcall(function()
            if type(LocalPlayer.RequestStreamAroundAsync) == "function" then
                task.spawn(function()
                    pcall(function() LocalPlayer:RequestStreamAroundAsync(targetCF.Position, 2) end)
                end)
            end
        end)
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

-- ============================================================================
-- 【模块 14：【钓鱼】页面构建（全鱼竿属性库、核心钓鱼自动化、技能轮换、智能配装方案）】
-- 作用说明：
--   1. 定义全游戏鱼竿价格/威力/运气数据库 allRods；
--   2. 构建自动抛竿、强制恢复钓鱼按键、位置锁定、锚定条、秒钓、Z/X/C/V 技能顺序配置及双配装方案快速切换 UI。
-- 后续修改指引：
--   - 若游戏版本更新加入了新鱼竿或新鱼饵，可在 allRods 或 baitNameList 中补充对应英文原名。
-- ============================================================================
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
createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿（举起鱼或收起鱼竿时自动暂停，关闭时自动恢复钓鱼按键）", Config.AutoCast, function(v)
    Config.AutoCast = v
    if not v then
        if DashUI._onAutoCastDisabled then pcall(DashUI._onAutoCastDisabled) end
        if RestoreMobileFishingButtonUI then
            -- 仅首次 force 刷新 GUI；后续只重拾按钮，避免 Fisher_GUI 闪两次
            pcall(RestoreMobileFishingButtonUI, true)
            task.delay(0.35, function()
                if isRunning and not Config.AutoCast and RestoreMobileFishingButtonUI then
                    pcall(RestoreMobileFishingButtonUI, false)
                end
            end)
            task.delay(1.0, function()
                if isRunning and not Config.AutoCast and RestoreMobileFishingButtonUI then
                    pcall(RestoreMobileFishingButtonUI, false)
                end
            end)
        end
    end
end, "AutoCast")
createSliderRow(fishCard, "抛竿延迟", "检测/抛竿频率", 0.1, 10.0, Config.CastDelay, true, "秒", function(v) Config.CastDelay = v end, "CastDelay")
createButtonRow(fishCard, "强制恢复钓鱼按键与UI", "当切换物品或关闭自动钓鱼后右侧【钓鱼】圆钮消失时，一键强制恢复并重装鱼竿", "恢复按键", function()
    if Config.HideGameUI then
        Config.HideGameUI = false
        if UIControls["HideGameUI"] and UIControls["HideGameUI"].Set then
            pcall(function() UIControls["HideGameUI"].Set(false, true) end)
        end
        pcall(SetGameUIHidden, false)
    end
    if EnsureFishingRodEquipped then pcall(EnsureFishingRodEquipped) end
    if RestoreMobileFishingButtonUI then pcall(RestoreMobileFishingButtonUI, true) end
    ShowNotification("钓鱼按键已恢复", "已重置钓鱼状态机并强制恢复右侧【钓鱼】按键显示！", "SUCCESS", 4)
end)

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
-- 一键装备预设方案中的鱼竿与鱼饵（先校验背包是否拥有对应鱼竿与鱼饵库存）
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

-- ============================================================================
-- 【模块 15：黑名单防误卖保护引擎、单次防翻转上锁与安全卖鱼系统 (SafeSellAllFish)】
-- 作用说明：
--   1. 支持精确名(=)、前缀(^)、后缀($)、通配符(*?)及子串包含规则匹配，自动剥离背包鱼名后的 " | 重量" 后缀；
--   2. TryFavoriteProtectedFish() 对未上锁的保护鱼发送收藏请求，带冷却与乐观锁校验，防止 Toggle 重复触发把锁解开；
--   3. SafeSellAllFish() 铁律保护：只要背包存在哪怕 1 条保护鱼或已锁鱼，严禁发送 SellFish("All")，改为仅对白名单普通鱼逐条出售。
-- 后续修改指引：
--   - 若需新增默认保护的材料鱼或稀有 Boss 鱼关键词，分别在 craftMaterialFish 或 rareBossKeywords 表中添加。
-- ============================================================================
do -- Fish Protection, Sell & Boss Scope
-- [寄存器优化] 将防误卖与自动上锁引擎的所有内部字典、缓存与辅助函数收敛至单一局部表 FG，
-- 彻底消除 38 个独立 local 变量占用，确保主块活跃局部变量远低于 Luau 200 寄存器硬上限！
local FG = {
    craftMaterialFish = {
        ["Mountain Fish"] = true, ["Catfish"] = true, ["Crimson Catfish"] = true,
        ["Scarlet Fish"] = true, ["Elder Scarlet Fish"] = true, ["Octoparasitic Fish"] = true,
        ["Tiger Mirefish"] = true, ["Mirage Lanternfish"] = true, ["Golden Guardian Fish"] = true,
        ["Frost Kingfish"] = true, ["Frost Queenfish"] = true, ["Rainbow Dragonfish"] = true,
        ["Sanguine Fish"] = true
    },
    rareBossKeywords = {
        "wraith", "octoparasitic", "overlord", "heavenpiercer",
        "primordial", "colossal tigerfish", "ascended perch", "warbringer shark",
        "crimson electric eel", "golden guardian", "frost kingfish", "frost queenfish",
        "rainbow dragonfish", "sanguine fish", "starlight", "leviathan", "kraken",
        "golden dragon", "dark kingfish", "dragon whale", "mountain dragon",
        "dragonfish", "kingfish", "queenfish", "boss"
    },
    cnFishAliasMap = {
        ["巨型老虎鱼"] = "colossal tigerfish",
        ["巨型虎鱼"] = "colossal tigerfish",
        ["鲲鹏君主"] = "primordial kunfish overlord",
        ["原始鲲鱼霸主"] = "primordial kunfish overlord",
        ["太古鲲霸主"] = "primordial kunfish overlord",
        ["金色守护者鱼"] = "golden guardian fish",
        ["金色守护者鱼王"] = "golden guardian fish",
        ["黄金守护鱼"] = "golden guardian fish",
        ["黄金龙鱼"] = "golden dragon fish",
        ["金色龙鱼"] = "golden dragon fish",
        ["暗黑鱼王"] = "dark kingfish",
        ["黑暗鱼王"] = "dark kingfish",
        ["山海龙鲸"] = "mountain dragon whale",
        ["龙鲸"] = "mountain dragon whale",
        ["猩红铲鱼君主"] = "elder scarlet fish",
        ["猩红电鳗"] = "crimson electric eel",
        ["猩红电鳗鱼王"] = "crimson electric eel",
        ["深红电鳗"] = "crimson electric eel",
        ["穿天龟"] = "heavenpiercer turtle",
        ["破天玄龟"] = "heavenpiercer turtle",
        ["破天巨龟"] = "heavenpiercer turtle",
        ["章鱼寄生鱼"] = "octoparasitic fish",
        ["幽灵虎鲸"] = "wraith orca",
        ["怨灵虎鲸"] = "wraith orca",
        ["冰霜鱼王"] = "frost kingfish",
        ["冰霜王鱼"] = "frost kingfish",
        ["冰霜鱼后"] = "frost queenfish",
        ["彩虹龙鱼"] = "rainbow dragonfish",
        ["血腥鱼"] = "sanguine fish",
        ["幻影灯笼鱼"] = "mirage lanternfish",
        ["幻影灯鱼"] = "mirage lanternfish",
        ["虎纹泥鱼"] = "tiger mirefish",
        ["虎纹沼泽鱼"] = "tiger mirefish",
        ["高山鱼"] = "mountain fish",
        ["山鱼"] = "mountain fish",
        ["飞升鲈鱼"] = "ascended perch",
        ["升华鲈鱼"] = "ascended perch",
        ["战神鲨"] = "warbringer shark",
        ["战神鲨鱼"] = "warbringer shark",
        ["猩红鲶鱼"] = "crimson catfish",
        ["猩红鲶鱼之王"] = "crimson catfish",
        ["远古猩红鱼"] = "elder scarlet fish",
        ["老猩红鱼"] = "elder scarlet fish",
        ["猩红鱼"] = "scarlet fish",
        ["鲶鱼"] = "catfish",
    },
    favNameSet = {
        Favorite = true, Favorited = true, Favourite = true, Favourited = true,
        Locked = true, Lock = true, IsFavorite = true, IsFavourite = true, IsLocked = true,
        Star = true, Starred = true, Fav = true, Keep = true, Protected = true,
        Pin = true, Pinned = true, Safe = true, Saved = true, Mark = true, Marked = true, Bind = true, Bound = true,
    },
    favCheckNames = {
        "Favorite", "Favourite", "Locked", "Favorited", "Favourited", "IsFavorite", "IsFavourite", "IsLocked",
        "Fav", "Lock", "Star", "Pin", "Keep", "Protected"
    },
    favFolderNames = {
        "Favorites", "Favorite", "FavoriteItems", "FavoriteFish", "Locked", "LockedItems", "LockedFish"
    },
    fishNameChildKeys = {
        "FishName", "ItemName", "Species", "DisplayName", "Type", "Name"
    },
    fishWeightChildKeys = {
        "Weight", "Kg", "KG", "Mass", "Size"
    },
    bagFolderNames = {
        "Inventory", "Hotbar"
    },
    nonFishStrongKeywords = {
        "rod", "pole", "bait", "orb", "potion", "ticket", "scroll"
    },
    nonFishExactOnlySet = {
        ["key"] = true, ["chest"] = true, ["box"] = true, ["book"] = true,
        ["stone"] = true, ["crystal"] = true, ["gem"] = true,
    },
    fishSpeciesGuardKeywords = {
        "fish", "shark", "whale", "eel", "crab", "ray", "squid", "octopus", "octoparasitic",
        "turtle", "carp", "salmon", "trout", "tuna", "bass", "perch", "catfish", "orca",
        "leviathan", "kraken", "dolphin", "marlin", "cod", "herring", "pike", "snapper", "grouper"
    },
    favRemotePriorityNames = {
        "FavoriteItem", "FavouriteItem", "FavoriteFish", "FavouriteFish",
        "LockFish", "LockItem", "Lock", "Favorite", "Favourite",
        "ToggleLock", "ToggleFavorite", "SetLock", "SetFavorite", "LockUnlock", "FavFish", "FavItem"
    },
    pureNameCache = {},
    pureNameCacheCount = 0,
    itemPrimaryNameCache = setmetatable({}, { __mode = "k" }),
    cachedFavRemote = nil,
    verifiedSmartFavFormat = nil,
    lastFavBlockNotify = 0,
    pendingLockQueue = {},
    inLockQueue = setmetatable({}, { __mode = "k" }),
    isBatchLockQueueRunning = false,
    lockingInFlight = setmetatable({}, { __mode = "k" }),
    lockConfirmedOrSent = setmetatable({}, { __mode = "k" }),
    lastLockSentAt = setmetatable({}, { __mode = "k" }),
    lastLockSentByName = {},
    lastAnyLockSentAt = 0,
    isInternalFavCall = false,
    cachedInvGrids = {},
    lastInvGridSearchAt = 0,
    guiLockByExactName = {},
    guiLockByInstance = setmetatable({}, { __mode = "k" }),
    guiLockBySpeciesWeight = {},
    lastGuiLockScanAt = 0,
}

-- 提取纯鱼名：自动剥离背包实例名后追加的 " | 1849724.37"、"(1.4M KG)" 重量后缀及 "#12" 编号后缀
function FG.GetPureFishName(rawName)
    if not rawName then return "" end
    local s = (typeof(rawName) == "Instance") and rawName.Name or tostring(rawName)
    local cached = FG.pureNameCache[s]
    if cached then return cached end
    local beforePipe = s:match("^(.-)%s*|")
    local res = (beforePipe and #beforePipe > 0) and beforePipe:match("^%s*(.-)%s*$") or s:match("^%s*(.-)%s*$")
    res = res:gsub("%s*%([^%(%)]*[%d%.]+[^%(%)]*%)%s*$", "")
    res = res:gsub("%s*[_#]%d+%s*$", ""):match("^%s*(.-)%s*$") or res
    if FG.pureNameCacheCount >= 512 then
        table.clear(FG.pureNameCache)
        FG.pureNameCacheCount = 0
    end
    FG.pureNameCache[s] = res
    FG.pureNameCacheCount = FG.pureNameCacheCount + 1
    return res
end

function FG.IsTruthyLockValue(v)
    if v == true or v == 1 then return true end
    if type(v) == "string" then
        local low = v:lower():match("^%s*(.-)%s*$")
        return low == "true" or low == "1" or low == "yes" or low == "locked" or low == "favorited" or low == "favourited" or low == "lock" or low == "fav"
    end
    return false
end

function FG.HasLockKeywordInName(str)
    if type(str) ~= "string" or str == "" then return false end
    local kLow = str:lower()
    return FG.favNameSet[str] or kLow:find("fav", 1, true) or kLow:find("lock", 1, true)
        or kLow:find("star", 1, true) or kLow:find("pin", 1, true)
        or kLow:find("keep", 1, true) or kLow:find("safe", 1, true)
        or kLow:find("mark", 1, true) or kLow:find("bind", 1, true)
        or kLow:find("锁", 1, true) or kLow:find("收藏", 1, true)
end

-- 规范化鱼种名称（自动剥离重量后缀并映射中文别名到英文小写）
function FG.NormalizeFishSpeciesLower(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return "" end
    local pure = FG.GetPureFishName(rawStr)
    local mapped = FG.cnFishAliasMap[pure]
    if not mapped then
        for cnKey, enVal in pairs(FG.cnFishAliasMap) do
            if pure:find(cnKey, 1, true) or rawStr:find(cnKey, 1, true) then
                mapped = enVal
                break
            end
        end
    end
    return (mapped or pure):lower():match("^%s*(.-)%s*$")
end

-- 将以 KG 为单位的数值重量格式化为与游戏库存 UI 一致的缩写标签（如 1400000 -> "1.4m"，5950 -> "5.95t"）
function FG.FormatWeightTag(weightKg)
    if type(weightKg) ~= "number" or weightKg <= 0 then return nil end
    local num, unit
    if weightKg >= 1e9 then
        num, unit = weightKg / 1e9, "b"
    elseif weightKg >= 1e6 then
        num, unit = weightKg / 1e6, "m"
    elseif weightKg >= 1e3 then
        num, unit = weightKg / 1e3, "t"
    else
        num, unit = weightKg, "kg"
    end
    return string.format("%.2f", num):gsub("%.?0+$", "") .. unit
end

-- 提取背包鱼实例的数值重量（KG），支持从 "鱼名 | 1849724.37" 实例名或 Weight 子节点/属性提取
function FG.ExtractItemWeightKg(item)
    if not item or typeof(item) ~= "Instance" then return nil end
    local pipeNum = item.Name:match("|%s*([%d%.]+)")
    if pipeNum then
        local w = tonumber(pipeNum)
        if w and w > 0 then return w end
    end
    local wKeys = FG.fishWeightChildKeys
    for i = 1, #wKeys do
        local k = wKeys[i]
        local ch = item:FindFirstChild(k)
        if ch and ch:IsA("ValueBase") then
            local w = tonumber(ch.Value)
            if w and w > 0 then return w end
        end
        local attr = item:GetAttribute(k)
        if attr ~= nil then
            local w = tonumber(attr)
            if w and w > 0 then return w end
        end
    end
    return nil
end

-- 解析库存 UI 卡片标题文本（例如 "Wraith Orca (1.4M KG)" 或 "巨型老虎鱼 (5.95 吨)"）
function FG.ParseCardFishLabel(text)
    if type(text) ~= "string" or text == "" then return nil, nil, nil end
    local clean = text:gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
    local namePart, weightPart = clean:match("^(.-)%s*%(([^%(%)]+)%)%s*$")
    if not namePart or namePart == "" or not weightPart then return nil, nil, nil end
    local speciesLower = FG.NormalizeFishSpeciesLower(namePart)
    if speciesLower == "" then return nil, nil, nil end
    local numStr = weightPart:match("([%d%.]+)")
    local num = numStr and tonumber(numStr) or nil
    if not num or num <= 0 then return speciesLower, nil, nil end
    local mult, unit = 1, "kg"
    if weightPart:find("[Bb]") or weightPart:find("十亿", 1, true) then
        mult, unit = 1e9, "b"
    elseif weightPart:find("[Mm]") or weightPart:find("百万", 1, true) or weightPart:find("兆", 1, true) then
        mult, unit = 1e6, "m"
    elseif weightPart:find("[TtKk]") or weightPart:find("吨", 1, true) or weightPart:find("千", 1, true) then
        mult, unit = 1e3, "t"
    end
    local weightKg = num * mult
    local weightTag = string.format("%.2f", num):gsub("%.?0+$", "") .. unit
    return speciesLower, weightKg, weightTag
end

-- 检测单个库存 UI 槽位卡片左上角锁头图标的显式状态（仅在库存界面真实打开可见时校验左上角锁头图标）
function FG.InspectCardPadlockState(card)
    if not card or not card:IsA("GuiObject") or not card.Visible then return nil end
    local favNames = FG.favCheckNames
    for i = 1, #favNames do
        local attrVal = card:GetAttribute(favNames[i])
        if attrVal ~= nil then
            return FG.IsTruthyLockValue(attrVal)
        end
    end
    local cardAbsW, cardAbsH = card.AbsoluteSize.X, card.AbsoluteSize.Y
    if cardAbsW < 40 or cardAbsH < 40 then return nil end
    local cardAbsX, cardAbsY = card.AbsolutePosition.X, card.AbsolutePosition.Y
    local foundAnyPadlock = false
    local foundWhiteLocked = false
    for _, d in ipairs(card:GetDescendants()) do
        if (d:IsA("ImageButton") or d:IsA("ImageLabel")) and d ~= card and d.Visible and d.Image ~= "" then
            local isPadlockCandidate = false
            if FG.HasLockKeywordInName(d.Name) or (d.Parent and d.Parent ~= card and FG.HasLockKeywordInName(d.Parent.Name)) then
                isPadlockCandidate = true
            elseif d.AbsoluteSize.X >= 6 and d.AbsoluteSize.Y >= 6 then
                local relW = d.AbsoluteSize.X / cardAbsW
                local relH = d.AbsoluteSize.Y / cardAbsH
                local relX = (d.AbsolutePosition.X - cardAbsX) / cardAbsW
                local relY = (d.AbsolutePosition.Y - cardAbsY) / cardAbsH
                if relW >= 0.06 and relW <= 0.26 and relH >= 0.06 and relH <= 0.28 and relX >= 0.01 and relX <= 0.26 and relY >= 0.01 and relY <= 0.32 then
                    isPadlockCandidate = true
                end
            end
            if isPadlockCandidate then
                foundAnyPadlock = true
                local col = d.ImageColor3
                local trans = d.ImageTransparency
                if trans <= 0.18 and col.R >= 0.85 and col.G >= 0.85 and col.B >= 0.85 then
                    foundWhiteLocked = true
                    break
                end
            end
        end
    end
    if foundAnyPadlock then
        return foundWhiteLocked
    end
    return nil
end

-- 刷新并缓存游戏原生库存 UI (MainGui) 中已渲染鱼槽位的锁头状态（0.25s 节流）
function FG.RefreshGuiLockCache(now, force)
    now = now or tick()
    if not force and (now - FG.lastGuiLockScanAt) < 0.25 then return end
    FG.lastGuiLockScanAt = now

    table.clear(FG.guiLockByExactName)
    table.clear(FG.guiLockByInstance)
    table.clear(FG.guiLockBySpeciesWeight)

    local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end

    local validGrids = {}
    for i = 1, #FG.cachedInvGrids do
        local g = FG.cachedInvGrids[i]
        if g and g.Parent then
            table.insert(validGrids, g)
        end
    end
    if #validGrids == 0 or (now - FG.lastInvGridSearchAt) >= 2.0 then
        FG.lastInvGridSearchAt = now
        table.clear(validGrids)
        local seenGrid = {}
        for _, guiName in ipairs({"MainGui", "Fisher_GUI"}) do
            local rootGui = pg:FindFirstChild(guiName)
            if rootGui then
                for _, desc in ipairs(rootGui:GetDescendants()) do
                    if desc:IsA("UIGridLayout") and desc.Parent and desc.Parent:IsA("GuiObject") then
                        local grid = desc.Parent
                        if not seenGrid[grid] then
                            local pathLow = grid:GetFullName():lower()
                            if pathLow:find("inventory", 1, true) or pathLow:find("bag", 1, true) or pathLow:find("backpack", 1, true) or pathLow:find("item", 1, true) or pathLow:find("menu", 1, true) then
                                seenGrid[grid] = true
                                table.insert(validGrids, grid)
                            end
                        end
                    end
                end
            end
        end
        FG.cachedInvGrids = validGrids
    end

    for gIdx = 1, #validGrids do
        local grid = validGrids[gIdx]
        if grid.AbsoluteSize.X > 60 and grid.AbsoluteSize.Y > 60 then
            for _, card in ipairs(grid:GetChildren()) do
                if card:IsA("GuiObject") and card.Visible and card.AbsoluteSize.X > 40 then
                    local cNameLow = card.Name:lower()
                    if cNameLow ~= "template" and not cNameLow:find("template", 1, true) then
                        local lockState = FG.InspectCardPadlockState(card)
                        if lockState ~= nil then
                            FG.guiLockByExactName[card.Name] = lockState
                            for _, ch in ipairs(card:GetChildren()) do
                                if ch:IsA("ObjectValue") and ch.Value then
                                    FG.guiLockByInstance[ch.Value] = lockState
                                end
                            end
                            for _, d in ipairs(card:GetDescendants()) do
                                if d:IsA("TextLabel") and d.Text and d.Text:find("(", 1, true) then
                                    local spLow, wKg, wTag = FG.ParseCardFishLabel(d.Text)
                                    if spLow and spLow ~= "" and (wTag or wKg) then
                                        local list = FG.guiLockBySpeciesWeight[spLow]
                                        if not list then
                                            list = {}
                                            FG.guiLockBySpeciesWeight[spLow] = list
                                        end
                                        table.insert(list, { weightTag = wTag, weightKg = wKg, locked = lockState })
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- 查询某条背包鱼实例在库存 UI 中的显式锁头状态（仅当精确实例或精确同重卡片明确渲染时返回）
function FG.GetGuiSlotLockState(item)
    if not item or typeof(item) ~= "Instance" then return nil end
    FG.RefreshGuiLockCache(tick(), false)
    local byInst = FG.guiLockByInstance[item]
    if byInst ~= nil then return byInst end
    if item.Name:find("|", 1, true) then
        local byName = FG.guiLockByExactName[item.Name]
        if byName ~= nil then return byName end
    end

    local pure = FG.GetFishItemPrimaryPureName(item)
    local spLow = FG.NormalizeFishSpeciesLower(pure ~= "" and pure or item.Name)
    if spLow == "" then return nil end

    local list = FG.guiLockBySpeciesWeight[spLow]
    local itemW = FG.ExtractItemWeightKg(item)
    if list and #list > 0 and itemW then
        local itemTag = FG.FormatWeightTag(itemW)
        local lockedMatches = 0
        local unlockedMatches = 0
        for i = 1, #list do
            local entry = list[i]
            local isMatch = (itemTag and entry.weightTag == itemTag)
                or (entry.weightKg and math.abs(itemW - entry.weightKg) <= math.max(5000, itemW * 0.005))
            if isMatch then
                if entry.locked then
                    lockedMatches = lockedMatches + 1
                else
                    unlockedMatches = unlockedMatches + 1
                end
            end
        end
        if (lockedMatches + unlockedMatches) > 0 then
            if unlockedMatches == 0 then
                return true
            elseif lockedMatches == 0 then
                return false
            end
        end
    end
    return nil
end

-- 检查数据模型层（子节点 / 属性 / BoolValue / 父级收藏表）上锁状态
function FG.GetFishItemDataLockState(item)
    if not item or typeof(item) ~= "Instance" then return false, false end
    local hasExplicitField = false
    local favNames = FG.favCheckNames
    for i = 1, #favNames do
        local fav = item:FindFirstChild(favNames[i])
        if fav then
            hasExplicitField = true
            if fav:IsA("BoolValue") then
                if fav.Value == true then return true, true end
            elseif fav:IsA("ValueBase") then
                if FG.IsTruthyLockValue(fav.Value) then return true, true end
            else
                return true, true
            end
        end
    end
    for _, ch in ipairs(item:GetChildren()) do
        local cn = ch.Name
        local cnLow = cn:lower()
        if FG.favNameSet[cn] or cnLow:find("fav", 1, true) or cnLow:find("lock", 1, true) or cnLow:find("star", 1, true) then
            hasExplicitField = true
            if ch:IsA("ValueBase") then
                if FG.IsTruthyLockValue(ch.Value) then
                    return true, true
                end
            else
                return true, true
            end
        end
    end
    for i = 1, #favNames do
        local attrVal = item:GetAttribute(favNames[i])
        if attrVal ~= nil then
            hasExplicitField = true
            if FG.IsTruthyLockValue(attrVal) then
                return true, true
            end
        end
    end
    local okA, attrMap = pcall(function() return item:GetAttributes() end)
    if okA and type(attrMap) == "table" then
        for k, v in pairs(attrMap) do
            if FG.HasLockKeywordInName(k) then
                hasExplicitField = true
                if FG.IsTruthyLockValue(v) then
                    return true, true
                end
            end
        end
    end
    if item:IsA("BoolValue") then
        hasExplicitField = true
        if item.Value == true then
            return true, true
        end
    elseif item:IsA("StringValue") and item.Value ~= "1" and FG.IsTruthyLockValue(item.Value) then
        return true, true
    end
    local pData = item.Parent and item.Parent.Parent
    if pData then
        local fFolders = FG.favFolderNames
        for i = 1, #fFolders do
            local ff = pData:FindFirstChild(fFolders[i])
            if ff then
                local entry = ff:FindFirstChild(item.Name)
                if entry then
                    if not entry:IsA("ValueBase") or FG.IsTruthyLockValue(entry.Value) then
                        return true, true
                    end
                end
                if FG.IsTruthyLockValue(ff:GetAttribute(item.Name)) then
                    return true, true
                end
            end
        end
    end
    return false, hasExplicitField
end

function FG.IsFishItemDataFavorited(item)
    local isLocked = FG.GetFishItemDataLockState(item)
    return isLocked
end

-- 检查鱼实例是否已在数据模型层处于收藏/上锁状态（真实数据锁 + 单次防翻转永久记录，绝不因 2s 过期清除导致重复发包把锁解开！）
function FG.IsFishItemFavorited(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked, hasExplicitField = FG.GetFishItemDataLockState(item)
    if dataLocked then
        FG.lockConfirmedOrSent[item] = true
        return true
    end
    if hasExplicitField then
        return false
    end
    if FG.lockConfirmedOrSent[item] then
        return true
    end
    return false
end

-- 编译通配符/前缀/后缀/精确/包含匹配器（支持中英文鱼名与变异前缀匹配）
function FG.BuildFishMatcher(patternStr)
    if not patternStr then return nil end
    local raw = tostring(patternStr):match("^%s*(.-)%s*$")
    local pipePrefix = raw:match("^(.-)%s*|%s*[%d%.]+$")
    if pipePrefix and #pipePrefix > 0 then
        raw = pipePrefix:match("^%s*(.-)%s*$")
    end
    if raw == "" then return nil end
    local mappedEn = FG.cnFishAliasMap[raw]
    local lower = (mappedEn or raw):lower()
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
        matcher = function(pureLower, fullLower)
            return pureLower:sub(1, #body) == body or fullLower:sub(1, #body) == body
        end
    elseif mode == "suffix" then
        matcher = function(pureLower)
            return #pureLower >= #body and pureLower:sub(-#body) == body
        end
    elseif mode == "contains" then
        matcher = function(pureLower, fullLower, baseLower)
            return FG.DoesSpeciesMatch(pureLower, fullLower, baseLower, body)
        end
    else
        local escaped = body:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
        escaped = escaped:gsub("%*", ".*"):gsub("%?", ".")
        local stripped = body:gsub("[%*%?]+", ""):match("^%s*(.-)%s*$")
        matcher = function(pureLower, fullLower)
            if pureLower:find(escaped) ~= nil or fullLower:find(escaped) ~= nil then
                return true
            end
            if stripped ~= "" and (pureLower:find(stripped, 1, true) ~= nil or fullLower:find(stripped, 1, true) ~= nil) then
                return true
            end
            return false
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

function FG.GetRuleMatchers()
    local src = Config.CustomProtectedFish or ""
    if src == cachedRuleSource then return cachedRuleMatchers end
    table.clear(cachedRuleMatchers)
    for token in string.gmatch(src, "([^,，;；\n\r]+)") do
        local m = FG.BuildFishMatcher(token)
        if m then table.insert(cachedRuleMatchers, m) end
    end
    cachedRuleSource = src
    return cachedRuleMatchers
end

-- 剥离鱼名开头的常见变异修饰词或品质前缀（如 [Mythic] / Shiny / Albino / Cursed 等）
function FG.StripFishMutationPrefix(lowerName)
    if type(lowerName) ~= "string" or lowerName == "" then return "" end
    local s = lowerName:gsub("^%b[]%s*", ""):gsub("^【.-】%s*", ""):match("^%s*(.-)%s*$") or ""
    local prefixes = {"shiny ", "albino ", "cursed ", "blessed ", "giant ", "big ", "small ", "mutated ", "shadow ", "corrupted ", "spectral ", "void ", "abyssal ", "celestial "}
    local changed = true
    while changed do
        changed = false
        for i = 1, #prefixes do
            local p = prefixes[i]
            if s:sub(1, #p) == p and #s > #p then
                s = s:sub(#p + 1):match("^%s*(.-)%s*$")
                changed = true
                break
            end
        end
    end
    if s:sub(1, 7) == "golden " and not s:find("golden guardian", 1, true) and not s:find("golden dragon", 1, true) then
        s = s:sub(8):match("^%s*(.-)%s*$")
    elseif s:sub(1, 8) == "rainbow " and not s:find("rainbow dragon", 1, true) then
        s = s:sub(9):match("^%s*(.-)%s*$")
    end
    return s
end

-- 高召回鱼种匹配器（完整保留 36max.txt 的子串/前缀/后缀容错能力，同时特判隔离 Catfish vs Crimson Catfish 与 Scarlet Fish vs Elder Scarlet Fish）
function FG.DoesSpeciesMatch(pureLower, fullLower, baseLower, targetLower)
    if type(targetLower) ~= "string" or targetLower == "" then return false end
    if targetLower == "catfish" and (pureLower:find("crimson catfish", 1, true) or fullLower:find("crimson catfish", 1, true)) then
        return false
    end
    if targetLower == "scarlet fish" and (pureLower:find("elder scarlet fish", 1, true) or fullLower:find("elder scarlet fish", 1, true)) then
        return false
    end
    if pureLower == targetLower or (baseLower and baseLower == targetLower) or fullLower == targetLower then
        return true
    end
    if pureLower:find(targetLower, 1, true) ~= nil or fullLower:find(targetLower, 1, true) ~= nil then
        return true
    end
    return false
end

function FG.IsFishNameStringBlacklisted(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return false end
    local pureName = FG.GetPureFishName(rawStr)
    local mapped = FG.cnFishAliasMap[pureName]
    if not mapped then
        for cnKey, enVal in pairs(FG.cnFishAliasMap) do
            if pureName == cnKey or rawStr == cnKey then
                mapped = enVal
                break
            end
        end
        if not mapped then
            for cnKey, enVal in pairs(FG.cnFishAliasMap) do
                if pureName:find(cnKey, 1, true) or rawStr:find(cnKey, 1, true) then
                    mapped = enVal
                    break
                end
            end
        end
    end
    mapped = mapped or pureName
    local pureLower = mapped:lower():match("^%s*(.-)%s*$")
    local baseLower = FG.StripFishMutationPrefix(pureLower)
    local fullLower = (rawStr .. " " .. mapped):lower()
    if pureLower == "" then return false end

    if Config.MaterialFarming then
        if FG.craftMaterialFish[pureName] or FG.craftMaterialFish[mapped] then return true end
        for matName in pairs(FG.craftMaterialFish) do
            local matLow = matName:lower()
            if FG.DoesSpeciesMatch(pureLower, fullLower, baseLower, matLow) then
                return true
            end
        end
    end
    if Config.AutoProtectRareBossFish then
        for _, kw in ipairs(FG.rareBossKeywords) do
            if pureLower:find(kw, 1, true) or fullLower:find(kw, 1, true) then
                return true
            end
        end
    end
    -- 核心保护规则：只要用户在「收藏目标」或「收藏/保护名单」中选定了鱼（如 Wraith Orca），
    -- 无论用户是否先开自动收藏或先开自动卖鱼，一律 100% 纳入黑名单防误卖保护，绝不误卖！
    if Config.FavouriteFishName and Config.FavouriteFishName ~= "" then
        local targetRaw = FG.GetPureFishName(Config.FavouriteFishName)
        local targetPure = FG.NormalizeFishSpeciesLower(targetRaw)
        local targetBase = FG.StripFishMutationPrefix(targetPure)
        if FG.DoesSpeciesMatch(pureLower, fullLower, baseLower, targetPure)
            or (targetBase ~= "" and FG.DoesSpeciesMatch(pureLower, fullLower, baseLower, targetBase)) then
            return true
        end
    end
    local matchers = FG.GetRuleMatchers()
    for i = 1, #matchers do
        if matchers[i](pureLower, fullLower, baseLower) then
            return true
        end
    end
    return false
end

function FG.GetFishItemPrimaryPureName(item)
    if not item then return "" end
    if type(item) == "string" then return FG.GetPureFishName(item) end
    if typeof(item) ~= "Instance" then return "" end
    local cached = FG.itemPrimaryNameCache[item]
    if cached and cached.rawName == item.Name then
        return cached.pure
    end
    local resolved = nil
    if item:IsA("ValueBase") and type(item.Value) == "string" and item.Value ~= "" then
        local p = FG.GetPureFishName(item.Value)
        if p ~= "" and not p:match("^%d+$") and not FG.IsTruthyLockValue(p) then resolved = p end
    end
    if not resolved then
        local nameKeys = FG.fishNameChildKeys
        for i = 1, #nameKeys do
            local childName = nameKeys[i]
            local ch = item:FindFirstChild(childName)
            if ch and ch:IsA("ValueBase") and type(ch.Value) == "string" and ch.Value ~= "" then
                local p = FG.GetPureFishName(ch.Value)
                if p ~= "" then resolved = p; break end
            end
            local attr = item:GetAttribute(childName)
            if type(attr) == "string" and attr ~= "" then
                local p = FG.GetPureFishName(attr)
                if p ~= "" then resolved = p; break end
            end
        end
    end
    resolved = resolved or FG.GetPureFishName(item.Name)
    FG.itemPrimaryNameCache[item] = { rawName = item.Name, pure = resolved }
    return resolved
end

function FG.IsNonFishEquipmentItem(item)
    if not item or typeof(item) ~= "Instance" then return false end
    if IsToolFishingRod and IsToolFishingRod(item) then return true end
    local pureName = FG.GetFishItemPrimaryPureName(item)
    local pureLow = pureName:lower()
    if pureLow == "" then return true end
    if FG.craftMaterialFish[pureName] then return false end
    for i = 1, #FG.fishSpeciesGuardKeywords do
        if pureLow:find(FG.fishSpeciesGuardKeywords[i], 1, true) then
            return false
        end
    end
    if FG.nonFishExactOnlySet[pureLow] then
        return true
    end
    for i = 1, #FG.nonFishStrongKeywords do
        local kw = FG.nonFishStrongKeywords[i]
        if pureLow == kw or pureLow:find("%f[%a]" .. kw .. "%f[%A]") then
            return true
        end
    end
    return false
end

function FG.ShouldProtectFishItem(item)
    if not item then return false end
    if type(item) == "string" then
        return FG.IsFishNameStringBlacklisted(item)
    end
    if typeof(item) ~= "Instance" then return false end

    if FG.IsFishNameStringBlacklisted(item.Name) then
        return true
    end
    if item:IsA("ValueBase") and type(item.Value) == "string" and FG.IsFishNameStringBlacklisted(item.Value) then
        return true
    end
    local nameKeys = FG.fishNameChildKeys
    for i = 1, #nameKeys do
        local childName = nameKeys[i]
        local ch = item:FindFirstChild(childName)
        if ch and ch:IsA("ValueBase") and type(ch.Value) == "string" and FG.IsFishNameStringBlacklisted(ch.Value) then
            return true
        end
        local attr = item:GetAttribute(childName)
        if type(attr) == "string" and FG.IsFishNameStringBlacklisted(attr) then
            return true
        end
    end

    if Config.AutoProtectRareBossFish then
        local rarityObj = item:FindFirstChild("Rarity") or item:FindFirstChild("Tier") or item:FindFirstChild("Quality")
        if rarityObj and rarityObj:IsA("ValueBase") and rarityObj.Value then
            local rStr = tostring(rarityObj.Value):lower()
            if rStr:find("mythic") or rStr:find("secret") or rStr:find("boss") or rStr:find("legend") or rStr:find("divine") or rStr:find("supreme") or rStr:find("ancient") then
                return true
            end
        end
        local rAttr = item:GetAttribute("Rarity") or item:GetAttribute("Tier") or item:GetAttribute("Quality")
        if type(rAttr) == "string" then
            local rStr = rAttr:lower()
            if rStr:find("mythic") or rStr:find("secret") or rStr:find("boss") or rStr:find("legend") or rStr:find("divine") or rStr:find("supreme") or rStr:find("ancient") then
                return true
            end
        end
    end
    return false
end

-- 查找并缓存游戏内的收藏/上锁远程事件（优先使用 Events.FavoriteItem，与原版逻辑完全一致）
function FG.GetFavoriteRemote()
    if Events then
        local directFav = Events:FindFirstChild("FavoriteItem")
        if directFav and (directFav:IsA("RemoteEvent") or directFav:IsA("RemoteFunction")) then
            FG.cachedFavRemote = directFav
            return directFav
        end
    end
    if sharedEnv and typeof(sharedEnv.IdenticalLearnedFavRemote) == "Instance" and sharedEnv.IdenticalLearnedFavRemote.Parent then
        return sharedEnv.IdenticalLearnedFavRemote
    end
    if FG.cachedFavRemote and FG.cachedFavRemote.Parent then
        return FG.cachedFavRemote
    end
    if Events then
        for i = 1, #FG.favRemotePriorityNames do
            local r = Events:FindFirstChild(FG.favRemotePriorityNames[i])
            if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then
                FG.cachedFavRemote = r
                return r
            end
        end
        for _, ch in ipairs(Events:GetChildren()) do
            if ch:IsA("RemoteEvent") or ch:IsA("RemoteFunction") then
                local low = ch.Name:lower()
                if low:find("fav", 1, true) or low:find("lock", 1, true) then
                    FG.cachedFavRemote = ch
                    return ch
                end
            end
        end
    end
    return nil
end

-- 仅当鱼实例真实处于已上锁保护状态时才视为已完成白锁保护
function FG.IsFishLockProtected(item)
    return FG.IsFishItemFavorited(item)
end

function FG.RawCallFavRemote(favRem, ...)
    if not favRem then return false end
    local args = {...}
    if favRem:IsA("RemoteEvent") then
        FG.isInternalFavCall = true
        local ok = pcall(function() favRem:FireServer(unpack(args)) end)
        FG.isInternalFavCall = false
        return ok
    elseif favRem:IsA("RemoteFunction") then
        local ok = pcall(function()
            task.spawn(function()
                FG.isInternalFavCall = true
                pcall(function() favRem:InvokeServer(unpack(args)) end)
                FG.isInternalFavCall = false
            end)
        end)
        return ok
    end
    return false
end

-- ============================================================================
-- [核心修复] 按指定格式单次调用 FavoriteItem，配合状态反馈闭环探测：
--   1. 发送前必查 `FG.IsFishItemFavorited(item)`，已上锁的鱼绝不发送第二次 Toggle（彻底杜绝锁了又被解开）；
--   2. 首包默认发送 `favRem:FireServer(item)`（或已验证成功的格式），随后轮询检测 `FG.IsFishItemFavorited(item)`；
--   3. 仅当首包发送后 0.64s 内鱼仍未变为已上锁状态时，才依次回退尝试 `item.Name` / `纯鱼名` / `("Favorite", item)`，
--      一旦任意格式使 `FG.IsFishItemFavorited(item)` 变为 true，立即终止探测并缓存该格式！
-- ============================================================================
function FG.FireFormatOnce(favRem, item, fmt)
    if not favRem or not item or typeof(item) ~= "Instance" then return false end
    if FG.IsFishItemDataFavorited(item) then return true end
    local rLow = favRem.Name:lower()
    local act = rLow:find("lock", 1, true) and "Lock" or "Favorite"
    if fmt == "instance" then
        return FG.RawCallFavRemote(favRem, item)
    elseif fmt == "name" then
        return FG.RawCallFavRemote(favRem, item.Name)
    elseif fmt == "pure_name" then
        local pure = FG.GetFishItemPrimaryPureName(item)
        return FG.RawCallFavRemote(favRem, (pure ~= "" and pure) or item.Name)
    elseif fmt == "action_instance" then
        return FG.RawCallFavRemote(favRem, act, item)
    elseif fmt == "action_name" then
        return FG.RawCallFavRemote(favRem, act, item.Name)
    end
    return FG.RawCallFavRemote(favRem, item)
end

function FG.BuildCandidateFavFormats(modeOverride)
    local mode = modeOverride or Config.FavPacketMode or "实例对象(item)"
    local order = {}
    local seen = {}
    local function pushFmt(f)
        if f and not seen[f] then
            seen[f] = true
            table.insert(order, f)
        end
    end
    if sharedEnv and type(sharedEnv.IdenticalLearnedFavFormat) == "string" then
        pushFmt(sharedEnv.IdenticalLearnedFavFormat)
    end
    if FG.verifiedSmartFavFormat then
        pushFmt(FG.verifiedSmartFavFormat)
    end
    if mode == "完整鱼名(item.Name)" then
        pushFmt("name")
        pushFmt("instance")
    elseif mode == "动作+鱼名(Favorite+Name)" then
        pushFmt("action_name")
        pushFmt("action_instance")
        pushFmt("instance")
        pushFmt("name")
    else
        pushFmt("instance")
        pushFmt("name")
    end
    pushFmt("pure_name")
    pushFmt("action_instance")
    pushFmt("action_name")
    return order
end

function FG.NotifyFavUnlockBlocked()
    local now = tick()
    if now - FG.lastFavBlockNotify > 5.0 then
        FG.lastFavBlockNotify = now
        task.defer(function()
            if isRunning and ShowNotification then
                ShowNotification("🔒 保护鱼防误解", "该鱼在保护名单中，已拦截解锁！如需手动解锁，请先关闭「自动收藏并防卖」或从名单移除。", "WARN", 3.5)
            end
        end)
    end
end

function FG.IsFavToggleBlockedByHook(arg1, arg2)
    -- 仅当开启了「自动收藏并防卖」/「自动保护Boss鱼」/「材料收集模式」且该鱼属于当前保护鱼种时拦截外部解锁调用；
    -- 关闭上述开关或将该鱼移出保护选择后，玩家可在背包随时自由手动解锁！
    if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish) then
        return false
    end
    local target = (typeof(arg1) == "Instance" and arg1) or (typeof(arg2) == "Instance" and arg2) or nil
    if not target and type(arg1) == "string" then
        local pData = GetPlayerData()
        if pData then
            for _, fName in ipairs({"Inventory", "Hotbar"}) do
                local f = pData:FindFirstChild(fName)
                local found = f and f:FindFirstChild(arg1)
                if found then target = found; break end
            end
        end
    end
    if target and FG.ShouldProtectFishItem(target) then
        if FG.isInternalFavCall then
            -- 脚本内部上锁调用：仅当数据模型已明确处于白锁状态时拦截，确保首次上锁请求 100% 放行！
            return FG.IsFishItemDataFavorited(target)
        end
        if FG.IsFishItemFavorited(target) or FG.lastLockSentAt[target] then
            FG.NotifyFavUnlockBlocked()
            return true
        end
    end
    return false
end

if sharedEnv then
    sharedEnv.IdenticalIsFavToggleBlocked = FG.IsFavToggleBlockedByHook
end

-- ============================================================================
-- [防翻转单次上锁 + 突破50条限流队列] (融合 36max.txt 永久单次上锁记录与步进分批队列)：
--   1. FavoriteItem 在服务端是 Toggle（翻转开关）：对同一条已上锁的鱼再发一次请求会直接把它【解锁】！
--   2. 因此对每条鱼实例 item，生命周期内最多只发送 1 次上锁请求（lastLockSentAt[item] 与 lockConfirmedOrSent[item] 永久记录，绝不因 2s 过期清除重发）！
--   3. 当背包有 100+ 条保护鱼时，排入 pendingLockQueue 以 0.07s/条 步进发送，避免同帧突发丢包。
-- ============================================================================
function FG.ExecuteSingleLockNow(item, favRem)
    if not item or typeof(item) ~= "Instance" or not item.Parent then return false end
    if FG.IsNonFishEquipmentItem(item) or not FG.ShouldProtectFishItem(item) then return false end
    if FG.IsFishItemDataFavorited(item) then
        FG.lockConfirmedOrSent[item] = true
        FG.lastLockSentAt[item] = FG.lastLockSentAt[item] or tick()
        knownLockedUntil[item] = math.huge
        return false
    end
    favRem = favRem or (Events and Events:FindFirstChild("FavoriteItem")) or FG.GetFavoriteRemote()
    if not favRem then return false end

    local candidates = FG.BuildCandidateFavFormats()
    local firstFmt = candidates[1] or "instance"
    FG.lockingInFlight[item] = true
    local sendOk = FG.FireFormatOnce(favRem, item, firstFmt)
    FG.lockingInFlight[item] = nil

    if sendOk then
        local now = tick()
        FG.lockConfirmedOrSent[item] = true
        FG.lastLockSentAt[item] = now
        if item.Name and item.Name:find("|", 1, true) then
            FG.lastLockSentByName[item.Name] = now
        end
        FG.lastAnyLockSentAt = now
        knownLockedUntil[item] = math.huge
        return true
    end
    return false
end

function FG.StartBatchLockWorker()
    if FG.isBatchLockQueueRunning then return end
    FG.isBatchLockQueueRunning = true
    task.spawn(function()
        local batchSent = 0
        pcall(function()
            while isRunning and #FG.pendingLockQueue > 0 do
                local item = table.remove(FG.pendingLockQueue, 1)
                if item then
                    FG.inLockQueue[item] = nil
                    if item.Parent and not FG.IsFishItemFavorited(item) and not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                        local favRem = (Events and Events:FindFirstChild("FavoriteItem")) or FG.GetFavoriteRemote()
                        if favRem and FG.ExecuteSingleLockNow(item, favRem) then
                            batchSent = batchSent + 1
                            if batchSent % 45 == 0 then
                                task.wait(1.0)
                            elseif batchSent % 20 == 0 then
                                task.wait(0.45)
                            else
                                task.wait(0.07)
                            end
                        end
                    end
                end
            end
        end)
        FG.isBatchLockQueueRunning = false
        if isRunning and #FG.pendingLockQueue > 0 then
            FG.StartBatchLockWorker()
        end
    end)
end

function FG.TryLockSingleFishItem(item, favRem, now, forceResend)
    if not item or typeof(item) ~= "Instance" or FG.IsNonFishEquipmentItem(item) then
        return false, false
    end
    if FG.IsFishItemDataFavorited(item) then
        FG.lockConfirmedOrSent[item] = true
        FG.lastLockSentAt[item] = FG.lastLockSentAt[item] or (now or tick())
        FG.lockingInFlight[item] = nil
        return false, false
    end
    -- 若库存 UI 明确打开且识别到该卡已是白锁，直接记录已锁，绝不发送 Toggle 把原有白锁解开！
    if not forceResend and FG.GetGuiSlotLockState(item) == true then
        FG.lockConfirmedOrSent[item] = true
        FG.lastLockSentAt[item] = FG.lastLockSentAt[item] or (now or tick())
        return false, false
    end
    -- 对同一条鱼实例只发 1 次 FavoriteItem（与 36max.txt 一致），严禁周期性重发把已锁鱼翻转解锁！
    if not forceResend and (FG.lockConfirmedOrSent[item] or FG.lastLockSentAt[item] or (item.Name and item.Name:find("|", 1, true) and FG.lastLockSentByName[item.Name])) then
        FG.lockConfirmedOrSent[item] = true
        return false, false
    end
    if not FG.ShouldProtectFishItem(item) then
        return false, false
    end
    if FG.inLockQueue[item] or FG.lockingInFlight[item] then
        return true, false
    end

    FG.inLockQueue[item] = true
    table.insert(FG.pendingLockQueue, item)
    FG.StartBatchLockWorker()
    return true, true
end

function FG.EnsureBagAutoLockListeners(pData)
    if not pData then return end
    for _, folderName in ipairs({"Inventory", "Hotbar"}) do
        local folder = pData:FindFirstChild(folderName)
        if folder and not watchedBagFolders[folder] then
            watchedBagFolders[folder] = true
            table.insert(activeConnections, folder.ChildAdded:Connect(function(newItem)
                if not isRunning then return end
                if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) then return end
                task.delay(0.15, function()
                    if not isRunning or not newItem or not newItem.Parent then return end
                    local favRem = FG.GetFavoriteRemote()
                    FG.TryLockSingleFishItem(newItem, favRem, tick(), false)
                end)
            end))
        end
    end
end

-- 自动上锁：扫描 Inventory 与 Hotbar，对未发送过上锁的保护鱼执行单次防翻转上锁
TryFavoriteProtectedFish = function(pData, forceResendAll)
    pData = pData or GetPlayerData()
    if not pData or not Events then return 0, 0 end
    FG.EnsureBagAutoLockListeners(pData)
    local favRem = Events:FindFirstChild("FavoriteItem") or FG.GetFavoriteRemote()
    if not favRem then return 0, 0 end

    local now = tick()
    FG.RefreshGuiLockCache(now, forceResendAll == true)
    local unfavProtectedCount = 0
    local queuedCount = 0
    local bagNames = FG.bagFolderNames

    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                    if forceResendAll and not FG.IsFishItemDataFavorited(item) and FG.GetGuiSlotLockState(item) ~= true then
                        FG.lockConfirmedOrSent[item] = nil
                        FG.lastLockSentAt[item] = nil
                        if item.Name then FG.lastLockSentByName[item.Name] = nil end
                    end
                    if not FG.IsFishItemFavorited(item) then
                        unfavProtectedCount = unfavProtectedCount + 1
                        local _, didQueue = FG.TryLockSingleFishItem(item, favRem, now, forceResendAll)
                        if didQueue then
                            queuedCount = queuedCount + 1
                        end
                    end
                end
            end
        end
    end

    for k in pairs(knownLockedUntil) do
        if not k or not k.Parent then knownLockedUntil[k] = nil end
    end
    return unfavProtectedCount, queuedCount
end

-- 检查背包中是否还存在【尚未发送/完成上锁】的保护鱼
function FG.HasAnyUnlockedProtectedFishInBag(pData)
    if FG.isBatchLockQueueRunning or #FG.pendingLockQueue > 0 then
        return true, "分批上锁队列处理中"
    end
    pData = pData or GetPlayerData()
    if not pData then return false, nil end
    local bagNames = FG.bagFolderNames
    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsFishItemFavorited(item) and not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                    return true, FG.GetFishItemPrimaryPureName(item)
                end
            end
        end
    end
    return false, nil
end

-- 检查是否有正在执行的分批上锁队列或刚发出不到 1.2s 的上锁请求
function FG.HasAnyLockSettlingInBag(pData)
    if FG.isBatchLockQueueRunning or #FG.pendingLockQueue > 0 then
        return true
    end
    local now = tick()
    if FG.lastAnyLockSentAt > 0 and (now - FG.lastAnyLockSentAt) < 1.2 then
        return true
    end
    pData = pData or GetPlayerData()
    if not pData then return false end
    local bagNames = FG.bagFolderNames
    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if FG.lockingInFlight[item] or FG.inLockQueue[item] then
                    return true
                end
                local sentAt = FG.lastLockSentAt[item]
                if sentAt and (now - sentAt) < 1.2 then
                    return true
                end
            end
        end
    end
    return false
end

-- 发包级黑名单拦截器（同时挂载到 SafeSellAllFish 与全局 __namecall Hook）：
--   1. 只要出售参数命中受保护鱼名或受保护/已锁实例，直接拦截丢弃该卖鱼包！
--   2. 对 SellFish("All") 全体出售包：若背包中仍有任何未完成上锁或刚发包未满 1.2s 的保护鱼，一律严格拦截！
function FG.IsSellPacketArgBlacklisted(arg)
    if arg == nil then
        local hasUnlockedProt = FG.HasAnyUnlockedProtectedFishInBag()
        if hasUnlockedProt then pcall(TryFavoriteProtectedFish, GetPlayerData(), false) end
        return hasUnlockedProt or FG.HasAnyLockSettlingInBag()
    end
    if type(arg) == "string" then
        local low = arg:lower():match("^%s*(.-)%s*$")
        if low == "" or low == "all" or low == "sellall" or low == "*" or low == "everything" or low == "inventory" then
            local hasUnlockedProt = FG.HasAnyUnlockedProtectedFishInBag()
            if hasUnlockedProt then pcall(TryFavoriteProtectedFish, GetPlayerData(), false) end
            return hasUnlockedProt or FG.HasAnyLockSettlingInBag()
        end
        if FG.IsFishNameStringBlacklisted(arg) then
            return true
        end
        local pData = GetPlayerData()
        if pData then
            for _, fName in ipairs({"Inventory", "Hotbar"}) do
                local f = pData:FindFirstChild(fName)
                local inst = f and f:FindFirstChild(arg)
                if inst and (FG.ShouldProtectFishItem(inst) or FG.IsFishItemFavorited(inst)) then
                    return true
                end
            end
        end
        return false
    elseif typeof(arg) == "Instance" then
        if FG.IsNonFishEquipmentItem(arg) or FG.ShouldProtectFishItem(arg) or FG.IsFishItemFavorited(arg) then
            return true
        end
        return false
    elseif type(arg) == "table" then
        for k, v in pairs(arg) do
            if FG.IsSellPacketArgBlacklisted(k) or FG.IsSellPacketArgBlacklisted(v) then
                return true
            end
        end
    end
    return false
end

if sharedEnv then
    sharedEnv.IdenticalIsSellArgBlocked = FG.IsSellPacketArgBlacklisted
end

function FG.SafeFireSellFishRemote(sellRem, arg)
    if not sellRem or arg == nil then return false end
    if type(arg) == "string" and arg:match("^%s*$") then return false end
    if FG.IsSellPacketArgBlacklisted(arg) then
        return false
    end
    if sellRem:IsA("RemoteEvent") then
        local ok = pcall(function() sellRem:FireServer(arg) end)
        return ok
    elseif sellRem:IsA("RemoteFunction") then
        local ok = pcall(function()
            task.spawn(function()
                pcall(function() sellRem:InvokeServer(arg) end)
            end)
        end)
        return ok
    end
    return false
end

-- 逐条安全出售非保护普通鱼（与 36max.txt 一致：自动探测 instance/name 参数格式，严格跳过所有保护鱼与已锁鱼）
function FG.SellUnlockedNormalFishOnly(sellRem, sellableItems, protectedPureSet)
    if not sellRem or not sellableItems or #sellableItems == 0 then return 0, true end
    local batchParamMode = (singleSellFormat == "name") and "name" or "instance"
    local probeSwitched = false
    local successCount = 0
    local singleSellSupported = true

    for idx, normalItem in ipairs(sellableItems) do
        if not isRunning then break end
        if normalItem and normalItem.Parent then
            local pureLow = FG.GetFishItemPrimaryPureName(normalItem):lower()
            local isSafeToSell = (not protectedPureSet or not protectedPureSet[pureLow])
                and (not FG.ShouldProtectFishItem(normalItem))
                and (not FG.IsFishItemFavorited(normalItem))
                and (not FG.IsSellPacketArgBlacklisted(normalItem))
                and (not FG.IsSellPacketArgBlacklisted(normalItem.Name))
            if isSafeToSell then
                local arg = (batchParamMode == "name") and normalItem.Name or normalItem
                FG.SafeFireSellFishRemote(sellRem, arg)
                task.wait(idx == 1 and 0.14 or 0.06)
                if idx == 1 and normalItem.Parent and not probeSwitched then
                    probeSwitched = true
                    batchParamMode = (batchParamMode == "instance") and "name" or "instance"
                    local altArg = (batchParamMode == "name") and normalItem.Name or normalItem
                    FG.SafeFireSellFishRemote(sellRem, altArg)
                    task.wait(0.14)
                end
                if not normalItem.Parent then
                    successCount = successCount + 1
                elseif idx == 1 then
                    singleSellSupported = false
                    break
                end
            end
        end
    end

    if successCount >= 1 then
        singleSellFormat = (batchParamMode == "name") and "name" or "instance"
    end
    return successCount, singleSellSupported
end

-- 铁壁级黑名单安全卖鱼引擎（完整恢复 36max.txt 核心防误卖机制）：
--   1. 卖鱼前先对未上锁保护鱼执行单次防翻转上锁（TryFavoriteProtectedFish）并等待队列与服务端落锁完成；
--   2. 核心铁律：只要背包/快捷栏里存在哪怕 1 条命中保护名单/黑名单的鱼（#protectedNames > 0），
--      无论其服务端白锁是否显示已锁（哪怕超过服务端 50 条白锁上限），都【绝对禁止】直接裸发未受控的全卖，
--      优先逐条只卖白名单普通鱼；若服务端接口仅响应全卖，则必须在确认包内全部保护鱼 100% 完成上锁后才放行！
SafeSellAllFish = function(pData)
    if isSellingInProgress or not Events or not Events:FindFirstChild("SellFish") then return end
    isSellingInProgress = true

    task.spawn(function()
        pcall(function()
            local sellRem = Events:FindFirstChild("SellFish")
            pData = pData or GetPlayerData()
            if not sellRem or not pData then return end

            local char = LocalPlayer.Character
            if char and IsCharacterHoldingFishingRod and not IsCharacterHoldingFishingRod(char, pData) then
                if EnsureFishingRodEquipped then pcall(EnsureFishingRodEquipped) end
                task.wait(0.12)
            end

            local protectedNames = {}
            local protectedPureSet = {}
            local sellableItems = {}

            local function ScanBagState()
                table.clear(protectedNames)
                table.clear(protectedPureSet)
                table.clear(sellableItems)
                local containers = { pData:FindFirstChild("Inventory"), pData:FindFirstChild("Hotbar") }
                for _, folder in ipairs(containers) do
                    if folder then
                        for _, item in ipairs(folder:GetChildren()) do
                            if not FG.IsNonFishEquipmentItem(item) then
                                local pure = FG.GetFishItemPrimaryPureName(item)
                                local pureLow = pure:lower()
                                if FG.ShouldProtectFishItem(item) or FG.IsFishItemFavorited(item) then
                                    protectedPureSet[pureLow] = true
                                    table.insert(protectedNames, pure)
                                else
                                    table.insert(sellableItems, item)
                                end
                            end
                        end
                    end
                end
                local bp = LocalPlayer:FindFirstChild("Backpack")
                if bp then
                    for _, item in ipairs(bp:GetChildren()) do
                        if not FG.IsNonFishEquipmentItem(item) and (FG.ShouldProtectFishItem(item) or FG.IsFishItemFavorited(item)) then
                            local pure = FG.GetFishItemPrimaryPureName(item)
                            protectedPureSet[pure:lower()] = true
                            table.insert(protectedNames, pure)
                        end
                    end
                end
            end

            TryFavoriteProtectedFish(pData, false)
            local waitStart = tick()
            local maxWait = math.clamp(2.0 + (#FG.pendingLockQueue * 0.10), 2.0, 12.0)
            while isRunning and (FG.HasAnyUnlockedProtectedFishInBag(pData) or FG.HasAnyLockSettlingInBag(pData)) and (tick() - waitStart < maxWait) do
                task.wait(0.15)
            end
            ScanBagState()

            -- 若背包内根本没有可出售的普通鱼（例如只有受保护的 Wraith Orca），直接跳过，绝不发任何卖鱼包！
            if #sellableItems == 0 then
                return
            end

            -- 双擎防误卖安全出售（融合 36max.txt 逐条白名单出售 + 全锁确认后全卖兜底）：
            -- 1) 若包内无任何保护鱼（#protectedNames == 0），直接发送 SellFish("All")；
            -- 2) 若包内有保护鱼（如 Wraith Orca），优先按 36max.txt 逐条出售普通鱼（sellableItems）；
            -- 3) 若服务端仅响应 "All"（首条单卖探测后仍在背包），则仅在确认包内全部保护鱼均已完成单次白锁且满 1.2s 落锁期后才发送 "All"，任何一条未锁则绝对拦截！
            if #protectedNames == 0 then
                FG.SafeFireSellFishRemote(sellRem, "All")
            else
                local successCount, singleSellSupported = FG.SellUnlockedNormalFishOnly(sellRem, sellableItems, protectedPureSet)
                if successCount >= 1 then
                    ShowNotification(
                        "黑名单防误卖已生效",
                        string.format("已保护 [%s] 等 %d 条目标鱼不卖，仅安全出售其余 %d 条普通鱼！", tostring(protectedNames[1]), #protectedNames, successCount),
                        "SUCCESS",
                        3.5
                    )
                elseif not singleSellSupported then
                    -- 服务端 SellFish 仅支持 "All" 参数：再次确认全部保护鱼均已上好白锁且满 1.2s 落锁期后才放行
                    if not FG.HasAnyUnlockedProtectedFishInBag(pData) and not FG.HasAnyLockSettlingInBag(pData) then
                        FG.SafeFireSellFishRemote(sellRem, "All")
                        ShowNotification(
                            "白锁防误卖已生效",
                            string.format("已确认 [%s] 等 %d 条目标鱼全部上锁保护，已安全出售普通鱼！", tostring(protectedNames[1]), #protectedNames),
                            "SUCCESS",
                            3
                        )
                    else
                        ShowNotification(
                            "防误卖保护已拦截",
                            string.format("检测到保护鱼 [%s] 尚未完成服务端白锁，已取消本次出售以防误卖！", tostring(protectedNames[1])),
                            "WARN",
                            3.5
                        )
                    end
                end
            end
        end)
        task.wait(0.2)
        isSellingInProgress = false
    end)
end

-- 安全触发 ProximityPrompt 交互
TriggerPrompt = function(prompt)
    if not prompt or not prompt.Parent or not prompt.Enabled then return end
    if type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
    else
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

local GUI_CONN_SIGNALS = {"Activated", "MouseButton1Click", "TouchTap"}
local GUI_FIRE_SIGNALS = {"Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "TouchTap"}
FireGuiButton = function(btn)
    if not btn or not btn:IsA("GuiButton") or not btn.Visible or not btn.Active then return false end
    local firedAny = false
    if type(getconnections) == "function" then
        pcall(function()
            for i = 1, #GUI_CONN_SIGNALS do
                local sig = btn[GUI_CONN_SIGNALS[i]]
                if sig then
                    local conns = getconnections(sig)
                    if type(conns) == "table" and #conns > 0 then
                        local sigFired = false
                        for _, conn in ipairs(conns) do
                            if type(conn.Fire) == "function" then
                                conn:Fire()
                                sigFired = true
                            elseif type(conn.Function) == "function" then
                                task.spawn(conn.Function)
                                sigFired = true
                            end
                        end
                        if sigFired then
                            firedAny = true
                            break
                        end
                    end
                end
            end
        end)
    end
    if not firedAny and type(firesignal) == "function" then
        for i = 1, #GUI_FIRE_SIGNALS do
            local sig = btn[GUI_FIRE_SIGNALS[i]]
            if sig then
                if pcall(firesignal, sig) then
                    firedAny = true
                end
            end
        end
    end
    return firedAny
end

-- ============================================================================
-- 【模块 16：【钓鱼】页面经济/防卖配置 UI 与【Boss】页面构建（无名章鱼 / 恩佐 / 龙钓海）】
-- ============================================================================
do -- Economy & Sell UI Sub-Scope (独立 do-end 块及时释放 UI 局部寄存器)
createCategoryHeader(tabFishing, "经济与出售")
local sellCard = createCardGroup(tabFishing)
createToggleRow(sellCard, "自动卖鱼", "定期安全出售普通鱼（保护名单内的鱼绝不卖）", Config.AutoSell, function(v)
    Config.AutoSell = v
    if v then
        if DashUI and DashUI._resetSellTimer then DashUI._resetSellTimer() end
        local pData = GetPlayerData()
        if pData and TryFavoriteProtectedFish then
            pcall(TryFavoriteProtectedFish, pData, false)
        end
    end
end, "AutoSell")
createSliderRow(sellCard, "出售间隔(秒)", "出售鱼的频率 (10秒-60分钟)", 10, 3600, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end, "SellInterval")
createButtonRow(sellCard, "立即出售并传送到娜娜", "传送到娜娜处并安全出售非保护鱼", "立即出售", function()
    local pData = GetPlayerData()
    if SafeTeleport(CFrame.new(-203.5, 7.3, 107.1)) then
        task.wait(0.3)
        SafeSellAllFish(pData)
    end
end)

local baseFishList = {
    "Wraith Orca", "Colossal Tigerfish", "Heavenpiercer Turtle", "Golden Guardian Fish",
    "Golden Dragon Fish", "Dark Kingfish", "Mountain Dragon Whale",
    "Crimson Electric Eel", "Frost Kingfish", "Frost Queenfish",
    "Ascended Perch", "Primordial Kunfish Overlord", "Warbringer Shark",
    "Mountain Fish", "Tiger Mirefish", "Mirage Lanternfish",
    "Octoparasitic Fish", "Rainbow Dragonfish", "Sanguine Fish",
    "Crimson Catfish", "Elder Scarlet Fish", "Scarlet Fish", "Catfish"
}
-- 启动时自动扫描玩家当前背包与快捷栏中的鱼种并置顶加入下拉框，方便直接手动选择单种或多种鱼进行保护
do
    local initPData = GetPlayerData()
    if initPData then
        local seenInit = {}
        local mergedInit = {}
        for _, folderName in ipairs({"Inventory", "Hotbar"}) do
            local f = initPData:FindFirstChild(folderName)
            if f then
                for _, item in ipairs(f:GetChildren()) do
                    if not FG.IsNonFishEquipmentItem(item) then
                        local pure = FG.GetFishItemPrimaryPureName(item)
                        if pure ~= "" and not seenInit[pure] then
                            seenInit[pure] = true
                            table.insert(mergedInit, pure)
                        end
                    end
                end
            end
        end
        for _, name in ipairs(baseFishList) do
            if not seenInit[name] then
                seenInit[name] = true
                table.insert(mergedInit, name)
            end
        end
        baseFishList = mergedInit
    end
end

createToggleRow(sellCard, "自动收藏并防卖", "打开后：对你选中的「收藏目标」或「保护名单」内的鱼自动上锁且永不出售", Config.AutoFavouriteFish, function(v)
    Config.AutoFavouriteFish = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
        local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or ""
        if listStr == "" then
            ShowNotification("自动收藏已开启", string.format("当前单选保护鱼种: [%s]（自动卖鱼绝不出售）", tostring(Config.FavouriteFishName or "无")), "SUCCESS", 3)
        else
            ShowNotification("自动收藏已开启", string.format("当前保护目标: [%s] + 名单[%s]", tostring(Config.FavouriteFishName or ""), listStr), "SUCCESS", 3)
        end
    else
        table.clear(FG.pendingLockQueue)
        table.clear(FG.inLockQueue)
        ShowNotification("自动上锁已暂停", "已暂停后台自动上锁（但选中的收藏目标在自动卖鱼时仍受黑名单保护不卖）！", "INFO", 3)
    end
end, "AutoFavouriteFish")

local customFavBox = nil
-- 「收藏目标」下拉框：选中即立即生效保护并触发上锁（即使旧配置曾关闭自动收藏开关也会自动联动开启）
local favDropdownCtrl = createDropdownRow(sellCard, "收藏目标", "单选保护：直接选中即保护该鱼种绝不出售；需保护多种鱼请点下方「加入/移除」", baseFishList, Config.FavouriteFishName, function(v)
    Config.FavouriteFishName = v
    if not Config.AutoFavouriteFish then
        Config.AutoFavouriteFish = true
        if UIControls and UIControls["AutoFavouriteFish"] and UIControls["AutoFavouriteFish"].Set then
            pcall(UIControls["AutoFavouriteFish"].Set, true)
        end
    end
    local pData = GetPlayerData()
    if TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, pData, false)
    end
    local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or ""
    if listStr == "" then
        ShowNotification("单选保护目标已生效", string.format("已锁定保护: [%s]（自动卖鱼时绝不出售）", tostring(v)), "SUCCESS", 2.5)
    else
        ShowNotification("已切换保护目标", string.format("当前保护: [%s] | 多选名单: %s", tostring(v), listStr), "SUCCESS", 2.5)
    end
end, "FavouriteFishName")

createToggleRow(sellCard, "自动保护 Boss/神话稀有鱼", "可选：开启后按关键词/稀有度自动保护全部 Boss 与神话鱼", Config.AutoProtectRareBossFish, function(v)
    Config.AutoProtectRareBossFish = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "AutoProtectRareBossFish")
createToggleRow(sellCard, "材料收集模式", "可选：开启后自动保护制作神话鱼饵所需的材料鱼", Config.MaterialFarming, function(v)
    Config.MaterialFarming = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "MaterialFarming")

do
    local listRow = createBaseRow(sellCard, "收藏/保护名单", "可手改；支持 Wraith*、*Orca、=精确名、中文译名，逗号分隔", true)
    listRow.Size = UDim2.new(1, 0, 0, 56)
    customFavBox = Instance.new("TextBox")
    customFavBox.Size = UDim2.new(0, 220, 0, 40)
    customFavBox.Position = UDim2.new(1, -220, 0.5, -20)
    customFavBox.BackgroundColor3 = Colors.ControlBg
    customFavBox.Font = Enum.Font.GothamBold
    customFavBox.Text = Config.CustomProtectedFish or ""
    customFavBox.PlaceholderText = "例: Wraith Orca, Wraith*"
    customFavBox.TextColor3 = Colors.PurplePrimary
    customFavBox.PlaceholderColor3 = Colors.TextMuted
    customFavBox.TextSize = 10
    customFavBox.TextWrapped = true
    customFavBox.MultiLine = false
    customFavBox.BorderSizePixel = 0
    customFavBox.ClearTextOnFocus = false
    customFavBox.Parent = listRow
    Instance.new("UICorner", customFavBox).CornerRadius = UDim.new(0, 4)
    customFavBox:GetPropertyChangedSignal("Text"):Connect(function()
        Config.CustomProtectedFish = customFavBox.Text
    end)
    customFavBox.FocusLost:Connect(function()
        Config.CustomProtectedFish = customFavBox.Text
        local pData = GetPlayerData()
        TryFavoriteProtectedFish(pData, false)
        ShowNotification("名单已更新", "正在对背包中的匹配鱼尝试收藏", "SUCCESS", 2.5)
    end)
    UIControls["CustomProtectedFish"] = { Set = function(val) customFavBox.Text = tostring(val or "") end }
end

createDropdownRow(sellCard, "上锁发包模式", "默认使用实例对象(item)，切换模式后自动对匹配鱼重新发送上锁", {
    "实例对象(item)",
    "完整鱼名(item.Name)",
    "智能探测(自动对比状态)",
    "动作+鱼名(Favorite+Name)",
    "多格式兼容连发(方案二)"
}, Config.FavPacketMode or "实例对象(item)", function(v)
    Config.FavPacketMode = v
    FG.verifiedSmartFavFormat = nil
    local pData = GetPlayerData()
    if pData and TryFavoriteProtectedFish then
        FG.RefreshGuiLockCache(tick(), true)
        local _, sentN = TryFavoriteProtectedFish(pData, false)
        ShowNotification("上锁模式已切换", string.format("当前模式: %s | 已将 %d 条未上锁保护鱼排入分批上锁队列！", tostring(v), sentN or 0), "SUCCESS", 3.5)
    else
        ShowNotification("上锁模式已切换", string.format("当前模式: %s", tostring(v)), "SUCCESS", 2.5)
    end
end, "FavPacketMode")

createButtonRow(sellCard, "立即收藏背包匹配鱼", "扫描背包，分批突破50条限制，对全部100+条匹配鱼稳定发送上锁指令", "立即收藏", function()
    local pData = GetPlayerData()
    if not pData then
        ShowNotification("收藏失败", "未读取到玩家数据", "WARN")
        return
    end
    FG.RefreshGuiLockCache(tick(), true)
    local favRem = FG.GetFavoriteRemote()
    local remName = favRem and favRem.Name or "未找到Remote"
    local unfavCount, queuedCount = TryFavoriteProtectedFish(pData, false)
    if (queuedCount or 0) == 0 and #FG.pendingLockQueue == 0 then
        unfavCount, queuedCount = TryFavoriteProtectedFish(pData, true)
    end
    local qTotal = #FG.pendingLockQueue
    ShowNotification(
        "分批全量上锁已启动",
        string.format("已排入队列: %d 条（当前待处理: %d 条，自动突破50条限流）\n接口: %s | 模式: %s", queuedCount or unfavCount or 0, qTotal, remName, tostring(Config.FavPacketMode or "实例对象(item)")),
        "SUCCESS",
        4.5
    )
end)

createButtonRow(sellCard, "[诊断] 查看鱼锁接口与背包数据结构", "扫描 Events 中的真实上锁事件名与背包样本鱼的属性/子节点结构并复制到剪贴板", "诊断鱼锁", function()
    local remList = {}
    if Events then
        for _, ch in ipairs(Events:GetChildren()) do
            local low = ch.Name:lower()
            if low:find("fav", 1, true) or low:find("lock", 1, true) or low:find("sell", 1, true) or low:find("item", 1, true) or low:find("fish", 1, true) then
                table.insert(remList, ch.Name .. "(" .. ch.ClassName:gsub("Remote", "") .. ")")
            end
        end
    end
    local fishInfo = "背包为空"
    local pData = GetPlayerData()
    if pData and pData:FindFirstChild("Inventory") then
        local items = pData.Inventory:GetChildren()
        if #items > 0 then
            local sample = items[1]
            for _, it in ipairs(items) do
                if it.Name:lower():find("wraith", 1, true) or it.Name:lower():find("orca", 1, true) then
                    sample = it
                    break
                end
            end
            local valStr = sample:IsA("ValueBase") and ("=" .. tostring(sample.Value)) or ""
            local attrParts = {}
            local okA, aMap = pcall(function() return sample:GetAttributes() end)
            if okA and type(aMap) == "table" then
                for k, v in pairs(aMap) do table.insert(attrParts, tostring(k) .. "=" .. tostring(v)) end
            end
            local childParts = {}
            for _, c in ipairs(sample:GetChildren()) do
                local cv = c:IsA("ValueBase") and ("=" .. tostring(c.Value)) or ("(" .. c.ClassName .. ")")
                table.insert(childParts, c.Name .. cv)
            end
            fishInfo = string.format("%s [%s%s] 属性:{%s} 子项:{%s}", sample.Name, sample.ClassName, valStr, table.concat(attrParts, ","), table.concat(childParts, ","))
        end
    end
    local msg = string.format("接口: %s\n样本鱼: %s", (#remList > 0 and table.concat(remList, ", ") or "无"), fishInfo)
    if type(setclipboard) == "function" then pcall(function() setclipboard(msg) end) end
    ShowNotification("鱼锁结构诊断 (已复制)", msg, "SUCCESS", 8)
end)

createButtonRow(sellCard, "预览：哪些会保护 / 出售", "扫描背包，显示保护与可卖列表", "预览结果", function()
    local pData = GetPlayerData()
    if not pData then
        ShowNotification("预览失败", "未读取到玩家背包数据。", "WARN")
        return
    end
    FG.RefreshGuiLockCache(tick(), true)
    if Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.MaterialFarming or Config.AutoSell then
        TryFavoriteProtectedFish(pData, false)
    end
    local protList, sellList = {}, {}
    for _, folderName in ipairs(FG.bagFolderNames) do
        local folder = pData:FindFirstChild(folderName)
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsNonFishEquipmentItem(item) then
                    local pure = FG.GetFishItemPrimaryPureName(item)
                    local lockedTag = (FG.IsFishItemFavorited(item) or FG.IsFishLockProtected(item)) and "[已锁]" or "[防卖]"
                    if FG.ShouldProtectFishItem(item) or FG.IsFishLockProtected(item) then
                        table.insert(protList, pure .. lockedTag)
                    else
                        table.insert(sellList, pure)
                    end
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
        "背包预览",
        string.format("保护(%d): %s\n可卖(%d): %s", #protList, SummarizeList(protList), #sellList, SummarizeList(sellList)),
        "SUCCESS",
        8
    )
end)

createButtonRow(sellCard, "将收藏目标加入/移出名单", "多选开关：把上方选中的鱼加入多选名单；若已在名单中再次点击即可移除", "加入/移除", function()
    local target = FG.GetPureFishName(Config.FavouriteFishName)
    if not target or target == "" then return end
    local targetLow = target:lower()
    local cur = Config.CustomProtectedFish or ""
    local kept = {}
    local removed = false
    for token in string.gmatch(cur, "([^,，;；\n\r]+)") do
        local trimmed = token:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            local cleanLow = FG.GetPureFishName(trimmed:gsub("^=", "")):lower()
            if cleanLow == targetLow then
                removed = true
            else
                table.insert(kept, trimmed)
            end
        end
    end
    if removed then
        Config.CustomProtectedFish = table.concat(kept, ",")
        if customFavBox then customFavBox.Text = Config.CustomProtectedFish end
        if Config.CustomProtectedFish == "" then
            ShowNotification("已从多选名单移除", string.format("已移除 [%s]，多选名单已清空（当前仅保护上方单选目标）！", target), "INFO", 3)
        else
            ShowNotification("已从多选名单移除", string.format("已移除 [%s] | 当前名单: %s", target, Config.CustomProtectedFish), "INFO", 3)
        end
    else
        table.insert(kept, target)
        Config.CustomProtectedFish = table.concat(kept, ",")
        if customFavBox then customFavBox.Text = Config.CustomProtectedFish end
        if not Config.AutoFavouriteFish then
            Config.AutoFavouriteFish = true
            if UIControls and UIControls["AutoFavouriteFish"] and UIControls["AutoFavouriteFish"].Set then
                pcall(UIControls["AutoFavouriteFish"].Set, true)
            end
        end
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then
            pcall(TryFavoriteProtectedFish, pData, false)
        end
        ShowNotification("已加入多选保护名单", string.format("已添加 [%s]（共 %d 种鱼受保护，再次点击可移除）！", target, #kept), "SUCCESS", 3)
    end
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
                    local pure = FG.GetFishItemPrimaryPureName(item)
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
end -- end of Economy & Sell UI Sub-Scope

-- ==========================================
-- Boss 页面 (完全对齐 V1.0 稳定版布局：无名章鱼寄生体 + 恩佐/龙钓海 + 自动传送防冲突)
-- ==========================================
TeleportToDragonSea = function()
    -- 优先在 Workspace / BossSetUp / Islands / Map 中查找龙钓海 / Mountain Dragon Whale / Dragon 实体或区域坐标，兜底前往雾峰岛龙域
    local targetPos = nil
    local searchFolders = {}
    for _, fName in ipairs({"BossSetUp", "Islands", "Map"}) do
        local f = Workspace:FindFirstChild(fName)
        if f then table.insert(searchFolders, f) end
    end
    table.insert(searchFolders, Workspace)
    for _, folder in ipairs(searchFolders) do
        for _, ch in ipairs(folder:GetChildren()) do
            local cn = (ch.Name or ""):lower()
            if cn:find("dragon") or cn:find("whale") or cn:find("long") or cn:find("龙") then
                local p = GetNPCPosition(ch)
                if p then targetPos = p; break end
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

do -- Boss UI Sub-Scope
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
        if DashUI._resetBossTimer then DashUI._resetBossTimer() end
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
        if DashUI._resetBossTimer then DashUI._resetBossTimer() end
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
end -- end of Boss UI Sub-Scope
end -- end of Sell and Boss UI scope

-- ==========================================
-- V5.0 全图深度 NPC 雷达 + 双引擎对话 (直连 + 岛屿流式预加载微瞬移) + 一键传送
-- ==========================================
-- ============================================================================
-- 【模块 17：V5.0 全图深度 NPC 数据库、ProximityPrompt 零污染触发与双引擎远程对话系统】
-- 作用说明：
--   1. 定义 10 大岛屿中心坐标 IslandCenters、全量任务/商店/门派/流动商人数据库 ImportantDialogueNPCs、
--      三岛神灵表 ThreeSpiritsSpecs 以及四圣兽表 FourSacredBeastsSpecs；
--   2. 全局唯一一对 DescendantAdded/Removing 实时维护 cachedAllPrompts 与 cachedBossPrompts，配合脏标记
--      hasPollutedPrompts 在触发远端交互后立即恢复原始距离并清除粘滞弹窗；
--   3. OpenRemoteNPCDialogue() 双引擎：先尝试原位零位移直连，未弹出对话框时自动执行流式预加载 + 微瞬移贴脸触发并瞬间归位。
-- 后续修改指引：
--   - 若需新增可对话/可传送的 NPC，只需在 ImportantDialogueNPCs 表中按相同格式追加一条配置即可自动生成双按钮行并接入雷达。
-- ============================================================================
do -- NPC Engine, God & Quests Scope
-- 安全调用单个 RemoteEvent 或异步调用 RemoteFunction，捕获并隔离异常
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

-- 根据世界坐标计算距离最近的岛屿信息与直线距离
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
TryStreamAroundPosition = function(pos)
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
    {cnName = "亚索 (Yasuo)", internalName = "Yasuo", desc = "主线任务 (鲈鱼岛/战场岛/雾峰岛 疾风剑豪斩风钓法全套技能)", aliases = {"Yasuo", "Wind", "Swordsman", "Wanderer", "Ronin", "Chem Gio", "Triple Cut"}, fallbackPos = Vector3.new(-62.0, 11.9, -1321.4), altPositions = {Vector3.new(-62.0, 11.9, -1321.4), Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(65.5, 8.8, 1181.3)}},

    -- 4. 流动商人 / 隐藏商人（含英/中/越文全别名与 liveKey 实时坐标联动）
    {cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", liveKey = "Taoist", desc = "流动商人 (100M道士珠 / 200M极鹰猎 / 接取「三个神灵」任务)", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi", "XiaoDaoshi", "Tieu Dao Si", "TieuDaoSi", "Tiểu Đạo Sĩ", "Đạo Sĩ", "Dao Si", "Little Taoist", "道士", "小道士"}, fallbackPos = nil, isRoaming = true},
    {cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", liveKey = "Maoshan", desc = "流动商人 (300M茅山竿 / 200M茅山珠 / 200M镇江技能)", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan", "Mao Son", "MaoSon", "Mao Sơn", "Dai Su Huynh", "DaiSuHuynh", "Đại Sư Huynh", "茅山", "大师兄"}, fallbackPos = nil, isRoaming = true},
    {cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", liveKey = "DumbGuy", desc = "轮换隐藏商人 (六脉神鹰 Six Vein Divine Hawk / 道士商店卡)", aliases = {"Dumb Guy", "Dumb Man", "Dumb", "Thang Ngu", "ThangNgu", "Thằng Ngu", "Thằng Ngốc", "Thang Ngoc", "傻子", "笨蛋"}, fallbackPos = nil, isRoaming = true},
}

-- 三个神灵专属配置表（支持英/中/越文模型名、祭坛名与交互提示词匹配）
local ThreeSpiritsSpecs = {
    {
        liveKey = "Spirit_Bamboo",
        cnName = "神灵 #1 · 竹岛神灵 (Bamboo Isle)",
        internalName = "Spirit",
        islandName = "[2] 竹岛",
        desc = "竹岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得竹岛神灵祝福)",
        aliases = {"Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Bamboo Spirit", "Green Spirit", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "竹岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1223.0, 7.3, -24.1),
        preferPos = Vector3.new(-1223.0, 7.3, -24.1),
    },
    {
        liveKey = "Spirit_Frost",
        cnName = "神灵 #2 · 冰霜岛神灵 (Frost Isle)",
        internalName = "Spirit",
        islandName = "[6] 冰霜岛",
        desc = "冰霜岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得霜岛神灵祝福)",
        aliases = {"Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Frost Spirit", "Blue Spirit", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "冰霜神灵", "冰霜岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4),
        preferPos = Vector3.new(-1366.0, 11.9, -1495.4),
    },
    {
        liveKey = "Spirit_Amber",
        cnName = "神灵 #3 · 琥珀岛神灵 (Amber Isle)",
        internalName = "Spirit",
        islandName = "[8] 琥珀岛",
        desc = "琥珀岛祭坛 · 每次祈祷花费 50M Cash (集齐三岛祝福解锁幻影灯笼鱼克制技)",
        aliases = {"Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Amber Spirit", "Yellow Spirit", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "琥珀神灵", "琥珀岛神灵", "祭坛", "祈祷"},
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
        aliases = {"Vermilion Bird", "Vermillion Bird", "Vermilion", "Vermillion", "Chu Tuoc", "ChuTuoc", "Chu Tước", "Phoenix", "Phượng Hoàng", "朱雀"},
        desc = "0.1%神话特质(-50%冷却+25%伤害+重置CD) / 朱雀Boss (Vermilion Bird Li)",
        color = Colors.AccentRed,
    },
    {
        liveKey = "BlackTortoise",
        cnName = "🐢 玄武 (Black Tortoise)",
        engName = "Black Tortoise",
        aliases = {"Black Tortoise", "Tortoise", "Huyen Vu", "HuyenVu", "Huyền Vũ", "Black Tortoise Bloodline", "玄武"},
        desc = "0.1%神话特质(+15%回血+30%伤害+眩晕+低血20秒无敌) / 玄武血脉Boss",
        color = Colors.AccentBlue,
    },
    {
        liveKey = "WhiteTiger",
        cnName = "🐯 白虎 (White Tiger)",
        engName = "White Tiger",
        aliases = {"White Tiger", "WhiteTiger", "Bach Ho", "BachHo", "Bạch Hổ", "白虎"},
        desc = "0.1%神话特质(+50%暴击率+100%暴击伤害+每次释放叠5%暴击)",
        color = Colors.TextWhite,
    },
    {
        liveKey = "AzureDragon",
        cnName = "🐉 青龙 (Azure Dragon)",
        engName = "Azure Dragon",
        aliases = {"Azure Dragon", "Thanh Long", "AzureDragon", "ThanhLong", "Rồng Xanh", "青龙"},
        desc = "0.1%神话特质(+100~150%伤害-20%冷却+低血穿透Boss无敌)",
        color = Colors.AccentGreen,
    },
}

for _, bSpec in ipairs(FourSacredBeastsSpecs) do
    bSpec.lowerAliases = {}
    for _, al in ipairs(bSpec.aliases) do
        table.insert(bSpec.lowerAliases, al:lower())
    end
end

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

-- 判断实例是否为整座岛屿或地图级顶层大容器（防止把整座岛屿 Model 当作单个 NPC 聚合）
IsMapOrIslandContainer = function(inst)
    if not inst or inst == Workspace then return true end
    local nLow = (inst.Name or ""):lower()
    if nLow == "map" or nLow == "islands" or nLow == "world" or nLow == "npc" or nLow == "npcs"
        or nLow == "interactables" or nLow == "dialoguenpcs" or nLow == "questnpcs"
        or nLow == "bosssetup" or nLow == "fishes" or nLow == "boat" or nLow == "boats"
        or nLow == "vehicles" or nLow == "secretrod" or nLow == "secretrods" or nLow == "rods"
        or nLow == "shrines" or nLow == "spirits" or nLow == "merchants" then
        return true
    end
    if nLow:find(" isle", 1, true) or nLow:find("island", 1, true) then
        return true
    end
    return false
end

-- 从 ProximityPrompt 向上反查所属的具体 NPC / 神灵祭坛实例（兼容 Model、BasePart 与独立子 Folder，绝不误取整座岛屿容器）
ResolvePromptEntity = function(pr)
    if not pr or not pr.Parent then return nil end
    local cur = pr.Parent
    local bestModel = nil
    local depth = 0
    while cur and cur ~= Workspace and depth < 5 do
        if IsMapOrIslandContainer(cur) then
            break
        end
        if cur:IsA("Model") then
            bestModel = cur
            if cur:FindFirstChildOfClass("Humanoid") or cur.PrimaryPart then
                break
            end
        end
        cur = cur.Parent
        depth = depth + 1
    end
    return bestModel or pr.Parent
end

-- 提取实例及其内部交互提示、头顶 BillboardGui 文本与多语言翻译文本的检索摘要（带流式子节点数量校验缓存）
GetInstanceSearchableSummary = function(inst)
    if not inst then return "" end
    local children = inst:GetChildren()
    if inst:IsA("BasePart") and #children == 0 then
        return (inst.Name or ""):lower()
    end
    if IsMapOrIslandContainer(inst) and #children > 60 then
        return (inst.Name or ""):lower()
    end
    local now = tick()
    local descendants = inst:GetDescendants()
    local descCount = #descendants
    local cached = npcTextSummaryCache[inst]
    -- 仅当后代数量未变（无新流式加载的 Prompt/BillboardGui）且已有有效文本（或未满 2.5s）时才命中缓存
    if cached and cached.name == inst.Name and cached.descCount == descCount then
        local ttl = cached.hasExtra and 180.0 or 2.5
        if (now - cached.time) < ttl then
            return cached.summary
        end
    end
    local parts = { (inst.Name or ""):lower() }
    if inst.Parent and not IsMapOrIslandContainer(inst.Parent) then
        table.insert(parts, (inst.Parent.Name or ""):lower())
    end
    local hum = inst:FindFirstChildOfClass("Humanoid")
    if hum and hum.DisplayName and hum.DisplayName ~= "" then
        table.insert(parts, hum.DisplayName:lower())
    end
    for i = 1, descCount do
        local sub = descendants[i]
        if sub:IsA("ProximityPrompt") then
            if sub.Name and sub.Name ~= "ProximityPrompt" then table.insert(parts, sub.Name:lower()) end
            if sub.ObjectText and sub.ObjectText ~= "" then table.insert(parts, sub.ObjectText:lower()) end
            if sub.ActionText and sub.ActionText ~= "" then table.insert(parts, sub.ActionText:lower()) end
        elseif sub:IsA("TextLabel") or sub:IsA("TextButton") then
            local rawTxt = sub.Text
            if rawTxt and rawTxt ~= "" and #rawTxt <= 240 then
                local cleanTxt = rawTxt:gsub("<[^>]+>", ""):lower()
                if cleanTxt ~= "" then table.insert(parts, cleanTxt) end
            end
            local okLoc, locTxt = pcall(function() return sub.LocalizedText or sub.ContentText end)
            if okLoc and type(locTxt) == "string" and locTxt ~= "" and locTxt ~= rawTxt and #locTxt <= 240 then
                local cleanLoc = locTxt:gsub("<[^>]+>", ""):lower()
                if cleanLoc ~= "" then table.insert(parts, cleanLoc) end
            end
        elseif sub:IsA("StringValue") and type(sub.Value) == "string" and sub.Value ~= "" and #sub.Value <= 100 then
            table.insert(parts, sub.Value:lower())
        elseif (sub:IsA("Model") or sub:IsA("BillboardGui")) and sub.Name and sub.Name ~= "" then
            table.insert(parts, sub.Name:lower())
        end
    end
    local summary = table.concat(parts, " | ")
    npcTextSummaryCache[inst] = {
        summary = summary,
        time = now,
        name = inst.Name,
        descCount = descCount,
        hasExtra = (#parts > 1)
    }
    return summary
end

-- 判断场景中的 Model 实例是否匹配目标 NPC 配置（结合名称与 300s 缓存的内部文本摘要比对）
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

-- 维护全局 ProximityPrompt 缓存与原始属性保护表（使用独立 do...end 封装内部状态，释放局部寄存器）：
-- 1) 合并全局唯一一对 Workspace.DescendantAdded/Removing 同时维护 cachedAllPrompts 与 cachedBossPrompts；
-- 2) 引入 hasPollutedPrompts 脏标记，常态无污染时 DismissStuckPromptsAndRestore O(1) 早退，不再遍历 PlayerGui/CoreGui。
do
    local originalPromptState = setmetatable({}, { __mode = "k" })
    local currentlyTriggeringPrompts = setmetatable({}, { __mode = "k" })
    local cachedAllPrompts = {}
    local cachedAllPromptsSet = setmetatable({}, { __mode = "k" })
    local cachedBossPromptsSet = setmetatable({}, { __mode = "k" })
    local hasPollutedPrompts = false
    local lastAllPromptsScan = 0
    local lastDismissTime = 0

    local function IsBossPromptCandidate(inst)
        if not inst or not inst:IsA("ProximityPrompt") then return false end
        local full = inst:GetFullName():lower()
        return (full:find("boss", 1, true) or full:find("enzo", 1, true) or full:find("octo", 1, true) or full:find("parasite", 1, true) or full:find("angler", 1, true) or full:find("rhythm", 1, true) or full:find("buoy", 1, true)) ~= nil
    end

    local function RememberPromptState(pr)
        if not pr then return { dist = 10, los = true, hold = 0 } end
        local existing = originalPromptState[pr]
        if existing then return existing end
        local rawDist = tonumber(pr.MaxActivationDistance) or 10
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
            if forcePulseHide and isRunning then
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
        if not forceScanAll and not hasPollutedPrompts then
            return
        end
        local nowDismiss = tick()
        if not forceScanAll and isRunning and (nowDismiss - lastDismissTime) < 1.5 then
            return
        end
        lastDismissTime = nowDismiss
        local char = LocalPlayer.Character
        local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
        local stillTriggering = false
        for pr in pairs(currentlyTriggeringPrompts) do
            if pr and pr.Parent then stillTriggering = true; break end
        end
        for pr in pairs(originalPromptState) do
            if pr and pr.Parent and not currentlyTriggeringPrompts[pr] then
                if (tonumber(pr.MaxActivationDistance) or 0) > 35 then
                    RestoreSinglePrompt(pr, true)
                end
            end
        end
        if forceScanAll then
            lastAllPromptsScan = nowDismiss
            task.spawn(function()
                pcall(function()
                    local descendants = Workspace:GetDescendants()
                    for i = 1, #descendants do
                        if not isRunning then break end
                        local d = descendants[i]
                        if d and d:IsA("ProximityPrompt") and d.Parent then
                            if not cachedAllPromptsSet[d] then
                                cachedAllPromptsSet[d] = true
                                table.insert(cachedAllPrompts, d)
                            end
                            if IsBossPromptCandidate(d) and not cachedBossPromptsSet[d] then
                                cachedBossPromptsSet[d] = true
                                table.insert(cachedBossPrompts, d)
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
                        if i % 400 == 0 then task.wait() end
                    end
                    lastAllPromptsScan = tick()
                end)
            end)
        end
        pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local guiContainers = {}
            if pg then table.insert(guiContainers, pg) end
            if CoreGui then table.insert(guiContainers, CoreGui) end
            for _, container in ipairs(guiContainers) do
                if container then
                    for _, g in ipairs(container:GetChildren()) do
                        if g:IsA("ScreenGui") or g:IsA("Folder") then
                            local gn = g.Name:lower()
                            if gn:find("proximityprompt", 1, true) or gn:find("prompt", 1, true) then
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
        if not stillTriggering then
            hasPollutedPrompts = false
        end
    end

    table.insert(activeConnections, Workspace.DescendantAdded:Connect(function(d)
        if d and d:IsA("ProximityPrompt") then
            if not cachedAllPromptsSet[d] then
                cachedAllPromptsSet[d] = true
                table.insert(cachedAllPrompts, d)
            end
            if IsBossPromptCandidate(d) and not cachedBossPromptsSet[d] then
                cachedBossPromptsSet[d] = true
                table.insert(cachedBossPrompts, d)
            end
            if not currentlyTriggeringPrompts[d] and (tonumber(d.MaxActivationDistance) or 10) <= 35 then
                RememberPromptState(d)
            end
        end
    end))
    table.insert(activeConnections, Workspace.DescendantRemoving:Connect(function(d)
        if d and d:IsA("ProximityPrompt") then
            if cachedAllPromptsSet[d] then
                cachedAllPromptsSet[d] = nil
                local idx = table.find(cachedAllPrompts, d)
                if idx then table.remove(cachedAllPrompts, idx) end
            end
            if cachedBossPromptsSet[d] then
                cachedBossPromptsSet[d] = nil
                local idx2 = table.find(cachedBossPrompts, d)
                if idx2 then table.remove(cachedBossPrompts, idx2) end
            end
        end
    end))

    GetCachedWorkspacePrompts = function()
        local i = 1
        while i <= #cachedAllPrompts do
            local pr = cachedAllPrompts[i]
            if not pr or not pr.Parent then
                if pr then cachedAllPromptsSet[pr] = nil end
                table.remove(cachedAllPrompts, i)
            else
                i = i + 1
            end
        end
        local now = tick()
        if #cachedAllPrompts == 0 and lastAllPromptsScan == 0 then
            lastAllPromptsScan = now
            for _, d in ipairs(Workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") and d.Parent then
                    if not cachedAllPromptsSet[d] then
                        cachedAllPromptsSet[d] = true
                        table.insert(cachedAllPrompts, d)
                    end
                    if not currentlyTriggeringPrompts[d] and (tonumber(d.MaxActivationDistance) or 10) <= 35 then
                        RememberPromptState(d)
                    end
                end
            end
        end
        return cachedAllPrompts
    end

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
                hasPollutedPrompts = true
                pcall(function()
                    pr.Enabled = true
                    pr.RequiresLineOfSight = false
                    pr.MaxActivationDistance = 999999
                    pr.HoldDuration = 0
                end)
                if type(fireproximityprompt) == "function" then
                    pcall(fireproximityprompt, pr)
                    triggered = true
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
                task.delay(0.05, function()
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
end

-- 在全图中查找匹配的 NPC 实例（支持深入岛屿子文件夹与按 preferPos 距离排序）
-- 0.5s 短缓存：同一 spec 连续两次调用（直连 + 微瞬移）只扫一次
local npcScanCache = setmetatable({}, { __mode = "k" })

-- 在全图 NPC 容器与交互点缓存中搜索匹配指定配置的 NPC 实例（带 0.5s 短缓存与就近排序）
local function FindNPCInstancesBySpec(spec)
    local now = tick()
    local cachedEntry = npcScanCache[spec]
    if cachedEntry and (now - cachedEntry.tick) < 0.5 and type(cachedEntry.results) == "table" then
        local alive = false
        for _, r in ipairs(cachedEntry.results) do
            if r and r.Parent then alive = true; break end
        end
        if alive or #cachedEntry.results == 0 then
            return cachedEntry.results
        end
    end

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
    for _, folderName in ipairs({"NPC", "NPCs", "Interactables", "DialogueNPCs", "QuestNPCs", "BossSetUp", "Shrines", "Spirits", "Merchants"}) do
        local f = Workspace:FindFirstChild(folderName)
        if f then table.insert(searchContainers, f) end
    end
    for _, mapName in ipairs({"Islands", "Map"}) do
        local mf = Workspace:FindFirstChild(mapName)
        if mf then
            for _, isl in ipairs(mf:GetChildren()) do
                table.insert(searchContainers, isl)
            end
        end
    end

    local function checkNode(inst)
        if not inst or seen[inst] or IsMapOrIslandContainer(inst) then return end
        if not (inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder")) then return end
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

    -- Prompt 反向溯源兜底：使用 ResolvePromptEntity 精准定位挂载了 ProximityPrompt 的 Model/BasePart/Folder（绝不误取整座岛屿容器）
    if #results == 0 then
        local allPrompts = GetCachedWorkspacePrompts()
        for i = 1, #allPrompts do
            local d = allPrompts[i]
            if d and d.Parent then
                local entity = ResolvePromptEntity(d)
                if entity and not seen[entity] and (DoesInstanceMatchNPCSpec(entity, spec) or DoesInstanceMatchNPCSpec(d.Parent, spec)) then
                    seen[entity] = true
                    table.insert(results, entity)
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
    npcScanCache[spec] = { tick = now, results = results }
    return results
end

-- 检测游戏内的 NPC 对话框 UI 是否已经弹出（带热点引用缓存 + 0.35s 最小查询间隔 + 定向扫描，绝不每秒遍历整个 MainGui）
-- [性能优化 #7 & Bug修复 #1 / 建议 #4] 赋值给上层预声明的 IsDialogueUIOpen，并增加 0.35s 查询门控（支持 forceNow 实时检测）
do
    local cachedDialogueNode = nil
    local lastDialogueCheckTime = 0
    local lastDialogueCheckResult = false
    IsDialogueUIOpen = function(forceNow)
        if cachedDialogueNode and cachedDialogueNode.Parent and cachedDialogueNode.Visible and cachedDialogueNode.AbsoluteSize.X > 20 then
            local sg = cachedDialogueNode:FindFirstAncestorOfClass("ScreenGui")
            if not sg or sg.Enabled then
                lastDialogueCheckResult = true
                lastDialogueCheckTime = tick()
                return true
            end
        end
        local now = tick()
        if not forceNow and (now - lastDialogueCheckTime) < 0.35 then
            return lastDialogueCheckResult
        end
        lastDialogueCheckTime = now
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then
            lastDialogueCheckResult = false
            return false
        end
        for _, gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "IdenticalHeavyweightFishing" and gui.Name ~= "RobloxGui" then
                local gName = gui.Name:lower()
                if gName:find("dialogue", 1, true) or gName:find("dialog", 1, true) or gName:find("talk", 1, true) or gName:find("npc", 1, true) or gName:find("chat", 1, true) then
                    for _, d in ipairs(gui:GetDescendants()) do
                        if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Visible and d.AbsoluteSize.X > 20 then
                            cachedDialogueNode = d
                            lastDialogueCheckResult = true
                            return true
                        end
                    end
                else
                    for _, topChild in ipairs(gui:GetChildren()) do
                        if topChild:IsA("GuiObject") and topChild.Visible then
                            local cn = topChild.Name:lower()
                            if cn:find("dialogue", 1, true) or cn:find("dialog", 1, true) or cn:find("talk", 1, true) or cn:find("npc", 1, true) or cn:find("chat", 1, true) or cn:find("interact", 1, true) then
                                for _, d in ipairs(topChild:GetDescendants()) do
                                    if d:IsA("TextButton") and d.Visible and d.AbsoluteSize.X > 20 then
                                        local t = (d.Text or ""):lower()
                                        if t:find("没关系", 1, true) or t:find("主线", 1, true) or t:find("任务", 1, true) or t:find("对话", 1, true)
                                            or t:find("nevermind", 1, true) or t:find("cancel", 1, true) or t:find("goodbye", 1, true)
                                            or t:find("accept", 1, true) or t:find("quest", 1, true) or t:find("shop", 1, true)
                                            or t:find("easy", 1, true) or t:find("hard", 1, true) or t:find("简单", 1, true) or t:find("困难", 1, true) then
                                            cachedDialogueNode = d
                                            lastDialogueCheckResult = true
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
        lastDialogueCheckResult = false
        return false
    end
end

-- 自动点击当前弹出的 NPC 对话框选项（优先扫描对话/任务相关 ScreenGui，且完全等于匹配优先、包含次之）
-- 0.5s 候选缓存：RunTicketQuestAction 连续 3 次点击只扫 1 次 UI 树
local dialogueBtnCache = { time = 0, list = nil }

-- 在当前打开的 NPC 对话界面中按关键词优先级自动匹配并点击对应选项按钮
local function AutoClickDialogueOption(preferredKeywords)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end

    local now = tick()
    local candidates
    if dialogueBtnCache.list and (now - dialogueBtnCache.time) < 0.5 then
        -- 复用半秒内的候选列表，过滤已销毁按钮
        candidates = {}
        for _, c in ipairs(dialogueBtnCache.list) do
            if c.btn and c.btn.Parent and c.btn.Visible and c.btn.Active then
                table.insert(candidates, c)
            end
        end
        if #candidates == 0 then
            dialogueBtnCache.list = nil
        end
    end

    if not candidates or #candidates == 0 then
        local priorityGuis, fallbackGuis = {}, {}
        for _, gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Name ~= "IdenticalHeavyweightFishing" and gui.Name ~= "RobloxGui" and gui.Enabled then
                local gn = gui.Name:lower()
                if gn:find("dialogue") or gn:find("dialog") or gn:find("talk")
                    or gn:find("npc") or gn:find("chat") or gn:find("quest") then
                    table.insert(priorityGuis, gui)
                elseif gn == "maingui" or gn == "fisher_gui" then
                    -- MainGui / Fisher_GUI 体积巨大：只取名字像对话/任务的顶层子面板，绝不整树扫描
                    for _, ch in ipairs(gui:GetChildren()) do
                        if ch:IsA("GuiObject") and ch.Visible then
                            local cn = ch.Name:lower()
                            if cn:find("dialog") or cn:find("dialogue") or cn:find("talk")
                                or cn:find("npc") or cn:find("chat") or cn:find("quest")
                                or cn:find("modal") or cn:find("popup") or cn:find("prompt") then
                                table.insert(priorityGuis, ch)
                            end
                        end
                    end
                else
                    -- 跳过背包/商店/图鉴等大菜单，避免 fallback 扫到数百鱼条目
                    local isMenu = gn:find("inventory") or gn:find("shop")
                        or gn:find("bag") or gn:find("index")
                        or gn:find("setting") or gn:find("store")
                        or gn:find("catalog") or gn:find("codex")
                    if not isMenu then
                        table.insert(fallbackGuis, gui)
                    end
                end
            end
        end
        local orderedGuis = (#priorityGuis > 0) and priorityGuis or fallbackGuis
        candidates = {}
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
        dialogueBtnCache.time = now
        dialogueBtnCache.list = candidates
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
            if IsDialogueUIOpen(true) then
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
                    if IsDialogueUIOpen(true) or nearTriggered then
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
-- ============================================================================
-- 【模块 18：【神灵】页面构建（三岛神灵祈祷、道士/茅山/傻子商人、四圣兽监控与跳服引擎）】
-- 作用说明：
--   1. 构建三岛神灵状态检查、自动祈祷、一键寻找当前服活跃神灵及分岛独立【传送/对话】双按钮行；
--   2. 构建道士/茅山/傻子隐藏商人快捷交互行、四圣兽特质与世界 Boss 检查及自动跳服开关。
-- ============================================================================
-- 神灵页面（三个神灵分类管理 + 道士接任务 + 四圣兽特质与Boss监控）
-- ==========================================
do
createCategoryHeader(tabGod, "三个神灵世界事件 (竹岛 / 冰霜岛 / 琥珀岛 · 50M 祈祷)")
local godCard = createCardGroup(tabGod)

createButtonRow(godCard, "检查三个神灵祝福状态", "检查竹岛/冰霜岛/琥珀岛三个神灵祝福进度与场上活跃神灵", "检查状态", function()
    if DashUI._runRadarPassNow then pcall(DashUI._runRadarPassNow) end
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
    if DashUI._runRadarPassNow then pcall(DashUI._runRadarPassNow) end
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
    TeleportToNPCSpec(ImportantDialogueNPCs[20])
end, function()
    OpenRemoteNPCDialogue(ImportantDialogueNPCs[20], false)
end)
createNPCDualActionRow(roamGodCard, "茅山商人 (Maoshan Merchant)", "购买 300M 茅山竿(105威力) / 200M 茅山珠 / 200M 镇江技能", function()
    TeleportToNPCSpec(ImportantDialogueNPCs[21])
end, function()
    OpenRemoteNPCDialogue(ImportantDialogueNPCs[21], false)
end)
createNPCDualActionRow(roamGodCard, "傻子隐藏商人 (Dumb Guy)", "轮换隐藏商人 · 获取六脉神鹰 Six Vein Divine Hawk 技能", function()
    TeleportToNPCSpec(ImportantDialogueNPCs[22])
end, function()
    OpenRemoteNPCDialogue(ImportantDialogueNPCs[22], false)
end)

createCategoryHeader(tabGod, "四圣兽 (朱雀 / 玄武 / 白虎 / 青龙 · 神话特质与圣兽Boss雷达)")
local beastCard = createCardGroup(tabGod)
createButtonRow(beastCard, "检查四圣兽特质与场上圣兽状态", "扫描当前已装备技能是否拥有四圣兽特质，并检测场上四圣兽Boss", "检查四圣兽", function()
    local pData = GetPlayerData()
    local ownedBeasts = {}
    if pData then
        for _, topFolder in ipairs(pData:GetChildren()) do
            local fn = topFolder.Name
            if fn ~= "Inventory" and fn ~= "Hotbar" and fn ~= "FishingRodInventory" and fn ~= "Bait" and fn ~= "Index" then
                local toCheck = topFolder:GetDescendants()
                table.insert(toCheck, topFolder)
                for i = 1, #toCheck do
                    local d = toCheck[i]
                    if d:IsA("ValueBase") and type(d.Value) == "string" and d.Value ~= "" then
                        local vLow = d.Value:lower()
                        for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                            for _, alLow in ipairs(bSpec.lowerAliases) do
                                if vLow:find(alLow, 1, true) then
                                    table.insert(ownedBeasts, bSpec.cnName .. "(" .. (d.Parent and d.Parent.Name or d.Name) .. ")")
                                    break
                                end
                            end
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
createButtonRow(hopCard, "立即跳服务器", "立即跳转到随机不同服务器", "跳转", function() ServerHop(true) end)
end -- end of God UI scope

-- ==========================================
-- ============================================================================
-- 【模块 19：【任务】页面构建（智能票据任务、每日签到、礼包码批量兑换、全NPC双按钮列表与猴子交鱼）】
-- 作用说明：
--   1. RunTicketQuestAction() 自动读取任务进度，未接或已完成时才发起远程对话接交任务，任务进行中静默等待不打断钓鱼；
--   2. 提供每日任务领取、1~7天签到奖励领取、已知有效促销码一键兑换、全量 NPC【传送+对话】列表及自动向猴子交鱼功能。
-- 后续修改指引：
--   - 若官方发布了新的兑换码，直接在下方 knownActiveCodes 数组末尾追加新代码字符串即可。
-- ============================================================================
-- 🎫 票据任务与全量 NPC 传送+对话面板
-- ==========================================
do
local questAlternateToggle = false
-- 自动或手动执行票据任务：先检查任务进度，仅在未接取或已完成时发起远程对话与提交，避免频繁打断钓鱼
RunTicketQuestAction = function(diffArg, manualNotify)
    diffArg = diffArg or (QuestDiffMap[Config.TicketDifficulty] or "Easy")
    local isHard = (diffArg == "Hard" or diffArg == "困难")
    local diffKey = isHard and "Hard" or "Easy"
    local diffCN = isHard and "困难" or "简单"

    -- 融合老版本 (fsc6) 优点：自动模式下先读取 pData 任务进度，若任务正在进行中且进度未满，静默等待钓鱼完成，绝不频繁打断钓鱼
    local pData = GetPlayerData()
    local needAccept = false
    local canClaim = false
    local hasData = false

    if pData and not manualNotify then
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
                    -- 任务进行中且进度未满：静默返回 false，不打断当前钓鱼
                    return false
                end
            else
                needAccept = true
                canClaim = false
            end
        end
    end

    if not hasData and not manualNotify then
        questAlternateToggle = not questAlternateToggle
        if questAlternateToggle then
            needAccept = true
            canClaim = false
        else
            needAccept = false
            canClaim = true
        end
    elseif manualNotify then
        needAccept = true
        canClaim = true
    end

    if Events and (needAccept or canClaim or manualNotify) then
        local questRemNames = (canClaim and not needAccept)
            and {"TicketQuest", "ClaimQuest", "SubmitQuest", "CompleteQuest", "Quest", "DialogueQuest", "AcceptQuest"}
            or  {"TicketQuest", "AcceptQuest", "StartQuest", "GetQuest", "TakeQuest", "Quest", "DialogueQuest", "ClaimQuest"}
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
    local pData = GetPlayerData()
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
    if type(setclipboard) == "function" then pcall(function() setclipboard(msg) end) end
    ShowNotification("任务结构诊断 (已复制)", msg, "SUCCESS", 8)
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
-- 自动向猴子 NPC 发起远程对话并批量提交鱼类完成收集任务
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
end -- end of NPC Engine, God & Quests Scope

-- ==========================================
-- ============================================================================
-- 【模块 20：【商店与制作】页面构建（鱼饵合成/自动补货、逸久贤者技能学习、自动扭蛋、鱼竿商店）】
-- 作用说明：
--   1. 构建神话 Boss 鱼饵自动制作与普通鱼饵低于阈值自动补货面板；
--   2. 构建逸久贤者技能远程/传送购买、太极/无我卡池自动扭蛋，以及按价格排序的全鱼竿一键购买目录。
-- ============================================================================
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

createCategoryHeader(tabShop, "逸久贤者(技能商人)")
local sageCard = createCardGroup(tabShop)
local sageSkills = {"One-Strike Heaven Gate", "Taijiquan Technique", "Infinite Sky Ascension", "Rolling Chaos", "Sever the Gate", "Phoenix Strike Art", "Skyfall Stomp", "Beastbreaker Cleave", "Demonfall Technique", "Dragon Strike"}
local chosenSageSkill = sageSkills[1]
createDropdownRow(sageCard, "选择技能", "从逸久贤者处学习的技能", sageSkills, chosenSageSkill, function(v) chosenSageSkill = v end)
createButtonRow(sageCard, "购买技能并传送", "安全传送到逸久贤者处并购买技能", "购买技能", function()
    if SafeTeleport(CFrame.new(-117.5, 6.8, 41.2)) then
        task.wait(0.3)
        if Events and Events:FindFirstChild("BuySkill") then
            Events.BuySkill:FireServer(chosenSageSkill)
            ShowNotification("逸久贤者", "已购买 " .. chosenSageSkill .. "！", "SUCCESS")
        else
            ShowNotification("逸久贤者", "已到达逸久贤者面前，请点击购买技能。", "WARN")
        end
    end
end)

createCategoryHeader(tabShop, "自动扭蛋")
local gachaCard = createCardGroup(tabShop)
createDropdownRow(gachaCard, "扭蛋卡池", "当前召唤卡池", {"太极卡池", "无我卡池"}, Config.GachaBanner, function(v) Config.GachaBanner = v end, "GachaBanner")
createSliderRow(gachaCard, "每次扭蛋票数", "每次扭蛋动作的票数", 1, 10, Config.GachaPullsPerAction, false, "", function(v) Config.GachaPullsPerAction = v end, "GachaPullsPerAction")
createToggleRow(gachaCard, "自动扭蛋", "自动从选中的卡池抽取", Config.AutoGacha, function(v) Config.AutoGacha = v end, "AutoGacha")

createCategoryHeader(tabShop, "鱼竿商人目录(按价格排序)")
local rodShopCard = createCardGroup(tabShop)
local function formatRodPrice(n)
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
    local desc = string.format("威力: %d | 运气: %d%% | %s", rod.power, rod.luck, formatRodPrice(rod.price))
    createButtonRow(rodShopCard, rod.name, desc, "购买", function()
        if Events and Events:FindFirstChild("BuyFishingRod") then
            Events.BuyFishingRod:FireServer(rod.name)
            ShowNotification("鱼竿商人", "已发送购买请求: " .. rod.name, "SUCCESS")
        end
    end)
end

end -- end of Shop UI scope

-- ==========================================
-- ============================================================================
-- 【模块 21：【传送】页面构建（自定义坐标点管理、10大特殊NPC实时雷达传送、岛屿/商人/秘密鱼竿/玩家传送）】
-- 作用说明：
--   1. 支持读取并保存当前 XYZ 坐标为自定义传送点（支持单独删除与本地 JSON 持久化）；
--   2. 构建 10 大特殊 NPC（竹岛/冰霜/琥珀神灵、道士/茅山/傻子商人、朱雀/玄武/白虎/青龙）实时状态与安全射线落地传送行；
--   3. 构建 1~10 号岛屿、Boss 领域、各岛标迪鱼竿商人、6 把秘密鱼竿点位以及指定/随机玩家传送面板。
-- ============================================================================
-- 传送页面
-- ==========================================
do
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

-- 重新渲染自定义传送点列表 UI（生成每行的传送与删除按钮）
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
-- 创建特殊 NPC 实时监控行（显示刷新状态与距离，点击时通过向下射线检测安全落点后传送）
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

-- 构建当前服务器其他玩家的下拉列表选项并建立名称到 Player 实例的映射
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
    local targetChar = target and (target.Character or Workspace:FindFirstChild(target.Name))
    local targetPos = targetChar and GetNPCPosition(targetChar)
    if not target or not targetPos then
        ShowNotification("玩家传送", "目标玩家不存在或未加载角色，请刷新列表后重试", "ERROR")
        return
    end
    if SafeTeleport(CFrame.new(targetPos + Vector3.new(0, 2.5, 3), targetPos)) then
        ShowNotification("玩家传送", "已传送到 " .. (target.DisplayName or target.Name), "SUCCESS")
    else
        ShowNotification("玩家传送", "本地角色未就绪", "ERROR")
    end
end)

-- 保留随机传送（兼容远端岛屿流式卸载下的 GetPivot 坐标获取）
local lastTpTarget = nil
createButtonRow(srvCard, "传送到随机玩家", "随机传送到当前服务器另一个玩家附近", "传送", function()
    local targets = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local pChar = p.Character or Workspace:FindFirstChild(p.Name)
            if pChar and GetNPCPosition(pChar) then
                table.insert(targets, p)
            end
        end
    end
    if #targets == 0 then
        ShowNotification("玩家传送", "未找到其他已加载角色位置的玩家。", "WARN")
        return
    end
    local pool = {}
    for _, p in ipairs(targets) do
        if not (#targets > 1 and p == lastTpTarget) then table.insert(pool, p) end
    end
    local selected = (#pool > 0 and pool[math.random(1, #pool)]) or targets[math.random(1, #targets)]
    lastTpTarget = selected
    local selChar = selected.Character or Workspace:FindFirstChild(selected.Name)
    local selPos = selChar and GetNPCPosition(selChar)
    if selPos then
        if SafeTeleport(CFrame.new(selPos + Vector3.new(0, 2.5, 3), selPos)) then
            ShowNotification("玩家传送", "已传送到 " .. (selected.DisplayName or selected.Name), "SUCCESS")
        end
    end
end)

end -- end of Teleports scope

-- ==========================================
-- ============================================================================
-- 【模块 22：环境光照控制 (ApplyLightingSettings) 与【视觉】【移动】【配置文件】页面构建】
-- 作用说明：
--   1. ApplyLightingSettings() 事件驱动调节全亮、去雾去粒子、关闭阴影，移出每帧渲染循环以节省开销；
--   2. 构建【视觉】页（7 类实体 ESP + 鱼红圈 + 省电模式）、【移动】页（加速/飞行/无限跳/水上行走/穿墙/防挂机/重连）与【配置文件】页。
-- ============================================================================
-- 视觉设置函数（移出每帧渲染循环）
-- ==========================================
local isApplyingLighting = false
local lastCameraParticleScan = 0
local fullbrightWasActive = false
local shadowsDisabledByScript = false
local FULLBRIGHT_AMBIENT = Color3.fromRGB(180, 180, 180)
-- 应用全亮、去雾去粒子与关闭阴影等环境视觉设置，关闭对应开关时精确还原初始画质（未开启全亮时不覆写游戏原生昼夜交替）
ApplyLightingSettings = function()
    if not isRunning or isApplyingLighting then return end
    isApplyingLighting = true
    pcall(function()
        if Config.Fullbright then
            fullbrightWasActive = true
            if Lighting.Brightness ~= 2.5 then Lighting.Brightness = 2.5 end
            if Lighting.ClockTime ~= 14 then Lighting.ClockTime = 14 end
            if Lighting.Ambient ~= FULLBRIGHT_AMBIENT then Lighting.Ambient = FULLBRIGHT_AMBIENT end
            if Lighting.OutdoorAmbient ~= FULLBRIGHT_AMBIENT then Lighting.OutdoorAmbient = FULLBRIGHT_AMBIENT end
        elseif fullbrightWasActive then
            fullbrightWasActive = false
            Lighting.Brightness = originalLightingState.Brightness
            Lighting.ClockTime = originalLightingState.ClockTime
            Lighting.Ambient = originalLightingState.Ambient
            Lighting.OutdoorAmbient = originalLightingState.OutdoorAmbient
        end
        -- 性能模式只负责阴影；全亮关闭后也不会错误覆盖性能模式。
        if Config.Fullbright or Config.PerformanceMode then
            shadowsDisabledByScript = true
            if Lighting.GlobalShadows ~= false then Lighting.GlobalShadows = false end
        elseif shadowsDisabledByScript then
            shadowsDisabledByScript = false
            Lighting.GlobalShadows = originalLightingState.GlobalShadows
        end
        if Config.NoFog then
            if Lighting.FogEnd ~= 1000000 then Lighting.FogEnd = 1000000 end
            if Lighting.FogStart ~= 1000000 then Lighting.FogStart = 1000000 end
            local atmo = Lighting:FindFirstChildWhichIsA("Atmosphere")
            if atmo then
                RememberAtmosphere(atmo)
                if atmo.Density ~= 0 then atmo.Density = 0 end
                if atmo.Haze ~= 0 then atmo.Haze = 0 end
                if atmo.Glare ~= 0 then atmo.Glare = 0 end
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
local function NotifyAndRefreshESP(catKey, v, labelTitle)
    Config["ESP_" .. catKey] = v
    if DashUI._refreshESPNow then
        pcall(DashUI._refreshESPNow, catKey, v, labelTitle)
    end
end
createToggleRow(espCard, "神灵ESP", "高亮三座神灵祭坛与活跃神灵 (跨全图穿墙显示)", Config.ESP_GodSpirit, function(v) NotifyAndRefreshESP("GodSpirit", v, "神灵ESP") end, "ESP_GodSpirit")
createToggleRow(espCard, "秘密鱼竿ESP", "高亮所有秘密鱼竿与隐藏鱼竿点位", Config.ESP_SecretRod, function(v) NotifyAndRefreshESP("SecretRod", v, "秘密鱼竿ESP") end, "ESP_SecretRod")
createToggleRow(espCard, "船只ESP", "高亮已生成的船只位置与距离", Config.ESP_Boats, function(v) NotifyAndRefreshESP("Boats", v, "船只ESP") end, "ESP_Boats")
createToggleRow(espCard, "茅山ESP", "高亮茅山商人/茅山鱼竿位置", Config.ESP_Maoshan, function(v) NotifyAndRefreshESP("Maoshan", v, "茅山ESP") end, "ESP_Maoshan")
createToggleRow(espCard, "道士ESP", "高亮道士商人/隐藏商人位置", Config.ESP_Taoist, function(v) NotifyAndRefreshESP("Taoist", v, "道士ESP") end, "ESP_Taoist")
createToggleRow(espCard, "Boss ESP", "高亮恩佐/章鱼隐藏Boss/龙钓海/四圣兽生成点", Config.ESP_Boss, function(v) NotifyAndRefreshESP("Boss", v, "Boss ESP") end, "ESP_Boss")
createToggleRow(espCard, "玩家ESP", "高亮服务器内其他玩家及实时距离", Config.ESP_Players, function(v) NotifyAndRefreshESP("Players", v, "玩家ESP") end, "ESP_Players")
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
        if UpdateMainFrameScale then
            UpdateMainFrameScale(true)
        elseif mainFrameScale and mainFrameScale.Parent then
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
        if UpdateMainFrameScale then UpdateMainFrameScale(true) end
    else
        ShowNotification("配置错误", "未找到已保存的配置文件。", "WARN")
    end
end)
createToggleRow(profCard, "注入时自动加载配置", "启动时自动加载配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end, "AutoLoadProfile")

createCategoryHeader(tabProfiles, "会话操作")
local credCard = createCardGroup(tabProfiles)
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复所有设置", "卸载", UnloadScript)

-- [性能优化 #5 / 建议 #14] UI 构建完成后仅刷新当前可见标签页 Canvas，其余标签页在 SwitchTab / Visible 变化时按需刷新
local function refreshVisibleTabCanvas()
    if currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab] then
        pcall(tabCanvasRefreshers[currentActiveTab])
    end
end
task.defer(refreshVisibleTabCanvas)
task.delay(0.4, refreshVisibleTabCanvas)
task.delay(1.2, refreshVisibleTabCanvas)
end -- end of Visuals/Player/Profiles scope
end -- end of Tab & Feature Construction Scope

-- ============================================================================
-- 【模块 23：鱼竿工具精准识别 (IsToolFishingRod) 与持竿状态缓存判定 (IsCharacterHoldingFishingRod)】
-- 作用说明：
--   1. 区分角色手中拿的是“鱼竿”还是“钓上来的鱼”（防止把名字含 Fish 的鱼误判为鱼竿）；
--   2. 带 0.25s TTL 缓存与 ChildAdded/Removed 事件失效机制，当玩家切到鱼或收起鱼竿时自动暂停抛竿。
-- ============================================================================
-- 精准判定某个 Tool/Model 是否为鱼竿（绝不把名字带 "Fish" 的鱼类当成鱼竿！）
IsToolFishingRod = function(inst, pData)
    if not inst then return false end
    pData = pData or GetPlayerData()
    local equippedRodName = pData and pData:FindFirstChild("FishingRod") and pData.FishingRod.Value or nil
    local rawName = (inst.Name or "")
    if equippedRodName and equippedRodName ~= "" and rawName == equippedRodName then
        return true
    end
    local low = rawName:lower()
    if low:find("rod") or low:find("pole") or low:find("钓竿") or low:find("鱼竿") or low:find("钓") or low:find("竿") then
        return true
    end
    if allRods then
        for i = 1, #allRods do
            if allRods[i].name:lower() == low then
                return true
            end
        end
    end
    return false
end

-- 精准判定角色当前是否正拿着鱼竿（若玩家切到2号位“举起一条鱼”或把鱼竿收进背包，立即返回 false 暂停自动抛竿！）
-- 持竿状态缓存：ChildAdded/Removed 时失效，避免 Heartbeat 每帧遍历 GetChildren
local cachedHoldingRod = true
local cachedHoldingRodTime = 0
local HOLDING_ROD_CACHE_TTL = 0.25

-- 判定角色当前是否正手持鱼竿（带 0.25s 缓存，若切换到手持鱼或收起鱼竿则返回 false 以暂停自动抛竿）
IsCharacterHoldingFishingRod = function(char, pData)
    char = char or LocalPlayer.Character
    if not char then return false end
    local now = tick()
    if (now - cachedHoldingRodTime) < HOLDING_ROD_CACHE_TTL then
        return cachedHoldingRod
    end
    pData = pData or GetPlayerData()

    -- 1) 检查角色身上是否正装备着 Tool
    local equippedTool = char:FindFirstChildOfClass("Tool")
    if equippedTool then
        cachedHoldingRod = IsToolFishingRod(equippedTool, pData)
        cachedHoldingRodTime = now
        return cachedHoldingRod
    end

    -- 2) 检查角色身上是否挂载了手持鱼模型（如视频中点击快捷栏举起一条鱼时）
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Model") or ch:IsA("Tool") then
            local cn = (ch.Name or ""):lower()
            if IsToolFishingRod(ch, pData) then
                cachedHoldingRod = true
                cachedHoldingRodTime = now
                return true
            elseif cn:find("fish", 1, true) or cn:find("orca", 1, true) or cn:find("shark", 1, true) or cn:find("catfish", 1, true)
                or cn:find("turtle", 1, true) or cn:find("eel", 1, true) or cn:find("perch", 1, true) or cn:find("whale", 1, true) then
                cachedHoldingRod = false
                cachedHoldingRodTime = now
                return false
            end
        end
    end

    -- 3) 若角色手中无 Tool，检查 Backpack 里是否躺着未装备的鱼竿 Tool（说明玩家主动收起了鱼竿）
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and IsToolFishingRod(tool, pData) then
                cachedHoldingRod = false
                cachedHoldingRodTime = now
                return false
            end
        end
    end

    cachedHoldingRod = true
    cachedHoldingRodTime = now
    return true
end

-- 自动装备背包中的鱼竿工具（若当前手里举着鱼，自动先切换回鱼竿；绝不把名字含 Fish 的鱼当成鱼竿装备）
EnsureFishingRodEquipped = function()
    local char = LocalPlayer.Character
    if not char then return false end
    local pData = GetPlayerData()
    local existingTool = char:FindFirstChildOfClass("Tool")
    if existingTool and IsToolFishingRod(existingTool, pData) then
        return true
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if not hum or not bp then return false end
    local bestTool = nil
    for _, tool in ipairs(bp:GetChildren()) do
        if tool:IsA("Tool") and IsToolFishingRod(tool, pData) then
            bestTool = tool
            break
        end
    end
    if bestTool then
        pcall(function() hum:EquipTool(bestTool) end)
        return true
    end
    return existingTool ~= nil
end

-- 保持 MainGui / Fisher_GUI 原生界面结构纯净，启动时不篡改任何子面板 Visible 状态，确保钓鱼按钮与 Boss 弹窗 100% 原生正常工作

SyncUIWithConfig()
task.spawn(function()
    task.wait(0.3)
    if isRunning and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
    end
end)

-- ==========================================
-- ============================================================================
-- 【模块 24：角色属性事件监听 (BindCharacterAttributes)、零 GC 穿墙零件缓存与断线自动重连】
-- 作用说明：
--   1. 通过 AttributeChanged 事件驱动缓存 Fishing / CDForTheNextThrow / Minigame / Swimming 四大高频状态，消除每帧 GetAttribute 调用；
--   2. 缓存角色全身 BasePart 供 Stepped 穿墙循环零 GC 遍历，并监听断线弹窗与传送失败事件实现 3 秒自动重连。
-- ============================================================================
-- 角色属性缓存 + 零件监听（用于零开销 Noclip）
-- ==========================================
-- 角色属性缓存：用 AttributeChanged 事件驱动，避免 Heartbeat / RenderStepped 每帧跨边界 GetAttribute
local attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false
-- 监听角色 AttributeChanged 信号，实时同步 Fishing / CDForTheNextThrow / Minigame / Swimming 状态位
local function BindCharacterAttributes(char)
    if attrCharConn then
        pcall(function() attrCharConn:Disconnect() end)
        attrCharConn = nil
    end
    attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false
    if not char then return end
    pcall(function()
        attrFishing = char:GetAttribute("Fishing") == true
        attrCD = char:GetAttribute("CDForTheNextThrow") == true
        attrMinigame = char:GetAttribute("Minigame") == true
        attrSwimming = char:GetAttribute("Swimming") == true
    end)
    attrCharConn = char.AttributeChanged:Connect(function(name)
        if not isRunning then return end
        if name == "Fishing" then
            attrFishing = char:GetAttribute("Fishing") == true
        elseif name == "CDForTheNextThrow" then
            attrCD = char:GetAttribute("CDForTheNextThrow") == true
        elseif name == "Minigame" then
            attrMinigame = char:GetAttribute("Minigame") == true
        elseif name == "Swimming" then
            attrSwimming = char:GetAttribute("Swimming") == true
        end
    end)
    -- 不加入 activeConnections：重生时会主动 Disconnect 并替换，避免数组里堆死连接
end

-- 缓存角色全身 BasePart 供 Stepped 穿墙循环零开销遍历，并在手持工具变化时刷新持竿状态缓存
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
    table.insert(characterConnections, char.ChildAdded:Connect(function(child)
        -- 仅 Tool/Model 变化时失效持竿缓存，避免无关子项抖动
        if child:IsA("Tool") or child:IsA("Model") then
            cachedHoldingRodTime = 0
            if not Config.AutoCast and RestoreMobileFishingButtonUI then
                task.delay(0.1, function()
                    if isRunning and not Config.AutoCast and RestoreMobileFishingButtonUI then
                        pcall(RestoreMobileFishingButtonUI, false)
                    end
                end)
                task.delay(0.35, function()
                    if isRunning and not Config.AutoCast and RestoreMobileFishingButtonUI then
                        pcall(RestoreMobileFishingButtonUI, false)
                    end
                end)
            end
        end
    end))
    table.insert(characterConnections, char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") or child:IsA("Model") then
            cachedHoldingRodTime = 0
        end
    end))
    -- Backpack 获得/失去鱼竿时也要失效缓存，避免 0.25s 内误判
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        table.insert(characterConnections, bp.ChildAdded:Connect(function()
            cachedHoldingRodTime = 0
        end))
        table.insert(characterConnections, bp.ChildRemoved:Connect(function()
            cachedHoldingRodTime = 0
        end))
    end

    table.insert(characterConnections, char.DescendantRemoving:Connect(function(part)
        local idx = table.find(cachedCharacterParts, part)
        if idx then table.remove(cachedCharacterParts, idx) end
        if cachedFishConstraint == part then cachedFishConstraint = nil end
    end))
end

if LocalPlayer.Character then
    CacheCharacterParts(LocalPlayer.Character)
    BindCharacterAttributes(LocalPlayer.Character)
end
table.insert(activeConnections, LocalPlayer.CharacterAdded:Connect(function(char)
    CacheCharacterParts(char)
    BindCharacterAttributes(char)
end))

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
-- ============================================================================
-- 【模块 25：全图穿墙 ESP 渲染管理系统、跨全图固定地标锚点与鱼目标红圈】
-- 作用说明：
--   1. 将 BillboardGui 挂载于 screenGui 下实现无限距离穿墙显示，配合 3D Highlight 高亮目标模型；
--   2. 预置三岛神灵祭坛、三大 Boss 区与秘密山洞固定 ESP 锚点（即使远端岛屿尚未流式加载也能跨全图看到方位与距离）；
--   3. RefreshAllESPNow() 带空表短路与距离整数缓存，仅在开启对应 ESP 且距离变化超过 1 米时更新文本。
-- ============================================================================
-- ESP 管理系统 (挂载于 screenGui LayerCollector + 递归零件查找 + 远距流式锚点 + 3D Highlight 高亮)
-- ==========================================
-- 关键修复：BillboardGui 必须挂载在 ScreenGui (CoreGui/PlayerGui) 下才能在全图无限距离 100% 穿墙渲染，挂载在 Workspace.Folder 下会被引擎裁剪不显示！
local espFolder = Instance.new("Folder")
espFolder.Name = "IdenticalESP"
espFolder.Parent = screenGui
table.insert(cleanUpInstances, espFolder)

local espAnchorFolder = Instance.new("Folder")
espAnchorFolder.Name = "IdenticalESPAnchors"
espAnchorFolder.Parent = Workspace
table.insert(cleanUpInstances, espAnchorFolder)

local activeESP = setmetatable({}, { __mode = "k" })  -- 弱键：实例被 GC 时条目自动消失

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

-- 在 Workspace 创建或复用透明无碰撞的固定坐标锚点 Part，供未流式加载的远端地标挂载 ESP
local function CreateESPAnchorPart(anchorKey, pos)
    local existing = espAnchorFolder:FindFirstChild(anchorKey)
    if existing and existing:IsA("BasePart") then
        if pos then existing.Position = pos end
        return existing
    end
    local p = Instance.new("Part")
    p.Name = anchorKey
    p.Size = Vector3.new(1, 1, 1)
    p.Transparency = 1
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.Anchored = true
    p.Position = pos or Vector3.zero
    p.Parent = espAnchorFolder
    return p
end

-- 预编译 ESP 配置键（放在 AddESP 之前，避免热路径字符串拼接）
local ESP_CATEGORY_KEYS = {
    GodSpirit = "ESP_GodSpirit",
    SecretRod = "ESP_SecretRod",
    Boats     = "ESP_Boats",
    Maoshan   = "ESP_Maoshan",
    Taoist    = "ESP_Taoist",
    Boss      = "ESP_Boss",
    Players   = "ESP_Players",
}

-- 为目标实例挂载跨全图穿墙 BillboardGui 标签与 3D Highlight 轮廓高亮
local function AddESP(instance, name, espCategory, color, icon, fallbackPos)
    if not instance then return end
    local existing = activeESP[instance]
    if existing then
        existing.name = name
        existing.icon = icon or ""
        if fallbackPos and existing.isProxyPart and existing.part and existing.part.Parent then
            existing.part.Position = fallbackPos
        end
        return
    end

    -- 递归查找 BasePart（修复原先 FindFirstChildWhichIsA("BasePart") 未传 true 导致嵌套 Model 拿不到 part 无法显示 ESP 的问题）
    local part = nil
    local isProxyPart = false
    if typeof(instance) == "Instance" then
        if instance:IsA("BasePart") then
            part = instance
        elseif instance:IsA("Model") then
            part = instance:FindFirstChild("HumanoidRootPart", true) or instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
        else
            part = instance:FindFirstChildWhichIsA("BasePart", true)
        end
    end

    if not part then
        local pos = (typeof(instance) == "Instance" and GetNPCPosition(instance)) or fallbackPos
        if pos then
            part = CreateESPAnchorPart("Proxy_" .. tostring(espCategory) .. "_" .. tostring(name), pos)
            isProxyPart = true
        end
    end
    if not part then return end

    local cfgKey = ESP_CATEGORY_KEYS[espCategory]
    local isEnabledNow = cfgKey and (Config[cfgKey] == true) or false

    local bb = Instance.new("BillboardGui")
    bb.Name = "ESP_" .. tostring(name)
    bb.Size = UDim2.new(0, 175, 0, 26)
    bb.StudsOffset = Vector3.new(0, 3.0, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = math.huge
    bb.Enabled = isEnabledNow
    bb.Adornee = part
    bb.Parent = espFolder

    local f = Instance.new("Frame", bb)
    f.Size = UDim2.new(1, 0, 1, 0)
    f.BackgroundColor3 = Colors.Background
    f.BackgroundTransparency = 0.15
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 5)
    local s = Instance.new("UIStroke", f)
    s.Color = color or Colors.PurpleAccent
    s.Thickness = 1.4

    local lbl = Instance.new("TextLabel", f)
    lbl.Size = UDim2.new(1, -8, 1, 0)
    lbl.Position = UDim2.new(0, 4, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.Text = (icon or "") .. " " .. tostring(name)
    lbl.TextColor3 = color or Colors.TextWhite
    lbl.TextSize = 11

    local hl = nil
    if typeof(instance) == "Instance" and (instance:IsA("Model") or instance:IsA("BasePart")) and not isProxyPart then
        pcall(function()
            hl = Instance.new("Highlight")
            hl.Name = "IdenticalHighlight"
            hl.Adornee = instance
            hl.FillColor = color or Colors.PurpleAccent
            hl.OutlineColor = Colors.TextWhite
            hl.FillTransparency = 0.65
            hl.OutlineTransparency = 0.05
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Enabled = isEnabledNow
            hl.Parent = espFolder
        end)
    end

    activeESP[instance] = {
        gui = bb,
        highlight = hl,
        label = lbl,
        part = part,
        isProxyPart = isProxyPart,
        espCategory = espCategory,
        name = name,
        icon = icon or "",
        lastDist = -1
    }
end

-- 销毁并移除指定实例关联的 ESP 标签、Highlight 与代理锚点
local function RemoveESP(instance)
    local data = activeESP[instance]
    if data then
        if data.gui and data.gui.Parent then pcall(function() data.gui:Destroy() end) end
        if data.highlight and data.highlight.Parent then pcall(function() data.highlight:Destroy() end) end
        if data.isProxyPart and data.part and data.part.Parent then pcall(function() data.part:Destroy() end) end
        activeESP[instance] = nil
    end
end

-- 预置跨全图固定点位 ESP 锚点（即使玩家站在起始岛、远端岛屿因流式加载尚未刷出模型，开启神灵/Boss/秘密鱼竿 ESP 也能立即跨全图穿墙看到方位与距离！）
do
    local spiritLandmarks = {
        {key = "Landmark_Spirit_Bamboo", name = "竹岛神灵祭坛", pos = Vector3.new(-1223.0, 10.3, -24.1), icon = "⛩️"},
        {key = "Landmark_Spirit_Frost",  name = "冰霜岛神灵祭坛", pos = Vector3.new(-1366.0, 14.9, -1495.4), icon = "❄️"},
        {key = "Landmark_Spirit_Amber",  name = "琥珀岛神灵祭坛", pos = Vector3.new(1259.4, 12.1, 1401.5), icon = "🔥"},
    }
    for _, sp in ipairs(spiritLandmarks) do
        local anchor = CreateESPAnchorPart(sp.key, sp.pos)
        AddESP(anchor, sp.name, "GodSpirit", Colors.AccentGreen, sp.icon, sp.pos)
    end

    local bossLandmarks = {
        {key = "Landmark_Boss_Enzo",   name = "恩佐 (Enzo Boss竞技场)", pos = Vector3.new(-115.3, 12.2, 1349.5), icon = "👹"},
        {key = "Landmark_Boss_Octo",   name = "无名章鱼寄生体 (隐藏Boss)", pos = Vector3.new(1608.2, 8.0, -218.3), icon = "🐙"},
        {key = "Landmark_Boss_Dragon", name = "龙钓海 Boss挑战区", pos = Vector3.new(2745.2, 13.6, -79.4), icon = "🐉"},
    }
    for _, bm in ipairs(bossLandmarks) do
        local anchor = CreateESPAnchorPart(bm.key, bm.pos)
        AddESP(anchor, bm.name, "Boss", Colors.AccentRed, bm.icon, bm.pos)
    end

    local rodLandmarks = {
        {key = "Landmark_Rod_Anchor",     name = "锚定鱼竿 (主权岛秘密竿)", pos = Vector3.new(-1208.5, 56.3, 1646.2), icon = "🌟"},
        {key = "Landmark_Rod_ShadowCave", name = "火焰鲨鱼竿 / 暗影秘密山洞", pos = Vector3.new(-8.4, 55.9, 6.7), icon = "🌟"},
        {key = "Landmark_Rod_Siren",      name = "海妖鱼竿 (琥珀岛秘密竿)", pos = Vector3.new(1543.8, 73.4, 1490.9), icon = "🌟"},
        {key = "Landmark_Rod_BambooAsc",  name = "升华竹竿 (竹岛高崖秘密竿)", pos = Vector3.new(-1360.6, 140.6, 31.0), icon = "🌟"},
        {key = "Landmark_Rod_LifeBloom",  name = "生命绽放鱼竿 (鲈鱼岛秘密竿)", pos = Vector3.new(-114.9, 74.9, -1533.2), icon = "🌟"},
        {key = "Landmark_Rod_Demon",      name = "恶魔鱼竿 (椰子岛秘密竿)", pos = Vector3.new(1181.9, 82.9, -1243.8), icon = "🌟"},
        {key = "Landmark_Rod_BiaoDi",     name = "世界表弟 (神话鱼竿合成台)", pos = Vector3.new(-151.4, 10.7, -49.9), icon = "🎣"},
    }
    for _, rm in ipairs(rodLandmarks) do
        local anchor = CreateESPAnchorPart(rm.key, rm.pos)
        AddESP(anchor, rm.name, "SecretRod", Colors.AccentYellow, rm.icon, rm.pos)
    end
end

-- 启动瞬间自动执行一次全图 ProximityPrompt 净化（即使上次旧脚本遗留了 999999 粘滞弹窗也能在 1 秒内立即清除）
task.spawn(function()
    task.wait(0.2)
    if isRunning and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(true)
    end
end)

-- 立即扫描并挂载动态世界目标与全体玩家 ESP（兼容 StreamingEnabled 远距流式卸载，无需等待 1.25s 雷达周期）
local function ScanAndMountDynamicESP()
    -- 1) 扫描全体其他玩家（即使远端玩家因 StreamingEnabled 未加载 HumanoidRootPart，也通过 GetPivot 代理锚点 100% 挂载高亮）
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local pChar = p.Character or Workspace:FindFirstChild(p.Name)
            if pChar then
                local pPos = GetNPCPosition(pChar)
                AddESP(pChar, p.DisplayName or p.Name, "Players", Colors.PurpleAccent, "👤", pPos)
            end
        end
    end
    -- 2) 扫描秘密鱼竿、船只与 Boss 容器
    for _, srName in ipairs({"SecretRod", "SecretRods", "Rods"}) do
        local srFolder = Workspace:FindFirstChild(srName)
        if srFolder then
            for _, r in ipairs(srFolder:GetChildren()) do AddESP(r, r.Name, "SecretRod", Colors.AccentYellow, "🌟", GetNPCPosition(r)) end
        end
    end
    for _, btName in ipairs({"Boat", "Boats", "Vehicles"}) do
        local boatFolder = Workspace:FindFirstChild(btName)
        if boatFolder then
            for _, b in ipairs(boatFolder:GetChildren()) do AddESP(b, b.Name, "Boats", Colors.AccentBlue, "⛵", GetNPCPosition(b)) end
        end
    end
    local bossFolder = Workspace:FindFirstChild("BossSetUp")
    if bossFolder then
        for _, b in ipairs(bossFolder:GetChildren()) do AddESP(b, b.Name, "Boss", Colors.AccentRed, "👹", GetNPCPosition(b)) end
    end
    -- 3) 同步挂载 liveNPCs 中已探测到的活跃神灵、道士/茅山/傻子商人与四圣兽
    for _, key in ipairs(liveNPCOrder) do
        local entry = liveNPCs[key]
        if entry and entry.inst and entry.inst.Parent then
            if key:find("^Spirit_") then
                AddESP(entry.inst, entry.name, "GodSpirit", Colors.AccentGreen, entry.icon, entry.pos)
            elseif key == "Taoist" or key == "DumbGuy" then
                AddESP(entry.inst, entry.name, "Taoist", Colors.AccentOrange, entry.icon, entry.pos)
            elseif key == "Maoshan" then
                AddESP(entry.inst, entry.name, "Maoshan", Colors.PurplePrimary, entry.icon, entry.pos)
            else
                AddESP(entry.inst, entry.name, "Boss", Colors.AccentRed, entry.icon, entry.pos)
            end
        end
    end
end

-- 监听新玩家加入与角色重生，确保开启玩家 ESP 期间新进服或重生的玩家立即挂载 ESP
do
    local function bindPlayerESPChar(p)
        if p == LocalPlayer then return end
        table.insert(activeConnections, p.CharacterAdded:Connect(function(newChar)
            if not isRunning then return end
            task.delay(0.25, function()
                if isRunning and newChar and newChar.Parent then
                    AddESP(newChar, p.DisplayName or p.Name, "Players", Colors.PurpleAccent, "👤", GetNPCPosition(newChar))
                end
            end)
        end))
    end
    for _, p in ipairs(Players:GetPlayers()) do bindPlayerESPChar(p) end
    table.insert(activeConnections, Players.PlayerAdded:Connect(bindPlayerESPChar))
end

-- 刷新所有已注册 ESP 的显隐状态与实时距离文本（开启开关时先执行即时扫描，且远距流式卸载时自动切换代理锚点绝不误删）
local function RefreshAllESPNow(toggledCategory, toggledState, labelTitle)
    -- 当用户手动开启任意 ESP 开关时，先立即执行一次全目标扫描挂载，彻底消除“明明有玩家/目标却弹窗报无目标”的时序与流式卸载 Bug
    if toggledCategory and toggledState == true then
        if DashUI._runRadarPassNow and (toggledCategory == "GodSpirit" or toggledCategory == "Maoshan" or toggledCategory == "Taoist" or toggledCategory == "Boss") then
            pcall(DashUI._runRadarPassNow)
        end
        pcall(ScanAndMountDynamicESP)
    end

    if next(activeESP) == nil then
        if toggledCategory and toggledState == true and labelTitle then
            ShowNotification(labelTitle, string.format("已开启 %s（当前服暂无该目标，刷新时将自动高亮）！", labelTitle), "WARN", 3.5)
        end
        return
    end
    local anyESP = Config.ESP_GodSpirit or Config.ESP_SecretRod or Config.ESP_Boats
        or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_Boss or Config.ESP_Players
    if not anyESP and not toggledCategory then
        return
    end

    local currentCamera = Workspace.CurrentCamera or Camera
    local char = LocalPlayer.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    local refPos = (myRoot and myRoot.Position) or (currentCamera and currentCamera.CFrame.Position)
    local activeCountForCat = 0

    for inst, data in pairs(activeESP) do
        if not inst or not inst.Parent then
            RemoveESP(inst)
        else
            -- 动态兼容 StreamingEnabled：若目标真实 BasePart 因远距流式卸载变为 nil，自动无缝切换为 ProxyPart；若走近后真实 BasePart 加载完成，自动升级绑回真实零件！
            if data.isProxyPart then
                local realPart = nil
                if inst:IsA("Model") then
                    realPart = inst:FindFirstChild("HumanoidRootPart", true) or inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
                elseif not inst:IsA("BasePart") then
                    realPart = inst:FindFirstChildWhichIsA("BasePart", true)
                end
                if realPart and realPart.Parent then
                    if data.part and data.part.Parent and data.part ~= realPart then
                        pcall(function() data.part:Destroy() end)
                    end
                    data.part = realPart
                    data.isProxyPart = false
                    if data.gui then data.gui.Adornee = realPart end
                elseif data.part and data.part.Parent then
                    local latestPos = GetNPCPosition(inst)
                    if latestPos then data.part.Position = latestPos end
                end
            elseif not data.part or not data.part.Parent then
                local fallbackPos = GetNPCPosition(inst)
                if fallbackPos then
                    local proxy = CreateESPAnchorPart("Proxy_" .. tostring(data.espCategory) .. "_" .. tostring(data.name), fallbackPos)
                    data.part = proxy
                    data.isProxyPart = true
                    if data.gui then data.gui.Adornee = proxy end
                else
                    RemoveESP(inst)
                end
            end

            if activeESP[inst] and data.part and data.part.Parent then
                local cfgKey = ESP_CATEGORY_KEYS[data.espCategory]
                local isEnabled = cfgKey and (Config[cfgKey] == true) or false
                if data.gui.Enabled ~= isEnabled then data.gui.Enabled = isEnabled end
                if data.highlight and data.highlight.Parent and data.highlight.Enabled ~= isEnabled then
                    data.highlight.Enabled = isEnabled
                end
                if isEnabled then
                    if data.espCategory == toggledCategory then
                        activeCountForCat = activeCountForCat + 1
                    end
                    if refPos then
                        local dist = math.floor((refPos - data.part.Position).Magnitude)
                        if data.lastDist ~= dist then
                            data.lastDist = dist
                            data.label.Text = data.icon .. " " .. data.name .. " [" .. dist .. "米]"
                        end
                    end
                end
            end
        end
    end

    if toggledCategory and toggledState == true and labelTitle then
        if toggledCategory == "Players" and activeCountForCat == 0 then
            local otherPlayerCount = math.max(0, #Players:GetPlayers() - 1)
            if otherPlayerCount > 0 then
                activeCountForCat = otherPlayerCount
            end
        end
        if activeCountForCat > 0 then
            ShowNotification(labelTitle, string.format("已开启 %s，当前已高亮 %d 个目标点位！", labelTitle, activeCountForCat), "SUCCESS", 3)
        else
            ShowNotification(labelTitle, string.format("已开启 %s（当前服暂无该目标，刷新时将自动高亮）！", labelTitle), "WARN", 3.5)
        end
    end
end

DashUI._refreshESPNow = RefreshAllESPNow

-- ==========================================
-- 自动化循环 Heartbeat + 统一后台调度器 + 纯净渲染循环 RenderStepped
-- 独立函数作用域：避免顶层 local 超过 Luau 200 寄存器上限导致整脚本编译失败、UI 不出现
-- ==========================================
-- ============================================================================
-- 【模块 26：核心运行时引擎 (IdenticalStartRuntimeLoops) —— 手机钓鱼按钮守护、Boss弹窗与技能按键缓存】
-- 作用说明：
--   1. 独立函数作用域封装运行时高频状态变量，避免顶层 local 变量超过 Luau 200 寄存器上限；
--   2. 精准定位并守护移动端右侧【钓鱼】圆钮（关闭自动抛竿时自动恢复显示并绑定手动点击兜底）；
--   3. 缓存 PlayerGui / MainGui / Fishing / BossFightBar 及 Z/X/C/V 技能按钮引用，消除高频查找开销。
-- ============================================================================
local function IdenticalStartRuntimeLoops()
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
local lastSecretBaitCraftTime = 0
local lastEquipNamelessTime = 0
local lastFullBagWarnTime = 0
local lastGachaTime = 0
local lastBossTime = 0
DashUI._resetBossTimer = function()
    lastBossTime = 0
end
DashUI._resetSellTimer = function()
    lastSellTime = tick()
end
local lastSlamChargeTime = 0
local lastRhythmTime = 0
local lastHookScanTime = 0
local cachedIsHooked = false
local cachedHookedPos = nil
local cachedHookedFish = nil
local wasInMinigame = false

local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

-- FireGuiButton 已提升至上层作用域，供任务对话与小游戏共用

-- 零GC事件缓存：复用上层统一维护的 cachedBossPrompts + 缓存 Z/X/C/V 技能按钮 + 缓存 PlayerGui/PlayerData 与 Workspace 文件夹引用
local cachedSkillButtons = {}
local cachedWsFolders = {}
local function GetWorkspaceFolder(folderName)
    local f = cachedWsFolders[folderName]
    if f and f.Parent == Workspace then
        return f
    end
    f = Workspace:FindFirstChild(folderName)
    cachedWsFolders[folderName] = f
    return f
end
local cachedEventRemotes = {}
local function GetEventRemote(name)
    if not Events then return nil end
    local r = cachedEventRemotes[name]
    if r and r.Parent == Events then
        return r
    end
    r = Events:FindFirstChild(name)
    cachedEventRemotes[name] = r
    return r
end
local lastSkillBtnScanTime = 0
local lastGuiDataCacheTime = 0
local cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar = nil, nil, nil, nil, nil
local cachedBarInner, cachedBossBarInner, cachedBossHitbox, cachedProgBarInner = nil, nil, nil, nil
local cachedPerfectBtn, cachedChargeBtn, cachedHurt1, cachedHurt2 = nil, nil, nil, nil
local lastFishRingPos = nil
local cachedMobileFishBtn = nil
local cachedMobileFishContainer = nil
local cachedAutoFishBtn = nil
local hookedManualFishBtns = setmetatable({}, { __mode = "k" })
local lastMobileFishBtnScan = 0
local lastFishBtnRestoreTime = 0
local lastQTEHitTime = 0

DashUI._onAutoCastDisabled = function()
    lastCastTime = tick()
end

-- 为右侧【钓鱼】圆钮绑定手动点击兜底：当关闭脚本自动抛竿后，若游戏原生 LocalScript 因切物品状态卡死未能响应点击，自动补发一次抛竿请求！
local function BindManualFishButtonFallback(btn)
    if not btn or hookedManualFishBtns[btn] then return end
    hookedManualFishBtns[btn] = true
    pcall(function()
        btn.MouseButton1Click:Connect(function()
            if not isRunning or Config.AutoCast or Config.AutoFarmBoss or Config.AutoFarmSecretBoss then return end
            task.delay(0.15, function()
                if not isRunning or Config.AutoCast then return end
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not char or not root then return end
                local isFishingNow = attrFishing
                local isMiniNow = attrMinigame or cachedIsHooked
                if not isFishingNow and not isMiniNow and IsCharacterHoldingFishingRod(char, GetPlayerData()) then

                    if Events and Events:FindFirstChild("Fishing") then
                        pcall(function() Events.Fishing:FireServer(root.CFrame) end)
                    end
                end
            end)
        end)
    end)
end

-- 精准定位手机端右侧 HUD 上的【钓鱼】大圆钮与【自动钓鱼】圆钮：
-- 绝不匹配背包/图鉴/商店面板内部的隐藏 "Fish" 按钮，也绝不乱开未知父级面板遮挡左侧技能按钮！
local function GetMobileFishingButton(now)
    now = now or tick()
    -- 缓存判活只看 Parent，Visible 由外部守护逻辑负责，避免原版每帧隐藏导致缓存永远失效而反复全屏扫描
    if cachedMobileFishBtn and cachedMobileFishBtn.Parent then
        return cachedMobileFishBtn
    end
    -- 扫描节流 3.5s → 10s，减少无效全 Descendants 开销
    if now - lastMobileFishBtnScan < 10.0 then
        return nil
    end
    lastMobileFishBtnScan = now
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end

    local bestVisibleCandidate = nil
    local bestHiddenHudCandidate = nil
    local hudRoots = {}

    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Name ~= "IdenticalHeavyweightFishing" and g.Name ~= "RobloxGui" then
            local gn = g.Name:lower()
            -- 跳过明显的背包/商店/图鉴/任务/设置类 GUI，不做后代扫描
            local isMenu = gn:find("inventory") or gn:find("shop")
                or gn:find("bag") or gn:find("index")
                or gn:find("quest") or gn:find("setting")
                or gn:find("store") or gn:find("catalog")
            if not isMenu then
                if gn == "maingui" then
                    -- 对 MainGui 跳过 Menu/Inventory/Shop/Index 等重型子容器，避免遍历数百个背包鱼格子造成卡顿
                    for _, sub in ipairs(g:GetChildren()) do
                        local sn = sub.Name:lower()
                        if sn ~= "menu" and not sn:find("inventory") and not sn:find("shop") and not sn:find("index") and not sn:find("bag") then
                            table.insert(hudRoots, sub)
                        end
                    end
                else
                    table.insert(hudRoots, g)
                end
            end
        end
    end

    for _, rootContainer in ipairs(hudRoots) do
        for _, d in ipairs(rootContainer:GetDescendants()) do
                if d:IsA("TextButton") or d:IsA("ImageButton") then
                    local txt = ""
                    if d:IsA("TextButton") then
                        txt = (d.Text or ""):lower():match("^%s*(.-)%s*$")
                    end
                    if txt == "" then
                        local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                        if lbl then txt = (lbl.Text or ""):lower():match("^%s*(.-)%s*$") end
                    end
                    if txt == "" and d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X < 220 then
                        for _, sib in ipairs(d.Parent:GetChildren()) do
                            if sib:IsA("TextLabel") then
                                local st = (sib.Text or ""):lower():match("^%s*(.-)%s*$")
                                if st ~= "" then txt = st; break end
                            end
                        end
                    end
                    local dn = (d.Name or ""):lower()
                    local pn = (d.Parent and d.Parent.Name or ""):lower()
                    if txt:find("自动钓鱼", 1, true) or txt:find("auto fish", 1, true) or dn:find("autofish", 1, true) or pn:find("autofish", 1, true) then
                        cachedAutoFishBtn = d
                    elseif (txt == "钓鱼" or txt == "fish" or dn == "fishbutton" or dn == "fishingbutton" or dn == "castbutton" or pn == "fishbutton" or pn == "fishingbutton")
                        and not txt:find("自动", 1, true) and not txt:find("auto", 1, true) and not dn:find("auto", 1, true) and not pn:find("auto", 1, true) then
                        -- 排除背包/商店/设置弹窗内的按钮，只锁定右侧 HUD 钓鱼圆钮
                        local fullLow = d:GetFullName():lower()
                        local isMenuBtn = fullLow:find("inventory", 1, true) or fullLow:find("shop", 1, true) or fullLow:find("bag", 1, true) or fullLow:find("index", 1, true) or fullLow:find("quest", 1, true) or fullLow:find("setting", 1, true)
                        if not isMenuBtn then
                            if d.Visible then
                                bestVisibleCandidate = d
                            elseif not bestHiddenHudCandidate then
                                bestHiddenHudCandidate = d
                            elseif cachedAutoFishBtn and (d.Parent == cachedAutoFishBtn.Parent or (d.Parent and cachedAutoFishBtn.Parent and d.Parent.Parent == cachedAutoFishBtn.Parent.Parent)) then
                                bestHiddenHudCandidate = d
                            end
                        end
                    end
                end
            end
        end

    local chosen = bestVisibleCandidate or bestHiddenHudCandidate or cachedMobileFishBtn
    if chosen and chosen.Parent then
        cachedMobileFishBtn = chosen
        -- 仅当外层是尺寸小于 220px 的单个圆钮小包装框时才记录为 container，绝不记录全屏大面板（防止遮挡左侧技能按钮导致技能无法点击！）
        local par = chosen.Parent
        if par and par:IsA("GuiObject") and par.Name ~= "MainGui" and par.Name ~= "Fisher_GUI" and par.Name ~= "Fishing"
            and par.AbsoluteSize.X > 0 and par.AbsoluteSize.X < 220 and par.AbsoluteSize.Y < 220 then
            cachedMobileFishContainer = par
        else
            cachedMobileFishContainer = nil
        end
        if sharedEnv then
            sharedEnv.IdenticalProtectedFishBtn = cachedMobileFishBtn
            sharedEnv.IdenticalProtectedFishContainer = cachedMobileFishContainer
        end
        BindManualFishButtonFallback(chosen)
        return chosen
    end
    return nil
end

-- 当玩家关闭自动抛竿且手持鱼竿时，恢复被原版脚本隐藏的【钓鱼】圆钮：
-- 严格遵循《钓鱼图标异常修改.html》第3节：绝不篡改 Character.Fishing 服务端同步属性，也绝不遍历开启上层未知 Frame 遮挡技能按钮！
RestoreMobileFishingButtonUI = function(forceRefreshGui)
    local now = tick()
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end

    if forceRefreshGui then
        lastMobileFishBtnScan = 0
        if not Config.HideGameUI then
            local fisherGui = pg:FindFirstChild("Fisher_GUI")
            if fisherGui and fisherGui:IsA("ScreenGui") then
                pcall(function()
                    fisherGui.Enabled = false
                    task.delay(0.08, function()
                        if isRunning and not Config.HideGameUI and fisherGui and fisherGui.Parent then
                            fisherGui.Enabled = true
                        end
                    end)
                end)
            end
        end
    end

    local fishBtn = GetMobileFishingButton(now)
    if not fishBtn or not fishBtn.Parent then return false end

    local char = LocalPlayer.Character
    local pData = cachedPData or GetPlayerData()
    local autoFishShown = (cachedAutoFishBtn and cachedAutoFishBtn.Parent and cachedAutoFishBtn.Visible)
    local holdingRod = IsCharacterHoldingFishingRod(char, pData)
    local shouldKeepVisible = (not Config.AutoCast and not Config.AutoFarmBoss and not Config.AutoFarmSecretBoss and not Config.HideGameUI) and (autoFishShown or holdingRod or forceRefreshGui)

    if sharedEnv then
        sharedEnv.IdenticalKeepFishBtnVisible = shouldKeepVisible
        sharedEnv.IdenticalProtectedFishBtn = fishBtn
        sharedEnv.IdenticalProtectedFishContainer = cachedMobileFishContainer
    end

    if shouldKeepVisible then
        pcall(function()
            if not fishBtn.Visible then fishBtn.Visible = true end
            if not fishBtn.Active then fishBtn.Active = true end
            if cachedMobileFishContainer and cachedMobileFishContainer.Parent and not cachedMobileFishContainer.Visible then
                cachedMobileFishContainer.Visible = true
            end
        end)
        BindManualFishButtonFallback(fishBtn)
        return true
    end
    return false
end

-- 递归向上检查按钮的所有父级容器是否均处于 Visible = true 状态（防止误点已隐藏面板内部的按钮）
local function IsGuiHierarchyVisible(guiObj, stopAt)
    local cur = guiObj
    while cur and cur ~= stopAt do
        if cur:IsA("GuiObject") and not cur.Visible then
            return false
        elseif cur:IsA("ScreenGui") and not cur.Enabled then
            return false
        end
        cur = cur.Parent
    end
    return true
end

-- 仅当用户显式开启 Config.AutoFarmBoss 时，自动在弹出的 Boss Fight 窗口中选择难度（简单/困难/噩梦）并点击 Fight
local function TrySelectAndStartEnzoModal(mainGui)
    if not Config.AutoFarmBoss then return false end
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    local containers = {}
    if mainGui then
        -- 只收集名字与 Boss 弹窗相关的可见子面板，避免对背包等大面板做 GetDescendants
        for _, ch in ipairs(mainGui:GetChildren()) do
            if ch:IsA("GuiObject") and ch.Visible then
                local cn = ch.Name:lower()
                if cn:find("boss") or cn:find("fight") or cn:find("enzo")
                    or cn:find("quest") or cn:find("dialog") or cn:find("modal")
                    or cn:find("popup") or cn:find("prompt") then
                    table.insert(containers, ch)
                end
            end
        end
    end
    if pg then
        for _, g in ipairs(pg:GetChildren()) do
            if g:IsA("ScreenGui") and g.Enabled and g ~= mainGui
                and g.Name ~= "IdenticalHeavyweightFishing" and g.Name ~= "RobloxGui" then
                local gn = g.Name:lower()
                if gn:find("boss") or gn:find("fight") or gn:find("enzo")
                    or gn:find("quest") or gn:find("dialog") then
                    table.insert(containers, g)
                end
            end
        end
    end
    for _, ch in ipairs(containers) do
        local fightBtn = nil
        local diffBtns = {}
        local okBtn = nil
        local closePopupBtn = nil
        for _, d in ipairs(ch:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.Active and IsGuiHierarchyVisible(d, ch) then
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
                elseif not closePopupBtn and (txt:find("点击以关闭") or txt:find("关闭") or txt == "close" or txt == "claim") then
                    closePopupBtn = d
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
        elseif closePopupBtn then
            FireGuiButton(closePopupBtn)
            return true
        end
    end
    return false
end

-- 定期（0.6s）刷新并缓存 PlayerData、PlayerGui、MainGui、Fishing、BossFightBar 及小游戏子控件引用
local function RefreshGuiAndDataRefs(now)
    if now - lastGuiDataCacheTime < 0.6
        and cachedPG and cachedPG.Parent
        and (not cachedMainGui or cachedMainGui.Parent)
        and (not cachedFUI or cachedFUI.Parent)
        and (not cachedBossBar or cachedBossBar.Parent) then
        return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
    end
    lastGuiDataCacheTime = now
    cachedPData = GetPlayerData()
    cachedPG = LocalPlayer:FindFirstChild("PlayerGui")
    cachedMainGui = cachedPG and cachedPG:FindFirstChild("MainGui")
    local fisherGui = cachedPG and cachedPG:FindFirstChild("Fisher_GUI")
    cachedFUI = (cachedMainGui and cachedMainGui:FindFirstChild("Fishing"))
        or (cachedPG and cachedPG:FindFirstChild("Fishing"))
        or (fisherGui and fisherGui:FindFirstChild("Fishing"))
    cachedBossBar = cachedFUI and cachedFUI:FindFirstChild("BossFightBar")

    local barFrame = cachedFUI and cachedFUI:FindFirstChild("BarFrame")
    cachedBarInner = barFrame and barFrame:FindFirstChild("Bar")
    cachedBossBarInner = cachedBossBar and cachedBossBar:FindFirstChild("Bar")
    cachedBossHitbox = cachedBossBar and (cachedBossBar:FindFirstChild("Hitbox") or cachedBossBar:FindFirstChild("GreenZone") or cachedBossBar:FindFirstChild("Target"))
    local hpPlayer = cachedFUI and cachedFUI:FindFirstChild("HPPlayer")
    local progBar = hpPlayer and hpPlayer:FindFirstChild("ProgressionBar")
    cachedProgBarInner = progBar and progBar:FindFirstChild("Bar")
    cachedPerfectBtn = cachedFUI and cachedFUI:FindFirstChild("PerfectButton")
    cachedChargeBtn = cachedFUI and cachedFUI:FindFirstChild("Charge")
    local cutscene = cachedMainGui and cachedMainGui:FindFirstChild("Cutscene")
    cachedHurt1 = cutscene and cutscene:FindFirstChild("Hurt")
    local impactGui = cachedPG and cachedPG:FindFirstChild("Impact")
    local impactCutscene = impactGui and impactGui:FindFirstChild("Cutscene")
    cachedHurt2 = impactCutscene and impactCutscene:FindFirstChild("Hurt")

    return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
end

local SKILL_KEYS = {"Z", "X", "C", "V"}
-- 判断指定 UI 按钮是否对应 Z / X / C / V 技能槽位（排除关闭/取消按钮）
local function DoesButtonMatchSkillKey(d, key)
    local rawName = (d.Name or ""):match("^%s*(.-)%s*$"):upper()
    local rawLow = rawName:lower()
    if rawLow:find("close", 1, true) or rawLow:find("exit", 1, true) or rawLow:find("cancel", 1, true) or rawLow:find("quit", 1, true) or rawLow:find("delete", 1, true) then
        return false
    end
    if rawName == key
        or rawName == ("SKILL" .. key) or rawName == ("SKILL_" .. key) or rawName == ("SKILL " .. key)
        or rawName == ("KEY" .. key) or rawName == ("KEY_" .. key) or rawName == ("SLOT" .. key) or rawName == ("BTN" .. key) then
        return true
    end
    if d:IsA("TextButton") then
        local t = (d.Text or ""):match("^%s*(.-)%s*$"):upper()
        if t == key or t == ("[" .. key .. "]") then
            return true
        end
    end
    -- 只查一层子 TextLabel，避免 GetDescendants 深扫
    for _, sub in ipairs(d:GetChildren()) do
        if sub:IsA("TextLabel") and sub.Visible then
            local st = (sub.Text or ""):match("^%s*(.-)%s*$"):upper()
            if st == key or st == ("[" .. key .. "]") then
                return true
            end
        end
    end
    if d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X > 10 and d.Parent.AbsoluteSize.X < 180 then
        for _, sib in ipairs(d.Parent:GetChildren()) do
            if sib:IsA("TextLabel") and sib.Visible then
                local st = (sib.Text or ""):match("^%s*(.-)%s*$"):upper()
                if st == key or st == ("[" .. key .. "]") then
                    return true
                end
            end
        end
    end
    return false
end

-- 获取或扫描指定技能键（Z/X/C/V）对应的屏幕 UI 按钮引用（带 4s 扫描节流，保留仍有效的已缓存槽位并跳过 MainGui.Menu）
local function GetCachedSkillButton(sk, now)
    local btn = cachedSkillButtons[sk]
    if btn and btn.Parent and btn.Visible and btn.AbsoluteSize.X > 5 then
        return btn
    end
    if now - lastSkillBtnScanTime < 4.0 then return nil end
    lastSkillBtnScanTime = now
    for k, oldBtn in pairs(cachedSkillButtons) do
        if not oldBtn or not oldBtn.Parent or not oldBtn.Visible or oldBtn.AbsoluteSize.X <= 5 then
            cachedSkillButtons[k] = nil
        end
    end
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local searchRoots = {}
    if cachedFUI then table.insert(searchRoots, cachedFUI) end
    local fisherGui = pg:FindFirstChild("Fisher_GUI")
    if fisherGui then table.insert(searchRoots, fisherGui) end
    if cachedMainGui then
        for _, sub in ipairs(cachedMainGui:GetChildren()) do
            local sn = sub.Name:lower()
            if sn ~= "menu" and sn ~= "fishing" and not sn:find("inventory") and not sn:find("shop") and not sn:find("index") then
                table.insert(searchRoots, sub)
            end
        end
    end
    for _, rootInst in ipairs(searchRoots) do
        for _, d in ipairs(rootInst:GetDescendants()) do
            if (d:IsA("GuiButton") or d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 5 then
                for kIdx = 1, #SKILL_KEYS do
                    local key = SKILL_KEYS[kIdx]
                    if not cachedSkillButtons[key] and DoesButtonMatchSkillKey(d, key) then
                        cachedSkillButtons[key] = d
                    end
                end
            end
        end
    end
    return cachedSkillButtons[sk]
end

-- 遍历并触发已缓存的 Boss 相关 ProximityPrompt，同时清理已销毁的失效引用
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

-- [性能优化 #6 / 建议 #7] 已在全局合并唯一一对 Workspace.DescendantAdded/Removing 与启动分帧预热，此处不再重复挂载第二套监听器

local waterPlatform = Instance.new("Part"); waterPlatform.Name = "IdenticalWaterPlatform"; waterPlatform.Size = Vector3.new(60, 2, 60); waterPlatform.Anchored = true; waterPlatform.CanCollide = false; waterPlatform.Transparency = 1; waterPlatform.Parent = Workspace
table.insert(cleanUpInstances, waterPlatform)

local uidHealthKey = tostring(LocalPlayer.UserId) .. "_PlayerHealth"

-- [性能优化 #8 & #12 / Bug修复 #3] 事件驱动 + 全别名匹配维护 Workspace 根子节点候选 Model 集合：
-- 1) 完整覆盖神灵、道士/茅山/傻子商人全别名（含越文/拼音/空格写法）、四圣兽、恩佐/章鱼/龙钓海 Boss 等关键词；
-- 2) 配合 stepWorldRadar 内的实时重校验与后台调度器每 30s 一次的增量补扫，彻底解决 Model 插入后再改名的漏检回归问题。
local wsRootRadarModels = setmetatable({}, { __mode = "k" })
local function HasRadarKeyword(str)
    if not str or str == "" then return false end
    return (str:find("spirit", 1, true) or str:find("god", 1, true) or str:find("shrine", 1, true) or str:find("altar", 1, true)
        or str:find("pray", 1, true) or str:find("blessing", 1, true) or str:find("worship", 1, true) or str:find("statue", 1, true)
        or str:find("amber", 1, true) or str:find("frost", 1, true) or str:find("bamboo", 1, true)
        or str:find("tinh linh", 1, true) or str:find("than linh", 1, true) or str:find("thần", 1, true) or str:find("mieu", 1, true) or str:find("miếu", 1, true)
        or str:find("ban tho", 1, true) or str:find("bàn thờ", 1, true) or str:find("cau nguyen", 1, true) or str:find("cầu nguyện", 1, true)
        or str:find("神灵", 1, true) or str:find("神明", 1, true) or str:find("祭坛", 1, true) or str:find("神龛", 1, true) or str:find("祈祷", 1, true) or str:find("祝福", 1, true) or str:find("琥珀", 1, true)
        or str:find("taoist", 1, true) or str:find("daoshi", 1, true) or str:find("dao si", 1, true) or str:find("đạo sĩ", 1, true) or str:find("道士", 1, true)
        or str:find("maoshan", 1, true) or str:find("mao shan", 1, true) or str:find("mao son", 1, true) or str:find("mao sơn", 1, true) or str:find("dai su huynh", 1, true) or str:find("đại sư huynh", 1, true) or str:find("茅山", 1, true) or str:find("大师兄", 1, true)
        or str:find("dumb", 1, true) or str:find("thang ngu", 1, true) or str:find("thằng ngu", 1, true) or str:find("thang ngoc", 1, true) or str:find("merchant", 1, true) or str:find("傻子", 1, true)
        or str:find("bird", 1, true) or str:find("vermilion", 1, true) or str:find("vermillion", 1, true) or str:find("chu tuoc", 1, true) or str:find("chu tước", 1, true) or str:find("phoenix", 1, true) or str:find("朱雀", 1, true)
        or str:find("tortoise", 1, true) or str:find("huyen vu", 1, true) or str:find("huyền vũ", 1, true) or str:find("black", 1, true) or str:find("玄武", 1, true)
        or str:find("tiger", 1, true) or str:find("bach ho", 1, true) or str:find("bạch hổ", 1, true) or str:find("white", 1, true) or str:find("白虎", 1, true)
        or str:find("dragon", 1, true) or str:find("thanh long", 1, true) or str:find("azure", 1, true) or str:find("青龙", 1, true)
        or str:find("boss", 1, true) or str:find("enzo", 1, true) or str:find("octo", 1, true) or str:find("parasite", 1, true) or str:find("buoy", 1, true) or str:find("whale", 1, true)
        or str:find("angler", 1, true) or str:find("yasuo", 1, true) or str:find("shaolin", 1, true) or str:find("npc", 1, true)
        or str:find("quest", 1, true) or str:find("giver", 1, true) or str:find("ticket", 1, true) or str:find("sage", 1, true)
        or str:find("nana", 1, true) or str:find("biao", 1, true) or str:find("chu", 1, true) or str:find("giang", 1, true)
        or str:find("lao", 1, true) or str:find("shadow", 1, true) or str:find("nanjang", 1, true) or str:find("nanjiang", 1, true)
        or str:find("ba chang", 1, true) or str:find("bac minh", 1, true) or str:find("ha dieu de", 1, true) or str:find("dawan", 1, true)
        or str:find("doan", 1, true) or str:find("blind", 1, true) or str:find("finger", 1, true) or str:find("shi xing", 1, true) or str:find("monkey", 1, true)) ~= nil
end
local function IsWorkspaceRootRadarCandidate(ch)
    if not ch or IsMapOrIslandContainer(ch) then return false end
    if not (ch:IsA("Model") or ch:IsA("BasePart") or ch:IsA("Folder")) then return false end
    local cn = (ch.Name or ""):lower()
    if cn:find("rod", 1, true) or cn == "identicallock" or cn:find("identical", 1, true) or cn == "terrain" or cn == "camera" then
        return false
    end
    return HasRadarKeyword(cn)
end
for _, ch in ipairs(Workspace:GetChildren()) do
    if IsWorkspaceRootRadarCandidate(ch) then
        wsRootRadarModels[ch] = true
    end
end
table.insert(activeConnections, Workspace.ChildAdded:Connect(function(ch)
    if IsWorkspaceRootRadarCandidate(ch) then
        wsRootRadarModels[ch] = true
    elseif ch and ch:IsA("Model") then
        task.defer(function()
            if isRunning and ch.Parent == Workspace and IsWorkspaceRootRadarCandidate(ch) then
                wsRootRadarModels[ch] = true
            end
        end)
    end
end))
table.insert(activeConnections, Workspace.ChildRemoved:Connect(function(ch)
    if ch then
        wsRootRadarModels[ch] = nil
        if cachedWsFolders[ch.Name] == ch then
            cachedWsFolders[ch.Name] = nil
        end
    end
end))

-- [性能优化 #11 & #13] 缓存解析后的技能释放队列：先转大写并去除空白分隔符后再比对快照，忽略大小写/空格差异引起的重复解析
local cachedEnabledSkills = {}
local lastSkillOrderSnapshot = nil
local lastSkillFlagsSnapshot = -1
local function GetEnabledSkillsList()
    local orderStr = (Config.SkillOrder or "Z,X,C,V"):upper():gsub("[%s,;|/]+", "")
    local flagsMask = (Config.SkillZ and 1 or 0) + (Config.SkillX and 2 or 0) + (Config.SkillC and 4 or 0) + (Config.SkillV and 8 or 0)
    if orderStr == lastSkillOrderSnapshot and flagsMask == lastSkillFlagsSnapshot then
        return cachedEnabledSkills
    end
    lastSkillOrderSnapshot = orderStr
    lastSkillFlagsSnapshot = flagsMask
    table.clear(cachedEnabledSkills)
    for i = 1, #orderStr do
        local sk = orderStr:sub(i, i)
        if sk == "Z" or sk == "X" or sk == "C" or sk == "V" then
            local allowed = (sk == "Z" and Config.SkillZ) or (sk == "X" and Config.SkillX)
                or (sk == "C" and Config.SkillC) or (sk == "V" and Config.SkillV)
            if allowed and not table.find(cachedEnabledSkills, sk) then
                table.insert(cachedEnabledSkills, sk)
            end
        end
    end
    if #cachedEnabledSkills == 0 then
        if Config.SkillZ then table.insert(cachedEnabledSkills, "Z") end
        if Config.SkillX then table.insert(cachedEnabledSkills, "X") end
        if Config.SkillC then table.insert(cachedEnabledSkills, "C") end
        if Config.SkillV then table.insert(cachedEnabledSkills, "V") end
    end
    return cachedEnabledSkills
end

-- ==========================================
-- ============================================================================
-- 【模块 27：统一后台时间片调度器（低频自动化 + 仪表盘统计 + 全图深度雷达扫描 + ESP清理）】
-- 作用说明：
--   1. 单协程分时错峰调度：0.15s 刷新 ESP 距离、0.25s 执行低频自动化（防卖上锁/卖鱼/票据任务/祈祷/扭蛋/喂猴/签到/合成买饵）、
--      0.50s 更新仪表盘与自动配装、1.25s（省电模式 2.5s）执行全图 NPC/神灵/商人/四圣兽/Boss 雷达扫描、5.0s 清理失效 ESP、
--      30.0s 执行一次 Workspace 根子节点改名增量补扫；
--   2. 每个子模块均由独立 pcall 保护，互不阻塞、零每帧空转。
-- ============================================================================
-- [性能优化 #10 / 建议 #2,#5,#16,#17] 统一后台时间片调度器
-- 将原先分散的 4 个常驻轮询协程（ESP 刷新 0.15s、仪表盘 0.5s、雷达 1.25s/2.5s、ESP 清理 5s）
-- 以及混在 Heartbeat 每帧里的 9 项低频业务（出售、保护上锁、祈祷、票据任务、扭蛋、喂猴子、每日奖励、制作/购买鱼饵）
-- 统一整合为单协程错峰调度，且每个子模块拥有独立 pcall 错误边界，零每帧空转、零同帧叠加！
-- ==========================================
local dashStartTime = tick()
local dashStartFish = 0
local dashStartCash = 0
local dashInitDone = false
local lastEquipCheck = 0
local lastPingCheck = 0
local baitLuckMap = { ["Ancestral Bait"] = 50, ["Elite Bait"] = 30, ["Corrupted Essence Bait"] = 18, ["Crude Mash Bait"] = 8, ["Basic Bait"] = 3 }
local rodPowerLookup = {
    ["Soul Thorn Rod"] = 72, ["Blazeshark Rod"] = 75, ["Sacred Bamboo Rod"] = 80,
    ["Ascended Bamboo Rod"] = 90, ["Pure Diamond Rod"] = 95, ["Maoshan Rod"] = 105,
    ["Legacy Rod"] = 110, ["Heaven Piercer"] = 120, ["Heavenpiercer Rod"] = 120,
}
for _, r in ipairs(allRods) do rodPowerLookup[r.name] = r.power end

-- [0.25s 周期] 执行低频自动化任务：自动收藏上锁、定时卖鱼、票据任务、神灵祈祷、自动扭蛋、喂猴子、每日签到及合成/购买鱼饵
local function stepLowFreqAutomation(now)
    -- [性能优化 #13] 移除此处未使用的 Humanoid 查找，仅校验 root 即可
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local pData = cachedPData or GetPlayerData()
    local isFishing = attrFishing
    local isMinigame = wasInMinigame or attrMinigame or cachedIsHooked
        or (cachedFUI and cachedFUI.Visible)
        or (cachedBossBar and cachedBossBar.Visible)

    -- [P3 优化] 背包鱼自动上锁与 ChildAdded 监听绑定不受「正在钓鱼 (isFishing)」阻塞，即使先开自动卖鱼也能提前秒锁名单内的鱼！
    if (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) and (lastProtectTime == 0 or (now - lastProtectTime >= 1.5)) and pData then
        lastProtectTime = now
        TryFavoriteProtectedFish(pData, false)
    end

    if not isMinigame and not isFishing then

        if Config.AutoSell and (now - lastSellTime >= Config.SellInterval) then
            SafeSellAllFish(pData)
            lastSellTime = now
        end

        if Config.AutoTicketQuest and (now - lastQuestTime >= 4.0) then
            lastQuestTime = now
            if RunTicketQuestAction then
                local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
                local didSend = RunTicketQuestAction(diffArg, false)
                if didSend then
                    lastQuestTime = now + 6.0
                end
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
        local npcFolder = GetWorkspaceFolder("NPC") or GetWorkspaceFolder("NPCs")
        if npcFolder then
            for _, ch in ipairs(npcFolder:GetChildren()) do
                local cn = ch.Name:lower()
                if cn == "spirit" or cn == "god" or cn:find("spirit", 1, true) then
                    TriggerNPCInstancePrompts(ch)
                end
            end
        end
    end

    if Config.AutoGacha and (now - lastGachaTime >= 1.5) then
        lastGachaTime = now
        if Events and Events:FindFirstChild("Gacha") then
            local bannerArg = GachaBannerMap[Config.GachaBanner] or "Taiji Banner"
            Events.Gacha:FireServer(bannerArg, Config.GachaPullsPerAction)
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
end

-- [0.50s 周期] 更新仪表盘实时统计卡片（挂机时长、Ping、坐标、现金/钓鱼速率、背包容量）及每 5s 检查一次自动最佳配装
local function stepDashboardAndEquip(now)
    local pData = GetPlayerData()
    local elapsed = now - dashStartTime

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
        local rawFish = pData:FindFirstChild("FishCaught") and pData.FishCaught.Value or 0
        local rawCash = pData:FindFirstChild("Cash") and pData.Cash.Value or 0
        if not dashInitDone then
            if DashUI._prevInitFish == nil then
                dashStartFish = rawFish
                dashStartCash = rawCash
                DashUI._prevInitFish = rawFish
                DashUI._prevInitCash = rawCash
            elseif DashUI._prevInitFish == rawFish and DashUI._prevInitCash == rawCash and (rawFish > 0 or rawCash > 0 or elapsed > 2.5) then
                dashStartFish = rawFish
                dashStartCash = rawCash
                dashInitDone = true
            else
                DashUI._prevInitFish = rawFish
                DashUI._prevInitCash = rawCash
            end
        end

        local currentFish = rawFish
        local currentCash = rawCash

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
            local fishSpeed = math.max(0, ((currentFish - dashStartFish) / elapsed) * 3600)
            DashUI.lblFishSpeed.Text = string.format("%.0f 条/h", fishSpeed)
            local cashSpeed = math.max(0, ((currentCash - dashStartCash) / elapsed) * 3600)
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
                local curRodName = pData.FishingRod.Value
                local curRodPower = rodPowerLookup[curRodName]
                -- 若当前已装备未知高阶/神话隐藏竿（不在常规商店字典内），保持当前装备不降级覆盖
                if curRodName == "" or curRodPower ~= nil then
                    local bestRod, bestPower = curRodName, (curRodPower or -1)
                    for _, rFolder in ipairs(pData.FishingRodInventory:GetChildren()) do
                        local isOwned = rFolder:FindFirstChild("Owned") and rFolder.Owned.Value == true
                        if isOwned then
                            local pwrObj = rFolder:FindFirstChild("Power")
                            local pwr = (pwrObj and tonumber(pwrObj.Value)) or rodPowerLookup[rFolder.Name] or -1
                            if pwr > bestPower then
                                bestPower = pwr
                                bestRod = rFolder.Name
                            end
                        end
                    end
                    if bestRod and bestRod ~= "" and pData.FishingRod.Value ~= bestRod then
                        task.spawn(function() pcall(function() Events.EquipFishingRod:InvokeServer(bestRod) end) end)
                    end
                end
            end
            if Config.AutoEquipBestOrb and pData:FindFirstChild("Orb") and Events and Events:FindFirstChild("EquipOrb") then
                local orbs = pData.Orb:GetChildren()
                if #orbs > 0 then
                    local targetOrb = orbs[#orbs].Name
                    local eqOrbObj = pData:FindFirstChild("EquippedOrb") or pData:FindFirstChild("CurrentOrb")
                    if not eqOrbObj or eqOrbObj.Value ~= targetOrb then
                        task.spawn(function() pcall(function() Events.EquipOrb:InvokeServer(targetOrb) end) end)
                    end
                end
            end
        end
    end
end

local radarWasFound = {}
local radarNotifiedTraits = {}
local lastCheckedTraitValue = setmetatable({}, { __mode = "k" })
local radarLastHopCheck = tick()
local radarWasDialogueOpen = false
local lastStreamPrefetchTime = 0
local streamPrefetchIdx = 0
local streamPrefetchPoints = {
    Vector3.new(1259.4, 9.1, 1401.5),   -- [8] 琥珀岛神灵祭坛
    Vector3.new(-1223.0, 7.3, -24.1),   -- [2] 竹岛神灵祭坛
    Vector3.new(-1366.0, 11.9, -1495.4),-- [6] 冰霜岛神灵祭坛
    Vector3.new(65.5, 8.8, 1181.3),     -- [3] 辐射岛
    Vector3.new(-1276.4, 8.8, 1239.7),  -- [4] 主权岛
    Vector3.new(-62.0, 11.9, -1321.4),  -- [5] 鲈鱼岛
    Vector3.new(1493.6, 9.1, -1430.6),  -- [7] 椰子岛
    Vector3.new(1393.5, 11.3, 169.6),   -- [9] 战场岛
    Vector3.new(2660.2, 8.8, -86.7),    -- [10] 雾峰岛
}

-- 启动时后台预加载三座神灵岛屿流式区域，解决玩家在起始岛时因远距流式未加载而检测不到琥珀/竹岛/冰霜神灵的问题
task.spawn(function()
    for idx = 1, 3 do
        if not isRunning then break end
        if TryStreamAroundPosition then
            pcall(TryStreamAroundPosition, streamPrefetchPoints[idx])
        end
        task.wait(0.35)
    end
end)

local inspectedRadarPass = setmetatable({}, { __mode = "k" })

-- [1.25s/2.5s 周期] 全图雷达扫描：检测三岛神灵、流动商人、四圣兽特质/Boss、挂载动态实体 ESP 并驱动自动跳服
local function stepWorldRadar(now)
    now = now or tick()
    local nowDialogueOpen = IsDialogueUIOpen(false)
    if radarWasDialogueOpen and not nowDialogueOpen and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(false)
    elseif not nowDialogueOpen and not isMicroTeleportingNPC and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(false)
    end
    radarWasDialogueOpen = nowDialogueOpen

    local char = LocalPlayer.Character
    local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
    local found = {}
    local foundOnlinePass = {}
    table.clear(inspectedRadarPass)

    -- 后台非阻塞轮询预加载远端神灵祭坛与各岛中心（每 5s 预加载 1 个远端岛屿，不移动角色）
    if not isMicroTeleportingNPC and not attrMinigame and (now - lastStreamPrefetchTime >= 5.0) then
        lastStreamPrefetchTime = now
        streamPrefetchIdx = (streamPrefetchIdx % #streamPrefetchPoints) + 1
        local pt = streamPrefetchPoints[streamPrefetchIdx]
        if pt and (not myPos or (myPos - pt).Magnitude > 450) and TryStreamAroundPosition then
            pcall(TryStreamAroundPosition, pt)
        end
    end

    -- 增强型多语言实体识别引擎（兼容 Model / BasePart / Folder 及 ProximityPrompt 直接溯源，彻底修复琥珀神灵与流动商人漏检）
    local function inspectEntity(npc, allowDeepSummary, promptHint)
        if not npc or npc == char or IsMapOrIslandContainer(npc) then return end
        local dedupKey = promptHint or npc
        if inspectedRadarPass[dedupKey] then return end
        if not (npc:IsA("Model") or npc:IsA("BasePart") or npc:IsA("Folder")) then return end
        inspectedRadarPass[dedupKey] = true
        if npc:IsA("Model") and Players:GetPlayerFromCharacter(npc) then return end
        if IsToolFishingRod and IsToolFishingRod(npc) then return end

        local name = npc.Name or ""
        local nLow = name:lower()
        local matchParts = { nLow }
        if npc.Parent and not IsMapOrIslandContainer(npc.Parent) then
            table.insert(matchParts, (npc.Parent.Name or ""):lower())
        end
        if promptHint and promptHint:IsA("ProximityPrompt") then
            if promptHint.Name and promptHint.Name ~= "ProximityPrompt" then table.insert(matchParts, promptHint.Name:lower()) end
            if promptHint.ObjectText and promptHint.ObjectText ~= "" then table.insert(matchParts, promptHint.ObjectText:lower()) end
            if promptHint.ActionText and promptHint.ActionText ~= "" then table.insert(matchParts, promptHint.ActionText:lower()) end
            if promptHint.Parent and promptHint.Parent ~= npc then table.insert(matchParts, (promptHint.Parent.Name or ""):lower()) end
        end
        if allowDeepSummary then
            local summary = GetInstanceSearchableSummary(npc)
            if summary and summary ~= "" then
                table.insert(matchParts, summary)
            end
        end
        local matchStr = table.concat(matchParts, " | ")
        if not HasRadarKeyword(matchStr) then return end
        local pos = (promptHint and promptHint.Parent and GetNPCPosition(promptHint.Parent)) or GetNPCPosition(npc)
        if not pos then return end

        -- 1) 优先识别流动商人（道士 / 茅山 / 傻子隐藏商人，独立分支防止其对话含 "Spirit" 被误归类为神灵）
        local isMerchant = false
        if matchStr:find("taoist", 1, true) or matchStr:find("xiao daoshi", 1, true) or matchStr:find("xiaodaoshi", 1, true)
            or matchStr:find("tieu dao si", 1, true) or matchStr:find("tieudaosi", 1, true) or matchStr:find("tiểu đạo sĩ", 1, true)
            or matchStr:find("đạo sĩ", 1, true) or matchStr:find("dao si", 1, true) or matchStr:find("little taoist", 1, true)
            or matchStr:find("道士", 1, true) or matchStr:find("小道士", 1, true) then
            isMerchant = true
            local dispName = (name ~= "" and name ~= "NPC" and name ~= "Model" and name ~= "Part") and name or "道士商人 (Taoist)"
            AddESP(npc, dispName, "Taoist", Colors.AccentOrange, "📜", pos)
            liveNPCs.Taoist.pos = pos
            liveNPCs.Taoist.inst = npc
            liveNPCs.Taoist.lastSeen = now
            found.Taoist = true
            if not radarWasFound.Taoist then
                ShowNotification("📜 道士商人降临", "道士商人 (Taoist Merchant) 已在服务器刷新！", "SUCCESS", 6)
            end
        elseif matchStr:find("maoshan", 1, true) or matchStr:find("mao shan", 1, true) or matchStr:find("mao son", 1, true)
            or matchStr:find("maoson", 1, true) or matchStr:find("mao sơn", 1, true) or matchStr:find("dai su huynh", 1, true)
            or matchStr:find("daisuhuynh", 1, true) or matchStr:find("đại sư huynh", 1, true)
            or matchStr:find("茅山", 1, true) or matchStr:find("大师兄", 1, true) then
            isMerchant = true
            local dispName = (name ~= "" and name ~= "NPC" and name ~= "Model" and name ~= "Part") and name or "茅山商人 (Maoshan)"
            AddESP(npc, dispName, "Maoshan", Colors.PurplePrimary, "✨", pos)
            liveNPCs.Maoshan.pos = pos
            liveNPCs.Maoshan.inst = npc
            liveNPCs.Maoshan.lastSeen = now
            found.Maoshan = true
            if not radarWasFound.Maoshan then
                ShowNotification("✨ 茅山商人降临", "茅山商人 (Maoshan Merchant) 已在服务器刷新！", "SUCCESS", 6)
            end
        elseif matchStr:find("dumb", 1, true) or matchStr:find("thang ngu", 1, true) or matchStr:find("thangngu", 1, true)
            or matchStr:find("thằng ngu", 1, true) or matchStr:find("thằng ngốc", 1, true) or matchStr:find("thang ngoc", 1, true)
            or matchStr:find("傻子", 1, true) or matchStr:find("笨蛋", 1, true) then
            isMerchant = true
            AddESP(npc, "傻子商人 (Dumb Guy)", "Taoist", Colors.AccentYellow, "🃏", pos)
            liveNPCs.DumbGuy.pos = pos
            liveNPCs.DumbGuy.inst = npc
            liveNPCs.DumbGuy.lastSeen = now
            found.DumbGuy = true
            if not radarWasFound.DumbGuy then
                ShowNotification("🃏 隐藏商人降临", "傻子隐藏商人 (Dumb Guy) 已在服务器刷新！", "SUCCESS", 6)
            end
        end

        -- 2) 四圣兽检测与弹窗报警（同时匹配模型名与缓存摘要中的英文/越文/中文名）
        local matchedAnyBeast = false
        for _, bSpec in ipairs(FourSacredBeastsSpecs) do
            local matchedBeast = false
            for _, alLow in ipairs(bSpec.lowerAliases) do
                if matchStr:find(alLow, 1, true) then
                    matchedBeast = true
                    break
                end
            end
            if matchedBeast then
                matchedAnyBeast = true
                local bKey = bSpec.liveKey
                AddESP(npc, bSpec.cnName, "Boss", bSpec.color, "🐉", pos)
                liveNPCs[bKey].pos = pos
                liveNPCs[bKey].inst = npc
                liveNPCs[bKey].lastSeen = now
                found[bKey] = true
                if not radarWasFound[bKey] then
                    ShowNotification("🔥 四圣兽现世", bSpec.cnName .. " 已在当前服务器出现！", "SUCCESS", 6)
                end
            end
        end

        -- 3) 三个神灵分岛精准识别（支持 Spirit/God/Shrine/Altar/Pray/50M 及中/英/越文全别名，按名称或距三座神灵祭坛最近距离归属）
        if not isMerchant and not matchedAnyBeast then
            local isSpiritEntity = (nLow == "spirit" or nLow == "god" or nLow == "spirits" or nLow == "godspirit" or nLow == "shrine" or nLow == "altar"
                or matchStr:find("spirit", 1, true) or matchStr:find("godspirit", 1, true) or matchStr:find("god ", 1, true) or matchStr:find(" god", 1, true)
                or matchStr:find("shrine", 1, true) or matchStr:find("altar", 1, true) or matchStr:find("pray", 1, true) or matchStr:find("blessing", 1, true)
                or matchStr:find("tinh linh", 1, true) or matchStr:find("than linh", 1, true) or matchStr:find("thần linh", 1, true)
                or matchStr:find("miếu", 1, true) or matchStr:find("bàn thờ", 1, true) or matchStr:find("cầu nguyện", 1, true) or matchStr:find("ban phước", 1, true)
                or matchStr:find("神灵", 1, true) or matchStr:find("神明", 1, true) or matchStr:find("祭坛", 1, true) or matchStr:find("神龛", 1, true)
                or matchStr:find("祈祷", 1, true) or matchStr:find("50,000,000", 1, true) or matchStr:find("50m", 1, true))
            if isSpiritEntity then
                local dBam = (pos - Vector3.new(-1223.0, 7.3, -24.1)).Magnitude
                local dFro = (pos - Vector3.new(-1366.0, 11.9, -1495.4)).Magnitude
                local dAmb = (pos - Vector3.new(1259.4, 9.1, 1401.5)).Magnitude
                local minSpiritDist = math.min(dBam, dFro, dAmb)
                -- 确保该神灵/祭坛位于三座神灵岛合理半径内（或名字明确为神灵/祭坛）
                if minSpiritDist < 650 or nLow == "spirit" or nLow == "god" or matchStr:find("spirit", 1, true) or matchStr:find("神灵", 1, true) or matchStr:find("shrine", 1, true) then
                    local spKey, spTitle
                    if matchStr:find("amber", 1, true) or matchStr:find("yellow", 1, true) or matchStr:find("ho phach", 1, true) or matchStr:find("hổ phách", 1, true) or matchStr:find("琥珀", 1, true) then
                        spKey = "Spirit_Amber"; spTitle = "琥珀岛神灵"
                    elseif matchStr:find("frost", 1, true) or matchStr:find("blue", 1, true) or matchStr:find("冰霜", 1, true) then
                        spKey = "Spirit_Frost"; spTitle = "冰霜岛神灵"
                    elseif matchStr:find("bamboo", 1, true) or matchStr:find("green", 1, true) or matchStr:find("竹", 1, true) then
                        spKey = "Spirit_Bamboo"; spTitle = "竹岛神灵"
                    elseif dBam <= dFro and dBam <= dAmb then
                        spKey = "Spirit_Bamboo"; spTitle = "竹岛神灵"
                    elseif dFro <= dBam and dFro <= dAmb then
                        spKey = "Spirit_Frost"; spTitle = "冰霜岛神灵"
                    else
                        spKey = "Spirit_Amber"; spTitle = "琥珀岛神灵"
                    end
                    AddESP(npc, spTitle, "GodSpirit", Colors.AccentGreen, "⛩️", pos)
                    liveNPCs[spKey].pos = pos
                    liveNPCs[spKey].inst = npc
                    liveNPCs[spKey].lastSeen = now
                    found[spKey] = true
                    found.AnySpirit = true
                    if not radarWasFound[spKey] then
                        ShowNotification("⛩️ 神灵降临", liveNPCs[spKey].name .. " 已在服务器刷新！", "SUCCESS", 6)
                    end
                end
            end
        end

        -- 4) 世界 Boss 实体识别与 ESP 挂载（恩佐 / 章鱼寄生体 / 龙钓海巨鲸等）
        if not matchedAnyBeast and (nLow:find("enzo", 1, true) or nLow:find("octo", 1, true) or nLow:find("parasite", 1, true) or nLow:find("dragon whale", 1, true) or nLow:find("boss", 1, true)) then
            AddESP(npc, name, "Boss", Colors.AccentRed, "👹", pos)
        end

        -- 5) 同步更新通用 NPC 雷达缓存 OnlineNPCs
        for _, spec in ipairs(ImportantDialogueNPCs) do
            if DoesInstanceMatchNPCSpec(npc, spec) then
                foundOnlinePass[spec.internalName] = true
                OnlineNPCs[spec.internalName] = { instance = npc, pos = pos, time = now }
            end
        end
    end

    -- 扫描全部 NPC、神灵祭坛与 Boss 专用容器（支持 3 层子结构遍历）
    for _, folderName in ipairs({"NPC", "NPCs", "Interactables", "DialogueNPCs", "QuestNPCs", "BossSetUp", "Shrines", "Spirits", "Merchants"}) do
        local folder = GetWorkspaceFolder(folderName)
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do
                if IsMapOrIslandContainer(ch) then
                    for _, sub in ipairs(ch:GetChildren()) do
                        pcall(inspectEntity, sub, true)
                    end
                else
                    pcall(inspectEntity, ch, true)
                    if ch:IsA("Folder") or ch:IsA("Model") then
                        for _, sub in ipairs(ch:GetChildren()) do
                            pcall(inspectEntity, sub, true)
                        end
                    end
                end
            end
        end
    end

    -- 扫描 Islands / Map 下各岛屿顶层子项（捕捉直接挂在岛屿目录下的常驻神灵祭坛如琥珀神灵及岛屿专属 NPC）
    for _, mapFolderName in ipairs({"Islands", "Map"}) do
        local mapFolder = GetWorkspaceFolder(mapFolderName)
        if mapFolder then
            for _, isl in ipairs(mapFolder:GetChildren()) do
                if isl:IsA("Folder") or isl:IsA("Model") then
                    for _, ch in ipairs(isl:GetChildren()) do
                        local cnLow = (ch.Name or ""):lower()
                        if IsMapOrIslandContainer(ch) or cnLow == "npcs" or cnLow == "npc" or cnLow == "shrine" or cnLow == "shrines" or cnLow == "interactables" then
                            for _, sub in ipairs(ch:GetChildren()) do
                                pcall(inspectEntity, sub, true)
                            end
                        elseif HasRadarKeyword(cnLow) then
                            pcall(inspectEntity, ch, true)
                        end
                    end
                end
            end
        end
    end

    -- 遍历事件驱动维护的 wsRootRadarModels 候选集
    for ch in pairs(wsRootRadarModels) do
        if ch and ch.Parent == Workspace then
            if not IsWorkspaceRootRadarCandidate(ch) then
                wsRootRadarModels[ch] = nil
            elseif ch ~= char then
                pcall(inspectEntity, ch, true)
            end
        else
            wsRootRadarModels[ch] = nil
        end
    end

    -- 复用全局事件维护的 GetCachedWorkspacePrompts() 反查所有挂载了 ProximityPrompt 的实体（通过 ResolvePromptEntity 精准定位，绝不漏检 BasePart/Folder 祭坛）
    local allPrompts = GetCachedWorkspacePrompts()
    for i = 1, #allPrompts do
        local pr = allPrompts[i]
        if pr and pr.Parent then
            local entity = ResolvePromptEntity(pr)
            if entity and entity ~= char then
                pcall(inspectEntity, entity, true, pr)
            end
        end
    end

    -- 流式卸载防抖保持：当玩家远离某座岛屿（> 600 米）导致客户端临时流式卸载该岛模型时，保留已确认刷新的神灵/商人状态，避免刚离开岛屿就误变成“未检测到”
    for _, key in ipairs(liveNPCOrder) do
        local data = liveNPCs[key]
        if data and not found[key] then
            if data.inst and data.inst.Parent then
                found[key] = true
                data.pos = GetNPCPosition(data.inst) or data.pos
                if key:find("^Spirit_") then found.AnySpirit = true end
            elseif data.pos and data.lastSeen and (now - data.lastSeen < 120.0) and myPos and (myPos - data.pos).Magnitude > 600 then
                found[key] = true
                if key:find("^Spirit_") then found.AnySpirit = true end
            end
        end
    end

    -- 清理已消失的通用 NPC 缓存
    for k, v in pairs(OnlineNPCs) do
        if not foundOnlinePass[k] and (now - (v.time or 0) > 6.0) then
            OnlineNPCs[k] = nil
        end
    end

    -- 检查玩家技能槽是否新洗出了四圣兽神话特质（独立 pcall 保护，不阻断雷达主状态更新）
    local pData = GetPlayerData()
    if pData and (now - (radarNotifiedTraits._lastScan or 0) >= 6.0) then
        pcall(function()
            if (radarNotifiedTraits._count or 0) > 256 then
                table.clear(radarNotifiedTraits)
            end
            radarNotifiedTraits._lastScan = now
            for _, topFolder in ipairs(pData:GetChildren()) do
                local fn = topFolder.Name
                if fn ~= "Inventory" and fn ~= "Hotbar" and fn ~= "FishingRodInventory" and fn ~= "Bait" and fn ~= "Index" then
                    local toCheck = topFolder:GetDescendants()
                    table.insert(toCheck, topFolder)
                    for i = 1, #toCheck do
                        local d = toCheck[i]
                        if d:IsA("ValueBase") then
                            local rawVal = d.Value
                            if type(rawVal) == "string" and rawVal ~= "" and lastCheckedTraitValue[d] ~= rawVal then
                                lastCheckedTraitValue[d] = rawVal
                                local vLow = rawVal:lower()
                                for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                                    for _, alLow in ipairs(bSpec.lowerAliases) do
                                        if vLow:find(alLow, 1, true) then
                                            local noticeKey = bSpec.liveKey .. "_" .. d:GetFullName()
                                            if not radarNotifiedTraits[noticeKey] then
                                                radarNotifiedTraits[noticeKey] = true
                                                radarNotifiedTraits._count = (radarNotifiedTraits._count or 0) + 1
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
        end)
    end

    -- 刷新传送页面的 10 个特殊 NPC 实时状态行
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
                data.lastSeen = nil
                data.ui_title.Text = data.icon .. " " .. data.name .. " (未检测到)"
                data.ui_title.TextColor3 = Colors.TextMuted
                data.ui_desc.Text = data.desc or "等待刷新..."
                data.ui_btn.BackgroundColor3 = Colors.ControlBg
                data.ui_btn.TextColor3 = data.fallbackPos and Colors.PurplePrimary or Colors.TextMuted
                data.ui_btn.Text = data.fallbackPos and "前往岛屿" or "传送"
            end
        end
    end
    radarWasFound = found

    if now - radarLastHopCheck >= 90.0 then
        radarLastHopCheck = now
        local inCombatNow = attrMinigame or wasInMinigame
        if not inCombatNow and (
           (Config.AutoServerHopGod and not found.AnySpirit) or
           (Config.AutoServerHopMaoshan and not found.Maoshan) or
           (Config.AutoServerHopTaoist and not found.Taoist)) then
            ServerHop(false)
        end
    end

    -- 统一调用动态 ESP 挂载器（含远端流式代理锚点支持）
    ScanAndMountDynamicESP()
end

DashUI._runRadarPassNow = function()
    stepWorldRadar(tick())
end

-- [5.0s 周期] 巡检并清理目标已离开或已销毁的残留 ESP 实例
local function stepESPCleanup()
    if next(activeESP) == nil then return end
    for inst, data in pairs(activeESP) do
        if not inst.Parent
            or not data.part or not data.part.Parent
            or not data.gui or not data.gui.Parent then
            pcall(RemoveESP, inst)
        end
    end
end

-- 启动统一后台调度器协程（取代原先 4 个独立轮询协程 + Heartbeat 低频分支）
task.spawn(function()
    local lastEspRefreshTick = 0
    local lastLowFreqTick = 0
    local lastDashTick = 0
    local lastRadarTick = 0
    local lastEspCleanTick = tick()
    local lastWSScanBackfill = tick()
    while isRunning do
        local powerSave = Config.Disable3DRendering
        task.wait(powerSave and 0.25 or 0.15)
        if not isRunning then break end
        local now = tick()

        -- 1) 0.15s ESP 距离与开关轻量刷新（省电模式下暂停）
        if not powerSave and (now - lastEspRefreshTick >= 0.15) then
            lastEspRefreshTick = now
            local anyESP = Config.ESP_GodSpirit or Config.ESP_SecretRod or Config.ESP_Boats
                or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_Boss or Config.ESP_Players
            if anyESP and next(activeESP) ~= nil then
                pcall(RefreshAllESPNow)
            end
        end

        -- 2) 0.25s 低频自动化业务（出售、保护上锁、祈祷、票据任务、扭蛋、猴子、每日签到、制作与购买鱼饵）
        if now - lastLowFreqTick >= 0.25 then
            lastLowFreqTick = now
            pcall(stepLowFreqAutomation, now)
        end

        -- 3) 0.50s 仪表盘与自动装备更新
        if now - lastDashTick >= 0.50 then
            lastDashTick = now
            pcall(stepDashboardAndEquip, now)
        end

        -- 4) 1.25s（省电模式 2.5s）全图雷达扫描 + 30s 一次的 Workspace 根子节点改名增量补扫
        local radarInterval = powerSave and 2.5 or 1.25
        if now - lastRadarTick >= radarInterval then
            lastRadarTick = now
            -- [性能优化 #12 & Bug修复 #3] 每 30 秒执行一次低频增量补扫，捕捉先以匿名 Model 插入 Workspace 后再被服务端改名为 Boss/神灵/商人的实例
            if now - lastWSScanBackfill >= 30.0 then
                lastWSScanBackfill = now
                pcall(function()
                    for _, ch in ipairs(Workspace:GetChildren()) do
                        if IsWorkspaceRootRadarCandidate(ch) then
                            wsRootRadarModels[ch] = true
                        end
                    end
                end)
            end
            pcall(stepWorldRadar, now)
        elseif now - lastEspCleanTick >= 5.0 then
            -- 5) 5.0s ESP 失效条目清理（与雷达错开不在同一 tick 执行，避免帧尖峰）
            lastEspCleanTick = now
            pcall(stepESPCleanup)
        end
    end
end)

-- ==========================================
-- ============================================================================
-- 【模块 28：高频帧循环（Heartbeat 战斗/抛竿/QTE & RenderStepped 飞行/拉杆辅助/鱼红圈）与全局快捷键】
-- 作用说明：
--   1. stepHeartbeat() 仅保留真正需要帧级响应的逻辑：移速/水上行走/坐标锁定、0.25s O(1) 咬钩检测、Boss 召唤、
--      小游戏猛击/蓄力/秒钓推进、Z/X/C/V 技能三通道释放、自动抛竿及节奏 QTE；
--   2. RenderStepped 处理丝滑飞行控制（仅在状态切换或速度变化时写属性）、拉杆条居中与鱼红圈跟随（未开启/未钓鱼时立即早退）；
--   3. 底部挂载无限跳、20分钟防挂机 (AntiAFK) 以及 RightControl 显隐菜单 / End 键安全卸载快捷键。
-- ============================================================================
-- [性能优化 #10,#11 & Bug修复 #2] 高频 Heartbeat 函数（预定义函数消除每帧匿名闭包分配）
-- ==========================================
local rhythmRemoteNames = {"RhythmHit", "Rhythm", "RhythmMinigame", "OctoMinigame", "OctoHit", "ParasiteMinigame", "QTE", "BossQTE", "BossMinigame", "MinigameHit"}

-- [Heartbeat 每帧循环] 处理移速、水上行走、位置锁定、0.25s 咬钩检测、Boss 召唤、小游戏猛击/蓄力/秒钓推进、技能轮换、自动抛竿及节奏 QTE
local function stepHeartbeat()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return end
    local now = tick()
    local pData, _, mainGui, fUI, bossBar = RefreshGuiAndDataRefs(now)

    -- [性能优化 #11] 仅在 WalkSpeed 不等于目标值时写入，避免每帧触发 C++ 属性变更信号
    if Config.WalkSpeedEnabled then
        RememberHumanoidState(hum)
        if hum.WalkSpeed ~= Config.WalkSpeedValue then
            hum.WalkSpeed = Config.WalkSpeedValue
        end
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

    -- [性能优化 #11] 咬钩扫描缓存命中时直接 O(1) 读取，无需每 0.25s 遍历 Fishes 全表
    if now - lastHookScanTime >= 0.25 then
        lastHookScanTime = now
        local fishesFolder = GetWorkspaceFolder("Fishes")
        if cachedHookedFish and cachedHookedFish.Parent == fishesFolder and cachedHookedFish:FindFirstChild(uidHealthKey) then
            cachedIsHooked = true
            local fishModel = cachedHookedFish:FindFirstChild("Model")
            local fishBuoy = cachedHookedFish:FindFirstChild("Buoy")
            if fishModel and fishModel:IsA("Model") then
                cachedHookedPos = fishModel:GetPivot().Position
            elseif fishBuoy and fishBuoy:IsA("BasePart") then
                cachedHookedPos = fishBuoy.Position
            end
        else
            cachedHookedFish = nil
            cachedIsHooked = false
            cachedHookedPos = nil
            if fishesFolder then
                for _, f in ipairs(fishesFolder:GetChildren()) do
                    if f:FindFirstChild(uidHealthKey) then
                        cachedHookedFish = f
                        cachedIsHooked = true
                        local fishModel = f:FindFirstChild("Model")
                        local fishBuoy = f:FindFirstChild("Buoy")
                        if fishModel and fishModel:IsA("Model") then
                            cachedHookedPos = fishModel:GetPivot().Position
                        elseif fishBuoy and fishBuoy:IsA("BasePart") then
                            cachedHookedPos = fishBuoy.Position
                        end
                        break
                    end
                end
            end
        end
    end

    local inUndergroundRealm = (root.Position.Y < -50)
    local isFishing = attrFishing
    local isCD = attrCD
    local isMinigame = attrMinigame
        or (fUI and fUI.Visible)
        or (bossBar and bossBar.Visible)
        or cachedIsHooked
    local isSwimming = attrSwimming
    local useMinigameAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoEnzoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss
    -- [Bug修复 #2] 将 isBossEncounter 提升到 if isMinigame 外层作用域，修复原代码 7014 行在 if 块外访问 nil 的作用域 Bug
    local isBossEncounter = (bossBar ~= nil and bossBar.Visible) or Config.AutoFarmBoss or Config.AutoFarmSecretBoss or Config.AutoEnzoMinigame

    -- 状态边沿检测：每次刚进入小游戏瞬间，强制重置技能索引为 1（保证 100% 从第 1 个勾选技能如 Z 起手）
    if isMinigame and not wasInMinigame then
        wasInMinigame = true
        currentSkillIndex = 1
        local interval = Config.SkillInterval or 1.5
        lastSkillTime = now - interval + 0.2
    elseif not isMinigame and wasInMinigame then
        wasInMinigame = false
        currentSkillIndex = 1
    end

    local bossCheckInterval = Config.AutoFarmBoss and 1.2 or 2.5
    if (Config.AutoFarmBoss or Config.AutoFarmSecretBoss) and not isMicroTeleportingNPC and not isMinigame and not isFishing and not cachedIsHooked and (now - lastBossTime >= bossCheckInterval) then
        lastBossTime = now
        if Config.AutoFarmSecretBoss then
            local bVal = pData and pData:FindFirstChild("Bait") and pData.Bait:FindFirstChild("Nameless Bait")
            if (not bVal or bVal.Value <= 0) and Events and Events:FindFirstChild("CraftBait") then
                if now - lastSecretBaitCraftTime >= 10.0 then
                    lastSecretBaitCraftTime = now
                    Events.CraftBait:FireServer("Nameless Bait", 1)
                end
            elseif bVal and bVal.Value > 0 and pData:FindFirstChild("EquippedBait") and pData.EquippedBait.Value ~= "Nameless Bait" and (now - lastEquipNamelessTime >= 5.0) then
                lastEquipNamelessTime = now
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
            local inEnzoCombat = isMinigame or (bossBar ~= nil and bossBar.Visible)
            local enzoPos = Vector3.new(-115.3, 9.2, 1349.5)
            if not inEnzoCombat and (root.Position - enzoPos).Magnitude > 15 then
                SafeTeleport(CFrame.new(enzoPos))
            end
            if not TrySelectAndStartEnzoModal(mainGui) then
                PruneAndTriggerBossPrompts()
                local bossSetup = GetWorkspaceFolder("BossSetUp")
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
            if (now - lastSlamChargeTime >= 0.08) then
                local didFire = false
                local perfBtn = (cachedPerfectBtn and cachedPerfectBtn.Parent == fUI) and cachedPerfectBtn or fUI:FindFirstChild("PerfectButton")
                if (Config.AutoSlam or useMinigameAssist) and perfBtn and perfBtn.Visible then
                    FireGuiButton(perfBtn)
                    local slamRem = GetEventRemote("Slam")
                    if slamRem then slamRem:FireServer("Perfect") end
                    didFire = true
                end
                local chgBtn = (cachedChargeBtn and cachedChargeBtn.Parent == fUI) and cachedChargeBtn or fUI:FindFirstChild("Charge")
                if (Config.AutoCharge or useMinigameAssist) and chgBtn and chgBtn.Visible then
                    if chgBtn:IsA("GuiButton") then FireGuiButton(chgBtn) end
                    local chgRem = GetEventRemote("Charge")
                    if chgRem then chgRem:FireServer(100) end
                    didFire = true
                end
                if didFire then lastSlamChargeTime = now end
            end
            local progInterval = Config.InstantCatch and 0.05 or 0.08
            if useMinigameAssist and (now - lastProgressionTime >= progInterval) then
                local progRem = GetEventRemote("UpdateFishProgression")
                if progRem then
                    progRem:FireServer()
                    if Config.InstantCatch then progRem:FireServer() end
                end
                local miniRem = GetEventRemote("FishingMinigame")
                if miniRem then
                    miniRem:FireServer("In bar")
                end
                lastProgressionTime = now
            end
        end

        local shouldFireSkills = Config.AutoSkills or (Config.BossAutoSkills and isBossEncounter)
        if shouldFireSkills and (now - lastSkillTime >= (Config.SkillInterval or 1.5)) then
            local enabledSkills = GetEnabledSkillsList()
            if #enabledSkills > 0 then
                if not currentSkillIndex or currentSkillIndex < 1 or currentSkillIndex > #enabledSkills then
                    currentSkillIndex = 1
                end
                local sk = enabledSkills[currentSkillIndex]

                -- 通道1：触发服务端技能 Remote
                pcall(function()
                    local rem = GetEventRemote("TriggerMinigameSkill")
                        or GetEventRemote("UseSkill")
                        or GetEventRemote("CastSkill")
                        or GetEventRemote("ActivateSkill")
                    if rem and rem:IsA("RemoteEvent") then
                        rem:FireServer(sk)
                    end
                end)

                -- 通道2：模拟按键 Z/X/C/V
                pcall(function()
                    if VirtualInputManager and Enum.KeyCode[sk] then
                        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode[sk], false, game)
                        task.delay(0.06, function()
                            if isRunning then
                                pcall(function()
                                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode[sk], false, game)
                                end)
                            end
                        end)
                    end
                end)

                -- 通道3：精准点击屏幕上的 Z/X/C/V 技能按钮
                pcall(function()
                    local btn = GetCachedSkillButton(sk, now)
                    if btn then FireGuiButton(btn) end
                end)

                currentSkillIndex = (currentSkillIndex % #enabledSkills) + 1
                lastSkillTime = now
            end
        end
    elseif isFishing then
        lastCastTime = now
    else
        -- 低频自动保护与定时卖鱼已移入 0.25s 后台调度器 stepLowFreqAutomation，Heartbeat 仅保留高频自动抛竿与按键恢复
        local holdingRodNow = IsCharacterHoldingFishingRod(char, pData)
        if cachedAutoFishBtn and cachedAutoFishBtn.Parent and not cachedAutoFishBtn.Visible then
            holdingRodNow = false
        end
        local shouldAutoCast = (Config.AutoCast or Config.AutoFarmSecretBoss) and not Config.AutoFarmBoss and not isMicroTeleportingNPC and holdingRodNow
        if shouldAutoCast then
            if sharedEnv then sharedEnv.IdenticalKeepFishBtnVisible = false end
        end
        if shouldAutoCast and not isCD and not isSwimming and (now - lastCastTime >= Config.CastDelay) then
            -- 无论本次是否因满包拦截，均同步更新 lastCastTime，彻底杜绝满包等待卖鱼期间每帧 (60~240FPS) 重复遍历背包 GetChildren() 造成掉帧卡顿！
            lastCastTime = now
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
                if Config.AutoSell and maxLim > 0 and invCount >= math.floor(maxLim * 0.9) and (now - lastFullBagSellTime >= 5.0) then
                    SafeSellAllFish(pData)
                    lastFullBagSellTime = now
                end
                if invCount >= maxLim then
                    canCast = false
                    if Config.AutoFarmSecretBoss and not Config.AutoSell and (now - lastFullBagWarnTime >= 30.0) then
                        lastFullBagWarnTime = now
                        ShowNotification("背包已满", "当前背包已满且未开启自动卖鱼，无法继续垂钓获取无名鱼饵材料！", "WARN", 5)
                    end
                end
            end
            if canCast then
                local castBtn = GetMobileFishingButton(now)
                local clickedCastUI = false
                if castBtn and castBtn.Visible and castBtn.Active then
                    clickedCastUI = FireGuiButton(castBtn)
                end
                local fishRem = GetEventRemote("Fishing")
                if not clickedCastUI and fishRem then
                    fishRem:FireServer(root.CFrame)
                end
            end
        elseif not Config.AutoCast and not Config.AutoFarmBoss and not Config.AutoFarmSecretBoss and (now - lastFishBtnRestoreTime >= 0.5) then
            lastFishBtnRestoreTime = now
            if holdingRodNow or (cachedAutoFishBtn and cachedAutoFishBtn.Parent and cachedAutoFishBtn.Visible) then
                RestoreMobileFishingButtonUI(false)
            elseif sharedEnv then
                sharedEnv.IdenticalKeepFishBtnVisible = false
            end
        end
    end

    if (Config.OctoAutoMinigame or Config.AutoEnzoMinigame) and (now - lastRhythmTime >= 0.10) then
        lastRhythmTime = now
        local acc = tonumber(Config.RhythmAccuracy) or 100
        local hitPass = (acc >= 100) or (math.random(1, 100) <= acc)
        if hitPass and Events then
            for i = 1, #rhythmRemoteNames do
                local rem = GetEventRemote(rhythmRemoteNames[i])
                if rem and rem:IsA("RemoteEvent") then
                    rem:FireServer(true, 100)
                    rem:FireServer("Perfect")
                end
            end
            if isMinigame then
                local progRem = GetEventRemote("UpdateFishProgression")
                if progRem then progRem:FireServer() end
                local miniRem = GetEventRemote("FishingMinigame")
                if miniRem then miniRem:FireServer("In bar") end
            end
        end
        if hitPass and ((bossBar and bossBar.Visible) or isBossEncounter) and (now - lastQTEHitTime >= 0.14) then
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
end

table.insert(activeConnections, RunService.Heartbeat:Connect(function()
    if not isRunning then return end
    pcall(stepHeartbeat)
end))

-- ==========================================
-- 纯净渲染循环 RenderStepped (极致低延迟 + 零每帧闭包分配)
-- ==========================================
local flyBV, flyBG = nil, nil
-- [性能优化 #11 / 建议 #12] 记录飞行激活状态与上帧速度，避免未开启飞行时每帧重复写 hum.PlatformStand，以及悬停零输入时重复写 Velocity
local flyWasActive = false
local lastFlyVel = nil
pcall(function()
    if type(RunService.BindToRenderStep) == "function" then
        pcall(function() RunService:UnbindFromRenderStep("IdenticalForceFishBtnVisible") end)
        local lastPrio = (Enum.RenderPriority and Enum.RenderPriority.Last and Enum.RenderPriority.Last.Value) or 2000
        RunService:BindToRenderStep("IdenticalForceFishBtnVisible", lastPrio, function()
            if not isRunning then return end
            if not Config.AutoCast and not Config.AutoFarmBoss and not Config.AutoFarmSecretBoss and not Config.HideGameUI then
                local autoShown = (cachedAutoFishBtn and cachedAutoFishBtn.Parent and cachedAutoFishBtn.Visible)
                if autoShown or (sharedEnv and sharedEnv.IdenticalKeepFishBtnVisible) then
                    if cachedMobileFishBtn and cachedMobileFishBtn.Parent then
                        if not cachedMobileFishBtn.Visible then cachedMobileFishBtn.Visible = true end
                        if not cachedMobileFishBtn.Active then cachedMobileFishBtn.Active = true end
                    end
                    if cachedMobileFishContainer and cachedMobileFishContainer.Parent and not cachedMobileFishContainer.Visible then
                        cachedMobileFishContainer.Visible = true
                    end
                end
            end
        end)
    end
end)

local UDIM2_CENTER = UDim2.new(0.5, 0, 0.5, 0)
local UDIM2_FULL = UDim2.new(1, 0, 1, 0)
-- [RenderStepped 渲染辅助] 小游戏期间实时居中钓鱼判定条、对齐 Boss 拔河绿区、拉满捕获进度条并隐藏受伤红屏遮罩（复用 0.6s 缓存子控件，零 FindFirstChild / 零 UDim2 分配）
local function stepRenderAssist(now)
    local _, _, _, fUI, bossBar = RefreshGuiAndDataRefs(now or tick())
    if fUI and fUI.Visible then
        if Config.AnchorBar then
            if cachedBarInner and cachedBarInner.Parent then
                cachedBarInner.Position = UDIM2_CENTER
            end
            if cachedProgBarInner and cachedProgBarInner.Parent then
                cachedProgBarInner.Size = UDIM2_FULL
            end
        end
        if (Config.AutoEnzoMinigame or Config.OctoAutoMinigame or Config.AnchorBar) and bossBar and bossBar.Visible then
            local bBar = cachedBossBarInner
            local bHit = cachedBossHitbox
            if bBar and bHit and bBar.Parent and bHit.Parent then
                bBar.Position = bHit.Position
                if bHit.Rotation and bBar.Rotation then
                    bBar.Rotation = bHit.Rotation
                end
            end
        end
        if cachedHurt1 and cachedHurt1.Parent and cachedHurt1.ImageTransparency ~= 1 then
            pcall(function() cachedHurt1.ImageTransparency = 1 end)
        end
        if cachedHurt2 and cachedHurt2.Parent and cachedHurt2.ImageTransparency ~= 1 then
            pcall(function() cachedHurt2.ImageTransparency = 1 end)
        end
    end
end

-- [RenderStepped 鱼红圈跟随] 追踪鱼线末端 Attachment1 或咬钩浮标的世界坐标，实时更新红色光圈位置
local function stepFishRedRing(char, now)
    now = now or tick()
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

    local fishPos = (cachedFishConstraint and cachedFishConstraint.Attachment1 and cachedFishConstraint.Attachment1.WorldPosition) or cachedHookedPos
    if fishPos then
        local needUpdate = (not lastFishRingPos)
            or (not fishRingAdornment.Visible)
            or ((fishPos - lastFishRingPos).Magnitude > 0.08)
        if needUpdate then
            fishRingAnchor.Position = fishPos
            lastFishRingPos = fishPos
            fishRingAdornment.Visible = true
        end
    elseif fishRingAdornment.Visible then
        fishRingAdornment.Visible = false
        lastFishRingPos = nil
    end
end

table.insert(activeConnections, RunService.RenderStepped:Connect(function()
    if not isRunning then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local hum = char:FindFirstChildOfClass("Humanoid")

    if Config.FlyEnabled then
        flyWasActive = true
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
            lastFlyVel = nil
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

        if hum then
            RememberHumanoidState(hum)
            if not hum.PlatformStand then hum.PlatformStand = true end
        end

        local cam = Workspace.CurrentCamera or Camera
        local camCF = cam and cam.CFrame or CFrame.new()
        local dir = Vector3.zero

        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir = dir + camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir = dir - camCF.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir = dir + camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir = dir - camCF.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
            dir = dir - Vector3.new(0, 1, 0)
        end

        -- [性能优化 #11] 消除原代码此处每帧计算却从未使用过的 flatLook / flatRight 向量死代码
        if hum and hum.MoveDirection.Magnitude > 0.08 then
            dir = dir + hum.MoveDirection
        end

        if UserInputService:IsKeyDown(Enum.KeyCode.ButtonA) then
            dir = dir + Vector3.new(0, 1, 0)
        end
        if os.clock() < flyAscendUntil then
            dir = dir + Vector3.new(0, 1, 0)
        end

        flyBG.CFrame = camCF
        local targetVel = (dir.Magnitude > 0.05) and (dir.Unit * (Config.FlySpeed or 50)) or Vector3.zero
        if lastFlyVel ~= targetVel then
            flyBV.Velocity = targetVel
            lastFlyVel = targetVel
        end
        if targetVel ~= Vector3.zero or root.AssemblyLinearVelocity.Magnitude > 0.05 then
            root.AssemblyLinearVelocity = targetVel
        end
    elseif flyWasActive then
        -- [性能优化 #11] 仅在从飞行开启切回关闭的那一帧清理并恢复 PlatformStand，常态不飞行时零属性写入开销
        flyWasActive = false
        lastFlyVel = nil
        flyAscendUntil = 0
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

    -- [性能优化 #11 / 建议 #10] 小游戏未进行时直接短路跳过 UI 辅助与 pcall，消除常态每帧 RefreshGuiAndDataRefs 开销
    local useAssist = Config.AnchorBar or Config.OctoAutoMinigame or Config.AutoEnzoMinigame or Config.AutoFarmSecretBoss or Config.AutoFarmBoss
    local activeMinigame = wasInMinigame or attrMinigame or cachedIsHooked
        or (cachedFUI ~= nil and cachedFUI.Parent ~= nil and cachedFUI.Visible)
        or (cachedBossBar ~= nil and cachedBossBar.Parent ~= nil and cachedBossBar.Visible)
    local isHooked = char and (attrFishing or attrMinigame or cachedIsHooked)
    local needRenderAssist = useAssist and activeMinigame
    local needFishRing = Config.FishRedRing and isHooked
    -- [性能优化 #13] 仅当小游戏辅助或鱼目标红圈至少有一项需要执行时才获取一次 tick() 并共享
    if needRenderAssist or needFishRing then
        local frameNow = tick()
        if needRenderAssist then
            pcall(stepRenderAssist, frameNow)
        end
        if needFishRing then
            pcall(stepFishRedRing, char, frameNow)
        elseif fishRingAdornment.Visible then
            fishRingAdornment.Visible = false
            lastFishRingPos = nil
        end
    elseif fishRingAdornment.Visible then
        fishRingAdornment.Visible = false
        lastFishRingPos = nil
    end
end))

-- 监听服务端发来的 Slam / Charge / Rhythm / Boss QTE 远程事件并自动回传 Perfect / 100 满分判定
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
end -- end of IdenticalStartRuntimeLoops
IdenticalStartRuntimeLoops()

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
