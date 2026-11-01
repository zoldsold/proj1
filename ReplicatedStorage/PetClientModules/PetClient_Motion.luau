-- v1.0.0.1
--[[
	PetClient_Motion (ModuleScript -> ReplicatedStorage/PetClientModules)

	Per-frame movement of the local player's pet, in one fixed order every frame:

	  1. guards         character, pet and follow constraints ready? (self-heals the setup)
	  2. snap / freeze  teleport snap; hold still during cinematics and the summon
	  3. profile        speed, height gap and bob for THIS pet (cached; see PetMotionConfig)
	  4. state          FOLLOW <-> WANDER, click ATTACK -> hold DRAG, strikes
	  5. goal           where to go and which way to face, per state
	  6. move           horizontal: speed-limited approach; vertical: ground + gap, eased
	  7. publish        MoveSpeed / DashBlend attributes for the swim animation

	Everything tunable is in PetMotionConfig. Adding a pet or a movement type never edits this file.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("PetClientModules")
local Cfg     = require(Modules:WaitForChild("PetMotionConfig"))
local Helpers = require(Modules:WaitForChild("PetClient_Helpers"))
local Follow  = require(Modules:WaitForChild("PetClient_Follow"))
local Attack  = require(Modules:WaitForChild("PetClient_Attack"))

local Motion = {}

local M, V = Cfg.Modes, Cfg.Vertical
local MODE = { FOLLOW = M.Follow, WANDER = M.Wander, ATTACK = M.Attack, DRAG = M.Drag }
local EMPTY = {}

local ctx = {}                  -- player, key, petsFolder, petEvent
local profile, profileKey = {}, {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local rayCharacter
local lastRootPos
local lastSetup = 0
local speedEase = 0


function Motion.init(player, petsFolder, petEvent)
	ctx.player, ctx.key, ctx.petsFolder, ctx.petEvent = player, tostring(player.UserId), petsFolder, petEvent
end

------------------------------------------------------------------ 3. profile

-- Studs from the model's pivot down to its underside.
local function pivotToBottom(model)
	local box, size = model:GetBoundingBox()
	return model:GetPivot().Position.Y - (box.Position.Y - size.Y * 0.5)
end

-- Resolved movement profile for this pet. Rebuilt only when species, stage or size change.
local function resolveProfile(model, cfg)
	local species, stage = model:GetAttribute("SpeciesId"), model:GetAttribute("Stage")
	local size = model:GetAttribute("SizeMultiplier") or 1
	local k = profileKey
	if k.model == model and k.species == species and k.stage == stage and k.size == size then
		return profile
	end
	k.model, k.species, k.stage, k.size = model, species, stage, size

	local override = Cfg.Species[species] or EMPTY
	local kind = Cfg.Types[override.Type or cfg.MoveType or Cfg.DefaultType] or Cfg.Types[Cfg.DefaultType]
	local scale = (cfg.Scale or 1) * size

	profile.scale     = scale
	profile.speed     = override.Speed or cfg.MoveSpeed or (Cfg.Speed.Base + Cfg.Speed.PerScale * scale)
	profile.lift      = (override.Gap or (kind.Gap + kind.GapPerScale * scale)) + pivotToBottom(model) -- pivot height above ground
	profile.bob       = kind.Bob
	profile.wanderBob = kind.WanderBob
	Follow.currentSizeMultiplier = size
	return profile
end

------------------------------------------------------------------ 4. state

local function strike(cfg)
	local target = Follow.attackTargetPos
	if Follow.enemyNearAttack(ctx.player, target, cfg) then
		ctx.petEvent:FireServer("AttackImpact", target)
		Attack.burstImpact(target)
	end
end

local function flatDistance(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function updateState(dt, root, rootSpeed, petPos, cfg)
	local state = Follow.petState

	if state == "FOLLOW" or state == "WANDER" then
		local W = M.Wander
		local dist = (petPos - root.Position).Magnitude
		if state == "FOLLOW" and dist < W.EnterDist and rootSpeed < W.EnterPlayerSpeed then
			Follow.petState, Follow.wanderAngle = "WANDER", math.random() * math.pi * 2
		elseif state == "WANDER" and (dist > W.ExitDist or rootSpeed > W.ExitPlayerSpeed) then
			Follow.petState = "FOLLOW"
		end
		return
	end

	Follow.attackTimer += dt
	if state == "ATTACK" then
		if Follow.pointerHeld and Follow.attackTimer >= M.Drag.HoldTime then
			Follow.petState, Follow.dragTimer = "DRAG", 0 -- click became a drag
			return
		end
		local timedOut = Follow.attackTimer > M.Attack.Timeout
		if timedOut or flatDistance(petPos, Follow.attackTargetPos) < M.Attack.Reached then
			if not timedOut then strike(cfg) end
			Follow.petState = "FOLLOW"
		end
	else -- DRAG
		if not Follow.pointerHeld then
			Follow.petState = "FOLLOW"
			return
		end
		Attack.updateDrag()
		Follow.dragTimer += dt
		if Follow.dragTimer >= M.Drag.ImpactInterval then
			Follow.dragTimer = 0
			strike(cfg)
		end
	end
end

------------------------------------------------------------------ 6. move

-- Horizontal approach: eased by `smooth` (0 = none), never faster than `maxStep`, never overshoots.
local function approach(pos, goal, smooth, maxStep, dt)
	local delta = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
	local step = smooth > 0 and delta * (1 - math.exp(-smooth * dt)) or delta
	local len = step.Magnitude
	if len > maxStep then step *= maxStep / len end
	return pos + step
end

-- Ground height below (x, z), searched downward from just above `fromY`; nil when there is none.
local function groundHeight(x, fromY, z)
	local character = ctx.player.Character
	if character ~= rayCharacter then
		rayCharacter = character
		rayParams.FilterDescendantsInstances = { character, ctx.petsFolder }
	end
	local hit = workspace:Raycast(Vector3.new(x, fromY + V.RayStart, z), Vector3.new(0, -V.RayLength, 0), rayParams)
	return hit and hit.Position.Y
end

-- Attributes are client-local; the swim animation reads them.
local function publish(model, name, value, epsilon)
	if math.abs((model:GetAttribute(name) or 0) - value) > epsilon then
		model:SetAttribute(name, value)
	end
end

------------------------------------------------------------------ frame

function Motion.step(dt)
	local player, petsFolder = ctx.player, ctx.petsFolder

	-- 1. guards ---------------------------------------------------------
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		lastRootPos = nil
		return
	end

	local pet = petsFolder:FindFirstChild(ctx.key)
	if not pet or not pet.PrimaryPart then
		lastRootPos = root.Position
		return
	end

	-- Self-heal: wire the follow constraints if missing (late PetSpawned / respawn race).
	-- Throttled: Follow.setup does a blocking WaitForChild("Body", 5).
	local f = Follow.follows[ctx.key]
	if not (f and f.anchor) then
		local now = os.clock()
		if now - lastSetup > 1 then
			lastSetup = now
			Follow.setup(player, ctx.key, petsFolder)
			f = Follow.follows[ctx.key]
		end
		if not (f and f.anchor) then
			lastRootPos = root.Position
			return
		end
	end

	local cfg = Helpers.stageCfgOf(pet)
	if not cfg then return end

	-- 2. snap / freeze --------------------------------------------------
	local rootPos = root.Position
	if lastRootPos and (rootPos - lastRootPos).Magnitude > Cfg.TeleportSnap then
		pet:PivotTo(root.CFrame * CFrame.new(cfg.FollowOffset))
		Follow.currentAnchorOffset = cfg.FollowOffset
	end
	lastRootPos = rootPos

	if player:GetAttribute("PetCinematic") or pet:GetAttribute("Spawning") then
		f.anchor.Position = cfg.FollowOffset
		return
	end

	-- 3. profile --------------------------------------------------------
	local p = resolveProfile(pet, cfg)
	local pivot = pet:GetPivot()
	local petPos = pivot.Position
	local rootSpeed = root.AssemblyLinearVelocity.Magnitude

	-- 4. state ----------------------------------------------------------
	updateState(dt, root, rootSpeed, petPos, cfg)
	local state = Follow.petState
	local mode = MODE[state]

	-- 5. goal (horizontal target, facing, vertical sway) -----------------
	local goal, goalRot, sway
	if state == "ATTACK" or state == "DRAG" then
		goal = Follow.attackTargetPos
		local toGoal = Vector3.new(goal.X - petPos.X, 0, goal.Z - petPos.Z)
		goalRot = toGoal.Magnitude > 0.05 and CFrame.lookAt(Vector3.zero, toGoal) or pivot.Rotation
		sway = 0
	else
		local offset = cfg.FollowOffset
		if state == "WANDER" then
			Follow.wanderAngle += dt * (mode.Rate + p.scale * mode.RatePerScale)
			local radius = mode.Radius + p.scale * mode.RadiusPerScale
			offset = Vector3.new(math.sin(Follow.wanderAngle) * radius, offset.Y, math.cos(Follow.wanderAngle) * radius)
		end
		if Follow.currentAnchorOffset.Magnitude < 0.1 then Follow.currentAnchorOffset = cfg.FollowOffset end
		Follow.currentAnchorOffset = Follow.currentAnchorOffset:Lerp(offset, 1 - math.exp(-mode.OffsetSmooth * dt))
		goal = root.CFrame * Follow.currentAnchorOffset

		local t, s = os.clock(), p.scale
		sway = p.bob * (math.sin(t * 1.7) * (0.22 + 0.32 * s) + math.sin(t * 0.9 + 1.1) * (0.09 + 0.13 * s))
		if state == "WANDER" then sway += p.wanderBob * math.sin(Follow.wanderAngle * 1.5) end
		local roll = (state == "FOLLOW" and rootSpeed < 0.5) and math.sin(t * 0.6) * math.rad(4) or 0
		goalRot = root.CFrame.Rotation * CFrame.Angles(0, 0, roll)
	end

	-- 6. move -----------------------------------------------------------
	local speed = p.speed * mode.SpeedMult
	local pos = approach(petPos, goal, mode.Smooth, speed * dt, dt)

	local y = petPos.Y
	local ground = groundHeight(pos.X, y, pos.Z)
	if ground then
		y += (ground + p.lift + sway - y) * (1 - math.exp(-V.Smooth * dt))
	end

	local rot = pivot.Rotation:Lerp(goalRot, 1 - math.exp(-(mode.Turn or mode.Smooth) * dt))
	local world = CFrame.new(pos.X, y, pos.Z) * rot
	pet:PivotTo(world)

	f.anchor.CFrame = root.CFrame:ToObjectSpace(world) -- keeps the constraint attachments on the pet
	f.alignPos.MaxVelocity = speed

	-- 7. publish --------------------------------------------------------
	speedEase += ((world.Position - petPos).Magnitude / dt - speedEase) * math.min(1, dt * 8)
	publish(pet, "MoveSpeed", speedEase, 0.5)
	publish(pet, "DashBlend", (state == "ATTACK" or state == "DRAG") and 1 or 0, 0.02)
end

return Motion