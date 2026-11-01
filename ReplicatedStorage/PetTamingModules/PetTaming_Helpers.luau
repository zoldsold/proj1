-- v1.0.0.0.2
-- FIXES: All capitalized keywords lowercased (Local→local, Fn→function, End→end, Return→return, If→if)
--        Ring/Beam/Sparks/Circle/Tween variable refs lowercased to match declaration

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local Debris           = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local Helpers = {}

-- Taming probability: higher level difference increases failure chance.
function Helpers.calculateTamingChance(petLevel, playerLevel)
	local baseChance = 0.9
	local levelDiff  = petLevel - playerLevel
	local penalty    = levelDiff * 0.05
	return math.clamp(baseChance - penalty, 0.15, 0.95)
end

-- Returns true if taming succeeds.
function Helpers.tryTame(petLevel, playerLevel)
	local rng    = Random.new()
	local chance = Helpers.calculateTamingChance(petLevel, playerLevel)
	return rng:NextNumber() < chance
end

-- VFX helpers
function Helpers.createOrbitalRing(position, radius, color, parent)
	local ring      = Instance.new("Part")
	ring.Size       = Vector3.new(0.2, 0.2, radius * 2)
	ring.Anchored   = true
	ring.Transparency = 0.3
	ring.BrickColor = BrickColor.new(color)
	ring.Material   = Enum.Material.Neon
	ring.CFrame     = CFrame.new(position) * CFrame.fromOrientation(0, math.rad(90), 0)
	ring.Parent     = parent or workspace

	local attach = Instance.new("Attachment", ring)

	local beam          = Instance.new("Beam")
	beam.Attachment0    = attach
	beam.Attachment1    = attach
	beam.Color          = ColorSequence.new(color)
	beam.Width0         = 0.2
	beam.Width1         = 0.2
	beam.Transparency   = NumberSequence.new(0.3)
	beam.Texture        = "rbxasset://textures/particles/smoke_main.dds"
	beam.Parent         = attach

	return ring
end

function Helpers.createEnchantmentCircle(position, radius, color)
	local circle         = Instance.new("Part")
	circle.Size          = Vector3.new(radius * 2, 0.2, radius * 2)
	circle.Anchored      = true
	circle.Transparency  = 0.5
	circle.BrickColor    = BrickColor.new(color)
	circle.Material      = Enum.Material.Neon
	circle.CFrame        = CFrame.new(position) * CFrame.fromOrientation(-math.rad(90), 0, 0)
	circle.Parent        = workspace

	-- Sparkle particles
	local sparks             = Instance.new("ParticleEmitter")
	sparks.Color             = ColorSequence.new(color)
	sparks.LightEmission     = 1
	sparks.Size              = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Lifetime          = NumberRange.new(0.8)
	sparks.Rate              = 60
	sparks.Speed             = NumberRange.new(8, 15)
	sparks.SpreadAngle       = Vector2.new(360, 360)
	sparks.Parent            = circle
	sparks.Enabled           = true

	Debris:AddItem(circle, 2)
	return circle
end

-- Animate part transparency.
function Helpers.fadePart(part, targetAlpha, duration)
	if not part then return end
	local tween = TweenService:Create(
		part,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = targetAlpha }
	)
	tween:Play()
	return tween
end

return Helpers