-- v1.0.0.1
--[[
	PetClient_Follow (ModuleScript -> ReplicatedStorage/PetClientModules)

	Pet state (FOLLOW / WANDER / ATTACK / DRAG), the client-owned anchor + constraints, and the
	strike gate. The per-frame movement lives in PetClient_Motion; every tunable lives in
	PetMotionConfig.

	CHANGES v1.0.0.1: tuning constants moved to PetMotionConfig; dead spin state and the unused
	attack constants removed; DRAG state + pointer fields added.
]]
local Players = game:GetService("Players")

local Helpers   = require(game.ReplicatedStorage:WaitForChild("PetClientModules"):WaitForChild("PetClient_Helpers"))
local Cfg       = require(game.ReplicatedStorage:WaitForChild("PetClientModules"):WaitForChild("PetMotionConfig"))

local Follow = {}

------------------------------------------------------------------ state

Follow.follows = {} -- [userIdStr] = { anchor, alignPos, alignOri }

-- One set per pet owner; the client only drives its own pet.
Follow.petState            = "FOLLOW" -- FOLLOW | WANDER | ATTACK | DRAG
Follow.wanderAngle         = 0
Follow.currentAnchorOffset = Vector3.zero
Follow.currentSizeMultiplier = 1

Follow.attackTargetPos = Vector3.zero -- where the pet is heading (click point, then the cursor while dragging)
Follow.attackTimer     = 0            -- seconds since the click
Follow.dragTimer       = 0            -- seconds since the last strike check while dragging
Follow.pointerHeld     = false        -- left button currently down

------------------------------------------------------------------ lifecycle

function Follow.teardown(player, userIdStr)
	local f = Follow.follows[userIdStr]
	if not f then return end
	if f.anchor   and f.anchor.Parent   then f.anchor:Destroy()   end
	if f.alignPos and f.alignPos.Parent then f.alignPos:Destroy() end
	if f.alignOri and f.alignOri.Parent then f.alignOri:Destroy() end
	Follow.follows[userIdStr] = nil
end

function Follow.setup(player, userIdStr, petsFolder)
	Follow.teardown(player, userIdStr)

	local model = petsFolder:FindFirstChild(userIdStr)
	if not model then return end
	local body = model:WaitForChild("Body", 5)
	if not body then return end

	local petAttach = body:FindFirstChild("PetAttach")
	if not petAttach then
		petAttach = Instance.new("Attachment")
		petAttach.Name = "PetAttach"
		petAttach.Parent = body
	end

	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local old = root:FindFirstChild("PetAnchor")
	if old then old:Destroy() end

	local cfg = Helpers.stageCfgOf(model)
	if not cfg then return end

	local anchor = Instance.new("Attachment")
	anchor.Name = "PetAnchor"
	anchor.Position = cfg.FollowOffset
	anchor.Parent = root

	local ap = Instance.new("AlignPosition")
	ap.Mode           = Enum.PositionAlignmentMode.TwoAttachment
	ap.Attachment0    = petAttach
	ap.Attachment1    = anchor
	ap.MaxForce       = 6e4
	ap.MaxVelocity    = 18 + cfg.Scale * 12
	ap.Responsiveness = 12
	ap.Parent         = body

	local ao = Instance.new("AlignOrientation")
	ao.Mode               = Enum.OrientationAlignmentMode.TwoAttachment
	ao.Attachment0        = petAttach
	ao.Attachment1        = anchor
	ao.MaxTorque          = 4e4
	ao.MaxAngularVelocity = 4
	ao.Responsiveness     = 8
	ao.Parent             = body

	Follow.follows[userIdStr] = { anchor = anchor, alignPos = ap, alignOri = ao }
end

------------------------------------------------------------------ strike gate

-- Is an enemy player close enough to the strike point to be worth a server round-trip?
function Follow.enemyNearAttack(player, attackTargetPos, cfg)
	local A = Cfg.Modes.Attack
	local radius = A.ImpactRadius + (cfg.Scale or 1) * Follow.currentSizeMultiplier * A.ImpactRadiusPerScale
	for _, plr in Players:GetPlayers() do
		if plr ~= player then
			local ch  = plr.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if hum and hum.Health > 0 and hrp and (hrp.Position - attackTargetPos).Magnitude <= radius then
				return true
			end
		end
	end
	return false
end

return Follow