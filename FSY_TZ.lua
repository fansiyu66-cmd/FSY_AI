-- ============================================================================
-- FSY 探针（先跑这个，30 秒内出结果）
-- 作用：只验证两件事 —— ① 你的执行器能不能正常执行脚本；② ScreenGui 能不能显示出来。
-- 如果这个绿色按钮都看不到，说明问题在执行器/注入环境，而不是脚本本身。
-- ============================================================================
print("[FSY探针] 开始执行")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
print("[FSY探针] LocalPlayer =", tostring(lp))
local pg = lp and (lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 10))
print("[FSY探针] PlayerGui =", tostring(pg))
local sg = Instance.new("ScreenGui")
sg.Name = "FSY_Probe"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 99999
sg.Parent = pg
local btn = Instance.new("TextButton")
btn.Size = UDim2.new(0, 260, 0, 90)
btn.Position = UDim2.new(0.5, -130, 0.4, 0)
btn.BackgroundColor3 = Color3.fromRGB(0, 200, 120)
btn.Text = "FSY 探针 OK"
btn.TextSize = 20
btn.TextColor3 = Color3.fromRGB(255, 255, 255)
btn.Parent = sg
btn.MouseButton1Click:Connect(function()
    print("[FSY探针] 按钮点击成功，UI 交互正常")
    btn.Text = "点击成功 ✓"
end)
print("[FSY探针] 完成  ScreenGui.Parent =", tostring(sg.Parent), " Enabled =", tostring(sg.Enabled))
