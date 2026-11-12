--[[
================================================================================
  BtnDoctor v2 —— 钓鱼按钮诊断器（独立脚本，只读）
  v1 的问题：窗口先按 30px 建、再靠 setOpen 撑开；一旦中途任何一句抛错，
                窗口就停在一条横条上，报告也写不进去 —— 屏幕上看就是"只有一个标题条"。
  v2 的改法：窗口一开始就是全尺寸、报告框一开始就可见；整段构建包在 pcall 里，
                真出错就把错误原文写进报告框，看得到才好排查。
--------------------------------------------------------------------------------
  用法：注入 → 等按钮消失 → 点「扫描」→ 点「复制」把内容发我（或直接截图）
================================================================================
]]

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local OUT = {}
local function add(s) OUT[#OUT + 1] = tostring(s) end

local function isFishLike(d)
    local okB, isBtn = pcall(function() return d:IsA("TextButton") or d:IsA("ImageButton") end)
    if not (okB and isBtn) then return false end
    local nm = string.lower(tostring(d.Name or ""))
    if nm:find("fish") or nm:find("cast") or nm:find("rod") then return true end
    local okT, txt = pcall(function() return d.Text end)
    if okT and type(txt) == "string" then
        if txt:find("钓鱼", 1, true) or txt:find("抛竿", 1, true) then return true end
    end
    local okF, full = pcall(function() return d:GetFullName() end)
    if okF and type(full) == "string" then
        local low = string.lower(full)
        if low:find("fish") or low:find("cast") then return true end
    end
    return false
end

local function chainOf(d, pg)
    local rows, cur, n = {}, d, 0
    while cur and n < 10 do
        local line = tostring(cur.Name) .. "(" .. tostring(cur.ClassName) .. ")"
        local okV, v = pcall(function() return cur.Visible end)
        if okV then line = line .. " V=" .. tostring(v) end
        local okE, e = pcall(function() return cur.Enabled end)
        if okE then line = line .. " E=" .. tostring(e) end
        local okP, p = pcall(function() return cur.AbsolutePosition end)
        if okP and p then line = line .. string.format(" pos=(%.0f,%.0f)", p.X, p.Y) end
        local okS, s = pcall(function() return cur.AbsoluteSize end)
        if okS and s then line = line .. string.format(" size=(%.0f,%.0f)", s.X, s.Y) end
        local okT, t = pcall(function() return cur.Transparency end)
        if okT then line = line .. string.format(" T=%.2f", t) end
        rows[#rows + 1] = line
        if cur == pg or cur == game then break end
        local okPar, par = pcall(function() return cur.Parent end)
        if not okPar then break end
        cur = par
        n = n + 1
    end
    return rows
end

local function Scan()
    OUT = {}
    local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then add("PlayerGui 不存在") return end

    add("========== 1. PlayerGui 下的 ScreenGui ==========")
    for _, g in ipairs(pg:GetChildren()) do
        local okG, isGui = pcall(function() return g:IsA("ScreenGui") end)
        if okG and isGui then
            add(string.format("  %-30s Enabled=%s", tostring(g.Name), tostring(g.Enabled)))
        end
    end

    add("")
    add("========== 2. 疑似钓鱼按钮（父级链逐层列出） ==========")
    local found = 0
    for _, g in ipairs(pg:GetChildren()) do
        local okG, isGui = pcall(function() return g:IsA("ScreenGui") end)
        if okG and isGui and g.Name ~= "RobloxGui" and g.Name ~= "BtnDoctorGui" then
            for _, d in ipairs(g:GetDescendants()) do
                if isFishLike(d) then
                    found = found + 1
                    add("")
                    add(string.format("[%d] %s", found, tostring(d:GetFullName())))
                    local rows = chainOf(d, pg)
                    for i, r in ipairs(rows) do
                        add("      " .. string.rep("  ", i - 1) .. r)
                    end
                    local hidden, zero = false, false
                    for _, r in ipairs(rows) do
                        if r:find("V=false") or r:find("E=false") then hidden = true end
                    end
                    local okS, sz = pcall(function() return d.AbsoluteSize end)
                    if okS and sz and (sz.X < 2 or sz.Y < 2) then zero = true end
                    add("      >>> 判定: " .. (hidden and "【被隐藏】父级链里有 V=false 或 E=false"
                        or zero and "【尺寸为 0】"
                        or "【看起来正常】不是显隐问题，可能被遮挡或游戏本就不打算显示"))
                end
            end
        end
    end
    if found == 0 then
        add("  （一个都没扫到）")
        add("  >>> 说明按钮容器名字不含 fish/cast，或此刻根本没生成。")
        add("  >>> 把第 1 段完整发我，我按真实名字改识别规则。")
    end

    add("")
    add("========== 3. 主脚本怎么看这个按钮 ==========")
    local okGe, ge = pcall(function() return getgenv() end)
    if okGe and ge then
        add("  IdenticalProtectedFishBtn   = " .. tostring(ge.IdenticalProtectedFishBtn))
        add("  IdenticalKeepFishBtnVisible = " .. tostring(ge.IdenticalKeepFishBtnVisible))
        add("  IdenticalFishingRunning     = " .. tostring(ge.IdenticalFishingRunning))
        local b = ge.IdenticalProtectedFishBtn
        if b then
            local okV, v = pcall(function() return b.Visible end)
            add("  → 缓存的按钮 Visible = " .. (okV and tostring(v) or "?"))
            local okF, f = pcall(function() return b:GetFullName() end)
            add("  → 缓存的按钮路径     = " .. (okF and tostring(f) or "?"))
        else
            add("  → 主脚本没认出这个按钮（识别规则没匹配上）")
        end
        local c = ge.IdenticalFishingConfig
        if c then
            add("  AutoCast=" .. tostring(c.AutoCast) .. "  HideGameUI=" .. tostring(c.HideGameUI)
                .. "  AutoFarmBoss=" .. tostring(c.AutoFarmBoss))
        else
            add("  （没读到主脚本配置：主脚本没注入或版本较旧）")
        end
    else
        add("  getgenv() 不可用")
    end
    add("")
    add("===== 报告结束 =====")
end

-- ============================ UI（一开始就是全尺寸） ============================
local UI = {}

local function buildUI()
    local parent
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then parent = core end
    if not parent then parent = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") end
    if not parent then return false, "没有 CoreGui / PlayerGui" end

    local gui = Instance.new("ScreenGui")
    gui.Name = "BtnDoctorGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999998
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 340, 0, 380)      -- 一开始就全尺寸（v1 的坑就在这）
    frame.Position = UDim2.new(0.5, -170, 0.12, 0)
    frame.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.ClipsDescendants = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -140, 0, 28)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(140, 200, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "钓鱼按钮诊断器"
    title.Parent = frame

    local function mkBtn(name, text, xOff, bg)
        local b = Instance.new("TextButton")
        b.Name = name
        b.Size = UDim2.new(0, 40, 0, 22)
        b.Position = UDim2.new(1, xOff, 0, 3)
        b.BackgroundColor3 = bg
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.TextColor3 = Color3.fromRGB(225, 240, 235)
        b.Text = text
        b.Parent = frame
        return b
    end
    local btnScan = mkBtn("Scan", "扫描", -134, Color3.fromRGB(46, 62, 56))
    local btnCopy = mkBtn("Copy", "复制", -90, Color3.fromRGB(46, 62, 56))
    local btnClose = mkBtn("Close", "×", -28, Color3.fromRGB(62, 44, 44))

    local box = Instance.new("TextBox")
    box.Name = "Report"
    box.Size = UDim2.new(1, -12, 1, -36)
    box.Position = UDim2.new(0, 6, 0, 30)
    box.BackgroundColor3 = Color3.fromRGB(10, 13, 18)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Code
    box.TextSize = 11
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextYAlignment = Enum.TextYAlignment.Top
    box.TextWrapped = true
    box.MultiLine = true
    box.ClearTextOnFocus = false
    box.TextEditable = false
    box.TextColor3 = Color3.fromRGB(200, 220, 240)
    box.Text = "正在扫描…"
    box.Parent = frame

    UI.gui, UI.frame, UI.box = gui, frame, box

    btnClose.MouseButton1Click:Connect(function()
        pcall(function() gui:Destroy() end)
        UI.gui = nil
    end)
    btnScan.MouseButton1Click:Connect(function()
        local ok, err = pcall(Scan)
        if not ok then
            box.Text = "扫描出错：\n" .. tostring(err)
        else
            box.Text = table.concat(OUT, "\n")
        end
    end)
    btnCopy.MouseButton1Click:Connect(function()
        local t = box.Text or ""
        if type(setclipboard) == "function" then pcall(setclipboard, t) end
        if type(writefile) == "function" then pcall(writefile, "BtnDoctor.txt", t) end
        btnCopy.Text = "已复制"
    end)

    return true
end

local ok, err = pcall(buildUI)
if ok then
    -- 构建成功后再扫描；扫描失败也只写到框里，不影响窗口
    local ok2, err2 = pcall(Scan)
    if UI.box then
        if ok2 then
            UI.box.Text = table.concat(OUT, "\n")
        else
            UI.box.Text = "扫描出错：\n" .. tostring(err2)
        end
    end
else
    -- 界面建不出来时退回打印 + 剪贴板
    pcall(Scan)
    local t = table.concat(OUT, "\n")
    pcall(print, t)
    if type(setclipboard) == "function" then pcall(setclipboard, t) end
end

pcall(function()
    getgenv().BtnDoctor = {
        scan = function()
            pcall(Scan)
            local t = table.concat(OUT, "\n")
            if type(setclipboard) == "function" then pcall(setclipboard, t) end
            return t
        end,
        show = function() pcall(buildUI) end,
    }
end)
