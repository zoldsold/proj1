-- v1.0.0.2
--[[
	PetClient_Attack (ModuleScript -> ReplicatedStorage/PetClientModules)

	Left-button input and cursor targeting.
	  Press        the pet lunges to the clicked point (no delay: it starts on press).
	  Hold + move  after Drag.HoldTime the pet tracks the cursor in real time (see PetClient_Motion).
	  Release      the pet stops following the cursor and returns.
	Movement and strikes are handled by PetClient_Motion; ranges live in PetMotionConfig.

	CHANGES v1.0.0.2: press/release tracking, Attack.cursorTarget / start / updateDrag, ranges from
	config. The per-frame raycast reuses one RaycastParams (no allocation while dragging).
]]
local ContextActionService = game:GetService("ContextActionService")
local UserInputService     = game:GetService("UserInputService")
local Debris               = game:GetService("Debris")

local ModulesFolder = game.ReplicatedStorage:WaitForChild("PetClientModules")
local Follow = require(ModulesFolder:WaitForChild("PetClient_Follow"))
local Cfg    = require(ModulesFolder:WaitForChild("PetMotionConfig"))

local Attack = {}

local ACTION = "PetAttack"
local ctx = {}                                  -- player, petsFolder, camera (set by bindInput)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local filteredCharacter

------------------------------------------------------------------ targeting

-- The point under the cursor: an enemy's root when one is hit, the surface point otherwise, or a
-- point along the ray at full range for a miss (so the pet still lunges in the clicked direction).
function Attack.cursorTarget()
	local character = ctx.player.Character
	if character ~= filteredCharacter then
		filteredCharacter = character
		rayParams.FilterDescendantsInstances = { character, ctx.petsFolder, ctx.camera }
	end

	local mouse = UserInputService:GetMouseLocation()
	local ray   = ctx.camera:ViewportPointToRay(mouse.X, mouse.Y)
	local reach = ray.Direction * Cfg.Modes.Attack.Range
	local hit   = workspace:Raycast(ray.Origin, reach, rayParams)
	if not hit then return ray.Origin + reach end

	local model = hit.Instance:FindFirstAncestorOfClass("Model")
	local enemyRoot = model and model:FindFirstChild("HumanoidRootPart")
	local humanoid  = model and model:FindFirstChildOfClass("Humanoid")
	if enemyRoot and humanoid and humanoid.Health > 0 then return enemyRoot.Position end
	return hit.Position
end

-- Begin a lunge toward `target`.
function Attack.start(target)
	Follow.attackTargetPos = target
	Follow.attackTimer     = 0
	Follow.dragTimer       = 0
	Follow.petState        = "ATTACK"
end

-- While dragging: keep the target on the cursor.
function Attack.updateDrag()
	Follow.attackTargetPos = Attack.cursorTarget()
end

------------------------------------------------------------------ input

-- ContextActionService callback signature is (actionName, inputState, inputObject).
function Attack.bindInput(player, petsFolder, camera)
	ctx.player, ctx.petsFolder, ctx.camera = player, petsFolder, camera

	ContextActionService:BindAction(ACTION, function(_, inputState, input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return Enum.ContextActionResult.Pass
		end

		if inputState ~= Enum.UserInputState.Begin then
			Follow.pointerHeld = false -- End or Cancel
			return Enum.ContextActionResult.Pass
		end

		local busy = Follow.petState == "ATTACK" or Follow.petState == "DRAG"
		if busy or player:GetAttribute("PetCinematic") or not player.Character then
			return Enum.ContextActionResult.Pass
		end

		Follow.pointerHeld = true
		Attack.start(Attack.cursorTarget())
		return Enum.ContextActionResult.Sink
	end, false, Enum.UserInputType.MouseButton1)

	player.AncestryChanged:Connect(function(_, parent)
		if not parent then ContextActionService:UnbindAction(ACTION) end
	end)
end

------------------------------------------------------------------ impact VFX (client-side)

local function burst(pos, count, color, sMin, sMax, sz, life, spread)
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
	e.Drag = 2; e.Rate = 0; e.Parent = a
	e:Emit(count)
	Debris:AddItem(a, life + 0.5)
end

-- Public so the FX handler can call it
function Attack.burstImpact(pos)
	burst(pos, 20, Color3.new(0, 1, 1), 10, 20, 0.5, 1, 180)
end

return Attack