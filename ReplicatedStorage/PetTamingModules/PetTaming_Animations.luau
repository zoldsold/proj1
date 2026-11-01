-- PetTaming_Animations
-- Animation definitions for taming effects
-- Handles orb effects, floating, and visual feedback
-- v1.0.0.0.1
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Animations = {}

-- Create a magical orb that orbits around a target
function Animations.createOrbitingOrbs(targetPart, count, radius, color, speed)
	count = count or 8
	radius = radius or 4
	speed = speed or 1
	color = color or Color3.fromRGB(0, 255, 180)

	local orbs = {}
	local center = targetPart

	for i = 1, count do
		local orb = Instance.new("Part")
		orb.Size = Vector3.new(0.3, 0.3, 0.3)
		orb.Shape = Enum.PartType.Ball
		orb.Anchored = true
		orb.CanCollide = false
		orb.CanQuery = false
		orb.Transparency = 0.3
		orb.BrickColor = BrickColor.new(color)
		orb.Material = Enum.Material.Neon
		orb.Parent = workspace

		local angle = (i - 1) / count * math.pi * 2

		local conn = RunService.Heartbeat:Connect(function(dt)
			angle += dt * speed
			local offset = Vector3.new(
				math.cos(angle) * radius,
				math.sin(angle * 0.7) * radius * 0.3,
				math.sin(angle) * radius
			)
			orb.CFrame = center.CFrame + offset
		end)

		-- Track cleanup
		local stopConn = orb.Destroying:Connect(function()
			if conn.Connected then conn:Disconnect() end
		end)

		table.insert(orbs, {orb = orb, connection = conn})
	end

	return orbs
end

-- Floating/ascending animation for pet during taming
function Animations.playFloatingAnimation(petModel, duration, maxHeight, onComplete)
	duration = duration or 2.0
	maxHeight = maxHeight or 5
	local startCFrame = petModel:GetPivot()
	local startTime = tick()
	local connection

	connection = RunService.Heartbeat:Connect(function()
		local elapsed = tick() - startTime
		if elapsed >= duration then
			connection:Disconnect()
			if onComplete then onComplete() end
			return
		end
		local progress = elapsed / duration
		local floatUp = math.sin(progress * math.pi) * maxHeight
		local rotation = progress * math.pi * 4
		petModel:PivotTo(startCFrame * CFrame.new(0, floatUp, 0) * CFrame.fromOrientation(0, math.rad(rotation), 0))
	end)

	return function() -- cancel function
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

-- Enchantment burst particle effect
function Animations.playEnchantmentBurst(position, color, intensity)
	intensity = intensity or 1
	local part = Instance.new("Part")
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Anchored = true
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CFrame = CFrame.new(position)
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5 * intensity), NumberSequenceKeypoint.new(1, 0)})
	emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)})
	emitter.Lifetime = NumberRange.new(0.8)
	emitter.Rate = 0
	emitter.Speed = NumberRange.new(15 * intensity, 25 * intensity)
	emitter.SpreadAngle = Vector2.new(360, 360)
	emitter.Parent = part
	emitter:Emit(math.floor(20 * intensity))

	Debris:AddItem(part, 1.5)
end

-- Shrink-out animation for failure
function Animations.playShrinkOut(model, duration, onComplete)
	duration = duration or 0.5
	local startCFrame = model:GetPivot()
	local startTime = tick()
	local connection

	connection = RunService.Heartbeat:Connect(function()
		local elapsed = tick() - startTime
		if elapsed >= duration then
			connection:Disconnect()
			if onComplete then onComplete() end
			return
		end
		local t = elapsed / duration
		local offset = Vector3.new(0, t * 2, 0)
		model:PivotTo(startCFrame * CFrame.new(offset))
		-- Apply visual transparency without physically shrinking (cheaper)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = math.clamp(part.Transparency + 0.05, 0, 1)
				local pe = part:FindFirstChildOfClass("ParticleEmitter")
				if pe then pe.Enabled = false end
			end
		end
	end)
end

return Animations