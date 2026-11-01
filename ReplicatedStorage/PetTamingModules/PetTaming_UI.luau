-- v1.0.0.0.1
--[[
	PetTaming_UI (ModuleScript -> ReplicatedStorage/PetClientModules)

	All on-screen pieces of the taming ceremony: letterbox, fade/flash, captions,
	stat card, nickname prompt, end prompt, nickname tag. Panels scale with the
	viewport (phones included). Everything is parented to one ScreenGui that the
	janitor destroys.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")

local Config = require(TamingModules:WaitForChild("PetTaming_Config"))
local Util   = require(TamingModules:WaitForChild("PetTaming_Util"))

local C = Config.Colors
local QUAD, BACK = Enum.EasingStyle.Quad, Enum.EasingStyle.Back
local EOUT, EIN = Enum.EasingDirection.Out, Enum.EasingDirection.In

local UI = {}
UI.__index = UI

-------------------------------------------------------------------- helpers

local function tw(inst, time, props, style, dir)
	local tween = TweenService:Create(inst, TweenInfo.new(time, style or QUAD, dir or EOUT), props)
	tween:Play()
	return tween
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color, s.Thickness, s.Transparency = color, thickness or 2, transparency or 0.2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function text(parent, str, size, color, font, order, height)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text, l.TextSize, l.TextColor3 = str, size, color
	l.Font = font or Enum.Font.GothamMedium
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.LayoutOrder = order or 0
	l.Size = UDim2.new(1, 0, 0, height or size + 6)
	l.ZIndex = 32
	l.Parent = parent
	return l
end

local function button(parent, str, bg, fg)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3, b.Text, b.TextColor3 = bg, str, fg or C.Text
	b.Font, b.TextSize, b.ZIndex = Enum.Font.GothamBold, 15, 32
	b.Parent = parent
	corner(b, 9)
	b.MouseEnter:Connect(function() tw(b, 0.12, { BackgroundTransparency = 0.15 }) end)
	b.MouseLeave:Connect(function() tw(b, 0.12, { BackgroundTransparency = 0 }) end)
	return b
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clampText(s, max)
	s = s:gsub("%c", "")
	if not utf8.len(s) then return "" end
	if utf8.len(s) > max then s = s:sub(1, utf8.offset(s, max + 1) - 1) end
	return s
end

-------------------------------------------------------------------- build

function UI.new(playerGui, janitor, accent)
	local self = setmetatable({ accent = accent, janitor = janitor, scales = {}, playerGui = playerGui }, UI)

	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "TameCinemaUI", false, 60, true
	gui.Parent = playerGui
	janitor:add(gui)
	self.gui = gui

	local function layer(name, z, color, transparency)
		local f = Instance.new("Frame")
		f.Name, f.ZIndex, f.BorderSizePixel = name, z, 0
		f.BackgroundColor3, f.BackgroundTransparency = color, transparency
		f.Size = UDim2.fromScale(1, 1)
		f.Parent = gui
		return f
	end
	self.fadeF  = layer("Fade", 90, Color3.new(0, 0, 0), 0) -- starts black
	self.flashF = layer("Flash", 95, Color3.new(1, 1, 1), 1)

	local function bar(name, y)
		local f = layer(name, 100, Color3.new(0, 0, 0), 0)
		f.Size = UDim2.fromScale(1, 0.12)
		f.Position = UDim2.fromScale(0, y)
		return f
	end
	self.top, self.bottom = bar("LetterboxTop", -0.12), bar("LetterboxBottom", 1)

	local cam = Workspace.CurrentCamera
	janitor:add(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function() self:_rescale() end))
	return self
end

function UI:_rescale()
	local s = math.clamp(Workspace.CurrentCamera.ViewportSize.Y / 760, 0.62, 1.3)
	for _, u in self.scales do u.Scale = s end
end

function UI:_scaled(frame)
	local u = Instance.new("UIScale")
	u.Parent = frame
	table.insert(self.scales, u)
	self:_rescale()
end

-- Bottom-anchored panel that slides up into place.
function UI:_panel(width, y)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.new(0.5, 0, y + 0.1, 0)
	f.Size = UDim2.fromOffset(width, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3, f.BackgroundTransparency, f.ZIndex = C.Panel, 0.08, 30
	f.Parent = self.gui
	corner(f, 16)
	stroke(f, self.accent, 2, 0.2)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 16), UDim.new(0, 16)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 18), UDim.new(0, 18)
	pad.Parent = f

	local list = Instance.new("UIListLayout")
	list.SortOrder, list.Padding = Enum.SortOrder.LayoutOrder, UDim.new(0, 10)
	list.Parent = f

	self:_scaled(f)
	tw(f, 0.5, { Position = UDim2.new(0.5, 0, y, 0) }, BACK, EOUT)
	return f
end

local function dismiss(f)
	tw(f, 0.35, { Position = UDim2.new(0.5, 0, 1.2, 0) }, QUAD, EIN)
	task.delay(0.4, function() if f.Parent then f:Destroy() end end)
end

-------------------------------------------------------------------- screen layers

function UI:fade(alpha, duration)
	return tw(self.fadeF, duration, { BackgroundTransparency = alpha })
end

function UI:bars(show, duration)
	tw(self.top, duration, { Position = UDim2.fromScale(0, show and 0 or -0.12) })
	tw(self.bottom, duration, { Position = UDim2.fromScale(0, show and 0.88 or 1) })
end

function UI:flash(color, alpha, duration)
	self.flashF.BackgroundColor3 = color
	self.flashF.BackgroundTransparency = 1 - alpha
	tw(self.flashF, duration, { BackgroundTransparency = 1 })
end

function UI:caption(str, hold)
	if not self.cap then
		local l = Instance.new("TextLabel")
		l.AnchorPoint, l.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.94)
		l.Size, l.BackgroundTransparency = UDim2.fromScale(0.9, 0.06), 1
		l.Font, l.TextSize, l.TextColor3 = Enum.Font.GothamMedium, 20, C.Text
		l.TextTransparency, l.ZIndex = 1, 101
		l.Parent = self.gui
		self.cap = l
	end
	self.capToken = (self.capToken or 0) + 1
	local token = self.capToken
	self.cap.Text = str
	tw(self.cap, 0.4, { TextTransparency = 0 })
	task.delay(hold or 2.2, function()
		if self.capToken == token and self.cap.Parent then tw(self.cap, 0.5, { TextTransparency = 1 }) end
	end)
end

-------------------------------------------------------------------- stat card

-- info: { title, species, color, rows = { {Label, Text, Number?, Format?} } }
function UI:showStats(info)
	local card = Instance.new("Frame")
	card.Name = "StatCard"
	card.AnchorPoint = Vector2.new(0, 0.5)
	card.Position = UDim2.new(0.03, -360, 0.46, 0)
	card.Size = UDim2.fromOffset(300, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3, card.BackgroundTransparency, card.ZIndex = C.Panel, 0.1, 20
	card.Parent = self.gui
	corner(card, 16)
	stroke(card, info.color, 2, 0.1)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 18), UDim.new(0, 18)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 18), UDim.new(0, 18)
	pad.Parent = card
	local list = Instance.new("UIListLayout")
	list.SortOrder, list.Padding = Enum.SortOrder.LayoutOrder, UDim.new(0, 8)
	list.Parent = card

	local sub = text(card, string.upper(info.species or ""), 12, C.Sub, Enum.Font.GothamBold, 1, 16)
	sub.ZIndex = 21
	local title = text(card, info.title or "", 26, C.Text, Enum.Font.GothamBlack, 2, 32)
	title.ZIndex = 21
	local nick = text(card, "", 18, C.Gold, Enum.Font.GothamBold, 3, 24)
	nick.ZIndex, nick.Visible = 21, false

	local line = Instance.new("Frame")
	line.BorderSizePixel, line.BackgroundColor3 = 0, info.color
	line.Size, line.LayoutOrder, line.ZIndex = UDim2.new(1, 0, 0, 2), 4, 21
	line.Parent = card

	self:_scaled(card)
	tw(card, 0.75, { Position = UDim2.new(0.03, 0, 0.46, 0) }, BACK, EOUT)

	for i, row in ipairs(info.rows) do
		local r = Instance.new("Frame")
		r.LayoutOrder, r.Size, r.ZIndex = 10 + i, UDim2.new(1, 0, 0, 36), 21
		r.BackgroundColor3, r.BackgroundTransparency, r.Visible = info.color, 1, false
		r.Parent = card
		corner(r, 8)

		local lab = text(r, row.Label, 13, C.Sub, Enum.Font.GothamBold, 0, 36)
		lab.Position, lab.Size, lab.ZIndex = UDim2.fromOffset(10, 0), UDim2.new(0.5, 0, 1, 0), 22
		local val = text(r, row.Text, 20, C.Text, Enum.Font.GothamBold, 0, 36)
		val.Position, val.Size, val.ZIndex = UDim2.new(0.4, 0, 0, 0), UDim2.new(0.6, -10, 1, 0), 22
		val.TextXAlignment = Enum.TextXAlignment.Right
		if row.Number then val.Text = string.format(row.Format, 0) end

		task.delay(0.55 + 0.22 * i, function()
			if not r.Parent then return end
			r.Visible = true
			r.BackgroundTransparency = 0.45 -- flash
			tw(r, 0.6, { BackgroundTransparency = 0.88 })
			if row.Number then
				task.spawn(Util.animate, 0.9, function(a)
					if val.Parent then val.Text = string.format(row.Format, row.Number * a) end
				end, Util.ease.outCubic)
			end
		end)
	end

	self.statCard, self.nickLabel = card, nick
end

function UI:setNickname(name)
	if not self.nickLabel or not self.nickLabel.Parent then return end
	self.nickLabel.Text = '"' .. name .. '"'
	self.nickLabel.TextTransparency = 1
	self.nickLabel.Visible = true
	tw(self.nickLabel, 0.5, { TextTransparency = 0 })
end

-------------------------------------------------------------------- nickname prompt

-- opts: { min, max, suggestions }. Yields until submitted; returns text (nil if aborted).
function UI:askNickname(opts)
	local ev = Instance.new("BindableEvent")
	self.janitor:add(ev)
	self.janitor:add(function() ev:Fire(nil) end) -- releases the waiter on abort

	local min, max = opts.min or 1, opts.max or 16
	local f = self:_panel(440, 0.845)
	self.nickPanel = f

	local title = text(f, "NAME YOUR COMPANION", 17, self.accent, Enum.Font.GothamBlack, 1, 22)
	title.TextXAlignment = Enum.TextXAlignment.Center
	local hint = text(f, "This name will stay with them.", 13, C.Sub, Enum.Font.GothamMedium, 2, 16)
	hint.TextXAlignment = Enum.TextXAlignment.Center

	local boxRow = Instance.new("Frame")
	boxRow.BackgroundColor3, boxRow.LayoutOrder, boxRow.ZIndex = Color3.fromRGB(10, 13, 22), 3, 31
	boxRow.Size = UDim2.new(1, 0, 0, 46)
	boxRow.Parent = f
	corner(boxRow, 10)
	stroke(boxRow, self.accent, 1.5, 0.55)

	local box = Instance.new("TextBox")
	box.BackgroundTransparency, box.ClearTextOnFocus = 1, false
	box.PlaceholderText, box.PlaceholderColor3 = "Enter a nickname...", C.Sub
	box.Text, box.TextColor3, box.Font, box.TextSize = "", C.Text, Enum.Font.GothamMedium, 20
	box.TextXAlignment, box.ZIndex = Enum.TextXAlignment.Left, 33
	box.Position, box.Size = UDim2.fromOffset(14, 0), UDim2.new(1, -74, 1, 0)
	box.Parent = boxRow

	local counter = text(boxRow, "0/" .. max, 13, C.Sub, Enum.Font.GothamMedium, 0, 46)
	counter.Position, counter.Size = UDim2.new(1, -62, 0, 0), UDim2.fromOffset(52, 46)
	counter.TextXAlignment, counter.ZIndex = Enum.TextXAlignment.Right, 33

	local row = Instance.new("Frame")
	row.BackgroundTransparency, row.LayoutOrder, row.Size = 1, 4, UDim2.new(1, 0, 0, 42)
	row.Parent = f
	local rl = Instance.new("UIListLayout")
	rl.FillDirection, rl.Padding = Enum.FillDirection.Horizontal, UDim.new(0, 8)
	rl.Parent = row

	local suggest = button(row, "Suggest", C.Dark)
	suggest.Size = UDim2.new(0.36, -4, 1, 0)
	local confirm = button(row, "Confirm", self.accent, Color3.fromRGB(10, 14, 22))
	confirm.Size = UDim2.new(0.64, -4, 1, 0)

	local locked = false
	local function valid()
		local n = utf8.len(trim(box.Text)) or 0
		return n >= min and n <= max
	end
	local function refresh()
		counter.Text = (utf8.len(box.Text) or 0) .. "/" .. max
		local ok = valid()
		confirm.BackgroundColor3 = ok and self.accent or C.Dark
		confirm.TextTransparency = ok and 0 or 0.5
	end
	refresh()

	box:GetPropertyChangedSignal("Text"):Connect(function()
		local clean = clampText(box.Text, max)
		if clean ~= box.Text then box.Text = clean return end
		refresh()
	end)

	local function submit()
		if locked then return end
		if not valid() then
			tw(f, 0.06, { Rotation = 1.5 }).Completed:Connect(function() tw(f, 0.12, { Rotation = 0 }, BACK, EOUT) end)
			return
		end
		locked = true
		box.TextEditable = false
		confirm.Text = "Naming..."
		Util.sound("Confirm")
		ev:Fire(trim(box.Text))
	end

	confirm.MouseButton1Click:Connect(submit)
	box.FocusLost:Connect(function(enter) if enter then submit() end end)
	suggest.MouseButton1Click:Connect(function()
		if locked then return end
		local list = opts.suggestions
		if list and #list > 0 then box.Text = list[math.random(#list)] end
	end)

	task.delay(0.6, function() if box.Parent and not locked then box:CaptureFocus() end end)
	return ev.Event:Wait()
end

function UI:hideNickname()
	if self.nickPanel and self.nickPanel.Parent then dismiss(self.nickPanel) end
	self.nickPanel = nil
end

-- Floating name tag above the pet.
function UI:nameTag(adornee, name, studsUp)
	local bb = Instance.new("BillboardGui")
	bb.Adornee, bb.AlwaysOnTop, bb.LightInfluence = adornee, true, 0
	bb.Size, bb.StudsOffset = UDim2.fromOffset(300, 70), Vector3.new(0, studsUp, 0)
	bb.Parent = self.playerGui
	self.janitor:add(bb)

	local l = Instance.new("TextLabel")
	l.BackgroundTransparency, l.Size = 1, UDim2.fromScale(1, 1)
	l.Text, l.Font, l.TextSize, l.TextColor3 = name, Enum.Font.GothamBlack, 36, C.Gold
	l.TextStrokeTransparency, l.TextStrokeColor3 = 0.2, Color3.new(0, 0, 0)
	l.Parent = bb
	local s = Instance.new("UIScale")
	s.Scale = 0
	s.Parent = l
	tw(s, 0.6, { Scale = 1 }, BACK, EOUT)
end

-------------------------------------------------------------------- end prompt

-- Yields until the player chooses to end. Returns "end" (nil if aborted).
function UI:askEnd()
	local ev = Instance.new("BindableEvent")
	self.janitor:add(ev)
	self.janitor:add(function() ev:Fire(nil) end)

	local f = self:_panel(420, 0.86)
	local title = text(f, "END THE ANIMATION?", 17, self.accent, Enum.Font.GothamBlack, 1, 22)
	title.TextXAlignment = Enum.TextXAlignment.Center
	local hint = text(f, "Your companion is ready to join you.", 13, C.Sub, Enum.Font.GothamMedium, 2, 16)
	hint.TextXAlignment = Enum.TextXAlignment.Center

	local row = Instance.new("Frame")
	row.BackgroundTransparency, row.LayoutOrder, row.Size = 1, 3, UDim2.new(1, 0, 0, 42)
	row.Parent = f
	local rl = Instance.new("UIListLayout")
	rl.FillDirection, rl.Padding = Enum.FillDirection.Horizontal, UDim.new(0, 8)
	rl.Parent = row

	local keep = button(row, "Keep watching", C.Dark)
	keep.Size = UDim2.new(0.5, -4, 1, 0)
	local yes = button(row, "End", self.accent, Color3.fromRGB(10, 14, 22))
	yes.Size = UDim2.new(0.5, -4, 1, 0)

	yes.MouseButton1Click:Connect(function() ev:Fire("end") end)
	keep.MouseButton1Click:Connect(function()
		dismiss(f)
		local mini = button(self.gui, "End  >", C.Panel)
		mini.AnchorPoint, mini.Position, mini.Size = Vector2.new(1, 1), UDim2.fromScale(0.97, 0.86), UDim2.fromOffset(120, 38)
		stroke(mini, self.accent, 1.5, 0.3)
		self:_scaled(mini)
		mini.MouseButton1Click:Connect(function() ev:Fire("end") end)
	end)
	return ev.Event:Wait()
end

return UI