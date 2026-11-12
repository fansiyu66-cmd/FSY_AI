local pg = game:GetService("Players").LocalPlayer.PlayerGui
local function dumpScreen(name)
    local g = pg:FindFirstChild(name)
    print("=== " .. name .. " ===")
    if not g then print("  不存在") return end
    print("  Enabled = " .. tostring(g.Enabled))
    for _, d in ipairs(g:GetDescendants()) do
        local isBtn = d:IsA("TextButton") or d:IsA("ImageButton")
        if isBtn and (d.Name:lower():find("fish") or (d:IsA("TextButton") and (d.Text or ""):find("钓鱼"))) then
            local chain, cur, n = {}, d, 0
            while cur and n < 9 and cur ~= pg do
                table.insert(chain, string.format("%s(%s) V=%s E=%s", cur.Name, cur.ClassName, tostring(cur.Visible), tostring(cur.Enabled)))
                cur = cur.Parent
                n = n + 1
            end
            print("  " .. table.concat(chain, "\n   ↑ "))
        end
    end
end
dumpScreen("MainGui")
dumpScreen("Fisher_GUI")
print("脚本是否认得按钮: " .. tostring(getgenv().IdenticalProtectedFishBtn))
print("脚本强显开关: " .. tostring(getgenv().IdenticalKeepFishBtnVisible))