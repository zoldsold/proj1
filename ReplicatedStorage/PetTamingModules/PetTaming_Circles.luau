-- v1.0.0.2
--[[
	PetTaming_Circles (ModuleScript -> ReplicatedStorage/PetTamingModules)

	World-space effect primitives for the taming ceremony. Client-only: zero server cost, zero
	replication. Everything long-lived is registered with a janitor so nothing can leak.
	Every tunable lives in PetTamingConfig.Effects; this file holds no magic numbers.

	  Circles.new    glowing seal on a flat part (spin, flicker, ring layer, soft halo, point light)
	  Circles.motes  particles gathering into a circle
	  Circles.links  optional vertical filaments between circles (Effects.Links.Enabled)
	  Circles.crack  jagged cracks across a circle
	  Circles.burst  one-shot burst: sparks + embers + shockwave ring + light flash
	  Circles.storm  light column + storm cloud + rain  (storm.flash() = thunder light)

	CHANGES v1.0.0.2: all constants moved to Config.Effects; lightning arcs (the lines inside the
	circles) removed; links are opt-in.
]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")
local Workspace         = game:GetService("Workspace")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")
local Config = require(TamingModules:WaitForChild("PetTaming_Config"))
local Util   = require(TamingModules:WaitForChild("PetTaming_Util"))

local FX = assert(Config.Effects, "PetTaming_Config.Effects is missing: paste PetTaming_Config.lua v1.0.0.2")

local Circles = {}
Circles.STORM_HEIGHT = FX.Storm.Height

local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

-------------------------------------------------------------------- images

local FULL_ID, RING_ID, TINTABLE
do
	local full, ring = Config.Images.Full, Config.Images.Ring
	TINTABLE = full ~= ""
	if full == "" then
		full = "rbxassetid://0"
		local inst = ReplicatedStorage:FindFirstChild("MagicCircleConfig")
		if inst then
			local ok, cfg = pcall(require, inst)
			if ok and type(cfg) == "table" and cfg.ImageId then full = cfg.ImageId end
		end
	end
	if ring == "" then ring = full end
	FULL_ID, RING_ID = full, ring
	if full == "rbxassetid://0" then
		warn("[PetTaming] No circle image set (PetTamingConfig.Images.Full). Circles will be invisible.")
	end
end

-------------------------------------------------------------------- helpers

local function range(r) return NumberRange.new(r[1], r[2]) end

local function ns(a, b)
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

-- Soft fade in / hold / fade out. peak = most opaque value (0 = solid).
local function envelope(peak)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, peak),
		NumberSequenceKeypoint.new(0.7, peak + (1 - peak) * 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Swell in, hold, shrink out.
local function swell(size)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, size), NumberSequenceKeypoint.new(1, 0),
	})
end

-- White-hot core cooling into the tint, then darkening as the particle dies.
local function glow(core, tint)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, core),
		ColorSequenceKeypoint.new(0.3, tint),
		ColorSequenceKeypoint.new(1, tint:Lerp(BLACK, 0.55)),
	})
end

local function part(janitor, size, cf, name)
	local p = Instance.new("Part")
	p.Name = name or "TameFx"
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow, p.Massless, p.Transparency = false, true, 1
	p.Size, p.CFrame = size, cf
	p.Parent = Workspace
	if janitor then janitor:add(p) end
	return p
end

local function emitter(parent, props)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	for k, v in props do e[k] = v end
	e.Parent = parent
	return e
end

local function label(parent, id, tint)
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromScale(1, 1)
	l.Image = id
	l.ImageColor3 = tint
	l.ImageTransparency = 1
	l.Parent = parent
	return l
end

-- A flat SurfaceGui canvas on the top face of `p`.
local function topGui(p, canvas, brightness)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(canvas, canvas)
	gui.LightInfluence = 0
	gui.Brightness = brightness
	gui.Parent = p
	return gui
end

-- A point light that tweens its brightness to 0.
local function flashLight(parent, color, range_, brightness, fade)
	local l = Instance.new("PointLight")
	l.Color, l.Range, l.Brightness, l.Shadows = color, range_, brightness, false
	l.Parent = parent
	TweenService:Create(l, TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	return l
end

local function disc(e, style, inOut)
	pcall(function()
		e.Shape = Enum.ParticleEmitterShape.Disc
		e.ShapeStyle = style
		e.ShapeInOut = inOut
	end)
end

-------------------------------------------------------------------- Circle

local Circle = {}
Circle.__index = Circle

-- opts: position, radius, color, spin (deg/s)
function Circles.new(janitor, opts)
	local C = FX.Circle
	local self = setmetatable({}, Circle)
	self.pos, self.radius = opts.position, opts.radius
	self.spin, self.rot = opts.spin or 40, 0
	self.alpha, self.rimAlpha = 0, 0 -- 0..1 visibility of full layers / ring layer
	self.flicker, self._ft, self._fon = false, 0, true

	local side = opts.radius * 2 * C.HaloScale
	self.part = part(janitor, Vector3.new(side, 0.05, side), CFrame.new(opts.position), "Circle")
	local gui = topGui(self.part, C.Canvas, C.Brightness)

	local tint = TINTABLE and (opts.color or WHITE) or WHITE
	local art = 1 / C.HaloScale
	self.halo  = label(gui, RING_ID, tint) -- created first = drawn behind the art
	self.main  = label(gui, FULL_ID, tint)
	self.inner = label(gui, FULL_ID, tint)
	self.rim   = label(gui, RING_ID, tint)
	self.main.Size  = UDim2.fromScale(art, art)
	self.rim.Size   = UDim2.fromScale(art, art)
	self.inner.Size = UDim2.fromScale(C.InnerScale * art, C.InnerScale * art)

	if C.Light.Enabled then
		local l = Instance.new("PointLight")
		l.Color, l.Brightness, l.Shadows = opts.color or WHITE, 0, false
		l.Parent = self.part
		self.light = l
		self:_fitLight()
	end

	janitor:add(RunService.Heartbeat:Connect(function(dt) self:step(dt) end))
	return self
end

function Circle:_fitLight()
	local L = FX.Circle.Light
	self.light.Range = math.clamp(self.radius * L.RangePerRadius, L.MinRange, L.MaxRange)
end

function Circle:step(dt)
	local C = FX.Circle
	self.rot += self.spin * dt
	self.main.Rotation  = self.rot
	self.inner.Rotation = self.rot * C.Spin.Inner
	self.rim.Rotation   = self.rot * C.Spin.Rim
	self.halo.Rotation  = self.rot * C.Spin.Halo

	local a = self.alpha
	if self.flicker then
		self._ft -= dt
		if self._ft <= 0 then
			self._fon = not self._fon
			self._ft = C.Flicker.OffTime + math.random() * C.Flicker.OffSpread
		end
		if not self._fon then a *= C.Flicker.DimAlpha end
	end

	local lit = math.max(a, self.rimAlpha * 0.8)
	local pulse = 1 - C.Pulse.Depth + C.Pulse.Depth * math.sin(os.clock() * C.Pulse.Rate)
	self.main.ImageTransparency  = 1 - a
	self.inner.ImageTransparency = 1 - a
	self.rim.ImageTransparency   = 1 - self.rimAlpha
	self.halo.ImageTransparency  = 1 - lit * C.HaloAlpha * pulse
	if self.light then self.light.Brightness = lit * C.Light.Brightness * pulse end
end

function Circle:setPos(v)
	self.pos = v
	self.part.CFrame = CFrame.new(v)
end

function Circle:setRadius(r)
	self.radius = math.max(r, 0.05)
	local side = self.radius * 2 * FX.Circle.HaloScale
	self.part.Size = Vector3.new(side, 0.05, side)
	if self.light then self:_fitLight() end
end

-------------------------------------------------------------------- particles

-- Soft motes gathering inward and rising, plus fast glints along the rim.
function Circles.motes(circle, color)
	local M = FX.Motes
	local e = emitter(circle.part, {
		Color = glow(WHITE, color), LightEmission = 1, LightInfluence = 0,
		Size = swell(M.Size), Transparency = envelope(0.05),
		Lifetime = range(M.Lifetime), Speed = range(M.Speed), Drag = 1.2,
		Acceleration = Vector3.new(0, M.Lift, 0), EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(M.Spread, M.Spread), RotSpeed = NumberRange.new(-90, 90), Rotation = NumberRange.new(0, 360),
		Rate = Util.rate(M.Rate),
	})
	disc(e, Enum.ParticleEmitterShapeStyle.Volume, Enum.ParticleEmitterShapeInOut.Inward)

	local glints = emitter(circle.part, {
		Color = ColorSequence.new(WHITE, color), LightEmission = 1, LightInfluence = 0,
		Size = ns(M.GlintSize, 0), Transparency = envelope(0),
		Lifetime = range(M.GlintLifetime), Speed = range(M.GlintSpeed),
		Acceleration = Vector3.new(0, M.GlintLift, 0), EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(25, 25), Rate = Util.rate(M.GlintRate),
	})
	disc(glints, Enum.ParticleEmitterShapeStyle.Surface, Enum.ParticleEmitterShapeInOut.Outward)
	return e
end

-- Optional vertical filaments between consecutive circles in `circles` (lowest first).
-- Inert unless Effects.Links.Enabled. Scale visibility with links.strength (0..1).
function Circles.links(janitor, circles, color)
	local L = FX.Links
	local links = { strength = 0 }
	local count = math.floor(L.Count * math.clamp(Config.Quality, 0.25, 1) + 0.5)
	if not L.Enabled or count <= 0 or #circles < 2 then return links end

	local items = {}
	for i = 1, count do
		local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
		a0.Parent, a1.Parent = Workspace.Terrain, Workspace.Terrain
		local beam = Instance.new("Beam")
		beam.Attachment0, beam.Attachment1 = a0, a1
		beam.Color = glow(WHITE, color)
		beam.LightEmission, beam.LightInfluence, beam.FaceCamera = 1, 0, true
		beam.Width0, beam.Width1, beam.Segments = L.Width, L.Width, 1
		beam.Transparency = NumberSequence.new(1)
		beam.Parent = Workspace.Terrain
		janitor:add(a0)
		janitor:add(a1)
		janitor:add(beam)
		items[i] = {
			a0 = a0, a1 = a1, beam = beam,
			lo = circles[(i - 1) % (#circles - 1) + 1],
			hi = circles[(i - 1) % (#circles - 1) + 2],
			phase = (i - 1) / count * math.pi * 2,
		}
	end

	local acc = 0
	janitor:add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.033 then return end -- ~30 Hz is plenty for a filament
		acc = 0
		local t = os.clock()
		for i, it in items do
			local lo, hi = it.lo, it.hi
			local vis = links.strength * math.min(math.max(lo.alpha, lo.rimAlpha), math.max(hi.alpha, hi.rimAlpha))
			if vis > 0.01 then
				local aLo, aHi = it.phase + math.rad(lo.rot), it.phase + math.rad(hi.rot)
				it.a0.WorldPosition = lo.pos + Vector3.new(math.cos(aLo) * lo.radius, 0, math.sin(aLo) * lo.radius)
				it.a1.WorldPosition = hi.pos + Vector3.new(math.cos(aHi) * hi.radius, 0, math.sin(aHi) * hi.radius)
				it.beam.Transparency = NumberSequence.new(1 - L.Opacity * vis * (0.7 + 0.3 * math.sin(t * 9 + i * 1.7)))
			else
				it.beam.Transparency = NumberSequence.new(1)
			end
		end
	end))
	return links
end

-- One-shot burst: sparks + rising embers + shockwave ring + short light flash.
function Circles.burst(pos, color, count)
	local B = FX.Burst
	local q = math.clamp(Config.Quality, 0.1, 1)
	local p = part(nil, Vector3.new(0.5, 0.5, 0.5), CFrame.new(pos), "Burst")

	emitter(p, {
		Color = glow(WHITE, color), LightEmission = 1, LightInfluence = 0,
		Size = ns(B.SparkSize, 0), Transparency = envelope(0),
		Lifetime = range(B.SparkLifetime), Speed = range(B.SparkSpeed), Drag = B.SparkDrag,
		SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, -B.SparkGravity, 0),
	}):Emit(math.max(1, math.floor(count * q + 0.5)))

	emitter(p, {
		Color = glow(color, color), LightEmission = 0.8, LightInfluence = 0,
		Size = swell(B.EmberSize), Transparency = envelope(0.15),
		Lifetime = range(B.EmberLifetime), Speed = range(B.EmberSpeed), Drag = 1.5,
		SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, B.EmberLift, 0),
		RotSpeed = NumberRange.new(-60, 60), Rotation = NumberRange.new(0, 360),
	}):Emit(math.max(1, math.floor(count * B.EmberRatio * q + 0.5)))

	flashLight(p, color, B.Flash.Range, B.Flash.Brightness, B.Flash.Time)

	local S = B.Shockwave
	if S.Enabled then
		local reach = S.BaseReach + count * S.ReachPerCount
		local ring = part(nil, Vector3.new(1, 0.05, 1), CFrame.new(pos), "Shockwave")
		local img = label(topGui(ring, 256, 2), RING_ID, TINTABLE and color or WHITE)
		img.ImageTransparency = 0.1
		TweenService:Create(ring, TweenInfo.new(S.Time, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
			{ Size = Vector3.new(reach * 2, 0.05, reach * 2) }):Play()
		TweenService:Create(img, TweenInfo.new(S.Time, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ ImageTransparency = 1 }):Play()
		Debris:AddItem(ring, S.Time + 0.3)
	end

	Debris:AddItem(p, B.EmberLifetime[2] + 1)
end

-------------------------------------------------------------------- crack

function Circles.crack(janitor, circle, color)
	local K = FX.Crack
	local segs, up = {}, Vector3.new(0, 0.1, 0)
	local center, radius = circle.pos, circle.radius

	for i = 1, K.Rays do
		local ang = (i / K.Rays) * math.pi * 2 + (math.random() - 0.5) * 0.5
		local segLen = radius * (0.75 + math.random() * 0.3) / K.Steps
		local cur = center
		for s = 1, K.Steps do
			ang += (math.random() - 0.5) * K.Wobble
			local nxt = cur + Vector3.new(math.cos(ang), 0, math.sin(ang)) * segLen
			local p = part(janitor, Vector3.new(K.Width, 0.06, segLen * 1.08),
				CFrame.lookAt((cur + nxt) / 2 + up, nxt + up), "Crack")
			p.Material, p.Color = Enum.Material.Neon, color
			table.insert(segs, { part = p, at = ((s - 1) / K.Steps) * 0.7 + math.random() * 0.12 })
			cur = nxt
		end
	end

	local api = {}
	-- progress 0..1 reveals cracks outward; fade 0..1 fades them out.
	function api:set(progress, fade)
		for _, seg in segs do
			local v = math.clamp((progress - seg.at) / 0.16, 0, 1)
			seg.part.Transparency = 1 - v * (1 - fade) * 0.95
		end
	end
	return api
end

-------------------------------------------------------------------- storm

function Circles.storm(janitor, center, color, radius)
	local S = FX.Storm
	local H = S.Height
	local cloudPos = center + Vector3.new(0, H - S.Cloud.Drop, 0)

	local col = part(janitor, Vector3.new(H, radius * S.Column.Width, radius * S.Column.Width),
		CFrame.new(center + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)), "Column")
	col.Shape, col.Material, col.Color = Enum.PartType.Cylinder, Enum.Material.Neon, color

	local cloud = part(janitor, S.Cloud.Size, CFrame.new(cloudPos), "Cloud")
	local rainPart = part(janitor, Vector3.new(S.Rain.Width, 1, S.Rain.Width), CFrame.new(cloudPos - Vector3.new(0, 2, 0)), "Rain")

	local smoke = emitter(cloud, {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(S.Cloud.ColorA, S.Cloud.ColorB),
		LightEmission = 0.15, LightInfluence = 0.8, Size = ns(S.Cloud.ParticleSize[1], S.Cloud.ParticleSize[2]),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 0.35),
			NumberSequenceKeypoint.new(0.75, 0.45), NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = range(S.Cloud.Lifetime), Speed = NumberRange.new(0.5, 2),
		RotSpeed = NumberRange.new(-25, 25), Rotation = NumberRange.new(0, 360),
		EmissionDirection = Enum.NormalId.Bottom,
	})
	local rain = emitter(rainPart, {
		Color = ColorSequence.new(S.Rain.Color), LightEmission = 0.5,
		Size = NumberSequence.new(0.14), Transparency = NumberSequence.new(0.35),
		Lifetime = NumberRange.new(0.4, 0.5), Speed = range(S.Rain.Speed),
		Acceleration = Vector3.new(0, -30, 0), EmissionDirection = Enum.NormalId.Bottom,
		Orientation = Enum.ParticleOrientation.VelocityParallel,
	})
	-- Column is rotated 90deg on Z, so its local +X (Right) points to world up.
	local sparks = emitter(col, {
		Color = glow(WHITE, color), LightEmission = 1, LightInfluence = 0,
		Size = ns(S.Sparks.Size, 0), Transparency = envelope(0.05),
		Lifetime = range(S.Sparks.Lifetime), Speed = range(S.Sparks.Speed), Drag = 0.8,
		EmissionDirection = Enum.NormalId.Right, SpreadAngle = Vector2.new(6, 6),
	})

	local T = FX.Thunder
	local cloudLight = Instance.new("PointLight")
	cloudLight.Color, cloudLight.Range, cloudLight.Brightness, cloudLight.Shadows = T.Light.Color, T.Light.Range, 0, false
	cloudLight.Parent = cloud

	local s = { k = 0 }
	function s.set(k)
		s.k = k
		smoke.Rate  = Util.rate(S.Cloud.Rate) * k
		rain.Rate   = Util.rate(S.Rain.Rate) * k
		sparks.Rate = Util.rate(S.Sparks.Rate) * k
	end

	-- Thunder: the cloud lights up and decays.
	function s.flash()
		cloudLight.Brightness = T.Light.Brightness
		TweenService:Create(cloudLight, TweenInfo.new(T.Light.Fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Brightness = 0 }):Play()
	end

	janitor:add(RunService.Heartbeat:Connect(function()
		local t = os.clock()
		col.Transparency = 1 - S.Column.Opacity * s.k * (1 - S.Column.Pulse + S.Column.Pulse * math.sin(t * 8))
		cloud.CFrame = CFrame.new(cloudPos) * CFrame.Angles(0, t * S.Cloud.Spin, 0)
	end))
	return s
end

return Circles