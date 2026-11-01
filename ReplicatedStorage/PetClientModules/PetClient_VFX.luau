--[[
	PetClient_VFX (ModuleScript -> ReplicatedStorage/PetClientModules)

	Visual-effect primitives and high-level VFX sequences:
	  - spark rings, pillars, particle bursts, light flashes, shard gathers
	  - summon, evolve buildup/reveal

	Split from the original monolithic PetClient.lua so VFX can be tuned
	without touching gameplay state machines.

	SCAN FIXES APPLIED:
	  1. burst(): was `e.Parent = e:Emit(count)` -> parented the emitter to
	     Emit()'s (nil) return and never emitted. Now parents to `a` and emits.
	  2. summonVFX(): duplicated `drop` / `ground` / `bodyPart` blocks removed;
	     single validated path using `body` (a BasePart).
	  3. Easing enums resolved locally from Enum.* so this module no longer
	     depends on Helpers exporting SINE/QUAD/QUART/IN/OUT/INOUT (that was
	     the "second argument expects Enum.EasingStyle" crash).
	  4. Helpers.nextNumber / randUnitVector replaced with local functions so
	     shard VFX can't crash if Helpers is the older copy.
	  5. Require path now matches the live folder (PetClientModules).
]]
-- v1.0.0.0.1
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModulesFolder = ReplicatedStorage:WaitForChild("PetClientModules")
local Helpers   = require(ModulesFolder:WaitForChild("PetClient_Helpers"))
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local VFX = {}

------------------------------------------------------------------ easing enums

-- Resolved directly from Enum so this module never depends on Helpers
-- re-exporting them.
local SINE  = Enum.EasingStyle.Sine
local QUAD  = Enum.EasingStyle.Quad
local QUART = Enum.EasingStyle.Quart

local IN    = Enum.EasingDirection.In
local OUT   = Enum.EasingDirection.Out
local INOUT = Enum.EasingDirection.InOut

------------------------------------------------------------------ local math helpers

-- Self-contained so shard VFX never depends on Helpers for these.
local function nextNumber(a, b)
	return a + math.random() * (b - a)
end

local function randUnitVector()
	local theta = math.random() * math.pi * 2
	local phi   = math.acos(2 * math.random() - 1)
	return Vector3.new(
		math.sin(phi) * math.cos(theta),
		math.sin(phi) * math.sin(theta),
		math.cos(phi)
	)
end

local WHITE = Color3.new(1, 1, 1)

------------------------------------------------------------------ primitives

function VFX.spawnRing(center, startD, endD, duration, color, delay)
	task.delay(delay or 0, function()
		local part = Instance.new("Part")
		part.Anchored = true; part.CanCollide = false; part.CanQuery = false; part.CanTouch = false
		part.Transparency = 1; part.Size = Vector3.new(startD, 0.2, startD)
		part.CFrame = CFrame.new(center + Vector3.new(0, 0.25, 0)); part.Parent = workspace

		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Top; gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		gui.CanvasSize = Vector2.new(512, 512); gui.LightInfluence = 0; gui.Brightness = 2
		gui.Parent = part

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1); frame.BackgroundTransparency = 1; frame.Parent = gui

		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = frame

		local s = Instance.new("UIStroke"); s.Color = color; s.Thickness = 14; s.Parent = frame

		TweenService:Create(part, TweenInfo.new(duration, QUART, OUT),
			{ Size = Vector3.new(endD, 0.2, endD) }):Play()
		TweenService:Create(s, TweenInfo.new(duration, QUAD, IN),
			{ Transparency = 1 }):Play()

		Debris:AddItem(part, duration + 0.2)
	end)
end

function VFX.spawnPillar(base, height, radius, duration, color)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder; p.Anchored = true; p.CanCollide = false
	p.CanQuery = false; p.CanTouch = false; p.Material = Enum.Material.Neon
	p.Color = color; p.Transparency = 0.35
	p.Size = Vector3.new(height, radius * 2, radius * 2)
	p.CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	p.Parent = workspace

	TweenService:Create(p, TweenInfo.new(duration, QUAD, OUT),
		{ Size = Vector3.new(height, 0.4, 0.4), Transparency = 1 }):Play()

	Debris:AddItem(p, duration + 0.1)
end

function VFX.burst(pos, count, color, sMin, sMax, sz, life, spread)
	local a = Instance.new("Part")
	a.Anchored = true; a.CanCollide = false; a.CanQuery = false; a.CanTouch = false
	a.Transparency = 1; a.Size = Vector3.one * 0.2; a.Position = pos; a.Parent = workspace

	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(color); e.LightEmission = 1
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, sz),
		NumberSequenceKeypoint.new(1, 0)
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1)
	})
	e.Lifetime = NumberRange.new(life * 0.6, life)
	e.Speed = NumberRange.new(sMin, sMax)
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Drag = 2; e.Rate = 0

	-- FIX: parent to the host part, then emit. (Was: e.Parent = e:Emit(count))
	e.Parent = a
	e:Emit(count)

	Debris:AddItem(a, life + 0.5)
end

function VFX.flashLight(pos, color, peak, duration)
	local a = Instance.new("Part")
	a.Anchored = true; a.CanCollide = false; a.CanQuery = false; a.CanTouch = false
	a.Transparency = 1; a.Size = Vector3.one * 0.2; a.Position = pos; a.Parent = workspace

	local l = Instance.new("PointLight")
	l.Color = color; l.Range = 45; l.Brightness = peak; l.Parent = a

	TweenService:Create(l, TweenInfo.new(duration, QUAD, OUT), { Brightness = 0 }):Play()
	Debris:AddItem(a, duration + 0.1)
end

function VFX.gatherShards(userId, count, duration, color, petsFolder)
	for _ = 1, count do
		task.delay(nextNumber(0, duration * 0.8), function()
			local body = Helpers.petBody(userId, petsFolder)
			if not body then return end

			local target = body.Position
			local origin = target + randUnitVector() * nextNumber(14, 26)

			local s = Instance.new("Part")
			s.Anchored = true; s.CanCollide = false; s.CanQuery = false; s.CanTouch = false
			s.Material = Enum.Material.Neon; s.Color = color
			s.Size = Vector3.new(0.2, 0.2, 2.4)
			s.CFrame = CFrame.lookAt(origin, target); s.Parent = workspace

			local travel = nextNumber(0.5, 0.8)
			TweenService:Create(s, TweenInfo.new(travel, QUAD, IN), {
				CFrame = CFrame.lookAt(target, target + (target - origin)),
				Transparency = 1
			}):Play()

			Debris:AddItem(s, travel + 0.1)
		end)
	end
end

------------------------------------------------------------------ sequences

function VFX.summonVFX(model, petsFolder)
	local body = model:WaitForChild("Body", 3)
	local cfg  = Helpers.stageCfgOf(model)
	if not body or not cfg then
		return body and body.Position or Vector3.zero
	end
	if not body:IsA("BasePart") then
		warn("[PetClient_VFX] summonVFX: body is not a BasePart:", body)
		return
	end

	local glow, scale = cfg.Colors.Glow, cfg.Scale

	-- How far below the follow spot the pet starts, so it can rise out.
	local drop = 8
	if type(PetConfig.SummonDrop) == "function" then
		local ok, r = pcall(PetConfig.SummonDrop, cfg)
		if ok and type(r) == "number" then drop = r end
	end
	drop = tonumber(drop) or 0

	local ground = Helpers.groundBelow(
		body.Position + Vector3.new(0, drop, 0),
		petsFolder,
		nil
	)

	VFX.spawnRing(ground, 2, 14 + 14 * scale, 1.2, glow, 0)
	VFX.spawnRing(ground, 2, 22 + 20 * scale, 1.6, WHITE, 0.15)
	VFX.spawnPillar(ground, 40, 2 + 2 * scale, 1.1, glow)
	VFX.burst(ground + Vector3.new(0, 1, 0), 60, glow, 14, 30, 0.9, 1.4, 25)
	VFX.flashLight(ground + Vector3.new(0, 3, 0), glow, 6, 1.2)

	task.delay(0.5, function()
		VFX.burst(ground + Vector3.new(0, 2, 0), 40, WHITE, 8, 20, 0.6, 1.2, 60)
	end)
	task.delay(0.35, function()
		Helpers.fadeInModel(model, 0.9)
	end)

	return ground
end

function VFX.evolveBuildupVFX(userId, duration, petsFolder)
	local body = Helpers.petBody(userId, petsFolder)
	if not body then return end
	local cfg = Helpers.stageCfgOf(body.Parent)
	if not cfg then return end

	local hi = Instance.new("Highlight")
	hi.FillColor = WHITE; hi.OutlineColor = cfg.Colors.Glow
	hi.FillTransparency = 1; hi.OutlineTransparency = 0.4
	hi.DepthMode = Enum.HighlightDepthMode.Occluded; hi.Parent = body.Parent

	TweenService:Create(hi, TweenInfo.new(duration, QUAD, IN), { FillTransparency = 0 }):Play()

	VFX.gatherShards(userId, 30, duration, cfg.Colors.Glow, petsFolder)

	local ground = Helpers.groundBelow(body.Position, petsFolder, nil)
	VFX.spawnRing(ground, 24 + 10 * cfg.Scale, 3, duration * 0.5, cfg.Colors.Glow, 0.2)
	VFX.spawnRing(ground, 24 + 10 * cfg.Scale, 3, duration * 0.5, WHITE, duration * 0.5)
end

function VFX.evolveRevealVFX(userId, petsFolder)
	local body = Helpers.petBody(userId, petsFolder)
	if not body then return end
	local cfg = Helpers.stageCfgOf(body.Parent)
	if not cfg then return end

	local glow, scale = cfg.Colors.Glow, cfg.Scale
	local pos    = body.Position
	local ground = Helpers.groundBelow(pos, petsFolder, nil)

	VFX.spawnRing(ground, 4, 60 + 30 * scale, 1.5, glow, 0)
	VFX.spawnRing(ground, 4, 95 + 40 * scale, 2.0, WHITE, 0.12)
	VFX.spawnRing(ground, 4, 40, 1.1, glow, 0.3)
	VFX.spawnPillar(ground, 80, 3 + 3 * scale, 1.4, glow)
	VFX.burst(pos, 140, glow, 25, 70, 1.4, 1.8, 180)
	VFX.flashLight(pos, WHITE, 10, 1.4)

	local hi = Instance.new("Highlight")
	hi.FillColor = WHITE; hi.OutlineColor = glow
	hi.FillTransparency = 0; hi.OutlineTransparency = 0.2
	hi.Parent = body.Parent

	TweenService:Create(hi, TweenInfo.new(3.4, QUAD, OUT),
		{ FillTransparency = 1, OutlineTransparency = 1 }):Play()

	Debris:AddItem(hi, 3.6)
end

return VFX