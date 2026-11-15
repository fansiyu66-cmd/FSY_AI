-- ============================================================
-- NNVN 第四级 URL 嗅探器 v3（带 UI：实时列表 + 复制 + 保存按钮）
-- 用法：进入 Forsaken 游戏 → 先跑本脚本 → 再跑官方 Loader
-- 状态条会实时列出抓到的 URL；按钮一键复制/保存
-- ============================================================

if _G.__NNVN_SNIFFER_V3 then
    warn("嗅探器已在运行，勿重复执行")
    return
end
_G.__NNVN_SNIFFER_V3 = true
_G.__CAPTURED = _G.__CAPTURED or {}

local Players  = game:GetService("Players")
local CoreGui  = (gethui and gethui()) or game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer

-- ---------- 工具 ----------
local function tryClip(s)
    local ok = pcall(function()
        if setclipboard then setclipboard(s)
        elseif toclipboard then toclipboard(s)
        else error("no clip fn") end
    end)
    return ok
end

local function hasWrite()
    return type(writefile) == "function"
end

local function fmtAll()
    local t = {}
    for i, e in ipairs(_G.__CAPTURED) do
        t[#t+1] = ("#%d [%s] %s"):format(i, e.via or "?", e.url or "?")
    end
    return table.concat(t, "\n")
end

-- ---------- UI ----------
local gui = Instance.new("ScreenGui")
gui.Name = "NNVNSnifferV3"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local okP = pcall(function() gui.Parent = CoreGui end)
if not okP then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- 主面板（右上角，可拖动）
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(420, 260)
panel.Position = UDim2.new(1, -435, 0, 8)
panel.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
panel.BackgroundTransparency = 0.12
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel

-- 标题栏
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -12, 0, 24)
title.Position = UDim2.fromOffset(6, 4)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🔍 NNVN 嗅探器 v3 — 0 条"
title.Parent = panel

-- 滚动列表
local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -12, 1, -66)
list.Position = UDim2.fromOffset(6, 30)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = panel
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list

-- 按钮行
local function mkBtn(text, xPos, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.32, -8, 0, 26)
    b.Position = UDim2.new(xPos, 6, 1, -32)
    b.BackgroundColor3 = color
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Text = text
    b.Parent = panel
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    return b
end

local btnCopy  = mkBtn("📋 复制全部", 0,     Color3.fromRGB(40, 100, 190))
local btnSave  = mkBtn("💾 保存",     0.34,  Color3.fromRGB(40, 140, 80))
local btnClose = mkBtn("✕ 关闭",     0.68,  Color3.fromRGB(150, 50, 50))

-- ---------- 抓包 hook ----------
local hookOK, hookErr = pcall(function()
    local old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if m == "HttpGet" or m == "GetAsync" or m == "PostAsync"
           or m == "RequestAsync" or m == "GetObjects" then
            local args = { ... }
            local url = tostring(args[1])
            table.insert(_G.__CAPTURED, { url = url, via = m, t = os.clock() })

            -- 实时加进 UI 列表
            local row = Instance.new("TextLabel")
            row.Size = UDim2.new(1, -8, 0, 18)
            row.BackgroundTransparency = 1
            row.Font = Enum.Font.Code
            row.TextSize = 11
            row.TextColor3 = Color3.fromRGB(180, 255, 180)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Text = ("#%d %s"):format(#_G.__CAPTURED, url:sub(1, 58))
            row.Parent = list

            title.Text = ("🔍 NNVN 嗅探器 v3 — %d 条"):format(#_G.__CAPTURED)
            warn(("[抓包 #%d][%s] %s"):format(#_G.__CAPTURED, m, url))

            -- 自动复制最新一条（你要的自动复制）
            tryClip(url)
        end
        return old(self, ...)
    end))
    assert(old ~= nil, "hookmetamethod 返回空")
end)

if not hookOK then
    title.Text = "❌ hook 失败: " .. tostring(hookErr):sub(1, 34)
    title.TextColor3 = Color3.fromRGB(255, 90, 90)
    warn("嗅探器 hook 失败:", hookErr)
    return
end

-- ---------- 按钮 action ----------
btnCopy.MouseButton1Click:Connect(function()
    local s = fmtAll()
    if s == "" then
        btnCopy.Text = "无记录"; task.wait(1); btnCopy.Text = "📋 复制全部"; return
    end
    if tryClip(s) then
        btnCopy.Text = "✅ 已复制"; print("[嗅探器] 全量已复制:\n" .. s)
    else
        btnCopy.Text = "❌ 剪贴板不可用"
        print("[嗅探器] 复制失败，控制台输出全量:\n" .. s)
    end
    task.wait(1.4); btnCopy.Text = "📋 复制全部"
end)

btnSave.MouseButton1Click:Connect(function()
    local s = fmtAll()
    if s == "" then
        btnSave.Text = "无记录"; task.wait(1); btnSave.Text = "💾 保存"; return
    end
    if hasWrite() then
        local name = ("NNVN_urls_%d.txt"):format(os.time())
        local okW = pcall(function() writefile(name, s) end)
        if okW then
            btnSave.Text = "✅ " .. name
            print(("[嗅探器] 已保存到执行器 workspace/%s"):format(name))
        else
            btnSave.Text = "❌ 写入失败"
        end
    else
        btnSave.Text = "❌ 无 writefile"
        print("[嗅探器] 此执行器无 writefile，请用复制按钮")
    end
    task.wait(1.6); btnSave.Text = "💾 保存"
end)

btnClose.MouseButton1Click:Connect(function()
    _G.__NNVN_SNIFFER_V3 = nil
    gui:Destroy()
end)

-- 自测（本地地址，不真发外网）
task.delay(0.5, function()
    local before = #_G.__CAPTURED
    pcall(function() game:HttpGet("http://127.0.0.1:9/__selftest") end)
    if #_G.__CAPTURED > before then
        title.Text = ("🔍 嗅探器 v3 正常 — %d 条（去跑 Loader）"):format(#_G.__CAPTURED)
        print("✅ 嗅探器自测通过")
    end
end)

print("🔍 NNVN 嗅探器 v3 已装载 — 右上角面板，去跑官方 Loader")
