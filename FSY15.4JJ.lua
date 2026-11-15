print("[FSY][BOOT] 0/5 脚本开始执行")
local sharedEnv = nil
if type(getgenv) == "function" then
    local envOk, envValue = pcall(getgenv)
    if envOk and type(envValue) == "table" then sharedEnv = envValue end
end
if sharedEnv then
    sharedEnv.IdenticalFishingBootToken = (tonumber(sharedEnv.IdenticalFishingBootToken) or 0) + 1
    if type(sharedEnv.IdenticalHeavyweightFishingUnload) == "function" then
        pcall(sharedEnv.IdenticalHeavyweightFishingUnload)
    end
end
local myBootToken = sharedEnv and sharedEnv.IdenticalFishingBootToken or nil
if not game:IsLoaded() then
    local loadedDeadline = tick() + 20
    while not game:IsLoaded() and tick() < loadedDeadline do task.wait(0.2) end
end
if sharedEnv and myBootToken and sharedEnv.IdenticalFishingBootToken ~= myBootToken then
    return
end
if sharedEnv and type(sharedEnv.IdenticalHeavyweightFishingUnload) == "function" then
    pcall(sharedEnv.IdenticalHeavyweightFishingUnload)
end
local function SafeGetService(serviceName)
    local ok, svc = pcall(function() return game:GetService(serviceName) end)
    return ok and svc or nil
end
local Players = SafeGetService("Players") or game:GetService("Players")
local Workspace = SafeGetService("Workspace") or workspace
local ReplicatedStorage = SafeGetService("ReplicatedStorage") or game:GetService("ReplicatedStorage")
local RunService = SafeGetService("RunService") or game:GetService("RunService")
local UserInputService = SafeGetService("UserInputService") or game:GetService("UserInputService")
local TweenService = SafeGetService("TweenService") or game:GetService("TweenService")
local HttpService = SafeGetService("HttpService")
local TeleportService = SafeGetService("TeleportService")
local Lighting = SafeGetService("Lighting")
local CoreGui = SafeGetService("CoreGui")
local Stats = SafeGetService("Stats")
local originalLightingState = {}
if Lighting then
    local okLS, ls = pcall(function()
        return {
            Brightness = Lighting.Brightness,
            ClockTime = Lighting.ClockTime,
            FogEnd = Lighting.FogEnd,
            FogStart = Lighting.FogStart,
            GlobalShadows = Lighting.GlobalShadows,
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
        }
    end)
    if okLS and type(ls) == "table" then originalLightingState = ls end
end
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
    if not Lighting then return end
    if originalLightingState.FogEnd ~= nil then Lighting.FogEnd = originalLightingState.FogEnd end
    if originalLightingState.FogStart ~= nil then Lighting.FogStart = originalLightingState.FogStart end
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
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local lpDeadline = tick() + 15
    while not Players.LocalPlayer and tick() < lpDeadline do task.wait(0.1) end
    LocalPlayer = Players.LocalPlayer
end
if sharedEnv and myBootToken and sharedEnv.IdenticalFishingBootToken ~= myBootToken then
    return
end
local Camera = Workspace.CurrentCamera
local gameGuiEnabledBackup = {}
local function SetGameUIHidden(hidden)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, guiName in ipairs({"MainGui", "Fisher_GUI"}) do
        local gui = pg:FindFirstChild(guiName)
        if gui and gui:IsA("ScreenGui") then
            if hidden then
                if originalGameGuiState[gui] == nil then
                    originalGameGuiState[gui] = gui.Enabled
                    gameGuiEnabledBackup[guiName] = gui.Enabled
                end
                gui.Enabled = false
            else
                local saved = gameGuiEnabledBackup[guiName]
                if saved == nil then saved = originalGameGuiState[gui] end
                if saved ~= nil then gui.Enabled = saved end
                gameGuiEnabledBackup[guiName] = nil
                originalGameGuiState[gui] = nil
            end
        end
    end
end
local isRunning = true
local activeConnections = {}
local activeDragConns = {}
local activeThreads = setmetatable({}, { __mode = "k" })
local activeSliderCleanupFns = {}
local pressedVirtualKeys = {}
local task = (function()
    local rawSpawn, rawDelay, rawWait, rawDefer, rawCancel = task.spawn, task.delay, task.wait, task.defer, task.cancel
    local unpackFn = table.unpack or unpack
    return {
        wait = rawWait,
        defer = function(fn, ...)
            if not isRunning or type(fn) ~= "function" then return nil end
            local args = table.pack(...)
            local th
            th = rawDefer(function()
                if th then activeThreads[th] = nil end
                if isRunning then
                    fn(unpackFn(args, 1, args.n))
                end
            end)
            if isRunning and th then activeThreads[th] = true end
            return th
        end,
        cancel = rawCancel,
        spawn = function(fn, ...)
            if not isRunning or type(fn) ~= "function" then return nil end
            local args = table.pack(...)
            local th
            th = rawSpawn(function()
                if isRunning then
                    fn(unpackFn(args, 1, args.n))
                end
                if th then activeThreads[th] = nil end
            end)
            if isRunning and th then activeThreads[th] = true end
            return th
        end,
        delay = function(sec, fn, ...)
            if not isRunning or type(fn) ~= "function" then return nil end
            local args = table.pack(...)
            local th
            th = rawDelay(sec, function()
                if th then activeThreads[th] = nil end
                if isRunning then
                    fn(unpackFn(args, 1, args.n))
                end
            end)
            if isRunning and th then activeThreads[th] = true end
            return th
        end,
    }
end)()
local function RegisterTempDragConn(conn)
    if conn then activeDragConns[conn] = true end
    return conn
end
local function DisconnectTempDragConn(conn)
    if conn then
        activeDragConns[conn] = nil
        pcall(function() conn:Disconnect() end)
    end
    return nil
end
local LowerInstNameG
local FLog, FLogWarn, FLogErr, SafeStep, SafeConnect
do
local FLOG_BUFFER_SIZE = 120
local FLogBuffer = {}
local FLogSuppressed = {}
local function FLogEmit(level, tag, msg)
    local cfgTable = sharedEnv and sharedEnv.IdenticalFishingConfig
    if level ~= "ERROR" and (not cfgTable or cfgTable.DebugLog ~= true) then return end
    local key = tostring(level) .. "|" .. tostring(tag)
    local now = tick()
    local rec = FLogSuppressed[key]
    if rec and (now - rec.at) < 2.0 then
        rec.skipped = rec.skipped + 1
        return
    end
    local skipped = rec and rec.skipped or 0
    FLogSuppressed[key] = { at = now, skipped = 0 }
    local line = string.format("[FSY][%s][%s] %s", tostring(level), tostring(tag), tostring(msg))
    if skipped > 0 then
        line = line .. string.format("（同标签另有 %d 条同类日志已合并）", skipped)
    end
    FLogBuffer[#FLogBuffer + 1] = line
    if #FLogBuffer > FLOG_BUFFER_SIZE then table.remove(FLogBuffer, 1) end
    if level == "INFO" then print(line) else warn(line) end
end
FLog = function(tag, msg) FLogEmit("INFO", tag, msg) end
FLogWarn = function(tag, msg) FLogEmit("WARN", tag, msg) end
FLogErr = function(tag, err) FLogEmit("ERROR", tag, tostring(err)) end
SafeStep = function(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then FLogErr(tag, err) end
    return ok
end
SafeConnect = function(tag, fn)
    return function(...)
        if not isRunning then return end
        SafeStep(tag, fn, ...)
    end
end
if sharedEnv then
    sharedEnv.IdenticalFishingDumpLogs = function()
        return table.concat(FLogBuffer, "\n")
    end
end
end
local function Utf8SafeCut(s, maxBytes)
    if type(s) ~= "string" or not maxBytes or maxBytes <= 0 then return "" end
    if #s <= maxBytes then return s end
    local cut = maxBytes
    local guard = 0
    while cut > 0 and guard < 4 do
        local b = string.byte(s, cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
        guard = guard + 1
    end
    if cut <= 0 then return "" end
    return s:sub(1, cut)
end
local activeQuickTweens = setmetatable({}, { __mode = "k" })
local FSYC = {}
FSYC.FAST_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FSYC.Tunables = {
    PacketDefaultWindowMs = 40,
    PacketCombatWindowMs = 10,
    PacketSweepInterval = 512,
    InvokeDefaultTimeoutSec = 4.0,
    RemoteBackoffBaseSec = 0.50,
    RemoteBackoffMaxSec = 1.20,
    CombatBackoffBaseSec = 0.10,
    CombatBackoffMaxSec = 0.35,
    CombatFreshTtlSec = 0.50,
    GateFightExitGraceSec = 0.80,
    GateActiveExitGraceSec = 0.40,
    GateQuietAfterExitSec = 0.25,
    GateWarnBlockStreakSec = 6.0,
    GateMaxGhostFightSec = 240.0,
    SkillExitGraceSec = 1.5,
    SkillRetryDelaySec = 0.4,
    SkillMaxSlotFails = 3,
    SkillMinGapSec = 0.12,
    SkillPanicHpRatio = 0.35,
    SkillReenterLockSec = 5.0,
    SkillStrongMinSec = 0.5,
    SkillMaxWeakFightSec = 90.0,
    RealBossHardGapSec = 0.50,
    RealBossMaxSends = 500,
    RealBossMaxDurationSec = 200.0,
    RealBossMissHeartbeatSec = 2.5,
    RealBossRetryBaseSec = 0.08,
    RealBossRetryMaxSec = 1.00,
    LockSettlingWindowSec = 2.0,
    EquipCheckIntervalSec = 5.0,
    DailyAutoIntervalSec = 300.0,
    CraftAutoIntervalSec = 10.0,
    MonkeyGiveIntervalSec = 4.0,
    UndergroundYThreshold = -50.0,
    RhythmMinGapSec = 0.30,
    ObsSkillDedupSec = 0.20,
    ObsCdMinGapSec = 1.0,
    ObsCdMaxGapSec = 300.0,
    EspPoolSize = 64,
    CustomTpMaxRows = 100,
    NotifMaxCards = 4,
}
FSYC.Protocol = {
    EventFolderCandidates = {"Events", "Remotes", "RemoteEvents", "Network"},
    DataFolderCandidates = {"Data", "PlayerData", "PlayersData"},
    SlamActionPerfect = "Perfect",
    MinigameInBar = "In bar",
    SessionEndKeywords = {
        ["sessionend"] = true,
        ["end"] = true,
        ["stop"] = true,
        ["finish"] = true,
        ["close"] = true,
    },
    Remotes = {
        Fishing = "Fishing",
        FishingMinigame = "FishingMinigame",
        Slam = "Slam",
        Charge = "Charge",
        CastSkill = "CastSkill",
        SellFish = "SellFish",
        CraftBait = "CraftBait",
        BuyBait = "BuyBait",
        EquipBait = "EquipBait",
        EquipFishingRod = "EquipFishingRod",
        EquipOrb = "EquipOrb",
        BossPhase2Setup = "BossPhase2Setup",
        BossPhase2Action = "BossPhase2Action",
        NotifyDamage = "NotifyDamage",
    },
}
FSYC.Locations = {
    EnzoArena = Vector3.new(-115.3, 12.2, 1349.5),
    OctoParasite = Vector3.new(1608.2, 8.0, -218.3),
    DragonSea = Vector3.new(2745.2, 13.6, -79.4),
}
FSYC.ResolveEventsFolder = function(repStorage, waitSec)
    if not repStorage then return nil end
    local candidates = FSYC.Protocol and FSYC.Protocol.EventFolderCandidates or {"Events", "Remotes", "RemoteEvents", "Network"}
    for i = 1, #candidates do
        local folder = repStorage:FindFirstChild(candidates[i])
        if folder then return folder end
    end
    if waitSec and waitSec > 0 then
        local okEv, evObj = pcall(function() return repStorage:WaitForChild(candidates[1], waitSec) end)
        if okEv and evObj then return evObj end
        for i = 2, #candidates do
            local folder = repStorage:FindFirstChild(candidates[i])
            if folder then return folder end
        end
    end
    return nil
end
local function PlayQuickTween(inst, props, tweenInfo)
    if not inst or not isRunning then return nil end
    local prev = activeQuickTweens[inst]
    if prev then
        activeQuickTweens[inst] = nil
        pcall(prev.Cancel, prev)
    end
    local alreadyThere = true
    for k, v in pairs(props) do
        if inst[k] ~= v then
            alreadyThere = false
            break
        end
    end
    if alreadyThere then return nil end
    local ok, tw = pcall(TweenService.Create, TweenService, inst, tweenInfo or FSYC.FAST_TWEEN_INFO, props)
    if ok and tw then
        activeQuickTweens[inst] = tw
        pcall(tw.Play, tw)
        return tw
    end
    return nil
end
local attrCharConn = nil
local cameraViewportConn = nil
local UpdateMainFrameScale, BindCameraViewportSignal
do
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
local currentlyOpenDropdown = nil
local HRand = function(base, span)
    base = tonumber(base) or 0
    span = tonumber(span) or 0
    if base < 0 then base = 0 end
    if span <= 0 then return base end
    local r = math.random()
    if type(r) ~= "number" or r ~= r then return base end
    return base + r * span
end
local HRandomWait = function(base, span)
    task.wait(HRand(base, span))
end
local function IsInstanceValid(inst)
    if typeof(inst) ~= "Instance" or inst.Parent == nil then return false end
    local ok, inside = pcall(inst.IsDescendantOf, inst, game)
    return ok and inside == true
end
local GetPlayerData
do
local cachedDataContainer = nil
local cachedPlayerDataNode = nil
local warnedMissingDataRoot = false
GetPlayerData = function()
    if IsInstanceValid(cachedPlayerDataNode) then
        return cachedPlayerDataNode
    end
    cachedPlayerDataNode = nil
    if not LocalPlayer then return nil end
    local uidStr = tostring(LocalPlayer.UserId)
    if IsInstanceValid(cachedDataContainer) then
        local found = cachedDataContainer:FindFirstChild(uidStr) or cachedDataContainer:FindFirstChild(LocalPlayer.Name)
        if found then
            cachedPlayerDataNode = found
            return found
        end
    end
    local dataCandidates = FSYC.Protocol and FSYC.Protocol.DataFolderCandidates or {"Data", "PlayerData", "PlayersData"}
    for _, folderName in ipairs(dataCandidates) do
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
    for _, localFolderName in ipairs(dataCandidates) do
        local localData = LocalPlayer:FindFirstChild(localFolderName)
        if localData and (localData:FindFirstChild("Inventory") or localData:FindFirstChild("Cash")) then
            cachedPlayerDataNode = localData
            return localData
        end
    end
    if not warnedMissingDataRoot then
        warnedMissingDataRoot = true
        FLogWarn("数据", "尚未找到 ReplicatedStorage 下的玩家数据节点，等待角色数据加载...")
    end
    return nil
end
end
local characterConnections = {}
local originalHumanoidState = setmetatable({}, {__mode = "k"})
local function RememberHumanoidState(hum)
    if hum and not originalHumanoidState[hum] then
        originalHumanoidState[hum] = {
            WalkSpeed = hum.WalkSpeed,
            PlatformStand = hum.PlatformStand,
        }
    end
end
local cachedFishConstraint = nil
FSYC.lastConstraintSearch = 0
print("[FSY][BOOT] 1/5 配置表与协议常量就绪")
local Events = FSYC.ResolveEventsFolder(ReplicatedStorage, 10)
if not Events then
    FLogWarn("启动", "10 秒内未找到远程事件容器 (Events/Remotes)；已交由统一延迟加载监听，就绪后自动恢复")
end
local FSY_VERSION = "V15.3"
local Config = {
    UIScale = 0.85,
    UITheme = "薄荷翠绿",
    UIGroupState = {},
    DeviceMode = "自动",
    InputIsolation = true,
    InputDedupeMs = 600,
    PacketDedupeMs = 40,
    DebugLog = false,
    FishingGate = true,
    FishingGateLoose = false,
    AutoCast = false,
    CastDelay = 1.0,
    CastPower = 100,
    PositionLock = false,
    AnchorBar = true,
    AutoSlam = true,
    AutoCharge = true,
    InstantCatch = true,
    AutoSkills = false,
    SkillZ = true,
    SkillX = true,
    SkillC = true,
    SkillV = true,
    SkillOrder = "Z,X,C,V",
    SkillInterval = 1.5,
    SkillStrict = false,
    SkillOrderMode = "优先(Z→X→C→V)",
    SkillFirstInstant = true,
    SkillStartDelay = 2.5,
    SkillCooldown = 30,
    SkillCdZ = 3, SkillCdX = 21, SkillCdC = 5, SkillCdV = 5,
    SkillCdProbe = true,
    _cdZFixed = false,
    SkillChannel = "自动",
    SkillPanicKey = "关闭",
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
    RodMaterialFarming = false,
    FavouriteFishName = "Colossal Tigerfish",
    CustomProtectedFish = "Colossal Tigerfish",
    FavPacketMode = "鱼名+后缀(Name | Favorite)",
    MaterialFarming = false,
    OctoAutoMinigame = false,
    RhythmBeatSec = 0.34,
    RhythmAccuracy = 100,
    RealBossHit = false,
    RealBossGap = 0.75,
    RealBossForce = false,
    RealBossHitRate = 85,
    ForceFishBtn = false,
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
    BuyBaitThreshold = 10,
    BuyBaitDelay = 5,
    AutoGacha = false,
    GachaBanner = "太极卡池",
    GachaPullsPerAction = 1,
    ESP_GodSpirit = false,
    ESP_Boats = false,
    ESP_Maoshan = false,
    ESP_Taoist = false,
    ESP_DumbGuy = false,
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
    ["Hard"] = "Hard",
    ["Dễ"] = "Easy",
    ["Thường"] = "Easy",
    ["Khó"] = "Hard",
    ["Simple"] = "Easy",
    ["Normal"] = "Easy",
    ["普通"] = "Easy",
    ["噩梦"] = "Hard",
    ["Nightmare"] = "Hard",
    ["Ác Mộng"] = "Hard",
    ["Khó Khăn"] = "Hard",
    ["Bình thường"] = "Easy",
}
FSYC.GachaBannerMap = {
    ["太极卡池"] = "Taiji Banner",
    ["无我卡池"] = "Selflessness Banner",
    ["Taiji Banner"] = "Taiji Banner",
    ["Selflessness Banner"] = "Selflessness Banner",
    ["Vòng Quay Thái Cực"] = "Taiji Banner",
    ["Vòng Quay Vô Ngã"] = "Selflessness Banner",
    ["Thái Cực"] = "Taiji Banner",
    ["Vô Ngã"] = "Selflessness Banner",
}
local Capabilities = {
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
        local unpackArgs = table.unpack or unpack
        local hookOk, hookErr = pcall(function()
            if type(preSavedNamecall) ~= "function" and not (sharedEnv and sharedEnv.IdenticalOldNamecall) then
                return
            end
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
                        local assistActive = cfg.AnchorBar or cfg.OctoAutoMinigame
                        local okName, rName = pcall(getInstanceName, self)
                        if okName and type(rName) == "string" then
                            local combatFresh = sharedEnv
                                and sharedEnv.IdenticalCombatActive == true
                                and type(sharedEnv.IdenticalCombatActiveAt) == "number"
                                and (tick() - sharedEnv.IdenticalCombatActiveAt) <= (FSYC.Tunables and FSYC.Tunables.CombatFreshTtlSec or 0.5)
                            if rName == "UpdateFishProgression" then
                                if sharedEnv then sharedEnv.IdenticalLastProgressionAt = tick() end
                            elseif rName == (FSYC.Protocol and FSYC.Protocol.Remotes.FishingMinigame or "FishingMinigame") and assistActive then
                                local args = table.pack(...)
                                local action = tostring(args[1])
                                if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar", 1, true) or action:find("Fail", 1, true) or action:find("Miss", 1, true) then
                                    return orig(self, FSYC.Protocol and FSYC.Protocol.MinigameInBar or "In bar", unpackArgs(args, 2, args.n))
                                end
                            elseif (rName == (FSYC.Protocol and FSYC.Protocol.Remotes.Slam or "Slam") or rName:find("Slam", 1, true)) and cfg.AutoSlam
                                and combatFresh then
                                local firstArg = select(1, ...)
                                local firstStr = firstArg ~= nil and tostring(firstArg):lower() or ""
                                if firstArg == nil or firstArg == false or firstStr:find("miss", 1, true) or firstStr:find("fail", 1, true) or firstStr:find("bad", 1, true) then
                                    return orig(self, FSYC.Protocol and FSYC.Protocol.SlamActionPerfect or "Perfect")
                                end
                            elseif rName ~= "RhythmHit" and (rName:find("Rhythm", 1, true) or rName:find("QTE", 1, true) or rName:find("Octo", 1, true)) and (cfg.OctoAutoMinigame or cfg.AutoSlam)
                                and combatFresh then
                                local args = table.pack(...)
                                local firstArg = args[1]
                                local firstStr = firstArg ~= nil and tostring(firstArg):lower() or ""
                                if firstArg == nil or firstArg == false or firstStr:find("miss", 1, true) or firstStr:find("fail", 1, true) or firstStr:find("bad", 1, true) then
                                    args[1] = (type(firstArg) == "boolean") and true or (FSYC.Protocol and FSYC.Protocol.SlamActionPerfect or "Perfect")
                                    if args[2] == nil or type(args[2]) == "number" then args[2] = 100 end
                                    return orig(self, unpackArgs(args, 1, math.max(args.n, 2)))
                                end
                            elseif rName == "Charge" and cfg.AutoCharge and combatFresh then
                                local args = {...}
                                if args[1] == nil or (type(args[1]) == "number" and args[1] < 100) then
                                    return orig(self, 100)
                                end
                            elseif (rName == "SellFish" or rName == "SellItem" or rName == "SellAll") and sharedEnv then
                                if sharedEnv.IdenticalIsSellArgBlocked == nil then
                                    return orig(self, ...)
                                end
                                local args = table.pack(...)
                                if type(sharedEnv.IdenticalIsSellArgBlocked) ~= "function" then
                                    return nil
                                end
                                if rName == "SellAll" or args.n == 0 then
                                    local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, "All")
                                    if (not okCheck) or isBlocked then return nil end
                                else
                                    for aIdx = 1, args.n do
                                        local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, args[aIdx])
                                        if (not okCheck) or isBlocked then return nil end
                                    end
                                end
                            elseif (rName == "FavoriteItem" or rName == "FavouriteItem" or rName == "FavoriteFish" or rName == "FavouriteFish"
                                or rName == "LockFish" or rName == "LockItem" or rName == "Lock" or rName == "Favorite" or rName == "Favourite") then
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
                FLogErr("Hook", "未能取得原始 __namecall，namecall 直通可能失效")
            end
        end)
        if not hookOk then
            FLogWarn("Hook", "Hook 安装失败，已跳过可选 Hook：" .. tostring(hookErr))
        end
    elseif not Capabilities.Hook then
        FLogWarn("Hook", "当前执行器缺少完整 Hook API，已跳过 Hook；主界面仍会继续加载。")
    else
        FLogWarn("Hook", "本会话已安装过旧版钩子，为避免执行器闪退本次不重装；如需让新的钩子逻辑生效，请重启游戏后再注入。")
    end
end
print("[FSY][BOOT] 2/5 执行器能力探测与 namecall 钩子处理完成")
local SaveProfile, SyncUIWithConfig, LoadProfile, LoadCustomTPs, SaveCustomTPs
local RestoreNativeGameHud, RealBossDeactivate, SweepOrphanSlots, FishGate
local CustomTPs = {}
local blackOutFrame, mainFrameScale, ApplyLightingSettings
local DashUI = {}
do
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
RestoreNativeGameHud = function()
    if Config and Config.HideGameUI then return false end
    if not LocalPlayer then return false end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end
    local restored = 0
    for _, guiName in ipairs({"MainGui", "Fisher_GUI"}) do
        local gui = pg:FindFirstChild(guiName)
        if gui and gui:IsA("ScreenGui") then
            local saved = gameGuiEnabledBackup[guiName]
            if saved == nil then saved = originalGameGuiState[gui] end
            if saved ~= nil then
                if gui.Enabled ~= saved then gui.Enabled = saved end
                gameGuiEnabledBackup[guiName] = nil
                originalGameGuiState[gui] = nil
                restored = restored + 1
            end
        end
    end
    return restored > 0
end
local ConfigNumericBounds = {
    UIScale = {0.5, 1.2}, CastDelay = {0.1, 10}, CastPower = {0, 100},
    SkillInterval = {0.5, 5}, SellInterval = {10, 3600}, DailyClaimDelay = {0.3, 2},
    SkillStartDelay = {0.5, 10}, SkillCooldown = {1, 999},
    SkillCdZ = {1, 999}, SkillCdX = {1, 999}, SkillCdC = {1, 999}, SkillCdV = {1, 999},
    CraftAmount = {1, 10}, BuyBaitThreshold = {5, 50},
    BuyBaitDelay = {5, 3600}, GachaPullsPerAction = {1, 10},
    MonkeyGiveCount = {10, 500},
    RhythmAccuracy = {85, 100},
    InputDedupeMs = {200, 1000}, PacketDedupeMs = {0, 200},
    RealBossHitRate = {1, 100}, RealBossGap = {0.30, 2.0},
    RhythmBeatSec = {0.30, 1.0},
}
local ValidConfigEnums = {
    UITheme = {["薄荷翠绿"] = true, ["冰川天蓝"] = true, ["极光青碧"] = true, ["流光琥珀"] = true, ["珊瑚绯红"] = true},
    DeviceMode = {["自动"] = true, ["手机"] = true, ["电脑"] = true},
    TicketDifficulty = QuestDiffMap,
    GachaBanner = FSYC.GachaBannerMap,
    SkillChannel = {["自动"] = true, ["屏幕按钮"] = true, ["远程事件"] = true, ["模拟按键"] = true, ["兼容(三通道全开)"] = true},
    SkillPanicKey = {["关闭"] = true, ["Z"] = true, ["X"] = true, ["C"] = true, ["V"] = true},
    SkillOrderMode = {["优先(Z→X→C→V)"] = true, ["顺位优先(谁好放谁)"] = true, ["盲轮转(按顺序点)"] = true, ["严格轮流(等冷却)"] = true},
    FavPacketMode = {
        ["鱼名+后缀(Name | Favorite)"] = true, ["仅完整鱼名(item.Name)"] = true,
        ["仅实例对象(item)"] = true, ["智能探测(自动对比状态)"] = true, ["动作+鱼名(Favorite+Name)"] = true,
    },
}
local function SanitizeConfigValue(key, value, defaultValue)
    if type(value) ~= type(defaultValue) then return defaultValue end
    local bounds = ConfigNumericBounds[key]
    if bounds and type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return defaultValue end
        return math.clamp(value, bounds[1], bounds[2])
    end
    if type(value) == "string" then
        local maxLen = (key == "CustomProtectedFish") and 900 or 256
        if #value > maxLen then
            if key ~= "CustomProtectedFish" then return defaultValue end
            value = Utf8SafeCut(value, maxLen)
        end
        if key == "ActiveProfile" then return NormalizeProfileName(value) end
        if key == "SkillOrder" then
            local clean = value:gsub("[^ZzXxCcVv,%s;|/]", ""):gsub("%s+", ""):upper():sub(1, 16)
            return (clean ~= "") and clean or defaultValue
        end
        if ValidConfigEnums[key] then
            return ValidConfigEnums[key][value] and value or defaultValue
        end
        if key ~= "CustomProtectedFish" and (value:match("^%s*$") ~= nil) then
            return defaultValue
        end
    end
    return value
end
DashUI._readValueBase = function(inst, defaultVal)
    if typeof(inst) ~= "Instance" or not inst.Parent then return defaultVal end
    if inst:IsA("ValueBase") then return inst.Value end
    local sub = inst:FindFirstChild("Value") or inst:FindFirstChild("Quantity") or inst:FindFirstChild("Amount")
    if sub and sub:IsA("ValueBase") then return sub.Value end
    return defaultVal
end
DashUI._getBaitQty = function(pData, baitName)
    if not pData or not pData.Parent or not baitName or baitName == "" then return 0 end
    local baitInv = pData:FindFirstChild("Bait")
    local bNode = baitInv and baitInv:FindFirstChild(baitName)
    if not bNode then return 0 end
    if bNode:IsA("ValueBase") then return tonumber(bNode.Value) or 0 end
    local qObj = bNode:FindFirstChild("Quantity") or bNode:FindFirstChild("Count") or bNode:FindFirstChild("Amount") or bNode:FindFirstChild("Value")
    if qObj and qObj:IsA("ValueBase") then return tonumber(qObj.Value) or 0 end
    return tonumber(bNode:GetAttribute("Quantity") or bNode:GetAttribute("Count")) or 0
end
DashUI._isRodOwned = function(rFolder)
    if not rFolder or not rFolder.Parent then return false end
    local ownedObj = rFolder:FindFirstChild("Owned")
    if ownedObj then
        return (not ownedObj:IsA("ValueBase")) or (ownedObj.Value == true) or (ownedObj.Value == 1)
    end
    return rFolder:GetAttribute("Owned") == true
end
DashUI._releaseAllVirtualKeys = function()
    if next(pressedVirtualKeys) == nil then return end
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then
            for kc in pairs(pressedVirtualKeys) do
                pressedVirtualKeys[kc] = nil
                pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
            end
        end
    end)
    table.clear(pressedVirtualKeys)
end
local pressedVirtualMouse = {}
DashUI._pressVirtualMouse = function(x, y, withTouch)
    local key = tostring(x) .. ":" .. tostring(y)
    local prev = pressedVirtualMouse[key]
    pressedVirtualMouse[key] = { x = x, y = y, touch = (withTouch == true) or (prev and prev.touch == true) or false }
    return key
end
DashUI._releaseVirtualMouse = function(key)
    if key then pressedVirtualMouse[key] = nil end
end
DashUI._releaseAllVirtualMouse = function()
    if next(pressedVirtualMouse) == nil then return end
    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        for _, info in pairs(pressedVirtualMouse) do
            pcall(function() vim:SendMouseButtonEvent(info.x, info.y, 0, false, game, 1) end)
            if info.touch then
                pcall(function() vim:SendTouchEvent(0, 2, info.x, info.y) end)
            end
        end
    end
    table.clear(pressedVirtualMouse)
end
local invokeInFlight = setmetatable({}, { __mode = "k" })
local invokeBackoffUntil = setmetatable({}, { __mode = "k" })
local invokeFailStreak = setmetatable({}, { __mode = "k" })
FSYC.invokeReset = function()
    if invokeInFlight then table.clear(invokeInFlight) end
    if invokeBackoffUntil then table.clear(invokeBackoffUntil) end
    if invokeFailStreak then table.clear(invokeFailStreak) end
end
local unpackInvokeArgs = table.unpack or unpack
DashUI._safeInvokeAsync = function(rem, timeoutSec, ...)
    if typeof(rem) ~= "Instance" or not rem.Parent or not rem:IsA("RemoteFunction") then return false end
    local nowClk = tick()
    local defaultTimeout = FSYC.Tunables and FSYC.Tunables.InvokeDefaultTimeoutSec or 4.0
    if invokeBackoffUntil[rem] and nowClk < invokeBackoffUntil[rem] then
        return false
    end
    if invokeInFlight[rem] and (nowClk - invokeInFlight[rem]) < (timeoutSec or defaultTimeout) then
        return false
    end
    invokeInFlight[rem] = nowClk
    local args = table.pack(...)
    local th
    th = task.spawn(function()
        local ok, err = pcall(function()
            rem:InvokeServer(unpackInvokeArgs(args, 1, args.n))
        end)
        if not ok then
            local streak = (invokeFailStreak[rem] or 0) + 1
            invokeFailStreak[rem] = streak
            local baseSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffBaseSec or 0.50
            local maxSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffMaxSec or 8.00
            local waitBackoff = math.min(baseSec * (2 ^ (streak - 1)), maxSec)
            invokeBackoffUntil[rem] = tick() + waitBackoff
            FLogWarn("Invoke", string.format("%s 调用失败 (退避 %.2fs): %s", tostring(rem.Name), waitBackoff, tostring(err)))
        else
            invokeFailStreak[rem] = nil
            invokeBackoffUntil[rem] = nil
        end
        if invokeInFlight[rem] == nowClk then invokeInFlight[rem] = nil end
        if th then activeThreads[th] = nil end
    end)
    if th then activeThreads[th] = true end
    return true
end
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
SyncUIWithConfig = function()
    for key, ctrl in pairs(UIControls) do
        if Config[key] ~= nil and ctrl and ctrl.Set then
            pcall(ctrl.Set, Config[key], true)
        end
    end
    if UIControls.RealBossGap and UIControls.RealBossGap.Set and Config.RealBossGap ~= nil then
        local gapVal = tonumber(Config.RealBossGap) or 0.75
        local gapLabel
        if gapVal >= 1.05 then gapLabel = "1.20s 真人速"
        elseif gapVal >= 0.85 then gapLabel = "0.95s 稳健"
        elseif gapVal >= 0.675 then gapLabel = "0.75s 偏快(推荐)"
        elseif gapVal >= 0.525 then gapLabel = "0.60s 很快(有风险)"
        elseif gapVal >= 0.375 then gapLabel = "0.45s 极快(概率封号)"
        else gapLabel = "0.30s 疯狂(高概率封号)" end
        pcall(UIControls.RealBossGap.Set, gapLabel, true)
    end
    if (tonumber(Config.RhythmBeatSec) or 0.34) < 0.30 then Config.RhythmBeatSec = 0.30 end
    if (tonumber(Config.RealBossGap) or 0.75) < 0.30 then Config.RealBossGap = 0.30 end
    if UIControls.RhythmBeatSec and UIControls.RhythmBeatSec.Set and Config.RhythmBeatSec ~= nil then
        local beatVal = tonumber(Config.RhythmBeatSec) or 0.34
        local beatLabel
        if beatVal >= 0.37 then beatLabel = "0.38s 保守"
        elseif beatVal >= 0.35 then beatLabel = "0.36s 真人速"
        elseif beatVal >= 0.32 then beatLabel = "0.34s 稳健(推荐)"
        else beatLabel = "0.30s 最快(仍安全)" end
        pcall(UIControls.RhythmBeatSec.Set, beatLabel, true)
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
    if DashUI and type(DashUI._applyTheme) == "function" then
        pcall(DashUI._applyTheme, Config.UITheme, true)
    end
end
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
                        Config[k] = SanitizeConfigValue(k, v, current)
                    end
                end
                if not Config._cdZFixed then
                    Config._cdZFixed = true
                    if Config.SkillCdZ == 30 then
                        Config.SkillCdZ = 3
                        FLog("技能", "检测到 Z 技能冷却被旧版迁移写成 30 秒，已按实测复位为 3 秒（仅本次）")
                    end
                end
                Config.AutoCraftBait = false
                Config.AutoBuyBait = false
                Config.AutoGacha = false
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
LoadCustomTPs = function()
    EnsureProfileDir()
    if readfile then
        local ok, content = pcall(function() return readfile(CustomTP_FILE) end)
        if ok and content and #content > 0 then
            local decOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
            if decOk and type(decoded) == "table" then
                local validated = {}
                for _, item in ipairs(decoded) do
                    local cleanName = (type(item) == "table" and type(item.name) == "string") and (item.name:gsub("[%c]", ""):match("^%s*(.-)%s*$") or "") or ""
                    if cleanName ~= ""
                        and type(item.x) == "number" and type(item.y) == "number" and type(item.z) == "number"
                        and item.x == item.x and item.y == item.y and item.z == item.z
                        and math.abs(item.x) < 1000000 and math.abs(item.y) < 1000000 and math.abs(item.z) < 1000000 then
                        table.insert(validated, {
                            name = cleanName:sub(1, 48),
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
end
local THEME_ACCENTS = {
    ["薄荷翠绿"] = {
        BorderAccent     = Color3.fromRGB(53, 210, 153),
        AccentSoft       = Color3.fromRGB(110, 231, 183),
        Accent           = Color3.fromRGB(53, 210, 153),
        AccentDeep       = Color3.fromRGB(16, 98, 72),
        AccentGlow       = Color3.fromRGB(167, 243, 208),
        DropdownSelected = Color3.fromRGB(20, 83, 61),
    },
    ["冰川天蓝"] = {
        BorderAccent     = Color3.fromRGB(126, 158, 178),
        AccentSoft       = Color3.fromRGB(176, 205, 220),
        Accent           = Color3.fromRGB(143, 180, 201),
        AccentDeep       = Color3.fromRGB(30, 52, 66),
        AccentGlow       = Color3.fromRGB(199, 220, 232),
        DropdownSelected = Color3.fromRGB(33, 55, 70),
    },
    ["极光青碧"] = {
        BorderAccent     = Color3.fromRGB(118, 172, 164),
        AccentSoft       = Color3.fromRGB(166, 208, 201),
        Accent           = Color3.fromRGB(134, 198, 190),
        AccentDeep       = Color3.fromRGB(28, 59, 55),
        AccentGlow       = Color3.fromRGB(196, 227, 222),
        DropdownSelected = Color3.fromRGB(31, 63, 58),
    },
    ["流光琥珀"] = {
        BorderAccent     = Color3.fromRGB(180, 156, 116),
        AccentSoft       = Color3.fromRGB(224, 203, 168),
        Accent           = Color3.fromRGB(208, 178, 126),
        AccentDeep       = Color3.fromRGB(62, 50, 32),
        AccentGlow       = Color3.fromRGB(238, 224, 198),
        DropdownSelected = Color3.fromRGB(66, 54, 35),
    },
    ["珊瑚绯红"] = {
        BorderAccent     = Color3.fromRGB(184, 132, 138),
        AccentSoft       = Color3.fromRGB(224, 182, 187),
        Accent           = Color3.fromRGB(201, 142, 150),
        AccentDeep       = Color3.fromRGB(64, 38, 42),
        AccentGlow       = Color3.fromRGB(236, 206, 210),
        DropdownSelected = Color3.fromRGB(70, 42, 46),
    },
}
FSYC.THEME_BASE_KEYS = {"Background", "SidebarBg", "Card", "RowNormal", "RowHover", "ControlBg",
                         "InputBg", "Divider", "BorderSubtle"}
FSYC.RGBToHSV = function(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
    end
    local s = (mx == 0) and 0 or (d / mx)
    return h, s, mx
end
FSYC.HSVToRGB = function(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs(((h / 60) % 2) - 1))
    local m = v - c
    local r, g, b
    local seg = math.floor((h % 360) / 60)
    if seg == 0 then r, g, b = c, x, 0
    elseif seg == 1 then r, g, b = x, c, 0
    elseif seg == 2 then r, g, b = 0, c, x
    elseif seg == 3 then r, g, b = 0, x, c
    elseif seg == 4 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5)
end
do
    local basePalette = {
        Background   = {23, 26, 33}, SidebarBg = {19, 22, 28}, Card    = {24, 28, 36},
        RowNormal    = {30, 34, 43}, RowHover  = {38, 43, 54}, ControlBg = {48, 55, 70},
        InputBg      = {16, 19, 24}, Divider   = {38, 44, 56}, BorderSubtle = {46, 53, 66},
    }
    for themeName, palette in pairs(THEME_ACCENTS) do
        local acc = palette.Accent
        local hueAccent = FSYC.RGBToHSV(math.floor(acc.R * 255 + 0.5), math.floor(acc.G * 255 + 0.5), math.floor(acc.B * 255 + 0.5))
        for _, key in ipairs(FSYC.THEME_BASE_KEYS) do
            local rgb = basePalette[key]
            if themeName == "薄荷翠绿" then
                palette[key] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
            else
                local h, s, v = FSYC.RGBToHSV(rgb[1], rgb[2], rgb[3])
                local nh, ns = hueAccent, s * 0.9
                local r2, g2, b2 = FSYC.HSVToRGB(nh, ns, v)
                palette[key] = Color3.fromRGB(r2, g2, b2)
            end
        end
    end
end
FSYC.THEME_OPTIONS = {"薄荷翠绿", "冰川天蓝", "极光青碧", "流光琥珀", "珊瑚绯红"}
local Colors = {
    Background       = Color3.fromRGB(23, 26, 33),
    SidebarBg        = Color3.fromRGB(19, 22, 28),
    Card             = Color3.fromRGB(24, 28, 36),
    RowNormal        = Color3.fromRGB(30, 34, 43),
    RowHover         = Color3.fromRGB(38, 43, 54),
    ControlBg        = Color3.fromRGB(48, 55, 70),
    InputBg          = Color3.fromRGB(16, 19, 24),
    Divider          = Color3.fromRGB(38, 44, 56),
    BorderSubtle     = Color3.fromRGB(46, 53, 66),
    BorderAccent     = Color3.fromRGB(53, 210, 153),
    Accent           = Color3.fromRGB(53, 210, 153),
    AccentSoft       = Color3.fromRGB(110, 231, 183),
    AccentDeep       = Color3.fromRGB(16, 98, 72),
    AccentGlow       = Color3.fromRGB(167, 243, 208),
    TextWhite        = Color3.fromRGB(234, 241, 235),
    TextSubtle       = Color3.fromRGB(224, 230, 240),
    TextMuted        = Color3.fromRGB(178, 188, 204),
    AccentGreen      = Color3.fromRGB(52, 211, 153),
    AccentRed        = Color3.fromRGB(248, 113, 113),
    AccentOrange     = Color3.fromRGB(251, 146, 60),
    AccentYellow     = Color3.fromRGB(250, 204, 21),
    AccentBlue       = Color3.fromRGB(56, 189, 248),
    DropdownSelected = Color3.fromRGB(20, 83, 61),
}
local currentThemeName = (THEME_ACCENTS[Config.UITheme] and Config.UITheme) or "薄荷翠绿"
for k, v in pairs(THEME_ACCENTS[currentThemeName]) do
    Colors[k] = v
end
local ApplyThemeRecolor
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
    local prevPalette = THEME_ACCENTS[currentThemeName]
    currentThemeName = targetName
    Config.UITheme = targetName
    local accentPalette = THEME_ACCENTS[targetName]
    if ApplyThemeRecolor and prevPalette ~= accentPalette then
        local okRecolor, errRecolor = pcall(ApplyThemeRecolor, prevPalette, accentPalette)
        if not okRecolor then
            FLogWarn("主题", "主题批量换色失败（可能只换了部分控件）: " .. tostring(errRecolor))
        end
    end
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
FSYC.MODE_OPTIONS = {"自动", "手机", "电脑"}
local DeviceProfile = { touch = false, keyboard = false, mouse = false, gamepad = false,
                        detected = "desktop", effective = "desktop", hybrid = false }
function DeviceProfile.Refresh()
    local function CapFlag(prop)
        local ok, v = pcall(function() return UserInputService and UserInputService[prop] end)
        return (ok and v) and true or false
    end
    DeviceProfile.touch = CapFlag("TouchEnabled")
    DeviceProfile.keyboard = CapFlag("KeyboardEnabled")
    DeviceProfile.mouse = CapFlag("MouseEnabled")
    DeviceProfile.gamepad = CapFlag("GamepadEnabled")
    local t, k, m = DeviceProfile.touch, DeviceProfile.keyboard, DeviceProfile.mouse
    if t and (k or m) then
        DeviceProfile.detected = "hybrid"
    elseif t then
        DeviceProfile.detected = "mobile"
    else
        DeviceProfile.detected = "desktop"
    end
    DeviceProfile.hybrid = (DeviceProfile.detected == "hybrid")
    DeviceProfile.effective = (DeviceProfile.detected == "mobile") and "mobile" or "desktop"
    return DeviceProfile
end
DeviceProfile.Refresh()
local ModeCtl = {
    mode = DeviceProfile.effective,
    configured = "自动",
    gen = 0,
    listeners = {},
    stats = { switches = 0, rebinds = 0, isolated = 0, deduped = 0,
              dispatched = 0, fallbackFired = 0, fallbackSkipped = 0,
              last = { t = 0, kind = nil, family = nil, mode = nil, gen = 0, ok = false, name = nil } },
}
local InputRouter
local mainFrame
local PacketGuard
function ModeCtl.Resolve(configured)
    if configured == "手机" and DeviceProfile.touch then return "mobile" end
    if configured == "电脑" and (DeviceProfile.mouse or DeviceProfile.keyboard) then return "desktop" end
    return DeviceProfile.effective or "desktop"
end
function ModeCtl.IsMobile() return ModeCtl.mode == "mobile" end
function ModeCtl.IsDesktop() return ModeCtl.mode == "desktop" end
function ModeCtl.Label()
    return ModeCtl.IsMobile() and "手机（触屏）" or "电脑（键鼠）"
end
function ModeCtl.Describe()
    local d = DeviceProfile
    local parts = {}
    if d.touch then parts[#parts + 1] = "触屏" end
    if d.keyboard then parts[#parts + 1] = "键盘" end
    if d.mouse then parts[#parts + 1] = "鼠标" end
    if d.gamepad then parts[#parts + 1] = "手柄" end
    local cap = (#parts > 0) and table.concat(parts, "+") or "未探测到输入设备"
    return string.format("%s · %s%s", cap, (ModeCtl.configured == "自动") and "自动" or "手动",
        d.hybrid and " · 混合" or "")
end
function ModeCtl.IsForced()
    if Config.DeviceMode == "手机" then return ModeCtl.mode == "mobile" end
    if Config.DeviceMode == "电脑" then return ModeCtl.mode == "desktop" end
    return false
end
function ModeCtl.Accepts(inputType)
    if not Config.InputIsolation then return true end
    local isTouch = (inputType == "touch") or (inputType == Enum.UserInputType.Touch)
    local isMouse = (inputType == "mouse") or (inputType == Enum.UserInputType.MouseButton1)
        or (inputType == Enum.UserInputType.MouseButton2) or (inputType == Enum.UserInputType.MouseMovement)
    if not (isTouch or isMouse) then return true end
    if not ModeCtl.IsForced() then return true end
    if isTouch and ModeCtl.IsMobile() then return true end
    if isMouse and ModeCtl.IsDesktop() then return true end
    return false
end
function ModeCtl.AllowKeyboardShortcuts()
    return ModeCtl.IsDesktop() or DeviceProfile.keyboard or (not DeviceProfile.touch)
end
function ModeCtl.Apply(configured, opts)
    if not isRunning then return ModeCtl.mode end
    opts = opts or {}
    local target = ModeCtl.Resolve(configured)
    local prev = ModeCtl.mode
    local prevConfigured = ModeCtl.configured
    ModeCtl.configured = (configured == "手机" or configured == "电脑") and configured or "自动"
    if not opts.runtimeOnly then
        Config.DeviceMode = ModeCtl.configured
    end
    if not ModeCtl.warnedFallback
        and ((configured == "手机" and target ~= "mobile") or (configured == "电脑" and target ~= "desktop")) then
        ModeCtl.warnedFallback = true
        FLogWarn("双端模式", string.format("本机没有「%s」所需输入设备，已回落为 %s",
            configured == "手机" and "触屏" or "键盘/鼠标",
            target == "mobile" and "手机（触屏）" or "电脑（键鼠）"))
    end
    if target ~= prev or opts.force or prevConfigured ~= ModeCtl.configured then
        ModeCtl.gen = ModeCtl.gen + 1
        ModeCtl.mode = target
        ModeCtl.stats.switches = ModeCtl.stats.switches + 1
        if DashUI.metrics then DashUI.metrics.touch = (target == "mobile") end
        if UIControls and UIControls.DeviceMode and type(UIControls.DeviceMode.Set) == "function" then
            pcall(UIControls.DeviceMode.Set, ModeCtl.configured, true)
        end
        if InputRouter then pcall(InputRouter.ApplyMode) end
        FLog("双端模式", string.format("切换为 %s（配置=%s · 代次=%d）", ModeCtl.Label(), ModeCtl.configured, ModeCtl.gen))
    end
    for i = 1, #ModeCtl.listeners do pcall(ModeCtl.listeners[i], ModeCtl.mode, ModeCtl.configured) end
    return ModeCtl.mode
end
function ModeCtl.OnChange(fn)
    if type(fn) == "function" then ModeCtl.listeners[#ModeCtl.listeners + 1] = fn end
end
function ModeCtl.NoteIsolatedBlock(now)
    local w = ModeCtl.blockWindow
    if not w or (now - w.at) > 3.0 then
        ModeCtl.blockWindow = { at = now, n = 1 }
        return
    end
    w.n = w.n + 1
    if w.n >= 5 and ModeCtl.IsForced() and not ModeCtl.autoFellBack then
        ModeCtl.autoFellBack = true
        FLogWarn("双端模式", "3 秒内 5 次点击被输入隔离拦下，当前模式与本机输入不匹配，已自动回落为「自动」模式")
        task.defer(function()
            if isRunning then pcall(ModeCtl.Apply, "自动", { force = true, runtimeOnly = true }) end
        end)
    end
end
ModeCtl.configured = (Config.DeviceMode == "手机" or Config.DeviceMode == "电脑") and Config.DeviceMode or "自动"
ModeCtl.mode = ModeCtl.Resolve(ModeCtl.configured)
local IS_TOUCH_ONLY = ModeCtl.IsMobile()
local VIEWCFG = (function()
    local cam0 = Workspace.CurrentCamera
    local vp0 = cam0 and cam0.ViewportSize
    local w = (vp0 and vp0.X and vp0.X > 0) and vp0.X or 1280
    local h = (vp0 and vp0.Y and vp0.Y > 0) and vp0.Y or 720
    local narrow = (w < 760) and (h > w * 1.05)
    return { w = w, h = h, narrow = narrow, scale = 0.9 }
end)()
local IS_NARROW = VIEWCFG.narrow
FSYC.DESIGN_SCALE = VIEWCFG.scale
DashUI.metrics = {
    touch        = IS_TOUCH_ONLY,
    compactNav   = IS_NARROW,
    winW         = IS_NARROW and math.max(340, math.floor((VIEWCFG.w - 20) / FSYC.DESIGN_SCALE)) or (IS_TOUCH_ONLY and 760 or 800),
    winH         = IS_NARROW and math.max(520, math.floor((VIEWCFG.h - 20) / FSYC.DESIGN_SCALE)) or (IS_TOUCH_ONLY and 560 or 552),
    navW         = IS_NARROW and 88 or (IS_TOUCH_ONLY and 168 or 158),
    topH         = IS_TOUCH_ONLY and 52 or 46,
    footH        = 26,
    searchH      = IS_TOUCH_ONLY and 34 or 30,
    navH         = IS_NARROW and 56 or (IS_TOUCH_ONLY and 40 or 34),
    rowH         = IS_TOUCH_ONLY and 58 or 46,
    padX         = IS_TOUCH_ONLY and 18 or 14,
    gap          = IS_TOUCH_ONLY and 12 or 10,
    groupH       = IS_TOUCH_ONLY and 46 or 38,
    titleSize    = IS_TOUCH_ONLY and 15 or 14,
    descSize     = IS_TOUCH_ONLY and 12 or 11,
    groupTitle   = IS_TOUCH_ONLY and 14 or 13,
    toggleW      = IS_TOUCH_ONLY and 54 or 46,
    toggleH      = IS_TOUCH_ONLY and 30 or 26,
    knobSize     = IS_TOUCH_ONLY and 22 or 18,
    hitW         = IS_TOUCH_ONLY and 72 or 56,
    btnH         = IS_TOUCH_ONLY and 38 or 30,
    btnW         = IS_TOUCH_ONLY and 108 or 92,
    ddH          = IS_TOUCH_ONLY and 38 or 30,
    ddW          = IS_TOUCH_ONLY and 156 or 138,
    optH         = IS_TOUCH_ONLY and 40 or 30,
    sliderW      = IS_TOUCH_ONLY and 176 or 190,
    radius       = 10,
    radiusSm     = 8,
}
do
    local avail = DashUI.metrics.winH - DashUI.metrics.topH - DashUI.metrics.footH - 28 - 40
    local fit = math.floor((avail - 8 * 5) / 9)
    if fit < DashUI.metrics.navH then
        DashUI.metrics.navH = math.max(34, fit)
    end
end
local UIM = DashUI.metrics
FSYC.getGuiParent = function()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    if CoreGui then
        local ok, name = pcall(function() return CoreGui.Name end)
        if ok and name then return CoreGui end
    end
    local pg = LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10))
    return pg
end
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdenticalHeavyweightFishing"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 100
FSYC.CLASS_COLOR_PROPS = {
    Frame          = {"BackgroundColor3"},
    ScrollingFrame = {"BackgroundColor3", "ScrollBarImageColor3"},
    TextLabel      = {"BackgroundColor3", "TextColor3", "TextStrokeColor3"},
    TextButton     = {"BackgroundColor3", "TextColor3", "TextStrokeColor3"},
    TextBox        = {"BackgroundColor3", "TextColor3", "TextStrokeColor3", "PlaceholderColor3"},
    ImageLabel     = {"BackgroundColor3", "ImageColor3"},
    ImageButton    = {"BackgroundColor3", "ImageColor3"},
    UIStroke       = {"Color"},
}
local function ThemeColorKey(c)
    return math.floor(c.R * 255 + 0.5) * 65536 + math.floor(c.G * 255 + 0.5) * 256 + math.floor(c.B * 255 + 0.5)
end
ApplyThemeRecolor = function(oldPalette, newPalette)
    if not screenGui then return 0 end
    local map, mapCount = {}, 0
    local protected = {}
    for k, v in pairs(Colors) do
        if oldPalette[k] == nil and typeof(v) == "Color3" then
            protected[ThemeColorKey(v)] = true
        end
    end
    for k, oldV in pairs(oldPalette) do
        local newV = newPalette[k]
        if newV and typeof(oldV) == "Color3" and oldV ~= newV then
            local key = ThemeColorKey(oldV)
            if not protected[key] then
                map[key] = newV
                mapCount = mapCount + 1
            end
        end
    end
    if mapCount == 0 then return 0 end
    local changed = 0
    local stack = { screenGui }
    while #stack > 0 do
        local inst = table.remove(stack)
        local kids = inst:GetChildren()
        for i = 1, #kids do stack[#stack + 1] = kids[i] end
        local propList = FSYC.CLASS_COLOR_PROPS[inst.ClassName]
        if propList then
            for pi = 1, #propList do
                local prop = propList[pi]
                local cur = inst[prop]
                if typeof(cur) == "Color3" then
                    local newV = map[ThemeColorKey(cur)]
                    if newV then
                        inst[prop] = newV
                        changed = changed + 1
                    end
                end
            end
        end
    end
    return changed
end
FSYC.setParentOk = pcall(function() screenGui.Parent = FSYC.getGuiParent() end)
if not FSYC.setParentOk or not screenGui.Parent then
    pcall(function() screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) end)
end
if not screenGui.Parent then
    FLogErr("UI", "ScreenGui 挂载失败（gethui/CoreGui/PlayerGui 均不可用），悬浮窗将不可见")
end
table.insert(cleanUpInstances, screenGui)
FSYC.CLICK_COOLDOWN_MOBILE = 0.12
FSYC.CLICK_COOLDOWN_DESKTOP = 0.06
InputRouter = {
    pressSeq = 0,
    pressAt = 0,
    pressSource = nil,
    pressPos = nil,
    pressMoved = false,
    records = setmetatable({}, { __mode = "k" }),
    modeConns = {},
}
local function RecentPress()
    if not InputRouter.pressSource then return nil, nil, nil end
    local window = math.max(0.05, (tonumber(Config.InputDedupeMs) or 600) / 1000)
    local age = tick() - InputRouter.pressAt
    if age <= window then
        return InputRouter.pressSource, InputRouter.pressSeq, age
    end
    return nil, nil, nil
end
local function SourceForChannel(channel)
    local pressSrc, seq, pressAge = RecentPress()
    if channel == "touch" then return "touch", seq end
    if channel == "mouse" then
        if pressSrc == "touch" and pressAge and pressAge <= 0.15 then return "touch", seq end
        if ModeCtl.IsMobile() and not DeviceProfile.mouse then return "touch", seq end
        return "mouse", seq
    end
    return pressSrc, seq
end
function InputRouter.Dispatch(button, channel, opts)
    local rec = InputRouter.records[button]
    if not rec or not isRunning then return false end
    opts = opts or {}
    local now = tick()
    if opts.seq and opts.seq ~= InputRouter.pressSeq then
        ModeCtl.stats.fallbackSkipped = ModeCtl.stats.fallbackSkipped + 1
        return false
    end
    local source, seq = SourceForChannel(channel)
    if source and not ModeCtl.Accepts(source) then
        ModeCtl.stats.isolated = ModeCtl.stats.isolated + 1
        ModeCtl.NoteIsolatedBlock(now)
        return false
    end
    if seq and rec.lastSeq == seq then
        ModeCtl.stats.deduped = ModeCtl.stats.deduped + 1
        return false
    end
    local cooldown = rec.cooldown or (ModeCtl.IsMobile() and FSYC.CLICK_COOLDOWN_MOBILE or FSYC.CLICK_COOLDOWN_DESKTOP)
    if (now - (rec.lastAt or 0)) < cooldown then
        ModeCtl.stats.deduped = ModeCtl.stats.deduped + 1
        return false
    end
    rec.lastSeq, rec.lastAt = seq, now
    ModeCtl.stats.dispatched = ModeCtl.stats.dispatched + 1
    local ok, err = pcall(rec.callback)
    if not ok then FLogErr("点击回调", tostring(button and button.Name) .. " 执行异常: " .. tostring(err)) end
    local last = ModeCtl.stats.last
    last.t, last.kind, last.family = now, channel, source
    last.mode, last.gen, last.ok = ModeCtl.mode, ModeCtl.gen, ok
    last.name = (button and button.Name) or "?"
    return true
end
local function ConnectRecord(button, rec)
    local conns = {}
    if button.Activated then
        conns[#conns + 1] = button.Activated:Connect(function(inputObj)
            local channel = "activated"
            if inputObj and typeof(inputObj) == "Instance" and inputObj.UserInputType == Enum.UserInputType.Touch then
                channel = "touch"
            end
            InputRouter.Dispatch(button, channel)
        end)
    end
    if button.MouseButton1Click then
        conns[#conns + 1] = button.MouseButton1Click:Connect(function()
            InputRouter.Dispatch(button, "mouse")
        end)
    end
    rec.conns = conns
end
local function DisconnectRecord(rec)
    if rec and rec.conns then
        for i = 1, #rec.conns do pcall(function() rec.conns[i]:Disconnect() end) end
        rec.conns = nil
    end
end
function InputRouter.BindClick(button, callback)
    if not button or type(callback) ~= "function" then return nil end
    local rec = InputRouter.records[button]
    if rec then
        rec.callback = callback
        return rec.fire
    end
    rec = { callback = callback, lastAt = 0, lastSeq = nil, conns = nil, hud = false }
    rec.fire = function() InputRouter.Dispatch(button, "activated") end
    InputRouter.records[button] = rec
    ConnectRecord(button, rec)
    return rec.fire
end
function InputRouter.BindHudClick(button, callback, mobileOnly)
    if not button or type(callback) ~= "function" then return nil end
    local rec = InputRouter.records[button]
    if rec then
        rec.callback = callback
        return rec.fire
    end
    rec = { callback = callback, lastAt = 0, lastSeq = nil, conns = nil, hud = true,
            mobileOnly = (mobileOnly ~= false) }
    rec.fire = function() InputRouter.Dispatch(button, "activated") end
    InputRouter.records[button] = rec
    if not (rec.mobileOnly and not ModeCtl.IsMobile()) then ConnectRecord(button, rec) end
    return rec.fire
end
function InputRouter.RebindAll()
    for button, rec in pairs(InputRouter.records) do
        DisconnectRecord(rec)
        if button.Parent ~= nil and not (rec.mobileOnly and not ModeCtl.IsMobile()) then
            ConnectRecord(button, rec)
            ModeCtl.stats.rebinds = ModeCtl.stats.rebinds + 1
        end
    end
end
function InputRouter.BindGlobal()
    for i = 1, #InputRouter.modeConns do pcall(function() InputRouter.modeConns[i]:Disconnect() end) end
    table.clear(InputRouter.modeConns)
    local conns = InputRouter.modeConns
    conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        local ut = input.UserInputType
        if ut == Enum.UserInputType.Touch or ut == Enum.UserInputType.MouseButton1 then
            InputRouter.pressSeq = InputRouter.pressSeq + 1
            InputRouter.pressAt = tick()
            InputRouter.pressSource = (ut == Enum.UserInputType.Touch) and "touch" or "mouse"
            InputRouter.pressPos = input.Position
            InputRouter.pressMoved = false
        end
    end)
    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
        if not InputRouter.pressPos then return end
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then
            if (input.Position - InputRouter.pressPos).Magnitude > 14 then InputRouter.pressMoved = true end
        end
    end)
    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if not InputRouter.pressPos then return end
        local pos, moved = input.Position, InputRouter.pressMoved
        local held, seqAtPress, pressSource = tick() - InputRouter.pressAt, InputRouter.pressSeq, InputRouter.pressSource
        InputRouter.pressPos = nil
        if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if moved or held > 0.8 then return end
        if not ModeCtl.IsMobile() or pressSource ~= "touch" then return end
        local genAtSchedule = ModeCtl.gen
        task.delay(0.12, function()
            if not isRunning then return end
            if genAtSchedule ~= ModeCtl.gen or not ModeCtl.IsMobile() then
                ModeCtl.stats.fallbackSkipped = ModeCtl.stats.fallbackSkipped + 1
                return
            end
            if mainFrame and not mainFrame.Visible then return end
            local confirmNode = screenGui and screenGui:FindFirstChild("UnloadConfirmOverlay")
            if confirmNode and confirmNode.Visible then return end
            local ok, objects = pcall(function() return UserInputService:GetGuiObjectsAtPosition(pos.X, pos.Y) end)
            if not ok or type(objects) ~= "table" or #objects == 0 then return end
            for _, obj in ipairs(objects) do
                local rec = InputRouter.records[obj]
                if rec then
                    if InputRouter.Dispatch(obj, "touch", { seq = seqAtPress }) then
                        ModeCtl.stats.fallbackFired = ModeCtl.stats.fallbackFired + 1
                    end
                    return
                end
                if obj:IsA("GuiButton") then return end
                if obj:IsA("GuiObject") and obj.Active == true then return end
            end
        end)
    end)
end
function InputRouter.ApplyMode()
    if not isRunning then return false end
    InputRouter.pressSeq = InputRouter.pressSeq + 1
    InputRouter.pressAt = 0
    InputRouter.pressSource = nil
    InputRouter.pressPos = nil
    InputRouter.pressMoved = false
    InputRouter.RebindAll()
    InputRouter.BindGlobal()
    return true
end
function InputRouter.Destroy()
    for _, rec in pairs(InputRouter.records) do DisconnectRecord(rec) end
    table.clear(InputRouter.records)
    for i = 1, #InputRouter.modeConns do pcall(function() InputRouter.modeConns[i]:Disconnect() end) end
    table.clear(InputRouter.modeConns)
end
InputRouter.BindGlobal()
DashUI.device = {
    profile = DeviceProfile,
    router = InputRouter,
    stats = ModeCtl.stats,
    mode = function() return ModeCtl.mode end,
    configured = function() return ModeCtl.configured end,
    gen = function() return ModeCtl.gen end,
    label = function() return ModeCtl.Label() end,
    describe = function() return ModeCtl.Describe() end,
    accepts = function(t) return ModeCtl.Accepts(t) end,
    set = function(configured, force) return ModeCtl.Apply(configured, { force = force == true }) end,
    reDetect = function()
        DeviceProfile.Refresh()
        return ModeCtl.Apply(Config.DeviceMode, { force = true })
    end,
    snapshot = function()
        local d, st = DeviceProfile, ModeCtl.stats
        return {
            mode = ModeCtl.mode, configured = ModeCtl.configured, gen = ModeCtl.gen,
            strict = ModeCtl.IsForced(),
            profile = { touch = d.touch, keyboard = d.keyboard, mouse = d.mouse, gamepad = d.gamepad,
                        detected = d.detected, effective = d.effective, hybrid = d.hybrid },
            stats = { switches = st.switches, rebinds = st.rebinds, isolated = st.isolated,
                      deduped = st.deduped, dispatched = st.dispatched,
                      fallbackFired = st.fallbackFired, fallbackSkipped = st.fallbackSkipped,
                      last = { t = st.last.t, kind = st.last.kind, family = st.last.family,
                               mode = st.last.mode, gen = st.last.gen, ok = st.last.ok, name = st.last.name } },
        }
    end,
}
local function BindClick(button, callback)
    return InputRouter.BindClick(button, callback)
end
DashUI._hideTip = function() end
DashUI.attachTip = function() end
blackOutFrame = Instance.new("Frame")
blackOutFrame.Name = "PowerSaveOverlay"
blackOutFrame.Size = UDim2.new(1, 0, 1, 0)
blackOutFrame.BackgroundColor3 = Color3.fromRGB(5, 7, 6)
blackOutFrame.BorderSizePixel = 0
blackOutFrame.Visible = false
blackOutFrame.ZIndex = 0
blackOutFrame.Active = false
blackOutFrame.Parent = screenGui
do
    local blackOutLabel = Instance.new("TextLabel")
    blackOutLabel.Size = UDim2.new(1, 0, 0, 40)
    blackOutLabel.Position = UDim2.new(0, 0, 0.1, 0)
    blackOutLabel.BackgroundTransparency = 1
    blackOutLabel.Font = Enum.Font.GothamBold
    blackOutLabel.Text = "FSY · 极致省电挂机模式运行中（已关闭 3D 渲染）"
    blackOutLabel.TextColor3 = Colors.AccentSoft
    blackOutLabel.TextSize = 15
    blackOutLabel.Parent = blackOutFrame
    RegisterThemeUpdater(function() blackOutLabel.TextColor3 = Colors.AccentSoft end)
end
PacketGuard = { sent = 0, dropped = 0, lastAt = {}, combat = false }
PacketGuard.windowMs = FSYC.Tunables and FSYC.Tunables.PacketDefaultWindowMs or 40
PacketGuard.combatWindowMs = FSYC.Tunables and FSYC.Tunables.PacketCombatWindowMs or 10
PacketGuard.failStreak = {}
PacketGuard.backoffUntil = {}
DashUI.packetGuard = PacketGuard
local function SerializeTableArg(tbl)
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local kvParts = {}
    for i = 1, math.min(#keys, 8) do
        local k = keys[i]
        local v = tbl[k]
        local vt = typeof(v)
        local vs
        if vt == "boolean" then
            vs = v and "b:1" or "b:0"
        elseif vt == "number" then
            vs = string.format("n:%.3f", v)
        elseif vt == "string" then
            vs = "s:" .. v
        else
            vs = vt .. ":" .. tostring(v)
        end
        kvParts[#kvParts + 1] = tostring(k) .. "=" .. vs
    end
    return "t:{" .. table.concat(kvParts, ",") .. "}"
end
function PacketGuard.Signature(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    if n == 1 then
        local v1 = select(1, ...)
        local t1 = typeof(v1)
        if t1 == "string" then return "s:" .. v1 end
        if t1 == "boolean" then return v1 and "b:1" or "b:0" end
        if t1 == "number" then return string.format("n:%.3f", v1) end
        if t1 == "table" then return SerializeTableArg(v1) end
    end
    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        local t = typeof(v)
        if t == "CFrame" then
            local p = v.Position
            parts[i] = string.format("C:%.2f,%.2f,%.2f", p.X, p.Y, p.Z)
        elseif t == "Vector3" then
            parts[i] = string.format("V:%.2f,%.2f,%.2f", v.X, v.Y, v.Z)
        elseif t == "number" then
            parts[i] = string.format("n:%.3f", v)
        elseif t == "string" then
            parts[i] = "s:" .. v
        elseif t == "boolean" then
            parts[i] = v and "b:1" or "b:0"
        elseif t == "Instance" then
            parts[i] = "I:" .. tostring(v.Name)
        elseif t == "table" then
            parts[i] = SerializeTableArg(v)
        else
            parts[i] = t
        end
    end
    return table.concat(parts, "|")
end
function PacketGuard.RecordResult(rem, ok, err)
    local name = (typeof(rem) == "Instance") and rem.Name or tostring(rem)
    if ok then
        PacketGuard.failStreak[name] = nil
        PacketGuard.backoffUntil[name] = nil
    else
        local streak = (PacketGuard.failStreak[name] or 0) + 1
        PacketGuard.failStreak[name] = streak
        local baseSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffBaseSec or 0.50
        local maxSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffMaxSec or 1.20
        if PacketGuard.combat then
            baseSec = FSYC.Tunables and FSYC.Tunables.CombatBackoffBaseSec or 0.10
            maxSec = FSYC.Tunables and FSYC.Tunables.CombatBackoffMaxSec or 0.35
        end
        local waitSec = math.min(baseSec * (2 ^ (streak - 1)), maxSec)
        PacketGuard.backoffUntil[name] = tick() + waitSec
        FLogWarn("发包退避", string.format("%s 触发异常退避 (第 %d 次, 冷却 %.2fs): %s", name, streak, waitSec, tostring(err)))
    end
end
function PacketGuard.Allow(rem, ...)
    local window = PacketGuard.combat and (PacketGuard.combatWindowMs or 0)
        or tonumber(Config.PacketDedupeMs) or PacketGuard.windowMs or 40
    local now = tick()
    local name = (typeof(rem) == "Instance") and rem.Name or tostring(rem)
    local backoffDeadline = PacketGuard.backoffUntil[name]
    if backoffDeadline and now < backoffDeadline then
        PacketGuard.dropped = PacketGuard.dropped + 1
        return false
    end
    if window <= 0 then
        PacketGuard.sent = PacketGuard.sent + 1
        return true
    end
    local key = name .. "#" .. PacketGuard.Signature(...)
    local last = PacketGuard.lastAt[key]
    if last and (now - last) * 1000 < window then
        PacketGuard.dropped = PacketGuard.dropped + 1
        return false
    end
    PacketGuard.lastAt[key] = now
    PacketGuard.sent = PacketGuard.sent + 1
    local sweepEvery = FSYC.Tunables and FSYC.Tunables.PacketSweepInterval or 512
    if PacketGuard.sent % sweepEvery == 0 then
        local maxWindow = math.max(tonumber(Config.PacketDedupeMs) or 40, PacketGuard.combatWindowMs or 10) / 1000
        for k, at in pairs(PacketGuard.lastAt) do
            if (now - at) > maxWindow then PacketGuard.lastAt[k] = nil end
        end
    end
    return true
end
local patternCache = {}
local patternCacheCount = 0
local cachedRuleMatchers = {}
FSYC.cachedRuleSource = nil
local tqLc = (function()
    local upMap = {
        ["À"]="à",["Á"]="á",["Â"]="â",["Ã"]="ã",["È"]="è",["É"]="é",["Ê"]="ê",["Ì"]="ì",["Í"]="í",["Ĩ"]="ĩ",
        ["Ò"]="ò",["Ó"]="ó",["Ô"]="ô",["Õ"]="õ",["Ù"]="ù",["Ú"]="ú",["Ý"]="ý",["Ă"]="ă",["Đ"]="đ",["Ơ"]="ơ",["Ư"]="ư",
        ["Ạ"]="ạ",["Ả"]="ả",["Ấ"]="ấ",["Ầ"]="ầ",["Ẩ"]="ẩ",["Ẫ"]="ẫ",["Ậ"]="ậ",["Ắ"]="ắ",["Ằ"]="ằ",["Ẳ"]="ẳ",["Ẵ"]="ẵ",["Ặ"]="ặ",
        ["Ẹ"]="ẹ",["Ẻ"]="ẻ",["Ẽ"]="ẽ",["Ế"]="ế",["Ề"]="ề",["Ể"]="ể",["Ễ"]="ễ",["Ệ"]="ệ",
        ["Ỉ"]="ỉ",["Ị"]="ị",["Ọ"]="ọ",["Ỏ"]="ỏ",["Ố"]="ố",["Ồ"]="ồ",["Ổ"]="ổ",["Ỗ"]="ỗ",["Ộ"]="ộ",
        ["Ớ"]="ớ",["Ờ"]="ờ",["Ở"]="ở",["Ỡ"]="ỡ",["Ợ"]="ợ",["Ụ"]="ụ",["Ủ"]="ủ",["Ũ"]="ũ",
        ["Ừ"]="ừ",["Ứ"]="ứ",["Ử"]="ử",["Ữ"]="ữ",["Ự"]="ự",["Ỳ"]="ỳ",["Ỷ"]="ỷ",["Ỹ"]="ỹ",["Ỵ"]="ỵ",
    }
    return function(s)
        if type(s) ~= "string" or s == "" then return "" end
        s = string.lower(s)
        if not string.find(s, "[\194-\244]") then return s end
        local okFix, fixed = pcall(function()
            return (string.gsub(s, "[\194-\244][\128-\191]*", function(ch) return upMap[ch] or ch end))
        end)
        if okFix and type(fixed) == "string" then return fixed end
        return s
    end
end)()
FSYC.watchedBagFolders = setmetatable({}, { __mode = "k" })
local isSellingInProgress = false
local isClaimingDailyTask = false
local isClaimingDailySign = false
FSYC.dailyTaskLockAt = 0
FSYC.dailySignLockAt = 0
local activePromptTasks = setmetatable({}, { __mode = "k" })
local OnlineNPCs = {}
local isMicroTeleportingNPC = false
local microTeleportLockAt = 0
local DismissStuckPromptsAndRestore
local liveNPCOrder = {
    "Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber",
    "Taoist", "Maoshan", "DumbGuy",
    "VermilionBird", "BlackTortoise", "WhiteTiger", "AzureDragon"
}
FSYC.NPC_SCAN_CONTAINER_NAMES = {"NPC", "NPCs", "Interactables", "DialogueNPCs", "QuestNPCs", "BossSetUp", "Shrines", "Spirits", "Merchants"}
local MAP_ROOT_NAMES = {"Islands", "Map"}
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
FSYC.unloadStarted = false
local IsToolFishingRod, IsCharacterHoldingFishingRod, RestoreMobileFishingButtonUI, StopLingeringFishingAnimations, MakeSyntheticInput
local searchState, collapsibleSections
local function UnloadScript()
    if FSYC.unloadStarted then return false end
    FSYC.unloadStarted = true
    isRunning = false
    FLog("卸载", "开始卸载：断开全部事件连接、取消受管协程、还原游戏视觉与输入状态、销毁 UI 节点")
    for fn in pairs(activeSliderCleanupFns) do pcall(fn) end
    table.clear(activeSliderCleanupFns)
    if DashUI and type(DashUI._releaseAllVirtualKeys) == "function" then
        pcall(DashUI._releaseAllVirtualKeys)
    end
    if DashUI and type(DashUI._releaseAllVirtualMouse) == "function" then
        pcall(DashUI._releaseAllVirtualMouse)
    end
    for pr in pairs(activePromptTasks) do
        if pr and pr.Parent then
            pcall(function() pr:InputHoldEnd() end)
        end
    end
    table.clear(activePromptTasks)
    if activeThreads then
        local selfThread = coroutine.running()
        for th in pairs(activeThreads) do
            if th ~= selfThread then
                pcall(task.cancel, th)
            end
        end
        table.clear(activeThreads)
    end
    if DashUI and type(DashUI._cleanupFG) == "function" then pcall(DashUI._cleanupFG) end
    currentlyOpenDropdown = nil
    if cameraViewportConn then
        pcall(function() cameraViewportConn:Disconnect() end)
        cameraViewportConn = nil
    end
    if sharedEnv then
        sharedEnv.IdenticalFishingRunning = false
        sharedEnv.IdenticalCombatActive = false
        sharedEnv.IdenticalCombatActiveAt = nil
        sharedEnv.IdenticalHeavyweightFishingUnload = nil
        sharedEnv.IdenticalFishingConfig = nil
        sharedEnv.IdenticalFishingDumpLogs = nil
        sharedEnv.IdenticalIsSellArgBlocked = nil
        sharedEnv.IdenticalIsFavToggleBlocked = nil
        sharedEnv.IdenticalInternalFavCall = nil
        sharedEnv.IdenticalLearnedFavRemote = nil
        sharedEnv.IdenticalLearnedFavFormat = nil
        sharedEnv.IdenticalLearnedFavSuffix = nil
        sharedEnv.IdenticalKeepFishBtnVisible = false
        sharedEnv.IdenticalProtectedFishBtn = nil
        sharedEnv.IdenticalProtectedFishContainer = nil
        sharedEnv.IdenticalLastHopTime = nil
    end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    pcall(function() RunService:UnbindFromRenderStep("IdenticalForceFishBtnVisible") end)
    if RestoreMobileFishingButtonUI then
        pcall(function()
            Config.HideGameUI = false
            RestoreMobileFishingButtonUI(true)
        end)
        if sharedEnv then
            sharedEnv.IdenticalKeepFishBtnVisible = false
            sharedEnv.IdenticalProtectedFishBtn = nil
            sharedEnv.IdenticalProtectedFishContainer = nil
        end
    end
    if attrCharConn then
        pcall(function() attrCharConn:Disconnect() end)
        attrCharConn = nil
    end
    for _, tw in pairs(activeQuickTweens) do pcall(function() tw:Cancel() end) end
    table.clear(activeQuickTweens)
    if FSYC.notifPool then
        for i = 1, #FSYC.notifPool do
            local rec = FSYC.notifPool[i]
            if rec then
                if rec.inTw then pcall(function() rec.inTw:Cancel() end) end
                if rec.outTw then pcall(function() rec.outTw:Cancel() end) end
            end
        end
    end
    table.clear(themeUpdaters)
    for conn in pairs(activeDragConns) do pcall(function() conn:Disconnect() end) end
    table.clear(activeDragConns)
    if InputRouter then pcall(InputRouter.Destroy) end
    if PacketGuard then
        table.clear(PacketGuard.lastAt)
        if PacketGuard.failStreak then table.clear(PacketGuard.failStreak) end
        if PacketGuard.backoffUntil then table.clear(PacketGuard.backoffUntil) end
    end
    if FSYC and type(FSYC.invokeReset) == "function" then pcall(FSYC.invokeReset) end
    for _, conn in ipairs(activeConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(activeConnections)
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    for _, inst in ipairs(cleanUpInstances) do pcall(function() if inst then inst:Destroy() end end) end
    table.clear(cleanUpInstances)
    if UIControls then table.clear(UIControls) end
    if collapsibleSections then table.clear(collapsibleSections) end
    if searchState and searchState.rows then table.clear(searchState.rows) end
    for hum, state in pairs(originalHumanoidState) do
        if hum and hum.Parent then
            pcall(function()
                hum.PlatformStand = state.PlatformStand
                hum.WalkSpeed = state.WalkSpeed
                hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
                hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
                hum:SetStateEnabled(Enum.HumanoidStateType.Pushed, true)
            end)
        end
    end
    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and not originalHumanoidState[hum] then
            hum.PlatformStand = false
        end
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = false end
    end)
    table.clear(originalHumanoidState)
    pcall(function()
        for _, fn in ipairs({"IdenticalESP", "IdenticalESPAnchors", "IdenticalESPHighlights", "FishRingAnchor", "IdenticalWaterPlatform"}) do
            local leftover = Workspace:FindFirstChild(fn)
            if leftover then leftover:Destroy() end
        end
    end)
    pcall(function()
        pcall(RestoreNativeGameHud)
        for gui, wasEnabled in pairs(originalGameGuiState) do
            if gui and gui.Parent then pcall(function() gui.Enabled = wasEnabled end) end
        end
        table.clear(originalGameGuiState)
        table.clear(gameGuiEnabledBackup)
        pcall(RestoreNoFogChanges)
        for property, value in pairs(originalLightingState) do
            pcall(function() Lighting[property] = value end)
        end
    end)
    if StopLingeringFishingAnimations then pcall(StopLingeringFishingAnimations, LocalPlayer and LocalPlayer.Character, true) end
    if DismissStuckPromptsAndRestore then pcall(DismissStuckPromptsAndRestore, false) end
    table.clear(patternCache)
    patternCacheCount = 0
    table.clear(cachedRuleMatchers)
    FSYC.cachedRuleSource = nil
    table.clear(FSYC.watchedBagFolders)
    table.clear(OnlineNPCs)
    isMicroTeleportingNPC = false
    microTeleportLockAt = 0
    isSellingInProgress = false
    isClaimingDailyTask = false
    isClaimingDailySign = false
    cachedFishConstraint = nil
    lockedCFrame = nil
    FLog("卸载", "卸载完成，全部连接、受管协程、视觉设置与缓存已完整释放")
    return true
end
if sharedEnv then sharedEnv.IdenticalHeavyweightFishingUnload = UnloadScript end
local notifContainer = Instance.new("Frame"); notifContainer.Name = "Notifications"; notifContainer.Size = UDim2.new(0, 300, 1, -40); notifContainer.Position = UDim2.new(1, -315, 0, 20); notifContainer.BackgroundTransparency = 1; notifContainer.ZIndex = 3500; notifContainer.Active = false; notifContainer.Parent = screenGui
table.insert(cleanUpInstances, notifContainer)
local ShowNotification, ServerHop
do (function()
local notifLayout = Instance.new("UIListLayout"); notifLayout.SortOrder = Enum.SortOrder.LayoutOrder; notifLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom; notifLayout.Padding = UDim.new(0, 8); notifLayout.Parent = notifContainer
local recentNotifMap = {}
local MAX_NOTIF_CARDS = FSYC.Tunables and FSYC.Tunables.NotifMaxCards or 4
local NOTIF_IN_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local NOTIF_OUT_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local notifPool = {}
local function DismissNotifCard(rec)
    if not rec or rec.closing or rec.shownAt == 0 then return end
    rec.closing = true
    rec.token = rec.token + 1
    local tok = rec.token
    if isRunning and rec.slot.Parent then
        pcall(function() rec.outTw:Play() end)
        task.delay(0.24, function()
            if tok ~= rec.token then return end
            rec.slot.Visible = false
            rec.card.Position = UDim2.new(1, 30, 0, 0)
            rec.card.BackgroundTransparency = 0.04
            rec.closing = false
            rec.shownAt = 0
        end)
    else
        rec.slot.Visible = false
        rec.card.Position = UDim2.new(1, 30, 0, 0)
        rec.card.BackgroundTransparency = 0.04
        rec.closing = false
        rec.shownAt = 0
    end
end
for i = 1, MAX_NOTIF_CARDS do
    local slot = Instance.new("Frame")
    slot.Name = "NotifSlot" .. i
    slot.LayoutOrder = i
    slot.Size = UDim2.new(1, 0, 0, 62)
    slot.BackgroundTransparency = 1
    slot.BorderSizePixel = 0
    slot.Visible = false
    slot.Parent = notifContainer
    local card = Instance.new("Frame")
    card.Name = "NotifCard"
    card.Size = UDim2.new(1, 0, 1, 0)
    card.Position = UDim2.new(1, 30, 0, 0)
    card.BackgroundColor3 = Colors.RowNormal
    card.BackgroundTransparency = 0.04
    card.BorderSizePixel = 0
    card.ClipsDescendants = true
    card.Active = true
    card.Parent = slot
    local stroke = Instance.new("UIStroke"); stroke.Color = Colors.Accent; stroke.Thickness = 1.2; stroke.Transparency = 0.15; stroke.Parent = card
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = card
    local sideBar = Instance.new("Frame"); sideBar.Size = UDim2.new(0, 3, 1, -14); sideBar.Position = UDim2.new(0, 5, 0, 7); sideBar.BackgroundColor3 = Colors.Accent; sideBar.BorderSizePixel = 0; sideBar.Parent = card
    Instance.new("UICorner", sideBar).CornerRadius = UDim.new(1, 0)
    local topBar = Instance.new("Frame"); topBar.Size = UDim2.new(1, 0, 0, 20); topBar.BackgroundTransparency = 1; topBar.Position = UDim2.new(0, 14, 0, 6); topBar.Parent = card
    local tLabel = Instance.new("TextLabel"); tLabel.Size = UDim2.new(1, -24, 1, 0); tLabel.BackgroundTransparency = 1; tLabel.Font = Enum.Font.GothamBold; tLabel.Text = ""; tLabel.TextColor3 = Colors.TextWhite; tLabel.TextSize = 13; tLabel.TextXAlignment = Enum.TextXAlignment.Left; tLabel.TextTruncate = Enum.TextTruncate.AtEnd; tLabel.Parent = topBar
    local mLabel = Instance.new("TextLabel"); mLabel.Size = UDim2.new(1, -24, 0, 28); mLabel.Position = UDim2.new(0, 14, 0, 26); mLabel.BackgroundTransparency = 1; mLabel.Font = Enum.Font.Gotham; mLabel.Text = ""; mLabel.TextColor3 = Colors.TextSubtle; mLabel.TextSize = 11; mLabel.TextXAlignment = Enum.TextXAlignment.Left; mLabel.TextWrapped = true; mLabel.TextTruncate = Enum.TextTruncate.AtEnd; mLabel.Parent = card
    local rec = {
        slot = slot, card = card, stroke = stroke, sideBar = sideBar,
        tLabel = tLabel, mLabel = mLabel,
        inTw = TweenService:Create(card, NOTIF_IN_TWEEN, {Position = UDim2.new(0, 0, 0, 0)}),
        outTw = TweenService:Create(card, NOTIF_OUT_TWEEN, {BackgroundTransparency = 1, Position = UDim2.new(1, 40, 0, 0)}),
        shownAt = 0, token = 0, closing = false,
    }
    notifPool[i] = rec
    FSYC.notifPool = notifPool
    card.InputBegan:Connect(function(input)
        if not ModeCtl.Accepts(input.UserInputType) then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            DismissNotifCard(rec)
        end
    end)
end
ShowNotification = function(title, text, notifType, duration)
    if not isRunning or not notifContainer or not notifContainer.Parent then return end
    duration = tonumber(duration) or 3.2
    if duration ~= duration or duration <= 0 then duration = 3.2 end
    if duration > 60 then duration = 60 end
    local now = tick()
    local dedupKey = tostring(title) .. "|" .. tostring(text)
    if recentNotifMap[dedupKey] and (now - recentNotifMap[dedupKey] < 1.2) then
        return
    end
    recentNotifMap[dedupKey] = now
    for k, t in pairs(recentNotifMap) do
        if now - t > 5.0 then recentNotifMap[k] = nil end
    end
    local rec = nil
    for i = 1, #notifPool do
        local cand = notifPool[i]
        if cand.shownAt == 0 and not cand.closing then rec = cand; break end
    end
    if not rec then
        rec = notifPool[1]
        for i = 2, #notifPool do
            local cand = notifPool[i]
            if (cand.shownAt or 0) < (rec.shownAt or 0) then rec = cand end
        end
    end
    if not rec then return end
    local accentColor = Colors.Accent
    if notifType == "SUCCESS" then accentColor = Colors.AccentGreen elseif notifType == "WARN" then accentColor = Colors.AccentYellow elseif notifType == "ERROR" then accentColor = Colors.AccentRed end
    rec.token = rec.token + 1
    local tok = rec.token
    rec.closing = false
    rec.shownAt = now
    pcall(function() rec.inTw:Cancel() end)
    pcall(function() rec.outTw:Cancel() end)
    rec.stroke.Color = accentColor
    rec.sideBar.BackgroundColor3 = accentColor
    rec.tLabel.Text = tostring(title)
    rec.mLabel.Text = tostring(text)
    rec.card.BackgroundTransparency = 0.04
    rec.card.Position = UDim2.new(1, 30, 0, 0)
    rec.slot.Visible = true
    pcall(function() rec.inTw:Play() end)
    task.delay(duration, function()
        if tok == rec.token then DismissNotifCard(rec) end
    end)
end
local isHopping = false
local hopLockAt = 0
local lastLocalHopTime = 0
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
ServerHop = function(manualClick)
    if isHopping and (tick() - hopLockAt) < 20 then return end
    local now = tick()
    local prevHopTime = math.max(lastLocalHopTime, (sharedEnv and type(sharedEnv.IdenticalLastHopTime) == "number") and sharedEnv.IdenticalLastHopTime or 0)
    if not manualClick and prevHopTime > 0 and (now - prevHopTime < 85.0) then
        return
    end
    isHopping = true
    hopLockAt = tick()
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
                    local tpOk = pcall(function()
                        TeleportService:TeleportToPlaceInstance(placeId, chosen, LocalPlayer)
                    end)
                    if tpOk then
                        teleported = true
                        FLog("跳服", string.format("已选中并传送：placeId=%s 候选=%d", tostring(placeId), #candidates))
                        return
                    end
                end
            end
        end)
        if not teleported then
            FLogWarn("跳服", "公开服务器列表不可用或无空位，回退随机重连")
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
end)() end
local ToggleUiVisibility
local navList, tabCanvasRefreshers, currentActiveTab, SwitchTab, CreateTab, CloseUI
local FLOATING_BALL_SIZE = DashUI.metrics.touch and 56 or 48
local floatingBall = Instance.new("TextButton")
floatingBall.Name = "FSY"
floatingBall.Size = UDim2.new(0, FLOATING_BALL_SIZE, 0, FLOATING_BALL_SIZE)
floatingBall.Position = UDim2.new(0, 18, 0, 300)
floatingBall.BackgroundColor3 = Colors.Card
floatingBall.BackgroundTransparency = 0.05
floatingBall.BorderSizePixel = 0
floatingBall.Text = ""
floatingBall.AutoButtonColor = false
floatingBall.Visible = false
floatingBall.ZIndex = 2500
floatingBall.Parent = screenGui
table.insert(cleanUpInstances, floatingBall)
do
    local fbCorner = Instance.new("UICorner"); fbCorner.CornerRadius = UDim.new(1, 0); fbCorner.Parent = floatingBall
    local fbStroke = Instance.new("UIStroke"); fbStroke.Color = Colors.BorderAccent; fbStroke.Thickness = 1.5; fbStroke.Transparency = 0.25; fbStroke.Parent = floatingBall
    local fbLabel = Instance.new("TextLabel")
    fbLabel.Name = "Title"
    fbLabel.Size = UDim2.new(1, 0, 1, 0)
    fbLabel.BackgroundTransparency = 1
    fbLabel.Font = Enum.Font.GothamBold
    fbLabel.Text = "FSY"
    fbLabel.TextColor3 = Colors.AccentSoft
    fbLabel.TextSize = 13
    fbLabel.TextXAlignment = Enum.TextXAlignment.Center
    fbLabel.TextYAlignment = Enum.TextYAlignment.Center
    fbLabel.Parent = floatingBall
    local fbStatusDot = Instance.new("Frame")
    fbStatusDot.Name = "StatusDot"
    fbStatusDot.Size = UDim2.new(0, 8, 0, 8)
    fbStatusDot.Position = UDim2.new(1, -9, 1, -9)
    fbStatusDot.BackgroundColor3 = Colors.AccentGreen
    fbStatusDot.BorderSizePixel = 0
    fbStatusDot.ZIndex = 2501
    fbStatusDot.Parent = floatingBall
    Instance.new("UICorner", fbStatusDot).CornerRadius = UDim.new(1, 0)
    local fbDotStroke = Instance.new("UIStroke", fbStatusDot); fbDotStroke.Color = Colors.Card; fbDotStroke.Thickness = 1.5
    RegisterThemeUpdater(function()
        fbStroke.Color = Colors.BorderAccent
        fbLabel.TextColor3 = Colors.AccentSoft
        fbStatusDot.BackgroundColor3 = Colors.AccentGreen
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
        if not ModeCtl.Accepts(input.UserInputType) then return end
        if fbDragging and fbActiveTouch and input.UserInputType == Enum.UserInputType.MouseButton1 then return end
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
        if DashUI.metrics.touch then return end
        PlayQuickTween(floatingBall, { BackgroundColor3 = Colors.RowHover })
        PlayQuickTween(fbStroke, { Color = Colors.AccentSoft, Transparency = 0.05 })
    end)
    floatingBall.MouseLeave:Connect(function()
        if DashUI.metrics.touch then return end
        PlayQuickTween(floatingBall, { BackgroundColor3 = Colors.Card })
        PlayQuickTween(fbStroke, { Color = Colors.BorderAccent, Transparency = 0.25 })
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
mainFrame.Size = UDim2.fromOffset(DashUI.metrics.winW, DashUI.metrics.winH)
mainFrame.BackgroundColor3 = Colors.Background
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Visible = true
mainFrame.ZIndex = 3000
mainFrame.Active = true
mainFrame.Parent = screenGui
table.insert(cleanUpInstances, mainFrame)
mainFrameScale = Instance.new("UIScale")
mainFrameScale.Parent = mainFrame
mainFrameScale.Scale = Config.UIScale
do
    local lastScaledViewport = nil
    local lastScaledConfigVal = nil
    local lastComputedTargetScale = nil
    UpdateMainFrameScale = function(forceApply)
        if not mainFrame or not mainFrame.Parent then return end
        local cam = Workspace.CurrentCamera or Camera
        local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
        if vp.X <= 0 or vp.Y <= 0 then return end
        local cfgScale = Config.UIScale or 0.85
        if not forceApply and lastScaledViewport == vp and lastScaledConfigVal == cfgScale then
            if mainFrameScale and mainFrameScale.Parent and lastComputedTargetScale and mainFrameScale.Scale ~= lastComputedTargetScale then
                mainFrameScale.Scale = lastComputedTargetScale
            end
            return
        end
        lastScaledViewport = vp
        lastScaledConfigVal = cfgScale
        local baseW = DashUI.metrics.winW
        local baseH = DashUI.metrics.winH
        local maxScaleX = (vp.X - 24) / baseW
        local maxScaleY = (vp.Y - 20) / baseH
        local autoMaxScale = math.clamp(math.min(maxScaleX, maxScaleY), 0.45, 1.25)
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
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 14); mc.Parent = mainFrame
    local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderSubtle; ms.Thickness = 1; ms.Transparency = 0.1; ms.Parent = mainFrame
    RegisterThemeUpdater(function() ms.Color = Colors.BorderSubtle end)
end
collapsibleSections = {}
searchState = {rows = {}, query = "", refresh = nil, box = nil, count = nil, clear = nil}
do (function()
local UIM = DashUI.metrics
local CATEGORY_ORDER = {"仪表盘", "钓鱼", "Boss", "任务", "神灵", "传送", "视觉", "移动", "配置文件"}
DashUI.categories = CATEGORY_ORDER
local CATEGORY_META = {
    ["仪表盘"]   = {icon = "仪"},
    ["钓鱼"]     = {icon = "钓"},
    ["Boss"]     = {icon = "战"},
    ["任务"]     = {icon = "任"},
    ["神灵"]     = {icon = "神"},
    ["传送"]     = {icon = "传"},
    ["视觉"]     = {icon = "视"},
    ["移动"]     = {icon = "移"},
    ["配置文件"] = {icon = "设"},
}
local TAB_TO_CAT = {}
for i = 1, #CATEGORY_ORDER do TAB_TO_CAT[CATEGORY_ORDER[i]] = CATEGORY_ORDER[i] end
local categoryPages = {}
local categoryRefreshers = {}
tabCanvasRefreshers = {}
local navItems = {}
local containerMeta = setmetatable({}, { __mode = "k" })
DashUI.containerMeta = containerMeta
local currentCategory = nil
local function BindVerticalCanvas(scrollFrame, listLayout, extraPadding)
    extraPadding = extraPadding or 0
    scrollFrame.Active = true
    scrollFrame.ScrollingEnabled = true
    scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    scrollFrame.ElasticBehavior = Enum.ElasticBehavior.Never
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    scrollFrame.ScrollBarThickness = math.max(scrollFrame.ScrollBarThickness, 3)
    local lastCanvasH = -1
    local refreshing = false
    local listPadding = 0
    if listLayout and listLayout.Padding then
        listPadding = listLayout.Padding.Offset or 0
    end
    local cachedUiPad = scrollFrame:FindFirstChildOfClass("UIPadding")
    local function measureContentHeight()
        local padY = 0
        local uiPad = (cachedUiPad and cachedUiPad.Parent == scrollFrame) and cachedUiPad or scrollFrame:FindFirstChildOfClass("UIPadding")
        if uiPad then
            cachedUiPad = uiPad
            padY = (uiPad.PaddingTop and uiPad.PaddingTop.Offset or 0)
                + (uiPad.PaddingBottom and uiPad.PaddingBottom.Offset or 0)
        end
        local scale = 1
        if mainFrameScale and mainFrameScale.Parent and type(mainFrameScale.Scale) == "number" and mainFrameScale.Scale > 0.05 then
            scale = mainFrameScale.Scale
        end
        local totalAbs = 0
        local visibleCount = 0
        for _, child in ipairs(scrollFrame:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible then
                local h = child.AbsoluteSize.Y
                if h < 1 and child.AutomaticSize ~= Enum.AutomaticSize.None then
                    local subLayout = child:FindFirstChildOfClass("UIListLayout")
                    if subLayout and subLayout.AbsoluteContentSize.Y > 0 then
                        h = subLayout.AbsoluteContentSize.Y * scale
                    else
                        local subH = 0
                        for _, sub in ipairs(child:GetChildren()) do
                            if sub:IsA("GuiObject") and sub.Visible then
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
            totalAbs = totalAbs + (listPadding * (visibleCount - 1) * scale)
        end
        local totalLocal = totalAbs / scale
        local layoutH = (listLayout and listLayout.AbsoluteContentSize.Y or 0) + padY
        totalLocal = math.max(totalLocal + padY, layoutH)
        return totalLocal + extraPadding
    end
    local function refreshCanvas()
        if refreshing or not scrollFrame or not scrollFrame.Parent or not scrollFrame.Visible then return end
        refreshing = true
        pcall(function()
            local contentHeight = measureContentHeight()
            local viewportHeight = scrollFrame.AbsoluteWindowSize.Y
            if viewportHeight < 1 then viewportHeight = scrollFrame.AbsoluteSize.Y end
            local canvasHeight = math.max(math.ceil(contentHeight), 1)
            if math.abs(canvasHeight - lastCanvasH) >= 1 then
                lastCanvasH = canvasHeight
                scrollFrame.CanvasSize = UDim2.new(0, 0, 0, canvasHeight)
            end
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
    local function runScheduledRefresh()
        refreshQueued = false
        lastRefreshTime = tick()
        if isRunning then refreshCanvas() end
    end
    local function requestRefresh()
        if refreshQueued or not isRunning or not scrollFrame or not scrollFrame.Parent or not scrollFrame.Visible then return end
        refreshQueued = true
        local elapsed = tick() - lastRefreshTime
        if elapsed >= 0.15 then
            task.defer(runScheduledRefresh)
        else
            task.delay(0.15 - elapsed, runScheduledRefresh)
        end
    end
    local childSizeConns = setmetatable({}, { __mode = "k" })
    local function bindChildSignals(child)
        if child:IsA("GuiObject") and not childSizeConns[child] then
            local conn = child:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestRefresh)
            childSizeConns[child] = conn
            table.insert(activeConnections, conn)
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
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, UIM.topH)
topBar.BackgroundColor3 = Colors.SidebarBg
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 14)
do
    local cover = Instance.new("Frame")
    cover.Size = UDim2.new(1, 0, 0, 14)
    cover.Position = UDim2.new(0, 0, 1, -14)
    cover.BackgroundColor3 = Colors.SidebarBg
    cover.BorderSizePixel = 0
    cover.Parent = topBar
    local div = Instance.new("Frame")
    div.Size = UDim2.new(1, 0, 0, 1)
    div.Position = UDim2.new(0, 0, 1, -1)
    div.BackgroundColor3 = Colors.Divider
    div.BorderSizePixel = 0
    div.Parent = topBar
end
do
    local brandPill = Instance.new("Frame")
    brandPill.Size = UDim2.new(0, 4, 0, 18)
    brandPill.Position = UDim2.new(0, 16, 0.5, -9)
    brandPill.BackgroundColor3 = Colors.Accent
    brandPill.BorderSizePixel = 0
    brandPill.Parent = topBar
    Instance.new("UICorner", brandPill).CornerRadius = UDim.new(1, 0)
    local brandTitle = Instance.new("TextLabel")
    brandTitle.Size = UDim2.new(0, 46, 1, 0)
    brandTitle.Position = UDim2.new(0, 28, 0, 0)
    brandTitle.BackgroundTransparency = 1
    brandTitle.Font = Enum.Font.GothamBold
    brandTitle.Text = "FSY"
    brandTitle.TextColor3 = Colors.TextWhite
    brandTitle.TextSize = 17
    brandTitle.TextXAlignment = Enum.TextXAlignment.Left
    brandTitle.Parent = topBar
    local verChip = Instance.new("Frame")
    verChip.Size = UDim2.new(0, 58, 0, 20)
    verChip.Position = UDim2.new(0, 76, 0.5, -10)
    verChip.BackgroundColor3 = Colors.AccentDeep
    verChip.BorderSizePixel = 0
    verChip.Parent = topBar
    Instance.new("UICorner", verChip).CornerRadius = UDim.new(0, 6)
    local verStroke = Instance.new("UIStroke", verChip)
    verStroke.Color = Colors.BorderAccent
    verStroke.Thickness = 1
    verStroke.Transparency = 0.55
    local verLabel = Instance.new("TextLabel")
    verLabel.Size = UDim2.new(1, 0, 1, 0)
    verLabel.BackgroundTransparency = 1
    verLabel.Font = Enum.Font.GothamBold
    verLabel.Text = FSY_VERSION .. " · 9页"
    verLabel.TextColor3 = Colors.AccentSoft
    verLabel.TextSize = 10
    verLabel.Parent = verChip
    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(0, 300, 1, 0)
    subtitle.Position = UDim2.new(0, 146, 0, 0)
    subtitle.BackgroundTransparency = 1
    subtitle.Font = Enum.Font.Gotham
    subtitle.Text = "HEAVYWEIGHT FISHING · 薄荷鲜绿"
    if UIM.compactNav then
        subtitle.Visible = false
        verChip.Size = UDim2.new(0, 50, 0, 18)
        verChip.Position = UDim2.new(0, 72, 0.5, -9)
        verLabel.TextSize = 9
    end
    subtitle.TextColor3 = Colors.TextMuted
    subtitle.TextSize = 10
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = topBar
    RegisterThemeUpdater(function()
        brandPill.BackgroundColor3 = Colors.Accent
        verChip.BackgroundColor3 = Colors.AccentDeep
        verStroke.Color = Colors.BorderAccent
        verLabel.TextColor3 = Colors.AccentSoft
        subtitle.TextColor3 = Colors.TextMuted
    end)
end
local winControls = Instance.new("Frame")
winControls.Size = UDim2.new(0, 80, 1, 0)
winControls.Position = UDim2.new(1, -88, 0, 0)
winControls.BackgroundTransparency = 1
winControls.Parent = topBar
local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 34, 0, 26)
minBtn.Position = UDim2.new(0, 0, 0.5, -13)
minBtn.BackgroundColor3 = Colors.ControlBg
minBtn.BackgroundTransparency = 0.35
minBtn.Font = Enum.Font.GothamBold
minBtn.Text = "—"
minBtn.TextColor3 = Colors.TextSubtle
minBtn.TextSize = 13
minBtn.BorderSizePixel = 0
minBtn.AutoButtonColor = false
minBtn.Parent = winControls
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 7)
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 34, 0, 26)
closeBtn.Position = UDim2.new(0, 40, 0.5, -13)
closeBtn.BackgroundColor3 = Colors.ControlBg
closeBtn.BackgroundTransparency = 0.35
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Text = "✕"
closeBtn.TextColor3 = Colors.AccentRed
closeBtn.TextSize = 12
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
closeBtn.Parent = winControls
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 7)
local function bindHover(btn, normalColor, hoverColor, normalAlpha, hoverAlpha)
    btn.MouseEnter:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = hoverColor, BackgroundTransparency = hoverAlpha })
    end)
    btn.MouseLeave:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = normalColor, BackgroundTransparency = normalAlpha })
    end)
end
bindHover(minBtn, Colors.ControlBg, Colors.RowHover, 0.35, 0)
bindHover(closeBtn, Colors.ControlBg, Colors.RowHover, 0.35, 0)
RegisterThemeUpdater(function()
    minBtn.BackgroundColor3 = Colors.ControlBg
    closeBtn.BackgroundColor3 = Colors.ControlBg
    minBtn.TextColor3 = Colors.TextSubtle
    closeBtn.TextColor3 = Colors.AccentRed
end)
do
    local dragging = false
    local activeDragTouch = nil
    local dragStart = nil
    local startPos = nil
    local titleInputEndConn = nil
    local titleDragChangedConn = nil
    local titleDragEndedConn = nil
    local function updateMainFrameDrag(inputPos)
        if not dragging or not dragStart or not startPos then return end
        local delta = inputPos - dragStart
        local vp = (screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize)
            or ((Workspace.CurrentCamera or Camera) and (Workspace.CurrentCamera or Camera).ViewportSize)
            or Vector2.new(1280, 720)
        local absX = startPos.X.Scale * vp.X + startPos.X.Offset + delta.X
        local absY = startPos.Y.Scale * vp.Y + startPos.Y.Offset + delta.Y
        local uiScale = (mainFrameScale and mainFrameScale.Parent and tonumber(mainFrameScale.Scale)) or 1
        local frameW = mainFrame.AbsoluteSize.X > 0 and mainFrame.AbsoluteSize.X or (UIM.winW * uiScale)
        local frameH = mainFrame.AbsoluteSize.Y > 0 and mainFrame.AbsoluteSize.Y or (UIM.winH * uiScale)
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
    local function stopTitleDrag()
        dragging = false
        activeDragTouch = nil
        titleInputEndConn = DisconnectTempDragConn(titleInputEndConn)
        titleDragChangedConn = DisconnectTempDragConn(titleDragChangedConn)
        titleDragEndedConn = DisconnectTempDragConn(titleDragEndedConn)
    end
    topBar.InputBegan:Connect(function(input)
        if not ModeCtl.Accepts(input.UserInputType) then return end
        if dragging and activeDragTouch and input.UserInputType == Enum.UserInputType.MouseButton1 then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            stopTitleDrag()
            dragging = true
            activeDragTouch = (input.UserInputType == Enum.UserInputType.Touch) and input or nil
            dragStart = input.Position
            startPos = mainFrame.Position
            titleInputEndConn = RegisterTempDragConn(input.Changed:Connect(function()
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
local bodyFrame = Instance.new("Frame")
bodyFrame.Name = "Body"
bodyFrame.Size = UDim2.new(1, 0, 1, -(UIM.topH + UIM.footH))
bodyFrame.Position = UDim2.new(0, 0, 0, UIM.topH)
bodyFrame.BackgroundTransparency = 1
bodyFrame.Parent = mainFrame
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, UIM.navW, 1, 0)
sidebar.BackgroundColor3 = Colors.SidebarBg
sidebar.BorderSizePixel = 0
sidebar.Parent = bodyFrame
do
    local d = Instance.new("Frame")
    d.Size = UDim2.new(0, 1, 1, 0)
    d.Position = UDim2.new(1, -1, 0, 0)
    d.BackgroundColor3 = Colors.Divider
    d.BorderSizePixel = 0
    d.Parent = sidebar
end
local navCaption = Instance.new("TextLabel")
navCaption.Size = UDim2.new(1, -28, 0, 16)
navCaption.Position = UDim2.new(0, 16, 0, 12)
navCaption.BackgroundTransparency = 1
navCaption.Font = Enum.Font.GothamBold
navCaption.Text = "功能"
navCaption.TextColor3 = Colors.TextMuted
navCaption.TextSize = 10
navCaption.TextXAlignment = Enum.TextXAlignment.Left
navCaption.Parent = sidebar
navList = Instance.new("ScrollingFrame")
navList.Name = "NavList"
navList.Size = UDim2.new(1, 0, 1, -74)
navList.Position = UDim2.new(0, 0, 0, 32)
navList.BackgroundTransparency = 1
navList.BorderSizePixel = 0
navList.ScrollBarThickness = 2
navList.ScrollBarImageColor3 = Colors.BorderSubtle
navList.CanvasSize = UDim2.new(0, 0, 0, 0)
navList.AutomaticCanvasSize = Enum.AutomaticSize.None
navList.Active = true
navList.ScrollingEnabled = true
navList.Parent = sidebar
do
    local nl = Instance.new("UIListLayout")
    nl.SortOrder = Enum.SortOrder.LayoutOrder
    nl.Padding = UDim.new(0, 5)
    nl.Parent = navList
    local np = Instance.new("UIPadding")
    np.PaddingTop = UDim.new(0, 2)
    np.PaddingLeft = UDim.new(0, 10)
    np.PaddingRight = UDim.new(0, 10)
    np.Parent = navList
    BindVerticalCanvas(navList, nl, 8)
end
local navStatus = Instance.new("Frame")
navStatus.Size = UDim2.new(1, -20, 0, 34)
navStatus.Position = UDim2.new(0, 10, 1, -42)
navStatus.BackgroundColor3 = Colors.Card
navStatus.BackgroundTransparency = 0.25
navStatus.BorderSizePixel = 0
navStatus.Parent = sidebar
Instance.new("UICorner", navStatus).CornerRadius = UDim.new(0, 8)
do
    local stStroke = Instance.new("UIStroke", navStatus)
    stStroke.Color = Colors.BorderSubtle
    stStroke.Thickness = 1
    stStroke.Transparency = 0.4
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 7, 0, 7)
    dot.Position = UDim2.new(0, 9, 0.5, -3.5)
    dot.BackgroundColor3 = Colors.AccentGreen
    dot.BorderSizePixel = 0
    dot.Parent = navStatus
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local stText = Instance.new("TextLabel")
    stText.Size = UDim2.new(1, -22, 1, 0)
    stText.Position = UDim2.new(0, 20, 0, 0)
    stText.BackgroundTransparency = 1
    stText.Font = Enum.Font.Gotham
    stText.Text = "运行中 · 低占用模式"
    stText.TextColor3 = Colors.TextMuted
    stText.TextSize = 9
    stText.TextXAlignment = Enum.TextXAlignment.Left
    stText.Parent = navStatus
    RegisterThemeUpdater(function()
        stText.TextColor3 = Colors.TextMuted
        dot.BackgroundColor3 = Colors.AccentGreen
        stStroke.Color = Colors.BorderSubtle
    end)
end
if UIM.compactNav then
    navStatus.Visible = false
    navList.Size = UDim2.new(1, 0, 1, -40)
    navList.Position = UDim2.new(0, 0, 0, 28)
    navCaption.Text = "功能"
    navCaption.Position = UDim2.new(0, 0, 0, 8)
    navCaption.Size = UDim2.new(1, 0, 0, 16)
    navCaption.TextXAlignment = Enum.TextXAlignment.Center
end
local contentArea = Instance.new("Frame")
contentArea.Name = "ContentArea"
contentArea.Size = UDim2.new(1, -UIM.navW, 1, 0)
contentArea.Position = UDim2.new(0, UIM.navW, 0, 0)
contentArea.BackgroundTransparency = 1
contentArea.Parent = bodyFrame
local searchBar = Instance.new("Frame")
searchBar.Name = "SearchBar"
searchBar.Size = UDim2.new(1, -(UIM.padX * 2), 0, UIM.searchH)
searchBar.Position = UDim2.new(0, UIM.padX, 0, 0)
searchBar.BackgroundTransparency = 1
searchBar.Parent = contentArea
local searchBoxBg = Instance.new("Frame")
searchBoxBg.Name = "SearchBoxBg"
searchBoxBg.Size = UDim2.new(1, -46, 0, UIM.searchH - 8)
searchBoxBg.Position = UDim2.new(0, 0, 0, 4)
searchBoxBg.BackgroundColor3 = Colors.InputBg
searchBoxBg.BorderSizePixel = 0
searchBoxBg.Parent = searchBar
Instance.new("UICorner", searchBoxBg).CornerRadius = UDim.new(0, 9)
local searchStroke = Instance.new("UIStroke", searchBoxBg)
searchStroke.Color = Colors.BorderSubtle
searchStroke.Thickness = 1
searchStroke.Transparency = 0.3
local searchIcon = Instance.new("TextLabel")
searchIcon.Size = UDim2.new(0, 26, 1, 0)
searchIcon.Position = UDim2.new(0, 4, 0, 0)
searchIcon.BackgroundTransparency = 1
searchIcon.Font = Enum.Font.GothamBold
searchIcon.Text = "🔍"
searchIcon.TextSize = 15
searchIcon.TextColor3 = Colors.TextMuted
searchIcon.Parent = searchBoxBg
local searchBox = Instance.new("TextBox")
searchBox.Name = "SearchBox"
searchBox.Size = UDim2.new(1, -102, 1, 0)
searchBox.Position = UDim2.new(0, 30, 0, 0)
searchBox.BackgroundTransparency = 1
searchBox.Font = Enum.Font.Gotham
searchBox.Text = ""
searchBox.PlaceholderText = "搜索功能名称：抛竿 / 传送 / 神灵 / ESP / 票据 …"
searchBox.PlaceholderColor3 = Colors.TextMuted
searchBox.TextColor3 = Colors.TextWhite
searchBox.TextSize = 12
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.ClearTextOnFocus = false
searchBox.Parent = searchBoxBg
local searchCount = Instance.new("TextLabel")
searchCount.Name = "SearchCount"
searchCount.Size = UDim2.new(0, 64, 1, 0)
searchCount.Position = UDim2.new(1, -68, 0, 0)
searchCount.BackgroundTransparency = 1
searchCount.Font = Enum.Font.GothamBold
searchCount.Text = ""
searchCount.TextSize = 11
searchCount.TextColor3 = Colors.TextMuted
searchCount.TextXAlignment = Enum.TextXAlignment.Right
searchCount.Parent = searchBoxBg
local searchClear = Instance.new("TextButton")
searchClear.Name = "SearchClear"
searchClear.Size = UDim2.new(0, 38, 0, UIM.searchH - 8)
searchClear.Position = UDim2.new(1, -38, 0, 4)
searchClear.BackgroundColor3 = Colors.ControlBg
searchClear.BackgroundTransparency = 0.45
searchClear.Font = Enum.Font.GothamBold
searchClear.Text = "✕"
searchClear.TextColor3 = Colors.TextMuted
searchClear.TextSize = 12
searchClear.BorderSizePixel = 0
searchClear.AutoButtonColor = false
searchClear.Parent = searchBar
Instance.new("UICorner", searchClear).CornerRadius = UDim.new(0, 9)
bindHover(searchClear, Colors.ControlBg, Colors.RowHover, 0.45, 0)
searchState.box = searchBox
searchState.count = searchCount
searchState.clear = searchClear
RegisterThemeUpdater(function()
    searchBoxBg.BackgroundColor3 = Colors.InputBg
    searchStroke.Color = Colors.BorderSubtle
    searchClear.BackgroundColor3 = Colors.ControlBg
    searchBox.TextColor3 = Colors.TextWhite
    searchBox.PlaceholderColor3 = Colors.TextMuted
    searchCount.TextColor3 = Colors.TextMuted
    searchClear.TextColor3 = Colors.TextMuted
    searchIcon.TextColor3 = Colors.TextMuted
    navCaption.TextColor3 = Colors.TextMuted
end)
local PAGE_TOP = UIM.searchH
local function createCategoryPage(catName)
    local page = Instance.new("ScrollingFrame")
    page.Name = "CategoryPage_" .. catName
    page.Size = UDim2.new(1, 0, 1, -PAGE_TOP)
    page.Position = UDim2.new(0, 0, 0, PAGE_TOP)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 4
    page.ScrollBarImageColor3 = Colors.BorderSubtle
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.None
    page.Active = true
    page.ScrollingEnabled = true
    page.ScrollingDirection = Enum.ScrollingDirection.Y
    page.ElasticBehavior = Enum.ElasticBehavior.Never
    page.Visible = false
    page.Parent = contentArea
    local pl = Instance.new("UIListLayout")
    pl.SortOrder = Enum.SortOrder.LayoutOrder
    pl.Padding = UDim.new(0, UIM.gap)
    pl.Parent = page
    local pp = Instance.new("UIPadding")
    pp.PaddingTop = UDim.new(0, 4)
    pp.PaddingBottom = UDim.new(0, 26)
    pp.PaddingLeft = UDim.new(0, UIM.padX)
    pp.PaddingRight = UDim.new(0, UIM.padX)
    pp.Parent = page
    local refresher = BindVerticalCanvas(page, pl, 30)
    categoryRefreshers[catName] = refresher
    tabCanvasRefreshers[catName] = refresher
    table.insert(activeConnections, page:GetPropertyChangedSignal("Visible"):Connect(function()
        if isRunning and page.Visible then
            task.defer(refresher)
            task.delay(0.12, function() if isRunning and page.Visible then refresher() end end)
        end
    end))
    RegisterThemeUpdater(function() page.ScrollBarImageColor3 = Colors.BorderSubtle end)
    categoryPages[catName] = page
    return page
end
for i = 1, #CATEGORY_ORDER do
    createCategoryPage(CATEGORY_ORDER[i])
end
local function setNavActive(catName)
    for name, item in pairs(navItems) do
        local active = (name == catName)
        item.btn.BackgroundColor3 = active and Colors.AccentDeep or Colors.SidebarBg
        item.btn.BackgroundTransparency = active and 0 or 1
        item.bar.Visible = active
        item.label.TextColor3 = active and Colors.TextWhite or Colors.TextSubtle
        if item.icon then
            item.icon.TextColor3 = active and Colors.AccentSoft or Colors.TextMuted
        end
    end
end
local function createNavItem(catName, iconChar)
    local btn = Instance.new("TextButton")
    btn.Name = "Nav_" .. catName
    btn.Size = UDim2.new(1, 0, 0, UIM.navH)
    btn.BackgroundColor3 = Colors.SidebarBg
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.BorderSizePixel = 0
    btn.Parent = navList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)
    local bar = Instance.new("Frame")
    bar.Name = "ActiveBar"
    bar.Size = UDim2.new(0, 3, 0, 18)
    bar.Position = UDim2.new(0, 3, 0.5, -9)
    bar.BackgroundColor3 = Colors.AccentSoft
    bar.BorderSizePixel = 0
    bar.Visible = false
    bar.Parent = btn
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.Text = catName
    label.TextColor3 = Colors.TextSubtle
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Parent = btn
    if UIM.compactNav then
        label.Size = UDim2.new(1, -4, 0, 14)
        label.Position = UDim2.new(0, 2, 0, UIM.navH - 19)
        label.TextSize = 9
        label.TextXAlignment = Enum.TextXAlignment.Center
        local icon = Instance.new("TextLabel")
        icon.Name = "Icon"
        icon.Size = UDim2.new(1, -4, 0, 18)
        icon.Position = UDim2.new(0, 2, 0, 8)
        icon.BackgroundTransparency = 1
        icon.Font = Enum.Font.GothamBold
        icon.Text = tostring(iconChar or "")
        icon.TextColor3 = Colors.TextMuted
        icon.TextSize = 13
        icon.TextXAlignment = Enum.TextXAlignment.Center
        icon.Parent = btn
        navItems[catName] = { btn = btn, bar = bar, label = label, icon = icon }
    else
        label.Size = UDim2.new(1, -16, 1, 0)
        label.Position = UDim2.new(0, 11, 0, 0)
        label.TextSize = 12
        label.TextXAlignment = Enum.TextXAlignment.Left
        navItems[catName] = { btn = btn, bar = bar, label = label }
    end
    btn.MouseEnter:Connect(function()
        if UIM.touch then return end
        if currentCategory ~= catName then
            PlayQuickTween(btn, { BackgroundColor3 = Colors.RowHover, BackgroundTransparency = 0.55 })
        end
    end)
    btn.MouseLeave:Connect(function()
        if UIM.touch then return end
        if currentCategory ~= catName then
            PlayQuickTween(btn, { BackgroundColor3 = Colors.SidebarBg, BackgroundTransparency = 1 })
        end
    end)
    BindClick(btn, function()
        if SwitchTab then SwitchTab(catName) end
    end)
    return btn
end
for i = 1, #CATEGORY_ORDER do
    local catName = CATEGORY_ORDER[i]
    local meta = CATEGORY_META[catName]
    createNavItem(catName, meta and meta.icon)
end
SwitchTab = function(tabName)
    local catName = TAB_TO_CAT[tabName] or tabName
    if not categoryPages[catName] then catName = CATEGORY_ORDER[1] end
    for fn in pairs(activeSliderCleanupFns) do pcall(fn) end
    table.clear(activeSliderCleanupFns)
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
    currentActiveTab = catName
    currentCategory = catName
    for name, page in pairs(categoryPages) do
        local isTarget = (name == catName)
        if page.Visible ~= isTarget then page.Visible = isTarget end
    end
    setNavActive(catName)
    local refresher = categoryRefreshers[catName]
    if refresher then task.defer(refresher) end
    if searchState.refresh and searchState.query ~= "" then
        task.delay(0.05, searchState.refresh)
    end
end
CreateTab = function(name)
    local catName = TAB_TO_CAT[name] or "设置"
    local page = categoryPages[catName] or categoryPages[CATEGORY_ORDER[1]]
    local container = Instance.new("Frame")
    container.Name = "Section_" .. tostring(name)
    container.Size = UDim2.new(1, 0, 0, 0)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.BackgroundTransparency = 1
    container.BorderSizePixel = 0
    container.Parent = page
    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, UIM.gap)
    layout.Parent = container
    containerMeta[container] = {cat = catName, tab = name}
    return container
end
DashUI.resolveCategory = function(obj)
    local node, guard = obj, 0
    while node and guard < 16 do
        local meta = containerMeta[node]
        if meta then return meta.cat, meta.tab end
        node = node.Parent
        guard = guard + 1
    end
    return currentCategory or CATEGORY_ORDER[1]
end
DashUI.switchCategory = function(catName)
    if SwitchTab then SwitchTab(catName) end
end
local footerBar = Instance.new("Frame")
footerBar.Name = "FooterBar"
footerBar.Size = UDim2.new(1, 0, 0, UIM.footH)
footerBar.Position = UDim2.new(0, 0, 1, -UIM.footH)
footerBar.BackgroundColor3 = Colors.SidebarBg
footerBar.BorderSizePixel = 0
footerBar.Parent = mainFrame
Instance.new("UICorner", footerBar).CornerRadius = UDim.new(0, 14)
do
    local cover = Instance.new("Frame")
    cover.Size = UDim2.new(1, 0, 0, 14)
    cover.BackgroundColor3 = Colors.SidebarBg
    cover.BorderSizePixel = 0
    cover.Parent = footerBar
    local div = Instance.new("Frame")
    div.Size = UDim2.new(1, 0, 0, 1)
    div.BackgroundColor3 = Colors.Divider
    div.BorderSizePixel = 0
    div.Parent = footerBar
end
local footerBrand = Instance.new("TextLabel")
footerBrand.Size = UDim2.new(0, 340, 1, 0)
footerBrand.Position = UDim2.new(0, 14, 0, 0)
footerBrand.BackgroundTransparency = 1
footerBrand.Font = Enum.Font.Gotham
footerBrand.Text = string.format("FSY %s · %s · 输入隔离%s", FSY_VERSION, ModeCtl.Label(), Config.InputIsolation and "开" or "关")
footerBrand.TextColor3 = Colors.TextMuted
footerBrand.TextSize = 9
footerBrand.TextXAlignment = Enum.TextXAlignment.Left
footerBrand.Parent = footerBar
local footerKey = Instance.new("TextLabel")
footerKey.Size = UDim2.new(0, 300, 1, 0)
footerKey.Position = UDim2.new(1, -314, 0, 0)
footerKey.BackgroundTransparency = 1
footerKey.Font = Enum.Font.Gotham
footerKey.Text = ModeCtl.IsMobile() and "触屏 · 右上角 FSY 球收放" or "[R-CTRL] 菜单 · [END] 停止"
footerKey.TextColor3 = Colors.TextMuted
footerKey.TextSize = 9
footerKey.TextXAlignment = Enum.TextXAlignment.Right
footerKey.Parent = footerBar
RegisterThemeUpdater(function()
    footerBrand.TextColor3 = Colors.TextMuted
    footerKey.TextColor3 = Colors.TextMuted
end)
ModeCtl.OnChange(function()
    footerBrand.Text = string.format("FSY %s · %s · 输入隔离%s", FSY_VERSION, ModeCtl.Label(), Config.InputIsolation and "开" or "关")
    footerKey.Text = ModeCtl.IsMobile() and "触屏 · 右上角 FSY 球收放" or "[R-CTRL] 菜单 · [END] 停止"
end)
local isUiAnimating = false
local pendingUiToggle = false
local UI_OPEN_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UI_CLOSE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BALL_POP_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function ApplyPendingUiToggle()
    if not pendingUiToggle then return end
    pendingUiToggle = false
    if isUiAnimating or not isRunning then return end
    if ToggleUiVisibility then ToggleUiVisibility() end
end
local function OpenUI()
    if not isRunning or not mainFrame or isUiAnimating then return end
    isUiAnimating = true
    if screenGui then
        if not screenGui.Enabled then screenGui.Enabled = true end
        screenGui.DisplayOrder = 100
    end
    mainFrame.ZIndex = 3000
    UpdateMainFrameScale(true)
    local targetScale = (mainFrameScale and mainFrameScale.Scale) or (Config.UIScale or 0.85)
    if mainFrameScale then mainFrameScale.Scale = targetScale * 0.94 end
    mainFrame.BackgroundTransparency = 0.15
    mainFrame.Visible = true
    if floatingBall then floatingBall.Visible = false end
    if mainFrameScale then PlayQuickTween(mainFrameScale, {Scale = targetScale}, UI_OPEN_TWEEN) end
    PlayQuickTween(mainFrame, {BackgroundTransparency = 0}, UI_OPEN_TWEEN)
    local th
    th = task.delay(0.17, function()
        if th then activeThreads[th] = nil end
        if not isRunning then return end
        isUiAnimating = false
        if mainFrame and mainFrame.Parent then mainFrame.BackgroundTransparency = 0 end
        if UpdateMainFrameScale then UpdateMainFrameScale(true) end
        ApplyPendingUiToggle()
    end)
    activeThreads[th] = true
end
CloseUI = function()
    if not isRunning or not mainFrame or isUiAnimating then return end
    for fn in pairs(activeSliderCleanupFns) do pcall(fn) end
    table.clear(activeSliderCleanupFns)
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
    if DashUI._hideTip then DashUI._hideTip() end
    if DashUI._closeUnloadConfirm then pcall(DashUI._closeUnloadConfirm) end
    isUiAnimating = true
    local baseScale = (mainFrameScale and mainFrameScale.Scale) or (Config.UIScale or 0.85)
    if mainFrameScale then PlayQuickTween(mainFrameScale, {Scale = baseScale * 0.94}, UI_CLOSE_TWEEN) end
    PlayQuickTween(mainFrame, {BackgroundTransparency = 0.3}, UI_CLOSE_TWEEN)
    local th
    th = task.delay(0.15, function()
        if th then activeThreads[th] = nil end
        if not isRunning then return end
        if mainFrame and mainFrame.Parent then
            mainFrame.Visible = false
            mainFrame.BackgroundTransparency = 0
            if UpdateMainFrameScale then UpdateMainFrameScale(true) end
        end
        if floatingBall and floatingBall.Parent then
            floatingBall.Visible = true
            PlayQuickTween(floatingBall, {Size = UDim2.new(0, FLOATING_BALL_SIZE, 0, FLOATING_BALL_SIZE)}, BALL_POP_TWEEN)
        end
        isUiAnimating = false
        ApplyPendingUiToggle()
    end)
    activeThreads[th] = true
end
DashUI._openUI = OpenUI
ToggleUiVisibility = function()
    if isUiAnimating then
        pendingUiToggle = not pendingUiToggle
        return
    end
    if mainFrame and mainFrame.Visible then
        CloseUI()
    else
        OpenUI()
    end
end
BindClick(minBtn, ToggleUiVisibility)
do
    local confirmOverlay = Instance.new("Frame")
    confirmOverlay.Name = "UnloadConfirmOverlay"
    confirmOverlay.Size = UDim2.new(1, 0, 1, 0)
    confirmOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    confirmOverlay.BackgroundTransparency = 0.5
    confirmOverlay.BorderSizePixel = 0
    confirmOverlay.ZIndex = 4000
    confirmOverlay.Active = false
    confirmOverlay.Visible = false
    confirmOverlay.Parent = screenGui
    table.insert(cleanUpInstances, confirmOverlay)
    local card = Instance.new("Frame")
    card.Name = "ConfirmCard"
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.new(0, 320, 0, 164)
    card.BackgroundColor3 = Colors.Card
    card.BorderSizePixel = 0
    card.ZIndex = 4001
    card.Parent = confirmOverlay
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 14)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Colors.BorderAccent
    stroke.Thickness = 1
    stroke.Transparency = 0.35
    stroke.Parent = card
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -28, 0, 24)
    title.Position = UDim2.new(0, 16, 0, 16)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "确认退出 FSY？"
    title.TextColor3 = Colors.TextWhite
    title.TextSize = 15
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 4002
    title.Parent = card
    local desc = Instance.new("TextLabel")
    desc.Size = UDim2.new(1, -32, 0, 44)
    desc.Position = UDim2.new(0, 16, 0, 46)
    desc.BackgroundTransparency = 1
    desc.Font = Enum.Font.Gotham
    desc.Text = "退出后将停止挂机并恢复游戏设置，可随时重新注入脚本。"
    desc.TextColor3 = Colors.TextMuted
    desc.TextSize = 11
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextWrapped = true
    desc.ZIndex = 4002
    desc.Parent = card
    local cancelBtn = Instance.new("TextButton")
    cancelBtn.Size = UDim2.new(0, 128, 0, 34)
    cancelBtn.Position = UDim2.new(0, 16, 1, -50)
    cancelBtn.BackgroundColor3 = Colors.ControlBg
    cancelBtn.Font = Enum.Font.GothamBold
    cancelBtn.Text = "取消"
    cancelBtn.TextColor3 = Colors.TextSubtle
    cancelBtn.TextSize = 12
    cancelBtn.BorderSizePixel = 0
    cancelBtn.AutoButtonColor = false
    cancelBtn.ZIndex = 4002
    cancelBtn.Parent = card
    Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0, 8)
    local okBtn = Instance.new("TextButton")
    okBtn.Size = UDim2.new(0, 128, 0, 34)
    okBtn.Position = UDim2.new(1, -144, 1, -50)
    okBtn.BackgroundColor3 = Color3.fromRGB(74, 42, 44)
    okBtn.Font = Enum.Font.GothamBold
    okBtn.Text = "确认退出"
    okBtn.TextColor3 = Colors.AccentRed
    okBtn.TextSize = 12
    okBtn.BorderSizePixel = 0
    okBtn.AutoButtonColor = false
    okBtn.ZIndex = 4002
    okBtn.Parent = card
    Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 8)
    local function CloseUnloadConfirm()
        if confirmOverlay.Visible then confirmOverlay.Visible = false end
        confirmOverlay.Active = false
    end
    DashUI._closeUnloadConfirm = CloseUnloadConfirm
    local function ShowUnloadConfirm()
        if confirmOverlay.Visible then return end
        if not screenGui or not screenGui.Parent then return end
        confirmOverlay.Visible = true
        confirmOverlay.Active = true
    end
    BindClick(cancelBtn, CloseUnloadConfirm)
    BindClick(okBtn, function()
        CloseUnloadConfirm()
        UnloadScript()
    end)
    confirmOverlay.InputBegan:Connect(function(input)
        if not ModeCtl.Accepts(input.UserInputType) then return end
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
    BindClick(closeBtn, ShowUnloadConfirm)
    RegisterThemeUpdater(function()
        card.BackgroundColor3 = Colors.Card
        stroke.Color = Colors.BorderAccent
        title.TextColor3 = Colors.TextWhite
        desc.TextColor3 = Colors.TextMuted
        cancelBtn.BackgroundColor3 = Colors.ControlBg
        cancelBtn.TextColor3 = Colors.TextSubtle
        okBtn.TextColor3 = Colors.AccentRed
    end)
end
end)() end
local SafeTeleport, allRods, TryFavoriteProtectedFish, SafeSellAllFish, TriggerPrompt, EnsureFishingRodEquipped, TeleportToDragonSea
local RunTicketQuestAction, RunGiveFishToMonkeyBatch, GetNPCPosition, FireGuiButton
FSYC.FSYDialogueOpenedAt = 0
local GetNearestIslandInfo, ImportantDialogueNPCs, FourSacredBeastsSpecs, DoesInstanceMatchNPCSpec, TriggerNPCInstancePrompts, IsDialogueUIOpen
local TryStreamAroundPosition, IsMapOrIslandContainer, ResolvePromptEntity, GetInstanceSearchableSummary, GetCachedWorkspacePrompts
local cachedBossPrompts = {}
print("[FSY][BOOT] 3/5 UI 外壳创建完成，开始装配各页面")
do (function()
local UIM = DashUI.metrics
do
    if type(Config.UIGroupState) ~= "table" then
        Config.UIGroupState = {}
    else
        local count = 0
        local badKeys = nil
        for k, v in pairs(Config.UIGroupState) do
            count = count + 1
            if type(k) ~= "string" or type(v) ~= "boolean" then
                badKeys = badKeys or {}
                badKeys[#badKeys + 1] = k
            end
        end
        if badKeys then
            for i = 1, #badKeys do Config.UIGroupState[badKeys[i]] = nil end
        end
        if count > 240 then Config.UIGroupState = {} end
    end
end
local bodyGroup = setmetatable({}, { __mode = "k" })
local function resolveGroup(obj)
    local node, guard = obj, 0
    while node and guard < 6 do
        local grp = bodyGroup[node]
        if grp then return grp end
        node = node.Parent
        guard = guard + 1
    end
    return nil
end
local groupSaveQueued = false
local function queueSaveGroupState()
    if groupSaveQueued then return end
    groupSaveQueued = true
    task.delay(1.2, function()
        groupSaveQueued = false
        if not isRunning then return end
        if type(SaveProfile) == "function" then pcall(SaveProfile, Config.ActiveProfile) end
    end)
end
local function refreshCurrentCanvas()
    if not currentActiveTab or not tabCanvasRefreshers then return end
    local refresher = tabCanvasRefreshers[currentActiveTab]
    if not refresher then return end
    pcall(refresher)
    task.delay(0.18, function()
        if isRunning then pcall(refresher) end
    end)
end
DashUI.refreshCanvas = refreshCurrentCanvas
local function createCollapsibleGroup(parent, titleText, defaultExpanded)
    local grpTitle = tostring(titleText)
    local cat = DashUI.resolveCategory(parent)
    local key = tostring(cat) .. "|" .. grpTitle
    local savedState = Config.UIGroupState and Config.UIGroupState[key]
    local expanded = (type(savedState) == "boolean") and savedState or (defaultExpanded ~= false)
    local card = Instance.new("Frame")
    card.Name = "Group_" .. grpTitle
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = Colors.Card
    card.BorderSizePixel = 0
    card.ClipsDescendants = false
    card.Parent = parent
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
    local cardStroke = Instance.new("UIStroke", card)
    cardStroke.Color = Colors.BorderSubtle
    cardStroke.Thickness = 1
    cardStroke.Transparency = 0.25
    local cardLayout = Instance.new("UIListLayout")
    cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
    cardLayout.Padding = UDim.new(0, 0)
    cardLayout.Parent = card
    local header = Instance.new("TextButton")
    header.Name = "Header"
    header.LayoutOrder = 1
    header.Size = UDim2.new(1, 0, 0, UIM.groupH)
    header.BackgroundColor3 = Colors.RowHover
    header.BackgroundTransparency = 1
    header.BorderSizePixel = 0
    header.Text = ""
    header.AutoButtonColor = false
    header.Parent = card
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)
    local accentBar = Instance.new("Frame")
    accentBar.Name = "AccentBar"
    accentBar.Size = UDim2.new(0, 3, 0, 16)
    accentBar.Position = UDim2.new(0, 12, 0.5, -8)
    accentBar.BackgroundColor3 = Colors.Accent
    accentBar.BorderSizePixel = 0
    accentBar.Visible = expanded
    accentBar.Parent = header
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, -64, 1, 0)
    titleLabel.Position = UDim2.new(0, 24, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = grpTitle
    titleLabel.TextColor3 = Colors.TextWhite
    titleLabel.TextSize = UIM.groupTitle
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.Parent = header
    local arrow = Instance.new("TextLabel")
    arrow.Name = "Arrow"
    arrow.Size = UDim2.new(0, 18, 0, 18)
    arrow.Position = UDim2.new(1, -30, 0.5, -9)
    arrow.BackgroundTransparency = 1
    arrow.Font = Enum.Font.GothamBold
    arrow.Text = "▶"
    arrow.TextColor3 = Colors.TextMuted
    arrow.TextSize = 9
    arrow.Rotation = expanded and 90 or 0
    arrow.Parent = header
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.LayoutOrder = 2
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
    body.BackgroundTransparency = 1
    body.BorderSizePixel = 0
    body.ClipsDescendants = true
    body.Visible = expanded
    body.Parent = card
    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Padding = UDim.new(0, 0)
    bodyLayout.Parent = body
    local rec
    local function applyExpanded(want, persist, animate)
        expanded = (want ~= false)
        body.Visible = expanded
        body.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
        body.Size = UDim2.new(1, 0, 0, 0)
        arrow.Rotation = expanded and 90 or 0
        accentBar.Visible = expanded
        if persist then
            rec.initialExpanded = expanded
            if type(Config.UIGroupState) ~= "table" then Config.UIGroupState = {} end
            Config.UIGroupState[key] = expanded
            queueSaveGroupState()
        end
        if animate then refreshCurrentCanvas() end
    end
    rec = {
        section = card,
        header = header,
        body = body,
        title = grpTitle,
        key = key,
        cat = cat,
        initialExpanded = expanded,
        GetExpanded = function() return expanded end,
        SetExpanded = function(value, animate, skipPersist)
            applyExpanded(value, not skipPersist, animate == true)
        end,
        HasVisibleRow = function()
            for _, child in ipairs(body:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then return true end
            end
            return false
        end,
    }
    collapsibleSections[#collapsibleSections + 1] = rec
    bodyGroup[body] = rec
    BindClick(header, function()
        if currentlyOpenDropdown and currentlyOpenDropdown.Close then
            pcall(currentlyOpenDropdown.Close)
            currentlyOpenDropdown = nil
        end
        applyExpanded(not expanded, true, true)
    end)
    header.MouseEnter:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(header, { BackgroundColor3 = Colors.RowHover, BackgroundTransparency = 0.45 })
    end)
    header.MouseLeave:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(header, { BackgroundTransparency = 1 })
    end)
    RegisterThemeUpdater(function()
        card.BackgroundColor3 = Colors.Card
        cardStroke.Color = Colors.BorderSubtle
        accentBar.BackgroundColor3 = Colors.Accent
        titleLabel.TextColor3 = Colors.TextWhite
        arrow.TextColor3 = Colors.TextMuted
        header.BackgroundColor3 = Colors.RowHover
    end)
    return body
end
local function createDrawerCapsule(parent, labelText, descText, defaultExpanded)
    local grpTitle = tostring(labelText or "更多设置")
    local cat = DashUI.resolveCategory(parent)
    local key = tostring(cat) .. "|" .. grpTitle
    local savedState = Config.UIGroupState and Config.UIGroupState[key]
    local expanded = (type(savedState) == "boolean") and savedState or (defaultExpanded == true)
    local wrapper = Instance.new("Frame")
    wrapper.Name = "Capsule_" .. grpTitle
    wrapper.Size = UDim2.new(1, 0, 0, 0)
    wrapper.AutomaticSize = Enum.AutomaticSize.Y
    wrapper.BackgroundTransparency = 1
    wrapper.BorderSizePixel = 0
    wrapper.Parent = parent
    local wrapLayout = Instance.new("UIListLayout")
    wrapLayout.SortOrder = Enum.SortOrder.LayoutOrder
    wrapLayout.Padding = UDim.new(0, 0)
    wrapLayout.Parent = wrapper
    local header = Instance.new("TextButton")
    header.Name = "CapsuleHead"
    header.LayoutOrder = 1
    header.Size = UDim2.new(1, 0, 0, UIM.touch and 56 or 44)
    header.BackgroundColor3 = Colors.RowNormal
    header.Text = ""
    header.AutoButtonColor = false
    header.BorderSizePixel = 0
    header.Parent = wrapper
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 9)
    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 0, 18)
    accentBar.Position = UDim2.new(0, 9, 0.5, -9)
    accentBar.BackgroundColor3 = Colors.AccentSoft
    accentBar.BorderSizePixel = 0
    accentBar.Parent = header
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, -96, 0, 18)
    titleLabel.Position = UDim2.new(0, 20, 0, UIM.touch and 9 or 5)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = grpTitle
    titleLabel.TextColor3 = Colors.TextWhite
    titleLabel.TextSize = UIM.titleSize
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.Parent = header
    local descLabel = Instance.new("TextLabel")
    descLabel.Name = "Desc"
    descLabel.Size = UDim2.new(1, -96, 0, 14)
    descLabel.Position = UDim2.new(0, 20, 0, UIM.touch and 30 or 24)
    descLabel.BackgroundTransparency = 1
    descLabel.Font = Enum.Font.Gotham
    descLabel.Text = tostring(descText or "")
    descLabel.TextColor3 = Colors.TextMuted
    descLabel.TextSize = UIM.descSize
    descLabel.TextXAlignment = Enum.TextXAlignment.Left
    descLabel.TextTruncate = Enum.TextTruncate.AtEnd
    descLabel.Parent = header
    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.Size = UDim2.new(0, 60, 0, 22)
    indicator.Position = UDim2.new(1, -70, 0.5, -11)
    indicator.BackgroundColor3 = Colors.ControlBg
    indicator.BorderSizePixel = 0
    indicator.Parent = header
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)
    local indStroke = Instance.new("UIStroke", indicator)
    indStroke.Color = Colors.BorderSubtle
    indStroke.Thickness = 1
    indStroke.Transparency = 0.35
    local stateLbl = Instance.new("TextLabel")
    stateLbl.Size = UDim2.new(0, 36, 1, 0)
    stateLbl.Position = UDim2.new(0, 8, 0, 0)
    stateLbl.BackgroundTransparency = 1
    stateLbl.Font = Enum.Font.GothamBold
    stateLbl.Text = "展开"
    stateLbl.TextColor3 = Colors.TextMuted
    stateLbl.TextSize = 10
    stateLbl.TextXAlignment = Enum.TextXAlignment.Left
    stateLbl.Parent = indicator
    local arrow = Instance.new("TextLabel")
    arrow.Name = "Arrow"
    arrow.Size = UDim2.new(0, 14, 0, 14)
    arrow.Position = UDim2.new(1, -18, 0.5, -7)
    arrow.BackgroundTransparency = 1
    arrow.Font = Enum.Font.GothamBold
    arrow.Text = "▶"
    arrow.TextColor3 = Colors.TextMuted
    arrow.TextSize = 9
    arrow.Parent = indicator
    local holder = Instance.new("Frame")
    holder.Name = "CapsuleHolder"
    holder.LayoutOrder = 2
    holder.Size = UDim2.new(1, 0, 0, 0)
    holder.AutomaticSize = Enum.AutomaticSize.Y
    holder.BackgroundTransparency = 1
    holder.BorderSizePixel = 0
    holder.Parent = wrapper
    local box = Instance.new("Frame")
    box.Name = "CapsuleBox"
    box.Size = UDim2.new(1, 0, 0, 0)
    box.AutomaticSize = Enum.AutomaticSize.Y
    box.BackgroundColor3 = Colors.InputBg
    box.BorderSizePixel = 0
    box.Parent = holder
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 10)
    local boxStroke = Instance.new("UIStroke", box)
    boxStroke.Color = Colors.BorderSubtle
    boxStroke.Thickness = 1
    boxStroke.Transparency = 0.35
    local boxPad = Instance.new("UIPadding")
    boxPad.PaddingLeft = UDim.new(0, 8)
    boxPad.PaddingRight = UDim.new(0, 4)
    boxPad.PaddingTop = UDim.new(0, 4)
    boxPad.PaddingBottom = UDim.new(0, 4)
    boxPad.Parent = box
    local guide = Instance.new("Frame")
    guide.Name = "Guide"
    guide.Size = UDim2.new(0, 2, 1, -10)
    guide.Position = UDim2.new(0, 0, 0, 5)
    guide.BackgroundColor3 = Colors.Accent
    guide.BackgroundTransparency = 0.45
    guide.BorderSizePixel = 0
    guide.Parent = box
    Instance.new("UICorner", guide).CornerRadius = UDim.new(1, 0)
    local content = Instance.new("Frame")
    content.Name = "CapsuleContent"
    content.Size = UDim2.new(1, 0, 0, 0)
    content.AutomaticSize = Enum.AutomaticSize.Y
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.Parent = box
    local contentLayout = Instance.new("UIListLayout")
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, 2)
    contentLayout.Parent = content
    local rec
    local function applyExpanded(want, persist, animate)
        expanded = (want ~= false)
        holder.Visible = expanded
        holder.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
        holder.Size = UDim2.new(1, 0, 0, 0)
        arrow.Rotation = expanded and 90 or 0
        arrow.TextColor3 = expanded and Colors.AccentSoft or Colors.TextMuted
        stateLbl.Text = expanded and "收起" or "展开"
        stateLbl.TextColor3 = expanded and Colors.TextWhite or Colors.TextMuted
        indicator.BackgroundColor3 = expanded and Colors.AccentDeep or Colors.ControlBg
        indStroke.Color = expanded and Colors.BorderAccent or Colors.BorderSubtle
        accentBar.BackgroundColor3 = expanded and Colors.Accent or Colors.AccentSoft
        if persist then
            rec.initialExpanded = expanded
            if type(Config.UIGroupState) ~= "table" then Config.UIGroupState = {} end
            Config.UIGroupState[key] = expanded
            queueSaveGroupState()
        end
        if animate then refreshCurrentCanvas() end
    end
    rec = {
        section = wrapper,
        header = header,
        body = content,
        title = grpTitle,
        key = key,
        cat = cat,
        initialExpanded = expanded,
        GetExpanded = function() return expanded end,
        SetExpanded = function(value, animate, skipPersist)
            applyExpanded(value, not skipPersist, animate == true)
        end,
        HasVisibleRow = function()
            for _, child in ipairs(content:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then return true end
            end
            return false
        end,
    }
    collapsibleSections[#collapsibleSections + 1] = rec
    bodyGroup[content] = rec
    BindClick(header, function()
        if currentlyOpenDropdown and currentlyOpenDropdown.Close then
            pcall(currentlyOpenDropdown.Close)
            currentlyOpenDropdown = nil
        end
        applyExpanded(not expanded, true, true)
    end)
    header.MouseEnter:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(header, { BackgroundColor3 = Colors.RowHover })
    end)
    header.MouseLeave:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(header, { BackgroundColor3 = Colors.RowNormal })
    end)
    RegisterThemeUpdater(function()
        header.BackgroundColor3 = Colors.RowNormal
        titleLabel.TextColor3 = Colors.TextWhite
        descLabel.TextColor3 = Colors.TextMuted
        box.BackgroundColor3 = Colors.InputBg
        boxStroke.Color = Colors.BorderSubtle
        guide.BackgroundColor3 = Colors.Accent
        indicator.BackgroundColor3 = expanded and Colors.AccentDeep or Colors.ControlBg
        indStroke.Color = expanded and Colors.BorderAccent or Colors.BorderSubtle
        stateLbl.TextColor3 = expanded and Colors.TextWhite or Colors.TextMuted
        arrow.TextColor3 = expanded and Colors.AccentSoft or Colors.TextMuted
        accentBar.BackgroundColor3 = expanded and Colors.Accent or Colors.AccentSoft
    end)
    applyExpanded(expanded, false, false)
    return content
end
local function registerSearchRow(row, titleLabel, hlBar, labelText, descText, groupRec)
    local cat = DashUI.resolveCategory(row)
    local grp = groupRec or resolveGroup(row)
    local hay = tqLc(tostring(labelText or "") .. " " .. tostring(descText or "")
        .. " " .. tostring(cat or "") .. " " .. tostring(grp and grp.title or ""))
    local recRow = {
        frame = row,
        title = titleLabel,
        hl = hlBar,
        hay = hay,
        cat = cat,
        highlighted = false,
    }
    searchState.rows[#searchState.rows + 1] = recRow
    return recRow
end
local function createBaseRow(parent, labelText, descText, reserveWidth)
    local hasDesc = (descText ~= nil and descText ~= "")
    local rowH = UIM.rowH
    local reserve = tonumber(reserveWidth) or (UIM.btnW + 16)
    local row = Instance.new("Frame")
    row.Name = "Row"
    row.Size = UDim2.new(1, 0, 0, rowH)
    row.BackgroundColor3 = Colors.RowNormal
    row.BackgroundTransparency = 0
    row.BorderSizePixel = 0
    row.ClipsDescendants = true
    row.Parent = parent
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 13)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = row
    local textFrame = Instance.new("Frame")
    textFrame.Size = UDim2.new(1, -reserve, 1, 0)
    textFrame.BackgroundTransparency = 1
    textFrame.ClipsDescendants = true
    textFrame.Parent = row
    local titleTop = hasDesc and math.floor(rowH * 0.15) or math.floor((rowH - 18) / 2)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, 0, 0, 18)
    titleLabel.Position = UDim2.new(0, 0, 0, titleTop)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = tostring(labelText or "")
    titleLabel.TextColor3 = Colors.TextWhite
    titleLabel.TextSize = UIM.titleSize
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.Parent = textFrame
    local descLabel
    if hasDesc then
        descLabel = Instance.new("TextLabel")
        descLabel.Name = "Desc"
        descLabel.Size = UDim2.new(1, 0, 0, 14)
        descLabel.Position = UDim2.new(0, 0, 0, rowH - 20)
        descLabel.BackgroundTransparency = 1
        descLabel.Font = Enum.Font.Gotham
        descLabel.Text = tostring(descText)
        descLabel.TextColor3 = Colors.TextMuted
        descLabel.TextSize = UIM.descSize
        descLabel.TextXAlignment = Enum.TextXAlignment.Left
        descLabel.TextTruncate = Enum.TextTruncate.AtEnd
        descLabel.Parent = textFrame
    end
    local divider = Instance.new("Frame")
    divider.Name = "Divider"
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.Position = UDim2.new(0, 12, 1, -1)
    divider.BackgroundColor3 = Colors.Divider
    divider.BackgroundTransparency = 0.45
    divider.BorderSizePixel = 0
    divider.Parent = row
    local recRow = registerSearchRow(row, titleLabel, nil, labelText, descText)
    row.MouseEnter:Connect(function()
        if UIM.touch then return end
        if not recRow.highlighted then
            PlayQuickTween(row, { BackgroundColor3 = Colors.RowHover })
        end
    end)
    row.MouseLeave:Connect(function()
        if UIM.touch then return end
        if not recRow.highlighted then
            PlayQuickTween(row, { BackgroundColor3 = Colors.RowNormal })
        end
    end)
    row.InputBegan:Connect(function(input)
        if ModeCtl.IsMobile() and input.UserInputType == Enum.UserInputType.Touch and not recRow.highlighted then
            row.BackgroundColor3 = Colors.RowHover
        end
    end)
    row.InputEnded:Connect(function(input)
        if ModeCtl.IsMobile() and input.UserInputType == Enum.UserInputType.Touch and not recRow.highlighted then
            row.BackgroundColor3 = Colors.RowNormal
        end
    end)
    DashUI.attachTip(row, descText)
    return row, titleLabel
end
local function createToggleRow(parent, labelText, descText, initialVal, callback, configKey)
    if type(initialVal) == "function" then callback = initialVal; initialVal = false end
    local row = createBaseRow(parent, labelText, descText, UIM.hitW + 10)
    local state = initialVal or false
    local trackW, trackH, knobSize = UIM.toggleW, UIM.toggleH, UIM.knobSize
    local knobOffX = 4
    local knobOnX = trackW - knobSize - 4
    local hit = Instance.new("TextButton")
    hit.Name = "ToggleHit"
    hit.Size = UDim2.new(0, UIM.hitW, 1, 0)
    hit.Position = UDim2.new(1, -UIM.hitW - 4, 0, 0)
    hit.BackgroundColor3 = Colors.RowHover
    hit.BackgroundTransparency = 1
    hit.Text = ""
    hit.AutoButtonColor = false
    hit.BorderSizePixel = 0
    hit.Parent = row
    local track = Instance.new("Frame")
    track.Name = "Track"
    track.Size = UDim2.new(0, trackW, 0, trackH)
    track.Position = UDim2.new(1, -trackW - 6, 0.5, -trackH / 2)
    track.BackgroundColor3 = state and Colors.Accent or Colors.ControlBg
    track.BorderSizePixel = 0
    track.Parent = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local trackStroke = Instance.new("UIStroke", track)
    trackStroke.Color = state and Colors.AccentSoft or Colors.BorderSubtle
    trackStroke.Thickness = 1
    trackStroke.Transparency = state and 0.45 or 0.5
    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.new(0, knobSize, 0, knobSize)
    knob.Position = UDim2.new(0, state and knobOnX or knobOffX, 0.5, -knobSize / 2)
    knob.BackgroundColor3 = state and Colors.TextWhite or Colors.TextSubtle
    knob.BorderSizePixel = 0
    knob.Parent = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local function updateVisuals(instant)
        local bg = state and Colors.Accent or Colors.ControlBg
        local knobColor = state and Colors.TextWhite or Colors.TextSubtle
        local knobPos = UDim2.new(0, state and knobOnX or knobOffX, 0.5, -knobSize / 2)
        local strokeColor = state and Colors.AccentSoft or Colors.BorderSubtle
        if instant then
            track.BackgroundColor3 = bg
            knob.BackgroundColor3 = knobColor
            knob.Position = knobPos
            trackStroke.Color = strokeColor
        else
            PlayQuickTween(track, { BackgroundColor3 = bg })
            PlayQuickTween(knob, { BackgroundColor3 = knobColor, Position = knobPos })
            PlayQuickTween(trackStroke, { Color = strokeColor })
        end
    end
    RegisterThemeUpdater(function()
        if state then
            track.BackgroundColor3 = Colors.Accent
            trackStroke.Color = Colors.AccentSoft
            knob.BackgroundColor3 = Colors.TextWhite
        else
            track.BackgroundColor3 = Colors.ControlBg
            trackStroke.Color = Colors.BorderSubtle
        end
    end)
    BindClick(hit, function()
        state = not state
        updateVisuals(false)
        if type(callback) == "function" then callback(state) end
    end)
    hit.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1)
            and ModeCtl.Accepts(input.UserInputType) then
            hit.BackgroundTransparency = 0.86
        end
    end)
    hit.InputEnded:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1)
            and ModeCtl.Accepts(input.UserInputType) then
            hit.BackgroundTransparency = 1
        end
    end)
    local ctrl = {
        frame = row,
        Set = function(val, silent)
            state = not not val
            updateVisuals(silent == true)
            if not silent and type(callback) == "function" then callback(state) end
        end,
        Get = function() return state end,
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end
local function createSliderRow(parent, labelText, descText, minVal, maxVal, initialVal, isFloat, suffix, callback, configKey)
    local row = createBaseRow(parent, labelText, descText, UIM.sliderW + 8)
    local currentVal = initialVal or minVal
    suffix = suffix or ""
    local container = Instance.new("Frame")
    container.Size = UDim2.new(0, UIM.sliderW, 1, 0)
    container.Position = UDim2.new(1, -UIM.sliderW, 0, 0)
    container.BackgroundTransparency = 1
    container.Parent = row
    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(0, 58, 1, 0)
    valLabel.Position = UDim2.new(1, -58, 0, 0)
    valLabel.BackgroundTransparency = 1
    valLabel.Font = Enum.Font.GothamBold
    valLabel.TextColor3 = Colors.AccentSoft
    valLabel.TextSize = 11
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.Parent = container
    local touchArea = Instance.new("Frame")
    touchArea.Size = UDim2.new(1, -64, 1, 0)
    touchArea.BackgroundTransparency = 1
    touchArea.ClipsDescendants = false
    touchArea.Parent = container
    local trackH = UIM.touch and 8 or 6
    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, 0, 0, trackH)
    track.Position = UDim2.new(0, 0, 0.5, -trackH / 2)
    track.BackgroundColor3 = Colors.ControlBg
    track.BorderSizePixel = 0
    track.Parent = touchArea
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = Colors.Accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
    local knobSize = UIM.touch and 18 or 15
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, knobSize, 0, knobSize)
    knob.BackgroundColor3 = Colors.TextWhite
    knob.BorderSizePixel = 0
    knob.Parent = touchArea
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local knobStroke = Instance.new("UIStroke", knob)
    knobStroke.Color = Colors.Accent
    knobStroke.Thickness = 2
    RegisterThemeUpdater(function()
        fill.BackgroundColor3 = Colors.Accent
        knobStroke.Color = Colors.Accent
        valLabel.TextColor3 = Colors.AccentSoft
    end)
    local function updateVisual(val)
        local pct = math.clamp((val - minVal) / (maxVal - minVal), 0, 1)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, -knobSize / 2, 0.5, -knobSize / 2)
        valLabel.Text = isFloat and string.format("%.2f", val) .. suffix or tostring(math.floor(val)) .. suffix
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
        local p, guard = row, 0
        while p and not p:IsA("ScrollingFrame") and guard < 16 do
            p = p.Parent
            guard = guard + 1
        end
        return (p and p:IsA("ScrollingFrame")) and p or nil
    end
    local function finishSliding()
        sliding = false
        activeTouch = nil
        activeSliderCleanupFns[finishSliding] = nil
        sliderInputSelfConn = DisconnectTempDragConn(sliderInputSelfConn)
        sliderChangedConn = DisconnectTempDragConn(sliderChangedConn)
        sliderEndedConn = DisconnectTempDragConn(sliderEndedConn)
        if activeScrollFrame and activeScrollFrame.Parent then
            activeScrollFrame.ScrollingEnabled = (previousScrollingEnabled ~= false)
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
            if not ok then FLogWarn("滑块", "滑块回调失败: " .. tostring(err)) end
        end
    end
    touchArea.InputBegan:Connect(function(input)
        if sliding then return end
        if not ModeCtl.Accepts(input.UserInputType) then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            activeSliderCleanupFns[finishSliding] = true
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
    local ctrl = {
        frame = row,
        Set = function(val, silent)
            local num = tonumber(val)
            if not num or num ~= num or num == math.huge or num == -math.huge then num = minVal end
            currentVal = math.clamp(num, minVal, maxVal)
            updateVisual(currentVal)
            if not silent and type(callback) == "function" then callback(currentVal) end
        end,
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end
local function createDropdownRow(parent, labelText, descText, options, initialVal, callback, configKey, optPoolSize)
    if type(options) == "table" and type(initialVal) == "function" then callback = initialVal; initialVal = options[1] end
    local selected = initialVal or options[1]
    local row = Instance.new("Frame")
    row.Name = "DropdownRow"
    row.Size = UDim2.new(1, 0, 0, UIM.rowH)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.BackgroundColor3 = Colors.RowNormal
    row.BorderSizePixel = 0
    row.ClipsDescendants = false
    row.Parent = parent
    local rl = Instance.new("UIListLayout")
    rl.SortOrder = Enum.SortOrder.LayoutOrder
    rl.Padding = UDim.new(0, 0)
    rl.Parent = row
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.LayoutOrder = 1
    header.Size = UDim2.new(1, 0, 0, UIM.rowH)
    header.BackgroundTransparency = 1
    header.Parent = row
    local hlBar = Instance.new("Frame")
    hlBar.Size = UDim2.new(0, 3, 1, -14)
    hlBar.Position = UDim2.new(0, 0, 0, 7)
    hlBar.BackgroundColor3 = Colors.Accent
    hlBar.BorderSizePixel = 0
    hlBar.Visible = false
    hlBar.Parent = header
    Instance.new("UICorner", hlBar).CornerRadius = UDim.new(1, 0)
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 13)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = header
    local textFrame = Instance.new("Frame")
    textFrame.Size = UDim2.new(1, -(UIM.ddW + 18), 1, 0)
    textFrame.BackgroundTransparency = 1
    textFrame.ClipsDescendants = true
    textFrame.Parent = header
    local titleTop = math.floor(UIM.rowH * 0.15)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, 0, 0, 18)
    titleLabel.Position = UDim2.new(0, 0, 0, titleTop)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = tostring(labelText or "")
    titleLabel.TextColor3 = Colors.TextWhite
    titleLabel.TextSize = UIM.titleSize
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.Parent = textFrame
    local descLabel = Instance.new("TextLabel")
    descLabel.Size = UDim2.new(1, 0, 0, 14)
    descLabel.Position = UDim2.new(0, 0, 0, UIM.rowH - 20)
    descLabel.BackgroundTransparency = 1
    descLabel.Font = Enum.Font.Gotham
    descLabel.Text = tostring(descText or "")
    descLabel.TextColor3 = Colors.TextMuted
    descLabel.TextSize = UIM.descSize
    descLabel.TextXAlignment = Enum.TextXAlignment.Left
    descLabel.TextTruncate = Enum.TextTruncate.AtEnd
    descLabel.Parent = textFrame
    local ddBtn = Instance.new("TextButton")
    ddBtn.Size = UDim2.new(0, UIM.ddW, 0, UIM.ddH)
    ddBtn.Position = UDim2.new(1, -UIM.ddW - 6, 0.5, -UIM.ddH / 2)
    ddBtn.BackgroundColor3 = Colors.ControlBg
    ddBtn.Font = Enum.Font.GothamBold
    ddBtn.Text = tostring(selected)
    ddBtn.TextColor3 = Colors.TextSubtle
    ddBtn.TextSize = 11
    ddBtn.TextTruncate = Enum.TextTruncate.AtEnd
    ddBtn.BorderSizePixel = 0
    ddBtn.AutoButtonColor = false
    ddBtn.Parent = header
    Instance.new("UICorner", ddBtn).CornerRadius = UDim.new(0, 8)
    local ddStroke = Instance.new("UIStroke", ddBtn)
    ddStroke.Color = Colors.BorderSubtle
    ddStroke.Thickness = 1
    ddStroke.Transparency = 0.35
    local caret = Instance.new("TextLabel")
    caret.Size = UDim2.new(0, 16, 1, 0)
    caret.Position = UDim2.new(1, -18, 0, 0)
    caret.BackgroundTransparency = 1
    caret.Font = Enum.Font.GothamBold
    caret.Text = "▾"
    caret.TextColor3 = Colors.TextMuted
    caret.TextSize = 10
    caret.Parent = ddBtn
    local ddTextPad = Instance.new("UIPadding")
    ddTextPad.PaddingLeft = UDim.new(0, 10)
    ddTextPad.PaddingRight = UDim.new(0, 20)
    ddTextPad.Parent = ddBtn
    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.Position = UDim2.new(0, 12, 1, -1)
    divider.BackgroundColor3 = Colors.Divider
    divider.BackgroundTransparency = 0.45
    divider.BorderSizePixel = 0
    divider.Parent = header
    local optWrap = Instance.new("Frame")
    optWrap.Name = "Options"
    optWrap.LayoutOrder = 2
    optWrap.Size = UDim2.new(1, 0, 0, 0)
    optWrap.AutomaticSize = Enum.AutomaticSize.Y
    optWrap.BackgroundTransparency = 1
    optWrap.Visible = false
    optWrap.Parent = row
    do
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, 12)
        p.PaddingRight = UDim.new(0, 12)
        p.PaddingBottom = UDim.new(0, 6)
        p.Parent = optWrap
        local ol = Instance.new("UIListLayout")
        ol.SortOrder = Enum.SortOrder.LayoutOrder
        ol.Padding = UDim.new(0, 3)
        ol.Parent = optWrap
    end
    local optButtons = {}
    local btnOptName = setmetatable({}, { __mode = "k" })
    local optSnapshot = {}
    local poolCount = math.max(tonumber(optPoolSize) or 0, #options, 8)
    local function styleOption(ob, opt, isSelected)
        ob.BackgroundColor3 = isSelected and Colors.DropdownSelected or Colors.InputBg
        ob.TextColor3 = isSelected and Colors.AccentSoft or Colors.TextSubtle
        ob.Text = (isSelected and "• " or "   ") .. tostring(opt)
    end
    local function renderAllOptions()
        for i = 1, poolCount do
            local ob = optButtons[i]
            local opt = optSnapshot[i]
            if opt == nil then
                btnOptName[ob] = nil
                if ob.Visible then ob.Visible = false end
            else
                btnOptName[ob] = opt
                if not ob.Visible then ob.Visible = true end
                styleOption(ob, opt, opt == selected)
            end
        end
    end
    for i = 1, poolCount do
        local ob = Instance.new("TextButton")
        ob.Name = "Option" .. i
        ob.LayoutOrder = i
        ob.Size = UDim2.new(1, 0, 0, UIM.optH)
        ob.BackgroundColor3 = Colors.InputBg
        ob.Font = Enum.Font.Gotham
        ob.Text = ""
        ob.TextColor3 = Colors.TextSubtle
        ob.TextSize = 11
        ob.TextXAlignment = Enum.TextXAlignment.Left
        ob.BorderSizePixel = 0
        ob.AutoButtonColor = false
        ob.Visible = false
        ob.Parent = optWrap
        Instance.new("UICorner", ob).CornerRadius = UDim.new(0, 7)
        do
            local p = Instance.new("UIPadding")
            p.PaddingLeft = UDim.new(0, 12)
            p.Parent = ob
        end
        optButtons[i] = ob
        ob.MouseEnter:Connect(function()
            if UIM.touch then return end
            local hoverOpt = btnOptName[ob]
            if hoverOpt ~= nil and hoverOpt ~= selected then
                PlayQuickTween(ob, { BackgroundColor3 = Colors.RowHover })
            end
        end)
        ob.MouseLeave:Connect(function()
            if UIM.touch then return end
            local hoverOpt = btnOptName[ob]
            if hoverOpt ~= nil and hoverOpt ~= selected then
                PlayQuickTween(ob, { BackgroundColor3 = Colors.InputBg })
            end
        end)
        BindClick(ob, function()
            local opt = btnOptName[ob]
            if opt == nil then return end
            selected = opt
            ddBtn.Text = tostring(opt)
            optWrap.Visible = false
            caret.Text = "▾"
            if currentlyOpenDropdown and currentlyOpenDropdown.optC == optWrap then currentlyOpenDropdown = nil end
            renderAllOptions()
            refreshCurrentCanvas()
            if type(callback) == "function" then callback(opt) end
        end)
    end
    local function populate(opts)
        local snap = {}
        local n = #opts
        if n > poolCount then
            FLogWarn("Dropdown", string.format("选项 %d 项超出静态池 %d，仅显示前 %d 项（不影响配置读写）", n, poolCount, poolCount))
            n = poolCount
        end
        for i = 1, n do snap[i] = opts[i] end
        optSnapshot = snap
        renderAllOptions()
    end
    populate(options)
    RegisterThemeUpdater(renderAllOptions)
    local function closeThisDropdown()
        if optWrap and optWrap.Parent then
            optWrap.Visible = false
            caret.Text = "▾"
            ddBtn.Text = tostring(selected)
        end
    end
    BindClick(ddBtn, function()
        local willOpen = not optWrap.Visible
        if willOpen then
            if currentlyOpenDropdown and currentlyOpenDropdown.optC ~= optWrap and currentlyOpenDropdown.Close then
                pcall(currentlyOpenDropdown.Close)
            end
            currentlyOpenDropdown = { optC = optWrap, Close = closeThisDropdown }
        elseif currentlyOpenDropdown and currentlyOpenDropdown.optC == optWrap then
            currentlyOpenDropdown = nil
        end
        optWrap.Visible = willOpen
        caret.Text = willOpen and "▴" or "▾"
        refreshCurrentCanvas()
    end)
    local recRow = registerSearchRow(row, titleLabel, hlBar, labelText, descText)
    header.InputBegan:Connect(function(input)
        if ModeCtl.IsMobile() and input.UserInputType == Enum.UserInputType.Touch and not recRow.highlighted then
            row.BackgroundColor3 = Colors.RowHover
        end
    end)
    header.InputEnded:Connect(function(input)
        if ModeCtl.IsMobile() and input.UserInputType == Enum.UserInputType.Touch and not recRow.highlighted then
            row.BackgroundColor3 = Colors.RowNormal
        end
    end)
    DashUI.attachTip(header, descText)
    local ctrl = {
        frame = row,
        Set = function(opt, silent)
            if opt ~= nil and type(opt) ~= "string" then
                local strOpt = tostring(opt)
                for i = 1, #optSnapshot do
                    if optSnapshot[i] == strOpt then
                        opt = strOpt
                        break
                    end
                end
            end
            selected = opt
            ddBtn.Text = tostring(opt)
            renderAllOptions()
            if not silent and type(callback) == "function" then callback(opt) end
        end,
        Get = function() return selected end,
        Refresh = function(newOpts)
            if type(newOpts) == "table" and #newOpts > 0 then
                populate(newOpts)
                local stillPresent = false
                for i = 1, #optSnapshot do
                    if optSnapshot[i] == selected then stillPresent = true; break end
                end
                if not stillPresent then
                    selected = optSnapshot[1]
                    ddBtn.Text = tostring(selected)
                    renderAllOptions()
                    if type(callback) == "function" then callback(selected) end
                else
                    ddBtn.Text = tostring(selected)
                end
            end
        end,
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end
local function createButtonRow(parent, labelText, descText, btnText, callback)
    if type(descText) == "function" then
        callback = descText; btnText = "执行"; descText = ""
    elseif type(btnText) == "function" then
        callback = btnText; btnText = descText; descText = ""
    end
    local row = createBaseRow(parent, labelText, descText, UIM.btnW + 18)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, UIM.btnW, 0, UIM.btnH)
    btn.Position = UDim2.new(1, -UIM.btnW - 6, 0.5, -UIM.btnH / 2)
    btn.BackgroundColor3 = Colors.Accent
    btn.Font = Enum.Font.GothamBold
    btn.Text = btnText or "执行"
    btn.TextColor3 = Colors.AccentDeep
    btn.TextSize = 11
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local function restore()
        btn.BackgroundColor3 = Colors.Accent
        btn.TextColor3 = Colors.AccentDeep
    end
    RegisterThemeUpdater(restore)
    btn.MouseEnter:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = Colors.AccentSoft })
    end)
    btn.MouseLeave:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = Colors.Accent, TextColor3 = Colors.AccentDeep })
    end)
    btn.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
            and ModeCtl.Accepts(input.UserInputType) then
            btn.BackgroundColor3 = Colors.AccentDeep
            btn.TextColor3 = Colors.AccentSoft
        end
    end)
    btn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            restore()
        end
    end)
    BindClick(btn, function()
        if type(callback) == "function" then callback() end
    end)
    return btn
end
local function createInfoRow(parent, labelText, valueText)
    local row = createBaseRow(parent, labelText, "", 168)
    local valueLabel = Instance.new("TextLabel")
    valueLabel.Size = UDim2.new(0, 160, 1, 0)
    valueLabel.Position = UDim2.new(1, -160, 0, 0)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.Text = tostring(valueText or "")
    valueLabel.TextColor3 = Colors.TextSubtle
    valueLabel.TextSize = 11
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.TextTruncate = Enum.TextTruncate.AtEnd
    valueLabel.Parent = row
    return { frame = row, Set = function(nv) valueLabel.Text = tostring(nv) end }
end
local tabDashboard = CreateTab("仪表盘")
local tabFishing   = CreateTab("钓鱼")
local tabBoss      = CreateTab("Boss")
local tabQuests    = CreateTab("任务")
local tabGod       = CreateTab("神灵")
local tabTeleports = CreateTab("传送")
local tabVisuals   = CreateTab("视觉")
local tabPlayer    = CreateTab("移动")
local tabProfiles  = CreateTab("配置文件")
SwitchTab("仪表盘")
do
    local dashLayout = tabDashboard:FindFirstChildOfClass("UIListLayout")
    if dashLayout then
        dashLayout.Padding = UDim.new(0, 10)
        dashLayout.SortOrder = Enum.SortOrder.LayoutOrder
    end
    local function CreateDashRow()
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 74)
        row.BackgroundTransparency = 1
        row.Parent = tabDashboard
        local rl = Instance.new("UIListLayout")
        rl.FillDirection = Enum.FillDirection.Horizontal
        rl.HorizontalAlignment = Enum.HorizontalAlignment.Left
        rl.SortOrder = Enum.SortOrder.LayoutOrder
        rl.Padding = UDim.new(0, 10)
        rl.Parent = row
        return row
    end
    local function CreateDashCard(parent, title, icon, color)
        local card = Instance.new("Frame")
        card.Size = UDim2.new(0.333, -7, 1, 0)
        card.BackgroundColor3 = Colors.Card
        card.BorderSizePixel = 0
        card.Parent = parent
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
        local stroke = Instance.new("UIStroke", card)
        stroke.Color = Colors.BorderSubtle
        stroke.Thickness = 1
        stroke.Transparency = 0.3
        local chip = Instance.new("Frame")
        chip.Size = UDim2.new(0, 20, 0, 20)
        chip.Position = UDim2.new(0, 10, 0, 9)
        chip.BackgroundColor3 = Colors.AccentDeep
        chip.BorderSizePixel = 0
        chip.Parent = card
        Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 6)
        local iconLbl = Instance.new("TextLabel")
        iconLbl.Size = UDim2.new(1, 0, 1, 0)
        iconLbl.BackgroundTransparency = 1
        iconLbl.Font = Enum.Font.GothamBold
        iconLbl.Text = icon
        iconLbl.TextSize = 10
        iconLbl.Parent = chip
        local titleLbl = Instance.new("TextLabel")
        titleLbl.Size = UDim2.new(1, -40, 0, 16)
        titleLbl.Position = UDim2.new(0, 36, 0, 11)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Font = Enum.Font.Gotham
        titleLbl.Text = title
        titleLbl.TextColor3 = Colors.TextMuted
        titleLbl.TextSize = 9
        titleLbl.TextXAlignment = Enum.TextXAlignment.Left
        titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
        titleLbl.Parent = card
        local valLbl = Instance.new("TextLabel")
        valLbl.Size = UDim2.new(1, -20, 0, 24)
        valLbl.Position = UDim2.new(0, 12, 0, 32)
        valLbl.BackgroundTransparency = 1
        valLbl.Font = Enum.Font.GothamBold
        valLbl.Text = "..."
        valLbl.TextColor3 = color
        valLbl.TextSize = 14
        valLbl.TextXAlignment = Enum.TextXAlignment.Left
        valLbl.TextTruncate = Enum.TextTruncate.AtEnd
        valLbl.Parent = card
        local dash = Instance.new("Frame")
        dash.Size = UDim2.new(0, 16, 0, 3)
        dash.Position = UDim2.new(0, 12, 1, -11)
        dash.BackgroundColor3 = color
        dash.BackgroundTransparency = 0.45
        dash.BorderSizePixel = 0
        dash.Parent = card
        Instance.new("UICorner", dash).CornerRadius = UDim.new(1, 0)
        card.MouseEnter:Connect(function()
            if DashUI.metrics.touch then return end
            PlayQuickTween(card, { BackgroundColor3 = Colors.RowHover })
            PlayQuickTween(stroke, { Color = Colors.BorderAccent, Transparency = 0.15 })
        end)
        card.MouseLeave:Connect(function()
            if DashUI.metrics.touch then return end
            PlayQuickTween(card, { BackgroundColor3 = Colors.Card })
            PlayQuickTween(stroke, { Color = Colors.BorderSubtle, Transparency = 0.3 })
        end)
        RegisterThemeUpdater(function()
            card.BackgroundColor3 = Colors.Card
            stroke.Color = Colors.BorderSubtle
            chip.BackgroundColor3 = Colors.AccentDeep
            titleLbl.TextColor3 = Colors.TextMuted
        end)
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
    local verCard = CreateDashCard(row5, "版本", "✨", Colors.AccentSoft)
    verCard.Text = "FSY " .. FSY_VERSION
    local stateCard = CreateDashCard(row5, "状态", "🟢", Colors.AccentGreen)
    stateCard.Text = "极速挂机中"
    RegisterThemeUpdater(function()
        verCard.TextColor3 = Colors.AccentSoft
    end)
end
SafeTeleport = function(targetCF)
    if not targetCF then return false end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and (tonumber(hum.Health) or 100) <= 0 then return false end
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local uprightCF = DashUI._makeUprightCFrame(targetCF) or targetCF
        local currentPos = root.Position
        local targetPos = uprightCF.Position
        local isFarTeleport = (currentPos - targetPos).Magnitude > 150
        pcall(function()
            if type(LocalPlayer.RequestStreamAroundAsync) == "function" then
                task.spawn(function()
                    pcall(function() LocalPlayer:RequestStreamAroundAsync(targetPos, 2) end)
                end)
            end
        end)
        DashUI._ensureHumanoidUpright(hum)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.CFrame = uprightCF
        if Config.PositionLock then lockedCFrame = uprightCF end
        if isFarTeleport then
            pcall(function()
                root.Anchored = true
                task.delay(0.12, function()
                    if root and root.Parent then
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                        root.Anchored = false
                        if isRunning then
                            DashUI._ensureHumanoidUpright(hum)
                            if Config.PositionLock and not isMicroTeleportingNPC then
                                lockedCFrame = uprightCF
                            end
                        end
                    end
                end)
            end)
        else
            task.defer(function()
                if isRunning and hum and hum.Parent then
                    DashUI._ensureHumanoidUpright(hum)
                end
            end)
        end
        return true
    end
    return false
end
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
DashUI.infoFishLive = createInfoRow(statsCard, "本局鱼获(实时)", "—")
DashUI.infoSkillCD = createInfoRow(statsCard, "技能实测CD", "采集中…")
local fishCard = createCollapsibleGroup(tabFishing, "核心钓鱼自动化")
createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿（举起鱼或收起鱼竿时自动暂停，关闭时自动恢复钓鱼按键）", Config.AutoCast, function(v)
    Config.AutoCast = v
    if not v then
        if DashUI._onAutoCastDisabled then pcall(DashUI._onAutoCastDisabled) end
        pcall(RestoreNativeGameHud)
        if RestoreMobileFishingButtonUI then
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
createToggleRow(fishCard, "自动技能(爆发DPS)", "咬钩后按「起手等待 → 严格顺序 → 单技能冷却」释放技能（详细参数见下方技能分组）", Config.AutoSkills, function(v)
    Config.AutoSkills = v
    currentSkillIndex = 1
    if v then
        ShowNotification("自动技能", string.format("顺序 %s · 起手 %.1fs · 冷却 Z%.0f/X%.0f/C%.0f/V%.0f · 通道 %s",
            tostring(Config.SkillOrder or "Z,X,C,V"), tonumber(Config.SkillStartDelay) or 2.5,
            tonumber(Config.SkillCdZ) or 30, tonumber(Config.SkillCdX) or 30,
            tonumber(Config.SkillCdC) or 30, tonumber(Config.SkillCdV) or 30,
            tostring(Config.SkillChannel or "自动")), "SUCCESS", 4)
    end
end, "AutoSkills")
createToggleRow(fishCard, "仅在钓鱼时自动（防空转发包）", "开启：只有确认在钓鱼/搏斗中，才放技能、打猛击、蓄力、发进度包；站着不动时完全不发包。关闭：退回旧行为（可能出现空闲也持续发包）", Config.FishingGate, function(v)
    Config.FishingGate = v
    if DashUI and DashUI._resetFishTimers then pcall(DashUI._resetFishTimers) end
    if not v then
        ShowNotification("状态闸门", "已关闭：自动功能不再校验钓鱼状态（空闲时可能持续发包，仅建议调试时使用）", "WARN", 5)
    else
        ShowNotification("状态闸门", "已开启：仅在有效钓鱼/搏斗状态执行自动发包与自动技能", "SUCCESS", 4)
    end
end, "FishingGate")
local gateDrawer = createDrawerCapsule(fishCard, "闸门高级与诊断",
    "点击展开：闸门兼容模式（仅「明明在搏斗却不放技能」时才开）与当前闸门状态查看", false)
createToggleRow(gateDrawer, "闸门兼容模式（面板可见也算搏斗）", "默认关。只在你确认「明明在搏斗、技能却不放」时才打开：它会把「Fishing 面板可见 且（猛击钮可见 或 鱼线在水里）」也当成搏斗（旧判定里并没有这一条，属于额外放宽），代价是重新出现空转发包。注意：关掉「自动猛击」时这条主要靠「鱼线在水里」生效", Config.FishingGateLoose, function(v)
    Config.FishingGateLoose = v
    if DashUI and DashUI._resetFishTimers then pcall(DashUI._resetFishTimers) end
    if v then
        ShowNotification("闸门兼容模式", "已开启：Fishing 面板可见也会被当作搏斗。若不再需要请及时关闭，避免空转发包。", "WARN", 6)
    else
        ShowNotification("闸门兼容模式", "已关闭：回到严格判定（只认 Minigame 属性 / Boss 拔河条 / 自己的鱼）", "SUCCESS", 4)
    end
end, "FishingGateLoose")
createButtonRow(gateDrawer, "查看自动发包闸门状态", "显示当前状态（搏斗中/钓鱼中/空闲）、各原始信号与被拦下的发包次数，用于确认空闲时没有空转发包", "查看状态", function()
    local line = "闸门状态不可用"
    if DashUI._fishGateStatus then
        local ok, v = pcall(DashUI._fishGateStatus)
        if ok and type(v) == "string" and v ~= "" then line = v end
    end
    ShowNotification("自动发包闸门", line, "INFO", 10)
    if FLog then pcall(FLog, "状态闸门", line) end
end)
local skillDrawer = createDrawerCapsule(tabFishing, "技能轮换细项",
    "点击展开：勾选 Z/X/C/V 要放的技能，设置释放顺序、起手等待、单技能冷却与施法通道（平时不用动）", false)
createToggleRow(skillDrawer, "使用技能 Z", "勾选后才会释放 Z 技能", Config.SkillZ, function(v) Config.SkillZ = v; currentSkillIndex = 1 end, "SkillZ")
createToggleRow(skillDrawer, "使用技能 X", "勾选后才会释放 X 技能", Config.SkillX, function(v) Config.SkillX = v; currentSkillIndex = 1 end, "SkillX")
createToggleRow(skillDrawer, "使用技能 C", "勾选后才会释放 C 技能", Config.SkillC, function(v) Config.SkillC = v; currentSkillIndex = 1 end, "SkillC")
createToggleRow(skillDrawer, "使用技能 V", "勾选后才会释放 V 技能", Config.SkillV, function(v) Config.SkillV = v; currentSkillIndex = 1 end, "SkillV")
do
    local orderRow = createBaseRow(skillDrawer, "技能释放顺序", "标准顺序为 Z,X,C,V（每次进小游戏固定从第1个起手）", UIM.ddW + 24)
    local orderBox = Instance.new("TextBox")
    orderBox.Size = UDim2.new(0, UIM.ddW, 0, UIM.ddH)
    orderBox.Position = UDim2.new(1, -UIM.ddW - 6, 0.5, -UIM.ddH / 2)
    orderBox.BackgroundColor3 = Colors.InputBg
    orderBox.Font = Enum.Font.GothamBold
    orderBox.Text = Config.SkillOrder or "Z,X,C,V"
    orderBox.PlaceholderText = "Z,X,C,V"
    orderBox.TextColor3 = Colors.TextWhite
    orderBox.PlaceholderColor3 = Colors.TextMuted
    orderBox.TextSize = 12
    orderBox.BorderSizePixel = 0
    orderBox.ClearTextOnFocus = false
    orderBox.Parent = orderRow
    Instance.new("UICorner", orderBox).CornerRadius = UDim.new(0, 8)
    do
        local op = Instance.new("UIPadding"); op.PaddingLeft = UDim.new(0, 10); op.Parent = orderBox
        local os = Instance.new("UIStroke", orderBox); os.Color = Colors.BorderSubtle; os.Thickness = 1; os.Transparency = 0.3
    end
    orderBox.FocusLost:Connect(function()
        local text = orderBox.Text:gsub("[^ZzXxCcVv,%s;|/]", ""):gsub("%s+", ""):upper()
        if #text > 16 then text = text:sub(1, 16) end
        if text == "" or not text:find("[ZXCV]") then text = "Z,X,C,V" end
        Config.SkillOrder = text
        orderBox.Text = text
        currentSkillIndex = 1
        ShowNotification("技能顺序", "已更新为: " .. text .. " (已重置从第1个起手)", "SUCCESS")
    end)
    UIControls["SkillOrder"] = { Set = function(val) orderBox.Text = tostring(val) end }
end
createSliderRow(skillDrawer, "技能间隔", "任意两次技能之间的最小间隔（建议 1.2~1.5 秒；四个技能同时好了时，就按这个间隔一个个放）", 0.5, 5.0, Config.SkillInterval, true, "秒", function(v) Config.SkillInterval = v end, "SkillInterval")
createDropdownRow(skillDrawer, "技能释放顺序", "优先(Z→X→C→V)：每次都从顺序表头扫，Z 一好就放 Z（推荐）｜顺位优先：从上次的下一位开始，谁冷却好了放谁，最均衡｜盲轮转：每「技能间隔」秒按 Z→X→C→V 点一个，不看本地冷却、只有按钮显示倒计时才跳过这一拍（节奏稳、空放少）｜严格轮流：必须等当前位冷却完（最慢）", {"优先(Z→X→C→V)", "顺位优先(谁好放谁)", "盲轮转(按顺序点)", "严格轮流(等冷却)"}, Config.SkillOrderMode, function(v)
    Config.SkillOrderMode = v
    Config.SkillStrict = (v == "严格轮流(等冷却)")
end, "SkillOrderMode")
createSliderRow(skillDrawer, "起手等待", "咬钩进入小游戏后先等这么久再放第一个技能（仅对「第二个技能起」生效，首技默认立即放）", 0.5, 10.0, Config.SkillStartDelay, true, "秒", function(v) Config.SkillStartDelay = v end, "SkillStartDelay")
createToggleRow(skillDrawer, "首技立即释放", "开启（推荐）：本场第一个技能不吃「起手等待」、也不做施法前的界面冷却校验，直接放；放完立刻按按钮上的真实秒数记冷却，第二个技能起才等冷却。若发现首技经常被服务端拒绝，就关掉它", Config.SkillFirstInstant, function(v) Config.SkillFirstInstant = v end, "SkillFirstInstant")
createSliderRow(skillDrawer, "Z 技能冷却", "Z 技能点完之后要等多久才能再点（1~999 秒）。开启「自动读取冷却倒计时」后会按按钮上的真实秒数校正，这里只作读不到时的兜底", 1, 999, Config.SkillCdZ, true, "秒", function(v) Config.SkillCdZ = v; Config.SkillCooldown = v end, "SkillCdZ")
createSliderRow(skillDrawer, "X 技能冷却", "X 技能的真实冷却（1~999 秒）。同上，读到就按读数走；未解锁时请取消勾选", 1, 999, Config.SkillCdX, true, "秒", function(v) Config.SkillCdX = v end, "SkillCdX")
createSliderRow(skillDrawer, "C 技能冷却", "C 技能的真实冷却（1~999 秒）。同上，读到就按读数走", 1, 999, Config.SkillCdC, true, "秒", function(v) Config.SkillCdC = v end, "SkillCdC")
createSliderRow(skillDrawer, "V 技能冷却", "V 技能的真实冷却（1~999 秒）。同上，读到就按读数走；没解锁请取消勾选", 1, 999, Config.SkillCdV, true, "秒", function(v) Config.SkillCdV = v end, "SkillCdV")
createToggleRow(skillDrawer, "自动读取冷却倒计时", "从变灰的技能按钮上读剩余秒数来校正计时（推荐开启：读到了就完全按游戏真实冷却走）", Config.SkillCdProbe, function(v) Config.SkillCdProbe = v end, "SkillCdProbe")
createDropdownRow(skillDrawer, "施法通道", "一次技能只走一条通道，避免旧版三通道同开导致一次技能被重复释放、后续技能被跳过", {"自动", "屏幕按钮", "远程事件", "模拟按键", "兼容(三通道全开)"}, Config.SkillChannel, function(v) Config.SkillChannel = v end, "SkillChannel")
createDropdownRow(skillDrawer, "低血保命技能", "角色血量低于 35% 时每场战斗提前放一次这个技能（不影响技能顺序；会正常消耗该技能自身冷却）；不确定就保持关闭", {"关闭", "Z", "X", "C", "V"}, Config.SkillPanicKey, function(v) Config.SkillPanicKey = v end, "SkillPanicKey")
createButtonRow(skillDrawer, "自动技能引擎自检", "查看当前技能顺序、是否在战斗中、本场/累计释放次数、失败/跳过次数与最近一次判定原因", "自检", function()
    local order = tostring(Config.SkillOrder or "Z,X,C,V")
    local line = "引擎状态不可用"
    if DashUI and type(DashUI._autoSkillStatus) == "function" then
        local okStatus, txt = pcall(DashUI._autoSkillStatus)
        if okStatus and txt then line = tostring(txt) end
    end
    ShowNotification("自动技能自检", string.format("顺序 %s｜起手 %.1fs｜冷却 Z%.0f/X%.0f/C%.0f/V%.0f｜通道 %s｜%s",
        order, tonumber(Config.SkillStartDelay) or 2.5,
        tonumber(Config.SkillCdZ) or 30, tonumber(Config.SkillCdX) or 30,
        tonumber(Config.SkillCdC) or 30, tonumber(Config.SkillCdV) or 30,
        tostring(Config.SkillChannel or "自动"), line), "SUCCESS", 6)
end)
createToggleRow(fishCard, "自动猛击/暴击", "提示时自动点击猛击按钮造成巨大伤害", Config.AutoSlam, function(v) Config.AutoSlam = v end, "AutoSlam")
createToggleRow(fishCard, "自动充能耐久", "提示时自动充能鱼线耐久", Config.AutoCharge, function(v) Config.AutoCharge = v end, "AutoCharge")
end
do
local equipCard = createCollapsibleGroup(tabFishing, "智能自动装备引擎")
createToggleRow(equipCard, "自动装备最佳鱼饵", "装备背包中运气最高的鱼饵", Config.AutoEquipBestBait, function(v) Config.AutoEquipBestBait = v end, "AutoEquipBestBait")
createToggleRow(equipCard, "自动装备最佳鱼竿", "装备你拥有的最高威力鱼竿", Config.AutoEquipBestRod, function(v) Config.AutoEquipBestRod = v end, "AutoEquipBestRod")
createToggleRow(equipCard, "自动装备最佳宝珠", "装备最高等级精华宝珠", Config.AutoEquipBestOrb, function(v) Config.AutoEquipBestOrb = v end, "AutoEquipBestOrb")
local rodNameList = {}
for _, r in ipairs(allRods) do table.insert(rodNameList, r.name) end
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait", "Frost Bait", "Rainbow Bait", "Intuitive Bait", "Thunder Bait"}
local loadout1Drawer = createDrawerCapsule(equipCard, "预设配装方案 #1",
    "点击展开：选择方案1的鱼竿与鱼饵，一键换装", false)
createDropdownRow(loadout1Drawer, "方案1：鱼竿", "方案1的鱼竿", rodNameList, Config.Loadout1_Rod, function(v) Config.Loadout1_Rod = v end, "Loadout1_Rod")
createDropdownRow(loadout1Drawer, "方案1：鱼饵", "方案1的鱼饵", baitNameList, Config.Loadout1_Bait, function(v) Config.Loadout1_Bait = v end, "Loadout1_Bait")
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
            local rodNameReal = rodName
            if rFolder then
                rodNameReal = rFolder.Name
            elseif rodInv and type(rodName) == "string" then
                local wantLow = string.lower(rodName)
                for _, ch in ipairs(rodInv:GetChildren()) do
                    if string.lower(ch.Name) == wantLow then
                        rFolder = ch
                        rodNameReal = ch.Name
                        break
                    end
                end
            end
            local isOwned = DashUI._isRodOwned(rFolder)
            if isOwned then
                local equipRodRem = Events and Events:FindFirstChild("EquipFishingRod")
                if equipRodRem then
                    DashUI._safeInvokeAsync(equipRodRem, 4.0, rodNameReal)
                    ShowNotification(slotLabel, "已装备鱼竿: " .. tostring(rodNameReal), "SUCCESS")
                else
                    ShowNotification(slotLabel, "未找到装备鱼竿接口，已跳过鱼竿装备。", "WARN")
                end
            else
                ShowNotification(slotLabel, "你还没有拥有 " .. tostring(rodName) .. " ！", "WARN")
            end
            local bQty = DashUI._getBaitQty(pData, baitName)
            if bQty > 0 then
                local equipBaitRem = Events and Events:FindFirstChild("EquipBait")
                if equipBaitRem then
                    DashUI._safeInvokeAsync(equipBaitRem, 4.0, baitName)
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
local loadout2Drawer = createDrawerCapsule(equipCard, "预设配装方案 #2",
    "点击展开：选择方案2的鱼竿与鱼饵，一键换装", false)
createDropdownRow(loadout2Drawer, "方案2：鱼竿", "方案2的鱼竿", rodNameList, Config.Loadout2_Rod, function(v) Config.Loadout2_Rod = v end, "Loadout2_Rod")
createDropdownRow(loadout2Drawer, "方案2：鱼饵", "方案2的鱼饵", baitNameList, Config.Loadout2_Bait, function(v) Config.Loadout2_Bait = v end, "Loadout2_Bait")
createButtonRow(loadout2Drawer, "立即装备方案2", "装备方案2选择的鱼竿和鱼饵", "装备#2", function()
    EquipLoadoutAction("方案2", Config.Loadout2_Rod, Config.Loadout2_Bait)
end)
end
do
local FG = {
    craftMaterialFish = {
        ["Colossal Tigerfish"] = true, ["Heavenpiercer Turtle"] = true, ["Heaven Piercer Turtle"] = true,
        ["Golden Guardian Fish"] = true, ["Crimson Electric Eel"] = true,
        ["Rainbow Dragonfish"] = true, ["Rainbow Dragon Fish"] = true,
        ["Frost Kingfish"] = true, ["Frost King Fish"] = true, ["Ascended Perch"] = true,
        ["Primordial Kunfish Overlord"] = true, ["Warbringer Shark"] = true,
        ["Frost Queenfish"] = true, ["Frost Queen Fish"] = true,
        ["Mountain Fish"] = true, ["Tiger Mirefish"] = true,
        ["Mirage Lanternfish"] = true, ["Octoparasitic Fish"] = true,
        ["Nameless Octoparasite"] = true,
        ["Aquatic Fish"] = true, ["Flame Fish"] = true,
        ["Thunder Fish"] = true, ["Wind Fish"] = true,
        ["Intuitive Fish King"] = true,
        ["Apollo Swordfish"] = true, ["Killer Sawshark"] = true,
        ["Demon Bladefish"] = true, ["Colossal Bull Shark"] = true,
        ["Thunder Bull Shark"] = true,
        ["Catfish"] = true, ["Crimson Catfish"] = true,
        ["Scarlet Fish"] = true, ["Elder Scarlet Fish"] = true,
        ["Sanguine Fish"] = true
    },
    rodMaterialFish = {
        ["Flying Fish Emperor"] = true, ["Flying Fish Empress"] = true,
        ["Heavenpiercer Turtle"] = true, ["Heaven Piercer Turtle"] = true,
        ["Rainbow Dragonfish"] = true, ["Rainbow Dragon Fish"] = true,
        ["Frost Kingfish"] = true, ["Frost King Fish"] = true,
        ["Frost Queenfish"] = true, ["Frost Queen Fish"] = true,
        ["Sanguine Fish"] = true, ["Draconic Koi"] = true, ["Dragon Koi"] = true,
        ["Nameless Octoparasite"] = true, ["Octoparasitic Fish"] = true,
        ["Reborn Puffer Beast"] = true, ["Reborn Puffer"] = true,
        ["Ascended Perch"] = true, ["Mountain Fish"] = true,
        ["Trueform Jiaolongfish"] = true,
        ["Yinfish Sovereign"] = true, ["Yangfish Sovereign"] = true,
        ["Yangfish Empress"] = true, ["Intuitive Fish King"] = true,
        ["Demon Bladefish"] = true, ["Colossal Bull Shark"] = true,
        ["Thunder Bull Shark"] = true
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
        ["巨型老虎魚"] = "colossal tigerfish", ["巨型虎魚"] = "colossal tigerfish", ["老虎魚"] = "colossal tigerfish",
        ["鯤鵬君主"] = "primordial kunfish overlord", ["原始鯤魚霸主"] = "primordial kunfish overlord", ["太古鯤霸主"] = "primordial kunfish overlord",
        ["金色守護者魚"] = "golden guardian fish", ["金色守護者魚王"] = "golden guardian fish", ["黃金守護魚"] = "golden guardian fish",
        ["黃金龍魚"] = "golden dragon fish", ["金色龍魚"] = "golden dragon fish",
        ["暗黑魚王"] = "dark kingfish", ["黑暗魚王"] = "dark kingfish",
        ["山海龍鯨"] = "mountain dragon whale", ["龍鯨"] = "mountain dragon whale",
        ["猩紅鏟魚君主"] = "elder scarlet fish", ["遠古猩紅魚"] = "elder scarlet fish", ["老猩紅魚"] = "elder scarlet fish",
        ["猩紅電鰻"] = "crimson electric eel", ["猩紅電鰻魚王"] = "crimson electric eel", ["深紅電鰻"] = "crimson electric eel",
        ["穿天龜"] = "heavenpiercer turtle", ["破天玄龜"] = "heavenpiercer turtle", ["破天巨龜"] = "heavenpiercer turtle",
        ["章魚寄生魚"] = "octoparasitic fish",
        ["幽靈虎鯨"] = "wraith orca", ["怨靈虎鯨"] = "wraith orca",
        ["冰霜魚王"] = "frost kingfish", ["冰霜王魚"] = "frost kingfish",
        ["冰霜魚后"] = "frost queenfish",
        ["彩虹龍魚"] = "rainbow dragonfish",
        ["血腥魚"] = "sanguine fish",
        ["幻影燈籠魚"] = "mirage lanternfish", ["幻影燈魚"] = "mirage lanternfish",
        ["虎紋泥魚"] = "tiger mirefish", ["虎紋沼澤魚"] = "tiger mirefish",
        ["高山魚"] = "mountain fish", ["山魚"] = "mountain fish",
        ["飛升鱸魚"] = "ascended perch", ["飛昇鱸魚"] = "ascended perch", ["昇華鱸魚"] = "ascended perch", ["升華鱸魚"] = "ascended perch",
        ["戰神鯊"] = "warbringer shark", ["戰神鯊魚"] = "warbringer shark",
        ["猩紅鯰魚"] = "crimson catfish", ["猩紅鯰魚之王"] = "crimson catfish",
        ["猩紅魚"] = "scarlet fish",
        ["鯰魚"] = "catfish",
        ["飞鱼皇帝"] = "flying fish emperor", ["飞鱼皇"] = "flying fish emperor", ["飞鱼君主"] = "flying fish emperor",
        ["飛魚皇帝"] = "flying fish emperor", ["飛魚皇"] = "flying fish emperor", ["飛魚君主"] = "flying fish emperor",
        ["cá chuồn hoàng đế"] = "flying fish emperor", ["ca chuon hoang de"] = "flying fish emperor",
        ["飞鱼皇后"] = "flying fish empress", ["飞鱼后"] = "flying fish empress",
        ["飛魚皇后"] = "flying fish empress", ["飛魚后"] = "flying fish empress",
        ["cá chuồn hoàng hậu"] = "flying fish empress", ["ca chuon hoang hau"] = "flying fish empress",
        ["龙锦鲤"] = "draconic koi", ["龙形锦鲤"] = "draconic koi", ["龙纹锦鲤"] = "draconic koi", ["龙化锦鲤"] = "draconic koi",
        ["龍錦鯉"] = "draconic koi", ["龍形錦鯉"] = "draconic koi", ["龍紋錦鯉"] = "draconic koi",
        ["cá chép rồng"] = "draconic koi", ["ca chep rong"] = "draconic koi",
        ["重生河豚兽"] = "reborn puffer beast", ["重生河豚"] = "reborn puffer beast", ["转生河豚"] = "reborn puffer beast",
        ["重生河豚獸"] = "reborn puffer beast", ["轉生河豚"] = "reborn puffer beast",
        ["cá nóc tái sinh"] = "reborn puffer beast", ["ca noc tai sinh"] = "reborn puffer beast",
        ["阴鱼主"] = "yinfish sovereign", ["极阴鱼王"] = "yinfish sovereign", ["阴鱼之主"] = "yinfish sovereign", ["阴鱼王"] = "yinfish sovereign",
        ["陰魚主"] = "yinfish sovereign", ["極陰魚王"] = "yinfish sovereign", ["陰魚之主"] = "yinfish sovereign",
        ["âm ngư vương"] = "yinfish sovereign", ["am ngu vuong"] = "yinfish sovereign",
        ["阳鱼主"] = "yangfish sovereign", ["极阳鱼王"] = "yangfish sovereign", ["阳鱼之主"] = "yangfish sovereign", ["阳鱼王"] = "yangfish sovereign",
        ["陽魚主"] = "yangfish sovereign", ["極陽魚王"] = "yangfish sovereign", ["陽魚之主"] = "yangfish sovereign",
        ["dương ngư vương"] = "yangfish sovereign", ["duong ngu vuong"] = "yangfish sovereign",
        ["阳鱼皇后"] = "yangfish empress", ["阳鱼后"] = "yangfish empress",
        ["陽魚皇后"] = "yangfish empress", ["陽魚后"] = "yangfish empress",
        ["dương ngư hoàng hậu"] = "yangfish empress", ["duong ngu hoang hau"] = "yangfish empress",
        ["通灵鱼王"] = "intuitive fish king", ["顿悟鱼王"] = "intuitive fish king", ["直觉鱼王"] = "intuitive fish king",
        ["通靈魚王"] = "intuitive fish king", ["頓悟魚王"] = "intuitive fish king", ["直覺魚王"] = "intuitive fish king",
        ["trực giác ngư vương"] = "intuitive fish king", ["truc giac ngu vuong"] = "intuitive fish king",
        ["无名章鱼寄生体"] = "nameless octoparasite", ["无名章鱼"] = "nameless octoparasite",
        ["無名章魚寄生體"] = "nameless octoparasite", ["無名章魚"] = "nameless octoparasite",
        ["bạch tuộc ký sinh vô danh"] = "nameless octoparasite", ["bach tuoc ky sinh vo danh"] = "nameless octoparasite",
        ["水之鱼"] = "aquatic fish", ["水生鱼"] = "aquatic fish", ["水灵鱼"] = "aquatic fish",
        ["水之魚"] = "aquatic fish", ["水生魚"] = "aquatic fish", ["水靈魚"] = "aquatic fish",
        ["cá thủy"] = "aquatic fish", ["ca thuy"] = "aquatic fish", ["cá nước"] = "aquatic fish",
        ["火之鱼"] = "flame fish", ["烈焰鱼"] = "flame fish", ["火焰鱼"] = "flame fish",
        ["火之魚"] = "flame fish", ["烈焰魚"] = "flame fish", ["火焰魚"] = "flame fish",
        ["cá lửa"] = "flame fish", ["ca lua"] = "flame fish", ["cá hỏa"] = "flame fish",
        ["雷之鱼"] = "thunder fish", ["雷霆鱼"] = "thunder fish", ["闪电鱼"] = "thunder fish",
        ["雷之魚"] = "thunder fish", ["雷霆魚"] = "thunder fish", ["閃電魚"] = "thunder fish",
        ["cá sấm"] = "thunder fish", ["ca sam"] = "thunder fish", ["cá lôi"] = "thunder fish",
        ["风之鱼"] = "wind fish", ["疾风鱼"] = "wind fish", ["狂风鱼"] = "wind fish",
        ["風之魚"] = "wind fish", ["疾風魚"] = "wind fish", ["狂風魚"] = "wind fish",
        ["cá gió"] = "wind fish", ["ca gio"] = "wind fish", ["cá phong"] = "wind fish",
        ["阿波罗剑鱼"] = "apollo swordfish", ["太阳神剑鱼"] = "apollo swordfish",
        ["阿波羅劍魚"] = "apollo swordfish", ["太陽神劍魚"] = "apollo swordfish",
        ["cá kiếm apollo"] = "apollo swordfish", ["ca kiem apollo"] = "apollo swordfish",
        ["杀手锯鲨"] = "killer sawshark", ["夺命锯鲨"] = "killer sawshark",
        ["殺手鋸鯊"] = "killer sawshark", ["奪命鋸鯊"] = "killer sawshark",
        ["cá mập cưa sát thủ"] = "killer sawshark", ["ca map cua sat thu"] = "killer sawshark",
        ["恶魔刀鱼"] = "demon bladefish", ["魔刃鱼"] = "demon bladefish", ["恶魔刃鱼"] = "demon bladefish",
        ["惡魔刀魚"] = "demon bladefish", ["魔刃魚"] = "demon bladefish", ["惡魔刃魚"] = "demon bladefish",
        ["cá đao quỷ"] = "demon bladefish", ["ca dao quy"] = "demon bladefish",
        ["巨型公牛鲨"] = "colossal bull shark", ["巨型牛鲨"] = "colossal bull shark",
        ["巨型公牛鯊"] = "colossal bull shark", ["巨型牛鯊"] = "colossal bull shark",
        ["cá mập bò khổng lồ"] = "colossal bull shark", ["ca map bo khong lo"] = "colossal bull shark",
        ["雷霆公牛鲨"] = "thunder bull shark", ["雷霆牛鲨"] = "thunder bull shark",
        ["雷霆公牛鯊"] = "thunder bull shark", ["雷霆牛鯊"] = "thunder bull shark",
        ["cá mập bò sấm sét"] = "thunder bull shark", ["ca map bo sam set"] = "thunder bull shark",
        ["真形蛟龙鱼"] = "trueform jiaolongfish", ["真身蛟龙鱼"] = "trueform jiaolongfish",
        ["真形蛟龍魚"] = "trueform jiaolongfish", ["真身蛟龍魚"] = "trueform jiaolongfish",
        ["cá giao long chân hình"] = "trueform jiaolongfish", ["ca giao long chan hinh"] = "trueform jiaolongfish",
        ["cá hổ khổng lồ"] = "colossal tigerfish", ["ca ho khong lo"] = "colossal tigerfish",
        ["côn bằng bá chủ"] = "primordial kunfish overlord", ["con bang ba chu"] = "primordial kunfish overlord",
        ["cá hộ vệ hoàng kim"] = "golden guardian fish", ["ca ho ve hoang kim"] = "golden guardian fish",
        ["cá hộ vệ vàng"] = "golden guardian fish", ["ca ho ve vang"] = "golden guardian fish",
        ["cá rồng hoàng kim"] = "golden dragon fish", ["ca rong hoang kim"] = "golden dragon fish",
        ["cá rồng vàng"] = "golden dragon fish", ["ca rong vang"] = "golden dragon fish",
        ["cá vua bóng tối"] = "dark kingfish", ["ca vua bong toi"] = "dark kingfish", ["hắc ngư vương"] = "dark kingfish",
        ["cá voi rồng núi"] = "mountain dragon whale", ["ca voi rong nui"] = "mountain dragon whale",
        ["cá voi rồng"] = "mountain dragon whale", ["ca voi rong"] = "mountain dragon whale",
        ["lươn điện đỏ thẫm"] = "crimson electric eel", ["luon dien do tham"] = "crimson electric eel",
        ["lươn điện đỏ"] = "crimson electric eel", ["luon dien do"] = "crimson electric eel",
        ["rùa xuyên thiên"] = "heavenpiercer turtle", ["rua xuyen thien"] = "heavenpiercer turtle", ["rùa phá thiên"] = "heavenpiercer turtle",
        ["cá bạch tuộc ký sinh"] = "octoparasitic fish", ["ca bach tuoc ky sinh"] = "octoparasitic fish",
        ["cá voi sát thủ bóng ma"] = "wraith orca", ["ca voi sat thu bong ma"] = "wraith orca",
        ["cá voi sát thủ"] = "wraith orca", ["ca voi sat thu"] = "wraith orca",
        ["cá vua băng giá"] = "frost kingfish", ["ca vua bang gia"] = "frost kingfish",
        ["cá vua băng"] = "frost kingfish", ["ca vua bang"] = "frost kingfish",
        ["cá hoàng hậu băng giá"] = "frost queenfish", ["ca hoang hau bang gia"] = "frost queenfish",
        ["cá nữ hoàng băng"] = "frost queenfish", ["ca nu hoang bang"] = "frost queenfish",
        ["cá rồng cầu vồng"] = "rainbow dragonfish", ["ca rong cau vong"] = "rainbow dragonfish",
        ["cá huyết"] = "sanguine fish", ["ca huyet"] = "sanguine fish",
        ["cá máu"] = "sanguine fish", ["ca mau"] = "sanguine fish",
        ["cá đèn lồng ảo ảnh"] = "mirage lanternfish", ["ca den long ao anh"] = "mirage lanternfish",
        ["cá lồng đèn ảo ảnh"] = "mirage lanternfish", ["ca long den ao anh"] = "mirage lanternfish",
        ["cá bùn hổ"] = "tiger mirefish", ["ca bun ho"] = "tiger mirefish",
        ["cá núi"] = "mountain fish", ["ca nui"] = "mountain fish",
        ["cá rô thăng hoa"] = "ascended perch", ["ca ro thang hoa"] = "ascended perch",
        ["cá mập chiến thần"] = "warbringer shark", ["ca map chien than"] = "warbringer shark",
        ["cá trê đỏ thẫm"] = "crimson catfish", ["ca tre do tham"] = "crimson catfish",
        ["cá trê đỏ"] = "crimson catfish", ["ca tre do"] = "crimson catfish",
        ["cá đỏ cổ đại"] = "elder scarlet fish", ["ca do co dai"] = "elder scarlet fish",
        ["cá đỏ"] = "scarlet fish", ["ca do"] = "scarlet fish",
        ["cá trê"] = "catfish", ["ca tre"] = "catfish",
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
        "棱镜", "光明", "混沌", "太极", "觉醒", "仙品", "神品", "魔化", "血色", "狂暴",
        "lấp lánh ", "ánh kim ", "bạch tạng ", "nguyền rủa ", "ban phước ", "khổng lồ ", "đột biến ", "bóng tối ",
        "hắc ám ", "tha hóa ", "hư không ", "vực thẳm ", "thần thánh ", "thần thoại ", "cổ đại ",
        "ác quỷ ", "huyết ", "điện ", "sấm sét ", "hỏa ", "lửa ", "băng giá ", "đóng băng ", "độc ",
        "hạt nhân ", "phóng xạ ", "vũ trụ ", "ngân hà ", "bóng ma ", "hồn ma ", "linh hồn ",
        "ngọc bích ", "hồng ngọc ", "kim cương ", "pha lê ", "hắc diện thạch ", "hổ phách ",
        "bạch kim ", "cầu vồng ", "hỗn độn ", "thái cực ", "thức tỉnh ", "bất tử ", "vĩnh cửu ", "huyền thoại "
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
        "rod", "pole", "bait", "orb", "potion", "ticket", "scroll",
        "鱼竿", "钓竿", "鱼饵", "宝珠", "灵珠", "药水", "任务券", "卷轴",
        "cần câu", "can cau", "mồi câu", "moi cau", "ngọc", "thuốc", "cuộn"
    },
    nonFishExactOnlySet = {
        ["key"] = true, ["chest"] = true, ["box"] = true, ["book"] = true,
        ["stone"] = true, ["crystal"] = true, ["gem"] = true,
        ["钥匙"] = true, ["宝箱"] = true, ["技能书"] = true, ["水晶"] = true, ["宝石"] = true,
        ["chìa khóa"] = true, ["rương"] = true, ["sách"] = true, ["pha lê"] = true,
    },
    fishSpeciesGuardKeywords = {
        "fish", "shark", "whale", "eel", "crab", "ray", "squid", "octopus", "octoparasitic", "octoparasite",
        "turtle", "carp", "salmon", "trout", "tuna", "bass", "perch", "catfish", "orca", "koi", "puffer",
        "leviathan", "kraken", "dolphin", "marlin", "cod", "herring", "pike", "snapper", "grouper",
        "cá mập", "cá voi", "cá heo", "cá trê", "cá rô", "cá chép", "cá nóc", "cá chuồn", "cá kiếm", "bạch tuộc", "lươn", "rùa", "mực"
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
    batchLockStartedAt = 0,
    lockConfirmedOrSent = setmetatable({}, { __mode = "k" }),
    dupSameKeyUnlocked = setmetatable({}, { __mode = "k" }),
    lockRequeue = setmetatable({}, { __mode = "k" }),
    lastLockSentAt = setmetatable({}, { __mode = "k" }),
    lastAnyLockSentAt = 0,
    lockRetryAfter = setmetatable({}, { __mode = "k" }),
    lockFailCount = setmetatable({}, { __mode = "k" }),
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
function FG.GetItemWeightText(item)
    if not item or typeof(item) ~= "Instance" then return nil end
    local nameText = item.Name:match("|%s*([%d%.]+)%s*$") or item.Name:match("|%s*([%d%.]+)%s*|")
    if nameText then return nameText end
    local wKeys = FG.fishWeightChildKeys
    if wKeys then
        for i = 1, #wKeys do
            local k = wKeys[i]
            local ch = item:FindFirstChild(k)
            if ch and ch:IsA("StringValue") and type(ch.Value) == "string" then
                local t = ch.Value:match("([%d%.]+)")
                if t then return t end
            end
            local attr = item:GetAttribute(k)
            if type(attr) == "string" then
                local t = attr:match("([%d%.]+)")
                if t then return t end
            end
        end
    end
    local w = FG.ExtractItemWeightKg and FG.ExtractItemWeightKg(item) or nil
    if w and w > 0 then return string.format("%.2f", w) end
    return nil
end
function FG.GetItemBaseNameWithWeight(item)
    if not item then return "" end
    local raw = (typeof(item) == "Instance") and tostring(item.Name) or tostring(item)
    local stripped = raw:gsub("%s*|%s*[Ff][Aa][Vv][Oo][Uu]?[Rr][Ii][Tt][Ee][Dd]?%s*$", "")
                        :gsub("%s*|%s*[Ll][Oo][Cc][Kk][Ee]?[Dd]?%s*$", "")
    stripped = stripped:match("^%s*(.-)%s*$") or raw
    if typeof(item) == "Instance" and not stripped:find("|", 1, true) then
        local wtxt = FG.GetItemWeightText and FG.GetItemWeightText(item) or nil
        if wtxt and wtxt ~= "" then
            return stripped .. " | " .. wtxt
        end
    end
    return stripped
end
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
function FG.UnregisterLockedInstance(item)
    if not item then return end
    FG.lockConfirmedOrSent[item] = nil
    if FG.dupSameKeyUnlocked then FG.dupSameKeyUnlocked[item] = nil end
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
            entry.inst = item
            FG.lockConfirmedOrSent[item] = true
            FG.lastLockSentAt[item] = entry.sentAt
            return true
        end
    end
    if #list > 0 then
        local firstEntry = list[1]
        FG.lockConfirmedOrSent[item] = true
        FG.dupSameKeyUnlocked[item] = true
        if not FG.lastLockSentAt[item] and firstEntry then FG.lastLockSentAt[item] = firstEntry.sentAt end
        return true
    end
    return false
end
function FG.GetPureFishName(rawName)
    if not rawName then return "" end
    local s = (typeof(rawName) == "Instance") and rawName.Name or tostring(rawName)
    local cached = FG.pureNameCache[s]
    if cached then return cached end
    local beforePipe = s:match("^(.-)%s*|")
    local res = (beforePipe and #beforePipe > 0) and beforePipe or s
    res = res:gsub("%s*%([^%(%)]*[%d%.]+[^%(%)]*%)%s*$", "")
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
function FG.IsTruthyLockValue(v)
    if v == true or v == 1 then return true end
    if type(v) == "string" then
        local low = tqLc(v):match("^%s*(.-)%s*$")
        if low:find("unfav", 1, true) or low:find("unlock", 1, true) or low:find("mở khóa", 1, true) then return false end
        return low == "true" or low == "1" or low == "yes" or low == "locked"
            or low == "favorited" or low == "favourited" or low == "favorite" or low == "favourite"
            or low == "lock" or low == "fav"
            or low == "khóa" or low == "đã khóa" or low == "yêu thích" or low == "đã thích"
    end
    return false
end
function FG.IsFishLikeName(lowName)
    if type(lowName) ~= "string" or lowName == "" then return false end
    local keys = FG.fishSpeciesGuardKeywords
    for i = 1, #keys do
        local kw = keys[i]
        if #kw >= 4 then
            if string.find(lowName, kw, 1, true) then return true end
        else
            if string.find(lowName, "%f[%a]" .. kw .. "%f[%A]") then return true end
        end
    end
    return string.find(lowName, "cá", 1, true) ~= nil or string.find(lowName, "鱼", 1, true) ~= nil
end
DashUI._isFishLikeName = FG.IsFishLikeName
function FG.HasFavLockKeyword(str)
    if type(str) ~= "string" or str == "" then return false end
    local kLow = tqLc(str)
    return kLow:find("fav", 1, true) ~= nil or kLow:find("lock", 1, true) ~= nil
        or kLow:find("锁", 1, true) ~= nil or kLow:find("收藏", 1, true) ~= nil
        or kLow:find("khóa", 1, true) ~= nil or kLow:find("yêu thích", 1, true) ~= nil
end
function FG.NormalizeFishSpeciesLower(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return "" end
    local cached = FG.normSpeciesCache[rawStr]
    if cached then return cached end
    local pure = FG.GetPureFishName(rawStr)
    local pureLow = tqLc(pure)
    local rawLow = tqLc(rawStr)
    local strippedPure = FG.StripFishMutationPrefix and FG.StripFishMutationPrefix(pureLow) or pureLow
    local mapped = FG.cnFishAliasMap[pure] or FG.cnFishAliasMap[pureLow] or FG.cnFishAliasMap[strippedPure]
    if not mapped then
        for cnKey, enVal in pairs(FG.cnFishAliasMap) do
            if pureLow:find(cnKey, 1, true) or rawLow:find(cnKey, 1, true) then
                mapped = enVal
                break
            end
        end
    end
    local res = tqLc(mapped or strippedPure or pureLow):match("^%s*(.-)%s*$")
    if FG.normSpeciesCacheCount >= 512 then
        table.clear(FG.normSpeciesCache)
        FG.normSpeciesCacheCount = 0
    end
    FG.normSpeciesCache[rawStr] = res
    FG.normSpeciesCacheCount = FG.normSpeciesCacheCount + 1
    return res
end
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
    local unitProbe = weightPart:gsub("[Kk][Gg]", "")
    local mult, unit = 1, "kg"
    if unitProbe:find("[Bb]") or unitProbe:find("十亿", 1, true) then
        mult, unit = 1e9, "b"
    elseif unitProbe:find("[Mm]") or unitProbe:find("百万", 1, true) or unitProbe:find("兆", 1, true) then
        mult, unit = 1e6, "m"
    elseif unitProbe:find("[TtKk]") or unitProbe:find("吨", 1, true) or unitProbe:find("千", 1, true) then
        mult, unit = 1e3, "t"
    end
    local weightKg = num * mult
    local weightTag = string.format("%.2f", num):gsub("%.?0+$", "") .. unit
    return speciesLower, weightKg, weightTag
end
function FG.InspectCardPadlockState(card, descs)
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
    descs = descs or card:GetDescendants()
    for _, d in ipairs(descs) do
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
        return foundWhiteLocked, descs
    end
    return nil, descs
end
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
    local validGrids = FG.cachedInvGrids
    local gridKeep = 0
    for i = 1, #validGrids do
        local g = validGrids[i]
        if g and g.Parent then
            gridKeep = gridKeep + 1
            validGrids[gridKeep] = g
        end
    end
    for i = #validGrids, gridKeep + 1, -1 do validGrids[i] = nil end
    if #validGrids == 0 and (force or (now - FG.lastInvGridSearchAt) >= 3.0) then
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
                    local lockState, cardDescs = FG.InspectCardPadlockState(card)
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
                        for _, d in ipairs(cardDescs or card:GetDescendants()) do
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
function FG.GetGuiSlotLockState(item, strictMode)
    if not item or typeof(item) ~= "Instance" then return nil end
    FG.RefreshGuiLockCache(tick(), false)
    local byInst = FG.guiLockByInstance[item]
    if byInst ~= nil then return byInst end
    local baseWithW = FG.GetItemBaseNameWithWeight(item)
    for kIdx = 1, 3 do
        local keyCandidate
        if kIdx == 1 then keyCandidate = item.Name
        elseif kIdx == 2 then keyCandidate = baseWithW
        else keyCandidate = baseWithW .. " | Favorite" end
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
                or (entry.weightKg and math.abs(itemW - entry.weightKg) <= math.max(50, itemW * 0.005))
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
function FG.GetFishItemDataLockState(item)
    if not item or typeof(item) ~= "Instance" then return false, false end
    local chainMemo = FG.lockStateChainMemo
    local chainHit = chainMemo and chainMemo[item]
    if chainHit then return chainHit[1], chainHit[2] end
    local rawName = tostring(item.Name or "")
    local lastSeg = rawName:find("|", 1, true) and rawName:match("|%s*([^|]+)%s*$") or nil
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
    local vLow = (item:IsA("ValueBase") and type(item.Value) == "string") and tqLc(item.Value) or ""
    if item:IsA("StringValue") and vLow ~= "" and vLow ~= "1" then
        if FG.IsTruthyLockValue(item.Value) then
            return true, true
        elseif vLow == "false" or vLow:find("unfav", 1, true) or vLow:find("unlock", 1, true)
            or vLow:find("mở khóa", 1, true) or vLow:find("chưa khóa", 1, true) then
            hasExplicitField = true
        end
    elseif item:IsA("BoolValue") then
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
    if chainMemo then chainMemo[item] = { false, hasExplicitField } end
    return false, hasExplicitField
end
function FG.IsFishItemDataFavorited(item)
    local isLocked = FG.GetFishItemDataLockState(item)
    return isLocked
end
function FG.IsFishItemFavorited(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked, hasExplicitField = FG.GetFishItemDataLockState(item)
    if dataLocked then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or tick())
        return true
    end
    if hasExplicitField then
        local sentAt = FG.lastLockSentAt[item] or 0
        if sentAt > 0 and (tick() - sentAt) < 1.8 then
            return true
        end
        FG.UnregisterLockedInstance(item)
        return false
    end
    FG.ClaimDestroyedLockInheritance(item)
    if FG.lockConfirmedOrSent[item] then
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
function FG.IsFishItemSellSafe(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked, hasExplicit = FG.GetFishItemDataLockState(item)
    if dataLocked then return true end
    if hasExplicit then return false end
    FG.ClaimDestroyedLockInheritance(item)
    local now = tick()
    local sentAt = FG.lastLockSentAt[item] or 0
    if sentAt > 0 and (now - sentAt) < 2.0 then
        return false
    end
    if FG.IsInventoryGridVisibleOnScreen() then
        local uiStrict = FG.GetGuiSlotLockState(item, "strict")
        if uiStrict == false then return false end
        if uiStrict == true then return true end
    end
    if FG.dupSameKeyUnlocked[item] then
        local nowDup = tick()
        if (nowDup - (FG._dupSellWarnAt or 0)) > 60 then
            FG._dupSellWarnAt = nowDup
            task.defer(function()
                if isRunning and ShowNotification then
                    ShowNotification("🔒 保护鱼", "检测到同名同重量的重复鱼，无法单独上锁，已暂停全卖。请手动上锁其中一条，或把它移出保护名单。", "WARN", 5)
                end
            end)
        end
        return false
    end
    if FG.lockConfirmedOrSent[item] then
        return true
    end
    return false
end
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
                elseif (p == "spirit " or p == "幽灵") and (s:find("wraith orca", 1, true) or s:find("幽灵虎鲸", 1, true)) then
                elseif (p == "flame " or p == "烈焰" or p == "火焰") and (s:find("flame fish", 1, true) or s:find("火之鱼", 1, true) or s:find("烈焰鱼", 1, true) or s:find("火焰鱼", 1, true)) then
                elseif (p == "thunder " or p == "雷电" or p == "闪电") and (s:find("thunder fish", 1, true) or s:find("thunder bull shark", 1, true) or s:find("雷之鱼", 1, true) or s:find("雷霆", 1, true)) then
                elseif (p == "demon " or p == "demonic ") and (s:find("demon bladefish", 1, true) or s:find("恶魔刀鱼", 1, true)) then
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
function FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, targetLower)
    if not targetLower or targetLower == "" then return false end
    if pureLower == targetLower or (baseLower and baseLower == targetLower) or fullLower == targetLower then
        return true
    end
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
function FG.BuildFishMatcher(patternStr)
    if not patternStr then return nil end
    local raw = tostring(patternStr):match("^%s*(.-)%s*$")
    local pipePrefix = raw:match("^(.-)%s*|")
    if pipePrefix and #pipePrefix > 0 then
        raw = pipePrefix:match("^%s*(.-)%s*$")
    end
    if raw == "" then return nil end
    local rawFolded = tqLc(raw)
    local mappedEn = FG.cnFishAliasMap[raw] or FG.cnFishAliasMap[rawFolded]
    local lower = tqLc(mappedEn or rawFolded)
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
    local bodyClean = FG.StripFishMutationPrefix(tqLc(bodyMapped))
    local matcher
    if mode == "exact" then
        local exactBody = tqLc(bodyMapped)
        matcher = function(pureLower, fullLower, baseLower)
            return pureLower == body or pureLower == exactBody
                or (baseLower and (baseLower == body or baseLower == exactBody))
                or fullLower == body or fullLower == exactBody
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
            return FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, body)
                or (bodyClean ~= "" and bodyClean ~= body and FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, bodyClean))
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
    if src == FSYC.cachedRuleSource then return cachedRuleMatchers end
    table.clear(cachedRuleMatchers)
    for token in string.gmatch((src:gsub("，", ","):gsub("；", ";")), "([^,;\n\r]+)") do
        local m = FG.BuildFishMatcher(token)
        if m then table.insert(cachedRuleMatchers, m) end
    end
    FSYC.cachedRuleSource = src
    return cachedRuleMatchers
end
local blMemo, blMemoCount = {}, 0
local blMemoFlags, blMemoFav, blMemoCps = -1, nil, nil
local function IsFishNameBlacklistedCore(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return false end
    local pureName = FG.GetPureFishName(rawStr)
    local pureFolded = tqLc(pureName)
    local rawFolded = tqLc(rawStr)
    local mapped = FG.cnFishAliasMap[pureName] or FG.cnFishAliasMap[pureFolded]
    if not mapped then
        for cnKey, enVal in pairs(FG.cnFishAliasMap) do
            if pureName == cnKey or pureFolded == cnKey or rawStr == cnKey or rawFolded == cnKey then
                mapped = enVal
                break
            end
        end
        if not mapped then
            for cnKey, enVal in pairs(FG.cnFishAliasMap) do
                if pureFolded:find(cnKey, 1, true) or rawFolded:find(cnKey, 1, true) then
                    mapped = enVal
                    break
                end
            end
        end
    end
    mapped = mapped or pureName
    local pureLower = tqLc(mapped):match("^%s*(.-)%s*$")
    local baseLower = FG.StripFishMutationPrefix(pureLower)
    local mappedBase = FG.cnFishAliasMap[baseLower]
    if mappedBase then baseLower = tqLc(mappedBase) end
    local fullLower = tqLc(rawStr .. " " .. pureName .. " " .. mapped .. " " .. baseLower)
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
    if Config.RodMaterialFarming then
        if FG.rodMaterialFish[pureName] or FG.rodMaterialFish[mapped] then return true end
        for rodFish in pairs(FG.rodMaterialFish) do
            local rodFishLow = rodFish:lower()
            if FG.DoesSpeciesMatchTarget(pureLower, baseLower, fullLower, rodFishLow) then
                return true
            end
        end
    end
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
function FG.IsFishNameStringBlacklisted(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return false end
    local flags = (Config.MaterialFarming and 1 or 0) + (Config.RodMaterialFarming and 2 or 0)
        + (Config.AutoFavouriteFish and 4 or 0)
    if flags ~= blMemoFlags or Config.FavouriteFishName ~= blMemoFav or Config.CustomProtectedFish ~= blMemoCps then
        blMemoFlags = flags
        blMemoFav = Config.FavouriteFishName
        blMemoCps = Config.CustomProtectedFish
        table.clear(blMemo)
        blMemoCount = 0
    end
    local hit = blMemo[rawStr]
    if hit ~= nil then return hit end
    local res = IsFishNameBlacklistedCore(rawStr)
    if blMemoCount >= 1024 then
        table.clear(blMemo)
        blMemoCount = 0
    end
    blMemo[rawStr] = res
    blMemoCount = blMemoCount + 1
    return res
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
    local fromItemName = FG.GetPureFishName(item.Name)
    local nameLow = fromItemName:lower()
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
function FG.IsNonFishEquipmentItem(item)
    if not item or typeof(item) ~= "Instance" then return false end
    if IsToolFishingRod and IsToolFishingRod(item) then return true end
    local pureName = FG.GetFishItemPrimaryPureName(item)
    local pureLow = tqLc(pureName)
    if pureLow == "" then return true end
    if FG.craftMaterialFish[pureName] or (FG.rodMaterialFish and FG.rodMaterialFish[pureName]) then return false end
    if FG.IsFishLikeName(pureLow) then return false end
    if FG.nonFishExactOnlySet[pureLow] then
        return true
    end
    for i = 1, #FG.nonFishStrongKeywords do
        local kw = FG.nonFishStrongKeywords[i]
        if kw:find("^[%a]+$") then
            if pureLow == kw or pureLow:find("%f[%a]" .. kw .. "%f[%A]") then
                return true
            end
        elseif pureLow:find(kw, 1, true) then
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
    return false
end
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
function FG.IsFishLockProtected(item)
    return FG.IsFishItemFavorited(item)
end
local unpackFavArgs = table.unpack or unpack
FG.internalFavCallCount = 0
local function EnterInternalFavCall()
    FG.internalFavCallCount = (FG.internalFavCallCount or 0) + 1
    FG.isInternalFavCall = true
    FG.internalFavCallAt = tick()
    if sharedEnv then sharedEnv.IdenticalInternalFavCall = true end
end
local function LeaveInternalFavCall()
    local nextCount = (FG.internalFavCallCount or 1) - 1
    if nextCount <= 0 then
        FG.internalFavCallCount = 0
        FG.isInternalFavCall = false
        FG.internalFavCallAt = nil
        if sharedEnv then sharedEnv.IdenticalInternalFavCall = false end
    else
        FG.internalFavCallCount = nextCount
    end
end
function FG.RawCallFavRemote(favRem, ...)
    if not favRem or not favRem.Parent then return false end
    local args = table.pack(...)
    if favRem:IsA("RemoteEvent") then
        if PacketGuard and not PacketGuard.Allow(favRem, ...) then return false end
        EnterInternalFavCall()
        local ok, err = pcall(function() favRem:FireServer(unpackFavArgs(args, 1, args.n)) end)
        LeaveInternalFavCall()
        if PacketGuard then PacketGuard.RecordResult(favRem, ok, err) end
        return ok
    elseif favRem:IsA("RemoteFunction") then
        if PacketGuard and not PacketGuard.Allow(favRem, ...) then return false end
        local th = task.spawn(function()
            EnterInternalFavCall()
            local ok, err = pcall(function() favRem:InvokeServer(unpackFavArgs(args, 1, args.n)) end)
            LeaveInternalFavCall()
            if PacketGuard then PacketGuard.RecordResult(favRem, ok, err) end
        end)
        return th ~= nil
    end
    return false
end
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
function FG.BuildCandidateFavFormats(modeOverride)
    local mode = modeOverride or Config.FavPacketMode or "鱼名+后缀(Name | Favorite)"
    local order = {}
    local seen = {}
    local function pushFmt(f)
        if f and not seen[f] then
            seen[f] = true
            table.insert(order, f)
        end
    end
    if mode ~= "鱼名+后缀(Name | Favorite)" and not FG._favModeWarned then
        FG._favModeWarned = true
        FLogWarn("上锁", "所选发包模式在抓包中不存在（pcap3 只观测到 name_favorite），本次仍按 name_favorite 发送: " .. tostring(mode))
    end
    pushFmt("name_favorite")
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
    if FG.isInternalFavCall or (sharedEnv and sharedEnv.IdenticalInternalFavCall) then
        local t0 = FG.internalFavCallAt
        if t0 and (tick() - t0) <= 1.5 then
            return false
        end
        FG.isInternalFavCall = false
        FG.internalFavCallAt = nil
        if sharedEnv then sharedEnv.IdenticalInternalFavCall = false end
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
    if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming) then
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
function FG.ExecuteSingleLockNow(item, favRem, preverified)
    if not item or typeof(item) ~= "Instance" or not item.Parent then return false end
    if not preverified and (FG.IsNonFishEquipmentItem(item) or not FG.ShouldProtectFishItem(item)) then return false end
    if FG.IsFishItemFavorited(item) then
        return false
    end
    local now = tick()
    if now < (FG.lockRetryAfter[item] or 0) then return false end
    favRem = favRem or FG.GetFavoriteRemote()
    if not favRem then return false end
    local candidates = FG.BuildCandidateFavFormats()
    local tryIdx = (FG.lockFailCount[item] or 0) + 1
    local verifiedFmt = (FG.verifiedSmartFavFormat == "name_favorite") and "name_favorite" or nil
    local fmt = verifiedFmt or candidates[math.clamp(tryIdx, 1, #candidates)] or "name_favorite"
    local sendOk = FG.FireFormatOnce(favRem, item, fmt)
    if not sendOk then return false end
    FG.lastAnyLockSentAt = now
    FG.RegisterLockedInstance(item, now)
    task.spawn(function()
        task.wait(1.8)
        local okVerify, errVerify = pcall(function()
            if not isRunning or not item or not item.Parent then return end
            local dataLocked, hasExplicitField = FG.GetFishItemDataLockState(item)
            if dataLocked then
                FG.verifiedSmartFavFormat = fmt
                FG.RegisterLockedInstance(item, now)
                FG.lockFailCount[item] = nil
                FG.lockRetryAfter[item] = nil
                return
            end
            local explicitlyStillUnlocked = false
            if hasExplicitField and not dataLocked then
                explicitlyStillUnlocked = true
            elseif not hasExplicitField and FG.IsInventoryGridVisibleOnScreen() then
                FG.RefreshGuiLockCache(tick(), true)
                local guiStrictState = FG.GetGuiSlotLockState(item, "strict")
                if guiStrictState == false then
                    explicitlyStillUnlocked = true
                elseif guiStrictState == true then
                    FG.verifiedSmartFavFormat = fmt
                    return
                end
            end
            if explicitlyStillUnlocked then
                local fails = (FG.lockFailCount[item] or 0) + 1
                FG.lockFailCount[item] = fails
                FG.UnregisterLockedInstance(item)
                if fails < 3 then
                    FG.lockRetryAfter[item] = tick() + 1.5
                else
                    FG.lockRetryAfter[item] = tick() + 10.0
                    FLogWarn("上锁", "保护鱼连续上锁失败（候选格式已试遍），已延长重试冷却并保持未锁状态以防误卖")
                end
            end
        end)
        if not okVerify then FLogErr("上锁校验", errVerify) end
    end)
    return true
end
function FG.StartBatchLockWorker()
    if FG.isBatchLockQueueRunning then
        local th = FG.batchLockThread
        if th == nil then
            if (tick() - (FG.batchLockStartedAt or 0)) < 60.0 then return end
        elseif coroutine.status(th) ~= "dead" then
            return
        end
        FLogWarn("批量上锁", "检测到分批上锁协程已终止但标记未释放，执行一次性自愈重置")
        FG.isBatchLockQueueRunning = false
        FG.batchLockStartedAt = 0
        FG.batchLockThread = nil
    end
    FG.isBatchLockQueueRunning = true
    FG.batchLockStartedAt = tick()
    local selfThread = nil
    selfThread = task.spawn(function()
        local batchSent = 0
        local maxPassGuard = 0
        pcall(function()
            while isRunning and #FG.pendingLockQueue > 0 and maxPassGuard < 400 do
                while isRunning and FishGate and FishGate.IsFight and FishGate.IsFight() do
                    task.wait(0.25)
                end
                if not isRunning then break end
                maxPassGuard = maxPassGuard + 1
                local item = table.remove(FG.pendingLockQueue, 1)
                if item then
                    FG.inLockQueue[item] = nil
                    if item.Parent and not FG.IsFishItemFavorited(item) and not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                        local favRem = Events and Events:FindFirstChild("FavoriteItem") or FG.GetFavoriteRemote()
                        if favRem and FG.ExecuteSingleLockNow(item, favRem, true) then
                            batchSent = batchSent + 1
                            if batchSent % 45 == 0 then
                                task.wait(1.0)
                                FG.RefreshGuiLockCache(tick(), true)
                            elseif batchSent % 20 == 0 then
                                task.wait(0.45)
                                FG.RefreshGuiLockCache(tick(), true)
                            else
                                HRandomWait(0.07, 0.03)
                            end
                        else
                            local rc = FG.lockRequeue[item] or 0
                            if isRunning and item and item.Parent and rc < 2
                                and not FG.inLockQueue[item] and not FG.IsFishItemFavorited(item) then
                                FG.lockRequeue[item] = rc + 1
                                FG.inLockQueue[item] = true
                                table.insert(FG.pendingLockQueue, item)
                                task.wait(0.35)
                            else
                                HRandomWait(0.05, 0.05)
                            end
                        end
                    end
                end
            end
        end)
        if selfThread == nil or FG.batchLockThread == selfThread then
            FG.isBatchLockQueueRunning = false
            FG.batchLockStartedAt = 0
            FG.batchLockThread = nil
        end
        if isRunning and #FG.pendingLockQueue > 0 then
            FG.StartBatchLockWorker()
        end
    end)
    FG.batchLockThread = selfThread
end
function FG.TryLockSingleFishItem(item, favRem, now, forceResend, preverified)
    if not item or typeof(item) ~= "Instance" or (not preverified and FG.IsNonFishEquipmentItem(item)) then
        return false, false
    end
    if FG.GetFishItemDataLockState(item) then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or tick())
        return false, false
    end
    if not forceResend and FG.IsFishItemFavorited(item) then
        return false, false
    end
    if not preverified and not FG.ShouldProtectFishItem(item) then
        return false, false
    end
    if FG.inLockQueue[item] then
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
FG.bagFolderConns = FG.bagFolderConns or {}
function FG.EnsureBagAutoLockListeners(pData)
    if not pData then return end
    for connName, deadConn in pairs(FG.bagFolderConns) do
        if deadConn and not deadConn.Connected then
            FG.bagFolderConns[connName] = nil
            local deadIdx = table.find(activeConnections, deadConn)
            if deadIdx then table.remove(activeConnections, deadIdx) end
        end
    end
    for _, folderName in ipairs({"Inventory", "Hotbar"}) do
        local folder = pData:FindFirstChild(folderName)
        if folder and not FSYC.watchedBagFolders[folder] then
            FSYC.watchedBagFolders[folder] = true
            local oldConn = FG.bagFolderConns[folderName]
            if oldConn then
                pcall(function() oldConn:Disconnect() end)
                local idx = table.find(activeConnections, oldConn)
                if idx then table.remove(activeConnections, idx) end
            end
            local conn = folder.ChildAdded:Connect(function(newItem)
                if not isRunning then return end
                if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) then return end
                if FG.ClaimDestroyedLockInheritance(newItem) then
                    return
                end
                task.delay(0.15, function()
                    if not isRunning or not newItem or not newItem.Parent then return end
                    if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) then return end
                    if FG.ClaimDestroyedLockInheritance(newItem) then return end
                    local favRem = FG.GetFavoriteRemote()
                    FG.TryLockSingleFishItem(newItem, favRem, tick(), false)
                end)
            end)
            FG.bagFolderConns[folderName] = conn
            table.insert(activeConnections, conn)
        end
    end
end
DashUI._cleanupFG = function()
    table.clear(FG.pendingLockQueue)
    table.clear(FG.inLockQueue)
    FG.isBatchLockQueueRunning = false
    FG.isInternalFavCall = false
end
TryFavoriteProtectedFish = function(pData, forceResendAll)
    pData = pData or GetPlayerData()
    if not pData or not Events then return 0, 0 end
    FG.EnsureBagAutoLockListeners(pData)
    local favRem = Events:FindFirstChild("FavoriteItem") or FG.GetFavoriteRemote()
    if not favRem then return 0, 0 end
    local now = tick()
    if now - (FG.lastLockListSweep or 0) >= 3.0 then
        FG.lastLockListSweep = now
        for baseKey, list in pairs(FG.lockedInstListByBase) do
            if type(list) == "table" then
                for i = #list, 1, -1 do
                    local entry = list[i]
                    local deadInst = (not entry) or (not entry.inst) or entry.inst.Parent == nil
                    if deadInst and (not entry or not entry.sentAt or (now - entry.sentAt) > 120.0) then
                        table.remove(list, i)
                    end
                end
                if #list == 0 then FG.lockedInstListByBase[baseKey] = nil end
            end
        end
    end
    FG.RefreshGuiLockCache(now, forceResendAll == true)
    local unfavProtectedCount = 0
    local queuedCount = 0
    local bagNames = FG.bagFolderNames
    FG.lockStateChainMemo = {}
    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsNonFishEquipmentItem(item) and FG.ShouldProtectFishItem(item) then
                    if forceResendAll and not FG.IsFishItemDataFavorited(item) then
                        if FG.IsInventoryGridVisibleOnScreen() and FG.GetGuiSlotLockState(item, "strict") == false then
                            FG.UnregisterLockedInstance(item)
                        end
                    end
                    if not FG.IsFishItemFavorited(item) then
                        unfavProtectedCount = unfavProtectedCount + 1
                        local _, didQueue = FG.TryLockSingleFishItem(item, favRem, now, false, true)
                        if didQueue then
                            queuedCount = queuedCount + 1
                        end
                    end
                end
            end
        end
    end
    FG.lockStateChainMemo = nil
    return unfavProtectedCount, queuedCount
end
function FG.HasAnyLockSettlingInBag(pData)
    if FG.isBatchLockQueueRunning or #FG.pendingLockQueue > 0 then
        return true
    end
    local now = tick()
    local settleWin = (FSYC.Tunables and FSYC.Tunables.LockSettlingWindowSec) or 2.0
    if FG.lastAnyLockSentAt > 0 and (now - FG.lastAnyLockSentAt) < settleWin then
        return true
    end
    pData = pData or GetPlayerData()
    if not pData then return false end
    local bagNames = FG.bagFolderNames
    for fIdx = 1, #bagNames do
        local folder = pData:FindFirstChild(bagNames[fIdx])
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if FG.inLockQueue[item] then
                    return true
                end
                local sentAt = FG.lastLockSentAt[item]
                if sentAt and (now - sentAt) < settleWin then
                    return true
                end
            end
        end
    end
    return false
end
function FG.IsSellPacketArgBlacklisted(arg, depth)
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
        depth = (tonumber(depth) or 0) + 1
        if depth > 3 then
            FLogWarn("卖鱼拦截", "出售参数嵌套过深，已按可疑参数阻断")
            return true
        end
        for k, v in pairs(arg) do
            if FG.IsSellPacketArgBlacklisted(k, depth) or FG.IsSellPacketArgBlacklisted(v, depth) then
                return true
            end
        end
    end
    return false
end
if sharedEnv then
    sharedEnv.IdenticalIsSellArgBlocked = FG.IsSellPacketArgBlacklisted
end
SafeSellAllFish = function(pData)
    if isSellingInProgress or not Events or not Events:FindFirstChild("SellFish") then return end
    isSellingInProgress = true
    task.spawn(function()
        local okSell, sellErr = pcall(function()
            local sellRem = Events:FindFirstChild("SellFish")
            pData = pData or GetPlayerData()
            if not sellRem or not pData then return end
            local char = LocalPlayer.Character
            local isHoldingFish = false
            if char then
                for _, ch in ipairs(char:GetChildren()) do
                    if (ch:IsA("Model") or ch:IsA("Tool")) and not IsToolFishingRod(ch, pData) then
                        isHoldingFish = true
                        break
                    end
                end
            end
            if isHoldingFish and EnsureFishingRodEquipped then
                pcall(EnsureFishingRodEquipped)
                task.wait(0.12)
            end
            FG.RefreshGuiLockCache(tick(), true)
            TryFavoriteProtectedFish(pData, false)
            local waitStart = tick()
            local maxWait = math.clamp(2.5 + (#FG.pendingLockQueue * 0.14), 2.5, 25.0)
            local lastRetryAt = 0
            while isRunning and (tick() - waitStart < maxWait) do
                local settling = FG.HasAnyLockSettlingInBag(pData)
                if not settling then
                    if not FG.HasAnyUnsafeProtectedFishInBag(pData) then break end
                    local nowTick = tick()
                    if not FG.isBatchLockQueueRunning and (nowTick - lastRetryAt) >= 1.0 then
                        lastRetryAt = nowTick
                        pcall(TryFavoriteProtectedFish, pData, false)
                    end
                end
                task.wait(0.15)
            end
            FG.RefreshGuiLockCache(tick(), true)
            if not isRunning then return end
            if FishGate and not FishGate.IsIdle() then
                ShowNotification("防冲突保护", "检测到等待期间已进入钓鱼或搏鱼状态，本次自动卖鱼已安全延后！", "WARN", 2.5)
            elseif not FG.HasAnyUnsafeProtectedFishInBag(pData) and not FG.HasAnyLockSettlingInBag(pData) then
                if sellRem:IsA("RemoteEvent") then
                    if not PacketGuard or PacketGuard.Allow(sellRem, "All") then
                        local okFire, errFire = pcall(function() sellRem:FireServer("All") end)
                        if PacketGuard then PacketGuard.RecordResult(sellRem, okFire, errFire) end
                    end
                elseif sellRem:IsA("RemoteFunction") then
                    DashUI._safeInvokeAsync(sellRem, FSYC.Tunables and FSYC.Tunables.InvokeDefaultTimeoutSec or 4.0, "All")
                end
                ShowNotification("自动卖鱼", "已确认全部保护鱼锁定完毕，安全执行全卖普通鱼！", "SUCCESS", 2)
            else
                ShowNotification("防误卖保护", "检测到保护鱼正在同步锁定中，已延后本次出售，确保绝不误卖保护鱼！", "WARN", 2.5)
            end
        end)
        if not okSell then FLogErr("卖鱼", sellErr) end
        pcall(function() task.wait(0.2) end)
        isSellingInProgress = false
    end)
end
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
                if prompt and prompt.Parent then
                    prompt:InputHoldEnd()
                end
            end)
            activePromptTasks[prompt] = nil
        end)
    end
end
GetNPCPosition = function(npc)
    if not npc then return nil end
    if npc:IsA("Attachment") then
        local ok, wp = pcall(function() return npc.WorldPosition end)
        if ok and wp then return wp end
        if npc.Parent then return GetNPCPosition(npc.Parent) end
    elseif npc:IsA("ProximityPrompt") or npc:IsA("BillboardGui") or npc:IsA("ClickDetector") then
        if npc.Parent then return GetNPCPosition(npc.Parent) end
    end
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
    local att = npc:FindFirstChildWhichIsA("Attachment", true)
    if att then
        local ok, wp = pcall(function() return att.WorldPosition end)
        if ok and wp then return wp end
    end
    return nil
end
local GUI_CONN_SIGNALS = {"Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "TouchTap"}
local GUI_FIRE_SIGNALS = GUI_CONN_SIGNALS
local function SyntheticModifierFalse() return false end
local function SyntheticIsA(_, cls) return cls == "InputObject" or cls == "Instance" end
MakeSyntheticInput = function(uType, uState, keyCode, posVec3)
    return {
        _isFSYSynthetic = true,
        UserInputType = uType,
        UserInputState = uState,
        KeyCode = keyCode or Enum.KeyCode.F,
        Position = posVec3 or Vector3.zero,
        Delta = Vector3.zero,
        ClassName = "InputObject",
        IsModifierKeyDown = SyntheticModifierFalse,
        IsA = SyntheticIsA,
    }
end
FireGuiButton = function(btn, allowInactive, simulateScreenTouch)
    if not btn or not btn:IsA("GuiObject") or not btn.Visible then return false end
    if btn:IsA("GuiButton") and not allowInactive and not btn.Active then return false end
    local firedAny = false
    local seenObj = {}
    local btnTargets = {}
    local guiTargets = {}
    local function addTarget(obj)
        if not obj or not obj.Parent or seenObj[obj] or not obj:IsA("GuiObject") or not obj.Visible then return end
        seenObj[obj] = true
        table.insert(guiTargets, obj)
        if obj:IsA("GuiButton") and (allowInactive or obj.Active) then
            table.insert(btnTargets, obj)
        end
    end
    addTarget(btn)
    local widgetRoot = btn
    if simulateScreenTouch or allowInactive or not btn:IsA("GuiButton") then
        local cur = btn.Parent
        local hop = 0
        while cur and cur:IsA("GuiObject") and hop < 3 do
            if cur.AbsoluteSize.X > 8 and cur.AbsoluteSize.X <= 260 and cur.AbsoluteSize.Y > 8 and cur.AbsoluteSize.Y <= 260
                and not cur:FindFirstChildOfClass("UIListLayout")
                and not cur:FindFirstChildOfClass("UIGridLayout")
                and not cur:FindFirstChildOfClass("UITableLayout")
                and not cur:FindFirstChildOfClass("UIPageLayout") then
                widgetRoot = cur
                addTarget(cur)
                cur = cur.Parent
                hop = hop + 1
            else
                break
            end
        end
        local descCache = DashUI._widgetDescCache
        if not descCache then
            descCache = setmetatable({}, { __mode = "k" })
            DashUI._widgetDescCache = descCache
        end
        local descNow = tick()
        local descHit = descCache[widgetRoot]
        local descList
        if descHit and (descNow - descHit.t) < 0.25 then
            descList = descHit.list
        else
            descList = widgetRoot:GetDescendants()
            descCache[widgetRoot] = { list = descList, t = descNow }
        end
        for _, sub in ipairs(descList) do
            addTarget(sub)
        end
    else
        if btn.Parent and btn.Parent:IsA("GuiButton") then addTarget(btn.Parent) end
        for _, ch in ipairs(btn:GetChildren()) do
            if ch:IsA("GuiButton") then addTarget(ch) end
        end
    end
    local cx = math.floor(btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5)
    local cy = math.floor(btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5)
    local posVec3 = Vector3.new(cx, cy, 0)
    local touchArr = { Vector2.new(cx, cy) }
    local fakeTouchBegin = MakeSyntheticInput(Enum.UserInputType.Touch, Enum.UserInputState.Begin, Enum.KeyCode.F, posVec3)
    for _, tBtn in ipairs(btnTargets) do
        local connFiredSigs = nil
        if type(getconnections) == "function" then
            pcall(function()
                for i = 1, #GUI_CONN_SIGNALS do
                    local sigName = GUI_CONN_SIGNALS[i]
                    local sig = tBtn[sigName]
                    if sig then
                        local conns = getconnections(sig)
                        if type(conns) == "table" and #conns > 0 then
                            local sigFired = false
                            for _, conn in ipairs(conns) do
                                local okFire = false
                                if type(conn.Fire) == "function" then
                                    if sigName == "MouseButton1Down" or sigName == "MouseButton1Up" then
                                        okFire = pcall(conn.Fire, conn, cx, cy) or pcall(conn.Fire, conn)
                                    elseif sigName == "TouchTap" then
                                        okFire = pcall(conn.Fire, conn, touchArr, false) or pcall(conn.Fire, conn)
                                    else
                                        okFire = pcall(conn.Fire, conn)
                                    end
                                    if okFire then sigFired = true end
                                end
                                if (not okFire) and type(conn.Function) == "function" then
                                    if sigName == "Activated" then
                                        task.spawn(function() pcall(conn.Function, fakeTouchBegin, 1) end)
                                    elseif sigName == "TouchTap" then
                                        task.spawn(function() pcall(conn.Function, touchArr, false) end)
                                    elseif sigName == "MouseButton1Down" or sigName == "MouseButton1Up" then
                                        task.spawn(function() pcall(conn.Function, cx, cy) end)
                                    else
                                        task.spawn(function() pcall(conn.Function) end)
                                    end
                                    sigFired = true
                                end
                            end
                            if sigFired then
                                firedAny = true
                                connFiredSigs = connFiredSigs or {}
                                connFiredSigs[sigName] = true
                                if not simulateScreenTouch then break end
                            end
                        end
                    end
                end
            end)
        end
        if type(firesignal) == "function" then
            for i = 1, #GUI_FIRE_SIGNALS do
                local fireName = GUI_FIRE_SIGNALS[i]
                if not (connFiredSigs and connFiredSigs[fireName]) then
                    local sig = tBtn[fireName]
                    if sig and pcall(firesignal, sig) then
                        firedAny = true
                    end
                end
            end
        end
    end
    if simulateScreenTouch and type(getconnections) == "function" then
        local fakeMouseBegin = MakeSyntheticInput(Enum.UserInputType.MouseButton1, Enum.UserInputState.Begin, Enum.KeyCode.F, posVec3)
        local fakeTouchEnd = MakeSyntheticInput(Enum.UserInputType.Touch, Enum.UserInputState.End, Enum.KeyCode.F, posVec3)
        local fakeMouseEnd = MakeSyntheticInput(Enum.UserInputType.MouseButton1, Enum.UserInputState.End, Enum.KeyCode.F, posVec3)
        for _, gObj in ipairs(guiTargets) do
            pcall(function()
                if not gObj:IsA("GuiButton") and gObj.TouchTap then
                    local tConns = getconnections(gObj.TouchTap)
                    if type(tConns) == "table" then
                        for _, conn in ipairs(tConns) do
                            if type(conn.Function) == "function" then
                                task.spawn(function() pcall(conn.Function, touchArr, false) end)
                                firedAny = true
                            end
                        end
                    end
                end
                if gObj.InputBegan then
                    local bConns = getconnections(gObj.InputBegan)
                    if type(bConns) == "table" then
                        for _, conn in ipairs(bConns) do
                            if type(conn.Function) == "function" then
                                task.spawn(function()
                                    pcall(conn.Function, fakeTouchBegin, false)
                                    pcall(conn.Function, fakeMouseBegin, false)
                                end)
                                firedAny = true
                            end
                        end
                    end
                end
                if gObj.InputEnded then
                    local eConns = getconnections(gObj.InputEnded)
                    if type(eConns) == "table" then
                        for _, conn in ipairs(eConns) do
                            if type(conn.Function) == "function" then
                                task.delay(HRand(0.03, 0.04), function()
                                    pcall(conn.Function, fakeTouchEnd, false)
                                    pcall(conn.Function, fakeMouseEnd, false)
                                end)
                            end
                        end
                    end
                end
            end)
        end
    end
    if simulateScreenTouch and widgetRoot.AbsoluteSize.X > 4 and widgetRoot.AbsoluteSize.Y > 4 then
        pcall(function()
            local clickX = math.floor(widgetRoot.AbsolutePosition.X + widgetRoot.AbsoluteSize.X * 0.5)
            local clickY = math.floor(widgetRoot.AbsolutePosition.Y + widgetRoot.AbsoluteSize.Y * 0.5)
            local guiInsetY = 0
            pcall(function()
                local sg = widgetRoot:FindFirstAncestorWhichIsA("ScreenGui")
                if not (sg and sg.IgnoreGuiInset) then
                    local gs = game:GetService("GuiService")
                    if gs then guiInsetY = gs:GetGuiInset().Y end
                end
            end)
            local screenY = clickY + guiInsetY
            local vim = game:GetService("VirtualInputManager")
            if vim then
                local allowTouchSim = not (ModeCtl and ModeCtl.IsDesktop and ModeCtl.IsDesktop() and ModeCtl.IsForced and ModeCtl.IsForced())
                local mKey = DashUI._pressVirtualMouse(clickX, screenY, allowTouchSim)
                local mKeyInset = (guiInsetY ~= 0) and DashUI._pressVirtualMouse(clickX, clickY, false) or nil
                pcall(function() vim:SendMouseButtonEvent(clickX, screenY, 0, true, game, 1) end)
                if guiInsetY ~= 0 then
                    pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1) end)
                end
                if allowTouchSim then
                    pcall(function() vim:SendTouchEvent(0, 0, clickX, screenY) end)
                end
                task.delay(HRand(0.03, 0.04), function()
                    pcall(function() vim:SendMouseButtonEvent(clickX, screenY, 0, false, game, 1) end)
                    if guiInsetY ~= 0 then
                        pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1) end)
                    end
                    if allowTouchSim then
                        pcall(function() vim:SendTouchEvent(0, 2, clickX, screenY) end)
                    end
                    DashUI._releaseVirtualMouse(mKey)
                    if mKeyInset then DashUI._releaseVirtualMouse(mKeyInset) end
                end)
                firedAny = true
            end
            local vu = game:GetService("VirtualUser")
            if vu then
                pcall(function()
                    vu:CaptureController()
                    vu:ClickButton1(Vector2.new(clickX, screenY))
                end)
            end
        end)
    end
    return firedAny
end
do
local sellCard = createCollapsibleGroup(tabFishing, "经济与出售", false)
createToggleRow(sellCard, "自动卖鱼", "定期安全出售普通鱼（开启时自动联动启用锁鱼防卖，保护鱼绝不出售）", Config.AutoSell, function(v)
    Config.AutoSell = v
    if v then
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
        HRandomWait(0.3, 0.15)
        SafeSellAllFish(pData)
    end
end)
local baseFishList = {
    "Wraith Orca", "Colossal Tigerfish", "Heavenpiercer Turtle", "Golden Guardian Fish",
    "Crimson Electric Eel", "Rainbow Dragonfish", "Frost Kingfish", "Frost Queenfish",
    "Ascended Perch", "Primordial Kunfish Overlord", "Warbringer Shark",
    "Mountain Fish", "Tiger Mirefish", "Mirage Lanternfish", "Octoparasitic Fish", "Nameless Octoparasite",
    "Flying Fish Emperor", "Flying Fish Empress", "Sanguine Fish", "Draconic Koi",
    "Reborn Puffer Beast", "Trueform Jiaolongfish",
    "Yinfish Sovereign", "Yangfish Sovereign", "Yangfish Empress", "Intuitive Fish King",
    "Aquatic Fish", "Flame Fish", "Thunder Fish", "Wind Fish",
    "Apollo Swordfish", "Killer Sawshark", "Demon Bladefish", "Colossal Bull Shark", "Thunder Bull Shark",
    "Golden Dragon Fish", "Dark Kingfish", "Mountain Dragon Whale",
    "Crimson Catfish", "Elder Scarlet Fish", "Scarlet Fish", "Catfish"
}
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
local favBoxSyncing = false
local function EnsureFishInProtectedList(fishName)
    local target = FG.GetPureFishName(fishName)
    if not target or target == "" then return false end
    local targetLow = target:lower()
    local cur = Config.CustomProtectedFish or ""
    local items = {}
    local exists = false
    for token in string.gmatch((cur:gsub("，", ","):gsub("；", ";")), "([^,;\n\r]+)") do
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
        local joined = table.concat(items, ",")
        local droppedFav = 0
        while #joined > 900 and #items > 1 do
            table.remove(items, 1)
            droppedFav = droppedFav + 1
            joined = table.concat(items, ",")
        end
        if droppedFav > 0 then
            FLogWarn("保护名单", "名单已超 900 字节上限，按最旧优先丢弃 " .. droppedFav .. " 项；新加入项已保留")
        end
        if #joined > 900 then joined = Utf8SafeCut(joined, 900) end
        Config.CustomProtectedFish = joined
        if customFavBox then
            favBoxSyncing = true
            customFavBox.Text = Config.CustomProtectedFish
            favBoxSyncing = false
        end
        return true
    end
    return false
end
local favDropdownCtrl = createDropdownRow(sellCard, "收藏目标", "选中即自动加入保护名单（含变异鱼）；之前选过的鱼也会继续保留保护", baseFishList, Config.FavouriteFishName, function(v)
    Config.FavouriteFishName = v
    EnsureFishInProtectedList(v)
    local pData = GetPlayerData()
    if (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, pData, false)
    end
    local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or tostring(v)
    ShowNotification("已添加保护目标", string.format("当前选中: [%s]\n受保护总名单: %s", tostring(v), listStr), "SUCCESS", 3)
end, "FavouriteFishName", 160)
createToggleRow(sellCard, "材料升级模式 (制作钓竿材料鱼)", "开启后自动保护全部制作钓竿材料鱼（破天竿/纯钻竿/神圣竹竿/天道竿/未知竿全部材料鱼）", Config.RodMaterialFarming, function(v)
    Config.RodMaterialFarming = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "RodMaterialFarming")
createToggleRow(sellCard, "材料收集模式 (制作鱼饵材料鱼)", "开启后自动保护全部 5 大神话Boss鱼饵材料鱼（无名/冰霜/彩虹/直觉/雷霆鱼饵全套材料鱼）", Config.MaterialFarming, function(v)
    Config.MaterialFarming = v
    if v then
        local pData = GetPlayerData()
        if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, pData, false) end
    end
end, "MaterialFarming")
do
    local listRow = createBaseRow(sellCard, "收藏/保护名单", "可手改；支持 Wraith*、*Orca、=精确名、中文译名，逗号分隔", 250)
    customFavBox = Instance.new("TextBox")
    customFavBox.Size = UDim2.new(0, 236, 0, 34)
    customFavBox.Position = UDim2.new(1, -240, 0.5, -17)
    customFavBox.BackgroundColor3 = Colors.InputBg
    customFavBox.Font = Enum.Font.GothamBold
    customFavBox.Text = Config.CustomProtectedFish or ""
    customFavBox.PlaceholderText = "例: Colossal Tigerfish, Wraith Orca"
    customFavBox.TextColor3 = Colors.TextWhite
    customFavBox.PlaceholderColor3 = Colors.TextMuted
    customFavBox.TextSize = 11
    customFavBox.TextWrapped = true
    customFavBox.MultiLine = false
    customFavBox.BorderSizePixel = 0
    customFavBox.ClearTextOnFocus = false
    customFavBox.Parent = listRow
    Instance.new("UICorner", customFavBox).CornerRadius = UDim.new(0, 8)
    do
        local fp = Instance.new("UIPadding"); fp.PaddingLeft = UDim.new(0, 8); fp.PaddingRight = UDim.new(0, 8); fp.Parent = customFavBox
        local fs = Instance.new("UIStroke", customFavBox); fs.Color = Colors.BorderSubtle; fs.Thickness = 1; fs.Transparency = 0.35
    end
    customFavBox:GetPropertyChangedSignal("Text"):Connect(function()
        if favBoxSyncing then return end
        local favTxt = customFavBox.Text
        if #favTxt > 900 then favTxt = Utf8SafeCut(favTxt, 900) end
        Config.CustomProtectedFish = favTxt
    end)
    customFavBox.FocusLost:Connect(function()
        if favBoxSyncing then return end
        local favTxt = customFavBox.Text
        if #favTxt > 900 then favTxt = Utf8SafeCut(favTxt, 900) end
        Config.CustomProtectedFish = favTxt
        local pData = GetPlayerData()
        if (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
            TryFavoriteProtectedFish(pData, false)
        end
        ShowNotification("名单已更新", "已更新自定义多选保护名单！", "SUCCESS", 2.5)
    end)
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
    if pData and (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
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
    if Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming then
        TryFavoriteProtectedFish(pData, false)
    end
    local protList, sellList = {}, {}
    for _, folderName in ipairs(FG.bagFolderNames) do
        local folder = pData:FindFirstChild(folderName)
        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                if not FG.IsNonFishEquipmentItem(item) then
                    local pure = FG.GetFishItemPrimaryPureName(item)
                    local lockedTag = FG.IsFishItemFavorited(item) and "[已锁]" or "[防卖]"
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
    for token in string.gmatch((cur:gsub("，", ","):gsub("；", ";")), "([^,;\n\r]+)") do
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
        if (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
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
end
TeleportToDragonSea = function()
    local targetPos = nil
    local searchFolders = {}
    for _, fName in ipairs({"BossSetUp", MAP_ROOT_NAMES[1], MAP_ROOT_NAMES[2]}) do
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
do
local function createWarnNote(parent, text)
    local box = Instance.new("Frame")
    box.Name = "WarnNote"
    box.Size = UDim2.new(1, 0, 0, 0)
    box.AutomaticSize = Enum.AutomaticSize.Y
    box.BackgroundColor3 = Color3.fromRGB(64, 46, 12)
    box.BackgroundTransparency = 0.15
    box.BorderSizePixel = 0
    box.Parent = parent
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = box
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.PaddingRight = UDim.new(0, 10)
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.Parent = box
    local lbl = Instance.new("TextLabel")
    lbl.Name = "Text"
    lbl.Size = UDim2.new(1, 0, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 11
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = Color3.fromRGB(255, 196, 92)
    lbl.Text = tostring(text or "")
    lbl.Parent = box
    return {
        frame = box,
        SetActive = function(on)
            if on then
                box.BackgroundColor3 = Color3.fromRGB(92, 58, 10)
                box.BackgroundTransparency = 0.10
                lbl.TextColor3 = Color3.fromRGB(255, 200, 96)
            else
                box.BackgroundColor3 = Color3.fromRGB(38, 36, 32)
                box.BackgroundTransparency = 0.25
                lbl.TextColor3 = Color3.fromRGB(168, 160, 146)
            end
        end,
    }
end
local octoCard = createCollapsibleGroup(tabBoss, "章鱼寄生体 (隐藏Boss)")
createToggleRow(octoCard, "自动玩小游戏 (节奏机器人)", "机器人自动安全打拍子", Config.OctoAutoMinigame, function(v)
    Config.OctoAutoMinigame = v
end, "OctoAutoMinigame")
createSliderRow(octoCard, "节奏命中率 (Accuracy %)", "每个节拍真的去按的几率。100 = 每次都按（最稳、必定过）；越低越像真人手速，但空过的节拍会被游戏判成漏按（-200 血）。命中 +50 / 漏按 -200，所以 80% 是收益平衡点、低于 80% 净亏血，不确定就保持 100", 85, 100, Config.RhythmAccuracy, true, "%", function(v)
    Config.RhythmAccuracy = v
end, "RhythmAccuracy")
createDropdownRow(octoCard, "节奏节拍", "两次命中的间隔。本关 20000 血 ÷ 每击 70 = 需 286 次命中、限时 120 秒，真人实测平均 0.36 秒（约 103 秒打完）。0.30s 已是最快安全档（86s），再快必被封", {"0.38s 保守", "0.36s 真人速", "0.34s 稳健(推荐)", "0.30s 最快(仍安全)"}, "0.34s 稳健(推荐)", function(v)
    local map = { ["0.38s 保守"] = 0.38, ["0.36s 真人速"] = 0.36, ["0.34s 稳健(推荐)"] = 0.34, ["0.30s 最快(仍安全)"] = 0.30 }
    Config.RhythmBeatSec = map[v] or 0.34
end, "RhythmBeatSec")
createButtonRow(octoCard, "传送到章鱼寄生体", "传送到海洋隐藏Boss浮标", "传送", function()
    if SafeTeleport(CFrame.new(1608.2, 5.0, -218.3)) then ShowNotification("已传送", "已到达无名章鱼寄生体海洋浮标！", "SUCCESS") end
end)
createButtonRow(octoCard, "传送到渔夫之地", "传送到地下渔夫领域", "传送", function()
    if SafeTeleport(CFrame.new(112.5, -330.0, -30.8)) then ShowNotification("已传送", "已到达地下渔夫之地！", "SUCCESS") end
end)
local bossFarmCard = createCollapsibleGroup(tabBoss, "恩佐 龙钓海")
DashUI.infoBossHit = createInfoRow(bossFarmCard, "第二阶段命中", "—")
createToggleRow(bossFarmCard, "真实命中上报(读条)",
    "读 BossFightBar 判定条，只在游标进入判定区时发 BossPhase2Action(Hit=true)；窗口外如实发 Hit=false。间隔由下方「命中节拍」档位决定（1.20/0.95/0.75/0.60/0.45/0.30s，实际下限 0.30s），读不到判定条自动停",
    Config.RealBossHit, function(v)
        Config.RealBossHit = v
        if v then
            ShowNotification("真实命中上报", "已开启。需要先触发一场 Enzo 战，收到第二阶段参数后才会开始上报。", "SUCCESS", 5)
        else
            pcall(RealBossDeactivate, "手动关闭")
            ShowNotification("真实命中上报", "已关闭，恢复原有逻辑。", "INFO", 3)
        end
    end, "RealBossHit")
createDropdownRow(bossFarmCard, "命中节拍", "本关 Boss 20000 血 ÷ 每次 200 = 需 100 次命中，所以档位直接等于「多少秒打完」：1.20→120s｜0.95→95s｜0.75→75s｜0.60→60s｜0.45→45s｜0.30→30s。判定条最快约 0.54 秒给一次机会（100 次≈54 秒是真人极限），比 0.60 更快就是人做不到的速率", {"1.20s 真人速", "0.95s 稳健", "0.75s 偏快(推荐)", "0.60s 很快(有风险)", "0.45s 极快(概率封号)", "0.30s 疯狂(高概率封号)"}, "0.75s 偏快(推荐)", function(v)
    local map = {
        ["1.20s 真人速"] = 1.20, ["0.95s 稳健"] = 0.95, ["0.75s 偏快(推荐)"] = 0.75,
        ["0.60s 很快(有风险)"] = 0.60, ["0.45s 极快(概率封号)"] = 0.45,
        ["0.30s 疯狂(高概率封号)"] = 0.30,
    }
    Config.RealBossGap = map[v] or 0.75
end, "RealBossGap")
local aggressiveWarnNote
createToggleRow(bossFarmCard, "激进模式(不等绿区)",
    "不等绿区经过，按节拍直接报命中。注意：它的真正风险不是「快」，而是每一发都落在判定区之外——服务端按自己的判定条位置一比对就是不可能的操作",
    Config.RealBossForce, function(v)
        Config.RealBossForce = v
        if aggressiveWarnNote then pcall(aggressiveWarnNote.SetActive, v) end
        if v then
            local curGap = tonumber(Config.RealBossGap) or 0.75
            local extra = (curGap < 0.95) and string.format("当前 %.2fs 偏快，建议先调到 0.95s 以上。", curGap) or ""
            ShowNotification("⚠ 激进模式", "已开启：跳过绿区判定，速度过快可能被判定为脚本并封号！" .. extra, "WARN", 8)
        else
            ShowNotification("激进模式", "已关闭，恢复读条判定（贴绿区，最安全）。", "INFO", 3)
        end
    end, "RealBossForce")
aggressiveWarnNote = createWarnNote(bossFarmCard,
    "⚠ 风险提示：激进模式会跳过绿区判定 —— 服务端知道判定条在哪，你在区外报命中就是不可能的操作，调慢节拍也救不回来。"
    .. "已有实例因「小游戏 33 秒耗完 Boss 剩余血」被封号 —— 速度过快可能会封号！"
    .. "节拍档位：0.60s「很快」已接近判定条上限；0.45s「极快」、0.30s「疯狂」都超出判定条能给到的节奏（概率/高概率封号）。"
    .. "想稳就把节拍调到 0.95s 或 1.20s；关掉本项则回到贴绿区判定，最安全。")
if aggressiveWarnNote then pcall(aggressiveWarnNote.SetActive, Config.RealBossForce == true) end
createToggleRow(bossFarmCard, "强制显示钓鱼按钮",
    "开=右侧【钓鱼】按钮一直显示（打开仓库/装备/商店也照样显示）；关=完全不碰游戏原生界面",
    Config.ForceFishBtn, function(v)
        Config.ForceFishBtn = v
        if v then
            pcall(RestoreMobileFishingButtonUI, true)
        end
    end, "ForceFishBtn")
createSliderRow(bossFarmCard, "拟人命中率",
    "仅对「激进模式」生效：按百分比主动漏报。100=一次不漏（统计数据不像真人），65≈真人实测命中率，越低头越安全。读条模式下本项无作用",
    50, 100, Config.RealBossHitRate, true, "%", function(v) Config.RealBossHitRate = v end, "RealBossHitRate")
createButtonRow(bossFarmCard, "传送到Enzo", "传送到Enzo竞技场", "传送", function()
    if SafeTeleport(CFrame.new(-115.3, 9.2, 1349.5)) then ShowNotification("已传送", "已到达Enzo竞技场！", "SUCCESS") end
end)
createButtonRow(bossFarmCard, "传送到龙钓海", "传送到龙钓海", "传送", function()
    TeleportToDragonSea()
end)
end
end
do
local function SafeFireOneRemote(rem, ...)
    if typeof(rem) ~= "Instance" or not rem.Parent then return false, "remote_unavailable" end
    if rem:IsA("RemoteEvent") then
        if PacketGuard and not PacketGuard.Allow(rem, ...) then
            return false, "rate_limited_or_backoff"
        end
        local ok, err = pcall(rem.FireServer, rem, ...)
        if PacketGuard then PacketGuard.RecordResult(rem, ok, err) end
        if not ok then return false, tostring(err) end
        return true, "event_sent"
    elseif rem:IsA("RemoteFunction") then
        if DashUI and type(DashUI._safeInvokeAsync) == "function" then
            local queued = DashUI._safeInvokeAsync(rem, FSYC.Tunables and FSYC.Tunables.InvokeDefaultTimeoutSec or 4.0, ...)
            return queued, queued and "invoke_queued" or "invoke_throttled"
        end
    end
    return false, "unsupported_instance"
end
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
ImportantDialogueNPCs = {
    {cnName = "票据任务员 (Quest Giver)", internalName = "Ticket Quest Giver", desc = "每日票据任务 (起始岛 [1] Easy / Hard 抽卡券任务)", aliases = {"Ticket Quest Giver", "Quest Giver", "QuestGiver", "TicketQuest", "Ticket NPC", "Ticket", "DailyQuest", "票据", "任务员", "每日票据", "Nhân Viên Nhiệm Vụ Vé", "Nhan Vien Nhiem Vu Ve", "Phiếu Nhiệm Vụ", "Phieu Nhiem Vu"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "南江 (Nanjang / Nanjiang)", internalName = "Nanjang", desc = "抽特质 物品交换 (初始岛 [1] 技能特质重铸 / 洗练四圣兽)", aliases = {"Nanjang", "Nanjiang", "Nam Giang", "NamGiang", "TraitNPC", "Trait", "南江", "特质"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "初始岛楚依旧 · 智者伊杰尤 (Sage Yiju)", internalName = "Sage Yiju", desc = "买技能 对话 (初始岛 [1] 智者伊杰尤 · 基础 Cash 金币钓鱼技能商店)", aliases = {"智者伊杰尤", "伊杰尤", "Sage Yiju", "Sage Yijiu", "Chu Yijiu", "Sage Eiju", "Yiju", "Eiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者", "买技能", "技能商人"}, fallbackPos = Vector3.new(-117.5, 6.8, 41.2), preferPos = Vector3.new(-117.5, 6.8, 41.2), altPositions = {Vector3.new(-117.5, 6.8, 41.2), Vector3.new(-200.7, 11.1, 35.9)}},
    {cnName = "技能升级师 · 曾天国 (Skill Upgrades)", internalName = "Skill Upgrades", desc = "技能升级 (辐射岛 [3] 曾天国 · 消耗精华 Essences 强化技能)", aliases = {"曾天国", "技能升级", "Skill Upgrades", "Skill Upgrade", "SkillUpgrades", "UpgradeSkill", "Tăng Thiên Quốc", "Tang Thien Quoc", "Zeng Tian Guo", "Sheng Tian Guo"}, fallbackPos = Vector3.new(65.5, 8.8, 1181.3), preferPos = Vector3.new(65.5, 8.8, 1181.3), altPositions = {Vector3.new(65.5, 8.8, 1181.3), Vector3.new(138.4, 9.0, 1179.7), Vector3.new(-200.7, 11.1, 35.9)}},
    {cnName = "世界表弟 (Biao Di)", internalName = "Biao Di", desc = "主线 任务 对话 (鱼竿商店 / 神话竿合成 / 世界钓鱼岛主线)", aliases = {"Biao Di", "BiaoDi", "Biểu Đệ", "Bieu De", "Rod Seller", "RodDealer", "比奥迪", "表弟", "标迪"}, fallbackPos = Vector3.new(-151.4, 8.7, -49.9), altPositions = {Vector3.new(-151.4, 8.7, -49.9), Vector3.new(-2404.5, 7.6, -202.4)}},
    {cnName = "天气岛楚新 (Chu Xin)", internalName = "Chu Xin", desc = "主线任务 (天气之岛/起始岛码头 出售并生成船只 Spawn Boat)", aliases = {"Chu Xin", "ChuXin", "Sở Tân", "So Tan", "Boat Seller", "Spawn Boat", "楚新", "楚Xin", "生成船只"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9), altPositions = {Vector3.new(-200.7, 11.1, 35.9), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "楚无双 / 表哥 (Biao Ge)", internalName = "Biao Ge", desc = "设出生点 主线 宝珠任务 (记录当前岛屿重生点 Set Spawn)", aliases = {"Biao Ge", "Chu Wu Shuang", "Biểu Ca", "Bieu Ca", "Set Spawn", "SpawnPoint", "楚无双", "表哥", "重生点"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "娜娜 (Nana)", internalName = "Nana", desc = "卖鱼商人 (各岛收购鱼类换取 Cash 核心经济)", aliases = {"Nana", "Fish Buyer", "SellNPC", "娜娜", "卖鱼"}, fallbackPos = Vector3.new(-203.5, 7.3, 107.1)},
    {cnName = "八长 (Ba Chang)", internalName = "Ba Chang", desc = "鱼饵商人 (出售 Luck 鱼饵与制作彩虹/冰霜神话鱼饵)", aliases = {"Ba Chang", "Bai Chang", "Bá Trường", "Ba Truong", "Bait Seller", "八长", "鱼饵"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9), altPositions = {Vector3.new(-200.7, 11.1, 35.9), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "升天国 / 夏钓帝 (Ha Dieu De)", internalName = "Ha Dieu De", desc = "任务 技能升级 (冰霜岛 [6] 斩天门V3 Sever The Gate v3 任务)", aliases = {"Ha Dieu De", "Hạ Điếu Đế", "Sheng Tian Guo", "Sever The Gate", "Gate v3", "Xia Diaodi", "夏钓帝", "升天国", "曾天国"}, fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4), preferPos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {cnName = "北冥 (Bac Minh)", internalName = "Bac Minh", desc = "买技能 任务 主线 (椰子岛 [7] 北冥宝珠 Bac Minh Orb 主线)", aliases = {"Bac Minh", "Bei Ming", "BacMinh", "BeiMing", "Bắc Minh", "北冥"}, fallbackPos = Vector3.new(1493.6, 9.1, -1430.6), preferPos = Vector3.new(1493.6, 9.1, -1430.6)},
    {cnName = "断杆 (Dawan Gan / Duan Gan)", internalName = "Dawan Gan", desc = "公会 创造公会 主线 (战场岛/雾峰岛 登仙十钓/破天四技能)", aliases = {"Dawan Gan", "Duan Gan", "DuanGan", "Doan Can", "Đoạn Cần", "Guild", "断杆", "断竿"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7)}},
    {cnName = "战场岛楚依旧 · 智者伊杰尤 (Sage Yijiu)", internalName = "Sage Yijiu", desc = "买技能 任务 (战场岛 [9] 5阶段终极主线: 钻石竿→一钩霸主)", aliases = {"智者伊杰尤", "伊杰尤", "Sage Yijiu", "Sage Yiju", "Chu Yijiu", "Sage Eiju", "Yijiu", "Yiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "失明的大钓鱼人 (Blind Grand Angler)", internalName = "Blind Grand Angler", desc = "任务 对话 (战场岛 [9] 星辰大钓术·极 Astral Grand Art Zenith)", aliases = {"Blind Grand Angler", "Grand Angler", "BlindAngler", "Blind", "失明", "大钓鱼人", "盲眼", "Ngư Phủ Mù", "Ngu Phu Mu", "Thợ Câu Cá Mù", "Tho Cau Ca Mu"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "竹岛江老 (Giang Lao)", internalName = "Giang Lao", desc = "任务 对话 (竹岛 [2] 无影太极击 Shadowless Taji + 神圣竹竿)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), preferPos = Vector3.new(-1223.0, 7.3, -24.1)},
    {cnName = "战场岛江老 (Giang Lao BF)", internalName = "Giang Lao BF", desc = "主线任务 (战场岛 [9] 升仙太极术 Ascended Taji Art 任务)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "老江 (Old Jiang)", internalName = "Old Jiang", desc = "普通升级任务 (竹岛/主权岛 经验与等级提升支线)", aliases = {"Old Jiang", "Giang Lao", "Jiang Lao", "Lão Giang", "老江", "江老"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), altPositions = {Vector3.new(-1223.0, 7.3, -24.1), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "钓科威 / 老吴 (Lao Ngo)", internalName = "Lao Ngo", desc = "主线任务 (战场岛/天气岛 碎心斩V2 Heartbreaker Cleave V2 任务)", aliases = {"Lao Ngo", "Diao Ke Wei", "Lao Wu", "Lão Ngô", "Heartbreaker", "钓科威", "迪奥·克维", "迪奥", "老吴"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "暗影 (The Shadow)", internalName = "The Shadow", desc = "升级角色 (起始岛瀑布后秘密洞穴 · 献祭资源突破角色等级)", aliases = {"The Shadow", "Shadow", "An Ying", "Dark", "Upgrade Character", "暗影", "升级角色", "Ám Ảnh", "Am Anh", "Bóng Tối", "Bong Toi"}, fallbackPos = Vector3.new(-8.4, 53.9, 6.7), preferPos = Vector3.new(-8.4, 53.9, 6.7)},
    {cnName = "少林 / 花和尚 (Shaolin)", internalName = "Shaolin", desc = "购买 (少林钓法 / 降龙伏虎 / 如来神掌 武学技能)", aliases = {"Shaolin", "Monk", "Flower Monk", "Thieu Lam", "Hoa Thuong", "Hòa Thượng", "Buddha", "Tathagata", "Dragon Subjugation", "少林", "花和尚"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "五指钓王 (Five Finger King)", internalName = "Five Finger King", desc = "主线任务(天气鱼) (琥珀岛/雾峰岛 提交指定天气稀有鱼)", aliases = {"Five Finger", "Wu Zhi", "Weather King", "Finger", "Ngu Chi", "Ngũ Chỉ", "World Angler", "五指钓王", "五指", "卢奥亚之王"}, fallbackPos = Vector3.new(1259.4, 9.1, 1401.5), altPositions = {Vector3.new(1259.4, 9.1, 1401.5), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "史星钓 / 石克翔 (Shi Xing Diao)", internalName = "Shi Xing Diao", desc = "主线任务 (雾峰岛/珊瑚礁岛 高阶钓鱼人主线任务挑战)", aliases = {"Shi Xing Diao", "ShiXingDiao", "石克翔", "史星钓", "石星之骄", "World Angler", "Star Angler", "Sử Tinh Điếu", "Su Tinh Dieu"}, fallbackPos = Vector3.new(2660.2, 8.8, -86.7), altPositions = {Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "楚天骄 (Chu Tian Jiao)", internalName = "Chu Tian Jiao", desc = "主线任务 (战场岛/雾峰岛/珊瑚礁岛 天骄专属进阶试炼任务)", aliases = {"Chu Tian Jiao", "ChuTianJiao", "Tian Jiao", "Thien Kieu", "Sở Thiên Kiêu", "Pride", "Celestial", "楚天骄", "楚天之骄"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1259.4, 9.1, 1401.5)}},
    {cnName = "亚索 (Yasuo)", internalName = "Yasuo", desc = "主线任务 (鲈鱼岛/珊瑚礁岛/战场岛 疾风剑豪斩风钓法全套技能)", aliases = {"Yasuo", "Yaxuo", "Wind", "Swordsman", "Wanderer", "Ronin", "Chem Gio", "Chém Gió", "Triple Cut", "亚索"}, fallbackPos = Vector3.new(-62.0, 11.9, -1321.4), altPositions = {Vector3.new(-62.0, 11.9, -1321.4), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7)}},
    {cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", liveKey = "Taoist", desc = "流动商人 (100M道士珠 / 200M极鹰猎 / 接取「三个神灵」任务)", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi", "XiaoDaoshi", "Tieu Dao Si", "TieuDaoSi", "Tiểu Đạo Sĩ", "Đạo Sĩ", "Dao Si", "Little Taoist", "道士", "小道士"}, fallbackPos = nil},
    {cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", liveKey = "Maoshan", desc = "流动商人 (300M茅山竿 / 200M茅山珠 / 200M镇江技能)", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan", "Mao Son", "MaoSon", "Mao Sơn", "Dai Su Huynh", "DaiSuHuynh", "Đại Sư Huynh", "茅山", "大师兄"}, fallbackPos = nil},
    {cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", liveKey = "DumbGuy", desc = "轮换隐藏商人 (六脉神鹰 Six Vein Divine Hawk / 道士商店卡)", aliases = {"Dumb Guy", "Dumb Man", "Dumb", "Thang Ngu", "ThangNgu", "Thằng Ngu", "Thằng Ngốc", "Thang Ngoc", "傻子", "笨蛋"}, fallbackPos = nil},
}
local ThreeSpiritsSpecs = {
    {
        liveKey = "Spirit_Bamboo",
        cnName = "神灵 #1 · 竹岛神灵 (Bamboo Isle)",
        internalName = "Spirit_Bamboo",
        islandName = "[2] 竹岛",
        desc = "竹岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得竹岛神灵祝福)",
        aliases = {"Spirit_Bamboo", "Bamboo Spirit", "Green Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "Ban Tho", "Cau Nguyen", "Mieu", "神灵", "竹岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1223.0, 7.3, -24.1),
        preferPos = Vector3.new(-1223.0, 7.3, -24.1),
    },
    {
        liveKey = "Spirit_Frost",
        cnName = "神灵 #2 · 冰霜岛神灵 (Frost Isle)",
        internalName = "Spirit_Frost",
        islandName = "[6] 冰霜岛",
        desc = "冰霜岛祭坛 · 每次祈祷花费 50M Cash (20%概率获得霜岛神灵祝福)",
        aliases = {"Spirit_Frost", "Frost Spirit", "Blue Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "Ban Tho", "Cau Nguyen", "Mieu", "神灵", "冰霜神灵", "冰霜岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(-1366.0, 11.9, -1495.4),
        preferPos = Vector3.new(-1366.0, 11.9, -1495.4),
    },
    {
        liveKey = "Spirit_Amber",
        cnName = "神灵 #3 · 琥珀岛神灵 (Amber Isle)",
        internalName = "Spirit_Amber",
        islandName = "[8] 琥珀岛",
        desc = "琥珀岛祭坛 · 每次祈祷花费 50M Cash (集齐三岛祝福解锁幻影灯笼鱼克制技)",
        aliases = {"Spirit_Amber", "Amber Spirit", "Yellow Spirit", "Spirit", "God", "GodSpirit", "Spirits", "Shrine", "Altar", "Pray", "Tinh Linh", "Thần Linh", "Than Linh", "Miếu", "Bàn Thờ", "Cầu Nguyện", "Ban Tho", "Cau Nguyen", "Mieu", "神灵", "琥珀神灵", "琥珀岛神灵", "祭坛", "祈祷"},
        fallbackPos = Vector3.new(1259.4, 9.1, 1401.5),
        preferPos = Vector3.new(1259.4, 9.1, 1401.5),
    },
}
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
        table.insert(bSpec.lowerAliases, tqLc(al))
    end
end
local TicketQuestNPCSpec = ImportantDialogueNPCs[1]
local npcTextSummaryCache = setmetatable({}, { __mode = "k" })
local function GetCompiledSpecKeywords(spec)
    if spec._compiledKeywords then return spec._compiledKeywords end
    local kwList = {}
    local seenKw = {}
    local function addKw(s)
        if not s or s == "" then return end
        local low = tqLc(s)
        if low ~= "" and not seenKw[low] then
            seenKw[low] = true
            table.insert(kwList, low)
        end
    end
    addKw(spec.internalName)
    if spec.cnName then
        local pureCn = spec.cnName:match("^([^%(%s/]+)")
        if pureCn and #pureCn >= 2 and not pureCn:find("\240", 1, true) then addKw(pureCn) end
    end
    if spec.aliases then
        for i = 1, #spec.aliases do addKw(spec.aliases[i]) end
    end
    spec._compiledKeywords = kwList
    return kwList
end
local lowerNameRaw = setmetatable({}, { __mode = "k" })
local lowerNameVal = setmetatable({}, { __mode = "k" })
local function LowerInstName(inst)
    if not inst then return "" end
    local raw = inst.Name
    if lowerNameRaw[inst] == raw then return lowerNameVal[inst] end
    local low = tqLc(raw or "")
    lowerNameRaw[inst] = raw
    lowerNameVal[inst] = low
    return low
end
LowerInstNameG = LowerInstName
IsMapOrIslandContainer = function(inst)
    if not inst or inst == Workspace then return true end
    local nLow = LowerInstName(inst)
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
    if nLow:find("đảo", 1, true) or nLow:find("岛", 1, true) then
        return true
    end
    return false
end
ResolvePromptEntity = function(pr)
    if not pr or not pr.Parent then return nil end
    local cur = pr.Parent
    local bestModel = nil
    local bestPart = nil
    local depth = 0
    while cur and cur ~= Workspace and depth < 6 do
        if IsMapOrIslandContainer(cur) then
            break
        end
        if cur:IsA("BasePart") and not bestPart then
            bestPart = cur
        elseif cur:IsA("Model") then
            bestModel = cur
            if cur:FindFirstChildOfClass("Humanoid") or cur.PrimaryPart then
                break
            end
        end
        cur = cur.Parent
        depth = depth + 1
    end
    return bestModel or bestPart or pr.Parent
end
GetInstanceSearchableSummary = function(inst)
    if not inst then return "" end
    if inst:IsA("BasePart") and #inst:GetChildren() == 0 then
        return LowerInstName(inst)
    end
    if IsMapOrIslandContainer(inst) and #inst:GetChildren() > 60 then
        return LowerInstName(inst)
    end
    local now = tick()
    local cached = npcTextSummaryCache[inst]
    if cached and cached.name == inst.Name and (now - cached.time) < 0.5 then
        return cached.summary
    end
    local descendants = inst:GetDescendants()
    local descCount = #descendants
    if cached and cached.name == inst.Name and cached.descCount == descCount then
        local ttl = cached.hasExtra and 180.0 or 2.5
        if (now - cached.time) < ttl then
            return cached.summary
        end
    end
    local parts = { tqLc(inst.Name or "") }
    if inst.Parent and not IsMapOrIslandContainer(inst.Parent) then
        table.insert(parts, tqLc(inst.Parent.Name or ""))
    end
    local hum = inst:FindFirstChildOfClass("Humanoid")
    if hum and hum.DisplayName and hum.DisplayName ~= "" then
        table.insert(parts, tqLc(hum.DisplayName))
    end
    for i = 1, descCount do
        local sub = descendants[i]
        if sub:IsA("ProximityPrompt") then
            if sub.Name and sub.Name ~= "ProximityPrompt" then table.insert(parts, tqLc(sub.Name)) end
            if sub.ObjectText and sub.ObjectText ~= "" then table.insert(parts, tqLc(sub.ObjectText)) end
            if sub.ActionText and sub.ActionText ~= "" then table.insert(parts, tqLc(sub.ActionText)) end
        elseif sub:IsA("TextLabel") or sub:IsA("TextButton") then
            local rawTxt = sub.Text
            if rawTxt and rawTxt ~= "" and #rawTxt <= 240 then
                local cleanTxt = tqLc(rawTxt:gsub("<[^>]+>", ""))
                if cleanTxt ~= "" then table.insert(parts, cleanTxt) end
            end
            local okLoc, locTxt = pcall(function() return sub.LocalizedText or sub.ContentText end)
            if okLoc and type(locTxt) == "string" and locTxt ~= "" and locTxt ~= rawTxt and #locTxt <= 240 then
                local cleanLoc = tqLc(locTxt:gsub("<[^>]+>", ""))
                if cleanLoc ~= "" then table.insert(parts, cleanLoc) end
            end
        elseif sub:IsA("StringValue") and type(sub.Value) == "string" and sub.Value ~= "" and #sub.Value <= 100 then
            table.insert(parts, tqLc(sub.Value))
        elseif (sub:IsA("Model") or sub:IsA("BillboardGui")) and sub.Name and sub.Name ~= "" then
            table.insert(parts, tqLc(sub.Name))
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
local specMatchCache = setmetatable({}, { __mode = "k" })
local _DoesInstanceMatchNPCSpecInner
DoesInstanceMatchNPCSpec = function(inst, spec)
    if not inst or not spec or inst == LocalPlayer.Character then return false end
    local specKey = spec.internalName or spec.name or "?"
    local bucket = specMatchCache[inst]
    local nowT = tick()
    if bucket and bucket.name == inst.Name and (nowT - bucket.t) < 0.7 then
        local hitv = bucket[specKey]
        if hitv ~= nil then return hitv end
    else
        bucket = { name = inst.Name, t = nowT }
        specMatchCache[inst] = bucket
    end
    local result = _DoesInstanceMatchNPCSpecInner(inst, spec)
    bucket[specKey] = result
    return result
end
_DoesInstanceMatchNPCSpecInner = function(inst, spec)
    if inst:IsA("Model") then
        local okPlr, plr = pcall(function() return Players:GetPlayerFromCharacter(inst) end)
        if okPlr and plr then return false end
    end
    local kwList = GetCompiledSpecKeywords(spec)
    local nLow = LowerInstName(inst)
    local nLen = #nLow
    for i = 1, #kwList do
        local kw = kwList[i]
        if #kw <= nLen and (nLow == kw or nLow:find(kw, 1, true)) then
            return true
        end
    end
    if inst:IsA("BasePart") and #inst:GetChildren() == 0 then
        return false
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
            enabled = (pr.Enabled ~= false),
        }
        originalPromptState[pr] = state
        return state
    end
    local function RestoreSinglePrompt(pr, forcePulseHide, wasEnabled)
        if not pr or not pr.Parent then return end
        local orig = RememberPromptState(pr)
        currentlyTriggeringPrompts[pr] = nil
        pcall(function()
            pr.MaxActivationDistance = orig.dist
            pr.RequiresLineOfSight = orig.los
            pr.HoldDuration = orig.hold
            if wasEnabled ~= nil then pr.Enabled = wasEnabled end
            if forcePulseHide then
                if not isRunning then
                    pr.Enabled = (orig.enabled ~= false)
                else
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
            end
        end)
    end
    DismissStuckPromptsAndRestore = function(forceScanAll)
        if not isRunning then
            table.clear(currentlyTriggeringPrompts)
        end
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
                    local sliceAt = os.clock()
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
                        if (i % 200 == 0) or (os.clock() - sliceAt >= 0.004) then
                            task.wait()
                            sliceAt = os.clock()
                        end
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
            end
            if cachedBossPromptsSet[d] then
                cachedBossPromptsSet[d] = nil
            end
        end
    end))
    GetCachedWorkspacePrompts = function()
        local w = 0
        for r = 1, #cachedAllPrompts do
            local pr = cachedAllPrompts[r]
            if pr and pr.Parent and cachedAllPromptsSet[pr] then
                w = w + 1
                cachedAllPrompts[w] = pr
            elseif pr then
                cachedAllPromptsSet[pr] = nil
            end
        end
        for r = #cachedAllPrompts, w + 1, -1 do
            cachedAllPrompts[r] = nil
        end
        local bw = 0
        for r = 1, #cachedBossPrompts do
            local bpr = cachedBossPrompts[r]
            if bpr and bpr.Parent and cachedBossPromptsSet[bpr] then
                bw = bw + 1
                cachedBossPrompts[bw] = bpr
            elseif bpr then
                cachedBossPromptsSet[bpr] = nil
            end
        end
        for r = #cachedBossPrompts, bw + 1, -1 do
            cachedBossPrompts[r] = nil
        end
        local now = tick()
        if #cachedAllPrompts == 0 and (lastAllPromptsScan == 0 or (now - lastAllPromptsScan) >= 10.0) then
            lastAllPromptsScan = now
            for _, folderName in ipairs(FSYC.NPC_SCAN_CONTAINER_NAMES) do
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
            for _, mapName in ipairs(MAP_ROOT_NAMES) do
                local mf = Workspace:FindFirstChild(mapName)
                if mf then
                    for _, d in ipairs(mf:GetDescendants()) do
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
        local restoreQueue = {}
        for _, pr in ipairs(prompts) do
            if pr and pr.Parent then
                local orig = RememberPromptState(pr)
                local wasEnabled = (pr.Enabled ~= false)
                local firedThis = false
                currentlyTriggeringPrompts[pr] = true
                hasPollutedPrompts = true
                pcall(function()
                    pr.Enabled = true
                    pr.RequiresLineOfSight = false
                    pr.MaxActivationDistance = 999999
                    pr.HoldDuration = 0
                end)
                if type(fireproximityprompt) == "function" then
                    local okFire = pcall(fireproximityprompt, pr)
                    if okFire then firedThis = true; triggered = true end
                end
                if not firedThis then
                    pcall(function()
                        activePromptTasks[pr] = true
                        pr:InputHoldBegin()
                        task.delay(0.04, function()
                            activePromptTasks[pr] = nil
                            if pr and pr.Parent then
                                pcall(function() pr:InputHoldEnd() end)
                            end
                        end)
                    end)
                    triggered = true
                end
                restoreQueue[#restoreQueue + 1] = { pr = pr, orig = orig, wasEnabled = wasEnabled }
            end
        end
        if #restoreQueue > 0 then
            task.delay(0.14, function()
                local char = LocalPlayer.Character
                local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
                for i = 1, #restoreQueue do
                    local e = restoreQueue[i]
                    local pr = e.pr
                    if pr and pr.Parent then
                        pcall(function()
                            local pPos = GetNPCPosition(pr)
                            local isFar = (not myPos or not pPos) or ((myPos - pPos).Magnitude > (e.orig.dist + 4))
                            RestoreSinglePrompt(pr, isFar, e.wasEnabled)
                        end)
                    end
                end
            end)
        end
        return triggered
    end
end
local npcScanCache = setmetatable({}, { __mode = "k" })
local function IsPositionNearNPCSpec(spec, p)
    if not p or not spec then return false end
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
    if spec.liveKey and liveNPCs[spec.liveKey] and liveNPCs[spec.liveKey].inst and liveNPCs[spec.liveKey].inst.Parent then
        local cachedInst = liveNPCs[spec.liveKey].inst
        local cPos = liveNPCs[spec.liveKey].pos or GetNPCPosition(cachedInst)
        if IsPositionNearNPCSpec(spec, cPos) then
            seen[cachedInst] = true
            table.insert(results, cachedInst)
        end
    end
    if spec.internalName and OnlineNPCs[spec.internalName] then
        local cached = OnlineNPCs[spec.internalName]
        if cached.instance and cached.instance.Parent and not seen[cached.instance] then
            local cPos = cached.pos or GetNPCPosition(cached.instance)
            if IsPositionNearNPCSpec(spec, cPos) then
                seen[cached.instance] = true
                table.insert(results, cached.instance)
            end
        end
    end
    local searchContainers = {}
    for _, folderName in ipairs(FSYC.NPC_SCAN_CONTAINER_NAMES) do
        local f = Workspace:FindFirstChild(folderName)
        if f then table.insert(searchContainers, f) end
    end
    for _, mapName in ipairs(MAP_ROOT_NAMES) do
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
            local nPos = GetNPCPosition(inst)
            if IsPositionNearNPCSpec(spec, nPos) then
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
    if #results == 0 then
        local allPrompts = GetCachedWorkspacePrompts()
        local kwList = GetCompiledSpecKeywords(spec)
        for i = 1, #allPrompts do
            local d = allPrompts[i]
            if d and d.Parent then
                local entity = ResolvePromptEntity(d)
                local prText = tqLc((d.ObjectText or "") .. " | " .. (d.ActionText or "") .. " | " .. (d.Name or ""))
                local prMatched = false
                for kIdx = 1, #kwList do
                    if prText:find(kwList[kIdx], 1, true) then
                        prMatched = true
                        break
                    end
                end
                if entity and not seen[entity] and (prMatched or DoesInstanceMatchNPCSpec(entity, spec) or DoesInstanceMatchNPCSpec(d.Parent, spec)) then
                    local pPos = GetNPCPosition(entity) or GetNPCPosition(d)
                    if IsPositionNearNPCSpec(spec, pPos) then
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
                local gName = LowerInstName(gui)
                if gName:find("dialogue", 1, true) or gName:find("dialog", 1, true) or gName:find("talk", 1, true) or gName:find("npc", 1, true) or gName:find("chat", 1, true)
                    or gName:find("对话", 1, true) or gName:find("交谈", 1, true)
                    or gName:find("thoại", 1, true) or gName:find("hoi thoai", 1, true)
                    or gName:find("tro chuyen", 1, true) or gName:find("trò chuyện", 1, true) then
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
                            local cn = LowerInstName(topChild)
                            if cn:find("dialogue", 1, true) or cn:find("dialog", 1, true) or cn:find("talk", 1, true) or cn:find("npc", 1, true) or cn:find("chat", 1, true) or cn:find("interact", 1, true)
                                or cn:find("thoại", 1, true) or cn:find("nhiệm vụ", 1, true) or cn:find("hộp", 1, true)
                                or cn:find("对话", 1, true) or cn:find("交谈", 1, true) or cn:find("选择", 1, true)
                                or cn:find("hoi thoai", 1, true) or cn:find("tro chuyen", 1, true) or cn:find("lua chon", 1, true)
                                or cn:find("trò chuyện", 1, true) or cn:find("lựa chọn", 1, true) then
                                for _, d in ipairs(topChild:GetDescendants()) do
                                    if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 20 then
                                        local t = ""
                                        if d:IsA("TextButton") then
                                            t = tqLc(d.Text or "")
                                            if t == "" then
                                                local l0 = d:FindFirstChildWhichIsA("TextLabel", true)
                                                if l0 then t = tqLc(l0.Text or "") end
                                            end
                                        else
                                            local l0 = d:FindFirstChildWhichIsA("TextLabel", true)
                                            if l0 then t = tqLc(l0.Text or "") end
                                        end
                                        if t:find("没关系", 1, true) or t:find("主线", 1, true) or t:find("任务", 1, true) or t:find("对话", 1, true)
                                            or t:find("离开", 1, true) or t:find("退出", 1, true) or t:find("再见", 1, true)
                                            or t:find("leave", 1, true) or t:find("close", 1, true) or t:find("exit", 1, true)
                                            or t:find("rời", 1, true) or t:find("thoát", 1, true) or t:find("đóng", 1, true)
                                            or t:find("nhiệm vụ", 1, true)
                                            or t:find("nevermind", 1, true) or t:find("cancel", 1, true) or t:find("goodbye", 1, true)
                                            or t:find("accept", 1, true) or t:find("quest", 1, true) or t:find("shop", 1, true)
                                            or t:find("easy", 1, true) or t:find("hard", 1, true) or t:find("简单", 1, true) or t:find("困难", 1, true)
                                            or t:find("dong y", 1, true) or t:find("tu choi", 1, true) or t:find("tiep tuc", 1, true) or t:find("roi di", 1, true)
                                            or t:find("选择", 1, true) or t:find("继续", 1, true) or t:find("接受", 1, true) or t:find("拒绝", 1, true)
                                            or t:find("đồng ý", 1, true) or t:find("từ chối", 1, true) or t:find("tiếp tục", 1, true) then
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
local dialogueBtnCache = { time = 0, list = nil }
local function AutoClickDialogueOption(preferredKeywords, allowInactive)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end
    local now = tick()
    local wantExit = false
    for _, k in ipairs(preferredKeywords or {}) do
        local kl = tqLc(tostring(k))
        if kl == "离开" or kl == "关闭" or kl == "退出" or kl == "取消" or kl == "leave" or kl == "close" or kl == "exit" or kl == "rời đi" or kl == "đóng" or kl == "thoát" then
            wantExit = true
            break
        end
    end
    local cacheTtl = wantExit and 0.12 or 0.5
    local candidates
    if dialogueBtnCache.list and (now - dialogueBtnCache.time) < cacheTtl then
        candidates = {}
        for _, c in ipairs(dialogueBtnCache.list) do
            if c.btn and c.btn.Parent and c.btn.Visible and (allowInactive or c.btn.Active) then
                local sg = c.btn:FindFirstAncestorOfClass("ScreenGui")
                local liveTxt = c.txt
                if c.btn:IsA("TextButton") then
                    liveTxt = tqLc(c.btn.Text or ""):match("^%s*(.-)%s*$")
                    if liveTxt == "" then
                        local l0 = c.btn:FindFirstChildWhichIsA("TextLabel", true)
                        if l0 then liveTxt = tqLc(l0.Text or ""):match("^%s*(.-)%s*$") end
                    end
                else
                    local l0 = c.btn:FindFirstChildWhichIsA("TextLabel", true)
                    if l0 then liveTxt = tqLc(l0.Text or ""):match("^%s*(.-)%s*$") end
                end
                if (not sg or sg.Enabled) and liveTxt == c.txt then
                    table.insert(candidates, c)
                end
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
                    or gn:find("对话") or gn:find("任务") or gn:find("交谈") or gn:find("选项")
                    or gn:find("npc") or gn:find("chat") or gn:find("quest") then
                    table.insert(priorityGuis, gui)
                elseif gn == "maingui" or gn == "fisher_gui" then
                    for _, ch in ipairs(gui:GetChildren()) do
                        if ch:IsA("GuiObject") and ch.Visible then
                            local cn = ch.Name:lower()
                            if cn:find("dialog") or cn:find("dialogue") or cn:find("talk")
                                or cn:find("对话") or cn:find("任务") or cn:find("交谈") or cn:find("选项")
                                or cn:find("npc") or cn:find("chat") or cn:find("quest")
                                or cn:find("modal") or cn:find("popup") or cn:find("prompt") then
                                table.insert(priorityGuis, ch)
                            end
                        end
                    end
                else
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
        local function reallyVisible(b)
            local n, guard = b, 0
            while n and n ~= pg and guard < 12 do
                if n:IsA("GuiObject") and not n.Visible then return false end
                if n:IsA("ScreenGui") and not n.Enabled then return false end
                n = n.Parent
                guard = guard + 1
            end
            return true
        end
        local function collectFromGuis(guiList)
            for _, gui in ipairs(guiList) do
                for _, d in ipairs(gui:GetDescendants()) do
if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 10 and (allowInactive or d.Active) and reallyVisible(d) then
                        local txt = ""
                        if d:IsA("TextButton") then
                            txt = tqLc(d.Text or ""):match("^%s*(.-)%s*$")
                            if txt == "" then
                                local lbl2 = d:FindFirstChildWhichIsA("TextLabel", true)
                                if lbl2 then txt = tqLc(lbl2.Text or ""):match("^%s*(.-)%s*$") end
                            end
                        else
                            local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                            if lbl then txt = tqLc(lbl.Text or ""):match("^%s*(.-)%s*$") end
                        end
                        local bName = tqLc(d.Name or ""):match("^%s*(.-)%s*$")
                        table.insert(candidates, { btn = d, txt = txt, bName = bName })
                    end
                end
            end
        end
        collectFromGuis(orderedGuis)
        if wantExit and #fallbackGuis > 0 then
            collectFromGuis(fallbackGuis)
        end
        if #candidates == 0 and #priorityGuis > 0 then
            collectFromGuis(fallbackGuis)
        end
        dialogueBtnCache.time = now
        dialogueBtnCache.list = candidates
    end
    for _, kw in ipairs(preferredKeywords) do
        local kwLow = tqLc(kw)
        for _, c in ipairs(candidates) do
            if c.txt == kwLow then
                if FireGuiButton(c.btn, allowInactive) then
                    dialogueBtnCache.list = nil dialogueBtnCache.time = 0
                    return true
                end
            end
        end
    end
    for _, kw in ipairs(preferredKeywords) do
        local kwLow = tqLc(kw)
        for _, c in ipairs(candidates) do
            if c.bName == kwLow then
                if FireGuiButton(c.btn, allowInactive) then
                    dialogueBtnCache.list = nil dialogueBtnCache.time = 0
                    return true
                end
            end
        end
    end
    for _, kw in ipairs(preferredKeywords) do
        local kwLow = tqLc(kw)
        for _, c in ipairs(candidates) do
            if (c.txt ~= "" and c.txt:find(kwLow, 1, true)) or (c.bName ~= "" and c.bName:find(kwLow, 1, true)) then
                if FireGuiButton(c.btn, allowInactive) then
                    dialogueBtnCache.list = nil dialogueBtnCache.time = 0
                    return true
                end
            end
        end
    end
    return false
end
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
    local targetPos = nil
    local primaryPos = primaryInst and GetNPCPosition(primaryInst) or nil
    if primaryPos and IsPositionNearNPCSpec(spec, primaryPos) then
        targetPos = primaryPos
    elseif liveEntry and IsPositionNearNPCSpec(spec, liveEntry.pos) then
        targetPos = liveEntry.pos
    elseif cachedRadar and IsPositionNearNPCSpec(spec, cachedRadar.pos) then
        targetPos = cachedRadar.pos
    else
        targetPos = spec.preferPos or spec.fallbackPos
    end
    if not targetPos then
        ShowNotification("传送提示", string.format("当前服务器暂未检测到 [%s] 刷新。", spec.cnName or internalName), "WARN", 4)
        return false
    end
    TryStreamAroundPosition(targetPos)
    local standPos = targetPos + Vector3.new(0, 2.6, 3.5)
    if not SafeTeleport(CFrame.new(standPos, Vector3.new(targetPos.X, standPos.Y, targetPos.Z))) then
        ShowNotification("NPC 传送", "本地角色尚未就绪，传送失败，请稍后重试。", "ERROR", 3)
        return false
    end
    ShowNotification("NPC 传送", "正在前往: " .. tostring(spec.cnName or internalName), "SUCCESS", 3)
    task.spawn(function()
        HRandomWait(0.28, 0.35)
        pcall(function()
            local loadedList = FindNPCInstancesBySpec(spec, true)
            if #loadedList > 0 then
                local exactPos = GetNPCPosition(loadedList[1])
                if exactPos and IsPositionNearNPCSpec(spec, exactPos) then
                    OnlineNPCs[internalName] = { instance = loadedList[1], pos = exactPos, time = tick() }
                    local exactStand = exactPos + Vector3.new(0, 2.6, 3.5)
                    SafeTeleport(CFrame.new(exactStand, Vector3.new(exactPos.X, exactStand.Y, exactPos.Z)))
                end
            end
        end)
    end)
    return true
end
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
    local primaryInst = npcInstances[1]
    if not primaryInst and liveEntry and liveEntry.inst and liveEntry.inst.Parent and IsPositionNearNPCSpec(spec, liveEntry.pos or GetNPCPosition(liveEntry.inst)) then
        primaryInst = liveEntry.inst
    end
    if not primaryInst and cachedRadar and cachedRadar.instance and cachedRadar.instance.Parent and IsPositionNearNPCSpec(spec, cachedRadar.pos or GetNPCPosition(cachedRadar.instance)) then
        primaryInst = cachedRadar.instance
    end
    local targetPos = nil
    local primaryPos = primaryInst and GetNPCPosition(primaryInst) or nil
    if primaryPos and IsPositionNearNPCSpec(spec, primaryPos) then
        targetPos = primaryPos
    elseif liveEntry and IsPositionNearNPCSpec(spec, liveEntry.pos) then
        targetPos = liveEntry.pos
    elseif cachedRadar and IsPositionNearNPCSpec(spec, cachedRadar.pos) then
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
        local tBeforeDirect = tick()
        local directTried = false
        if primaryInst and primaryInst.Parent then
            if TriggerNPCInstancePrompts(primaryInst) then
                directTried = true
            end
        end
        if directTried then
            task.wait(0.28)
            if IsDialogueUIOpen(true) or ((FSYC.FSYDialogueOpenedAt or 0) > tBeforeDirect) then
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
        if not isMicroTeleportingNPC and not (FishGate and not FishGate.IsIdle()) then
            isMicroTeleportingNPC = true
            microTeleportLockAt = tick()
            local savedCF = root.CFrame
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
                    if not isRunning or (FishGate and not FishGate.IsIdle()) then break end
                    TryStreamAroundPosition(probePos)
                    root.CFrame = CFrame.new(probePos + Vector3.new(0, 3, 2))
                    root.AssemblyLinearVelocity = Vector3.zero
                    HRandomWait(0.32, 0.20)
                    local nearInstances = FindNPCInstancesBySpec(spec, true)
                    local nearTriggered = false
                    local tBeforePos = tick()
                    if #nearInstances > 0 then
                        local exactNPC = nearInstances[1]
                        local exactPos = GetNPCPosition(exactNPC)
                        if exactPos and IsPositionNearNPCSpec(spec, exactPos) then
                            OnlineNPCs[internalName] = { instance = exactNPC, pos = exactPos, time = tick() }
                            if (root.Position - exactPos).Magnitude > 8 then
                                root.CFrame = CFrame.new(exactPos + Vector3.new(0, 2.5, 2))
                                root.AssemblyLinearVelocity = Vector3.zero
                                HRandomWait(0.18, 0.20)
                            end
                        end
                        if TriggerNPCInstancePrompts(exactNPC) then
                            nearTriggered = true
                        end
                    end
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
                                    local prText = tqLc((d.ObjectText or "") .. " " .. (d.ActionText or "") .. " " .. (d.Name or ""))
                                    if not matchesSpec then
                                        for _, kw in ipairs(GetCompiledSpecKeywords(spec)) do
                                            if prText:find(kw, 1, true) then
                                                matchesSpec = true
                                                break
                                            end
                                        end
                                    end
                                    local mName = tqLc(model and model.Name or "")
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
                                HRandomWait(0.18, 0.20)
                            end
                            TriggerNPCInstancePrompts(bestPr)
                            nearTriggered = true
                        end
                    end
                    task.wait(0.25)
                    if IsDialogueUIOpen(true) or ((FSYC.FSYDialogueOpenedAt or 0) > tBeforePos) or nearTriggered then
                        break
                    end
                end
                if type(postDialogueCallback) == "function" then
                    pcall(postDialogueCallback)
                    HRandomWait(0.22, 0.45)
                end
            end)
            if root and root.Parent then
                local humNow = char and char:FindFirstChildOfClass("Humanoid")
                if humNow then DashUI._ensureHumanoidUpright(humNow) end
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                root.CFrame = DashUI._makeUprightCFrame(savedCF) or savedCF
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
            if type(postDialogueCallback) == "function" then
                FLogWarn("NPC对话", string.format("%s 的对话后回调因微瞬移锁占用被跳过", tostring(internalName)))
            end
            ShowNotification("角色", string.format("已发送 %s 对话请求。", internalName), "WARN", 3)
        end
    end)
    return true
end
local function createNPCDualActionRow(parent, labelText, descText, onTeleport, onDialogue)
    local btnW = UIM.touch and 80 or 62
    local btnH = UIM.touch and 34 or 26
    local row = createBaseRow(parent, labelText, descText, btnW * 2 + 20)
    local function styleBtn(btn, primary)
        btn.Size = UDim2.new(0, btnW, 0, btnH)
        btn.BackgroundColor3 = primary and Colors.Accent or Colors.ControlBg
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = primary and Colors.AccentDeep or Colors.TextSubtle
        btn.TextSize = 11
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Parent = row
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
        RegisterThemeUpdater(function()
            if primary then
                btn.BackgroundColor3 = Colors.Accent
                btn.TextColor3 = Colors.AccentDeep
            else
                btn.BackgroundColor3 = Colors.ControlBg
                btn.TextColor3 = Colors.TextSubtle
            end
        end)
        btn.MouseEnter:Connect(function()
            if UIM.touch then return end
            PlayQuickTween(btn, { BackgroundColor3 = primary and Colors.AccentSoft or Colors.RowHover })
        end)
        btn.MouseLeave:Connect(function()
            if UIM.touch then return end
            PlayQuickTween(btn, { BackgroundColor3 = primary and Colors.Accent or Colors.ControlBg })
        end)
        btn.InputBegan:Connect(function(input)
            if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
                and ModeCtl.Accepts(input.UserInputType) then
                btn.BackgroundColor3 = primary and Colors.AccentDeep or Colors.ControlBg
            end
        end)
        btn.InputEnded:Connect(function(input)
            if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
                and ModeCtl.Accepts(input.UserInputType) then
                btn.BackgroundColor3 = primary and Colors.Accent or Colors.ControlBg
            end
        end)
    end
    local tpBtn = Instance.new("TextButton")
    tpBtn.Position = UDim2.new(1, -(btnW * 2 + 14), 0.5, -btnH / 2)
    tpBtn.Text = "传送"
    styleBtn(tpBtn, false)
    BindClick(tpBtn, function() if type(onTeleport) == "function" then pcall(onTeleport) end end)
    local dlgBtn = Instance.new("TextButton")
    dlgBtn.Position = UDim2.new(1, -btnW - 6, 0.5, -btnH / 2)
    dlgBtn.Text = "对话"
    styleBtn(dlgBtn, true)
    BindClick(dlgBtn, function() if type(onDialogue) == "function" then pcall(onDialogue) end end)
    return row
end
do
local godCard = createCollapsibleGroup(tabGod, "三个神灵 (50M 祈祷)")
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
        local y = DashUI._readValueBase(pData.GodSpirit:FindFirstChild("Yellow"), false) == true
        local b = DashUI._readValueBase(pData.GodSpirit:FindFirstChild("Blue"), false) == true
        local g = DashUI._readValueBase(pData.GodSpirit:FindFirstChild("Green"), false) == true
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
            if not spSpec.fallbackPos or (entry.pos - spSpec.fallbackPos).Magnitude <= 450 then
                OpenRemoteNPCDialogue(spSpec, false)
                return
            end
        end
    end
    local npcFolder = Workspace:FindFirstChild("NPC") or Workspace:FindFirstChild("NPCs")
    local sp = npcFolder and (npcFolder:FindFirstChild("Spirit") or npcFolder:FindFirstChild("God"))
    if sp then
        OpenRemoteNPCDialogue({cnName = "活跃神灵", internalName = sp.Name, aliases = {"Spirit", "God"}, fallbackPos = GetNPCPosition(sp)}, false)
    else
        ShowNotification("三个神灵", "当前服务器竹岛/冰霜岛/琥珀岛均未检测到活跃神灵（每小时整点刷新10分钟）。", "WARN", 5)
    end
end)
for _, spSpec in ipairs(ThreeSpiritsSpecs) do
    createNPCDualActionRow(godCard, spSpec.cnName, spSpec.desc, function()
        TeleportToNPCSpec(spSpec)
    end, function()
        OpenRemoteNPCDialogue(spSpec, false)
    end)
end
local roamGodCard = createCollapsibleGroup(tabGod, "流动商人任务接取", false)
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
local beastCard = createCollapsibleGroup(tabGod, "四圣兽 (特质 / Boss雷达)")
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
                        local vLow = tqLc(d.Value)
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
local hopCard = createCollapsibleGroup(tabGod, "服务器跳转引擎", false)
createToggleRow(hopCard, "为神灵跳服务器", "若当前服无神灵，自动跳服寻找", Config.AutoServerHopGod, function(v) Config.AutoServerHopGod = v end, "AutoServerHopGod")
createToggleRow(hopCard, "为茅山跳服务器", "若当前服无茅山，自动跳服寻找", Config.AutoServerHopMaoshan, function(v) Config.AutoServerHopMaoshan = v end, "AutoServerHopMaoshan")
createToggleRow(hopCard, "为道士跳服务器", "若当前服无道士，自动跳服寻找", Config.AutoServerHopTaoist, function(v) Config.AutoServerHopTaoist = v end, "AutoServerHopTaoist")
createButtonRow(hopCard, "立即跳服务器", "立即跳转到随机不同服务器", "跳转", function() ServerHop(true) end)
end
do (function()
local function IsTicketQuestStillRunning(pData)
    pData = pData or GetPlayerData()
    if not pData then return false end
    local quests = pData:FindFirstChild("Quest")
    local main = quests and quests:FindFirstChild("Main")
    if main then
        local function IsRunningTicketNode(qNode)
            if not qNode then return false end
            local progNode = qNode:FindFirstChild("1")
            local prog = (progNode and progNode:IsA("ValueBase") and tonumber(progNode.Value)) or 0
            local goal = 0
            local objFolder = qNode:FindFirstChild("Objective")
            if objFolder then
                for _, ch in ipairs(objFolder:GetChildren()) do
                    if ch:IsA("StringValue") and type(ch.Value) == "string" then
                        local gStr = ch.Value:match("^[^,]*,([^,]+)")
                        goal = tonumber(gStr or "") or 0
                        break
                    end
                end
            end
            return goal > 0 and prog > 0 and prog < goal
        end
        for _, qName in ipairs({
            "Hard Ticket Quest", "Easy Ticket Quest", "Ticket Quest",
            "Nhiệm Vụ Vé Khó", "Nhiệm Vụ Vé Dễ", "Nhiệm Vụ Vé",
            "Nhiem Vu Ve Kho", "Nhiem Vu Ve De", "Nhiem Vu Ve",
            "困难票据任务", "简单票据任务", "票据任务",
        }) do
            if IsRunningTicketNode(main:FindFirstChild(qName)) then return true end
        end
        for _, ch in ipairs(main:GetChildren()) do
            local n = tqLc(ch.Name or "")
            local hasTicketWord = n:find("ticket", 1, true) or n:find("vé", 1, true)
                or n:find("票据", 1, true) or n:find("票據", 1, true) or n:find("nhiem vu ve", 1, true)
            local hasQuestWord = n:find("quest", 1, true) or n:find("nhiệm vụ", 1, true)
                or n:find("nhiem vu", 1, true) or n:find("任务", 1, true) or n:find("任務", 1, true)
            if hasTicketWord and hasQuestWord and IsRunningTicketNode(ch) then return true end
        end
    end
    local qFolder = pData:FindFirstChild("TicketQuest") or pData:FindFirstChild("Quests")
    if qFolder then
        local prog = tonumber(DashUI._readValueBase(qFolder:FindFirstChild("Progress") or qFolder:FindFirstChild("Current"), 0)) or 0
        local goal = tonumber(DashUI._readValueBase(qFolder:FindFirstChild("Goal") or qFolder:FindFirstChild("Target"), 0)) or 0
        if goal > 0 and prog > 0 and prog < goal then
            return true
        end
    end
    return false
end
local FSYQD = {}
function FSYQD.GetState(maxAge)
    local st = FSYC.DialogueState
    if type(st) ~= "table" then return nil, "no_dialogue_state" end
    if type(st.id) ~= "string" or st.id == "" or type(st.body) ~= "table" then return nil, "dialogue_state_invalid" end
    if (tick() - (tonumber(st.at) or 0)) > (maxAge or 12) then return nil, "dialogue_state_stale" end
    if typeof(st.npc) == "Instance" and not st.npc.Parent then return nil, "dialogue_npc_gone" end
    return st, "ok"
end
function FSYQD.IndexOf(st, actionTag)
    if type(st) ~= "table" then return nil end
    local opts = (type(st.body) == "table") and st.body[2] or nil
    if type(opts) ~= "table" then return nil end
    local want = tostring(actionTag)
    for i = 1, #opts do
        local o = opts[i]
        if type(o) == "table" and tostring(o[2]) == want then return i end
    end
    return nil
end
function FSYQD.IsRetUsable(ret)
    if ret == nil then return true end
    if type(ret) ~= "table" then return false end
    for i = 1, #ret do
        local v = ret[i]
        if typeof(v) == "Instance" and not v.Parent then return false end
    end
    return true
end
function FSYQD.Fire(actionTag, maxAge)
    local chooseRem = Events and Events:FindFirstChild("ChooseDialogueOption")
    if not chooseRem or not chooseRem:IsA("RemoteEvent") then return false, "no_choose_remote" end
    local st, why = FSYQD.GetState(maxAge or 12)
    if not st then return false, why end
    local uiOpen = false
    pcall(function() uiOpen = IsDialogueUIOpen(true) == true end)
    if not (uiOpen or (tick() - (tonumber(st.at) or 0)) <= 5) then return false, "dialogue_ui_not_open" end
    local idx = FSYQD.IndexOf(st, actionTag)
    if not idx then return false, "action_tag_not_in_page" end
    if not FSYQD.IsRetUsable(st.ret) then return false, "return_args_unusable" end
    local ok, reason
    if st.ret ~= nil then
        ok, reason = SafeFireOneRemote(chooseRem, st.id, idx, tostring(actionTag), st.ret)
    else
        ok, reason = SafeFireOneRemote(chooseRem, st.id, idx, tostring(actionTag))
    end
    if ok then
        FSYC.DialogueState = nil
        FSYC.FSYDialogueOpenedAt = tick()
    end
    return ok, reason or (ok and "sent" or "unknown")
end
function FSYQD.WaitNext(prevSeq, timeoutSec)
    local deadline = tick() + (timeoutSec or 2.5)
    while isRunning and tick() < deadline do
        local st = FSYC.DialogueState
        if type(st) == "table" and (tonumber(st.seq) or 0) > (tonumber(prevSeq) or 0) then return st end
        task.wait(0.05)
    end
    return nil
end
function FSYQD.WaitReady(timeoutSec)
    local deadline = tick() + (timeoutSec or 4.0)
    while isRunning and tick() < deadline do
        local st = FSYQD.GetState(12)
        if st then return st end
        task.wait(0.1)
    end
    return nil
end
function FSYQD.AcceptQuest(isHard, diffCN)
    local st, why = FSYQD.GetState(12)
    if not st then
        FLogWarn("票据任务", "接取跳过，未捕获到对话状态: " .. tostring(why))
        ShowNotification("票据任务", "未捕获到对话状态，已跳过自动接取（请手动点选）。", "WARN", 4)
        return false
    end
    local prevSeq = tonumber(st.seq) or 0
    if FSYQD.IndexOf(st, "Quest") then
        local ok1, why1 = FSYQD.Fire("Quest", 12)
        if not ok1 then
            FLogWarn("票据任务", "进入接取页发包失败(" .. tostring(why1) .. ")，退回 UI 点击")
            AutoClickDialogueOption({"quest"}, true)
        end
        st = FSYQD.WaitNext(prevSeq, 2.5)
        if not st then
            ShowNotification("票据任务", "未等到接取页，请稍后重试。", "WARN", 4)
            return false
        end
    end
    local wantTag = isHard and "HardAcceptQuest" or "EasyAcceptQuest"
    if FSYQD.IndexOf(st, wantTag) then
        local ok2, why2 = FSYQD.Fire(wantTag, 12)
        if ok2 then
            ShowNotification("票据任务", string.format("已按真实协议提交接取请求（%s）。", tostring(diffCN or (isHard and "困难" or "简单"))), "SUCCESS", 4)
            return true
        end
        FLogWarn("票据任务", "接取发包失败(" .. tostring(why2) .. ")，退回 UI 点击")
        AutoClickDialogueOption({isHard and "accept hard quest" or "accept easy quest"}, true)
        return false
    elseif FSYQD.IndexOf(st, "Close") then
        ShowNotification("票据任务", "当前是任务进行中/奖励页，无需再接取。", "INFO", 4)
    else
        ShowNotification("票据任务", "当前对话页没有接取选项。", "WARN", 4)
    end
    return false
end
function FSYQD.ClaimReward()
    local st = FSYQD.GetState(12)
    if not st then
        if not IsDialogueUIOpen(true) then
            OpenRemoteNPCDialogue(TicketQuestNPCSpec, false)
            st = FSYQD.WaitReady(4.5)
        end
    end
    if not st then
        ShowNotification("票据任务", "没有检测到任务对话，请先靠近票据任务员或稍后重试。", "WARN", 4)
        return false
    end
    if FSYQD.IndexOf(st, "Quest") then
        local ok, why = FSYQD.Fire("Quest", 12)
        if not ok then
            FLogWarn("票据任务", "领奖发包失败(" .. tostring(why) .. ")，退回 UI 点击")
            if AutoClickDialogueOption({"quest"}, true) then
                ShowNotification("票据任务", "已通过点击对话按钮提交领奖。", "SUCCESS", 4)
                return true
            end
            ShowNotification("票据任务", "领奖失败：" .. tostring(why), "WARN", 4)
            return false
        end
        ShowNotification("票据任务", "已提交领奖请求，请查看游戏内奖励提示。", "SUCCESS", 4)
        task.delay(1.2, function()
            if not isRunning then return end
            local st2 = FSYQD.GetState(12)
            if st2 and FSYQD.IndexOf(st2, "Close") and not FSYQD.IndexOf(st2, "Quest") then
                if not AutoClickDialogueOption({"*leave*"}, true) then
                    AutoClickDialogueOption({"nevermind"}, true)
                end
            end
        end)
        return true
    elseif FSYQD.IndexOf(st, "EasyAcceptQuest") or FSYQD.IndexOf(st, "HardAcceptQuest") then
        ShowNotification("票据任务", "当前没有已完成的任务，对话框停在接取页。", "INFO", 4)
    else
        ShowNotification("票据任务", "当前对话页没有领奖选项（可能是奖励页/纯提示页）。", "INFO", 4)
    end
    return false
end
RunTicketQuestAction = function(diffArg, manualNotify, autoAccept)
    local isHard = (diffArg == "Hard" or diffArg == "困难" or QuestDiffMap[diffArg] == "Hard")
    local diffCN = isHard and "困难" or "简单"
    local function TryAccept()
        local okA, errA = pcall(FSYQD.AcceptQuest, isHard, diffCN)
        if not okA then FLogErr("票据任务", errA) end
    end
    if IsDialogueUIOpen(true) then
        if manualNotify or autoAccept then
            ShowNotification("票据任务", "票据任务对话框已在屏幕上打开，正在按当前页选项处理…", "INFO", 3)
        end
        if autoAccept then task.spawn(TryAccept) end
        return true
    end
    if not manualNotify and IsTicketQuestStillRunning(GetPlayerData()) then
        return false
    end
    if manualNotify or autoAccept then
        ShowNotification("票据任务", string.format("正在打开 [票据任务员] 对话框（%s）…", diffCN), "INFO", 2.5)
    end
    local opened = OpenRemoteNPCDialogue(TicketQuestNPCSpec, not manualNotify)
    if opened and autoAccept then
        task.spawn(function()
            if FSYQD.WaitReady(4.0) then TryAccept() end
        end)
    end
    return opened
end
local questCard = createCollapsibleGroup(tabQuests, "票据任务 (打开对话框)")
createNPCDualActionRow(questCard, TicketQuestNPCSpec.cnName, "直接传送到票据任务员面前，或远程打开他的对话框", function()
    TeleportToNPCSpec(TicketQuestNPCSpec)
end, function()
    OpenRemoteNPCDialogue(TicketQuestNPCSpec, false)
end)
createToggleRow(questCard, "自动票据任务", "空闲且无进行中任务（或任务已完成）时，自动帮你打开票据任务员对话框（不乱发包、不收起悬浮窗）", Config.AutoTicketQuest, function(v)
    Config.AutoTicketQuest = v
    if v then
        task.spawn(function()
            local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
            RunTicketQuestAction(diffArg, true)
        end)
    end
end, "AutoTicketQuest")
createDropdownRow(questCard, "难度", "票据任务难度标识 (简单 / 困难)", {"简单", "困难", "Easy", "Hard"}, Config.TicketDifficulty, function(v)
    Config.TicketDifficulty = v
end, "TicketDifficulty")
createButtonRow(questCard, "接受并提交票据任务(简单)", "直接打开票据任务员对话框（不自动关窗、不收起面板）", "执行简单", function()
    Config.TicketDifficulty = "简单"
    if UIControls["TicketDifficulty"] and UIControls["TicketDifficulty"].Set then
        pcall(UIControls["TicketDifficulty"].Set, "简单", true)
    end
    RunTicketQuestAction("Easy", true, true)
end)
createButtonRow(questCard, "接受并提交票据任务(困难)", "直接打开票据任务员对话框（不自动关窗、不收起面板）", "执行困难", function()
    Config.TicketDifficulty = "困难"
    if UIControls["TicketDifficulty"] and UIControls["TicketDifficulty"].Set then
        pcall(UIControls["TicketDifficulty"].Set, "困难", true)
    end
    RunTicketQuestAction("Hard", true, true)
end)
local dailyCard = createCollapsibleGroup(tabQuests, "每日任务与奖励", false)
createButtonRow(dailyCard, "领取每日任务", "打开票据任务员对话，按真实协议领取已完成任务（ChooseDialogueOption）", "领取", function()
    if isClaimingDailyTask and (tick() - FSYC.dailyTaskLockAt) < 30 then
        ShowNotification("每日任务", "正在顺序领取中，请稍候...", "WARN")
        return
    end
    if FishGate and FishGate.IsIdle and not FishGate.IsIdle() then
        ShowNotification("每日任务", "当前正在钓鱼/搏斗，已跳过领奖以免打断。请空闲后再点。", "WARN", 4)
        return
    end
    isClaimingDailyTask = true
    FSYC.dailyTaskLockAt = tick()
    task.spawn(function()
        local okR, errR = pcall(FSYQD.ClaimReward)
        if not okR then
            FLogErr("每日任务", errR)
            ShowNotification("每日任务", "领奖流程异常：" .. tostring(errR), "WARN", 4)
        end
        task.wait(0.6)
        isClaimingDailyTask = false
    end)
end)
createToggleRow(dailyCard, "自动领取每日奖励", "按顺序领取1到7天的每日奖励", Config.AutoClaimDaily, function(v) Config.AutoClaimDaily = v end, "AutoClaimDaily")
createSliderRow(dailyCard, "领取延迟", "领取天数之间的延迟", 0.3, 2.0, Config.DailyClaimDelay, true, "秒", function(v) Config.DailyClaimDelay = v end, "DailyClaimDelay")
createButtonRow(dailyCard, "立即领取第1到7天", "批量领取所有7天每日奖励", "领取全部", function()
    if isClaimingDailySign and (tick() - FSYC.dailySignLockAt) < 30 then
        ShowNotification("每日奖励", "正在顺序领取签到中，请勿连点！", "WARN")
        return
    end
    isClaimingDailySign = true
    FSYC.dailySignLockAt = tick()
    task.spawn(function()
        if Events then
            local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
            if dailyRem then
                local delaySec = math.max(0.4, tonumber(Config.DailyClaimDelay) or 0.5)
                for day = 1, 7 do
                    if not isRunning then break end
                    while isRunning and FishGate and not FishGate.IsIdle() do
                        task.wait(0.3)
                    end
                    if not isRunning then break end
                    local okDay, reasonDay = SafeFireOneRemote(dailyRem, day)
                    if not okDay and reasonDay ~= "rate_limited_or_backoff" then break end
                    task.wait(delaySec)
                end
                ShowNotification("每日奖励", "已按安全间隔顺序尝试领取 1~7 天！", "SUCCESS")
            else
                ShowNotification("每日奖励", "未找到每日奖励远程事件，领取失败。", "WARN")
            end
        else
            ShowNotification("每日奖励", "游戏远程事件尚未就绪，请稍后重试。", "WARN")
        end
        HRandomWait(2.5, 0.45)
        isClaimingDailySign = false
    end)
end)
local npcTalkCard = createCollapsibleGroup(tabQuests, "NPC 对话与传送 (27 位)", false)
for _, npcSpec in ipairs(ImportantDialogueNPCs) do
    createNPCDualActionRow(npcTalkCard, npcSpec.cnName, npcSpec.desc, function()
        TeleportToNPCSpec(npcSpec)
    end, function()
        OpenRemoteNPCDialogue(npcSpec, false)
    end)
end
local npcQuestSubCard = createCollapsibleGroup(tabQuests, "NPC任务")
local MonkeyNPCSpec = {
    cnName = "傻子",
    internalName = "Monkey",
    aliases = {"Monkey", "MonkeyKing", "WuKong", "Ape", "Khỉ", "Vua Khỉ", "Tôn Ngộ Không", "Hầu Vương", "Khi", "Vua Khi", "猴子", "猴王", "孙悟空", "千金台",
        "傻子", "Dumb Guy", "DumbGuy", "笨蛋"},
    fallbackPos = nil,
}
local monkeyCtl = { running = false, at = 0, thread = nil }
FSYC.monkeyCtl = monkeyCtl
RunGiveFishToMonkeyBatch = function()
    if not isRunning then return end
    if monkeyCtl.running then
        local th = monkeyCtl.thread
        if th == nil then
            if (tick() - (monkeyCtl.at or 0)) < 15.0 then return end
        elseif coroutine.status(th) ~= "dead" then
            return
        end
        FLogWarn("自动喂猴", string.format("检测到喂猴协程已终止但标记未释放（已挂起 %.1fs），执行一次性自愈重置", tick() - (monkeyCtl.at or 0)))
        monkeyCtl.running, monkeyCtl.at, monkeyCtl.thread = false, 0, nil
    end
    monkeyCtl.running = true
    monkeyCtl.at = tick()
    local selfThread = nil
    selfThread = task.spawn(function()
        pcall(function()
            if FishGate and not FishGate.IsIdle() then return end
            local maxGive = tonumber(Config.MonkeyGiveCount) or 100
            local firedGiveRemote = false
            local function FireGiveMonkeyRemoteOnce()
                if firedGiveRemote or not isRunning or (FishGate and not FishGate.IsIdle()) then return end
                firedGiveRemote = true
                if Events then
                    for _, rName in ipairs({"GiveFish", "SubmitFish", "MonkeyQuest", "FeedMonkey", "Monkey", "QuestSubmit", "GiveItem"}) do
                        local rem = Events:FindFirstChild(rName)
                        if rem then
                            SafeFireOneRemote(rem, "Monkey", maxGive)
                            break
                        end
                    end
                end
            end
            OpenRemoteNPCDialogue(MonkeyNPCSpec, true, function()
                AutoClickDialogueOption({
                    "给鱼", "交鱼", "提交", "喂食", "Give", "Submit", "Feed", "Hand over", "Yes", "确定", "主线任务",
                    "đưa cá", "nộp cá", "nộp", "cho ăn", "giao cá", "giao", "đưa", "đồng ý", "nhiệm vụ chính", "nhiệm vụ",
                    "dua ca", "nop ca", "nop", "cho an", "dong y",
                }, true)
                task.delay(0.25, FireGiveMonkeyRemoteOnce)
            end)
            task.delay(1.1, FireGiveMonkeyRemoteOnce)
        end)
        pcall(function() task.wait(2.0) end)
        if selfThread == nil or monkeyCtl.thread == selfThread then
            monkeyCtl.running, monkeyCtl.at, monkeyCtl.thread = false, 0, nil
        end
    end)
    monkeyCtl.thread = selfThread
end
createToggleRow(npcQuestSubCard, "自动把鱼给傻子", "收集千金台任务 (自动远程向傻子提交鱼类)", Config.AutoGiveMonkey, function(v)
    Config.AutoGiveMonkey = v
    if v and (not FishGate or FishGate.IsIdle()) then RunGiveFishToMonkeyBatch() end
end, "AutoGiveMonkey")
createDropdownRow(npcQuestSubCard, "给鱼数量", "最大给鱼数量", {"10", "25", "50", "100", "200", "500"}, tostring(Config.MonkeyGiveCount or 100), function(v)
    Config.MonkeyGiveCount = tonumber(v) or 100
end, "MonkeyGiveCount")
end)() end
end
do
local quickTPCard = createCollapsibleGroup(tabTeleports, "★ 常用传送 (置顶)")
createButtonRow(quickTPCard, "Enzo 竞技场", "Enzo 三难度 Boss 场地", "传送", function()
    if SafeTeleport(CFrame.new(-115.3, 12.2, 1349.5)) then ShowNotification("已传送", "已到达 Enzo 竞技场", "SUCCESS") end
end)
createButtonRow(quickTPCard, "章鱼寄生体", "海洋隐藏 Boss 浮标", "传送", function()
    if SafeTeleport(CFrame.new(1608.2, 8.0, -218.3)) then ShowNotification("已传送", "已到达 章鱼寄生体", "SUCCESS") end
end)
createButtonRow(quickTPCard, "渔夫之地", "地下渔夫领域", "传送", function()
    if SafeTeleport(CFrame.new(112.5, -327.0, -30.8)) then ShowNotification("已传送", "已到达 渔夫之地", "SUCCESS") end
end)
createButtonRow(quickTPCard, "龙钓海", "龙钓海竞技场入口", "传送", function()
    TeleportToDragonSea()
end)
createButtonRow(quickTPCard, "起始岛 (娜娜)", "出生岛 · 卖鱼 / 票据任务", "传送", function()
    if SafeTeleport(CFrame.new(-200.7, 14.1, 35.9)) then ShowNotification("已传送", "已到达 起始岛", "SUCCESS") end
end)
local customTPCard = createCollapsibleGroup(tabTeleports, "自定义传送点", false)
local tpActionW = UIM.touch and 118 or 96
local inputRow = Instance.new("Frame")
inputRow.Size = UDim2.new(1, 0, 0, UIM.rowH)
inputRow.BackgroundColor3 = Colors.RowNormal
inputRow.BorderSizePixel = 0
inputRow.Parent = customTPCard
local box = Instance.new("TextBox")
box.Size = UDim2.new(1, -(tpActionW + 26), 0, UIM.ddH)
box.Position = UDim2.new(0, 12, 0.5, -UIM.ddH / 2)
box.BackgroundColor3 = Colors.InputBg
box.Font = Enum.Font.Gotham
box.PlaceholderText = "输入传送名称..."
box.PlaceholderColor3 = Colors.TextMuted
box.Text = ""
box.TextColor3 = Colors.TextWhite
box.TextSize = 12
box.BorderSizePixel = 0
box.ClearTextOnFocus = false
box.Parent = inputRow
do
    local p = Instance.new("UIPadding"); p.PaddingLeft = UDim.new(0, 10); p.Parent = box
    local bs = Instance.new("UIStroke", box); bs.Color = Colors.BorderSubtle; bs.Thickness = 1; bs.Transparency = 0.35
end
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0, tpActionW, 0, UIM.btnH)
saveBtn.Position = UDim2.new(1, -tpActionW - 12, 0.5, -UIM.btnH / 2)
saveBtn.BackgroundColor3 = Colors.Accent
saveBtn.Font = Enum.Font.GothamBold
saveBtn.Text = "保存当前位置"
saveBtn.TextColor3 = Colors.AccentDeep
saveBtn.TextSize = 11
saveBtn.TextTruncate = Enum.TextTruncate.AtEnd
saveBtn.BorderSizePixel = 0
saveBtn.AutoButtonColor = false
saveBtn.Parent = inputRow
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 8)
RegisterThemeUpdater(function() saveBtn.BackgroundColor3 = Colors.Accent; saveBtn.TextColor3 = Colors.AccentDeep end)
local coordRow = Instance.new("Frame")
coordRow.Size = UDim2.new(1, 0, 0, UIM.rowH)
coordRow.BackgroundColor3 = Colors.RowNormal
coordRow.BorderSizePixel = 0
coordRow.Parent = customTPCard
local coordLabel = Instance.new("TextLabel")
coordLabel.Size = UDim2.new(1, -(tpActionW + 30), 1, 0)
coordLabel.Position = UDim2.new(0, 12, 0, 0)
coordLabel.BackgroundTransparency = 1
coordLabel.Font = Enum.Font.GothamBold
coordLabel.Text = "当前坐标: 点击右侧读取"
coordLabel.TextColor3 = Colors.AccentGreen
coordLabel.TextSize = 11
coordLabel.TextXAlignment = Enum.TextXAlignment.Left
coordLabel.TextTruncate = Enum.TextTruncate.AtEnd
coordLabel.Parent = coordRow
local readBtn = Instance.new("TextButton")
readBtn.Size = UDim2.new(0, tpActionW, 0, UIM.btnH)
readBtn.Position = UDim2.new(1, -tpActionW - 12, 0.5, -UIM.btnH / 2)
readBtn.BackgroundColor3 = Colors.ControlBg
readBtn.Font = Enum.Font.GothamBold
readBtn.Text = "读取当前 XYZ"
readBtn.TextColor3 = Colors.TextSubtle
readBtn.TextSize = 11
readBtn.BorderSizePixel = 0
readBtn.AutoButtonColor = false
readBtn.Parent = coordRow
Instance.new("UICorner", readBtn).CornerRadius = UDim.new(0, 8)
local listFrame = Instance.new("Frame"); listFrame.Size = UDim2.new(1, 0, 0, 0); listFrame.AutomaticSize = Enum.AutomaticSize.Y; listFrame.BackgroundTransparency = 1; listFrame.Parent = customTPCard
local ll = Instance.new("UIListLayout"); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = listFrame
local RefreshCustomTPs
local CUSTOM_TP_MAX_ROWS = FSYC.Tunables and FSYC.Tunables.CustomTpMaxRows or 100
local tpRows = {}
do
    for i = 1, CUSTOM_TP_MAX_ROWS do
        local row = Instance.new("Frame")
        row.Name = "CustomTPRow" .. i
        row.LayoutOrder = i
        row.Size = UDim2.new(1, 0, 0, UIM.touch and 52 or 44)
        row.BackgroundColor3 = Colors.RowNormal
        row.BorderSizePixel = 0
        row.ClipsDescendants = true
        row.Visible = false
        row.Parent = listFrame
        local rp = Instance.new("UIPadding")
        rp.PaddingLeft = UDim.new(0, 12)
        rp.PaddingRight = UDim.new(0, 10)
        rp.Parent = row
        local tf = Instance.new("Frame")
        tf.Size = UDim2.new(1, -(UIM.touch and 202 or 176), 1, 0)
        tf.BackgroundTransparency = 1
        tf.ClipsDescendants = true
        tf.Parent = row
        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size = UDim2.new(1, 0, 0, 18)
        nameLbl.Position = UDim2.new(0, 0, 0, 3)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamBold
        nameLbl.Text = ""
        nameLbl.TextColor3 = Colors.TextWhite
        nameLbl.TextSize = 12
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Parent = tf
        local coordLbl = Instance.new("TextLabel")
        coordLbl.Size = UDim2.new(1, 0, 0, 14)
        coordLbl.Position = UDim2.new(0, 0, 0, 21)
        coordLbl.BackgroundTransparency = 1
        coordLbl.Font = Enum.Font.Gotham
        coordLbl.Text = ""
        coordLbl.TextColor3 = Colors.TextMuted
        coordLbl.TextSize = 10
        coordLbl.TextXAlignment = Enum.TextXAlignment.Left
        coordLbl.TextTruncate = Enum.TextTruncate.AtEnd
        coordLbl.Parent = tf
        local tpBtn = Instance.new("TextButton")
        tpBtn.Size = UDim2.new(0, UIM.touch and 74 or 62, 0, UIM.touch and 30 or 26)
        tpBtn.Position = UDim2.new(1, -(UIM.touch and 104 or 92), 0.5, -(UIM.touch and 15 or 13))
        tpBtn.BackgroundColor3 = Colors.ControlBg
        tpBtn.Font = Enum.Font.GothamBold
        tpBtn.Text = "传送"
        tpBtn.TextColor3 = Colors.AccentSoft
        tpBtn.TextSize = 11
        tpBtn.BorderSizePixel = 0
        tpBtn.Parent = row
        Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 7)
        local delBtn = Instance.new("TextButton")
        delBtn.Size = UDim2.new(0, UIM.touch and 28 or 24, 0, UIM.touch and 30 or 26)
        delBtn.Position = UDim2.new(1, -(UIM.touch and 28 or 24), 0.5, -(UIM.touch and 15 or 13))
        delBtn.BackgroundColor3 = Colors.ControlBg
        delBtn.Font = Enum.Font.GothamBold
        delBtn.Text = "X"
        delBtn.TextColor3 = Colors.AccentRed
        delBtn.TextSize = 11
        delBtn.BorderSizePixel = 0
        delBtn.Parent = row
        Instance.new("UICorner", delBtn).CornerRadius = UDim.new(0, 7)
        row.MouseEnter:Connect(function()
            if UIM.touch or ModeCtl.IsMobile() then return end
            PlayQuickTween(row, {BackgroundColor3 = Colors.RowHover})
        end)
        row.MouseLeave:Connect(function()
            if UIM.touch or ModeCtl.IsMobile() then return end
            PlayQuickTween(row, {BackgroundColor3 = Colors.RowNormal})
        end)
        BindClick(tpBtn, function()
            local tp = CustomTPs[i]
            if not tp then return end
            if SafeTeleport(CFrame.new(tp.x, tp.y + 3, tp.z)) then
                ShowNotification("传送", "已到达: " .. tostring(tp.name), "SUCCESS")
            end
        end)
        BindClick(delBtn, function()
            local tp = CustomTPs[i]
            if not tp then return end
            local removedName = tostring(tp.name)
            table.remove(CustomTPs, i)
            SaveCustomTPs()
            RefreshCustomTPs()
            ShowNotification("已删除", "已移除传送点: " .. removedName, "WARN")
        end)
        tpRows[i] = { row = row, nameLbl = nameLbl, coordLbl = coordLbl, tpBtn = tpBtn, delBtn = delBtn }
    end
    RegisterThemeUpdater(function()
        for i = 1, CUSTOM_TP_MAX_ROWS do
            local refs = tpRows[i]
            if refs and refs.row and refs.row.Parent then
                refs.row.BackgroundColor3 = Colors.RowNormal
                refs.nameLbl.TextColor3 = Colors.TextWhite
                refs.coordLbl.TextColor3 = Colors.TextMuted
                refs.tpBtn.BackgroundColor3 = Colors.ControlBg
                refs.tpBtn.TextColor3 = Colors.AccentSoft
                refs.delBtn.BackgroundColor3 = Colors.ControlBg
            end
        end
    end)
end
RefreshCustomTPs = function()
    local total = #CustomTPs
    for i = 1, CUSTOM_TP_MAX_ROWS do
        local refs = tpRows[i]
        local tp = CustomTPs[i]
        if refs then
            if tp then
                if not refs.row.Visible then refs.row.Visible = true end
                local tpName = tostring(tp.name or "")
                if refs.nameLbl.Text ~= tpName then refs.nameLbl.Text = tpName end
                local coordText = string.format("X: %.1f | Y: %.1f | Z: %.1f", tonumber(tp.x) or 0, tonumber(tp.y) or 0, tonumber(tp.z) or 0)
                if refs.coordLbl.Text ~= coordText then refs.coordLbl.Text = coordText end
            elseif refs.row.Visible then
                refs.row.Visible = false
            end
        end
    end
    if total > CUSTOM_TP_MAX_ROWS then
        FLogWarn("CustomTP", string.format("自定义传送点 %d 个，超过静态列表上限 %d，超出部分不显示", total, CUSTOM_TP_MAX_ROWS))
    end
    task.defer(function()
        if not isRunning then return end
        local refresher = currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab]
        if refresher then pcall(refresher) end
    end)
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
        local name = ((box.Text or ""):gsub("[%c]", ""):match("^%s*(.-)%s*$") or ""):sub(1, 48)
        if name == "" then name = "自定义点 " .. (#CustomTPs + 1) end
        if #CustomTPs >= 100 then
            ShowNotification("保存失败", "自定义传送点最多保存 100 个，请先删除旧项目。", "WARN")
            return
        end
        local p = root.Position
        if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z or math.abs(p.X) >= 1000000 or math.abs(p.Y) >= 1000000 or math.abs(p.Z) >= 1000000 then
            ShowNotification("保存失败", "当前角色坐标异常，无法保存。", "ERROR")
            return
        end
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
end
do
local liveNPCCard = createCollapsibleGroup(tabTeleports, "特殊NPC实时传送 (神灵/道士/茅山/四圣兽)", false)
local function CreateNPCRow(key, data)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, UIM.rowH)
    row.BackgroundColor3 = Colors.RowNormal
    row.BorderSizePixel = 0
    row.ClipsDescendants = true
    row.Parent = liveNPCCard
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 13)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = row
    local hl = Instance.new("Frame")
    hl.Size = UDim2.new(0, 3, 1, -14)
    hl.Position = UDim2.new(0, 0, 0, 7)
    hl.BackgroundColor3 = Colors.Accent
    hl.BorderSizePixel = 0
    hl.Visible = false
    hl.Parent = row
    Instance.new("UICorner", hl).CornerRadius = UDim.new(1, 0)
    local tf = Instance.new("Frame")
    tf.Size = UDim2.new(1, -(UIM.btnW + 18), 1, 0)
    tf.BackgroundTransparency = 1
    tf.ClipsDescendants = true
    tf.Parent = row
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 18)
    title.Position = UDim2.new(0, 0, 0, math.floor(UIM.rowH * 0.15))
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = data.icon .. " " .. data.name .. " (未检测到)"
    title.TextColor3 = Colors.TextMuted
    title.TextSize = UIM.titleSize
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.Parent = tf
    local desc = Instance.new("TextLabel")
    desc.Size = UDim2.new(1, 0, 0, 14)
    desc.Position = UDim2.new(0, 0, 0, UIM.rowH - 20)
    desc.BackgroundTransparency = 1
    desc.Font = Enum.Font.Gotham
    desc.Text = data.desc or "等待刷新..."
    desc.TextColor3 = Colors.TextMuted
    desc.TextSize = UIM.descSize
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextTruncate = Enum.TextTruncate.AtEnd
    desc.Parent = tf
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, UIM.btnW, 0, UIM.btnH)
    btn.Position = UDim2.new(1, -UIM.btnW - 6, 0.5, -UIM.btnH / 2)
    btn.BackgroundColor3 = Colors.ControlBg
    btn.Font = Enum.Font.GothamBold
    btn.Text = data.fallbackPos and "前往岛屿" or "传送"
    btn.TextColor3 = Colors.TextMuted
    btn.TextSize = 11
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local rowDivider = Instance.new("Frame")
    rowDivider.Size = UDim2.new(1, -24, 0, 1)
    rowDivider.Position = UDim2.new(0, 12, 1, -1)
    rowDivider.BackgroundColor3 = Colors.Divider
    rowDivider.BackgroundTransparency = 0.45
    rowDivider.BorderSizePixel = 0
    rowDivider.Parent = row
    data.ui_title = title; data.ui_desc = desc; data.ui_btn = btn
    local sRows = searchState.rows
    sRows[#sRows + 1] = {
        frame = row,
        title = title,
        hl = hl,
        cat = DashUI.resolveCategory(row),
        hay = tqLc(tostring(data.name or key or "") .. " " .. tostring(data.desc or "") .. " 特殊npc 实时雷达 传送"),
    }
    RegisterThemeUpdater(function() if data.pos then btn.BackgroundColor3 = Colors.Accent elseif data.fallbackPos then btn.TextColor3 = Colors.AccentSoft end end)
    BindClick(btn, function()
        local isLiveTarget = false
        local targetDest = data.pos
        if targetDest and data.fallbackPos and (targetDest - data.fallbackPos).Magnitude > 450 then
            data.pos = nil
            data.inst = nil
            data.lastSeen = nil
            targetDest = nil
        end
        if targetDest then
            isLiveTarget = true
        else
            targetDest = data.fallbackPos
        end
        if targetDest then
            local char = LocalPlayer.Character; local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                TryStreamAroundPosition(targetDest)
                local standOffset = Vector3.new(0, 0, 2.5)
                local baseDest = targetDest
                if data.inst and data.inst.Parent and isLiveTarget then
                    local instPos = GetNPCPosition(data.inst)
                    if instPos and (not data.fallbackPos or (instPos - data.fallbackPos).Magnitude <= 450) then
                        baseDest = instPos
                    end
                end
                local targetPos = baseDest + standOffset + Vector3.new(0, 2.5, 0)
                local rayParams = RaycastParams.new()
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                local ignoreList = {}
                if char then table.insert(ignoreList, char) end
                if data.inst then table.insert(ignoreList, data.inst) end
                for _, fn in ipairs({"IdenticalESP", "IdenticalESPAnchors", "IdenticalESPHighlights", "FishRingAnchor", "IdenticalWaterPlatform"}) do
                    local espInst = Workspace:FindFirstChild(fn)
                    if espInst then table.insert(ignoreList, espInst) end
                end
                rayParams.FilterDescendantsInstances = ignoreList
                local rayOrigin = baseDest + standOffset + Vector3.new(0, 12, 0)
                local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -35, 0), rayParams)
                if not rayResult then
                    rayResult = Workspace:Raycast(baseDest + Vector3.new(0, 12, 0), Vector3.new(0, -35, 0), rayParams)
                    if rayResult then
                        targetPos = rayResult.Position + Vector3.new(0, 2.5, 0)
                    end
                else
                    targetPos = rayResult.Position + Vector3.new(0, 2.5, 0)
                end
                local flatLookTarget = Vector3.new(baseDest.X, targetPos.Y, baseDest.Z)
                local finalCF = ((flatLookTarget - targetPos).Magnitude > 0.05) and CFrame.lookAt(targetPos, flatLookTarget) or CFrame.new(targetPos)
                SafeTeleport(finalCF)
                if isLiveTarget then
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
local islandCard = createCollapsibleGroup(tabTeleports, "岛屿传送 (13 座)", false)
local islands = {
    {name = "[1] 起始岛 (Beginning Isle)", power = "1", desc = "新手出生岛 · Nana卖鱼 / 楚依旧技能 / 南江洗特质 / 票据任务 / 暗影山洞", pos = Vector3.new(-200.7, 11.1, 35.9)},
    {name = "[2] 竹子岛 (Bamboo Isle)", power = "19", desc = "早期主线岛 + 竹岛神灵 #1 · 江老（无影太极击）/ 50M祈祷祝福", pos = Vector3.new(-1223.0, 7.3, -24.1)},
    {name = "[3] 辐射岛 (Fallout Isle)", power = "32", desc = "Enzo（等级1000 Boss三难度）· 黄金竿等中期鱼竿", pos = Vector3.new(65.5, 8.8, 1181.3)},
    {name = "[4] 主权岛屿 (Sovereign Isle)", power = "39", desc = "大师级鱼竿（Grandmaster / Inferno）· 老江支线", pos = Vector3.new(-1276.4, 8.8, 1239.7)},
    {name = "[5] 鲈鱼岛 (Perch Isle)", power = "48", desc = "脊椎系列鱼竿 · 亚索（疾风剑豪斩风钓法门派）", pos = Vector3.new(-62.0, 11.9, -1321.4)},
    {name = "[6] 冰霜岛 (Frost Isle)", power = "55", desc = "重力系列鱼竿 + 冰霜神灵 #2 · 夏钓帝（斩天门v3）/ 50M祈祷祝福", pos = Vector3.new(-1366.0, 11.9, -1495.4)},
    {name = "[7] 椰子岛 (Coconut Isle)", power = "65", desc = "荆棘系列鱼竿 · 北冥（北冥宝珠主线任务）/ 椰子岛商人", pos = Vector3.new(1493.6, 9.1, -1430.6)},
    {name = "[8] 琥珀岛 (Amber Isle)", power = "75", desc = "星光竿等主线终点 + 琥珀神灵 #3 · 五指钓王（天气鱼主线）/ 50M祈祷", pos = Vector3.new(1259.4, 9.1, 1401.5)},
    {name = "[9] 战场岛 (Battlefield Isle)", power = "90", desc = "高阶技能与终局集中地 · 楚依旧/江老/老吴/盲眼钓圣/少林/楚天骄/断杆", pos = Vector3.new(1393.5, 11.3, 169.6)},
    {name = "[10] 迷雾山岛 (Mistpeak Isle)", power = "100", desc = "山海龙鲸 Boss · 卢奥亚之王主线任务 / 史星钓（石克翔）/ 断杆", pos = Vector3.new(2660.2, 8.8, -86.7)},
    {name = "[11] 世界钓鱼岛 (World Angler Isle)", power = "100", desc = "比奥迪（Biao Di）主线任务 / 斩兽碎心V3 / 熔岩洞穴", pos = Vector3.new(-2404.5, 7.6, -202.4)},
    {name = "[12] 天气之岛 (Weather Isle)", power = "100", desc = "天气核心终局岛 · 楚Xin（生成船只）/ 八长（鱼饵）/ 老姜与迪奥·克维主线", pos = Vector3.new(-2908.1, 6.8, 1191.2)},
    {name = "[13] 神秘珊瑚礁岛 (Mysterious Coral Reef)", power = "100", desc = "神秘珊瑚礁海域 · 楚天之骄 / 石星之骄 / Yaxuo（亚索）主线任务", pos = Vector3.new(-2648.0, 6.8, -1322.1)},
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
local bossRealmCard = createCollapsibleGroup(tabTeleports, "Boss竞技场与隐藏领域", false)
local bossRealms = {
    {name = "章鱼寄生体", pos = Vector3.new(1608.2, 5.0, -218.3)}, {name = "渔夫之地", pos = Vector3.new(112.5, -330.0, -30.8)}, {name = "Enzo竞技场", pos = Vector3.new(-115.3, 9.2, 1349.5)},
}
for _, br in ipairs(bossRealms) do
    createButtonRow(bossRealmCard, br.name, "传送到 " .. br.name, "传送", function()
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then SafeTeleport(CFrame.new(br.pos + Vector3.new(0, 3, 0))); ShowNotification("传送", "已到达 " .. br.name, "SUCCESS") end
    end)
end
local rodDealerCard = createCollapsibleGroup(tabTeleports, "鱼竿商人 · 标迪 (8 岛)", false)
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
local sRodCard = createCollapsibleGroup(tabTeleports, "秘密鱼竿位置", false)
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
local srvCard = createCollapsibleGroup(tabTeleports, "服务器与玩家传送", false)
local selectedPlayerName = nil
local playerNameToObj = {}
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
end, nil, 64)
selectedPlayerName = playerOpts[1]
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
end
local isApplyingLighting = false
local lastCameraParticleScan = 0
local fullbrightWasActive = false
local shadowsDisabledByScript = false
local FULLBRIGHT_AMBIENT = Color3.fromRGB(180, 180, 180)
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
local function NotifyAndRefreshESP(catKey, v, labelTitle)
    Config["ESP_" .. catKey] = v
    if DashUI._refreshESPNow then
        pcall(DashUI._refreshESPNow, catKey, v, labelTitle)
    end
end
createToggleRow(espCard, "神灵ESP", "高亮三座神灵祭坛与活跃神灵 (跨全图穿墙显示)", Config.ESP_GodSpirit, function(v) NotifyAndRefreshESP("GodSpirit", v, "神灵ESP") end, "ESP_GodSpirit")
createToggleRow(espCard, "船只ESP", "高亮已生成的船只位置与距离", Config.ESP_Boats, function(v) NotifyAndRefreshESP("Boats", v, "船只ESP") end, "ESP_Boats")
createToggleRow(espCard, "茅山ESP", "高亮茅山商人/茅山鱼竿位置", Config.ESP_Maoshan, function(v) NotifyAndRefreshESP("Maoshan", v, "茅山ESP") end, "ESP_Maoshan")
createToggleRow(espCard, "道士ESP", "高亮道士商人位置（流动商人）", Config.ESP_Taoist, function(v) NotifyAndRefreshESP("Taoist", v, "道士ESP") end, "ESP_Taoist")
createToggleRow(espCard, "隐藏商人ESP", "高亮傻子隐藏商人 (Dumb Guy) 位置", Config.ESP_DumbGuy, function(v) NotifyAndRefreshESP("DumbGuy", v, "隐藏商人ESP") end, "ESP_DumbGuy")
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
local stabCard = createCollapsibleGroup(tabPlayer, "防挂机与稳定性")
createToggleRow(stabCard, "防挂机", "防止Roblox 20分钟空闲断开", Config.AntiAFK, function(v) Config.AntiAFK = v end, "AntiAFK")
createToggleRow(stabCard, "被踢自动重连", "断线或报错弹窗时自动重连服务器", Config.AutoRejoin, function(v) Config.AutoRejoin = v end, "AutoRejoin")
local devCard = createCollapsibleGroup(tabProfiles, "设备与输入")
local devInfo = createInfoRow(devCard, "设备识别", ModeCtl.Describe())
local devNow = createInfoRow(devCard, "当前生效", ModeCtl.Label())
createDropdownRow(devCard, "运行模式",
    "自动=按硬件识别（纯触屏→手机，有键鼠→电脑，两者都有→混合按电脑）；手动手机/电脑=只认该族输入。切换立即生效并解绑另一套事件",
    FSYC.MODE_OPTIONS, Config.DeviceMode, function(v)
        Config.DeviceMode = v
        ModeCtl.Apply(v)
        if devInfo then devInfo.Set(ModeCtl.Describe()) end
        if devNow then devNow.Set(ModeCtl.Label()) end
        ShowNotification("运行模式", "已切换为 " .. ModeCtl.Label() .. "，另一套输入事件已解绑", "SUCCESS", 2.5)
        if type(SaveProfile) == "function" then pcall(SaveProfile, Config.ActiveProfile) end
    end, "DeviceMode")
createToggleRow(devCard, "输入隔离",
    "自动模式：两族都收，但同一次按下只派发一次；手动手机/电脑：硬隔离，另一族事件直接丢弃",
    Config.InputIsolation, function(v)
        Config.InputIsolation = v
        ModeCtl.Apply(Config.DeviceMode, { force = true })
    end, "InputIsolation")
createSliderRow(devCard, "按下归并窗口",
    "一次按下后多少毫秒内的点击事件都算同一次操作（Activated / 鼠标点击 / 触屏兜底 三通道去重依据）",
    200, 1000, Config.InputDedupeMs, false, "ms", function(v) Config.InputDedupeMs = v end, "InputDedupeMs")
createSliderRow(devCard, "发包去重窗口",
    "同一 Remote 且参数完全相同的包，在此窗口内只放行一次；0 = 关闭。战斗域（猛击/蓄力/进度/节奏）不参与去重",
    0, 200, Config.PacketDedupeMs, false, "ms", function(v)
        Config.PacketDedupeMs = v
        PacketGuard.windowMs = v
    end, "PacketDedupeMs")
createButtonRow(devCard, "重新识别设备",
    "重新读取触屏/键盘/鼠标能力，并按当前运行模式重新应用（换设备、外接键鼠后用）",
    "重新识别", function()
        DeviceProfile.Refresh()
        ModeCtl.Apply(Config.DeviceMode, { force = true })
        if devInfo then devInfo.Set(ModeCtl.Describe()) end
        if devNow then devNow.Set(ModeCtl.Label()) end
        ShowNotification("设备识别", "当前：" .. ModeCtl.Describe(), "INFO", 3)
    end)
ModeCtl.OnChange(function()
    if devInfo then devInfo.Set(ModeCtl.Describe()) end
    if devNow then devNow.Set(ModeCtl.Label()) end
end)
local uiCard = createCollapsibleGroup(tabProfiles, "界面设置")
DashUI._applyTheme = ApplyTheme
createDropdownRow(uiCard, "主题配色", "切换非紫色高颜值点缀色（薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红）", FSYC.THEME_OPTIONS, currentThemeName, function(value)
    ApplyTheme(value, false)
    ShowNotification("主题配色已切换", "当前配色: " .. tostring(value), "SUCCESS", 2.5)
end, "UITheme")
local scaleDebounceThread = nil
createSliderRow(uiCard, "窗口缩放比例", "调节界面大小（拖动不卡，松手后生效）", 0.5, 1.2, Config.UIScale, true, "x", function(v)
    Config.UIScale = v
    if scaleDebounceThread then
        activeThreads[scaleDebounceThread] = nil
        pcall(task.cancel, scaleDebounceThread)
        scaleDebounceThread = nil
    end
    scaleDebounceThread = task.delay(0.12, function()
        if scaleDebounceThread then activeThreads[scaleDebounceThread] = nil end
        scaleDebounceThread = nil
        if not isRunning then return end
        if UpdateMainFrameScale then
            UpdateMainFrameScale(true)
        elseif mainFrameScale and mainFrameScale.Parent then
            mainFrameScale.Scale = Config.UIScale
        end
    end)
    activeThreads[scaleDebounceThread] = true
end, "UIScale")
local function ApplyAllSectionsExpanded(wantExpanded, tipText)
    for i = 1, #collapsibleSections do
        local sec = collapsibleSections[i]
        if sec and sec.section and sec.section.Parent then
            sec.SetExpanded(wantExpanded, false, true)
            sec.initialExpanded = wantExpanded
        end
    end
    if DashUI.refreshCanvas then DashUI.refreshCanvas() end
    ShowNotification("折叠面板", tipText, "INFO", 2)
end
createButtonRow(uiCard, "折叠全部分组", "临时收起所有分组与胶囊，只留标题条，长页面更好翻页（仅本次生效，不写进配置）", "全部折叠", function()
    ApplyAllSectionsExpanded(false, "已收起全部分组（仅本次）")
end)
createButtonRow(uiCard, "展开全部分组", "临时展开所有分组与胶囊，恢复完整视图（仅本次生效，不写进配置）", "全部展开", function()
    ApplyAllSectionsExpanded(true, "已展开全部分组（仅本次）")
end)
local function SectionHasVisibleRow(body)
    for _, child in ipairs(body:GetChildren()) do
        if child:IsA("GuiObject") and child.Visible then return true end
    end
    return false
end
local function ApplySearchFilterInner(raw)
    if searchState.applying then return 0 end
    searchState.applying = true
    local q = tostring(raw or "")
    q = (string.gsub(q, "^%s+", ""))
    q = (string.gsub(q, "%s+$", ""))
    q = tqLc(q)
    searchState.query = q
    local tokens = {}
    for w in string.gmatch(q, "%S+") do tokens[#tokens + 1] = w end
    local nTok = #tokens
    local rows = searchState.rows
    local hits = 0
    local catHits = {}
    local changed = 0
    for i = 1, #rows do
        local rec = rows[i]
        local row = rec.frame
        if row and row.Parent then
            local vis = true
            if nTok > 0 then
                for t = 1, nTok do
                    if not string.find(rec.hay, tokens[t], 1, true) then
                        vis = false
                        break
                    end
                end
            end
            if row.Visible ~= vis then
                row.Visible = vis
                changed = changed + 1
            end
            local shouldHighlight = (nTok > 0) and vis
            if rec.highlighted ~= shouldHighlight then
                rec.highlighted = shouldHighlight
                if rec.hl and rec.hl.Parent then rec.hl.Visible = shouldHighlight end
                if rec.title and rec.title.Parent then
                    rec.title.TextColor3 = shouldHighlight and Colors.AccentSoft or Colors.TextWhite
                end
                row.BackgroundColor3 = shouldHighlight and Colors.DropdownSelected or Colors.RowNormal
                changed = changed + 1
            end
            if vis and nTok > 0 then
                hits = hits + 1
                catHits[rec.cat] = (catHits[rec.cat] or 0) + 1
            end
        end
    end
    for i = #collapsibleSections, 1, -1 do
        local sec = collapsibleSections[i]
        if sec and sec.section and sec.section.Parent then
            if nTok > 0 then
                local has = SectionHasVisibleRow(sec.body)
                if sec.section.Visible ~= has then sec.section.Visible = has; changed = changed + 1 end
                if has and not sec.GetExpanded() then
                    sec.SetExpanded(true, false, true)
                    changed = changed + 1
                end
            else
                if not sec.section.Visible then sec.section.Visible = true; changed = changed + 1 end
                local want = (sec.initialExpanded ~= false)
                if sec.GetExpanded() ~= want then
                    sec.SetExpanded(want, false, true)
                    changed = changed + 1
                end
            end
        end
    end
    local sectionVisible = {}
    for i = 1, #collapsibleSections do
        local sec = collapsibleSections[i]
        if sec and sec.section and sec.section.Parent and sec.section.Visible then
            sectionVisible[sec.section.Parent] = true
        end
    end
    if DashUI.containerMeta then
        for container in pairs(DashUI.containerMeta) do
            if container.Parent then
                local vis = true
                if nTok > 0 then vis = sectionVisible[container] == true end
                if container.Visible ~= vis then container.Visible = vis; changed = changed + 1 end
            end
        end
    end
    if searchState.count then
        local cntText = (nTok > 0) and (tostring(hits) .. " 项") or ""
        if searchState.count.Text ~= cntText then searchState.count.Text = cntText end
    end
    if nTok > 0 and hits > 0 and DashUI.categories then
        local cur = currentActiveTab or ""
        local curHits = catHits[cur] or 0
        local bestCat, bestHits = nil, curHits
        for _, catName in ipairs(DashUI.categories) do
            local h = catHits[catName] or 0
            if h > bestHits then bestCat, bestHits = catName, h end
        end
        if bestCat and bestCat ~= cur then
            if DashUI.switchCategory then DashUI.switchCategory(bestCat) end
        end
    end
    if changed > 0 and DashUI.refreshCanvas then
        DashUI.refreshCanvas()
    end
    searchState.applying = false
    return hits
end
local function ApplySearchFilter(raw)
    local ok, hits = pcall(ApplySearchFilterInner, raw)
    if ok then return hits end
    searchState.applying = false
    FLogWarn("搜索", "过滤异常已隔离: " .. tostring(hits))
    return 0
end
searchState.refresh = function()
    if searchState.query ~= "" then ApplySearchFilter(searchState.query) end
end
local searchDebounce = nil
if searchState.box then
    searchState.box:GetPropertyChangedSignal("Text"):Connect(function()
        if searchDebounce then
            activeThreads[searchDebounce] = nil
            pcall(function() task.cancel(searchDebounce) end)
            searchDebounce = nil
        end
        searchDebounce = task.delay(0.18, function()
            if searchDebounce then activeThreads[searchDebounce] = nil end
            searchDebounce = nil
            if not isRunning then return end
            ApplySearchFilter(searchState.box.Text)
        end)
        activeThreads[searchDebounce] = true
    end)
end
if searchState.clear then
    BindClick(searchState.clear, function()
        if searchState.box.Text ~= "" then
            searchState.box.Text = ""
        else
            ApplySearchFilter("")
        end
    end)
end
createToggleRow(uiCard, "调试日志", "开启后输出 FSY 运行日志，便于定位偶发异常（异常日志始终输出）", Config.DebugLog, function(v)
    Config.DebugLog = v
    FLog("配置", "调试日志已" .. (v and "开启" or "关闭"))
end, "DebugLog")
local profCard = createCollapsibleGroup(tabProfiles, "配置文件管理")
createButtonRow(profCard, "保存配置", "将所有设置保存到JSON文件", "保存配置", function()
    if SaveProfile() then ShowNotification("配置已保存", "配置文件 'default.json' 保存成功！", "SUCCESS") else ShowNotification("配置错误", "保存配置文件失败。", "ERROR") end
end)
createButtonRow(profCard, "加载配置", "从JSON文件加载设置并同步界面", "加载配置", function()
    if LoadProfile() then
        ModeCtl.Apply(Config.DeviceMode, { force = true })
        ShowNotification("配置已加载", "配置文件 'default.json' 加载并同步成功！", "SUCCESS")
        if UpdateMainFrameScale then UpdateMainFrameScale(true) end
    else
        ShowNotification("配置错误", "未找到已保存的配置文件。", "WARN")
    end
end)
createToggleRow(profCard, "注入时自动加载配置", "启动时自动加载配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end, "AutoLoadProfile")
local credCard = createCollapsibleGroup(tabProfiles, "会话操作")
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复所有设置", "卸载", UnloadScript)
local function refreshVisibleTabCanvas()
    if currentActiveTab and tabCanvasRefreshers and tabCanvasRefreshers[currentActiveTab] then
        pcall(tabCanvasRefreshers[currentActiveTab])
    end
end
task.defer(refreshVisibleTabCanvas)
task.delay(0.4, refreshVisibleTabCanvas)
task.delay(1.2, refreshVisibleTabCanvas)
end
end)() end
IsToolFishingRod = function(inst, pData)
    if not inst then return false end
    pData = pData or GetPlayerData()
    local equippedRodName = pData and DashUI._readValueBase(pData:FindFirstChild("FishingRod"), nil) or nil
    local rawName = (inst.Name or "")
    if equippedRodName and equippedRodName ~= "" and rawName == equippedRodName then
        return true
    end
    local low = tqLc(rawName)
    if low:find("rod") or low:find("pole") or low:find("钓竿") or low:find("鱼竿") or low:find("钓") or low:find("竿")
        or low:find("釣竿", 1, true) or low:find("魚竿", 1, true)
        or low:find("cần câu", 1, true) or low:find("can cau", 1, true) then
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
local cachedHoldingRodTime = 0
do
local cachedHoldingRod = true
local HOLDING_ROD_CACHE_TTL = 0.25
IsCharacterHoldingFishingRod = function(char, pData)
    char = char or LocalPlayer.Character
    if not char then return false end
    local now = tick()
    if (now - cachedHoldingRodTime) < HOLDING_ROD_CACHE_TTL then
        return cachedHoldingRod
    end
    pData = pData or GetPlayerData()
    local equippedTool = char:FindFirstChildOfClass("Tool")
    if equippedTool then
        cachedHoldingRod = IsToolFishingRod(equippedTool, pData)
        cachedHoldingRodTime = now
        return cachedHoldingRod
    end
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Model") or ch:IsA("Tool") then
            local cn = tqLc(ch.Name or "")
            if IsToolFishingRod(ch, pData) then
                cachedHoldingRod = true
                cachedHoldingRodTime = now
                return true
            elseif DashUI._isFishLikeName and DashUI._isFishLikeName(cn) then
                cachedHoldingRod = false
                cachedHoldingRodTime = now
                return false
            end
        end
    end
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
end
local attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false
StopLingeringFishingAnimations = function(char, forceAllAction)
    char = char or (LocalPlayer and LocalPlayer.Character)
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum)
    if not animator then return false end
    local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
    if not ok or type(tracks) ~= "table" or #tracks == 0 then return false end
    local stoppedCount = 0
    local holdingRod = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(char)
    local hasAnyTool = char:FindFirstChildOfClass("Tool") ~= nil
    for i = 1, #tracks do
        local track = tracks[i]
        if track and track.IsPlaying then
            local prio = track.Priority
            local tName = (track.Name or ""):lower()
            local animObj = track.Animation
            local aName = (animObj and animObj.Name or ""):lower()
            local isCoreLocomotion = (prio == Enum.AnimationPriority.Core)
                or (prio == Enum.AnimationPriority.Idle and (tName:find("idle") or aName:find("idle")))
                or (prio == Enum.AnimationPriority.Movement and (tName:find("walk") or tName:find("run") or tName:find("move") or aName:find("walk") or aName:find("run")))
            if not isCoreLocomotion then
                local isExplicitFishing = tName:find("fish") or tName:find("rod") or tName:find("cast")
                    or tName:find("reel") or tName:find("hold") or tName:find("angle") or tName:find("pull")
                    or tName:find("hook") or tName:find("catch") or aName:find("fish") or aName:find("rod")
                    or aName:find("cast") or aName:find("reel") or aName:find("hold") or aName:find("angle")
                    or aName:find("pull") or aName:find("hook") or aName:find("catch")
                    or tName:find("câu") or aName:find("câu") or tName:find("钓") or aName:find("钓")
                local shouldStop = false
                if forceAllAction then
                    shouldStop = not isCoreLocomotion
                elseif not hasAnyTool and not attrFishing and not attrMinigame then
                    shouldStop = isExplicitFishing
                        or (prio == Enum.AnimationPriority.Action)
                        or (prio == Enum.AnimationPriority.Action2)
                        or (prio == Enum.AnimationPriority.Action3)
                        or (prio == Enum.AnimationPriority.Action4)
                        or tName == "animation" or aName == "animation" or tName == "toolnoneanim" or tName == "toolnone" or tName == ""
                elseif not holdingRod and not attrFishing and not attrMinigame then
                    shouldStop = isExplicitFishing
                end
                if shouldStop then
                    pcall(function()
                        track:Stop(0.12)
                    end)
                    stoppedCount = stoppedCount + 1
                end
            end
        end
    end
    return stoppedCount > 0
end
DashUI._stopLingeringFishingAnimations = StopLingeringFishingAnimations
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
SyncUIWithConfig()
task.spawn(function()
    task.wait(0.3)
    if isRunning and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
    end
end)
local function CreateFishingStateGate(deps)
    deps = deps or {}
    local cfg = deps.config or {}
    local logFn = deps.log
    local notifyFn = deps.notify
    local tun = FSYC.Tunables or {}
    local FIGHT_EXIT_GRACE = tun.GateFightExitGraceSec or 0.80
    local ACTIVE_EXIT_GRACE = tun.GateActiveExitGraceSec or 0.40
    local QUIET_AFTER_EXIT = tun.GateQuietAfterExitSec or 0.25
    local WARN_BLOCK_STREAK = tun.GateWarnBlockStreakSec or 6.0
    local MAX_GHOST_FIGHT = tun.GateMaxGhostFightSec or 240
    local G = {
        fight = false,
        lastFightAt = 0,
        endedAt = 0,
        active = false,
        lastActiveAt = 0,
        instant = false,
        rawFight = false,
        quietUntil = 0,
        now = 0,
        blockStreakAt = 0,
        fightStartAt = 0,
        lastHardAt = 0,
        hookedBlock = false,
        warned = false,
        reason = "空闲",
        stats = { allow = 0, block = 0, enter = 0, exit = 0 },
    }
    local snap = {
        attrFishing = false, attrMinigame = false, hooked = false,
        bossBar = false, fui = false, slam = false,
    }
    G.snap = snap
    local M = {}
    local function L(msg)
        if logFn then pcall(logFn, "状态闸门", msg) end
    end
    local function GateEnabled()
        return cfg.FishingGate ~= false
    end
    function M.Update(now, s)
        if type(now) ~= "number" then return end
        s = s or snap
        G.now = now
        snap.attrFishing = (s.attrFishing == true)
        snap.attrMinigame = (s.attrMinigame == true)
        snap.hooked = (s.hooked == true)
        snap.bossBar = (s.bossBar == true)
        snap.fui = (s.fui == true)
        snap.slam = (s.slam == true)
        G.rawFight = (s.rawFight == true)
        local hardSignal = snap.attrMinigame or snap.bossBar
        local looseSignal = (cfg.FishingGateLoose == true) and snap.fui and (snap.slam or snap.attrFishing)
        local fightNow = hardSignal or (snap.hooked and not G.hookedBlock) or looseSignal
        if hardSignal then G.lastHardAt = now end
        if fightNow then
            G.lastFightAt = now
            if not G.fight then
                G.fight = true
                G.fightStartAt = now
                G.stats.enter = G.stats.enter + 1
                G.blockStreakAt = 0
                G.warned = false
                L(string.format("进入搏斗：Minigame=%s Boss条=%s 自己的鱼=%s",
                    tostring(snap.attrMinigame), tostring(snap.bossBar), tostring(snap.hooked)))
            end
            G.reason = "搏斗中"
        elseif G.fight and (now - G.lastFightAt) > FIGHT_EXIT_GRACE then
            G.fight = false
            G.endedAt = now
            G.quietUntil = now + QUIET_AFTER_EXIT
            G.stats.exit = G.stats.exit + 1
            G.reason = "刚退出搏斗"
            L(string.format("退出搏斗：本场 %.1fs", now - G.fightStartAt))
        end
        if (not looseSignal) and G.fight and (now - G.lastHardAt) > MAX_GHOST_FIGHT
            and (now - G.fightStartAt) > MAX_GHOST_FIGHT then
            G.fight = false
            G.endedAt = now
            G.quietUntil = now + QUIET_AFTER_EXIT
            G.stats.exit = G.stats.exit + 1
            G.hookedBlock = true
            G.reason = "幽灵鱼收场"
            L(string.format("只有「自己的鱼」信号、持续 %.0fs 未拿到 Minigame/Boss 条，判定为鱼模型残留，已强制收场", now - G.fightStartAt))
        end
        if G.hookedBlock and not snap.hooked then G.hookedBlock = false end
        local activeNow = fightNow or snap.attrFishing
        if activeNow then
            G.lastActiveAt = now
            G.active = true
        elseif G.active and (now - G.lastActiveAt) > ACTIVE_EXIT_GRACE then
            G.active = false
        end
        G.instant = snap.attrFishing or snap.attrMinigame or (snap.hooked and not G.hookedBlock)
        if GateEnabled() and G.rawFight and not G.fight then
            if G.blockStreakAt == 0 then
                G.blockStreakAt = now
            elseif (not G.warned) and (now - G.blockStreakAt) >= WARN_BLOCK_STREAK then
                G.warned = true
                local msg = string.format("旧判定持续 %.0fs 认为在战斗，但闸门未采信（Minigame属性=%s Boss拔河条=%s 自己的鱼=%s），已拦截发包。若此时确实在搏斗，请按【钓鱼】页「查看自动发包闸门状态」把这一行发出来，我按你那种鱼补信号。",
                    now - G.blockStreakAt, tostring(snap.attrMinigame), tostring(snap.bossBar), tostring(snap.hooked))
                L(msg)
                if notifyFn then pcall(notifyFn, "状态闸门", msg, "WARN", 8) end
            end
        elseif G.fight then
            G.blockStreakAt = 0
            G.warned = false
        end
    end
    function M.IsFight()
        if not GateEnabled() then return G.rawFight end
        return G.fight
    end
    function M.IsIdle()
        if not GateEnabled() then return (not G.rawFight) and (not G.instant) end
        return (not G.fight) and (not G.active)
    end
    function M.AllowCombat()
        if not GateEnabled() then
            G.stats.allow = G.stats.allow + 1
            return true
        end
        local freshNow = tick()
        if G.now <= 0 or (freshNow - G.now) > 0.5 then
            G.stats.block = G.stats.block + 1
            return false
        end
        if G.fight and G.now >= G.quietUntil then
            G.stats.allow = G.stats.allow + 1
            return true
        end
        G.stats.block = G.stats.block + 1
        return false
    end
    function M.AllowAutoCast(now)
        if not GateEnabled() then return true end
        if G.fight then return false end
        if G.instant then return false end
        if type(now) == "number" and now < G.quietUntil then return false end
        return true
    end
    function M.GetStateName()
        if not GateEnabled() then return "闸门关闭" end
        if G.fight then return (cfg.FishingGateLoose == true) and "搏斗中(兼容)" or "搏斗中" end
        if G.active then return G.hookedBlock and "钓鱼中(残留鱼已忽略)" or "钓鱼中" end
        if G.hookedBlock then return "空闲(残留鱼已忽略)" end
        return "空闲"
    end
    function M.GetBlockedCount() return G.stats.block end
    function M.GetDebugLine()
        return string.format("状态=%s | 旧判定=%s | Minigame=%s 自己的鱼=%s Boss条=%s 面板=%s 猛击钮=%s 鱼线=%s | 放行=%d 拦截=%d 进=%d 出=%d",
            M.GetStateName(), tostring(G.rawFight),
            tostring(snap.attrMinigame), tostring(snap.hooked), tostring(snap.bossBar),
            tostring(snap.fui), tostring(snap.slam), tostring(snap.attrFishing),
            G.stats.allow, G.stats.block, G.stats.enter, G.stats.exit)
    end
    function M.Reset()
        G.fight = false
        G.active = false
        G.instant = false
        G.rawFight = false
        G.lastFightAt = 0
        G.lastActiveAt = 0
        G.quietUntil = 0
        G.blockStreakAt = 0
        G.fightStartAt = 0
        G.lastHardAt = 0
        G.hookedBlock = false
        G.warned = false
        G.reason = "空闲"
        snap.attrFishing, snap.attrMinigame, snap.hooked = false, false, false
        snap.bossBar, snap.fui, snap.slam = false, false, false
        G.stats.allow, G.stats.block, G.stats.enter, G.stats.exit = 0, 0, 0, 0
    end
    return M
end
FishGate = CreateFishingStateGate({ config = Config, log = FLog, notify = ShowNotification })
DashUI._fishGate = FishGate
DashUI._fishGateStatus = function()
    local okLine, line = pcall(FishGate.GetDebugLine)
    if not okLine then return "闸门状态不可用" end
    local okN, n = pcall(FishGate.GetBlockedCount)
    return okN and (tostring(line) .. " ｜ 本局拦截=" .. tostring(n)) or tostring(line)
end
DashUI._fishGateBlocked = function()
    local okN, n = pcall(FishGate.GetBlockedCount)
    return okN and n or 0
end
local fishGateSig = {
    attrFishing = false, attrMinigame = false, hooked = false,
    bossBar = false, fui = false, slam = false, rawFight = false,
}
do
local function BindCharacterAttributes(char)
    if attrCharConn then
        pcall(function() attrCharConn:Disconnect() end)
        attrCharConn = nil
    end
    attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false
    if FishGate then pcall(FishGate.Reset) end
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
            if not attrFishing then
                task.delay(0.15, function()
                    if isRunning and char and char.Parent and not attrFishing and not attrMinigame then
                        local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(char)
                        if not stillHolding and StopLingeringFishingAnimations then
                            StopLingeringFishingAnimations(char)
                        end
                    end
                end)
            end
        elseif name == "CDForTheNextThrow" then
            attrCD = char:GetAttribute("CDForTheNextThrow") == true
        elseif name == "Minigame" then
            attrMinigame = char:GetAttribute("Minigame") == true
            if not attrMinigame then
                task.delay(0.15, function()
                    if isRunning and char and char.Parent and not attrFishing and not attrMinigame then
                        local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(char)
                        if not stillHolding and StopLingeringFishingAnimations then
                            StopLingeringFishingAnimations(char)
                        end
                    end
                end)
            end
        elseif name == "Swimming" then
            attrSwimming = char:GetAttribute("Swimming") == true
        end
    end)
end
local function CacheCharacterParts(char)
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    cachedFishConstraint = nil
    if not char then return end
    local boundHumanoids = setmetatable({}, { __mode = "k" })
    local boundTools = setmetatable({}, { __mode = "k" })
    local boundBackpacks = setmetatable({}, { __mode = "k" })
    local function bindToolUnequip(tool)
        if not tool or not tool:IsA("Tool") then return end
        if boundTools[tool] then return end
        boundTools[tool] = true
        table.insert(characterConnections, tool.Unequipped:Connect(function()
            task.defer(function()
                if isRunning and LocalPlayer and LocalPlayer.Character and StopLingeringFishingAnimations then
                    local curChar = LocalPlayer.Character
                    local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(curChar)
                    if not stillHolding and not attrFishing and not attrMinigame then
                        StopLingeringFishingAnimations(curChar)
                    end
                end
            end)
        end))
    end
    local function bindHumanoidAntiTrip(hum)
        if not hum or boundHumanoids[hum] then return end
        boundHumanoids[hum] = true
        DashUI._ensureHumanoidUpright(hum)
        table.insert(characterConnections, hum.StateChanged:Connect(function(_, newState)
            if not isRunning then return end
            if newState == Enum.HumanoidStateType.FallingDown
                or newState == Enum.HumanoidStateType.Ragdoll
                or newState == Enum.HumanoidStateType.GettingUp then
                task.defer(function()
                    if isRunning and hum and hum.Parent then
                        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
                    end
                end)
            end
        end))
    end
    local initHum = char:FindFirstChildOfClass("Humanoid")
    if initHum then
        bindHumanoidAntiTrip(initHum)
    end
    table.insert(characterConnections, char.ChildAdded:Connect(function(child)
        if child:IsA("Humanoid") then
            bindHumanoidAntiTrip(child)
        end
        if child:IsA("Tool") or child:IsA("Model") then
            cachedHoldingRodTime = 0
            if child:IsA("Tool") then
                bindToolUnequip(child)
            end
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
            task.defer(function()
                if isRunning and char and char.Parent then
                    local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(char)
                    if not stillHolding and not attrFishing and not attrMinigame and StopLingeringFishingAnimations then
                        StopLingeringFishingAnimations(char)
                    end
                end
            end)
        end
    end))
    for _, ch in ipairs(char:GetChildren()) do bindToolUnequip(ch) end
    local function bindBackpackCacheInvalidation(bp)
        if not bp or not bp:IsA("Backpack") then return end
        if boundBackpacks[bp] then return end
        boundBackpacks[bp] = true
        for _, t in ipairs(bp:GetChildren()) do bindToolUnequip(t) end
        table.insert(characterConnections, bp.ChildAdded:Connect(function(newTool)
            cachedHoldingRodTime = 0
            bindToolUnequip(newTool)
        end))
        table.insert(characterConnections, bp.ChildRemoved:Connect(function()
            cachedHoldingRodTime = 0
        end))
    end
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if bp then
        bindBackpackCacheInvalidation(bp)
    end
    table.insert(characterConnections, LocalPlayer.ChildAdded:Connect(function(ch)
        if ch and ch:IsA("Backpack") then
            cachedHoldingRodTime = 0
            bindBackpackCacheInvalidation(ch)
        end
    end))
    table.insert(characterConnections, char.DescendantRemoving:Connect(function(part)
        if cachedFishConstraint == part then cachedFishConstraint = nil end
    end))
end
DashUI._makeUprightCFrame = function(cf)
    if not cf then return nil end
    local pos = cf.Position
    local look = cf.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    if flatLook.Magnitude < 0.001 then
        return CFrame.new(pos)
    end
    return CFrame.lookAt(pos, pos + flatLook.Unit)
end
DashUI._ensureHumanoidUpright = function(hum)
    if not hum or not hum.Parent then return end
    pcall(function()
        RememberHumanoidState(hum)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        hum:SetStateEnabled(Enum.HumanoidStateType.Pushed, false)
        if hum.PlatformStand then
            hum.PlatformStand = false
        end
        if hum.Sit then
            hum.Sit = false
        end
        local st = hum:GetState()
        if st == Enum.HumanoidStateType.FallingDown
            or st == Enum.HumanoidStateType.Ragdoll
            or st == Enum.HumanoidStateType.GettingUp
            or st == Enum.HumanoidStateType.PlatformStanding
            or st == Enum.HumanoidStateType.Seated then
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            hum:ChangeState(Enum.HumanoidStateType.Running)
        end
    end)
end
if LocalPlayer.Character then
    CacheCharacterParts(LocalPlayer.Character)
    BindCharacterAttributes(LocalPlayer.Character)
end
table.insert(activeConnections, LocalPlayer.CharacterAdded:Connect(function(char)
    CacheCharacterParts(char)
    BindCharacterAttributes(char)
end))
end
table.insert(activeConnections, Lighting.Changed:Connect(function()
    if isRunning and (Config.Fullbright or Config.NoFog or Config.PerformanceMode) then
        ApplyLightingSettings()
    end
end))
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
        activeThreads[coroutine.running()] = true
        if not CoreGui then
            FLogWarn("断线重连", "未能获取 CoreGui，跳过断线弹窗监控（其余功能不受影响）")
            return
        end
        local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
        local overlay = promptGui and promptGui:WaitForChild("promptOverlay", 5)
        if overlay and isRunning then
            table.insert(activeConnections, overlay.ChildAdded:Connect(function(child)
                if child and child.Name == "ErrorPrompt" then
                    FLogWarn("断线重连", "检测到 ErrorPrompt 断线弹窗")
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
local activeESP = setmetatable({}, { __mode = "k" })
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
local RemoveESP, ClearDisabledCategoryESP, AddESP, ScanAndMountDynamicESP, RefreshAllESPNow
do (function()
    local espFolder = Instance.new("Folder")
    espFolder.Name = "IdenticalESP"
    espFolder.Parent = screenGui
    table.insert(cleanUpInstances, espFolder)
    local espAnchorFolder = Instance.new("Folder")
    espAnchorFolder.Name = "IdenticalESPAnchors"
    espAnchorFolder.Parent = Workspace
    table.insert(cleanUpInstances, espAnchorFolder)
    local espHighlightFolder = Instance.new("Folder")
    espHighlightFolder.Name = "IdenticalESPHighlights"
    espHighlightFolder.Parent = Workspace
    table.insert(cleanUpInstances, espHighlightFolder)
    local ESP_POOL_SIZE = FSYC.Tunables and FSYC.Tunables.EspPoolSize or 64
    local espPoolWarned = false
    local espSlotPool = {}
    local ESP_CATEGORY_KEYS = {
        GodSpirit = "ESP_GodSpirit",
        Boats     = "ESP_Boats",
        Maoshan   = "ESP_Maoshan",
        Taoist    = "ESP_Taoist",
        DumbGuy   = "ESP_DumbGuy",
        Boss      = "ESP_Boss",
        Players   = "ESP_Players",
    }
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
                {key = "Landmark_Boss_Enzo",   name = "恩佐 (Enzo Boss竞技场)", pos = FSYC.Locations and FSYC.Locations.EnzoArena or Vector3.new(-115.3, 12.2, 1349.5), icon = "👹"},
                {key = "Landmark_Boss_Octo",   name = "无名章鱼寄生体 (隐藏Boss)", pos = FSYC.Locations and FSYC.Locations.OctoParasite or Vector3.new(1608.2, 8.0, -218.3), icon = "🐙"},
                {key = "Landmark_Boss_Dragon", name = "龙钓海 Boss挑战区", pos = FSYC.Locations and FSYC.Locations.DragonSea or Vector3.new(2745.2, 13.6, -79.4), icon = "🐉"},
            }
        },
    }
    local staticLandmarkAnchors = {}
    for _, group in pairs(ESP_STATIC_LANDMARKS) do
        for _, lm in ipairs(group.items) do
            local p = Instance.new("Part")
            p.Name = lm.key
            p.Size = Vector3.new(1, 1, 1)
            p.Transparency = 1
            p.CanCollide = false
            p.CanQuery = false
            p.CanTouch = false
            p.Anchored = true
            p.Position = lm.pos
            p.Parent = espAnchorFolder
            staticLandmarkAnchors[lm.key] = p
        end
    end
    for i = 1, ESP_POOL_SIZE do
        local proxyPart = Instance.new("Part")
        proxyPart.Name = "ESPProxyAnchor_" .. i
        proxyPart.Size = Vector3.new(1, 1, 1)
        proxyPart.Transparency = 1
        proxyPart.CanCollide = false
        proxyPart.CanQuery = false
        proxyPart.CanTouch = false
        proxyPart.Anchored = true
        proxyPart.Position = Vector3.new(0, -5000, 0)
        proxyPart.Parent = espAnchorFolder
        local bb = Instance.new("BillboardGui")
        bb.Name = "ESPSlot_" .. i
        bb.Size = UDim2.new(0, 175, 0, 26)
        bb.StudsOffset = Vector3.new(0, 3.0, 0)
        bb.AlwaysOnTop = true
        bb.MaxDistance = math.huge
        bb.Enabled = false
        bb.Adornee = nil
        bb.Parent = espFolder
        local f = Instance.new("Frame", bb)
        f.Size = UDim2.new(1, 0, 1, 0)
        f.BackgroundColor3 = Colors.Background
        f.BackgroundTransparency = 0.15
        f.Visible = false
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 5)
        local s = Instance.new("UIStroke", f)
        s.Color = Colors.Accent
        s.Thickness = 1.4
        local lbl = Instance.new("TextLabel", f)
        lbl.Size = UDim2.new(1, -8, 1, 0)
        lbl.Position = UDim2.new(0, 4, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamBold
        lbl.Text = ""
        lbl.TextColor3 = Colors.TextWhite
        lbl.TextSize = 11
        lbl.TextTruncate = Enum.TextTruncate.AtEnd
        local hl = Instance.new("Highlight")
        hl.Name = "ESPHighlightSlot_" .. i
        hl.FillColor = Colors.Accent
        hl.OutlineColor = Colors.TextWhite
        hl.FillTransparency = 0.65
        hl.OutlineTransparency = 0.05
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Enabled = false
        hl.Adornee = nil
        hl.Parent = espHighlightFolder
        espSlotPool[i] = {
            inUse = false,
            gui = bb,
            frame = f,
            stroke = s,
            label = lbl,
            highlight = hl,
            proxyPart = proxyPart,
            part = nil,
            isProxyPart = false,
            isLandmarkAnchor = false,
            espCategory = nil,
            name = "",
            icon = "",
            lastDist = -1,
        }
    end
    local function AcquireESPSlot()
        for i = 1, ESP_POOL_SIZE do
            local slot = espSlotPool[i]
            if not slot.inUse then
                slot.inUse = true
                slot.lastDist = -1
                return slot
            end
        end
        return nil
    end
    local function DisableESPSlot(data)
        if not data then return end
        data.inUse = false
        data.part = nil
        data.isProxyPart = false
        data.isLandmarkAnchor = false
        data.espCategory = nil
        data.lastDist = -1
        if data.frame and data.frame.Parent then
            pcall(function() data.frame.Visible = false end)
        end
        if data.gui and data.gui.Parent then
            pcall(function()
                data.gui.Enabled = false
                data.gui.Adornee = nil
            end)
        end
        if data.highlight and data.highlight.Parent then
            pcall(function()
                data.highlight.Enabled = false
                data.highlight.Adornee = nil
            end)
        end
    end
    SweepOrphanSlots = function()
        for i = 1, #espSlotPool do
            local slot = espSlotPool[i]
            if slot.inUse then
                local ad = slot.gui and slot.gui.Adornee
                if not slot.gui or not slot.gui.Parent or not ad or not ad.Parent then
                    DisableESPSlot(slot)
                end
            end
        end
    end
    DashUI._sweepOrphanSlots = SweepOrphanSlots
    RemoveESP = function(instance)
        local data = instance and activeESP[instance] or nil
        if data then activeESP[instance] = nil end
        if data then DisableESPSlot(data) end
    end
    ClearDisabledCategoryESP = function(targetCategory)
        for inst, data in pairs(activeESP) do
            if data then
                local cat = data.espCategory
                local cfgKey = ESP_CATEGORY_KEYS[cat]
                local isCatEnabled = cfgKey and (Config[cfgKey] == true) or false
                if (targetCategory and cat == targetCategory and not isCatEnabled) or (not targetCategory and not isCatEnabled) then
                    RemoveESP(inst)
                end
            end
        end
        for i = 1, #espSlotPool do
            local slot = espSlotPool[i]
            if slot.inUse then
                local key = slot.espCategory and ESP_CATEGORY_KEYS[slot.espCategory] or nil
                if not (key and Config[key] == true) then
                    DisableESPSlot(slot)
                end
            end
        end
        SweepOrphanSlots()
    end
    local function ResolveHighlightAdornee(inst)
        if typeof(inst) ~= "Instance" then return nil end
        if inst:IsA("Model") or inst:IsA("BasePart") then return inst end
        local ok, sub = pcall(function() return inst:FindFirstChildWhichIsA("BasePart", true) end)
        if ok and sub then return sub end
        return nil
    end
    local espSeqCounter = 0
    AddESP = function(instance, name, espCategory, color, icon, fallbackPos, isLandmarkAnchor)
        if not instance then return end
        local cfgKey = ESP_CATEGORY_KEYS[espCategory]
        local isEnabledNow = cfgKey and (Config[cfgKey] == true) or false
        if not isEnabledNow then
            if activeESP[instance] then RemoveESP(instance) end
            return
        end
        local existing = activeESP[instance]
        if existing then
            if existing.espCategory ~= espCategory or not existing.gui or not existing.gui.Parent then
                RemoveESP(instance)
            else
                existing.name = name
                existing.icon = icon or ""
                if fallbackPos and existing.isProxyPart and existing.part and existing.part.Parent then
                    existing.part.Position = fallbackPos
                end
                if existing.isProxyPart and typeof(instance) == "Instance" then
                    local realPart = nil
                    if instance:IsA("Model") then
                        realPart = instance:FindFirstChild("HumanoidRootPart", true) or instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
                    elseif instance:IsA("BasePart") then
                        realPart = instance
                    else
                        realPart = instance:FindFirstChildWhichIsA("BasePart", true)
                    end
                    if realPart and realPart.Parent then
                        existing.part = realPart
                        existing.isProxyPart = false
                        if existing.gui then existing.gui.Adornee = realPart end
                    end
                end
                if existing.highlight and existing.highlight.Parent and not existing.isProxyPart and not existing.isLandmarkAnchor then
                    local hlTarget = ResolveHighlightAdornee(instance)
                    if hlTarget then
                        if existing.highlight.Adornee ~= hlTarget then existing.highlight.Adornee = hlTarget end
                        if not existing.highlight.Enabled then existing.highlight.Enabled = true end
                    end
                end
                return
            end
        end
        local slot = AcquireESPSlot()
        if not slot then
            local oldestInst, oldestSeq = nil, nil
            for existInst, existData in pairs(activeESP) do
                if existData and existData.inUse then
                    local seqNow = existData.seq or 0
                    if not oldestSeq or seqNow < oldestSeq then
                        oldestInst, oldestSeq = existInst, seqNow
                    end
                end
            end
            if oldestInst then
                RemoveESP(oldestInst)
                slot = AcquireESPSlot()
            end
            if not espPoolWarned then
                espPoolWarned = true
                FLogWarn("ESP", string.format("ESP 槽位池已满(%d)，已改为覆盖最旧的标记目标；可减少同时开启的 ESP 类别", ESP_POOL_SIZE))
            end
            if not slot then return end
        end
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
            if pos and slot.proxyPart and slot.proxyPart.Parent then
                slot.proxyPart.Position = pos
                part = slot.proxyPart
                isProxyPart = true
            end
        end
        if not part then
            slot.inUse = false
            return
        end
        local targetColor = color or Colors.Accent
        slot.part = part
        slot.isProxyPart = isProxyPart
        slot.isLandmarkAnchor = (isLandmarkAnchor == true)
        slot.espCategory = espCategory
        slot.name = name
        slot.icon = icon or ""
        slot.lastDist = -1
        slot.stroke.Color = targetColor
        slot.label.Text = (icon or "") .. " " .. tostring(name)
        slot.label.TextColor3 = color or Colors.TextWhite
        slot.frame.Visible = true
        slot.gui.Adornee = part
        slot.gui.Enabled = true
        local hlAdornee = (not isProxyPart and not isLandmarkAnchor) and ResolveHighlightAdornee(instance) or nil
        if hlAdornee then
            pcall(function()
                slot.highlight.FillColor = targetColor
                slot.highlight.Adornee = hlAdornee
                slot.highlight.Enabled = true
            end)
        else
            pcall(function()
                slot.highlight.Enabled = false
                slot.highlight.Adornee = nil
            end)
        end
        espSeqCounter = espSeqCounter + 1
        slot.seq = espSeqCounter
        activeESP[instance] = slot
    end
    local function MountEnabledStaticLandmarks()
        for cat, group in pairs(ESP_STATIC_LANDMARKS) do
            local cfgKey = ESP_CATEGORY_KEYS[cat]
            if cfgKey and Config[cfgKey] == true then
                for _, lm in ipairs(group.items) do
                    local anchor = staticLandmarkAnchors[lm.key]
                    if anchor and anchor.Parent then
                        AddESP(anchor, lm.name, cat, group.color, lm.icon, lm.pos, true)
                    end
                end
            end
        end
    end
    task.spawn(function()
        task.wait(0.2)
        if isRunning and DismissStuckPromptsAndRestore then
            DismissStuckPromptsAndRestore(true)
        end
    end)
    local function ESPFallbackPosFor(inst)
        local entry = activeESP[inst]
        if entry and not entry.isProxyPart then return nil end
        return GetNPCPosition(inst)
    end
    ScanAndMountDynamicESP = function()
        MountEnabledStaticLandmarks()
        if Config.ESP_Players then
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer then
                    local pChar = p.Character or Workspace:FindFirstChild(p.Name)
                    if pChar then
                        AddESP(pChar, p.DisplayName or p.Name, "Players", Colors.Accent, "👤", ESPFallbackPosFor(pChar))
                    end
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
        for _, key in ipairs(liveNPCOrder) do
            local entry = liveNPCs[key]
            if entry and entry.inst and entry.inst.Parent then
                if key:find("^Spirit_") then
                    if Config.ESP_GodSpirit then
                        AddESP(entry.inst, entry.name, "GodSpirit", Colors.AccentGreen, entry.icon, entry.pos)
                    end
                elseif key == "Taoist" then
                    if Config.ESP_Taoist then
                        AddESP(entry.inst, entry.name, "Taoist", Colors.AccentOrange, entry.icon, entry.pos)
                    end
                elseif key == "DumbGuy" then
                    if Config.ESP_DumbGuy then
                        AddESP(entry.inst, entry.name, "DumbGuy", Colors.AccentYellow, entry.icon, entry.pos)
                    end
                elseif key == "Maoshan" then
                    if Config.ESP_Maoshan then
                        AddESP(entry.inst, entry.name, "Maoshan", Colors.AccentSoft, entry.icon, entry.pos)
                    end
                else
                    if Config.ESP_Boss then
                        AddESP(entry.inst, entry.name, "Boss", Colors.AccentRed, entry.icon, entry.pos)
                    end
                end
            end
        end
    end
    local playerESPConns = setmetatable({}, { __mode = "k" })
    local function bindPlayerESPChar(p)
        if p == LocalPlayer or playerESPConns[p] then return end
        local conn = p.CharacterAdded:Connect(function(newChar)
            if not isRunning or not Config.ESP_Players then return end
            task.delay(0.25, function()
                if isRunning and Config.ESP_Players and newChar and newChar.Parent then
                    AddESP(newChar, p.DisplayName or p.Name, "Players", Colors.Accent, "👤", GetNPCPosition(newChar))
                end
            end)
        end)
        playerESPConns[p] = conn
        table.insert(activeConnections, conn)
    end
    for _, p in ipairs(Players:GetPlayers()) do bindPlayerESPChar(p) end
    table.insert(activeConnections, Players.PlayerAdded:Connect(bindPlayerESPChar))
    table.insert(activeConnections, Players.PlayerRemoving:Connect(function(p)
        local conn = playerESPConns[p]
        if conn then
            playerESPConns[p] = nil
            pcall(function() conn:Disconnect() end)
            local deadIdx = table.find(activeConnections, conn)
            if deadIdx then table.remove(activeConnections, deadIdx) end
        end
    end))
    RefreshAllESPNow = function(toggledCategory, toggledState, labelTitle)
        if toggledCategory and toggledState == false then
            ClearDisabledCategoryESP(toggledCategory)
        end
        if toggledCategory and toggledState == true then
            if DashUI._runRadarPassNow and (toggledCategory == "GodSpirit" or toggledCategory == "Maoshan" or toggledCategory == "Taoist" or toggledCategory == "DumbGuy" or toggledCategory == "Boss") then
                pcall(DashUI._runRadarPassNow)
            end
            pcall(ScanAndMountDynamicESP)
        end
        if SweepOrphanSlots then pcall(SweepOrphanSlots) end
        local anyESP = Config.ESP_GodSpirit or Config.ESP_Boats
            or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_DumbGuy or Config.ESP_Boss or Config.ESP_Players
        if not anyESP then
            ClearDisabledCategoryESP(nil)
            return
        end
        if next(activeESP) == nil and not (toggledCategory and toggledState == true) then
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
            if typeof(inst) ~= "Instance" or not inst.Parent or not isEnabled then
                RemoveESP(inst)
            else
                if data.isProxyPart and not data.isLandmarkAnchor then
                    local realPart = nil
                    if inst:IsA("Model") then
                        realPart = inst:FindFirstChild("HumanoidRootPart", true) or inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
                    elseif not inst:IsA("BasePart") then
                        realPart = inst:FindFirstChildWhichIsA("BasePart", true)
                    end
                    if realPart and realPart.Parent then
                        data.part = realPart
                        data.isProxyPart = false
                        if data.gui then data.gui.Adornee = realPart end
                        if data.highlight and data.highlight.Parent and not data.isLandmarkAnchor then
                            local hlTarget = ResolveHighlightAdornee(inst)
                            if hlTarget then
                                data.highlight.Adornee = hlTarget
                                data.highlight.Enabled = true
                            end
                        end
                    elseif data.part and data.part.Parent then
                        local latestPos = GetNPCPosition(inst)
                        if latestPos then data.part.Position = latestPos end
                    end
                elseif not data.part or not data.part.Parent then
                    local fallbackPos = GetNPCPosition(inst)
                    if fallbackPos and data.proxyPart and data.proxyPart.Parent then
                        data.proxyPart.Position = fallbackPos
                        data.part = data.proxyPart
                        data.isProxyPart = true
                        if data.gui then data.gui.Adornee = data.proxyPart end
                    else
                        RemoveESP(inst)
                    end
                end
                if activeESP[inst] and data.part and data.part.Parent then
                    if data.gui and not data.gui.Enabled then data.gui.Enabled = true end
                    if data.frame and not data.frame.Visible then data.frame.Visible = true end
                    if data.highlight and data.highlight.Parent and not data.isProxyPart and not data.isLandmarkAnchor then
                        if not data.highlight.Adornee then
                            local hlTarget = ResolveHighlightAdornee(inst)
                            if hlTarget then data.highlight.Adornee = hlTarget end
                        end
                        if not data.highlight.Enabled then data.highlight.Enabled = true end
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
end)() end
DashUI._refreshESPNow = RefreshAllESPNow
local function IdenticalStartRuntimeLoops()
local lastSellTime = 0
local lastFullBagSellTime = 0
local lastDailyTime = 0
local dailyMissingWarned = false
local lastFullBagWarnTime = 0
DashUI._resetSellTimer = function()
    lastSellTime = tick()
end
local lastHookScanTime = 0
local cachedIsHooked = false
local cachedHookedPos = nil
local cachedHookedFish = nil
local wasInMinigame = false
local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)
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
    if not IsInstanceValid(Events) then
        Events = FSYC.ResolveEventsFolder and FSYC.ResolveEventsFolder(ReplicatedStorage, 0)
            or (ReplicatedStorage and ReplicatedStorage:FindFirstChild("Events")) or nil
        table.clear(cachedEventRemotes)
    end
    if not Events then return nil end
    local r = cachedEventRemotes[name]
    if r and r.Parent == Events then
        return r
    end
    r = Events:FindFirstChild(name)
    cachedEventRemotes[name] = r
    return r
end
local function SafeFireEventRemote(nameOrInst, ...)
    local rem = (typeof(nameOrInst) == "Instance") and nameOrInst or GetEventRemote(nameOrInst)
    if rem and rem.Parent and rem:IsA("RemoteEvent") then
        if not PacketGuard.Allow(rem, ...) then return false end
        local ok, err = pcall(rem.FireServer, rem, ...)
        PacketGuard.RecordResult(rem, ok, err)
        if not ok then FLogWarn("远程调用", tostring(rem.Name) .. " FireServer 异常: " .. tostring(err)) end
        return ok
    end
    return false
end
DashUI._safeFireRemote = function(nameOrInst, ...) return SafeFireEventRemote(nameOrInst, ...) end
DashUI._eventRemote = function(name) return GetEventRemote(name) end
local function SafeFireEventCombat(nameOrInst, ...)
    if not FishGate.AllowCombat() then return false end
    PacketGuard.combat = true
    local callOk, sent = pcall(SafeFireEventRemote, nameOrInst, ...)
    PacketGuard.combat = false
    if not callOk then return false end
    return sent
end
DashUI._safeFireCombat = function(nameOrInst, ...) return SafeFireEventCombat(nameOrInst, ...) end
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
local nextCastAt = 0
local nextBaitBuyAt = 0
local nextMonkeyAt = 0
local nextGodPrayAt = 0
local nextCraftAt = 0
local nextGachaAt = 0
local nextProtectAt = 0
local nextFishBtnRestoreAt = 0
local nextQteAt = 0
local nextBossPromptAt = 0
local nextProgressionAt = 0
local nextSlamAt = 0
local nextRhythmAt = 0
DashUI._onAutoCastDisabled = function()
    nextCastAt = tick() + (tonumber(Config.CastDelay) or 1.0)
end
local function BindManualFishButtonFallback(btn)
    if not btn or hookedManualFishBtns[btn] then return end
    hookedManualFishBtns[btn] = true
    pcall(function()
        InputRouter.BindHudClick(btn, function()
            if not isRunning or Config.AutoCast then return end
            task.delay(HRand(0.15, 0.12), function()
                if not isRunning or Config.AutoCast or isMicroTeleportingNPC or isSellingInProgress or (FSYC.monkeyCtl and FSYC.monkeyCtl.running) then return end
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not char or not root then return end
                local isFishingNow = attrFishing
                local isMiniNow = attrMinigame or cachedIsHooked
                if not isFishingNow and not isMiniNow and not attrCD and not attrSwimming and FishGate.AllowAutoCast(tick())
                    and IsCharacterHoldingFishingRod(char, GetPlayerData()) then
                    SafeFireEventRemote("Fishing", root.CFrame)
                end
            end)
        end, true)
    end)
end
local function GetMobileFishingButton(now)
    now = now or tick()
    if cachedMobileFishBtn and cachedMobileFishBtn.Parent then
        return cachedMobileFishBtn
    end
    if cachedMobileFishBtn then
        FLog("钓鱼按钮", "缓存的钓鱼按钮已失效（被游戏销毁/重建），1.5s 后重扫")
        cachedMobileFishBtn = nil
        local rescanDelay = 1.5
        lastMobileFishBtnScan = math.min(lastMobileFishBtnScan, now - 10.0 + rescanDelay)
    end
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
            local isMenu = gn:find("inventory") or gn:find("shop")
                or gn:find("bag") or gn:find("index")
                or gn:find("quest") or gn:find("setting")
                or gn:find("store") or gn:find("catalog")
            if not isMenu then
                if gn == "maingui" then
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
                        txt = tqLc(d.Text or ""):match("^%s*(.-)%s*$")
                    end
                    if txt == "" then
                        local lbl = d:FindFirstChildWhichIsA("TextLabel", true)
                        if lbl then txt = tqLc(lbl.Text or ""):match("^%s*(.-)%s*$") end
                    end
                    if txt == "" and d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X < 220 then
                        for _, sib in ipairs(d.Parent:GetChildren()) do
                            if sib:IsA("TextLabel") then
                                local st = tqLc(sib.Text or ""):match("^%s*(.-)%s*$")
                                if st ~= "" then txt = st; break end
                            end
                        end
                    end
                    local dn = tqLc(d.Name or "")
                    local pn = tqLc(d.Parent and d.Parent.Name or "")
                    if txt:find("自动钓鱼", 1, true) or txt:find("auto fish", 1, true)
                        or txt:find("tự động câu", 1, true) or txt:find("cau ca tu dong", 1, true)
                        or dn:find("autofish", 1, true) or pn:find("autofish", 1, true) then
                        cachedAutoFishBtn = d
                    elseif (txt == "钓鱼" or txt == "抛竿" or txt == "fish" or txt == "câu cá" or txt == "câu" or txt == "quăng câu"
                        or dn == "fishbutton" or dn == "fishingbutton" or dn == "castbutton" or pn == "fishbutton" or pn == "fishingbutton"
                        or dn == "fishing" or dn == "fish")
                        and not txt:find("自动", 1, true) and not txt:find("auto", 1, true) and not txt:find("tự động", 1, true)
                        and not dn:find("auto", 1, true) and not pn:find("auto", 1, true) then
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
RestoreMobileFishingButtonUI = function(forceRefreshGui)
    if not Config.ForceFishBtn then return false end
    local fishBtn = GetMobileFishingButton(tick())
    if not fishBtn or not fishBtn.Parent then return false end
    pcall(function()
        if fishBtn.Visible ~= true then fishBtn.Visible = true end
        if fishBtn.Active ~= true then fishBtn.Active = true end
        local par = fishBtn.Parent
        if par and par ~= cachedMainGui and par:IsA("GuiObject") and par.Visible ~= true then
            par.Visible = true
        end
    end)
    if sharedEnv then
        sharedEnv.IdenticalProtectedFishBtn = fishBtn
        sharedEnv.IdenticalKeepFishBtnVisible = true
    end
    return true
end
local function IsGuiHierarchyVisible(guiObj, stopAt)
    local cur, depth = guiObj, 0
    while cur and cur ~= stopAt and depth < 16 do
        if cur:IsA("GuiObject") then
            if not cur.Visible then return false end
        elseif cur:IsA("ScreenGui") then
            if not cur.Enabled then return false end
        end
        cur = cur.Parent
        depth = depth + 1
    end
    return true
end
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
    local function FindGuiByKeywords(root, keywords, maxDepth)
        if not root then return nil end
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("GuiObject") then
                local ln = string.lower(d.Name)
                for i = 1, #keywords do
                    if string.find(ln, keywords[i], 1, true) then return d end
                end
            end
        end
        return nil
    end
    cachedBossBar = cachedFUI and (cachedFUI:FindFirstChild("BossFightBar")
        or FindGuiByKeywords(cachedFUI, {"bossfightbar", "bossbar"})
        or FindGuiByKeywords(cachedFUI, {"boss"}))
    local barFrame = cachedFUI and cachedFUI:FindFirstChild("BarFrame")
    cachedBarInner = barFrame and barFrame:FindFirstChild("Bar")
    cachedBossBarInner = cachedBossBar and (cachedBossBar:FindFirstChild("Bar")
        or FindGuiByKeywords(cachedBossBar, {"cursor", "marker", "indicator", "needle", "pointer", "moving", "bar"}))
    cachedBossHitbox = cachedBossBar and (cachedBossBar:FindFirstChild("Hitbox") or cachedBossBar:FindFirstChild("GreenZone")
        or cachedBossBar:FindFirstChild("Target")
        or FindGuiByKeywords(cachedBossBar, {"hitbox", "green", "zone", "perfect", "good", "target", "hit"}))
    local hpPlayer = cachedFUI and cachedFUI:FindFirstChild("HPPlayer")
    local progBar = hpPlayer and hpPlayer:FindFirstChild("ProgressionBar")
    cachedProgBarInner = progBar and progBar:FindFirstChild("Bar")
    local fUIPerf = cachedFUI and cachedFUI:FindFirstChild("PerfectButton")
    if fUIPerf and fUIPerf.Visible then
        cachedPerfectBtn = fUIPerf
    elseif cachedPerfectBtn and not cachedPerfectBtn.Parent then
        cachedPerfectBtn = nil
    end
    cachedChargeBtn = cachedFUI and cachedFUI:FindFirstChild("Charge")
    local cutscene = cachedMainGui and cachedMainGui:FindFirstChild("Cutscene")
    cachedHurt1 = cutscene and cutscene:FindFirstChild("Hurt")
    local impactGui = cachedPG and cachedPG:FindFirstChild("Impact")
    local impactCutscene = impactGui and impactGui:FindFirstChild("Cutscene")
    cachedHurt2 = impactCutscene and impactCutscene:FindFirstChild("Hurt")
    return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
end
local RealBoss = {
    active = false,
    index = 0,
    hits = 0,
    confirmed = 0,
    sent = 0,
    minGap = 0.25,
    startedAt = 0,
    nextAt = 0,
    pendingAt = 0,
    pendingIdx = 0,
    uiAt = 0,
    lastAnyAt = 0,
}
local REALBOSS_HARD_GAP = FSYC.Tunables and FSYC.Tunables.RealBossHardGapSec or 0.50
local REALBOSS_MAX_SENDS = FSYC.Tunables and FSYC.Tunables.RealBossMaxSends or 200
local REALBOSS_MAX_DURATION = FSYC.Tunables and FSYC.Tunables.RealBossMaxDurationSec or 200
RealBoss.failStreak = 0
RealBossDeactivate = function(reason)
    if RealBoss.active and FLog then
        local dur = math.max(0.1, tick() - (RealBoss.startedAt or tick()))
        local rate = (RealBoss.hits or 0) / dur
        pcall(FLog, "Boss/真实命中", string.format("第二阶段结束(%s)：命中 %d 次 / %.1f 秒 = %.2f 次/秒（真人≈0.84）",
            tostring(reason), RealBoss.hits or 0, dur, rate))
        if rate > 1.3 then
            pcall(FLogWarn, "Boss/真实命中", "本阶段命中速率超过真人（0.84 次/秒）的 1.5 倍，若被踢/封请立刻把「命中节拍」调到 0.95~1.20s 或直接关掉本功能")
        end
    end
    RealBoss.active = false
    RealBoss.pendingIdx = 0
    RealBoss.failStreak = 0
end
DashUI._realBossDeactivate = RealBossDeactivate
local function RealBossActivate(setup)
    RealBoss.active = true
    RealBoss.index = 0
    RealBoss.hits = 0
    RealBoss.confirmed = 0
    RealBoss.sent = 0
    RealBoss.startedAt = tick()
    RealBoss.nextAt = RealBoss.startedAt + REALBOSS_HARD_GAP
    RealBoss.pendingIdx = 0
    RealBoss.sawBar = false
    local gap = 0.25
    if type(setup) == "table" then
        local ok, v = pcall(function() return tonumber(setup.MinGap) end)
        if ok and v and v > 0 then gap = v end
    end
    RealBoss.minGap = gap
    local wantGap = tonumber(Config.RealBossGap) or 0.75
    if wantGap < gap + 0.10 then wantGap = gap + 0.10 end
    local hardFloor = 0.30
    if wantGap < hardFloor then wantGap = hardFloor end
    Config.RealBossGap = wantGap
    if FLog then pcall(FLog, "Boss/真实命中",
        string.format("第二阶段开始：服务端MinGap=%.2fs，生效间隔=%.2fs（真人实测均值1.19s/最快0.51s，单阶段上限%d包）",
            gap, wantGap, REALBOSS_MAX_SENDS)) end
end
local function RealBossOnDamage()
    if not RealBoss.active then return end
    if RealBoss.pendingIdx <= 0 then return end
    if (tick() - RealBoss.pendingAt) > 1.0 then return end
    RealBoss.confirmed = RealBoss.confirmed + 1
    RealBoss.pendingIdx = 0
end
local function RealBossRefreshUI(now)
    if (now - RealBoss.uiAt) < 0.5 then return end
    RealBoss.uiAt = now
    local row = DashUI.infoBossHit
    if row and row.Set then
        if RealBoss.active then
            row.Set(string.format("命中 %d · 已确认 %d · 序号 %d", RealBoss.hits, RealBoss.confirmed, RealBoss.index))
        else
            row.Set(string.format("上次：命中 %d / 确认 %d", RealBoss.hits, RealBoss.confirmed))
        end
    end
end
local function RealBossStep(now)
    if not RealBoss.active then return end
    if not Config.RealBossHit then RealBossDeactivate("开关关闭"); return end
    if not isRunning then return end
    if not FishGate.AllowCombat() then return end
    if RealBoss.sent >= REALBOSS_MAX_SENDS then RealBossDeactivate("超出单阶段上限"); return end
    if (now - RealBoss.startedAt) > REALBOSS_MAX_DURATION then RealBossDeactivate("超时"); return end
    local bossBar = cachedBossBar
    if not (bossBar and bossBar.Parent and bossBar.Visible) then
        if RealBoss.sawBar then RealBossDeactivate("判定条消失") end
        return
    end
    RealBoss.sawBar = true
    local marker = cachedBossBarInner
    local zone = cachedBossHitbox
    if not (marker and marker.Parent and zone and zone.Parent) then
        RealBoss.noNodeSince = RealBoss.noNodeSince or now
        if (now - RealBoss.noNodeSince) >= 2.5 and not RealBoss.nodeWarned then
            RealBoss.nodeWarned = true
            local names = {}
            pcall(function()
                for _, d in ipairs(cachedBossBar:GetDescendants()) do
                    if d:IsA("GuiObject") and #names < 12 then
                        names[#names + 1] = d.Name .. "(" .. d.ClassName .. ")"
                    end
                end
            end)
            FLogWarn("Boss/读条", "判定条可见但找不到 Bar/Hitbox 节点，读条模式不会发包。"
                .. "当前 BossFightBar 子节点: " .. table.concat(names, ", "))
            pcall(ShowNotification, "⚠ 读条模式未生效",
                "找不到 BossFightBar 的 Bar/Hitbox 节点，本阶段不会自动命中。可先改用激进模式，或把日志里的节点名发给我。", "WARN", 8)
        end
        return
    end
    RealBoss.noNodeSince = 0
    if now < RealBoss.nextAt then return end
    local inZone = false
    local okGeo = pcall(function()
        local mx = marker.AbsolutePosition.X
        local mw = marker.AbsoluteSize.X
        local zx = zone.AbsolutePosition.X
        local zw = zone.AbsoluteSize.X
        if mw < 1 then mw = 1 end
        if zw < 1 then zw = 1 end
        inZone = (mx < (zx + zw)) and ((mx + mw) > zx)
    end)
    if not okGeo then return end
    local wantGap = tonumber(Config.RealBossGap) or 0.50
    local gap = wantGap
    local hardFloor = 0.30
    if gap < hardFloor then gap = hardFloor end
    local forcedMiss = false
    if Config.RealBossForce then
        local rate = tonumber(Config.RealBossHitRate) or 85
        if rate < 1 then rate = 1 elseif rate > 100 then rate = 100 end
        if rate >= 100 or math.random(1, 100) <= rate then
            inZone = true
        else
            inZone = false
            forcedMiss = true
        end
    end
    if inZone then
        local nextIdx = RealBoss.index + 1
        local okFire = SafeFireEventCombat("BossPhase2Action", { Index = nextIdx, Hit = true })
        if okFire == false then
            RealBoss.failStreak = (RealBoss.failStreak or 0) + 1
            local retryBase = FSYC.Tunables and FSYC.Tunables.RealBossRetryBaseSec or 0.08
            local retryMax = FSYC.Tunables and FSYC.Tunables.RealBossRetryMaxSec or 1.00
            RealBoss.nextAt = now + math.min(retryBase * (2 ^ (RealBoss.failStreak - 1)), retryMax)
        else
            RealBoss.failStreak = 0
            RealBoss.index = nextIdx
            RealBoss.hits = RealBoss.hits + 1
            RealBoss.sent = RealBoss.sent + 1
            RealBoss.pendingIdx = nextIdx
            RealBoss.pendingAt = now
            RealBoss.lastAnyAt = now
            RealBoss.nextAt = now + gap + math.random() * 0.06
        end
    elseif forcedMiss then
        local okMiss = SafeFireEventCombat("BossPhase2Action", { Hit = false })
        if okMiss ~= false then
            RealBoss.sent = RealBoss.sent + 1
            RealBoss.pendingIdx = 0
            RealBoss.lastAnyAt = now
        end
        RealBoss.nextAt = now + gap + math.random() * 0.06
    else
        local missInterval = FSYC.Tunables and FSYC.Tunables.RealBossMissHeartbeatSec or 2.5
        local retryBase = FSYC.Tunables and FSYC.Tunables.RealBossRetryBaseSec or 0.08
        if (now - RealBoss.lastAnyAt) >= missInterval then
            local okMiss = SafeFireEventCombat("BossPhase2Action", { Hit = false })
            if okMiss ~= false then
                RealBoss.sent = RealBoss.sent + 1
                RealBoss.pendingIdx = 0
                RealBoss.lastAnyAt = now
                RealBoss.failStreak = 0
            else
                RealBoss.failStreak = (RealBoss.failStreak or 0) + 1
            end
        end
        RealBoss.nextAt = now + retryBase
    end
    RealBossRefreshUI(now)
end
local SKILL_KEYS = {"Z", "X", "C", "V"}
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
local function GetCachedSkillButton(sk, now)
    local btn = cachedSkillButtons[sk]
    if btn and btn.Parent and btn.Visible and btn.AbsoluteSize.X > 5 then
        return btn
    end
    if now - lastSkillBtnScanTime < 4.0 then return nil end
    lastSkillBtnScanTime = now
    for k, oldBtn in pairs(cachedSkillButtons) do
        if not oldBtn or not oldBtn.Parent then
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
local function GetSkillButtonRef(slot)
    local btn = cachedSkillButtons[slot]
    if btn and btn.Parent then return btn end
    return nil
end
local function DoesTextMatchSlam(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return false end
    local t = tqLc(rawStr):gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
    if t == "" then return false end
    local tNoSpace = t:gsub("%s+", "")
    if tNoSpace == "f" or tNoSpace == "[f]" or tNoSpace == "(f)" or tNoSpace == "keyf"
        or tNoSpace:find("猛击", 1, true) or tNoSpace:find("按下f", 1, true) or tNoSpace:find("按f", 1, true)
        or tNoSpace:find("进行猛击", 1, true) or tNoSpace:find("转机", 1, true) or tNoSpace:find("暴击", 1, true)
        or tNoSpace:find("slam", 1, true) or tNoSpace:find("perfect", 1, true)
        or tNoSpace:find("pressf", 1, true) or tNoSpace:find("tapto", 1, true)
        or tNoSpace:find("nhấnf", 1, true) or tNoSpace:find("bấmf", 1, true)
        or tNoSpace:find("nhanf", 1, true) or tNoSpace:find("bamf", 1, true)
        or tNoSpace:find("đập", 1, true) or tNoSpace:find("nện", 1, true) then
        return true
    end
    return false
end
local function CheckLabelMatchesSlam(lbl)
    if not lbl or not lbl.Visible then return false end
    if (lbl:IsA("TextLabel") or lbl:IsA("TextButton")) and lbl.TextTransparency < 0.96 then
        if DoesTextMatchSlam(lbl.Text) then return true end
        local okLoc, locTxt = pcall(function() return lbl.LocalizedText end)
        if okLoc and DoesTextMatchSlam(locTxt) then return true end
        local okCnt, cntTxt = pcall(function() return lbl.ContentText end)
        if okCnt and DoesTextMatchSlam(cntTxt) then return true end
    end
    return false
end
local function IsSlamGuiCandidate(d)
    if not d or not d:IsA("GuiObject") or not d.Visible or d.AbsoluteSize.X <= 8 or d.AbsoluteSize.Y <= 8 then
        return false
    end
    if d.AbsoluteSize.X > 320 or d.AbsoluteSize.Y > 320 then
        return false
    end
    local dn = (d.Name or ""):lower():gsub("%s+", "")
    if dn:find("close", 1, true) or dn:find("cancel", 1, true) or dn:find("exit", 1, true) or dn:find("fsy", 1, true) then
        return false
    end
    if dn == "perfectbutton" or dn == "slambutton" or dn == "slam" or dn == "f" or dn == "keyf" or dn == "skillf" or dn == "btnf" or dn == "qtebutton" or dn == "actionf"
        or dn:find("perfect", 1, true) or dn:find("slam", 1, true) then
        return true
    end
    if CheckLabelMatchesSlam(d) then return true end
    for _, ch in ipairs(d:GetChildren()) do
        if CheckLabelMatchesSlam(ch) then return true end
    end
    if d:IsA("GuiButton") and d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X > 10 and d.Parent.AbsoluteSize.X < 220 and d.Parent.AbsoluteSize.Y < 220 then
        for _, sib in ipairs(d.Parent:GetChildren()) do
            if CheckLabelMatchesSlam(sib) then return true end
        end
    end
    return false
end
local function ResolveSlamButtonTarget(d)
    if not d then return nil end
    if d:IsA("GuiButton") then return d end
    local childBtn = d:FindFirstChildWhichIsA("GuiButton", true)
    if childBtn and childBtn.Visible and childBtn.AbsoluteSize.X > 8 then return childBtn end
    local cur = d.Parent
    local hop = 0
    local bestFrame = d
    while cur and cur:IsA("GuiObject") and hop < 3 do
        if cur.AbsoluteSize.X > 8 and cur.AbsoluteSize.X <= 260 and cur.AbsoluteSize.Y > 8 and cur.AbsoluteSize.Y <= 260 then
            if cur:IsA("GuiButton") and cur.Visible then return cur end
            local sibBtn = cur:FindFirstChildWhichIsA("GuiButton", true)
            if sibBtn and sibBtn.Visible and sibBtn.AbsoluteSize.X > 8 then return sibBtn end
            bestFrame = cur
            cur = cur.Parent
            hop = hop + 1
        else
            break
        end
    end
    return bestFrame
end
local function GetCachedSlamButton(now)
    local pg = cachedPG or LocalPlayer:FindFirstChild("PlayerGui")
    if cachedPerfectBtn and cachedPerfectBtn.Parent and cachedPerfectBtn.Visible and cachedPerfectBtn.AbsoluteSize.X > 8 then
        if IsGuiHierarchyVisible(cachedPerfectBtn, pg) then
            return cachedPerfectBtn
        end
    end
    if now - (DashUI._lastSlamScanAt or 0) < 0.15 then
        return nil
    end
    DashUI._lastSlamScanAt = now
    cachedPerfectBtn = nil
    if not pg then return nil end
    if next(cachedSkillButtons) == nil then
        pcall(GetCachedSkillButton, "Z", now)
    end
    for _, skBtn in pairs(cachedSkillButtons) do
        if skBtn and skBtn.Parent then
            local p1 = skBtn.Parent
            local p2 = p1.Parent
            local p3 = p2 and p2.Parent
            for _, container in ipairs({p1, p2, p3}) do
                if container and container ~= pg and container ~= cachedMainGui then
                    for _, d in ipairs(container:GetDescendants()) do
                        if IsSlamGuiCandidate(d) and IsGuiHierarchyVisible(d, pg) then
                            local target = ResolveSlamButtonTarget(d)
                            cachedPerfectBtn = target
                            return target
                        end
                    end
                end
            end
            break
        end
    end
    local searchRoots = {}
    if cachedFUI then table.insert(searchRoots, cachedFUI) end
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Enabled and g.Name ~= "IdenticalHeavyweightFishing" and g.Name ~= "RobloxGui" then
            local gn = g.Name:lower()
            local isMenuGui = gn:find("inventory", 1, true) or gn:find("shop", 1, true) or gn:find("bag", 1, true)
                or gn:find("index", 1, true) or gn:find("setting", 1, true) or gn:find("store", 1, true) or gn:find("catalog", 1, true)
            if not isMenuGui then
                if gn == "maingui" then
                    for _, sub in ipairs(g:GetChildren()) do
                        local sn = sub.Name:lower()
                        if sn ~= "menu" and not sn:find("inventory", 1, true) and not sn:find("shop", 1, true) and not sn:find("index", 1, true) and not sn:find("bag", 1, true) then
                            table.insert(searchRoots, sub)
                        end
                    end
                else
                    table.insert(searchRoots, g)
                end
            end
        end
    end
    for _, rootInst in ipairs(searchRoots) do
        for _, d in ipairs(rootInst:GetDescendants()) do
            if IsSlamGuiCandidate(d) and IsGuiHierarchyVisible(d, pg) then
                local target = ResolveSlamButtonTarget(d)
                cachedPerfectBtn = target
                return target
            end
        end
    end
    return nil
end
local function TriggerSlamEveryWay(perfBtn)
    if not FishGate.AllowCombat() then return end
    if perfBtn and perfBtn.Parent and perfBtn.Visible then
        FireGuiButton(perfBtn, true, true)
    end
    if VirtualInputManager then
        pcall(function()
            pressedVirtualKeys[Enum.KeyCode.F] = true
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            task.delay(0.04, function()
                pressedVirtualKeys[Enum.KeyCode.F] = nil
                pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game) end)
            end)
        end)
    end
    if type(getconnections) == "function" then
        pcall(function()
            local fakeKeyBegin = MakeSyntheticInput(Enum.UserInputType.Keyboard, Enum.UserInputState.Begin, Enum.KeyCode.F, Vector3.zero)
            local fakeKeyEnd = MakeSyntheticInput(Enum.UserInputType.Keyboard, Enum.UserInputState.End, Enum.KeyCode.F, Vector3.zero)
            local uisConns = getconnections(UserInputService.InputBegan)
            if type(uisConns) == "table" then
                for _, conn in ipairs(uisConns) do
                    if type(conn.Function) == "function" then
                        task.spawn(function() pcall(conn.Function, fakeKeyBegin, false) end)
                    end
                end
            end
            task.delay(0.04, function()
                pcall(function()
                    local endConns = getconnections(UserInputService.InputEnded)
                    if type(endConns) == "table" then
                        for _, conn in ipairs(endConns) do
                            if type(conn.Function) == "function" then
                                task.spawn(function() pcall(conn.Function, fakeKeyEnd, false) end)
                            end
                        end
                    end
                end)
            end)
        end)
    end
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
local uidHealthKey = tostring(LocalPlayer.UserId) .. "_PlayerHealth"
local wsRootRadarModels = setmetatable({}, { __mode = "k" })
local radarKwCache, radarKwCount = {}, 0
local function HasRadarKeyword(str)
    if not str or str == "" then return false end
    local hit = radarKwCache[str]
    if hit ~= nil then return hit end
    local res = (str:find("spirit", 1, true) or str:find("god", 1, true) or str:find("shrine", 1, true) or str:find("altar", 1, true)
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
        or str:find("skill", 1, true) or str:find("upgrade", 1, true) or str:find("曾天国", 1, true) or str:find("楚依旧", 1, true)
        or str:find("智者", 1, true) or str:find("伊杰尤", 1, true) or str:find("yiju", 1, true) or str:find("eiju", 1, true) or str:find("技能", 1, true)) ~= nil
    if #str <= 200 then
        if radarKwCount >= 4096 then table.clear(radarKwCache); radarKwCount = 0 end
        radarKwCache[str] = res
        radarKwCount = radarKwCount + 1
    end
    return res
end
local radarNameVerdict = {}
local radarNameVerdictCount = 0
local function IsWorkspaceRootRadarCandidate(ch)
    if not ch or IsMapOrIslandContainer(ch) then return false end
    if not (ch:IsA("Model") or ch:IsA("BasePart") or ch:IsA("Folder")) then return false end
    local rawName = ch.Name or ""
    local cachedVerdict = radarNameVerdict[rawName]
    if cachedVerdict ~= nil then return cachedVerdict end
    local cn = tqLc(rawName)
    local verdict
    if cn:find("rod", 1, true) or cn == "identicallock" or cn:find("identical", 1, true) or cn == "terrain" or cn == "camera" then
        verdict = false
    else
        verdict = HasRadarKeyword(cn)
    end
    if radarNameVerdictCount >= 2048 then
        table.clear(radarNameVerdict)
        radarNameVerdictCount = 0
    end
    radarNameVerdict[rawName] = verdict
    radarNameVerdictCount = radarNameVerdictCount + 1
    return verdict
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
local rodPowerLookupLower = {}
for k, v in pairs(rodPowerLookup) do rodPowerLookupLower[string.lower(tostring(k))] = v end
local function RodPowerOf(name)
    if name == nil then return nil end
    local key = tostring(name)
    return rodPowerLookup[key] or rodPowerLookupLower[string.lower(key)]
end
local function stepLowFreqAutomation(now)
    if isMicroTeleportingNPC and microTeleportLockAt > 0 and (now - microTeleportLockAt > 12) then
        isMicroTeleportingNPC = false
        microTeleportLockAt = 0
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local pData = cachedPData or GetPlayerData()
    local gateIdleNow = FishGate.IsIdle()
    if not FishGate.IsFight() and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) and (now >= nextProtectAt) and pData then
        nextProtectAt = now + HRand(1.2, 0.12)
        TryFavoriteProtectedFish(pData, false)
    end
    if gateIdleNow then
        if Config.AutoSell and (now - lastSellTime >= (tonumber(Config.SellInterval) or 30)) then
            SafeSellAllFish(pData)
            lastSellTime = now
        end
        if (now - (DashUI._lastAnimCleanTime or 0) >= 0.8) then
            DashUI._lastAnimCleanTime = now
            local holdingNow = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(char, pData)
            if not holdingNow and StopLingeringFishingAnimations then
                StopLingeringFishingAnimations(char)
            end
        end
        if Config.AutoTicketQuest and not isMicroTeleportingNPC and not IsDialogueUIOpen(false) and (now - (DashUI._lastAutoTicketAt or 0) >= 15.0) then
            DashUI._lastAutoTicketAt = now
            if RunTicketQuestAction then
                local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
                RunTicketQuestAction(diffArg, false)
            end
        end
    end
    if gateIdleNow and Config.AutoPrayGodSpirit and (now >= nextGodPrayAt) then
        nextGodPrayAt = now + HRand(3.0, 0.35)
        for _, spKey in ipairs({"Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber"}) do
            local entry = liveNPCs[spKey]
            if entry and entry.inst and entry.inst.Parent then
                TriggerNPCInstancePrompts(entry.inst)
            end
        end
        local npcFolder = GetWorkspaceFolder("NPC") or GetWorkspaceFolder("NPCs")
        if npcFolder then
            for _, ch in ipairs(npcFolder:GetChildren()) do
                local cn = tqLc(ch.Name or "")
                if cn == "spirit" or cn == "god" or cn:find("spirit", 1, true) or cn:find("thần linh", 1, true) or cn:find("神灵", 1, true) then
                    TriggerNPCInstancePrompts(ch)
                end
            end
        end
    end
    if gateIdleNow and Config.AutoGacha and (now >= nextGachaAt) then
        nextGachaAt = now + HRand(1.5, 0.35)
        local bannerArg = FSYC.GachaBannerMap[Config.GachaBanner] or "Taiji Banner"
        SafeFireEventRemote("Gacha", bannerArg, Config.GachaPullsPerAction)
    end
    if gateIdleNow and Config.AutoGiveMonkey and (now >= nextMonkeyAt) then
        nextMonkeyAt = now + HRand((FSYC.Tunables and FSYC.Tunables.MonkeyGiveIntervalSec) or 4.0, 0.45)
        if RunGiveFishToMonkeyBatch then RunGiveFishToMonkeyBatch() end
    end
    if gateIdleNow and Config.AutoClaimDaily and (now - lastDailyTime >= (FSYC.Tunables and FSYC.Tunables.DailyAutoIntervalSec or 300.0)) then
        if not (isClaimingDailySign and (now - (FSYC.dailySignLockAt or 0)) < 30) then
            lastDailyTime = now
            if Events then
                local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
                if dailyRem then
                    dailyMissingWarned = false
                    isClaimingDailySign = true
                    FSYC.dailySignLockAt = now
                    task.spawn(function()
                        local delaySec = math.max(0.4, tonumber(Config.DailyClaimDelay) or 0.5)
                        if FishGate.IsIdle() then
                            for day = 1, 7 do
                                if not isRunning or not Config.AutoClaimDaily then break end
                                while isRunning and Config.AutoClaimDaily and FishGate and not FishGate.IsIdle() do
                                    task.wait(0.3)
                                end
                                if not isRunning or not Config.AutoClaimDaily then break end
                                if dailyRem:IsA("RemoteEvent") then
                                    SafeFireEventRemote(dailyRem, day)
                                elseif dailyRem:IsA("RemoteFunction") then
                                    DashUI._safeInvokeAsync(dailyRem, 3.0, day)
                                end
                                task.wait(delaySec)
                            end
                        end
                        isClaimingDailySign = false
                    end)
                elseif not dailyMissingWarned then
                    dailyMissingWarned = true
                    ShowNotification("每日奖励", "当前服务器未找到每日奖励远程事件，自动领取已跳过。", "WARN", 4)
                end
            end
        end
    end
    if gateIdleNow and Config.AutoCraftBait and (now >= nextCraftAt) then
        nextCraftAt = now + HRand(FSYC.Tunables and FSYC.Tunables.CraftAutoIntervalSec or 10.0, 0.35)
        SafeFireEventRemote("CraftBait", Config.CraftBaitName, Config.CraftAmount)
    end
    if gateIdleNow and Config.AutoBuyBait and (now >= nextBaitBuyAt) then
        nextBaitBuyAt = now + HRand(math.max(5, tonumber(Config.BuyBaitDelay) or 30), 0.35)
        if pData then
            local currentAmount = DashUI._getBaitQty(pData, Config.BuyBaitName)
            if currentAmount >= 500 then
                FLogWarn("诱饵", string.format("%s 已达 500 上限，跳过购买", tostring(Config.BuyBaitName)))
            elseif currentAmount < (tonumber(Config.BuyBaitThreshold) or 10) then
                SafeFireEventRemote("BuyBait", Config.BuyBaitName, 1)
            end
        end
    end
end
local function SetDashLbl(lbl, txt)
    if lbl and lbl.Parent and lbl.Text ~= txt then lbl.Text = txt end
end
local bagCountHolder, bagCountVal, bagCountAt = nil, 0, -1
local function CountBagFish(pData, now)
    if not pData then return 0 end
    if bagCountHolder == pData and bagCountAt >= 0 and (now - bagCountAt) < 0.5 then
        return bagCountVal
    end
    local invCount = 0
    local inv = pData:FindFirstChild("Inventory")
    if inv then invCount = invCount + #inv:GetChildren() end
    local hotbar = pData:FindFirstChild("Hotbar")
    if hotbar then
        for _, item in ipairs(hotbar:GetChildren()) do
            local qVal = tonumber(DashUI._readValueBase(item:FindFirstChild("Quantity"), 1)) or 1
            invCount = invCount + qVal
        end
    end
    bagCountHolder, bagCountVal, bagCountAt = pData, invCount, now
    return invCount
end
local function stepDashboardAndEquip(now)
    if not DashUI.lblHangTime or not DashUI.lblHangTime.Parent then return end
    local pData = GetPlayerData()
    local elapsed = now - dashStartTime
    local h = math.floor(elapsed / 3600)
    local m = math.floor((elapsed % 3600) / 60)
    local s = math.floor(elapsed % 60)
    SetDashLbl(DashUI.lblHangTime, string.format("%02d:%02d:%02d", h, m, s))
    if now - lastPingCheck >= 2.0 then
        lastPingCheck = now
        local pingOk, pingVal = pcall(function() return Stats and math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue()) end)
        if pingOk and pingVal then SetDashLbl(DashUI.lblPing, pingVal .. " ms") else SetDashLbl(DashUI.lblPing, "无信号") end
    end
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then SetDashLbl(DashUI.lblPos, string.format("%.0f, %.0f, %.0f", root.Position.X, root.Position.Y, root.Position.Z)) end
    if pData and pData.Parent then
        local rawFish = tonumber(DashUI._readValueBase(pData:FindFirstChild("FishCaught"), 0)) or 0
        local rawCash = tonumber(DashUI._readValueBase(pData:FindFirstChild("Cash"), 0)) or 0
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
        SetDashLbl(DashUI.lblTotalFish, string.format("%d 条", currentFish))
        DashUI.infoFishCaught.Set(tostring(currentFish))
        DashUI.infoCash.Set("$" .. tostring(currentCash))
        if currentCash >= 1000000000 then
            SetDashLbl(DashUI.lblCash, string.format("$%.2fB", currentCash / 1000000000))
        elseif currentCash >= 1000000 then
            SetDashLbl(DashUI.lblCash, string.format("$%.2fM", currentCash / 1000000))
        elseif currentCash >= 1000 then
            SetDashLbl(DashUI.lblCash, string.format("$%.1fK", currentCash / 1000))
        else
            SetDashLbl(DashUI.lblCash, "$" .. tostring(currentCash))
        end
        if elapsed > 5 then
            local fishSpeed = math.max(0, ((currentFish - dashStartFish) / elapsed) * 3600)
            SetDashLbl(DashUI.lblFishSpeed, string.format("%.0f 条/h", fishSpeed))
            local cashSpeed = math.max(0, ((currentCash - dashStartCash) / elapsed) * 3600)
            if cashSpeed >= 1000000 then
                SetDashLbl(DashUI.lblCashSpeed, string.format("$%.1fM/h", cashSpeed / 1000000))
            elseif cashSpeed >= 1000 then
                SetDashLbl(DashUI.lblCashSpeed, string.format("$%.1fK/h", cashSpeed / 1000))
            else
                SetDashLbl(DashUI.lblCashSpeed, string.format("$%.0f/h", cashSpeed))
            end
        else
            SetDashLbl(DashUI.lblCashSpeed, "$0 金币/时")
        end
        local eqRodStr = tostring(DashUI._readValueBase(pData:FindFirstChild("FishingRod"), "") or "")
        if eqRodStr ~= "" then
            SetDashLbl(DashUI.lblRod, eqRodStr)
            DashUI.infoEquippedRod.Set(eqRodStr)
        end
        local eqBaitStr = tostring(DashUI._readValueBase(pData:FindFirstChild("EquippedBait"), "") or "")
        if eqBaitStr ~= "" then
            SetDashLbl(DashUI.lblBait, eqBaitStr)
            DashUI.infoEquippedBait.Set(eqBaitStr)
        end
        local gemsVal = tonumber(DashUI._readValueBase(pData:FindFirstChild("Gems") or pData:FindFirstChild("Gem") or pData:FindFirstChild("Diamonds"), 0)) or 0
        if gemsVal >= 1000000000 then SetDashLbl(DashUI.lblGems, string.format("%.1fB", gemsVal / 1000000000))
        elseif gemsVal >= 1000000 then SetDashLbl(DashUI.lblGems, string.format("%.1fM", gemsVal / 1000000))
        else SetDashLbl(DashUI.lblGems, tostring(gemsVal)) end
        local ticketsVal = tonumber(DashUI._readValueBase(pData:FindFirstChild("Tickets") or pData:FindFirstChild("Ticket"), 0)) or 0
        if ticketsVal >= 1000000000 then SetDashLbl(DashUI.lblTicket, string.format("%.1fB", ticketsVal / 1000000000))
        elseif ticketsVal >= 1000000 then SetDashLbl(DashUI.lblTicket, string.format("%.1fM", ticketsVal / 1000000))
        else SetDashLbl(DashUI.lblTicket, tostring(ticketsVal)) end
        local dailyDone = tostring(DashUI._readValueBase(pData:FindFirstChild("DailyQuestsDone") or pData:FindFirstChild("DailyProgress"), 0) or 0)
        SetDashLbl(DashUI.lblQuest, dailyDone .. " 个")
        local invCount = CountBagFish(pData, now)
        local limit = DashUI._readValueBase(pData:FindFirstChild("InventoryLimit"), "?")
        SetDashLbl(DashUI.lblBag, invCount .. " / " .. tostring(limit))
        if FishGate.IsIdle() and (now - lastEquipCheck >= (FSYC.Tunables and FSYC.Tunables.EquipCheckIntervalSec or 5.0)) then
            lastEquipCheck = now
            local equipBaitRem = GetEventRemote("EquipBait")
            if Config.AutoEquipBestBait and pData:FindFirstChild("Bait") and equipBaitRem then
                local curEquipped = eqBaitStr
                local isSpecialBossBait = (curEquipped == "Nameless Bait" or curEquipped == "Frost Bait" or curEquipped == "Rainbow Bait" or curEquipped == "Intuitive Bait" or curEquipped == "Thunder Bait")
                if not isSpecialBossBait then
                    local bestBait, bestLuck = nil, -1
                    for bName, bLuck in pairs(baitLuckMap) do
                        if DashUI._getBaitQty(pData, bName) > 0 and bLuck > bestLuck then
                            bestLuck = bLuck
                            bestBait = bName
                        end
                    end
                    if bestBait and curEquipped ~= bestBait then
                        DashUI._safeInvokeAsync(equipBaitRem, 4.0, bestBait)
                    end
                end
            end
            local equipRodRem = GetEventRemote("EquipFishingRod")
            if Config.AutoEquipBestRod and pData:FindFirstChild("FishingRodInventory") and equipRodRem then
                local curRodName = eqRodStr
                local curRodPower = RodPowerOf(curRodName)
                if curRodName == "" or curRodPower ~= nil then
                    local bestRod, bestPower = curRodName, (curRodPower or -1)
                    for _, rFolder in ipairs(pData.FishingRodInventory:GetChildren()) do
                        if DashUI._isRodOwned(rFolder) then
                            local pwr = tonumber(DashUI._readValueBase(rFolder:FindFirstChild("Power"), nil)) or RodPowerOf(rFolder.Name) or -1
                            if pwr > bestPower then
                                bestPower = pwr
                                bestRod = rFolder.Name
                            end
                        end
                    end
                    if bestRod and bestRod ~= "" and curRodName ~= bestRod then
                        DashUI._safeInvokeAsync(equipRodRem, 4.0, bestRod)
                    end
                elseif not DashUI._rodUnknownWarned then
                    DashUI._rodUnknownWarned = true
                    FLogWarn("自动配竿", "当前鱼竿未收录战力表，已跳过自动更换: " .. tostring(curRodName))
                end
            end
            local equipOrbRem = GetEventRemote("EquipOrb")
            if Config.AutoEquipBestOrb and pData:FindFirstChild("Orb") and equipOrbRem then
                local orbs = pData.Orb:GetChildren()
                local lastOrb = (#orbs > 0) and orbs[#orbs] or nil
                if lastOrb and IsInstanceValid(lastOrb) and type(lastOrb.Name) == "string" and lastOrb.Name ~= "" then
                    local targetOrb = lastOrb.Name
                    local curOrb = tostring(DashUI._readValueBase(pData:FindFirstChild("EquippedOrb") or pData:FindFirstChild("CurrentOrb"), "") or "")
                    if curOrb ~= targetOrb then
                        DashUI._safeInvokeAsync(equipOrbRem, FSYC.Tunables and FSYC.Tunables.InvokeDefaultTimeoutSec or 4.0, targetOrb)
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
    Vector3.new(1259.4, 9.1, 1401.5),
    Vector3.new(-1223.0, 7.3, -24.1),
    Vector3.new(-1366.0, 11.9, -1495.4),
    Vector3.new(65.5, 8.8, 1181.3),
    Vector3.new(-1276.4, 8.8, 1239.7),
    Vector3.new(-62.0, 11.9, -1321.4),
    Vector3.new(1493.6, 9.1, -1430.6),
    Vector3.new(1393.5, 11.3, 169.6),
    Vector3.new(2660.2, 8.8, -86.7),
    Vector3.new(-2404.5, 7.6, -202.4),
    Vector3.new(-2908.1, 6.8, 1191.2),
    Vector3.new(-2648.0, 6.8, -1322.1),
}
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
local function stepWorldRadar(now)
    now = now or tick()
    local nowDialogueOpen = IsDialogueUIOpen(false)
    if not nowDialogueOpen and (radarWasDialogueOpen or not isMicroTeleportingNPC) and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(false)
    end
    radarWasDialogueOpen = nowDialogueOpen
    local char = LocalPlayer.Character
    local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
    local found = {}
    local foundOnlinePass = {}
    table.clear(inspectedRadarPass)
    if not isMicroTeleportingNPC and not attrMinigame and (now - lastStreamPrefetchTime >= 5.0) then
        lastStreamPrefetchTime = now
        streamPrefetchIdx = (streamPrefetchIdx % #streamPrefetchPoints) + 1
        local pt = streamPrefetchPoints[streamPrefetchIdx]
        if pt and (not myPos or (myPos - pt).Magnitude > 450) and TryStreamAroundPosition then
            pcall(TryStreamAroundPosition, pt)
        end
    end
    local function inspectEntity(npc, allowDeepSummary, promptHint)
        if not npc or npc == char or IsMapOrIslandContainer(npc) then return end
        local dedupKey = promptHint or npc
        if inspectedRadarPass[dedupKey] then return end
        if not (npc:IsA("Model") or npc:IsA("BasePart") or npc:IsA("Folder")) then return end
        inspectedRadarPass[dedupKey] = true
        if npc:IsA("Model") and Players:GetPlayerFromCharacter(npc) then return end
        if IsToolFishingRod and IsToolFishingRod(npc) then return end
        local name = npc.Name or ""
        local nLow = LowerInstNameG(npc)
        local matchParts = { nLow }
        if npc.Parent and not IsMapOrIslandContainer(npc.Parent) then
            table.insert(matchParts, LowerInstNameG(npc.Parent))
        end
        if promptHint and promptHint:IsA("ProximityPrompt") then
            if promptHint.Name and promptHint.Name ~= "ProximityPrompt" then table.insert(matchParts, tqLc(promptHint.Name)) end
            if promptHint.ObjectText and promptHint.ObjectText ~= "" then table.insert(matchParts, tqLc(promptHint.ObjectText)) end
            if promptHint.ActionText and promptHint.ActionText ~= "" then table.insert(matchParts, tqLc(promptHint.ActionText)) end
            if promptHint.Parent and promptHint.Parent ~= npc then table.insert(matchParts, tqLc(promptHint.Parent.Name or "")) end
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
            AddESP(npc, dispName, "Maoshan", Colors.AccentSoft, "✨", pos)
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
            AddESP(npc, "傻子隐藏商人 (Dumb Guy)", "DumbGuy", Colors.AccentYellow, "🃏", pos)
            liveNPCs.DumbGuy.pos = pos
            liveNPCs.DumbGuy.inst = npc
            liveNPCs.DumbGuy.lastSeen = now
            found.DumbGuy = true
            if not radarWasFound.DumbGuy then
                ShowNotification("🃏 隐藏商人降临", "傻子隐藏商人 (Dumb Guy) 已在服务器刷新！", "SUCCESS", 6)
            end
        end
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
                if minSpiritDist <= 450 then
                    local spKey, spTitle = nil, nil
                    if dAmb <= 450 and (matchStr:find("amber", 1, true) or matchStr:find("yellow", 1, true) or matchStr:find("ho phach", 1, true) or matchStr:find("hổ phách", 1, true) or matchStr:find("琥珀", 1, true) or (dAmb <= dBam and dAmb <= dFro)) then
                        spKey = "Spirit_Amber"; spTitle = "琥珀岛神灵"
                    elseif dFro <= 450 and (matchStr:find("frost", 1, true) or matchStr:find("blue", 1, true) or matchStr:find("băng", 1, true) or matchStr:find("sương giá", 1, true) or matchStr:find("bang gia", 1, true) or matchStr:find("冰霜", 1, true) or (dFro <= dBam and dFro <= dAmb)) then
                        spKey = "Spirit_Frost"; spTitle = "冰霜岛神灵"
                    elseif dBam <= 450 and (matchStr:find("bamboo", 1, true) or matchStr:find("green", 1, true) or matchStr:find("tre", 1, true) or matchStr:find("trúc", 1, true) or matchStr:find("truc", 1, true) or matchStr:find("竹", 1, true) or (dBam <= dFro and dBam <= dAmb)) then
                        spKey = "Spirit_Bamboo"; spTitle = "竹岛神灵"
                    end
                    if spKey and spTitle then
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
        end
        if not matchedAnyBeast and (nLow:find("enzo", 1, true) or nLow:find("octo", 1, true) or nLow:find("parasite", 1, true) or nLow:find("dragon whale", 1, true) or nLow:find("boss", 1, true)) then
            AddESP(npc, name, "Boss", Colors.AccentRed, "👹", pos)
        end
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
    for _, folderName in ipairs(FSYC.NPC_SCAN_CONTAINER_NAMES) do
        local folder = GetWorkspaceFolder(folderName)
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do
                if IsMapOrIslandContainer(ch) then
                    for _, sub in ipairs(ch:GetChildren()) do
                        pcall(inspectEntity, sub, true)
                    end
                else
                    local parentNamedHit = HasRadarKeyword(LowerInstNameG(ch))
                    pcall(inspectEntity, ch, true)
                    if ch:IsA("Folder") or ch:IsA("Model") then
                        for _, sub in ipairs(ch:GetChildren()) do
                            if parentNamedHit and sub:IsA("BasePart") and #sub:GetChildren() == 0
                                and not HasRadarKeyword(LowerInstNameG(sub)) then
                            else
                                pcall(inspectEntity, sub, true)
                            end
                        end
                    end
                end
            end
        end
    end
    for _, mapFolderName in ipairs(MAP_ROOT_NAMES) do
        local mapFolder = GetWorkspaceFolder(mapFolderName)
        if mapFolder then
            for _, isl in ipairs(mapFolder:GetChildren()) do
                if isl:IsA("Folder") or isl:IsA("Model") then
                    for _, ch in ipairs(isl:GetChildren()) do
                        local cnLow = LowerInstNameG(ch)
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
    for _, key in ipairs(liveNPCOrder) do
        local data = liveNPCs[key]
        if data and not found[key] then
            local isPosValid = true
            if data.fallbackPos and data.pos then
                if (data.pos - data.fallbackPos).Magnitude > 450 then
                    isPosValid = false
                    data.pos = nil
                    data.inst = nil
                    data.lastSeen = nil
                end
            end
            if isPosValid then
                local ESP_STALE_KEEP = 10.0
                local seenFresh = (data.lastSeen == nil) or ((now - data.lastSeen) <= ESP_STALE_KEEP)
                if data.inst and data.inst.Parent and seenFresh then
                    found[key] = true
                    data.pos = GetNPCPosition(data.inst) or data.pos
                    if key:find("^Spirit_") then found.AnySpirit = true end
                elseif data.inst and data.inst.Parent then
                    if activeESP and activeESP[data.inst] then pcall(RemoveESP, data.inst) end
                    data.inst = nil
                    data.pos = nil
                    data.lastSeen = nil
                elseif data.pos and data.lastSeen and (now - data.lastSeen < 120.0) and myPos and (myPos - data.pos).Magnitude > 600 then
                    found[key] = true
                    if key:find("^Spirit_") then found.AnySpirit = true end
                end
            end
        end
    end
    for k, v in pairs(OnlineNPCs) do
        if not foundOnlinePass[k] and (now - (v.time or 0) > 6.0) then
            OnlineNPCs[k] = nil
        end
    end
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
                                local vLow = tqLc(rawVal)
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
    for _, key in ipairs(liveNPCOrder) do
        local data = liveNPCs[key]
        if data and data.ui_title then
            local newTitle, newTitleColor, newDesc, btnBg, btnTextColor, btnLabel
            if found[key] and data.pos then
                newTitle = data.icon .. " " .. data.name .. " (🟢 已刷新)"
                newTitleColor = Colors.AccentGreen
                if myPos then
                    local isl = GetNearestIslandInfo(data.pos)
                    local islTag = isl and (" · " .. isl.name) or ""
                    newDesc = string.format("距离你: %d 米%s", math.floor((myPos - data.pos).Magnitude), islTag)
                else
                    newDesc = "位置已锁定，点击立即传送"
                end
                btnBg = Colors.Accent
                btnTextColor = Colors.AccentDeep
                btnLabel = "立即传送"
            else
                data.pos = nil
                data.inst = nil
                data.lastSeen = nil
                newTitle = data.icon .. " " .. data.name .. " (未检测到)"
                newTitleColor = Colors.TextMuted
                newDesc = data.desc or "等待刷新..."
                btnBg = Colors.ControlBg
                btnTextColor = data.fallbackPos and Colors.AccentSoft or Colors.TextMuted
                btnLabel = data.fallbackPos and "前往岛屿" or "传送"
            end
            if data.ui_title.Text ~= newTitle then data.ui_title.Text = newTitle end
            if data.ui_title.TextColor3 ~= newTitleColor then data.ui_title.TextColor3 = newTitleColor end
            if data.ui_desc.Text ~= newDesc then data.ui_desc.Text = newDesc end
            if data.ui_btn.BackgroundColor3 ~= btnBg then data.ui_btn.BackgroundColor3 = btnBg end
            if data.ui_btn.TextColor3 ~= btnTextColor then data.ui_btn.TextColor3 = btnTextColor end
            if data.ui_btn.Text ~= btnLabel then data.ui_btn.Text = btnLabel end
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
    ScanAndMountDynamicESP()
end
DashUI._runRadarPassNow = function()
    stepWorldRadar(tick())
end
local function stepESPCleanup()
    for inst, data in pairs(activeESP) do
        if not inst.Parent
            or not data.part or not data.part.Parent
            or not data.gui or not data.gui.Parent then
            pcall(RemoveESP, inst)
        end
    end
    if SweepOrphanSlots then pcall(SweepOrphanSlots) end
end
local function RunBackgroundScheduler()
    local lastEspRefreshTick = 0
    local lastLowFreqTick = 0
    local lastDashTick = 0
    local lastRadarTick = 0
    local lastEspCleanTick = tick()
    local lastWSScanBackfill = tick()
    local idleSince = 0
    local idleLowLoad = false
    local lastCombatLow = false
    local combatSince = 0
    while isRunning do
        local powerSave = Config.Disable3DRendering
        task.wait(powerSave and 0.25 or 0.15)
        if not isRunning then break end
        local now = tick()
        local inGameplay = attrFishing or attrMinigame or wasInMinigame or cachedIsHooked
        if inGameplay then
            idleSince = 0
            idleLowLoad = false
        elseif idleSince == 0 then
            idleSince = now
        elseif not idleLowLoad and (now - idleSince >= 5.0) then
            idleLowLoad = true
        end
        local inCombatNow = attrMinigame or cachedIsHooked
        local combatHold = Config.OctoAutoMinigame
        if inCombatNow then
            if combatSince == 0 then combatSince = now end
        else
            combatSince = 0
        end
        local combatLowLoad = inCombatNow and (now - combatSince >= 0.2) and not combatHold
        if combatLowLoad ~= lastCombatLow then
            lastCombatLow = combatLowLoad
            if combatLowLoad then
                if (now - lastRadarTick) > 0.5 then lastRadarTick = 0 end
                FLog("性能/降载", "进入搏斗低载：雷达2.0s / ESP0.35s / 仪表盘1.0s")
            else
                FLog("性能/恢复", "退出搏斗低载：恢复雷达0.8s / ESP0.15s / 仪表盘0.5s")
            end
        end
        local espInterval = combatLowLoad and 0.35 or (idleLowLoad and 0.45 or 0.15)
        local dashInterval = combatLowLoad and 1.00 or (idleLowLoad and 1.00 or 0.50)
        if not powerSave and (now - lastEspRefreshTick >= espInterval) then
            lastEspRefreshTick = now
            local anyESP = Config.ESP_GodSpirit or Config.ESP_Boats
                or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_DumbGuy or Config.ESP_Boss or Config.ESP_Players
            if next(activeESP) ~= nil then
                if anyESP then
                    SafeStep("ESP距离刷新", RefreshAllESPNow)
                else
                    SafeStep("ESP清理", ClearDisabledCategoryESP, nil)
                end
            end
        end
        if now - lastLowFreqTick >= 0.25 then
            lastLowFreqTick = now
            SafeStep("低频自动化", stepLowFreqAutomation, now)
        end
        local radarInterval = powerSave and 0.65 or (combatLowLoad and 2.0 or 0.8)
        local radarDue = (now - lastRadarTick >= radarInterval)
        if now - lastDashTick >= dashInterval and not radarDue then
            lastDashTick = now
            SafeStep("仪表盘统计", stepDashboardAndEquip, now)
        end
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
        if radarDue then
            lastRadarTick = now
            SafeStep("全图雷达", stepWorldRadar, now)
        elseif powerSave and now - lastEspCleanTick >= 5.0 then
            lastEspCleanTick = now
            SafeStep("ESP失效清理", stepESPCleanup)
        end
    end
end
task.spawn(function()
    while isRunning do
        local okRun, runErr = pcall(RunBackgroundScheduler)
        if okRun then break end
        FLogErr("后台调度器", "调度器异常退出，3 秒后自动重启：" .. tostring(runErr))
        task.wait(3.0)
    end
end)
local function CreateAutoSkillEngine(deps)
    deps = deps or {}
    local cfg = deps.config or {}
    local logFn, warnFn = deps.log, deps.warn
    local getIndex, setIndex = deps.getIndex, deps.setIndex
    local jitterFn = deps.jitter
    local tun = FSYC.Tunables or {}
    local EXIT_GRACE = tun.SkillExitGraceSec or 1.5
    local RETRY_DELAY = tun.SkillRetryDelaySec or 0.4
    local MAX_SLOT_FAILS = tun.SkillMaxSlotFails or 3
    local MIN_GAP = tun.SkillMinGapSec or 0.12
    local PANIC_HP = tun.SkillPanicHpRatio or 0.35
    local REENTER_LOCK = tun.SkillReenterLockSec or 5.0
    local STRONG_MIN = tun.SkillStrongMinSec or 0.5
    local MAX_WEAK_FIGHT = tun.SkillMaxWeakFightSec or 90
    local S = {
        inFight = false,
        fightStartAt = 0,
        warmJitter = 0,
        lastSignalAt = 0,
        lastStrongAt = 0,
        strongRun = 0,
        strongAuthoritative = false,
        blockWeakEntry = false,
        lastStepAt = 0,
        relockUntil = 0,
        seq = {},
        seqSig = "",
        readyAt = {},
        broken = {},
        failCount = {},
        nextCastAt = 0,
        lastCastAt = 0,
        panicUsed = false,
        probe = {},
        nextProbeAt = 0,
        probeFails = 0,
        probeInterval = 0.4,
        deferCount = {},
        lastRead = {},
        deferOff = {},
        castThisFight = {},
        stallWarned = false,
        stats = { fight = 0, cast = 0, fail = 0, skip = 0, reset = 0, fightCast = 0, probe = 0 },
        lastReason = "idle",
    }
    local M = {}
    local function L(msg)
        if logFn then pcall(logFn, "自动技能", msg) end
    end
    local function W(msg)
        if warnFn then pcall(warnFn, "自动技能", msg) end
    end
    local function Num(v, def, lo, hi)
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then return def end
        if lo and n < lo then n = lo end
        if hi and n > hi then n = hi end
        return n
    end
    local function Jit(max)
        if not jitterFn then return 0 end
        local ok, v = pcall(jitterFn, max)
        if ok and type(v) == "number" and v == v and v > 0 and v <= max then return v end
        return 0
    end
    local function StartDelay() return Num(cfg.SkillStartDelay, 2.5, 0.5, 10) end
    local function Gap() return Num(cfg.SkillInterval, 1.5, 0.5, 5) end
    local function CooldownFor(slot)
        local per
        if slot == "Z" then per = cfg.SkillCdZ
        elseif slot == "X" then per = cfg.SkillCdX
        elseif slot == "C" then per = cfg.SkillCdC
        elseif slot == "V" then per = cfg.SkillCdV end
        return Num(per, Num(cfg.SkillCooldown, 30, 1, 999), 1, 999)
    end
    local readPrev = {}
    local function ReadIsCredible(slot, v, now)
        if type(v) ~= "number" then return false end
        if v <= 3 then readPrev[slot] = nil; return true end
        local prev = readPrev[slot]
        if not prev or v > prev.v + 0.5 then
            readPrev[slot] = { v = v, t = now }
            return false
        end
        if (now - prev.t) < 0.6 then
            return false
        end
        readPrev[slot] = { v = v, t = now }
        return v < prev.v - 0.05
    end
    local function Index() return Num(getIndex and getIndex() or 1, 1, 1, 4) end
    local function SetIndex(v) if setIndex then pcall(setIndex, v) end end
    local function ClearMap(t)
        for k in pairs(t) do t[k] = nil end
    end
    local seqCacheOrder, seqCacheMask, seqCacheOut, seqCacheSig = nil, -1, nil, ""
    local function BuildSequence()
        local orderRaw = cfg.SkillOrder
        local orderStr = type(orderRaw) == "string" and orderRaw or "Z,X,C,V"
        local mask = (cfg.SkillZ and 1 or 0) + (cfg.SkillX and 2 or 0) + (cfg.SkillC and 4 or 0) + (cfg.SkillV and 8 or 0)
        if seqCacheOut and orderStr == seqCacheOrder and mask == seqCacheMask then
            return seqCacheOut, seqCacheSig
        end
        seqCacheOrder, seqCacheMask = orderStr, mask
        orderStr = orderStr:upper():gsub("[^ZXCV]", "")
        local out, seen = {}, {}
        local i
        for i = 1, #orderStr do
            local k = orderStr:sub(i, i)
            local on
            if k == "Z" then on = cfg.SkillZ
            elseif k == "X" then on = cfg.SkillX
            elseif k == "C" then on = cfg.SkillC
            else on = cfg.SkillV end
            if on and not seen[k] then
                seen[k] = true
                out[#out + 1] = k
            end
        end
        if #out == 0 then
            if cfg.SkillZ then out[#out + 1] = "Z"; seen["Z"] = true end
            if cfg.SkillX then out[#out + 1] = "X"; seen["X"] = true end
            if cfg.SkillC then out[#out + 1] = "C"; seen["C"] = true end
            if cfg.SkillV then out[#out + 1] = "V"; seen["V"] = true end
        end
        seqCacheOut, seqCacheSig = out, table.concat(out, ",")
        return seqCacheOut, seqCacheSig
    end
    local function EnterFight(now)
        S.inFight = true
        S.fightStartAt = now
        S.lastSignalAt = now
        S.lastStrongAt = now
        S.strongRun = 0
        S.strongAuthoritative = false
        S.panicUsed = false
        ClearMap(S.deferOff)
        ClearMap(S.deferCount)
        ClearMap(S.lastRead)
        S.probeFails = 0
        S.probeInterval = 0.4
        ClearMap(S.broken)
        ClearMap(S.failCount)
        ClearMap(S.castThisFight)
        readPrev = {}
        S.stallWarned = false
        ClearMap(S.readyAt)
        S.stats.fight = S.stats.fight + 1
        S.stats.fightCast = 0
        S.warmJitter = Jit(0.6)
        SetIndex(1)
        L(string.format("进入战斗：%d 个技能待放，起手等待 %.2fs", #S.seq, StartDelay()))
    end
    local function ExitFight(now)
        S.inFight = false
        S.relockUntil = (now or 0) + (S.strongAuthoritative and REENTER_LOCK or 0)
        SetIndex(1)
        L(string.format("战斗结束：本场释放 %d 次（累计 %d 次）", S.stats.fightCast, S.stats.cast))
    end
    local function OrderMode()
        local m = cfg.SkillOrderMode
        if m == "严格轮流(等冷却)" then return "strict" end
        if m == "顺位优先(谁好放谁)" then return "priority" end
        if m == "盲轮转(按顺序点)" then return "blind" end
        if m == "优先(Z→X→C→V)" then return "head" end
        if cfg.SkillStrict == true then return "strict" end
        return "head"
    end
    local function PickSlot(now, reader)
        local total = #S.seq
        if total == 0 then return nil, 0 end
        local mode = OrderMode()
        local idx = Index()
        if idx < 1 or idx > total then idx = 1 end
        if mode == "blind" then
            local slot = S.seq[idx]
            local nxt = (idx % total) + 1
            local read
            if S.castThisFight[slot] and cfg.SkillCdProbe ~= false and reader then
                local okR, v = pcall(reader, slot)
                if okR and type(v) == "number" and v >= 1 and v <= 1200 then read = v end
            end
            SetIndex(nxt)
            if read then
                S.readyAt[slot] = now + read + 0.15
                S.stats.probe = S.stats.probe + 1
                return nil, idx, read
            end
            return slot, idx, 0
        end
        if mode == "head" then
            local pos
            for pos = 1, total do
                local slot = S.seq[pos]
                if not S.broken[slot] and now >= (S.readyAt[slot] or 0) then return slot, pos end
            end
            return nil, 1
        end
        if mode == "priority" then
            local step
            for step = 0, total - 1 do
                local pos = ((idx - 1 + step) % total) + 1
                local slot = S.seq[pos]
                if not S.broken[slot] and now >= (S.readyAt[slot] or 0) then return slot, pos end
            end
            return nil, idx
        end
        local curSlot = S.seq[idx]
        if curSlot and not S.broken[curSlot] and now >= (S.readyAt[curSlot] or 0) then
            return curSlot, idx
        end
        return nil, idx
    end
    function M.Step(now, ctx)
        local strong = (ctx.inMinigame == true)
        local anySignal = strong or (ctx.weak == true)
        local dt = now - S.lastStepAt
        if dt < 0 or dt > 0.5 then dt = 0 end
        S.lastStepAt = now
        if anySignal then S.lastSignalAt = now end
        if not anySignal then S.blockWeakEntry = false end
        if strong then
            S.lastStrongAt = now
            S.strongRun = S.strongRun + dt
            if S.strongRun >= STRONG_MIN then S.strongAuthoritative = true end
        else
            S.strongRun = 0
        end
        if not S.inFight then
            if not anySignal then
                S.lastReason = "idle"
                return "idle"
            end
            if (not strong) and now < S.relockUntil then
                S.lastReason = "relock"
                return "relock"
            end
            if (not strong) and S.blockWeakEntry then
                S.lastReason = "stale-block"
                return "stale-block"
            end
            local seq, sig = BuildSequence()
            S.seq, S.seqSig = seq, sig
            S.nextCastAt = 0
            EnterFight(now)
        elseif (S.strongAuthoritative and (now - S.lastStrongAt > EXIT_GRACE))
            or ((not S.strongAuthoritative) and (now - S.lastSignalAt > EXIT_GRACE)) then
            ExitFight(now)
            S.lastReason = "exit"
            return "exit"
        end
        if (not S.strongAuthoritative) and (now - S.fightStartAt > MAX_WEAK_FIGHT) then
            ExitFight(now)
            S.blockWeakEntry = true
            S.lastReason = "weak-timeout"
            W(string.format("弱信号战斗已持续 %.0fs，判定为咬钩缓存残留，强制收场", now - S.fightStartAt))
            return "weak-timeout"
        end
        local seq, sig = BuildSequence()
        if sig ~= S.seqSig then
            S.seq, S.seqSig = seq, sig
            S.stats.reset = S.stats.reset + 1
            SetIndex(1)
            L("顺序表变更，重新从第 1 位起手：" .. sig)
        elseif #S.seq == 0 then
            S.seq = seq
        end
        if #S.seq == 0 then
            S.lastReason = "no-skill"
            return "no-skill"
        end
        local firstCastOfFight = (S.stats.fightCast == 0)
        local warmBase, warmJit = StartDelay(), (S.warmJitter or 0)
        if firstCastOfFight and cfg.SkillFirstInstant ~= false then
            warmBase, warmJit = 0.20, 0
        end
        local waitLeft = (S.fightStartAt + warmBase + warmJit) - now
        if waitLeft > 0 then
            S.lastReason = "warmup"
            return "warmup"
        end
        if cfg.SkillCdProbe ~= false and ctx.readCooldown and now >= S.nextProbeAt then
            local hasProbe = false
            local probeKey
            for probeKey in pairs(S.probe) do hasProbe = true; break end
            if hasProbe then
                S.nextProbeAt = now + S.probeInterval
                local gotAny = false
                local slotP, deadlineP
                for slotP, deadlineP in pairs(S.probe) do
                    if now > deadlineP then
                        S.probe[slotP] = nil
                    elseif not S.deferOff[slotP] then
                        local okRead, v = pcall(ctx.readCooldown, slotP)
                        if okRead and type(v) == "number" and v >= 1 and v <= 1200
                            and ReadIsCredible(slotP, v, now) then
                            S.readyAt[slotP] = now + v + 0.15
                            S.probe[slotP] = nil
                            S.stats.probe = S.stats.probe + 1
                            gotAny = true
                        end
                    end
                end
                if gotAny then
                    S.probeFails = 0
                    S.probeInterval = 0.4
                else
                    S.probeFails = S.probeFails + 1
                    S.probeInterval = math.min(0.4 * (2 ^ math.min(S.probeFails, 3)), 3.2)
                end
            end
        end
        local panicKey = cfg.SkillPanicKey
        if not S.panicUsed and panicKey and panicKey ~= "关闭" and panicKey ~= "" then
            local hp = tonumber(ctx.hpPct)
            if hp and hp > 0 and hp <= PANIC_HP and now >= (S.readyAt[panicKey] or 0)
                and (now - S.lastCastAt) >= MIN_GAP then
                local okCast, res = pcall(ctx.cast, panicKey)
                if not okCast then res = "fail" end
                if res == "blocked" then
                    S.nextCastAt = now + RETRY_DELAY
                    S.lastReason = "gated"
                    return "gated"
                end
                if res ~= "fail" then
                    S.readyAt[panicKey] = now + CooldownFor(panicKey)
                    S.lastCastAt = now
                    S.nextCastAt = now + Gap() + Jit(0.25)
                    S.panicUsed = true
                    S.stats.cast = S.stats.cast + 1
                    S.stats.fightCast = S.stats.fightCast + 1
                    if cfg.SkillCdProbe ~= false and ctx.readCooldown then S.probe[panicKey] = now + 10.0 end
                    local curIdx = Index()
                    if S.seq[curIdx] == panicKey then
                        SetIndex((curIdx % #S.seq) + 1)
                    end
                    S.lastReason = "panic"
                    W(string.format("血量 %.0f%% 触发保命技能 %s", hp * 100, panicKey))
                    return "panic"
                end
            end
        end
        local gapReadyAt = S.nextCastAt
        if now < gapReadyAt then
            S.lastReason = "gap"
            return "gap"
        end
        if not S.stallWarned then
            local baseAt = math.max(S.lastCastAt or 0, S.fightStartAt or 0)
            if baseAt > 0 and (now - baseAt) >= 10 then
                S.stallWarned = true
                local curSlotW = S.seq[Index()] or "-"
                local leftW = math.max(0, (S.readyAt[curSlotW] or 0) - now)
                W(string.format("本场已 %.0f 秒没放出技能：当前位 %s 还需 %.0f 秒｜模式=%s｜顺序表=%s｜本场已放 %d 次。若是「严格轮流」请换成「优先(Z→X→C→V)」；若顺序表里只有 1 个技能，请把其他技能也勾上",
                    now - baseAt, tostring(curSlotW), leftW, OrderMode(), tostring(cfg.SkillOrder), S.stats.fightCast))
            end
        end
        local slot, pos, blockedLeft = PickSlot(now, ctx.readCooldown)
        if not slot then
            if OrderMode() == "blind" then
                S.nextCastAt = now + Gap()
                S.lastReason = "blind-skip"
                return "blind-skip"
            end
            S.nextCastAt = now + 0.30
            S.lastReason = "cooldown"
            return "cooldown"
        end
        if OrderMode() ~= "blind" and S.castThisFight[slot] and cfg.SkillCdProbe ~= false and ctx.readCooldown and not S.deferOff[slot] then
            local okPre, preLeft = pcall(ctx.readCooldown, slot)
            if okPre and type(preLeft) == "number" and preLeft >= 1 and preLeft <= 1200
                and ReadIsCredible(slot, preLeft, now) then
                S.readyAt[slot] = now + preLeft + 0.15
                S.probe[slot] = nil
                S.stats.probe = S.stats.probe + 1
                S.lastReason = "cooldown-ui"
                S.nextCastAt = now + 0.35
                local prevRead = S.lastRead[slot]
                if prevRead and preLeft < prevRead - 0.05 then S.deferCount[slot] = 0 end
                S.lastRead[slot] = preLeft
                local n = (S.deferCount[slot] or 0) + 1
                S.deferCount[slot] = n
                if n >= 10 then
                    S.deferOff[slot] = true
                    S.deferCount[slot] = 0
                    S.probe[slot] = nil
                    local learned = tonumber(S.lastRead[slot])
                    local cd = CooldownFor(slot)
                    if learned and learned > cd then cd = math.min(learned, 999) end
                    S.readyAt[slot] = now + cd
                    W(string.format("技能 %s 的界面读数连续 %d 次都是「冷却中」（最后一次读数 %s 秒），本场按 %.0fs 冷却处理",
                        slot, n, tostring(learned or "?"), cd))
                end
                return "cooldown-ui"
            end
        end
        local okCall, res = pcall(ctx.cast, slot)
        if not okCall then
            W("施法回调异常：" .. tostring(res))
            res = "fail"
        end
        if res == "blocked" then
            S.nextCastAt = now + RETRY_DELAY
            S.lastReason = "gated"
            return "gated"
        end
        if res == "fail" then
            S.castThisFight[slot] = true
            S.failCount[slot] = (S.failCount[slot] or 0) + 1
            S.stats.fail = S.stats.fail + 1
            S.nextCastAt = now + RETRY_DELAY
            S.lastReason = "cast-fail"
            if S.failCount[slot] >= MAX_SLOT_FAILS then
                S.broken[slot] = true
                S.stats.skip = S.stats.skip + 1
                SetIndex((pos % #S.seq) + 1)
                W(string.format("技能 %s 连续 %d 次释放失败，本场战斗内暂时跳过", slot, S.failCount[slot]))
            end
            return "cast-fail"
        end
        S.readyAt[slot] = now + CooldownFor(slot)
        S.castThisFight[slot] = true
        S.lastCastAt = now
        S.nextCastAt = now + Gap() + Jit(0.25)
        S.failCount[slot] = 0
        S.deferCount[slot] = 0
        S.lastRead[slot] = nil
        S.stats.cast = S.stats.cast + 1
        S.stats.fightCast = S.stats.fightCast + 1
        if cfg.SkillCdProbe ~= false and ctx.readCooldown then S.probe[slot] = now + 10.0 end
        SetIndex((pos % #S.seq) + 1)
        S.lastReason = "cast"
        return "cast"
    end
    function M.Suspend()
        if S.inFight then L("自动技能已关闭/挂起，重置战斗状态") end
        S.inFight = false
        S.relockUntil = 0
        S.panicUsed = false
        S.blockWeakEntry = false
        S.strongRun = 0
        S.strongAuthoritative = false
        ClearMap(S.deferOff)
        ClearMap(S.deferCount)
        S.probeFails = 0
        S.probeInterval = 0.4
        ClearMap(S.broken)
        ClearMap(S.failCount)
        ClearMap(S.castThisFight)
        SetIndex(1)
        S.lastReason = "suspended"
    end
    function M.IsInFight() return S.inFight end
    function M.GetDebugLine()
        local offCnt = 0
        local ok
        for ok in pairs(S.deferOff) do offCnt = offCnt + 1 end
        local modeTag = "顺序+跳过"
        local md = OrderMode()
        if md == "strict" then modeTag = "严格轮流"
        elseif md == "priority" then modeTag = "顺位优先"
        elseif md == "head" then modeTag = "Z优先"
        elseif md == "blind" then modeTag = "盲轮转" end
        local curSlot = S.seq[Index()] or "-"
        local nowT = tick()
        local function cdTag(sk)
            local left = (S.readyAt[sk] or 0) - nowT
            if left <= 0 then return sk .. "=就绪" end
            return string.format("%s=%.0fs", sk, left)
        end
        local slotLine = string.format("%s %s %s %s", cdTag("Z"), cdTag("X"), cdTag("C"), cdTag("V"))
        return string.format("模式=%s 顺序=%s 当前位=%s(%d/%d) 状态=%s | 冷却 %s | 本场释放=%d 累计=%d 失败=%d 跳过=%d 读冷却=%d 读数忽略=%d",
            modeTag, tostring(cfg.SkillOrder or "Z,X,C,V"), tostring(curSlot), Index(), #S.seq,
            tostring(S.lastReason), slotLine, S.stats.fightCast, S.stats.cast,
            S.stats.fail, S.stats.skip, S.stats.probe, offCnt)
    end
    return M
end
local autoSkillCtx = { inMinigame = false, weak = false, hpPct = nil, cast = nil }
local autoSkillSuspended = false
local function ParseCooldownText(raw)
    if type(raw) ~= "string" then return nil end
    local t = raw:gsub("%s+", "")
    if t == "" then return nil end
    if t:find("%%", 1, true) or t:find("/", 1, true) or t:find(",", 1, true) or t:find("+", 1, true) then return nil end
    local m, sec = t:match("^(%d+):(%d%d)$")
    if m then
        local v = tonumber(m) * 60 + tonumber(sec)
        if v and v >= 0 and v <= 1200 then return v end
        return nil
    end
    local num = t:match("^(%d+%.?%d*)[sS秒]?$")
    if not num then return nil end
    local v = tonumber(num)
    if not v or v < 0 or v > 1200 then return nil end
    return v
end
local function ReadCooldownNode(obj, slot, allowHidden)
    if not obj or not obj.Parent then return nil end
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then return nil end
    if not allowHidden and not obj.Visible then return nil end
    local txt = obj.Text
    if type(txt) ~= "string" or txt == "" then return nil end
    local trimmed = txt:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil end
    local up = trimmed:upper()
    if up == slot or up == ("[" .. slot .. "]") or up == ("SKILL" .. slot) or up == ("技能" .. slot) then return nil end
    return ParseCooldownText(trimmed)
end
local function IsOtherSkillWidget(obj, selfKey)
    if not obj then return false end
    local k
    for k = 1, #SKILL_KEYS do
        local key = SKILL_KEYS[k]
        if key ~= selfKey and DoesButtonMatchSkillKey(obj, key) then return true end
    end
    return false
end
local function ReadSkillCooldown(slot)
    local btn = GetSkillButtonRef(slot)
    if not btn then
        local okFind, found = pcall(GetCachedSkillButton, slot, tick())
        if okFind and found then btn = found end
    end
    if not btn then return nil end
    local v = ReadCooldownNode(btn, slot, true)
    if v then return v end
    if not (btn:IsA("GuiButton") and not btn.Active) then return nil end
    for _, ch in ipairs(btn:GetChildren()) do
        v = ReadCooldownNode(ch, slot, true)
        if v then return v end
    end
    local par = btn.Parent
    if par and par:IsA("GuiObject") and par.AbsoluteSize.X > 8 and par.AbsoluteSize.X <= 260 then
        for _, sib in ipairs(par:GetChildren()) do
            if sib ~= btn and not IsOtherSkillWidget(sib, slot) then
                v = ReadCooldownNode(sib, slot, true)
                if v then return v end
            end
        end
    end
    return nil
end
local function ASFireUI(slot)
    local btn = GetCachedSkillButton(slot, tick())
    if not (btn and btn.Visible) then return false end
    return FireGuiButton(btn, true) == true
end
local function ASFireRemote(slot)
    local rem = GetEventRemote("UseSkill") or GetEventRemote("TriggerMinigameSkill")
        or GetEventRemote(FSYC.Protocol and FSYC.Protocol.Remotes.CastSkill or "CastSkill") or GetEventRemote("ActivateSkill")
    if not (rem and rem:IsA("RemoteEvent")) then return false end
    return SafeFireEventCombat(rem, slot) == true
end
local function ASFireKey(slot)
    local kc = Enum.KeyCode[slot]
    if not (VirtualInputManager and kc) then return false end
    pressedVirtualKeys[kc] = true
    local okSend = pcall(function() VirtualInputManager:SendKeyEvent(true, kc, false, game) end)
    if not okSend then
        pressedVirtualKeys[kc] = nil
        return false
    end
    task.delay(0.06, function()
        pcall(function() VirtualInputManager:SendKeyEvent(false, kc, false, game) end)
        pressedVirtualKeys[kc] = nil
    end)
    return true
end
local function AutoSkillCastOnce(slot)
    if not FishGate.AllowCombat() then return "blocked" end
    local channel = tostring(Config.SkillChannel or "自动")
    local fired
    if channel == "屏幕按钮" then
        fired = ASFireUI(slot)
    elseif channel == "远程事件" then
        fired = ASFireRemote(slot)
    elseif channel == "模拟按键" then
        fired = ASFireKey(slot)
    elseif channel == "兼容(三通道全开)" then
        local a = ASFireRemote(slot)
        local b = ASFireKey(slot)
        local c = ASFireUI(slot)
        fired = a or b or c
    else
        fired = ASFireUI(slot)
        if not fired then fired = ASFireRemote(slot) end
        if not fired then fired = ASFireKey(slot) end
    end
    return fired and "ok" or "fail"
end
local AutoSkill = CreateAutoSkillEngine({
    config = Config,
    log = FLog,
    warn = FLogWarn,
    getIndex = function() return currentSkillIndex end,
    setIndex = function(v) currentSkillIndex = v end,
    jitter = function(max) return HRand(0, max) end,
})
DashUI._resetFishTimers = function()
    nextSlamAt = 0
    nextProgressionAt = 0
    DashUI._progressionHoldUntil = 0
    nextRhythmAt = 0
    nextQteAt = 0
    nextFishBtnRestoreAt = 0
    nextCastAt = 0
    autoSkillSuspended = false
    if AutoSkill and AutoSkill.Suspend then pcall(AutoSkill.Suspend) end
end
DashUI._autoSkillStatus = function()
    local okLine, line = pcall(AutoSkill.GetDebugLine)
    return okLine and line or "引擎状态不可用"
end
local function StepAutoSkills(now, strongMinigame, weakMinigame, hum)
    if not Config.AutoSkills then
        if not autoSkillSuspended then
            autoSkillSuspended = true
            pcall(AutoSkill.Suspend)
        end
        return
    end
    autoSkillSuspended = false
    local ctx = autoSkillCtx
    ctx.inMinigame = (strongMinigame == true)
    ctx.weak = (weakMinigame == true)
    local hp = nil
    if hum and hum.Parent then
        local maxHp, curHp = hum.MaxHealth, hum.Health
        if maxHp and maxHp > 0 and curHp and curHp > 0 then hp = curHp / maxHp end
    end
    ctx.hpPct = hp
    ctx.cast = AutoSkillCastOnce
    ctx.readCooldown = (Config.SkillCdProbe ~= false) and ReadSkillCooldown or nil
    local okStep, err = pcall(AutoSkill.Step, now, ctx)
    if not okStep then FLogWarn("自动技能", "节奏引擎异常：" .. tostring(err)) end
end
local CachedRhythmRem = nil
local BOSS_RHYTHM_MIN_GAP = FSYC.Tunables and FSYC.Tunables.RhythmMinGapSec or 0.30
local BossRhythmBudget = { lastAt = 0, count = 0, startedAt = 0, warned = false }
local function BossRhythmAllow(now)
    now = now or tick()
    if (now - BossRhythmBudget.lastAt) < BOSS_RHYTHM_MIN_GAP then return false end
    BossRhythmBudget.lastAt = now
    BossRhythmBudget.count = BossRhythmBudget.count + 1
    return true
end
local _charRefCache = { char = nil, root = nil, hum = nil }
local function GetCharRefs(char, needHum)
    if not char then return nil, nil end
    local c = _charRefCache
    if c.char ~= char then
        c.char, c.root, c.hum = char, nil, nil
    end
    local root = c.root
    if root and root.Parent ~= char then
        root = nil
        c.root = nil
    end
    if not root then
        root = char:FindFirstChild("HumanoidRootPart")
        c.root = root
    end
    if not needHum then return root, nil end
    local hum = c.hum
    if hum and hum.Parent ~= char then
        hum = nil
        c.hum = nil
    end
    if not hum then
        hum = char:FindFirstChildOfClass("Humanoid")
        c.hum = hum
    end
    return root, hum
end
local function ResolveHookedFishPos(fish)
    if not fish then return nil end
    local fishModel = fish:FindFirstChild("Model")
    if fishModel and fishModel:IsA("Model") then
        local okPv, cf = pcall(fishModel.GetPivot, fishModel)
        if okPv and cf then return cf.Position end
        return nil
    end
    local fishBuoy = fish:FindFirstChild("Buoy")
    if fishBuoy and fishBuoy:IsA("BasePart") then return fishBuoy.Position end
    return nil
end
local function stepHeartbeat()
    local char = LocalPlayer.Character
    local root, hum = GetCharRefs(char, true)
    if not root or not hum then return end
    local now = tick()
    local pData, _, _, fUI, bossBar = RefreshGuiAndDataRefs(now)
    if Config.PositionLock and not isMicroTeleportingNPC then
        if not lockedCFrame then lockedCFrame = root.CFrame end
        if (root.Position - lockedCFrame.Position).Magnitude > 3.5 then
            root.CFrame = lockedCFrame
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end
    if now - lastHookScanTime >= 0.25 then
        lastHookScanTime = now
        local fishesFolder = GetWorkspaceFolder("Fishes")
        if cachedHookedFish and cachedHookedFish.Parent == fishesFolder and cachedHookedFish:FindFirstChild(uidHealthKey) then
            cachedIsHooked = true
            if Config.FishRedRing then
                cachedHookedPos = ResolveHookedFishPos(cachedHookedFish)
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
                        if Config.FishRedRing then
                            cachedHookedPos = ResolveHookedFishPos(f)
                        end
                        break
                    end
                end
            end
        end
    end
    local inUndergroundRealm = (root.Position.Y < ((FSYC.Tunables and FSYC.Tunables.UndergroundYThreshold) or -50.0))
    local isFishing = attrFishing
    local isCD = attrCD
    local miniAttr = attrMinigame
    local fuiVisible = (fUI ~= nil and fUI.Visible) or false
    local bossVisible = (bossBar ~= nil and bossBar.Visible) or false
    local slamNeeded = miniAttr or cachedIsHooked or inUndergroundRealm
        or fuiVisible or bossVisible
    local activeSlamBtn = (Config.AutoSlam and slamNeeded and GetCachedSlamButton(now)) or nil
    if Config.ForceFishBtn and (now >= nextFishBtnRestoreAt) then
        nextFishBtnRestoreAt = now + 0.5
        pcall(RestoreMobileFishingButtonUI, false)
    end
    local isMinigame = miniAttr
        or fuiVisible
        or bossVisible
        or cachedIsHooked
        or (activeSlamBtn ~= nil and activeSlamBtn.Visible)
    local isSwimming = attrSwimming
    local useMinigameAssist = Config.AnchorBar or Config.OctoAutoMinigame
    local useSlamAssist = Config.OctoAutoMinigame
    local isBossEncounter = bossVisible
    local sig = fishGateSig
    sig.attrFishing = isFishing
    sig.attrMinigame = miniAttr
    sig.hooked = cachedIsHooked
    sig.bossBar = bossVisible
    sig.fui = fuiVisible
    sig.slam = (activeSlamBtn ~= nil and activeSlamBtn.Visible == true)
    sig.rawFight = isMinigame
    FishGate.Update(now, sig)
    local gateFight = FishGate.IsFight()
    if sharedEnv then
        sharedEnv.IdenticalCombatActive = (gateFight == true)
        sharedEnv.IdenticalCombatActiveAt = tick()
    end
    local gateIdle = FishGate.IsIdle()
    SafeStep("自动技能", StepAutoSkills, now, (miniAttr or bossVisible or cachedIsHooked), gateFight, hum)
    if isMinigame and not wasInMinigame then
        wasInMinigame = true
    elseif not isMinigame and wasInMinigame then
        wasInMinigame = false
        if not AutoSkill.IsInFight() and DashUI._releaseAllVirtualKeys then pcall(DashUI._releaseAllVirtualKeys) end
    end
    if gateFight then
        if (now >= nextSlamAt) then
            local didFire = false
            if Config.AutoSlam or useSlamAssist then
                local perfBtn = activeSlamBtn or GetCachedSlamButton(now)
                if perfBtn and perfBtn.Visible then
                    TriggerSlamEveryWay(perfBtn)
                    didFire = true
                elseif Config.AutoSlam and (now >= (DashUI._nextBlindSlamAt or 0)) then
                    DashUI._nextBlindSlamAt = now + HRand(0.22, 0.12)
                    TriggerSlamEveryWay(nil)
                    didFire = true
                end
            end
            if Config.AutoCharge or useSlamAssist then
                local chgBtn = (cachedChargeBtn and cachedChargeBtn.Parent and cachedChargeBtn.Visible) and cachedChargeBtn
                    or (fUI and fUI:FindFirstChild("Charge", true))
                if chgBtn and chgBtn.Visible then
                    FireGuiButton(chgBtn, true, true)
                    didFire = true
                end
            end
            if didFire then
                nextSlamAt = now + HRand(0.08, 0.05)
            else
                nextSlamAt = now + HRand(0.04, 0.02)
            end
        end
        if useMinigameAssist and (now >= nextProgressionAt) and now >= (DashUI._progressionHoldUntil or 0) then
            nextProgressionAt = now + (Config.InstantCatch and HRand(0.10, 0.03) or HRand(0.10, 0.05))
            local lastGameProg = sharedEnv and sharedEnv.IdenticalLastProgressionAt or 0
            if (now - lastGameProg) >= 0.09 then
                SafeFireEventCombat("UpdateFishProgression")
            end
        end
    elseif isFishing then
        nextCastAt = now + (tonumber(Config.CastDelay) or 1.0)
    elseif not gateIdle then
    else
        local holdingRodNow = IsCharacterHoldingFishingRod(char, pData)
        local shouldAutoCast = Config.AutoCast
            and not isMicroTeleportingNPC and not isSellingInProgress and not (FSYC.monkeyCtl and FSYC.monkeyCtl.running)
            and holdingRodNow and FishGate.AllowAutoCast(now)
        if shouldAutoCast then
            if sharedEnv then sharedEnv.IdenticalKeepFishBtnVisible = false end
        end
        if shouldAutoCast and not isCD and not isSwimming and (now >= nextCastAt) then
            nextCastAt = now + HRand(Config.CastDelay or 1.0, 0.25)
            local canCast = true
            if pData and pData:FindFirstChild("InventoryLimit") then
                local invCount = CountBagFish(pData, now)
                local maxLim = tonumber(DashUI._readValueBase(pData:FindFirstChild("InventoryLimit"), nil))
                if maxLim then
                    if Config.AutoSell and maxLim > 0 and invCount >= math.floor(maxLim * 0.9) and (now - lastFullBagSellTime >= 5.0) then
                        SafeSellAllFish(pData)
                        lastFullBagSellTime = now
                        canCast = false
                    end
                    if invCount >= maxLim then
                        canCast = false
                        if (now - lastFullBagWarnTime >= 30.0) then
                            lastFullBagWarnTime = now
                            local tail = Config.AutoSell
                                and "自动卖鱼没能清出空间，请检查卖鱼/上锁设置"
                                or "请开启【自动卖鱼】或手动清理背包，清出空间后会自动继续"
                            if FLog then
                                pcall(FLog, "自动抛竿", string.format("背包已满 %d/%d，暂停抛竿（AutoSell=%s）",
                                    invCount, maxLim, tostring(Config.AutoSell)))
                            end
                            if not DashUI._bagFullNotified then
                                DashUI._bagFullNotified = true
                                pcall(ShowNotification, "背包已满，自动抛竿已暂停",
                                    string.format("鱼袋 %d/%d；%s", invCount, maxLim, tail), "WARN", 6)
                            end
                        end
                    else
                        DashUI._bagFullNotified = false
                    end
                end
            end
            if canCast then
                local castBtn = GetMobileFishingButton(now)
                local clickedCastUI = false
                if castBtn and castBtn.Visible and castBtn.Active then
                    clickedCastUI = FireGuiButton(castBtn)
                end
                if not clickedCastUI then
                    SafeFireEventRemote("Fishing", root.CFrame)
                end
            end
        end
    end
    if Config.OctoAutoMinigame and (now >= nextRhythmAt) then
        local beatBase = tonumber(Config.RhythmBeatSec) or 0.34
        if beatBase < BOSS_RHYTHM_MIN_GAP then beatBase = BOSS_RHYTHM_MIN_GAP end
        if beatBase > 1.0 then beatBase = 1.0 end
        nextRhythmAt = now + (gateFight and (beatBase * (0.80 + math.random() * 0.40)) or HRand(0.50, 0.10))
        local acc = tonumber(Config.RhythmAccuracy) or 100
        local hitPass = (acc >= 100) or (math.random(1, 100) <= acc)
        local rhythmInCombat = gateFight or (inUndergroundRealm and (miniAttr or bossVisible or cachedIsHooked or (now < (DashUI._rhythmActiveUntil or 0))))
        if hitPass and Events and rhythmInCombat and BossRhythmAllow(now) then
            local rh = CachedRhythmRem
            if not rh or rh.Parent ~= Events then
                rh = GetEventRemote("RhythmHit")
                CachedRhythmRem = rh
            end
            if rh and rh:IsA("RemoteEvent") then
                SafeFireEventCombat(rh, "hit")
            end
        end
        if hitPass and rhythmInCombat and isBossEncounter and (now >= nextQteAt) then
            nextQteAt = now + HRand(0.12, 0.05)
            if BossRhythmAllow(now) then
                local fishBtn = GetMobileFishingButton(now)
                if fishBtn and fishBtn.Visible then
                    FireGuiButton(fishBtn)
                end
                if bossBar and bossBar:IsA("GuiButton") then FireGuiButton(bossBar) end
            end
        end
        if Config.OctoAutoMinigame and inUndergroundRealm and not gateFight and not isFishing and (now >= nextBossPromptAt) then
            nextBossPromptAt = now + HRand(0.1, 0.08)
            PruneAndTriggerBossPrompts()
        end
    end
end
table.insert(activeConnections, RunService.Heartbeat:Connect(function()
    if not isRunning then return end
    SafeStep("Heartbeat主循环", stepHeartbeat)
end))
FLog("启动/心跳", "Heartbeat 主循环已注册")
pcall(function()
    if type(RunService.BindToRenderStep) == "function" then
        pcall(function() RunService:UnbindFromRenderStep("IdenticalForceFishBtnVisible") end)
        local lastPrio = (Enum.RenderPriority and Enum.RenderPriority.Last and Enum.RenderPriority.Last.Value) or 2000
        RunService:BindToRenderStep("IdenticalForceFishBtnVisible", lastPrio, function()
            if not isRunning then return end
            if Config.ForceFishBtn then
                local fb = cachedMobileFishBtn
                if fb and fb.Parent then
                    if fb.Visible ~= true then fb.Visible = true end
                    if fb.Active ~= true then fb.Active = true end
                    local par = fb.Parent
                    if par and par ~= cachedMainGui and par:IsA("GuiObject") and par.Visible ~= true then
                        par.Visible = true
                    end
                end
                if cachedMobileFishContainer and cachedMobileFishContainer.Parent
                    and cachedMobileFishContainer.Visible ~= true then
                    cachedMobileFishContainer.Visible = true
                end
            end
        end)
    end
end)
local UDIM2_CENTER = UDim2.new(0.5, 0, 0.5, 0)
local UDIM2_FULL = UDim2.new(1, 0, 1, 0)
local function stepRenderAssist(now)
    local _, _, _, fUI, bossBar = RefreshGuiAndDataRefs(now or tick())
    if fUI and fUI.Visible then
        if Config.AnchorBar then
            if cachedBarInner and cachedBarInner.Parent and cachedBarInner.Position ~= UDIM2_CENTER then
                cachedBarInner.Position = UDIM2_CENTER
            end
            if cachedProgBarInner and cachedProgBarInner.Parent and cachedProgBarInner.Size ~= UDIM2_FULL then
                cachedProgBarInner.Size = UDIM2_FULL
            end
        end
        if (Config.OctoAutoMinigame or Config.AnchorBar) and not Config.RealBossHit and bossBar and bossBar.Visible then
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
            cachedHurt1.ImageTransparency = 1
        end
        if cachedHurt2 and cachedHurt2.Parent and cachedHurt2.ImageTransparency ~= 1 then
            cachedHurt2.ImageTransparency = 1
        end
    end
end
local function stepFishRedRing(char, now)
    now = now or tick()
    if (not cachedFishConstraint or not cachedFishConstraint.Parent or not cachedFishConstraint.Attachment1) and (now - FSYC.lastConstraintSearch >= 0.5) then
        FSYC.lastConstraintSearch = now
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
table.insert(activeConnections, RunService.RenderStepped:Connect(SafeConnect("渲染帧", function()
    if not isRunning then return end
    local char = LocalPlayer.Character
    local root = GetCharRefs(char, false)
    if not root then return end
    local useAssist = Config.AnchorBar or Config.OctoAutoMinigame
    local miniAttrNow = attrMinigame
    local needRenderAssist = false
    if useAssist then
        needRenderAssist = wasInMinigame or miniAttrNow or cachedIsHooked
            or (cachedFUI ~= nil and cachedFUI.Parent ~= nil and cachedFUI.Visible)
            or (cachedBossBar ~= nil and cachedBossBar.Parent ~= nil and cachedBossBar.Visible)
    end
    local needFishRing = (Config.FishRedRing and char ~= nil and (attrFishing or miniAttrNow or cachedIsHooked)) or false
    if Config.RealBossHit and RealBoss.active then pcall(RealBossStep, tick()) end
    if needRenderAssist or needFishRing then
        local frameNow = tick()
        if needRenderAssist then
            SafeStep("渲染辅助", stepRenderAssist, frameNow)
        end
        if needFishRing then
            SafeStep("鱼目标光圈", stepFishRedRing, char, frameNow)
        elseif fishRingAdornment.Visible then
            fishRingAdornment.Visible = false
            lastFishRingPos = nil
        end
    elseif fishRingAdornment.Visible then
        fishRingAdornment.Visible = false
        lastFishRingPos = nil
    end
end)))
FLog("启动/渲染", "RenderStepped 渲染循环已注册")
local OBS = {
    fishByName = {}, fishOrder = {}, fishTotal = 0,
    skillLastAt = {}, skillCount = {}, skillCD = {}, skillOrder = {},
    cleanup = 0,
    uiAt = 0,
}
local OBS_SKILL_DEDUP = FSYC.Tunables and FSYC.Tunables.ObsSkillDedupSec or 0.20
local OBS_CD_MIN_GAP = FSYC.Tunables and FSYC.Tunables.ObsCdMinGapSec or 1.0
local OBS_CD_MAX_GAP = FSYC.Tunables and FSYC.Tunables.ObsCdMaxGapSec or 300.0
local function OBS_SkillName(vfx)
    if typeof(vfx) ~= "Instance" then return nil end
    local par = vfx.Parent
    if par and par.Name ~= "Skill" then return par.Name end
    return vfx.Name
end
local function OBS_RefreshUI(now)
    if now - OBS.uiAt < 0.25 then return end
    OBS.uiAt = now
    local rowFish = DashUI.infoFishLive
    if rowFish and rowFish.Set then
        if OBS.fishTotal <= 0 then
            rowFish.Set("—")
        else
            local parts = {}
            for i = 1, #OBS.fishOrder do
                if i > 3 then break end
                local n = OBS.fishOrder[i]
                parts[#parts + 1] = n .. " ×" .. tostring(OBS.fishByName[n] or 0)
            end
            rowFish.Set("共 " .. OBS.fishTotal .. " 条｜" .. table.concat(parts, " / "))
        end
    end
    local rowSkill = DashUI.infoSkillCD
    if rowSkill and rowSkill.Set then
        local parts = {}
        for i = 1, #OBS.skillOrder do
            if #parts >= 2 then break end
            local n = OBS.skillOrder[i]
            local cd = OBS.skillCD[n]
            if cd then parts[#parts + 1] = n .. " " .. string.format("%.1fs", cd) end
        end
        rowSkill.Set(#parts > 0 and table.concat(parts, " / ") or "采集中…")
    end
end
local function IsSelfBroadcast(who)
    if typeof(who) ~= "Instance" then return true end
    if who == LocalPlayer then return true end
    local selfChar = LocalPlayer.Character
    if selfChar and who == selfChar then return true end
    local owner = nil
    pcall(function() owner = Players:GetPlayerFromCharacter(who) end)
    return owner == LocalPlayer
end
local function OBS_OnFishCaught(who, fishName)
    if not IsSelfBroadcast(who) then return end
    if type(fishName) ~= "string" or fishName == "" then return end
    OBS.fishTotal = OBS.fishTotal + 1
    if not OBS.fishByName[fishName] then
        OBS.fishByName[fishName] = 0
        OBS.fishOrder[#OBS.fishOrder + 1] = fishName
    end
    OBS.fishByName[fishName] = OBS.fishByName[fishName] + 1
    OBS_RefreshUI(tick())
end
local function OBS_OnCleanup()
    OBS.cleanup = OBS.cleanup + 1
end
local function OBS_OnSkillRendered(who, vfx)
    if not IsSelfBroadcast(who) then return end
    local name = OBS_SkillName(vfx)
    if not name then return end
    local now = tick()
    local last = OBS.skillLastAt[name]
    if last and (now - last) < OBS_SKILL_DEDUP then return end
    OBS.skillLastAt[name] = now
    if not OBS.skillCount[name] then
        OBS.skillCount[name] = 0
        OBS.skillOrder[#OBS.skillOrder + 1] = name
    end
    OBS.skillCount[name] = OBS.skillCount[name] + 1
    if last then
        local gap = now - last
        if gap >= OBS_CD_MIN_GAP and gap <= OBS_CD_MAX_GAP then
            local cur = OBS.skillCD[name]
            if not cur or gap < cur then OBS.skillCD[name] = gap end
        end
    end
    OBS_RefreshUI(now)
end
DashUI._obsStats = function()
    return {
        fishTotal = OBS.fishTotal, fishByName = OBS.fishByName,
        skillCount = OBS.skillCount, skillCD = OBS.skillCD,
        cleanup = OBS.cleanup,
    }
end
local dynMinigameRemoteBound = setmetatable({}, { __mode = "k" })
local function ConnectDynamicMinigameRemote(rem)
    if not rem or not rem:IsA("RemoteEvent") then return end
    if dynMinigameRemoteBound[rem] then return end
    dynMinigameRemoteBound[rem] = true
    local rName = rem.Name
    if rName == "Slam" or rName:find("Slam", 1, true) then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(slamEvent)
            if isRunning and Config.AutoSlam then
                pcall(function()
                    TriggerSlamEveryWay(GetCachedSlamButton(tick()))
                end)
            end
        end))
    elseif rName == "Charge" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(chargeEvent)
            if isRunning and Config.AutoCharge then
                pcall(function()
                    local chgBtn = (cachedChargeBtn and cachedChargeBtn.Parent and cachedChargeBtn.Visible) and cachedChargeBtn
                        or (cachedFUI and cachedFUI:FindFirstChild("Charge", true))
                    if chgBtn and chgBtn.Visible then FireGuiButton(chgBtn, true, true) end
                end)
            end
        end))
    elseif rName == "RhythmStart" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(cfgTbl)
            if not isRunning then return end
            local dur = (type(cfgTbl) == "table" and tonumber(cfgTbl.Duration or cfgTbl.Time)) or 125.0
            DashUI._rhythmActiveUntil = tick() + math.clamp(dur, 10.0, 180.0)
            if type(cfgTbl) == "table" then
                BossRhythmBudget.lastAt = 0
                BossRhythmBudget.count = 0
                BossRhythmBudget.startedAt = tick()
                local hp = tonumber(cfgTbl.FinalMaxHP)
                local dmg = tonumber(cfgTbl.DealDMG)
                if hp and dmg and hp > 0 and dmg > 0 then
                    local needHits = math.ceil(hp / dmg)
                    local beat = tonumber(Config.RhythmBeatSec) or 0.34
                    if beat < BOSS_RHYTHM_MIN_GAP then beat = BOSS_RHYTHM_MIN_GAP end
                    local eta = needHits * beat
                    local limit = tonumber(cfgTbl.MiniGameTime) or 120
                    if FLog then
                        pcall(FLog, "Boss/节奏", string.format(
                            "本场 %d 血 / 每击 %d → 需 %d 次命中；按 %.2fs 预计 %.0fs 击杀（限时 %ds，真人实测约 103s）",
                            hp, dmg, needHits, beat, eta, limit))
                    end
                    if eta < 86 and not BossRhythmBudget.warned then
                        BossRhythmBudget.warned = true
                        pcall(ShowNotification, "节奏安全",
                            string.format("本场预计 %.0fs 击杀，低于 86s 安全线，已强制按 0.30s 限速。", eta), "WARN", 5)
                    end
                end
            end
        end))
    elseif rName == "RhythmEnd" or rName == "RhythmStop" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            DashUI._rhythmActiveUntil = 0
        end))
    elseif (rName:find("Rhythm") or rName:find("Octo") or rName:find("QTE") or rName:find("Boss"))
        and not (rName:find("Reward") or rName:find("Spawn") or rName:find("Shop")
            or rName:find("Data") or rName:find("Notify") or rName:find("Chest")
            or rName:find("Phase2") or rName:find("Start") or rName:find("Setup")
            or rName:find("End") or rName:find("Stop") or rName:find("Init") or rName:find("State")
            or rName == "RhythmHit") then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(dynArg, ...)
            if isRunning and Config.OctoAutoMinigame and FishGate.AllowCombat()
                and (tick() - (DashUI._octoEchoAt or 0)) >= 0.25 then
                DashUI._octoEchoAt = tick()
                local targetRem = (typeof(dynArg) == "Instance" and dynArg:IsA("RemoteEvent")) and dynArg or rem
                SafeFireEventCombat(targetRem, "Perfect")
            end
        end))
    elseif rName == "RenderSkillToClients" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(obsTarget, obsVfx)
            if not isRunning then return end
            pcall(OBS_OnSkillRendered, obsTarget, obsVfx)
        end))
    elseif rName == "CleanUp" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            pcall(OBS_OnCleanup)
        end))
    elseif rName == "BossPhase2Setup" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(setup)
            if not isRunning then return end
            pcall(RealBossActivate, setup)
        end))
    elseif rName == "FishingMinigame" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(kind)
            if not isRunning then return end
            local endKey = nil
            if type(kind) == "string" then
                endKey = kind:lower()
            elseif type(kind) == "table" then
                local rawAct = kind.Action or kind.Type or kind.State or kind.Status or kind[1]
                if type(rawAct) == "string" then endKey = rawAct:lower() end
            end
            local endMap = FSYC.Protocol and FSYC.Protocol.SessionEndKeywords
            if endKey and ((endMap and endMap[endKey]) or endKey == "sessionend") then
                DashUI._progressionHoldUntil = tick() + 0.90
                pcall(RealBossDeactivate, "SessionEnd")
            end
        end))
    elseif rName == "ReadyTimeFX" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(readyVal)
            if not isRunning then return end
            if type(readyVal) == "string" and readyVal == "LOCK" then
                DashUI._progressionHoldUntil = 0
            end
        end))
    elseif rName == "NotifyDamage" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            pcall(RealBossOnDamage)
        end))
    elseif rName == "StartDialogue" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(dlgId, dlgNpc, dlgBody, dlgRet)
            if not isRunning then return end
            FSYC.FSYDialogueOpenedAt = tick()
            if type(dlgId) ~= "string" or dlgId == "" or type(dlgBody) ~= "table" then
                FSYC.DialogueState = nil
                return
            end
            FSYC.DialogueSeq = (tonumber(FSYC.DialogueSeq) or 0) + 1
            FSYC.DialogueState = {
                id = dlgId,
                npc = dlgNpc,
                body = dlgBody,
                ret = dlgRet,
                at = tick(),
                seq = FSYC.DialogueSeq,
            }
        end))
    elseif rName == "UpdateFishingRodShop" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(rodList)
            if not isRunning or type(rodList) ~= "table" then return end
            local norm = {}
            for i = 1, #rodList do
                if type(rodList[i]) == "string" then norm[#norm + 1] = rodList[i] end
            end
            FLog("竿店", "服务端竿名清单: " .. table.concat(norm, " | "))
            if rodPowerLookupLower then
                local missing = {}
                for i = 1, #norm do
                    if not rodPowerLookupLower[string.lower(norm[i])] then missing[#missing + 1] = norm[i] end
                end
                if #missing > 0 then
                    FLogWarn("竿店", "以下服务端竿名未收录进静态战力表: " .. table.concat(missing, " | "))
                end
            end
        end))
    elseif rName == "ReplicateFishCaught" or rName == "NotifyFish" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(fishWho, fishName)
            if not isRunning then return end
            if rName == "ReplicateFishCaught" then
                pcall(OBS_OnFishCaught, fishWho, fishName)
                if not IsSelfBroadcast(fishWho) then return end
            end
            task.delay(0.35, function()
                if isRunning and LocalPlayer and LocalPlayer.Character and not attrFishing and not attrMinigame and StopLingeringFishingAnimations then
                    local curChar = LocalPlayer.Character
                    local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(curChar)
                    if not stillHolding then
                        StopLingeringFishingAnimations(curChar)
                    end
                end
            end)
            if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) then return end
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
local watchedEventsFolders = setmetatable({}, { __mode = "k" })
local function BindEventsFolderRemotes(evFolder)
    if not evFolder or watchedEventsFolders[evFolder] then return end
    watchedEventsFolders[evFolder] = true
    Events = evFolder
    for _, child in ipairs(evFolder:GetChildren()) do
        ConnectDynamicMinigameRemote(child)
    end
    table.insert(activeConnections, evFolder.ChildAdded:Connect(ConnectDynamicMinigameRemote))
end
if Events then BindEventsFolderRemotes(Events) end
if ReplicatedStorage then
    table.insert(activeConnections, ReplicatedStorage.ChildAdded:Connect(function(ch)
        if isRunning and ch then
            local candidates = FSYC.Protocol and FSYC.Protocol.EventFolderCandidates or {"Events", "Remotes", "RemoteEvents", "Network"}
            for i = 1, #candidates do
                if ch.Name == candidates[i] then
                    BindEventsFolderRemotes(ch)
                    FLog("事件", "检测到远程事件容器 " .. tostring(ch.Name) .. " 已加载完成，远程功能自动恢复")
                    break
                end
            end
        end
    end))
end
end
print("[FSY][BOOT] 4/5 UI 外壳与全部页面装配完成，准备启动运行时")
local okBoot, bootErr = pcall(IdenticalStartRuntimeLoops)
if not okBoot then
    FLogErr("启动", "运行时引擎初始化失败，自动化功能不可用: " .. tostring(bootErr))
    if ShowNotification then
        ShowNotification("FSY 启动异常", "自动化引擎初始化失败，请查看控制台日志后重进", "ERROR", 8)
    end
end
pcall(function()
    table.insert(activeConnections, LocalPlayer.Idled:Connect(function()
        if Config.AntiAFK and isRunning then
            pcall(function()
                local vu = game:GetService("VirtualUser")
                if vu then
                    vu:CaptureController()
                    vu:ClickButton2(Vector2.new(0, 0))
                end
            end)
        end
    end))
end)
table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or (type(input) == "table" and input._isFSYSynthetic) then return end
    if not ModeCtl.AllowKeyboardShortcuts() then return end
    local uiKeybind = (typeof(Config.UIKeybind) == "EnumItem" and Config.UIKeybind) or Enum.KeyCode.RightControl
    local stopKeybind = (typeof(Config.StopKeybind) == "EnumItem" and Config.StopKeybind) or Enum.KeyCode.End
    if (input.KeyCode == Enum.KeyCode.RightControl or input.KeyCode == uiKeybind)
        and input.KeyCode ~= stopKeybind then
        if ToggleUiVisibility then ToggleUiVisibility() end
    elseif input.KeyCode == Enum.KeyCode.Escape and mainFrame and mainFrame.Visible then
        CloseUI()
    elseif input.KeyCode == Enum.KeyCode.End or input.KeyCode == stopKeybind then
        UnloadScript()
    end
end))
ShowNotification("FSY " .. FSY_VERSION, string.format("脚本已加载完成！当前 %s，%s。点击右上角 [FSY] 收起为悬浮球；【配置文件 → 设备与输入】可切换模式",
    ModeCtl.Label(), Config.InputIsolation and "输入隔离已开" or "输入隔离已关"), "SUCCESS", 5)
FLog("启动", okBoot and "初始化完成：UI 静态节点与后台时间片调度器已就绪"
    or "初始化未完成：自动化引擎不可用，详见上一条 ERROR 日志")
