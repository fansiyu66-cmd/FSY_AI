--[[
================================================================================
  Remote Spy Lite (RSL) v1.1  —— 独立抓包/协议探针
  用途：抓「客户端 → 服务端」的上行协议（rspy 默认只看服务端→客户端那半边）。
  性质：纯只读。本脚本**不会**发送任何 Remote、不改任何参数、不改游戏状态。
  依赖：无。独立运行，不需要主脚本；可与主脚本同时注入。
--------------------------------------------------------------------------------
  v1.1 改动：
    1. 窗口可折叠：点标题栏右侧「－」缩成一条横条，再点「＋」展开；
    2. 新增「保存」按钮：写入执行器 workspace 目录，并在状态栏显示完整路径；
    3. 点「×」= 停止记录 + 整个悬浮窗直接销毁（不是隐藏，是删掉）；
       之后想再开：执行 getgenv().RSLite.show()
--------------------------------------------------------------------------------
  用法（有界面）：
      注入 → 小窗弹出 → 点「开始记录」→ 手动打一场 Boss → 点「保存」或「复制」
  用法（没界面 / 全控制台）：
      getgenv().RSLite.start()
      getgenv().RSLite.dump()      -- 返回文本并复制到剪贴板
      getgenv().RSLite.save()      -- 存文件，返回路径
      getgenv().RSLite.close()     -- 停记录 + 销毁窗口
--------------------------------------------------------------------------------
  输出格式：
      12.345  OUT  [GAME] Slam.FireServer(n=1)   string:"Perfect"
      12.480  IN   Slam.OnClientEvent(n=1)       string:"Perfect"
      OUT = 客户端发的（[GAME]=游戏自己的代码，[SELF]=执行器脚本）
      IN  = 服务端发来的
================================================================================
]]

-- ============================ 配置 ============================
local CFG = {
    logOutgoing = true,      -- 记录客户端 -> 服务端
    logIncoming = true,      -- 记录服务端 -> 客户端（需 getconnections + hookfunction）
    tagSelf     = true,      -- 出向包标注 [GAME] / [SELF]
    maxLines    = 600,       -- 环形缓冲上限
    uiLines     = 60,        -- 界面最多显示多少行
    dedupMs     = 5,         -- 连续完全相同的包多少毫秒内只记一条
    watchFolder = "Events",  -- 重点监视 ReplicatedStorage 下这个文件夹（"" = 整个 ReplicatedStorage）
    saveFolder  = "RSLite",  -- 保存到 workspace 下的子文件夹名（无 makefolder 时退回根目录）
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
local HAS_WRITE = (type(writefile) == "function")

local function nowT()
    if type(tick) == "function" then return tick() end
    return os.clock()
end

-- ============================ 缓冲 ============================
local BUF = { rec = {}, head = 0, n = 0, lastKey = "", lastAt = 0 }
local DIRTY = false

local function safeName(inst)
    if typeof(inst) ~= "Instance" then return tostring(inst) end
    local ok, n = pcall(function() return inst.Name end)
    if ok and type(n) == "string" then return n end
    return "?"
end

local function fmtArg(v)
    local t = typeof(v)
    local s
    if t == "string" then
        s = v
        if #s > 64 then s = s:sub(1, 64) .. "…" end
        s = string.format("%q", s)
    elseif t == "number" then s = string.format("%.3f", v)
    elseif t == "boolean" then s = tostring(v)
    elseif t == "nil" then s = "nil"
    elseif t == "Vector3" then s = string.format("V3(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
    elseif t == "Vector2" then s = string.format("V2(%.1f,%.1f)", v.X, v.Y)
    elseif t == "CFrame" then
        local p = v.Position
        if p then s = string.format("CF(%.1f,%.1f,%.1f)", p.X, p.Y, p.Z) else s = "CF" end
    elseif t == "Color3" then s = string.format("C3(%.2f,%.2f,%.2f)", v.R, v.G, v.B)
    elseif t == "Instance" then s = "Inst<" .. safeName(v) .. ">"
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

-- ============================ 保存到系统文件 ============================
-- 不同执行器的 workspace 路径不一样，这里按可用性依次尝试，拿不到就退回相对路径。
local function getWorkspaceDir()
    if type(getworkspace) == "function" then
        local ok, p = pcall(getworkspace)
        if ok and type(p) == "string" and p ~= "" then return p end
    end
    if type(getworkspacepath) == "function" then
        local ok, p = pcall(getworkspacepath)
        if ok and type(p) == "string" and p ~= "" then return p end
    end
    if type(getexecutorpath) == "function" then
        local ok, p = pcall(getexecutorpath)
        if ok and type(p) == "string" and p ~= "" then return p end
    end
    return nil
end

local function makeStamp()
    local ok, s = pcall(function() return os.date("%Y%m%d_%H%M%S") end)
    if ok and type(s) == "string" then return s end
    return tostring(math.floor(nowT()))
end

-- 返回 (显示用路径, 错误信息)
local function saveToFile()
    if not HAS_WRITE then return nil, "执行器不支持 writefile" end
    local text = dumpText()
    if #text == 0 then return nil, "还没有记录" end
    local base = getWorkspaceDir()
    local stamp = makeStamp()
    local fname = "RSLite_dump_" .. stamp .. ".txt"
    local tried = {}

    local function attempt(dir)
        local path
        if dir then
            -- 优先建子目录（执行器支持 makefolder 时）
            if type(makefolder) == "function" then
                pcall(makefolder, dir)
                pcall(makefolder, dir .. "/" .. CFG.saveFolder)
            end
            path = dir .. "/" .. CFG.saveFolder .. "/" .. fname
        else
            path = fname
        end
        table.insert(tried, path)
        local ok = pcall(writefile, path, text)
        if not ok and dir then
            -- 子目录写不进去就退回根目录
            path = dir .. "/" .. fname
            table.insert(tried, path)
            ok = pcall(writefile, path, text)
        end
        return ok, path
    end

    local ok, path = attempt(base)
    if not ok then
        ok, path = attempt(nil)   -- 有些执行器只接受相对文件名
    end
    if not ok then
        return nil, "写入失败，试过：" .. table.concat(tried, " | ")
    end
    local shown = path
    if not base then shown = path .. "（执行器 workspace 目录内）" end
    return shown
end

local function copyToClipboard()
    local text = dumpText()
    if #text == 0 then return 0 end
    if type(setclipboard) == "function" then pcall(setclipboard, text) end
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

-- ============================ 界面 ============================
local UI = { gui = nil, frame = nil, body = nil, scroll = nil, log = nil, status = nil, collapseBtn = nil, collapsed = false, buttons = {}, bound = false }

local C_BG      = Color3.fromRGB(24, 28, 26)
local C_BTN     = Color3.fromRGB(46, 60, 54)
local C_BTN2    = Color3.fromRGB(58, 46, 46)
local C_TEXT    = Color3.fromRGB(220, 240, 230)
local C_ACCENT  = Color3.fromRGB(140, 230, 180)
local C_SUB     = Color3.fromRGB(170, 200, 185)

local W_EXPANDED = UDim2.new(0, 340, 0, 290)
local W_COLLAPSED = UDim2.new(0, 340, 0, 30)

local function applyCollapsed(v)
    UI.collapsed = v and true or false
    if not UI.frame then return end
    if UI.collapsed then
        UI.frame.Size = W_COLLAPSED
        if UI.body then UI.body.Visible = false end
        if UI.collapseBtn then UI.collapseBtn.Text = "＋" end
    else
        UI.frame.Size = W_EXPANDED
        if UI.body then UI.body.Visible = true end
        if UI.collapseBtn then UI.collapseBtn.Text = "－" end
    end
end

local function setStatus(txt)
    if UI.status then UI.status.Text = tostring(txt) end
end

local function refreshUI()
    if not UI.log then return end
    local all = snapshot()
    local start = #all - CFG.uiLines + 1
    if start < 1 then start = 1 end
    local shown = {}
    for i = start, #all do shown[#shown + 1] = all[i] end
    UI.log.Text = table.concat(shown, "\n")
    if UI.status then
        UI.status.Text = string.format("记录 %d 条 · 出向%s · 入向%s",
            BUF.n, CFG.logOutgoing and "开" or "关", CFG.logIncoming and "开" or "关")
    end
end

local function destroyUI()
    if UI.gui then pcall(function() UI.gui:Destroy() end) end
    UI.gui, UI.frame, UI.body, UI.scroll, UI.log, UI.status, UI.collapseBtn = nil, nil, nil, nil, nil, nil, nil
    UI.buttons = {}
    UI.bound = false
    return true
end

local function buildUI()
    if UI.gui and UI.gui.Parent then return true end

    local parent
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then parent = core end
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
    frame.Size = W_EXPANDED
    frame.Position = UDim2.new(0.5, -170, 0.5, -145)
    frame.BackgroundColor3 = C_BG
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.ClipsDescendants = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    -- 标题栏（折叠后只剩这一条）
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -76, 0, 30)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = C_ACCENT
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Remote Spy Lite · 只读"
    title.Parent = frame

    local collapseBtn = Instance.new("TextButton")
    collapseBtn.Name = "Collapse"
    collapseBtn.Size = UDim2.new(0, 28, 0, 22)
    collapseBtn.Position = UDim2.new(1, -64, 0, 4)
    collapseBtn.BackgroundColor3 = C_BTN
    collapseBtn.BorderSizePixel = 0
    collapseBtn.Font = Enum.Font.GothamBold
    collapseBtn.TextSize = 15
    collapseBtn.TextColor3 = C_TEXT
    collapseBtn.Text = "－"
    collapseBtn.Parent = frame

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "Close"
    closeBtn.Size = UDim2.new(0, 28, 0, 22)
    closeBtn.Position = UDim2.new(1, -32, 0, 4)
    closeBtn.BackgroundColor3 = C_BTN2
    closeBtn.BorderSizePixel = 0
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 14
    closeBtn.TextColor3 = Color3.fromRGB(255, 190, 190)
    closeBtn.Text = "×"
    closeBtn.Parent = frame

    -- 主体（折叠时整块隐藏）
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 1, -30)
    body.Position = UDim2.new(0, 0, 0, 30)
    body.BackgroundTransparency = 1
    body.Parent = frame

    local btnDefs = {
        { id = "start", text = "开始", w = 64 },
        { id = "stop",  text = "停止", w = 48 },
        { id = "copy",  text = "复制", w = 48 },
        { id = "save",  text = "保存", w = 48 },
        { id = "clear", text = "清空", w = 48 },
    }
    local bx = 8
    for _, d in ipairs(btnDefs) do
        local b = Instance.new("TextButton")
        b.Name = d.id
        b.Size = UDim2.new(0, d.w, 0, 24)
        b.Position = UDim2.new(0, bx, 0, 4)
        b.BackgroundColor3 = C_BTN
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = C_TEXT
        b.Text = d.text
        b.AutoButtonColor = true
        b.Parent = body
        bx = bx + d.w + 5
        UI.buttons[d.id] = b
    end

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.Size = UDim2.new(1, -16, 0, 30)
    status.Position = UDim2.new(0, 8, 0, 30)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 10
    status.TextColor3 = C_SUB
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextYAlignment = Enum.TextYAlignment.Top
    status.TextWrapped = true
    status.Text = string.format("待开始 · 出向钩子:%s · 入向钩子:%s · 存盘:%s",
        HAS_HOOK and "可用" or "不可用",
        HAS_CONN and "可用" or "不可用",
        HAS_WRITE and "可用" or "不可用")
    status.Parent = body

    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "Log"
    scroll.Size = UDim2.new(1, -16, 1, -66)
    scroll.Position = UDim2.new(0, 8, 0, 62)
    scroll.BackgroundColor3 = Color3.fromRGB(14, 17, 16)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = body

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
    lbl.TextColor3 = C_TEXT
    lbl.Text = ""
    lbl.Parent = scroll

    UI.gui = gui
    UI.frame = frame
    UI.body = body
    UI.scroll = scroll
    UI.log = lbl
    UI.status = status
    UI.collapseBtn = collapseBtn

    collapseBtn.MouseButton1Click:Connect(function()
        applyCollapsed(not UI.collapsed)
    end)
    closeBtn.MouseButton1Click:Connect(function()
        g.RSLite.close()   -- 停记录 + 整个窗口删掉
    end)

    return true
end

-- ============================ 启停 / 动作 ============================
local RUNNING = false
local hookedOnce = false

local function startLogging()
    RUNNING = true
    installOutgoing()
    if not hookedOnce then hookedOnce = true end
    scanIncoming()
    setStatus("记录中…（去手动打一场 Boss）")
    return true
end

local function stopLogging()
    RUNNING = false
    setStatus("已停止 · 共 " .. BUF.n .. " 条")
    return BUF.n
end

local function clearBuf()
    BUF.rec, BUF.head, BUF.n, BUF.lastKey, BUF.lastAt = {}, 0, 0, "", 0
    DIRTY = true
    setStatus("已清空")
end

-- ============================ 心跳 ============================
pcall(function()
    RunService.Heartbeat:Connect(function()
        if DIRTY and UI.log then
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

-- ============================ 按钮绑定 ============================
local function bindButtons()
    if UI.bound then return end          -- 防止 show() 重复调用时给同一批按钮叠加多份回调
    UI.bound = true
    local function on(id, fn)
        local b = UI.buttons[id]
        if b then b.MouseButton1Click:Connect(function() pcall(fn) end) end
    end
    on("start", function()
        startLogging(); DIRTY = true
    end)
    on("stop", function()
        stopLogging(); DIRTY = true
    end)
    on("copy", function()
        local n = copyToClipboard()
        setStatus(n > 0 and ("已复制 " .. n .. " 条到剪贴板") or "还没有记录")
        if n > 0 then pcall(print, "[RSL] 已复制 " .. n .. " 条") end
    end)
    on("save", function()
        local path, err = saveToFile()
        if path then
            setStatus("已保存 " .. BUF.n .. " 条 → " .. path)
            pcall(print, "[RSL] 已保存 → " .. path)
        else
            setStatus("保存失败：" .. tostring(err))
            pcall(print, "[RSL] 保存失败：" .. tostring(err))
        end
    end)
    on("clear", function()
        clearBuf(); DIRTY = true
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
    save = function() return saveToFile() end,
    clear = function() return clearBuf() end,
    count = function() return BUF.n end,
    show = function()
        local ok = buildUI()
        if ok then bindButtons(); applyCollapsed(false) end
        return ok
    end,
    close = function()
        RUNNING = false
        destroyUI()
        return true
    end,
    status = function()
        local c = 0
        for _ in pairs(inHooked) do c = c + 1 end
        return string.format("[RSL] 运行=%s 记录=%d 出向钩子=%s 入向钩子=%d 窗口=%s",
            tostring(RUNNING), BUF.n, tostring(outHooked), c, tostring(UI.gui ~= nil))
    end,
    setOption = function(k, v) if CFG[k] ~= nil then CFG[k] = v end return CFG[k] end,
    _record = record,
}

-- ============================ 启动 ============================
local okUI = false
pcall(function()
    okUI = buildUI()
    if okUI then bindButtons() end
end)

if not okUI then
    startLogging()
    pcall(print, "[RSL] 界面不可用，已自动开始记录。用 getgenv().RSLite.dump() / .save() 取数据。")
else
    pcall(print, "[RSL] 已加载：点「开始」再打 Boss；「保存」会显示完整路径；「×」直接删除窗口。")
end
