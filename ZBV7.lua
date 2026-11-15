-- ============================================================
-- Luraph 运行时 dump 载荷（手机端）
-- 用法：在 Heavyweight-Fishing（或任何 NNVN 游戏）内：
--   1. 先跑本脚本
--   2. 再跑 NoKey 直通或官方 Loader（走完 key 流程）
--   3. 最后执行 _G.SAVE_DUMPS() 或 _G.COPY_DUMPS()
-- ============================================================

if _G.__LURAPH_DUMP then warn("dump 载荷已运行") return end
_G.__LURAPH_DUMP = true
_G.__DUMPS = _G.__DUMPS or {}

-- ---------- UI 面板 ----------
local CoreGui = (gethui and gethui()) or game:GetService("CoreGui")
local gui = Instance.new("ScreenGui")
gui.Name = "LuraphDumper"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = CoreGui end)

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(400, 180)
panel.Position = UDim2.new(1, -414, 0, 8)
panel.BackgroundColor3 = Color3.fromRGB(10, 12, 20)
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
title.TextColor3 = Color3.fromRGB(255, 200, 120)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🧬 Luraph Dumper — 待触发"
title.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 40)
status.Position = UDim2.fromOffset(8, 28)
status.BackgroundColor3 = Color3.fromRGB(20, 26, 40)
status.Font = Enum.Font.Code
status.TextSize = 11
status.TextColor3 = Color3.fromRGB(180, 255, 180)
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = "1. 跑本脚本 ✅\n2. 现在去跑 NoKey / Loader"
status.Parent = panel
local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = status

-- ---------- 核心：loadstring hook ----------
local ok, err = pcall(function()
    local orig = loadstring
    loadstring = function(src, ...)
        if type(src) == "string" and #src > 5000 then
            table.insert(_G.__DUMPS, { src = src, t = os.time() })
            title.Text = ("🧬 已截获 %d 段"):format(#_G.__DUMPS)
            status.Text = ("第 %d 段: %d 字节\n头: %s"):format(
                #_G.__DUMPS, #src, src:sub(1, 56))
            warn(("[dump #%d] %d 字节 | 头80: %s"):format(
                #_G.__DUMPS, #src, src:sub(1, 80):gsub("%c", " ")))
        end
        return orig(src, ...)
    end
end)

if not ok then
    title.Text = "❌ loadstring hook 失败"
    status.Text = tostring(err):sub(1, 80)
    warn("hook err:", err)
end

-- ---------- 导出 ----------
local function allText()
    local t = {}
    for i, d in ipairs(_G.__DUMPS) do
        t[#t+1] = ("===== DUMP #%d (%d bytes) =====\n%s"):format(i, #d.src, d.src)
    end
    return table.concat(t, "\n\n")
end

_G.SAVE_DUMPS = function()
    if #_G.__DUMPS == 0 then print("无 dump") return end
    if type(writefile) ~= "function" then print("无 writefile，用 COPY_DUMPS") return end
    for i, d in ipairs(_G.__DUMPS) do
        local name = ("luraph_dump_%d_%d.lua"):format(i, #d.src)
        pcall(function() writefile(name, d.src) end)
        print("已保存:", name)
    end
end

_G.COPY_DUMPS = function()
    local s = allText()
    if s == "" then print("无 dump") return end
    local f = setclipboard or toclipboard
    if f then
        -- 剪贴板可能有大小限制，逐段复制
        if #s > 100000 then
            print("总量过大(" .. #s .. "B)，逐段复制：")
            for i, d in ipairs(_G.__DUMPS) do
                f(d.src)
                print(("#%d (%dB) 已复制 — 粘贴后执行下一条"), i, #d.src)
                task.wait(0.3)
            end
        else
            f(s)
            print("✅ 全部已复制到剪贴板")
        end
    else
        print("[无剪贴板] 控制台输出：")
        print(s:sub(1, 4000))
    end
end

-- 按钮
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
    return b
end

panel.Size = UDim2.fromOffset(400, 280)
mkBtn("💾 SAVE_DUMPS（写文件）", -66,  Color3.fromRGB(40, 140, 80), function() _G.SAVE_DUMPS() end)
mkBtn("📋 COPY_DUMPS（剪贴板）", -100, Color3.fromRGB(40, 100, 190), function() _G.COPY_DUMPS() end)
mkBtn("📊 查看状态",             -134, Color3.fromRGB(90, 60, 160), function()
    print("=== DUMP 状态 ===")
    if #_G.__DUMPS == 0 then
        print("还没有截获任何 loadstring 大载荷")
        print("→ 去跑 NoKey 直通或官方 Loader")
    else
        for i, d in ipairs(_G.__DUMPS) do
            print(("#%d: %d 字节 | 头: %s"):format(i, #d.src, d.src:sub(1, 70):gsub("%c", " ")))
        end
    end
end)

print("🧬 Luraph Dumper 已装载 — 去跑 NoKey/Loader，之后 SAVE_DUMPS/COPY_DUMPS 导出")
