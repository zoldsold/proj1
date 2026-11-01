-- FILE: CombatServer (Script in ServerScriptService)
-- VERSION: v1.0.0.1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CombatRemote = ReplicatedStorage:WaitForChild("CombatRemote") 

local CombatServer = {}
CombatServer.__index = CombatServer

function CombatServer.new()
	local self = setmetatable({}, CombatServer)
	
	self.PlayerData = {}
	self.DefaultWalkSpeed = 16
	self.BlockWalkSpeed = 6
	self.Damage = 5
	self.Range = 10
	
	self.AnimationFolder = script:WaitForChild("Animations")

	self:_setupPlayers()
	self:_setupRemote()
	
	return self
end

function CombatServer:_setupPlayers()
	local function onCharacterAdded(character, player)
		local humanoid = character:WaitForChild("Humanoid")
		self.PlayerData[player] = {
			Combo = 0,
			LastPunch = 0,
			Blocking = false,
			Character = character,
			Humanoid = humanoid
		}
	end

	local function onPlayerAdded(player)
		player.CharacterAdded:Connect(function(char) onCharacterAdded(char, player) end)
		if player.Character then onCharacterAdded(player.Character, player) end
	end

	local function onPlayerRemoving(player)
		self.PlayerData[player] = nil -- Prevents memory leaks
	end

	for _, player in ipairs(Players:GetPlayers()) do onPlayerAdded(player) end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function CombatServer:_setupRemote()
	CombatRemote.OnServerEvent:Connect(function(plr, action, state)
		local data = self.PlayerData[plr]
		if not data then return end
		local character = plr.Character
		if not character then return end
		local humanoid = character:FindFirstChild("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp or not humanoid or humanoid.Health <= 0 then return end

		if action == "Punch" then
			self:HandlePunch(plr, character, humanoid, hrp)
		elseif action == "Block" then
			self:HandleBlock(plr, character, humanoid, state)
		end
	end)
end

function CombatServer:GetAnimationTrack(humanoid, name)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	
	local animation = self.AnimationFolder:FindFirstChild(name)
	
	return animator:LoadAnimation(animation) 
end

function CombatServer:StopPunchTracks(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		local anim = track.Animation
		if anim and (anim.Name == "M1" or anim.Name == "M2" or anim.Name == "M3" or anim.Name == "M4") then
			track:Stop()
		end
	end
end

function CombatServer:HandleBlock(plr, character, humanoid, state)
	local data = self.PlayerData[plr]
	if not data then return end

	if state then
		data.Blocking = true
		humanoid.WalkSpeed = self.BlockWalkSpeed
		CollectionService:AddTag(character, "Blocking")
		local track = self:GetAnimationTrack(humanoid, "Block")
		if track then track.Looped = true; track:Play() end
	else
		data.Blocking = false
		humanoid.WalkSpeed = self.DefaultWalkSpeed
		CollectionService:RemoveTag(character, "Blocking")
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				if track.Animation and track.Animation.Name == "Block" then track:Stop() end
			end
		end
	end
end

function CombatServer:HandlePunch(player, character, humanoid, hrp)
	local data = self.PlayerData[player]
	if not data then return end

	local now = os.clock()
	if now - data.LastPunch > 1 then data.Combo = 0 end

	local neededCooldown = data.Combo == 4 and 1.5 or 0.5
	if now - data.LastPunch < neededCooldown then return end

	if data.Blocking then
		CollectionService:RemoveTag(character, "Blocking")
		data.Blocking = false
		humanoid.WalkSpeed = self.DefaultWalkSpeed
	end

	data.Combo += 1
	if data.Combo > 4 then data.Combo = 1 end
	data.LastPunch = now

	self:StopPunchTracks(humanoid)
	local track = self:GetAnimationTrack(humanoid, "M" .. tostring(data.Combo))
	if track then track:Play() end

	task.delay(0.3, function()
		if humanoid and humanoid.Health > 0 then self:DoHitbox(character, hrp) end
	end)

	if data.Combo >= 4 then data.Combo = 0 end
end

function CombatServer:DoHitbox(character, hrp)
	if not hrp or not hrp.Parent then return end

	local size = Vector3.new(self.Range, self.Range, self.Range)
	local cf = hrp.CFrame * CFrame.new(0, 0, -self.Range / 2)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = {character}
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local hitModels = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(cf, size, overlapParams)) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not hitModels[model] then
			local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
			local targetHrp = model:FindFirstChild("HumanoidRootPart")

			if targetHumanoid and targetHrp and targetHumanoid.Health > 0 then
				hitModels[model] = true
				if not CollectionService:HasTag(model, "Blocking") then
					targetHumanoid:TakeDamage(self.Damage)

					local vfx = VFXTemplate:Clone()
					vfx.Parent = targetHrp
					Debris:AddItem(vfx, 2)
					task.delay(0.01, function()
						for _, v in ipairs(vfx:GetChildren()) do
							if v:IsA("ParticleEmitter") then v:Emit(1) end
						end
					end)
				end
			end
		end
	end
end

CombatServer.new()