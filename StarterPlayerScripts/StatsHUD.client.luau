--!nonstrict
-- StatsHUD v1.0.0.1
-- StarterPlayerScripts (LocalScript). Render-only: shows money, level and XP from the player
-- attributes DataService publishes (Money, PlayerLevel, PlayerXP, PlayerXPNeeded).
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local BG, EDGE = Color3.fromRGB(19, 27, 44), Color3.fromRGB(52, 66, 92)
local TEXT = Color3.fromRGB(243, 246, 252)
local GOLD, XPCOL, RED = Color3.fromRGB(255, 205, 64), Color3.fromRGB(96, 214, 255), Color3.fromRGB(255, 110, 110)
local COUNT = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FLOAT = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in props do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function fmt(n) -- 1234567 -> "1,234,567"
	local s = string.format("%.0f", n):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

-- Layout: scale-sized, clamped in pixels so phones and ultrawides both read well.
local gui = make("ScreenGui", { Name = "StatsHUD", ResetOnSpawn = false, DisplayOrder = 5 }, player:WaitForChild("PlayerGui"))
local root = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.75, 0),
	Size = UDim2.fromScale(0.15, 0.10),
	BackgroundTransparency = 1,
}, gui)
make("UISizeConstraint", { MinSize = Vector2.new(190, 64), MaxSize = Vector2.new(320, 92) }, root)

local card = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BG, BackgroundTransparency = 0.1 }, root)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, card)
make("UIStroke", { Color = EDGE, Thickness = 1.5 }, card)
make("UIPadding", {
	PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, card)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, card)

local moneyLabel = make("TextLabel", {
	Size = UDim2.fromScale(1, 0.5), BackgroundTransparency = 1, Text = "💰 0", TextColor3 = GOLD,
	Font = Enum.Font.GothamBold, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1,
}, card)
make("UITextSizeConstraint", { MaxTextSize = 24 }, moneyLabel)

local row = make("Frame", { Size = UDim2.fromScale(1, 0.4), BackgroundTransparency = 1, LayoutOrder = 2 }, card)
local levelLabel = make("TextLabel", {
	Size = UDim2.fromScale(0.26, 1), BackgroundTransparency = 1, Text = "Lv 1", TextColor3 = TEXT,
	Font = Enum.Font.GothamBold, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left,
}, row)
make("UITextSizeConstraint", { MaxTextSize = 16 }, levelLabel)
local levelScale = make("UIScale", {}, levelLabel)

local bar = make("Frame", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.72, 0.8),
	BackgroundColor3 = EDGE,
}, row)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)
local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = XPCOL }, bar)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
local xpText = make("TextLabel", {
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "0 / 100", TextColor3 = TEXT,
	Font = Enum.Font.GothamMedium, TextScaled = true, TextStrokeTransparency = 0.6, ZIndex = 2,
}, bar)
make("UITextSizeConstraint", { MaxTextSize = 13 }, xpText)

-- Floating "+1,000" under the card (x = 0.3 money side, 0.7 XP side).
local function popup(text, color, x)
	local label = make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(x, 0, 1, 4), Size = UDim2.fromOffset(140, 24),
		BackgroundTransparency = 1, Text = text, TextColor3 = color, Font = Enum.Font.GothamBold,
		TextSize = 20, TextStrokeTransparency = 0.5,
	}, root)
	local tween = TweenService:Create(label, FLOAT, {
		Position = UDim2.new(x, 0, 1, 30), TextTransparency = 1, TextStrokeTransparency = 1,
	})
	tween.Completed:Connect(function()
		label:Destroy()
	end)
	tween:Play()
end

-- Money: count-up number, popup on gain/spend. The first value just snaps in (no popup).
local moneyShown = Instance.new("NumberValue")
moneyShown.Changed:Connect(function(v)
	moneyLabel.Text = "💰 " .. fmt(v)
end)

local lastMoney
local function onMoney()
	local v = player:GetAttribute("Money")
	if type(v) ~= "number" then
		return
	end
	if lastMoney == nil then
		moneyShown.Value = v
	else
		if v ~= lastMoney then
			local d = v - lastMoney
			popup((d > 0 and "+" or "-") .. fmt(math.abs(d)), d > 0 and GOLD or RED, 0.3)
		end
		TweenService:Create(moneyShown, COUNT, { Value = v }):Play()
	end
	lastMoney = v
end

-- XP / level: three attributes change together, so read them once per frame (defer).
local lastXP, lastLevel, xpQueued = nil, nil, false
local function readXP()
	xpQueued = false
	local xp, need, lv = player:GetAttribute("PlayerXP"), player:GetAttribute("PlayerXPNeeded"), player:GetAttribute("PlayerLevel")
	if type(xp) ~= "number" or type(need) ~= "number" or type(lv) ~= "number" then
		return
	end
	levelLabel.Text = "Lv " .. fmt(lv)
	xpText.Text = fmt(xp) .. " / " .. fmt(need)
	TweenService:Create(fill, COUNT, { Size = UDim2.fromScale(math.clamp(xp / need, 0, 1), 1) }):Play()
	if lastLevel ~= nil then
		if lv > lastLevel then
			popup("LEVEL UP!", XPCOL, 0.7)
			TweenService:Create(levelScale, POP, { Scale = 1.4 }):Play()
			task.delay(0.15, function()
				TweenService:Create(levelScale, POP, { Scale = 1 }):Play()
			end)
		elseif xp > lastXP then
			popup("+" .. fmt(xp - lastXP) .. " XP", XPCOL, 0.7)
		end
	end
	lastXP, lastLevel = xp, lv
end

local function onXP()
	if not xpQueued then
		xpQueued = true
		task.defer(readXP)
	end
end

player:GetAttributeChangedSignal("Money"):Connect(onMoney)
for _, name in { "PlayerXP", "PlayerXPNeeded", "PlayerLevel" } do
	player:GetAttributeChangedSignal(name):Connect(onXP)
end
onMoney()
onXP()
