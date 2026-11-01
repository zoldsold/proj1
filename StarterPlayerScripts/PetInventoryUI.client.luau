--[[
	PetInventoryUI (LocalScript -> StarterPlayer > StarterPlayerScripts)

	Pet collection screen. Round toggle button in bottom-right corner opens
	panel with one card per inventory slot (PetConfig.MaxSlots, laid out 3 wide).

	NOTE: Uses plain Frame instead of CanvasGroup — CanvasGroup has a Roblox
	bug where child buttons don't receive clicks when GroupTransparency > 0.
	We fade by tweening BackgroundTransparency on the panel frame directly.
]]
-- v1.0.0.1
-- CHANGES v1.0.0.1: cards show petData.Nickname when the server snapshot carries one (stage name moves to the sub-label).
-- v1.0.0.0.2 FIXES: All capitalized keywords lowercased; broken concat `.` → `..`;
--        payload key casing: payload.pets→payload.Pets, payload.equipped→payload.Equipped
--        (matches PetManager snapshot which sends capital keys);
--        mixed-case var refs (C., L., B., etc.) → lowercase throughout

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService      = game:GetService("RunService")
local TweenService    = game:GetService("TweenService")

local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))
local Builder   = require(ReplicatedStorage:WaitForChild("PetModelBuilder"))
local PetEvent  = ReplicatedStorage:WaitForChild("PetEvent")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local QUAD = Enum.EasingStyle.Quad
local BACK = Enum.EasingStyle.Back
local SINE = Enum.EasingStyle.Sine
local OUT, INOUT = Enum.EasingDirection.Out, Enum.EasingDirection.InOut

-------------------------------------------------------------------- palette

local BG_DIM    = Color3.new(0, 0, 0)
local PANEL     = Color3.fromRGB(19, 25, 38)
local PANEL_EDGE = Color3.fromRGB(52, 66, 92)
local CARD      = Color3.fromRGB(27, 35, 52)
local CARD_EMPTY = Color3.fromRGB(20, 25, 37)
local TEXT      = Color3.fromRGB(235, 240, 250)
local SUBTEXT   = Color3.fromRGB(146, 159, 184)
local ACCENT    = Color3.fromRGB(96, 214, 255)
local GOOD      = Color3.fromRGB(102, 224, 154)
local GOLD      = Color3.fromRGB(255, 205, 92)

-------------------------------------------------------------------- helpers

local function tw(inst, time, props, style, dir)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or QUAD, dir or OUT), props)
	t:Play(); return t
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 10)
	c.Parent = parent; return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color; s.Thickness = thickness or 1.4
	s.Transparency = transparency or 0.35
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent; return s
end

local function label(parent, text, size, color, font, align)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text; l.TextSize = size
	l.TextColor3 = color or TEXT
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Size = UDim2.new(1, 0, 0, size + 6)
	l.Parent = parent; return l
end

local function makeButton(parent, text, bg)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3 = bg
	b.Text = text; b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold; b.TextSize = 14
	b.Size = UDim2.new(1, 0, 1, 0)
	b.Parent = parent
	corner(b, UDim.new(0, 7))
	return b
end

-------------------------------------------------------------------- state

local slots         = {}
local previews      = {}
local previewsActive = false
local open          = false
local readyPulse    = nil

-------------------------------------------------------------------- root gui

local gui = Instance.new("ScreenGui")
gui.Name = "PetInventoryGui"; gui.ResetOnSpawn = false
gui.DisplayOrder = 20; gui.IgnoreGuiInset = false
gui.Parent = playerGui

-- dim backdrop
local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"; backdrop.AutoButtonColor = false
backdrop.Text = ""; backdrop.BackgroundColor3 = BG_DIM
backdrop.BackgroundTransparency = 1
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.Visible = false; backdrop.ZIndex = 1
backdrop.Parent = gui

-- toggle button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "Toggle"; toggleBtn.AutoButtonColor = false
toggleBtn.AnchorPoint = Vector2.new(1, 1)
toggleBtn.Position = UDim2.new(1, -22, 1, -22)
toggleBtn.Size = UDim2.fromOffset(66, 66)
toggleBtn.BackgroundColor3 = PANEL; toggleBtn.Text = ""
toggleBtn.ZIndex = 10; toggleBtn.Parent = gui
corner(toggleBtn, UDim.new(1, 0))
local toggleRing = stroke(toggleBtn, ACCENT, 1.6, 0.25)

local toggleIcon = Instance.new("TextLabel")
toggleIcon.BackgroundTransparency = 1
toggleIcon.Size = UDim2.fromScale(1, 1)
toggleIcon.Text = "\240\159\144\139" -- 🐋
toggleIcon.Font = Enum.Font.GothamBold; toggleIcon.TextSize = 28
toggleIcon.TextColor3 = TEXT
toggleIcon.TextXAlignment = Enum.TextXAlignment.Center
toggleIcon.TextYAlignment = Enum.TextYAlignment.Center
toggleIcon.Parent = toggleBtn

local readyDot = Instance.new("Frame")
readyDot.Name = "ReadyDot"; readyDot.AnchorPoint = Vector2.new(1, 0)
readyDot.Position = UDim2.new(1, 2, 0, -2)
readyDot.Size = UDim2.fromOffset(16, 16)
readyDot.BackgroundColor3 = GOLD; readyDot.Visible = false
readyDot.ZIndex = 11; readyDot.Parent = toggleBtn
corner(readyDot, UDim.new(1, 0))
stroke(readyDot, PANEL, 2, 0)

-- panel
local panel = Instance.new("Frame")
panel.Name = "Panel"; panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(590, 660)
panel.BackgroundColor3 = PANEL
panel.BackgroundTransparency = 1
panel.Visible = false
panel.ZIndex = 2; panel.Parent = gui
corner(panel, UDim.new(0, 18))
local panelStroke = stroke(panel, PANEL_EDGE, 1.4, 0.15)

local panelScale = Instance.new("UIScale")
panelScale.Scale = 0.9; panelScale.Parent = panel

-- header
local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, -40, 0, 58)
header.Position = UDim2.new(0, 20, 0, 16)
header.ZIndex = 3; header.Parent = panel

local titleLbl = label(header, "PET COLLECTION", 24, TEXT, Enum.Font.GothamBlack)
titleLbl.Size = UDim2.new(1, -40, 0, 30); titleLbl.ZIndex = 3

local subtitle = label(header, "0 / " .. PetConfig.MaxSlots .. " SLOTS FILLED", 14, SUBTEXT)
subtitle.Size = UDim2.new(1, -40, 0, 18)
subtitle.Position = UDim2.new(0, 0, 0, 30); subtitle.ZIndex = 3

local closeBtn = Instance.new("TextButton")
closeBtn.AutoButtonColor = false; closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, 0, 0, 2); closeBtn.Size = UDim2.fromOffset(30, 30)
closeBtn.BackgroundColor3 = CARD; closeBtn.Text = "X"
closeBtn.TextColor3 = SUBTEXT; closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14; closeBtn.ZIndex = 5; closeBtn.Parent = header
corner(closeBtn, UDim.new(1, 0))

local accentLine = Instance.new("Frame")
accentLine.BorderSizePixel = 0; accentLine.BackgroundColor3 = ACCENT
accentLine.Size = UDim2.new(1, -40, 0, 2)
accentLine.Position = UDim2.new(0, 20, 0, 76)
accentLine.ZIndex = 3; accentLine.Parent = panel
local lineGrad = Instance.new("UIGradient")
lineGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)
}); lineGrad.Parent = accentLine

local scroller = Instance.new("ScrollingFrame")
scroller.BackgroundTransparency = 1; scroller.BorderSizePixel = 0
scroller.Position = UDim2.new(0, 20, 0, 90)
scroller.Size = UDim2.new(1, -40, 1, -110)
scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.ScrollingDirection = Enum.ScrollingDirection.Y
scroller.ScrollBarThickness = 5
scroller.ScrollBarImageColor3 = ACCENT
scroller.ScrollBarImageTransparency = 0.3
scroller.ZIndex = 3; scroller.Parent = panel

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.fromOffset(170, 268)
grid.CellPadding = UDim2.fromOffset(12, 12)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = scroller

-------------------------------------------------------------------- viewport previews

local function clearPreview(index)
	local p = previews[index]
	if p then p.model:Destroy(); previews[index] = nil end
end

local function frameCamera(cam, model)
	local cf, size = model:GetBoundingBox()
	local r = math.max(size.Magnitude, 4)
	cam.CFrame = CFrame.lookAt(
		cf.Position + Vector3.new(r * 0.5, r * 0.34, -r * 0.78),
		cf.Position + Vector3.new(0, size.Y * 0.08, 0)
	)
end

local function setSlotPreview(index, speciesId, stage)
	clearPreview(index)
	local vp    = slots[index].viewport
	local model = Builder.Build(speciesId, stage, true)
	model.Parent = vp
	local cam = Instance.new("Camera")
	cam.FieldOfView = 32; cam.Parent = vp
	vp.CurrentCamera = cam
	frameCamera(cam, model)
	previews[index] = {
		model    = model,
		camera   = cam,
		animator = Builder.NewAnimator(model, true),
		t        = math.random() * 10,
	}
end

-------------------------------------------------------------------- card factory

local function createCard(index)
	local card = Instance.new("Frame")
	card.Name = "Slot" .. index; card.BackgroundColor3 = CARD_EMPTY
	card.LayoutOrder = index; card.ZIndex = 4; card.Parent = scroller
	corner(card, UDim.new(0, 12))
	local cardStroke = stroke(card, PANEL_EDGE, 1.4, 0.35)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = card

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6); list.Parent = card

	-- preview frame
	local previewFrame = Instance.new("Frame")
	previewFrame.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
	previewFrame.Size = UDim2.new(1, 0, 0, 104)
	previewFrame.LayoutOrder = 1; previewFrame.ClipsDescendants = true
	previewFrame.ZIndex = 4; previewFrame.Parent = card
	corner(previewFrame, UDim.new(0, 8))

	local vp = Instance.new("ViewportFrame")
	vp.BackgroundTransparency = 1; vp.Size = UDim2.fromScale(1, 1)
	vp.ZIndex = 4; vp.Parent = previewFrame

	local emptyLbl = Instance.new("TextLabel")
	emptyLbl.BackgroundTransparency = 1; emptyLbl.Text = "EMPTY SLOT"
	emptyLbl.Font = Enum.Font.GothamMedium; emptyLbl.TextSize = 13
	emptyLbl.TextColor3 = SUBTEXT; emptyLbl.TextTransparency = 0.3
	emptyLbl.TextXAlignment = Enum.TextXAlignment.Center
	emptyLbl.TextYAlignment = Enum.TextYAlignment.Center
	emptyLbl.Size = UDim2.fromScale(1, 1); emptyLbl.ZIndex = 5
	emptyLbl.Parent = previewFrame

	local equippedTag = Instance.new("TextLabel")
	equippedTag.BackgroundColor3 = GOOD; equippedTag.Text = "EQUIPPED"
	equippedTag.Font = Enum.Font.GothamBold; equippedTag.TextSize = 10
	equippedTag.TextColor3 = Color3.new(0, 0, 0)
	equippedTag.Position = UDim2.fromOffset(6, 6); equippedTag.Size = UDim2.fromOffset(66, 16)
	equippedTag.Visible = false; equippedTag.ZIndex = 6; equippedTag.Parent = previewFrame
	corner(equippedTag, UDim.new(1, 0))

	local nameLbl = label(card, "", 15, TEXT, Enum.Font.GothamBold)
	nameLbl.LayoutOrder = 2; nameLbl.Size = UDim2.new(1, 0, 0, 18); nameLbl.ZIndex = 5

	local subLbl = label(card, "", 12, SUBTEXT)
	subLbl.LayoutOrder = 3; subLbl.Size = UDim2.new(1, 0, 0, 14); subLbl.ZIndex = 5

	local xpBar = Instance.new("Frame")
	xpBar.BackgroundColor3 = Color3.fromRGB(12, 16, 25)
	xpBar.Size = UDim2.new(1, 0, 0, 16); xpBar.LayoutOrder = 4
	xpBar.ZIndex = 5; xpBar.Parent = card
	corner(xpBar, UDim.new(1, 0))

	local xpFill = Instance.new("Frame")
	xpFill.BackgroundColor3 = ACCENT; xpFill.BorderSizePixel = 0
	xpFill.Size = UDim2.new(0, 0, 1, 0); xpFill.ZIndex = 6; xpFill.Parent = xpBar
	corner(xpFill, UDim.new(1, 0))

	local xpText = Instance.new("TextLabel")
	xpText.BackgroundTransparency = 1; xpText.Size = UDim2.fromScale(1, 1)
	xpText.Text = ""; xpText.Font = Enum.Font.GothamMedium; xpText.TextSize = 11
	xpText.TextColor3 = TEXT; xpText.ZIndex = 7; xpText.Parent = xpBar

	local btnRow = Instance.new("Frame")
	btnRow.BackgroundTransparency = 1; btnRow.Size = UDim2.new(1, 0, 0, 30)
	btnRow.LayoutOrder = 5; btnRow.ZIndex = 5; btnRow.Parent = card

	local rowList = Instance.new("UIListLayout")
	rowList.FillDirection = Enum.FillDirection.Horizontal
	rowList.SortOrder = Enum.SortOrder.LayoutOrder
	rowList.Padding = UDim.new(0, 6); rowList.Parent = btnRow

	local equipBtn  = makeButton(btnRow, "EQUIP",  Color3.fromRGB(40, 70, 58))
	equipBtn.LayoutOrder = 1; equipBtn.ZIndex = 6

	local evolveBtn = makeButton(btnRow, "EVOLVE", GOLD)
	evolveBtn.TextColor3 = Color3.fromRGB(30, 22, 5); evolveBtn.LayoutOrder = 2
	evolveBtn.Size = UDim2.new(0.5, -3, 1, 0); evolveBtn.Visible = false
	evolveBtn.ZIndex = 6

	-- Release row — separate from action row so it's always below
	local releaseRow = Instance.new("Frame")
	releaseRow.BackgroundTransparency = 1
	releaseRow.Size = UDim2.new(1, 0, 0, 24)
	releaseRow.LayoutOrder = 6; releaseRow.ZIndex = 5
	releaseRow.Visible = false; releaseRow.Parent = card

	local releaseBtn = makeButton(releaseRow, "RELEASE TO WILD", Color3.fromRGB(90, 40, 40))
	releaseBtn.TextSize = 11; releaseBtn.ZIndex = 6

	-- Confirmation state: first click shows confirm prompt, second click fires release
	local releaseConfirming = false
	local releaseTimer      = nil

	local function resetReleaseBtn()
		releaseConfirming     = false
		releaseBtn.Text       = "RELEASE TO WILD"
		releaseBtn.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
		if releaseTimer then releaseTimer:Cancel(); releaseTimer = nil end
	end

	local debugBtn = nil
	if RunService:IsStudio() then
		debugBtn = Instance.new("TextButton")
		debugBtn.AutoButtonColor = false; debugBtn.BackgroundTransparency = 1
		debugBtn.Text = "+50 XP (Studio)"; debugBtn.Font = Enum.Font.Gotham
		debugBtn.TextSize = 10; debugBtn.TextColor3 = SUBTEXT
		debugBtn.Size = UDim2.new(1, 0, 0, 12); debugBtn.LayoutOrder = 7
		debugBtn.Visible = false; debugBtn.ZIndex = 6; debugBtn.Parent = card
	end

	local data = {
		frame        = card,
		strokeInst   = cardStroke,
		viewport     = vp,
		emptyLabel   = emptyLbl,
		equippedTag  = equippedTag,
		nameLabel    = nameLbl,
		subLabel     = subLbl,
		xpFill       = xpFill,
		xpText       = xpText,
		equipButton  = equipBtn,
		evolveButton = evolveBtn,
		releaseRow   = releaseRow,
		releaseBtn   = releaseBtn,
		debugButton  = debugBtn,
		petId        = nil,
		equipped     = false,
		lastKey      = nil,
		pulseTween   = nil,
	}
	slots[index] = data

	equipBtn.MouseButton1Click:Connect(function()
		if not data.petId then return end
		resetReleaseBtn()
		if data.equipped then
			PetEvent:FireServer("Unequip")
		else
			PetEvent:FireServer("Equip", data.petId)
		end
	end)

	evolveBtn.MouseButton1Click:Connect(function()
		if data.petId then PetEvent:FireServer("Evolve", data.petId) end
	end)

	releaseBtn.MouseButton1Click:Connect(function()
		if not data.petId then return end
		if not releaseConfirming then
			-- First click: ask for confirmation
			releaseConfirming           = true
			releaseBtn.Text             = "CONFIRM RELEASE ?"
			releaseBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
			-- Auto-reset after 3s if player doesn't confirm
			releaseTimer = TweenService:Create(
				releaseBtn,
				TweenInfo.new(3, Enum.EasingStyle.Linear),
				{ BackgroundColor3 = Color3.fromRGB(90, 40, 40) }
			)
			releaseTimer:Play()
			releaseTimer.Completed:Connect(function()
				if releaseConfirming then resetReleaseBtn() end
			end)
		else
			-- Second click: confirmed — fire release
			local petId = data.petId
			resetReleaseBtn()
			PetEvent:FireServer("ReleasePet", petId)
		end
	end)

	if debugBtn then
		debugBtn.MouseButton1Click:Connect(function()
			if data.petId then PetEvent:FireServer("DebugXP", data.petId) end
		end)
	end

	return data
end

for i = 1, PetConfig.MaxSlots do createCard(i) end

-------------------------------------------------------------------- sync

local function updateSlot(index, petData, equippedId)
	local c = slots[index]
	if not petData then
		c.frame.BackgroundColor3 = CARD_EMPTY
		if c.pulseTween then c.pulseTween:Cancel(); c.pulseTween = nil end
		c.strokeInst.Color = PANEL_EDGE; c.strokeInst.Thickness = 1.4; c.strokeInst.Transparency = 0.35
		c.viewport.Visible = false; c.emptyLabel.Visible = true; c.equippedTag.Visible = false
		c.nameLabel.Text = ""; c.subLabel.Text = ""
		c.xpFill.Size = UDim2.new(0, 0, 1, 0); c.xpText.Text = ""
		c.equipButton.Visible = false; c.evolveButton.Visible = false
		c.releaseRow.Visible = false
		if c.debugButton then c.debugButton.Visible = false end
		c.petId = nil; c.equipped = false; c.lastKey = nil
		clearPreview(index)
		return
	end

	local cfg        = PetConfig.GetStage(petData.Species, petData.Stage)
	local speciesCfg = PetConfig.Species[petData.Species]
	local isEquipped = petData.Id == equippedId
	local canEvolve  = isEquipped
		and cfg.XPToEvolve ~= nil
		and petData.XP >= cfg.XPToEvolve
		and PetConfig.GetStage(petData.Species, petData.Stage + 1) ~= nil

	c.frame.BackgroundColor3 = CARD
	c.viewport.Visible = true; c.emptyLabel.Visible = false
	c.equippedTag.Visible = isEquipped
	local nick = (type(petData.Nickname) == "string" and petData.Nickname ~= "") and petData.Nickname or nil
	c.nameLabel.Text = nick or cfg.Name
	c.subLabel.Text  = (nick and (cfg.Name .. " \226\128\162 ") or "")
		.. speciesCfg.DisplayName
		.. " \226\128\162 Stage " .. petData.Stage
		.. "/" .. PetConfig.GetMaxStage(petData.Species)

	c.equipButton.Visible = true
	c.equipButton.Text = isEquipped and "UNEQUIP" or "EQUIP"
	c.equipButton.BackgroundColor3 = isEquipped
		and Color3.fromRGB(74, 40, 40)
		or  Color3.fromRGB(40, 70, 58)
	c.evolveButton.Visible = canEvolve
	c.releaseRow.Visible   = true
	c.equipButton.Size = canEvolve
		and UDim2.new(0.5, -3, 1, 0)
		or  UDim2.new(1, 0, 1, 0)
	c.petId    = petData.Id
	c.equipped = isEquipped

	if cfg.XPToEvolve then
		local pct = math.clamp(petData.XP / cfg.XPToEvolve, 0, 1)
		tw(c.xpFill, 0.25, { Size = UDim2.new(pct, 0, 1, 0) })
		c.xpFill.BackgroundColor3 = ACCENT
		c.xpText.Text = petData.XP .. " / " .. cfg.XPToEvolve .. " XP"
	else
		c.xpFill.Size = UDim2.new(1, 0, 1, 0)
		c.xpFill.BackgroundColor3 = GOOD
		c.xpText.Text = "MAX FORM"
	end

	if c.debugButton then c.debugButton.Visible = true end

	if canEvolve then
		c.strokeInst.Color = GOLD; c.strokeInst.Thickness = 2
		if not c.pulseTween then
			c.strokeInst.Transparency = 0.15
			c.pulseTween = TweenService:Create(
				c.strokeInst,
				TweenInfo.new(0.9, SINE, INOUT, -1, true),
				{ Transparency = 0.65 }
			)
			c.pulseTween:Play()
		end
	else
		if c.pulseTween then c.pulseTween:Cancel(); c.pulseTween = nil end
		c.strokeInst.Color = cfg.Colors and cfg.Colors.Glow or ACCENT
		c.strokeInst.Thickness = 1.4; c.strokeInst.Transparency = 0.35
	end

	local key = petData.Species .. tostring(petData.Stage)
	if c.lastKey ~= key then
		c.lastKey = key
		setSlotPreview(index, petData.Species, petData.Stage)
	end
end

local function applySync(payload)
	-- PetManager snapshot sends capital keys: Pets, Equipped
	local pets       = (payload and payload.Pets) or {}
	local equippedId = payload and payload.Equipped
	local anyReady   = false

	for i = 1, PetConfig.MaxSlots do
		local pd = pets[i]
		updateSlot(i, pd, equippedId)
		if pd and pd.Id == equippedId then
			local cfg = PetConfig.GetStage(pd.Species, pd.Stage)
			if cfg.XPToEvolve and pd.XP >= cfg.XPToEvolve
				and PetConfig.GetStage(pd.Species, pd.Stage + 1) then
				anyReady = true
			end
		end
	end

	subtitle.Text = #pets .. " / " .. PetConfig.MaxSlots .. " SLOTS FILLED"
	readyDot.Visible = anyReady

	if anyReady and not readyPulse then
		readyDot.Size = UDim2.fromOffset(16, 16)
		readyPulse = TweenService:Create(
			readyDot,
			TweenInfo.new(0.7, SINE, INOUT, -1, true),
			{ Size = UDim2.fromOffset(12, 12) }
		)
		readyPulse:Play()
	elseif not anyReady and readyPulse then
		readyPulse:Cancel(); readyPulse = nil
		readyDot.Size = UDim2.fromOffset(16, 16)
	end
end

PetEvent.OnClientEvent:Connect(function(action, payload)
	if action == "Sync" then applySync(payload) end
end)
PetEvent:FireServer("RequestSync")

-------------------------------------------------------------------- open / close

local function setOpen(show)
	if show == open then return end
	open = show
	if show then
		PetEvent:FireServer("RequestSync")
		backdrop.Visible = true; panel.Visible = true
		tw(backdrop,   0.25, { BackgroundTransparency = 0.45 })
		tw(panel,      0.25, { BackgroundTransparency = 0 })
		tw(panelScale, 0.28, { Scale = 1 }, BACK, OUT)
		toggleRing.Color = ACCENT; toggleRing.Transparency = 0
		previewsActive = true
	else
		tw(backdrop,   0.2,  { BackgroundTransparency = 1 })
		tw(panel,      0.2,  { BackgroundTransparency = 1 })
		tw(panelScale, 0.2,  { Scale = 0.92 })
		toggleRing.Transparency = 0.25
		previewsActive = false
		task.delay(0.22, function()
			if not open then
				backdrop.Visible = false; panel.Visible = false
				panel.BackgroundTransparency = 1
			end
		end)
	end
end

toggleBtn.MouseButton1Click:Connect(function() setOpen(not open) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
backdrop.MouseButton1Click:Connect(function() setOpen(false) end)

player:GetAttributeChangedSignal("PetCinematic"):Connect(function()
	local cinematic = player:GetAttribute("PetCinematic")
	toggleBtn.Visible = not cinematic
	if cinematic then setOpen(false) end
end)

-------------------------------------------------------------------- preview loop

RunService.Heartbeat:Connect(function(dt)
	if not previewsActive then return end
	for _, p in previews do
		p.t += dt
		p.animator.Step(p.t, 1)
	end
end)