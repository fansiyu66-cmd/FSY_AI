-- NNVN Hub | Fishing Master v1.4.8 | Smart AutoSell + EntitlementConfig


local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:FindFirstChild("Events")
local Data = ReplicatedStorage:FindFirstChild("Data")

-- ============================================================
-- FUNCTION 1: setupState — State + constants
-- ============================================================
local function setupState()
    local S = {
        AutoClickFish = false, AutoPullMinigame = false,
        AutoUseSkillsAtExecute = false, AutoUseSkills = false,
        AutoXMultiplier = 10, AutoCast = false, AutoEquipRod = false,
        AutoPerfectCast = false, AutoDismissPopup = true,
        AutoSell = false, AutoSellInterval = false, AutoSellWhenFull = false, AutoLockFish = false,
        AutoMissFilteredFish = true, AutoActionBusy = false, AutoActionBusyName = "",
        AutoBuyRod = false, AutoFarmLevel = false, AutoPerfect = false,
        AutoUnlockIsland = false, AutoClaimRewards = false,
        AutoSkillGacha = false, AutoAuraGacha = false, AutoCrate = false,
        AutoWeatherWebhook = true, AutoFarmBoss = false,
        -- Boss advanced features
        AutoTweenOnBossSpawn = false,
        AutoSkillOnBossPhase = false,
        AutoDodgeBossRoar = false,
        BossRegionESP = false,
        BossSpawnAlert = true,
        BossDespawnAlert = true,
        BossWebhookEnabled = false,
        BossWebhookUrl = "",
        BossCaughtCount = 0,
        WalkOnWater = false, BoatSpeedEnabled = false, AutoBoatForward = false,
        NoFog = false, UnlockFarView = false,
        AvatarSparkles = false,
        FakeStats = false, FakeLeaderboard = false,
        ESPPlayers = false, ESPNPCs = false, ESPFish = false, ESPGuides = false, ESPBox = false,
        ESPColorPlayers = Color3.fromRGB(80, 170, 255),
        ESPColorNPCs = Color3.fromRGB(255, 210, 90),
        ESPColorFish = Color3.fromRGB(90, 255, 200),
        ESPColorGuides = Color3.fromRGB(210, 120, 255),
        ESPColorBox = Color3.fromRGB(255, 80, 80),
        MapXRay = false, TweenBeforeActions = true,
        Streamer = false, StreamerAllPlayers = false,
        Fly = false, Noclip = false, FullBright = false, InfiniteJump = false,
        SafeFarmInvisible = false,
        FreezePlayer = false,
        BypassAntiCheat = true,
        AntiAFK = true,
        InfoBarEnabled = true,
        InfoShowGameName = true, InfoShowPing = true, InfoShowFPS = true,
        InfoShowIsland = true, InfoShowDismiss = true,
        Clicks = 0, Casts = 0, Skills = 0, Sells = 0, Codes = 0, RodBuys = 0,
        SelectedIsland = "Starter Island", SelectedChest = "Ocean Chest",
        SelectedFish = "All", SelectedLockFish = "All", SelectedLockRarity = "All",
        SelectedRod = "stone_rod", SelectedSkin = "None",
        FakeCoin = "999,999,999", FakeGem = "999,999",
        SkillOrder = "Z,X,C,V", SavedPosition = nil, FakeName = "NNVN Hub",
        TweenSpeed = 20, TweenHeight = 5,
        CastHoldMin = 0.35, CastHoldMax = 0.65,
        AutoCastDelay = 0.35,
        ClickDelay = 0.12, PullDelay = 0.08,
        ExecutePercent = 0.25,
        WalkSpeed = 24, JumpPower = 50, FlySpeed = 60, BoatSpeed = 120,
        SelectedUnlockIsland = "Jungle Island", ESPDistance = 2500,
        GachaDelay = 3, AuraDelay = 3, CrateDelay = 3,
        SellIntervalMinutes = 3, SellIntervalSeconds = 0,
        StopCoin = 0, StopGem = 0,
        DiscordOnline = "Unknown", DiscordMembers = "Unknown",
        JoinJobId = "",
        TeleportMode = "Fast Travel", SelectedVehicle = "Truck - Free",
        SellMethod = "SellAll (at NPC)",
        PriorityFarm = 50, PriorityAutoSell = 90, PriorityFishFilter = 60, PriorityAutoLock = 45,
        PriorityShop = 35, PriorityAutoQuest = 40, PriorityBoss = 55, PriorityRewards = 25,
        AutoQuestEnabled = false,
        AutoQuestFarm = true,
        AutoQuestBuyRod = true,
        AutoQuestVerbose = true,
        AutoQuestCurrentTarget = nil,
        AutoQuestLastCompleteAt = 0,
        AutoQuestDelay = 4,
        AutoQuestBlacklist = {},
        AutoSetFilterPerQuest = true,
        AutoCoinFarmPerQuest = true,
        _autoQuestFilterFor = nil,
        _autoQuestSellFor = nil,
        ManualFishLimit = 0, -- 0 = EntitlementConfig, >0 = force limit
        SkillGachaCurrency = "Coin", SkillGachaCount = 1,
        FishFilterSelectedFish = "All",
        FishFilterRarityInput = "",
        FishFilterRarities = {},
        FishFilterName = "",
        FishFilterMinWeight = 0,
        FishFilterMaxWeight = 100000,
        FishFilterHugeOnly = false,
        FishFilterLockMode = "All",
        AutoLockFiltered = false,
        AuraGachaCount = 1, CrateCount = 1,
        LockedUids = {},
        SelectedLanguage = "English",
        IndexPreview = false,
        BossHistory = {},
        SelectedBossRegion = "",
    }
    local Status = {}
    local Paragraphs = {}

    local IslandPaths = {
        ["Starter Island"]="island_starter", ["Jungle Island"]="island_jungle",
        ["Desert Island"]="island_desert", ["Snow Island"]="island_snow",
        ["Volcano Island"]="island_volcano", ["Fossil Island"]="island_fossil",
    }
    local IslandDisplayNames = {}
    for display, id in pairs(IslandPaths) do IslandDisplayNames[id] = display end

    local UnlockIslandIds = {
        ["Jungle Island"]=2, ["Desert Island"]=3, ["Snow Island"]=4,
        ["Volcano Island"]=5, ["Fossil Island"]=6,
    }

    local RodShopFallback = {
        stone_rod={price=3000,islandId="island_starter"},
        iron_rod={price=12000,islandId="island_starter"},
        golden_rod={price=35000,islandId="island_jungle"},
        steel_rod={price=90000,islandId="island_jungle"},
        golden_steel_rod={price=220000,islandId="island_desert"},
        diamond_steel_rod={price=520000,islandId="island_desert"},
        taoist_rod={price=1300000,islandId="island_snow"},
        legacy_rod={price=3000000,islandId="island_snow"},
    }

    return {
        S = S, Status = Status, Paragraphs = Paragraphs,
        IslandPaths = IslandPaths, IslandDisplayNames = IslandDisplayNames,
        UnlockIslandIds = UnlockIslandIds, RodShopFallback = RodShopFallback,
    }
end

-- ============================================================
-- FUNCTION 2: setupCore — helpers, Window, Language, loops
-- ============================================================
local function setupCore(env)
    local S = env.S
    local Status = env.Status
    local Paragraphs = env.Paragraphs
    local IslandPaths = env.IslandPaths
    local IslandDisplayNames = env.IslandDisplayNames
    local UnlockIslandIds = env.UnlockIslandIds
    local RodShopFallback = env.RodShopFallback

    -- ============ BASIC HELPERS ============
    local function trim(v) return (tostring(v or ""):gsub("^%s+",""):gsub("%s+$","")) end
    local function getChar() return LocalPlayer.Character end
    local function getRoot() local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end
    local function getHumanoid() local c = getChar() return c and c:FindFirstChildOfClass("Humanoid") end

    local function setPathText(root, path, value)
        pcall(function()
            local node = root
            for part in tostring(path):gmatch("[^%.]+") do node = node and node:FindFirstChild(part) end
            if node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox")) then
                node.Text = tostring(value)
            end
        end)
    end

    local function cleanStatusText(text)
        local s = tostring(text or "空闲")
        local replacements = {
            ["EntitlementConfig%.FishCapacity"] = "Auto capacity detection",
            ["EntitlementConfig"] = "Auto capacity detection",
            ["FishCapacity"] = "capacity check",
            ["SellController"] = "sell service",
            ["FishingController"] = "fishing service",
            ["FastTravelController"] = "travel service",
            ["QuestController"] = "quest service",
            ["PlayerDataV2Controller"] = "data service",
            ["SkillGachaController"] = "skill shop",
            ["AuraGachaController"] = "aura shop",
            ["CrateGachaController"] = "crate shop",
            ["CodeRedeemController"] = "code service",
            ["FishingRodShopController"] = "rod shop",
            ["ReplicatedStorage"] = "game service",
            ["PlayerGui"] = "game UI",
            ["workspace"] = "map",
            ["HumanoidRootPart"] = "target point",
            ["HRP"] = "target point",
            ["CFrame"] = "position",
            ["npc_fish_seller_1"] = "Fish Seller",
            ["npc_rod_shop_starter"] = "Rod Seller",
            ["npc_gacha_book"] = "Skill Shop",
            ["npc_gacha_aura"] = "Aura Shop",
            ["crate_ocean_chest_1"] = "Ocean Chest",
            ["crate_dragon_chest_1"] = "Dragon Chest",
            ["SellAll"] = "Sell All",
            ["SellHeld"] = "Sell Held",
            ["backpackIsFull"] = "backpack check",
        }
        for pattern, value in pairs(replacements) do
            s = s:gsub(pattern, value)
        end
        s = s:gsub("UID:%s*[%w_%-]+", "Selected item")
        s = s:gsub("Sell Held%([^%)]-%)", "Sell Held")
        s = s:gsub("npc_[%w_%-]+", "NPC")
        s = s:gsub("workspace%.[%w_%.%[%]\"'_%-]+", "map target")
        s = s:gsub("game:GetService%([^%)]-%)", "game service")
        s = s:gsub("via%s+Auto capacity detection", "using auto capacity")
        return s
    end

    local function setStatus(key, text)
        Status[key] = cleanStatusText(text)
        local p = Paragraphs[key]
        if p and p.SetDesc then pcall(function() p:SetDesc(Status[key]) end) end
    end

    local function notify(title, content)
        if getgenv().NNVN_WindUI and getgenv().NNVN_WindUI.Notify then
            pcall(function()
                getgenv().NNVN_WindUI:Notify({ Title=title, Content=cleanStatusText(content), Duration=3 })
            end)
        end
    end

    local function getJobIdText() return tostring(game.JobId or "") end

    local function copyText(text)
        text = tostring(text or "")
        return pcall(function()
            if type(setclipboard) == "function" then setclipboard(text) return end
            if type(toclipboard) == "function" then toclipboard(text) return end
            error("clipboard unavailable")
        end)
    end

    local function rejoinCurrentJob()
        setStatus("job", "Rejoining current JobId...")
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end)
    end

    local function joinJobId(jobId)
        jobId = trim(jobId or S.JoinJobId or "")
        if jobId == "" then setStatus("job", "请先输入服务器 ID") return end
        setStatus("job", "Joining JobId: " .. jobId)
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
        end)
    end

    -- ============ BOSS DETECTION ============
    local function scanBossSpawners()
        local result = {}
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        if not islands then return result end
        for _, island in ipairs(islands:GetChildren()) do
            local br = island:FindFirstChild("BossRegions")
            if br then
                for _, region in ipairs(br:GetChildren()) do
                    local fx = region:FindFirstChild("BossSpawnerFX")
                    if fx and fx:IsA("BasePart") then
                        table.insert(result, {
                            islandId = island.Name,
                            islandDisplay = IslandDisplayNames[island.Name] or island.Name,
                            regionName = region.Name,
                            position = fx.Position, cf = fx.CFrame,
                            active = true, fx = fx,
                        })
                    end
                end
            end
        end
        return result
    end

        -- ⭐ Extended scan: dùng Catalog.BossRegion → biết đủ 12 regions
    local function scanBossSpawnersExtended()
        local result = {}

        -- Load catalog
        local ok, BossRegionCatalog = pcall(function()
            return require(ReplicatedStorage.Data.Catalog.BossRegion)
        end)

        -- Nếu không load được catalog → fallback code cũ
        if not ok or type(BossRegionCatalog) ~= "table" then
            return scanBossSpawners()
        end

        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")

        for regionId, regionData in pairs(BossRegionCatalog) do
            local islandId = regionData.fallbackIslandId
            local island = islands and islands:FindFirstChild(islandId)
            local regionPart = nil
            local active = false
            local fx = nil
            local pos, cf = nil, nil

            if island then
                local bossRegions = island:FindFirstChild("BossRegions")
                if bossRegions then
                    local region = bossRegions:FindFirstChild(regionId)
                    if region then
                        regionPart = region
                        fx = region:FindFirstChild("BossSpawnerFX")
                        active = fx ~= nil and fx:IsA("BasePart")
                        if active then
                            pos = fx.Position
                            cf = fx.CFrame
                        else
                            -- Lấy vị trí region để có thể tween tới khi offline
                            local pivotOk, pivot = pcall(function() return region:GetPivot() end)
                            if pivotOk then
                                pos = pivot.Position
                                cf = pivot
                            end
                        end
                    end
                end
            end

            table.insert(result, {
                islandId      = islandId,
                islandDisplay = IslandDisplayNames[islandId] or islandId,
                regionId      = regionId,
                regionName    = regionData.name,
                position      = pos,
                cf            = cf,
                active        = active,
                fx            = fx,
                exists        = regionPart ~= nil,
                region        = regionPart,
            })
        end

        -- Sort theo island display name để hiển thị đẹp
        table.sort(result, function(a, b)
            if a.islandDisplay ~= b.islandDisplay then
                return a.islandDisplay < b.islandDisplay
            end
            return a.regionId < b.regionId
        end)

        return result
    end

    env.scanBossSpawnersExtended = scanBossSpawnersExtended

    local function getActiveBossSpawner()
        for _, info in ipairs(scanBossSpawners()) do
            if info.active then return info end
        end
        return nil
    end

    local function getIslandForPosition(pos)
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        if not islands then return "Unknown" end
        local best, bestDist = "Unknown", math.huge
        for _, island in ipairs(islands:GetChildren()) do
            local zones = island:FindFirstChild("Zones")
            local part = zones and zones:FindFirstChild("Part")
            if part then
                local half = part.Size / 2
                local ipos = part.Position
                if math.abs(pos.X - ipos.X) <= half.X and math.abs(pos.Z - ipos.Z) <= half.Z then
                    local dist = (pos - ipos).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        best = IslandDisplayNames[island.Name] or island.Name
                    end
                end
            end
        end
        if best == "Unknown" then
            for _, island in ipairs(islands:GetChildren()) do
                local sp = island:FindFirstChild("SpawnPoint")
                local spawner = sp and sp:FindFirstChildWhichIsA("BasePart", true)
                if spawner then
                    local d = (pos - spawner.Position).Magnitude
                    if d < bestDist then bestDist = d; best = IslandDisplayNames[island.Name] or island.Name end
                end
            end
        end
        return best
    end

    -- Boss Status HUD removed (user request)
    local function ensureBossStatusLabel()
        local existing = PlayerGui:FindFirstChild("NNVN_BossStatusGui")
        if existing then existing:Destroy() end
        return nil
    end
    local function updateBossStatusLabel(_spawners)
        -- no-op: floating boss HUD disabled
        local existing = PlayerGui:FindFirstChild("NNVN_BossStatusGui")
        if existing then existing:Destroy() end
    end

    -- ============ WEATHER WEBHOOKS ============
    local WeatherWebhooks = {
        { Key="blood_moon", Name="Blood Moon", Emoji="🌕", Gui="weather_blood_moon", Color=0x9B1C31,
          Url="https://discord.com/api/webhooks/1553280611823915031/6e6cy4CeZfBwFAzAsoBdyNOzGWiGGXx8O1t-vy9QxD0OgVQLhrT7X180dNmY-MBaQKV7" },
        { Key="rain", Name="Rain", Emoji="🌧️", Gui="weather_rain", Color=0x3498DB,
          Url="https://discord.com/api/webhooks/1553280854044844092/z4qaAhf3sg0dfv32mSGOYkdsMXEGQstlx27QEdGDXbfH6xwY-XIY01LMVh7D6HHW06Em" },
        { Key="rainbow_rain", Name="Rainbow Rain", Emoji="🌈", Gui="weather_rainbow_rain", Color=0xF1C40F,
          Url="https://discord.com/api/webhooks/1553281010928582718/SXM65CWsshh45aWPR-fZoXluT1PUsDdA9m0BB0kdcZItjVTMcyy6_ikFU93Mknjsoida" },
        { Key="snowfall", Name="Snowfall", Emoji="❄️", Gui="weather_snowfall", Color=0xDFF6FF,
          Url="https://discord.com/api/webhooks/1553281172308754454/JqpJTRZQBMPKWwJMcN_Sclfpw9tDfADUNp__CPFd5xTNIYFwbOLCiWTZ3TvmAVLIRoDq" },
        { Key="thunderstorm", Name="Thunderstorm", Emoji="⛈️", Gui="weather_thunderstorm", Color=0x6C5CE7,
          Url="https://discord.com/api/webhooks/1553281294081720441/1JGwsdktcbEn6c0VY251MhLJUBupkWv33zG_0EN2jYMQqFORX8D0VOZZf410fnmBrj1H" },
        { Key="void_storm", Name="Void Storm", Emoji="🌀", Gui="weather_void_storm", Color=0x8E44AD,
          Url="https://discord.com/api/webhooks/1553281399170146484/BKdfAu3U67EIOl9NC4Ykn04WyVb0HkdmxHBIqWXZ7FG9-MKedAiD-Bis9HdMjhlxxl8B" },
    }
    local WeatherSent = {}

    local function requestHttp(payload)
        local req = (syn and syn.request) or (http and http.request) or http_request or request
        if type(req) ~= "function" then return false end
        return pcall(req, payload)
    end

    local function fetchDiscordStats()
        local ok, res = requestHttp({
            Url = "https://discord.com/api/v9/invites/5JJAuHRUgJ?with_counts=true",
            Method = "GET",
            Headers = { ["User-Agent"] = "NNVN Hub" },
        })
        if not ok or type(res) ~= "table" then return false end
        local body = res.Body or res.body
        if type(body) ~= "string" or body == "" then return false end
        local okDecode, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not okDecode or type(data) ~= "table" then return false end
        S.DiscordOnline = tostring(data.approximate_presence_count or S.DiscordOnline or "Unknown")
        S.DiscordMembers = tostring(data.approximate_member_count or S.DiscordMembers or "Unknown")
        return true
    end

    local function weatherNode(guiName)
        local events = PlayerGui:FindFirstChild("Events")
        local holder = events and events:FindFirstChild("Frame") and events.Frame:FindFirstChild("Holder")
        return holder and holder:FindFirstChild(guiName)
    end

    local function weatherTimeLeft(node)
        local label = node and node:FindFirstChild("TextLabel")
        if label and label:IsA("TextLabel") then return tostring(label.Text) end
        return "Unknown"
    end

    local function sendWeatherWebhook(info, timeLeft)
        local body = {
            username = "NNVN Hub", avatar_url = "",
            embeds = {{
                title = ("%s %s Event Detected"):format(info.Emoji, info.Name),
                description = "Fishing Master weather alert",
                color = info.Color,
                fields = {
                    { name="Weather",   value=("%s %s"):format(info.Emoji, info.Name), inline=true },
                    { name="Time Left", value=tostring(timeLeft or "Unknown"), inline=true },
                    { name="Players",   value=("%d/%d"):format(#Players:GetPlayers(), Players.MaxPlayers), inline=true },
                    { name="PlaceId",   value=tostring(game.PlaceId), inline=true },
                    { name="JobId",     value=("`%s`"):format(getJobIdText()), inline=false },
                },
                footer = { text="NNVN Hub | No player name included" },
                timestamp = DateTime.now():ToIsoDate(),
            }},
        }
        return requestHttp({
            Url = info.Url, Method = "POST",
            Headers = { ["Content-Type"]="application/json" },
            Body = HttpService:JSONEncode(body),
        })
    end

    local function scanWeatherWebhooks(force)
        local active = {}
        for _, info in ipairs(WeatherWebhooks) do
            local node = weatherNode(info.Gui)
            local visible = node and node.Visible == true
            local timeLeft = weatherTimeLeft(node)
            active[#active+1] = ("%s %s: %s"):format(info.Emoji, info.Name, visible and timeLeft or "hidden")
            if visible and (force or not WeatherSent[info.Key]) then
                WeatherSent[info.Key] = true
                local ok = sendWeatherWebhook(info, timeLeft)
                setStatus("webhook", ok and ("Sent: "..info.Name) or ("Failed: "..info.Name))
                task.wait(0.2)
            elseif not visible then
                WeatherSent[info.Key] = false
            end
        end
        if force then setStatus("webhook", "Scanned: "..table.concat(active," | ")) end
    end

    -- ============ PREMIUM ============
    local function refreshPremiumAccess()
        local premium = rawget(_G,"NNVN_IsPremium")==true or getgenv().NNVN_IsPremium==true
            or rawget(_G,"SCRIPT_IsPremium")==true or getgenv().SCRIPT_IsPremium==true
        getgenv().NNVN_IsPremiumAccess = premium
        S.IsPremium = premium
        return premium
    end

    local function premiumSourceText()
        if rawget(_G,"NNVN_IsPremium")==true then return "_G.NNNVN_IsPremium" end
        if getgenv().NNVN_IsPremium==true then return "getgenv().NNVN_IsPremium" end
        if rawget(_G,"SCRIPT_IsPremium")==true then return "_G.SCRIPT_IsPremium" end
        if getgenv().SCRIPT_IsPremium==true then return "getgenv().SCRIPT_IsPremium" end
        return "Free key / no premium flag"
    end

    local function accessText()
        local premium = refreshPremiumAccess()
        return ("Tier: %s\nDetected by: %s"):format(premium and "PREMIUM" or "FREE", premiumSourceText())
    end

    -- ============ STARDUST ============
    local function getStardustClient()
        local stardust = ReplicatedStorage:FindFirstChild("Stardust")
        if not stardust then return nil end
        local ok, mod = pcall(require, stardust)
        if not ok or type(mod) ~= "table" then return nil end
        return mod.Client
    end

    local function getFishingController()
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("FishingController") end)
        if ok and type(ctrl) == "table" then return ctrl end
        return nil
    end

    local function getFishState()
        local ctrl = getFishingController()
        if not ctrl then return nil end
        local ok, state = pcall(function() return ctrl:GetState() end)
        return ok and state or nil
    end

    local function getFishInfo()
        local ctrl = getFishingController()
        if not ctrl then return nil, nil, nil end
        local ok, id, hp, maxHp = pcall(function()
            local a,b,c = ctrl:GetFishInfo() return a,b,c
        end)
        if ok then return id, hp, maxHp end
        return nil, nil, nil
    end

    -- ============ INPUT SIM ============
    local function simulateClick()
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(0,0,0,true,game,0)
            task.wait(0.03)
            VirtualInputManager:SendMouseButtonEvent(0,0,0,false,game,0)
        end)
    end

    local function simulateClickAt(x, y)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(x,y,0,true,game,0)
            task.wait(0.03)
            VirtualInputManager:SendMouseButtonEvent(x,y,0,false,game,0)
        end)
    end

    local function simulateHold(duration)
        pcall(function() VirtualInputManager:SendMouseButtonEvent(0,0,0,true,game,0) end)
        task.wait(duration)
        pcall(function() VirtualInputManager:SendMouseButtonEvent(0,0,0,false,game,0) end)
    end

    local function simulateKey(keyCode)
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.03)
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end

    -- ============ PERFECT CAST ============
    local PerfectCast = { Enabled=false, Meta=nil, OldFire=nil, Count=0 }
    local _luckBarUI, _perfectFX
    local function getFishingControllerModule(name)
        local controllers = ReplicatedStorage:FindFirstChild("Controllers")
        local fishing = controllers and controllers:FindFirstChild("FishingController")
        local mod = fishing and fishing:FindFirstChild(name)
        if mod and mod:IsA("ModuleScript") then
            local ok, value = pcall(require, mod)
            if ok then return value end
        end
        return nil
    end
    local function getLuckBarUI()
        if _luckBarUI ~= nil then return _luckBarUI end
        _luckBarUI = getFishingControllerModule("LuckBarUI") or false
        return _luckBarUI ~= false and _luckBarUI or nil
    end
    local function getPerfectFX()
        if _perfectFX ~= nil then return _perfectFX end
        _perfectFX = getFishingControllerModule("PerfectFX") or false
        return _perfectFX ~= false and _perfectFX or nil
    end
    local function showPerfectFallback()
        local gui = PlayerGui:FindFirstChild("NNVN_PerfectLuckBar")
        if not gui then
            gui = Instance.new("ScreenGui")
            gui.Name = "NNVN_PerfectLuckBar"
            gui.IgnoreGuiInset = true
            gui.ResetOnSpawn = false
            gui.Parent = PlayerGui
            local wrap = Instance.new("Frame")
            wrap.Name = "Wrap"
            wrap.AnchorPoint = Vector2.new(0.5, 0.5)
            wrap.Position = UDim2.fromScale(0.5, 0.68)
            wrap.Size = UDim2.fromOffset(260, 54)
            wrap.BackgroundColor3 = Color3.fromRGB(10, 13, 16)
            wrap.BackgroundTransparency = 0.08
            wrap.BorderSizePixel = 0
            wrap.Parent = gui
            Instance.new("UICorner", wrap).CornerRadius = UDim.new(0, 8)
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(255, 255, 255)
            stroke.Transparency = 0.35
            stroke.Parent = wrap
            local title = Instance.new("TextLabel")
            title.Name = "Title"
            title.BackgroundTransparency = 1
            title.Position = UDim2.fromOffset(0, 5)
            title.Size = UDim2.new(1, 0, 0, 24)
            title.Font = Enum.Font.GothamBlack
            title.Text = "PERFECT"
            title.TextColor3 = Color3.fromRGB(255, 255, 255)
            title.TextStrokeTransparency = 0.2
            title.TextSize = 19
            title.Parent = wrap
            local barBg = Instance.new("Frame")
            barBg.Name = "BarBg"
            barBg.Position = UDim2.fromOffset(16, 36)
            barBg.Size = UDim2.new(1, -32, 0, 7)
            barBg.BackgroundColor3 = Color3.fromRGB(55, 65, 72)
            barBg.BorderSizePixel = 0
            barBg.Parent = wrap
            Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)
            local bar = Instance.new("Frame")
            bar.Name = "Bar"
            bar.Size = UDim2.fromScale(1, 1)
            bar.BackgroundColor3 = Color3.fromRGB(95, 255, 170)
            bar.BorderSizePixel = 0
            bar.Parent = barBg
            Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
        end
        gui.Enabled = true
        local wrap = gui:FindFirstChild("Wrap")
        if wrap then
            wrap.Visible = true
            wrap.BackgroundTransparency = 0.08
        end
        task.delay(0.75, function()
            if gui and gui.Parent then gui.Enabled = false end
        end)
    end
    local function showPerfectCastPresentation()
        local root = getRoot()
        local usedNative = false
        local luck = getLuckBarUI()
        if luck then
            pcall(function()
                if type(luck.Setup) == "function" and LocalPlayer.Character then luck.Setup(LocalPlayer.Character) end
                if type(luck.SetVisible) == "function" then luck.SetVisible(true) end
                if type(luck.UpdateBar) == "function" then luck.UpdateBar(1) end
                if type(luck.UpdateColor) == "function" then luck.UpdateColor(1, true) end
                if type(luck.PlayGlow) == "function" then luck.PlayGlow() end
                usedNative = true
            end)
            task.delay(0.8, function()
                pcall(function()
                    if type(luck.SetVisible) == "function" then luck.SetVisible(false) end
                end)
            end)
        end
        local fx = getPerfectFX()
        if fx and root then
            pcall(function()
                if type(fx.Init) == "function" then fx.Init() end
                if type(fx.Play) == "function" then fx.Play(root) end
                usedNative = true
            end)
        end
        if not usedNative then showPerfectFallback() end
    end
    local function findPacketMeta()
        if PerfectCast.Meta then return PerfectCast.Meta end
        if not getgc then return nil end
        for _, mode in ipairs({true, false}) do
            for _, obj in pairs(getgc(mode)) do
                if type(obj) == "table" then
                    local name = rawget(obj, "Name")
                    local reads = rawget(obj, "Reads")
                    if type(name) == "string" and type(reads) == "table" then
                        local ok, mt = pcall(getrawmetatable, obj)
                        if ok and type(mt) == "table" and type(mt.Fire) == "function" then
                            PerfectCast.Meta = mt
                            return mt
                        end
                    end
                end
            end
        end
        return nil
    end
    local function enablePerfectCast(on)
        PerfectCast.Enabled = on
        if not on then
            if PerfectCast.OldFire and PerfectCast.Meta then
                pcall(setreadonly, PerfectCast.Meta, false)
                PerfectCast.Meta.Fire = PerfectCast.OldFire
                pcall(setreadonly, PerfectCast.Meta, true)
                PerfectCast.OldFire = nil
                setStatus("farm", "完美抛竿: 关闭")
            end
            return
        end
        local mt = findPacketMeta()
        if not mt then setStatus("farm","完美抛竿: 失败"); return end
        if PerfectCast.OldFire then setStatus("farm","完美抛竿: 开启"); return end
        PerfectCast.OldFire = mt.Fire
        local hooked = newcclosure(function(self, ...)
            local name = rawget(self, "Name")
            if name == "FishCast" and PerfectCast.Enabled then
                local args = { ... }
                args[1] = 1.0
                PerfectCast.Count += 1
                pcall(showPerfectCastPresentation)
                return PerfectCast.OldFire(self, table.unpack(args))
            end
            return PerfectCast.OldFire(self, ...)
        end)
        pcall(setreadonly, mt, false)
        local ok = pcall(function() mt.Fire = hooked end)
        pcall(setreadonly, mt, true)
        if not ok then PerfectCast.OldFire = nil; setStatus("farm","完美抛竿: 失败"); return end
        setStatus("farm", "完美抛竿: 开启")
    end

    -- ============ AUTO DISMISS POPUP ============
    local _popupBound = false
    local function findCatchPopup()
        for _, gui in ipairs(PlayerGui:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Enabled ~= false then
                for _, desc in ipairs(gui:GetDescendants()) do
                    if desc:IsA("TextLabel") and desc.Visible then
                        local t = tostring(desc.Text or ""):lower()
                        if t:find("fish caught",1,true) or t:find("caught!",1,true) or t:find("you caught",1,true) then
                            return gui
                        end
                    end
                end
            end
        end
        return nil
    end
    local function findDismissButton()
        for _, gui in ipairs(PlayerGui:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Enabled ~= false then
                local hasPopupText = false
                for _, d in ipairs(gui:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Visible and tostring(d.Text or ""):lower():find("caught",1,true) then
                        hasPopupText = true; break
                    end
                end
                if hasPopupText then
                    for _, desc in ipairs(gui:GetDescendants()) do
                        if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then
                            local n = tostring(desc.Name):lower()
                            if n:find("continue") or n:find("close") or n:find("dismiss") or n:find("ok") or n:find("next") or n:find("confirm") then
                                return desc
                            end
                        end
                    end
                    for _, desc in ipairs(gui:GetDescendants()) do
                        if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then return desc end
                    end
                end
            end
        end
        return nil
    end
    local function dismissPopupOnce()
        local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800,600)
        simulateClickAt(vp.X / 2, vp.Y / 2)
        task.wait(0.03)
        local btn = findDismissButton()
        if btn then
            pcall(function()
                btn.MouseButton1Click:Fire()
                btn.MouseButton1Down:Fire()
                btn.MouseButton1Up:Fire()
            end)
        end
    end
    local function bindAutoDismissPopup()
        if _popupBound then return end
        local Client = getStardustClient()
        if not Client then return end
        local fishing = Client.GetController("FishingController")
        if not fishing or not fishing.StateChanged then return end
        _popupBound = true
        fishing.StateChanged:Connect(function(newState)
            if newState ~= "Caught" and newState ~= "Escaped" then return end
            if not S.AutoDismissPopup then return end
            task.spawn(function()
                task.wait(0.15)
                for _ = 1, 25 do
                    if not S.AutoDismissPopup then break end
                    dismissPopupOnce()
                    task.wait(0.08)
                    if not findCatchPopup() then break end
                end
            end)
        end)
    end
    task.spawn(function()
        for _ = 1, 60 do
            if getStardustClient() then bindAutoDismissPopup(); break end
            task.wait(0.2)
        end
    end)
    task.spawn(function()
        while task.wait(0.3) do
            if S.AutoDismissPopup and (S.AutoCast or S.AutoClickFish or S.AutoPullMinigame) then
                if findCatchPopup() then
                    local state = getFishState()
                    if state == "Caught" or state == "Escaped" then dismissPopupOnce() end
                end
            end
        end
    end)

    -- ============ TWEEN (Steal-an-Egg style velocity engine + full restore) ============
    -- Uses continuous velocity toward target (not CFrame lock alone) to avoid rubberband.

    local TweenConn, CurrentTween
    local TweenActive = false
    local TweenSaved = nil -- restore snapshot

    local function captureTweenState(root, hum)
        local parts = {}
        local char = getChar()
        if char then
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then
                    parts[p] = p.CanCollide
                end
            end
        end
        return {
            platformStand = hum and hum.PlatformStand or false,
            autoRotate = hum and hum.AutoRotate ~= false,
            walkSpeed = hum and hum.WalkSpeed or 16,
            jumpPower = (hum and (hum.UseJumpPower and hum.JumpPower or hum.JumpHeight)) or 50,
            useJumpPower = hum and hum.UseJumpPower or false,
            parts = parts,
            anchored = root and root.Anchored or false,
        }
    end

    local function restoreTweenState()
        local root = getRoot()
        local hum = getHumanoid()
        local snap = TweenSaved
        TweenSaved = nil
        if not snap then
            -- soft restore defaults
            if hum then
                pcall(function()
                    hum.PlatformStand = false
                    hum.Sit = false
                    hum.AutoRotate = true
                end)
            end
            if root then
                pcall(function()
                    root.Anchored = false
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end)
                local clip = root:FindFirstChild("NNVN_BodyClip")
                if clip then pcall(function() clip:Destroy() end) end
                local bg = root:FindFirstChild("NNVN_BodyGyro")
                if bg then pcall(function() bg:Destroy() end) end
            end
            local char = getChar()
            if char then
                for _, p in ipairs(char:GetDescendants()) do
                    if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                        -- leave as-is if no snapshot
                    end
                end
            end
            return
        end
        if hum then
            pcall(function()
                hum.PlatformStand = snap.platformStand == true
                hum.Sit = false
                hum.AutoRotate = snap.autoRotate ~= false
                if type(snap.walkSpeed) == "number" and snap.walkSpeed > 0 then
                    hum.WalkSpeed = snap.walkSpeed
                end
                pcall(function()
                    if snap.useJumpPower then
                        hum.JumpPower = tonumber(snap.jumpPower) or 50
                    end
                end)
                hum:ChangeState(Enum.HumanoidStateType.Freefall)
            end)
        end
        if root then
            pcall(function()
                root.Anchored = false
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
            local clip = root:FindFirstChild("NNVN_BodyClip")
            if clip then pcall(function() clip:Destroy() end) end
            local bg = root:FindFirstChild("NNVN_BodyGyro")
            if bg then pcall(function() bg:Destroy() end) end
        end
        if snap.parts then
            for part, coll in pairs(snap.parts) do
                if part and part.Parent then
                    pcall(function() part.CanCollide = coll end)
                end
            end
        end
    end

    local function stopTween()
        TweenActive = false
        if CurrentTween then pcall(function() CurrentTween:Cancel() end) end
        CurrentTween = nil
        if TweenConn then pcall(function() TweenConn:Disconnect() end) end
        TweenConn = nil
        restoreTweenState()
    end

    -- Steal-an-Egg inspired: velocity fly-to + optional CFrame assist, full restore on stop
        -- Steal-an-Egg style smooth tween + anticheat bypass
    -- ============ ANTI-TELEPORT BYPASS (Steal-an-Egg style) ============
    local _antiTpScriptsDisabled = false
    local function applyAntiTeleportBypass()
        if S.BypassAntiCheat == false then return end
        -- 1. Tắt attribute anti-teleport chung
        pcall(function() workspace:SetAttribute("ClientObbyAntiTp", false) end)
        -- 2. Quét và disable LocalScript anti-teleport trong PlayerScripts
        if _antiTpScriptsDisabled then return end
        _antiTpScriptsDisabled = true
        pcall(function()
            local ps = LocalPlayer:FindFirstChild("PlayerScripts")
            if not ps then return end
            for _, name in ipairs({"ObbyAntiTPClient", "AntiTP", "AntiTeleport",
                                    "AntiTeleportClient", "MovementValidator"}) do
                local s = ps:FindFirstChild(name)
                if s and s:IsA("LocalScript") and not s.Disabled then
                    s.Disabled = true
                end
            end
        end)
    end

    -- ============ tweenTo (blocking loop + full bypass) ============
    local function tweenTo(cf, speed)
        local root = getRoot()
        local hum = getHumanoid()
        if not root or not hum or hum.Health <= 0 or typeof(cf) ~= "CFrame" then
            return false
        end
        speed = math.clamp(tonumber(speed) or S.TweenSpeed or 20, 10, 900)
        local dist = (root.Position - cf.Position).Magnitude
        if dist < 4 then
            root.CFrame = cf
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            return true
        end

        stopTween()
        TweenSaved = captureTweenState(root, hum)
        TweenActive = true

        applyAntiTeleportBypass()

        -- Lock platform + noclip
        pcall(function()
            hum.PlatformStand = true
            hum.AutoRotate = false
            hum.Sit = false
            hum.Jump = false
            hum.AutoJumpEnabled = false
        end)
        pcall(function() root.Anchored = false end)

        local char = getChar()
        local function noclip()
            if char then
                for _, p in ipairs(char:GetDescendants()) do
                    if p:IsA("BasePart") then p.CanCollide = false end
                end
            end
        end
        noclip()

        local function assertOwner()
            if S.BypassAntiCheat == false then return end
            pcall(function()
                if root and root.SetNetworkOwner then
                    root:SetNetworkOwner(LocalPlayer)
                end
            end)
        end
        assertOwner()

        -- Blocking loop — giống Steal an Egg
        local duration = math.clamp(dist / speed, 0.25, 45)
        local startTime = os.clock()
        local startPos = root.Position
        local targetPos = cf.Position
        local lookVec = targetPos - startPos
        lookVec = lookVec.Magnitude > 0.1 and lookVec.Unit or root.CFrame.LookVector

        local arrived = false
        local lastBypassAt = 0
        local deadline = os.clock() + duration + 2

        while TweenActive and os.clock() < deadline do
            local r = getRoot()
            local h = getHumanoid()
            if not r or not h or h.Health <= 0 then break end

            local now = os.clock()
            local alpha = math.clamp((now - startTime) / duration, 0, 1)
            local curPos = startPos:Lerp(targetPos, alpha)

            -- Snap look direction
            r.CFrame = CFrame.new(curPos, curPos + lookVec)

            noclip()
            h.PlatformStand = true

            -- Re-assert network owner định kỳ
            if S.BypassAntiCheat ~= false and now - lastBypassAt > 0.15 then
                lastBypassAt = now
                assertOwner()
                pcall(function() workspace:SetAttribute("ClientObbyAntiTp", false) end)
            end

            if alpha >= 1 then
                r.CFrame = cf
                arrived = true
                TweenActive = false
                break
            end

            RunService.Heartbeat:Wait()
        end

        -- Final snap
        root = getRoot()
        if root and root.Parent then
            pcall(function()
                root.CFrame = cf
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        stopTween()
        task.wait(0.05)
        root = getRoot()
        return root ~= nil and (root.Position - cf.Position).Magnitude <= 14
    end

    local function walkTo(cf, timeout)
        local root = getRoot()
        local hum = getHumanoid()
        if not root or not hum or hum.Health <= 0 or typeof(cf) ~= "CFrame" then
            return false
        end

        stopTween()
        restoreTweenState()
        pcall(function()
            hum.PlatformStand = false
            hum.Sit = false
            hum.AutoRotate = true
            hum.WalkSpeed = math.max(tonumber(S.WalkSpeed) or 16, 16)
        end)

        local function canMoveDirect(fromPos, toPos)
            local character = LocalPlayer.Character
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = character and { character } or {}
            params.IgnoreWater = false
            local dir = toPos - fromPos
            if dir.Magnitude <= 2 then return true end
            local hit = workspace:Raycast(fromPos + Vector3.new(0, 2, 0), dir, params)
            if not hit then return true end
            return (hit.Position - toPos).Magnitude <= 5
        end

        local function moveStraight(toPos, maxWait)
            root = getRoot()
            hum = getHumanoid()
            if not root or not hum or hum.Health <= 0 then return false end
            if (root.Position - toPos).Magnitude <= 6 then return true end
            local flatTarget = Vector3.new(toPos.X, root.Position.Y, toPos.Z)
            if (flatTarget - root.Position).Magnitude > 1 then
                pcall(function() root.CFrame = CFrame.lookAt(root.Position, flatTarget) end)
            end
            hum:MoveTo(toPos)
            local startedMove = os.clock()
            while os.clock() - startedMove < (maxWait or 4) do
                root = getRoot()
                hum = getHumanoid()
                if not root or not hum or hum.Health <= 0 then return false end
                if (root.Position - toPos).Magnitude <= 7 then return true end
                local faceTarget = Vector3.new(toPos.X, root.Position.Y, toPos.Z)
                if (faceTarget - root.Position).Magnitude > 1 then
                    pcall(function() root.CFrame = CFrame.lookAt(root.Position, faceTarget) end)
                end
                task.wait(0.08)
            end
            return root ~= nil and (root.Position - toPos).Magnitude <= 10
        end

        if canMoveDirect(root.Position, cf.Position) then
            return moveStraight(cf.Position, math.min(tonumber(timeout) or 25, 8))
        end

        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = true,
            WaypointSpacing = 8,
        })
        local ok = pcall(function()
            path:ComputeAsync(root.Position, cf.Position)
        end)
        if not ok or path.Status ~= Enum.PathStatus.Success then
            return false
        end

        local started = os.clock()
        timeout = tonumber(timeout) or 25
        local waypoints = path:GetWaypoints()
        local i = 1
        while i <= #waypoints do
            if os.clock() - started > timeout then return false end
            root = getRoot()
            hum = getHumanoid()
            if not root or not hum or hum.Health <= 0 then return false end

            if (root.Position - cf.Position).Magnitude <= 26 and canMoveDirect(root.Position, cf.Position) then
                return moveStraight(cf.Position, 5)
            end

            local best = i
            for j = math.min(#waypoints, i + 4), i, -1 do
                if canMoveDirect(root.Position, waypoints[j].Position) then
                    best = j
                    break
                end
            end

            local waypoint = waypoints[best]
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                hum.Jump = true
            end
            local flatWaypoint = Vector3.new(waypoint.Position.X, root.Position.Y, waypoint.Position.Z)
            if (flatWaypoint - root.Position).Magnitude > 1 then
                pcall(function() root.CFrame = CFrame.lookAt(root.Position, flatWaypoint) end)
            end
            hum:MoveTo(waypoint.Position)
            local reached = false
            local waypointStart = os.clock()
            while os.clock() - waypointStart < 3.5 do
                root = getRoot()
                if not root then return false end
                if (root.Position - waypoint.Position).Magnitude <= 7 then reached = true; break end
                task.wait(0.08)
            end
            if not reached and (root.Position - waypoint.Position).Magnitude > 8 then
                hum.Jump = true
                task.wait(0.15)
                hum:MoveTo(waypoint.Position)
                local retryStart = os.clock()
                while os.clock() - retryStart < 2.5 do
                    root = getRoot()
                    if not root then return false end
                    if (root.Position - waypoint.Position).Magnitude <= 8 then reached = true; break end
                    task.wait(0.08)
                end
                if not reached and (root.Position - waypoint.Position).Magnitude > 10 then
                    return false
                end
            end
            i = best + 1
        end

        root = getRoot()
        return root ~= nil and (root.Position - cf.Position).Magnitude <= 14
    end

    env.applyAntiTeleportBypass = applyAntiTeleportBypass

    local function findIslandCF(name)
        local id = IslandPaths[name] or name
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        local island = islands and islands:FindFirstChild(id)
        local spawner = island and island:FindFirstChild("SpawnPoint") and island.SpawnPoint:FindFirstChild("Spawner")
        if spawner and spawner:IsA("BasePart") then return spawner.CFrame + Vector3.new(0, S.TweenHeight, 0) end
        if spawner and spawner:IsA("Model") then return spawner:GetPivot() + Vector3.new(0, S.TweenHeight, 0) end
        return nil
    end

    local _fastTravelCtrl = nil
    local function getFastTravelController()
        if _fastTravelCtrl then return _fastTravelCtrl end
        local Client = getStardustClient()
        if Client then
            local ok, ctrl = pcall(function() return Client.GetController("FastTravelController") end)
            if ok and type(ctrl) == "table" then _fastTravelCtrl = ctrl; return ctrl end
        end
        local mod = ReplicatedStorage:FindFirstChild("Controllers") and ReplicatedStorage.Controllers:FindFirstChild("FastTravelController")
        local ok, ctrl = pcall(function() return mod and require(mod) end)
        if ok and type(ctrl) == "table" then _fastTravelCtrl = ctrl; return ctrl end
        return nil
    end

    local _islandCatalogCache, _islandConfigCache, _playerDataV2Ctrl, _travelPacket
    local function getIslandCatalog()
        if _islandCatalogCache ~= nil then return _islandCatalogCache ~= false and _islandCatalogCache or nil end
        local ok, catalog = pcall(function() return require(ReplicatedStorage.Data.Catalog) end)
        if ok and type(catalog) == "table" and type(catalog.Island) == "table" then
            _islandCatalogCache = catalog.Island
            return _islandCatalogCache
        end
        _islandCatalogCache = false
        return nil
    end
    local function getIslandConfig()
        if _islandConfigCache ~= nil then return _islandConfigCache ~= false and _islandConfigCache or nil end
        local ok, cfg = pcall(function() return require(ReplicatedStorage.Data.Config.IslandConfig) end)
        if ok and type(cfg) == "table" then
            _islandConfigCache = cfg
            return cfg
        end
        _islandConfigCache = false
        return nil
    end
    local function getIslandMetaById(islandId)
        local islands = getIslandCatalog()
        if not islands then return nil end
        local ok, meta = pcall(function()
            if type(islands.GetById) == "function" then return islands.GetById(islandId) end
            if type(islands.GetAll) == "function" then
                for _, item in pairs(islands.GetAll()) do
                    if type(item) == "table" and tostring(item.id or item.Id or item.name) == tostring(islandId) then
                        return item
                    end
                end
            end
            return nil
        end)
        return ok and meta or nil
    end
    local function getPlayerDataV2()
        if not _playerDataV2Ctrl then
            local Client = getStardustClient()
            if Client then
                local ok, ctrl = pcall(function() return Client.GetController("PlayerDataV2Controller") end)
                if ok and type(ctrl) == "table" then _playerDataV2Ctrl = ctrl end
            end
        end
        if _playerDataV2Ctrl and type(_playerDataV2Ctrl.Fetch) == "function" then
            local ok, data = pcall(function() return _playerDataV2Ctrl:Fetch() end)
            if ok and type(data) == "table" then return data end
        end
        return nil
    end
    local function isIslandUnlockedForTravel(islandId)
        local cfg = getIslandConfig()
        local meta = getIslandMetaById(islandId)
        local cfgMeta = cfg and cfg[islandId]
        if type(meta) == "table" and meta.defaultUnlocked == true then return true end
        if type(cfgMeta) == "table" and cfgMeta.defaultUnlocked == true then return true end
        local data = getPlayerDataV2()
        local unlocked = type(data) == "table" and data.UnlockedIslands
        return type(unlocked) == "table" and unlocked[islandId] == true
    end
    local function getIslandDropdownValues()
        local values = {}
        local seen = {}
        local function addIslandDisplay(display, id)
            id = tostring(id or "")
            display = tostring(display or "")
            local lower = display:lower()
            if id == "island_volcano" or lower == "volcano" or lower == "volcanic" or lower == "volcano island" or lower == "volcanic island" then
                display = "Volcano Island"
                id = "island_volcano"
            end
            if display == "" or id == "" then return end
            IslandPaths[display] = id
            IslandDisplayNames[id] = display
            if not seen[display] then values[#values+1] = display; seen[display] = true end
        end
        local islands = getIslandCatalog()
        if islands and type(islands.GetAll) == "function" then
            local ok, all = pcall(islands.GetAll)
            if ok and type(all) == "table" then
                table.sort(all, function(a, b)
                    return tostring((type(a) == "table" and (a.order or a.index or a.price or a.id)) or "") < tostring((type(b) == "table" and (b.order or b.index or b.price or b.id)) or "")
                end)
                for _, item in ipairs(all) do
                    if type(item) == "table" then
                        local id = tostring(item.id or item.Id or "")
                        if id ~= "" then
                            local display = tostring(item.displayName or item.name or IslandDisplayNames[id] or id)
                            display = display:gsub("_", " ")
                            addIslandDisplay(display, id)
                        end
                    end
                end
            end
        end
        for display in pairs(IslandPaths) do
            addIslandDisplay(display, IslandPaths[display])
        end
        table.sort(values)
        return values
    end
    local function getTravelToIslandPacket()
        if _travelPacket ~= nil then return _travelPacket ~= false and _travelPacket or nil end
        local ok, packet = pcall(function()
            local Packet = require(ReplicatedStorage.Stardust).Packet
            return Packet("TravelToIsland", Packet.String)
        end)
        if ok and packet then
            _travelPacket = packet
            return packet
        end
        _travelPacket = false
        return nil
    end
    local function simpleObjectCFrame(inst)
        if not inst then return nil end
        local ok, cf = pcall(function()
            if inst:IsA("Model") then return inst:GetPivot() end
            if inst:IsA("BasePart") then return inst.CFrame end
            local part = inst:FindFirstChildWhichIsA("BasePart", true)
            return part and part.CFrame or nil
        end)
        return ok and cf or nil
    end
    local function findNearestPortalCF()
        local root = getRoot()
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        if not root or not islands then return nil end
        local currentDisplay = getIslandForPosition(root.Position)
        local currentId = IslandPaths[currentDisplay] or currentDisplay
        local currentIsland = islands:FindFirstChild(currentId)
        local best, bestDist = nil, math.huge
        local function consider(inst)
            if not inst then return end
            local n = tostring(inst.Name):lower()
            if not (n:find("portal", 1, true) or n:find("travel", 1, true) or n:find("teleport", 1, true) or n:find("fast", 1, true)) then return end
            local cf = simpleObjectCFrame(inst)
            if not cf then return end
            local d = (root.Position - cf.Position).Magnitude
            if d < bestDist then best, bestDist = cf, d end
        end
        if currentIsland then
            for _, d in ipairs(currentIsland:GetDescendants()) do consider(d) end
        end
        if not best then
            for _, d in ipairs(islands:GetDescendants()) do consider(d) end
        end
        return best
    end

    local FastTravelIslandNumbers = {
        island_jungle = 2,
        island_desert = 3,
        island_snow = 4,
        island_volcano = 5,
        island_fossil = 6,
    }
    local function waitForIslandSpawner(islandId, timeout)
        timeout = tonumber(timeout) or 8
        local world = workspace:FindFirstChild("World") or workspace:WaitForChild("World", timeout)
        local islands = world and (world:FindFirstChild("Islands") or world:WaitForChild("Islands", timeout))
        local island = islands and (islands:FindFirstChild(islandId) or islands:WaitForChild(islandId, timeout))
        local spawnPoint = island and (island:FindFirstChild("SpawnPoint") or island:WaitForChild("SpawnPoint", timeout))
        local spawner = spawnPoint and (spawnPoint:FindFirstChild("Spawner") or spawnPoint:WaitForChild("Spawner", timeout))
        return spawner, spawner and nil or ("Missing workspace.World.Islands.%s.SpawnPoint.Spawner"):format(tostring(islandId))
    end
    local function waitForFastTravelPad(islandId, timeout)
        timeout = tonumber(timeout) or 12
        local number = FastTravelIslandNumbers[islandId]
        if not number then return nil, nil end
        local world = workspace:FindFirstChild("World") or workspace:WaitForChild("World", timeout)
        local islands = world and (world:FindFirstChild("Islands") or world:WaitForChild("Islands", timeout))
        local island = islands and (islands:FindFirstChild(islandId) or islands:WaitForChild(islandId, timeout))
        local interactives = island and (island:FindFirstChild("Interactives") or island:WaitForChild("Interactives", timeout))
        local padName = ("fast_travel_island_%d"):format(number)
        local pad = interactives and (interactives:FindFirstChild(padName) or interactives:WaitForChild(padName, timeout))
        return pad, pad and nil or ("Missing workspace.World.Islands.%s.Interactives.%s"):format(tostring(islandId), padName)
    end
    local function teleportRootToCF(cf)
        local root = getRoot()
        if not root or not cf then return false end
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
        root.CFrame = cf + Vector3.new(0, 4, 0)
        return true
    end
    local function findIslandPortalCF(islandId)
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        local island = islands and islands:FindFirstChild(islandId)
        if not island then return nil end
        local best, bestScore = nil, math.huge
        for _, inst in ipairs(island:GetDescendants()) do
            local n = tostring(inst.Name):lower()
            if (n:find("portal", 1, true) or n:find("fast_travel", 1, true) or n:find("fast travel", 1, true)) and not n:find("spawn", 1, true) then
                local cf = simpleObjectCFrame(inst)
                if cf then
                    local score = n:find("portal", 1, true) and 0 or 10
                    if score < bestScore then
                        best, bestScore = cf, score
                    end
                end
            end
        end
        return best
    end
    local function showFastTravelLoading(destination, duration)
        duration = tonumber(duration) or 5
        local old = PlayerGui:FindFirstChild("NNVN_FastTravelLoading")
        if old then old:Destroy() end

        local gui = Instance.new("ScreenGui")
        gui.Name = "NNVN_FastTravelLoading"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2147483647
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = PlayerGui

        local shade = Instance.new("Frame")
        shade.Name = "Shade"
        shade.Size = UDim2.fromScale(1, 1)
        shade.BackgroundColor3 = Color3.fromRGB(3, 5, 7)
        shade.BackgroundTransparency = 1
        shade.BorderSizePixel = 0
        shade.ZIndex = 1000
        shade.Parent = gui

        local vignette = Instance.new("Frame")
        vignette.Name = "Vignette"
        vignette.AnchorPoint = Vector2.new(0.5, 0.5)
        vignette.Position = UDim2.fromScale(0.5, 0.5)
        vignette.Size = UDim2.fromScale(1.2, 1.2)
        vignette.BackgroundColor3 = Color3.fromRGB(10, 16, 18)
        vignette.BackgroundTransparency = 1
        vignette.BorderSizePixel = 0
        vignette.ZIndex = 1001
        vignette.Parent = shade
        local gradient = Instance.new("UIGradient")
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(5, 7, 9)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(11, 17, 19)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(5, 7, 9)),
        })
        gradient.Rotation = 35
        gradient.Parent = vignette

        local card = Instance.new("Frame")
        card.Name = "Card"
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.fromScale(0.5, 0.5)
        card.Size = UDim2.fromOffset(420, 150)
        card.BackgroundColor3 = Color3.fromRGB(12, 15, 18)
        card.BackgroundTransparency = 1
        card.BorderSizePixel = 0
        card.ZIndex = 1002
        card.Parent = shade
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Transparency = 1
        stroke.Thickness = 1
        stroke.Parent = card

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.BackgroundTransparency = 1
        title.Position = UDim2.fromOffset(26, 24)
        title.Size = UDim2.new(1, -52, 0, 30)
        title.Font = Enum.Font.GothamBlack
        title.Text = "Fast Travel"
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.TextTransparency = 1
        title.TextSize = 24
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 1003
        title.Parent = card

        local subtitle = Instance.new("TextLabel")
        subtitle.Name = "Subtitle"
        subtitle.BackgroundTransparency = 1
        subtitle.Position = UDim2.fromOffset(26, 58)
        subtitle.Size = UDim2.new(1, -52, 0, 22)
        subtitle.Font = Enum.Font.GothamMedium
        subtitle.Text = "Traveling to " .. tostring(destination or "island") .. "..."
        subtitle.TextColor3 = Color3.fromRGB(190, 205, 210)
        subtitle.TextTransparency = 1
        subtitle.TextSize = 14
        subtitle.TextXAlignment = Enum.TextXAlignment.Left
        subtitle.ZIndex = 1003
        subtitle.Parent = card

        local barBack = Instance.new("Frame")
        barBack.Name = "BarBack"
        barBack.Position = UDim2.fromOffset(26, 105)
        barBack.Size = UDim2.new(1, -52, 0, 7)
        barBack.BackgroundColor3 = Color3.fromRGB(48, 58, 62)
        barBack.BackgroundTransparency = 1
        barBack.BorderSizePixel = 0
        barBack.ZIndex = 1003
        barBack.Parent = card
        Instance.new("UICorner", barBack).CornerRadius = UDim.new(1, 0)

        local bar = Instance.new("Frame")
        bar.Name = "Bar"
        bar.Size = UDim2.fromScale(0, 1)
        bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        bar.BackgroundTransparency = 0
        bar.BorderSizePixel = 0
        bar.ZIndex = 1004
        bar.Parent = barBack
        Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

        TweenService:Create(shade, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.05}):Play()
        TweenService:Create(vignette, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.14}):Play()
        TweenService:Create(card, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {BackgroundTransparency = 0.04}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Transparency = 0.55}):Play()
        TweenService:Create(title, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
        TweenService:Create(subtitle, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
        TweenService:Create(barBack, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()
        TweenService:Create(bar, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Size = UDim2.fromScale(1, 1)}):Play()

        local alive = true
        task.spawn(function()
            while alive and gui.Parent do
                TweenService:Create(gradient, TweenInfo.new(1.15, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = gradient.Rotation + 95}):Play()
                task.wait(1.15)
            end
        end)

        return function()
            if not gui.Parent then return end
            alive = false
            TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
            TweenService:Create(shade, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
            TweenService:Create(vignette, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
            TweenService:Create(title, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {TextTransparency = 1}):Play()
            TweenService:Create(subtitle, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {TextTransparency = 1}):Play()
            task.wait(0.28)
            if gui.Parent then gui:Destroy() end
        end
    end

    local function fastTravelToIsland(name)
        local islandId = IslandPaths[name] or name
        setStatus("job", "Waiting island spawner: " .. tostring(name))
        local spawner, reason = waitForIslandSpawner(islandId, 10)
        local spawnerCF = simpleObjectCFrame(spawner)
        if spawnerCF then
            local closeLoading = showFastTravelLoading(name, 5)
            local started = os.clock()
            local okTeleport = teleportRootToCF(spawnerCF)
            if okTeleport and FastTravelIslandNumbers[islandId] then
                setStatus("job", "Waiting fast travel part: " .. tostring(name))
                local pad, padReason = waitForFastTravelPad(islandId, 12)
                local padCF = simpleObjectCFrame(pad)
                if padCF then
                    teleportRootToCF(padCF)
                elseif padReason then
                    setStatus("job", padReason)
                end
            end
            local elapsed = os.clock() - started
            if elapsed < 5 then task.wait(5 - elapsed) end
            pcall(closeLoading)
            if okTeleport then
                setStatus("job", "Teleported to fast travel path: " .. tostring(name))
                return true
            end
        end
        setStatus("job", tostring(reason or "Fast travel pad not found"))
        notify("传送岛屿", tostring(reason or "Fast travel pad not found."))
        return false
    end

    local function packetTravelToIsland(name)
        local islandId = IslandPaths[name] or name
        if not isIslandUnlockedForTravel(islandId) then
            setStatus("job", "Island is locked: " .. tostring(name))
            notify("传送岛屿", "Island is locked or PlayerData is not ready.")
            return false
        end
        local portalCF = findNearestPortalCF()
        if portalCF then
            setStatus("job", "Moving near portal...")
            local nearCF = portalCF + Vector3.new(0, 3, 0)
            local walked = false
            pcall(function() walked = walkTo(nearCF, math.max(tonumber(S.WalkSpeed) or 24, 16)) end)
            local root = getRoot()
            if not walked and root and (root.Position - portalCF.Position).Magnitude > 18 then
                tweenTo(nearCF, math.max(tonumber(S.TweenSpeed) or 20, 12))
            end
            task.wait(0.25)
        else
            setStatus("job", "Portal not found; trying travel packet nearby")
        end
        local ctrl = getFastTravelController()
        local packet = getTravelToIslandPacket()
        if not ctrl and not packet then setStatus("job", "Travel service is not ready"); return false end
        local ok, result = pcall(function()
            if packet and type(packet.Fire) == "function" then
                return packet:Fire(islandId)
            end
            if ctrl and type(ctrl.TravelToIsland) == "table" and type(ctrl.TravelToIsland.Fire) == "function" then
                return ctrl.TravelToIsland:Fire(islandId)
            end
        end)
        if not ok then
            setStatus("job", "Fast travel failed: " .. tostring(result))
            return false
        end
        if result ~= nil and result ~= 0 then
            setStatus("job", "Fast travel rejected: " .. tostring(result) .. " (stand near portal)")
            return false
        end
        setStatus("job", "Fast travel sent: " .. tostring(name))
        return true
    end

    -- ============ INTERACTION TARGETS ============
    local InteractionTargets = {
        Sell = { Names={"npc_fish_seller_1","npc_fish_seller"}, Fallback=CFrame.new(-31.8,19.6,407.0), Status="sell" },
        BuyRod = { Names={"npc_rod_shop_starter","npc_rod_shop"}, Fallback=CFrame.new(-29.7,12.0,354.2), Status="buyrod" },
        SkillGacha = { Names={"npc_gacha_book"}, Fallback=CFrame.new(-32.8,19.7,432.3), Status="shop" },
        AuraGacha = { Names={"npc_gacha_aura"}, Fallback=CFrame.new(-55.7,55.3,538.6), Status="auragacha" },
        OceanChest = { Names={"crate_ocean_chest_1","crate_ocean_chest"}, Fallback=CFrame.new(-70.3,17.3,419.9), Status="crate" },
        DragonChest = { Names={"crate_dragon_chest_1","crate_dragon_chest"}, Fallback=CFrame.new(-68.4,18.99,403.28), Status="crate" },
    }
    local function objectCFrame(inst)
        if not inst then return nil end
        local ok, cf = pcall(function()
            local hrp = inst:FindFirstChild("HumanoidRootPart", true)
            if hrp and hrp:IsA("BasePart") then return hrp.CFrame end
            if inst:IsA("Model") then return inst:GetPivot() end
            if inst:IsA("BasePart") then return inst.CFrame end
            local part = inst:FindFirstChildWhichIsA("BasePart", true)
            return part and part.CFrame or nil
        end)
        return ok and cf or nil
    end
    local function findInteractiveByNames(names)
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        if islands then
            for _, island in ipairs(islands:GetChildren()) do
                local inter = island:FindFirstChild("Interactives")
                if inter then
                    for _, name in ipairs(names) do
                        local found = inter:FindFirstChild(name) or inter:FindFirstChild(name, true)
                        if found then return found end
                    end
                end
            end
        end
        for _, name in ipairs(names) do
            local found = workspace:FindFirstChild(name, true)
            if found then return found end
        end
        return nil
    end
    local function interactionCF(key)
        local target = InteractionTargets[key]
        if not target then return nil end
        local inst = findInteractiveByNames(target.Names)
        local cf = objectCFrame(inst) or target.Fallback
        if cf then return cf, inst end
        return nil, inst
    end
    local function tweenToInteraction(key, reason)
        if S.TweenBeforeActions == false then return true end
        local target = InteractionTargets[key]
        local cf = interactionCF(key)
        if not cf then
            setStatus(target and target.Status or "teleport", "Target not found: "..tostring(reason or key))
            return false
        end
        local root = getRoot()
        if root then S.LastInteractionReturnCF = root.CFrame end
        setStatus(target.Status, ("Tweening to %s"):format(tostring(reason or key)))
        return tweenTo(cf, S.TweenSpeed)
    end
    local function returnFromInteraction(statusKey)
        if S.TweenBeforeActions == false then return end
        local cf = S.LastInteractionReturnCF
        S.LastInteractionReturnCF = nil
        if typeof(cf) == "CFrame" then
            if statusKey then setStatus(statusKey, "Returning") end
            task.wait(0.75)
            if statusKey == "sell" and walkTo(cf, 25) then
                local root = getRoot()
                if root then
                    pcall(function()
                        root.CFrame = cf
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
                return
            end
            tweenTo(cf, S.TweenSpeed)
        end
    end
    local function crateInteractionKey(crateId)
        crateId = tostring(crateId or S.SelectedChest or ""):lower()
        if crateId:find("dragon", 1, true) then return "DragonChest" end
        return "OceanChest"
    end

    -- ============ BOSS FARM ============
    local BossFarmPlatform = nil
    local function ensureBossFarmPlatform()
        if BossFarmPlatform and BossFarmPlatform.Parent then return BossFarmPlatform end
        local p = Instance.new("Part")
        p.Name = "NNVN_BossFarmPlatform"
        p.Anchored = true; p.CanCollide = true
        p.CanTouch = false; p.CanQuery = false
        p.Size = Vector3.new(12,1,12); p.Transparency = 0.4
        p.Material = Enum.Material.SmoothPlastic
        p.BrickColor = BrickColor.new("Bright blue")
        p.Parent = workspace; BossFarmPlatform = p
        return p
    end
    local function removeBossFarmPlatform()
        if BossFarmPlatform and BossFarmPlatform.Parent then BossFarmPlatform:Destroy() end
        BossFarmPlatform = nil
    end
    local function updateBossFarmPlatform()
        if not S.AutoFarmBoss then removeBossFarmPlatform(); return end
        local root = getRoot()
        if not root then return end
        local p = ensureBossFarmPlatform()
        p.CFrame = CFrame.new(root.Position.X, root.Position.Y - 3.5, root.Position.Z)
    end
    local function tweenToBoss()
        local info = nil
        if env.scanBossSpawnersExtended then
            for _, spawner in ipairs(env.scanBossSpawnersExtended()) do
                if spawner.active and spawner.position then
                    info = spawner
                    break
                end
            end
        end
        info = info or getActiveBossSpawner()
        if not info then setStatus("boss", "No active boss spawner"); notify("Boss Farm", "No boss active"); return end
        local root = getRoot()
        if root then S.LastInteractionReturnCF = root.CFrame end
        local targetCF = CFrame.new(info.position + Vector3.new(0, S.TweenHeight + 2, 0))
        setStatus("boss", ("Tweening to boss: %s Region %s"):format(info.islandDisplay, info.regionName))
        tweenTo(targetCF, S.TweenSpeed)
        setStatus("boss", ("At boss: %s Region %s"):format(info.islandDisplay, info.regionName))
    end
    local function startAutoFarmBoss()
        if not S.AutoCast then S.AutoCast = true end
        if not S.AutoClickFish then S.AutoClickFish = true end
        if not S.AutoPullMinigame then S.AutoPullMinigame = true end
        if not S.AutoUseSkills then S.AutoUseSkills = true end
        if not S.AutoPerfectCast then S.AutoPerfectCast = true; enablePerfectCast(true) end
        tweenToBoss()
        setStatus("boss", "Boss 挂机: 激活")
    end
    local function stopAutoFarmBoss()
        S.AutoFarmBoss = false
        removeBossFarmPlatform()
        setStatus("boss", "Boss 挂机: 关闭")
    end

    -- Export env
    env.trim = trim
    env.getChar = getChar
    env.getRoot = getRoot
    env.getHumanoid = getHumanoid
    env.setPathText = setPathText
    env.setStatus = setStatus
    env.notify = notify
    env.getJobIdText = getJobIdText
    env.copyText = copyText
    env.rejoinCurrentJob = rejoinCurrentJob
    env.joinJobId = joinJobId
    env.scanBossSpawners = scanBossSpawners
    env.getActiveBossSpawner = getActiveBossSpawner
    env.getIslandForPosition = getIslandForPosition
    env.fetchDiscordStats = fetchDiscordStats
    env.ensureBossStatusLabel = ensureBossStatusLabel
    env.updateBossStatusLabel = updateBossStatusLabel
    env.scanWeatherWebhooks = scanWeatherWebhooks
    env.refreshPremiumAccess = refreshPremiumAccess
    env.accessText = accessText
    env.getStardustClient = getStardustClient
    env.getFishingController = getFishingController
    env.getFishState = getFishState
    env.getFishInfo = getFishInfo
    env.simulateClick = simulateClick
    env.simulateClickAt = simulateClickAt
    env.simulateHold = simulateHold
    env.simulateKey = simulateKey
    env.PerfectCast = PerfectCast
    env.enablePerfectCast = enablePerfectCast
    env.bindAutoDismissPopup = bindAutoDismissPopup
    env._getPopupBound = function() return _popupBound end
    env.tweenTo = tweenTo
    env.walkTo = walkTo
    env.stopTween = stopTween
    env.findIslandCF = findIslandCF
    env.findIslandPortalCF = findIslandPortalCF
    env.fastTravelToIsland = fastTravelToIsland
    env.getIslandDropdownValues = getIslandDropdownValues
    env.isIslandUnlockedForTravel = isIslandUnlockedForTravel
    env.objectCFrame = objectCFrame
    env.findInteractiveByNames = findInteractiveByNames
    env.interactionCF = interactionCF
    env.tweenToInteraction = tweenToInteraction
    env.returnFromInteraction = returnFromInteraction
    env.crateInteractionKey = crateInteractionKey
    env.ensureBossFarmPlatform = ensureBossFarmPlatform
    env.removeBossFarmPlatform = removeBossFarmPlatform
    env.updateBossFarmPlatform = updateBossFarmPlatform
    env.tweenToBoss = tweenToBoss
    env.startAutoFarmBoss = startAutoFarmBoss
    env.stopAutoFarmBoss = stopAutoFarmBoss
end
-- ============================================================
-- FUNCTION 3: setupDataHelpers — PlayerData, rods, skins
-- ============================================================
local function setupDataHelpers(env)
    local S = env.S
    local RodShopFallback = env.RodShopFallback
    local Data = Data
    local ReplicatedStorage = ReplicatedStorage
    local LocalPlayer = LocalPlayer
    local trim = env.trim
    local getChar = env.getChar
    local setStatus = env.setStatus

    local function getPlayerData()
        local data = ReplicatedStorage:FindFirstChild("Data")
        if not data then return nil end
        return data:FindFirstChild(tostring(LocalPlayer.UserId)) or data:FindFirstChild(LocalPlayer.Name)
    end

    local function readNumber(names)
        local pdata = getPlayerData()
        for _, root in ipairs({pdata, LocalPlayer:FindFirstChild("leaderstats")}) do
            if root then
                for _, name in ipairs(names) do
                    local v = root:FindFirstChild(name, true)
                    if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then return v.Value end
                    if v and v:IsA("StringValue") then return tonumber(v.Value) end
                end
            end
        end
        return 0
    end

    local function parseAmount(text)
        text = tostring(text or ""):gsub(",",""):gsub("%s+","")
        local mult = 1
        if text:lower():find("k") then mult = 1000 end
        if text:lower():find("m") then mult = 1000000 end
        if text:lower():find("b") then mult = 1000000000 end
        return (tonumber(text:match("[%d%.]+")) or 0) * mult
    end

    local function guiCounter(path)
        local ok, value = pcall(function()
            local node = PlayerGui
            for part in tostring(path):gmatch("[^%.]+") do node = node:FindFirstChild(part) end
            return node and node.Text
        end)
        return ok and parseAmount(value) or 0
    end

    local function getCoin()
        local gui = guiCounter("HUD.Frame.Coin.Button.Frame.Counter")
        return gui > 0 and gui or readNumber({"Coin","Coins","Cash","Money"})
    end

    local function getGem()
        local gui = guiCounter("HUD.Frame.Gem.Button.Frame.Counter")
        return gui > 0 and gui or readNumber({"Gem","Gems"})
    end

    local function getCatalogList(pathName, fallback)
        local result, seen = {}, {}
        local function add(v)
            v = trim(v)
            if v ~= "" and not seen[v] then seen[v]=true; table.insert(result,v) end
        end
        pcall(function()
            local catalog = Data and Data:FindFirstChild("Catalog")
            local obj = catalog and catalog:FindFirstChild(pathName)
            if obj and obj:IsA("ModuleScript") then
                local d = require(obj)
                if type(d) == "table" then
                    for k, v in pairs(d) do
                        if type(k) == "string" then add(k) end
                        if type(v) == "table" then add(v.id or v.name or v.Name) end
                    end
                end
            elseif obj then
                for _, child in ipairs(obj:GetChildren()) do add(child.Name) end
            end
        end)
        for _, v in ipairs(fallback or {}) do add(v) end
        table.sort(result)
        return result
    end

    local function getRodShop()
        local data = RodShopFallback
        pcall(function()
            local mod = Data and Data:FindFirstChild("Config") and Data.Config:FindFirstChild("RodShopConfig")
            if mod and mod:IsA("ModuleScript") then
                local ok = require(mod)
                if type(ok) == "table" then data = ok end
            end
        end)
        return data
    end

    local function getRodOptions()
        local list = {}
        for id, cfg in pairs(getRodShop()) do
            if tostring(id) ~= "wooden_rod" then
                table.insert(list, ("%s - $%s"):format(tostring(id), tostring(cfg.price or 0)))
            end
        end
        table.sort(list)
        return list
    end

    local function getRodSkinOptions()
        local values, seen = {}, {}
        local function add(v)
            v = trim(v)
            if v ~= "" and not seen[v] then seen[v]=true; table.insert(values,v) end
        end
        add("None")
        pcall(function()
            local skins = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("RodSkins")
            if skins then for _, child in ipairs(skins:GetChildren()) do add(child.Name) end end
        end)
        for _, v in ipairs(getCatalogList("RodSkin",{})) do add(v) end
        table.sort(values)
        return values
    end

    local function selectedRodId()
        return tostring(S.SelectedRod or ""):match("^([^%s]+)") or S.SelectedRod
    end

    local function firstBasePart(inst)
        if not inst then return nil end
        if inst:IsA("BasePart") then return inst end
        return inst:FindFirstChildWhichIsA("BasePart", true)
    end

    local function basePartNamed(inst, name)
        if not inst then return nil end
        for _, child in ipairs(inst:GetDescendants()) do
            if child:IsA("BasePart") and child.Name == name then return child end
        end
        return nil
    end

    local function getEquippedRodTool()
        local char = getChar()
        if not char then return nil end
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") and tostring(child.Name):lower():find("rod",1,true) then return child end
        end
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") then return child end
        end
        return nil
    end

    local function destroyLocalRodSkins(root)
        if not root then return end
        for _, inst in ipairs(root:GetDescendants()) do
            if inst.Name == "NNVN_LocalRodSkin" then inst:Destroy() end
        end
    end

    local function restoreRodVisual(root)
        if not root then return end
        for _, inst in ipairs(root:GetDescendants()) do
            if inst:IsA("BasePart") then
                local original = inst:GetAttribute("NNVN_OrigLTM")
                inst.LocalTransparencyModifier = typeof(original)=="number" and original or 0
                local origColor = inst:GetAttribute("NNVN_OrigColor")
                local origMaterial = inst:GetAttribute("NNVN_OrigMaterial")
                local origTransparency = inst:GetAttribute("NNVN_OrigPartTransparency")
                if typeof(origColor) == "Color3" then inst.Color = origColor end
                if typeof(origMaterial) == "string" and Enum.Material[origMaterial] then inst.Material = Enum.Material[origMaterial] end
                if typeof(origTransparency) == "number" then inst.Transparency = origTransparency end
                if inst:IsA("MeshPart") then
                    local origMesh = inst:GetAttribute("NNVN_OrigMeshId")
                    local origTexture = inst:GetAttribute("NNVN_OrigTextureID")
                    if typeof(origMesh) == "string" then pcall(function() inst.MeshId = origMesh end) end
                    if typeof(origTexture) == "string" then pcall(function() inst.TextureID = origTexture end) end
                end
            elseif inst:IsA("Decal") or inst:IsA("Texture") then
                local original = inst:GetAttribute("NNVN_OrigTransparency")
                inst.Transparency = typeof(original)=="number" and original or 0
            end
        end
    end

    local function hideRodVisual(root, keepPart)
        if not root then return end
        for _, inst in ipairs(root:GetDescendants()) do
            if inst:IsA("BasePart") then
                if inst:GetAttribute("NNVN_OrigLTM")==nil then inst:SetAttribute("NNVN_OrigLTM", inst.LocalTransparencyModifier) end
                if inst ~= keepPart then inst.LocalTransparencyModifier = 1 end
            elseif inst:IsA("Decal") or inst:IsA("Texture") then
                if inst:GetAttribute("NNVN_OrigTransparency")==nil then inst:SetAttribute("NNVN_OrigTransparency", inst.Transparency) end
                inst.Transparency = 1
            end
        end
    end

    local function getRodVisual()
        local tool = getEquippedRodTool()
        if tool then
            local handle = basePartNamed(tool,"Handle") or firstBasePart(tool)
            if handle then return tool, handle, tool end
        end
        local char = getChar()
        if not char then return nil, nil, nil end
        for _, limbName in ipairs({"Right Arm","RightHand","RightLowerArm","RightUpperArm"}) do
            local limb = char:FindFirstChild(limbName)
            local model = limb and limb:FindFirstChild("Handle")
            if model and (model:IsA("Model") or model:IsA("Folder")) then
                local handle = basePartNamed(model,"Handle") or firstBasePart(model)
                if handle then return model, handle, model end
            end
        end
        for _, inst in ipairs(char:GetDescendants()) do
            if (inst:IsA("Model") or inst:IsA("Folder")) and inst.Name=="Handle" and inst:FindFirstChild("RodMesh",true) then
                local handle = basePartNamed(inst,"Handle") or firstBasePart(inst)
                if handle then return inst, handle, inst end
            end
        end
        return tool, tool and firstBasePart(tool), tool
    end

    local function chooseRodSkinSource(skin)
        if not skin then return nil end
        local rodId = tostring(selectedRodId() or "")
        local candidates = { rodId, rodId:gsub("_rod$", ""), tostring(S.SelectedRod or ""), "Model", "Default", "Handle", "鱼竿" }
        for _, name in ipairs(candidates) do
            if name ~= "" then
                local child = skin:FindFirstChild(name) or skin:FindFirstChild(name, true)
                if child and (child:IsA("Model") or child:IsA("Folder") or child:IsA("BasePart")) then
                    return child
                end
            end
        end
        return skin
    end

    local function makeLocalSkinVisible(inst)
        local list = inst:IsA("BasePart") and { inst } or inst:GetDescendants()
        for _, d in ipairs(list) do
            if d:IsA("BasePart") then
                d.Anchored = false
                d.CanCollide = false
                d.CanTouch = false
                d.CanQuery = false
                d.Massless = true
                d.Transparency = 0
                d.LocalTransparencyModifier = 0
            elseif d:IsA("Decal") or d:IsA("Texture") then
                d.Transparency = 0
            end
        end
    end

    local function copyHandleAppearance(handle, sourceHandle)
        if not (handle and sourceHandle and handle:IsA("BasePart") and sourceHandle:IsA("BasePart")) then return end
        if handle:GetAttribute("NNVN_OrigColor") == nil then handle:SetAttribute("NNVN_OrigColor", handle.Color) end
        if handle:GetAttribute("NNVN_OrigMaterial") == nil then handle:SetAttribute("NNVN_OrigMaterial", handle.Material.Name) end
        if handle:GetAttribute("NNVN_OrigPartTransparency") == nil then handle:SetAttribute("NNVN_OrigPartTransparency", handle.Transparency) end
        handle.Color = sourceHandle.Color
        handle.Material = sourceHandle.Material
        handle.Transparency = sourceHandle.Transparency
        handle.LocalTransparencyModifier = 0
        if handle:IsA("MeshPart") and sourceHandle:IsA("MeshPart") then
            if handle:GetAttribute("NNVN_OrigMeshId") == nil then handle:SetAttribute("NNVN_OrigMeshId", handle.MeshId) end
            if handle:GetAttribute("NNVN_OrigTextureID") == nil then handle:SetAttribute("NNVN_OrigTextureID", handle.TextureID) end
            pcall(function() handle.MeshId = sourceHandle.MeshId end)
            pcall(function() handle.TextureID = sourceHandle.TextureID end)
        end
    end

    local function applyLocalRodSkin(skinName)
        skinName = tostring(skinName or S.SelectedSkin or "")
        local skins = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("RodSkins")
        local container, handle, visualRoot = getRodVisual()
        local char = getChar()
        if not container or not handle then setStatus("skin","请先装备可见的鱼竿"); return false end
        destroyLocalRodSkins(container)
        destroyLocalRodSkins(char)
        if skinName=="" or skinName=="None" then restoreRodVisual(visualRoot); setStatus("skin","Local skin removed"); return true end
        local skin = skins and (skins:FindFirstChild(skinName) or skins:FindFirstChild(skinName,true))
        if not skin then setStatus("skin","Skin not found: "..skinName); return false end
        local source = chooseRodSkinSource(skin)
        local clone = source:Clone()
        clone.Name = "NNVN_LocalRodSkin"
        local sourceHandle = basePartNamed(clone,"Handle") or firstBasePart(clone)
        if not sourceHandle then setStatus("skin","Skin has no visible parts"); return false end
        makeLocalSkinVisible(clone)
        copyHandleAppearance(handle, sourceHandle)
        hideRodVisual(visualRoot, handle)
        clone.Parent = container
        if clone:IsA("Model") then
            pcall(function() clone:PivotTo(handle.CFrame) end)
        elseif clone:IsA("BasePart") then
            clone.CFrame = handle.CFrame
        end
        local sourceFrame = sourceHandle.CFrame
        local weldParts = clone:IsA("BasePart") and { clone } or clone:GetDescendants()
        for _, part in ipairs(weldParts) do
            if part:IsA("BasePart") then
                local offset = sourceFrame:ToObjectSpace(part.CFrame)
                part.CFrame = handle.CFrame * offset
                part.Anchored = false; part.CanCollide = false; part.CanTouch = false
                part.CanQuery = false; part.Massless = true
                local weld = Instance.new("WeldConstraint")
                weld.Part0 = handle; weld.Part1 = part; weld.Parent = part
            end
        end
        setStatus("skin","Local skin applied: "..skinName)
        return true
    end

    local function getRodPrice(rodId)
        local cfg = getRodShop()[rodId]
        return cfg and tonumber(cfg.price) or 0
    end

    local function fireRemoteNames(names, ...)
        local args = table.pack(...)
        for _, name in ipairs(names) do
            local ev = (Events and Events:FindFirstChild(name)) or ReplicatedStorage:FindFirstChild(name, true)
            if ev and ev:IsA("RemoteEvent") then pcall(function() ev:FireServer(table.unpack(args,1,args.n)) end); return true end
            if ev and ev:IsA("RemoteFunction") then pcall(function() ev:InvokeServer(table.unpack(args,1,args.n)) end); return true end
        end
        return false
    end

    env.getPlayerData = getPlayerData
    env.readNumber = readNumber
    env.parseAmount = parseAmount
    env.getCoin = getCoin
    env.getGem = getGem
    env.getCatalogList = getCatalogList
    env.getRodShop = getRodShop
    env.getRodOptions = getRodOptions
    env.getRodSkinOptions = getRodSkinOptions
    env.selectedRodId = selectedRodId
    env.applyLocalRodSkin = applyLocalRodSkin
    env.getRodPrice = getRodPrice
    env.fireRemoteNames = fireRemoteNames
end

-- ============================================================
-- FUNCTION 4: setupFishingCore — Fishing, Sell, Gacha, Crate, Codes
-- ============================================================
local function setupFishingCore(env)
    local S = env.S
    local ReplicatedStorage = ReplicatedStorage
    local LocalPlayer = LocalPlayer
    local VirtualInputManager = VirtualInputManager
    local getStardustClient = env.getStardustClient
    local getFishingController = env.getFishingController
    local getFishState = env.getFishState
    local getFishInfo = env.getFishInfo
    local setStatus = env.setStatus
    local notify = env.notify
    local copyText = env.copyText
    local simulateClick = env.simulateClick
    local simulateHold = env.simulateHold
    local simulateKey = env.simulateKey
    local fireRemoteNames = env.fireRemoteNames
    local getChar = env.getChar
    local getPlayerData = env.getPlayerData
    local getCoin = env.getCoin
    local getGem = env.getGem
    local selectedRodId = env.selectedRodId
    local getRodPrice = env.getRodPrice
    local getRodShop = env.getRodShop
    local getAuraGachaCost = nil

    -- ============ FISHING ============
    local function hasRodEquipped()
        local char = getChar()
        if not char then return false end
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") and tostring(child.Name):lower():find("rod",1,true) then return true end
        end
        return false
    end

    local function equipRod()
        local char = getChar()
        if not char then return false end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            for _, tool in ipairs(bp:GetChildren()) do
                if tool:IsA("Tool") and tostring(tool.Name):lower():find("rod",1,true) then
                    tool.Parent = char; task.wait(0.15); return true
                end
            end
        end
        return false
    end

    local function castRod()
        local ctrl = getFishingController()
        if not ctrl then setStatus("farm","钓鱼系统未就绪"); return false end
        local state = getFishState()
        if state and state ~= "Idling" then setStatus("farm","无法抛竿: "..tostring(state)); return false end
        if S.AutoEquipRod and not hasRodEquipped() then equipRod(); task.wait(0.25) end
        if not hasRodEquipped() then setStatus("farm","未装备鱼竿"); return false end
        local minHold = math.max(0.1, tonumber(S.CastHoldMin) or 1)
        local maxHold = math.max(minHold, tonumber(S.CastHoldMax) or 2)
        simulateHold(minHold + math.random() * (maxHold - minHold))
        S.Casts += 1
        setStatus("farm", ("抛竿: %d | 点击: %d | 技能: %d"):format(S.Casts,S.Clicks,S.Skills))
        return true
    end

    local function clickFish()
        local ctrl = getFishingController()
        if not ctrl then return false end
        local state = getFishState()
        if not state then return false end
        if state == "FirstPull" or state == "Reeling" then
            simulateClick(); S.Clicks += 1; return true
        end
        return false
    end

    local function getQTEDirection()
        local gui = PlayerGui:FindFirstChild("ReelCounterGui")
        if not gui then return nil end
        for _, name in ipairs({"Left","Right","Up","Counter","Direction"}) do
            local node = gui:FindFirstChild(name, true)
            if node and node:IsA("GuiObject") and node.Visible then return name end
        end
        for _, node in ipairs(gui:GetDescendants()) do
            if node:IsA("TextLabel") and node.Visible and node.Text ~= "" then
                local t = node.Text:upper()
                if t:find("LEFT") then return "Left" end
                if t:find("RIGHT") then return "Right" end
                if t:find("UP") then return "Up" end
                if t=="A" then return "Left" end
                if t=="D" then return "Right" end
                if t=="W" then return "Up" end
            end
        end
        return nil
    end

    local function pressQTE(direction)
        if not direction then return end
        local keyCode
        if direction=="Left" or direction=="A" then keyCode = Enum.KeyCode.A
        elseif direction=="Right" or direction=="D" then keyCode = Enum.KeyCode.D
        else keyCode = Enum.KeyCode.W end
        simulateKey(keyCode)
    end

    local LastPullAt = 0
    local function pullMinigame()
        local ctrl = getFishingController()
        if not ctrl then return end
        local state = getFishState()
        if state ~= "FirstPull" and state ~= "Reeling" then return end
        local direction = getQTEDirection()
        if direction then pressQTE(direction); setStatus("farm","QTE response: "..direction); return end
        local now = os.clock()
        if now - LastPullAt < (S.PullDelay or 0.12) then return end
        LastPullAt = now
        simulateClick()
        S.Clicks += 1
        setStatus("farm", ("收线 | 点击: %d | 抛竿: %d"):format(S.Clicks,S.Casts))
    end

    local function parseSkillOrder(str)
        local order = {}
        for token in tostring(str or "Z,X,C,V"):gmatch("[ZXCVzxcv]") do
            table.insert(order, token:upper())
        end
        if #order == 0 then order = {"Z","X","C","V"} end
        return order
    end

    local function useSkillsOnce()
        if UserInputService:GetFocusedTextBox() then return false end
        local allowedSkillKeys = { Z = true, X = true, C = true, V = true }
        for _, key in ipairs(parseSkillOrder(S.SkillOrder)) do
            key = tostring(key or ""):upper()
            local keyCode = allowedSkillKeys[key] and Enum.KeyCode[key] or nil
            if keyCode then simulateKey(keyCode); S.Skills += 1; task.wait(0.12) end
        end
        setStatus("farm", ("技能: %d | 点击: %d | 抛竿: %d"):format(S.Skills,S.Clicks,S.Casts))
        return true
    end

    local function useSkillsAtExecute()
        local ctrl = getFishingController()
        if not ctrl then return false end
        local _, hp, maxHp = getFishInfo()
        if not hp or not maxHp or maxHp <= 0 then
            setStatus("farm", "技能已准备 | 等待鱼血量"); return false
        end
        local ratio = hp / maxHp
        local threshold = math.clamp(tonumber(S.ExecutePercent) or 0.25, 0.02, 0.95)
        if ratio <= threshold then
            useSkillsOnce()
            setStatus("farm", ("Execute fired @ %d/%d (%.1f%%)"):format(hp,maxHp,ratio*100))
            return true
        end
        setStatus("farm", ("Armed: %d/%d (%.1f%%)"):format(hp,maxHp,ratio*100))
        return false
    end

    -- ============ SELL CONTROLLER (EntitlementConfig + busy lock) ============
    local returnFromInteraction = env.returnFromInteraction
    local interactionCF = env.interactionCF
    local tweenTo = env.tweenTo
    local getRoot = env.getRoot

    local _sellCtrl = nil
    local function getSellController()
        if _sellCtrl then return _sellCtrl end
        local Client = getStardustClient()
        if Client then
            local ok, ctrl = pcall(function() return Client.GetController("SellController") end)
            if ok and type(ctrl) == "table" then _sellCtrl = ctrl; return ctrl end
        end
        local mod = ReplicatedStorage:FindFirstChild("Controllers") and ReplicatedStorage.Controllers:FindFirstChild("SellController")
        local ok, ctrl = pcall(function() return mod and require(mod) end)
        if ok and type(ctrl) == "table" then _sellCtrl = ctrl; return ctrl end
        return nil
    end

    local _pdataV2Cache = nil
    local function getPlayerDataV2Lazy()
        if _pdataV2Cache then return _pdataV2Cache end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("PlayerDataV2Controller") end)
        if ok and type(ctrl) == "table" then _pdataV2Cache = ctrl; return ctrl end
        return nil
    end

    local _entitlementCfg = nil
    local function getEntitlementConfig()
        if _entitlementCfg ~= nil then return _entitlementCfg end
        local ok, cfg = pcall(function()
            return require(ReplicatedStorage.Data.Config.EntitlementConfig)
        end)
        if ok and type(cfg) == "table" then _entitlementCfg = cfg; return cfg end
        _entitlementCfg = false
        return nil
    end

    local function fetchPlayerData()
        local ctrl = getPlayerDataV2Lazy()
        if ctrl then
            local ok, data = pcall(function() return ctrl:Fetch() end)
            if ok and type(data) == "table" then return data end
        end
        return nil
    end

    local function countFishInInventory(data)
        if not data then return 0 end
        local inv = data.Inventory
        if type(inv) ~= "table" then return 0 end
        local fishes = inv.Fishes
        if type(fishes) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(fishes) do n = n + 1 end
        return n
    end

    local function countFishTools()
        local count = 0
        pcall(function()
            local bp = LocalPlayer:FindFirstChild("Backpack")
            if bp then
                for _, c in ipairs(bp:GetChildren()) do
                    if c:IsA("Tool") and CollectionService:HasTag(c, "Fish") then
                        count += 1
                    end
                end
            end
            local char = LocalPlayer.Character
            if char then
                for _, c in ipairs(char:GetChildren()) do
                    if c:IsA("Tool") and CollectionService:HasTag(c, "Fish") then
                        count += 1
                    end
                end
            end
        end)
        return count
    end

    -- Capacity: Manual override > EntitlementConfig.FishCapacity(data)
    local function getFishCapacity()
        local data = fetchPlayerData()
        if not data then return nil, "NoData" end
        local manual = tonumber(S.ManualFishLimit) or 0
        if manual > 0 then return manual, "Manual" end
        local cfg = getEntitlementConfig()
        if cfg and type(cfg.FishCapacity) == "function" then
            local ok, cap = pcall(cfg.FishCapacity, data)
            if ok and type(cap) == "number" and cap > 0 then
                return cap, "Auto"
            end
        end
        return nil, "Unknown"
    end

    local SellStatus = { OK = 0, EMPTY = 1, NO_PASS = 2, BUSY = 3 }
    local _sellBusy = false
    local function setAutoActionBusy(name, on)
        S.AutoActionBusy = on == true
        S.AutoActionBusyName = on and tostring(name or "action") or ""
        S.ActivePriorityName = on and tostring(name or "action") or ""
        S.ActivePriorityValue = on and (S.PriorityAutoSell or 90) or 0
    end

    local function sellStatusText(st)
        if st == SellStatus.OK then return "成功" end
        if st == SellStatus.EMPTY then return "EMPTY" end
        if st == SellStatus.NO_PASS then return "NO_PASS" end
        if st == SellStatus.BUSY then return "BUSY" end
        return ("status=" .. tostring(st))
    end

    local function tweenToFishSeller()
        if S.TweenBeforeActions == false then return true end
        local root = getRoot and getRoot()
        if root then S.LastInteractionReturnCF = root.CFrame end

        local hrp = nil
        local islandDisplay = root and env.getIslandForPosition and env.getIslandForPosition(root.Position) or S.SelectedIsland
        local islandId = env.IslandPaths and (env.IslandPaths[islandDisplay] or env.IslandPaths[S.SelectedIsland]) or "island_starter"
        if not islandId then islandId = "island_starter" end
        if not (hrp and hrp:IsA("BasePart")) then
            pcall(function()
                local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
                local island = islands and islands:FindFirstChild(islandId)
                local inter = island and island:FindFirstChild("Interactives")
                local npc = inter and inter:FindFirstChild("npc_fish_seller_1")
                hrp = npc and npc:FindFirstChild("HumanoidRootPart")
            end)
        end
        if not (hrp and hrp:IsA("BasePart")) then
            local cf = interactionCF and interactionCF("Sell")
            if cf then
                setStatus("sell", "Walking to Fish Seller...")
                if env.walkTo and env.walkTo(cf, 35) then
                    return true
                end
                setStatus("sell", "Path blocked - walk failed to Fish Seller")
                return false
            end
            setStatus("sell", "鱼商不可用")
            return false
        end
        local cf = hrp.CFrame
        setStatus("sell", "Walking to Fish Seller...")
        if env.walkTo and env.walkTo(cf, 35) then
            return true
        end
        setStatus("sell", "Path blocked - walk failed to Fish Seller")
        return false
    end

    local function runSell(label, fn)
        if _sellBusy then
            setStatus("sell", "忙碌中 — 跳过")
            return
        end
        _sellBusy = true
        setAutoActionBusy("sell", true)
        local function finishSell()
            if returnFromInteraction then returnFromInteraction("sell") end
            _sellBusy = false
            setAutoActionBusy("sell", false)
        end
        if S.TweenBeforeActions ~= false then
            local ok = tweenToFishSeller()
            if not ok then
                _sellBusy = false
                setAutoActionBusy("sell", false)
                return
            end
            task.wait(0.4)
        end
        local ctrl = getSellController()
        if not ctrl then
            _sellBusy = false
            setAutoActionBusy("sell", false)
            setStatus("sell", "出售服务未就绪")
            return
        end
        setStatus("sell", label .. "...")
        task.spawn(function()
            local ok, status, coins, count = pcall(fn, ctrl)
            if not ok then
                setStatus("sell", label .. " failed: " .. tostring(status))
                finishSell()
                return
            end
            if status == SellStatus.OK then
                S.Sells = (S.Sells or 0) + 1
            end
            local msg = ("%s | Coins=%s"):format(label, tostring(math.floor(coins or 0)))
            if count then msg = msg .. " | Count=" .. tostring(count) end
            setStatus("sell", msg .. " | " .. sellStatusText(status))
            task.wait(0.25)
            finishSell()
        end)
    end

    local function sellHeld()
        if _sellBusy then setStatus("sell", "忙碌中 — 跳过"); return end
        _sellBusy = true
        setAutoActionBusy("sell", true)
        local function finishSell()
            if returnFromInteraction then returnFromInteraction("sell") end
            _sellBusy = false
            setAutoActionBusy("sell", false)
        end
        local ctrl = getSellController()
        if not ctrl then
            _sellBusy = false
            setAutoActionBusy("sell", false)
            setStatus("sell", "出售服务未就绪")
            return
        end
        if S.TweenBeforeActions ~= false then
            if not tweenToFishSeller() then
                _sellBusy = false
                setAutoActionBusy("sell", false)
                return
            end
            task.wait(0.4)
        end
        local uid = ctrl:GetHeldFishUid()
        if not uid then
            setStatus("sell", "No fish held")
            finishSell()
            return
        end
        setStatus("sell", "Selling selected fish...")
        task.spawn(function()
            local ok, status, coins = pcall(function() return ctrl:SellHeld(uid) end)
            if not ok then
                setStatus("sell", "Sell selected fish failed: " .. tostring(status))
                finishSell()
                return
            end
            if status == SellStatus.OK then S.Sells = (S.Sells or 0) + 1 end
            setStatus("sell", ("Selected fish sold | Coins=%s | %s"):format(
                tostring(math.floor(coins or 0)), sellStatusText(status)))
            task.wait(0.25)
            finishSell()
        end)
    end

    local function sellAll()
        runSell("SellAll", function(ctrl) return ctrl:SellAll() end)
    end

    local function lockHeldFish()
        local ctrl = getSellController()
        if not ctrl then setStatus("lockfish", "背包服务未就绪"); return end
        local uid = ctrl:GetHeldFishUid()
        if not uid then setStatus("lockfish", "请先装备一条鱼"); return end
        task.spawn(function()
            local ok, status, isLocked = pcall(function() return ctrl:ToggleLock(uid) end)
            if ok then
                setStatus("lockfish", ("%s → locked=%s"):format(tostring(uid), tostring(isLocked)))
            else
                setStatus("lockfish", "ToggleLock failed")
            end
        end)
    end

    -- Return: isFull, count, limit, source
    local function backpackIsFull()
        local data = fetchPlayerData()
        if not data then
            local toolCount = countFishTools()
            return false, toolCount, 0, "NoData"
        end
        local fishCount = countFishInInventory(data)
        local cap, src = getFishCapacity()
        if cap and cap > 0 then
            return fishCount >= cap, fishCount, cap, src
        end
        local toolCount = countFishTools()
        return false, toolCount, 0, "ToolCount"
    end

    local _catalogCache = nil
    local function getCatalog()
        if _catalogCache then return _catalogCache end
        local ok, cat = pcall(function()
            return require(ReplicatedStorage.Data.Catalog)
        end)
        if ok and type(cat) == "table" then
            _catalogCache = cat
            return cat
        end
        return nil
    end

    local _rarityOptions = nil
    local function getRarityOptions()
        if _rarityOptions then return _rarityOptions end
        local fallback = {"Common","Uncommon","Rare","Epic","Legendary","Mythical","Divine"}
        local ok, enum = pcall(function()
            return require(ReplicatedStorage.Data.Enums.RarityEnums)
        end)
        if ok and type(enum) == "table" then
            if type(enum.Order) == "table" and #enum.Order > 0 then
                _rarityOptions = table.clone(enum.Order)
                return _rarityOptions
            end
            if type(enum.Rarity) == "table" then
                local values = {}
                for _, rarity in pairs(enum.Rarity) do values[#values+1] = tostring(rarity) end
                table.sort(values)
                if #values > 0 then
                    _rarityOptions = values
                    return _rarityOptions
                end
            end
        end
        _rarityOptions = fallback
        return _rarityOptions
    end

    local function normalizeRaritySelection(value)
        local selected = {}
        local function add(v)
            v = tostring(v or "")
            if v ~= "" and v ~= "---" then selected[v] = true end
        end
        if type(value) == "table" then
            if value.Value ~= nil then return normalizeRaritySelection(value.Value) end
            if value.Values ~= nil then return normalizeRaritySelection(value.Values) end
            if value.Selected ~= nil then return normalizeRaritySelection(value.Selected) end
            for k, v in pairs(value) do
                if type(k) == "string" and type(v) == "boolean" then
                    if v then add(k) end
                elseif type(v) == "string" then
                    add(v)
                elseif type(v) == "table" then
                    add(v.Value or v.Name or v.Title or v[1])
                end
            end
        else
            for token in tostring(value or ""):gmatch("[^,%s]+") do add(token) end
        end
        local out = {}
        for rarity in pairs(selected) do out[#out+1] = rarity end
        table.sort(out)
        return out
    end

    local function parseRarities()
        local set = {}
        local selected = S.FishFilterRarities
        if type(selected) == "table" then
            for _, rarity in pairs(selected) do
                rarity = tostring(rarity or ""):lower()
                if rarity ~= "" then set[rarity] = true end
            end
        end
        local raw = tostring(S.FishFilterRarityInput or "")
        for token in raw:gmatch("[^,%s]+") do
            token = token:lower()
            if token ~= "" then set[token] = true end
        end
        return set
    end

    local function fishFilterHasActiveIgnore()
        if tostring(S.FishFilterSelectedFish or "All") ~= "All" then return true end
        if next(parseRarities()) then return true end
        if tostring(S.FishFilterName or "") ~= "" then return true end
        if (tonumber(S.FishFilterMinWeight) or 0) > 0 then return true end
        if (tonumber(S.FishFilterMaxWeight) or 100000) < 100000 then return true end
        if S.FishFilterHugeOnly then return true end
        if tostring(S.FishFilterLockMode or "All") ~= "All" then return true end
        return false
    end

    local _fishOptionsCache = nil
    local _fishNameToId = {}
    local function resolveFishSelection(value)
        if type(value) == "table" then value = value.Value or value.Name or value.Title or value[1] end
        value = tostring(value or "All")
        if value == "" or value == "All" then return "All" end
        return _fishNameToId[value] or value:match("^(.-)%s+%[[^%]]+%]$") or value
    end

    local function matchFilter(entry, meta)
        if not entry or not meta then return false end
        local selectedFish = resolveFishSelection(S.FishFilterSelectedFish or "All")
        if selectedFish ~= "All" then
            local fishId = tostring(entry.fishId or meta.id or meta.Id or "")
            if fishId ~= selectedFish then return false end
        end
        local rarities = parseRarities()
        if next(rarities) then
            local r = tostring(meta.rarity or ""):lower()
            if not rarities[r] then return false end
        end
        local nameQ = tostring(S.FishFilterName or "")
        if nameQ ~= "" then
            local lname = tostring(meta.name or ""):lower()
            if not string.find(lname, nameQ:lower(), 1, true) then return false end
        end
        local w = tonumber(entry.weight) or 0
        local minW = tonumber(S.FishFilterMinWeight) or 0
        local maxW = tonumber(S.FishFilterMaxWeight) or 100000
        if minW > 0 and w < minW then return false end
        if maxW < 100000 and w > maxW then return false end
        if S.FishFilterHugeOnly and not entry.isHuge then return false end
        local lockMode = tostring(S.FishFilterLockMode or "All")
        if lockMode ~= "All" then
            local isLocked = entry.locked == true
            if lockMode == "Locked only" and not isLocked then return false end
            if lockMode == "Unlocked only" and isLocked then return false end
        end
        return true
    end

    local function getFilteredFishList()
        local data = fetchPlayerData()
        if not data then return {} end
        local inv = data.Inventory
        if type(inv) ~= "table" then return {} end
        local fishes = inv.Fishes
        if type(fishes) ~= "table" then return {} end
        local cat = getCatalog()
        if not cat or not cat.Fish then return {} end
        local result = {}
        for uid, entry in pairs(fishes) do
            if type(entry) == "table" and entry.fishId then
                local ok, meta = pcall(function()
                    return cat.Fish.GetById(entry.fishId)
                end)
                if ok and meta and matchFilter(entry, meta) then
                    table.insert(result, {
                        uid = uid,
                        fishId = entry.fishId,
                        name = meta.name or entry.fishId,
                        rarity = meta.rarity or "Common",
                        weight = tonumber(entry.weight) or 0,
                        isHuge = entry.isHuge == true,
                        locked = entry.locked == true,
                    })
                end
            end
        end
        table.sort(result, function(a, b) return a.weight > b.weight end)
        return result
    end

    local function getFishOptions()
        if _fishOptionsCache then return _fishOptionsCache end
        local options = { "All" }
        local seen = { All = true }
        local cat = getCatalog()
        if cat and cat.Fish then
            local source = cat.Fish
            if type(source.GetAll) == "function" then
                local ok, all = pcall(function() return source.GetAll() end)
                if ok and type(all) == "table" then source = all end
            end
            for id, meta in pairs(source) do
                if type(meta) == "table" then
                    local fishId = tostring(meta.id or meta.Id or meta.fishId or id)
                    local name = tostring(meta.name or meta.Name or fishId)
                    local rarity = tostring(meta.rarity or meta.Rarity or "?")
                    local label = ("%s [%s]"):format(name, rarity)
                    if not seen[label] then
                        seen[label] = true
                        _fishNameToId[label] = fishId
                        _fishNameToId[name] = fishId
                        _fishNameToId[fishId] = fishId
                        options[#options+1] = label
                    end
                end
            end
        end
        table.sort(options, function(a, b)
            if a == "All" then return true end
            if b == "All" then return false end
            return a < b
        end)
        _fishOptionsCache = options
        return options
    end

    local function equipFishByUid(uid)
        uid = tostring(uid or "")
        if uid == "" then return false end
        local ctrl = getSellController()
        if ctrl then
            for _, method in ipairs({ "EquipFish", "EquipHeldFish", "HoldFish", "SelectFish", "SetHeldFish", "SetHeldFishUid" }) do
                if type(ctrl[method]) == "function" then
                    local ok = pcall(function() return ctrl[method](ctrl, uid) end)
                    if ok then task.wait(0.25); return true end
                end
            end
        end
        local containers = { LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }
        for _, container in ipairs(containers) do
            if container then
                for _, tool in ipairs(container:GetChildren()) do
                    if tool:IsA("Tool") then
                        local text = tostring(tool.Name or "") .. " " .. tostring(tool:GetAttribute("UID") or tool:GetAttribute("Uid") or tool:GetAttribute("FishUid") or "")
                        if text:find(uid, 1, true) then
                            local hum = getHumanoid()
                            if hum and tool.Parent ~= LocalPlayer.Character then
                                pcall(function() hum:EquipTool(tool) end)
                                task.wait(0.25)
                            end
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local function lockFishByUid(uid)
        local ctrl = getSellController()
        if not ctrl then setStatus("lockfish", "背包服务未就绪"); return false end
        if not uid then setStatus("lockfish", "No fish selected"); return false end
        local ok = pcall(function() ctrl:ToggleLock(uid) end)
        if ok then
            return true
        end

        setStatus("lockfish", "直接 UID 锁定失败 - 尝试手持鱼回退")
        equipFishByUid(uid)
        task.wait(0.15)
        ok = pcall(function() ctrl:ToggleLock(uid) end)
        return ok == true
    end

    local function getAutoLockTargets()
        local data = fetchPlayerData()
        if not data or not data.Inventory or type(data.Inventory.Fishes) ~= "table" then return {} end
        local cat = getCatalog()
        local selectedFish = resolveFishSelection(S.SelectedLockFish or "All")
        local selectedRarity = tostring(S.SelectedLockRarity or "All")
        local result = {}
        for uid, entry in pairs(data.Inventory.Fishes) do
            if type(entry) == "table" and entry.locked ~= true then
                local fishId = tostring(entry.fishId or "")
                local meta = nil
                if cat and cat.Fish and fishId ~= "" then
                    local ok, m = pcall(function() return cat.Fish.GetById(fishId) end)
                    if ok then meta = m end
                end
                local rarity = tostring((meta and meta.rarity) or entry.rarity or "")
                local fishOk = selectedFish == "All" or fishId == selectedFish
                local rarityOk = selectedRarity == "All" or rarity == selectedRarity
                if fishOk and rarityOk then
                    result[#result+1] = {
                        uid = uid,
                        fishId = fishId,
                        name = (meta and meta.name) or fishId,
                        rarity = rarity,
                        weight = tonumber(entry.weight) or 0,
                    }
                end
            end
        end
        table.sort(result, function(a, b) return a.weight > b.weight end)
        return result
    end

    local function autoLockSelectedFishOnce()
        local ctrl = getSellController()
        if not ctrl then setStatus("lockfish", "背包服务未就绪"); return false end
        local targets = getAutoLockTargets()
        if #targets == 0 then
            setStatus("lockfish", "No unlocked fish matches selected filters")
            return false
        end
        local target = targets[1]
        if S.LockedUids[target.uid] then return false end
        S.LockedUids[target.uid] = true
        local ok = lockFishByUid(target.uid)
        setStatus("lockfish", ok and ("Locked: " .. tostring(target.name) .. " [" .. tostring(target.rarity) .. "]")
            or "Lock selected fish failed")
        return ok
    end

    local function getCurrentFish()
        local ctrl = getFishingController()
        if not ctrl then return nil end
        local ok, state = pcall(function() return ctrl:GetState() end)
        if not ok or not state then return nil end
        if state ~= "FirstPull" and state ~= "Reeling" and state ~= "Caught" then return nil end
        local ok2, fishId, hp, maxHp = pcall(function() return ctrl:GetFishInfo() end)
        if not ok2 or not fishId or fishId == "" then return nil end
        local name, rarity = fishId, "Common"
        local cat = getCatalog()
        if cat and cat.Fish then
            local ok3, fish = pcall(function() return cat.Fish.GetById(fishId) end)
            if ok3 and fish then
                name = fish.name or fishId
                rarity = fish.rarity or "Common"
            end
        end
        return { id = fishId, name = name, rarity = rarity, hp = hp or 0, maxHp = maxHp or 0, state = state }
    end

    local function currentFishAllowedByRarity()
        if not fishFilterHasActiveIgnore() then return true end
        local fish = getCurrentFish()
        if not fish then return true end
        local fakeEntry = {
            fishId = fish.id,
            weight = 0,
            isHuge = false,
            locked = false,
        }
        local matched = matchFilter(fakeEntry, {
            id = fish.id,
            name = fish.name,
            rarity = fish.rarity,
        })
        return matched ~= true
    end

    local function currentFishFilterActive()
        return fishFilterHasActiveIgnore()
    end

    local function onFishCaught(extra)
        if not S.AutoLockFiltered then return end
        if type(extra) ~= "table" then return end
        local fishId = extra.fishId
        if not fishId then return end
        local cat = getCatalog()
        local meta = nil
        if cat and cat.Fish then
            local ok, m = pcall(function() return cat.Fish.GetById(fishId) end)
            if ok then meta = m end
        end
        if not meta then return end
        local fakeEntry = {
            fishId = fishId,
            weight = tonumber(extra.weight) or 0,
            isHuge = extra.isHuge == true,
            locked = false,
        }
        if not matchFilter(fakeEntry, meta) then return end
        task.spawn(function()
            for _ = 1, 20 do
                task.wait(0.25)
                local data = fetchPlayerData()
                if data and data.Inventory and data.Inventory.Fishes then
                    for uid, entry in pairs(data.Inventory.Fishes) do
                        if entry.fishId == fishId
                            and math.abs((tonumber(entry.weight) or 0) - fakeEntry.weight) < 0.01
                            and (entry.isHuge == true) == fakeEntry.isHuge
                            and entry.locked ~= true then
                            local ctrl = getSellController()
                            if ctrl then pcall(function() ctrl:ToggleLock(uid) end) end
                            return
                        end
                    end
                end
            end
        end)
    end

    task.spawn(function()
        for _ = 1, 60 do
            local ctrl = getFishingController()
            if ctrl and ctrl.StateChanged then
                ctrl.StateChanged:Connect(function(newState, extra)
                    if newState == "Caught" then pcall(onFishCaught, extra) end
                end)
                break
            end
            task.wait(0.2)
        end
    end)

    env.getCatalog = getCatalog
    env.getFilteredFishList = getFilteredFishList
    env.getFishOptions = getFishOptions
    env.resolveFishSelection = resolveFishSelection
    env.equipFishByUid = equipFishByUid
    env.lockFishByUid = lockFishByUid
    env.getAutoLockTargets = getAutoLockTargets
    env.autoLockSelectedFishOnce = autoLockSelectedFishOnce
    env.getCurrentFish = getCurrentFish
    env.matchFilter = matchFilter
    env.getRarityOptions = getRarityOptions
    env.normalizeRaritySelection = normalizeRaritySelection
    env.currentFishAllowedByRarity = currentFishAllowedByRarity
    env.currentFishFilterActive = currentFishFilterActive

    env.isSellBusy = function() return _sellBusy end
    env.getFishCapacity = getFishCapacity
    env.fetchPlayerData = fetchPlayerData
    env.countFishInInventory = countFishInInventory
    env.countFishTools = countFishTools
    env.getEntitlementConfig = getEntitlementConfig

    -- ============ SKILL GACHA ============
    local _skillGachaCtrl = nil
    local function getSkillGachaController()
        if _skillGachaCtrl then return _skillGachaCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("SkillGachaController") end)
        if ok and type(ctrl)=="table" then _skillGachaCtrl=ctrl; return ctrl end
        return nil
    end
    task.spawn(function()
        for _ = 1, 50 do
            if getSkillGachaController() then break end
            task.wait(0.2)
        end
    end)

    local function skillGachaQuote(count)
        local ctrl = getSkillGachaController()
        if not ctrl then setStatus("shop","SkillGacha not ready"); return nil end
        if not tweenToInteraction("SkillGacha","技能抽卡") then return nil end
        local ok, quote = pcall(function() return ctrl.GetQuote:Fire(count) end)
        returnFromInteraction("shop")
        if ok and type(quote)=="table" and quote.ok then return quote end
        return nil
    end

    local function skillGachaPull(count, currency)
        currency = currency or "Coin"
        local ctrl = getSkillGachaController()
        if not ctrl then setStatus("shop","SkillGacha not ready"); return nil end
        if not tweenToInteraction("SkillGacha","技能抽卡") then return nil end
        local okFlight, inFlight = pcall(function() return ctrl:IsInFlight() end)
        if okFlight and inFlight then setStatus("shop","Pull in progress"); returnFromInteraction("shop"); return nil end
        task.spawn(function()
            local ok, result = pcall(function() return ctrl.Pull:Fire(currency, count) end)
            if not ok or type(result)~="table" then setStatus("shop","Pull failed"); returnFromInteraction("shop"); return end
            if not result.ok then setStatus("shop",("Rejected: %s"):format(tostring(result.reason))); returnFromInteraction("shop"); return end
            local lines = {}
            for _, r in ipairs(result.results or {}) do
                lines[#lines+1] = ("%s (%s)%s"):format(tostring(r.skill_id), tostring(r.rarity), r.is_new and " ★NEW" or "")
            end
            setStatus("shop", ("Rolled x%d: %s"):format(#(result.results or {}), table.concat(lines,", ")))
            returnFromInteraction("shop")
        end)
    end

    local function skillGachaPity()
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, pdata = pcall(function() return Client.GetController("PlayerDataV2Controller"):Fetch() end)
        if not ok or type(pdata)~="table" then return nil end
        return pdata.SkillGacha and pdata.SkillGacha.Pity or nil
    end

    -- ============ AURA GACHA ============
    local _auraGachaCtrl, _auraGachaConfig = nil, nil
    local function getAuraGachaController()
        if _auraGachaCtrl then return _auraGachaCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("AuraGachaController") end)
        if ok and type(ctrl)=="table" then _auraGachaCtrl=ctrl; return ctrl end
        return nil
    end
    local function getAuraGachaConfig()
        if _auraGachaConfig then return _auraGachaConfig end
        local ok, cfg = pcall(function() return require(ReplicatedStorage.Data.Config.AuraGachaConfig) end)
        if ok and type(cfg)=="table" then _auraGachaConfig=cfg; return cfg end
        return nil
    end
    task.spawn(function()
        for _ = 1, 50 do
            if getAuraGachaController() then break end
            task.wait(0.2)
        end
    end)

    local function auraGachaCost(count)
        local cfg = getAuraGachaConfig()
        if not cfg or not cfg.Pull then return nil end
        local discount = cfg.Pull.BulkDiscount and cfg.Pull.BulkDiscount[count] or 1
        return math.ceil(cfg.Pull.CostGem * count * discount)
    end

    local function auraGachaPull(count)
        count = tonumber(count) or 1
        local ctrl = getAuraGachaController()
        if not ctrl then setStatus("auragacha","光环抽卡未就绪"); return nil end
        if not tweenToInteraction("AuraGacha","Aura Gacha") then return nil end
        local okFlight, inFlight = pcall(function() return ctrl._inFlight end)
        if okFlight and inFlight then setStatus("auragacha","Pull in progress"); returnFromInteraction("auragacha"); return nil end
        task.spawn(function()
            local ok, result = pcall(function() return ctrl.Pull:Fire(count) end)
            if not ok or type(result)~="table" then setStatus("auragacha","Pull failed"); returnFromInteraction("auragacha"); return end
            if not result.ok then
                local reason = tostring(result.reason)
                if reason=="insufficient_gem" then reason="Not enough Gems" end
                setStatus("auragacha",("Rejected: %s"):format(reason)); returnFromInteraction("auragacha"); return
            end
            local lines = {}
            for _, r in ipairs(result.results or {}) do
                lines[#lines+1] = ("%s (%s)%s"):format(tostring(r.aura_id), tostring(r.rarity), r.is_new and " ★NEW" or "")
            end
            setStatus("auragacha", ("Rolled x%d | -%s gem | %s"):format(#(result.results or {}), tostring(result.gem_spent or 0), table.concat(lines,", ")))
            returnFromInteraction("auragacha")
        end)
    end

    local function auraGachaPity()
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, pdata = pcall(function() return Client.GetController("PlayerDataV2Controller"):Fetch() end)
        if not ok or type(pdata)~="table" then return nil end
        return pdata.AuraGacha and pdata.AuraGacha.Pity or nil
    end

    -- ============ CRATE ============
    local _crateCtrl, _crateConfig = nil, nil
    local function getCrateController()
        if _crateCtrl then return _crateCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("CrateGachaController") end)
        if ok and type(ctrl)=="table" then _crateCtrl=ctrl; return ctrl end
        return nil
    end
    local function getCrateConfig()
        if _crateConfig then return _crateConfig end
        local ok, cfg = pcall(function() return require(ReplicatedStorage.Data.Config.CrateConfig) end)
        if ok and type(cfg)=="table" then _crateConfig=cfg; return cfg end
        return nil
    end
    task.spawn(function()
        for _ = 1, 50 do
            if getCrateController() then break end
            task.wait(0.2)
        end
    end)

    local CrateIdMap = { ["Ocean Chest"]="crate_ocean_chest", ["Dragon Chest"]="crate_dragon_chest" }
    local function resolveCrateId(name)
        if type(name)~="string" then return nil end
        if name:find("^crate_") then return name end
        return CrateIdMap[name] or name
    end
    local function cratePrice(crateId, count)
        local cfg = getCrateConfig()
        if not cfg then return nil end
        count = tonumber(count) or 1
        local ok, price = pcall(function() return cfg.GetPrice(crateId, count) end)
        if ok and type(price)=="number" then return price end
        return nil
    end
    local function crateCurrency(crateId)
        local cfg = getCrateConfig()
        if not cfg then return "Coin" end
        local ok, crate = pcall(function() return cfg.GetCrate(crateId) end)
        if ok and type(crate)=="table" then return crate.Currency or "Coin" end
        return "Coin"
    end
    local function cratePull(crateId, count)
        crateId = resolveCrateId(crateId) or "crate_ocean_chest"
        count = tonumber(count) or 1
        local ctrl = getCrateController()
        if not ctrl then setStatus("crate","开箱未就绪"); return nil end
        if not tweenToInteraction(crateInteractionKey(crateId), crateId) then return nil end
        pcall(function() ctrl._crateId = crateId end)
        local okFlight, inFlight = pcall(function() return ctrl._inFlight end)
        if okFlight and inFlight then setStatus("crate","Pull in progress"); returnFromInteraction("crate"); return nil end
        task.spawn(function()
            local ok = pcall(function() ctrl:Pull(count) end)
            if not ok then setStatus("crate","Pull failed") else setStatus("crate",("Pull x%d sent"):format(count)) end
            returnFromInteraction("crate")
        end)
    end
    local function cratePullFast(crateId, count)
        crateId = resolveCrateId(crateId) or "crate_ocean_chest"
        count = tonumber(count) or 1
        local ctrl = getCrateController()
        if not ctrl then setStatus("crate","开箱未就绪"); return nil end
        if not tweenToInteraction(crateInteractionKey(crateId), crateId) then return nil end
        task.spawn(function()
            local ok, result = pcall(function() return ctrl.OpenPacket:Fire(crateId, count) end)
            if not ok or type(result)~="table" then setStatus("crate","Fast pull failed"); returnFromInteraction("crate"); return end
            if not result.ok then setStatus("crate",("Rejected: %s"):format(tostring(result.reason))); returnFromInteraction("crate"); return end
            local newCount, dupCount = 0, 0
            for _, r in ipairs(result.results or {}) do
                if r.is_new then newCount+=1 end
                if r.is_duplicate then dupCount+=1 end
            end
            setStatus("crate", ("Opened x%d | New: %d | Dup: %d"):format(#(result.results or {}), newCount, dupCount))
            returnFromInteraction("crate")
        end)
    end
    local function cratePity(crateId)
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, pdata = pcall(function() return Client.GetController("PlayerDataV2Controller"):Fetch() end)
        if not ok or type(pdata)~="table" then return nil end
        local pity = pdata.CrateGacha and pdata.CrateGacha.Pity
        if type(pity)~="table" then return nil end
        return pity[crateId]
    end

    -- ============ CODE REDEEM ============
    local _codeRedeemCtrl = nil
    local function getCodeRedeemController()
        if _codeRedeemCtrl then return _codeRedeemCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("CodeRedeemController") end)
        if ok and type(ctrl)=="table" then _codeRedeemCtrl=ctrl; return ctrl end
        return nil
    end

    local function readAllCodesFromModule()
        local codes = {}
        local ok, RedeemCodes = pcall(function() return require(ReplicatedStorage.Data.RedeemCodes) end)
        if not ok or type(RedeemCodes)~="table" then return codes, "Cannot read RedeemCodes" end
        for code, info in pairs(RedeemCodes) do
            if type(code)=="string" and code~="" then
                local expireUnix = 0
                pcall(function() expireUnix = info.ExpireDate.UnixTimestamp or 0 end)
                local rewards = {}
                for _, r in ipairs(info.Rewards or {}) do
                    local reward = tostring(r.Type)
                    if r.Id then reward = reward..":"..tostring(r.Id) end
                    if r.Amount then reward = reward.." x"..tostring(r.Amount) end
                    table.insert(rewards, reward)
                end
                table.insert(codes, {code=tostring(code), expireUnix=expireUnix, rewards=table.concat(rewards,", ")})
            end
        end
        table.sort(codes, function(a,b) return a.expireUnix < b.expireUnix end)
        return codes, nil
    end

    local RedeemStatusText = {
        [0]="✅ Success", [1]="❌ Invalid", [2]="❌ Expired",
        [3]="❌ Already redeemed", [4]="❌ Requirements not met",
        [5]="❌ Save failed", [6]="⏳ Processing", [7]="✅ Migrated passes",
    }

    local function redeemAllCodes()
        local ctrl = getCodeRedeemController()
        if not ctrl then setStatus("misc","兑换码未加载"); return end
        local codes, err = readAllCodesFromModule()
        if err or #codes==0 then setStatus("misc", err or "No codes found"); return end
        setStatus("misc", ("Found %d codes. Redeeming..."):format(#codes))
        local ok, fail, done = 0, 0, 0
        for _, entry in ipairs(codes) do
            local status
            pcall(function() status = ctrl:RedeemCode(entry.code) end)
            done += 1
            if status==0 or status==7 then ok+=1 else fail+=1 end
            setStatus("misc", ("%d/%d | ✅ %d | ❌ %d | Last: %s"):format(done,#codes,ok,fail,entry.code))
            task.wait(0.5)
        end
        S.Codes = ok
        setStatus("misc", ("Done! ✅ %d / %d | ❌ %d"):format(ok,#codes,fail))
        notify("Redeem Codes", ("Success: %d / %d"):format(ok,#codes))
    end

    local function dumpAllCodes()
        local codes, err = readAllCodesFromModule()
        if err or #codes==0 then setStatus("misc", err or "No codes found"); return end
        local lines = {}
        for _, c in ipairs(codes) do
            local exp = c.expireUnix > 0 and os.date("%Y-%m-%d", c.expireUnix) or "?"
            lines[#lines+1] = ("%s | exp: %s | %s"):format(c.code, exp, c.rewards)
        end
        -- redeem dump
        setStatus("misc", ("Found %d codes — see F9"):format(#codes))
        notify("Codes Dump", ("Found %d codes"):format(#codes))
    end

    -- ============ MISC ============
    local function claimRewardsOnce()
        env.fireRemoteNames({"ClaimDailyReward","DailyReward","ClaimReward","ClaimAllRewards"})
        pcall(function()
            local controllers = ReplicatedStorage:FindFirstChild("Controllers")
            local daily = controllers and controllers:FindFirstChild("DailyRewardController")
            daily = daily and require(daily)
            for _, method in ipairs({"Claim","ClaimAll","ClaimDaily","Redeem"}) do
                if type(daily[method])=="function" then daily[method](daily) end
            end
        end)
        setStatus("rewards","领取请求已发送")
    end

    local _rodShopCtrl = nil
    local function getFishingRodShopController()
        if _rodShopCtrl then return _rodShopCtrl end
        local Client = getStardustClient()
        if Client then
            local ok, ctrl = pcall(function() return Client.GetController("FishingRodShopController") end)
            if ok and type(ctrl)=="table" then _rodShopCtrl=ctrl; return ctrl end
        end
        local mod = ReplicatedStorage:FindFirstChild("Controllers") and ReplicatedStorage.Controllers:FindFirstChild("FishingRodShopController")
        local ok, ctrl = pcall(function() return mod and require(mod) end)
        if ok and type(ctrl)=="table" then _rodShopCtrl=ctrl; return ctrl end
        return nil
    end

    local function buyRodOnce()
        local rod = selectedRodId()
        if rod=="" then return end
        if not tweenToInteraction("BuyRod","Rod Shop") then return end
        local ctrl = getFishingRodShopController()
        local cfg = getRodShop()[rod] or {}
        local ok = false
        if ctrl then
            pcall(function() if type(ctrl.SetIsland)=="function" then ctrl:SetIsland(cfg.islandId or "island_starter") end end)
            ok = pcall(function()
                if type(ctrl.PurchaseRod)=="table" and type(ctrl.PurchaseRod.Fire)=="function" then
                    return ctrl.PurchaseRod:Fire(rod)
                end
            end)
        end
        if not ok then ok = env.fireRemoteNames({"BuyFishingRod","BuyRod","PurchaseRod","PurchaseFishingRod"}, rod) end
        S.RodBuys += 1
        setStatus("buyrod", ("Buy %s | Attempts: %d"):format(rod, S.RodBuys))
        returnFromInteraction("buyrod")
    end

    local function autoBuyRodOnce()
        local rod = selectedRodId()
        local price = getRodPrice(rod)
        local money = getCoin()
        if money >= price then buyRodOnce()
        else setStatus("buyrod", ("Not enough: %s / %s"):format(tostring(math.floor(money)), tostring(price))) end
    end

    local function unlockIslandOnce(name)
        local islandNo = env.UnlockIslandIds[name]
        if not islandNo then return false end
        local dialogueName = "npc_unlock_island_"..tostring(islandNo)
        local questName = "unlock_island_"..tostring(islandNo)
        if S.TweenBeforeActions ~= false then
            local npc = nil
            pcall(function()
                local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
                local fossil = islands and islands:FindFirstChild("island_fossil")
                local inter = fossil and fossil:FindFirstChild("Interactives")
                npc = inter and (inter:FindFirstChild(dialogueName) or inter:FindFirstChild(dialogueName, true))
            end)
            npc = npc or env.findInteractiveByNames({dialogueName})
            local cf = env.objectCFrame(npc)
            if cf then
                setStatus("teleport","Walking to unlock NPC")
                local walked = env.walkTo and env.walkTo(cf, 35)
                if not walked then
                    setStatus("teleport","Path blocked - slow tween to unlock NPC")
                    env.tweenTo(cf + Vector3.new(0, 3, 0), math.max(8, tonumber(S.TweenSpeed) or 20))
                end
                task.wait(0.25)
            end
        end
        env.fireRemoteNames({"Dialogue","DialogueAnswer","NPCDialogue","UnlockIsland"}, dialogueName, "Accept")
        env.fireRemoteNames({"QuestAccept","AcceptQuest","UnlockIsland","IslandUnlock"}, questName)
        setStatus("teleport","Unlock sent: "..tostring(name))
        return true
    end

    local function getInfoText()
        return table.concat({
            "Name: "..LocalPlayer.Name,
            "UserId: "..LocalPlayer.UserId,
            "Coin: "..tostring(env.getCoin and env.getCoin() or env.readNumber({"Coin","Coins"})),
            "Gem: "..tostring(env.getGem and env.getGem() or env.readNumber({"Gem","Gems"})),
            "PlaceId: "..game.PlaceId,
        }, "\n")
    end

    local function getBoatSeat()
        local hum = env.getHumanoid()
        if hum and hum.SeatPart then return hum.SeatPart end
        local root = env.getRoot()
        local best, bestDist
        local cars = workspace:FindFirstChild("Cars")
        if cars then
            for _, car in ipairs(cars:GetChildren()) do
                if car:FindFirstChild("Highlight", true) then
                    local seat = car:FindFirstChild("DSeat", true)
                    if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
                        local dist = root and (root.Position - seat.Position).Magnitude or 0
                        if not bestDist or dist < bestDist then best, bestDist = seat, dist end
                    end
                end
            end
            if best then return best end
        end
        for _, inst in ipairs(workspace:GetDescendants()) do
            if inst:IsA("VehicleSeat") or (inst:IsA("Seat") and tostring(inst.Name):lower():find("boat",1,true)) then
                local dist = root and (root.Position - inst.Position).Magnitude or 999999
                if not bestDist or dist < bestDist then best, bestDist = inst, dist end
            end
        end
        return best
    end

    local applyBoatSpeed

    local _boatCtrl = nil
    local function getBoatController()
        if _boatCtrl then return _boatCtrl end
        local Client = getStardustClient and getStardustClient()
        if Client then
            for _, name in ipairs({"BoatController", "BoatsController", "BoatShopController", "VehicleController"}) do
                local ok, ctrl = pcall(function() return Client.GetController(name) end)
                if ok and type(ctrl) == "table" then
                    _boatCtrl = ctrl
                    return ctrl
                end
            end
        end
        local controllers = ReplicatedStorage:FindFirstChild("Controllers")
        if controllers then
            for _, name in ipairs({"BoatController", "BoatsController", "BoatShopController", "VehicleController"}) do
                local mod = controllers:FindFirstChild(name)
                local ok, ctrl = pcall(function() return mod and require(mod) end)
                if ok and type(ctrl) == "table" then
                    _boatCtrl = ctrl
                    return ctrl
                end
            end
        end
        return nil
    end

    local function findBoatMerchant()
        return env.findInteractiveByNames({
            "npc_boat_merchant_1",
            "npc_boat_merchant",
            "npc_boat_shop_1",
            "npc_boat_shop",
            "npc_boat",
            "boat_merchant",
            "boat_shop",
        })
    end

    local CarMerchantByIsland = {
        island_starter = "npc_car_merchant_starter",
        island_jungle = "npc_car_merchant_jungle",
        island_desert = "npc_car_merchant_desert",
        island_snow = "npc_car_merchant_snow",
        island_volcano = "npc_car_merchant_volcano",
        island_fossil = "npc_car_merchant_fossil",
    }

    local function getCurrentIslandId()
        local root = env.getRoot and env.getRoot()
        local display = root and env.getIslandForPosition and env.getIslandForPosition(root.Position) or S.SelectedIsland
        return (env.IslandPaths and env.IslandPaths[display]) or env.IslandPaths[S.SelectedIsland] or "island_starter"
    end

    local function findVehicleMerchantForCurrentIsland()
        local islandId = getCurrentIslandId()
        local npcName = CarMerchantByIsland[islandId] or "npc_car_merchant_starter"
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        local island = islands and islands:FindFirstChild(islandId)
        local inter = island and island:FindFirstChild("Interactives")
        local npc = inter and (inter:FindFirstChild(npcName) or inter:FindFirstChild(npcName, true))
        return npc or env.findInteractiveByNames({ npcName }), islandId, npcName
    end

    local function triggerBoatMerchant(npc)
        local clicked = false
        if npc then
            for _, d in ipairs(npc:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    clicked = true
                    pcall(function()
                        if fireproximityprompt then fireproximityprompt(d) end
                    end)
                elseif d:IsA("ClickDetector") then
                    clicked = true
                    pcall(function()
                        if fireclickdetector then fireclickdetector(d) end
                    end)
                end
            end
        end
        return clicked
    end

    local function vehicleIdForSelection()
        local choice = tostring(S.SelectedVehicle or "Truck - Free")
        if choice:lower():find("red", 1, true) then
            return "Red Truck - 50000", "RedTruck", "red_truck"
        end
        return "Truck - Free", "Truck", "truck"
    end

    local function catalogVehicleId()
        local displayName = vehicleIdForSelection()
        local wantRed = tostring(S.SelectedVehicle or ""):lower():find("red", 1, true) ~= nil
        local ok, catalog = pcall(function() return require(ReplicatedStorage.Data.Catalog) end)
        local cars = nil
        if ok and catalog and catalog.Car and type(catalog.Car.GetAll) == "function" then
            pcall(function() cars = catalog.Car.GetAll() end)
        end
        if type(cars) == "table" then
            table.sort(cars, function(a, b) return (tonumber(a.price) or 0) < (tonumber(b.price) or 0) end)
            for _, car in ipairs(cars) do
                local name = tostring(car.name or car.Name or car.id or ""):lower()
                local price = tonumber(car.price) or 0
                if wantRed and name:find("red", 1, true) and name:find("truck", 1, true) then
                    return tostring(car.id or car.Id or car.name)
                end
                if not wantRed and name:find("truck", 1, true) and not name:find("red", 1, true) and price <= 0 then
                    return tostring(car.id or car.Id or car.name)
                end
            end
        end
        local _, compactName, snakeName = vehicleIdForSelection()
        return wantRed and compactName or snakeName
    end

    local function fireSpawnCarEvent(islandId)
        islandId = tostring(islandId or getCurrentIslandId() or "island_starter")
        local carId = catalogVehicleId()
        local payload = ("%s/%s"):format(tostring(carId), islandId)
        local ok = pcall(function()
            local Packet = require(ReplicatedStorage.Stardust).Packet
            local spawnCar = Packet("SpawnCarEvent", Packet.String)
            spawnCar:Fire(payload)
        end)
        if ok then
            setStatus("boat", "Spawn car sent: " .. payload)
            return true
        end
        local events = ReplicatedStorage:FindFirstChild("Events")
        local ev = (events and events:FindFirstChild("SpawnCarEvent")) or ReplicatedStorage:FindFirstChild("SpawnCarEvent", true)
        if ev and ev:IsA("RemoteEvent") then
            pcall(function() ev:FireServer(payload) end)
            setStatus("boat", "Spawn car remote sent: " .. payload)
            return true
        end
        setStatus("boat", "SpawnCarEvent not found")
        return false
    end

    local function spawnBoatForTravel(islandId)
        if fireSpawnCarEvent(islandId) then
            return true
        end
        local displayName, compactName, snakeName = vehicleIdForSelection()
        local ctrl = getBoatController()
        if ctrl then
            for _, method in ipairs({"SpawnBoat", "RequestBoat", "SummonBoat", "EquipBoat", "CreateBoat", "Spawn"}) do
                local member = ctrl[method]
                local ok = false
                if type(member) == "function" then
                    ok = pcall(function() member(ctrl, compactName) end)
                    if not ok then ok = pcall(function() member(ctrl, snakeName) end) end
                    if not ok then ok = pcall(function() member(ctrl, displayName) end) end
                elseif type(member) == "table" and type(member.Fire) == "function" then
                    ok = pcall(function() member:Fire(compactName) end)
                    if not ok then ok = pcall(function() member:Fire(snakeName) end) end
                    if not ok then ok = pcall(function() member:Fire(displayName) end) end
                elseif type(member) == "table" and type(member.Invoke) == "function" then
                    ok = pcall(function() member:Invoke(compactName) end)
                    if not ok then ok = pcall(function() member:Invoke(snakeName) end) end
                    if not ok then ok = pcall(function() member:Invoke(displayName) end) end
                end
                if ok then return true end
            end
        end
        if env.fireRemoteNames({
            "SpawnBoat", "RequestBoat", "SummonBoat", "EquipBoat", "CreateBoat",
            "BoatSpawn", "BoatRequest", "BoatSummon", "SpawnVehicle", "RequestVehicle",
            "VehicleSpawn", "VehicleRequest", "SpawnCar", "RequestCar"
        }, compactName) then
            return true
        end
        if env.fireRemoteNames({
            "SpawnBoat", "RequestBoat", "SummonBoat", "EquipBoat", "CreateBoat",
            "BoatSpawn", "BoatRequest", "BoatSummon", "SpawnVehicle", "RequestVehicle",
            "VehicleSpawn", "VehicleRequest", "SpawnCar", "RequestCar"
        }, snakeName) then
            return true
        end
        return false
    end

    local function sitBoatSeat(seat)
        local root = env.getRoot and env.getRoot()
        local hum = env.getHumanoid and env.getHumanoid()
        if not root or not hum or not seat then return false end
        pcall(function()
            hum.Sit = false
            root.CFrame = seat.CFrame + Vector3.new(0, 4, 0)
        end)
        task.wait(0.25)
        pcall(function() seat:Sit(hum) end)
        task.wait(0.4)
        return hum.SeatPart == seat
    end

    local function waitForBoatSeat(timeout)
        local start = os.clock()
        local best
        repeat
            best = getBoatSeat()
            if best then return best end
            task.wait(0.25)
        until os.clock() - start > (timeout or 8)
        return best
    end

    local function boatRootFromSeat(seat)
        if not seat then return nil end
        local model = seat:FindFirstAncestorOfClass("Model")
        if model then
            local primary = model.PrimaryPart or seat
            return model, primary
        end
        return nil, seat
    end

    local function driveBoatToCF(targetCF)
        local seat = waitForBoatSeat(4)
        if not seat then setStatus("boat", "未找到船座"); return false end
        if not sitBoatSeat(seat) then setStatus("boat", "无法坐上船"); return false end
        applyBoatSpeed()

        local model, boatRoot = boatRootFromSeat(seat)
        if not boatRoot or not boatRoot:IsA("BasePart") then return false end
        local startCF = boatRoot.CFrame
        local targetPos = targetCF.Position
        local waterY = startCF.Position.Y
        local endPos = Vector3.new(targetPos.X, waterY, targetPos.Z)
        local distance = (startCF.Position - endPos).Magnitude
        local speed = math.clamp(tonumber(S.BoatSpeed) or 120, 35, 180)
        local duration = math.clamp(distance / speed, 2.5, 45)
        local started = os.clock()

        setStatus("boat", "驾驶船前往岛屿...")
        while os.clock() - started < duration do
            local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
            local pos = startCF.Position:Lerp(endPos, alpha)
            if (pos - endPos).Magnitude <= 90 then
                break
            end
            local cf = CFrame.new(pos, Vector3.new(endPos.X, pos.Y, endPos.Z))
            pcall(function()
                if seat:IsA("VehicleSeat") then
                    seat.ThrottleFloat = 1
                    seat.Throttle = 1
                end
                if model then
                    model:PivotTo(cf)
                else
                    boatRoot.CFrame = cf
                end
                boatRoot.AssemblyLinearVelocity = Vector3.zero
                boatRoot.AssemblyAngularVelocity = Vector3.zero
            end)
            RunService.Heartbeat:Wait()
        end
        pcall(function()
            if model then model:PivotTo(CFrame.new(endPos, endPos + targetCF.LookVector)) else boatRoot.CFrame = CFrame.new(endPos) end
            if seat:IsA("VehicleSeat") then seat.Throttle = 0; seat.ThrottleFloat = 0 end
        end)
        setStatus("boat", "Near island - final tween")
        if env.tweenTo then
            env.tweenTo(targetCF, math.max(8, tonumber(S.TweenSpeed) or 20))
        end
        setStatus("boat", "Vehicle arrived")
        return true
    end

    local function boatTravelToIsland(name)
        local targetCF = env.findIslandCF and env.findIslandCF(name)
        if not targetCF then setStatus("boat", "Island target not found"); return false end
        local root = env.getRoot and env.getRoot()
        if root then S.LastInteractionReturnCF = root.CFrame end

        local merchant, islandId, npcName = findVehicleMerchantForCurrentIsland()
        if not merchant then merchant = findBoatMerchant() end
        local merchantCF = env.objectCFrame and env.objectCFrame(merchant)
        if merchantCF then
            setStatus("boat", ("Walking to Vehicle Merchant: %s"):format(tostring(islandId or npcName or "current island")))
            local okWalk = env.walkTo and env.walkTo(merchantCF, 35)
            if not okWalk and env.tweenTo then
                env.tweenTo(merchantCF + Vector3.new(0, 3, 0), math.max(8, tonumber(S.TweenSpeed) or 20))
            end
            task.wait(0.25)
            triggerBoatMerchant(merchant)
        else
            setStatus("boat", "Vehicle Merchant not found - trying direct summon")
        end

        spawnBoatForTravel(islandId)
        task.wait(2)
        return driveBoatToCF(targetCF)
    end

    applyBoatSpeed = function()
        local seat = getBoatSeat()
        if not seat then setStatus("boat","No boat seat"); return end
        pcall(function()
            if seat:IsA("VehicleSeat") then
                seat.MaxSpeed = S.BoatSpeed
                seat.Torque = math.max(seat.Torque, S.BoatSpeed * 200)
            end
        end)
        setStatus("boat", ("Boat speed set: %d"):format(S.BoatSpeed))
    end

    local function applyFakeStats()
        if not S.FakeStats then return end
        env.setPathText(PlayerGui,"HUD.Frame.Coin.Button.Frame.Counter", S.FakeCoin)
        env.setPathText(PlayerGui,"HUD.Frame.Gem.Button.Frame.Counter", S.FakeGem)
    end

    local function applyStreamer()
        if not S.Streamer then return end
        local fake = S.FakeName ~= "" and S.FakeName or "NNVN Hub"
        local function fakeFor(plr)
            if plr == LocalPlayer then return fake end
            return S.StreamerAllPlayers and fake or plr.Name
        end
        pcall(function()
            local nt = workspace:FindFirstChild("Nametags")
            if nt then
                for _, plr in ipairs(Players:GetPlayers()) do
                    local tag = nt:FindFirstChild(plr.Name)
                    local label = tag and tag:FindFirstChild("PlrName",true) and tag.PlrName:FindFirstChild("Label",true)
                    if label and label:IsA("TextLabel") then label.Text = fakeFor(plr) end
                end
            end
        end)
    end

    env.hasRodEquipped = hasRodEquipped
    env.equipRod = equipRod
    env.castRod = castRod
    env.clickFish = clickFish
    env.pullMinigame = pullMinigame
    env.getQTEDirection = getQTEDirection
    env.pressQTE = pressQTE
    env.useSkillsOnce = useSkillsOnce
    env.useSkillsAtExecute = useSkillsAtExecute
    env.getSellController = getSellController
    env.tweenToFishSeller = tweenToFishSeller
    env.sellHeld = sellHeld
    env.sellAll = sellAll
    env.lockHeldFish = lockHeldFish
    env.backpackIsFull = backpackIsFull
    env.isAutoActionBusy = function() return S.AutoActionBusy == true end
    env.getAutoActionBusyName = function() return tostring(S.AutoActionBusyName or "") end
    env.getSkillGachaController = getSkillGachaController
    env.skillGachaQuote = skillGachaQuote
    env.skillGachaPull = skillGachaPull
    env.skillGachaPity = skillGachaPity
    env.getAuraGachaController = getAuraGachaController
    env.auraGachaCost = auraGachaCost
    env.auraGachaPull = auraGachaPull
    env.auraGachaPity = auraGachaPity
    env.getCrateController = getCrateController
    env.resolveCrateId = resolveCrateId
    env.cratePrice = cratePrice
    env.crateCurrency = crateCurrency
    env.cratePull = cratePull
    env.cratePullFast = cratePullFast
    env.cratePity = cratePity
    env.getCodeRedeemController = getCodeRedeemController
    env.redeemAllCodes = redeemAllCodes
    env.dumpAllCodes = dumpAllCodes
    env.claimRewardsOnce = claimRewardsOnce
    env.buyRodOnce = buyRodOnce
    env.autoBuyRodOnce = autoBuyRodOnce
    env.unlockIslandOnce = unlockIslandOnce
    env.getInfoText = getInfoText
    env.applyBoatSpeed = applyBoatSpeed
    env.boatTravelToIsland = boatTravelToIsland
    env.applyFakeStats = applyFakeStats
    env.applyStreamer = applyStreamer
end
-- ============================================================
-- FUNCTION 5: setupESP
-- ============================================================
local function setupESP(env)
    local S = env.S
    local PlayerGui = PlayerGui
    local Players = Players
    local LocalPlayer = LocalPlayer
    local getRoot = env.getRoot
    local getIslandForPosition = env.getIslandForPosition

    local ESPFolder = Instance.new("Folder")
    ESPFolder.Name = "NNVN_FishingMaster_ESP"
    ESPFolder.Parent = PlayerGui
    local ESPObjects = {}
    local XRayOriginal = {}

    local function clearESP()
        for inst, data in pairs(ESPObjects) do
            if data.Billboard then pcall(function() data.Billboard:Destroy() end) end
            if data.Highlight  then pcall(function() data.Highlight:Destroy() end) end
            if data.SelectionBox then pcall(function() data.SelectionBox:Destroy() end) end
            ESPObjects[inst] = nil
        end
    end

    local function espPart(inst)
        if inst:IsA("BasePart") then return inst end
        if inst:IsA("Model") then
            return inst:FindFirstChild("HumanoidRootPart",true) or inst:FindFirstChild("Head",true) or inst:FindFirstChildWhichIsA("BasePart",true)
        end
        return inst:FindFirstChildWhichIsA("BasePart",true)
    end

    -- Box ESP: SelectionBox (khung chữ nhật 3D) quanh target
    local function upsertESP(inst, kind, color, extraInfo)
        if not inst or not inst.Parent then return end
        local part = espPart(inst)
        local root = getRoot()
        if not part or not root then return end
        local dist = (root.Position - part.Position).Magnitude
        if dist > S.ESPDistance then
            if ESPObjects[inst] then
                if ESPObjects[inst].Billboard then ESPObjects[inst].Billboard:Destroy() end
                if ESPObjects[inst].Highlight  then ESPObjects[inst].Highlight:Destroy() end
                if ESPObjects[inst].SelectionBox then ESPObjects[inst].SelectionBox:Destroy() end
                ESPObjects[inst] = nil
            end
            return
        end
        local data = ESPObjects[inst]
        if not data then
            data = {}
            -- SelectionBox = khung hình chữ nhật quanh character/NPC
            local sb = Instance.new("SelectionBox")
            sb.Name = "NNVN_BoxESP"
            sb.Adornee = inst
            sb.LineThickness = 0.05
            sb.SurfaceTransparency = 0.85
            sb.Color3 = color
            sb.SurfaceColor3 = color
            pcall(function() sb.Visible = S.ESPBox == true end)
            sb.Parent = ESPFolder
            data.SelectionBox = sb

            local h = Instance.new("Highlight")
            h.FillColor = color
            h.OutlineColor = color
            h.FillTransparency = 0.88
            h.OutlineTransparency = 0.35
            h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            h.Adornee = inst
            h.Parent = ESPFolder
            data.Highlight = h

            local bb = Instance.new("BillboardGui")
            bb.AlwaysOnTop = true
            bb.Size = UDim2.fromOffset(200, 50)
            bb.StudsOffset = Vector3.new(0, 3.5, 0)
            bb.Adornee = part
            bb.Parent = ESPFolder
            local txt = Instance.new("TextLabel")
            txt.BackgroundTransparency = 1
            txt.Font = Enum.Font.GothamMedium
            txt.TextSize = 11
            txt.TextColor3 = color
            txt.TextStrokeTransparency = 0.3
            txt.Size = UDim2.fromScale(1, 1)
            txt.Parent = bb
            data.Billboard = bb
            data.Text = txt
            ESPObjects[inst] = data
        else
            -- Update colors live
            if data.SelectionBox then
                data.SelectionBox.Color3 = color
                data.SelectionBox.SurfaceColor3 = color
                pcall(function() data.SelectionBox.Visible = S.ESPBox == true end)
            end
            if data.Highlight then
                data.Highlight.FillColor = color
                data.Highlight.OutlineColor = color
                data.Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            end
            if data.Text then data.Text.TextColor3 = color end
        end
        local hum = inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid")
        local hp  = hum and ("\nHP "..math.floor(hum.Health).."/"..math.floor(hum.MaxHealth)) or ""
        local islandLine = ""
        if extraInfo and extraInfo.isPlayer and part then
            islandLine = "\nIsland: "..getIslandForPosition(part.Position)
        end
        data.Billboard.Adornee = part
        data.Text.Text = ("%s | %s\n%d studs%s%s"):format(kind, tostring(inst.Name), math.floor(dist), hp, islandLine)
    end

    local function scanESP()
        if not (S.ESPPlayers or S.ESPNPCs or S.ESPFish or S.ESPGuides or S.ESPBox) then
            clearESP(); return
        end
        if S.ESPPlayers then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and plr.Character then
                    upsertESP(plr.Character, "玩家", S.ESPColorPlayers or Color3.fromRGB(80,170,255), {isPlayer=true})
                end
            end
        end
        for _, inst in ipairs(workspace:GetDescendants()) do
            local n = tostring(inst.Name):lower()
            if S.ESPNPCs and inst:IsA("Model") and n:find("npc",1,true) then
                upsertESP(inst, "NPC", S.ESPColorNPCs or Color3.fromRGB(255,210,90))
            end
            local fishLike = n=="fishhitbox" or inst:GetAttribute("FishId") or inst:GetAttribute("fishId")
            if S.ESPFish and fishLike then
                upsertESP(inst, "Fish", S.ESPColorFish or Color3.fromRGB(90,255,200))
            end
            if S.ESPGuides and (n:find("unlock",1,true) or n:find("guide",1,true)) then
                upsertESP(inst, "Guide", S.ESPColorGuides or Color3.fromRGB(210,120,255))
            end
            -- Box ESP: khung quanh mọi NPC/Player đã bật (SelectionBox đã gắn trong upsert)
            -- Không còn crate/chest ESP riêng
        end
    end

    local function applyMapXRay(on)
        local islands = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Islands")
        if not islands then return end
        if on then
            for _, inst in ipairs(islands:GetDescendants()) do
                if inst:IsA("BasePart") and not inst:FindFirstAncestor("Interactives") then
                    if XRayOriginal[inst]==nil then XRayOriginal[inst]=inst.LocalTransparencyModifier end
                    inst.LocalTransparencyModifier = 0.68
                end
            end
            env.setStatus("visual","Map X-Ray: ON")
        else
            for inst, value in pairs(XRayOriginal) do
                if inst and inst.Parent then pcall(function() inst.LocalTransparencyModifier = value end) end
                XRayOriginal[inst] = nil
            end
            env.setStatus("visual","Map X-Ray: OFF")
        end
    end

    env.clearESP = clearESP
    env.scanESP = scanESP
    env.applyMapXRay = applyMapXRay
end

-- ============================================================
-- FUNCTION: setupIndexPreview — Force Index Preview Mode
-- ============================================================
local function setupIndexPreview(env)
    local getStardustClient = env.getStardustClient
    local setStatus = env.setStatus
    local notify = env.notify

    local _indexCtrl = nil
    local function getIndexController()
        if _indexCtrl then return _indexCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("IndexController") end)
        if ok and type(ctrl) == "table" then
            _indexCtrl = ctrl
            return ctrl
        end
        return nil
    end

    -- Bật/tắt preview mode — hiện toàn bộ cá kể cả chưa khám phá
    local function setIndexPreview(on)
        local ctrl = getIndexController()
        if not ctrl then
            setStatus("index", "Index preview is not ready")
            notify("图鉴预览", "Preview service is not ready. Try rejoining.")
            return false
        end

        local ok, err = pcall(function() ctrl:SetPreview(on and true or false) end)
        if ok then
            env.S.IndexPreview = on and true or false
            setStatus("index", "Index Preview: " .. (on and "开启" or "关闭"))
            notify("图鉴预览", on and "ON — showing all fish" or "关闭")
            return true
        else
            setStatus("index", "SetPreview failed: " .. tostring(err))
            return false
        end
    end

    -- Mở Index UI (nếu muốn test ngay)
    local function openIndexUI()
        local Client = getStardustClient()
        if not Client then return end
        local ui = Client.GetController("UIController")
        if ui then
            pcall(function() ui:Open("Index") end)
        end
    end

    env.setIndexPreview = setIndexPreview
    env.openIndexUI = openIndexUI
    env.getIndexController = getIndexController

    -- Auto request state từ server (nếu có packet)
    task.spawn(function()
        for _ = 1, 50 do
            if getIndexController() then
                -- index preview
                break
            end
            task.wait(0.2)
        end
    end)
end

-- ============================================================
-- FUNCTION: setupBossAdvanced — Spawn Alert, Phase, ESP, History
-- ============================================================
local function setupBossAdvanced(env)
    local S = env.S
    local setStatus = env.setStatus
    local notify = env.notify
    local getRoot = env.getRoot
    local tweenTo = env.tweenTo
    local getFishingController = env.getFishingController
    local getFishInfo = env.getFishInfo
    local useSkillsOnce = env.useSkillsOnce
    local scanBossSpawnersExtended = env.scanBossSpawnersExtended
    local HttpService = game:GetService("HttpService")

    -- ========== Boss Discord Webhook ==========
    local function sendBossWebhook(info, eventType)
        if not S.BossWebhookEnabled then return end
        local url = tostring(S.BossWebhookUrl or "")
        if url == "" or not url:find("discord", 1, true) then return end
        local req = (syn and syn.request) or (http and http.request) or http_request or request
        if type(req) ~= "function" then return end
        local emoji = eventType == "spawn" and "🔥" or "💨"
        local title = eventType == "spawn" and "Boss SPAWNED" or "Boss DESPAWNED"
        local body = {
            username = "NNVN Boss Alert",
            embeds = {{
                title = ("%s %s"):format(emoji, title),
                description = ("**[%s] %s**"):format(info.islandDisplay or "?", info.regionName or "?"),
                color = eventType == "spawn" and 0xE74C3C or 0x95A5A6,
                fields = {
                    { name = "岛屿", value = tostring(info.islandDisplay or "?"), inline = true },
                    { name = "Region", value = tostring(info.regionName or "?"), inline = true },
                    { name = "JobId", value = ("`%s`"):format(tostring(game.JobId or "")), inline = false },
                    { name = "Players", value = ("%d/%d"):format(#Players:GetPlayers(), Players.MaxPlayers), inline = true },
                },
                footer = { text = "NNVN Hub | Fishing Master" },
                timestamp = DateTime.now():ToIsoDate(),
            }},
        }
        pcall(req, {
            Url = url,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(body),
        })
    end

    -- ========== Boss Spawn / Despawn Alert Loop ==========
    local lastActive = {}
    local function startBossSpawnAlertLoop()
        task.spawn(function()
            task.wait(2)
            local initial = scanBossSpawnersExtended()
            for _, info in ipairs(initial) do
                lastActive[info.regionId] = info.active == true

                -- ⭐ Nếu boss đã active từ đầu + user đã bật toggle → tween ngay
                if info.active and S.AutoTweenOnBossSpawn and info.position then
                    local root = getRoot()
                    if root then
                        local target = CFrame.new(info.position + Vector3.new(0, (S.TweenHeight or 5) + 2, 0))
                        task.spawn(function() tweenTo(target, S.TweenSpeed) end)
                    end
                end
            end
            while true do
                task.wait(3)
                local ok, spawners = pcall(scanBossSpawnersExtended)
                if not ok or type(spawners) ~= "table" then continue end
                for _, info in ipairs(spawners) do
                    local was = lastActive[info.regionId] or false
                    local now = info.active == true
                    if now and not was then
                        -- SPAWN
                        if S.BossSpawnAlert then
                            notify("🔥 BOSS SPAWN", ("[%s] %s"):format(
                                tostring(info.islandDisplay), tostring(info.regionName)))
                            setStatus("bossalert", ("🔥 SPAWN: [%s] %s"):format(
                                tostring(info.islandDisplay), tostring(info.regionName)))
                        end
                        pcall(sendBossWebhook, info, "spawn")
                        if S.AutoTweenOnBossSpawn and info.position then
                            local root = getRoot()
                            if root then
                                local target = CFrame.new(info.position + Vector3.new(0, (S.TweenHeight or 5) + 2, 0))
                                task.spawn(function()
                                    tweenTo(target, S.TweenSpeed)
                                end)
                            end
                        end
                    elseif was and not now then
                        -- DESPAWN
                        if S.BossDespawnAlert then
                            notify("💨 BOSS DESPAWN", ("[%s] %s"):format(
                                tostring(info.islandDisplay), tostring(info.regionName)))
                            setStatus("bossalert", ("💨 DESPAWN: [%s] %s"):format(
                                tostring(info.islandDisplay), tostring(info.regionName)))
                        end
                        pcall(sendBossWebhook, info, "despawn")
                    end
                    lastActive[info.regionId] = now
                end
            end
        end)
    end
    
    -- ========== Boss Region ESP ==========
    local BossESPFolder = nil
    local function ensureBossESPFolder()
        if BossESPFolder and BossESPFolder.Parent then return BossESPFolder end
        local existing = PlayerGui:FindFirstChild("NNVN_BossRegionESP")
        if existing then existing:Destroy() end
        local folder = Instance.new("Folder")
        folder.Name = "NNVN_BossRegionESP"
        folder.Parent = PlayerGui
        BossESPFolder = folder
        return folder
    end

    local function clearBossRegionESP()
        local folder = ensureBossESPFolder()
        for _, child in ipairs(folder:GetChildren()) do
            child:Destroy()
        end
    end

    local function attachBossESP(info)
        if not info or not info.fx or not info.fx.Parent then return end
        if info.fx:FindFirstChild("NNVN_BossESP") then return end
        local folder = ensureBossESPFolder()
        local bb = Instance.new("BillboardGui")
        bb.Name = "NNVN_BossESP"
        bb.Size = UDim2.fromOffset(220, 42)
        bb.StudsOffset = Vector3.new(0, 6, 0)
        bb.AlwaysOnTop = true
        bb.Adornee = info.fx
        bb.Parent = folder
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.fromScale(1, 1)
        lbl.BackgroundTransparency = 1
        lbl.Text = "🔥 BOSS: " .. tostring(info.regionName)
        lbl.TextColor3 = Color3.fromRGB(255, 50, 50)
        lbl.TextStrokeTransparency = 0.25
        lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
        lbl.Font = Enum.Font.GothamBlack
        lbl.TextSize = 16
        lbl.Parent = bb
        local hl = Instance.new("Highlight")
        hl.Name = "NNVN_BossHL"
        hl.Adornee = info.fx
        hl.FillColor = Color3.fromRGB(255, 40, 40)
        hl.OutlineColor = Color3.fromRGB(255, 200, 50)
        hl.FillTransparency = 0.7
        hl.OutlineTransparency = 0.1
        hl.Parent = folder
    end

    local _bossSpawnerFXLib
    local function getBossSpawnerFXLib()
        if _bossSpawnerFXLib ~= nil then return _bossSpawnerFXLib ~= false and _bossSpawnerFXLib or nil end
        local ok, lib = pcall(function()
            return require(ReplicatedStorage.Shared.Lib.BossSpawnerFX)
        end)
        if ok and type(lib) == "table" then
            _bossSpawnerFXLib = lib
            return lib
        end
        _bossSpawnerFXLib = false
        return nil
    end
    local function enableBossRegionVisual(info)
        if not info then return false end
        local region = info.region
        local fx = info.fx
        local lib = getBossSpawnerFXLib()
        if lib and region and type(lib.GetForRegion) == "function" then
            pcall(function()
                local nativeFX = lib.GetForRegion(region)
                if nativeFX then
                    if type(lib.SetVisualsEnabled) == "function" then lib.SetVisualsEnabled(nativeFX, true) end
                    if type(lib.IsActive) == "function" then info.active = lib.IsActive(nativeFX) end
                    if nativeFX:IsA("BasePart") then
                        info.fx = nativeFX
                        info.position = nativeFX.Position
                        info.cf = nativeFX.CFrame
                    end
                    fx = info.fx or nativeFX
                end
            end)
        end
        local target = fx or region
        if not target then return false end
        pcall(function()
            for _, d in ipairs(target:GetDescendants()) do
                if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
                    d.Enabled = true
                elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
                    d.Enabled = true
                end
            end
        end)
        return true
    end

    local function updateBossRegionESP()
        if not S.BossRegionESP then
            clearBossRegionESP()
            return
        end
        clearBossRegionESP()
        local ok, spawners = pcall(scanBossSpawnersExtended)
        if not ok or type(spawners) ~= "table" then return end
        for _, info in ipairs(spawners) do
            enableBossRegionVisual(info)
            if info.active and info.fx then
                attachBossESP(info)
            end
        end
    end

    local function startBossRegionESPLoop()
        task.spawn(function()
            while true do
                task.wait(2)
                pcall(updateBossRegionESP)
            end
        end)
    end

    -- ========== Boss Phase / Telegraph / Roar hooks ==========
    local _bossHooksBound = false
    local function bindBossFightHooks()
        if _bossHooksBound then return end
        local ctrl = getFishingController()
        if not ctrl then return end

        -- Phase logger + auto skill
        if ctrl.FishBossPhase then
            local conn = ctrl.FishBossPhase
            if type(conn) == "table" and conn.OnClientEvent then
                conn.OnClientEvent:Connect(function(char, newPhase)
                    local phase = tonumber(newPhase) or newPhase
                    -- boss phase
                    setStatus("bossfight", ("Phase %s"):format(tostring(phase)))
                    if S.AutoSkillOnBossPhase then
                        pcall(useSkillsOnce)
                    end
                end)
                _bossHooksBound = true
            elseif typeof(conn) == "RBXScriptSignal" then
                conn:Connect(function(char, newPhase)
                    local phase = tonumber(newPhase) or newPhase
                    -- boss phase
                    setStatus("bossfight", ("Phase %s"):format(tostring(phase)))
                    if S.AutoSkillOnBossPhase then
                        pcall(useSkillsOnce)
                    end
                end)
                _bossHooksBound = true
            end
        end

        -- Telegraph alert
        if ctrl.FishBossTelegraph then
            local conn = ctrl.FishBossTelegraph
            local function onTelegraph(char, duration)
                local name = (char and char.Name) or "Boss"
                local dur = tonumber(duration) or 0
                notify("⚠️ Boss Warning", ("%s telegraph (%.1fs)"):format(name, dur))
                setStatus("bossfight", ("Telegraph %.1fs"):format(dur))
            end
            if type(conn) == "table" and conn.OnClientEvent then
                conn.OnClientEvent:Connect(onTelegraph)
            elseif typeof(conn) == "RBXScriptSignal" then
                conn:Connect(onTelegraph)
            end
        end

        -- Roar auto-dodge
        if ctrl.FishBossRoar then
            local conn = ctrl.FishBossRoar
            local function onRoar(char, duration)
                if not S.AutoDodgeBossRoar then return end
                local root = getRoot()
                if not root then return end
                local back = root.CFrame.LookVector * -35
                local target = root.CFrame + back + Vector3.new(0, 5, 0)
                notify("💨 Boss Roar", "Auto-dodging...")
                task.spawn(function()
                    tweenTo(target, S.TweenSpeed)
                end)
            end
            if type(conn) == "table" and conn.OnClientEvent then
                conn.OnClientEvent:Connect(onRoar)
            elseif typeof(conn) == "RBXScriptSignal" then
                conn:Connect(onRoar)
            end
        end
    end

    -- Retry binding hooks
    task.spawn(function()
        for _ = 1, 80 do
            if getFishingController() then
                bindBossFightHooks()
                if _bossHooksBound then break end
            end
            task.wait(0.25)
        end
    end)

    -- ========== Boss Catch History ==========
    local function isBossFishId(fishId)
        if not fishId then return false end
        local ok, Catalog = pcall(function()
            return require(ReplicatedStorage.Data.Catalog)
        end)
        if not ok or type(Catalog) ~= "table" or not Catalog.Boss then return false end
        local Boss = Catalog.Boss
        local getWeatherIds = Boss.GetWeatherIds
        local getPool = Boss.GetPool
        if type(getWeatherIds) ~= "function" or type(getPool) ~= "function" then
            -- Fallback: check if fishId string contains "boss"
            return tostring(fishId):lower():find("boss", 1, true) ~= nil
        end
        local ok2, weatherIds = pcall(getWeatherIds, Boss)
        if not ok2 or type(weatherIds) ~= "table" then return false end
        for _, wid in ipairs(weatherIds) do
            local ok3, pool = pcall(getPool, Boss, wid)
            if ok3 and type(pool) == "table" then
                for _, boss in ipairs(pool) do
                    if boss and (boss.id == fishId or boss.Id == fishId) then
                        return true
                    end
                end
            end
        end
        return false
    end

    local function recordBossCatch(fishId, weight)
        S.BossCaughtCount = (S.BossCaughtCount or 0) + 1
        table.insert(S.BossHistory, {
            id = tostring(fishId),
            weight = weight,
            time = os.time(),
        })
        -- Keep last 50
        while #S.BossHistory > 50 do
            table.remove(S.BossHistory, 1)
        end
        notify("🏆 Boss Caught", ("%s (total: %d)"):format(tostring(fishId), S.BossCaughtCount))
        setStatus("bosshistory", ("Caught %d bosses | Last: %s"):format(S.BossCaughtCount, tostring(fishId)))
        -- boss caught
    end

    local function bindBossCatchHistory()
        local ctrl = getFishingController()
        if not ctrl or not ctrl.StateChanged then return end
        ctrl.StateChanged:Connect(function(newState, extra)
            if newState ~= "Caught" then return end
            local fishId = nil
            local weight = nil
            if type(extra) == "table" then
                fishId = extra.fishId or extra.FishId or extra.id
                weight = extra.weight or extra.Weight
            end
            if not fishId then
                local id = getFishInfo()
                fishId = id
            end
            if fishId and isBossFishId(fishId) then
                recordBossCatch(fishId, weight)
            end
        end)
    end

    task.spawn(function()
        for _ = 1, 80 do
            if getFishingController() then
                pcall(bindBossCatchHistory)
                break
            end
            task.wait(0.25)
        end
    end)

    local function dumpBossHistory()
        local lines = { ("=== Boss Catch History (%d) ==="):format(S.BossCaughtCount or 0) }
        for i, entry in ipairs(S.BossHistory or {}) do
            local t = entry.time and os.date("%H:%M:%S", entry.time) or "?"
            lines[#lines + 1] = ("  %d. %s | weight=%s | %s"):format(
                i, tostring(entry.id), tostring(entry.weight or "?"), t)
        end
        -- dump suppressed
        notify("Boss History", ("%d catches — see F9"):format(#(S.BossHistory or {})))
    end

    local function dumpBossPools()
        local ok, Catalog = pcall(function()
            return require(ReplicatedStorage.Data.Catalog)
        end)
        if not ok or type(Catalog) ~= "table" or not Catalog.Boss then
            setStatus("bossalert", "Boss 目录不可用")
            notify("Boss Pool", "Catalog.Boss not found")
            return
        end
        local Boss = Catalog.Boss
        if type(Boss.GetWeatherIds) ~= "function" then
            setStatus("bossalert", "GetWeatherIds missing")
            return
        end
        local lines = { "=== Boss Pools ===" }
        local ok2, weatherIds = pcall(Boss.GetWeatherIds, Boss)
        if ok2 and type(weatherIds) == "table" then
            for _, weatherId in ipairs(weatherIds) do
                lines[#lines + 1] = ("=== %s ==="):format(tostring(weatherId))
                local ok3, pool = pcall(Boss.GetPool, Boss, weatherId)
                if ok3 and type(pool) == "table" then
                    for _, boss in ipairs(pool) do
                        lines[#lines + 1] = ("  %s | %s"):format(
                            tostring(boss.id or boss.Id or "?"),
                            tostring(boss.name or boss.Name or "?"))
                    end
                end
            end
        end
        -- dump suppressed
        notify("Boss Pool", "Dumped to F9")
        setStatus("bossalert", "Boss pools dumped (F9)")
    end

    -- Export
    env.sendBossWebhook = sendBossWebhook
    env.startBossSpawnAlertLoop = startBossSpawnAlertLoop
    env.startBossRegionESPLoop = startBossRegionESPLoop
    env.updateBossRegionESP = updateBossRegionESP
    env.clearBossRegionESP = clearBossRegionESP
    env.bindBossFightHooks = bindBossFightHooks
    env.dumpBossHistory = dumpBossHistory
    env.dumpBossPools = dumpBossPools
    env.recordBossCatch = recordBossCatch

    -- Auto-start loops
    startBossSpawnAlertLoop()
    startBossRegionESPLoop()
end

-- ============================================================
-- FUNCTION 6: setupInfoBar
-- ============================================================
local function setupInfoBar(env)
    local PlayerGui = PlayerGui
    local RunService = RunService
    local Stats = Stats
    local S = env.S
    local getRoot = env.getRoot
    local getIslandForPosition = env.getIslandForPosition

    if PlayerGui:FindFirstChild("NNVN_FishingMaster_InfoBar") then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "NNVN_FishingMaster_InfoBar"
    gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.Parent = PlayerGui
    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = Color3.fromRGB(8,8,8)
    frame.BorderColor3 = Color3.fromRGB(245,245,245); frame.BorderSizePixel = 1
    frame.Position = UDim2.fromOffset(8,112); frame.Size = UDim2.fromOffset(560,24)
    frame.Parent = gui; frame.Active = true; frame.Draggable = true
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1; label.TextColor3 = Color3.fromRGB(255,255,255)
    label.Font = Enum.Font.GothamMedium; label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Position = UDim2.fromOffset(8,0); label.Size = UDim2.new(1,-12,1,0)
    label.Text = "Fishing Master v1.4.8 | -- ms | -- FPS | Island: Unknown"
    label.Parent = frame
    local frames, last = 0, os.clock()
    RunService.RenderStepped:Connect(function()
        frames += 1
        local now = os.clock()
        if now - last >= 1 then
            local fps = frames; frames = 0; last = now
            gui.Enabled = S.InfoBarEnabled ~= false
            frame.Visible = S.InfoBarEnabled ~= false
            local ping = "-- ms"
            pcall(function() ping = Stats.Network.ServerStatsItem["Data Ping"]:GetValueString() end)
            local island = "Unknown"
            pcall(function()
                local root = getRoot and getRoot()
                if root and getIslandForPosition then island = getIslandForPosition(root.Position) end
            end)
            local parts = {}
            if S.InfoShowGameName ~= false then parts[#parts+1] = "Fishing Master v1.4.8" end
            if S.InfoShowPing ~= false then parts[#parts+1] = tostring(ping) end
            if S.InfoShowFPS ~= false then parts[#parts+1] = tostring(fps) .. " FPS" end
            if S.InfoShowIsland ~= false then parts[#parts+1] = "Island: " .. tostring(island) end
            if S.InfoShowDismiss ~= false then parts[#parts+1] = "Dismiss:" .. (S.AutoDismissPopup and "开启" or "关闭") end
            label.Text = table.concat(parts, " | ")
        end
    end)
end

-- ============================================================
-- FUNCTION 7: setupFly
-- ============================================================
local function setupFly(env)
    local S = env.S
    local RunService = RunService
    local UserInputService = UserInputService
    local getRoot = env.getRoot

    local flyBV, flyBG
    local function setFly(on)
        S.Fly = on
        local root = getRoot()
        if not root then return end
        if not on then
            if flyBV then flyBV:Destroy(); flyBV = nil end
            if flyBG then flyBG:Destroy(); flyBG = nil end
            return
        end
        flyBV = flyBV or Instance.new("BodyVelocity")
        flyBV.MaxForce = Vector3.new(1e9,1e9,1e9); flyBV.Parent = root
        flyBG = flyBG or Instance.new("BodyGyro")
        flyBG.MaxTorque = Vector3.new(1e9,1e9,1e9); flyBG.Parent = root
        task.spawn(function()
            while S.Fly and flyBV and flyBG do
                local cam = workspace.CurrentCamera
                local move = Vector3.zero
                if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += cam.CFrame.LookVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= cam.CFrame.LookVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= cam.CFrame.RightVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += cam.CFrame.RightVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
                if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.yAxis end
                flyBV.Velocity = move.Magnitude > 0 and move.Unit * S.FlySpeed or Vector3.zero
                flyBG.CFrame = cam.CFrame
                task.wait()
            end
        end)
    end
    env.setFly = setFly

    local invisibleConn = nil
    local invisibleFocus = nil
    local invisiblePrevNoClip = nil
    local invisiblePrevCamType = nil
    local invisiblePrevCamSubject = nil
    local invisibleCamY = nil
    local invisibleFocusCFrame = nil
    local invisibleFootPart = nil
    local freezeCFrame = nil

    local function setSafeFarmInvisible(on)
        S.SafeFarmInvisible = on == true

        if invisibleConn then
            pcall(function() invisibleConn:Disconnect() end)
            invisibleConn = nil
        end

        local camera = workspace.CurrentCamera
        if S.SafeFarmInvisible then
            local root = getRoot()
            if not root then
                S.SafeFarmInvisible = false
                return
            end

            invisiblePrevNoClip = S.Noclip
            invisiblePrevCamType = camera and camera.CameraType
            invisiblePrevCamSubject = camera and camera.CameraSubject
            S.Noclip = true
            invisibleCamY = (camera and camera.CFrame.Position.Y) or (root.Position.Y + 8)
            invisibleFocusCFrame = CFrame.new(root.Position.X, invisibleCamY, root.Position.Z)

            if invisibleFocus and invisibleFocus.Parent then
                invisibleFocus:Destroy()
            end
            invisibleFocus = Instance.new("Part")
            invisibleFocus.Name = "NNVN_InvisibleCamFocus"
            invisibleFocus.Size = Vector3.new(1, 1, 1)
            invisibleFocus.Anchored = true
            invisibleFocus.CanCollide = false
            invisibleFocus.CanTouch = false
            invisibleFocus.CanQuery = false
            invisibleFocus.Transparency = 1
            invisibleFocus.Parent = workspace

            if invisibleFootPart and invisibleFootPart.Parent then
                invisibleFootPart:Destroy()
            end
            invisibleFootPart = Instance.new("Part")
            invisibleFootPart.Name = "NNVN_InvisibleFootPlatform"
            invisibleFootPart.Size = Vector3.new(7, 0.35, 7)
            invisibleFootPart.Anchored = true
            invisibleFootPart.CanCollide = true
            invisibleFootPart.CanTouch = false
            invisibleFootPart.CanQuery = false
            invisibleFootPart.Transparency = 1
            invisibleFootPart.Parent = workspace

            invisibleFocus.CFrame = invisibleFocusCFrame
            local hiddenY = math.min(root.Position.Y - 90, -45)
            root.CFrame = CFrame.new(root.Position.X, hiddenY, root.Position.Z)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            invisibleFootPart.CFrame = CFrame.new(root.Position.X, hiddenY - 3.1, root.Position.Z)
            if camera then
                camera.CameraType = Enum.CameraType.Custom
                camera.CameraSubject = invisibleFocus
            end

            invisibleConn = RunService.RenderStepped:Connect(function()
                if not S.SafeFarmInvisible then return end
                local currentRoot = getRoot()
                local currentCamera = workspace.CurrentCamera
                if not currentRoot then return end
                if invisibleFootPart and invisibleFootPart.Parent then
                    invisibleFootPart.CFrame = CFrame.new(currentRoot.Position.X, currentRoot.Position.Y - 3.1, currentRoot.Position.Z)
                end
                if invisibleFocus and invisibleFocus.Parent then
                    invisibleFocus.CFrame = invisibleFocusCFrame or CFrame.new(currentRoot.Position.X, invisibleCamY or currentRoot.Position.Y + 58, currentRoot.Position.Z)
                end
                if currentCamera and invisibleFocus then
                    if currentCamera.CameraSubject ~= invisibleFocus then currentCamera.CameraSubject = invisibleFocus end
                    if currentCamera.CameraType ~= Enum.CameraType.Custom then currentCamera.CameraType = Enum.CameraType.Custom end
                end
            end)
        else
            if camera then
                pcall(function()
                    if invisiblePrevCamSubject and invisiblePrevCamSubject.Parent then
                        camera.CameraSubject = invisiblePrevCamSubject
                    else
                        local hum = env.getHumanoid()
                        if hum then camera.CameraSubject = hum end
                    end
                    camera.CameraType = invisiblePrevCamType or Enum.CameraType.Custom
                end)
            end
            if invisibleFocus and invisibleFocus.Parent then
                invisibleFocus:Destroy()
            end
            invisibleFocus = nil
            if invisibleFootPart and invisibleFootPart.Parent then
                invisibleFootPart:Destroy()
            end
            invisibleFootPart = nil
            if invisiblePrevNoClip == false then
                S.Noclip = false
            end
            invisiblePrevNoClip = nil
            invisiblePrevCamType = nil
            invisiblePrevCamSubject = nil
            invisibleCamY = nil
            invisibleFocusCFrame = nil
        end
    end
    env.setSafeFarmInvisible = setSafeFarmInvisible

    UserInputService.JumpRequest:Connect(function()
        if S.InfiniteJump then
            local hum = env.getHumanoid()
            if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
        end
    end)

    RunService.RenderStepped:Connect(function()
        local hum = env.getHumanoid()
        local root = getRoot()
        if S.FreezePlayer then
            freezeCFrame = freezeCFrame or (root and root.CFrame)
            if hum then
                pcall(function()
                    hum.PlatformStand = true
                    hum.WalkSpeed = 0
                    hum.JumpPower = 0
                end)
            end
            if root then
                pcall(function()
                    if freezeCFrame then root.CFrame = freezeCFrame end
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end)
            end
            return
        end
        freezeCFrame = nil
        if hum then hum.WalkSpeed = S.WalkSpeed; hum.JumpPower = S.JumpPower end
        if S.Noclip and env.getChar() then
            for _, part in ipairs(env.getChar():GetDescendants()) do
                if part:IsA("BasePart") then part.CanCollide = false end
            end
        end
        if S.FullBright then
            Lighting.Brightness = 2; Lighting.ClockTime = 14
            Lighting.FogEnd = 100000; Lighting.GlobalShadows = false
        end
        if S.NoFog then
            Lighting.FogStart = 0
            Lighting.FogEnd = 1000000
            pcall(function() Lighting.Atmosphere.Density = 0 end)
            pcall(function() Lighting.Atmosphere.Haze = 0 end)
        end
        if S.UnlockFarView then
            Lighting.FogEnd = 10000000
            pcall(function() workspace.StreamingEnabled = false end)
            pcall(function()
                local camera = workspace.CurrentCamera
                if camera then camera.FarPlaneZ = 1000000 end
            end)
        end
        if S.WalkOnWater then
            local oceanPlane = nil
            pcall(function()
                local ocean = workspace:FindFirstChild("Ocean")
                oceanPlane = ocean and ocean:FindFirstChild("OceanPlane")
            end)
            local p = workspace:FindFirstChild("NNVN_WalkOnWater")
            if not p then
                p = Instance.new("Part")
                p.Name = "NNVN_WalkOnWater"
                p.Anchored = true
                p.CanCollide = true
                p.CanTouch = false
                p.CanQuery = false
                p.CastShadow = false
                p.Material = Enum.Material.SmoothPlastic
                p.Transparency = 1 -- tàng hình
                p.Parent = workspace
            end
            if oceanPlane and oceanPlane:IsA("BasePart") then
                -- Che hết bề mặt OceanPlane (size ~1736 x 0.001 x 1736)
                p.Size = Vector3.new(
                    math.max(oceanPlane.Size.X, 1736),
                    1,
                    math.max(oceanPlane.Size.Z, 1736)
                )
                p.CFrame = CFrame.new(oceanPlane.Position.X, oceanPlane.Position.Y + 0.5, oceanPlane.Position.Z)
            else
                -- Fallback nếu không tìm thấy OceanPlane
                p.Size = Vector3.new(1736, 1, 1736)
                local root = getRoot()
                if root then
                    p.CFrame = CFrame.new(root.Position.X, root.Position.Y - 3, root.Position.Z)
                end
            end
        else
            local p = workspace:FindFirstChild("NNVN_WalkOnWater")
            if p then p:Destroy() end
        end
        if S.BoatSpeedEnabled then pcall(env.applyBoatSpeed) end
        pcall(env.applyStreamer)
    end)

    -- Anti AFK (default ON) — virtual idle input to prevent kick
    task.spawn(function()
        while true do
            task.wait(60)
            if S.AntiAFK then
                pcall(function()
                    local vim = game:GetService("VirtualUser")
                    vim:CaptureController()
                    vim:ClickButton2(Vector2.new())
                end)
                pcall(function()
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
                    task.wait(0.05)
                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
                end)
            end
        end
    end)
end

-- ============================================================
-- FUNCTION 8: setupLanguage
-- ============================================================
local function setupLanguage(env)
    getgenv().NNVN_Language = getgenv().NNVN_Language or "English"
    env.S.SelectedLanguage = getgenv().NNVN_Language

    local LANGUAGE_OPTIONS = { "English", "Vietnamese", "Spanish", "Indonesian", "Portuguese" }

    local UI_TRANSLATIONS = {
        Vietnamese = {
            ["Farm"]="Farm",["主界面"]="Chính",["首页"]="Trang chủ",["玩家"]="玩家",["视觉"]="Hiển thị",
            ["商店 / 开箱"]="Cửa hàng / Crate",["杂项"]="Khác",["设置"]="Cài đặt",["Info"]="Thông tin",
            ["状态"]="Trạng thái",["语言"]="Ngôn ngữ",["应用语言"]="Áp dụng ngôn ngữ",
            ["主题"]="Giao diện",["Transparent Window"]="Cửa sổ trong suốt",
            ["Hide Search Bar"]="Ẩn thanh tìm kiếm",["Scroll Bar Enabled"]="Bật thanh cuộn",
            ["Refresh Themes List"]="Làm mới danh sách giao diện",
            ["图片主题说明"]="Hướng dẫn Image Theme",
            ["Open Roblox Creator Store, search for an image, copy the asset id, then paste only the number below."]="Mở Roblox Creator Store, tìm ảnh mong muốn, copy asset id rồi dán số vào ô bên dưới.",
            ["复制 Roblox 创作者贴图链接"]="Sao chép link Roblox Creator Decals",
            ["图片主题"]="图片主题",
            ["WindUI 设置"]="WindUI 设置",["钓鱼"]="钓鱼",
            ["挂机设置"]="Cài đặt Farm",["自动抛竿"]="Tự động quăng cần",
            ["自动点击钓鱼（首次拉杆/收线）"]="Tự động click cá",
            ["自动小游戏（QTE方向键 + 收线）"]="Tự động kéo minigame",
            ["自动装备鱼竿"]="Tự trang bị cần câu",
            ["自动技能 Z/X/C/V"]="Tự dùng skill Z/X/C/V",
            ["自动使用技能（达到斩杀线）"]="Tự dùng skill khi tới dòng Execute",
            ["完美抛竿（始终满幸运值）"]="Perfect Cast (luôn max luck)",
            ["自动关闭捕获弹窗"]="Tự đóng popup bắt cá",
            ["使用技能（一次）"]="Dùng skill một lần",
            ["立即强制抛竿"]="Quăng cần ngay",["调试状态"]="Debug trạng thái",
            ["技能顺序"]="Thứ tự skill",["自动倍率 X"]="Hệ số Auto X",
            ["抛竿最短蓄力 (秒)"]="Giữ cast tối thiểu (s)",
            ["抛竿最长蓄力 (秒)"]="Giữ cast tối đa (s)",
            ["自动点击延迟 (毫秒)"]="Độ trễ auto click (ms)",
            ["自动拉杆延迟 (毫秒)"]="Độ trễ auto pull (ms)",
            ["技能释放血量 (%)"]="HP dùng skill Execute (%)",
            ["传送岛屿"]="Dịch chuyển đảo",["岛屿"]="Đảo",["平滑移动速度"]="Tốc độ Tween",
            ["移动安全提示"]="Ghi chú an toàn di chuyển",
            ["Do not set Tween Speed or WalkSpeed too high, otherwise the server may kick you."]="Không nên để Tween Speed hoặc WalkSpeed quá cao, nếu không server có thể kick bạn.",
            ["平滑移动速度数值"]="Nhập tốc độ Tween",
            ["出售/抽卡前平滑移动"]="Tween trước Shop / Sell / Gacha",
            ["Teleport (Tween)"]="Dịch chuyển (Tween)",["传送模式"]="Chế độ dịch chuyển",
            ["传送"]="Dịch chuyển",["服务器 ID"]="服务器 ID",
            ["加入服务器 ID"]="Vào Job ID",["复制服务器 ID"]="Sao chép Job ID",
            ["重新加入当前服务器"]="Rejoin Job hiện tại",
            ["Boss Spawn Status"]="Trạng thái Boss",["Scan Now"]="Quét ngay",
            ["Tween To Active Boss"]="Tween tới Boss",
            ["Auto Farm Secret Boss"]="Tự farm Secret Boss",
            ["自动刷 Boss（传送 + 全套钓鱼）"]="Tự farm Boss",
            ["Boss 挂机 [不可用]"]="Boss Farm [Không hoạt động]",
            ["Go To Boss Now"]="Đến Boss ngay",
            ["停止挂机 + 移除平台"]="Dừng farm + xóa platform",
            ["Auto Unlock Island"]="Tự mở khóa đảo",
            ["要解锁的岛屿"]="Đảo cần mở khóa",
            ["自动解锁选中岛屿"]="Tự mở khóa đảo đã chọn",
            ["解锁（一次）"]="Mở khóa một lần",
            ["移动"]="Di chuyển",["飞行"]="Bay",["飞行速度"]="Tốc độ bay",
            ["行走速度警告"]="Cảnh báo WalkSpeed",
            ["Do not set WalkSpeed too high, otherwise the server may kick you."]="Không nên để WalkSpeed quá cao, nếu không server có thể kick bạn.",
            ["行走速度"]="Tốc độ đi",["跳跃力"]="Lực nhảy",["穿墙"]="穿墙",
            ["行走速度数值"]="Nhập tốc độ đi",
            ["无限跳跃"]="Nhảy vô hạn",["全亮"]="全亮",
            ["水上行走"]="Đi trên nước",["船只"]="Thuyền",
            ["Boat Travel Note"]="Ghi chú đi thuyền",
            ["Teleport Mode Boat will walk to Boat Merchant, summon a boat, sit in the driver seat, then drive to the selected island."]="Chế độ Boat sẽ đi bộ tới Boat Merchant, triệu hồi thuyền, ngồi vào ghế lái, rồi lái tới đảo đã chọn.",
            ["载具移动提示"]="Ghi chú di chuyển bằng xe",
            ["Teleport Mode Boat will walk to the current island vehicle merchant, summon the selected vehicle, sit in the driver seat, then drive to the selected island."]="Chế độ Boat sẽ đi tới Vehicle Merchant của đảo hiện tại, triệu hồi xe đã chọn, ngồi vào ghế lái, rồi lái tới đảo đã chọn.",
            ["载具"]="Xe",
            ["Truck - Free"]="Truck - Miễn phí",
            ["Red Truck - 50000"]="Red Truck - 50000",
            ["船速度"]="Tốc độ thuyền",
            ["船速度数值"]="Nhập tốc độ thuyền",
            ["设置船速度"]="Đặt tốc độ thuyền",
            ["应用船速度（一次）"]="Áp dụng tốc độ thuyền",
            ["已保存位置"]="Vị trí đã lưu",
            ["保存当前位置"]="Lưu vị trí hiện tại",
            ["回到保存的位置"]="Quay lại vị trí đã lưu",
            ["自动出售"]="Tự bán",["出售方式"]="Cách bán",
            ["Auto Sell (server-side)"]="Tự bán (server-side)",
            ["背包满时自动出售"]="Tự bán khi balo đầy",
            ["Preview Payout"]="Xem trước tiền bán",
            ["出售一次（选中方式）"]="Bán một lần",
            ["出售手持鱼"]="Bán cá đang cầm",
            ["Sell All (NPC)"]="Bán tất cả (NPC)",
            ["Sell All Anywhere"]="Bán tất cả mọi nơi",
            ["自动锁定鱼"]="Tự khóa cá",
            ["Auto Lock Held Fish"]="Tự khóa cá đang cầm",
            ["Choose fish or rarity, then auto lock."]="Chọn cá hoặc độ hiếm, sau đó tự khóa.",
            ["要锁定的鱼"]="Cá cần khóa",
            ["要锁定的稀有度"]="Độ hiếm cần khóa",
            ["鱼类过滤"]="Bộ lọc cá",
            ["优先级"]="Ưu tiên",
            ["功能优先级"]="Ưu tiên chức năng",
            ["Farming Priority"]="Ưu tiên Farm",
            ["Auto Sell Priority"]="Ưu tiên tự bán",
            ["Fish Filter Priority"]="Ưu tiên bộ lọc cá",
            ["Auto Lock Priority"]="Ưu tiên tự khóa",
            ["Shop / Gacha Priority"]="Ưu tiên Shop / Gacha",
            ["Auto Quest Priority"]="Ưu tiên Auto Quest",
            ["Boss Priority"]="Ưu tiên Boss",
            ["Rewards Priority"]="Ưu tiên phần thưởng",
            ["重置优先级默认值"]="Đặt lại ưu tiên mặc định",
            ["跳过过滤掉的鱼"]="Tự miss cá bị lọc",
            ["自动任务 Pro"]="自动任务 Pro",
            ["自动任务（完整链）"]="Tự chạy toàn bộ chuỗi Quest",
            ["条件不足时自动钓鱼升级"]="Tự farm khi thiếu yêu cầu",
            ["自动购买所需鱼竿"]="Tự mua cần khi thiếu điều kiện",
            ["按任务自动设置鱼类过滤"]="Tự đặt bộ lọc cá theo Quest",
            ["背包满时出售（金币任务用）"]="Tự bán khi đầy (Quest cần coin)",
            ["详细日志 (F9)"]="Log chi tiết (F9)",
            ["步进延迟 (秒)"]="Độ trễ mỗi bước (s)",
            ["跳过当前任务"]="Bỏ qua Quest hiện tại",
            ["Run One Step Now"]="Chạy một bước ngay",
            ["Apply Quest Filter Now"]="Áp dụng bộ lọc Quest ngay",
            ["Clear Quest Filter"]="Xóa bộ lọc Quest",
            ["鱼类监控"]="Theo dõi cá",
            ["抛竿位置"]="Vị trí quăng cần",
            ["鱼类过滤使用说明"]="Cách dùng bộ lọc cá",
            ["Select fish or rarity here to make auto fishing ignore them. If Auto Miss is enabled, matching fish will press the wrong QTE direction on purpose."]="Chọn cá hoặc độ hiếm ở đây để auto câu bỏ qua. Nếu bật Auto Miss, cá khớp bộ lọc sẽ cố ý bấm sai hướng QTE.",
            ["已忽略的过滤"]="Bộ lọc bỏ qua",
            ["No ignored fish filter. Auto fishing will handle every fish."]="Chưa có bộ lọc bỏ qua. Auto câu sẽ xử lý mọi cá.",
            ["要忽略的鱼"]="Cá cần bỏ qua",
            ["匹配的鱼"]="Cá khớp bộ lọc",
            ["匹配数量"]="Đếm cá khớp",
            ["预览匹配列表"]="Xem danh sách khớp",
            ["清除所有过滤"]="Xóa bộ lọc",
            ["自动锁定选中的鱼"]="Tự khóa cá đã chọn",
            ["锁定选中鱼（一次）"]="Khóa cá đã chọn một lần",
            ["切换锁定手持鱼"]="Bật/tắt khóa cá",
            ["检查手持鱼 UID"]="Kiểm tra UID cá",
            ["购买鱼竿"]="Mua cần",["鱼竿"]="Cần câu",
            ["金币够时自动购买"]="Tự mua khi đủ tiền",
            ["购买一次"]="Mua một lần",["Mod Skin"]="Mod Skin",["Rod Skin"]="Skin cần",
            ["Apply Local Skin"]="Áp dụng skin local",
            ["透视"]="透视",["透视距离"]="Khoảng cách ESP",
            ["Player ESP (shows island)"]="ESP người chơi (hiện đảo)",
            ["NPC ESP"]="ESP NPC",["Fish ESP"]="ESP cá",
            ["Guide ESP"]="ESP hướng dẫn",["Box / Crate ESP"]="ESP Box / Crate",
            ["清除透视"]="Xóa ESP",["地图透视"]="X-Ray bản đồ",
            ["外观娱乐"]="Hiệu ứng vui",["头像闪烁"]="Lấp lánh nhân vật",
            ["伪造数据"]="Fake chỉ số",["伪造金币"]="伪造金币",["伪造宝石"]="伪造宝石",
            ["伪造界面金币/宝石"]="伪造界面金币/宝石",
            ["同时伪造排行榜"]="Fake cả bảng xếp hạng",
            ["主播模式"]="Chế độ Streamer",
            ["重命名所有玩家"]="Đổi tên tất cả người chơi",
            ["自定义名称"]="Tên tùy chỉnh",
            ["技能抽卡"]="技能抽卡",
            ["光环抽卡"]="Aura Gacha",
            ["开箱"]="开箱",["货币"]="Tiền tệ",
            ["抽卡次数"]="Số lần quay",
            ["预览价格（报价）"]="Xem trước giá",
            ["单次抽卡"]="Quay một lần",["抽 10 次"]="Quay x10",["抽 1 次"]="Quay x1",
            ["自动技能抽卡"]="Tự Skill Gacha",
            ["自动光环抽卡"]="Tự quay Aura",
            ["查看保底"]="Xem Pity",["预览消耗"]="Xem trước chi phí",
            ["开箱"]="开箱",["开箱次数"]="Số lần mở",
            ["开一次（带确认）"]="Mở một lần (có xác nhận)",
            ["开 1 个"]="Mở x1",["开 10 个"]="Mở x10",
            ["⚡ 快速开箱（无确认）"]="⚡ Mở nhanh (không xác nhận)",
            ["自动开箱"]="Tự mở Crate",["抽卡延迟"]="Độ trễ Gacha",
            ["保留金币余额"]="Giữ dự trữ Coin",
            ["保留宝石余额"]="Giữ dự trữ Gem",
            ["奖励"]="Phần thưởng",
            ["自动领取奖励"]="Tự nhận phần thưởng",
            ["领取奖励（一次）"]="Nhận phần thưởng một lần",
            ["复制当前服务器 ID"]="Sao chép Job ID hiện tại",
            ["加入输入的服务器 ID"]="Vào Job ID đã nhập",
            ["兑换码"]="Code",
            ["兑换所有码（从模块）"]="Đổi tất cả code",
            ["导出兑换码（仅查看）"]="Xem danh sách code",
            ["查看"]="Tầm nhìn",
            ["去雾"]="Không sương mù",
            ["解锁远景"]="Mở khóa tầm nhìn xa",
            ["访问标签"]="Thẻ truy cập",["作者"]="Tác giả",
            ["玩家信息"]="Thông tin người chơi",
            ["刷新玩家信息"]="Làm mới thông tin",
            ["Discord"]="Discord",
            ["复制 Discord 邀请链接"]="Sao chép Discord Invite",
            ["Join Discord for hub updates"]="Vào Discord để nhận cập nhật hub",
            ["Discord 状态"]="Trạng thái Discord",
            ["刷新 Discord 状态"]="Làm mới trạng thái Discord",
            ["刷新访问标签"]="Làm mới thẻ truy cập",
            ["空闲"]="Chờ",["打开菜单"]="Mở Menu",
            ["传送警告"]="Cảnh báo Teleport",
            ["Teleport should not be used because it may kick you. We will not respond to reports about this issue."]="Không nên sử dụng Teleport vì có thể bị kick. Chúng tôi sẽ không phản hồi về vấn đề này.",
            ["Waiting for active fishing..."]="Đợi đang câu cá...",
            ["Next interval sell in"]="Tự bán sau",
            ["Interval reached - selling..."]="Đến giờ bán - đang bán...",
            ["Sold"]="Đã bán",
            ["Walking to Fish Seller..."]="Đang đi tới NPC bán cá...",
            ["Path blocked - walk failed to Fish Seller"]="Đường bị chặn - không đi bộ tới NPC bán cá được",
        },
        Spanish = {
            ["首页"]="Inicio",["Farm"]="Granja",["玩家"]="Jugador",["视觉"]="视觉",["商店 / 开箱"]="Tienda / Caja",["杂项"]="Extra",["设置"]="Ajustes",
            ["状态"]="Estado",["语言"]="Idioma",["应用语言"]="Aplicar idioma",["钓鱼"]="Pesca",["移动"]="Movimiento",["传送岛屿"]="Teletransportar isla",
            ["岛屿"]="Isla",["传送模式"]="Modo de transporte",["传送"]="Transportar",["行走速度"]="Velocidad",["行走速度警告"]="Aviso de velocidad",
            ["自动出售"]="Venta automatica",["自动锁定鱼"]="Bloqueo de peces",["鱼类过滤"]="Filtro de peces",
            ["优先级"]="Prioridad",["跳过过滤掉的鱼"]="Auto fallar peces filtrados",
            ["鱼类过滤使用说明"]="Como usar el filtro de peces",
            ["Select fish or rarity here to make auto fishing ignore them. If Auto Miss is enabled, matching fish will press the wrong QTE direction on purpose."]="Selecciona peces o rareza aqui para ignorarlos. Si Auto Miss esta activado, los peces coincidentes pulsaran la direccion QTE incorrecta.",
            ["已忽略的过滤"]="Filtro ignorado",["No ignored fish filter. Auto fishing will handle every fish."]="Sin filtro ignorado. La pesca automatica manejara todos los peces.",
            ["要忽略的鱼"]="Pez a ignorar",["稀有度"]="Rareza",["名称包含"]="Nombre contiene",["匹配的鱼"]="Peces coincidentes",
            ["匹配数量"]="Contar coincidencias",["预览匹配列表"]="Ver lista",["清除所有过滤"]="Limpiar filtros",
            ["查看"]="Vista",["去雾"]="Sin niebla",["解锁远景"]="Desbloquear vista lejana",["Discord 状态"]="Estado de Discord",["外观娱乐"]="Cosmeticos",["头像闪烁"]="Brillos del avatar",
            ["复制 Discord 邀请链接"]="Copiar invitacion Discord",["打开菜单"]="Abrir menu",
            ["Waiting for active fishing..."]="Esperando pesca activa...",
            ["Next interval sell in"]="Venta en",
            ["Interval reached - selling..."]="Intervalo listo - vendiendo...",
            ["Sold"]="Vendido",
            ["Walking to Fish Seller..."]="Caminando al vendedor de peces...",
            ["Path blocked - walk failed to Fish Seller"]="Camino bloqueado - no se pudo caminar al vendedor",
        },
        Indonesian = {
            ["首页"]="Beranda",["Farm"]="Farm",["玩家"]="Pemain",["视觉"]="视觉",["商店 / 开箱"]="Toko / Crate",["杂项"]="Lainnya",["设置"]="Pengaturan",
            ["状态"]="状态",["语言"]="Bahasa",["应用语言"]="Terapkan bahasa",["钓鱼"]="Memancing",["移动"]="Gerakan",["传送岛屿"]="Teleport pulau",
            ["岛屿"]="Pulau",["传送模式"]="Mode teleport",["传送"]="传送",["行走速度"]="Kecepatan jalan",["行走速度警告"]="Peringatan WalkSpeed",
            ["自动出售"]="Jual otomatis",["自动锁定鱼"]="Kunci ikan otomatis",["鱼类过滤"]="Filter ikan",
            ["优先级"]="Prioritas",["跳过过滤掉的鱼"]="Auto miss ikan filter",
            ["鱼类过滤使用说明"]="Cara memakai filter ikan",
            ["Select fish or rarity here to make auto fishing ignore them. If Auto Miss is enabled, matching fish will press the wrong QTE direction on purpose."]="Pilih ikan atau rarity di sini agar auto fishing mengabaikannya. Jika Auto Miss aktif, ikan yang cocok akan menekan arah QTE yang salah.",
            ["已忽略的过滤"]="Filter yang diabaikan",["No ignored fish filter. Auto fishing will handle every fish."]="Belum ada filter abaikan. Auto fishing akan menangani semua ikan.",
            ["要忽略的鱼"]="Ikan yang diabaikan",["稀有度"]="稀有度",["名称包含"]="Nama berisi",["匹配的鱼"]="Ikan cocok",
            ["匹配数量"]="Hitung cocok",["预览匹配列表"]="Lihat daftar",["清除所有过滤"]="Hapus filter",
            ["查看"]="Tampilan",["去雾"]="Tanpa kabut",["解锁远景"]="Buka jarak pandang",["Discord 状态"]="Status Discord",["外观娱乐"]="Kosmetik seru",["头像闪烁"]="Kilau avatar",
            ["复制 Discord 邀请链接"]="Salin undangan Discord",["打开菜单"]="Buka menu",
            ["Waiting for active fishing..."]="Menunggu sedang memancing...",
            ["Next interval sell in"]="Jual otomatis dalam",
            ["Interval reached - selling..."]="Waktu jual tiba - menjual...",
            ["Sold"]="Terjual",
            ["Walking to Fish Seller..."]="Berjalan ke penjual ikan...",
            ["Path blocked - walk failed to Fish Seller"]="Jalur terhalang - gagal berjalan ke penjual ikan",
        },
        Portuguese = {
            ["首页"]="Inicio",["Farm"]="Farm",["玩家"]="Jogador",["视觉"]="视觉",["商店 / 开箱"]="Loja / Caixa",["杂项"]="Extras",["设置"]="Configuracoes",
            ["状态"]="状态",["语言"]="Idioma",["应用语言"]="Aplicar idioma",["钓鱼"]="Pesca",["移动"]="Movimento",["传送岛屿"]="Teleportar ilha",
            ["岛屿"]="Ilha",["传送模式"]="Modo de teleporte",["传送"]="Teleportar",["行走速度"]="Velocidade",["行走速度警告"]="Aviso de velocidade",
            ["自动出售"]="Venda automatica",["自动锁定鱼"]="Travar peixe auto",["鱼类过滤"]="Filtro de peixe",
            ["优先级"]="Prioridade",["跳过过滤掉的鱼"]="Auto errar peixes filtrados",
            ["鱼类过滤使用说明"]="Como usar o filtro de peixe",
            ["Select fish or rarity here to make auto fishing ignore them. If Auto Miss is enabled, matching fish will press the wrong QTE direction on purpose."]="Selecione peixe ou raridade aqui para ignorar. Se Auto Miss estiver ativo, peixes filtrados apertarao a direcao QTE errada.",
            ["已忽略的过滤"]="Filtro ignorado",["No ignored fish filter. Auto fishing will handle every fish."]="Sem filtro ignorado. A pesca automatica cuidara de todos os peixes.",
            ["要忽略的鱼"]="Peixe a ignorar",["稀有度"]="Raridade",["名称包含"]="Nome contem",["匹配的鱼"]="Peixes encontrados",
            ["匹配数量"]="Contar encontrados",["预览匹配列表"]="Ver lista",["清除所有过滤"]="Limpar filtros",
            ["查看"]="Visao",["去雾"]="Sem neblina",["解锁远景"]="Liberar visao distante",["Discord 状态"]="Status do Discord",["外观娱乐"]="Cosmeticos",["头像闪烁"]="Brilhos do avatar",
            ["复制 Discord 邀请链接"]="Copiar convite Discord",["打开菜单"]="Abrir menu",
            ["Waiting for active fishing..."]="Aguardando pesca ativa...",
            ["Next interval sell in"]="Venda em",
            ["Interval reached - selling..."]="Intervalo pronto - vendendo...",
            ["Sold"]="Vendido",
            ["Walking to Fish Seller..."]="Indo ate o vendedor de peixes...",
            ["Path blocked - walk failed to Fish Seller"]="Caminho bloqueado - falha ao andar ate o vendedor",
        },
    }

    local UI_TRANSLATION_SKIP = {
        ["Z"]=true,["X"]=true,["C"]=true,["V"]=true,["R"]=true,["T"]=true,
        ["Dark"]=true,["Light"]=true,["Rose"]=true,["Plant"]=true,
        ["Aqua"]=true,["Amethyst"]=true,["Emerald"]=true,["Indigo"]=true,
        ["Orange"]=true,["Pink"]=true,["Purple"]=true,["Red"]=true,
        ["Sky"]=true,["Yellow"]=true,["Zinc"]=true,["Modern"]=true,["Rainbow"]=true,
        ["Coin"]=true,["Robux"]=true,["Gem"]=true,
        ["Tween"]=true,["Fast Travel"]=true,
        ["Ocean Chest"]=true,["Dragon Chest"]=true,
        ["Starter Island"]=true,["Jungle Island"]=true,["Desert Island"]=true,
            ["Snow Island"]=true,["Volcano Island"]=true,["Fossil Island"]=true,
        ["None"]=true,
    }

    local function ShouldSkipUITranslation(text)
        if type(text) ~= "string" or text == "" then return true end
        if UI_TRANSLATION_SKIP[text] then return true end
        if #text <= 2 and text:match("^[A-Za-z0-9]+$") then return true end
        if text:match("^[%d%.]+$") then return true end
        if text:find("rbxassetid://", 1, true) or text:find("https://", 1, true) or text:find("http://", 1, true) then return true end
        if text:find("|", 1, true) then return true end
        return false
    end

    local function TranslateText(text)
        if type(text) ~= "string" then return text end
        if ShouldSkipUITranslation(text) then return text end
        local lang = getgenv().NNVN_Language or "English"
        if lang == "English" then return text end
        local map = UI_TRANSLATIONS[lang]
        if map and map[text] then return map[text] end
        return text
    end

    local function ApplyUILanguage()
        local reverse = {}
        for _, map in pairs(UI_TRANSLATIONS) do
            for english, translated in pairs(map) do reverse[translated] = english end
        end
        local function isHubGui(gui)
            if not gui then return false end
            local name = string.lower(tostring(gui.Name or ""))
            if name:find("wind", 1, true) or name:find("nnvn", 1, true) or name:find("hub", 1, true) then return true end
            for _, d in ipairs(gui:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and type(d.Text) == "string" then
                    local t = d.Text
                    if t == "NNVN Hub" or t:find("NNVN Hub", 1, true) or t:find("Fishing Master", 1, true) then return true end
                end
            end
            return false
        end
        local function translateObjectText(obj)
            if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then return end
            local original = obj:GetAttribute("NNVN_EnglishText")
            if not original then
                original = reverse[obj.Text] or obj.Text
                obj:SetAttribute("NNVN_EnglishText", original)
            end
            if ShouldSkipUITranslation(original) then return end
            local translated = TranslateText(original)
            if obj.Text ~= translated then obj.Text = translated end
            if obj:IsA("TextBox") then
                local placeholder = obj:GetAttribute("NNVN_EnglishPlaceholder")
                if not placeholder then
                    placeholder = obj.PlaceholderText or ""
                    obj:SetAttribute("NNVN_EnglishPlaceholder", placeholder)
                end
                if not ShouldSkipUITranslation(placeholder) then
                    local tp = TranslateText(placeholder)
                    if obj.PlaceholderText ~= tp then obj.PlaceholderText = tp end
                end
            end
        end
        local roots = {}
        pcall(function() table.insert(roots, game:GetService("CoreGui")) end)
        if LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") then table.insert(roots, LocalPlayer.PlayerGui) end
        for _, guiRoot in ipairs(roots) do
            for _, rootGui in ipairs(guiRoot:GetChildren()) do
                if rootGui:IsA("ScreenGui") and isHubGui(rootGui) then
                    for _, obj in ipairs(rootGui:GetDescendants()) do pcall(translateObjectText, obj) end
                end
            end
        end
    end

    env.LANGUAGE_OPTIONS = LANGUAGE_OPTIONS
    env.TranslateText = TranslateText
    env.ApplyUILanguage = ApplyUILanguage
end

-- ============================================================
-- FUNCTION 9: setupWindow — Create WindUI window
-- ============================================================
local function setupWindow(env)
    local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/n0namevnnek-web/UltraObsidian/refs/heads/main/Library.lua"))()
    getgenv().NNVN_WindUI = WindUI
    env.WindUI = WindUI

    pcall(function()
        if type(WindUI.Scheme) == "table" then
            WindUI.Scheme.BackgroundColor = Color3.fromRGB(22, 22, 22)
            WindUI.Scheme.MainColor = Color3.fromRGB(30, 30, 30)
            WindUI.Scheme.AccentColor = Color3.fromRGB(245, 245, 245)
            WindUI.Scheme.OutlineColor = Color3.fromRGB(64, 64, 64)
            WindUI.Scheme.FontColor = Color3.fromRGB(255, 255, 255)
            WindUI.Scheme.BackgroundImage = ""
        end
        if type(WindUI.UpdateColors) == "function" then WindUI:UpdateColors() end
    end)

    local tooltipText = {
        ["岛屿"] = "Choose the island used by teleport/tween actions.",
        ["传送模式"] = "Choose Boat, Tween, or Fast Travel before pressing Teleport.",
        ["传送"] = "Boat mode walks to Boat Merchant, summons a boat, sits in the driver seat, then drives to the selected island.",
        ["移动安全提示"] = "Do not set Tween Speed or WalkSpeed too high, otherwise the server may kick you.",
        ["出售/抽卡前平滑移动"] = "Moves to the needed NPC or station before shop, sell, or gacha actions.",
        ["绕过反作弊（传送）"] = "Applies movement safety changes while tweening.",
        ["平滑移动速度"] = "Shared tween speed for tween-based actions. Do not set it too high.",
        ["平滑移动速度数值"] = "Type an exact tween speed number. Do not set it too high.",
        ["行走速度警告"] = "Do not set WalkSpeed too high, otherwise the server may kick you.",
        ["行走速度"] = "Shared walking speed used by manual movement and path-based features.",
        ["行走速度数值"] = "Type an exact shared walking speed number.",
        ["Boat Travel Note"] = "Explains how Boat teleport works.",
        ["载具移动提示"] = "Boat mode now uses the current island vehicle merchant and the selected truck.",
        ["载具"] = "Choose which vehicle to summon from the merchant. Truck is free; Red Truck costs 50000.",
        ["船速度"] = "Changes the current boat speed when a boat seat is found.",
        ["船速度数值"] = "Type an exact boat speed number.",
        ["设置船速度"] = "Keeps applying the configured boat speed while enabled.",
        ["应用船速度（一次）"] = "Applies the configured boat speed to the current boat once.",
        ["去雾"] = "Removes fog locally and keeps far areas clearer.",
        ["解锁远景"] = "Expands local view distance so far islands are less hidden.",
        ["头像闪烁"] = "Adds a small local-only sparkle effect around your character. It does not call remotes or change gameplay.",
        ["图片主题说明"] = "Use Roblox Creator Store decals to find a background image asset id.",
        ["复制 Roblox 创作者贴图链接"] = "Copies the Roblox Creator Store decals link so you can search for an image asset.",
        ["图片主题"] = "Paste only the Roblox decal asset id number. The script adds rbxassetid:// automatically.",
        ["复制 Discord 邀请链接"] = "Copies the NNVN Hub Discord invite link.",
        ["自动抛竿"] = "Automatically casts the rod when the fishing state is idle.",
        ["自动小游戏（QTE方向键 + 收线）"] = "Automatically handles pull, QTE, and reel actions during fishing.",
        ["自动点击钓鱼（首次拉杆/收线）"] = "Clicks during FirstPull and Reeling to help catch fish.",
        ["自动装备鱼竿"] = "Equips a fishing rod automatically when none is held.",
        ["自动技能 Z/X/C/V"] = "Uses configured rod skills while fighting a fish.",
        ["自动使用技能（达到斩杀线）"] = "Uses skills when the fish reaches the execute threshold.",
        ["完美抛竿（始终满幸运值）"] = "Forces cast packets toward perfect/max-luck casting when supported.",
        ["自动关闭捕获弹窗"] = "Automatically closes catch popup screens after catching fish.",
        ["冻结玩家"] = "Freezes your character in place until turned off.",
        ["安全挂机（隐身）"] = "Moves your character under the map and keeps the camera above for safer farming. Auto enables noclip.",
        ["使用技能（一次）"] = "Runs the current skill order one time.",
        ["立即强制抛竿"] = "Casts the rod immediately once.",
        ["调试状态"] = "Prints the current fishing controller state to the console.",
        ["自动刷 Boss（传送 + 全套钓鱼）"] = "Waits for an active boss region, tweens there, and enables farming helpers.",
        ["立即前往活跃 Boss"] = "Tweens to the currently active boss region once.",
        ["停止挂机 + 移除平台"] = "Stops boss farming and removes the helper platform.",
        ["扫描活跃 Boss"] = "Scans BossRegion data and shows active boss regions.",
        ["要锁定的鱼"] = "Choose a specific fish to lock directly from inventory.",
        ["要锁定的稀有度"] = "Choose a rarity to lock directly from inventory.",
        ["要忽略的鱼"] = "Choose a fish that auto fishing should ignore. Matching fish will not be clicked, pulled, or skilled.",
        ["鱼类过滤使用说明"] = "Fish Filter is an ignore list for auto fishing, not a target-only list.",
        ["跳过过滤掉的鱼"] = "When the current fish matches the ignore filter, press the wrong QTE direction on purpose.",
        ["优先级"] = "Adjust which automation group should pause or run first.",
        ["Auto Sell Priority"] = "Auto Sell uses this priority and pauses fishing actions while walking, selling, and returning.",
        ["自动任务（完整链）"] = "Runs the full quest chain: pick a visible quest, accept it, prepare filters/farming, complete it, then move to the next quest.",
        ["条件不足时自动钓鱼升级"] = "Turns farming helpers on when the selected quest still needs fish, coin, or related progress.",
        ["自动购买所需鱼竿"] = "Attempts to buy the required rod when a quest requirement needs it and you have enough coin.",
        ["按任务自动设置鱼类过滤"] = "Automatically changes Fish Filter settings to match the current quest target.",
        ["背包满时出售（金币任务用）"] = "Temporarily enables Auto Sell When Full when the current quest needs coin farming.",
        ["详细日志 (F9)"] = "Prints detailed Auto Quest progress to the F9 console.",
        ["步进延迟 (秒)"] = "Delay between Auto Quest decision steps.",
        ["跳过当前任务"] = "Blacklists the current quest for this Auto Quest session and moves to the next available quest.",
        ["Run One Step Now"] = "Runs one Auto Quest decision step immediately without waiting for the timer.",
        ["Apply Quest Filter Now"] = "Applies the Fish Filter for the current Auto Quest target once.",
        ["Clear Quest Filter"] = "Clears Fish Filter changes made by Auto Quest.",
        ["鱼类监控"] = "Shows current hooked fish info and whether it matches the active filter.",
        ["抛竿位置"] = "Save and reuse island-specific cast positions for Auto Quest farming.",
        ["稀有度"] = "Choose rarities that auto fishing should ignore.",
        ["自动锁定选中的鱼"] = "Automatically locks matching fish by UID without holding them when supported.",
        ["锁定选中鱼（一次）"] = "Locks one matching fish by UID immediately.",
        ["名称包含"] = "Ignores fish whose name contains this text.",
        ["锁定状态"] = "Filters fish by current lock state.",
        ["主题"] = "Select the UI theme.",
        ["语言"] = "Select UI language, then press Apply Language.",
    }

    env.prepareControlInfo = function(info)
        if type(info) ~= "table" then return info end
        local title = tostring(info.Title or info.Name or info.Text or "")
        info.Text = info.Text or info.Title or info.Name
        info.Name = info.Name or info.Title or info.Text
        if info.Tooltip == nil then
            info.Tooltip = info.Description or info.Desc or info.Content or tooltipText[title]
        end
        if info.Tooltip == nil and title ~= "" then
            info.Tooltip = "Configure " .. title .. "."
        end
        if info.Description == nil and type(info.Tooltip) == "string" then
            info.Description = info.Tooltip
        end
        return info
    end

    env.patchControlContainer = function(c)
        if not c then return c end
        local prepare = env.prepareControlInfo or function(o) return o end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) o = prepare(o or {}); return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) o = prepare(o or {}); return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown and not c.Dropdown then function c:Dropdown(o)
            o = prepare(o or {})
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddSlider and not c.Slider then function c:Slider(o) o = prepare(o or {}); return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.AddInput and not c.Input then function c:Input(o) o = prepare(o or {}); return self:AddInput(o.Title or o.Name or "Input", o) end end
        if c.Button and not c.__NNVNButtonPatched then local raw = c.Button; c.__NNVNButtonPatched = true; function c:Button(o) return raw(self, prepare(o or {})) end end
        if c.Toggle and not c.__NNVNTogglePatched then local raw = c.Toggle; c.__NNVNTogglePatched = true; function c:Toggle(o) return raw(self, prepare(o or {})) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local raw = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = prepare(o or {})
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return raw(self, o)
            end
        end
        if c.Slider and not c.__NNVNSliderPatched then local raw = c.Slider; c.__NNVNSliderPatched = true; function c:Slider(o) return raw(self, prepare(o or {})) end end
        if c.Input and not c.__NNVNInputPatched then local raw = c.Input; c.__NNVNInputPatched = true; function c:Input(o) return raw(self, prepare(o or {})) end end
        return c
    end

    local Window = WindUI:CreateWindow({
        Title = "NNVN Hub",
        Icon = "rbxassetid://138952058031836", Author = "Fishing Master v1.4.8", Folder = "NNVN_FishingMaster",
        Footer = {
            { Text = "https://discord.gg/5JJAuHRUgJ", Copyable = true },
            { Text = " | Fishing Master v1.4.8 | Island: Unknown", Copyable = false },
        },
        CopyableFooter = false,
        Size = UDim2.fromOffset(760,520), MinSize = Vector2.new(560,340), MaxSize = Vector2.new(940,640),
        Transparent = true, Theme = "Dark", Background = "", BackgroundImageTransparency = 0.4,
        Resizable = true, SideBarWidth = 220, SidebarWidth = 220, MinSidebarWidth = 220,
        EnableSidebarResize = true,
        SidebarCompactWidth = 48, CompactWidthActivation = 128,
        SidebarCompacted = true, EnableCompacting = true, DisableCompactingSnap = false,
        HideSearchBar = false, ScrollBarEnabled = true,
        User = { Enabled=true, Anonymous=true },
    })
    env.Window = Window
    pcall(function() WindUI:SetTheme("Dark") end)
    pcall(function() if Window.SetCompact then Window:SetCompact(true) end end)

    env.getFooterIsland = function()
        local island = "Unknown"
        pcall(function()
            local root = env.getRoot and env.getRoot()
            if root and env.getIslandForPosition then
                island = env.getIslandForPosition(root.Position)
            end
        end)
        return island
    end

    task.spawn(function()
        while task.wait(1) do
            if Window and Window.SetFooter then
                local island = env.getFooterIsland and env.getFooterIsland() or "Unknown"
                pcall(function()
                    Window:SetFooter({
                        { Text = "https://discord.gg/5JJAuHRUgJ", Copyable = true },
                        { Text = " | Fishing Master v1.4.8 | Island: " .. tostring(island), Copyable = false },
                    })
                end)
            end
        end
    end)

    pcall(function()
        Window:EditOpenButton({
            Title = "打开菜单", Icon = "rbxassetid://138952058031836",
            CornerRadius = UDim.new(0,10), StrokeThickness = 1.5,
            Color = ColorSequence.new(Color3.fromHex("111111"), Color3.fromHex("F5F5F5")),
            OnlyMobile = false, Enabled = true, Draggable = true,
        })
    end)

    pcall(function()
        local premium = env.refreshPremiumAccess()
        Window:Tag({
            Title = premium and "PREMIUM" or "FREE",
            Icon = premium and "crown" or "shield-check",
            Color = premium and Color3.fromHex("#EAB308") or Color3.fromHex("#000000"),
            Radius = 5,
        })
    end)
end

-- ============================================================
-- FUNCTION 10: buildFarmTab
-- ============================================================
local function buildFarmTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local setStatus = env.setStatus
    local notify = env.notify
    local enablePerfectCast = env.enablePerfectCast
    local bindAutoDismissPopup = env.bindAutoDismissPopup
    local getFishingController = env.getFishingController
    local getFishState = env.getFishState
    local getFishInfo = env.getFishInfo
    local castRod = env.castRod
    local useSkillsOnce = env.useSkillsOnce
    local PerfectCast = env.PerfectCast
    local setSafeFarmInvisible = env.setSafeFarmInvisible

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        local prepare = env.prepareControlInfo or function(o) return o end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) o = prepare(o or {}); return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) o = prepare(o or {}); return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown and not c.Dropdown then function c:Dropdown(o)
            o = prepare(o or {})
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddSlider and not c.Slider then function c:Slider(o) o = prepare(o or {}); return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.AddInput and not c.Input then function c:Input(o) o = prepare(o or {}); return self:AddInput(o.Title or o.Name or "Input", o) end end
        if c.Button and not c.__NNVNButtonPatched then local raw = c.Button; c.__NNVNButtonPatched = true; function c:Button(o) return raw(self, prepare(o or {})) end end
        if c.Toggle and not c.__NNVNTogglePatched then local raw = c.Toggle; c.__NNVNTogglePatched = true; function c:Toggle(o) return raw(self, prepare(o or {})) end end
        if c.Slider and not c.__NNVNSliderPatched then local raw = c.Slider; c.__NNVNSliderPatched = true; function c:Slider(o) return raw(self, prepare(o or {})) end end
        if c.Input and not c.__NNVNInputPatched then local raw = c.Input; c.__NNVNInputPatched = true; function c:Input(o) return raw(self, prepare(o or {})) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local rawDropdown = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = prepare(o or {})
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return rawDropdown(self, o)
            end
        end
        return c
    end

    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local FarmTab = Window:Tab({ Title = "主界面", Icon = "fish" })
    local FarmSec = section(FarmTab, { Title = "钓鱼", Icon = "sailboat" })
    Paragraphs.farm = FarmSec:Paragraph({ Title = "状态", Desc = "空闲" })

    FarmSec:Toggle({ Title="自动小游戏（QTE方向键 + 收线）", Icon="circle-dot", Default=false,
        Callback=function(v) S.AutoPullMinigame=v; setStatus("farm", v and "Auto pull enabled" or "空闲") end })
    FarmSec:Toggle({ Title="自动抛竿", Icon="send", Default=false,
        Callback=function(v) S.AutoCast=v; setStatus("farm", v and "Auto cast enabled" or "空闲") end })
    FarmSec:Toggle({ Title="自动点击钓鱼（首次拉杆/收线）", Icon="mouse-pointer-click", Default=false,
        Callback=function(v) S.AutoClickFish=v; setStatus("farm", v and "Auto click enabled" or "空闲") end })
    FarmSec:Toggle({ Title="自动装备鱼竿", Icon="hand", Default=false,
        Callback=function(v) S.AutoEquipRod=v; setStatus("farm", v and "Auto equip enabled" or "空闲") end })
    FarmSec:Toggle({ Title="自动技能 Z/X/C/V", Icon="zap", Default=false,
        Callback=function(v) S.AutoUseSkills=v; setStatus("farm", v and "Auto skills enabled" or "空闲") end })
    FarmSec:Toggle({ Title="自动使用技能（达到斩杀线）", Icon="crosshair", Default=false,
        Callback=function(v) S.AutoUseSkillsAtExecute=v; setStatus("farm", v and "Execute-line armed" or "空闲") end })
    FarmSec:Toggle({ Title="完美抛竿（始终满幸运值）", Icon="sparkles", Default=false,
        Callback=function(v) S.AutoPerfectCast=v; enablePerfectCast(v) end })
    FarmSec:Toggle({ Title="自动关闭捕获弹窗", Icon="mouse-pointer-click", Default=true,
        Callback=function(v)
            S.AutoDismissPopup = v
            setStatus("farm", v and "Auto dismiss popup: ON" or "Auto dismiss popup: OFF")
            if v then bindAutoDismissPopup() end
        end })
    FarmSec:Toggle({ Title="冻结玩家", Icon="snowflake", Default=false,
        Callback=function(v)
            S.FreezePlayer = v
            local hum = env.getHumanoid and env.getHumanoid()
            local root = env.getRoot and env.getRoot()
            if not v then
                if hum then
                    pcall(function()
                        hum.PlatformStand = false
                        hum.WalkSpeed = S.WalkSpeed or 16
                        hum.JumpPower = S.JumpPower or 50
                    end)
                end
                if root then
                    pcall(function()
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
            end
            setStatus("farm", v and "Freeze Player: ON" or "Freeze Player: OFF")
        end })
    FarmSec:Toggle({
        Title = "安全挂机（隐身）",
        Icon = "eye-off",
        Default = false,
        Description = "Force under map + camera spectate. Auto enables NoClip for safer farming.",
        Callback = function(v)
            if setSafeFarmInvisible then setSafeFarmInvisible(v) end
            setStatus("farm", v and "Safe Farm Invisible: ON" or "Safe Farm Invisible: OFF")
        end,
    })
    FarmSec:Button({ Title="使用技能（一次）", Icon="play", Callback=useSkillsOnce })
    FarmSec:Button({ Title="立即强制抛竿", Icon="send",
        Callback=function()
            if not getFishingController() then notify("Cast","钓鱼系统未就绪"); return end
            castRod()
        end })
    FarmSec:Button({ Title="调试状态", Icon="bug",
        Callback=function()
            local ctrl = getFishingController()
            if not ctrl then notify("调试","钓鱼系统未就绪"); return end
            local state = getFishState()
            local _, hp, maxHp = getFishInfo()
            local msg = ("State=%s | HP=%s/%s"):format(tostring(state),tostring(hp),tostring(maxHp))
            if S.AutoPerfectCast then msg = msg.." | PerfectCast: "..tostring(PerfectCast.Count) end
            notify("调试", msg)
        end })

    local FarmSettingsSec = section(FarmTab, { Title = "挂机设置", Icon = "sliders-horizontal" })
    FarmSettingsSec:Input({ Title="技能顺序", Icon="list-ordered", Value=S.SkillOrder,
        Callback=function(v) S.SkillOrder=tostring(v or "Z,X,C,V") end })
    FarmSettingsSec:Dropdown({ Title="自动倍率 X", Icon="badge-x",
        Values={"1","3","5","10"}, Default="10",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.AutoXMultiplier=tonumber(v) or 10 end })
    FarmSettingsSec:Slider({ Title="自动抛竿延迟 (秒)", Icon="timer",
        Value={Min=0.12,Max=2.5,Default=S.AutoCastDelay or 0.35},
        Callback=function(v) S.AutoCastDelay=math.clamp(tonumber(v) or 0.35, 0.12, 2.5) end })
    FarmSettingsSec:Slider({ Title="抛竿最短蓄力 (秒)", Icon="timer",
        Value={Min=0.2,Max=5,Default=S.CastHoldMin},
        Callback=function(v) S.CastHoldMin=tonumber(v) or 0.35 end })
    FarmSettingsSec:Slider({ Title="抛竿最长蓄力 (秒)", Icon="timer-reset",
        Value={Min=0.2,Max=8,Default=S.CastHoldMax},
        Callback=function(v) S.CastHoldMax=tonumber(v) or 0.65 end })
    FarmSettingsSec:Slider({ Title="自动点击延迟 (毫秒)", Icon="timer",
        Value={Min=10,Max=1000,Default=120},
        Callback=function(v) S.ClickDelay=math.max(0.04,(tonumber(v) or 120)/1000) end })
    FarmSettingsSec:Slider({ Title="自动拉杆延迟 (毫秒)", Icon="timer-reset",
        Value={Min=10,Max=1000,Default=80},
        Callback=function(v) S.PullDelay=math.max(0.04,(tonumber(v) or 80)/1000) end })
    FarmSettingsSec:Slider({ Title="技能释放血量 (%)", Icon="crosshair",
        Value={Min=2,Max=95,Default=math.floor(S.ExecutePercent*100)},
        Callback=function(v) S.ExecutePercent=math.clamp((tonumber(v) or 25)/100, 0.02, 0.95) end })

    -- ═══════════════════════════════════════════════════════════
    -- BOSS (merged: Farm + Alert + ESP + History)
    -- ═══════════════════════════════════════════════════════════
    local BossSec = section(FarmTab, { Title = "Boss 挂机 [不可用]", Icon = "swords" })
    Paragraphs.bossfarm = BossSec:Paragraph({ Title = "挂机状态", Desc = "空闲" })
    Paragraphs.bossalert = BossSec:Paragraph({ Title = "提醒", Desc = "Monitoring..." })
    Paragraphs.bossfight = BossSec:Paragraph({ Title = "战斗", Desc = "Waiting..." })
    Paragraphs.bosshistory = BossSec:Paragraph({ Title = "历史", Desc = "捕获 Boss: 0" })

    local function findFirstActiveRegion()
        local spawners = env.scanBossSpawnersExtended and env.scanBossSpawnersExtended() or {}
        for _, info in ipairs(spawners) do
            if info.active then return info end
        end
        return nil
    end

    local function tweenToRegion(info)
        if not info or not info.position then
            setStatus("bossfarm", "Region không có vị trí")
            return false
        end
        local root = env.getRoot and env.getRoot()
        if root then S.LastInteractionReturnCF = root.CFrame end
        local targetCF = CFrame.new(info.position + Vector3.new(0, (S.TweenHeight or 5) + 2, 0))
        env.tweenTo(targetCF, S.TweenSpeed)
        return true
    end

        BossSec:Toggle({
        Title = "自动刷 Boss（传送 + 全套钓鱼）",
        Icon = "repeat", Default = false,
        Callback = function(v)
            S.AutoFarmBoss = v
            if v then
                -- Bật hết farming phụ trợ
                S.AutoCast = true
                S.AutoClickFish = true
                S.AutoPullMinigame = true
                S.AutoUseSkills = true
                if not S.AutoPerfectCast then
                    S.AutoPerfectCast = true
                    if env.enablePerfectCast then env.enablePerfectCast(true) end
                end

                -- Thử tween ngay nếu boss đã active
                local active = findFirstActiveRegion()
                if active then
                    tweenToRegion(active)
                    setStatus("bossfarm", ("🎯 Farming: [%s] %s"):format(active.islandDisplay, active.regionName))
                else
                    -- ⭐ KHÔNG tắt — chờ boss spawn
                    setStatus("bossfarm", "⏳ Đang chờ boss spawn...")
                    notify("Boss Farm", "Đang chờ boss spawn (tự tween khi boss xuất hiện)")
                end
                -- Loop chờ boss spawn tự động tween
                task.spawn(function()
                    while S.AutoFarmBoss do
                        task.wait(2)
                        local a = findFirstActiveRegion()
                        if a then
                            local root = env.getRoot and env.getRoot()
                            if root then
                                local dist = (root.Position - a.position).Magnitude
                                if dist > 60 then
                                    tweenToRegion(a)
                                    setStatus("bossfarm", ("🎯 Farming: [%s] %s"):format(a.islandDisplay, a.regionName))
                                end
                            end
                        else
                            setStatus("bossfarm", "⏳ Chờ boss spawn...")
                        end
                    end
                end)
            else
                if env.removeBossFarmPlatform then env.removeBossFarmPlatform() end
                setStatus("bossfarm", "自动挂机关闭")
            end
        end,
    })
    BossSec:Button({
        Title = "立即前往活跃 Boss", Icon = "send",
        Callback = function()
            local active = findFirstActiveRegion()
            if not active then
                setStatus("bossfarm", "❌ Không có boss active")
                return
            end
            if tweenToRegion(active) then
                setStatus("bossfarm", ("→ [%s] %s"):format(active.islandDisplay, active.regionName))
            end
        end,
    })
    BossSec:Button({
        Title = "停止挂机 + 移除平台", Icon = "square",
        Callback = function()
            S.AutoFarmBoss = false
            if env.removeBossFarmPlatform then env.removeBossFarmPlatform() end
            setStatus("bossfarm", "Stopped")
        end,
    })
    BossSec:Button({
        Title = "扫描活跃 Boss", Icon = "search",
        Callback = function()
            local spawners = env.scanBossSpawnersExtended and env.scanBossSpawnersExtended() or {}
            local activeCount, names = 0, {}
            for _, info in ipairs(spawners) do
                if info.active then
                    activeCount += 1
                    names[#names + 1] = ("[%s] %s"):format(info.islandDisplay, info.regionName)
                end
            end
            if activeCount > 0 then
                setStatus("bossfarm", "ONLINE: " .. table.concat(names, " | "))
                notify("Boss Scan", ("%d online"):format(activeCount))
            else
                setStatus("bossfarm", "No active bosses")
                notify("Boss Scan", "0 online")
            end
        end,
    })
        BossSec:Button({
        Title = "强制传送到 Boss（调试）",
        Icon = "bug",
        Callback = function()
            local spawners = env.scanBossSpawnersExtended and env.scanBossSpawnersExtended() or {}
            local lines = { "=== Boss Scan ===" }
            local activeCount = 0
            for _, info in ipairs(spawners) do
                local status = info.active and "ACTIVE" or (info.exists and "region-only" or "missing")
                lines[#lines+1] = ("[%s] %s | %s | %s"):format(
                    info.islandDisplay, info.regionName, info.regionId, status)
                if info.active then activeCount += 1 end
            end
            lines[#lines+1] = ("Total active: %d"):format(activeCount)
            print(table.concat(lines, "\n"))
            notify("Boss Scan", ("%d active - see F9"):format(activeCount))

            local a = findFirstActiveRegion()
            if a then
                tweenToRegion(a)
                setStatus("bossfarm", ("→ [%s] %s"):format(a.islandDisplay, a.regionName))
            else
                setStatus("bossfarm", "❌ Không tìm thấy boss — xem F9 để biết chi tiết")
            end
        end,
    })
    BossSec:Toggle({ Title = "Boss 出现提醒", Icon = "bell", Default = true,
        Callback = function(v) S.BossSpawnAlert = v end })
    BossSec:Toggle({ Title = "Boss 消失提醒", Icon = "bell-off", Default = true,
        Callback = function(v) S.BossDespawnAlert = v end })
    BossSec:Toggle({ Title = "Boss 出现自动传送", Icon = "send", Default = false,
        Callback = function(v) S.AutoTweenOnBossSpawn = v end })
    BossSec:Toggle({ Title = "Boss 阶段自动技能", Icon = "zap", Default = false,
        Callback = function(v) S.AutoSkillOnBossPhase = v end })
    BossSec:Toggle({ Title = "Boss 咆哮自动闪避", Icon = "move", Default = false,
        Callback = function(v) S.AutoDodgeBossRoar = v end })
    BossSec:Toggle({ Title = "Boss 区域 ESP", Icon = "eye", Default = false,
        Callback = function(v)
            S.BossRegionESP = v
            if env.updateBossRegionESP then pcall(env.updateBossRegionESP) end
            if not v and env.clearBossRegionESP then pcall(env.clearBossRegionESP) end
        end })
    BossSec:Toggle({ Title = "Boss Discord 通知", Icon = "webhook", Default = false,
        Callback = function(v) S.BossWebhookEnabled = v end })
    BossSec:Input({ Title = "Boss Webhook 地址", Icon = "link", Value = "",
        Placeholder = "https://discord.com/api/webhooks/...",
        Callback = function(v) S.BossWebhookUrl = tostring(v or "") end })
    BossSec:Button({ Title = "导出 Boss 历史 (F9)", Icon = "trophy",
        Callback = function() if env.dumpBossHistory then env.dumpBossHistory() end end })
    BossSec:Button({ Title = "导出 Boss 池 (F9)", Icon = "list",
        Callback = function() if env.dumpBossPools then env.dumpBossPools() end end })
    BossSec:Button({ Title = "清除 Boss 历史", Icon = "trash-2",
        Callback = function()
            S.BossHistory = {}
            S.BossCaughtCount = 0
            setStatus("bosshistory", "捕获 Boss: 0")
        end })

    -- Unlock Island (moved into Farm)
    local UnlockSec = section(FarmTab, { Title = "解锁岛屿", Icon = "key" })
    Paragraphs.teleport = UnlockSec:Paragraph({ Title = "状态", Desc = "空闲" })
    UnlockSec:Dropdown({
        Title = "要解锁的岛屿", Icon = "map",
        Values = {"Jungle Island","Desert Island","Snow Island","Volcano Island","Fossil Island"},
        Default = S.SelectedUnlockIsland,
        Callback = function(v)
            if type(v) == "table" then v = v.Value or v[1] end
            S.SelectedUnlockIsland = tostring(v or S.SelectedUnlockIsland)
        end,
    })
    UnlockSec:Toggle({
        Title = "自动解锁选中岛屿", Icon = "repeat", Default = false,
        Callback = function(v) S.AutoUnlockIsland = v end,
    })
    UnlockSec:Button({
        Title = "解锁（一次）", Icon = "check",
        Callback = function()
            if env.unlockIslandOnce then env.unlockIslandOnce(S.SelectedUnlockIsland) end
        end,
    })
end

-- ============================================================
-- FUNCTION 11: buildPlayerTab
-- ============================================================
local function buildPlayerTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local setStatus = env.setStatus
    local notify = env.notify
    local copyText = env.copyText
    local getJobIdText = env.getJobIdText
    local rejoinCurrentJob = env.rejoinCurrentJob
    local joinJobId = env.joinJobId
    local findIslandCF = env.findIslandCF
    local fastTravelToIsland = env.fastTravelToIsland
    local boatTravelToIsland = env.boatTravelToIsland
    local getIslandDropdownValues = env.getIslandDropdownValues
    local tweenTo = env.tweenTo
    local setFly = env.setFly
    local applyBoatSpeed = env.applyBoatSpeed
    local sellHeld = env.sellHeld
    local sellAll = env.sellAll
    local lockHeldFish = env.lockHeldFish
    local getSellController = env.getSellController
    local buyRodOnce = env.buyRodOnce
    local getRodOptions = env.getRodOptions
    local getRoot = env.getRoot
    local getRarityOptions = env.getRarityOptions
    local getFishOptions = env.getFishOptions
    local normalizeRaritySelection = env.normalizeRaritySelection

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown and not c.Dropdown then function c:Dropdown(o)
            o = o or {}
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddSlider and not c.Slider then function c:Slider(o) return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.AddInput and not c.Input then function c:Input(o) return self:AddInput(o.Title or o.Name or "Input", o) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local rawDropdown = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = o or {}
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return rawDropdown(self, o)
            end
        end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local PlayerTab = Window:Tab({ Title = "玩家", Icon = "user" })

    local TeleportSec = section(PlayerTab, { Title = "传送岛屿", Icon = "map-pin" })
    TeleportSec:Paragraph({
        Title = "传送警告",
        Desc = "Teleport should not be used because it may kick you. We will not respond to reports about this issue.",
    })
    TeleportSec:Paragraph({
        Title = "移动安全提示",
        Desc = "Do not set Tween Speed or WalkSpeed too high, otherwise the server may kick you.",
    })
    TeleportSec:Dropdown({ Title="岛屿", Icon="map",
        Values=(getIslandDropdownValues and getIslandDropdownValues()) or {"Starter Island","Jungle Island","Desert Island","Snow Island","Volcano Island","Fossil Island"},
        Default=S.SelectedIsland,
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SelectedIsland=tostring(v or S.SelectedIsland) end })
    local VehicleTeleportDropdown
    local function updateVehicleTeleportDropdown()
        local show = (S.TeleportMode or "Fast Travel") == "船只"
        local c = VehicleTeleportDropdown
        if not c then return end
        pcall(function() if c.SetVisible then c:SetVisible(show) end end)
        pcall(function() if c.Visible ~= nil then c.Visible = show end end)
        pcall(function() if c.SetHidden then c:SetHidden(not show) end end)
        pcall(function() if c.Hide and not show then c:Hide() end end)
        pcall(function() if c.Show and show then c:Show() end end)
    end
    TeleportSec:Dropdown({ Title="传送模式", Icon="route",
        Values={"船只","Tween","Fast Travel"},
        Default=S.TeleportMode or "Fast Travel",
        Callback=function(v)
            if type(v)=="table" then v=v.Value or v[1] end
            S.TeleportMode=tostring(v or "Fast Travel")
            updateVehicleTeleportDropdown()
        end })
    VehicleTeleportDropdown = TeleportSec:Dropdown({ Title="载具", Icon="truck",
        Values={"Truck - Free","Red Truck - 50000"},
        Default=S.SelectedVehicle or "Truck - Free",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SelectedVehicle=tostring(v or "Truck - Free") end })
    task.defer(updateVehicleTeleportDropdown)
    TeleportSec:Slider({ Title="平滑移动速度", Icon="gauge",
        Value={Min=10,Max=900,Default=S.TweenSpeed or 20},
        Callback=function(v) S.TweenSpeed=tonumber(v) or 20 end })
    TeleportSec:Input({ Title="平滑移动速度数值", Icon="hash", Value=tostring(S.TweenSpeed or 20),
        Placeholder="20",
        Callback=function(v)
            local n = tonumber(v)
            if n then S.TweenSpeed = math.clamp(n, 10, 900) end
        end })
    TeleportSec:Toggle({ Title="出售/抽卡前平滑移动", Icon="route", Default=true,
        Callback=function(v) S.TweenBeforeActions=v end })
    TeleportSec:Toggle({ Title="绕过反作弊（传送）", Icon="shield", Default=true,
        Callback=function(v) S.BypassAntiCheat=v end })
    TeleportSec:Button({ Title="停止移动 / 恢复", Icon="square",
        Callback=function()
            if env.stopTween then env.stopTween() end
            setStatus("job", "Tween stopped · character restored")
        end })
    TeleportSec:Button({ Title="传送", Icon="send",
        Callback=function()
            if S.TeleportMode == "船只" then
                if boatTravelToIsland then boatTravelToIsland(S.SelectedIsland) end
                return
            end
            if S.TeleportMode == "Fast Travel" then
                if fastTravelToIsland then fastTravelToIsland(S.SelectedIsland) end
                return
            end
            local cf=findIslandCF(S.SelectedIsland); if cf then tweenTo(cf,S.TweenSpeed) end
        end })
    Paragraphs.job = TeleportSec:Paragraph({ Title="服务器 ID", Desc=getJobIdText() })
    TeleportSec:Input({ Title="加入服务器 ID", Icon="server", Value="",
        Callback=function(v) S.JoinJobId=tostring(v or "") end })
    TeleportSec:Button({ Title="复制服务器 ID", Icon="copy",
        Callback=function()
            local job = getJobIdText()
            setStatus("job", copyText(job) and ("Copied: "..job) or ("JobId: "..job))
        end })
    TeleportSec:Button({ Title="重新加入当前服务器", Icon="refresh-cw", Callback=rejoinCurrentJob })
    TeleportSec:Button({ Title="加入服务器 ID", Icon="log-in", Callback=function() joinJobId(S.JoinJobId) end })

    local PlayerSec = section(PlayerTab, { Title = "移动", Icon = "person-standing" })
    PlayerSec:Paragraph({
        Title = "行走速度警告",
        Desc = "Do not set WalkSpeed too high, otherwise the server may kick you.",
    })
    PlayerSec:Toggle({ Title="飞行", Icon="plane", Default=false, Callback=setFly })
    PlayerSec:Slider({ Title="飞行速度", Icon="gauge", Value={Min=10,Max=250,Default=S.FlySpeed},
        Callback=function(v) S.FlySpeed=tonumber(v) or 60 end })
    PlayerSec:Slider({ Title="行走速度", Icon="footprints", Value={Min=16,Max=80,Default=S.WalkSpeed},
        Callback=function(v) S.WalkSpeed=math.clamp(tonumber(v) or 24, 16, 80) end })
    PlayerSec:Input({ Title="行走速度数值", Icon="hash", Value=tostring(S.WalkSpeed or 24),
        Placeholder="24",
        Callback=function(v)
            local n = tonumber(v)
            if n then S.WalkSpeed = math.clamp(n, 16, 80) end
        end })
    PlayerSec:Slider({ Title="跳跃力", Icon="arrow-up", Value={Min=50,Max=250,Default=S.JumpPower},
        Callback=function(v) S.JumpPower=tonumber(v) or 50 end })
    PlayerSec:Toggle({ Title="穿墙", Icon="ghost", Default=false, Callback=function(v) S.Noclip=v end })
    PlayerSec:Toggle({ Title="冻结玩家", Icon="snowflake", Default=false,
        Callback=function(v)
            S.FreezePlayer = v
            local hum = env.getHumanoid and env.getHumanoid()
            local root = getRoot and getRoot()
            if not v then
                if hum then
                    pcall(function()
                        hum.PlatformStand = false
                        hum.WalkSpeed = S.WalkSpeed or 16
                        hum.JumpPower = S.JumpPower or 50
                    end)
                end
                if root then
                    pcall(function()
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
            end
        end })
    PlayerSec:Toggle({ Title="绕过反作弊（传送）", Icon="shield", Default=true,
        Callback=function(v) S.BypassAntiCheat = v end })
    PlayerSec:Toggle({ Title="无限跳跃", Icon="chevrons-up", Default=false, Callback=function(v) S.InfiniteJump=v end })
    PlayerSec:Toggle({ Title="水上行走", Icon="waves", Default=false, Callback=function(v) S.WalkOnWater=v end })
    PlayerSec:Toggle({ Title="防挂机", Icon="shield", Default=true, Callback=function(v) S.AntiAFK=v end })

    local ViewSec = section(PlayerTab, { Title = "查看", Icon = "eye" })
    ViewSec:Toggle({ Title="全亮", Icon="sun", Default=false, Callback=function(v) S.FullBright=v end })
    ViewSec:Toggle({ Title="去雾", Icon="cloud-off", Default=false,
        Callback=function(v) S.NoFog=v; setStatus("job", v and "No Fog: ON" or "No Fog: OFF") end })
    ViewSec:Toggle({ Title="解锁远景", Icon="scan-eye", Default=false,
        Callback=function(v) S.UnlockFarView=v; setStatus("job", v and "Unlock Far View: ON" or "Unlock Far View: OFF") end })

    local BoatSec = section(PlayerTab, { Title = "船只", Icon = "ship" })
    Paragraphs.boat = BoatSec:Paragraph({ Title="状态", Desc="空闲" })
    BoatSec:Paragraph({
        Title = "载具移动提示",
        Desc = "Teleport Mode Boat will walk to the current island vehicle merchant, summon the selected vehicle, sit in the driver seat, then drive to the selected island.",
    })
    BoatSec:Slider({ Title="船速度", Icon="gauge", Value={Min=20,Max=500,Default=S.BoatSpeed},
        Callback=function(v) S.BoatSpeed=tonumber(v) or 120; applyBoatSpeed() end })
    BoatSec:Input({ Title="船速度数值", Icon="hash", Value=tostring(S.BoatSpeed or 120),
        Placeholder="120",
        Callback=function(v)
            local n = tonumber(v)
            if n then S.BoatSpeed = math.clamp(n, 20, 500); applyBoatSpeed() end
        end })
    BoatSec:Toggle({ Title="设置船速度", Icon="ship-wheel", Default=false,
        Callback=function(v) S.BoatSpeedEnabled=v; if v then applyBoatSpeed() end end })
    BoatSec:Button({ Title="应用船速度（一次）", Icon="check", Callback=applyBoatSpeed })

    local SavePosSec = section(PlayerTab, { Title = "已保存位置", Icon = "bookmark" })
    Paragraphs.savedpos = SavePosSec:Paragraph({ Title="状态", Desc="No saved position" })
    SavePosSec:Button({ Title="保存当前位置", Icon="save",
        Callback=function()
            local root = getRoot()
            if root then
                S.SavedPosition = root.CFrame
                setStatus("savedpos", ("Saved: %.1f, %.1f, %.1f"):format(root.Position.X, root.Position.Y, root.Position.Z))
            end
        end })
    SavePosSec:Button({ Title="回到保存的位置", Icon="rotate-ccw",
        Callback=function()
            if S.SavedPosition then tweenTo(S.SavedPosition, S.TweenSpeed); setStatus("savedpos","Returned") end
        end })

    local SellSec = section(PlayerTab, { Title = "自动出售", Icon = "coins" })
    Paragraphs.sell = SellSec:Paragraph({ Title="状态", Desc="Ready" })
    SellSec:Dropdown({ Title="出售方式", Icon="list",
        Values={"SellHeld (held fish)","SellAll (at NPC)"},
        Default="SellAll (at NPC)",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SellMethod=tostring(v or "SellAll (at NPC)") end })
    SellSec:Toggle({ Title="背包满时自动出售", Icon="backpack", Default=false,
        Callback=function(v)
            S.AutoSellWhenFull = v
            setStatus("sell", v and "Auto Sell When Full: ON" or "Auto Sell When Full: OFF")
        end })
    SellSec:Toggle({ Title="定时自动出售", Icon="timer", Default=false,
        Callback=function(v)
            S.AutoSellInterval = v
            local total = math.max(5, (tonumber(S.SellIntervalMinutes) or 0) * 60 + (tonumber(S.SellIntervalSeconds) or 0))
            local tr = env.TranslateText or function(text) return text end
            setStatus("sell", v and (("%s %ds"):format(tr("Next interval sell in"), total)) or "Auto interval sell: OFF")
        end })
    SellSec:Input({ Title="出售间隔（分钟）", Icon="clock", Value=tostring(S.SellIntervalMinutes or 1),
        Callback=function(v)
            S.SellIntervalMinutes = math.max(0, tonumber(v) or 0)
            local total = math.max(5, (S.SellIntervalMinutes or 0) * 60 + (tonumber(S.SellIntervalSeconds) or 0))
            setStatus("sell", ("Sell interval: %dm %ds (%ds)"):format(S.SellIntervalMinutes or 0, tonumber(S.SellIntervalSeconds) or 0, total))
        end })
    SellSec:Input({ Title="出售间隔（秒）", Icon="clock-3", Value=tostring(S.SellIntervalSeconds or 30),
        Callback=function(v)
            S.SellIntervalSeconds = math.max(0, tonumber(v) or 0)
            local total = math.max(5, (tonumber(S.SellIntervalMinutes) or 0) * 60 + (S.SellIntervalSeconds or 0))
            setStatus("sell", ("Sell interval: %dm %ds (%ds)"):format(tonumber(S.SellIntervalMinutes) or 0, S.SellIntervalSeconds or 0, total))
        end })
    SellSec:Slider({ Title="手动鱼类上限（0 = 自动检测）", Icon="hash",
        Value = { Min = 0, Max = 500, Default = S.ManualFishLimit or 0 },
        Callback = function(v)
            v = tonumber(v) or 0
            S.ManualFishLimit = v
            if v > 0 then
                setStatus("sell", ("Manual limit = %d"):format(v))
            else
                setStatus("sell", "Using auto capacity detection")
            end
        end })
    SellSec:Button({ Title="检查背包状态", Icon="info",
        Callback=function()
            local ok, full, count, limit, src = pcall(env.backpackIsFull)
            if not ok then
                setStatus("sell", "Backpack check failed: " .. tostring(full))
                return
            end
            setStatus("sell", ("Fish %s/%s | Full=%s | Source=%s"):format(
                tostring(count), tostring(limit), tostring(full), tostring(src or "?")))
        end })
    SellSec:Button({ Title="出售一次（选中方式）", Icon="circle-dollar-sign",
        Callback=function()
            local m = S.SellMethod or "SellAll (at NPC)"
            if m:find("SellHeld") then sellHeld() else sellAll() end
        end })
    SellSec:Button({ Title="出售手持鱼", Icon="hand", Callback=sellHeld })
    SellSec:Button({ Title="全部出售（在 NPC 处）", Icon="store", Callback=sellAll })

    local LockFishSec = section(PlayerTab, { Title = "自动锁定鱼", Icon = "lock" })
    Paragraphs.lockfish = LockFishSec:Paragraph({ Title="状态", Desc="Choose fish or rarity, then auto lock." })
    LockFishSec:Dropdown({ Title="要锁定的鱼", Icon="fish",
        Values=(getFishOptions and getFishOptions()) or {"All"},
        Default=S.SelectedLockFish or "All",
        Callback=function(v)
            if type(v)=="table" then v=v.Value or v[1] end
            S.SelectedLockFish=tostring(v or "All")
            setStatus("lockfish", "Fish filter: "..S.SelectedLockFish)
        end })
    local lockRarityOptions = {"All"}
    for _, rarity in ipairs((getRarityOptions and getRarityOptions()) or {"Common","Uncommon","Rare","Epic","Legendary","Mythical","Divine"}) do
        lockRarityOptions[#lockRarityOptions+1] = rarity
    end
    LockFishSec:Dropdown({ Title="要锁定的稀有度", Icon="sparkles",
        Values=lockRarityOptions,
        Default=S.SelectedLockRarity or "All",
        Callback=function(v)
            if type(v)=="table" then v=v.Value or v[1] end
            S.SelectedLockRarity=tostring(v or "All")
            setStatus("lockfish", "Rarity filter: "..S.SelectedLockRarity)
        end })
    LockFishSec:Toggle({ Title="自动锁定选中的鱼", Icon="repeat", Default=false,
        Callback=function(v) S.AutoLockFish=v end })
    LockFishSec:Button({ Title="锁定选中鱼（一次）", Icon="lock-keyhole",
        Callback=function()
            if env.autoLockSelectedFishOnce then env.autoLockSelectedFishOnce() end
        end })
    LockFishSec:Button({ Title="切换锁定手持鱼", Icon="lock", Callback=lockHeldFish })
    LockFishSec:Button({ Title="检查手持鱼 UID", Icon="info",
        Callback=function()
            local ctrl = env.getSellController and env.getSellController()
            if not ctrl then setStatus("lockfish","背包服务未就绪"); return end
            local uid = ctrl:GetHeldFishUid()
            setStatus("lockfish", uid and "Selected fish detected" or "No fish held")
        end })

    local FishFilterSec = section(PlayerTab, { Title = "鱼类过滤", Icon = "funnel" })
    FishFilterSec:Paragraph({
        Title = "鱼类过滤使用说明",
        Desc = "Select fish or rarity here to make auto fishing ignore them. If Auto Miss is enabled, matching fish will press the wrong QTE direction on purpose.",
    })
    Paragraphs.fishfilter = FishFilterSec:Paragraph({ Title = "已忽略的过滤", Desc = "No ignored fish filter. Auto fishing will handle every fish." })
    Paragraphs.fishfilterlist = FishFilterSec:Paragraph({ Title = "匹配的鱼", Desc = "None" })

    FishFilterSec:Toggle({
        Title = "跳过过滤掉的鱼",
        Icon = "x-circle",
        Default = S.AutoMissFilteredFish ~= false,
        Callback = function(v)
            S.AutoMissFilteredFish = v == true
            setStatus("fishfilter", S.AutoMissFilteredFish and "Auto Miss filtered fish: ON" or "Auto Miss filtered fish: OFF")
        end,
    })

    local function refreshFilterStatus()
        local active = {}
        if type(S.FishFilterRarities) == "table" and #S.FishFilterRarities > 0 then
            active[#active+1] = "Rarity: " .. table.concat(S.FishFilterRarities, ", ")
        elseif S.FishFilterRarityInput ~= "" then
            active[#active+1] = "Rarity: " .. S.FishFilterRarityInput
        end
        if S.FishFilterName ~= "" then active[#active+1] = "Name: " .. S.FishFilterName end
        if (tonumber(S.FishFilterMinWeight) or 0) > 0 then active[#active+1] = ("Min: %.0f kg"):format(S.FishFilterMinWeight) end
        if (tonumber(S.FishFilterMaxWeight) or 100000) < 100000 then active[#active+1] = ("Max: %.0f kg"):format(S.FishFilterMaxWeight) end
        if S.FishFilterHugeOnly then active[#active+1] = "仅巨型" end
        if S.FishFilterLockMode ~= "All" then active[#active+1] = "Lock: " .. S.FishFilterLockMode end
        local selectedFish = tostring(S.FishFilterSelectedFish or "All")
        if selectedFish ~= "All" then active[#active+1] = "Fish: " .. selectedFish end
        setStatus("fishfilter", #active == 0 and "No ignored fish filter. Auto fishing will handle every fish." or ("Ignoring: " .. table.concat(active, " | ")))
    end

    FishFilterSec:Dropdown({
        Title = "要忽略的鱼",
        Icon = "fish",
        Values = (getFishOptions and getFishOptions()) or {"All"},
        Default = S.FishFilterSelectedFish or "All",
        Callback = function(v)
            if type(v) == "table" then v = v.Value or v[1] end
            S.FishFilterSelectedFish = tostring(v or "All")
            refreshFilterStatus()
        end,
    })
    FishFilterSec:Dropdown({
        Title = "稀有度",
        Icon = "sparkles",
        Values = (getRarityOptions and getRarityOptions()) or {"Common","Uncommon","Rare","Epic","Legendary","Mythical","Divine"},
        Multi = true,
        Multiple = true,
        MultiSelect = true,
        Default = {},
        Callback = function(v)
            S.FishFilterRarityInput = ""
            S.FishFilterRarities = normalizeRaritySelection and normalizeRaritySelection(v) or {}
            refreshFilterStatus()
        end,
    })
    FishFilterSec:Input({ Title = "名称包含", Icon = "search", Value = "", Placeholder = "dragon",
        Callback = function(v) S.FishFilterName = tostring(v or ""); refreshFilterStatus() end })
    FishFilterSec:Slider({ Title = "最小重量 (kg)", Icon = "weight",
        Value = { Min = 0, Max = 10000, Default = 0 },
        Callback = function(v) S.FishFilterMinWeight = tonumber(v) or 0; refreshFilterStatus() end })
    FishFilterSec:Slider({ Title = "最大重量 (kg)", Icon = "weight",
        Value = { Min = 100, Max = 100000, Default = 100000 },
        Callback = function(v) S.FishFilterMaxWeight = tonumber(v) or 100000; refreshFilterStatus() end })
    FishFilterSec:Toggle({ Title = "仅巨型", Icon = "star", Default = false,
        Callback = function(v) S.FishFilterHugeOnly = v; refreshFilterStatus() end })
    FishFilterSec:Dropdown({ Title = "锁定状态", Icon = "lock",
        Values = { "All", "Locked only", "Unlocked only" }, Default = "All",
        Callback = function(v)
            if type(v) == "table" then v = v.Value or v[1] end
            S.FishFilterLockMode = tostring(v or "All")
            refreshFilterStatus()
        end })

    FishFilterSec:Button({ Title = "匹配数量", Icon = "hash",
        Callback = function()
            local list = env.getFilteredFishList and env.getFilteredFishList() or {}
            setStatus("fishfilterlist", ("Matched: %d fish"):format(#list))
        end })
    FishFilterSec:Button({ Title = "预览匹配列表", Icon = "list",
        Callback = function()
            local list = env.getFilteredFishList and env.getFilteredFishList() or {}
            local lines = { ("=== Matched Fish (%d) ==="):format(#list) }
            for i, f in ipairs(list) do
                lines[#lines+1] = ("%d. %s [%s] %.1fkg%s%s"):format(
                    i, f.name, f.rarity, f.weight,
                    f.isHuge and " HUGE" or "",
                    f.locked and " LOCKED" or "")
            end
            print(table.concat(lines, "\n"))
            local preview = {}
            for i = 1, math.min(5, #list) do
                preview[#preview+1] = ("%s [%s] %.1fkg"):format(list[i].name, list[i].rarity, list[i].weight)
            end
            setStatus("fishfilterlist", #preview > 0 and table.concat(preview, "\n") or "No matched fish")
        end })
    FishFilterSec:Button({ Title = "锁定所有匹配", Icon = "lock",
        Callback = function()
            local ctrl = env.getSellController and env.getSellController() or nil
            if not ctrl then setStatus("fishfilterlist", "背包服务未就绪"); return end
            local list = env.getFilteredFishList and env.getFilteredFishList() or {}
            if #list == 0 then setStatus("fishfilterlist", "No matched fish"); return end
            task.spawn(function()
                local locked, skipped = 0, 0
                for _, f in ipairs(list) do
                    if not f.locked then
                        pcall(function() ctrl:ToggleLock(f.uid) end)
                        locked += 1
                        task.wait(0.2)
                    else
                        skipped += 1
                    end
                end
                setStatus("fishfilterlist", ("Locked: %d | Skipped: %d"):format(locked, skipped))
            end)
        end })
    FishFilterSec:Button({ Title = "解锁所有匹配", Icon = "unlock",
        Callback = function()
            local ctrl = env.getSellController and env.getSellController() or nil
            if not ctrl then setStatus("fishfilterlist", "背包服务未就绪"); return end
            local list = env.getFilteredFishList and env.getFilteredFishList() or {}
            if #list == 0 then setStatus("fishfilterlist", "No matched fish"); return end
            task.spawn(function()
                local unlocked, skipped = 0, 0
                for _, f in ipairs(list) do
                    if f.locked then
                        pcall(function() ctrl:ToggleLock(f.uid) end)
                        unlocked += 1
                        task.wait(0.2)
                    else
                        skipped += 1
                    end
                end
                setStatus("fishfilterlist", ("Unlocked: %d | Skipped: %d"):format(unlocked, skipped))
            end)
        end })
    FishFilterSec:Button({ Title = "清除所有过滤", Icon = "trash-2",
        Callback = function()
            S.FishFilterSelectedFish = "All"
            S.FishFilterRarityInput = ""
            S.FishFilterRarities = {}
            S.FishFilterName = ""
            S.FishFilterMinWeight = 0
            S.FishFilterMaxWeight = 100000
            S.FishFilterHugeOnly = false
            S.FishFilterLockMode = "All"
            refreshFilterStatus()
            setStatus("fishfilterlist", "已清除")
        end })
    FishFilterSec:Toggle({ Title = "钓到匹配鱼时自动锁定", Icon = "repeat", Default = false,
        Callback = function(v)
            S.AutoLockFiltered = v
            refreshFilterStatus()
            setStatus("fishfilterlist", v and "Auto lock matched fish: ON" or "Auto lock matched fish: OFF")
        end })
    FishFilterSec:Button({ Title = "显示当前鱼", Icon = "fish",
        Callback = function()
            local fish = env.getCurrentFish and env.getCurrentFish() or nil
            if fish then
                setStatus("fishfilterlist", ("%s [%s]\nHP: %d/%d | %s"):format(
                    fish.name, fish.rarity, fish.hp, fish.maxHp, fish.state))
            else
                setStatus("fishfilterlist", "No active fish")
            end
        end })

    local RodSec = section(PlayerTab, { Title = "购买鱼竿", Icon = "shopping-cart" })
    Paragraphs.buyrod = RodSec:Paragraph({ Title="状态", Desc="空闲" })
    RodSec:Dropdown({ Title="鱼竿", Icon="list", Values=getRodOptions(), Default=getRodOptions()[1],
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SelectedRod=tostring(v or "stone_rod") end })
    RodSec:Toggle({ Title="金币够时自动购买", Icon="repeat", Default=false, Callback=function(v) S.AutoBuyRod=v end })
    RodSec:Button({ Title="购买一次", Icon="shopping-bag", Callback=buyRodOnce })

end

-- ============================================================
-- FUNCTION 12: buildVisualTab
-- ============================================================
local function buildVisualTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local applyMapXRay = env.applyMapXRay
    local clearESP = env.clearESP
    local applyFakeStats = env.applyFakeStats
    local applyStreamer = env.applyStreamer
    local getRoot = env.getRoot

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddSlider and not c.Slider then function c:Slider(o) return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.AddInput and not c.Input then function c:Input(o) return self:AddInput(o.Title or o.Name or "Input", o) end end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local VisualTab = Window:Tab({ Title = "视觉", Icon = "eye" })

    local ESPSec = section(VisualTab, { Title = "透视", Icon = "eye" })
    ESPSec:Slider({ Title="透视距离", Icon="ruler", Value={Min=200,Max=10000,Default=S.ESPDistance},
        Callback=function(v) S.ESPDistance=tonumber(v) or 2500 end })
    ESPSec:Toggle({ Title="玩家透视（高亮 + 岛屿）", Icon="users", Default=false, Callback=function(v) S.ESPPlayers=v end })
    ESPSec:Toggle({ Title="NPC 透视（高亮）", Icon="bot", Default=false, Callback=function(v) S.ESPNPCs=v end })
    ESPSec:Toggle({ Title="鱼 ESP（高亮）", Icon="fish", Default=false, Callback=function(v) S.ESPFish=v end })
    ESPSec:Toggle({ Title="引导 ESP（高亮）", Icon="map-pin", Default=false, Callback=function(v) S.ESPGuides=v end })
    ESPSec:Toggle({ Title="方框 ESP 轮廓", Icon="box", Default=false,
        Callback=function(v) S.ESPBox=v end })
    -- Color pickers via RGB inputs
    ESPSec:Input({ Title="玩家颜色 (R,G,B)", Icon="palette", Value="80,170,255",
        Callback=function(v)
            local r,g,b = tostring(v):match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
            if r then S.ESPColorPlayers = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b)) end
        end })
    ESPSec:Input({ Title="NPC颜色 (R,G,B)", Icon="palette", Value="255,210,90",
        Callback=function(v)
            local r,g,b = tostring(v):match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
            if r then S.ESPColorNPCs = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b)) end
        end })
    ESPSec:Input({ Title="鱼类颜色 (R,G,B)", Icon="palette", Value="90,255,200",
        Callback=function(v)
            local r,g,b = tostring(v):match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
            if r then S.ESPColorFish = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b)) end
        end })
    ESPSec:Input({ Title="引导颜色 (R,G,B)", Icon="palette", Value="210,120,255",
        Callback=function(v)
            local r,g,b = tostring(v):match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
            if r then S.ESPColorGuides = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b)) end
        end })
    ESPSec:Button({ Title="清除透视", Icon="trash-2", Callback=clearESP })

    local XRaySec = section(VisualTab, { Title = "地图透视", Icon = "scan-eye" })
    Paragraphs.visual = XRaySec:Paragraph({ Title="状态", Desc="空闲" })
    XRaySec:Toggle({ Title="地图透视", Icon="scan-eye", Default=false,
        Callback=function(v) S.MapXRay=v; applyMapXRay(v) end })

    local FakeStatsSec = section(VisualTab, { Title = "伪造数据", Icon = "badge-dollar-sign" })
    FakeStatsSec:Input({ Title="伪造金币", Icon="coins", Value=S.FakeCoin,
        Callback=function(v) S.FakeCoin=tostring(v); applyFakeStats() end })
    FakeStatsSec:Input({ Title="伪造宝石", Icon="gem", Value=S.FakeGem,
        Callback=function(v) S.FakeGem=tostring(v); applyFakeStats() end })
    FakeStatsSec:Toggle({ Title="伪造界面金币/宝石", Icon="monitor", Default=false,
        Callback=function(v) S.FakeStats=v; applyFakeStats() end })
    FakeStatsSec:Toggle({ Title="同时伪造排行榜", Icon="list", Default=false,
        Callback=function(v) S.FakeLeaderboard=v; applyFakeStats() end })

    local StreamerSec = section(VisualTab, { Title = "主播模式", Icon = "eye-off" })
    StreamerSec:Toggle({ Title="主播模式", Icon="eye-off", Default=false,
        Callback=function(v) S.Streamer=v; applyStreamer() end })
    StreamerSec:Toggle({ Title="重命名所有玩家", Icon="users", Default=false,
        Callback=function(v) S.StreamerAllPlayers=v; applyStreamer() end })
    StreamerSec:Input({ Title="自定义名称", Icon="text-cursor-input", Value=S.FakeName,
        Callback=function(v) S.FakeName=tostring(v or "NNVN Hub"); applyStreamer() end })

    local CosmeticSec = section(VisualTab, { Title = "外观娱乐", Icon = "sparkles" })
    local sparkleAttachment = nil
    local sparkleLoopRunning = false
    local function clearAvatarSparkles()
        if sparkleAttachment and sparkleAttachment.Parent then sparkleAttachment:Destroy() end
        sparkleAttachment = nil
        local root = getRoot and getRoot()
        local old = root and root:FindFirstChild("NNVN_AvatarSparkleAttachment")
        if old then old:Destroy() end
    end
    local function attachAvatarSparkles()
        local root = getRoot and getRoot()
        if not root then return false end
        if sparkleAttachment and sparkleAttachment.Parent == root then return true end
        clearAvatarSparkles()
        local att = Instance.new("Attachment")
        att.Name = "NNVN_AvatarSparkleAttachment"
        att.Position = Vector3.new(0, 0.3, 0)
        att.Parent = root
        sparkleAttachment = att
        local emitter = Instance.new("ParticleEmitter")
        emitter.Name = "SoftSparkles"
        emitter.Texture = "rbxassetid://138952058031836"
        emitter.Rate = 5
        emitter.Lifetime = NumberRange.new(0.7, 1.2)
        emitter.Speed = NumberRange.new(0.8, 1.8)
        emitter.SpreadAngle = Vector2.new(18, 18)
        emitter.Rotation = NumberRange.new(0, 360)
        emitter.RotSpeed = NumberRange.new(-60, 60)
        emitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.16),
            NumberSequenceKeypoint.new(0.5, 0.24),
            NumberSequenceKeypoint.new(1, 0),
        })
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.15),
            NumberSequenceKeypoint.new(0.75, 0.25),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.LightEmission = 0.25
        emitter.Parent = att
        return true
    end
    CosmeticSec:Toggle({
        Title = "头像闪烁",
        Icon = "sparkles",
        Default = false,
        Callback = function(v)
            S.AvatarSparkles = v == true
            if not S.AvatarSparkles then
                clearAvatarSparkles()
                return
            end
            attachAvatarSparkles()
            if sparkleLoopRunning then return end
            sparkleLoopRunning = true
            task.spawn(function()
                while S.AvatarSparkles do
                    pcall(attachAvatarSparkles)
                    task.wait(1)
                end
                clearAvatarSparkles()
                sparkleLoopRunning = false
            end)
        end,
    })
end

-- ============================================================
-- FUNCTION 13: buildShopTab
-- ============================================================
local function buildShopTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local Status = env.Status
    local getCoin = env.getCoin
    local getGem = env.getGem
    local skillGachaQuote = env.skillGachaQuote
    local skillGachaPull = env.skillGachaPull
    local skillGachaPity = env.skillGachaPity
    local auraGachaCost = env.auraGachaCost
    local auraGachaPull = env.auraGachaPull
    local auraGachaPity = env.auraGachaPity
    local resolveCrateId = env.resolveCrateId
    local cratePrice = env.cratePrice
    local crateCurrency = env.crateCurrency
    local cratePull = env.cratePull
    local cratePullFast = env.cratePullFast
    local cratePity = env.cratePity

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown and not c.Dropdown then function c:Dropdown(o)
            o = o or {}
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddSlider and not c.Slider then function c:Slider(o) return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local rawDropdown = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = o or {}
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return rawDropdown(self, o)
            end
        end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local ShopTab = Window:Tab({ Title = "商店 / 开箱", Icon = "shopping-bag" })

    local ShopStatusSec = section(ShopTab, { Title = "状态", Icon = "activity" })
    Paragraphs.shop = ShopStatusSec:Paragraph({ Title="商店 / 开箱", Desc="空闲" })
    ShopStatusSec:Slider({ Title="抽卡延迟", Icon="timer", Value={Min=1,Max=30,Default=S.GachaDelay},
        Callback=function(v) S.GachaDelay=tonumber(v) or 3 end })
    ShopStatusSec:Slider({ Title="保留金币余额", Icon="coins", Value={Min=0,Max=10000000,Default=0},
        Callback=function(v) S.StopCoin=tonumber(v) or 0 end })
    ShopStatusSec:Slider({ Title="保留宝石余额", Icon="gem", Value={Min=0,Max=100000,Default=0},
        Callback=function(v) S.StopGem=tonumber(v) or 0 end })

    local SkillGachaSec = section(ShopTab, { Title = "技能抽卡", Icon = "sparkles" })
    Paragraphs.skillgacha = SkillGachaSec:Paragraph({ Title="状态", Desc="空闲" })
    local function setSkillStatus(text)
        Status.skillgacha = text
        if Paragraphs.skillgacha and Paragraphs.skillgacha.SetDesc then
            pcall(function() Paragraphs.skillgacha:SetDesc(text) end)
        end
    end
    SkillGachaSec:Dropdown({ Title="货币", Icon="coins", Values={"Coin","Robux"}, Default="Coin",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SkillGachaCurrency=tostring(v or "Coin") end })
    SkillGachaSec:Dropdown({ Title="抽卡次数", Icon="hash", Values={"1","10"}, Default="1",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SkillGachaCount=tonumber(v) or 1 end })
    SkillGachaSec:Button({ Title="预览价格（报价）", Icon="calculator",
        Callback=function()
            task.spawn(function()
                local count = S.SkillGachaCount or 1
                local q = skillGachaQuote(count)
                if not q then setSkillStatus("Quote failed"); return end
                local msg = ("Quote x%d: %s Coin | Credits: %d"):format(count, tostring(math.floor(q.coin_cost or 0)), tonumber(q.credits_available) or 0)
                setSkillStatus(msg)
            end)
        end })
    SkillGachaSec:Button({ Title="单次抽卡", Icon="dice-5",
        Callback=function()
            local count = S.SkillGachaCount or 1
            local currency = S.SkillGachaCurrency or "Coin"
            setSkillStatus(("Rolling x%d..."):format(count))
            skillGachaPull(count, currency)
        end })
    SkillGachaSec:Button({ Title="抽 10 次", Icon="dice-6",
        Callback=function() setSkillStatus("Rolling x10..."); skillGachaPull(10, S.SkillGachaCurrency or "Coin") end })
    SkillGachaSec:Toggle({ Title="自动技能抽卡", Icon="repeat", Default=false,
        Callback=function(v) S.AutoSkillGacha=v; setSkillStatus(v and "Auto ON" or "Auto OFF") end })
    SkillGachaSec:Button({ Title="查看保底", Icon="info",
        Callback=function()
            local pity = skillGachaPity()
            if not pity then setSkillStatus("Pity data unavailable"); return end
            local msg = ("Legendary: %s | Mythical: %s"):format(tostring(pity.Legendary or 0), tostring(pity.Mythical or 0))
            setSkillStatus("Pity — "..msg)
        end })

    local AuraGachaSec = section(ShopTab, { Title = "光环抽卡", Icon = "sparkle" })
    Paragraphs.auragacha = AuraGachaSec:Paragraph({ Title="状态", Desc="空闲" })
    local function setAuraStatus(text)
        Status.auragacha = text
        if Paragraphs.auragacha and Paragraphs.auragacha.SetDesc then
            pcall(function() Paragraphs.auragacha:SetDesc(text) end)
        end
    end
    AuraGachaSec:Dropdown({ Title="抽卡次数", Icon="hash", Values={"1","10"}, Default="1",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.AuraGachaCount=tonumber(v) or 1 end })
    AuraGachaSec:Button({ Title="预览消耗", Icon="calculator",
        Callback=function()
            local count = S.AuraGachaCount or 1
            local cost = auraGachaCost(count)
            if not cost then setAuraStatus("Config unavailable"); return end
            local gem = getGem()
            setAuraStatus(("Cost x%d: %d Gem | You have: %d"):format(count, cost, math.floor(gem)))
        end })
    AuraGachaSec:Button({ Title="单次抽卡", Icon="dice-6",
        Callback=function() local count = S.AuraGachaCount or 1; setAuraStatus(("Rolling x%d..."):format(count)); auraGachaPull(count) end })
    AuraGachaSec:Button({ Title="抽 1 次", Icon="dice-5", Callback=function() setAuraStatus("Rolling x1..."); auraGachaPull(1) end })
    AuraGachaSec:Button({ Title="抽 10 次", Icon="dice-6", Callback=function() setAuraStatus("Rolling x10..."); auraGachaPull(10) end })
    AuraGachaSec:Toggle({ Title="自动光环抽卡", Icon="repeat", Default=false,
        Callback=function(v) S.AutoAuraGacha=v; setAuraStatus(v and "Auto ON" or "Auto OFF") end })
    AuraGachaSec:Button({ Title="查看保底", Icon="info",
        Callback=function()
            local pity = auraGachaPity()
            if not pity then setAuraStatus("Pity unavailable"); return end
            setAuraStatus(("Legendary: %s | Mythical: %s | Divine: %s"):format(
                tostring(pity.Legendary or 0), tostring(pity.Mythical or 0), tostring(pity.Divine or 0)))
        end })

    local CrateSec = section(ShopTab, { Title = "开箱", Icon = "package" })
    Paragraphs.crate = CrateSec:Paragraph({ Title="状态", Desc="空闲" })
    local function setCrateStatus(text)
        Status.crate = text
        if Paragraphs.crate and Paragraphs.crate.SetDesc then
            pcall(function() Paragraphs.crate:SetDesc(text) end)
        end
    end
    CrateSec:Dropdown({ Title="开箱", Icon="box", Values={"Ocean Chest","Dragon Chest"}, Default=S.SelectedChest,
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.SelectedChest=tostring(v or "Ocean Chest") end })
    CrateSec:Dropdown({ Title="开箱次数", Icon="hash", Values={"1","10"}, Default="1",
        Callback=function(v) if type(v)=="table" then v=v.Value or v[1] end; S.CrateCount=tonumber(v) or 1 end })
    CrateSec:Button({ Title="预览消耗", Icon="calculator",
        Callback=function()
            local crateId = resolveCrateId(S.SelectedChest or "Ocean Chest")
            local count = S.CrateCount or 1
            local price = cratePrice(crateId, count)
            local curr = crateCurrency(crateId)
            if not price then setCrateStatus("Config unavailable"); return end
            local current = curr=="Gem" and getGem() or getCoin()
            setCrateStatus(("%s x%d: %d %s | You have: %d"):format(crateId, count, price, curr, math.floor(current)))
        end })
    CrateSec:Button({ Title="开一次（带确认）", Icon="package-open",
        Callback=function()
            local crateId = resolveCrateId(S.SelectedChest or "Ocean Chest")
            setCrateStatus(("Opening x%d..."):format(S.CrateCount or 1))
            cratePull(crateId, S.CrateCount or 1)
        end })
    CrateSec:Button({ Title="开 1 个", Icon="package",
        Callback=function() local id=resolveCrateId(S.SelectedChest or "Ocean Chest"); setCrateStatus("Opening x1..."); cratePull(id,1) end })
    CrateSec:Button({ Title="开 10 个", Icon="package",
        Callback=function() local id=resolveCrateId(S.SelectedChest or "Ocean Chest"); setCrateStatus("Opening x10..."); cratePull(id,10) end })
    CrateSec:Button({ Title="⚡ 快速开箱（无确认）", Icon="zap",
        Callback=function()
            local crateId = resolveCrateId(S.SelectedChest or "Ocean Chest")
            setCrateStatus(("Fast opening x%d..."):format(S.CrateCount or 1))
            cratePullFast(crateId, S.CrateCount or 1)
        end })
    CrateSec:Toggle({ Title="自动开箱", Icon="repeat", Default=false,
        Callback=function(v) S.AutoCrate=v; setCrateStatus(v and "Auto ON" or "Auto OFF") end })
    CrateSec:Button({ Title="查看保底", Icon="info",
        Callback=function()
            local crateId = resolveCrateId(S.SelectedChest or "Ocean Chest")
            local pity = cratePity(crateId)
            if not pity then setCrateStatus("Pity unavailable"); return end
            setCrateStatus(("Pity (%s): %d"):format(crateId, pity))
        end })
end

-- ============================================================
-- FUNCTION 14: buildMiscTab
-- ============================================================
local function buildMiscTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local setStatus = env.setStatus
    local getJobIdText = env.getJobIdText
    local copyText = env.copyText
    local rejoinCurrentJob = env.rejoinCurrentJob
    local joinJobId = env.joinJobId
    local claimRewardsOnce = env.claimRewardsOnce
    local redeemAllCodes = env.redeemAllCodes
    local dumpAllCodes = env.dumpAllCodes
    local clearESP = env.clearESP
    local stopTween = env.stopTween

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddInput and not c.Input then function c:Input(o) return self:AddInput(o.Title or o.Name or "Input", o) end end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local function setScreenCover(color)
        local old = PlayerGui:FindFirstChild("NNVN_ScreenCover")
        if old then old:Destroy() end
        local gui = Instance.new("ScreenGui")
        gui.Name = "NNVN_ScreenCover"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 999999
        gui.Parent = PlayerGui
        local frame = Instance.new("Frame")
        frame.Name = "Cover"
        frame.BackgroundColor3 = color
        frame.BorderSizePixel = 0
        frame.Size = UDim2.fromScale(1, 1)
        frame.Parent = gui
        setStatus("miscjob", color == Color3.new(1,1,1) and "White screen enabled" or "Dark screen enabled")
    end

    local function clearScreenCover()
        local old = PlayerGui:FindFirstChild("NNVN_ScreenCover")
        if old then old:Destroy() end
        setStatus("miscjob", "Screen cover cleared")
    end

    local function unloadAllScript()
        for key, value in pairs(S) do
            if type(key) == "string" and key:sub(1, 4) == "Auto" and type(value) == "boolean" then
                S[key] = false
            end
        end
        if stopTween then pcall(stopTween) end
        if clearESP then pcall(clearESP) end
        clearScreenCover()
        for _, name in ipairs({"NNVN_FishingMaster_InfoBar","NNVN_BossStatusGui","NNVN_FishingMaster_ESP"}) do
            local gui = PlayerGui:FindFirstChild(name)
            if gui then pcall(function() gui:Destroy() end) end
            pcall(function()
                local cg = game:GetService("CoreGui")
                local core = cg:FindFirstChild(name)
                if core then core:Destroy() end
            end)
        end
        pcall(function()
            if getgenv then getgenv().NNVN_FishingMasterLoaded = false end
        end)
        setStatus("miscjob", "所有自动化已关闭，覆盖层已移除")
    end

    local MiscTab = Window:Tab({ Title = "杂项", Icon = "wrench" })

    local RewardsSec = section(MiscTab, { Title = "奖励", Icon = "gift" })
    Paragraphs.rewards = RewardsSec:Paragraph({ Title="状态", Desc="空闲" })
    RewardsSec:Toggle({ Title="自动领取奖励", Icon="repeat", Default=false,
        Callback=function(v) S.AutoClaimRewards=v end })
    RewardsSec:Button({ Title="领取奖励（一次）", Icon="gift", Callback=claimRewardsOnce })

    local JobSec = section(MiscTab, { Title = "服务器 ID", Icon = "server" })
    Paragraphs.miscjob = JobSec:Paragraph({ Title="当前服务器", Desc=getJobIdText() })
    JobSec:Input({ Title="加入服务器 ID", Icon="server", Value="",
        Callback=function(v) S.JoinJobId=tostring(v or "") end })
    JobSec:Button({ Title="复制当前服务器 ID", Icon="copy",
        Callback=function()
            local job = getJobIdText()
            setStatus("miscjob", copyText(job) and ("Copied: "..job) or ("JobId: "..job))
        end })
    JobSec:Button({ Title="重新加入当前服务器", Icon="refresh-cw", Callback=rejoinCurrentJob })
    JobSec:Button({ Title="加入输入的服务器 ID", Icon="log-in", Callback=function() joinJobId(S.JoinJobId) end })
    JobSec:Button({ Title="卸载所有脚本", Icon="power", Callback=unloadAllScript })
    JobSec:Button({ Title="白屏", Icon="monitor", Callback=function() setScreenCover(Color3.new(1,1,1)) end })
    JobSec:Button({ Title="暗屏", Icon="moon", Callback=function() setScreenCover(Color3.new(0,0,0)) end })
    JobSec:Button({ Title="清除屏幕遮挡", Icon="x", Callback=clearScreenCover })

    local MiscSec = section(MiscTab, { Title = "兑换码", Icon = "ticket" })
    Paragraphs.misc = MiscSec:Paragraph({ Title="状态", Desc="空闲" })
    MiscSec:Button({ Title="兑换所有码（从模块）", Icon="gift", Callback=redeemAllCodes })
    MiscSec:Button({ Title="导出兑换码（仅查看）", Icon="list", Callback=dumpAllCodes })
        -- ⭐ Index Preview
    local IndexSec = section(MiscTab, { Title = "图鉴预览", Icon = "book-open" })
    Paragraphs.index = IndexSec:Paragraph({ Title = "状态", Desc = "Force show all fish" })

    IndexSec:Toggle({
        Title = "强制图鉴预览（显示所有鱼）",
        Icon = "eye",
        Default = false,
        Callback = function(v)
            if env.setIndexPreview then
                env.setIndexPreview(v)
            end
        end,
    })

    IndexSec:Button({
        Title = "打开图鉴界面",
        Icon = "book-open",
        Callback = function()
            if env.openIndexUI then env.openIndexUI() end
        end,
    })

    IndexSec:Button({
        Title = "切换预览（一次）",
        Icon = "refresh-cw",
        Callback = function()
            if not env.setIndexPreview then return end
            local cur = env.S.IndexPreview == true
            env.setIndexPreview(not cur)
        end,
    })

    local StatusBarSec = section(MiscTab, { Title = "状态栏设置", Icon = "panel-top" })
    Paragraphs.statusbar = StatusBarSec:Paragraph({ Title="状态", Desc="All status bar fields are visible" })
    local function updateStatusBarStatus()
        local shown = {}
        if S.InfoBarEnabled ~= false then shown[#shown+1] = "Bar" end
        if S.InfoShowGameName ~= false then shown[#shown+1] = "Game" end
        if S.InfoShowPing ~= false then shown[#shown+1] = "Ping" end
        if S.InfoShowFPS ~= false then shown[#shown+1] = "FPS" end
        if S.InfoShowIsland ~= false then shown[#shown+1] = "岛屿" end
        if S.InfoShowDismiss ~= false then shown[#shown+1] = "Dismiss" end
        setStatus("statusbar", #shown > 0 and ("Visible: " .. table.concat(shown, ", ")) or "All fields hidden")
    end
    StatusBarSec:Toggle({ Title="显示状态栏", Icon="rectangle-horizontal", Default=true,
        Callback=function(v) S.InfoBarEnabled = v; updateStatusBarStatus() end })
    StatusBarSec:Toggle({ Title="显示游戏名", Icon="badge-info", Default=true,
        Callback=function(v) S.InfoShowGameName = v; updateStatusBarStatus() end })
    StatusBarSec:Toggle({ Title="显示延迟", Icon="wifi", Default=true,
        Callback=function(v) S.InfoShowPing = v; updateStatusBarStatus() end })
    StatusBarSec:Toggle({ Title="显示 FPS", Icon="gauge", Default=true,
        Callback=function(v) S.InfoShowFPS = v; updateStatusBarStatus() end })
    StatusBarSec:Toggle({ Title="显示岛屿", Icon="map-pin", Default=true,
        Callback=function(v) S.InfoShowIsland = v; updateStatusBarStatus() end })
    StatusBarSec:Toggle({ Title="显示关闭状态", Icon="mouse-pointer-click", Default=true,
        Callback=function(v) S.InfoShowDismiss = v; updateStatusBarStatus() end })
end

-- ============================================================
-- FUNCTION 15: buildPriorityTab
-- ============================================================
local function buildPriorityTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local setStatus = env.setStatus

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddSlider and not c.Slider then function c:Slider(o) return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local PriorityTab = Window:Tab({ Title = "优先级", Icon = "list-ordered" })
    local PrioritySec = section(PriorityTab, { Title = "功能优先级", Icon = "sliders-horizontal" })
    Paragraphs.priority = PrioritySec:Paragraph({
        Title = "状态",
        Desc = "Auto Sell pauses fishing actions while it walks, sells, and returns.",
    })

    local function prioritySlider(title, icon, key)
        PrioritySec:Slider({
            Title = title,
            Icon = icon,
            Value = { Min = 0, Max = 100, Default = tonumber(S[key]) or 50 },
            Callback = function(v)
                S[key] = math.clamp(math.floor(tonumber(v) or 0), 0, 100)
                setStatus("priority", ("%s priority = %d"):format(title, S[key]))
            end,
        })
    end

    prioritySlider("Farming Priority", "fish", "PriorityFarm")
    prioritySlider("Auto Sell Priority", "coins", "PriorityAutoSell")
    prioritySlider("Fish Filter Priority", "funnel", "PriorityFishFilter")
    prioritySlider("Auto Lock Priority", "lock", "PriorityAutoLock")
    prioritySlider("Shop / Gacha Priority", "shopping-bag", "PriorityShop")
    prioritySlider("Auto Quest Priority", "scroll", "PriorityAutoQuest")
    prioritySlider("Boss Priority", "swords", "PriorityBoss")
    prioritySlider("Rewards Priority", "gift", "PriorityRewards")

    PrioritySec:Button({
        Title = "重置优先级默认值",
        Icon = "rotate-ccw",
        Callback = function()
            S.PriorityFarm = 50
            S.PriorityAutoSell = 90
            S.PriorityFishFilter = 60
            S.PriorityAutoLock = 45
            S.PriorityShop = 35
            S.PriorityAutoQuest = 40
            S.PriorityBoss = 55
            S.PriorityRewards = 25
            setStatus("priority", "Priority defaults restored")
        end,
    })
end

-- ============================================================
-- FUNCTION 15: buildSettingsTab
-- ============================================================
local function buildSettingsTab(env)
    local Window = env.Window
    local WindUI = env.WindUI
    local S = env.S
    local Paragraphs = env.Paragraphs
    local setStatus = env.setStatus
    local notify = env.notify
    local copyText = env.copyText
    local LANGUAGE_OPTIONS = env.LANGUAGE_OPTIONS
    local ApplyUILanguage = env.ApplyUILanguage
    local trim = env.trim

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        if c.AddToggle and not c.Toggle then function c:Toggle(o) return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown and not c.Dropdown then function c:Dropdown(o)
            o = o or {}
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddInput and not c.Input then function c:Input(o) return self:AddInput(o.Title or o.Name or "Input", o) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local rawDropdown = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = o or {}
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return rawDropdown(self, o)
            end
        end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local SettingsTab = Window:Tab({ Title = "设置", Icon = "settings" })
    local SettingsSec = section(SettingsTab, { Title = "WindUI 设置", Icon = "settings" })
    Paragraphs.settings = SettingsSec:Paragraph({ Title="状态", Desc="Theme & Icon settings" })

    local themeNames = {}
    pcall(function()
        local themes = WindUI:GetThemes()
        if type(themes) == "table" then
            for name in pairs(themes) do table.insert(themeNames, name) end
            table.sort(themeNames)
        end
    end)
    if #themeNames == 0 then
        themeNames = {"Midnight","Dark","Light","Rose","Plant","Aqua","Amethyst","Emerald","Indigo","Orange","Pink","Purple","Red","Sky","Yellow","Zinc","Modern","Rainbow"}
    elseif not table.find(themeNames, "Midnight") then
        table.insert(themeNames, 1, "Midnight")
    end

    SettingsSec:Dropdown({
        Title = "主题", Icon = "palette", Values = themeNames,
        Default = (function()
            local cur = "Midnight"
            pcall(function() cur = WindUI:GetCurrentTheme() or "Midnight" end)
            return cur
        end)(),
        Callback = function(v)
            if type(v) == "table" then v = v.Value or v[1] end
            v = tostring(v or "Midnight")
            pcall(function() WindUI:SetTheme(v) end)
            setStatus("settings", "Theme set to: " .. v)
            notify("主题", "Changed to " .. v)
        end,
    })

    SettingsSec:Paragraph({
        Title = "图片主题说明",
        Desc = "Open Roblox Creator Store, search for an image, copy the asset id, then paste only the number below.",
    })
    SettingsSec:Button({
        Title = "复制 Roblox 创作者贴图链接", Icon = "copy",
        Callback = function()
            local link = "https://create.roblox.com/store/category/2d/decals"
            setStatus("settings", copyText(link) and "Copied Creator decals link" or link)
        end,
    })
    SettingsSec:Input({
        Title = "图片主题", Icon = "image", Value = "",
        Placeholder = "rbxassetid://",
        Callback = function(v)
            v = trim(tostring(v or ""))
            if v == "" then return end
            local id = v:match("rbxassetid://(%d+)") or v:match("(%d+)")
            if not id then setStatus("settings", "Invalid Asset ID"); return end
            local asset = "rbxassetid://" .. id
            S.ImageTheme = asset
            pcall(function()
                if type(WindUI.Scheme) == "table" then
                    WindUI.Scheme.BackgroundImage = asset
                end
                if type(WindUI.UpdateColors) == "function" then WindUI:UpdateColors() end
            end)
            pcall(function()
                if Window.SetBackground then Window:SetBackground(asset) end
                if Window.SetBackgroundImage then Window:SetBackgroundImage(asset) end
            end)
            setStatus("settings", "Image Theme set: " .. asset)
        end,
    })

    SettingsSec:Dropdown({
        Title = "语言", Icon = "languages", Values = LANGUAGE_OPTIONS,
        Default = S.SelectedLanguage or "English",
        Callback = function(v)
            if type(v) == "table" then v = v.Value or v[1] end
            S.SelectedLanguage = tostring(v or "English")
            setStatus("settings", "Language: " .. S.SelectedLanguage .. " (press Apply)")
        end,
    })

    SettingsSec:Button({
        Title = "应用语言", Icon = "check",
        Callback = function()
            local lang = S.SelectedLanguage or "English"
            getgenv().NNVN_Language = lang
            pcall(ApplyUILanguage)
            task.delay(0.35, function() pcall(ApplyUILanguage) end)
            setStatus("settings", "Language: " .. getgenv().NNVN_Language)
        end,
    })
end

-- ============================================================
-- FUNCTION 16: buildInfoTab
-- ============================================================
local function buildInfoTab(env)
    local Window = env.Window
    local S = env.S
    local Paragraphs = env.Paragraphs
    local notify = env.notify
    local accessText = env.accessText
    local getInfoText = env.getInfoText
    local refreshPremiumAccess = env.refreshPremiumAccess
    local fetchDiscordStats = env.fetchDiscordStats

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton and not c.Button then function c:Button(o) return self:AddButton(o) end end
        return c
    end
    local function section(tab, opts)
        opts = opts or {}
        opts.Open=true; opts.Opened=true; opts.DefaultOpen=true; opts.Collapsed=false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local InfoTab = Window:Tab({ Title = "首页", Icon = "house" })
    local DiscordSec = section(InfoTab, { Title = "Discord", Icon = "message-circle" })
    local discordInvite = "https://discord.gg/5JJAuHRUgJ"
    local discordCard = {
        Title = "NNVN Hub",
        Subtitle = "Join Discord for hub updates",
        Banner = "rbxassetid://138952058031836",
        Avatar = "rbxassetid://138952058031836",
        Status = "online",
        Accent = Color3.fromRGB(88, 101, 242),
        Link = discordInvite,
        BannerHeight = 64,
        AvatarSize = 56,
        Buttons = {
            {
                Text = "复制 Discord 邀请链接",
                Icon = "copy",
                Copy = true,
                CopiedText = "Copied",
                Func = function()
                    notify("Discord", env.copyText(discordInvite) and "Copied Discord invite" or discordInvite)
                end,
            },
        },
    }
    if DiscordSec.AddDiscordBox then
        DiscordSec:AddDiscordBox("NNVNDiscord", discordCard)
    elseif DiscordSec.DiscordBox then
        DiscordSec:DiscordBox(discordCard)
    else
        DiscordSec:Paragraph({
            Title = "NNVN Hub",
            Desc = "Join Discord for hub updates\nIcon: rbxassetid://138952058031836\n" .. discordInvite,
        })
        DiscordSec:Button({
            Title = "复制 Discord 邀请链接", Icon = "copy",
            Callback = function()
                notify("Discord", env.copyText(discordInvite) and "Copied Discord invite" or discordInvite)
            end,
        })
    end
    local InfoSec = section(InfoTab, { Title = "NNVN Hub", Icon = "info" })
    Paragraphs.access = InfoSec:Paragraph({ Title="访问标签", Desc=accessText() })
    InfoSec:Paragraph({ Title="作者", Desc="By n0namevnnek & thang" })
    InfoSec:Paragraph({ Title="Discord", Desc="https://discord.gg/5JJAuHRUgJ" })
    Paragraphs.discordstatus = InfoSec:Paragraph({
        Title = "Discord 状态",
        Desc = ("Online: %s | All Members: %s"):format(tostring(S.DiscordOnline or "Unknown"), tostring(S.DiscordMembers or "Unknown")),
    })
    Paragraphs.playerinfo = InfoSec:Paragraph({ Title="玩家信息", Desc=getInfoText() })
    InfoSec:Button({ Title="刷新 Discord 状态", Icon="activity",
        Callback=function()
            if fetchDiscordStats then pcall(fetchDiscordStats) end
            local text = ("Online: %s | All Members: %s"):format(tostring(S.DiscordOnline or "Unknown"), tostring(S.DiscordMembers or "Unknown"))
            if Paragraphs.discordstatus and Paragraphs.discordstatus.SetDesc then
                pcall(function() Paragraphs.discordstatus:SetDesc(text) end)
            end
            notify("Discord 状态", text)
        end })
    InfoSec:Button({ Title="刷新玩家信息", Icon="refresh-cw",
        Callback=function()
            local text = getInfoText()
            if Paragraphs.playerinfo and Paragraphs.playerinfo.SetDesc then
                pcall(function() Paragraphs.playerinfo:SetDesc(text) end)
            end
            notify("Info", text)
        end })
    InfoSec:Button({ Title="刷新访问标签", Icon="shield-check",
        Callback=function() notify("Access", refreshPremiumAccess() and "PREMIUM" or "FREE") end })
    task.spawn(function()
        if fetchDiscordStats then pcall(fetchDiscordStats) end
        local text = ("Online: %s | All Members: %s"):format(tostring(S.DiscordOnline or "Unknown"), tostring(S.DiscordMembers or "Unknown"))
        if Paragraphs.discordstatus and Paragraphs.discordstatus.SetDesc then
            pcall(function() Paragraphs.discordstatus:SetDesc(text) end)
        end
    end)
end
-- FUNCTION: buildAutoQuestTab — Auto Quest
-- ============================================================
-- ============================================================
-- FUNCTION: buildAutoQuestTab — Auto Quest v2 (Integrated)
-- Tích hợp: QuestController, QuestConfig, Requirements, PlayerDataV2
-- ============================================================
-- ============================================================
-- FUNCTION: buildAutoQuestTab — Auto Quest Pro
-- ============================================================
local function buildAutoQuestTab(env)
    local Window                 = env.Window
    local S                      = env.S
    local Paragraphs             = env.Paragraphs
    local Status                 = env.Status
    local setStatus              = env.setStatus
    local notify                 = env.notify
    local getStardustClient      = env.getStardustClient
    local getPlayerData          = env.getPlayerData
    local getCoin                = env.getCoin
    local getRoot                = env.getRoot
    local tweenTo                = env.tweenTo
    local findInteractiveByNames = env.findInteractiveByNames
    local objectCFrame           = env.objectCFrame
    local fireRemoteNames        = env.fireRemoteNames
    local unlockIslandOnce       = env.unlockIslandOnce
    local getChar                = env.getChar
    local getIslandForPosition   = env.getIslandForPosition
    local fastTravelToIsland     = env.fastTravelToIsland
    local buyRodOnce             = env.buyRodOnce

    local QuestConfig = nil
    pcall(function()
        QuestConfig = require(ReplicatedStorage.Data.Config.QuestConfig)
    end)
    if not QuestConfig or not QuestConfig.Data then
        QuestConfig = { Data = {}, QuestTypes = {}, UnlockIsland6MinWeightKg = {}, WhiteTigerMinWeightKg = 1000 }
    end

    local _questCtrl = nil
    local function getQuestController()
        if _questCtrl then return _questCtrl end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("QuestController") end)
        if ok and type(ctrl) == "table" then _questCtrl = ctrl; return ctrl end
        return nil
    end

    local _pdataCtrlCache = nil
    local function getPlayerDataV2Lazy()
        if _pdataCtrlCache then return _pdataCtrlCache end
        local Client = getStardustClient()
        if not Client then return nil end
        local ok, ctrl = pcall(function() return Client.GetController("PlayerDataV2Controller") end)
        if ok and type(ctrl) == "table" then _pdataCtrlCache = ctrl; return ctrl end
        return nil
    end

    local function fetchPData()
        local ctrl = getPlayerDataV2Lazy()
        if ctrl then
            local ok, data = pcall(function() return ctrl:Fetch() end)
            if ok and type(data) == "table" then return data end
        end
        return nil
    end

    local function pdGet(pdata, name)
        if not pdata then return nil end
        if type(pdata) == "table" then return pdata[name] end
        local ok, attr = pcall(function() return pdata:GetAttribute(name) end)
        if ok and attr ~= nil then return attr end
        return nil
    end

    local function getQuestIds()
        local list = {}
        for id in pairs(QuestConfig.Data) do list[#list+1] = id end
        table.sort(list)
        return list
    end

    local function getQuestInfo(questId) return QuestConfig.Data[questId] end

    local function getActiveQuest()
        local pdata = fetchPData()
        if not pdata then return nil, nil end
        local q = pdGet(pdata, "Quest")
        if not q then return nil, nil end
        local cur = (type(q) == "table") and q.Current or pdGet(q, "当前")
        if not cur then return nil, nil end
        local id = (type(cur) == "table") and cur.Id or pdGet(cur, "Id")
        if not id or id == "" then return nil, nil end
        local prog = (type(cur) == "table") and cur.Progress or pdGet(cur, "进度")
        return id, prog or {}
    end

    local function isQuestDone(questId)
        local pdata = fetchPData()
        if not pdata then return false end
        local q = pdGet(pdata, "Quest")
        if not q then return false end
        local done = (type(q) == "table") and q.Done or pdGet(q, "Done")
        if type(done) ~= "table" then return false end
        return done[questId] == true
    end

    local function isIslandUnlocked(islandId)
        if not islandId or islandId == "" then return true end
        local pdata = fetchPData()
        if not pdata then return false end
        local islands = pdGet(pdata, "UnlockedIslands")
        if type(islands) ~= "table" then return false end
        return islands[islandId] == true
    end

    local function isQuestVisible(questId)
        local info = getQuestInfo(questId)
        if not info then return false end
        if isQuestDone(questId) then return true end
        local activeId = getActiveQuest()
        if activeId == questId then return true end
        local gate = info.visibleWhenIslandUnlocked
        if gate then return isIslandUnlocked(gate) end
        return true
    end

    local function islandIdToDisplay(islandId)
        return (env.IslandDisplayNames and env.IslandDisplayNames[islandId]) or islandId
    end

    local function displayToIslandId(name)
        return (env.IslandPaths and env.IslandPaths[name]) or name
    end

    local function countFishFromIsland(islandId, rarity, minKg)
        local pdata = fetchPData()
        if not pdata or not pdata.Inventory or not pdata.Inventory.Fishes then return 0 end
        local Catalog = nil
        pcall(function() Catalog = require(ReplicatedStorage.Data.Catalog) end)
        if not Catalog then return 0 end
        local island = Catalog.Island.GetById(islandId)
        if not island or not island.fishes then return 0 end
        local ids = {}
        for _, f in ipairs(island.fishes) do ids[f.fishId] = true end
        local n = 0
        for _, entry in pairs(pdata.Inventory.Fishes) do
            if entry.fishId and ids[entry.fishId] then
                local meta = Catalog.Fish.GetById(entry.fishId)
                if meta and meta.rarity == rarity then
                    if not minKg or (tonumber(entry.weight) or 0) >= minKg then
                        n += 1
                    end
                end
            end
        end
        return n
    end

    local function countUnequippedBooks(bookId)
        local pdata = fetchPData()
        if not pdata then return 0 end
        local inv = pdata.Inventory and pdata.Inventory.Books or {}
        local have = tonumber(inv[bookId]) or 0
        local equipped = 0
        for _, rod in pairs(pdata.Rods or {}) do
            local slots = rod.BookSlots or {}
            for _, slot in pairs(slots) do
                if slot == bookId then equipped += 1 end
            end
        end
        return math.max(0, have - equipped)
    end

    local function evaluateQuestProgress(questId)
        local info = getQuestInfo(questId)
        if not info then return {} end
        local pdata = fetchPData()
        if not pdata then return {} end
        local activeId, progress = getActiveQuest()
        if activeId ~= questId then progress = {} end
        local p = progress or {}
        local rows = {}

        local function addCoinRow()
            local coin = tonumber(pdGet(pdata, "Coin")) or 0
            local need = tonumber(p.RequiredCoin) or 0
            if need > 0 then
                rows[#rows+1] = { label = "Coins", have = coin, need = need, done = coin >= need }
            end
        end

        if questId == "crimson_bead_rod" then
            local have = tonumber(p.CurrentFished) or 0
            local need = tonumber(p.RequiredFished) or 0
            rows[#rows+1] = { label = "Fish with Legacy Rod", have = have, need = need, done = have >= need }
            addCoinRow()
        elseif questId == "bamboo_rod" then
            local frags = 0
            pcall(function()
                local fn = require(ReplicatedStorage.Shared.getItemCount)
                if type(fn) == "function" then frags = fn(pdata, "bamboo_fragment") end
            end)
            local need = tonumber(p.RequiredBamboo) or 0
            rows[#rows+1] = { label = "Bamboo Fragments", have = frags, need = need, done = frags >= need }
            addCoinRow()
        elseif questId == "heaven_piercer_turtle_rod" then
            local have = countFishFromIsland("island_fossil", "Legendary")
            local need = tonumber(p.RequiredFish) or 5
            rows[#rows+1] = { label = "Legendary fish (Fossil)", have = have, need = need, done = have >= need }
            addCoinRow()
        elseif questId == "dread_fish_rod" then
            local have = countFishFromIsland("island_fossil", "Mythical")
            local need = tonumber(p.RequiredFish) or 0
            rows[#rows+1] = { label = "Mythical fish (Fossil)", have = have, need = need, done = have >= need }
            addCoinRow()
        elseif questId == "zen_staff_rod" then
            local have = tonumber(p.CurrentFish) or 0
            local need = tonumber(p.RequiredFish) or 1
            rows[#rows+1] = { label = "Legendary final blows (Fossil)", have = have, need = need, done = have >= need }
            addCoinRow()
        elseif questId == "taiji_hooking_art_v2" then
            local kills = tonumber(p.CurrentKills) or 0
            local need = tonumber(p.RequiredKills) or 100
            rows[#rows+1] = { label = "Final blows with Taiji", have = kills, need = need, done = kills >= need }
            local bookId = p.RequiredBookId or "taiji_hooking_art"
            local bHave = countUnequippedBooks(bookId)
            local bNeed = tonumber(p.RequiredBookCount) or 1
            rows[#rows+1] = { label = "Unequipped " .. bookId, have = bHave, need = bNeed, done = bHave >= bNeed }
            addCoinRow()
        elseif questId == "white_tiger" then
            local minKg = QuestConfig.WhiteTigerMinWeightKg or 1000
            local have = countFishFromIsland("island_desert", "Legendary", minKg)
            local need = tonumber(p.RequiredFish) or 3
            rows[#rows+1] = { label = ("Legendary >= %d kg (Desert)"):format(minKg),
                              have = have, need = need, done = have >= need }
        elseif questId == "phoenix" then
            local have = countFishFromIsland("island_snow", "Legendary")
            local need = tonumber(p.RequiredFish) or 3
            rows[#rows+1] = { label = "Legendary fish (Snow)", have = have, need = need, done = have >= need }
            local books = p.RequiredBooks or QuestConfig.PhoenixRequiredBooks
                or { one_hook_supreme = 1, taiji_hooking_art = 1, shatter_the_azure_heavens = 1 }
            for bookId, qty in pairs(books) do
                local bHave = countUnequippedBooks(bookId)
                rows[#rows+1] = {
                    label = "Unequipped " .. bookId,
                    have = bHave, need = tonumber(qty) or 1,
                    done = bHave >= (tonumber(qty) or 1),
                }
            end
        elseif questId == "azure_dragon" then
            local used = tonumber(p.CurrentUsedSkill) or 0
            local needUsed = tonumber(p.CatchWithSkill) or 100
            rows[#rows+1] = { label = "Final blows with One Hook Supreme",
                              have = used, need = needUsed, done = used >= needUsed }
            local have = countFishFromIsland("island_volcano", "Legendary")
            local need = tonumber(p.RequiredFish) or 3
            rows[#rows+1] = { label = "Legendary fish (Volcano)", have = have, need = need, done = have >= need }
        elseif questId == "supreme_king" then
            local used = tonumber(p.CurrentUsedSkill) or 0
            local needUsed = tonumber(p.CatchWithSkill) or 5
            rows[#rows+1] = { label = "Legendary final blows with Rod Gate 20%",
                              have = used, need = needUsed, done = used >= needUsed }
            local books = p.RequiredBooks or { rod_gate_20_percent = 1 }
            for bookId, qty in pairs(books) do
                local bHave = countUnequippedBooks(bookId)
                rows[#rows+1] = {
                    label = "Unequipped " .. bookId,
                    have = bHave, need = tonumber(qty) or 1,
                    done = bHave >= (tonumber(qty) or 1),
                }
            end
        elseif questId == "unlock_island_2" or questId == "unlock_island_3" then
            addCoinRow()
        elseif questId == "unlock_island_4" then
            local have = countFishFromIsland("island_desert", "Legendary")
            local need = tonumber(p.RequiredFish) or 1
            rows[#rows+1] = { label = "Legendary fish (Desert)", have = have, need = need, done = have >= need }
            addCoinRow()
        elseif questId == "unlock_island_5" then
            local need = p.RequiredFishes or {}
            local fishes = pdata.Inventory and pdata.Inventory.Fishes or {}
            for fishId, qty in pairs(need) do
                local have = 0
                for _, entry in pairs(fishes) do
                    if entry.fishId == fishId then have += 1 end
                end
                rows[#rows+1] = { label = "Fish " .. fishId, have = have, need = tonumber(qty) or 1,
                                  done = have >= (tonumber(qty) or 1) }
            end
            addCoinRow()
        elseif questId == "unlock_island_6" then
            local need = p.RequiredFishes or {}
            local weightReq = QuestConfig.UnlockIsland6MinWeightKg or {}
            local fishes = pdata.Inventory and pdata.Inventory.Fishes or {}
            for fishId, qty in pairs(need) do
                local minKg = weightReq[fishId] or 0
                local have = 0
                for _, entry in pairs(fishes) do
                    if entry.fishId == fishId and (tonumber(entry.weight) or 0) >= minKg then
                        have += 1
                    end
                end
                rows[#rows+1] = {
                    label = ("Fish %s (>=%d kg)"):format(fishId, minKg),
                    have = have, need = tonumber(qty) or 1,
                    done = have >= (tonumber(qty) or 1),
                }
            end
            addCoinRow()
        end
        return rows
    end

    local function isQuestReadyToComplete(questId)
        local rows = evaluateQuestProgress(questId)
        if #rows == 0 then return false end
        for _, r in ipairs(rows) do
            if not r.done then return false end
        end
        return true
    end

    local QUEST_ORDER = {
        "unlock_island_2", "unlock_island_3", "unlock_island_4",
        "unlock_island_5", "unlock_island_6",
        "crimson_bead_rod", "bamboo_rod",
        "heaven_piercer_turtle_rod", "dread_fish_rod", "zen_staff_rod",
        "white_tiger", "phoenix", "azure_dragon", "supreme_king",
        "taiji_hooking_art_v2",
    }

    local QUEST_PREREQ_ROD = {
        ["crimson_bead_rod"] = "legacy_rod",
        ["bamboo_rod"]       = "crimson_bead_rod",
    }

    local QUEST_REQUIRED_EQUIP = {
        ["azure_dragon"]         = { skill = "one_hook_supreme" },
        ["supreme_king"]         = { skill = "rod_gate_20_percent" },
        ["zen_staff_rod"]        = { skill = "taiji_hooking_art_v2" },
        ["taiji_hooking_art_v2"] = { skill = "taiji_hooking_art" },
        ["crimson_bead_rod"]     = { rod = "legacy_rod" },
    }

    local QUEST_FARM_ISLAND = {
        ["crimson_bead_rod"]          = "island_starter",
        ["bamboo_rod"]                = "island_jungle",
        ["heaven_piercer_turtle_rod"] = "island_fossil",
        ["dread_fish_rod"]            = "island_fossil",
        ["zen_staff_rod"]             = "island_fossil",
        ["white_tiger"]               = "island_desert",
        ["phoenix"]                   = "island_snow",
        ["azure_dragon"]              = "island_volcano",
        ["supreme_king"]              = "island_fossil",
        ["taiji_hooking_art_v2"]      = "island_starter",
        ["unlock_island_4"]           = "island_desert",
        ["unlock_island_5"]           = "island_snow",
        ["unlock_island_6"]           = "island_volcano",
    }

    local QUEST_FISH_FILTER = {
        ["white_tiger"]               = { rarities = {"Legendary"}, minWeight = 1000 },
        ["unlock_island_4"]           = { rarities = {"Legendary"} },
        ["unlock_island_5"]           = { rarities = {"Legendary"} },
        ["unlock_island_6"]           = { rarities = {"Legendary"} },
        ["heaven_piercer_turtle_rod"] = { rarities = {"Legendary"} },
        ["dread_fish_rod"]            = { rarities = {"Mythical"} },
        ["azure_dragon"]              = { rarities = {"Legendary"} },
        ["phoenix"]                   = { rarities = {"Legendary"} },
    }

    local QUEST_COIN_NEED = {
        ["unlock_island_2"]           = 40000,
        ["unlock_island_3"]           = 180000,
        ["unlock_island_4"]           = 900000,
        ["unlock_island_5"]           = 4000000,
        ["unlock_island_6"]           = 15000000,
        ["crimson_bead_rod"]          = 3000000,
        ["bamboo_rod"]                = 3600000,
        ["dread_fish_rod"]            = 10000000,
        ["heaven_piercer_turtle_rod"] = 5000000,
        ["zen_staff_rod"]             = 5000000,
        ["taiji_hooking_art_v2"]      = 1000000,
    }

    local function logAQ(msg)
        if not S.AutoQuestVerbose then return end
        print("[NNRP AQ] " .. tostring(msg))
    end

    local function hasRodInInv(rodId)
        local pdata = fetchPData()
        if not pdata or not pdata.Rods then return false end
        return pdata.Rods[rodId] ~= nil
    end

    local function pickNextQuest()
        local pdata = fetchPData()
        if not pdata or not pdata.Quest then return nil end
        local cur = pdata.Quest.Current
        if cur and cur.Id and cur.Id ~= "" then return cur.Id end
        local done = pdata.Quest.Done or {}
        for _, qid in ipairs(QUEST_ORDER) do
            if not done[qid] and not S.AutoQuestBlacklist[qid] then
                if isQuestVisible(qid) then return qid end
            end
        end
        return nil
    end

    local function equipRodById(rodId)
        local char = getChar and getChar()
        if not char then return false end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if not bp then return false end
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") then
                local n = tostring(tool.Name):lower()
                if n:find(rodId:lower(), 1, true) or n:find("rod", 1, true) then
                    tool.Parent = char
                    task.wait(0.3)
                    return true
                end
            end
        end
        return false
    end

    local function travelToIsland(islandIdOrName)
        if not islandIdOrName then return false end
        local islandId = displayToIslandId(islandIdOrName)
        local display  = islandIdToDisplay(islandId)
        logAQ(("Travel to %s (%s)"):format(display, islandId))

        if fastTravelToIsland then
            local ok, result = pcall(fastTravelToIsland, display)
            if ok and result == true then
                logAQ("FastTravel sent, waiting...")
                for _ = 1, 10 do
                    task.wait(0.5)
                    local root = getRoot and getRoot()
                    if root and getIslandForPosition then
                        local cur = getIslandForPosition(root.Position)
                        if cur == display then
                            logAQ("Arrived via FastTravel: " .. cur)
                            return true
                        end
                    end
                end
                logAQ("FastTravel timeout")
            else
                logAQ("FastTravel failed: " .. tostring(result))
            end
        end

        if env.findIslandCF and tweenTo then
            local cf = env.findIslandCF(display) or env.findIslandCF(islandId)
            if cf then
                setStatus("questauto", "Tweening to " .. display)
                logAQ("Tween to " .. display)
                local ok = tweenTo(cf, S.TweenSpeed)
                if ok then
                    logAQ("Tween OK: " .. display)
                    task.wait(0.5)
                    return true
                end
                logAQ("Tween FAILED")
            else
                logAQ("findIslandCF returned nil for " .. display)
            end
        end
        return false
    end

    local function getCastPosition(islandId)
        if not islandId then return nil end
        local pos = S.IslandCastPositions and S.IslandCastPositions[islandId]
        if not pos then return nil end
        if typeof(pos) ~= "Vector3" then return nil end
        if pos.Magnitude < 0.1 then return nil end
        return pos
    end

    local function tweenToCastSpot(islandId)
        local pos = getCastPosition(islandId)
        if not pos then
            logAQ("No cast position for " .. tostring(islandId))
            return true
        end
        local root = getRoot and getRoot()
        if not root then return false end
        local dist = (root.Position - pos).Magnitude
        local tol = S.IslandCastTolerance or 30
        if dist <= tol then
            logAQ(("Already at cast spot (dist=%.1f)"):format(dist))
            return true
        end
        setStatus("questauto", ("Tween to cast spot (%.0f studs)"):format(dist))
        logAQ(("Tween to cast spot | dist=%.1f | pos=%s"):format(dist, tostring(pos)))
        local cf = CFrame.new(pos)
        local ok = tweenTo(cf, S.TweenSpeed)
        if ok then
            logAQ("Arrived at cast spot")
            task.wait(0.5)
            return true
        end
        logAQ("Tween to cast spot FAILED")
        return false
    end

    local function enableFarming(on)
        S.AutoCast = on
        S.AutoClickFish = on
        S.AutoPullMinigame = on
        S.AutoUseSkills = on
        S.AutoEquipRod = on
        if on then
            S.AutoDismissPopup = true
            S.AutoPerfectCast = true
            if env.enablePerfectCast then env.enablePerfectCast(true) end
        end
    end

    local function buyRodById(rodId)
        if not S.AutoQuestBuyRod then return false end
        if hasRodInInv(rodId) then return true end
        logAQ("Buying rod: " .. rodId)
        S.SelectedRod = rodId
        if buyRodOnce then
            buyRodOnce()
            task.wait(2)
            return hasRodInInv(rodId)
        end
        return false
    end

    local function syncFilterUIToggles(autoLockOn, lockModeValue, rarityList)
        S._suppressFilterCallback = true

        local t = S._fishFilterAutoLockToggle
        if t then
            pcall(function()
                if type(t.Set) == "function" then t:Set(autoLockOn)
                elseif type(t.SetValue) == "function" then t:SetValue(autoLockOn) end
            end)
        end

        local d = S._fishFilterLockModeDropdown
        if d and lockModeValue then
            pcall(function()
                if type(d.Set) == "function" then d:Set(lockModeValue)
                elseif type(d.SetValue) == "function" then d:SetValue(lockModeValue) end
            end)
        end

        local r = S._fishFilterRarityDropdown
        if r and rarityList then
            pcall(function()
                if type(r.Set) == "function" then r:Set(rarityList)
                elseif type(r.SetValue) == "function" then r:SetValue(rarityList)
                elseif type(r.SetSelected) == "function" then r:SetSelected(rarityList)
                elseif type(r.Refresh) == "function" then r:Refresh(rarityList)
                elseif type(r.Select) == "function" then
                    for _, v in ipairs(rarityList) do r:Select(v) end
                end
            end)
        end

        task.wait(0.1)
        S._suppressFilterCallback = false
    end

    local function applyQuestFilter(questId)
        if not S.AutoSetFilterPerQuest then
            if S._autoQuestFilterFor then
                S.FishFilterRarities = {}
                S.FishFilterRarityInput = ""
                S.FishFilterName = ""
                S.FishFilterMinWeight = 0
                S.FishFilterMaxWeight = 100000
                S.FishFilterHugeOnly = false
                S.FishFilterLockMode = "All"
                S.AutoLockFiltered = false
                S._autoQuestFilterFor = nil
                syncFilterUIToggles(false, "All", {})
            end
            return
        end

        if S._autoQuestFilterFor == questId then return end

        local cfg = QUEST_FISH_FILTER[questId]
        if cfg then
            S.FishFilterRarities = cfg.rarities or {}
            S.FishFilterRarityInput = ""
            S.FishFilterName = cfg.name or ""
            S.FishFilterMinWeight = tonumber(cfg.minWeight) or 0
            S.FishFilterMaxWeight = 100000
            S.FishFilterHugeOnly = false
            S.FishFilterLockMode = "All"
            S.AutoLockFiltered = true
            syncFilterUIToggles(true, "All", cfg.rarities or {})
            logAQ(("[Filter] ON %s | rarity=%s | minKg=%d"):format(
                questId, table.concat(cfg.rarities or {}, ","), tonumber(cfg.minWeight) or 0))
        else
            S.FishFilterRarities = {}
            S.FishFilterRarityInput = ""
            S.FishFilterName = ""
            S.FishFilterMinWeight = 0
            S.FishFilterMaxWeight = 100000
            S.FishFilterHugeOnly = false
            S.FishFilterLockMode = "All"
            S.AutoLockFiltered = false
            syncFilterUIToggles(false, "All", {})
            logAQ(("[Filter] OFF for %s"):format(questId))
        end
        S._autoQuestFilterFor = questId
    end

    local function clearQuestFilter()
        S.FishFilterRarities = {}
        S.FishFilterRarityInput = ""
        S.FishFilterName = ""
        S.FishFilterMinWeight = 0
        S.FishFilterMaxWeight = 100000
        S.FishFilterHugeOnly = false
        S.FishFilterLockMode = "All"
        S.AutoLockFiltered = false
        S._autoQuestFilterFor = nil
        syncFilterUIToggles(false, "All", {})
    end

    local function applyQuestCoinMode(questId)
        if not S.AutoCoinFarmPerQuest then
            if S._autoQuestSellFor then
                S.AutoSellWhenFull = false
                S._autoQuestSellFor = nil
            end
            return
        end

        if S._autoQuestSellFor == questId then return end

        local need = QUEST_COIN_NEED[questId]
        local haveFromProgress = 0
        local pdata = fetchPData()
        if pdata then haveFromProgress = tonumber(pdGet(pdata, "Coin")) or 0 end

        if need and need > 0 and haveFromProgress < need then
            S.AutoSellWhenFull = true
            logAQ(("[CoinMode] ON %s | %d/%d"):format(questId, math.floor(haveFromProgress), need))
        else
            S.AutoSellWhenFull = false
            logAQ(("[CoinMode] OFF for %s"):format(questId))
        end
        S._autoQuestSellFor = questId
    end

    local function clearQuestCoinMode()
        S.AutoSellWhenFull = false
        S._autoQuestSellFor = nil
    end

    local function runAutoQuestStep()
        if not S.AutoQuestEnabled then return end

        local target = pickNextQuest()
        if not target then
            setStatus("questauto", "所有任务完成！")
            S.AutoQuestEnabled = false
            enableFarming(false)
            clearQuestFilter()
            clearQuestCoinMode()
            return
        end

        S.AutoQuestCurrentTarget = target
        local qInfo = getQuestInfo(target)
        logAQ("Target: " .. target .. " (" .. (qInfo and qInfo.name or "?") .. ")")

        local activeId = getActiveQuest()
        if not activeId or activeId ~= target then
            local ctrl = getQuestController()
            if not ctrl then
                setStatus("questauto", "Quest service not ready")
                return
            end
            local ok, err = ctrl:Accept(target)
            if ok then
                setStatus("questauto", "Accepted: " .. target)
                logAQ("Accepted " .. target)
                task.wait(1)
            else
                setStatus("questauto", ("Accept fail: %s"):format(tostring(err)))
                logAQ("Accept failed: " .. tostring(err))
                if tostring(err):lower():find("prereq") then
                    S.AutoQuestBlacklist[target] = true
                end
                return
            end
            return
        end

        applyQuestFilter(target)
        applyQuestCoinMode(target)

        local reqRod = QUEST_PREREQ_ROD[target]
        if reqRod then
            if not hasRodInInv(reqRod) then
                if S.AutoQuestBuyRod then
                    setStatus("questauto", "Need to buy rod: " .. reqRod)
                    buyRodById(reqRod)
                    return
                else
                    setStatus("questauto", "Need to own rod: " .. reqRod .. " (enable Auto Buy)")
                    S.AutoQuestEnabled = false
                    return
                end
            else
                equipRodById(reqRod)
            end
        end

        if isQuestReadyToComplete(target) then
            local ctrl = getQuestController()
            local ok, err = ctrl:Complete(target)
            if ok then
                setStatus("questauto", "Completed: " .. target)
                logAQ("Completed " .. target)
                S.AutoQuestLastCompleteAt = os.time()
                enableFarming(false)
                clearQuestFilter()
                clearQuestCoinMode()
                task.wait(2)
            else
                setStatus("questauto", "Complete fail: " .. tostring(err))
            end
            return
        end

        if not S.AutoQuestFarm then
            setStatus("questauto", "Target ready, waiting for farm (AutoQuestFarm OFF)")
            return
        end

        local reqEquip = QUEST_REQUIRED_EQUIP[target]
        if reqEquip and reqEquip.rod then
            equipRodById(reqEquip.rod)
        end

        local farmIslandId = QUEST_FARM_ISLAND[target]
        if farmIslandId then
            local farmDisplay = islandIdToDisplay(farmIslandId)
            local root = getRoot and getRoot()
            local currentIsland = root and getIslandForPosition
                and getIslandForPosition(root.Position) or "Unknown"

            logAQ(("Check island: current=%s | target=%s (%s)"):format(
                tostring(currentIsland), tostring(farmDisplay), tostring(farmIslandId)))

            if currentIsland ~= farmDisplay then
                setStatus("questauto", ("Travel to %s (currently at %s)"):format(
                    farmDisplay, currentIsland))
                local ok = travelToIsland(farmIslandId)
                if not ok then
                    setStatus("questauto", ("Cannot travel to %s"):format(farmDisplay))
                    logAQ("Travel failed, retry next step")
                end
                return
            end

            local castPos = getCastPosition(farmIslandId)
            if castPos then
                local atSpot = false
                if root then
                    local dist = (root.Position - castPos).Magnitude
                    atSpot = dist <= (S.IslandCastTolerance or 30)
                end
                if not atSpot then
                    local ok = tweenToCastSpot(farmIslandId)
                    if not ok then
                        setStatus("questauto", "Tween to cast spot failed, retry")
                        return
                    end
                end
            end
        end

        enableFarming(true)
        local rows = evaluateQuestProgress(target)
        local missing = {}
        for _, r in ipairs(rows) do
            if not r.done then
                missing[#missing+1] = ("%s %s/%s"):format(r.label, tostring(r.have), tostring(r.need))
            end
        end
        local extra = ""
        if S._autoQuestFilterFor == target and S.AutoLockFiltered then
            extra = extra .. " [Filter ON]"
        end
        if S._autoQuestSellFor == target and S.AutoSellWhenFull then
            extra = extra .. " [Sell ON]"
        end
        if S.AutoEquipRod then extra = extra .. " [Rod Auto]" end
        if S.AutoPerfectCast then extra = extra .. " [Perfect]" end
        setStatus("questauto", ("Farming %s%s | Need: %s"):format(
            target, extra, table.concat(missing, " | ")))
    end

    local function patchContainer(c)
        if not c then return c end
        if env.patchControlContainer then return env.patchControlContainer(c) end
        if c.AddParagraph and not c.Paragraph then function c:Paragraph(o) return self:AddParagraph(o) end end
        if c.AddButton    and not c.Button    then function c:Button(o)    return self:AddButton(o) end end
        if c.AddToggle    and not c.Toggle    then function c:Toggle(o)    return self:AddToggle(o.Title or o.Name or "Toggle", o) end end
        if c.AddDropdown  and not c.Dropdown  then function c:Dropdown(o)
            o = o or {}
            o.Text = o.Text or o.Title or o.Name or "Dropdown"
            o.Name = o.Name or o.Title or o.Text
            if type(o.Values) == "table" and #o.Values > 6 then
                o.Searchable = true; o.Search = true; o.AllowSearch = true
                o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
            end
            return self:AddDropdown(o.Title or o.Name or "Dropdown", o)
        end end
        if c.AddSlider    and not c.Slider    then function c:Slider(o)    return self:AddSlider(o.Title or o.Name or "Slider", o) end end
        if c.AddInput     and not c.Input     then function c:Input(o)     return self:AddInput(o.Title or o.Name or "Input", o) end end
        if c.Dropdown and not c.__NNVNDropdownPatched then
            local rawDropdown = c.Dropdown
            c.__NNVNDropdownPatched = true
            function c:Dropdown(o)
                o = o or {}
                o.Text = o.Text or o.Title or o.Name or "Dropdown"
                o.Name = o.Name or o.Title or o.Text
                if type(o.Values) == "table" and #o.Values > 6 then
                    o.Searchable = true; o.Search = true; o.AllowSearch = true
                    o.MaxVisibleDropdownItems = o.MaxVisibleDropdownItems or 8
                end
                return rawDropdown(self, o)
            end
        end
        return c
    end

    local function section(tab, opts)
        opts = opts or {}
        opts.Open = true; opts.Opened = true; opts.DefaultOpen = true; opts.Collapsed = false
        if tab.Section then return patchContainer(tab:Section(opts)) end
        if tab.AddSection then return patchContainer(tab:AddSection(opts)) end
        return patchContainer(tab)
    end

    local QuestTab = Window:Tab({ Title = "自动任务", Icon = "scroll" })

    -- SECTION: Auto Quest Pro
    local AQSec = section(QuestTab, { Title = "自动任务 Pro", Icon = "zap" })
    Paragraphs.questauto = AQSec:Paragraph({ Title = "状态", Desc = "空闲" })

    AQSec:Toggle({
        Title = "自动任务（完整链）",
        Icon = "play",
        Default = false,
        Callback = function(v)
            S.AutoQuestEnabled = v
            if v then
                S.AutoQuestBlacklist = {}
                S._autoQuestFilterFor = nil
                S._autoQuestSellFor = nil
                setStatus("questauto", "自动任务开始")
                logAQ("=== Auto Quest ENABLED ===")
            else
                enableFarming(false)
                clearQuestFilter()
                clearQuestCoinMode()
                setStatus("questauto", "自动任务停止")
            end
        end,
    })

    AQSec:Toggle({
        Title = "条件不足时自动钓鱼升级",
        Icon = "wheat",
        Default = true,
        Callback = function(v) S.AutoQuestFarm = v end,
    })

    AQSec:Toggle({
        Title = "自动购买所需鱼竿",
        Icon = "shopping-cart",
        Default = true,
        Callback = function(v) S.AutoQuestBuyRod = v end,
    })

    AQSec:Toggle({
        Title = "按任务自动设置鱼类过滤",
        Icon = "funnel",
        Default = true,
        Callback = function(v)
            S.AutoSetFilterPerQuest = v
            if not v then clearQuestFilter() end
        end,
    })

    AQSec:Toggle({
        Title = "背包满时出售（金币任务用）",
        Icon = "coins",
        Default = true,
        Callback = function(v)
            S.AutoCoinFarmPerQuest = v
            if not v then clearQuestCoinMode() end
        end,
    })

    AQSec:Toggle({
        Title = "详细日志 (F9)",
        Icon = "bug",
        Default = true,
        Callback = function(v) S.AutoQuestVerbose = v end,
    })

    AQSec:Slider({
        Title = "步进延迟 (秒)",
        Icon = "timer",
        Value = { Min = 2, Max = 15, Default = 4 },
        Callback = function(v) S.AutoQuestDelay = tonumber(v) or 4 end,
    })

    AQSec:Button({
        Title = "跳过当前任务",
        Icon = "skip-forward",
        Callback = function()
            local active = getActiveQuest()
            if not active then
                setStatus("questauto", "No active quest to skip")
                return
            end
            local ctrl = getQuestController()
            if ctrl then pcall(function() ctrl:Cancel(active) end); task.wait(0.5) end
            S.AutoQuestBlacklist[active] = true
            setStatus("questauto", "Skipped: " .. active)
            logAQ("Blacklisted: " .. active)
        end,
    })

    AQSec:Button({
        Title = "显示当前目标",
        Icon = "info",
        Callback = function()
            local target = S.AutoQuestCurrentTarget or pickNextQuest() or "None"
            local info = getQuestInfo(target)
            local rows = evaluateQuestProgress(target)
            local lines = { "Target: " .. target, "Name: " .. (info and info.name or "?") }
            for _, r in ipairs(rows) do
                lines[#lines+1] = ("  %s %s: %s/%s"):format(
                    r.done and "[OK]" or "[..]", r.label, tostring(r.have), tostring(r.need))
            end
            local cfg = QUEST_FISH_FILTER[target]
            if cfg then
                lines[#lines+1] = ("Filter: rarity=%s minKg=%d"):format(
                    table.concat(cfg.rarities or {}, ","), tonumber(cfg.minWeight) or 0)
            end
            local coinNeed = QUEST_COIN_NEED[target]
            if coinNeed then
                lines[#lines+1] = ("Coin need: %d"):format(coinNeed)
            end
            print(table.concat(lines, "\n"))
            setStatus("questauto", ("Target: %s\n%s"):format(target, table.concat(lines, "\n")))
        end,
    })

    AQSec:Button({
        Title = "重置黑名单",
        Icon = "refresh-cw",
        Callback = function()
            S.AutoQuestBlacklist = {}
            setStatus("questauto", "Blacklist cleared")
        end,
    })

    AQSec:Button({
        Title = "测试 1 步（调试）",
        Icon = "play-circle",
        Callback = function()
            logAQ("=== Manual test step ===")
            local old = S.AutoQuestEnabled
            S.AutoQuestEnabled = true
            pcall(runAutoQuestStep)
            S.AutoQuestEnabled = old
        end,
    })

    AQSec:Button({
        Title = "测试传送到挂机岛屿",
        Icon = "plane",
        Callback = function()
            local target = S.AutoQuestCurrentTarget or pickNextQuest()
            if not target then
                setStatus("questauto", "No target")
                return
            end
            local farmIslandId = QUEST_FARM_ISLAND[target]
            if not farmIslandId then
                setStatus("questauto", ("Quest %s has no farm island"):format(target))
                return
            end
            local display = islandIdToDisplay(farmIslandId)
            setStatus("questauto", ("Manual travel to %s"):format(display))
            travelToIsland(farmIslandId)
        end,
    })

    AQSec:Button({
        Title = "测试应用过滤",
        Icon = "funnel",
        Callback = function()
            local target = S.AutoQuestCurrentTarget or pickNextQuest()
            if not target then return end
            applyQuestFilter(target)
            notify("Filter", ("Applied for %s: %s"):format(target,
                table.concat(S.FishFilterRarities or {}, ",")))
        end,
    })

    AQSec:Button({
        Title = "清除过滤",
        Icon = "trash-2",
        Callback = function()
            clearQuestFilter()
            notify("Filter", "已清除")
        end,
    })

    -- SECTION: Active Quest
    local ActiveSec = section(QuestTab, { Title = "当前任务", Icon = "circle-play" })
    Paragraphs.questactive = ActiveSec:Paragraph({ Title = "当前", Desc = "无活跃任务" })
    Paragraphs.questprog   = ActiveSec:Paragraph({ Title = "进度", Desc = "-" })

    local function refreshActivePanel()
        local activeId = getActiveQuest()
        if not activeId then
            setStatus("questactive", "无活跃任务")
            setStatus("questprog", "-")
            return
        end
        local info = getQuestInfo(activeId)
        local name = info and info.name or activeId
        local qtype = info and info.questType or "?"
        setStatus("questactive", ("%s\nID: %s | Type: %s"):format(name, activeId, qtype))

        local rows = evaluateQuestProgress(activeId)
        if #rows == 0 then
            setStatus("questprog", "（无进度数据）")
            return
        end
        local lines = {}
        for _, r in ipairs(rows) do
            lines[#lines+1] = ("%s %s: %s/%s"):format(
                r.done and "[OK]" or "[..]", r.label,
                tostring(r.have), tostring(r.need))
        end
        setStatus("questprog", table.concat(lines, "\n"))
    end

    ActiveSec:Button({ Title = "刷新当前任务", Icon = "refresh-cw",
        Callback = refreshActivePanel })

    ActiveSec:Button({ Title = "完成当前任务", Icon = "circle-check",
        Callback = function()
            local ctrl = getQuestController()
            local activeId = getActiveQuest()
            if not ctrl then notify("Quest", "Quest service not ready"); return end
            if not activeId then notify("Quest", "无活跃任务"); return end
            if not isQuestReadyToComplete(activeId) then
                notify("Quest", "Requirements not met yet")
                return
            end
            local ok, err = ctrl:Complete(activeId)
            setStatus("questactive", ok and ("Completed: "..activeId)
                or ("Failed: "..tostring(err)))
            task.wait(0.5)
            refreshActivePanel()
        end })

    ActiveSec:Button({ Title = "放弃当前任务", Icon = "circle-x",
        Callback = function()
            local ctrl = getQuestController()
            local activeId = getActiveQuest()
            if not ctrl or not activeId then return end
            local ok, err = ctrl:Cancel(activeId)
            notify("Quest", ok and ("Abandoned: "..activeId)
                or ("Failed: "..tostring(err)))
            task.wait(0.5)
            refreshActivePanel()
        end })

    task.spawn(function()
        while task.wait(2) do pcall(refreshActivePanel) end
    end)

    -- SECTION: Quest Navigator
    local NavSec = section(QuestTab, { Title = "任务导航", Icon = "map-pin" })
    Paragraphs.questnav = NavSec:Paragraph({
        Title = "选中任务",
        Desc  = "Not selected - use Prev/Next",
    })

    S._questIndex = S._questIndex or 1
    if not S.SelectedQuest or S.SelectedQuest == "" then
        S.SelectedQuest = getQuestIds()[1] or ""
    end

    local function refreshNavStatus()
        local qid = S.SelectedQuest
        if not qid or qid == "" then
            setStatus("questnav", "No quest selected")
            return
        end
        local info = getQuestInfo(qid)
        local ids  = getQuestIds()
        if info then
            local status = isQuestDone(qid) and "DONE"
                or (isQuestVisible(qid) and "Visible" or "Locked")
            setStatus("questnav",
                ("[%d/%d] %s\nID: %s | Type: %s\nStatus: %s"):format(
                    S._questIndex or 1, #ids,
                    info.name or "?",
                    qid,
                    info.questType or "?",
                    status))
        else
            setStatus("questnav", "Quest not found: "..qid)
        end
    end

    local function stepQuest(delta)
        local ids = getQuestIds()
        if #ids == 0 then return end
        S._questIndex = math.clamp((S._questIndex or 1) + delta, 1, #ids)
        S.SelectedQuest = ids[S._questIndex] or ""
        task.defer(function() pcall(refreshNavStatus) end)
    end

    NavSec:Button({ Title = "上一个 (-1)", Icon = "chevron-left",
        Callback = function() stepQuest(-1) end })
    NavSec:Button({ Title = "下一个 (+1)", Icon = "chevron-right",
        Callback = function() stepQuest(1) end })
    NavSec:Button({ Title = "跳跃 -5", Icon = "chevrons-left",
        Callback = function() stepQuest(-5) end })
    NavSec:Button({ Title = "跳跃 +5", Icon = "chevrons-right",
        Callback = function() stepQuest(5) end })

    NavSec:Button({ Title = "显示信息", Icon = "info",
        Callback = function()
            local qid = S.SelectedQuest
            if not qid or qid == "" then return end
            local info = getQuestInfo(qid)
            if not info then return end
            local lines = { "=== " .. (info.name or qid) .. " ===" }
            lines[#lines+1] = "Type: " .. (info.questType or "?")
            lines[#lines+1] = ""
            for _, l in ipairs(info.description or {}) do
                lines[#lines+1] = l:gsub("<[^>]+>", "")
            end
            setStatus("questnav", table.concat(lines, "\n"))
        end })

    NavSec:Button({ Title = "检查需求", Icon = "list-checks",
        Callback = function()
            local qid = S.SelectedQuest
            if not qid or qid == "" then return end
            local rows = evaluateQuestProgress(qid)
            if #rows == 0 then
                setStatus("questnav", "No progress data")
                return
            end
            local lines = {}
            for _, r in ipairs(rows) do
                lines[#lines+1] = ("[%s] %s: %s/%s"):format(
                    r.done and "成功" or "X", r.label,
                    tostring(r.have), tostring(r.need))
            end
            setStatus("questnav", table.concat(lines, "\n"))
        end })

    NavSec:Button({ Title = "接受选中任务", Icon = "check",
        Callback = function()
            local qid = S.SelectedQuest
            if not qid or qid == "" then return end
            local ctrl = getQuestController()
            if ctrl then
                local ok, err = ctrl:Accept(qid)
                setStatus("questnav", ok and ("Accepted: "..qid)
                    or ("Failed: "..tostring(err)))
            else
                setStatus("questnav", "Quest service not ready")
            end
            task.wait(0.5)
            task.defer(function() pcall(refreshNavStatus) end)
        end })

    task.defer(function() pcall(refreshNavStatus) end)

    -- SECTION: Goal Tracker
    local GoalSec = section(QuestTab, { Title = "目标追踪", Icon = "target" })
    Paragraphs.questgoal = GoalSec:Paragraph({ Title = "目标", Desc = "Press Calculate" })

    local UNLOCK_ORDER = {
        { islandId = "island_jungle",  display = "Jungle Island",  cost = 40000    },
        { islandId = "island_desert",  display = "Desert Island",  cost = 180000   },
        { islandId = "island_snow",    display = "Snow Island",    cost = 900000   },
        { islandId = "island_volcano", display = "Volcano Island", cost = 4000000  },
        { islandId = "island_fossil",  display = "Fossil Island",  cost = 15000000 },
    }

    GoalSec:Button({ Title = "计算所有解锁的金币需求", Icon = "calculator",
        Callback = function()
            local total = 0
            local lines = { "=== Unlock Goal ===" }
            for _, u in ipairs(UNLOCK_ORDER) do
                if isIslandUnlocked(u.islandId) then
                    lines[#lines+1] = ("[OK] %s"):format(u.display)
                else
                    total += u.cost
                    lines[#lines+1] = ("[..] %s - need %s"):format(u.display, tostring(u.cost))
                end
            end
            local coin = getCoin()
            lines[#lines+1] = ""
            lines[#lines+1] = ("Current: %s | Remaining: %s"):format(
                tostring(math.floor(coin)), tostring(total))
            setStatus("questgoal", table.concat(lines, "\n"))
        end })

    GoalSec:Button({ Title = "显示重量需求", Icon = "weight",
        Callback = function()
            local lines = { "=== Weight Requirements ===" }
            lines[#lines+1] = ("White Tiger: >= %d kg"):format(
                QuestConfig.WhiteTigerMinWeightKg or 1000)
            for fishId, kg in pairs(QuestConfig.UnlockIsland6MinWeightKg or {}) do
                lines[#lines+1] = ("  %s >= %d kg"):format(fishId, kg)
            end
            setStatus("questgoal", table.concat(lines, "\n"))
        end })

    GoalSec:Button({ Title = "任务类型汇总", Icon = "list",
        Callback = function()
            local byType = {}
            for id, info in pairs(QuestConfig.Data) do
                local t = info.questType or "?"
                byType[t] = byType[t] or { total = 0, done = 0 }
                byType[t].total += 1
                if isQuestDone(id) then byType[t].done += 1 end
            end
            local lines = { "=== Quest Summary ===" }
            for _, t in ipairs(QuestConfig.QuestTypes or {}) do
                local s = byType[t]
                if s then
                    lines[#lines+1] = ("%-16s %d/%d done"):format(t, s.done, s.total)
                end
            end
            setStatus("questgoal", table.concat(lines, "\n"))
        end })

    -- SECTION: Fish Watcher
    local WatcherSec = section(QuestTab, { Title = "鱼类监控", Icon = "fish" })
    Paragraphs.fishwatcher = WatcherSec:Paragraph({
        Title = "当前鱼",
        Desc = "Idle - watcher off",
    })

    WatcherSec:Toggle({
        Title = "抛竿时显示鱼信息",
        Icon = "eye",
        Default = false,
        Callback = function(v)
            S.FishWatcherEnabled = v
            S._lastWatcherFishKey = nil
            if v then
                setStatus("fishwatcher", "Watching...")
            else
                setStatus("fishwatcher", "Watcher off")
            end
        end,
    })

    WatcherSec:Toggle({
        Title = "空闲时也显示信息",
        Icon = "info",
        Default = true,
        Callback = function(v) S.FishWatcherShowOnIdle = v end,
    })

    WatcherSec:Slider({
        Title = "轮询间隔 (秒)",
        Icon = "timer",
        Value = { Min = 0.1, Max = 2, Default = 0.4 },
        Callback = function(v) S.FishWatcherPollRate = tonumber(v) or 0.4 end,
    })

    WatcherSec:Button({
        Title = "立即查看当前鱼",
        Icon = "search",
        Callback = function()
            local fish = env.getCurrentFish and env.getCurrentFish()
            if not fish then
                notify("鱼类监控", "No fish on hook")
                setStatus("fishwatcher", "No fish on hook")
                return
            end
            local msg = ("%s [%s]\nHP: %d/%d | State: %s"):format(
                fish.name, fish.rarity, fish.hp or 0, fish.maxHp or 0, tostring(fish.state))
            notify("鱼类监控", msg)
            setStatus("fishwatcher", msg)
        end,
    })

    WatcherSec:Button({
        Title = "测试通知",
        Icon = "bell",
        Callback = function()
            notify("Fish Watcher Test", "Legendary Dragonfish [Legendary]\nHP: 500/500 | Filter: MATCH")
        end,
    })

    local function buildFishWatcherMessage(fish)
        local lines = {}
        lines[#lines+1] = ("%s [%s]"):format(
            tostring(fish.name or fish.id or "?"),
            tostring(fish.rarity or "?"))

        local hp = tonumber(fish.hp) or 0
        local maxHp = tonumber(fish.maxHp) or 0
        local hpPct = maxHp > 0 and math.floor((hp / maxHp) * 100) or 0
        lines[#lines+1] = ("HP: %d/%d (%d%%)"):format(hp, maxHp, hpPct)

        lines[#lines+1] = ("State: %s"):format(tostring(fish.state or "?"))

        local filterStatus = "No filter"
        local cat = env.getCatalog and env.getCatalog()
        if cat and cat.Fish and env.matchFilter then
            local ok, meta = pcall(function() return cat.Fish.GetById(fish.id) end)
            if ok and meta then
                local fakeEntry = {
                    fishId = fish.id,
                    weight = 0,
                    isHuge = false,
                    locked = false,
                }
                local ok2, matched = pcall(env.matchFilter, fakeEntry, meta)
                if ok2 then
                    filterStatus = matched and "MATCH" or "NO MATCH"
                end
            end
        end
        lines[#lines+1] = ("Filter: %s"):format(filterStatus)

        if S.FishFilterRarities and #S.FishFilterRarities > 0 then
            lines[#lines+1] = ("Filter rarity: %s"):format(
                table.concat(S.FishFilterRarities, ", "))
        end

        return table.concat(lines, "\n")
    end

    local _lastWatcherState = nil
    task.spawn(function()
        while true do
            task.wait(S.FishWatcherPollRate or 0.4)
            if S.FishWatcherEnabled then
                local fish = env.getCurrentFish and env.getCurrentFish()
                if fish then
                    local key = tostring(fish.id)
                        .. "|" .. tostring(fish.state)
                        .. "|" .. tostring(fish.hp)
                    if _lastWatcherState ~= key then
                        _lastWatcherState = key
                        local msg = buildFishWatcherMessage(fish)
                        notify("鱼类监控", msg)
                        setStatus("fishwatcher", msg)
                    end
                else
                    if _lastWatcherState ~= nil then
                        _lastWatcherState = nil
                        if S.FishWatcherShowOnIdle then
                            setStatus("fishwatcher", "Idle - waiting for fish")
                        end
                    end
                end
            end
        end
    end)

    -- SECTION: Cast Positions
    local CastPosSec = section(QuestTab, { Title = "抛竿位置", Icon = "map" })
    Paragraphs.castpos = CastPosSec:Paragraph({
        Title = "抛竿点位",
        Desc = "Add position per island for Auto Quest",
    })

    CastPosSec:Button({
        Title = "将当前位置设为当前岛屿的抛竿点",
        Icon = "save",
        Callback = function()
            local root = getRoot and getRoot()
            if not root then
                notify("Cast Pos", "No character")
                return
            end
            local currentDisplay = getIslandForPosition and getIslandForPosition(root.Position) or "Unknown"
            local islandId = displayToIslandId(currentDisplay)
            if not islandId or islandId == "Unknown" then
                notify("Cast Pos", "Cannot detect island")
                return
            end
            S.IslandCastPositions = S.IslandCastPositions or {}
            S.IslandCastPositions[islandId] = root.Position
            notify("Cast Pos", ("Set %s → %.1f, %.1f, %.1f"):format(
                currentDisplay, root.Position.X, root.Position.Y, root.Position.Z))
            logAQ(("Cast position set for %s: %s"):format(islandId, tostring(root.Position)))
        end,
    })

    CastPosSec:Button({
        Title = "清除所有抛竿位置",
        Icon = "trash-2",
        Callback = function()
            S.IslandCastPositions = {
                island_starter  = nil,
                island_jungle   = nil,
                island_desert   = nil,
                island_snow     = nil,
                island_volcano  = nil,
                island_fossil   = nil,
            }
            notify("Cast Pos", "All cleared")
        end,
    })

    CastPosSec:Button({
        Title = "显示抛竿位置",
        Icon = "list",
        Callback = function()
            local lines = { "=== Cast Positions ===" }
            for id, pos in pairs(S.IslandCastPositions or {}) do
                local display = islandIdToDisplay(id)
                if pos and typeof(pos) == "Vector3" then
                    lines[#lines+1] = ("[%s] %.1f, %.1f, %.1f"):format(
                        display, pos.X, pos.Y, pos.Z)
                else
                    lines[#lines+1] = ("[%s] (not set)"):format(display)
                end
            end
            print(table.concat(lines, "\n"))
            setStatus("castpos", table.concat(lines, "\n"))
        end,
    })

    CastPosSec:Button({
        Title = "测试传送到抛竿点（当前目标）",
        Icon = "navigation",
        Callback = function()
            local target = S.AutoQuestCurrentTarget or pickNextQuest()
            if not target then
                notify("Cast Pos", "No target")
                return
            end
            local islandId = QUEST_FARM_ISLAND[target]
            if not islandId then
                notify("Cast Pos", "No farm island for target")
                return
            end
            local ok = tweenToCastSpot(islandId)
            notify("Cast Pos", ok and "Tween OK" or "移动失败")
        end,
    })

    CastPosSec:Input({
        Title = "容差 (格)",
        Icon = "hash",
        Value = "30",
        Callback = function(v)
            S.IslandCastTolerance = tonumber(v) or 30
        end,
    })

    -- SECTION: Debug
    local DbgSec = section(QuestTab, { Title = "调试", Icon = "bug" })

    DbgSec:Button({ Title = "导出所有任务 (F9)", Icon = "file-text",
        Callback = function()
            local lines = {
                "=== Quest Config Dump ===",
                ("Total: %d"):format(#getQuestIds()),
                ("Types: %s"):format(table.concat(QuestConfig.QuestTypes or {}, ", ")),
                "",
            }
            for _, id in ipairs(getQuestIds()) do
                local info = getQuestInfo(id)
                lines[#lines+1] = ("[%s] %s"):format(id, info.name or "?")
                lines[#lines+1] = ("  Type: %s | SortOrder: %s"):format(
                    info.questType or "?", tostring(info.sortOrder or "?"))
                lines[#lines+1] = ("  Gate: %s%s"):format(
                    info.visibleWhenIslandUnlocked or "any",
                    info.repeatable and " | repeatable" or "")
                lines[#lines+1] = ""
            end
            print(table.concat(lines, "\n"))
            notify("Quest Dump", ("%d quests - see F9"):format(#getQuestIds()))
        end })

    DbgSec:Button({ Title = "导出玩家任务数据 (F9)", Icon = "database",
        Callback = function()
            local pdata = fetchPData()
            if not pdata or not pdata.Quest then
                notify("Quest", "PlayerData.Quest not found")
                return
            end
            local lines = { "=== PlayerData.Quest ===" }
            local cur = pdata.Quest.Current
            lines[#lines+1] = "Current: " .. tostring(cur and cur.Id or "none")
            if cur and cur.Progress then
                for k, v in pairs(cur.Progress) do
                    lines[#lines+1] = ("  Progress.%s = %s"):format(
                        tostring(k), tostring(type(v) == "table" and "TABLE" or v))
                end
            end
            lines[#lines+1] = ""
            lines[#lines+1] = "Done:"
            for id, done in pairs(pdata.Quest.Done or {}) do
                if done then lines[#lines+1] = "  [OK] " .. tostring(id) end
            end
            print(table.concat(lines, "\n"))
            notify("Quest", "See F9")
        end })

    DbgSec:Button({ Title = "导出已解锁岛屿 (F9)", Icon = "map",
        Callback = function()
            local pdata = fetchPData()
            local lines = { "=== UnlockedIslands ===" }
            for id, unlocked in pairs(pdata and pdata.UnlockedIslands or {}) do
                lines[#lines+1] = ("  %s = %s"):format(tostring(id), tostring(unlocked))
            end
            print(table.concat(lines, "\n"))
            notify("Islands", "See F9")
        end })

    DbgSec:Button({ Title = "导出过滤状态", Icon = "funnel",
        Callback = function()
            local lines = {
                "=== Fish Filter State ===",
                ("Rarities: %s"):format(table.concat(S.FishFilterRarities or {}, ", ")),
                ("Name: %s"):format(S.FishFilterName or ""),
                ("MinWeight: %s"):format(tostring(S.FishFilterMinWeight)),
                ("MaxWeight: %s"):format(tostring(S.FishFilterMaxWeight)),
                ("AutoLockFiltered: %s"):format(tostring(S.AutoLockFiltered)),
                ("AutoSellWhenFull: %s"):format(tostring(S.AutoSellWhenFull)),
                ("AutoEquipRod: %s"):format(tostring(S.AutoEquipRod)),
                ("AutoPerfectCast: %s"):format(tostring(S.AutoPerfectCast)),
                ("_autoQuestFilterFor: %s"):format(tostring(S._autoQuestFilterFor)),
                ("_autoQuestSellFor: %s"):format(tostring(S._autoQuestSellFor)),
            }
            print(table.concat(lines, "\n"))
            notify("Filter State", "See F9")
        end })

    -- Background loop
    task.spawn(function()
        while task.wait(S.AutoQuestDelay or 4) do
            if S.AutoQuestEnabled then
                pcall(runAutoQuestStep)
            end
        end
    end)
end

-- ============================================================

-- ============================================================
-- FUNCTION 17: startLoops
-- ============================================================
local function startLoops(env)
    local S = env.S
    local setStatus = env.setStatus
    local getFishState = env.getFishState
    local castRod = env.castRod
    local clickFish = env.clickFish
    local pullMinigame = env.pullMinigame
    local hasRodEquipped = env.hasRodEquipped
    local equipRod = env.equipRod
    local useSkillsOnce = env.useSkillsOnce
    local useSkillsAtExecute = env.useSkillsAtExecute
    local backpackIsFull = env.backpackIsFull
    local sellAll = env.sellAll
    local getSellController = env.getSellController
    local autoBuyRodOnce = env.autoBuyRodOnce
    local unlockIslandOnce = env.unlockIslandOnce
    local claimRewardsOnce = env.claimRewardsOnce
    local scanWeatherWebhooks = env.scanWeatherWebhooks
    local getSkillGachaController = env.getSkillGachaController
    local skillGachaPull = env.skillGachaPull
    local getAuraGachaController = env.getAuraGachaController
    local auraGachaPull = env.auraGachaPull
    local getCrateController = env.getCrateController
    local resolveCrateId = env.resolveCrateId
    local cratePrice = env.cratePrice
    local crateCurrency = env.crateCurrency
    local cratePullFast = env.cratePullFast
    local getCoin = env.getCoin
    local getGem = env.getGem
    local scanESP = env.scanESP
    local applyMapXRay = env.applyMapXRay
    local applyFakeStats = env.applyFakeStats
    local scanBossSpawners = env.scanBossSpawners
    local updateBossStatusLabel = env.updateBossStatusLabel
    local updateBossFarmPlatform = env.updateBossFarmPlatform
    local getActiveBossSpawner = env.getActiveBossSpawner
    local scanBossSpawnersExtended = env.scanBossSpawnersExtended
    local getRoot = env.getRoot
    local tweenTo = env.tweenTo
    local currentFishAllowedByRarity = env.currentFishAllowedByRarity
    local currentFishFilterActive = env.currentFishFilterActive
    local tr = env.TranslateText or function(text) return text end
    local getQTEDirection = env.getQTEDirection
    local pressQTE = env.pressQTE

    local function automationBusy()
        return env.isAutoActionBusy and env.isAutoActionBusy()
    end

    local function autoMissFilteredFishOnce()
        if not S.AutoMissFilteredFish or automationBusy() then return false end
        if not currentFishFilterActive then return false end
        local okActive, active = pcall(currentFishFilterActive)
        if not okActive or active ~= true then return false end
        local direction = getQTEDirection and getQTEDirection()
        if not direction then return false end
        local missDirection = "D"
        if direction == "Left" or direction == "A" then
            missDirection = "D"
        elseif direction == "Right" or direction == "D" then
            missDirection = "A"
        elseif direction == "Up" or direction == "W" then
            missDirection = "D"
        end
        if pressQTE then
            pressQTE(missDirection)
            setStatus("fishfilter", "Auto Miss: " .. tostring(direction) .. " -> " .. tostring(missDirection))
            return true
        end
        return false
    end

    local function waitForSellToFinish()
        local deadline = os.clock() + 120
        while env.isSellBusy and env.isSellBusy() and os.clock() < deadline do
            task.wait(0.25)
        end
    end

    local function fishRarityGate()
        if automationBusy() then return false end
        if not currentFishAllowedByRarity then return true end
        local ok, allowed = pcall(currentFishAllowedByRarity)
        if ok then
            if not allowed then setStatus("farm", "过滤中的鱼 - 等待") end
            return allowed == true
        end
        return true
    end

    local function skillFilterGate()
        if automationBusy() then return false end
        if currentFishFilterActive then
            local okActive, active = pcall(currentFishFilterActive)
            if not okActive or active ~= true then return true end
        end
        return fishRarityGate()
    end

    task.spawn(function() while task.wait(S.ClickDelay or 0.18) do if S.AutoClickFish and fishRarityGate() then clickFish() end end end)
    task.spawn(function() while task.wait(S.PullDelay or 0.12) do if S.AutoMissFilteredFish then autoMissFilteredFishOnce() end end end)
    task.spawn(function() while task.wait(S.PullDelay or 0.12) do if S.AutoPullMinigame and fishRarityGate() then pullMinigame() end end end)
    task.spawn(function()
        while task.wait(0.15) do
            if S.AutoCast and not automationBusy() then
                local state = getFishState()
                if state == "Idling" then
                    castRod()
                    local d = tonumber(S.AutoCastDelay) or 0.35
                    task.wait(math.clamp(d, 0.12, 2.5))
                end
            end
        end
    end)
    task.spawn(function() while task.wait(1) do if S.AutoEquipRod and not automationBusy() and not hasRodEquipped() then equipRod() end end end)
    task.spawn(function()
        while task.wait(0.75) do
            if S.AutoUseSkills and skillFilterGate() then
                useSkillsOnce()
            end
        end
    end)
    task.spawn(function() while task.wait(0.25) do if S.AutoUseSkillsAtExecute and skillFilterGate() then useSkillsAtExecute() end end end)
    task.spawn(function()
        while task.wait(1) do
            if S.AutoSellInterval then
                local minutes = tonumber(S.SellIntervalMinutes) or 0
                local seconds = tonumber(S.SellIntervalSeconds) or 0
                local total = math.max(5, math.floor(minutes * 60 + seconds))
                local waited = 0
                while waited < total and S.AutoSellInterval do
                    local remaining = math.max(0, total - waited)
                    setStatus("sell", ("%s %ds"):format(tr("Next interval sell in"), remaining))
                    task.wait(1)
                    waited += 1
                end
                if S.AutoSellInterval then
                    local busy = env.isSellBusy and env.isSellBusy()
                    if not busy then
                        setStatus("sell", tr("Interval reached - selling..."))
                        local m = S.SellMethod or "SellAll (at NPC)"
                        if m:find("SellHeld") then
                            if env.sellHeld then env.sellHeld() end
                        else
                            sellAll()
                        end
                        waitForSellToFinish()
                        setStatus("sell", ('<font color="#55ff99">%s</font>'):format(tr("Sold")))
                    end
                end
            end
        end
    end)
    task.spawn(function()
        while task.wait(3) do
            if S.AutoSellWhenFull then
                local busy = env.isSellBusy and env.isSellBusy()
                if not busy then
                    local okFull, full, count, limit, src = pcall(backpackIsFull)
                    if okFull and full then
                        setStatus("sell", ("Full (%s/%s via %s) → selling..."):format(
                            tostring(count), tostring(limit), tostring(src or "?")))
                        local m = S.SellMethod or "SellAll (at NPC)"
                        if m:find("SellHeld") then
                            if env.sellHeld then env.sellHeld() end
                        else
                            sellAll()
                        end
                        waitForSellToFinish()
                    elseif okFull and type(count) == "number" and type(limit) == "number" and limit > 0 then
                        setStatus("sell", ("Auto Sell ON — %s/%s (%d%%) [%s]"):format(
                            tostring(count), tostring(limit),
                            math.floor((count / limit) * 100),
                            tostring(src or "?")))
                    end
                end
            end
            if S.AutoLockFish and not automationBusy() then
                if env.autoLockSelectedFishOnce then
                    pcall(env.autoLockSelectedFishOnce)
                end
            end
        end
    end)
    task.spawn(function() while task.wait(3) do if S.AutoBuyRod and not automationBusy() then autoBuyRodOnce() end end end)
    task.spawn(function() while task.wait(2.5) do if S.AutoUnlockIsland and not automationBusy() then unlockIslandOnce(S.SelectedUnlockIsland) end end end)
    task.spawn(function() while task.wait(5) do if S.AutoClaimRewards and not automationBusy() then claimRewardsOnce() end end end)
    task.spawn(function() pcall(scanWeatherWebhooks, false); while task.wait(4) do pcall(scanWeatherWebhooks, false) end end)
    task.spawn(function()
        while task.wait(S.GachaDelay or 3) do
            if S.AutoSkillGacha and not automationBusy() then
                local ctrl = getSkillGachaController()
                if ctrl then
                    local coin = getCoin()
                    if S.StopCoin > 0 and coin <= S.StopCoin then S.AutoSkillGacha = false
                    else
                        local ok, inFlight = pcall(function() return ctrl:IsInFlight() end)
                        if not ok or not inFlight then skillGachaPull(S.SkillGachaCount or 1, S.SkillGachaCurrency or "Coin") end
                    end
                end
            end
        end
    end)
    task.spawn(function()
        while task.wait(S.AuraDelay or 3) do
            if S.AutoAuraGacha and not automationBusy() then
                local ctrl = getAuraGachaController()
                if ctrl then
                    local gem = getGem()
                    if S.StopGem > 0 and gem <= S.StopGem then S.AutoAuraGacha = false
                    else
                        local ok, inFlight = pcall(function() return ctrl._inFlight end)
                        if not ok or not inFlight then auraGachaPull(S.AuraGachaCount or 1) end
                    end
                end
            end
        end
    end)
    task.spawn(function()
        while task.wait(S.CrateDelay or 3) do
            if S.AutoCrate and not automationBusy() then
                local ctrl = getCrateController()
                if ctrl then
                    local crateId = resolveCrateId(S.SelectedChest or "Ocean Chest")
                    local count = S.CrateCount or 1
                    local price = cratePrice(crateId, count)
                    local curr = crateCurrency(crateId)
                    local current = curr=="Gem" and getGem() or getCoin()
                    if price and current < price then S.AutoCrate = false
                    else
                        local ok, inFlight = pcall(function() return ctrl._inFlight end)
                        if not ok or not inFlight then cratePullFast(crateId, count) end
                    end
                end
            end
        end
    end)
    task.spawn(function()
        local lastXRay = 0
        while task.wait(0.75) do
            pcall(scanESP)
            if S.MapXRay and os.clock() - lastXRay > 2 then lastXRay = os.clock(); pcall(applyMapXRay, true) end
            pcall(applyFakeStats)
        end
    end)
    task.spawn(function() while task.wait(0.1) do if S.AutoFarmBoss and not automationBusy() then pcall(updateBossFarmPlatform) end end end)
    task.spawn(function()
        while task.wait(8) do
            if S.AutoFarmBoss and not automationBusy() then
                local info = nil
                if scanBossSpawnersExtended then
                    local ok, spawners = pcall(scanBossSpawnersExtended)
                    if ok and type(spawners) == "table" then
                        for _, spawner in ipairs(spawners) do
                            if spawner.active and spawner.position then
                                info = spawner
                                break
                            end
                        end
                    end
                end
                info = info or getActiveBossSpawner()
                if info then
                    local root = getRoot()
                    if root then
                        local dist = (root.Position - info.position).Magnitude
                        if dist > 60 then
                            tweenTo(CFrame.new(info.position + Vector3.new(0, S.TweenHeight + 2, 0)), S.TweenSpeed)
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- MAIN: run everything
-- ============================================================
-- ============================================================
-- MAIN: run everything
-- ============================================================
local function main()
    local env = {}

    -- 1. State + constants (State table, Status, Paragraphs, IslandPaths, ...)
    local stateEnv = setupState()
    for k, v in pairs(stateEnv) do env[k] = v end

    -- 2. Core helpers
    --    - trim, getChar, getRoot, getHumanoid, setStatus, notify
    --    - scanBossSpawners, updateBossStatusLabel, scanWeatherWebhooks
    --    - getStardustClient, getFishingController, getFishState, getFishInfo
    --    - simulateClick / simulateHold / simulateKey
    --    - PerfectCast (hook FishCast packet)
    --    - AutoDismiss popup
    --    - tweenTo, findIslandCF, tweenToInteraction, tweenToBoss
    --    - BossFarmPlatform
    setupCore(env)

    -- 3. Data helpers
    --    - getPlayerData, readNumber, getCoin, getGem, parseAmount
    --    - getRodShop, getRodOptions, getRodSkinOptions
    --    - applyLocalRodSkin, fireRemoteNames
    setupDataHelpers(env)

    -- 4. Fishing + Controllers
    --    - castRod, clickFish, pullMinigame, useSkillsOnce, useSkillsAtExecute
    --    - getSellController, setAutoSell, sellHeld, sellAll, sellAllAnywhere
    --    - getSkillGachaController, skillGachaPull, skillGachaPity
    --    - getAuraGachaController, auraGachaPull, auraGachaPity
    --    - getCrateController, cratePull, cratePullFast, cratePity
    --    - getCodeRedeemController, redeemAllCodes, dumpAllCodes
    setupFishingCore(env)

    -- 5. ESP + Map X-Ray
    setupESP(env)

    -- 6. ⭐ FORCE INDEX PREVIEW — hiện toàn bộ cá kể cả chưa khám phá
    --    - env.setIndexPreview(on)   → gọi IndexController:SetPreview(on)
    --    - env.openIndexUI()         → mở UI Index
    --    - env.getIndexController()  → trả về controller instance
    setupIndexPreview(env)

    -- 6b. ⭐ BOSS ADVANCED — Spawn Alert, Phase hooks, Region ESP, Catch History
    setupBossAdvanced(env)

    -- 7. Info bar overlay (FPS, ping, Dismiss status)
    setupInfoBar(env)

    -- 8. Fly + RenderStepped loop (WalkSpeed, Noclip, FullBright, WalkOnWater)
    setupFly(env)

    -- 9. Language i18n (Vietnamese dict + ApplyUILanguage)
    setupLanguage(env)

    -- 10. WindUI window (CreateWindow + EditOpenButton + Tag)
    setupWindow(env)

    -- 11. Build tabs (thứ tự: Farm → Player → Quest → Visual → Shop → Misc → Settings → Info)
    -- Tab order: Farm → Player → Quest → Visual → Shop → Misc → Settings → Info
    buildInfoTab(env)        -- Home
    buildFarmTab(env)        -- Farm
    buildPlayerTab(env)      -- Player
    buildPriorityTab(env)    -- Priority
    local okAQ, errAQ = pcall(buildAutoQuestTab, env)  -- Quest
    if not okAQ then
        warn("[NNVN Hub] buildAutoQuestTab failed:", tostring(errAQ))
    end
    buildVisualTab(env)      -- Visual
    buildShopTab(env)        -- Shop
    buildMiscTab(env)        -- Misc
    buildSettingsTab(env)    -- Settings

    -- 12. Start
    pcall(function()
        if env.ensureBossStatusLabel then env.ensureBossStatusLabel() end
    end)
    startLoops(env)

    pcall(function() env.Window:SelectTab(1) end)

    -- Print banner + info
    pcall(function()
        print([[
--------------------------------
|  _   _ _   ___     ___   _   |
| | \ | | \ | \ \   / / \ | |  |
| |  \| |  \| |\ \ / /|  \| |  |
| | |\  | |\  | \ V / | |\  |  |
| |_| \_|_| \_|  \_/  |_| \_|  |
|          NNVN Hub            |
|    Fishing Master v1.4.8     |
|  + Boss in Farm + Box ESP + AntiAFK     |
--------------------------------
]])
        print("[NNVN Hub] Fishing Master v1.4.8 loaded")
    end)

    -- Notify loaded
    if getgenv().NNVN_WindUI and getgenv().NNVN_WindUI.Notify then
        pcall(function()
            getgenv().NNVN_WindUI:Notify({
                Title = "NNVN Hub",
                Content = "Fishing Master v1.4.8 loaded! (Boss Advanced)",
                Duration = 3,
            })
        end)
    end

    -- Apply language sau khi UI build xong
    task.delay(1, function() pcall(env.ApplyUILanguage) end)
    task.delay(3, function() pcall(env.ApplyUILanguage) end)

    -- ⭐ OPTIONAL: Tự động bật Index Preview ngay khi load script
    -- Bỏ comment 5 dòng dưới nếu muốn tự động ON
    -- task.delay(2, function()
    --     if env.setIndexPreview then
    --         env.setIndexPreview(true)
    --     end
    -- end)
end

main()
