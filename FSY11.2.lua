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
-- [性能优化 #1 / 建议 #6,#20] 动态拖拽连接池：仅在拖拽进行中挂载 UIS 连接，松手立即断开，Unload 时兜底清理
local activeDragConns = {}
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
-- [UI 设计移植] 新版 UI 的轻量补间工具：同一实例复用 Tween、完成即回收，避免每行预创建常驻 Tween
local activeQuickTweens = setmetatable({}, { __mode = "k" })
local FAST_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function PlayQuickTween(inst, props, tweenInfo)
    if not inst or not isRunning then return nil end
    local prev = activeQuickTweens[inst]
    if prev then
        activeQuickTweens[inst] = nil
        pcall(function() prev:Cancel() end)
    end
    local ok, tw = pcall(function()
        return TweenService:Create(inst, tweenInfo or FAST_TWEEN_INFO, props)
    end)
    if ok and tw then
        activeQuickTweens[inst] = tw
        -- 下一个补间开始时统一 Cancel 上一次原生 Tween，避免频繁绑定 Completed 回调堆积
        pcall(function() tw:Play() end)
        return tw
    end
    return nil
end
local attrCharConn = nil -- 角色 AttributeChanged 连接；重生时替换，Unload 时单独断开
local cameraViewportConn = nil
local UpdateMainFrameScale, BindCameraViewportSignal
do
    -- [性能优化 #2 / 建议 #9] 合并同一帧内多次 ViewportSize / CurrentCamera 变化触发的缩放计算，避免拖拽窗口或旋转屏幕时连续重排抖动
    local scaleUpdateQueued = false
    -- 合并同一帧内的窗口缩放更新请求，避免频繁重排
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
-- 动态探测并获取当前玩家在 ReplicatedStorage 或 LocalPlayer 下的数据节点
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
    for _, localFolderName in ipairs({"Data", "PlayerData", "PlayersData"}) do
        local localData = LocalPlayer:FindFirstChild(localFolderName)
        if localData and (localData:FindFirstChild("Inventory") or localData:FindFirstChild("Cash")) then
            cachedPlayerDataNode = localData
            return localData
        end
    end
    if not warnedMissingDataRoot then
        warnedMissingDataRoot = true
        warn("[FSY] 尚未找到 ReplicatedStorage 下的玩家数据节点，等待角色数据加载...")
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
    warn("[FSY] 10 秒内未找到 ReplicatedStorage.Events；界面仍会加载，但依赖 Events 的功能暂不可用。")
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
    -- [主题配色] 内置 5 套非紫色清爽主题：薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红
    UITheme = "薄荷翠绿",
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
    AutoFavouriteFish = false,
    AutoProtectRareBossFish = false,
    FavouriteFishName = "Colossal Tigerfish",
    CustomProtectedFish = "Colossal Tigerfish",
    FavPacketMode = "鱼名+后缀(Name | Favorite)",
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
    SageSkill = "One-Strike Heaven Gate", -- [功能修复] 逸久贤者要学习的技能（随配置文件持久化）
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

        -- 安全读取实例名称，供 __namecall 钩子内部比对远程事件名
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
                                -- 【v21 核心修复】脚本内部发起的上锁调用（IdenticalInternalFavCall == true）必须直接放行：
                                -- 在 Delta 等移动端执行器中，pcall/task.spawn 协程内 checkcaller() 会返回 false 并进入 __namecall；
                                -- 旧版未在此处放行内部调用，导致脚本发出的 FavoriteItem 包被自己的 IsFavToggleBlocked 拦截丢弃（抓包 Outgoing 为 0），
                                -- 且把脚本试探包误学习为玩家手动发包。此处直接直通 orig，彻底解决抓包无 FavoriteItem 发包问题！
                                if sharedEnv and sharedEnv.IdenticalInternalFavCall then
                                    return orig(self, ...)
                                end
                                local args = {...}
                                if sharedEnv then
                                    sharedEnv.IdenticalLearnedFavRemote = self
                                    if typeof(args[1]) == "Instance" then
                                        sharedEnv.IdenticalLearnedFavFormat = "instance"
                                    elseif type(args[1]) == "string" and type(args[2]) == "string" then
                                        sharedEnv.IdenticalLearnedFavFormat = "action_name"
                                    elseif type(args[1]) == "string" then
                                        local sep, act = args[1]:match("(%s*|%s*)([^|]+)$")
                                        if act then act = act:match("^%s*(.-)%s*$") or "" end
                                        if sep and act ~= "" and (act:lower():find("fav", 1, true) or act:lower():find("lock", 1, true)) and not act:lower():find("un", 1, true) then
                                            sharedEnv.IdenticalLearnedFavSuffix = sep .. act
                                            sharedEnv.IdenticalLearnedFavFormat = "name_favorite"
                                        else
                                            sharedEnv.IdenticalLearnedFavFormat = "name"
                                        end
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
                warn("[FSY] hookmetamethod 未返回原始 __namecall，已启用安全保护分支。")
            end
        end)

        if not hookOk then
            warn("[FSY] Hook 安装失败，已跳过可选 Hook：" .. tostring(hookErr))
        end
    elseif not Capabilities.Hook then
        warn("[FSY] 当前执行器缺少完整 Hook API，已跳过 Hook；主界面仍会继续加载。")
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
local DashUI = {}
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

-- 校验并钳制单个配置项的类型、字符串长度与数值上下界
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
        -- [主题配色] 只接受内置非紫色清爽主题文案，旧配置中的紫色/旧色名自动回退为默认薄荷翠绿
        if key == "UITheme" then
            local validThemes = {
                ["薄荷翠绿"] = true, ["冰川天蓝"] = true, ["极光青碧"] = true, ["流光琥珀"] = true, ["珊瑚绯红"] = true,
            }
            if validThemes[value] then return value end
            return defaultValue
        end
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
    if DashUI and type(DashUI._refreshESPNow) == "function" then
        pcall(DashUI._refreshESPNow)
    end
    if Config.HideGameUI then pcall(SetGameUIHidden, true) end
    if Config.Disable3DRendering and blackOutFrame then
        blackOutFrame.Visible = true
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
    end
    -- [主题配色] 加载配置后同步界面主题色（轻量注册表更新，无全树扫描、无元表代理）
    if DashUI and type(DashUI._applyTheme) == "function" then
        pcall(DashUI._applyTheme, Config.UITheme, true)
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
                if Config.FavPacketMode == "完整鱼名(item.Name)" or Config.FavPacketMode == "实例对象(item)" or not Config.FavPacketMode or Config.FavPacketMode == "" then
                    Config.FavPacketMode = "鱼名+后缀(Name | Favorite)"
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
-- 【模块 08：现代深灰底色 + 纯白正文 + 轻量级非紫色主题切换器、ScreenGui 挂载与省电遮罩】
-- 作用说明：
--   1. 采用现代中性深灰蓝黑底色 (#171a21) + 纯白正文 (Color3.new(1,1,1)) + 浅灰描述文字 (#9aa3b2)，彻底告别全屏发绿或旧版紫色；
--   2. 内置 5 套非紫色高颜值主题点缀色（薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红），采用轻量级控件注册表更新，
--      100% 使用原生 TweenService（0 元表劫持、0 GetDescendants 全树盲扫、启动期 0 额外开销），PC 与 Delta 手机端均稳定流畅；
--   3. 优先使用 gethui / CoreGui 挂载 ScreenGui，使用安全正整数 DisplayOrder (100) 与标准 IgnoreGuiInset。
-- ============================================================================
local THEME_ACCENTS = {
    ["薄荷翠绿"] = {
        BorderPurple     = Color3.fromRGB(52, 211, 153),   -- #34d399 柔和薄荷绿主色
        PurplePrimary    = Color3.fromRGB(110, 231, 183),  -- #6ee7b7 清亮薄荷绿
        PurpleAccent     = Color3.fromRGB(52, 211, 153),   -- #34d399 核心按钮/高亮薄荷绿
        PurpleMuted      = Color3.fromRGB(178, 188, 204),  -- #b2bcc8 高对比度次要浅灰
        PurpleDark       = Color3.fromRGB(16, 98, 72),     -- 选中胶囊/导航深薄荷底
        PurpleGlow       = Color3.fromRGB(167, 243, 208),  -- 外环柔光色
        DropdownSelected = Color3.fromRGB(20, 83, 61),
    },
    ["冰川天蓝"] = {
        BorderPurple     = Color3.fromRGB(56, 189, 248),   -- #38bdf8 冰川天蓝主色
        PurplePrimary    = Color3.fromRGB(125, 211, 252),  -- #7dd3fc 清亮天蓝
        PurpleAccent     = Color3.fromRGB(56, 189, 248),   -- #38bdf8 核心按钮/高亮天蓝
        PurpleMuted      = Color3.fromRGB(178, 188, 204),
        PurpleDark       = Color3.fromRGB(14, 78, 116),
        PurpleGlow       = Color3.fromRGB(186, 230, 253),
        DropdownSelected = Color3.fromRGB(17, 64, 96),
    },
    ["极光青碧"] = {
        BorderPurple     = Color3.fromRGB(45, 212, 191),   -- #2dd4bf 极光青碧主色
        PurplePrimary    = Color3.fromRGB(94, 234, 212),   -- #5eead4 清亮青碧
        PurpleAccent     = Color3.fromRGB(45, 212, 191),   -- #2dd4bf 核心按钮/高亮青碧
        PurpleMuted      = Color3.fromRGB(178, 188, 204),
        PurpleDark       = Color3.fromRGB(17, 94, 89),
        PurpleGlow       = Color3.fromRGB(153, 246, 228),
        DropdownSelected = Color3.fromRGB(19, 78, 74),
    },
    ["流光琥珀"] = {
        BorderPurple     = Color3.fromRGB(245, 158, 11),   -- #f59e0b 流光琥珀主色
        PurplePrimary    = Color3.fromRGB(251, 191, 36),   -- #fbbf24 清亮琥珀金
        PurpleAccent     = Color3.fromRGB(245, 158, 11),   -- #f59e0b 核心按钮/高亮琥珀
        PurpleMuted      = Color3.fromRGB(182, 188, 202),
        PurpleDark       = Color3.fromRGB(120, 53, 15),
        PurpleGlow       = Color3.fromRGB(253, 230, 138),
        DropdownSelected = Color3.fromRGB(92, 42, 12),
    },
    ["珊瑚绯红"] = {
        BorderPurple     = Color3.fromRGB(251, 113, 133),  -- #fb7185 珊瑚绯红主色
        PurplePrimary    = Color3.fromRGB(253, 164, 175),  -- #fda4af 清亮珊瑚红
        PurpleAccent     = Color3.fromRGB(251, 113, 133),  -- #fb7185 核心按钮/高亮珊瑚红
        PurpleMuted      = Color3.fromRGB(182, 188, 202),
        PurpleDark       = Color3.fromRGB(136, 19, 55),
        PurpleGlow       = Color3.fromRGB(254, 205, 211),
        DropdownSelected = Color3.fromRGB(105, 16, 43),
    },
}
local THEME_OPTIONS = {"薄荷翠绿", "冰川天蓝", "极光青碧", "流光琥珀", "珊瑚绯红"}

-- 基础中性深灰蓝黑底色 + 纯白主文字 + 浅灰次要文字（严格遵循图3高对比度设计规范）
local Colors = {
    Background       = Color3.fromRGB(23, 26, 33),    -- #171a21 主窗口深灰蓝底
    SidebarBg        = Color3.fromRGB(19, 22, 28),    -- #13161c 侧边栏与标题栏底
    BorderPurple     = Color3.fromRGB(52, 211, 153),  -- #34d399 主外框线（随主题切换）
    BorderSubtle     = Color3.fromRGB(46, 53, 66),    -- #2e3542 卡片细边框
    Divider          = Color3.fromRGB(38, 44, 56),    -- #262c38 分割线
    PurplePrimary    = Color3.fromRGB(110, 231, 183), -- #6ee7b7 主题亮色（随主题切换）
    PurpleAccent     = Color3.fromRGB(52, 211, 153),  -- #34d399 主题主色（随主题切换）
    PurpleMuted      = Color3.fromRGB(178, 188, 204), -- #b2bcc8 高对比度次要灰字（手机强光下清晰可读）
    PurpleDark       = Color3.fromRGB(16, 98, 72),    -- 主题深色激活底（随主题切换）
    PurpleGlow       = Color3.fromRGB(167, 243, 208), -- 主题浅光色（随主题切换）
    RowNormal        = Color3.fromRGB(30, 34, 43),    -- #1e222b 功能行常态深灰底
    RowHover         = Color3.fromRGB(38, 43, 54),    -- #262b36 功能行悬停浅灰底
    ControlBg        = Color3.fromRGB(48, 55, 70),    -- #303746 按钮/滑块槽底色（增强与行底色的层次区分）
    InputBg          = Color3.fromRGB(16, 19, 24),    -- #101318 输入框/下拉项底色
    TextWhite        = Color3.new(1, 1, 1),           -- #ffffff 纯白主文字
    TextSubtle       = Color3.fromRGB(224, 230, 240), -- #e0e6f0 高亮白灰文字
    TextMuted        = Color3.fromRGB(178, 188, 204), -- #b2bcc8 次要描述浅灰文字（提升对比度至 >6.5:1）
    AccentGreen      = Color3.fromRGB(52, 211, 153),  -- #34d399 成功/运行薄荷绿
    AccentRed        = Color3.fromRGB(248, 113, 113), -- #f87171 警告/关闭红
    AccentOrange     = Color3.fromRGB(251, 146, 60),  -- #fb923c 橙色指标
    AccentYellow     = Color3.fromRGB(250, 204, 21),  -- #facc15 黄色指标
    AccentBlue       = Color3.fromRGB(56, 189, 248),  -- #38bdf8 蓝色指标
    DropdownSelected = Color3.fromRGB(20, 83, 61),    -- 下拉选中项深底（随主题切换）
}

local currentThemeName = (THEME_ACCENTS[Config.UITheme] and Config.UITheme) or "薄荷翠绿"
for k, v in pairs(THEME_ACCENTS[currentThemeName]) do
    Colors[k] = v
end

-- 轻量级主题色刷新注册表：仅记录依赖主题点缀色的控件回调，切换颜色时 O(N) 直接赋值，不做全树 GetDescendants 扫描
local themeUpdaters = {}
local function RegisterThemeUpdater(fn)
    if type(fn) == "function" then
        themeUpdaters[#themeUpdaters + 1] = fn
    end
end

local function ApplyTheme(themeName, silent)
    local targetName = (type(themeName) == "string" and THEME_ACCENTS[themeName]) and themeName or "薄荷翠绿"
    if silent and targetName == currentThemeName then
        Config.UITheme = targetName
        return true
    end
    currentThemeName = targetName
    Config.UITheme = targetName
    local accentPalette = THEME_ACCENTS[targetName]
    for k, v in pairs(accentPalette) do
        Colors[k] = v
    end
    for i = 1, #themeUpdaters do
        pcall(themeUpdaters[i])
    end
    if not silent and type(SaveProfile) == "function" then
        pcall(SaveProfile, Config.ActiveProfile)
    end
    return true
end

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
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- 使用安全正整数 DisplayOrder (100) 置顶于普通游戏 HUD 之上，避免 2147483647 (INT32_MAX) 在部分移动端执行器中引发排序溢出
screenGui.DisplayOrder = 100
local setParentOk = pcall(function() screenGui.Parent = getGuiParent() end)
if not setParentOk or not screenGui.Parent then
    pcall(function() screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) end)
end
table.insert(cleanUpInstances, screenGui)

-- ============================================================================
-- 【UI 交互修复 2/4：统一点击绑定器 BindClick】
-- 旧代码对部分控件只连 Activated，对另一些只连 MouseButton1Click；在触屏合成的
-- 鼠标事件、旧客户端或部分执行器里，两条事件来源并不总是同时可靠。
-- 这里同一控件同时连接两条路径，用 220ms 去抖保证只执行一次；并把回调登记到
-- clickRegistry，供“触屏点击兜底”使用。
-- ============================================================================
local clickRegistry = setmetatable({}, { __mode = "k" })
local lastClickAt = setmetatable({}, { __mode = "k" })
local CLICK_DEBOUNCE = 0.22
local function BindClick(button, callback)
    if not button or type(callback) ~= "function" then return nil end
    local function fire()
        local now = tick()
        if now - (lastClickAt[button] or 0) < CLICK_DEBOUNCE then return end
        lastClickAt[button] = now
        callback()
    end
    clickRegistry[button] = fire
    -- Activated 覆盖触屏/鼠标/手柄；MouseButton1Click 作为旧客户端与部分执行器的兜底
    if button.Activated then
        button.Activated:Connect(fire)
    end
    button.MouseButton1Click:Connect(fire)
    return fire
end

blackOutFrame = Instance.new("Frame")
blackOutFrame.Name = "PowerSaveOverlay"
blackOutFrame.Size = UDim2.new(1, 0, 1, 0)
blackOutFrame.BackgroundColor3 = Color3.fromRGB(5, 5, 8)
blackOutFrame.BorderSizePixel = 0
blackOutFrame.Visible = false
blackOutFrame.ZIndex = 0
-- [UI 交互修复 3/4] 省电黑屏遮罩只负责显示，绝不参与输入拦截
blackOutFrame.Active = false
blackOutFrame.Parent = screenGui
do
    local blackOutLabel = Instance.new("TextLabel")
    blackOutLabel.Size = UDim2.new(1, 0, 0, 40)
    blackOutLabel.Position = UDim2.new(0, 0, 0.1, 0)
    blackOutLabel.BackgroundTransparency = 1
    blackOutLabel.Font = Enum.Font.GothamBold
    blackOutLabel.Text = "⚡ FSY V1.8 极致省电挂机模式运行中 (已关闭 3D 渲染)"
    blackOutLabel.TextColor3 = Colors.PurplePrimary
    blackOutLabel.TextSize = 16
    blackOutLabel.Parent = blackOutFrame
    RegisterThemeUpdater(function() blackOutLabel.TextColor3 = Colors.PurplePrimary end)
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
local watchedBagFolders = setmetatable({}, { __mode = "k" })  -- 已挂载 ChildAdded 自动收藏监听的背包容器集合
local isSellingInProgress = false                             -- 卖鱼协程互斥锁，防止并发重入
local isClaimingDailyTask = false
local isClaimingDailySign = false
local activePromptTasks = setmetatable({}, { __mode = "k" })
local OnlineNPCs = {}
local isMicroTeleportingNPC = false
-- [稳定性修复] 微瞬移锁的获取时间：协程若被异常中断（切场景 / 角色重生 / 报错）锁会永久为 true，
-- 会同时冻结自动抛竿与 Boss 挂机；这里记录时间戳，由低频调度器做 12s 超时自愈
local microTeleportLockAt = 0
local DismissStuckPromptsAndRestore
local liveNPCOrder = {
    "Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber",
    "Taoist", "Maoshan", "DumbGuy",
    "VermilionBird", "BlackTortoise", "WhiteTiger", "AzureDragon"
}

-- [冗余清理] 全图 NPC / 容器扫描目录名单的唯一真源：原来模块 17「按配置查找 NPC」与模块 27「全图雷达」各写一份
-- 完全相同的 9 项数组，改目录名时漏改一处就会静默漏扫；这里放在文件作用域，供两个模块共用。
local NPC_SCAN_CONTAINER_NAMES = {"NPC", "NPCs", "Interactables", "DialogueNPCs", "QuestNPCs", "BossSetUp", "Shrines", "Spirits", "Merchants"}
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
-- 幂等安全卸载函数：断开所有连接、销毁 UI/ESP 实例并还原画质与角色碰撞
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
    -- [性能优化 #1 清理兜底] 取消所有进行中的补间动画并断开临时拖拽连接
    for _, tw in pairs(activeQuickTweens) do pcall(function() tw:Cancel() end) end
    table.clear(activeQuickTweens)
    table.clear(themeUpdaters)
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
    pcall(function()
        for _, fn in ipairs({"IdenticalESP", "IdenticalESPAnchors", "IdenticalESPHighlights", "FishRingAnchor", "IdenticalWaterPlatform"}) do
            local leftover = Workspace:FindFirstChild(fn)
            if leftover then leftover:Destroy() end
        end
    end)
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
    table.clear(watchedBagFolders)
    table.clear(activePromptTasks)
    if DismissStuckPromptsAndRestore then pcall(DismissStuckPromptsAndRestore, false) end
    table.clear(OnlineNPCs)
    isMicroTeleportingNPC = false
    isSellingInProgress = false
    isClaimingDailyTask = false
    isClaimingDailySign = false
    if sharedEnv then
        sharedEnv.IdenticalIsSellArgBlocked = nil
        sharedEnv.IdenticalIsFavToggleBlocked = nil
        sharedEnv.IdenticalInternalFavCall = nil
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
-- [UI 交互修复 3/4] 通知容器显式声明为非交互层：它覆盖右侧整条屏幕高度，
-- 旧版只靠 Frame 默认行为，遇到异常客户端/旧输入实现时可能吞掉下层按钮点击。
local notifContainer = Instance.new("Frame"); notifContainer.Name = "Notifications"; notifContainer.Size = UDim2.new(0, 300, 1, -40); notifContainer.Position = UDim2.new(1, -315, 0, 20); notifContainer.BackgroundTransparency = 1; notifContainer.ZIndex = 3500; notifContainer.Active = false; notifContainer.Parent = screenGui
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

    local card = Instance.new("Frame"); card.Size = UDim2.new(1, 0, 1, 0); card.Position = UDim2.new(1, 30, 0, 0); card.BackgroundColor3 = Colors.RowNormal; card.BackgroundTransparency = 0.04; card.BorderSizePixel = 0; card.ClipsDescendants = true; card.Active = true; card.Parent = slot
    local stroke = Instance.new("UIStroke"); stroke.Color = accentColor; stroke.Thickness = 1.2; stroke.Transparency = 0.15; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = card
    local sideBar = Instance.new("Frame"); sideBar.Size = UDim2.new(0, 3, 1, -14); sideBar.Position = UDim2.new(0, 5, 0, 7); sideBar.BackgroundColor3 = accentColor; sideBar.BorderSizePixel = 0; sideBar.Parent = card
    Instance.new("UICorner", sideBar).CornerRadius = UDim.new(1, 0)
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 20); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 14, 0, 6); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -24, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = title; tLabel.TextColor3 = Colors.TextWhite; tLabel.TextSize = 13; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.TextTruncate = Enum.TextTruncate.AtEnd; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -24, 0, 28); mLabel.Position = UDim2.new(0, 14, 0, 26); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = text; mLabel.TextColor3 = Colors.TextSubtle; mLabel.TextSize = 11; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.TextTruncate = Enum.TextTruncate.AtEnd; mLabel.Parent = card

    TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = UDim2.new(0, 0, 0, 0)}):Play()

    local dismissed = false
    -- 播放滑出动画并销毁当前通知卡片
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
-- ============================================================================
-- 【模块 11：FSY 可拖拽悬浮球 (FloatingBall) 与主窗口自适应缩放容器 (MainFrame)】
-- 作用说明：
--   1. 注入后创建名为 FSY 的圆形悬浮球：按住可拖动（自动钳制在屏幕内），松手位移很小时视为点击，
--      点击唤起 / 收起主功能面板；拖拽期间才挂载 UIS 连接，平时零回调开销；
--   2. 主面板打开时自动休眠悬浮球的呼吸光晕协程，避免后台空转；
--   3. 构建 700x480 主窗口容器与自适应 UIScale，确保手机小屏与 PC 大屏下均完整显示不越界。
-- 后续修改指引：
--   - 悬浮球直径：改 FLOATING_BALL_SIZE；初始位置：改 floatingBall.Position；
--   - 悬浮球文字 / 字号：改 fbLabel.Text 与 fbLabel.TextSize。
-- ============================================================================
local ToggleUiVisibility, mainFrame

-- [UI 重构 #1] 悬浮球由“小月亮图标”改为用户指定的 FSY 圆形球（深色球体 + 紫色描边 + 居中 FSY + 运行状态点）
-- 静态 FSY 悬浮球（不搞小黑球、无后台呼吸闪烁协程，柔和深灰底 + 主题色边框 + 纯白 FSY 字样）
local FLOATING_BALL_SIZE = 48
local floatingBall = Instance.new("TextButton")
floatingBall.Name = "FSY"
floatingBall.Size = UDim2.new(0, FLOATING_BALL_SIZE, 0, FLOATING_BALL_SIZE)
floatingBall.Position = UDim2.new(0, 18, 0, 300)
floatingBall.BackgroundColor3 = Colors.RowHover
floatingBall.BackgroundTransparency = 0
floatingBall.BorderSizePixel = 0
floatingBall.Text = ""
floatingBall.AutoButtonColor = false
floatingBall.Visible = false
floatingBall.ZIndex = 2500
floatingBall.Parent = screenGui
table.insert(cleanUpInstances, floatingBall)

do -- Static Floating FSY Ball Scope
    local fbCorner = Instance.new("UICorner"); fbCorner.CornerRadius = UDim.new(1, 0); fbCorner.Parent = floatingBall
    local fbStroke = Instance.new("UIStroke"); fbStroke.Color = Colors.PurpleAccent; fbStroke.Thickness = 2; fbStroke.Transparency = 0.1; fbStroke.Parent = floatingBall

    local fbLabel = Instance.new("TextLabel")
    fbLabel.Name = "Title"
    fbLabel.Size = UDim2.new(1, 0, 1, 0)
    fbLabel.BackgroundTransparency = 1
    fbLabel.Font = Enum.Font.GothamBold
    fbLabel.Text = "FSY"
    fbLabel.TextColor3 = Colors.TextWhite
    fbLabel.TextSize = 14
    fbLabel.TextXAlignment = Enum.TextXAlignment.Center
    fbLabel.TextYAlignment = Enum.TextYAlignment.Center
    fbLabel.Parent = floatingBall

    local fbStatusDot = Instance.new("Frame")
    fbStatusDot.Name = "StatusDot"
    fbStatusDot.Size = UDim2.new(0, 9, 0, 9)
    fbStatusDot.Position = UDim2.new(1, -10, 1, -10)
    fbStatusDot.BackgroundColor3 = Colors.PurpleAccent
    fbStatusDot.BorderSizePixel = 0
    fbStatusDot.ZIndex = 2501
    fbStatusDot.Parent = floatingBall
    Instance.new("UICorner", fbStatusDot).CornerRadius = UDim.new(1, 0)
    local fbDotStroke = Instance.new("UIStroke", fbStatusDot); fbDotStroke.Color = Colors.RowHover; fbDotStroke.Thickness = 1.5

    RegisterThemeUpdater(function()
        fbStroke.Color = Colors.PurpleAccent
        fbStatusDot.BackgroundColor3 = Colors.PurpleAccent
    end)

    local fbDragging = false
    local fbActiveTouch = nil
    local fbDragStart = nil
    local fbStartAbs = nil
    local fbMovedDistance = 0
    local fbInputEndConn = nil
    local fbDragChangedConn = nil
    local fbDragEndedConn = nil

    local function getScreenBoundsSize()
        if screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize.Y > 0 then
            return screenGui.AbsoluteSize
        end
        local cam = Workspace.CurrentCamera or Camera
        return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    end

    local function updateBallPosition(inputPos)
        if not fbDragging or not fbDragStart or not fbStartAbs then return end
        local delta = inputPos - fbDragStart
        fbMovedDistance = math.max(fbMovedDistance, delta.Magnitude)
        local vp = getScreenBoundsSize()
        local guiOrigin = (screenGui and screenGui.Parent and screenGui.AbsolutePosition) or Vector2.zero
        local btnW = floatingBall.AbsoluteSize.X > 0 and floatingBall.AbsoluteSize.X or FLOATING_BALL_SIZE
        local btnH = floatingBall.AbsoluteSize.Y > 0 and floatingBall.AbsoluteSize.Y or FLOATING_BALL_SIZE
        local localX = (fbStartAbs.X - guiOrigin.X) + delta.X
        local localY = (fbStartAbs.Y - guiOrigin.Y) + delta.Y
        local clampedX = math.clamp(localX, 0, math.max(0, vp.X - btnW))
        local clampedY = math.clamp(localY, 0, math.max(0, vp.Y - btnH))
        floatingBall.Position = UDim2.fromOffset(clampedX, clampedY)
    end

    local function stopBallDrag()
        fbDragging = false
        fbActiveTouch = nil
        fbInputEndConn = DisconnectTempDragConn(fbInputEndConn)
        fbDragChangedConn = DisconnectTempDragConn(fbDragChangedConn)
        fbDragEndedConn = DisconnectTempDragConn(fbDragEndedConn)
    end

    floatingBall.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            stopBallDrag()
            fbDragging = true
            fbActiveTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
            fbMovedDistance = 0
            fbDragStart = input.Position
            local vp = getScreenBoundsSize()
            local curPos = floatingBall.Position
            if floatingBall.AbsolutePosition.X ~= 0 or floatingBall.AbsolutePosition.Y ~= 0 then
                fbStartAbs = floatingBall.AbsolutePosition
            else
                fbStartAbs = Vector2.new(curPos.X.Scale * vp.X + curPos.X.Offset, curPos.Y.Scale * vp.Y + curPos.Y.Offset)
            end
            fbInputEndConn = RegisterTempDragConn(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                    stopBallDrag()
                elseif fbDragging and (input == fbActiveTouch or input.UserInputType == Enum.UserInputType.Touch) then
                    updateBallPosition(input.Position)
                end
            end))
            fbDragChangedConn = RegisterTempDragConn(UserInputService.InputChanged:Connect(function(changedInput)
                if not fbDragging then return end
                if fbActiveTouch then
                    if changedInput == fbActiveTouch or changedInput.UserInputType == Enum.UserInputType.Touch then
                        updateBallPosition(changedInput.Position)
                    end
                elseif changedInput.UserInputType == Enum.UserInputType.MouseMovement then
                    updateBallPosition(changedInput.Position)
                end
            end))
            fbDragEndedConn = RegisterTempDragConn(UserInputService.InputEnded:Connect(function(endedInput)
                if not fbDragging then return end
                if (fbActiveTouch and endedInput == fbActiveTouch) or (not fbActiveTouch and endedInput.UserInputType == Enum.UserInputType.MouseButton1) then
                    stopBallDrag()
                end
            end))
        end
    end)

    floatingBall.MouseEnter:Connect(function()
        PlayQuickTween(floatingBall, {BackgroundColor3 = Colors.ControlBg})
        PlayQuickTween(fbStroke, {Color = Colors.PurplePrimary, Transparency = 0})
    end)

    floatingBall.MouseLeave:Connect(function()
        PlayQuickTween(floatingBall, {BackgroundColor3 = Colors.RowHover})
        PlayQuickTween(fbStroke, {Color = Colors.PurpleAccent, Transparency = 0.1})
    end)

    local lastToggleClick = 0
    local function handleToggleTrigger()
        if fbMovedDistance > 8 then return end
        local now = tick()
        if now - lastToggleClick < 0.25 then return end
        lastToggleClick = now
        if ToggleUiVisibility then ToggleUiVisibility() end
    end

    BindClick(floatingBall, handleToggleTrigger)
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
-- [UI 交互修复 3/4] 主窗口显式置顶并主动接收输入：
-- 1) ZIndex 高于通知容器/悬浮球，避免透明层盖在面板之上；
-- 2) Active=true 让面板空白区域也吃掉点击，不再穿透到游戏/HUD。
mainFrame.ZIndex = 3000
mainFrame.Active = true
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
    -- 根据当前屏幕视口尺寸与 Config.UIScale 自适应计算并应用主窗口缩放比例
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

do
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 8); mc.Parent = mainFrame
    local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderPurple; ms.Thickness = 1.5; ms.Parent = mainFrame
    RegisterThemeUpdater(function() ms.Color = Colors.BorderPurple end)
end

-- [折叠面板] 折叠分组与抽屉胶囊注册表
local collapsibleSections = {}
local drawerCapsules = {}
local navList, tabCanvasRefreshers, currentActiveTab, SwitchTab, CreateTab, CloseUI
-- ============================================================================
-- 【模块 12：主窗口框架构建（FSY V1.8 静态标题栏、移动端防弹回滚动与标签页路由）】
-- 作用说明：
--   1. 构建顶部标题栏（静态 FSY 徽标与 FSY V1.8 版本号，无月亮图标；右侧含清爽静态 [-] 与 [X] 按钮）、左侧导航栏与底部状态栏；
--   2. BindVerticalCanvas() 通过真实可见子项高度累加计算 CanvasSize，解决手机端 AutomaticSize 滑不到底或回弹问题；
--   3. CreateTab() 与 SwitchTab() 负责标签页切换与按需刷新当前可见页滚动高度。
-- ============================================================================
do -- Window Frame Construction Scope
local titleBar = Instance.new("Frame"); titleBar.Name = "TitleBar"; titleBar.Size = UDim2.new(1, 0, 0, 38); titleBar.BackgroundColor3 = Colors.SidebarBg; titleBar.BorderSizePixel = 0; titleBar.Parent = mainFrame
do
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 8); tc.Parent = titleBar
    local tbf = Instance.new("Frame"); tbf.Size = UDim2.new(1, 0, 0, 10); tbf.Position = UDim2.new(0, 0, 1, -10); tbf.BackgroundColor3 = Colors.SidebarBg; tbf.BorderSizePixel = 0; tbf.Parent = titleBar
    local tdiv = Instance.new("Frame"); tdiv.Size = UDim2.new(1, 0, 0, 1); tdiv.Position = UDim2.new(0, 0, 1, -1); tdiv.BackgroundColor3 = Colors.Divider; tdiv.BorderSizePixel = 0; tdiv.Parent = titleBar
end
do
    -- 静态主题色竖标（去掉旧版带黑圆挖孔的月亮图标）
    local brandPill = Instance.new("Frame")
    brandPill.Size = UDim2.new(0, 4, 0, 16)
    brandPill.Position = UDim2.new(0, 14, 0.5, -8)
    brandPill.BackgroundColor3 = Colors.PurpleAccent
    brandPill.BorderSizePixel = 0
    brandPill.Parent = titleBar
    Instance.new("UICorner", brandPill).CornerRadius = UDim.new(1, 0)
    RegisterThemeUpdater(function() brandPill.BackgroundColor3 = Colors.PurpleAccent end)
end

local brandTitle = Instance.new("TextLabel"); brandTitle.Size = UDim2.new(0, 56, 1, 0); brandTitle.Position = UDim2.new(0, 24, 0, 0); brandTitle.BackgroundTransparency = 1; brandTitle.Font = Enum.Font.GothamBold; brandTitle.Text = "FSY"; brandTitle.TextColor3 = Colors.TextWhite; brandTitle.TextSize = 15; brandTitle.TextXAlignment = Enum.TextXAlignment.Left; brandTitle.Parent = titleBar
local gameSubtitle = Instance.new("TextLabel"); gameSubtitle.Size = UDim2.new(0, 240, 1, 0); gameSubtitle.Position = UDim2.new(0, 62, 0, 0); gameSubtitle.BackgroundTransparency = 1; gameSubtitle.Font = Enum.Font.GothamBold; gameSubtitle.Text = "FSY V1.8 · HEAVYWEIGHT FISHING"; gameSubtitle.TextColor3 = Colors.PurpleAccent; gameSubtitle.TextSize = 11; gameSubtitle.TextXAlignment = Enum.TextXAlignment.Left; gameSubtitle.Parent = titleBar
RegisterThemeUpdater(function() gameSubtitle.TextColor3 = Colors.PurpleAccent end)

-- 右上角静态窗口控制按钮：清爽浅灰胶囊 + 细描边，不搞小黑块
local winControls = Instance.new("Frame"); winControls.Size = UDim2.new(0, 84, 1, 0); winControls.Position = UDim2.new(1, -90, 0, 0); winControls.BackgroundTransparency = 1; winControls.Parent = titleBar
local minBtn = Instance.new("TextButton"); minBtn.Size = UDim2.new(0, 32, 0, 26); minBtn.Position = UDim2.new(0, 4, 0.5, -13); minBtn.BackgroundColor3 = Colors.ControlBg; minBtn.Font = Enum.Font.GothamBold; minBtn.Text = "FSY"; minBtn.TextColor3 = Colors.TextWhite; minBtn.TextSize = 11; minBtn.BorderSizePixel = 0; minBtn.AutoButtonColor = true; minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)
do
    local minStroke = Instance.new("UIStroke", minBtn); minStroke.Color = Colors.PurpleAccent; minStroke.Thickness = 1; minStroke.Transparency = 0.25
    RegisterThemeUpdater(function() minStroke.Color = Colors.PurpleAccent end)
end
local closeBtn = Instance.new("TextButton"); closeBtn.Size = UDim2.new(0, 32, 0, 26); closeBtn.Position = UDim2.new(0, 48, 0.5, -13); closeBtn.BackgroundColor3 = Colors.ControlBg; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Text = "X"; closeBtn.TextColor3 = Colors.AccentRed; closeBtn.TextSize = 12; closeBtn.BorderSizePixel = 0; closeBtn.AutoButtonColor = true; closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
do
    local closeStroke = Instance.new("UIStroke", closeBtn); closeStroke.Color = Colors.BorderSubtle; closeStroke.Thickness = 1
end

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
        local uiScale = (mainFrameScale and mainFrameScale.Parent and tonumber(mainFrameScale.Scale)) or 1
        local frameW = mainFrame.AbsoluteSize.X > 0 and mainFrame.AbsoluteSize.X or (700 * uiScale)
        local frameH = mainFrame.AbsoluteSize.Y > 0 and mainFrame.AbsoluteSize.Y or (480 * uiScale)
        -- mainFrame 使用中心锚点 AnchorPoint = (0.5, 0.5)，严防手机小屏下把窗口拖出屏幕边缘
        local halfW = frameW * 0.5
        local halfH = frameH * 0.5
        local marginX = math.min(12, vp.X * 0.05)
        local marginY = math.min(8, vp.Y * 0.04)
        local minX = math.min(halfW + marginX, vp.X * 0.5)
        local maxX = math.max(vp.X - halfW - marginX, vp.X * 0.5)
        local minY = math.min(halfH + marginY, vp.Y * 0.5)
        local maxY = math.max(vp.Y - halfH - marginY, vp.Y * 0.5)
        absX = math.clamp(absX, minX, maxX)
        absY = math.clamp(absY, minY, maxY)
        mainFrame.Position = UDim2.fromOffset(absX, absY)
    end

    -- [性能优化 #1] 主窗口标题栏拖拽仅在按下期间连接全局 UIS，松手立即断开
    local titleDragChangedConn = nil
    local titleDragEndedConn = nil
    -- 结束标题栏拖拽并立即断开临时挂载的全局输入连接
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
                -- [冗余清理] 原写法 input.UserInputState.Cancel == input.UserInputState 语义等价但极易误读，规范成直接比较
                if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
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

currentActiveTab = nil

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
    -- 累加滚动容器内所有可见子项的真实像素高度并折算为本地 Canvas 高度
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

    -- 刷新当前可见滚动容器的 CanvasSize 并修正越界滚动位置
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
    -- 以 0.15s 节流合并触发滚动区域 Canvas 高度重算
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

    -- 为滚动容器子控件绑定尺寸变化信号以动态更新滚动高度
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

navList = Instance.new("ScrollingFrame"); navList.Name = "NavList"; navList.Size = UDim2.new(1, 0, 1, -12); navList.Position = UDim2.new(0, 0, 0, 6); navList.BackgroundTransparency = 1; navList.BorderSizePixel = 0; navList.ScrollBarThickness = 3; navList.ScrollBarImageColor3 = Colors.BorderSubtle; navList.CanvasSize = UDim2.new(0, 0, 0, 0); navList.AutomaticCanvasSize = Enum.AutomaticSize.None; navList.Active = true; navList.ScrollingEnabled = true; navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout"); nl.SortOrder = Enum.SortOrder.LayoutOrder; nl.Padding = UDim.new(0, 4); nl.Parent = navList
    local np = Instance.new("UIPadding"); np.PaddingTop = UDim.new(0, 4); np.PaddingLeft = UDim.new(0, 8); np.PaddingRight = UDim.new(0, 8); np.Parent = navList
    BindVerticalCanvas(navList, nl, 6)
end

local contentArea = Instance.new("Frame"); contentArea.Name = "ContentArea"; contentArea.Size = UDim2.new(1, -140, 1, 0); contentArea.Position = UDim2.new(0, 140, 0, 0); contentArea.BackgroundTransparency = 1; contentArea.Parent = bodyFrame
local tabFrames = {}; local tabButtons = {}; local tabPills = {}

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
        local pill = tabPills[name]
        if name == tabName then
            PlayQuickTween(btn, {BackgroundColor3 = Colors.PurpleAccent, TextColor3 = Colors.TextWhite})
            if pill then
                pill.BackgroundColor3 = Colors.TextWhite
                pill.Visible = true
            end
        else
            PlayQuickTween(btn, {BackgroundColor3 = Colors.SidebarBg, TextColor3 = Colors.TextMuted})
            if pill then pill.Visible = false end
        end
    end
    local refresher = tabCanvasRefreshers[tabName]
    if refresher then
        task.defer(refresher)
        task.delay(0.1, refresher)
    end
end

    -- 创建左侧导航按钮与对应的右侧自适应滚动页面容器
CreateTab = function(name)
    local btn = Instance.new("TextButton"); btn.Name = "TabBtn_" .. name; btn.Size = UDim2.new(1, 0, 0, 32); btn.BackgroundColor3 = Colors.SidebarBg; btn.Font = Enum.Font.GothamBold; btn.Text = name; btn.TextColor3 = Colors.TextMuted; btn.TextSize = 12; btn.TextXAlignment = Enum.TextXAlignment.Left; btn.BorderSizePixel = 0; btn.Parent = navList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 12); p.Parent = btn end
    local pill = Instance.new("Frame"); pill.Name = "ActivePill"; pill.Size = UDim2.new(0, 3, 0, 16); pill.Position = UDim2.new(0, -8, 0.5, -8); pill.BackgroundColor3 = Colors.TextWhite; pill.BorderSizePixel = 0; pill.Visible = false; pill.Parent = btn
    Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 2)
    tabPills[name] = pill
    BindClick(btn, function() SwitchTab(name) end)

    local page = Instance.new("ScrollingFrame"); page.Name = "TabPage_" .. name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1; page.BorderSizePixel = 0; page.ScrollBarThickness = 4; page.ScrollBarImageColor3 = Colors.BorderPurple; page.CanvasSize = UDim2.new(0, 0, 0, 0); page.AutomaticCanvasSize = Enum.AutomaticSize.None; page.Active = true; page.ScrollingEnabled = true; page.ScrollingDirection = Enum.ScrollingDirection.Y; page.ElasticBehavior = Enum.ElasticBehavior.Never; page.Visible = false; page.Parent = contentArea
    do
        local pl = Instance.new("UIListLayout"); pl.SortOrder = Enum.SortOrder.LayoutOrder; pl.Padding = UDim.new(0, 10); pl.Parent = page
        local pp = Instance.new("UIPadding"); pp.PaddingTop = UDim.new(0, 12); pp.PaddingBottom = UDim.new(0, 20); pp.PaddingLeft = UDim.new(0, 14); pp.PaddingRight = UDim.new(0, 14); pp.Parent = page
        local refresher = BindVerticalCanvas(page, pl, 40)
        tabCanvasRefreshers[name] = refresher
        page:GetPropertyChangedSignal("Visible"):Connect(function()
            if page.Visible then
                task.defer(refresher)
                task.delay(0.12, refresher)
                task.delay(0.4, refresher)
            end
        end)
    end
    RegisterThemeUpdater(function()
        page.ScrollBarImageColor3 = Colors.BorderPurple
        if currentActiveTab == name then
            btn.BackgroundColor3 = Colors.PurpleAccent
            btn.TextColor3 = Colors.TextWhite
        end
    end)
    tabFrames[name] = page; tabButtons[name] = btn
    return page
end

local footerBar = Instance.new("Frame"); footerBar.Name = "FooterBar"; footerBar.Size = UDim2.new(1, 0, 0, 24); footerBar.Position = UDim2.new(0, 0, 1, -24); footerBar.BackgroundColor3 = Colors.SidebarBg; footerBar.BorderSizePixel = 0; footerBar.Parent = mainFrame
Instance.new("UICorner", footerBar).CornerRadius = UDim.new(0, 8)
do
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, 0, 0, 10); tf.BackgroundColor3 = Colors.SidebarBg; tf.BorderSizePixel = 0; tf.Parent = footerBar
    local fd = Instance.new("Frame"); fd.Size = UDim2.new(1, 0, 0, 1); fd.BackgroundColor3 = Colors.Divider; fd.BorderSizePixel = 0; fd.Parent = footerBar
end
local footerBrand = Instance.new("TextLabel"); footerBrand.Size = UDim2.new(0, 260, 1, 0); footerBrand.Position = UDim2.new(0, 12, 0, 0); footerBrand.BackgroundTransparency = 1; footerBrand.Font = Enum.Font.GothamBold; footerBrand.Text = "FSY V1.8 | Heavyweight Fishing"; footerBrand.TextColor3 = Colors.TextMuted; footerBrand.TextSize = 10; footerBrand.TextXAlignment = Enum.TextXAlignment.Left; footerBrand.Parent = footerBar
local footerKey = Instance.new("TextLabel"); footerKey.Size = UDim2.new(0, 280, 1, 0); footerKey.Position = UDim2.new(1, -292, 0, 0); footerKey.BackgroundTransparency = 1; footerKey.Font = Enum.Font.Gotham; footerKey.Text = "[R-CTRL] 菜单 | [END] 停止"; footerKey.TextColor3 = Colors.TextMuted; footerKey.TextSize = 10; footerKey.TextXAlignment = Enum.TextXAlignment.Right; footerKey.Parent = footerBar

local isUiAnimating = false
local UI_OPEN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UI_CLOSE_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BALL_POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

    -- 展开主窗口并隐藏 FSY 悬浮球（使用 PlayQuickTween 防冲突取消上一次补间，避免闪烁卡顿）
local function OpenUI()
    if not mainFrame or isUiAnimating then return end
    isUiAnimating = true
    if screenGui then
        if not screenGui.Enabled then screenGui.Enabled = true end
        screenGui.DisplayOrder = 100
    end
    mainFrame.ZIndex = 3000
    UpdateMainFrameScale(true)
    local targetScale = (mainFrameScale and mainFrameScale.Scale) or (Config.UIScale or 0.75)
    if mainFrameScale then mainFrameScale.Scale = targetScale * 0.92 end
    mainFrame.BackgroundTransparency = 0.2
    mainFrame.Visible = true
    if floatingBall then floatingBall.Visible = false end

    if mainFrameScale then PlayQuickTween(mainFrameScale, {Scale = targetScale}, UI_OPEN_TWEEN) end
    PlayQuickTween(mainFrame, {BackgroundTransparency = 0}, UI_OPEN_TWEEN)
    task.delay(0.19, function()
        isUiAnimating = false
        if mainFrame then mainFrame.BackgroundTransparency = 0 end
        if UpdateMainFrameScale then UpdateMainFrameScale(true) end
    end)
end

    -- 最小化主窗口并弹出 FSY 悬浮球
CloseUI = function()
    if not mainFrame or isUiAnimating then return end
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
    isUiAnimating = true
    local baseScale = (mainFrameScale and mainFrameScale.Scale) or (Config.UIScale or 0.75)
    if mainFrameScale then PlayQuickTween(mainFrameScale, {Scale = baseScale * 0.92}, UI_CLOSE_TWEEN) end
    PlayQuickTween(mainFrame, {BackgroundTransparency = 0.35}, UI_CLOSE_TWEEN)
    task.delay(0.16, function()
        if mainFrame then
            mainFrame.Visible = false
            mainFrame.BackgroundTransparency = 0
            if UpdateMainFrameScale then UpdateMainFrameScale(true) end
        end
        if floatingBall then
            floatingBall.Size = UDim2.new(0, FLOATING_BALL_SIZE - 10, 0, FLOATING_BALL_SIZE - 10)
            floatingBall.Visible = true
            PlayQuickTween(floatingBall, {Size = UDim2.new(0, FLOATING_BALL_SIZE, 0, FLOATING_BALL_SIZE)}, BALL_POP_TWEEN)
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
BindClick(minBtn, ToggleUiVisibility)
-- 关闭：弹出确认框，点「确认退出」才真正卸载，避免误触
do
    local confirmOverlay = nil
    -- 关闭并销毁退出确认弹窗遮罩
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
        confirmOverlay.ZIndex = 4000
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
        card.ZIndex = 4001
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
        title.Text = "确认退出 FSY V1.8？"
        title.TextColor3 = Colors.TextWhite
        title.TextSize = 16
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 4002
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
        desc.ZIndex = 4002
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
        cancelBtn.ZIndex = 4002
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
        okBtn.ZIndex = 4002
        okBtn.Parent = card
        Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 6)

        -- [UI 交互修复] 确认框按钮同样走统一双通道绑定
        BindClick(cancelBtn, CloseUnloadConfirm)
        BindClick(okBtn, function()
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

    -- 点击标题栏右上角 [X] 时唤起退出确认弹窗
    local function onCloseClick()
        ShowUnloadConfirm()
    end
    BindClick(closeBtn, onCloseClick)
end
-- ============================================================================
-- 【UI 交互修复 4/4：触屏点击兜底】
-- 某些执行器/旧客户端会把触摸事件交给透明层，或 Activated 合成事件偶发丢失，
-- 表现为面板可见但按钮点不动。UIS 的 InputEnded 仍能拿到最终坐标，这里按坐标
-- 找到同一位置下已登记的按钮；若它在 0.12s 内没有收到过点击，则补发一次。
-- 保护：
--   - 拖动 / 长按不触发；面板隐藏或退出确认框打开时不触发；
--   - 最上层是别的 GuiButton 或主动拦截输入的容器时绝不穿透，避免误触其它界面。
-- ============================================================================
do
    local pressPosition, pressMoved, pressAt = nil, false, 0
    table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            pressPosition = input.Position
            pressMoved = false
            pressAt = tick()
        end
    end))
    table.insert(activeConnections, UserInputService.InputChanged:Connect(function(input)
        if not pressPosition then return end
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then
            if (input.Position - pressPosition).Magnitude > 14 then pressMoved = true end
        end
    end))
    table.insert(activeConnections, UserInputService.InputEnded:Connect(function(input)
        if not pressPosition then return end
        -- 用松手位置做命中（按在按钮上、松手滑到别处时不会误触）
        local pos, moved, held = input.Position, pressMoved, tick() - pressAt
        pressPosition = nil
        if moved or held > 0.8 then return end
        if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        task.delay(0.12, function()
            if not isRunning or not mainFrame or not mainFrame.Visible then return end
            if screenGui:FindFirstChild("UnloadConfirmOverlay") then return end
            local ok, objects = pcall(function() return UserInputService:GetGuiObjectsAtPosition(pos.X, pos.Y) end)
            if not ok or type(objects) ~= "table" or #objects == 0 then return end
            for _, obj in ipairs(objects) do
                local handler = clickRegistry[obj]
                if handler then
                    -- 0.12s 内已由原生事件处理过的按钮不重复触发
                    if tick() - (lastClickAt[obj] or 0) >= 0.12 then handler() end
                    return
                end
                -- 其它可交互按钮 / 主动拦截层在上方时，尊重它，不穿透
                if obj:IsA("GuiButton") then return end
                if obj:IsA("GuiObject") and obj.Active == true then return end
            end
        end)
    end))
end

end -- end of Window Frame Construction Scope

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
-- ============================================================================
-- 【折叠分组控件 createCollapsibleGroup（模块 13 通用组件）】
-- 作用说明：
--   1. 合并原“createCategoryHeader 分组标题 + createCardGroup 卡片容器”两步调用为一个可折叠分组：
--      标题行右侧带三角指示，收起时三角朝右（Rotation=0），展开时旋转朝下（Rotation=90）；
--   2. 点击标题行切换展开 / 收起，高度与三角旋转统一使用 Quad 缓动（0.18s），配色与圆角和 FSY 主界面一致；
--   3. 返回分组内容容器 body，调用方照旧把 createToggleRow / createSliderRow / createButtonRow 塞进 body；
--   4. 折叠状态登记到 collapsibleSections，供搜索过滤自动展开命中分组、自动收起无命中分组。
-- 性能说明：
--   - 标题行 / 三角 / 悬停 Tween 全部预创建复用，点击时不新建 Tween 实例，连续点击也不会堆积；
--   - 收起时 body 高度为 0 且 AutomaticSize=None，Roblox 不再为其子项做布局，长页面收起后更省；
--   - 展开结束后恢复 AutomaticSize=Y，下拉框展开 / NPC 列表重建等动态高度仍能自动撑开。
-- ============================================================================
local COLLAPSE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COLLAPSE_ARROW_COLLAPSED = 0
local COLLAPSE_ARROW_EXPANDED = 90

-- 创建可折叠分组：parent 为页面容器；titleText 为分组标题（自动转大写）；defaultExpanded 缺省为展开
local function createCollapsibleGroup(parent, titleText, defaultExpanded)
    if defaultExpanded == nil then defaultExpanded = true end
    local expanded = (defaultExpanded ~= false)

    local section = Instance.new("Frame")
    section.Name = "Section_" .. tostring(titleText)
    section.Size = UDim2.new(1, 0, 0, 0)
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.BackgroundTransparency = 1
    section.BorderSizePixel = 0
    section.Parent = parent

    local sectionLayout = Instance.new("UIListLayout")
    sectionLayout.SortOrder = Enum.SortOrder.LayoutOrder
    sectionLayout.Padding = UDim.new(0, 0)
    sectionLayout.Parent = section

    -- 标题行：整行可点，左侧紫色竖条 + 标题 + 右侧三角
    local header = Instance.new("TextButton")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 26)
    header.BackgroundColor3 = Colors.RowNormal
    header.BackgroundTransparency = 1
    header.BorderSizePixel = 0
    header.Text = ""
    header.AutoButtonColor = false
    header.Parent = section
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 5)

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 0, 12)
    accentBar.Position = UDim2.new(0, 8, 0.5, -6)
    accentBar.BackgroundColor3 = Colors.PurpleAccent
    accentBar.BorderSizePixel = 0
    accentBar.Parent = header
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -58, 1, 0)
    titleLabel.Position = UDim2.new(0, 16, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = string.upper(tostring(titleText))
    titleLabel.TextColor3 = Colors.PurplePrimary
    RegisterThemeUpdater(function()
        accentBar.BackgroundColor3 = Colors.PurpleAccent
        titleLabel.TextColor3 = Colors.PurplePrimary
    end)
    titleLabel.TextSize = 11
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.Parent = header

    -- 三角指示：用“▶”字符做旋转，收起朝右 0°，展开朝下 90°，无需额外图片资源
    local arrow = Instance.new("TextLabel")
    arrow.Name = "Arrow"
    arrow.Size = UDim2.new(0, 16, 0, 16)
    arrow.Position = UDim2.new(1, -22, 0.5, -8)
    arrow.BackgroundTransparency = 1
    arrow.Font = Enum.Font.GothamBold
    arrow.Text = "▶"
    arrow.TextColor3 = Colors.PurpleMuted
    arrow.TextSize = 9
    arrow.Rotation = expanded and COLLAPSE_ARROW_EXPANDED or COLLAPSE_ARROW_COLLAPSED
    arrow.Parent = header

    -- 内容容器：沿用原 createCardGroup 的圆角 + 描边 + 列表布局，保证视觉与旧版一致
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.BackgroundColor3 = Colors.RowNormal
    body.BorderSizePixel = 0
    body.ClipsDescendants = true
    body.Parent = section
    Instance.new("UICorner", body).CornerRadius = UDim.new(0, 6)
    local bodyStroke = Instance.new("UIStroke")
    bodyStroke.Color = Colors.BorderSubtle
    bodyStroke.Thickness = 1
    bodyStroke.Parent = body
    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Padding = UDim.new(0, 0)
    bodyLayout.Parent = body

    local headerEnterTw = TweenService:Create(header, COLLAPSE_TWEEN_INFO, {BackgroundTransparency = 0.35})
    local headerLeaveTw = TweenService:Create(header, COLLAPSE_TWEEN_INFO, {BackgroundTransparency = 1})
    local arrowExpandTw = TweenService:Create(arrow, COLLAPSE_TWEEN_INFO, {Rotation = COLLAPSE_ARROW_EXPANDED})
    local arrowCollapseTw = TweenService:Create(arrow, COLLAPSE_TWEEN_INFO, {Rotation = COLLAPSE_ARROW_COLLAPSED})
    local bodyTween = nil

    -- 主窗口 UIScale 会放大 AbsoluteSize，折算成本地 offset 才能给 Size 使用
    -- 获取主窗口当前生效的 UIScale 缩放系数
    local function getUiScale()
        local sc = (mainFrameScale and mainFrameScale.Parent) and mainFrameScale.Scale or 1
        if type(sc) ~= "number" or sc <= 0.05 then sc = 1 end
        return sc
    end

    -- 测量 body 展开后的真实高度（绝对像素 → 本地 offset）
    -- 测量折叠分组内容区展开后的真实本地高度
    local function measureBodyHeight()
        local absH = 0
        if bodyLayout and bodyLayout.Parent == body then
            absH = bodyLayout.AbsoluteContentSize.Y
        end
        if absH <= 0 then
            for _, child in ipairs(body:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then
                    absH = absH + child.AbsoluteSize.Y
                end
            end
        end
        if absH <= 0 then
            -- 兜底：布局尚未计算时按行数 × 标准行高估算，动画结束后 AutomaticSize 会自校正
            local count = 0
            for _, child in ipairs(body:GetChildren()) do
                if child:IsA("GuiObject") then count = count + 1 end
            end
            absH = count * 42 * getUiScale()
        end
        return math.max(absH / getUiScale(), 0)
    end

    -- 折叠 / 展开后主动刷新所属页面画布高度，避免收起后仍能下滑到空白区
    -- 在分组折叠或展开后请求刷新所属标签页的滚动高度
    local function requestCanvasRefresh()
        if not (currentActiveTab and tabCanvasRefreshers) then return end
        local refresher = tabCanvasRefreshers[currentActiveTab]
        if not refresher then return end
        pcall(refresher)
        task.delay(0.22, function()
            if isRunning then pcall(refresher) end
        end)
    end

    -- 切换折叠分组的展开/收起状态并播放三角旋转与高度补间动画
    local function applyExpandedState(wantExpanded, animate)
        expanded = (wantExpanded ~= false)
        if bodyTween then
            pcall(function() bodyTween:Cancel() end)
            bodyTween = nil
        end

        if not animate then
            pcall(function() arrowExpandTw:Cancel(); arrowCollapseTw:Cancel() end)
            arrow.Rotation = expanded and COLLAPSE_ARROW_EXPANDED or COLLAPSE_ARROW_COLLAPSED
            body.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
            body.Size = UDim2.new(1, 0, 0, 0)
            return
        end

        if expanded then
            arrowExpandTw:Play()
            local targetH = measureBodyHeight()
            body.AutomaticSize = Enum.AutomaticSize.None
            body.Size = UDim2.new(1, 0, 0, 0)
            local tw = TweenService:Create(body, COLLAPSE_TWEEN_INFO, {Size = UDim2.new(1, 0, 0, targetH)})
            bodyTween = tw
            tw:Play()
            task.delay(COLLAPSE_TWEEN_INFO.Time, function()
                -- 脚本卸载 / UI 已销毁时直接放弃回调，避免对已 Destroy 的实例写属性报错
                if bodyTween ~= tw or not body or not body.Parent then return end
                bodyTween = nil
                -- 动画结束后交回 AutomaticSize，保证后续动态增删行仍然自适应
                body.AutomaticSize = Enum.AutomaticSize.Y
                body.Size = UDim2.new(1, 0, 0, 0)
            end)
        else
            arrowCollapseTw:Play()
            local currentH = body.AbsoluteSize.Y / getUiScale()
            body.AutomaticSize = Enum.AutomaticSize.None
            body.Size = UDim2.new(1, 0, 0, math.max(currentH, 0))
            local tw = TweenService:Create(body, COLLAPSE_TWEEN_INFO, {Size = UDim2.new(1, 0, 0, 0)})
            bodyTween = tw
            tw:Play()
            task.delay(COLLAPSE_TWEEN_INFO.Time, function()
                if bodyTween ~= tw or not body or not body.Parent then return end
                bodyTween = nil
                body.Size = UDim2.new(1, 0, 0, 0)
            end)
        end
    end

    -- 点击标题行：先收起其它展开中的下拉框，再切换本组展开状态
    local function onHeaderClicked()
        if currentlyOpenDropdown and currentlyOpenDropdown.Close then
            pcall(currentlyOpenDropdown.Close)
            currentlyOpenDropdown = nil
        end
        applyExpandedState(not expanded, true)
        requestCanvasRefresh()
    end

    BindClick(header, onHeaderClicked)
    header.MouseEnter:Connect(function() headerEnterTw:Play() end)
    header.MouseLeave:Connect(function() headerLeaveTw:Play() end)

    -- 分组记录：供搜索过滤 / 其它模块读取折叠状态
    collapsibleSections[#collapsibleSections + 1] = {
        section = section,
        header = header,
        body = body,
        title = tostring(titleText),
        GetExpanded = function() return expanded end,
        SetExpanded = function(value, animate) applyExpandedState(value, animate == true) end,
        HasVisibleRow = function()
            for _, child in ipairs(body:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then return true end
            end
            return false
        end,
    }

    -- 初始状态不播动画，避免注入瞬间 30+ 个分组同时补间
    applyExpandedState(expanded, false)
    return body
end

-- [UI 设计移植] 仿侧边抽屉式折叠胶囊：主行右侧带状态胶囊 + 旋转三角，点击在本行下方用 Quad 缓动弹出圆角胶囊容器
-- 返回胶囊内容容器，调用方把 createToggleRow / createDropdownRow / createButtonRow 塞进来即可
local function createDrawerCapsule(parent, labelText, descText, defaultExpanded)
    local expanded = (defaultExpanded == true)
    local wrapper = Instance.new("Frame")
    wrapper.Name = "DrawerCapsule_" .. tostring(labelText)
    wrapper.Size = UDim2.new(1, 0, 0, 0)
    wrapper.AutomaticSize = Enum.AutomaticSize.Y
    wrapper.BackgroundTransparency = 1
    wrapper.BorderSizePixel = 0
    wrapper.Parent = parent
    local wrapLayout = Instance.new("UIListLayout")
    wrapLayout.SortOrder = Enum.SortOrder.LayoutOrder
    wrapLayout.Padding = UDim.new(0, 0)
    wrapLayout.Parent = wrapper
    local mainRow = Instance.new("TextButton")
    mainRow.Name = "DrawerTriggerRow"
    mainRow.LayoutOrder = 1
    mainRow.Size = UDim2.new(1, 0, 0, 42)
    mainRow.BackgroundColor3 = expanded and Colors.RowHover or Colors.RowNormal
    mainRow.BorderSizePixel = 0
    mainRow.Text = ""
    mainRow.AutoButtonColor = false
    mainRow.Parent = wrapper
    local rowPad = Instance.new("UIPadding")
    rowPad.PaddingLeft = UDim.new(0, 10)
    rowPad.PaddingRight = UDim.new(0, 10)
    rowPad.Parent = mainRow
    local leftPill = Instance.new("Frame")
    leftPill.Size = UDim2.new(0, 3, 0, 18)
    leftPill.Position = UDim2.new(0, 0, 0.5, -9)
    leftPill.BackgroundColor3 = expanded and Colors.PurplePrimary or Colors.PurpleAccent
    leftPill.BorderSizePixel = 0
    leftPill.Parent = mainRow
    Instance.new("UICorner", leftPill).CornerRadius = UDim.new(1, 0)
    local tf = Instance.new("Frame")
    tf.Size = UDim2.new(1, -76, 1, 0)
    tf.Position = UDim2.new(0, 9, 0, 0)
    tf.BackgroundTransparency = 1
    tf.Parent = mainRow
    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.new(1, 0, 0, 18)
    tl.Position = UDim2.new(0, 0, 0, 4)
    tl.BackgroundTransparency = 1
    tl.Font = Enum.Font.GothamBold
    tl.Text = labelText
    tl.TextColor3 = Colors.TextWhite
    tl.TextSize = 12
    tl.TextXAlignment = Enum.TextXAlignment.Left
    tl.TextTruncate = Enum.TextTruncate.AtEnd
    tl.Parent = tf
    local dl = Instance.new("TextLabel")
    dl.Size = UDim2.new(1, 0, 0, 14)
    dl.Position = UDim2.new(0, 0, 0, 22)
    dl.BackgroundTransparency = 1
    dl.Font = Enum.Font.Gotham
    dl.Text = descText or "点击展开下方折叠胶囊子选项"
    dl.TextColor3 = Colors.TextMuted
    dl.TextSize = 10
    dl.TextXAlignment = Enum.TextXAlignment.Left
    dl.TextTruncate = Enum.TextTruncate.AtEnd
    dl.Parent = tf
    local indicatorPill = Instance.new("Frame")
    indicatorPill.Name = "IndicatorCapsule"
    indicatorPill.Size = UDim2.new(0, 58, 0, 22)
    indicatorPill.Position = UDim2.new(1, -58, 0.5, -11)
    indicatorPill.BackgroundColor3 = expanded and Colors.PurpleDark or Colors.ControlBg
    indicatorPill.BorderSizePixel = 0
    indicatorPill.Parent = mainRow
    Instance.new("UICorner", indicatorPill).CornerRadius = UDim.new(1, 0)
    local indStroke = Instance.new("UIStroke")
    indStroke.Color = expanded and Colors.PurpleAccent or Colors.BorderSubtle
    indStroke.Thickness = 1
    indStroke.Transparency = 0.25
    indStroke.Parent = indicatorPill
    local stateLbl = Instance.new("TextLabel")
    stateLbl.Size = UDim2.new(0, 32, 1, 0)
    stateLbl.Position = UDim2.new(0, 8, 0, 0)
    stateLbl.BackgroundTransparency = 1
    stateLbl.Font = Enum.Font.GothamBold
    stateLbl.Text = expanded and "收起" or "展开"
    stateLbl.TextColor3 = expanded and Colors.TextWhite or Colors.PurpleMuted
    stateLbl.TextSize = 10
    stateLbl.TextXAlignment = Enum.TextXAlignment.Left
    stateLbl.Parent = indicatorPill
    local arrow = Instance.new("TextLabel")
    arrow.Name = "TriangleArrow"
    arrow.Size = UDim2.new(0, 14, 0, 14)
    arrow.Position = UDim2.new(1, -18, 0.5, -7)
    arrow.BackgroundTransparency = 1
    arrow.Font = Enum.Font.GothamBold
    arrow.Text = "▶"
    arrow.TextColor3 = expanded and Colors.PurplePrimary or Colors.PurpleMuted
    arrow.TextSize = 9
    arrow.Rotation = expanded and COLLAPSE_ARROW_EXPANDED or COLLAPSE_ARROW_COLLAPSED
    arrow.Parent = indicatorPill
    local capsuleHolder = Instance.new("Frame")
    capsuleHolder.Name = "CapsuleHolder"
    capsuleHolder.LayoutOrder = 2
    capsuleHolder.Size = UDim2.new(1, 0, 0, 0)
    capsuleHolder.BackgroundTransparency = 1
    capsuleHolder.BorderSizePixel = 0
    capsuleHolder.ClipsDescendants = true
    capsuleHolder.Visible = expanded
    capsuleHolder.Parent = wrapper
    local holderPad = Instance.new("UIPadding")
    holderPad.PaddingLeft = UDim.new(0, 10)
    holderPad.PaddingRight = UDim.new(0, 10)
    holderPad.PaddingTop = UDim.new(0, 2)
    holderPad.PaddingBottom = UDim.new(0, 6)
    holderPad.Parent = capsuleHolder
    local capsuleBox = Instance.new("Frame")
    capsuleBox.Name = "CapsuleBox"
    capsuleBox.Size = UDim2.new(1, 0, 0, 0)
    capsuleBox.AutomaticSize = Enum.AutomaticSize.Y
    capsuleBox.BackgroundColor3 = Colors.InputBg
    capsuleBox.BorderSizePixel = 0
    capsuleBox.Parent = capsuleHolder
    Instance.new("UICorner", capsuleBox).CornerRadius = UDim.new(0, 10)
    local capStroke = Instance.new("UIStroke")
    capStroke.Color = Colors.BorderPurple
    capStroke.Thickness = 1
    capStroke.Transparency = 0.45
    capStroke.Parent = capsuleBox
    local capBoxPad = Instance.new("UIPadding")
    capBoxPad.PaddingLeft = UDim.new(0, 8)
    capBoxPad.PaddingRight = UDim.new(0, 4)
    capBoxPad.PaddingTop = UDim.new(0, 4)
    capBoxPad.PaddingBottom = UDim.new(0, 4)
    capBoxPad.Parent = capsuleBox
    local drawerGuide = Instance.new("Frame")
    drawerGuide.Name = "DrawerGuideLine"
    drawerGuide.Size = UDim2.new(0, 2, 1, -8)
    drawerGuide.Position = UDim2.new(0, -3, 0, 4)
    drawerGuide.BackgroundColor3 = Colors.PurpleAccent
    drawerGuide.BackgroundTransparency = 0.35
    drawerGuide.BorderSizePixel = 0
    drawerGuide.Parent = capsuleBox
    Instance.new("UICorner", drawerGuide).CornerRadius = UDim.new(1, 0)
    local content = Instance.new("Frame")
    content.Name = "CapsuleContent"
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.Parent = capsuleBox
    local contentLayout = Instance.new("UIListLayout")
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, 2)
    contentLayout.Parent = content
    local holderTween = nil
    local function getUiScale()
        local sc = (mainFrameScale and mainFrameScale.Parent) and mainFrameScale.Scale or 1
        if type(sc) ~= "number" or sc <= 0.05 then sc = 1 end
        return sc
    end
    local function measureCapsuleHeight()
        local sc = getUiScale()
        local absH = contentLayout.AbsoluteContentSize.Y
        if absH <= 0 then
            for _, ch in ipairs(content:GetChildren()) do
                if ch:IsA("GuiObject") and ch.Visible then absH = absH + ch.AbsoluteSize.Y end
            end
        end
        if absH <= 0 then
            local cnt = 0
            for _, ch in ipairs(content:GetChildren()) do if ch:IsA("GuiObject") then cnt = cnt + 1 end end
            absH = cnt * 42 * sc
        end
        return math.max((absH / sc) + 16, 0)
    end
    local function refreshActiveTabCanvas()
        if not (currentActiveTab and tabCanvasRefreshers) then return end
        local refresher = tabCanvasRefreshers[currentActiveTab]
        if not refresher then return end
        pcall(refresher)
        task.delay(0.20, function() if isRunning then pcall(refresher) end end)
        task.delay(0.38, function() if isRunning then pcall(refresher) end end)
    end
    local function setDrawerExpanded(wantExpanded, animate)
        expanded = (wantExpanded == true)
        if holderTween then
            pcall(function() holderTween:Cancel() end)
            holderTween = nil
        end
        stateLbl.Text = expanded and "收起" or "展开"
        stateLbl.TextColor3 = expanded and Colors.TextWhite or Colors.PurpleMuted
        leftPill.BackgroundColor3 = expanded and Colors.PurplePrimary or Colors.PurpleAccent
        if not animate then
            arrow.Rotation = expanded and COLLAPSE_ARROW_EXPANDED or COLLAPSE_ARROW_COLLAPSED
            arrow.TextColor3 = expanded and Colors.PurplePrimary or Colors.PurpleMuted
            indicatorPill.BackgroundColor3 = expanded and Colors.PurpleDark or Colors.ControlBg
            indStroke.Color = expanded and Colors.PurpleAccent or Colors.BorderSubtle
            mainRow.BackgroundColor3 = expanded and Colors.RowHover or Colors.RowNormal
            capsuleHolder.ClipsDescendants = not expanded
            capsuleHolder.Visible = expanded
            capsuleHolder.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
            capsuleHolder.Size = UDim2.new(1, 0, 0, 0)
            return
        end
        PlayQuickTween(arrow, { Rotation = expanded and COLLAPSE_ARROW_EXPANDED or COLLAPSE_ARROW_COLLAPSED, TextColor3 = expanded and Colors.PurplePrimary or Colors.PurpleMuted }, COLLAPSE_TWEEN_INFO)
        PlayQuickTween(indicatorPill, { BackgroundColor3 = expanded and Colors.PurpleDark or Colors.ControlBg }, COLLAPSE_TWEEN_INFO)
        PlayQuickTween(indStroke, { Color = expanded and Colors.PurpleAccent or Colors.BorderSubtle }, COLLAPSE_TWEEN_INFO)
        PlayQuickTween(mainRow, { BackgroundColor3 = expanded and Colors.RowHover or Colors.RowNormal }, COLLAPSE_TWEEN_INFO)
        if expanded then
            capsuleHolder.ClipsDescendants = true
            capsuleHolder.Visible = true
            local targetH = measureCapsuleHeight()
            capsuleHolder.AutomaticSize = Enum.AutomaticSize.None
            capsuleHolder.Size = UDim2.new(1, 0, 0, 0)
            local tw = TweenService:Create(capsuleHolder, COLLAPSE_TWEEN_INFO, { Size = UDim2.new(1, 0, 0, targetH) })
            holderTween = tw
            tw:Play()
            task.delay(COLLAPSE_TWEEN_INFO.Time, function()
                if holderTween ~= tw or not capsuleHolder or not capsuleHolder.Parent then return end
                holderTween = nil
                capsuleHolder.ClipsDescendants = false
                capsuleHolder.AutomaticSize = Enum.AutomaticSize.Y
                capsuleHolder.Size = UDim2.new(1, 0, 0, 0)
            end)
        else
            capsuleHolder.ClipsDescendants = true
            local curH = capsuleHolder.AbsoluteSize.Y / getUiScale()
            capsuleHolder.AutomaticSize = Enum.AutomaticSize.None
            capsuleHolder.Size = UDim2.new(1, 0, 0, math.max(curH, 0))
            local tw = TweenService:Create(capsuleHolder, COLLAPSE_TWEEN_INFO, { Size = UDim2.new(1, 0, 0, 0) })
            holderTween = tw
            tw:Play()
            task.delay(COLLAPSE_TWEEN_INFO.Time, function()
                if holderTween ~= tw or not capsuleHolder or not capsuleHolder.Parent then return end
                holderTween = nil
                capsuleHolder.Size = UDim2.new(1, 0, 0, 0)
                capsuleHolder.Visible = false
            end)
        end
    end
    local drawerRecord = {
        wrapper = wrapper, content = content, parentCard = parent,
        query = (tostring(labelText) .. " " .. tostring(descText or "")):lower(),
        searchSaved = nil,
        GetExpanded = function() return expanded end,
        SetExpanded = function(val, animate) setDrawerExpanded(val, animate == true) end,
    }
    drawerCapsules[#drawerCapsules + 1] = drawerRecord
    local function onTriggerClicked()
        if currentlyOpenDropdown and currentlyOpenDropdown.Close then
            pcall(currentlyOpenDropdown.Close)
            currentlyOpenDropdown = nil
        end
        local nextVal = not expanded
        if drawerRecord.searchSaved ~= nil then drawerRecord.searchSaved = nextVal end
        setDrawerExpanded(nextVal, true)
        refreshActiveTabCanvas()
    end
    -- [UI 交互修复] 统一走 BindClick：触屏 Activated 与 MouseButton1Click 双通道兜底
    RegisterThemeUpdater(function()
        leftPill.BackgroundColor3 = expanded and Colors.PurplePrimary or Colors.PurpleAccent
        indicatorPill.BackgroundColor3 = expanded and Colors.PurpleDark or Colors.ControlBg
        indStroke.Color = expanded and Colors.PurpleAccent or Colors.BorderSubtle
        arrow.TextColor3 = expanded and Colors.PurplePrimary or Colors.PurpleMuted
        capStroke.Color = Colors.BorderPurple
        drawerGuide.BackgroundColor3 = Colors.PurpleAccent
    end)
    BindClick(mainRow, onTriggerClicked)
    mainRow.MouseEnter:Connect(function() PlayQuickTween(mainRow, { BackgroundColor3 = Colors.RowHover }) end)
    mainRow.MouseLeave:Connect(function() if not expanded then PlayQuickTween(mainRow, { BackgroundColor3 = Colors.RowNormal }) end end)
    setDrawerExpanded(expanded, false)
    return content
end
-- 创建通用功能行底板（纯白主标题 + 浅灰副标题描述 + 按需原生悬停过渡）
local function createBaseRow(parent, labelText, descText)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = true; row.Parent = parent
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -190, 1, 0); tf.BackgroundTransparency = 1; tf.ClipsDescendants = true; tf.Parent = row
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 18); tl.Position = UDim2.new(0, 0, 0, 4); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 12; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.TextTruncate = Enum.TextTruncate.AtEnd; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 14); dl.Position = UDim2.new(0, 0, 0, 22); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 10; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.TextTruncate = Enum.TextTruncate.AtEnd; dl.Parent = tf
    row.MouseEnter:Connect(function() PlayQuickTween(row, {BackgroundColor3 = Colors.RowHover}) end)
    row.MouseLeave:Connect(function() PlayQuickTween(row, {BackgroundColor3 = Colors.RowNormal}) end)
    return row
end

-- 创建开关行组件（支持平滑拨动动画、Config 绑定与主题切换自动同步）
local function createToggleRow(parent, labelText, descText, initialVal, callback, configKey)
    if type(initialVal) == "function" then callback = initialVal; initialVal = false end
    local row = createBaseRow(parent, labelText, descText)
    local state = initialVal or false
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 40, 0, 20); btn.Position = UDim2.new(1, -40, 0.5, -10); btn.BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg; btn.Text = ""; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame"); knob.Size = UDim2.new(0, 14, 0, 14); knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7); knob.BackgroundColor3 = Colors.TextWhite; knob.BorderSizePixel = 0; knob.Parent = btn
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local function updateVisuals(instant)
        if instant then
            btn.BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg
            knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        else
            PlayQuickTween(btn, {BackgroundColor3 = state and Colors.PurpleAccent or Colors.ControlBg})
            PlayQuickTween(knob, {Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)})
        end
    end
    RegisterThemeUpdater(function()
        if state then btn.BackgroundColor3 = Colors.PurpleAccent end
    end)
    BindClick(btn, function() state = not state; updateVisuals(false); if type(callback) == "function" then callback(state) end end)
    local ctrl = {frame = row, Set = function(val, silent) state = not not val; updateVisuals(silent == true); if not silent and type(callback) == "function" then callback(state) end end, Get = function() return state end}
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

-- 创建数值滑块行组件（按下时动态挂载输入监听并锁定外层滚动，松手即刻释放）
local function createSliderRow(parent, labelText, descText, minVal, maxVal, initialVal, isFloat, suffix, callback, configKey)
    local row = createBaseRow(parent, labelText, descText)
    local currentVal = initialVal or minVal; suffix = suffix or ""
    local container = Instance.new("Frame"); container.Size = UDim2.new(0, 180, 0, 36); container.Position = UDim2.new(1, -180, 0.5, -18); container.BackgroundTransparency = 1; container.Parent = row
    local valLabel = Instance.new("TextLabel"); valLabel.Size = UDim2.new(0, 68, 1, 0); valLabel.Position = UDim2.new(1, -68, 0, 0); valLabel.BackgroundTransparency = 1; valLabel.Font = Enum.Font.GothamBold; valLabel.TextColor3 = Colors.TextWhite; valLabel.TextSize = 11; valLabel.TextXAlignment = Enum.TextXAlignment.Right; valLabel.Parent = container
    local touchArea = Instance.new("Frame"); touchArea.Size = UDim2.new(1, -74, 1, 0); touchArea.Position = UDim2.new(0, 0, 0, 0); touchArea.BackgroundTransparency = 1; touchArea.ClipsDescendants = false; touchArea.Parent = container
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, 0, 0, 6); track.Position = UDim2.new(0, 0, 0.5, -3); track.BackgroundColor3 = Colors.ControlBg; track.BorderSizePixel = 0; track.Parent = touchArea
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local fill = Instance.new("Frame"); fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = Colors.PurpleAccent; fill.BorderSizePixel = 0; fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame"); knob.Size = UDim2.new(0, 14, 0, 14); knob.BackgroundColor3 = Colors.TextWhite; knob.BorderSizePixel = 0; knob.Parent = touchArea
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local knobStroke = Instance.new("UIStroke", knob); knobStroke.Color = Colors.PurpleAccent; knobStroke.Thickness = 1.5
    RegisterThemeUpdater(function()
        fill.BackgroundColor3 = Colors.PurpleAccent
        knobStroke.Color = Colors.PurpleAccent
    end)
    -- 根据当前数值更新滑块填充条宽度、圆点位置与右侧数值文本
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
    -- 向上查找滑块所属的 ScrollingFrame，以便拖动滑块时临时锁定外层滚动
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
    -- 根据手指或鼠标的屏幕 X 坐标计算滑块对应数值并触发回调
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
            if not ok then warn("[FSY] 滑块回调失败: " .. tostring(err)) end
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
local function createDropdownRow(parent, labelText, descText, options, initialVal, callback, configKey)
    if type(options) == "table" and type(initialVal) == "function" then callback = initialVal; initialVal = options[1] end
    local selected = initialVal or options[1]
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.ClipsDescendants = false; row.Parent = parent
    local rl = Instance.new("UIListLayout"); rl.SortOrder = Enum.SortOrder.LayoutOrder; rl.Padding = UDim.new(0, 4); rl.Parent = row
    local header = Instance.new("Frame"); header.Size = UDim2.new(1, 0, 0, 42); header.BackgroundTransparency = 1; header.Parent = row
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = header
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -145, 1, 0); tf.BackgroundTransparency = 1; tf.BorderSizePixel = 0; tf.Parent = header
    local tl = Instance.new("TextLabel"); tl.Size = UDim2.new(1, 0, 0, 18); tl.Position = UDim2.new(0, 0, 0, 4); tl.BackgroundTransparency = 1; tl.Font = Enum.Font.GothamBold; tl.Text = labelText; tl.TextColor3 = Colors.TextWhite; tl.TextSize = 12; tl.TextXAlignment = Enum.TextXAlignment.Left; tl.TextTruncate = Enum.TextTruncate.AtEnd; tl.Parent = tf
    local dl = Instance.new("TextLabel"); dl.Size = UDim2.new(1, 0, 0, 14); dl.Position = UDim2.new(0, 0, 0, 22); dl.BackgroundTransparency = 1; dl.Font = Enum.Font.Gotham; dl.Text = descText or ""; dl.TextColor3 = Colors.TextMuted; dl.TextSize = 10; dl.TextXAlignment = Enum.TextXAlignment.Left; dl.TextTruncate = Enum.TextTruncate.AtEnd; dl.Parent = tf
    local ddBtn = Instance.new("TextButton"); ddBtn.Size = UDim2.new(0, 130, 0, 24); ddBtn.Position = UDim2.new(1, -130, 0.5, -12); ddBtn.BackgroundColor3 = Colors.ControlBg; ddBtn.Font = Enum.Font.GothamBold; ddBtn.Text = tostring(selected) .. "  v"; ddBtn.TextColor3 = Colors.TextWhite; ddBtn.TextSize = 11; ddBtn.TextTruncate = Enum.TextTruncate.AtEnd; ddBtn.BorderSizePixel = 0; ddBtn.Parent = header
    Instance.new("UICorner", ddBtn).CornerRadius = UDim.new(0, 4)
    local ddStroke = Instance.new("UIStroke", ddBtn); ddStroke.Color = Colors.BorderSubtle; ddStroke.Thickness = 1
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
            ob.MouseEnter:Connect(function() if opt ~= selected then PlayQuickTween(ob, {BackgroundColor3 = Colors.RowHover}) end end)
            ob.MouseLeave:Connect(function() if opt ~= selected then PlayQuickTween(ob, {BackgroundColor3 = Colors.InputBg}) end end)
            BindClick(ob, function()
                selected = opt; ddBtn.Text = tostring(opt) .. "  v"; optC.Visible = false
                if currentlyOpenDropdown and currentlyOpenDropdown.optC == optC then currentlyOpenDropdown = nil end
                for oN, b in pairs(optButtons) do b.BackgroundColor3 = (oN == opt) and Colors.DropdownSelected or Colors.InputBg; b.TextColor3 = (oN == opt) and Colors.PurplePrimary or Colors.TextWhite; b.Text = (oN == opt and "> " or "   ") .. tostring(oN) end
                if type(callback) == "function" then callback(opt) end
            end)
        end
    end
    populate(options)
    RegisterThemeUpdater(function()
        for oN, b in pairs(optButtons) do
            if b and b.Parent then
                b.BackgroundColor3 = (oN == selected) and Colors.DropdownSelected or Colors.InputBg
                b.TextColor3 = (oN == selected) and Colors.PurplePrimary or Colors.TextWhite
            end
        end
    end)
    local function closeThisDropdown()
        if optC and optC.Parent then
            optC.Visible = false
            ddBtn.Text = tostring(selected) .. "  v"
        end
    end
    BindClick(ddBtn, function()
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
    header.MouseEnter:Connect(function() PlayQuickTween(row, {BackgroundColor3 = Colors.RowHover}) end)
    header.MouseLeave:Connect(function() PlayQuickTween(row, {BackgroundColor3 = Colors.RowNormal}) end)
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

-- 创建带右侧操作按钮的功能行组件（遵循图3规范：按钮采用主题色底 + 纯白文字）
local function createButtonRow(parent, labelText, descText, btnText, callback)
    if type(descText) == "function" then callback = descText; btnText = "执行"; descText = "" elseif type(btnText) == "function" then callback = btnText; btnText = descText; descText = "" end
    local row = createBaseRow(parent, labelText, descText)
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.PurpleAccent; btn.Font = Enum.Font.GothamBold; btn.Text = btnText or "执行"; btn.TextColor3 = Colors.TextWhite; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    RegisterThemeUpdater(function() btn.BackgroundColor3 = Colors.PurpleAccent end)
    btn.MouseEnter:Connect(function() PlayQuickTween(btn, {BackgroundColor3 = Colors.PurpleDark}) end)
    btn.MouseLeave:Connect(function() PlayQuickTween(btn, {BackgroundColor3 = Colors.PurpleAccent}) end)
    BindClick(btn, function() if type(callback) == "function" then pcall(callback) end end)
    return btn
end

-- 创建只读键值对信息展示行组件
local function createInfoRow(parent, labelText, valueText)
    local row = createBaseRow(parent, labelText, "")
    local vl = Instance.new("TextLabel"); vl.Size = UDim2.new(0, 160, 1, 0); vl.Position = UDim2.new(1, -160, 0, 0); vl.BackgroundTransparency = 1; vl.Font = Enum.Font.GothamBold; vl.Text = valueText; vl.TextColor3 = Colors.TextWhite; vl.TextSize = 11; vl.TextXAlignment = Enum.TextXAlignment.Right; vl.TextTruncate = Enum.TextTruncate.AtEnd; vl.Parent = row
    return {frame = row, Set = function(nv) vl.Text = nv end}
end

local tabDashboard = CreateTab("仪表盘")
local tabFishing   = CreateTab("钓鱼")
local tabBoss      = CreateTab("Boss")
local tabGod       = CreateTab("神灵")
local tabQuests    = CreateTab("任务")
local tabTeleports = CreateTab("传送")
local tabVisuals   = CreateTab("视觉")
local tabPlayer    = CreateTab("移动")
local tabProfiles  = CreateTab("配置文件")

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

-- 创建仪表盘页面的水平三列卡片行容器
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

-- 创建仪表盘单个统计指标卡片并返回其数值 TextLabel
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

    card.MouseEnter:Connect(function()
        PlayQuickTween(card, {BackgroundColor3 = Colors.RowHover})
        PlayQuickTween(stroke, {Color = Colors.PurpleAccent, Transparency = 0.1})
    end)
    card.MouseLeave:Connect(function()
        PlayQuickTween(card, {BackgroundColor3 = Colors.RowNormal})
        PlayQuickTween(stroke, {Color = Colors.BorderSubtle, Transparency = 0.35})
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
DashUI.lblRod = CreateDashCard(row1, "当前鱼竿", "🎣", Colors.TextWhite)
DashUI.lblBait = CreateDashCard(row1, "当前鱼饵", "🪱", Colors.AccentOrange)
DashUI.lblPos = CreateDashCard(row1, "当前位置", "📍", Colors.AccentBlue)

local row2 = CreateDashRow()
DashUI.lblHangTime = CreateDashCard(row2, "挂机时长", "⏳", Colors.AccentYellow)
DashUI.lblTotalFish = CreateDashCard(row2, "总钓获", "🐟", Colors.TextWhite)
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
local lblEmpty1 = CreateDashCard(row5, "版本", "✨", Colors.PurplePrimary)
lblEmpty1.Text = "FSY V1.8"
RegisterThemeUpdater(function() lblEmpty1.TextColor3 = Colors.PurplePrimary end)
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
local statsCard = createCollapsibleGroup(tabFishing, "实时账户与钓鱼统计")
DashUI.infoEquippedRod = createInfoRow(statsCard, "已装备鱼竿", "无")
DashUI.infoEquippedBait = createInfoRow(statsCard, "已装备鱼饵", "无")
DashUI.infoFishCaught = createInfoRow(statsCard, "总捕获鱼数", "0")
DashUI.infoCash = createInfoRow(statsCard, "当前现金", "$0")

local fishCard = createCollapsibleGroup(tabFishing, "核心钓鱼自动化")
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
local skillDrawer = createDrawerCapsule(fishCard, "技能轮换细项配置 (Z/X/C/V 与顺序、间隔)", "点击展开：勾选要释放的技能、设置释放顺序与间隔", false)
createToggleRow(skillDrawer, "使用技能 Z", "勾选后才会释放 Z 技能", Config.SkillZ, function(v) Config.SkillZ = v; currentSkillIndex = 1 end, "SkillZ")
createToggleRow(skillDrawer, "使用技能 X", "勾选后才会释放 X 技能", Config.SkillX, function(v) Config.SkillX = v; currentSkillIndex = 1 end, "SkillX")
createToggleRow(skillDrawer, "使用技能 C", "勾选后才会释放 C 技能", Config.SkillC, function(v) Config.SkillC = v; currentSkillIndex = 1 end, "SkillC")
createToggleRow(skillDrawer, "使用技能 V", "勾选后才会释放 V 技能", Config.SkillV, function(v) Config.SkillV = v; currentSkillIndex = 1 end, "SkillV")

do
    local orderRow = createBaseRow(skillDrawer, "技能释放顺序", "标准顺序为 Z,X,C,V（每次进小游戏固定从第1个起手）")
    local orderBox = Instance.new("TextBox")
    orderBox.Size = UDim2.new(0, 130, 0, 24)
    orderBox.Position = UDim2.new(1, -130, 0.5, -12)
    orderBox.BackgroundColor3 = Colors.ControlBg
    orderBox.Font = Enum.Font.GothamBold
    orderBox.Text = Config.SkillOrder or "Z,X,C,V"
    orderBox.PlaceholderText = "Z,X,C,V"
    orderBox.TextColor3 = Colors.TextWhite
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

createSliderRow(skillDrawer, "技能间隔", "技能释放间隔（建议 1.2~1.5 秒打满伤害，防伤害不足超时）", 0.5, 5.0, Config.SkillInterval, true, "秒", function(v) Config.SkillInterval = v end, "SkillInterval")
createToggleRow(fishCard, "自动猛击/暴击", "提示时自动点击猛击按钮造成巨大伤害", Config.AutoSlam, function(v) Config.AutoSlam = v end, "AutoSlam")
createToggleRow(fishCard, "自动充能耐久", "提示时自动充能鱼线耐久", Config.AutoCharge, function(v) Config.AutoCharge = v end, "AutoCharge")

end -- end of fishCard

do
local equipCard = createCollapsibleGroup(tabFishing, "智能自动装备引擎")
createToggleRow(equipCard, "自动装备最佳鱼饵", "装备背包中运气最高的鱼饵", Config.AutoEquipBestBait, function(v) Config.AutoEquipBestBait = v end, "AutoEquipBestBait")
createToggleRow(equipCard, "自动装备最佳鱼竿", "装备你拥有的最高威力鱼竿", Config.AutoEquipBestRod, function(v) Config.AutoEquipBestRod = v end, "AutoEquipBestRod")
createToggleRow(equipCard, "自动装备最佳宝珠", "装备最高等级精华宝珠", Config.AutoEquipBestOrb, function(v) Config.AutoEquipBestOrb = v end, "AutoEquipBestOrb")

local rodNameList = {}
for _, r in ipairs(allRods) do table.insert(rodNameList, r.name) end
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait"}

local loadout1Drawer = createDrawerCapsule(equipCard, "预设配装方案 #1 (鱼竿/鱼饵快速切换)", "点击展开：选择方案1鱼竿、鱼饵并一键装备", false)
createDropdownRow(loadout1Drawer, "方案1：鱼竿", "方案1的鱼竿", rodNameList, Config.Loadout1_Rod, function(v) Config.Loadout1_Rod = v end, "Loadout1_Rod")
createDropdownRow(loadout1Drawer, "方案1：鱼饵", "方案1的鱼饵", baitNameList, Config.Loadout1_Bait, function(v) Config.Loadout1_Bait = v end, "Loadout1_Bait")
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
            local ownedObj = rFolder and rFolder:FindFirstChild("Owned")
            -- 【v20 修复】Owned 若不是 ValueBase（例如用 Folder 当"已拥有"标记）时，.Value 会直接报错被 pcall 吞掉
            local isOwned = ownedObj and (not ownedObj:IsA("ValueBase") or ownedObj.Value == true)
            if isOwned then
                local equipRodRem = Events and Events:FindFirstChild("EquipFishingRod")
                if equipRodRem then
                    pcall(function() equipRodRem:InvokeServer(rodName) end)
                    ShowNotification(slotLabel, "已装备鱼竿: " .. tostring(rodName), "SUCCESS")
                else
                    -- 【v20 修复】找不到装备接口时不再谎报"已装备"（用户感知为"点了没反应却提示成功"）
                    ShowNotification(slotLabel, "未找到装备鱼竿接口，已跳过鱼竿装备。", "WARN")
                end
            else
                ShowNotification(slotLabel, "你还没有拥有 " .. tostring(rodName) .. " ！", "WARN")
            end
            local baitInv = pData:FindFirstChild("Bait")
            local bFolder = baitInv and baitInv:FindFirstChild(baitName)
            local bQty = 0
            if bFolder then
                if bFolder:IsA("ValueBase") then
                    bQty = tonumber(bFolder.Value) or 0
                else
                    -- 【v20 修复】兼容"Bait 条目是 Folder、数量在 Quantity 子节点"的背包结构：
                    -- 旧代码 tonumber(bFolder.Value) 会直接报错并被外层 pcall 静默吞掉，按钮看起来完全没反应。
                    local qObj = bFolder:FindFirstChild("Quantity")
                    if qObj and qObj:IsA("ValueBase") then bQty = tonumber(qObj.Value) or 0 end
                end
            end
            if bQty > 0 then
                local equipBaitRem = Events and Events:FindFirstChild("EquipBait")
                if equipBaitRem then
                    pcall(function() equipBaitRem:InvokeServer(baitName) end)
                    ShowNotification(slotLabel, "已装备鱼饵: " .. tostring(baitName), "SUCCESS")
                else
                    ShowNotification(slotLabel, "未找到装备鱼饵接口，已跳过鱼饵装备。", "WARN")
                end
            else
                ShowNotification(slotLabel, "你的背包中 " .. tostring(baitName) .. " 数量为0。", "WARN")
            end
        end)
    end)
end

createButtonRow(loadout1Drawer, "立即装备方案1", "装备方案1选择的鱼竿和鱼饵", "装备#1", function()
    EquipLoadoutAction("方案1", Config.Loadout1_Rod, Config.Loadout1_Bait)
end)

local loadout2Drawer = createDrawerCapsule(equipCard, "预设配装方案 #2 (鱼竿/鱼饵快速切换)", "点击展开：选择方案2鱼竿、鱼饵并一键装备", false)
createDropdownRow(loadout2Drawer, "方案2：鱼竿", "方案2的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end, "Loadout2_Rod")
createDropdownRow(loadout2Drawer, "方案2：鱼饵", "方案2的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end, "Loadout2_Bait")
createButtonRow(loadout2Drawer, "立即装备方案2", "装备方案2选择的鱼竿和鱼饵", "装备#2", function()
    EquipLoadoutAction("方案2", Config.Loadout2_Rod, Config.Loadout2_Bait)
end)

end -- end of equipCard scope

-- ============================================================================
-- 【模块 15：黑名单防误卖保护引擎、单次防翻转上锁与安全卖鱼系统 (SafeSellAllFish)】
-- 作用说明：
--   1. 支持精确名(=)、前缀(^)、后缀($)、通配符(*?)及全词边界物种匹配，自动剥离背包鱼名后的 " | 重量"、括号重量及全系变异前缀（100% 保护变异鱼）；
--   2. TryFavoriteProtectedFish() 对未上锁的保护鱼发送单次收藏请求，立即标记确权并按实例跟踪重建继承，严防无反馈时重复发送 Toggle 把已锁的鱼解开（彻底解决“变了一遍被卖掉”）；
--   3. SafeSellAllFish() 铁律保护：仅当背包内全部保护鱼均已上锁且度过服务端落锁窗口后才发送 SellFish("All")；若存在任何未完成上锁的保护鱼，严禁调用 SellFish。
-- 后续修改指引：
--   - 若需新增默认保护的材料鱼或稀有 Boss 鱼关键词，分别在 craftMaterialFish 或 rareBossKeywords 表中添加。
-- ============================================================================
do -- Fish Protection, Sell & Boss Scope
-- [寄存器优化] 将防误卖与自动上锁引擎的所有内部字典、缓存与辅助函数收敛至单一局部表 FG，
-- 彻底消除独立 local 变量占用，确保主块活跃局部变量远低于 Luau 200 寄存器硬上限！
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
        ["老虎鱼"] = "colossal tigerfish",
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
    mutationPrefixes = {
        "shiny ", "albino ", "cursed ", "blessed ", "giant ", "big ", "small ", "mutated ", "mutant ",
        "shadow ", "corrupted ", "spectral ", "void ", "abyssal ", "celestial ", "radiant ", "mythical ",
        "mythic ", "divine ", "ancient ", "heavenly ", "demonic ", "demon ", "blood ", "bloody ",
        "electric ", "lightning ", "thunder ", "flame ", "fire ", "infernal ", "frosty ", "frozen ",
        "icy ", "ice ", "glacial ", "poison ", "poisonous ", "toxic ", "venom ", "venomous ", "nuclear ",
        "radioactive ", "atomic ", "galactic ", "galaxy ", "cosmic ", "astral ", "lunar ", "solar ",
        "eclipse ", "phantom ", "ghost ", "ghostly ", "spirit ", "spiritual ", "soul ", "jade ",
        "emerald ", "ruby ", "sapphire ", "diamond ", "crystal ", "crystalline ", "amethyst ", "obsidian ",
        "amber ", "silver ", "platinum ", "titanium ", "neon ", "cyber ", "prism ", "prismatic ",
        "chromatic ", "light ", "holy ", "sacred ", "chaos ", "chaotic ", "taiji ", "enlightened ",
        "awakened ", "transcendent ", "immortal ", "eternal ", "gargantuan ", "titanic ", "mini ",
        "tiny ", "huge ", "massive ", "king ", "emperor ", "royal ", "imperial ", "legendary ",
        "闪光", "变异", "白化", "诅咒", "祝福", "巨大", "暗影", "腐化", "虚空", "深渊", "神圣",
        "雷电", "闪电", "火焰", "烈焰", "剧毒", "毒素", "核能", "辐射", "星空", "星辰", "幽灵",
        "翡翠", "红宝石", "蓝宝石", "钻石", "水晶", "紫水晶", "黑曜石", "白银", "铂金", "霓虹",
        "棱镜", "光明", "混沌", "太极", "觉醒", "仙品", "神品", "魔化", "血色", "狂暴"
    },
    favCheckNames = {
        "Favorite", "Favourite", "Locked", "Favorited", "Favourited", "IsFavorite", "IsFavourite", "IsLocked",
        "Fav", "Lock"
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
    lastAnyLockSentAt = 0,
    lockRetryAfter = setmetatable({}, { __mode = "k" }),
    lockFailCount = setmetatable({}, { __mode = "k" }),
    lockPipelineVerified = false,
    -- 按 "鱼名 | 重量" 记录已发包上锁的实例列表：当服务端因锁鱼销毁旧实例并插入同名新实例时，精准将已锁状态过户给新实例，
    -- 同时保证若背包里原本就有 2 条相同重量的同名鱼（旧实例仍存活在背包中），第 2 条鱼仍会正常上锁！
    lockedInstListByBase = {},
    normSpeciesCache = {},
    normSpeciesCacheCount = 0,
    isInternalFavCall = false,
    cachedInvGrids = {},
    lastInvGridSearchAt = 0,
    guiLockByExactName = {},
    guiLockByInstance = setmetatable({}, { __mode = "k" }),
    guiLockBySpeciesWeight = {},
    guiLockBySpeciesAll = {},
    lastGuiLockScanAt = 0,
}

-- 提取鱼实例的 "鱼名 | 重量" 基础标识（自动剥离末尾可能已存在的 "| Favorite" 或 "| Locked" 后缀，防止重复拼接）
function FG.GetItemBaseNameWithWeight(item)
    if not item then return "" end
    local raw = (typeof(item) == "Instance") and tostring(item.Name) or tostring(item)
    local stripped = raw:gsub("%s*|%s*[Ff][Aa][Vv][Oo][Uu]?[Rr][Ii][Tt][Ee][Dd]?%s*$", "")
                        :gsub("%s*|%s*[Ll][Oo][Cc][Kk][Ee]?[Dd]?%s*$", "")
    stripped = stripped:match("^%s*(.-)%s*$") or raw
    if typeof(item) == "Instance" and not stripped:find("|", 1, true) then
        local w = FG.ExtractItemWeightKg and FG.ExtractItemWeightKg(item) or nil
        if w and w > 0 then
            return stripped .. " | " .. tostring(w)
        end
    end
    return stripped
end

-- 记录某条鱼实例已完成单次上锁发包，加入对应 "鱼名 | 重量" 的实例追踪列表
function FG.RegisterLockedInstance(item, sentTime)
    if not item or typeof(item) ~= "Instance" then return end
    sentTime = sentTime or tick()
    FG.lockConfirmedOrSent[item] = true
    FG.lastLockSentAt[item] = sentTime
    local baseKey = FG.GetItemBaseNameWithWeight(item)
    if baseKey ~= "" and baseKey:find("|", 1, true) then
        local list = FG.lockedInstListByBase[baseKey]
        if not list then
            list = {}
            FG.lockedInstListByBase[baseKey] = list
        end
        for i = 1, #list do
            if list[i].inst == item then
                list[i].sentAt = sentTime
                return
            end
        end
        table.insert(list, { inst = item, sentAt = sentTime })
    end
end

-- 移除某条鱼实例的已上锁追踪记录（供超时明确未锁补发或玩家手动解锁时调用）
function FG.UnregisterLockedInstance(item)
    if not item then return end
    FG.lockConfirmedOrSent[item] = nil
    local baseKey = FG.GetItemBaseNameWithWeight(item)
    local list = baseKey ~= "" and FG.lockedInstListByBase[baseKey] or nil
    if list then
        for i = #list, 1, -1 do
            if list[i].inst == item then
                table.remove(list, i)
            end
        end
    end
end

-- 检查新实例是否为服务端在锁鱼时销毁旧同名实例后原位重建的实例：
-- 仅当列表中存在已脱离父节点 (oldInst.Parent == nil) 的同名同重量记录时才过户继承锁状态，
-- 若旧实例仍存活在背包中（说明是第 2 条同重量重复鱼），绝不误判为已锁！
function FG.ClaimDestroyedLockInheritance(item)
    if not item or typeof(item) ~= "Instance" then return false end
    if FG.lockConfirmedOrSent[item] then return true end
    local baseKey = FG.GetItemBaseNameWithWeight(item)
    if baseKey == "" or not baseKey:find("|", 1, true) then return false end
    local list = FG.lockedInstListByBase[baseKey]
    if not list then return false end
    for i = 1, #list do
        local entry = list[i]
        if entry.inst == item then
            FG.lockConfirmedOrSent[item] = true
            if not FG.lastLockSentAt[item] then FG.lastLockSentAt[item] = entry.sentAt end
            return true
        elseif not entry.inst or entry.inst.Parent == nil then
            -- 旧实例已被服务端销毁，将锁确权状态无缝过户给当前重建的新实例
            entry.inst = item
            FG.lockConfirmedOrSent[item] = true
            FG.lastLockSentAt[item] = entry.sentAt
            return true
        else
            -- 无显式 Favorite 子字段时，服务端按 "鱼名 | 重量" 字符串寻址：同一 "鱼名 | 重量" 绝不重复发第 2 次相同字符串包，防止把第 1 条同重量的鱼翻转解锁！
            FG.lockConfirmedOrSent[item] = true
            if not FG.lastLockSentAt[item] then FG.lastLockSentAt[item] = entry.sentAt end
            return true
        end
    end
    return false
end

-- 提取纯鱼名：自动剥离 " | 1849724.37"、" | Favorite"、括号重量 "(1.4M KG)" 以及方括号变异标签 "[Shiny]"
function FG.GetPureFishName(rawName)
    if not rawName then return "" end
    local s = (typeof(rawName) == "Instance") and rawName.Name or tostring(rawName)
    local cached = FG.pureNameCache[s]
    if cached then return cached end
    local beforePipe = s:match("^(.-)%s*|")
    local res = (beforePipe and #beforePipe > 0) and beforePipe or s
    -- 剥离末尾括号中的重量或状态描述，如 "Wraith Orca (1.4M KG)" 或 "巨型老虎鱼 (5.95 吨)"
    res = res:gsub("%s*%([^%(%)]*[%d%.]+[^%(%)]*%)%s*$", "")
    -- 剥离方括号或书名号变异前缀/后缀，如 "[Shiny] Colossal Tigerfish"、"【变异】巨型老虎鱼"
    res = res:gsub("^%s*%[[^%[%]]+%]%s*", ""):gsub("%s*%[[^%[%]]+%]%s*$", "")
    res = res:gsub("^%s*【[^【】]+】%s*", ""):gsub("%s*【[^【】]+】%s*$", "")
    res = res:match("^%s*(.-)%s*$") or ""
    if FG.pureNameCacheCount >= 512 then
        table.clear(FG.pureNameCache)
        FG.pureNameCacheCount = 0
    end
    FG.pureNameCache[s] = res
    FG.pureNameCacheCount = FG.pureNameCacheCount + 1
    return res
end

-- 判定属性值或字符串是否代表“已上锁/已收藏”真值
function FG.IsTruthyLockValue(v)
    if v == true or v == 1 then return true end
    if type(v) == "string" then
        local low = v:lower():match("^%s*(.-)%s*$")
        if low:find("unfav", 1, true) or low:find("unlock", 1, true) then return false end
        return low == "true" or low == "1" or low == "yes" or low == "locked"
            or low == "favorited" or low == "favourited" or low == "favorite" or low == "favourite"
            or low == "lock" or low == "fav"
    end
    return false
end

-- 数据层判锁专用关键词：仅认 fav / lock / 锁 / 收藏，杜绝无关属性误判
function FG.HasFavLockKeyword(str)
    if type(str) ~= "string" or str == "" then return false end
    local kLow = str:lower()
    return kLow:find("fav", 1, true) ~= nil or kLow:find("lock", 1, true) ~= nil
        or kLow:find("锁", 1, true) ~= nil or kLow:find("收藏", 1, true) ~= nil
end

-- 规范化鱼种名称（自动剥离重量与变异词缀并映射中文别名到英文小写，带 512 条 LRU 缓存）
function FG.NormalizeFishSpeciesLower(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return "" end
    local cached = FG.normSpeciesCache[rawStr]
    if cached then return cached end
    local pure = FG.GetPureFishName(rawStr)
    local strippedPure = FG.StripFishMutationPrefix and FG.StripFishMutationPrefix(pure:lower()) or pure:lower()
    local mapped = FG.cnFishAliasMap[pure] or FG.cnFishAliasMap[strippedPure]
    if not mapped then
        for cnKey, enVal in pairs(FG.cnFishAliasMap) do
            if pure:find(cnKey, 1, true) or rawStr:find(cnKey, 1, true) then
                mapped = enVal
                break
            end
        end
    end
    local res = (mapped or strippedPure or pure):lower():match("^%s*(.-)%s*$")
    if FG.normSpeciesCacheCount >= 512 then
        table.clear(FG.normSpeciesCache)
        FG.normSpeciesCacheCount = 0
    end
    FG.normSpeciesCache[rawStr] = res
    FG.normSpeciesCacheCount = FG.normSpeciesCacheCount + 1
    return res
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

-- 检测单个库存 UI 槽位卡片左上角锁头图标的显式状态（仅在卡片已实际渲染或具备显式锁属性/锁名子节点时判定，避免背包关闭时误判）
function FG.InspectCardPadlockState(card)
    if not card or not card:IsA("GuiObject") then return nil end
    local favNames = FG.favCheckNames
    for i = 1, #favNames do
        local attrVal = card:GetAttribute(favNames[i])
        if attrVal ~= nil then
            return FG.IsTruthyLockValue(attrVal)
        end
        local chVal = card:FindFirstChild(favNames[i])
        if chVal and chVal:IsA("ValueBase") then
            return FG.IsTruthyLockValue(chVal.Value)
        end
    end
    local cardAbsW, cardAbsH = card.AbsoluteSize.X, card.AbsoluteSize.Y
    local cardAbsX, cardAbsY = card.AbsolutePosition.X, card.AbsolutePosition.Y
    local isCardRendered = (card.Visible ~= false and cardAbsW > 20 and cardAbsH > 20)
    local foundAnyPadlock = false
    local foundWhiteLocked = false
    for _, d in ipairs(card:GetDescendants()) do
        if (d:IsA("ImageButton") or d:IsA("ImageLabel")) and d ~= card then
            local hasExplicitLockName = FG.HasFavLockKeyword(d.Name) or (d.Parent and d.Parent ~= card and FG.HasFavLockKeyword(d.Parent.Name))
            local isPadlockCandidate = false
            if hasExplicitLockName then
                isPadlockCandidate = true
            elseif isCardRendered and d.AbsoluteSize.X > 4 and d.AbsoluteSize.Y > 4 then
                local relW = d.AbsoluteSize.X / cardAbsW
                local relH = d.AbsoluteSize.Y / cardAbsH
                local relX = (d.AbsolutePosition.X - cardAbsX) / cardAbsW
                local relY = (d.AbsolutePosition.Y - cardAbsY) / cardAbsH
                if relW <= 0.36 and relH <= 0.36 and relX >= -0.05 and relX <= 0.32 and relY >= -0.05 and relY <= 0.32 then
                    isPadlockCandidate = true
                end
            end
            if isPadlockCandidate and d.Visible ~= false and d.Image ~= "" then
                foundAnyPadlock = true
                local col = d.ImageColor3
                local trans = d.ImageTransparency
                if trans <= 0.22 and col.R >= 0.78 and col.G >= 0.78 and col.B >= 0.78 then
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

-- 判断游戏背包网格当前是否正打开并渲染在屏幕上
function FG.IsInventoryGridVisibleOnScreen()
    for i = 1, #FG.cachedInvGrids do
        local g = FG.cachedInvGrids[i]
        if g and g.Parent and g.Visible and g.AbsoluteSize.X > 40 and g.AbsoluteSize.Y > 40 then
            local sg = g:FindFirstAncestorOfClass("ScreenGui")
            if not sg or sg.Enabled then
                return true
            end
        end
    end
    return false
end

-- 刷新并缓存游戏原生库存 UI (MainGui) 中各鱼槽位的白锁/灰锁状态（0.25s 节流，支持同名多卡计数而不互相覆盖）
function FG.RefreshGuiLockCache(now, force)
    now = now or tick()
    if not force and (now - FG.lastGuiLockScanAt) < 0.25 then return end
    FG.lastGuiLockScanAt = now

    table.clear(FG.guiLockByExactName)
    table.clear(FG.guiLockByInstance)
    table.clear(FG.guiLockBySpeciesWeight)
    table.clear(FG.guiLockBySpeciesAll)

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
        for _, card in ipairs(grid:GetChildren()) do
            if card:IsA("GuiObject") then
                local cNameLow = card.Name:lower()
                if cNameLow ~= "template" and not cNameLow:find("template", 1, true) then
                    local lockState = FG.InspectCardPadlockState(card)
                    if lockState ~= nil then
                        local exactStat = FG.guiLockByExactName[card.Name]
                        if not exactStat then
                            exactStat = { locked = 0, unlocked = 0 }
                            FG.guiLockByExactName[card.Name] = exactStat
                        end
                        if lockState then
                            exactStat.locked = exactStat.locked + 1
                        else
                            exactStat.unlocked = exactStat.unlocked + 1
                        end
                        for _, ch in ipairs(card:GetChildren()) do
                            if ch:IsA("ObjectValue") and ch.Value then
                                FG.guiLockByInstance[ch.Value] = lockState
                            end
                        end
                        for _, d in ipairs(card:GetDescendants()) do
                            if d:IsA("TextLabel") and d.Text and d.Text:find("(", 1, true) then
                                local spLow, wKg, wTag = FG.ParseCardFishLabel(d.Text)
                                if spLow and spLow ~= "" then
                                    local stat = FG.guiLockBySpeciesAll[spLow]
                                    if not stat then
                                        stat = { total = 0, locked = 0 }
                                        FG.guiLockBySpeciesAll[spLow] = stat
                                    end
                                    stat.total = stat.total + 1
                                    if lockState then stat.locked = stat.locked + 1 end
                                    if wTag or wKg then
                                        local list = FG.guiLockBySpeciesWeight[spLow]
                                        if not list then
                                            list = {}
                                            FG.guiLockBySpeciesWeight[spLow] = list
                                        end
                                        table.insert(list, { weightTag = wTag, weightKg = wKg, locked = lockState })
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
end

-- 查询某条背包鱼实例在库存 UI 中的显式锁头状态（修复原 "bind" 模式死代码恒返回 nil 的问题，支持实例绑定、精确卡片名计数与同种同重量比对）
function FG.GetGuiSlotLockState(item, strictMode)
    if not item or typeof(item) ~= "Instance" then return nil end
    FG.RefreshGuiLockCache(tick(), false)
    local byInst = FG.guiLockByInstance[item]
    if byInst ~= nil then return byInst end

    local baseWithW = FG.GetItemBaseNameWithWeight(item)
    for _, keyCandidate in ipairs({item.Name, baseWithW, baseWithW .. " | Favorite"}) do
        if keyCandidate and keyCandidate ~= "" and keyCandidate:find("|", 1, true) then
            local exactStat = FG.guiLockByExactName[keyCandidate]
            if type(exactStat) == "table" and (exactStat.locked + exactStat.unlocked) > 0 then
                if exactStat.unlocked == 0 then
                    return true
                elseif exactStat.locked == 0 then
                    return false
                elseif strictMode then
                    return nil
                else
                    return FG.lockConfirmedOrSent[item] == true
                end
            end
        end
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
            else
                if strictMode then return nil end
                return FG.lockConfirmedOrSent[item] == true
            end
        end
    end

    if not strictMode then
        local stat = FG.guiLockBySpeciesAll[spLow]
        if stat and stat.total > 0 then
            if stat.locked >= stat.total then
                return true
            elseif stat.locked == 0 then
                return false
            else
                return FG.lockConfirmedOrSent[item] == true
            end
        end
    end
    return nil
end

-- 检查数据模型层（实例名 "| Favorite" 后缀 / 子节点 / 属性 / ValueBase / 父级收藏表）上锁状态
-- 返回两个值：isLocked (boolean), hasExplicitLockField (boolean)
function FG.GetFishItemDataLockState(item)
    if not item or typeof(item) ~= "Instance" then return false, false end
    -- 1. 检查实例名末尾是否带有 "| Favorite" 或 "| Locked"
    local rawName = tostring(item.Name or "")
    local lastSeg = rawName:match("|%s*([^|]+)%s*$")
    if lastSeg then
        local segLow = lastSeg:lower():match("^%s*(.-)%s*$")
        if (segLow:find("fav", 1, true) or segLow:find("lock", 1, true)) and not segLow:find("un", 1, true) then
            return true, true
        end
    end

    local hasExplicitField = false
    local favNames = FG.favCheckNames
    for i = 1, #favNames do
        local fav = item:FindFirstChild(favNames[i])
        if fav then
            hasExplicitField = true
            if fav:IsA("BoolValue") then
                if fav.Value == true then return true, true end
            elseif fav:IsA("IntValue") or fav:IsA("NumberValue") then
                if (tonumber(fav.Value) or 0) ~= 0 then return true, true end
            elseif fav:IsA("StringValue") then
                if fav.Value == "" or FG.IsTruthyLockValue(fav.Value) then return true, true end
            elseif fav:IsA("ValueBase") then
                if FG.IsTruthyLockValue(fav.Value) then return true, true end
            end
        end
    end
    for _, ch in ipairs(item:GetChildren()) do
        if ch:IsA("ValueBase") and FG.HasFavLockKeyword(ch.Name) then
            hasExplicitField = true
            if FG.IsTruthyLockValue(ch.Value) then
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
            if FG.HasFavLockKeyword(k) then
                hasExplicitField = true
                if FG.IsTruthyLockValue(v) then
                    return true, true
                end
            end
        end
    end
    if item:IsA("StringValue") and item.Value ~= "" and item.Value ~= "1" then
        if FG.IsTruthyLockValue(item.Value) then
            return true, true
        elseif item.Value:lower() == "false" or item.Value:lower():find("unfav", 1, true) or item.Value:lower():find("unlock", 1, true) then
            hasExplicitField = true
        end
    elseif item:IsA("BoolValue") then
        -- 仅当背包内存在 Value == false 的同类 BoolValue 时，才将 BoolValue.Value 视为锁状态字段（防止把“拥有=true”误判为“已锁=true”）
        local parentFolder = item.Parent
        local hasFalseSibling = false
        if parentFolder then
            for _, sib in ipairs(parentFolder:GetChildren()) do
                if sib:IsA("BoolValue") and sib.Value == false then
                    hasFalseSibling = true
                    break
                end
            end
        end
        if hasFalseSibling then
            hasExplicitField = true
            if item.Value == true then
                return true, true
            end
        end
    end
    local pData = item.Parent and item.Parent.Parent
    if pData then
        local baseWithW = FG.GetItemBaseNameWithWeight(item)
        local fFolders = FG.favFolderNames
        for i = 1, #fFolders do
            local ff = pData:FindFirstChild(fFolders[i])
            if ff then
                local entry = ff:FindFirstChild(item.Name) or (baseWithW ~= "" and ff:FindFirstChild(baseWithW))
                if entry then
                    hasExplicitField = true
                    if entry:IsA("ValueBase") then
                        if entry.Value == "" or FG.IsTruthyLockValue(entry.Value) then return true, true end
                    else
                        return true, true
                    end
                end
                if FG.IsTruthyLockValue(ff:GetAttribute(item.Name)) or (baseWithW ~= "" and FG.IsTruthyLockValue(ff:GetAttribute(baseWithW))) then
                    return true, true
                end
            end
        end
    end
    return false, hasExplicitField
end

-- 仅查询数据模型层是否已确认上锁
function FG.IsFishItemDataFavorited(item)
    local isLocked = FG.GetFishItemDataLockState(item)
    return isLocked
end

-- 综合判定鱼实例是否已处于上锁保护状态（兼顾数据层、单次已发包防翻转标记、已销毁同名实例过户继承及打开状态的库存UI白锁检测）
function FG.IsFishItemFavorited(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked, hasExplicitField = FG.GetFishItemDataLockState(item)
    if dataLocked then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or tick())
        return true
    end
    if hasExplicitField then
        -- 数据层存在显式 Favorite 字段且当前为 false：仅在刚发包 1.8s 内视为在途，超时仍为 false 则允许补锁
        local sentAt = FG.lastLockSentAt[item] or 0
        if sentAt > 0 and (tick() - sentAt) < 1.8 then
            return true
        end
        FG.UnregisterLockedInstance(item)
        return false
    end
    -- 若服务端在锁鱼时销毁了旧实例并新建了同 "鱼名 | 重量" 的新实例，精准过户继承已上锁标记，绝不触发第二次 Toggle 解锁！
    FG.ClaimDestroyedLockInheritance(item)

    if FG.lockConfirmedOrSent[item] then
        -- 若背包界面当前正打开在屏幕上，且明确看到该鱼卡片为灰锁（未锁），且距离上次发包已超过 2.5s，才清除标记允许补锁
        local sentAt = FG.lastLockSentAt[item] or 0
        if (tick() - sentAt) >= 2.5 and FG.IsInventoryGridVisibleOnScreen() then
            local uiStrict = FG.GetGuiSlotLockState(item, "strict")
            if uiStrict == false then
                FG.UnregisterLockedInstance(item)
                return false
            end
        end
        return true
    end
    -- 若背包界面正打开且该鱼卡片已明确显示白锁（例如脚本启动前玩家已手动锁好的鱼），直接登记已锁，绝不发包把它解开！
    if FG.IsInventoryGridVisibleOnScreen() then
        local uiStrict = FG.GetGuiSlotLockState(item, "strict")
        if uiStrict == true then
            FG.RegisterLockedInstance(item, tick() - 5.0)
            return true
        end
    end
    local sentAt = FG.lastLockSentAt[item] or 0
    if sentAt > 0 and (tick() - sentAt) < 1.8 then
        return true
    end
    return false
end

-- 严格“卖鱼安全”判定：仅当保护鱼已通过数据层确认或已发出单次上锁包且度过 2.0s 服务端落锁期后，才允许执行 SellFish("All")
function FG.IsFishItemSellSafe(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked, hasExplicit = FG.GetFishItemDataLockState(item)
    if dataLocked then return true end
    if hasExplicit then return false end

    FG.ClaimDestroyedLockInheritance(item)

    local now = tick()
    local sentAt = FG.lastLockSentAt[item] or 0
    -- 刚发出上锁包不足 2.0s 时视为服务端尚未落锁完成，严禁放行全卖
    if sentAt > 0 and (now - sentAt) < 2.0 then
        return false
    end

    if FG.IsInventoryGridVisibleOnScreen() then
        local uiStrict = FG.GetGuiSlotLockState(item, "strict")
        if uiStrict == false then return false end
        if uiStrict == true then return true end
    end

    if FG.lockConfirmedOrSent[item] then
        return true
    end
    return false
end

-- 检查背包或快捷栏中是否还存在未完成上锁确权的保护鱼
function FG.HasAnyUnsafeProtectedFishInBag(pData)
    pData = pData or GetPlayerData()
    if not pData then return true, nil end
    local bagNames = FG.bagFolderNames
    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                    if not FG.IsFishItemSellSafe(item) then
                        return true, FG.GetFishItemPrimaryPureName(item)
                    end
                end
            end
        end
    end
    return false, nil
end

-- 剥离鱼名开头的全系中英文变异修饰词前缀（保留 Golden Guardian / Golden Dragon / Rainbow Dragonfish 等原生鱼种名）
function FG.StripFishMutationPrefix(lowerName)
    if type(lowerName) ~= "string" or lowerName == "" then return "" end
    local s = lowerName:match("^%s*(.-)%s*$")
    s = s:gsub("^%s*%[[^%[%]]+%]%s*", ""):gsub("^%s*【[^【】]+】%s*", "")
    local prefixes = FG.mutationPrefixes
    local changed = true
    local guard = 0
    while changed and guard < 6 do
        changed = false
        guard = guard + 1
        for i = 1, #prefixes do
            local p = prefixes[i]
            if s:sub(1, #p) == p and #s > #p then
                if (p == "frost " or p == "冰霜") and (s:find("frost kingfish", 1, true) or s:find("frost queenfish", 1, true) or s:find("冰霜鱼", 1, true) or s:find("冰霜王", 1, true)) then
                    -- 保留原生冰霜鱼王/鱼后名称
                elseif (p == "spirit " or p == "幽灵") and (s:find("wraith orca", 1, true) or s:find("幽灵虎鲸", 1, true)) then
                    -- 保留原生幽灵虎鲸名称
                else
                    s = s:sub(#p + 1):match("^%s*(.-)%s*$")
                    changed = true
                    break
                end
            end
        end
    end
    if s:sub(1, 7) == "golden " and not s:find("golden guardian", 1, true) and not s:find("golden dragon", 1, true) then
        s = s:sub(8):match("^%s*(.-)%s*$")
    elseif s:sub(1, 8) == "rainbow " and not s:find("rainbow dragon", 1, true) then
        s = s:sub(9):match("^%s*(.-)%s*$")
    elseif s:sub(1, 5) == "dark " and not s:find("dark kingfish", 1, true) then
        s = s:sub(6):match("^%s*(.-)%s*$")
    elseif s:sub(1, 8) == "crimson " and not s:find("crimson catfish", 1, true) and not s:find("crimson electric", 1, true) then
        s = s:sub(9):match("^%s*(.-)%s*$")
    end
    return s
end

-- 判断鱼名是否匹配目标鱼种（支持全系未知变异词缀包裹匹配，同时隔离 Catfish/Crimson Catfish 与 Scarlet Fish/Elder Scarlet Fish）
function FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, targetLower)
    if not targetLower or targetLower == "" then return false end
    if pureLower == targetLower or (baseLower and baseLower == targetLower) or fullLower == targetLower then
        return true
    end
    -- 防跨物种误锁保护：选普通 Catfish 不误锁 Crimson Catfish；选普通 Scarlet Fish 不误锁 Elder Scarlet Fish
    if targetLower == "catfish" and (pureLower:find("crimson catfish", 1, true) or fullLower:find("crimson catfish", 1, true)) then
        return false
    end
    if targetLower == "scarlet fish" and (pureLower:find("elder scarlet fish", 1, true) or fullLower:find("elder scarlet fish", 1, true)) then
        return false
    end
    if targetLower == "kingfish" and (pureLower:find("frost kingfish", 1, true) or pureLower:find("dark kingfish", 1, true)) then
        return false
    end
    if targetLower == "dragonfish" and pureLower:find("rainbow dragonfish", 1, true) then
        return false
    end
    -- 全词边界包含匹配：无论鱼名带有任何变异前缀/后缀（如 "Nuclear Colossal Tigerfish"、"Colossal Tigerfish [Mutated]"），均 100% 命中保护！
    local escaped = targetLower:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    if targetLower:find("^[%a%s%-']+$") then
        local wordPat = "%f[%a]" .. escaped .. "%f[%A]"
        if pureLower:find(wordPat) ~= nil or (baseLower and baseLower:find(wordPat) ~= nil) or fullLower:find(wordPat) ~= nil then
            return true
        end
    else
        if pureLower:find(targetLower, 1, true) ~= nil or (baseLower and baseLower:find(targetLower, 1, true) ~= nil) or fullLower:find(targetLower, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- 编译通配符/前缀/后缀/精确/包含匹配器（支持中英文鱼名与全部变异词缀匹配）
function FG.BuildFishMatcher(patternStr)
    if not patternStr then return nil end
    local raw = tostring(patternStr):match("^%s*(.-)%s*$")
    local pipePrefix = raw:match("^(.-)%s*|")
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
    local bodyMapped = FG.cnFishAliasMap[body] or body
    local bodyClean = FG.StripFishMutationPrefix(bodyMapped:lower())

    local matcher
    -- 精确匹配模式（=鱼名）
    if mode == "exact" then
        matcher = function(pureLower, fullLower, baseLower)
            return pureLower == body or (baseLower and baseLower == body) or fullLower == body
        end
    -- 前缀匹配模式（^前缀）
    elseif mode == "prefix" then
        matcher = function(pureLower, fullLower)
            return pureLower:sub(1, #body) == body or fullLower:sub(1, #body) == body
        end
    -- 后缀匹配模式（后缀$）
    elseif mode == "suffix" then
        matcher = function(pureLower)
            return #pureLower >= #body and pureLower:sub(-#body) == body
        end
    -- 默认鱼种包含匹配模式（兼容全部变异鱼词缀）
    elseif mode == "contains" then
        matcher = function(pureLower, fullLower, baseLower)
            return FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, body)
                or (bodyClean ~= "" and bodyClean ~= body and FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, bodyClean))
        end
    -- 通配符匹配模式（* 与 ?）
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

-- 解析并缓存用户在「收藏/保护名单」中输入的逗号分隔规则列表
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

-- 判断鱼名字符串是否命中任何保护规则（含收藏目标、多选保护名单、变异鱼词缀、Boss稀有鱼及制饵材料鱼）
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
    local mappedBase = FG.cnFishAliasMap[baseLower]
    if mappedBase then baseLower = mappedBase:lower() end
    local fullLower = (rawStr .. " " .. pureName .. " " .. mapped .. " " .. baseLower):lower()
    if pureLower == "" then return false end

    if Config.MaterialFarming then
        if FG.craftMaterialFish[pureName] or FG.craftMaterialFish[mapped] then return true end
        for matName in pairs(FG.craftMaterialFish) do
            local matLow = matName:lower()
            if FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, matLow) then
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
    -- 无论用户开启了「自动收藏并防卖」还是「自动卖鱼」，只要选定了收藏目标或填写了保护名单，均严格纳入保护（含其全部变异体）
    if Config.FavouriteFishName and Config.FavouriteFishName ~= "" then
        local targetRaw = FG.GetPureFishName(Config.FavouriteFishName)
        local targetPure = FG.NormalizeFishSpeciesLower(targetRaw)
        local targetBase = FG.StripFishMutationPrefix(targetPure)
        if targetPure ~= "" and (FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, targetPure)
            or (targetBase ~= "" and FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, targetBase))) then
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

-- 获取背包鱼实例的主鱼种纯名（优先解析 item.Name，拒绝将浮点数重量或状态值误当作鱼名）
function FG.GetFishItemPrimaryPureName(item)
    if not item then return "" end
    if type(item) == "string" then return FG.GetPureFishName(item) end
    if typeof(item) ~= "Instance" then return "" end
    local cached = FG.itemPrimaryNameCache[item]
    if cached and cached.rawName == item.Name then
        return cached.pure
    end
    local resolved = nil
    local fromItemName = FG.GetPureFishName(item.Name)
    local nameLow = fromItemName:lower()
    -- 只要 item.Name 不是纯数字槽位号或通用占位名，直接以 item.Name 提取的鱼种名为准
    if fromItemName ~= "" and not fromItemName:match("^[%d%.]+$")
        and not nameLow:match("^slot%d*$") and not nameLow:match("^item_?%d*$")
        and not FG.IsTruthyLockValue(fromItemName) then
        resolved = fromItemName
    end
    if not resolved then
        local nameKeys = FG.fishNameChildKeys
        for i = 1, #nameKeys do
            local childName = nameKeys[i]
            local ch = item:FindFirstChild(childName)
            if ch and ch:IsA("ValueBase") and type(ch.Value) == "string" and ch.Value ~= "" then
                local p = FG.GetPureFishName(ch.Value)
                if p ~= "" and not p:match("^[%d%.]+$") and not FG.IsTruthyLockValue(p) then
                    resolved = p
                    break
                end
            end
            local attr = item:GetAttribute(childName)
            if type(attr) == "string" and attr ~= "" then
                local p = FG.GetPureFishName(attr)
                if p ~= "" and not p:match("^[%d%.]+$") and not FG.IsTruthyLockValue(p) then
                    resolved = p
                    break
                end
            end
        end
    end
    if not resolved and item:IsA("ValueBase") and type(item.Value) == "string" and item.Value ~= "" then
        local p = FG.GetPureFishName(item.Value)
        local pLow = p:lower()
        if p ~= "" and not p:match("^[%d%.]+$") and not FG.IsTruthyLockValue(p)
            and pLow ~= "false" and pLow ~= "none" and pLow ~= "normal" and pLow ~= "unfavorited" and pLow ~= "unlocked" then
            resolved = p
        end
    end
    resolved = resolved or fromItemName
    FG.itemPrimaryNameCache[item] = { rawName = item.Name, pure = resolved }
    return resolved
end

-- 判断背包实例是否为鱼竿/鱼饵/宝珠等非鱼类装备（防止误卖或误锁装备）
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

-- 综合判定某条背包鱼实例是否属于需要保护的目标鱼（检查实例名、子节点、属性及稀有度标签）
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

-- 查找并缓存游戏内的收藏/上锁远程事件（优先使用 Events.FavoriteItem）
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
        for _, ch in ipairs(Events:GetDescendants()) do
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

-- 判断鱼实例是否已受白锁保护
function FG.IsFishLockProtected(item)
    return FG.IsFishItemFavorited(item)
end

-- 内部安全调用收藏 Remote（自动置位 IdenticalInternalFavCall，确保 __namecall 钩子 100% 放行脚本自身发出的锁鱼包）
function FG.RawCallFavRemote(favRem, ...)
    if not favRem then return false end
    local args = {...}
    if favRem:IsA("RemoteEvent") then
        FG.isInternalFavCall = true
        if sharedEnv then sharedEnv.IdenticalInternalFavCall = true end
        local ok = pcall(function() favRem:FireServer(unpack(args)) end)
        FG.isInternalFavCall = false
        if sharedEnv then sharedEnv.IdenticalInternalFavCall = false end
        return ok
    elseif favRem:IsA("RemoteFunction") then
        local ok = pcall(function()
            task.spawn(function()
                FG.isInternalFavCall = true
                if sharedEnv then sharedEnv.IdenticalInternalFavCall = true end
                pcall(function() favRem:InvokeServer(unpack(args)) end)
                FG.isInternalFavCall = false
                if sharedEnv then sharedEnv.IdenticalInternalFavCall = false end
            end)
        end)
        return ok
    end
    return false
end

-- 按指定参数格式向服务端发送单次收藏请求（自动规范化 "鱼名 | 重量 | Favorite" 格式，防止重复拼接后缀）
function FG.FireFormatOnce(favRem, item, fmt)
    if not favRem or not item or typeof(item) ~= "Instance" then return false end
    if FG.GetFishItemDataLockState(item) then return true end
    local rLow = favRem.Name:lower()
    local act = rLow:find("lock", 1, true) and "Lock" or "Favorite"
    local baseWithW = FG.GetItemBaseNameWithWeight(item)
    if fmt == "name_favorite" then
        local suffix = " | Favorite"
        if sharedEnv and type(sharedEnv.IdenticalLearnedFavSuffix) == "string" then
            local learned = sharedEnv.IdenticalLearnedFavSuffix
            if learned ~= "" and #learned <= 24 and not learned:lower():find("un", 1, true) then
                suffix = learned
            end
        end
        return FG.RawCallFavRemote(favRem, baseWithW .. suffix)
    elseif fmt == "name" then
        return FG.RawCallFavRemote(favRem, baseWithW ~= "" and baseWithW or item.Name)
    elseif fmt == "instance" then
        return FG.RawCallFavRemote(favRem, item)
    elseif fmt == "pure_name" then
        local pure = FG.GetFishItemPrimaryPureName(item)
        return FG.RawCallFavRemote(favRem, (pure ~= "" and pure) or item.Name)
    elseif fmt == "action_instance" then
        return FG.RawCallFavRemote(favRem, act, item)
    elseif fmt == "action_name" then
        return FG.RawCallFavRemote(favRem, act, baseWithW ~= "" and baseWithW or item.Name)
    end
    return FG.RawCallFavRemote(favRem, baseWithW .. " | Favorite")
end

-- 构建上锁发包候选格式优先级列表（严格尊重用户在 UI 下拉框中选择的模式，默认置顶抓包确认的 name_favorite）
function FG.BuildCandidateFavFormats(modeOverride)
    local mode = modeOverride or Config.FavPacketMode or "鱼名+后缀(Name | Favorite)"
    local order = {}
    local seen = {}
    -- 向候选格式队列追加未重复的格式名称
    local function pushFmt(f)
        if f and not seen[f] then
            seen[f] = true
            table.insert(order, f)
        end
    end
    if mode == "仅完整鱼名(item.Name)" then
        pushFmt("name")
        pushFmt("name_favorite")
        pushFmt("instance")
    elseif mode == "仅实例对象(item)" then
        pushFmt("instance")
        pushFmt("name_favorite")
        pushFmt("name")
    elseif mode == "动作+鱼名(Favorite+Name)" then
        pushFmt("action_name")
        pushFmt("name_favorite")
        pushFmt("name")
        pushFmt("instance")
    else
        if sharedEnv and type(sharedEnv.IdenticalLearnedFavFormat) == "string" then
            pushFmt(sharedEnv.IdenticalLearnedFavFormat)
        end
        if FG.verifiedSmartFavFormat then
            pushFmt(FG.verifiedSmartFavFormat)
        end
        pushFmt("name_favorite")
        pushFmt("name")
        pushFmt("instance")
    end
    pushFmt("pure_name")
    pushFmt("action_instance")
    pushFmt("action_name")
    return order
end

-- 提示玩家当前鱼处于保护名单中，已拦截手动解锁请求
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

-- 供 __namecall 调用的防误解锁判定（脚本内部调用 100% 放行；玩家关闭保护手动解锁时同步清除已锁缓存）
function FG.IsFavToggleBlockedByHook(arg1, arg2)
    if FG.isInternalFavCall or (sharedEnv and sharedEnv.IdenticalInternalFavCall) then
        return false
    end
    local target = (typeof(arg1) == "Instance" and arg1) or (typeof(arg2) == "Instance" and arg2) or nil
    if not target and type(arg1) == "string" then
        local strippedArg = arg1:gsub("%s*|%s*[Ff][Aa][Vv][Oo][Uu]?[Rr][Ii][Tt][Ee][Dd]?%s*$", "")
                                :gsub("%s*|%s*[Ll][Oo][Cc][Kk][Ee]?[Dd]?%s*$", "")
        local pData = GetPlayerData()
        if pData then
            for _, fName in ipairs({"Inventory", "Hotbar"}) do
                local f = pData:FindFirstChild(fName)
                local found = f and (f:FindFirstChild(arg1) or (strippedArg ~= "" and f:FindFirstChild(strippedArg)))
                if found then target = found; break end
            end
        end
    end
    if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish) then
        -- 玩家已关闭自动收藏并手动点击解锁：同步清除该鱼的已锁缓存，以便后续重新开启保护时能正常补锁
        if target then
            FG.UnregisterLockedInstance(target)
        end
        return false
    end
    if target and FG.ShouldProtectFishItem(target) then
        if FG.IsFishItemFavorited(target) then
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
-- [单次防翻转上锁核心引擎] FG.ExecuteSingleLockNow：
--   根因修复说明：
--     旧版在发送上锁包后调用 WaitLockVisible(item, 2.0)，而在钓鱼期间背包界面关闭时，
--     GetGuiSlotLockState(item, "bind") 恒返回 nil 且数据层无显式 BoolValue 变化，导致 WaitLockVisible 恒返回 false；
--     随后旧版每隔 3 秒对同一条鱼重复发送第 2、3、4 次 Toggle 包，直接把刚锁上的鱼又解开（“变了一遍”），并在卖鱼时被直接卖掉！
--   新机制：
--     1. 对每条未上锁的保护鱼发送 1 次上锁包后，立即调用 `FG.RegisterLockedInstance(item, now)` 标记确权；
--     2. 钓鱼期间（背包未打开且无显式 false 字段时）绝不对同一条鱼发送第 2 次 Toggle 包，彻底杜绝“先锁后解”；
--     3. 仅当数据层存在显式 Favorite 字段且 1.8s 后仍为 false，或背包界面正打开且明确显示灰锁时，才切换备选格式补锁。
-- ============================================================================
function FG.ExecuteSingleLockNow(item, favRem)
    if not item or typeof(item) ~= "Instance" or not item.Parent then return false end
    if FG.IsNonFishEquipmentItem(item) or not FG.ShouldProtectFishItem(item) then return false end
    if FG.IsFishItemFavorited(item) then
        return false
    end
    local now = tick()
    if now < (FG.lockRetryAfter[item] or 0) then return false end
    favRem = favRem or FG.GetFavoriteRemote()
    if not favRem then return false end

    local candidates = FG.BuildCandidateFavFormats()
    local tryIdx = (FG.lockFailCount[item] or 0) + 1
    local fmt = FG.verifiedSmartFavFormat or candidates[math.clamp(tryIdx, 1, #candidates)] or "name_favorite"

    local sendOk = FG.FireFormatOnce(favRem, item, fmt)
    if not sendOk then return false end

    FG.lastAnyLockSentAt = now
    FG.lockingInFlight[item] = nil
    -- 关键修复：单次发包后立即登记实例已上锁确权，防止无显式字段回写时重复发送偶数次 Toggle 包把鱼解锁！
    FG.RegisterLockedInstance(item, now)

    task.spawn(function()
        task.wait(1.8)
        if not isRunning or not item or not item.Parent then return end
        local dataLocked, hasExplicitField = FG.GetFishItemDataLockState(item)
        if dataLocked then
            FG.lockPipelineVerified = true
            FG.verifiedSmartFavFormat = fmt
            FG.RegisterLockedInstance(item, now)
            FG.lockFailCount[item] = nil
            FG.lockRetryAfter[item] = nil
            return
        end
        -- 仅当存在显式数据字段且明确仍为 false，或玩家正打开背包界面且卡片明确为未锁灰锁时，才判定本次格式未生效并尝试下一候选格式
        local explicitlyStillUnlocked = false
        if hasExplicitField and not dataLocked then
            explicitlyStillUnlocked = true
        elseif not hasExplicitField and FG.IsInventoryGridVisibleOnScreen() then
            FG.RefreshGuiLockCache(tick(), true)
            if FG.GetGuiSlotLockState(item, "strict") == false then
                explicitlyStillUnlocked = true
            elseif FG.GetGuiSlotLockState(item, "strict") == true then
                FG.lockPipelineVerified = true
                FG.verifiedSmartFavFormat = fmt
                return
            end
        end
        if explicitlyStillUnlocked then
            local fails = (FG.lockFailCount[item] or 0) + 1
            FG.lockFailCount[item] = fails
            if fails < math.min(3, #candidates) then
                FG.UnregisterLockedInstance(item)
                FG.lockRetryAfter[item] = tick() + 1.5
            end
        end
    end)
    return true
end

-- 启动异步步进分批上锁工作协程（每条间隔 0.07s，每满 20/45 条呼吸停顿，突破服务端 50 包限流）
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
                        local favRem = Events and Events:FindFirstChild("FavoriteItem") or FG.GetFavoriteRemote()
                        if favRem and FG.ExecuteSingleLockNow(item, favRem) then
                            batchSent = batchSent + 1
                            if batchSent % 45 == 0 then
                                task.wait(1.0)
                                FG.RefreshGuiLockCache(tick(), true)
                            elseif batchSent % 20 == 0 then
                                task.wait(0.45)
                                FG.RefreshGuiLockCache(tick(), true)
                            else
                                task.wait(0.07)
                            end
                        else
                            task.wait(0.05)
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

-- 将单条未上锁的保护鱼加入异步步进上锁队列（带防重入与冷却检查）
function FG.TryLockSingleFishItem(item, favRem, now, forceResend)
    if not item or typeof(item) ~= "Instance" or FG.IsNonFishEquipmentItem(item) then
        return false, false
    end
    if FG.GetFishItemDataLockState(item) then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or tick())
        FG.lockingInFlight[item] = nil
        return false, false
    end
    if not forceResend and FG.IsFishItemFavorited(item) then
        FG.lockingInFlight[item] = nil
        return false, false
    end
    if not FG.ShouldProtectFishItem(item) then
        return false, false
    end
    if FG.inLockQueue[item] or FG.lockingInFlight[item] then
        return true, false
    end
    now = now or tick()
    if now < (FG.lockRetryAfter[item] or 0) then return true, false end
    local lastSent = FG.lastLockSentAt[item] or 0
    if (now - lastSent) < 1.8 then
        return true, false
    end

    FG.inLockQueue[item] = true
    table.insert(FG.pendingLockQueue, item)
    FG.StartBatchLockWorker()
    return true, true
end

-- 监听玩家背包 (Inventory / Hotbar) 新增鱼实例事件，钓上保护鱼瞬间立即触发单次上锁（同时自动过户服务端锁鱼重建的同名实例）
function FG.EnsureBagAutoLockListeners(pData)
    if not pData then return end
    for _, folderName in ipairs({"Inventory", "Hotbar"}) do
        local folder = pData:FindFirstChild(folderName)
        if folder and not watchedBagFolders[folder] then
            watchedBagFolders[folder] = true
            table.insert(activeConnections, folder.ChildAdded:Connect(function(newItem)
                if not isRunning then return end
                if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) then return end
                if FG.ClaimDestroyedLockInheritance(newItem) then
                    return
                end
                task.delay(0.15, function()
                    if not isRunning or not newItem or not newItem.Parent then return end
                    if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) then return end
                    if FG.ClaimDestroyedLockInheritance(newItem) then return end
                    local favRem = FG.GetFavoriteRemote()
                    FG.TryLockSingleFishItem(newItem, favRem, tick(), false)
                end)
            end))
        end
    end
end

-- 扫描 Inventory 与 Hotbar，将全部未上锁保护鱼排入步进分批队列
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
                    -- 仅当背包 UI 正在屏幕上打开且明确显示该鱼为灰锁（未锁）时，forceResendAll 才允许清除标记补锁，防止盲目重发把已锁鱼解开
                    if forceResendAll and not FG.IsFishItemDataFavorited(item) then
                        if FG.IsInventoryGridVisibleOnScreen() and FG.GetGuiSlotLockState(item, "strict") == false then
                            FG.UnregisterLockedInstance(item)
                        end
                    end
                    if not FG.IsFishItemFavorited(item) then
                        unfavProtectedCount = unfavProtectedCount + 1
                        local _, didQueue = FG.TryLockSingleFishItem(item, favRem, now, false)
                        if didQueue then
                            queuedCount = queuedCount + 1
                        end
                    end
                end
            end
        end
    end

    return unfavProtectedCount, queuedCount
end

-- 检查是否有正在执行的分批上锁队列或刚发出不足 2.0s 的上锁请求，防止上锁未落盘前抢先触发 SellFish
function FG.HasAnyLockSettlingInBag(pData)
    if FG.isBatchLockQueueRunning or #FG.pendingLockQueue > 0 then
        return true
    end
    local now = tick()
    if FG.lastAnyLockSentAt > 0 and (now - FG.lastAnyLockSentAt) < 2.0 then
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
                if sentAt and (now - sentAt) < 2.0 then
                    return true
                end
            end
        end
    end
    return false
end

-- 供 __namecall 与卖鱼模块调用的发包参数黑名单拦截器（包内存在未锁稳的保护鱼时一律拦截 SellFish）
function FG.IsSellPacketArgBlacklisted(arg)
    if arg == nil then
        local hasUnsafeProt = FG.HasAnyUnsafeProtectedFishInBag()
        if hasUnsafeProt then pcall(TryFavoriteProtectedFish, GetPlayerData(), false) end
        return hasUnsafeProt or FG.HasAnyLockSettlingInBag()
    end
    if type(arg) == "string" then
        local low = arg:lower():match("^%s*(.-)%s*$")
        if low == "" or low == "all" or low == "sellall" or low == "*" or low == "everything" or low == "inventory" then
            local hasUnsafeProt = FG.HasAnyUnsafeProtectedFishInBag()
            if hasUnsafeProt then pcall(TryFavoriteProtectedFish, GetPlayerData(), false) end
            return hasUnsafeProt or FG.HasAnyLockSettlingInBag()
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

-- 安全卖鱼主函数：先将背包内所有保护鱼单次上锁并等待 2.0s 服务端落锁确认，确认全部保护鱼安全后才发送 SellFish("All")；
-- 若存在任何未完成上锁的保护鱼，严禁调用 SellFish（彻底移除会触发服务端全卖未锁鱼的逐条降级分支），100% 杜绝误卖！
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

            -- 卖鱼前先扫描并将所有未上锁的保护鱼排入上锁队列
            FG.RefreshGuiLockCache(tick(), true)
            TryFavoriteProtectedFish(pData, false)

            local waitStart = tick()
            local maxWait = math.clamp(2.5 + (#FG.pendingLockQueue * 0.14), 2.5, 25.0)
            while isRunning and (tick() - waitStart < maxWait) do
                local settling = FG.HasAnyLockSettlingInBag(pData)
                if not settling then
                    if not FG.HasAnyUnsafeProtectedFishInBag(pData) then break end
                    if not FG.isBatchLockQueueRunning then pcall(TryFavoriteProtectedFish, pData, false) end
                end
                task.wait(0.15)
            end

            FG.RefreshGuiLockCache(tick(), true)
            if not isRunning then return end
            if not FG.HasAnyUnsafeProtectedFishInBag(pData) and not FG.HasAnyLockSettlingInBag(pData) then
                if sellRem:IsA("RemoteEvent") then
                    sellRem:FireServer("All")
                elseif sellRem:IsA("RemoteFunction") then
                    task.spawn(function()
                        pcall(function() sellRem:InvokeServer("All") end)
                    end)
                end
                ShowNotification("自动卖鱼", "已确认全部保护鱼锁定完毕，安全执行全卖普通鱼！", "SUCCESS", 2)
            else
                ShowNotification("防误卖保护", "检测到保护鱼正在同步锁定中，已延后本次出售，确保绝不误卖保护鱼！", "WARN", 2.5)
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

-- 获取任意 NPC 模型或零件的世界坐标（兼容流式卸载下的 GetBoundingBox / GetPivot）
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
-- 模拟点击屏幕 GuiButton（优先通过 getconnections 触发绑定回调，回退使用 firesignal）
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
-- 作用说明：
--   1. 构建自动卖鱼、自动收藏并防卖、收藏目标下拉自动追加多选名单、上锁发包模式切换及背包预览诊断按钮；
--   2. 构建无名章鱼隐藏 Boss 与恩佐/龙钓海 Boss 自动化挑战面板。
-- ============================================================================
do -- Economy & Sell UI Sub-Scope (独立 do-end 块及时释放 UI 局部寄存器)
local sellCard = createCollapsibleGroup(tabFishing, "经济与出售")
createToggleRow(sellCard, "自动卖鱼", "定期安全出售普通鱼（开启时自动联动启用锁鱼防卖，保护鱼绝不出售）", Config.AutoSell, function(v)
    Config.AutoSell = v
    if v then
        -- 开启自动卖鱼时自动联动开启「自动收藏并防卖」，避免玩家只开卖鱼忘开锁鱼导致保护鱼未上锁
        if not Config.AutoFavouriteFish then
            Config.AutoFavouriteFish = true
            if UIControls["AutoFavouriteFish"] and UIControls["AutoFavouriteFish"].Set then
                pcall(function() UIControls["AutoFavouriteFish"].Set(true, true) end)
            end
        end
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
-- 启动时自动扫描玩家当前背包与快捷栏中的鱼种并置顶加入下拉框，方便直接选择保护
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

createToggleRow(sellCard, "自动收藏并防卖", "打开后：对你选中的「收藏目标」及「保护名单」内的鱼（含一切变异体）自动上锁并防卖", Config.AutoFavouriteFish, function(v)
    Config.AutoFavouriteFish = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
        local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or ""
        if listStr == "" then
            ShowNotification("自动收藏已开启", string.format("当前保护鱼种: [%s]（含所有变异体）", tostring(Config.FavouriteFishName or "无")), "SUCCESS", 3)
        else
            ShowNotification("自动收藏已开启", string.format("当前保护目标: [%s] + 名单[%s]", tostring(Config.FavouriteFishName or ""), listStr), "SUCCESS", 3)
        end
    else
        table.clear(FG.pendingLockQueue)
        table.clear(FG.inLockQueue)
        ShowNotification("自动收藏已关闭", "已停止自动上锁，你现在可在游戏背包中自由手动解锁任意鱼类！", "INFO", 3)
    end
end, "AutoFavouriteFish")

local customFavBox = nil
-- 将指定鱼种自动合入 CustomProtectedFish 多选保护名单（若尚未存在），防止下拉切换新鱼时丢失之前选过的保护鱼
local function EnsureFishInProtectedList(fishName)
    local target = FG.GetPureFishName(fishName)
    if not target or target == "" then return false end
    local targetLow = target:lower()
    local cur = Config.CustomProtectedFish or ""
    local items = {}
    local exists = false
    for token in string.gmatch(cur, "([^,，;；\n\r]+)") do
        local trimmed = token:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            table.insert(items, trimmed)
            local cleanLow = FG.GetPureFishName(trimmed:gsub("^=", "")):lower()
            if cleanLow == targetLow then
                exists = true
            end
        end
    end
    if not exists then
        table.insert(items, target)
        Config.CustomProtectedFish = table.concat(items, ",")
        if customFavBox then customFavBox.Text = Config.CustomProtectedFish end
        return true
    end
    return false
end

-- 「收藏目标」下拉框：选中任意鱼种时自动将其追加进保护名单（之前选过的鱼同样保留受保护，不会因为换选另一条鱼而被卖掉！）
local favDropdownCtrl = createDropdownRow(sellCard, "收藏目标", "选中即自动加入保护名单（含变异鱼）；之前选过的鱼也会继续保留保护", baseFishList, Config.FavouriteFishName, function(v)
    Config.FavouriteFishName = v
    EnsureFishInProtectedList(v)
    local pData = GetPlayerData()
    if (Config.AutoFavouriteFish or Config.AutoSell or Config.AutoProtectRareBossFish or Config.MaterialFarming) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, pData, false)
    end
    local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or tostring(v)
    ShowNotification("已添加保护目标", string.format("当前选中: [%s]\n受保护总名单: %s", tostring(v), listStr), "SUCCESS", 3)
end, "FavouriteFishName")

createToggleRow(sellCard, "自动保护 Boss/神话稀有鱼", "可选：开启后按关键词/稀有度自动保护全部 Boss 与神话鱼", Config.AutoProtectRareBossFish, function(v)
    Config.AutoProtectRareBossFish = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "AutoProtectRareBossFish")
createToggleRow(sellCard, "材料收集模式", "可选：开启后自动保护制作神话鱼饵所需的 13 种材料鱼", Config.MaterialFarming, function(v)
    Config.MaterialFarming = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "MaterialFarming")

do
    local listRow = createBaseRow(sellCard, "收藏/保护名单", "可手改；支持 Wraith*、*Orca、=精确名、中文译名，逗号分隔")
    listRow.Size = UDim2.new(1, 0, 0, 56)
    customFavBox = Instance.new("TextBox")
    customFavBox.Size = UDim2.new(0, 220, 0, 40)
    customFavBox.Position = UDim2.new(1, -220, 0.5, -20)
    customFavBox.BackgroundColor3 = Colors.ControlBg
    customFavBox.Font = Enum.Font.GothamBold
    customFavBox.Text = Config.CustomProtectedFish or ""
    customFavBox.PlaceholderText = "例: Colossal Tigerfish, Wraith Orca"
    customFavBox.TextColor3 = Colors.TextWhite
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
        if (Config.AutoFavouriteFish or Config.AutoSell or Config.AutoProtectRareBossFish or Config.MaterialFarming) and TryFavoriteProtectedFish then
            TryFavoriteProtectedFish(pData, false)
        end
        ShowNotification("名单已更新", "已更新自定义多选保护名单！", "SUCCESS", 2.5)
    end)
    -- 同步自定义保护鱼名单文本到输入框控件
    UIControls["CustomProtectedFish"] = { Set = function(val) customFavBox.Text = tostring(val or "") end }
end

createDropdownRow(sellCard, "上锁发包模式", "默认使用抓包确认的「鱼名 | 重量 | Favorite」单次精确上锁", {
    "鱼名+后缀(Name | Favorite)",
    "仅完整鱼名(item.Name)",
    "仅实例对象(item)",
    "智能探测(自动对比状态)",
    "动作+鱼名(Favorite+Name)"
}, Config.FavPacketMode or "鱼名+后缀(Name | Favorite)", function(v)
    Config.FavPacketMode = v
    FG.verifiedSmartFavFormat = nil
    for k in pairs(FG.lockFailCount) do FG.lockFailCount[k] = nil end
    for k in pairs(FG.lockRetryAfter) do FG.lockRetryAfter[k] = nil end
    local pData = GetPlayerData()
    if pData and (Config.AutoFavouriteFish or Config.AutoSell or Config.AutoProtectRareBossFish or Config.MaterialFarming) and TryFavoriteProtectedFish then
        FG.RefreshGuiLockCache(tick(), true)
        local _, sentN = TryFavoriteProtectedFish(pData, false)
        ShowNotification("上锁模式已切换", string.format("当前模式: %s | 已将 %d 条未上锁保护鱼排入分批上锁队列！", tostring(v), sentN or 0), "SUCCESS", 3.5)
    else
        ShowNotification("上锁模式已切换", string.format("当前模式: %s", tostring(v)), "SUCCESS", 2.5)
    end
end, "FavPacketMode")

createButtonRow(sellCard, "立即收藏背包匹配鱼", "扫描背包，对未上锁的匹配保护鱼执行单次稳定上锁（已锁的鱼绝不重复触发解锁）", "立即收藏", function()
    local pData = GetPlayerData()
    if not pData then
        ShowNotification("收藏失败", "未读取到玩家数据", "WARN")
        return
    end
    FG.RefreshGuiLockCache(tick(), true)
    local favRem = FG.GetFavoriteRemote()
    local remName = favRem and favRem.Name or "未找到Remote"
    local unfavCount, queuedCount = TryFavoriteProtectedFish(pData, false)
    if (queuedCount or 0) == 0 and #FG.pendingLockQueue == 0 and FG.IsInventoryGridVisibleOnScreen() then
        -- 仅当背包打开且明确检测到灰锁未锁鱼时才执行补锁，杜绝盲目重发把已锁鱼翻转解开
        unfavCount, queuedCount = TryFavoriteProtectedFish(pData, true)
    end
    local qTotal = #FG.pendingLockQueue
    ShowNotification(
        "分批全量上锁已启动",
        string.format("新增入队: %d 条（队列待处理: %d 条，已锁保护鱼自动跳过防翻转）\n接口: %s | 模式: %s", queuedCount or unfavCount or 0, qTotal, remName, tostring(Config.FavPacketMode or "鱼名+后缀(Name | Favorite)")),
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
                if FG.ShouldProtectFishItem(it) then
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
    if Config.AutoFavouriteFish or Config.AutoSell or Config.AutoProtectRareBossFish or Config.MaterialFarming then
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
    -- 将鱼名数组截取前 6 项并拼接为简明预览摘要字符串
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
        local pData = GetPlayerData()
        if (Config.AutoFavouriteFish or Config.AutoSell or Config.AutoProtectRareBossFish or Config.MaterialFarming) and TryFavoriteProtectedFish then
            pcall(TryFavoriteProtectedFish, pData, false)
        end
        ShowNotification("已加入多选保护名单", string.format("已添加 [%s]（共 %d 种鱼受保护，再次点击可移除）！", target, #kept), "SUCCESS", 3)
    end
end)

createButtonRow(sellCard, "清空多选名单(仅留当前目标)", "一键清空多选名单，重置为仅保护上方下拉框当前选中的鱼种", "仅留当前", function()
    local target = FG.GetPureFishName(Config.FavouriteFishName) or ""
    Config.CustomProtectedFish = target
    if customFavBox then customFavBox.Text = target end
    ShowNotification("名单已重置", string.format("已重置保护名单，当前仅保护: [%s]", tostring(target)), "SUCCESS", 3)
end)

createButtonRow(sellCard, "[刷新] 扫描当前背包鱼类到下拉框", "读取背包和快捷栏现有鱼类(自动去除数字后缀ID与变异前缀)", "扫描背包", function()
    local pData = GetPlayerData()
    local merged = {}
    local seen = {}
    if pData then
        for _, folderName in ipairs({"Inventory", "Hotbar"}) do
            local f = pData:FindFirstChild(folderName)
            if f then
                for _, item in ipairs(f:GetChildren()) do
                    if not FG.IsNonFishEquipmentItem(item) then
                        local pure = FG.GetFishItemPrimaryPureName(item)
                        if pure ~= "" and not seen[pure] then
                            seen[pure] = true
                            table.insert(merged, pure)
                        end
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
local octoCard = createCollapsibleGroup(tabBoss, "无名章鱼寄生体(隐藏BOSS)")
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

local bossFarmCard = createCollapsibleGroup(tabBoss, "恩佐 龙钓海")
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
-- 13 大岛屿中心锚点（包含游戏内指南针全量 1~13 号岛屿）
local IslandCenters = {
    {id = 1,  name = "起始岛 (Beginning Isle)",              pos = Vector3.new(-200.7, 11.1, 35.9)},
    {id = 2,  name = "竹子岛 (Bamboo Isle)",                 pos = Vector3.new(-1223.0, 7.3, -24.1)},
    {id = 3,  name = "辐射岛 (Fallout Isle)",                pos = Vector3.new(65.5, 8.8, 1181.3)},
    {id = 4,  name = "主权岛屿 (Sovereign Isle)",            pos = Vector3.new(-1276.4, 8.8, 1239.7)},
    {id = 5,  name = "鲈鱼岛 (Perch Isle)",                  pos = Vector3.new(-62.0, 11.9, -1321.4)},
    {id = 6,  name = "冰霜岛 (Frost Isle)",                  pos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {id = 7,  name = "椰子岛 (Coconut Isle)",                pos = Vector3.new(1493.6, 9.1, -1430.6)},
    {id = 8,  name = "琥珀岛 (Amber Isle)",                  pos = Vector3.new(1259.4, 9.1, 1401.5)},
    {id = 9,  name = "战场岛 (Battlefield Isle)",            pos = Vector3.new(1393.5, 11.3, 169.6)},
    {id = 10, name = "迷雾山岛 (Mistpeak Isle)",             pos = Vector3.new(2660.2, 8.8, -86.7)},
    {id = 11, name = "世界钓鱼岛 (World Angler Isle)",        pos = Vector3.new(-2404.5, 7.6, -202.4)},
    {id = 12, name = "天气之岛 (Weather Isle)",              pos = Vector3.new(-2908.1, 6.8, 1191.2)},
    {id = 13, name = "神秘珊瑚礁岛 (Mysterious Coral Reef)",  pos = Vector3.new(-2648.0, 6.8, -1322.1)},
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
    {cnName = "票据任务员 (Quest Giver)", internalName = "Quest Giver", desc = "每日票据任务 (起始岛 [1] Easy / Hard 抽卡券任务)", aliases = {"Quest Giver", "QuestGiver", "TicketQuest", "Ticket NPC", "Ticket", "DailyQuest", "票据", "任务员", "每日票据"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "南江 (Nanjang / Nanjiang)", internalName = "Nanjang", desc = "抽特质 物品交换 (初始岛 [1] 技能特质重铸 / 洗练四圣兽)", aliases = {"Nanjang", "Nanjiang", "Nam Giang", "NamGiang", "TraitNPC", "Trait", "南江", "特质"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "初始岛楚依旧 (Sage Yiju)", internalName = "Sage Yiju", desc = "买技能 对话 (初始岛 [1] 基础 Cash 金币钓鱼技能商店)", aliases = {"Sage Yiju", "Sage Yijiu", "Chu Yijiu", "Sage Eiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者", "买技能", "技能商人"}, fallbackPos = Vector3.new(-117.5, 6.8, 41.2), preferPos = Vector3.new(-117.5, 6.8, 41.2), altPositions = {Vector3.new(-117.5, 6.8, 41.2), Vector3.new(-200.7, 11.1, 35.9)}},
    {cnName = "技能升级师 · 曾天国 (Skill Upgrades)", internalName = "Skill Upgrades", desc = "技能升级 (辐射岛 [3] 曾天国 · 消耗精华 Essences 强化技能)", aliases = {"曾天国", "技能升级", "Skill Upgrades", "Skill Upgrade", "SkillUpgrades", "UpgradeSkill", "Tăng Thiên Quốc", "Tang Thien Quoc", "Zeng Tian Guo", "Sheng Tian Guo"}, fallbackPos = Vector3.new(65.5, 8.8, 1181.3), preferPos = Vector3.new(65.5, 8.8, 1181.3), altPositions = {Vector3.new(65.5, 8.8, 1181.3), Vector3.new(138.4, 9.0, 1179.7), Vector3.new(-200.7, 11.1, 35.9)}},
    {cnName = "世界表弟 (Biao Di)", internalName = "Biao Di", desc = "主线 任务 对话 (鱼竿商店 / 神话竿合成 / 世界钓鱼岛主线)", aliases = {"Biao Di", "BiaoDi", "Biểu Đệ", "Bieu De", "Rod Seller", "RodDealer", "比奥迪", "表弟", "标迪"}, fallbackPos = Vector3.new(-151.4, 8.7, -49.9), altPositions = {Vector3.new(-151.4, 8.7, -49.9), Vector3.new(-2404.5, 7.6, -202.4)}},
    {cnName = "天气岛楚新 (Chu Xin)", internalName = "Chu Xin", desc = "主线任务 (天气之岛/起始岛码头 出售并生成船只 Spawn Boat)", aliases = {"Chu Xin", "ChuXin", "Sở Tân", "So Tan", "Boat Seller", "Spawn Boat", "楚新", "楚Xin", "生成船只"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9), altPositions = {Vector3.new(-200.7, 11.1, 35.9), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "楚无双 / 表哥 (Biao Ge)", internalName = "Biao Ge", desc = "设出生点 主线 宝珠任务 (记录当前岛屿重生点 Set Spawn)", aliases = {"Biao Ge", "Chu Wu Shuang", "Biểu Ca", "Bieu Ca", "Set Spawn", "SpawnPoint", "楚无双", "表哥", "重生点"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "娜娜 (Nana)", internalName = "Nana", desc = "卖鱼商人 (各岛收购鱼类换取 Cash 核心经济)", aliases = {"Nana", "Fish Buyer", "SellNPC", "娜娜", "卖鱼"}, fallbackPos = Vector3.new(-203.5, 7.3, 107.1)},
    {cnName = "八长 (Ba Chang)", internalName = "Ba Chang", desc = "鱼饵商人 (出售 Luck 鱼饵与制作彩虹/冰霜神话鱼饵)", aliases = {"Ba Chang", "Bai Chang", "Bá Trường", "Ba Truong", "Bait Seller", "八长", "鱼饵"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9), altPositions = {Vector3.new(-200.7, 11.1, 35.9), Vector3.new(-2908.1, 6.8, 1191.2)}},

    -- 2. 各岛高阶主线与专属技能 NPC
    {cnName = "升天国 / 夏钓帝 (Ha Dieu De)", internalName = "Ha Dieu De", desc = "任务 技能升级 (冰霜岛 [6] 斩天门V3 Sever The Gate v3 任务)", aliases = {"Ha Dieu De", "Hạ Điếu Đế", "Sheng Tian Guo", "Sever The Gate", "Gate v3", "Xia Diaodi", "夏钓帝", "升天国", "曾天国"}, fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4), preferPos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {cnName = "北冥 (Bac Minh)", internalName = "Bac Minh", desc = "买技能 任务 主线 (椰子岛 [7] 北冥宝珠 Bac Minh Orb 主线)", aliases = {"Bac Minh", "Bei Ming", "BacMinh", "BeiMing", "Bắc Minh", "北冥"}, fallbackPos = Vector3.new(1493.6, 9.1, -1430.6), preferPos = Vector3.new(1493.6, 9.1, -1430.6)},
    {cnName = "断杆 (Dawan Gan / Duan Gan)", internalName = "Dawan Gan", desc = "公会 创造公会 主线 (战场岛/雾峰岛 登仙十钓/破天四技能)", aliases = {"Dawan Gan", "Duan Gan", "DuanGan", "Doan Can", "Đoạn Cần", "Guild", "断杆", "断竿"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7)}},
    {cnName = "战场岛楚依旧 (Sage Yijiu)", internalName = "Sage Yijiu", desc = "买技能 任务 (战场岛 [9] 5阶段终极主线: 钻石竿→一钩霸主)", aliases = {"Sage Yijiu", "Sage Yiju", "Chu Yijiu", "Sage Eiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "失明的大钓鱼人 (Blind Grand Angler)", internalName = "Blind Grand Angler", desc = "任务 对话 (战场岛 [9] 星辰大钓术·极 Astral Grand Art Zenith)", aliases = {"Blind Grand Angler", "Grand Angler", "BlindAngler", "Blind", "失明", "大钓鱼人", "盲眼"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "竹岛江老 (Giang Lao)", internalName = "Giang Lao", desc = "任务 对话 (竹岛 [2] 无影太极击 Shadowless Taji + 神圣竹竿)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), preferPos = Vector3.new(-1223.0, 7.3, -24.1)},
    {cnName = "战场岛江老 (Giang Lao BF)", internalName = "Giang Lao BF", remoteName = "Giang Lao", desc = "主线任务 (战场岛 [9] 升仙太极术 Ascended Taji Art 任务)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "老江 (Old Jiang)", internalName = "Old Jiang", desc = "普通升级任务 (竹岛/主权岛 经验与等级提升支线)", aliases = {"Old Jiang", "Giang Lao", "Jiang Lao", "Lão Giang", "老江", "江老"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), altPositions = {Vector3.new(-1223.0, 7.3, -24.1), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "钓科威 / 老吴 (Lao Ngo)", internalName = "Lao Ngo", desc = "主线任务 (战场岛/天气岛 碎心斩V2 Heartbreaker Cleave V2 任务)", aliases = {"Lao Ngo", "Diao Ke Wei", "Lao Wu", "Lão Ngô", "Heartbreaker", "钓科威", "迪奥·克维", "迪奥", "老吴"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "暗影 (The Shadow)", internalName = "The Shadow", desc = "升级角色 (起始岛瀑布后秘密洞穴 · 献祭资源突破角色等级)", aliases = {"The Shadow", "Shadow", "An Ying", "Dark", "Upgrade Character", "暗影", "升级角色"}, fallbackPos = Vector3.new(-8.4, 53.9, 6.7), preferPos = Vector3.new(-8.4, 53.9, 6.7)},

    -- 3. 后期门派与英雄任务 NPC（加入多英文/越文内部别名 + 跨岛巡检定位，解决远距离找不到问题）
    {cnName = "少林 / 花和尚 (Shaolin)", internalName = "Shaolin", desc = "购买 (少林钓法 / 降龙伏虎 / 如来神掌 武学技能)", aliases = {"Shaolin", "Monk", "Flower Monk", "Thieu Lam", "Hoa Thuong", "Hòa Thượng", "Buddha", "Tathagata", "Dragon Subjugation", "少林", "花和尚"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "五指钓王 (Five Finger King)", internalName = "Five Finger King", desc = "主线任务(天气鱼) (琥珀岛/雾峰岛 提交指定天气稀有鱼)", aliases = {"Five Finger", "Wu Zhi", "Weather King", "Finger", "Ngu Chi", "Ngũ Chỉ", "World Angler", "五指钓王", "五指", "卢奥亚之王"}, fallbackPos = Vector3.new(1259.4, 9.1, 1401.5), altPositions = {Vector3.new(1259.4, 9.1, 1401.5), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "史星钓 / 石克翔 (Shi Xing Diao)", internalName = "Shi Xing Diao", desc = "主线任务 (雾峰岛/珊瑚礁岛 高阶钓鱼人主线任务挑战)", aliases = {"Shi Xing Diao", "ShiXingDiao", "石克翔", "史星钓", "石星之骄", "World Angler", "Star Angler"}, fallbackPos = Vector3.new(2660.2, 8.8, -86.7), altPositions = {Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "楚天骄 (Chu Tian Jiao)", internalName = "Chu Tian Jiao", desc = "主线任务 (战场岛/雾峰岛/珊瑚礁岛 天骄专属进阶试炼任务)", aliases = {"Chu Tian Jiao", "ChuTianJiao", "Tian Jiao", "Thien Kieu", "Sở Thiên Kiêu", "Pride", "Celestial", "楚天骄", "楚天之骄"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1259.4, 9.1, 1401.5)}},
    {cnName = "亚索 (Yasuo)", internalName = "Yasuo", desc = "主线任务 (鲈鱼岛/珊瑚礁岛/战场岛 疾风剑豪斩风钓法全套技能)", aliases = {"Yasuo", "Yaxuo", "Wind", "Swordsman", "Wanderer", "Ronin", "Chem Gio", "Triple Cut", "亚索"}, fallbackPos = Vector3.new(-62.0, 11.9, -1321.4), altPositions = {Vector3.new(-62.0, 11.9, -1321.4), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7)}},

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
        internalName = "Spirit_Bamboo",
        islandName = "[2] 竹岛",
        desc = "竹岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得竹岛神灵祝福)",
        aliases = {"Spirit_Bamboo", "Bamboo Spirit", "Green Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "竹岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1223.0, 7.3, -24.1),
        preferPos = Vector3.new(-1223.0, 7.3, -24.1),
    },
    {
        liveKey = "Spirit_Frost",
        cnName = "神灵 #2 · 冰霜岛神灵 (Frost Isle)",
        internalName = "Spirit_Frost",
        islandName = "[6] 冰霜岛",
        desc = "冰霜岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得霜岛神灵祝福)",
        aliases = {"Spirit_Frost", "Frost Spirit", "Blue Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "冰霜神灵", "冰霜岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4),
        preferPos = Vector3.new(-1366.0, 11.9, -1495.4),
    },
    {
        liveKey = "Spirit_Amber",
        cnName = "神灵 #3 · 琥珀岛神灵 (Amber Isle)",
        internalName = "Spirit_Amber",
        islandName = "[8] 琥珀岛",
        desc = "琥珀岛祭坛 · 每次祈祷花费 50M Cash (集齐三岛祝福解锁幻影灯笼鱼克制技)",
        aliases = {"Spirit_Amber", "Amber Spirit", "Yellow Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "神灵", "琥珀神灵", "琥珀岛神灵", "祭坛", "祈祷"},
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

-- 预编译并缓存 NPC 配置项的多语言检索关键词列表（转小写去重）
local function GetCompiledSpecKeywords(spec)
    if spec._compiledKeywords then return spec._compiledKeywords end
    local kwList = {}
    local seenKw = {}
    -- 将单个非空关键词转小写去重后加入检索列表
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

    -- 判断 ProximityPrompt 是否属于恩佐或无名章鱼等 Boss 交互点
    local function IsBossPromptCandidate(inst)
        if not inst or not inst:IsA("ProximityPrompt") then return false end
        local full = inst:GetFullName():lower()
        return (full:find("boss", 1, true) or full:find("enzo", 1, true) or full:find("octo", 1, true) or full:find("parasite", 1, true) or full:find("angler", 1, true) or full:find("rhythm", 1, true) or full:find("buoy", 1, true)) ~= nil
    end

    -- 备份单个 ProximityPrompt 的原始触发距离、视线要求与按住时长
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
            enabled = (pr.Enabled ~= false),
        }
        originalPromptState[pr] = state
        return state
    end

    -- 将被远距触发修改过的 ProximityPrompt 恢复为原始属性并消除粘滞弹窗
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
                            pr.Enabled = (orig.enabled ~= false)
                        end)
                    end
                end)
            end
        end)
    end

    -- 批量还原被远距触发污染的 ProximityPrompt 并隐藏远离玩家的残留交互提示框
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

    -- 获取当前场景内缓存的所有有效 ProximityPrompt 列表（自动剔除已销毁实例）
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
            -- 定向扫描 NPC/交互容器与 Workspace（对齐旧版 36max22 行为，保证对话与票据任务立即获得有效提示词）
            for _, folderName in ipairs(NPC_SCAN_CONTAINER_NAMES) do
                local f = Workspace:FindFirstChild(folderName)
                if f then
                    for _, d in ipairs(f:GetDescendants()) do
                        if d:IsA("ProximityPrompt") and d.Parent and not cachedAllPromptsSet[d] then
                            cachedAllPromptsSet[d] = true
                            table.insert(cachedAllPrompts, d)
                            if not currentlyTriggeringPrompts[d] and (tonumber(d.MaxActivationDistance) or 10) <= 35 then
                                RememberPromptState(d)
                            end
                        end
                    end
                end
            end
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

    -- 临时放开距离限制并触发指定 NPC 实例下的所有 ProximityPrompt 或 ClickDetector
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
                        pr.Enabled = (orig.enabled ~= false)
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
local function FindNPCInstancesBySpec(spec, forceRescan)
    local now = tick()
    local cachedEntry = npcScanCache[spec]
    if not forceRescan and cachedEntry and (now - cachedEntry.tick) < 0.5 and type(cachedEntry.results) == "table" then
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
    local function isNearSpec(p)
        if not p then return false end
        local anchor = spec.preferPos or spec.fallbackPos
        if not anchor then return true end
        if (p - anchor).Magnitude < 650 then return true end
        if spec.altPositions then
            for _, ap in ipairs(spec.altPositions) do
                if (p - ap).Magnitude < 650 then return true end
            end
        end
        return false
    end

    if spec.liveKey and liveNPCs[spec.liveKey] and liveNPCs[spec.liveKey].inst and liveNPCs[spec.liveKey].inst.Parent then
        local cachedInst = liveNPCs[spec.liveKey].inst
        local cPos = liveNPCs[spec.liveKey].pos or GetNPCPosition(cachedInst)
        if isNearSpec(cPos) then
            seen[cachedInst] = true
            table.insert(results, cachedInst)
        end
    end
    if spec.internalName and OnlineNPCs[spec.internalName] then
        local cached = OnlineNPCs[spec.internalName]
        if cached.instance and cached.instance.Parent and not seen[cached.instance] then
            local cPos = cached.pos or GetNPCPosition(cached.instance)
            if isNearSpec(cPos) then
                seen[cached.instance] = true
                table.insert(results, cached.instance)
            end
        end
    end

    local searchContainers = {}
    -- [冗余清理] 与全图雷达共用同一份目录名单常量
    for _, folderName in ipairs(NPC_SCAN_CONTAINER_NAMES) do
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

    -- 检查单个场景节点是否匹配目标 NPC 配置并加入结果集
    local function checkNode(inst)
        if not inst or seen[inst] or IsMapOrIslandContainer(inst) then return end
        if not (inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder")) then return end
        if DoesInstanceMatchNPCSpec(inst, spec) then
            local nPos = GetNPCPosition(inst)
            if isNearSpec(nPos) then
                seen[inst] = true
                table.insert(results, inst)
            end
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
                    local pPos = GetNPCPosition(entity) or GetNPCPosition(d.Parent)
                    if isNearSpec(pPos) then
                        seen[entity] = true
                        table.insert(results, entity)
                    end
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
    -- 检测玩家屏幕上是否已弹出 NPC 对话框界面（带 0.35s 节流缓存）
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
        -- 从指定的界面容器列表中收集所有可见可点击的对话选项按钮
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

    local function isNearSpec(p)
        if not p then return false end
        local anchor = spec.preferPos or spec.fallbackPos
        if not anchor then return true end
        if (p - anchor).Magnitude < 650 then return true end
        if spec.altPositions then
            for _, ap in ipairs(spec.altPositions) do
                if (p - ap).Magnitude < 650 then return true end
            end
        end
        return false
    end

    local targetPos = nil
    if primaryInst and isNearSpec(GetNPCPosition(primaryInst)) then
        targetPos = GetNPCPosition(primaryInst)
    elseif liveEntry and isNearSpec(liveEntry.pos) then
        targetPos = liveEntry.pos
    elseif cachedRadar and isNearSpec(cachedRadar.pos) then
        targetPos = cachedRadar.pos
    else
        targetPos = spec.preferPos or spec.fallbackPos
    end

    if not targetPos then
        ShowNotification("传送提示", string.format("当前服务器暂未检测到 [%s] 刷新。", spec.cnName or internalName), "WARN", 4)
        return false
    end

    TryStreamAroundPosition(targetPos)
    if not SafeTeleport(CFrame.new(targetPos + Vector3.new(0, 3, 4), targetPos)) then
        ShowNotification("NPC 传送", "本地角色尚未就绪，传送失败，请稍后重试。", "ERROR", 3)
        return false
    end
    ShowNotification("NPC 传送", "正在前往: " .. tostring(spec.cnName or internalName), "SUCCESS", 3)

    -- 到达岛屿后等待 0.28 秒流式加载完成，若扫描到真实 NPC 模型则二次精准对齐到他面前 3 米处（严格距离校验，绝不跨岛乱拉）
    task.spawn(function()
        task.wait(0.28)
        pcall(function()
            local loadedList = FindNPCInstancesBySpec(spec, true)
            if #loadedList > 0 then
                local exactPos = GetNPCPosition(loadedList[1])
                if exactPos and isNearSpec(exactPos) then
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
    local remoteTargetName = spec.remoteName or internalName
    local cachedRadar = OnlineNPCs[internalName]
    local liveEntry = spec.liveKey and liveNPCs[spec.liveKey]

    local function isNearSpec(p)
        if not p then return false end
        local anchor = spec.preferPos or spec.fallbackPos
        if not anchor then return true end
        if (p - anchor).Magnitude < 650 then return true end
        if spec.altPositions then
            for _, ap in ipairs(spec.altPositions) do
                if (p - ap).Magnitude < 650 then return true end
            end
        end
        return false
    end

    local npcInstances = FindNPCInstancesBySpec(spec)
    local primaryInst = npcInstances[1]
    if not primaryInst and liveEntry and liveEntry.inst and liveEntry.inst.Parent and isNearSpec(liveEntry.pos or GetNPCPosition(liveEntry.inst)) then
        primaryInst = liveEntry.inst
    end
    if not primaryInst and cachedRadar and cachedRadar.instance and cachedRadar.instance.Parent and isNearSpec(cachedRadar.pos or GetNPCPosition(cachedRadar.instance)) then
        primaryInst = cachedRadar.instance
    end

    local targetPos = nil
    if primaryInst and isNearSpec(GetNPCPosition(primaryInst)) then
        targetPos = GetNPCPosition(primaryInst)
    elseif liveEntry and isNearSpec(liveEntry.pos) then
        targetPos = liveEntry.pos
    elseif cachedRadar and isNearSpec(cachedRadar.pos) then
        targetPos = cachedRadar.pos
    else
        targetPos = spec.preferPos or spec.fallbackPos
    end

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
                    SafeFireOneRemote(rem, remoteTargetName)
                    if spec.aliases and spec.aliases[1] and spec.aliases[1] ~= remoteTargetName then
                        SafeFireOneRemote(rem, spec.aliases[1])
                    end
                    directTried = true
                end
            end
        end

        if directTried then
            task.wait(0.22)
            if IsDialogueUIOpen(true) then
                DismissStuckPromptsAndRestore(false)
                if not silent then
                    ShowNotification("角色", string.format("已打开 %s 的对话 (直连成功)。", spec.cnName or internalName), "SUCCESS", 3)
                end
                if type(postDialogueCallback) == "function" then
                    pcall(postDialogueCallback)
                end
                return
            end
            DismissStuckPromptsAndRestore(false)
        end

        -- 🥈 引擎 2：岛屿流式预加载 + 微瞬移贴脸强制触发（彻底解决后期岛屿亚索/少林/楚天骄/曾天国等被卸载导致无法打开的问题）
        if not isMicroTeleportingNPC then
            isMicroTeleportingNPC = true
            microTeleportLockAt = tick()
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
                    task.wait(0.32)

                    local nearInstances = FindNPCInstancesBySpec(spec, true)
                    local nearTriggered = false
                    if #nearInstances > 0 then
                        local exactNPC = nearInstances[1]
                        local exactPos = GetNPCPosition(exactNPC)
                        if exactPos and isNearSpec(exactPos) then
                            OnlineNPCs[internalName] = { instance = exactNPC, pos = exactPos, time = tick() }
                            -- 第二步：如果 NPC 真实位置距离当前探测点超过 8 米，再贴脸瞬移到该 NPC 面前 2 米处确保通过服务端距离校验！
                            if (root.Position - exactPos).Magnitude > 8 then
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

                    -- 兜底：若按模型未找到，扫描流式加载后的全局/岛内 ProximityPrompt，严格校验匹配当前 spec（或距离专属坐标 < 14 米且非其他杂项 NPC），绝不乱开老江等无关 NPC！
                    if not nearTriggered then
                        local myNowPos = root.Position
                        local bestPr, bestDist = nil, 45
                        local allPrompts = GetCachedWorkspacePrompts()
                        for i = 1, #allPrompts do
                            local d = allPrompts[i]
                            if d and d.Parent then
                                local entity = ResolvePromptEntity(d)
                                local okAnc, anc = pcall(function() return d:FindFirstAncestorOfClass("Model") end)
                                local model = entity or (okAnc and anc) or d.Parent
                                local pPos = GetNPCPosition(model) or GetNPCPosition(d.Parent)
                                if pPos then
                                    local dist = (pPos - myNowPos).Magnitude
                                    local matchesSpec = DoesInstanceMatchNPCSpec(model, spec) or DoesInstanceMatchNPCSpec(d.Parent, spec)
                                    local prText = ((d.ObjectText or "") .. " " .. (d.ActionText or "") .. " " .. (d.Name or "")):lower()
                                    if not matchesSpec then
                                        for _, kw in ipairs(GetCompiledSpecKeywords(spec)) do
                                            if prText:find(kw, 1, true) then
                                                matchesSpec = true
                                                break
                                            end
                                        end
                                    end
                                    -- 仅当明确匹配当前 NPC 关键词，或紧贴专属锚点 (<12米) 且不属于老江/娜娜/八长/表哥/楚新时才允许触发
                                    local mName = (model and model.Name or ""):lower()
                                    local isOtherCommonNPC = (mName:find("nana", 1, true) or mName:find("ba chang", 1, true) or mName:find("biao ge", 1, true)
                                        or mName:find("chu xin", 1, true) or mName:find("giang", 1, true) or mName:find("jiang", 1, true)
                                        or prText:find("老江", 1, true) or prText:find("江老", 1, true) or prText:find("娜娜", 1, true))
                                    if (matchesSpec and dist < 260) or (not isOtherCommonNPC and dist < 12) then
                                        if dist < bestDist or matchesSpec then
                                            bestDist = matchesSpec and math.min(dist, 5) or dist
                                            bestPr = d
                                            if matchesSpec then break end
                                        end
                                    end
                                end
                            end
                        end
                        if bestPr then
                            local pPos = GetNPCPosition(bestPr.Parent)
                            if pPos and (root.Position - pPos).Magnitude > 8 then
                                root.CFrame = CFrame.new(pPos + Vector3.new(0, 2.5, 2))
                                root.AssemblyLinearVelocity = Vector3.zero
                                task.wait(0.18)
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
            microTeleportLockAt = 0
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
    local row = createBaseRow(parent, labelText, descText)
    local tpBtn = Instance.new("TextButton")
    tpBtn.Size = UDim2.new(0, 56, 0, 24)
    tpBtn.Position = UDim2.new(1, -126, 0.5, -12)
    tpBtn.BackgroundColor3 = Colors.ControlBg
    tpBtn.Font = Enum.Font.GothamBold
    tpBtn.Text = "传送"
    tpBtn.TextColor3 = Colors.TextWhite
    tpBtn.TextSize = 11
    tpBtn.BorderSizePixel = 0
    tpBtn.Parent = row
    Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)
    tpBtn.MouseEnter:Connect(function() PlayQuickTween(tpBtn, {BackgroundColor3 = Colors.PurpleDark}) end)
    tpBtn.MouseLeave:Connect(function() PlayQuickTween(tpBtn, {BackgroundColor3 = Colors.ControlBg}) end)
    BindClick(tpBtn, function() if type(onTeleport) == "function" then pcall(onTeleport) end end)

    local dlgBtn = Instance.new("TextButton")
    dlgBtn.Size = UDim2.new(0, 64, 0, 24)
    dlgBtn.Position = UDim2.new(1, -64, 0.5, -12)
    dlgBtn.BackgroundColor3 = Colors.PurpleAccent
    dlgBtn.Font = Enum.Font.GothamBold
    dlgBtn.Text = "对话"
    dlgBtn.TextColor3 = Colors.TextWhite
    dlgBtn.TextSize = 11
    dlgBtn.BorderSizePixel = 0
    dlgBtn.Parent = row
    Instance.new("UICorner", dlgBtn).CornerRadius = UDim.new(0, 4)
    RegisterThemeUpdater(function() dlgBtn.BackgroundColor3 = Colors.PurpleAccent end)
    dlgBtn.MouseEnter:Connect(function() PlayQuickTween(dlgBtn, {BackgroundColor3 = Colors.PurpleDark}) end)
    dlgBtn.MouseLeave:Connect(function() PlayQuickTween(dlgBtn, {BackgroundColor3 = Colors.PurpleAccent}) end)
    BindClick(dlgBtn, function() if type(onDialogue) == "function" then pcall(onDialogue) end end)
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
local godCard = createCollapsibleGroup(tabGod, "三个神灵世界事件 (竹岛 / 冰霜岛 / 琥珀岛 · 50M 祈祷)")

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

local roamGodCard = createCollapsibleGroup(tabGod, "流动商人与「三个神灵」任务接取")
-- 按 liveKey 反查 NPC 配置：原实现硬编码 ImportantDialogueNPCs[20/21/22]，
-- 而这三个下标实际指向「少林/五指钓王/史星钓」，导致道士/茅山/傻子三行传送到错误 NPC。
-- 根据 liveKey 在 ImportantDialogueNPCs 数据库中反查对应的 NPC 配置项
local function FindNPCSpecByLiveKey(liveKey)
    for i = 1, #ImportantDialogueNPCs do
        if ImportantDialogueNPCs[i].liveKey == liveKey then return ImportantDialogueNPCs[i] end
    end
    return nil
end
createNPCDualActionRow(roamGodCard, "道士商人 (Taoist Merchant)", "接取「三个神灵」前置任务 / 购买 100M 道士珠与 200M 极鹰猎", function()
    TeleportToNPCSpec(FindNPCSpecByLiveKey("Taoist"))
end, function()
    OpenRemoteNPCDialogue(FindNPCSpecByLiveKey("Taoist"), false)
end)
createNPCDualActionRow(roamGodCard, "茅山商人 (Maoshan Merchant)", "购买 300M 茅山竿(105威力) / 200M 茅山珠 / 200M 镇江技能", function()
    TeleportToNPCSpec(FindNPCSpecByLiveKey("Maoshan"))
end, function()
    OpenRemoteNPCDialogue(FindNPCSpecByLiveKey("Maoshan"), false)
end)
createNPCDualActionRow(roamGodCard, "傻子隐藏商人 (Dumb Guy)", "轮换隐藏商人 · 获取六脉神鹰 Six Vein Divine Hawk 技能", function()
    TeleportToNPCSpec(FindNPCSpecByLiveKey("DumbGuy"))
end, function()
    OpenRemoteNPCDialogue(FindNPCSpecByLiveKey("DumbGuy"), false)
end)

local beastCard = createCollapsibleGroup(tabGod, "四圣兽 (朱雀 / 玄武 / 白虎 / 青龙 · 神话特质与圣兽Boss雷达)")
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

local hopCard = createCollapsibleGroup(tabGod, "服务器跳转引擎")
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
local questCard = createCollapsibleGroup(tabQuests, "票据任务 (双引擎: 直连 + 微瞬移保底)")
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

local dailyCard = createCollapsibleGroup(tabQuests, "每日任务与奖励")

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
            else
                ShowNotification("每日奖励", "未找到每日奖励远程事件，领取失败。", "WARN")
            end
        else
            ShowNotification("每日奖励", "游戏远程事件尚未就绪，请稍后重试。", "WARN")
        end
        task.wait(2.5)
        isClaimingDailySign = false
    end)
end)

local isRedeemingCodes = false
local knownActiveCodes = {
    "SeeYouSoon", "BUGfix", "BUGTrait", "65KLikes", "41MVisits", "40MVisits",
    "39MVisits", "38MVisits", "37MVisits", "33MVisits", "32MVisits", "31MVisits",
    "Legendary", "BannerShop", "WeeklyUPD1", "85KLikes", "25KActives",
    "Riku", "SON", "VermilionBird", "80KLikes", "Welcome", "HWF", "AXO",
    "60KLikes", "50KLikes", "13KActives", "6KActives"
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
local npcTalkCard = createCollapsibleGroup(tabQuests, "NPC对话与传送 (每行支持: [传送] 到面前 + 远距离 [对话])")

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
local npcQuestSubCard = createCollapsibleGroup(tabQuests, "NPC任务")

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
-- 【模块 21：【传送】页面构建（自定义坐标点管理、10大特殊NPC实时雷达传送、岛屿/商人/秘密鱼竿/玩家传送）】
-- 作用说明：
--   1. 支持读取并保存当前 XYZ 坐标为自定义传送点（支持单独删除与本地 JSON 持久化）；
--   2. 构建 10 大特殊 NPC（竹岛/冰霜/琥珀神灵、道士/茅山/傻子商人、朱雀/玄武/白虎/青龙）实时状态与安全射线落地传送行；
--   3. 构建 1~10 号岛屿、Boss 领域、各岛标迪鱼竿商人、6 把秘密鱼竿点位以及指定/随机玩家传送面板。
-- ============================================================================
-- 传送页面
-- ==========================================
do
local customTPCard = createCollapsibleGroup(tabTeleports, "自定义传送点 (支持单独删除)")

local inputRow = Instance.new("Frame"); inputRow.Size = UDim2.new(1, 0, 0, 42); inputRow.BackgroundColor3 = Colors.RowNormal; inputRow.BorderSizePixel = 0; inputRow.Parent = customTPCard
local box = Instance.new("TextBox"); box.Size = UDim2.new(1, -115, 0, 26); box.Position = UDim2.new(0, 10, 0.5, -13); box.BackgroundColor3 = Colors.InputBg; box.Font = Enum.Font.Gotham; box.PlaceholderText = "输入传送名称..."; box.PlaceholderColor3 = Colors.TextMuted; box.Text = ""; box.TextColor3 = Colors.TextWhite; box.TextSize = 11; box.BorderSizePixel = 0; box.ClearTextOnFocus = false; box.Parent = inputRow
do local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 8); p.Parent = box end
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)

local saveBtn = Instance.new("TextButton"); saveBtn.Size = UDim2.new(0, 90, 0, 26); saveBtn.Position = UDim2.new(1, -100, 0.5, -13); saveBtn.BackgroundColor3 = Colors.PurpleAccent; saveBtn.Font = Enum.Font.GothamBold; saveBtn.Text = "保存当前位置"; saveBtn.TextColor3 = Colors.TextWhite; saveBtn.TextSize = 11; saveBtn.BorderSizePixel = 0; saveBtn.Parent = inputRow
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 4)
RegisterThemeUpdater(function() saveBtn.BackgroundColor3 = Colors.PurpleAccent end)

local coordRow = Instance.new("Frame"); coordRow.Size = UDim2.new(1, 0, 0, 42); coordRow.BackgroundColor3 = Colors.RowNormal; coordRow.BorderSizePixel = 0; coordRow.Parent = customTPCard
local coordLabel = Instance.new("TextLabel"); coordLabel.Size = UDim2.new(1, -115, 1, 0); coordLabel.Position = UDim2.new(0, 10, 0, 0); coordLabel.BackgroundTransparency = 1; coordLabel.Font = Enum.Font.GothamBold; coordLabel.Text = "当前坐标: 点击右侧读取"; coordLabel.TextColor3 = Colors.AccentGreen; coordLabel.TextSize = 11; coordLabel.TextXAlignment = Enum.TextXAlignment.Left; coordLabel.Parent = coordRow
local readBtn = Instance.new("TextButton"); readBtn.Size = UDim2.new(0, 90, 0, 26); readBtn.Position = UDim2.new(1, -100, 0.5, -13); readBtn.BackgroundColor3 = Colors.ControlBg; readBtn.Font = Enum.Font.GothamBold; readBtn.Text = "读取当前 XYZ"; readBtn.TextColor3 = Colors.TextWhite; readBtn.TextSize = 11; readBtn.BorderSizePixel = 0; readBtn.Parent = coordRow
Instance.new("UICorner", readBtn).CornerRadius = UDim.new(0, 4)

local listFrame = Instance.new("Frame"); listFrame.Size = UDim2.new(1, 0, 0, 0); listFrame.AutomaticSize = Enum.AutomaticSize.Y; listFrame.BackgroundTransparency = 1; listFrame.Parent = customTPCard
local ll = Instance.new("UIListLayout"); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = listFrame

-- 重新渲染自定义传送点列表 UI（生成每行的传送与删除按钮）
local function RefreshCustomTPs()
    for _, child in ipairs(listFrame:GetChildren()) do if child:IsA("Frame") then child:Destroy() end end
    for i, tp in ipairs(CustomTPs) do
        local coordText = string.format("X: %.1f | Y: %.1f | Z: %.1f", tp.x, tp.y, tp.z)
        local row = createBaseRow(listFrame, tp.name, coordText)

        local tpBtn = Instance.new("TextButton")
        tpBtn.Size = UDim2.new(0, 62, 0, 24)
        tpBtn.Position = UDim2.new(1, -92, 0.5, -12)
        tpBtn.BackgroundColor3 = Colors.ControlBg
        tpBtn.Font = Enum.Font.GothamBold
        tpBtn.Text = "传送"
        tpBtn.TextColor3 = Colors.PurplePrimary
        tpBtn.TextSize = 11
        RegisterThemeUpdater(function() if tpBtn and tpBtn.Parent then tpBtn.TextColor3 = Colors.PurplePrimary end end)
        tpBtn.BorderSizePixel = 0
        tpBtn.Parent = row
        Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)
        BindClick(tpBtn, function()
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
        BindClick(delBtn, function()
            table.remove(CustomTPs, i)
            SaveCustomTPs()
            RefreshCustomTPs()
            ShowNotification("已删除", "已移除传送点: " .. tp.name, "WARN")
        end)
    end
end

BindClick(readBtn, function()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local p = root.Position
        coordLabel.Text = string.format("X: %.1f | Y: %.1f | Z: %.1f", p.X, p.Y, p.Z)
        ShowNotification("当前坐标", string.format("X: %.1f, Y: %.1f, Z: %.1f", p.X, p.Y, p.Z), "SUCCESS")
    end
end)
BindClick(saveBtn, function()
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
local liveNPCCard = createCollapsibleGroup(tabTeleports, "特殊NPC实时检测与传送 (三个神灵 + 茅山/道士 + 四圣兽)")
-- 创建特殊 NPC 实时监控行（显示刷新状态与距离，点击时通过向下射线检测安全落点后传送）
local function CreateNPCRow(key, data)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 42); row.BackgroundColor3 = Colors.RowNormal; row.BorderSizePixel = 0; row.Parent = liveNPCCard
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.Parent = row
    local tf = Instance.new("Frame"); tf.Size = UDim2.new(1, -110, 1, 0); tf.BackgroundTransparency = 1; tf.Parent = row
    local title = Instance.new("TextLabel"); title.Size = UDim2.new(1, 0, 0, 18); title.Position = UDim2.new(0, 0, 0, 4); title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.Text = data.icon .. " " .. data.name .. " (未检测到)"; title.TextColor3 = Colors.TextMuted; title.TextSize = 12; title.TextXAlignment = Enum.TextXAlignment.Left; title.TextTruncate = Enum.TextTruncate.AtEnd; title.Parent = tf
    local desc = Instance.new("TextLabel"); desc.Size = UDim2.new(1, 0, 0, 14); desc.Position = UDim2.new(0, 0, 0, 22); desc.BackgroundTransparency = 1; desc.Font = Enum.Font.Gotham; desc.Text = data.desc or "等待刷新..."; desc.TextColor3 = Colors.TextMuted; desc.TextSize = 10; desc.TextXAlignment = Enum.TextXAlignment.Left; desc.TextTruncate = Enum.TextTruncate.AtEnd; desc.Parent = tf
    local btn = Instance.new("TextButton"); btn.Size = UDim2.new(0, 90, 0, 24); btn.Position = UDim2.new(1, -90, 0.5, -12); btn.BackgroundColor3 = Colors.ControlBg; btn.Font = Enum.Font.GothamBold; btn.Text = data.fallbackPos and "前往岛屿" or "传送"; btn.TextColor3 = Colors.TextMuted; btn.TextSize = 11; btn.BorderSizePixel = 0; btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    data.ui_title = title; data.ui_desc = desc; data.ui_btn = btn
    RegisterThemeUpdater(function() if data.pos then btn.BackgroundColor3 = Colors.PurpleAccent elseif data.fallbackPos then btn.TextColor3 = Colors.PurplePrimary end end)
    BindClick(btn, function()
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
                for _, fn in ipairs({"IdenticalESP", "IdenticalESPAnchors", "IdenticalESPHighlights", "FishRingAnchor", "IdenticalWaterPlatform"}) do
                    local espInst = Workspace:FindFirstChild(fn)
                    if espInst then table.insert(ignoreList, espInst) end
                end
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

local islandCard = createCollapsibleGroup(tabTeleports, "钓鱼岛屿传送 (完整 13 岛屿汇总)")
local islands = {
    {id = 1,  name = "[1] 起始岛 (Beginning Isle)", power = "1", desc = "新手出生岛 · Nana卖鱼 / 楚依旧技能 / 南江洗特质 / 票据任务 / 暗影山洞", pos = Vector3.new(-200.7, 11.1, 35.9), aliases = {"Beginning", "Starting", "起始岛", "初始岛"}},
    {id = 2,  name = "[2] 竹子岛 (Bamboo Isle)", power = "19", desc = "早期主线岛 + 竹岛神灵 #1 · 江老（无影太极击）/ 50M祈祷祝福", pos = Vector3.new(-1223.0, 7.3, -24.1), aliases = {"Bamboo", "竹岛", "竹子岛"}},
    {id = 3,  name = "[3] 辐射岛 (Fallout Isle)", power = "32", desc = "Enzo（等级1000 Boss三难度）· 黄金竿等中期鱼竿", pos = Vector3.new(65.5, 8.8, 1181.3), aliases = {"Fallout", "Radiation", "辐射岛"}},
    {id = 4,  name = "[4] 主权岛屿 (Sovereign Isle)", power = "39", desc = "大师级鱼竿（Grandmaster / Inferno）· 老江支线", pos = Vector3.new(-1276.4, 8.8, 1239.7), aliases = {"Sovereign", "主权岛", "主权岛屿"}},
    {id = 5,  name = "[5] 鲈鱼岛 (Perch Isle)", power = "48", desc = "脊椎系列鱼竿 · 亚索（疾风剑豪斩风钓法门派）", pos = Vector3.new(-62.0, 11.9, -1321.4), aliases = {"Perch", "鲈鱼岛"}},
    {id = 6,  name = "[6] 冰霜岛 (Frost Isle)", power = "55", desc = "重力系列鱼竿 + 冰霜神灵 #2 · 夏钓帝（斩天门v3）/ 50M祈祷祝福", pos = Vector3.new(-1366.0, 11.9, -1495.4), aliases = {"Frost", "冰霜岛", "霜岛"}},
    {id = 7,  name = "[7] 椰子岛 (Coconut Isle)", power = "65", desc = "荆棘系列鱼竿 · 北冥（北冥宝珠主线任务）/ 椰子岛商人", pos = Vector3.new(1493.6, 9.1, -1430.6), aliases = {"Coconut", "椰子岛"}},
    {id = 8,  name = "[8] 琥珀岛 (Amber Isle)", power = "75", desc = "星光竿等主线终点 + 琥珀神灵 #3 · 五指钓王（天气鱼主线）/ 50M祈祷", pos = Vector3.new(1259.4, 9.1, 1401.5), aliases = {"Amber", "琥珀岛"}},
    {id = 9,  name = "[9] 战场岛 (Battlefield Isle)", power = "90", desc = "高阶技能与终局集中地 · 楚依旧/江老/老吴/盲眼钓圣/少林/楚天骄/断杆", pos = Vector3.new(1393.5, 11.3, 169.6), aliases = {"Battlefield", "战场岛"}},
    {id = 10, name = "[10] 迷雾山岛 (Mistpeak Isle)", power = "100", desc = "山海龙鲸 Boss · 卢奥亚之王主线任务 / 史星钓（石克翔）/ 断杆", pos = Vector3.new(2660.2, 8.8, -86.7), aliases = {"Mistpeak", "Mist", "雾峰岛", "迷雾山岛"}},
    {id = 11, name = "[11] 世界钓鱼岛 (World Angler Isle)", power = "100", desc = "比奥迪（Biao Di）主线任务 / 斩兽碎心V3 / 熔岩洞穴", pos = Vector3.new(-2404.5, 7.6, -202.4), aliases = {"World Angler", "WorldAngler", "World Fishing", "世界钓鱼岛"}},
    {id = 12, name = "[12] 天气之岛 (Weather Isle)", power = "100", desc = "天气核心终局岛 · 楚Xin（生成船只）/ 八长（鱼饵）/ 老姜与迪奥·克维主线", pos = Vector3.new(-2908.1, 6.8, 1191.2), aliases = {"Weather", "Weather Isle", "Weather Island", "天气之岛"}},
    {id = 13, name = "[13] 神秘珊瑚礁岛 (Mysterious Coral Reef)", power = "100", desc = "神秘珊瑚礁海域 · 楚天之骄 / 石星之骄 / Yaxuo（亚索）主线任务", pos = Vector3.new(-2648.0, 6.8, -1322.1), aliases = {"Coral Reef", "CoralReef", "Mysterious Coral", "神秘珊瑚礁岛", "珊瑚礁岛"}},
}
for _, isl in ipairs(islands) do
    local btnDesc = string.format("Power: %s | %s", isl.power or "1", isl.desc or ("传送到 " .. isl.name))
    createButtonRow(islandCard, isl.name, btnDesc, "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local targetPos = isl.pos
        TryStreamAroundPosition(targetPos)
        if SafeTeleport(CFrame.new(targetPos + Vector3.new(0, 3, 0))) then
            ShowNotification("岛屿传送", "已到达 " .. isl.name, "SUCCESS", 3.5)
        end
    end)
end

local bossRealmCard = createCollapsibleGroup(tabTeleports, "Boss竞技场与隐藏领域")
local bossRealms = {
    {name = "章鱼寄生体", pos = Vector3.new(1608.2, 5.0, -218.3)}, {name = "渔夫之地", pos = Vector3.new(112.5, -330.0, -30.8)}, {name = "Enzo竞技场", pos = Vector3.new(-115.3, 9.2, 1349.5)},
}
for _, br in ipairs(bossRealms) do
    createButtonRow(bossRealmCard, br.name, "传送到 " .. br.name, "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(br.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. br.name, "SUCCESS") end
    end)
end

local rodDealerCard = createCollapsibleGroup(tabTeleports, "鱼竿商人商店(标迪)")
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

local sRodCard = createCollapsibleGroup(tabTeleports, "秘密鱼竿位置")
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

local srvCard = createCollapsibleGroup(tabTeleports, "服务器与玩家传送")

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
end)
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
local espCard = createCollapsibleGroup(tabVisuals, "世界与实体ESP")
-- 切换指定类别的 ESP 开关并立即扫描刷新场景内的目标高亮
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

local perfCard = createCollapsibleGroup(tabVisuals, "光照与性能")
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
local moveCard = createCollapsibleGroup(tabPlayer, "玩家移动")
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

local stabCard = createCollapsibleGroup(tabPlayer, "防挂机与稳定性")
createToggleRow(stabCard, "防挂机", "防止Roblox 20分钟空闲断开", Config.AntiAFK, function(v) Config.AntiAFK = v end, "AntiAFK")
createToggleRow(stabCard, "被踢自动重连", "断线或报错弹窗时自动重连服务器", Config.AutoRejoin, function(v) Config.AutoRejoin = v end, "AutoRejoin")

-- ==========================================
-- 配置页面
-- ==========================================
local uiCard = createCollapsibleGroup(tabProfiles, "界面设置")

DashUI._applyTheme = ApplyTheme
createDropdownRow(uiCard, "主题配色", "切换非紫色高颜值点缀色（薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红）", THEME_OPTIONS, currentThemeName, function(value)
    ApplyTheme(value, false)
    ShowNotification("主题配色已切换", "当前配色: " .. tostring(value), "SUCCESS", 2.5)
end, "UITheme")

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

-- [折叠面板] 批量展开 / 折叠：32 个分组逐个点太麻烦，这里提供一键操作并立即刷新当前页画布
-- 一键批量展开或折叠所有分组面板并刷新当前页滚动高度
local function ApplyAllSectionsExpanded(wantExpanded, tipText)
    for i = 1, #collapsibleSections do
        local sec = collapsibleSections[i]
        if sec and sec.section and sec.section.Parent then
            sec.SetExpanded(wantExpanded, false)
        end
    end
    if currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab] then
        pcall(tabCanvasRefreshers[currentActiveTab])
    end
    ShowNotification("折叠面板", tipText, "INFO", 2)
end
createButtonRow(uiCard, "折叠全部分组", "收起所有折叠分组，只保留分组标题，长页面更好翻", "全部折叠", function()
    ApplyAllSectionsExpanded(false, "已收起全部分组")
end)
createButtonRow(uiCard, "展开全部分组", "展开所有折叠分组，恢复默认视图", "全部展开", function()
    ApplyAllSectionsExpanded(true, "已展开全部分组")
end)

local profCard = createCollapsibleGroup(tabProfiles, "配置文件管理")
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

local credCard = createCollapsibleGroup(tabProfiles, "会话操作")
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复所有设置", "卸载", UnloadScript)

-- [性能优化 #5 / 建议 #14] UI 构建完成后仅刷新当前可见标签页 Canvas，其余标签页在 SwitchTab / Visible 变化时按需刷新
-- 刷新当前激活可见标签页的滚动区域高度
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
    if isRunning and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) and TryFavoriteProtectedFish then
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
    -- 触发断线或传送失败后的 3 秒延迟自动重连（带防重入锁）
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

-- 独立存放 3D Highlight 实例的容器（避免挂载在 ScreenGui 下导致移动端渲染状态更新滞后）
local espHighlightFolder = Instance.new("Folder")
espHighlightFolder.Name = "IdenticalESPHighlights"
espHighlightFolder.Parent = Workspace
table.insert(cleanUpInstances, espHighlightFolder)

local activeESP = setmetatable({}, { __mode = "k" })  -- 弱键：实例被 GC 时条目自动消失

local fishRingAnchor = Instance.new("Part")
fishRingAnchor.Name = "FishRingAnchor"
fishRingAnchor.Size = Vector3.new(0.5, 0.5, 0.5)
fishRingAnchor.Transparency = 1
fishRingAnchor.CanCollide = false
fishRingAnchor.CanQuery = false
fishRingAnchor.CanTouch = false
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

-- 为每个目标实例分配稳定且唯一的代理锚点键：同名目标（多艘同名船只、同岛多个神灵模型）不再共用同一个代理 Part
local GetESPProxyKey = (function()
    local proxyIds = setmetatable({}, { __mode = "k" })
    local idCounter = 0
    return function(instance, category, name)
        local id = proxyIds[instance]
        if not id then
            idCounter = idCounter + 1
            id = idCounter
            proxyIds[instance] = id
        end
        return "Proxy_" .. tostring(category) .. "_" .. tostring(id) .. "_" .. tostring(name)
    end
end)()

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

-- 跨全图固定地标定义（仅在对应类别的 ESP 开启时按需挂载，关闭时立即彻底销毁，绝不在后台残留！）
local ESP_STATIC_LANDMARKS = {
    GodSpirit = {
        color = Colors.AccentGreen,
        items = {
            {key = "Landmark_Spirit_Bamboo", name = "竹岛神灵祭坛", pos = Vector3.new(-1223.0, 10.3, -24.1), icon = "⛩️"},
            {key = "Landmark_Spirit_Frost",  name = "冰霜岛神灵祭坛", pos = Vector3.new(-1366.0, 14.9, -1495.4), icon = "❄️"},
            {key = "Landmark_Spirit_Amber",  name = "琥珀岛神灵祭坛", pos = Vector3.new(1259.4, 12.1, 1401.5), icon = "🔥"},
        }
    },
    Boss = {
        color = Colors.AccentRed,
        items = {
            {key = "Landmark_Boss_Enzo",   name = "恩佐 (Enzo Boss竞技场)", pos = Vector3.new(-115.3, 12.2, 1349.5), icon = "👹"},
            {key = "Landmark_Boss_Octo",   name = "无名章鱼寄生体 (隐藏Boss)", pos = Vector3.new(1608.2, 8.0, -218.3), icon = "🐙"},
            {key = "Landmark_Boss_Dragon", name = "龙钓海 Boss挑战区", pos = Vector3.new(2745.2, 13.6, -79.4), icon = "🐉"},
        }
    },
    SecretRod = {
        color = Colors.AccentYellow,
        items = {
            {key = "Landmark_Rod_Anchor",     name = "锚定鱼竿 (主权岛秘密竿)", pos = Vector3.new(-1208.5, 56.3, 1646.2), icon = "🌟"},
            {key = "Landmark_Rod_ShadowCave", name = "火焰鲨鱼竿 / 暗影秘密山洞", pos = Vector3.new(-8.4, 55.9, 6.7), icon = "🌟"},
            {key = "Landmark_Rod_Siren",      name = "海妖鱼竿 (琥珀岛秘密竿)", pos = Vector3.new(1543.8, 73.4, 1490.9), icon = "🌟"},
            {key = "Landmark_Rod_BambooAsc",  name = "升华竹竿 (竹岛高崖秘密竿)", pos = Vector3.new(-1360.6, 140.6, 31.0), icon = "🌟"},
            {key = "Landmark_Rod_LifeBloom",  name = "生命绽放鱼竿 (鲈鱼岛秘密竿)", pos = Vector3.new(-114.9, 74.9, -1533.2), icon = "🌟"},
            {key = "Landmark_Rod_Demon",      name = "恶魔鱼竿 (椰子岛秘密竿)", pos = Vector3.new(1181.9, 82.9, -1243.8), icon = "🌟"},
            {key = "Landmark_Rod_BiaoDi",     name = "世界表弟 (神话鱼竿合成台)", pos = Vector3.new(-151.4, 10.7, -49.9), icon = "🎣"},
        }
    }
}

-- 销毁并移除指定实例关联的 ESP 标签、Highlight 与代理/地标锚点（先切断 Adornee 与 Visible/Enabled 再 Destroy，彻底解决 Delta 端渲染残影）
local function RemoveESP(instance)
    local data = activeESP[instance]
    if data then
        activeESP[instance] = nil
        if data.frame and data.frame.Parent then
            pcall(function() data.frame.Visible = false end)
        end
        if data.gui then
            pcall(function()
                data.gui.Enabled = false
                data.gui.Adornee = nil
                data.gui:Destroy()
            end)
        end
        if data.highlight then
            pcall(function()
                data.highlight.Enabled = false
                data.highlight.Adornee = nil
                data.highlight:Destroy()
            end)
        end
        if (data.isProxyPart or data.isLandmarkAnchor) and data.part and data.part.Parent then
            pcall(function() data.part:Destroy() end)
        end
    end
end

-- 彻底销毁指定类别（或全部已关闭类别）的所有 BillboardGui、Highlight 与锚点实例
local function ClearDisabledCategoryESP(targetCategory)
    local toRemove = {}
    for inst, data in pairs(activeESP) do
        if data then
            local cat = data.espCategory
            local cfgKey = ESP_CATEGORY_KEYS[cat]
            local isCatEnabled = cfgKey and (Config[cfgKey] == true) or false
            if (targetCategory and cat == targetCategory and not isCatEnabled) or (not targetCategory and not isCatEnabled) then
                table.insert(toRemove, inst)
            end
        end
    end
    for i = 1, #toRemove do
        RemoveESP(toRemove[i])
    end
    -- 额外兜底扫描 espFolder 与 espHighlightFolder，确保没有任何脱离 activeESP 追踪的残留组件
    if targetCategory then
        local cfgKey = ESP_CATEGORY_KEYS[targetCategory]
        if cfgKey and not Config[cfgKey] then
            for _, ch in ipairs(espFolder:GetChildren()) do
                if ch:GetAttribute("ESPCategory") == targetCategory then
                    pcall(function()
                        if ch:IsA("BillboardGui") then ch.Enabled = false; ch.Adornee = nil end
                        ch:Destroy()
                    end)
                end
            end
            for _, ch in ipairs(espHighlightFolder:GetChildren()) do
                if ch:GetAttribute("ESPCategory") == targetCategory then
                    pcall(function()
                        if ch:IsA("Highlight") then ch.Enabled = false; ch.Adornee = nil end
                        ch:Destroy()
                    end)
                end
            end
        end
    end
end

-- 为目标实例挂载跨全图穿墙 BillboardGui 标签与 3D Highlight 轮廓高亮（仅当对应 ESP 开关处于开启状态时才创建实例！）
local function AddESP(instance, name, espCategory, color, icon, fallbackPos, isLandmarkAnchor)
    if not instance then return end
    local cfgKey = ESP_CATEGORY_KEYS[espCategory]
    local isEnabledNow = cfgKey and (Config[cfgKey] == true) or false
    -- 核心修复：若该类别的 ESP 开关未开启，绝不创建任何 BillboardGui / Highlight 实例，若已有旧实例则立即销毁！
    if not isEnabledNow then
        if activeESP[instance] then
            RemoveESP(instance)
        end
        return
    end

    local existing = activeESP[instance]
    if existing then
        -- 若同一实例曾被挂载为其它类别（或旧实例已失效），先清理重建
        if existing.espCategory ~= espCategory or not existing.gui or not existing.gui.Parent then
            RemoveESP(instance)
        else
            existing.name = name
            existing.icon = icon or ""
            if fallbackPos and existing.isProxyPart and existing.part and existing.part.Parent then
                existing.part.Position = fallbackPos
            end
            return
        end
    end

    -- 递归查找 BasePart
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
            part = CreateESPAnchorPart(GetESPProxyKey(instance, espCategory, name), pos)
            isProxyPart = true
        end
    end
    if not part then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "ESP_" .. tostring(espCategory) .. "_" .. tostring(name)
    bb:SetAttribute("ESPCategory", espCategory)
    bb.Size = UDim2.new(0, 175, 0, 26)
    bb.StudsOffset = Vector3.new(0, 3.0, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = math.huge
    bb.Enabled = true
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
    lbl.TextTruncate = Enum.TextTruncate.AtEnd

    local hl = nil
    if typeof(instance) == "Instance" and (instance:IsA("Model") or instance:IsA("BasePart")) and not isProxyPart and not isLandmarkAnchor then
        pcall(function()
            hl = Instance.new("Highlight")
            hl.Name = "IdenticalHighlight_" .. tostring(espCategory)
            hl:SetAttribute("ESPCategory", espCategory)
            hl.Adornee = instance
            hl.FillColor = color or Colors.PurpleAccent
            hl.OutlineColor = Colors.TextWhite
            hl.FillTransparency = 0.65
            hl.OutlineTransparency = 0.05
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Enabled = true
            hl.Parent = espHighlightFolder
        end)
    end

    activeESP[instance] = {
        gui = bb,
        frame = f,
        highlight = hl,
        label = lbl,
        part = part,
        isProxyPart = isProxyPart,
        isLandmarkAnchor = (isLandmarkAnchor == true),
        espCategory = espCategory,
        name = name,
        icon = icon or "",
        lastDist = -1
    }
end

-- 按需挂载已开启类别的固定地标锚点
local function MountEnabledStaticLandmarks()
    for cat, group in pairs(ESP_STATIC_LANDMARKS) do
        local cfgKey = ESP_CATEGORY_KEYS[cat]
        if cfgKey and Config[cfgKey] == true then
            for _, lm in ipairs(group.items) do
                local anchor = CreateESPAnchorPart(lm.key, lm.pos)
                AddESP(anchor, lm.name, cat, group.color, lm.icon, lm.pos, true)
            end
        end
    end
end

-- 启动瞬间自动执行一次全图 ProximityPrompt 净化（即使上次旧脚本遗留了 999999 粘滞弹窗也能在 1 秒内立即清除）
task.spawn(function()
    task.wait(0.2)
    if isRunning and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(true)
    end
end)

-- [perf] 已存在的非代理 ESP 条目会忽略 fallbackPos（AddESP 内部只更新名字/图标）
local function ESPFallbackPosFor(inst)
    local entry = activeESP[inst]
    if entry and not entry.isProxyPart then return nil end
    return GetNPCPosition(inst)
end

-- 立即扫描并按需挂载当前已开启类别的动态目标与固定地标 ESP（未开启的类别完全跳过，不创建任何实例）
local function ScanAndMountDynamicESP()
    MountEnabledStaticLandmarks()

    -- 1) 仅在开启「玩家ESP」时扫描全体其他玩家
    if Config.ESP_Players then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                local pChar = p.Character or Workspace:FindFirstChild(p.Name)
                if pChar then
                    AddESP(pChar, p.DisplayName or p.Name, "Players", Colors.PurpleAccent, "👤", ESPFallbackPosFor(pChar))
                end
            end
        end
    end
    -- 2) 按需扫描秘密鱼竿、船只与 Boss 容器
    if Config.ESP_SecretRod then
        for _, srName in ipairs({"SecretRod", "SecretRods", "Rods"}) do
            local srFolder = Workspace:FindFirstChild(srName)
            if srFolder then
                for _, r in ipairs(srFolder:GetChildren()) do AddESP(r, r.Name, "SecretRod", Colors.AccentYellow, "🌟", ESPFallbackPosFor(r)) end
            end
        end
    end
    if Config.ESP_Boats then
        for _, btName in ipairs({"Boat", "Boats", "Vehicles"}) do
            local boatFolder = Workspace:FindFirstChild(btName)
            if boatFolder then
                for _, b in ipairs(boatFolder:GetChildren()) do AddESP(b, b.Name, "Boats", Colors.AccentBlue, "⛵", ESPFallbackPosFor(b)) end
            end
        end
    end
    if Config.ESP_Boss then
        local bossFolder = Workspace:FindFirstChild("BossSetUp")
        if bossFolder then
            for _, b in ipairs(bossFolder:GetChildren()) do AddESP(b, b.Name, "Boss", Colors.AccentRed, "👹", ESPFallbackPosFor(b)) end
        end
    end
    -- 3) 按需挂载 liveNPCs 中已探测到的活跃神灵、道士/茅山/傻子商人与四圣兽
    for _, key in ipairs(liveNPCOrder) do
        local entry = liveNPCs[key]
        if entry and entry.inst and entry.inst.Parent then
            if key:find("^Spirit_") then
                if Config.ESP_GodSpirit then
                    AddESP(entry.inst, entry.name, "GodSpirit", Colors.AccentGreen, entry.icon, entry.pos)
                end
            elseif key == "Taoist" or key == "DumbGuy" then
                if Config.ESP_Taoist then
                    AddESP(entry.inst, entry.name, "Taoist", Colors.AccentOrange, entry.icon, entry.pos)
                end
            elseif key == "Maoshan" then
                if Config.ESP_Maoshan then
                    AddESP(entry.inst, entry.name, "Maoshan", Colors.PurplePrimary, entry.icon, entry.pos)
                end
            else
                if Config.ESP_Boss then
                    AddESP(entry.inst, entry.name, "Boss", Colors.AccentRed, entry.icon, entry.pos)
                end
            end
        end
    end
end

-- 监听新玩家加入与角色重生，仅在 Config.ESP_Players 开启时自动挂载玩家 ESP
do
    local function bindPlayerESPChar(p)
        if p == LocalPlayer then return end
        table.insert(activeConnections, p.CharacterAdded:Connect(function(newChar)
            if not isRunning or not Config.ESP_Players then return end
            task.delay(0.25, function()
                if isRunning and Config.ESP_Players and newChar and newChar.Parent then
                    AddESP(newChar, p.DisplayName or p.Name, "Players", Colors.PurpleAccent, "👤", GetNPCPosition(newChar))
                end
            end)
        end))
    end
    for _, p in ipairs(Players:GetPlayers()) do bindPlayerESPChar(p) end
    table.insert(activeConnections, Players.PlayerAdded:Connect(bindPlayerESPChar))
end

-- 刷新所有已注册 ESP 的显隐状态与实时距离文本（关闭开关时立即销毁对应类别全部 BillboardGui/Highlight 实例，100% 零残留！）
local function RefreshAllESPNow(toggledCategory, toggledState, labelTitle)
    -- 当用户关闭某个 ESP 开关时，立即彻底销毁该类别的所有高亮与标签实例
    if toggledCategory and toggledState == false then
        ClearDisabledCategoryESP(toggledCategory)
    else
        ClearDisabledCategoryESP(nil)
    end

    -- 当用户手动开启任意 ESP 开关时，先立即执行一次全目标扫描挂载
    if toggledCategory and toggledState == true then
        if DashUI._runRadarPassNow and (toggledCategory == "GodSpirit" or toggledCategory == "Maoshan" or toggledCategory == "Taoist" or toggledCategory == "Boss") then
            pcall(DashUI._runRadarPassNow)
        end
        pcall(ScanAndMountDynamicESP)
    end

    local anyESP = Config.ESP_GodSpirit or Config.ESP_SecretRod or Config.ESP_Boats
        or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_Boss or Config.ESP_Players
    if not anyESP then
        ClearDisabledCategoryESP(nil)
        return
    end

    if next(activeESP) == nil then
        pcall(ScanAndMountDynamicESP)
    end
    if next(activeESP) == nil then
        if toggledCategory and toggledState == true and labelTitle then
            ShowNotification(labelTitle, string.format("已开启 %s（当前服暂无该目标，刷新时将自动高亮）！", labelTitle), "WARN", 3.5)
        end
        return
    end

    local currentCamera = Workspace.CurrentCamera or Camera
    local char = LocalPlayer.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    local refPos = (myRoot and myRoot.Position) or (currentCamera and currentCamera.CFrame.Position)
    local activeCountForCat = 0

    for inst, data in pairs(activeESP) do
        local cfgKey = data and ESP_CATEGORY_KEYS[data.espCategory]
        local isEnabled = cfgKey and (Config[cfgKey] == true) or false
        if not inst or not inst.Parent or not isEnabled then
            RemoveESP(inst)
        else
            -- 动态兼容 StreamingEnabled：若目标真实 BasePart 因远距流式卸载变为 nil，自动无缝切换为 ProxyPart；若走近后真实 BasePart 加载完成，自动升级绑回真实零件！
            if data.isProxyPart and not data.isLandmarkAnchor then
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
                    local proxy = CreateESPAnchorPart(GetESPProxyKey(inst, data.espCategory, data.name), fallbackPos)
                    data.part = proxy
                    data.isProxyPart = true
                    if data.gui then data.gui.Adornee = proxy end
                else
                    RemoveESP(inst)
                end
            end

            if activeESP[inst] and data.part and data.part.Parent then
                if data.gui and not data.gui.Enabled then data.gui.Enabled = true end
                if data.highlight and data.highlight.Parent and not data.highlight.Enabled then
                    data.highlight.Enabled = true
                end
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
local dailyMissingWarned = false -- [Bug修复] 每日奖励远程缺失时只提示一次，避免每 5 分钟刷屏
local lastSecretBaitCraftTime = 0
local lastEquipNamelessTime = 0
local lastFullBagWarnTime = 0
local lastGachaTime = 0
local lastBossTime = 0
-- 重置 Boss 自动化检测计时器以立即执行下一轮扫描
DashUI._resetBossTimer = function()
    lastBossTime = 0
end
-- 重置自动卖鱼计时器
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
-- 获取并缓存 Workspace 下的指定顶层文件夹引用
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
-- 获取并缓存 ReplicatedStorage.Events 下的指定远程事件引用
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

-- 关闭自动抛竿时同步更新抛竿计时时间戳
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
-- 快速判断字符串是否包含神灵、商人、四圣兽、Boss 或重点 NPC 的特征关键词
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
        or str:find("doan", 1, true) or str:find("blind", 1, true) or str:find("finger", 1, true) or str:find("shi xing", 1, true) or str:find("monkey", 1, true)
        or str:find("skill", 1, true) or str:find("upgrade", 1, true) or str:find("曾天国", 1, true) or str:find("楚依旧", 1, true) or str:find("技能", 1, true)) ~= nil
end
-- 判断 Workspace 顶层子节点是否可能为动态刷新的 NPC、神灵祭坛或 Boss 实体
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
-- 解析并缓存当前已勾选且按自定义顺序排列的技能按键数组 (Z/X/C/V)
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
    -- [稳定性修复] 微瞬移锁超时自愈：持有超过 12s 视为协程已被异常中断，强制释放
    if isMicroTeleportingNPC and microTeleportLockAt > 0 and (now - microTeleportLockAt > 12) then
        isMicroTeleportingNPC = false
        microTeleportLockAt = 0
    end
    -- [性能优化 #13] 移除此处未使用的 Humanoid 查找，仅校验 root 即可
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local pData = cachedPData or GetPlayerData()
    local isFishing = attrFishing
    local isMinigame = wasInMinigame or attrMinigame or cachedIsHooked
        or (cachedFUI and cachedFUI.Visible)
        or (cachedBossBar and cachedBossBar.Visible)

    -- 当用户开启了「自动收藏并防卖」/「自动卖鱼」/「自动保护Boss鱼」/「材料收集模式」任意一项时，后台持续扫描为新入包保护鱼单次上锁
    if (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) and (lastProtectTime == 0 or (now - lastProtectTime >= 1.2)) and pData then
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
                dailyMissingWarned = false
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
            elseif not dailyMissingWarned then
                -- [Bug修复] 原实现完全静默，玩家会误判为功能失效；这里每次注入只提示一次
                dailyMissingWarned = true
                ShowNotification("每日奖励", "当前服务器未找到每日奖励远程事件，自动领取已跳过。", "WARN", 4)
            end
        end
    end

    if Config.AutoCraftBait and (now - lastCraftTime >= 10.0) then
        lastCraftTime = now
        local craftRem = Events and Events:FindFirstChild("CraftBait")
        if craftRem then
            pcall(function() craftRem:FireServer(Config.CraftBaitName, Config.CraftAmount) end)
        end
    end

    if Config.AutoBuyBait and (now - lastBaitBuyTime >= math.max(5, tonumber(Config.BuyBaitDelay) or 30)) then
        lastBaitBuyTime = now
        if pData and pData:FindFirstChild("Bait") and Events and Events:FindFirstChild("BuyBait") then
            local bFolder = pData.Bait:FindFirstChild(Config.BuyBaitName)
            local currentAmount = bFolder and bFolder.Value or 0
            if currentAmount < Config.BuyBaitThreshold then
                local buyRem = Events and Events:FindFirstChild("BuyBait")
                if buyRem then
                    pcall(function() buyRem:FireServer(Config.BuyBaitName, Config.BuyBaitAmount) end)
                end
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
    Vector3.new(-2404.5, 7.6, -202.4),  -- [11] 世界钓鱼岛
    Vector3.new(-2908.1, 6.8, 1191.2),  -- [12] 天气之岛
    Vector3.new(-2648.0, 6.8, -1322.1), -- [13] 神秘珊瑚礁岛
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

        -- 3) 三个神灵分岛精准识别（排除码头生成船只 Chu Xin、传送路标 Location、鱼竿与常规商人，严防误判为神灵！）
        local isBoatOrWaypoint = (nLow:find("^location%d*") ~= nil or nLow:find("boat", 1, true) ~= nil or nLow:find("chu xin", 1, true) ~= nil
            or nLow:find("spawn", 1, true) ~= nil or matchStr:find("生成船只", 1, true) ~= nil or matchStr:find("spawn boat", 1, true) ~= nil)
        if not isMerchant and not matchedAnyBeast and not isBoatOrWaypoint then
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
                    OnlineNPCs[spKey] = { instance = npc, pos = pos, time = now }
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

        -- 5) 同步更新通用 NPC 雷达缓存 OnlineNPCs（校验岛屿距离半径，防止同名/同别名 NPC 跨岛互相污染缓存）
        for _, spec in ipairs(ImportantDialogueNPCs) do
            if DoesInstanceMatchNPCSpec(npc, spec) then
                local anchor = spec.preferPos or spec.fallbackPos
                local nearOk = (not anchor) or ((pos - anchor).Magnitude < 650)
                if not nearOk and spec.altPositions then
                    for _, ap in ipairs(spec.altPositions) do
                        if (pos - ap).Magnitude < 650 then nearOk = true; break end
                    end
                end
                if nearOk then
                    foundOnlinePass[spec.internalName] = true
                    OnlineNPCs[spec.internalName] = { instance = npc, pos = pos, time = now }
                end
            end
        end
    end

    -- 扫描全部 NPC、神灵祭坛与 Boss 专用容器（支持 3 层子结构遍历）
    -- [冗余清理] 与 FindNPCInstancesBySpec 共用同一份目录名单常量
    for _, folderName in ipairs(NPC_SCAN_CONTAINER_NAMES) do
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

-- 立即手动执行一次全图深度雷达扫描
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

        -- 1) 0.15s ESP 距离与开关轻量刷新（当全部 ESP 关闭但仍有残留条目时立即执行一次彻底清理）
        if not powerSave and (now - lastEspRefreshTick >= 0.15) then
            lastEspRefreshTick = now
            local anyESP = Config.ESP_GodSpirit or Config.ESP_SecretRod or Config.ESP_Boats
                or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_Boss or Config.ESP_Players
            if next(activeESP) ~= nil then
                if anyESP then
                    pcall(RefreshAllESPNow)
                else
                    pcall(ClearDisabledCategoryESP, nil)
                end
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
        -- [perf] 属性写去重：RenderStepped 每帧都会进来，写相同值仍会跨 C++ 边界并触发 Gui 布局重算
        if Config.AnchorBar then
            if cachedBarInner and cachedBarInner.Parent and cachedBarInner.Position ~= UDIM2_CENTER then
                cachedBarInner.Position = UDIM2_CENTER
            end
            if cachedProgBarInner and cachedProgBarInner.Parent and cachedProgBarInner.Size ~= UDIM2_FULL then
                cachedProgBarInner.Size = UDIM2_FULL
            end
        end
        if (Config.AutoEnzoMinigame or Config.OctoAutoMinigame or Config.AnchorBar) and bossBar and bossBar.Visible then
            local bBar = cachedBossBarInner
            local bHit = cachedBossHitbox
            if bBar and bHit and bBar.Parent and bHit.Parent then
                local hitPos = bHit.Position
                if bBar.Position ~= hitPos then bBar.Position = hitPos end
                local hitRot = bHit.Rotation
                if hitRot and bBar.Rotation ~= hitRot then bBar.Rotation = hitRot end
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
    -- [perf] Humanoid 仅飞行分支需要；未开飞行时不再每帧 FindFirstChildOfClass
    local hum = nil

    if Config.FlyEnabled then
        flyWasActive = true
        hum = char:FindFirstChildOfClass("Humanoid")
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
        local humRestore = char:FindFirstChildOfClass("Humanoid")
        if humRestore then
            local saved = originalHumanoidState[humRestore]
            humRestore.PlatformStand = saved and saved.PlatformStand or false
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
    elseif rName == "ReplicateFishCaught" or rName == "NotifyFish" then
        -- 监听抓包确认的钓鱼入包通知事件（ReplicateFishCaught / NotifyFish），鱼入包后 0.2s 与 0.8s 立即触发保护鱼自动上锁
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.AutoProtectRareBossFish or Config.AutoSell) then return end
            task.delay(0.2, function()
                if isRunning and TryFavoriteProtectedFish then
                    pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
                end
            end)
            task.delay(0.8, function()
                if isRunning and TryFavoriteProtectedFish then
                    pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
                end
            end)
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

ShowNotification("FSY V1.8", "脚本已加载完成！点击右上角 [FSY] 收起为静态悬浮球；【界面设置】可切换主题颜色", "SUCCESS", 4.5)
