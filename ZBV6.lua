-- ============================================================
-- NNVN 侦察台（全信息屏显版）—— 一张贴纸上显示一切
-- 功能：PlaceId/游戏名/路由判定 屏显 + 强制触发第四级 + 抓包 + 复制/保存
-- 用法：任意游戏内直接执行本脚本 → 看屏幕右侧面板 → 点按钮
-- ============================================================

if _G.__NNVN_RECON then warn("侦察台已运行") return end
_G.__NNVN_RECON = true
_G.__CAPTURED = _G.__CAPTURED or {}

local Players = game:GetService("Players")
local MS = game:GetService("MarketplaceService")
local CoreGui = (gethui and gethui()) or game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer

-- ---------- 工具 ----------
local function tryClip(s)
    return pcall(function()
        if setclipboard then setclipboard(s) elseif toclipboard then toclipboard(s) else error("x") end
    end)
end
local function fmtAll()
    local t = {}
    for i, e in ipairs(_G.__CAPTURED) do
        t[#t+1] = ("#%d [%s] %s"):format(i, e.via or "?", e.url or "?")
    end
    return table.concat(t, "\n")
end

-- ---------- 路由表 ----------
local ROUTE = {
[74102906764176]="Greedy-Growers",[98502499119821]="Heavyweight-Fishing",
[140302982046391]="Be-The-Final-Boss-",[17600423422]="Flee-10-Player",
[99521272836282]="Final-Swarm",[132508978828159]="Roll-to-Survive-",
[74218191398494]="-1-Double-Jump-Bike-Escape-",[127634932179327]="Kick-Ball-to-Space-",
[80111254680893]="Zombies-",[75654987823652]="-1-Speed-Boat-Tsunami",
[90803345996188]="Speed-vs-Giant",[102990893659741]="Brainblast-a-Lucky-Block-",
[134660056748270]="1-Speed-Per-Click",[96033388567901]="Loot-Evo",
[75568173037446]="Get-Fat-to-Break-Tape",[10449761463]="The-Strongest-BattleGrounds",
[18687417158]="Forsaken",[137233438285284]="Chicken-Farm-",
[136107936984073]="-1-Muscle-to-Push-Boulder",[1962086868]="Tower-of-Hell",
[74716719697996]="Survive-Verity-In-Arena-51",[133294838637122]="Jump-to-Steal-Soccer-Players",
[8737899170]="Pet-Simulator-99",[96401370703274]="Climb-and-Drop-a-Lucky-Block-",
[132016691802922]="Build-a-Base-and-Steal",[112838150455902]="Encounter-Smash-Battles",
[119609933650338]="Dog-Race",[1537690962]="Bee-Swarm-Simulator",
[100400297022629]="Duels-Warriors",[112641748896693]="Missiles-vs-Cities",
[116223724643557]="-1-Magic-Evolution",[89469502395769]="Kick-A-Lucky-Block",
[83622406313819]="Loot-Up",[119031147890918]="Dino-Hunters",
[78177131121429]="Drill-Blocks-For-Brainrots",[99702578544768]="Be-A-Fish-Bait",
[115681808123944]="Throw-a-Coin-",[114204398207377]="Survive-Zombie-Arena",
[138381251771774]="Drain-the-Lake",[118433033586507]="Simple-Spell",
[13864661000]="Break-In-2",[3678761576]="ENTRENCHED-WW1",
[142823291]="Murder-Mystery-2",[16039690331]="Secret-Killer",
[116495829188952]="Dead-rails-Heatwave-",[10260193230]="Meme-sea",
[7711635737]="Emergency-Hamburg",[12998806177]="Kill-Streak",
[114234929420007]="Blox-Strike-",[94640181989498]="Grow-a-Chicken-Fighter",
[13400517693]="Goofy-Gods",[90086669327265]="-1-Cut-Grass-Adventure",
[108307565942574]="Hero-RNG-",[107778070777162]="Steal-An-Egg-",
[2753915549]="Blox-Fruit",[99925503388128]="Fishing-Master",
[97617452700163]="Anime-Eye",[6938803436]="Anime-Dimension",
[97289366402005]="Fake-An-Egg",[104856666707760]="KillStreak-Battle-Royale",
[108448382032231]="KillStreak-Battle-Royale-2",
}

local placeId = game.PlaceId
local gameName = "?"
pcall(function()
    local info = MS:GetProductInfo(placeId, Enum.InfoType.Game)
    gameName = info.Name or "?"
end)
local execName = "?"
pcall(function() execName = tostring((identifyexecutor())) end)
local routeHit = ROUTE[placeId]

-- ---------- 抓包 hook ----------
local logLines = {}   -- 屏显日志缓冲
local logBox, stat    -- 前置声明（addLog/onCapture 引用；UI 段赋值）

local function shortURL(u)
    -- 把冗长的域名前缀压缩，显示可区分的尾部
    u = tostring(u)
    u = u:gsub("https?://raw%.githubusercontent%.com/n0namevnnek%-web/", "『")
    u = u:gsub("https?://raw%.githubusercontent%.com/", "raw:")
    u = u:gsub("https?://", "")
    return u
end

local function addLog(s)
    table.insert(logLines, os.date("%H:%M:%S ") .. s)
    if #logLines > 30 then table.remove(logLines, 1) end
    if logBox then logBox.Text = table.concat(logLines, "\n") end
end

local function onCapture(via, url)
    table.insert(_G.__CAPTURED, { url = url, via = via, t = os.clock() })
    -- 完整 URL 存档，屏显用压缩格式（保留可区分尾部）
    addLog(("#%d [%s] %s"):format(#_G.__CAPTURED, via, shortURL(url)))
    stat.Text = ("已抓取 %d 条 — 点日志行可复制该条")
        :format(#_G.__CAPTURED):gsub(" — 点日志行可复制该条$", "") .. "（点日志行可复制单条）"
    tryClip(url)  -- 自动复制最新一条
end

-- ---------- UI ----------
local gui = Instance.new("ScreenGui")
gui.Name = "NNVNRecon"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(440, 360)
panel.Position = UDim2.new(1, -444, 0, 8)
panel.BackgroundColor3 = Color3.fromRGB(10, 12, 20)
panel.BackgroundTransparency = 0.08
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
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🛰 NNVN 侦察台"
title.Parent = panel

-- 信息区
local info = Instance.new("TextLabel")
info.Size = UDim2.new(1, -16, 0, 72)
info.Position = UDim2.fromOffset(8, 28)
info.BackgroundColor3 = Color3.fromRGB(20, 26, 40)
info.BorderSizePixel = 0
info.Font = Enum.Font.Code
info.TextSize = 12
info.TextColor3 = Color3.fromRGB(230, 230, 255)
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.Text = ""
info.Parent = panel
local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = info

-- 日志区
logBox = Instance.new("TextLabel")
logBox.Size = UDim2.new(1, -16, 1, -222)
logBox.Position = UDim2.fromOffset(8, 104)
logBox.BackgroundColor3 = Color3.fromRGB(6, 8, 14)
logBox.BorderSizePixel = 0
logBox.Font = Enum.Font.Code
logBox.TextSize = 11
logBox.TextColor3 = Color3.fromRGB(160, 255, 170)
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Bottom
logBox.Text = "(等待抓包…)"
logBox.Parent = panel
local c3 = Instance.new("UICorner"); c3.CornerRadius = UDim.new(0, 6); c3.Parent = logBox

-- 状态条
stat = Instance.new("TextLabel")
stat.Size = UDim2.new(1, -16, 0, 18)
stat.Position = UDim2.fromOffset(8, 104)
stat.BackgroundTransparency = 1
stat.Font = Enum.Font.GothamBold
stat.TextSize = 12
stat.TextColor3 = Color3.fromRGB(255, 220, 120)
stat.TextXAlignment = Enum.TextXAlignment.Left
stat.Text = "已抓取 0 条"
stat.Parent = panel

-- 按钮工厂
local function mkBtn(text, x, y, w, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w or 128, 30)
    b.Position = UDim2.new(x, 8, 1, y)
    b.BackgroundColor3 = color
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Text = text
    b.Parent = panel
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
    return b
end

local btnForce = mkBtn("🚀 强制触发第四级", 0,   -38, 200, Color3.fromRGB(180, 80, 30))
local btnCopy  = mkBtn("📋 复制全部",       0.48, -38, 130, Color3.fromRGB(40, 100, 190))
local btnLast  = mkBtn("📌 复制最后一条",   0,    -104, 150, Color3.fromRGB(120, 80, 40))
local btnSave  = mkBtn("💾 保存",           0,    -72, 96,  Color3.fromRGB(40, 140, 80))
local btnRerun = mkBtn("▶ 重跑 Loader",     0.25, -72, 110, Color3.fromRGB(90, 60, 160))
local btnClose = mkBtn("✕",                0.55, -72, 40,  Color3.fromRGB(150, 50, 50))

-- 填充信息
task.delay(0.2, function()
    local verdict
    if routeHit then
        verdict = ("✅ 命中路由 → %s"):format(routeHit)
    else
        verdict = "❌ 不在 NNVN 路由表 → Loader 会静默退出"
    end
    info.Text = ("PlaceId: %s\n游戏: %s\n执行器: %s\n路由判定: %s")
        :format(tostring(placeId), gameName, execName, verdict)
    addLog("侦察台就绪。当前游戏: " .. gameName)
    if routeHit then
        addLog("命中路由: " .. routeHit)
    else
        addLog("本游戏不在路由表 → 用『强制触发』按钮抓第四级")
    end
end)

-- ---------- hooks ----------
pcall(function()
    local old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if m == "HttpGet" or m == "GetAsync" or m == "PostAsync"
           or m == "RequestAsync" or m == "GetObjects" then
            local a = { ... }
            onCapture(m, tostring(a[1]))
        end
        return old(self, ...)
    end))
    addLog("✅ namecall hook 已装")
end)

pcall(function()
    local g = (getgenv and getgenv()) or _G
    for _, n in ipairs({ "request", "http_request", "syn_request" }) do
        local f = rawget(g, n)
        if type(f) == "function" and hookfunction then
            local oldF = hookfunction(f, newcclosure(function(...)
                local a = { ... }
                local u = "?"
                if type(a[1]) == "table" and a[1].Url then u = tostring(a[1].Url)
                elseif type(a[1]) == "string" then u = a[1] end
                onCapture(n, u)
                return oldF(...)
            end))
            addLog("✅ hook 全局函数: " .. n)
        end
    end
    if type(http) == "table" and type(http.request) == "function" and hookfunction then
        local oldH = hookfunction(http.request, newcclosure(function(...)
            local a = { ... }
            if type(a[1]) == "table" and a[1].Url then
                onCapture("http.request", tostring(a[1].Url))
            end
            return oldH(...)
        end))
        addLog("✅ hook http.request")
    end
end)

-- ---------- 按钮 action ----------
btnForce.MouseButton1Click:Connect(function()
    addLog("🚀 强制加载 Forsaken Key.lua …")
    stat.Text = "触发中…"
    local ok, err = pcall(function()
        local src = game:HttpGet("https://raw.githubusercontent.com/n0namevnnek-web/Forsaken/refs/heads/main/Key.lua")
        local f = loadstring(src)
        if f then f() end
    end)
    if ok then
        addLog("Key.lua 执行完毕（无报错）")
    else
        addLog("Key.lua 报错(正常,游戏不匹配): " .. tostring(err):sub(1, 60))
    end
    stat.Text = ("已抓取 %d 条"):format(#_G.__CAPTURED)
end)

btnLast.MouseButton1Click:Connect(function()
    local n = #_G.__CAPTURED
    if n == 0 then btnLast.Text = "无记录"; task.wait(1); btnLast.Text = "📌 复制最后一条" return end
    local e = _G.__CAPTURED[n]
    if tryClip(("#%d [%s] %s"):format(n, e.via, e.url)) then
        btnLast.Text = "✅ #" .. n
        print(("[侦察台] 最后一条 #%d: [%s] %s"):format(n, e.via, e.url))
    else
        print(("[侦察台] 最后一条 #%d: [%s] %s"):format(n, e.via, e.url))
        btnLast.Text = "看控制台"
    end
    task.wait(1.4); btnLast.Text = "📌 复制最后一条"
end)

btnCopy.MouseButton1Click:Connect(function()
    local s = fmtAll()
    if s == "" then btnCopy.Text = "无记录"; task.wait(1); btnCopy.Text = "📋 复制全部" return end
    if tryClip(s) then
        btnCopy.Text = "✅ 已复制"
        print("[侦察台] 全量:\n" .. s)
    else
        btnCopy.Text = "❌ 剪贴板不可用(看控制台)"
        print("[侦察台] 全量:\n" .. s)
    end
    task.wait(1.5); btnCopy.Text = "📋 复制全部"
end)

btnSave.MouseButton1Click:Connect(function()
    local s = fmtAll()
    if s == "" then btnSave.Text = "无记录"; task.wait(1); btnSave.Text = "💾 保存" return end
    if type(writefile) == "function" then
        local name = ("NNVN_urls_%d.txt"):format(os.time())
        local ok = pcall(function() writefile(name, s) end)
        btnSave.Text = ok and ("✅ " .. name) or "❌ 写入失败"
        if ok then addLog("已保存: workspace/" .. name) end
    else
        btnSave.Text = "❌ 无 writefile"
        addLog("此执行器无 writefile，请用复制按钮")
    end
    task.wait(1.8); btnSave.Text = "💾 保存"
end)

btnRerun.MouseButton1Click:Connect(function()
    addLog("▶ 重跑官方 Loader …")
    pcall(function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/n0namevnnek-web/NNVN-Hub/refs/heads/main/Loader.lua"))()
    end)
end)

btnClose.MouseButton1Click:Connect(function()
    _G.__NNVN_RECON = nil
    gui:Destroy()
end)

-- 自测
task.delay(0.6, function()
    pcall(function() game:HttpGet("http://127.0.0.1:9/__selftest") end)
    addLog("自测完成（#1 即自测）")
end)

print("🛰 NNVN 侦察台已装载（屏幕右侧面板）")
