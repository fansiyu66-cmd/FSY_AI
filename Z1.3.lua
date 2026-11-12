--[[
================================================================================
  BtnDoctor —— 钓鱼按钮诊断器（独立脚本，只读，不改任何东西）
  用途：查清「游戏原生钓鱼按钮为什么不见了 / 为什么不显示」。
  它只做三件事：扫描、把结果摊在窗口里、允许一键复制。不发送任何包、不修改任何属性。
--------------------------------------------------------------------------------
  用法：
      1) 执行器里注入本脚本（可以和主脚本同时跑，互不干扰）
      2) 等钓鱼按钮"消失"的那一刻，点窗口里的「重新扫描」
      3) 把文本框里的内容复制/截图发我
--------------------------------------------------------------------------------
  报告会直接指出是哪一种情况：
      A. 某层父级 Visible=false / Enabled=false  → 被藏了
      B. 尺寸为 0 / 坐标在屏幕外                 → 被挪走了
      C. 全都正常但按钮不在场景里                → 根本没生成 / 被销毁
      D. 脚本没认出这个按钮                      → 识别规则对不上
================================================================================
]]

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local OUT = {}          -- 报告行
local UI = {}

local function add(s) OUT[#OUT + 1] = tostring(s) end

local function isFishLike(d)
    if not (d:IsA("TextButton") or d:IsA("ImageButton")) then return false end
    local nm = string.lower(d.Name or "")
    if nm:find("fish") or nm:find("cast") or nm:find("rod") then return true end
    if d:IsA("TextButton") then
        local t = d.Text or ""
        if t:find("钓鱼", 1, true) or t:find("抛竿", 1, true) or t:find("Câu", 1, true) then return true end
    end
    local low = string.lower(d:GetFullName() or "")
    if low:find("fish") or low:find("cast") then return true end
    return false
end

local function chainOf(d, pg)
    local rows, cur, n = {}, d, 0
    while cur and n < 10 and cur ~= game do
        -- 注意：不能写 `pcall(...) and cur.Visible or nil` —— 当 Visible 是 false 时会被 or 吞成 nil，
        -- 结果报告里最关键的那个 V=false 反而显示不出来（这是本工具第一版踩过的坑）。
        local v, e, pos, sz, tr = nil, nil, nil, nil, nil
        local okV, vv = pcall(function() return cur.Visible end)
        if okV then v = vv end
        local okE, ee = pcall(function() return cur.Enabled end)
        if okE then e = ee end
        local okP, pp = pcall(function() return cur.AbsolutePosition end)
        if okP then pos = pp end
        local okS, ss = pcall(function() return cur.AbsoluteSize end)
        if okS then sz = ss end
        local okT, tt = pcall(function() return cur.Transparency end)
        if okT then tr = tt end
        local line = string.format("%s(%s)", tostring(cur.Name), tostring(cur.ClassName))
        if v ~= nil then line = line .. " V=" .. tostring(v) end
        if e ~= nil then line = line .. " E=" .. tostring(e) end
        if pos then line = line .. string.format(" pos=(%.0f,%.0f)", pos.X, pos.Y) end
        if sz then line = line .. string.format(" size=(%.0f,%.0f)", sz.X, sz.Y) end
        if tr ~= nil then line = line .. string.format(" T=%.2f", tr) end
        rows[#rows + 1] = line
        cur = cur.Parent
        n = n + 1
        if cur == pg or cur == game then break end
    end
    return rows
end

function Scan()
    OUT = {}
    local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then add("PlayerGui 不存在（还没进游戏？）") return end
    local screenW = 0
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then screenW = cam.ViewportSize.X end
    end)

    add("========== 1. PlayerGui 下所有 ScreenGui ==========")
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") then
            add(string.format("  %-28s Enabled=%s", tostring(g.Name), tostring(g.Enabled)))
        end
    end

    add("")
    add("========== 2. 疑似钓鱼按钮（逐个列出父级链） ==========")
    local found = 0
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Name ~= "RobloxGui"
            and g.Name ~= "IdenticalHeavyweightFishing" and g.Name ~= "RSLiteGui" and g.Name ~= "BtnDoctorGui" then
            for _, d in ipairs(g:GetDescendants()) do
                if isFishLike(d) then
                    found = found + 1
                    add("")
                    add(string.format("[%d] %s", found, d:GetFullName()))
                    local rows = chainOf(d, pg)
                    for i, r in ipairs(rows) do
                        add("      " .. string.rep("  ", i - 1) .. r)
                    end
                    -- 自动判定
                    local hidden, offscreen, zero = false, false, false
                    for _, r in ipairs(rows) do
                        if r:find("V=false") or r:find("E=false") then hidden = true end
                    end
                    local okPos, pos = pcall(function() return d.AbsolutePosition end)
                    local okSz, sz = pcall(function() return d.AbsoluteSize end)
                    if okSz and sz and (sz.X < 2 or sz.Y < 2) then zero = true end
                    if okPos and pos and screenW > 0 and (pos.X < -50 or pos.X > screenW + 50 or pos.Y < -50) then offscreen = true end
                    add("      >>> 判定: " .. (hidden and "【被隐藏】父级有 V=false 或 E=false"
                        or zero and "【尺寸为 0】"
                        or offscreen and "【被移到屏幕外】"
                        or "【看起来正常】那问题不在显隐，可能是被别的控件盖住或游戏没意图显示"))
                end
            end
        end
    end
    if found == 0 then
        add("  （一个都没扫到）")
        add("  >>> 说明：按钮所在容器可能不叫 fish/cast，或者此刻根本没生成。")
        add("  >>> 请把下面第 3 段完整发我，我照着改识别规则。")
    end

    add("")
    add("========== 3. 脚本自己怎么看（主脚本注入过才有值） ==========")
    local ok, ge = pcall(function() return getgenv() end)
    if ok and ge then
        add("  IdenticalProtectedFishBtn   = " .. tostring(ge.IdenticalProtectedFishBtn))
        add("  IdenticalKeepFishBtnVisible = " .. tostring(ge.IdenticalKeepFishBtnVisible))
        add("  IdenticalFishingRunning     = " .. tostring(ge.IdenticalFishingRunning))
        local b = ge.IdenticalProtectedFishBtn
        if b then
            local okV = pcall(function() return b.Visible end)
            add("  → 脚本缓存的按钮 Visible = " .. (okV and tostring(b.Visible) or "读取失败"))
            local okP = pcall(function() return b:GetFullName() end)
            add("  → 脚本缓存的按钮路径     = " .. (okP and tostring(b:GetFullName()) or "?"))
        else
            add("  → 脚本压根没认出这个按钮（识别规则没匹配上）")
        end
    else
        add("  getgenv() 不可用")
    end

    add("")
    add("========== 4. 主脚本 UI 里的相关开关 ==========")
    if ok and ge and ge.IdenticalFishingConfig then
        local c = ge.IdenticalFishingConfig
        add("  AutoCast        = " .. tostring(c.AutoCast))
        add("  HideGameUI      = " .. tostring(c.HideGameUI))
        add("  AutoFarmBoss    = " .. tostring(c.AutoFarmBoss))
        add("  AutoFarmSecretBoss = " .. tostring(c.AutoFarmSecretBoss))
    else
        add("  没有读到主脚本配置（主脚本没注入？）")
    end
    add("")
    add("===== 报告结束 =====")
end

-- ============================ 界面（加载期一次性构建） ============================
local function buildUI()
    local parent
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then parent = core end
    if not parent then parent = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") end
    if not parent then return false end

    local gui = Instance.new("ScreenGui")
    gui.Name = "BtnDoctorGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999998
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 340, 0, 30)
    frame.Position = UDim2.new(0.5, -170, 0.3, 0)
    frame.BackgroundColor3 = Color3.fromRGB(22, 26, 34)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.ClipsDescendants = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -100, 0, 30)
    title.Position = UDim2.new(0, 8, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(140, 200, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "钓鱼按钮诊断器"
    title.Parent = frame

    local btnScan = Instance.new("TextButton")
    btnScan.Name = "Scan"
    btnScan.Size = UDim2.new(0, 34, 0, 22)
    btnScan.Position = UDim2.new(1, -104, 0, 4)
    btnScan.BackgroundColor3 = Color3.fromRGB(46, 60, 54)
    btnScan.BorderSizePixel = 0
    btnScan.Font = Enum.Font.GothamBold
    btnScan.TextSize = 11
    btnScan.TextColor3 = Color3.fromRGB(220, 240, 230)
    btnScan.Text = "扫描"
    btnScan.Parent = frame

    local btnCopy = Instance.new("TextButton")
    btnCopy.Name = "Copy"
    btnCopy.Size = UDim2.new(0, 34, 0, 22)
    btnCopy.Position = UDim2.new(1, -66, 0, 4)
    btnCopy.BackgroundColor3 = Color3.fromRGB(46, 60, 54)
    btnCopy.BorderSizePixel = 0
    btnCopy.Font = Enum.Font.GothamBold
    btnCopy.TextSize = 11
    btnCopy.TextColor3 = Color3.fromRGB(220, 240, 230)
    btnCopy.Text = "复制"
    btnCopy.Parent = frame

    local btnOpen = Instance.new("TextButton")
    btnOpen.Name = "Open"
    btnOpen.Size = UDim2.new(0, 26, 0, 22)
    btnOpen.Position = UDim2.new(1, -30, 0, 4)
    btnOpen.BackgroundColor3 = Color3.fromRGB(58, 46, 46)
    btnOpen.BorderSizePixel = 0
    btnOpen.Font = Enum.Font.GothamBold
    btnOpen.TextSize = 12
    btnOpen.TextColor3 = Color3.fromRGB(255, 200, 200)
    btnOpen.Text = "×"
    btnOpen.Parent = frame

    local box = Instance.new("TextBox")
    box.Name = "Report"
    box.Size = UDim2.new(1, -12, 1, -40)
    box.Position = UDim2.new(0, 6, 0, 34)
    box.BackgroundColor3 = Color3.fromRGB(12, 15, 20)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Code
    box.TextSize = 11
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextYAlignment = Enum.TextYAlignment.Top
    box.TextWrapped = false
    box.MultiLine = true
    box.ClearTextOnFocus = false
    box.TextEditable = false
    box.TextColor3 = Color3.fromRGB(200, 220, 240)
    box.Text = "点右上角「扫描」"
    box.Visible = true
    box.Parent = frame

    UI.gui = gui
    UI.frame = frame
    UI.box = box
    UI.open = false

    local function setOpen(v)
        UI.open = v and true or false
        frame.Size = UI.open and UDim2.new(0, 340, 0, 360) or UDim2.new(0, 340, 0, 30)
        box.Visible = UI.open
        btnScan.Visible = UI.open
        btnCopy.Visible = UI.open
        btnOpen.Text = UI.open and "×" or "▣"
    end

    btnOpen.MouseButton1Click:Connect(function()
        if UI.open then
            gui:Destroy()
            UI.gui = nil
        else
            setOpen(true)
        end
    end)
    btnScan.MouseButton1Click:Connect(function()
        pcall(Scan)
        box.Text = table.concat(OUT, "\n")
    end)
    btnCopy.MouseButton1Click:Connect(function()
        local t = box.Text or ""
        if type(setclipboard) == "function" then pcall(setclipboard, t) end
        if type(writefile) == "function" then pcall(writefile, "BtnDoctor.txt", t) end
        btnCopy.Text = "已复制"
    end)

    pcall(Scan)
    box.Text = table.concat(OUT, "\n")
    setOpen(true)
    return true
end

local ok = pcall(buildUI)
if not ok then
    pcall(Scan)
    local t = table.concat(OUT, "\n")
    pcall(print, t)
    if type(setclipboard) == "function" then pcall(setclipboard, t) end
    pcall(print, "[BtnDoctor] 界面不可用，已把报告打印并复制到剪贴板。")
end

pcall(function()
    getgenv().BtnDoctor = {
        scan = function() pcall(Scan) local t = table.concat(OUT, "\n") if type(setclipboard) == "function" then pcall(setclipboard, t) end return t end,
        show = function() pcall(buildUI) end,
    }
end)
