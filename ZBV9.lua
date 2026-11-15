-- ============================================================
-- string.char 嗅探器 v2（保守版：只 hook char，不动 concat）
-- Luraph 14.9 的 anti-tamper 可能检查 table.concat 完整性
-- 但 string.char 的逐字节调用模式难以被 anti-tamper 发现（返回值不变）
-- ============================================================
if _G.__SC2 then warn("已运行") return end
_G.__SC2 = true
_G.__SC_STRS = _G.__SC_STRS or {}
local CoreGui = (gethui and gethui()) or game:GetService("CoreGui")
local gui = Instance.new("ScreenGui")
gui.Name = "SCDumper2"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = CoreGui end)
local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(420, 160)
panel.Position = UDim2.new(1, -434, 0, 8)
panel.BackgroundColor3 = Color3.fromRGB(8, 10, 18)
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Active = true; panel.Draggable = true
panel.Parent = gui
local c1 = Instance.new("UICorner"); c1.CornerRadius = UDim.new(0, 8); c1.Parent = panel
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 22); title.Position = UDim2.fromOffset(8, 4)
title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold
title.TextSize = 13; title.TextColor3 = Color3.fromRGB(180, 140, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🧬 char v2 — 0 段"
title.Parent = panel
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 36); status.Position = UDim2.fromOffset(8, 28)
status.BackgroundColor3 = Color3.fromRGB(18, 22, 36); status.Font = Enum.Font.Code
status.TextSize = 11; status.TextColor3 = Color3.fromRGB(180, 255, 180)
status.TextXAlignment = Enum.TextXAlignment.Left; status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = "hook 中…跑 NoKey 看效果"
status.Parent = panel
local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = status
-- 核心：只 hook char
local origChar = string.char
local ok, err = pcall(function()
    string.char = function(...)
        local n = select("#", ...)
        if n < 6 then return origChar(...) end  -- 快路径
        local s = origChar(...)
        -- 可打印率检查
        local p = 0
        for i = 1, #s do
            local b = s:byte(i)
            if (b >= 32 and b < 127) or b == 10 or b == 13 or b == 9 then p = p + 1 end
        end
        if p / #s >= 0.7 then
            _G.__SC_STRS[#_G.__SC_STRS + 1] = s
            title.Text = ("🧬 char v2 — %d 段"):format(#_G.__SC_STRS)
            status.Text = ("最新(%dB): %s"):format(#s, s:sub(1, 52):gsub("%c", " "))
        end
        return s
    end
end)
if not ok then
    title.Text = "❌ " .. tostring(err):sub(1, 34)
    warn("SC2 hook err:", err)
end
_G.SAVE_SC = function()
    if #_G.__SC_STRS == 0 then print("无") return end
    if not writefile then print("无 writefile") return end
    local name = ("sc2_%d.txt"):format(os.time())
    local parts = {}
    for i, s in ipairs(_G.__SC_STRS) do
        parts[#parts+1] = ("--- #%d (%dB) ---\n%s"):format(i, #s, s)
    end
    pcall(function() writefile(name, table.concat(parts, "\n")) end)
    print("✅ " .. name)
end
_G.COPY_SC = function()
    if #_G.__SC_STRS == 0 then print("无") return end
    local f = setclipboard or toclipboard
    if not f then print("无剪贴板") return end
    for i, s in ipairs(_G.__SC_STRS) do
        f(s)
        print(("#%d(%dB) 已复制"), i, #s)
        task.wait(1)
    end
end
_G.SC_STATUS = function()
    print("段数:", #_G.__SC_STRS)
    for i, s in ipairs(_G.__SC_STRS) do
        if i > 40 then print("...更多") break end
        print(("#%d(%dB): %s"):format(i, #s, s:sub(1, 70):gsub("%c", " ")))
    end
end
panel.Size = UDim2.fromOffset(420, 240)
local function mkBtn(text, y, color, fn)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 28)
    b.Position = UDim2.new(0, 8, 1, y)
    b.BackgroundColor3 = color; b.Font = Enum.Font.GothamBold
    b.TextSize = 13; b.TextColor3 = Color3.new(1,1,1); b.Text = text
    b.Parent = panel
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
    b.MouseButton1Click:Connect(fn)
end
mkBtn("💾 SAVE_SC",   -70,  Color3.fromRGB(40,140,80), function() _G.SAVE_SC() end)
mkBtn("📋 COPY_SC",   -104, Color3.fromRGB(40,100,190), function() _G.COPY_SC() end)
mkBtn("📊 SC_STATUS", -138, Color3.fromRGB(90,60,160), function() _G.SC_STATUS() end)
print("🧬 char v2 已装 — 跑 NoKey")
