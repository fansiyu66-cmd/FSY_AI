-- ============================================================================
-- 【模块 01：执行器环境初始化与Roblox核心服务引用】
-- 作用：安全获取执行器全局环境 getgenv，重复注入时先调用上一次的卸载函数清理旧实例；集中获取核心服务。
-- 后续修改指引：引入新的 Roblox 服务（如 MarketplaceService）请在此模块顶部统一 GetService。
-- ============================================================================
local sharedEnv = nil
if type(getgenv) == "function" then
    local envOk, envValue = pcall(getgenv)
    if envOk and type(envValue) == "table" then sharedEnv = envValue end
end

-- [审计修复 R-02] 启动令牌与前置卸载：在等待游戏加载前先登记递增启动令牌并尝试卸载旧实例；
-- 若加载等待期间发生二次注入，旧实例唤醒后检测到令牌被覆盖即刻早退，杜绝双实例并存与双倍发包。
if sharedEnv then
    sharedEnv.IdenticalFishingBootToken = (tonumber(sharedEnv.IdenticalFishingBootToken) or 0) + 1
    if type(sharedEnv.IdenticalHeavyweightFishingUnload) == "function" then
        pcall(sharedEnv.IdenticalHeavyweightFishingUnload)
    end
end
local myBootToken = sharedEnv and sharedEnv.IdenticalFishingBootToken or nil

-- [V15.44 / DIAG] 每次注入打印一次服务器身份。出现「自动重进」时看这一行即可定性：
--   JobId 不变 = 客户端空闲/网络断线后被 Roblox 自动重连回同一实例（脚本只是被动）；
--   JobId 变化 = 脚本自己发起了 Teleport（模块 23 被踢重连 / 模块 10 跨服跳转）。
-- 只有这一行 print，不会刷屏。
pcall(function()
    print(string.format("[FSY][BOOT] JobId=%s PlaceId=%d Time=%d", tostring(game.JobId), game.PlaceId, os.time()))
end)

-- 等待客户端场景加载完成（最多 20s 超时兜底，防止断线重连或黑屏时永久挂起）
if not game:IsLoaded() then
    local loadedDeadline = tick() + 20
    while not game:IsLoaded() and tick() < loadedDeadline do task.wait(0.2) end
end
if sharedEnv and myBootToken and sharedEnv.IdenticalFishingBootToken ~= myBootToken then
    return
end

-- 重复执行时先卸载旧实例；卸载失败不阻断本次启动
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
-- CoreGui / Stats 在受限执行器身份下可能受权限限制，容错获取
local CoreGui = SafeGetService("CoreGui")
local Stats = SafeGetService("Stats")

-- ============================================================================
-- 【模块 02：原始画质/雾效/游戏原生UI状态备份与还原】
-- 作用：备份启动前的 Lighting 光照、Atmosphere 大气雾效、相机粒子及原生 ScreenGui 显隐状态，
--   由 RestoreNoFogChanges() 与 SetGameUIHidden() 在关闭视觉功能或卸载脚本时精确恢复原状。
-- 后续修改指引：游戏新增原生 HUD 界面名称时，在 SetGameUIHidden 的 {"MainGui", "Fisher_GUI"} 列表中追加。
-- ============================================================================
-- 保存脚本启动前的环境值，卸载时恢复原状，避免强制写入固定画质参数。
-- Lighting 取不到时不得让顶层崩掉：备份失败退化为空表，还原阶段逐键判空
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
-- 原生 HUD 备份「按名字」再存一份：originalGameGuiState 是弱键表，切图重建实例时旧键会被回收，之后关掉「隐藏游戏UI」就无处还原。
local gameGuiEnabledBackup = {}
-- 切换游戏原生 HUD（MainGui / Fisher_GUI）显隐状态，并在关闭隐藏时恢复原值
local function SetGameUIHidden(hidden)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, guiName in ipairs({"MainGui", "Fisher_GUI"}) do
        local gui = pg:FindFirstChild(guiName)
        if gui and gui:IsA("ScreenGui") then
            if hidden then
                -- 双份登记：实例键（原语义保留）+ 名字键（抗实例重建）
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

-- ============================================================================
-- 【模块 03：全局生命周期控制、按需拖拽连接池与视口防抖缩放监听】
-- 作用：维护 isRunning、常驻事件表 activeConnections、临时拖拽连接池 activeDragConns；
--   监听屏幕旋转或窗口大小变化 (ViewportSize)，通过 task.defer 合并同一帧内的缩放重算请求。
-- 后续修改指引：新增全局常驻事件连接请 table.insert 到 activeConnections；拖拽类临时连接用 RegisterTempDragConn。
-- ============================================================================
local isRunning = true
local activeConnections = {}
-- 动态拖拽连接池：仅在拖拽进行中挂载 UIS 连接，松手立即断开，卸载时兜底清理
local activeDragConns = {}
-- 受管协程与计时器池、滑块滚动锁恢复池与按下虚拟键追踪池（用于卸载时完整回收与恢复输入）
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
                    local ok, err = pcall(fn, unpackFn(args, 1, args.n))
                    if th then activeThreads[th] = nil end
                    if not ok then error(err, 0) end
                elseif th then
                    activeThreads[th] = nil
                end
            end)
            if isRunning and th and coroutine.status(th) ~= "dead" then activeThreads[th] = true end
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
-- ============================================================================
-- 【模块 03-A：轻量调试日志 (FLog / FLogWarn / FLogErr / SafeStep)】
-- 作用：统一 [FSY][级别][标签] 前缀输出；同一「级别+标签」2 秒内只打印一次并累积合并条数，避免高频循环刷爆控制台。
--   保留最近 120 条日志，可随时通过 sharedEnv.IdenticalFishingDumpLogs() 导出排查；SafeStep 包裹各后台轮询步骤，
--   异常只记录日志、不静默吞掉，也不会因为单步异常让后续功能"看似开着却不生效"。
-- 后续修改指引：关闭普通日志：Config.DebugLog = false（注意：此时 INFO 与 WARN 均不输出，仅 ERROR 恒输出）。
-- ============================================================================
-- 供后续作用域外引用的名字折叠函数别名（在 LowerInstName 定义处赋值）
local LowerInstNameG
local FLog, FLogWarn, FLogErr, SafeStep, SafeConnect
do
local FLOG_BUFFER_SIZE = 120
local FLogBuffer = {}
local FLogSuppressed = {}
local function FLogEmit(level, tag, msg)
    -- 注意：此处早于「local FSYC = {}」声明，写 FSYC.xxx 会解析成全局 nil（无效）；只用 sharedEnv 契约字段
    local cfgTable = sharedEnv and sharedEnv.IdenticalFishingConfig
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
    if level ~= "ERROR" and (not cfgTable or cfgTable.DebugLog ~= true) then return end
    if level == "INFO" then print(line) else warn(line) end
end
FLog = function(tag, msg) FLogEmit("INFO", tag, msg) end
FLogWarn = function(tag, msg) FLogEmit("WARN", tag, msg) end
FLogErr = function(tag, err) FLogEmit("ERROR", tag, tostring(err)) end
-- 后台轮询统一保护壳：捕获异常 -> 记录日志 -> 返回 false，绝不静默吞异常
SafeStep = function(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then FLogErr(tag, err) end
    return ok
end
-- 常驻事件回调的统一包装：isRunning 守卫 + pcall 隔离 + 中文错误日志；用于 RenderStepped 这类热回调，
-- 把逐帧 traceback 降为每 2 秒一条 ERROR 日志，避免异常直接抛给引擎（包装器只在加载期创建一次，运行期零闭包分配）。
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

-- 按字节截断不得切断多字节字符（UTF-8 续字节 0x80~0xBF），否则 Config 写入非法 UTF-8 会导致整份 JSON 编码/保存失败。
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

-- 轻量补间工具：同一实例复用 Tween、完成即回收，避免每行预创建常驻 Tween
local activeQuickTweens = setmetatable({}, { __mode = "k" })
-- 主块顶层局部变量已逼近 Lua/Luau 单函数硬上限 200（超过即 too many local variables 编译失败）；
-- 一次性常量/初始化期专用句柄一律挂 FSYC.xxx，不要再往顶层堆 local。
local FSYC = {}
FSYC.FAST_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- 顶部统一配置区：集中收拢发包延时、限流退避、状态锁宽限、技能冷却、协议字段与核心坐标
FSYC.Tunables = {
    -- 发包限流、去重与异常指数退避参数
    PacketDefaultWindowMs = 40,
    PacketCombatWindowMs = 10,
    PacketSweepInterval = 512,
    InvokeDefaultTimeoutSec = 4.0,
    RemoteBackoffBaseSec = 0.50,
-- 退避上限 1.20s：恩佐二阶段是「回血 vs 扣血」的赛跑，静默 8s 等于必输；1.20s 仍能阻止"报错后逐帧重发"。
    RemoteBackoffMaxSec = 1.20,
-- 战斗域远程（Slam / 节奏 / BossPhase2Action / 技能）单独一档：退避照做但上限只到 0.35s，保证战斗中最多漏几帧、不会长时间失联。
    CombatBackoffBaseSec = 0.10,
    CombatBackoffMaxSec = 0.35,
    CombatFreshTtlSec = 0.50,
    -- 钓鱼状态闸门 (FishingStateGate) 阈值与宽限参数
    GateFightExitGraceSec = 0.80,
    GateActiveExitGraceSec = 0.40,
    GateQuietAfterExitSec = 0.25,
    GateWarnBlockStreakSec = 6.0,
    GateMaxGhostFightSec = 240.0,
    -- 自动技能调度引擎 (AutoSkillEngine) 阈值与冷却参数
    SkillExitGraceSec = 1.5,
    SkillRetryDelaySec = 0.4,
    SkillMaxSlotFails = 3,
    SkillMinGapSec = 0.12,
    SkillPanicHpRatio = 0.35,
    SkillReenterLockSec = 5.0,
    SkillStrongMinSec = 0.5,
    SkillMaxWeakFightSec = 90.0,
    -- Boss 二阶段读条判定 (RealBoss) 阈值与限流参数
    RealBossHardGapSec = 0.50,
-- 只作兜底保险：真正的停手条件是「判定条消失 / 离开战斗」而不是包数（120 太小：0.18s 档 21.6 秒就打光，实测该阶段约 24.6 秒，会让后半段彻底不上报）。
    RealBossMaxSends = 500,
    RealBossMaxDurationSec = 200.0,
    RealBossMissHeartbeatSec = 2.5,
    RealBossRetryBaseSec = 0.08,
    RealBossRetryMaxSec = 1.00,
    -- 背包保护锁、自动卖鱼、低频自动化与自动配装周期
    LockSettlingWindowSec = 2.0,
    EquipCheckIntervalSec = 5.0,
    DailyAutoIntervalSec = 300.0,
    CraftAutoIntervalSec = 10.0,
    MonkeyGiveIntervalSec = 4.0,
    UndergroundYThreshold = -50.0,
    -- 节奏（无名章鱼）命中最小间隔：与下面 BOSS_RHYTHM_MIN_GAP 同值搬迁
    RhythmMinGapSec = 0.30,
    -- OBS 只读观测的去重/采样窗口
    ObsSkillDedupSec = 0.20,
    ObsCdMinGapSec = 1.0,
    ObsCdMaxGapSec = 300.0,
    -- 预建池容量（静态 UI：加载期一次建满，运行期只复用）
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
-- 兼容客户端协议目录改名的事件容器解析函数
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
        -- 直接传递方法引用取代匿名闭包，消除每次补间取消/创建/播放时的 3 次闭包分配
        pcall(prev.Cancel, prev)
    end
    -- 目标值已经达成时直接返回：鼠标快速划过列表时不再反复创建无意义的原生 Tween（降低 GC 抖动）
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
        -- 下一个补间开始时统一 Cancel 上一次原生 Tween，避免频繁绑定 Completed 回调堆积
        pcall(tw.Play, tw)
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
local currentlyOpenDropdown = nil

-- ============================================================================
-- 【C14 拟人化时长工具】仅用于「动作节奏」的抖动量，禁止用于检测窗口或阈值比较
-- ============================================================================
-- 返回 [base, base+span] 之间的随机秒数；base/span 非法时退化为 base，保证不缩短原有间隔
local HRand = function(base, span)
    base = tonumber(base) or 0
    span = tonumber(span) or 0
    if base < 0 then base = 0 end
    if span <= 0 then return base end
    local r = math.random()
    if type(r) ~= "number" or r ~= r then return base end
    return base + r * span
end
-- 拟人化等待：base 取原固定值，span 取增量上限（上限见 BRIEF §11：点击/轻交互 ≤0.12，
-- 技能/施法 ≤0.25，对话/UI ≤0.45，传送/远程序列 ≤0.35，任何位置总时长不得超过 1.5s）
local HRandomWait = function(base, span)
    task.wait(HRand(base, span))
end

-- ============================================================================
-- 【模块 04：玩家数据节点动态探测与角色碰撞/物理缓存】
-- 作用：GetPlayerData() 自动在 ReplicatedStorage 下探测并缓存当前玩家的 Data 节点（含鱼竿/鱼饵/背包/金币等）；
--   维护角色肢体碰撞表 originalCanCollide 与 Humanoid 原始移速/状态备份表，供穿墙与飞行功能安全读写。
-- 后续修改指引：游戏更新改名了数据文件夹（非 Data/PlayerData/PlayersData）时，在 GetPlayerData 的列表中添加新名字。
-- ============================================================================
-- 动态探测并缓存玩家数据容器，兼容 Data / PlayerData / PlayersData 结构更新
-- 校验实例是否仍然存活且挂载于 game 数据模型下，防止访问已销毁或脱离树结构的残留节点
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
-- 动态探测并获取当前玩家在 ReplicatedStorage 或 LocalPlayer 下的数据节点（带 DataModel 归属校验）
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

-- 角色事件连接与 Humanoid 状态缓存
local characterConnections = {}
local originalHumanoidState = setmetatable({}, {__mode = "k"})
-- 备份角色 Humanoid 原始移速与 PlatformStand 状态，供卸载或状态恢复时还原
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

local Events = FSYC.ResolveEventsFolder(ReplicatedStorage, 10)
if not Events then
    -- 此处不再挂 ReplicatedStorage.ChildAdded 监听：统一由模块 27 底部 BindEventsFolderRemotes 唯一监听并恢复 Events
    FLogWarn("启动", "10 秒内未找到远程事件容器 (Events/Remotes)；已交由统一延迟加载监听，就绪后自动恢复")
end

-- ============================================================================
-- 【模块 05：全局功能默认配置表 (Config) 与中英映射字典】
-- 作用：集中定义所有功能的默认开关、延迟参数、保护鱼名单、快捷键等配置项；
--   提供任务难度 (QuestDiffMap) 与扭蛋卡池 (FSYC.GachaBannerMap) 的中英文参数映射。
-- 后续修改指引：修改任意功能的默认初始状态、默认保护鱼或默认快捷键，直接改下方 Config 对应字段即可。
-- ============================================================================
-- 统一全局版本号常量，消除顶栏、底栏、仪表盘与启动通知的版本号割裂
local FSY_VERSION = "V15.5"

local Config = {
    UIScale = 0.85,
    -- 内置 5 套低饱和护眼主题：薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红
    UITheme = "薄荷翠绿",
    -- 记录每个折叠分组的展开/收起（键：分类|分组名 -> boolean），关闭重开 UI / 重新注入后保留
    UIGroupState = {},
    -- 运行模式：自动 = 按硬件能力识别（触屏/键鼠/混合），手机 = 强制只认触屏，电脑 = 强制只认键鼠。
    -- 手动值优先于自动识别；持久化在配置文件里，重新注入后保持用户选择。
    DeviceMode = "自动",
    -- true = 只接受当前模式的输入族（手机忽略鼠标、电脑忽略触屏），
    -- 防止触屏与鼠标同时触发同一次点击（同一次点击被两路各派发一次 = 重复发包）。
    InputIsolation = true,
    -- 一次 UIS.InputBegan 后，多少毫秒内的点击事件都算「同一次物理按下」。
    -- 这是吞掉 Activated + MouseButton1Click + 触屏兜底 三通道重复的判定依据，不是节流参数。
    InputDedupeMs = 600,
    -- 同一 Remote + 同一参数在该窗口内只放行一次；0 = 关闭去重。
    -- 只去重不改节流：真实的新意图（时间/参数不同）照常发出。
    PacketDedupeMs = 40,
    -- true=输出运行日志到执行器控制台（同标签 2 秒内自动合并，不会刷屏）；false=默认静默只输出 ERROR（消除运行期 print/warn 刷屏）
    DebugLog = false,
    -- 只在"真的在钓鱼"时才允许自动发包 / 自动技能 / 自动猛击；
    -- 关闭后完全退回旧行为（旧行为在空闲时会被面板可见、咬钩缓存、猛击钮缓存带成持续发包）
    FishingGate = true,
    -- 默认关。给"既不给 Minigame 属性、也没有自己的鱼、也没有拔河条"的鱼种/布局留的后门：
    -- 打开后会把「Fishing 面板可见 +（猛击钮可见 或 鱼线在水里）」也算搏斗（等价于旧判定 + 迟滞）。
    -- 代价是重新出现一定量的空转发包，所以只在你确认"该放技能却不放"时才开。
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
    -- 节奏引擎参数：严格顺序 / 起手等待 / 单技能冷却 / 施法通道 / 保命技能
    SkillStrict = false,         -- 等价于 SkillOrderMode="严格轮流(等冷却)"（兼容旧存档）
    -- 三档释放模式（解决"选的是 Z,X,C,V，实际却像随机放"）：顺序优先·超时跳过（默认，仅当前位冷却 > SkillSkipWait 才跳）、
    --   顺位优先(谁好放谁)（沿顺序方向找第一个就绪位，旧版默认，冷却一乱看起来就是随机）、严格轮流(等冷却)（死等当前位）。
    -- 默认「优先(Z→X→C→V)」：按顺序表从头扫，谁靠前又就绪就放谁。抓包（pcap5）证明旧"轮转"模式会让 Z 变得最少
    -- （Z 7 次 / C 29 / V 27），因为轮转指针停在谁身上就优先放谁。
    SkillOrderMode = "优先(Z→X→C→V)",
    -- 首技立即释放：用户实测「进入钓鱼/战斗后游戏会重置技能冷却，第一个技能必定可用」。
    -- 开着时：本场第一次施法跳过「起手等待」，也不做施法前的界面冷却校验（此时按钮上的数字是上一场的残留）。
    SkillFirstInstant = true,
    SkillStartDelay = 2.5,       -- 咬钩进入小游戏后等待多久放第一个技能（秒）
    SkillCooldown = 30,          -- 兜底冷却：四项独立冷却缺省时使用（旧存档兼容字段）
    -- [按技能独立冷却] 3~999 秒；游戏里每个技能各自转 CD，点完要等十几~几十秒（个别 999s）。
    -- 真正生效的是「施法前读按钮倒计时」：只要能读到就按读到的真实剩余时间校正，配置值只是"读不到时的兜底"。
    -- 用户实测 Z 位技能（无影太极击）只有 3 秒冷却；旧默认 30 秒把它锁了 10 倍长（抓包里「Z 每 30.0 秒一次」的直接原因）。
    -- 默认值按实测给：Z=3（用户实测）｜X≈21.5s、C≈4.5s、V≈4.7s（pcap5 里各技能相邻两次释放的间隔，约等于真实 CD）
    SkillCdZ = 3, SkillCdX = 21, SkillCdC = 5, SkillCdV = 5,
    SkillCdProbe = true,         -- 自动读取技能按钮上的冷却倒计时数字（灰色按钮上显示剩余秒数），读到就用它校正计时
    _cdZFixed = false,           -- 一次性迁移标记（旧版"3→30"迁移把 Z 写成 30 的，只复位一次）
    SkillChannel = "自动",       -- 施法通道：自动 / 屏幕按钮 / 远程事件 / 模拟按键 / 兼容(三通道全开)
    SkillPanicKey = "关闭",      -- 低血保命技能位：关闭 / Z / X / C / V
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
    -- 无名章鱼节奏小游戏：每次上报的最小间隔（秒）。实测真人 8 次按键间隔 0.08~0.66s，平均 0.361s（2.77 次/秒）。
    -- pcap2 #1887 RhythmStart 实测规则：{HealHP=50, LoseHP=200, DealDMG=70, MiniGameTime=120, FinalMaxHP=20000}
    --   → 20000 ÷ 70 = 286 次命中才能击杀；286 × 0.34s ≈ 97 秒，落在真人的 103 秒附近、也在 120 秒限时内。
    -- 0.25s = 71.5 秒（已是理论极限）、0.18s = 51 秒、0.12s = 34 秒 —— 后两档都会被服务端判定为不可能
    -- （实测就出现了「33 秒内击败 Boss」的封禁提示）。运行期还会硬夹到 ≥ 0.30s（见 BOSS_RHYTHM_MIN_GAP）。
    RhythmBeatSec = 0.34,
    -- 节奏命中率：每一次节拍有百分之几的几率真的去按（其余节拍不发包）。命中 +50 血、漏按 -200 血，
    -- 四次命中才抵一次漏按 → **80% 是收益平衡点、低于 80% 净亏血**；默认 100（最稳）。
    RhythmAccuracy = 100,
    -- Enzo 第二阶段「读条判定」真实命中上报（默认关）。协议来自实机完整双向抓包，
    -- 见 pcap/完整协议解析报告.md；开启后由模块 31-B 接管 BossPhase2Action 的上报。
    RealBossHit = false,
    -- 命中上报最小间隔（秒）。服务端 MinGap=0.25，实测真人最快 0.51s。三档 0.18 / 0.15 / 0.10 **都低于 MinGap**，
    -- 是按用户要求保留的手动尝试档：低于 MinGap 的包服务端很可能直接丢弃（"发了但不回血"），不回血就往上调一档。
    -- 默认 0.75（≈1.3 次/秒，真人实测 0.84 次/秒）。Enzo 战实测（pcap/ 1158s 整场）：StartBossFight("Enzo","Nightmare")
    --   +8.6s → 最后一条命中 +299.7s，整场约 291 秒；第二阶段 272.7~299.7s 共 17 次命中，平均间隔 1.19 秒。
    -- [审计 R-23] 现行档位是 1.20/0.95/0.75/0.60/0.45/0.30s（旧的 0.18/0.15/0.10 已废弃，仅作历史记录）。
    -- 注意：该局是用户"故意漏按做测试"的战败局（命中 17 / 漏按 9 = 65%），是"真人能达到的命中节拍"样本，不是"成功击杀"样本。
    RealBossGap = 0.75,
    -- 激进模式：不等绿区，轮到节拍就报命中（回血速度只受节拍限制）
    RealBossForce = false,
    -- 激进模式的「拟人命中率」(50~100%)：按百分比主动漏报，让上报命中率落回人类区间。
    -- 100 = 一次不漏（统计上不可能是真人）；85 = 大约每 7 次漏 1 次；65 = 接近真人实测命中率。
    RealBossHitRate = 85,
    -- 强制显示钓鱼按钮：开 = 一直显示（仓库/装备等界面也照显示）；关 = 完全不管
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
    -- 默认值对齐自身边界下限 5，避免"保存即被静默改写为 5"
    BuyBaitDelay = 5,
    AutoGacha = false,
    GachaBanner = "太极卡池",
    GachaPullsPerAction = 1,

    ESP_GodSpirit = false,
    ESP_Boats = false,
    ESP_Maoshan = false,
    ESP_Taoist = false,
    ESP_DumbGuy = false,   -- 傻子隐藏商人独立分类
    ESP_Boss = false,
    ESP_Players = false,
    -- [方案A / 雷达总开关] 三态：
    --   全开 = 扫描 + 弹窗 + 挂 ESP（原行为）
    --   静默 = 照常扫描（保 NPC 远程对话 / 传送页状态），但一律不弹窗
    --   关   = 完全不扫描、不弹窗、不挂 ESP、不预加载岛屿、不跑自动跳服
    RadarMode = "全开",
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
FSYC.Config = Config
-- 保留旧版配置文件兼容字段（CastPower / SelectedSkill / AutoGodSpiritCheck / AutoExecuteOnJoin）

local QuestDiffMap = {
    ["简单"] = "Easy",
    ["困难"] = "Hard",
    ["Easy"] = "Easy",
    ["Hard"] = "Hard",
    ["Dễ"] = "Easy",
    ["Thường"] = "Easy",
    ["Khó"] = "Hard",
    -- 补齐缺失的英文/越文/中文难度别名；既有 "Thường"="Easy" 保持不变
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
    -- 补齐越文卡池短名，取值与既有 太极卡池 / 无我卡池 一致
    ["Thái Cực"] = "Taiji Banner",
    ["Vô Ngã"] = "Selflessness Banner",
}

-- ============================================================================
-- 【模块 06：执行器能力探测 (Capabilities) 与 __namecall 远程事件拦截 Hook】
-- 作用：探测执行器是否具备 Hook 所需 API（hookmetamethod / newcclosure / getnamecallmethod / checkcaller）；
--   支持 Hook 时拦截 FireServer 实现：小游戏 "Out of bar" 自动改判 "In bar"、猛击/节奏自动 "Perfect"、
--   蓄力自动 100，以及发包级防误卖拦截（命中保护鱼或包内有保护鱼时禁止 SellAll）。
-- 后续修改指引：若游戏新增了小游戏或卖鱼远程事件名称，可在 __namecall 分支的 rName 判断中补充。
-- ============================================================================
-- 执行器能力集中探测表（Capabilities）与可选 Hook 生命周期管理
local Capabilities = {
    Hook = (type(hookmetamethod) == "function" and type(newcclosure) == "function" and type(getnamecallmethod) == "function" and type(checkcaller) == "function"),
}

if sharedEnv then
    sharedEnv.IdenticalFishingConfig = Config
    sharedEnv.IdenticalFishingRunning = true

    -- 本会话装过钩子就不再装：同一会话里重复对 game 调用 hookmetamethod，部分执行器（含 Delta）会在 C 层直接崩溃；
    -- 上一版闭包在重新注入后可能已失效，把它当 orig 调用同样会崩。
    -- 代价是「升级脚本后钩子逻辑需重启游戏才生效」，下面会打一条明确提示，不再静默失效。
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
        -- 兼容 Luau / Lua 5.1+ 的 unpack，配合 table.pack 保留稀疏 nil 参数长度
        local unpackArgs = table.unpack or unpack
        local hookOk, hookErr = pcall(function()
            -- 拿不到原始 __namecall 时不要安装钩子：旧实现把判空放在钩子体内，一旦执行器不返回旧函数，
            -- 全站 namecall 会静默返回 nil（商店/抛竿/背包全部失效且不报错）；这里提前放弃，原生 namecall 保持可用。
            if type(preSavedNamecall) ~= "function" and not (sharedEnv and sharedEnv.IdenticalOldNamecall) then
                -- [审计-4] 这条路径原来完全不打日志：卖鱼保护与完美条改写会静默失效，用户以为保护开着
                FLogWarn("Hook", "未能取得原始 __namecall，已跳过 Hook（卖鱼保护/完美条改写不生效）；如需该功能请换支持 hookmetamethod 的执行器")
                -- FLogWarn 默认被 DebugLog=false 静默：这条属"安全功能未生效"，改用一次性 print 保证可见（每次注入仅一行）
                pcall(print, "[FSY][WARN][Hook] 未能取得原始 __namecall，已跳过 Hook：卖鱼保护与完美条改写不生效")
                return
            end
            local oldNamecall = preSavedNamecall
            local retNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                local orig = oldNamecall or (sharedEnv and sharedEnv.IdenticalOldNamecall)
                if type(orig) ~= "function" then return nil end
                if not sharedEnv or not sharedEnv.IdenticalFishingRunning then
                    return orig(self, ...)
                end
                if typeof(self) == "Instance" then
                    -- [Delta 减负 M2] __namecall 快路径重排：先保留纳秒级 Instance 类型判断，再取方法名；
                    -- 非 FireServer 调用（占全游戏 99%+ 的 FindFirstChild/GetAttribute 等）立即跳过 pcall(checkcaller)，减少 1 次跨 C 边界调用。
                    local okMethod, method = pcall(getnamecallmethod)
                    local okCaller, isOurCall = false, true
                    if okMethod and method == "FireServer" then
                        okCaller, isOurCall = pcall(checkcaller)
                    end
                    if okMethod and method == "FireServer" and okCaller and not isOurCall then
                    local cfg = sharedEnv.IdenticalFishingConfig
                    if cfg then
                        local assistActive = cfg.AnchorBar or cfg.OctoAutoMinigame
                        local okName, rName = pcall(getInstanceName, self)
                        if okName and type(rName) == "string" then
                            -- 战斗态新鲜度：stepHeartbeat 在无角色/重生/切图时早退，标志会卡在最后一次的 true；
                            -- 这里要求「true 且时间戳在 0.5s 内」才算在战斗，超时一律按非战斗处理（fail-closed）。Slam/Rhythm/Charge 共用。
                            local combatFresh = sharedEnv
                                and sharedEnv.IdenticalCombatActive == true
                                and type(sharedEnv.IdenticalCombatActiveAt) == "number"
                                and (tick() - sharedEnv.IdenticalCombatActiveAt) <= (FSYC.Tunables and FSYC.Tunables.CombatFreshTtlSec or 0.5)
                            -- 记录「游戏自己」发进度包的时刻（checkcaller=false 才走到这里）：实测 pcap5 UpdateFishProgression 6062 条 / 583 秒 = 10.4 条/秒，
                            -- 中位间隔 0.067s、67.9% 小于 0.10s（脚本 0.125s 一包 + 游戏自己一包叠加）；脚本发之前先看 90ms 内游戏有没有自己发过。
                            if rName == "UpdateFishProgression" then
                                if sharedEnv then sharedEnv.IdenticalLastProgressionAt = tick() end
                            elseif rName == (FSYC.Protocol and FSYC.Protocol.Remotes.FishingMinigame or "FishingMinigame") and assistActive then
                                local args = table.pack(...)
                                local inBarStr = FSYC.Protocol and FSYC.Protocol.MinigameInBar or "In bar"
                                local actIdx = (type(args[1]) == "string") and 1 or ((type(args[3]) == "string") and 3 or nil)
                                if actIdx then
                                    local action = args[actIdx]
                                    if action == "Out of bar" or action == "Out of bar (overpull)" or action:find("Out of bar", 1, true) or action:find("Fail", 1, true) or action:find("Miss", 1, true) then
                                        args[actIdx] = inBarStr
                                        return orig(self, unpackArgs(args, 1, args.n))
                                    end
                                end
                            -- 战斗域改写必须同时满足「本帧确实在搏斗」（sharedEnv.IdenticalCombatActive），否则空闲挂机时游戏自身发出的 Slam 包也会被改写成 "Perfect"。
                            elseif (rName == (FSYC.Protocol and FSYC.Protocol.Remotes.Slam or "Slam") or rName:find("Slam", 1, true)) and cfg.AutoSlam
                                and combatFresh then
                                local firstArg = select(1, ...)
                                local firstStr = firstArg ~= nil and tostring(firstArg):lower() or ""
                                if firstArg == nil or firstArg == false or firstStr:find("miss", 1, true) or firstStr:find("fail", 1, true) or firstStr:find("bad", 1, true) then
                                    return orig(self, FSYC.Protocol and FSYC.Protocol.SlamActionPerfect or "Perfect")
                                end
                            -- RhythmHit 抓包协议严格只接受单参字符串 "hit" / "miss"：绝不能走下方通用 QTE 分支改写成 ("Perfect", 100) 双参非法载荷！
                            -- 也不要把游戏自己发出的 RhythmHit("miss") 改写成 "hit"：客户端已判定这次按空、网线上却写 "hit"，服务端拿判定条位置对一次就能确认客户端撒谎
                            -- （真人抓包 pcap2 #1897~#1910：8 次按键里 5 次 miss —— "零失误"本身就是异常指纹）。脚本自己的自动命中走 RhythmHit 直发，不经过这里。
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

                            -- Charge 同属战斗域报文：只堵 Slam/Rhythm 不堵 Charge 等于留下同一个口子。
                            elseif rName == "Charge" and cfg.AutoCharge and combatFresh then
                                local args = table.pack(...)
                                if args[1] == nil or (type(args[1]) == "number" and args[1] < 100) then
                                    -- [审计-11] 保留原调用尾参：协议若为多参，原写法会把第 2 个及以后参数丢掉
                                    return orig(self, 100, unpackArgs(args, 2, args.n))
                                end
                            -- 防误卖拦截 fail-closed：检查函数报错（okCheck=false）也要拦，否则保护鱼会被卖出；「函数尚未安装（==nil）」改为放行（见分支内说明）。
                            -- 进入条件**不带 Config.AutoSell 前置**：卖鱼拦截与「是否开启自动卖鱼」无关，关掉 AutoSell 后玩家手动/游戏内卖鱼同样要受包级保护。
                            elseif (rName == "SellFish" or rName == "SellItem" or rName == "SellAll") and sharedEnv then
                                -- 发包级卖鱼拦截：遍历全部参数（或 SellAll 无参），命中保护鱼/已锁鱼时直接拦截丢弃。
                                -- 必须用 table.pack 的 args.n 取精确参数个数：`{...}` + `#args` 在参数含稀疏 nil 时会被截断
                                --   （SellFish(nil, 保护鱼) 的 #args 可能是 0 → 走 "All" 分支并跳过逐参拦截 → 保护鱼被卖出）。
                                -- 「函数不存在（==nil）」放行（否则加载期游戏自身的卖鱼包会被一起吞掉）；「存在但 pcall 报错」继续 fail-closed 拦截。
                                if sharedEnv.IdenticalIsSellArgBlocked == nil then
                                    return orig(self, ...)
                                end
                                local args = table.pack(...)
                                if type(sharedEnv.IdenticalIsSellArgBlocked) ~= "function" then
                                    -- 字段存在但不是函数（被写坏）→ 仍按已拦截处理，不做无条件放行
                                    return nil
                                end
                                if rName == "SellAll" or args.n == 0 then
                                    local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, "All")
                                    -- okCheck 为 false（检查函数报错）也必须拦下，不得放行
                                    if (not okCheck) or isBlocked then return nil end
                                else
                                    for aIdx = 1, args.n do
                                        local okCheck, isBlocked = pcall(sharedEnv.IdenticalIsSellArgBlocked, args[aIdx])
                                        -- 同上：报错即视为命中，直接拦截
                                        if (not okCheck) or isBlocked then return nil end
                                    end
                                end
                            elseif (rName == "FavoriteItem" or rName == "FavouriteItem" or rName == "FavoriteFish" or rName == "FavouriteFish"
                                or rName == "LockFish" or rName == "LockItem" or rName == "Lock" or rName == "Favorite" or rName == "Favourite") then
                                -- 放行脚本内部发起的收藏上锁调用（IdenticalInternalFavCall == true），仅拦截外部误解锁请求
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
                end
                return orig(self, ...)
            end))
            -- 必须无条件采用 hookmetamethod 返回的 retNamecall：Delta 的 hookmetamethod 是「原地改写」，
            -- 它返回一个指向真正原生 namecall 的跳板闭包，hook 之后 rawget 到的 preSavedNamecall 已指向钩子自己。
            -- 若改成「oldNamecall 已是函数就不采用 retNamecall」，orig 会指回钩子 → 任意 : 方法调用无限递归 → C 栈爆栈 → App 秒退。
            if type(retNamecall) == "function" then
                oldNamecall = retNamecall
            end
            if type(oldNamecall) == "function" then
                sharedEnv.IdenticalOldNamecall = oldNamecall
                sharedEnv.IdenticalHookInstalled = true
            else
                sharedEnv.IdenticalOldNamecall = nil
                sharedEnv.IdenticalHookInstalled = false
                -- 既未预取到原始 __namecall、hook 也未返回函数时给出 ERROR 级日志（不改变安装行为）
                FLogErr("Hook", "未能取得原始 __namecall，namecall 直通可能失效")
            end
        end)

        if not hookOk then
            FLogWarn("Hook", "Hook 安装失败，已跳过可选 Hook：" .. tostring(hookErr))
        end
    elseif not Capabilities.Hook then
        FLogWarn("Hook", "当前执行器缺少完整 Hook API，已跳过 Hook；主界面仍会继续加载。")
    else
        -- 本会话已装过钩子（通常是重复执行了脚本）：这次不重装，避免执行器崩溃。
        FLogWarn("Hook", "本会话已安装过旧版钩子，为避免执行器闪退本次不重装；如需让新的钩子逻辑生效，请重启游戏后再注入。")
        pcall(print, "[FSY][WARN][Hook] 本会话已装过旧钩子，本次不重装：新钩子逻辑需重启游戏后生效")
    end
else
    -- [审计-4] 无 getgenv 时整段 Hook 被跳过：补一条日志，避免"卖鱼保护开着但其实没生效"
    FLogWarn("Hook", "当前执行器没有 getgenv，跨实例保护与可选 Hook 均已跳过（主界面仍会加载）")
    pcall(print, "[FSY][WARN][Hook] 当前执行器没有 getgenv：跨实例保护与可选 Hook 均已跳过")
end

-- ============================================================================
-- 【模块 07：本地配置文件 (Profile) 与自定义传送点 JSON 持久化】
-- 作用：将 Config 配置与自定义传送点保存至本地工作区 Identical/HeavyweightFishing 目录；
--   加载旧配置时通过 ConfigNumericBounds 执行数值范围钳制，防止异常数值导致逻辑出错。
-- 后续修改指引：新增滑块配置项时，建议在 ConfigNumericBounds 中同步添加 {最小值, 最大值} 校验范围。
-- ============================================================================
local SaveProfile, SyncUIWithConfig, LoadProfile, LoadCustomTPs, SaveCustomTPs
-- 跨模块函数前向声明为顶层 local：原先定义在 do...end 块内会让外部调用落入全局 nil（高危）
local RestoreNativeGameHud, RealBossDeactivate, SweepOrphanSlots, FishGate
local CustomTPs = {}
local blackOutFrame, mainFrameScale, ApplyLightingSettings
local DashUI = {}

-- ============================================================================
-- 【V15.46 / 通用小工具】有界等待 + 运行状态总线 + 数值钳制
-- 说明：只做只读/轻量状态记录与等待封装，不改变任何发包、钓鱼、重连、UI 逻辑。
--   · WaitUntil：所有"等别人"都有 deadline，杜绝永久挂起；
--   · SetStatus/GetStatusText：各子系统最近状态汇总，供"查看运行状态"与排障；
--   · ClampNum：运行时读取配置的统一钳制，防止脏存档把节拍写成极端值。
-- ============================================================================
DashUI._status = {}
DashUI._statusLimit = 12

-- [UI-STATUS] 统一运行级别：全脚本唯一的状态判定出口，底栏状态条与悬浮球状态灯共用同一份判断，
-- 避免两处各算一套导致「球是绿的、底栏说有失败」这种自相矛盾。
--   err  有失败/异常    → 红
--   warn 有延后/暂停    → 黄（决定用户要不要动手，优先级高于"在跑"）
--   ok   正在钓鱼/搏斗  → 绿
--   idle 空闲           → 灰
function DashUI.GetRunLevel()
    local hasFail, hasBlock = false, false
    for _, rec in pairs(DashUI._status) do
        local t = tostring(rec and rec.text or "")
        if t:find("失败", 1, true) or t:find("异常", 1, true) then hasFail = true; break end
        if t:find("延后", 1, true) or t:find("暂停", 1, true) then hasBlock = true end
    end
    if hasFail then return "err" end
    if hasBlock then return "warn" end
    if FishGate and type(FishGate.GetStateName) == "function" then
        local ok, sn = pcall(FishGate.GetStateName)
        if ok and type(sn) == "string" and (sn:find("搏斗", 1, true) or sn:find("钓鱼", 1, true)) then
            return "ok"
        end
    end
    return "idle"
end

function DashUI.SetStatus(key, text)
    key = tostring(key or "sys")
    text = tostring(text or "")
    -- [V15.46] 单键文本上限 80 字符：异常信息（如 tostring(err)）可能数百字符，会把状态行撑爆
    if #text > 80 then text = string.sub(text, 1, 80) .. "…" end
    local rec = DashUI._status[key]
    if rec then
        if rec.text ~= text then rec.text = text end
        rec.at = tick()
        return
    end
    DashUI._status[key] = { text = text, at = tick() }
    local n = 0
    for _ in pairs(DashUI._status) do n = n + 1 end
    if n > DashUI._statusLimit then
        local oldestKey, oldestAt
        for k, v in pairs(DashUI._status) do
            local vt = tostring(v and v.text or "")
            local isAlert = vt:find("失败", 1, true) or vt:find("异常", 1, true) or vt:find("延后", 1, true) or vt:find("暂停", 1, true)
            if not isAlert and (not oldestAt or v.at < oldestAt) then oldestKey, oldestAt = k, v.at end
        end
        if not oldestKey then
            for k, v in pairs(DashUI._status) do
                if not oldestAt or v.at < oldestAt then oldestKey, oldestAt = k, v.at end
            end
        end
        if oldestKey then DashUI._status[oldestKey] = nil end
    end
end

function DashUI.GetStatusText()
    local out = {}
    for k, v in pairs(DashUI._status) do
        out[#out + 1] = string.format("%s=%s", tostring(k), tostring(v.text))
    end
    table.sort(out)
    return table.concat(out, " | ")
end

-- 有界等待：fn 返回真即成功；超时返回 false + 实际等待秒数
-- 默认 2.5s 与 FSYQD 原默认一致；predicate 异常按 5s 节流记一条 WARN，避免静默吞错
function DashUI.WaitUntil(fn, timeout, interval)
    local t0 = tick()
    local deadline = t0 + (tonumber(timeout) or 2.5)
    interval = tonumber(interval) or 0.1
    if interval < 0.03 then interval = 0.03 end
    while isRunning and tick() < deadline do
        local ok, v = pcall(fn)
        if ok and v then return true, tick() - t0 end
        if not ok and tick() >= (DashUI._waitErrLogAt or 0) then
            DashUI._waitErrLogAt = tick() + 5
            FLogWarn("等待", "WaitUntil 条件函数异常: " .. tostring(v))
        end
        task.wait(interval)
    end
    return false, tick() - t0
end

-- 运行时数值钳制：非数字/NaN 回默认值，越界钳到边界
function DashUI.ClampNum(v, lo, hi, def)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return def end
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

do
local PROFILE_DIR = "Identical/HeavyweightFishing"

-- 确保本地配置目录 Identical/HeavyweightFishing 存在
local function EnsureProfileDir()
    -- [审计-17] 原探测只看 makefolder，函数体里却直接调用 isfolder：缺 isfolder 的执行器会让整个 pcall 抛错、
    -- 目录建不出来 → 配置永远存不下（且只有用户点保存时才看到失败）。这里补 isfolder 探测并给出无 isfolder 的退路。
    if type(makefolder) ~= "function" then return end
    pcall(function()
        if type(isfolder) == "function" then
            if not isfolder("Identical") then makefolder("Identical") end
            if not isfolder(PROFILE_DIR) then makefolder(PROFILE_DIR) end
        else
            pcall(makefolder, "Identical")
            pcall(makefolder, PROFILE_DIR)
        end
    end)
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

-- 原生 HUD 的唯一还原入口：谁藏的谁还原，且只还原「我们自己登记过的备份值」，写完即销账。
-- 注意：本函数必须在 Config 定义之后（上面），否则函数体里的 Config 会被解析成全局 nil（"种子 S1/S2"坑）。
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
    -- 自动技能 v2：起手等待 0.5~10s；四项独立冷却 1~999s（部分技能 CD 只有 1~2 秒，下界更高会被钳坏计时器）。
    SkillStartDelay = {0.5, 10}, SkillCooldown = {1, 999},
    SkillCdZ = {1, 999}, SkillCdX = {1, 999}, SkillCdC = {1, 999}, SkillCdV = {1, 999},
    CraftAmount = {1, 10}, BuyBaitThreshold = {5, 50},
    BuyBaitDelay = {5, 3600}, GachaPullsPerAction = {1, 10},
    MonkeyGiveCount = {10, 500},
    RhythmAccuracy = {85, 100},   -- 下限 85：80% 是收益平衡点（+50 / -200），低于 80% 净亏血
    -- 按下归并窗口 200~1000ms；发包去重窗口 0~200ms（0=关闭）。
    -- 没有这两行时，脏 default.json 可以把 PacketDedupeMs 写成 600000，等于「一竿之后静默 10 分钟」。
    InputDedupeMs = {200, 1000}, PacketDedupeMs = {0, 200},
    -- 两个新数值项原先不在边界表里，手改脏 JSON 不会被钳制；下界同步到安全档 0.30：
    -- 0.30s = 3.33 次/秒，已远超判定条能给的节奏（约 0.8~1.8 次/秒），属于"明知风险仍要用"的档位。
    RealBossHitRate = {50, 100}, RealBossGap = {0.30, 2.0},
    RhythmBeatSec = {0.30, 1.0},
}

local ValidConfigEnums = {
    UITheme = {["薄荷翠绿"] = true, ["冰川天蓝"] = true, ["极光青碧"] = true, ["流光琥珀"] = true, ["珊瑚绯红"] = true},
    -- 运行模式白名单：配置文件被改坏时回落「自动」，不会卡在未知模式上
    DeviceMode = {["自动"] = true, ["手机"] = true, ["电脑"] = true},
    TicketDifficulty = QuestDiffMap,
    -- 雷达总开关只允许这三档；配置文件被改坏时回落「全开」，不会卡在未知档位
    RadarMode = {["全开"] = true, ["静默"] = true, ["关"] = true},
    GachaBanner = FSYC.GachaBannerMap,
    -- [自动技能 v2] 施法通道与保命技能只允许这几个取值，旧配置里的非法字符串会被自动回退默认值
    SkillChannel = {["自动"] = true, ["屏幕按钮"] = true, ["远程事件"] = true, ["模拟按键"] = true, ["兼容(三通道全开)"] = true},
    SkillPanicKey = {["关闭"] = true, ["Z"] = true, ["X"] = true, ["C"] = true, ["V"] = true},
    -- 技能释放顺序只允许这三种；旧存档里已删除的「顺序优先·超时跳过」会读档回落成第一种（优先）
    SkillOrderMode = {["优先(Z→X→C→V)"] = true, ["顺位优先(谁好放谁)"] = true, ["盲轮转(按顺序点)"] = true, ["严格轮流(等冷却)"] = true},
    FavPacketMode = {
        ["鱼名+后缀(Name | Favorite)"] = true, ["仅完整鱼名(item.Name)"] = true,
        ["仅实例对象(item)"] = true, ["智能探测(自动对比状态)"] = true, ["动作+鱼名(Favorite+Name)"] = true,
    },
}

-- 校验并钳制单个配置项的类型、字符串长度、枚举合法性与数值上下界
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
            -- 按字节截断改用 UTF-8 安全切分，避免切出半个多字节字符导致配置 JSON 保存失败
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

-- 挂载跨模块共享的安全属性读取与带超时异步 InvokeServer 工具（零顶层 local 寄存器占用）
DashUI._readValueBase = function(inst, defaultVal)
    if typeof(inst) ~= "Instance" or not inst.Parent then return defaultVal end
    if inst:IsA("ValueBase") then return inst.Value end
    local sub = inst:FindFirstChild("Value") or inst:FindFirstChild("Quantity") or inst:FindFirstChild("Amount")
    if sub and sub:IsA("ValueBase") then return sub.Value end
    return defaultVal
end

-- 兼容 ValueBase、Folder(Quantity/Count/Amount/Value 子节点) 与 Attribute 的鱼饵库存安全读取器
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

-- 兼容 ValueBase(BoolValue/NumberValue)、标记型 Folder 与 Attribute 的鱼竿拥有状态判定器
DashUI._isRodOwned = function(rFolder)
    if not rFolder or not rFolder.Parent then return false end
    local ownedObj = rFolder:FindFirstChild("Owned")
    if ownedObj then
        return (not ownedObj:IsA("ValueBase")) or (ownedObj.Value == true) or (ownedObj.Value == 1)
    end
    return rFolder:GetAttribute("Owned") == true
end

-- 统一释放所有在途按下的虚拟按键 (Z/X/C/V)，供退出小游戏瞬间与卸载脚本时双重调用
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

-- 虚拟鼠标/触摸「按下」登记表：VIM 的 down/up 是跨帧拆分的，若卸载时取消了 up 回调，
-- 虚拟左键会永久停在按下态（原生输入不恢复）。按下即登记、抬起后注销，卸载前统一补发抬起。
local pressedVirtualMouse = {}
-- 同步登记虚拟鼠标按下与虚拟触控按下 (withTouch)，防止卸载时取消延迟回调后触控点 0 卡在按下态
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
-- [审计 R-14] 这三张表是 do 块内的局部量，UnloadScript 在块外看不到；挂一个重置入口供卸载调用
-- （若在 UnloadScript 里直接引用 invokeInFlight，会解析成 nil 全局，`if x then` 恒假 = 空操作）。
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
            local maxSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffMaxSec or 1.20
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
    -- 「节奏节拍」与「命中节拍」反查前先用 ClampNum 归一，保证「UI 显示值 = 实际生效值 = 存档值」
    Config.RhythmBeatSec = DashUI.ClampNum(Config.RhythmBeatSec, 0.30, 1.0, 0.34)
    Config.RealBossGap = DashUI.ClampNum(Config.RealBossGap, 0.30, 2.0, 0.75)
    if DashUI then DashUI._batchSyncing = true end
    for key, ctrl in pairs(UIControls) do
        if Config[key] ~= nil and ctrl and ctrl.Set and key ~= "RealBossGap" and key ~= "RhythmBeatSec" then
            -- 传入 silent=true 仅同步UI视觉状态，避免启动时触发 false 分支副作用弄乱游戏界面
            pcall(ctrl.Set, Config[key], true)
        end
    end
    if DashUI then DashUI._batchSyncing = false end
    -- 「命中节拍」数值 → 档位文本按区间反查（不依赖浮点精确相等）；档位必须覆盖全部可取值，否则读档后显示会误判节拍。
    if UIControls.RealBossGap and UIControls.RealBossGap.Set and Config.RealBossGap ~= nil then
        local gapVal = Config.RealBossGap
        -- 旧存档的 0.18/0.10 会被归到 0.30s 档（运行期实际硬夹到 ≥0.30，见 RealBossStep 的 hardFloor）
        local gapLabel
        if gapVal >= 1.05 then gapLabel = "1.20s 真人速"
        elseif gapVal >= 0.85 then gapLabel = "0.95s 稳健"
        elseif gapVal >= 0.675 then gapLabel = "0.75s 偏快(推荐)"
        elseif gapVal >= 0.525 then gapLabel = "0.60s 很快(有风险)"
        elseif gapVal >= 0.375 then gapLabel = "0.45s 极快(概率封号)"
        else gapLabel = "0.30s 疯狂(高概率封号)" end
        pcall(UIControls.RealBossGap.Set, gapLabel, true)
    end
    if UIControls.RhythmBeatSec and UIControls.RhythmBeatSec.Set and Config.RhythmBeatSec ~= nil then
        local beatVal = Config.RhythmBeatSec
        -- 回填映射需覆盖全部档位；旧存档里的 0.18/0.12 会被归到 0.30s 档（并有运行期硬夹兜底）
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
    if SetGameUIHidden then pcall(SetGameUIHidden, Config.HideGameUI == true) end
    if blackOutFrame then
        local dis3d = (Config.Disable3DRendering == true)
        blackOutFrame.Visible = dis3d
        pcall(function() RunService:Set3dRenderingEnabled(not dis3d) end)
    end
    -- 加载配置后同步界面主题色（轻量注册表更新，无全树扫描、无元表代理）
    if DashUI and type(DashUI._applyTheme) == "function" then
        pcall(DashUI._applyTheme, Config.UITheme, true)
    end
    if DashUI and type(DashUI.ApplyUIDeps) == "function" then
        pcall(DashUI.ApplyUIDeps)
    end
    if DashUI and type(DashUI.RefreshHomeScenes) == "function" then
        pcall(DashUI.RefreshHomeScenes)
    end
end

-- 从本地 JSON 文件读取配置并执行类型与数值范围校验后同步至 UI
LoadProfile = function(name)
    local path = GetProfilePath(name)
    if readfile then
        local ok, content = pcall(function() return readfile(path) end)
        if ok and content and #content > 0 then
            local decOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
            if not decOk or type(decoded) ~= "table" then
                -- [审计-18] 存档损坏/截断时原来静默回退默认值：用户"设置凭空消失"且查不到任何线索
                pcall(function()
                    if FLogWarn then
                        FLogWarn("配置", "配置文件解析失败，已忽略该文件并使用内存中的当前配置（原文件未改动）")
                    end
                    -- 注意：本函数在模块 07 定义、可能早于模块 10 的 ShowNotification 赋值，
                    -- 这里只留日志（FLogWarn 为已声明的局部），不引用尚未赋值的 UI 通知函数。
                end)
            end
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
                -- 不再做「技能间隔 0.8/2.0 → 1.5」与「冷却=3 → 30」这类静默覆盖：用户实测 Z 位技能（无影太极击）真实 CD 就是 3 秒。
                -- 只保留一次性迁移：旧版"3→30"把 Z 写成 30 的复位回 3（_cdZFixed 置位后不再动，X/C/V 保持用户设置）。
                if not Config._cdZFixed then
                    Config._cdZFixed = true
                    if Config.SkillCdZ == 30 then
                        Config.SkillCdZ = 3
                        FLog("技能", "检测到 Z 技能冷却被旧版迁移写成 30 秒，已按实测复位为 3 秒（仅本次）")
                    end
                end
                -- 商店/扭蛋页面已移除，强制将无 UI 控件绑定的遗留自动发包开关复位为 false，杜绝旧存档反序列化后后台幽灵发包
                Config.AutoCraftBait = false
                Config.AutoBuyBait = false
                Config.AutoGacha = false
                -- 防止旧版 default.json 残留自动跳服开关导致运行 90 秒后无故自动重连换服（需跳服时由用户在当前会话手动开启）
                Config.AutoServerHopGod = false
                Config.AutoServerHopMaoshan = false
                Config.AutoServerHopTaoist = false
                -- [V15.44 / REJOIN-FIX] 与上面三个跳服开关同等待遇。
                -- 原因：SanitizeConfigValue 对 boolean 只做 type 比较，旧存档里的 "AutoRejoin": true 会被原样读回；
                -- 而「被踢自动重连」是脚本里唯一能主动执行 TeleportService:Teleport(game.PlaceId, LocalPlayer) 的地方
                -- （= 整个 place 重进一遍，玩家看到的就是「自动重进当前服务器」）。任何一次 ErrorPrompt（含游戏自身的
                -- 传送失败、实例不可用）都会在 3 秒后触发它。因此每次读档一律强制关闭，需要时由用户在当前会话手动打开。
                Config.AutoRejoin = false
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
-- 【模块 08：护眼淡绿深色主题令牌、设备自适应尺寸度量、ScreenGui 挂载与省电遮罩】
-- 作用：5 套低饱和主题（薄荷翠绿 / 冰川天蓝 / 极光青碧 / 流光琥珀 / 珊瑚绯红）沿用原配置键，旧存档主题名可无损读取；
--   主题切换只做 O(N) 颜色赋值（0 全树扫描、0 元表劫持）；DashUI.metrics 在加载期按输入设备一次性算好尺寸，运行期只读。
-- 悬浮/长按说明浮层（UITooltip）同样在加载期一次性预建，运行期只改文本、位置与 Visible。
-- ============================================================================
local THEME_ACCENTS = {
    ["薄荷翠绿"] = {
        -- Accent/BorderAccent 用 (53,210,153) 而非 (52,211,153)：与状态绿 AccentGreen 同值会让
        -- ApplyThemeRecolor 的「旧色→新色」精确匹配把状态绿一起换掉（切主题色漂）。
        BorderAccent     = Color3.fromRGB(53, 210, 153),  -- #35D299 鲜绿描边
        AccentSoft       = Color3.fromRGB(110, 231, 183), -- #6EE7B7 亮薄荷（标题/图标）
        Accent           = Color3.fromRGB(53, 210, 153),  -- #35D299 主点缀色
        AccentDeep       = Color3.fromRGB(16, 98, 72),    -- #106248 选中态深底
        AccentGlow       = Color3.fromRGB(167, 243, 208), -- #A7F3D0 浅高光
        DropdownSelected = Color3.fromRGB(20, 83, 61),    -- #14533D 下拉选中底
    },
    ["冰川天蓝"] = {
        BorderAccent     = Color3.fromRGB(126, 158, 178),
        AccentSoft       = Color3.fromRGB(176, 205, 220),
        -- Accent 偏移 1：(143,179,201) 与状态色 Colors.AccentBlue 完全相同，换色器按值匹配会把「蓝色指标」一起改掉（色漂），肉眼无差。
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
-- 按主题点缀色**色相**重算深色底（主窗/侧栏/卡片/行/控件/分割线）：保持原有明度与低饱和（S×0.9、V 不变）只旋转色相；
-- 默认「薄荷翠绿」的色相与本底一致，因此观感不变。
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
        -- 必须与上方 Colors 的 9 个基础色同步：这里会按主题色相重算后写回 THEME_ACCENTS 再覆盖 Colors，只改 Colors 字面量会被盖回旧绿。
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
                -- 默认主题保留 13.1 的蓝灰底，不按薄荷色相旋转；否则底色又会被染回绿色。
                palette[key] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
            else
                local _, s, v = FSYC.RGBToHSV(rgb[1], rgb[2], rgb[3])
                local nh, ns = hueAccent, s * 0.9
                local r2, g2, b2 = FSYC.HSVToRGB(nh, ns, v)
                palette[key] = Color3.fromRGB(r2, g2, b2)
            end
        end
    end
end

FSYC.THEME_OPTIONS = {"薄荷翠绿", "冰川天蓝", "极光青碧", "流光琥珀", "珊瑚绯红"}

-- 护眼淡绿深色基础色板：所有色值按「低饱和、低对比刺激」原则重新校准
local Colors = {
    -- 高对比深灰蓝底 + 鲜艳薄荷绿：底色更深、文字更白、点缀色饱和度更高。
    -- 对比度（WCAG，相对 Background #171A21）：主文字 15.2:1 / 次文字 13.9:1 / 描述 9.1:1 / 主题绿 9.0:1。
    Background       = Color3.fromRGB(23, 26, 33),    -- #171A21 主窗口底（深灰蓝）
    SidebarBg        = Color3.fromRGB(19, 22, 28),    -- #13161C 侧栏 / 顶栏底
    Card             = Color3.fromRGB(24, 28, 36),    -- #181C24 分组卡片底
    RowNormal        = Color3.fromRGB(30, 34, 43),    -- #1E222B 功能行底
    RowHover         = Color3.fromRGB(38, 43, 54),    -- #262B36 悬停底
    ControlBg        = Color3.fromRGB(48, 55, 70),    -- #303746 按钮 / 滑块槽
    InputBg          = Color3.fromRGB(16, 19, 24),    -- #101318 输入框底
    Divider          = Color3.fromRGB(38, 44, 56),    -- #262C38 分割线
    BorderSubtle     = Color3.fromRGB(46, 53, 66),    -- #2E3542 卡片细描边
    BorderAccent     = Color3.fromRGB(53, 210, 153),  -- #35D299 主题描边（随主题；比状态绿偏 1，避免换色误伤）
    Accent           = Color3.fromRGB(53, 210, 153),  -- #35D299 主题主色（随主题）
    AccentSoft       = Color3.fromRGB(110, 231, 183), -- #6EE7B7 主题亮色（随主题）
    AccentDeep       = Color3.fromRGB(16, 98, 72),    -- #106248 主题深底（随主题）
    AccentGlow       = Color3.fromRGB(167, 243, 208), -- #A7F3D0 主题高光（随主题）
    TextWhite        = Color3.fromRGB(234, 241, 235), -- #EAF1EB 主文字（护眼米白，保留旧断言口径）
    TextSubtle       = Color3.fromRGB(224, 230, 240), -- #E0E6F0 次级文字
    TextMuted        = Color3.fromRGB(178, 188, 204), -- #B2BCCC 描述文字
    AccentGreen      = Color3.fromRGB(52, 211, 153),  -- #34D399 成功 / 运行
    AccentRed        = Color3.fromRGB(248, 113, 113), -- #F87171 警告 / 关闭
    AccentOrange     = Color3.fromRGB(251, 146, 60),  -- #FB923C 橙色指标
    AccentYellow     = Color3.fromRGB(250, 204, 21),  -- #FACC15 黄色指标
    AccentBlue       = Color3.fromRGB(56, 189, 248),  -- #38BDF8 蓝色指标
    DropdownSelected = Color3.fromRGB(20, 83, 61),    -- #14533D 下拉选中底（随主题）
}

local currentThemeName = (THEME_ACCENTS[Config.UITheme] and Config.UITheme) or "薄荷翠绿"
for k, v in pairs(THEME_ACCENTS[currentThemeName]) do
    Colors[k] = v
end

-- 全局换色钩子：仅靠 RegisterThemeUpdater 无法覆盖全部控件（其余控件在创建时把 Colors.X 拷贝成了固定色值）。
-- 这里前置声明「旧调色板 → 新调色板」批量换色器，等 screenGui 建好后再赋值，避免在 ApplyTheme 里引用未定义的局部变量。
local ApplyThemeRecolor

-- 轻量级主题色刷新注册表：仅记录依赖主题点缀色的控件回调，切换时 O(N) 直接赋值
local themeUpdaters = {}
-- 注册一个「主题切换时需要刷新颜色」的回调（加载期注册一次，运行期不再追加）
local function RegisterThemeUpdater(fn)
    if type(fn) == "function" then
        themeUpdaters[#themeUpdaters + 1] = fn
    end
end

-- 应用主题配色（silent=true 时只改颜色不写盘，用于启动阶段同步存档）
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
    -- 先用「旧值→新值」批量把已经渲染出去的控件换成新色，再更新 Colors 表
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

-- ============================================================================
-- 【模块 08-A：设备画像 (DeviceProfile) 与双端模式控制器 (ModeCtl)】
-- 作用：启动期一次性读取输入硬件能力（触屏/键盘/鼠标/手柄），得到「手机 / 电脑 / 混合」画像；
--   Config.DeviceMode = 自动 | 手机 | 电脑，手动强制优先于自动识别，随配置文件持久化；
--   ModeCtl.gen 为模式代次：每次切换 +1，所有延迟派发（触屏 0.12s 兜底）携带旧代次即作废；
--   模式切换只改「输入路由 + 悬停/按压反馈」，不在运行期新建或重建任何 UI 节点。
-- 后续修改指引：想加第三种模式（如手柄专用）改 FSYC.MODE_OPTIONS 与 ModeCtl.Resolve 即可，其余模块只读 ModeCtl.IsMobile()/Accepts()。
-- ============================================================================
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
    -- 判定口径（detected = 设备画像，三态；effective = 实际生效的默认模式，两态）：
    --   纯触屏（无键盘无鼠标）      → detected="mobile"，  effective="mobile"
    --   触屏 + 键鼠同时存在（混合）  → detected="hybrid"，  effective="desktop"（触屏笔记本 / 带键盘平板 / 模拟器）
    --   只有键鼠（含一个都探不到）   → detected="desktop"， effective="desktop"
    -- 混合设备默认按电脑跑，但两族输入都接受（自动模式），用户也可以手动切手机。
    local t, k, m = DeviceProfile.touch, DeviceProfile.keyboard, DeviceProfile.mouse
    if t and (k or m) then
        DeviceProfile.detected = "hybrid"
    elseif t then
        DeviceProfile.detected = "mobile"
    else
        -- 极端兜底：一个输入设备都探测不到时按电脑处理（键鼠事件不会触发，也不会把误判成触屏当成真手机）
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
local InputRouter -- 前向声明：模块 08-B 赋值；ModeCtl.Apply 回调它重绑输入
local mainFrame    -- 前向声明：模块 11 赋值；触屏兜底的可见性守卫读它（不留全局名）
local PacketGuard  -- 前向声明：模块 08-C 赋值；UnloadScript 里要清空它的去重表

function ModeCtl.Resolve(configured)
    -- 手动模式必须有硬件兜底：在**没有触屏的电脑**上强制「手机」→ Accepts 把每一次鼠标点击都当"外来输入族"丢弃，
    -- 面板从第一帧就点不动，快捷键也被禁 → 除了手改配置文件没有任何逃生口；纯触屏手机上强制「电脑」同样锁死。
    -- 现在：手动选择只在本机确有该输入族时生效，否则回落到设备画像推导出的可用模式。
    if configured == "手机" and DeviceProfile.touch then return "mobile" end
    if configured == "电脑" and (DeviceProfile.mouse or DeviceProfile.keyboard) then return "desktop" end
    return DeviceProfile.effective or "desktop"
end

function ModeCtl.IsMobile() return ModeCtl.mode == "mobile" end
function ModeCtl.IsDesktop() return ModeCtl.mode == "desktop" end

function ModeCtl.Label()
    return ModeCtl.IsMobile() and "手机（触屏）" or "电脑（键鼠）"
end

-- 设备描述：给 UI 只读信息行用（例：触屏+键盘 · 手动 · 混合）
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

-- 输入族隔离判定：返回该 UserInputType 在当前模式下是否允许参与 UI 交互
-- 是否「手动强制」模式：只有手动选了手机/电脑，才按输入族硬隔离
function ModeCtl.IsForced()
    -- 只有「手动选择」且「确实按该模式生效」才硬隔离；被硬件兜底或点不动自愈(runtimeOnly)改写为「自动」的不算强制
    local activeCfg = ModeCtl.configured or Config.DeviceMode
    if activeCfg == "手机" then return ModeCtl.mode == "mobile" end
    if activeCfg == "电脑" then return ModeCtl.mode == "desktop" end
    return false
end

-- 入参既接受 UserInputType 枚举，也接受输入总线内部的 "touch" / "mouse" 字符串。两档语义：
--   · 自动模式：两族输入都接受（触屏笔记本/模拟器很常见），由「同一次物理按下只派发一次」负责挡重复；
--   · 手动手机/电脑：硬隔离，只认该族输入，另一族事件直接丢弃并计数（用户明确表态后按表态执行）。
function ModeCtl.Accepts(inputType)
    if not Config.InputIsolation then return true end
    local isTouch = (inputType == "touch") or (inputType == Enum.UserInputType.Touch)
    local isMouse = (inputType == "mouse") or (inputType == Enum.UserInputType.MouseButton1)
        or (inputType == Enum.UserInputType.MouseButton2) or (inputType == Enum.UserInputType.MouseMovement)
    if not (isTouch or isMouse) then return true end -- 键盘 / 手柄 / 焦点事件不受输入族隔离影响
    if not ModeCtl.IsForced() then return true end
    if isTouch and ModeCtl.IsMobile() then return true end
    if isMouse and ModeCtl.IsDesktop() then return true end
    -- 纯查询：不在这里计数（UI 悬停/自检也会调用它），隔离计数只在真正拦下派发时 +1
    return false
end

-- 键盘快捷键：只在电脑模式放行（手机模式的屏幕键盘同样会发 KeyCode，容易误触隐藏/卸载热键）
function ModeCtl.AllowKeyboardShortcuts()
    -- 电脑模式常开；手机模式只在「真的探测到键盘」时放行：手机屏幕键盘同样会发 KeyCode（打字时会误触 RCtrl/END），
    -- 但接了蓝牙键盘/手柄键盘的用户不该被一刀切禁掉。
    -- 硬逃生口：本机根本没有触屏时（电脑），无论当前是什么模式都保留键盘快捷键，否则连 END 退出都按不出来。
    return ModeCtl.IsDesktop() or DeviceProfile.keyboard or (not DeviceProfile.touch)
end

-- 应用模式：configured = "自动" | "手机" | "电脑"；opts.force = true 时同模式也强制重绑
function ModeCtl.Apply(configured, opts)
    -- 卸载后（UI 已销毁、监听已断开）不再写配置、不再通知监听者：
    -- 旧版卸载后若外部脚本调用 device.set()，会重新挂全局输入监听并把已销毁的控件重新接上
    if not isRunning then return ModeCtl.mode end
    opts = opts or {}
    -- [审计-19] 用户主动切换模式时复位"点不动自愈"的两个一次性标记：
    -- 否则第一次自愈后 autoFellBack 永不复位（整场只能用一次），而切换前残留的 blockWindow 拦截计数
    -- 会让新模式的第一下点击就被算成第 5 次 → 刚选的模式立刻自己跳回去。自愈自身(runtimeOnly)不复位，避免死循环。
    if not opts.runtimeOnly then
        ModeCtl.autoFellBack = false
        ModeCtl.blockWindow = nil
    end
    local target = ModeCtl.Resolve(configured)
    local prev = ModeCtl.mode
    local prevConfigured = ModeCtl.configured
    ModeCtl.configured = (configured == "手机" or configured == "电脑") and configured or "自动"
    -- runtimeOnly：自动回落这类"自愈"只改运行时，不覆盖用户手动选的模式（否则一次误拦就把用户的选择悄悄写盘）。
    if not opts.runtimeOnly then
        Config.DeviceMode = ModeCtl.configured
    end
    -- 只要「生效模式」或「用户选择」发生变化就换代次：即使解析结果相同（如 手机→自动 仍解析为 desktop），
    -- 也视为一次模式决策变更，重建一次输入连接（幂等，不会累积）。
    -- 手动选择被硬件兜底改写时提示一次（不刷屏）
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
        -- 同步下拉文本：否则自愈之后用户看到的和实际生效的不一致；silent=true 不触发回调、不会二次写盘。
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

-- 「点不动」自愈：强制模式下如果 3 秒内连续被输入隔离拦下 5 次，说明用户手里的输入设备和当前模式不匹配
-- （典型：模拟器上报 TouchEnabled=true 但其实用鼠标，或触屏本被切成手机模式后改用鼠标）。
-- 这时自动回落到「自动」模式（两族都收）并记一条日志 —— 用户不会再遇到「面板突然点不动」。
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
        -- 延迟到下一帧再重绑：不要在派发链路里同步断开正在执行的连接
        task.defer(function()
            -- runtimeOnly：只把运行态切回「自动」，不改用户手动选的模式（下拉会同步显示运行时模式）
            if isRunning then pcall(ModeCtl.Apply, "自动", { force = true, runtimeOnly = true }) end
        end)
    end
end

ModeCtl.configured = (Config.DeviceMode == "手机" or Config.DeviceMode == "电脑") and Config.DeviceMode or "自动"
ModeCtl.mode = ModeCtl.Resolve(ModeCtl.configured)

-- ============================================================================
-- 【设备自适应尺寸度量】加载期按「生效模式」一次性算好尺寸；运行期切换模式只改输入路由与悬停/按压反馈，
-- 不改已建节点尺寸（UI 静态预定义、零重建）。DashUI.metrics.touch 由 ModeCtl.Apply 实时改写，运行期 `if UIM.touch` 自动跟随模式。
-- ============================================================================
local IS_TOUCH_ONLY = ModeCtl.IsMobile()
-- 加载期读一次视口（返回 1 个表，避免占用多个 chunk 级 local）：
--   手机竖屏 = 窄导航(88px) + 按视口反推窗口尺寸，缩放 0.9 后正好铺满，避免 760 设计宽在 390 屏上被压到 0.45 而看不清
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

-- [UI-重构] 导航每项高度的自适应计算已移到 CATEGORY_ORDER 定义之后（原来在这里写死了「9 个标签 / 8 个间距」，
-- 页签合并成 7 个之后会算出偏小的值，把小屏导航压得比需要的更矮）。见下方 "导航高度按实际页数反推"。
-- 顶层不保留未使用的 UIM 局部别名（内部作用域按需绑定 local UIM = DashUI.metrics，节省顶层寄存器并消除遮蔽）

-- 按优先级（gethui -> CoreGui -> PlayerGui）安全获取 UI 挂载父容器（零临时实例创建）
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

-- [审计-2] 加载中段二次注入守卫：全文原来只在第 35/130 行校验启动令牌，若旧实例已过 130 行、尚未跑完脚本时被新实例注入，
-- 旧实例会继续建 UI 并在第 2712 行覆盖新实例的卸载登记 → 双实例并存、双倍发包。这里在开始创建 UI 节点前再校验一次。
if myBootToken and sharedEnv and sharedEnv.IdenticalFishingBootToken ~= myBootToken then return end
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdenticalHeavyweightFishing"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- 使用安全正整数 DisplayOrder (100) 置顶于普通游戏 HUD 之上，避免 INT32_MAX 在部分移动端执行器排序溢出
screenGui.DisplayOrder = 100
-- 主题批量换色用静态 ClassName -> Color3 属性表取代运行时 pcall 动态试探：根除「某节点含同名子实例（如名为 "Color" 的子节点）
-- 污染 ClassName 缓存、在其它同类型节点上读取 inst[prop] 抛错崩溃」的隐患，也省掉首次换色的数十次 pcall 闭包开销。
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
    -- 非主题色（状态色/文字色等）按值保护：即使某套主题的点缀色恰好与它同值，也不参与替换
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
-- 挂载彻底失败必须留下可诊断日志，否则整个 UI 构建成功但玩家什么都看不到
if not screenGui.Parent then
    FLogErr("UI", "ScreenGui 挂载失败（gethui/CoreGui/PlayerGui 均不可用），悬浮窗将不可见")
end
table.insert(cleanUpInstances, screenGui)

-- ============================================================================
-- 【模块 08-B：输入总线 InputRouter —— 单次派发 / 双端隔离 / 切换模式正确解绑】
-- 旧实现（FSY15.0）的问题：① 每个按钮同时直连 Activated 与 MouseButton1Click，只靠 60ms 时间防抖，
--   一次触屏点按会被引擎合成为「Activated + MouseButton1Click」，回调间抖动 >60ms 或执行器补发就会执行两次
--   （开关被切两次、抛竿发两包）；② 触屏兜底是另一条独立通道（0.12s 后按坐标找按钮补发），与前两条互不知情；
--   ③ 切换设备/模式时没有任何解绑入口，连接只会越挂越多。
-- 现实现：① 统一入口：所有点击登记到 InputRouter.records，唯一派发函数 Dispatch 决定是否执行；
--   ② 物理按下序号：UIS.InputBegan 每按下一次 pressSeq + 1，点击事件在「按下归并窗口」内归属该序号，同序号重复到达一律丢弃；
--   ③ 模式隔离：手机模式拒绝鼠标来源、电脑模式拒绝触屏来源（含兜底），由 ModeCtl.Accepts 判定；
--   ④ 正确解绑：每个按钮的连接登记在 rec.conns，切模式逐条 Disconnect 后按新模式重建；
--      已排队的 0.12s 兜底携带 ModeCtl.gen，代次不符直接作废；卸载时 Destroy 全断。
-- ============================================================================
-- 点击冷却常量：原先散落在 Dispatch 里的 (IsMobile() and 0.12) or 0.06 魔法数，语义是「同控件两次独立点击的最小间隔」，手机手指误触多给一倍余量。
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

-- 取「最近一次物理按下」的来源与序号；超过归并窗口视为无按下证据（例如执行器直接 firesignal）
local function RecentPress()
    if not InputRouter.pressSource then return nil, nil, nil end
    local window = math.max(0.05, (tonumber(Config.InputDedupeMs) or 600) / 1000)
    local age = tick() - InputRouter.pressAt
    if age <= window then
        return InputRouter.pressSource, InputRouter.pressSeq, age
    end
    return nil, nil, nil
end

-- 事件通道 → 输入来源：有按下证据时以证据为准（触屏点按被合成 MouseButton1Click 时仍算触屏）
local function SourceForChannel(channel)
    local pressSrc, seq, pressAge = RecentPress()
    -- 通道身份优先，按下证据只补「族无关」的 Activated：旧实现「最近 600ms 内有任意按下就用那次按下的来源」
    -- 会覆盖通道自身身份（混合设备上「先手指点一下、0.6s 内再用鼠标点」，鼠标点击会被判成 touch 而在手动电脑模式下被丢弃，
    -- 反过来手动手机模式下真实触屏也会被判成 mouse 丢掉）—— 表现就是"点了没反应"。
    if channel == "touch" then return "touch", seq end
    if channel == "mouse" then
        -- 引擎会把一次触屏点按同时合成 Activated 与 MouseButton1Click。极短窗口（≤150ms）内若最近一次按下是触屏，
        -- 这个 MouseButton1Click 就是它合成的，仍按触屏归属 —— 否则「手动电脑模式下触屏被整体拦掉」会出现缺口。
        -- 真实鼠标点击会有自己的 InputBegan(mouse) 把 pressSource 覆盖成 mouse，不会被这条规则误伤。
        if pressSrc == "touch" and pressAge and pressAge <= 0.15 then return "touch", seq end
        -- 纯手机（无鼠标硬件）的 MouseButton1Click 也只可能是合成事件，按触屏算
        if ModeCtl.IsMobile() and not DeviceProfile.mouse then return "touch", seq end
        return "mouse", seq
    end
    return pressSrc, seq
end

-- 唯一派发入口：返回 true 表示本次真的执行了回调
function InputRouter.Dispatch(button, channel, opts)
    local rec = InputRouter.records[button]
    if not rec or not isRunning then return false end
    opts = opts or {}
    local now = tick()
    -- 兜底派发必须确认「期间没有新的按下」，否则会把旧坐标的点击补到新手势上
    if opts.seq and opts.seq ~= InputRouter.pressSeq then
        ModeCtl.stats.fallbackSkipped = ModeCtl.stats.fallbackSkipped + 1
        return false
    end
    local source, seq = SourceForChannel(channel)
    -- ① 输入族隔离（真正拦下才计数）
    if source and not ModeCtl.Accepts(source) then
        ModeCtl.stats.isolated = ModeCtl.stats.isolated + 1
        ModeCtl.NoteIsolatedBlock(now) -- 连续被拦 → 自动回落到「自动」模式
        return false
    end
    -- ② 同一次物理按下只派发一次（Activated / MouseButton1Click / 触屏兜底 三通道归一）
    if seq and rec.lastSeq == seq then
        ModeCtl.stats.deduped = ModeCtl.stats.deduped + 1
        return false
    end
    -- ③ 同控件最小间隔（手机 120ms / 电脑 60ms）；两次独立按下序号不同，不受影响
    local cooldown = rec.cooldown or (ModeCtl.IsMobile() and FSYC.CLICK_COOLDOWN_MOBILE or FSYC.CLICK_COOLDOWN_DESKTOP)
    if (now - (rec.lastAt or 0)) < cooldown then
        ModeCtl.stats.deduped = ModeCtl.stats.deduped + 1
        return false
    end
    rec.lastSeq, rec.lastAt = seq, now
    ModeCtl.stats.dispatched = ModeCtl.stats.dispatched + 1
    local ok, err = pcall(rec.callback)
    if not ok then FLogErr("点击回调", tostring(button and button.Name) .. " 执行异常: " .. tostring(err)) end
    -- 最近一次派发快照（复用同一张表，零分配）：排查「点到哪、走的哪族、哪个模式代次」
    local last = ModeCtl.stats.last
    last.t, last.kind, last.family = now, channel, source
    last.mode, last.gen, last.ok = ModeCtl.mode, ModeCtl.gen, ok
    last.name = (button and button.Name) or "?"
    return true
end

-- 为单个控件挂接当前模式需要的通道（Activated 覆盖触屏与键盘/手柄，MouseButton1Click 覆盖鼠标）
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

-- 绑定一个按钮：重复绑定只替换回调，不再重建连接（旧实现会重建，切换模式后容易漏断）
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

-- 绑定游戏原生 HUD 按钮（不属于本脚本 UI，卸载时同样要断）：mobileOnly=true 时只在手机模式挂接，
-- 因为桌面端的原生按钮由游戏自己的 LocalScript 处理，我们再补一刀就是重复发包。
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

-- 按当前模式重绑全部按钮（切换模式时调用；连接先断后建，不会累积）
function InputRouter.RebindAll()
    -- 这里**只断开、不删记录**：HUD 钓鱼按钮的兜底绑定被 hookedManualFishBtns 一次性守卫，一旦记录被删、按钮之后又挂回来，
    -- 就再也没有代码会重新绑定它 —— 等于用一个"可能有界的泄漏"换"永久失效的手动兜底"，不划算。
    -- 记录本身在卸载时由 Destroy 统一清空，运行期数量被"HUD 重建次数"限死，可以接受。
    for button, rec in pairs(InputRouter.records) do
        DisconnectRecord(rec)
        if button.Parent ~= nil and not (rec.mobileOnly and not ModeCtl.IsMobile()) then
            ConnectRecord(button, rec)
            ModeCtl.stats.rebinds = ModeCtl.stats.rebinds + 1
        end
    end
end

-- 全局输入监听：物理按下序号 + 触屏兜底（只在手机模式排队）
function InputRouter.BindGlobal()
    for i = 1, #InputRouter.modeConns do pcall(function() InputRouter.modeConns[i]:Disconnect() end) end
    table.clear(InputRouter.modeConns)
    local conns = InputRouter.modeConns

    conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gpe)
        if type(input) == "table" and input._isFSYSynthetic then return end
        -- [V15.44] 恢复 15.31 的 gpe 过滤（15_31.lua:2187-2188 的 if gpe then return end 被重构改成了 _gpe）。
        -- gpe=true 表示这次按键已被 GUI 消费（正在 TextBox 里打字），不过滤会让
        -- 「在搜索框 / 自定义传送点名字里输入」误触 RightControl 显隐甚至 End 卸载。
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
            -- [Delta 减负 M3] 手指/鼠标高频移动事件改用分量平方比较（14^2 = 196），省去每次新建 Vector3 与开方运算，数学判定 100% 等价。
            local dx = input.Position.X - InputRouter.pressPos.X
            local dy = input.Position.Y - InputRouter.pressPos.Y
            if (dx * dx + dy * dy) > 196 then InputRouter.pressMoved = true end
        end
    end)

    conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
        if not InputRouter.pressPos then return end
        -- [审计-13] 输入类型过滤必须早于 pressPos 清理：原先任何其它输入的抬起（键盘/手柄/鼠标侧键/第二根手指）
        -- 都会先把本次按下的坐标清掉，导致触屏兜底派发被取消 → 手机偶发"点了没反应"
        if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local pos, moved = input.Position, InputRouter.pressMoved
        local held, seqAtPress, pressSource = tick() - InputRouter.pressAt, InputRouter.pressSeq, InputRouter.pressSource
        InputRouter.pressPos = nil
        if moved or held > 0.8 then return end
        -- 兜底只在「手机模式 + 这次按下确实是触屏」时排队：电脑模式不排队 —— 鼠标点击不会在 0.12s 后被「补一刀」；
        -- 鼠标按下也不排队 —— 否则等于给鼠标点击开了一条绕过输入隔离的暗门
        -- （强制手机模式下鼠标点击本该被拒，兜底却会把它当成触屏再派发一次）。
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

-- 模式切换：先让在途手势与排队兜底失效，再按新模式重绑按钮与全局监听
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

-- 卸载：断开全部按钮连接与全局监听（UnloadScript 调用）
function InputRouter.Destroy()
    for _, rec in pairs(InputRouter.records) do DisconnectRecord(rec) end
    table.clear(InputRouter.records)
    for i = 1, #InputRouter.modeConns do pcall(function() InputRouter.modeConns[i]:Disconnect() end) end
    table.clear(InputRouter.modeConns)
end

InputRouter.BindGlobal()

-- 对外调试/测试入口（UI 不依赖它；只读 + 一个 set，便于自检与远程排查）
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
    -- 纯数据快照：外部工具/自检无需猜测字段是函数还是值
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

-- 兼容旧调用点：BindClick 全部改走输入总线，签名与返回值保持不变（返回 fire 函数）
local function BindClick(button, callback)
    return InputRouter.BindClick(button, callback)
end

-- ============================================================================
-- 【说明浮层已移除】旧版 FSY13.1 没有「悬浮 / 长按弹说明」；手机上按住一行会盖住正在点的开关，反而挡手。
-- 这里保留同名空实现，调用点（createBaseRow / createButtonRow）零改动；说明文案照旧以「副标题」形式直接印在行内。
-- ============================================================================
DashUI._hideTip = function() end
DashUI.attachTip = function() end

-- 【省电遮罩】关闭 3D 渲染时的静态黑屏层（不参与输入拦截）
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

-- ============================================================================
-- 【模块 08-C：发包去重闸 PacketGuard】定位：只去重、不限流。同一个 Remote + 同一组参数在 Config.PacketDedupeMs 内只放行一次。
-- 为什么需要：输入层万一漏了一次（旧版三通道、外部脚本模拟点击、执行器重放），同一个业务意图就会变成两包 ——
--   服务端看到的是「不可能的操作频率」。
-- 与原有业务节流的关系：AutoSkillEngine 冷却、FishGate 战斗闸、各 nextXxxAt 节拍全部原样保留；
--   这里只在「窗口内完全相同」时丢，任何真实的新意图（时间或参数不同）都照常发出，不影响功能。
-- ============================================================================
PacketGuard = { sent = 0, dropped = 0, lastAt = {}, combat = false }
PacketGuard.windowMs = FSYC.Tunables and FSYC.Tunables.PacketDefaultWindowMs or 40
-- 战斗域专用窗口：FireGuiButton 为了兼容不同执行器会「getconnections + firesignal + replicatesignal」三通道齐发，
-- 同一次逻辑点击因此可能把同一个包发 3 次（间隔 <1ms，参数完全相同）。战斗域不能套用 40ms 普通窗口
-- （猛击/节奏的合法包间隔可低到 ~20ms），但「10ms 内逐字节相同」的战斗包只可能来自同一次点击的重复通道 —— 用窄窗口收成 1 包。
PacketGuard.combatWindowMs = FSYC.Tunables and FSYC.Tunables.PacketCombatWindowMs or 10
PacketGuard.failStreak = {}
PacketGuard.backoffUntil = {}
DashUI.packetGuard = PacketGuard

-- 浅层确定性序列化 table 参数（如 BossPhase2Action 的 {Index=n, Hit=true} 与 {Hit=false}），消除原先所有 table 参数统一退化为常量字符串 "table" 引发的不同载荷误判重隐患。
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
    -- 快速路径：战斗路径上绝大多数调用是 1 个标量或单表参数。
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

-- [Delta 减负 M4] Remote 完整路径弱键缓存 + 具名无闭包读取：原实现每发一包在 Allow 与 RecordResult 各调一次 GetFullName()
-- （两次父链遍历 + 字符串拼接）。改为弱键表缓存（不强引用实例），首次读取使用具名函数配合 pcall 零闭包分配。
PacketGuard.nameCache = setmetatable({}, { __mode = "k" })
PacketGuard._readFullName = function(inst) return inst:GetFullName() end
function PacketGuard.RemKey(rem)
    if typeof(rem) ~= "Instance" then return tostring(rem) end
    local cache = PacketGuard.nameCache
    local cached = cache[rem]
    if cached ~= nil then return cached end
    local okName, full = pcall(PacketGuard._readFullName, rem)
    local key = (okName and type(full) == "string" and full ~= "") and full or rem.Name
    cache[rem] = key
    return key
end

-- 记录远程调用成功或异常结果：发生网络/调用报错时按指数退避冷却，杜绝报错后逐帧高频重发
function PacketGuard.RecordResult(rem, ok, err)
    local name = PacketGuard.RemKey(rem)
    if ok then
        PacketGuard.failStreak[name] = nil
        PacketGuard.backoffUntil[name] = nil
    else
        local streak = (PacketGuard.failStreak[name] or 0) + 1
        PacketGuard.failStreak[name] = streak
        local baseSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffBaseSec or 0.50
        local maxSec = FSYC.Tunables and FSYC.Tunables.RemoteBackoffMaxSec or 1.20
        -- 战斗域豁免长熔断：PacketGuard.combat 由 SafeFireEventCombat 在调用期间置真；战斗包宁可多发几次也不能被熔断掐死，故基数与上限都压到很短。
        if PacketGuard.combat then
            baseSec = FSYC.Tunables and FSYC.Tunables.CombatBackoffBaseSec or 0.10
            maxSec = FSYC.Tunables and FSYC.Tunables.CombatBackoffMaxSec or 0.35
        end
        local waitSec = math.min(baseSec * (2 ^ (streak - 1)), maxSec)
        PacketGuard.backoffUntil[name] = tick() + waitSec
        FLogWarn("发包退避", string.format("%s 触发异常退避 (第 %d 次, 冷却 %.2fs): %s", name, streak, waitSec, tostring(err)))
    end
end

-- 返回 true = 放行；false = 判定为窗口内重复或处于异常退避期，已计数丢弃
function PacketGuard.Allow(rem, ...)
    local window = PacketGuard.combat and (PacketGuard.combatWindowMs or 0)
        or tonumber(Config.PacketDedupeMs) or PacketGuard.windowMs or 40
    local now = tick()
    local name = PacketGuard.RemKey(rem)
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
        local maxWindow = math.max(DashUI.ClampNum(Config.PacketDedupeMs, 0, 200, 40), PacketGuard.combatWindowMs or 10) / 1000
        for k, at in pairs(PacketGuard.lastAt) do
            if (now - at) > maxWindow then PacketGuard.lastAt[k] = nil end
        end
        for k, deadline in pairs(PacketGuard.backoffUntil) do
            if (now - deadline) > 60.0 then
                PacketGuard.backoffUntil[k] = nil
                PacketGuard.failStreak[k] = nil
            end
        end
    end
    return true
end

-- 【模块 09：运行时状态表、10大特殊NPC雷达字典 (liveNPCs) 与安全卸载函数 (UnloadScript)】
-- 作用：预声明鱼名/上锁缓存与全图特殊 NPC 字典 liveNPCs（三岛神灵 + 道士/茅山/傻子商人 + 四圣兽）；UnloadScript() 一键断连、取消协程、销毁 UI/ESP 并恢复画质与碰撞。
-- 后续修改指引：在“传送 -> 特殊NPC实时检测”中新增监控目标时，同步改 liveNPCOrder 与 liveNPCs。
-- ============================================================================
-- 预声明需要在卸载时重置的缓存与状态变量
local patternCache = {}
local patternCacheCount = 0
local cachedRuleMatchers = {}
FSYC.cachedRuleSource = nil
-- 文件级越南语/ASCII 统一小写折叠函数（处理越南语带声调大写字母 Ư/Đ/Ầ 等，供全模块多语言匹配共用）
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
-- 收藏与安全卖鱼状态表（弱键表自动随实例销毁回收，防止内存泄漏与 Toggle 翻转）
FSYC.watchedBagFolders = setmetatable({}, { __mode = "k" })  -- 已挂载 ChildAdded 自动收藏监听的背包容器集合
local isSellingInProgress = false                             -- 卖鱼协程互斥锁，防止并发重入
local isClaimingDailyTask = false
local isClaimingDailySign = false
FSYC.dailyTaskLockAt = 0
FSYC.dailySignLockAt = 0
local activePromptTasks = setmetatable({}, { __mode = "k" })
local OnlineNPCs = {}
local isMicroTeleportingNPC = false
-- 微瞬移锁的时间戳：协程若被异常中断（切场景 / 角色重生 / 报错）锁会永久为 true，同时冻结自动抛竿与 Boss 挂机，由低频调度器做 12s 超时自愈
local microTeleportLockAt = 0
local DismissStuckPromptsAndRestore
local liveNPCOrder = {
    "Spirit_Bamboo", "Spirit_Frost", "Spirit_Amber",
    "Taoist", "Maoshan", "DumbGuy",
    "VermilionBird", "BlackTortoise", "WhiteTiger", "AzureDragon"
}

-- 全图 NPC 容器与地图根节点名称常量（供 NPC 查找与全图雷达共用）
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

-- 卸载过程只允许执行一次，防止关闭按钮、重复执行和重生回调并发触发清理。
-- 注意：卸载时不直接覆写 Config.FlyEnabled / Config.Noclip（避免破坏用户内存中或即将保存的配置），物理与穿墙循环均通过 isRunning 状态位安全停止并恢复原状。
FSYC.unloadStarted = false
-- [前向声明] 下列名字在本文档更晚处才声明、在模块 22/23 才赋值：不提前声明会被解析成全局变量并恒为 nil，导致卸载分支被静默跳过。
-- MakeSyntheticInput 原声明落在「标签页构建作用域」内，跨函数不可见，此处一并提前声明供区域 B/D 使用。
local IsToolFishingRod, IsCharacterHoldingFishingRod, RestoreMobileFishingButtonUI, StopLingeringFishingAnimations, MakeSyntheticInput
-- [前向声明] 卸载时需清空的 UI 注册表（原声明在模块 12，晚于本函数）
local searchState, collapsibleSections
-- 幂等安全卸载函数：断开所有连接、取消后台协程、恢复按键/对话框/钓鱼按钮、销毁 UI/ESP 实例并还原画质与角色碰撞
local function UnloadScript()
    if FSYC.unloadStarted then return false end
    FSYC.unloadStarted = true
    isRunning = false
    FLog("卸载", "开始卸载：断开全部事件连接、取消受管协程、还原游戏视觉与输入状态、销毁 UI 节点")

    -- 1. 立即终止进行中的滑块拖拽并恢复外层 ScrollingFrame 滚动能力
    for fn in pairs(activeSliderCleanupFns) do pcall(fn) end
    table.clear(activeSliderCleanupFns)

    -- 2. 立即释放所有处于按下状态的虚拟按键 (Z/X/C/V) 与正在按住的 ProximityPrompt
    if DashUI and type(DashUI._releaseAllVirtualKeys) == "function" then
        pcall(DashUI._releaseAllVirtualKeys)
    end
    -- 同步补发虚拟鼠标抬起（必须早于取消 activeThreads，否则抬起回调被取消后左键永久按下）
    if DashUI and type(DashUI._releaseAllVirtualMouse) == "function" then
        pcall(DashUI._releaseAllVirtualMouse)
    end
    for pr in pairs(activePromptTasks) do
        if pr and pr.Parent then
            pcall(function() pr:InputHoldEnd() end)
        end
    end
    table.clear(activePromptTasks)

    -- 3. 取消所有受管的后台协程与防抖计时器
    if activeThreads then
        local selfThread = coroutine.running()
        for th in pairs(activeThreads) do
            if th ~= selfThread then
                pcall(task.cancel, th)
            end
        end
        table.clear(activeThreads)
    end

    -- 4. 清理防误卖分批队列与票据引擎本地隐藏过的原生对话界面
    if DashUI and type(DashUI._cleanupFG) == "function" then pcall(DashUI._cleanupFG) end

    currentlyOpenDropdown = nil
    if cameraViewportConn then
        pcall(function() cameraViewportConn:Disconnect() end)
        cameraViewportConn = nil
    end
    if sharedEnv then
        -- 保持 IdenticalHookInstalled = true，由 __namecall 内部检测 IdenticalFishingRunning == false 自动直通原函数
        sharedEnv.IdenticalFishingRunning = false
        -- 卸载时一并清掉战斗态标志与时间戳，避免下一次注入读到上一次的残留 true
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
        -- 上面这次调用内部（模块 23 的还原函数）会重新写入 sharedEnv 的三个契约字段，必须在其之后再清空一次，否则卸载后残留存活实例引用，造成跨注入误保护与内存泄漏
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
    -- 5. 取消所有进行中的补间动画（含通知卡片预建 Tween）并断开全部临时/常驻/角色事件连接
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
    -- [审计-10] 清掉模式监听：否则监听闭包会钉住已销毁的 TextLabel（devInfo/devNow）直到整个 chunk 被回收
    if ModeCtl and ModeCtl.listeners then table.clear(ModeCtl.listeners) end
    for conn in pairs(activeDragConns) do pcall(function() conn:Disconnect() end) end
    table.clear(activeDragConns)
    -- 输入总线与发包去重闸：先断按钮/全局输入连接，再断常驻连接表
    if InputRouter then pcall(InputRouter.Destroy) end
    if PacketGuard then
        table.clear(PacketGuard.lastAt)
        if PacketGuard.failStreak then table.clear(PacketGuard.failStreak) end
        if PacketGuard.backoffUntil then table.clear(PacketGuard.backoffUntil) end
    end
    -- [审计 R-14] RemoteFunction 的在飞/退避/失败计数三张表声明在模块 08 的 do 块内，
    -- 这里只能通过 FSYC.invokeReset 清理（直接引用会变成 nil 全局，等于没清）。
    if FSYC and type(FSYC.invokeReset) == "function" then pcall(FSYC.invokeReset) end
    -- [Delta 减负 M1 / 退出清理加固] 统一遍历治理器登记的全部句柄（含 activeConnections / characterConnections / 临时拖拽池 / 失效 Prompt）
    -- 一次性 Disconnect 并清空池表；下面的原版逐个断开逻辑保留为兜底，重复 Disconnect 幂等无副作用。
    if FSYC.Gov and FSYC.Gov.Shutdown then pcall(FSYC.Gov.Shutdown) end
    for _, conn in ipairs(activeConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(activeConnections)
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    for _, inst in ipairs(cleanUpInstances) do pcall(function() if inst then inst:Destroy() end end) end
    table.clear(cleanUpInstances)
    -- 释放 UI 注册表，避免已销毁节点被残留闭包钉住
    if UIControls then table.clear(UIControls) end
    if collapsibleSections then table.clear(collapsibleSections) end
    if searchState and searchState.rows then table.clear(searchState.rows) end
    if DashUI and type(DashUI._clearUIDeps) == "function" then pcall(DashUI._clearUIDeps) end
    if DashUI and type(DashUI._clearHomeScenes) == "function" then pcall(DashUI._clearHomeScenes) end
    -- 6. 恢复角色 Humanoid 移速与 PlatformStand 状态
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
        -- 先走名字键兜底（抗实例重建），再走原有的实例键兜底
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
    -- [审计-9] 上一行已把 sharedEnv.IdenticalFishingConfig 置 nil，普通 FLog 会被日志开关直接丢弃 →
    -- 这条"卸载完成"永远看不到，改用 ERROR 级（恒输出且 2s 去重）
    FLogErr("卸载", "卸载完成，全部连接、受管协程、视觉设置与缓存已完整释放")
    return true
end

-- [审计-2] 登记卸载函数前再校验一次启动令牌：被新实例取代后不再覆盖 IdenticalHeavyweightFishingUnload
if myBootToken and sharedEnv and sharedEnv.IdenticalFishingBootToken ~= myBootToken then return end
if sharedEnv then sharedEnv.IdenticalHeavyweightFishingUnload = UnloadScript end

-- ============================================================================
-- 【模块 10：右上角防刷屏通知弹窗系统 (ShowNotification) 与跨服跳转 (ServerHop)】
-- 作用：ShowNotification() 带 1.2s 同文去重、最多 4 张卡片队列、支持手指轻触即关的滑入式通知卡片；ServerHop() 请求 Roblox 公开服务器列表 API，挑选未满员的不同实例执行跨服跳转（失败时自动回退随机重连）。
-- 后续修改指引：调整 MAX_NOTIF_CARDS 可改变同时显示的最大通知数量；调整 ServerHop 的 85.0 秒冷却可改变自动跳服间隔。
-- ============================================================================
-- 通知容器覆盖右侧整条屏幕高度，显式声明为非交互层（Active=false），避免挡住手机屏幕操作
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

-- 播放滑出动画并隐藏（不销毁）通知卡片
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

-- UI 静态化：加载阶段一次性预建 4 张通知卡片（含可复用的滑入/滑出 Tween），运行期 ShowNotification 只改文本/颜色/可见性，绝不再 Instance.new + TweenService:Create + Destroy。
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

    -- 支持手指/鼠标轻触通知卡片立即滑出关闭，不遮挡手机屏幕操作（遵循双端输入隔离）
    card.InputBegan:Connect(function(input)
        if not ModeCtl.Accepts(input.UserInputType) then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            DismissNotifCard(rec)
        end
    end)
end

-- 右上角通知弹窗：1.2s 同文去重 + 最多 4 张卡片循环复用静态池
ShowNotification = function(title, text, notifType, duration)
    if not isRunning or not notifContainer or not notifContainer.Parent then return end
    -- duration 必须是 (0, 60] 内的有限数，避免 NaN/负数/超大值把卡片槽长期占住
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

    -- 优先取空闲卡片；全部占用时复用最久未刷新的那张（不再销毁重建节点）
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
local hopToken = 0
-- [V15.44 / HOP-FIX] 初值改成 tick()：旧版是 0，而 ServerHop 的冷却判断是 prevHopTime > 0 and ...，
-- 于是「本会话第一次自动跳服」完全绕过 85 秒冷却 —— 脚本刚注入、雷达第一次巡检（90s）就可能真的换服。
local lastLocalHopTime = tick()
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
    if isHopping and (tick() - hopLockAt) < 20 then return end
    local now = tick()
    local prevHopTime = math.max(lastLocalHopTime, (sharedEnv and type(sharedEnv.IdenticalLastHopTime) == "number") and sharedEnv.IdenticalLastHopTime or 0)
    if not manualClick and prevHopTime > 0 and (now - prevHopTime < 85.0) then
        return
    end
    isHopping = true
    hopLockAt = now
    hopToken = hopToken + 1
    local myHopToken = hopToken
    local prevSavedHopTime = prevHopTime
    lastLocalHopTime = now
    if sharedEnv then sharedEnv.IdenticalLastHopTime = now end
    ShowNotification("服务器跳转", "正在搜索可用服务器...", "WARN")
    task.spawn(function()
        local teleported = false
        local placeId = game.PlaceId
        pcall(function()
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
            -- [审计-15] 原条件 not ok and not fallbackOk：ok 只代表"列表阶段没抛错"，列表通了但没空位、
            -- 随机重连又失败时两条都成立不了 → 界面停在"正在跳转"且没有任何失败提示
            if not fallbackOk then
                if hopToken == myHopToken then
                    lastLocalHopTime = prevSavedHopTime
                    if sharedEnv then sharedEnv.IdenticalLastHopTime = prevSavedHopTime end
                end
                ShowNotification("服务器跳转", "获取服务器列表失败且随机重连未成功，稍后重试。", "ERROR")
            end
        end
        pcall(task.wait, 4)
        if hopToken == myHopToken then
            isHopping = false
        end
    end)
end
end)() end -- end of Module 10 Notification & ServerHop Scope

-- ============================================================================
-- 【模块 11：FSY 可拖拽悬浮球 (FloatingBall) 与主窗口自适应缩放容器 (MainFrame)】
-- 作用：圆形 FSY 悬浮球（按住拖动钳制屏内，松手位移很小视为点击唤起/收起主面板；拖拽期间才挂 UIS 连接，平时零回调开销、无常驻动画）+ 主面板 800x552（触屏 760x560），UIScale 按视口与 Config.UIScale 自适应，手机小屏与 PC 大屏均完整显示不越界。
-- 后续修改指引：悬浮球直径改 FLOATING_BALL_SIZE、初始位置改 floatingBall.Position；主窗口尺寸改 DashUI.metrics.winW / winH（模块 08）。
-- ============================================================================
local ToggleUiVisibility -- mainFrame 已在模块 08-A 前向声明，此处不再重复 local
local navList, tabCanvasRefreshers, currentActiveTab, SwitchTab, CreateTab, CloseUI

-- 静态 FSY 悬浮球（深绿底 + 主题描边 + 居中 FSY + 运行状态点，无任何常驻动画）
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

do -- Static Floating FSY Ball Scope
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

    -- [UI-STATUS] 悬浮球状态灯：这个绿点原来是写死的，永远绿色、不反映任何状态。
    -- 现在按 DashUI.GetRunLevel() 上色，让「面板收起时扫一眼球就知道要不要打开」：
    --   绿=正在钓鱼/搏斗（一切正常） 灰=空闲（没在干活） 黄=有阻塞（如卖鱼被延后） 红=有失败
    local BALL_LEVEL_COLORS = {
        ok   = Colors.AccentGreen,
        idle = Colors.TextMuted,
        warn = Colors.AccentYellow,
        err  = Colors.AccentRed,
    }
    function DashUI.RefreshBallStatus()
        if not fbStatusDot or not fbStatusDot.Parent then return end
        local lv = (DashUI.GetRunLevel and DashUI.GetRunLevel()) or "idle"
        local col = BALL_LEVEL_COLORS[lv] or Colors.TextMuted
        if fbStatusDot.BackgroundColor3 ~= col then fbStatusDot.BackgroundColor3 = col end
    end

    RegisterThemeUpdater(function()
        fbStroke.Color = Colors.BorderAccent
        fbLabel.TextColor3 = Colors.AccentSoft
        -- 主题切换后按当前运行级别重新上色，而不是无条件刷回绿色
        if DashUI.RefreshBallStatus then DashUI.RefreshBallStatus() end
    end)

    local fbDragging = false
    local fbActiveTouch = nil
    local fbDragStart = nil
    local fbStartAbs = nil
    local fbMovedDistance = 0
    local fbInputEndConn = nil
    local fbDragChangedConn = nil
    local fbDragEndedConn = nil

    -- 取当前可拖拽区域尺寸（优先 ScreenGui 实际像素尺寸，退回相机视口）
    local function getScreenBoundsSize()
        if screenGui and screenGui.Parent and screenGui.AbsoluteSize.X > 0 and screenGui.AbsoluteSize.Y > 0 then
            return screenGui.AbsoluteSize
        end
        local cam = Workspace.CurrentCamera or Camera
        return (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    end

    -- 根据拖拽位移更新悬浮球位置（自动钳制在屏幕内）
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

    -- 结束悬浮球拖拽并断开全部临时输入连接
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
    -- 悬浮球点击：位移小于 8px 才视为点击；250ms 内重复触发直接忽略
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

-- 缓存上次计算的视口尺寸与缩放值，未变化时跳过 UIScale 与通知容器重设
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

do -- 主窗口外观：圆角 + 细描边 + 顶栏底部柔和高光
    local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(0, 14); mc.Parent = mainFrame
    local ms = Instance.new("UIStroke"); ms.Color = Colors.BorderSubtle; ms.Thickness = 1; ms.Transparency = 0.1; ms.Parent = mainFrame
    RegisterThemeUpdater(function() ms.Color = Colors.BorderSubtle end)
end

-- [折叠面板] 折叠分组注册表（供搜索过滤 / 一键展开折叠读取）
collapsibleSections = {}
-- [搜索] 静态搜索状态：rows=行索引 query=当前关键词 refresh=切页重算 box/count/clear=静态控件
searchState = {rows = {}, query = "", refresh = nil, box = nil, count = nil, clear = nil}

-- ============================================================================
-- 【模块 12：主窗口外壳（顶栏 / 左侧 9 标签导航 / 细搜索条 / 页路由 / 底部状态栏）】
-- 作用：左侧固定 9 个平铺标签（仪表盘 / 钓鱼 / Boss / 任务 / 神灵 / 传送 / 视觉 / 移动 / 配置文件，一屏一件事，无第二层导航）；
--   顶部细搜索条常驻（34px），支持模糊匹配、命中高亮、自动展开分组、自动跳到命中最多的一页，对「折叠分组」与「抽屉胶囊」一视同仁；
--   CreateTab(页名) 直接返回该页的滚动容器，页面构建代码无需改动业务回调；底部状态栏保留（品牌 + 键位提示）。
-- ============================================================================
do (function() -- Window Shell Scope
local UIM = DashUI.metrics

-- 导航元数据：顺序即左侧导航顺序（9 个平铺标签：一屏一件事）
-- [UI-重构] 9 页 → 7 页：原「仪表盘」并入新的「首页」（首页 = 场景卡 + 原仪表盘指标），
-- 原「视觉」「移动」「配置文件」三页并入新的「杂项」（低频设置集中收口）。
-- 为什么这样合：9 个平铺标签在手机竖屏导航里已经要滚，且「视觉/移动/配置」三者都是"设置一次就不再动"的属性，
-- 合并后高频页（钓鱼/Boss/任务/神灵/传送）保持一屏一件事，低频页收进一个抽屉。
local CATEGORY_ORDER = {"首页", "钓鱼", "Boss", "任务", "神灵", "传送", "杂项"}
DashUI.categories = CATEGORY_ORDER
-- 窄屏（手机竖屏导航栏只有 88px 宽）用 1 个汉字代替图标，便于扫视定位
local CATEGORY_META = {
    ["首页"]     = {icon = "⌂"},
    ["钓鱼"]     = {icon = "钓"},
    ["Boss"]     = {icon = "战"},
    ["任务"]     = {icon = "任"},
    ["神灵"]     = {icon = "神"},
    ["传送"]     = {icon = "传"},
    ["杂项"]     = {icon = "杂"},
    -- 以下三项已并入「杂项」，仅保留元数据供 TAB_TO_CAT 别名解析时取图标，不会再出现在导航栏
    ["仪表盘"]   = {icon = "仪"},
    ["视觉"]     = {icon = "视"},
    ["移动"]     = {icon = "移"},
    ["配置文件"] = {icon = "设"},
}
-- [兼容保留] 标签页 -> 分类映射：让 DashUI.resolveCategory / 搜索自动跳页 / CreateTab 三条既有调用约定零改动。
-- 同名恒等映射 + 4 条别名（把已合并的旧页名指向新分类）
local TAB_TO_CAT = {}
for i = 1, #CATEGORY_ORDER do TAB_TO_CAT[CATEGORY_ORDER[i]] = CATEGORY_ORDER[i] end
TAB_TO_CAT["仪表盘"]   = "首页"
TAB_TO_CAT["视觉"]     = "杂项"
TAB_TO_CAT["移动"]     = "杂项"
TAB_TO_CAT["配置文件"] = "杂项"

-- [UI-重构] 导航高度按实际页数反推（原来写死「9 个标签 / 8 个间距」，页数一变就失准）。
-- 目标：所有标签一屏放得下，否则小屏会出现「导航能滚，但滚动条只有 2px、用户不知道下面还有页面」。
-- 计算式：可用 = 窗高 − 顶栏 − 底栏 − 导航标题区(28) − 底部留白(40) − (n-1) 个 5px 间距，再对 n 取整。
-- 下限 34px（触屏最小可点高度），上限保持基准值不放大。
do
    local n = #CATEGORY_ORDER
    if n > 0 then
        local avail = DashUI.metrics.winH - DashUI.metrics.topH - DashUI.metrics.footH - 28 - 40
        local fit = math.floor((avail - (n - 1) * 5) / n)
        if fit < DashUI.metrics.navH then
            DashUI.metrics.navH = math.max(34, fit)
        end
    end
end

local categoryPages = {}
local categoryRefreshers = {}
tabCanvasRefreshers = {}
local navItems = {}
local containerMeta = setmetatable({}, { __mode = "k" })
DashUI.containerMeta = containerMeta
local currentCategory = nil

-- ============================================================================
-- 【滚动画布高度校准 BindVerticalCanvas】手机端不依赖 AutomaticContentSize（对 AutomaticSize 子项经常算矮），改为累加可见子控件真实高度，
-- 彻底解决“滑到一半就到底 / 回弹 / 下面够不到”；仅在子项尺寸或可见性变化时以 0.15s 节流合并重算，隐藏页面不做无效遍历。
-- ============================================================================
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

    -- 累加滚动容器内所有可见子项的真实像素高度并折算为本地 Canvas 高度
    local function measureContentHeight()
        local padY = 0
        local uiPad = (cachedUiPad and cachedUiPad.Parent == scrollFrame) and cachedUiPad or scrollFrame:FindFirstChildOfClass("UIPadding")
        if uiPad then
            cachedUiPad = uiPad
            padY = (uiPad.PaddingTop and uiPad.PaddingTop.Offset or 0)
                + (uiPad.PaddingBottom and uiPad.PaddingBottom.Offset or 0)
        end
        -- UIScale 在祖先上时 AbsoluteSize 是屏幕像素，CanvasSize 需要本地坐标，必须除以 scale
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
                        h = subLayout.AbsoluteContentSize.Y
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

    -- 刷新当前可见滚动容器的 CanvasSize 并修正越界滚动位置
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
    -- 预绑定刷新执行体并跳过不可见标签页：8 个后台隐藏标签页在子控件初始化、批量展开/折叠或搜索过滤时不再分配 task.defer/task.delay 闭包，也不污染 lastRefreshTime。
    local function runScheduledRefresh()
        refreshQueued = false
        lastRefreshTime = tick()
        if isRunning then refreshCanvas() end
    end
    -- 以 0.15s 节流合并触发滚动区域 Canvas 高度重算
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

    -- 弱表按 child 去重存储，对象销毁后条目自动消失
    local childSizeConns = setmetatable({}, { __mode = "k" })
    local function bindChildSignals(child)
        if child and child:IsA("GuiObject") and not childSizeConns[child] then
            for i = #activeConnections, 1, -1 do
                local c = activeConnections[i]
                if not c or not c.Connected then table.remove(activeConnections, i) end
            end
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

-- ============================ 顶栏 ============================
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, UIM.topH)
topBar.BackgroundColor3 = Colors.SidebarBg
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 14)
do -- 顶栏底部直角补块 + 分割线（让圆角只作用在顶部两角）
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

do -- 品牌区：竖条 + FSY + 版本胶囊
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
    -- [UI-重构] 页数不再硬编码：合并/拆分页签后这里会自动跟随，避免再出现「写着 9 页实际 7 页」
    verLabel.Text = FSY_VERSION .. " · " .. tostring(#CATEGORY_ORDER) .. "页"
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

-- 右上角窗口控制按钮：最小化 / 关闭（静态，悬停柔和高亮）
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

-- 顶栏按钮悬停反馈（触屏端不挂 hover，避免无效补间）
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

-- 顶栏整体可拖动
do
    local dragging = false
    local activeDragTouch = nil
    local dragStart = nil
    local startPos = nil
    local titleInputEndConn = nil
    local titleDragChangedConn = nil
    local titleDragEndedConn = nil

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

    -- 结束标题栏拖拽并立即断开临时挂载的全局输入连接
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

-- ============================ 主体 ============================
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

-- 侧栏小标题
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

-- 侧栏底部状态
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
    stText.TextTruncate = Enum.TextTruncate.AtEnd
    stText.Parent = navStatus
    RegisterThemeUpdater(function()
        stText.TextColor3 = Colors.TextMuted
        dot.BackgroundColor3 = Colors.AccentGreen
        stStroke.Color = Colors.BorderSubtle
    end)
end
if UIM.compactNav then
    -- 窄导航栏放不下状态文字：隐藏状态盒，把高度让给分类列表
    navStatus.Visible = false
    navList.Size = UDim2.new(1, 0, 1, -40)
    navList.Position = UDim2.new(0, 0, 0, 28)
    navCaption.Text = "功能"
    navCaption.Position = UDim2.new(0, 0, 0, 8)
    navCaption.Size = UDim2.new(1, 0, 0, 16)
    navCaption.TextXAlignment = Enum.TextXAlignment.Center
end

-- ============================ 内容区 ============================
local contentArea = Instance.new("Frame")
contentArea.Name = "ContentArea"
contentArea.Size = UDim2.new(1, -UIM.navW, 1, 0)
contentArea.Position = UDim2.new(0, UIM.navW, 0, 0)
contentArea.BackgroundTransparency = 1
contentArea.Parent = bodyFrame

-- 顶部搜索框（常驻：加载期一次性建好，运行期只读输入 + 切行 Visible）
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

-- 页面容器起点：细搜索条下面直接就是功能页
local PAGE_TOP = UIM.searchH

-- ============================ 分类页面 ============================
-- 创建单个分类的滚动页容器
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

-- ============================ 左侧导航项 ============================
-- 切换导航选中态（只改颜色/可见性，不重建节点、不新建 Tween）
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

-- 创建单个左侧导航项（纯文字选中胶囊）
--   · 宽屏（PC / 横屏）：单行文字 + 选中竖条，行高 34~40px，9 个标签一屏放得下；窄屏（手机竖屏 88px）：竖排「1 字图标 + 名称」，保证「配置文件」这种 4 字标题不截断
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

    -- 选中态左侧竖条
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

    -- 悬停反馈只在鼠标端做（触屏端靠按压高亮，避免每次切页都跑 Tween）
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

-- ============================ 路由 ============================
-- 切换分类：只切换页面 Visible 与导航高亮，不重建任何节点
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
    -- 有搜索词时，切页后按当前条件重算可见性（仅切 Visible / 展开态）
    if searchState.refresh and searchState.query ~= "" then
        task.delay(0.05, searchState.refresh)
    end
end

-- 把旧标签页内容挂到目标分类下的子区块（返回区块容器，供页面构建代码继续塞分组）
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

-- 供控件工厂反查某个控件所属分类（向上找已登记的子区块容器）
DashUI.resolveCategory = function(obj)
    local node, guard = obj, 0
    -- 回溯上限 16：胶囊把行到 Section 的层数正好顶到第 8 层（Row→Content→Box→Holder→Wrapper→Body→Group→Section），再多一层嵌套就会静默返回错页，连带折叠记忆键与搜索跳页一起错。
    while node and guard < 16 do
        local meta = containerMeta[node]
        if meta then return meta.cat, meta.tab end
        node = node.Parent
        guard = guard + 1
    end
    return currentCategory or CATEGORY_ORDER[1]
end

-- 暴露给搜索框：切到首个命中分类
DashUI.switchCategory = function(catName)
    if SwitchTab then SwitchTab(catName) end
end

-- ============================ 底部状态栏 ============================
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
footerBrand.Size = UDim2.new(0.58, -16, 1, 0)
footerBrand.Position = UDim2.new(0, 14, 0, 0)
footerBrand.BackgroundTransparency = 1
footerBrand.Font = Enum.Font.Gotham
-- 底栏常显当前版本、模式与隔离状态：切换模式后由 ModeCtl.OnChange 回写，不重建节点
footerBrand.Text = string.format("FSY %s · %s · 输入隔离%s", FSY_VERSION, ModeCtl.Label(), Config.InputIsolation and "开" or "关")
footerBrand.TextColor3 = Colors.TextMuted
footerBrand.TextSize = 9
footerBrand.TextXAlignment = Enum.TextXAlignment.Left
footerBrand.TextTruncate = Enum.TextTruncate.AtEnd
footerBrand.Parent = footerBar

local footerKey = Instance.new("TextLabel")
footerKey.Size = UDim2.new(0.42, -16, 1, 0)
footerKey.Position = UDim2.new(0.58, 2, 0, 0)
footerKey.BackgroundTransparency = 1
footerKey.Font = Enum.Font.Gotham
footerKey.Text = ModeCtl.IsMobile() and "触屏 · 右上角 FSY 球收放" or "[R-CTRL] 菜单 · [END] 停止"
footerKey.TextColor3 = Colors.TextMuted
footerKey.TextSize = 9
footerKey.TextXAlignment = Enum.TextXAlignment.Right
footerKey.TextTruncate = Enum.TextTruncate.AtEnd
footerKey.Parent = footerBar
RegisterThemeUpdater(function()
    footerBrand.TextColor3 = Colors.TextMuted
    footerKey.TextColor3 = Colors.TextMuted
end)

-- ============================================================================
-- [UI-STATUS] 底部常驻状态条
-- 原来这里只写「版本 + 模式 + 输入隔离」，全是静态信息；切到任何页签都读不到「现在到底在干什么」。
-- 依据 NN/g 的 operational dashboard 原则：状态条只回答一个问题 ——「我现在要不要动手」。
-- 因此只放 3 项：运行态（钓鱼/搏斗/空闲）、本场鱼获、阻塞原因（优先级最高）。
-- 成本：1s 一次，只在文本真的变化时才写属性（避免每帧触发文本重排）。
-- ============================================================================
local footerStatusCache = nil
function DashUI.RefreshFooterStatus(force)
    if not footerBrand or not footerBrand.Parent then return end
    local fish = 0
    local pData = GetPlayerData()
    if pData then
        fish = tonumber(DashUI._readValueBase(pData:FindFirstChild("FishCaught"), 0)) or 0
    end
    -- 【作用域坑】不能用 attrFishing / attrMinigame：它们是 12588 行的 local，本函数定义在 4165 行（更早），
    -- 在这里会被解析成全局 nil，状态永远显示「空闲」。改用 FishGate（1018 行已前向声明，运行期赋值），
    -- 它本来就是全脚本唯一的状态出口，语义更准（含「闸门关闭」「残留鱼已忽略」等档）。
    local stateText = "空闲"
    if FishGate and type(FishGate.GetStateName) == "function" then
        local okState, sn = pcall(FishGate.GetStateName)
        if okState and type(sn) == "string" and sn ~= "" then stateText = sn end
    end
    -- 级别由 GetRunLevel 统一给出（与悬浮球状态灯同源），这里只用来给文字加前缀符号
    local lv = (DashUI.GetRunLevel and DashUI.GetRunLevel()) or "idle"
    local lvMark = (lv == "err") and "🔴 " or (lv == "warn") and "🟡 " or (lv == "ok") and "🟢 " or "⚪ "
    -- 阻塞原因：与 GetRunLevel 同优先级（失败/异常 > 延后/暂停），避免状态灯为红色时底栏却只显示普通延后条目
    local block, warnBlock = nil, nil
    for k, rec in pairs(DashUI._status) do
        local t = tostring(rec and rec.text or "")
        if t:find("失败", 1, true) or t:find("异常", 1, true) then
            block = tostring(k) .. ":" .. t
            break
        elseif not warnBlock and (t:find("延后", 1, true) or t:find("暂停", 1, true)) then
            warnBlock = tostring(k) .. ":" .. t
        end
    end
    block = block or warnBlock
    local line = string.format("%sFSY %s · %s · %s · %d 条%s",
        lvMark, FSY_VERSION, ModeCtl.Label(), stateText, fish,
        block and (" · " .. block) or (Config.InputIsolation and " · 隔离开" or ""))
    if force or footerStatusCache ~= line then
        footerStatusCache = line
        footerBrand.Text = line
    end
end
ModeCtl.OnChange(function()
    footerKey.Text = ModeCtl.IsMobile() and "触屏 · 右上角 FSY 球收放" or "[R-CTRL] 菜单 · [END] 停止"
    DashUI.RefreshFooterStatus(true)
end)

-- ============================ 展开 / 收起 ============================
local isUiAnimating = false
local uiAnimStartAt = 0
local pendingUiToggle = false
local UI_OPEN_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UI_CLOSE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BALL_POP_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- 动画收尾时统一结算排队中的展开/收起请求
local function ApplyPendingUiToggle()
    if not pendingUiToggle then return end
    pendingUiToggle = false
    if isUiAnimating or not isRunning then return end
    if ToggleUiVisibility then ToggleUiVisibility() end
end

-- 展开主窗口并隐藏 FSY 悬浮球
local function OpenUI()
    if isUiAnimating and (tick() - uiAnimStartAt) > 0.6 then isUiAnimating = false end
    if not isRunning or not mainFrame or isUiAnimating then return end
    isUiAnimating = true
    uiAnimStartAt = tick()
    if screenGui then
        if not screenGui.Enabled then screenGui.Enabled = true end
        screenGui.DisplayOrder = 100
    end
    mainFrame.ZIndex = 3000
    pcall(UpdateMainFrameScale, true)
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
        isUiAnimating = false
        if not isRunning then return end
        if mainFrame and mainFrame.Parent then mainFrame.BackgroundTransparency = 0 end
        if UpdateMainFrameScale then pcall(UpdateMainFrameScale, true) end
        ApplyPendingUiToggle()
    end)
    activeThreads[th] = true
end

-- 最小化主窗口并弹出 FSY 悬浮球
CloseUI = function()
    if isUiAnimating and (tick() - uiAnimStartAt) > 0.6 then isUiAnimating = false end
    if not isRunning or not mainFrame or isUiAnimating then return end
    for fn in pairs(activeSliderCleanupFns) do pcall(fn) end
    table.clear(activeSliderCleanupFns)
    if currentlyOpenDropdown and currentlyOpenDropdown.Close then
        pcall(currentlyOpenDropdown.Close)
        currentlyOpenDropdown = nil
    end
    if DashUI._hideTip then DashUI._hideTip() end
    -- [审计修复 UI-04] 最小化/快捷键收起主窗口时同步关闭退出确认模态遮罩，防止 50% 黑幕残留在屏幕上
    if DashUI._closeUnloadConfirm then pcall(DashUI._closeUnloadConfirm) end
    isUiAnimating = true
    uiAnimStartAt = tick()
    local baseScale = (mainFrameScale and mainFrameScale.Scale) or (Config.UIScale or 0.85)
    if mainFrameScale then PlayQuickTween(mainFrameScale, {Scale = baseScale * 0.94}, UI_CLOSE_TWEEN) end
    PlayQuickTween(mainFrame, {BackgroundTransparency = 0.3}, UI_CLOSE_TWEEN)
    local th
    th = task.delay(0.15, function()
        if th then activeThreads[th] = nil end
        isUiAnimating = false
        if not isRunning then return end
        if mainFrame and mainFrame.Parent then
            mainFrame.Visible = false
            mainFrame.BackgroundTransparency = 0
            if UpdateMainFrameScale then pcall(UpdateMainFrameScale, true) end
        end
        if floatingBall and floatingBall.Parent then
            floatingBall.Visible = true
            PlayQuickTween(floatingBall, {Size = UDim2.new(0, FLOATING_BALL_SIZE, 0, FLOATING_BALL_SIZE)}, BALL_POP_TWEEN)
        end
        ApplyPendingUiToggle()
    end)
    activeThreads[th] = true
end
DashUI._openUI = OpenUI

-- 切换主窗口展开/最小化状态
ToggleUiVisibility = function()
    if isUiAnimating and (tick() - uiAnimStartAt) > 0.6 then isUiAnimating = false end
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

-- 最小化：单击即可（手机/PC 统一走 BindClick，避免双触发）
BindClick(minBtn, ToggleUiVisibility)

-- ============================ 退出确认弹窗（静态常驻） ============================
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
    -- [UI-适配] 高 164 → 176：配合描述区 60px，保证 3 行长文案完整显示且按钮不挤压
    card.Size = UDim2.new(0, 320, 0, 176)
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
    -- [UI-适配] 高度 44 → 60：确认文案加了「背包物品数 / 自定义点数量」后会到 3 行，
    -- 44px 在 TextSize 11 下只容得下约 3.3 行，长句会被裁掉尾巴。按钮组在底部 -50，不会重叠。
    desc.Size = UDim2.new(1, -32, 0, 60)
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

    -- 关闭并隐藏退出确认弹窗（节点常驻复用，不再 Destroy）
    local function CloseUnloadConfirm()
        if confirmOverlay.Visible then confirmOverlay.Visible = false end
        confirmOverlay.Active = false
    end
    DashUI._closeUnloadConfirm = CloseUnloadConfirm
    -- [UI-CONFIRM] 通用确认模态：同一套常驻节点复用，只换文案与确认动作。
    -- 为什么要它：脚本里有若干「一次点击就执行、且不可逆」的按钮（立即出售并传送、清空全部自定义点、卸载脚本），
    -- 手指划过就会触发且无法撤回。这里统一收口到二次确认。
    local pendingConfirmAction = nil
    local function ShowConfirm(titleText, descText, okLabel, onOk)
        if not screenGui or not screenGui.Parent then return false end
        if title then title.Text = tostring(titleText or "确认操作？") end
        if desc then desc.Text = tostring(descText or "") end
        if okBtn then okBtn.Text = tostring(okLabel or "确认") end
        pendingConfirmAction = (type(onOk) == "function") and onOk or nil
        confirmOverlay.Visible = true
        confirmOverlay.Active = true
        return true
    end
    DashUI.Confirm = ShowConfirm
    -- 弹出退出确认模态框，防止手指误触右上角 [X] 直接关闭脚本
    local function ShowUnloadConfirm()
        if confirmOverlay.Visible then return end
        ShowConfirm("确认退出 FSY？", "退出后将停止挂机并恢复游戏设置，可随时重新注入脚本。", "确认退出", UnloadScript)
    end

    BindClick(cancelBtn, function()
        pendingConfirmAction = nil
        CloseUnloadConfirm()
    end)
    BindClick(okBtn, function()
        local fn = pendingConfirmAction
        pendingConfirmAction = nil
        CloseUnloadConfirm()
        if fn then pcall(fn) end
    end)
    -- 点遮罩空白处也视为取消（遵循双端输入隔离）
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
                pendingConfirmAction = nil
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

-- 触屏点击兜底统一走模块 08-B InputRouter（同一物理按下只派发一次、切模式/卸载均正确解绑），此处不保留第二套坐标补发逻辑。

end)() end -- end of Window Shell Scope

-- [前向声明] 以下名字在本行之后才被赋值，但更早的代码（雷达协程 / 卸载分支 / 页面回调）会读取，必须先声明为 chunk 级 local，否则会变成全局变量，卸载或异常分支可能读到 nil。
local SafeTeleport, allRods, TryFavoriteProtectedFish, SafeSellAllFish, TriggerPrompt, EnsureFishingRodEquipped, TeleportToDragonSea
local RunTicketQuestAction, RunGiveFishToMonkeyBatch, GetNPCPosition, FireGuiButton
FSYC.FSYDialogueOpenedAt = 0
local GetNearestIslandInfo, ImportantDialogueNPCs, FourSacredBeastsSpecs, DoesInstanceMatchNPCSpec, TriggerNPCInstancePrompts, IsDialogueUIOpen
local TryStreamAroundPosition, IsMapOrIslandContainer, ResolvePromptEntity, GetInstanceSearchableSummary, GetCachedWorkspacePrompts
local cachedBossPrompts = {}

-- ============================================================================
-- 【模块 13：UI 控件工厂与页面装配】
-- createCollapsibleGroup / createDrawerCapsule 共用 collapsibleSections 接口（搜索命中/全部折叠/全部展开/记忆状态全部通吃）；行工厂（toggle/slider/dropdown/button/info）统一行高、留白与命中区，加载期一次性构建，运行期只改属性。
-- ============================================================================
do (function() -- 分类页面与控件工厂作用域
local UIM = DashUI.metrics

-- [存档容错] UIGroupState 来自配置 JSON：只接受 string -> boolean，其余丢弃；超过 240 条整体清空（折叠记忆可再生，清空无业务影响）。
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

-- 分组 body -> 分组记录（供功能行反查所属分组，用于搜索与统计）
local bodyGroup = setmetatable({}, { __mode = "k" })

-- 从任意控件向上回溯，找到所属折叠分组记录
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

-- 折叠状态写盘（1.2s 合并一次，避免连续点击触发多次文件写入）
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

-- 请求刷新当前分类页的滚动高度（折叠 / 下拉 / 行显隐变化后调用）
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

-- 【胶囊折叠分组】标题栏 + 内容卡片一体式，点击标题整行切换展开/收起
-- 状态写入 Config.UIGroupState（键：分类|分组名）；用瞬时显隐而非高度补间，省掉每帧重排与 Canvas 重算；记录登记到 collapsibleSections 供搜索/全部展开折叠使用。
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

    -- 标题栏（整行可点，含箭头 + 展开时左侧竖条）
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

    -- 内容区：展开时自动撑高，收起时整体隐藏（0 布局开销）
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
    -- 应用展开/收起状态：instant 显隐，无高度补间
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

    -- 记录到全局分组表（倒序处理时先子后父，搜索过滤依赖顺序）
    rec = {
        section = card,
        header = header,
        body = body,
        title = grpTitle,
        key = key,
        cat = cat,
        initialExpanded = expanded,
        GetExpanded = function() return expanded end,
        -- 第三个参数 true 表示「搜索自动展开」，不写盘也不改变用户记忆状态
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

    -- 点击标题：同时收起其它展开中的下拉，避免遮挡
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

-- 【抽屉胶囊 createDrawerCapsule】一行「标题 + 说明 + 展开/收起」，点一下才展开下方内容卡片，默认收起
-- 收纳参数多但平时不动的细项（技能轮换、两套预设配装、闸门诊断）；与折叠分组共用 collapsibleSections 接口，搜索/全折叠/全展开/记忆状态同样生效；节点加载期一次性建好，运行期只切 Visible/Rotation。
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

    -- 触发行（整行可点，触屏 56px / 鼠标 44px）
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

    -- 右侧「展开 / 收起」指示胶囊
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

    -- 抽屉内容：浅底卡片 + 左侧引导线
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

    -- [高度不动点] guide 用 Scale 高度（1,-10），靠 boxPad.PaddingTop(4)+偏移(5)=9 撑出 1px 余量：
    -- 只有「上下 padding 之和 > guide 的 Y 偏移」时 guide 才不参与撑高、AutomaticSize 链才收敛；调 padding 前务必先算这条，否则展开后高度会一帧一帧往上长。
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
    -- 应用展开/收起：瞬时显隐（和折叠分组一致），不做高度补间，手机上更跟手
    local function applyExpanded(want, persist, animate)
        expanded = (want ~= false)
        holder.Visible = expanded
        holder.AutomaticSize = expanded and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
        holder.Size = UDim2.new(1, 0, 0, 0)
        arrow.Rotation = expanded and 90 or 0
        -- 箭头颜色必须跟着展开态走，否则展开后箭头仍是灰色，看不出「点这里能收起」
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

    -- 与 createCollapsibleGroup 完全同构的记录，搜索 / 全部折叠 / 全部展开直接复用
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

-- 【功能行底板】统一圆角行底 + 主标题（放大加粗）+ 副标题（小字描述）+ 搜索登记
-- 登记一行到搜索索引（hay 同时包含标题、描述、分类、分组名，支持模糊定位）
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

-- 创建通用功能行底板（返回行容器；titleLabel 供搜索高亮使用）
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

    -- 行底分割线（低对比，形成整齐列表）
    local divider = Instance.new("Frame")
    divider.Name = "Divider"
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.Position = UDim2.new(0, 12, 1, -1)
    divider.BackgroundColor3 = Colors.Divider
    divider.BackgroundTransparency = 0.45
    divider.BorderSizePixel = 0
    divider.Parent = row

    local recRow = registerSearchRow(row, titleLabel, nil, labelText, descText)

    -- 悬停柔和高亮（仅鼠标端）
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

    -- 触屏按压反馈：按住整行轻微提亮，松手复位（不改变业务行为）
    -- 连接常驻、运行期按模式判定：若改回加载期 if UIM.touch 决定是否连接，切到手机模式后按压反馈会缺失
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

    -- 鼠标悬浮 / 触屏长按显示中文说明
    DashUI.attachTip(row, descText)

    return row, titleLabel
end

-- 【开关行】右侧大命中区开关（触屏 54x30，鼠标 46x26），拨动 0.1s 轻过渡
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

    -- 根据当前状态刷新开关外观
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
        -- [UI-DEP] 开关变化后立即重算依赖项显隐（只改 Visible + 重算画布，不重建节点）
        if DashUI.ApplyUIDeps then DashUI.ApplyUIDeps() end
    end)

    -- 按压反馈：整块命中区轻微提亮
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
            -- [UI-DEP] 程序化改写（联动开关、配置同步、读档回填）同样要重算依赖
            if DashUI.ApplyUIDeps then DashUI.ApplyUIDeps() end
        end,
        Get = function() return state end,
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

-- 【滑块行】加大拖拽热区与圆点，按下才挂 UIS 连接，松手/切页立即释放并恢复外层滚动
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
    valLabel.TextTruncate = Enum.TextTruncate.AtEnd
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

    -- 根据当前数值更新滑块填充条宽度、圆点位置与右侧数值文本
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

    -- 向上查找滑块所属的 ScrollingFrame（带深度上限），拖动时临时锁滚
    local function findScrollFrame()
        local p, guard = row, 0
        while p and not p:IsA("ScrollingFrame") and guard < 16 do
            p = p.Parent
            guard = guard + 1
        end
        return (p and p:IsA("ScrollingFrame")) and p or nil
    end

    -- 结束滑动并恢复外层滚动
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

    -- 根据手指或鼠标的屏幕 X 坐标计算滑块数值并触发回调
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
                if endedInput == activeTouch
                    or endedInput.UserInputType == Enum.UserInputType.Touch
                    or endedInput.UserInputType == Enum.UserInputType.MouseButton1 then
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

-- 【下拉行】静态选项池（加载期一次性建好），运行期只改文本/颜色/Visible
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

    -- 静态选项池：运行期只改文本与配色，绝不 Destroy + Instance.new
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
        ob.TextTruncate = Enum.TextTruncate.AtEnd
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
        -- 按钮复用：点击读取当前绑定在它身上的选项名
        BindClick(ob, function()
            local opt = btnOptName[ob]
            if opt == nil then return end
            selected = opt
            ddBtn.Text = tostring(opt)
            optWrap.Visible = false
            caret.Text = "▾" -- [V15.3 BUG-05] 选中选项收起下拉框时同步复位箭头指示符
            if currentlyOpenDropdown and currentlyOpenDropdown.optC == optWrap then currentlyOpenDropdown = nil end
            renderAllOptions()
            refreshCurrentCanvas()
            if type(callback) == "function" then callback(opt) end
            if DashUI.ApplyUIDeps then DashUI.ApplyUIDeps() end
        end)
    end

    -- 把选项列表写入静态池（超出池容量时截断显示并记录日志，不影响配置读写）
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
            caret.Text = "▾" -- [V15.3 BUG-05] 被其它控件联动收起时同步复位箭头指示符
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
    -- 触摸高亮作用于不透明的 row（header 背景透明），且遵守手机模式与搜索高亮状态守卫
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
            if DashUI.ApplyUIDeps then DashUI.ApplyUIDeps() end
        end,
        Get = function() return selected end,
        Refresh = function(newOpts, silent)
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
                    -- [审计-16] 被动刷新（如"扫描背包"重建候选）不应触发业务回调：否则会静默改写 Config.FavouriteFishName
                    -- 并把 merged[1] 加进保护鱼名单，用户没有做任何选择。silent=true 时跳过回调。
                    if not silent and type(callback) == "function" then callback(selected) end
                else
                    ddBtn.Text = tostring(selected)
                end
                if DashUI.ApplyUIDeps then DashUI.ApplyUIDeps() end
            end
        end,
    }
    if configKey then UIControls[configKey] = ctrl end
    return ctrl
end

-- 【操作按钮行】右侧主题色按钮（触屏 108x38，鼠标 92x30），点击有轻微按压反馈
-- style 可选：nil = 普通执行按钮（实心主题色）；"danger" = 不可逆危险动作（暗底 + 红描边 + 红字）
-- 依据 NN/g「配置 vs 执行」三差原则：形状（实心 vs 描边）、色彩（只有主按钮用高饱和）必须能一眼分开，
-- 否则「点一下 AutoSell 开关」和「点一下 立即出售」在手感上是同一件事，代价却完全不同。
local function createButtonRow(parent, labelText, descText, btnText, callback, style)
    if type(descText) == "function" then
        callback = descText; btnText = "执行"; descText = ""
    elseif type(btnText) == "function" then
        callback = btnText; btnText = descText; descText = ""
    end
    local isDanger = (style == "danger")
    local row = createBaseRow(parent, labelText, descText, UIM.btnW + 18)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, UIM.btnW, 0, UIM.btnH)
    btn.Position = UDim2.new(1, -UIM.btnW - 6, 0.5, -UIM.btnH / 2)
    btn.BackgroundColor3 = isDanger and Color3.fromRGB(46, 26, 28) or Colors.Accent
    btn.Font = Enum.Font.GothamBold
    btn.Text = btnText or "执行"
    btn.TextColor3 = isDanger and Colors.AccentRed or Colors.AccentDeep
    btn.TextSize = 11
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    if isDanger then
        local dStroke = Instance.new("UIStroke", btn)
        dStroke.Color = Colors.AccentRed
        dStroke.Thickness = 1
        dStroke.Transparency = 0.45
    end

    local function restore()
        if isDanger then
            btn.BackgroundColor3 = Color3.fromRGB(46, 26, 28)
            btn.TextColor3 = Colors.AccentRed
        else
            btn.BackgroundColor3 = Colors.Accent
            btn.TextColor3 = Colors.AccentDeep
        end
    end
    RegisterThemeUpdater(restore)
    btn.MouseEnter:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = isDanger and Color3.fromRGB(70, 34, 38) or Colors.AccentSoft })
    end)
    btn.MouseLeave:Connect(function()
        if UIM.touch then return end
        PlayQuickTween(btn, { BackgroundColor3 = isDanger and Color3.fromRGB(46, 26, 28) or Colors.Accent,
            TextColor3 = isDanger and Colors.AccentRed or Colors.AccentDeep })
    end)
    -- 按压反馈：按下加深、松手复位（鼠标与触屏一致；危险按钮保持深红警告色系）
    btn.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
            and ModeCtl.Accepts(input.UserInputType) then
            if isDanger then
                btn.BackgroundColor3 = Color3.fromRGB(82, 36, 40)
                btn.TextColor3 = Colors.AccentRed
            else
                btn.BackgroundColor3 = Colors.AccentDeep
                btn.TextColor3 = Colors.AccentSoft
            end
        end
    end)
    btn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            restore()
        end
    end)
    BindClick(btn, function()
        -- 不做内层静默 pcall，交由 BindClick 统一 pcall + FLogErr 记录异常
        if type(callback) == "function" then callback() end
    end)
    return btn
end

-- 【只读信息行】右侧数值文本
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
    -- [Delta 减负 M5] 文本脏检查：仪表盘与观测台每秒约 12 次刷新同一批指标；值未变时跳过跨 C 属性写入与 UI 文本重排。
    return {
        frame = row,
        Set = function(nv)
            local text = tostring(nv)
            if valueLabel.Text ~= text then valueLabel.Text = text end
        end,
    }
end

-- ============================================================================
-- [UI-DEP] 依赖显隐：父开关关闭时，它的参数行 / 细项分组整块隐藏（不是置灰）
-- 为什么：钓鱼页 20+ 个控件同屏时找不到重点；隐藏后首屏只留当前真正生效的项。
-- 实现约束（改这里前先看清）：
--   ① 只改 Visible，不销毁任何节点 —— 静态预建、运行期零 Instance.new/Destroy 的原则不变；
--   ② 任何一次显隐变化后必须调 refreshCanvas()，否则 ScrollingFrame 画布高度不更新，
--      表现就是「展开后滚不到底 / 滑不动」。这是这类改动的头号坑。
--   ③ 注册表是纯数组，运行期只遍历不增删；与搜索过滤改的是同一批 Visible，谁后写谁生效。
-- ============================================================================
local uiDepList = {}
-- 向上找不超过 5 层、按名字匹配 "Capsule_*" 的容器（胶囊折叠组的外壳）
-- 实测层级：CapsuleContent → CapsuleBox → CapsuleHolder → Capsule_<标题>，留 2 层余量防以后加壳
local function FindCapsuleRoot(content)
    local n = content
    for _ = 1, 5 do
        if not n or not n.Parent then return nil end
        n = n.Parent
        if type(n.Name) == "string" and n.Name:match("^Capsule_") then return n end
    end
    return nil
end
-- 登记一个「依赖某组开关才显示」的节点
--   deps   ：元素可为 Config 键（要求为 true）或 function() -> boolean（用于非布尔判断）
--   anyMode：true = 命中任意一个就显示；false/nil = 全部满足才显示
function DashUI.BindUIParent(frame, deps, anyMode)
    if typeof(frame) ~= "Instance" or type(deps) ~= "table" or #deps == 0 then return nil end
    uiDepList[#uiDepList + 1] = { frame = frame, deps = deps, any = (anyMode == true) }
    return frame
end
-- 单条依赖是否满足：deps 里的元素既可以是 Config 键（要求 == true），也可以是一个返回布尔的函数
-- （用于「雷达总开关 ≠ 关」这类非布尔判断）
local function UIDepSatisfied(d)
    if type(d) == "function" then
        local ok, v = pcall(d)
        return ok and (v == true)
    end
    return Config[d] == true
end
-- 按当前 Config 重新计算所有依赖节点的可见性；有变化才重算画布（无关配置不动）
DashUI._clearUIDeps = function()
    table.clear(uiDepList)
end
function DashUI.ApplyUIDeps()
    if not isRunning or DashUI._batchSyncing then return false end
    if DashUI.RefreshHomeScenes then pcall(DashUI.RefreshHomeScenes) end
    local hasSearch = (searchState and type(searchState.query) == "string" and searchState.query ~= "")
    local changed = false
    for i = 1, #uiDepList do
        local rec = uiDepList[i]
        local f = rec.frame
        if f and f.Parent then
            local show
            if rec.any then
                show = false
                for j = 1, #rec.deps do
                    if UIDepSatisfied(rec.deps[j]) then show = true; break end
                end
            else
                show = true
                for j = 1, #rec.deps do
                    if not UIDepSatisfied(rec.deps[j]) then show = false; break end
                end
            end
            rec.depVisible = show
            -- 搜索激活期间不强行把搜索未命中的行改回 Visible=true，交由下方搜索过滤统一收口
            if not (hasSearch and show) and f.Visible ~= show then
                f.Visible = show
                changed = true
            end
        end
    end
    if hasSearch and not searchState.applying and searchState.refresh then
        searchState.refresh()
    elseif changed and DashUI.refreshCanvas then
        DashUI.refreshCanvas()
    end
    return changed
end

-- [UI-重构] CreateTab 每次调用都会新建一个 Section 容器并挂到同名分类页下，
-- 所以「多个 tab 变量指向同一个分类」= 把多页内容自然合并到一页，不需要改工厂，也不需要搬动任何控件。
local tabDashboard = CreateTab("首页")     -- 原仪表盘指标 → 首页
local tabFishing   = CreateTab("钓鱼")
local tabBoss      = CreateTab("Boss")
local tabQuests    = CreateTab("任务")
local tabGod       = CreateTab("神灵")
local tabTeleports = CreateTab("传送")
local tabVisuals   = CreateTab("视觉")     -- 视觉 → 杂项（TAB_TO_CAT 自动路由到「杂项」页并保留独立 Section 名）
local tabPlayer    = CreateTab("移动")     -- 移动 → 杂项
local tabProfiles  = CreateTab("配置文件") -- 配置文件 → 杂项

SwitchTab("首页")

-- 运行概览（仪表盘）卡片：加载期静态构建，运行期只改数值文本
do
    local dashLayout = tabDashboard:FindFirstChildOfClass("UIListLayout")
    if dashLayout then
        dashLayout.Padding = UDim.new(0, 10)
        dashLayout.SortOrder = Enum.SortOrder.LayoutOrder
    end

    -- 小标题：运行概览指标排在首页场景卡下方（LayoutOrder >= 10，保证「现在做什么」6 张场景卡在首页第一屏）
    local dashTitle = Instance.new("TextLabel")
    dashTitle.LayoutOrder = 10
    dashTitle.Size = UDim2.new(1, 0, 0, 20)
    dashTitle.BackgroundTransparency = 1
    dashTitle.Font = Enum.Font.GothamBold
    dashTitle.Text = "实时运行概览"
    dashTitle.TextColor3 = Colors.TextWhite
    dashTitle.TextSize = 12
    dashTitle.TextXAlignment = Enum.TextXAlignment.Left
    dashTitle.TextTruncate = Enum.TextTruncate.AtEnd
    dashTitle.Parent = tabDashboard
    RegisterThemeUpdater(function()
        dashTitle.TextColor3 = Colors.TextWhite
    end)

    local dashRowOrder = 10
    -- 创建一行三列卡片容器
    local function CreateDashRow()
        dashRowOrder = dashRowOrder + 1
        local row = Instance.new("Frame")
        row.LayoutOrder = dashRowOrder
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

    -- 创建单个统计卡片，返回数值 TextLabel
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


-- ============================================================================
-- [UI-重构 / 场景卡] 首页首屏：把「要开哪一堆开关」收敛成 6 个场景按钮
-- 设计依据：NN/g 渐进披露 —— 首屏只给少数最重要的决策点。147 个控件 → 6 个决策。
-- 硬约束遵守：
--   ① 全部静态预建（本 do 块在加载期一次性建完），运行期只改 BackgroundColor3 / Visible / Text，零新增实例；
--   ② 点卡片 = 批量写 Config + 通过 UIControls[k].Set(v, true) 同步已有控件外观（silent，不重复触发业务回调）；
--   ③ 每个卡片自身是既有 Button，点击统一走 BindClick → InputRouter（自动登记 + pcall 兜底），不另起连接。
-- ============================================================================
do
    -- 场景定义：on = 要打开的开关；off = 一键全关
    -- 每一项是 {Config键, 目标值}，目标值可以是 boolean 或字符串（如雷达三态）
    local SCENE_DEFS = {
        { id = "fish",  icon = "🎣", name = "挂机钓鱼", desc = "抛竿 · 猛击 · 充能 · 卖鱼 · 锁鱼防卖 · 防挂机",
          on = { {"AutoCast", true}, {"AutoSell", true}, {"AutoFavouriteFish", true},
                 {"AutoSlam", true}, {"AutoCharge", true}, {"AntiAFK", true}, {"PositionLock", true} } },
        { id = "boss",  icon = "⚔️", name = "打 Boss", desc = "自动技能 Z/X/C/V · 小游戏节奏 · 二阶段读条",
          on = { {"AutoSkills", true}, {"SkillZ", true}, {"SkillX", true}, {"SkillC", true},
                 {"SkillV", true}, {"OctoAutoMinigame", true} } },
        { id = "radar", icon = "📡", name = "找商人神灵", desc = "雷达全开 · 神灵/道士/茅山/傻子 ESP",
          on = { {"RadarMode", "全开"}, {"ESP_GodSpirit", true}, {"ESP_Maoshan", true},
                 {"ESP_Taoist", true}, {"ESP_DumbGuy", true} } },
        { id = "quest", icon = "📜", name = "做任务", desc = "票据任务 · 喂猴交鱼 · 每日签到",
          on = { {"AutoTicketQuest", true}, {"AutoGiveMonkey", true}, {"AutoClaimDaily", true} } },
        { id = "eco",   icon = "🔋", name = "省电挂机", desc = "关 3D 渲染 · 雷达静默 · 只保留钓鱼",
          on = { {"Disable3DRendering", true}, {"RadarMode", "静默"}, {"AutoCast", true}, {"AntiAFK", true} } },
        { id = "stop",  icon = "⏹",  name = "全部停止", desc = "关掉全部自动化（保留界面与雷达设置）", off = true },
    }

    -- 一键全关时统一清掉的开关（覆盖上面所有场景用到的布尔项）
    local ALL_OFF_KEYS = {
        "AutoCast", "AutoSell", "AutoFavouriteFish", "AutoSlam", "AutoCharge", "AntiAFK", "PositionLock",
        "AutoSkills", "SkillZ", "SkillX", "SkillC", "SkillV", "OctoAutoMinigame",
        "ESP_GodSpirit", "ESP_Maoshan", "ESP_Taoist", "ESP_DumbGuy",
        "AutoTicketQuest", "AutoGiveMonkey", "AutoClaimDaily", "Disable3DRendering",
    }

    -- 统一写入：先写 Config 并静默同步控件外观，再一次性补齐关键业务副作用（3D渲染黑屏、坐标锁、抛竿HUD恢复、雷达/ESP与卖鱼计时器）
    local function WriteConfigPairs(pairsList)
        local prevAutoCast = (Config.AutoCast == true)
        local prevPosLock = (Config.PositionLock == true)
        local prevDis3D = (Config.Disable3DRendering == true)
        local prevRadar = Config.RadarMode
        local prevSell = (Config.AutoSell == true)
        local prevFav = (Config.AutoFavouriteFish == true)
        local prevSkills = (Config.AutoSkills == true)
        local espTouched = false

        DashUI._batchSyncing = true
        for i = 1, #pairsList do
            local kv = pairsList[i]
            local k, v = kv[1], kv[2]
            Config[k] = v
            if type(k) == "string" and k:sub(1, 4) == "ESP_" then
                espTouched = true
            end
            local ctrl = UIControls and UIControls[k]
            if ctrl and type(ctrl.Set) == "function" then pcall(ctrl.Set, v, true) end
        end
        DashUI._batchSyncing = false

        -- 1) 同步 3D 渲染开关与省电黑屏遮罩
        local nowDis3D = (Config.Disable3DRendering == true)
        if nowDis3D ~= prevDis3D and blackOutFrame then
            blackOutFrame.Visible = nowDis3D
            pcall(function() RunService:Set3dRenderingEnabled(not nowDis3D) end)
        end
        -- 2) 同步坐标锁定基准点（开启时捕获当前位置，关闭时清空旧坐标防跨岛瞬移回拉）
        local nowPosLock = (Config.PositionLock == true)
        if nowPosLock ~= prevPosLock then
            if nowPosLock then
                local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if root then lockedCFrame = root.CFrame end
            else
                lockedCFrame = nil
            end
        end
        -- 3) 自动抛竿由开转关时，恢复抛竿状态机与原生钓鱼按钮 HUD
        if prevAutoCast and not Config.AutoCast then
            if DashUI._onAutoCastDisabled then pcall(DashUI._onAutoCastDisabled) end
            if RestoreNativeGameHud then pcall(RestoreNativeGameHud) end
            if RestoreMobileFishingButtonUI then
                pcall(RestoreMobileFishingButtonUI, true)
                task.delay(0.35, function()
                    if isRunning and not Config.AutoCast and RestoreMobileFishingButtonUI then
                        pcall(RestoreMobileFishingButtonUI, false)
                    end
                end)
            end
        end
        -- 4) 自动卖鱼/自动收藏开启时重置卖鱼计时器并立即扫描一次保护鱼上锁
        if Config.AutoSell and not prevSell and DashUI._resetSellTimer then
            pcall(DashUI._resetSellTimer)
        end
        if (Config.AutoFavouriteFish and not prevFav) or (Config.AutoSell and not prevSell) then
            if TryFavoriteProtectedFish then pcall(TryFavoriteProtectedFish, GetPlayerData(), false) end
        end
        -- 5) 自动技能状态切换时重置技能起手序号
        if (Config.AutoSkills == true) ~= prevSkills then
            currentSkillIndex = 1
        end
        -- 6) 雷达模式或 ESP 开关变化时立即同步雷达与场景高亮
        if Config.RadarMode ~= prevRadar and DashUI._radarApplyMode then
            pcall(DashUI._radarApplyMode, Config.RadarMode)
        elseif espTouched and DashUI._refreshESPNow then
            pcall(DashUI._refreshESPNow)
        end
    end

    local function SceneIsOn(def)
        if def.off or not def.on then return false end
        for i = 1, #def.on do
            local kv = def.on[i]
            if Config[kv[1]] ~= kv[2] then return false end
        end
        return true
    end

    local sceneCards = {}

    local function ApplyScene(def)
        if def.off then
            local offPairs = {}
            for i = 1, #ALL_OFF_KEYS do offPairs[i] = { ALL_OFF_KEYS[i], false } end
            WriteConfigPairs(offPairs)
            ShowNotification("场景", "已关闭全部自动化（雷达与界面设置保持不变）", "WARN", 4)
        elseif SceneIsOn(def) then
            -- 已经全开 → 再点一次等于关掉本场景（避免只能开不能关）。
            -- 布尔项置 false；字符串项（如 RadarMode）保持原值不动，避免把"雷达=静默"意外改成"全开"
            -- 【Lua 陷阱】这里绝不能写 (type(v)=="boolean") and false or v ——
            -- 条件为真时表达式求值为 false or v = v，会把布尔项原样写回 true，等于「点两次都没关掉」。
            -- 必须用显式分支。
            local offPairs = {}
            for i = 1, #def.on do
                local k, v = def.on[i][1], def.on[i][2]
                local nv = v
                if type(v) == "boolean" then nv = false end
                offPairs[i] = { k, nv }
            end
            WriteConfigPairs(offPairs)
            ShowNotification("场景", "已关闭「" .. def.name .. "」", "INFO", 3)
        else
            WriteConfigPairs(def.on)
            ShowNotification("场景", "已启用「" .. def.name .. "」", "SUCCESS", 4)
        end
        if DashUI.ApplyUIDeps then pcall(DashUI.ApplyUIDeps) end
        if DashUI.RefreshFooterStatus then pcall(DashUI.RefreshFooterStatus, true) end
        if DashUI.RefreshHomeScenes then pcall(DashUI.RefreshHomeScenes) end
    end

    -- 小标题（LayoutOrder = 1，固定在「首页」最顶部第一屏）
    local sceneTitle = Instance.new("TextLabel")
    sceneTitle.LayoutOrder = 1
    sceneTitle.Size = UDim2.new(1, 0, 0, 20)
    sceneTitle.BackgroundTransparency = 1
    sceneTitle.Font = Enum.Font.GothamBold
    sceneTitle.Text = "现在做什么"
    sceneTitle.TextColor3 = Colors.TextWhite
    sceneTitle.TextSize = 12
    sceneTitle.TextXAlignment = Enum.TextXAlignment.Left
    sceneTitle.TextTruncate = Enum.TextTruncate.AtEnd
    sceneTitle.Parent = tabDashboard
    RegisterThemeUpdater(function()
        sceneTitle.TextColor3 = Colors.TextWhite
    end)

    -- 2 列 × 3 行卡片（LayoutOrder = 2..4，排在实时运行概览上方）
    local perRow, rowFrames = 2, {}
    for i = 1, math.ceil(#SCENE_DEFS / perRow) do
        local row = Instance.new("Frame")
        row.LayoutOrder = i + 1
        row.Size = UDim2.new(1, 0, 0, 98)
        row.BackgroundTransparency = 1
        row.Parent = tabDashboard
        local rl = Instance.new("UIListLayout")
        rl.FillDirection = Enum.FillDirection.Horizontal
        rl.SortOrder = Enum.SortOrder.LayoutOrder
        rl.Padding = UDim.new(0, 8)
        rl.Parent = row
        rowFrames[i] = row
    end

    for idx = 1, #SCENE_DEFS do
        local def = SCENE_DEFS[idx]
        local parentRow = rowFrames[math.ceil(idx / perRow)]

        local card = Instance.new("TextButton")
        card.Name = "Scene_" .. def.id
        card.Size = UDim2.new(0.5, -4, 1, 0)
        card.BackgroundColor3 = Colors.Card
        card.BorderSizePixel = 0
        card.Text = ""
        card.AutoButtonColor = false
        card.Parent = parentRow
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
        local cardStroke = Instance.new("UIStroke", card)
        cardStroke.Color = Colors.BorderSubtle
        cardStroke.Thickness = 1
        cardStroke.Transparency = 0.3

        local icon = Instance.new("TextLabel")
        icon.Size = UDim2.new(0, 20, 0, 20)
        icon.Position = UDim2.new(0, 10, 0, 9)
        icon.BackgroundTransparency = 1
        icon.Font = Enum.Font.GothamBold
        icon.Text = def.icon
        icon.TextSize = 16
        icon.TextXAlignment = Enum.TextXAlignment.Left
        icon.Parent = card

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size = UDim2.new(1, -46, 0, 18)
        nameLbl.Position = UDim2.new(0, 34, 0, 10)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamBold
        nameLbl.Text = def.name
        nameLbl.TextColor3 = Colors.TextWhite
        nameLbl.TextSize = 12
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Parent = card

        local dot = Instance.new("Frame")
        dot.Size = UDim2.new(0, 8, 0, 8)
        dot.Position = UDim2.new(1, -16, 0, 13)
        dot.BackgroundColor3 = Colors.TextMuted
        dot.BorderSizePixel = 0
        dot.Parent = card
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

        local descLbl = Instance.new("TextLabel")
        descLbl.Size = UDim2.new(1, -20, 0, 52)
        descLbl.Position = UDim2.new(0, 10, 0, 34)
        descLbl.BackgroundTransparency = 1
        descLbl.Font = Enum.Font.Gotham
        descLbl.Text = def.desc
        descLbl.TextColor3 = Colors.TextMuted
        descLbl.TextSize = 9
        descLbl.TextXAlignment = Enum.TextXAlignment.Left
        descLbl.TextYAlignment = Enum.TextYAlignment.Top
        descLbl.TextWrapped = true
        descLbl.Parent = card

        sceneCards[idx] = { def = def, card = card, stroke = cardStroke, dot = dot }

        -- 点击：走 BindClick（InputRouter 统一登记 + Dispatch 内 pcall 兜底）
        BindClick(card, function() ApplyScene(def) end)

        -- 悬停与触屏/鼠标按压反馈（遵守双端输入隔离 ModeCtl.Accepts）
        card.MouseEnter:Connect(function()
            if UIM and UIM.touch then return end
            card.BackgroundColor3 = Colors.RowHover
        end)
        card.MouseLeave:Connect(function()
            if UIM and UIM.touch then return end
            card.BackgroundColor3 = Colors.Card
        end)
        card.InputBegan:Connect(function(input)
            if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
                and ModeCtl.Accepts(input.UserInputType) then
                card.BackgroundColor3 = Colors.RowHover
            end
        end)
        card.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                card.BackgroundColor3 = Colors.Card
            end
        end)

        RegisterThemeUpdater(function()
            card.BackgroundColor3 = Colors.Card
            cardStroke.Color = Colors.BorderSubtle
            nameLbl.TextColor3 = Colors.TextWhite
            descLbl.TextColor3 = Colors.TextMuted
        end)
    end

    DashUI._clearHomeScenes = function()
        table.clear(sceneCards)
    end

    -- 状态点刷新：全部满足=绿、部分满足=黄、全关=灰（与底栏/悬浮球同一套语义）
    function DashUI.RefreshHomeScenes()
        if not sceneCards then return end
        for i = 1, #sceneCards do
            local rec = sceneCards[i]
            if rec and rec.dot and rec.dot.Parent then
                local col = Colors.TextMuted
                if not rec.def.off then
                    local total, hit = #rec.def.on, 0
                    for j = 1, total do
                        local kv = rec.def.on[j]
                        if Config[kv[1]] == kv[2] then hit = hit + 1 end
                    end
                    if hit == total then col = Colors.AccentGreen
                    elseif hit > 0 then col = Colors.AccentYellow end
                end
                if rec.dot.BackgroundColor3 ~= col then rec.dot.BackgroundColor3 = col end
            end
        end
    end
    pcall(DashUI.RefreshHomeScenes)
    -- 场景卡是「SwitchTab(首页) 之后」才建的，首帧画布高度可能没把它们算进去（表现为滑不到底）。
    -- 这里显式重算一次；BindVerticalCanvas 自带的 0.1s / 0.35s 延迟刷新再兜一层。
    if DashUI.refreshCanvas then pcall(DashUI.refreshCanvas) end
end

-- 【业务函数：SafeTeleport】跨岛传送 + 防下坠锚定（传送 / NPC 导航 / Boss 前往共用入口）
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
        FSYC.lastManualTpAt = tick()
        if TryStreamAroundPosition then
            pcall(TryStreamAroundPosition, targetPos)
        end
        DashUI._ensureHumanoidUpright(hum)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.CFrame = uprightCF

        if Config.PositionLock then lockedCFrame = uprightCF end
        if isFarTeleport then
            -- 跨岛远距离传送防下坠保护：短暂锚定 0.12 秒等待流式碰撞网格就绪，且防止微瞬移或连点传送期间误改锁定坐标
            pcall(function()
                local myTpToken = (FSYC.tpAnchorToken or 0) + 1
                FSYC.tpAnchorToken = myTpToken
                root.Anchored = true
                task.delay(0.12, function()
                    if root and root.Parent then
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                        if FSYC.tpAnchorToken == myTpToken or not isRunning then
                            root.Anchored = false
                        end
                        if isRunning and FSYC.tpAnchorToken == myTpToken then
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

-- ============================================================================
-- 【模块 14：【钓鱼】页面构建（全鱼竿属性库、核心钓鱼自动化、技能轮换、智能配装方案）】
-- 新增鱼竿/鱼饵时在 allRods 或 baitNameList 补充对应英文原名；本模块构建自动抛竿、位置锁定、锚定条、秒钓、Z/X/C/V 技能顺序与双配装方案 UI。
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
-- [FEAT-OBS] 只读观测行：数据源为抓包确认的下行事件 ReplicateFishCaught / RenderSkillToClients，纯统计零发包、加载期静态创建（实现在模块 30）。
DashUI.infoFishLive = createInfoRow(statsCard, "本局鱼获(实时)", "—")
DashUI.infoSkillCD = createInfoRow(statsCard, "技能实测CD", "采集中…")

local fishCard = createCollapsibleGroup(tabFishing, "核心钓鱼自动化")
createToggleRow(fishCard, "自动抛竿", "自动开始钓鱼并抛竿（举起鱼或收起鱼竿时自动暂停，关闭时自动恢复钓鱼按键）", Config.AutoCast, function(v)
    Config.AutoCast = v
    if not v then
        if DashUI._onAutoCastDisabled then pcall(DashUI._onAutoCastDisabled) end
        -- [FIX-BTN] 一次性、无条件的原生 HUD 对称还原：不能依赖 holdingRod / cachedAutoFishBtn.Visible，
        -- 这两个信号在「取消钓鱼 + 关自动抛竿」后必然同时为假，会导致 RestoreMobileFishingButtonUI 根本不会被调用。
        pcall(RestoreNativeGameHud)
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
local uiRowCastDelay = createSliderRow(fishCard, "抛竿延迟", "检测/抛竿频率", 0.1, 10.0, Config.CastDelay, true, "秒", function(v) Config.CastDelay = v end, "CastDelay")
-- [UI-DEP] 只在「自动抛竿」开启时需要调这个值
DashUI.BindUIParent(uiRowCastDelay and uiRowCastDelay.frame, {"AutoCast"})

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

-- [模块 22-B] 自动发包状态闸门：总开关 + 一键自检（两条都是静态预建行，运行期不新建任何 UI 节点）
createToggleRow(fishCard, "仅在钓鱼时自动（防空转发包）", "开启：只有确认在钓鱼/搏斗中，才放技能、打猛击、蓄力、发进度包；站着不动时完全不发包。关闭：退回旧行为（可能出现空闲也持续发包）", Config.FishingGate, function(v)
    Config.FishingGate = v
    -- 开关状态影响所有战斗域发包，切换时把节拍与技能引擎一起复位，避免残留节拍跨状态沿用
    if DashUI and DashUI._resetFishTimers then pcall(DashUI._resetFishTimers) end
    if not v then
        ShowNotification("状态闸门", "已关闭：自动功能不再校验钓鱼状态（空闲时可能持续发包，仅建议调试时使用）", "WARN", 5)
    else
        ShowNotification("状态闸门", "已开启：仅在有效钓鱼/搏斗状态执行自动发包与自动技能", "SUCCESS", 4)
    end
end, "FishingGate")
-- 闸门的高级项与诊断按钮平时不动，收进一行胶囊，避免占掉【钓鱼】页首屏
local gateDrawer = createDrawerCapsule(fishCard, "闸门高级与诊断",
    "点击展开：闸门兼容模式（仅「明明在搏斗却不放技能」时才开）与当前闸门状态查看", false)
-- [UI-DEP] 「仅在钓鱼时自动」关闭时，闸门高级项与诊断按钮一并隐藏（此时闸门不生效，调它没意义）
DashUI.BindUIParent(FindCapsuleRoot(gateDrawer), {"FishingGate"})
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
-- [UI-DEP] 「自动技能」关闭时，整个技能细项胶囊隐藏（里面 12 项全是它的参数）
DashUI.BindUIParent(FindCapsuleRoot(skillDrawer), {"AutoSkills"})
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
    orderBox.FocusLost:Connect(SafeConnect("技能顺序输入", function()
        -- [边界校验] 只保留技能键与分隔符并限制 16 字符：旧版无校验，超长串会让 0.25s 技能轮换逐字符遍历，且下次加载被判超长回退默认值。
        local text = (orderBox.Text or ""):gsub("[^ZzXxCcVv,%s;|/]", ""):gsub("%s+", ""):upper()
        if #text > 16 then text = text:sub(1, 16) end
        -- 清洗后若不含任何 Z/X/C/V 字母（如「;;;」全分隔符），回退默认值，避免技能轮换空转
        if text == "" or not text:find("[ZXCV]") then text = "Z,X,C,V" end
        Config.SkillOrder = text
        orderBox.Text = text
        currentSkillIndex = 1
        ShowNotification("技能顺序", "已更新为: " .. text .. " (已重置从第1个起手)", "SUCCESS")
    end))
    UIControls["SkillOrder"] = { Set = function(val) orderBox.Text = tostring(val) end }
end

createSliderRow(skillDrawer, "技能间隔", "任意两次技能之间的最小间隔（建议 1.2~1.5 秒；四个技能同时好了时，就按这个间隔一个个放）", 0.5, 5.0, Config.SkillInterval, true, "秒", function(v) Config.SkillInterval = v end, "SkillInterval")

-- [自动技能 v2 · 模块 27-A] 节奏引擎参数（静态预建行，运行期不新建 UI 节点）；用四档下拉取代原布尔开关，避免「谁好放谁」看起来像随机放
createDropdownRow(skillDrawer, "技能释放顺序", "优先(Z→X→C→V)：每次都从顺序表头扫，Z 一好就放 Z（推荐）｜顺位优先：从上次的下一位开始，谁冷却好了放谁，最均衡｜盲轮转：每「技能间隔」秒按 Z→X→C→V 点一个，不看本地冷却、只有按钮显示倒计时才跳过这一拍（节奏稳、空放少）｜严格轮流：必须等当前位冷却完（最慢）", {"优先(Z→X→C→V)", "顺位优先(谁好放谁)", "盲轮转(按顺序点)", "严格轮流(等冷却)"}, Config.SkillOrderMode, function(v)
    Config.SkillOrderMode = v
    Config.SkillStrict = (v == "严格轮流(等冷却)")
end, "SkillOrderMode")
createSliderRow(skillDrawer, "起手等待", "咬钩进入小游戏后先等这么久再放第一个技能（仅对「第二个技能起」生效，首技默认立即放）", 0.5, 10.0, Config.SkillStartDelay, true, "秒", function(v) Config.SkillStartDelay = v end, "SkillStartDelay")
-- 首技立即释放（游戏进入战斗会重置 CD，第一个技能必定可用）
createToggleRow(skillDrawer, "首技立即释放", "开启（推荐）：本场第一个技能不吃「起手等待」、也不做施法前的界面冷却校验，直接放；放完立刻按按钮上的真实秒数记冷却，第二个技能起才等冷却。若发现首技经常被服务端拒绝，就关掉它", Config.SkillFirstInstant, function(v) Config.SkillFirstInstant = v end, "SkillFirstInstant")
-- [按技能独立冷却] 四项独立滑块（游戏里每个技能各自转 CD，点完要等十几~几十秒）
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
    -- 注意：Config.SkillCooldown 只在「Z 技能冷却」滑块里同步写；自检必须读四项独立冷却，否则会误导
    ShowNotification("自动技能自检", string.format("顺序 %s｜起手 %.1fs｜冷却 Z%.0f/X%.0f/C%.0f/V%.0f｜通道 %s｜%s",
        order, tonumber(Config.SkillStartDelay) or 2.5,
        tonumber(Config.SkillCdZ) or 30, tonumber(Config.SkillCdX) or 30,
        tonumber(Config.SkillCdC) or 30, tonumber(Config.SkillCdV) or 30,
        tostring(Config.SkillChannel or "自动"), line), "SUCCESS", 6)
end)
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
local baitNameList = {"Basic Bait", "Crude Mash Bait", "Corrupted Essence Bait", "Elite Bait", "Ancestral Bait", "Nameless Bait", "Frost Bait", "Rainbow Bait", "Intuitive Bait", "Thunder Bait"}

local loadout1Drawer = createDrawerCapsule(equipCard, "预设配装方案 #1",
    "点击展开：选择方案1的鱼竿与鱼饵，一键换装", false)
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
            -- [V15.30 / PCAP3] 竿名大小写兜底：抓包 #154 UpdateFishingRodShop 服务端清单是「Wooden rod」（小写 r），
            -- 静态表/预设写的是「Wooden Rod」：精确 FindFirstChild 会误报「未拥有」且回发名字也错 → 必须大小写不敏感找到背包真实节点、用其节点名回发，不猜大小写。
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

end -- end of equipCard scope

-- ============================================================================
-- 【模块 15：黑名单防误卖保护引擎、单次防翻转上锁与安全卖鱼系统 (SafeSellAllFish)】
-- 作用：精确名(=)/前缀(^)/后缀($)/通配符(*?)与全词边界物种匹配，自动剥离 " | 重量"、括号重量与全系变异前缀（100% 保护变异鱼）；TryFavoriteProtectedFish 对未锁保护鱼单发收藏并立即确权防翻转；SafeSellAllFish 仅在全部保护鱼已上锁且度过服务端落锁窗口后才发 SellFish("All")，否则严禁调用。
-- 后续修改：新增默认保护材料鱼请改 craftMaterialFish；rareBossKeywords 未被任何判定读取，加词不生效（改 craftMaterialFish 或 Config.CustomProtectedFish）。
-- ============================================================================
do -- Fish Protection, Sell & Boss Scope
-- 全部内部字典/缓存/辅助函数收敛进单一局部表 FG，压低主块活跃局部变量（Luau 200 寄存器硬上限）
local FG = {
    craftMaterialFish = {
        -- 1. 彩虹鱼饵 (Rainbow Bait) 材料鱼 (4种) + 召唤Boss
        ["Colossal Tigerfish"] = true, ["Heavenpiercer Turtle"] = true, ["Heaven Piercer Turtle"] = true,
        ["Golden Guardian Fish"] = true, ["Crimson Electric Eel"] = true,
        ["Rainbow Dragonfish"] = true, ["Rainbow Dragon Fish"] = true,
        -- 2. 冰霜鱼饵 (Frost Bait) 材料鱼 (4种) + 召唤Boss
        ["Frost Kingfish"] = true, ["Frost King Fish"] = true, ["Ascended Perch"] = true,
        ["Primordial Kunfish Overlord"] = true, ["Warbringer Shark"] = true,
        ["Frost Queenfish"] = true, ["Frost Queen Fish"] = true,
        -- 3. 无名鱼饵 (Nameless Bait) 材料鱼 (4种) + 召唤Boss
        ["Mountain Fish"] = true, ["Tiger Mirefish"] = true,
        ["Mirage Lanternfish"] = true, ["Octoparasitic Fish"] = true,
        ["Nameless Octoparasite"] = true,
        -- 4. 直觉/通灵鱼饵 (Intuitive Bait) 材料鱼 (4种) + 召唤Boss (Weather Isle 更新新增)
        ["Aquatic Fish"] = true, ["Flame Fish"] = true,
        ["Thunder Fish"] = true, ["Wind Fish"] = true,
        ["Intuitive Fish King"] = true,
        -- 5. 雷霆鱼饵 (Thunder Bait) 材料鱼 (4种) + 召唤Boss (Mystic Reef Isle 更新新增)
        ["Apollo Swordfish"] = true, ["Killer Sawshark"] = true,
        ["Demon Bladefish"] = true, ["Colossal Bull Shark"] = true,
        ["Thunder Bull Shark"] = true,
        -- 6. 旧版经典任务与材料鱼兼容保留
        ["Catfish"] = true, ["Crimson Catfish"] = true,
        ["Scarlet Fish"] = true, ["Elder Scarlet Fish"] = true,
        ["Sanguine Fish"] = true
    },
    rodMaterialFish = {
        -- 1. 破天钓竿 (Heavenpiercer Rod - Power 100) 4种材料鱼
        ["Flying Fish Emperor"] = true, ["Flying Fish Empress"] = true,
        ["Heavenpiercer Turtle"] = true, ["Heaven Piercer Turtle"] = true,
        ["Rainbow Dragonfish"] = true, ["Rainbow Dragon Fish"] = true,
        -- 2. 纯钻钓竿 (Pure Diamond Rod - Power 100) 4种材料鱼
        ["Frost Kingfish"] = true, ["Frost King Fish"] = true,
        ["Frost Queenfish"] = true, ["Frost Queen Fish"] = true,
        ["Sanguine Fish"] = true, ["Draconic Koi"] = true, ["Dragon Koi"] = true,
        -- 3. 神圣竹竿 (Sacred Bamboo Rod - Power 100) 制作与江老任务材料鱼
        ["Nameless Octoparasite"] = true, ["Octoparasitic Fish"] = true,
        ["Reborn Puffer Beast"] = true, ["Reborn Puffer"] = true,
        ["Ascended Perch"] = true, ["Mountain Fish"] = true,
        ["Trueform Jiaolongfish"] = true,
        -- 4. 天道钓竿 (Heaven Rod - Power 110 最新终局制作竿) 4种材料鱼
        ["Yinfish Sovereign"] = true, ["Yangfish Sovereign"] = true,
        ["Yangfish Empress"] = true, ["Intuitive Fish King"] = true,
        -- 5. 未知钓竿 (Unknown Rod - Power 100 亚索任务线) 材料鱼
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
        -- 繁体客户端别名（繁体「魚≠鱼」会致规范失配，以下鱼种原先仅有简体）
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
        -- 制作神话钓竿材料鱼（中语、英语、粤语/繁体、越南语全别名）
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
        -- 新增直觉鱼饵 (Intuitive Bait) & 雷霆鱼饵 (Thunder Bait) & 钓竿任务材料鱼别名（中/粤繁/越/英）
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
        -- 越南语鱼种别名（含带声调与无声调写法，统一映射至标准英文鱼名）
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
    lastFavBlockNotify = 0,
    pendingLockQueue = {},
    inLockQueue = setmetatable({}, { __mode = "k" }),
    isBatchLockQueueRunning = false,
    batchLockStartedAt = 0, -- 批处理上锁协程启动时间戳（60s 时间戳兜底，防死锁）
    lockConfirmedOrSent = setmetatable({}, { __mode = "k" }),
    lastLockSentAt = setmetatable({}, { __mode = "k" }),
    lastAnyLockSentAt = 0,
    lockRetryAfter = setmetatable({}, { __mode = "k" }),
    lockFailCount = setmetatable({}, { __mode = "k" }),
    -- 按 "鱼名 | 重量" 记录已发包上锁的实例：服务端锁鱼销毁旧实例并插入同名新实例时精准过户已锁状态；旧实例仍存活（2 条同重同名鱼）时第 2 条仍会正常上锁。
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

-- 取"重量文本"：优先原文透传，其次按客户端实证的两位小数格式化。
-- 抓包实证 pcap3（唯一基准）：#9 "Chainbound Shark | 20584.58"、#10 "Colossal Tigerfish | 5988651.12"、#16 "Sanguine Fish | 4308106.78"
-- 三例全部两位小数；#9/#11 与 #16/#17 是同一鱼两次 toggle，重量文本逐字节相同 ⇒ 客户端透传实例名原文，不是 tonumber 后再格式化。
-- 旧实现 tostring(number) 走 %.14g：300.00→"300"、20584.50→"20584.5"、1e14→"1e+14"，末位是 0 或整数就与客户端不一致 ⇒ 服务端按名找不到该鱼、上锁静默失败，
-- 且 lockedInstListByBase / GUI 精确名匹配的键也会跟着错（销毁重建的锁状态过户一起失效）。
function FG.GetItemWeightText(item)
    if not item or typeof(item) ~= "Instance" then return nil end
    -- 1) 实例名里已有的重量原文：直接切片透传（绝不做 tonumber→tostring 往返）
    local nameText = item.Name:match("|%s*([%d%.]+)%s*$") or item.Name:match("|%s*([%d%.]+)%s*|")
    if nameText then return nameText end
    -- 2) 子节点/属性本身是字符串型重量：原样透传
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
    -- 3) 数值回退：使用 tostring(w) 保持与实例原始数值一致，避免整数/一位小数被强制补 .00 导致服务端匹配失败
    local w = FG.ExtractItemWeightKg and FG.ExtractItemWeightKg(item) or nil
    if w and w > 0 then return tostring(w) end
    return nil
end

-- 提取鱼实例的 "鱼名 | 重量" 基础标识（自动剥离末尾可能已存在的 "| Favorite" 或 "| Locked" 后缀，防止重复拼接）
function FG.GetItemBaseNameWithWeight(item)
    if not item then return "" end
    local raw = (typeof(item) == "Instance") and tostring(item.Name) or tostring(item)
    local stripped = raw:gsub("%s*|%s*[Ff][Aa][Vv][Oo][Uu]?[Rr][Ii][Tt][Ee][Dd]?%s*$", "")
                        :gsub("%s*|%s*[Ll][Oo][Cc][Kk][Ee]?[Dd]?%s*$", "")
    stripped = stripped:match("^%s*(.-)%s*$") or raw
    if typeof(item) == "Instance" and not stripped:find("|", 1, true) then
        -- 必须用"重量文本"而不是 tostring(number)，否则尾随 0 / .00 / 科学计数法全与客户端不一致
        local wtxt = FG.GetItemWeightText and FG.GetItemWeightText(item) or nil
        if wtxt and wtxt ~= "" then
            return stripped .. " | " .. wtxt
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
    if baseKey ~= "" then
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

-- 移除某条鱼实例的已上锁追踪记录（供玩家关闭保护手动解锁时调用）
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

-- 检查新实例是否为服务端锁鱼时销毁旧同名实例后原位重建的实例，或同名同重量已发送过单次上锁包的实例
function FG.ClaimDestroyedLockInheritance(item)
    if not item or typeof(item) ~= "Instance" then return false end
    if FG.lockConfirmedOrSent[item] then return true end
    local baseKey = FG.GetItemBaseNameWithWeight(item)
    if baseKey == "" then return false end
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
        -- 用 tqLc 折叠（纯 ASCII 结果与 string.lower 完全一致），并覆盖越语 khóa / yêu thích 白名单
        local low = tqLc(v):match("^%s*(.-)%s*$")
        if low:find("unfav", 1, true) or low:find("unlock", 1, true) or low:find("mở khóa", 1, true) then return false end
        return low == "true" or low == "1" or low == "yes" or low == "locked"
            or low == "favorited" or low == "favourited" or low == "favorite" or low == "favourite"
            or low == "lock" or low == "fav"
            or low == "khóa" or low == "đã khóa" or low == "yêu thích" or low == "đã thích"
    end
    return false
end

-- 判断手持物是否为"一条鱼"（用于暂停自动抛竿）。注意：入参必须已做过小写/折叠处理。
function FG.IsFishLikeName(lowName)
    if type(lowName) ~= "string" or lowName == "" then return false end
    local keys = FG.fishSpeciesGuardKeywords
    for i = 1, #keys do
        local kw = keys[i]
        if #kw >= 4 then
            if string.find(lowName, kw, 1, true) then return true end
        else
            -- 3 字母以内的短词（ray / cod / eel / bass）必须整词匹配，
            -- 否则 "Prayer"（含 ray）、"Wheel"（含 eel）这类无关手持物会被误判成鱼而错误暂停抛竿。
            if string.find(lowName, "%f[%a]" .. kw .. "%f[%A]") then return true end
        end
    end
    return string.find(lowName, "cá", 1, true) ~= nil or string.find(lowName, "鱼", 1, true) ~= nil
end
DashUI._isFishLikeName = FG.IsFishLikeName

-- 数据层判锁专用关键词（兼容中/越/英 fav / lock / 锁 / 收藏 / khóa / yêu thích）
function FG.HasFavLockKeyword(str)
    if type(str) ~= "string" or str == "" then return false end
    local kLow = tqLc(str)
    return kLow:find("fav", 1, true) ~= nil or kLow:find("lock", 1, true) ~= nil
        or kLow:find("锁", 1, true) ~= nil or kLow:find("收藏", 1, true) ~= nil
        or kLow:find("khóa", 1, true) ~= nil or kLow:find("yêu thích", 1, true) ~= nil
end

-- 规范化鱼种名称（自动剥离重量与变异词缀并映射中/越文别名到英文小写，带 512 条 LRU 缓存）
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
    -- 先剔除千克单位再判倍数：否则 "(800 KG)" 里的 K 会被当成千倍，与 FormatWeightTag 输出的 "800kg" 永不相等
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

-- 检测单个库存 UI 槽位卡片左上角锁头图标的显式状态（仅在卡片已实际渲染或具备显式锁属性/锁名子节点时判定，避免背包关闭时误判）
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

-- 判断游戏背包网格当前是否正打开并渲染在屏幕上
function FG.IsInventoryGridVisibleOnScreen()
    for i = 1, #FG.cachedInvGrids do
        local g = FG.cachedInvGrids[i]
        if g and g.Parent and g.Visible and g.AbsoluteSize.X > 40 and g.AbsoluteSize.Y > 40 then
            local sg = g:FindFirstAncestorOfClass("ScreenGui")
            if not sg or sg.Enabled then
                local allVis = true
                local cur = g
                while cur and cur ~= sg do
                    if cur:IsA("GuiObject") and not cur.Visible then
                        allVis = false
                        break
                    end
                    cur = cur.Parent
                end
                if allVis then
                    return true
                end
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

    -- 部分网格被销毁后不能把死引用留在缓存里（强引用会阻止回收）；原地压缩存活网格，不再每 0.25s 新建临时数组（元素顺序与过滤条件逐项一致）
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
    -- [Delta 减负 M6] 背包不可见闸门（改进版）：先在上方清空四张锁缓存表并原地剔除已销毁的 validGrids 引用（防止关背包后旧鱼实例被强引用滞留），
    -- 随后若非强制刷新且库存网格未在屏幕显示，则直接跳过下方高开销的卡片属性/子节点跨 C 遍历（GetGuiSlotLockState 的全部读取点本就先判可见性）。
    if not force and not FG.IsInventoryGridVisibleOnScreen() then return end
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
                    -- 同一次刷新只做一次全量后序遍历：已遍历过的句柄通过第二个返回值复用
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

-- 查询某条背包鱼实例在库存 UI 中的显式锁头状态（支持实例绑定、精确卡片名计数与同种同重量比对）
function FG.GetGuiSlotLockState(item, strictMode)
    if not item or typeof(item) ~= "Instance" then return nil end
    FG.RefreshGuiLockCache(tick(), false)
    local byInst = FG.guiLockByInstance[item]
    if byInst ~= nil then return byInst end

    local baseWithW = FG.GetItemBaseNameWithWeight(item)
    -- 按原顺序惰性取候选（顺序/判定/短路点与原来的 3 元素临时数组完全一致）
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
                -- 同种同重量容差：绝对下限 50 或相对 0.005（≥1 吨大鱼行为不变，只收紧小鱼避免同种小鱼互相误配）
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

-- 检查数据模型层（实例名 "| Favorite" 后缀 / 子节点 / 属性 / ValueBase / 父级收藏表）上锁状态，返回 isLocked, hasExplicitLockField
function FG.GetFishItemDataLockState(item)
    if not item or typeof(item) ~= "Instance" then return false, false end
    -- 本链无 yield，故同链内同实例结果不变：仅在链作用域内复用，键是鱼实例本身（同名不同实例不会串味）
    local chainMemo = FG.lockStateChainMemo
    local chainHit = chainMemo and chainMemo[item]
    if chainHit then return chainHit[1], chainHit[2] end
    -- 1. 检查实例名末尾是否带有 "| Favorite" 或 "| Locked"
    local rawName = tostring(item.Name or "")
    -- 绝大多数背包鱼名不含 "|"：先做一次零分配的纯文本包含判定，跳过 match/lower/子串切片三次分配
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
    -- 锁状态字符串统一走 tqLc 折叠（去越文重音），裸 :lower() 会漏掉 "Mở khóa" / "Chưa khóa" 这类显式解锁值
    local vLow = (item:IsA("ValueBase") and type(item.Value) == "string") and tqLc(item.Value) or ""
    if item:IsA("StringValue") and vLow ~= "" and vLow ~= "1" then
        if FG.IsTruthyLockValue(item.Value) then
            return true, true
        elseif vLow == "false" or vLow:find("unfav", 1, true) or vLow:find("unlock", 1, true)
            or vLow:find("mở khóa", 1, true) or vLow:find("chưa khóa", 1, true) then
            hasExplicitField = true
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

-- 仅查询数据模型层是否已确认上锁
function FG.IsFishItemDataFavorited(item)
    local isLocked = FG.GetFishItemDataLockState(item)
    return isLocked
end

-- 综合判定鱼实例是否已处于上锁保护状态（兼顾数据层、单次已发包防翻转标记、已销毁同名实例过户继承及打开状态的库存UI白锁检测）
function FG.IsFishItemFavorited(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked = FG.GetFishItemDataLockState(item)
    if dataLocked then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or (tick() - 5.0))
        return true
    end
    FG.ClaimDestroyedLockInheritance(item)
    if FG.lockConfirmedOrSent[item] then
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

-- 严格“卖鱼安全”判定：仅当保护鱼已通过数据层确认或已发出单次上锁包且度过 1.5s 服务端落锁期后，才允许执行 SellFish("All")
function FG.IsFishItemSellSafe(item)
    if not item or typeof(item) ~= "Instance" then return false end
    local dataLocked = FG.GetFishItemDataLockState(item)
    if dataLocked then
        FG.RegisterLockedInstance(item, FG.lastLockSentAt[item] or (tick() - 5.0))
        return true
    end

    FG.ClaimDestroyedLockInheritance(item)

    local now = tick()
    local sentAt = FG.lastLockSentAt[item] or 0
    if sentAt > 0 and (now - sentAt) < 1.5 then
        return false
    end

    if FG.lockConfirmedOrSent[item] then
        return true
    end

    if FG.IsInventoryGridVisibleOnScreen() then
        local uiStrict = FG.GetGuiSlotLockState(item, "strict")
        if uiStrict == true then
            FG.RegisterLockedInstance(item, now - 5.0)
            return true
        end
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
                elseif (p == "flame " or p == "烈焰" or p == "火焰") and (s:find("flame fish", 1, true) or s:find("火之鱼", 1, true) or s:find("烈焰鱼", 1, true) or s:find("火焰鱼", 1, true)) then
                    -- 保留原生火之鱼名称
                elseif (p == "thunder " or p == "雷电" or p == "闪电") and (s:find("thunder fish", 1, true) or s:find("thunder bull shark", 1, true) or s:find("雷之鱼", 1, true) or s:find("雷霆", 1, true)) then
                    -- 保留原生雷之鱼/雷霆公牛鲨名称
                elseif (p == "demon " or p == "demonic ") and (s:find("demon bladefish", 1, true) or s:find("恶魔刀鱼", 1, true)) then
                    -- 保留原生恶魔刀鱼名称
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
    -- 精确匹配模式（=鱼名）
    if mode == "exact" then
        local exactBody = tqLc(bodyMapped)
        matcher = function(pureLower, fullLower, baseLower)
            return pureLower == body or pureLower == exactBody
                or (baseLower and (baseLower == body or baseLower == exactBody))
                or fullLower == body or fullLower == exactBody
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
    if src == FSYC.cachedRuleSource then return cachedRuleMatchers end
    table.clear(cachedRuleMatchers)
    for token in string.gmatch((src:gsub("，", ","):gsub("；", ";")), "([^,;\n\r]+)") do
        local m = FG.BuildFishMatcher(token)
        if m then table.insert(cachedRuleMatchers, m) end
    end
    FSYC.cachedRuleSource = src
    return cachedRuleMatchers
end

-- 判断鱼名字符串是否命中任何保护规则（含收藏目标、多选保护名单、变异鱼词缀、Boss稀有鱼及制饵材料鱼）
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

-- 判断鱼名字符串是否命中任何保护规则（按"配置指纹 + 名字"记忆化：命中结果只与名字 + 保护相关配置有关，
-- 配置一变立即整体失效；否则背包 200 条鱼 × 每 1.2s 一轮会持续占用主线程）。
function FG.IsFishNameStringBlacklisted(rawStr)
    if type(rawStr) ~= "string" or rawStr == "" then return false end
    local flags = (Config.MaterialFarming and 1 or 0) + (Config.RodMaterialFarming and 2 or 0)
        + (Config.AutoFavouriteFish and 4 or 0)
    -- Lua 字符串是 interned 的，这里 == 是 O(1) 指针比较，热路径零分配
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

-- 内部安全调用收藏 Remote（采用在途引用计数维护 IdenticalInternalFavCall，防止并发异步调用提前复位标志位）
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
    -- [V15.44 / PKT-FIX] 恢复 15.31 就有的 PacketGuard 去重 + 异常指数退避（15_31.lua:7659-7671 被重构漏掉了）。
    -- 少了这道闸：同一帧里多个通道（上锁队列 / 入包监听 / 卖鱼前巡检）会各发一次完全相同的 FavoriteItem 包；
    -- 且 FireServer 一旦报错，旧版会按 0.5->1.2s 指数退避降频，新版则按固定节拍无限重试 —— 这是全脚本
    -- 唯一「重构后发包变多」的地方，也是服务端最可能判异常的组合。
    if favRem:IsA("RemoteEvent") then
        if PacketGuard and not PacketGuard.Allow(favRem, unpackFavArgs(args, 1, args.n)) then return false end
        EnterInternalFavCall()
        local ok, err = pcall(function() favRem:FireServer(unpackFavArgs(args, 1, args.n)) end)
        LeaveInternalFavCall()
        if PacketGuard then PacketGuard.RecordResult(favRem, ok, err) end
        return ok
    elseif favRem:IsA("RemoteFunction") then
        if PacketGuard and not PacketGuard.Allow(favRem, unpackFavArgs(args, 1, args.n)) then return false end
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

-- 构建上锁发包候选格式优先级列表。
-- [审计 R-17] 注意：BuildCandidateFavFormats 目前恒只产出 {"name_favorite"}（抓包 22/26 条即此单参形态），
--   因此 UI 下拉的 5 档「上锁发包模式」实际都发同一种包；其余分支为历史遗留，不要据此以为可选格式生效。
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
    -- 只保留抓包实证过的形态：pcap3 #9~#17 九条出向全部是单字符串 "鱼名 | 重量[ | Favorite]"，
    -- pure_name / instance / action_instance / action_name 在三份抓包里 0 次出现。这个字符串是"鱼的标识"，
    -- 会随锁状态变化（#12↔#13 在 0.53s 内交替），换写法不可能让同一条鱼上锁，只可能发成无效包或反向语义包（无后缀 name 正是 #9/#12/#14/#17 那另一半）。
    if mode ~= "鱼名+后缀(Name | Favorite)" and not FG._favModeWarned then
        -- 只提示一次：批量上锁是 70~100ms 一条的循环，每条都写日志会把控制台刷爆
        FG._favModeWarned = true
        FLogWarn("上锁", "所选发包模式在抓包中不存在（pcap3 只观测到 name_favorite），本次仍按 name_favorite 发送: " .. tostring(mode))
    end
    -- 不用 IdenticalLearnedFavFormat 置顶：它记录玩家最后一次手动调用的形态，手动"解锁"时发的正是反方向。
    pushFmt("name_favorite")
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
        -- 放行窗口上界兜底：标志位由"本次远程往返"持有，协程被 cancel 或远程永不返回时会残留 true，
        -- 导致玩家手动上锁/解锁被永久当内部调用放行 ⇒ 用时间戳钉死 1.5s（大于任何一次 RF 往返实测时延），超时强制复位。
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

-- [单次防翻转上锁核心引擎] FG.ExecuteSingleLockNow：
--   1. 对每条未上锁的保护鱼发送 1 次上锁包后，立即调用 `FG.RegisterLockedInstance(item, now)` 标记确权；
--   2. 钓鱼期间（背包未打开且无显式 false 字段时）绝不对同一条鱼发送第 2 次 Toggle 包，彻底杜绝"先锁后解"；
--   3. 仅当数据层存在显式 Favorite 字段且 1.8s 后仍为 false，或背包界面正打开且明确显示灰锁时，才切换备选格式补锁。
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
    local fmt = candidates[math.clamp(tryIdx, 1, #candidates)] or "name_favorite"

    local sendOk = FG.FireFormatOnce(favRem, item, fmt)
    if not sendOk then
        local fails = (FG.lockFailCount[item] or 0) + 1
        FG.lockFailCount[item] = fails
        FG.lockRetryAfter[item] = now + 0.40
        return false
    end

    FG.lastAnyLockSentAt = now
    -- 单次发包后立即登记实例已上锁确权，防止重复发送偶数次 Toggle 包把已锁鱼解开
    FG.RegisterLockedInstance(item, now)
    FG.lockFailCount[item] = nil
    FG.lockRetryAfter[item] = nil
    return true
end

-- 启动异步步进分批上锁工作协程（每条间隔 0.07s，每满 20/45 条呼吸停顿，突破服务端 50 包限流）
function FG.StartBatchLockWorker()
    -- 并发 worker 防护：只要老协程还活着就一律拒绝重复启动（多个 worker 并存会破坏「每 0.07s 一条、每 20/45 条呼吸」的限流，直接撞服务端 50 包限制），
    -- 只有「句柄已 dead 但标记没清」才做一次性自愈。
    if FG.isBatchLockQueueRunning then
        local th = FG.batchLockThread
        if th == nil then
            -- 个别执行器的 task.spawn 不返回线程句柄：兜底时长必须大于 300s 搏斗挂起上限，防止长战斗期间重入启动双 Worker
            if (tick() - (FG.batchLockStartedAt or 0)) < 310.0 then return end
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
        selfThread = coroutine.running()
        FG.batchLockThread = selfThread
        local batchSent = 0
        pcall(function()
            while isRunning and #FG.pendingLockQueue > 0 do
                local maxPassGuard = 0
                while isRunning and #FG.pendingLockQueue > 0 and maxPassGuard < 400 do
                    -- [V15.44 / PKT-FIX] 恢复 15.31 的「搏斗期暂停上锁」闸门，严禁与小游戏高频包同帧交错
                    local fightWaitDeadline = tick() + 300
                    while isRunning and tick() < fightWaitDeadline and FishGate and FishGate.IsFight and FishGate.IsFight() do
                        FG.batchLockStartedAt = tick()
                        task.wait(0.25)
                    end
                    if not isRunning then break end
                    FG.batchLockStartedAt = tick()
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
                                if item.Parent and (FG.lockFailCount[item] or 0) < 3 and not FG.inLockQueue[item] then
                                    FG.inLockQueue[item] = true
                                    table.insert(FG.pendingLockQueue, item)
                                end
                                HRandomWait(0.35, 0.05)
                            end
                        end
                    end
                end
                if isRunning and #FG.pendingLockQueue > 0 then
                    task.wait(0.25)
                end
            end
        end)
        -- 只允许「自己这条协程」清标记：被后来者顶掉后不能误清新协程的锁
        if selfThread == nil or FG.batchLockThread == selfThread then
            FG.isBatchLockQueueRunning = false
            FG.batchLockStartedAt = 0
            FG.batchLockThread = nil
        end
    end)
    if selfThread and FG.isBatchLockQueueRunning then
        FG.batchLockThread = selfThread
    end
end

-- 将单条未上锁的保护鱼加入异步步进上锁队列（带防重入与冷却检查）
function FG.TryLockSingleFishItem(item, favRem, now, forceResend, preverified)
    -- preverified：调用方 TryFavoriteProtectedFish 在同一决策链上刚判定过，跳过重复的装备/保护判定
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

-- 监听玩家背包 (Inventory / Hotbar) 新增鱼实例事件，支持容器重建时自动清理旧连接
FG.bagFolderConns = FG.bagFolderConns or {}
function FG.EnsureBagAutoLockListeners(pData)
    if not pData then return end
    -- 容器被销毁后其 ChildAdded 连接已被引擎自动断开，顺手把这类死连接从登记表与 activeConnections 里摘掉，避免强引用长期残留
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

-- 扫描 Inventory 与 Hotbar，将全部未上锁保护鱼排入步进分批队列
TryFavoriteProtectedFish = function(pData, forceResendAll)
    pData = pData or GetPlayerData()
    if not pData or not Events then return 0, 0 end
    FG.EnsureBagAutoLockListeners(pData)
    local favRem = Events:FindFirstChild("FavoriteItem") or FG.GetFavoriteRemote()
    if not favRem then return 0, 0 end

    local now = tick()
    -- 惰性清理 lockedInstListByBase 里已失去实例且超过 120s 的旧记录：脱离父节点的记录要短时间保留供 ClaimDestroyedLockInheritance 过户，
    -- 超过 2 分钟无人认领的只会在长挂中无限堆积，这里定期回收，不影响任何过户判定。
    if now - (FG.lastLockListSweep or 0) >= 3.0 then
        FG.lastLockListSweep = now
        for baseKey, list in pairs(FG.lockedInstListByBase) do
            if type(list) == "table" then
                for i = #list, 1, -1 do
                    local entry = list[i]
                    local deadInst = (not entry) or (not entry.inst) or entry.inst.Parent == nil
                    if entry and entry.inst and entry.inst.Parent == nil then
                        entry.inst = nil -- 立即解除对已销毁 C++ Instance 的强引用，仅保留 sentAt 供 120s 内过户继承
                    end
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

    -- 本链无 yield，故同链内同实例结果不变：链入口建作用域缓存、链出口立即清空（不做时间窗过期）。
    -- 已核对无 yield：循环体只调 IsNonFishEquipmentItem/ShouldProtectFishItem/IsFishItemDataFavorited/IsFishItemFavorited/TryLockSingleFishItem（其内 StartBatchLockWorker 仅 task.spawn 后立即 return）
    -- [Delta 减负 M7] 改用弱键表：即使循环中途异常中断未能执行链尾置 nil，也不会强引用整包鱼实例。
    FG.lockStateChainMemo = setmetatable({}, { __mode = "k" })
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

-- 检查是否有正在执行的分批上锁队列或刚发出不足 2.0s 的上锁请求，防止上锁未落盘前抢先触发 SellFish
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

-- 供 __namecall 与卖鱼模块调用的发包参数黑名单拦截器（包内存在未锁稳的保护鱼时一律拦截 SellFish）
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
        -- 递归深度上限：自引用/深嵌套表会栈溢出，而溢出会被 Hook 外层 pcall 吞掉
        depth = (tonumber(depth) or 0) + 1
        if depth > 3 then
            -- 深度超限说明参数结构异常（自引用/深嵌套），本函数 true=拦截，因此必须 fail-closed；
            -- 若 return false 等于放行，正是本次要修的"溢出后 fail-open 放行全卖"问题
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

-- 安全卖鱼主函数：先将背包内所有保护鱼单次上锁并等待 2.0s 服务端落锁确认，确认全部保护鱼安全后才发送 SellFish("All")；
-- 若存在任何未完成上锁的保护鱼，严禁调用 SellFish（彻底移除会触发服务端全卖未锁鱼的逐条降级分支），100% 杜绝误卖！
SafeSellAllFish = function(pData)
    if isSellingInProgress or not Events or not Events:FindFirstChild("SellFish") then return end
    -- [审计-13] 搏斗/钓鱼中不要做"换竿 + 排上锁队列 + 等 2~6 秒"这一整套前置动作：
    -- 原实现要等到 8008 才判闸门，期间已经换竿、把保护鱼排队，按钮入口甚至已经传送过 → 白跑一轮且与战斗包交织
    if FishGate and not FishGate.IsIdle() then
        DashUI.SetStatus("卖鱼", "延后: 搏斗中")
        return
    end
    isSellingInProgress = true
    DashUI.SetStatus("卖鱼", "开始")

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

            -- 卖鱼前先扫描并将所有未上锁的保护鱼排入上锁队列
            FG.RefreshGuiLockCache(tick(), true)
            TryFavoriteProtectedFish(pData, false)

            local waitStart = tick()
            local maxWait = math.clamp(2.2 + (#FG.pendingLockQueue * 0.12), 2.2, 6.0)
            local lastRetryAt = 0
            while isRunning and (tick() - waitStart < maxWait) do
                local settling = FG.HasAnyLockSettlingInBag(pData)
                if not settling then
                    if not FG.HasAnyUnsafeProtectedFishInBag(pData) then break end
                    local nowTick = tick()
                    if not FG.isBatchLockQueueRunning and (nowTick - lastRetryAt) >= 0.8 then
                        lastRetryAt = nowTick
                        pcall(TryFavoriteProtectedFish, pData, false)
                    end
                end
                task.wait(0.15)
            end

            FG.RefreshGuiLockCache(tick(), true)
            if not isRunning then return end
            -- [V15.44 / PKT-FIX] 恢复「搏斗/钓鱼中不卖鱼」兜底（15_31.lua:8243-8245 被重构删掉）。
            -- 上面那段最长 6 秒的等待期间，玩家完全可能已经咬钩进入小游戏；此时再发 SellFish("All")，
            -- 卖鱼包会和进度包/猛击包同帧交叉，是服务端最容易判异常的组合之一。
            if FishGate and not FishGate.IsIdle() then
                DashUI.SetStatus("卖鱼", "延后: 搏斗中")
                FLog("自动卖鱼", "等待期间已进入钓鱼/搏斗状态，本次卖鱼已安全延后")
                return
            end
            if not FG.HasAnyUnsafeProtectedFishInBag(pData) and not FG.HasAnyLockSettlingInBag(pData) then
                -- [审计-14] 记录"这一包到底有没有真的发出去"：原来无论去重闸/退避拦下还是类型不匹配，都报"已卖出"
                local sellFired = false
                if sellRem:IsA("RemoteEvent") then
                    if not PacketGuard or PacketGuard.Allow(sellRem, "All") then
                        local okFire, errFire = pcall(function() sellRem:FireServer("All") end)
                        if PacketGuard then PacketGuard.RecordResult(sellRem, okFire, errFire) end
                        sellFired = (okFire == true)
                    end
                elseif sellRem:IsA("RemoteFunction") then
                    sellFired = (DashUI._safeInvokeAsync(sellRem, FSYC.Tunables and FSYC.Tunables.InvokeDefaultTimeoutSec or 4.0, "All") == true)
                end
                if sellFired then
                    DashUI.SetStatus("卖鱼", "已卖出")
                    ShowNotification("自动卖鱼", "已确认全部保护鱼锁定完毕，安全执行全卖普通鱼！", "SUCCESS", 2)
                else
                    DashUI.SetStatus("卖鱼", "未发出: 被去重/退避或调用失败拦下")
                end
            else
                DashUI.SetStatus("卖鱼", "延后: 保护鱼锁定中")
                ShowNotification("防误卖保护", "检测到保护鱼正在同步锁定中，已延后本次出售，确保绝不误卖保护鱼！", "WARN", 2.5)
            end
        end)
        if not okSell then FLogErr("卖鱼", sellErr) end
        DashUI.SetStatus("卖鱼", okSell and "结束" or ("失败: " .. tostring(sellErr)))
        -- 互斥锁必须无条件复位：task.wait 在协程被 cancel 时会抛错，用 pcall 兜底防止卖鱼功能永久锁死
        pcall(function() task.wait(0.2) end)
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
                -- [退出清理] InputHoldEnd 是收尾动作，不能因 isRunning=false 被跳过，
                -- 否则该 prompt 会停留在"按住中"状态一段时间内无法再次交互。
                if prompt and prompt.Parent then
                    prompt:InputHoldEnd()
                end
            end)
            activePromptTasks[prompt] = nil
        end)
    end
end

-- 获取任意 NPC 模型、Attachment、ProximityPrompt 或零件的世界坐标（兼容流式卸载下的 GetBoundingBox / GetPivot）
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

-- 实测：部分游戏的对话选项把回调挂在 MouseButton1Down/Up 上，只挂 Activated/MouseButton1Click/TouchTap 会 getconnections 不到、点了没反应
local GUI_CONN_SIGNALS = {"Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "TouchTap"}
local GUI_FIRE_SIGNALS = GUI_CONN_SIGNALS -- 与 GUI_CONN_SIGNALS 逐元素相同，复用同一张表避免两处维护漂移
-- 复用虚拟 InputObject 的两个只读方法引用，消除每次 MakeSyntheticInput 分配 2 个匿名闭包
local function SyntheticModifierFalse() return false end
local function SyntheticIsA(_, cls) return cls == "InputObject" or cls == "Instance" end

-- 构造兼容 Luau 回调属性读取的虚拟 InputObject（避免 C++ 信号反射类型强转失败）
-- 用赋值绑定到区域 A 的前向声明 local（不能用 local function，否则 D 区按全局解析成 nil，通道 4 静默失效）
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

-- 模拟点击屏幕 GuiButton / 触屏圆钮组件（覆盖按钮自身、同级兄弟按钮、圆钮外层 Frame 及屏幕真实触控坐标）
FireGuiButton = function(btn, allowInactive, simulateScreenTouch)
    -- allowInactive：游戏内对话/任务/猛击按钮常常 Active=false 或为 Frame+TextLabel 套壳，此时只要可见就允许触发
    if not btn or not btn:IsA("GuiObject") or not btn.Visible then return false end
    if btn:IsA("GuiButton") and not allowInactive and not btn.Active then return false end
    local firedAny = false
    local seenObj = {}
    local btnTargets = {}
    local guiTargets = {}
    local function addTarget(obj)
        -- 增加 Parent 校验：短缓存里的条目可能已被销毁（销毁后仍可读属性，会被 pcall 吞掉白跑一遍信号触发）
        if not obj or not obj.Parent or seenObj[obj] or not obj:IsA("GuiObject") or not obj.Visible then return end
        seenObj[obj] = true
        table.insert(guiTargets, obj)
        if obj:IsA("GuiButton") and (allowInactive or obj.Active) then
            table.insert(btnTargets, obj)
        end
    end

    addTarget(btn)
    -- 若父容器含 UIListLayout/UIGridLayout（对话选项列表/技能栏等多按钮容器）立即停止向上合并，严防误触兄弟按钮；
    -- 同时 allowInactive / 非 GuiButton 也要向上合并（监听可能挂在外层圆钮容器上），误触防护交给上面的 Layout 早停。
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
        -- 子节点列表 0.25s 短缓存：搏斗期 FireGuiButton 每 0.08~0.13s 调一次，GetDescendants() 每次都会在引擎侧新建整个实例数组并全部进 GC。
        -- 缓存只存「子节点清单」，可见性 / 父子关系仍在 addTarget 里逐次实时判定，行为语义不变。
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

    -- 1) 触发所有 GuiButton 的标准点击信号（兼容移动端执行器 conn:Fire 无参失败时自动回退调用 conn.Function）
    for _, tBtn in ipairs(btnTargets) do
        -- 记录本按钮已通过 getconnections 点过火的信号名：下面的 firesignal 只补没被覆盖到的那些，
        -- 避免同一批连接被点火两次（手机热路径每次回调 2~4 遍）。拿不到 connections 时它是 nil ⇒ 仍全量补发。
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
                                if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false then
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
                                -- 只在 conn:Fire() 失败时才回退调 conn.Function：否则 Fire 成功后 simulateScreenTouch 为真会再调一次，
                                -- 同一信号的回调被执行两遍（猛击/自动充能/自动技能正是热路径）。
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
                            end
                            if sigFired then
                                firedAny = true
                                -- 记下这个信号名，下面 firesignal 会跳过它
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
                -- 跳过已被 getconnections 覆盖的信号名；connFiredSigs 为 nil（没有 getconnections 能力）时全量补发，
                -- 保证「拿不到 connections 仍必须靠 firesignal」这条兜底不被破坏。
                if not (connFiredSigs and connFiredSigs[fireName]) then
                    local sig = tBtn[fireName]
                    if sig and pcall(firesignal, sig) then
                        firedAny = true
                    end
                end
            end
        end
        -- 不发 replicatesignal：它会把本地信号复制成上行流量上报服务端，与 firesignal 叠加后同一次点击产生两条通道，是最容易识别的伪造形态。
    end

    -- 2) 针对移动端触屏圆钮（如「按下F键进行猛击」），对组件内所有 GuiObject（含外层 Frame / TextLabel）触发 TouchTap 与 InputBegan/Ended
    if simulateScreenTouch and type(getconnections) == "function" then
        -- 仅在 simulateScreenTouch 分支按需创建另外 3 个虚拟输入对象，常规按钮点击省去 75% 对象分配
        local fakeMouseBegin = MakeSyntheticInput(Enum.UserInputType.MouseButton1, Enum.UserInputState.Begin, Enum.KeyCode.F, posVec3)
        local fakeTouchEnd = MakeSyntheticInput(Enum.UserInputType.Touch, Enum.UserInputState.End, Enum.KeyCode.F, posVec3)
        local fakeMouseEnd = MakeSyntheticInput(Enum.UserInputType.MouseButton1, Enum.UserInputState.End, Enum.KeyCode.F, posVec3)
        for _, gObj in ipairs(guiTargets) do
            pcall(function()
                if not gObj:IsA("GuiButton") and gObj.TouchTap then
                    local tConns = getconnections(gObj.TouchTap)
                    if type(tConns) == "table" then
                        for _, conn in ipairs(tConns) do
                            if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false and type(conn.Function) == "function" then
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
                            if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false and type(conn.Function) == "function" then
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
                            if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false and type(conn.Function) == "function" then
                                -- 按下→抬起间隔加 0~0.04s 抖动（点击类上限 0.12s）
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

    -- 3) 屏幕坐标级虚拟鼠标点击兜底（仅当步骤 1/2 信号均未命中且处于电脑端时触发；严禁在手机端调用 SendTouchEvent(0, ...) 或 CaptureController() 抢占单指旋转视角 touchId=0）
    if simulateScreenTouch and not firedAny and not (ModeCtl and ModeCtl.IsMobile and ModeCtl.IsMobile())
        and not (DeviceProfile and DeviceProfile.touch)
        and widgetRoot.AbsoluteSize.X > 4 and widgetRoot.AbsoluteSize.Y > 4 then
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
                local mKey = DashUI._pressVirtualMouse(clickX, screenY, false)
                pcall(function() vim:SendMouseButtonEvent(clickX, screenY, 0, true, game, 1) end)
                task.delay(HRand(0.03, 0.04), function()
                    pcall(function() vim:SendMouseButtonEvent(clickX, screenY, 0, false, game, 1) end)
                    DashUI._releaseVirtualMouse(mKey)
                end)
                firedAny = true
            end
        end)
    end
    return firedAny
end

-- ============================================================================
-- 【模块 16：【钓鱼】页面经济/防卖配置 UI 与【Boss】页面构建（无名章鱼 / 恩佐 / 龙钓海）】
-- 作用：自动卖鱼 / 防卖收藏名单 / 上锁发包模式 / 背包诊断 + 无名章鱼与恩佐·龙钓海 Boss 面板。
-- ============================================================================
do -- Economy & Sell UI Sub-Scope (独立 do-end 块及时释放 UI 局部寄存器)
local sellCard = createCollapsibleGroup(tabFishing, "经济与出售", false)
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
local uiRowSellInterval = createSliderRow(sellCard, "出售间隔(秒)", "出售鱼的频率 (10秒-60分钟)", 10, 3600, Config.SellInterval, false, "秒", function(v) Config.SellInterval = v end, "SellInterval")
-- [UI-DEP] 只在「自动卖鱼」开启时需要调这个值
DashUI.BindUIParent(uiRowSellInterval and uiRowSellInterval.frame, {"AutoSell"})
createButtonRow(sellCard, "立即出售并传送到娜娜", "传送到娜娜处并安全出售非保护鱼", "立即出售", function()
    -- [UI-CONFIRM] 一次点击就会「传走 + 全卖」，不可逆：先二次确认，避免手指划过误触
    if DashUI.Confirm then
        -- [UI-CONFIRM] NN/g：确认框必须写清「对象 + 数量 + 代价 + 不可逆」，否则等于没确认
        local bagCount = 0
        local cData = GetPlayerData()
        if cData then
            for _, folderName in ipairs({"Inventory", "Hotbar"}) do
                local f = cData:FindFirstChild(folderName)
                if f then bagCount = bagCount + #f:GetChildren() end
            end
        end
        DashUI.Confirm("立即出售并传送？",
            string.format("背包内约 %d 个物品。会先传送到娜娜处，再执行一次安全全卖（保护鱼与已上锁的鱼不会被卖）。此操作不可撤销。", bagCount),
            "确认出售", function()
                local pData = GetPlayerData()
                if SafeTeleport(CFrame.new(-203.5, 7.3, 107.1)) then
                    -- 传送后卖出前加 0~0.15s 抖动（传送类上限 0.35s，只加长不缩短）
                    HRandomWait(0.3, 0.15)
                    SafeSellAllFish(pData)
                end
            end)
        return
    end
    local pData = GetPlayerData()
    if SafeTeleport(CFrame.new(-203.5, 7.3, 107.1)) then
        HRandomWait(0.3, 0.15)
        SafeSellAllFish(pData)
    end
end, "danger")

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
-- 程序化回写保护名单输入框时的抑制标志：避免 Text 处理器再次截断/回写造成丢新鱼
local favBoxSyncing = false
-- 将指定鱼种自动合入 CustomProtectedFish 多选保护名单（若尚未存在），防止下拉切换新鱼时丢失之前选过的保护鱼
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
        -- 900 字节上限从「最旧」条目开始丢：直接截断拼接串会把刚追加的新鱼截掉
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

-- 「收藏目标」下拉框：选中任意鱼种时自动将其追加进保护名单（之前选过的鱼同样保留受保护，不会因为换选另一条鱼而被卖掉！）
local favDropdownCtrl = createDropdownRow(sellCard, "收藏目标", "选中即自动加入保护名单（含变异鱼）；之前选过的鱼也会继续保留保护", baseFishList, Config.FavouriteFishName, function(v)
    Config.FavouriteFishName = v
    EnsureFishInProtectedList(v)
    local pData = GetPlayerData()
    if (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, pData, false)
    end
    local listStr = (Config.CustomProtectedFish and Config.CustomProtectedFish:match("^%s*(.-)%s*$")) or tostring(v)
    ShowNotification("已添加保护目标", string.format("当前选中: [%s]\n受保护总名单: %s", tostring(v), listStr), "SUCCESS", 3)
-- [静态池容量] 下拉池 160：超过 64 时 Refresh 会截断并把当前选中重置为第一项（构建期一次性预建、运行期零新建）。
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
    customFavBox:GetPropertyChangedSignal("Text"):Connect(SafeConnect("保护名单输入", function()
        -- 程序化同步期间早退：不截断、不回写，避免刚合入的新鱼被再次裁掉
        if favBoxSyncing then return end
        -- 与 SanitizeConfigValue 的 900 字符上限对齐；只截断写入 Config 的副本，不回写输入框（避免光标跳动与递归触发）
        local favTxt = customFavBox.Text or ""
        if #favTxt > 900 then favTxt = Utf8SafeCut(favTxt, 900) end
        Config.CustomProtectedFish = favTxt
    end))
    customFavBox.FocusLost:Connect(SafeConnect("保护名单确认", function()
        -- 同上：程序化同步期间早退
        if favBoxSyncing then return end
        -- 同上：与 SanitizeConfigValue 的 900 字符上限对齐
        local favTxt = customFavBox.Text or ""
        if #favTxt > 900 then favTxt = Utf8SafeCut(favTxt, 900) end
        Config.CustomProtectedFish = favTxt
        local pData = GetPlayerData()
        if (Config.AutoFavouriteFish or Config.AutoSell or Config.RodMaterialFarming or Config.MaterialFarming) and TryFavoriteProtectedFish then
            pcall(TryFavoriteProtectedFish, pData, false)
        end
        ShowNotification("名单已更新", "已更新自定义多选保护名单！", "SUCCESS", 2.5)
    end))
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
        -- [审计-16] 记住当前选中项，刷新后若仍可选则写回（silent=true 不触发回调），避免"点一次扫描背包就改了收藏目标"
        local keepFav = favDropdownCtrl.Get and favDropdownCtrl.Get()
        favDropdownCtrl.Refresh(merged, true)
        if keepFav and favDropdownCtrl.Set then
            for _, n in ipairs(merged) do
                if n == keepFav then
                    favDropdownCtrl.Set(keepFav, true)
                    break
                end
            end
        end
    end
    ShowNotification("扫描完成", string.format("已刷新纯鱼名列表（共 %d 种可选）！", #merged), "SUCCESS")
end)
end -- end of Economy & Sell UI Sub-Scope

-- Boss 页面：无名章鱼寄生体 + 恩佐/龙钓海 + 自动传送防冲突
TeleportToDragonSea = function()
    -- 优先在 Workspace / BossSetUp / Islands / Map 中查找龙钓海 / Mountain Dragon Whale / Dragon 实体或区域坐标，兜底前往雾峰岛龙域
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

do -- Boss UI Sub-Scope
-- 小字风险提示条：挂在开关下方永远可见（开关开=高亮、关=变暗），只用 AutomaticSize + TextWrapped，不写死高度。
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
    -- SetActive(on)：开=亮黄底+亮字，关=暗底+灰字（提示仍在，但一眼能看出当前没启用）
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
-- [F22-08] 范围 85~100、默认 100：本关命中 +50 血、漏按 -200 血，80% 是收益平衡点、低于 80% 净亏血，不确定就保持 100
createSliderRow(octoCard, "节奏命中率 (Accuracy %)", "每个节拍真的去按的几率。100 = 每次都按（最稳、必定过）；越低越像真人手速，但空过的节拍会被游戏判成漏按（-200 血）。命中 +50 / 漏按 -200，所以 80% 是收益平衡点、低于 80% 净亏血，不确定就保持 100", 85, 100, Config.RhythmAccuracy, true, "%", function(v)
    Config.RhythmAccuracy = v
end, "RhythmAccuracy")
-- [UI-DEP] 节奏命中率 只在「OctoAutoMinigame」开启后才有意义
DashUI.BindUIParent(UIControls["RhythmAccuracy"] and UIControls["RhythmAccuracy"].frame, {"OctoAutoMinigame"})
-- [BAN-FIX] 0.18s / 0.12s 两档已删：286 次命中 × 0.18s = 51s、× 0.12s = 34s，远低于真人约 103s，
-- 服务端比一次击杀时长即可判定（实测「33 秒内击败 boss」被封）；现四档 86~109s，运行期硬夹 ≥ 0.30s。
createDropdownRow(octoCard, "节奏节拍", "两次命中的间隔。本关 20000 血 ÷ 每击 70 = 需 286 次命中、限时 120 秒，真人实测平均 0.36 秒（约 103 秒打完）。0.30s 已是最快安全档（86s），再快必被封", {"0.38s 保守", "0.36s 真人速", "0.34s 稳健(推荐)", "0.30s 最快(仍安全)"}, "0.34s 稳健(推荐)", function(v)
    local map = { ["0.38s 保守"] = 0.38, ["0.36s 真人速"] = 0.36, ["0.34s 稳健(推荐)"] = 0.34, ["0.30s 最快(仍安全)"] = 0.30 }
    Config.RhythmBeatSec = map[v] or 0.34
end, "RhythmBeatSec")
-- [UI-DEP] 节奏节拍 只在「OctoAutoMinigame」开启后才有意义
DashUI.BindUIParent(UIControls["RhythmBeatSec"] and UIControls["RhythmBeatSec"].frame, {"OctoAutoMinigame"})
createButtonRow(octoCard, "传送到章鱼寄生体", "传送到海洋隐藏Boss浮标", "传送", function()
    if SafeTeleport(CFrame.new(1608.2, 5.0, -218.3)) then ShowNotification("已传送", "已到达无名章鱼寄生体海洋浮标！", "SUCCESS") end
end)
createButtonRow(octoCard, "传送到渔夫之地", "传送到地下渔夫领域", "传送", function()
    if SafeTeleport(CFrame.new(112.5, -330.0, -30.8)) then ShowNotification("已传送", "已到达地下渔夫之地！", "SUCCESS") end
end)

local bossFarmCard = createCollapsibleGroup(tabBoss, "恩佐 龙钓海")
-- [REALBOSS] 第二阶段读条判定（协议来自实机抓包，默认关）
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
-- [BAN-FIX-2] Enzo 二阶段真人均值 1.19s、最快 0.51s，低于 0.50s 就是「血量蒸发」（实测 33 秒击杀被判封）；
-- 判定条上限约 1.8 次/秒（≈0.54s 一次），档位值见下方 map。
createDropdownRow(bossFarmCard, "命中节拍", "本关 Boss 20000 血 ÷ 每次 200 = 需 100 次命中，所以档位直接等于「多少秒打完」：1.20→120s｜0.95→95s｜0.75→75s｜0.60→60s｜0.45→45s｜0.30→30s。判定条最快约 0.54 秒给一次机会（100 次≈54 秒是真人极限），比 0.60 更快就是人做不到的速率", {"1.20s 真人速", "0.95s 稳健", "0.75s 偏快(推荐)", "0.60s 很快(有风险)", "0.45s 极快(概率封号)", "0.30s 疯狂(高概率封号)"}, "0.75s 偏快(推荐)", function(v)
    local map = {
        ["1.20s 真人速"] = 1.20, ["0.95s 稳健"] = 0.95, ["0.75s 偏快(推荐)"] = 0.75,
        ["0.60s 很快(有风险)"] = 0.60, ["0.45s 极快(概率封号)"] = 0.45,
        ["0.30s 疯狂(高概率封号)"] = 0.30,
    }
    Config.RealBossGap = map[v] or 0.75
end, "RealBossGap")
-- [UI-DEP] 命中节拍 只在「RealBossHit」开启后才有意义
DashUI.BindUIParent(UIControls["RealBossGap"] and UIControls["RealBossGap"].frame, {"RealBossHit"})
local aggressiveWarnNote
createToggleRow(bossFarmCard, "激进模式(不等绿区)",
    "不等绿区经过，按节拍直接报命中。注意：它的真正风险不是「快」，而是每一发都落在判定区之外——服务端按自己的判定条位置一比对就是不可能的操作",
    Config.RealBossForce, function(v)
        Config.RealBossForce = v
        if aggressiveWarnNote then pcall(aggressiveWarnNote.SetActive, v) end
        if v then
            -- 不强行改用户选的节拍（保留下拉的自由度），只提示；真正的物理下限在 RealBossStep 里（硬编码 0.30s）
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
-- [UI-DEP] 拟人命中率 只在「RealBossHit」开启后才有意义
DashUI.BindUIParent(UIControls["RealBossHitRate"] and UIControls["RealBossHitRate"].frame, {"RealBossHit"})
createButtonRow(bossFarmCard, "传送到Enzo", "传送到Enzo竞技场", "传送", function()
    if SafeTeleport(CFrame.new(-115.3, 9.2, 1349.5)) then ShowNotification("已传送", "已到达Enzo竞技场！", "SUCCESS") end
end)
createButtonRow(bossFarmCard, "传送到龙钓海", "传送到龙钓海", "传送", function()
    TeleportToDragonSea()
end)
end -- end of Boss UI Sub-Scope
end -- end of Sell and Boss UI scope

-- 【模块 17：V5.0 全图深度 NPC 数据库、ProximityPrompt 零污染触发与双引擎远程对话系统】
-- 作用：13 岛中心 IslandCenters + NPC 数据库 ImportantDialogueNPCs + 三岛神灵/四圣兽表；ProximityPrompt 缓存与零污染触发；OpenRemoteNPCDialogue 双引擎（原位直连 → 流式预加载 + 微瞬移贴脸）。
-- 后续修改：新增可对话/可传送 NPC，只需在 ImportantDialogueNPCs 按同格式追加一条即可自动生成双按钮行并接入雷达。
-- ============================================================================
do -- NPC Engine, God & Quests Scope
-- 安全调用单个 RemoteEvent 或异步调用 RemoteFunction，统一接入 PacketGuard 限流去重与异常指数退避
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

-- 尝试请求服务端流式加载指定坐标周围的地图与 NPC 模型（带单飞防重入保护，防止网络波动时流式请求协程重叠堆积）
TryStreamAroundPosition = function(pos)
    if not pos then return end
    local now = tick()
    if FSYC.streamInFlightAt and (now - FSYC.streamInFlightAt) < 3.5 then return end
    FSYC.streamInFlightAt = now
    pcall(function()
        if type(LocalPlayer.RequestStreamAroundAsync) == "function" then
            task.spawn(function()
                pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, 2) end)
                FSYC.streamInFlightAt = nil
            end)
        else
            FSYC.streamInFlightAt = nil
        end
    end)
end

-- 📦 官方完整 NPC 数据库（涵盖全部核心、主线、后期、流动商人、三个神灵与四圣兽）
ImportantDialogueNPCs = {
    -- 1. 起始岛与核心系统 NPC
    {cnName = "票据任务员 (Quest Giver)", internalName = "Ticket Quest Giver", desc = "每日票据任务 (起始岛 [1] Easy / Hard 抽卡券任务)", aliases = {"Ticket Quest Giver", "Quest Giver", "QuestGiver", "TicketQuest", "Ticket NPC", "Ticket", "DailyQuest", "票据", "任务员", "每日票据", "Nhân Viên Nhiệm Vụ Vé", "Nhan Vien Nhiem Vu Ve", "Phiếu Nhiệm Vụ", "Phieu Nhiem Vu"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "南江 (Nanjang / Nanjiang)", internalName = "Nanjang", desc = "抽特质 物品交换 (初始岛 [1] 技能特质重铸 / 洗练四圣兽)", aliases = {"Nanjang", "Nanjiang", "Nam Giang", "NamGiang", "TraitNPC", "Trait", "南江", "特质"}, fallbackPos = Vector3.new(-200.7, 11.1, 35.9)},
    {cnName = "初始岛楚依旧 · 智者伊杰尤 (Sage Yiju)", internalName = "Sage Yiju", desc = "买技能 对话 (初始岛 [1] 智者伊杰尤 · 基础 Cash 金币钓鱼技能商店)", aliases = {"智者伊杰尤", "伊杰尤", "Sage Yiju", "Sage Yijiu", "Chu Yijiu", "Sage Eiju", "Yiju", "Eiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者", "买技能", "技能商人"}, fallbackPos = Vector3.new(-117.5, 6.8, 41.2), preferPos = Vector3.new(-117.5, 6.8, 41.2), altPositions = {Vector3.new(-117.5, 6.8, 41.2), Vector3.new(-200.7, 11.1, 35.9)}},
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
    {cnName = "战场岛楚依旧 · 智者伊杰尤 (Sage Yijiu)", internalName = "Sage Yijiu", desc = "买技能 任务 (战场岛 [9] 5阶段终极主线: 钻石竿→一钩霸主)", aliases = {"智者伊杰尤", "伊杰尤", "Sage Yijiu", "Sage Yiju", "Chu Yijiu", "Sage Eiju", "Yijiu", "Yiju", "Sở Y Cửu", "So Y Cuu", "楚依旧", "逸久贤者"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "失明的大钓鱼人 (Blind Grand Angler)", internalName = "Blind Grand Angler", desc = "任务 对话 (战场岛 [9] 星辰大钓术·极 Astral Grand Art Zenith)", aliases = {"Blind Grand Angler", "Grand Angler", "BlindAngler", "Blind", "失明", "大钓鱼人", "盲眼", "Ngư Phủ Mù", "Ngu Phu Mu", "Thợ Câu Cá Mù", "Tho Cau Ca Mu"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6)},
    {cnName = "竹岛江老 (Giang Lao)", internalName = "Giang Lao", desc = "任务 对话 (竹岛 [2] 无影太极击 Shadowless Taji + 神圣竹竿)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), preferPos = Vector3.new(-1223.0, 7.3, -24.1)},
    {cnName = "战场岛江老 (Giang Lao BF)", internalName = "Giang Lao BF", desc = "主线任务 (战场岛 [9] 升仙太极术 Ascended Taji Art 任务)", aliases = {"Giang Lao", "Jiang Lao", "Old Jiang", "Giang Lão", "江老", "老江", "老姜"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "老江 (Old Jiang)", internalName = "Old Jiang", desc = "普通升级任务 (竹岛/主权岛 经验与等级提升支线)", aliases = {"Old Jiang", "Giang Lao", "Jiang Lao", "Lão Giang", "老江", "江老"}, fallbackPos = Vector3.new(-1223.0, 7.3, -24.1), altPositions = {Vector3.new(-1223.0, 7.3, -24.1), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "钓科威 / 老吴 (Lao Ngo)", internalName = "Lao Ngo", desc = "主线任务 (战场岛/天气岛 碎心斩V2 Heartbreaker Cleave V2 任务)", aliases = {"Lao Ngo", "Diao Ke Wei", "Lao Wu", "Lão Ngô", "Heartbreaker", "钓科威", "迪奥·克维", "迪奥", "老吴"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), preferPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2908.1, 6.8, 1191.2)}},
    {cnName = "暗影 (The Shadow)", internalName = "The Shadow", desc = "升级角色 (起始岛瀑布后秘密洞穴 · 献祭资源突破角色等级)", aliases = {"The Shadow", "Shadow", "An Ying", "Dark", "Upgrade Character", "暗影", "升级角色", "Ám Ảnh", "Am Anh", "Bóng Tối", "Bong Toi"}, fallbackPos = Vector3.new(-8.4, 53.9, 6.7), preferPos = Vector3.new(-8.4, 53.9, 6.7)},

    -- 3. 后期门派与英雄任务 NPC（加入多英文/越文内部别名 + 跨岛巡检定位，解决远距离找不到问题）
    {cnName = "少林 / 花和尚 (Shaolin)", internalName = "Shaolin", desc = "购买 (少林钓法 / 降龙伏虎 / 如来神掌 武学技能)", aliases = {"Shaolin", "Monk", "Flower Monk", "Thieu Lam", "Hoa Thuong", "Hòa Thượng", "Buddha", "Tathagata", "Dragon Subjugation", "少林", "花和尚"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-1276.4, 8.8, 1239.7)}},
    {cnName = "五指钓王 (Five Finger King)", internalName = "Five Finger King", desc = "主线任务(天气鱼) (琥珀岛/雾峰岛 提交指定天气稀有鱼)", aliases = {"Five Finger", "Wu Zhi", "Weather King", "Finger", "Ngu Chi", "Ngũ Chỉ", "World Angler", "五指钓王", "五指", "卢奥亚之王"}, fallbackPos = Vector3.new(1259.4, 9.1, 1401.5), altPositions = {Vector3.new(1259.4, 9.1, 1401.5), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "史星钓 / 石克翔 (Shi Xing Diao)", internalName = "Shi Xing Diao", desc = "主线任务 (雾峰岛/珊瑚礁岛 高阶钓鱼人主线任务挑战)", aliases = {"Shi Xing Diao", "ShiXingDiao", "石克翔", "史星钓", "石星之骄", "World Angler", "Star Angler", "Sử Tinh Điếu", "Su Tinh Dieu"}, fallbackPos = Vector3.new(2660.2, 8.8, -86.7), altPositions = {Vector3.new(2660.2, 8.8, -86.7), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6)}},
    {cnName = "楚天骄 (Chu Tian Jiao)", internalName = "Chu Tian Jiao", desc = "主线任务 (战场岛/雾峰岛/珊瑚礁岛 天骄专属进阶试炼任务)", aliases = {"Chu Tian Jiao", "ChuTianJiao", "Tian Jiao", "Thien Kieu", "Sở Thiên Kiêu", "Pride", "Celestial", "楚天骄", "楚天之骄"}, fallbackPos = Vector3.new(1393.5, 11.3, 169.6), altPositions = {Vector3.new(1393.5, 11.3, 169.6), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(2660.2, 8.8, -86.7), Vector3.new(1259.4, 9.1, 1401.5)}},
    {cnName = "亚索 (Yasuo)", internalName = "Yasuo", desc = "主线任务 (鲈鱼岛/珊瑚礁岛/战场岛 疾风剑豪斩风钓法全套技能)", aliases = {"Yasuo", "Yaxuo", "Wind", "Swordsman", "Wanderer", "Ronin", "Chem Gio", "Chém Gió", "Triple Cut", "亚索"}, fallbackPos = Vector3.new(-62.0, 11.9, -1321.4), altPositions = {Vector3.new(-62.0, 11.9, -1321.4), Vector3.new(-2648.0, 6.8, -1322.1), Vector3.new(1393.5, 11.3, 169.6), Vector3.new(2660.2, 8.8, -86.7)}},

    -- 4. 流动商人 / 隐藏商人（含英/中/越文全别名与 liveKey 实时坐标联动）
    {cnName = "道士商人 (Taoist Merchant)", internalName = "Taoist", liveKey = "Taoist", desc = "流动商人 (100M道士珠 / 200M极鹰猎 / 接取「三个神灵」任务)", aliases = {"Taoist Merchant", "Taoist", "Xiao Daoshi", "XiaoDaoshi", "Tieu Dao Si", "TieuDaoSi", "Tiểu Đạo Sĩ", "Đạo Sĩ", "Dao Si", "Little Taoist", "道士", "小道士"}, fallbackPos = nil},
    {cnName = "茅山商人 (Maoshan Merchant)", internalName = "Maoshan", liveKey = "Maoshan", desc = "流动商人 (300M茅山竿 / 200M茅山珠 / 200M镇江技能)", aliases = {"Maoshan Merchant", "Maoshan", "Mao Shan", "Mao Son", "MaoSon", "Mao Sơn", "Dai Su Huynh", "DaiSuHuynh", "Đại Sư Huynh", "茅山", "大师兄"}, fallbackPos = nil},
    {cnName = "傻子隐藏商人 (Dumb Guy)", internalName = "Dumb Guy", liveKey = "DumbGuy", desc = "轮换隐藏商人 (六脉神鹰 Six Vein Divine Hawk / 道士商店卡)", aliases = {"Dumb Guy", "Dumb Man", "Dumb", "Thang Ngu", "ThangNgu", "Thằng Ngu", "Thằng Ngốc", "Thang Ngoc", "傻子", "笨蛋"}, fallbackPos = nil},
}

-- 三个神灵专属配置表（支持英/中/越文模型名、祭坛名与交互提示词匹配）
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
        table.insert(bSpec.lowerAliases, tqLc(al))
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
        -- 首 token 含 emoji（UTF-8 首字节 0xF0，星平面字符）时跳过，避免把图标当成检索关键词
        if pureCn and #pureCn >= 2 and not pureCn:find("\240", 1, true) then addKw(pureCn) end
    end
    if spec.aliases then
        for i = 1, #spec.aliases do addKw(spec.aliases[i]) end
    end
    spec._compiledKeywords = kwList
    return kwList
end

-- [perf] 实例名小写折叠缓存（IsMapOrIslandContainer / DoesInstanceMatchNPCSpec / GetInstanceSearchableSummary 共用）：
-- 全图扫描对同一批节点反复调 tqLc（string.lower 分配 + 越南语多字节扫描 + pcall/gsub）；按实例弱键缓存，改名即失效，结果与原 tqLc 逐字符一致。
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

-- 判断实例是否为整座岛屿或地图级顶层大容器（防止把整座岛屿 Model 当作单个 NPC 聚合）
IsMapOrIslandContainer = function(inst)
    if not inst or inst == Workspace then return true end
    local nLow = LowerInstName(inst) -- [本地化] 越南语大写折叠（[perf] 按实例缓存）
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
    -- [本地化] 越南语 "đảo" / 中文「岛」命名的整岛容器同样排除，否则整座岛被当单个 NPC（传送目标错位 + 每轮全岛 GetDescendants）。
    -- 注意不要加 ASCII "dao"：Daoshi / Dao Si（道士商人）会被误判成岛屿容器。
    if nLow:find("đảo", 1, true) or nLow:find("岛", 1, true) then
        return true
    end
    return false
end

-- 从 ProximityPrompt 向上反查所属的具体 NPC / 神灵祭坛实例（兼容 Attachment、Model、BasePart 与独立子 Folder，绝不误取整座岛屿容器）
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

-- 提取实例及其内部交互提示、头顶 BillboardGui 文本与多语言翻译文本的检索摘要（带流式子节点数量校验缓存）
GetInstanceSearchableSummary = function(inst)
    if not inst then return "" end
    -- [零 GC] 只有 BasePart 需要"无子节点即早退"、只有地图级容器需要"子节点数 > 60 才早退"。
    if inst:IsA("BasePart") and #inst:GetChildren() == 0 then
        return LowerInstName(inst)
    end
    if IsMapOrIslandContainer(inst) and #inst:GetChildren() > 60 then
        return LowerInstName(inst)
    end
    local now = tick()
    local cached = npcTextSummaryCache[inst]
    -- [PERF-R2] 先吃 0.5s 内的缓存再算 descendants：同一轮雷达里同一实例会被 inspectEntity 与 27 个 NPC spec 反复取摘要。
    -- 0.5s 上限保证只在同一轮内复用（跨轮照常重算），提示文本变化的可见延迟与原来一致。
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

-- 判断场景中的 Model 实例是否匹配目标 NPC 配置（结合名称与 300s 缓存的内部文本摘要比对）
-- [PERF-R5] 按 (实例 → spec) 缓存匹配结果：雷达每轮对每个候选实体跑 27 个 spec、单轮约 1600 次判定，是扫描最贵的一段。
-- TTL 0.7s 必须 **短于** 雷达量化周期 0.90s（否则「先出模型后挂 prompt」的流式实体可见延迟放大到近两轮）；键带实例名，改名立即失效。
local specMatchCache = setmetatable({}, { __mode = "k" })
-- 前置声明：Lua 的 local 必须先用后定义，否则调用点会解析成全局 nil（错误还会被外层 pcall 吞掉）
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
    -- GetPlayerFromCharacter 仅对 Model 有意义（非 Model 恒 nil），先 IsA 前置判定，避免对每个 BasePart/Folder 候选白跑一次跨边界 pcall + 闭包分配
    if inst:IsA("Model") then
        local okPlr, plr = pcall(function() return Players:GetPlayerFromCharacter(inst) end)
        if okPlr and plr then return false end
    end
    local kwList = GetCompiledSpecKeywords(spec)
    local nLow = LowerInstName(inst) -- [本地化] 越南语大写折叠（"Đạo Sĩ" 等别名才能命中；[perf] 按实例缓存）
    local nLen = #nLow
    for i = 1, #kwList do
        local kw = kwList[i]
        -- [perf] 针长于被搜串时 find 必然失配，先比长度省掉一次 C 调用（纯等价剪枝，匹配结果不变）
        if #kw <= nLen and (nLow == kw or nLow:find(kw, 1, true)) then
            return true
        end
    end
    -- [perf] 无子节点 BasePart 的摘要正文就是本节点名本身（上面已逐个关键词测过同一批 find），直接返回 false：省掉缓存查找 + 子节点数组 + 拼接
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

-- ProximityPrompt 缓存与原始属性保护表（独立 do...end 封装内部状态，释放局部寄存器）：
-- 1) 全局唯一一对 Workspace.DescendantAdded/Removing 同时维护 cachedAllPrompts 与 cachedBossPrompts；2) hasPollutedPrompts 脏标记让无污染时 O(1) 早退。
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
    local function RestoreSinglePrompt(pr, forcePulseHide, wasEnabled)
        if not pr or not pr.Parent then return end
        local orig = RememberPromptState(pr)
        currentlyTriggeringPrompts[pr] = nil
        pcall(function()
            pr.MaxActivationDistance = orig.dist
            pr.RequiresLineOfSight = orig.los
            pr.HoldDuration = orig.hold
            -- [C02] 非 forcePulseHide 路径同样要还原 Enabled，避免被强开的 prompt 永久可交互（wasEnabled 由触发点传入，nil 时行为不变）
            if wasEnabled ~= nil then pr.Enabled = wasEnabled end
            if forcePulseHide then
                -- [AUD-L01] 卸载阶段 (isRunning == false) 受管 task.delay 已停用，必须直接同步恢复原始 Enabled，
                -- 严禁先置 pr.Enabled = false 再调已被拦截的 task.delay，否则游戏内交互键会永久失效！
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

    -- 批量还原被远距触发污染的 ProximityPrompt 并隐藏远离玩家的残留交互提示框
    DismissStuckPromptsAndRestore = function(forceScanAll)
        -- [AUD-L01] 卸载阶段清空正在触发标记，确保所有被修改过的 ProximityPrompt 均能立即还原
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
        for pr, origSt in pairs(originalPromptState) do
            if pr and pr.Parent and not currentlyTriggeringPrompts[pr] then
                if (tonumber(pr.MaxActivationDistance) or 0) > 35 or not isRunning then
                    RestoreSinglePrompt(pr, true, origSt and origSt.enabled)
                end
            end
        end
        if forceScanAll and not FSYC.isFullPromptScanning then
            FSYC.isFullPromptScanning = true
            lastAllPromptsScan = nowDismiss
            task.spawn(function()
                pcall(function()
                    local descendants = Workspace:GetDescendants()
                    -- [A2-06] 遍历让出改为时间片（每 ≥4ms 或至少每 200 个实例一次），遍历范围不变
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
                FSYC.isFullPromptScanning = false
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
            -- 只做 O(1) 索引失效标记，不对数组做 table.find + table.remove（每次 O(n)）；死引用交给 GetCachedWorkspacePrompts 惰性压缩，语义一致。
            if cachedAllPromptsSet[d] then
                cachedAllPromptsSet[d] = nil
            end
            if cachedBossPromptsSet[d] then
                cachedBossPromptsSet[d] = nil
            end
        end
    end))

    -- 获取当前场景内缓存的所有有效 ProximityPrompt 列表（O(N) 双指针原地压缩 + 跨岛流式重扫自愈）
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
        -- 同步惰性压缩 cachedBossPrompts，防止未开启 Boss 挂机时残留已销毁引用
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

        -- [PERF-PM06] 循环内只登记、结束后统一一个定时器批量还原：原实现每个 prompt 各建 1 个 task.delay + 3 个 pcall 闭包（N 个定时器），语义等价。
        local restoreQueue = {}
        for _, pr in ipairs(prompts) do
            if pr and pr.Parent then
                local orig = RememberPromptState(pr)
                local wasEnabled = (pr.Enabled ~= false)   -- [C02] 记录触发瞬间的真实启用状态（RememberPromptState 的缓存可能过期）
                orig.enabled = wasEnabled                  -- 同步最新启用态到备份表，防止卸载取消 0.14s 定时器后漏还原
                local firedThis = false                    -- [C03] 本 prompt 是否已触发（不再与 ClickDetector / 其它 prompt 共享）
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
                        -- [VERIFY-F4] 逐条 pcall：合并成一个循环后必须显式隔离，否则一条异常会让后面排队的 prompt
                        -- 停在 Enabled=true / MaxActivationDistance=999999 的污染态。
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

-- 在全图中查找匹配的 NPC 实例（深入岛屿子文件夹 + 按 preferPos 距离排序）；0.5s 短缓存让直连与微瞬移两次调用只扫一次
local npcScanCache = setmetatable({}, { __mode = "k" })
-- [Delta 减负 M1] 治理器裁剪入口：删除超过 120s 的过期条目 + 剔除 results 里已销毁实例（Parent == nil）的强引用。
-- 缓存 TTL 仅 0.5s，清理过期项不改变任何一次查询的返回结果。
FSYC.TrimNpcScanCache = function()
    local nowT = tick()
    for spec, entry in pairs(npcScanCache) do
        if type(entry) ~= "table" or (nowT - (tonumber(entry.tick) or 0)) > 120 then
            npcScanCache[spec] = nil
        elseif type(entry.results) == "table" then
            local res = entry.results
            for i = #res, 1, -1 do
                local inst = res[i]
                if not (inst and inst.Parent) then table.remove(res, i) end
            end
        end
    end
end

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
    -- [冗余清理] 与全图雷达共用同一份目录名单常量
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

    -- 检查单个场景节点是否匹配目标 NPC 配置并加入结果集
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

    -- Prompt 反向溯源兜底：直接比对 ProximityPrompt 的 ObjectText/ActionText 与父级 Model/BasePart（支持智者伊杰尤、曾天国等中文/越文/英文提示框直接定位）
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

-- 检测游戏内的 NPC 对话框 UI 是否已经弹出（带热点引用缓存 + 0.35s 最小查询间隔 + 定向扫描，绝不每秒遍历整个 MainGui）
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
                -- [C15] 追加中文与无音调越文关键词（gName 已由 tqLc 折叠大小写），只加对话面板必然出现的词
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
                                            -- [实测] 「你还没有完成任务」那页只有【离开】，旧白名单缺它会让整屏被判成没有对话、关窗全被挡死
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

-- 自动点击当前弹出的 NPC 对话框选项（优先扫描对话/任务相关 ScreenGui，完全等于匹配优先、包含次之）；0.5s 候选缓存让连续 3 次点击只扫 1 次 UI 树
local dialogueBtnCache = { time = 0, list = nil }
-- [Delta 减负 M1] 治理器裁剪入口：候选缓存 TTL 0.5s，超过 60s 未被命中的候选表只会强引用整屏按钮，直接释放。
FSYC.TrimDialogueCache = function()
    if dialogueBtnCache and dialogueBtnCache.list and (tick() - (tonumber(dialogueBtnCache.time) or 0)) > 60 then
        dialogueBtnCache.list = nil
        dialogueBtnCache.time = 0
    end
end

local function AutoClickDialogueOption(preferredKeywords, allowInactive)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end

    local now = tick()
    -- [实测] 「离开/关闭/退出」这类关窗按钮必须实时扫描：共用 0.5s 缓存时换页/重建后最长 0.5s 点不到，叠加 priorityGuis 遮蔽会永久点不到。
    local wantExit = false
    -- [现状] 唯一调用点（RunGiveFishToMonkeyBatch）不传退出类关键词，wantExit 恒 false、0.12s 短 TTL 与退出词分支当前不可达；保留结构待将来接「自动关闭对话」复用。
    for _, k in ipairs(preferredKeywords or {}) do
        local kl = tqLc(tostring(k))
        if kl == "离开" or kl == "关闭" or kl == "退出" or kl == "取消" or kl == "leave" or kl == "*leave*" or kl == "nevermind" or kl == "close" or kl == "exit" or kl == "rời đi" or kl == "đóng" or kl == "thoát" then
            wantExit = true
            break
        end
    end
    local cacheTtl = wantExit and 0.12 or 0.5
    local candidates
    if dialogueBtnCache.list and (now - dialogueBtnCache.time) < cacheTtl then
        -- 复用短窗口内的候选列表；复用时重读实时文本，防止按钮复用改字后误点
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
                    -- MainGui / Fisher_GUI 体积巨大：只取名字像对话/任务的顶层子面板，绝不整树扫描
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
        -- 祖先链可见性：只看按钮自身 Visible 会把隐藏面板里的按钮当成候选（会去点屏幕外的东西）
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
        -- [实测修正] 关窗按钮可能不在名字带 dialogue/quest 的界面里；旧版 fallbackGuis 一旦有 priorityGuis 就永不扫描
        if wantExit and #fallbackGuis > 0 then
            collectFromGuis(fallbackGuis)
        end
        if #candidates == 0 and #priorityGuis > 0 then
            collectFromGuis(fallbackGuis)
        end
        dialogueBtnCache.time = now
        dialogueBtnCache.list = candidates
    end

    -- 第一轮：文本完全匹配优先
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
    -- 第一轮补充：实例名完全匹配
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
    -- 第二轮：子串包含匹配
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
    DashUI.SetStatus("传送", "前往 " .. tostring(spec.cnName or internalName))
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

    -- 到达岛屿后等待 0.28 秒流式加载完成，若扫描到真实 NPC 模型则二次精准对齐到他面前 3.5 米处（水平直立朝向，绝不倾斜摔倒）
    task.spawn(function()
        -- [C14] 传送后等流式加载再复扫：0.28 → [0.28, 0.63]，传送类 span 0.35，纯加载等待（非检测窗口）
        HRandomWait(0.28, 0.35)
        -- [审计-7] 该协程未登记 activeThreads，卸载时不会被取消：这里必须自查运行标志，避免卸载后又把角色传送一次
        if not isRunning then return end
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
        -- 🥇 引擎 1：尝试原位直连触发（不移动角色）
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

        -- 🥈 引擎 2：岛屿流式预加载 + 微瞬移贴脸强制触发（彻底解决后期岛屿亚索/少林/楚天骄/曾天国等被卸载导致无法打开的问题）
        -- [审计修复 R-15] 引擎 1 等待 0.28s 期间及多候选点轮询期间若玩家已抛竿或进入搏斗，禁止执行微瞬移以免打断钓鱼状态。
        if not isMicroTeleportingNPC and not (FishGate and not FishGate.IsIdle()) then
            isMicroTeleportingNPC = true
            local myMicroStartAt = tick()
            microTeleportLockAt = myMicroStartAt
            local myMicroToken = (FSYC.microTpToken or 0) + 1
            FSYC.microTpToken = myMicroToken
            local savedCF = root.CFrame
            local dialogueOpened = false
            local abortedByCombat = false
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
                    if not isRunning or FSYC.microTpToken ~= myMicroToken then break end
                    if FishGate and not FishGate.IsIdle() then
                        abortedByCombat = true
                        break
                    end
                    microTeleportLockAt = tick()
                    TryStreamAroundPosition(probePos)
                    -- 第一步：先瞬移到岛屿锚点，让 Roblox 客户端把该岛上的 NPC 模型流式加载出来
                    root.CFrame = CFrame.new(probePos + Vector3.new(0, 3, 2))
                    root.AssemblyLinearVelocity = Vector3.zero
                    -- [C14] 微瞬移后等流式加载：0.32 → [0.32, 0.52]（在最多 3 个候选点的循环内，span 取 0.20 控制累计上界；非检测窗口）
                    HRandomWait(0.32, 0.20)

                    local nearInstances = FindNPCInstancesBySpec(spec, true)
                    local nearTriggered = false
                    local tBeforePos = tick()   -- 本轮"对话是否打开"的判定基线
                    if #nearInstances > 0 then
                        local exactNPC = nearInstances[1]
                        local exactPos = GetNPCPosition(exactNPC)
                        if exactPos and IsPositionNearNPCSpec(spec, exactPos) then
                            OnlineNPCs[internalName] = { instance = exactNPC, pos = exactPos, time = tick() }
                            -- 第二步：如果 NPC 真实位置距离当前探测点超过 8 米，再贴脸瞬移到该 NPC 面前 2 米处确保通过服务端距离校验！
                            if (root.Position - exactPos).Magnitude > 8 then
                                root.CFrame = CFrame.new(exactPos + Vector3.new(0, 2.5, 2))
                                root.AssemblyLinearVelocity = Vector3.zero
                                -- [C14] 贴脸微调后等物理沉降：0.18 → [0.18, 0.38]（循环内，span 0.20 控制累计上界；非检测窗口）
                                HRandomWait(0.18, 0.20)
                            end
                        end
                        -- 跟这个 NPC 对话要"长按约 1 秒"才会开，而且服务端需要时间确认玩家已靠近。
                        -- 现在：触发后真正等对话出现，没出现就再来一轮，最多 3 轮。
                        if TriggerNPCInstancePrompts(exactNPC) then
                            nearTriggered = true
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
                                    local prText = tqLc((d.ObjectText or "") .. " " .. (d.ActionText or "") .. " " .. (d.Name or ""))
                                    if not matchesSpec then
                                        for _, kw in ipairs(GetCompiledSpecKeywords(spec)) do
                                            if prText:find(kw, 1, true) then
                                                matchesSpec = true
                                                break
                                            end
                                        end
                                    end
                                    -- 仅当明确匹配当前 NPC 关键词，或紧贴专属锚点 (<12米) 且不属于老江/娜娜/八长/表哥/楚新时才允许触发
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
                                -- [C14] 贴脸微调后等物理沉降：0.18 → [0.18, 0.38]（循环内，span 0.20 控制累计上界；非检测窗口）
                                HRandomWait(0.18, 0.20)
                            end
                            -- [审计-11] 必须看返回值：原写法无条件置真 → 提前 break 掉后续候选点，并向上报"已打开对话"的假成功
                            if TriggerNPCInstancePrompts(bestPr) then
                                nearTriggered = true
                            end
                        end
                    end

                    task.wait(0.25)
                    -- [审计-12] 区分"对话真的开了"与"只是触发了 prompt"：postDialogueCallback 会点对话选项并补发远程包，
                    -- 没开对话就执行等于"没有对话却发包"，是明确的风控可疑形态（猴子交鱼正是走这条回调）。
                    local openedNow = IsDialogueUIOpen(true) or ((FSYC.FSYDialogueOpenedAt or 0) > tBeforePos)
                    if openedNow or nearTriggered then
                        if openedNow then dialogueOpened = true end
                        break
                    end
                end

                if dialogueOpened and type(postDialogueCallback) == "function" then
                    pcall(postDialogueCallback)
                    -- [C14] 对话后回调已执行完，属收尾节奏：0.22 → [0.22, 0.67]，对话类 span 0.45（非检测窗口）
                    HRandomWait(0.22, 0.45)
                end
            end)

            -- 恢复玩家原位（仅在未被手动传送覆盖、未进入搏斗且仍持有本轮微瞬移令牌时归位）
            local manualTpHappened = (FSYC.lastManualTpAt or 0) > myMicroStartAt
            if FSYC.microTpToken == myMicroToken then
                if root and root.Parent and not manualTpHappened and not abortedByCombat then
                    local humNow = char and char:FindFirstChildOfClass("Humanoid")
                    if humNow then DashUI._ensureHumanoidUpright(humNow) end
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    root.CFrame = DashUI._makeUprightCFrame(savedCF) or savedCF
                end
                isMicroTeleportingNPC = false
                microTeleportLockAt = 0
            end
            DismissStuckPromptsAndRestore(false)
            task.delay(0.3, function()
                if isRunning then DismissStuckPromptsAndRestore(false) end
            end)
            if not silent then
                if dialogueOpened then
                    ShowNotification("角色", string.format("已打开 %s 的对话。", internalName), "SUCCESS", 3.5)
                else
                    ShowNotification("角色", string.format("已尝试触发 %s 对话（若未弹出请靠近后重试）。", internalName), "WARN", 3.5)
                end
            end
        elseif not silent then
            -- [可观测性] 微瞬移锁被占用时引擎 2 整体跳过、postDialogueCallback 不执行，这里补一条中文日志避免「已发送对话请求」误导排障。
            if type(postDialogueCallback) == "function" then
                FLogWarn("NPC对话", string.format("%s 的对话后回调因微瞬移锁占用被跳过", tostring(internalName)))
            end
            ShowNotification("角色", string.format("已发送 %s 对话请求。", internalName), "WARN", 3)
        end
    end)
    return true
end

-- 为每一行同时创建【传送】与【对话】双按钮的专用行组件
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
        btn.TextTruncate = Enum.TextTruncate.AtEnd
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
        -- [V15.3 BUG-06] 遵守双端输入族隔离 ModeCtl.Accepts，避免单端强制模式下被隔离的输入仍触发按钮变色
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

-- ==========================================
-- 【模块 18：【神灵】页面构建（三岛神灵祈祷、道士/茅山/傻子商人、四圣兽监控与跳服引擎）】
-- 作用：三岛神灵状态/自动祈祷/分岛传送对话 + 道士·茅山·傻子商人 + 四圣兽特质与Boss监控 + 跳服引擎
-- ============================================================================
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
            -- 增加合法性二次校验，确保不会前往被污染的错误坐标
            if not spSpec.fallbackPos or (entry.pos - spSpec.fallbackPos).Magnitude <= 450 then
                OpenRemoteNPCDialogue(spSpec, false)
                return
            end
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

local roamGodCard = createCollapsibleGroup(tabGod, "流动商人任务接取", false)
-- 按 liveKey 在 ImportantDialogueNPCs 反查：下标 20/21/22 实际指向「少林/五指钓王/史星钓」，禁止硬编码下标
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
end -- end of God UI scope

-- ==========================================
-- 【模块 19：【任务】页面构建（票据任务对话唤起、每日签到、全NPC双按钮列表与猴子交鱼）】
-- 作用：票据任务双引擎对话(不乱发包/不关窗/不收起悬浮窗) + 每日/签到领取 + 全 NPC 传送对话 + 自动交鱼给猴子
--   自动票据任务仅在未接或进度已满时弹窗，进行中静默等待不打断钓鱼
-- ============================================================================
do (function()
-- 检查当前是否已有正在进行中且尚未完成的票据任务（进行中返回 true，未接或已完成可提交返回 false）
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
        -- 本地化兜底：节点名被翻译且不在名单里时，按 ticket/vé/票据 + quest/nhiệm vụ/任务 双词语义匹配（排除 Ticket Shop 商店）
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

-- ============================================================================
-- [PCAP3] 入向 StartDialogue 4 元组 → 出向 ChooseDialogueOption（#68→#69 领奖、#77→#78 接任务、#138 为 3 参无第 4 参）：
--   #68 StartDialogue("Ticket Quest Giver", NPC, {文本,{{"Quest","Quest",false},{"Nevermind","Close",false}}}, {NPC})
--   #69 ChooseDialogueOption("Ticket Quest Giver", 1, "Quest", {NPC}) → #70 Cash 896975 / #71 Crystal 15 / #72 Ticket 9 / #73 "Quest completed!" / #74 奖励页(只有 *Leave*)
--   #77 StartDialogue(..., {{"Accept Easy Quest","EasyAcceptQuest",false},{"Accept Hard Quest","HardAcceptQuest",false},...}, {NPC,"Ticket Quest"})
--   #78 ChooseDialogueOption("Ticket Quest Giver", 2, "HardAcceptQuest", {NPC,"Ticket Quest"})
-- 硬约束：第 2 参 = 当页 1-based 下标；第 3 参 = 该选项第 2 元素(actionTag)；第 4 参 = 当页 StartDialogue 第 4 参原样回传（{NPC} vs {NPC,"Ticket Quest"} 实测不同）→ 禁止硬编码，必须每页现算。
-- 安全闸：状态新鲜 + 选项存在 + 第 4 参实例仍存活 + 对话框开着，四条全过才发；发完立即作废本页状态。
-- ============================================================================
local FSYQD = {}

-- 取当页对话状态（默认 12s 内有效）
function FSYQD.GetState(maxAge)
    local st = FSYC.DialogueState
    if type(st) ~= "table" then return nil, "no_dialogue_state" end
    -- [审计修复 R-21] 严格校验 dialogueId 与 body 类型，防止协议字段顺序变动后把 Instance 当作第 1 参回传
    if type(st.id) ~= "string" or st.id == "" or type(st.body) ~= "table" then return nil, "dialogue_state_invalid" end
    if (tick() - (tonumber(st.at) or 0)) > (maxAge or 12) then return nil, "dialogue_state_stale" end
    if typeof(st.npc) == "Instance" and not st.npc.Parent then return nil, "dialogue_npc_gone" end
    return st, "ok"
end

-- 在当页选项里按 actionTag 反查 1-based 下标（不存在返回 nil，绝不猜）
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

-- 第 4 参可用性：结构对，且表里的实例都还活着（避免对着已卸载的 NPC 发包）
function FSYQD.IsRetUsable(ret)
    if ret == nil then return true end
    if type(ret) ~= "table" then return false end
    for i = 1, #ret do
        local v = ret[i]
        if typeof(v) == "Instance" and not v.Parent then return false end
    end
    return true
end

-- 唯一允许的对话发包口：四道前置全过才发，发完立即作废本页状态（一次性消费，杜绝连点重发）
function FSYQD.Fire(actionTag, maxAge)
    local chooseRem = Events and Events:FindFirstChild("ChooseDialogueOption")
    if not chooseRem or not chooseRem:IsA("RemoteEvent") then return false, "no_choose_remote" end
    local st, why = FSYQD.GetState(maxAge or 12)
    if not st then return false, why end
    local uiOpen = false
    pcall(function() uiOpen = IsDialogueUIOpen(true) == true end)
    -- StartDialogue 刚下发（<=5s）本身就是"对话框已开"的证据；UI 探测拿不到面板路径时也不至于永久失效
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
        FSYC.DialogueState = nil      -- 等下一帧真实 StartDialogue 重建，禁止对同一页发第二次
        FSYC.FSYDialogueOpenedAt = tick()
    end
    return ok, reason or (ok and "sent" or "unknown")
end

-- 等"下一页" StartDialogue（服务端回包）——两包接任务必须靠它对齐，不能定时瞎等
function FSYQD.WaitNext(prevSeq, timeoutSec)
    -- [V15.46] 改用统一的 DashUI.WaitUntil：语义不变（超时返回 nil），等待逻辑只维护一份
    local found
    DashUI.WaitUntil(function()
        local st = FSYC.DialogueState
        if type(st) == "table" and (tonumber(st.seq) or 0) > (tonumber(prevSeq) or 0) then
            found = st
            return true
        end
        return false
    end, timeoutSec or 2.5, 0.05)
    return found
end

-- 等对话状态出现（刚打开对话框时用）
function FSYQD.WaitReady(timeoutSec)
    -- [V15.46] 同上：统一走 DashUI.WaitUntil
    local found
    DashUI.WaitUntil(function()
        local st = FSYQD.GetState(12)
        if st then found = st; return true end
        return false
    end, timeoutSec or 4.0, 0.1)
    return found
end

-- 按真实协议接任务：先发"Quest"进接取页，再按难度发 EasyAcceptQuest / HardAcceptQuest
function FSYQD.AcceptQuest(isHard, diffCN)
    local st, why = FSYQD.GetState(12)
    if not st then
        FLogWarn("票据任务", "接取跳过，未捕获到对话状态: " .. tostring(why))
        ShowNotification("票据任务", "未捕获到对话状态，已跳过自动接取（请手动点选）。", "WARN", 4)
        return false
    end
    local prevSeq = tonumber(st.seq) or 0
    -- 第 1 包：当页若有 "Quest"（入口页/领奖页共用同一个按钮），先进接取页
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
    -- 第 2 包：接取页按难度选；下标与第 4 参都从当页算
    local wantTag = isHard and "HardAcceptQuest" or "EasyAcceptQuest"
    if FSYQD.IndexOf(st, wantTag) then
        local ok2, why2 = FSYQD.Fire(wantTag, 12)
        if ok2 then
            ShowNotification("票据任务", string.format("已按真实协议提交接取请求（%s）。", tostring(diffCN or (isHard and "困难" or "简单"))), "SUCCESS", 4)
            return true
        end
        FLogWarn("票据任务", "接取发包失败(" .. tostring(why2) .. ")，退回 UI 点击")
        -- [误点防护] #77 第 1 项是 "Accept Easy Quest"，只给 "quest" 会被子串匹配到第 1 项 → 必须用完整按钮文本
        AutoClickDialogueOption({isHard and "accept hard quest" or "accept easy quest"}, true)
        return false
    elseif FSYQD.IndexOf(st, "Close") then
        ShowNotification("票据任务", "当前是任务进行中/奖励页，无需再接取。", "INFO", 4)
    else
        ShowNotification("票据任务", "当前对话页没有接取选项。", "WARN", 4)
    end
    return false
end

-- 按真实协议领奖：点当页的 "Quest" 选项（#69），失败退回 UI 点击，然后关掉奖励页
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
        -- 收尾关窗：奖励页只有 *Leave*（#74），关窗是纯客户端动作、零出向包（#74→#75 间隔 1.927s 且中间 0 条出向）
        task.delay(1.2, function()
            if not isRunning then return end
            local st2 = FSYQD.GetState(12)
            if st2 and FSYQD.IndexOf(st2, "Close") and not FSYQD.IndexOf(st2, "Quest") then
                -- 关键词故意写 "*leave*"：写 "leave" 会命中 AutoClickDialogueOption 的 wantExit 分支，把候选界面扩大到全部 fallbackGuis
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

-- 打开票据任务员 (Quest Giver) 对话框
--   第二参 manualNotify：手点时弹提示；第三参 autoAccept：顺带按真实协议把任务接掉（默认不传 = 只开对话框）
--   抓包链路：#75(Quest/Nevermind 页) --#76 "Quest"--> #77(接取页) --#78 "HardAcceptQuest"--> #81 "You started the Hard Ticket questline!"
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
        -- [审计-8] 与同页另外两个入口保持一致：非空闲（钓鱼/搏斗中）不立刻微瞬移去对话，
        -- 交给 0.25s 低频调度器的自动票据周期（空闲后自然执行，见 14681）
        if not FishGate or (FishGate.IsIdle and FishGate.IsIdle()) then
            task.spawn(function()
                local diffArg = QuestDiffMap[Config.TicketDifficulty] or "Easy"
                RunTicketQuestAction(diffArg, true)
            end)
        else
            ShowNotification("票据任务", "当前正在钓鱼/搏斗，空闲后会自动执行", "WARN", 4)
        end
    end
end, "AutoTicketQuest")
createDropdownRow(questCard, "难度", "票据任务难度标识 (简单 / 困难)", {"简单", "困难", "Easy", "Hard"}, Config.TicketDifficulty, function(v)
    Config.TicketDifficulty = v
end, "TicketDifficulty")
-- [UI-DEP] 票据难度 只在「AutoTicketQuest」开启后才有意义
DashUI.BindUIParent(UIControls["TicketDifficulty"] and UIControls["TicketDifficulty"].frame, {"AutoTicketQuest"})
createButtonRow(questCard, "接受并提交票据任务(简单)", "直接打开票据任务员对话框（不自动关窗、不收起面板）", "执行简单", function()
    Config.TicketDifficulty = "简单"
    if UIControls["TicketDifficulty"] and UIControls["TicketDifficulty"].Set then
        pcall(UIControls["TicketDifficulty"].Set, "简单", true)
    end
    RunTicketQuestAction("Easy", true, true)   -- 第三参 autoAccept：真的去接任务
end)
createButtonRow(questCard, "接受并提交票据任务(困难)", "直接打开票据任务员对话框（不自动关窗、不收起面板）", "执行困难", function()
    Config.TicketDifficulty = "困难"
    if UIControls["TicketDifficulty"] and UIControls["TicketDifficulty"].Set then
        pcall(UIControls["TicketDifficulty"].Set, "困难", true)
    end
    RunTicketQuestAction("Hard", true, true)   -- 第三参 autoAccept：真的去接任务
end)

local dailyCard = createCollapsibleGroup(tabQuests, "每日任务与奖励", false)

createButtonRow(dailyCard, "领取每日任务", "打开票据任务员对话，按真实协议领取已完成任务（ChooseDialogueOption）", "领取", function()
    if isClaimingDailyTask and (tick() - FSYC.dailyTaskLockAt) < 30 then
        ShowNotification("每日任务", "正在顺序领取中，请稍候...", "WARN")
        return
    end
    -- 领奖要打开 NPC 对话（可能走微瞬移引擎），钓鱼/搏斗/卖鱼途中会打断；与其它后台业务共用同一把闸：非空闲态直接拒绝
    if FishGate and FishGate.IsIdle and not FishGate.IsIdle() then
        ShowNotification("每日任务", "当前正在钓鱼/搏斗，已跳过领奖以免打断。请空闲后再点。", "WARN", 4)
        return
    end
    isClaimingDailyTask = true
    FSYC.dailyTaskLockAt = tick()
    task.spawn(function()
        -- 【协议事实】ClaimQuest / ClaimDailyQuest / DailyQuest 三个远程不存在：pcap3(170) + pcap(2987) + pcap2(1930) 共 0 命中，
        -- 禁止自创签名连发；领奖的唯一真实通道是对话选项 #68 StartDialogue → #69 ChooseDialogueOption(..., 1, "Quest", ...)
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
-- [UI-DEP] 领取延迟 只在「AutoClaimDaily」开启后才有意义
DashUI.BindUIParent(UIControls["DailyClaimDelay"] and UIControls["DailyClaimDelay"].frame, {"AutoClaimDaily"})

createButtonRow(dailyCard, "立即领取第1到7天", "批量领取所有7天每日奖励", "领取全部", function()
    if isClaimingDailySign and (tick() - FSYC.dailySignLockAt) < 30 then
        ShowNotification("每日奖励", "正在顺序领取签到中，请勿连点！", "WARN")
        return
    end
    isClaimingDailySign = true
    FSYC.dailySignLockAt = tick()
    task.spawn(function()
        pcall(function()
            if Events then
                local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
                if dailyRem then
                    local delaySec = math.max(0.4, DashUI.ClampNum(Config.DailyClaimDelay, 0.3, 2, 0.5))
                    local abortedByBusy = false
                    for day = 1, 7 do
                        if not isRunning then break end
                        -- [V15.46] 每天最多等 120s 空闲；等待期间续期互斥锁，超时仍未空闲则中止本轮领取，绝不在搏斗中途发签到包
                        local idleDeadline = tick() + 120
                        while isRunning and tick() < idleDeadline and FishGate and not FishGate.IsIdle() do
                            FSYC.dailySignLockAt = tick()
                            task.wait(0.3)
                        end
                        if not isRunning then break end
                        if FishGate and not FishGate.IsIdle() then
                            abortedByBusy = true
                            break
                        end
                        FSYC.dailySignLockAt = tick()
                        local okDay, reasonDay = SafeFireOneRemote(dailyRem, day)
                        if not okDay and reasonDay ~= "rate_limited_or_backoff" then break end
                        task.wait(delaySec)
                    end
                    if abortedByBusy then
                        ShowNotification("每日奖励", "等待钓鱼/搏斗空闲超时(120s)，已暂停本次领取以免打断战斗。", "WARN")
                    else
                        ShowNotification("每日奖励", "已按安全间隔顺序尝试领取 1~7 天！", "SUCCESS")
                    end
                else
                    ShowNotification("每日奖励", "未找到每日奖励远程事件，领取失败。", "WARN")
                end
            else
                ShowNotification("每日奖励", "游戏远程事件尚未就绪，请稍后重试。", "WARN")
            end
            -- 签到收尾等待 2.5s（HRandomWait 2.5±0.45；仅加长远程返回等待，不是检测窗口）
            HRandomWait(2.5, 0.45)
        end)
        isClaimingDailySign = false
    end)
end)

-- NPC 对话与一键传送 (每行均配【传送】+【对话】双按钮，解决远距离岛屿流式卸载问题)
local npcTalkCard = createCollapsibleGroup(tabQuests, "NPC 对话与传送 (27 位)", false)

for _, npcSpec in ipairs(ImportantDialogueNPCs) do
    createNPCDualActionRow(npcTalkCard, npcSpec.cnName, npcSpec.desc, function()
        TeleportToNPCSpec(npcSpec)
    end, function()
        OpenRemoteNPCDialogue(npcSpec, false)
    end)
end

-- NPC 任务 (自动把鱼给猴子等专项 NPC 提交任务)
local npcQuestSubCard = createCollapsibleGroup(tabQuests, "NPC任务")

local MonkeyNPCSpec = {
    -- 显示名按用户要求用「傻子」；aliases 里 Monkey 系列必须全部保留，改名不会把匹配改坏
    cnName = "傻子",
    internalName = "Monkey",
    aliases = {"Monkey", "MonkeyKing", "WuKong", "Ape", "Khỉ", "Vua Khỉ", "Tôn Ngộ Không", "Hầu Vương", "Khi", "Vua Khi", "猴子", "猴王", "孙悟空", "千金台",
        "傻子", "Dumb Guy", "DumbGuy", "笨蛋"},
    fallbackPos = nil,
}

local monkeyCtl = { running = false, at = 0, thread = nil }
FSYC.monkeyCtl = monkeyCtl
-- 自动向猴子 NPC 发起远程对话并批量提交鱼类完成收集任务
RunGiveFishToMonkeyBatch = function()
    if not isRunning then return end
    -- 按协程句柄判定，避免「15s 超时自愈」再起一条协程导致同一批鱼被重复提交
    if monkeyCtl.running then
        local th = monkeyCtl.thread
        if th == nil then
            -- 拿不到协程句柄时退化回 15s 时间戳兜底
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
        selfThread = coroutine.running()
        monkeyCtl.thread = selfThread
        pcall(function()
            if FishGate and not FishGate.IsIdle() then return end
            local maxGive = DashUI.ClampNum(Config.MonkeyGiveCount, 10, 500, 100)
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
            -- [保守优先] 兜底包：对话检测失败(postDialogueCallback 被 dialogueOpened 门控跳过)时仍能交出鱼。
            -- FireGiveMonkeyRemoteOnce 内部 firedGiveRemote 是一次性闸，所以 0.25s 与 1.1s 两条路径合计只发 1 包，不会翻倍。
            task.delay(1.1, FireGiveMonkeyRemoteOnce)
        end)
        pcall(function() task.wait(2.4) end)
        -- 只允许「自己这条协程」清标记，防止两条协程互相覆盖
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
-- [UI-DEP] 给鱼数量 只在「AutoGiveMonkey」开启后才有意义
DashUI.BindUIParent(UIControls["MonkeyGiveCount"] and UIControls["MonkeyGiveCount"].frame, {"AutoGiveMonkey"})

end)() end -- end of Quests UI scope
end -- end of NPC Engine, God & Quests Scope

-- ==========================================
-- 【模块 20：【传送】页面构建（自定义坐标点管理、10大特殊NPC实时雷达传送、岛屿/商人/秘密鱼竿/玩家传送）】
-- 作用：自定义坐标点(JSON 持久化) + 10 大特殊 NPC 实时状态与射线安全落地 + 13 座岛屿/Boss领域/标迪鱼竿商人(8岛)/6 把秘密鱼竿/玩家传送
-- ============================================================================
do
-- 常用传送置顶：高频目的地固定在传送页最上方，打开即可「点一下就走」
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

-- [硬性要求] 自定义传送点 = 加载期一次性预建 100 行静态池（与 CustomTPs 上限一致），运行期只更新文本/显隐；
-- 禁止回到「每次增删 Destroy 后重建整批行 + 重复 RegisterThemeUpdater」——会让 themeUpdaters 无限增长、ApplyTheme 越来越慢
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
        -- 回调按行号实时读取 CustomTPs，避免旧版闭包捕获过期行数据
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
    -- 全部静态行共用一套主题 updater（数量恒定，不再随增删增长）
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

-- 刷新自定义传送点列表：只改静态行的文本与显隐，不再创建/销毁任何 UI 节点
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
    -- 行显隐变化后刷新当前标签页画布高度（放在 defer 里避免与 UIListLayout 当帧重排相互打断）
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
    -- [UI-CONFIRM] 会一次性删掉全部自定义点并写盘，不可撤销
    local function DoClear()
        CustomTPs = {}; SaveCustomTPs(); RefreshCustomTPs(); coordLabel.Text = "当前坐标: 点击右侧读取"; ShowNotification("已清空", "所有自定义传送点已删除", "SUCCESS")
    end
    if DashUI.Confirm then
        local tpCount = (type(CustomTPs) == "table") and #CustomTPs or 0
        DashUI.Confirm("清空全部自定义传送点？",
            string.format("共 %d 个自定义坐标会被删除并立即写入配置文件。此操作不可撤销。", tpCount),
            "确认清空", DoClear)
        return
    end
    DoClear()
end, "danger")
RefreshCustomTPs()

end -- end of Sell/Boss/God/Quests/Shop/CustomTP scope

do
local liveNPCCard = createCollapsibleGroup(tabTeleports, "特殊NPC实时传送 (神灵/道士/茅山/四圣兽)", false)
-- 创建特殊 NPC 实时监控行（显示刷新状态与距离，点击时通过向下射线检测安全落点后传送）
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
        -- 1. 严格校验目标坐标：针对三岛神灵等拥有专属 fallbackPos 的固定实体，
        -- 若检测到的 data.pos 距离其专属岛屿中心超过 450 米，视为非法误判，重置异常数据并回退至安全岛屿坐标
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

                -- 安全落脚点：站在目标正前方 2.5 米处（高度 +2.5 米贴合角色站立重心），严禁叠加沿来向延伸的 dir * 6 悬崖外推，
                -- 更严禁使用头朝脚底垂直俯冲的 CFrame.new(pos + (0,3,0), pos) 导致角色脸朝地趴倒卡住 2 秒！
                local standOffset = Vector3.new(0, 0, 2.5)
                local baseDest = targetDest
                if data.inst and data.inst.Parent and isLiveTarget then
                    local instPos = GetNPCPosition(data.inst)
                    if instPos and (not data.fallbackPos or (instPos - data.fallbackPos).Magnitude <= 450) then
                        baseDest = instPos
                    end
                end
                local targetPos = baseDest + standOffset + Vector3.new(0, 2.5, 0)

                -- 从落脚点垂直上方探测地面碰撞体，精准校准站立高度
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
                    -- 若前方 2.5 米处未命中地面，则直接在目标中心点垂直向下探测地面
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
end, nil, 64)
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
-- 【模块 21：环境光照控制 (ApplyLightingSettings) 与【视觉】【移动】【配置文件】页面构建】
-- 作用：1) ApplyLightingSettings() 事件驱动调节全亮/去雾去粒子/关阴影，已移出每帧渲染循环；
--       2) 构建【视觉】页（7 类实体 ESP + 鱼红圈 + 省电模式）、【移动】页（现仅剩防挂机与稳定性）与【配置文件】页。
-- ============================================================================
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
    -- [方案A] 雷达关档时 ESP 根本扫不到目标：这里给一次明确提示，避免用户以为脚本坏了
    if v and Config.RadarMode == "关" then
        ShowNotification("提示", "雷达总开关为「关」，不会扫描目标，ESP 暂时看不到东西；请把雷达切到「静默」或「全开」", "WARN", 5)
    end
    if DashUI._refreshESPNow then
        pcall(DashUI._refreshESPNow, catKey, v, labelTitle)
    end
end
-- [方案A / 雷达总开关] 放在所有 ESP 开关之前：关掉后连扫描都不做，下面 7 个 ESP 开关等于无效
createDropdownRow(espCard, "雷达总开关",
    "全开=扫描+弹窗+ESP｜静默=照常扫描但不弹窗｜关=完全不扫描、不弹窗、不挂ESP、不预加载岛屿、不自动跳服",
    {"全开", "静默", "关"}, Config.RadarMode, function(v)
    Config.RadarMode = v
    if DashUI._radarApplyMode then pcall(DashUI._radarApplyMode, v) end
end, "RadarMode")   -- 第 8 参是「选项按钮池大小」不是宽度：3 选项用默认 8 即可，传大会白建一堆隐藏按钮
createToggleRow(espCard, "神灵ESP", "高亮三座神灵祭坛与活跃神灵 (跨全图穿墙显示)", Config.ESP_GodSpirit, function(v) NotifyAndRefreshESP("GodSpirit", v, "神灵ESP") end, "ESP_GodSpirit")
createToggleRow(espCard, "船只ESP", "高亮已生成的船只位置与距离", Config.ESP_Boats, function(v) NotifyAndRefreshESP("Boats", v, "船只ESP") end, "ESP_Boats")
createToggleRow(espCard, "茅山ESP", "高亮茅山商人/茅山鱼竿位置", Config.ESP_Maoshan, function(v) NotifyAndRefreshESP("Maoshan", v, "茅山ESP") end, "ESP_Maoshan")
createToggleRow(espCard, "道士ESP", "高亮道士商人位置（流动商人）", Config.ESP_Taoist, function(v) NotifyAndRefreshESP("Taoist", v, "道士ESP") end, "ESP_Taoist")
createToggleRow(espCard, "隐藏商人ESP", "高亮傻子隐藏商人 (Dumb Guy) 位置", Config.ESP_DumbGuy, function(v) NotifyAndRefreshESP("DumbGuy", v, "隐藏商人ESP") end, "ESP_DumbGuy")
createToggleRow(espCard, "Boss ESP", "高亮恩佐/章鱼隐藏Boss/龙钓海/四圣兽生成点", Config.ESP_Boss, function(v) NotifyAndRefreshESP("Boss", v, "Boss ESP") end, "ESP_Boss")
createToggleRow(espCard, "玩家ESP", "高亮服务器内其他玩家及实时距离", Config.ESP_Players, function(v) NotifyAndRefreshESP("Players", v, "玩家ESP") end, "ESP_Players")
-- [UI-DEP] 七个 ESP 都依赖「雷达总开关 ≠ 关」：雷达关档时不扫描，ESP 开着也没有目标可显示。
-- 这里用函数谓词（而不是布尔键），因为 RadarMode 是三态字符串。
local function RadarNotOff() return Config.RadarMode ~= "关" end
for _, espKey in ipairs({"ESP_GodSpirit", "ESP_Boats", "ESP_Maoshan", "ESP_Taoist", "ESP_DumbGuy", "ESP_Boss", "ESP_Players"}) do
    local espCtrl = UIControls[espKey]
    if espCtrl and espCtrl.frame then DashUI.BindUIParent(espCtrl.frame, {RadarNotOff}) end
end
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

-- 原「玩家移动」卡（步行加速/速度值/飞行/飞行速度/无限跳跃/水上行走/穿墙）已整块删除；下方「防挂机与稳定性」卡不动

local stabCard = createCollapsibleGroup(tabPlayer, "防挂机与稳定性")
createToggleRow(stabCard, "防挂机", "防止Roblox 20分钟空闲断开", Config.AntiAFK, function(v) Config.AntiAFK = v end, "AntiAFK")
createToggleRow(stabCard, "被踢自动重连", "断线或报错弹窗时自动重连服务器", Config.AutoRejoin, function(v) Config.AutoRejoin = v end, "AutoRejoin")
createButtonRow(stabCard, "查看运行状态", "显示各子系统最近一次状态（钓鱼/卖鱼/传送/重连），用于排查", "查看", function()
    local text = DashUI.GetStatusText()
    if text == "" then text = "暂无状态" end
    -- 全文仍走 print（不受 DebugLog 门控，F9 控制台一定看得到）
    pcall(function() print("[FSY][运行状态] " .. text) end)
    -- [UI-STATUS] 原来只截前 26 字（永远截在第一个字母序的条目上，基本等于没用）。
    -- 改成「阻塞优先」排序：失败/异常排最前，其次延后/暂停，再按最近更新排序。
    -- 通知卡正文容量有限（约 2 行），所以只取前 2 条；完整清单仍在控制台。
    local rows = {}
    for k, v in pairs(DashUI._status) do
        rows[#rows + 1] = { k = tostring(k), t = tostring(v and v.text or ""), at = tonumber(v and v.at) or 0 }
    end
    local function Pri(r)
        if r.t:find("失败", 1, true) or r.t:find("异常", 1, true) then return 0 end
        if r.t:find("延后", 1, true) or r.t:find("暂停", 1, true) then return 1 end
        return 2
    end
    table.sort(rows, function(a, b)
        local pa, pb = Pri(a), Pri(b)
        if pa ~= pb then return pa < pb end
        return a.at > b.at
    end)
    local lines = {}
    for i = 1, math.min(#rows, 2) do
        lines[#lines + 1] = rows[i].k .. "：" .. rows[i].t
    end
    local body = (#lines > 0) and table.concat(lines, "\n") or "暂无状态"
    if #rows > 2 then body = body .. string.format("\n（共 %d 项，详见 F9 控制台）", #rows) end
    local lv = (DashUI.GetRunLevel and DashUI.GetRunLevel()) or "idle"
    local lvCN = (lv == "err") and "有失败" or (lv == "warn") and "有阻塞" or (lv == "ok") and "运行中" or "空闲"
    ShowNotification("运行状态 · " .. lvCN, body, (lv == "err") and "ERROR" or "INFO", 10)
end)

-- ==========================================
-- 配置页面
-- ==========================================
-- ============================================================================
-- 【V15.1 双端：设备与输入】下拉选项池加载期一次性预建，运行期不 Instance.new 任何节点；切换模式只改输入路由与交互反馈
-- ============================================================================
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
        -- 隔离开关本身立即生效：强制重绑一次，让按钮只挂当前模式需要的通道
        ModeCtl.Apply(Config.DeviceMode, { force = true })
    end, "InputIsolation")

createSliderRow(devCard, "按下归并窗口",
    "一次按下后多少毫秒内的点击事件都算同一次操作（Activated / 鼠标点击 / 触屏兜底 三通道去重依据）",
    200, 1000, Config.InputDedupeMs, false, "ms", function(v) Config.InputDedupeMs = v end, "InputDedupeMs")

createSliderRow(devCard, "发包去重窗口",
    "同一 Remote 且参数完全相同的包，在此窗口内只放行一次；0 = 关闭（战斗域仍固定保留 10ms，用于合并三通道齐发造成的重复包）",
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

-- [折叠面板] 批量展开/折叠：逐个切换加载期登记的分组，随后只重算一次当前页画布
-- 第三个参数 skipPersist=true：这是「临时的看图操作」，只影响本次会话，不写盘、不动 Config.UIGroupState
local function ApplyAllSectionsExpanded(wantExpanded, tipText)
    for i = 1, #collapsibleSections do
        local sec = collapsibleSections[i]
        if sec and sec.section and sec.section.Parent then
            sec.SetExpanded(wantExpanded, false, true)
            -- skipPersist 不更新 initialExpanded，而搜索清空时按它恢复 → 必须手动同步，否则「全部折叠→搜索→清空」后一半分组会弹开
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

-- ============================================================================
-- 【静态搜索过滤】输入即过滤：只切 Visible / 文本颜色，不新建、不销毁任何节点
-- 规则：① 标题+描述+分类名+分组名 小写子串匹配，空格分隔多词取「与」；② 命中行高亮并自动展开分组；③ 未命中分组/区块隐藏；
--       ④ 无命中时跳到命中最多的分类；⑤ 清空后恢复各组折叠记忆。性能：O(行数+分组数)，180ms 防抖，无文本变化不写 Text
-- ============================================================================
local function SectionHasVisibleRow(body)
    for _, child in ipairs(body:GetChildren()) do
        if child:IsA("GuiObject") and child.Visible then return true end
    end
    return false
end

-- 应用搜索过滤并返回命中数量（内部实现，统一由下方 ApplySearchFilter 守卫包装调用）
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

    -- 1) 逐行匹配：切显隐 + 命中高亮
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
                -- 行级 HitBar 已删除（rec.hl=nil）；仅分组标题/下拉行仍带竖条，保留其高亮
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

    -- 2) 分组显隐 + 命中自动展开（倒序：先子后父，父分组判断才准确）
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

    -- 3) 区块显隐：有命中分组才显示；无分组的数据区块（运行概览）在有搜索词时整体隐藏
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

    -- 4) 自动定位：跳到「命中最多」的分类（当前分类已是第一则不跳，避免边打字边乱跳）
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

    -- 清空搜索词恢复常规视图时，重新应用父开关依赖显隐，防止父开关关闭的隐藏子项被无条件展露
    if nTok == 0 and DashUI.ApplyUIDeps then
        DashUI.ApplyUIDeps()
    end
    if changed > 0 and DashUI.refreshCanvas then
        DashUI.refreshCanvas()
    end
    searchState.applying = false
    return hits
end

-- 守卫包装：内部实现任一环节抛错时复位 applying，避免一次异常永久禁用搜索
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
    searchState.box:GetPropertyChangedSignal("Text"):Connect(SafeConnect("搜索框输入", function()
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
        if searchDebounce then activeThreads[searchDebounce] = true end
    end))
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

-- [调试日志] 静态开关：默认开启，输出 [FSY] 前缀运行日志到执行器控制台（同标签 2 秒内自动合并，不刷屏）
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
        -- [V15.1 双端] 导入的配置可能改了运行模式：显式应用一次（静默同步不会触发下拉回调）
        ModeCtl.Apply(Config.DeviceMode, { force = true })
        ShowNotification("配置已加载", "配置文件 'default.json' 加载并同步成功！", "SUCCESS")
        if UpdateMainFrameScale then UpdateMainFrameScale(true) end
    else
        ShowNotification("配置错误", "未找到已保存的配置文件。", "WARN")
    end
end)
createToggleRow(profCard, "注入时自动加载配置", "启动时自动加载配置", Config.AutoLoadProfile, function(v) Config.AutoLoadProfile = v end, "AutoLoadProfile")

local credCard = createCollapsibleGroup(tabProfiles, "会话操作")
-- [UI-CONFIRM] 原来这里直接 UnloadScript，绕过了右上角 [X] 的确认弹窗：同一个危险动作两条路径待遇不一致
createButtonRow(credCard, "卸载脚本", "干净地卸载脚本并恢复所有设置", "卸载", function()
    if DashUI.Confirm then
        DashUI.Confirm("确认卸载脚本？", "退出后将停止挂机并恢复游戏设置，可随时重新注入脚本。", "确认卸载", UnloadScript)
        return
    end
    UnloadScript()
end, "danger")

-- UI 构建完成后仅刷新当前可见标签页 Canvas，其余标签页在 SwitchTab / Visible 变化时按需刷新
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
end)() end -- end of Tab & Feature Construction Scope

-- ============================================================================
-- 【模块 22：鱼竿工具精准识别 (IsToolFishingRod) 与持竿状态缓存判定 (IsCharacterHoldingFishingRod)】
-- 作用：区分手中是鱼竿还是钓上来的鱼（防 Fish 误判）；0.25s TTL 缓存 + ChildAdded/Removed 失效，切鱼/收竿即暂停抛竿。
-- 精准判定某个 Tool/Model 是否为鱼竿（绝不把名字带 "Fish" 的鱼类当成鱼竿！）
IsToolFishingRod = function(inst, pData)
    if not inst then return false end
    pData = pData or GetPlayerData()
    local equippedRodName = pData and DashUI._readValueBase(pData:FindFirstChild("FishingRod"), nil) or nil
    local rawName = (inst.Name or "")
    if equippedRodName and equippedRodName ~= "" and rawName == equippedRodName then
        return true
    end
    local low = tqLc(rawName)
    -- [本地化] 补越南语 Cần câu / can cau 与繁体 釣竿 / 魚竿（allRods 目前是英文名，英文环境行为不变）
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

-- 持竿状态缓存：ChildAdded/Removed 时失效，避免 Heartbeat 每帧遍历 GetChildren
local cachedHoldingRodTime = 0
do
local cachedHoldingRod = true
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
end

-- attrFishing/attrMinigame 必须先于 StopLingeringFishingAnimations 声明，否则函数内读到全局 nil，「钓鱼/小游戏期间不停动画」的守卫恒真
local attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false

-- 停止并清理角色身上残留的钓鱼/持竿等 Action 优先级卡死动画，恢复正常行走与站立姿态
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

            -- 严格保护核心基础运动动画（站立 idle / 行走 walk / 跑步 run / 游泳 swim / 攀爬 climb / 坠落 fall），绝不误停
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
                    -- 手中未装备任何 Tool，且未在钓鱼：任何高优先级 Action/Tool/Fishing 动作均属于脱手残留，必须停止
                    shouldStop = isExplicitFishing
                        or (prio == Enum.AnimationPriority.Action)
                        or (prio == Enum.AnimationPriority.Action2)
                        or (prio == Enum.AnimationPriority.Action3)
                        or (prio == Enum.AnimationPriority.Action4)
                        or tName == "animation" or aName == "animation" or tName == "toolnoneanim" or tName == "toolnone" or tName == ""
                elseif not holdingRod and not attrFishing and not attrMinigame then
                    -- 手中拿的不是鱼竿且未在钓鱼：只要命中钓鱼/持竿特征动作即停止
                    shouldStop = isExplicitFishing
                end

                if shouldStop then
                    -- [Delta 减负 M8] 直接向 pcall 传入方法与实例参数，消除每次停止残留动画时新建匿名闭包。
                    pcall(track.Stop, track, 0.12)
                    stoppedCount = stoppedCount + 1
                end
            end
        end
    end
    return stoppedCount > 0
end
DashUI._stopLingeringFishingAnimations = StopLingeringFishingAnimations

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
    return false
end

-- 保持 MainGui / Fisher_GUI 原生界面结构纯净，启动时不篡改任何子面板 Visible 状态，确保钓鱼按钮与 Boss 弹窗 100% 原生正常工作

SyncUIWithConfig()
task.spawn(function()
    task.wait(0.3)
    if isRunning and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) and TryFavoriteProtectedFish then
        pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
    end
end)

-- ============================================================================
-- 【模块 22-B：钓鱼状态闸门 (FishingStateGate) —— 所有自动类功能的唯一状态入口】
-- 为什么必须加这一层：旧版各自动功能各自拿一堆弱信号拼出 isMinigame 就开火，其中至少三个是「会残留、会常亮」的软信号：
--   cachedFUI.Visible（移动端 HUD 布局下可能长期可见）、cachedIsHooked（收竿后仍有缓存窗口）、activeSlamBtn（猛击圆钮
--   缓存，GetCachedSlamButton 有扫描节流与 TTL）。任意一个为真，0.05~0.22s 节拍的分支就会在玩家已收竿站着不动时
--   持续发包 —— 这就是「我没在钓鱼，脚本却一直在发包」的根因。本模块把这些信号收敛成一台带滞回的状态机，对外 5 个查询：
--   Update(now,s) 每帧采样（O(1)，不建表/不遍历/不分配，入参复用一张表）、IsFight() 有效搏斗中（只有它为真才发战斗包）、
--   IsIdle() 既没钓鱼也没搏斗、AllowCombat() 战斗包总闸（累计拦截数）、AllowAutoCast(now) 自动抛竿总闸。
-- 设计约束（改动时逐条遵守）：
--   1) 只减不增：3 个强信号全是旧 isMinigame 合成式的子集，状态机「进入搏斗」的每一帧旧版一定也在战斗。三个例外：
--      退出方向有 0.80s 宽限（旧版单帧消失就停手，这里多撑最多 0.8s 抗抖动）；Config.FishingGate=false 完全退化为旧行为；
--      Config.FishingGateLoose=true（兼容模式，默认关）额外把「面板可见 且（猛击钮/鱼线在水里）」当作搏斗 —— 这一支
--      确实会在旧版一包不发时发包，是用户显式选择的放宽，不是默认行为。
--   2) 判定只用 3 个游戏侧权威信号：Minigame 属性、Boss 拔河条、自己的鱼（UserId_PlayerHealth）。绝不单独采信 Fishing
--      面板可见 / 猛击圆钮可见 / 捕获进度条可见：面板在移动端 HUD 可能长期可见；猛击圆钮缓存没有 TTL，且正是
--      cachedPerfectBtn 指向的实例（拿它当证据=自证循环）；进度条压根不在旧 isMinigame 合成式里。
--   3) 防幽灵鱼：连续 240s 没拿到任何硬信号 → 判定鱼模型没被清理，强制收场并锁定到「鱼先消失一次」。
--   4) 隔离与可观测：整体是工厂函数，实例只挂在上层一个 local 上，不写全局变量；拦截计数 + 状态快照可从 DashUI 读取。
-- 后续修改指引：放宽/收紧判定只改 Update() 里的 hardSignal / looseSignal 两行；抗抖时间改上面的 5 个内部常量
--   （FIGHT_EXIT_GRACE / ACTIVE_EXIT_GRACE / QUIET_AFTER_EXIT / WARN_BLOCK_STREAK / MAX_GHOST_FIGHT，均从 FSYC.Tunables 读取）。
-- ============================================================================
-- [FISH-GATE-BEGIN]
local function CreateFishingStateGate(deps)
    deps = deps or {}
    local cfg = deps.config or {}
    local logFn = deps.log
    local notifyFn = deps.notify

    -- ---- 内部常量（统一从顶部 FSYC.Tunables 读取，支持集中调优） ----
    local tun = FSYC.Tunables or {}
    local FIGHT_EXIT_GRACE = tun.GateFightExitGraceSec or 0.80   -- 战斗信号全部消失后仍按"搏斗中"处理的宽限
    local ACTIVE_EXIT_GRACE = tun.GateActiveExitGraceSec or 0.40 -- 钓鱼会话退出宽限
    local QUIET_AFTER_EXIT = tun.GateQuietAfterExitSec or 0.25   -- 退出战斗后的静默窗
    local WARN_BLOCK_STREAK = tun.GateWarnBlockStreakSec or 6.0  -- 持续拦截告警阈值
    local MAX_GHOST_FIGHT = tun.GateMaxGhostFightSec or 240      -- 幽灵鱼强制收场上限（秒）

    local G = {
        fight = false,          -- 滞回后的"有效搏斗"
        lastFightAt = 0,        -- 最近一次出现搏斗信号的时刻
        endedAt = 0,            -- 最近一次退出搏斗的时刻（诊断用）
        active = false,         -- 滞回后的"有效钓鱼会话"
        lastActiveAt = 0,
        instant = false,        -- 瞬时"确实在水里/在搏斗"（无宽限，仅用于抛竿互斥）
        rawFight = false,       -- 旧 isMinigame 合成值（关闭闸门时的回退语义 + 诊断用）
        quietUntil = 0,
        now = 0,                -- 最近一次 Update 的时刻（AllowCombat 判静默窗用，避免额外传参）
        blockStreakAt = 0,      -- 连续拦截计时起点
        fightStartAt = 0,       -- 本场搏斗开始时刻
        lastHardAt = 0,         -- 最近一次拿到硬信号（Minigame 属性 / Boss 条）的时刻
        hookedBlock = false,    -- 幽灵鱼收场后置真：必须等鱼消失、或打一场有硬信号的战斗，才允许再进
        warned = false,
        reason = "空闲",
        -- [统计] 供自检与 UI 展示：放行次数 / 拦截次数 / 进出战斗次数（注意：一次猛击会走 4 条通道，计数>实际包量）
        stats = { allow = 0, block = 0, enter = 0, exit = 0 },
    }

    -- 采样快照：只读镜像，供 UI 与排错使用，不参与判定（每帧复用同一张表，零分配）
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

    -- 每帧采样一次：s 由调用方复用（同一张表反复写字段），本函数不保留引用；字段全按「真值」语义读，缺字段当 false，不因某个 UI 控件没扫到就抛错。
    function M.Update(now, s)
        if type(now) ~= "number" then return end
        s = s or snap
        G.now = now

        -- 1) 采样（顺手做一次类型收敛，防止上游把 nil/非布尔塞进来）
        snap.attrFishing = (s.attrFishing == true)
        snap.attrMinigame = (s.attrMinigame == true)
        snap.hooked = (s.hooked == true)
        snap.bossBar = (s.bossBar == true)
        snap.fui = (s.fui == true)
        snap.slam = (s.slam == true)
        G.rawFight = (s.rawFight == true)

        -- 2) 判定「这一帧是否真的在搏斗」：三个信号全部来自游戏侧，且都同时出现在旧 isMinigame 的合成式里 → 保证「只减不增」：
        --      · Minigame 属性（服务端同步的战斗状态位，最权威、会自己置假） · Boss 拔河条（BossFightBar 可见，无属性时兜底）
        --      · 自己的鱼（Fishes 下出现 <自己UserId>_PlayerHealth，只代表本人）
        --    【重要】面板可见(cachedFUI.Visible) 与 猛击圆钮 一律不采信：面板在移动端 HUD 布局下可能长期可见，猛击圆钮
        --      缓存没有 TTL 且正是 cachedPerfectBtn 指向的那个实例（拿它当证据=自证循环）；单独采信任何一个都会让闸门
        --      「永久搏斗中」，那正是旧版空转发包的病根。
        local hardSignal = snap.attrMinigame or snap.bossBar
        -- 兼容模式（可选，默认关）：把「Fishing 面板可见 + (猛击钮可见 或 鱼线在水里)」也算搏斗，给既无 Minigame 属性、
        -- 也无自己的鱼/拔河条的鱼种或布局留后门；打开后等价于「旧判定 + 迟滞」，会重新出现一定量的空转发包，故默认关闭。
        local looseSignal = (cfg.FishingGateLoose == true) and snap.fui and (snap.slam or snap.attrFishing)
        -- hookedBlock：上一场被判定为"幽灵鱼"之后要先解锁才允许重新进入（解锁条件见 3.6）
        local fightNow = hardSignal or (snap.hooked and not G.hookedBlock) or looseSignal
        if hardSignal then G.lastHardAt = now end

        -- 3) 进/出搏斗（进出都用"时刻差"，不做逐帧翻转，避免 60Hz 抖动把状态打成锯齿）
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

        -- 3.5) 兜底：连续 MAX_GHOST_FIGHT 都没有任何硬信号（Minigame 属性 / Boss 拔河条）→ 判定为鱼模型没被清理，强制收场。
        --      lastHardAt 每帧都会被硬信号刷新，所以真·长战斗（属性一直为真）绝不会被误伤。
        --      兼容模式打开时不参与此兜底（用户已明确选择宽松语义）。
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
        -- 3.6) 解锁：只认「鱼信号消失」。绝对不能用 hardSignal 解锁 —— 硬信号是「玩家跑去打别的东西」的信号，
        --      跟那条残留鱼没有任何关系；用它会顺手把幽灵鱼一起洗白（表现为每打完一场 Boss，残留鱼又被当成真鱼，
        --      于是再多出整整 MAX_GHOST_FIGHT 的空转发包窗口，实测 239.9s）。Boss 战本身不受影响：fightNow 里 hardSignal 独立放行。
        if G.hookedBlock and not snap.hooked then G.hookedBlock = false end

        -- 4) 钓鱼会话（鱼线在水里 / 正在搏鱼）。抛竿互斥与"空闲判定"用这一层。
        local activeNow = fightNow or snap.attrFishing
        if activeNow then
            G.lastActiveAt = now
            G.active = true
        elseif G.active and (now - G.lastActiveAt) > ACTIVE_EXIT_GRACE then
            G.active = false
        end

        -- 5) 瞬时状态（无宽限）：给「能不能再抛一竿」用，避免宽限期把抛竿节奏拖慢。
        -- 被判定为残留鱼之后，不允许它再通过 instant 把 AllowAutoCast 永久卡死，否则「收场只是不发包，却永远抛不了竿」。
        G.instant = snap.attrFishing or snap.attrMinigame or (snap.hooked and not G.hookedBlock)

        -- 6) 诊断：闸门拦了很久、但旧判定一直说在战斗 → 只告警一次（+ 一次界面提示），绝不自动放行（「宁可少发也不空发」；若确认确实在战斗，可关掉闸门开关自救）。
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

    -- 关闭闸门（用户主动关掉开关）时，退回旧语义，保证"关掉开关 = 完全还原旧行为"
    function M.IsFight()
        if not GateEnabled() then return G.rawFight end
        return G.fight
    end

    -- 旧版低频自动化的门是 "not isMinigame and not isFishing"；关闭闸门时必须完全等价，
    -- 因此这里把 attrFishing（= 瞬时里的一项）也一起否掉，否则卖鱼包会插进垂钓过程。
    function M.IsIdle()
        if not GateEnabled() then return (not G.rawFight) and (not G.instant) end
        return (not G.fight) and (not G.active)
    end

    -- 战斗域发包总闸：Slam / Charge / 进度包 / 节奏包 / 技能施法 / 小游戏回包 全部走这里
    function M.AllowCombat()
        if not GateEnabled() then
            G.stats.allow = G.stats.allow + 1
            return true
        end
        -- 采样新鲜度保护（fail-closed）：stepHeartbeat 在「角色缺失 / 重生中 / 切图」时会在 if not root or not hum then
        --   return end 处早退，早于本闸门的 Update()；这段窗口里 G.now 冻结、G.fight 仍保持上一帧的 true，
        --   于是原本「空闲零发包」会被陈旧状态放行（Slam / Charge / QTE 的 OnClientEvent 照发）。这里改为：超过 0.5s
        --   没拿到新采样就一律拒绝（0.5s 远大于调度器 0.15s / 省电 0.25s 的采样周期，正常搏斗不会被误拦）。
        local freshNow = tick()
        if G.now <= 0 or (freshNow - G.now) > 0.5 then
            G.stats.block = G.stats.block + 1
            return false
        end
        -- 退出战斗后的静默窗内同样拒绝：收竿那一瞬间最容易被"延迟执行的通道"补一包
        if G.fight and G.now >= G.quietUntil then
            G.stats.allow = G.stats.allow + 1
            return true
        end
        G.stats.block = G.stats.block + 1
        return false
    end

    -- 自动抛竿总闸：搏斗中、鱼线已在水里、刚退出战斗的静默窗内，一律不许再抛
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
        -- 锁定标记必须跟着「钓鱼中」一起显示：若 active 判在前面，只要鱼线还在水里就永远看不到「残留鱼已忽略」，自检时会以为一切正常。
        if G.active then return G.hookedBlock and "钓鱼中(残留鱼已忽略)" or "钓鱼中" end
        -- 残留鱼锁定：鱼节点还在、但已判定为幽灵鱼 → 正在按"没在战斗"处理
        if G.hookedBlock then return "空闲(残留鱼已忽略)" end
        return "空闲"
    end

    function M.GetBlockedCount() return G.stats.block end

    -- 一行诊断文本：状态 + 各原始信号 + 放行/拦截计数（UI 自检按钮 / 控制台排查用）
    function M.GetDebugLine()
        return string.format("状态=%s | 旧判定=%s | Minigame=%s 自己的鱼=%s Boss条=%s 面板=%s 猛击钮=%s 鱼线=%s | 放行=%d 拦截=%d 进=%d 出=%d",
            M.GetStateName(), tostring(G.rawFight),
            tostring(snap.attrMinigame), tostring(snap.hooked), tostring(snap.bossBar),
            tostring(snap.fui), tostring(snap.slam), tostring(snap.attrFishing),
            G.stats.allow, G.stats.block, G.stats.enter, G.stats.exit)
    end

    -- 角色重生 / 切图 / 重载时调用：清掉残留状态，避免带着上一张图的"搏斗中"进新图
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
        -- 统计清零：UI 与 GetDebugLine 都把 block 标注成「本局拦截」，若只增不减会跨图跨会话累积（一次猛击走 4~5 条通道
        -- 又会 +3~5），看到的数字既不是「本局」也不是「实际包量」。Reset 是重生/切图/重载的统一入口，在这里归零。
        G.stats.allow, G.stats.block, G.stats.enter, G.stats.exit = 0, 0, 0, 0
    end

    return M
end
-- [FISH-GATE-END]

-- 闸门实例：全脚本唯一，挂在 local 上（不新增全局变量）
FishGate = CreateFishingStateGate({ config = Config, log = FLog, notify = ShowNotification })
DashUI._fishGate = FishGate
-- 只读状态入口（挂在既有共享表 DashUI 上，不新增全局变量）；排查「为什么没放技能 / 空闲有没有在发包」直接看这一行
DashUI._fishGateStatus = function()
    local okLine, line = pcall(FishGate.GetDebugLine)
    if not okLine then return "闸门状态不可用" end
    -- _fishGateStatus 供 UI 自检按钮调用；下方 _fishGateBlocked 预留给控制台单独查询拦截计数
    local okN, n = pcall(FishGate.GetBlockedCount)
    return okN and (tostring(line) .. " ｜ 本局拦截=" .. tostring(n)) or tostring(line)
end
DashUI._fishGateBlocked = function()
    local okN, n = pcall(FishGate.GetBlockedCount)
    return okN and n or 0
end

-- 每帧采样的入参表：整份脚本只此一张，反复复用（避免每帧建表进 GC）
local fishGateSig = {
    attrFishing = false, attrMinigame = false, hooked = false,
    bossBar = false, fui = false, slam = false, rawFight = false,
}

-- ==========================================
-- 【模块 23：角色属性事件监听 (BindCharacterAttributes)、零 GC 穿墙零件缓存与断线自动重连】
-- 作用：AttributeChanged 事件驱动缓存 Fishing / CDForTheNextThrow / Minigame / Swimming 四大高频状态，消除每帧 GetAttribute；
--   缓存角色全身 BasePart 供穿墙循环零 GC 遍历；监听断线弹窗与传送失败事件实现 3 秒自动重连。
-- [作用域修复] 四个状态位的 local 声明已前移到 StopLingeringFishingAnimations 定义之前，全文仅此一处声明
do
-- 监听角色 AttributeChanged 信号，实时同步 Fishing / CDForTheNextThrow / Minigame / Swimming 状态位
local function BindCharacterAttributes(char)
    if attrCharConn then
        pcall(function() attrCharConn:Disconnect() end)
        attrCharConn = nil
    end
    attrFishing, attrCD, attrMinigame, attrSwimming = false, false, false, false
    -- [模块 22-B] 换角色/重生/切图时同步清空闸门，避免把上一张图的"搏斗中"带进新图
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
    -- 不加入 activeConnections：重生时会主动 Disconnect 并替换，避免数组里堆死连接
end

-- 绑定角色防倒地保护与手持工具/背包变化监听（用于持竿缓存失效与脱手后停动画）
local function CacheCharacterParts(char)
    -- 角色重生时先断开旧角色监听，避免每次重生都累积事件连接。
    for _, conn in ipairs(characterConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(characterConnections)
    cachedFishConstraint = nil
    if not char then return end
    -- 同一把工具/同一个 Backpack/同一个 Humanoid 只绑定一次（弱键表去重）；bindToolUnequip 需前置定义，供 char.ChildAdded 直接调用
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
    -- 角色加载/重生时立即禁用 FallingDown 与 Ragdoll 摔倒状态，监听状态变化实现 0 秒瞬时防倒地起身
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
        if not isRunning or not child then return end
        if child:IsA("Humanoid") then
            bindHumanoidAntiTrip(child)
        end
        -- 仅 Tool/Model 变化时失效持竿缓存，避免无关子项抖动
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
        if not isRunning or not child then return end
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
    -- 监听 Backpack 工具变化以实时失效持竿缓存（兼容角色重生后 Backpack 延迟挂载或重建）
    local function bindBackpackCacheInvalidation(bp)
        if not bp or not bp:IsA("Backpack") then return end
        if boundBackpacks[bp] then return end -- [V15.2] 同一个背包只挂一次 ChildAdded
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

-- 直立姿态辅助：压平 CFrame 朝向、禁用摔倒状态（防倒地起身用）
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

-- 环境光照守候（涵盖全亮、去雾与性能模式关闭阴影；过滤受控属性并合并同帧触发，防止天气 Tween 每帧刷回调）
do
    local watchedLightProps = {
        Brightness = true, ClockTime = true, Ambient = true, OutdoorAmbient = true,
        GlobalShadows = true, FogEnd = true, FogStart = true,
    }
    local lightUpdateQueued = false
    if Lighting then
        table.insert(activeConnections, Lighting.Changed:Connect(function(prop)
            if not isRunning or not watchedLightProps[prop] then return end
            if not (Config.Fullbright or Config.NoFog or Config.PerformanceMode) then return end
            if lightUpdateQueued then return end
            lightUpdateQueued = true
            task.defer(function()
                lightUpdateQueued = false
                if isRunning and (Config.Fullbright or Config.NoFog or Config.PerformanceMode) then
                    ApplyLightingSettings()
                end
            end)
        end))
    end
end

-- 被踢重连（多通道守候 + isRejoining 防重入锁，避免重复触发两次 Teleport）
pcall(function()
    local isRejoining = false
    -- [V15.44 / REJOIN-FIX] 旧版只有 isRejoining 这一把 13 秒的短锁，TeleportState.Failed 回调晚到时
    -- 会在锁过期后再次触发，形成「每 >=13 秒传送一次」的自激循环。这里补两道硬闸：全局冷却 + 单会话次数上限。
    local rejoinCooldownUntil = 0
    local rejoinCount = 0
    -- 触发断线或传送失败后的 3 秒延迟自动重连（带防重入锁）
    local function TryTriggerRejoin(reasonMsg)
        -- [V15.44 / REJOIN-FIX] 三重硬门控，从结构上杜绝「自动重进」：
        --   1) Config.AutoRejoin 必须由用户在当前会话手动打开（读档时已被强制复位，见模块 07 LoadProfile）；
        --   2) 全局冷却 300s：一次重连尝试后 5 分钟内不再尝试，掐掉旧版「13s 锁过期 -> 再传送」的自激；
        --   3) 单会话上限 3 次：连续失败说明不是网络问题，继续传送只会把玩家反复踢出游戏。
        if isRejoining or not isRunning or not Config.AutoRejoin then return end
        local nowT = tick()
        if nowT < (rejoinCooldownUntil or 0) then
            FLog("断线重连", string.format("冷却中，忽略本次重连请求（还需 %.0f 秒）", (rejoinCooldownUntil or 0) - nowT))
            return
        end
        if (rejoinCount or 0) >= 3 then
            FLogWarn("断线重连", "本会话已自动重连 3 次，停止自动重连（避免反复掉线）。请确认网络后重新注入脚本。")
            return
        end
        -- 状态记录放在置锁之前：任何意外都不该让 isRejoining 卡在 true
        DashUI.SetStatus("重连", tostring(reasonMsg or "触发"))
        isRejoining = true
        rejoinCount = (rejoinCount or 0) + 1
        rejoinCooldownUntil = nowT + 300.0
        if reasonMsg then
            ShowNotification("自动重连", reasonMsg, "WARN")
        end
        pcall(function()
            print(string.format("[FSY][REJOIN] 第 %d 次自动重连 旧JobId=%s PlaceId=%d 原因=%s",
                rejoinCount, tostring(game.JobId), game.PlaceId, tostring(reasonMsg)))
        end)
        task.delay(3, function()
            if isRunning and Config.AutoRejoin then
                pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
            end
            -- 锁保持 60s（旧版 10s 太短，Failed 回调晚到就会在锁过期后再次触发）
            task.delay(60, function() isRejoining = false end)
        end)
    end
    task.spawn(function()
        activeThreads[coroutine.running()] = true
        if not CoreGui then
            FLogWarn("断线重连", "未能获取 CoreGui，跳过断线弹窗监控（其余功能不受影响）") -- [健壮性] 容错获取失败时不再报错中断
            return
        end
        local promptGui = CoreGui:WaitForChild("RobloxPromptGui", 5)
        local overlay = promptGui and promptGui:WaitForChild("promptOverlay", 5)
        if overlay and isRunning then
            table.insert(activeConnections, overlay.ChildAdded:Connect(function(child)
                if child and child.Name == "ErrorPrompt" then
                    task.delay(0.5, function()
                        if isRunning and Config.AutoRejoin and child and child.Parent
                            and (not child:IsA("GuiObject") or (child.Visible and child.AbsoluteSize.X > 50 and child.AbsoluteSize.Y > 30)) then
                            FLogWarn("断线重连", "检测到可见 ErrorPrompt 断线弹窗")
                            TryTriggerRejoin("检测到断线弹窗，3秒后自动重新连接...")
                        end
                    end)
                end
            end))
        end
    end)
    table.insert(activeConnections, LocalPlayer.OnTeleport:Connect(function(teleportState)
        -- [V15.44 / REJOIN-FIX] 传送失败不再自动重连，只记录。
        -- 原因：OnTeleport:Failed 在「游戏自己发起的一次传送被取消/目标实例满员」时同样会触发，
        -- 这类失败根本不代表掉线。旧版在这里直接 Teleport(game.PlaceId)，等于
        -- 「游戏自己传送失败 -> 脚本把玩家整个重进一遍」，是「无故自动重进」最像的一条路径。
        -- 现在自动重连只由「确实出现了可见的断线弹窗」这一条路径触发。
        if teleportState == Enum.TeleportState.Failed then
            FLogWarn("断线重连", "检测到传送失败（OnTeleport Failed）：仅记录日志，不自动重连")
        end
    end))
end)

-- ==========================================
-- 【模块 24：全图穿墙 ESP 渲染管理系统、跨全图固定地标锚点与鱼目标红圈】
-- 作用：BillboardGui 挂载于 screenGui 下实现无限距离穿墙显示，配合 3D Highlight 高亮目标模型；预置三岛神灵祭坛、
--   三大 Boss 区与秘密山洞固定 ESP 锚点（远端岛屿尚未流式加载也能跨全图看到方位与距离）；RefreshAllESPNow() 带
--   空表短路与距离整数缓存，仅在开启对应 ESP 且距离变化超过 1 米时更新文本。
-- ==========================================
-- 关键修复：BillboardGui 必须挂载在 ScreenGui (CoreGui/PlayerGui) 下才能在全图无限距离 100% 穿墙渲染，挂载在 Workspace.Folder 下会被引擎裁剪不显示！
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

-- 静态对象池化 ESP 管理系统：启动期一次性预分配 64 套 BillboardGui（含 Frame/UICorner/UIStroke/TextLabel）、Highlight 与代理锚点 Part，
-- 运行期 AddESP / RemoveESP / ClearDisabledCategoryESP 仅控制显隐、Adornee、文本、颜色与位置属性，0 次动态 Instance.new、0 次运行期 Destroy！
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

    -- 独立存放 3D Highlight 实例的容器（避免挂载在 ScreenGui 下导致移动端渲染状态更新滞后）
    local espHighlightFolder = Instance.new("Folder")
    espHighlightFolder.Name = "IdenticalESPHighlights"
    espHighlightFolder.Parent = Workspace
    table.insert(cleanUpInstances, espHighlightFolder)

    local ESP_POOL_SIZE = FSYC.Tunables and FSYC.Tunables.EspPoolSize or 64
    local espPoolWarned = false   -- [C05] 槽位池满的中文告警只提示一次，避免刷屏
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

    -- 启动期静态预建固定地标锚点 Part
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

    -- [静态UI修复] 加载期一次性静态预建 64 套 ESP 渲染槽位（BillboardGui + Frame + UIStroke + TextLabel + Highlight + 代理锚点 Part），严禁运行期动态创建 UI 实例
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
            if not slot then return nil end   -- 池未建/未满：宁可这次不显示，也不能 index nil 抛错
            if not slot.inUse then
                slot.inUse = true
                slot.lastDist = -1
                return slot
            end
        end
        return nil
    end

    -- 槽位释放抽成单一出口：原来只有 RemoveESP 会关 GUI/Highlight，一旦 activeESP 里的条目因弱键被 GC、或池满被覆盖
    -- 而「凭空消失」，槽位就永远留在 inUse=true（表现为「关掉 ESP 后还有一个标记不消失 / 越用越少」）。这里统一关显隐并复位字段。
    local function DisableESPSlot(data)
        if not data then return end
        -- [审计-5] 释放槽位时同步清掉所有仍指向它的 activeESP 反查条目：
        -- 旧条目若活到下一轮刷新，RemoveESP(旧实例) 会把已改挂给新目标的同一槽位一起关掉（表现为 ESP 标记时有时无）
        for existInst, existData in pairs(activeESP) do
            if existData == data then activeESP[existInst] = nil end
        end
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

    -- [ESP-FIX] 孤儿槽位清扫：槽位仍标记占用、但它的 Adornee 已经不在场景里（实例被销毁/流式卸载，
    -- 或弱键条目被 GC 导致再也没人释放它）时强制回收，保证 64 个槽位不会慢性泄漏。
    -- [Delta 减负 M9] 复用模块级缓冲表 sweepAliveBuf + table.clear，消除清扫时新建临时表（单线程同步执行无重入）。
    local sweepAliveBuf = {}
    SweepOrphanSlots = function()
        local aliveSlots = sweepAliveBuf
        table.clear(aliveSlots)
        for inst, data in pairs(activeESP) do
            if typeof(inst) == "Instance" and inst.Parent and data then
                aliveSlots[data] = true
            end
        end
        for i = 1, #espSlotPool do
            local slot = espSlotPool[i]
            if slot.inUse then
                local ad = slot.gui and slot.gui.Adornee
                if not aliveSlots[slot] or not slot.gui or not slot.gui.Parent or not ad or not ad.Parent then
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
        -- [ESP-FIX] 槽位级兜底：即使条目已从 activeESP 消失（弱键 GC / 池满覆盖），
        -- 也要按槽位自身记录的类别把不该显示的标记关掉，否则会残留一个关不掉的点。
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

    -- [ESP-FIX] Highlight 的 Adornee 只认 Model/BasePart：雷达允许把 Folder 当实体送进来，
    -- 原来这类目标永远没有 3D 高亮（只有文字）。这里统一解析出一个可高亮的对象。
    local function ResolveHighlightAdornee(inst)
        if typeof(inst) ~= "Instance" then return nil end
        if inst:IsA("Model") or inst:IsA("BasePart") then return inst end
        local ok, sub = pcall(function() return inst:FindFirstChildWhichIsA("BasePart", true) end)
        if ok and sub then return sub end
        return nil
    end

    -- [C05/ESP-FIX] 池满时按占用顺序淘汰最旧项；原来用 tick()，同一批添加的 seq 相同 → 淘汰顺序随机，
    -- 实测两轮显示的集合会变（用户感知"时有时无"）。改为单调自增计数器，顺序稳定可预测。
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
                -- 首次挂载时模型可能还没流式加载出零件（走了代理锚点），此后每次扫描都会命中这个早退分支，3D 高亮就永远是关的
                -- （用户看到「只有字没有光圈」）。这里每轮补一次：代理 → 真实零件，并把 Highlight.Adornee 绑上去并启用。
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
            -- [C05] 池满时不再静默丢弃：回收最旧（seq 最小）的标记槽位后再取一次；只覆盖最旧项，不新增任何节点
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
        slot.seq = espSeqCounter   -- [C05] 单调序号，供池满时稳定地判定"最旧项"
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
                -- [审计-6] 原为在 UI 输入回调里同步跑完整轮全图雷达（9 个容器 + 全岛子项 + 全部 prompt），
                -- 低端机点开关会卡数百毫秒；改为下一帧执行，功能等价，不再占用输入线程
                task.defer(function()
                    if isRunning and DashUI._runRadarPassNow then pcall(DashUI._runRadarPassNow) end
                end)
            end
            pcall(ScanAndMountDynamicESP)
        end

        -- [ESP-FIX] 孤儿槽清扫挂到常规刷新周期（原来只在省电清理/关类别时跑，回收时机不确定）；
        -- 64 个槽位的纯字段判断，开销可忽略，且不含任何 Instance 创建。
        if SweepOrphanSlots then pcall(SweepOrphanSlots) end

        local anyESP = Config.ESP_GodSpirit or Config.ESP_Boats
            or Config.ESP_Maoshan or Config.ESP_Taoist or Config.ESP_DumbGuy or Config.ESP_Boss or Config.ESP_Players
        if not anyESP then
            ClearDisabledCategoryESP(nil)
            return
        end

        -- [C7] toggledState == true 的开启动作刚在上方 ScanAndMountDynamicESP 扫过一次，这里不再重复全量扫描
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
                        -- 代理转真实零件时同步补 3D 高亮（否则 Highlight 仍指向空，只有字没有光圈）
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
                        -- [ESP-FIX] 除了启停，还要保证 Adornee 有效：Adornee 为空时 Highlight 即使 Enabled 也不渲染
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

-- ==========================================
-- 自动化循环 Heartbeat + 统一后台调度器 + 纯净渲染循环 RenderStepped
-- 独立函数作用域：避免顶层 local 超过 Luau 200 寄存器上限导致整脚本编译失败、UI 不出现
-- ==========================================
-- 【模块 25：核心运行时引擎 (IdenticalStartRuntimeLoops) —— 手机钓鱼按钮守护、Boss弹窗与技能按键缓存】
-- 作用：封装运行时高频状态变量（避免顶层 local 超过 Luau 200 寄存器上限）；守护移动端钓鱼圆钮；缓存 GUI/技能按钮引用。
-- ============================================================================
local function IdenticalStartRuntimeLoops()
local lastSellTime = 0
local lastFullBagSellTime = 0
-- 技能节拍由模块 27-A AutoSkill 引擎统一维护（本函数不保留 lastSkillTime / nextSkillAt）
local lastDailyTime = 0
local dailyMissingWarned = false -- 每日奖励远程缺失时只提示一次，避免每 5 分钟刷屏
local lastFullBagWarnTime = 0
-- 重置自动卖鱼计时器
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
-- [V15.46] 负缓存时间戳：false 只保持 60s，避免"白名单外名字"被永久挡住
local cachedEventRemoteNegAt = {}
-- 获取并缓存远程事件容器下的指定远程事件引用（兼容 Events/Remotes 多目录结构与延迟加载自愈）
local function GetEventRemote(name)
    -- [V15.46] name 必须是字符串：负缓存写入 cachedEventRemotes[name] 时 nil 键会直接报错
    if type(name) ~= "string" then return nil end
    if not IsInstanceValid(Events) then
        Events = FSYC.ResolveEventsFolder and FSYC.ResolveEventsFolder(ReplicatedStorage, 0)
            or (ReplicatedStorage and ReplicatedStorage:FindFirstChild("Events")) or nil
        table.clear(cachedEventRemotes)
        table.clear(cachedEventRemoteNegAt)
    end
    if not Events then return nil end
    local r = cachedEventRemotes[name]
    -- [V15.46] 负缓存：false 表示"查过但没有"，避免战斗中每帧重复 FindFirstChild。
    -- 3s TTL 兜底：即使某个名字不在新远程清理链路里，也不会被永久挡住；
    -- 取 3s 而非 60s：技能远程链若首个候选名缺失，60s 会形成整整一分钟的功能盲窗。
    if r == false then
        local negAt = cachedEventRemoteNegAt[name]
        if negAt and (tick() - negAt) < 3 then return nil end
        cachedEventRemotes[name] = nil
        cachedEventRemoteNegAt[name] = nil
        r = nil
    end
    if r and r.Parent == Events then
        return r
    end
    r = Events:FindFirstChild(name)
    if r then
        cachedEventRemotes[name] = r
        cachedEventRemoteNegAt[name] = nil
    else
        cachedEventRemotes[name] = false
        cachedEventRemoteNegAt[name] = tick()
    end
    return r or nil
end

-- 统一受 pcall 保护的 RemoteEvent 触发器，单个远程异常不中断当前帧；DashUI._safeFireRemote 为同口径自检入口（同样经 PacketGuard 去重与退避）。
local function SafeFireEventRemote(nameOrInst, ...)
    local rem = (typeof(nameOrInst) == "Instance") and nameOrInst or GetEventRemote(nameOrInst)
    if rem and rem.Parent and rem:IsA("RemoteEvent") then
        -- 同一业务意图在去重窗口内只发一包；处于异常指数退避期时自动拦截
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

-- [模块 22-B] 战斗域发包总闸：Slam/Charge/进度包/节奏包/技能施法/小游戏回包统一走这里；非搏斗状态返回 false（不发包不报错，计入闸门拦截数，可用 DashUI._fishGateStatus() 查看）。
local function SafeFireEventCombat(nameOrInst, ...)
    if not FishGate.AllowCombat() then return false end
    -- 战斗域用「10ms 精确去重」而非完全跳过：间隔 ≥20ms 的高频包照发，只把三通道重复触发的逐字节相同包收成 1 包（见 PacketGuard.combatWindowMs）。
    PacketGuard.combat = true
    -- pcall 兜底：万一出口内部抛错，也不会让 skip 永久为 true（那等于关掉去重保护）
    local callOk, sent = pcall(SafeFireEventRemote, nameOrInst, ...)
    PacketGuard.combat = false
    if not callOk then return false end
    return sent
end

-- 战斗域出口自检入口：必须放在 SafeFireEventCombat 之后（本地函数无前向声明，提前引用恒为 nil）。
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

-- 节拍抖动每周期预抽一次，下面统一存「下次允许时刻」（每帧重抽会把实际抖动压到设计值的 25%~50% 并被帧率量化）。
local nextCastAt = 0
local nextBaitBuyAt = 0
local nextMonkeyAt = 0
local nextGodPrayAt = 0
local nextCraftAt = 0
local nextGachaAt = 0
local nextProtectAt = 0
local nextFishBtnRestoreAt = 0
local nextQteAt = 0             -- [A2-08] QTE 点击
local nextBossPromptAt = 0      -- [A2-02] Boss Prompt
local nextProgressionAt = 0     -- [A2-05] 进度包
local nextSlamAt = 0            -- [A2-03] 猛击/蓄力节拍
local nextRhythmAt = 0          -- [A2-04] 节奏远程

-- 关闭自动抛竿时同步更新抛竿计时时间戳
DashUI._onAutoCastDisabled = function()
    -- 重开自动抛竿后仍等待一个完整 CastDelay
    nextCastAt = tick() + DashUI.ClampNum(Config.CastDelay, 0.1, 10, 1.0)
end

-- 为右侧【钓鱼】圆钮绑定手动点击兜底：当关闭脚本自动抛竿后，若游戏原生 LocalScript 因切物品状态卡死未能响应点击，自动补发一次抛竿请求！
local function BindManualFishButtonFallback(btn)
    if not btn or hookedManualFishBtns[btn] then return end
    hookedManualFishBtns[btn] = true
    pcall(function()
        -- 走输入总线：同一物理按下只补发一次；桌面端不挂（原生脚本已处理，再补就是重复发包），切手机模式由 RebindAll 补挂。
        InputRouter.BindHudClick(btn, function()
            if not isRunning or Config.AutoCast then return end
            -- 手动兜底点击 span 0.12（点击类非检测窗口，仅加长）
            task.delay(HRand(0.15, 0.12), function()
                -- 延迟窗口内需重校验 Boss 挂机/微瞬移/卖鱼/抛竿 CD/游泳状态，并统一走 SafeFireEventRemote 接入去重
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
        -- 该连接挂在游戏原生 HUD 按钮上（不属本脚本 UI），由 InputRouter.Destroy 统一断开，不放进 activeConnections。
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
    -- 缓存按钮被游戏销毁/重建时，重扫冷却从 10s 收紧到 1.5s（否则表现为自动抛竿十几秒不动作）。
    if cachedMobileFishBtn then
        FLog("钓鱼按钮", "缓存的钓鱼按钮已失效（被游戏销毁/重建），1.5s 后重扫")
        cachedMobileFishBtn = nil
        -- 回拨上次扫描时间，等价于 1.5s 后立刻允许重扫
        local rescanDelay = 1.5
        lastMobileFishBtnScan = math.min(lastMobileFishBtnScan, now - 10.0 + rescanDelay)
    end
    -- 正常情况仍保持 10s 扫描节流，避免反复全 Descendants 遍历
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
                    -- [本地化] 按钮文案走越南语大写折叠，并补越南语/中文变体（Câu Cá 与「抛竿」易漏）
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
                        -- 实机确认：钓鱼按钮真名 MainGui.Mobile.Fishing（Name = "Fishing"），识别表必须覆盖 dn == "fishing"/"fish"，否则恢复逻辑全部空转。
                        or dn == "fishing" or dn == "fish")
                        and not txt:find("自动", 1, true) and not txt:find("auto", 1, true) and not txt:find("tự động", 1, true)
                        and not dn:find("auto", 1, true) and not pn:find("auto", 1, true) then
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
-- [BTN-SIMPLE] 只剩一个开关：开就一直显示，关就完全不管（不要再恢复"智能判断该不该显示"的辅助逻辑）。

RestoreMobileFishingButtonUI = function(forceRefreshGui)
    -- [BTN-FIX] 恢复按钮的触发条件（修复「关自动钓鱼后按钮消失」）：
    --   · 强制显示开关开            → 无条件恢复（一直显示，保留原语义）；
    --   · 强制显示开关关 且 自动抛竿关 → 恢复（关掉自动钓鱼后把按钮交还游戏，恢复官方「拿竿显示/收竿隐藏」）；
    --   · 强制显示开关关 且 自动抛竿开 → 不干预（挂机期间由脚本自己抛竿，不碰游戏 UI）。
    -- 不做持竿/面板判断（实机读不准：IsCharacterHoldingFishingRod 末尾恒 return true）；
    -- 恢复动作只做「把被游戏藏掉的按钮拉回 Visible=true」，后续显隐仍交给游戏 LocalScript，不越权持续强改。
    if not Config.ForceFishBtn and Config.AutoCast then return false end
    local fishBtn = GetMobileFishingButton(tick())
    if not fishBtn or not fishBtn.Parent then return false end
    pcall(function()
        if fishBtn.Visible ~= true then fishBtn.Visible = true end
        if fishBtn.Active ~= true then fishBtn.Active = true end
        -- 父容器（实机是 MainGui.Mobile，宽 31px）被游戏隐藏时一起撑开。
        -- 只碰这一层窄容器，绝不动 MainGui / Fisher_GUI 这类整屏节点。
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

-- 递归向上检查按钮的所有父级容器是否均处于 Visible = true 状态（带深度上限保护）
local function IsGuiHierarchyVisible(guiObj, stopAt)
    local cur, depth = guiObj, 0
    while cur and cur ~= stopAt and depth < 16 do
        -- 两分支互斥（ScreenGui 不属于 GuiObject），先判更常见的 GuiObject 以省一次 IsA
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

-- 在指定容器子树中按关键词查找首个 GuiObject（提取至函数外复用，消除每 0.6s 重复创建闭包）
local function FindGuiByKeywords(root, keywords)
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
    local rawFUI = (cachedMainGui and cachedMainGui:FindFirstChild("Fishing"))
        or (cachedPG and cachedPG:FindFirstChild("Fishing"))
        or (fisherGui and fisherGui:FindFirstChild("Fishing"))
    cachedFUI = (rawFUI and rawFUI:IsA("GuiObject")) and rawFUI or nil
    -- BossFightBar 节点查找：严格要求自身与祖先链均处于 Visible 状态，杜绝回退分支绕过可见性检查导致脱战后误判常亮
    local rawBossBar = cachedFUI and cachedFUI:FindFirstChild("BossFightBar")
    cachedBossBar = (rawBossBar and rawBossBar:IsA("GuiObject") and rawBossBar.Visible and IsGuiHierarchyVisible(rawBossBar, cachedFUI))
        and rawBossBar or nil

    local barFrame = cachedFUI and cachedFUI:FindFirstChild("BarFrame")
    local rawBarInner = barFrame and barFrame:FindFirstChild("Bar")
    cachedBarInner = (rawBarInner and rawBarInner:IsA("GuiObject")) and rawBarInner or nil
    local rawBossInner = cachedBossBar and (cachedBossBar:FindFirstChild("Bar")
        or FindGuiByKeywords(cachedBossBar, {"cursor", "marker", "indicator", "needle", "pointer", "moving", "bar"}))
    cachedBossBarInner = (rawBossInner and rawBossInner:IsA("GuiObject")) and rawBossInner or nil
    local rawBossHit = cachedBossBar and (cachedBossBar:FindFirstChild("Hitbox") or cachedBossBar:FindFirstChild("GreenZone")
        or cachedBossBar:FindFirstChild("Target")
        or FindGuiByKeywords(cachedBossBar, {"hitbox", "green", "zone", "perfect", "good", "target", "hit"}))
    cachedBossHitbox = (rawBossHit and rawBossHit:IsA("GuiObject")) and rawBossHit or nil
    local hpPlayer = cachedFUI and cachedFUI:FindFirstChild("HPPlayer")
    local progBar = hpPlayer and hpPlayer:FindFirstChild("ProgressionBar")
    local rawProgInner = progBar and progBar:FindFirstChild("Bar")
    cachedProgBarInner = (rawProgInner and rawProgInner:IsA("GuiObject")) and rawProgInner or nil
    local fUIPerf = cachedFUI and cachedFUI:FindFirstChild("PerfectButton")
    if fUIPerf and fUIPerf:IsA("GuiObject") and fUIPerf.Visible then
        cachedPerfectBtn = fUIPerf
    elseif cachedPerfectBtn and not cachedPerfectBtn.Parent then
        cachedPerfectBtn = nil
    end
    local rawChg = cachedFUI and cachedFUI:FindFirstChild("Charge")
    cachedChargeBtn = (rawChg and rawChg:IsA("GuiObject")) and rawChg or nil
    local cutscene = cachedMainGui and cachedMainGui:FindFirstChild("Cutscene")
    local rawHurt1 = cutscene and cutscene:FindFirstChild("Hurt")
    cachedHurt1 = (rawHurt1 and (rawHurt1:IsA("ImageLabel") or rawHurt1:IsA("ImageButton"))) and rawHurt1 or nil
    local impactGui = cachedPG and cachedPG:FindFirstChild("Impact")
    local impactCutscene = impactGui and impactGui:FindFirstChild("Cutscene")
    local rawHurt2 = impactCutscene and impactCutscene:FindFirstChild("Hurt")
    cachedHurt2 = (rawHurt2 and (rawHurt2:IsA("ImageLabel") or rawHurt2:IsA("ImageButton"))) and rawHurt2 or nil

    return cachedPData, cachedPG, cachedMainGui, cachedFUI, cachedBossBar
end

-- ============================================================================
-- 【模块 31-B：Enzo 第二阶段「读条判定」真实命中上报 (方案 B)】
-- 协议（实机双向抓包，pcap/完整协议解析报告.md，2987 条）：
--   出向  BossPhase2Action:FireServer({Index = n, Hit = true})   命中，n 从 1 严格 +1
--         BossPhase2Action:FireServer({Hit = false})            未命中，不带 Index
--   入向  BossPhase2Setup{HitboxW, MinGap, Mode, BarSpeed, BadLife}  第二阶段开始
--         NotifyDamage(200, false)                              单次命中回执
-- 红线：默认关闭（Config.RealBossHit）；只在第二阶段激活（SessionEnd/判定条消失/超时自动停）；读不到 Bar/Hitbox 立刻停手，绝不盲发；
--   上报间隔 = Config.RealBossGap + 0~0.06s 抖动（现行档位 1.20~0.30s；运行期硬下限 0.30s。旧档 0.18/0.15/0.10 已废弃；
--   实测真人最快 0.51s，0.5s 以上才是安全区）；单阶段有发送上限（REALBOSS_MAX_SENDS）；未命中如实上报 {Hit=false}。
-- ============================================================================
local RealBoss = {
    active = false,      -- 是否处于第二阶段
    index = 0,           -- 已经上报到第几次命中（服务端要求严格 +1）
    hits = 0,            -- 本阶段命中次数
    confirmed = 0,       -- 本阶段收到 NotifyDamage 回执的次数
    sent = 0,            -- 本阶段总上报次数（含未命中）
    minGap = 0.25,       -- 服务端下发的 MinGap
    startedAt = 0,
    nextAt = 0,          -- 下一次允许上报的时刻（预抽，带抖动）
    pendingAt = 0,       -- 上一次命中上报的时刻（等回执用）
    pendingIdx = 0,
    uiAt = 0,
    lastAnyAt = 0,       -- 上一次任何上报的时刻（低频未命中用）
}
local REALBOSS_HARD_GAP = FSYC.Tunables and FSYC.Tunables.RealBossHardGapSec or 0.50
-- 上限按「速率」而不是总包数来管：真正的作弊特征是「秒耗」，所以闸下在间隔上；总包数（REALBOSS_MAX_SENDS）只做防跑飞保险。
local REALBOSS_MAX_SENDS = FSYC.Tunables and FSYC.Tunables.RealBossMaxSends or 500
local REALBOSS_MAX_DURATION = FSYC.Tunables and FSYC.Tunables.RealBossMaxDurationSec or 200
RealBoss.failStreak = 0

RealBossDeactivate = function(reason)
    -- 脱战打印本阶段实测速率：真人 ≈0.84 次/秒（17 次/27 秒）；命中/秒是服务端最可能用来判定的指标，>1.5 需警惕。
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
    -- 运行期硬夹：无论存档里是什么值，实际间隔都不低于「服务端 MinGap + 0.10」且不低于 hardFloor。
    -- 真人实测命中节拍均值 1.27s、最快 0.54s（判定条本身的节奏上限）；命中率才是胜负手——漏按扣血、命中回血并扣 Boss 血，故「读条 + 100% 命中」永不掉血。
    -- [保守优先] 保持用户 Config 不变（不静默改写，UI 显示与配置一致），但日志里的「生效间隔」按真实发送下限打印
    local wantGap = DashUI.ClampNum(Config.RealBossGap, 0.30, 2.0, 0.75)
    do
        local minAllowed = math.max(0.30, gap + 0.10)
        if wantGap < minAllowed then wantGap = minAllowed end
    end
    if FLog then pcall(FLog, "Boss/真实命中",
        string.format("第二阶段开始：服务端MinGap=%.2fs，生效间隔=%.2fs（真人实测均值1.19s/最快0.51s，单阶段上限%d包）",
            gap, wantGap, REALBOSS_MAX_SENDS)) end
end

local function RealBossOnDamage()
    -- 只认「我们自己刚发过命中、且 1 秒内」的回执，避免把技能伤害/第一阶段大伤害算进来
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

-- 每帧调用：判定条在窗口内才上报命中
-- [Delta 减负 M10] 读条几何判定提为 FSYC 具名函数（不占主块顶层 local）：消除 RenderStepped 每帧新建 1 个匿名闭包，
-- 同时严守 FSY15.47 历史修复红线，保持下方 IsGuiHierarchyVisible(bossBar) 每帧实时检查不降频。
FSYC._realBossGeomCore = function(marker, zone)
    local mx, mw = marker.AbsolutePosition.X, marker.AbsoluteSize.X
    local zx, zw = zone.AbsolutePosition.X, zone.AbsoluteSize.X
    if mw < 1 then mw = 1 end
    if zw < 1 then zw = 1 end
    return (mx < (zx + zw)) and ((mx + mw) > zx)
end

local function RealBossStep(now)
    if not RealBoss.active then return end
    if not Config.RealBossHit then RealBossDeactivate("开关关闭"); return end
    if not isRunning then return end
    if not FishGate.AllowCombat() then return end
    -- 包数上限只是兜底保险（防状态机空转）；真正停手的是下面「判定条消失」那条。实测该阶段真实持续约 24.6 秒。
    if RealBoss.sent >= REALBOSS_MAX_SENDS then RealBossDeactivate("超出单阶段上限"); return end
    if (now - RealBoss.startedAt) > REALBOSS_MAX_DURATION then RealBossDeactivate("超时"); return end
    -- 判定条消失 = 战斗结束（或不是 Enzo 战），立刻停手。
    -- 缓存引用按 0.6s 刷新，刚激活头几帧可能还是 nil：必须先"至少见过一次"，之后消失才算真结束，否则开局就会把自己关掉。
    local bossBar = cachedBossBar
    if not (bossBar and bossBar.Parent and bossBar.Visible and IsGuiHierarchyVisible(bossBar)) then
        if RealBoss.sawBar then RealBossDeactivate("判定条消失") end
        return
    end
    RealBoss.sawBar = true
    local marker = cachedBossBarInner
    local zone = cachedBossHitbox
    -- 读不到子控件就不发（宁可不动也不盲发）；连续 2.5s 找不到就打印一次节点清单，避免"0.35s 打不了"被误判成速度问题。
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

    -- 命中窗口判定：游标与判定区在 X 轴上是否有重叠
    local okGeo, inZone = pcall(FSYC._realBossGeomCore, marker, zone)
    if not okGeo then return end
    inZone = (inZone == true)

    -- [保守优先] 间隔 = max(用户档位, 服务端MinGap+0.10, 0.30)：不篡改用户的 Config（UI 仍显示所选档位），
    -- 但实际发送节奏不会被压到服务端下限之下 —— 低于 MinGap 时服务端直接丢弃，表现为"发了但不回血"，且是典型风控特征。
    local gap = DashUI.ClampNum(Config.RealBossGap, 0.30, 2.0, 0.75)
    do
        local minAllowed = math.max(0.30, (tonumber(RealBoss.minGap) or 0) + 0.10)
        if gap < minAllowed then gap = minAllowed end
    end
    -- 激进模式：不等绿区，按节拍上报，命中与否按「拟人命中率」掷骰。
    -- 未命中立刻上报 {Hit=false}（与真人打空同形，不被 2.5s 心跳吞掉），使服务端看到的命中率等于配置值。
    local forcedMiss = false
    if Config.RealBossForce then
        local rate = DashUI.ClampNum(Config.RealBossHitRate, 50, 100, 85)
        if rate >= 100 or math.random(1, 100) <= rate then
            inZone = true
        else
            inZone = false
            forcedMiss = true
        end
    end
    if inZone then
        -- 必须先发包、确认没被明确拒绝后再推进 index：一旦这包没发出去（remote 未就绪 / 被判重 / 闸门翻转）而本地已 +1，
        -- 之后所有 Index 都与服务端要求的「严格 +1」永久错位。注意 SafeFireEventCombat 返回 nil = 无法判定，按成功处理；只有明确 false 才回滚。
        local nextIdx = RealBoss.index + 1
        local okFire = SafeFireEventCombat("BossPhase2Action", { Index = nextIdx, Hit = true })
        if okFire == false then
            -- 失败退避：不推进序号，按指数退避延后重试（0.08s → 0.16s → … → 1.0s）
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
        -- 拟人漏报：这一次明确打空，形态与真人一致（不推进 Index）
        local okMiss = SafeFireEventCombat("BossPhase2Action", { Hit = false })
        if okMiss ~= false then
            RealBoss.sent = RealBoss.sent + 1
            RealBoss.pendingIdx = 0
            RealBoss.lastAnyAt = now
        end
        RealBoss.nextAt = now + gap + math.random() * 0.06
    else
        -- 窗口外：连续 RealBossMissHeartbeatSec (2.5s) 没有任何上报才补一条 {Hit = false}
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
-- [Delta 减负 M11] 技能槽位名字别名表：将原先热路径内层每次调用的 8~10 次字符串拼接（"SKILL"..key 等）
-- 改为加载期一次性建表 + 哈希查表；严格区分实例名（8 种）与文本（2 种），候选集合与原实现逐字符一致。
FSYC.SkillNameAlias = {}
for _, skillKey in ipairs(SKILL_KEYS) do
    FSYC.SkillNameAlias[skillKey] = {
        name = {
            [skillKey] = true,
            ["SKILL" .. skillKey] = true,
            ["SKILL_" .. skillKey] = true,
            ["SKILL " .. skillKey] = true,
            ["KEY" .. skillKey] = true,
            ["KEY_" .. skillKey] = true,
            ["SLOT" .. skillKey] = true,
            ["BTN" .. skillKey] = true,
        },
        text = {
            [skillKey] = true,
            ["[" .. skillKey .. "]"] = true,
        },
    }
end
-- 判断指定 UI 按钮是否对应 Z / X / C / V 技能槽位（排除关闭/取消按钮）
local function DoesButtonMatchSkillKey(d, key)
    local rawName = (d.Name or ""):match("^%s*(.-)%s*$"):upper()
    local rawLow = rawName:lower()
    if rawLow:find("close", 1, true) or rawLow:find("exit", 1, true) or rawLow:find("cancel", 1, true) or rawLow:find("quit", 1, true) or rawLow:find("delete", 1, true) then
        return false
    end
    local alias = FSYC.SkillNameAlias[key]
    local aliasName = alias and alias.name
    local aliasText = alias and alias.text
    if aliasName and aliasName[rawName] then return true end
    if d:IsA("TextButton") then
        local t = (d.Text or ""):match("^%s*(.-)%s*$"):upper()
        if aliasText and aliasText[t] then
            return true
        end
    end
    -- 只查一层子 TextLabel，避免 GetDescendants 深扫
    for _, sub in ipairs(d:GetChildren()) do
        if sub:IsA("TextLabel") and sub.Visible then
            local st = (sub.Text or ""):match("^%s*(.-)%s*$"):upper()
            if aliasText and aliasText[st] then
                return true
            end
        end
    end
    if d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X > 10 and d.Parent.AbsoluteSize.X < 180 then
        for _, sib in ipairs(d.Parent:GetChildren()) do
            if sib:IsA("TextLabel") and sib.Visible then
                local st = (sib.Text or ""):match("^%s*(.-)%s*$"):upper()
                if aliasText and aliasText[st] then
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
    -- 冷却读取：只在实例被销毁时丢弃缓存——按钮变灰/隐藏时实例仍在，倒计时数字还要靠它读。
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

-- 取技能按钮原始引用（只要求实例存活，不要求可见）：冷却读数需要它在按钮变灰/隐藏时仍可读。
local function GetSkillButtonRef(slot)
    local btn = cachedSkillButtons[slot]
    if btn and btn.Parent then return btn end
    return nil
end

-- 跨全 PlayerGui 定位手机端「按下F键进行猛击」圆钮与 Charge 按钮：猛击圆钮与 Z/X/C/V 同栏，但 TextLabel 与 GuiButton 是兄弟节点，且文本可能多行/被自动翻译。
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

-- [Delta 减负 M12] 属性读取具名函数：替代内层循环里的 pcall(匿名函数)，消除每个候选控件分配 2 个闭包。
FSYC._readLocalizedText = function(lbl) return lbl.LocalizedText end
FSYC._readContentText = function(lbl) return lbl.ContentText end
local function CheckLabelMatchesSlam(lbl)
    if not lbl or not lbl.Visible then return false end
    if (lbl:IsA("TextLabel") or lbl:IsA("TextButton")) and lbl.TextTransparency < 0.96 then
        if DoesTextMatchSlam(lbl.Text) then return true end
        local okLoc, locTxt = pcall(FSYC._readLocalizedText, lbl)
        if okLoc and DoesTextMatchSlam(locTxt) then return true end
        local okCnt, cntTxt = pcall(FSYC._readContentText, lbl)
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
    -- 与 DoesButtonMatchSkillKey 一致：检查小圆钮容器（尺寸 < 220px）下的同级兄弟 TextLabel
    if d:IsA("GuiButton") and d.Parent and d.Parent:IsA("GuiObject") and d.Parent.AbsoluteSize.X > 10 and d.Parent.AbsoluteSize.X < 220 and d.Parent.AbsoluteSize.Y < 220 then
        for _, sib in ipairs(d.Parent:GetChildren()) do
            if CheckLabelMatchesSlam(sib) then return true end
        end
    end
    return false
end

-- 从命中的 UI 节点（可能是 TextLabel、外层 Frame 或 GuiButton）反查同一圆钮容器内的最佳可点击目标
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

    -- 若尚未缓存过 Z/X/C/V 技能按钮，先触发一次技能槽定位，以便直接顺藤摸瓜检查技能组旁边的第 5 个猛击圆钮
    if next(cachedSkillButtons) == nil then
        pcall(GetCachedSkillButton, "Z", now)
    end

    -- 1) 优先检查已定位的 Z/X/C/V 技能按钮同级容器（实拍图显示「按下F键\n进行猛击」就在 Z/X/C/V 技能组右侧同级容器内）
    for _, skBtn in pairs(cachedSkillButtons) do
        if skBtn and skBtn.Parent then
            local p1 = skBtn.Parent
            local p2 = p1.Parent
            local p3 = p2 and p2.Parent
            -- [Delta 减负 M13] 改为固定三槽遍历，消除每轮扫描新建 {p1, p2, p3} 临时数组。
            for ci = 1, 3 do
                local container = (ci == 1) and p1 or ((ci == 2) and p2 or p3)
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

    -- 2) 遍历 PlayerGui 下所有已启用的 ScreenGui（含 Fisher_GUI、MainGui、ContextActionGui 等，仅排除背包/商店/图鉴等大型菜单）
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

-- 四通道覆盖「按下F键进行猛击」：
-- 通道1 圆钮全信号（Activated/MouseButton1Click/TouchTap/InputBegan）；通道2 圆钮中心像素触控与鼠标点击；
-- 通道3 模拟硬件 [F] 键；通道4 注入 UserInputService.InputBegan 上的原生 [F] 监听（手机无物理键盘时 SendKeyEvent 会被忽略）。
-- [P-02] 抓包实证 Slam 出向 0 次、猛击没有独立远程包（服务端看到的是随后的 UpdateFishProgression），故不再向 Slam 发 "Perfect"/true/无参 三包。
-- [Delta 减负 M14] 复用只读的合成 F 键 InputObject（挂载于 FSYC，0 顶层 local 占用），消除每次猛击新建 2 张表；
-- 同时严格保留实时 getconnections 与每连接独立 task.spawn 并发触发，杜绝连接缓存漏打 QTE 或单协程回调 yield 阻塞。
FSYC._getSlamFakeKeys = function()
    if not FSYC._slamFakeKeyBegin then
        FSYC._slamFakeKeyBegin = MakeSyntheticInput(Enum.UserInputType.Keyboard, Enum.UserInputState.Begin, Enum.KeyCode.F, Vector3.zero)
        FSYC._slamFakeKeyEnd = MakeSyntheticInput(Enum.UserInputType.Keyboard, Enum.UserInputState.End, Enum.KeyCode.F, Vector3.zero)
    end
    return FSYC._slamFakeKeyBegin, FSYC._slamFakeKeyEnd
end

local function TriggerSlamEveryWay(perfBtn)
    -- [模块 22-B] 闸门：非搏斗状态一律不打猛击（圆钮缓存、OnClientEvent 回包、盲打保底三条路都会走到这里）。
    if not FishGate.AllowCombat() then return end
    if perfBtn and perfBtn.Parent and perfBtn.Visible then
        FireGuiButton(perfBtn, true, true)
    end
    if VirtualInputManager then
        pcall(function()
            -- F 键纳入 pressedVirtualKeys 登记：卸载/取消该 task.delay 时由 DashUI._releaseAllVirtualKeys 泛化兜底抬手
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
            local fakeKeyBegin, fakeKeyEnd = FSYC._getSlamFakeKeys()
            local uisConns = getconnections(UserInputService.InputBegan)
            if type(uisConns) == "table" then
                for _, conn in ipairs(uisConns) do
                    if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false and type(conn.Function) == "function" then
                        task.spawn(function() pcall(conn.Function, fakeKeyBegin, false) end)
                    end
                end
            end
            task.delay(0.04, function()
                pcall(function()
                    local endConns = getconnections(UserInputService.InputEnded)
                    if type(endConns) == "table" then
                        for _, conn in ipairs(endConns) do
                            if (type(conn) == "table" or typeof(conn) == "userdata") and conn.Enabled ~= false and conn.State ~= false and type(conn.Function) == "function" then
                                task.spawn(function() pcall(conn.Function, fakeKeyEnd, false) end)
                            end
                        end
                    end
                end)
            end)
        end)
    end
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

-- 注意：Workspace.DescendantAdded/Removing 已在全局合并为唯一一对监听 + 启动分帧预热，此处不要再挂第二套。

local uidHealthKey = tostring(LocalPlayer.UserId) .. "_PlayerHealth"

-- 事件驱动维护 Workspace 根子节点候选 Model 集合（wsRootRadarModels）：关键词覆盖神灵、道士/茅山/傻子商人全别名（含越文/拼音/空格）、四圣兽、恩佐/章鱼/龙钓海 Boss；
-- 配合 stepWorldRadar 内实时重校验与调度器每 30s 增量补扫，解决 Model 插入后再改名的漏检。
local wsRootRadarModels = setmetatable({}, { __mode = "k" })
-- 快速判断字符串是否包含神灵、商人、四圣兽、Boss 或重点 NPC 的特征关键词
-- 关键字判定按字符串缓存（每次约 100 条 find，雷达每轮重复调用同名）；上限 4096，超限整体清空重建。
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
-- 判断 Workspace 顶层子节点是否可能为动态刷新的 NPC、神灵祭坛或 Boss 实体
-- 名字判定缓存：IsWorkspaceRootRadarCandidate 在每次 Workspace.ChildAdded 与 30s 补扫时都会调用，结果只取决于名字字符串
-- （IsA/容器两条前置校验在缓存之外）；上限 2048，超限整体清空重建，省掉每次 tqLc 分配与近百次 find。
local radarNameVerdict = {}
local radarNameVerdictCount = 0
local function IsWorkspaceRootRadarCandidate(ch)
    if not ch or IsMapOrIslandContainer(ch) then return false end
    if not (ch:IsA("Model") or ch:IsA("BasePart") or ch:IsA("Folder")) then return false end
    local rawName = ch.Name or ""
    local cachedVerdict = radarNameVerdict[rawName]
    if cachedVerdict ~= nil then return cachedVerdict end
    local cn = tqLc(rawName) -- [本地化] 走越南语大写折叠，避免 "Đạo Sĩ" 一类名字漏判
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

-- 技能顺序只保留模块 27-A 引擎内的 BuildSequence() 一套实现（顺序串 + 勾选位掩码快照缓存，逐帧零分配，非法串回退 Z→X→C→V）。

-- ============================================================================
-- 【模块 25-B：Delta 执行器统一资源治理器 (ResourceGovernor · A+B 融合增强版)】
-- 目的：把「事件连接池 / 受管协程池 / 交互提示池 / 可重建缓存」纳入「统一登记 -> 定期清扫 -> 事务守卫空闲软重置 -> 退出强制回收」，
--   消除 Delta 执行器长时间运行后的死句柄堆积、失效实例强引用滞留与 GC 峰值闪退；100% 保持原版业务功能、发包节拍与雷达时效。
-- 融合设计要点：
--   ① 零新增事件连接、零新增常驻协程、零新增主块顶层 local（IIFE 闭包挂载至 FSYC.Gov，严守 Luau 200 寄存器红线）；
--   ② 五池全覆盖清扫（每 4.0s，卡顿自适应 8.0s）：接管 activeConnections / characterConnections / activeDragConns 三大连接池
--      （尾元素回填 O(1) 删除 + pcall 探活 + 幂等 Disconnect），并融合版本 B 对 activeThreads（dead 协程）与 activePromptTasks（Parent==nil）的清扫；
--   ③ 30s 独立定频缓存裁剪（不依赖深度空闲，解决挂机自动钓鱼期间缓存永不裁剪的问题）：裁剪 npcScanCache、dialogueBtnCache、
--      超阈值 patternCache、ESP 孤儿槽位及超过 120s 的过期 PacketGuard.lastAt 记录（绝不粗暴清空活跃去重窗口）；
--   ④ 事务守卫安全软重置：连续 120s 空闲（非钓鱼/小游戏，且无卖鱼/领奖/签到/微瞬移/喂猴事务）且间隔 ≥300s 时集中清扫+裁剪+采样内存，
--      绝不拉长主循环 task.wait(0.15s) 与雷达 0.8s 扫描周期。
-- ============================================================================
FSYC.Gov = (function()
    local Gov = {}

    -- 已登记连接：弱键表（连接被引擎回收后条目自动消失，治理器不会反向钉住句柄）
    local conns = setmetatable({}, { __mode = "k" })
    local pools = {}
    local trims = {}
    local busyGuards = {}
    local stats = {
        adopted = 0,          -- 累计登记过的连接数
        pruned = 0,           -- 累计清扫掉的失效连接数
        threadsPruned = 0,    -- 累计清扫掉的已结束协程数
        promptsPruned = 0,    -- 累计清扫掉的失效 Prompt 数
        sweeps = 0,           -- 清扫轮次
        trims = 0,            -- 缓存裁剪轮次
        resets = 0,           -- 空闲软重置次数
        shutdowns = 0,        -- 退出清理次数
        ticks = 0,            -- 治理器被调度次数
        lagSamples = 0,       -- 调度节拍被拖慢的采样次数
        lagPeak = 0,          -- 观测到的最大调度节拍（秒）
        luaKb = 0,            -- 最近一次 Lua 堆大小（KB，执行器不暴露 gcinfo 时恒为 0）
        luaKbPeak = 0,        -- 观测到的 Lua 堆峰值（KB）
        lastTickAt = 0,
        lastSweepAt = tick(),
        lastTrimAt = tick(),
        lastResetAt = tick(),
        lastMemAt = 0,
        lastWarnAt = 0,
    }
    Gov.stats = stats
    Gov.enabled = true
    Gov.SWEEP_INTERVAL = 4.0      -- 失效句柄清扫周期（秒）
    Gov.TRIM_INTERVAL = 30.0      -- 可重建缓存裁剪周期（秒）
    Gov.RESET_IDLE_SEC = 120.0    -- 连续空闲多久后允许一次安全软重置
    Gov.RESET_MIN_GAP = 300.0     -- 两次软重置的最小间隔
    Gov.LAG_TICK_SEC = 0.40       -- 调度器节拍超过 0.40s 记一次卡顿采样
    Gov.POOL_WARN = 400           -- 常驻连接池异常膨胀告警线（只告警，不主动断开业务连接）
    Gov.idleSince = 0

    -- 具名无闭包安全探针（兼容魔改元表执行器，读属性异常时保守视为存活/未死，绝不误删）
    local function ProbeConnConnected(conn) return conn.Connected end
    local function ProbeThreadStatus(th) return coroutine.status(th) end
    local function ProbePromptParent(pr) return pr.Parent end
    local function DoDisconnect(conn) conn:Disconnect() end

    local function IsAlive(conn)
        if conn == nil then return false end
        local ok, alive = pcall(ProbeConnConnected, conn)
        if not ok then return true end
        return alive == true
    end

    local function IsDeadConfirmed(conn)
        if conn == nil then return true end
        local ok, alive = pcall(ProbeConnConnected, conn)
        return ok and alive == false
    end

    local function ReadGcKb()
        local ok, kb = pcall(gcinfo)
        if ok and type(kb) == "number" then return kb end
        return nil
    end

    -- 数组连接池清扫：从后往前用尾元素回填 O(1) 删除，避免 table.remove 的 O(n^2) 搬移
    local function SweepArray(list)
        local removed, i = 0, #list
        while i >= 1 do
            local conn = list[i]
            if conn == nil then
                list[i] = list[#list]
                list[#list] = nil
                removed = removed + 1
            elseif IsDeadConfirmed(conn) then
                list[i] = list[#list]
                list[#list] = nil
                removed = removed + 1
                pcall(DoDisconnect, conn)
            end
            i = i - 1
        end
        return removed
    end

    -- 集合连接池清扫（activeDragConns 等 conn -> true 表）
    local function SweepSet(set)
        local removed = 0
        for conn in pairs(set) do
            if conn == nil or IsDeadConfirmed(conn) then
                set[conn] = nil
                removed = removed + 1
                if conn then pcall(DoDisconnect, conn) end
            end
        end
        return removed
    end

    -- 受管协程与交互提示弱表清扫（吸收版本 B：摘除已被外部引用钉住的 dead 协程与已销毁 Prompt）
    local function SweepThreadsAndPrompts()
        local td, pd = 0, 0
        if type(activeThreads) == "table" then
            for th in pairs(activeThreads) do
                local okS, st = pcall(ProbeThreadStatus, th)
                if okS and st == "dead" then
                    activeThreads[th] = nil
                    td = td + 1
                end
            end
        end
        if type(activePromptTasks) == "table" then
            for pr in pairs(activePromptTasks) do
                local okP, parent = pcall(ProbePromptParent, pr)
                if okP and parent == nil then
                    activePromptTasks[pr] = nil
                    pd = pd + 1
                end
            end
        end
        stats.threadsPruned = stats.threadsPruned + td
        stats.promptsPruned = stats.promptsPruned + pd
        return td, pd
    end

    function Gov.AttachPool(pool, kind)
        if type(pool) ~= "table" then return false end
        for i = 1, #pools do
            if pools[i].pool == pool then return true end
        end
        pools[#pools + 1] = { pool = pool, kind = (kind == "set") and "set" or "array" }
        return true
    end

    function Gov.Track(conn)
        if conn == nil then return nil end
        if conns[conn] == nil then
            conns[conn] = tick()
            stats.adopted = stats.adopted + 1
        end
        return conn
    end

    function Gov.RegisterTrim(name, fn)
        if type(fn) ~= "function" then return false end
        trims[#trims + 1] = { name = tostring(name), fn = fn }
        return true
    end

    function Gov.AddBusyGuard(fn)
        if type(fn) ~= "function" then return false end
        busyGuards[#busyGuards + 1] = fn
        return true
    end

    function Gov.IsBusy(inGameplay)
        if inGameplay then return true end
        for i = 1, #busyGuards do
            local ok, busy = pcall(busyGuards[i])
            if ok and busy then return true end
        end
        return false
    end

    local function AdoptPool(rec)
        local pool = rec.pool
        if rec.kind == "set" then
            for conn in pairs(pool) do Gov.Track(conn) end
        else
            for i = 1, #pool do Gov.Track(pool[i]) end
        end
    end

    local function SweepAll()
        local removed = 0
        for i = 1, #pools do
            local rec = pools[i]
            if rec.kind == "set" then
                removed = removed + SweepSet(rec.pool)
            else
                removed = removed + SweepArray(rec.pool)
            end
            AdoptPool(rec)
        end
        for conn in pairs(conns) do
            if IsDeadConfirmed(conn) then conns[conn] = nil end
        end
        SweepThreadsAndPrompts()
        stats.pruned = stats.pruned + removed
        stats.sweeps = stats.sweeps + 1
        stats.lastSweepAt = tick()
        return removed
    end

    local function RunTrims()
        for i = 1, #trims do
            pcall(trims[i].fn)
        end
        stats.trims = stats.trims + 1
        stats.lastTrimAt = tick()
    end

    function Gov.SoftReset(reason)
        if not Gov.enabled then return false end
        local ok, removed = pcall(function()
            local n = SweepAll()
            RunTrims()
            return n
        end)
        if ok then
            stats.resets = stats.resets + 1
            stats.lastResetAt = tick()
            FLog("资源治理", string.format("空闲软重置 #%d（%s）：清除失效连接 %d 条 / 死协程 %d 个，常驻连接 %d 条，Lua 堆 %d KB",
                stats.resets, tostring(reason or "定时"), tonumber(removed) or 0, stats.threadsPruned, #activeConnections, stats.luaKb))
            return true
        end
        FLogWarn("资源治理", "空闲软重置异常，已跳过（不影响业务）")
        return false
    end

    function Gov.Tick(now, idle)
        if not Gov.enabled or not isRunning then return false end
        now = now or tick()
        stats.ticks = stats.ticks + 1

        -- 1) 帧压采样：只读调度器节拍间隔，零新增连接
        local prevTickAt = stats.lastTickAt
        local dt = now - prevTickAt
        stats.lastTickAt = now
        if prevTickAt > 0 and dt > Gov.LAG_TICK_SEC then
            stats.lagSamples = stats.lagSamples + 1
            if dt > stats.lagPeak then stats.lagPeak = dt end
        end

        -- 2) 定期清扫（4s/次，卡顿期自动退避至 8s/次）+ 30s 独立定频缓存裁剪
        local sweepGap = Gov.SWEEP_INTERVAL
        if stats.lagSamples > 5 then sweepGap = Gov.SWEEP_INTERVAL * 2 end
        if now - stats.lastSweepAt >= sweepGap then
            pcall(SweepAll)
            if #activeConnections > Gov.POOL_WARN and (now - stats.lastWarnAt) > 60.0 then
                stats.lastWarnAt = now
                FLogWarn("资源治理", string.format("常驻连接数异常偏高（%d 条），已执行清扫；若持续增长请反馈", #activeConnections))
            end
            if now - stats.lastTrimAt >= Gov.TRIM_INTERVAL then
                RunTrims()
            end
        end

        -- 3) 内存采样：30s 一次，执行器不暴露 gcinfo 时自动跳过
        if now - stats.lastMemAt >= 30.0 then
            stats.lastMemAt = now
            local kb = ReadGcKb()
            if kb then
                stats.luaKb = kb
                if kb > stats.luaKbPeak then stats.luaKbPeak = kb end
            end
        end

        -- 4) 事务守卫空闲软重置：仅在非钓鱼/非搏斗且无后台事务忙时计时，满 120s 且间隔 ≥300s 触发
        local actuallyIdle = (idle == true) and (not Gov.IsBusy(false))
        if actuallyIdle then
            if Gov.idleSince == 0 then Gov.idleSince = now end
            if (now - Gov.idleSince >= Gov.RESET_IDLE_SEC) and (now - stats.lastResetAt >= Gov.RESET_MIN_GAP) then
                Gov.SoftReset("空闲")
                Gov.idleSince = now
            end
        else
            Gov.idleSince = 0
        end
        return true
    end

    function Gov.Shutdown()
        Gov.enabled = false
        local count = 0
        for conn in pairs(conns) do
            if IsAlive(conn) then
                pcall(DoDisconnect, conn)
                count = count + 1
            end
            conns[conn] = nil
        end
        for i = 1, #pools do
            local rec = pools[i]
            if rec.kind == "set" then
                for conn in pairs(rec.pool) do
                    if conn then pcall(DoDisconnect, conn) end
                end
            else
                for j = 1, #rec.pool do
                    local conn = rec.pool[j]
                    if conn then pcall(DoDisconnect, conn) end
                end
            end
            table.clear(rec.pool)
        end
        SweepThreadsAndPrompts()
        table.clear(trims)
        table.clear(busyGuards)
        stats.shutdowns = stats.shutdowns + 1
        return count
    end

    function Gov.Report()
        return string.format("钩子=%d/清扫连接%d/死协程%d/裁剪%d/软重置%d/节拍峰值%.2fs/堆%dKB",
            #activeConnections, stats.pruned, stats.threadsPruned, stats.trims, stats.resets, stats.lagPeak, stats.luaKb)
    end

    Gov.AttachPool(activeConnections, "array")
    Gov.AttachPool(characterConnections, "array")
    Gov.AttachPool(activeDragConns, "set")

    if sharedEnv then sharedEnv.IdenticalFishingResourceStats = stats end
    return Gov
end)()

-- ==========================================
-- 【模块 26：统一后台时间片调度器（低频自动化 + 仪表盘统计 + 全图深度雷达扫描 + ESP清理）】
-- 作用：单协程分时错峰——0.15s ESP 距离、0.25s 低频自动化（防卖上锁/卖鱼/票据任务/祈祷/扭蛋/喂猴/签到/合成买饵）、0.50s 仪表盘与自动配装、
-- 全图 NPC/神灵/商人/四圣兽/Boss 雷达（周期见 radarInterval）、5.0s 清理失效 ESP、30.0s 根子节点改名增量补扫；每个子模块独立 pcall，互不阻塞、零每帧空转。
-- ============================================================================
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
-- 竿名大小写兜底：抓包 #154 UpdateFishingRodShop 首根是 "Wooden rod"（小写 r），静态表写的是 "Wooden Rod"，查不到会走"未收录战力表"分支 → 自动配竿整体跳过。
-- 故补一份小写索引（不动显示名，避免破坏已保存的配置文件与预设方案）。
local rodPowerLookupLower = {}
for k, v in pairs(rodPowerLookup) do rodPowerLookupLower[string.lower(tostring(k))] = v end
local function RodPowerOf(name)
    if name == nil then return nil end
    local key = tostring(name)
    return rodPowerLookup[key] or rodPowerLookupLower[string.lower(key)]
end

-- ============================================================================
-- 【FIX-AFK / 本次修复核心】防挂机保活统一入口
-- 旧版 15.26 能整夜稳定，靠两条线：
--   ① FireGuiButton 在移动端每次猛击/蓄力都注入真实触摸+鼠标事件（old_26:8397-8448）；
--   ② LocalPlayer.Idled 兜底只调 CaptureController + ClickButton2（old_26:17005-17017）。
-- 新版把 ① 删掉/门控成「电脑端 + 其它通道全失败才走」（new_43:8179-8205），于是只剩 ②；
-- 但 ② 被改成 CaptureController → Button2Down → delay → Button2Up → ClickButton2，全部塞进同一个 pcall
-- （Idled: new_43:16958-16972，定时脉冲: new_43:14321-14336）：只要执行器的 VirtualUser 没实现其中任何一步
-- （移动端执行器常见：没有 Button2Down、CaptureController 被拦），异常就会中断整个 pcall，
-- 真正能重置空闲计时器的 ClickButton2 永远不会执行 → 防挂机静默失效 → 满 20 分钟被空闲踢线 → 自动重连重进。
-- 这里把每条通道拆成独立 pcall，ClickButton2 永远会执行，并补上跨端兜底通道；只发「保活输入」，
-- 不改变任何游戏行为，也不恢复任何已删除功能。
-- ============================================================================
DashUI._antiAfkFailCount = 0
DashUI._antiAfkOkCount = 0
DashUI._touchActive = 0
DashUI._touchChangedAt = 0
pcall(function()
    table.insert(activeConnections, UserInputService.TouchStarted:Connect(function()
        DashUI._touchActive = (DashUI._touchActive or 0) + 1
        DashUI._touchChangedAt = tick()
    end))
end)
pcall(function()
    table.insert(activeConnections, UserInputService.TouchEnded:Connect(function()
        DashUI._touchActive = math.max(0, (DashUI._touchActive or 0) - 1)
        DashUI._touchChangedAt = tick()
    end))
end)

-- 发一条保活脉冲；返回 true 表示至少有一条通道成功发出
DashUI.AntiAfkPulse = function(reason)
    if not (Config.AntiAFK and isRunning) then return false end
    local vu, vim
    pcall(function() vu = game:GetService("VirtualUser") end)
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    local camCF = (Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame) or CFrame.new()
    local clickPos = Vector2.new(0, 0)
    local sent = false

    -- 通道 1（旧版验证过、优先级最高）：捕获控制器 + 右键点击。两步各自独立 pcall，互不阻断。
    if vu then
        pcall(function() vu:CaptureController() end)
        if pcall(function() vu:ClickButton2(clickPos) end) then
            sent = true
        elseif pcall(function() vu:ClickButton2(clickPos, camCF) end) then
            sent = true
        end
        -- 通道 2（可选）：按下/抬起。执行器不支持就静默跳过，绝不影响通道 1。
        -- [V15.46] 按下与抬起同帧发出：托管 task.delay 在卸载时会跳过回调，留 50ms 窗口会让右键停在按下态
        pcall(function() vu:Button2Down(clickPos, camCF) end)
        pcall(function() vu:Button2Up(clickPos, camCF) end)
    end

    -- 通道 3（跨端兜底）：引擎级键盘事件。LeftControl 在本游戏没有默认绑定，不会产生任何动作，
    -- 但会作为一条真实输入事件重置客户端空闲计时器（VirtualUser 被执行器拦掉时靠它）。
    -- LeftControl 若被用户配成 UI 显隐/卸载热键，就不要发这个键，避免保活脉冲误触脚本自己的快捷键
    local keySafe = not (Config.UIKeybind == Enum.KeyCode.LeftControl or Config.StopKeybind == Enum.KeyCode.LeftControl)
    if vim and keySafe then
        pressedVirtualKeys[Enum.KeyCode.LeftControl] = true
        if pcall(function() vim:SendKeyEvent(true, Enum.KeyCode.LeftControl, false, game) end) then
            sent = true
            task.delay(0.05, function()
                pcall(function() vim:SendKeyEvent(false, Enum.KeyCode.LeftControl, false, game) end)
                pressedVirtualKeys[Enum.KeyCode.LeftControl] = nil
            end)
        else
            pressedVirtualKeys[Enum.KeyCode.LeftControl] = nil
        end
    end

    -- 通道 4（仅移动端，且当前没有手指按在屏幕上）：屏幕顶部正中一次「按下→抬起」轻点，不拖动。
    -- 只用于重置触屏客户端的空闲计时器；有手指在屏幕上时跳过，避免第二根手指导致镜头缩放。
    -- 计数漂移保护：TouchEnded 偶发丢失时，超过 30s 没有变化就视为「没有手指在屏幕上」，避免触摸兜底被永久禁用
    local touchActive = (DashUI._touchActive or 0) > 0 and (tick() - (DashUI._touchChangedAt or 0)) < 30
    if vim and UserInputService and UserInputService.TouchEnabled and not touchActive then
        local cam = Workspace.CurrentCamera
        local vp = (cam and cam.ViewportSize) or Vector2.new(800, 600)
        -- 落点选屏幕顶部正中（Roblox 顶栏区域）：静止轻点不会旋转镜头，也不在游戏常用按钮上
        local tx = math.floor(vp.X * 0.5)
        local ty = 8
        -- 按下与抬起同帧发出（不留 40ms 窗口）：既保证输入事件被引擎记录，又避免卸载时抬起回调被取消、
        -- 让 touchId=1 永久停在按下态。Enum 与数字状态位各试一次，兼容只认其中一种的执行器。
        local began = pcall(function() vim:SendTouchEvent(1, Enum.UserInputState.Begin, tx, ty) end)
        if not began then
            began = pcall(function() vim:SendTouchEvent(1, 0, tx, ty) end)
        end
        if began then
            sent = true
            if not pcall(function() vim:SendTouchEvent(1, Enum.UserInputState.End, tx, ty) end) then
                pcall(function() vim:SendTouchEvent(1, 2, tx, ty) end)
            end
        end
    end

    if sent then
        DashUI._antiAfkOkCount = (DashUI._antiAfkOkCount or 0) + 1
        DashUI._antiAfkFailCount = 0
    else
        DashUI._antiAfkFailCount = (DashUI._antiAfkFailCount or 0) + 1
        if DashUI._antiAfkFailCount == 1 or DashUI._antiAfkFailCount % 10 == 0 then
            FLogErr("防挂机", string.format("保活脉冲全部通道失败（第 %d 次，来源=%s）：当前执行器不允许任何虚拟输入，20 分钟空闲踢线风险仍在",
                DashUI._antiAfkFailCount, tostring(reason)))
        end
    end
    return sent
end

-- [0.25s 周期] 低频自动化：自动收藏上锁、定时卖鱼、票据任务、神灵祈祷、自动扭蛋、喂猴子、每日签到及合成/购买鱼饵
local function stepLowFreqAutomation(now)
    -- [V15.45 / ANTI-IDLE] 保活脉冲：每 90s 一次，跨钓鱼/搏斗状态（这两段时间最长，正是最需要复位计时器的时候）。
    -- 统一走 DashUI.AntiAfkPulse：每条通道独立 pcall，ClickButton2 永远执行；移动端补触摸兜底；全失败写 ERROR 日志。
    if Config.AntiAFK and (now - (DashUI._lastProactiveAntiAfkAt or 0) >= 90.0) then
        DashUI._lastProactiveAntiAfkAt = now
        if DashUI.AntiAfkPulse then pcall(DashUI.AntiAfkPulse, "定时脉冲") end
    end
    -- 微瞬移锁超时自愈：持有超过 12s 视为协程已被异常中断，强制释放
    if isMicroTeleportingNPC and microTeleportLockAt > 0 and (now - microTeleportLockAt > 12) then
        isMicroTeleportingNPC = false
        microTeleportLockAt = 0
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local pData = cachedPData or GetPlayerData()
    -- [模块 22-B] 低频自动化（卖鱼/票据任务/动作清理）共用闸门的"空闲"判定。
    -- 旧条件 wasInMinigame / cachedIsHooked / 面板可见 的并集会在"其实还在搏斗"时插入卖鱼包（与钓鱼包同帧交叉，最容易被服务端判异常）。
    local gateIdleNow = FishGate.IsIdle()

    -- 当用户开启了「自动收藏并防卖」/「自动卖鱼」/「自动保护Boss鱼」/「材料收集模式」任意一项时，后台持续扫描为新入包保护鱼单次上锁
    -- 保护鱼上锁巡检 span 0.12（点击/轻动作，上锁无判定窗口）
    -- 后台定时扫描上锁避开小游戏搏斗期（not FishGate.IsFight()），避免与高频战斗包同帧并发（鱼刚入包由 ReplicateFishCaught 独立触发上锁）
    if not FishGate.IsFight() and (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) and (now >= nextProtectAt) and pData then
        nextProtectAt = now + HRand(1.2, 0.12)
        TryFavoriteProtectedFish(pData, false)
    end

    if gateIdleNow then
        -- [模块 22-B] 用闸门的"空闲"判定（含 0.8s 退出宽限）
        -- 容错：配置值被外部改写为非数值时退化为默认 30s，避免本条比较抛错连带整段低频自动化停摆
        if Config.AutoSell and (now - lastSellTime >= DashUI.ClampNum(Config.SellInterval, 10, 3600, 30)) then
            SafeSellAllFish(pData)
            lastSellTime = now
        end

        -- 角色动作卡死守护：若当前未钓鱼且未手持鱼竿，自动排查并清理残留的钓鱼/持竿动作姿态
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

    -- 神灵祈祷节拍 span 0.35（远程序列，动作冷却门，非检测窗口）。
    -- [FIX-12] 祈祷属"空闲挂机动作"：非空闲（搏斗中/鱼线在水里/退出宽限内）一律不触发，否则会在战斗途中点神灵 ProximityPrompt（服务端可见的交互请求）。
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

    -- 扭蛋节拍 span 0.35（远程序列，动作冷却门，非检测窗口）。
    -- [FIX-12] 扭蛋是纯空闲动作：非空闲不抽，避免战斗中途向服务端发 Gacha 包。
    if gateIdleNow and Config.AutoGacha and (now >= nextGachaAt) then
        nextGachaAt = now + HRand(1.5, 0.35)
        local bannerArg = FSYC.GachaBannerMap[Config.GachaBanner] or "Taiji Banner"
        SafeFireEventRemote("Gacha", bannerArg, Config.GachaPullsPerAction)
    end

    -- 喂猴批量节拍 span 0.45（对话/UI，动作冷却门，非检测窗口）。
    -- [FIX-06/12] 只在空闲时触发：GiveFish 系列走 SafeFireOneRemote、不经 PacketGuard 去重，战斗/钓鱼途中发会被服务端看到。
    if gateIdleNow and Config.AutoGiveMonkey and (now >= nextMonkeyAt) then
        nextMonkeyAt = now + HRand((FSYC.Tunables and FSYC.Tunables.MonkeyGiveIntervalSec) or 4.0, 0.45)
        if RunGiveFishToMonkeyBatch then RunGiveFishToMonkeyBatch() end
    end

    if gateIdleNow and Config.AutoClaimDaily and (now - lastDailyTime >= (FSYC.Tunables and FSYC.Tunables.DailyAutoIntervalSec or 300.0)) then
        -- 与手动领取每日奖励共享 isClaimingDailySign 互斥锁，杜绝自动与手动协程并发重入
        if not (isClaimingDailySign and (now - (FSYC.dailySignLockAt or 0)) < 30) then
            lastDailyTime = now
            if Events then
                local dailyRem = Events:FindFirstChild("DailyReward") or Events:FindFirstChild("ClaimDailyReward")
                if dailyRem then
                    dailyMissingWarned = false
                    isClaimingDailySign = true
                    FSYC.dailySignLockAt = now
                    task.spawn(function()
                        pcall(function()
                            local delaySec = math.max(0.4, DashUI.ClampNum(Config.DailyClaimDelay, 0.3, 2, 0.5))
                            if FishGate.IsIdle() then
                                for day = 1, 7 do
                                    if not isRunning or not Config.AutoClaimDaily then break end
                                    -- 若中途进入钓鱼/搏斗状态则等待空闲后再继续领取剩余天数，既不打断 2~7 天也不在搏斗中途发签到包
                                    -- [V15.46] 每天最多等 120s 空闲，等待期间续期互斥锁；超时放弃本次自动签到（下次定时再试），绝不在搏斗中途发包
                                    local autoIdleDeadline = tick() + 120
                                    while isRunning and Config.AutoClaimDaily and tick() < autoIdleDeadline and FishGate and not FishGate.IsIdle() do
                                        FSYC.dailySignLockAt = tick()
                                        task.wait(0.3)
                                    end
                                    if not isRunning or not Config.AutoClaimDaily then break end
                                    if FishGate and not FishGate.IsIdle() then break end
                                    FSYC.dailySignLockAt = tick()
                                    if dailyRem:IsA("RemoteEvent") then
                                        SafeFireEventRemote(dailyRem, day)
                                    elseif dailyRem:IsA("RemoteFunction") then
                                        DashUI._safeInvokeAsync(dailyRem, 3.0, day)
                                    end
                                    task.wait(delaySec)
                                end
                            end
                        end)
                        isClaimingDailySign = false
                    end)
                elseif not dailyMissingWarned then
                    dailyMissingWarned = true
                    ShowNotification("每日奖励", "当前服务器未找到每日奖励远程事件，自动领取已跳过。", "WARN", 4)
                end
            end
        end
    end

    -- 合成鱼饵与购买鱼饵同样受 gateIdleNow 门控，防止在抛竿或小游戏搏斗中途穿插商店/合成发包
    if gateIdleNow and Config.AutoCraftBait and (now >= nextCraftAt) then
        nextCraftAt = now + HRand(FSYC.Tunables and FSYC.Tunables.CraftAutoIntervalSec or 10.0, 0.35)
        SafeFireEventRemote("CraftBait", Config.CraftBaitName, Config.CraftAmount)
    end

    if gateIdleNow and Config.AutoBuyBait and (now >= nextBaitBuyAt) then
        nextBaitBuyAt = now + HRand(DashUI.ClampNum(Config.BuyBaitDelay, 5, 3600, 30), 0.35)
        if pData then
            local currentAmount = DashUI._getBaitQty(pData, Config.BuyBaitName)
            -- 抓包硬约束 1：BuyBait 第 2 参恒为 1（#141/#143/#145/#147/#149/#151 全为 1，回执 CurrencyNotify("Bait",1,名) 一致）；>1 未观测，一律按 1 发。
            -- 抓包硬约束 2：单种上限 500（#150/#152 "You can only have 500 baits of this type at the same time!"），顶上限时不加库存也不扣钱 → 跳过。
            if currentAmount >= 500 then
                FLogWarn("诱饵", string.format("%s 已达 500 上限，跳过购买", tostring(Config.BuyBaitName)))
            elseif currentAmount < DashUI.ClampNum(Config.BuyBaitThreshold, 5, 50, 10) then
                SafeFireEventRemote("BuyBait", Config.BuyBaitName, 1)
            end
        end
    end
end

-- 仪表盘文本写入去重：值相同不重复写 Roblox Text 属性（每 0.5s 约省 20 次属性写与文本重排）
local function SetDashLbl(lbl, txt)
    if lbl and lbl.Parent and lbl.Text ~= txt then lbl.Text = txt end
end

-- 背包鱼数统一计数（仪表盘与抛竿前满包判定共用），带 0.5s TTL 避免同帧重复全量遍历
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

-- [0.50s 周期] 更新仪表盘实时统计卡片（挂机时长、Ping、坐标、现金/钓鱼速率、背包容量）及每 5s 检查一次自动最佳配装
local function stepDashboardAndEquip(now)
    -- [UI-STATUS] 底部常驻状态条：与仪表盘同节拍调用，内部再按 1s 节流（只读，不发包、不改业务）
    if now - (DashUI._footerStatusAt or 0) >= 1.0 then
        DashUI._footerStatusAt = now
        if DashUI.RefreshFooterStatus then pcall(DashUI.RefreshFooterStatus) end
        -- [UI-STATUS] 悬浮球状态灯与底栏同源同频，保证两处永远一致
        if DashUI.RefreshBallStatus then pcall(DashUI.RefreshBallStatus) end
        -- [UI-重构] 首页场景卡状态点：与上面同一节拍，绿=该场景已全开 / 黄=部分开 / 灰=没开
        if DashUI.RefreshHomeScenes then pcall(DashUI.RefreshHomeScenes) end
    end
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
                    -- 未知竿名时只补一条一次性可见告警，"跳过更换"的原有行为保持不变
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

-- ============================================================================
-- [方案A / 雷达三态总开关] config.RadarMode：全开 / 静默 / 关
--   全开：扫描 + 弹窗 + 挂 ESP（原行为，默认）
--   静默：照常扫描（OnlineNPCs 仍需维护，NPC 远程对话与传送页状态都靠它），但所有弹窗一律静音
--   关  ：完全不扫描、不弹窗、不挂 ESP、不预加载岛屿、不跑自动跳服；已挂的标记一次性摘干净
-- 为什么要有「静默」这档：雷达扫描结果 OnlineNPCs 是 NPC 远程对话的缓存来源（见 OpenRemoteNPCDialogue），
--   全关之后对话不坏但会退化成每次现场扫描、更慢。静默档保留扫描、只掐掉弹窗。
-- ============================================================================
local function RadarModeNow()
    local m = Config.RadarMode
    if m == "关" or m == "静默" then return m end
    return "全开"
end

-- 静默档只扫描不弹窗：所有雷达弹窗统一走这里（含四圣兽特质提示）
local function RadarNotify(title, text, typ, dur)
    if RadarModeNow() ~= "全开" then return end
    if ShowNotification then pcall(ShowNotification, title, text, typ, dur) end
end

-- 「关」档的收敛动作：摘掉所有标记与缓存，并把传送页 10 行改成「雷达已关闭」
-- 每轮关档 tick 都跑一次（空表遍历近似零成本），保证改配置/切存档后界面一定是对的。
local function RadarOffPass()
    -- 1) 摘掉所有 ESP 标记
    for inst in pairs(activeESP) do
        pcall(RemoveESP, inst)
    end
    -- 2) 清掉雷达缓存与状态
    for _, key in ipairs(liveNPCOrder) do
        local data = liveNPCs[key]
        if data then
            data.pos = nil
            data.inst = nil
            data.lastSeen = nil
        end
    end
    table.clear(OnlineNPCs)
    table.clear(wsRootRadarModels)
    radarWasFound = {}
    -- 3) 传送页 10 行显示「雷达已关闭」，避免看着像「没检测到」而以为脚本坏了
    for _, key in ipairs(liveNPCOrder) do
        local data = liveNPCs[key]
        if data and data.ui_title then
            local offTitle = data.icon .. " " .. data.name .. " (雷达已关闭)"
            local offDesc = "雷达总开关为「关」：不扫描、不提示、不挂标记"
            local offBtnLabel = data.fallbackPos and "前往岛屿" or "传送"
            if data.ui_title.Text ~= offTitle then data.ui_title.Text = offTitle end
            if data.ui_title.TextColor3 ~= Colors.TextMuted then data.ui_title.TextColor3 = Colors.TextMuted end
            if data.ui_desc.Text ~= offDesc then data.ui_desc.Text = offDesc end
            if data.ui_btn.BackgroundColor3 ~= Colors.ControlBg then data.ui_btn.BackgroundColor3 = Colors.ControlBg end
            if data.ui_btn.TextColor3 ~= Colors.TextMuted then data.ui_btn.TextColor3 = Colors.TextMuted end
            if data.ui_btn.Text ~= offBtnLabel then data.ui_btn.Text = offBtnLabel end
        end
    end
end

-- UI 下拉回调入口：切到「关」时立即收敛一次，切到其它档时清掉关档标记让下一轮雷达照常跑
DashUI._radarApplyMode = function(mode)
    if mode == "关" then
        pcall(RadarOffPass)
        ShowNotification("雷达已关闭", "不再扫描、不弹窗、不挂 ESP，也不会自动跳服", "WARN", 4)
    elseif mode == "静默" then
        ShowNotification("雷达已静默", "照常扫描（NPC对话/传送页可用），但不再弹窗；ESP 仍按各自开关显示", "INFO", 4)
    else
        ShowNotification("雷达已全开", "扫描、弹窗、ESP、自动跳服全部恢复", "SUCCESS", 3)
    end
end

-- 全图雷达扫描：检测三岛神灵、流动商人、四圣兽特质/Boss、挂载动态实体 ESP 并驱动自动跳服
-- [Delta 减负 M15] 全图雷达匹配串构造缓冲（挂载于 FSYC，0 顶层 local 占用），整轮扫描复用同一张表。
FSYC._radarMatchPartsBuf = {}

local function stepWorldRadar(now)
    now = now or tick()
    -- [方案A] 关档：只做收敛，不扫、不挂、不跳服
    if RadarModeNow() == "关" then
        return RadarOffPass()
    end
    local nowDialogueOpen = IsDialogueUIOpen(false)
    -- 对话由开→关必清；其余情况仅在未微瞬移时清
    if not nowDialogueOpen and (radarWasDialogueOpen or not isMicroTeleportingNPC) and DismissStuckPromptsAndRestore then
        DismissStuckPromptsAndRestore(false)
    end
    radarWasDialogueOpen = nowDialogueOpen

    local char = LocalPlayer.Character
    local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
    local found = {}
    local foundOnlinePass = {}
    table.clear(inspectedRadarPass)

    -- 后台非阻塞轮询预加载远端神灵祭坛与各岛中心（每 5s 预加载 1 个远端岛屿，全图 12 岛覆盖神灵/道士/茅山/傻子商人/四圣兽实时弹窗与刷新检测；由 TryStreamAroundPosition 内部单飞锁防堆积）
    if not isMicroTeleportingNPC and not attrMinigame and (now - lastStreamPrefetchTime >= 5.0) then
        lastStreamPrefetchTime = now
        streamPrefetchIdx = (streamPrefetchIdx % #streamPrefetchPoints) + 1
        local pt = streamPrefetchPoints[streamPrefetchIdx]
        if pt and (not myPos or (myPos - pt).Magnitude > 450) and TryStreamAroundPosition then
            pcall(TryStreamAroundPosition, pt)
        end
    end

    -- 多语言实体识别（兼容 Model/BasePart/Folder 及 ProximityPrompt 溯源，避免琥珀神灵与流动商人漏检）
    local function inspectEntity(npc, allowDeepSummary, promptHint)
        if not npc or npc == char or IsMapOrIslandContainer(npc) then return end
        local dedupKey = promptHint or npc
        if inspectedRadarPass[dedupKey] then return end
        if not (npc:IsA("Model") or npc:IsA("BasePart") or npc:IsA("Folder")) then return end
        inspectedRadarPass[dedupKey] = true
        if npc:IsA("Model") and Players:GetPlayerFromCharacter(npc) then return end
        if IsToolFishingRod and IsToolFishingRod(npc) then return end

        local name = npc.Name or ""
        -- [本地化] 名称与交互提示全部走越南语大写折叠（:lower() 只折叠 ASCII，Đ/Ả/Ầ 会漏判）
        local nLow = LowerInstNameG(npc)
        -- [Delta 减负 M15] 复用构造缓冲表：消除每轮雷达扫描对场景数百个实体逐一新建临时表（table.concat 后即不再引用）。
        local matchParts = FSYC._radarMatchPartsBuf
        table.clear(matchParts)
        matchParts[1] = nLow
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
                RadarNotify("📜 道士商人降临", "道士商人 (Taoist Merchant) 已在服务器刷新！", "SUCCESS", 6)
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
                RadarNotify("✨ 茅山商人降临", "茅山商人 (Maoshan Merchant) 已在服务器刷新！", "SUCCESS", 6)
            end
        elseif matchStr:find("dumb", 1, true) or matchStr:find("thang ngu", 1, true) or matchStr:find("thangngu", 1, true)
            or matchStr:find("thằng ngu", 1, true) or matchStr:find("thằng ngốc", 1, true) or matchStr:find("thang ngoc", 1, true)
            or matchStr:find("傻子", 1, true) or matchStr:find("笨蛋", 1, true) then
            isMerchant = true
            -- 名称统一：liveNPCs 正式名是"傻子隐藏商人"，名字不一致会让 AddESP 的 existing.name 每轮覆盖、图标名来回跳。
            AddESP(npc, "傻子隐藏商人 (Dumb Guy)", "DumbGuy", Colors.AccentYellow, "🃏", pos)
            liveNPCs.DumbGuy.pos = pos
            liveNPCs.DumbGuy.inst = npc
            liveNPCs.DumbGuy.lastSeen = now
            found.DumbGuy = true
            if not radarWasFound.DumbGuy then
                RadarNotify("🃏 隐藏商人降临", "傻子隐藏商人 (Dumb Guy) 已在服务器刷新！", "SUCCESS", 6)
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
                    RadarNotify("🔥 四圣兽现世", bSpec.cnName .. " 已在当前服务器出现！", "SUCCESS", 6)
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

                -- 严格约束：神灵实体必须真实位于三座神灵岛专属祭坛 450 studs 范围内！
                -- 严禁将战场岛、初始岛等非神灵岛屿上的实体（如带有 spirit 词汇的 NPC 或物体）错误归类为神灵！
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
                            RadarNotify("⛩️ 神灵降临", liveNPCs[spKey].name .. " 已在服务器刷新！", "SUCCESS", 6)
                        end
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

    -- 扫描全部 NPC/神灵祭坛/Boss 专用容器（支持 3 层子结构）；目录名单与 FindNPCInstancesBySpec 共用 FSYC.NPC_SCAN_CONTAINER_NAMES
    for _, folderName in ipairs(FSYC.NPC_SCAN_CONTAINER_NAMES) do
        local folder = GetWorkspaceFolder(folderName)
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do
                if IsMapOrIslandContainer(ch) then
                    for _, sub in ipairs(ch:GetChildren()) do
                        pcall(inspectEntity, sub, true)
                    end
                else
                    -- [PERF-R4] 父节点名字已命中关键字时，其「叶子零件」子节点（自身无关键字、无子节点）不带来新增判定信息
                    -- （匹配串只有零件名 + 父名，两者已被覆盖），逐个 inspect 纯属重复解析，直接跳过；其余情况照旧下沉。
                    local parentNamedHit = HasRadarKeyword(LowerInstNameG(ch))
                    pcall(inspectEntity, ch, true)
                    if ch:IsA("Folder") or ch:IsA("Model") then
                        for _, sub in ipairs(ch:GetChildren()) do
                            if parentNamedHit and sub:IsA("BasePart") and #sub:GetChildren() == 0
                                and not HasRadarKeyword(LowerInstNameG(sub)) then
                                -- 纯身体零件，跳过
                            else
                                pcall(inspectEntity, sub, true)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 扫描 Islands / Map 下各岛屿顶层子项（捕捉直接挂在岛屿目录下的常驻神灵祭坛如琥珀神灵及岛屿专属 NPC）
    for _, mapFolderName in ipairs(MAP_ROOT_NAMES) do
        local mapFolder = GetWorkspaceFolder(mapFolderName)
        if mapFolder then
            for _, isl in ipairs(mapFolder:GetChildren()) do
                if isl:IsA("Folder") or isl:IsA("Model") then
                    for _, ch in ipairs(isl:GetChildren()) do
                        local cnLow = LowerInstNameG(ch) -- [本地化] 越南语大写折叠（按实例缓存）
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
            -- 增加合法性校验：如果 data.fallbackPos 存在（如三大神灵），data.pos 必须在其 450 米以内！
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
                -- 模型还 parented 就无条件保活会让"关不掉的最后一个标记"永不消失（游戏把商人挪进隐藏文件夹/停用而不 Destroy 时，雷达扫不到但 found 恒 true）。
                -- 改为：超过 10s 未复见即视为离场，主动摘标记。
                local ESP_STALE_KEEP = 10.0
                local seenFresh = (data.lastSeen == nil) or ((now - data.lastSeen) <= ESP_STALE_KEEP)
                local isFarUnloaded = (data.pos ~= nil and myPos ~= nil and (myPos - data.pos).Magnitude > 450)
                if data.inst and data.inst.Parent and seenFresh then
                    found[key] = true
                    data.pos = GetNPCPosition(data.inst) or data.pos
                    if key:find("^Spirit_") then found.AnySpirit = true end
                elseif isFarUnloaded and data.lastSeen and (now - data.lastSeen < 180.0) then
                    -- 远距离流式卸载期间保留 180 秒（3 轮全岛轮询周期）已检测状态，防止 10 秒后误判神灵/商人消失
                    found[key] = true
                    if key:find("^Spirit_") then found.AnySpirit = true end
                elseif data.inst and data.inst.Parent then
                    if activeESP and activeESP[data.inst] then pcall(RemoveESP, data.inst) end
                    data.inst = nil
                    data.pos = nil
                    data.lastSeen = nil
                end
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
                                local vLow = tqLc(rawVal)
                                for _, bSpec in ipairs(FourSacredBeastsSpecs) do
                                    for _, alLow in ipairs(bSpec.lowerAliases) do
                                        if vLow:find(alLow, 1, true) then
                                            local noticeKey = bSpec.liveKey .. "_" .. d:GetFullName()
                                            if not radarNotifiedTraits[noticeKey] then
                                                radarNotifiedTraits[noticeKey] = true
                                                radarNotifiedTraits._count = (radarNotifiedTraits._count or 0) + 1
                                                RadarNotify("🎉 四圣兽神话特质降临！", string.format("检测到四圣兽 [%s] 已激活于 [%s]！", bSpec.cnName, d.Parent and d.Parent.Name or d.Name), "SUCCESS", 8)
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

    -- 刷新传送页面的 10 个特殊 NPC 实时状态行（仅在文本/颜色真正变化时才写属性，避免每 1.25s 触发整块 UI 重排）
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
        local inBusyState = attrMinigame or wasInMinigame or attrFishing or isSellingInProgress or (FishGate and not FishGate.IsIdle())
        if not inBusyState and (
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
    if RadarModeNow() == "关" then
        ShowNotification("雷达已关闭", "当前雷达总开关为「关」，如需扫描请先切到「静默」或「全开」", "WARN", 4)
        return
    end
    stepWorldRadar(tick())
end

-- [5.0s 周期] 巡检并清理目标已离开或已销毁的残留 ESP 实例
local function stepESPCleanup()
    -- 即使 activeESP 为空也要做一次 64 槽位清扫：否则「条目已从弱键表消失、但槽位仍 inUse」的孤儿槽位永不回收，
    -- 池满后表现为"有的目标就是高亮不出来"。
    for inst, data in pairs(activeESP) do
        if not inst.Parent
            or not data.part or not data.part.Parent
            or not data.gui or not data.gui.Parent then
            pcall(RemoveESP, inst)
        end
    end
    if SweepOrphanSlots then pcall(SweepOrphanSlots) end
end

-- 统一后台调度器（取代原先 4 个独立轮询协程 + Heartbeat 低频分支）：主体抽成具名函数，由外层监护协程 pcall 调用。
-- 循环体内除 SafeStep 外还有时间运算/FLog/Config 读取/next() 遍历等裸语句，任一处抛错都会让整个协程静默死亡，
-- 表现为"脚本还开着但什么都不做了"；现在异常会被捕获、写一条 ERROR 日志，并在 3s 后自动重启调度器。
-- [Delta 减负 M1] 注册事务忙守卫与可重建缓存裁剪钩子（只清过期/可重建缓存，不动任何业务队列与发包节拍）：
if FSYC.Gov then
    -- 卖鱼/日常任务/每日签到/NPC微瞬移/猴子批量期间视为忙，不触发空闲软重置
    FSYC.Gov.AddBusyGuard(function()
        if isSellingInProgress or isClaimingDailyTask or isClaimingDailySign or isMicroTeleportingNPC then
            return true
        end
        local mk = FSYC.monkeyCtl
        return (mk and mk.running) == true
    end)
    -- 1) NPC 扫描缓存（0.5s TTL，清理 >120s 过期项与已销毁实例引用）
    if FSYC.TrimNpcScanCache then FSYC.Gov.RegisterTrim("NPC扫描缓存", FSYC.TrimNpcScanCache) end
    -- 2) 对话按钮候选缓存（0.5s TTL，清理 >60s 未命中列表）
    if FSYC.TrimDialogueCache then FSYC.Gov.RegisterTrim("对话按钮缓存", FSYC.TrimDialogueCache) end
    -- 3) 规则字符串匹配缓存（仅当 >96 条时裁剪，保留热路径命中率）
    FSYC.Gov.RegisterTrim("规则匹配缓存", function()
        if patternCacheCount > 96 then
            table.clear(patternCache)
            patternCacheCount = 0
            table.clear(cachedRuleMatchers)
            FSYC.cachedRuleSource = nil
        end
    end)
    -- 4) ESP 孤儿槽位兜底回收（只回收 Adornee 已失效槽位，不动在用标记）
    FSYC.Gov.RegisterTrim("ESP孤儿槽位", function()
        if DashUI and type(DashUI._sweepOrphanSlots) == "function" then
            pcall(DashUI._sweepOrphanSlots)
        end
    end)
    -- 5) 发包去重窗口过期条目增量清理（只删除 >120s 的陈旧键，绝不清空活跃去重窗口）
    FSYC.Gov.RegisterTrim("发包去重过期键", function()
        if PacketGuard and type(PacketGuard.lastAt) == "table" then
            local nowP = tick()
            for k, t in pairs(PacketGuard.lastAt) do
                if type(t) ~= "number" or (nowP - t) > 120.0 then
                    PacketGuard.lastAt[k] = nil
                end
            end
        end
    end)
end

local function RunBackgroundScheduler()
    local lastEspRefreshTick = 0
    local lastLowFreqTick = 0
    local lastDashTick = 0
    local lastRadarTick = 0
    local lastEspCleanTick = tick()
    local lastWSScanBackfill = tick()
    -- 空闲低负载（仅调度器内部局部变量，不新增全局）：连续 5s 未钓鱼且未小游戏才降两项非检测开销
    local idleSince = 0
    local idleLowLoad = false
    local lastCombatLow = false
    local combatSince = 0
    while isRunning do
        local powerSave = Config.Disable3DRendering
        task.wait(powerSave and 0.25 or 0.15)
        if not isRunning then break end
        local now = tick()

        -- 一进入钓鱼/小游戏立即恢复原频率；低频自动化 0.25s、30s 补扫、0.15s 主 tick 均不受影响
        local inGameplay = attrFishing or attrMinigame or wasInMinigame or cachedIsHooked
        -- [Delta 减负 M1] 复用既有 0.15s 时间片驱动资源治理器，零新增事件连接/协程，不改变下方任何业务节拍。
        if FSYC.Gov then SafeStep("资源治理", FSYC.Gov.Tick, FSYC.Gov, now, (not inGameplay)) end
        if inGameplay then
            idleSince = 0
            idleLowLoad = false
        elseif idleSince == 0 then
            idleSince = now
        elseif not idleLowLoad and (now - idleSince >= 5.0) then
            idleLowLoad = true
        end
        -- [流畅度] 搏斗期自适应降载（仅搏斗期，非搏斗期频率完全不变）：雷达 0.8→2.0s、ESP 距离 0.15→0.35s、仪表盘 0.5→1.0s；
        -- 退出搏斗后下一 tick 立即恢复（不依赖 5s 空闲判定）；Config.OctoAutoMinigame 开启时依赖雷达与 prompt 时效，不降频；首次进入搏斗先补扫一轮。
        -- 0.2s 稳定期 + 补扫间隔≥0.5s：避免信号按调度同频抖动时反复进出低载、把补扫放大成雷达风暴。
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

        -- 1) 0.15s（空闲 0.45s）ESP 距离与开关轻量刷新（当全部 ESP 关闭但仍有残留条目时立即执行一次彻底清理）
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

        -- 2) 0.25s 低频自动化业务（出售、保护上锁、祈祷、票据任务、扭蛋、猴子、每日签到、制作与购买鱼饵）
        if now - lastLowFreqTick >= 0.25 then
            lastLowFreqTick = now
            SafeStep("低频自动化", stepLowFreqAutomation, now)
        end

        -- 3) 0.50s（空闲 1.00s）仪表盘与自动装备更新
        -- 雷达周期需叠加主 tick 量化误差（普通 0.15s / 省电 0.25s）：普通 0.80s → 最坏 0.90s 触发；省电 0.65s → 最坏 0.75s。
        -- 要求 NPC/神灵「到人」必须在 1s 内被发现，两种模式都 < 1s；省电靠关 3D/ESP 与仪表盘降频，不牺牲雷达时效。
        -- [方案A] 关档：不再按 0.8s 跑全图扫描，改成 2s 一次的「收敛 tick」（只清标记/刷界面，近零成本）
        local radarOff = (RadarModeNow() == "关")
        local radarInterval = radarOff and 2.0 or (powerSave and 0.65 or (combatLowLoad and 2.0 or 0.8))
        local radarDue = (now - lastRadarTick >= radarInterval)
        -- 雷达到期的 tick 让仪表盘顺延一个 tick（≤0.15s），避免"雷达 + 仪表盘"同帧双份重活；仪表盘计时器只在真正执行时推进，周期仍 0.50s。
        if now - lastDashTick >= dashInterval and not radarDue then
            lastDashTick = now
            SafeStep("仪表盘统计", stepDashboardAndEquip, now)
        end

        -- 4) 全图雷达扫描（radarInterval：普通 0.8s / 省电 0.65s / 搏斗低载 2.0s）
        -- 每 30s 增量补扫：捕捉先以匿名 Model 插入 Workspace、后被服务端改名为 Boss/神灵/商人的实例。
        -- 补扫独立成一个 tick 判定，不与雷达同帧执行（周期仍 30s），避免"Workspace 全扫 + 全图雷达"叠在一帧卡顿。
        if not radarOff and now - lastWSScanBackfill >= 30.0 then
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
        elseif now - lastEspCleanTick >= 5.0 then
            -- 5) 5.0s ESP 失效清理：兜底清扫 activeESP 已空但 proxyPart 槽位仍占用的孤儿槽位
            lastEspCleanTick = now
            SafeStep("ESP失效清理", stepESPCleanup)
        end
    end
end
task.spawn(function()
    while isRunning do
        local okRun, runErr = pcall(RunBackgroundScheduler)
        if okRun then break end
        if not isRunning then break end
        FLogErr("后台调度器", "调度器异常退出，3 秒后自动重启：" .. tostring(runErr))
        task.wait(3.0)
    end
end)

-- ==========================================
-- 【模块 27-A：自动技能节奏引擎 (AutoSkillEngine v2) —— 严格顺序 / 起手等待 / 单技能冷却 / 单通道施法】
-- 职责：把「何时放第几个技能」从 Heartbeat 收敛成一个状态机 —— 严格顺序下标、每技能独立冷却、
--       1.5s 退出宽限抗 UI 闪烁、一次意图只走一条通道、失败只重试当前位（不推进下标）。
-- 后续修改：手感参数在 UI「技能轮换与节奏 (Z/X/C/V)」分组；四个技能冷却不同时改 CooldownFor(slot)。
-- ============================================================================
-- [AUTO-SKILL-ENGINE-BEGIN]
local function CreateAutoSkillEngine(deps)
    deps = deps or {}
    local cfg = deps.config or {}
    local logFn, warnFn = deps.log, deps.warn
    local getIndex, setIndex = deps.getIndex, deps.setIndex
    local jitterFn = deps.jitter    -- 拟人化抖动：返回 0~max 的随机秒数；测试里不传则恒为 0（确定性）

    -- ---- 内部常量（统一从顶部 FSYC.Tunables 读取，支持集中调优） ----
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
        -- 战斗存活状态
        inFight = false,
        fightStartAt = 0,
        warmJitter = 0,     -- 本场起手等待的拟人抖动（0~0.6s，每场重抽）
        lastSignalAt = 0,
        lastStrongAt = 0,   -- 最近一次「游戏自身小游戏状态/UI」为真的时刻
        strongRun = 0,          -- 强信号「连续」持续时长（一断即清零，避免零星闪烁累计成权威）
        strongAuthoritative = false, -- 本场强信号是否曾连续稳定 ≥STRONG_MIN（一旦成立即锁存到本场结束）
        blockWeakEntry = false, -- 弱信号超时收场后置真：必须等"弱信号先消失再出现"或强信号，才允许开下一场
        lastStepAt = 0,         -- 上一次 Step 的时间戳，用于累计连续时长
        relockUntil = 0,    -- 退出后仅凭弱信号重新进入的锁定截止时刻
        -- 顺序表
        seq = {},
        seqSig = "",
        -- 冷却 / 节拍
        readyAt = {},
        broken = {},
        failCount = {},
        nextCastAt = 0,
        lastCastAt = 0,
        -- 保命技能
        panicUsed = false,
        -- 冷却倒计时读取（从变灰的技能按钮上读剩余秒数）
        probe = {},
        nextProbeAt = 0,
        probeFails = 0,     -- 连续读不到次数：用于退避，避免读不到时 10 次/秒空扫
        probeInterval = 0.4,
        deferCount = {},    -- 每个技能位被"界面显示还在冷却"挡下的次数：超过上限就放弃界面读数，回落到配置冷却
        lastRead = {},      -- 每个技能位上一次读到的剩余秒数：只有"读数不递减"才算可疑；真倒计时递减就不累计
        deferOff = {},      -- 被判定为"读数值不可信"的技能位（本场战斗内不再采信界面读数）
        -- [V15.31 / SKILL-FIRST] 本场已经真正放出去的技能位（按位记）：没放过的位不采信界面读数
        castThisFight = {},
        stallWarned = false,   -- [V15.31] 连续 10s 发不出技能时只提示一次
        -- 统计与调试
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

    -- 安全取数：任何非法值都退回默认，绝不把 nil/NaN 带进计时比较
    local function Num(v, def, lo, hi)
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then return def end
        if lo and n < lo then n = lo end
        if hi and n > hi then n = hi end
        return n
    end

    -- 默认值与上下界与 Config / ConfigNumericBounds / UI 滑块保持严格一致，避免"界面一个值、引擎另一个值"
    -- 拟人化抖动（幅度都很小，只为不让时间戳精确到毫秒级恒定）
    local function Jit(max)
        if not jitterFn then return 0 end
        local ok, v = pcall(jitterFn, max)
        if ok and type(v) == "number" and v == v and v > 0 and v <= max then return v end
        return 0
    end

    local function StartDelay() return Num(cfg.SkillStartDelay, 2.5, 0.5, 10) end
    local function Gap() return Num(cfg.SkillInterval, 1.5, 0.5, 5) end
    -- 每个技能各自一套冷却（游戏内 Z/X/C/V 完全独立，3~999s）；没单独配置时退回旧字段 SkillCooldown
    local function CooldownFor(slot)
        local per
        if slot == "Z" then per = cfg.SkillCdZ
        elseif slot == "X" then per = cfg.SkillCdX
        elseif slot == "C" then per = cfg.SkillCdC
        elseif slot == "V" then per = cfg.SkillCdV end
        -- [V15.31 / CD-RANGE] 下界 3 → 1（与 UI 滑块、ConfigNumericBounds 保持一致）
        return Num(per, Num(cfg.SkillCooldown, 30, 1, 999), 1, 999)
    end

    -- ============================================================================
    -- [READ-TRUST] 按钮读数不一定是剩余冷却（技能等级/层数也是纯数字）：只有「≤3s」或「0.6s 内确实变小」
    -- 才采信，否则当作读不到、交回本地配置冷却决定，绝不因一个可疑数字把技能锁死。
    -- ============================================================================
    local readPrev = {}
    local function ReadIsCredible(slot, v, now)
        if type(v) ~= "number" then return false end
        if v <= 3 then readPrev[slot] = nil; return true end
        local prev = readPrev[slot]
        -- [审计修复 COM-09] 采样间隔 <0.6s（如 0.4s 探针、0.35s 施法前复核或同帧二次调用）时保留基准时间戳 prev.t，
        -- 防止每次调用都无条件把 prev.t 重置为 now 导致 (now - prev.t) 永远 <0.6s 而陷入死锁。
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

    -- 依据 Config.SkillOrder + 四个勾选开关生成本场顺序表；顺序表变化会返回新的指纹
    -- [性能] 用「原始顺序串 + 勾选位掩码」做零分配指纹：每帧只比两个标量，绝不重复 gsub / 建表
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
        -- 兜底：用户把顺序框清空成非法字符时，回退到勾选顺序 Z→X→C→V
        if #out == 0 then
            if cfg.SkillZ then out[#out + 1] = "Z"; seen["Z"] = true end
            if cfg.SkillX then out[#out + 1] = "X"; seen["X"] = true end
            if cfg.SkillC then out[#out + 1] = "C"; seen["C"] = true end
            if cfg.SkillV then out[#out + 1] = "V"; seen["V"] = true end
        end
        seqCacheOut, seqCacheSig = out, table.concat(out, ",")
        return seqCacheOut, seqCacheSig
    end

    -- 进入战斗：重置顺序与保命计数，并清空本地冷却（每场以界面读数为准，避免跨场 30s 静默）
    local function EnterFight(now)
        S.inFight = true
        S.fightStartAt = now
        S.lastSignalAt = now
        S.lastStrongAt = now
        S.strongRun = 0
        S.strongAuthoritative = false
        S.panicUsed = false
        -- 每场战斗重新给"读冷却"一次机会：上一场被判定不可信的技能位，这一场再试
        ClearMap(S.deferOff)
        ClearMap(S.deferCount)
        ClearMap(S.lastRead)
        S.probeFails = 0
        S.probeInterval = 0.4
        ClearMap(S.broken)
        ClearMap(S.failCount)
        ClearMap(S.castThisFight)
        readPrev = {}          -- [V15.31 / READ-TRUST] 每场重置读数记忆，避免上一场的数字影响本场判定
        S.stallWarned = false
        -- [14.9 修复 H2] 每场重新以界面读数为准：清掉上一场留下的配置冷却（默认 30s 远大于真实冷却，
        -- 否则第二杆起会整整 30s 一个技能都不放）。清理后若界面读到数字，仍会在施法前被重新校正。
        ClearMap(S.readyAt)
        S.stats.fight = S.stats.fight + 1
        S.stats.fightCast = 0
        -- 起手时间也做一点点拟人抖动（最多 +0.6s），避免"每一杆都精确在 2.500s 放技能"
        S.warmJitter = Jit(0.6)
        SetIndex(1)
        L(string.format("进入战斗：%d 个技能待放，起手等待 %.2fs", #S.seq, StartDelay()))
    end

    -- 退出战斗：只清顺序指针与瞬时状态；冷却由下一场进入时重新读界面校准
    local function ExitFight(now)
        S.inFight = false
        -- 只有「强信号权威」的战斗才需要重入锁：那种情况下残留的弱信号是脏数据；
        -- 而只有弱信号的模式本来就没有别的信号可用，再加锁只会让下一杆白白晚起手。
        S.relockUntil = (now or 0) + (S.strongAuthoritative and REENTER_LOCK or 0)
        SetIndex(1)
        L(string.format("战斗结束：本场释放 %d 次（累计 %d 次）", S.stats.fightCast, S.stats.cast))
    end

    -- 在顺序表里从当前位开始找「自身冷却已就绪」的技能位
    -- 严格模式：只看当前位（冷却没到就等），但【已熔断的位一律跳过】——否则熔断位会把顺序永久卡死；
    -- 非严格模式：沿顺序方向找第一个就绪且未熔断的位。
    -- [V15.31 / SKILL-ORDER] 释放模式解析：新字段优先，旧存档按 SkillStrict 布尔解释
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

        -- [V15.31 / BLIND] 盲轮转：不看本地冷却，每「技能间隔」秒按 Z→X→C→V 顺序点一个。
        -- 唯一刹车 = 按钮上是否显示倒计时数字：显示就跳过这一拍（指针照样前进，下一拍轮到下一位）。
        -- 这样既保留"定时点一下"的节奏，又不会明知在冷却还硬发（纯盲版约 50%~70% 的包会被服务端拒）。
        if mode == "blind" then
            local slot = S.seq[idx]
            local nxt = (idx % total) + 1
            local read
            -- 只有"本场真放过的位"才采信读数：没放过的位按钮上可能是上一场的残留数字
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

        -- 优先(Z→X→C→V)：每次都从顺序表头开始扫，谁靠前又就绪就放谁 —— Z 一好就放 Z
        if mode == "head" then
            for pos = 1, total do
                local slot = S.seq[pos]
                if not S.broken[slot] and now >= (S.readyAt[slot] or 0) then return slot, pos end
            end
            return nil, 1
        end

        -- 顺位优先：沿顺序方向找第一个就绪位（旧行为，冷却一乱就显随机）
        if mode == "priority" then
            for step = 0, total - 1 do
                local pos = ((idx - 1 + step) % total) + 1
                local slot = S.seq[pos]
                if not S.broken[slot] and now >= (S.readyAt[slot] or 0) then return slot, pos end
            end
            return nil, idx
        end

        -- 严格轮流：只看"当前位"，冷却没到就死等，绝不跳位
        local curSlot = S.seq[idx]
        if curSlot and not S.broken[curSlot] and now >= (S.readyAt[curSlot] or 0) then
            return curSlot, idx
        end
        return nil, idx
    end

    -- 主入口：每个 Heartbeat 帧调用一次（O(1) 早退、零表分配）
    -- ctx 为复用表：inMinigame（强信号=游戏自身小游戏状态/UI）/ weak（弱信号=合成判定）/ hpPct / cast(slot)
    -- 双信号的职责划分：
    --   · 「进入」战斗：强信号或弱信号任意一个为真即可（小游戏刚开、GUI 还没显形的头几帧也能及时起手计时）；
    --   · 「结束」战斗：强信号在本场稳定持续过 ≥0.5s 才以它为准（鱼模型残留在 Fishes 里时不会无限续命）；
    --     强信号从未稳定出现（该鱼种/该模式只给弱信号）则退化为以弱信号消失为准，避免死循环。
    function M.Step(now, ctx)
        local strong = (ctx.inMinigame == true)
        local anySignal = strong or (ctx.weak == true)
        -- 帧间隔（异常值一律按 0 处理，避免卡顿/重连把累计时长算飞）
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

        -- 1) 抗抖存活判定
        if not S.inFight then
            if not anySignal then
                S.lastReason = "idle"
                return "idle"
            end
            -- 刚结束一场战斗、且当前只有弱信号（残留咬钩缓存）时先锁一段时间，等游戏自身的小游戏状态重新为真
            if (not strong) and now < S.relockUntil then
                S.lastReason = "relock"
                return "relock"
            end
            -- 弱信号超时收场后，残留的 weak 不允许直接把下一场拉起来（必须 weak 先消失过一次，或强信号出现）
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
            -- 强信号在本场稳定持续过（≥0.5s）：以强信号消失为准（防止残留咬钩缓存续命）；
            -- 强信号从未稳定出现（该鱼种/该模式只给弱信号，或只闪了一帧）：退化为以弱信号消失为准，
            -- 否则「起手等待 2.5s > 退出宽限 1.5s」会让引擎陷入「进入→退出→锁定」的死循环、永不施法。
            ExitFight(now)
            S.lastReason = "exit"
            return "exit"
        end

        -- 1.5) 兜底：只有弱信号可用的模式下，鱼被钓走后模型有时不会被立刻清理（cachedIsHooked 假性为真），
        --      单场战斗超过 MAX_WEAK_FIGHT 就强制收场，避免"整局都在放技能"
        if (not S.strongAuthoritative) and (now - S.fightStartAt > MAX_WEAK_FIGHT) then
            ExitFight(now)
            S.blockWeakEntry = true
            S.lastReason = "weak-timeout"
            W(string.format("弱信号战斗已持续 %.0fs，判定为咬钩缓存残留，强制收场", now - S.fightStartAt))
            return "weak-timeout"
        end

        -- 2) 顺序表热更新（用户中途改勾选/顺序：从第 1 位重新起手，避免下标错位放大成乱序）
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

        -- 3) 起手等待：刚咬钩/刚进小游戏的一段时间内不交技能
        -- [V15.31 / SKILL-FIRST] 但「本场还没放过任何技能」时，按用户实测可以立刻放第一个技能：
        -- 游戏进入战斗会把技能 CD 重置，第一个技能必定可用，此时空等 2.5s 纯属浪费输出。
        local firstCastOfFight = (S.stats.fightCast == 0)
        -- 首技只留 0.20s（跨一两帧，避免"刚判定进战斗的那一帧就发包"），第二个技能起才用「起手等待」
        local warmBase, warmJit = StartDelay(), (S.warmJitter or 0)
        if firstCastOfFight and cfg.SkillFirstInstant ~= false then
            warmBase, warmJit = 0.20, 0
        end
        local waitLeft = (S.fightStartAt + warmBase + warmJit) - now
        if waitLeft > 0 then
            S.lastReason = "warmup"
            return "warmup"
        end

        -- 3.6) 冷却倒计时读取：施法后的短窗口内，从变灰的技能按钮上读"剩余秒数"，直接校正 readyAt。
        --      0.4s 一次、最多 10s、只针对刚放过的技能，开销可忽略；读不到就继续用配置里的兜底冷却。
        if cfg.SkillCdProbe ~= false and ctx.readCooldown and now >= S.nextProbeAt then
            local hasProbe = false
            for _ in pairs(S.probe) do hasProbe = true; break end
            if hasProbe then
                -- 退避：连续读不到就 0.4→0.8→1.6→3.2s，避免"读不到"时仍以每秒 10 次的频率空扫 UI
                S.nextProbeAt = now + S.probeInterval
                local gotAny = false
                for slotP, deadlineP in pairs(S.probe) do
                    if now > deadlineP then
                        S.probe[slotP] = nil
                    elseif not S.deferOff[slotP] then
                        local okRead, v = pcall(ctx.readCooldown, slotP)
                        -- v>=1 才算有效读数：0 往往表示"这帧还没刷新/读到的不是冷却"，采信会导致抢跑
                        -- [V15.31 / READ-TRUST] 再加一道"是否真在倒计时"的判定，防止把等级/层数当成冷却
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

        -- 4) 保命技能：低血时每场战斗提前交一次
        --    说明：它会正常消耗该技能自身的冷却（这是应该的）；若保命位正好是当前顺序位，
        --    把顺序指针前移一位，避免主轮换在一个刚被用掉的位上干等一整个冷却。
        local panicKey = cfg.SkillPanicKey
        if not S.panicUsed and panicKey and panicKey ~= "关闭" and panicKey ~= "" then
            local hp = tonumber(ctx.hpPct)
            if hp and hp > 0 and hp <= PANIC_HP and now >= (S.readyAt[panicKey] or 0)
                and (now - S.lastCastAt) >= MIN_GAP then
                local okCast, res = pcall(ctx.cast, panicKey)
                if not okCast then res = "fail" end
                -- [复核 B-3] 保命分支原来写的是 `if res ~= "fail"`，会把闸门返回的 "blocked"
                -- 当成施法成功：白扣一整个冷却 + panicUsed 置真（本场再也不会保命），必须单独拦掉。
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

        -- 5) 全局间隔（[CLEAN-2] 冲刺加速已删除，这里恒等于 nextCastAt）
        local gapReadyAt = S.nextCastAt
        if now < gapReadyAt then
            S.lastReason = "gap"
            return "gap"
        end

        -- 5.5) [V15.31 / STALL-HINT] 卡住提示：连续 10 秒一个技能都放不出来时，说明"不是速度慢，是被卡住了"。
        -- 两种典型现场：
        --   ① 顺序表里只勾了一个技能，而它正在长冷却（例如把 Z 设成 999 秒）→ 本场不会再有技能；
        --   ② 模式选了「严格轮流(等冷却)」，当前位的冷却就是几十~几百秒 → 一直死等。
        -- 只提示一次，且不影响任何决策。
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

        -- 6) 选位（四档模式各自的规则见 PickSlot）
        local slot, pos = PickSlot(now, ctx.readCooldown)
        if not slot then
            if OrderMode() == "blind" then
                -- 盲轮转：这一拍被按钮读数否掉 → 等一个完整节拍再轮到下一位
                S.nextCastAt = now + Gap()
                S.lastReason = "blind-skip"
                return "blind-skip"
            end
            -- 其它模式：全部在冷却，0.3 秒后再看（避免高帧率空转）
            S.nextCastAt = now + 0.30
            S.lastReason = "cooldown"
            return "cooldown"
        end

        -- 6.5) 施法前读数校正：本地计时可能偏乐观（刚注入/刚切图），读到真实剩余冷却就校正本次不交。
        -- 只对「本场已真正放过一次」的位采信：进战斗时游戏会重置 CD，按钮上残留的是上一场数字，
        -- 采信它会把首技挡掉（抓包里「Z 14 次 / X 1 次 / C 1 次 / V 0 次」的成因）。
        -- 盲轮转模式跳过本校验：PickSlot 已按按钮读数跳过该拍，再挡一次会把节拍推迟 0.35s。
        if OrderMode() ~= "blind" and S.castThisFight[slot] and cfg.SkillCdProbe ~= false and ctx.readCooldown and not S.deferOff[slot] then
            local okPre, preLeft = pcall(ctx.readCooldown, slot)
            -- [V15.31 / READ-TRUST] 读数必须"确实是倒计时"才拿来推迟施法
            if okPre and type(preLeft) == "number" and preLeft >= 1 and preLeft <= 1200
                and ReadIsCredible(slot, preLeft, now) then
                S.readyAt[slot] = now + preLeft + 0.15
                S.probe[slot] = nil
                S.stats.probe = S.stats.probe + 1
                S.lastReason = "cooldown-ui"
                -- 被读数挡下也必须推进节拍：否则同帧会连读同一个数字，被误判成「读数恒定」→ 回落到配置冷却硬放。
                S.nextCastAt = now + 0.35
                -- 防「读数恒正 → 该技能永久饿死」：只有读数完全不动（静态误读）才累计到 10 次后放弃界面读数；
                -- 真倒计时一定递减，读数比上次小就清零可疑计数。
                local prevRead = S.lastRead[slot]
                if prevRead and preLeft < prevRead - 0.05 then S.deferCount[slot] = 0 end
                S.lastRead[slot] = preLeft
                local n = (S.deferCount[slot] or 0) + 1
                S.deferCount[slot] = n
                -- 阈值 10 × 0.35s ≈ 3.5 秒读数一动不动才判定不可信，真倒计时不会被误判。
                if n >= 10 then
                    S.deferOff[slot] = true
                    S.deferCount[slot] = 0
                    S.probe[slot] = nil
                    -- 回落到「读数」与「配置」的较大值（上限 999）：按钮上的静态大数字就是真实冷却，
                    -- 否则按配置硬放会表现为「一直卡在这个技能上」。
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

        -- 7) 施法：失败不推进下标（旧版最致命的错位点），连续失败达上限才跳过该位
        local okCall, res = pcall(ctx.cast, slot)
        if not okCall then
            W("施法回调异常：" .. tostring(res))
            res = "fail"
        end
        -- 施法回调返回 blocked = 被状态闸门拦下（引擎 1.5s 退出宽限还没走完）：
        -- 不推进下标、不计失败、不进冷却，只做短退避，等宽限结束自然收场。
        if res == "blocked" then
            S.nextCastAt = now + RETRY_DELAY
            S.lastReason = "gated"
            return "gated"
        end
        if res == "fail" then
            -- 这一位已尝试过（哪怕失败），下次必须回到界面读数校验。
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
        S.castThisFight[slot] = true   -- [V15.31 / SKILL-FIRST] 从这一发起，该位才开始采信界面读数
        S.lastCastAt = now
        S.nextCastAt = now + Gap() + Jit(0.25)
        S.failCount[slot] = 0
        S.deferCount[slot] = 0
        S.lastRead[slot] = nil
        S.stats.cast = S.stats.cast + 1
        S.stats.fightCast = S.stats.fightCast + 1
        -- 这一发刚交出去，接下来 10s 内尝试从按钮倒计时上读出它的真实冷却
        if cfg.SkillCdProbe ~= false and ctx.readCooldown then S.probe[slot] = now + 10.0 end
        SetIndex((pos % #S.seq) + 1)
        S.lastReason = "cast"
        return "cast"
    end

    -- 关闭自动技能 / 切图 / 重载时调用：立刻中断本场战斗，避免下次开启时沿用旧的起手计时
    function M.Suspend()
        if S.inFight then L("自动技能已关闭/挂起，重置战斗状态") end
        S.inFight = false
        S.relockUntil = 0
        S.panicUsed = false
        -- 关掉再开是最自然的"手动恢复"动作：把所有会拦截下一场战斗的瞬时判定一并清掉，
        -- 否则弱信号超时收场留下的 blockWeakEntry 会把用户的重开也挡在 stale-block 外面。
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

    -- 只读查询接口（供 Heartbeat 判定「是否仍在同一场战斗」与调试展示）
    function M.IsInFight() return S.inFight end
    function M.GetDebugLine()
        local offCnt = 0
        for _ in pairs(S.deferOff) do offCnt = offCnt + 1 end
        -- 自检里把「模式 + 顺序表 + 当前位」都打出来，方便一眼确认是不是按 Z→X→C→V 走
        local modeTag = "顺序+跳过"
        local md = OrderMode()
        if md == "strict" then modeTag = "严格轮流"
        elseif md == "priority" then modeTag = "顺位优先"
        elseif md == "head" then modeTag = "Z优先"
        elseif md == "blind" then modeTag = "盲轮转" end
        local curSlot = S.seq[Index()] or "-"
        -- 逐位冷却状态：下次再出现「只放 Z」时，一眼能看出 X/C/V 是被谁锁住的
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
-- [AUTO-SKILL-ENGINE-END]

-- ---- 引擎运行时接线：复用上下文表 + 单通道施法（全部是函数内 local，不新增全局变量） ----
-- 复用型上下文表：每帧只改字段，绝不新建表（零 GC 压力）
-- inMinigame=强信号（游戏自身的 Minigame 属性 / Fishing GUI / Boss 拔河条），weak=合成弱信号（含咬钩、猛击按钮）
local autoSkillCtx = { inMinigame = false, weak = false, hpPct = nil, cast = nil }
local autoSkillSuspended = false

-- 把界面上的"剩余冷却"文本解析成秒数：兼容 "45" / "45s" / "45秒" / "0:45" / "1:30" 等写法
local function ParseCooldownText(raw)
    if type(raw) ~= "string" then return nil end
    local t = raw:gsub("%s+", "")
    if t == "" then return nil end
    -- 先排除明显不是"剩余冷却"的写法：百分比 / 分数 / 千分位 / 叠加层数（"45%" "45/100" "1,234" "+3"）
    if t:find("%%", 1, true) or t:find("/", 1, true) or t:find(",", 1, true) or t:find("+", 1, true) then return nil end
    local m, sec = t:match("^(%d+):(%d%d)$")
    if m then
        local v = tonumber(m) * 60 + tonumber(sec)
        if v and v >= 0 and v <= 1200 then return v end
        return nil
    end
    -- [V15.31 / CD-PARSE] 必须"整串只是数字"（可带 s/秒），否则 "3级" "6次" "Lv.3" 都会被前缀匹配成 3/6/0。
    local num = t:match("^(%d+%.?%d*)[sS秒]?$")
    if not num then return nil end
    local v = tonumber(num)
    if not v or v < 0 or v > 1200 then return nil end
    return v
end

-- 解析单个 GUI 节点上的"剩余冷却"文本（排除键位字母标签）
local function ReadCooldownNode(obj, slot, allowHidden)
    -- 是否允许隐藏态读取由调用方决定（按钮进入冷却后常被置为不可见，倒计时仍能读到）。
    if not obj or not obj.Parent then return nil end
    -- [审计修复 COM-01/R-11] Roblox Instance 访问不存在的属性（如 ImageButton.Text 或 UICorner.Visible/Text）会直接抛异常，
    -- 必须先限定为含 Text 属性的文本控件，防止异常中断整个 ReadSkillCooldown 的子节点与兄弟节点遍历。
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

-- 判断某个节点是不是"别的技能按钮"（防止把 X 的倒计时读成 Z 的冷却）
local function IsOtherSkillWidget(obj, selfKey)
    if not obj then return false end
    for k = 1, #SKILL_KEYS do
        local key = SKILL_KEYS[k]
        if key ~= selfKey and DoesButtonMatchSkillKey(obj, key) then return true end
    end
    return false
end

-- 从技能按钮读取"剩余冷却秒数"：先看按钮自身与一级子节点；只有按钮"变灰/不可用"时，
-- 才把同一小容器内的兄弟节点也纳入（此时旁边那个数字基本就是它自己的倒计时）。
-- 全程只做三层有限扫描，绝不做全屏遍历；任何疑似"百分比/分数/层数"的文本一律不收。
local function ReadSkillCooldown(slot)
    -- 注意：这里用"原始引用"而不是 GetCachedSkillButton —— 按钮进入冷却后可能被游戏置灰/隐藏，
    -- 只有原始引用才能读到它上面的倒计时数字（这也是实测截图里看到的形态：字母变成剩余秒数）。
    local btn = GetSkillButtonRef(slot)
    -- 缓存没命中时做一次轻量重扫（技能栏 HUD 两场之间会消失，缓存随之失效）；每 0.4s 最多一次。
    if not btn then
        local okFind, found = pcall(GetCachedSkillButton, slot, tick())
        if okFind and found then btn = found end
    end
    -- 允许隐藏态读取：冷却期按钮可能被置灰/隐藏，只靠 Visible 判定会永远读不到（实测「读冷却=0」）。
    -- 仍只做三层有限扫描（自身文本 → 直接子节点 → 父容器兄弟），未扩大遍历范围。
    if not btn then return nil end
    local v = ReadCooldownNode(btn, slot, true)
    if v then return v end
    -- 只有按钮「变灰/不可用」时才把内部/同级其它数字当倒计时；可点时只认自身文本（字母=就绪），
    -- 避免把等级/层数（实测 C 按钮右下角的 6）误读成 6 秒冷却。
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
-- 单条通道施法：一次意图只走一条通道，返回 "ok"（已尝试发出）/ "fail"（三条通道都不可用）
-- 单条通道施法：一次意图只走一条通道，返回 ok（已尝试发出）/ fail（三条通道都不可用）。
-- 三通道同开会让服务端把一次意图当成多次施法；只要「尝试过」就记 ok（按钮 Active=false 属正常冷却）。
-- 三条通道各自独立成函数，施法路径不产生闭包分配。
local function ASFireUI(slot)
    local btn = GetCachedSkillButton(slot, tick())
    if not (btn and btn.Visible) then return false end
    -- [AUD-S02] 如实返回 FireGuiButton 的触发结果：若当前执行器不支持信号触发且模拟点击失败，允许「自动」模式继续降级到远程/按键通道
    return FireGuiButton(btn, true) == true
end

local function ASFireRemote(slot)
    -- 优先 UseSkill：pcap3/pcap/pcap2 三份抓包合计 36 条出向，参数是槽位字母；
    -- TriggerMinigameSkill / CastSkill / ActivateSkill 在三份抓包里 0 次（Events 里也无此名），只作兜底。
    local rem = GetEventRemote("UseSkill") or GetEventRemote("TriggerMinigameSkill")
        or GetEventRemote(FSYC.Protocol and FSYC.Protocol.Remotes.CastSkill or "CastSkill") or GetEventRemote("ActivateSkill")
    if not (rem and rem:IsA("RemoteEvent")) then return false end
    -- [AUD-S02] 如实返回 SafeFireEventCombat 的发送结果，被限流/退避拦截时不虚报成功
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
        -- 先补发抬起再清登记：即使此刻脚本正在卸载（isRunning=false），也不会把按键留在按下态
        pcall(function() VirtualInputManager:SendKeyEvent(false, kc, false, game) end)
        pressedVirtualKeys[kc] = nil
    end)
    return true
end

local function AutoSkillCastOnce(slot)
    -- [模块 22-B] 施法前最后一道闸门：宽限期内若战斗其实已结束，直接返回 blocked，绝不在非搏斗状态点技能/发包。
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
        -- 自动：优先游戏自己的屏幕按钮（最贴近真实手点），没有按钮才退远程，最后才模拟按键
        fired = ASFireUI(slot)
        if not fired then fired = ASFireRemote(slot) end
        if not fired then fired = ASFireKey(slot) end
    end
    return fired and "ok" or "fail"
end

-- 引擎实例：deps 全部闭包注入，参数直接读 Config（UI 改动即时生效，无需重载脚本）
local AutoSkill = CreateAutoSkillEngine({
    config = Config,
    log = FLog,
    warn = FLogWarn,
    getIndex = function() return currentSkillIndex end,
    setIndex = function(v) currentSkillIndex = v end,
    -- 拟人化：技能间隔 +0~0.25s、起手 +0~0.6s 的随机抖动，避免时间戳恒定到毫秒
    jitter = function(max) return HRand(0, max) end,
})

-- 闸门开关切换时的一次性清理：清零预抽时刻并挂起技能引擎（必须定义在 AutoSkill 实例之后）。
DashUI._resetFishTimers = function()
    nextSlamAt = 0
    nextProgressionAt = 0
    DashUI._progressionHoldUntil = 0   -- [V15.30 / P-13] 开关重开时一并清零，避免沿用上一场的收场闸
    nextRhythmAt = 0
    nextQteAt = 0
    nextFishBtnRestoreAt = 0
    nextCastAt = 0
    autoSkillSuspended = false
    if AutoSkill and AutoSkill.Suspend then pcall(AutoSkill.Suspend) end
end

-- 供 UI「自动技能引擎自检」按钮与排查使用的只读状态入口（挂在既有共享表上，不新增全局变量）
DashUI._autoSkillStatus = function()
    local okLine, line = pcall(AutoSkill.GetDebugLine)
    return okLine and line or "引擎状态不可用"
end

-- 每帧驱动：关闭时只做一次 Suspend；开启后由引擎自行做抗抖 / 冷却 / 顺序判定
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
    -- 冷却倒计时读取通道：关闭「自动读取冷却倒计时」时传 nil，引擎会自动跳过这一步
    ctx.readCooldown = (Config.SkillCdProbe ~= false) and ReadSkillCooldown or nil
    -- 双保险：引擎内部已对每个外部回调做了 pcall，这里再兜一层，异常只记日志绝不打断 Heartbeat
    local okStep, err = pcall(AutoSkill.Step, now, ctx)
    if not okStep then FLogWarn("自动技能", "节奏引擎异常：" .. tostring(err)) end
end

-- ==========================================
-- 【模块 27：高频帧循环（Heartbeat 战斗/抛竿/QTE & RenderStepped 拉杆辅助/鱼红圈）与全局快捷键】
-- 1. stepHeartbeat：位置锁定、0.25s 咬钩检测、小游戏猛击/蓄力/秒钓推进、自动抛竿与节奏 QTE
--    （Z/X/C/V 技能由模块 27-A 的 AutoSkill 引擎按严格顺序释放）；
-- 2. RenderStepped：拉杆条居中、鱼红圈跟随（未开启/未钓鱼时立即早退）；
-- 3. 底部挂载 20 分钟防挂机 (AntiAFK) 与 RightControl 显隐 / End 卸载快捷键。
-- ==========================================
-- [性能优化 #10,#11 & Bug修复 #2] 高频 Heartbeat 函数（预定义函数消除每帧匿名闭包分配）
-- ==========================================
-- [FIX-21] 无名章鱼「节奏」小游戏只有这一个远程、只有两种载荷（pcap2 实证）：
--   RhythmHit:FireServer("hit") = 命中（+50 血 / 对 Boss 70 伤害）；"miss" = 失手（-200 血，绝不发）。
--   RhythmStart 规则：{HealHP=50, LoseHP=200, DealDMG=70, MiniGameTime=120, FinalMaxHP=20000}。
local CachedRhythmRem = nil   -- 只缓存 RhythmHit 这一个真实远程

-- ============================================================================
-- [BAN-FIX] 节奏命中全局预算（令牌桶）：所有会产生命中的路径共用同一个桶，任意 0.30s 内最多 1 次命中。
-- 依据：286 次命中才能击杀（20000/70）；0.12s 档 33 秒击杀 = 8.7 次/秒，是真人 2.8 次/秒的 3 倍，
-- 服务端比对击杀时长即可判定脚本。0.30s 节拍保证击杀时长 ≥ 286×0.30 ≈ 86 秒。
-- ============================================================================
local BOSS_RHYTHM_MIN_GAP = FSYC.Tunables and FSYC.Tunables.RhythmMinGapSec or 0.30
local BossRhythmBudget = { lastAt = 0, count = 0, startedAt = 0, warned = false }
local function BossRhythmAllow(now)
    now = now or tick()
    if (now - BossRhythmBudget.lastAt) < BOSS_RHYTHM_MIN_GAP then return false end
    BossRhythmBudget.lastAt = now
    BossRhythmBudget.count = BossRhythmBudget.count + 1
    return true
end

-- [PERF-A1] HumanoidRootPart / Humanoid 轻量缓存：以角色实例身份为键，命中后用 .Parent 复核，
-- 根部件被移除/换新或角色重生时自动重查，语义与每次 FindFirstChild 完全一致。
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

-- [V15.2] 咬钩鱼坐标解析：缓存命中与重新扫描两条分支共用本函数（pcall(f, obj) 形式，不分配闭包）。
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

-- [Heartbeat 每帧循环] 处理移速、水上行走、位置锁定、0.25s 咬钩检测、Boss 召唤、小游戏猛击/蓄力/秒钓推进、技能轮换、自动抛竿及节奏 QTE
local function stepHeartbeat()
    local char = LocalPlayer.Character
    -- [PERF-A1] 每帧 2 次查找走缓存（命中时仅 2 次 .Parent 复核，不再跨 C++ 边界找子实例）
    local root, hum = GetCharRefs(char, true)
    if not root or not hum then
        -- [V15.46] 角色缺失/重生/切图时也记录一次，避免"查看运行状态"停在上一个状态
        DashUI.SetStatus("钓鱼", "角色未就绪")
        return
    end
    local now = tick()
    local pData, _, _, fUI, bossBar = RefreshGuiAndDataRefs(now)

    if Config.PositionLock and not isMicroTeleportingNPC then
        if not lockedCFrame then lockedCFrame = root.CFrame end
        if (root.Position - lockedCFrame.Position).Magnitude > 3.5 then
            root.CFrame = lockedCFrame
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end

    -- 咬钩扫描缓存命中时直接 O(1) 读取，无需每 0.25s 遍历 Fishes 全表
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
    -- [perf] 每帧只读一次：miniAttr / fuiVisible / bossVisible 原先在下面 3 个判定里被重复读取 2–3 次（60Hz 下省约 300 次属性/全局读每秒）
    local miniAttr = attrMinigame
    local fuiVisible = (fUI ~= nil and fUI.Visible and IsGuiHierarchyVisible(fUI)) or false
    local bossVisible = (bossBar ~= nil and bossBar.Visible and IsGuiHierarchyVisible(bossBar)) or false
    -- [C7] 按状态门控：仅在可能处于小游戏/拔河/章鱼领域时才扫描猛击按钮，普通垂钓与挂机跳过全树扫描。
    local slamNeeded = miniAttr or cachedIsHooked or inUndergroundRealm
        or fuiVisible or bossVisible
    local activeSlamBtn = (Config.AutoSlam and slamNeeded and GetCachedSlamButton(now)) or nil

    -- ========================================================================
    -- [BTN-SIMPLE] 强制显示钓鱼按钮：开 = 按钮一直显示（仓库/装备/商店也显示），关 = 完全不碰游戏原生 UI。
    -- 这里每 0.5s 刷新缓存，每帧守卫在下面的渲染帧里。旧版「持竿判定 + 面板检测 + 两路守护」已整块删除
    -- （它们互相覆盖，才是按钮时有时无、收不干净的根因）。
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
    -- [模块 22-B] 猛击/蓄力辅助只看 OctoAutoMinigame，绝不被 AnchorBar 短路 —— 否则用户关掉自动猛击仍会发包。
    local useSlamAssist = Config.OctoAutoMinigame
    local isBossEncounter = bossVisible

    -- [模块 22-B 状态闸门] 本帧唯一一次采样（O(1)：只写 9 个布尔，零建表、零遍历）。
    -- isMinigame 保持原语义（雷达/渲染辅助/动画清理仍在用），但所有会发包的分支只看 gateFight：
    -- 前者含面板可见/咬钩缓存/猛击钮缓存，任一残留就会让 0.05~0.22s 的分支持续发包。
    local sig = fishGateSig
    sig.attrFishing = isFishing
    sig.attrMinigame = miniAttr
    sig.hooked = cachedIsHooked
    sig.bossBar = bossVisible
    sig.fui = fuiVisible
    sig.slam = (activeSlamBtn ~= nil and activeSlamBtn.Visible == true)
    -- [复核 B-1] 不把「捕获进度条 / 完美按钮可见」当搏斗证据：完美按钮就是猛击圆钮本身（自证），
    -- 进度条不在旧 isMinigame 合成式里（采信会让新版比旧版多发包）。只保留 3 个游戏侧权威信号 + 1 个补充信号。
    sig.rawFight = isMinigame
    FishGate.Update(now, sig)
    local gateFight = FishGate.IsFight()   -- 有效搏斗中：只有它为真才允许发战斗包
    -- [FIX-01/13] 把「本帧确实在搏斗」暴露给模块 06 的 __namecall 钩子，并同时写时间戳 ——
    -- stepHeartbeat 在无角色/重生/切图时会早退，只写布尔会让标志卡在 true；钩子按 0.5s 新鲜度判定。
    if sharedEnv then
        sharedEnv.IdenticalCombatActive = (gateFight == true)
        sharedEnv.IdenticalCombatActiveAt = tick()
    end
    local gateIdle = FishGate.IsIdle()     -- 既没钓鱼也没搏斗

    -- [V15.46 / 状态总线] 每 0.25s 记录一次当前状态，供"查看运行状态"与排障使用（零发包、零 Instance）
    if now >= (DashUI._nextStatusAt or 0) then
        DashUI._nextStatusAt = now + 0.25
        DashUI.SetStatus("钓鱼", isFishing and "钓鱼中" or (gateFight and "搏斗中" or (isMinigame and "小游戏" or "空闲")))
    end

    -- [自动技能 v2] 状态与节拍全部交给模块 27-A 的引擎：
    --   强信号 = 游戏侧权威信号（Minigame 属性 / 自己的鱼 / Boss 拔河条，不含 fuiVisible —— 面板可见≠在战斗）；
    --   弱信号 = 闸门输出（带 0.8s 退出宽限，抗 UI 闪烁）。
    SafeStep("自动技能", StepAutoSkills, now, (miniAttr or bossVisible or cachedIsHooked), gateFight, hum)

    if isMinigame and not wasInMinigame then
        wasInMinigame = true
    elseif not isMinigame and wasInMinigame then
        wasInMinigame = false
        -- 只有引擎确认「这场战斗真的结束」才松手，避免单帧闪烁把正在按的技能键提前抬起
        if not AutoSkill.IsInFight() and DashUI._releaseAllVirtualKeys then pcall(DashUI._releaseAllVirtualKeys) end
    end

    -- [模块 22-B] 这一段全是发包 / 模拟按键 / 模拟点按钮：外层必须用 gateFight（游戏侧权威信号 + 0.8s 退出宽限），
    -- 旧版用 isMinigame，任一信号残留就会 0.05~0.22s 无限发包。（原「自动刷 Boss」大块已整段删除。）
    if gateFight then
        -- 不依赖 fUI.Visible：Boss 战 / 移动端布局下「按下F键进行猛击」圆钮挂在技能栏旁而非 fUI 内，
        -- 由五通道 TriggerSlamEveryWay 全覆盖触发；节拍预抽 0.08 → [0.08, 0.13]。
        if (now >= nextSlamAt) then
            local didFire = false
            if Config.AutoSlam or useSlamAssist then
                local perfBtn = activeSlamBtn or GetCachedSlamButton(now)
                if perfBtn and perfBtn.Visible then
                    TriggerSlamEveryWay(perfBtn)
                    didFire = true
                end
            end

            -- [V15.2] 蓄力按钮查找收进开关分支内且只查一次（FindFirstChild(name,true) 本身先查直接子节点）。
            if Config.AutoCharge or useSlamAssist then
                local chgBtn = (cachedChargeBtn and cachedChargeBtn.Parent and cachedChargeBtn.Visible) and cachedChargeBtn
                    or (fUI and fUI:FindFirstChild("Charge", true))
                if chgBtn and chgBtn:IsA("GuiObject") and chgBtn.Visible then
                    FireGuiButton(chgBtn, true, true)
                    -- 不向 Charge 远程发包（两场抓包出向 0 次，按钮点击已驱动游戏逻辑）。
                    didFire = true
                end
            end

            -- [V15.2] 节拍推进与命中解耦：旧版只在 didFire 时写 nextSlamAt，找不到按钮就每帧重跑定位，
            -- 搏斗期最高 60~240 次/秒。现在无论成败都推进（命中按原节拍，未命中走更短重试）。
            if didFire then
                nextSlamAt = now + HRand(0.08, 0.05)
            else
                nextSlamAt = now + HRand(0.04, 0.02)
            end
        end

        -- [P-04] 进度包节拍对齐抓包：3475 条 UpdateFishProgression 实测 min 0.100 / 中位 0.118 / P90 0.150，
        -- 平均 0.127s ≈ 7.8~8.0 包每秒。旧值 0.05~0.07s（14~20 包/秒）是最大的包量来源，已统一到 0.10~0.15s。
        -- _progressionHoldUntil 由 FishingMinigame(SessionEnd) 置位、ReadyTimeFX(LOCK) 清零。
        if useMinigameAssist and (now >= nextProgressionAt) and now >= (DashUI._progressionHoldUntil or 0) then
            -- [P-15] 放宽上限到 0.15 后均值 ≈0.125，与真机一致；0.100s 已是真机绝对下限，秒钓不能靠压它实现。
            nextProgressionAt = now + (Config.InstantCatch and HRand(0.10, 0.03) or HRand(0.10, 0.05))
            -- [V15.31 / PROG-DEDUP] 游戏自己刚发过（90ms 内）就不再补一包，把实际包频拉回单源水平
            local lastGameProg = sharedEnv and sharedEnv.IdenticalLastProgressionAt or 0
            if (now - lastGameProg) >= 0.09 then
                SafeFireEventCombat("UpdateFishProgression")
            end
            -- [P-01] 不向 FishingMinigame 反向发包：两场抓包（恩佐 1158s / 章鱼 283s）它只有入向 OnClientEvent。
            -- 模块 06 钩子里「把 Out of bar 改写成 In bar」是改写入向/出向既有调用，保持不变。
        end

        -- [自动技能 v2] 旧的「三通道同开 + 无条件推进下标」轮转已迁移到模块 27-A（StepAutoSkills 每帧驱动）。
    elseif isFishing then
        -- [A2-02/A4-11] 钓鱼期间同步推进预抽；CastDelay 被外部改写为非数值时退化为 1.0s。
        nextCastAt = now + DashUI.ClampNum(Config.CastDelay, 0.1, 10, 1.0)
    elseif not gateIdle then
        -- [R1] 刹车分支：属性已假但闸门仍在 0.8s 退出宽限内 —— 只停手、不抛竿、不重置 nextCastAt。
    else
        -- 低频自动保护与定时卖鱼已移入 0.25s 后台调度器 stepLowFreqAutomation，这里只保留高频自动抛竿。
        local holdingRodNow = IsCharacterHoldingFishingRod(char, pData)
        -- [FIX-BTN-2] 不要用 cachedAutoFishBtn.Visible 否决持竿状态：游戏把两个圆钮一起隐藏时会导致
        -- 「关自动钓鱼再拿竿，按钮永远回不来」的死锁。手持鱼竿本身就是最可靠的信号。
        -- [模块 22-B] 抛竿总闸：搏斗中 / 鱼线已在水里 / 刚退出战斗的静默窗内一律不抛。
        -- [AUD-C01] 自动卖鱼落锁等待期或自动喂猴进行期暂停抛竿，避免抛竿入水打断正在执行的 SafeSellAllFish。
        local shouldAutoCast = Config.AutoCast
            and not isMicroTeleportingNPC and not isSellingInProgress and not (FSYC.monkeyCtl and FSYC.monkeyCtl.running)
            and holdingRodNow and FishGate.AllowAutoCast(now)
        if shouldAutoCast then
            if sharedEnv then sharedEnv.IdenticalKeepFishBtnVisible = false end
        end
        -- [C14/H1] 抛竿节拍：CastDelay(默认1.0) → +[0, 0.25]（咬钩检测是独立的 0.25s 轮询，不受影响）。
        if shouldAutoCast and not isCD and not isSwimming and (now >= nextCastAt) then
            nextCastAt = now + HRand(DashUI.ClampNum(Config.CastDelay, 0.1, 10, 1.0), 0.25)
            local canCast = true
            if pData and pData:FindFirstChild("InventoryLimit") then
                local invCount = CountBagFish(pData, now)
                local maxLim = tonumber(DashUI._readValueBase(pData:FindFirstChild("InventoryLimit"), nil))
                -- 上限值异常（非数值）时不再让整条 Heartbeat 抛错中断本帧后续逻辑。
                if maxLim then
                    if Config.AutoSell and maxLim > 0 and invCount >= math.floor(maxLim * 0.9) and (now - lastFullBagSellTime >= 5.0) then
                        SafeSellAllFish(pData)
                        lastFullBagSellTime = now
                        canCast = false
                    end
                    if invCount >= maxLim then
                        canCast = false
                        -- [15.0] 满包不静默停抛：日志每 30s 一条；弹窗每次「连续满包」只弹一次（清出空间后重置）。
                        if (now - lastFullBagWarnTime >= 30.0) then
                            lastFullBagWarnTime = now
                            local tail = Config.AutoSell
                                and "自动卖鱼没能清出空间，请检查卖鱼/上锁设置"
                                or "请开启【自动卖鱼】或手动清理背包，清出空间后会自动继续"
                            -- 先落日志再弹通知：即使通知系统异常，控制台也能看到停抛原因
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
        -- [FIX-BTN-8] 手机钓鱼按钮恢复只保留上面那个独立守护（旧的双实现会互相覆盖，按钮时有时无）。
    end

    -- [A2-04/FIX-22] 节奏节拍预抽：可调（默认 0.34s），并加 ±20% 抖动避免时间戳等距。
    if Config.OctoAutoMinigame then
        if now >= nextRhythmAt then
            -- 真战斗按 beatBase（±20% 抖动），非战斗降到 0.50~0.60s，避免挂机空打。
            -- [BAN-FIX] 运行期硬夹到 ≥0.30s：存档里残留的 0.12 / 0.18 也发不出去。
            local beatBase = DashUI.ClampNum(Config.RhythmBeatSec, BOSS_RHYTHM_MIN_GAP, 1.0, 0.34)
            nextRhythmAt = now + (gateFight and (beatBase * (0.80 + math.random() * 0.40)) or HRand(0.50, 0.10))
            local acc = DashUI.ClampNum(Config.RhythmAccuracy, 85, 100, 100)
            local hitPass = (acc >= 100) or (math.random(1, 100) <= acc)
            -- [风控] 只在确实处于搏斗/地下领域活跃态时才打拍子
            local rhythmInCombat = gateFight or (inUndergroundRealm and (miniAttr or bossVisible or cachedIsHooked or (now < (DashUI._rhythmActiveUntil or 0))))
            -- [BAN-FIX] BossRhythmAllow(now) 专供 RhythmHit("hit")，不再由额外 QTE 点击争抢令牌桶
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
        end
        -- [AUD-07] 独立于 nextRhythmAt 节拍：仅在未处于搏斗/垂钓中时按 0.10~0.18s 周期触发地下 Boss 交互提示
        if inUndergroundRealm and not gateFight and not isFishing and (now >= nextBossPromptAt) then
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

-- ==========================================
-- 纯净渲染循环 RenderStepped (极致低延迟 + 零每帧闭包分配)
-- ==========================================

pcall(function()
    if type(RunService.BindToRenderStep) == "function" then
        pcall(function() RunService:UnbindFromRenderStep("IdenticalForceFishBtnVisible") end)
        local lastPrio = (Enum.RenderPriority and Enum.RenderPriority.Last and Enum.RenderPriority.Last.Value) or 2000
        RunService:BindToRenderStep("IdenticalForceFishBtnVisible", lastPrio, function()
            if not isRunning then return end
            -- [BTN-SIMPLE] 强制显示：每帧只做"当前不对才写"的守卫写，不产生无效属性写。
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
-- [渲染辅助] 小游戏期间实时居中判定条、对齐 Boss 拔河绿区、拉满捕获进度条并隐藏受伤红屏（复用 0.6s 缓存子控件）。
local function stepRenderAssist(now)
    local _, _, _, fUI, bossBar = RefreshGuiAndDataRefs(now or tick())
    if fUI and fUI.Visible then
        -- [perf] 属性写去重：RenderStepped 每帧都进来，写相同值仍会跨 C++ 边界并触发布局重算。
        if Config.AnchorBar then
            if cachedBarInner and cachedBarInner.Parent and cachedBarInner.Position ~= UDIM2_CENTER then
                cachedBarInner.Position = UDIM2_CENTER
            end
            if cachedProgBarInner and cachedProgBarInner.Parent and cachedProgBarInner.Size ~= UDIM2_FULL then
                cachedProgBarInner.Size = UDIM2_FULL
            end
        end
        -- [REALBOSS] 开启真实命中上报时必须保留游戏算出的 Bar/Hitbox 相对位置：视觉对齐会让读条永远返回「命中」，
        -- 等于把方案 B 退化成盲发，所以开关打开时跳过这段。
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
        -- [perf] 去掉两处每帧闭包 + pcall：实例已用 .Parent 判空，直写属性即可（受伤闪屏期间最多省 2×240 个闭包分配/秒）
        if cachedHurt1 and cachedHurt1.Parent and cachedHurt1.ImageTransparency ~= 1 then
            cachedHurt1.ImageTransparency = 1
        end
        if cachedHurt2 and cachedHurt2.Parent and cachedHurt2.ImageTransparency ~= 1 then
            cachedHurt2.ImageTransparency = 1
        end
    end
end

-- [RenderStepped 鱼红圈跟随] 追踪鱼线末端 Attachment1 或咬钩浮标的世界坐标，实时更新红色光圈位置
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
    -- [PERF-A1] 渲染帧最高 240Hz：root 走缓存，只做 .Parent 复核
    local root = GetCharRefs(char, false)
    if not root then return end

    -- [CLEAN-5] 渲染帧飞行解算整段已删除（飞行功能整块移除）。

    -- [perf] 小游戏未进行时短路跳过 UI 辅助，消除常态每帧 RefreshGuiAndDataRefs 开销。
    local useAssist = Config.AnchorBar or Config.OctoAutoMinigame
    -- [perf] 惰性求值：辅助全关时不再计算 4 次 activeMinigame 属性读；鱼光圈关闭时不再读 3 个 attr（渲染帧最高 240Hz）。
    local miniAttrNow = attrMinigame
    local needRenderAssist = false
    if useAssist then
        needRenderAssist = wasInMinigame or miniAttrNow or cachedIsHooked
            or (cachedFUI ~= nil and cachedFUI.Parent ~= nil and cachedFUI.Visible)
            or (cachedBossBar ~= nil and cachedBossBar.Parent ~= nil and cachedBossBar.Visible)
    end
    local needFishRing = (Config.FishRedRing and char ~= nil and (attrFishing or miniAttrNow or cachedIsHooked)) or false
    -- [REALBOSS/FIX-10] 第二阶段读条不能被视觉开关连带关掉：提到外层独立调用（函数内已有四重判断）。
    if Config.RealBossHit and RealBoss.active then pcall(RealBossStep, tick()) end
    -- 仅当小游戏辅助或鱼目标红圈至少有一项需要执行时才获取一次 tick() 并共享
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

-- ============================================================================
-- 【模块 30：只读协议观测 (OBS) —— 字段完全来自实机抓包，见 pcap/协议解析报告.md】
-- 红线：只监听、只统计、零发包（不调用 FireServer/InvokeServer，不插入任何发包节拍）。
-- 字段只用抓包真实出现的：ReplicateFishCaught(player, fishName, pos) / RenderSkillToClients(target, skillVFX) / CleanUp(instance)。
-- 两者都是广播（201s 内 arg1 出现过 3 个不同玩家实例），必须过滤非本机；RenderSkillToClients 每次施法会被
-- 两个客户端回调各记一次（58 条 = 29 次，间隔 10~59ms），所以统计必须做 0.2s 去重。
-- ============================================================================
local OBS = {
    fishByName = {}, fishOrder = {}, fishTotal = 0,
    skillLastAt = {}, skillCount = {}, skillCD = {}, skillOrder = {},
    cleanup = 0,
    uiAt = 0,
}
local OBS_SKILL_DEDUP = FSYC.Tunables and FSYC.Tunables.ObsSkillDedupSec or 0.20   -- 同技能 0.2s 内视为同一次施法的重复回调
local OBS_CD_MIN_GAP = FSYC.Tunables and FSYC.Tunables.ObsCdMinGapSec or 1.0     -- 小于 1s 的间隔不算 CD 样本（那是重复回调）
local OBS_CD_MAX_GAP = FSYC.Tunables and FSYC.Tunables.ObsCdMaxGapSec or 300.0   -- 大于 300s 的间隔也不当作 CD 样本（挂机/换图）

-- 从 Info.Skill["<技能名>"].VFX 里取出技能名；抓包确认的结构是 名字.VFX
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

-- [P-10] 抓包实证（pcap3 9 + pcap 99 + pcap2 23，共 131 条 100% 一致）：ReplicateFishCaught /
-- RenderSkillToClients 的第 1 参永远是「角色模型」而不是 Player 对象（本机 = LocalPlayer.Character，
-- 别人 = workspace.<玩家名>）。旧判据 who ~= LocalPlayer 对每条都为真 → 本机广播被当成「别人」丢掉。
local function IsSelfBroadcast(who)
    if typeof(who) ~= "Instance" then return true end   -- 非 Instance（如 NotifyFish 的字符串）保持旧行为：不拦
    if who == LocalPlayer then return true end          -- 兼容万一哪天真的直接传 Player
    local selfChar = LocalPlayer.Character
    if selfChar and who == selfChar then return true end
    local owner = nil
    pcall(function() owner = Players:GetPlayerFromCharacter(who) end)
    return owner == LocalPlayer
end

local function OBS_OnFishCaught(who, fishName)
    if not IsSelfBroadcast(who) then return end         -- 广播过滤（按角色归属判定，见上）
    if type(fishName) ~= "string" or fishName == "" then return end
    local pure = fishName:match("^(.-)%s*|") or fishName
    pure = pure:match("^%s*(.-)%s*$") or fishName
    if pure == "" then pure = fishName end
    OBS.fishTotal = OBS.fishTotal + 1
    if not OBS.fishByName[pure] then
        if #OBS.fishOrder >= 64 then
            local oldest = table.remove(OBS.fishOrder, 1)
            if oldest then OBS.fishByName[oldest] = nil end
        end
        OBS.fishByName[pure] = 0
        OBS.fishOrder[#OBS.fishOrder + 1] = pure
    end
    OBS.fishByName[pure] = OBS.fishByName[pure] + 1
    OBS_RefreshUI(tick())
end

local function OBS_OnCleanup()
    OBS.cleanup = OBS.cleanup + 1
end

local function OBS_OnSkillRendered(who, vfx)
    if not IsSelfBroadcast(who) then return end         -- 广播过滤（本机 = LocalPlayer.Character）
    local name = OBS_SkillName(vfx)
    if not name then return end
    local now = tick()
    local last = OBS.skillLastAt[name]
    if last and (now - last) < OBS_SKILL_DEDUP then return end           -- 同一次施法的重复回调
    OBS.skillLastAt[name] = now
    if not OBS.skillCount[name] then
        if #OBS.skillOrder >= 32 then
            local oldest = table.remove(OBS.skillOrder, 1)
            if oldest then OBS.skillCount[oldest] = nil; OBS.skillCD[oldest] = nil; OBS.skillLastAt[oldest] = nil end
        end
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

-- 自检入口：控制台里 DashUI._obsStats() 可取到本局的只读统计
DashUI._obsStats = function()
    return {
        fishTotal = OBS.fishTotal, fishByName = OBS.fishByName,
        skillCount = OBS.skillCount, skillCD = OBS.skillCD,
        cleanup = OBS.cleanup,
    }
end

-- 监听服务端发来的 Slam / Charge / Rhythm / Boss QTE 远程事件并自动回传 Perfect / 100 满分判定
local dynMinigameRemoteBound = setmetatable({}, { __mode = "k" })
local function ConnectDynamicMinigameRemote(rem)
    if not rem then return end
    -- [V15.46] 先清同名负缓存（放在 IsA 守卫之前：即使新出现的是 RemoteFunction/其他实例，也要让 GetEventRemote 重新查）
    cachedEventRemotes[rem.Name] = nil
    cachedEventRemoteNegAt[rem.Name] = nil
    if not rem:IsA("RemoteEvent") then return end
    -- [内存回收] 同一个 Remote 只绑定一次：避免初始遍历与 Events.ChildAdded 重复叠加连接（旧版无去重）
    if dynMinigameRemoteBound[rem] then return end
    dynMinigameRemoteBound[rem] = true
    local rName = rem.Name
    if rName == "Slam" or rName:find("Slam", 1, true) then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(slamEvent)
            -- [模块 22-B] 统一经 SafeFireEventCombat 走闸门与 10ms 战斗去重。
            if isRunning and Config.AutoSlam then
                -- [P-05] 不向 Slam 远程回包（两场抓包出向 0 次），真实猛击只由「点击猛击圆钮 + F 键输入」驱动。
                pcall(function()
                    TriggerSlamEveryWay(GetCachedSlamButton(tick()))
                end)
            end
        end))
    elseif rName == "Charge" then
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(chargeEvent)
            -- [P-06] 不向 Charge 远程回包（抓包出向 0 次），充能由点击充能按钮驱动。
            if isRunning and Config.AutoCharge then
                pcall(function()
                    local chgBtn = (cachedChargeBtn and cachedChargeBtn.Parent and cachedChargeBtn.Visible) and cachedChargeBtn
                        or (cachedFUI and cachedFUI:FindFirstChild("Charge", true))
                    if chgBtn and chgBtn:IsA("GuiObject") and chgBtn.Visible then FireGuiButton(chgBtn, true, true) end
                end)
            end
        end))
    elseif rName == "RhythmStart" then
        -- [AUD-R02] RhythmStart 是服务端下发的入向会话启动通知，严禁反向 FireServer("Perfect")。
        -- 这里只记录节奏会话活跃窗口，供地下领域无名章鱼战判别战斗态。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(cfgTbl)
            if not isRunning then return end
            local dur = DashUI.ClampNum(type(cfgTbl) == "table" and (cfgTbl.MiniGameTime or cfgTbl.Duration or cfgTbl.Time), 10.0, 180.0, 125.0)
            DashUI._rhythmActiveUntil = tick() + dur
            -- [BAN-FIX] 用服务端下发的真实规则算「本场预计多久打完」并重置命中预算。
            -- 规则实测（pcap2 #1887）：20000 血 / 每击 70 → 286 次命中；0.34s 节拍 → 97s（真人约 103s）。
            if type(cfgTbl) == "table" then
                BossRhythmBudget.lastAt = 0
                BossRhythmBudget.count = 0
                BossRhythmBudget.startedAt = tick()
                local hp = tonumber(cfgTbl.FinalMaxHP)
                local dmg = tonumber(cfgTbl.DealDMG)
                if hp and dmg and hp > 0 and dmg > 0 then
                    local needHits = math.ceil(hp / dmg)
                    local beat = DashUI.ClampNum(Config.RhythmBeatSec, BOSS_RHYTHM_MIN_GAP, 1.0, 0.34)
                    local eta = needHits * beat
                    local limit = DashUI.ClampNum(cfgTbl.MiniGameTime, 10, 600, 120)
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
    elseif rName == "RenderSkillToClients" then
        -- [FEAT-OBS] 只读：2 参 (target, Info.Skill["<名>"].VFX)，不发送任何包，只统计释放次数与实测 CD。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(obsTarget, obsVfx)
            if not isRunning then return end
            pcall(OBS_OnSkillRendered, obsTarget, obsVfx)
        end))
    elseif rName == "CleanUp" then
        -- [FEAT-OBS] 只读：1 参（要清理的鱼模型实例），统计「入包→清理」的确认次数。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            pcall(OBS_OnCleanup)
        end))
    elseif rName == "BossPhase2Setup" then
        -- [REALBOSS] 第二阶段开始：{HitboxW, MinGap, Mode, BarSpeed, BadLife}
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(setup)
            if not isRunning then return end
            pcall(RealBossActivate, setup)
        end))
    elseif rName == "FishingMinigame" then
        -- [AUD-18] 兼容客户端协议字段改版：支持字符串与表结构的小游戏会话结束通知
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(kind)
            if not isRunning then return end
            local endKey = nil
            if type(kind) == "string" then
                endKey = kind:lower()
            elseif type(kind) == "table" then
                local rawAct = kind.Action or kind.Type or kind.State or kind.Status or kind[1]
                if type(rawAct) == "string" then endKey = rawAct:lower() end
            end
            -- [F22-07] 只认精确命中（白名单键或 "sessionend"）：旧实现用 find("end") 做子串匹配，
            -- "pending"/"suspended"/"legend" 都会被误判成 SessionEnd → 提前 RealBossDeactivate 且无提示。
            local endMap = FSYC.Protocol and FSYC.Protocol.SessionEndKeywords
            if endKey and ((endMap and endMap[endKey]) or endKey == "sessionend") then
                -- [P-13] 收场后立刻掐进度包：实测两场都是 SessionEnd 后只再漏 1 条（+0.095s），
                -- 不掐的话 0.8s 退出宽限内还会再发 ~7 条零参包。0.90s = 宽限 + 余量，LOCK 时清零。
                DashUI._progressionHoldUntil = tick() + 0.90
                pcall(RealBossDeactivate, "SessionEnd")
            end
        end))
    elseif rName == "ReadyTimeFX" then
        -- [P-14] 只读监听倒计时：3 → 2 → 1 → "LOCK"（#30~#33 / #111~#114）。"LOCK" 是独立开抢信号，
        -- 绝不能 tonumber（tonumber("LOCK")==nil 会被当成 0 秒 → 提前开抢）。
        -- 只做两件事：记录开抢时刻、解除上一场 SessionEnd 留下的进度包闸；不做「必须 LOCK 才发包」的硬闸。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(readyVal)
            if not isRunning then return end
            if type(readyVal) == "string" and readyVal == "LOCK" then
                DashUI._progressionHoldUntil = 0
            end
        end))
    elseif rName == "NotifyDamage" then
        -- [REALBOSS] 命中回执（200, false）：用来核对"上报了命中但服务端不认"的情况
        table.insert(activeConnections, rem.OnClientEvent:Connect(function()
            if not isRunning then return end
            pcall(RealBossOnDamage)
        end))
    elseif rName == "StartDialogue" then
        -- [PCAP3] 入向是 4 元组：(dialogueId, npcInstance, { 文本, { {按钮文本, actionTag, bool}, ... } }, 回传参数表?)
        --   实例 #68/#75/#77 是 4 参；#74(奖励页)/#135(诱饵商)/#153(钓竿商) 是 3 参（无第 4 参）。
        -- 旧实现是无参回调，把四样全丢掉 → 算不出 ChooseDialogueOption 的下标与第 4 参，领奖/接任务/开商店只能手点。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(dlgId, dlgNpc, dlgBody, dlgRet)
            if not isRunning then return end
            FSYC.FSYDialogueOpenedAt = tick()
            -- [审计修复 R-21] 入向参数类型校验：仅当 dlgId 为非空字符串且 dlgBody 为表时才记录自动对话状态
            if type(dlgId) ~= "string" or dlgId == "" or type(dlgBody) ~= "table" then
                FSYC.DialogueState = nil
                return
            end
            FSYC.DialogueSeq = (tonumber(FSYC.DialogueSeq) or 0) + 1
            FSYC.DialogueState = {
                id = dlgId,            -- dialogueId，出向第 1 参
                npc = dlgNpc,          -- NPC 实例，用于判存活
                body = dlgBody,        -- { 文本, { 选项... } }
                ret = dlgRet,          -- 第 4 参（nil = 该页无第 4 参，出向也要省掉）
                at = tick(),
                seq = FSYC.DialogueSeq,
            }
        end))
    elseif rName == "UpdateFishingRodShop" then
        -- [PCAP3] 只读。#154 在开钓竿对话后 9ms 下发服务端真实竿名清单（第一根是小写 r 的 "Wooden rod"）。
        -- 只记录、不改行为，用于给静态 allRods 表做真实名对账（RodPowerOf 有大小写兜底）。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(rodList)
            if not isRunning or type(rodList) ~= "table" then return end
            local norm = {}
            for i = 1, #rodList do
                if type(rodList[i]) == "string" then norm[#norm + 1] = rodList[i] end
            end
            FLog("竿店", "服务端竿名清单: " .. table.concat(norm, " | "))
            -- 与静态战力表对账：真实竿名不在 rodPowerLookup（大小写不敏感）里时，自动配竿会跳过该竿
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
        -- [FEAT-OBS] ReplicateFishCaught 是 (player, fishName, position) 的广播事件（201s 内 arg1 出现 3 个玩家），
        -- 别人钓到的鱼不触发我们自己的保护鱼上锁扫描；NotifyFish / 参数异常保持原有行为。
        table.insert(activeConnections, rem.OnClientEvent:Connect(function(fishWho, fishName)
            if not isRunning then return end
            if rName == "ReplicateFishCaught" then
                pcall(OBS_OnFishCaught, fishWho, fishName)
                -- [V15.30 / P-10] 抓包实证 arg1 是角色模型（自己 = LocalPlayer.Character），必须按角色归属判定
                if not IsSelfBroadcast(fishWho) then return end
            end
            if not FSYC.catchAnimScheduled then
                FSYC.catchAnimScheduled = true
                task.delay(0.35, function()
                    FSYC.catchAnimScheduled = false
                    if isRunning and LocalPlayer and LocalPlayer.Character and not attrFishing and not attrMinigame and StopLingeringFishingAnimations then
                        local curChar = LocalPlayer.Character
                        local stillHolding = IsCharacterHoldingFishingRod and IsCharacterHoldingFishingRod(curChar)
                        if not stillHolding then
                            StopLingeringFishingAnimations(curChar)
                        end
                    end
                end)
            end
            if not (Config.MaterialFarming or Config.AutoFavouriteFish or Config.RodMaterialFarming or Config.AutoSell) then return end
            if not FSYC.catchLockScheduled then
                FSYC.catchLockScheduled = true
                task.delay(0.22, function()
                    if isRunning and TryFavoriteProtectedFish then
                        pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
                    end
                end)
                task.delay(0.80, function()
                    FSYC.catchLockScheduled = false
                    if isRunning and TryFavoriteProtectedFish then
                        pcall(TryFavoriteProtectedFish, GetPlayerData(), false)
                    end
                end)
            end
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
end -- end of IdenticalStartRuntimeLoops
do
    local okBoot, bootErr = pcall(IdenticalStartRuntimeLoops)
    if not okBoot then
        FLogErr("启动", "运行时引擎初始化失败，自动化功能不可用: " .. tostring(bootErr))
        if ShowNotification then
            ShowNotification("FSY 启动异常", "自动化引擎初始化失败，请查看控制台日志后重进", "ERROR", 8)
        end
    end
    FLog("启动", okBoot and "初始化完成：UI 静态节点与后台时间片调度器已就绪"
        or "初始化未完成：自动化引擎不可用，详见上一条 ERROR 日志")
end

pcall(function()
    table.insert(activeConnections, LocalPlayer.Idled:Connect(function()
        -- [V15.45 / ANTI-IDLE] 收到 Idled 说明客户端已经连续 20 分钟没有真实输入：立刻补一条保活脉冲。
        if Config.AntiAFK and isRunning then
            FLogWarn("防挂机", "收到 Idled 空闲事件，补发保活脉冲")
            if DashUI.AntiAfkPulse then pcall(DashUI.AntiAfkPulse, "Idled") end
        end
    end))
end)

table.insert(activeConnections, UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or (type(input) == "table" and input._isFSYSynthetic) then return end
    -- [V15.1 双端] 快捷键只在电脑模式放行：手机屏幕键盘同样会发 KeyCode，避免打字时误触隐藏/卸载
    if not ModeCtl.AllowKeyboardShortcuts() then return end
    -- [C10/FSY-D-14] 配置导入可能把键位写成字符串：非 EnumItem 时回落默认键，避免热键静默失效
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

-- [UI-DEP] 启动收尾：按当前（可能是读档回填的）配置算一次依赖显隐，保证首次打开就无多余控件
if DashUI.ApplyUIDeps then pcall(DashUI.ApplyUIDeps) end
-- [UI-STATUS] 启动即刷一次底部状态条，避免开局显示的是占位文案
if DashUI.RefreshFooterStatus then pcall(DashUI.RefreshFooterStatus, true) end
-- [UI-重构] 启动即算一次场景卡状态点（读档回填的开关状态可能已让某个场景处于"全开"）
if DashUI.RefreshHomeScenes then pcall(DashUI.RefreshHomeScenes) end
ShowNotification("FSY " .. FSY_VERSION, string.format("脚本已加载完成！当前 %s，%s。点击右上角 [FSY] 收起为悬浮球；【杂项 → 设备与输入】可切换模式",
    ModeCtl.Label(), Config.InputIsolation and "输入隔离已开" or "输入隔离已关"), "SUCCESS", 5)
