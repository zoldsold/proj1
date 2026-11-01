--[[
	PetClient_Cinema (ModuleScript -> ReplicatedStorage/PetClientModules)

	Cinematic camera letterbox, titles, flash overlay, control toggling,
	and the two full cutscenes: Summon and Evolve.

	FIXES:
	  - Require path matches the live folder (PetClientModules).
	  - Removed the PetModelBuilder require (server-only module; the client
	    never used it and requiring it fired on load).
	  - Easing enums resolved from Enum.* directly.  Reading them off Helpers
	    returned nil, which crashed TweenInfo.new with
	    "second argument expects Enum.EasingStyle input".
]]
-- v1.0.0.0.1
local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local ModulesFolder = game.ReplicatedStorage:WaitForChild("PetClientModules")

local Helpers   = require(ModulesFolder:WaitForChild("PetClient_Helpers"))
local VFX       = require(ModulesFolder:WaitForChild("PetClient_VFX"))
local PetConfig = require(game.ReplicatedStorage:WaitForChild("PetConfig"))

local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")
local camera     = workspace.CurrentCamera

local Timing = PetConfig.Timing

-- Resolved directly from Enum so we never depend on Helpers re-exporting these.
local SINE  = Enum.EasingStyle.Sine
local QUAD  = Enum.EasingStyle.Quad
local QUART = Enum.EasingStyle.Quart

local IN    = Enum.EasingDirection.In
local OUT   = Enum.EasingDirection.Out
local INOUT = Enum.EasingDirection.InOut

local WHITE = Color3.new(1, 1, 1)

local Cinema = {}

------------------------------------------------------------------ UI setup

local cine = Instance.new("ScreenGui")
cine.Name = "PetCinema"; cine.ResetOnSpawn = false
cine.IgnoreGuiInset = true; cine.DisplayOrder = 50; cine.Parent = playerGui

local function solidFrame(name, anchorY)
	local f = Instance.new("Frame")
	f.Name = name; f.BorderSizePixel = 0; f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.AnchorPoint = Vector2.new(0, anchorY); f.Position = UDim2.fromScale(0, anchorY)
	f.Size = UDim2.new(1, 0, 0, 0); f.Parent = cine
	return f
end

local topBar    = solidFrame("TopBar", 0)
local bottomBar = solidFrame("BottomBar", 1)

local flashFrame = Instance.new("Frame")
flashFrame.Name = "Flash"; flashFrame.BorderSizePixel = 0
flashFrame.BackgroundColor3 = WHITE; flashFrame.BackgroundTransparency = 1
flashFrame.Size = UDim2.fromScale(1, 1); flashFrame.ZIndex = 10; flashFrame.Parent = cine

local function mkLabel(y, maxSize, font)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, y); l.Size = UDim2.fromScale(0.8, 0.08)
	l.Font = font; l.TextScaled = true; l.TextColor3 = WHITE
	l.TextTransparency = 1; l.TextStrokeTransparency = 1; l.ZIndex = 5; l.Parent = cine
	local lim = Instance.new("UITextSizeConstraint"); lim.MaxTextSize = maxSize; lim.Parent = l
	return l
end

local titleSmall = mkLabel(0.66, 20, Enum.Font.GothamMedium)
local titleBig   = mkLabel(0.73, 54, Enum.Font.GothamBlack)

------------------------------------------------------------------ UI helpers

function Cinema.showTitle(small, big, color)
	titleSmall.Text = small; titleBig.Text = big; titleBig.TextColor3 = color
	local info = TweenInfo.new(0.6, QUAD, OUT)
	for _, l in { titleSmall, titleBig } do
		TweenService:Create(l, info, { TextTransparency = 0, TextStrokeTransparency = 0.7 }):Play()
	end
end

function Cinema.hideTitle()
	local info = TweenInfo.new(0.5)
	for _, l in { titleSmall, titleBig } do
		TweenService:Create(l, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
end

function Cinema.letterbox(on, dur)
	local sz = UDim2.new(1, 0, on and 0.115 or 0, 0)
	TweenService:Create(topBar,    TweenInfo.new(dur, QUAD, INOUT), { Size = sz }):Play()
	TweenService:Create(bottomBar, TweenInfo.new(dur, QUAD, INOUT), { Size = sz }):Play()
end

function Cinema.flash(t, dur)
	TweenService:Create(flashFrame, TweenInfo.new(dur, QUAD, OUT), { BackgroundTransparency = t }):Play()
end

function Cinema.setControls(enabled)
	local ps  = player:FindFirstChild("PlayerScripts"); if not ps then return end
	local pm  = ps:FindFirstChild("PlayerModule"); if not pm then return end
	local ok, ctrl = pcall(function() return require(pm):GetControls() end)
	if not ok or not ctrl then return end
	if enabled then ctrl:Enable() else ctrl:Disable() end
end

------------------------------------------------------------------ cinematic session

Cinema.session = { active = false }

function Cinema.beginCinematic()
	local session = Cinema.session
	session.active = true

	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local look = root and root.CFrame.LookVector or Vector3.new(0, 0, -1)
	local flat = Vector3.new(look.X, 0, look.Z)
	session.fwd = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
	session.right = session.fwd:Cross(Vector3.yAxis)
	session.originalCF  = camera.CFrame
	session.originalFov = camera.FieldOfView

	player:SetAttribute("PetCinematic", true)
	camera.CameraType = Enum.CameraType.Scriptable
	Cinema.setControls(false)
	Cinema.letterbox(true, 0.5)
end

function Cinema.endCinematic()
	local session = Cinema.session
	local fromCF, fromFov = camera.CFrame, camera.FieldOfView
	local toCF, toFov     = session.originalCF, session.originalFov

	Helpers.timeline(0.7, function(a)
		local e = Helpers.ease(a, SINE, INOUT)
		camera.CFrame = fromCF:Lerp(toCF, e)
		camera.FieldOfView = fromFov + (toFov - fromFov) * e
	end)

	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = toFov
	Cinema.letterbox(false, 0.4)
	Cinema.hideTitle()
	flashFrame.BackgroundTransparency = 1
	Cinema.setControls(true)
	player:SetAttribute("PetCinematic", false)
	session.active = false
end

function Cinema.runCinematic(fn)
	if Cinema.session.active then return end
	Cinema.beginCinematic()
	local ok, err = pcall(fn)
	if not ok then warn("[Pet cinematic]", err) end
	Cinema.endCinematic()
end

------------------------------------------------------------------ camera math

function Cinema.orbitCF(focus, phi, radius, height)
	local s = Cinema.session
	local dir = s.fwd * math.cos(phi) + s.right * math.sin(phi)
	return CFrame.lookAt(focus + dir * radius + Vector3.new(0, height, 0), focus)
end

function Cinema.aim(a, intro, targetCF, targetFov)
	local s = Cinema.session
	if a < intro then
		local k = Helpers.ease(a / intro, SINE, INOUT)
		camera.CFrame = s.originalCF:Lerp(targetCF, k)
		camera.FieldOfView = s.originalFov + (targetFov - s.originalFov) * k
	else
		camera.CFrame = targetCF
		camera.FieldOfView = targetFov
	end
end

------------------------------------------------------------------ cutscenes

function Cinema.summonCinematic(model, ground, petsFolder)
	local cfg = Helpers.stageCfgOf(model)
	local scale = cfg.Scale

	local function petPos()
		local b = model:FindFirstChild("Body")
		return b and b.Position or ground
	end

	Helpers.timeline(Timing.Summon, function(a)
		local e = Helpers.ease(a, SINE, INOUT)
		local focus = ground:Lerp(petPos(), Helpers.ease(a * 1.6, SINE, OUT)) + Vector3.new(0, 1, 0)
		Cinema.aim(a, 0.14, Cinema.orbitCF(focus, math.rad(20 + 70 * e), (11 + 13 * scale) - (5 + 6 * scale) * e, 0.8 + (2.5 + 3 * scale) * e), 72 - 14 * e)
	end)
end

Cinema.revealed = {}

function Cinema.evolveCinematic(userId, petsFolder)
	local body = Helpers.petBody(userId, petsFolder)
	if not body then return end
	local cfg = Helpers.stageCfgOf(body.Parent)
	local scale = cfg.Scale

	local lastFocus = body.Position
	local function focus()
		local b = Helpers.petBody(userId, petsFolder)
		if b then lastFocus = b.Position end
		return lastFocus + Vector3.new(0, 1, 0)
	end

	VFX.evolveBuildupVFX(userId, Timing.EvolveBuildup, petsFolder)

	Helpers.timeline(Timing.EvolveBuildup, function(a)
		local e = Helpers.ease(a, QUAD, IN)
		local shake = 0.45 * e * e
		local cf = Cinema.orbitCF(focus(), math.rad(25 + 150 * Helpers.ease(a, SINE, INOUT)), (9 + 12 * scale) * (1 - 0.4 * e), 1.5 + (1.5 + 2 * scale) * Helpers.ease(a, SINE, OUT))
			* CFrame.new(Helpers.nextNumber(-shake, shake), Helpers.nextNumber(-shake, shake), 0)
		Cinema.aim(a, 0.12, cf, 70 - 16 * e)
	end)

	Cinema.flash(0, 0.15)
	camera.FieldOfView = 95

	local waited = 0
	while Cinema.revealed[userId] == nil and waited < 4 do
		waited += task.wait()
	end
	Cinema.revealed[userId] = nil

	local newModel = petsFolder:WaitForChild(tostring(userId), 3)
	local newBody  = newModel and newModel:WaitForChild("Body", 3)
	if not newBody then return end
	local newCfg = Helpers.stageCfgOf(newModel)
	if not newCfg then return end
	local ns = newCfg.Scale

	VFX.evolveRevealVFX(userId, petsFolder)
	Cinema.flash(1, 0.9)

	local titled = false
	Helpers.timeline(Timing.EvolveReveal, function(a)
		local e = Helpers.ease(a, QUART, OUT)
		local shake = 0.5 * (1 - a) ^ 3
		camera.CFrame = Cinema.orbitCF(focus(), math.rad(175 + 60 * a), (5 + 5 * ns) + (12 + 16 * ns) * e, 2 + (2.5 + 4 * ns) * e)
			* CFrame.new(Helpers.nextNumber(-shake, shake), Helpers.nextNumber(-shake, shake), 0)
		camera.FieldOfView = 62 + 33 * (1 - e) ^ 2

		if not titled and a > 0.28 then
			titled = true
			Cinema.showTitle("EVOLUTION COMPLETE", newCfg.Name:upper(), newCfg.Colors.Glow)
			task.delay(2.2, Cinema.hideTitle)
		end
	end)
end

return Cinema