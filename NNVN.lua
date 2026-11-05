--[[============================================================================
    NNVN Heavyweight Fishing  —  重写版 (Rewrite)
    ---------------------------------------------------------------------------
    这是什么：
      按逆向得到的功能面 / Remote 表 / 游戏数据表，重新实现的一套完整钓鱼脚本。
      原始脚本被 Luraph 系虚拟机保护，无法逐字还原；本文件是**独立实现**，
      不依赖任何混淆器产物，因此完全可读、可改、可扩展。

    设计原则：
      1) 单文件、零外部依赖（不 loadstring、不 HttpGet 任何 UI 库）。
      2) 每个功能都是独立开关，坏一个不影响别的。
      3) 自动化分两类手段，互相兜底：
         · Remote 直发  —— 已知名字的（SellFish / BuyBait ...）
         · GUI 点击     —— 不知道签名时更可靠（对话框、商店、小游戏）
      4) 全部 pcall 包裹，任何一处报错只在「调试」页留痕，不炸脚本。

    作者：逆向重建，非原作者。仅用于你自己的账号与学习。
============================================================================]]

--==============================================================
-- 0. 服务与被保护引用
--==============================================================
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local CoreGui           = pcall(function() return game:GetService("CoreGui") end)
    and game:GetService("CoreGui") or nil
local HttpService  = game:GetService("HttpService")

local LP = Players.LocalPlayer

-- 有些执行器需要 cloneref 才能安全操作 CoreGui / 服务
if cloneref then
    local ok, v = pcall(cloneref, CoreGui)
    if ok and v then CoreGui = v end
end

--==============================================================
-- 1. 日志 / 通知
--==============================================================
local LOGS = {}
local MAX_LOGS = 200
local DEBUG = true

local function stamp()
    local ok, v = pcall(os.date, "%H:%M:%S")
    return ok and v or "??:??:??"
end

-- warn 是 Roblox 全局，某些环境没有；统一走安全输出
local function warnf(msg)
    local f = warn or print
    pcall(f, msg)
end

local function log(fmt, ...)
    local msg
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        msg = ok and s or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    local line = "[" .. stamp() .. "] " .. msg
    LOGS[#LOGS + 1] = line
    if #LOGS > MAX_LOGS then table.remove(LOGS, 1) end
    if DEBUG then warnf("[NNVN] " .. msg) end
    return line
end

-- UI 通知（由 UI 段注入真实实现）
local Notify = function(text) print("[NNVN] " .. tostring(text)) end

--==============================================================
-- 2. 配置（所有开关集中在这里，UI 会自动绑定）
--==============================================================
local Config = {
    -- 钓鱼
    AutoCast            = false,
    CastDelay           = 2,
    AutoSell            = false,
    SellInterval        = 60,
    AutoFavorite        = false,
    AutoBuyBait         = false,
    BaitName            = "Basic Bait",
    BaitQuantity        = 1,
    AutoUseBait         = false,
    AutoEquipBestBait   = false,
    AutoEquipRod        = false,
    AutoCraftBait       = false,

    -- 任务
    AutoAcceptQuest     = false,
    AutoTicketQuest     = false,
    TicketDifficulty    = "Easy",
    AutoTurnIn          = false,
    AutoPhase2          = false,

    -- Boss
    AutoBossFight       = false,
    AutoBossFishing     = false,
    AutoFarmSecretBoss  = false,

    -- 技能
    AutoSkill           = false,
    SkillInterval       = 1,

    -- 日常
    AutoClaimDaily      = false,
    ClaimDailyDelay     = 30,
    AutoRedeemCodes     = false,

    -- 移动 / 会话
    IslandTeleport      = false,
    TargetIsland        = "Beginning Isle",
    AutoRejoin          = false,
    AntiAFK             = true,
    WalkOnWater         = false,
    FlySpeed            = 0,   -- 0 = 关闭

    -- 服务器跳转
    ServerHopGod        = false,
    ServerHopMaoshan    = false,
    ServerHopTaoist     = false,

    -- ESP
    ESPBoss             = false,
    ESPNPC              = false,
    ESPSecretRod        = false,
    ESPGodSpirit        = false,
    ESPMaoshan          = false,
    ESPTaoist           = false,
    ESPTracers          = false,

    -- 杂项
    ShowInfo            = true,
    ThemeColor          = "紫",
}

--==============================================================
-- 3. 配置持久化
--==============================================================
local CFG_DIR  = "NNVN_HeavyweightFishing"
local CFG_FILE = CFG_DIR .. "/config.json"

local function ensureDir()
    if makefolder then pcall(makefolder, CFG_DIR) end
end

local function saveConfig()
    local ok, err = pcall(function()
        ensureDir()
        if not writefile then error("执行器不支持 writefile") end
        writefile(CFG_FILE, HttpService:JSONEncode(Config))
    end)
    if ok then log("配置已保存") else log("保存配置失败: %s", tostring(err)) end
    return ok
end

local function loadConfig()
    local ok, err = pcall(function()
        if not (isfile and readfile) then error("执行器不支持 readfile/isfile") end
        if not isfile(CFG_FILE) then error("还没有保存过配置") end
        local raw = readfile(CFG_FILE)
        local data = HttpService:JSONDecode(raw)
        if type(data) ~= "table" then error("配置文件格式不对") end
        for k, v in pairs(data) do
            if Config[k] ~= nil and type(v) == type(Config[k]) then
                Config[k] = v
            end
        end
    end)
    if ok then log("配置已加载") else log("加载配置失败: %s", tostring(err)) end
    return ok
end

--==============================================================
-- 4. 游戏句柄（ReplicatedStorage 结构）
--==============================================================
local function rget(path, timeout)
    -- path 形如 {"Info","Inventory"}
    local node = ReplicatedStorage
    for i, name in ipairs(path) do
        local ok, got = pcall(function()
            if i == #path and timeout then
                return node:WaitForChild(name, timeout)
            end
            return node:FindFirstChild(name)
        end)
        node = ok and got or nil
        if not node then return nil end
    end
    return node
end

local Handles = {}
local function refreshHandles()
    Handles.Events    = rget({ "Events" })
    -- 有些版本把事件放在 Remotes / RemoteEvents 下
    if not Handles.Events then
        for _, alt in ipairs({ "Remotes", "RemoteEvents", "Remote" }) do
            Handles.Events = rget({ alt })
            if Handles.Events then break end
        end
    end
    Handles.Data    = rget({ "Data" })
    Handles.Index   = rget({ "Index" })
    Handles.Info    = rget({ "Info" })
    Handles.Inv     = rget({ "Info", "Inventory" })
end
refreshHandles()

-- 已知 Remote 名（逆向恢复，作为兜底清单）
local KNOWN_REMOTES = {
    "SellFish", "BuyFishingRod", "BuyBait", "EquipBait", "BuySkill", "DailyReward",
    "StartBossFight", "ChooseDialogueOption", "RedeemCode", "ToggleHotbar",
    "FavoriteItem", "UpgradeCharacter", "BossPhase2Setup", "BossPhase2Action",
    "StartDialogue", "EquipFishingRod", "CraftBait", "StartAutoTicket",
}

--==============================================================
-- 5. Remote 调用层（自动找 Event / Function，兼容多种壳）
--==============================================================
-- Remote 查找带缓存：避免每个循环都全库扫描 ReplicatedStorage（那很贵）
local remoteCache = {}

local function findRemoteRaw(name)
    local root = Handles.Events or ReplicatedStorage
    local ok, obj = pcall(function() return root:FindFirstChild(name, true) end)
    if ok and obj then return obj end
    local ok2, obj2 = pcall(function()
        for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
            if d.Name == name then return d end
        end
    end)
    return ok2 and obj2 or nil
end

local function findRemote(name)
    local hit = remoteCache[name]
    if hit and hit.Parent then return hit end
    local obj = findRemoteRaw(name)
    remoteCache[name] = obj
    return obj
end

local function clearRemoteCache()
    remoteCache = {}
    refreshHandles()
end

local callStats = { ok = 0, fail = 0, lastError = nil }

local function fire(name, ...)
    local n = select("#", ...)
    local args = { ... }
    local r = findRemote(name)
    if not r then
        callStats.fail = callStats.fail + 1
        callStats.lastError = name .. " 不存在"
        return false, "remote not found: " .. name
    end
    local ok, err = pcall(function()
        if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
            r:FireServer(table.unpack(args, 1, n))
        elseif r:IsA("RemoteFunction") then
            r:InvokeServer(table.unpack(args, 1, n))
        elseif r:IsA("BindableEvent") then
            r:Fire(table.unpack(args, 1, n))
        else
            error("未知 Remote 类型: " .. r.ClassName)
        end
    end)
    if ok then callStats.ok = callStats.ok + 1 else
        callStats.fail = callStats.fail + 1
        callStats.lastError = name .. ": " .. tostring(err)
        log("Remote %s 调用失败: %s", name, tostring(err))
    end
    return ok, err
end

--==============================================================
-- 6. 执行器能力探测（都做安全降级）
--==============================================================
local Cap = {
    getconnections       = type(getconnections) == "function",
    fireproximityprompt  = type(fireproximityprompt) == "function",
    fireclickdetector    = type(fireclickdetector) == "function",
    firetouchinterest    = type(firetouchinterest) == "function",
    getgc                = type(getgc) == "function",
    sethiddenproperty    = type(sethiddenproperty) == "function",
    queueteleport        = type(queueteleport) == "function",
    writefile            = type(writefile) == "function",
    VirtualUser          = pcall(function() return game:GetService("VirtualUser") end),
}

-- 点击一个 GUI 按钮：优先 getconnections 直接触发回调（最可靠）
local function clickButton(btn)
    if type(btn) ~= "table" or not btn then return false end
    -- 1) getconnections（执行器）
    if Cap.getconnections then
        local ok, conns = pcall(getconnections, btn.MouseButton1Click)
        if ok and conns then
            for _, c in ipairs(conns) do
                pcall(function()
                    if c.Fire then c:Fire() end
                end)
            end
            if #conns > 0 then return true end
        end
    end
    -- 2) VirtualUser 按屏幕坐标点
    if Cap.VirtualUser then
        local ok = pcall(function()
            local pos  = btn.AbsolutePosition
            local size = btn.AbsoluteSize
            local VU = game:GetService("VirtualUser")
            VU:Button1Down(Vector2.new(pos.X + size.X / 2, pos.Y + size.Y / 2))
            task.wait(0.03)
            VU:Button1Up(Vector2.new(pos.X + size.X / 2, pos.Y + size.Y / 2))
        end)
        if ok then return true end
    end
    return false
end

-- 触发 ProximityPrompt
local function firePrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then return false end
    if Cap.fireproximityprompt then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then return true end
    end
    return false
end

--==============================================================
-- 7. 角色工具
--==============================================================
local function char()
    return LP.Character
end

local function root()
    local c = char()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

local function hum()
    local c = char()
    if not c then return nil end
    return c:FindFirstChildOfClass("Humanoid")
end

local function alive()
    local h = hum()
    return h ~= nil and h.Health > 0 and root() ~= nil
end

-- 在背包/角色里找一个 Tool
local function findTool(pred)
    local ok, res = pcall(function()
        local bag = LP:FindFirstChildOfClass("Backpack")
        local containers = { bag, char() }
        for _, cont in ipairs(containers) do
            if cont then
                for _, it in ipairs(cont:GetChildren()) do
                    if it:IsA("Tool") and pred(it) then return it end
                end
            end
        end
    end)
    return ok and res or nil
end

local function equipTool(tool)
    local h = hum()
    if not h or not tool then return false end
    if tool.Parent == char() then return true end
    local ok = pcall(function() h:EquipTool(tool) end)
    task.wait(0.2)
    return ok
end

local function unequipAll()
    local h = hum()
    if not h then return end
    pcall(function() h:UnequipTools() end)
    task.wait(0.15)
end

-- 传送到 CFrame（带 HumanoidRootPart 存在性检查）
local function teleportTo(cf)
    local r = root()
    if not r or not cf then return false end
    local ok = pcall(function() r.CFrame = cf end)
    return ok
end

-- 走到某对象旁边（简单传送，用于 NPC / 岛屿）
local function gotoPart(part, offset)
    if not part then return false end
    offset = offset or Vector3.new(0, 0, 3)
    local ok = pcall(function()
        teleportTo(CFrame.new((part.Position + offset)))
    end)
    return ok
end

--==============================================================
-- 8. 调度器：每个功能独立节拍，互不阻塞
--==============================================================
local RUNNING = true
local Loops = {}

local function addLoop(name, interval, enabledFn, fn)
    Loops[#Loops + 1] = {
        name = name, interval = interval, enabled = enabledFn, fn = fn,
        last = 0, errors = 0,
    }
end

local function startScheduler()
    task.spawn(function()
        while RUNNING do
            local now = os.clock()
            for _, l in ipairs(Loops) do
                if RUNNING and (now - l.last) >= l.interval then
                    l.last = now
                    local on = false
                    local okEn, res = pcall(l.enabled)
                    if okEn then on = res and true or false end
                    if on then
                        local ok, err = pcall(l.fn)
                        if not ok then
                            l.errors = l.errors + 1
                            if l.errors <= 3 then
                                log("[%s] 出错: %s", l.name, tostring(err))
                            end
                        end
                    end
                end
            end
            task.wait(0.05)
        end
    end)
    log("调度器已启动，共 %d 个循环", #Loops)
end

--==============================================================
-- 9. GUI 自动化：扫描并点击按钮（不依赖 Remote 签名，最稳）
--==============================================================
local OUR_GUI_NAME = "NNVN_Rewrite_UI"

local function isVisibleDeep(obj)
    local cur = obj
    local guard = 0
    while cur and guard < 12 do
        guard = guard + 1
        if cur:IsA("GuiObject") and cur.Visible == false then return false end
        cur = cur.Parent
    end
    return true
end

local function collectButtons()
    local out = {}
    local function scan(rootObj)
        if not rootObj then return end
        local ok = pcall(function()
            for _, d in ipairs(rootObj:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) then
                    if d.Name ~= OUR_GUI_NAME then
                        local txt = ""
                        pcall(function()
                            if d:IsA("TextButton") then txt = d.Text or "" end
                        end)
                        if isVisibleDeep(d) then
                            out[#out + 1] = { btn = d, text = txt, name = d.Name }
                        end
                    end
                end
            end
        end)
        if not ok then return end
    end
    pcall(function() scan(LP:FindFirstChildOfClass("PlayerGui")) end)
    if CoreGui then pcall(function() scan(CoreGui) end) end
    return out
end

-- 在按钮清单里按关键词优先级找
-- patterns: {"accept easy quest", "accept quest", ...}  越靠前优先级越高
local function matchButton(patterns, exclude)
    local btns = collectButtons()
    for _, pat in ipairs(patterns) do
        local lp = string.lower(pat)
        for _, b in ipairs(btns) do
            local hay = string.lower(b.text .. " " .. b.name)
            if string.find(hay, lp, 1, true) then
                local skip = false
                if exclude then
                    for _, ex in ipairs(exclude) do
                        if string.find(hay, string.lower(ex), 1, true) then skip = true break end
                    end
                end
                if not skip then return b.btn, b.text end
            end
        end
    end
    return nil
end

-- 点一次，带冷却（避免连点把服务器点崩 / 被封）
local lastClick = {}
local function clickSmart(key, patterns, cooldown, exclude)
    cooldown = cooldown or 1
    local now = os.clock()
    if lastClick[key] and (now - lastClick[key]) < cooldown then return false end
    local btn, txt = matchButton(patterns, exclude)
    if not btn then return false end
    local ok = clickButton(btn)
    if ok then
        lastClick[key] = now
        log("[GUI] 点击「%s」", tostring(txt ~= "" and txt or btn.Name))
    end
    return ok
end

--==============================================================
-- 10. 词表：从原脚本恢复的真实按钮文案
--==============================================================
local W = {
    -- 任务
    questOpen    = { "quest", "nhiệm vụ", "任务" },
    questEasy    = { "accept easy quest", "easy quest", "accept easy" },
    questHard    = { "accept hard quest", "hard quest", "accept hard" },
    questAccept  = { "accept quest", "accept", "接受" },
    questTurnIn  = { "turn in", "complete quest", "claim reward", "hand in", "finish quest" },
    questClose   = { "nevermind", "close", "decline", "cancel", "no thanks" },
    -- 对白推进 / Boss 二阶段
    phase2       = { "yes, prepare", "prepare", "phase 2", "phase2", "begin", "continue", "yes" },
    -- 商店
    buy          = { "buy", "purchase", "confirm", "mua" },
    -- 通用确认
    confirm      = { "confirm", "yes", "ok", "okay" },
    -- 领取
    claim        = { "claim", "collect", "receive", "open chest", "open" },
    -- 重连
    rejoin       = { "reconnect", "rejoin", "retry", "返回游戏" },
}

--==============================================================
-- 11. 钓鱼核心
--==============================================================
local Fishing = {
    casting        = false,
    lastCast       = 0,
    casts          = 0,
    catches        = 0,
    lastReel       = 0,
}

-- 找钓竿：名字里含 Rod，排除已装备外的背包
local function findRod()
    return findTool(function(t)
        local n = string.lower(t.Name)
        return string.find(n, "rod", 1, true)
            or string.find(n, "钓竿", 1, true)
            or string.find(n, "cần", 1, true)
    end)
end

-- 判断是否在钓鱼状态：小游戏 GUI / 竿已装备且线已抛
local function isFishingGuiOpen()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return false, nil end
    local found, obj = pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            local n = string.lower(d.Name)
            if string.find(n, "fishingminigame", 1, true)
                or string.find(n, "fishingminigames", 1, true)
                or (string.find(n, "minigame", 1, true) and string.find(n, "fish", 1, true))
                or string.find(n, "reel", 1, true) then
                if d:IsA("GuiObject") and isVisibleDeep(d) then return true, d end
                if d:IsA("ScreenGui") and d.Enabled then return true, d end
                return true, d
            end
        end
    end)
    if found and obj then return true, obj end
    return false, nil
end

-- 抛竿：多策略
local function doCast()
    local rod = findRod()
    if not rod then
        return false, "背包里没有钓竿"
    end
    if not equipTool(rod) then
        return false, "装备钓竿失败"
    end

    -- 策略 1：竿的 Activate
    local okA = pcall(function() rod:Activate() end)
    if okA then
        Fishing.lastCast = os.clock()
        Fishing.casts = Fishing.casts + 1
        return true, "Activate"
    end

    -- 策略 2：附近 ProximityPrompt
    local r = root()
    if r then
        local best
        pcall(function()
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") and d.Enabled then
                    local part = d.Parent
                    if part and part:IsA("BasePart") and (part.Position - r.Position).Magnitude < 40 then
                        best = d break
                    end
                end
            end
        end)
        if best and firePrompt(best) then
            Fishing.lastCast = os.clock()
            Fishing.casts = Fishing.casts + 1
            return true, "ProximityPrompt"
        end
    end

    return false, "抛竿手段都失败"
end

-- 收线 / 小游戏自动化
local function doReel()
    local open, gui = isFishingGuiOpen()
    if not open then return false end
    -- 小游戏通常是「点一下 / 按住」；先试关键词按钮
    local patterns = {
        "reel", "catch", "pull", "grab", "strike", "hook",
        "click", "tap", "collect", "收", "拉",
    }
    local btn = matchButton(patterns, { "close", "exit", "cancel" })
    if btn then
        clickButton(btn)
        Fishing.catches = Fishing.catches + 1
        return true
    end
    -- 兜底：整个 GUI 上找一个最大的按钮点
    if gui then
        local best, area = nil, 0
        pcall(function()
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextButton") and isVisibleDeep(d) then
                    local s = d.AbsoluteSize
                    local a = s.X * s.Y
                    if a > area and a > 400 then best, area = d, a end
                end
            end
        end)
        if best then return clickButton(best) end
    end
    return false
end

--==============================================================
-- 12. 数据读取（Cash / Level / Crystal / Ticket）
--==============================================================
local function safeNum(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then
        local n = tonumber((string.gsub(v, "[^%d%.%-]", "")))
        return n
    end
    return nil
end

local function readStat(nameList)
    -- 依次尝试 Data / Index / Info 下的同名属性或值对象
    local roots = { Handles.Data, Handles.Index, Handles.Info }
    for _, rootObj in ipairs(roots) do
        if rootObj then
            for _, nm in ipairs(nameList) do
                local ok, v = pcall(function()
                    local c = rootObj:FindFirstChild(nm, true)
                    if not c then return nil end
                    if c:IsA("ValueBase") then return c.Value end
                    return c.Value
                end)
                local n = ok and safeNum(v) or nil
                if n then return n end
                -- 属性形式
                local ok2, v2 = pcall(function() return rootObj:GetAttribute(nm) end)
                local n2 = ok2 and safeNum(v2) or nil
                if n2 then return n2 end
            end
        end
    end
    return nil
end

local Stats = { cash = nil, level = nil, crystal = nil, ticket = nil, fishes = nil, rods = 0, baits = 0 }

local function refreshStats()
    Stats.cash    = readStat({ "Cash", "Money", "Coins" })
    Stats.level   = readStat({ "Level", "Lv" })
    Stats.crystal = readStat({ "Crystal", "Crystals", "Gem" })
    Stats.ticket  = readStat({ "Ticket", "Tickets" })
    -- 背包统计
    pcall(function()
        local inv = Handles.Inv or rget({ "Info", "Inventory" })
        if inv then
            local f = inv:FindFirstChild("Fish") or inv:FindFirstChild("Fishes")
            Stats.fishes = f and #f:GetChildren() or nil
            local r2 = inv:FindFirstChild("Rod") or inv:FindFirstChild("Rods")
            Stats.rods = r2 and #r2:GetChildren() or 0
            local b = inv:FindFirstChild("Bait") or inv:FindFirstChild("Baits")
            Stats.baits = b and #b:GetChildren() or 0
        end
    end)
end

--==============================================================
-- 13. 功能：AntiAFK
--==============================================================
addLoop("AntiAFK", 60, function() return Config.AntiAFK end, function()
    local VU
    pcall(function() VU = game:GetService("VirtualUser") end)
    if VU then
        pcall(function()
            VU:CaptureController()
            VU:ClickButton2(Vector2.new())
        end)
    else
        pcall(function()
            local h = hum(); if h then h.Jump = true end
        end)
    end
end)

--==============================================================
-- 14. 功能：AutoCast（自动抛竿 + 自动收线）
--==============================================================
addLoop("AutoCast", 0.4, function()
    return Config.AutoCast and alive()
end, function()
    local now = os.clock()
    local open = isFishingGuiOpen()

    if open then
        Fishing.casting = true
        -- 小游戏开着 → 收线
        if (now - Fishing.lastReel) > 0.25 then
            Fishing.lastReel = now
            doReel()
        end
        return
    end

    Fishing.casting = false
    if (now - Fishing.lastCast) < Config.CastDelay then return end

    local ok, how = doCast()
    if ok then
        Fishing.lastCast = now
        if Fishing.casts % 20 == 1 then
            log("抛竿 #%d (%s)", Fishing.casts, tostring(how))
        end
    else
        -- 失败也别狂刷
        Fishing.lastCast = now - Config.CastDelay + 1.5
    end
end)

--==============================================================
-- 15. 功能：AutoSell
--==============================================================
addLoop("AutoSell", 1, function() return Config.AutoSell end, function()
    local now = os.clock()
    if (now - (Fishing.lastSell or 0)) < Config.SellInterval then return end
    Fishing.lastSell = now

    local ok = fire("SellFish")
    if not ok then
        -- 兜底：找 Sell 按钮 / NPC 提示
        clickSmart("sell", { "sell all", "sell fish", "sell" }, 2, { "cancel" })
    else
        log("卖出全部鱼")
    end
end)

--==============================================================
-- 16. 功能：鱼饵（买 / 换 / 自动最佳 / 制作）
--==============================================================
addLoop("AutoUseBait", 3, function() return Config.AutoUseBait end, function()
    if not Config.BaitName or Config.BaitName == "" then return end
    fire("EquipBait", Config.BaitName)
end)

addLoop("AutoBuyBait", 5, function() return Config.AutoBuyBait end, function()
    local qty = math.max(1, math.floor(Config.BaitQuantity or 1))
    local ok = fire("BuyBait", Config.BaitName, qty)
    if not ok then fire("BuyBait", Config.BaitName) end
end)

-- 自动装备最好的鱼饵：按「剩余数量 × 品质」估分
local BAIT_TIER = {
    ["Basic Bait"] = 1, ["Crude Mash Bait"] = 2, ["Elite Bait"] = 4,
    ["Ancestral Bait"] = 6, ["Corrupted Essence Bait"] = 7,
    ["Frost Bait"] = 5, ["Rainbow Bait"] = 8,
}
addLoop("AutoEquipBestBait", 8, function() return Config.AutoEquipBestBait end, function()
    local inv = Handles.Inv or rget({ "Info", "Inventory" })
    if not inv then return end
    local best, bestScore = nil, -1
    pcall(function()
        local baitRoot = inv:FindFirstChild("Bait") or inv:FindFirstChild("Baits")
        if not baitRoot then return end
        for _, item in ipairs(baitRoot:GetChildren()) do
            local nm = item.Name
            local count = 0
            local v = item:FindFirstChild("Amount") or item:FindFirstChild("Count") or item:FindFirstChild("Value")
            if v and v:IsA("ValueBase") then count = tonumber(v.Value) or 0 end
            local tier = BAIT_TIER[nm] or 1
            local score = (count > 0) and tier or -1
            if score > bestScore then best, bestScore = nm, score end
        end
    end)
    if best then fire("EquipBait", best) end
end)

addLoop("AutoCraftBait", 20, function() return Config.AutoCraftBait end, function()
    local ok = fire("CraftBait")
    if not ok then clickSmart("craftbait", { "craft bait", "craft" }, 5, { "cancel" }) end
end)

--==============================================================
-- 17. 功能：AutoEquipRod
--==============================================================
addLoop("AutoEquipRod", 6, function() return Config.AutoEquipRod and alive() end, function()
    local rod = findRod()
    if rod and rod.Parent ~= char() then equipTool(rod) end
end)

--==============================================================
-- 18. 功能：AutoSkill
--==============================================================
local SKILL_KEYS = {
    "Aerial Rod Throw", "Demonic", "Dragonfish Vitality", "Infinite Sky Ascension",
    "One-Strike Heaven Gate", "Phoenix Strike Art", "Rolling Chaos", "Rooster Strike",
    "Skybreaker Technique", "Skyfall Stomp", "Thousand Enemy Sweep", "Unshake Stance",
    "Reel Sprint", "Swift Reel",
}
local skillIdx = 0
addLoop("AutoSkill", 1, function() return Config.AutoSkill and alive() end, function()
    skillIdx = skillIdx % #SKILL_KEYS + 1
    local name = SKILL_KEYS[skillIdx]
    fire("BuySkill", name)
end)

--==============================================================
-- 19. 功能：日常（领奖 / 兑换码）
--==============================================================
addLoop("AutoClaimDaily", 5, function() return Config.AutoClaimDaily end, function()
    local now = os.clock()
    if (now - (Fishing.lastDaily or 0)) < Config.ClaimDailyDelay then return end
    Fishing.lastDaily = now
    local ok = fire("DailyReward")
    if not ok then clickSmart("daily", { "daily reward", "claim daily", "daily" }, 3, { "cancel" }) end
end)

-- 恢复出来的兑换码（原脚本里写死的，可能已过期，但先全试一遍）
local CODES = {
    "NNVN", "DISCORD_CODE", "DISCORD_INVITE", "UIBUG", "BAIT_RECIPES",
    "ESP_", "NNVN_ESP", "NPC_", "MAT_FISH_CFRAME", "MAT_WEATHER_REQUIRED",
    "0A1128", "4B0082", "2107",
}
addLoop("AutoRedeemCodes", 3, function() return Config.AutoRedeemCodes end, function()
    if not RedeemQueue then
        RedeemQueue = { n = 1 }
        log("开始尝试 %d 个兑换码", #CODES)
    end
    local i = RedeemQueue.n
    if not i or i > #CODES then return end
    RedeemQueue.n = i + 1
    local ok = fire("RedeemCode", CODES[i])
    if ok then log("提交兑换码: %s", CODES[i]) end
end)

--==============================================================
-- 20. 功能：任务对话自动化（GUI 驱动，最稳）
--     原脚本靠 ChooseDialogueOption 硬发；这里改成"看到按钮就点"，
--     不依赖 Remote 签名，游戏改版也不容易坏。
--==============================================================
-- 判定"对话开着"：必须同时看到「任务类选项」和「关闭类选项」。
-- 只看到 Close 不算 —— 很多常驻界面都有 Close 按钮，误判会连带误点。
local CLOSE_WORDS = { "nevermind", "close", "decline", "cancel" }
local FUNC_WORDS  = { "quest", "accept", "turn in", "complete", "ticket", "reward", "trade" }

local function dialogueVisible()
    local btns = collectButtons()
    local hasClose, hasFunc = false, false
    for _, b in ipairs(btns) do
        local hay = string.lower(b.text .. " " .. b.name)
        for _, w in ipairs(CLOSE_WORDS) do
            if string.find(hay, w, 1, true) then hasClose = true break end
        end
        for _, w in ipairs(FUNC_WORDS) do
            if string.find(hay, w, 1, true) then hasFunc = true break end
        end
        if hasClose and hasFunc then return true end
    end
    return false
end

addLoop("AutoQuest", 1, function()
    return Config.AutoAcceptQuest or Config.AutoTurnIn or Config.AutoPhase2 or Config.AutoTicketQuest
end, function()
    if not dialogueVisible() then return end

    -- 优先级 1：交付任务（做完的任务先交掉）
    if Config.AutoTurnIn then
        if clickSmart("turnin", W.questTurnIn, 2) then return end
    end

    -- 优先级 2：接任务
    if Config.AutoAcceptQuest or Config.AutoTicketQuest then
        local wantHard = (Config.TicketDifficulty == "Hard")
        if clickSmart("diff", wantHard and W.questHard or W.questEasy, 2) then
            log("选择难度: %s", wantHard and "Hard" or "Easy")
            return
        end
        if clickSmart("accept", W.questAccept, 2,
            { "nevermind", "close", "decline", "cancel", "turn in" }) then
            return
        end
        -- 对话第一层通常要先选 "Quest"
        clickSmart("questopen", W.questOpen, 3,
            { "nevermind", "close", "decline", "ticket quest" })
    end

    -- 优先级 3：Boss 二阶段 / 推进对话
    if Config.AutoPhase2 then
        clickSmart("phase2", W.phase2, 4, { "no", "decline", "cancel", "nevermind" })
    end
end)

-- 对话一出现就把 NPC 传过去（有些任务必须先对话才给接）
addLoop("QuestNpcApproach", 4, function()
    return (Config.AutoAcceptQuest or Config.AutoTicketQuest or Config.AutoTurnIn) and alive()
end, function()
    if dialogueVisible() then return end
    local r = root()
    if not r then return end
    -- 找名字里带 Quest / Ticket 的 NPC 模型
    local target
    pcall(function()
        for _, m in ipairs(workspace:GetDescendants()) do
            if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                local n = string.lower(m.Name)
                if string.find(n, "ticket quest", 1, true)
                    or string.find(n, "quest giver", 1, true)
                    or string.find(n, "ba thuong", 1, true) then
                    local hrp = m:FindFirstChild("HumanoidRootPart")
                    if hrp and (hrp.Position - r.Position).Magnitude < 500 then
                        target = m break
                    end
                end
            end
        end
    end)
    if target then
        local hrp = target:FindFirstChild("HumanoidRootPart")
        if hrp then
            local behind = hrp.CFrame * CFrame.new(0, 0, 3)
            teleportTo(behind)
            task.wait(0.15)
            -- 尝试触发对话（点 NPC 或提示）
            clickSmart("talknpc", { "talk", "speak", "interact", "quest" }, 6)
        end
    end
end)

--==============================================================
-- 21. 功能：Boss
--==============================================================
local function findModelByKeywords(keywords, maxDist)
    local r = root()
    local out = {}
    pcall(function()
        for _, m in ipairs(workspace:GetDescendants()) do
            if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                local n = string.lower(m.Name)
                for _, kw in ipairs(keywords) do
                    if string.find(n, kw, 1, true) then
                        local hrp = m:FindFirstChild("HumanoidRootPart")
                        if hrp then
                            local d = r and (hrp.Position - r.Position).Magnitude or 0
                            if not maxDist or d <= maxDist then
                                out[#out + 1] = { model = m, hrp = hrp, dist = d }
                            end
                        end
                        break
                    end
                end
            end
        end
    end)
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

addLoop("AutoBossFight", 3, function()
    return Config.AutoBossFight and alive()
end, function()
    local bosses = findModelByKeywords({ "boss", "secretboss", "secret boss" }, 2000)
    if #bosses == 0 then return end

    -- 先推进二阶段 / 确认对话
    if clickSmart("bossphase2", { "phase 2", "phase2", "prepare", "yes, prepare" }, 3,
        { "no", "decline" }) then return end

    local ok = fire("StartBossFight")
    if not ok then
        -- 兜底：走到 boss 旁边点提示
        gotoPart(bosses[1].hrp, Vector3.new(0, 0, 5))
        task.wait(0.2)
        clickSmart("bossstart", { "start boss", "start fight", "fight", "challenge" }, 4)
    else
        log("发起 Boss 战（视野内 %d 个）", #bosses)
    end
end)

addLoop("BossCombat", 0.6, function()
    return (Config.AutoBossFight or Config.AutoFarmSecretBoss) and alive()
end, function()
    local bosses = findModelByKeywords({ "boss" }, 300)
    if #bosses == 0 then return end
    -- 贴身 + 攻击
    local closest = bosses[1]
    if closest.dist > 12 then
        gotoPart(closest.hrp, Vector3.new(0, 0, 6))
    end
    local btn = matchButton({ "attack", "strike", "hit", "skill", "cast" }, { "cancel" })
    if btn then clickButton(btn) end
    -- 技能 Remote 也可以帮你打
    if Config.AutoSkill then
        fire("BuySkill", SKILL_KEYS[skillIdx])
    end
end)

addLoop("AutoFarmSecretBoss", 6, function()
    return Config.AutoFarmSecretBoss and alive()
end, function()
    local sec = findModelByKeywords({ "secretboss", "secret boss", "specialboss", "special boss" }, 5000)
    if #sec == 0 then return end
    gotoPart(sec[1].hrp, Vector3.new(0, 0, 6))
    task.wait(0.2)
    fire("StartBossFight")
end)

--==============================================================
-- 22. 功能：岛屿传送
--==============================================================
local ISLANDS = {
    "Beginning Isle", "Bamboo Isle", "Coconut Isle", "Perch Isle",
    "Amber Isle", "Frost Isle", "Fallout Isle", "Battlefield Isle",
    "Mistpeak Isle", "Sovereign Isle",
}

local function findIslandPart(name)
    local target = string.lower(name)
    local best, bestScore = nil, -1
    pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") then
                local n = string.lower(d.Name)
                local score = 0
                if n == target then score = 3
                elseif string.find(n, target, 1, true) then score = 2 end
                if score > bestScore then best, bestScore = d, score end
            end
        end
    end)
    return best
end

addLoop("IslandTeleport", 2, function()
    return Config.IslandTeleport and alive() and Config.TargetIsland ~= ""
end, function()
    local part = findIslandPart(Config.TargetIsland)
    if not part then
        log("找不到岛屿: %s", Config.TargetIsland)
        Config.IslandTeleport = false  -- 只报一次，避免刷屏
        return
    end
    teleportTo(CFrame.new(part.Position + Vector3.new(0, 12, 0)))
    log("传送到 %s", Config.TargetIsland)
    Config.IslandTeleport = false
end)

--==============================================================
-- 23. 功能：水上行走 / 飞行
--==============================================================
addLoop("WalkOnWater", 0.35, function()
    return Config.WalkOnWater and alive()
end, function()
    local r = root()
    if not r then return end
    -- 在脚下放一个不可见平台（本地生成，只有自己看得见）
    local plat = workspace:FindFirstChild("NNVN_WaterPlate")
    if not plat then
        local p = Instance.new("Part")
        p.Name = "NNVN_WaterPlate"
        p.Size = Vector3.new(12, 0.4, 12)
        p.Anchored = true
        p.CanCollide = true
        p.Transparency = 1
        p.CFrame = CFrame.new(r.Position - Vector3.new(0, 3.2, 0))
        p.Parent = workspace
    else
        plat.CFrame = CFrame.new(r.Position - Vector3.new(0, 3.2, 0))
    end
end)

addLoop("Fly", 0.1, function()
    return (Config.FlySpeed or 0) > 0 and alive()
end, function()
    local r = root()
    local h = hum()
    if not r or not h then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local move = Vector3.new()
    local function pressed(k) return UserInputService:IsKeyDown(k) end
    if pressed(Enum.KeyCode.W) then move = move + cam.CFrame.LookVector end
    if pressed(Enum.KeyCode.S) then move = move - cam.CFrame.LookVector end
    if pressed(Enum.KeyCode.A) then move = move - cam.CFrame.RightVector end
    if pressed(Enum.KeyCode.D) then move = move + cam.CFrame.RightVector end
    if pressed(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
    if pressed(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end

    if move.Magnitude > 0 then
        move = move.Unit * Config.FlySpeed
        -- 直接位移，不用速度，稳
        r.CFrame = r.CFrame + move * 0.1
        pcall(function() h.PlatformStand = true end)
    end
end)

--==============================================================
-- 24. 功能：服务器跳转
--==============================================================
local TeleportService = game:GetService("TeleportService")
local PlaceId = game.PlaceId

local function httpGet(url)
    local ok, body = pcall(function()
        if game.HttpGet then return game:HttpGet(url, true) end
        if httpget then return httpget(url) end
        if syn and syn.request then return syn.request({ Url = url, Method = "GET" }).Body end
        if request then return request({ Url = url, Method = "GET" }).Body end
        error("没有可用的 HTTP 方法")
    end)
    if ok then return body end
    return nil
end

local function fetchServers(cursor)
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s",
        PlaceId, cursor and ("&cursor=" .. cursor) or "")
    local body = httpGet(url)
    if not body then return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" then return nil end
    return data.data, data.nextPageCursor
end

local function hopServer()
    local list = fetchServers(nil)
    if not list then Notify("获取服务器列表失败") return end
    local me = game.JobId
    for _, s in ipairs(list) do
        if s.id and s.id ~= me and (s.playing or 0) < (s.maxPlayers or 0) - 1 then
            log("跳转到服务器 %s", tostring(s.id))
            local ok = pcall(function()
                TeleportService:TeleportToPlaceInstance(PlaceId, s.id, LP)
            end)
            if ok then return end
        end
    end
    Notify("没找到合适的服务器")
end

addLoop("AutoRejoin", 5, function()
    return Config.AutoRejoin
end, function()
    -- 断线弹窗 / 重连按钮
    clickSmart("rejoin", W.rejoin, 5)
end)

addLoop("ServerHop", 20, function()
    return Config.ServerHopGod or Config.ServerHopMaoshan or Config.ServerHopTaoist
end, function()
    local want
    if Config.ServerHopGod then want = { "god spirit" } end
    if Config.ServerHopMaoshan then want = { "maoshan" } end
    if Config.ServerHopTaoist then want = { "taoist" } end
    if not want then return end

    local found = findModelByKeywords(want, nil)
    if #found > 0 then
        log("本服已发现目标 NPC，不跳")
        Config.ServerHopGod = false
        Config.ServerHopMaoshan = false
        Config.ServerHopTaoist = false
        return
    end
    hopServer()
end)

--==============================================================
-- 25. 功能：ESP
--==============================================================
local espRegistry = {}   -- [model] = Highlight

local ESP_COLORS = {
    boss       = Color3.fromRGB(255, 40, 40),
    npc        = Color3.fromRGB(0, 200, 255),
    secretrod  = Color3.fromRGB(255, 60, 60),
    godspirit  = Color3.fromRGB(255, 215, 0),
    maoshan    = Color3.fromRGB(170, 0, 255),
    taoist     = Color3.fromRGB(255, 140, 0),
}

local function applyESP(model, color, key)
    if not model or not model:IsA("Model") then return end
    if espRegistry[model] then return end
    local ok, hl = pcall(function()
        local h = Instance.new("Highlight")
        h.FillColor = color
        h.FillTransparency = 0.55
        h.OutlineColor = color
        h.OutlineTransparency = 0
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Adornee = model
        h.Parent = model
        return h
    end)
    if ok then espRegistry[model] = hl end
end

local function clearESP()
    for m, h in pairs(espRegistry) do
        pcall(function() h:Destroy() end)
    end
    espRegistry = {}
end

local ESP_RULES = {
    { cfg = "ESPBoss",      color = ESP_COLORS.boss,      kws = { "boss" } },
    { cfg = "ESPNPC",       color = ESP_COLORS.npc,       kws = { "npc", "ba thuong", "rod seller", "bait seller" } },
    { cfg = "ESPSecretRod", color = ESP_COLORS.secretrod, kws = { "secretrod", "secret rod" } },
    { cfg = "ESPGodSpirit", color = ESP_COLORS.godspirit, kws = { "god spirit", "godspirit", "spirit npc" } },
    { cfg = "ESPMaoshan",   color = ESP_COLORS.maoshan,   kws = { "maoshan" } },
    { cfg = "ESPTaoist",    color = ESP_COLORS.taoist,    kws = { "taoist" } },
}

addLoop("ESP", 1.0, function()
    for _, rdef in ipairs(ESP_RULES) do
        if Config[rdef.cfg] then return true end
    end
    return false
end, function()
    for _, rdef in ipairs(ESP_RULES) do
        local on = Config[rdef.cfg]
        if on then
            pcall(function()
                for _, m in ipairs(workspace:GetDescendants()) do
                    if m:IsA("Model") then
                        local n = string.lower(m.Name)
                        for _, kw in ipairs(rdef.kws) do
                            if string.find(n, kw, 1, true) then
                                applyESP(m, rdef.color, rdef.cfg)
                                break
                            end
                        end
                    end
                end
            end)
        end
    end
end)

-- 开关全关时清掉
task.spawn(function()
    while RUNNING do
        local any = false
        for _, rdef in ipairs(ESP_RULES) do
            if Config[rdef.cfg] then any = true break end
        end
        if not any and next(espRegistry) then clearESP() end
        task.wait(2)
    end
end)

--==============================================================
-- 26. 数据面板刷新
--==============================================================
local InfoLabel = nil
addLoop("RefreshStats", 1.5, function() return Config.ShowInfo end, function()
    refreshStats()
    if InfoLabel and InfoLabel.Parent then
        local function f(v, suffix)
            if v == nil then return "?" end
            if type(v) ~= "number" then return tostring(v) end
            if v >= 1e9 then return string.format("%.2fB", v / 1e9) end
            if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
            if v >= 1e3 then return string.format("%.1fK", v / 1e3) end
            return string.format("%d", math.floor(v))
        end
        InfoLabel.Text = string.format(
            "💰 %s   ⭐ Lv %s   💎 %s   🎫 %s\n🐟 %s   🎣 竿 %d   饵 %d",
            f(Stats.cash), f(Stats.level), f(Stats.crystal), f(Stats.ticket),
            f(Stats.fishes), Stats.rods, Stats.baits)
    end
end)

--==============================================================
-- 27. UI —— 自建轻量组件库（零外部依赖）
--==============================================================
local UI = {
    tabs = {},
    controls = {},   -- 需要随 Config 刷新的控件
    activeTab = nil,
}

-- 主题
local THEMES = {
    ["紫"] = { accent = Color3.fromRGB(150, 90, 255), accent2 = Color3.fromRGB(110, 60, 210) },
    ["青"] = { accent = Color3.fromRGB(60, 200, 220), accent2 = Color3.fromRGB(30, 150, 175) },
    ["绿"] = { accent = Color3.fromRGB(80, 210, 120), accent2 = Color3.fromRGB(45, 160, 85) },
    ["红"] = { accent = Color3.fromRGB(240, 80, 90),  accent2 = Color3.fromRGB(190, 50, 60) },
    ["金"] = { accent = Color3.fromRGB(235, 185, 60), accent2 = Color3.fromRGB(185, 140, 35) },
}
-- UserInputService 连接集中管理（卸载时统一断开）
local UIS_CONNS = {}
local function uisConnect(evt, fn)
    local c = evt:Connect(fn)
    UIS_CONNS[#UIS_CONNS + 1] = c
    return c
end

local function theme()
    return THEMES[Config.ThemeColor] or THEMES["紫"]
end

local BG      = Color3.fromRGB(26, 26, 32)
local BG2     = Color3.fromRGB(34, 34, 42)
local BG3     = Color3.fromRGB(44, 44, 54)
local FG      = Color3.fromRGB(236, 236, 245)
local FG_DIM  = Color3.fromRGB(160, 160, 178)
local FONT    = Enum.Font.GothamMedium
local FONT_B  = Enum.Font.GothamBold

local function corner(o, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = o
    return c
end

local function stroke(o, col, thick)
    local s = Instance.new("UIStroke")
    s.Color = col or BG3
    s.Thickness = thick or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = o
    return s
end

local function padding(o, p)
    local u = Instance.new("UIPadding")
    u.PaddingTop = UDim.new(0, p)
    u.PaddingBottom = UDim.new(0, p)
    u.PaddingLeft = UDim.new(0, p)
    u.PaddingRight = UDim.new(0, p)
    u.Parent = o
    return u
end

-- 找放置 UI 的容器
local function uiParent()
    if CoreGui then
        local ok, pg = pcall(function()
            local gui = Instance.new("ScreenGui")
            gui.Name = OUR_GUI_NAME
            gui.ResetOnSpawn = false
            gui.IgnoreGuiInset = true
            gui.DisplayOrder = 999
            gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            gui.Parent = CoreGui
            return gui
        end)
        if ok and pg then return pg end
    end
    local ok2, pg2 = pcall(function()
        local gui = Instance.new("ScreenGui")
        gui.Name = OUR_GUI_NAME
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = true
        gui.DisplayOrder = 999
        gui.Parent = LP:WaitForChild("PlayerGui", 10)
        return gui
    end)
    if ok2 then return pg2 end
    return nil
end

local ScreenGui = uiParent()
if not ScreenGui then
    log("无法创建 UI 容器，脚本以无界面模式运行")
end

--==============================================================
-- 28. 通知（右上角堆叠 toast）
--==============================================================
local toastHolder
if ScreenGui then
    toastHolder = Instance.new("Frame")
    toastHolder.Name = "Toasts"
    toastHolder.BackgroundTransparency = 1
    toastHolder.AnchorPoint = Vector2.new(1, 0)
    toastHolder.Position = UDim2.new(1, -14, 0, 14)
    toastHolder.Size = UDim2.new(0, 300, 0, 400)
    toastHolder.Parent = ScreenGui

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    layout.Parent = toastHolder
end

Notify = function(text, dur)
    log("%s", tostring(text))
    if not toastHolder then return end
    local f = Instance.new("Frame")
    f.BackgroundColor3 = BG2
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.Parent = toastHolder
    corner(f, 8); stroke(f, theme().accent, 1)

    local bar = Instance.new("Frame")
    bar.BackgroundColor3 = theme().accent
    bar.Size = UDim2.new(0, 3, 1, 0)
    bar.Parent = f
    corner(bar, 2)

    local lb = Instance.new("TextLabel")
    lb.BackgroundTransparency = 1
    lb.Position = UDim2.new(0, 12, 0, 8)
    lb.Size = UDim2.new(1, -24, 1, -16)
    lb.AutomaticSize = Enum.AutomaticSize.Y
    lb.Font = FONT
    lb.TextSize = 13
    lb.TextColor3 = FG
    lb.TextWrapped = true
    lb.TextXAlignment = Enum.TextXAlignment.Left
    lb.Text = tostring(text)
    lb.Parent = f

    task.delay(dur or 4, function()
        pcall(function()
            local tw = TweenService:Create(f, TweenInfo.new(0.25), { BackgroundTransparency = 1 })
            tw:Play()
            tw.Completed:Wait()
            f:Destroy()
        end)
    end)
end

--==============================================================
-- 29. 主窗口
--==============================================================
local UI_REFS = {}
local Main, Content, Sidebar
if ScreenGui then
    Main = Instance.new("Frame")
    Main.Name = "Main"
    Main.BackgroundColor3 = BG
    Main.BorderSizePixel = 0
    Main.Position = UDim2.new(0, 60, 0, 60)
    Main.Size = UDim2.new(0, 520, 0, 430)
    Main.ClipsDescendants = true
    Main.Parent = ScreenGui
    corner(Main, 10); stroke(Main, BG3, 1)

    -- 标题栏
    local Title = Instance.new("Frame")
    Title.BackgroundColor3 = BG2
    Title.Size = UDim2.new(1, 0, 0, 40)
    Title.Parent = Main
    corner(Title, 10)

    local TitleText = Instance.new("TextLabel")
    TitleText.BackgroundTransparency = 1
    TitleText.Position = UDim2.new(0, 14, 0, 0)
    TitleText.Size = UDim2.new(1, -120, 1, 0)
    TitleText.Font = FONT_B
    TitleText.TextSize = 15
    TitleText.TextColor3 = FG
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Text = "🐟  NNVN Hub  •  重写版"
    TitleText.Parent = Title

    -- 关闭（卸载脚本）
    local CloseBtn = Instance.new("TextButton")
    CloseBtn.BackgroundColor3 = Color3.fromRGB(70, 40, 45)
    CloseBtn.AnchorPoint = Vector2.new(1, 0.5)
    CloseBtn.Position = UDim2.new(1, -10, 0.5, 0)
    CloseBtn.Size = UDim2.new(0, 26, 0, 26)
    CloseBtn.Font = FONT_B
    CloseBtn.TextSize = 14
    CloseBtn.TextColor3 = FG
    CloseBtn.Text = "×"
    CloseBtn.AutoButtonColor = true
    CloseBtn.Parent = Title
    corner(CloseBtn, 6)

    -- 收起
    local MinBtn = Instance.new("TextButton")
    MinBtn.BackgroundColor3 = BG3
    MinBtn.AnchorPoint = Vector2.new(1, 0.5)
    MinBtn.Position = UDim2.new(1, -42, 0.5, 0)
    MinBtn.Size = UDim2.new(0, 26, 0, 26)
    MinBtn.Font = FONT_B
    MinBtn.TextSize = 14
    MinBtn.TextColor3 = FG
    MinBtn.Text = "–"
    MinBtn.Parent = Title
    corner(MinBtn, 6)

    -- 侧栏
    Sidebar = Instance.new("Frame")
    Sidebar.BackgroundColor3 = BG2
    Sidebar.Position = UDim2.new(0, 0, 0, 40)
    Sidebar.Size = UDim2.new(0, 118, 1, -40)
    Sidebar.Parent = Main
    local sbPad = Instance.new("UIPadding")
    sbPad.PaddingTop = UDim.new(0, 8)
    sbPad.PaddingLeft = UDim.new(0, 8)
    sbPad.PaddingRight = UDim.new(0, 8)
    sbPad.Parent = Sidebar
    local sbl = Instance.new("UIListLayout")
    sbl.Padding = UDim.new(0, 4)
    sbl.Parent = Sidebar

    -- 内容区
    Content = Instance.new("ScrollingFrame")
    Content.BackgroundTransparency = 1
    Content.Position = UDim2.new(0, 118, 0, 40)
    Content.Size = UDim2.new(1, -118, 1, -40)
    Content.CanvasSize = UDim2.new(0, 0, 0, 0)
    Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Content.ScrollBarThickness = 4
    Content.ScrollBarImageColor3 = theme().accent
    Content.Parent = Main
    local cPad = Instance.new("UIPadding")
    cPad.PaddingTop = UDim.new(0, 10)
    cPad.PaddingLeft = UDim.new(0, 12)
    cPad.PaddingRight = UDim.new(0, 12)
    cPad.PaddingBottom = UDim.new(0, 12)
    cPad.Parent = Content
    local cl = Instance.new("UIListLayout")
    cl.Padding = UDim.new(0, 6)
    cl.Parent = Content

    -- 拖动
    local dragging, dragStart, startPos = false, nil, nil
    Title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Main.Position
        end
    end)
    Title.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    uisConnect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    -- 收起 / 展开
    UI_REFS.main = Main
    UI_REFS.content = Content
    UI_REFS.sidebar = Sidebar
    UI_REFS.close = CloseBtn
    UI_REFS.min = MinBtn
    UI_REFS.title = Title

    local collapsed = false
    MinBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        Main.Size = collapsed and UDim2.new(0, 520, 0, 40) or UDim2.new(0, 520, 0, 430)
        Content.Visible = not collapsed
        Sidebar.Visible = not collapsed
    end)
end

--==============================================================
-- 30. 控件工厂
--==============================================================
local function addControl(frame)
    frame.Parent = Content
    return frame
end

local function section(titleText)
    if not Content then return end
    local f = Instance.new("Frame")
    f.BackgroundColor3 = BG2
    f.Size = UDim2.new(1, 0, 0, 28)
    f.Parent = Content
    corner(f, 6)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 0)
    l.Size = UDim2.new(1, -20, 1, 0)
    l.Font = FONT_B
    l.TextSize = 12
    l.TextColor3 = theme().accent
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(titleText)
    l.Parent = f
    return f
end

local function baseRow(h)
    if not Content then return nil end
    local f = Instance.new("Frame")
    f.BackgroundColor3 = BG2
    f.Size = UDim2.new(1, 0, 0, h or 30)
    f.Parent = Content
    corner(f, 6)
    return f
end

local function labelRow(textStr, color)
    local f = baseRow(26)
    if not f then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 0)
    l.Size = UDim2.new(1, -20, 1, 0)
    l.Font = FONT
    l.TextSize = 12
    l.TextColor3 = color or FG_DIM
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = true
    l.Text = tostring(textStr)
    l.Parent = f
    return l
end

-- 开关
local function toggle(textStr, key, onChange)
    local f = baseRow(30)
    if not f then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 0)
    l.Size = UDim2.new(1, -70, 1, 0)
    l.Font = FONT
    l.TextSize = 13
    l.TextColor3 = FG
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = tostring(textStr)
    l.Parent = f

    local knob = Instance.new("Frame")
    knob.BackgroundColor3 = BG3
    knob.AnchorPoint = Vector2.new(1, 0.5)
    knob.Position = UDim2.new(1, -10, 0.5, 0)
    knob.Size = UDim2.new(0, 40, 0, 20)
    knob.Parent = f
    corner(knob, 10)

    local dot = Instance.new("Frame")
    dot.BackgroundColor3 = FG_DIM
    dot.AnchorPoint = Vector2.new(0, 0.5)
    dot.Position = UDim2.new(0, 2, 0.5, 0)
    dot.Size = UDim2.new(0, 16, 0, 16)
    dot.Parent = knob
    corner(dot, 8)

    local btn = Instance.new("TextButton")
    btn.BackgroundTransparency = 1
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.Text = ""
    btn.Parent = f

    local function render()
        local on = Config[key] and true or false
        knob.BackgroundColor3 = on and theme().accent or BG3
        dot.BackgroundColor3 = on and Color3.fromRGB(255, 255, 255) or FG_DIM
        dot.Position = on and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
    end

    btn.MouseButton1Click:Connect(function()
        Config[key] = not Config[key]
        render()
        if onChange then onChange(Config[key]) end
    end)

    render()
    UI.controls[#UI.controls + 1] = render
    return f
end

-- 滑条
local function slider(textStr, key, minV, maxV, step, fmt)
    local f = baseRow(46)
    if not f then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 2)
    l.Size = UDim2.new(1, -20, 0, 18)
    l.Font = FONT
    l.TextSize = 12
    l.TextColor3 = FG
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = f

    local track = Instance.new("Frame")
    track.BackgroundColor3 = BG3
    track.Position = UDim2.new(0, 10, 0, 30)
    track.Size = UDim2.new(1, -20, 0, 6)
    track.Parent = f
    corner(track, 3)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = theme().accent
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.Parent = track
    corner(fill, 3)

    local hit = Instance.new("TextButton")
    hit.BackgroundTransparency = 1
    hit.Size = UDim2.new(1, 0, 1, 20)
    hit.AnchorPoint = Vector2.new(0, 0.5)
    hit.Position = UDim2.new(0, 0, 0.5, 0)
    hit.Text = ""
    hit.Parent = track

    local function render()
        local v = tonumber(Config[key]) or minV
        local ratio = (maxV > minV) and ((v - minV) / (maxV - minV)) or 0
        ratio = math.clamp(ratio, 0, 1)
        fill.Size = UDim2.new(ratio, 0, 1, 0)
        local shown = fmt and fmt(v) or tostring(v)
        l.Text = textStr .. "  :  " .. shown
    end

    local function setFromX(absX)
        local rel = (absX - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X)
        rel = math.clamp(rel, 0, 1)
        local raw = minV + rel * (maxV - minV)
        if step and step > 0 then raw = math.floor(raw / step + 0.5) * step end
        Config[key] = raw
        render()
    end

    hit.MouseButton1Down:Connect(function()
        local conn
        conn = uisConnect(UserInputService.InputChanged, function(input)
            if input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch then
                setFromX(input.Position.X)
            end
        end)
        uisConnect(UserInputService.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                if conn then conn:Disconnect() end
            end
        end)
    end)

    render()
    UI.controls[#UI.controls + 1] = render
    return f
end

-- 文本框
local function textbox(textStr, key, placeholder)
    local f = baseRow(48)
    if not f then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 2)
    l.Size = UDim2.new(1, -20, 0, 16)
    l.Font = FONT
    l.TextSize = 12
    l.TextColor3 = FG
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = tostring(textStr)
    l.Parent = f

    local box = Instance.new("TextBox")
    box.BackgroundColor3 = BG3
    box.Position = UDim2.new(0, 10, 0, 22)
    box.Size = UDim2.new(1, -20, 0, 22)
    box.Font = FONT
    box.TextSize = 12
    box.TextColor3 = FG
    box.PlaceholderText = placeholder or ""
    box.Text = tostring(Config[key] or "")
    box.ClearTextOnFocus = false
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.Parent = f
    corner(box, 4)
    local bp = Instance.new("UIPadding")
    bp.PaddingLeft = UDim.new(0, 6); bp.Parent = box

    box.FocusLost:Connect(function()
        Config[key] = box.Text
        log("%s = %s", textStr, box.Text)
    end)
    return f
end

-- 按钮
local function button(textStr, cb, danger)
    local f = baseRow(32)
    if not f then return end
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = danger and Color3.fromRGB(60, 35, 40) or BG3
    b.Size = UDim2.new(1, 0, 1, 0)
    b.Font = FONT_B
    b.TextSize = 13
    b.TextColor3 = FG
    b.Text = tostring(textStr)
    b.Parent = f
    corner(b, 6)
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(cb)
        if not ok then Notify("执行出错: " .. tostring(err)) end
    end)
    return f
end

-- 下拉（点击循环切换，简单可靠）
local function cycle(textStr, key, list, fmt)
    local f = baseRow(30)
    if not f then return end
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 10, 0, 0)
    l.Size = UDim2.new(1, -130, 1, 0)
    l.Font = FONT
    l.TextSize = 13
    l.TextColor3 = FG
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = tostring(textStr)
    l.Parent = f

    local val = Instance.new("TextButton")
    val.BackgroundColor3 = BG3
    val.AnchorPoint = Vector2.new(1, 0.5)
    val.Position = UDim2.new(1, -10, 0.5, 0)
    val.Size = UDim2.new(0, 110, 0, 22)
    val.Font = FONT
    val.TextSize = 12
    val.TextColor3 = theme().accent
    val.Text = tostring(Config[key])
    val.Parent = f
    corner(val, 4)

    val.MouseButton1Click:Connect(function()
        local cur = tostring(Config[key])
        local idx = 1
        for i, v in ipairs(list) do if tostring(v) == cur then idx = i break end end
        idx = idx % #list + 1
        Config[key] = list[idx]
        val.Text = tostring(list[idx])
        log("%s = %s", textStr, tostring(list[idx]))
    end)
    return f
end

--==============================================================
-- 31. 分页
--==============================================================
local function makeTab(titleText)
    if not Sidebar then return nil end
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = BG
    b.Size = UDim2.new(1, 0, 0, 30)
    b.Font = FONT
    b.TextSize = 13
    b.TextColor3 = FG_DIM
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.Text = "  " .. titleText
    b.Parent = Sidebar
    corner(b, 6)

    local page = Instance.new("Frame")
    page.BackgroundTransparency = 1
    page.Size = UDim2.new(1, 0, 1, 0)
    page.Visible = false
    -- page 只是占位，控件仍放 Content；切页时重建
    local def = { btn = b, name = titleText, build = nil, page = page }
    UI.tabs[#UI.tabs + 1] = def
    return def
end

local function clearContent()
    if not Content then return end
    for _, ch in ipairs(Content:GetChildren()) do
        if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then
            ch:Destroy()
        end
    end
    UI.controls = {}
end

local function showTab(def)
    if not Content then return end
    clearContent()
    for _, t in ipairs(UI.tabs) do
        t.btn.BackgroundColor3 = (t == def) and BG3 or BG
        t.btn.TextColor3 = (t == def) and FG or FG_DIM
    end
    UI.activeTab = def
    if def.build then
        local ok, err = pcall(def.build)
        if not ok then log("页面 %s 构建失败: %s", def.name, tostring(err)) end
    end
    if Content then Content.CanvasPosition = Vector2.new(0, 0) end
end

--==============================================================
-- 32. 页面装配
--==============================================================
local T = {}
T.fishing = makeTab("🎣 钓鱼")
T.quest   = makeTab("📜 任务")
T.boss    = makeTab("⚔️ Boss")
T.skill   = makeTab("✨ 技能")
T.daily   = makeTab("🎁 日常")
T.move    = makeTab("🚀 移动")
T.hop     = makeTab("🌐 跳服")
T.esp     = makeTab("👁 ESP")
T.info    = makeTab("📊 信息")
T.debug   = makeTab("🔧 调试")
T.config  = makeTab("⚙️ 设置")

-- ---------- 钓鱼 ----------
T.fishing.build = function()
    section("核心")
    toggle("自动抛竿 + 自动收线", "AutoCast")
    slider("抛竿间隔 (秒)", "CastDelay", 0.5, 10, 0.5, function(v) return string.format("%.1fs", v) end)
    toggle("自动装备钓竿", "AutoEquipRod")

    section("卖鱼")
    toggle("自动卖鱼", "AutoSell")
    slider("卖鱼间隔 (秒)", "SellInterval", 5, 300, 5, function(v) return string.format("%d s", v) end)
    button("立即卖一次", function()
        local ok = fire("SellFish")
        Notify(ok and "已发送卖鱼请求" or "SellFish 调用失败，看调试页")
    end)
    toggle("自动收藏选中鱼", "AutoFavorite")

    section("鱼饵")
    cycle("要用的鱼饵", "BaitName", {
        "Basic Bait", "Crude Mash Bait", "Elite Bait", "Frost Bait",
        "Ancestral Bait", "Corrupted Essence Bait", "Rainbow Bait",
    })
    toggle("自动换饵", "AutoUseBait")
    toggle("自动装备最佳鱼饵", "AutoEquipBestBait")
    toggle("自动买饵", "AutoBuyBait")
    slider("买饵数量", "BaitQuantity", 1, 50, 1, function(v) return string.format("%d", v) end)
    toggle("自动制作鱼饵", "AutoCraftBait")

    section("说明")
    labelRow("· 抛竿优先用竿的 Activate，失败再找附近 ProximityPrompt\n"
          .. "· 收线靠小游戏按钮（Reel/Catch 关键词），找不到就点最大按钮\n"
          .. "· 每个功能独立开关，坏一个不影响其它")
end

-- ---------- 任务 ----------
T.quest.build = function()
    section("任务")
    toggle("自动接任务", "AutoAcceptQuest")
    toggle("自动接 Ticket 任务", "AutoTicketQuest")
    cycle("Ticket 难度", "TicketDifficulty", { "Easy", "Hard" })
    toggle("自动交任务", "AutoTurnIn")
    toggle("自动推进 Boss 二阶段", "AutoPhase2")

    section("手动")
    button("点一次「接任务」", function()
        local ok = clickSmart("manualquest", W.questAccept, 0,
            { "nevermind", "close", "decline" })
        Notify(ok and "已点击" or "没找到接任务按钮（对话没开？）")
    end)
    button("点一次「交任务」", function()
        local ok = clickSmart("manualturnin", W.questTurnIn, 0)
        Notify(ok and "已点击" or "没找到交任务按钮")
    end)
    button("把对话选项列出来（看调试页）", function()
        local btns = collectButtons()
        for _, b in ipairs(btns) do
            log("按钮: text=「%s」 name=%s", tostring(b.text), tostring(b.name))
        end
        Notify(string.format("当前界面上有 %d 个按钮，详见调试页", #btns))
    end)

    section("说明")
    labelRow("任务走 GUI 点击，不硬发 ChooseDialogueOption —— 这样游戏改签名也不会坏。\n"
          .. "如果它不动，先点上面第三个按钮看看游戏里按钮到底叫什么。")
end

-- ---------- Boss ----------
T.boss.build = function()
    section("Boss 自动化")
    toggle("自动 Boss 战", "AutoBossFight")
    toggle("Boss 钓鱼模式（跳过普通鱼）", "AutoBossFishing")
    toggle("自动刷 Secret Boss", "AutoFarmSecretBoss")

    section("手动")
    button("搜索附近 Boss", function()
        local b = findModelByKeywords({ "boss" }, 2000)
        if #b == 0 then Notify("视野内没有 Boss 模型") return end
        local lines = {}
        for i = 1, math.min(#b, 5) do
            lines[#lines + 1] = string.format("%s (%.0fm)", b[i].model.Name, b[i].dist)
        end
        Notify(table.concat(lines, "\n"))
    end)
    button("打一次 StartBossFight", function()
        local ok = fire("StartBossFight")
        Notify(ok and "已发送" or "StartBossFight 不存在")
    end)

    section("说明")
    labelRow("Boss 战需要二阶段确认时会自动点 Yes/Prepare。\n"
          .. "AutoBossFishing 只是标记，实际由「钓鱼」页的自动抛竿执行。")
end

-- ---------- 技能 ----------
T.skill.build = function()
    section("技能")
    toggle("自动用技能", "AutoSkill")
    slider("轮换间隔 (秒)", "SkillInterval", 0.5, 10, 0.5, function(v) return string.format("%.1fs", v) end)
    labelRow("轮换的技能（从原脚本恢复的真实名字）：")
    for _, n in ipairs(SKILL_KEYS) do
        labelRow("   · " .. n)
    end
    section("手动")
    for i = 1, math.min(#SKILL_KEYS, 6) do
        local nm = SKILL_KEYS[i]
        button("放一次 " .. nm, function()
            local ok = fire("BuySkill", nm)
            Notify(ok and ("已发送 " .. nm) or "BuySkill 调用失败")
        end)
    end
end

-- ---------- 日常 ----------
T.daily.build = function()
    section("日常")
    toggle("自动领每日奖励", "AutoClaimDaily")
    slider("领取间隔 (秒)", "ClaimDailyDelay", 10, 600, 10, function(v) return string.format("%d s", v) end)
    toggle("自动试兑换码", "AutoRedeemCodes")
    labelRow("注意：兑换码是从旧版脚本里扒出来的，多半已过期。\n开着只是碰运气，不影响别的功能。")

    section("手动")
    button("领一次每日奖励", function()
        local ok = fire("DailyReward")
        Notify(ok and "已发送" or "DailyReward 调用失败")
    end)
end

-- ---------- 移动 ----------
T.move.build = function()
    section("传送")
    cycle("目标岛屿", "TargetIsland", ISLANDS)
    toggle("传送到目标岛屿", "IslandTeleport")

    section("移动辅助")
    toggle("水上行走", "WalkOnWater")
    slider("飞行速度 (0 = 关)", "FlySpeed", 0, 120, 1, function(v)
        return (v == 0) and "关闭" or string.format("%d", v)
    end)
    labelRow("飞行：WASD 平移，空格上升，左Ctrl 下降。\n"
          .. "水上行走：在脚下放一块只有你看得见的实心板。")

    section("会话")
    toggle("自动重连（点重连按钮）", "AutoRejoin")
    toggle("防踢（防 AFK）", "AntiAFK")
end

-- ---------- 跳服 ----------
T.hop.build = function()
    section("目标服务器跳转")
    toggle("找 God Spirit 服", "ServerHopGod")
    toggle("找 Maoshan 服", "ServerHopMaoshan")
    toggle("找 Taoist 服", "ServerHopTaoist")
    labelRow("开着就会每 20 秒检查本服有没有目标 NPC，没有就跳下一个服务器。")
    section("手动")
    button("立刻跳一个服务器", function()
        hopServer()
    end)
    button("看服务器列表（调试页）", function()
        local list = fetchServers(nil)
        if not list then Notify("获取失败") return end
        for i, s in ipairs(list) do
            if i > 15 then break end
            log("服务器 %s  %d/%d", tostring(s.id), s.playing or 0, s.maxPlayers or 0)
        end
        Notify(string.format("共 %d 个服务器，详见调试页", #list))
    end)
end

-- ---------- ESP ----------
T.esp.build = function()
    section("高亮")
    toggle("Boss（红）", "ESPBoss")
    toggle("NPC（青）", "ESPNPC")
    toggle("Secret Rod（红）", "ESPSecretRod")
    toggle("God Spirit（金）", "ESPGodSpirit")
    toggle("Maoshan（紫）", "ESPMaoshan")
    toggle("Taoist（橙）", "ESPTaoist")
    section("操作")
    button("清除所有高亮", function()
        clearESP()
        Notify("已清除")
    end)
    button("扫描当前所有模型（调试页）", function()
        local n = 0
        for _, m in ipairs(workspace:GetDescendants()) do
            if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
                n = n + 1
                if n <= 40 then log("模型: %s", m.Name) end
            end
        end
        Notify(string.format("共 %d 个带 Humanoid 的模型", n))
    end)
end

-- ---------- 信息 ----------
T.info.build = function()
    section("实时数据")
    InfoLabel = labelRow("读取中…", FG)
    if InfoLabel then
        InfoLabel.TextSize = 14
        InfoLabel.Size = UDim2.new(1, -20, 0, 46)
        InfoLabel.TextYAlignment = Enum.TextYAlignment.Top
    end
    toggle("显示信息面板", "ShowInfo")
    button("立即刷新", function()
        refreshStats()
        Notify(string.format("Cash=%s Level=%s Crystal=%s Ticket=%s",
            tostring(Stats.cash), tostring(Stats.level),
            tostring(Stats.crystal), tostring(Stats.ticket)))
    end)
    section("数据源探测")
    labelRow("如果上面全是「?」，说明数据结构跟预期不同，点下面的按钮看实际路径：")
    button("列出 ReplicatedStorage 顶层结构", function()
        for _, ch in ipairs(ReplicatedStorage:GetChildren()) do
            log("RS: %s (%s)", ch.Name, ch.ClassName)
        end
        if Handles.Events then
            for _, ch in ipairs(Handles.Events:GetChildren()) do
                log("Events: %s (%s)", ch.Name, ch.ClassName)
            end
        else
            log("没找到 Events 目录")
        end
        Notify("详见调试页")
    end)
end

-- ---------- 调试 ----------
T.debug.build = function()
    section("Remote 状态")
    labelRow(string.format("成功 %d 次 / 失败 %d 次", callStats.ok, callStats.fail))
    labelRow("最后错误: " .. tostring(callStats.lastError or "无"))
    labelRow(string.format("抛竿 %d 次 / 收线 %d 次", Fishing.casts, Fishing.catches))

    section("已找到的 Remote")
    button("扫描所有 Remote 名字", function()
        clearRemoteCache()
        local found, missing = 0, 0
        for _, nm in ipairs(KNOWN_REMOTES) do
            local r = findRemote(nm)
            if r then
                found = found + 1
                log("✔ %s  (%s)", nm, r.ClassName)
            else
                missing = missing + 1
                log("✘ %s  不存在", nm)
            end
        end
        Notify(string.format("找到 %d 个，缺失 %d 个", found, missing))
    end)
    button("列出所有可能是 Remote 的对象", function()
        local n = 0
        for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                n = n + 1
                if n <= 120 then log("REMOTE: %s (%s)", d:GetFullName(), d.ClassName) end
            end
        end
        Notify(string.format("共 %d 个 Remote", n))
    end)

    section("执行器能力")
    labelRow("getconnections: " .. tostring(Cap.getconnections))
    labelRow("fireproximityprompt: " .. tostring(Cap.fireproximityprompt))
    labelRow("fireclickdetector: " .. tostring(Cap.fireclickdetector))
    labelRow("writefile: " .. tostring(Cap.writefile))

    section("最近日志")
    local logBox = baseRow(8)
    if logBox then
        logBox.Size = UDim2.new(1, 0, 0, 160)
        local sc = Instance.new("ScrollingFrame")
        sc.BackgroundTransparency = 1
        sc.Size = UDim2.new(1, -12, 1, -12)
        sc.Position = UDim2.new(0, 6, 0, 6)
        sc.CanvasSize = UDim2.new(0, 0, 0, 0)
        sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
        sc.ScrollBarThickness = 3
        sc.Parent = logBox
        local ll = Instance.new("UIListLayout")
        ll.Padding = UDim.new(0, 2)
        ll.Parent = sc
        for i = #LOGS, 1, -1 do
            local lb = Instance.new("TextLabel")
            lb.BackgroundTransparency = 1
            lb.Size = UDim2.new(1, 0, 0, 0)
            lb.AutomaticSize = Enum.AutomaticSize.Y
            lb.Font = Enum.Font.Code
            lb.TextSize = 11
            lb.TextColor3 = FG_DIM
            lb.TextXAlignment = Enum.TextXAlignment.Left
            lb.TextWrapped = true
            lb.Text = LOGS[i]
            lb.Parent = sc
        end
    end
    button("刷新日志", function() showTab(T.debug) end)
end

-- ---------- 设置 ----------
T.config.build = function()
    section("外观")
    cycle("主题颜色", "ThemeColor", { "紫", "青", "绿", "红", "金" })
    labelRow("换主题后重开窗口生效。")

    section("配置")
    button("保存配置到本地", function()
        Notify(saveConfig() and "已保存" or "保存失败（执行器不支持 writefile）")
    end)
    button("从本地加载配置", function()
        local ok = loadConfig()
        Notify(ok and "已加载，正在刷新界面" or "加载失败")
        if ok and UI.activeTab then showTab(UI.activeTab) end
    end)
    button("全部关闭（只关功能，不卸载）", function()
        for k, v in pairs(Config) do
            if type(v) == "boolean" and k ~= "AntiAFK" and k ~= "ShowInfo" then
                Config[k] = false
            end
        end
        clearESP()
        Notify("所有功能已关闭")
        if UI.activeTab then showTab(UI.activeTab) end
    end)

    section("危险操作")
    button("卸载脚本", function() unload() end, true)
    labelRow("卸载会移除界面、清理高亮和本地生成的水面板。")
end

--==============================================================
-- 33. 卸载
--==============================================================
function unload()
    RUNNING = false
    pcall(clearESP)
    for _, c in ipairs(UIS_CONNS) do pcall(function() c:Disconnect() end) end
    -- 清理水上平台
    pcall(function()
        local c = char()
        if c then
            local p = c:FindFirstChild("NNVN_WaterPlate")
            if p then p:Destroy() end
        end
    end)
    pcall(function() if ScreenGui then ScreenGui:Destroy() end end)
    log("脚本已卸载")
end

if UI_REFS.close then
    UI_REFS.close.MouseButton1Click:Connect(function() unload() end)
end

--==============================================================
-- 34. 启动
--==============================================================
if #UI.tabs > 0 then
    for _, t in ipairs(UI.tabs) do
        t.btn.MouseButton1Click:Connect(function() showTab(t) end)
    end
    showTab(T.fishing)
end

-- 功能内部会改 Config（例如传送完成后自动关闭开关），这里把界面同步回来
addLoop("UISync", 0.4, function() return #UI.controls > 0 end, function()
    for _, r in ipairs(UI.controls) do pcall(r) end
end)

startScheduler()

task.spawn(function()
    task.wait(1)
    Notify("NNVN 重写版已加载 ✓")
    refreshStats()
    -- 启动自检
    local missing = {}
    for _, nm in ipairs({ "SellFish", "BuyBait", "EquipBait", "BuySkill" }) do
        if not findRemote(nm) then missing[#missing + 1] = nm end
    end
    if #missing > 0 then
        task.wait(0.5)
        Notify("这几个 Remote 没找到，相关功能可能不生效：\n" .. table.concat(missing, ", ")
            .. "\n（去「调试」页点扫描确认）")
    end
end)

log("加载完成 | Remote 目录: %s | 事件根: %s",
    Handles.Events and "已找到" or "未找到",
    Handles.Events and Handles.Events:GetFullName() or "—")
