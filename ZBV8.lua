-- ============================================================
-- Luraph string.char 嗅探器（最终版）
-- 原理：Luraph v14.9 内层 VM 用 string.char 逐字节构造所有解密字符串
--      （UI 文本/URL/Remote 名/配置全部经此出口）——hook 它 = 明文全收
-- 用法：Heavyweight-Fishing 内先跑本脚本 → 跑 NoKey / Loader → 用按钮导出
-- ============================================================

if _G.__SC_DUMPER then warn("已运行") return end
_G.__SC_DUMPER = true
_G.__SC_STRS = _G.__SC_STRS or {}

local CoreGui = (gethui and gethui()) or game:GetService("CoreGui")
local gui = Instance.new("ScreenGui")
gui.Name = "SCDumper"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = CoreGui end)

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(420, 210)
panel.Position = UDim2.new(1, -434, 0, 8)
panel.BackgroundColor3 = Color3.fromRGB(8, 10, 18)
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
panel.Parent = gui
local c1 = Instance.new("UICorner"); c1.CornerRadius = UDim.new(0, 8); c1.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 22)
title.Position = UDim2.fromOffset(8, 4)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(180, 140, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🧬 string.char 嗅探器 — 0 段"
title.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 58)
status.Position = UDim2.fromOffset(8, 28)
status.BackgroundColor3 = Color3.fromRGB(18, 22, 36)
status.Font = Enum.Font.Code
status.TextSize = 11
status.TextColor3 = Color3.fromRGB(180, 255, 180)
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = "1. 本脚本已装 ✅\n2. 跑 NoKey 或 Loader\n3. UI 出现越多文字 = 抓得越多"
status.Parent = panel
local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = status

-- ---------- 核心 hook ----------
local MIN_LEN = 4            -- 只收 >=4 字节的拼接结果
local totalBytes = 0

local ok, err = pcall(function()
    local origChar = string.char
    local buf = {}
    -- 关键：Luraph 常常【一次一个字节】调 string.char，再 table.concat 拼接
    -- 所以同时 hook concat：如果参数全是单字节字符串，拼接结果就是解密串
    local origConcat = table.concat
    table.concat = function(t, sep, ...)
        local ok2, r = pcall(origConcat, t, sep, ...)
        if ok2 and type(r) == "string" and #r >= MIN_LEN then
            -- 粗判可打印性：超过一半是可打印 ASCII 才收
            local printable = 0
            for i = 1, #r do
                local b = r:byte(i)
                if (b >= 32 and b < 127) or b == 10 or b == 13 or b == 9 then
                    printable = printable + 1
                end
            end
            if printable / #r >= 0.7 then
                totalBytes = totalBytes + #r
                _G.__SC_STRS[#_G.__SC_STRS + 1] = r
                title.Text = ("🧬 string.char 嗅探器 — %d 段 / %dB"):format(
                    #_G.__SC_STRS, totalBytes)
                status.Text = ("最新: %s"):format(r:sub(1, 60):gsub("%c", " "))
            end
        end
        return r
    end
    -- 同时 hook 直接的 string.char 长串调用
    string.char = function(...)
        local n = select("#", ...)
        if n >= MIN_LEN then
            local s = origChar(...)
            local printable = 0
            for i = 1, #s do
                local b = s:byte(i)
                if (b >= 32 and b < 127) or b == 10 or b == 13 or b == 9 then
                    printable = printable + 1
                end
            end
            if printable / #s >= 0.7 then
                totalBytes = totalBytes + #s
                _G.__SC_STRS[#_G.__SC_STRS + 1] = s
                title.Text = ("🧬 string.char 嗅探器 — %d 段 / %dB"):format(
                    #_G.__SC_STRS, totalBytes)
            end
            return s
        end
        return origChar(...)
    end
end)

if not ok then
    title.Text = "❌ hook 失败: " .. tostring(err):sub(1, 30)
    warn("SC hook err:", err)
end

-- ---------- 导出 ----------
local function allText()
    local t = {}
    for i, s in ipairs(_G.__SC_STRS) do
        t[#t+1] = ("--- #%d (%dB) ---\n%s"):format(i, #s, s)
    end
    return table.concat(t, "\n\n")
end

_G.SAVE_SC = function()
    if #_G.__SC_STRS == 0 then print("无捕获") return end
    if type(writefile) ~= "function" then print("无 writefile") return end
    local name = ("sc_dump_%d_%dstr.txt"):format(os.time(), #_G.__SC_STRS)
    local ok2 = pcall(function() writefile(name, allText()) end)
    print(ok2 and ("✅ 已保存 workspace/" .. name) or "写入失败")
end

_G.COPY_SC = function()
    if #_G.__SC_STRS == 0 then print("无捕获") return end
    local f = setclipboard or toclipboard
    if not f then print("无剪贴板函数") return end
    -- 逐段复制（避免超限）
    for i, s in ipairs(_G.__SC_STRS) do
        f(s)
        print(("#%d (%dB) 已复制，粘贴后等 1 秒自动复制下一条"), i, #s)
        task.wait(1)
    end
end

panel.Size = UDim2.fromOffset(420, 310)
local function mkBtn(text, y, color, fn)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 28)
    b.Position = UDim2.new(0, 8, 1, y)
    b.BackgroundColor3 = color
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Text = text
    b.Parent = panel
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
    b.MouseButton1Click:Connect(fn)
end
mkBtn("💾 SAVE_SC（写文件）",   -70,  Color3.fromRGB(40, 140, 80), function() _G.SAVE_SC() end)
mkBtn("📋 COPY_SC（逐段剪贴板）", -104, Color3.fromRGB(40, 100, 190), function() _G.COPY_SC() end)
mkBtn("📊 状态",               -138, Color3.fromRGB(90, 60, 160), function()
    print("=== string.char 捕获状态 ===")
    print("段数:", #_G.__SC_STRS, " 总字节:", totalBytes)
    for i, s in ipairs(_G.__SC_STRS) do
        if i > 30 then print("...(更多见 SAVE)") break end
        print(("#%d (%dB): %s"):format(i, #s, s:sub(1, 60):gsub("%c", " ")))
    end
end)

print("🧬 string.char 嗅探器已装 — 跑 NoKey/Loader，之后 SAVE_SC/COPY_SC")
