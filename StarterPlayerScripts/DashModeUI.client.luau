local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MODES = { "Slide", "Teleport" }
local ACTIVE_COLOR = Color3.fromRGB(70, 150, 255)
local IDLE_COLOR = Color3.fromRGB(40, 40, 50)
local CYCLE_KEY = Enum.KeyCode.R

player:SetAttribute("DashMode", MODES[1])

local gui = Instance.new("ScreenGui")
gui.Name = "DashModeUI"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 1)
frame.Position = UDim2.new(0.5, 0, 1, -20)
frame.Size = UDim2.fromOffset(260, 70)
frame.BackgroundTransparency = 1
frame.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Padding = UDim.new(0, 10)
layout.Parent = frame

local buttons = {}

local function refresh()
	local current = player:GetAttribute("DashMode")
	for mode, button in buttons do
		local active = mode == current
		TweenService:Create(button, TweenInfo.new(0.15), {
			BackgroundColor3 = active and ACTIVE_COLOR or IDLE_COLOR,
			Size = active and UDim2.fromOffset(125, 66) or UDim2.fromOffset(115, 56),
		}):Play()
	end
end

for _, mode in MODES do
	local button = Instance.new("TextButton")
	button.Name = mode
	button.Text = mode
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = Color3.new(1, 1, 1)
	button.BackgroundColor3 = IDLE_COLOR
	button.Size = UDim2.fromOffset(115, 56)
	button.AutoButtonColor = false
	button.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	button.Activated:Connect(function()
		player:SetAttribute("DashMode", mode)
	end)

	buttons[mode] = button
end

-- Press R to cycle modes
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or input.KeyCode ~= CYCLE_KEY then return end
	local currentIndex = table.find(MODES, player:GetAttribute("DashMode")) or 1
	player:SetAttribute("DashMode", MODES[currentIndex % #MODES + 1])
end)

player:GetAttributeChangedSignal("DashMode"):Connect(refresh)
refresh()

-- v1.0.0.0.1