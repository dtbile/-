--!strict
-- Roblox Studio LocalScript
-- 功能：
-- 1) 记录最近 5 秒速度数据（总速度/水平速度/垂直速度）
-- 2) 在屏幕上显示当前速度信息
-- 3) 绘制最近 5 秒三条平滑速度曲线
-- 4) 纵轴显示刻度数字，超过最大刻度会自动上调
--
-- 使用方式：
-- - 将本脚本放入 StarterPlayerScripts（推荐）
-- - 运行游戏后会自动创建 UI

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer

-- ===== 可调参数 =====
local WINDOW_SECONDS = 5 -- 图表窗口（最近 N 秒）
local SAMPLE_RATE = 60 -- 每秒采样次数（采样更密，曲线更顺滑）
local RENDER_POINTS = 180 -- 图中重采样点数（越高越平滑，性能开销也更高）
local GRAPH_HEIGHT = 240
local GRAPH_WIDTH = 860
local GRAPH_PADDING = 16
local GRAPH_LINES = 5 -- 横向网格线数量（包含顶部和底部）
local SCALE_HEADROOM = 1.12 -- 超过上限时增加的余量比例
local DOWNSCALE_LERP = 0.08 -- 缩小纵轴时的缓降速度，避免抖动

-- ===== UI 创建 =====
local gui = Instance.new("ScreenGui")
gui.Name = "SpeedRecorderGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = localPlayer:WaitForChild("PlayerGui")

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromOffset(GRAPH_WIDTH + GRAPH_PADDING * 2, GRAPH_HEIGHT + 130)
root.Position = UDim2.fromScale(0.5, 0.05)
root.AnchorPoint = Vector2.new(0.5, 0)
root.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
root.BorderSizePixel = 0
root.Parent = gui

local rootCorner = Instance.new("UICorner")
rootCorner.CornerRadius = UDim.new(0, 10)
rootCorner.Parent = root

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 8)
title.Size = UDim2.new(1, -28, 0, 26)
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(235, 239, 245)
title.Text = "速度记录器（最近 5 秒）"
title.Parent = root

local stats = Instance.new("TextLabel")
stats.Name = "Stats"
stats.BackgroundTransparency = 1
stats.Position = UDim2.fromOffset(14, 34)
stats.Size = UDim2.new(1, -28, 0, 56)
stats.Font = Enum.Font.Code
stats.TextSize = 15
stats.TextXAlignment = Enum.TextXAlignment.Left
stats.TextYAlignment = Enum.TextYAlignment.Top
stats.TextColor3 = Color3.fromRGB(206, 216, 228)
stats.Text = "等待角色生成..."
stats.Parent = root

local axisWidth = 68
local graph = Instance.new("Frame")
graph.Name = "Graph"
graph.Position = UDim2.fromOffset(GRAPH_PADDING + axisWidth, 96)
graph.Size = UDim2.fromOffset(GRAPH_WIDTH - axisWidth, GRAPH_HEIGHT)
graph.BackgroundColor3 = Color3.fromRGB(30, 33, 39)
graph.BorderSizePixel = 0
graph.ClipsDescendants = true
graph.Parent = root

local graphCorner = Instance.new("UICorner")
graphCorner.CornerRadius = UDim.new(0, 8)
graphCorner.Parent = graph

local yAxisContainer = Instance.new("Frame")
yAxisContainer.Name = "YAxis"
yAxisContainer.BackgroundTransparency = 1
yAxisContainer.Position = UDim2.fromOffset(GRAPH_PADDING, 96)
yAxisContainer.Size = UDim2.fromOffset(axisWidth - 6, GRAPH_HEIGHT)
yAxisContainer.Parent = root

local legend = Instance.new("TextLabel")
legend.Name = "Legend"
legend.BackgroundTransparency = 1
legend.Position = UDim2.new(0, 12, 1, -24)
legend.Size = UDim2.new(1, -24, 0, 20)
legend.Font = Enum.Font.Gotham
legend.TextSize = 12
legend.TextXAlignment = Enum.TextXAlignment.Left
legend.TextColor3 = Color3.fromRGB(205, 211, 220)
legend.Text = "白: 总速度 | 蓝: 水平速度 | 红: 垂直速度(绝对值)"
legend.Parent = graph

local yLabels: { TextLabel } = {}
for i = 0, GRAPH_LINES - 1 do
	local y = i / (GRAPH_LINES - 1)

	local line = Instance.new("Frame")
	line.Name = "GridY_" .. i
	line.AnchorPoint = Vector2.new(0, 0.5)
	line.Position = UDim2.fromScale(0, y)
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3 = Color3.fromRGB(58, 62, 70)
	line.BorderSizePixel = 0
	line.Parent = graph

	local label = Instance.new("TextLabel")
	label.Name = "Tick_" .. i
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.Position = UDim2.new(1, 0, y, 0)
	label.Size = UDim2.new(1, 0, 0, 16)
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextColor3 = Color3.fromRGB(170, 178, 192)
	label.Text = "0"
	label.Parent = yAxisContainer
	table.insert(yLabels, label)
end

-- ===== 数据结构 =====
type Sample = {
	time: number,
	total: number,
	horizontal: number,
	verticalAbs: number,
}

local samples: { Sample } = {}
local yAxisMax = 50

local function clearLineSegments()
	for _, child in graph:GetChildren() do
		if child:IsA("Frame") and string.sub(child.Name, 1, 5) == "Line_" then
			child:Destroy()
		end
	end
end

local function trimOldSamples(nowTs: number)
	local minTs = nowTs - WINDOW_SECONDS
	while #samples > 0 and samples[1].time < minTs do
		table.remove(samples, 1)
	end
end

local function pushSample(sample: Sample)
	table.insert(samples, sample)
	trimOldSamples(sample.time)
end

local function getNiceMax(value: number): number
	if value <= 1 then
		return 1
	end

	local exp = math.floor(math.log10(value))
	local base = 10 ^ exp
	local scaled = value / base
	local nice
	if scaled <= 1 then
		nice = 1
	elseif scaled <= 2 then
		nice = 2
	elseif scaled <= 2.5 then
		nice = 2.5
	elseif scaled <= 5 then
		nice = 5
	else
		nice = 10
	end
	return nice * base
end

local function updateYAxisLabels()
	for i, label in ipairs(yLabels) do
		local ratio = (i - 1) / (GRAPH_LINES - 1)
		local val = yAxisMax * (1 - ratio)
		label.Text = string.format("%6.1f", val)
	end
end

local function drawLine(x1: number, y1: number, x2: number, y2: number, color: Color3, thickness: number, id: number)
	local dx = x2 - x1
	local dy = y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	if length <= 0 then
		return
	end

	local line = Instance.new("Frame")
	line.Name = string.format("Line_%d", id)
	line.AnchorPoint = Vector2.new(0, 0.5)
	line.Position = UDim2.fromOffset(x1, y1)
	line.Size = UDim2.fromOffset(length, thickness)
	line.BorderSizePixel = 0
	line.BackgroundColor3 = color
	line.Rotation = math.deg(math.atan2(dy, dx))
	line.Parent = graph
end

type SeriesField = "total" | "horizontal" | "verticalAbs"

local function getSampleField(sample: Sample, field: SeriesField): number
	if field == "total" then
		return sample.total
	elseif field == "horizontal" then
		return sample.horizontal
	else
		return sample.verticalAbs
	end
end

local function getValueAtTime(buffer: { Sample }, t: number, field: SeriesField, cursor: number): (number, number)
	local n = #buffer
	if n == 0 then
		return 0, cursor
	end

	cursor = math.clamp(cursor, 1, n)
	while cursor < n and buffer[cursor + 1].time < t do
		cursor += 1
	end

	local a = buffer[cursor]
	if cursor >= n then
		return getSampleField(a, field), cursor
	end

	local b = buffer[cursor + 1]
	if b.time <= a.time then
		return getSampleField(a, field), cursor
	end

	if t <= a.time then
		return getSampleField(a, field), cursor
	end

	local alpha = math.clamp((t - a.time) / (b.time - a.time), 0, 1)
	local av = getSampleField(a, field)
	local bv = getSampleField(b, field)
	return av + (bv - av) * alpha, cursor
end

local function resampleSeries(nowTs: number): ({ number }, { number }, { number }, number)
	local totals = table.create(RENDER_POINTS, 0)
	local horizontals = table.create(RENDER_POINTS, 0)
	local verticals = table.create(RENDER_POINTS, 0)

	if #samples == 0 then
		return totals, horizontals, verticals, 0
	end

	local startTs = nowTs - WINDOW_SECONDS
	local peak = 0
	local c1, c2, c3 = 1, 1, 1

	for i = 1, RENDER_POINTS do
		local t = startTs + ((i - 1) / (RENDER_POINTS - 1)) * WINDOW_SECONDS
		local total, nc1 = getValueAtTime(samples, t, "total", c1)
		local horizontal, nc2 = getValueAtTime(samples, t, "horizontal", c2)
		local vertical, nc3 = getValueAtTime(samples, t, "verticalAbs", c3)
		c1, c2, c3 = nc1, nc2, nc3

		totals[i] = total
		horizontals[i] = horizontal
		verticals[i] = vertical
		peak = math.max(peak, total, horizontal, vertical)
	end

	return totals, horizontals, verticals, peak
end

local function smoothSeries(values: { number }): { number }
	local n = #values
	if n <= 2 then
		return values
	end

	local out = table.create(n, 0)
	out[1] = values[1]
	for i = 2, n - 1 do
		out[i] = values[i - 1] * 0.2 + values[i] * 0.6 + values[i + 1] * 0.2
	end
	out[n] = values[n]
	return out
end

local lineCounter = 0
local function plotSeries(values: { number }, color: Color3)
	if #values < 2 then
		return
	end

	local w = graph.AbsoluteSize.X
	local h = graph.AbsoluteSize.Y - 24
	if w <= 1 or h <= 1 then
		return
	end

	for i = 1, #values - 1 do
		local x1 = ((i - 1) / (#values - 1)) * w
		local x2 = (i / (#values - 1)) * w
		local y1 = h - (math.clamp(values[i] / yAxisMax, 0, 1) * h)
		local y2 = h - (math.clamp(values[i + 1] / yAxisMax, 0, 1) * h)

		lineCounter += 1
		drawLine(x1, y1, x2, y2, color, 2, lineCounter)
	end
end

local function updateYAxisScale(observedPeak: number)
	local expanded = getNiceMax(math.max(1, observedPeak * SCALE_HEADROOM))
	if expanded > yAxisMax then
		yAxisMax = expanded
	else
		local target = getNiceMax(math.max(1, observedPeak * SCALE_HEADROOM))
		yAxisMax = math.max(target, yAxisMax - (yAxisMax - target) * DOWNSCALE_LERP)
		yAxisMax = math.max(1, yAxisMax)
	end
	updateYAxisLabels()
end

local function renderGraph(nowTs: number)
	clearLineSegments()
	trimOldSamples(nowTs)
	if #samples < 2 then
		return
	end

	local totals, horizontals, verticals, peak = resampleSeries(nowTs)
	updateYAxisScale(peak)

	local smoothTotal = smoothSeries(totals)
	local smoothHorizontal = smoothSeries(horizontals)
	local smoothVertical = smoothSeries(verticals)

	plotSeries(smoothTotal, Color3.fromRGB(240, 240, 240))
	plotSeries(smoothHorizontal, Color3.fromRGB(90, 170, 255))
	plotSeries(smoothVertical, Color3.fromRGB(255, 95, 95))
end

-- ===== 角色速度读取 =====
local currentHumanoidRootPart: BasePart? = nil

local function bindCharacter(character: Model)
	currentHumanoidRootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
end

if localPlayer.Character then
	bindCharacter(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(function(char)
	table.clear(samples)
	yAxisMax = 50
	updateYAxisLabels()
	bindCharacter(char)
end)

updateYAxisLabels()

-- ===== 主循环 =====
local sampleInterval = 1 / SAMPLE_RATE
local elapsed = 0

RunService.RenderStepped:Connect(function(dt)
	elapsed += dt
	if elapsed < sampleInterval then
		return
	end
	elapsed = 0

	local nowTs = os.clock()
	local hrp = currentHumanoidRootPart
	if not hrp then
		stats.Text = "等待角色 HumanoidRootPart..."
		return
	end

	local vel = hrp.AssemblyLinearVelocity
	local horizontal = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local vertical = vel.Y
	local total = vel.Magnitude

	pushSample({
		time = nowTs,
		total = total,
		horizontal = horizontal,
		verticalAbs = math.abs(vertical),
	})

	local up = vertical >= 0 and "↑" or "↓"
	stats.Text = string.format(
		"总速度: %.2f stud/s\n水平速度: %.2f stud/s\n垂直速度: %s %.2f stud/s",
		total,
		horizontal,
		up,
		math.abs(vertical)
	)

	renderGraph(nowTs)
end)
