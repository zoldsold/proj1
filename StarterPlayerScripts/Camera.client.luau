local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

---------------------------------------------------------------------
-- Camera modes (scroll wheel steps: Above <-> Mid <-> First)
---------------------------------------------------------------------
local MODES = {
	-- height/distance: camera offset from the character
	-- target: how high above the root we look/orbit(Y AXIS)
	-- shoulder: how far the character slides to the side while moving (X OFFSET)
	-- ahead: how far the camera leads in the move direction (X AND Z)
	-- lookFwd: looks this far forward (used by first person)
	-- roll: max cinematic tilt (degrees) when strafing
	{ name = "Above", height = 20, distance = 16, target = 1,   fov = 120, shoulder = 3, ahead = 3, lookFwd = 0,  roll = 0.8 },
	{ name = "Mid",   height = 13, distance = 30, target = 3,   fov = 36, shoulder = 7, ahead = 5, lookFwd = 0,  roll = 2.5 },
	{ name = "Ground", height = 0.1, distance = 18, target =-0.5, fov = 60, shoulder = 5, ahead = 4, lookFwd = 0, roll = 0.5 },
	{ name = "First", height = 0,  distance = -5, target = 1.7, fov = 103, shoulder = 0, ahead = 0, lookFwd = 40, roll = 1.5 },
}

local START_MODE = 2            -- 1 = Above, 2 = Mid, 3 = First
local MODE_SPEED = 4            -- how fast modes blend (lower = slower, more cinematic)

-- Combat camera
local COMBAT_KEY = Enum.KeyCode.Z
local COMBAT_BLEND_SPEED = 5      -- how fast it blends in/out
local COMBAT_FOLLOW_BONUS = 8     -- extra follow tightness in combat
local COMBAT_ROTATE_BONUS = 0.5   -- 0.5 = 50% faster Q/E rotation in combat

local COMBAT = {
	height = 10, distance = 24, target = 2, fov = 70,
	shoulder = 0, ahead = 4, lookFwd = 8, roll = 0,
}

-- Collision
local COLLIDE_PADDING = 0.8     -- gap kept between the camera and the wall
local COLLIDE_MIN = 0.15        -- closest the camera may get (fraction of full distance)
local COLLIDE_IN_SPEED = 30     -- how fast it pushes in when blocked
local COLLIDE_OUT_SPEED = 3     -- how slowly it drifts back out (lower = smoother)


-- Rotation
local ROTATE_SPEED = 120        -- degrees/sec while holding Q/E
local ROTATE_ACCEL = 10
local MOUSE_SENS = 0.25         -- degrees per pixel while holding right mouse

-- Motion feel
local FOLLOW_SPEED = 10
local SHOULDER_IN_SPEED = 2.5   -- how fast the character slides to the side when you start moving
local SHOULDER_OUT_SPEED = 1.6  -- how slowly it drifts back to center when you stop
local LOOK_AHEAD_SPEED = 3
local ROLL_SPEED = 3
local FOV_KICK = 5              -- extra FOV while running (not in first person)

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local modeIndex = START_MODE
local mode = START_MODE          -- smoothed value (1..3), blends between presets
local yaw = math.rad(30)
local yawVelocity = 0
local focus = nil
local lookAhead = Vector3.zero
local moveBlend = 0              -- 0 = idle (centered), 1 = moving (shifted to side)
local roll = 0
local fov = MODES[START_MODE].fov
local rightMouseDown = false
local lastFade = -1
local collideFrac = 1           -- 1 = full distance, lower = pulled in
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true   -- ignores non-collidable parts like decorations
local combatOn = false
local combatBlend = 0
local function smooth(t)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function blendedPreset(m)
	local i = math.clamp(math.floor(m), 1, #MODES - 1)
	local t = smooth(math.clamp(m - i, 0, 1))
	local a, b = MODES[i], MODES[i + 1]
	local result = {}
	for key, value in pairs(a) do
		if typeof(value) == "number" then
			result[key] = value + (b[key] - value) * t
		end
	end
	-- Arc blend: interpolate angle + radius instead of raw height/distance
	local function polar(m) return math.atan2(m.height, m.distance), math.sqrt(m.height^2 + m.distance^2) end
	local angA, radA = polar(a)
	local angB, radB = polar(b)
	local ang = angA + (angB - angA) * t
	local rad = radA + (radB - radA) * t
	result.height = math.sin(ang) * rad
	result.distance = math.cos(ang) * rad
	return result
end

local function stepMode(direction)
	modeIndex = math.clamp(modeIndex + direction, 1, #MODES)
end
---------------------------------------------------------------------
-- Input
---------------------------------------------------------------------
UserInputService.InputChanged:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
		-- wheel up = toward first person, wheel down = toward above
		modeIndex = math.clamp(modeIndex + (input.Position.Z > 0 and 1 or -1), 1, #MODES)
	elseif input.UserInputType == Enum.UserInputType.MouseMovement and rightMouseDown then
		yaw -= math.rad(input.Delta.X * MOUSE_SENS)
	end
end)

UserInputService.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		rightMouseDown = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		rightMouseDown = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)

local cycleDir = 1
local MODE_COOLDOWN = 0.6     -- seconds before the key can be used again
local lastModeChange = 0

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == Enum.KeyCode.C then
		local now = os.clock()
		if now - lastModeChange < MODE_COOLDOWN then return end   -- too soon, ignore
		lastModeChange = now
		
		if math.abs(modeIndex - mode) > 0.15 then return end   -- still transitioning, ignore
		if modeIndex + cycleDir > #MODES or modeIndex + cycleDir < 1 then
			cycleDir = -cycleDir   -- reverse at either end
		end
		modeIndex += cycleDir
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == COMBAT_KEY then
		combatOn = not combatOn
	end
end)

---------------------------------------------------------------------
-- Hide the character when the camera is inside the head (first person)
---------------------------------------------------------------------
local function setCharacterFade(character, alpha)
	if math.abs(alpha - lastFade) < 0.01 then return end
	lastFade = alpha
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") then
			d.LocalTransparencyModifier = alpha
		end
	end
end

---------------------------------------------------------------------
-- Camera loop
---------------------------------------------------------------------
RunService:BindToRenderStep("ARPGCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid) then return end

	camera.CameraType = Enum.CameraType.Scriptable

	-- Blend between modes
	local jump = math.abs(modeIndex - mode)
	mode += (modeIndex - mode) * (1 - math.exp(-(MODE_SPEED + jump * 0.6) * dt))
	local p = blendedPreset(mode)
	local firstPersonAlpha = math.clamp((mode - (#MODES - 0.6)) / 0.5, 0, 1)
	
	-- Combat blend (fades out automatically in first person)
	combatBlend += ((combatOn and 1 or 0) - combatBlend) * (1 - math.exp(-COMBAT_BLEND_SPEED * dt))
	local cb = smooth(math.clamp(combatBlend, 0, 1)) * (1 - firstPersonAlpha)
	for key, value in pairs(COMBAT) do
		p[key] = p[key] + (value - p[key]) * cb
	end
	local followSpeed = FOLLOW_SPEED + COMBAT_FOLLOW_BONUS * cb

	-- Continuous rotation (Q/E)
	local rotInput = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then rotInput += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then rotInput -= 1 end
	local targetVel = math.rad(ROTATE_SPEED) * (1 + COMBAT_ROTATE_BONUS * combatBlend) * rotInput
	yawVelocity += (targetVel - yawVelocity) * (1 - math.exp(-ROTATE_ACCEL * dt))
	yaw += yawVelocity * dt

	local yawCF = CFrame.Angles(0, yaw, 0)
	local moveDir = humanoid.MoveDirection
	local moving = moveDir.Magnitude > 0.1

	-- Shoulder: centered when idle OR moving forward, slides to the side otherwise
	local camForward = yawCF:VectorToWorldSpace(Vector3.new(0, 0, -1))
	local forwardAmount = math.clamp(moveDir:Dot(camForward), 0, 1)   -- 1 = straight forward
	local shoulderGoal = moving and (1 - forwardAmount) or 0
	local speed = shoulderGoal > moveBlend and SHOULDER_IN_SPEED or SHOULDER_OUT_SPEED
	moveBlend += (shoulderGoal - moveBlend) * (1 - math.exp(-speed * dt))

	-- Look-ahead
	lookAhead = lookAhead:Lerp(moveDir * p.ahead, 1 - math.exp(-LOOK_AHEAD_SPEED * dt))

	-- Follow
	local goalFocus = root.Position + Vector3.new(0, p.target, 0) + lookAhead
	focus = focus or goalFocus
	focus = focus:Lerp(goalFocus, 1 - math.exp(-followSpeed * dt))

	-- Cinematic tilt when strafing
	local lateral = moveDir:Dot(yawCF.RightVector)
	roll += (-lateral * math.rad(p.roll) * moveBlend - roll) * (1 - math.exp(-ROLL_SPEED * dt))

	-- FOV (kicks wider when running, except in first person)
	local speedAlpha = math.clamp(root.AssemblyLinearVelocity.Magnitude / 20, 0, 1)
	local goalFov = p.fov + FOV_KICK * speedAlpha * (1 - firstPersonAlpha)
	fov += (goalFov - fov) * (1 - math.exp(-4 * dt))
	camera.FieldOfView = fov

	-- Build the camera
	local shift = yawCF.RightVector * (p.shoulder * moveBlend)
	local back = yawCF:VectorToWorldSpace(Vector3.new(0, p.height, p.distance))
	local forward = yawCF:VectorToWorldSpace(Vector3.new(0, 0, -1))

	local camPos = focus + shift + back
	local lookAt = focus + shift + forward * p.lookFwd
	
	-- Camera collision: raycast from the character toward the camera
	local origin = focus + shift
	local toCam = camPos - origin
	local fullDist = toCam.Magnitude
	local goalFrac = 1

	if fullDist > 1 and firstPersonAlpha < 0.5 then
		rayParams.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(origin, toCam, rayParams)
		if hit then
			goalFrac = math.clamp((hit.Distance - COLLIDE_PADDING) / fullDist, COLLIDE_MIN, 1)
		end
	end

	-- Snap in fast, ease out slowly
	local rate = goalFrac < collideFrac and COLLIDE_IN_SPEED or COLLIDE_OUT_SPEED
	collideFrac += (goalFrac - collideFrac) * (1 - math.exp(-rate * dt))

	camPos = origin + toCam * collideFrac
	camera.CFrame = CFrame.lookAt(camPos, lookAt) * CFrame.Angles(0, 0, roll)

	-- First person: character faces where the camera looks, and is hidden
	if firstPersonAlpha > 0.5 then
		humanoid.AutoRotate = false
		local goalCF = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
		root.CFrame = root.CFrame:Lerp(goalCF, 1 - math.exp(-14 * dt))
	else
		humanoid.AutoRotate = true
	end
	local actualDist = (camera.CFrame.Position - root.Position).Magnitude
	local closeAlpha = 1 - math.clamp((actualDist - 3) / 5, 0, 1)
	setCharacterFade(character, math.max(firstPersonAlpha, closeAlpha))
end)

-- v1.0.0.0.1