--[[
================================================================================
  Remote Spy Lite (RSL) v1.0  —— 独立抓包/协议探针
  用途：抓「客户端 → 服务端」的上行协议（rspy 默认只看服务端→客户端那半边）。
  性质：纯只读。本脚本**不会**发送任何 Remote、不改任何参数。
  依赖：无。独立运行，不需要主脚本；可与主脚本同时注入，两者互不干扰。
--------------------------------------------------------------------------------
  用法一（有界面）：
      注入后自动弹出一个小窗口，点「开始记录」→ 手动打一场 Boss → 点「复制」。
  用法二（没界面 / 更省事）：
      getgenv().RSLite.start()
      getgenv().RSLite.dump()      -- 返回文本并自动复制到剪贴板
      getgenv().RSLite.stop()
--------------------------------------------------------------------------------
  输出格式：
      12.345  OUT  Slam.FireServer(n=1)        string:"Perfect"
      12.480  IN   Slam.OnClientEvent(n=1)     string:"Perfect"
      OUT = 客户端发的（带 [GAME] 的才是游戏自己的代码发的，[SELF] 是执行器脚本发的）
      IN  = 服务端发来的
================================================================================
]]

-- ============================ 配置 ============================
local CFG = {
    logOutgoing = true,   -- 记录客户端 -> 服务端
    logIncoming = true,   -- 记录服务端 -> 客户端（需要 getconnections + hookfunction）
    tagSelf     = true,   -- 出向包标注是 [GAME] 还是 [SELF]
    maxLines    = 600,    -- 环形缓冲上限
    uiLines     = 60,     -- 界面里最多显示多少行
    dedupMs     = 5,      -- 同一秒内完全相同的包只记一条
    watchFolder = "Events", -- 重点监视 ReplicatedStorage 下这个文件夹（空字符串=全 ReplicatedStorage）
}

-- ============================ 环境 ============================
local g = (type(getgenv) == "function" and getgenv()) or _G
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")

local HAS_CHECKCALLER = (type(checkcaller) == "function")
local HAS_HOOK = (type(hookmetamethod) == "function" and type(newcclosure) == "function"
                  and type(getnamecallmethod) == "function")
local HAS_CONN = (type(getconnections) == "function" and type(hookfunction) == "function")

local function nowT()
    if type(tick) == "function" then return tick() end
    return os.clock()
end

-- ============================ 缓冲 ============================
local BUF = { rec = {}, head = 0, n = 0, lastKey = "", lastAt = 0, text = "" }
local DIRTY = false   -- 有新行待刷新到界面

local function safeName(inst)
    if typeof(inst) ~= "Instance" then return tostring(inst) end
    local ok, n = pcall(function() return inst.Name end)
    if ok and type(n) == "string" then return n end
    return "?"
end

-- 把一个参数转成「类型:值」的短文本
local function fmtArg(v)
    local t = typeof(v)
    local s
    if t == "string" then
        s = v
        if #s > 64 then s = s:sub(1, 64) .. "…" end
        s = string.format("%q", s)
    elseif t == "number" then
        s = string.format("%.3f", v)
    elseif t == "boolean" then
        s = tostring(v)
    elseif t == "nil" then
        s = "nil"
    elseif t == "Vector3" then
        s = string.format("V3(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
    elseif t == "Vector2" then
        s = string.format("V2(%.1f,%.1f)", v.X, v.Y)
    elseif t == "CFrame" then
        local p = v.Position
        if p then s = string.format("CF(%.1f,%.1f,%.1f)", p.X, p.Y, p.Z) else s = "CF" end
    elseif t == "Color3" then
        s = string.format("C3(%.2f,%.2f,%.2f)", v.R, v.G, v.B)
    elseif t == "Instance" then
        s = "Inst<" .. safeName(v) .. ">"
    elseif t == "table" then
        local keys, kc = {}, 0
        pcall(function()
            for k in pairs(v) do
                kc = kc + 1
                if kc > 8 then break end
                keys[kc] = tostring(k)
            end
        end)
        s = "{" .. table.concat(keys, ",") .. (kc >= 8 and ",…" or "") .. "}"
    else
        s = tostring(t)
    end
    if #s > 110 then s = s:sub(1, 110) .. "…" end
    return t .. ":" .. s
end

-- 核心：记一条
local function record(dir, inst, method, ...)
    if dir == "OUT" and not CFG.logOutgoing then return end
    if dir == "IN" and not CFG.logIncoming then return end
    local nm = safeName(inst)
    local total = select("#", ...)
    local cnt = total
    if cnt > 8 then cnt = 8 end
    local parts = {}
    for i = 1, cnt do parts[i] = fmtArg((select(i, ...))) end
    local now = nowT()
    local key = dir .. "|" .. nm .. "|" .. tostring(method) .. "|" .. table.concat(parts, ",")
    if key == BUF.lastKey and (now - BUF.lastAt) * 1000 < CFG.dedupMs then return end
    BUF.lastKey, BUF.lastAt = key, now

    local tag = ""
    if dir == "OUT" and CFG.tagSelf and HAS_CHECKCALLER then
        tag = checkcaller() and "[SELF] " or "[GAME] "
    end

    BUF.n = BUF.n + 1
    BUF.head = BUF.head + 1
    if BUF.head > CFG.maxLines then BUF.head = 1 end
    BUF.rec[BUF.head] = string.format("%8.3f  %s  %s%s.%s(n=%d)  %s",
        now, dir, tag, nm, tostring(method), total, table.concat(parts, ", "))
    DIRTY = true
end

-- 按时间顺序取出缓冲里的行
local function snapshot()
    local out = {}
    local stored = BUF.n
    if stored > CFG.maxLines then stored = CFG.maxLines end
    for i = 1, stored do
        local idx = BUF.head - stored + i
        while idx < 1 do idx = idx + CFG.maxLines end
        local v = BUF.rec[idx]
        if v then out[#out + 1] = v end
    end
    return out
end

local function dumpText()
    return table.concat(snapshot(), "\n")
end

local function copyToClipboard()
    local text = dumpText()
    if #text == 0 then return 0 end
    if type(setclipboard) == "function" then pcall(setclipboard, text) end
    if type(writefile) == "function" then pcall(writefile, "RSLite_dump.txt", text) end
    return BUF.n
end

-- ============================ 出向钩子 ============================
local outHooked = false
local function installOutgoing()
    if outHooked or not HAS_HOOK then return outHooked end
    local ok = pcall(function()
        local orig
        orig = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local m = getnamecallmethod()
            if m == "FireServer" or m == "InvokeServer" then
                pcall(record, "OUT", self, m, ...)
            end
            return orig(self, ...)
        end))
    end)
    outHooked = ok
    return ok
end

-- ============================ 入向钩子 ============================
local inHooked = {}
local function scanIncoming()
    if not CFG.logIncoming or not HAS_CONN then return 0 end
    local rs = game:GetService("ReplicatedStorage")
    local root = rs
    if CFG.watchFolder ~= "" then
        local f = rs:FindFirstChild(CFG.watchFolder)
        if f then root = f end
    end
    local n = 0
    for _, rem in ipairs(root:GetDescendants()) do
        if rem:IsA("RemoteEvent") or rem:IsA("UnreliableRemoteEvent") then
            pcall(function()
                for _, c in ipairs(getconnections(rem.OnClientEvent)) do
                    local f = c.Fire
                    if type(f) == "function" and not inHooked[f] then
                        inHooked[f] = true
                        local okHook = pcall(function()
                            hookfunction(f, newcclosure(function(...)
                                pcall(record, "IN", rem, "OnClientEvent", ...)
                                return f(...)
                            end))
                        end)
                        if okHook then n = n + 1 end
                    end
                end
            end)
        end
    end
    return n
end

-- ============================ 界面（加载期一次性构建） ============================
local UI = { lines = {}, frame = nil, textLabel = nil, statusLabel = nil, buttons = {} }

local function buildUI()
    local parent
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then parent = core end
    if not parent then
        local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
        parent = pg
    end
    if not parent then return false end

    local gui = Instance.new("ScreenGui")
    gui.Name = "RSLiteGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999999
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 380, 0, 300)
    frame.Position = UDim2.new(0.5, -190, 0.5, -150)
    frame.BackgroundColor3 = Color3.fromRGB(24, 28, 26)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -12, 0, 24)
    title.Position = UDim2.new(0, 8, 0, 4)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(140, 230, 180)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Remote Spy Lite  ·  只读，不发包"
    title.Parent = frame

    -- 按钮行
    local btnDefs = {
        { id = "start",  text = "开始记录", w = 78 },
        { id = "stop",   text = "停止",     w = 54 },
        { id = "copy",   text = "复制",     w = 54 },
        { id = "clear",  text = "清空",     w = 54 },
    }
    local bx = 8
    for _, d in ipairs(btnDefs) do
        local b = Instance.new("TextButton")
        b.Name = d.id
        b.Size = UDim2.new(0, d.w, 0, 24)
        b.Position = UDim2.new(0, bx, 0, 32)
        b.BackgroundColor3 = Color3.fromRGB(46, 60, 54)
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(220, 240, 230)
        b.Text = d.text
        b.AutoButtonColor = true
        b.Parent = frame
        bx = bx + d.w + 6
        UI.buttons[d.id] = b
    end

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -12, 0, 16)
    status.Position = UDim2.new(0, 8, 0, 60)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 11
    status.TextColor3 = Color3.fromRGB(170, 200, 185)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = string.format("待开始 · 出向钩子:%s · 入向钩子:%s",
        HAS_HOOK and "可用" or "不可用",
        HAS_CONN and "可用" or "不可用(仅记录出向)")
    status.Parent = frame

    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "Log"
    scroll.Size = UDim2.new(1, -16, 1, -88)
    scroll.Position = UDim2.new(0, 8, 0, 80)
    scroll.BackgroundColor3 = Color3.fromRGB(14, 17, 16)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = frame

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 4)
    pad.PaddingTop = UDim.new(0, 4)
    pad.Parent = scroll

    local lbl = Instance.new("TextLabel")
    lbl.Name = "Body"
    lbl.Size = UDim2.new(1, -8, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextYAlignment = Enum.TextYAlignment.Top
    lbl.TextColor3 = Color3.fromRGB(200, 230, 210)
    lbl.Text = ""
    lbl.Parent = scroll

    UI.frame = frame
    UI.scroll = scroll
    UI.textLabel = lbl
    UI.statusLabel = status
    return true
end

local function refreshUI()
    if not UI.textLabel then return end
    local all = snapshot()
    local start = #all - CFG.uiLines + 1
    if start < 1 then start = 1 end
    local shown = {}
    for i = start, #all do shown[#shown + 1] = all[i] end
    UI.textLabel.Text = table.concat(shown, "\n")
    if UI.statusLabel then
        UI.statusLabel.Text = string.format("记录 %d 条  ·  出向%s  入向%s", BUF.n,
            CFG.logOutgoing and "开" or "关", CFG.logIncoming and "开" or "关")
    end
end

-- ============================ 启停 ============================
local RUNNING = false
local hookedOnce = false

local function startLogging()
    RUNNING = true
    if not hookedOnce then
        installOutgoing()
        scanIncoming()
        hookedOnce = true
    else
        installOutgoing()
        scanIncoming()
    end
    if UI.statusLabel then UI.statusLabel.Text = "记录中…（去手动打一场 Boss）" end
    return true
end

local function stopLogging()
    RUNNING = false
    if UI.statusLabel then UI.statusLabel.Text = "已停止 · 共 " .. BUF.n .. " 条" end
    return BUF.n
end

local function clearBuf()
    BUF.rec, BUF.head, BUF.n, BUF.lastKey, BUF.lastAt = {}, 0, 0, "", 0
    DIRTY = true
    if UI.statusLabel then UI.statusLabel.Text = "已清空" end
end

-- ============================ 心跳：刷新界面 + 补挂新连接 ============================
pcall(function()
    RunService.Heartbeat:Connect(function()
        if DIRTY and UI.textLabel then
            DIRTY = false
            pcall(refreshUI)
        end
    end)
end)

pcall(function()
    task.spawn(function()
        while true do
            task.wait(2)
            if RUNNING then pcall(scanIncoming) end
        end
    end)
end)

-- ============================ 界面事件 ============================
local okUI = false
pcall(function() okUI = buildUI() end)

if UI.buttons.start then
    UI.buttons.start.MouseButton1Click:Connect(function()
        startLogging()
        DIRTY = true
    end)
end
if UI.buttons.stop then
    UI.buttons.stop.MouseButton1Click:Connect(function()
        stopLogging()
        DIRTY = true
    end)
end
if UI.buttons.copy then
    UI.buttons.copy.MouseButton1Click:Connect(function()
        local n = copyToClipboard()
        if UI.statusLabel then
            UI.statusLabel.Text = n > 0 and ("已复制 " .. n .. " 条到剪贴板") or "还没有记录"
        end
        if n > 0 then pcall(print, "[RSL] 已复制 " .. n .. " 条：\n" .. dumpText()) end
    end)
end
if UI.buttons.clear then
    UI.buttons.clear.MouseButton1Click:Connect(function()
        clearBuf()
        DIRTY = true
    end)
end

-- ============================ 外部 API ============================
g.RSLite = {
    start = function() return startLogging() end,
    stop = function() return stopLogging() end,
    dump = function()
        local t = dumpText()
        if #t > 0 and type(setclipboard) == "function" then pcall(setclipboard, t) end
        return t
    end,
    copy = function() return copyToClipboard() end,
    clear = function() return clearBuf() end,
    count = function() return BUF.n end,
    status = function()
        return string.format("[RSL] 运行=%s 记录=%d 出向钩子=%s 入向钩子=%d 界面=%s",
            tostring(RUNNING), BUF.n, tostring(outHooked), (function()
                local c = 0
                for _ in pairs(inHooked) do c = c + 1 end
                return c
            end)(), tostring(okUI))
    end,
    setOption = function(k, v) if CFG[k] ~= nil then CFG[k] = v end return CFG[k] end,
    _record = record,   -- 自测用
}

-- 启动时自动开始，省一步操作（不想自动就改成 false）
if not okUI then startLogging() end

pcall(print, "[RSL] Remote Spy Lite 已加载。" .. (okUI and "窗口已弹出，点「开始记录」。" or "界面不可用，请用 getgenv().RSLite.start()。"))
